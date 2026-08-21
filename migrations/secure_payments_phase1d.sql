-- ============================================================================
-- Phase 1d — session-gated PAYMENT pre-completion writes (Group A, Paytm-only).
-- ============================================================================
-- These are the payment-row bookkeeping writes AROUND the gateway flow (create
-- the 'I' row, stamp the order id, mark 'F' on failure, record cheque/tender
-- details). The money-critical transition to 'C' (completed) is NOT here — it
-- happens only inside complete_payment_grouped, which re-derives paid amounts
-- from the demands. So update_payment deliberately:
--   * WHITELISTS a fixed set of non-money columns, and
--   * REJECTS paystatus 'C'/'R' (completion/refund go through their own RPCs).
-- This closes the forgery hole (a client can't UPDATE a payment to completed or
-- rewrite its amount) while still letting the gateway flow do its bookkeeping.
-- Requires secure_app_session.sql. Idempotent.
-- ============================================================================

-- insert_payment: create the temporary 'I' payment row. ins_id forced; any
-- client pay_id/paystatus is ignored (status is always born 'I').
CREATE OR REPLACE FUNCTION public.insert_payment(
  p_token text, p_data jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_id bigint;
  v_data jsonb; v_cols text; v_sel text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_data := (p_data - 'pay_id') || jsonb_build_object('ins_id', v_ins, 'paystatus', 'I');

  SELECT string_agg(quote_ident(column_name), ','),
         string_agg('r.' || quote_ident(column_name), ',')
    INTO v_cols, v_sel
    FROM information_schema.columns
   WHERE table_schema = v_schema AND table_name = 'payment' AND v_data ? column_name;

  EXECUTE format(
    'INSERT INTO %I.payment (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.payment, $1) r RETURNING pay_id',
    v_schema, v_cols, v_sel, v_schema)
  INTO v_id USING v_data;
  RETURN v_id;
END; $$;

-- update_payment: whitelisted pre-completion field updates on one payment row.
CREATE OR REPLACE FUNCTION public.update_payment(
  p_token text, p_pay_id bigint, p_data jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_data jsonb; v_set text;
  c_allowed text[] := ARRAY[
    'payorderid','payreference','paychequeno','paychequedate',
    'paybankname','tender_amount','refund_amount','paystatus'
  ];
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- A client may only ever move a payment to a NON-completed state. Completion
  -- ('C') is exclusively complete_payment_grouped; refund ('R') is process_refund.
  IF p_data ? 'paystatus' AND (p_data->>'paystatus') NOT IN ('F','I','P') THEN
    RAISE EXCEPTION 'update_payment cannot set paystatus=%', p_data->>'paystatus';
  END IF;

  -- Keep only whitelisted keys (drops transtotalamount, paidamount, etc.).
  SELECT jsonb_object_agg(key, value) INTO v_data
    FROM jsonb_each(p_data) WHERE key = ANY(c_allowed);
  IF v_data IS NULL THEN RETURN; END IF;

  SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
    INTO v_set
    FROM information_schema.columns
   WHERE table_schema = v_schema AND table_name = 'payment' AND v_data ? column_name;
  IF v_set IS NULL THEN RETURN; END IF;

  EXECUTE format(
    'UPDATE %I.payment t SET %s FROM jsonb_populate_record(NULL::%I.payment, $1) r WHERE t.pay_id=$2 AND t.ins_id=$3',
    v_schema, v_set, v_schema)
  USING v_data, p_pay_id, v_ins;
END; $$;

-- fail_pending_payments: release a student's pending lock by marking every
-- not-completed ('I') attempt failed. Scoped to the session's institution.
CREATE OR REPLACE FUNCTION public.fail_pending_payments(
  p_token text, p_stu_id bigint
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  EXECUTE format(
    'UPDATE %I.payment SET paystatus=''F'' WHERE ins_id=$1 AND stu_id=$2 AND paystatus=''I''', v_schema)
  USING v_ins, p_stu_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.insert_payment(text, jsonb)                TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_payment(text, bigint, jsonb)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_pending_payments(text, bigint)        TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
