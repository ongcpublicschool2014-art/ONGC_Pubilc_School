-- =====================================================================
-- B.TECH ( IT) -IV has no students on any screen that lists a class.
--
-- Not a code fault. The class MASTER calls it 'B TECH- IT-IV' while
-- every table that stores student data calls it 'B.TECH ( IT) -IV':
--
--     class (master)   B TECH- IT-IV        1 row
--     students         B.TECH ( IT) -IV    61 rows
--     feedemand        B.TECH ( IT) -IV   776 rows
--     classfeedemand   B.TECH ( IT) -IV   244 rows
--
-- Classes are matched BY NAME, so the dropdown built from the master
-- finds nobody: Fee Demand Import shows "No students" and the Semester
-- box shows "No class fees". Those 61 are the only active students in
-- the schema whose class name matches no master row.
--
-- THE MASTER IS THE ONE TO CHANGE, not the 1,081 data rows. Nothing
-- anywhere references 'B TECH- IT-IV' -- not students, feedemand,
-- classfeedemand, tempfeedemand or public.admission -- so renaming it
-- breaks nothing, while rewriting the data rows would touch three
-- tables including live fee demands.
--
-- The spacing stays as the data has it. Its siblings read
-- 'B.TECH  (IT) -I/-II/-III' (no space inside the bracket) so this one
-- is untidy, but tidying it means rewriting those 1,081 rows for
-- appearance alone. Not worth the risk; the name is an identifier here,
-- not a label.
--
-- Run on LIVE. Read the verify output before and after.
-- =====================================================================

-- BEFORE: expect 1 master row named 'B TECH- IT-IV' and 0 students on it.
SELECT c.cla_id, c.claname, count(s.stu_id) AS active_students
  FROM kcet20262027.class c
  LEFT JOIN kcet20262027.students s
         ON s.stuclass = c.claname AND s.activestatus = 1
 WHERE c.claname ILIKE '%IT%'
 GROUP BY c.cla_id, c.claname
 ORDER BY c.claname;

-- THE FIX. Guarded on the old name so a re-run does nothing.
UPDATE kcet20262027.class
   SET claname = 'B.TECH ( IT) -IV'
 WHERE claname = 'B TECH- IT-IV';

-- AFTER: the same class must now report 61 active students, and the
-- other three IT classes must be unchanged.
SELECT c.cla_id, c.claname, count(s.stu_id) AS active_students
  FROM kcet20262027.class c
  LEFT JOIN kcet20262027.students s
         ON s.stuclass = c.claname AND s.activestatus = 1
 WHERE c.claname ILIKE '%IT%'
 GROUP BY c.cla_id, c.claname
 ORDER BY c.claname;

-- Nothing anywhere should still be orphaned by name.
SELECT count(*) AS students_with_no_master_class
  FROM kcet20262027.students s
  LEFT JOIN kcet20262027.class c ON c.claname = s.stuclass
 WHERE s.activestatus = 1 AND c.claname IS NULL;
