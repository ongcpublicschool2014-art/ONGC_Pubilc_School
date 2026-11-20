-- transport_15_enrollment_drop_fee_snapshot.sql
--
-- Removes the per-student fee snapshot from tr_student_enrollment in every
-- year schema: stage_fee_id, fee_amount and concession_amount. Nothing in the
-- app or the API read or wrote them; the stage a student pays for stays in
-- fee_stage_id, and the fee for each stage stays in tr_stage_fee.
--
-- Their only user was the report view v_fee_demand. It reads the columns, so
-- it is dropped first and made again without them: the stage-wise count of
-- active students (no gross_fee / concession / net_fee). It is locked like
-- every year-schema view (transport_02): no grants to the app roles.
--
-- New years copy the latest year's tables and views, so they never get the
-- columns back. Safe to run again: a schema without the columns is skipped.
BEGIN;

DO $$
DECLARE s text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{8}$' ORDER BY nspname LOOP
    CONTINUE WHEN NOT EXISTS (
      SELECT 1 FROM information_schema.columns
       WHERE table_schema = s AND table_name = 'tr_student_enrollment'
         AND column_name IN ('stage_fee_id', 'fee_amount', 'concession_amount'));

    EXECUTE format('DROP VIEW IF EXISTS %I.v_fee_demand', s);

    EXECUTE format('ALTER TABLE %I.tr_student_enrollment
                      DROP COLUMN IF EXISTS stage_fee_id,
                      DROP COLUMN IF EXISTS fee_amount,
                      DROP COLUMN IF EXISTS concession_amount', s);

    -- stage-wise count of active students, for accounts
    EXECUTE format($v$CREATE VIEW %1$I.v_fee_demand AS
      SELECT e.inst_id, e.acad_year_id, r.route_code, sg.stage_no, sg.stage_name,
             count(*) AS students
        FROM %1$I.tr_student_enrollment e
        JOIN public.tr_route r  ON r.route_id  = e.route_id
        JOIN public.tr_stage sg ON sg.stage_id = e.fee_stage_id
       WHERE e.status = 'ACTIVE'
       GROUP BY e.inst_id, e.acad_year_id, r.route_code, sg.stage_no, sg.stage_name$v$, s);
    EXECUTE format('REVOKE ALL ON TABLE %I.v_fee_demand FROM PUBLIC, anon, authenticated', s);
  END LOOP;
END $$;

COMMIT;
