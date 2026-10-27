-- ============================================================================
-- alter_misc_collection_course.sql
-- misc_collection: drop fg_id (feegroup id) and add courname (course).
--   • fg_id is no longer stored on the row — save_misc_collection still receives
--     it in p_header for the receipt-number SEQUENCE lookup, just doesn't persist it.
--   • courname records the student's course (populates the Daily Collection COURSE
--     column for misc receipts).
-- Idempotent. Run once in Supabase.
-- ============================================================================
DO $mig$
DECLARE r RECORD; v_schema text;
BEGIN
  FOR r IN SELECT ins_id FROM public.institution WHERE activestatus = 1 LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;
    EXECUTE format('ALTER TABLE %I.misc_collection ADD COLUMN IF NOT EXISTS courname varchar(20)', v_schema);
    EXECUTE format('ALTER TABLE %I.misc_collection DROP COLUMN IF EXISTS fg_id', v_schema);
  END LOOP;
END;
$mig$;

-- Updated save_misc_collection: courname stored, fg_id no longer stored (still
-- used from p_header only to pick the receipt sequence).
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
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

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
    USING p_ins_id, p_header->>'inscode', NULLIF(p_header->>'yr_id','')::integer, p_header->>'yrlabel',
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
