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
