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
