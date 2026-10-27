-- ============================================================================
-- Misc Collection via Paytm: store the gateway's transaction id.
--
-- misc_collection has no payment row behind it, so unlike the fee path there is
-- nowhere to keep Paytm's TXNID -- transrefno holds OUR order id. Without the
-- TXNID a Misc receipt can only be matched to a Paytm settlement by looking the
-- order id up in the dashboard, one at a time.
--
-- Added now because no Paytm Misc receipt exists yet (475 Cash / 142 Cheque /
-- 11 UPI, 0 Paytm), so there is nothing to backfill. transrefno keeps its
-- current meaning, so existing rows and the receipt display are untouched.
--
-- STEP 1 is a nullable varchar with no default: metadata-only in Postgres, no
-- table rewrite, no blocking lock, safe on a live database.
-- STEP 2 also carries the yr_id/yrlabel fallback (see
-- misc_collection_year_fallback.sql) -- one function replace delivers both.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE.
-- ============================================================================

-- STEP 1 -- the column, on every institution schema that exists.
DO $mt$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'misc_collection')
       AND left(nspname,3) <> 'pg_'
       AND nspname NOT IN ('public','information_schema')
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.misc_collection ADD COLUMN IF NOT EXISTS paytm_txnid varchar(60)', r.nspname);
    RAISE NOTICE 'added paytm_txnid to %.misc_collection', r.nspname;
  END LOOP;
END
$mt$;

-- STEP 2 -- persist it when the caller sends it. Callers that do not are
-- unaffected: the column simply stays NULL.

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
       totalamount,activestatus,createdby,paytm_txnid)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,1,$25,$26)
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
          COALESCE(NULLIF(p_header->>'collectedby',''), 'SYSTEM'),
          -- $26: appended so every existing placeholder keeps its number.
          NULLIF(p_header->>'paytm_txnid','');

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

-- Verify.
SELECT table_schema, column_name, data_type, character_maximum_length
  FROM information_schema.columns
 WHERE table_name = 'misc_collection' AND column_name = 'paytm_txnid'
 ORDER BY table_schema;
