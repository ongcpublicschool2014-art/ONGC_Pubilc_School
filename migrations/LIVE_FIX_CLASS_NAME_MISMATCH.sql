-- ############################################################################
--
--   EduCore360 -- FIX CLASS NAMES ON LIVE, 23-09-2026
--
--   Six final-year classes in the master are named after the COURSE
--   ("B.E-CSE-IV") while every other year in the same ladder is named the way
--   students actually hold it ("B.E CSE -I", "-II", "-III"). The difference is
--   a hyphen where the rest of the ladder has a space, so it survives any
--   comparison that only strips whitespace.
--
--   Run the whole file in the SQL editor on the LIVE project. Run
--   CHECK_BEFORE_ADVANCE_LOAD.sql first if you have not already -- it says
--   LIVE or TEST from the database itself, which the project name will not.
--
-- ----------------------------------------------------------------------------
-- WHY IT MATTERS
-- ----------------------------------------------------------------------------
-- Students sitting in a class the master does not contain:
--
--   * get no classtype, so they are missing from every Promotional / Terminal
--     count and from anything keyed on the class master
--   * end the promotion ladder on a name nobody is in: "B.E CSE -III" succeeds
--     to "B.E-CSE-IV", which holds 0 students
--
-- On the TEST restore that was 228 active students, and it made the final-year
-- count read 63 instead of roughly 290.
--
-- ----------------------------------------------------------------------------
-- WHAT IT CHANGES
-- ----------------------------------------------------------------------------
-- The claname of up to six rows in <schema>.class. Nothing else -- no student,
-- demand, receipt or payment row is written. On the TEST restore:
--
--   cla_id  from              to
--   ------  ----------------  ------------------
--      54   B.E-ECE-IV        B.E ECE -IV          (78 students)
--      51   B.E-CSE-IV        B.E CSE -IV          (62)
--       1   B TECH- IT-IV     B.TECH ( IT) -IV     (61)
--     229   B.E-CIVIL-IV      B.E CIVIL-IV         (20)
--     120   M.E-EST-II        M.E EST- II          (4)
--     344   B ED-II           B.ED - II            (3)
--
-- The MASTER row is the right thing to move, not the students: the students'
-- name is the one already printed on their demands, receipts and ledgers, and
-- all six master rows hold ZERO students, so renaming them strands nobody.
--
-- succeedingclass is by cla_id, so the ladder follows the rename automatically
-- and needs no repair.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RUN, AND SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- * Each rename is matched on the OLD name, so a second run finds nothing.
-- * A rename is SKIPPED if the new name already exists -- that would merge two
--   classes, and there would be no way back.
-- * All or nothing: the editor runs this as one transaction.
-- * This file does NOT read class.classtype, so it works whether or not
--   LIVE_RUN_20260921.sql (CLASS_TYPE.sql) has been run yet. Order between the
--   two does not matter.
--
-- ----------------------------------------------------------------------------
-- WHAT YOU SHOULD SEE
-- ----------------------------------------------------------------------------
-- One result, in three parts, because the editor shows only the last statement:
--
--   1 BEFORE   the classes students are in that the master did not contain
--   2 RENAME   what each of the six renames did: "renamed", "not found"
--              (already correct on live) or "SKIPPED - target exists"
--   3 AFTER    must be a single row reading "none - every class matches".
--              Anything else is a class still unmatched, and worth telling me
--              about before you move on.
--
-- Checked on the TEST project (a restore of live) first.
-- ############################################################################


-- ----------------------------------------------------------------------------
-- 0 -- REFUSE TO RUN ON THE TEST PROJECT
--
-- public._this_is_the_test_project exists on TEST and nowhere else. If this is
-- TEST, the script stops here and nothing below it runs -- the editor executes
-- the file as one transaction, so an abort leaves the database untouched.
--
-- Both projects are named KCET and both show the PRODUCTION chip; this is the
-- check that does not depend on noticing that.
-- ----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public._this_is_the_test_project') IS NOT NULL THEN
    RAISE EXCEPTION
      'This is the TEST project -- this script is for LIVE only. Nothing was written. Switch to the live project (URL must read /project/exasnbapvgfeooxyxjas) and run it again.';
  END IF;
END $guard$;


-- ----------------------------------------------------------------------------
-- 1 -- capture the BEFORE picture
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _cm_before ON COMMIT DROP AS
SELECT s.courname AS course, s.stuclass AS detail, COUNT(*)::bigint AS students
  FROM kcet20262027.students s
 WHERE s.activestatus = 1 AND COALESCE(s.preadmission, 0) = 0
   AND NOT EXISTS (SELECT 1 FROM kcet20262027.class c
                    WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
                      AND c.ins_id = s.ins_id AND c.activestatus = 1)
 GROUP BY 1, 2;


-- ----------------------------------------------------------------------------
-- 2 -- the rename
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _cm_log (detail text, students bigint) ON COMMIT DROP;

DO $ren$
DECLARE
  n int;
  i int;
  pairs CONSTANT text[][] := ARRAY[
    ARRAY['B.E-ECE-IV',    'B.E ECE -IV'],
    ARRAY['B.E-CSE-IV',    'B.E CSE -IV'],
    ARRAY['B TECH- IT-IV', 'B.TECH ( IT) -IV'],
    ARRAY['B.E-CIVIL-IV',  'B.E CIVIL-IV'],
    ARRAY['M.E-EST-II',    'M.E EST- II'],
    ARRAY['B ED-II',       'B.ED - II']
  ];
BEGIN
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    -- Never rename onto a name that already exists: that would merge two
    -- classes, and there would be no way back.
    IF EXISTS (SELECT 1 FROM kcet20262027.class
                WHERE UPPER(TRIM(claname)) = UPPER(TRIM(pairs[i][2]))
                  AND activestatus = 1) THEN
      INSERT INTO _cm_log VALUES
        (format('SKIPPED  %s -> %s  (target already exists)', pairs[i][1], pairs[i][2]), 0);
      CONTINUE;
    END IF;

    UPDATE kcet20262027.class
       SET claname = pairs[i][2]
     WHERE UPPER(TRIM(claname)) = UPPER(TRIM(pairs[i][1]))
       AND activestatus = 1;
    GET DIAGNOSTICS n = ROW_COUNT;

    INSERT INTO _cm_log VALUES (
      CASE WHEN n > 0
           THEN format('renamed  %s -> %s', pairs[i][1], pairs[i][2])
           ELSE format('not found  %s  (nothing to rename)', pairs[i][1])
      END, n);
  END LOOP;
END $ren$;


-- ----------------------------------------------------------------------------
-- 3 -- the whole story, in one result
-- ----------------------------------------------------------------------------
SELECT '1 BEFORE' AS stage,
       course || ' -- ' || detail AS detail,
       students
  FROM _cm_before

UNION ALL
SELECT '2 RENAME', detail, students FROM _cm_log

UNION ALL
SELECT '3 AFTER',
       COALESCE(x.course || ' -- ' || x.detail, 'none - every class matches'),
       COALESCE(x.students, 0)
  FROM (SELECT s.courname AS course, s.stuclass AS detail, COUNT(*)::bigint AS students
          FROM kcet20262027.students s
         WHERE s.activestatus = 1 AND COALESCE(s.preadmission, 0) = 0
           AND NOT EXISTS (SELECT 1 FROM kcet20262027.class c
                            WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
                              AND c.ins_id = s.ins_id AND c.activestatus = 1)
         GROUP BY 1, 2) x
 RIGHT JOIN (SELECT 1) one ON TRUE

 ORDER BY stage, students DESC, detail;
