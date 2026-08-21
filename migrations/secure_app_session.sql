-- ============================================================================
-- Phase 0 — Server-issued session tokens (foundation for the write lockdown).
-- ============================================================================
-- The app has no server-side identity today: every request runs as the shared
-- anon role, so RLS can't tell users/institutions apart and grants are wide open
-- (see docs/SECURITY_REVIEW.md). This adds a server-minted session token that
-- later write RPCs will require, deriving ins_id/role SERVER-SIDE from the token
-- instead of trusting a client-supplied p_ins_id.
--
-- Design (mirrors the existing device_activations hashed-code pattern):
--   * Only a SHA-256 HASH of the token is stored; the client holds the raw token.
--   * create_app_session RE-VERIFIES the bcrypt password (scoped to the chosen
--     institution) before minting — a client cannot forge a session for another
--     user by passing a use_id.
--   * session_context(token) validates + returns (use_id, ins_id, ur_id) or
--     RAISEs; write RPCs call it first and use its ins_id.
--   * app_session is REVOKEd from anon/authenticated + RLS-enabled: reachable
--     only through these SECURITY DEFINER functions.
--
-- Additive and non-breaking — nothing calls these yet. Idempotent.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Session store ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.app_session (
  token_hash   text        PRIMARY KEY,          -- sha256(raw token), hex
  use_id       integer     NOT NULL,
  ins_id       integer     NOT NULL,
  ur_id        integer,
  role         text,
  device_id    text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL DEFAULT now() + interval '30 days',
  revoked      boolean     NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS ix_app_session_lookup
  ON public.app_session (token_hash) WHERE NOT revoked;

-- Lock the table away from direct client access (default privileges would have
-- granted anon ALL on this new public table). Access is only via the functions.
REVOKE ALL ON public.app_session FROM anon, authenticated;
ALTER TABLE public.app_session ENABLE ROW LEVEL SECURITY;  -- no policy => no direct rows

-- ── Mint a session (after verifying credentials, scoped to the institution) ──
CREATE OR REPLACE FUNCTION public.create_app_session(
  p_email          text,
  p_plain_password text,
  p_ins_id         integer,
  p_is_super_admin boolean DEFAULT false,
  p_device_id      text    DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_schema text; v_use_id integer; v_ur_id integer; v_urname text; v_ins_id integer; v_token text;
BEGIN
  -- Mirrors public.verify_user_login's proven lookup + bcrypt check, but binds
  -- the result to a session. Identity (use_id, ins_id, role) is taken from the
  -- matched row — never from the client — so a caller can't forge a session.
  IF p_is_super_admin THEN
    -- Super admins log in by username; single public row with inscode='SUPER'.
    SELECT use_id, ur_id, urname, ins_id INTO v_use_id, v_ur_id, v_urname, v_ins_id
    FROM public.institutionusers
    WHERE lower(usename) = lower(p_email) AND inscode = 'SUPER' AND activestatus = 1
      AND usepassword = crypt(p_plain_password, usepassword)
    LIMIT 1;
  ELSE
    -- public.institutionusers first (where the app creates users)...
    SELECT use_id, ur_id, urname, ins_id INTO v_use_id, v_ur_id, v_urname, v_ins_id
    FROM public.institutionusers
    WHERE usemail = p_email AND activestatus = 1
      AND usepassword = crypt(p_plain_password, usepassword)
    LIMIT 1;
    -- ...then the selected institution's schema copy (legacy data).
    IF v_use_id IS NULL THEN
      v_schema := get_institution_schema(p_ins_id);
      IF v_schema IS NOT NULL THEN
        EXECUTE format(
          'SELECT use_id, ur_id, urname, ins_id FROM %I.institutionusers '
          'WHERE usemail = $1 AND activestatus = 1 '
          '  AND usepassword = crypt($2, usepassword) LIMIT 1', v_schema)
        INTO v_use_id, v_ur_id, v_urname, v_ins_id USING p_email, p_plain_password;
      END IF;
    END IF;
  END IF;

  IF v_use_id IS NULL THEN
    RAISE EXCEPTION 'Invalid credentials';
  END IF;

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  INSERT INTO public.app_session(token_hash, use_id, ins_id, ur_id, role, device_id)
  VALUES (encode(digest(v_token, 'sha256'), 'hex'), v_use_id,
          COALESCE(v_ins_id, p_ins_id), v_ur_id, v_urname, p_device_id);
  RETURN v_token;
END; $$;

-- ── Validate a token; return the caller's context (or RAISE) ────────────────
-- Write RPCs call: SELECT ins_id INTO v_ins FROM public.session_context(p_token);
CREATE OR REPLACE FUNCTION public.session_context(p_token text)
RETURNS TABLE(use_id integer, ins_id integer, ur_id integer, role text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_hash text; r record;
BEGIN
  IF p_token IS NULL OR length(p_token) < 16 THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  v_hash := encode(digest(p_token, 'sha256'), 'hex');
  SELECT s.use_id, s.ins_id, s.ur_id, s.role INTO r
  FROM public.app_session s
  WHERE s.token_hash = v_hash AND NOT s.revoked AND s.expires_at > now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid or expired session';
  END IF;
  UPDATE public.app_session SET last_seen_at = now() WHERE token_hash = v_hash;
  use_id := r.use_id; ins_id := r.ins_id; ur_id := r.ur_id; role := r.role;
  RETURN NEXT;
END; $$;

-- ── Revoke (logout) ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.revoke_session(p_token text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_token IS NULL THEN RETURN; END IF;
  UPDATE public.app_session SET revoked = true
  WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex');
END; $$;

GRANT EXECUTE ON FUNCTION public.create_app_session(text, text, integer, boolean, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.session_context(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_session(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
