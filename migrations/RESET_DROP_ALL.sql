-- ============================================================================
-- FULL RESET: drop every table and function this application owns.
--
--   *** THIS DESTROYS ALL DATA. THERE IS NO UNDO. ***
--
-- Take a backup first (pg_dump, or Supabase Dashboard -> Database -> Backups).
-- Afterwards, rebuild the schema by running C:\pg_backups\complete_setup.sql.
--
-- What it removes:
--   * every tenant schema (kch20262027, and any other institution schema)
--   * every table, view, sequence, type and function in public
--
-- What it deliberately LEAVES ALONE, so the project keeps working:
--   * auth, storage, realtime, graphql, vault, extensions, cron, net,
--     supabase_functions, supabase_migrations and every pg_* schema
--   * anything owned by an installed extension (pgcrypto's functions, the
--     uuid helpers, and so on) — dropping those breaks the extension itself
--
-- Your Supabase project, its API keys, its auth users and its storage buckets
-- all survive: this only empties the database of application objects.
--
-- >>> RUN SECTION 1 FIRST and read the list. Only then run section 2. <<<
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1) PREVIEW — exactly what section 2 will drop. Nothing is changed here.
-- ---------------------------------------------------------------------------
SELECT 'schema' AS kind, nspname AS name, '' AS detail
  FROM pg_namespace
 WHERE nspname NOT IN ('public','information_schema','auth','storage','graphql',
                       'graphql_public','extensions','realtime','supabase_functions',
                       'supabase_migrations','vault','pgsodium','pgsodium_masks',
                       'cron','net','pgbouncer','_analytics','_realtime')
   AND nspname NOT LIKE 'pg\_%'
UNION ALL
SELECT 'table', tablename, ''
  FROM pg_tables WHERE schemaname = 'public'
UNION ALL
SELECT 'view', viewname, ''
  FROM pg_views WHERE schemaname = 'public'
UNION ALL
SELECT CASE p.prokind WHEN 'a' THEN 'aggregate' WHEN 'p' THEN 'procedure' ELSE 'function' END,
       p.proname,
       pg_get_function_identity_arguments(p.oid)
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   -- extension-owned objects are not ours to drop
   AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.objid = p.oid AND d.deptype = 'e')
 ORDER BY 1, 2;


-- ---------------------------------------------------------------------------
-- 2) DROP. Uncomment the whole block and run it.
--
-- Order matters: tenant schemas go first (their tables reference public), then
-- public's own objects. CASCADE clears dependent constraints, policies,
-- triggers and grants along the way.
-- ---------------------------------------------------------------------------
-- DO $reset$
-- DECLARE r record;
-- BEGIN
--   -- 2a) every institution schema
--   FOR r IN
--     SELECT nspname FROM pg_namespace
--      WHERE nspname NOT IN ('public','information_schema','auth','storage','graphql',
--                            'graphql_public','extensions','realtime','supabase_functions',
--                            'supabase_migrations','vault','pgsodium','pgsodium_masks',
--                            'cron','net','pgbouncer','_analytics','_realtime')
--        AND nspname NOT LIKE 'pg\_%'
--   LOOP
--     EXECUTE format('DROP SCHEMA %I CASCADE', r.nspname);
--     RAISE NOTICE 'dropped schema %', r.nspname;
--   END LOOP;
--
--   -- 2b) public views (before tables, so nothing depends on a dropped table)
--   FOR r IN SELECT viewname FROM pg_views WHERE schemaname = 'public' LOOP
--     EXECUTE format('DROP VIEW IF EXISTS public.%I CASCADE', r.viewname);
--   END LOOP;
--
--   FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname = 'public' LOOP
--     EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS public.%I CASCADE', r.matviewname);
--   END LOOP;
--
--   -- 2c) public tables, skipping anything an extension owns
--   FOR r IN
--     SELECT c.relname
--       FROM pg_class c
--       JOIN pg_namespace n ON n.oid = c.relnamespace
--      WHERE n.nspname = 'public' AND c.relkind = 'r'
--        AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                         WHERE d.objid = c.oid AND d.deptype = 'e')
--   LOOP
--     EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', r.relname);
--   END LOOP;
--
--   -- 2d) functions, procedures and aggregates -- each needs its own DROP verb,
--   --     and the identity arguments, because overloads share a name
--   FOR r IN
--     SELECT p.prokind,
--            p.proname,
--            pg_get_function_identity_arguments(p.oid) AS args
--       FROM pg_proc p
--       JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'public'
--        AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                         WHERE d.objid = p.oid AND d.deptype = 'e')
--   LOOP
--     BEGIN
--       IF r.prokind = 'a' THEN
--         EXECUTE format('DROP AGGREGATE IF EXISTS public.%I(%s) CASCADE', r.proname, r.args);
--       ELSIF r.prokind = 'p' THEN
--         EXECUTE format('DROP PROCEDURE IF EXISTS public.%I(%s) CASCADE', r.proname, r.args);
--       ELSE
--         EXECUTE format('DROP FUNCTION IF EXISTS public.%I(%s) CASCADE', r.proname, r.args);
--       END IF;
--     EXCEPTION WHEN undefined_function OR undefined_object THEN
--       -- already gone via a CASCADE from something dropped earlier
--       NULL;
--     END;
--   END LOOP;
--
--   -- 2e) leftover sequences and custom types (enums, composites)
--   FOR r IN
--     SELECT c.relname FROM pg_class c
--       JOIN pg_namespace n ON n.oid = c.relnamespace
--      WHERE n.nspname = 'public' AND c.relkind = 'S'
--        AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                         WHERE d.objid = c.oid AND d.deptype = 'e')
--   LOOP
--     EXECUTE format('DROP SEQUENCE IF EXISTS public.%I CASCADE', r.relname);
--   END LOOP;
--
--   FOR r IN
--     SELECT t.typname FROM pg_type t
--       JOIN pg_namespace n ON n.oid = t.typnamespace
--      WHERE n.nspname = 'public'
--        AND t.typtype IN ('e','c','d')
--        AND NOT EXISTS (SELECT 1 FROM pg_class c
--                         WHERE c.oid = t.typrelid AND c.relkind <> 'c')
--        AND NOT EXISTS (SELECT 1 FROM pg_depend d
--                         WHERE d.objid = t.oid AND d.deptype = 'e')
--   LOOP
--     EXECUTE format('DROP TYPE IF EXISTS public.%I CASCADE', r.typname);
--   END LOOP;
--
--   RAISE NOTICE 'reset complete';
-- END $reset$;


-- ---------------------------------------------------------------------------
-- 3) VERIFY — after the drop, section 1 should return no rows (or only
--    extension-owned leftovers). Then run complete_setup.sql to rebuild.
-- ---------------------------------------------------------------------------
SELECT count(*) FILTER (WHERE schemaname = 'public') AS public_tables_left
  FROM pg_tables;
