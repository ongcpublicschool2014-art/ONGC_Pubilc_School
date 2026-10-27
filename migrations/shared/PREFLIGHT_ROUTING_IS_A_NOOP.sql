-- =====================================================================
-- Read only. Run on LIVE before releasing desktop 0.0.10.
--
-- 0.0.10 routes a collection to its FEE GROUP's own Paytm merchant whenever
-- that group's bank names one, instead of always using the institution's. On a
-- database with one fee group that should change nothing -- but only if the
-- group's bank resolves to the SAME merchant the institution already uses.
--
-- This says whether that is true here. Every row must read 'no change'.
-- A row reading 'MONEY MOVES' means collections for that group would start
-- settling into a different Paytm account the moment 0.0.10 is installed.
-- =====================================================================
SELECT g.fgdesc                                   AS fee_group,
       COALESCE(b.banname || ' ' || b.banaccno, '(no bank mapped)') AS bank,
       COALESCE(NULLIF(trim(b.paytm_mid), ''), '(none)')            AS group_merchant,
       (SELECT merchant_id FROM public.paytm_configuration
         WHERE institution_id = g.ins_id LIMIT 1)                   AS institution_merchant,
       CASE
         WHEN COALESCE(trim(b.paytm_mid), '') = ''
           THEN 'no change - falls back to the institution merchant'
         WHEN trim(b.paytm_mid) = (SELECT merchant_id FROM public.paytm_configuration
                                    WHERE institution_id = g.ins_id LIMIT 1)
           THEN 'no change - same merchant as today'
         ELSE '*** MONEY MOVES - this group would settle elsewhere ***'
       END AS effect_of_0_0_10
  FROM kcet20262027.feegroup g
  LEFT JOIN kcet20262027.bank b ON b.ban_id = g.ban_id
 WHERE g.ins_id = 1 AND g.activestatus = 1
 ORDER BY g.fg_id;
