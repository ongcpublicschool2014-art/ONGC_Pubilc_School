-- PERF + BUG FIX: class/course dropdowns were built by pulling the ENTIRE
-- students table to the client and de-duping in Dart. Past ~1000 students the
-- PostgREST row cap silently dropped rows, so some classes disappeared from the
-- filters. This RPC returns the distinct (courname, stuclass) pairs server-side
-- in one small round-trip, with no cap.
--
-- Schema is resolved from p_ins_id (get_institution_schema) so the client never
-- passes a schema name.

CREATE OR REPLACE FUNCTION public.get_distinct_classes(p_ins_id integer)
RETURNS TABLE (courname text, stuclass text)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;
  RETURN QUERY EXECUTE format(
    'SELECT DISTINCT COALESCE(courname, '''')::text, COALESCE(stuclass, '''')::text
       FROM %I.students
      WHERE ins_id = $1 AND activestatus = 1
        AND stuclass IS NOT NULL AND btrim(stuclass) <> ''''
      ORDER BY 1, 2', v
  ) USING p_ins_id;
END $$;

GRANT EXECUTE ON FUNCTION public.get_distinct_classes(integer) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
