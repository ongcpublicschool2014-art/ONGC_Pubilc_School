-- ============================================================================
-- Make Dashboard a grantable menu — backfill for roles configured before it was.
--
-- Dashboard used to be excluded from Roles & Access and force-included in the
-- sidebar, so it has no rolemenuaccess row for any role configured up to now.
-- The app no longer force-includes it (a role can be given a sidebar with no
-- Dashboard at all), which means every already-configured role would silently
-- lose the menu the moment the new build is installed.
--
-- This grants Dashboard to each role that is ALREADY configured — i.e. that has
-- at least one row — preserving exactly what those roles can see today. Roles
-- with no rows are untouched: no rows still means "never configured", and the
-- app falls back to its built-in defaults for them.
--
-- Run this BEFORE (or with) the build that makes Dashboard assignable.
-- Idempotent: ON CONFLICT DO NOTHING on the (ins_id, ur_id, menulabel) unique.
-- ============================================================================

INSERT INTO public.rolemenuaccess (ins_id, ur_id, menulabel, createdby, activestatus)
SELECT DISTINCT r.ins_id, r.ur_id, 'Dashboard', 'migration', 1
  FROM public.rolemenuaccess r
 WHERE r.activestatus = 1
   AND NOT EXISTS (
         SELECT 1 FROM public.rolemenuaccess d
          WHERE d.ins_id = r.ins_id
            AND d.ur_id  = r.ur_id
            AND d.menulabel = 'Dashboard')
ON CONFLICT (ins_id, ur_id, menulabel) DO NOTHING;

-- Verify: every configured role should now list Dashboard.
SELECT ins_id, ur_id,
       count(*)                                        AS menus_allowed,
       bool_or(menulabel = 'Dashboard')                AS has_dashboard
  FROM public.rolemenuaccess
 WHERE activestatus = 1
 GROUP BY ins_id, ur_id
 ORDER BY ins_id, ur_id;
