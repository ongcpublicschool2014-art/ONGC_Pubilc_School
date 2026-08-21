-- ============================================================================
-- Fix: newly-exposed institution schema returns PGRST205
--      "Could not find the table 'xxx.year' in the schema cache".
-- ============================================================================
-- After a new institution is registered, expose_schema/expose_all_schemas add
-- the schema to pgrst.db_schemas and send `NOTIFY pgrst, 'reload config'`, but
-- that alone can leave PostgREST WITHOUT re-introspecting the newly-exposed
-- schema's tables -> "table not in schema cache". Adding a second
-- `NOTIFY pgrst, 'reload schema'` forces the table cache to rebuild.
--
-- Run this in the Supabase SQL editor (needs rights to ALTER ROLE
-- authenticator). It also reloads the cache immediately at the end.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.expose_schema(p_schema text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_list text := 'public';
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL AND iy.activestatus = 1
  LOOP
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = rec.schema_name) THEN
      v_list := v_list || ', ' || rec.schema_name;
    END IF;
  END LOOP;
  IF p_schema IS NOT NULL AND p_schema <> ''
     AND position(lower(p_schema) in v_list) = 0
     AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = lower(p_schema)) THEN
    v_list := v_list || ', ' || lower(p_schema);
  END IF;
  BEGIN
    EXECUTE format('ALTER ROLE authenticator SET pgrst.db_schemas = %L', v_list);
    NOTIFY pgrst, 'reload config';
    NOTIFY pgrst, 'reload schema';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'expose_schema: ALTER ROLE skipped: %', SQLERRM;
  END;
END; $$;

CREATE OR REPLACE FUNCTION public.expose_all_schemas() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  rec RECORD;
  v_list text := 'public';
BEGIN
  FOR rec IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL
      AND iy.activestatus = 1
  LOOP
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = rec.schema_name) THEN
      v_list := v_list || ', ' || rec.schema_name;
    END IF;
  END LOOP;
  BEGIN
    EXECUTE format('ALTER ROLE authenticator SET pgrst.db_schemas = %L', v_list);
    NOTIFY pgrst, 'reload config';
    NOTIFY pgrst, 'reload schema';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'expose_all_schemas: ALTER ROLE skipped (insufficient privilege): %', SQLERRM;
  END;
END; $$;

GRANT EXECUTE ON FUNCTION public.expose_schema(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expose_all_schemas() TO anon, authenticated;

-- Apply now: re-expose everything (incl. the new schema) and reload the cache.
SELECT public.expose_all_schemas();
NOTIFY pgrst, 'reload schema';
