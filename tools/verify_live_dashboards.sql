-- ============================================================================
-- After LIVE_2026_10_13_DASHBOARD_FIGURES.sql -- every check, in ONE row.
-- ============================================================================
-- The Supabase editor keeps only the LAST result set, so a script with six
-- verification blocks shows you the sixth and throws away the rest. This is
-- all of them folded into a single statement.
--
-- Read-only. Nothing here writes.
--
-- The four booleans at the end must all be true, and rows_still_adrift 0.
-- ============================================================================

WITH f AS (
  SELECT COALESCE(SUM(fd.feeamount), 0)  AS fee,
         COALESCE(SUM(fd.fineamount), 0) AS fine_all,
         COALESCE(SUM(fd.fineamount)
           FILTER (WHERE fd.paidstatus = 'P' OR fd.paidamount > 0), 0) AS fine_paid
    FROM kcet20262027.feedemand fd
    JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
   WHERE fd.ins_id = 1 AND fd.activestatus = 1
),
gone AS (
  -- Demands belonging to students who have left. This IS the drop, and it is
  -- the answer to "why is the dashboard lower than yesterday".
  SELECT count(DISTINCT s.stu_id)       AS tc_students_excluded,
         COALESCE(SUM(fd.feeamount), 0) AS tc_demand_removed
    FROM kcet20262027.feedemand fd
    JOIN kcet20262027.students s ON s.stu_id = fd.stu_id
   WHERE fd.activestatus = 1 AND s.activestatus <> 1
),
adrift AS (
  SELECT count(*) AS rows_still_adrift
    FROM kcet20262027.feedemand fd
    JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
    LEFT JOIN (
      SELECT pd.dem_id,
             SUM(GREATEST(pd.transtotalamount - COALESCE(fd2.fineamount, 0), 0)) AS unrecon
        FROM kcet20262027.paymentdetails pd
        JOIN kcet20262027.payment p     ON p.pay_id = pd.pay_id
        JOIN kcet20262027.feedemand fd2 ON fd2.dem_id = pd.dem_id
       WHERE p.ins_id = 1 AND p.paystatus = 'C' AND p.recon_status = 'P'
         AND p.activestatus = 1 AND fd2.activestatus = 1
       GROUP BY pd.dem_id
    ) a ON a.dem_id = fd.dem_id
   WHERE fd.ins_id = 1 AND fd.activestatus = 1
     AND fd.reconbalancedue <> fd.balancedue + COALESCE(a.unrecon, 0)
)
SELECT
  -- What the cards now say.
  (public.get_fee_totals(1)->>'total_demand')::numeric  AS demand_now,
  (public.get_fee_totals(1)->>'total_paid')::numeric    AS collected_now,
  (public.get_fee_totals(1)->>'total_pending')::numeric AS outstanding_now,
  (public.get_fee_totals(1)->>'total_fine')::numeric    AS fine_now,

  -- Why they moved.
  gone.tc_students_excluded,
  gone.tc_demand_removed,
  f.fine_all  AS fine_total_on_demands,
  f.fine_paid AS fine_collected,

  -- Must all be true.
  (public.get_fee_totals(1)->>'total_demand')::numeric
    = ((public.get_fee_totals_by_seqtype(1)->'regular'->>'demand')::numeric
     + (public.get_fee_totals_by_seqtype(1)->'arrear'->>'demand')::numeric)
      AS card_agrees_with_drilldown,
  (public.get_fee_totals(1)->>'total_pending')::numeric
    = ((public.get_fee_totals_by_seqtype(1)->'regular'->>'pending')::numeric
     + (public.get_fee_totals_by_seqtype(1)->'arrear'->>'pending')::numeric)
      AS outstanding_agrees_with_drilldown,
  (SELECT bool_and(
            (e->>'total_demand')::numeric
              = (public.get_fee_totals((e->>'ins_id')::int)->>'total_demand')::numeric
            AND (e->>'total_collected')::numeric
              = (public.get_fee_totals((e->>'ins_id')::int)->>'total_paid')::numeric
            AND (e->>'total_pending')::numeric
              = (public.get_fee_totals((e->>'ins_id')::int)->>'total_pending')::numeric)
     FROM json_array_elements(public.get_super_admin_dashboard(NULL)) e)
      AS superadmin_matches_admin,
  (public.get_fee_totals(1)->>'total_demand')::numeric = f.fee - f.fine_all
      AS demand_is_fee_only,

  -- Must be 0.
  adrift.rows_still_adrift
  FROM f, gone, adrift;
