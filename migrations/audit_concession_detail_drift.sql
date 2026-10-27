-- Concession history vs the demand.
--
-- money_invariant_hardening.sql section 4 stops NEW vouchers from writing the
-- full total into concessiondetail. Rows already written that way are still in
-- the table: two 3,000 vouchers against one demand sum to 6,000 while the
-- demand correctly holds 3,000, so any report that adds up the detail rows
-- over-states the concession. kch20262027 CN00007 / CN00008 on ALAIMAN M I's
-- TUITION FEE demand are the known case.
--
-- feedemand.conamount is the authority here and is NOT touched by anything in
-- this file.
--
-- >>> Replace kch20262027 with your schema (3 places). Run query 1 first. <<<

-- ---------------------------------------------------------------------------
-- 1) Where the voucher history disagrees with the demand.
--    detail_total > conamount  -> a repeat voucher re-stated the whole total.
-- ---------------------------------------------------------------------------
SELECT fd.dem_id,
       fd.stuadmno,
       fd.demfeetype,
       fd.feeamount,
       fd.conamount            AS demand_concession,
       SUM(cd.conamount)       AS detail_total,
       SUM(cd.conamount) - fd.conamount AS drift,
       COUNT(*)                AS voucher_lines,
       string_agg(DISTINCT cd.receiptno, ', ' ORDER BY cd.receiptno) AS vouchers
  FROM kch20262027.feedemand fd
  JOIN kch20262027.concessiondetail cd
    ON cd.dem_id = fd.dem_id AND cd.activestatus = 1
 WHERE fd.activestatus = 1
 GROUP BY fd.dem_id, fd.stuadmno, fd.demfeetype, fd.feeamount, fd.conamount
HAVING SUM(cd.conamount) <> fd.conamount
 ORDER BY ABS(SUM(cd.conamount) - fd.conamount) DESC;

-- ---------------------------------------------------------------------------
-- 2) The totals -- how much concession the reports over-state.
-- ---------------------------------------------------------------------------
WITH per_demand AS (
  SELECT fd.dem_id, fd.conamount, SUM(cd.conamount) AS detail_total
    FROM kch20262027.feedemand fd
    JOIN kch20262027.concessiondetail cd
      ON cd.dem_id = fd.dem_id AND cd.activestatus = 1
   WHERE fd.activestatus = 1
   GROUP BY fd.dem_id, fd.conamount
)
SELECT COUNT(*) FILTER (WHERE detail_total <> conamount) AS drifting_demands,
       COALESCE(SUM(GREATEST(detail_total - conamount, 0)), 0) AS over_stated,
       COALESCE(SUM(GREATEST(conamount - detail_total, 0)), 0) AS under_stated
  FROM per_demand;

-- ---------------------------------------------------------------------------
-- 3) REPAIR -- COMMENTED OUT. Read queries 1 and 2 first.
--
-- Rewrites each LATER voucher line as the delta it actually applied, keeping
-- the earliest line as the opening amount, so the lines sum to the demand's
-- conamount. Vouchers stay in place with their doc numbers; only the amount
-- carried on the repeat lines changes.
--
-- Check query 1's output first: if a demand's drift is not explained by a
-- repeat voucher (e.g. a genuine second concession that SHOULD have added up),
-- fix that one by hand instead -- this rewrite assumes the repeats were
-- re-statements, which is what the old process_concession produced.
--
-- ONLY drifting demands are touched, and that is what makes this safe to run
-- twice. The rewrite reads each line as a running TOTAL and turns it into a
-- delta; once a demand is repaired its lines are already deltas, so re-reading
-- them as totals would produce nonsense (3000, 0 would become 3000, -3000).
-- Restricting to demands that still disagree with feedemand.conamount means a
-- repaired demand drops out of the set and a second run does nothing.
-- ---------------------------------------------------------------------------
-- WITH drifting AS (
--   SELECT cd.dem_id
--     FROM kch20262027.concessiondetail cd
--     JOIN kch20262027.feedemand fd
--       ON fd.dem_id = cd.dem_id AND fd.activestatus = 1
--    WHERE cd.activestatus = 1
--    GROUP BY cd.dem_id, fd.conamount
--   HAVING SUM(cd.conamount) <> fd.conamount
-- ), ranked AS (
--   SELECT cd.ctid,
--          cd.conamount,
--          ROW_NUMBER() OVER (PARTITION BY cd.dem_id ORDER BY cd.con_hdr_id) AS rn,
--          LAG(cd.conamount) OVER (PARTITION BY cd.dem_id ORDER BY cd.con_hdr_id) AS prev_total
--     FROM kch20262027.concessiondetail cd
--    WHERE cd.activestatus = 1
--      AND cd.dem_id IN (SELECT dem_id FROM drifting)
-- )
-- UPDATE kch20262027.concessiondetail c
--    SET conamount = r.conamount - COALESCE(r.prev_total, 0)
--   FROM ranked r
--  WHERE c.ctid = r.ctid
--    AND r.rn > 1;

-- After repairing, query 1 should return no rows.
