-- ############################################################################
--
--   EduCore360 -- THE SIXTH CLASS RENAME, WHICH DID NOT LAND
--   25-09-2026
--
--   Run the whole file in the SQL editor on the LIVE project.
--   It refuses to run on TEST.
--
-- ----------------------------------------------------------------------------
-- WHAT HAPPENED
-- ----------------------------------------------------------------------------
-- LIVE_FIX_CLASS_NAME_MISMATCH.sql (part 4 of the 0.0.8 release) renames six
-- master classes to the names students actually carry. On live FIVE landed and
-- ONE did not:
--
--     B.E CIVIL-IV    20 students    renamed
--     B.E CSE -IV     62             renamed
--     B.E ECE -IV     61             renamed
--     B.ED - II        3             renamed
--     M.E EST- II      4             renamed
--     B TECH- IT-IV    0             STILL THE OLD NAME   <-- this file
--
-- Why the sixth was skipped is not recoverable from the database -- part 4
-- printed a per-rename line ("renamed" / "not found" / "SKIPPED - target
-- exists") and that output was not kept. What IS certain is the end state:
-- the master row still reads 'B TECH- IT-IV' and its WHERE clause matches it,
-- so the rename can simply be completed now.
--
-- ----------------------------------------------------------------------------
-- WHAT IT BREAKS WHILE IT IS WRONG
-- ----------------------------------------------------------------------------
-- 61 active students carry 'B.TECH ( IT) -IV'. The master has no such row, so
-- those students are in a class the master does not contain:
--
--   * Misc Collection, Fee Collection and every other screen whose Class
--     dropdown is built from the MASTER offers 'B TECH- IT-IV' -- a name
--     nobody is in -- and lists no students. This is what was reported.
--   * they are missing from any count keyed on the class master
--   * check 3 of the release's verification ("every student's class is in the
--     master") reads UNMATCHED rather than OK, for exactly these 61
--
-- ----------------------------------------------------------------------------
-- WHY THE MASTER MOVES AND NOT THE STUDENTS
-- ----------------------------------------------------------------------------
-- The students' name is the one already printed on their demands, receipts and
-- ledgers; renaming 61 students would rewrite what those documents say. The
-- master row holds ZERO students, so moving it strands nobody. Same reasoning
-- the original file used for the other five.
--
-- succeedingclass is by cla_id, so the promotion ladder follows the rename and
-- needs no repair. classtype is already TERMINAL and stays that way.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RUN, AND SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- * Matched on the OLD name, so a second run finds nothing to do.
-- * REFUSES if 'B.TECH ( IT) -IV' already exists -- renaming onto a live name
--   would merge two classes and there would be no way back.
-- * One transaction: it renames the row or changes nothing.
-- * No student, demand, receipt or payment row is written.
--
-- Applied and verified on TEST (a restore of live taken 25-09 11:11, which
-- carries the same defect) before this file was written.
--
-- ----------------------------------------------------------------------------
-- WHAT YOU SHOULD SEE
-- ----------------------------------------------------------------------------
-- Two rows:
--   the renamed class, reading 'B.TECH ( IT) -IV' TERMINAL with 61 students
--   students_still_unmatched = 0
-- ############################################################################

-- ----------------------------------------------------------------------------
-- 0 -- REFUSE TO RUN ON THE TEST PROJECT
-- ----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public._this_is_the_test_project') IS NOT NULL THEN
    RAISE EXCEPTION
      'This is the TEST project -- already fixed here. Nothing was written. Switch to the live project (URL must read /project/exasnbapvgfeooxyxjas) and run it again.';
  END IF;
END $guard$;


-- ----------------------------------------------------------------------------
-- 1 -- complete the rename
-- ----------------------------------------------------------------------------
DO $ren$
DECLARE n int;
BEGIN
  IF EXISTS (SELECT 1 FROM kcet20262027.class
              WHERE UPPER(TRIM(claname)) = UPPER(TRIM('B.TECH ( IT) -IV'))
                AND activestatus = 1) THEN
    RAISE EXCEPTION
      'B.TECH ( IT) -IV already exists in the class master -- renaming onto it would merge two classes. Nothing was written; send me the class list instead.';
  END IF;

  UPDATE kcet20262027.class
     SET claname = 'B.TECH ( IT) -IV'
   WHERE UPPER(TRIM(claname)) = UPPER(TRIM('B TECH- IT-IV'))
     AND activestatus = 1;
  GET DIAGNOSTICS n = ROW_COUNT;

  IF n = 0 THEN
    RAISE EXCEPTION
      'No active class named B TECH- IT-IV to rename. Nothing was written -- tell me what the class master holds before going further.';
  END IF;
END $ren$;


-- ----------------------------------------------------------------------------
-- 2 -- VERIFY
-- ----------------------------------------------------------------------------
SELECT 'renamed class' AS what,
       c.claname AS detail,
       (SELECT count(*) FROM kcet20262027.students s
         WHERE UPPER(TRIM(s.stuclass)) = UPPER(TRIM(c.claname))
           AND s.activestatus = 1)::text AS value
  FROM kcet20262027.class c
 WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM('B.TECH ( IT) -IV'))
   AND c.activestatus = 1

UNION ALL
SELECT 'students still unmatched', 'expected 0', count(*)::text
  FROM kcet20262027.students s
 WHERE s.activestatus = 1 AND COALESCE(s.preadmission, 0) = 0
   AND NOT EXISTS (SELECT 1 FROM kcet20262027.class c
                    WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
                      AND c.ins_id = s.ins_id AND c.activestatus = 1);
