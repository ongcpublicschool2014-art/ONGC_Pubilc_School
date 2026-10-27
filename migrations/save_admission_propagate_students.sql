-- save_admission: when an ALLOCATED admission is edited, also propagate the
-- editable demographics to the enrolled student (students + parents +
-- parentdetail), so the Admission screen is the single edit point and the
-- (view-only) Students screen reflects the change. The locked core fields —
-- Register No, Admission Date, Course, Class, Batch — are never touched.
-- DB-only change (no app rebuild). Safe to re-run. Run on every institution DB.

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

    -- Propagate demographics to the enrolled student when allocated.
    SELECT * INTO v FROM public.admission WHERE adm_id = p_adm_id;
    IF v.admstatus = 'ALLOCATED' THEN
      v_schema := get_institution_schema(v_ins);
      IF v_schema IS NOT NULL THEN
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS aadharno varchar(20)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS community varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS caste varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS religion varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS nationality varchar(30)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS transportmode varchar(20)', v_schema);
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS hostel char(1)', v_schema);

        EXECUTE format(
          'UPDATE %I.students SET '
          ' stuname=$2, stugender=$3, studob=$4, stumobile=$5, stuemail=$6, stuaddress=$7, '
          ' stucity=$8, stustate=$9, stucountry=$10, stupin=$11, stubloodgrp=$12, '
          ' stuphoto=$13, con_id=$14, stucondesc=$15, admname=$16, quoname=$17, '
          ' admittyear=$18, aadharno=$19, community=$20, caste=$21, religion=$22, nationality=$23, '
          ' transportmode=$24, hostel=$25, adm_id=$26, quo_id=$27 '
          'WHERE stuadmno=$1 AND ins_id=$28', v_schema)
        USING v.admno, v.stuname, v.stugender, v.studob, v.stumobile, v.stuemail, v.stuaddress,
              v.stucity, v.stustate, v.stucountry, v.stupin, v.stubloodgrp, v.stuphoto,
              v.con_id, v.stucondesc, v.admname, v.quoname, v.admittyear, v.aadharno,
              v.community, v.caste, v.religion, v.nationality, v.transportmode, v.hostel,
              v.admtype_id, v.quo_id, v_ins;

        EXECUTE format('UPDATE %I.parentdetail SET stuname=$2 WHERE stuadmno=$1 AND ins_id=$3', v_schema)
          USING v.admno, v.stuname, v_ins;

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

GRANT EXECUTE ON FUNCTION public.save_admission(text, jsonb, bigint) TO anon, authenticated;
