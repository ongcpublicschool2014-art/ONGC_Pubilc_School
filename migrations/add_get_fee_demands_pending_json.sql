-- Fee Demand Approval queue: JSON wrapper to escape PostgREST's 1000-row cap.
--
-- get_fee_demands_pending returns SETOF json (one row per unapproved
-- tempfeedemand row). PostgREST caps that response at 1000 rows, so on a bulk
-- demand generation (all students x terms x fee types) every demand past #1000
-- was invisible in the approval screen and could never be approved. This
-- wrapper returns the whole set as a single json array (not row-capped).
-- Defined AFTER get_fee_demands_pending exists (LANGUAGE sql validates the body).

CREATE OR REPLACE FUNCTION public.get_fee_demands_pending_json(p_ins_id integer)
RETURNS json LANGUAGE sql STABLE AS $$
  SELECT COALESCE(json_agg(t), '[]'::json)
  FROM public.get_fee_demands_pending(p_ins_id) t;
$$;

GRANT EXECUTE ON FUNCTION public.get_fee_demands_pending_json(integer) TO anon, authenticated;
