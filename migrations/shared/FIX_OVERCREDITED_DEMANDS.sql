-- =====================================================================
-- Restore demands that were credited more than their receipts account for.
--
-- THE SYMPTOM, as the office sees it.
-- Fee Collection says "No pending fee demands" for a student while the Student
-- Ledger shows a balance. Both are reading the same database: Fee Collection
-- trusts feedemand.balancedue, and the ledger adds up the receipts actually
-- issued. When those disagree, the LEDGER is right -- a receipt is evidence
-- that money arrived; balancedue is only a running total.
--
-- THE CAUSE.
-- complete_payment_grouped used to end with an unconditional
--     DELETE FROM payment WHERE pay_id = $1
-- so a payment processed twice had its FIRST receipt row destroyed while the
-- credit that receipt had already applied to the demand stayed behind. The
-- demand was then credited twice for one payment.
--
-- Found on JAYASURYA S (421324106021), demand 3626 TUITION FEE:
--     receipts against it   5,000 + 1,000 + 6,700 + 8,000 + 2,000 + 1,600
--                         = 24,300
--     feedemand.paidamount  39,000
--     difference            14,700
-- and 6,700 + 8,000 = 14,700 exactly -- the two payments whose first receipts
-- (FC26/03268 and FC26/03270) were deleted and whose numbers showed up as the
-- "gaps" in the register. The money came in ONCE. The student still owes
-- 14,700, and with balancedue at 0 the counter could not collect it.
--
-- Both deletion paths are now closed (PROTECT_RECEIPTED_PAYMENTS.sql and
-- REFUSE_REPROCESSING_RECEIPTED_PAYMENT.sql), so this is a one-off repair of
-- the damage already done, not a recurring job.
--
-- SCOPE: one demand on TEST as of 2026-10-01. The script is written generically
-- and repairs whatever it finds, so run the PREVIEW first and read it.
--
-- IT NEVER REDUCES WHAT A STUDENT HAS PAID. paidamount is recomputed from
-- receipts and advance adjustments -- the two things that represent real money
-- -- so a demand can only move from "paid more than it was" to "paid what it
-- actually was".
-- =====================================================================


-- ---------------------------------------------------------------------
-- PREVIEW -- run this ALONE first. Nothing is written.
--
-- Every row here is a student who appears settled but is not. Check a couple
-- against the Student Ledger before running the repair.
-- ---------------------------------------------------------------------
WITH receipted AS (
  SELECT pd.dem_id, SUM(pd.transtotalamount) AS from_receipts
    FROM kcet20262027.paymentdetails pd
    JOIN kcet20262027.payment p ON p.pay_id = pd.pay_id
   WHERE p.paynumber IS NOT NULL AND p.paystatus = 'C' AND p.activestatus = 1
   GROUP BY pd.dem_id
), adj AS (
  SELECT dem_id, SUM(adjustamount) AS from_advance
    FROM kcet20262027.advadjustment WHERE activestatus = 1 GROUP BY dem_id
)
SELECT s.stuadmno, s.stuname, fd.dem_id, fd.demfeetype,
       fd.feeamount, fd.conamount,
       fd.paidamount                              AS recorded_paid,
       COALESCE(r.from_receipts,0)                AS from_receipts,
       COALESCE(a.from_advance,0)                 AS from_advance,
       fd.paidamount - COALESCE(r.from_receipts,0) - COALESCE(a.from_advance,0)
                                                  AS phantom_credit,
       fd.balancedue                              AS balance_now,
       GREATEST(fd.feeamount - COALESCE(fd.conamount,0)
                - COALESCE(r.from_receipts,0) - COALESCE(a.from_advance,0), 0)
                                                  AS balance_should_be
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id
  LEFT JOIN receipted r ON r.dem_id = fd.dem_id
  LEFT JOIN adj a ON a.dem_id = fd.dem_id
 WHERE fd.activestatus = 1
   AND fd.paidamount > COALESCE(r.from_receipts,0) + COALESCE(a.from_advance,0) + 0.005
 ORDER BY phantom_credit DESC;


-- ---------------------------------------------------------------------
-- THE REPAIR -- run this only after reading the preview.
--
-- Recomputes paidamount from what actually arrived, and balancedue from the
-- net demand. reconbalancedue is raised to match balancedue when it is lower,
-- so the Pending Payment Report does not keep showing the amount as settled;
-- it is never lowered, because a figure already reconciled against a bank
-- statement is not this script's to overwrite.
-- ---------------------------------------------------------------------
WITH receipted AS (
  SELECT pd.dem_id, SUM(pd.transtotalamount) AS from_receipts
    FROM kcet20262027.paymentdetails pd
    JOIN kcet20262027.payment p ON p.pay_id = pd.pay_id
   WHERE p.paynumber IS NOT NULL AND p.paystatus = 'C' AND p.activestatus = 1
   GROUP BY pd.dem_id
), adj AS (
  SELECT dem_id, SUM(adjustamount) AS from_advance
    FROM kcet20262027.advadjustment WHERE activestatus = 1 GROUP BY dem_id
), fixed AS (
  SELECT fd.dem_id,
         COALESCE(r.from_receipts,0) + COALESCE(a.from_advance,0) AS real_paid,
         GREATEST(fd.feeamount - COALESCE(fd.conamount,0)
                  - COALESCE(r.from_receipts,0) - COALESCE(a.from_advance,0), 0)
                                                                  AS real_balance
    FROM kcet20262027.feedemand fd
    LEFT JOIN receipted r ON r.dem_id = fd.dem_id
    LEFT JOIN adj a ON a.dem_id = fd.dem_id
   WHERE fd.activestatus = 1
     AND fd.paidamount > COALESCE(r.from_receipts,0) + COALESCE(a.from_advance,0) + 0.005
)
UPDATE kcet20262027.feedemand fd
   SET paidamount      = f.real_paid,
       balancedue      = f.real_balance,
       reconbalancedue = GREATEST(COALESCE(fd.reconbalancedue,0), f.real_balance),
       paidstatus      = CASE WHEN f.real_balance <= 0 THEN 'P' ELSE 'U' END
  FROM fixed f
 WHERE fd.dem_id = f.dem_id;


-- ---------------------------------------------------------------------
-- VERIFY -- must return ZERO rows.
-- ---------------------------------------------------------------------
WITH receipted AS (
  SELECT pd.dem_id, SUM(pd.transtotalamount) AS from_receipts
    FROM kcet20262027.paymentdetails pd
    JOIN kcet20262027.payment p ON p.pay_id = pd.pay_id
   WHERE p.paynumber IS NOT NULL AND p.paystatus = 'C' AND p.activestatus = 1
   GROUP BY pd.dem_id
), adj AS (
  SELECT dem_id, SUM(adjustamount) AS from_advance
    FROM kcet20262027.advadjustment WHERE activestatus = 1 GROUP BY dem_id
)
SELECT fd.dem_id, fd.paidamount,
       COALESCE(r.from_receipts,0) + COALESCE(a.from_advance,0) AS real_paid
  FROM kcet20262027.feedemand fd
  LEFT JOIN receipted r ON r.dem_id = fd.dem_id
  LEFT JOIN adj a ON a.dem_id = fd.dem_id
 WHERE fd.activestatus = 1
   AND fd.paidamount > COALESCE(r.from_receipts,0) + COALESCE(a.from_advance,0) + 0.005;
