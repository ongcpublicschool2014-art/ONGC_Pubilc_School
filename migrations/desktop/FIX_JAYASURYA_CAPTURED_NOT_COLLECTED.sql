-- =====================================================================
-- Two captured payments are recorded as FAILED, so the collection reports
-- under-count by Rs 3,600.
--
-- JAYASURYA S (421324106021) paid through the parent app just after midnight
-- on 2026-10-01. Paytm captured both:
--   pay_id 2770  Rs 2,000  txn 20261001010930000312215256303287952  FC26/03272
--   pay_id 2772  Rs 1,600  txn 20261001010990000312216128248562043  FC26/03273
-- The money settles to the college account today.
--
-- The app's concurrent-payment handler saw his balance already cleared (he had
-- settled it the previous evening) and marked both 'F' with
-- "REFUND-NEEDED: concurrent payment", WITHOUT reversing the demand credit or
-- the receipt number it had already drawn. So the books say the money never
-- arrived while the bank says it did.
--
-- This records the truth: the money WAS collected. Receipt numbers and demand
-- credits are untouched -- they were already correct. If the college decides to
-- give the Rs 3,600 back, that is a fee refund recorded in its own right, which
-- is how an overpayment is supposed to be handled.
--
-- A THIRD attempt, pay_id 2771 Rs 2,000, is deliberately NOT touched: its
-- reference is "Payment Failed: Paytm ..." with no transaction id, so Paytm
-- took nothing and 'F' is correct for it.
--
-- IT REFUSES unless both rows are still exactly as surveyed.
-- Wrapped in a transaction: review the SELECT, then COMMIT or ROLLBACK.
-- =====================================================================
BEGIN;

DO $$
DECLARE v_n integer;
BEGIN
  SELECT COUNT(*) INTO v_n
    FROM kcet20262027.payment
   WHERE pay_id IN (2770, 2772)
     AND paystatus = 'F'
     AND activestatus = 1
     AND payreference LIKE '%REFUND-NEEDED: concurrent payment%';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'REFUSED: expected 2 failed rows flagged REFUND-NEEDED, found %. '
                    'They may already have been corrected.', v_n;
  END IF;

  UPDATE kcet20262027.payment
     SET paystatus = 'C',
         -- keep the gateway reference, drop the flag that is no longer true
         payreference = TRIM(BOTH ' ' FROM
                          REPLACE(payreference, '(REFUND-NEEDED: concurrent payment)', ''))
                        || ' [captured; corrected 2026-10-01]'
   WHERE pay_id IN (2770, 2772);

  RAISE NOTICE 'pay_id 2770 and 2772 marked collected (Rs 3,600)';
END $$;

-- Confirm: both 'C', receipt numbers intact, reference keeps the txn id.
SELECT pay_id, paynumber, paystatus, transtotalamount, payreference, recon_status
  FROM kcet20262027.payment WHERE pay_id IN (2770, 2771, 2772) ORDER BY pay_id;

-- Review the result above, then run:  COMMIT;   (or ROLLBACK; to abandon)
