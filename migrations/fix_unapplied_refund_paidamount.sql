-- One-off correction: a refund was recorded but never applied to its demands.
--
-- Both code paths that create a refund also reduce the demand's paidamount --
-- process_refund (paidamount = GREATEST(paid - refundamount, 0)) and the
-- token-less fallback in fee_refund_screen. On kch20262027 the effect is
-- missing anyway: RF00002 holds refundamount 300 + 2,200 against dem 21354 and
-- 21353, both active, yet those demands still carry paidamount 600 and 4,400 --
-- exactly 2,500 more than their fees. Which step failed isn't recoverable from
-- the data; this repairs the result.
--
-- balancedue is NOT touched: it is already correct everywhere (the audit found
-- zero drift), and it stays correct after this -- once paidamount comes down to
-- the fee, feeamount - conamount - paidamount is still 0.
--
-- SAFE BY CONSTRUCTION: it only ever removes the OVER-collected excess, capped
-- at what was actually refunded, and only on demands that are still over-
-- collected. Running it twice changes nothing the second time.
--
-- >>> Replace kch20262027 with your schema (3 places). Run query 1 first. <<<

-- ---------------------------------------------------------------------------
-- 1) PREVIEW -- what would change, and by how much.
-- ---------------------------------------------------------------------------
WITH refunded AS (
  SELECT rd.dem_id, SUM(rd.refundamount) AS refunded
    FROM kch20262027.fee_refunddetails rd
    JOIN kch20262027.fee_refund r ON r.rf_id = rd.rf_id
   WHERE r.activestatus = 1 AND COALESCE(rd.refundamount, 0) > 0
   GROUP BY rd.dem_id
)
SELECT fd.dem_id, fd.stuadmno, fd.demfeetype,
       fd.feeamount, fd.conamount, fd.paidamount, fd.balancedue,
       rf.refunded,
       COALESCE(fd.paidamount,0) - GREATEST(fd.feeamount - COALESCE(fd.conamount,0), 0) AS over_collected,
       LEAST(rf.refunded,
             COALESCE(fd.paidamount,0) - GREATEST(fd.feeamount - COALESCE(fd.conamount,0), 0)) AS will_deduct,
       COALESCE(fd.paidamount,0)
         - LEAST(rf.refunded,
                 COALESCE(fd.paidamount,0) - GREATEST(fd.feeamount - COALESCE(fd.conamount,0), 0)) AS new_paidamount
  FROM kch20262027.feedemand fd
  JOIN refunded rf ON rf.dem_id = fd.dem_id
 WHERE fd.activestatus = 1
   AND COALESCE(fd.paidamount,0) > GREATEST(fd.feeamount - COALESCE(fd.conamount,0), 0)
 ORDER BY fd.stuadmno, fd.demfeetype;

-- ---------------------------------------------------------------------------
-- 2) APPLY -- COMMENTED OUT. Check query 1 first: will_deduct should equal the
--    refund, and new_paidamount should equal the net fee.
-- ---------------------------------------------------------------------------
-- WITH refunded AS (
--   SELECT rd.dem_id, SUM(rd.refundamount) AS refunded
--     FROM kch20262027.fee_refunddetails rd
--     JOIN kch20262027.fee_refund r ON r.rf_id = rd.rf_id
--    WHERE r.activestatus = 1 AND COALESCE(rd.refundamount, 0) > 0
--    GROUP BY rd.dem_id
-- )
-- UPDATE kch20262027.feedemand fd
--    SET paidamount = COALESCE(fd.paidamount,0)
--          - LEAST(rf.refunded,
--                  COALESCE(fd.paidamount,0) - GREATEST(fd.feeamount - COALESCE(fd.conamount,0), 0))
--   FROM refunded rf
--  WHERE rf.dem_id = fd.dem_id
--    AND fd.activestatus = 1
--    AND COALESCE(fd.paidamount,0) > GREATEST(fd.feeamount - COALESCE(fd.conamount,0), 0);

-- ---------------------------------------------------------------------------
-- 3) VERIFY -- after applying, this should return no rows.
-- ---------------------------------------------------------------------------
-- SELECT dem_id, stuadmno, demfeetype, feeamount, conamount, paidamount
--   FROM kch20262027.feedemand
--  WHERE activestatus = 1
--    AND COALESCE(paidamount,0) + COALESCE(conamount,0) > feeamount;
