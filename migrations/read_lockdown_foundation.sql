-- ============================================================================
-- READ LOCKDOWN — Phase 4 foundation (NON-BREAKING).
-- ============================================================================
-- Goal: let RLS enforce per-tenant READS without rewriting the app's 55+ direct
-- read sites. The app's http client sends the session token as an `x-app-token`
-- header on every request; this db-pre-request hook validates it and stashes the
-- caller's ins_id in a request-local GUC `app.ins_id`. RLS policies (added later,
-- table by table) then filter with `ins_id = current_setting('app.ins_id')`.
--
-- This script is NON-BREAKING on its own: it only sets a GUC that nothing reads
-- yet. Reads/writes are unchanged until RLS is enabled on a table (separate,
-- careful step). Requires secure_app_session.sql (app_session). Idempotent.
-- ============================================================================

-- Runs before every PostgREST request (as the authenticator role). DEFINER so it
-- can read app_session (which is revoked from anon). Never raises — an invalid or
-- missing token just leaves app.ins_id empty, so RLS-protected tables return zero
-- rows rather than erroring.
CREATE OR REPLACE FUNCTION public.app_pre_request() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_token text; v_ins integer;
BEGIN
  BEGIN
    v_token := current_setting('request.headers', true)::json->>'x-app-token';
  EXCEPTION WHEN OTHERS THEN
    v_token := NULL;
  END;

  IF v_token IS NULL OR length(v_token) < 16 THEN
    PERFORM set_config('app.ins_id', '', true);
    RETURN;
  END IF;

  SELECT ins_id INTO v_ins
    FROM public.app_session
   WHERE token_hash = encode(digest(v_token, 'sha256'), 'hex')
     AND NOT revoked AND expires_at > now();

  PERFORM set_config('app.ins_id', COALESCE(v_ins::text, ''), true);
END; $$;

-- Wire it into PostgREST (Supabase's `authenticator` role). Takes effect after a
-- schema reload. Safe to re-run.
ALTER ROLE authenticator SET pgrst.db_pre_request = 'public.app_pre_request';

-- Helper other policies can reuse: the current request's institution, or NULL.
CREATE OR REPLACE FUNCTION public.current_app_ins() RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.ins_id', true), '')::integer;
$$;

GRANT EXECUTE ON FUNCTION public.current_app_ins() TO anon, authenticated;

NOTIFY pgrst, 'reload config';
NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- NEXT (breaking, per table — DO NOT run until the foundation is verified):
--   ALTER TABLE <schema>.students ENABLE ROW LEVEL SECURITY;
--   CREATE POLICY app_tenant_read ON <schema>.students FOR SELECT
--     USING (ins_id = public.current_app_ins());
--   -- Writes keep working: the SECURITY DEFINER RPCs own the tables and bypass RLS.
--   -- Verify: app reads still show data (token → GUC set); a direct anon read with
--   -- NO x-app-token header returns 0 rows.
-- ============================================================================
