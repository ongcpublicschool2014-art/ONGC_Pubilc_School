-- ============================================================================
-- RECONBALANCEDUE DRIFT -- find it, then fix it.
--
-- SYMPTOM on the dashboard: Total Fees Due - Total Collected does not equal
-- Outstanding.
--
--   Total Fees Due  = SUM(feedemand.feeamount)          -- what was billed
--   Total Collected = SUM(paidamount) - pending approval -- received AND approved
--   Outstanding     = SUM(feedemand.reconbalancedue)     -- owed after reconciliation
--
-- Those three only tally when the PAYMENT side and the DEMAND side agree about
-- how much money is received but not yet reconciled:
--
--   reconbalancedue  =  balancedue  +  (payments on this demand still recon 'P')
--
-- A demand where that does not hold has had reconbalancedue reduced by money
-- the bank has not confirmed, so Outstanding under-states what is owed. The
-- usual cause is a payment reconciled and later set back to pending without
-- restoring the figure.
--
-- Change kcet20262027 to your schema. Section 1 is READ-ONLY -- run it first
-- and look at the rows before running section 2.
-- ============================================================================


-- ============================================================================
-- 1. DIAGNOSE -- every demand where the two sides disagree, and by how much.
--    No rows = nothing to fix, and the dashboard cards already tally.
-- ============================================================================
WITH pend AS (
  SELECT pd.dem_id, SUM(pd.transtotalamount) AS pend_amt
    FROM kcet20262027.paymentdetails pd
    JOIN kcet20262027.payment p ON p.pay_id = pd.pay_id
   WHERE p.paystatus = 'C' AND p.recon_status = 'P' AND p.activestatus = 1
   GROUP BY pd.dem_id
)
SELECT fd.dem_id,
       fd.stuadmno,
       fd.demfeetype,
       fd.feeamount,
       fd.paidamount,
       fd.balancedue,
       fd.reconbalancedue                              AS recon_now,
       fd.balancedue + COALESCE(pe.pend_amt, 0)        AS recon_should_be,
       COALESCE(pe.pend_amt, 0)                        AS awaiting_reconciliation,
       (fd.balancedue + COALESCE(pe.pend_amt, 0)) - fd.reconbalancedue AS understated_by
  FROM kcet20262027.feedemand fd
  LEFT JOIN pend pe ON pe.dem_id = fd.dem_id
 WHERE fd.activestatus = 1
   AND fd.reconbalancedue <> fd.balancedue + COALESCE(pe.pend_amt, 0)
 ORDER BY abs((fd.balancedue + COALESCE(pe.pend_amt, 0)) - fd.reconbalancedue) DESC;


-- ============================================================================
-- 2. REPAIR -- recompute reconbalancedue from what is ACTUALLY unreconciled.
--
-- Derived, not guessed: balancedue is already correct (it tracks every payment)
-- and the pending total comes from the payment rows themselves, so the result
-- is whatever the two sides jointly imply. Touches ONLY the rows section 1
-- listed; every other demand is left exactly as it is.
--
-- Wrapped in a transaction with the before/after totals printed, so you can
-- ROLLBACK if the movement is not what section 1 predicted. Change COMMIT at
-- the bottom to ROLLBACK for a dry run.
-- ============================================================================
BEGIN;

SELECT 'BEFORE' AS when_, to_char(SUM(reconbalancedue), 'FM99,99,99,999') AS outstanding
  FROM kcet20262027.feedemand WHERE activestatus = 1;

WITH pend AS (
  SELECT pd.dem_id, SUM(pd.transtotalamount) AS pend_amt
    FROM kcet20262027.paymentdetails pd
    JOIN kcet20262027.payment p ON p.pay_id = pd.pay_id
   WHERE p.paystatus = 'C' AND p.recon_status = 'P' AND p.activestatus = 1
   GROUP BY pd.dem_id
)
UPDATE kcet20262027.feedemand fd
   SET reconbalancedue = fd.balancedue + COALESCE(pe.pend_amt, 0)
  FROM (SELECT dem_id, pend_amt FROM pend) pe
 WHERE fd.dem_id = pe.dem_id
   AND fd.activestatus = 1
   AND fd.reconbalancedue <> fd.balancedue + pe.pend_amt;

-- A demand with NO pending payment must have reconbalancedue = balancedue.
-- The join above cannot reach those rows, so they are handled separately.
UPDATE kcet20262027.feedemand fd
   SET reconbalancedue = fd.balancedue
 WHERE fd.activestatus = 1
   AND fd.reconbalancedue <> fd.balancedue
   AND NOT EXISTS (
     SELECT 1 FROM kcet20262027.paymentdetails pd
       JOIN kcet20262027.payment p ON p.pay_id = pd.pay_id
      WHERE pd.dem_id = fd.dem_id
        AND p.paystatus = 'C' AND p.recon_status = 'P' AND p.activestatus = 1);

SELECT 'AFTER' AS when_, to_char(SUM(reconbalancedue), 'FM99,99,99,999') AS outstanding
  FROM kcet20262027.feedemand WHERE activestatus = 1;

COMMIT;


-- ============================================================================
-- 3. VERIFY -- re-run section 1. It should return NO rows.
--
-- Then on the dashboard: Total Fees Due - Total Collected should equal
-- Outstanding, to the rupee.
-- ============================================================================
