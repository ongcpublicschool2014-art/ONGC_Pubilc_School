-- ############################################################################
-- ############################################################################
--
--   EduCore360 -- final-year class names that no student is in
--   21-09-2026
--
-- ############################################################################
-- ############################################################################
--
-- Six classes in the master are named after the COURSE ("B.E-CSE-IV") while
-- every other year in the same ladder is named the way students actually hold
-- it ("B.E CSE -I", "-II", "-III"). The difference is a hyphen where the rest
-- of the ladder has a space, so it survives any comparison that only strips
-- whitespace.
--
-- The effect: 228 active students are in a class the master does not contain.
--
--   * they get no classtype, so they are missing from every Promotional /
--     Terminal count and from anything keyed on the class master
--   * the promotion ladder ends by pointing at a name nobody is in:
--     "B.E CSE -III" succeeds to "B.E-CSE-IV", which holds 0 students
--   * the TERMINAL count reads 63 when the real final-year population is
--     around 290
--
-- ---------------------------------------------------------------------------
-- WHAT IT DOES
-- ---------------------------------------------------------------------------
-- Renames the SIX master rows to the name the students already carry. Nothing
-- else moves:
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
-- The master row is the right thing to move, not the students: the students'
-- name is the one already printed on their demands, receipts and ledgers, and
-- all six master rows hold ZERO students, so renaming them strands nobody.
--
-- succeedingclass is by cla_id, so the ladder follows the rename automatically
-- and needs no repair.
--
-- SAFE TO RE-RUN: each rename is matched on the OLD name, so a second run
-- finds nothing to do.
--
-- Checked on the TEST project (a restore of live) first.
-- ############################################################################


-- ############################################################################
-- 1 -- BEFORE  (read-only)
-- ############################################################################
SELECT s.courname AS course, s.stuclass AS class_on_student, COUNT(*) AS students
  FROM kcet20262027.students s
 WHERE s.activestatus = 1 AND COALESCE(s.preadmission,0) = 0
   AND NOT EXISTS (SELECT 1 FROM kcet20262027.class c
                    WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
                      AND c.ins_id = s.ins_id AND c.activestatus = 1)
 GROUP BY 1,2 ORDER BY students DESC;


-- ############################################################################
-- 2 -- THE RENAME
--
-- Matched on the old name AND guarded on the target not already existing, so
-- this can never collapse two classes into one.
-- ############################################################################
DO $ren$
DECLARE
  r RECORD;
  n int;
  pairs CONSTANT text[][] := ARRAY[
    ARRAY['B.E-ECE-IV',    'B.E ECE -IV'],
    ARRAY['B.E-CSE-IV',    'B.E CSE -IV'],
    ARRAY['B TECH- IT-IV', 'B.TECH ( IT) -IV'],
    ARRAY['B.E-CIVIL-IV',  'B.E CIVIL-IV'],
    ARRAY['M.E-EST-II',    'M.E EST- II'],
    ARRAY['B ED-II',       'B.ED - II']
  ];
  i int;
BEGIN
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    -- Never rename onto a name that already exists: that would merge two
    -- classes and there would be no way back.
    IF EXISTS (SELECT 1 FROM kcet20262027.class
                WHERE UPPER(TRIM(claname)) = UPPER(TRIM(pairs[i][2]))
                  AND activestatus = 1) THEN
      RAISE NOTICE 'SKIPPED %: "%" already exists', pairs[i][1], pairs[i][2];
      CONTINUE;
    END IF;

    UPDATE kcet20262027.class
       SET claname = pairs[i][2]
     WHERE UPPER(TRIM(claname)) = UPPER(TRIM(pairs[i][1]))
       AND activestatus = 1;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN
      RAISE NOTICE 'renamed "%" -> "%"', pairs[i][1], pairs[i][2];
    END IF;
  END LOOP;
END $ren$;


-- ############################################################################
-- 3 -- VERIFY  (read-only)
-- ############################################################################
-- Should come back EMPTY: every active student's class is now in the master.
SELECT s.courname AS course, s.stuclass AS class_still_unmatched, COUNT(*) AS students
  FROM kcet20262027.students s
 WHERE s.activestatus = 1 AND COALESCE(s.preadmission,0) = 0
   AND NOT EXISTS (SELECT 1 FROM kcet20262027.class c
                    WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
                      AND c.ins_id = s.ins_id AND c.activestatus = 1)
 GROUP BY 1,2 ORDER BY students DESC;

-- The split the dashboard shows. TERMINAL should now hold the real final-year
-- population instead of 0-student rows.
SELECT COALESCE(c.classtype,'(class not in master)') AS classtype,
       COUNT(*) AS students
  FROM kcet20262027.students s
  LEFT JOIN kcet20262027.class c
    ON UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
   AND c.ins_id = s.ins_id AND c.activestatus = 1
 WHERE s.activestatus = 1 AND COALESCE(s.preadmission,0) = 0
 GROUP BY 1 ORDER BY students DESC;

-- The ladder, end to end. Every PROMOTIONAL class should succeed to a class
-- that exists, and the last step should land on a TERMINAL one.
SELECT co.courname AS course, c.claname AS class, c.classtype,
       nc.claname AS succeeds_to
  FROM kcet20262027.class c
  JOIN kcet20262027.course co ON co.cour_id = c.cour_id
  LEFT JOIN kcet20262027.class nc ON nc.cla_id = c.succeedingclass
 WHERE c.activestatus = 1 AND c.classtype <> 'COMPLETED'
 ORDER BY co.courname, c.ordid, c.claname;
