-- ============================================================================
-- FIX: multi-institution parents under dual-mode RLS.
-- ============================================================================
-- A parent whose mobile is registered at several institutions has a DIFFERENT
-- par_id in each schema. The parent token carries only ONE (ins_id, par_id), so
-- a `par_id = current_app_par()` policy matched only the home schema and hid the
-- parent's students in every OTHER school. Fix: also carry the parent's MOBILE in
-- the session; RLS resolves the correct par_id per-schema from it (parents is
-- open, so the policy subquery can read it). read_lock_schema's parent predicates
-- are updated to use current_app_parmob() (see read_lockdown_dualmode.sql).
--
-- DB-ONLY — the mobile app is unchanged (it already logs in by mobile; the token
-- just gains par_mob). Existing tokens lack par_mob → parents re-login once to get
-- a scoped token. Deploy this, then the updated read_lock_schema + re-run rollout.
-- ============================================================================

ALTER TABLE public.app_session ADD COLUMN IF NOT EXISTS par_mob text;

-- create_parent_session: store the parent's mobile alongside par_id.
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
  INSERT INTO public.app_session(token_hash, use_id, ins_id, par_id, par_mob, role, device_id)
  VALUES (encode(digest(v_token, 'sha256'), 'hex'), NULL, p_ins_id, v_par_id, p_mobile, 'parent', p_device_id);
  RETURN v_token;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_parent_session(text, text, integer, text) TO anon, authenticated;

-- app_pre_request: publish app.ins_id, app.par_id AND app.par_mob from the token.
CREATE OR REPLACE FUNCTION public.app_pre_request() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_token text; v_ins integer; v_par integer; v_mob text;
BEGIN
  BEGIN
    v_token := current_setting('request.headers', true)::json->>'x-app-token';
  EXCEPTION WHEN OTHERS THEN v_token := NULL; END;
  IF v_token IS NULL OR length(v_token) < 16 THEN
    PERFORM set_config('app.ins_id', '', true);
    PERFORM set_config('app.par_id', '', true);
    PERFORM set_config('app.par_mob', '', true);
    RETURN;
  END IF;
  SELECT ins_id, par_id, par_mob INTO v_ins, v_par, v_mob FROM public.app_session
   WHERE token_hash = encode(digest(v_token, 'sha256'), 'hex') AND NOT revoked AND expires_at > now();
  PERFORM set_config('app.ins_id', COALESCE(v_ins::text, ''), true);
  PERFORM set_config('app.par_id', COALESCE(v_par::text, ''), true);
  PERFORM set_config('app.par_mob', COALESCE(v_mob, ''), true);
END; $$;
ALTER ROLE authenticator SET pgrst.db_pre_request = 'public.app_pre_request';

-- Current request's parent mobile (parent sessions only) for cross-schema RLS.
CREATE OR REPLACE FUNCTION public.current_app_parmob() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.par_mob', true), ''); $$;
GRANT EXECUTE ON FUNCTION public.current_app_parmob() TO anon, authenticated;
