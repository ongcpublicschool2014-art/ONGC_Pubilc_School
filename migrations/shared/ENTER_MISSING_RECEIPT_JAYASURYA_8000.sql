-- =====================================================================
-- Raise the receipt for a Paytm payment that was captured but never recorded.
--
--   student   JAYASURYA S  (421324106021)  stu_id 821
--   amount    Rs 8,000  against TUITION FEE (dem_id 3626)
--   paid      01-10-2026 17:58  via Paytm
--   txn       20261001011080000312477834325294642
--   order     PAY-2803t1790857699193
--
-- WHY BY RPC AND NOT BY HAND. process_grouped_payment is the same function the
-- counter uses: it draws the next number from the FC26/ series, writes the
-- payment and its per-demand breakdown, and credits feedemand in one
-- transaction. Inserting the rows by hand would leave the receipt series and
-- the demand to be corrected separately, which is how the register drifts.
--
-- CHECKED FIRST (2026-10-03): the transaction id appears nowhere in payment,
-- misc_collection or advance_collection on LIVE, and no Rs 8,000 receipt
-- exists for this student on 1-3 Oct. It is genuinely unreceipted -- not a
-- duplicate of FC26/03271, which is a SEPARATE Rs 8,000 captured on 30 Sep
-- (reference 20260930010930000312128615953021495).
--
-- RUN THE CHECK BLOCK FIRST. If it returns a row, the receipt already exists
-- and this must NOT be run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. STOP CHECK -- must return ZERO rows.
-- ---------------------------------------------------------------------
SELECT paynumber, transtotalamount, paydate
  FROM kcet20262027.payment
 WHERE payreference LIKE '%20261001011080000312477834325294642%'
    OR (stu_id = 821 AND transtotalamount = 8000 AND paydate >= DATE '2026-10-01');


-- ---------------------------------------------------------------------
-- 2. RAISE THE RECEIPT
--
-- The reference carries the Paytm transaction id so Bank Reconciliation and
-- any future reconciliation of 1 Oct can match it -- that is exactly how the
-- other 37 payments that day were matched, and how this one was found missing.
-- ---------------------------------------------------------------------
SELECT public.process_grouped_payment(
  1,                       -- p_ins_id
  '3410',                  -- p_inscode
  821,                     -- p_stu_id   JAYASURYA S
  1,                       -- p_yr_id
  '2026-2027',             -- p_yrlabel
  8000,                    -- p_total_amount
  'ADMIN',                 -- p_created_by
  'Online Transfer',       -- p_pay_method
  '20261001011080000312477834325294642',   -- p_pay_reference (the Paytm txn id)
  jsonb_build_array(jsonb_build_object(
    'dem_id',      3626,
    'yr_id',       1,
    'yrlabel',     '2026-2027',
    'amount',      8000,
    'demfeetype',  'TUITION FEE'))
) AS receipt;


-- ---------------------------------------------------------------------
-- 3. DATE IT 1 OCTOBER
--
-- process_grouped_payment stamps paydate = now(), so without this the receipt
-- lands on today's Daily Collection instead of the day the money was taken,
-- and the 1 Oct reconciliation still would not tie.
-- ---------------------------------------------------------------------
UPDATE kcet20262027.payment
   SET paydate = TIMESTAMP '2026-10-01 17:58:30'
 WHERE payreference = '20261001011080000312477834325294642'
   AND paynumber IS NOT NULL;


-- ---------------------------------------------------------------------
-- 4. VERIFY
-- ---------------------------------------------------------------------
SELECT p.paynumber, s.stuname, p.transtotalamount, p.paydate::timestamp(0),
       fd.balancedue AS tuition_now
  FROM kcet20262027.payment p
  JOIN kcet20262027.students s ON s.stu_id = p.stu_id
  JOIN kcet20262027.feedemand fd ON fd.dem_id = 3626
 WHERE p.payreference = '20261001011080000312477834325294642';

SELECT * FROM public.fee_health_check();
