-- ============================================================================
-- Parent session tokens — extend the session layer for the parent mobile app.
-- ============================================================================
-- The admin app mints an institution session (create_app_session → ins_id). The
-- parent mobile app (school_fees_app) logs a parent in by payinchargemob +
-- parpassword and should see ONLY that parent's children. This adds a parallel
-- PARENT session: same app_session store, but keyed to par_id. The dual-mode RLS
-- policies (see read_lock_schema) then allow admin = whole institution OR
-- parent = only their students. Additive & non-breaking. Requires
-- secure_app_session.sql + read_lockdown_foundation.sql. Idempotent.
-- ============================================================================

-- app_session: allow parent rows (use_id null, par_id set).
ALTER TABLE public.app_session ALTER COLUMN use_id DROP NOT NULL;
ALTER TABLE public.app_session ADD COLUMN IF NOT EXISTS par_id integer;

-- Mint a parent session: re-verifies parpassword (scoped to the institution
-- schema), stores only par_id + ins_id. Mirrors the mobile app's own login so a
-- caller cannot forge a session for another parent.
CREATE OR REPLACE FUNCTION public.create_parent_session(
  p_mobile text, p_plain_password text, p_ins_id integer, p_device_id text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_par_id integer; v_token text;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;

  EXECUTE format(
    'SELECT par_id FROM %I.parents WHERE payinchargemob = $1 AND activestatus = 1 '
    '  AND parpassword IS NOT NULL AND parpassword = crypt($2, parpassword) LIMIT 1', v_schema)
  INTO v_par_id USING p_mobile, p_plain_password;
  IF v_par_id IS NULL THEN RAISE EXCEPTION 'Invalid credentials'; END IF;

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  INSERT INTO public.app_session(token_hash, use_id, ins_id, par_id, role, device_id)
  VALUES (encode(digest(v_token, 'sha256'), 'hex'), NULL, p_ins_id, v_par_id, 'parent', p_device_id);
  RETURN v_token;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_parent_session(text, text, integer, text) TO anon, authenticated;

-- Update the pre-request hook to publish BOTH ins_id and par_id from the token.
CREATE OR REPLACE FUNCTION public.app_pre_request() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_token text; v_ins integer; v_par integer;
BEGIN
  BEGIN
    v_token := current_setting('request.headers', true)::json->>'x-app-token';
  EXCEPTION WHEN OTHERS THEN v_token := NULL; END;
  IF v_token IS NULL OR length(v_token) < 16 THEN
    PERFORM set_config('app.ins_id', '', true);
    PERFORM set_config('app.par_id', '', true);
    RETURN;
  END IF;
  SELECT ins_id, par_id INTO v_ins, v_par FROM public.app_session
   WHERE token_hash = encode(digest(v_token, 'sha256'), 'hex') AND NOT revoked AND expires_at > now();
  PERFORM set_config('app.ins_id', COALESCE(v_ins::text, ''), true);
  PERFORM set_config('app.par_id', COALESCE(v_par::text, ''), true);
END; $$;

-- Current request's parent (or NULL) for RLS policies.
CREATE OR REPLACE FUNCTION public.current_app_par() RETURNS integer
LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.par_id', true), '')::integer; $$;
GRANT EXECUTE ON FUNCTION public.current_app_par() TO anon, authenticated;

NOTIFY pgrst, 'reload config';
NOTIFY pgrst, 'reload schema';
