-- ============================================================================
-- A receipt whose money reached a bank is refunded, not cancelled.
-- ============================================================================
-- THE OLD RULE. void_receipt refused only a receipt already MATCHED on a bank
-- statement:
--
--     IF recon_status = 'R' AND NOT cash AND NOT advance-adjustment THEN refuse
--
-- which let two things through that should never have been cancellable:
--
--   1. AN ONLINE TRANSFER THAT NOBODY HAS RECONCILED YET. recon_status 'P'
--      means no one has matched the credit on the statement -- not that the
--      money has not arrived. It arrived the instant the transfer succeeded.
--      Cancelling leaves a credit on the statement with no receipt to match
--      it to, which is the exact mess reconciliation exists to prevent.
--      On this database that is 326 payment rows and 8 misc rows sitting at
--      'P' on Online Transfer.
--
--   2. AN ADVANCE ADJUSTMENT. It collected nothing -- it moved money that was
--      banked when the ADVANCE was taken. Voiding it erases the receipt
--      WITHOUT giving the advance back, so the student loses both. It is
--      reversed from the Advance side instead. The old code exempted it
--      deliberately; that exemption is what this removes.
--
-- THE NEW RULE. CASH ONLY. The notes go back across the same counter and
-- nothing ever reached a bank, so a cash receipt can be cancelled.
-- Every other mode -- cheque, DD, UPI, NEFT, online transfer, challan,
-- card, an advance adjustment, or a mode nobody recorded -- is refused,
-- and the message names Fee Refund rather than just saying no.
--
-- recon_status is no longer consulted. It records whether a credit has
-- been MATCHED on a statement, not whether the money arrived.
--
-- Applied to all three receipt writers: void_receipt (fee receipts),
-- void_misc_receipt (counter collections) and void_advance_receipt
-- (advances). The first two carry Online Transfer rows today; the third
-- is cash/cheque/DD only, and is included so an online advance taken in
-- future cannot be cancelled while its money sits in the bank.
--
-- A shared helper does the deciding, so the two cannot drift apart and the
-- app's copy of the rule has one thing to match.
--
-- Do NOT wrap in BEGIN -- the Supabase editor rolls that back silently.
-- ============================================================================


-- =================================================================== PART 1 =
-- The rule, in one place.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.receipt_cancel_block_reason(
  p_paymethod text, p_recon_status text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  -- CASH IS THE ONLY CANCELLABLE MODE. Everything else -- cheque, DD, UPI,
  -- NEFT, online transfer, challan, card, an advance adjustment, or a mode
  -- nobody recorded -- is refused.
  --
  -- The test is deliberately "is it cash", not "is it one of these other
  -- things". A spelling nobody anticipated then fails CLOSED: it is refused
  -- and someone asks why, instead of slipping through a list that did not
  -- happen to name it.
  --
  -- recon_status is not consulted at all. It records whether the credit has
  -- been MATCHED on a statement, not whether the money arrived.
  SELECT CASE
    WHEN LOWER(COALESCE(btrim(p_paymethod), '')) = 'cash' THEN NULL
    WHEN LOWER(COALESCE(btrim(p_paymethod), '')) = 'advance adjustment' THEN
      'This receipt was settled from an advance. Reverse it from Advance '
      'Adjustment so the advance goes back to the student -- cancelling here '
      'would void the receipt without returning it.'
    ELSE
      'Only a cash receipt can be cancelled. This one was paid by '
      || COALESCE(NULLIF(btrim(p_paymethod), ''), 'another mode')
      || ' -- return it through Fee Refund, which records where the money '
      || 'went. Cancelling would erase the receipt and leave the payment '
      || 'unexplained.'
  END;
$fn$;

GRANT EXECUTE ON FUNCTION public.receipt_cancel_block_reason(text, text)
  TO anon, authenticated;


-- =================================================================== PART 2 =
-- Swap the guard inside void_receipt and void_misc_receipt.
--
-- Rewrites only the IF that refuses and the message it raises; every other
-- line of those functions stays exactly as deployed, so the restore-the-
-- demands arithmetic below the guard is untouched.
--
-- ONE DO BLOCK PER FUNCTION, deliberately. A DO block is a single statement:
-- patching both inside one means a failure on the second silently rolls back
-- the first, and the NOTICE still says it succeeded. (It did, on the first
-- run of this migration.)
-- ===========================================================================

-- ---- void_receipt (fee receipts) -----------------------------------------
DO $vr$
DECLARE src text;
  oldg CONSTANT text := 'IF p.recon_status = ''R'' AND NOT v_is_cash AND NOT v_no_bank_leg THEN';
  newg CONSTANT text := 'IF public.receipt_cancel_block_reason(p.paymethod, p.recon_status) IS NOT NULL THEN';
  oldr CONSTANT text := 'RAISE EXCEPTION ''Receipt % is reconciled with the bank and cannot be deleted'', p.paynumber';
  newr CONSTANT text := 'RAISE EXCEPTION ''%'', public.receipt_cancel_block_reason(p.paymethod, p.recon_status)';
BEGIN
  SELECT pg_get_functiondef(pr.oid) INTO src
    FROM pg_proc pr JOIN pg_namespace ns ON ns.oid = pr.pronamespace
   WHERE ns.nspname = 'public' AND pr.proname = 'void_receipt';
  IF src IS NULL THEN RAISE NOTICE 'void_receipt does not exist'; RETURN; END IF;
  IF src LIKE '%receipt_cancel_block_reason%' THEN
    RAISE NOTICE 'void_receipt already patched'; RETURN;
  END IF;
  IF position(oldg in src) = 0 THEN
    RAISE EXCEPTION 'void_receipt does not carry the expected guard -- NOT patched. '
      'Its definition has changed since this migration was written.';
  END IF;
  src := replace(src, oldg, newg);
  IF position(oldr in src) > 0 THEN src := replace(src, oldr, newr); END IF;
  EXECUTE src;
  RAISE NOTICE 'patched public.void_receipt';
END
$vr$;

-- ---- void_misc_receipt (counter collections) ------------------------------
DO $vm$
DECLARE src text;
  oldg CONSTANT text := 'IF rec.recon_status = ''R'' AND NOT v_is_cash THEN';
  newg CONSTANT text := 'IF public.receipt_cancel_block_reason(rec.paymode, rec.recon_status) IS NOT NULL THEN';
  oldr CONSTANT text := 'RAISE EXCEPTION ''Receipt % is reconciled with the bank and cannot be cancelled'', rec.mcno';
  newr CONSTANT text := 'RAISE EXCEPTION ''%'', public.receipt_cancel_block_reason(rec.paymode, rec.recon_status)';
BEGIN
  SELECT pg_get_functiondef(pr.oid) INTO src
    FROM pg_proc pr JOIN pg_namespace ns ON ns.oid = pr.pronamespace
   WHERE ns.nspname = 'public' AND pr.proname = 'void_misc_receipt';
  IF src IS NULL THEN RAISE NOTICE 'void_misc_receipt does not exist'; RETURN; END IF;
  IF src LIKE '%receipt_cancel_block_reason%' THEN
    RAISE NOTICE 'void_misc_receipt already patched'; RETURN;
  END IF;
  IF position(oldg in src) = 0 THEN
    RAISE EXCEPTION 'void_misc_receipt does not carry the expected guard -- NOT patched. '
      'Its definition has changed since this migration was written.';
  END IF;
  src := replace(src, oldg, newg);
  IF position(oldr in src) > 0 THEN src := replace(src, oldr, newr); END IF;
  EXECUTE src;
  RAISE NOTICE 'patched public.void_misc_receipt';
END
$vm$;


-- ---- void_advance_receipt (advances) --------------------------------------
DO $va$
DECLARE src text;
  oldg CONSTANT text := 'IF v_adv.recon_status = ''R'' AND NOT v_is_cash THEN';
  newg CONSTANT text := 'IF public.receipt_cancel_block_reason(v_adv.paymethod, v_adv.recon_status) IS NOT NULL THEN';
  oldr CONSTANT text := 'RAISE EXCEPTION ''Advance % is reconciled with the bank and cannot be cancelled'',
      v_adv.advno USING ERRCODE = ''P0001'';';
  newr CONSTANT text := 'RAISE EXCEPTION ''%'', public.receipt_cancel_block_reason(v_adv.paymethod, v_adv.recon_status) USING ERRCODE = ''P0001'';';
BEGIN
  SELECT pg_get_functiondef(pr.oid) INTO src
    FROM pg_proc pr JOIN pg_namespace ns ON ns.oid = pr.pronamespace
   WHERE ns.nspname = 'public' AND pr.proname = 'void_advance_receipt';
  IF src IS NULL THEN RAISE NOTICE 'void_advance_receipt does not exist'; RETURN; END IF;
  IF src LIKE '%receipt_cancel_block_reason%' THEN
    RAISE NOTICE 'void_advance_receipt already patched'; RETURN;
  END IF;
  IF position(oldg in src) = 0 THEN
    RAISE EXCEPTION 'void_advance_receipt does not carry the expected guard -- NOT patched. '
      'Its definition has changed since this migration was written.';
  END IF;
  src := replace(src, oldg, newg);
  IF position(oldr in src) > 0 THEN src := replace(src, oldr, newr); END IF;
  EXECUTE src;
  RAISE NOTICE 'patched public.void_advance_receipt';
END
$va$;


-- ------------------------------------------------------------- VERIFY ------
-- 1. The rule itself. Expect: cash ok, cheque-pending ok, everything else a
--    reason.
SELECT mode, recon,
       COALESCE(left(public.receipt_cancel_block_reason(mode, recon), 46),
                '-- CANCELLABLE --') AS verdict
  FROM (VALUES ('Cash','R'), ('cash','P'),
               ('Online Transfer','P'), ('Online Transfer','R'),
               ('UPI','R'), ('NEFT/RTGS','R'),
               ('Advance Adjustment','R'),
               ('Cheque','P'), ('Cheque','R'),
               ('DD','P'), ('DD','R')) t(mode, recon);

-- 2. Both functions now defer to it. Expect true for each that exists.
SELECT p.proname,
       pg_get_functiondef(p.oid) LIKE '%receipt_cancel_block_reason%' AS uses_rule
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('void_receipt', 'void_misc_receipt', 'void_advance_receipt')
 ORDER BY 1;
