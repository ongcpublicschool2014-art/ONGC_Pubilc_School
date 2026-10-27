-- =====================================================================
-- Close the four misc refusals that were never real.
--
-- WHAT THEY ARE. On 05-10-2026 four misc Paytm collections raised the refusal
-- "Paytm captured money for an order with no record in the database":
--
--     MISC1T1791180314357  Rs 4,950  11:35   ->  FC26/03395
--     MISC1T1791183951207  Rs    50  12:36   ->  FC26/03414
--     MISC1T1791196962091  Rs 3,000  16:13   ->  FC26/03475
--     MISC1T1791197063418  Rs 5,250  16:15   ->  FC26/03476
--
-- Every one of them HAS a receipt, and its pending_collection intent is
-- status 'C' with the receipt number on it. Nothing was lost.
--
-- WHY THEY FIRED. webhook_find_payment searches <schema>.payment only. A misc
-- or advance order has no payment row by design -- its record is the
-- pending_collection intent -- so the lookup found nothing and the edge
-- function reported the order as unknown. It fired for every successful misc
-- payment, and it would have gone on doing so.
--
-- The edge function now calls webhook_complete_collection before declaring an
-- order unmatched, which both stops the noise AND makes the webhook able to
-- recover a misc or advance for the first time. Deploy it:
--
--     supabase functions deploy paytm-webhook
--
-- THIS SCRIPT only closes the four already on the list. It is deliberately
-- NOT a blanket "resolve everything": each one is matched against its receipt
-- first, so a refusal that is genuinely outstanding cannot be swept away with
-- them. If a row is missing its receipt it stays on the list and is reported.
--
-- Idempotent. Changes no money, no receipt and no demand.
-- =====================================================================
DO $resolve$
DECLARE r record; v_closed int := 0; v_left int := 0;
BEGIN
  FOR r IN
    SELECT w.order_id, w.amount, pc.receipt_no, pc.status
      FROM public.webhook_refusal w
      LEFT JOIN public.pending_collection pc ON pc.order_id = w.order_id
     WHERE w.resolved_at IS NULL
       AND w.reason LIKE '%no record in the database%'
  LOOP
    -- Only close it when the intent says it WAS receipted. "Settled with a
    -- receipt number" is the proof; the refusal's own text is not.
    IF r.status = 'C' AND COALESCE(btrim(r.receipt_no), '') <> '' THEN
      PERFORM public.resolve_webhook_refusal(
        r.order_id, 'SYSTEM',
        'False alarm. webhook_find_payment searches payment only, so a misc '
        'order never matched and was reported as unknown -- but this one was '
        'receipted as ' || r.receipt_no || '. Fixed in the edge function.');
      v_closed := v_closed + 1;
      RAISE NOTICE 'closed % -> receipt %', r.order_id, r.receipt_no;
    ELSE
      v_left := v_left + 1;
      RAISE WARNING 'LEFT OPEN: % (Rs %) has no receipted intent -- this one '
                    'may be real, work it by hand', r.order_id, r.amount;
    END IF;
  END LOOP;

  RAISE NOTICE '% closed, % left open', v_closed, v_left;
END $resolve$;


-- ---------------------------------------------------------------------
-- VERIFY -- what the health check says now.
-- ---------------------------------------------------------------------
SELECT severity, check_name, found, meaning
  FROM public.fee_health_check()
 WHERE check_name IN ('captures Paytm confirmed but we refused',
                      'demand bills nothing but money was taken')
 ORDER BY check_name;
