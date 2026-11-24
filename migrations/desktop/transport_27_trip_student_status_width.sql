-- transport_27_trip_student_status_width.sql
--
-- tr_trip_student.status was VARCHAR(12), one short of its own allowed
-- 'PARENT_PICKUP' (13 letters): a parent pickup could not be saved, neither
-- from a day exception (transport_core.fn_generate_trips) nor from the Daily
-- Trips boarding entry (trip_board_save). Widened to 16 in every year schema;
-- the check of the allowed values stays as it is.
--
-- Safe to run again: a year schema whose column is wide enough is skipped.
BEGIN;

DO $$
DECLARE s text;
BEGIN
  FOR s IN SELECT c.table_schema FROM information_schema.columns c
            WHERE c.table_schema ~ '^transport\d{8}$' AND c.table_name = 'tr_trip_student'
              AND c.column_name = 'status' AND c.character_maximum_length < 16
            ORDER BY 1 LOOP
    EXECUTE format('ALTER TABLE %I.tr_trip_student ALTER COLUMN status TYPE VARCHAR(16)', s);
  END LOOP;
END $$;

COMMIT;
