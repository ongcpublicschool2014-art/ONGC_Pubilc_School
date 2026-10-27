-- ============================================================================
-- Run this AFTER restoring a pg_dump backup into a NEW Supabase project.
--
-- The backups are taken with --no-owner --no-privileges, so the dump carries
-- tables, data, functions, policies and RLS -- but NO grants. Restore alone
-- therefore leaves `anon` with no access at all and the app reads nothing,
-- which looks like an empty database rather than a permissions problem.
--
-- This reissues exactly the grants create_institution_schema would have made,
-- including the Option-B write lockdown, so the restored project ends up with
-- the same security posture as the one it came from -- not a more open one.
--
-- Safe to re-run.
-- ============================================================================

-- ── public ──────────────────────────────────────────────────────────────────
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated;

-- ── every institution schema in the restore ─────────────────────────────────
DO $g$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'students')
       AND left(nspname,3) <> 'pg_'
       AND nspname NOT IN ('public','information_schema','auth','storage',
                           'realtime','vault','extensions','graphql','graphql_public')
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO anon, authenticated', r.nspname);
    EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO anon, authenticated', r.nspname);
    EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO anon, authenticated', r.nspname);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO anon, authenticated', r.nspname);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO anon, authenticated', r.nspname);

    -- Option B: the money and PII tables are written ONLY through the
    -- session-gated SECURITY DEFINER RPCs, so anon keeps SELECT but loses
    -- direct writes. Without this the restored project would be MORE open than
    -- the original. Wrapped because an older schema may lack some of them.
    BEGIN
      EXECUTE format(
        'REVOKE INSERT, UPDATE, DELETE ON %I.payment, %I.paymentdetails, %I.feedemand, '
        '%I.fee_refund, %I.fee_refunddetails, %I.students, %I.parents, %I.parentdetail FROM anon',
        r.nspname, r.nspname, r.nspname, r.nspname, r.nspname, r.nspname, r.nspname, r.nspname);
    EXCEPTION WHEN undefined_table THEN
      RAISE NOTICE 'money-table revoke skipped for % (table missing)', r.nspname;
    END;
    BEGIN
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.concession, %I.concessiondetail FROM anon',
                     r.nspname, r.nspname);
    EXCEPTION WHEN undefined_table THEN NULL;
    END;

    RAISE NOTICE 'granted + locked down %', r.nspname;
  END LOOP;
END
$g$;

-- ── PostgREST must rebuild its cache, or every request 503s ────────────────
NOTIFY pgrst, 'reload schema';

-- ── Verify: anon should have SELECT but NOT INSERT on a money table ────────
SELECT table_schema, table_name, privilege_type
  FROM information_schema.table_privileges
 WHERE grantee = 'anon'
   AND table_name IN ('feedemand','payment','students')
 ORDER BY table_schema, table_name, privilege_type;
