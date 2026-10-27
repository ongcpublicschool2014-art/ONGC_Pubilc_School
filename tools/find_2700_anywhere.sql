-- ============================================================================
-- Rs 2,700, order 202610121538040032, captured 12-10-2026 15:38.
-- No cart, no obvious payment row. Search EVERY table that records money.
-- ============================================================================
-- Why this is odd: every order id this system generates follows a known
-- shape -- PAY-<pay_id> for fees, MISC<ins>T<millis> for misc,
-- ADV<ins>T<millis> for advances. 202610121538040032 is none of them, so it
-- was supplied by a client that makes its own, and the usual breadcrumbs
-- (cart, payment row) may not exist.
--
-- Run ONE AT A TIME. The first one that returns a row identifies the payer.
-- ============================================================================


-- ===================================== 1. THE INTENT TABLE (misc / advance) =
-- record_pending_collection writes here BEFORE the gateway is called, for
-- misc and advance collections. If this payment was either, the row is here
-- with its full header and lines -- which name the student and the fees.
-- ===========================================================================

SELECT order_id, ins_id, kind, amount, status, created_by, created_at,
       claimed_by, receipt_no, settled_at,
       header, lines
  FROM public.pending_collection
 WHERE order_id = '202610121538040032'
    OR amount = 2700.00
   AND created_at::date = DATE '2026-10-12';


-- ============================================= 2. ANYTHING AT ALL AT 15:38 =
-- Every money row created in a 40-minute window today, across all three
-- tables, whatever its status. The payer is in here somewhere unless nothing
-- was written at all.
-- ===========================================================================

SELECT 'payment' AS src, p.pay_id::text AS id,
       COALESCE(p.paynumber, '-') AS receipt, p.transtotalamount AS amount,
       p.paystatus AS status, p.createdat AS at,
       COALESCE(NULLIF(btrim(p.payorderid), ''), '-') AS order_id,
       COALESCE(s.stuadmno, '?') AS roll, COALESCE(s.stuname, '?') AS who
  FROM kcet20262027.payment p
  LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
 WHERE p.createdat BETWEEN TIMESTAMP '2026-10-12 15:20' AND TIMESTAMP '2026-10-12 16:00'
UNION ALL
SELECT 'misc', m.mc_id::text, COALESCE(m.mcno, '-'), m.totalamount,
       m.paystatus, m.createdat::timestamp,
       COALESCE(NULLIF(btrim(m.paytm_txnid), ''), '-'),
       COALESCE(m.regno, '-'), COALESCE(m.stuname, '?')
  FROM kcet20262027.misc_collection m
 WHERE m.createdat BETWEEN TIMESTAMP '2026-10-12 15:20' AND TIMESTAMP '2026-10-12 16:00'
UNION ALL
SELECT 'advance', a.adv_id::text, COALESCE(a.advno, '-'), a.transtotalamount,
       a.paystatus, a.createdat,
       COALESCE(NULLIF(btrim(a.paytm_txnid), ''), '-'),
       COALESCE(a.stuadmno, '-'), COALESCE(a.stuname, '?')
  FROM kcet20262027.advance_collection a
 WHERE a.createdat BETWEEN TIMESTAMP '2026-10-12 15:20' AND TIMESTAMP '2026-10-12 16:00'
 ORDER BY 6;


-- =================================== 3. THE ORDER OR TXN ID, ANYWHERE AT ALL =
-- A free text hunt across every column that could hold either identifier.
-- ===========================================================================

SELECT 'payment' AS src, pay_id::text AS id, transtotalamount AS amount,
       paystatus, COALESCE(payorderid, '-') AS order_id,
       COALESCE(payreference, '-') AS reference
  FROM kcet20262027.payment
 WHERE COALESCE(payorderid, '') LIKE '%202610121538040032%'
    OR COALESCE(payreference, '') LIKE '%202610121538040032%'
    OR COALESCE(payreference, '') LIKE '%316428802083332288%'
UNION ALL
SELECT 'misc', mc_id::text, totalamount, paystatus,
       COALESCE(transrefno, '-'), COALESCE(paytm_txnid, '-')
  FROM kcet20262027.misc_collection
 WHERE COALESCE(transrefno, '') LIKE '%202610121538040032%'
    OR COALESCE(paytm_txnid, '') LIKE '%202610121538040032%'
    OR COALESCE(transrefno, '') LIKE '%316428802083332288%'
    OR COALESCE(paytm_txnid, '') LIKE '%316428802083332288%'
UNION ALL
SELECT 'advance', adv_id::text, transtotalamount, paystatus,
       COALESCE(payorderid, '-'), COALESCE(paytm_txnid, '-')
  FROM kcet20262027.advance_collection
 WHERE COALESCE(payorderid, '') LIKE '%202610121538040032%'
    OR COALESCE(paytm_txnid, '') LIKE '%202610121538040032%'
    OR COALESCE(paytm_txnid, '') LIKE '%316428802083332288%'
UNION ALL
SELECT 'pending_collection', order_id, amount, status,
       COALESCE(receipt_no, '-'), COALESCE(created_by, '-')
  FROM public.pending_collection
 WHERE order_id LIKE '%202610121538040032%';


-- ========================================== 4. EVERY CART TODAY, NOT JUST 15:38 =
-- Widen the net: the basket may have been built well before the payment, or
-- the clock may differ. Any cart today whose total is Rs 2,700.
-- ===========================================================================

SELECT c.car_id, s.stuadmno, s.stuname, c.transtotalamount, c.createdon,
       c.carinitiated, c.activestatus
  FROM kcet20262027.shoppingcart c
  LEFT JOIN kcet20262027.students s ON s.stu_id = c.stu_id
 WHERE c.createdon::date = DATE '2026-10-12'
 ORDER BY c.createdon;
