-- =====================================================================
-- EduCore360 - all outstanding migrations, in dependency order.
-- Generated from migrations/*.sql; run the whole file in the Supabase
-- SQL editor. Every section is idempotent, so re-running is safe.
--
-- Order matters only in one place: allocate_carry_student_ids must come
-- after admission_default_admit_cour_id (both touch admit_cour_id).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1/8  tc_entry_and_status.sql
--      Transfer Certificate: widen activestatus codes, create tc_entry, add save/delete RPCs
-- ---------------------------------------------------------------------
-- Transfer Certificate module (Admission → Transfer Certificate).
-- 1) Widen activestatus on students (all schemas) + public.admission to allow the
--    leaving codes: 1 active, 2 discontinued, 3 transferred, 4 completed,
--    5 others, 9 terminated. (Was students 1/2/9, admission 1/9.)
-- 2) Create a per-schema tc_entry table (+ id trigger, RLS, grants) in every schema.
-- 3) Create save_tc_entry / delete_tc_entry RPCs.
-- DB-only; safe to re-run.

-- 1a) Widen public.admission.activestatus check.
DO $$
DECLARE v_con text;
BEGIN
  FOR v_con IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'public.admission'::regclass AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%activestatus%'
  LOOP
    EXECUTE format('ALTER TABLE public.admission DROP CONSTRAINT %I', v_con);
  END LOOP;
  ALTER TABLE public.admission
    ADD CONSTRAINT admission_activestatus_check
    CHECK (activestatus = ANY (ARRAY[1,2,3,4,5,9]));
END $$;

-- 1b + 2) Per-schema: widen students.activestatus + create tc_entry.
DO $$
DECLARE r RECORD; v_schema text; v_con text;
BEGIN
  FOR r IN SELECT DISTINCT ins_id FROM public.admission WHERE ins_id IS NOT NULL LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;
    BEGIN
      -- widen students.activestatus
      FOR v_con IN
        SELECT conname FROM pg_constraint
         WHERE conrelid = (quote_ident(v_schema) || '.students')::regclass AND contype = 'c'
           AND pg_get_constraintdef(oid) ILIKE '%activestatus%'
      LOOP
        EXECUTE format('ALTER TABLE %I.students DROP CONSTRAINT %I', v_schema, v_con);
      END LOOP;
      EXECUTE format('ALTER TABLE %I.students ADD CONSTRAINT students_activestatus_check CHECK (activestatus = ANY(ARRAY[1,2,3,4,5,9]))', v_schema);

      -- tc_entry table (+ id trigger, RLS, grants) if missing
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = v_schema AND table_name = 'tc_entry'
      ) THEN
        EXECUTE format('CREATE TABLE %I.tc_entry (tc_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), stu_id bigint, stuadmno varchar(25) NOT NULL, stuname varchar(50), stuclass varchar(20), cla_id smallint, birthdate date, joindate date, status smallint NOT NULL DEFAULT 1 CHECK (status = ANY(ARRAY[1,2,3,4,5,9])), statustype varchar(20), tcno varchar(30), tcdate date, effectfrom date, docno varchar(30), docdate date, remarks varchar(200), createdby varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
        EXECUTE format('CREATE SEQUENCE %I.tc_entry_tc_id_seq', v_schema);
        EXECUTE format('CREATE FUNCTION %I.set_tc_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.tc_id IS NULL OR NEW.tc_id = 0 THEN NEW.tc_id := nextval(''%I.tc_entry_tc_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
        EXECUTE format('CREATE TRIGGER trg_tc_entry_tc_id BEFORE INSERT ON %I.tc_entry FOR EACH ROW EXECUTE FUNCTION %I.set_tc_id()', v_schema, v_schema);
        EXECUTE format('ALTER TABLE %I.tc_entry ENABLE ROW LEVEL SECURITY', v_schema);
        EXECUTE format('CREATE POLICY "Allow all" ON %I.tc_entry USING (true) WITH CHECK (true)', v_schema);
        EXECUTE format('GRANT ALL ON %I.tc_entry TO anon, authenticated', v_schema);
        EXECUTE format('GRANT ALL ON SEQUENCE %I.tc_entry_tc_id_seq TO anon, authenticated', v_schema);
      END IF;
      -- statustype (status label) column for existing tc_entry tables + backfill.
      EXECUTE format('ALTER TABLE %I.tc_entry ADD COLUMN IF NOT EXISTS statustype varchar(20)', v_schema);
      EXECUTE format($u$UPDATE %I.tc_entry SET statustype = CASE status WHEN 1 THEN 'Active' WHEN 2 THEN 'Discontinued' WHEN 3 THEN 'Transferred' WHEN 4 THEN 'Completed' WHEN 5 THEN 'Others' WHEN 9 THEN 'Terminated' END WHERE statustype IS NULL$u$, v_schema);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'tc_entry/status migration skip schema %: %', v_schema, SQLERRM;
    END;
  END LOOP;
END $$;

-- 3) RPCs.
CREATE OR REPLACE FUNCTION public.save_tc_entry(p_token text, p_data jsonb, p_tc_id bigint DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_inscode varchar(10); v_tc_id bigint;
  v_yr_id int; v_yrlabel text;
  v_admno   text     := p_data->>'stuadmno';
  v_status  smallint := COALESCE(NULLIF(p_data->>'status','')::smallint, 1);
  v_statustype text := CASE COALESCE(NULLIF(p_data->>'status','')::smallint, 1)
    WHEN 1 THEN 'Active' WHEN 2 THEN 'Discontinued' WHEN 3 THEN 'Transferred'
    WHEN 4 THEN 'Completed' WHEN 5 THEN 'Others' WHEN 9 THEN 'Terminated' ELSE NULL END;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF v_admno IS NULL OR TRIM(v_admno) = '' THEN RAISE EXCEPTION 'Admission number is required'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;
  -- Resolve the active academic year server-side (the client doesn't send it).
  EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
    INTO v_yr_id, v_yrlabel USING v_ins;

  IF p_tc_id IS NULL THEN
    EXECUTE format(
      'INSERT INTO %I.tc_entry (ins_id, inscode, yr_id, yrlabel, stu_id, stuadmno, stuname, stuclass, cla_id, '
      ' birthdate, joindate, status, tcno, tcdate, effectfrom, docno, docdate, remarks, createdby, statustype) '
      'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20) RETURNING tc_id', v_schema)
    INTO v_tc_id
    USING v_ins, v_inscode,
          COALESCE(NULLIF(p_data->>'yr_id','')::int, v_yr_id), COALESCE(NULLIF(p_data->>'yrlabel',''), v_yrlabel),
          NULLIF(p_data->>'stu_id','')::bigint, v_admno, p_data->>'stuname', p_data->>'stuclass',
          NULLIF(p_data->>'cla_id','')::smallint,
          NULLIF(p_data->>'birthdate','')::date, NULLIF(p_data->>'joindate','')::date, v_status,
          p_data->>'tcno', NULLIF(p_data->>'tcdate','')::date, NULLIF(p_data->>'effectfrom','')::date,
          p_data->>'docno', NULLIF(p_data->>'docdate','')::date, p_data->>'remarks', p_data->>'createdby', v_statustype;
  ELSE
    v_tc_id := p_tc_id;
    EXECUTE format(
      'UPDATE %I.tc_entry SET status=$1, statustype=$13, tcno=$2, tcdate=$3, effectfrom=$4, docno=$5, docdate=$6, remarks=$7, '
      ' stuclass=COALESCE($8,stuclass), birthdate=COALESCE($9,birthdate), joindate=COALESCE($10,joindate) '
      'WHERE tc_id=$11 AND ins_id=$12', v_schema)
    USING v_status, p_data->>'tcno', NULLIF(p_data->>'tcdate','')::date, NULLIF(p_data->>'effectfrom','')::date,
          p_data->>'docno', NULLIF(p_data->>'docdate','')::date, p_data->>'remarks',
          p_data->>'stuclass', NULLIF(p_data->>'birthdate','')::date, NULLIF(p_data->>'joindate','')::date,
          v_tc_id, v_ins, v_statustype;
  END IF;

  EXECUTE format('UPDATE %I.students SET activestatus=$1 WHERE stuadmno=$2 AND ins_id=$3', v_schema)
    USING v_status, v_admno, v_ins;
  UPDATE public.admission SET activestatus = v_status WHERE admno = v_admno AND ins_id = v_ins;

  RETURN v_tc_id;
END; $$;

CREATE OR REPLACE FUNCTION public.delete_tc_entry(p_token text, p_tc_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text; v_admno text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  EXECUTE format('SELECT stuadmno FROM %I.tc_entry WHERE tc_id=$1 AND ins_id=$2', v_schema)
    INTO v_admno USING p_tc_id, v_ins;
  EXECUTE format('DELETE FROM %I.tc_entry WHERE tc_id=$1 AND ins_id=$2', v_schema) USING p_tc_id, v_ins;

  IF v_admno IS NOT NULL THEN
    EXECUTE format('UPDATE %I.students SET activestatus=1 WHERE stuadmno=$1 AND ins_id=$2', v_schema)
      USING v_admno, v_ins;
    UPDATE public.admission SET activestatus = 1 WHERE admno = v_admno AND ins_id = v_ins;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.save_tc_entry(text, jsonb, bigint) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_tc_entry(text, bigint)      TO anon, authenticated;

-- ---------------------------------------------------------------------
-- 2/8  rollno_change.sql
--      New Roll Number: public.rollno_change + save_rollno_change (renumber + cascade)
-- ---------------------------------------------------------------------
-- New Roll Number (Admission → New Roll Number).
-- 1) public.rollno_change log table (+ same-date unique, RLS, grants). It lives
--    in public, alongside public.admission, because a renumber spans both sides:
--    the shared admission row and the tenant's students row move together.
-- 2) Drops any earlier PER-SCHEMA rollno_change (superseded by the public one).
-- 3) save_rollno_change RPC: renumbers a student by replacing stuadmno on
--    students and CASCADING the new number to every table keyed by stuadmno
--    (feedemand, tempfeedemand, concession, concessiondetail, fee_refund,
--    parentdetail, tc_entry, interim_promotion) plus public.admission.admno —
--    all in ONE transaction — then logs the change.
-- DB-only; safe to re-run.

CREATE TABLE IF NOT EXISTS public.rollno_change (
  rc_id        bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ins_id       integer     NOT NULL,
  inscode      varchar(10),
  stu_id       bigint,
  oldrollno    varchar(25) NOT NULL,
  newrollno    varchar(25) NOT NULL,
  stuname      varchar(50),
  stuclass     varchar(20),
  cla_id       smallint,
  effectdate   date        NOT NULL,
  createdby    varchar(50),
  createdon    timestamp   DEFAULT now() NOT NULL,
  activestatus smallint    DEFAULT 1 NOT NULL
);
-- An earlier cut of this file carried the academic year; a renumber isn't
-- year-scoped (effectdate carries the timing), so drop them if already created.
ALTER TABLE public.rollno_change
  DROP COLUMN IF EXISTS yr_id,
  DROP COLUMN IF EXISTS yrlabel;
-- VB rule: a student's roll number may not be updated twice on one date.
CREATE UNIQUE INDEX IF NOT EXISTS uq_rollno_change_day
  ON public.rollno_change (ins_id, stu_id, effectdate);
CREATE INDEX IF NOT EXISTS idx_rollno_change_ins
  ON public.rollno_change (ins_id, effectdate DESC);
ALTER TABLE public.rollno_change ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow all" ON public.rollno_change;
CREATE POLICY "Allow all" ON public.rollno_change USING (true) WITH CHECK (true);
GRANT ALL ON public.rollno_change TO anon, authenticated;

-- Retire the per-schema copy created by the first cut of this migration. It has
-- no rows in any live DB (the screen has never been shipped), so this is a plain
-- drop; the trigger fn and its sequence go with it.
DO $$
DECLARE r RECORD; v_schema text;
BEGIN
  FOR r IN SELECT DISTINCT ins_id FROM public.admission WHERE ins_id IS NOT NULL LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;
    BEGIN
      EXECUTE format('DROP TABLE IF EXISTS %I.rollno_change', v_schema);
      EXECUTE format('DROP FUNCTION IF EXISTS %I.set_rc_id()', v_schema);
      EXECUTE format('DROP SEQUENCE IF EXISTS %I.rollno_change_rc_id_seq', v_schema);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'rollno_change drop skip schema %: %', v_schema, SQLERRM;
    END;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.save_rollno_change(
  p_token text, p_effectdate date, p_rows jsonb, p_createdby text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_inscode varchar(10);
  itm RECORD; v_count int := 0; v_exists boolean; v_tbl text;
  v_stuid bigint; v_stuname text; v_stuclass text; v_claid smallint;
  v_old text; v_new text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;

  FOR itm IN SELECT * FROM jsonb_to_recordset(p_rows) AS x(oldrollno text, newrollno text)
  LOOP
    v_old := TRIM(COALESCE(itm.oldrollno, ''));
    v_new := TRIM(COALESCE(itm.newrollno, ''));
    CONTINUE WHEN v_new = '' OR v_old = '' OR v_new = v_old;

    EXECUTE format('SELECT stu_id, stuname, stuclass, cla_id FROM %I.students WHERE ins_id=$1 AND stuadmno=$2 LIMIT 1', v_schema)
      INTO v_stuid, v_stuname, v_stuclass, v_claid USING v_ins, v_old;
    IF v_stuid IS NULL THEN CONTINUE; END IF;

    -- the new number must be free (students + admission both have UNIQUE on it)
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.students WHERE ins_id=$1 AND stuadmno=$2 AND stu_id<>$3)', v_schema)
      INTO v_exists USING v_ins, v_new, v_stuid;
    IF v_exists THEN RAISE EXCEPTION 'Roll number % is already in use by another student', v_new; END IF;
    -- ...including a pending admission not yet allocated, which would otherwise
    -- break the admission UNIQUE(ins_id, admno) mid-cascade.
    SELECT EXISTS(SELECT 1 FROM public.admission WHERE ins_id = v_ins AND admno = v_new)
      INTO v_exists;
    IF v_exists THEN RAISE EXCEPTION 'Roll number % is already used by an admission record', v_new; END IF;

    -- one renumber per student per effect date
    SELECT EXISTS(SELECT 1 FROM public.rollno_change
                   WHERE ins_id = v_ins AND stu_id = v_stuid AND effectdate = p_effectdate)
      INTO v_exists;
    IF v_exists THEN
      RAISE EXCEPTION 'Roll number % was already updated on %', v_old, p_effectdate;
    END IF;

    EXECUTE format('UPDATE %I.students SET stuadmno=$1 WHERE ins_id=$2 AND stuadmno=$3', v_schema)
      USING v_new, v_ins, v_old;
    FOREACH v_tbl IN ARRAY ARRAY['feedemand','tempfeedemand','concession','concessiondetail',
                                 'fee_refund','parentdetail','tc_entry','interim_promotion'] LOOP
      BEGIN
        EXECUTE format('UPDATE %I.%I SET stuadmno=$1 WHERE ins_id=$2 AND stuadmno=$3', v_schema, v_tbl)
          USING v_new, v_ins, v_old;
      EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
      END;
    END LOOP;
    UPDATE public.admission SET admno = v_new WHERE ins_id = v_ins AND admno = v_old;

    INSERT INTO public.rollno_change(ins_id, inscode, stu_id, oldrollno, newrollno,
                                     stuname, stuclass, cla_id, effectdate, createdby)
    VALUES (v_ins, v_inscode, v_stuid, v_old, v_new,
            v_stuname, v_stuclass, v_claid, p_effectdate, p_createdby);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END; $$;

GRANT EXECUTE ON FUNCTION public.save_rollno_change(text, date, jsonb, text) TO anon, authenticated;

-- ---------------------------------------------------------------------
-- 3/8  concession_refund_doc_sequence.sql
--      Fee Concession / Fee Refund: doc_no from the CONNO / REFNO sequences
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 4/8  admission_default_admit_cour_id.sql
--      public.admission: default admit_cour_id from cour_id on insert, + backfill
-- ---------------------------------------------------------------------
-- admit_cour_id (the originally-admitted course) was left NULL on admissions
-- created by paths that didn't supply it (older builds / imports without the
-- column), even though cour_id was set. This adds a BEFORE INSERT default so
-- every future admission gets admit_cour_id = cour_id when not supplied, and
-- backfills existing rows. DB-only; safe to re-run.
--
-- Note: a course TRANSFER changes cour_id but deliberately leaves admit_cour_id
-- unchanged (the admitted course is fixed at admission), so this default is
-- INSERT-only and never disturbs transferred records.

CREATE OR REPLACE FUNCTION public.admission_default_admit_cour()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.admit_cour_id IS NULL AND NEW.cour_id IS NOT NULL THEN
    NEW.admit_cour_id := NEW.cour_id::smallint;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_admission_default_admit_cour ON public.admission;
CREATE TRIGGER trg_admission_default_admit_cour
  BEFORE INSERT ON public.admission
  FOR EACH ROW EXECUTE FUNCTION public.admission_default_admit_cour();

-- One-time backfill of existing rows: set the admitted course to the enrolled
-- course wherever it's missing.
UPDATE public.admission
   SET admit_cour_id = cour_id::smallint
 WHERE admit_cour_id IS NULL
   AND cour_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 5/8  allocate_carry_student_ids.sql
--      Allocation carries admit_cour_id to students; no fee demands generated on allocation
-- ---------------------------------------------------------------------
-- allocate_admission_to_student: carry the id columns onto the new student row.
-- Previously the students INSERT copied only the NAME columns (stuclass, courname,
-- admname, quoname) from the admission, leaving cla_id / cour_id / adm_id / quo_id /
-- medium / admit_cour_id NULL even though public.admission has them. This patch
-- resolves cla_id/cour_id from the allocated class and carries adm_id (from
-- admission.admtype_id) / quo_id / medium / admit_cour_id from the admission row.
-- Plus a one-time backfill (incl. admit_cour_id) for existing students across all
-- institution schemas.
--
-- ALSO: fee demand is no longer generated on allocation — enrolment creates the
-- student (+ parent) only; demands are raised separately from the Fee Demand
-- screen. The tempfeedemand INSERT has been removed from the function.
-- DB-only; safe to re-run.

CREATE OR REPLACE FUNCTION public.allocate_admission_to_student(
  p_adm_id      bigint,
  p_schema      text,
  p_class       text,
  p_stuadmno    text,
  p_allocatedby text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$
DECLARE
  v_schema   text := lower(p_schema);
  v          public.admission%ROWTYPE;
  v_stu_id   bigint;
  v_par_id   bigint;
  v_yr_id    integer;
  v_yrlabel  varchar(9);
  v_adm_id   smallint;
  v_cla_id   smallint;
  v_cour_id  integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
    RAISE EXCEPTION 'allocate_admission: schema % does not exist', v_schema;
  END IF;

  SELECT * INTO v FROM public.admission WHERE adm_id = p_adm_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Admission % not found', p_adm_id; END IF;
  IF v.admstatus = 'ALLOCATED' THEN
    RAISE EXCEPTION 'Admission % is already allocated', p_adm_id;
  END IF;

  EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
    INTO v_yr_id, v_yrlabel USING v.ins_id;
  IF v_yr_id IS NULL THEN
    RAISE EXCEPTION 'allocate_admission: cannot resolve academic year for schema %', v_schema;
  END IF;

  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS aadharno      varchar(20)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS community     varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS caste         varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS religion      varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS nationality   varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS transportmode varchar(20)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS hostel        char(1)', v_schema);

  -- Resolve the allocated class's ids (p_class can differ from the admission's
  -- preferred class); adm_id (from admission.admtype_id) / quo_id / medium come
  -- from the admission row.
  EXECUTE format('SELECT cla_id, cour_id FROM %I.class WHERE UPPER(TRIM(claname))=UPPER(TRIM($1)) AND activestatus=1 ORDER BY cla_id LIMIT 1', v_schema)
    INTO v_cla_id, v_cour_id USING p_class;

  EXECUTE format(
    'INSERT INTO %I.students '
    '(ins_id, inscode, yr_id, yrlabel, stuadmno, stuadmdate, stuname, stugender, studob, '
    ' stumobile, stuemail, stuaddress, stucity, stustate, stucountry, stupin, stubloodgrp, stuphoto, '
    ' stuclass, courname, con_id, stucondesc, stuser_id, stuotpstatus, '
    ' approvedby, approveddate, activestatus, createdon, batch, admname, quoname, admittyear, aadharno, '
    ' community, caste, religion, nationality, transportmode, hostel, cla_id, cour_id, adm_id, quo_id, medium, admit_cour_id) '
    'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,'
    ' $19,$20,$21,$22,$5,0,$23,now(),1,now(),$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34,'
    ' $35,$36,$37,$38,$39,$40) RETURNING stu_id', v_schema)
  INTO v_stu_id
  USING v.ins_id, v.inscode, v_yr_id, v_yrlabel, p_stuadmno, COALESCE(v.admdate, CURRENT_DATE),
        v.stuname, v.stugender, v.studob, v.stumobile, v.stuemail, v.stuaddress, v.stucity,
        v.stustate, v.stucountry, v.stupin, v.stubloodgrp, v.stuphoto, p_class, v.courname,
        v.con_id, v.stucondesc, p_allocatedby, v.batch, v.admname, v.quoname, v.admittyear, v.aadharno,
        v.community, v.caste, v.religion, v.nationality, v.transportmode, v.hostel,
        COALESCE(v_cla_id, v.cla_id), COALESCE(v_cour_id, v.cour_id), v.admtype_id, v.quo_id, v.medium,
        COALESCE(v.admit_cour_id, v_cour_id, v.cour_id);

  IF v.payinchargemob IS NOT NULL AND TRIM(v.payinchargemob) <> '' THEN
    EXECUTE format('SELECT par_id FROM %I.parents WHERE payinchargemob = $1 LIMIT 1', v_schema)
      INTO v_par_id USING v.payinchargemob;
    IF v_par_id IS NULL THEN
      EXECUTE format('ALTER TABLE %I.parents ADD COLUMN IF NOT EXISTS paremail varchar(254)', v_schema);
      EXECUTE format(
        'INSERT INTO %I.parents '
        '(ins_id, yr_id, yrlabel, partype, fathername, fathermobile, fatheroccupation, '
        ' mothername, mothermobile, motheroccupation, guardianname, guardianmobile, guardianoccupation, '
        ' payincharge, payinchargemob, paremail, parotpstatus, approveddate, activestatus) '
        'VALUES ($1,$2,$3,''P'',$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,NULLIF(TRIM($15),''''),0,now(),1) RETURNING par_id', v_schema)
      INTO v_par_id
      USING v.ins_id, v_yr_id, v_yrlabel, v.fathername, v.fathermobile, v.fatheroccupation,
            v.mothername, v.mothermobile, v.motheroccupation, v.guardianname, v.guardianmobile,
            v.guardianoccupation, COALESCE(NULLIF(TRIM(v.payincharge), ''), v.stuname), v.payinchargemob, v.paremail;
    END IF;

    EXECUTE format(
      'INSERT INTO %I.parentdetail '
      '(yr_id, yrlabel, par_id, stu_id, ins_id, inscode, stuadmno, stuname, stuclass, activestatus) '
      'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema)
    USING v_yr_id, v_yrlabel, v_par_id, v_stu_id, v.ins_id, v.inscode, p_stuadmno, v.stuname, p_class;
  END IF;

  UPDATE public.admission
     SET allocatedclass = p_class, admstatus = 'ALLOCATED',
         allocatedby = p_allocatedby, allocateddate = now()
   WHERE adm_id = p_adm_id;

  -- NOTE: fee demand is deliberately NOT generated on admission/allocation.
  -- Enrolment creates the student (+ parent) only; fee demands are raised
  -- separately from the Fee Demand screen (generate_feedemand_*). Allocation
  -- therefore never seeds tempfeedemand. (v_adm_id stays declared but unused.)

  RETURN json_build_object(
    'adm_id', p_adm_id, 'stu_id', v_stu_id, 'par_id', v_par_id,
    'stuadmno', p_stuadmno, 'class', p_class, 'status', 'ALLOCATED');
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.allocate_admission_to_student(bigint, text, text, text, text) TO anon, authenticated;

-- One-time backfill of existing students across ALL institution schemas:
-- copy the id columns from the matching public.admission row (by admno) where
-- the student's are NULL. Guarded per schema so one failure doesn't abort.
DO $backfill$
DECLARE r RECORD; v_schema text;
BEGIN
  FOR r IN SELECT DISTINCT ins_id FROM public.admission WHERE ins_id IS NOT NULL LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;
    BEGIN
      EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS cla_id smallint', v_schema);
      EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS cour_id integer', v_schema);
      EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS adm_id smallint', v_schema);
      EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS quo_id smallint', v_schema);
      EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS medium varchar(30)', v_schema);
      EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS admit_cour_id smallint', v_schema);
      EXECUTE format($q$
        UPDATE %1$I.students s SET
          cla_id        = COALESCE(s.cla_id,        a.cla_id),
          cour_id       = COALESCE(s.cour_id,       a.cour_id),
          adm_id        = COALESCE(s.adm_id,        a.admtype_id),
          quo_id        = COALESCE(s.quo_id,        a.quo_id),
          medium        = COALESCE(s.medium,        a.medium),
          admit_cour_id = COALESCE(s.admit_cour_id, a.admit_cour_id, a.cour_id::smallint)
        FROM public.admission a
        WHERE a.admno = s.stuadmno AND a.ins_id = s.ins_id
          AND a.activestatus = 1 AND s.activestatus <> 9
      $q$, v_schema);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'backfill skip schema %: %', v_schema, SQLERRM;
    END;
  END LOOP;
END
$backfill$;

-- ---------------------------------------------------------------------
-- 6/8  transfer_history_same_day.sql
--      Course Transfer: one history row per student per date; new demands are collectible
-- ---------------------------------------------------------------------
-- Course Transfer: two fixes to transfer_course_with_credit.
--
-- 1) ONE history row per student per DATE. It always INSERTed into
--    interim_promotion, so transferring the same student twice on one day left
--    two rows. The VB original (frmClassTransfer) keys studhist on
--    studid + tdate and UPDATEs an existing same-date row instead; this matches
--    that, and mirrors the same-day rule New Roll Number enforces with
--    uq_rollno_change_day.
--
-- 2) New demands are always COLLECTIBLE. classfeedemand.collectible defaults to
--    FALSE, and the transfer inherited it -- so the fees the operator had just
--    ticked and priced never showed up in Fee Collection and could not be paid.
--
-- DB-only, no schema change; safe to re-run.

CREATE OR REPLACE FUNCTION public.transfer_course_with_credit(
  p_ins_id integer, p_stu_id bigint,
  p_target_class text, p_target_course text,
  p_credits jsonb,            -- [{"cf_id": int, "feeamt": numeric, "credit": numeric}]
  p_doc_no integer, p_promotion_date date,
  p_created_by text, p_remarks text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '60s'
AS $$
DECLARE
  v text;
  v_paid numeric; v_remaining numeric; v_applied numeric := 0; v_new_count int := 0;
  v_stuadmno text; v_stuname text; v_old_course text; v_old_class text;
  v_log_rows integer;
  v_yr_id int; v_yrlabel text; v_inscode text; v_con_id int; v_admname text; v_adm_id smallint;
  cf RECORD; v_credit numeric;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

  EXECUTE format('SELECT stuadmno, stuname, courname, stuclass, yr_id, yrlabel, inscode, con_id, admname, adm_id FROM %I.students WHERE stu_id=$1', v)
    INTO v_stuadmno, v_stuname, v_old_course, v_old_class, v_yr_id, v_yrlabel, v_inscode, v_con_id, v_admname, v_adm_id
    USING p_stu_id;
  IF v_stuadmno IS NULL THEN RAISE EXCEPTION 'Student % not found', p_stu_id; END IF;

  -- The credit pool = what the student already paid on the current course.
  EXECUTE format('SELECT COALESCE(SUM(paidamount),0) FROM %I.feedemand WHERE stu_id=$1 AND activestatus=1', v)
    INTO v_paid USING p_stu_id;
  v_remaining := v_paid;

  -- 1) Settle / drop the old course demands.
  --    paid = 0 -> delete (nothing collected); paid > 0 -> keep but reduce the
  --    demand to the paid amount (balance 0, Paid) as a settled record.
  EXECUTE format('DELETE FROM %I.feedemand WHERE stu_id=$1 AND activestatus=1 AND COALESCE(paidamount,0)=0', v)
    USING p_stu_id;
  EXECUTE format($u$UPDATE %I.feedemand
      SET feeamount=paidamount, conamount=0, balancedue=0, reconbalancedue=0, paidstatus='P'
      WHERE stu_id=$1 AND activestatus=1 AND COALESCE(paidamount,0)>0$u$, v)
    USING p_stu_id;

  -- 2) Move the student to the new class/course (names + resolved ids). cla_id
  --    and cour_id come from the target class (class.cla_id / class.cour_id),
  --    else a course-name match, else kept as-is.
  EXECUTE format($su$
    WITH tc AS (
      SELECT cl.cla_id, cl.cour_id FROM %1$I.class cl
      WHERE UPPER(TRIM(cl.claname)) = UPPER(TRIM($1)) AND cl.activestatus = 1
      ORDER BY cl.cla_id LIMIT 1
    ), co AS (
      SELECT c.cour_id FROM %1$I.course c
      WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM($2)) AND c.activestatus = 1
      ORDER BY c.cour_id LIMIT 1
    )
    UPDATE %1$I.students s SET
      stuclass = $1, courname = $2,
      cla_id  = COALESCE((SELECT cla_id  FROM tc), s.cla_id),
      cour_id = COALESCE((SELECT cour_id FROM tc), (SELECT cour_id FROM co), s.cour_id)
    WHERE s.stu_id = $3
  $su$, v)
    USING p_target_class, p_target_course, p_stu_id;

  -- 2b) Mirror the move onto the student's admission record (public.admission),
  --     so the admission table's course/class stay in sync with the transfer.
  --     Matched by admission number (admno = student's stuadmno, unique per
  --     institution) because allocated admissions often carry a NULL stu_id;
  --     a stu_id match is kept as a fallback. cour_id / cla_id are refreshed
  --     from the schema masters; admit_cour_id (the originally-admitted course)
  --     is deliberately left unchanged.
  EXECUTE format($ad$
    WITH tc AS (
      SELECT cl.cla_id, cl.cour_id
      FROM %1$I.class cl
      WHERE UPPER(TRIM(cl.claname)) = UPPER(TRIM($1)) AND cl.activestatus = 1
      ORDER BY cl.cla_id LIMIT 1
    ), co AS (
      SELECT c.cour_id
      FROM %1$I.course c
      WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM($2)) AND c.activestatus = 1
      ORDER BY c.cour_id LIMIT 1
    )
    UPDATE public.admission a SET
      courname = $2, stuclass = $1, allocatedclass = $1,
      cla_id  = COALESCE((SELECT cla_id  FROM tc), a.cla_id),
      cour_id = COALESCE((SELECT cour_id FROM tc), (SELECT cour_id FROM co), a.cour_id)
    WHERE a.ins_id = $3 AND a.activestatus = 1
      AND a.admno = $4
  $ad$, v)
    USING p_target_class, p_target_course, p_ins_id, v_stuadmno;

  -- 3) Create the new course demands from the client amounts. The client already
  --    reduced feeamt by the matching OLD PAID (VB col8 -= paid); credit is the
  --    fee's concession (feeamount = feeamt, conamount = credit,
  --    balancedue = feeamt - credit, paidamount = 0). classfeedemand read-only.
  FOR cf IN EXECUTE format($q$
      SELECT c.cf_id, c.cfterm, c.cffeetype, c.cfdduedate, c.collectible,
             c.cla_id, c.sem_id, c.fee_id,
             (it->>'feeamt')::numeric AS feeamt,
             COALESCE((it->>'credit')::numeric, 0) AS credit
      FROM jsonb_array_elements($1::jsonb) it
      JOIN %I.classfeedemand c ON c.cf_id = (it->>'cf_id')::int
      WHERE (it->>'feeamt')::numeric > 0
      ORDER BY c.cf_id
    $q$, v) USING p_credits
  LOOP
    -- Concession = old paid + old concession carried (client capped at the fee).
    v_credit := LEAST(GREATEST(cf.credit, 0), cf.feeamt);
    v_applied := v_applied + v_credit;
    v_remaining := GREATEST(v_remaining - v_credit, 0);

    EXECUTE format($i$
      INSERT INTO %I.feedemand
        (demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, demfeeyear, demfeeterm, demfeetype,
         feeamount, con_id, conamount, paidamount, balancedue, reconbalancedue, duedate, paidstatus,
         createdby, activestatus, collectible, cla_id, sem_id, fee_id, cf_id, courname)
      VALUES ('REGULAR',$1,$2,$3,$4,$5,$6,$7,$8,$9,
              $10,$11,$12,0,GREATEST($10-$12,0),GREATEST($10-$12,0),$13,
              CASE WHEN $10-$12<=0 THEN 'P' ELSE 'U' END,
              $14,1,$15,$16,$17,$18,$19,$20)
    $i$, v)
    -- collectible is forced TRUE, not inherited from classfeedemand: that column
    -- defaults to FALSE, and these demands are the fees the operator explicitly
    -- ticked and priced on the Adjust Fees page. Inheriting false made them
    -- invisible to Fee Collection, so the student could never pay them.
    USING p_ins_id, v_inscode, v_yr_id, p_stu_id, v_stuadmno, p_target_class, v_yrlabel, cf.cfterm, cf.cffeetype,
          cf.feeamt, v_con_id, v_credit, cf.cfdduedate, p_created_by, true,
          cf.cla_id, cf.sem_id, cf.fee_id, cf.cf_id, p_target_course;
    v_new_count := v_new_count + 1;
  END LOOP;

  -- 4) Log the transfer (with the ORIGINAL course/class). One row per student
  --    per date: a second transfer on the same day UPDATES that day's row
  --    instead of adding a duplicate (the VB frmClassTransfer rule — studhist
  --    is keyed on studid + tdate).
  EXECUTE format($l$
    UPDATE %I.interim_promotion SET
      doc_no = $1, stuadmno = $5, courname = $6, stuclass = $7, stuname = $8,
      transferred_courname = $9, transferred_class = $10, remarks = $11,
      createdby = $12, activestatus = 1
    WHERE ins_id = $2 AND stu_id = $4 AND promotiondate = $3
  $l$, v)
  USING p_doc_no, p_ins_id, p_promotion_date, p_stu_id, v_stuadmno, v_old_course, v_old_class, v_stuname,
        p_target_course, p_target_class, NULLIF(btrim(COALESCE(p_remarks, '')), ''), p_created_by;
  GET DIAGNOSTICS v_log_rows = ROW_COUNT;
  IF v_log_rows = 0 THEN
    EXECUTE format($l$
      INSERT INTO %I.interim_promotion
        (doc_no, ins_id, promotiondate, stu_id, stuadmno, courname, stuclass, stuname,
         transferred_courname, transferred_class, remarks, createdby, activestatus)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,1)
    $l$, v)
    USING p_doc_no, p_ins_id, p_promotion_date, p_stu_id, v_stuadmno, v_old_course, v_old_class, v_stuname,
          p_target_course, p_target_class, NULLIF(btrim(COALESCE(p_remarks, '')), ''), p_created_by;
  END IF;

  RETURN jsonb_build_object('new_demands', v_new_count, 'applied', v_applied,
                            'old_paid', v_paid, 'leftover_credit', v_remaining);
END;
$$;
GRANT EXECUTE ON FUNCTION public.transfer_course_with_credit(integer, bigint, text, text, jsonb, integer, date, text, text)
  TO anon, authenticated;

-- ---------------------------------------------------------------------
-- 7/8  pending_report_concession.sql
--      Pending Payment report: stop dropping concessions from fully-settled rows
-- ---------------------------------------------------------------------
-- Pending Payment report: stop dropping concessions from fully-settled rows.
--
-- get_pending_payment_report ended with
--     HAVING SUM(balancedue + pending_fee) <> 0
-- so any student/term group with nothing outstanding was excluded -- and its
-- conamount went with it. The report's CON. AMT grand total therefore came out
-- LOWER than SUM(feedemand.conamount): a concession that cleared its demand to
-- zero vanished from the report entirely.
--
-- Such a group is now kept (pending shows 0, the concession is counted), so the
-- report's concession total matches the table.
--
-- DB-only, no schema change; safe to re-run.

CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
    p_schema TEXT, p_ins_id INT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json;
BEGIN
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.stuadmno), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  fd.demfeeterm::TEXT AS semester,
                  s.admname::TEXT AS admname, s.stuadmno::TEXT AS stuadmno, s.stuname::TEXT AS stuname,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  s.quoname::TEXT AS quoname, s.stumobile::TEXT AS stumobile
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, fd.demfeeterm,
                   s.admname, s.stuadmno, s.stuname, s.quoname, s.stumobile
          -- Keep a group that has nothing pending but DID receive a concession:
          -- dropping it also dropped its conamount, so the report's CON. AMT
          -- total came out short of SUM(feedemand.conamount).
          HAVING  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0)) <> 0
             OR   COALESCE(SUM(fd.conamount), 0) <> 0
        ) t
    $f$, p_schema, p_ins_id) INTO r;
    RETURN r;
END $$;

GRANT EXECUTE ON FUNCTION public.get_pending_payment_report(TEXT, INT) TO anon, authenticated;

-- ---------------------------------------------------------------------
-- 8/8  drop_dead_functions.sql
--      Drop six confirmed-unused functions
-- ---------------------------------------------------------------------
-- Drop dead/superseded functions from existing DBs (verified: no callers in the
-- desktop app or in any other function/trigger in complete_setup.sql).
-- Matches the removals made in complete_setup.sql. Idempotent (IF EXISTS).
--
-- NOTE: the two payment "atomic" functions (initiate_payment_atomic,
-- complete_payment_atomic) are intentionally NOT dropped here — they may still
-- be called by the separate MOBILE app. Confirm that before removing them.

DROP FUNCTION IF EXISTS public.activate_subscription_code(integer, text);
DROP FUNCTION IF EXISTS public.generate_feedemand_from_template(integer);
DROP FUNCTION IF EXISTS public.get_student_ledger_data(integer, text);
DROP FUNCTION IF EXISTS public.get_overdue_total(integer);
DROP FUNCTION IF EXISTS public.hash_password(text);
DROP FUNCTION IF EXISTS public.verify_password(text, text);
