-- Fee Concession + Fee Refund: draw doc_no from their own sequences (CONNO /
-- REFNO, managed in Fee Master). process_concession / process_refund now
-- generate doc_no from the sequence (atomic FOR UPDATE bump) when one exists,
-- else fall back to the client-supplied doc_no. DB-only; safe to re-run.
--
-- Set up the CN/RF sequences first in Setup → Fee Master → Concession No / Refund No.

-- doc_no becomes varchar(30) on both tables so it can hold the FORMATTED
-- sequence value (prefix + padded counter, e.g. CN00001 / RF00001) — the same
-- shape feedemand.demno uses. Existing integer values convert to their text form.
DO $$
DECLARE r RECORD; v_schema text;
BEGIN
  FOR r IN SELECT DISTINCT ins_id FROM public.admission WHERE ins_id IS NOT NULL LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;
    BEGIN
      EXECUTE format('ALTER TABLE %I.fee_refund ALTER COLUMN doc_no TYPE varchar(30) USING doc_no::text', v_schema);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fee_refund.doc_no type skip %: %', v_schema, SQLERRM; END;
    BEGIN
      EXECUTE format('ALTER TABLE %I.concession ALTER COLUMN doc_no TYPE varchar(30) USING doc_no::text', v_schema);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'concession.doc_no type skip %: %', v_schema, SQLERRM; END;
    -- receiptno is retired: doc_no is now the single concession document number.
    BEGIN
      EXECUTE format('ALTER TABLE %I.concession DROP COLUMN IF EXISTS receiptno', v_schema);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'concession.receiptno drop skip %: %', v_schema, SQLERRM; END;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.process_refund(
  p_token text, p_header jsonb, p_lines jsonb
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_rf_id integer; v_pay_id integer;
  v_total_refund numeric; v_existing numeric;
  itm RECORD; v_paid numeric; v_bal numeric; v_recon numeric;
  v_seq_id integer; v_num integer; v_scur numeric; v_sstart numeric;
  v_yrid integer; v_yrlabel text;
  v_prefix text; v_width int; v_docno text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  -- Resolve the active academic year server-side (client sends none).
  BEGIN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
      INTO v_yrid, v_yrlabel USING v_ins;
  EXCEPTION WHEN OTHERS THEN v_yrid := NULL; v_yrlabel := NULL;
  END;
  -- doc_no = formatted REFNO sequence value (prefix + padded), same shape as
  -- feedemand.demno. Atomic bump; falls back to the client value.
  EXECUTE format('SELECT seq_id, seqstart, seqcurno, seqprefix, seqwidth FROM %I.sequence WHERE ins_id=$1 AND actname=''REFNO'' AND activestatus=1 ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_sstart, v_scur, v_prefix, v_width USING v_ins;
  IF v_seq_id IS NOT NULL THEN
    v_num := (CASE WHEN COALESCE(v_scur,0) < COALESCE(v_sstart,1) THEN COALESCE(v_sstart,1) ELSE v_scur + 1 END)::integer;
    v_docno := COALESCE(v_prefix,'') || LPAD(v_num::text, COALESCE(v_width,5)::int, '0');
    EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_num, v_seq_id;
  ELSE
    v_docno := NULLIF(p_header->>'doc_no','');
  END IF;
  v_pay_id := (p_header->>'pay_id')::integer;
  v_total_refund := COALESCE((p_header->>'totalrefund')::numeric, 0);
  EXECUTE format(
    'INSERT INTO %I.fee_refund(doc_no,ins_id,inscode,yrlabel,refunddate,pay_id,paynumber,stu_id,stuadmno,stuname,stuclass,refundmode,ban_id,bankname,bankref,chequedate,accountcode,refundreason,totalrefund,totaladjust,createdby,yr_id,activestatus) '
    'VALUES($1,$2,$3,$4,NULLIF($5,'''')::date,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,NULLIF($16,'''')::date,$17,$18,$19,$20,$21,$22,1) RETURNING rf_id', v_schema)
  INTO v_rf_id USING
    v_docno, v_ins, p_header->>'inscode', COALESCE(NULLIF(p_header->>'yrlabel',''), v_yrlabel), p_header->>'refunddate',
    v_pay_id, p_header->>'paynumber', (p_header->>'stu_id')::bigint, p_header->>'stuadmno', p_header->>'stuname',
    p_header->>'stuclass', p_header->>'refundmode', NULLIF(p_header->>'ban_id','')::integer, p_header->>'bankname',
    p_header->>'bankref', p_header->>'chequedate', p_header->>'accountcode', p_header->>'refundreason',
    v_total_refund, COALESCE((p_header->>'totaladjust')::numeric, 0), p_header->>'createdby', v_yrid;
  FOR itm IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(
    dem_id bigint, refundterm text, refundfeetype text, feeamount numeric,
    refundamount numeric, adjustamount numeric, adjustreason text)
  LOOP
    EXECUTE format('INSERT INTO %I.fee_refunddetails(rf_id,dem_id,ins_id,refundterm,refundfeetype,feeamount,refundamount,adjustamount,adjustreason,activestatus) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema)
      USING v_rf_id, itm.dem_id, v_ins, itm.refundterm, itm.refundfeetype, itm.feeamount, itm.refundamount, itm.adjustamount, itm.adjustreason;
    IF COALESCE(itm.refundamount, 0) > 0 THEN
      EXECUTE format('SELECT paidamount, balancedue, reconbalancedue FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2', v_schema)
        INTO v_paid, v_bal, v_recon USING itm.dem_id, v_ins;
      IF v_paid IS NOT NULL THEN
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1, balancedue=$2, reconbalancedue=$3, paidstatus=$4 WHERE dem_id=$5 AND ins_id=$6', v_schema)
          USING GREATEST(COALESCE(v_paid,0) - itm.refundamount, 0), COALESCE(v_bal,0) + itm.refundamount,
                COALESCE(v_recon, v_bal, 0) + itm.refundamount,
                CASE WHEN COALESCE(v_bal,0) + itm.refundamount > 0 THEN 'U' ELSE 'P' END, itm.dem_id, v_ins;
      END IF;
    END IF;
  END LOOP;
  EXECUTE format('SELECT COALESCE(refund_amount,0) FROM %I.payment WHERE pay_id=$1 AND ins_id=$2', v_schema)
    INTO v_existing USING v_pay_id, v_ins;
  EXECUTE format('UPDATE %I.payment SET refund_amount=$1, paystatus=''R'' WHERE pay_id=$2 AND ins_id=$3', v_schema)
    USING COALESCE(v_existing, 0) + v_total_refund, v_pay_id, v_ins;
  RETURN v_rf_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.process_refund(text, jsonb, jsonb) TO anon, authenticated;

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

-- Backfill yr_id / yrlabel on existing fee_refund + concession rows from each
-- schema's active year (where missing). Each update independently guarded.
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
      EXECUTE format('UPDATE %I.fee_refund SET yr_id=COALESCE(yr_id,$1), yrlabel=COALESCE(NULLIF(yrlabel,''''),$2) WHERE yr_id IS NULL OR COALESCE(yrlabel,'''')=''''', v_schema) USING v_yrid, v_yrlabel;
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN
      EXECUTE format('UPDATE %I.concession SET yr_id=COALESCE(yr_id,$1), yrlabel=COALESCE(NULLIF(yrlabel,''''),$2) WHERE yr_id IS NULL OR COALESCE(yrlabel,'''')=''''', v_schema) USING v_yrid, v_yrlabel;
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END $$;
