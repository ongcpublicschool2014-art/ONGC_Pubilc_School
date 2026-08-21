-- ============================================================================
-- Phase 3b — LOCKDOWN: revoke anon writes on the OPEN PII / user tables.
-- ============================================================================
--  ⚠ Run ONLY after `consolidated_secure_writes.sql` is deployed AND you've
--    tested: add/edit student (incl. parent + photo), section transfer, interim
--    promotion, create staff user (Admin Creation), add/edit designation.
--
--  This targets the tables that a live anon-key probe (2026-08-13) showed STILL
--  WRITABLE and whose every app write now routes through a SECURITY DEFINER RPC:
--    • students / parents / parentdetail  (schema)  → save_student/parent/parentdetail
--    • staffdesignation                   (public)  → save_public_row/delete_public_row
--    • institutionusers                   (public)  → save_public_row (INSERT path)
--
--  institutionusers gets INSERT + UPDATE + DELETE revoked — the whole
--  privilege-escalation surface (anon can no longer create, modify, or remove an
--  admin account). The Super-Admin "My Account" edit now goes through
--  update_super_admin_self (server-side password re-verify), so it survives the
--  revoke. REQUIRES secure_superadmin_self.sql deployed first.
--
--  NOT touched here (still need work first — do NOT add them blindly):
--    • admission            — may have a bulk-import write path; verify first.
--    • feetype/feegroup/course/class/semester/... — master_import UPSERTS them
--      directly (un-gated); revoking breaks Master Import.
--    • classfeedemand/tempfeedemand/notice/notification/interim_promotion/
--      student_import — un-gated bulk/compound writes.
--  Money tables are handled by phase3a (already effectively locked live).
-- ============================================================================

-- 1) Institution-SCHEMA PII tables: revoke across every schema that has them.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT table_schema, table_name
      FROM information_schema.tables
     WHERE table_name IN ('students','parents','parentdetail')
       AND table_schema NOT IN ('public','pg_catalog','information_schema','extensions')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.%I FROM anon', r.table_schema, r.table_name);
    RAISE NOTICE 'revoked anon writes on %.%', r.table_schema, r.table_name;
  END LOOP;
END $$;

-- 2) PUBLIC tables.
--    staffdesignation: full revoke (all writes go through save/delete_public_row).
REVOKE INSERT, UPDATE, DELETE ON public.staffdesignation FROM anon;
--    institutionusers: full revoke — the Super-Admin self-edit now uses the
--    update_super_admin_self RPC, so no direct anon write remains.
REVOKE INSERT, UPDATE, DELETE ON public.institutionusers FROM anon;

NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY (anon REST, e.g. curl). Replace kcet20262027 as needed.
--   PATCH  …/students?stu_id=eq.-1            (Content-Profile: kcet20262027) -> 401
--   POST   …/institutionusers                 (Content-Profile: public)       -> 401
--   PATCH  …/staffdesignation?des_id=eq.-1     (Content-Profile: public)       -> 401
--   The same actions IN THE APP (which call the RPCs) must still succeed.
-- ============================================================================

-- ============================================================================
-- ROLLBACK (fast restore if a screen breaks):
--   DO $$ DECLARE r record; BEGIN
--     FOR r IN SELECT table_schema, table_name FROM information_schema.tables
--       WHERE table_name IN ('students','parents','parentdetail')
--         AND table_schema NOT IN ('public','pg_catalog','information_schema','extensions')
--         AND table_schema NOT LIKE 'pg_%'
--     LOOP EXECUTE format('GRANT INSERT, UPDATE, DELETE ON %I.%I TO anon', r.table_schema, r.table_name); END LOOP;
--   END $$;
--   GRANT INSERT, UPDATE, DELETE ON public.staffdesignation   TO anon;
--   GRANT INSERT, UPDATE, DELETE ON public.institutionusers   TO anon;
-- ============================================================================
-- create_institution_schema already revokes students/parents/parentdetail on
-- NEW schemas (same pattern as the money tables).
-- ============================================================================
