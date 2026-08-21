-- Disable auto-generation of fee demands on student insert (ALL SCHEMAS).
-- trg_gen_feedemand_on_student is an AFTER-INSERT trigger on students that
-- auto-creates tempfeedemand rows from the classfeedemand template for every
-- student created (so it fires for each imported student). Per requirement,
-- importing / adding students must NOT auto-generate demands — those are
-- generated explicitly via the Fee Demand import or generate_feedemand_from_template.
--
-- Drops the trigger only; the function fn_gen_feedemand_on_student is kept so
-- the behaviour can be re-enabled by re-creating the trigger. Idempotent.

DO $$
DECLARE schema_name TEXT;
BEGIN
    FOR schema_name IN
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT IN ('public', 'pg_catalog', 'information_schema', 'pg_toast', 'extensions', 'auth', 'storage', 'realtime', 'supabase_functions', 'graphql', 'graphql_public', 'pgsodium', 'pgsodium_masks', 'vault', 'net', '_realtime', 'supabase_migrations')
        AND nspname NOT LIKE 'pg_%'
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = schema_name AND table_name = 'students') THEN
            EXECUTE format('DROP TRIGGER IF EXISTS trg_gen_feedemand_on_student ON %I.students', schema_name);
            RAISE NOTICE 'Disabled auto-generation on schema: %', schema_name;
        END IF;
    END LOOP;
END $$;
