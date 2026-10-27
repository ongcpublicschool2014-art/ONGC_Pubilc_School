-- =====================================================================
-- Which receipts will change DAY when the IST migration runs, and by how much
-- each day's collection total moves.
--
-- Read-only. Changes nothing. Safe to run on live at any time.
--
-- There are TWO queries below. Run ONE of them -- the Supabase editor shows
-- only the LAST result set, so running both shows you only the second.
--
--   QUERY A -- for a database that has NOT yet been migrated (still UTC).
--             Predicts what will move. This is the one to run on LIVE now.
--   QUERY B -- for a database already migrated (TEST). Confirms what did move.
--
-- A receipt changes day only if it was taken between 00:00 and 05:30 IST,
-- which in UTC is 18:30-23:59 of the previous day. Everything else keeps its
-- date and only its printed TIME moves forward 5h30m.
-- =====================================================================


-- ---------------------------------------------------------------------
-- QUERY A -- BEFORE the migration (run this on LIVE)
-- ---------------------------------------------------------------------
WITH moving AS (
  SELECT 'Fee'::text AS src, paynumber::text AS receipt, transtotalamount AS amount,
         paydate::date AS dated_now,
         (paydate + interval '5 hours 30 minutes')::date AS dated_after
    FROM kcet20262027.payment
   WHERE paynumber IS NOT NULL AND activestatus = 1
     AND paydate::time >= '18:30:00'
  UNION ALL
  SELECT 'Advance', advno::text, transtotalamount,
         advdate::date, (advdate + interval '5 hours 30 minutes')::date
    FROM kcet20262027.advance_collection
   WHERE activestatus = 1
     AND advdate::time >= '18:30:00'
  UNION ALL
  -- mcdate is a DATE defaulted from CURRENT_DATE, so it has no time to test.
  -- createdat here is timestamptz -- an absolute instant -- so the true IST
  -- day is exact. Only rows that were DEFAULTED (stored day = UTC day) count;
  -- a hand-picked or back-dated mcdate is left alone by the migration.
  SELECT 'Misc', mcno::text, totalamount,
         mcdate, (createdat AT TIME ZONE 'Asia/Kolkata')::date
    FROM kcet20262027.misc_collection
   WHERE activestatus = 1 AND createdat IS NOT NULL
     AND mcdate =  (createdat AT TIME ZONE 'UTC')::date
     AND mcdate <> (createdat AT TIME ZONE 'Asia/Kolkata')::date
),
perday AS (
  SELECT dated_now   AS day, -sum(amount) AS delta FROM moving GROUP BY 1
  UNION ALL
  SELECT dated_after AS day,  sum(amount) AS delta FROM moving GROUP BY 1
)
SELECT '1. receipt that moves' AS section,
       src                     AS kind,
       receipt,
       amount,
       dated_now::text         AS from_day,
       dated_after::text       AS to_day
  FROM moving
UNION ALL
SELECT '2. net change to that day''s collection', '', '',
       sum(delta), day::text, ''
  FROM perday GROUP BY day
UNION ALL
SELECT '3. grand total -- must be IDENTICAL after the migration',
       'receipts: ' || count(*)::text, '',
       sum(transtotalamount), '', ''
  FROM kcet20262027.payment
 WHERE paynumber IS NOT NULL AND activestatus = 1
 ORDER BY 1, 5, 3;


-- ---------------------------------------------------------------------
-- QUERY B -- AFTER the migration (run this on TEST, or on live afterwards)
--
-- Same shape, read backwards: a receipt now dated between 00:00 and 05:30 is
-- one that crossed midnight. Exact 00:00:00 is excluded -- those are the
-- 9 Sep bulk import, which the migration deliberately does not shift.
-- ---------------------------------------------------------------------
-- WITH moved AS (
--   SELECT 'Fee'::text AS src, paynumber::text AS receipt, transtotalamount AS amount,
--          (paydate - interval '5 hours 30 minutes')::date AS was_dated,
--          paydate::date AS now_dated
--     FROM kcet20262027.payment
--    WHERE paynumber IS NOT NULL AND activestatus = 1
--      AND paydate::time > '00:00:00' AND paydate::time < '05:30:00'
--   UNION ALL
--   SELECT 'Advance', advno::text, transtotalamount,
--          (advdate - interval '5 hours 30 minutes')::date, advdate::date
--     FROM kcet20262027.advance_collection
--    WHERE activestatus = 1
--      AND advdate::time > '00:00:00' AND advdate::time < '05:30:00'
-- ),
-- perday AS (
--   SELECT was_dated AS day, -sum(amount) AS delta FROM moved GROUP BY 1
--   UNION ALL
--   SELECT now_dated AS day,  sum(amount) AS delta FROM moved GROUP BY 1
-- )
-- SELECT '1. receipt that moved' AS section, src AS kind, receipt, amount,
--        was_dated::text AS from_day, now_dated::text AS to_day
--   FROM moved
-- UNION ALL
-- SELECT '2. net change to that day''s collection', '', '',
--        sum(delta), day::text, ''
--   FROM perday GROUP BY day
-- UNION ALL
-- SELECT '3. grand total -- compare with the figure from QUERY A',
--        'receipts: ' || count(*)::text, '',
--        sum(transtotalamount), '', ''
--   FROM kcet20262027.payment
--  WHERE paynumber IS NOT NULL AND activestatus = 1
--  ORDER BY 1, 5, 3;
