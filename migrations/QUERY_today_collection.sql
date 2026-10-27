-- ============================================================================
-- TODAY'S COLLECTION -- read-only. Nothing here writes.
--
-- Change the schema name on the next line if you are not on KCET.
-- (Live: kcet20262027. Replace every kcet20262027 below -- the SQL editor's
--  Find & Replace does it in one pass.)
--
-- WHAT COUNTS AS TODAY'S COLLECTION
--   fee receipts   payment            paydate::date = CURRENT_DATE
--   misc receipts  misc_collection    mcdate        = CURRENT_DATE
--   advances       advance_collection advdate::date = CURRENT_DATE
--
-- EXCLUDED, deliberately:
--   * voided receipts (activestatus = 9)
--   * paymethod = 'Advance Adjustment' -- an adjustment settles a demand with
--     money that was ALREADY taken as an advance on some earlier day. Counting
--     it as today's collection would count the same rupee twice.
--
-- Section 5 needs the Advance Collection migration to have run. If
-- advance_collection does not exist yet, skip sections 4 and 5; sections 1-3
-- work today.
-- ============================================================================


-- ============================================================================
-- 1. HEADLINE -- one row. What came in today, and how much is still unbanked.
-- ============================================================================
SELECT
  COALESCE(SUM(amount)                                      , 0) AS total_today,
  COALESCE(SUM(amount) FILTER (WHERE source = 'FEE')        , 0) AS fee,
  COALESCE(SUM(amount) FILTER (WHERE source = 'MISC')       , 0) AS misc,
  COALESCE(SUM(amount) FILTER (WHERE recon = 'R')           , 0) AS reconciled,
  COALESCE(SUM(amount) FILTER (WHERE recon <> 'R')          , 0) AS unreconciled,
  COUNT(*)                                                       AS receipts
FROM (
  SELECT 'FEE'::text AS source, p.transtotalamount AS amount,
         COALESCE(p.recon_status, 'P') AS recon
    FROM kcet20262027.payment p
   WHERE p.paydate::date = CURRENT_DATE
     AND p.paystatus = 'C'
     AND COALESCE(p.activestatus, 1) <> 9
     AND COALESCE(p.paymethod, '') <> 'Advance Adjustment'
  UNION ALL
  SELECT 'MISC', m.totalamount, COALESCE(m.recon_status, 'P')
    FROM kcet20262027.misc_collection m
   WHERE m.mcdate = CURRENT_DATE
     AND COALESCE(m.paystatus, 'C') = 'C'
     AND COALESCE(m.activestatus, 1) = 1
) t;


-- ============================================================================
-- 2. BY MODE -- what is in the drawer vs what went to the bank.
--
-- The mode is normalised because three screens wrote three vocabularies over
-- time ('Cash' / 'cash' / 'CASH', 'upi' / 'QR/UPI', 'Online Transfer' /
-- 'Paytm'). Grouping on the raw column splits one mode across several rows,
-- which is what made the earlier by-mode figures look wrong.
-- ============================================================================
SELECT
  mode,
  COUNT(*)                                             AS receipts,
  SUM(amount)                                          AS amount,
  SUM(amount) FILTER (WHERE recon = 'R')               AS reconciled,
  SUM(amount) FILTER (WHERE recon <> 'R')              AS unreconciled
FROM (
  SELECT
    CASE
      WHEN UPPER(COALESCE(x.method, '')) LIKE '%CASH%'                        THEN 'CASH'
      WHEN UPPER(COALESCE(x.method, '')) LIKE '%UPI%'
        OR UPPER(COALESCE(x.method, '')) LIKE '%QR%'                          THEN 'UPI'
      WHEN UPPER(COALESCE(x.method, '')) LIKE '%CHEQUE%'                      THEN 'CHEQUE'
      WHEN UPPER(COALESCE(x.method, '')) = 'DD'
        OR UPPER(COALESCE(x.method, '')) LIKE '%DEMAND DRAFT%'                THEN 'DD'
      WHEN UPPER(COALESCE(x.method, '')) LIKE '%PAYTM%'
        OR UPPER(COALESCE(x.method, '')) LIKE '%ONLINE%'
        OR UPPER(COALESCE(x.method, '')) LIKE '%NEFT%'
        OR UPPER(COALESCE(x.method, '')) LIKE '%RTGS%'
        OR UPPER(COALESCE(x.method, '')) LIKE '%CARD%'                        THEN 'ONLINE'
      WHEN COALESCE(x.method, '') = ''                                        THEN '(not set)'
      ELSE UPPER(x.method)
    END AS mode,
    x.amount, x.recon
  FROM (
    SELECT p.paymethod AS method, p.transtotalamount AS amount,
           COALESCE(p.recon_status, 'P') AS recon
      FROM kcet20262027.payment p
     WHERE p.paydate::date = CURRENT_DATE
       AND p.paystatus = 'C'
       AND COALESCE(p.activestatus, 1) <> 9
       AND COALESCE(p.paymethod, '') <> 'Advance Adjustment'
    UNION ALL
    SELECT m.paymode, m.totalamount, COALESCE(m.recon_status, 'P')
      FROM kcet20262027.misc_collection m
     WHERE m.mcdate = CURRENT_DATE
       AND COALESCE(m.paystatus, 'C') = 'C'
       AND COALESCE(m.activestatus, 1) = 1
  ) x
) y
GROUP BY mode
ORDER BY amount DESC;


-- ============================================================================
-- 3. RECEIPT BY RECEIPT -- the counter's own list, in receipt-book order.
-- ============================================================================
SELECT
  src                                                        AS type,
  receiptno,
  regno,
  stuname,
  stuclass,
  amount,
  paymode,
  CASE WHEN recon = 'R' THEN 'CLEARED' ELSE 'PENDING' END    AS status,
  collectedby,
  paid_at
FROM (
  SELECT 'FEE'::text AS src, p.paynumber AS receiptno,
         s.stuadmno AS regno, s.stuname, s.stuclass,
         p.transtotalamount AS amount, p.paymethod AS paymode,
         COALESCE(p.recon_status, 'P') AS recon,
         p.createdby AS collectedby, p.paydate AS paid_at
    FROM kcet20262027.payment p
    LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
   WHERE p.paydate::date = CURRENT_DATE
     AND p.paystatus = 'C'
     AND COALESCE(p.activestatus, 1) <> 9
     AND COALESCE(p.paymethod, '') <> 'Advance Adjustment'
  UNION ALL
  SELECT 'MISC', m.mcno, m.regno, m.stuname, m.stuclass,
         m.totalamount, m.paymode, COALESCE(m.recon_status, 'P'),
         m.collectedby, m.mcdate::timestamp
    FROM kcet20262027.misc_collection m
   WHERE m.mcdate = CURRENT_DATE
     AND COALESCE(m.paystatus, 'C') = 'C'
     AND COALESCE(m.activestatus, 1) = 1
) r
-- Receipt-book order: the trailing digits compared as a NUMBER, so FC26/02699
-- precedes FC26/02700 instead of sorting after it as text would.
ORDER BY COALESCE(NULLIF(regexp_replace(receiptno, '^.*?(\d+)\s*$', '\1'), ''), '0')::bigint;


-- ============================================================================
-- 4. ADVANCES TAKEN TODAY  (needs the Advance Collection migration)
--
-- Kept in its own section on purpose: an advance is money in the drawer, but it
-- is NOT a fee collection -- no demand was settled. Read it alongside section 1,
-- not added into it, unless your cash-up counts every rupee that crossed the
-- counter.
-- ============================================================================
SELECT
  a.advno                                                     AS receiptno,
  CASE a.advtype WHEN 'A' THEN 'ADMISSION' ELSE 'STUDENT' END AS advance_type,
  a.stuadmno                                                  AS regno,
  a.stuname,
  a.stuclass,
  a.transtotalamount                                          AS amount,
  a.adjustedamount,
  a.balanceamount                                             AS unused,
  a.paymethod                                                 AS paymode,
  CASE WHEN COALESCE(a.recon_status, 'P') = 'R' THEN 'CLEARED' ELSE 'PENDING' END AS status,
  a.createdby                                                 AS collectedby,
  a.advdate
FROM kcet20262027.advance_collection a
WHERE a.advdate::date = CURRENT_DATE
  AND COALESCE(a.paystatus, 'C') = 'C'
  AND COALESCE(a.activestatus, 1) = 1
ORDER BY a.adv_id;

-- 4b. Fee-type breakdown of today's ADMISSION advances (advtype 'A' only).
SELECT a.advno, a.stuadmno AS regno, a.stuname,
       d.feetype, d.amount
  FROM kcet20262027.advance_collection a
  JOIN kcet20262027.advance_detail d ON d.adv_id = a.adv_id
 WHERE a.advdate::date = CURRENT_DATE
   AND COALESCE(a.activestatus, 1) = 1
   AND COALESCE(d.activestatus, 1) = 1
 ORDER BY a.adv_id, d.advd_id;


-- ============================================================================
-- 5. ADVANCE ADJUSTED TODAY  (needs the Advance Collection migration)
--
-- Demands settled today out of an advance taken earlier. NO money crossed the
-- counter today -- this is here so the demands that moved are accounted for,
-- and so you can see why a student's balance dropped with no cash to match.
-- ============================================================================
SELECT
  j.paynumber      AS fee_receipt,
  v.advno          AS from_advance,
  v.stuadmno       AS regno,
  v.stuname,
  j.demfeeterm     AS semester,
  j.demfeetype     AS feetype,
  j.adjustamount   AS amount,
  j.createdby,
  j.createdat
FROM kcet20262027.advadjustment j
JOIN kcet20262027.advance_collection v ON v.adv_id = j.adv_id
WHERE j.adjustdate = CURRENT_DATE
  AND COALESCE(j.activestatus, 1) = 1
ORDER BY j.adj_id;
