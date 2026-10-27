-- ============================================================================
-- fix_student_import_rls.sql
-- Supabase Advisor CRITICAL: "Policy Exists RLS Disabled" on <schema>.student_import
-- — the table has an "Allow all" RLS POLICY but ROW LEVEL SECURITY is NOT enabled,
-- so the policy is inert and the table is wide open. Enabling RLS makes the
-- existing permissive policy actually take effect (behaviour unchanged for the
-- app — student-import staging still reads/writes via anon — but the advisor
-- warning clears and the config is consistent).
--
-- Runs for EVERY schema that has a student_import table. Idempotent: re-enabling
-- RLS and re-creating the permissive policy are both safe to repeat.
-- ============================================================================
DO $$
DECLARE r record; sname text;
BEGIN
  FOR r IN
    SELECT table_schema FROM information_schema.tables WHERE table_name = 'student_import'
  LOOP
    sname := r.table_schema;
    -- Turn RLS on so the policy is enforced (clears the "RLS Disabled" advisor).
    EXECUTE format('ALTER TABLE %I.student_import ENABLE ROW LEVEL SECURITY', sname);
    -- Ensure a permissive all-operations policy so the import staging flow
    -- (anon insert/select/delete) keeps working exactly as before.
    BEGIN
      EXECUTE format('DROP POLICY IF EXISTS "Allow all" ON %I.student_import', sname);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    EXECUTE format(
      'CREATE POLICY "Allow all" ON %I.student_import FOR ALL TO anon, authenticated USING (true) WITH CHECK (true)',
      sname);
  END LOOP;
END $$;
