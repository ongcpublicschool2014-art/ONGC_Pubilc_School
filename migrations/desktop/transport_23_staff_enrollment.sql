-- transport_23_staff_enrollment.sql
--
-- tr_staff_enrollment, in every year schema: which staff travel on a route,
-- and where they get on and off. The same columns, checks, keys and indexes
-- as tr_student_enrollment, with staf_id in place of student_id: the school
-- app's staff of the same year (staffmast, transport_core._app_year_schema),
-- as the stage fees follow its semesters (transport_16). One active
-- enrollment per staff member a year.
--
-- Saved by the Student Enrollment screen's Staff Enrollment tab
-- (transport_core._staff_enrollment_save); listed by tr_list
-- 'staff_enrollment', and the staff who may travel by tr_enrollment_staff
-- (transport_02). A new year gets the table from create_year_schema, with
-- staf_id keyed to that year's staffmast.
--
-- A year schema whose school app year has no staffmast yet is skipped (run
-- this again once it has one); its Staff Enrollment tab says so meanwhile.
--
-- Safe to run again: a year schema that has the table is skipped.
BEGIN;

DO $$
DECLARE s text; v_app text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{8}$' ORDER BY nspname LOOP
    CONTINUE WHEN to_regclass(format('%I.tr_staff_enrollment', s)) IS NOT NULL;
    v_app := transport_core._app_year_schema(s);
    CONTINUE WHEN to_regclass(format('%I.staffmast', v_app)) IS NULL;

    EXECUTE format($t$CREATE TABLE %1$I.tr_staff_enrollment (
      enrollment_id      BIGINT       GENERATED ALWAYS AS IDENTITY,
      inst_id            BIGINT       NOT NULL,
      acad_year_id       BIGINT       NOT NULL,
      staf_id            NUMERIC(8,0) NOT NULL,  -- the school app's staff of the year (staffmast)
      route_id           BIGINT       NOT NULL,
      service_type       VARCHAR(10)  NOT NULL DEFAULT 'BOTH',
      pickup_stop_id     BIGINT,
      drop_stop_id       BIGINT,
      pickup_schedule_id BIGINT,
      drop_schedule_id   BIGINT,
      fee_stage_id       BIGINT       NOT NULL,  -- the stage of the farther stop
      start_date         DATE         NOT NULL,
      end_date           DATE,
      status             VARCHAR(12)  NOT NULL DEFAULT 'ACTIVE',
      rfid_tag           VARCHAR(40),
      cancel_reason      TEXT,
      created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
      created_by         BIGINT,
      updated_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
      updated_by         BIGINT,
      CONSTRAINT tr_staff_enrollment_pkey PRIMARY KEY (enrollment_id),
      CONSTRAINT tr_staff_enrollment_service_type_check CHECK (service_type IN ('BOTH', 'PICKUP', 'DROP')),
      CONSTRAINT tr_staff_enrollment_status_check CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CANCELLED', 'COMPLETED')),
      CONSTRAINT ck_senr_stops CHECK (
           (service_type = 'BOTH'   AND pickup_stop_id IS NOT NULL AND drop_stop_id IS NOT NULL)
        OR (service_type = 'PICKUP' AND pickup_stop_id IS NOT NULL)
        OR (service_type = 'DROP'   AND drop_stop_id IS NOT NULL)),
      CONSTRAINT fk_senr_staff       FOREIGN KEY (staf_id) REFERENCES %2$I.staffmast (staf_id),
      CONSTRAINT fk_senr_stage       FOREIGN KEY (fee_stage_id, route_id) REFERENCES public.tr_stage (stage_id, route_id),
      CONSTRAINT fk_senr_pickup_stop FOREIGN KEY (pickup_stop_id, route_id) REFERENCES public.tr_stop (stop_id, route_id),
      CONSTRAINT fk_senr_drop_stop   FOREIGN KEY (drop_stop_id, route_id) REFERENCES public.tr_stop (stop_id, route_id),
      CONSTRAINT fk_senr_pick_sched  FOREIGN KEY (pickup_schedule_id, route_id) REFERENCES %1$I.tr_trip_schedule (schedule_id, route_id),
      CONSTRAINT fk_senr_drop_sched  FOREIGN KEY (drop_schedule_id, route_id) REFERENCES %1$I.tr_trip_schedule (schedule_id, route_id)
    )$t$, s, v_app);
    EXECUTE format('CREATE UNIQUE INDEX uq_senr_active ON %I.tr_staff_enrollment (staf_id, acad_year_id) WHERE status = ''ACTIVE''', s);
    EXECUTE format('CREATE INDEX ix_senr_pickup_stop ON %I.tr_staff_enrollment (pickup_stop_id) WHERE status = ''ACTIVE''', s);
    EXECUTE format('CREATE INDEX ix_senr_drop_stop ON %I.tr_staff_enrollment (drop_stop_id) WHERE status = ''ACTIVE''', s);
    EXECUTE format('CREATE TRIGGER trg_tr_staff_enrollment_upd BEFORE UPDATE ON %I.tr_staff_enrollment
                      FOR EACH ROW EXECUTE FUNCTION transport_core.fn_set_updated_at()', s);

    -- closed like every year table (transport_02)
    EXECUTE format('ALTER TABLE %I.tr_staff_enrollment ENABLE ROW LEVEL SECURITY', s);
    EXECUTE format('REVOKE ALL ON TABLE %I.tr_staff_enrollment FROM PUBLIC, anon, authenticated', s);
  END LOOP;
END $$;

COMMIT;
