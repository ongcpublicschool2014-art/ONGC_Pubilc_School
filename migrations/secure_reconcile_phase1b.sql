-- ============================================================================
-- Phase 1b — session-gated wrapper for bank reconciliation.
-- ============================================================================
-- reconcile_payments_batch is SECURITY INVOKER (runs as the caller), so it only
-- works today thanks to anon's table grants and would BREAK on the Phase 3
-- REVOKE. This DEFINER wrapper validates the session token, derives ins_id +
-- schema server-side, and calls the batch — which then runs with the wrapper's
-- (owner) privileges, so it survives the REVOKE. The client calls the wrapper;
-- reconcile_payments_batch itself will be REVOKEd from anon in Phase 3.
-- Requires secure_app_session.sql. Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reconcile_payments_secure(
  p_token text, p_pay_ids integer[], p_user text,
  p_bank_ref text DEFAULT NULL, p_bank_date text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  RETURN public.reconcile_payments_batch(v_schema, v_ins, p_pay_ids, p_user, p_bank_ref, p_bank_date);
END; $$;

GRANT EXECUTE ON FUNCTION public.reconcile_payments_secure(text, integer[], text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
