-- Drop the UNIQUE constraints on student/parent EMAIL (ALL SCHEMAS).
-- students_stuemail_key (stuemail) and parents_paremail_key (paremail) are not
-- valid for this data: students commonly share or lack an email, and parents
-- (siblings / one family email) share theirs. With these constraints a bulk
-- student import fails with "Duplicate record found" on the first shared or
-- placeholder address — even though the students themselves are distinct.
-- The identity constraints uq_students_admission (ins_id, stuadmno) and
-- parentdetail_stuadmno_key stay. Idempotent.

DO $$
DECLARE schema_name TEXT;
BEGIN
    FOR schema_name IN
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT IN ('public', 'pg_catalog', 'information_schema', 'pg_toast', 'extensions', 'auth', 'storage', 'realtime', 'supabase_functions', 'graphql', 'graphql_public', 'pgsodium', 'pgsodium_masks', 'vault', 'net', '_realtime', 'supabase_migrations')
        AND nspname NOT LIKE 'pg_%'
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = schema_name AND table_name = 'students') THEN
            EXECUTE format('ALTER TABLE %I.students DROP CONSTRAINT IF EXISTS students_stuemail_key', schema_name);
            EXECUTE format('ALTER TABLE %I.parents  DROP CONSTRAINT IF EXISTS parents_paremail_key', schema_name);
            RAISE NOTICE 'Dropped email unique constraints on schema: %', schema_name;
        END IF;
    END LOOP;
END $$;
