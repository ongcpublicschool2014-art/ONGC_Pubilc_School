-- ============================================================================
-- Group C — session-gated Admission writes (public.admission).
-- ============================================================================
-- admission lives in the PUBLIC schema, so its tenant boundary is the ins_id
-- COLUMN (not a schema). Both functions validate the session token and force
-- ins_id server-side.
--
--  * save_admission        — insert/update public.admission (ins_id forced).
--  * allocate_admission_secure — thin wrapper over the existing
--        allocate_admission_to_student(...). It VERIFIES the admission belongs
--        to the caller's institution and derives the target schema server-side,
--        closing the old hole where the client passed an arbitrary p_schema.
--
-- Requires secure_app_session.sql (session_context). Idempotent.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- save_admission(p_token, p_data, p_adm_id)
--   p_adm_id NULL  -> INSERT (returns new adm_id)
--   p_adm_id given -> UPDATE that admission (scoped to the session's ins_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_admission(
  p_token text, p_data jsonb, p_adm_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  -- Force server-derived ins_id; never trust a client adm_id inside the payload.
  v_data := (p_data - 'adm_id') || jsonb_build_object('ins_id', v_ins);

  IF p_adm_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'admission' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO public.admission (%s) SELECT %s FROM jsonb_populate_record(NULL::public.admission, $1) r RETURNING adm_id',
      v_cols, v_sel)
    INTO v_id USING v_data;
    RETURN v_id;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'admission' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE public.admission t SET %s FROM jsonb_populate_record(NULL::public.admission, $1) r WHERE t.adm_id=$2 AND t.ins_id=$3',
      v_set)
    USING v_data, p_adm_id, v_ins;
    RETURN p_adm_id;
  END IF;
END; $$;

-- ---------------------------------------------------------------------------
-- allocate_admission_secure(p_token, p_adm_id, p_class, p_stuadmno, p_allocatedby)
--   Token-gated wrapper: verifies the admission is the caller's, derives the
--   institution schema server-side, then calls the existing allocator.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.allocate_admission_secure(
  p_token text, p_adm_id bigint, p_class text, p_stuadmno text, p_allocatedby text DEFAULT NULL
) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_adm_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  SELECT ins_id INTO v_adm_ins FROM public.admission WHERE adm_id = p_adm_id;
  IF v_adm_ins IS NULL THEN RAISE EXCEPTION 'Admission % not found', p_adm_id; END IF;
  IF v_adm_ins <> v_ins THEN
    RAISE EXCEPTION 'Admission % does not belong to this institution', p_adm_id;
  END IF;

  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  RETURN public.allocate_admission_to_student(p_adm_id, v_schema, p_class, p_stuadmno, p_allocatedby);
END; $$;

GRANT EXECUTE ON FUNCTION public.save_admission(text, jsonb, bigint)                        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_admission_secure(text, bigint, text, text, text)  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
