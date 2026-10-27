-- ############################################################################
-- EduCore360 -- REPORTS: LEAVERS OUT BY DEFAULT, PLUS A TC FILTER, 18-09-2026
--
-- Two things, in one file:
--
-- (A) A student who has left is no longer counted in the outstanding-dues
--     reports. They still own their demand rows, so Pending Payment, Pending
--     Details, Consolidated Status and the DCB Register were carrying money
--     nobody is going to collect.
--
-- (B) Those four reports get a TC filter -- Without TC / TC Issued / All
--     Students -- so the leavers can still be looked at deliberately.
--
-- students.activestatus is what the Transfer Certificate screen writes when a
-- TC is issued, and what it sets back to 1 when a TC is cancelled, so it is
-- the definition of "holds a TC" used here:
--     1 Active, 2 Discontinued, 3 Transferred, 4 Completed, 5 Others,
--     9 Terminated.
--
-- NOTHING IS DROPPED AND NO SIGNATURE CHANGES. The existing 1-arg / 2-arg
-- functions keep working exactly as they do now (a desktop copy that has not
-- been updated yet is unaffected); the new behaviour arrives as OVERLOADS that
-- take the filter. PostgREST picks the one whose argument names match the
-- call, so the two never collide.
--
--   public.tc_student_filter(text)                            NEW helper
--   public.get_fee_report_data(int, text)                     NEW overload
--   public.get_pending_payment_report(text, int, text)        NEW overload
--   public.get_consolidated_status_report(text, int, text)    NEW overload
--   public.get_pending_details_report(text, int, text)        NEW overload
--   public.get_pending_payment_report(text, int)              now a wrapper
--   public.get_consolidated_status_report(text, int)          now a wrapper
--   public.get_pending_details_report(text, int)              now a wrapper
--   public.get_pending_export_data(int)                       active only
--
-- SAFE TO RE-RUN. No row is inserted, updated or deleted: this changes code
-- only. CREATE OR REPLACE keeps the existing EXECUTE grants; the new functions
-- are granted explicitly at the end.
--
-- DELIBERATELY NOT CHANGED -- these report money that was actually received,
-- and a receipt is history. Dropping a leaver's past receipts would stop the
-- day's total matching the bank:
--   * get_daily_collection_report / _unreconciled  (Daily Collection)
--   * get_powercollege_export                      (Reports -> Export)
--   * get_student_ledger_report                    (Student Ledger deliberately
--     still opens a leaver's ledger, and the screen marks them TC ISSUED)
--
-- Applied and checked on the TEST project first (a full restore of live).
-- ############################################################################


-- ############################################################################
-- BEFORE (READ-ONLY) -- what the leavers are worth on THIS database. Run this
-- first and keep the output.
-- ############################################################################
DO $before$
DECLARE r RECORD; v_stu int; v_dem int; v_bal numeric;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'feedemand'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format($q$
      SELECT count(DISTINCT s.stu_id), count(fd.dem_id), COALESCE(sum(fd.balancedue),0)
        FROM %I.students s
        JOIN %I.feedemand fd ON fd.stu_id = s.stu_id AND fd.ins_id = s.ins_id
                            AND fd.activestatus = 1
       WHERE s.activestatus <> 1 $q$, r.s, r.s) INTO v_stu, v_dem, v_bal;
    RAISE NOTICE '%: % students with a TC, % live demands, % pending',
                 r.s, v_stu, v_dem, v_bal;
  END LOOP;
END $before$;


-- ----------------------------------------------------------------------------
-- 1 -- public.tc_student_filter(text)
--
-- The one place the three filter modes are defined. It returns a SQL fragment,
-- never the caller's text, so the reports below cannot be injected into.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tc_student_filter(p_tc TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $tcf$
  SELECT CASE UPPER(COALESCE(TRIM(p_tc), 'NOTC'))
           -- Students who hold a TC: they have left, so their dues are shown
           -- only when they are asked for.
           WHEN 'TC'  THEN 's.activestatus <> 1'
           -- Everybody, TC or not.
           WHEN 'ALL' THEN 'TRUE'
           -- Default, and what every report shows unless told otherwise.
           ELSE 's.activestatus = 1'
         END;
$tcf$;


-- ----------------------------------------------------------------------------
-- 2 -- public.get_fee_report_data(integer, text)   NEW OVERLOAD
--
-- Feeds the DCB Register and the Student Ledger picker. The app calls this one
-- with 'ALL' and does the filtering on screen, because the Student Ledger must
-- be able to open a student who has left while the DCB Register hides them --
-- one load, both behaviours. It returns one extra field, stuactive, which is
-- how the screen tells them apart and how it marks a ledger TC ISSUED.
--
-- The 1-arg form is untouched and still returns active students only.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_fee_report_data(p_ins_id integer, p_tc text) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $gfrd$
DECLARE v text; r json; v_stu text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN '[]'::json; END IF;
  v_stu := public.tc_student_filter(p_tc);
  EXECUTE format('SELECT json_agg(t) FROM (SELECT fd.fee_id,fd.stu_id,fd.feeamount,fd.conamount,fd.paidamount,fd.balancedue,fd.reconbalancedue,fd.paidstatus,fd.stuclass,fd.courname,fd.stuadmno,fd.demfeetype,fd.demfeeterm,fd.activestatus,s.stuname,s.activestatus AS stuactive,s.stuclass AS stu_class,s.courname AS stu_course FROM %1$I.feedemand fd JOIN %1$I.students s ON s.stu_id=fd.stu_id AND s.ins_id=fd.ins_id AND %2$s WHERE fd.ins_id=$1 AND fd.activestatus=1 ORDER BY fd.stuadmno) t', v, v_stu) INTO r USING p_ins_id;
  RETURN COALESCE(r, '[]'::json);
END; $gfrd$;


-- ----------------------------------------------------------------------------
-- 3 -- public.get_pending_payment_report(text, int, text)   NEW OVERLOAD
-- Reports -> Pending Payment.
-- The students join is now whatever tc_student_filter() returns.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
    p_schema TEXT, p_ins_id INT, p_tc TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json; v_stu text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.seqtype, t.stuadmno), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  fd.demfeeterm::TEXT AS semester,
                  -- Regular vs Arrear, same rule as Fee Collection and Fee
                  -- Concession: anything not explicitly ARREAR counts as
                  -- REGULAR, so a null/blank demseqtype never hides a due.
                  (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END)::TEXT AS seqtype,
                  s.admname::TEXT AS admname, s.stuadmno::TEXT AS stuadmno, s.stuname::TEXT AS stuname,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  s.quoname::TEXT AS quoname, s.stumobile::TEXT AS stumobile
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, fd.demfeeterm,
                   (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END),
                   s.admname, s.stuadmno, s.stuname, s.quoname, s.stumobile
          -- Keep a group that has nothing pending but DID receive a concession:
          -- dropping it also dropped its conamount, so the report's CON. AMT
          -- total came out short of SUM(feedemand.conamount).
          HAVING  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0)) <> 0
             OR   COALESCE(SUM(fd.conamount), 0) <> 0
        ) t
    $f$, p_schema, p_ins_id, v_stu) INTO r;
    RETURN r;
END $$;

-- ----------------------------------------------------------------------------
-- 4 -- public.get_consolidated_status_report(text, int, text)   NEW OVERLOAD
-- Reports -> Consolidated Status.
-- The students join is now whatever tc_student_filter() returns.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(
    p_schema TEXT, p_ins_id INT, p_tc TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json; v_stu text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    EXECUTE format($f$
        WITH class_strength AS (
            SELECT courname, stuclass, COUNT(DISTINCT stu_id)::INT AS strength
            FROM   %1$I.students WHERE ins_id = %2$L AND activestatus = 1
            GROUP BY courname, stuclass
        ),
        pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.category, t.type), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  cs.strength,
                  fd.demfeeterm::TEXT AS semester,
                  -- category = admission type (e.g. GOVERNMENT QUOTA / MANAGEMENT QUOTA)
                  COALESCE(NULLIF(s.admname, ''), 'GENERAL')::TEXT AS category,
                  COUNT(DISTINCT s.stu_id)::INT AS stud_count,
                  (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                  SUM(fd.feeamount)::NUMERIC AS due,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  SUM(fd.feeamount)::NUMERIC AS net_demand,
                  -- Paid = fee-only, approved-only (pending-approval amounts are subtracted)
                  GREATEST(
                    COALESCE(SUM(fd.paidamount),0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)
                      - COALESCE(SUM(pa.pending_fee),0),
                    0
                  )::NUMERIC AS paid,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS balance
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN class_strength cs
                 ON cs.courname = s.courname AND cs.stuclass = s.stuclass
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, cs.strength,
                   fd.demfeeterm, COALESCE(NULLIF(s.admname, ''), 'GENERAL'),
                   (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)
        ) t
    $f$, p_schema, p_ins_id, v_stu) INTO r;
    RETURN r;
END $$;

-- ----------------------------------------------------------------------------
-- 5 -- public.get_pending_details_report(text, int, text)   NEW OVERLOAD
-- Reports -> Pending Details.
-- The students join is now whatever tc_student_filter() returns.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pending_details_report(
    p_schema TEXT, p_ins_id INT, p_tc TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json; v_stu text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        ),
        per_type AS (
          SELECT  s.courname::TEXT                                  AS courname,
                  s.stuclass::TEXT                                  AS stuclass,
                  s.stuadmno::TEXT                                  AS stuadmno,
                  s.stuname::TEXT                                   AS stuname,
                  -- Category on the printed sheet is the student's quota.
                  COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL')::TEXT   AS category,
                  COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS')::TEXT AS feetype,
                  -- REGULAR vs ARREAR, so the report can be filtered to one or
                  -- the other. NULL is reported as REGULAR: older rows predate
                  -- the column and are all current-year demands.
                  COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')::TEXT AS demseqtype,
                  SUM(fd.feeamount)::NUMERIC                        AS demand,
                  SUM(fd.feeamount - COALESCE(fd.conamount, 0))::NUMERIC AS net_demand,
                  GREATEST(
                    COALESCE(SUM(fd.paidamount), 0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus = 'P' OR fd.paidamount > 0), 0)
                      - COALESCE(SUM(pa.pending_fee), 0),
                    0
                  )::NUMERIC                                        AS collection,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, s.stuadmno, s.stuname,
                   COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL'),
                   COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS'),
                   COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')
        )
        -- Only students who actually owe something. Their OTHER fee types are
        -- still returned, because the Total Demand / Collection columns are
        -- whole-student figures, not just the unpaid slice.
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.stuadmno, t.feetype, t.demseqtype), '[]'::json)
        FROM (
          SELECT * FROM per_type
          WHERE  stuadmno IN (SELECT stuadmno FROM per_type
                               GROUP BY stuadmno HAVING SUM(pending) <> 0)
        ) t
    $f$, p_schema, p_ins_id, v_stu) INTO r;
    RETURN r;
END $$;


-- ----------------------------------------------------------------------------
-- 6 -- the original 2-arg forms become wrappers
--
-- A desktop copy that has not been updated yet calls these. They now mean
-- "without TC", which is the same set of students the report should have been
-- showing all along, and there is only one copy of each report body to keep.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pending_payment_report(p_schema TEXT, p_ins_id INT)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w1$
  SELECT public.get_pending_payment_report(p_schema, p_ins_id, 'NOTC');
$w1$;

CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(p_schema TEXT, p_ins_id INT)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w2$
  SELECT public.get_consolidated_status_report(p_schema, p_ins_id, 'NOTC');
$w2$;

CREATE OR REPLACE FUNCTION public.get_pending_details_report(p_schema TEXT, p_ins_id INT)
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w3$
  SELECT public.get_pending_details_report(p_schema, p_ins_id, 'NOTC');
$w3$;


-- ----------------------------------------------------------------------------
-- 7 -- public.get_pending_export_data(integer)
-- The pending-fee export on the Fee Collection screen. No filter on that
-- screen, so it is simply active students.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_pending_export_data(p_ins_id integer) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; r json;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN '[]'::json; END IF;
  EXECUTE format('SELECT json_agg(t) FROM (SELECT fd.stu_id,fd.stuadmno,fd.stuclass,fd.courname,fd.demfeetype,fd.demfeeterm,fd.feeamount,fd.conamount,fd.balancedue,fd.reconbalancedue,fd.paidstatus,s.stuname FROM %I.feedemand fd JOIN %I.students s ON s.stu_id=fd.stu_id AND s.ins_id=fd.ins_id AND s.activestatus=1 WHERE fd.ins_id=$1 AND fd.activestatus=1 ORDER BY fd.courname,fd.stuclass,fd.stuadmno) t', v, v) INTO r USING p_ins_id;
  RETURN COALESCE(r, '[]'::json);
END; $$;


GRANT EXECUTE ON FUNCTION public.tc_student_filter(TEXT)                           TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_fee_report_data(integer, text)                TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pending_payment_report(TEXT, INT, TEXT)       TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_consolidated_status_report(TEXT, INT, TEXT)   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pending_details_report(TEXT, INT, TEXT)       TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- VERIFY -- anon_can_execute must read t on every row.
-- ############################################################################
SELECT p.proname,
       pg_get_function_identity_arguments(p.oid) AS args,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('tc_student_filter', 'get_fee_report_data', 'get_pending_export_data',
                     'get_pending_payment_report', 'get_consolidated_status_report',
                     'get_pending_details_report')
 ORDER BY p.proname, args;

-- The three modes, on this database. without_tc is what the report shows now,
-- and without_tc + tc_issued must add up to all_students.
SELECT (SELECT sum((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_payment_report(s, i, 'NOTC')) e) AS without_tc,
       (SELECT sum((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_payment_report(s, i, 'TC')) e)   AS tc_issued,
       (SELECT sum((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_payment_report(s, i, 'ALL')) e)  AS all_students
  FROM (SELECT get_institution_schema(1) AS s, 1 AS i) q;
