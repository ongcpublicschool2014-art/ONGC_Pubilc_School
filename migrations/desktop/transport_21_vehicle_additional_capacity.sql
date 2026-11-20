-- transport_21_vehicle_additional_capacity.sql
--
-- tr_vehicle.additional_capacity: how many students more than its seats a
-- vehicle may take, for small children (e.g. three small children on a
-- two-seat bench: 1 more). 0 by default, never negative; the API keeps it
-- no more than the seating capacity (file 02).
--
-- A vehicle's capacity for allotting students is now
-- seating_capacity + additional_capacity: in the Vehicle Allotment screen
-- and its save (transport_core._allotment_save, file 02), and in the report
-- view v_schedule_occupancy of every year schema, made again here with
-- seats_free and occupancy_pct from that capacity and two new columns at
-- the end (additional_capacity, capacity). New years copy the view.
--
-- Safe to run again.
BEGIN;

ALTER TABLE public.tr_vehicle
  ADD COLUMN IF NOT EXISTS additional_capacity SMALLINT NOT NULL DEFAULT 0
    CONSTRAINT ck_vehicle_additional CHECK (additional_capacity >= 0);

DO $$
DECLARE s text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{8}$' ORDER BY nspname LOOP
    CONTINUE WHEN to_regclass(format('%I.v_schedule_occupancy', s)) IS NULL;
    -- each schedule's students against its vehicle's capacity (a student
    -- with no vehicle yet counts on every trip of the route that way)
    EXECUTE format($v$CREATE OR REPLACE VIEW %1$I.v_schedule_occupancy AS
      SELECT s.inst_id, s.schedule_id, s.schedule_code, s.direction, r.route_code,
             v.vehicle_code, v.seating_capacity,
             count(e.enrollment_id) AS enrolled,
             v.seating_capacity + v.additional_capacity - count(e.enrollment_id) AS seats_free,
             ROUND(100.0 * count(e.enrollment_id) / NULLIF(v.seating_capacity + v.additional_capacity, 0), 1) AS occupancy_pct,
             v.additional_capacity,
             v.seating_capacity + v.additional_capacity AS capacity
        FROM %1$I.tr_trip_schedule s
        JOIN public.tr_route   r ON r.route_id   = s.route_id
        JOIN public.tr_vehicle v ON v.vehicle_id = s.vehicle_id
        LEFT JOIN %1$I.tr_student_enrollment e
               ON e.route_id = s.route_id AND e.status = 'ACTIVE'
              AND e.service_type IN ('BOTH', s.direction)
              AND COALESCE(CASE WHEN s.direction = 'PICKUP' THEN e.pickup_schedule_id
                                ELSE e.drop_schedule_id END, s.schedule_id) = s.schedule_id
       WHERE s.is_active
       GROUP BY s.inst_id, s.schedule_id, s.schedule_code, s.direction, r.route_code,
                v.vehicle_code, v.seating_capacity, v.additional_capacity$v$, s);
    EXECUTE format('REVOKE ALL ON TABLE %I.v_schedule_occupancy FROM PUBLIC, anon, authenticated', s);
  END LOOP;
END $$;

COMMIT;
