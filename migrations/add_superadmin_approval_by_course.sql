-- BUG: the superadmin "Pending Approval" drilldown showed "No data" for the
-- same reason as the collection drilldown — it read tenant payment/
-- paymentdetails/feedemand DIRECTLY as the anon role (which can't) and did the
-- grouping + N+1 fine lookups in Dart.
--
-- Fix: SECURITY DEFINER RPC that groups pending-approval money by course/class
-- server-side. approval = SUM(GREATEST(pd.transtotalamount - fineamount, 0))
-- over payments that are collected but not yet reconciled (recon_status='P') —
-- the same formula as get_super_admin_dashboard_v2.pending_approval.

CREATE OR REPLACE FUNCTION public.get_superadmin_approval_by_course(p_ins_id integer)
RETURNS TABLE (course text, stuclass text, approval_students int, approval numeric)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;
  RETURN QUERY EXECUTE format($q$
    SELECT COALESCE(NULLIF(s.courname, ''), 'Other')::text AS course,
           COALESCE(s.stuclass, '')::text                  AS stuclass,
           COUNT(DISTINCT p.stu_id)::int                   AS approval_students,
           COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)), 0)::numeric AS approval
    FROM   %1$I.payment p
    JOIN   %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
    JOIN   %1$I.feedemand fd ON fd.dem_id = pd.dem_id
    LEFT   JOIN %1$I.students s ON s.stu_id = p.stu_id
    WHERE  p.ins_id = $1 AND p.activestatus = 1 AND p.paystatus = 'C'
      AND  p.recon_status = 'P' AND fd.activestatus = 1
    GROUP  BY COALESCE(NULLIF(s.courname, ''), 'Other'), COALESCE(s.stuclass, '')
    HAVING COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)), 0) > 0
    ORDER  BY 1, 2
  $q$, v) USING p_ins_id;
END $$;

GRANT EXECUTE ON FUNCTION public.get_superadmin_approval_by_course(integer) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
