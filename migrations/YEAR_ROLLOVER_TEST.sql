-- ############################################################################
-- ############################################################################
--
--   EduCore360 -- YEAR ROLLOVER            *** TEST PROJECT ONLY ***
--   19-09-2026
--
-- ############################################################################
-- ############################################################################
--
-- DO NOT RUN THIS ON LIVE. DO NOT ADD IT TO A LIVE_UPDATE_*.sql BUNDLE.
--
-- The rollover feature is TEST-only until the institution says otherwise. The
-- desktop app hides it unless a config.json has pointed the build at a
-- non-production project, and this file is deliberately kept out of the live
-- bundles for the same reason. It is also NOT merged into
-- C:\pg_backups\complete_setup.sql yet -- a fresh institution keeps the old
-- (uncalled) function until rollover is cleared to ship.
--
-- ---------------------------------------------------------------------------
-- WHAT IT DOES
-- ---------------------------------------------------------------------------
-- Rebuilds public.rollover_academic_year so that "create next year" actually
-- carries the institution forward, and adds a read-only preview so the app can
-- show what WILL happen before anything is written.
--
--   1. students.arrearonly        new flag: carried only to settle arrears
--   2. copy helpers               column lists derived from the catalogue
--   3. rollover_preview()         read-only dry run
--   4. rollover_academic_year()   the rewrite
--   5. generate_feedemand_*       skips arrear-only students
--   6. verification
--
-- ---------------------------------------------------------------------------
-- THE CARRY-FORWARD RULES
-- ---------------------------------------------------------------------------
-- MASTERS copied as-is, PKs preserved (so cross-year ids stay meaningful):
--   course, class, semester, community, division, concessioncategory,
--   admissiontype, quota, bank, paymentgateway, finerule, feegroup, feetype,
--   sequence.
--
-- classfeedemand is NOT copied. The fee structure is set afresh every year --
-- the amounts are the whole point of the exercise -- so carrying last year's
-- templates would pre-load the new year with last year's figures and invite
-- demands being raised from them by mistake. Class Fee Demand is built in
-- Setup -> Fee Master before demands are generated.
--
-- STUDENTS -- every student with activestatus = 1, in one of four dispositions:
--   PROMOTED      class has a succeedingclass  -> next class
--   FINAL_YEAR    class has none               -> SAME class, arrearonly = 1
--   PREADMISSION  booked this year for next    -> SAME class, flag cleared
--   UNRESOLVED    class not in the master, or succeedingclass dangling
--                                              -> SAME class, reported
--
-- A FINAL-YEAR student is carried so their arrears stay collectible in the
-- current year without switching back. arrearonly = 1 stops the demand
-- generator raising a second year of fees against them.
--
-- FEE DEMANDS -- every unpaid demand crosses as demseqtype = 'ARREAR', one row
-- per original demand (term and fee type preserved, not consolidated), with
-- feeamount = what is still owed and arrearclass = the class it AROSE in, so
-- an arrear receipt prints the right class. collectible is carried unchanged:
-- a fee that was never collectible does not become one by crossing a year.
-- fineamount is NOT carried -- fines are recomputed from finerule.
--
-- ADVANCES -- carried when balanceamount > 0 after adjustment, at their
-- REMAINING value, with advance_detail. Money in hand must follow its student.
--
-- NOT COPIED (deliberate): classfeedemand (see above), payment,
-- paymentdetails, tempfeedemand, misc_collection, shoppingcart, notice,
-- notification, userlogin, student_import, interim_promotion, fee_refund.
-- The rest are records of what happened in a particular year.
--
-- ---------------------------------------------------------------------------
-- STILL OPEN -- must be settled before this can ever go live
-- ---------------------------------------------------------------------------
--   * No year-close flag. After a rollover the old schema is still writable,
--     so the same due is collectible in BOTH years. See
--     docs/YEAR_ROLLOVER_DESIGN.md section 2.6.
--   * Not session-gated. search_path is pinned here, but the function is still
--     granted to anon like its predecessor. It needs the p_token /
--     session_context treatment before it is exposed on a live project.
--   * Payments pending reconciliation are treated as realised (balancedue is
--     carried, not reconbalancedue).
--   * public.admission rows still PENDING at year end are left alone.
--
-- SAFE TO RE-RUN. The rollover itself refuses if the new schema exists.
-- ############################################################################


-- ############################################################################
-- 1 -- students.arrearonly
--
-- Carried into the new year only so their outstanding dues stay collectible;
-- no new demands are raised against them. Added to every existing year schema
-- here, and to the new schema by the rollover itself.
--
-- This file does not change create_institution_schema -- that function is
-- shared with live, so it is altered in the companion file
-- migrations/YEAR_ROLLOVER_CREATE_SCHEMA_TEST.sql, which is also TEST-only.
-- The rollover keeps its own ALTER regardless: it must still produce a usable
-- year on a database where only this file has been applied.
-- ############################################################################
DO $cols$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'students'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS '
                   'arrearonly smallint DEFAULT 0 NOT NULL', r.s);
    RAISE NOTICE '%.students: arrearonly present', r.s;
  END LOOP;
END $cols$;


-- ############################################################################
-- 2 -- COPY HELPERS
--
-- The old function hardcoded a column list for each of ~15 tables, which is
-- exactly how it drifted ~20 columns behind the schema and silently dropped
-- classfeedemand.collectible -- opening a year that could not collect fees.
--
-- These derive the list from information_schema at run time: whatever columns
-- BOTH schemas have get copied. A column added next year is picked up without
-- anyone remembering to edit this file.
-- ############################################################################

-- Copy one table wholesale. p_overrides maps a column name to a raw SQL
-- expression used in its place (already quoted by the caller).
CREATE OR REPLACE FUNCTION public._rollover_copy(
  p_old text, p_new text, p_table text, p_overrides jsonb DEFAULT '{}'::jsonb)
RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_cols text; v_sel text; v_identity boolean; v_n integer := 0;
BEGIN
  -- A schema created before a given module has no such table; skip quietly.
  IF to_regclass(format('%I.%I', p_old, p_table)) IS NULL
     OR to_regclass(format('%I.%I', p_new, p_table)) IS NULL THEN
    RETURN 0;
  END IF;

  SELECT string_agg(quote_ident(n.column_name), ', ' ORDER BY n.ordinal_position),
         string_agg(COALESCE(p_overrides->>n.column_name,
                             quote_ident(n.column_name)), ', ' ORDER BY n.ordinal_position),
         bool_or(n.is_identity = 'YES')
    INTO v_cols, v_sel, v_identity
    FROM information_schema.columns n
   WHERE n.table_schema = p_new
     AND n.table_name   = p_table
     -- GENERATED ALWAYS AS (...) columns cannot be inserted into:
     -- advance_collection.balanceamount is one.
     AND n.is_generated = 'NEVER'
     AND EXISTS (SELECT 1 FROM information_schema.columns o
                  WHERE o.table_schema = p_old
                    AND o.table_name   = p_table
                    AND o.column_name  = n.column_name);

  IF v_cols IS NULL THEN RETURN 0; END IF;

  EXECUTE format('INSERT INTO %I.%I (%s) %s SELECT %s FROM %I.%I',
                 p_new, p_table, v_cols,
                 CASE WHEN v_identity THEN 'OVERRIDING SYSTEM VALUE' ELSE '' END,
                 v_sel, p_old, p_table);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $fn$;

-- Push a table's sequence past the highest copied id, so the next insert in
-- the new year does not collide with a carried row.
CREATE OR REPLACE FUNCTION public._rollover_setval(
  p_schema text, p_table text, p_col text)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $fn$
DECLARE s text;
BEGIN
  IF to_regclass(format('%I.%I', p_schema, p_table)) IS NULL THEN RETURN; END IF;
  s := pg_get_serial_sequence(format('%I.%I', p_schema, p_table), p_col);
  IF s IS NULL THEN RETURN; END IF;
  EXECUTE format('SELECT setval(%L, GREATEST((SELECT COALESCE(MAX(%I),0) FROM %I.%I),1))',
                 s, p_col, p_schema, p_table);
END $fn$;


-- ############################################################################
-- 3 -- rollover_preview  (READ-ONLY)
--
-- What the confirmation dialog shows. Writes nothing, creates nothing, and
-- resolves promotion with exactly the same rules as the commit below -- if the
-- two ever disagree the preview is worthless, so they are kept adjacent.
-- ############################################################################
CREATE OR REPLACE FUNCTION public.rollover_preview(
  p_ins_id integer, p_old_year_label text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_short text; v_old text; v_res json;
BEGIN
  SELECT lower(inshortname) INTO v_short FROM public.institution WHERE ins_id = p_ins_id;
  IF v_short IS NULL THEN RAISE EXCEPTION 'Institution % not found', p_ins_id; END IF;
  v_old := v_short || replace(p_old_year_label, '-', '');

  IF to_regclass(format('%I.students', v_old)) IS NULL THEN
    RAISE EXCEPTION 'Year schema % does not exist', v_old;
  END IF;

  -- DROP + CREATE rather than CREATE IF NOT EXISTS + DELETE: Supabase runs the
  -- anon role with the safeupdate guard, which rejects an unqualified DELETE
  -- with SQLSTATE 21000 ("DELETE requires a WHERE clause"). That made every
  -- call from the app fail while the same function ran fine over psql, where
  -- the guard is not loaded.
  DROP TABLE IF EXISTS _preview_promote;
  CREATE TEMP TABLE _preview_promote (
    stu_id bigint PRIMARY KEY, new_class varchar(20), new_cla_id smallint,
    old_class varchar(20), disposition text) ON COMMIT DROP;

  EXECUTE format($q$
    INSERT INTO _preview_promote (stu_id, new_class, new_cla_id, old_class, disposition)
    SELECT DISTINCT ON (s.stu_id) s.stu_id,
      CASE WHEN COALESCE(s.preadmission,0) = 1 THEN s.stuclass
           WHEN c.cla_id IS NULL              THEN s.stuclass
           WHEN c.succeedingclass IS NULL     THEN s.stuclass
           WHEN nc.cla_id IS NULL             THEN s.stuclass
           ELSE nc.claname END,
      CASE WHEN COALESCE(s.preadmission,0) = 1 THEN c.cla_id
           WHEN c.cla_id IS NULL              THEN NULL
           WHEN c.succeedingclass IS NULL     THEN c.cla_id
           WHEN nc.cla_id IS NULL             THEN c.cla_id
           ELSE nc.cla_id END,
      s.stuclass,
      CASE WHEN COALESCE(s.preadmission,0) = 1 THEN 'PREADMISSION'
           WHEN c.cla_id IS NULL              THEN 'UNRESOLVED'
           WHEN c.succeedingclass IS NULL     THEN 'FINAL_YEAR'
           WHEN nc.cla_id IS NULL             THEN 'UNRESOLVED'
           ELSE 'PROMOTED' END
    FROM %1$I.students s
    LEFT JOIN %1$I.class c
      ON UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
     AND c.ins_id = s.ins_id AND c.activestatus = 1
     AND (c.cour_id IS NULL OR s.cour_id IS NULL OR c.cour_id = s.cour_id)
    LEFT JOIN %1$I.class nc ON nc.cla_id = c.succeedingclass AND nc.activestatus = 1
    WHERE s.activestatus = 1
    -- Prefer the class row that also matches the student's COURSE. Without
    -- this an institution running "I YEAR" under two courses produced two
    -- rows for one student and the whole rollover aborted on the PK.
    ORDER BY s.stu_id, (c.cour_id IS NOT DISTINCT FROM s.cour_id) DESC, c.cla_id
  $q$, v_old);

  EXECUTE format($q$
    SELECT json_build_object(
      'old_schema',        %1$L,
      'students_total',    (SELECT COUNT(*) FROM _preview_promote),
      'promoted',          (SELECT COUNT(*) FROM _preview_promote WHERE disposition='PROMOTED'),
      'final_year',        (SELECT COUNT(*) FROM _preview_promote WHERE disposition='FINAL_YEAR'),
      'preadmission',      (SELECT COUNT(*) FROM _preview_promote WHERE disposition='PREADMISSION'),
      'unresolved',        (SELECT COUNT(*) FROM _preview_promote WHERE disposition='UNRESOLVED'),
      'unresolved_classes',(SELECT COALESCE(json_agg(DISTINCT old_class), '[]'::json)
                              FROM _preview_promote WHERE disposition='UNRESOLVED'),
      'inactive_left',     (SELECT COUNT(*) FROM %1$I.students WHERE activestatus <> 1),
      'arrear_rows',       (SELECT COUNT(*) FROM %1$I.feedemand d JOIN _preview_promote p ON p.stu_id=d.stu_id
                             WHERE d.activestatus=1 AND d.paidstatus='U' AND d.balancedue>0),
      'arrear_total',      (SELECT COALESCE(SUM(d.balancedue),0) FROM %1$I.feedemand d JOIN _preview_promote p ON p.stu_id=d.stu_id
                             WHERE d.activestatus=1 AND d.paidstatus='U' AND d.balancedue>0),
      'advance_rows',      %2$s,
      'advance_total',     %3$s,
      'courses',           (SELECT COUNT(*) FROM %1$I.course WHERE activestatus=1),
      'classes',           (SELECT COUNT(*) FROM %1$I.class WHERE activestatus=1),
      'feegroups',         (SELECT COUNT(*) FROM %1$I.feegroup WHERE activestatus=1),
      'feetypes',          (SELECT COUNT(*) FROM %1$I.feetype WHERE activestatus=1)
    )$q$,
    v_old,
    CASE WHEN to_regclass(format('%I.advance_collection', v_old)) IS NULL THEN '0'
         ELSE format('(SELECT COUNT(*) FROM %I.advance_collection a JOIN _preview_promote p ON p.stu_id=a.stu_id WHERE a.activestatus=1 AND a.balanceamount>0)', v_old) END,
    CASE WHEN to_regclass(format('%I.advance_collection', v_old)) IS NULL THEN '0'
         ELSE format('(SELECT COALESCE(SUM(a.balanceamount),0) FROM %I.advance_collection a JOIN _preview_promote p ON p.stu_id=a.stu_id WHERE a.activestatus=1 AND a.balanceamount>0)', v_old) END
  ) INTO v_res;

  DROP TABLE IF EXISTS _preview_promote;
  RETURN v_res;
END $fn$;

GRANT EXECUTE ON FUNCTION public.rollover_preview(integer, text) TO anon, authenticated;


-- ############################################################################
-- 4 -- rollover_academic_year  (THE COMMIT)
--
-- One transaction. If anything raises, the new schema goes with it -- there is
-- no half-created year to clean up.
-- ############################################################################
CREATE OR REPLACE FUNCTION public.rollover_academic_year(
  p_ins_id integer, p_old_year_label text, p_new_year_label text,
  p_start_date date, p_end_date date)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $fn$
DECLARE
  v_short text; v_old text; v_new text; v_new_yr integer;
  v_cols text; v_sel text;
  v_promoted int := 0; v_final int := 0; v_pre int := 0; v_unres int := 0;
  v_students int := 0; v_parents int := 0; v_pdetail int := 0;
  v_arrows int := 0; v_aramt numeric(14,2) := 0;
  v_advrows int := 0; v_advamt numeric(14,2) := 0;
  v_masters jsonb := '{}'::jsonb;
  t text;
BEGIN
  SELECT lower(inshortname) INTO v_short FROM public.institution WHERE ins_id = p_ins_id;
  IF v_short IS NULL THEN RAISE EXCEPTION 'Institution % not found', p_ins_id; END IF;

  v_old := v_short || replace(p_old_year_label, '-', '');
  v_new := v_short || replace(p_new_year_label, '-', '');

  IF to_regclass(format('%I.students', v_old)) IS NULL THEN
    RAISE EXCEPTION 'Old year schema % does not exist', v_old;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_new) THEN
    RAISE EXCEPTION 'New year schema % already exists - aborting to avoid clobber', v_new;
  END IF;

  -- --- 1. the empty new schema (+ year / institutionyear rows) -------------
  PERFORM public.create_institution_schema(v_new, p_ins_id, p_new_year_label, p_start_date, p_end_date);
  EXECUTE format('SELECT yr_id FROM %I.year ORDER BY yr_id LIMIT 1', v_new) INTO v_new_yr;

  -- create_institution_schema is shared with live and deliberately not
  -- modified by this file, so the new schema needs the flag adding here.
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS '
                 'arrearonly smallint DEFAULT 0 NOT NULL', v_new);

  -- ======================================================================
  -- 2. MASTERS
  -- ======================================================================
  -- Year-less masters: straight copy, ids preserved.
  -- classfeedemand is deliberately absent: next year's fee structure is
  -- entered fresh in Setup -> Fee Master, not inherited.
  FOREACH t IN ARRAY ARRAY['course','class','semester','community','division',
                           'concessioncategory','admissiontype','quota','bank',
                           'paymentgateway','finerule']
  LOOP
    v_masters := v_masters || jsonb_build_object(t, public._rollover_copy(v_old, v_new, t));
  END LOOP;

  PERFORM public._rollover_setval(v_new,'course','cour_id');
  PERFORM public._rollover_setval(v_new,'class','cla_id');
  PERFORM public._rollover_setval(v_new,'concessioncategory','con_id');
  PERFORM public._rollover_setval(v_new,'bank','ban_id');
  PERFORM public._rollover_setval(v_new,'paymentgateway','gw_id');
  PERFORM public._rollover_setval(v_new,'finerule','fr_id');

  -- Year-stamped masters: same copy, with yr_id / yrlabel replaced.
  v_masters := v_masters || jsonb_build_object('feegroup',
    public._rollover_copy(v_old, v_new, 'feegroup',
      jsonb_build_object('yr_id', v_new_yr::text, 'yrlabel', quote_literal(p_new_year_label))));
  PERFORM public._rollover_setval(v_new,'feegroup','fg_id');

  v_masters := v_masters || jsonb_build_object('feetype',
    public._rollover_copy(v_old, v_new, 'feetype',
      jsonb_build_object('yr_id', v_new_yr::text, 'yrlabel', quote_literal(p_new_year_label))));
  PERFORM public._rollover_setval(v_new,'feetype','fee_id');

  -- sequence: year re-stamped AND the running number reset to its start, so
  -- receipt / demand numbering restarts each year.
  v_masters := v_masters || jsonb_build_object('sequence',
    public._rollover_copy(v_old, v_new, 'sequence',
      jsonb_build_object('yr_id', v_new_yr::text,
                         'yrlabel', quote_literal(p_new_year_label),
                         'seqcurno', 'seqstart')));
  PERFORM public._rollover_setval(v_new,'sequence','seq_id');

  -- ======================================================================
  -- 3. PROMOTION MAP -- who carries, to which class, and why
  -- ======================================================================
  CREATE TEMP TABLE _promote (
    stu_id bigint PRIMARY KEY, new_class varchar(20), new_cla_id smallint,
    old_class varchar(20), disposition text) ON COMMIT DROP;

  EXECUTE format($q$
    INSERT INTO _promote (stu_id, new_class, new_cla_id, old_class, disposition)
    SELECT DISTINCT ON (s.stu_id) s.stu_id,
      CASE WHEN COALESCE(s.preadmission,0) = 1 THEN s.stuclass
           WHEN c.cla_id IS NULL              THEN s.stuclass
           WHEN c.succeedingclass IS NULL     THEN s.stuclass
           WHEN nc.cla_id IS NULL             THEN s.stuclass
           ELSE nc.claname END,
      CASE WHEN COALESCE(s.preadmission,0) = 1 THEN c.cla_id
           WHEN c.cla_id IS NULL              THEN NULL
           WHEN c.succeedingclass IS NULL     THEN c.cla_id
           WHEN nc.cla_id IS NULL             THEN c.cla_id
           ELSE nc.cla_id END,
      s.stuclass,
      CASE WHEN COALESCE(s.preadmission,0) = 1 THEN 'PREADMISSION'
           WHEN c.cla_id IS NULL              THEN 'UNRESOLVED'
           WHEN c.succeedingclass IS NULL     THEN 'FINAL_YEAR'
           WHEN nc.cla_id IS NULL             THEN 'UNRESOLVED'
           ELSE 'PROMOTED' END
    FROM %1$I.students s
    LEFT JOIN %1$I.class c
      ON UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
     AND c.ins_id = s.ins_id AND c.activestatus = 1
     AND (c.cour_id IS NULL OR s.cour_id IS NULL OR c.cour_id = s.cour_id)
    LEFT JOIN %1$I.class nc ON nc.cla_id = c.succeedingclass AND nc.activestatus = 1
    WHERE s.activestatus = 1
    ORDER BY s.stu_id, (c.cour_id IS NOT DISTINCT FROM s.cour_id) DESC, c.cla_id
  $q$, v_old);

  SELECT COUNT(*) FILTER (WHERE disposition='PROMOTED'),
         COUNT(*) FILTER (WHERE disposition='FINAL_YEAR'),
         COUNT(*) FILTER (WHERE disposition='PREADMISSION'),
         COUNT(*) FILTER (WHERE disposition='UNRESOLVED')
    INTO v_promoted, v_final, v_pre, v_unres
    FROM _promote;

  -- ======================================================================
  -- 4. STUDENTS
  --
  -- The column list is built from the catalogue, minus the ones computed
  -- below. That is what stops this drifting behind the schema again: a
  -- column added to students next year is carried without editing this.
  -- ======================================================================
  SELECT string_agg(quote_ident(n.column_name), ', ' ORDER BY n.ordinal_position),
         string_agg('s.' || quote_ident(n.column_name), ', ' ORDER BY n.ordinal_position)
    INTO v_cols, v_sel
    FROM information_schema.columns n
   WHERE n.table_schema = v_new AND n.table_name = 'students'
     AND n.is_generated = 'NEVER'
     AND EXISTS (SELECT 1 FROM information_schema.columns o
                  WHERE o.table_schema = v_old AND o.table_name = 'students'
                    AND o.column_name = n.column_name)
     AND n.column_name NOT IN ('yr_id','yrlabel','stuclass','cla_id','stuotpstatus',
                               'approveddate','createdon','activestatus',
                               'preadmission','arrearonly','stumobotp',
                               'suspendeddate','suspendedby','terminateddate',
                               'terminatedby','terminatedreason');

  EXECUTE format($q$
    INSERT INTO %1$I.students
      (%3$s, yr_id, yrlabel, stuclass, cla_id, stuotpstatus, approveddate,
       createdon, activestatus, preadmission, arrearonly)
    SELECT %4$s, $1, $2, p.new_class, p.new_cla_id, 0, now(),
       now(), 1, 0,
       -- FINAL YEAR: carried so their arrears stay collectible in the current
       -- year, but the demand generator must not bill them a second time.
       CASE WHEN p.disposition = 'FINAL_YEAR' THEN 1 ELSE 0 END
    FROM %2$I.students s
    JOIN _promote p ON p.stu_id = s.stu_id
  $q$, v_new, v_old, v_cols, v_sel) USING v_new_yr, p_new_year_label;
  GET DIAGNOSTICS v_students = ROW_COUNT;
  -- preadmission is written 0: the year they were holding a seat for has
  -- arrived, so they are now an ordinary student of that class.

  PERFORM public._rollover_setval(v_new,'students','stu_id');

  -- ======================================================================
  -- 5. PARENTS + PARENTDETAIL  (only those attached to a carried student)
  -- ======================================================================
  SELECT string_agg(quote_ident(n.column_name), ', ' ORDER BY n.ordinal_position),
         string_agg('x.' || quote_ident(n.column_name), ', ' ORDER BY n.ordinal_position)
    INTO v_cols, v_sel
    FROM information_schema.columns n
   WHERE n.table_schema = v_new AND n.table_name = 'parents'
     AND n.is_generated = 'NEVER'
     AND EXISTS (SELECT 1 FROM information_schema.columns o
                  WHERE o.table_schema = v_old AND o.table_name = 'parents'
                    AND o.column_name = n.column_name)
     AND n.column_name NOT IN ('yr_id','yrlabel','parotpstatus','parmobotp','parmobotp_at');

  EXECUTE format($q$
    INSERT INTO %1$I.parents (%3$s, yr_id, yrlabel, parotpstatus)
    SELECT %4$s, $1, $2, 0
    FROM %2$I.parents x
    WHERE x.par_id IN (SELECT DISTINCT pd.par_id FROM %2$I.parentdetail pd
                        JOIN _promote p ON p.stu_id = pd.stu_id)
  $q$, v_new, v_old, v_cols, v_sel) USING v_new_yr, p_new_year_label;
  GET DIAGNOSTICS v_parents = ROW_COUNT;
  PERFORM public._rollover_setval(v_new,'parents','par_id');

  EXECUTE format($q$
    INSERT INTO %1$I.parentdetail
      (pd_id, yr_id, yrlabel, par_id, stu_id, ins_id, inscode, stuadmno, stuname, stuclass, activestatus)
    SELECT pd.pd_id, $1, $2, pd.par_id, pd.stu_id, pd.ins_id, pd.inscode,
           pd.stuadmno, pd.stuname, p.new_class, pd.activestatus
    FROM %2$I.parentdetail pd
    JOIN _promote p ON p.stu_id = pd.stu_id
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  GET DIAGNOSTICS v_pdetail = ROW_COUNT;
  PERFORM public._rollover_setval(v_new,'parentdetail','pd_id');

  -- ======================================================================
  -- 6. ARREARS -- every unpaid demand, one row each
  --
  -- NOT consolidated into a single "Opening Balance": the term and fee type
  -- are what the ledger, the DCB register and the arrear receipt print, and
  -- collapsing them loses information that cannot be recovered.
  --
  -- arrearclass is the class the due AROSE in, which is what fee collection
  -- reads when printing an arrear -- not the class the student moves to.
  -- ======================================================================
  EXECUTE format($q$
    INSERT INTO %1$I.feedemand
      (demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass,
       demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount,
       paidamount, fineamount, balancedue, reconbalancedue, duedate,
       paidstatus, createdby, activestatus, courname, collectible,
       fee_id, cla_id, sem_id, cf_id, arrearclass, remarks)
    SELECT 'ARREAR', d.ins_id, d.inscode, $1, d.stu_id, d.stuadmno, p.new_class,
       $2, d.demfeeterm, d.demfeetype,
       -- What is still owed becomes the demand. The concession was already
       -- applied when the original was raised, so it is not re-applied.
       d.balancedue, d.con_id, 0,
       0,
       -- Fines are NOT carried: they accrue against a due date and finerule
       -- recomputes them in the new year.
       0,
       d.balancedue, d.balancedue, $3,
       'U', 'YEAR_ROLLOVER', 1, d.courname,
       -- A fee that was never collectible does not become one by crossing a
       -- year boundary.
       d.collectible,
       d.fee_id, p.new_cla_id, d.sem_id, d.cf_id,
       COALESCE(NULLIF(TRIM(d.arrearclass), ''), d.stuclass),
       ('Arrear ' || $4)
    FROM %2$I.feedemand d
    JOIN _promote p ON p.stu_id = d.stu_id
    WHERE d.activestatus = 1 AND d.paidstatus = 'U' AND d.balancedue > 0
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label, p_start_date, p_old_year_label;
  GET DIAGNOSTICS v_arrows = ROW_COUNT;

  EXECUTE format($q$SELECT COALESCE(SUM(balancedue),0) FROM %1$I.feedemand
                     WHERE createdby = 'YEAR_ROLLOVER'$q$, v_new) INTO v_aramt;

  -- ======================================================================
  -- 7. ADVANCES -- money in hand follows its student
  --
  -- Carried at its REMAINING value: what was already adjusted was adjusted in
  -- the old year and must not become spendable twice.
  -- ======================================================================
  IF to_regclass(format('%I.advance_collection', v_old)) IS NOT NULL
     AND to_regclass(format('%I.advance_collection', v_new)) IS NOT NULL THEN
    EXECUTE format($q$
      INSERT INTO %1$I.advance_collection
        (adv_id, ins_id, inscode, stu_id, stuadmno, stuname, stuclass, courname,
         yr_id, yrlabel, advno, advdate, advtype, transtotalamount, adjustedamount,
         refund_amount, transcurrency, paystatus, paymethod, payreference,
         remarks, createdby, createdat, recon_status, reconciled_by,
         reconciled_date, bank_reference, bank_date, activestatus)
      OVERRIDING SYSTEM VALUE
      SELECT a.adv_id, a.ins_id, a.inscode, a.stu_id, a.stuadmno, a.stuname,
             p.new_class, a.courname, $1, $2, a.advno, a.advdate, a.advtype,
             a.balanceamount, 0, 0,
             a.transcurrency, a.paystatus, a.paymethod, a.payreference,
             COALESCE(NULLIF(a.remarks, ''), ''), a.createdby, a.createdat,
             a.recon_status, a.reconciled_by, a.reconciled_date,
             a.bank_reference, a.bank_date, a.activestatus
        FROM %2$I.advance_collection a
        JOIN _promote p ON p.stu_id = a.stu_id
       WHERE a.activestatus = 1 AND a.balanceamount > 0
    $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
    GET DIAGNOSTICS v_advrows = ROW_COUNT;
    PERFORM public._rollover_setval(v_new,'advance_collection','adv_id');

    EXECUTE format($q$SELECT COALESCE(SUM(balanceamount),0) FROM %1$I.advance_collection$q$, v_new)
      INTO v_advamt;

    -- The fee-type breakdown an ADMISSION advance was collected against;
    -- Advance Adjustment matches on it, so it has to come too.
    IF to_regclass(format('%I.advance_detail', v_old)) IS NOT NULL
       AND to_regclass(format('%I.advance_detail', v_new)) IS NOT NULL THEN
      EXECUTE format($q$
        INSERT INTO %1$I.advance_detail (adv_id, ins_id, fee_id, fg_id, feetype, amount, activestatus)
        SELECT d.adv_id, d.ins_id, d.fee_id, d.fg_id, d.feetype, d.amount, d.activestatus
          FROM %2$I.advance_detail d
          JOIN %1$I.advance_collection a ON a.adv_id = d.adv_id
         WHERE d.activestatus = 1
      $q$, v_new, v_old);
    END IF;
  END IF;

  RETURN json_build_object(
    'old_schema',        v_old,
    'new_schema',        v_new,
    'new_yr_id',         v_new_yr,
    'students_carried',  v_students,
    'promoted',          v_promoted,
    'final_year',        v_final,
    'preadmission',      v_pre,
    'unresolved',        v_unres,
    'parents_carried',   v_parents,
    'parentdetail',      v_pdetail,
    'arrear_rows',       v_arrows,
    'arrear_total',      v_aramt,
    'advance_rows',      v_advrows,
    'advance_total',     v_advamt,
    'masters',           v_masters
  );
END $fn$;

GRANT EXECUTE ON FUNCTION public.rollover_academic_year(integer, text, text, date, date) TO anon, authenticated;


-- ############################################################################
-- 5 -- THE DEMAND GENERATOR SKIPS ARREAR-ONLY STUDENTS
--
-- A final-year student carried into the new year is in the SAME class, so the
-- template would raise that class's fees against them a second time. The
-- predicate is added dynamically: a schema without the column (one created
-- before this file ran) still works.
-- ############################################################################
CREATE OR REPLACE FUNCTION public.generate_feedemand_for_class(
  p_ins_id integer, p_class text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '120s'
AS $fn$
DECLARE v_schema text; v_count int; v_arrear text := '';
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = v_schema AND table_name = 'students'
                AND column_name = 'arrearonly') THEN
    v_arrear := ' AND COALESCE(s.arrearonly, 0) = 0 ';
  END IF;

  EXECUTE format($q$
    INSERT INTO %1$I.tempfeedemand
      (ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear,
       demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, duedate,
       activestatus, createdby, isapproved, collectible,
       cla_id, sem_id, cf_id, fee_id, demseqtype)
    SELECT s.ins_id, s.inscode, s.yr_id, s.stu_id, s.stuadmno, s.stuclass, s.courname,
       s.yrlabel, cf.cfterm, cf.cffeetype, cf.cfamount, s.con_id, 0, cf.cfamount,
       cf.cfdduedate, 1, COALESCE(s.approvedby, 'SYSTEM'), false, COALESCE(cf.collectible, true),
       cf.cla_id, cf.sem_id, cf.cf_id, cf.fee_id, 'REGULAR'
    FROM %1$I.students s
    JOIN %1$I.classfeedemand cf
      ON cf.cfclass = s.stuclass AND cf.activestatus = 1
    LEFT JOIN %1$I.admissiontype a
      ON UPPER(TRIM(a.admname)) = UPPER(TRIM(s.admname)) AND a.activestatus = 1 AND a.ins_id = s.ins_id
    WHERE s.activestatus <> 9
      AND COALESCE(s.preadmission, 0) = 0
      %2$s
      AND s.stuclass = $1
      AND cf.cfamount IS NOT NULL
      AND (cf.admissiontype IS NULL OR cf.admissiontype = a.adm_id)
      AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd
                       WHERE fd.stu_id = s.stu_id AND fd.demfeetype = cf.cffeetype
                         AND fd.demfeeterm = cf.cfterm AND fd.activestatus = 1)
      AND NOT EXISTS (SELECT 1 FROM %1$I.tempfeedemand td
                       WHERE td.stu_id = s.stu_id AND td.demfeetype = cf.cffeetype
                         AND td.demfeeterm = cf.cfterm AND td.activestatus = 1)
  $q$, v_schema, v_arrear) USING p_class;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $fn$;

GRANT EXECUTE ON FUNCTION public.generate_feedemand_for_class(integer, text) TO anon, authenticated;


-- ############################################################################
-- 6 -- VERIFY  (read-only)
-- ############################################################################
SELECT 'arrearonly on every year schema' AS check,
       COUNT(*) FILTER (WHERE has_col) || ' of ' || COUNT(*) AS result
  FROM (SELECT t.table_schema,
               EXISTS (SELECT 1 FROM information_schema.columns c
                        WHERE c.table_schema = t.table_schema
                          AND c.table_name = 'students' AND c.column_name = 'arrearonly') AS has_col
          FROM information_schema.tables t
         WHERE t.table_name = 'students'
           AND t.table_schema NOT IN ('pg_catalog','information_schema')) x;

SELECT p.proname AS function, pg_get_function_identity_arguments(p.oid) AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('rollover_academic_year','rollover_preview',
                     '_rollover_copy','_rollover_setval','generate_feedemand_for_class')
 ORDER BY p.proname;

-- A dry run. Writes nothing. Replace the year label if yours differs.
-- SELECT jsonb_pretty(public.rollover_preview(1, '2026-2027')::jsonb);
