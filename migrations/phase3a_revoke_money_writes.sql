-- ============================================================================
-- Phase 3a — LOCKDOWN: revoke anon direct writes on the Group-A money tables.
-- ============================================================================
--  ⚠ THIS IS THE BREAKING STEP. Run it ONLY after ALL of the following:
--     1. Every Group-A write-RPC migration is deployed on this database:
--        secure_app_session, secure_payments_phase1, secure_feedemand_phase1b,
--        secure_reconcile_phase1b, secure_refund_phase1b, secure_feedemand_phase1c,
--        secure_payments_phase1d.
--     2. You have logged in and exercised EVERY money screen end-to-end and
--        confirmed it still works (fee collection cash/cheque/Paytm, fee refund,
--        bank reconciliation, fines/concession, fee-definition, class fee demand).
--
--  Why it's safe: every client money-write now routes through a SECURITY DEFINER
--  RPC. DEFINER functions run as their OWNER, not as anon, so they keep working
--  after anon loses direct write. Only SELECT is left intact (reads unchanged —
--  read lockdown is a separate later phase). The direct-write code paths that
--  remain in the app are no-token fallbacks that never run for a logged-in user.
--
--  Scope: the money tables live in the per-institution SCHEMAS (e.g.
--  kcet20262027), so this revokes across EVERY schema that has them. New schemas
--  created after this must also be locked — see the create_institution_schema
--  note at the bottom.
-- ============================================================================

-- 1) Existing schemas: revoke INSERT/UPDATE/DELETE on each money table present.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT table_schema, table_name
      FROM information_schema.tables
     WHERE table_name IN ('payment','paymentdetails','feedemand','fee_refund','fee_refunddetails')
       AND table_schema NOT IN ('public','pg_catalog','information_schema','extensions')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.%I FROM anon', r.table_schema, r.table_name);
    RAISE NOTICE 'revoked anon writes on %.%', r.table_schema, r.table_name;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY (run separately, as the anon role, e.g. from the app or a REST call):
--   A direct PATCH/POST to feedemand or payment must now return 401/403.
--   The same action through the app (which calls the RPCs) must still succeed.
--   Attempting complete_payment_grouped with a bogus status must be rejected by
--   the RPC's server-side checks.
--
-- Check remaining grants for a given schema (replace kcet20262027):
--   SELECT grantee, table_name, privilege_type
--     FROM information_schema.role_table_grants
--    WHERE table_schema = 'kcet20262027'
--      AND table_name IN ('payment','paymentdetails','feedemand','fee_refund','fee_refunddetails')
--      AND grantee IN ('anon','authenticated','PUBLIC')
--    ORDER BY table_name, grantee, privilege_type;
--   -> anon should show SELECT only (no INSERT/UPDATE/DELETE). If INSERT/UPDATE/
--      DELETE still appear for grantee 'PUBLIC', the grant was made to PUBLIC and
--      must be revoked from PUBLIC too (repeat the DO block with FROM PUBLIC).
-- ============================================================================

-- ============================================================================
-- ROLLBACK (if a screen breaks and you must restore the old behaviour fast):
--   DO $$
--   DECLARE r record;
--   BEGIN
--     FOR r IN
--       SELECT table_schema, table_name FROM information_schema.tables
--        WHERE table_name IN ('payment','paymentdetails','feedemand','fee_refund','fee_refunddetails')
--          AND table_schema NOT IN ('public','pg_catalog','information_schema','extensions')
--          AND table_schema NOT LIKE 'pg_%'
--     LOOP
--       EXECUTE format('GRANT INSERT, UPDATE, DELETE ON %I.%I TO anon', r.table_schema, r.table_name);
--     END LOOP;
--   END $$;
-- ============================================================================

-- ============================================================================
-- FUTURE SCHEMAS: create_institution_schema (the generator) currently grants
-- anon write on all new tables. After this lockdown, add — at the END of that
-- function, once the money tables exist — the same revoke so new institutions
-- are born locked:
--   EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.payment, %I.paymentdetails, '
--     '%I.feedemand, %I.fee_refund, %I.fee_refunddetails FROM anon',
--     p_schema, p_schema, p_schema, p_schema, p_schema);
-- (Ask and I will patch create_institution_schema in complete_setup.sql + a
--  standalone migration to run on Supabase.)
-- ============================================================================
