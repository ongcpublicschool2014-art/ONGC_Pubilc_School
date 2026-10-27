-- ============================================================================
-- Advance Collection -- stage 4: a non-cash advance reaches Bank Reconciliation.
--
-- save_advance_collection already marks cash 'R' and everything else 'P', the
-- same rule a misc receipt follows. But the Bank Reconciliation screen only
-- ever read payment and misc_collection, so an advance taken by cheque, UPI or
-- Paytm was written as pending and then had nowhere to go: it could not be
-- ticked, matched against a statement, or settled. It simply sat there.
--
-- This adds the missing half -- the batch approve -- and the screen now lists
-- advances alongside fee and misc receipts.
--
-- Mirrors reconcile_misc_batch exactly, including the guard that matters:
-- recon_status = 'P' in the WHERE clause, so approving twice cannot rewrite the
-- reconciled_by / reconciled_date of a receipt somebody else already settled.
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). TEST first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reconcile_advance_batch(
    p_ins_id    integer,
    p_adv_ids   bigint[],
    p_user      text,
    p_bank_ref  text DEFAULT NULL,
    p_bank_date text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE v text; n integer := 0;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;
  IF p_adv_ids IS NULL OR array_length(p_adv_ids, 1) IS NULL THEN RETURN 0; END IF;

  EXECUTE format('UPDATE %I.advance_collection
                     SET recon_status    = ''R'',
                         reconciled_by   = $2,
                         reconciled_date = NOW(),
                         bank_reference  = COALESCE($3, bank_reference),
                         bank_date       = COALESCE($4::date, bank_date)
                   WHERE ins_id = $5 AND adv_id = ANY($1)
                     AND recon_status = ''P'' AND activestatus = 1', v)
    USING p_adv_ids, p_user, NULLIF(p_bank_ref, ''), NULLIF(p_bank_date, ''), p_ins_id;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;

GRANT EXECUTE ON FUNCTION public.reconcile_advance_batch(integer, bigint[], text, text, text) TO anon, authenticated;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- expect one row, both flags t.
-- ============================================================================
SELECT p.proname,
       p.prosecdef                                      AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'reconcile_advance_batch';
