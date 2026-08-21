-- ============================================================================
-- Phase 1a — session-gated wrappers for PAYMENT COMPLETION (money path).
-- ============================================================================
-- Part of the write-lockdown remediation (docs/SECURITY_REVIEW.md, plan
-- buzzing-twirling-turtle). Today the client calls complete_payment_grouped /
-- process_grouped_payment directly with a client-supplied p_ins_id — anyone with
-- the anon key can call them for any institution. These wrappers require a valid
-- session token and derive ins_id SERVER-SIDE from it (via session_context),
-- ignoring any client value, then forward to the existing completion logic.
--
-- ADDITIVE + NON-BREAKING: the raw functions stay callable until the Phase 3
-- REVOKE. The client is rewired to call these *_secure wrappers in Phase 2
-- (only after secure_app_session.sql is run, so a real token exists).
-- Requires: secure_app_session.sql (session_context). Idempotent.
-- ============================================================================

-- Wrapper for complete_payment_grouped (offline/cash + online completion).
CREATE OR REPLACE FUNCTION public.complete_payment_secure(
  p_token         text,
  p_pay_id        bigint,
  p_pay_method    text,
  p_pay_reference text,
  p_items         jsonb,
  p_status        character DEFAULT 'C'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);  -- RAISEs if invalid/expired
  RETURN public.complete_payment_grouped(p_pay_id, p_pay_method, p_pay_reference, p_items, v_ins, p_status);
END; $$;

-- Wrapper for process_grouped_payment (grouped multi-fee-group collection).
CREATE OR REPLACE FUNCTION public.process_grouped_payment_secure(
  p_token         text,
  p_inscode       character varying,
  p_stu_id        bigint,
  p_yr_id         integer,
  p_yrlabel       character varying,
  p_total_amount  numeric,
  p_created_by    character varying,
  p_pay_method    text,
  p_pay_reference text,
  p_items         jsonb,
  p_seq_id        integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);  -- RAISEs if invalid/expired
  -- p_seq_id accepted for forward-compat but NOT forwarded: process_grouped_payment
  -- has no 11th param, so forwarding it fails with "function does not exist".
  RETURN public.process_grouped_payment(v_ins, p_inscode, p_stu_id, p_yr_id, p_yrlabel,
                                        p_total_amount, p_created_by, p_pay_method, p_pay_reference,
                                        p_items);
END; $$;

GRANT EXECUTE ON FUNCTION public.complete_payment_secure(text, bigint, text, text, jsonb, character)
  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_grouped_payment_secure(text, character varying, bigint, integer, character varying, numeric, character varying, text, text, jsonb, integer)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
