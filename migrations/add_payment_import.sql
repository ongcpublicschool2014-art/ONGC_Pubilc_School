-- ============================================================================
-- Historical fee-collection (payment) import.
-- ============================================================================
-- Records a past receipt and reduces the balance on the demands it paid.
-- One call per receipt: inserts a completed + reconciled payment row, a
-- paymentdetails row per demand, and decrements feedemand
-- (paidamount / balancedue / reconbalancedue / paidstatus / pay_id) by dem_id.
-- The client resolves Demand No -> dem_id and passes p_items = [{dem_id, amount}].
-- Mirrors process_grouped_payment's feedemand update, but preserves the original
-- receipt number + date and marks it reconciled cash (paystatus='C',recon_status='R').
-- Returns the new pay_id. Run in the Supabase SQL editor.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.import_payment(
  p_ins_id integer, p_inscode text, p_stu_id integer, p_yr_id integer, p_yrlabel text,
  p_paynumber text, p_paydate timestamp, p_method text, p_reference text, p_created_by text,
  p_items jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; v_pay_id bigint; v_total numeric; it jsonb; v_dem integer; v_amt numeric;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

  SELECT COALESCE(SUM((x->>'amount')::numeric), 0) INTO v_total FROM jsonb_array_elements(p_items) x;

  -- Receipt (pay_id assigned by the set_pay_id trigger). Completed + reconciled.
  EXECUTE format(
    'INSERT INTO %I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,'
    'paydate,paystatus,paymethod,payreference,createdby,createdat,activestatus,paynumber,'
    'recon_status,reconciled_by,reconciled_date) '
    'VALUES($1,$2,$3,$4,$5,$6,''INR'',$7,''C'',$8,$9,$10,now(),1,$11,''R'',$10,$7) RETURNING pay_id', v)
    INTO v_pay_id
    USING p_ins_id, p_inscode, p_stu_id, p_yr_id, p_yrlabel, v_total, p_paydate, p_method, p_reference, p_created_by, p_paynumber;

  FOR it IN SELECT jsonb_array_elements(p_items) LOOP
    v_dem := NULLIF(it->>'dem_id','')::integer;
    v_amt := COALESCE((it->>'amount')::numeric, 0);
    IF v_dem IS NULL THEN CONTINUE; END IF;
    EXECUTE format(
      'INSERT INTO %I.paymentdetails(pay_id,dem_id,yr_id,yrlabel,ins_id,transcurrency,transtotalamount,activestatus) '
      'VALUES($1,$2,$3,$4,$5,''INR'',$6,1)', v)
      USING v_pay_id, v_dem, p_yr_id, p_yrlabel, p_ins_id, v_amt;
    EXECUTE format(
      'UPDATE %I.feedemand SET paidamount=COALESCE(paidamount,0)+$1, '
      'balancedue=GREATEST(COALESCE(balancedue,0)-$1,0), '
      'reconbalancedue=GREATEST(COALESCE(reconbalancedue,0)-$1,0), '
      'paidstatus=CASE WHEN GREATEST(COALESCE(balancedue,0)-$1,0) <= 0 THEN ''P'' ELSE ''U'' END, '
      'pay_id=$2 WHERE dem_id=$3 AND activestatus=1', v)
      USING v_amt, v_pay_id, v_dem;
  END LOOP;

  RETURN v_pay_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.import_payment(integer,text,integer,integer,text,text,timestamp,text,text,text,jsonb) TO anon, authenticated;

NOTIFY pgrst, 'reload config';
