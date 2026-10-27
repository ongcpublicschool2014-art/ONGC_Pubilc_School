-- =====================================================================
-- RPCs for the paytm-webhook edge function.
--
-- The webhook decides NOTHING about money. It asks Paytm for the truth and
-- then calls one of these, which re-check the database themselves. That way
-- the safety rules live next to the data and hold no matter who calls them:
-- the webhook, a retry of the webhook, a future sweep, or a person.
--
-- All three are SECURITY DEFINER and granted ONLY to service_role -- the
-- edge function's key. They are deliberately NOT available to anon, so a
-- client cannot complete its own payment.
--
-- Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Look up a gateway order. Returns the row that decides what happens:
--    a receipted row wins over an attempt, so a completed payment is never
--    mistaken for an outstanding one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.webhook_find_payment(p_order_id text)
RETURNS TABLE(pay_id bigint, ins_id integer, stu_id bigint, paystatus char,
              paynumber varchar, transtotalamount numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  -- The order id does not say which institution it belongs to, so look
  -- through every active institution's schema until one owns it.
  FOR v_ins IN SELECT i.ins_id FROM public.institution i WHERE i.activestatus = 1 LOOP
    v_schema := get_institution_schema(v_ins);
    CONTINUE WHEN v_schema IS NULL;
    -- Columns are cast to the declared types: stu_id is integer in some
    -- schemas and bigint in others, and a mismatch aborts the whole call.
    RETURN QUERY EXECUTE format(
      'SELECT p.pay_id::bigint, p.ins_id::integer, p.stu_id::bigint,
              p.paystatus::char, p.paynumber::varchar,
              p.transtotalamount::numeric
         FROM %I.payment p
        WHERE p.payorderid = $1 AND p.activestatus = 1
        -- a raised receipt outranks the attempt it came from
        ORDER BY (p.paystatus = ''C'') DESC, p.pay_id
        LIMIT 1', v_schema) USING p_order_id;
    IF FOUND THEN RETURN; END IF;
  END LOOP;
  RETURN;
END; $$;

REVOKE ALL ON FUNCTION public.webhook_find_payment(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.webhook_find_payment(text) TO service_role;


-- ---------------------------------------------------------------------
-- 2. Complete a payment Paytm has confirmed as captured.
--
-- Raises the receipt through complete_payment_grouped -- the same function a
-- normal collection uses -- so the number comes from the fee group's
-- sequence and the demand balances move exactly as they would have on the
-- day. It does not hand-write rows.
--
-- REFUSES rather than risks a double credit when:
--   * a receipt already exists for this order (the webhook was retried);
--   * the attempt has no detail lines, so there is no record of which fees
--     it was paying;
--   * a demand no longer owes what is about to be applied to it, meaning it
--     has been settled some other way since.
-- Each refusal returns a reason instead of raising, so the webhook can log
-- it and return 200 -- a retry would not help and Paytm would keep retrying.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.webhook_complete_payment(
  p_order_id text, p_reference text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_pay_id bigint;
  v_items jsonb; v_bad integer; v_res jsonb;
BEGIN
  SELECT f.pay_id, f.ins_id INTO v_pay_id, v_ins
    FROM public.webhook_find_payment(p_order_id) f;
  IF v_pay_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no payment row');
  END IF;

  v_schema := get_institution_schema(v_ins);

  -- Already receipted? Nothing to do. This is the retry path and must be
  -- silent, not an error.
  IF EXISTS (SELECT 1 FROM public.webhook_find_payment(p_order_id) f
              WHERE f.paystatus = 'C') THEN
    RETURN jsonb_build_object('ok', true, 'reason', 'already receipted');
  END IF;

  EXECUTE format(
    'SELECT jsonb_agg(jsonb_build_object(
              ''dem_id'', d.dem_id, ''amount'', d.transtotalamount,
              ''demfeetype'', f.demfeetype))
       FROM %I.paymentdetails d
       JOIN %I.feedemand f ON f.dem_id = d.dem_id
      WHERE d.pay_id = $1 AND d.activestatus = 1', v_schema, v_schema)
    INTO v_items USING v_pay_id;

  IF v_items IS NULL THEN
    RETURN jsonb_build_object('ok', false,
      'reason', 'attempt has no detail lines - cannot tell which fees it paid');
  END IF;

  EXECUTE format(
    'SELECT COUNT(*) FROM jsonb_array_elements($1) x
       JOIN %I.feedemand f ON f.dem_id = (x->>''dem_id'')::bigint
      WHERE f.activestatus <> 1
         OR COALESCE(f.balancedue,0) < (x->>''amount'')::numeric', v_schema)
    INTO v_bad USING v_items;

  IF v_bad > 0 THEN
    RETURN jsonb_build_object('ok', false,
      'reason', format('%s demand(s) no longer owe this - settled another way', v_bad));
  END IF;

  v_res := public.complete_payment_grouped(
    p_pay_id => v_pay_id, p_pay_method => 'Online Transfer',
    p_pay_reference => p_reference, p_items => v_items,
    p_ins_id => v_ins, p_status => 'C');

  RETURN jsonb_build_object('ok', true, 'receipts', v_res);
END; $$;

REVOKE ALL ON FUNCTION public.webhook_complete_payment(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.webhook_complete_payment(text, text) TO service_role;


-- ---------------------------------------------------------------------
-- 3. Mark an attempt failed, but ONLY on Paytm's own word.
--
-- The webhook calls this only after /v3/order/status returned TXN_FAILURE.
-- It still refuses to touch a row that already carries a receipt.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.webhook_fail_payment(
  p_order_id text, p_reference text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text; v_pay_id bigint; v_status char;
BEGIN
  SELECT f.pay_id, f.ins_id, f.paystatus INTO v_pay_id, v_ins, v_status
    FROM public.webhook_find_payment(p_order_id) f;
  IF v_pay_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no payment row');
  END IF;
  IF v_status = 'C' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already receipted - not failing it');
  END IF;

  v_schema := get_institution_schema(v_ins);
  EXECUTE format(
    'UPDATE %I.payment SET paystatus = ''F'',
            payreference = COALESCE($2, payreference)
      WHERE pay_id = $1 AND paystatus <> ''C''', v_schema)
    USING v_pay_id, p_reference;

  RETURN jsonb_build_object('ok', true, 'pay_id', v_pay_id);
END; $$;

REVOKE ALL ON FUNCTION public.webhook_fail_payment(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.webhook_fail_payment(text, text) TO service_role;
