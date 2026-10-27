-- ============================================================================
-- Gaps and duplicates in the receipt-number series.
-- ============================================================================
-- READ THIS FIRST, or the answer will be wrong.
--
-- ONE SERIES, THREE TABLES. A receipt number is drawn from the fee group's
-- sequence, and three different kinds of collection draw from the same one:
--     payment.paynumber             fee collection
--     misc_collection.mcno          counter collection (BONAFIDE, ...)
--     advance_collection.advno      advances
-- So FC26/00412 may be a misc receipt sitting between two fee receipts.
-- Checking `payment` on its own reports every misc and advance receipt as a
-- missing number -- hundreds of false gaps on this database. The live series
-- was verified clean in October 2026; every "gap" found that way was one of
-- these. All three are unioned below.
--
-- CANCELLED RECEIPTS ARE NOT GAPS. A voided or refunded receipt keeps its
-- number -- the number was issued and must never be reused. So nothing here
-- filters on activestatus or paystatus: the question is "was this number
-- handed out", not "is it still live". Filtering them out is the second way
-- to manufacture false gaps.
--
-- Each query stands alone. Run them one at a time -- the Supabase editor
-- shows only the last result set.
--
-- Schema is kcet20262027 throughout; change it for another institution-year.
-- ============================================================================


-- ======================================================== 1. THE SUMMARY ===
-- One row per prefix. issued vs span tells you instantly whether there is
-- anything to chase: missing = 0 means the series is unbroken.
-- ===========================================================================

WITH nums AS (
  SELECT paynumber AS rno FROM kcet20262027.payment            WHERE paynumber IS NOT NULL AND btrim(paynumber) <> ''
  UNION ALL
  SELECT mcno             FROM kcet20262027.misc_collection    WHERE mcno      IS NOT NULL AND btrim(mcno)      <> ''
  UNION ALL
  SELECT advno            FROM kcet20262027.advance_collection WHERE advno     IS NOT NULL AND btrim(advno)     <> ''
), parsed AS (
  -- Split on the TRAILING digits only: 'FC26/03794' -> prefix 'FC26/', 3794.
  -- The prefix itself contains digits (the year), so anchoring at the end is
  -- what keeps 'FC26/' intact.
  SELECT btrim(rno)                                        AS rno,
         regexp_replace(btrim(rno), '[0-9]+$', '')         AS prefix,
         (regexp_match(btrim(rno), '([0-9]+)$'))[1]::bigint AS seq,
         length((regexp_match(btrim(rno), '([0-9]+)$'))[1]) AS width
    FROM nums
   WHERE btrim(rno) ~ '[0-9]+$'
)
SELECT prefix,
       count(*)                        AS issued,
       count(DISTINCT seq)             AS distinct_numbers,
       min(seq)                        AS lowest,
       max(seq)                        AS highest,
       max(seq) - min(seq) + 1         AS span,
       max(seq) - min(seq) + 1 - count(DISTINCT seq) AS missing,
       count(*) - count(DISTINCT seq)  AS duplicates,
       max(width)                      AS digits
  FROM parsed
 GROUP BY prefix
 ORDER BY prefix;


-- ====================================================== 2. THE GAPS, LISTED =
-- Every number between the lowest and highest issued that nothing used,
-- rebuilt into the printed form. Empty result = no gaps.
-- ===========================================================================

WITH nums AS (
  SELECT paynumber AS rno FROM kcet20262027.payment            WHERE paynumber IS NOT NULL AND btrim(paynumber) <> ''
  UNION ALL
  SELECT mcno             FROM kcet20262027.misc_collection    WHERE mcno      IS NOT NULL AND btrim(mcno)      <> ''
  UNION ALL
  SELECT advno            FROM kcet20262027.advance_collection WHERE advno     IS NOT NULL AND btrim(advno)     <> ''
), parsed AS (
  SELECT regexp_replace(btrim(rno), '[0-9]+$', '')          AS prefix,
         (regexp_match(btrim(rno), '([0-9]+)$'))[1]::bigint AS seq,
         length((regexp_match(btrim(rno), '([0-9]+)$'))[1]) AS width
    FROM nums
   WHERE btrim(rno) ~ '[0-9]+$'
), bounds AS (
  SELECT prefix, min(seq) AS lo, max(seq) AS hi, max(width) AS width
    FROM parsed GROUP BY prefix
)
SELECT b.prefix,
       g                                        AS missing_number,
       b.prefix || lpad(g::text, b.width, '0')  AS looks_like
  FROM bounds b
 CROSS JOIN LATERAL generate_series(b.lo, b.hi) AS g
 WHERE NOT EXISTS (SELECT 1 FROM parsed p
                    WHERE p.prefix = b.prefix AND p.seq = g)
 ORDER BY b.prefix, g;


-- ================================================== 3. THE SAME NUMBER TWICE =
-- Worse than a gap: two receipts printed with one number. Shows which table
-- each came from, because a collision across tables means the shared
-- sequence was read twice without being advanced.
-- ===========================================================================

WITH nums AS (
  SELECT 'payment'  AS src, pay_id::text AS id, paynumber AS rno, paydate::date AS dt, transtotalamount AS amt
    FROM kcet20262027.payment            WHERE paynumber IS NOT NULL AND btrim(paynumber) <> ''
  UNION ALL
  SELECT 'misc',     mc_id::text,  mcno,  mcdate,  totalamount
    FROM kcet20262027.misc_collection    WHERE mcno      IS NOT NULL AND btrim(mcno)      <> ''
  UNION ALL
  SELECT 'advance',  adv_id::text, advno, advdate::date, transtotalamount
    FROM kcet20262027.advance_collection WHERE advno     IS NOT NULL AND btrim(advno)     <> ''
)
SELECT rno, count(*) AS times_used,
       string_agg(src || '#' || id || ' ' || COALESCE(dt::text, '?') ||
                  ' Rs' || COALESCE(amt::text, '?'), '  |  ' ORDER BY src, id) AS rows_sharing_it
  FROM nums
 GROUP BY rno
HAVING count(*) > 1
 ORDER BY rno;


-- ============================================ 4. SERIES vs THE COUNTER ======
-- The sequence row says what has been HANDED OUT; the tables say what was
-- USED. seqcurno behind the highest used number means something issued a
-- receipt without advancing the counter -- the next collection will collide.
-- Ahead is normal and harmless: numbers drawn for attempts that never became
-- receipts.
-- ===========================================================================

WITH nums AS (
  SELECT paynumber AS rno FROM kcet20262027.payment            WHERE paynumber IS NOT NULL AND btrim(paynumber) <> ''
  UNION ALL
  SELECT mcno             FROM kcet20262027.misc_collection    WHERE mcno      IS NOT NULL AND btrim(mcno)      <> ''
  UNION ALL
  SELECT advno            FROM kcet20262027.advance_collection WHERE advno     IS NOT NULL AND btrim(advno)     <> ''
), used AS (
  SELECT regexp_replace(btrim(rno), '[0-9]+$', '')          AS prefix,
         max((regexp_match(btrim(rno), '([0-9]+)$'))[1]::bigint) AS highest_used
    FROM nums WHERE btrim(rno) ~ '[0-9]+$' GROUP BY 1
)
SELECT s.actname,
       s.seqprefix,
       s.seqcurno                AS counter,
       u.highest_used,
       CASE
         WHEN u.highest_used IS NULL              THEN 'nothing issued yet'
         WHEN s.seqcurno >= u.highest_used        THEN 'OK'
         ELSE 'BEHIND -- next receipt will collide'
       END                       AS verdict
  FROM kcet20262027.sequence s
  LEFT JOIN used u ON u.prefix = s.seqprefix
 WHERE s.activestatus = 1
   AND s.actname <> 'REGNO'      -- register numbers are not receipts
 ORDER BY s.actname;
