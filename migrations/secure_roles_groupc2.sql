-- ============================================================================
-- Group C part 2 — session-gated Roles & Access writes.
-- ============================================================================
-- public.custuserroles and public.rolemenuaccess were created WITHOUT anon
-- write grants, so the Roles & Access screen's direct inserts fail with
-- "permission denied for table custuserroles" (42501) — role creation never
-- worked. These SECURITY DEFINER RPCs both FIX that (definer bypasses the grant
-- gap) and secure it: the session token is validated and ins_id is derived
-- SERVER-SIDE, so a role/menu grant can only ever be written for the caller's
-- own institution. Requires secure_app_session.sql. Idempotent.
-- ============================================================================

-- save_user_role(p_token, p_data, p_ur_id): NULL ur_id -> INSERT (returns ur_id), else UPDATE
CREATE OR REPLACE FUNCTION public.save_user_role(
  p_token text, p_data jsonb, p_ur_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  v_data := (p_data - 'ur_id') || jsonb_build_object('ins_id', v_ins);

  IF p_ur_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'custuserroles' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO public.custuserroles (%s) SELECT %s FROM jsonb_populate_record(NULL::public.custuserroles, $1) r RETURNING ur_id',
      v_cols, v_sel)
    INTO v_id USING v_data;
    RETURN v_id;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'custuserroles' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE public.custuserroles t SET %s FROM jsonb_populate_record(NULL::public.custuserroles, $1) r WHERE t.ur_id=$2 AND t.ins_id=$3',
      v_set)
    USING v_data, p_ur_id, v_ins;
    RETURN p_ur_id;
  END IF;
END; $$;

-- delete_user_role(p_token, p_ur_id): soft-delete the caller's role.
CREATE OR REPLACE FUNCTION public.delete_user_role(p_token text, p_ur_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  UPDATE public.custuserroles SET activestatus = 0 WHERE ur_id = p_ur_id AND ins_id = v_ins;
END; $$;

-- save_role_menu_access(p_token, p_ur_id, p_labels, p_createdby): replace a
-- role's menu grants (delete-then-insert) scoped to the caller's institution.
CREATE OR REPLACE FUNCTION public.save_role_menu_access(
  p_token text, p_ur_id bigint, p_labels text[], p_createdby text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; lbl text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  DELETE FROM public.rolemenuaccess WHERE ins_id = v_ins AND ur_id = p_ur_id;
  IF p_labels IS NOT NULL THEN
    FOREACH lbl IN ARRAY p_labels LOOP
      INSERT INTO public.rolemenuaccess(ins_id, ur_id, menulabel, createdby, activestatus)
      VALUES (v_ins, p_ur_id, lbl, p_createdby, 1);
    END LOOP;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.save_user_role(text, jsonb, bigint)                 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_user_role(text, bigint)                      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_role_menu_access(text, bigint, text[], text)   TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
