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
