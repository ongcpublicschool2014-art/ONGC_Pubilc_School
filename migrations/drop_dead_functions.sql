-- Drop dead/superseded functions from existing DBs (verified: no callers in the
-- desktop app or in any other function/trigger in complete_setup.sql).
-- Matches the removals made in complete_setup.sql. Idempotent (IF EXISTS).
--
-- NOTE: the two payment "atomic" functions (initiate_payment_atomic,
-- complete_payment_atomic) are intentionally NOT dropped here — they may still
-- be called by the separate MOBILE app. Confirm that before removing them.

DROP FUNCTION IF EXISTS public.activate_subscription_code(integer, text);
DROP FUNCTION IF EXISTS public.generate_feedemand_from_template(integer);
DROP FUNCTION IF EXISTS public.get_student_ledger_data(integer, text);
DROP FUNCTION IF EXISTS public.get_overdue_total(integer);
DROP FUNCTION IF EXISTS public.hash_password(text);
DROP FUNCTION IF EXISTS public.verify_password(text, text);
