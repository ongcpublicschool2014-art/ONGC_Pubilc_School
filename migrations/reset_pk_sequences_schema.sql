-- Reset the PRIMARY KEY sequence of every table in ONE TENANT SCHEMA to max(pk).
--
--   >>> EDIT THE SCHEMA NAME ON THE `SET` LINE BELOW — that is the only place. <<<
--       Then run the whole file (STEP 0, 1 and 2 together).
--
-- Run this after a restore, a bulk import, or any load that inserted explicit
-- ids: those leave the sequence behind the data, and the next insert fails with
-- "duplicate key value violates unique constraint".
--
-- Tenant tables get their id from a plain sequence + BEFORE INSERT trigger
-- (students.stu_id, feedemand.dem_id, payment.pay_id, tc_entry.tc_id, ...).
-- Those sequences are NOT owned by their column, so pg_get_serial_sequence
-- can't see them; they're matched by the naming convention
-- <table>_<pkcol>_seq that create_institution_schema uses.
--
-- NOT touched: the business-number sequences in this schema's `sequence` table
-- (DEMNO / REGNO / TCNO / CONNO / REFNO receipt and document numbers). Those are
-- rows, not Postgres sequences, and are bumped by their own RPCs.
--
-- Safe and idempotent: a sequence is only ever moved FORWARD to max(pk). One
-- already ahead of the data is left alone, so a value handed out to an
-- in-flight transaction can't be reissued. Prefer running it with the apps in
-- maintenance mode (docs/MAINTENANCE_MODE.md).
--
-- For public, use reset_pk_sequences_public.sql instead.

-- ---------------------------------------------------------------------------
-- STEP 0 — the schema to fix. THIS IS THE ONLY LINE TO EDIT.
-- ---------------------------------------------------------------------------
SET app.target_schema = 'kch20262027';

-- ---------------------------------------------------------------------------
-- 1) PREVIEW — read-only. needs_reset = true means the sequence lags the data.
--    (Run STEP 0 first; on its own this errors with "unrecognized configuration
--    parameter app.target_schema", which tells you the SET didn't run.)
-- ---------------------------------------------------------------------------
WITH pk AS (
  SELECT n.nspname AS sch, c.relname AS tbl, a.attname AS col
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_constraint k ON k.conrelid = c.oid AND k.contype = 'p'
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.conkey[1]
   WHERE c.relkind = 'r'
     AND n.nspname = current_setting('app.target_schema')::name
     AND array_length(k.conkey, 1) = 1                     -- single-column PK only
     AND a.atttypid IN ('smallint'::regtype, 'integer'::regtype, 'bigint'::regtype)
),
resolved AS (
  SELECT pk.*,
         COALESCE(
           pg_get_serial_sequence(format('%I.%I', sch, tbl), col),
           (SELECT format('%I.%I', sn.nspname, s.relname)
              FROM pg_class s
              JOIN pg_namespace sn ON sn.oid = s.relnamespace
             WHERE s.relkind = 'S' AND sn.nspname = pk.sch
               AND s.relname = pk.tbl || '_' || pk.col || '_seq')
         ) AS seq
    FROM pk
),
measured AS (
  SELECT tbl, col, seq,
         COALESCE((xpath('/row/m/text()',
           query_to_xml(format('SELECT max(%I) AS m FROM %I.%I', col, sch, tbl),
                        false, true, '')))[1]::text::bigint, 0) AS max_id,
         pg_sequence_last_value(seq::regclass) AS seq_value
    FROM resolved
   WHERE seq IS NOT NULL
)
SELECT tbl, col, seq, max_id, seq_value,
       max_id > COALESCE(seq_value, 0) AS needs_reset
  FROM measured
 ORDER BY (max_id > COALESCE(seq_value, 0)) DESC, tbl;      -- lagging first

-- ---------------------------------------------------------------------------
-- 2) APPLY — moves every lagging sequence up to max(pk).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_schema name := current_setting('app.target_schema')::name;
  r        RECORD;
  v_max    bigint;
  v_last   bigint;
  v_fixed  int := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
    RAISE EXCEPTION 'Schema % does not exist', v_schema;
  END IF;

  FOR r IN
    WITH pk AS (
      SELECT n.nspname AS sch, c.relname AS tbl, a.attname AS col
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_constraint k ON k.conrelid = c.oid AND k.contype = 'p'
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.conkey[1]
       WHERE c.relkind = 'r'
         AND n.nspname = v_schema
         AND array_length(k.conkey, 1) = 1
         AND a.atttypid IN ('smallint'::regtype, 'integer'::regtype, 'bigint'::regtype)
    )
    SELECT pk.*,
           COALESCE(
             pg_get_serial_sequence(format('%I.%I', sch, tbl), col),
             (SELECT format('%I.%I', sn.nspname, s.relname)
                FROM pg_class s
                JOIN pg_namespace sn ON sn.oid = s.relnamespace
               WHERE s.relkind = 'S' AND sn.nspname = pk.sch
                 AND s.relname = pk.tbl || '_' || pk.col || '_seq')
           ) AS seq
      FROM pk
     ORDER BY tbl
  LOOP
    CONTINUE WHEN r.seq IS NULL;   -- PK not sequence-backed (composite key, text id, ...)
    BEGIN
      EXECUTE format('SELECT COALESCE(max(%I), 0) FROM %I.%I', r.col, r.sch, r.tbl)
        INTO v_max;
      SELECT pg_sequence_last_value(r.seq::regclass) INTO v_last;
      -- forward only: never hand back a value a live transaction may hold
      IF v_max > COALESCE(v_last, 0) THEN
        PERFORM setval(r.seq::regclass, v_max, true);
        v_fixed := v_fixed + 1;
        RAISE NOTICE '   reset % : %.%.% -> % (was %)',
          r.seq, r.sch, r.tbl, r.col, v_max, COALESCE(v_last::text, 'unused');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '   skip %.%.%: %', r.sch, r.tbl, r.col, SQLERRM;
    END;
  END LOOP;
  RAISE NOTICE '%: % sequence(s) reset.', v_schema, v_fixed;
END $$;
