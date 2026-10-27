-- =====================================================================
-- Refuse to re-process a payment that has already produced a receipt.
--
-- WHY THIS IS NEEDED ON TOP OF PROTECT_RECEIPTED_PAYMENTS.
-- That migration narrowed the final delete to `AND paynumber IS NULL`, so a
-- numbered row can no longer be destroyed. On its own that is not enough, and
-- is arguably worse: if complete_payment_grouped is entered with a row that
-- already carries a receipt, it now
--     1. reads that row,
--     2. creates a SECOND receipt with a new number,
--     3. fails to delete the first, because the guard protects it,
-- leaving two receipts for one payment and the demand credited twice. That
-- trades a cosmetic gap in the register for real double-counted money.
--
-- The honest fix is to refuse at the door. A payment that has produced a
-- receipt is finished; whatever the caller wants, re-running the collection
-- is not it. The caller gets a clear error instead of a silent second receipt.
--
-- This also removes the need to delete a numbered row at all, so the two
-- guards agree: a receipt, once drawn, is immutable.
--
-- Patches the deployed source in place rather than restating 100 lines of
-- money logic, and refuses if the function has changed shape.
--
-- Safe to re-run.
-- =====================================================================
DO $patch$
DECLARE src text; newsrc text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc
   WHERE proname = 'complete_payment_grouped'
     AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'complete_payment_grouped not found';
  END IF;

  IF position('already produced receipt' in src) > 0 THEN
    RAISE NOTICE 'already guarded -- nothing to do';
    RETURN;
  END IF;

  -- 1. carry paynumber out of the row it already locks FOR UPDATE, so the
  --    check costs nothing extra and cannot race another collector.
  newsrc := replace(
    src,
    'SELECT ins_id,inscode,stu_id,yr_id,yrlabel,createdby,payorderid,payreference FROM %I.payment WHERE pay_id=$1 FOR UPDATE',
    'SELECT ins_id,inscode,stu_id,yr_id,yrlabel,createdby,payorderid,payreference,paynumber FROM %I.payment WHERE pay_id=$1 FOR UPDATE');
  IF newsrc = src THEN
    RAISE EXCEPTION 'REFUSED: the expected SELECT ... FOR UPDATE was not found.';
  END IF;
  src := newsrc;

  -- 2. refuse the moment we know the row is already receipted, before any
  --    number is drawn or any row is written.
  newsrc := replace(
    src,
    'IF v_orig IS NULL THEN RAISE EXCEPTION ''Payment % not found'',p_pay_id; END IF;',
    'IF v_orig IS NULL THEN RAISE EXCEPTION ''Payment % not found'',p_pay_id; END IF;' || E'\n' ||
    '  -- A payment that has produced a receipt is finished. Re-running the' || E'\n' ||
    '  -- collection would raise a SECOND receipt and credit the demand twice.' || E'\n' ||
    '  IF COALESCE(v_orig.paynumber,'''') <> '''' THEN' || E'\n' ||
    '    RAISE EXCEPTION ''Payment % has already produced receipt %'',' || E'\n' ||
    '      p_pay_id, v_orig.paynumber USING ERRCODE = ''check_violation'';' || E'\n' ||
    '  END IF;');
  IF newsrc = src THEN
    RAISE EXCEPTION 'REFUSED: the expected not-found check was not located.';
  END IF;

  EXECUTE newsrc;
  RAISE NOTICE 'complete_payment_grouped now refuses an already-receipted payment';
END $patch$;
