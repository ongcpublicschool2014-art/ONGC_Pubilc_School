-- =====================================================================
--  SCHOOL TRANSPORT - reorganise the schemas (one-time)
--
--  After this file:
--    public          the masters, shared by every year:
--                      tr_settings, tr_route, tr_stage, tr_stop, tr_vendor,
--                      tr_vehicle, tr_vehicle_document, tr_vehicle_gps_device,
--                      tr_vehicle_service, tr_staff, tr_staff_document
--    transport20262027   the 2026-2027 data: tr_stage_fee, tr_gps_device,
--                      tr_fuel_log, tr_staff_leave, schedules, duty,
--                      enrolment, trips, GPS, notifications, and the views.
--                      Later years get transport20272028, ... (see file 05).
--    transport_core  the code: every transport function, so it is not copied
--                      into each year and survives an old year being dropped.
--
--  What it does: moves the masters to public, moves the two shared helper
--  functions (fn_set_updated_at, fn_distance_m) to transport_core, drops the
--  other old functions (05 and 02 create them again in transport_core), and
--  renames "transport" to "transport20262027" (an older run named it
--  "transport2627": that is renamed too).
--
--  ORDER: this file, then transport_05_year_schemas.sql, then
--  transport_02_phase1_api.sql. Run the three back to back: in between, the
--  Transport screens show "does not exist" errors. Safe to run again: every
--  step is skipped once done (also after an earlier version of this file).
--
--  What moves with each table, unchanged: rows, indexes, unique / check
--  constraints, identity sequences, triggers, the RLS flag, and every foreign
--  key in or out. Views keep working (they point at the tables themselves).
--
--  Access does not change: the masters get RLS and no grants to anon /
--  authenticated, so PostgREST cannot serve them; transport20262027 and
--  transport_core are closed schemas. The app goes through public.tr_* only.
-- =====================================================================

BEGIN;

DO $$
DECLARE
  tbls text[] := ARRAY['tr_settings','tr_route','tr_stage','tr_stop','tr_vendor','tr_vehicle',
                       'tr_vehicle_document','tr_vehicle_gps_device','tr_vehicle_service',
                       'tr_staff','tr_staff_document'];
  src text; t text; rel regclass; clash text; f record; old text; yr int; tgt text;
BEGIN
  -- Year schemas were transport<yy><yy> (transport2627) until 2026-11-20 and
  -- are now transport<yyyy><yyyy> (transport20262027), like the school app's
  -- ongc20262027. Rename an old one first.
  FOR old IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{4}$' ORDER BY nspname LOOP
    yr := 2000 + substr(old, 10, 2)::int;
    tgt := 'transport' || yr || (yr + (substr(old, 12, 2)::int - substr(old, 10, 2)::int + 100) % 100);
    IF to_regnamespace(tgt) IS NOT NULL THEN
      RAISE EXCEPTION 'Both schemas "%" and "%" exist. Merge or drop one by hand first; nothing was changed.', old, tgt;
    END IF;
    EXECUTE format('ALTER SCHEMA %I RENAME TO %I', old, tgt);
  END LOOP;

  -- Where the transport objects are now: before or after an earlier run.
  IF to_regnamespace('transport') IS NOT NULL AND to_regnamespace('transport20262027') IS NOT NULL THEN
    RAISE EXCEPTION 'Both schemas "transport" and "transport20262027" exist. Merge or drop one by hand first; nothing was changed.';
  ELSIF to_regnamespace('transport') IS NOT NULL THEN
    src := 'transport';
  ELSIF to_regnamespace('transport20262027') IS NOT NULL THEN
    src := 'transport20262027';
  ELSE
    RAISE EXCEPTION 'Schema "transport" not found. Run transport_01_schema.sql first.';
  END IF;

  -- 1a. Check every master first, so a name clash stops the run before any move.
  FOREACH t IN ARRAY tbls LOOP
    rel := to_regclass(format('%I.%I', src, t));
    IF rel IS NULL THEN
      IF to_regclass(format('public.%I', t)) IS NULL THEN
        RAISE EXCEPTION 'Neither %.% nor public.% exists.', src, t, t;
      END IF;
      CONTINUE;  -- already moved by an earlier run
    END IF;
    -- the table, its indexes and its identity sequences all take public names
    SELECT n.relname INTO clash
      FROM (SELECT c.relname FROM pg_class c WHERE c.oid = rel
            UNION ALL
            SELECT i.relname FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid WHERE x.indrelid = rel
            UNION ALL
            SELECT s.relname FROM pg_depend d JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
             WHERE d.refobjid = rel AND d.classid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')) n
     WHERE to_regclass(format('public.%I', n.relname)) IS NOT NULL
     LIMIT 1;
    IF clash IS NOT NULL THEN
      RAISE EXCEPTION 'Cannot move %.%: public already has a table, index or sequence named "%". Nothing was changed.', src, t, clash;
    END IF;
  END LOOP;

  -- 1b. Move the masters, then lock them the same way as before.
  FOREACH t IN ARRAY tbls LOOP
    IF to_regclass(format('%I.%I', src, t)) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %I.%I SET SCHEMA public', src, t);
    END IF;
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon, authenticated', t);
  END LOOP;

  -- 2. Code out of the data schema. The updated_at trigger function and the
  --    distance helper are moved (triggers keep pointing at them); the rest
  --    are dropped and created again by files 05 and 02.
  CREATE SCHEMA IF NOT EXISTS transport_core;
  REVOKE ALL ON SCHEMA transport_core FROM PUBLIC, anon, authenticated;
  FOR f IN SELECT p.proname, p.proargtypes, pg_get_function_identity_arguments(p.oid) AS args
             FROM pg_proc p WHERE p.pronamespace = to_regnamespace(src) LOOP
    IF f.proname IN ('fn_set_updated_at', 'fn_distance_m') THEN
      -- moved unless transport_core already has it (same name and argument types)
      IF NOT EXISTS (SELECT 1 FROM pg_proc q
                      WHERE q.pronamespace = 'transport_core'::regnamespace
                        AND q.proname = f.proname AND q.proargtypes = f.proargtypes) THEN
        EXECUTE format('ALTER FUNCTION %I.%I(%s) SET SCHEMA transport_core', src, f.proname, f.args);
      END IF;
    ELSE
      EXECUTE format('DROP FUNCTION %I.%I(%s)', src, f.proname, f.args);
    END IF;
  END LOOP;

  -- 3. The data schema becomes the 2026-2027 year schema.
  IF src = 'transport' THEN
    ALTER SCHEMA transport RENAME TO transport20262027;
  END IF;
  REVOKE ALL ON SCHEMA transport20262027 FROM PUBLIC, anon, authenticated;
END $$;

COMMIT;

-- Next: transport_05_year_schemas.sql, then transport_02_phase1_api.sql.
