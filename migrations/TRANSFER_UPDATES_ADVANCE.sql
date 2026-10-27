-- ############################################################################
-- EduCore360 -- COURSE TRANSFER ALSO MOVES THE STUDENT'S ADVANCES, 19-09-2026
--
-- public.transfer_course_with_credit already moves the student's class and
-- course onto students, public.admission and the new fee demands. It did not
-- touch advance_collection, which carries stuclass / courname of its own --
-- and both the Advance Collection and the Advance Adjustment screens FILTER on
-- those columns rather than joining students.
--
-- The effect: transfer a student who is holding an advance and the advance
-- stays filed under the class they left. It disappears from the new class's
-- list, and from the Advance Adjustment grid, while the money is still on it.
--
-- One statement is added, as step 2c. Nothing else in the function changes;
-- the body below is otherwise exactly what is in C:\pg_backups\complete_setup.sql.
--
--   * advance_detail and advadjustment hold no class or course column, so
--     there is nothing on them to move.
--   * payment and misc_collection are NOT touched. A receipt is a document
--     that was issued to a student in a class on a day, and rewriting the
--     class on it would change what was printed. An advance is different --
--     it is a live balance that has to be found and spent.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE, one function, no data change of its own.
-- Applied and checked on the TEST project first.
-- ############################################################################


-- ############################################################################
-- BEFORE (READ-ONLY) -- advances whose class no longer matches their student.
-- These are the ones already stranded; run the FIX at the bottom to move them.
-- ############################################################################
DO $before$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'advance_collection'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(*) FROM %I.advance_collection a
        JOIN %I.students s ON s.stu_id = a.stu_id
       WHERE a.stuclass IS DISTINCT FROM s.stuclass
          OR a.courname IS DISTINCT FROM s.courname $q$, r.s, r.s) INTO n;
    RAISE NOTICE '%: % advance row(s) filed under the wrong class', r.s, n;
  END LOOP;
END $before$;


-- ############################################################################
-- THE FUNCTION
-- ############################################################################
CREATE OR REPLACE FUNCTION public.transfer_course_with_credit(
  p_ins_id integer, p_stu_id bigint,
  p_target_class text, p_target_course text,
  p_credits jsonb,            -- [{"cf_id": int, "feeamt": numeric, "credit": numeric}]
  p_doc_no integer, p_promotion_date date,
  p_created_by text, p_remarks text,
  p_target_adm_id smallint DEFAULT NULL   -- NULL = leave admission type unchanged
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '60s'
AS $$
DECLARE
  v text;
  v_paid numeric; v_remaining numeric; v_applied numeric := 0; v_new_count int := 0;
  v_stuadmno text; v_stuname text; v_old_course text; v_old_class text;
  v_log_rows integer;
  v_yr_id int; v_yrlabel text; v_inscode text; v_con_id int; v_admname text; v_adm_id smallint;
  v_new_admname text;
  cf RECORD; v_credit numeric;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

  EXECUTE format('SELECT stuadmno, stuname, courname, stuclass, yr_id, yrlabel, inscode, con_id, admname, adm_id FROM %I.students WHERE stu_id=$1', v)
    INTO v_stuadmno, v_stuname, v_old_course, v_old_class, v_yr_id, v_yrlabel, v_inscode, v_con_id, v_admname, v_adm_id
    USING p_stu_id;
  IF v_stuadmno IS NULL THEN RAISE EXCEPTION 'Student % not found', p_stu_id; END IF;

  -- The credit pool = what the student already paid on the current course.
  EXECUTE format('SELECT COALESCE(SUM(paidamount),0) FROM %I.feedemand WHERE stu_id=$1 AND activestatus=1', v)
    INTO v_paid USING p_stu_id;
  v_remaining := v_paid;

  -- 1) Settle / drop the old course demands.
  --    paid = 0 -> delete (nothing collected); paid > 0 -> keep but reduce the
  --    demand to the paid amount (balance 0, Paid) as a settled record.
  EXECUTE format('DELETE FROM %I.feedemand WHERE stu_id=$1 AND activestatus=1 AND COALESCE(paidamount,0)=0', v)
    USING p_stu_id;
  EXECUTE format($u$UPDATE %I.feedemand
      SET feeamount=paidamount, conamount=0, balancedue=0, reconbalancedue=0, paidstatus='P'
      WHERE stu_id=$1 AND activestatus=1 AND COALESCE(paidamount,0)>0$u$, v)
    USING p_stu_id;

  -- 2) Move the student to the new class/course (names + resolved ids). cla_id
  --    and cour_id come from the target class (class.cla_id / class.cour_id),
  --    else a course-name match, else kept as-is.
  -- 2a-i) Resolve the target admission type's NAME once. students.admname and
  --       public.admission.admname are denormalised copies, so moving adm_id
  --       without the name would leave the two disagreeing -- and several
  --       reports read the NAME, not the id.
  IF p_target_adm_id IS NOT NULL THEN
    EXECUTE format('SELECT admname FROM %I.admissiontype WHERE adm_id = $1', v)
      INTO v_new_admname USING p_target_adm_id;
  END IF;

  EXECUTE format($su$
    WITH tc AS (
      SELECT cl.cla_id, cl.cour_id FROM %1$I.class cl
      WHERE UPPER(TRIM(cl.claname)) = UPPER(TRIM($1)) AND cl.activestatus = 1
      ORDER BY cl.cla_id LIMIT 1
    ), co AS (
      SELECT c.cour_id FROM %1$I.course c
      WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM($2)) AND c.activestatus = 1
      ORDER BY c.cour_id LIMIT 1
    )
    UPDATE %1$I.students s SET
      stuclass = $1, courname = $2,
      cla_id  = COALESCE((SELECT cla_id  FROM tc), s.cla_id),
      cour_id = COALESCE((SELECT cour_id FROM tc), (SELECT cour_id FROM co), s.cour_id),
      adm_id  = COALESCE($4::smallint, s.adm_id),
      admname = COALESCE($5, s.admname)
    WHERE s.stu_id = $3
  $su$, v)
    USING p_target_class, p_target_course, p_stu_id, p_target_adm_id, v_new_admname;

  -- 2b) Mirror the move onto the student's admission record (public.admission),
  --     so the admission table's course/class stay in sync with the transfer.
  --     Matched by admission number (admno = student's stuadmno, unique per
  --     institution) because allocated admissions often carry a NULL stu_id;
  --     a stu_id match is kept as a fallback. cour_id / cla_id are refreshed
  --     from the schema masters; admit_cour_id (the originally-admitted course)
  --     is deliberately left unchanged.
  EXECUTE format($ad$
    WITH tc AS (
      SELECT cl.cla_id, cl.cour_id
      FROM %1$I.class cl
      WHERE UPPER(TRIM(cl.claname)) = UPPER(TRIM($1)) AND cl.activestatus = 1
      ORDER BY cl.cla_id LIMIT 1
    ), co AS (
      SELECT c.cour_id
      FROM %1$I.course c
      WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM($2)) AND c.activestatus = 1
      ORDER BY c.cour_id LIMIT 1
    )
    UPDATE public.admission a SET
      courname = $2, stuclass = $1, allocatedclass = $1,
      cla_id  = COALESCE((SELECT cla_id  FROM tc), a.cla_id),
      cour_id = COALESCE((SELECT cour_id FROM tc), (SELECT cour_id FROM co), a.cour_id),
      admtype_id = COALESCE($5::smallint, a.admtype_id),
      admname    = COALESCE($6, a.admname)
    WHERE a.ins_id = $3 AND a.activestatus = 1
      AND a.admno = $4
  $ad$, v)
    USING p_target_class, p_target_course, p_ins_id, v_stuadmno,
          p_target_adm_id, v_new_admname;

  -- 2c) And onto the student's ADVANCES.
  --
  --     advance_collection carries stuclass / courname of its own, and both
  --     the Advance Collection and Advance Adjustment screens filter on those
  --     columns rather than joining students. Left alone, a transferred
  --     student's advance stays filed under the class they left: it vanishes
  --     from the new class's list while money is still sitting on it.
  --
  --     Every row for the student is moved, cancelled ones included, so the
  --     two screens and the advance report agree about which class an advance
  --     belongs to. advance_detail and advadjustment hold no class or course
  --     column, so there is nothing on them to move.
  --
  --     Guarded by to_regclass: an institution schema created before the
  --     advance module exists has no such table, and a transfer must not fail
  --     because of it.
  IF to_regclass(format('%I.advance_collection', v)) IS NOT NULL THEN
    EXECUTE format($av$
      UPDATE %1$I.advance_collection a
         SET stuclass = $1, courname = $2
       WHERE a.stu_id = $3
         AND (a.stuclass IS DISTINCT FROM $1 OR a.courname IS DISTINCT FROM $2)
    $av$, v)
      USING p_target_class, p_target_course, p_stu_id;
  END IF;

  -- 3) Create the new course demands from the client amounts. The client already
  --    reduced feeamt by the matching OLD PAID (VB col8 -= paid); credit is the
  --    fee's concession (feeamount = feeamt, conamount = credit,
  --    balancedue = feeamt - credit, paidamount = 0). classfeedemand read-only.
  FOR cf IN EXECUTE format($q$
      SELECT c.cf_id, c.cfterm, c.cffeetype, c.cfdduedate, c.collectible,
             c.cla_id, c.sem_id, c.fee_id,
             (it->>'feeamt')::numeric AS feeamt,
             COALESCE((it->>'credit')::numeric, 0) AS credit
      FROM jsonb_array_elements($1::jsonb) it
      JOIN %I.classfeedemand c ON c.cf_id = (it->>'cf_id')::int
      WHERE (it->>'feeamt')::numeric > 0
      ORDER BY c.cf_id
    $q$, v) USING p_credits
  LOOP
    -- Concession = old paid + old concession carried (client capped at the fee).
    v_credit := LEAST(GREATEST(cf.credit, 0), cf.feeamt);
    v_applied := v_applied + v_credit;
    v_remaining := GREATEST(v_remaining - v_credit, 0);

    EXECUTE format($i$
      INSERT INTO %I.feedemand
        (demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, demfeeyear, demfeeterm, demfeetype,
         feeamount, con_id, conamount, paidamount, balancedue, reconbalancedue, duedate, paidstatus,
         createdby, activestatus, collectible, cla_id, sem_id, fee_id, cf_id, courname)
      VALUES ('REGULAR',$1,$2,$3,$4,$5,$6,$7,$8,$9,
              $10,$11,$12,0,GREATEST($10-$12,0),GREATEST($10-$12,0),$13,
              CASE WHEN $10-$12<=0 THEN 'P' ELSE 'U' END,
              $14,1,$15,$16,$17,$18,$19,$20)
    $i$, v)
    -- collectible is forced TRUE, not inherited from classfeedemand: that column
    -- defaults to FALSE, and these demands are the fees the operator explicitly
    -- ticked and priced on the Adjust Fees page. Inheriting false made them
    -- invisible to Fee Collection, so the student could never pay them.
    USING p_ins_id, v_inscode, v_yr_id, p_stu_id, v_stuadmno, p_target_class, v_yrlabel, cf.cfterm, cf.cffeetype,
          cf.feeamt, v_con_id, v_credit, cf.cfdduedate, p_created_by, true,
          cf.cla_id, cf.sem_id, cf.fee_id, cf.cf_id, p_target_course;
    v_new_count := v_new_count + 1;
  END LOOP;

  -- 4) Log the transfer (with the ORIGINAL course/class). One row per student
  --    per date: a second transfer on the same day UPDATES that day's row
  --    instead of adding a duplicate (the VB frmClassTransfer rule — studhist
  --    is keyed on studid + tdate).
  EXECUTE format($l$
    UPDATE %I.interim_promotion SET
      doc_no = $1, stuadmno = $5, courname = $6, stuclass = $7, stuname = $8,
      transferred_courname = $9, transferred_class = $10, remarks = $11,
      createdby = $12, activestatus = 1,
      admname = $13, transferred_admname = $14
    WHERE ins_id = $2 AND stu_id = $4 AND promotiondate = $3
  $l$, v)
  USING p_doc_no, p_ins_id, p_promotion_date, p_stu_id, v_stuadmno, v_old_course, v_old_class, v_stuname,
        p_target_course, p_target_class, NULLIF(btrim(COALESCE(p_remarks, '')), ''), p_created_by,
        v_admname, COALESCE(v_new_admname, v_admname);
  GET DIAGNOSTICS v_log_rows = ROW_COUNT;
  IF v_log_rows = 0 THEN
    EXECUTE format($l$
      INSERT INTO %I.interim_promotion
        (doc_no, ins_id, promotiondate, stu_id, stuadmno, courname, stuclass, stuname,
         transferred_courname, transferred_class, remarks, createdby, activestatus,
         admname, transferred_admname)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,1,$13,$14)
    $l$, v)
    USING p_doc_no, p_ins_id, p_promotion_date, p_stu_id, v_stuadmno, v_old_course, v_old_class, v_stuname,
          p_target_course, p_target_class, NULLIF(btrim(COALESCE(p_remarks, '')), ''), p_created_by,
          v_admname, COALESCE(v_new_admname, v_admname);
  END IF;

  RETURN jsonb_build_object('new_demands', v_new_count, 'applied', v_applied,
                            'old_paid', v_paid, 'leftover_credit', v_remaining);
END;
$$;

GRANT EXECUTE ON FUNCTION public.transfer_course_with_credit(
  integer, bigint, text, text, jsonb, integer, date, text, text, smallint
) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- FIX THE ROWS ALREADY STRANDED -- transfers done before this update left
-- their advances behind. This moves each one onto its student's current class.
-- It changes DATA, so read the BEFORE output first and run this only if the
-- count it printed is what you expect.
-- ############################################################################
DO $fix$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'advance_collection'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      UPDATE %I.advance_collection a
         SET stuclass = s.stuclass, courname = s.courname
        FROM %I.students s
       WHERE s.stu_id = a.stu_id
         AND (a.stuclass IS DISTINCT FROM s.stuclass
           OR a.courname IS DISTINCT FROM s.courname) $q$, r.s, r.s);
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '%: % advance row(s) moved', r.s, n;
  END LOOP;
END $fix$;


-- ############################################################################
-- VERIFY -- carries_the_advance_step must read t, and the count must be 0.
-- ############################################################################
SELECT p.prosrc LIKE '%advance_collection%' AS carries_the_advance_step
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'transfer_course_with_credit';

DO $after$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'advance_collection'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(*) FROM %I.advance_collection a
        JOIN %I.students s ON s.stu_id = a.stu_id
       WHERE a.stuclass IS DISTINCT FROM s.stuclass
          OR a.courname IS DISTINCT FROM s.courname $q$, r.s, r.s) INTO n;
    RAISE NOTICE '%: % still mismatched (should be 0)', r.s, n;
  END LOOP;
END $after$;
