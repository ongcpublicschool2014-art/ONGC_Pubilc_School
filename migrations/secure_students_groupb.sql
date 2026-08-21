-- ============================================================================
-- Group B — session-gated Student / Parent writes (PII).
-- ============================================================================
-- Mirrors the Group-A money RPCs: every function validates the session token,
-- derives ins_id SERVER-SIDE (ignoring any client-supplied ins_id/stu_id), and
-- writes into the caller's own institution schema. After Phase 3 REVOKE these
-- become the ONLY way anon can write students/parents/parentdetail.
--
-- Wide PII rows have dozens of columns, so instead of hardcoding column lists we
-- upsert via jsonb_populate_record(NULL::<schema>.<table>, data): it casts the
-- JSON to the table's real column types automatically. We intersect the JSON
-- keys with the table's ACTUAL columns (information_schema) so a stray key can't
-- break the statement and only real columns are touched. Requires
-- secure_app_session.sql (session_context). Idempotent (CREATE OR REPLACE).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- save_student(p_token, p_data, p_stu_id)
--   p_stu_id NULL  -> INSERT (returns the new stu_id)
--   p_stu_id given -> UPDATE that student (scoped to the session's ins_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_student(
  p_token text, p_data jsonb, p_stu_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- Force server-derived ins_id; never trust a client stu_id inside the payload.
  v_data := (p_data - 'stu_id') || jsonb_build_object('ins_id', v_ins);

  IF p_stu_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'students' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO %I.students (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.students, $1) r RETURNING stu_id',
      v_schema, v_cols, v_sel, v_schema)
    INTO v_id USING v_data;
    RETURN v_id;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'students' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE %I.students t SET %s FROM jsonb_populate_record(NULL::%I.students, $1) r WHERE t.stu_id=$2 AND t.ins_id=$3',
      v_schema, v_set, v_schema)
    USING v_data, p_stu_id, v_ins;
    RETURN p_stu_id;
  END IF;
END; $$;

-- ---------------------------------------------------------------------------
-- save_parent(p_token, p_data, p_par_id)  -> INSERT (new par_id) or UPDATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_parent(
  p_token text, p_data jsonb, p_par_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_data := (p_data - 'par_id') || jsonb_build_object('ins_id', v_ins);

  IF p_par_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'parents' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO %I.parents (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.parents, $1) r RETURNING par_id',
      v_schema, v_cols, v_sel, v_schema)
    INTO v_id USING v_data;
    RETURN v_id;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'parents' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE %I.parents t SET %s FROM jsonb_populate_record(NULL::%I.parents, $1) r WHERE t.par_id=$2 AND t.ins_id=$3',
      v_schema, v_set, v_schema)
    USING v_data, p_par_id, v_ins;
    RETURN p_par_id;
  END IF;
END; $$;

-- ---------------------------------------------------------------------------
-- save_parentdetail(p_token, p_data, p_stu_id)
--   p_stu_id NULL  -> INSERT link row (student <-> parent)
--   p_stu_id given -> UPDATE the student's parentdetail row (denormalized sync)
-- The row lives in the caller's institution schema, so the server-derived
-- schema is itself the tenant boundary (no ins_id column needed to scope it).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_parentdetail(
  p_token text, p_data jsonb, p_stu_id bigint DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- ins_id is forced only if parentdetail actually has that column (the
  -- information_schema intersection below drops it otherwise).
  v_data := p_data || jsonb_build_object('ins_id', v_ins);

  IF p_stu_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'parentdetail' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO %I.parentdetail (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.parentdetail, $1) r',
      v_schema, v_cols, v_sel, v_schema)
    USING v_data;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'parentdetail' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE %I.parentdetail t SET %s FROM jsonb_populate_record(NULL::%I.parentdetail, $1) r WHERE t.stu_id=$2',
      v_schema, v_set, v_schema)
    USING v_data, p_stu_id;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.save_student(text, jsonb, bigint)       TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_parent(text, jsonb, bigint)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_parentdetail(text, jsonb, bigint)  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
