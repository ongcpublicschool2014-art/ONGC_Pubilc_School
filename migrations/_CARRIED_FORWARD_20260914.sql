-- ############################################################################
-- Carried forward: three functions written 12-14 September that were never
-- bundled for live. Each is CREATE OR REPLACE and independent of the rest.
-- ############################################################################

-- ---------------------------------------------------------------------------
-- source: migrations/reconcile_payments_batch_definer.sql
-- ---------------------------------------------------------------------------
-- ============================================================================
-- reconcile_payments_batch -> SECURITY DEFINER
--
-- SYMPTOM (live, 12 Sep 2026): reconciling a FEE receipt logged
--     42501  permission denied for table payment
-- four times, and the reconcile silently did nothing.
--
-- CAUSE: this function was created without SECURITY DEFINER, so it runs as the
-- CALLER -- anon. The money-table lockdown revoked INSERT/UPDATE/DELETE on
-- payment from anon, so the UPDATE inside it is refused. Its sibling
-- reconcile_misc_batch IS SECURITY DEFINER, which is why MISC receipts
-- reconciled fine while fee receipts failed.
--
-- WHY IT LOOKED FINE ON TEST: NOT the grants. Verified on test by reproducing
-- live's exact privilege state inside a rolled-back transaction: anon has no
-- UPDATE on payment there either, a direct UPDATE as anon raises 42501, and
-- this SECURITY DEFINER function then reconciled the receipt successfully.
-- The likely difference is that test's deployed function was ALREADY DEFINER
-- while complete_setup.sql carried a stale invoker-mode copy.
--
-- So on live the failure is either (a) an invoker-mode function, or (b) the
-- function being absent, with the client falling back to a direct payment
-- UPDATE that anon cannot perform. This file fixes both: it creates-or-replaces
-- the function as SECURITY DEFINER and re-grants EXECUTE.
--
-- The body below is byte-for-byte the deployed function; the ONLY change is
-- adding SECURITY DEFINER, putting it on the same footing as every other
-- money-writing RPC.
--
-- SAFE TO RE-RUN.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reconcile_payments_batch(
    p_schema        TEXT,
    p_ins_id        INT,
    p_pay_ids       INT[],
    p_user          TEXT,
    p_bank_ref      TEXT DEFAULT NULL,
    p_bank_date     TEXT DEFAULT NULL
) RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    updated_count INT := 0;
BEGIN
    IF p_pay_ids IS NULL OR array_length(p_pay_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;

    -- 1. Mark selected payments reconciled
    EXECUTE format($q$
        UPDATE %I.payment
           SET recon_status   = 'R',
               reconciled_by  = %L,
               reconciled_date = now(),
               bank_reference = COALESCE(NULLIF(%L, ''), bank_reference),
               bank_date      = COALESCE(%L::timestamp, bank_date)
         WHERE ins_id = %L
           AND pay_id = ANY (%L::INT[])
    $q$, p_schema, p_user, COALESCE(p_bank_ref, ''), p_bank_date, p_ins_id, p_pay_ids);

    GET DIAGNOSTICS updated_count = ROW_COUNT;

    -- 2. Recompute reconbalancedue for every demand touched by any of the
    --    now-reconciled payments. feedemand.pay_id is single-valued (and
    --    overwritten by the latest payment), so partial payments across two
    --    days would be missed by a pay_id-based WHERE. Use paymentdetails
    --    instead, and compute reconbalancedue as
    --      feeamount - conamount - sum(reconciled payments for this demand).
    EXECUTE format($q$
        UPDATE %1$I.feedemand fd
           SET reconbalancedue = GREATEST(
                 COALESCE(fd.feeamount, 0) - COALESCE(fd.conamount, 0) - COALESCE((
                     SELECT SUM(pd2.transtotalamount)
                     FROM %1$I.paymentdetails pd2
                     JOIN %1$I.payment p2
                       ON p2.pay_id = pd2.pay_id
                     WHERE pd2.dem_id = fd.dem_id
                       AND pd2.ins_id = %2$L
                       AND p2.paystatus = 'C'
                       AND p2.recon_status = 'R'
                 ), 0),
                 0)
         WHERE fd.ins_id = %2$L
           AND fd.dem_id IN (
               SELECT pd.dem_id
               FROM %1$I.paymentdetails pd
               WHERE pd.pay_id = ANY (%3$L::INT[])
                 AND pd.ins_id = %2$L
           )
    $q$, p_schema, p_ins_id, p_pay_ids);

    RETURN updated_count;
END $$;


GRANT EXECUTE ON FUNCTION public.reconcile_payments_batch(TEXT, INT, INT[], TEXT, TEXT, TEXT)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify: expects security_definer = true
SELECT p.prosecdef AS security_definer
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'reconcile_payments_batch';

-- ---------------------------------------------------------------------------
-- source: migrations/mark_payment_notifications_read.sql
-- ---------------------------------------------------------------------------
-- ============================================================================
-- mark_payment_notifications_read -- parent app marks receipt notifications
-- as read without an UPDATE grant on payment.
--
-- WHY: payment is a money table and anon's INSERT/UPDATE/DELETE on it is
-- revoked. The parent app updated payment.notification_read directly, which
-- Postgres refused (42501 permission denied for table payment). The app
-- swallows the error, so read state never saved -- and the refusals filled
-- the Postgres log, where they looked like a Bank Reconciliation failure.
--
-- SECURITY DEFINER, but it can only set notification_read = true, and only on
-- the given student's own payments: no other column, no other student.
-- Returns the number of rows changed.
--
-- SAFE TO RE-RUN.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mark_payment_notifications_read(
  p_ins_id integer, p_stu_id bigint, p_pay_ids bigint[]
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout = '15s'
AS $$
DECLARE v text; n integer;
BEGIN
  IF p_pay_ids IS NULL OR array_length(p_pay_ids, 1) IS NULL THEN RETURN 0; END IF;
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN 0; END IF;
  -- Only the read flag, only this student's own payments.
  EXECUTE format(
    'UPDATE %I.payment SET notification_read = true '
    'WHERE stu_id = $1 AND pay_id = ANY ($2) '
    'AND notification_read IS DISTINCT FROM true', v)
  USING p_stu_id, p_pay_ids;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.mark_payment_notifications_read(integer, bigint, bigint[]) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify: expects security_definer = true, anon_can_execute = true
SELECT p.prosecdef AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
       pg_get_function_identity_arguments(p.oid) AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'mark_payment_notifications_read';

-- ---------------------------------------------------------------------------
-- source: migrations/delete_stale_initiated_payments_keep_ordered.sql
-- ---------------------------------------------------------------------------
-- ============================================================================
-- delete_stale_initiated_payments -- never delete a payment that reached Paytm.
--
-- WHY: the parent app calls this when it restores a cart left mid-payment,
-- which is exactly what a phone shows after the app closes during checkout.
-- It deleted EVERY in-progress ('I') payment for the student -- including one
-- where Paytm had already taken the money but the app died before recording
-- it. That erased the only record: no receipt, fee still due, and the
-- desktop's Paytm-aware recovery could no longer find it.
--
-- NOW: only 'I' payments with no order id are deleted (no gateway order, so
-- nothing can have been charged). Payments with an order id stay 'I' and are
-- resolved against Paytm by the sweeps.
--
-- Server-side, so it protects every installed app version immediately.
-- Same signature: CREATE OR REPLACE keeps the existing grant. SAFE TO RE-RUN.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.delete_stale_initiated_payments(p_ins_id integer, p_stu_id bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout = '15s'
AS $$
DECLARE v text; n integer;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN 0; END IF;
  -- Only payments that never got a gateway order id: nothing can have been
  -- charged. One WITH an order id may have been paid, so it stays 'I' for the
  -- Paytm-aware sweeps to complete or fail -- deleting it lost the record.
  EXECUTE format('DELETE FROM %I.paymentdetails WHERE pay_id IN '
                 '(SELECT pay_id FROM %I.payment WHERE stu_id=$1 AND paystatus=''I'' '
                 'AND NULLIF(btrim(payorderid), '''') IS NULL)', v, v)
    USING p_stu_id;
  EXECUTE format('WITH d AS (DELETE FROM %I.payment WHERE stu_id=$1 AND paystatus=''I'' '
                 'AND NULLIF(btrim(payorderid), '''') IS NULL RETURNING 1) '
                 'SELECT count(*) FROM d', v)
    INTO n USING p_stu_id;
  RETURN n;
END; $$;

GRANT EXECUTE ON FUNCTION public.delete_stale_initiated_payments(integer, bigint) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify: expects keeps_ordered_payments = true
SELECT position('payorderid' in p.prosrc) > 0 AS keeps_ordered_payments
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'delete_stale_initiated_payments';

