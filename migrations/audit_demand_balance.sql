-- Audit: fee demands whose balancedue disagrees with their own figures.
--
-- Everywhere else in the system the invariant is
--     balancedue = GREATEST(feeamount - conamount - paidamount, 0)
-- (process_concession, rebuild_demand, propagate_class_fee and
-- transfer_course_with_credit all compute it that way). Collection subtracts
-- from it and void_receipt adds back to it, so the two stay symmetric.
--
-- It drifts when something adds the fee back twice -- e.g. a demand regenerated
-- or re-imported after a receipt was voided. That matters because the Fee
-- Collection screen offers balancedue as the amount to collect, so an inflated
-- balance becomes real over-collected money (kch20262027 dem_id 21353/21354:
-- a 2,200 fee collected as 4,400 and a 300 fee collected as 600).
--
-- Plain SELECTs, not DO blocks: the Supabase SQL editor shows result rows but
-- NOT RAISE NOTICE output, so a DO-block version just reports "no rows".
--
-- >>> Replace kch20262027 with your schema (4 places: queries 1, 2 and the
--     commented repair). Run query 1 first. <<<

-- ---------------------------------------------------------------------------
-- 1) THE DRIFTING DEMANDS.
--    drift > 0 -> balancedue is TOO HIGH: collectible money that isn't owed.
--    drift < 0 -> balancedue is too low: the fee would be under-collected.
-- ---------------------------------------------------------------------------
SELECT fd.dem_id,
       fd.stuadmno,
       fd.demfeetype,
       fd.demfeeterm,
       fd.feeamount,
       fd.conamount,
       fd.paidamount,
       fd.balancedue,
       GREATEST(fd.feeamount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0) AS expected,
       fd.balancedue
         - GREATEST(fd.feeamount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0) AS drift,
       fd.reconbalancedue,
       fd.paidstatus,
       -- was a receipt against this demand ever voided? that is the suspected
       -- trigger, so it tells you whether the drift follows that pattern.
       EXISTS (SELECT 1
                 FROM kch20262027.paymentdetails pd
                 JOIN kch20262027.payment p ON p.pay_id = pd.pay_id
                WHERE pd.dem_id = fd.dem_id AND p.activestatus = 9) AS had_voided_receipt
  FROM kch20262027.feedemand fd
 WHERE fd.activestatus = 1
   AND fd.balancedue
       <> GREATEST(fd.feeamount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0)
 ORDER BY ABS(fd.balancedue
              - GREATEST(fd.feeamount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0)) DESC;

-- ---------------------------------------------------------------------------
-- 2) THE TOTALS -- how much is over-stated, and how much was over-collected.
--    over_stated  = money the collection screen would offer but isn't owed.
--    over_collected = money already taken beyond the fee (needs a refund, not
--                     a balance correction).
-- ---------------------------------------------------------------------------
SELECT COUNT(*) FILTER (
         WHERE balancedue
               <> GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0)
       ) AS drifting_demands,
       COALESCE(SUM(GREATEST(
         balancedue - GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0), 0)), 0)
         AS over_stated,
       COUNT(*) FILTER (
         WHERE COALESCE(paidamount,0) + COALESCE(conamount,0) > feeamount
       ) AS over_collected_demands,
       COALESCE(SUM(GREATEST(
         COALESCE(paidamount,0) + COALESCE(conamount,0) - feeamount, 0)), 0) AS over_collected
  FROM kch20262027.feedemand
 WHERE activestatus = 1;

-- ---------------------------------------------------------------------------
-- 3) REPAIR -- COMMENTED OUT. Read queries 1 and 2 first.
--
-- Corrects balancedue only. reconbalancedue is deliberately left alone: it is
-- a different quantity (it drops at reconciliation, not at collection), so
-- rewriting it here would corrupt the Pending Payment / DCB figures.
--
-- This does NOT recover money already over-collected -- that sits in
-- paidamount above the fee and needs a refund.
-- ---------------------------------------------------------------------------
-- UPDATE kch20262027.feedemand
--    SET balancedue = GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0),
--        paidstatus = CASE
--          WHEN GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0) <= 0
--          THEN 'P' ELSE 'U' END
--  WHERE activestatus = 1
--    AND balancedue
--        <> GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0);
