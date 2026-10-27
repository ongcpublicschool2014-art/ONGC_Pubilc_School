-- ############################################################################
-- EduCore360 -- FEE DEMANDS WHOSE COURSE DOES NOT MATCH THEIR OWN CLASS
-- 19-09-2026
--
-- feedemand carries both courname and stuclass. Some rows disagree with each
-- other: a demand filed under B TECH- IT but in class B.E CSE -I, when the
-- class master says B.E CSE -I belongs to B.E-CSE. That pairing cannot be
-- true of anything.
--
-- ---------------------------------------------------------------------------
-- THE RULE, AND WHY IT IS NOT "THE STUDENT'S CURRENT COURSE"
-- ---------------------------------------------------------------------------
-- A demand's course is the course that OWNS ITS OWN CLASS (class.cour_id ->
-- course.courname). It is NOT the student's current course.
--
-- That distinction matters because of COURSE TRANSFER. When a student moves
-- course, transfer_course_with_credit keeps their already-paid demands as
-- settled records, still carrying the OLD course and the OLD class -- which is
-- correct and historical: that money was billed and collected under the old
-- course, and the DCB Register for that course must go on showing it.
--
-- Re-stamping those rows with the student's CURRENT course would leave the old
-- class beside the new course -- inventing exactly the mismatch this file
-- exists to remove -- and would move settled money from one course's register
-- to another's. So the repair below never looks at the student.
--
-- A worked example from TEST (2627372, transferred B.E-EEE -> B.E-ECE):
--     B.E-EEE / B.E EEE -I   x4   <- old course, settled. LEFT ALONE.
--     B.E-ECE / B.E ECE -I   x3   <- new course. LEFT ALONE.
-- Both pairs are internally consistent, so neither is touched.
--
-- ---------------------------------------------------------------------------
-- WHERE THE BAD ROWS COME FROM
-- ---------------------------------------------------------------------------
-- Not from course transfer: that writes course and class together, and the
-- interim_promotion log on TEST shows all of its moves paired correctly
-- (B.E-EEE/B.E EEE -I -> B.E-ECE/B.E ECE -I, and so on).
--
-- The bad rows carry the student's CURRENT class with a STALE course, i.e.
-- something changed the class and left the course behind. Two paths can do
-- that:
--   * Student Transfer (the section screen). It resolves the target course
--     from class.cour_id and passes it to update_demand_class; when that
--     resolution came back empty it fell back to the student's existing
--     course, so stuclass moved and courname did not.
--   * Fee Demand Import, if a sheet carried a class from one column and a
--     course from another that do not belong together.
-- The class master is clean now -- every class has a valid cour_id -- so the
-- first path cannot recur; the import path is only as good as the sheet.
--
-- WHAT IT BROKE
-- The reports' Class dropdown was built from the (course, class) pairs present
-- in the demands, so it offered impossible pairs: pick B TECH- IT and the list
-- included B.E CSE -I. The app no longer matches on the demand -- it follows
-- the student -- so the dropdown is already correct without this file. This
-- repairs the DATA, so the reports that group by feedemand.courname (the DCB
-- Register, the course filters) agree too.
--
-- Nothing but courname is touched: no amount, no balance, no status, no class.
--
-- SAFE TO RE-RUN: the UPDATE only matches rows that still disagree.
-- Applied and checked on the TEST project first.
-- ############################################################################


-- ############################################################################
-- BEFORE (READ-ONLY) -- how many rows disagree with their own class, per
-- schema. Run this first and keep the output.
-- ############################################################################
DO $before$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'feedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(*)
        FROM %I.feedemand fd
        JOIN %I.class  c  ON UPPER(TRIM(c.claname)) = UPPER(TRIM(fd.stuclass))
                          AND c.activestatus = 1
        JOIN %I.course co ON co.cour_id = c.cour_id
       WHERE fd.activestatus = 1
         AND COALESCE(fd.courname,'') IS DISTINCT FROM COALESCE(co.courname,'') $q$,
      r.s, r.s, r.s) INTO n;
    RAISE NOTICE '%: % demand row(s) whose course does not match their own class',
                 r.s, n;
  END LOOP;
END $before$;

-- The detail, so the pairs can be eyeballed before anything changes.
SELECT fd.courname AS demand_course, fd.stuclass AS demand_class,
       co.courname AS class_actually_belongs_to, count(*) AS rows
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.class  c  ON UPPER(TRIM(c.claname)) = UPPER(TRIM(fd.stuclass))
                              AND c.activestatus = 1
  JOIN kcet20262027.course co ON co.cour_id = c.cour_id
 WHERE fd.activestatus = 1
   AND COALESCE(fd.courname,'') IS DISTINCT FROM COALESCE(co.courname,'')
 GROUP BY 1, 2, 3
 ORDER BY rows DESC;


-- ############################################################################
-- THE REPAIR -- changes DATA. Read the BEFORE output first.
--
-- courname := the course that owns this demand's class. A demand whose class
-- is not in the class master is skipped (the JOIN drops it) rather than
-- guessed at.
-- ############################################################################
DO $fix$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'feedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      UPDATE %I.feedemand fd
         SET courname = co.courname
        FROM %I.class c
        JOIN %I.course co ON co.cour_id = c.cour_id
       WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(fd.stuclass))
         AND c.activestatus = 1
         AND fd.activestatus = 1
         AND COALESCE(fd.courname,'') IS DISTINCT FROM COALESCE(co.courname,'') $q$,
      r.s, r.s, r.s);
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE '%: % demand row(s) re-stamped with their class''s course', r.s, n;
  END LOOP;
END $fix$;


-- ############################################################################
-- VERIFY -- every schema must report 0.
-- ############################################################################
DO $after$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'feedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(*)
        FROM %I.feedemand fd
        JOIN %I.class  c  ON UPPER(TRIM(c.claname)) = UPPER(TRIM(fd.stuclass))
                          AND c.activestatus = 1
        JOIN %I.course co ON co.cour_id = c.cour_id
       WHERE fd.activestatus = 1
         AND COALESCE(fd.courname,'') IS DISTINCT FROM COALESCE(co.courname,'') $q$,
      r.s, r.s, r.s) INTO n;
    RAISE NOTICE '%: % still mismatched (should be 0)', r.s, n;
  END LOOP;
END $after$;

-- A transferred student keeps BOTH pairs, each internally consistent. This
-- should list their old course's settled demands AND their new course's --
-- if it ever shows an old class beside a new course, the repair above has
-- been changed to follow the student, and that is wrong.
SELECT fd.stuadmno, fd.courname, fd.stuclass, count(*) AS rows
  FROM kcet20262027.feedemand fd
 WHERE fd.activestatus = 1
   AND fd.stuadmno IN (SELECT stuadmno FROM kcet20262027.interim_promotion
                        WHERE activestatus = 1)
 GROUP BY 1, 2, 3
 ORDER BY fd.stuadmno, fd.courname;
