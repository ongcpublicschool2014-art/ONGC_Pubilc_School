-- transport_18_stage_fee_demand.sql
--
-- tr_stage_fee_demand, in every year schema: what the Stage Fee Process
-- (Stage Fees screen -> Process Fees, transport_core.stage_fee_process)
-- wrote into the school app's fee demands. One row per fee demand
-- (feedemand.dem_id) the process made or updated, with the term (sem_id),
-- the fee type (fee_id), the route and the stage fee it came from, and the
-- amount billed. A route is shown as processed for a term and fee type when
-- it has rows here.
--
--   dem_id has no foreign key: feedemand belongs to the fee screens, and a
--   key would stop them from removing a demand.
--   stage_fee_id has one: a stage fee that has been billed cannot be removed
--   (transport_core._stage_fee_save and remove say so first, by name).
--
-- The terms are the school app's semesters of the same year
-- (transport_core._app_year_schema), as for tr_stage_fee (transport_16).
--
-- Safe to run again: a year schema that has the table is skipped.
BEGIN;

DO $$
DECLARE s text; v_app text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname ~ '^transport\d{8}$' ORDER BY nspname LOOP
    CONTINUE WHEN to_regclass(format('%I.tr_stage_fee_demand', s)) IS NOT NULL;
    v_app := transport_core._app_year_schema(s);

    EXECUTE format($t$CREATE TABLE %1$I.tr_stage_fee_demand (
      stage_fee_demand_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      sem_id        SMALLINT      NOT NULL REFERENCES %2$I.semester(sem_id),            -- the term
      fee_id        INTEGER       NOT NULL REFERENCES public.feetype(fee_id),           -- the fee type
      route_id      BIGINT        NOT NULL REFERENCES public.tr_route(route_id),
      stage_fee_id  BIGINT        NOT NULL REFERENCES %1$I.tr_stage_fee(stage_fee_id),  -- the fee billed
      dem_id        BIGINT        NOT NULL,  -- the school app's fee demand of the year (feedemand)
      amount        NUMERIC(10,2) NOT NULL,
      processed_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
      processed_by  BIGINT,
      CONSTRAINT uq_stage_fee_demand UNIQUE (dem_id)
    )$t$, s, v_app);
    EXECUTE format('CREATE INDEX ix_stage_fee_demand_route ON %I.tr_stage_fee_demand (route_id, sem_id, fee_id)', s);
    EXECUTE format('CREATE INDEX ix_stage_fee_demand_fee ON %I.tr_stage_fee_demand (stage_fee_id)', s);

    -- closed like every year table (transport_02)
    EXECUTE format('ALTER TABLE %I.tr_stage_fee_demand ENABLE ROW LEVEL SECURITY', s);
    EXECUTE format('REVOKE ALL ON TABLE %I.tr_stage_fee_demand FROM PUBLIC, anon, authenticated', s);
  END LOOP;
END $$;

COMMIT;
