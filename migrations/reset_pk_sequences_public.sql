-- Reset the PRIMARY KEY sequence of every table in the PUBLIC schema to max(pk).
-- Nothing to edit — just run the whole file.
--
-- Run this after a restore, a bulk import, or any load that inserted explicit
-- ids: those leave the sequence behind the data, and the next insert fails with
-- "duplicate key value violates unique constraint".
--
-- Public tables mostly use identity columns (public.admission.adm_id,
-- public.rollno_change.rc_id, ...), resolved via pg_get_serial_sequence; the
-- <table>_<pkcol>_seq fallback catches any plain sequence driven by a trigger.
--
-- Safe and idempotent: a sequence is only ever moved FORWARD to max(pk). One
-- already ahead of the data is left alone, so a value handed out to an
-- in-flight transaction can't be reissued. Prefer running it with the apps in
-- maintenance mode (docs/MAINTENANCE_MODE.md).
--
-- For a tenant schema, use reset_pk_sequences_schema.sql instead.

-- ---------------------------------------------------------------------------
-- 1) PREVIEW — read-only. needs_reset = true means the sequence lags the data.
-- ---------------------------------------------------------------------------
WITH pk AS (
  SELECT n.nspname AS sch, c.relname AS tbl, a.attname AS col
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_constraint k ON k.conrelid = c.oid AND k.contype = 'p'
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.conkey[1]
   WHERE c.relkind = 'r'
     AND n.nspname = 'public'
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
  r       RECORD;
  v_max   bigint;
  v_last  bigint;
  v_fixed int := 0;
BEGIN
  FOR r IN
    WITH pk AS (
      SELECT n.nspname AS sch, c.relname AS tbl, a.attname AS col
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_constraint k ON k.conrelid = c.oid AND k.contype = 'p'
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.conkey[1]
       WHERE c.relkind = 'r'
         AND n.nspname = 'public'
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
        RAISE NOTICE '   reset % : public.%.% -> % (was %)',
          r.seq, r.tbl, r.col, v_max, COALESCE(v_last::text, 'unused');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '   skip public.%.%: %', r.tbl, r.col, SQLERRM;
    END;
  END LOOP;
  RAISE NOTICE 'public: % sequence(s) reset.', v_fixed;
END $$;
