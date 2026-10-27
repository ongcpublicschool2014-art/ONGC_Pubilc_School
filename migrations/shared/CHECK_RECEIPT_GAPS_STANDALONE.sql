-- =====================================================================
-- RECEIPT REGISTER CHECK -- read only. Safe on live, any time.
--
-- Installs nothing, changes nothing, locks nothing. One SELECT.
--
-- The FC26/ series is shared by THREE tables, so a check that scans `payment`
-- alone reports every misc and advance receipt as a missing number:
--     payment.paynumber            fee receipts
--     misc_collection.mcno         miscellaneous receipts
--     advance_collection.advno     advance receipts
-- This counts all three.
--
-- READ THE OUTPUT LIKE THIS:
--   rows marked 'total'   -- how many numbers each table holds
--   row  marked 'counter' -- sequence.seqcurno; the totals must add up to it
--   rows marked 'GAP'     -- a number issued to nothing. NONE is the healthy
--                            result and means the register is continuous.
-- =====================================================================

WITH used AS (
  SELECT (regexp_match(p.paynumber, '([0-9]+)$'))[1]::bigint AS n,
         p.paynumber::text AS no, 'fee'::text AS src, p.paydate::date AS dated
    FROM kcet20262027.payment p
   WHERE p.paynumber LIKE 'FC26/%' AND p.paynumber ~ '[0-9]$'
  UNION ALL
  SELECT (regexp_match(m.mcno, '([0-9]+)$'))[1]::bigint,
         m.mcno::text, 'misc', m.mcdate::date
    FROM kcet20262027.misc_collection m
   WHERE m.mcno LIKE 'FC26/%' AND m.mcno ~ '[0-9]$'
  UNION ALL
  SELECT (regexp_match(a.advno, '([0-9]+)$'))[1]::bigint,
         a.advno::text, 'advance', a.advdate::date
    FROM kcet20262027.advance_collection a
   WHERE a.advno LIKE 'FC26/%' AND a.advno ~ '[0-9]$'
),
seq AS (
  SELECT COALESCE(seqcurno, 0)::bigint AS hi, COALESCE(seqwidth, 5)::int AS w
    FROM kcet20262027.sequence WHERE seq_id = 1
),
-- from the first number actually issued, so a series adopted mid-year does not
-- report everything before it as lost.
span AS (SELECT COALESCE(MIN(n), 1) AS lo FROM used)
SELECT * FROM (
  SELECT 1 AS ord, 'total'::text AS kind, u.src AS detail,
         count(*)::text AS value, MIN(u.n)::text AS lowest, MAX(u.n)::text AS highest
    FROM used u GROUP BY u.src
  UNION ALL
  SELECT 2, 'counter', 'sequence.seqcurno', s.hi::text,
         'the totals above must add up to this', ''
    FROM seq s
  UNION ALL
  SELECT 3, 'GAP', 'FC26/' || lpad(g.g::text, (SELECT w FROM seq), '0'),
         'issued to nothing',
         COALESCE((SELECT u.no || ' (' || u.dated || ')' FROM used u
                    WHERE u.n < g.g ORDER BY u.n DESC LIMIT 1), '-'),
         COALESCE((SELECT u.no || ' (' || u.dated || ')' FROM used u
                    WHERE u.n > g.g ORDER BY u.n LIMIT 1), '-')
    FROM span, seq, generate_series(span.lo, seq.hi) AS g(g)
   WHERE NOT EXISTS (SELECT 1 FROM used u WHERE u.n = g.g)
) r
ORDER BY r.ord, r.detail;
