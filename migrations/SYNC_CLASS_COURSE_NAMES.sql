-- ############################################################################
--
--   EduCore360 -- MAKE EVERY TABLE'S CLASS / COURSE NAME MATCH THE MASTER
--   26-09-2026
--
--   Runs on either project. PREVIEW FIRST -- see "HOW TO RUN" below.
--
-- ----------------------------------------------------------------------------
-- WHY THIS EXISTS
-- ----------------------------------------------------------------------------
-- The class and course NAMES are copied onto the rows that use them -- a
-- student's stuclass, a demand's stuclass/courname, a fee definition's cfclass.
-- Copies drift: a class renamed in the master leaves rows written before the
-- rename spelling it the old way, and every screen that joins on the NAME (Fee
-- Collection's class dropdown, Misc Collection's student list) then offers a
-- class nobody is in. That is what happened to B TECH- IT-IV / B.TECH ( IT) -IV.
--
-- ----------------------------------------------------------------------------
-- WHAT IT WILL NOT DO, AND WHY  (read this -- it is the important part)
-- ----------------------------------------------------------------------------
-- A first draft of this file restated every name from the class the row's OWN
-- cla_id points at. On TEST that would have rewritten 810 rows -- and they were
-- not drift:
--
--     demfeeyear  type    stuclass on the row   class by cla_id   rows
--     2024-2025   ARREAR  B.E CSE -III          B.E CSE -I          36
--     2025-2026   ARREAR  B.E MECH -II          B.E MECH -I         30
--     2020-2021   ARREAR  CSE TC 23             B.E CSE -II         29
--
-- An arrear demand records the class the student was in WHEN IT WAS RAISED.
-- cla_id follows them as they are promoted, so on an old demand the two
-- legitimately disagree. "Syncing" those would have made a 2024-25 demand claim
-- the student was in first year -- falsifying documents that have been issued.
--
-- So the rule is split by what the row MEANS:
--
--   PART A -- CURRENT STATE, keyed on the id.
--     students, classfeedemand, student_import, public.admission.
--     These describe how things are now, so the master's name is restated
--     from cla_id / cour_id.
--
--   PART B -- HISTORY, spelling only.
--     feedemand, tempfeedemand, tc_entry, advance_collection, concession,
--     fee_refund, misc_collection, parentdetail, interim_promotion and the
--     arrearclass columns. A row is rewritten ONLY where it already names the
--     same class ignoring case and spacing -- "B TECH- IT-IV" -> the master's
--     exact text. A row naming a different class is left exactly as it is.
--
--   REPORTED, never touched: a name the master does not contain at all, and a
--   history row whose stored class differs from its cla_id. Both need a human;
--   nothing in the data says which is right.
--
-- ----------------------------------------------------------------------------
-- BEFORE LIVE
-- ----------------------------------------------------------------------------
-- THE MASTER MUST BE RIGHT FIRST -- this copies the master outward. On live the
-- class master still reads 'B TECH- IT-IV' while 61 students carry
-- 'B.TECH ( IT) -IV'. Run LIVE_FIX_IT_IV_CLASS_NAME.sql FIRST, or part A will
-- push the old name onto those students.
--
-- ----------------------------------------------------------------------------
-- HOW TO RUN
-- ----------------------------------------------------------------------------
--   1. Run it as it is. v_dry_run is TRUE: nothing is written and the result
--      lists what WOULD change, per table and column.
--   2. If that reads right, change
--          v_dry_run boolean := true;   ->   := false;
--      and run it again. The same list comes back, describing what was written.
--
-- Every year schema that has a class table is covered in one pass.
-- Safe to re-run: a second run finds nothing left to change.
-- ############################################################################

DROP TABLE IF EXISTS _name_sync_report;
CREATE TEMP TABLE _name_sync_report(
  part text, target text, rows_affected bigint);

DO $sync$
DECLARE
  -- >>> flip this to false to actually write <<<
  v_dry_run boolean := true;

  v_schema  text;
  v_sql     text;
  v_count   bigint;

  -- CURRENT STATE: table, name column, id column, master table, master name
  v_a text[][] := ARRAY[
    ['students',       'stuclass', 'cla_id',  'class',  'claname'],
    ['students',       'courname', 'cour_id', 'course', 'courname'],
    ['classfeedemand', 'cfclass',  'cla_id',  'class',  'claname'],
    ['student_import', 'stuclass', 'cla_id',  'class',  'claname'],
    ['student_import', 'courname', 'cour_id', 'course', 'courname']
  ];

  -- HISTORY: table, name column -- spelling only, never re-pointed
  v_b text[][] := ARRAY[
    ['feedemand',          'stuclass'],
    ['feedemand',          'arrearclass'],
    ['tempfeedemand',      'stuclass'],
    ['tempfeedemand',      'arrearclass'],
    ['tc_entry',           'stuclass'],
    ['advance_collection', 'stuclass'],
    ['concession',         'stuclass'],
    ['fee_refund',         'stuclass'],
    ['misc_collection',    'stuclass'],
    ['parentdetail',       'stuclass'],
    ['interim_promotion',  'stuclass']
  ];

  i int;
BEGIN
  FOR v_schema IN
    SELECT table_schema FROM information_schema.tables
     WHERE table_name = 'class'
       AND table_schema NOT IN ('pg_catalog','information_schema')
     ORDER BY table_schema
  LOOP
    -- ---------------------------------------------------------------- PART A
    FOR i IN 1 .. array_length(v_a, 1) LOOP
      CONTINUE WHEN NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = v_schema AND table_name = v_a[i][1]
           AND column_name = v_a[i][2]);

      IF v_dry_run THEN
        v_sql := format($q$
          SELECT count(*) FROM %1$I.%2$I t JOIN %1$I.%4$I m ON t.%6$I = m.%6$I
           WHERE t.%3$I IS DISTINCT FROM m.%5$I
        $q$, v_schema, v_a[i][1], v_a[i][2], v_a[i][4], v_a[i][5], v_a[i][3]);
      ELSE
        v_sql := format($q$
          WITH upd AS (
            UPDATE %1$I.%2$I t SET %3$I = m.%5$I
              FROM %1$I.%4$I m
             WHERE t.%6$I = m.%6$I AND t.%3$I IS DISTINCT FROM m.%5$I
            RETURNING 1)
          SELECT count(*) FROM upd
        $q$, v_schema, v_a[i][1], v_a[i][2], v_a[i][4], v_a[i][5], v_a[i][3]);
      END IF;

      EXECUTE v_sql INTO v_count;
      IF v_count > 0 THEN
        INSERT INTO _name_sync_report
        VALUES ('A current state', v_schema || '.' || v_a[i][1] || '.' || v_a[i][2], v_count);
      END IF;
    END LOOP;

    -- ---------------------------------------------------------------- PART B
    FOR i IN 1 .. array_length(v_b, 1) LOOP
      CONTINUE WHEN NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = v_schema AND table_name = v_b[i][1]
           AND column_name = v_b[i][2]);

      IF v_dry_run THEN
        v_sql := format($q$
          SELECT count(*) FROM %1$I.%2$I t JOIN %1$I.class c
              ON UPPER(TRIM(c.claname)) = UPPER(TRIM(t.%3$I))
           WHERE t.%3$I IS DISTINCT FROM c.claname
        $q$, v_schema, v_b[i][1], v_b[i][2]);
      ELSE
        v_sql := format($q$
          WITH upd AS (
            UPDATE %1$I.%2$I t SET %3$I = c.claname
              FROM %1$I.class c
             WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(t.%3$I))
               AND t.%3$I IS DISTINCT FROM c.claname
            RETURNING 1)
          SELECT count(*) FROM upd
        $q$, v_schema, v_b[i][1], v_b[i][2]);
      END IF;

      EXECUTE v_sql INTO v_count;
      IF v_count > 0 THEN
        INSERT INTO _name_sync_report
        VALUES ('B spelling', v_schema || '.' || v_b[i][1] || '.' || v_b[i][2], v_count);
      END IF;

      -- a name the master does not contain at all
      EXECUTE format($q$
        SELECT count(*) FROM %1$I.%2$I t
         WHERE COALESCE(TRIM(t.%3$I), '') <> ''
           AND NOT EXISTS (SELECT 1 FROM %1$I.class c
                            WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(t.%3$I)))
      $q$, v_schema, v_b[i][1], v_b[i][2]) INTO v_count;
      IF v_count > 0 THEN
        INSERT INTO _name_sync_report
        VALUES ('NOT IN MASTER - left alone',
                v_schema || '.' || v_b[i][1] || '.' || v_b[i][2], v_count);
      END IF;
    END LOOP;

    -- History rows whose stored class is a DIFFERENT class from their cla_id.
    -- Expected on arrear demands (the class at the time), so this is a count to
    -- read, not a fault to fix.
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = v_schema AND table_name = 'feedemand'
                  AND column_name = 'cla_id') THEN
      EXECUTE format($q$
        SELECT count(*) FROM %1$I.feedemand f JOIN %1$I.class c ON c.cla_id = f.cla_id
         WHERE UPPER(TRIM(f.stuclass)) IS DISTINCT FROM UPPER(TRIM(c.claname))
      $q$, v_schema) INTO v_count;
      IF v_count > 0 THEN
        INSERT INTO _name_sync_report
        VALUES ('FYI history kept', v_schema || '.feedemand.stuclass differs from its cla_id', v_count);
      END IF;
    END IF;
  END LOOP;

  -- ------------------------------------------------------------ public tables
  -- admission carries both ids and describes the current allocation.
  -- allocatedclass / prevclass are historical and carry no id: untouched.
  IF v_dry_run THEN
    SELECT count(*) INTO v_count
      FROM public.admission a JOIN kcet20262027.class c ON c.cla_id = a.cla_id
     WHERE a.stuclass IS DISTINCT FROM c.claname;
  ELSE
    WITH upd AS (
      UPDATE public.admission a SET stuclass = c.claname
        FROM kcet20262027.class c
       WHERE c.cla_id = a.cla_id AND a.stuclass IS DISTINCT FROM c.claname
      RETURNING 1)
    SELECT count(*) INTO v_count FROM upd;
  END IF;
  IF v_count > 0 THEN
    INSERT INTO _name_sync_report VALUES ('A current state', 'public.admission.stuclass', v_count);
  END IF;

  IF v_dry_run THEN
    SELECT count(*) INTO v_count
      FROM public.admission a JOIN kcet20262027.course k ON k.cour_id = a.cour_id
     WHERE a.courname IS DISTINCT FROM k.courname;
  ELSE
    WITH upd AS (
      UPDATE public.admission a SET courname = k.courname
        FROM kcet20262027.course k
       WHERE k.cour_id = a.cour_id AND a.courname IS DISTINCT FROM k.courname
      RETURNING 1)
    SELECT count(*) INTO v_count FROM upd;
  END IF;
  IF v_count > 0 THEN
    INSERT INTO _name_sync_report VALUES ('A current state', 'public.admission.courname', v_count);
  END IF;

  INSERT INTO _name_sync_report
  VALUES (CASE WHEN v_dry_run THEN '== DRY RUN, nothing written =='
               ELSE '== WRITTEN ==' END, 'set v_dry_run := false to apply', 0);
END $sync$;


-- ----------------------------------------------------------------------------
-- WHAT IT FOUND / DID
-- ----------------------------------------------------------------------------
--   A current state              restated from the master, keyed on the id
--   B spelling                   same class, different spelling -> master's text
--   NOT IN MASTER - left alone   the master has no such class; needs a human
--   FYI history kept             an old document naming the class of its day
SELECT * FROM _name_sync_report ORDER BY part, target;
