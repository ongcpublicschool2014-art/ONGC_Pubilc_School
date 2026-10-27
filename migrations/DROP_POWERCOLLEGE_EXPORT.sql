-- ############################################################################
-- EduCore360 -- DROP THE EXPORT REPORT'S FUNCTIONS, 19-09-2026
--
-- The Export report (Reports -> Export, the PowerCollege per-line-item export)
-- has been removed from the desktop app: the sidebar entry, the tab and about
-- 660 lines behind it are gone. These two functions existed only to feed it
-- and now have no caller.
--
--   public.get_powercollege_export_json(text, integer, date, date)
--   public.get_powercollege_export(text, integer, date, date)
--
-- Checked before writing this: nothing in the desktop app, nothing in the edge
-- functions, and no other database function references them -- only the _json
-- wrapper calls the base one, which is why it is dropped first.
--
-- ---------------------------------------------------------------------------
-- THIS IS THE ONE FILE HERE THAT DESTROYS SOMETHING. A dropped function cannot
-- be brought back by re-running anything; it has to be re-created from its
-- source. Run the PRE-FLIGHT below FIRST and keep the output -- that output is
-- the restore script. The same bodies are also in this repo's git history and
-- were in C:\pg_backups\complete_setup.sql before this change.
--
-- If the parent mobile app or any outside integration calls either function,
-- STOP: they will start failing the moment this runs.
-- ---------------------------------------------------------------------------
-- ############################################################################


-- ############################################################################
-- PRE-FLIGHT (READ-ONLY) -- the current source of both functions. SAVE THIS.
-- Two rows expected. No rows means they are already gone.
-- ############################################################################
SELECT p.proname,
       pg_get_functiondef(p.oid) AS restore_this_if_you_need_it_back
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('get_powercollege_export', 'get_powercollege_export_json')
 ORDER BY p.proname;


-- ############################################################################
-- DROP -- the wrapper first: it calls the one below it.
-- ############################################################################
DROP FUNCTION IF EXISTS public.get_powercollege_export_json(text, integer, date, date);
DROP FUNCTION IF EXISTS public.get_powercollege_export(text, integer, date, date);

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- VERIFY -- must return NO ROWS.
-- ############################################################################
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname LIKE 'get_powercollege%';
