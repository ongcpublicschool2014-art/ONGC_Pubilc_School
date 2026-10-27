-- allocate_admission_to_student: (1) derive the academic year from the target
-- schema (public.admission no longer has yr_id/yrlabel/stu_id, so the old body
-- that read v.yr_id/v.stu_id failed at runtime → "enrolment failed"); (2) on an
-- individual admission, STAGE that student's fee demands into tempfeedemand
-- (pending Fee Demand Approval) from the class fee template, matched on class +
-- admission type. Bulk student import uses a different path and is unaffected —
-- there is no students trigger. Run ONCE in the public schema.

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
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
    RAISE EXCEPTION 'allocate_admission: schema % does not exist', v_schema;
  END IF;

  SELECT * INTO v FROM public.admission WHERE adm_id = p_adm_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Admission % not found', p_adm_id; END IF;
  IF v.admstatus = 'ALLOCATED' THEN
    RAISE EXCEPTION 'Admission % is already allocated', p_adm_id;
  END IF;

  -- admission no longer stores yr_id/yrlabel — derive from the target schema.
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

  -- 4) stamp the admission row as allocated (admission no longer has stu_id).
  UPDATE public.admission
     SET allocatedclass = p_class,
         admstatus = 'ALLOCATED',
         allocatedby = p_allocatedby,
         allocateddate = now()
   WHERE adm_id = p_adm_id;

  -- 5) Generate THIS student's fee demands from the class fee template into
  -- tempfeedemand (isapproved=false → Fee Demand Approval → feedemand). Fires only
  -- on individual admission allocation; bulk student import uses a different path
  -- and is unaffected. Matched on class + admission type (NULL = all), skips dups.
  IF v.admname IS NOT NULL AND TRIM(v.admname) <> '' THEN
    EXECUTE format('SELECT adm_id FROM %I.admissiontype WHERE UPPER(TRIM(admname))=UPPER(TRIM($1)) AND activestatus=1 LIMIT 1', v_schema)
      INTO v_adm_id USING v.admname;
  END IF;
  EXECUTE format(
    'INSERT INTO %1$I.tempfeedemand '
    '(ins_id,inscode,yr_id,stu_id,stuadmno,stuclass,courname,demfeeyear,demfeeterm,demfeetype,'
    ' feeamount,con_id,conamount,balancedue,duedate,activestatus,createdby,isapproved,collectible,'
    ' cla_id,sem_id,cf_id,fee_id,demseqtype) '
    'SELECT $1,$2,$3,$4,$5,$6,$7,$8,cf.cfterm,cf.cffeetype,cf.cfamount,$9,0,cf.cfamount,cf.cfdduedate,1,'
    ' $10,false,COALESCE(cf.collectible,true),cf.cla_id,cf.sem_id,cf.cf_id,cf.fee_id,''REGULAR'' '
    'FROM %1$I.classfeedemand cf '
    'WHERE cf.cfclass=$6 AND cf.activestatus=1 '
    '  AND (cf.admissiontype IS NULL OR cf.admissiontype=$11) '
    '  AND cf.cfamount IS NOT NULL '
    '  AND (cf.cfdduedate IS NULL OR cf.cfdduedate >= $12) '
    '  AND NOT EXISTS (SELECT 1 FROM %1$I.tempfeedemand t WHERE t.stu_id=$4 AND t.demfeeterm=cf.cfterm AND t.demfeetype=cf.cffeetype AND t.activestatus=1) '
    '  AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd WHERE fd.stu_id=$4 AND fd.demfeeterm=cf.cfterm AND fd.demfeetype=cf.cffeetype AND fd.activestatus=1)',
    v_schema)
  USING v.ins_id, v.inscode, v_yr_id, v_stu_id, p_stuadmno, p_class, v.courname, v_yrlabel,
        v.con_id, COALESCE(p_allocatedby, 'SYSTEM'), v_adm_id, COALESCE(v.admdate, CURRENT_DATE);

  RETURN json_build_object(
    'adm_id', p_adm_id, 'stu_id', v_stu_id, 'par_id', v_par_id,
    'stuadmno', p_stuadmno, 'class', p_class, 'status', 'ALLOCATED');
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.allocate_admission_to_student(bigint, text, text, text, text) TO anon, authenticated;
