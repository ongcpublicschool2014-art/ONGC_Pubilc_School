-- ============================================================================
-- NEXT_UPDATE_LIVE.sql  — run on LIVE before deploying the desktop 0.0.6 build.
-- Bundles the two migrations held for this build. Both are idempotent
-- (CREATE OR REPLACE + ADD COLUMN IF NOT EXISTS), so re-running is harmless.
--   1) transfer_course_admission_type.sql  — Student/Course Transfer admission type
--   2) pending_details_seqtype.sql          — Pending Details Regular/Arrear filter
-- Run on TEST first. Each part ends with its own verify SELECT.
-- ============================================================================

-- ===== PART A: transfer_course_admission_type.sql =====
-- ============================================================================
-- Course Transfer: carry the ADMISSION TYPE, and log it.
--
-- PART 1 adds two audit columns to interim_promotion (the transfer log):
--   admname             -- the type the student held BEFORE the transfer
--   transferred_admname -- the type they hold after
-- The log already keeps before/after course and class; without these two the
-- reason for a fee change is unrecoverable once the student row has moved on,
-- because students.admname only ever holds the CURRENT value.
--
-- Applied to every institution schema that has the table, so a second
-- institution is picked up automatically. IF NOT EXISTS -> safe to re-run.
--
-- PART 2 replaces transfer_course_with_credit: one new trailing parameter,
-- p_target_adm_id (NULL = leave the admission type unchanged, so it is a no-op
-- for any caller that does not send it). When set, the student's
-- adm_id/admname and the matching public.admission row's admtype_id/admname
-- move with the course, and both names are written to the log.
--
-- The admname is resolved from the admissiontype master inside the function
-- rather than trusted from the client: students and admission each carry a
-- denormalised copy of the name and they must not drift apart.
--
-- DROP + CREATE, not CREATE OR REPLACE: Postgres cannot change a function's
-- parameter COUNT in place. The DROP names the exact 9-argument signature so
-- it cannot hit anything else.
--
-- SAFE TO RE-RUN. Run on TEST first.
-- ============================================================================

-- ---------- PART 1: audit columns -----------------------------------------
DO $mig$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT table_schema FROM information_schema.tables
     WHERE table_name = 'interim_promotion'
  LOOP
    EXECUTE format('ALTER TABLE %I.interim_promotion '
                   'ADD COLUMN IF NOT EXISTS admname varchar(30)', s);
    EXECUTE format('ALTER TABLE %I.interim_promotion '
                   'ADD COLUMN IF NOT EXISTS transferred_admname varchar(30)', s);
    RAISE NOTICE 'interim_promotion patched in %', s;
  END LOOP;
END $mig$;

-- ---------- PART 2: the transfer function ---------------------------------
DROP FUNCTION IF EXISTS public.transfer_course_with_credit(
  integer, bigint, text, text, jsonb, integer, date, text, text);

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
  integer, bigint, text, text, jsonb, integer, date, text, text, smallint)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify 1: expects ONE row, args ending in "p_target_adm_id smallint"
SELECT p.proname,
       p.prosecdef                                      AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
       pg_get_function_identity_arguments(p.oid)        AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'transfer_course_with_credit';

-- Verify 2: expects both columns present in every institution schema
SELECT table_schema, column_name
  FROM information_schema.columns
 WHERE table_name = 'interim_promotion'
   AND column_name IN ('admname','transferred_admname')
 ORDER BY table_schema, column_name;

-- ===== PART B: pending_details_seqtype.sql =====
-- ============================================================================
-- Pending Details report: expose REGULAR vs ARREAR.
--
-- WHY: the report could not be filtered to arrear-only or regular-only,
-- because the RPC collapsed both into one figure per fee type. Adding
-- demseqtype to the projection (and the GROUP BY) lets the client split them.
--
-- NULL/blank demseqtype is reported as REGULAR: rows written before the column
-- existed are all current-year demands, and treating them as neither would
-- make them vanish from both halves of the filter.
--
-- Same signature, so CREATE OR REPLACE is enough -- no DROP, no downtime.
--
-- NOTE for the client: a student can now return TWO rows for the same fee type
-- (one REGULAR, one ARREAR). Anything pivoting this must ACCUMULATE per fee
-- type, not assign.
--
-- SAFE TO RE-RUN. Run on TEST first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_pending_details_report(
    p_schema TEXT, p_ins_id INT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json;
BEGIN
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
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
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
    $f$, p_schema, p_ins_id) INTO r;
    RETURN r;
END $$;

GRANT EXECUTE ON FUNCTION public.get_pending_details_report(TEXT, INT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify: every row should carry a demseqtype of REGULAR or ARREAR.
SELECT DISTINCT value->>'demseqtype' AS demseqtype
  FROM json_array_elements(
         public.get_pending_details_report('kcet20262027', 1)
       ) AS value
 ORDER BY 1;
