-- transport_22_audit_columns.sql
--
-- Who made and who last changed a record, and when, on the transport tables
-- that lacked it:
--   public               tr_settings                created_by
--                        tr_gps_device, tr_vehicle_document,
--                        tr_vehicle_service, tr_staff_document
--                                                   updated_at, updated_by
--   every year schema    tr_stage_fee, tr_fuel_log, tr_duty_assignment,
--   (transport20262027, ...) tr_student_trip_exception  updated_at, updated_by
--                        tr_staff_leave, tr_notify_contact
--                                                   created_by, updated_at, updated_by
--                        tr_trip                    created_by, updated_by (it has updated_at)
--
-- created_by and updated_by are the user (institutionusers.use_id) the API
-- takes from the session (file 02); like the other transport tables, they
-- have no foreign key. updated_at is kept by a trigger, trg_<table>_upd
-- (transport_core.fn_set_updated_at), as on the tables that had it. A new
-- updated_at starts as the row's created_at, so a record never changed shows
-- when it was made. New years copy the latest year's tables and triggers.
--
-- Safe to run again: a column that is there is left as it is.
BEGIN;

DO $$
DECLARE r record; s text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      -- table,                      in each year, add created_by, updated_at, updated_by
      ('tr_settings',               false, true,  false, false),
      ('tr_gps_device',             false, false, true,  true),
      ('tr_vehicle_document',       false, false, true,  true),
      ('tr_vehicle_service',        false, false, true,  true),
      ('tr_staff_document',         false, false, true,  true),
      ('tr_stage_fee',              true,  false, true,  true),
      ('tr_fuel_log',               true,  false, true,  true),
      ('tr_duty_assignment',        true,  false, true,  true),
      ('tr_student_trip_exception', true,  false, true,  true),
      ('tr_staff_leave',            true,  true,  true,  true),
      ('tr_notify_contact',         true,  true,  true,  true),
      ('tr_trip',                   true,  true,  false, true)
    ) x(tbl, yearly, add_created_by, add_updated_at, add_updated_by)
  LOOP
    FOR s IN SELECT n.nspname FROM pg_namespace n
              WHERE (r.yearly AND n.nspname ~ '^transport\d{8}$') OR (NOT r.yearly AND n.nspname = 'public')
              ORDER BY n.nspname LOOP
      CONTINUE WHEN to_regclass(format('%I.%I', s, r.tbl)) IS NULL;
      IF r.add_created_by THEN
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS created_by BIGINT', s, r.tbl);
      END IF;
      IF r.add_updated_at THEN
        IF NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = format('%I.%I', s, r.tbl)::regclass AND a.attname = 'updated_at' AND NOT a.attisdropped) THEN
          EXECUTE format('ALTER TABLE %I.%I ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT now()', s, r.tbl);
          -- before the trigger below exists, so it is not set to now() again
          EXECUTE format('UPDATE %I.%I SET updated_at = created_at', s, r.tbl);
        END IF;
        EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION transport_core.fn_set_updated_at()',
                       'trg_' || r.tbl || '_upd', s, r.tbl);
      END IF;
      IF r.add_updated_by THEN
        EXECUTE format('ALTER TABLE %I.%I ADD COLUMN IF NOT EXISTS updated_by BIGINT', s, r.tbl);
      END IF;
    END LOOP;
  END LOOP;
END $$;

COMMIT;
