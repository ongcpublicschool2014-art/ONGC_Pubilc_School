-- ============================================================================
-- Find the Paytm captures that live has no receipt for.
-- ============================================================================
-- Paytm "This week" Success: 36 txns, Rs 1,80,650.
-- Live online transfer:              Rs 1,74,200.
-- Short by Rs 6,450 -- one or more captured payments with no receipt.
--
-- Run 1 FIRST. It is the fastest answer and needs nothing from Paytm.
-- Run 2 and 3 only if 1 comes back empty or does not account for the gap.
--
-- SET BOTH SIDES TO THE SAME DATES before trusting any difference. Paytm's
-- "This week" boundary is not necessarily yours -- use a custom range on the
-- dashboard matching the one used here.
--
-- THE DATES ARE WRITTEN INLINE, once per query, marked <<<< DATES. There are
-- no \set variables: those are psql meta-commands and the Supabase SQL editor
-- runs SQL only -- it answers them with `syntax error at or near ":"`.
--
-- Run one query at a time: the editor shows only the last result set.
-- ============================================================================


-- ========================================================= 1. THE REFUSALS =
-- The webhook re-asks Paytm on every callback. A capture it cannot match to
-- a payment row is logged here automatically -- this is what caught KANNAN
-- D's Rs 5,125. Anything unresolved is money with no receipt.
--
-- No dates: an unresolved refusal matters whenever it happened.
-- ===========================================================================

SELECT order_id, amount, times_seen,
       first_seen::date AS first_seen, reason
  FROM public.webhook_refusal
 WHERE resolved_at IS NULL
 ORDER BY first_seen DESC;


-- ============================ 2. WHAT LIVE THINKS IT TOOK, WITH REFERENCES =
-- Every online receipt in the window, with whatever Paytm identifier it
-- carries. Download the Paytm report for the same dates and diff the two
-- lists on ORDER ID / TRANSACTION ID.
--
-- paytm_ref is the thing to match on: for a desktop payment it is the order
-- id, for a webhook-completed one the txn id, and for a mobile payment often
-- NEITHER -- which is the bug being fixed.
-- ===========================================================================

SELECT p.paydate::date      AS day,
       p.paynumber          AS receipt,
       p.transtotalamount   AS amount,
       p.paymethod          AS mode,
       COALESCE(NULLIF(btrim(p.payorderid), ''), '(no order id)')    AS order_id,
       COALESCE(NULLIF(btrim(p.payreference), ''), '(no reference)') AS paytm_ref,
       s.stuadmno, s.stuname
  FROM kcet20262027.payment p
  LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
 WHERE p.activestatus = 1
   AND p.paystatus = 'C'
   AND p.paydate::date BETWEEN DATE '2026-10-06' AND DATE '2026-10-12'  -- <<<< DATES
   AND LOWER(btrim(COALESCE(p.paymethod, ''))) IN
       ('online transfer', 'online', 'upi', 'imps', 'neft', 'rtgs',
        'neft/rtgs', 'paytm', 'card')
 ORDER BY p.paydate, p.paynumber;


-- ================================= 3. ATTEMPTS THAT DIED WITHOUT A RECEIPT =
-- Rows that reached the gateway but never became a receipt, plus mobile
-- baskets with no payment at all. A capture Paytm shows but live does not
-- will usually line up with one of these -- same student, same amount.
-- ===========================================================================

SELECT 'failed/pending attempt' AS kind,
       p.pay_id::text           AS id,
       p.transtotalamount       AS amount,
       p.paystatus              AS status,
       COALESCE(NULLIF(btrim(p.payorderid), ''), '(no order id)') AS order_id,
       p.createdat,
       s.stuadmno, s.stuname
  FROM kcet20262027.payment p
  LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
 WHERE p.activestatus = 1
   AND p.paystatus IN ('I', 'F')
   AND p.createdat::date BETWEEN DATE '2026-10-06' AND DATE '2026-10-12'  -- <<<< DATES

UNION ALL

-- A basket with no payment row is the signature of the delete bug: the cart
-- survives, the payment row does not.
SELECT 'cart with no payment',
       c.car_id::text,
       c.transtotalamount,
       '-',
       '-',
       c.createdon,
       s.stuadmno, s.stuname
  FROM kcet20262027.shoppingcart c
  LEFT JOIN kcet20262027.students s ON s.stu_id = c.stu_id
 WHERE c.activestatus = 1
   AND c.createdon::date BETWEEN DATE '2026-10-06' AND DATE '2026-10-12'  -- <<<< DATES
   AND NOT EXISTS (
         SELECT 1 FROM kcet20262027.payment p
          WHERE p.stu_id = c.stu_id
            AND p.transtotalamount = c.transtotalamount
            AND p.createdat BETWEEN c.createdon - interval '10 minutes'
                                AND c.createdon + interval '60 minutes')

 ORDER BY 6;
