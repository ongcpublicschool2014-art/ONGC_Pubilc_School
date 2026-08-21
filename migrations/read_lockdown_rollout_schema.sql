-- ============================================================================
-- READ LOCKDOWN rollout — institution-schema PII + money tables.
-- ============================================================================
-- For each institution schema, for each sensitive table: ensure RLS on, DROP the
-- legacy permissive "allow all" policy (qual = true — the leak), and add a
-- tenant-scoped SELECT policy. Reads then require a valid session token (the app
-- sends x-app-token → app_pre_request sets app.ins_id → policy matches). Writes
-- are unaffected: the SECURITY DEFINER RPCs own these tables and bypass RLS, and
-- direct anon writes are already revoked (phase3a/3b).
--
-- Scope: only tables always read AFTER login (token present). PUBLIC tables that
-- are read during login (institution / institutionusers) are intentionally NOT
-- here. Requires read_lockdown_foundation.sql. Idempotent + reversible.
-- ============================================================================
DO $do$
DECLARE
  r record; pol record;
  sensitive text[] := ARRAY[
    'students','parents','parentdetail',
    'payment','paymentdetails','feedemand','fee_refund','fee_refunddetails'
  ];
BEGIN
  FOR r IN
    SELECT n.nspname AS sch, c.relname AS tbl
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'r' AND c.relname = ANY(sensitive)
       AND n.nspname NOT IN ('public','pg_catalog','information_schema','extensions')
       AND n.nspname NOT LIKE 'pg_%'
  LOOP
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', r.sch, r.tbl);

    -- Drop legacy permissive allow-all policies (any name; qual = true).
    FOR pol IN
      SELECT policyname FROM pg_policies
       WHERE schemaname = r.sch AND tablename = r.tbl
         AND permissive = 'PERMISSIVE' AND qual = 'true'
    LOOP
      EXECUTE format('DROP POLICY %I ON %I.%I', pol.policyname, r.sch, r.tbl);
    END LOOP;

    -- Add the tenant read policy if missing. Tables WITH ins_id get the strict
    -- per-tenant policy; ins_id-less schema tables (e.g. bank — isolated by
    -- schema) get a valid-session policy (else RLS-on-with-no-policy denies all).
    IF NOT EXISTS (SELECT 1 FROM pg_policies
                    WHERE schemaname = r.sch AND tablename = r.tbl AND policyname = 'app_tenant_read')
    THEN
      IF EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = r.sch AND table_name = r.tbl AND column_name = 'ins_id') THEN
        EXECUTE format('CREATE POLICY app_tenant_read ON %I.%I FOR SELECT USING (ins_id = public.current_app_ins())',
                       r.sch, r.tbl);
      ELSE
        EXECUTE format('CREATE POLICY app_tenant_read ON %I.%I FOR SELECT USING (public.current_app_ins() IS NOT NULL)',
                       r.sch, r.tbl);
      END IF;
    END IF;
    RAISE NOTICE 'read-locked %.%', r.sch, r.tbl;
  END LOOP;
END $do$;

NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- ROLLBACK (restore open reads on a table if a screen breaks):
--   DROP POLICY IF EXISTS app_tenant_read ON <schema>.<table>;
--   CREATE POLICY "<table> allow all" ON <schema>.<table> FOR ALL
--     TO anon, authenticated USING (true);
-- ============================================================================
