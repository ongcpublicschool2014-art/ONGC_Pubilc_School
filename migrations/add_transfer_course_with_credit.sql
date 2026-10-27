-- Interim Promotion → Course Transfer with carried credit.
--
-- When a student who has already PAID part of their current course is
-- transferred to a new course, the amount already paid is carried forward
-- against the NEW course's fees. In college the new class's classfeedemand is
-- mostly 0, so the new fee amounts are TYPED per student on the Adjust Fees page
-- and passed in p_credits[].feeamt (classfeedemand is read only for metadata and
-- NEVER modified). Done atomically in one SECURITY DEFINER transaction so
-- balances can never be left half-moved.
--
-- Money model (paid cash counted exactly once):
--   1. Settle / drop the old course's active demands:
--        * paid > 0  -> KEEP the record, reduce feeamount down to the paid
--          amount so balancedue = 0 and it reads as a fully-Paid historical
--          demand (e.g. 30000/paid 3000 -> 3000/3000/0). The unpaid remainder is
--          written off (student left the course).
--        * paid = 0  -> DELETE the record (nothing was collected).
--   2. Move the student to the new class/course.
--   3. Create the new course's demands from the client amounts:
--          feeamount = feeamt ; conamount = credit ; paidamount = 0
--          balancedue = feeamount − conamount
--      The client already reduced feeamt by the matching OLD PAID (VB col8 -= paid),
--      so the paid cash is not double-counted — it stays as paidamount on the kept
--      old demands. `credit` is the fee's concession. Only fees with feeamt > 0
--      (and ticked on the client) are created.
--   4. Log the transfer in interim_promotion (with the ORIGINAL course/class).
--
-- p_credits: [{"cf_id": int, "feeamt": numeric, "credit": numeric}]
--   feeamt = new-course fee amount ALREADY reduced by old paid (VB col8 -= paid)
--   credit = concession for this fee (manual / carried)
--
-- The real payment records (the money actually collected) are LEFT UNTOUCHED as
-- historical collection. `leftover_credit` in the result is any old-paid not
-- applied to new fees — refund that separately.

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
  --    demand to the paid amount (balance 0, Paid) so it stays a settled record.
  EXECUTE format('DELETE FROM %I.feedemand WHERE stu_id=$1 AND activestatus=1 AND COALESCE(paidamount,0)=0', v)
    USING p_stu_id;
  EXECUTE format($u$UPDATE %I.feedemand
      SET feeamount=paidamount, conamount=0, balancedue=0, reconbalancedue=0, paidstatus='P'
      WHERE stu_id=$1 AND activestatus=1 AND COALESCE(paidamount,0)>0$u$, v)
    USING p_stu_id;

  -- 2) Move the student to the new class/course.
  EXECUTE format('UPDATE %I.students SET stuclass=$1, courname=$2 WHERE stu_id=$3', v)
    USING p_target_class, p_target_course, p_stu_id;

  -- 3) Create the new course demands. feeamt already = new fee − old paid (client,
  --    VB col8 -= paid); credit = concession. feeamount=feeamt, conamount=credit,
  --    balancedue=feeamt-credit, paidamount=0. classfeedemand is read-only.
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
    USING p_ins_id, v_inscode, v_yr_id, p_stu_id, v_stuadmno, p_target_class, v_yrlabel, cf.cfterm, cf.cffeetype,
          cf.feeamt, v_con_id, v_credit, cf.cfdduedate, p_created_by, COALESCE(cf.collectible, true),
          cf.cla_id, cf.sem_id, cf.fee_id, cf.cf_id, p_target_course;
    v_new_count := v_new_count + 1;
  END LOOP;

  -- 4) Log the transfer (with the ORIGINAL course/class).
  EXECUTE format($l$
    INSERT INTO %I.interim_promotion
      (doc_no, ins_id, promotiondate, stu_id, stuadmno, courname, stuclass, stuname,
       transferred_courname, transferred_class, remarks, createdby, activestatus)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,1)
  $l$, v)
  USING p_doc_no, p_ins_id, p_promotion_date, p_stu_id, v_stuadmno, v_old_course, v_old_class, v_stuname,
        p_target_course, p_target_class, NULLIF(btrim(COALESCE(p_remarks, '')), ''), p_created_by;

  RETURN jsonb_build_object('new_demands', v_new_count, 'applied', v_applied,
                            'old_paid', v_paid, 'leftover_credit', v_remaining);
END;
$$;

GRANT EXECUTE ON FUNCTION public.transfer_course_with_credit(integer, bigint, text, text, jsonb, integer, date, text, text)
  TO anon, authenticated;
