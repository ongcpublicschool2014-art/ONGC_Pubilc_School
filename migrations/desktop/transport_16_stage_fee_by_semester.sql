-- transport_16_stage_fee_by_semester.sql
--
-- tr_stage_fee is dropped and made again in every year schema, in the new
-- structure: the fee of a stage of a route, per semester of the school app's
-- year and fee head (feetype), for both ways or one way.
--
--   gone:  inst_id (the route says the school), acad_year_id (the year schema
--          and the semester say the year), fee_frequency (one fee per
--          semester instead), fee_head_id (now fee_id, required)
--   new:   route_id, fee_id, sem_id, activestatus
--   rule:  one fee per stage, service, semester and start date (uq_stage_fee)
--
-- The semesters are the school app's own table for the same year:
-- institutionyear.iyrschema, e.g. transport20262027 -> ongc20262027.semester
-- (transport_core._app_year_schema). A year started later points at its own
-- year's semesters (create_year_schema).
--
-- The old rows are deleted with the table: they have no semester or fee head
-- to carry over. IDs carry on from the old table. Nothing else points at
-- tr_stage_fee (transport_15 removed tr_student_enrollment.stage_fee_id), so
-- the drop is not CASCADE: anything unexpected stops it, and nothing changes.
--
-- Safe to run again: a year schema whose tr_stage_fee already has sem_id is
-- skipped.
BEGIN;

DO $$
DECLARE s text; v_app text; v_seq text; v_last bigint; v_called boolean := false;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{8}$' ORDER BY nspname LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                           WHERE table_schema = s AND table_name = 'tr_stage_fee' AND column_name = 'sem_id');
    v_app := transport_core._app_year_schema(s);

    v_last := NULL;
    v_seq := CASE WHEN to_regclass(format('%I.tr_stage_fee', s)) IS NOT NULL
                  THEN pg_get_serial_sequence(format('%I.tr_stage_fee', s), 'stage_fee_id') END;
    IF v_seq IS NOT NULL THEN
      EXECUTE format('SELECT last_value, is_called FROM %s', v_seq) INTO v_last, v_called;
    END IF;
    EXECUTE format('DROP TABLE IF EXISTS %I.tr_stage_fee', s);

    EXECUTE format($t$CREATE TABLE %1$I.tr_stage_fee (
      stage_fee_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      route_id        BIGINT        NOT NULL REFERENCES public.tr_route(route_id),
      stage_id        BIGINT        NOT NULL REFERENCES public.tr_stage(stage_id),
      service_type    VARCHAR(10)   NOT NULL DEFAULT 'BOTH'
                      CHECK (service_type IN ('BOTH','PICKUP','DROP')),  -- one-way fee option
      fee_id          INTEGER       NOT NULL REFERENCES public.feetype(fee_id),  -- the fee module's fee head
      sem_id          SMALLINT      NOT NULL REFERENCES %2$I.semester(sem_id),  -- the school app's semester of the year
      amount          NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
      effective_from  DATE          NOT NULL,
      effective_to    DATE,
      activestatus    SMALLINT      NOT NULL DEFAULT 1,
      created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
      created_by      BIGINT,
      CONSTRAINT uq_stage_fee UNIQUE (stage_id, service_type, sem_id, effective_from)
    )$t$, s, v_app);

    IF v_last IS NOT NULL THEN
      PERFORM setval(pg_get_serial_sequence(format('%I.tr_stage_fee', s), 'stage_fee_id'), v_last, v_called);
    END IF;

    -- closed like every year table (transport_02)
    EXECUTE format('ALTER TABLE %I.tr_stage_fee ENABLE ROW LEVEL SECURITY', s);
    EXECUTE format('REVOKE ALL ON TABLE %I.tr_stage_fee FROM PUBLIC, anon, authenticated', s);
  END LOOP;
END $$;

COMMIT;
