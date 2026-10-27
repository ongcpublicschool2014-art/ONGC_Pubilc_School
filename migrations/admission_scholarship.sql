-- ============================================================================
-- Scholarship eligibility on the admission record.
--
--   scholarship     — 'Y' / 'N' / NULL. NULL means the question was never
--                     asked (every admission taken before this migration), and
--                     is deliberately distinct from an explicit 'N'.
--   scholarshiptype — which scheme, and only meaningful when eligible. The
--                     Admission Entry form clears it when eligibility is set
--                     back to No, so a stale scheme name can't survive.
--
-- Free text rather than a master table on purpose: schemes are announced and
-- renamed by the government every intake, and the form offers the values
-- already used as suggestions (the same self-populating pattern as Medium,
-- Caste and Occupation).
--
-- Added to public.admission AND to every tenant students table, so the value
-- survives class allocation and is available to reports and the TC.
--
-- Also replaces the two functions that move admission columns onto students:
--   allocate_admission_to_student — the INSERT run when a class is allocated
--   save_admission                — the UPDATE that pushes later admission
--                                   edits onto an already-ALLOCATED student
--
-- Idempotent: ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE throughout.
-- ============================================================================

ALTER TABLE public.admission
  ADD COLUMN IF NOT EXISTS scholarship     char(1),
  ADD COLUMN IF NOT EXISTS scholarshiptype varchar(60);

-- Every institution schema that already exists.
DO $sch$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'students')
       AND nspname NOT IN ('public','information_schema')
       AND nspname NOT LIKE 'pg\_%'
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarship char(1)', r.nspname);
    EXECUTE format(
      'ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarshiptype varchar(60)', r.nspname);
    RAISE NOTICE 'added scholarship columns to %.students', r.nspname;
  END LOOP;
END
$sch$;


-- ==========================================================================
-- allocate_admission_to_student
-- ==========================================================================

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

  -- admission no longer stores yr_id/yrlabel — derive from the target schema.
  EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
    INTO v_yr_id, v_yrlabel USING v.ins_id;
  IF v_yr_id IS NULL THEN
    RAISE EXCEPTION 'allocate_admission: cannot resolve academic year for schema %', v_schema;
  END IF;

  -- Self-heal: ensure the target schema's students table has the demographic
  -- columns (no-op if already present). Covers schemas created before this
  -- feature was added.
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS aadharno      varchar(20)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS community     varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS caste         varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS religion      varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS nationality   varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS transportmode varchar(20)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS hostel        char(1)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS emisno        varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS umisno        varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarship     char(1)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarshiptype varchar(60)', v_schema);

  -- Resolve the allocated class's ids (p_class can differ from the admission's
  -- preferred class) so the new student carries cla_id / cour_id; adm_id (from
  -- admission.admtype_id) / quo_id / medium come straight from the admission row.
  EXECUTE format('SELECT cla_id, cour_id FROM %I.class WHERE UPPER(TRIM(claname))=UPPER(TRIM($1)) AND activestatus=1 ORDER BY cla_id LIMIT 1', v_schema)
    INTO v_cla_id, v_cour_id USING p_class;

  -- 1) students (stu_id auto-assigned by the schema's set_stu_id trigger)
  EXECUTE format(
    'INSERT INTO %I.students '
    '(ins_id, inscode, yr_id, yrlabel, stuadmno, stuadmdate, stuname, stugender, studob, '
    ' stumobile, stuemail, stuaddress, stucity, stustate, stucountry, stupin, stubloodgrp, stuphoto, '
    ' stuclass, courname, con_id, stucondesc, stuser_id, stuotpstatus, '
    ' approvedby, approveddate, activestatus, createdon, batch, admname, quoname, admittyear, aadharno, '
    ' community, caste, religion, nationality, transportmode, hostel, emisno, umisno, scholarship, scholarshiptype, cla_id, cour_id, adm_id, quo_id, medium, admit_cour_id) '
    'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,'
    ' $19,$20,$21,$22,$5,0,$23,now(),1,now(),$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34,'
    ' $41,$42,$43,$44,$35,$36,$37,$38,$39,$40) RETURNING stu_id', v_schema)
  INTO v_stu_id
  USING v.ins_id, v.inscode, v_yr_id, v_yrlabel, p_stuadmno, COALESCE(v.admdate, CURRENT_DATE),
        v.stuname, v.stugender, v.studob, v.stumobile, v.stuemail, v.stuaddress, v.stucity,
        v.stustate, v.stucountry, v.stupin, v.stubloodgrp, v.stuphoto, p_class, v.courname,
        v.con_id, v.stucondesc, p_allocatedby, v.batch, v.admname, v.quoname, v.admittyear, v.aadharno,
        v.community, v.caste, v.religion, v.nationality, v.transportmode, v.hostel,
        COALESCE(v_cla_id, v.cla_id), COALESCE(v_cour_id, v.cour_id), v.admtype_id, v.quo_id, v.medium,
        COALESCE(v.admit_cour_id, v_cour_id, v.cour_id),
        -- $41-$44: appended rather than inserted mid-list so every existing
        -- placeholder keeps its number.
        v.emisno, v.umisno, v.scholarship, v.scholarshiptype;

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

-- ==========================================================================
-- save_admission
-- ==========================================================================

CREATE OR REPLACE FUNCTION public.save_admission(
  p_token text, p_data jsonb, p_adm_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
  v_schema text; v public.admission%ROWTYPE;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  v_data := (p_data - 'adm_id') || jsonb_build_object('ins_id', v_ins);

  IF p_adm_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'admission' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO public.admission (%s) SELECT %s FROM jsonb_populate_record(NULL::public.admission, $1) r RETURNING adm_id',
      v_cols, v_sel)
    INTO v_id USING v_data;
    RETURN v_id;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'admission' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE public.admission t SET %s FROM jsonb_populate_record(NULL::public.admission, $1) r WHERE t.adm_id=$2 AND t.ins_id=$3',
      v_set)
    USING v_data, p_adm_id, v_ins;

    -- Propagate the demographic edits to the ENROLLED student when the admission
    -- is allocated, so the Admission screen is the single edit point and the
    -- (view-only) Students screen reflects the change. The locked core fields —
    -- Register No (stuadmno), Admission Date (stuadmdate), Course (courname),
    -- Class (stuclass), Batch — are deliberately NOT touched here. Matched by
    -- stuadmno = admno because allocated admissions may carry a NULL stu_id.
    SELECT * INTO v FROM public.admission WHERE adm_id = p_adm_id;
    IF v.admstatus = 'ALLOCATED' THEN
      v_schema := get_institution_schema(v_ins);
      IF v_schema IS NOT NULL THEN
        -- self-heal demographic columns on older student tables (no-op if present)
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS aadharno varchar(20)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS community varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS caste varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS religion varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS nationality varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS transportmode varchar(20)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS hostel char(1)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS emisno varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS umisno varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarship char(1)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarshiptype varchar(60)', v_schema);

        EXECUTE format(
          'UPDATE %I.students SET '
          ' stuname=$2, stugender=$3, studob=$4, stumobile=$5, stuemail=$6, stuaddress=$7, '
          ' stucity=$8, stustate=$9, stucountry=$10, stupin=$11, stubloodgrp=$12, '
          ' stuphoto=$13, con_id=$14, stucondesc=$15, admname=$16, quoname=$17, '
          ' admittyear=$18, aadharno=$19, community=$20, caste=$21, religion=$22, nationality=$23, '
          ' transportmode=$24, hostel=$25, emisno=$26, umisno=$27, adm_id=$28, quo_id=$29, '
          -- $31/$32: appended so $1-$30 keep their numbers.
          ' scholarship=$31, scholarshiptype=$32 '
          'WHERE stuadmno=$1 AND ins_id=$30', v_schema)
        USING v.admno, v.stuname, v.stugender, v.studob, v.stumobile, v.stuemail, v.stuaddress,
              v.stucity, v.stustate, v.stucountry, v.stupin, v.stubloodgrp, v.stuphoto,
              v.con_id, v.stucondesc, v.admname, v.quoname, v.admittyear, v.aadharno,
              v.community, v.caste, v.religion, v.nationality, v.transportmode, v.hostel,
              v.emisno, v.umisno, v.admtype_id, v.quo_id, v_ins,
              v.scholarship, v.scholarshiptype;

        -- parentdetail carries a copy of the student's name
        EXECUTE format('UPDATE %I.parentdetail SET stuname=$2 WHERE stuadmno=$1 AND ins_id=$3', v_schema)
          USING v.admno, v.stuname, v_ins;

        -- parents (linked via parentdetail); self-heal paremail first
        EXECUTE format('ALTER TABLE %I.parents ADD COLUMN IF NOT EXISTS paremail varchar(254)', v_schema);
        EXECUTE format(
          'UPDATE %I.parents p SET '
          ' fathername=$2, fathermobile=$3, fatheroccupation=$4, mothername=$5, mothermobile=$6, '
          ' motheroccupation=$7, guardianname=$8, guardianmobile=$9, guardianoccupation=$10, '
          ' payincharge=$11, payinchargemob=$12, paremail=NULLIF(TRIM($13),'''') '
          'FROM %I.parentdetail pd '
          'WHERE pd.par_id=p.par_id AND pd.stuadmno=$1 AND pd.ins_id=$14', v_schema, v_schema)
        USING v.admno, v.fathername, v.fathermobile, v.fatheroccupation, v.mothername, v.mothermobile,
              v.motheroccupation, v.guardianname, v.guardianmobile, v.guardianoccupation,
              COALESCE(NULLIF(TRIM(v.payincharge),''), v.stuname), v.payinchargemob, v.paremail, v_ins;
      END IF;
    END IF;

    RETURN p_adm_id;
  END IF;
END; $$;


-- ============================================================================
-- Verify.
-- ============================================================================
SELECT table_schema, table_name, column_name
  FROM information_schema.columns
 WHERE column_name IN ('scholarship','scholarshiptype')
 ORDER BY table_schema, column_name;
