-- ============================================================================
-- Group C part 2 — session-gated writes for institution-scoped PUBLIC tables.
-- ============================================================================
-- institutionusers (staff accounts — a privilege-escalation surface: with the
-- anon key anyone could insert an admin user for ANY institution) and
-- staffdesignation live in the PUBLIC schema, so their tenant boundary is the
-- ins_id COLUMN. Generic whitelisted pair, analogous to save_schema_row but for
-- public tables: token validated, ins_id forced server-side, and UPDATE/DELETE
-- scoped by ins_id so a caller can only touch its own institution's rows.
--
-- NOTE institutionusers.usepassword is hashed by a BEFORE-INSERT trigger; that
-- trigger fires on this INSERT exactly as on a direct one, so passwords stay
-- bcrypt-hashed. Requires secure_app_session.sql. Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_public_row_writable(p_table text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_table IN ('institutionusers','staffdesignation');
$$;

CREATE OR REPLACE FUNCTION public.save_public_row(
  p_token text, p_table text, p_data jsonb,
  p_pk_col text DEFAULT NULL, p_pk_val bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_public_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via save_public_row', p_table;
  END IF;

  -- Force server-derived ins_id; drop the pk so a serial default applies.
  v_data := p_data || jsonb_build_object('ins_id', v_ins);
  IF p_pk_col IS NOT NULL THEN v_data := v_data - p_pk_col; END IF;

  IF p_pk_val IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = p_table AND v_data ? column_name;

    IF p_pk_col IS NULL THEN
      EXECUTE format(
        'INSERT INTO public.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I, $1) r',
        p_table, v_cols, v_sel, p_table)
      USING v_data;
      RETURN NULL;
    ELSE
      EXECUTE format(
        'INSERT INTO public.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I, $1) r RETURNING %I',
        p_table, v_cols, v_sel, p_table, p_pk_col)
      INTO v_id USING v_data;
      RETURN v_id;
    END IF;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = p_table AND v_data ? column_name;

    EXECUTE format(
      'UPDATE public.%I t SET %s FROM jsonb_populate_record(NULL::public.%I, $1) r WHERE t.%I=$2 AND t.ins_id=$3',
      p_table, v_set, p_table, p_pk_col)
    USING v_data, p_pk_val, v_ins;
    RETURN p_pk_val;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.delete_public_row(
  p_token text, p_table text, p_pk_col text, p_pk_val bigint, p_soft boolean DEFAULT true
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_public_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via delete_public_row', p_table;
  END IF;

  IF p_soft THEN
    EXECUTE format('UPDATE public.%I SET activestatus=0 WHERE %I=$1 AND ins_id=$2', p_table, p_pk_col)
      USING p_pk_val, v_ins;
  ELSE
    EXECUTE format('DELETE FROM public.%I WHERE %I=$1 AND ins_id=$2', p_table, p_pk_col)
      USING p_pk_val, v_ins;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.is_public_row_writable(text)                          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_public_row(text, text, jsonb, text, bigint)      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_public_row(text, text, text, bigint, boolean)  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
