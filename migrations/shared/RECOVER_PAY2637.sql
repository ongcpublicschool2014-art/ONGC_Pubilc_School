-- =====================================================================
-- RECOVERY: PAY-2637 -- Paytm captured Rs 50,000 on 2026-09-29 09:01 IST
-- (txn 20260929011020000311616672054839425, VIJAY J P, adm 421324104056)
-- but the app recorded the attempt as FAILED with payreference 'CANCELLED',
-- so no receipt was ever raised and the demand still shows as due.
--
-- This raises the receipt properly by calling complete_payment_grouped --
-- the same function a normal collection uses -- so the receipt number comes
-- from the fee group's sequence and the demand balance is updated exactly as
-- it would have been on the day. It does NOT hand-insert rows.
--
-- IT REFUSES TO RUN unless live still matches what was verified:
--   * the payment row is still 'F' with no receipt number
--   * no receipt already exists against this order id
--   * the demand still owes at least the amount being applied
-- so if the office has already collected this at the counter, or somebody
-- has run this once, it stops instead of crediting the money twice.
--
-- Wrapped in a transaction: on any failure NOTHING is written.
-- =====================================================================
BEGIN;

DO $$
DECLARE
  v_pay_id   bigint;
  v_ins      integer;
  v_items    jsonb;
  v_total    numeric;
  v_bad      integer;
  v_res      jsonb;
BEGIN
  -- ---- 1. the failed attempt must still be exactly as surveyed ----------
  SELECT pay_id, ins_id INTO v_pay_id, v_ins
    FROM kcet20262027.payment
   WHERE payorderid = 'PAY-2637' AND paystatus = 'F'
     AND paynumber IS NULL AND activestatus = 1;
  IF v_pay_id IS NULL THEN
    RAISE EXCEPTION 'REFUSED: no failed, unreceipted payment row for PAY-2637. '
                    'It may already have been recovered -- check before retrying.';
  END IF;

  -- ---- 2. nothing may already have been receipted for this order --------
  IF EXISTS (SELECT 1 FROM kcet20262027.payment
              WHERE payorderid = 'PAY-2637' AND paystatus = 'C') THEN
    RAISE EXCEPTION 'REFUSED: a receipt already exists for PAY-2637.';
  END IF;

  -- ---- 3. rebuild what the attempt was paying ---------------------------
  SELECT jsonb_agg(jsonb_build_object(
           'dem_id',      d.dem_id,
           'amount',      d.transtotalamount,
           'demfeetype',  f.demfeetype)),
         SUM(d.transtotalamount)
    INTO v_items, v_total
    FROM kcet20262027.paymentdetails d
    JOIN kcet20262027.feedemand f ON f.dem_id = d.dem_id
   WHERE d.pay_id = v_pay_id AND d.activestatus = 1;

  IF v_items IS NULL THEN
    RAISE EXCEPTION 'REFUSED: the failed attempt has no detail lines, so there '
                    'is no record of which fees it was paying.';
  END IF;
  IF v_total <> 50000.00 THEN
    RAISE EXCEPTION 'REFUSED: detail lines total % but Paytm captured 50000.00', v_total;
  END IF;

  -- ---- 4. the money must still be owed ----------------------------------
  SELECT COUNT(*) INTO v_bad
    FROM jsonb_array_elements(v_items) x
    JOIN kcet20262027.feedemand f ON f.dem_id = (x->>'dem_id')::bigint
   WHERE f.activestatus <> 1
      OR COALESCE(f.balancedue,0) < (x->>'amount')::numeric;
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'REFUSED: % demand(s) no longer owe this amount -- it has '
                    'been settled another way. Applying it would double-credit.', v_bad;
  END IF;

  -- ---- 5. raise the receipt the normal way ------------------------------
  v_res := public.complete_payment_grouped(
    p_pay_id        => v_pay_id,
    p_pay_method    => 'Online Transfer',
    p_pay_reference => 'RECOVERED Paytm 20260929011020000311616672054839425',
    p_items         => v_items,
    p_ins_id        => v_ins,
    p_status        => 'C');

  RAISE NOTICE 'Recovered PAY-2637. Result: %', v_res;
END $$;

-- Confirm before committing: expect a 'C' row WITH a receipt number.
SELECT pay_id, paynumber, paystatus, transtotalamount, paymethod, payreference
FROM   kcet20262027.payment WHERE payorderid = 'PAY-2637' ORDER BY pay_id;

SELECT dem_id, feeamount, conamount, paidamount, balancedue, paidstatus
FROM   kcet20262027.feedemand WHERE dem_id = 2259;

-- Review the two results above, then run:  COMMIT;   (or ROLLBACK; to abandon)
