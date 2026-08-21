-- ============================================================================
-- Phase 1b — session-gated ATOMIC refund (Group A).
-- ============================================================================
-- The client does a refund as 4 separate anon writes (fee_refund header +
-- fee_refunddetails + payment update + per-demand feedemand re-open). This does
-- all of it in ONE SECURITY DEFINER function, gated by the session token, with
-- ins_id derived server-side. p_header/p_lines are the same maps the client
-- built. Returns the new rf_id. Requires secure_app_session.sql. Idempotent def.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_refund(
  p_token text, p_header jsonb, p_lines jsonb
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_rf_id integer; v_pay_id integer;
  v_total_refund numeric; v_existing numeric;
  itm RECORD; v_paid numeric; v_bal numeric; v_recon numeric;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_pay_id := (p_header->>'pay_id')::integer;
  v_total_refund := COALESCE((p_header->>'totalrefund')::numeric, 0);

  -- 1. Refund header (ins_id forced from the session)
  EXECUTE format(
    'INSERT INTO %I.fee_refund(doc_no,ins_id,inscode,yrlabel,refunddate,pay_id,paynumber,stu_id,stuadmno,stuname,stuclass,refundmode,ban_id,bankname,bankref,chequedate,accountcode,refundreason,totalrefund,totaladjust,createdby,activestatus) '
    'VALUES($1,$2,$3,$4,NULLIF($5,'''')::date,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,NULLIF($16,'''')::date,$17,$18,$19,$20,$21,1) RETURNING rf_id', v_schema)
  INTO v_rf_id USING
    (p_header->>'doc_no')::integer, v_ins, p_header->>'inscode', p_header->>'yrlabel', p_header->>'refunddate',
    v_pay_id, p_header->>'paynumber', (p_header->>'stu_id')::bigint, p_header->>'stuadmno', p_header->>'stuname',
    p_header->>'stuclass', p_header->>'refundmode', NULLIF(p_header->>'ban_id','')::integer, p_header->>'bankname',
    p_header->>'bankref', p_header->>'chequedate', p_header->>'accountcode', p_header->>'refundreason',
    v_total_refund, COALESCE((p_header->>'totaladjust')::numeric, 0), p_header->>'createdby';

  -- 2. Detail lines + 4. re-open each refunded demand (money returned = owed again)
  FOR itm IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(
    dem_id bigint, refundterm text, refundfeetype text, feeamount numeric,
    refundamount numeric, adjustamount numeric, adjustreason text)
  LOOP
    EXECUTE format('INSERT INTO %I.fee_refunddetails(rf_id,dem_id,ins_id,refundterm,refundfeetype,feeamount,refundamount,adjustamount,adjustreason,activestatus) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema)
      USING v_rf_id, itm.dem_id, v_ins, itm.refundterm, itm.refundfeetype, itm.feeamount, itm.refundamount, itm.adjustamount, itm.adjustreason;

    IF COALESCE(itm.refundamount, 0) > 0 THEN
      EXECUTE format('SELECT paidamount, balancedue, reconbalancedue FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2', v_schema)
        INTO v_paid, v_bal, v_recon USING itm.dem_id, v_ins;
      IF v_paid IS NOT NULL THEN
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1, balancedue=$2, reconbalancedue=$3, paidstatus=$4 WHERE dem_id=$5 AND ins_id=$6', v_schema)
          USING GREATEST(COALESCE(v_paid,0) - itm.refundamount, 0),
                COALESCE(v_bal,0) + itm.refundamount,
                COALESCE(v_recon, v_bal, 0) + itm.refundamount,
                CASE WHEN COALESCE(v_bal,0) + itm.refundamount > 0 THEN 'U' ELSE 'P' END,
                itm.dem_id, v_ins;
      END IF;
    END IF;
  END LOOP;

  -- 3. Mark the receipt refunded + accumulate refund_amount
  EXECUTE format('SELECT COALESCE(refund_amount,0) FROM %I.payment WHERE pay_id=$1 AND ins_id=$2', v_schema)
    INTO v_existing USING v_pay_id, v_ins;
  EXECUTE format('UPDATE %I.payment SET refund_amount=$1, paystatus=''R'' WHERE pay_id=$2 AND ins_id=$3', v_schema)
    USING COALESCE(v_existing, 0) + v_total_refund, v_pay_id, v_ins;

  RETURN v_rf_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.process_refund(text, jsonb, jsonb) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
