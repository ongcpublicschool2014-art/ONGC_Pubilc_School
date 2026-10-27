-- ============================================================================
-- LIVE -- everything desktop 0.0.16 needs. Run BEFORE handing out the build.
-- ============================================================================
-- This is the companion to LIVE_2026_10_13_DASHBOARD_FIGURES.sql, which has
-- already been run. That one fixed figures the INSTALLED app shows. This one
-- is the opposite: nothing in it changes anything for a 0.0.15 user, and
-- everything in it is required by 0.0.16.
--
-- So it is safe to run at any time before the rollout, and it must be run
-- BEFORE anyone opens 0.0.16 -- the new Fee Type ordering and the fee group /
-- fee kind report filters call functions and read a column that do not exist
-- on live yet.
--
-- WHAT IS IN IT, in the order it has to run:
--
--   SECTION 1  feetype.ordid -- the column, seeded, plus the schema generator
--              so a new institution is born with it. (PART F of
--              RELEASE_LIVE_2026_10_13.sql, the only part of that file not
--              already on live. PARTS A-E were run on 13-10.)
--
--   SECTION 2  the order the office asked for: TUITION FEE, BUS FEES, ANNA
--              UNIVERSITY FEE, A.U.SPORTS FEE, BUS APPLICATION, FIRST
--              GRADUATE AMOUNT, SC/ST SCHOLARSHIP, EXAM FEE, then everything
--              else alphabetically from 9.
--
--   SECTION 3  a NEW fee type gets an ordid automatically -- the trigger
--              feetype already has, extended. Also makes the Fee Type CSV's
--              "FeeType Order" column mean something; process_master_import
--              had been reading it and throwing it away.
--
--   SECTION 4  p_fee_groups on the three report RPCs, for the Fee Group
--              filter on Pending Payment / Pending Details / Consolidated.
--
--   SECTION 5  p_fee_kinds on the same three, for the DCB Register's
--              COL / HOS / TRA filter.
--
-- ORDER MATTERS. Section 2 needs the column from 1. Section 3 patches the
-- same generator Section 1 patches and must follow it. Section 5 adds a 5th
-- argument to the 4-argument functions Section 4 creates.
--
-- OLD CALLERS KEEP WORKING. Sections 4 and 5 ADD overloads; the 2- and
-- 3-argument forms 0.0.15 calls are left in place. That is what makes this
-- safe to run days before the rollout.
--
-- Every section was run and verified on TEST. Safe to re-run: the DDL is
-- guarded, the functions are CREATE OR REPLACE, and the seeding is
-- deterministic -- running it twice produces the same numbers.
--
-- Do NOT wrap in BEGIN -- the editor supplies one, and a BEGIN here would
-- roll the whole thing back while looking like it ran.
--
-- The editor shows only the LAST result set, so run it section by section if
-- you want to see each check. The VERIFICATION at the very bottom is the one
-- that matters: every column must be true.
-- ============================================================================


-- #####################################################################
-- SECTION 1 -- feetype.ordid: the column, seeded, and the generator
-- #####################################################################

-- ============================================================================
-- feetype.ordid -- let the office decide the order fee types appear in.
-- ============================================================================
-- WHY. Reports lay fee types out as columns and sort them ALPHABETICALLY, so
-- a statement reads ADMISSION, A.U.SPORTS FEE, BUS FEES, EXAM FEE, TUITION
-- FEE -- which is nobody's idea of how a fee statement should read. TUITION
-- FEE is the one everybody looks for and it lands near the end because of its
-- initial letter.
--
-- Every other master that has a meaningful running order already carries this
-- column, with the same name and type: class, course, semester,
-- concessioncategory. feetype was the odd one out.
--
-- WHAT THIS DOES.
--   PART 1  adds ordid smallint to feetype in EVERY institution schema.
--   PART 2  seeds it so nothing is NULL on day one -- grouped by fee group,
--           then by fee_id within the group, which is the order they were
--           created and the closest thing to an intended sequence that
--           exists today. The office can renumber freely afterwards.
--   PART 3  patches create_institution_schema so a NEW institution is born
--           with the column instead of inheriting the old shape.
--
-- ORDERING IS ADVISORY, NOT A KEY. Duplicates and gaps are fine: the app
-- falls back to the fee description so two rows sharing an ordid still come
-- out in a stable, predictable order rather than shuffling between runs.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 1 =
-- The column, in every institution schema.
-- ===========================================================================

DO $add$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feetype'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.feetype ADD COLUMN IF NOT EXISTS ordid smallint', r.sch);
    RAISE NOTICE 'feetype.ordid ready in %', r.sch;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '% schema(s) updated', n;
END
$add$;


-- =================================================================== PART 2 =
-- Seed it. Only rows still NULL, so a re-run never undoes the office's work.
-- ===========================================================================

DO $seed$
DECLARE r record; n int := 0; c int;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feetype'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format($q$
      WITH ranked AS (
        SELECT fee_id,
               (row_number() OVER (ORDER BY COALESCE(fg_id, 32767), fee_id))::smallint AS seq
          FROM %I.feetype
      )
      UPDATE %I.feetype f
         SET ordid = ranked.seq
        FROM ranked
       WHERE f.fee_id = ranked.fee_id
         AND f.ordid IS NULL
    $q$, r.sch, r.sch);
    GET DIAGNOSTICS c = ROW_COUNT;
    RAISE NOTICE '% : % fee type(s) numbered', r.sch, c;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '% schema(s) seeded', n;
END
$seed$;


-- =================================================================== PART 3 =
-- New institutions get it too.
--
-- Patches the live generator text rather than replacing the whole function --
-- 55,000 characters of it -- so an unrelated change made since cannot be
-- silently reverted by this migration.
-- ===========================================================================

DO $gen$
DECLARE
  src text;
  feetype_ddl text;
  -- The real column is partialALLowed. An earlier draft of this migration
  -- searched for 'partiallowed' and would have matched nothing; it was saved
  -- only by a guard that was ALSO wrong -- 'src LIKE ''%feetype%ordid%''' is
  -- true of any generator containing both words anywhere, and ordid already
  -- exists on class, course and semester. Two loose tests cancelling out is
  -- not a safety net.
  old_txt CONSTANT text := 'partialallowed char(1) DEFAULT ''''Y''''';
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'create_institution_schema';

  IF src IS NULL THEN
    RAISE NOTICE 'create_institution_schema not found - nothing to patch';
    RETURN;
  END IF;

  -- Look at FEETYPE'S OWN definition, not the whole function.
  feetype_ddl := substring(src from 'CREATE TABLE %I.feetype[^;]*');
  IF feetype_ddl IS NULL THEN
    RAISE EXCEPTION 'Could not find feetype in the generator -- NOT patched.';
  END IF;

  IF feetype_ddl LIKE '%ordid%' THEN
    RAISE NOTICE 'generator already creates feetype.ordid';
    RETURN;
  END IF;

  n := (length(src) - length(replace(src, old_txt, ''))) / length(old_txt);
  IF n <> 1 THEN
    RAISE EXCEPTION 'Expected feetype''s partiallowed column once in the '
      'generator, found % -- NOT patched. Read the function before forcing; '
      'guessing at a schema builder is how a new institution is born broken.', n;
  END IF;

  src := replace(src, old_txt, 'ordid smallint, ' || old_txt);
  EXECUTE src;
  RAISE NOTICE 'patched create_institution_schema: feetype gains ordid';
END
$gen$;


-- #####################################################################
-- SECTION 2 -- the order the office asked for
-- #####################################################################

-- ============================================================================
-- The fee-type running order the office asked for.
-- ============================================================================
-- These eight lead, in this sequence. Everything else is numbered from 9
-- upwards in alphabetical order -- which is what "don't consider order"
-- means in practice: nobody has an opinion about them, so they keep the order
-- they already appeared in.
--
-- EVERY fee type gets a number, none are left NULL. The display is identical
-- either way (the app sorts a blank ordid last), but a real number is one the
-- office can see in the master and change, where a blank looks like something
-- nobody got round to.
--
--   1  TUITION FEE
--   2  BUS FEES
--   3  ANNA UNIVERSITY FEE
--   4  A.U.SPORTS FEE            (the office calls this "sports fee")
--   5  BUS APPLICATION           ("bus application fee")
--   6  FIRST GRADUATE AMOUNT     ("first graduate")
--   7  SC/ST SCHOLARSHIP
--   8  EXAM FEE
--
-- MATCHED ON feedesc, NOT fee_id. The reports join fee types by DESCRIPTION
-- -- feedemand stores demfeetype as text, there is no fee_id on the report
-- rows -- so the description is what the ordering has to key on. It also
-- means this script reads the same on live as on TEST without checking
-- whether the ids line up.
--
-- The descriptions above were read off the database, not guessed:
--   18 TUITION FEE · 46 BUS FEES · 21 ANNA UNIVERSITY FEE · 191 A.U.SPORTS FEE
--   253 BUS APPLICATION · 134 FIRST GRADUATE AMOUNT · 161 SC/ST SCHOLARSHIP
--   49 EXAM FEE
--
-- STEP 1 CLEARS EVERYTHING FIRST, on purpose. Without it the seed numbers
-- from FEETYPE_ORDID's PART 2 would stay on every other fee type and sort
-- them AHEAD of nothing in particular, in creation order -- which is not the
-- "don't consider" the office asked for and would look arbitrary.
--
-- Re-runnable. Run FEETYPE_ORDID.sql (or the 13-10 release) first so the
-- column exists.
--
-- Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================

-- --------------------------------------------------------------- STEP 1 ----
-- Clear. Everything starts unnumbered, then the eight are given their place.
-- ---------------------------------------------------------------------------
UPDATE kcet20262027.feetype SET ordid = NULL WHERE ordid IS NOT NULL;


-- --------------------------------------------------------------- STEP 2 ----
-- The eight, in order. UPPER(btrim()) so a stray space or a difference in
-- case cannot quietly skip one and leave a gap nobody notices.
-- ---------------------------------------------------------------------------
UPDATE kcet20262027.feetype f
   SET ordid = v.ord
  FROM (VALUES
          (1, 'TUITION FEE'),
          (2, 'BUS FEES'),
          (3, 'ANNA UNIVERSITY FEE'),
          (4, 'A.U.SPORTS FEE'),
          (5, 'BUS APPLICATION'),
          (6, 'FIRST GRADUATE AMOUNT'),
          (7, 'SC/ST SCHOLARSHIP'),
          (8, 'EXAM FEE')
       ) AS v(ord, name)
 WHERE UPPER(btrim(f.feedesc)) = v.name;


-- --------------------------------------------------------------- STEP 3 ----
-- Everything else, from 9 upwards, alphabetically.
--
-- Inactive fee types are numbered too, so a blank never comes back if one is
-- reactivated. They consume numbers and leave gaps among the active ones --
-- harmless, because the order only ever compares these values, it never
-- counts on them being consecutive.
-- ---------------------------------------------------------------------------
UPDATE kcet20262027.feetype f
   SET ordid = r.seq
  FROM (
    SELECT fee_id,
           (8 + row_number() OVER (ORDER BY UPPER(btrim(feedesc)), fee_id))::smallint AS seq
      FROM kcet20262027.feetype
     WHERE ordid IS NULL
  ) r
 WHERE f.fee_id = r.fee_id;


-- --------------------------------------------------------------- STEP 4 ----
-- Did all eight land? A name that has changed in the master would silently
-- match nothing, so this says so rather than leaving a hole in the order.
-- ---------------------------------------------------------------------------
DO $check$
DECLARE missing text;
BEGIN
  SELECT string_agg(v.name, ', ' ORDER BY v.ord)
    INTO missing
    FROM (VALUES
            (1, 'TUITION FEE'), (2, 'BUS FEES'), (3, 'ANNA UNIVERSITY FEE'),
            (4, 'A.U.SPORTS FEE'), (5, 'BUS APPLICATION'),
            (6, 'FIRST GRADUATE AMOUNT'), (7, 'SC/ST SCHOLARSHIP'),
            (8, 'EXAM FEE')
         ) AS v(ord, name)
   WHERE NOT EXISTS (SELECT 1 FROM kcet20262027.feetype f
                      WHERE UPPER(btrim(f.feedesc)) = v.name
                        AND f.ordid = v.ord);
  IF missing IS NOT NULL THEN
    RAISE WARNING 'NOT numbered (no fee type with this exact description): %',
      missing;
  ELSE
    RAISE NOTICE 'all eight numbered';
  END IF;
END
$check$;


-- ------------------------------------------------------------- VERIFY ------
-- 1. Nothing left unnumbered. Expect 0.
SELECT count(*) AS still_blank
  FROM kcet20262027.feetype WHERE ordid IS NULL;

-- 2. The order the reports and the Fee Type picker will now use.
SELECT ordid AS ord, feedesc, feeshort, activestatus
  FROM kcet20262027.feetype
 WHERE activestatus = 1
 ORDER BY ordid, feedesc;


-- #####################################################################
-- SECTION 3 -- a new fee type numbers itself
-- #####################################################################

-- ============================================================================
-- A new fee type gets an ordid automatically.
-- ============================================================================
-- WHAT WAS WRONG. FEETYPE_ORDID.sql added the column and set_feetype_order.sql
-- seeded it, but nothing assigns one to a fee type created AFTERWARDS. A fee
-- type added through Fee Master, or imported from a CSV, lands with ordid
-- NULL -- and a NULL sorts to the end of every fee-type list in Reports with
-- no number anyone can edit to move it.
--
-- WHERE IT IS FIXED. In the BEFORE INSERT trigger feetype already has.
--
-- set_fee_id is attached to feetype in every schema and already fills fee_id
-- the same way. Extending it rather than adding a 24th trigger means:
--   * both insert paths are covered by one rule -- the Fee Master form and
--     process_master_import go through the same INSERT
--   * nothing new has to be added to create_institution_schema's trigger list
--   * nothing new has to be added to tools/restore_test_repair.sql, which
--     puts the triggers back after a pg_restore into TEST strips them
--
-- An ordid supplied explicitly always wins -- the trigger only fills a NULL.
--
-- WHAT THE NUMBER IS. MAX(ordid) + 1 for the institution, so a new fee type
-- lands at the END of the order. That is the only safe default: anywhere else
-- would silently renumber fees the office has already arranged, and the one
-- thing nobody can object to is a new fee appearing last.
--
-- ALSO FIXED HERE. The Fee Type CSV has carried a "FeeType Order" column all
-- along and process_master_import read it into col6 and threw it away -- its
-- own comment said "(unused)". It now writes to ordid, so the column finally
-- means what its heading says, and a blank cell falls through to the trigger.
-- A non-numeric cell is treated as blank rather than failing the whole import.
--
-- NO APP CHANGE. Fee Master does not send ordid, which is exactly what makes
-- the trigger fire. Editing a fee type is an UPDATE, and the trigger is BEFORE
-- INSERT, so an edit cannot wipe an order that has been set.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 0 =
-- Fee types with no order today. These are the ones that would have been
-- numbered had the trigger existed; they stay NULL -- this only prints them.
-- ===========================================================================

SELECT fee_id, feedesc, feeshort, fg_id, ordid
  FROM kcet20262027.feetype
 WHERE activestatus = 1 AND ordid IS NULL
 ORDER BY fee_id;


-- =================================================================== PART 1 =
-- Extend set_fee_id in every schema that has the column.
--
-- Driven off information_schema rather than a list of institutions, so a
-- schema added since FEETYPE_ORDID.sql ran is picked up and one that never
-- got the column is skipped rather than failing.
-- ===========================================================================

DO $do$
DECLARE
  s text;
  n int := 0;
BEGIN
  FOR s IN
    SELECT c.table_schema
      FROM information_schema.columns c
     WHERE c.table_name = 'feetype'
       AND c.column_name = 'ordid'
       AND c.table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
     ORDER BY 1
  LOOP
    -- Non-positional %I throughout, three times, to match how the generator
    -- writes this function -- format() will not mix %I with %1$I.
    EXECUTE format(
      'CREATE OR REPLACE FUNCTION %I.set_fee_id() RETURNS trigger LANGUAGE plpgsql AS $t$ '
      'BEGIN '
      '  IF NEW.fee_id IS NULL OR NEW.fee_id = 0 THEN '
      '    NEW.fee_id := nextval(''%I.feetype_fee_id_seq''); '
      '  END IF; '
      '  IF NEW.ordid IS NULL THEN '
      '    SELECT COALESCE(MAX(ordid), 0) + 1 INTO NEW.ordid '
      '      FROM %I.feetype WHERE ins_id = NEW.ins_id; '
      '  END IF; '
      '  RETURN NEW; '
      'END; $t$', s, s, s);
    n := n + 1;
  END LOOP;

  IF n = 0 THEN
    RAISE EXCEPTION 'No schema has feetype.ordid -- run FEETYPE_ORDID.sql first';
  END IF;
  RAISE NOTICE 'set_fee_id extended in % schema(s)', n;
END
$do$;


-- =================================================================== PART 2 =
-- Same change inside create_institution_schema, so the NEXT institution is
-- born with it instead of needing this script run again.
--
-- Patched by replacing the one line in the stored source, not by rewriting
-- the function -- the generator is 1,500 lines and retyping it is how a
-- generator comes to differ from the schemas it has already made.
-- ===========================================================================

DO $do$
DECLARE
  src     text;
  old_txt text;
  new_txt text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema'
   LIMIT 1;

  IF src IS NULL THEN
    RAISE EXCEPTION 'create_institution_schema not found';
  END IF;

  -- Already done? Checked on the ordid assignment specifically, not merely on
  -- the word "ordid" -- class, course and semester all carry an ordid column
  -- and their DDL is in this same function, so a looser test would report
  -- success on an unpatched generator.
  IF position('NEW.ordid IS NULL' in src) > 0 THEN
    RAISE NOTICE 'create_institution_schema already patched -- nothing to do';
    RETURN;
  END IF;

  old_txt := 'NEW.fee_id := nextval(''''%I.feetype_fee_id_seq''''); END IF; RETURN NEW; END; $t$'', v_schema, v_schema);';
  new_txt := 'NEW.fee_id := nextval(''''%I.feetype_fee_id_seq''''); END IF; '
          || 'IF NEW.ordid IS NULL THEN SELECT COALESCE(MAX(ordid),0)+1 INTO NEW.ordid FROM %I.feetype WHERE ins_id = NEW.ins_id; END IF; '
          || 'RETURN NEW; END; $t$'', v_schema, v_schema, v_schema);';

  IF position(old_txt in src) = 0 THEN
    RAISE EXCEPTION 'set_fee_id line not found in create_institution_schema -- generator has drifted, patch by hand';
  END IF;

  EXECUTE replace(src, old_txt, new_txt);
  RAISE NOTICE 'create_institution_schema patched';
END
$do$;


-- =================================================================== PART 3 =
-- The CSV import's "FeeType Order" column stops being thrown away.
-- ===========================================================================

DO $do$
DECLARE
  src     text;
  old_txt text;
  new_txt text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'process_master_import'
   LIMIT 1;

  IF src IS NULL THEN
    RAISE EXCEPTION 'process_master_import not found';
  END IF;

  IF position('feefineapplicable,type,activestatus,ins_id,ordid' in src) > 0 THEN
    RAISE NOTICE 'process_master_import already patched -- nothing to do';
    RETURN;
  END IF;

  old_txt := 'feefineapplicable,type,activestatus,ins_id) VALUES($1,$2,$3,$4,$5,$6,COALESCE(NULLIF($7,'''''''')::smallint,0),NULLIF($8,''''''''),1,$9)'', v_schema) USING v_id,TRIM(rec.col2),TRIM(rec.col3),v_fg_id,v_yr_id,v_yrlabel,TRIM(rec.col5),TRIM(rec.col7),p_ins_id;';

  -- A cell that is not a plain number is treated as blank. One stray word in
  -- one row must not abort an import of ninety-five fee types, and the
  -- trigger will give that row a sensible order anyway.
  new_txt := 'feefineapplicable,type,activestatus,ins_id,ordid) VALUES($1,$2,$3,$4,$5,$6,COALESCE(NULLIF($7,'''''''')::smallint,0),NULLIF($8,''''''''),1,$9,CASE WHEN TRIM($10) ~ ''''^[0-9]+$'''' THEN TRIM($10)::smallint ELSE NULL END)'', v_schema) USING v_id,TRIM(rec.col2),TRIM(rec.col3),v_fg_id,v_yr_id,v_yrlabel,TRIM(rec.col5),TRIM(rec.col7),p_ins_id,TRIM(rec.col6);';

  IF position(old_txt in src) = 0 THEN
    RAISE EXCEPTION 'FEETYPE insert not found in process_master_import -- patch by hand';
  END IF;

  EXECUTE replace(src, old_txt, new_txt);
  RAISE NOTICE 'process_master_import patched';
END
$do$;


-- ------------------------------------------------------------- VERIFY ------
-- Expect: schemas_without_it 0, generator_patched t, import_patched t.
SELECT
  (SELECT count(*)
     FROM information_schema.columns c
    WHERE c.table_name = 'feetype' AND c.column_name = 'ordid'
      AND c.table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
      AND NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = c.table_schema AND p.proname = 'set_fee_id'
           AND p.prosrc LIKE '%NEW.ordid%'))            AS schemas_without_it,
  (SELECT bool_or(p.prosrc LIKE '%NEW.ordid IS NULL%')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema')
                                                        AS generator_patched,
  (SELECT bool_or(p.prosrc LIKE '%activestatus,ins_id,ordid%')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'process_master_import')
                                                        AS import_patched;

-- The trigger is still attached, and still the only one doing this job.
SELECT t.tgname, p.proname, p.prosrc LIKE '%NEW.ordid%' AS fills_ordid
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
 WHERE n.nspname = 'kcet20262027' AND c.relname = 'feetype' AND NOT t.tgisinternal;


-- #####################################################################
-- SECTION 4 -- Fee Group filter on the three report RPCs
-- #####################################################################

-- ============================================================================
-- Pending Payment and Consolidated Status, filterable by fee group.
-- ============================================================================
-- WHY IT HAD TO BE DONE HERE. Those two reports are server-side aggregates:
-- get_pending_payment_report and get_consolidated_status_report group by
-- course / class / semester / quota and return NO fee type at all. The app
-- can filter Daily Collection, Pending Details and the DCB Register in Dart
-- because their rows carry a fee type; these two have nothing to match on.
-- A Fee Group picker on those tabs could only ever be a dead control.
--
-- WHAT THIS ADDS. A FOURTH argument, p_fee_groups text[], to each. Null or
-- empty means "every fee group", which is exactly what the report did before.
--
-- NOTHING EXISTING CHANGES. The 2- and 3-argument forms stay, and the 3-arg
-- form now delegates with NULL. An app build that predates this keeps calling
-- the 3-arg overload and gets identical answers -- the same fallback ladder
-- _rpcWithTc already relies on for p_tc.
--
-- THE THREE REPORTS MUST STILL AGREE. get_pending_details_report shares its
-- money definitions with these two verbatim, and the comment in the app is
-- explicit that if they drift the office sees three reports contradicting
-- each other. So the filter is added as a PREDICATE ON WHICH DEMAND ROWS ARE
-- INCLUDED and nothing else: no change to how pending, paid, concession or
-- balance are computed. Filter to all groups and the numbers are identical to
-- today's, which PART 3 below checks rather than asserts.
--
-- Pending Details is deliberately NOT changed. It already filters in Dart on
-- rows that carry a fee type, and adding a second filter server-side would
-- mean two places to keep in step.
--
-- INJECTION. Group names come from the client, so they are interpolated with
-- %L (a quoted array literal) and the schema with %I, never by concatenation.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 1 =
-- Pending Payment.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE r json; v_stu text; v_fg text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);

    -- No groups chosen = no narrowing. TRUE rather than a no-op subquery so
    -- the planner sees the unfiltered shape it has always seen.
    IF p_fee_groups IS NULL OR array_length(p_fee_groups, 1) IS NULL THEN
      v_fg := 'TRUE';
    ELSE
      -- MATCHED ON fee_id, NOT THE DESCRIPTION.
      --
      -- Five fee descriptions exist in BOTH groups on this database --
      -- APPLICATION, FINE, GENERAL BREAKAGE, MISCELLANEOUS and STAFF NOTICE
      -- SALARY. Matching on text makes such a demand belong to both, so it is
      -- counted twice and the per-group totals come to MORE than the
      -- unfiltered one. Measured before this fix: 45,073,216 against
      -- 44,869,762.
      --
      -- feedemand.fee_id names the exact feetype row, and every demand here
      -- carries one (12,490 of 12,490), so the id is both unambiguous and
      -- available. The description stays only as a fallback for a row with no
      -- fee_id -- imprecise there, but visible rather than silently dropped.
      v_fg := format(
        '(CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ft'
        '             JOIN %I.feegroup fg ON fg.fg_id = ft.fg_id'
        '            WHERE ft.fee_id = fd.fee_id AND fg.activestatus = 1'
        '              AND fg.fgdesc = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ft2'
        '             JOIN %I.feegroup fg2 ON fg2.fg_id = ft2.fg_id'
        '            WHERE ft2.activestatus = 1 AND fg2.activestatus = 1'
        '              AND UPPER(TRIM(ft2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND fg2.fgdesc = ANY(%L))'
        ' END)',
        p_schema, p_schema, p_fee_groups,
        p_schema, p_schema, p_fee_groups);
    END IF;

    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.seqtype, t.stuadmno), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  fd.demfeeterm::TEXT AS semester,
                  (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END)::TEXT AS seqtype,
                  s.admname::TEXT AS admname, s.stuadmno::TEXT AS stuadmno, s.stuname::TEXT AS stuname,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  s.quoname::TEXT AS quoname, s.stumobile::TEXT AS stumobile
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND   %4$s
          GROUP BY s.courname, s.stuclass, fd.demfeeterm,
                   (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END),
                   s.admname, s.stuadmno, s.stuname, s.quoname, s.stumobile
          HAVING  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0)) <> 0
             OR   COALESCE(SUM(fd.conamount), 0) <> 0
        ) t
    $f$, p_schema, p_ins_id, v_stu, v_fg) INTO r;
    RETURN r;
END $function$;

-- The 3-arg form now delegates, so there is ONE body to maintain. Replacing
-- it rather than leaving the old copy is the point: two bodies computing
-- "pending" is how the three reports start disagreeing.
CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
  p_schema text, p_ins_id integer, p_tc text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
AS $function$
  SELECT public.get_pending_payment_report(p_schema, p_ins_id, p_tc, NULL::text[]);
$function$;

GRANT EXECUTE ON FUNCTION public.get_pending_payment_report(text, integer, text, text[])
  TO anon, authenticated;


-- =================================================================== PART 2 =
-- Consolidated Status.
--
-- class_strength is deliberately NOT filtered: a class's strength is how many
-- students are in it, not how many owe a particular group's fees. Filtering
-- it would make STRENGTH move with the fee filter, which is nonsense.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE r json; v_stu text; v_fg text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);

    IF p_fee_groups IS NULL OR array_length(p_fee_groups, 1) IS NULL THEN
      v_fg := 'TRUE';
    ELSE
      v_fg := format(
        '(CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ft'
        '             JOIN %I.feegroup fg ON fg.fg_id = ft.fg_id'
        '            WHERE ft.fee_id = fd.fee_id AND fg.activestatus = 1'
        '              AND fg.fgdesc = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ft2'
        '             JOIN %I.feegroup fg2 ON fg2.fg_id = ft2.fg_id'
        '            WHERE ft2.activestatus = 1 AND fg2.activestatus = 1'
        '              AND UPPER(TRIM(ft2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND fg2.fgdesc = ANY(%L))'
        ' END)',
        p_schema, p_schema, p_fee_groups,
        p_schema, p_schema, p_fee_groups);
    END IF;

    EXECUTE format($f$
        WITH class_strength AS (
            SELECT courname, stuclass, COUNT(DISTINCT stu_id)::INT AS strength
            FROM   %1$I.students WHERE ins_id = %2$L AND activestatus = 1
              AND COALESCE(preadmission, 0) = 0
            GROUP BY courname, stuclass
        ),
        pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.category, t.type), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  cs.strength,
                  fd.demfeeterm::TEXT AS semester,
                  COALESCE(NULLIF(s.admname, ''), 'GENERAL')::TEXT AS category,
                  COUNT(DISTINCT s.stu_id)::INT AS stud_count,
                  (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                  SUM(fd.feeamount)::NUMERIC AS due,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  SUM(fd.feeamount)::NUMERIC AS net_demand,
                  GREATEST(
                    COALESCE(SUM(fd.paidamount),0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)
                      - COALESCE(SUM(pa.pending_fee),0),
                    0
                  )::NUMERIC AS paid,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS balance
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN class_strength cs
                 ON cs.courname = s.courname AND cs.stuclass = s.stuclass
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND   %4$s
          GROUP BY s.courname, s.stuclass, cs.strength,
                   fd.demfeeterm, COALESCE(NULLIF(s.admname, ''), 'GENERAL'),
                   (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)
        ) t
    $f$, p_schema, p_ins_id, v_stu, v_fg) INTO r;
    RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(
  p_schema text, p_ins_id integer, p_tc text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
AS $function$
  SELECT public.get_consolidated_status_report(p_schema, p_ins_id, p_tc, NULL::text[]);
$function$;

GRANT EXECUTE ON FUNCTION public.get_consolidated_status_report(text, integer, text, text[])
  TO anon, authenticated;



-- =================================================================== PART 3 =
-- Pending Details, by the SAME predicate.
--
-- WHY IT HAD TO MOVE TO SQL. This report was being filtered in Dart, on the
-- fee DESCRIPTION, because its rows carry one. That disagreed with the two
-- above: five descriptions exist under both groups, so HOSTEL FEES came out
-- as 12,09,504 here against 10,27,250 from the RPCs -- 1,82,254 of college
-- fees counted as hostel. Three reports, two answers, in front of the office.
--
-- One predicate, in one place, matching on fee_id. The app now passes the
-- selection through instead of filtering what comes back.
--
-- The FEE TYPE filter stays client-side: it matches the description exactly
-- as the user picked it from a list of descriptions, so there is nothing to
-- resolve.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_pending_details_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE r json; v_stu text; v_fg text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    IF p_fee_groups IS NULL OR array_length(p_fee_groups, 1) IS NULL THEN
      v_fg := 'TRUE';
    ELSE
      v_fg := format(
        '(CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ft'
        '             JOIN %I.feegroup fg ON fg.fg_id = ft.fg_id'
        '            WHERE ft.fee_id = fd.fee_id AND fg.activestatus = 1'
        '              AND fg.fgdesc = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ft2'
        '             JOIN %I.feegroup fg2 ON fg2.fg_id = ft2.fg_id'
        '            WHERE ft2.activestatus = 1 AND fg2.activestatus = 1'
        '              AND UPPER(TRIM(ft2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND fg2.fgdesc = ANY(%L))'
        ' END)',
        p_schema, p_schema, p_fee_groups,
        p_schema, p_schema, p_fee_groups);
    END IF;
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        ),
        per_type AS (
          SELECT  s.courname::TEXT                                  AS courname,
                  s.stuclass::TEXT                                  AS stuclass,
                  s.stuadmno::TEXT                                  AS stuadmno,
                  s.stuname::TEXT                                   AS stuname,
                  -- Category on the printed sheet is the student's quota.
                  COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL')::TEXT   AS category,
                  COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS')::TEXT AS feetype,
                  -- REGULAR vs ARREAR, so the report can be filtered to one or
                  -- the other. NULL is reported as REGULAR: older rows predate
                  -- the column and are all current-year demands.
                  COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')::TEXT AS demseqtype,
                  SUM(fd.feeamount)::NUMERIC                        AS demand,
                  SUM(fd.feeamount - COALESCE(fd.conamount, 0))::NUMERIC AS net_demand,
                  GREATEST(
                    COALESCE(SUM(fd.paidamount), 0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus = 'P' OR fd.paidamount > 0), 0)
                      - COALESCE(SUM(pa.pending_fee), 0),
                    0
                  )::NUMERIC                                        AS collection,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND   %4$s
          GROUP BY s.courname, s.stuclass, s.stuadmno, s.stuname,
                   COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL'),
                   COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS'),
                   COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')
        )
        -- Only students who actually owe something. Their OTHER fee types are
        -- still returned, because the Total Demand / Collection columns are
        -- whole-student figures, not just the unpaid slice.
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.stuadmno, t.feetype, t.demseqtype), '[]'::json)
        FROM (
          SELECT * FROM per_type
          WHERE  stuadmno IN (SELECT stuadmno FROM per_type
                               GROUP BY stuadmno HAVING SUM(pending) <> 0)
        ) t
    $f$, p_schema, p_ins_id, v_stu, v_fg) INTO r;
    RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.get_pending_details_report(
  p_schema text, p_ins_id integer, p_tc text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
AS $function$
  SELECT public.get_pending_details_report(p_schema, p_ins_id, p_tc, NULL::text[]);
$function$;

GRANT EXECUTE ON FUNCTION public.get_pending_details_report(text, integer, text, text[])
  TO anon, authenticated;


-- ------------------------------------------------------------- VERIFY ------
-- 1. Both overloads exist.
SELECT
  to_regprocedure('public.get_pending_payment_report(text,integer,text,text[])')
    IS NOT NULL                                        AS pending_4arg,
  to_regprocedure('public.get_consolidated_status_report(text,integer,text,text[])')
    IS NOT NULL                                        AS conso_4arg;

-- 2. THE ONE THAT MATTERS. Unfiltered must equal what the report showed
--    before this migration, or the three reports have started to disagree.
--    Expect both true.
SELECT
  public.get_pending_payment_report('kcet20262027', 1, 'NOTC')::text
    = public.get_pending_payment_report('kcet20262027', 1, 'NOTC', NULL::text[])::text
      AS pending_unchanged,
  public.get_consolidated_status_report('kcet20262027', 1, 'NOTC')::text
    = public.get_consolidated_status_report('kcet20262027', 1, 'NOTC', NULL::text[])::text
      AS conso_unchanged,
  public.get_pending_details_report('kcet20262027', 1, 'NOTC')::text
    = public.get_pending_details_report('kcet20262027', 1, 'NOTC', NULL::text[])::text
      AS details_unchanged;

-- 3. And the filter actually narrows. Matching on fee_id, the per-group
--    totals must SUM TO the unfiltered total, less any demand whose fee type
--    sits in no live group. Summing to MORE means something is being counted
--    in two groups at once -- which is exactly what matching on the
--    description did.
SELECT 'ALL' AS fee_group,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(
                 public.get_pending_payment_report('kcet20262027', 1, 'NOTC')) e) AS pending
UNION ALL
SELECT fg.fgdesc,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(
                 public.get_pending_payment_report('kcet20262027', 1, 'NOTC',
                                                   ARRAY[fg.fgdesc])) e)
  FROM kcet20262027.feegroup fg
 WHERE fg.activestatus = 1
 ORDER BY 1;

-- 4. THE REAL TEST: all three reports must agree, filtered and unfiltered.
--    Pending Details sums its per-fee-type rows; the other two are already
--    per-student / per-class. Expect the two columns to match on every line.
SELECT g.fgdesc AS fee_group,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(
                 public.get_pending_payment_report('kcet20262027', 1, 'NOTC',
                   CASE WHEN g.fgdesc = '(ALL)' THEN NULL ELSE ARRAY[g.fgdesc] END)) e)
         AS pending_payment,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(
                 public.get_pending_details_report('kcet20262027', 1, 'NOTC',
                   CASE WHEN g.fgdesc = '(ALL)' THEN NULL ELSE ARRAY[g.fgdesc] END)) e)
         AS pending_details
  FROM (SELECT '(ALL)' AS fgdesc
        UNION ALL
        SELECT fgdesc FROM kcet20262027.feegroup WHERE activestatus = 1) g
 ORDER BY 1;


-- #####################################################################
-- SECTION 5 -- Fee Kind (COL / HOS / TRA) filter on the same three
-- #####################################################################

-- ============================================================================
-- The report RPCs also filter by FEE KIND (feetype.type: COL / TRA / HOS).
-- ============================================================================
-- A SECOND AXIS, not a replacement. The fee GROUP says which bank account the
-- money lands in; the KIND says what sort of charge it is. They are genuinely
-- independent -- the HOSTEL FEES group holds COL-typed fees on this database
-- -- so the two filters are ANDed, and either on its own still works.
--
-- Same shape as the group filter added alongside it: a 5th argument,
-- p_fee_kinds text[], null or empty meaning every kind. The 4-, 3- and 2-arg
-- forms all remain and delegate, so an older app build is unaffected.
--
-- MATCHED THROUGH fee_id for the same reason as the group: five fee
-- descriptions exist under two groups each, and the id resolves them.
--
-- Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================



-- ------------------------------------------------- get_pending_payment_report --

CREATE OR REPLACE FUNCTION public.get_pending_payment_report(p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[], p_fee_kinds text[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE r json; v_stu text; v_fg text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    -- No groups chosen = no narrowing. TRUE rather than a no-op subquery so
    -- the planner sees the unfiltered shape it has always seen.
    IF p_fee_groups IS NULL OR array_length(p_fee_groups, 1) IS NULL THEN
      v_fg := 'TRUE';
    ELSE
      -- MATCHED ON fee_id, NOT THE DESCRIPTION.
      --
      -- Five fee descriptions exist in BOTH groups on this database --
      -- APPLICATION, FINE, GENERAL BREAKAGE, MISCELLANEOUS and STAFF NOTICE
      -- SALARY. Matching on text makes such a demand belong to both, so it is
      -- counted twice and the per-group totals come to MORE than the
      -- unfiltered one. Measured before this fix: 45,073,216 against
      -- 44,869,762.
      --
      -- feedemand.fee_id names the exact feetype row, and every demand here
      -- carries one (12,490 of 12,490), so the id is both unambiguous and
      -- available. The description stays only as a fallback for a row with no
      -- fee_id -- imprecise there, but visible rather than silently dropped.
      v_fg := format(
        '(CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ft'
        '             JOIN %I.feegroup fg ON fg.fg_id = ft.fg_id'
        '            WHERE ft.fee_id = fd.fee_id AND fg.activestatus = 1'
        '              AND fg.fgdesc = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ft2'
        '             JOIN %I.feegroup fg2 ON fg2.fg_id = ft2.fg_id'
        '            WHERE ft2.activestatus = 1 AND fg2.activestatus = 1'
        '              AND UPPER(TRIM(ft2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND fg2.fgdesc = ANY(%L))'
        ' END)',
        p_schema, p_schema, p_fee_groups,
        p_schema, p_schema, p_fee_groups);
    END IF;
    -- FEE KIND (feetype.type: COL / TRA / HOS). A SECOND axis, ANDed with
    -- the group above. The group says which bank account the money lands in;
    -- the kind says what sort of charge it is, and a HOSTEL FEES group holds
    -- COL-typed fees on this database, so neither implies the other.
    --
    -- Through fee_id for the same reason as the group: five descriptions
    -- exist under two groups each and only the id resolves them.
    IF p_fee_kinds IS NOT NULL AND array_length(p_fee_kinds, 1) IS NOT NULL THEN
      v_fg := v_fg || format(
        ' AND (CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk'
        '            WHERE ftk.fee_id = fd.fee_id'
        '              AND UPPER(TRIM(COALESCE(ftk.type,''''''''))) = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk2'
        '            WHERE ftk2.activestatus = 1'
        '              AND UPPER(TRIM(ftk2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND UPPER(TRIM(COALESCE(ftk2.type,''''''''))) = ANY(%L))'
        ' END)',
        p_schema, p_fee_kinds, p_schema, p_fee_kinds);
    END IF;
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.seqtype, t.stuadmno), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  fd.demfeeterm::TEXT AS semester,
                  (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END)::TEXT AS seqtype,
                  s.admname::TEXT AS admname, s.stuadmno::TEXT AS stuadmno, s.stuname::TEXT AS stuname,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  s.quoname::TEXT AS quoname, s.stumobile::TEXT AS stumobile
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND   %4$s
          GROUP BY s.courname, s.stuclass, fd.demfeeterm,
                   (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END),
                   s.admname, s.stuadmno, s.stuname, s.quoname, s.stumobile
          HAVING  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0)) <> 0
             OR   COALESCE(SUM(fd.conamount), 0) <> 0
        ) t
    $f$, p_schema, p_ins_id, v_stu, v_fg) INTO r;
    RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w$
  SELECT public.get_pending_payment_report(p_schema, p_ins_id, p_tc, p_fee_groups, NULL::text[]);
$w$;

GRANT EXECUTE ON FUNCTION public.get_pending_payment_report(text, integer, text, text[], text[])
  TO anon, authenticated;

-- ------------------------------------------------- get_consolidated_status_report --

CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[], p_fee_kinds text[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE r json; v_stu text; v_fg text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    IF p_fee_groups IS NULL OR array_length(p_fee_groups, 1) IS NULL THEN
      v_fg := 'TRUE';
    ELSE
      v_fg := format(
        '(CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ft'
        '             JOIN %I.feegroup fg ON fg.fg_id = ft.fg_id'
        '            WHERE ft.fee_id = fd.fee_id AND fg.activestatus = 1'
        '              AND fg.fgdesc = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ft2'
        '             JOIN %I.feegroup fg2 ON fg2.fg_id = ft2.fg_id'
        '            WHERE ft2.activestatus = 1 AND fg2.activestatus = 1'
        '              AND UPPER(TRIM(ft2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND fg2.fgdesc = ANY(%L))'
        ' END)',
        p_schema, p_schema, p_fee_groups,
        p_schema, p_schema, p_fee_groups);
    END IF;
    -- FEE KIND (feetype.type: COL / TRA / HOS). A SECOND axis, ANDed with
    -- the group above. The group says which bank account the money lands in;
    -- the kind says what sort of charge it is, and a HOSTEL FEES group holds
    -- COL-typed fees on this database, so neither implies the other.
    --
    -- Through fee_id for the same reason as the group: five descriptions
    -- exist under two groups each and only the id resolves them.
    IF p_fee_kinds IS NOT NULL AND array_length(p_fee_kinds, 1) IS NOT NULL THEN
      v_fg := v_fg || format(
        ' AND (CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk'
        '            WHERE ftk.fee_id = fd.fee_id'
        '              AND UPPER(TRIM(COALESCE(ftk.type,''''''''))) = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk2'
        '            WHERE ftk2.activestatus = 1'
        '              AND UPPER(TRIM(ftk2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND UPPER(TRIM(COALESCE(ftk2.type,''''''''))) = ANY(%L))'
        ' END)',
        p_schema, p_fee_kinds, p_schema, p_fee_kinds);
    END IF;
    EXECUTE format($f$
        WITH class_strength AS (
            SELECT courname, stuclass, COUNT(DISTINCT stu_id)::INT AS strength
            FROM   %1$I.students WHERE ins_id = %2$L AND activestatus = 1
              AND COALESCE(preadmission, 0) = 0
            GROUP BY courname, stuclass
        ),
        pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.category, t.type), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  cs.strength,
                  fd.demfeeterm::TEXT AS semester,
                  COALESCE(NULLIF(s.admname, ''), 'GENERAL')::TEXT AS category,
                  COUNT(DISTINCT s.stu_id)::INT AS stud_count,
                  (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                  SUM(fd.feeamount)::NUMERIC AS due,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  SUM(fd.feeamount)::NUMERIC AS net_demand,
                  GREATEST(
                    COALESCE(SUM(fd.paidamount),0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)
                      - COALESCE(SUM(pa.pending_fee),0),
                    0
                  )::NUMERIC AS paid,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS balance
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN class_strength cs
                 ON cs.courname = s.courname AND cs.stuclass = s.stuclass
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND   %4$s
          GROUP BY s.courname, s.stuclass, cs.strength,
                   fd.demfeeterm, COALESCE(NULLIF(s.admname, ''), 'GENERAL'),
                   (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)
        ) t
    $f$, p_schema, p_ins_id, v_stu, v_fg) INTO r;
    RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w$
  SELECT public.get_consolidated_status_report(p_schema, p_ins_id, p_tc, p_fee_groups, NULL::text[]);
$w$;

GRANT EXECUTE ON FUNCTION public.get_consolidated_status_report(text, integer, text, text[], text[])
  TO anon, authenticated;

-- ------------------------------------------------- get_pending_details_report --

CREATE OR REPLACE FUNCTION public.get_pending_details_report(p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[], p_fee_kinds text[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE r json; v_stu text; v_fg text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    IF p_fee_groups IS NULL OR array_length(p_fee_groups, 1) IS NULL THEN
      v_fg := 'TRUE';
    ELSE
      v_fg := format(
        '(CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ft'
        '             JOIN %I.feegroup fg ON fg.fg_id = ft.fg_id'
        '            WHERE ft.fee_id = fd.fee_id AND fg.activestatus = 1'
        '              AND fg.fgdesc = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ft2'
        '             JOIN %I.feegroup fg2 ON fg2.fg_id = ft2.fg_id'
        '            WHERE ft2.activestatus = 1 AND fg2.activestatus = 1'
        '              AND UPPER(TRIM(ft2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND fg2.fgdesc = ANY(%L))'
        ' END)',
        p_schema, p_schema, p_fee_groups,
        p_schema, p_schema, p_fee_groups);
    END IF;
    -- FEE KIND (feetype.type: COL / TRA / HOS). A SECOND axis, ANDed with
    -- the group above. The group says which bank account the money lands in;
    -- the kind says what sort of charge it is, and a HOSTEL FEES group holds
    -- COL-typed fees on this database, so neither implies the other.
    --
    -- Through fee_id for the same reason as the group: five descriptions
    -- exist under two groups each and only the id resolves them.
    IF p_fee_kinds IS NOT NULL AND array_length(p_fee_kinds, 1) IS NOT NULL THEN
      v_fg := v_fg || format(
        ' AND (CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk'
        '            WHERE ftk.fee_id = fd.fee_id'
        '              AND UPPER(TRIM(COALESCE(ftk.type,''''''''))) = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk2'
        '            WHERE ftk2.activestatus = 1'
        '              AND UPPER(TRIM(ftk2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND UPPER(TRIM(COALESCE(ftk2.type,''''''''))) = ANY(%L))'
        ' END)',
        p_schema, p_fee_kinds, p_schema, p_fee_kinds);
    END IF;
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        ),
        per_type AS (
          SELECT  s.courname::TEXT                                  AS courname,
                  s.stuclass::TEXT                                  AS stuclass,
                  s.stuadmno::TEXT                                  AS stuadmno,
                  s.stuname::TEXT                                   AS stuname,
                  -- Category on the printed sheet is the student's quota.
                  COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL')::TEXT   AS category,
                  COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS')::TEXT AS feetype,
                  -- REGULAR vs ARREAR, so the report can be filtered to one or
                  -- the other. NULL is reported as REGULAR: older rows predate
                  -- the column and are all current-year demands.
                  COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')::TEXT AS demseqtype,
                  SUM(fd.feeamount)::NUMERIC                        AS demand,
                  SUM(fd.feeamount - COALESCE(fd.conamount, 0))::NUMERIC AS net_demand,
                  GREATEST(
                    COALESCE(SUM(fd.paidamount), 0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus = 'P' OR fd.paidamount > 0), 0)
                      - COALESCE(SUM(pa.pending_fee), 0),
                    0
                  )::NUMERIC                                        AS collection,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND   %4$s
          GROUP BY s.courname, s.stuclass, s.stuadmno, s.stuname,
                   COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL'),
                   COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS'),
                   COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')
        )
        -- Only students who actually owe something. Their OTHER fee types are
        -- still returned, because the Total Demand / Collection columns are
        -- whole-student figures, not just the unpaid slice.
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.stuadmno, t.feetype, t.demseqtype), '[]'::json)
        FROM (
          SELECT * FROM per_type
          WHERE  stuadmno IN (SELECT stuadmno FROM per_type
                               GROUP BY stuadmno HAVING SUM(pending) <> 0)
        ) t
    $f$, p_schema, p_ins_id, v_stu, v_fg) INTO r;
    RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.get_pending_details_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w$
  SELECT public.get_pending_details_report(p_schema, p_ins_id, p_tc, p_fee_groups, NULL::text[]);
$w$;

GRANT EXECUTE ON FUNCTION public.get_pending_details_report(text, integer, text, text[], text[])
  TO anon, authenticated;

-- ------------------------------------------------------------- VERIFY ------
-- 1. Unfiltered is unchanged, for all three. Expect true, true, true.
SELECT
  public.get_pending_payment_report('kcet20262027',1,'NOTC',NULL::text[])::text
    = public.get_pending_payment_report('kcet20262027',1,'NOTC',NULL::text[],NULL::text[])::text
      AS pending_unchanged,
  public.get_consolidated_status_report('kcet20262027',1,'NOTC',NULL::text[])::text
    = public.get_consolidated_status_report('kcet20262027',1,'NOTC',NULL::text[],NULL::text[])::text
      AS conso_unchanged,
  public.get_pending_details_report('kcet20262027',1,'NOTC',NULL::text[])::text
    = public.get_pending_details_report('kcet20262027',1,'NOTC',NULL::text[],NULL::text[])::text
      AS details_unchanged;

-- 2. The kinds partition the whole, and the two reports still agree.
SELECT k AS fee_kind,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_payment_report(
                 'kcet20262027',1,'NOTC',NULL::text[],
                 CASE WHEN k='(ALL)' THEN NULL ELSE ARRAY[k] END)) e) AS pending_payment,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_details_report(
                 'kcet20262027',1,'NOTC',NULL::text[],
                 CASE WHEN k='(ALL)' THEN NULL ELSE ARRAY[k] END)) e) AS pending_details
  FROM unnest(ARRAY['(ALL)','COL','TRA','HOS']) k
 ORDER BY 1;


-- #####################################################################
-- VERIFICATION -- every column must be true
-- #####################################################################

SELECT
  -- SECTION 1: the column exists everywhere it should, and nothing is blank.
  (SELECT count(*) = 0
     FROM information_schema.tables t
    WHERE t.table_name = 'feetype'
      AND t.table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns c
                       WHERE c.table_schema = t.table_schema
                         AND c.table_name = 'feetype' AND c.column_name = 'ordid'))
      AS ordid_on_every_schema,
  (SELECT count(*) = 0 FROM kcet20262027.feetype WHERE ordid IS NULL)
      AS nothing_unordered,

  -- SECTION 2: the eight named fee types hold 1..8, in that order.
  (SELECT count(*) = 8 FROM kcet20262027.feetype
    WHERE activestatus = 1 AND ordid BETWEEN 1 AND 8)
      AS the_eight_are_first,

  -- SECTION 3: new fee types number themselves, in every schema.
  (SELECT count(*) = 0
     FROM information_schema.columns c
    WHERE c.table_name = 'feetype' AND c.column_name = 'ordid'
      AND c.table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
      AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                       WHERE n.nspname = c.table_schema AND p.proname = 'set_fee_id'
                         AND p.prosrc LIKE '%NEW.ordid%'))
      AS trigger_fills_ordid,
  (SELECT bool_or(p.prosrc LIKE '%NEW.ordid IS NULL%')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema')
      AS generator_fills_ordid,
  (SELECT bool_or(p.prosrc LIKE '%activestatus,ins_id,ordid%')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'process_master_import')
      AS csv_order_column_used,

  -- SECTION 4 and 5: the new overloads exist AND the old ones survive, which
  -- is what lets 0.0.15 and 0.0.16 run side by side during the rollout.
  (to_regprocedure('public.get_pending_payment_report(text,integer,text,text[])') IS NOT NULL
   AND to_regprocedure('public.get_pending_details_report(text,integer,text,text[])') IS NOT NULL
   AND to_regprocedure('public.get_consolidated_status_report(text,integer,text,text[])') IS NOT NULL)
      AS fee_group_overloads,
  (to_regprocedure('public.get_pending_payment_report(text,integer,text,text[],text[])') IS NOT NULL
   AND to_regprocedure('public.get_pending_details_report(text,integer,text,text[],text[])') IS NOT NULL
   AND to_regprocedure('public.get_consolidated_status_report(text,integer,text,text[],text[])') IS NOT NULL)
      AS fee_kind_overloads,
  (to_regprocedure('public.get_pending_payment_report(text,integer,text)') IS NOT NULL
   AND to_regprocedure('public.get_pending_details_report(text,integer,text)') IS NOT NULL
   AND to_regprocedure('public.get_consolidated_status_report(text,integer,text)') IS NOT NULL)
      AS old_3arg_still_there;


-- The order the Fee Type pickers and report columns will now use. Eyeball it
-- -- this is what the office will see.
SELECT ordid, feedesc, feeshort,
       (SELECT fg.fgdesc FROM kcet20262027.feegroup fg WHERE fg.fg_id = ft.fg_id) AS fee_group
  FROM kcet20262027.feetype ft
 WHERE activestatus = 1
 ORDER BY ordid NULLS LAST, feedesc
 LIMIT 15;
