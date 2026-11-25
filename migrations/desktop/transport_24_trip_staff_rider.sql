-- transport_24_trip_staff_rider.sql
--
-- tr_trip_staff_rider, in every year schema that has staff enrollments
-- (transport_23): the staff a day's trip expects, made with the trip by
-- transport_core.fn_generate_trips from tr_staff_enrollment, the same way as
-- the students (tr_trip_student): the route, the trip's way (Both or that
-- direction), the dates, and the vehicle allotted (Vehicle Allotment).
-- Not the crew: drivers and attenders are tr_trip_staff.
--
-- Safe to run again: a year schema that has the table is skipped.
BEGIN;

DO $$
DECLARE s text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{8}$' ORDER BY nspname LOOP
    CONTINUE WHEN to_regclass(format('%I.tr_trip_staff_rider', s)) IS NOT NULL
               OR to_regclass(format('%I.tr_staff_enrollment', s)) IS NULL;

    EXECUTE format($t$CREATE TABLE %1$I.tr_trip_staff_rider (
      trip_id       BIGINT       NOT NULL REFERENCES %1$I.tr_trip(trip_id) ON DELETE CASCADE,
      enrollment_id BIGINT       NOT NULL REFERENCES %1$I.tr_staff_enrollment(enrollment_id),
      staf_id       NUMERIC(8,0) NOT NULL,  -- the school app's staff of the year (staffmast)
      stop_id       BIGINT       NOT NULL REFERENCES public.tr_stop(stop_id),
      status        VARCHAR(12)  NOT NULL DEFAULT 'EXPECTED'
                    CHECK (status IN ('EXPECTED','BOARDED','ALIGHTED','ABSENT','NO_SHOW')),
      boarded_at    TIMESTAMPTZ,
      alighted_at   TIMESTAMPTZ,
      marked_by     BIGINT,
      mark_method   VARCHAR(10)  CHECK (mark_method IN ('MANUAL','RFID','QR','FACE')),
      CONSTRAINT tr_trip_staff_rider_pkey PRIMARY KEY (trip_id, enrollment_id)
    )$t$, s);

    -- closed like every year table (transport_02)
    EXECUTE format('ALTER TABLE %I.tr_trip_staff_rider ENABLE ROW LEVEL SECURITY', s);
    EXECUTE format('REVOKE ALL ON TABLE %I.tr_trip_staff_rider FROM PUBLIC, anon, authenticated', s);
  END LOOP;
END $$;

COMMIT;
