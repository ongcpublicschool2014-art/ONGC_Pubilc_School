-- ============================================================================
-- Super-admin self-service account update (closes the last institutionusers hole).
-- ============================================================================
-- The Super-Admin "My Account" screen edits the super admin's OWN row with a
-- direct anon UPDATE (super_admin_dashboard.dart:4351) — the only remaining
-- un-gated institutionusers write, and the reason anon UPDATE couldn't be
-- revoked. Super admins have no session token (they log in cross-institution),
-- so instead of a token this RPC RE-VERIFIES the current bcrypt password
-- server-side — that IS the authorization. It can only ever touch the single
-- row whose (username + inscode='SUPER' + current password) match, and it
-- whitelists the self-service fields, so role/ins_id can't be escalated.
-- The usepassword hash trigger still fires on the UPDATE. Requires pgcrypto in
-- extensions (search_path). Idempotent. After deploying, anon UPDATE on
-- institutionusers can be revoked (see phase3b_revoke_pii_users.sql).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_super_admin_self(
  p_username text, p_current_password text, p_updates jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_use_id integer; v_set text; v_data jsonb;
  c_allowed text[] := ARRAY['usename','usemail','usephone','usedob','usepassword'];
BEGIN
  -- Authorization = current-password re-verification (mirrors verify_user_login
  -- for super admins: username lookup, inscode 'SUPER', bcrypt check).
  SELECT use_id INTO v_use_id
  FROM public.institutionusers
  WHERE lower(usename) = lower(p_username) AND inscode = 'SUPER' AND activestatus = 1
    AND usepassword = crypt(p_current_password, usepassword)
  LIMIT 1;
  IF v_use_id IS NULL THEN RAISE EXCEPTION 'Invalid credentials'; END IF;

  -- Keep only the self-service fields (drops ur_id/ins_id/activestatus/etc.).
  SELECT jsonb_object_agg(key, value) INTO v_data
    FROM jsonb_each(p_updates) WHERE key = ANY(c_allowed);
  IF v_data IS NULL THEN RETURN; END IF;

  SELECT string_agg(quote_ident(key) || '=r.' || quote_ident(key), ',')
    INTO v_set
    FROM jsonb_object_keys(v_data) AS key;

  EXECUTE format(
    'UPDATE public.institutionusers t SET %s '
    'FROM jsonb_populate_record(NULL::public.institutionusers, $1) r WHERE t.use_id=$2',
    v_set)
  USING v_data, v_use_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.update_super_admin_self(text, text, jsonb) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
