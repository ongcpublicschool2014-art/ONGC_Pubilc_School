-- BUG: the superadmin "Course-wise Collection" drilldown (click Today Collection
-- -> breakdown) showed "No data / 0 courses" because it queried the tenant
-- payment/students tables DIRECTLY as the anon role, which cannot read them.
--
-- Fix: SECURITY DEFINER RPC that groups collection by course/class server-side
-- for an optional [p_from, p_to] date range (today's drilldown passes today for
-- both). Returns paid_students (distinct payers) + collection per course/class.

CREATE OR REPLACE FUNCTION public.get_superadmin_collection_by_course(
  p_ins_id integer, p_from date DEFAULT NULL, p_to date DEFAULT NULL
) RETURNS TABLE (course text, stuclass text, paid_students int, collection numeric)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;
  RETURN QUERY EXECUTE format($q$
    SELECT COALESCE(NULLIF(s.courname, ''), 'Other')::text AS course,
           COALESCE(s.stuclass, '')::text                  AS stuclass,
           COUNT(DISTINCT p.stu_id)::int                   AS paid_students,
           COALESCE(SUM(p.transtotalamount), 0)::numeric   AS collection
    FROM   %1$I.payment p
    LEFT   JOIN %1$I.students s ON s.stu_id = p.stu_id
    WHERE  p.ins_id = $1 AND p.activestatus = 1 AND p.paystatus = 'C'
      AND  p.recon_status = 'R'
      AND  ($2::date IS NULL OR p.paydate >= $2)
      AND  ($3::date IS NULL OR p.paydate < $3 + 1)
    GROUP  BY COALESCE(NULLIF(s.courname, ''), 'Other'), COALESCE(s.stuclass, '')
    HAVING COALESCE(SUM(p.transtotalamount), 0) > 0
    ORDER  BY 1, 2
  $q$, v) USING p_ins_id, p_from, p_to;
END $$;

GRANT EXECUTE ON FUNCTION public.get_superadmin_collection_by_course(integer, date, date) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
