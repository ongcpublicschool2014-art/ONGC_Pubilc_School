-- =====================================================================
-- Stop a payment that already carries a RECEIPT NUMBER from being failed
-- or deleted. Two separate symptoms, one cause.
--
-- SYMPTOM 1 -- a FAILED transaction showing a receipt number.
--   set_payment_status is a bare UPDATE ... WHERE pay_id = $5. The parent
--   app's failure path calls it with 'F', and nothing stops it flipping a
--   row that has already produced a receipt. On 2026-10-01 that put
--   FC26/03272 and FC26/03273 (Rs 3,600, captured by Paytm) on the failed
--   list, so the collection reports under-counted real money.
--
-- SYMPTOM 2 -- gaps in the receipt register.
--   complete_payment_grouped ends by deleting the original payment row:
--   DELETE FROM payment WHERE pay_id = $1, unconditional. Run twice for the
--   same payment -- a retry -- the second run DELETES the row holding the
--   first receipt number and draws a fresh one. The old number is gone from
--   the register while the counter has moved past it. That is FC26/03268 and
--   FC26/03270: each sits immediately before a receipt for the same student.
--
-- The rule both now follow: a receipt number, once drawn and attached, is a
-- record of money. Nothing may silently fail it or delete it.
--
-- Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Never fail a receipted payment.
--    Other transitions still work, so a pending row can still be completed
--    or failed normally; only a row that already produced a receipt is
--    protected, and only from being marked failed or cancelled.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_payment_status(
  p_ins_id integer, p_pay_id bigint, p_status text DEFAULT NULL::text,
  p_method text DEFAULT NULL::text, p_reference text DEFAULT NULL::text,
  p_touch_date boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout TO '15s'
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE v text; v_no text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;

  IF p_status IN ('F','I') THEN
    EXECUTE format('SELECT paynumber FROM %I.payment WHERE pay_id = $1', v)
      INTO v_no USING p_pay_id;
    IF COALESCE(v_no,'') <> '' THEN
      -- The receipt exists and the demand behind it has been credited.
      -- Marking it failed would hide money the college has actually taken.
      RAISE EXCEPTION
        'Payment % already carries receipt % and cannot be marked %. '
        'If the money must be given back, raise a refund.',
        p_pay_id, v_no, p_status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  EXECUTE format(
    'UPDATE %I.payment SET '
    'paystatus = COALESCE($1, paystatus), '
    'paymethod = COALESCE($2, paymethod), '
    'payreference = COALESCE($3, payreference), '
    'paydate = CASE WHEN $4 THEN now() ELSE paydate END '
    'WHERE pay_id = $5', v)
  USING p_status, p_method, p_reference, p_touch_date, p_pay_id;
END; $function$;

GRANT EXECUTE ON FUNCTION public.set_payment_status(integer, bigint, text, text, text, boolean)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. Never delete a receipted payment.
--    complete_payment_grouped is long and handles the money, so it is NOT
--    rewritten here. Only its final DELETE is narrowed, by replacing the
--    function source in place: the row is removed only while it has no
--    receipt number, which is the case it was written for (the temporary
--    'I' row). A retry then leaves the first receipt standing instead of
--    destroying it, and no number is lost.
-- ---------------------------------------------------------------------
DO $patch$
DECLARE src text; newsrc text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc
   WHERE proname = 'complete_payment_grouped' AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'complete_payment_grouped not found';
  END IF;

  -- Test for the guard BEFORE attempting the replace. The unguarded DELETE is a
  -- PREFIX of the guarded one, so replace() happily matches an already-patched
  -- source and appends the predicate a second time -- which is what produced
  -- `AND paynumber IS NULL AND paynumber IS NULL` on TEST. Checking first makes
  -- re-running genuinely idempotent.
  -- Repair the doubling an earlier, non-idempotent run of this script left
  -- behind. `AND paynumber IS NULL AND paynumber IS NULL` is harmless logically
  -- but it is not what anyone reading the function should find.
  IF position('AND paynumber IS NULL AND paynumber IS NULL' in src) > 0 THEN
    EXECUTE replace(src, 'AND paynumber IS NULL AND paynumber IS NULL',
                         'AND paynumber IS NULL');
    RAISE NOTICE 'complete_payment_grouped: collapsed a duplicated guard predicate';
    RETURN;
  END IF;

  IF position('AND paynumber IS NULL' in src) > 0 THEN
    RAISE NOTICE 'complete_payment_grouped already guarded -- nothing to do';
    RETURN;
  END IF;

  newsrc := replace(
    src,
    'DELETE FROM %I.payment WHERE pay_id=$1',
    'DELETE FROM %I.payment WHERE pay_id=$1 AND paynumber IS NULL');

  IF newsrc = src THEN
    RAISE EXCEPTION 'REFUSED: the expected DELETE was not found, so the '
                    'function has changed shape. Patch it by hand.';
  END IF;

  EXECUTE newsrc;
  RAISE NOTICE 'complete_payment_grouped: delete now skips receipted rows';
END $patch$;
