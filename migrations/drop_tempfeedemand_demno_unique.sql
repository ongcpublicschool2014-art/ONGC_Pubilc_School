-- Drop the UNIQUE constraint on tempfeedemand.demno (ALL SCHEMAS).
-- A Fee Demand import stages one row per (demand, fee type). Files legitimately
-- repeat the same Demand No across a student's fee-type line items (and across
-- re-imports), so UNIQUE(demno) makes the batch insert fail with
-- "duplicate key value violates unique constraint tempfeedemand_demno_key".
-- feedemand.demno is NOT unique, so tempfeedemand shouldn't be either; the
-- approval trigger already de-dupes real duplicates by
-- (ins_id, stu_id, fee type, term, year, demfeeyear, Regular/Arrear). Idempotent.

DO $$
DECLARE schema_name TEXT;
BEGIN
    FOR schema_name IN
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT IN ('public', 'pg_catalog', 'information_schema', 'pg_toast', 'extensions', 'auth', 'storage', 'realtime', 'supabase_functions', 'graphql', 'graphql_public', 'pgsodium', 'pgsodium_masks', 'vault', 'net', '_realtime', 'supabase_migrations')
        AND nspname NOT LIKE 'pg_%'
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = schema_name AND table_name = 'tempfeedemand') THEN
            EXECUTE format('ALTER TABLE %I.tempfeedemand DROP CONSTRAINT IF EXISTS tempfeedemand_demno_key', schema_name);
            RAISE NOTICE 'Dropped tempfeedemand_demno_key on schema: %', schema_name;
        END IF;
    END LOOP;
END $$;
