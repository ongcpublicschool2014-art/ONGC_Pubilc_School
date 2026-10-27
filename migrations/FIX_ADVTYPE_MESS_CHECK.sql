-- ############################################################################
--
--   EduCore360 -- THE MESS ADVANCE THAT COULD NOT BE SAVED
--   26-09-2026
--
--   Run the whole file in the SQL editor. Safe on either project.
--
-- ----------------------------------------------------------------------------
-- WHAT IS WRONG
-- ----------------------------------------------------------------------------
-- advance_collection carries TWO check constraints on advtype:
--
--   advance_collection_advtype_check   advtype IN ('A','S')        <-- original
--   chk_advance_advtype                advtype IN ('A','S','M')    <-- added by
--                                      BANK_ROUTING_BY_FEEGROUP.sql
--
-- Postgres requires EVERY check to pass, so the newer one never widened
-- anything: a mess advance fails the original and the insert is rejected.
-- BANK_ROUTING_BY_FEEGROUP.sql should have replaced the original rather than
-- adding a second one beside it. That is the bug this file fixes.
--
-- The cashier saw only "Could not collect the advance. Something went wrong",
-- because a 23514 check violation has no friendly text -- so the screen looked
-- broken while the routing, numbering and settlement were all working.
--
-- ----------------------------------------------------------------------------
-- WHAT IT DOES
-- ----------------------------------------------------------------------------
-- In every schema that has an advance_collection table: drops any check on
-- advtype that does NOT allow 'M', then makes sure one that does is present.
-- Driven by what each constraint actually says, not by name, so a schema that
-- was patched by hand is handled too.
--
-- ----------------------------------------------------------------------------
-- SAFE
-- ----------------------------------------------------------------------------
-- Constraints only: no advance, payment or demand row is read or written. The
-- rule itself does not loosen -- advtype is still limited to A, S and M -- it
-- simply stops being contradicted by an older copy of itself. Re-running finds
-- nothing left to drop.
-- ############################################################################

DO $fix$
DECLARE
  v_schema text;
  v_con    record;
  v_dropped int := 0;
  v_added   int := 0;
BEGIN
  FOR v_schema IN
    SELECT table_schema FROM information_schema.tables
     WHERE table_name = 'advance_collection' AND table_schema NOT IN ('pg_catalog','information_schema')
     ORDER BY table_schema
  LOOP
    -- 1. every check on advtype that forbids a mess advance
    FOR v_con IN
      EXECUTE format($q$
        SELECT c.conname, pg_get_constraintdef(c.oid) AS def
          FROM pg_constraint c
         WHERE c.conrelid = %L::regclass
           AND c.contype = 'c'
           AND pg_get_constraintdef(c.oid) ILIKE '%%advtype%%'
           AND pg_get_constraintdef(c.oid) NOT LIKE '%%''M''%%'
      $q$, v_schema || '.advance_collection')
    LOOP
      EXECUTE format('ALTER TABLE %I.advance_collection DROP CONSTRAINT %I',
                     v_schema, v_con.conname);
      v_dropped := v_dropped + 1;
    END LOOP;

    -- 2. and one that allows A, S and M, if none is left
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
       WHERE c.conrelid = (v_schema || '.advance_collection')::regclass
         AND c.contype = 'c'
         AND pg_get_constraintdef(c.oid) ILIKE '%advtype%'
    ) THEN
      EXECUTE format($q$
        ALTER TABLE %I.advance_collection
          ADD CONSTRAINT chk_advance_advtype
          CHECK (advtype::text = ANY (ARRAY['A'::text,'S'::text,'M'::text]))
      $q$, v_schema);
      v_added := v_added + 1;
    END IF;
  END LOOP;

  RAISE NOTICE 'advtype checks: % dropped, % added', v_dropped, v_added;
END $fix$;


-- ----------------------------------------------------------------------------
-- VERIFY
-- ----------------------------------------------------------------------------
-- One row per schema, and every definition must list 'M'. A row reading
-- ONLY A,S is a schema this file could not reach.
SELECT n.nspname AS schema,
       c.conname,
       pg_get_constraintdef(c.oid) AS definition,
       CASE WHEN pg_get_constraintdef(c.oid) LIKE '%''M''%'
            THEN 'ok - mess advances allowed'
            ELSE 'STILL BLOCKS MESS ADVANCES' END AS state
  FROM pg_constraint c
  JOIN pg_class      t ON t.oid = c.conrelid
  JOIN pg_namespace  n ON n.oid = t.relnamespace
 WHERE t.relname = 'advance_collection'
   AND c.contype = 'c'
   AND pg_get_constraintdef(c.oid) ILIKE '%advtype%'
 ORDER BY 1, 2;
