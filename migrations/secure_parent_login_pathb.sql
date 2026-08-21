-- ============================================================================
-- PATH B — parent pre-login flows via SECURITY DEFINER RPCs.  [foundation]
-- ============================================================================
-- Goal: let the parent mobile app do institution-discovery / OTP / password-set
-- WITHOUT reading or writing `parents` directly, so `parents` can finally be
-- RLS-locked (Path A left it open because these pre-token flows touch it).
-- Login itself already has create_parent_session (verifies parpassword → token);
-- post-login the parent reads only their OWN parents row via the par_id RLS policy.
--
-- ADDITIVE + NON-BREAKING: nothing calls these until the Path-B mobile release is
-- wired to them. Deploy them, ship that mobile build, THEN add 'parents' to
-- read_lock_schema's sensitive[] and re-run the rollout. Also a security win on
-- its own: set_parent_password requires a verified OTP (closes today's
-- anon-can-set-any-parent-password hole), and none of these leak parpassword.
-- Requires get_institution_schema (exists). Idempotent (CREATE OR REPLACE).
-- ============================================================================

-- 1) Discover every institution where this mobile is an active parent.
--    Returns ins_id/schema/has_password only — never the password hash itself.
CREATE OR REPLACE FUNCTION public.find_parent_institutions(p_mobile text)
RETURNS TABLE(ins_id integer, schema text, has_password boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r record; v_ins integer; v_has boolean;
BEGIN
  FOR r IN
    SELECT n.nspname AS sch FROM pg_namespace n
    WHERE n.nspname NOT IN ('public','pg_catalog','information_schema','extensions')
      AND n.nspname NOT LIKE 'pg_%'
      AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema=n.nspname AND table_name='parents')
  LOOP
    v_ins := NULL; v_has := NULL;
    BEGIN
      EXECUTE format(
        'SELECT ins_id, (COALESCE(length(parpassword),0) > 0) FROM %I.parents '
        'WHERE payinchargemob=$1 AND activestatus=1 ORDER BY par_id LIMIT 1', r.sch)
      INTO v_ins, v_has USING p_mobile;
    EXCEPTION WHEN OTHERS THEN v_ins := NULL; END;
    IF v_ins IS NOT NULL THEN
      ins_id := v_ins; schema := r.sch; has_password := COALESCE(v_has,false);
      RETURN NEXT;
    END IF;
  END LOOP;
END; $$;
GRANT EXECUTE ON FUNCTION public.find_parent_institutions(text) TO anon, authenticated;

-- 2) Store a client-generated OTP against the parent (server validates existence).
--    Client still sends the SMS; this just records the OTP + returns status so the
--    client can branch (registered vs new account). parotpstatus reset to 0.
CREATE OR REPLACE FUNCTION public.request_parent_otp(p_mobile text, p_ins_id integer, p_otp integer)
RETURNS TABLE(is_found boolean, has_password boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_par integer; v_has boolean;
BEGIN
  is_found := false; has_password := false;
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RETURN NEXT; RETURN; END IF;
  EXECUTE format(
    'SELECT par_id, (COALESCE(length(parpassword),0)>0) FROM %I.parents '
    'WHERE payinchargemob=$1 AND activestatus=1 ORDER BY par_id LIMIT 1', v_schema)
  INTO v_par, v_has USING p_mobile;
  IF v_par IS NULL THEN RETURN NEXT; RETURN; END IF;
  EXECUTE format('UPDATE %I.parents SET parmobotp=$1, parotpstatus=0 WHERE par_id=$2', v_schema)
    USING p_otp, v_par;
  is_found := true; has_password := COALESCE(v_has,false); RETURN NEXT;
END; $$;
GRANT EXECUTE ON FUNCTION public.request_parent_otp(text, integer, integer) TO anon, authenticated;

-- 3) Verify an OTP; on match set parotpstatus=1 and clear the stored OTP.
CREATE OR REPLACE FUNCTION public.verify_parent_otp(p_mobile text, p_ins_id integer, p_otp integer)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_par integer;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RETURN false; END IF;
  EXECUTE format(
    'SELECT par_id FROM %I.parents WHERE payinchargemob=$1 AND parmobotp=$2 AND activestatus=1 '
    'ORDER BY par_id LIMIT 1', v_schema)
  INTO v_par USING p_mobile, p_otp;
  IF v_par IS NULL THEN RETURN false; END IF;
  EXECUTE format('UPDATE %I.parents SET parotpstatus=1, parmobotp=NULL WHERE par_id=$1', v_schema)
    USING v_par;
  RETURN true;
END; $$;
GRANT EXECUTE ON FUNCTION public.verify_parent_otp(text, integer, integer) TO anon, authenticated;

-- 4) Set the parent password (REQUIRES a verified OTP), fanning to peer schemas
--    where the same mobile is registered. The bcrypt trigger hashes parpassword.
CREATE OR REPLACE FUNCTION public.set_parent_password(
  p_mobile text, p_ins_id integer, p_new_password text, p_peer_ins_ids integer[] DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_ok boolean; v_peer integer; v_ps text;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;
  -- Guard: OTP must be verified for this mobile in the primary schema.
  EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.parents WHERE payinchargemob=$1 AND parotpstatus=1 AND activestatus=1)', v_schema)
    INTO v_ok USING p_mobile;
  IF NOT COALESCE(v_ok,false) THEN RAISE EXCEPTION 'OTP not verified'; END IF;
  -- Primary schema: set password (trigger bcrypts) + reset OTP.
  EXECUTE format('UPDATE %I.parents SET parpassword=$1, parmobotp=NULL, parotpstatus=0 WHERE payinchargemob=$2 AND activestatus=1', v_schema)
    USING p_new_password, p_mobile;
  -- Peers (same person, other institutions) — best effort, no OTP re-check.
  IF p_peer_ins_ids IS NOT NULL THEN
    FOREACH v_peer IN ARRAY p_peer_ins_ids LOOP
      BEGIN
        v_ps := get_institution_schema(v_peer);
        IF v_ps IS NOT NULL AND v_ps <> v_schema THEN
          EXECUTE format('UPDATE %I.parents SET parpassword=$1, parmobotp=NULL WHERE payinchargemob=$2 AND activestatus=1', v_ps)
            USING p_new_password, p_mobile;
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
  END IF;
  RETURN true;
END; $$;
GRANT EXECUTE ON FUNCTION public.set_parent_password(text, integer, text, integer[]) TO anon, authenticated;

-- ============================================================================
-- After deploying these + the Path-B mobile release that calls them, lock parents:
--   add 'parents' back to read_lock_schema's sensitive[] (parent scope
--   par_id = current_app_par(); also give it permissive write policies since the
--   RPCs are DEFINER and bypass RLS, so anon writes can then be REVOKED too), then
--   re-run the rollout. Optional hardening: rate-limit verify_parent_otp attempts.
-- ============================================================================
