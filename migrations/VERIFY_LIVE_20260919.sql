-- ############################################################################
-- ############################################################################
--
--   EduCore360 -- DID LIVE_RUN_20260919.sql ACTUALLY LAND?
--   Read-only. Safe on LIVE.
--
-- ############################################################################
-- ############################################################################
--
-- Run this in the Supabase SQL editor AFTER running LIVE_RUN_20260919.sql.
--
-- It is ONE query on purpose. The editor shows only the last statement's
-- result and does not show RAISE NOTICE at all, so anything split across
-- statements would be invisible. Every check returns a row here.
--
-- READ THE "status" COLUMN. Everything should say OK.
-- Anything that says MISSING / STILL THERE / FAIL names what did not land,
-- and the part it came from.
--
-- It writes nothing, creates nothing and reads no student data -- only the
-- catalogue, plus one COUNT over feedemand for the repair check.
-- ############################################################################

WITH
-- Every per-year institution schema on this database.
yrs AS (
  SELECT table_schema AS s
    FROM information_schema.tables
   WHERE table_name = 'students'
     AND table_schema NOT IN ('pg_catalog', 'information_schema')
),
n_yrs AS (SELECT count(*)::int AS n FROM yrs),

-- A public function exists?
fn AS (
  SELECT p.proname AS name, p.prosrc
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public'
),

-- Does every year schema have this table?
tbl_cov AS (
  SELECT t.tname,
         count(*) FILTER (WHERE to_regclass(format('%I.%I', y.s, t.tname)) IS NOT NULL)::int AS have
    FROM yrs y
    CROSS JOIN (VALUES ('advance_collection'), ('advance_detail'), ('advadjustment'),
                       ('misc_collection')) AS t(tname)
   GROUP BY t.tname
),

-- Does every year schema have this column?
col_cov AS (
  SELECT c.tname, c.cname,
         count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM information_schema.columns ic
            WHERE ic.table_schema = y.s AND ic.table_name = c.tname
              AND ic.column_name = c.cname))::int AS have
    FROM yrs y
    CROSS JOIN (VALUES ('students', 'preadmission'),
                       ('feedemand', 'arrearclass'),
                       ('feedemand', 'collectible')) AS c(tname, cname)
   GROUP BY c.tname, c.cname
),

checks AS (
  -- ── PART 1 -- carried forward from 12-14 September ──────────────────────
  SELECT 1 AS part, 'reconcile_payments_batch exists' AS check,
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='reconcile_payments_batch')
              THEN 'OK' ELSE 'MISSING' END AS status
  UNION ALL SELECT 1, 'mark_payment_notifications_read exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='mark_payment_notifications_read') THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 1, 'delete_stale_initiated_payments exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='delete_stale_initiated_payments') THEN 'OK' ELSE 'MISSING' END

  -- ── PART 2 -- Advance Collection ────────────────────────────────────────
  UNION ALL SELECT 2, 'advance_collection table in every year schema',
         CASE WHEN (SELECT have FROM tbl_cov WHERE tname='advance_collection') = (SELECT n FROM n_yrs)
              THEN 'OK' ELSE 'MISSING in ' ||
                   ((SELECT n FROM n_yrs) - (SELECT have FROM tbl_cov WHERE tname='advance_collection'))::text
                   || ' of ' || (SELECT n FROM n_yrs)::text || ' schema(s)' END
  UNION ALL SELECT 2, 'advance_detail table in every year schema',
         CASE WHEN (SELECT have FROM tbl_cov WHERE tname='advance_detail') = (SELECT n FROM n_yrs)
              THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 2, 'advadjustment table in every year schema',
         CASE WHEN (SELECT have FROM tbl_cov WHERE tname='advadjustment') = (SELECT n FROM n_yrs)
              THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 2, 'save_advance_collection exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='save_advance_collection') THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 2, 'adjust_advance exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='adjust_advance') THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 2, 'refund_advance exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='refund_advance') THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 2, 'void_advance_receipt exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='void_advance_receipt') THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 2, 'void_receipt_with_advance exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='void_receipt_with_advance') THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 2, 'reconcile_advance_batch exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='reconcile_advance_batch') THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 2, 'void_receipt_with_advance restores reconbalancedue (the 80-line version)',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='void_receipt_with_advance'
                             AND prosrc LIKE '%v_host_restores%') THEN 'OK' ELSE 'FAIL - old short version' END
  UNION ALL SELECT 2, 'feedemand.collectible in every year schema',
         CASE WHEN (SELECT have FROM col_cov WHERE tname='feedemand' AND cname='collectible') = (SELECT n FROM n_yrs)
              THEN 'OK' ELSE 'MISSING' END

  -- ── PART 3 -- reports: leavers out, TC filter in ────────────────────────
  UNION ALL SELECT 3, 'tc_student_filter exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='tc_student_filter') THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 3, 'get_pending_payment_report has the p_tc overload',
         CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
                            WHERE ns.nspname='public' AND p.proname='get_pending_payment_report'
                              AND pg_get_function_identity_arguments(p.oid) LIKE '%p_tc%')
              THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 3, 'get_pending_details_report has the p_tc overload',
         CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
                            WHERE ns.nspname='public' AND p.proname='get_pending_details_report'
                              AND pg_get_function_identity_arguments(p.oid) LIKE '%p_tc%')
              THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 3, 'get_consolidated_status_report has the p_tc overload',
         CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
                            WHERE ns.nspname='public' AND p.proname='get_consolidated_status_report'
                              AND pg_get_function_identity_arguments(p.oid) LIKE '%p_tc%')
              THEN 'OK' ELSE 'MISSING' END

  -- ── PART 4 -- course transfer moves the advance ─────────────────────────
  UNION ALL SELECT 4, 'transfer_course_with_credit reaches advance_collection',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='transfer_course_with_credit'
                             AND prosrc LIKE '%advance_collection%') THEN 'OK' ELSE 'FAIL - old version' END

  -- ── PART 5 -- roll-number change reaches everything ─────────────────────
  UNION ALL SELECT 5, 'save_rollno_change reaches advance_collection',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='save_rollno_change'
                             AND prosrc LIKE '%advance_collection%') THEN 'OK' ELSE 'FAIL - old version' END
  UNION ALL SELECT 5, 'save_rollno_change reaches misc_collection',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='save_rollno_change'
                             AND prosrc LIKE '%misc_collection%') THEN 'OK' ELSE 'FAIL - old version' END

  -- ── PART 6 -- pre-admission ─────────────────────────────────────────────
  UNION ALL SELECT 6, 'public.admission.preadmission column',
         CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                            WHERE table_schema='public' AND table_name='admission'
                              AND column_name='preadmission') THEN 'OK' ELSE 'MISSING' END
  UNION ALL SELECT 6, 'students.preadmission in every year schema',
         CASE WHEN (SELECT have FROM col_cov WHERE tname='students' AND cname='preadmission') = (SELECT n FROM n_yrs)
              THEN 'OK' ELSE 'MISSING in ' ||
                   ((SELECT n FROM n_yrs) - (SELECT have FROM col_cov WHERE tname='students' AND cname='preadmission'))::text
                   || ' of ' || (SELECT n FROM n_yrs)::text || ' schema(s)' END
  UNION ALL SELECT 6, 'create_institution_schema gives NEW schemas the column',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='create_institution_schema'
                             AND prosrc LIKE '%preadmission%') THEN 'OK' ELSE 'FAIL - old version' END
  UNION ALL SELECT 6, 'generate_feedemand_for_class skips pre-admitted students',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='generate_feedemand_for_class'
                             AND prosrc LIKE '%preadmission%') THEN 'OK' ELSE 'FAIL - old version' END
  UNION ALL SELECT 6, 'feedemand.arrearclass in every year schema',
         CASE WHEN (SELECT have FROM col_cov WHERE tname='feedemand' AND cname='arrearclass') = (SELECT n FROM n_yrs)
              THEN 'OK' ELSE 'MISSING' END

  -- ── PART 7 -- the Export report is gone (DESTRUCTIVE part) ──────────────
  UNION ALL SELECT 7, 'get_powercollege_export dropped',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='get_powercollege_export')
              THEN 'STILL THERE - part 7 not run' ELSE 'OK' END
  UNION ALL SELECT 7, 'get_powercollege_export_json dropped',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='get_powercollege_export_json')
              THEN 'STILL THERE - part 7 not run' ELSE 'OK' END

  -- PART 8 (the demand/course repair) is NOT checked here: it needs a scan of
  -- feedemand joined to the class master, which is a different shape of query.
  -- The standing guard at the end of migrations/FIX_DEMAND_COURSE_MISMATCH.sql
  -- is what reports it.

  -- ── MUST BE ABSENT -- the TEST-only year-rollover work ──────────────────
  UNION ALL SELECT 9, 'rollover_preview NOT on live',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='rollover_preview')
              THEN 'FAIL - TEST-only code reached live' ELSE 'OK' END
  UNION ALL SELECT 9, '_rollover_copy NOT on live',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE name='_rollover_copy')
              THEN 'FAIL - TEST-only code reached live' ELSE 'OK' END
  UNION ALL SELECT 9, 'students.arrearonly NOT on live',
         CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                            WHERE table_name='students' AND column_name='arrearonly'
                              AND table_schema NOT IN ('pg_catalog','information_schema'))
              THEN 'FAIL - TEST-only column reached live' ELSE 'OK' END
)
SELECT part, check, status FROM checks
ORDER BY part,
         CASE WHEN status = 'OK' THEN 1 ELSE 0 END,   -- failures first within a part
         check;
