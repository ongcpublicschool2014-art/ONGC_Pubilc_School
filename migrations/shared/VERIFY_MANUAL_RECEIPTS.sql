-- Read-only. Confirms the manually entered receipts landed cleanly.
WITH used AS (
  SELECT (regexp_match(p.paynumber,'([0-9]+)$'))[1]::bigint AS n, p.paynumber::text AS no
    FROM kcet20262027.payment p WHERE p.paynumber LIKE 'FC26/%' AND p.paynumber ~ '[0-9]$'
  UNION ALL
  SELECT (regexp_match(m.mcno,'([0-9]+)$'))[1]::bigint, m.mcno::text
    FROM kcet20262027.misc_collection m WHERE m.mcno LIKE 'FC26/%' AND m.mcno ~ '[0-9]$'
  UNION ALL
  SELECT (regexp_match(a.advno,'([0-9]+)$'))[1]::bigint, a.advno::text
    FROM kcet20262027.advance_collection a WHERE a.advno LIKE 'FC26/%' AND a.advno ~ '[0-9]$'
)
SELECT 'duplicate receipt numbers' AS check, COALESCE(string_agg(no,', '),'none - OK') AS detail
  FROM (SELECT no FROM used WHERE n IN (SELECT n FROM used GROUP BY n HAVING count(*)>1)) d;

-- the four students, and what they now hold
SELECT s.stuname, p.paynumber, p.paydate::date, p.paystatus,
       p.transtotalamount, COALESCE(p.payreference,'-') AS paytm_ref
  FROM kcet20262027.payment p
  JOIN kcet20262027.students s ON s.stu_id = p.stu_id
 WHERE s.stuname ILIKE ANY (ARRAY['%VIJAY J P%','%KARTHIKEYAN U%','%BHARATHI RAJA R%','%KEERTHIKA V%'])
   AND p.paynumber IS NOT NULL
   AND p.paydate >= DATE '2026-09-28'
 ORDER BY s.stuname, p.paynumber;

SELECT * FROM public.check_receipt_gaps(1);
