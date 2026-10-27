-- =====================================================================
-- Restore fee amounts on demands billed zero with NOTHING collected.
-- Companion to FIX_ZERO_BILLED_DEMANDS.sql (the rows that had money).
--
-- REGENERATED 07-10-2026 against live as of 12:20. The two earlier
-- versions of this script were WRONG; neither should be run.
--
-- THE TRAP. The 03-09 sheet splits a scholarship student's tuition in
-- two: TUITION FEE carries the student's share, SC/ST SCHOLARSHIP or
-- FIRST GRADUATE AMOUNT carries the granted part, and together they make
-- the full fee. Since 09-09 the office has been consolidating: where a
-- grant was never awarded they put the whole fee on the tuition line and
-- leave the grant at zero. That zero is CORRECT, and restoring it bills
-- the student twice.
--
-- THE RULE APPLIED HERE, which the previous version got wrong by testing
-- only for exact consolidation: a grant line is restored ONLY IF the
-- student's tuition + grants stay within the sheet's full fee. Anything
-- that would push them over is dropped. Partially-corrected students
-- (tuition already raised but not to the full figure) are caught by this
-- and were not caught before -- 421325106024 would have gone to 84,000
-- against a 55,000 fee.
--
-- Rows restored: 41
-- Rows dropped to avoid over-billing: 32
--
-- Every row has paidamount = 0, so the amount cannot contradict a
-- payment. Re-running changes nothing.
--
-- STILL NEEDS THE OFFICE, in neither script:
--   262791 CHANDRU R, BUS FEES -- billed 0, 10,000 collected, added by
--   hand on 05-10 after the sheet, so no sheet figure exists.
-- =====================================================================

SELECT count(*) AS zero_billed_no_payment
  FROM kcet20262027.feedemand
 WHERE activestatus = 1 AND COALESCE(feeamount,0) = 0 AND COALESCE(paidamount,0) = 0;

WITH correct(stuadmno, demfeetype, demfeeterm, amount) AS (VALUES
  ('421325106002', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000::numeric),
  ('421325106003', 'A.U.SPORTS FEE', 'YEARLY', 125),
  ('421325106006', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106011', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106012', 'A.U.SPORTS FEE', 'YEARLY', 125),
  ('421325106012', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106012', 'TUITION FEE', 'YEARLY', 30000),
  ('421325106017', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106018', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106019', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106020', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106021', 'SC/ST SCHOLARSHIP', 'YEARLY', 50000),
  ('421325106025', 'A.U.SPORTS FEE', 'YEARLY', 125),
  ('421325106025', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106025', 'TUITION FEE', 'YEARLY', 30000),
  ('421325106026', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106030', 'A.U.SPORTS FEE', 'YEARLY', 125),
  ('421325106030', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106034', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106035', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106037', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106038', 'A.U.SPORTS FEE', 'YEARLY', 125),
  ('421325106038', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106039', 'SC/ST SCHOLARSHIP', 'YEARLY', 50000),
  ('421325106040', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106041', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106042', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106045', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106046', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106047', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106049', 'A.U.SPORTS FEE', 'YEARLY', 125),
  ('421325106050', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106051', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106052', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106053', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325106059', 'FIRST GRADUATE AMOUNT', 'YEARLY', 25000),
  ('421325243014', 'FINE', 'III SEM', 100),
  ('421325243016', 'BUS FEES', 'III SEM', 7100),
  ('421325243037', 'FINE', 'III SEM', 100),
  ('421325243040', 'FINE', 'III SEM', 100),
  ('421325243058', 'FINE', 'III SEM', 100)
)
UPDATE kcet20262027.feedemand fd
   SET feeamount       = c.amount,
       balancedue      = GREATEST(c.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0),
       reconbalancedue = GREATEST(c.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0),
       paidstatus      = CASE WHEN c.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0) <= 0
                              THEN 'P' ELSE 'U' END
  FROM correct c
 WHERE fd.stuadmno     = c.stuadmno
   AND fd.demfeetype   = c.demfeetype
   AND fd.demfeeterm   = c.demfeeterm
   AND fd.activestatus = 1
   AND COALESCE(fd.feeamount,0)  = 0
   AND COALESCE(fd.paidamount,0) = 0;

SELECT count(*) AS zero_billed_no_payment
  FROM kcet20262027.feedemand
 WHERE activestatus = 1 AND COALESCE(feeamount,0) = 0 AND COALESCE(paidamount,0) = 0;

-- Still zero-billed with money on it. ONE row expected: 262791.
SELECT stuadmno, demfeetype, feeamount, paidamount
  FROM kcet20262027.feedemand
 WHERE activestatus = 1
   AND COALESCE(feeamount,0) - COALESCE(conamount,0) <= 0
   AND COALESCE(paidamount,0) > 0;
