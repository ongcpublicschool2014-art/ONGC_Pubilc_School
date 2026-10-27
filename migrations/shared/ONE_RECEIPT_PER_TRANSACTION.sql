-- =====================================================================
-- A Paytm transaction may be receipted ONCE.
--
-- WHAT HAPPENED. KEERTHIKA V paid Rs 6,500 on 28-09-2026 and VIJAY J P
-- Rs 50,000 on 29-09. Paytm captured both; neither app finished recording it.
-- On 30-09 LATHA entered both by hand -- FC26/03261 and FC26/03263 -- carrying
-- the correct Paytm transaction ids. Properly receipted, demands credited,
-- nothing owed.
--
-- The attempt rows stayed behind. On 03-10 the orphan sweep found them, asked
-- Paytm, was told "captured", and completed them -- not realising the money had
-- already been receipted two days earlier. Because their `payitems` was empty,
-- complete_payment_grouped took its finalise-in-place branch: paystatus became
-- 'C', paydate became now(), NO receipt number was drawn and NO demand was
-- credited. Rs 56,500 then read as collected while the students' ledgers showed
-- it already paid by other receipts.
--
-- THE DUPLICATE WAS DETECTABLE ALL ALONG. FC26/03261 carries
-- payreference = 20260928011020000311282950738413143, the same transaction id
-- as the attempt. Nothing looked.
--
-- THE GUARD. Refuse to complete a payment whose transaction id ALREADY appears
-- on a receipted row. One capture, one receipt -- enforced where the receipt is
-- drawn, so it holds for every caller: the counter, the orphan sweep, the
-- parent app, the webhook, and anyone running SQL by hand.
--
-- It cannot refuse a normal collection: at that moment the transaction id has
-- never been seen, so there is nothing to collide with. It only ever fires on
-- a SECOND attempt to receipt the same money.
--
-- Patched into the deployed function rather than restated: the body handles the
-- money and is long, and retyping it is how a subtle change gets introduced by
-- accident. Idempotent -- it checks for itself before patching.
-- =====================================================================
DO $guard$
DECLARE src text; old_decl text; new_decl text; anchor text; addition text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
   WHERE proname = 'complete_payment_grouped' AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN RAISE EXCEPTION 'complete_payment_grouped not found'; END IF;

  IF src LIKE '%is already receipted%' THEN
    RAISE NOTICE 'one-receipt-per-transaction guard already present';
    RETURN;
  END IF;

  -- a variable to count the collision in
  old_decl := 'v_orig RECORD;';
  new_decl := 'v_orig RECORD; v_dup integer;';
  IF position(old_decl in src) = 0 THEN
    RAISE EXCEPTION 'could not find the declaration block -- NOT patched';
  END IF;
  src := replace(src, old_decl, new_decl);

  -- after the row is found, before anything is written
  anchor := 'IF v_orig IS NULL THEN RAISE EXCEPTION ''Payment % not found'',p_pay_id; END IF;';
  IF position(anchor in src) = 0 THEN
    RAISE EXCEPTION 'could not find the not-found check -- NOT patched';
  END IF;

  addition := anchor || '
  -- ONE CAPTURE, ONE RECEIPT. If this transaction id already sits on a
  -- receipted row, the money has been dealt with -- by the counter, by a
  -- manual entry, or by an earlier recovery -- and completing it again would
  -- credit a demand twice. Raising stops the whole transaction, so the
  -- caller cannot half-finish it.
  IF p_status = ''C'' AND COALESCE(btrim(p_pay_reference), '''') <> '''' THEN
    EXECUTE format(''SELECT count(*) FROM %I.payment
                      WHERE payreference = $1 AND paynumber IS NOT NULL
                        AND paystatus = ''''C'''' AND activestatus = 1
                        AND pay_id <> $2'', v)
      INTO v_dup USING p_pay_reference, p_pay_id;
    IF v_dup > 0 THEN
      RAISE EXCEPTION
        ''Paytm transaction % is already receipted on this institution. ''
        ''Completing it again would credit the demand twice.'', p_pay_reference
        USING ERRCODE = ''check_violation'';
    END IF;
  END IF;';

  src := replace(src, anchor, addition);
  EXECUTE src;
  RAISE NOTICE 'complete_payment_grouped now refuses a transaction that is already receipted';
END $guard$;

NOTIFY pgrst, 'reload schema';


-- ---------------------------------------------------------------------
-- VERIFY -- both rows must read ok.
-- ---------------------------------------------------------------------
SELECT 'one receipt per Paytm transaction' AS check,
       CASE WHEN p.prosrc LIKE '%is already receipted%' THEN 'ok' ELSE 'FAILED' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'complete_payment_grouped'
UNION ALL
SELECT 'the receipted-payment delete guard survived',
       CASE WHEN p.prosrc LIKE '%paynumber IS NULL%' THEN 'ok' ELSE 'FAILED' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'complete_payment_grouped'
 ORDER BY 1;


-- ---------------------------------------------------------------------
-- Would it have caught the two from 30-09? Must return 2.
-- ---------------------------------------------------------------------
SELECT count(*) AS captures_that_were_already_receipted
  FROM kcet20262027.payment a
 WHERE a.paynumber IS NULL
   AND COALESCE(btrim(a.payreference), '') <> ''
   AND EXISTS (SELECT 1 FROM kcet20262027.payment b
                WHERE b.payreference = a.payreference
                  AND b.paynumber IS NOT NULL AND b.paystatus = 'C'
                  AND b.activestatus = 1 AND b.pay_id <> a.pay_id);
