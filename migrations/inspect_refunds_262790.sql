-- What actually happened to 262790's ANNA UNIVERSITY / A.U.SPORTS demands.
--
-- The ledger now shows balance 4,400 on a 2,200 fee and 600 on a 300 fee,
-- which is impossible: it is the old process_refund adding the refund onto
-- balancedue instead of deriving it. RF00002 (the 2,500 that never reduced
-- paidamount) and RF00003 (a full 5,000 taken today) are both against the
-- same two demands.
--
-- >>> Replace kch20262027 with your schema (3 places). Read-only. <<<

-- ---------------------------------------------------------------------------
-- 1) The demands as they stand now.
-- ---------------------------------------------------------------------------
SELECT dem_id, stuadmno, demfeetype,
       feeamount, conamount, paidamount, balancedue, reconbalancedue, paidstatus,
       GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0) AS balance_should_be
  FROM kch20262027.feedemand
 WHERE stuadmno = '262790' AND activestatus = 1
 ORDER BY demfeetype;

-- ---------------------------------------------------------------------------
-- 2) Every refund line against this student, oldest first.
--    adjustamount > 0 means it was settled against another fee rather than
--    paid out; refundmode / bankref say how the money was meant to leave.
-- ---------------------------------------------------------------------------
SELECT r.doc_no, r.refunddate, r.refundmode, r.bankref, r.totalrefund,
       r.totaladjust, r.activestatus AS refund_status, r.createdby,
       rd.dem_id, rd.refundfeetype, rd.feeamount, rd.refundamount, rd.adjustamount
  FROM kch20262027.fee_refund r
  JOIN kch20262027.fee_refunddetails rd ON rd.rf_id = r.rf_id
 WHERE r.stuadmno = '262790'
 ORDER BY r.rf_id, rd.rfd_id;

-- ---------------------------------------------------------------------------
-- 3) Money in vs money out for this student.
--    net_held should equal (total fee - concession) when the student is square.
-- ---------------------------------------------------------------------------
SELECT
  -- payment carries stu_id, not stuadmno, so the collection is tied to the
  -- student through their own demands -- the same way the ledger does it.
  (SELECT COALESCE(SUM(pd.transtotalamount),0)
     FROM kch20262027.paymentdetails pd
     JOIN kch20262027.payment p  ON p.pay_id  = pd.pay_id
     JOIN kch20262027.feedemand fd ON fd.dem_id = pd.dem_id
    WHERE fd.stuadmno = '262790' AND p.activestatus = 1 AND pd.activestatus = 1) AS collected,
  (SELECT COALESCE(SUM(rd.refundamount),0)
     FROM kch20262027.fee_refunddetails rd
     JOIN kch20262027.fee_refund r ON r.rf_id = rd.rf_id
    WHERE r.stuadmno = '262790' AND r.activestatus = 1) AS refunded,
  (SELECT COALESCE(SUM(feeamount - COALESCE(conamount,0)),0)
     FROM kch20262027.feedemand
    WHERE stuadmno = '262790' AND activestatus = 1) AS net_fee;
