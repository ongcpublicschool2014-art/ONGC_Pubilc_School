-- cleanup_student_import: SECURITY DEFINER RPC to delete processed student_import
-- staging rows (DONE / ERROR / NO_PARENT). Needed because the client's direct
-- DELETE on student_import is revoked under the write lockdown, which was
-- surfacing as a generic "Something went wrong" on an otherwise SUCCESSFUL
-- student import. The client calls this AFTER reading ERROR/NO_PARENT rows for
-- its error report. Public RPC — run once. Idempotent.

CREATE OR REPLACE FUNCTION public.cleanup_student_import(p_ins_id integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;
  EXECUTE format('DELETE FROM %I.student_import WHERE ins_id=$1 AND status IN (''DONE'',''ERROR'',''NO_PARENT'')', v) USING p_ins_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.cleanup_student_import(integer) TO anon, authenticated;
