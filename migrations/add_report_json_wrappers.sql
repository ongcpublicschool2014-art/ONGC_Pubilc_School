-- PERF: the Daily Collection and PowerCollege export reports paginate their
-- aggregate RPCs with .range(offset, offset+999). But PostgREST RE-EXECUTES a
-- SETOF function for every page, so a report with >1000 rows re-runs the whole
-- date-range aggregation N times (O(N^2) server work) and discards all but a
-- 1000-row window each time.
--
-- Fix: thin json_agg wrappers that run the original function ONCE and return the
-- entire result as a single JSON value (a scalar return is not subject to the
-- 1000-row cap). The originals are unchanged; the client calls these and gets
-- everything in one round-trip. Falls back to the paginated path if absent.

CREATE OR REPLACE FUNCTION public.get_daily_collection_report_json(
  p_schema text, p_ins_id integer, p_from date, p_to date
) RETURNS json LANGUAGE sql STABLE AS $$
  SELECT COALESCE(json_agg(t), '[]'::json)
  FROM public.get_daily_collection_report(p_schema, p_ins_id, p_from, p_to) t;
$$;
GRANT EXECUTE ON FUNCTION public.get_daily_collection_report_json(text, integer, date, date) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_powercollege_export_json(
  p_schema text, p_ins_id integer, p_from date, p_to date
) RETURNS json LANGUAGE sql STABLE AS $$
  SELECT COALESCE(json_agg(t), '[]'::json)
  FROM public.get_powercollege_export(p_schema, p_ins_id, p_from, p_to) t;
$$;
GRANT EXECUTE ON FUNCTION public.get_powercollege_export_json(text, integer, date, date) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
