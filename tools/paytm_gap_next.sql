-- ============================================================================
-- Next checks on the Rs 6,450 gap. Run ONE AT A TIME -- the Supabase editor
-- shows only the last result set.
--
-- Rs 2,700 of it is already identified (the unresolved refusal). This is for
-- the remaining Rs 3,750, which the webhook never logged -- meaning its
-- callback never arrived, so nothing noticed at all.
--
-- Dates are inline literals, marked <<<< DATES. Set the Paytm dashboard to a
-- CUSTOM range with the same two dates before comparing anything.
-- ============================================================================


-- ===================================================== A. THE FULL ORDER ID =
-- The refusal's order_id was cut off on screen. Paste the full value back and
-- Paytm's status API will confirm the capture and give the txn id.
-- ===========================================================================

SELECT order_id, amount, first_seen
  FROM public.webhook_refusal
 WHERE resolved_at IS NULL;


-- ====================================== B. ARE BOTH SIDES THE SAME PERIOD? =
-- Run this FIRST of the comparison queries. If this total does not match the
-- Paytm dashboard for the identical custom range, the gap is partly a date
-- mismatch and chasing individual payments is premature.
-- ===========================================================================

SELECT count(*)                  AS receipts,
       sum(transtotalamount)     AS amount
  FROM kcet20262027.payment
 WHERE activestatus = 1
   AND paystatus = 'C'
   AND paydate::date BETWEEN DATE '2026-10-06' AND DATE '2026-10-12'   -- <<<< DATES
   AND LOWER(btrim(COALESCE(paymethod, ''))) IN
       ('online transfer', 'online', 'upi', 'imps', 'neft', 'rtgs',
        'neft/rtgs', 'paytm', 'card');


-- ================================ C. THE LIST, TO DIFF AGAINST THE DOWNLOAD =
-- Download the Paytm report for the same dates, then match on paytm_ref.
--
-- A Paytm row whose ORDER ID or TRANSACTION ID appears NOWHERE in this list
-- is a capture with no receipt -- the thing being hunted.
-- ===========================================================================

SELECT p.paydate::date      AS day,
       p.paynumber          AS receipt,
       p.transtotalamount   AS amount,
       COALESCE(NULLIF(btrim(p.payorderid), ''), '-')    AS order_id,
       COALESCE(NULLIF(btrim(p.payreference), ''), '-')  AS paytm_ref,
       s.stuadmno, s.stuname
  FROM kcet20262027.payment p
  LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
 WHERE p.activestatus = 1
   AND p.paystatus = 'C'
   AND p.paydate::date BETWEEN DATE '2026-10-06' AND DATE '2026-10-12'   -- <<<< DATES
   AND LOWER(btrim(COALESCE(p.paymethod, ''))) IN
       ('online transfer', 'online', 'upi', 'imps', 'neft', 'rtgs',
        'neft/rtgs', 'paytm', 'card')
 ORDER BY p.paydate, p.paynumber;


-- ===================================== D. TODAY ONLY, THE LIKELIEST WINDOW =
-- The Rs 2,700 refusal is dated today, so the rest of the gap probably is
-- too. Every online receipt today, next to every attempt that died today --
-- a capture Paytm shows but live does not will line up with one of these by
-- student and amount.
-- ===========================================================================

SELECT 'RECEIPT'                AS kind,
       p.paynumber              AS ref,
       p.transtotalamount       AS amount,
       to_char(p.paydate, 'HH24:MI') AS at,
       COALESCE(NULLIF(btrim(p.payorderid), ''), '-') AS order_id,
       s.stuadmno, s.stuname
  FROM kcet20262027.payment p
  LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
 WHERE p.activestatus = 1 AND p.paystatus = 'C'
   AND p.paydate::date = DATE '2026-10-12'                              -- <<<< DATES
   AND LOWER(btrim(COALESCE(p.paymethod, ''))) IN
       ('online transfer', 'online', 'upi', 'imps', 'neft', 'rtgs',
        'neft/rtgs', 'paytm', 'card')

UNION ALL

SELECT 'DIED (' || p.paystatus || ')',
       COALESCE(NULLIF(btrim(p.payorderid), ''), '(no order id)'),
       p.transtotalamount,
       to_char(p.createdat, 'HH24:MI'),
       '-',
       s.stuadmno, s.stuname
  FROM kcet20262027.payment p
  LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
 WHERE p.activestatus = 1 AND p.paystatus IN ('I', 'F')
   AND p.createdat::date = DATE '2026-10-12'                            -- <<<< DATES

UNION ALL

SELECT 'CART, no payment',
       c.car_id::text,
       c.transtotalamount,
       to_char(c.createdon, 'HH24:MI'),
       '-',
       s.stuadmno, s.stuname
  FROM kcet20262027.shoppingcart c
  LEFT JOIN kcet20262027.students s ON s.stu_id = c.stu_id
 WHERE c.activestatus = 1
   AND c.createdon::date = DATE '2026-10-12'                            -- <<<< DATES
   AND NOT EXISTS (
         SELECT 1 FROM kcet20262027.payment p
          WHERE p.stu_id = c.stu_id
            AND p.transtotalamount = c.transtotalamount
            AND p.createdat BETWEEN c.createdon - interval '10 minutes'
                                AND c.createdon + interval '60 minutes')

 ORDER BY 4;
