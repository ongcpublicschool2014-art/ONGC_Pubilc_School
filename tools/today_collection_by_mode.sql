-- =====================================================================
-- TODAY'S COLLECTION BY MODE -- read only.
--
-- ONE result set: the Supabase editor shows only the last one, so the
-- three sources are UNIONed rather than queried separately.
--
-- THREE TABLES, NOT ONE. The FC26/ receipt series is shared by
-- payment, misc_collection and advance_collection, so a query against
-- payment alone under-reports the day and will not tie to the counter.
--
-- ADVANCE ADJUSTMENT IS EXCLUDED on purpose. Applying a held advance to
-- a fee writes a payment row with paymethod 'Advance Adjustment', but no
-- money arrives that day -- it was banked when the advance was taken.
-- Counting it would double it and inflate the day against the bank.
--
-- Change the one date in `bounds` to look at any other day.
-- =====================================================================

WITH bounds AS (SELECT CURRENT_DATE AS d),

rows AS (
  -- 1. FEE COLLECTION
  SELECT p.ins_id,
         'Fee'                                        AS source,
         upper(btrim(coalesce(p.paymethod, '—')))     AS mode,
         p.transtotalamount                           AS amount
    FROM kcet20262027.payment p, bounds b
   WHERE p.activestatus = 1
     AND p.paystatus    = 'C'
     AND p.paydate::date = b.d
     AND upper(btrim(coalesce(p.paymethod, ''))) <> 'ADVANCE ADJUSTMENT'

  UNION ALL

  -- 2. MISC COLLECTION   (mcdate is a DATE already, so no cast needed)
  SELECT m.ins_id,
         'Misc',
         upper(btrim(coalesce(m.paymode, '—'))),
         m.totalamount
    FROM kcet20262027.misc_collection m, bounds b
   WHERE m.activestatus = 1
     AND coalesce(m.paystatus, 'C') = 'C'
     AND m.mcdate = b.d

  UNION ALL

  -- 3. ADVANCE COLLECTION  (money taken, counted on the day it arrived)
  SELECT a.ins_id,
         'Advance',
         upper(btrim(coalesce(a.paymethod, '—'))),
         a.transtotalamount
    FROM kcet20262027.advance_collection a, bounds b
   WHERE a.activestatus = 1
     AND a.paystatus    = 'C'
     AND a.advdate::date = b.d
)

SELECT coalesce(mode, 'ALL MODES')            AS mode,
       coalesce(source, 'all')                AS source,
       count(*)                               AS receipts,
       sum(amount)                            AS amount
  FROM rows
 GROUP BY GROUPING SETS ((mode, source), (mode), ())
 ORDER BY grouping(mode), mode, grouping(source), source;
