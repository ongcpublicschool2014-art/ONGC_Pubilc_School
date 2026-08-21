-- Make feedemand / tempfeedemand yr_id NULLABLE (ALL SCHEMAS)
-- ------------------------------------------------------------------
-- Arrear imports may carry a Fee/Arrear Year (e.g. "2022-2023") that isn't in
-- the institution's year master. Per user preference, such a row is stored with
-- yr_id = NULL (the raw label is still kept in demfeeyear) rather than being
-- rejected or silently reassigned to the current year. yr_id was NOT NULL on
-- both the staging and final tables, which blocked that.
--
-- Run once in the Supabase SQL editor - auto-detects every schema with a
-- feedemand table. Idempotent (DROP NOT NULL is a no-op if already nullable).

DO $$
DECLARE
    schema_name TEXT;
BEGIN
    FOR schema_name IN
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT IN ('public', 'pg_catalog', 'information_schema', 'pg_toast', 'extensions', 'auth', 'storage', 'realtime', 'supabase_functions', 'graphql', 'graphql_public', 'pgsodium', 'pgsodium_masks', 'vault', 'net', '_realtime', 'supabase_migrations')
        AND nspname NOT LIKE 'pg_%'
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = schema_name AND table_name = 'feedemand') THEN
            EXECUTE format('ALTER TABLE %I.feedemand ALTER COLUMN yr_id DROP NOT NULL', schema_name);
            EXECUTE format('ALTER TABLE %I.tempfeedemand ALTER COLUMN yr_id DROP NOT NULL', schema_name);
            RAISE NOTICE 'Updated schema: %', schema_name;
        END IF;
    END LOOP;
END $$;
