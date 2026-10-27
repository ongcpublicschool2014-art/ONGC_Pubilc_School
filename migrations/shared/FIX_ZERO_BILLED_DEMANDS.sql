-- =====================================================================
-- Restore the fee amounts on demands that were left billed at zero.
--
-- WHAT HAPPENED. On 09-09-2026 15:19:09 a batch rebuilt these demand rows
-- under payments that already existed (9 Jul - 9 Sep). It carried
-- paidamount across from the receipts but took feeamount from the class
-- template, and 5,710 of the 5,757 templates hold 0.00 -- the office
-- bills these per student through Fee Demand Import, so the templates
-- were never filled in.
--
-- Result: feeamount 0 with paidamount > 0. balancedue 0 means the demand
-- reads FULLY SETTLED, so nobody is chased and the money missing from it
-- is absent from the year's totals.
--
-- WHERE THE AMOUNTS COME FROM. KCET-StudRegFeeDemand03092026.xlsx, the
-- demand sheet exported on 03-09-2026 -- six days BEFORE the rebuild, so
-- it still holds what each student was actually billed. Matched on roll
-- number + fee type, never on demand number: the rebuild reissued those,
-- so 421325106034 is RF26/03177 in the sheet and RF26/03161 here.
--
-- TWO ROWS ARE DELIBERATELY NOT IN THIS SCRIPT:
--   421325106022  THE SHEET IS STALE FOR THIS ONE. It says tuition 5,000,
--                 and as of 03-09 that fitted: 1,775 paid on 13-08, 3,225
--                 left. Then 20,000 was paid on 05-09 -- two days AFTER
--                 the sheet -- bringing the total to 21,775. A 5,000 bill
--                 cannot explain that payment, so the bill was revised
--                 after the export (their sheet also carries SC/ST
--                 SCHOLARSHIP 50,000, which would do it if it fell
--                 through). The office has to supply the real figure.
--                 The student is NOT overpaid; the sheet is just old.
--   262791        a BUS FEES demand added by hand on 05-10-2026, after
--                 the sheet was taken. It is in no sheet; only the office
--                 knows what it should be.
--
-- SAFE TO RE-RUN. Only rows still billed zero are touched.
-- Read the BEFORE and AFTER outputs.
-- =====================================================================

-- BEFORE
SELECT fd.stuadmno, fd.demfeetype, fd.feeamount, fd.paidamount, fd.balancedue, fd.paidstatus
  FROM kcet20262027.feedemand fd
 WHERE fd.activestatus = 1
   AND COALESCE(fd.feeamount,0) - COALESCE(fd.conamount,0) <= 0
   AND COALESCE(fd.paidamount,0) > 0
 ORDER BY fd.stuadmno;

-- THE FIX
WITH correct(stuadmno, demfeetype, amount) AS (VALUES
  ('421325106005', 'TUITION FEE', 50000::numeric),
  ('421325106018', 'TUITION FEE', 25000),
  ('421325106034', 'TUITION FEE', 25000),
  ('421325106035', 'TUITION FEE', 30000),
  ('421325106042', 'TUITION FEE', 30000),
  ('421325106044', 'TUITION FEE', 55000),
  ('421325106052', 'TUITION FEE', 30000),
  ('421325106053', 'TUITION FEE', 30000),
  ('421325106054', 'TUITION FEE', 25000),
  ('421325106056', 'TUITION FEE', 50000),
  ('421325106057', 'TUITION FEE', 55000),
  ('262701',       'BUS FEES',    20000)
)
UPDATE kcet20262027.feedemand fd
   SET feeamount       = c.amount,
       -- The convention on every correctly billed row in this schema:
       -- balance = billed - concession - paid, and the two balance
       -- columns agree. No trigger maintains them, so they are set here.
       balancedue      = GREATEST(c.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0),
       reconbalancedue = GREATEST(c.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0),
       paidstatus      = CASE WHEN c.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0) <= 0
                              THEN 'P' ELSE 'U' END
  FROM correct c
 WHERE fd.stuadmno   = c.stuadmno
   AND fd.demfeetype = c.demfeetype
   AND fd.activestatus = 1
   -- Guard: only a row still billed nothing. A re-run changes nothing,
   -- and a demand somebody has since corrected by hand is left alone.
   AND COALESCE(fd.feeamount,0) = 0;

-- AFTER: the twelve now carry an amount; only the two deliberate
-- exclusions should still be listed as zero-billed.
SELECT fd.stuadmno, fd.demfeetype, fd.feeamount, fd.paidamount, fd.balancedue, fd.paidstatus
  FROM kcet20262027.feedemand fd
 WHERE fd.activestatus = 1
   AND COALESCE(fd.paidamount,0) > 0
   AND fd.stuadmno IN ('421325106005','421325106018','421325106022','421325106034',
                       '421325106035','421325106042','421325106044','421325106052',
                       '421325106053','421325106054','421325106056','421325106057',
                       '262701','262791')
 ORDER BY fd.feeamount, fd.stuadmno;

-- What is now genuinely outstanding on these, which read as settled before.
SELECT count(*) AS demands, sum(fd.balancedue) AS now_collectable
  FROM kcet20262027.feedemand fd
 WHERE fd.activestatus = 1
   AND fd.stuadmno IN ('421325106005','421325106018','421325106034','421325106035',
                       '421325106042','421325106044','421325106052','421325106053',
                       '421325106054','421325106056','421325106057','262701')
   AND fd.demfeetype IN ('TUITION FEE','BUS FEES')
   AND fd.balancedue > 0;
