-- Fee Concession only: doc_no drawn from the CONNO sequence (Fee Master ->
-- Concession No). Safe to re-run. Create the CONNO sequence first, or doc_no
-- falls back to whatever the client sent.

-- 1) doc_no holds the FORMATTED sequence value (e.g. CN00001), and receiptno is
--    retired -- doc_no is now the single concession document number.
DO $$
DECLARE r RECORD; v_schema text;
BEGIN
  FOR r IN SELECT DISTINCT ins_id FROM public.admission WHERE ins_id IS NOT NULL LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;
    BEGIN
      EXECUTE format('ALTER TABLE %I.concession ALTER COLUMN doc_no TYPE varchar(30) USING doc_no::text', v_schema);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'concession.doc_no type skip %: %', v_schema, SQLERRM; END;
    BEGIN
      EXECUTE format('ALTER TABLE %I.concession DROP COLUMN IF EXISTS receiptno', v_schema);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'concession.receiptno drop skip %: %', v_schema, SQLERRM; END;
  END LOOP;
END $$;

-- 2) process_concession: pulls the next CONNO value (atomic FOR UPDATE bump),
--    formats it as prefix + zero-padded counter, writes it to the header and
--    every detail line, and re-applies each concession onto feedemand.
CREATE OR REPLACE FUNCTION public.process_concession(
  p_token text, p_header jsonb, p_lines jsonb
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_hdr_id integer;
  v_condate text; v_con_id integer; v_contype text; v_createdby text; v_stu_id bigint; v_stuadmno text;
  v_inscode text; v_yrid integer; v_yrlabel text;
  itm RECORD; v_fee numeric; v_paid numeric;
  v_seq_id integer; v_num integer; v_scur numeric; v_sstart numeric;
  v_prefix text; v_width int; v_docno text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  -- doc_no = formatted CONNO sequence value (prefix + padded), same shape as
  -- feedemand.demno. Atomic bump; falls back to the client value.
  EXECUTE format('SELECT seq_id, seqstart, seqcurno, seqprefix, seqwidth FROM %I.sequence WHERE ins_id=$1 AND actname=''CONNO'' AND activestatus=1 ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_sstart, v_scur, v_prefix, v_width USING v_ins;
  IF v_seq_id IS NOT NULL THEN
    v_num := (CASE WHEN COALESCE(v_scur,0) < COALESCE(v_sstart,1) THEN COALESCE(v_sstart,1) ELSE v_scur + 1 END)::integer;
    v_docno := COALESCE(v_prefix,'') || LPAD(v_num::text, COALESCE(v_width,5)::int, '0');
    EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_num, v_seq_id;
  ELSE
    v_docno := NULLIF(p_header->>'doc_no','');
  END IF;

  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;
  BEGIN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema) INTO v_yrid, v_yrlabel;
  EXCEPTION WHEN OTHERS THEN v_yrid := NULL; v_yrlabel := NULL;
  END;

  v_condate   := p_header->>'condate';
  v_con_id    := NULLIF(p_header->>'con_id','')::integer;
  v_contype   := p_header->>'contype';
  v_createdby := p_header->>'createdby';
  v_stu_id    := NULLIF(p_header->>'stu_id','')::bigint;
  v_stuadmno  := p_header->>'stuadmno';

  EXECUTE format(
    'INSERT INTO %I.concession(doc_no,ins_id,inscode,yr_id,yrlabel,condate,stu_id,stuadmno,stuname,stuclass,courname,con_id,contype,totalfee,totalconcession,totalbalance,remarks,createdby,activestatus) '
    'VALUES($1,$2,$3,$4,$5,COALESCE(NULLIF($6,'''')::date,CURRENT_DATE),$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,1) RETURNING con_hdr_id', v_schema)
  INTO v_hdr_id USING
    v_docno, v_ins, v_inscode, v_yrid, v_yrlabel,
    v_condate, v_stu_id, v_stuadmno, p_header->>'stuname', p_header->>'stuclass', p_header->>'courname',
    v_con_id, v_contype, COALESCE((p_header->>'totalfee')::numeric,0), COALESCE((p_header->>'totalconcession')::numeric,0),
    COALESCE((p_header->>'totalbalance')::numeric,0), p_header->>'remarks', v_createdby;

  FOR itm IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(
    dem_id bigint, demfeeterm text, demfeetype text, feeamount numeric,
    conamount numeric, balancedue numeric)
  LOOP
    EXECUTE format(
      'INSERT INTO %I.concessiondetail(con_hdr_id,ins_id,stu_id,stuadmno,receiptno,dem_id,demfeeterm,demfeetype,feeamount,conamount,balancedue,con_id,contype,condate,createdby,activestatus) '
      'VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,COALESCE(NULLIF($14,'''')::date,CURRENT_DATE),$15,1)', v_schema)
      USING v_hdr_id, v_ins, v_stu_id, v_stuadmno, v_docno, itm.dem_id, itm.demfeeterm, itm.demfeetype,
            itm.feeamount, itm.conamount, COALESCE(itm.balancedue,0), v_con_id, v_contype, v_condate, v_createdby;

    IF itm.dem_id IS NOT NULL THEN
      EXECUTE format('SELECT feeamount, paidamount FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2', v_schema)
        INTO v_fee, v_paid USING itm.dem_id, v_ins;
      IF v_fee IS NOT NULL THEN
        EXECUTE format('UPDATE %I.feedemand SET con_id=$1, conamount=$2, balancedue=$3, reconbalancedue=$3, paidstatus=CASE WHEN $3>0 THEN ''U'' ELSE ''P'' END WHERE dem_id=$4 AND ins_id=$5', v_schema)
          USING v_con_id, itm.conamount,
                GREATEST(COALESCE(v_fee,0) - COALESCE(v_paid,0) - COALESCE(itm.conamount,0), 0),
                itm.dem_id, v_ins;
      END IF;
    END IF;
  END LOOP;

  RETURN v_hdr_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.process_concession(text, jsonb, jsonb) TO anon, authenticated;

-- 3) Backfill yr_id / yrlabel on existing concession rows from each schema's
--    active year (where missing).
DO $$
DECLARE r RECORD; v_schema text; v_yrid int; v_yrlabel text;
BEGIN
  FOR r IN SELECT DISTINCT ins_id FROM public.admission WHERE ins_id IS NOT NULL LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;
    v_yrid := NULL; v_yrlabel := NULL;
    BEGIN
      EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
        INTO v_yrid, v_yrlabel USING r.ins_id;
    EXCEPTION WHEN OTHERS THEN v_yrid := NULL; END;
    IF v_yrid IS NULL THEN CONTINUE; END IF;
    BEGIN
      EXECUTE format('UPDATE %I.concession SET yr_id=COALESCE(yr_id,$1), yrlabel=COALESCE(NULLIF(yrlabel,''''),$2) WHERE yr_id IS NULL OR COALESCE(yrlabel,'''')=''''', v_schema) USING v_yrid, v_yrlabel;
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $$;
