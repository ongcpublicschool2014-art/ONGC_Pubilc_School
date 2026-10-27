-- Bank Reconciliation: show ALL reconciled payments, not just the newest 100.
--
-- get_bank_recon_data returns a single json object {pending, reconciled}. The
-- whole value is one JSON (not subject to PostgREST's 1000-row cap), but the
-- reconciled sub-select had a hard `LIMIT 100`, so the Reconciled tab only ever
-- showed 100 rows. Dropping the limit returns every reconciled payment; pending
-- was already unlimited.

CREATE OR REPLACE FUNCTION public.get_bank_recon_data(p_ins_id integer) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; r json;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN '{}'::json; END IF;
  EXECUTE format('SELECT json_build_object(
    ''pending'', COALESCE((SELECT json_agg(t) FROM (SELECT p.pay_id,p.paynumber,p.transtotalamount,p.paydate,p.paymethod,p.payreference,p.paychequeno,p.payorderid,p.stu_id,p.createdby,p.recon_status,s.stuname,s.stuadmno FROM %I.payment p LEFT JOIN %I.students s ON s.stu_id=p.stu_id AND s.ins_id=p.ins_id WHERE p.ins_id=$1 AND p.paystatus=''C'' AND p.recon_status=''P'' AND p.activestatus=1 ORDER BY p.paydate DESC) t), ''[]''::json),
    ''reconciled'', COALESCE((SELECT json_agg(t) FROM (SELECT p.pay_id,p.paynumber,p.transtotalamount,p.paydate,p.paymethod,p.payreference,p.stu_id,p.createdby,p.recon_status,p.reconciled_by,p.reconciled_date,p.bank_reference,s.stuname,s.stuadmno FROM %I.payment p LEFT JOIN %I.students s ON s.stu_id=p.stu_id AND s.ins_id=p.ins_id WHERE p.ins_id=$1 AND p.paystatus=''C'' AND p.recon_status=''R'' AND p.activestatus=1 ORDER BY p.reconciled_date DESC) t), ''[]''::json)
  )', v, v, v, v) INTO r USING p_ins_id;
  RETURN COALESCE(r, '{}'::json);
END; $$;
