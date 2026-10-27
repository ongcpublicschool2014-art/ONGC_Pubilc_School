-- =====================================================================
-- Verify FIX_TIMEZONE_TO_IST_20261005.sql, in ONE result set.
--
-- The Supabase editor shows only the LAST result set, so the five separate
-- checks in the migration are invisible -- you see check 6 and nothing else.
-- This folds all of them into a single grid. Read-only.
--
-- Every row must say 'ok'.
-- =====================================================================
WITH tz AS (
  SELECT count(*) FILTER (WHERE array_to_string(setconfig, ',') ILIKE '%Asia/Kolkata%') AS ist_rows,
         count(*) AS tz_rows
    FROM pg_db_role_setting
   WHERE array_to_string(setconfig, ',') ILIKE '%timezone%'
),
peak AS (
  SELECT extract(hour from paydate)::int AS h, count(*) AS c
    FROM kcet20262027.payment
   WHERE paynumber IS NOT NULL AND activestatus = 1
     AND lower(COALESCE(paymethod, '')) = 'cash'
     AND paydate::time <> '00:00:00'
   GROUP BY 1 ORDER BY c DESC LIMIT 1
),
online AS (
  SELECT paydate, regexp_replace(payreference, '^PAYTM-WH:', '') AS ref
    FROM kcet20262027.payment
   WHERE paynumber IS NOT NULL AND activestatus = 1
     AND regexp_replace(payreference, '^PAYTM-WH:', '') ~ '^20[0-9]{6}[0-9]{10,}$'
),
strays AS (
  -- Exact-midnight paydate is the 9 Sep bulk import: deliberately not shifted,
  -- so it is still "dated before written" and is NOT a stray.
  SELECT count(*) AS n
    FROM kcet20262027.payment
   WHERE paynumber IS NOT NULL AND activestatus = 1
     AND paydate::date < createdat::date
     AND paydate::time <> '00:00:00'
     AND paynumber <> 'FC26/03327'   -- the Rs 8,000 recovery, back-dated on purpose
)
SELECT '1. timezone settings pointing at Asia/Kolkata' AS check,
       (SELECT ist_rows || ' of ' || tz_rows || ' row(s)' FROM tz) AS value,
       (SELECT CASE WHEN ist_rows > 0 AND ist_rows = tz_rows THEN 'ok'
                    WHEN ist_rows > 0 THEN 'PARTIAL - see note'
                    ELSE 'FAILED - nothing took' END FROM tz) AS state
UNION ALL
SELECT '2. busiest cash hour (was 05:00; want 09-11)',
       (SELECT h || ':00 with ' || c || ' receipts' FROM peak),
       (SELECT CASE WHEN h BETWEEN 9 AND 11 THEN 'ok' ELSE 'LOOK' END FROM peak)
UNION ALL
SELECT '3. online receipts on a different day to Paytm (want 4)',
       (SELECT count(*) FILTER (
                 WHERE paydate::date <> to_date(substring(ref, 1, 8), 'YYYYMMDD'))::text
          FROM online),
       (SELECT CASE WHEN count(*) FILTER (
                 WHERE paydate::date <> to_date(substring(ref, 1, 8), 'YYYYMMDD')) = 4
                    THEN 'ok' ELSE 'LOOK' END FROM online)
UNION ALL
SELECT '4. the three that prompted this, now on their Paytm day',
       (SELECT string_agg(paynumber || ' = ' || paydate::date, ',  ' ORDER BY paynumber)
          FROM kcet20262027.payment
         WHERE paynumber IN ('FC26/03272', 'FC26/03273', 'FC26/03330')),
       (SELECT CASE WHEN count(*) = 3 THEN 'ok' ELSE 'LOOK' END
          FROM kcet20262027.payment
         WHERE (paynumber IN ('FC26/03272', 'FC26/03273') AND paydate::date = DATE '2026-10-01')
            OR (paynumber = 'FC26/03330'                  AND paydate::date = DATE '2026-10-05'))
UNION ALL
SELECT '5. receipts still dated before they were written (want 0)',
       (SELECT n::text FROM strays),
       (SELECT CASE WHEN n = 0 THEN 'ok' ELSE 'LOOK' END FROM strays)
 ORDER BY 1;
