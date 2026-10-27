-- ============================================================================
-- save_misc_collection: fall back to the schema's active academic year.
--
-- The function took yr_id and yrlabel straight from the caller's header. The
-- Misc Collection screen never sent yr_id at all, and sent yrlabel from a
-- cached value that can be blank -- so misc receipts were written with
-- yr_id NULL / yrlabel '', which takes the money but drops the receipt out of
-- every year-scoped report.
--
-- The client now sends both (read from the year master). This makes the server
-- correct on its own, so any caller that omits them still gets the right year
-- rather than a NULL.
--
-- Explicit values still win -- this only fills in what is missing.
-- Idempotent: CREATE OR REPLACE.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.save_misc_collection(
  p_ins_id integer, p_header jsonb, p_lines jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_schema text; v_mc_id bigint; v_fg_id integer;
  v_seq_id integer; v_sequid text; v_width numeric; v_cur numeric;
  v_prefix text; v_mcno text; v_total numeric := 0; itm jsonb;
  v_yr_id integer; v_yrlabel text; v_def_yr_id integer; v_def_yrlabel text;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

  -- Academic year: take what the caller sent, else fall back to the schema's
  -- active year. A client that omits these (or whose cached year label is
  -- blank) was writing yr_id NULL / yrlabel '', which drops the receipt out of
  -- every year-scoped report while still taking the money.
  v_yr_id    := NULLIF(p_header->>'yr_id','')::integer;
  v_yrlabel  := NULLIF(p_header->>'yrlabel','');
  IF v_yr_id IS NULL OR v_yrlabel IS NULL THEN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
      INTO v_def_yr_id, v_def_yrlabel USING p_ins_id;
    v_yr_id   := COALESCE(v_yr_id, v_def_yr_id);
    v_yrlabel := COALESCE(v_yrlabel, v_def_yrlabel);
  END IF;

  v_fg_id := NULLIF(p_header->>'fg_id','')::integer;
  IF v_fg_id IS NOT NULL THEN
    EXECUTE format('SELECT seq_id, sequid, seqwidth, seqcurno FROM %I.sequence WHERE ins_id=$1 AND fg_id=$2 LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_sequid, v_width, v_cur USING p_ins_id, v_fg_id;
  END IF;
  IF v_seq_id IS NULL THEN
    EXECUTE format('SELECT seq_id, sequid, seqwidth, seqcurno FROM %I.sequence WHERE ins_id=$1 AND fg_id IS NOT NULL ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_sequid, v_width, v_cur USING p_ins_id;
  END IF;
  IF v_seq_id IS NULL THEN RAISE EXCEPTION 'No receipt sequence configured for this institution'; END IF;

  v_cur    := COALESCE(v_cur, 0) + 1;
  v_prefix := regexp_replace(COALESCE(v_sequid, ''), '\d+$', '');
  v_mcno   := v_prefix || lpad(v_cur::bigint::text, COALESCE(v_width, 5)::int, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_cur, v_seq_id;

  SELECT COALESCE(SUM((x->>'amount')::numeric), 0) INTO v_total FROM jsonb_array_elements(p_lines) x;

  EXECUTE format('INSERT INTO %I.misc_collection
      (ins_id,inscode,yr_id,yrlabel,mcno,mcdate,selection,stu_id,regno,stuclass,stuname,courname,
       city,address,paymode,ban_id,bankname,transrefno,draweebank,transdate,transamt,collectedby,remarks,
       totalamount,activestatus,createdby)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,1,$25)
     RETURNING mc_id', v_schema)
    INTO v_mc_id
    USING p_ins_id, p_header->>'inscode', v_yr_id, v_yrlabel,
          v_mcno, COALESCE(NULLIF(p_header->>'mcdate','')::date, CURRENT_DATE),
          COALESCE(NULLIF(p_header->>'selection',''), 'S'), NULLIF(p_header->>'stu_id','')::bigint,
          p_header->>'regno', p_header->>'stuclass', p_header->>'stuname', p_header->>'courname',
          p_header->>'city', p_header->>'address',
          COALESCE(NULLIF(p_header->>'paymode',''), 'Cash'), NULLIF(p_header->>'ban_id','')::integer,
          p_header->>'bankname', p_header->>'transrefno', p_header->>'draweebank',
          NULLIF(p_header->>'transdate','')::date, NULLIF(p_header->>'transamt','')::numeric,
          p_header->>'collectedby', p_header->>'remarks', v_total,
          COALESCE(NULLIF(p_header->>'collectedby',''), 'SYSTEM');

  FOR itm IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    CONTINUE WHEN COALESCE(TRIM(itm->>'feetype'), '') = '';
    EXECUTE format('INSERT INTO %I.misc_collection_detail (mc_id,ins_id,fee_id,feetype,amount,activestatus)
        VALUES ($1,$2,$3,$4,$5,1)', v_schema)
      USING v_mc_id, p_ins_id, NULLIF(itm->>'fee_id','')::integer, itm->>'feetype', COALESCE(NULLIF(itm->>'amount','')::numeric, 0);
  END LOOP;

  RETURN jsonb_build_object('mc_id', v_mc_id, 'mcno', v_mcno, 'total', v_total);
END;
$$;
GRANT EXECUTE ON FUNCTION public.save_misc_collection(integer, jsonb, jsonb) TO anon, authenticated;

-- ── Backfill the receipts already written without a year ────────────────────
-- Review the count first, then run the UPDATE.
SELECT count(*) AS misc_rows_missing_year
  FROM kcet20262027.misc_collection
 WHERE yr_id IS NULL OR COALESCE(yrlabel,'') = '';

-- UPDATE kcet20262027.misc_collection m
--    SET yr_id   = COALESCE(m.yr_id,   y.yr_id),
--        yrlabel = COALESCE(NULLIF(m.yrlabel,''), y.yrlabel)
--   FROM (SELECT yr_id, yrlabel FROM kcet20262027.year
--          WHERE ins_id = 1 AND activestatus = 1
--          ORDER BY yr_id DESC LIMIT 1) y
--  WHERE m.ins_id = 1
--    AND (m.yr_id IS NULL OR COALESCE(m.yrlabel,'') = '');
