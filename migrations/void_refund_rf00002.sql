-- Cancel RF00002 (262790, 2026-09-05, Cash 2,500).
--
-- ONLY run this if no cash actually left the till on 05-09-2026.
--
-- Why it is the likely answer: for this student
--     collected 62,000 - refunded 7,500 = 54,500 held, against a 59,500 net fee
-- leaves 5,000 unaccounted, while the demands can only carry 2,500 once
-- repair_feedemand_balance.sql restores the invariant (ANNA 2,200 + SPORTS
-- 300). The missing 2,500 is exactly RF00002. Voiding it makes every figure
-- agree: refunded 5,000, held 57,000, owed 2,500.
--
-- If the cash DID leave, do NOT run this. The 2,500 is then a real
-- over-refund to recover from the student, and it does not belong in
-- feedemand -- record it however you handle other receivables.
--
-- IMPORTANT: this deliberately does NOT touch feedemand. RF00002 never
-- reduced paidamount in the first place (that was the original bug), so there
-- is no demand-side effect to undo. Reversing one here would double-count.
--
-- >>> Replace kch20262027 with your schema (4 places). Run query 1 first. <<<

-- ---------------------------------------------------------------------------
-- 1) PREVIEW -- confirm this is the voucher you mean. Expect 2 lines,
--    2,200 + 300, refundmode Cash, dated 2026-09-05.
-- ---------------------------------------------------------------------------
SELECT r.rf_id, r.doc_no, r.refunddate, r.refundmode, r.totalrefund,
       r.activestatus, rd.dem_id, rd.refundfeetype, rd.refundamount
  FROM kch20262027.fee_refund r
  JOIN kch20262027.fee_refunddetails rd ON rd.rf_id = r.rf_id
 WHERE r.stuadmno = '262790' AND r.doc_no = 'RF00002'
 ORDER BY rd.rfd_id;

-- ---------------------------------------------------------------------------
-- 2) VOID -- COMMENTED OUT. Uncomment only after checking the cash book.
-- ---------------------------------------------------------------------------
-- UPDATE kch20262027.fee_refunddetails
--    SET activestatus = 9
--  WHERE rf_id IN (SELECT rf_id FROM kch20262027.fee_refund
--                   WHERE stuadmno = '262790' AND doc_no = 'RF00002');
--
-- UPDATE kch20262027.fee_refund
--    SET activestatus = 9,
--        refundreason = COALESCE(NULLIF(refundreason,''), '')
--          || ' [voided: recorded but never paid out]'
--  WHERE stuadmno = '262790' AND doc_no = 'RF00002';

-- ---------------------------------------------------------------------------
-- 3) VERIFY -- refunded should read 5,000 and held should read 57,000,
--    leaving 2,500 owed, which is what the repaired demands carry.
-- ---------------------------------------------------------------------------
SELECT
  (SELECT COALESCE(SUM(pd.transtotalamount),0)
     FROM kch20262027.paymentdetails pd
     JOIN kch20262027.payment p    ON p.pay_id  = pd.pay_id
     JOIN kch20262027.feedemand fd ON fd.dem_id = pd.dem_id
    WHERE fd.stuadmno = '262790' AND p.activestatus = 1 AND pd.activestatus = 1) AS collected,
  (SELECT COALESCE(SUM(rd.refundamount),0)
     FROM kch20262027.fee_refunddetails rd
     JOIN kch20262027.fee_refund r ON r.rf_id = rd.rf_id
    WHERE r.stuadmno = '262790' AND r.activestatus = 1 AND rd.activestatus = 1) AS refunded,
  (SELECT COALESCE(SUM(balancedue),0)
     FROM kch20262027.feedemand
    WHERE stuadmno = '262790' AND activestatus = 1) AS demand_balance;
