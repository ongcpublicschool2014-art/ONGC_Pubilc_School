-- A refund must reduce the collection AND re-open the demand. process_refund
-- did the first half right and the second half by INCREMENTING the balance:
--     balancedue = balancedue + refundamount
-- which is correct only when the demand was not over-collected.
--
-- Every other function in the system derives the balance instead:
--     balancedue = GREATEST(feeamount - conamount - paidamount, 0)
-- (process_concession, rebuild_demand, propagate_class_fee,
-- transfer_course_with_credit). The two agree on an ordinary refund --
-- fee 300, paid 300, refund 300 -> paid 0, balance 300 either way -- and
-- disagree when a DUPLICATE collection is refunded:
--
--     fee 300, paid 600, balance 0, refund 300
--       bal + refund  -> paid 300, balance 300   (student owes 300 again)
--       invariant     -> paid 300, balance 0     (student is square)  <-- right
--
-- kch20262027 hit exactly that (see fix_unapplied_refund_paidamount.sql):
-- ALAIMAN M I paid 62,000 against a 59,500 net fee and was refunded the 2,500
-- excess. Incrementing would have billed that 2,500 a second time.
--
-- reconbalancedue moves by however much balancedue actually moved, so it is
-- unchanged when the balance does not move and behaves exactly as before
-- otherwise. Nothing else in the function changes.
--
-- Idempotent: plain CREATE OR REPLACE, safe to run more than once.

CREATE OR REPLACE FUNCTION public.process_refund(
  p_token text, p_header jsonb, p_lines jsonb
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_rf_id integer; v_pay_id integer;
  v_total_refund numeric; v_existing numeric;
  itm RECORD; v_paid numeric; v_bal numeric; v_recon numeric;
  v_fee numeric; v_con numeric; v_newpaid numeric; v_newbal numeric; v_delta numeric;
  v_seq_id integer; v_num integer; v_scur numeric; v_sstart numeric;
  v_yrid integer; v_yrlabel text;
  v_prefix text; v_width int; v_docno text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  -- Resolve the active academic year server-side (client sends none).
  BEGIN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
      INTO v_yrid, v_yrlabel USING v_ins;
  EXCEPTION WHEN OTHERS THEN v_yrid := NULL; v_yrlabel := NULL;
  END;
  -- doc_no = formatted REFNO sequence value (prefix + padded), same shape as
  -- feedemand.demno. Atomic bump; falls back to the client value.
  EXECUTE format('SELECT seq_id, seqstart, seqcurno, seqprefix, seqwidth FROM %I.sequence WHERE ins_id=$1 AND actname=''REFNO'' AND activestatus=1 ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_sstart, v_scur, v_prefix, v_width USING v_ins;
  IF v_seq_id IS NOT NULL THEN
    v_num := (CASE WHEN COALESCE(v_scur,0) < COALESCE(v_sstart,1) THEN COALESCE(v_sstart,1) ELSE v_scur + 1 END)::integer;
    v_docno := COALESCE(v_prefix,'') || LPAD(v_num::text, COALESCE(v_width,5)::int, '0');
    EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_num, v_seq_id;
  ELSE
    v_docno := NULLIF(p_header->>'doc_no','');
  END IF;
  v_pay_id := (p_header->>'pay_id')::integer;
  v_total_refund := COALESCE((p_header->>'totalrefund')::numeric, 0);
  EXECUTE format(
    'INSERT INTO %I.fee_refund(doc_no,ins_id,inscode,yrlabel,refunddate,pay_id,paynumber,stu_id,stuadmno,stuname,stuclass,refundmode,ban_id,bankname,bankref,chequedate,accountcode,refundreason,totalrefund,totaladjust,createdby,yr_id,activestatus) '
    'VALUES($1,$2,$3,$4,NULLIF($5,'''')::date,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,NULLIF($16,'''')::date,$17,$18,$19,$20,$21,$22,1) RETURNING rf_id', v_schema)
  INTO v_rf_id USING
    v_docno, v_ins, p_header->>'inscode', COALESCE(NULLIF(p_header->>'yrlabel',''), v_yrlabel), p_header->>'refunddate',
    v_pay_id, p_header->>'paynumber', (p_header->>'stu_id')::bigint, p_header->>'stuadmno', p_header->>'stuname',
    p_header->>'stuclass', p_header->>'refundmode', NULLIF(p_header->>'ban_id','')::integer, p_header->>'bankname',
    p_header->>'bankref', p_header->>'chequedate', p_header->>'accountcode', p_header->>'refundreason',
    v_total_refund, COALESCE((p_header->>'totaladjust')::numeric, 0), p_header->>'createdby', v_yrid;
  FOR itm IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(
    dem_id bigint, refundterm text, refundfeetype text, feeamount numeric,
    refundamount numeric, adjustamount numeric, adjustreason text)
  LOOP
    EXECUTE format('INSERT INTO %I.fee_refunddetails(rf_id,dem_id,ins_id,refundterm,refundfeetype,feeamount,refundamount,adjustamount,adjustreason,activestatus) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema)
      USING v_rf_id, itm.dem_id, v_ins, itm.refundterm, itm.refundfeetype, itm.feeamount, itm.refundamount, itm.adjustamount, itm.adjustreason;
    IF COALESCE(itm.refundamount, 0) > 0 THEN
      EXECUTE format('SELECT feeamount, conamount, paidamount, balancedue, reconbalancedue FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2', v_schema)
        INTO v_fee, v_con, v_paid, v_bal, v_recon USING itm.dem_id, v_ins;
      IF v_paid IS NOT NULL THEN
        -- A refund reduces the collection and re-opens the demand -- but the
        -- balance is RECOMPUTED from the invariant the rest of the system uses
        -- (feeamount - conamount - paidamount), not incremented by the refund.
        -- The two agree whenever the demand was not over-collected. They differ
        -- when a duplicate collection is being returned (fee 300, paid 600,
        -- refund 300): the invariant leaves the balance at 0, which is right --
        -- the student is square -- while bal + refund would re-open a 300 due
        -- against someone who owes nothing. reconbalancedue moves by however
        -- much balancedue actually moved, so it is untouched in that case and
        -- behaves exactly as before in the ordinary one.
        v_newpaid := GREATEST(COALESCE(v_paid,0) - itm.refundamount, 0);
        v_newbal  := GREATEST(COALESCE(v_fee,0) - COALESCE(v_con,0) - v_newpaid, 0);
        v_delta   := v_newbal - COALESCE(v_bal,0);
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1, balancedue=$2, reconbalancedue=$3, paidstatus=$4 WHERE dem_id=$5 AND ins_id=$6', v_schema)
          USING v_newpaid, v_newbal,
                GREATEST(COALESCE(v_recon, v_bal, 0) + v_delta, 0),
                CASE WHEN v_newbal > 0 THEN 'U' ELSE 'P' END, itm.dem_id, v_ins;
      END IF;
    END IF;
  END LOOP;
  EXECUTE format('SELECT COALESCE(refund_amount,0) FROM %I.payment WHERE pay_id=$1 AND ins_id=$2', v_schema)
    INTO v_existing USING v_pay_id, v_ins;
  EXECUTE format('UPDATE %I.payment SET refund_amount=$1, paystatus=''R'' WHERE pay_id=$2 AND ins_id=$3', v_schema)
    USING COALESCE(v_existing, 0) + v_total_refund, v_pay_id, v_ins;
  RETURN v_rf_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.process_refund(text, jsonb, jsonb) TO anon, authenticated;
