-- PERF: the home overview (shown to every user on login) pulled whole tables to
-- compute a few scalars:
--   * _fetchOverdue     -> ALL overdue feedemand rows (~1700) just to SUM balancedue
--   * collection trend  -> ALL payments in 13 months (~1300) to bucket by day/month
-- These two RPCs do the aggregation server-side so only a handful of rows cross
-- the wire. Both are SECURITY DEFINER + resolve schema from p_ins_id.

-- Outstanding balance already past its due date, in one number.
CREATE OR REPLACE FUNCTION public.get_overdue_total(p_ins_id integer)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; r numeric;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN 0; END IF;
  EXECUTE format(
    'SELECT COALESCE(SUM(balancedue), 0) FROM %I.feedemand
      WHERE ins_id = $1 AND activestatus = 1 AND balancedue > 0 AND duedate < CURRENT_DATE',
    v) INTO r USING p_ins_id;
  RETURN COALESCE(r, 0);
END $$;
GRANT EXECUTE ON FUNCTION public.get_overdue_total(integer) TO anon, authenticated;

-- Reconciled collection grouped by day for a date range. The client builds both
-- the last-7-days and last-12-months trends from these (few hundred) rows
-- instead of downloading every payment.
CREATE OR REPLACE FUNCTION public.get_reconciled_collection_by_day(
  p_ins_id integer, p_from date, p_to date
) RETURNS TABLE (day date, total numeric)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;
  RETURN QUERY EXECUTE format($q$
    SELECT paydate::date AS day, COALESCE(SUM(transtotalamount), 0)::numeric AS total
    FROM   %1$I.payment
    WHERE  ins_id = $1 AND activestatus = 1 AND paystatus = 'C' AND recon_status = 'R'
      AND  paydate >= $2 AND paydate < $3 + 1
    GROUP  BY paydate::date
    ORDER  BY 1
  $q$, v) USING p_ins_id, p_from, p_to;
END $$;
GRANT EXECUTE ON FUNCTION public.get_reconciled_collection_by_day(integer, date, date) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
