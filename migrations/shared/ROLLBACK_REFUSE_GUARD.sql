-- =====================================================================
-- EMERGENCY ROLLBACK -- undo PART 2 of LIVE_RECEIPT_FIX_2026_10_01.sql.
--
-- Removes the "already produced receipt" guard from complete_payment_grouped
-- and puts the SELECT ... FOR UPDATE back to its original column list, leaving
-- the function exactly as it was before that part ran.
--
-- It does NOT touch PART 1 (the delete guard and set_payment_status) or PART 3
-- (the read-only register functions), because neither is on the collection
-- path: PART 1 only narrows a DELETE and adds a refusal to set_payment_status,
-- and PART 3 creates two functions nothing calls.
--
-- Run this if live collection is failing. It restores the previous behaviour
-- immediately. The only thing given up is protection against a payment being
-- receipted twice.
--
-- Patches the deployed source, so it adapts to whatever is live now, and
-- refuses rather than guessing if the function is not in the expected shape.
-- Safe to re-run.
-- =====================================================================
DO $rollback$
DECLARE src text; newsrc text; changed boolean := false;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc
   WHERE proname = 'complete_payment_grouped'
     AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'complete_payment_grouped not found';
  END IF;

  -- 1. remove the guard block -- the exact text REFUSE_REPROCESSING inserted,
  --    reversed literally rather than by pattern, so it either matches what was
  --    applied or does nothing at all.
  newsrc := replace(
    src,
    E'\n' || '  -- A payment that has produced a receipt is finished. Re-running the' || E'\n' ||
    '  -- collection would raise a SECOND receipt and credit the demand twice.' || E'\n' ||
    '  IF COALESCE(v_orig.paynumber,'''') <> '''' THEN' || E'\n' ||
    '    RAISE EXCEPTION ''Payment % has already produced receipt %'',' || E'\n' ||
    '      p_pay_id, v_orig.paynumber USING ERRCODE = ''check_violation'';' || E'\n' ||
    '  END IF;',
    '');
  IF newsrc <> src THEN changed := true; src := newsrc; END IF;

  -- 2. put the column list back.
  newsrc := replace(
    src,
    'SELECT ins_id,inscode,stu_id,yr_id,yrlabel,createdby,payorderid,payreference,paynumber FROM %I.payment WHERE pay_id=$1 FOR UPDATE',
    'SELECT ins_id,inscode,stu_id,yr_id,yrlabel,createdby,payorderid,payreference FROM %I.payment WHERE pay_id=$1 FOR UPDATE');
  IF newsrc <> src THEN changed := true; src := newsrc; END IF;

  IF NOT changed THEN
    RAISE NOTICE 'guard not present -- complete_payment_grouped is already in its original shape';
    RETURN;
  END IF;

  IF position('already produced receipt' in src) > 0 THEN
    RAISE EXCEPTION 'REFUSED: part of the guard could not be removed cleanly. '
                    'Do not rely on this script; restore the function by hand.';
  END IF;

  EXECUTE src;
  RAISE NOTICE 'ROLLED BACK: complete_payment_grouped no longer refuses a receipted payment';
END $rollback$;

-- Confirm. Both must say 'reverted'.
SELECT 'refuse guard'  AS part,
       CASE WHEN prosrc LIKE '%already produced receipt%' THEN 'STILL PRESENT' ELSE 'reverted' END AS status
  FROM pg_proc WHERE proname='complete_payment_grouped' AND pronamespace='public'::regnamespace
UNION ALL
SELECT 'select column list',
       CASE WHEN prosrc LIKE '%payreference,paynumber FROM %' THEN 'STILL PRESENT' ELSE 'reverted' END
  FROM pg_proc WHERE proname='complete_payment_grouped' AND pronamespace='public'::regnamespace;
