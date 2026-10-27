-- ============================================================================
-- feetype.ordid -- let the office decide the order fee types appear in.
-- ============================================================================
-- WHY. Reports lay fee types out as columns and sort them ALPHABETICALLY, so
-- a statement reads ADMISSION, A.U.SPORTS FEE, BUS FEES, EXAM FEE, TUITION
-- FEE -- which is nobody's idea of how a fee statement should read. TUITION
-- FEE is the one everybody looks for and it lands near the end because of its
-- initial letter.
--
-- Every other master that has a meaningful running order already carries this
-- column, with the same name and type: class, course, semester,
-- concessioncategory. feetype was the odd one out.
--
-- WHAT THIS DOES.
--   PART 1  adds ordid smallint to feetype in EVERY institution schema.
--   PART 2  seeds it so nothing is NULL on day one -- grouped by fee group,
--           then by fee_id within the group, which is the order they were
--           created and the closest thing to an intended sequence that
--           exists today. The office can renumber freely afterwards.
--   PART 3  patches create_institution_schema so a NEW institution is born
--           with the column instead of inheriting the old shape.
--
-- ORDERING IS ADVISORY, NOT A KEY. Duplicates and gaps are fine: the app
-- falls back to the fee description so two rows sharing an ordid still come
-- out in a stable, predictable order rather than shuffling between runs.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 1 =
-- The column, in every institution schema.
-- ===========================================================================

DO $add$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feetype'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.feetype ADD COLUMN IF NOT EXISTS ordid smallint', r.sch);
    RAISE NOTICE 'feetype.ordid ready in %', r.sch;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '% schema(s) updated', n;
END
$add$;


-- =================================================================== PART 2 =
-- Seed it. Only rows still NULL, so a re-run never undoes the office's work.
-- ===========================================================================

DO $seed$
DECLARE r record; n int := 0; c int;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feetype'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format($q$
      WITH ranked AS (
        SELECT fee_id,
               (row_number() OVER (ORDER BY COALESCE(fg_id, 32767), fee_id))::smallint AS seq
          FROM %I.feetype
      )
      UPDATE %I.feetype f
         SET ordid = ranked.seq
        FROM ranked
       WHERE f.fee_id = ranked.fee_id
         AND f.ordid IS NULL
    $q$, r.sch, r.sch);
    GET DIAGNOSTICS c = ROW_COUNT;
    RAISE NOTICE '% : % fee type(s) numbered', r.sch, c;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '% schema(s) seeded', n;
END
$seed$;


-- =================================================================== PART 3 =
-- New institutions get it too.
--
-- Patches the live generator text rather than replacing the whole function --
-- 55,000 characters of it -- so an unrelated change made since cannot be
-- silently reverted by this migration.
-- ===========================================================================

DO $gen$
DECLARE
  src text;
  feetype_ddl text;
  -- The real column is partialALLowed. An earlier draft of this migration
  -- searched for 'partiallowed' and would have matched nothing; it was saved
  -- only by a guard that was ALSO wrong -- 'src LIKE ''%feetype%ordid%''' is
  -- true of any generator containing both words anywhere, and ordid already
  -- exists on class, course and semester. Two loose tests cancelling out is
  -- not a safety net.
  old_txt CONSTANT text := 'partialallowed char(1) DEFAULT ''''Y''''';
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'create_institution_schema';

  IF src IS NULL THEN
    RAISE NOTICE 'create_institution_schema not found - nothing to patch';
    RETURN;
  END IF;

  -- Look at FEETYPE'S OWN definition, not the whole function.
  feetype_ddl := substring(src from 'CREATE TABLE %I.feetype[^;]*');
  IF feetype_ddl IS NULL THEN
    RAISE EXCEPTION 'Could not find feetype in the generator -- NOT patched.';
  END IF;

  IF feetype_ddl LIKE '%ordid%' THEN
    RAISE NOTICE 'generator already creates feetype.ordid';
    RETURN;
  END IF;

  n := (length(src) - length(replace(src, old_txt, ''))) / length(old_txt);
  IF n <> 1 THEN
    RAISE EXCEPTION 'Expected feetype''s partiallowed column once in the '
      'generator, found % -- NOT patched. Read the function before forcing; '
      'guessing at a schema builder is how a new institution is born broken.', n;
  END IF;

  src := replace(src, old_txt, 'ordid smallint, ' || old_txt);
  EXECUTE src;
  RAISE NOTICE 'patched create_institution_schema: feetype gains ordid';
END
$gen$;


-- ------------------------------------------------------------- VERIFY ------
-- 1. Column present, nothing left NULL, and the generator carries it.
SELECT
  EXISTS (SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'kcet20262027' AND table_name = 'feetype'
             AND column_name = 'ordid')                        AS column_exists,
  (SELECT count(*) FROM kcet20262027.feetype WHERE ordid IS NULL)
                                                               AS still_unset,
  -- Looks at FEETYPE'S OWN definition. The whole-function test this used to
  -- do matched 'partiallowed' -- a typo for partialALLowed -- and reported
  -- false on a generator that had been patched correctly.
  (SELECT substring(pg_get_functiondef(p.oid)
                    from 'CREATE TABLE %I.feetype[^;]*') LIKE '%ordid%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema')
                                                               AS generator_has_it;

-- 2. The order the reports will now use. Renumber ordid to taste.
SELECT f.ordid, f.fee_id, f.feedesc, f.feeshort, g.fgdesc AS fee_group
  FROM kcet20262027.feetype f
  LEFT JOIN kcet20262027.feegroup g ON g.fg_id = f.fg_id
 WHERE f.activestatus = 1
 ORDER BY f.ordid, f.feedesc;
