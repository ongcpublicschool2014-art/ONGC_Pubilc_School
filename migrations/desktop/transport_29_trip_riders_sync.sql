-- transport_29_trip_riders_sync.sql
--
-- 1. is_extra on a trip's riders (tr_trip_student, tr_trip_staff_rider): a
--    rider added to the trip in the Riders window (Add Student / Add Staff,
--    trip_board_save), e.g. one who missed their own vehicle and took
--    another of the route. The trip keeps them whatever the allotment says.
--
-- 2. The trips already made for today or later, still Scheduled, brought in
--    line with the riders rule of transport_core.fn_sync_trip_riders
--    (transport_05): a rider allotted to no vehicle (Vehicle Allotment) rides
--    only when the route has one vehicle that way on the day. Until now such a
--    rider was put on every trip of the route that way: on both drop trips of
--    a route with two vehicles, and counted on each. Riders someone marked,
--    and riders added, stay as they are. From now on the trips follow every
--    enrollment and allotment change by themselves
--    (transport_core._route_trips_sync).
--
-- Safe to run again: a column already there is skipped, and a trip already in
-- line is not changed.
BEGIN;

DO $$
DECLARE s text; t bigint; n integer := 0;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{8}$' ORDER BY nspname LOOP
    CONTINUE WHEN to_regclass(format('%I.tr_trip', s)) IS NULL;
    IF to_regclass(format('%I.tr_trip_student', s)) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %I.tr_trip_student ADD COLUMN IF NOT EXISTS is_extra BOOLEAN NOT NULL DEFAULT false', s);
    END IF;
    IF to_regclass(format('%I.tr_trip_staff_rider', s)) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE %I.tr_trip_staff_rider ADD COLUMN IF NOT EXISTS is_extra BOOLEAN NOT NULL DEFAULT false', s);
    END IF;
  END LOOP;

  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{8}$' ORDER BY nspname LOOP
    CONTINUE WHEN to_regclass(format('%I.tr_trip', s)) IS NULL;
    FOR t IN EXECUTE format('SELECT trip_id FROM %I.tr_trip
                              WHERE status = ''SCHEDULED'' AND trip_date >= transport_core._today() ORDER BY trip_id', s) LOOP
      n := n + transport_core.fn_sync_trip_riders(s, t);
    END LOOP;
  END LOOP;
  RAISE NOTICE 'Trip riders brought in line: % change(s).', n;
END $$;

COMMIT;
