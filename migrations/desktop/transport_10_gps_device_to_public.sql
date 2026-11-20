-- =====================================================================
--  SCHOOL TRANSPORT - GPS devices become a master, in public
--
--  tr_gps_device was a year record (transport20262027), yet the vehicles in
--  public point at it: tr_vehicle.gps_device_id (file 06) and
--  tr_vehicle_gps_device.device_id. From 2027-2028 a vehicle could not have
--  been linked to a device of the new year. A tracker stays with its bus
--  from year to year, so the device list now lives in public with the
--  vehicles, shared by every year.
--
--  What moves with the table, unchanged: rows, the identity sequence (IDs
--  carry on), the IMEI rule (uq_gps_imei), the device type check,
--  created_by (file 08), the RLS flag, and both foreign keys from the
--  vehicles. Years started later get no copy (transport_05 copies the year
--  tables only).
--
--  A year schema started before this change has its own copy. An empty copy
--  is dropped; a copy with devices stops the run, so nothing is changed.
--
--  Runs after files 06 and 08, which still add the vehicle link and
--  created_by to the year table on a new install. Safe to run again: once
--  the table is in public it only checks.
-- =====================================================================

BEGIN;

DO $$
DECLARE src text; s record; cnt bigint; clash text; rel regclass;
BEGIN
  -- 1. Move the copy the vehicles point at (the first run only).
  IF to_regclass('public.tr_gps_device') IS NULL THEN
    SELECT ns.nspname INTO src
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.confrelid
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE k.conrelid = 'public.tr_vehicle_gps_device'::regclass AND k.contype = 'f' AND c.relname = 'tr_gps_device';
    IF src IS NULL THEN  -- no link to follow: the first year that has the table
      SELECT ns.nspname INTO src FROM pg_namespace ns
       WHERE ns.nspname ~ '^transport\d{8}$' AND to_regclass(format('%I.tr_gps_device', ns.nspname)) IS NOT NULL
       ORDER BY ns.nspname LIMIT 1;
    END IF;
    IF src IS NULL THEN
      RAISE EXCEPTION 'tr_gps_device is in neither public nor a year schema. Run the files before this one first.';
    END IF;

    -- the table, its indexes and its identity sequence all take public names
    rel := format('%I.tr_gps_device', src)::regclass;
    SELECT x.relname INTO clash
      FROM (SELECT c.relname FROM pg_class c WHERE c.oid = rel
            UNION ALL
            SELECT i.relname FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid WHERE ix.indrelid = rel
            UNION ALL
            SELECT q.relname FROM pg_depend d JOIN pg_class q ON q.oid = d.objid AND q.relkind = 'S'
             WHERE d.refobjid = rel AND d.classid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')) x
     WHERE to_regclass(format('public.%I', x.relname)) IS NOT NULL
     LIMIT 1;
    IF clash IS NOT NULL THEN
      RAISE EXCEPTION 'Cannot move %.tr_gps_device: public already has a table, index or sequence named "%". Nothing was changed.', src, clash;
    END IF;

    EXECUTE format('ALTER TABLE %I.tr_gps_device SET SCHEMA public', src);
  END IF;

  -- 2. Copies left in other year schemas: an empty one is dropped, one with
  --    devices stops the run.
  FOR s IN SELECT ns.nspname FROM pg_namespace ns
            WHERE ns.nspname ~ '^transport\d{8}$' AND to_regclass(format('%I.tr_gps_device', ns.nspname)) IS NOT NULL
            ORDER BY ns.nspname LOOP
    EXECUTE format('SELECT count(*) FROM %I.tr_gps_device', s.nspname) INTO cnt;
    IF cnt > 0 THEN
      RAISE EXCEPTION '%.tr_gps_device has % GPS device(s) of its own. Copy them into public.tr_gps_device and empty it by hand first; nothing was changed.',
        s.nspname, cnt;
    END IF;
    EXECUTE format('DROP TABLE %I.tr_gps_device', s.nspname);
  END LOOP;

  -- 3. Locked like every master: RLS on, no grants to the app roles.
  ALTER TABLE public.tr_gps_device ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON TABLE public.tr_gps_device FROM PUBLIC, anon, authenticated;
END $$;

COMMIT;
