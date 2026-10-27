-- Read only. Run on LIVE before raising the back-dated Rs 8,000 receipt.
--
-- The receipt takes the NEXT number in the series but would be dated 1 Oct.
-- If receipts have already been issued on 2 or 3 Oct, the register then runs
-- OUT OF ORDER: a higher number carrying an older date, sitting between two
-- newer ones. That is the first thing an auditor notices in a receipt book.
--
-- Read the second result:
--   only 2026-10-01 rows      -> back-dating is safe, nothing comes after it
--   rows dated 2 or 3 Oct too -> back-dating puts this receipt out of order;
--                                decide whether that matters to you

SELECT 'next number this receipt takes' AS item,
       'FC26/' || lpad((seqcurno + 1)::text, seqwidth::int, '0') AS value
  FROM kcet20262027.sequence WHERE seq_id = 1
UNION ALL
SELECT 'last receipt issued',
       (SELECT paynumber || '   dated ' || paydate::date
          FROM kcet20262027.payment
         WHERE paynumber ~ '^FC26/[0-9]+$' AND activestatus = 1
         ORDER BY (regexp_match(paynumber,'([0-9]+)$'))[1]::int DESC LIMIT 1);

-- Every receipt dated on or after the missing payment.
SELECT paydate::date AS dated, count(*) AS receipts,
       min(paynumber) AS lowest_no, max(paynumber) AS highest_no
  FROM kcet20262027.payment
 WHERE paynumber ~ '^FC26/[0-9]+$' AND activestatus = 1
   AND paydate >= DATE '2026-10-01'
 GROUP BY 1 ORDER BY 1;
