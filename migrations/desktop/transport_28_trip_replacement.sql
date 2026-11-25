-- transport_28_trip_replacement.sql
--
-- Replace Trip (Daily Trips): a cancelled trip of today or later (e.g. its
-- bus broke down) run by another vehicle. The replacement is a new trip of
-- the same schedule, day and times, with the cancelled trip's stops, riders
-- and other crew, its own vehicle and driver, and replaces_trip_id the
-- cancelled trip (transport_core.trip_replace).
--
-- So a schedule may now have more than one trip on a day: one original
-- (replaces_trip_id empty: the nightly run's, uq_trip_original) and the
-- replacements, each trip replaced at most once (uq_trip_replaces). The old
-- uq_trip (one trip per schedule and day) goes. The nightly run is not
-- changed: it skips a schedule that has any trip on the day.
--
-- Safe to run again.
BEGIN;

DO $$
DECLARE s text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{8}$' ORDER BY nspname LOOP
    CONTINUE WHEN to_regclass(format('%I.tr_trip', s)) IS NULL;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = s AND table_name = 'tr_trip' AND column_name = 'replaces_trip_id') THEN
      EXECUTE format('ALTER TABLE %1$I.tr_trip ADD COLUMN replaces_trip_id BIGINT REFERENCES %1$I.tr_trip(trip_id)', s);
    END IF;
    EXECUTE format('ALTER TABLE %I.tr_trip DROP CONSTRAINT IF EXISTS uq_trip', s);
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS uq_trip_original ON %I.tr_trip (schedule_id, trip_date) WHERE replaces_trip_id IS NULL', s);
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS uq_trip_replaces ON %I.tr_trip (replaces_trip_id) WHERE replaces_trip_id IS NOT NULL', s);
  END LOOP;
END $$;

COMMIT;
