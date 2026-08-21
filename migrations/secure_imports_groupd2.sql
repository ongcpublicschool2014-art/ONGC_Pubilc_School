-- ============================================================================
-- Group D part 2 — session-gated BULK/IMPORT writes for master tables.
-- ============================================================================
-- The single-row master writes already go through save_schema_row. The
-- remaining un-gated writes are BATCH operations (Master Import upserts,
-- classfeedemand batch insert, tempfeedemand batch) and COMPOUND-condition
-- deletes (classfeedemand cleared by class+term+admissiontype). These two
-- generic functions cover them, reusing the same is_schema_row_writable
-- whitelist and forcing ins_id server-side. Requires secure_app_session.sql +
-- secure_masters_groupd.sql (is_schema_row_writable). Idempotent.
-- ============================================================================

-- import_schema_rows: batch INSERT (p_conflict_col NULL) or UPSERT-on-conflict
-- of a JSON array of rows into a whitelisted institution-schema table.
CREATE OR REPLACE FUNCTION public.import_schema_rows(
  p_token text, p_table text, p_rows jsonb, p_conflict_col text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_rows jsonb;
  v_cols text; v_sel text; v_upd text; v_n integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_schema_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not importable via import_schema_rows', p_table;
  END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RETURN 0;
  END IF;

  -- Force server-derived ins_id on every row (only lands if the column exists).
  SELECT jsonb_agg(elem || jsonb_build_object('ins_id', v_ins))
    INTO v_rows FROM jsonb_array_elements(p_rows) elem;

  -- Column list = real columns present in the FIRST row (imports are uniform).
  SELECT string_agg(quote_ident(column_name), ','),
         string_agg('r.' || quote_ident(column_name), ',')
    INTO v_cols, v_sel
    FROM information_schema.columns
   WHERE table_schema = v_schema AND table_name = p_table AND (v_rows->0) ? column_name;

  IF p_conflict_col IS NULL THEN
    EXECUTE format(
      'INSERT INTO %I.%I (%s) SELECT %s FROM jsonb_populate_recordset(NULL::%I.%I, $1) r',
      v_schema, p_table, v_cols, v_sel, v_schema, p_table)
    USING v_rows;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=EXCLUDED.' || quote_ident(column_name), ',')
      INTO v_upd
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = p_table
       AND (v_rows->0) ? column_name AND column_name <> p_conflict_col;
    EXECUTE format(
      'INSERT INTO %I.%I (%s) SELECT %s FROM jsonb_populate_recordset(NULL::%I.%I, $1) r '
      'ON CONFLICT (%I) DO UPDATE SET %s',
      v_schema, p_table, v_cols, v_sel, v_schema, p_table, p_conflict_col, v_upd)
    USING v_rows;
  END IF;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $$;

-- delete_schema_rows_where: hard-DELETE rows matching an equality map (each
-- key = column, value = required value; NULL value => IS NULL). For the
-- classfeedemand idempotent-clear (class + term + admissiontype). Whitelisted.
CREATE OR REPLACE FUNCTION public.delete_schema_rows_where(
  p_token text, p_table text, p_match jsonb
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_where text; v_n integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_schema_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via delete_schema_rows_where', p_table;
  END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  IF p_match IS NULL OR jsonb_typeof(p_match) <> 'object' THEN
    RAISE EXCEPTION 'p_match must be a JSON object';
  END IF;

  -- Build "col = value / col IS NULL" only over REAL columns of the table.
  SELECT string_agg(
           CASE WHEN jsonb_typeof(p_match->k) = 'null'
                THEN format('%I IS NULL', k)
                ELSE format('%I = %L', k, p_match->>k) END, ' AND ')
    INTO v_where
    FROM jsonb_object_keys(p_match) AS k
   WHERE EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema = v_schema AND c.table_name = p_table
                    AND c.column_name = k);
  IF v_where IS NULL THEN RAISE EXCEPTION 'No valid match columns'; END IF;

  EXECUTE format('DELETE FROM %I.%I WHERE %s', v_schema, p_table, v_where);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $$;

GRANT EXECUTE ON FUNCTION public.import_schema_rows(text, text, jsonb, text)      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_schema_rows_where(text, text, jsonb)      TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
