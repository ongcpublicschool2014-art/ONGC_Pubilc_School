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
