-- ============================================================================
-- A new fee type gets an ordid automatically.
-- ============================================================================
-- WHAT WAS WRONG. FEETYPE_ORDID.sql added the column and set_feetype_order.sql
-- seeded it, but nothing assigns one to a fee type created AFTERWARDS. A fee
-- type added through Fee Master, or imported from a CSV, lands with ordid
-- NULL -- and a NULL sorts to the end of every fee-type list in Reports with
-- no number anyone can edit to move it.
--
-- WHERE IT IS FIXED. In the BEFORE INSERT trigger feetype already has.
--
-- set_fee_id is attached to feetype in every schema and already fills fee_id
-- the same way. Extending it rather than adding a 24th trigger means:
--   * both insert paths are covered by one rule -- the Fee Master form and
--     process_master_import go through the same INSERT
--   * nothing new has to be added to create_institution_schema's trigger list
--   * nothing new has to be added to tools/restore_test_repair.sql, which
--     puts the triggers back after a pg_restore into TEST strips them
--
-- An ordid supplied explicitly always wins -- the trigger only fills a NULL.
--
-- WHAT THE NUMBER IS. MAX(ordid) + 1 for the institution, so a new fee type
-- lands at the END of the order. That is the only safe default: anywhere else
-- would silently renumber fees the office has already arranged, and the one
-- thing nobody can object to is a new fee appearing last.
--
-- ALSO FIXED HERE. The Fee Type CSV has carried a "FeeType Order" column all
-- along and process_master_import read it into col6 and threw it away -- its
-- own comment said "(unused)". It now writes to ordid, so the column finally
-- means what its heading says, and a blank cell falls through to the trigger.
-- A non-numeric cell is treated as blank rather than failing the whole import.
--
-- NO APP CHANGE. Fee Master does not send ordid, which is exactly what makes
-- the trigger fire. Editing a fee type is an UPDATE, and the trigger is BEFORE
-- INSERT, so an edit cannot wipe an order that has been set.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 0 =
-- Fee types with no order today. These are the ones that would have been
-- numbered had the trigger existed; they stay NULL -- this only prints them.
-- ===========================================================================

SELECT fee_id, feedesc, feeshort, fg_id, ordid
  FROM kcet20262027.feetype
 WHERE activestatus = 1 AND ordid IS NULL
 ORDER BY fee_id;


-- =================================================================== PART 1 =
-- Extend set_fee_id in every schema that has the column.
--
-- Driven off information_schema rather than a list of institutions, so a
-- schema added since FEETYPE_ORDID.sql ran is picked up and one that never
-- got the column is skipped rather than failing.
-- ===========================================================================

DO $do$
DECLARE
  s text;
  n int := 0;
BEGIN
  FOR s IN
    SELECT c.table_schema
      FROM information_schema.columns c
     WHERE c.table_name = 'feetype'
       AND c.column_name = 'ordid'
       AND c.table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
     ORDER BY 1
  LOOP
    -- Non-positional %I throughout, three times, to match how the generator
    -- writes this function -- format() will not mix %I with %1$I.
    EXECUTE format(
      'CREATE OR REPLACE FUNCTION %I.set_fee_id() RETURNS trigger LANGUAGE plpgsql AS $t$ '
      'BEGIN '
      '  IF NEW.fee_id IS NULL OR NEW.fee_id = 0 THEN '
      '    NEW.fee_id := nextval(''%I.feetype_fee_id_seq''); '
      '  END IF; '
      '  IF NEW.ordid IS NULL THEN '
      '    SELECT COALESCE(MAX(ordid), 0) + 1 INTO NEW.ordid '
      '      FROM %I.feetype WHERE ins_id = NEW.ins_id; '
      '  END IF; '
      '  RETURN NEW; '
      'END; $t$', s, s, s);
    n := n + 1;
  END LOOP;

  IF n = 0 THEN
    RAISE EXCEPTION 'No schema has feetype.ordid -- run FEETYPE_ORDID.sql first';
  END IF;
  RAISE NOTICE 'set_fee_id extended in % schema(s)', n;
END
$do$;


-- =================================================================== PART 2 =
-- Same change inside create_institution_schema, so the NEXT institution is
-- born with it instead of needing this script run again.
--
-- Patched by replacing the one line in the stored source, not by rewriting
-- the function -- the generator is 1,500 lines and retyping it is how a
-- generator comes to differ from the schemas it has already made.
-- ===========================================================================

DO $do$
DECLARE
  src     text;
  old_txt text;
  new_txt text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema'
   LIMIT 1;

  IF src IS NULL THEN
    RAISE EXCEPTION 'create_institution_schema not found';
  END IF;

  -- Already done? Checked on the ordid assignment specifically, not merely on
  -- the word "ordid" -- class, course and semester all carry an ordid column
  -- and their DDL is in this same function, so a looser test would report
  -- success on an unpatched generator.
  IF position('NEW.ordid IS NULL' in src) > 0 THEN
    RAISE NOTICE 'create_institution_schema already patched -- nothing to do';
    RETURN;
  END IF;

  old_txt := 'NEW.fee_id := nextval(''''%I.feetype_fee_id_seq''''); END IF; RETURN NEW; END; $t$'', v_schema, v_schema);';
  new_txt := 'NEW.fee_id := nextval(''''%I.feetype_fee_id_seq''''); END IF; '
          || 'IF NEW.ordid IS NULL THEN SELECT COALESCE(MAX(ordid),0)+1 INTO NEW.ordid FROM %I.feetype WHERE ins_id = NEW.ins_id; END IF; '
          || 'RETURN NEW; END; $t$'', v_schema, v_schema, v_schema);';

  IF position(old_txt in src) = 0 THEN
    RAISE EXCEPTION 'set_fee_id line not found in create_institution_schema -- generator has drifted, patch by hand';
  END IF;

  EXECUTE replace(src, old_txt, new_txt);
  RAISE NOTICE 'create_institution_schema patched';
END
$do$;


-- =================================================================== PART 3 =
-- The CSV import's "FeeType Order" column stops being thrown away.
-- ===========================================================================

DO $do$
DECLARE
  src     text;
  old_txt text;
  new_txt text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'process_master_import'
   LIMIT 1;

  IF src IS NULL THEN
    RAISE EXCEPTION 'process_master_import not found';
  END IF;

  IF position('feefineapplicable,type,activestatus,ins_id,ordid' in src) > 0 THEN
    RAISE NOTICE 'process_master_import already patched -- nothing to do';
    RETURN;
  END IF;

  old_txt := 'feefineapplicable,type,activestatus,ins_id) VALUES($1,$2,$3,$4,$5,$6,COALESCE(NULLIF($7,'''''''')::smallint,0),NULLIF($8,''''''''),1,$9)'', v_schema) USING v_id,TRIM(rec.col2),TRIM(rec.col3),v_fg_id,v_yr_id,v_yrlabel,TRIM(rec.col5),TRIM(rec.col7),p_ins_id;';

  -- A cell that is not a plain number is treated as blank. One stray word in
  -- one row must not abort an import of ninety-five fee types, and the
  -- trigger will give that row a sensible order anyway.
  new_txt := 'feefineapplicable,type,activestatus,ins_id,ordid) VALUES($1,$2,$3,$4,$5,$6,COALESCE(NULLIF($7,'''''''')::smallint,0),NULLIF($8,''''''''),1,$9,CASE WHEN TRIM($10) ~ ''''^[0-9]+$'''' THEN TRIM($10)::smallint ELSE NULL END)'', v_schema) USING v_id,TRIM(rec.col2),TRIM(rec.col3),v_fg_id,v_yr_id,v_yrlabel,TRIM(rec.col5),TRIM(rec.col7),p_ins_id,TRIM(rec.col6);';

  IF position(old_txt in src) = 0 THEN
    RAISE EXCEPTION 'FEETYPE insert not found in process_master_import -- patch by hand';
  END IF;

  EXECUTE replace(src, old_txt, new_txt);
  RAISE NOTICE 'process_master_import patched';
END
$do$;


-- ------------------------------------------------------------- VERIFY ------
-- Expect: schemas_without_it 0, generator_patched t, import_patched t.
SELECT
  (SELECT count(*)
     FROM information_schema.columns c
    WHERE c.table_name = 'feetype' AND c.column_name = 'ordid'
      AND c.table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
      AND NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = c.table_schema AND p.proname = 'set_fee_id'
           AND p.prosrc LIKE '%NEW.ordid%'))            AS schemas_without_it,
  (SELECT bool_or(p.prosrc LIKE '%NEW.ordid IS NULL%')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema')
                                                        AS generator_patched,
  (SELECT bool_or(p.prosrc LIKE '%activestatus,ins_id,ordid%')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'process_master_import')
                                                        AS import_patched;

-- The trigger is still attached, and still the only one doing this job.
SELECT t.tgname, p.proname, p.prosrc LIKE '%NEW.ordid%' AS fills_ordid
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
 WHERE n.nspname = 'kcet20262027' AND c.relname = 'feetype' AND NOT t.tgisinternal;
