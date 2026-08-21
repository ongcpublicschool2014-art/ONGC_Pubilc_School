-- ============================================================================
-- Group D — session-gated master / config writes (institution-schema tables).
-- ============================================================================
-- Master/config tables are low-risk config data (fee types, classes, quotas,
-- sequences, notices…) that all live INSIDE the caller's institution schema —
-- so the server-derived schema is itself the tenant boundary. Rather than one
-- RPC per table, a single pair of generic, WHITELISTED functions handles them:
--
--   save_schema_row(p_token, p_table, p_data, p_pk_col, p_pk_val)
--       p_pk_val NULL  -> INSERT (returns the pk when p_pk_col given, else NULL)
--       p_pk_val given -> UPDATE that row by p_pk_col
--   delete_schema_row(p_token, p_table, p_pk_col, p_pk_val, p_soft)
--       p_soft true (default) -> activestatus=0 ; false -> hard DELETE
--
-- The whitelist (is_schema_row_writable) is the safety mechanism: money/PII
-- tables (payment, feedemand, students, …) are DELIBERATELY excluded — those
-- have their own dedicated, validated RPCs. Type-safe via jsonb_populate_record.
-- Requires secure_app_session.sql (session_context). Idempotent.
-- ============================================================================

-- Only these institution-schema tables may be written through the generic RPCs.
CREATE OR REPLACE FUNCTION public.is_schema_row_writable(p_table text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_table IN (
    'tempfeedemand','bank','feegroup','feetype','sequence','course','class',
    'classfeedemand','semester','notification','finerule','notice',
    'admissiontype','quota','community','concessioncategory','division',
    'interim_promotion'
  );
$$;

CREATE OR REPLACE FUNCTION public.save_schema_row(
  p_token text, p_table text, p_data jsonb,
  p_pk_col text DEFAULT NULL, p_pk_val bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_schema_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via save_schema_row', p_table;
  END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- Force server-derived ins_id (only lands if the table actually has ins_id).
  v_data := p_data || jsonb_build_object('ins_id', v_ins);

  IF p_pk_val IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = p_table AND v_data ? column_name;

    IF p_pk_col IS NULL THEN
      EXECUTE format(
        'INSERT INTO %I.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.%I, $1) r',
        v_schema, p_table, v_cols, v_sel, v_schema, p_table)
      USING v_data;
      RETURN NULL;
    ELSE
      EXECUTE format(
        'INSERT INTO %I.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.%I, $1) r RETURNING %I',
        v_schema, p_table, v_cols, v_sel, v_schema, p_table, p_pk_col)
      INTO v_id USING v_data;
      RETURN v_id;
    END IF;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = p_table AND v_data ? column_name;

    EXECUTE format(
      'UPDATE %I.%I t SET %s FROM jsonb_populate_record(NULL::%I.%I, $1) r WHERE t.%I=$2',
      v_schema, p_table, v_set, v_schema, p_table, p_pk_col)
    USING v_data, p_pk_val;
    RETURN p_pk_val;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.delete_schema_row(
  p_token text, p_table text, p_pk_col text, p_pk_val bigint, p_soft boolean DEFAULT true
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_schema_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via delete_schema_row', p_table;
  END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  IF p_soft THEN
    EXECUTE format('UPDATE %I.%I SET activestatus=0 WHERE %I=$1', v_schema, p_table, p_pk_col)
      USING p_pk_val;
  ELSE
    EXECUTE format('DELETE FROM %I.%I WHERE %I=$1', v_schema, p_table, p_pk_col)
      USING p_pk_val;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.is_schema_row_writable(text)                             TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_schema_row(text, text, jsonb, text, bigint)         TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_schema_row(text, text, text, bigint, boolean)     TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
