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
