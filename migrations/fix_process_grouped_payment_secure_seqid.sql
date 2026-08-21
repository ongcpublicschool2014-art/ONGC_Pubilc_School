-- FIX: session-token fee collection failed with "Payment failed. Something went
-- wrong." on the freshly-rebuilt DB.
--
-- Root cause: process_grouped_payment_secure() forwarded an 11th argument
-- (p_seq_id) to public.process_grouped_payment(...), but NO version of that
-- function has an 11th parameter (they all end at p_items jsonb). At runtime
-- Postgres raised "function public.process_grouped_payment(..., integer) does
-- not exist", so every collection made by a logged-in (session-token) user
-- failed. The non-token legacy path was unaffected, which is why imports worked.
--
-- Fix: keep the wrapper's signature (so the GRANT stays valid and no DROP is
-- needed) but stop forwarding p_seq_id. It's accepted for forward-compat only.

CREATE OR REPLACE FUNCTION public.process_grouped_payment_secure(
  p_token text, p_inscode character varying, p_stu_id bigint, p_yr_id integer,
  p_yrlabel character varying, p_total_amount numeric, p_created_by character varying,
  p_pay_method text, p_pay_reference text, p_items jsonb, p_seq_id integer DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  RETURN public.process_grouped_payment(v_ins, p_inscode, p_stu_id, p_yr_id, p_yrlabel,
                                        p_total_amount, p_created_by, p_pay_method, p_pay_reference,
                                        p_items);
END; $$;

GRANT EXECUTE ON FUNCTION public.process_grouped_payment_secure(text, character varying, bigint, integer, character varying, numeric, character varying, text, text, jsonb, integer) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
