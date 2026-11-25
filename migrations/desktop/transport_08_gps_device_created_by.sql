-- =====================================================================
--  SCHOOL TRANSPORT - tr_gps_device.created_by
--
--  The Vehicles screen now adds GPS devices through tr_save, which records
--  who created each row. tr_gps_device was the one table without that
--  column. Added to every year schema that has the table; later years copy
--  it (transport_05 uses LIKE ... INCLUDING ALL).
--
--  Run before re-applying transport_02_phase1_api.sql. Safe to run again.
-- =====================================================================

BEGIN;

DO $$
DECLARE s text;
BEGIN
  FOR s IN SELECT n.nspname FROM pg_namespace n
            WHERE n.nspname ~ '^transport[0-9]{8}$'
              AND to_regclass(format('%I.tr_gps_device', n.nspname)) IS NOT NULL LOOP
    EXECUTE format('ALTER TABLE %I.tr_gps_device ADD COLUMN IF NOT EXISTS created_by BIGINT NULL', s);
  END LOOP;
END $$;

COMMIT;
