-- =====================================================================
-- WHAT HAS THE WEBHOOK ACTUALLY RECOVERED? -- read only.
--
-- A receipt is "recovered" when the SERVER raised it because the client
-- never came back -- app closed, signal lost, dialog resolved with no
-- verdict. Two different trails, because fee and misc/advance recover by
-- different routes:
--
--   FEE      payment.payreference is stamped 'PAYTM-WH:<txn>' by
--            webhook_complete_payment. The apps write the bare Paytm txn
--            id, so the prefix is the only thing that tells them apart.
--
--   MISC /   public.pending_collection records the intent BEFORE Paytm is
--   ADVANCE  contacted; whoever completes it claims it first. Three can
--            claim -- COUNTER, SWEEP (admin app) and WEBHOOK -- so
--            claimed_by says which one actually saved it.
--
-- The summary rows ALWAYS print, including as zeros. "No rows returned"
-- cannot tell "nothing was recovered" from "the query is wrong".
--
-- Zero recovered is the GOOD result: it means every payment completed in
-- the client the way it should. The row that matters is the last one --
-- an unresolved refusal is money Paytm took with no receipt against it.
-- =====================================================================

WITH fee AS (
  SELECT p.paynumber AS receipt, p.paydate AS at,
         p.transtotalamount AS amount, p.payreference AS detail
    FROM kcet20262027.payment p
   WHERE p.activestatus = 1 AND p.paystatus = 'C'
     AND p.payreference LIKE 'PAYTM-WH:%'
),
coll AS (
  SELECT c.receipt_no AS receipt, c.settled_at AS at, c.amount,
         c.order_id AS detail,
         CASE c.kind WHEN 'M' THEN 'Misc' ELSE 'Advance' END AS kind
    FROM public.pending_collection c
   WHERE c.status = 'C' AND c.claimed_by = 'WEBHOOK'
),
refusal AS (
  SELECT r.order_id, r.reason, r.amount, r.last_seen
    FROM public.webhook_refusal r
   WHERE r.resolved_at IS NULL
)

SELECT * FROM (
  -- ---- summary: always printed, even at zero -------------------------
  SELECT 1 AS sort, 'SUMMARY' AS kind,
         'fee receipts raised by the webhook' AS receipt,
         NULL::timestamp AS at,
         COALESCE(sum(amount), 0) AS amount,
         count(*)::text || ' receipt(s)' AS detail
    FROM fee
  UNION ALL
  SELECT 2, 'SUMMARY', 'misc/advance receipts raised by the webhook',
         NULL, COALESCE(sum(amount), 0), count(*)::text || ' receipt(s)'
    FROM coll
  UNION ALL
  -- Not recovered at all: Paytm confirmed, the database would not receipt.
  SELECT 3, 'SUMMARY', 'UNRESOLVED REFUSALS - money with no receipt',
         NULL, COALESCE(sum(amount), 0), count(*)::text || ' order(s)'
    FROM refusal
  UNION ALL
  -- For contrast: who claimed each misc/advance collection overall.
  SELECT 4, 'SUMMARY', 'claims by ' || COALESCE(claimed_by, '(unclaimed)'),
         NULL, COALESCE(sum(amount), 0), count(*)::text || ' collection(s)'
    FROM public.pending_collection
   GROUP BY claimed_by

  -- ---- detail --------------------------------------------------------
  UNION ALL
  SELECT 5, 'Fee', receipt, at, amount, detail            FROM fee
  UNION ALL
  SELECT 6, kind,  receipt, at, amount, detail            FROM coll
  UNION ALL
  SELECT 7, 'REFUSAL', order_id, last_seen, amount, reason FROM refusal
) x
ORDER BY sort, at DESC NULLS LAST, receipt;
