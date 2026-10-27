-- ============================================================================
-- Fold historic misc_collection.paymode onto the payment.paymethod vocabulary
--
-- Misc Collection used to store the dropdown value verbatim ('Cash', 'QR/UPI',
-- 'Paytm'), while Fee Collection rewrites the mode before storing it ('cash',
-- 'upi', 'Online Transfer'). One receipt series with two vocabularies made
-- Pending Approval and Transactions read as if they came from two systems.
--
-- The app now writes the payment spelling for NEW misc receipts; this brings
-- the existing ones into line.
--
--   Cash    -> cash          Cheque -> cheque      DD -> dd
--   QR/UPI  -> upi           UPI    -> upi
--   Paytm   -> Online Transfer      (what Fee Collection stores for a Paytm
--                                    gateway payment)
--
-- NO MONEY FIGURE MOVES. Everything that groups by mode normalises case first
-- (_paymentBucket uppercases before testing CASH; the dashboard pie lowercases
-- and matches substrings), so the Cash/Bank split and the collection-by-mode
-- chart are identical before and after. Only the displayed string changes.
--
-- Reconciliation is untouched: recon_status was decided at insert and is not
-- re-derived here, and both save_misc_collection and void_misc_receipt test
-- LOWER(paymode) LIKE '%cash%', which matches 'cash' exactly as it matched
-- 'Cash'.
--
-- SAFE TO RE-RUN: only the old spellings are matched, so a second run updates
-- nothing.
-- ============================================================================

-- ── Before ──────────────────────────────────────────────────────────────────
SELECT 'BEFORE' AS stage, coalesce(paymode, '(null)') AS mode, count(*) AS rows
  FROM kcet20262027.misc_collection
 WHERE activestatus = 1
 GROUP BY 2 ORDER BY 3 DESC;

-- ── Update every institution schema ─────────────────────────────────────────
DO $fix$
DECLARE r record; n integer; total integer := 0;
BEGIN
  FOR r IN
    SELECT nspname FROM pg_namespace nsp
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = nsp.oid AND c.relname = 'misc_collection')
       AND left(nspname,3) <> 'pg_'
       AND nspname NOT IN ('public','information_schema','auth','storage',
                           'realtime','vault','extensions','graphql','graphql_public')
  LOOP
    -- Case-sensitive matches on the exact old spellings. A row already holding
    -- 'cash'/'upi' is left alone, which is what makes this re-runnable.
    EXECUTE format($u$
      UPDATE %I.misc_collection
         SET paymode = CASE paymode
                         WHEN 'Cash'   THEN 'cash'
                         WHEN 'Cheque' THEN 'cheque'
                         WHEN 'DD'     THEN 'dd'
                         WHEN 'QR/UPI' THEN 'upi'
                         WHEN 'UPI'    THEN 'upi'
                         WHEN 'Paytm'  THEN 'Online Transfer'
                       END
       WHERE paymode IN ('Cash','Cheque','DD','QR/UPI','UPI','Paytm')
    $u$, r.nspname);
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
    RAISE NOTICE '%: % row(s) renamed', r.nspname, n;
  END LOOP;
  RAISE NOTICE 'total rows renamed: %', total;
END
$fix$;

-- ── After: expect only cash / cheque / dd / upi / Online Transfer ───────────
SELECT 'AFTER' AS stage, coalesce(paymode, '(null)') AS mode, count(*) AS rows,
       count(*) FILTER (WHERE recon_status = 'P') AS still_pending
  FROM kcet20262027.misc_collection
 WHERE activestatus = 1
 GROUP BY 2 ORDER BY 3 DESC;

-- ── Cross-check: the two tables should now share one vocabulary ────────────
-- payment's capitalised values ('Cash', 'UPI', 'DD', ...) are IMPORTED history
-- from before go-live and are deliberately left as they are -- this file is
-- about misc only.
SELECT 'payment' AS tbl, coalesce(paymethod,'(null)') AS mode, count(*)
  FROM kcet20262027.payment WHERE activestatus = 1 GROUP BY 2
UNION ALL
SELECT 'misc', coalesce(paymode,'(null)'), count(*)
  FROM kcet20262027.misc_collection WHERE activestatus = 1 GROUP BY 2
ORDER BY 1, 3 DESC;
