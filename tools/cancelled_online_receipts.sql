-- ============================================================================
-- Online receipts CANCELLED in the window.
-- ============================================================================
-- Why this closes the gap arithmetic: Paytm counts the CAPTURE and keeps
-- counting it forever. Live counts the RECEIPT, and a cancelled receipt stops
-- counting. So every cancelled online receipt widens the Paytm-minus-live gap
-- by exactly its amount, without a rupee going missing.
--
-- Rs 6,450 outstanding, of which Rs 2,700 is the confirmed refusal. If a
-- cancellation of Rs 3,750 shows up here, the gap is fully explained and
-- nothing further is lost.
--
-- Dates inline, marked <<<< DATES. Run on LIVE -- a cancellation made this
-- afternoon is not in the morning's TEST restore.
-- ============================================================================

SELECT p.pay_id,
       p.paynumber,
       p.transtotalamount                                  AS amount,
       p.paydate::date                                     AS receipt_date,
       p.paymethod,
       p.paystatus,
       p.activestatus,
       COALESCE(NULLIF(btrim(p.payorderid), ''), '-')      AS order_id,
       COALESCE(NULLIF(btrim(p.payreference), ''), '-')    AS paytm_ref,
       p.voidedby,
       p.voideddate,
       COALESCE(p.voidreason, '-')                         AS reason,
       s.stuadmno, s.stuname
  FROM kcet20262027.payment p
  LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
 WHERE (p.paystatus = 'R' OR p.activestatus <> 1 OR p.voidedby IS NOT NULL)
   AND p.paydate::date BETWEEN DATE '2026-10-06' AND DATE '2026-10-12'  -- <<<< DATES
   AND LOWER(btrim(COALESCE(p.paymethod, ''))) IN
       ('online transfer', 'online', 'upi', 'imps', 'neft', 'rtgs',
        'neft/rtgs', 'paytm', 'card')
 ORDER BY p.paydate, p.pay_id;


-- ---------------------------------------------------------------------------
-- And the same for MISC, which draws from the same Paytm merchant and would
-- widen the gap the same way.
-- ---------------------------------------------------------------------------

SELECT m.mc_id, m.mcno, m.totalamount AS amount, m.mcdate AS receipt_date,
       m.paymode, m.paystatus, m.activestatus,
       m.voidedby, m.voideddate, COALESCE(m.voidreason, '-') AS reason,
       m.stuname
  FROM kcet20262027.misc_collection m
 WHERE (m.paystatus = 'R' OR m.activestatus <> 1 OR m.voidedby IS NOT NULL)
   AND m.mcdate BETWEEN DATE '2026-10-06' AND DATE '2026-10-12'          -- <<<< DATES
   AND LOWER(btrim(COALESCE(m.paymode, ''))) IN
       ('online transfer', 'online', 'upi', 'imps', 'neft', 'rtgs',
        'neft/rtgs', 'paytm', 'card')
 ORDER BY m.mcdate, m.mc_id;
