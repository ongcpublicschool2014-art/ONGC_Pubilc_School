-- Fix: KCSAM (ins_id=3) data unreachable — schema not served by PostgREST.
-- The schema is derived from inshortname 'kas', so it is **kas20262027**
-- (NOT kcsam20262027).
--
-- STATUS: the schema has ALREADY been added to the exposed list via the app's
-- public.expose_schema() RPC (the "Invalid schema" error became a "table not
-- in schema cache" error, which means it is now exposed). All that remains is
-- to reload PostgREST's table cache — one line, run in the Supabase SQL Editor:

NOTIFY pgrst, 'reload schema';

-- After running the line above, KCSAM should load immediately (no app restart
-- needed). If it still fails, run the two verification queries below.

-- ── verify (optional) ──────────────────────────────────────────────────────

-- (a) Confirm kas20262027 exists and lists its tables:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'kas20262027' ORDER BY 1;

-- (b) Confirm it's in PostgREST's exposed list (look inside rolconfig for
--     pgrst.db_schemas — it should contain public, kcet20262027, kp20262027,
--     kas20262027):
--   SELECT rolconfig FROM pg_roles WHERE rolname = 'authenticator';

-- If (a) returns nothing, the schema was never provisioned — run create_setup /
-- create_institution_schema for ins_id=3, then run NOTIFY pgrst, 'reload schema';
-- If kas20262027 is missing from (b), re-expose everything:
--   SELECT public.expose_all_schemas();
--   NOTIFY pgrst, 'reload schema';
