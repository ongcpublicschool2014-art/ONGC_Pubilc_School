-- ==========================================================================
-- RUN_IN_SUPABASE.sql — combined migrations to paste into the Supabase SQL editor
-- Generated 2026-09-01 16:26. All idempotent; safe to run as one block.
-- Order: misc course/fee_id -> institution update RPC -> concession -> ledger.
-- ==========================================================================


-- ####################################################################
-- >>> alter_misc_collection_course.sql
-- ####################################################################
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


-- ####################################################################
-- >>> add_admin_update_institution.sql
-- ####################################################################
-- ============================================================================
-- add_admin_update_institution.sql
-- public.institution has RLS enabled with only an anon SELECT policy, so a
-- direct anon UPDATE (the Manage Institutions toggle / Edit save) matches 0 rows
-- silently and never persists. This SECURITY DEFINER RPC runs as owner, bypasses
-- RLS, and patches only the columns present in p_patch (others keep their value).
-- Safe to re-run.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.admin_update_institution(p_ins_id integer, p_patch jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  UPDATE public.institution SET
    insname        = COALESCE(NULLIF(p_patch->>'insname',''), insname),
    inshortname    = COALESCE(p_patch->>'inshortname', inshortname),
    inscode        = COALESCE(NULLIF(p_patch->>'inscode',''), inscode),
    insautusername = COALESCE(NULLIF(p_patch->>'insautusername',''), insautusername),
    insdesignation = COALESCE(p_patch->>'insdesignation', insdesignation),
    insmobno       = COALESCE(NULLIF(p_patch->>'insmobno',''), insmobno),
    insmail        = COALESCE(p_patch->>'insmail', insmail),
    insaffliation  = COALESCE(p_patch->>'insaffliation', insaffliation),
    insaffno       = COALESCE(p_patch->>'insaffno', insaffno),
    inscity        = COALESCE(p_patch->>'inscity', inscity),
    insstate       = COALESCE(p_patch->>'insstate', insstate),
    inscountry     = COALESCE(p_patch->>'inscountry', inscountry),
    inspincode     = COALESCE(NULLIF(p_patch->>'inspincode',''), inspincode),
    activestatus   = COALESCE((p_patch->>'activestatus')::smallint, activestatus),
    updatedby      = COALESCE(NULLIF(p_patch->>'updatedby',''), updatedby),
    updateddate    = CURRENT_DATE
  WHERE ins_id = p_ins_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_update_institution(integer, jsonb) TO anon, authenticated;


-- ####################################################################
-- >>> add_concession_tables.sql
-- ####################################################################
-- ============================================================================
-- add_concession_tables.sql
-- Persisted Fee-Concession records: a per-student concession voucher (header)
-- plus its per-fee-line breakdown (detail). Mirrors the fee_refund /
-- fee_refunddetails pattern.
--
--   concession        — one row per concession voucher raised for a student
--   concessiondetail  — one row per fee line inside that voucher
--
-- Writes flow ONLY through the session-gated process_concession() RPC (ins_id
-- derived server-side); anon keeps SELECT so the management list + per-student
-- detail can read directly. Idempotent: safe to re-run.
--
-- Run in Supabase SQL editor (once). complete_setup.sql is kept in sync so NEW
-- institutions get these tables + RPC automatically.
-- ============================================================================

-- 1) Create the tables in EVERY existing institution schema. ------------------
DO $mig$
DECLARE
  r RECORD;
  v_schema text;
BEGIN
  FOR r IN SELECT ins_id FROM public.institution WHERE activestatus = 1 LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;

    -- concession (voucher header; one row per concession applied to a student)
    EXECUTE format($ct$
      CREATE TABLE IF NOT EXISTS %I.concession (
        con_hdr_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        receiptno       varchar(30),
        doc_no          integer,
        ins_id          integer NOT NULL,
        inscode         varchar(10),
        yr_id           integer,
        yrlabel         varchar(20),
        condate         date NOT NULL DEFAULT CURRENT_DATE,
        stu_id          bigint,
        stuadmno        varchar(25),
        stuname         varchar(50),
        stuclass        varchar(20),
        courname        varchar(20),
        con_id          integer,
        contype         varchar(30),
        totalfee        numeric(12,2) DEFAULT 0,
        totalconcession numeric(12,2) DEFAULT 0,
        totalbalance    numeric(12,2) DEFAULT 0,
        remarks         varchar(200),
        createdby       varchar(50),
        createdat       timestamp DEFAULT now() NOT NULL,
        activestatus    smallint DEFAULT 1 NOT NULL
      )$ct$, v_schema);

    -- concessiondetail (per fee-line breakdown; key voucher fields denormalized
    -- so the records grid reads from ONE table without a header join)
    EXECUTE format($cd$
      CREATE TABLE IF NOT EXISTS %I.concessiondetail (
        cond_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        con_hdr_id    bigint NOT NULL,
        ins_id        integer NOT NULL,
        stu_id        bigint,
        stuadmno      varchar(25),
        receiptno     varchar(30),
        dem_id        bigint,
        demfeeterm    varchar(20),
        demfeetype    varchar(30),
        feeamount     numeric(12,2) DEFAULT 0,
        conamount     numeric(12,2) DEFAULT 0,
        balancedue    numeric(12,2) DEFAULT 0,
        con_id        integer,
        contype       varchar(30),
        condate       date,
        createdby     varchar(50),
        activestatus  smallint DEFAULT 1 NOT NULL
      )$cd$, v_schema);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_concession_stu ON %I.concession (ins_id, stu_id)', v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_concessiondetail_hdr ON %I.concessiondetail (con_hdr_id)', v_schema);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_concessiondetail_stu ON %I.concessiondetail (ins_id, stu_id)', v_schema);

    -- Reads via anon (list/detail); writes only through the RPC below.
    EXECUTE format('GRANT SELECT, INSERT, UPDATE ON %I.concession, %I.concessiondetail TO anon, authenticated', v_schema, v_schema);
    -- Match the money-table lockdown: block direct anon writes (RPC runs as owner).
    BEGIN
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.concession, %I.concessiondetail FROM anon', v_schema, v_schema);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
END;
$mig$;

-- 2) Session-gated atomic concession write. -----------------------------------
--    Inserts the header + detail lines and re-applies each line's concession to
--    feedemand (con_id/conamount/balancedue). ins_id is derived from the token;
--    any client-supplied ins_id is ignored. Mirrors process_refund().
CREATE OR REPLACE FUNCTION public.process_concession(
  p_token text, p_header jsonb, p_lines jsonb
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_hdr_id integer;
  v_receiptno text; v_condate text; v_con_id integer; v_contype text; v_createdby text; v_stu_id bigint; v_stuadmno text;
  v_inscode text; v_yrid integer; v_yrlabel text;
  itm RECORD; v_fee numeric; v_paid numeric;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- inscode + active year are derived server-side (client can't get them wrong).
  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;
  BEGIN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema) INTO v_yrid, v_yrlabel;
  EXCEPTION WHEN OTHERS THEN v_yrid := NULL; v_yrlabel := NULL;
  END;

  v_receiptno := p_header->>'receiptno';
  v_condate   := p_header->>'condate';
  v_con_id    := NULLIF(p_header->>'con_id','')::integer;
  v_contype   := p_header->>'contype';
  v_createdby := p_header->>'createdby';
  v_stu_id    := NULLIF(p_header->>'stu_id','')::bigint;
  v_stuadmno  := p_header->>'stuadmno';

  EXECUTE format(
    'INSERT INTO %I.concession(receiptno,doc_no,ins_id,inscode,yr_id,yrlabel,condate,stu_id,stuadmno,stuname,stuclass,courname,con_id,contype,totalfee,totalconcession,totalbalance,remarks,createdby,activestatus) '
    'VALUES($1,$2,$3,$4,$5,$6,COALESCE(NULLIF($7,'''')::date,CURRENT_DATE),$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,1) RETURNING con_hdr_id', v_schema)
  INTO v_hdr_id USING
    v_receiptno, NULLIF(p_header->>'doc_no','')::integer, v_ins, v_inscode, v_yrid, v_yrlabel,
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
      USING v_hdr_id, v_ins, v_stu_id, v_stuadmno, v_receiptno, itm.dem_id, itm.demfeeterm, itm.demfeetype,
            itm.feeamount, itm.conamount, COALESCE(itm.balancedue,0), v_con_id, v_contype, v_condate, v_createdby;

    -- Re-apply the concession onto the live demand (only unpaid portion moves).
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

-- 3) Backfill EXISTING concessions already sitting on feedemand ---------------
--    (rows with conamount > 0) into the new tables so the Fee Concession list +
--    per-student detail show historical concessions instead of starting empty.
--    One voucher header per (student, concession category); one detail line per
--    concession-bearing demand. Idempotent: re-running only adds what's missing
--    (guards on createdby='BACKFILL' header per stu+con_id, and per dem_id detail).
DO $bf$
DECLARE
  r RECORD; v_schema text; v_base integer; v_inscode text; v_yrid integer; v_yrlabel text;
BEGIN
  FOR r IN SELECT ins_id FROM public.institution WHERE activestatus = 1 LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;

    EXECUTE format('SELECT COALESCE(MAX(doc_no),0) FROM %I.concession', v_schema) INTO v_base;
    SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = r.ins_id;
    BEGIN
      EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema) INTO v_yrid, v_yrlabel;
    EXCEPTION WHEN OTHERS THEN v_yrid := NULL; v_yrlabel := NULL;
    END;

    -- headers: one row per (student, concession category)
    EXECUTE format($h$
      INSERT INTO %1$I.concession(receiptno, doc_no, ins_id, inscode, yr_id, yrlabel, condate, stu_id, stuadmno, stuname, stuclass, courname, con_id, contype, totalfee, totalconcession, totalbalance, createdby, activestatus)
      SELECT 'CN'||to_char(CURRENT_DATE,'YYYY')||LPAD(($2 + row_number() OVER (ORDER BY g.stu_id, g.con_id))::text, 4, '0'),
             $2 + row_number() OVER (ORDER BY g.stu_id, g.con_id),
             $1, $3, $4, $5, CURRENT_DATE, g.stu_id, g.stuadmno, s.stuname, g.stuclass, s.courname,
             g.con_id, cc.condesc, g.totalfee, g.totalcon, g.totalbal, 'BACKFILL', 1
      FROM (
        SELECT fd.stu_id, MIN(fd.stuadmno) AS stuadmno, MIN(fd.stuclass) AS stuclass, fd.con_id,
               SUM(fd.feeamount) AS totalfee, SUM(fd.conamount) AS totalcon, SUM(fd.balancedue) AS totalbal
        FROM %1$I.feedemand fd
        WHERE fd.ins_id = $1 AND fd.activestatus = 1 AND COALESCE(fd.conamount,0) > 0 AND fd.stu_id IS NOT NULL
        GROUP BY fd.stu_id, fd.con_id
      ) g
      LEFT JOIN %1$I.students s ON s.stu_id = g.stu_id AND s.ins_id = $1
      LEFT JOIN %1$I.concessioncategory cc ON cc.con_id = g.con_id AND cc.ins_id = $1
      -- skip if ANY voucher (backfill OR manual) already exists for this
      -- (student, category) — never duplicate a concession already recorded.
      WHERE NOT EXISTS (SELECT 1 FROM %1$I.concession c WHERE c.stu_id = g.stu_id AND COALESCE(c.con_id,-1) = COALESCE(g.con_id,-1) AND c.activestatus = 1)
      $h$, v_schema) USING r.ins_id, v_base, v_inscode, v_yrid, v_yrlabel;

    -- detail lines: one per concession-bearing demand, linked to its header
    EXECUTE format($d$
      INSERT INTO %1$I.concessiondetail(con_hdr_id, ins_id, stu_id, stuadmno, receiptno, dem_id, demfeeterm, demfeetype, feeamount, conamount, balancedue, con_id, contype, condate, createdby, activestatus)
      SELECT c.con_hdr_id, $1, fd.stu_id, fd.stuadmno, c.receiptno, fd.dem_id, fd.demfeeterm, fd.demfeetype, fd.feeamount, fd.conamount, fd.balancedue, fd.con_id, c.contype, c.condate, 'BACKFILL', 1
      FROM %1$I.feedemand fd
      JOIN %1$I.concession c ON c.stu_id = fd.stu_id AND c.ins_id = $1 AND COALESCE(c.con_id,-1) = COALESCE(fd.con_id,-1) AND c.createdby = 'BACKFILL'
      WHERE fd.ins_id = $1 AND fd.activestatus = 1 AND COALESCE(fd.conamount,0) > 0 AND fd.stu_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM %1$I.concessiondetail d WHERE d.dem_id = fd.dem_id AND d.activestatus = 1)
      $d$, v_schema) USING r.ins_id;
  END LOOP;
END;
$bf$;

-- 4) De-dupe existing vouchers: keep ONE per (student, category, totals) -------
--    Removes exact-duplicate concession vouchers (same student + category +
--    totalfee + totalconcession + totalbalance) created by an earlier re-save or
--    by the backfill running after a manual save. Keeps the lowest con_hdr_id
--    and drops the rest (and their detail lines). feedemand.conamount is
--    authoritative and untouched. Idempotent.
DO $dd$
DECLARE r RECORD; v_schema text;
BEGIN
  FOR r IN SELECT ins_id FROM public.institution WHERE activestatus = 1 LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;

    -- detail lines belonging to the duplicate headers we are about to drop
    EXECUTE format($x$
      DELETE FROM %1$I.concessiondetail d
      WHERE d.con_hdr_id IN (
        SELECT c.con_hdr_id FROM %1$I.concession c
        WHERE c.activestatus = 1 AND c.con_hdr_id > (
          SELECT MIN(c2.con_hdr_id) FROM %1$I.concession c2
          WHERE c2.stu_id IS NOT DISTINCT FROM c.stu_id
            AND COALESCE(c2.con_id,-1) = COALESCE(c.con_id,-1)
            AND COALESCE(c2.totalfee,0) = COALESCE(c.totalfee,0)
            AND COALESCE(c2.totalconcession,0) = COALESCE(c.totalconcession,0)
            AND COALESCE(c2.totalbalance,0) = COALESCE(c.totalbalance,0)
            AND c2.activestatus = 1))
      $x$, v_schema);

    -- the duplicate headers themselves
    EXECUTE format($x$
      DELETE FROM %1$I.concession c
      WHERE c.activestatus = 1 AND c.con_hdr_id > (
        SELECT MIN(c2.con_hdr_id) FROM %1$I.concession c2
        WHERE c2.stu_id IS NOT DISTINCT FROM c.stu_id
          AND COALESCE(c2.con_id,-1) = COALESCE(c.con_id,-1)
          AND COALESCE(c2.totalfee,0) = COALESCE(c.totalfee,0)
          AND COALESCE(c2.totalconcession,0) = COALESCE(c.totalconcession,0)
          AND COALESCE(c2.totalbalance,0) = COALESCE(c.totalbalance,0)
          AND c2.activestatus = 1)
      $x$, v_schema);
  END LOOP;
END;
$dd$;

-- 5) Fill inscode / yr_id / yrlabel on existing rows that were saved before ----
--    those were derived server-side. inscode from public.institution, year from
--    the schema's active year. Idempotent (only touches NULLs).
DO $fx$
DECLARE r RECORD; v_schema text; v_inscode text; v_yrid integer; v_yrlabel text;
BEGIN
  FOR r IN SELECT ins_id FROM public.institution WHERE activestatus = 1 LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;
    SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = r.ins_id;
    BEGIN
      EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema) INTO v_yrid, v_yrlabel;
    EXCEPTION WHEN OTHERS THEN v_yrid := NULL; v_yrlabel := NULL;
    END;
    EXECUTE format('UPDATE %I.concession SET inscode = COALESCE(inscode, $1), yr_id = COALESCE(yr_id, $2), yrlabel = COALESCE(yrlabel, $3) WHERE inscode IS NULL OR yr_id IS NULL OR yrlabel IS NULL', v_schema)
      USING v_inscode, v_yrid, v_yrlabel;
  END LOOP;
END;
$fx$;


-- ####################################################################
-- >>> add_ledger_demseqtype.sql
-- ####################################################################
-- ============================================================================
-- add_ledger_demseqtype.sql
-- Student Ledger (Reports tab) needs demseqtype + demfeeyear to split the ledger
-- into Regular / Arrear (by year). Adds both columns to get_student_ledger_report.
-- RETURNS TABLE signature changes → DROP + CREATE (CREATE OR REPLACE can't alter
-- the OUT columns). Safe to re-run.
-- ============================================================================
DROP FUNCTION IF EXISTS public.get_student_ledger_report(TEXT, INT, TEXT);

CREATE FUNCTION public.get_student_ledger_report(
    p_schema TEXT, p_ins_id INT, p_stuadmno TEXT
) RETURNS TABLE (
    demfeeterm TEXT, demfeetype TEXT, demseqtype TEXT, demfeeyear TEXT,
    feeamount NUMERIC, conamount NUMERIC, paidamount NUMERIC,
    fineamount NUMERIC, balancedue NUMERIC, reconbalancedue NUMERIC,
    paynumber TEXT, paydate DATE, duedate DATE
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  fd.demfeeterm::TEXT, fd.demfeetype::TEXT,
                COALESCE(fd.demseqtype,'DEMAND')::TEXT, fd.demfeeyear::TEXT,
                fd.feeamount::NUMERIC, fd.conamount::NUMERIC,
                fd.paidamount::NUMERIC, fd.fineamount::NUMERIC,
                fd.balancedue::NUMERIC, fd.reconbalancedue::NUMERIC,
                p.paynumber::TEXT, p.paydate::date, fd.duedate
        FROM    %1$I.feedemand fd
        LEFT JOIN %1$I.payment p ON p.pay_id = fd.pay_id
        WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND fd.stuadmno = %3$L
        ORDER BY fd.duedate
    $f$, p_schema, p_ins_id, p_stuadmno);
END $$;

GRANT EXECUTE ON FUNCTION public.get_student_ledger_report(TEXT, INT, TEXT) TO anon, authenticated;



-- ####################################################################
-- >>> add_void_receipt_reason.sql  (Fee Cancel Receipt screen)
-- ####################################################################
-- Adds a cancellation REASON to the receipt-void flow. voidreason column +
-- void_receipt gains p_reason (the 3-arg overload is dropped and replaced by
-- the 4-arg with p_reason DEFAULT NULL, so legacy 3-key calls still resolve
-- with no overload ambiguity). Idempotent & safe to re-run.
-- ####################################################################

-- 1) voidreason column on every institution's payment table
DO $$
DECLARE
  r record;
  sname text;
BEGIN
  FOR r IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL
  LOOP
    sname := r.schema_name;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sname)
       AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = sname AND table_name = 'payment') THEN
      EXECUTE format(
        'ALTER TABLE %I.payment ADD COLUMN IF NOT EXISTS voidreason varchar(255)',
        sname);
    END IF;
  END LOOP;
END $$;

-- 2) Replace the void RPC with the reason-aware version
DROP FUNCTION IF EXISTS public.void_receipt(integer, bigint, text);

CREATE OR REPLACE FUNCTION public.void_receipt(
  p_ins_id integer, p_pay_id bigint, p_user text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v text; p RECORD; d RECORD; v_is_cash boolean;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema found for ins_id %', p_ins_id; END IF;

  EXECUTE format('SELECT pay_id, paymethod, recon_status, activestatus, paynumber FROM %I.payment WHERE pay_id=$1 AND ins_id=$2 FOR UPDATE', v)
    INTO p USING p_pay_id, p_ins_id;
  IF p.pay_id IS NULL THEN
    RAISE EXCEPTION 'Receipt not found' USING ERRCODE = 'P0001';
  END IF;
  IF p.activestatus = 9 THEN
    RAISE EXCEPTION 'Receipt is already deleted' USING ERRCODE = 'P0001';
  END IF;

  v_is_cash := LOWER(COALESCE(p.paymethod, '')) = 'cash';
  IF p.recon_status = 'R' AND NOT v_is_cash THEN
    RAISE EXCEPTION 'Receipt % is reconciled with the bank and cannot be deleted', p.paynumber USING ERRCODE = 'P0001';
  END IF;

  FOR d IN EXECUTE format('SELECT dem_id, transtotalamount FROM %I.paymentdetails WHERE pay_id=$1 AND activestatus=1', v) USING p_pay_id LOOP
    IF v_is_cash THEN
      EXECUTE format('UPDATE %I.feedemand SET paidamount=GREATEST(COALESCE(paidamount,0)-$1,0), balancedue=COALESCE(balancedue,0)+$1, reconbalancedue=COALESCE(reconbalancedue,0)+$1, paidstatus=''U'', pay_id=NULL WHERE dem_id=$2 AND ins_id=$3', v)
        USING d.transtotalamount, d.dem_id, p_ins_id;
    ELSE
      EXECUTE format('UPDATE %I.feedemand SET paidamount=GREATEST(COALESCE(paidamount,0)-$1,0), balancedue=COALESCE(balancedue,0)+$1, paidstatus=''U'', pay_id=NULL WHERE dem_id=$2 AND ins_id=$3', v)
        USING d.transtotalamount, d.dem_id, p_ins_id;
    END IF;
  END LOOP;

  EXECUTE format('UPDATE %I.paymentdetails SET activestatus=9 WHERE pay_id=$1', v) USING p_pay_id;
  EXECUTE format('UPDATE %I.payment SET activestatus=9, paystatus=''R'', voidedby=$1, voideddate=now(), voidreason=$2 WHERE pay_id=$3', v)
    USING p_user, NULLIF(TRIM(COALESCE(p_reason, '')), ''), p_pay_id;

  RETURN jsonb_build_object('voided', p_pay_id, 'paynumber', p.paynumber);
END; $$;

GRANT EXECUTE ON FUNCTION public.void_receipt(integer, bigint, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload config';


-- ####################################################################
-- >>> daily_collection_include_refunded.sql  (Daily Collection fix)
-- ####################################################################
-- A receipt that was later refunded (paystatus 'C'->'R' via process_refund) was
-- vanishing from its ORIGINAL collection date because the report filtered
-- paystatus='C'. Include paystatus IN ('C','R') with activestatus=1 (voided
-- receipts are activestatus=9, still excluded) so the refunded receipt still
-- shows as a full collection on the day it was collected. The refund is listed
-- separately (by refund date) in the report's Refunds section.
-- ####################################################################

DROP FUNCTION IF EXISTS public.get_daily_collection_report(TEXT, INT, DATE, DATE);
CREATE OR REPLACE FUNCTION public.get_daily_collection_report(
    p_schema TEXT, p_ins_id INT, p_from DATE, p_to DATE
) RETURNS TABLE (
    pay_id BIGINT, paynumber TEXT, stuadmno TEXT, stuname TEXT,
    courname TEXT, stuclass TEXT, semester TEXT, type TEXT, paymethod TEXT, createdby TEXT,
    fees_json JSONB, fine NUMERIC, total NUMERIC, paydate DATE
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  p.pay_id::BIGINT,
                p.paynumber::TEXT,
                s.stuadmno::TEXT,
                s.stuname::TEXT,
                s.courname::TEXT,
                s.stuclass::TEXT,
                COALESCE(fd.demfeeterm, '')::TEXT AS semester,
                (CASE WHEN BOOL_OR(UPPER(COALESCE(fd.demseqtype,''))='ARREAR') THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                p.paymethod::TEXT,
                COALESCE(p.createdby, '')::TEXT AS createdby,
                COALESCE(jsonb_object_agg(fd.demfeetype, pd.transtotalamount)
                         FILTER (WHERE fd.demfeetype IS NOT NULL),
                         '{}'::jsonb) AS fees_json,
                COALESCE(SUM(fd.fineamount), 0)::NUMERIC AS fine,
                COALESCE(SUM(pd.transtotalamount), MAX(p.transtotalamount), 0)::NUMERIC AS total,
                p.paydate::DATE
        FROM    %1$I.payment p
        LEFT JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
        LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
        LEFT JOIN %1$I.students s ON s.stu_id = p.stu_id
        WHERE   p.ins_id = %2$L AND p.activestatus = 1
            AND p.paystatus IN ('C','R') AND p.recon_status = 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $$;

GRANT EXECUTE ON FUNCTION public.get_daily_collection_report(TEXT, INT, DATE, DATE) TO anon, authenticated;


-- ####################################################################
-- >>> add_propagate_class_fee.sql  (Fee Master save speed-up)
-- ####################################################################
-- Set-based propagation of a class-fee template to existing unpaid feedemand
-- rows — one UPDATE per fee line instead of an N+1 (SELECT + per-row rebuild).
-- Client keeps the per-row loop as a fallback, so this is non-breaking.
-- ####################################################################

CREATE OR REPLACE FUNCTION public.propagate_class_fee(
  p_ins_id integer, p_class text, p_term text, p_lines jsonb, p_admnos text[] DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v text; ln jsonb; total int := 0; n int;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema found for ins_id %', p_ins_id; END IF;
  FOR ln IN SELECT * FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) LOOP
    EXECUTE format(
      'UPDATE %I.feedemand SET feeamount = $1, '
      'balancedue = GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0), '
      'reconbalancedue = GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0), '
      'collectible = $2 '
      'WHERE ins_id = $3 AND stuclass = $4 AND demfeeterm = $5 AND demfeetype = $6 '
      'AND paidstatus = ''U'' AND activestatus = 1 '
      'AND ($7::text[] IS NULL OR stuadmno = ANY($7))', v)
    USING (ln->>'amount')::numeric, COALESCE((ln->>'collectible')::boolean, true),
          p_ins_id, p_class, p_term, (ln->>'feetype'), p_admnos;
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
  END LOOP;
  RETURN total;
END; $$;
GRANT EXECUTE ON FUNCTION public.propagate_class_fee(integer, text, text, jsonb, text[]) TO anon, authenticated;
NOTIFY pgrst, 'reload config';


-- ####################################################################
-- >>> get_super_admin_dashboard_v2  (SuperAdmin dashboard speed-up, #4)
-- ####################################################################
-- Server-side per-institution aggregate that returns pending_approval +
-- today_collected in ONE call. The SuperAdmin dashboard uses this instead
-- of a slow per-institution client fan-out (chunked paymentdetails +
-- feedemand scans). If this RPC is present the fan-out never runs; deploy
-- this to guarantee the fast path (authoritative latest version).
-- ####################################################################

CREATE OR REPLACE FUNCTION public.get_super_admin_dashboard_v2(p_yrlabel text DEFAULT NULL)
RETURNS TABLE (
    ins_id           INT,
    insname          TEXT,
    inscode          TEXT,
    inshortname      TEXT,
    inslogo          TEXT,
    activestatus     SMALLINT,
    student_count    INT,
    total_demand     NUMERIC,
    total_collected  NUMERIC,
    total_pending    NUMERIC,
    pending_approval NUMERIC,
    today_collected  NUMERIC
) LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    rec       RECORD;
    schema_n  TEXT;
    short_n   TEXT;
    yr_label  TEXT;
    demand    NUMERIC;
    collected NUMERIC;
    pending   NUMERIC;
    pending_a NUMERIC;
    today_c   NUMERIC;
    stu_cnt   INT;
BEGIN
    FOR rec IN
        SELECT i.ins_id, i.insname, i.inscode, i.inshortname, i.inslogo, i.activestatus
        FROM   public.institution i
        ORDER  BY i.ins_id
    LOOP
        short_n  := lower(rec.inshortname);
        yr_label := NULL;
        IF p_yrlabel IS NOT NULL AND btrim(p_yrlabel) <> '' THEN
            SELECT iy.yrlabel INTO yr_label
            FROM   public.institutionyear iy
            WHERE  iy.ins_id = rec.ins_id AND iy.activestatus = 1 AND iy.yrlabel = p_yrlabel
            LIMIT  1;
        END IF;
        IF yr_label IS NULL THEN
            SELECT iy.yrlabel INTO yr_label
            FROM   public.institutionyear iy
            WHERE  iy.ins_id = rec.ins_id AND iy.activestatus = 1
            ORDER  BY iy.iyr_id DESC
            LIMIT  1;
        END IF;

        IF yr_label IS NULL OR short_n IS NULL THEN
            ins_id := rec.ins_id; insname := rec.insname; inscode := rec.inscode;
            inshortname := rec.inshortname; inslogo := rec.inslogo; activestatus := rec.activestatus;
            student_count := 0; total_demand := 0; total_collected := 0; total_pending := 0;
            pending_approval := 0; today_collected := 0;
            RETURN NEXT; CONTINUE;
        END IF;
        schema_n := short_n || replace(yr_label, '-', '');

        IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = schema_n) THEN
            ins_id := rec.ins_id; insname := rec.insname; inscode := rec.inscode;
            inshortname := rec.inshortname; inslogo := rec.inslogo; activestatus := rec.activestatus;
            student_count := 0; total_demand := 0; total_collected := 0; total_pending := 0;
            pending_approval := 0; today_collected := 0;
            RETURN NEXT; CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)), 0)
            FROM   %1$I.payment p
            JOIN   %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
            JOIN   %1$I.feedemand fd ON fd.dem_id = pd.dem_id
            WHERE  p.ins_id = %2$L AND p.activestatus = 1 AND p.paystatus = 'C'
              AND  p.recon_status = 'P' AND fd.activestatus = 1
        $q$, schema_n, rec.ins_id)
        INTO pending_a;

        EXECUTE format($q$
            SELECT
                COALESCE(SUM(feeamount), 0),
                COALESCE(SUM(balancedue), 0) + %3$L::numeric,
                COALESCE(SUM(feeamount), 0) - (COALESCE(SUM(balancedue), 0) + %3$L::numeric)
            FROM %1$I.feedemand WHERE ins_id = %2$L AND activestatus = 1
        $q$, schema_n, rec.ins_id, pending_a)
        INTO demand, pending, collected;

        -- recon_status='R' only: Today Collection counts RECONCILED money (cash
        -- auto-reconciles). Unreconciled payments are Pending Approval, not
        -- collection — matches the institution dashboard's Today Collection.
        EXECUTE format($q$
            SELECT COALESCE(SUM(transtotalamount), 0)
            FROM %1$I.payment
            WHERE ins_id = %2$L AND activestatus = 1 AND paystatus = 'C'
              AND recon_status = 'R'
              AND paydate >= CURRENT_DATE AND paydate < CURRENT_DATE + 1
        $q$, schema_n, rec.ins_id)
        INTO today_c;

        EXECUTE format($q$
            SELECT COUNT(*) FROM %I.students WHERE ins_id = %L AND activestatus = 1
        $q$, schema_n, rec.ins_id)
        INTO stu_cnt;

        ins_id := rec.ins_id; insname := rec.insname; inscode := rec.inscode;
        inshortname := rec.inshortname; inslogo := rec.inslogo; activestatus := rec.activestatus;
        student_count := stu_cnt; total_demand := demand; total_collected := collected;
        total_pending := pending; pending_approval := pending_a; today_collected := today_c;
        RETURN NEXT;
    END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION public.get_super_admin_dashboard_v2(text) TO anon, authenticated;


-- ####################################################################
-- >>> fix_student_import_rls.sql  (Supabase Advisor: RLS Disabled)
-- ####################################################################
DO $$
DECLARE r record; sname text;
BEGIN
  FOR r IN SELECT table_schema FROM information_schema.tables WHERE table_name = 'student_import' LOOP
    sname := r.table_schema;
    EXECUTE format('ALTER TABLE %I.student_import ENABLE ROW LEVEL SECURITY', sname);
    BEGIN EXECUTE format('DROP POLICY IF EXISTS "Allow all" ON %I.student_import', sname); EXCEPTION WHEN OTHERS THEN NULL; END;
    EXECUTE format('CREATE POLICY "Allow all" ON %I.student_import FOR ALL TO anon, authenticated USING (true) WITH CHECK (true)', sname);
  END LOOP;
END $$;
