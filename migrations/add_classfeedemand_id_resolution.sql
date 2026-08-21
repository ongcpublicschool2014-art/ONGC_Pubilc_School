-- ============================================================================
-- classfeedemand: auto-resolve cla_id / sem_id / fee_id from the names.
-- ============================================================================
-- classfeedemand stores cfclass / cfterm / cffeetype as NAMES, plus id columns
-- cla_id / sem_id / fee_id. Master Import fills the ids from the file, but the
-- Fee Master "Class Fee Demand" save never set them (and there is no trigger),
-- so rows saved from that screen had NULL ids. This adds a BEFORE INSERT/UPDATE
-- trigger that resolves each id from its name (schema-qualified, so it works
-- regardless of the caller's search_path — e.g. the session-gated save RPC), and
-- backfills existing NULL rows. Idempotent. Runs for every institution schema.
-- ============================================================================
DO $do$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT table_schema FROM information_schema.tables
     WHERE table_name = 'classfeedemand'
       AND table_schema NOT IN ('public','pg_catalog','information_schema','extensions')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    -- 1) Backfill existing rows whose ids are NULL/0.
    EXECUTE format('UPDATE %I.classfeedemand cf SET cla_id = c.cla_id FROM %I.class c '
      'WHERE (cf.cla_id IS NULL OR cf.cla_id = 0) AND c.claname = cf.cfclass AND c.activestatus = 1', s, s);
    EXECUTE format('UPDATE %I.classfeedemand cf SET sem_id = se.sem_id FROM %I.semester se '
      'WHERE (cf.sem_id IS NULL OR cf.sem_id = 0) AND se.semname = cf.cfterm AND se.activestatus = 1', s, s);
    EXECUTE format('UPDATE %I.classfeedemand cf SET fee_id = ft.fee_id FROM %I.feetype ft '
      'WHERE (cf.fee_id IS NULL OR cf.fee_id = 0) AND ft.feedesc = cf.cffeetype AND ft.activestatus = 1', s, s);

    -- 2) Resolution trigger for future inserts/updates.
    EXECUTE format('CREATE OR REPLACE FUNCTION %I.set_classfee_ids() RETURNS trigger '
      'LANGUAGE plpgsql AS $t$ BEGIN '
      'IF (NEW.cla_id IS NULL OR NEW.cla_id = 0) AND NEW.cfclass IS NOT NULL THEN '
      '  SELECT cla_id INTO NEW.cla_id FROM %I.class WHERE claname = NEW.cfclass AND activestatus = 1 LIMIT 1; END IF; '
      'IF (NEW.sem_id IS NULL OR NEW.sem_id = 0) AND NEW.cfterm IS NOT NULL THEN '
      '  SELECT sem_id INTO NEW.sem_id FROM %I.semester WHERE semname = NEW.cfterm AND activestatus = 1 LIMIT 1; END IF; '
      'IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.cffeetype IS NOT NULL THEN '
      '  SELECT fee_id INTO NEW.fee_id FROM %I.feetype WHERE feedesc = NEW.cffeetype AND activestatus = 1 LIMIT 1; END IF; '
      'RETURN NEW; END; $t$', s, s, s, s);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_classfeedemand_ids ON %I.classfeedemand', s);
    EXECUTE format('CREATE TRIGGER trg_classfeedemand_ids BEFORE INSERT OR UPDATE ON %I.classfeedemand '
      'FOR EACH ROW EXECUTE FUNCTION %I.set_classfee_ids()', s, s);
    RAISE NOTICE 'classfeedemand id-resolution installed for %', s;
  END LOOP;
END $do$;

NOTIFY pgrst, 'reload schema';
