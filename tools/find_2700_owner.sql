-- ============================================================================
-- Whose Rs 2,700 is it? (order 202610121538040032, 12-10-2026 15:38)
-- ============================================================================
-- Paytm: TXN_SUCCESS, resultCode 01, txn 20261012011060000316428802083332288.
-- Live has no receipt. The order id is timestamp-based rather than
-- PAY-<pay_id>, so the payment row cannot be identified from it -- these
-- queries find the student by time and amount instead.
--
-- Run them in order. The first one that returns a row identifies the payer.
-- Run ONE AT A TIME -- the editor shows only the last result set.
-- ============================================================================


-- =========================================== 1. ALREADY RECORDED SOMEWHERE? =
-- Check before anything else: if a receipt already carries this order or txn,
-- the money is not lost and the refusal is a false alarm, like PAY-3767 was.
-- ===========================================================================

SELECT 'payment' AS tbl, pay_id::text AS id, paynumber AS receipt,
       transtotalamount AS amount, paystatus, paydate, payorderid, payreference
  FROM kcet20262027.payment
 WHERE payorderid = '202610121538040032'
    OR payreference LIKE '%316428802083332288%'
UNION ALL
SELECT 'misc', mc_id::text, mcno, totalamount, paystatus, mcdate::timestamp,
       '-', COALESCE(transrefno, paytm_txnid, '-')
  FROM kcet20262027.misc_collection
 WHERE transrefno LIKE '%316428802083332288%'
    OR paytm_txnid LIKE '%316428802083332288%';


-- ================================================= 2. THE BASKET, BY TIME =
-- The mobile cart is written seconds before the gateway is called. KANNAN D's
-- was 7 seconds before the capture. Anything here around 15:38 for Rs 2,700
-- is almost certainly the payer, and its detail rows name the exact demands.
-- ===========================================================================

SELECT c.car_id, c.stu_id, s.stuadmno, s.stuname,
       c.transtotalamount AS cart_total, c.createdon, c.carinitiated,
       d.dem_id, fd.demno, fd.demfeetype, d.transtotalamount AS line_amount,
       fd.balancedue
  FROM kcet20262027.shoppingcart c
  LEFT JOIN kcet20262027.shoppingcartdetails d ON d.car_id = c.car_id
  LEFT JOIN kcet20262027.feedemand fd ON fd.dem_id = d.dem_id
  LEFT JOIN kcet20262027.students s ON s.stu_id = c.stu_id
 WHERE c.createdon BETWEEN TIMESTAMP '2026-10-12 15:20'
                       AND TIMESTAMP '2026-10-12 16:00'
 ORDER BY c.createdon, d.cd_id;


-- =========================================== 3. ANY ATTEMPT AT THAT MOMENT =
-- A payment row of any status near 15:38. If the row survived (status I or F)
-- its paymentdetails already name the allocation and recovery is trivial.
-- ===========================================================================

SELECT p.pay_id, p.paystatus, p.transtotalamount AS amount, p.createdat,
       COALESCE(NULLIF(btrim(p.payorderid), ''), '(none)') AS order_id,
       COALESCE(NULLIF(btrim(p.payreference), ''), '-')    AS reference,
       (SELECT count(*) FROM kcet20262027.paymentdetails d WHERE d.pay_id = p.pay_id)
         AS detail_rows,
       s.stuadmno, s.stuname
  FROM kcet20262027.payment p
  LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
 WHERE p.createdat BETWEEN TIMESTAMP '2026-10-12 15:20'
                       AND TIMESTAMP '2026-10-12 16:10'
 ORDER BY p.createdat;


-- ================================== 4. FALLBACK: WHO OWES EXACTLY Rs 2,700 =
-- Only if 1-3 draw a blank. This is weaker evidence -- many students can owe
-- the same amount -- so it narrows the field rather than naming the payer.
-- Do not recover on this alone without matching it to something else.
-- ===========================================================================

SELECT fd.dem_id, fd.demno, fd.demfeetype, fd.feeamount, fd.paidamount,
       fd.balancedue, s.stuadmno, s.stuname, s.stuclass
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id
 WHERE fd.activestatus = 1
   AND fd.balancedue = 2700.00
 ORDER BY s.stuadmno;
