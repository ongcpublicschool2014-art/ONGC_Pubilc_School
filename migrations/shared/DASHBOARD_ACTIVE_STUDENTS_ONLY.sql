-- ============================================================================
-- Dashboard: Fees Due / Collected / Outstanding count ACTIVE students only.
-- ============================================================================
-- WHAT WAS WRONG. get_fee_totals and get_fee_totals_by_seqtype sum feedemand
-- without ever touching students, so every demand raised against someone who
-- has since left -- a TC-issued student -- was still in the dashboard's
-- figures. The reports have excluded them all along: every report RPC takes
-- p_tc and defaults to 'NOTC', which is tc_student_filter's
-- 's.activestatus = 1'.
--
-- So the dashboard and the reports have been answering different questions
-- with the same words, and the dashboard's were the larger numbers.
--
-- WHAT THIS DOES. Joins students and keeps activestatus = 1, in BOTH
-- functions and in the pending-approval subquery each of them uses. The same
-- definition of "active" as tc_student_filter, written the same way, so the
-- three cannot drift.
--
-- BOTH, not one. get_fee_totals feeds the Total Fees Due / Total Collected /
-- Outstanding cards; get_fee_totals_by_seqtype feeds the Regular-vs-Arrear
-- breakdown you get by tapping one. Fixing only the card would make the
-- drill-down contradict the number that opened it.
--
-- THE NUMBERS WILL DROP. That is the point, but it means the dashboard will
-- not match a figure anybody wrote down yesterday. PART 3 prints the before
-- and after so the difference can be seen and explained rather than
-- discovered.
--
-- NOT a demand-level filter: a demand belonging to an active student is
-- counted in full. Only the student's own status is consulted.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 0 =
-- What the cards say TODAY, before anything changes. Keep this output.
-- ===========================================================================

SELECT 'BEFORE' AS state,
       (public.get_fee_totals(1)->>'total_demand')::numeric  AS total_demand,
       (public.get_fee_totals(1)->>'total_paid')::numeric    AS total_paid,
       (public.get_fee_totals(1)->>'total_pending')::numeric AS total_pending;


-- =================================================================== PART 1 =
-- The three headline totals.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_fee_totals(p_ins_id integer)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v text;
  v_total_demand numeric := 0;
  v_total_paid numeric := 0;
  v_total_fine numeric := 0;
  v_total_pending numeric := 0;
  v_pending_approval_fee numeric := 0;
  v_pending_approval_fine numeric := 0;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN
    RETURN json_build_object('total_demand',0,'total_pending',0,'total_paid',0,'total_fine',0);
  END IF;

  -- Pending-approval allocations, narrowed to active students for the same
  -- reason as the totals below: a figure subtracted from an active-only total
  -- has to be an active-only figure, or the subtraction takes away money that
  -- was never added.
  EXECUTE format('
    SELECT COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)),0),
           COALESCE(SUM(LEAST(pd.transtotalamount, COALESCE(fd.fineamount,0))),0)
    FROM %1$I.paymentdetails pd
    JOIN %1$I.payment p ON p.pay_id = pd.pay_id
    JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
    JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
    WHERE p.ins_id=$1 AND p.paystatus=''C'' AND p.recon_status=''P'' AND p.activestatus=1
      AND fd.activestatus=1
  ', v) INTO v_pending_approval_fee, v_pending_approval_fine USING p_ins_id;

  -- ACTIVE STUDENTS ONLY. s.activestatus = 1 is exactly what
  -- tc_student_filter('NOTC') produces, which is what every report uses
  -- unless asked for leavers.
  EXECUTE format('
    SELECT COALESCE(SUM(fd.feeamount),0),
           COALESCE(SUM(fd.paidamount),0),
           COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus=''P'' OR fd.paidamount > 0),0),
           COALESCE(SUM(fd.reconbalancedue),0)
    FROM %1$I.feedemand fd
    JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
    WHERE fd.ins_id=$1 AND fd.activestatus=1
  ', v) INTO v_total_demand, v_total_paid, v_total_fine, v_total_pending USING p_ins_id;

  v_total_paid := GREATEST(v_total_paid - v_pending_approval_fee - v_pending_approval_fine, 0);
  v_total_fine := GREATEST(v_total_fine - v_pending_approval_fine, 0);

  RETURN json_build_object(
    'total_demand',  v_total_demand,
    'total_paid',    v_total_paid,
    'total_pending', v_total_pending,
    'total_fine',    v_total_fine
  );
END; $function$;


-- =================================================================== PART 2 =
-- The Regular / Arrear breakdown behind the same cards.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_fee_totals_by_seqtype(p_ins_id integer)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE v text; r json;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN NULL; END IF;
  EXECUTE format($f$
    WITH pending_alloc AS (
      SELECT pd.dem_id,
             SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee,
             SUM(LEAST(pd.transtotalamount, COALESCE(fd.fineamount,0)))       AS pending_fine
      FROM %1$I.paymentdetails pd
      JOIN %1$I.payment p    ON p.pay_id = pd.pay_id
      JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
      JOIN %1$I.students s   ON s.stu_id = fd.stu_id AND s.activestatus = 1
      WHERE p.ins_id=$1 AND p.paystatus='C' AND p.recon_status='P' AND p.activestatus=1
        AND fd.activestatus=1
      GROUP BY pd.dem_id
    ),
    agg AS (
      SELECT CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR'
                  THEN 'arrear' ELSE 'regular' END AS seqtype,
             COALESCE(SUM(fd.feeamount),0) AS demand,
             GREATEST(
               COALESCE(SUM(fd.paidamount),0)
                 - COALESCE(SUM(pa.pending_fee),0)
                 - COALESCE(SUM(pa.pending_fine),0), 0) AS paid,
             COALESCE(SUM(fd.reconbalancedue),0) AS pending
      FROM %1$I.feedemand fd
      JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
      LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
      WHERE fd.ins_id=$1 AND fd.activestatus=1
      GROUP BY 1
    )
    SELECT json_object_agg(seqtype,
             json_build_object('demand', demand, 'paid', paid, 'pending', pending))
    FROM agg
  $f$, v) INTO r USING p_ins_id;
  RETURN COALESCE(r, '{}'::json);
END; $function$;


-- ------------------------------------------------------------- VERIFY ------
-- 1. AFTER. Compare against the BEFORE row printed at the top.
SELECT 'AFTER' AS state,
       (public.get_fee_totals(1)->>'total_demand')::numeric  AS total_demand,
       (public.get_fee_totals(1)->>'total_paid')::numeric    AS total_paid,
       (public.get_fee_totals(1)->>'total_pending')::numeric AS total_pending;

-- 2. What was removed, and whose it was. Demands belonging to students who
--    have left -- this is the difference, itemised.
SELECT count(DISTINCT s.stu_id)        AS students_excluded,
       count(*)                        AS demands_excluded,
       COALESCE(SUM(fd.feeamount),0)   AS demand_removed,
       COALESCE(SUM(fd.reconbalancedue),0) AS outstanding_removed
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id
 WHERE fd.activestatus = 1 AND s.activestatus <> 1;

-- 3. The card and its drill-down must agree. Expect both true.
SELECT
  (public.get_fee_totals(1)->>'total_demand')::numeric
    = ((public.get_fee_totals_by_seqtype(1)->'regular'->>'demand')::numeric
     + (public.get_fee_totals_by_seqtype(1)->'arrear'->>'demand')::numeric)
      AS demand_agrees,
  (public.get_fee_totals(1)->>'total_pending')::numeric
    = ((public.get_fee_totals_by_seqtype(1)->'regular'->>'pending')::numeric
     + (public.get_fee_totals_by_seqtype(1)->'arrear'->>'pending')::numeric)
      AS pending_agrees;
