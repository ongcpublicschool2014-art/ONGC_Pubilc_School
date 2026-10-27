-- =====================================================================
-- Stop the refusal list crying wolf.
--
-- On 05-10-2026 fee_health_check() reported 17 "captures Paytm confirmed but
-- we refused". Sixteen were noise:
--
--   13 x "attempt has no detail lines"
--        A DESKTOP counter payment writes its 'I' row WITHOUT paymentdetails
--        -- those are written at completion. Paytm's callback lands in the gap
--        between capture and the counter finishing, the webhook sees a row with
--        no detail lines, and records a refusal. Seconds later the counter
--        completes normally. Every one of the 13 had a receipt: FC26/03340,
--        03341, 03342, 03345, 03346, 03347, 03352, 03359, 03367-03370, 03372.
--
--    3 x "Paytm captured money for an order with no record"
--        for orders Paytm had marked FAILED. Fixed in the edge function --
--        it now records only on TXN_SUCCESS.
--
-- Exactly ONE was real: Rs 450, MISC1T1791171350251, since receipted by hand.
--
-- A list that means "money received with no receipt" is worth nothing once it
-- also means "a payment is halfway through" or "a payment failed". Sixteen
-- false entries in one morning would have trained whoever works it to ignore
-- the list, which is how the Rs 450 gets missed next time.
--
-- THE GUARD. A refusal naming a payment row is not recorded while that row is
-- less than 15 minutes old: the counter is probably still completing it. If it
-- is genuinely stuck, the next callback or the next sweep records it then --
-- nothing is lost, it is only not reported prematurely.
--
-- Refusals with no pay_id (an unmatched order) are unaffected: there is no
-- attempt in flight to wait for.
--
-- Idempotent. Changes no payment, receipt or demand.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.webhook_record_refusal(
  p_order_id text, p_reason text,
  p_ins_id integer DEFAULT NULL, p_pay_id bigint DEFAULT NULL,
  p_amount numeric DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v text; v_fresh boolean := false;
BEGIN
  -- Is the attempt still in flight? Only askable when we know which row.
  IF p_pay_id IS NOT NULL AND p_ins_id IS NOT NULL THEN
    v := get_institution_schema(p_ins_id);
    IF v IS NOT NULL THEN
      BEGIN
        EXECUTE format(
          'SELECT createdat > now() - interval ''15 minutes''
             FROM %I.payment WHERE pay_id = $1', v)
          INTO v_fresh USING p_pay_id;
      EXCEPTION WHEN OTHERS THEN
        v_fresh := false;   -- cannot tell -> record it, the safer direction
      END;
    END IF;
  END IF;

  IF COALESCE(v_fresh, false) THEN
    -- Still in flight. Saying nothing is right: the counter is most likely
    -- mid-completion, and a later callback or sweep will record it if not.
    RETURN;
  END IF;

  INSERT INTO public.webhook_refusal
         (order_id, ins_id, pay_id, reason, amount)
  VALUES (p_order_id, p_ins_id, p_pay_id, p_reason, p_amount)
  ON CONFLICT (order_id) DO UPDATE
     SET times_seen  = public.webhook_refusal.times_seen + 1,
         last_seen   = now(),
         reason      = EXCLUDED.reason,
         ins_id      = COALESCE(EXCLUDED.ins_id, public.webhook_refusal.ins_id),
         pay_id      = COALESCE(EXCLUDED.pay_id, public.webhook_refusal.pay_id),
         amount      = COALESCE(EXCLUDED.amount, public.webhook_refusal.amount),
         resolved_at = CASE WHEN public.webhook_refusal.reason IS DISTINCT FROM EXCLUDED.reason
                            THEN NULL ELSE public.webhook_refusal.resolved_at END;
END; $$;

REVOKE ALL ON FUNCTION public.webhook_record_refusal(text, text, integer, bigint, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.webhook_record_refusal(text, text, integer, bigint, numeric)
  TO service_role;


-- ---------------------------------------------------------------------
-- Clear today's noise: every "no detail lines" refusal whose payment was
-- in fact receipted. Guarded on the receipt existing, so a genuine one
-- stays on the list.
-- ---------------------------------------------------------------------
UPDATE public.webhook_refusal r
   SET resolved_at = now(), resolved_by = 'SYSTEM',
       resolution_note = 'False alarm: the counter completed it normally and a '
                      || 'receipt exists. The webhook arrived mid-completion.'
 WHERE r.resolved_at IS NULL
   AND r.reason LIKE 'attempt has no detail lines%'
   AND EXISTS (SELECT 1 FROM kcet20262027.payment p
                WHERE p.payorderid = r.order_id
                  AND p.paynumber IS NOT NULL AND p.paystatus = 'C'
                  AND p.activestatus = 1);

NOTIFY pgrst, 'reload schema';


-- ---------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------
SELECT 'a refusal waits for an attempt in flight' AS check,
       CASE WHEN p.prosrc LIKE '%still in flight%' THEN 'ok' ELSE 'FAILED' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'webhook_record_refusal'
UNION ALL
SELECT 'refusals still outstanding',
       count(*)::text FROM public.webhook_refusal WHERE resolved_at IS NULL
 ORDER BY 1;
