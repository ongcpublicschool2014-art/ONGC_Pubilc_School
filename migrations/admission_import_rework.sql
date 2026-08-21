-- ============================================================================
-- Admission table rework (2026-08-08)
-- ============================================================================
-- 1) public.admission: add entity-id columns + parent email; DROP yr_id/yrlabel/stu_id
--    (allocation status is tracked by admstatus; the created stu_id is returned by the RPC).
-- 2) allocate_admission_to_student: derive the academic year from the target
--    schema (public.institutionyear) instead of reading it off the admission
--    row (those columns are now gone).
-- 3) process_student_import: after creating the student (unchanged), ALSO write
--    an ALLOCATED row into public.admission (best-effort — never fails the
--    import), so imported students appear in the admission module.
--
-- ⚠️ public.admission is SHARED across ALL institutions. BACK IT UP first:
--      CREATE TABLE public.admission_bak AS SELECT * FROM public.admission;
-- Run in the Supabase SQL editor. Idempotent.
-- ============================================================================

-- ── 1) Columns ──────────────────────────────────────────────────────────────
ALTER TABLE public.admission
  ADD COLUMN IF NOT EXISTS cla_id        smallint,
  ADD COLUMN IF NOT EXISTS cour_id       smallint,
  ADD COLUMN IF NOT EXISTS admit_cour_id smallint,
  ADD COLUMN IF NOT EXISTS admtype_id    smallint,      -- admission TYPE id -> students.adm_id
  ADD COLUMN IF NOT EXISTS quo_id        smallint,
  ADD COLUMN IF NOT EXISTS medium        varchar(30),
  ADD COLUMN IF NOT EXISTS paremail      varchar(254);

ALTER TABLE public.admission
  DROP COLUMN IF EXISTS yr_id,
  DROP COLUMN IF EXISTS yrlabel,
  DROP COLUMN IF EXISTS stu_id;

-- ── 2) allocate_admission_to_student — year now derived from the schema ──────
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
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
    RAISE EXCEPTION 'allocate_admission: schema % does not exist', v_schema;
  END IF;

  SELECT * INTO v FROM public.admission WHERE adm_id = p_adm_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Admission % not found', p_adm_id;
  END IF;
  IF v.admstatus = 'ALLOCATED' THEN
    RAISE EXCEPTION 'Admission % is already allocated', p_adm_id;
  END IF;

  -- Resolve the academic year from the target schema's OWN year table (the
  -- source of students.yr_id). admission no longer stores yr_id/yrlabel.
  EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
    INTO v_yr_id, v_yrlabel USING v.ins_id;
  IF v_yr_id IS NULL THEN
    RAISE EXCEPTION 'allocate_admission: cannot resolve academic year for schema %', v_schema;
  END IF;

  -- Self-heal: ensure the target schema's students table has the admission cols.
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS aadharno      varchar(20)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS community     varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS caste         varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS religion      varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS nationality   varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS transportmode varchar(10)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS hostel        char(1)', v_schema);

  -- 1) students (stu_id auto-assigned by the schema's set_stu_id trigger)
  EXECUTE format(
    'INSERT INTO %I.students '
    '(ins_id, inscode, yr_id, yrlabel, stuadmno, stuadmdate, stuname, stugender, studob, '
    ' stumobile, stuemail, stuaddress, stucity, stustate, stucountry, stupin, stubloodgrp, stuphoto, '
    ' stuclass, courname, con_id, stucondesc, stuser_id, stuotpstatus, '
    ' approvedby, approveddate, activestatus, createdon, batch, admname, quoname, admittyear, aadharno, '
    ' community, caste, religion, nationality, transportmode, hostel) '
    'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,'
    ' $19,$20,$21,$22,$5,0,$23,now(),1,now(),$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34) RETURNING stu_id', v_schema)
  INTO v_stu_id
  USING v.ins_id, v.inscode, v_yr_id, v_yrlabel, p_stuadmno, COALESCE(v.admdate, CURRENT_DATE),
        v.stuname, v.stugender, v.studob, v.stumobile, v.stuemail, v.stuaddress, v.stucity,
        v.stustate, v.stucountry, v.stupin, v.stubloodgrp, v.stuphoto, p_class, v.courname,
        v.con_id, v.stucondesc, p_allocatedby, v.batch, v.admname, v.quoname, v.admittyear, v.aadharno,
        v.community, v.caste, v.religion, v.nationality, v.transportmode, v.hostel;

  -- 2) parents — reuse an existing parent matched by payinchargemob, else create.
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

    -- 3) parentdetail link
    EXECUTE format(
      'INSERT INTO %I.parentdetail '
      '(yr_id, yrlabel, par_id, stu_id, ins_id, inscode, stuadmno, stuname, stuclass, activestatus) '
      'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema)
    USING v_yr_id, v_yrlabel, v_par_id, v_stu_id, v.ins_id, v.inscode, p_stuadmno, v.stuname, p_class;
  END IF;

  -- 4) stamp the admission row as allocated
  UPDATE public.admission
     SET allocatedclass = p_class,
         admstatus = 'ALLOCATED',
         allocatedby = p_allocatedby,
         allocateddate = now()
   WHERE adm_id = p_adm_id;

  RETURN json_build_object(
    'adm_id', p_adm_id, 'stu_id', v_stu_id, 'par_id', v_par_id,
    'stuadmno', p_stuadmno, 'class', p_class, 'status', 'ALLOCATED');
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.allocate_admission_to_student(bigint, text, text, text, text)
  TO anon, authenticated;

-- ── 3) process_student_import — also mirror each student into public.admission ──
CREATE OR REPLACE FUNCTION public.process_student_import(p_ins_id integer) RETURNS TABLE(total integer, imported integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '300s'
AS $$
DECLARE rec RECORD; v_stu_id bigint; v_par_id bigint; v_con_id integer; v_total int:=0; v_imported int:=0; v_skipped int:=0; v_schema text;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;
  FOR rec IN EXECUTE format('SELECT * FROM %I.student_import WHERE ins_id=$1 AND status=''PENDING'' ORDER BY imp_id', v_schema) USING p_ins_id LOOP
    v_total:=v_total+1;
    BEGIN
      IF (rec.payinchargemob IS NULL OR TRIM(rec.payinchargemob)='') OR (rec.payincharge IS NULL OR TRIM(rec.payincharge)='') THEN
        EXECUTE format('UPDATE %I.student_import SET status=''NO_PARENT'',error_msg=''Missing payincharge'' WHERE imp_id=$1', v_schema) USING rec.imp_id; v_skipped:=v_skipped+1; CONTINUE;
      END IF;
      v_con_id:=NULL;
      IF rec.concession IS NOT NULL AND TRIM(rec.concession)!='' THEN EXECUTE format('SELECT con_id FROM %I.concessioncategory WHERE UPPER(TRIM(condesc))=UPPER($1) AND ins_id=$2 LIMIT 1', v_schema) INTO v_con_id USING TRIM(rec.concession),p_ins_id; END IF;
      EXECUTE format('INSERT INTO %I.students(ins_id,inscode,yr_id,yrlabel,stuadmno,stuadmdate,stuname,stugender,studob,stumobile,stuemail,stuaddress,stucity,stustate,stucountry,stupin,stubloodgrp,stuclass,courname,cour_id,admit_cour_id,con_id,stucondesc,stuser_id,stuotpstatus,approvedby,approveddate,suspendedby,terminatedby,activestatus,createdon,admname,quoname,batch,admittyear,aadharno,community,caste,religion,nationality,transportmode,hostel,medium,cla_id,adm_id,quo_id) VALUES($1,$2,$3,$4,$5,COALESCE($6,CURRENT_DATE),$7,$8,$9,$10,NULLIF($11,''''),$12,$13,$14,$15,$16,$17,$18,$21,$26,$38,$19,NULLIF(TRIM($20),''''),$5,0,'''',now(),'''','''',1,now(),$22,$23,$24,$25,$27,$28,$29,$30,$31,$32,$33,$34,$35,$36,$37) RETURNING stu_id', v_schema) INTO v_stu_id USING rec.ins_id,rec.inscode,rec.yr_id,rec.yrlabel,rec.stuadmno,rec.stuadmdate,rec.stuname,rec.stugender,rec.studob,rec.stumobile,rec.stuemail,rec.stuaddress,rec.stucity,rec.stustate,rec.stucountry,rec.stupin,rec.stubloodgrp,rec.stuclass,v_con_id,rec.concession,rec.courname,rec.admname,rec.quoname,rec.batch,rec.admittyear,rec.cour_id,rec.aadharno,rec.community,rec.caste,rec.religion,rec.nationality,rec.transportmode,rec.hostel,rec.medium,rec.cla_id,rec.adm_id,rec.quo_id,rec.admit_cour_id;
      v_par_id:=NULL;
      EXECUTE format('SELECT par_id FROM %I.parents WHERE payinchargemob=$1 LIMIT 1', v_schema) INTO v_par_id USING rec.payinchargemob;
      IF v_par_id IS NULL THEN
        EXECUTE format('INSERT INTO %I.parents(ins_id,yr_id,yrlabel,partype,fathername,fathermobile,fatheroccupation,mothername,mothermobile,motheroccupation,guardianname,guardianmobile,guardianoccupation,payincharge,payinchargemob,paremail,parotpstatus,approveddate,activestatus) VALUES($14,$1,$2,''P'',$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,NULLIF(TRIM($15),''''),0,now(),1) RETURNING par_id', v_schema) INTO v_par_id USING rec.yr_id,rec.yrlabel,rec.fathername,rec.fathermobile,rec.fatheroccupation,rec.mothername,rec.mothermobile,rec.motheroccupation,rec.guardianname,rec.guardianmobile,rec.guardianoccupation,rec.payincharge,rec.payinchargemob,rec.ins_id,rec.paremail;
      END IF;
      EXECUTE format('INSERT INTO %I.parentdetail(yr_id,yrlabel,par_id,stu_id,ins_id,inscode,stuadmno,stuname,stuclass,activestatus) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema) USING rec.yr_id,rec.yrlabel,v_par_id,v_stu_id,rec.ins_id,rec.inscode,rec.stuadmno,rec.stuname,rec.stuclass;
      -- Mirror into public.admission (best-effort; never fails the import).
      BEGIN
        INSERT INTO public.admission(
          ins_id,inscode,admno,admdate,admstatus,allocatedclass,allocatedby,allocateddate,
          stuname,stugender,studob,stumobile,stuemail,stuaddress,stucity,stustate,stucountry,stupin,stubloodgrp,
          aadharno,courname,stuclass,admname,quoname,con_id,stucondesc,batch,admittyear,
          community,caste,religion,nationality,transportmode,hostel,
          fathername,fathermobile,fatheroccupation,mothername,mothermobile,motheroccupation,
          guardianname,guardianmobile,guardianoccupation,payincharge,payinchargemob,paremail,
          createdby,cla_id,cour_id,admit_cour_id,admtype_id,quo_id,medium)
        VALUES(
          rec.ins_id,rec.inscode,rec.stuadmno,COALESCE(rec.stuadmdate,CURRENT_DATE),'ALLOCATED',rec.stuclass,'IMPORT',now(),
          rec.stuname,rec.stugender,rec.studob,rec.stumobile,NULLIF(rec.stuemail,''),rec.stuaddress,rec.stucity,rec.stustate,rec.stucountry,rec.stupin,rec.stubloodgrp,
          rec.aadharno,rec.courname,rec.stuclass,rec.admname,rec.quoname,v_con_id,NULLIF(TRIM(rec.concession),''),rec.batch,rec.admittyear,
          rec.community,rec.caste,rec.religion,rec.nationality,rec.transportmode,rec.hostel,
          rec.fathername,rec.fathermobile,rec.fatheroccupation,rec.mothername,rec.mothermobile,rec.motheroccupation,
          rec.guardianname,rec.guardianmobile,rec.guardianoccupation,rec.payincharge,rec.payinchargemob,NULLIF(TRIM(rec.paremail),''),
          'IMPORT',rec.cla_id,rec.cour_id,rec.admit_cour_id,rec.adm_id,rec.quo_id,rec.medium)
        ON CONFLICT (ins_id, admno) DO NOTHING;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
      EXECUTE format('UPDATE %I.student_import SET status=''DONE'' WHERE imp_id=$1', v_schema) USING rec.imp_id; v_imported:=v_imported+1;
    EXCEPTION WHEN OTHERS THEN
      EXECUTE format('UPDATE %I.student_import SET status=''ERROR'',error_msg=$1 WHERE imp_id=$2', v_schema) USING SQLERRM,rec.imp_id; v_skipped:=v_skipped+1;
    END;
  END LOOP;
  RETURN QUERY SELECT v_total, v_imported, v_skipped;
END; $$;

NOTIFY pgrst, 'reload schema';
