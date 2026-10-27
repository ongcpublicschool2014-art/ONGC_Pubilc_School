-- ############################################################################
--
--   EduCore360 -- LIVE UPDATE, 24-09-2026
--
--   Run the whole file, top to bottom, in the SQL editor on the LIVE project.
--   It refuses to run on TEST, so a mis-click costs nothing.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS RELEASE NEEDS FROM THE DATABASE
-- ----------------------------------------------------------------------------
-- Almost nothing. The session's work -- the class-ordering rule, the bank
-- delete guard, the Daily Collection print, the export buttons, the three new
-- reports, the per-tile dashboard access -- is all in the desktop build and
-- needs no schema change:
--
--   * dashboard tile grants reuse public.rolemenuaccess, storing keys like
--     'dash:collected' in the column the menu labels already use. The prefix
--     is what keeps a tile named "Quick Actions" from being read as a menu of
--     the same name.
--   * the new reports only READ -- public.admission and <schema>.tc_entry.
--
-- ONE thing does need doing here, and it is this file:
--
--   TWO NEW MENUS -- 'Admission Register' and 'TC Report'. A role that has
--   already been configured in Roles & Access has no row for a menu that did
--   not exist when it was configured, so on the new build those roles would
--   simply not see the reports, with nothing to say why. This grants both to
--   every role that is ALREADY configured, exactly as
--   rolemenuaccess_dashboard.sql did when Dashboard became assignable.
--
--   Roles with NO rows are left alone: no rows still means "never configured",
--   and the app falls back to its built-in defaults for them.
--
-- ----------------------------------------------------------------------------
-- BEFORE YOU DEPLOY THE BUILD -- READ THIS
-- ----------------------------------------------------------------------------
-- This release makes LIVE_RUN_20260921.sql (CLASS_TYPE.sql) REQUIRED, where it
-- was optional before. The dashboard's Total Students card and the Class screen
-- both SELECT class.classtype, which live does not have yet. Without it those
-- two break.
--
-- The class DROPDOWNS are safe either way -- they fall back to reading a TC
-- batch from its name -- but the dashboard card does not.
--
-- So the order for this release is:
--
--   1. LIVE_RUN_20260919.sql            still unrun
--   2. LIVE_RUN_20260921.sql            still unrun  <- now required
--   3. FIX_PAIDSTATUS_ON_APPROVAL.sql   still unrun
--   4. LIVE_FIX_CLASS_NAME_MISMATCH.sql still unrun
--   5. THIS FILE
--   6. NOTIFY pgrst, 'reload schema';
--
-- LIVE_ADVANCE_LOAD_20260923.sql (the 149 student advances) is independent of
-- the build -- run it whenever you intend that money to become adjustable.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RUN, AND SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- It only INSERTs grant rows, and only for roles that already have some. No
-- existing grant is changed or removed, and ON CONFLICT DO NOTHING makes a
-- second run a no-op.
--
-- To undo:
--   DELETE FROM public.rolemenuaccess
--    WHERE createdby = 'migration 20260924'
--      AND menulabel IN ('Admission Register', 'TC Report');
--
-- ----------------------------------------------------------------------------
-- WHAT YOU SHOULD SEE
-- ----------------------------------------------------------------------------
-- One row per configured role, with has_admission_register and has_tc_report
-- both true. A role missing from the list has never been configured and will
-- see the reports through the built-in defaults.
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
-- 1 -- grant the two new report menus to every already-configured role
-- ----------------------------------------------------------------------------
INSERT INTO public.rolemenuaccess (ins_id, ur_id, menulabel, createdby, activestatus)
SELECT DISTINCT r.ins_id, r.ur_id, m.label, 'migration 20260924', 1
  FROM public.rolemenuaccess r
 CROSS JOIN (VALUES ('Admission Register'), ('TC Report')) AS m(label)
 WHERE r.activestatus = 1
   AND NOT EXISTS (
         SELECT 1 FROM public.rolemenuaccess d
          WHERE d.ins_id = r.ins_id
            AND d.ur_id  = r.ur_id
            AND d.menulabel = m.label)
ON CONFLICT (ins_id, ur_id, menulabel) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 2 -- what each configured role can now see
-- ----------------------------------------------------------------------------
SELECT a.ins_id,
       a.ur_id,
       COALESCE(u.urname, '(role not in custuserroles)')      AS role,
       count(*) FILTER (WHERE a.menulabel NOT LIKE 'dash:%')  AS menus_allowed,
       count(*) FILTER (WHERE a.menulabel LIKE 'dash:%')      AS dashboard_tiles,
       bool_or(a.menulabel = 'Admission Register')            AS has_admission_register,
       bool_or(a.menulabel = 'TC Report')                     AS has_tc_report
  FROM public.rolemenuaccess a
  LEFT JOIN public.custuserroles u
         ON u.ur_id = a.ur_id AND u.ins_id = a.ins_id
 WHERE a.activestatus = 1
 GROUP BY a.ins_id, a.ur_id, u.urname
 ORDER BY a.ins_id, a.ur_id;
