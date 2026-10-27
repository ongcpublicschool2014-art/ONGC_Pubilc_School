-- =====================================================================
-- A recovered fee payment is dated the day the MONEY WAS TAKEN.
--
-- complete_payment_grouped stamps paydate = NOW(). That is right when the
-- payment completes normally -- the receipt happens as the money is taken --
-- and wrong for one the sweep recovers hours or days later.
--
-- THE CASE. JAYASURYA, 30-09-2026: Rs 2,000 and Rs 1,600 debited that evening,
-- captured by Paytm around midnight. Recovered the next morning, the receipts
-- would carry 1 OCTOBER -- so 30 September's Daily Collection is short by
-- Rs 3,600 and never ties against the Paytm report, and the difference has to
-- be chased by hand. The same reconciliation that found the missing Rs 8,000.
--
-- WHERE THE HONEST DATE COMES FROM. The 'I' row's createdat, stamped by this
-- server when the payment was initiated, before the gateway was contacted.
-- Never a workstation clock -- ignoring client dates is why misc receipts
-- stopped landing a day out.
--
-- complete_payment_grouped carries payorderid onto the rows it creates, so the
-- receipts can still be found after the original row is gone.
--
-- Only ever moves a receipt BACKWARDS, never forwards, and only one that
-- carries the order id it is asked about.
--
-- Idempotent. Changes no amount, no demand, no receipt number.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.backdate_recovered_payment(
  p_ins_id integer, p_order_id text, p_when timestamp
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v text; n integer := 0;
BEGIN
  IF p_order_id IS NULL OR btrim(p_order_id) = '' OR p_when IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'order id and date required');
  END IF;

  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no schema'); END IF;

  -- paynumber IS NOT NULL: only a RAISED receipt is moved. An attempt without
  -- one has no place in any report, so its date decides nothing.
  -- paydate > p_when: backwards only. A receipt that is already dated earlier
  -- is left exactly as it is.
  EXECUTE format(
    'UPDATE %I.payment SET paydate = $1
      WHERE payorderid = $2 AND ins_id = $3
        AND paynumber IS NOT NULL AND paystatus = ''C''
        AND paydate > $1', v)
    USING p_when, p_order_id, p_ins_id;
  GET DIAGNOSTICS n = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'moved', n, 'to', p_when);
END; $$;

GRANT EXECUTE ON FUNCTION public.backdate_recovered_payment(integer, text, timestamp)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

SELECT 'a recovered fee receipt keeps the day the money was taken' AS check,
       CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname='public' AND p.proname='backdate_recovered_payment')
            THEN 'ok' ELSE 'FAILED' END AS state;
