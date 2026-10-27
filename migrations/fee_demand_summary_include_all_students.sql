-- Fee Demand class-summary: count ALL active students (not only students who
-- have a feedemand row). The class list + student_count are driven by the
-- students table; demand aggregates are LEFT-joined per (class, course), so a
-- class/student with no demand still shows up with student_count and 0 demand.
-- Run ONCE in the public schema (resolves each institution's schema at call time).

CREATE OR REPLACE FUNCTION public.get_fee_demand_summary(p_ins_id integer)
RETURNS TABLE(stuclass text, courname text, student_count bigint, fee_types text[], total_demand numeric, total_concession numeric, total_paid numeric, total_pending numeric, total_fine numeric)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;
  RETURN QUERY EXECUTE format($f$
    WITH pending_alloc AS (
      SELECT pd.dem_id,
             SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee,
             SUM(LEAST(pd.transtotalamount, COALESCE(fd.fineamount,0))) AS pending_fine
      FROM %1$I.paymentdetails pd
      JOIN %1$I.payment p ON p.pay_id = pd.pay_id
      LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
      WHERE p.ins_id = $1 AND p.paystatus = 'C'
        AND p.recon_status = 'P' AND p.activestatus = 1
      GROUP BY pd.dem_id
    ),
    stu_counts AS (
      SELECT s.stuclass::text AS stuclass, COALESCE(s.courname,'Other')::text AS courname,
             COUNT(DISTINCT s.stuadmno)::bigint AS student_count
      FROM %1$I.students s
      WHERE s.ins_id=$1 AND s.activestatus=1
      GROUP BY s.stuclass, COALESCE(s.courname,'Other')
    ),
    dem_agg AS (
      SELECT fd.stuclass::text AS stuclass,
             COALESCE(fd.courname,'Other')::text AS courname,
             ARRAY_AGG(DISTINCT fd.demfeetype::text ORDER BY fd.demfeetype::text)
               FILTER(WHERE fd.demfeetype IS NOT NULL AND fd.demfeetype<>'') AS fee_types,
             SUM(fd.feeamount) AS total_demand,
             SUM(fd.conamount) AS total_concession,
             GREATEST(
               COALESCE(SUM(fd.paidamount),0)
                 - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)
                 - COALESCE(SUM(pa.pending_fee),0),
               0) AS total_paid,
             SUM(fd.balancedue + COALESCE(pa.pending_fee, 0)) AS total_pending,
             GREATEST(
               COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)
                 - COALESCE(SUM(pa.pending_fine),0),
               0) AS total_fine
      FROM %1$I.feedemand fd
      LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
      WHERE fd.ins_id=$1 AND fd.activestatus=1
      GROUP BY fd.stuclass, COALESCE(fd.courname,'Other')
    )
    SELECT COALESCE(sc.stuclass, da.stuclass) AS stuclass,
           COALESCE(sc.courname, da.courname) AS courname,
           COALESCE(sc.student_count, 0)::bigint AS student_count,
           da.fee_types,
           COALESCE(da.total_demand, 0) AS total_demand,
           COALESCE(da.total_concession, 0) AS total_concession,
           COALESCE(da.total_paid, 0) AS total_paid,
           COALESCE(da.total_pending, 0) AS total_pending,
           COALESCE(da.total_fine, 0) AS total_fine
    FROM stu_counts sc
    FULL OUTER JOIN dem_agg da
      ON da.stuclass = sc.stuclass AND da.courname = sc.courname
    ORDER BY COALESCE(sc.courname, da.courname), COALESCE(sc.stuclass, da.stuclass)
  $f$, v) USING p_ins_id;
END; $$;
