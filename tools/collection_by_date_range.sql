-- =====================================================================
-- COLLECTION OVER A DATE RANGE -- read only.
--
-- Set the two dates in `bounds`. Both ends are INCLUSIVE.
--
-- ONE result set, in four blocks, because the Supabase editor shows only
-- the last one:
--
--     1. each day, split by mode
--     2. each day, total
--     3. the whole range, split by mode
--     4. the whole range, total           <- the figure most people want
--
-- THREE TABLES. The FC26/ series is shared by payment, misc_collection
-- and advance_collection, so a query against payment alone under-reports
-- the range and will not tie to the counter.
--
-- ADVANCE ADJUSTMENT IS EXCLUDED. Applying a held advance to a fee writes
-- a payment row, but no money arrives that day -- it was banked when the
-- advance was taken. Counting it would inflate the range against the bank.
-- =====================================================================

WITH bounds AS (
  SELECT DATE '2026-10-01' AS d_from,     -- <<< change
         DATE '2026-10-07' AS d_to        -- <<< change
),

rows AS (
  -- 1. FEE COLLECTION
  SELECT p.paydate::date                              AS d,
         upper(btrim(coalesce(p.paymethod, '—')))     AS mode,
         p.transtotalamount                           AS amount
    FROM kcet20262027.payment p, bounds b
   WHERE p.activestatus = 1
     AND p.paystatus    = 'C'
     AND p.paydate::date BETWEEN b.d_from AND b.d_to
     AND upper(btrim(coalesce(p.paymethod, ''))) <> 'ADVANCE ADJUSTMENT'

  UNION ALL

  -- 2. MISC COLLECTION   (mcdate is a DATE already, so no cast needed)
  SELECT m.mcdate,
         upper(btrim(coalesce(m.paymode, '—'))),
         m.totalamount
    FROM kcet20262027.misc_collection m, bounds b
   WHERE m.activestatus = 1
     AND coalesce(m.paystatus, 'C') = 'C'
     AND m.mcdate BETWEEN b.d_from AND b.d_to

  UNION ALL

  -- 3. ADVANCE COLLECTION  (counted on the day the money arrived)
  SELECT a.advdate::date,
         upper(btrim(coalesce(a.paymethod, '—'))),
         a.transtotalamount
    FROM kcet20262027.advance_collection a, bounds b
   WHERE a.activestatus = 1
     AND a.paystatus    = 'C'
     AND a.advdate::date BETWEEN b.d_from AND b.d_to
)

SELECT CASE WHEN grouping(d)    = 1 THEN 'WHOLE RANGE' ELSE d::text END AS day,
       CASE WHEN grouping(mode) = 1 THEN 'ALL MODES'   ELSE mode     END AS mode,
       count(*)   AS receipts,
       sum(amount) AS amount
  FROM rows
 GROUP BY GROUPING SETS ((d, mode), (d), (mode), ())
 ORDER BY grouping(d), d, grouping(mode), mode;
