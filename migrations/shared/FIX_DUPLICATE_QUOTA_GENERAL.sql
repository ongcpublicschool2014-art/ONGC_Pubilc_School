-- =====================================================================
-- Admission Entry crashes with a red screen:
--
--   There should be exactly one item with [DropdownButton]'s value:
--   GENERAL. Either zero or 2 or more [DropdownMenuItem]s were detected
--   with the same value
--
-- CAUSE. kcet20262027.quota holds TWO active rows named GENERAL:
--
--   quo_id 5  GENERAL  created 09-09-2026 09:30  <- the real one, 2,510
--                                                   students and 2,632
--                                                   admissions use it
--   quo_id 3  GENERAL  created 07-10-2026 16:09  <- added by a master
--                                                   data import today
--
-- The quota dropdown is keyed by NAME, so two items share the value
-- GENERAL and Flutter asserts before the screen can paint. Nothing is
-- wrong with the data beyond the duplicate; the screen simply cannot
-- render a dropdown whose value matches more than one item.
--
-- The same import also added 7.5, GOVT and MANAGEMENT (quo_id 1, 2, 4).
-- Those are NOT exact duplicates -- the existing ones are GOVERNMENT
-- QUOTA and MANAGEMENT QUOTA -- so they do not crash anything. They are
-- left alone here: whether they are wanted is the office's call, not a
-- bug to fix.
--
-- WHAT THIS DOES
--   1. moves the ONE student and ONE admission already on quo_id 3 over
--      to quo_id 5, so nothing is left pointing at a hidden quota
--   2. deactivates quo_id 3. getQuotas() filters on activestatus = 1, so
--      it disappears from every dropdown. Not deleted -- the row is a
--      record of what the import did, and nothing has a foreign key to
--      quota (verified: no FK references it).
-- =====================================================================

-- BEFORE
SELECT quo_id, quoname, activestatus,
       (SELECT count(*) FROM kcet20262027.students s
         WHERE s.quo_id = q.quo_id AND s.activestatus = 1) AS students
  FROM kcet20262027.quota q
 WHERE quoname = 'GENERAL' ORDER BY quo_id;

-- 1. nothing may be left on the duplicate
UPDATE kcet20262027.students
   SET quo_id = 5
 WHERE quo_id = 3;

UPDATE public.admission
   SET quo_id = 5
 WHERE quo_id = 3;

-- 2. hide it from every dropdown
UPDATE kcet20262027.quota
   SET activestatus = 0
 WHERE quo_id = 3 AND quoname = 'GENERAL';

-- AFTER: exactly one active GENERAL, and nothing left on quo_id 3.
SELECT quo_id, quoname, activestatus,
       (SELECT count(*) FROM kcet20262027.students s
         WHERE s.quo_id = q.quo_id AND s.activestatus = 1) AS students
  FROM kcet20262027.quota q
 WHERE quoname = 'GENERAL' ORDER BY quo_id;

-- No active quota name may appear twice -- this is what the dropdown
-- needs. Any row returned here will crash a screen the same way.
SELECT quoname, count(*) AS active_rows
  FROM kcet20262027.quota
 WHERE activestatus = 1
 GROUP BY quoname HAVING count(*) > 1;
