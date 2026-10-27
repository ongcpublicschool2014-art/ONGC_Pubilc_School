-- Course Transfer: two fixes to transfer_course_with_credit.
--
-- 1) ONE history row per student per DATE. It always INSERTed into
--    interim_promotion, so transferring the same student twice on one day left
--    two rows. The VB original (frmClassTransfer) keys studhist on
--    studid + tdate and UPDATEs an existing same-date row instead; this matches
--    that, and mirrors the same-day rule New Roll Number enforces with
--    uq_rollno_change_day.
--
-- 2) New demands are always COLLECTIBLE. classfeedemand.collectible defaults to
--    FALSE, and the transfer inherited it -- so the fees the operator had just
--    ticked and priced never showed up in Fee Collection and could not be paid.
--
-- DB-only, no schema change; safe to re-run.

CREATE OR REPLACE FUNCTION public.transfer_course_with_credit(
  p_ins_id integer, p_stu_id bigint,
  p_target_class text, p_target_course text,
  p_credits jsonb,            -- [{"cf_id": int, "feeamt": numeric, "credit": numeric}]
  p_doc_no integer, p_promotion_date date,
  p_created_by text, p_remarks text
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
      cour_id = COALESCE((SELECT cour_id FROM tc), (SELECT cour_id FROM co), s.cour_id)
    WHERE s.stu_id = $3
  $su$, v)
    USING p_target_class, p_target_course, p_stu_id;

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
      cour_id = COALESCE((SELECT cour_id FROM tc), (SELECT cour_id FROM co), a.cour_id)
    WHERE a.ins_id = $3 AND a.activestatus = 1
      AND a.admno = $4
  $ad$, v)
    USING p_target_class, p_target_course, p_ins_id, v_stuadmno;

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
      createdby = $12, activestatus = 1
    WHERE ins_id = $2 AND stu_id = $4 AND promotiondate = $3
  $l$, v)
  USING p_doc_no, p_ins_id, p_promotion_date, p_stu_id, v_stuadmno, v_old_course, v_old_class, v_stuname,
        p_target_course, p_target_class, NULLIF(btrim(COALESCE(p_remarks, '')), ''), p_created_by;
  GET DIAGNOSTICS v_log_rows = ROW_COUNT;
  IF v_log_rows = 0 THEN
    EXECUTE format($l$
      INSERT INTO %I.interim_promotion
        (doc_no, ins_id, promotiondate, stu_id, stuadmno, courname, stuclass, stuname,
         transferred_courname, transferred_class, remarks, createdby, activestatus)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,1)
    $l$, v)
    USING p_doc_no, p_ins_id, p_promotion_date, p_stu_id, v_stuadmno, v_old_course, v_old_class, v_stuname,
          p_target_course, p_target_class, NULLIF(btrim(COALESCE(p_remarks, '')), ''), p_created_by;
  END IF;

  RETURN jsonb_build_object('new_demands', v_new_count, 'applied', v_applied,
                            'old_paid', v_paid, 'leftover_credit', v_remaining);
END;
$$;
GRANT EXECUTE ON FUNCTION public.transfer_course_with_credit(integer, bigint, text, text, jsonb, integer, date, text, text)
  TO anon, authenticated;
