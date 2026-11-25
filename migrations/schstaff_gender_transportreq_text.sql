-- ============================================================================
-- schstaff: gender -> character(1) 'M'/'F'/'T', transportreq -> varchar(3)
-- 'OWN'/'BUS'  (were integer 1/2/3 and smallint 0/1).
-- ============================================================================
-- staff_save and staff_list change with the columns: they now TAKE and RETURN
-- the text values directly --
--   gender        'M' | 'F' | 'T'      (was 1 | 2 | 3)
--   transportreq  'OWN' | 'BUS'        (was false | true; missing = 'OWN')
-- so every caller of those two functions must send / read the text values.
-- Existing rows are converted: 1->M, 2->F, 3->T and 0->OWN, 1->BUS.
-- One transaction: it all applies or none of it does. Run once.
-- ============================================================================

BEGIN;

ALTER TABLE public.schstaff DROP CONSTRAINT IF EXISTS schstaff_gender_check;
ALTER TABLE public.schstaff DROP CONSTRAINT IF EXISTS schstaff_transportreq_check;
ALTER TABLE public.schstaff ALTER COLUMN transportreq DROP DEFAULT;

ALTER TABLE public.schstaff
  ALTER COLUMN gender TYPE character(1)
    USING CASE gender WHEN 1 THEN 'M' WHEN 2 THEN 'F' WHEN 3 THEN 'T' END,
  ALTER COLUMN transportreq TYPE varchar(3)
    USING CASE transportreq WHEN 1 THEN 'BUS' WHEN 0 THEN 'OWN' END;

ALTER TABLE public.schstaff ALTER COLUMN transportreq SET DEFAULT 'OWN';
ALTER TABLE public.schstaff
  ADD CONSTRAINT schstaff_gender_check CHECK (gender IN ('M', 'F', 'T')),
  ADD CONSTRAINT schstaff_transportreq_check CHECK (transportreq IN ('OWN', 'BUS'));

CREATE OR REPLACE FUNCTION public.staff_list(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE c record; v jsonb;
BEGIN
  SELECT * INTO c FROM public._staff_ctx(p_token);
  EXECUTE format($q$
    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.in_year DESC, upper(x.emp_code) NULLS LAST, upper(x.stafname)), '[]'::jsonb)
      FROM (
        SELECT s.staf_id, s.stafname, s.shortname, s.gender, s.dob, s.joindate, s.staf_age,
               s.qualification, s.experience, s.address, s.city, s.phoneno, s.mobileno, s.emailid,
               s.bloodgroup, s.stafcare, s.stafcarename, s.confirmationdate,
               (COALESCE(s.staftermin, 0) = 1) AS staftermin, s.staftermindate,
               s.religion, s.community_id, cm.comname, s.nationality,
               s.transportreq,
               (s.password IS NOT NULL) AS has_password,
               m.staffmast_id, m.emp_code, m.designation,
               COALESCE(m.is_active, false) AS is_active,
               (m.staffmast_id IS NOT NULL) AS in_year,
               (SELECT count(*) FROM public.staff_experience e WHERE e.staf_id = s.staf_id) AS experience_count,
               s.created_at, s.updated_at
          FROM public.schstaff s
          LEFT JOIN %1$I.staffmast m ON m.staf_id = s.staf_id
          LEFT JOIN public.community cm ON cm.com_id = s.community_id
         WHERE s.ins_id = $1
      ) x $q$, c.ysch) INTO v USING c.ins;
  RETURN v;
END $function$
;

CREATE OR REPLACE FUNCTION public.staff_save(p_token text, p_row jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  c record; r jsonb := COALESCE(p_row, '{}'::jsonb);
  v_id numeric; v_name text; v_short text; v_mob text; v_mail text; v_code text; v_des text;
  v_gender text; v_transport text; v_dob date; v_join date; v_conf date; v_term boolean; v_termdate date;
  v_com smallint; v_care integer; v_pwd text; v_active boolean; v_dup text;
BEGIN
  SELECT * INTO c FROM public._staff_ctx(p_token);

  v_id    := NULLIF(r->>'staf_id', '')::numeric;
  v_name  := NULLIF(btrim(r->>'stafname'), '');
  v_short := NULLIF(btrim(r->>'shortname'), '');
  v_mob   := NULLIF(regexp_replace(COALESCE(r->>'mobileno', ''), '\s', '', 'g'), '');
  v_mail  := NULLIF(lower(btrim(r->>'emailid')), '');
  v_code  := NULLIF(upper(btrim(r->>'emp_code')), '');
  v_des   := NULLIF(btrim(r->>'designation'), '');
  v_gender := NULLIF(upper(btrim(r->>'gender')), '');
  v_transport := COALESCE(NULLIF(upper(btrim(r->>'transportreq')), ''), 'OWN');
  v_dob   := NULLIF(r->>'dob', '')::date;
  v_join  := NULLIF(r->>'joindate', '')::date;
  v_conf  := NULLIF(r->>'confirmationdate', '')::date;
  v_term  := COALESCE((r->>'staftermin')::boolean, false);
  v_termdate := NULLIF(r->>'staftermindate', '')::date;
  v_com   := NULLIF(r->>'community_id', '')::smallint;
  v_care  := NULLIF(r->>'stafcare', '')::integer;
  v_pwd   := NULLIF(r->>'password', '');
  v_active := COALESCE((r->>'is_active')::boolean, true) AND NOT v_term;

  IF v_code IS NULL THEN RAISE EXCEPTION 'Enter the employee code.' USING ERRCODE = 'P0001'; END IF;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Enter the staff name.' USING ERRCODE = 'P0001'; END IF;
  IF v_short IS NULL THEN RAISE EXCEPTION 'Enter the short name.' USING ERRCODE = 'P0001'; END IF;
  IF v_gender IS NULL THEN RAISE EXCEPTION 'Choose the gender.' USING ERRCODE = 'P0001'; END IF;
  IF v_gender NOT IN ('M', 'F', 'T') THEN RAISE EXCEPTION 'Gender must be M, F or T.' USING ERRCODE = 'P0001'; END IF;
  IF v_transport NOT IN ('OWN', 'BUS') THEN RAISE EXCEPTION 'Transport must be OWN or BUS.' USING ERRCODE = 'P0001'; END IF;
  IF v_dob IS NULL THEN RAISE EXCEPTION 'Select the date of birth.' USING ERRCODE = 'P0001'; END IF;
  IF v_join IS NULL THEN RAISE EXCEPTION 'Select the date of joining.' USING ERRCODE = 'P0001'; END IF;
  IF v_mob IS NULL THEN RAISE EXCEPTION 'Enter the mobile number.' USING ERRCODE = 'P0001'; END IF;
  IF v_mail IS NULL THEN RAISE EXCEPTION 'Enter the e-mail address.' USING ERRCODE = 'P0001'; END IF;
  IF v_mob !~ '^\+?[0-9]{10,14}$' THEN
    RAISE EXCEPTION 'Mobile No.: enter a valid 10-digit number.' USING ERRCODE = 'P0001';
  END IF;
  IF v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'Enter a valid e-mail address.' USING ERRCODE = 'P0001';
  END IF;
  IF v_dob >= CURRENT_DATE THEN RAISE EXCEPTION 'The date of birth must be before today.' USING ERRCODE = 'P0001'; END IF;
  IF v_join <= v_dob THEN RAISE EXCEPTION 'The date of joining must be after the date of birth.' USING ERRCODE = 'P0001'; END IF;
  IF v_conf IS NOT NULL AND v_conf < v_join THEN
    RAISE EXCEPTION 'The confirmation date cannot be before the date of joining.' USING ERRCODE = 'P0001';
  END IF;
  IF v_term AND v_termdate IS NULL THEN v_termdate := CURRENT_DATE; END IF;
  IF NOT v_term THEN v_termdate := NULL; END IF;
  IF v_termdate IS NOT NULL AND v_termdate < v_join THEN
    RAISE EXCEPTION 'The relieving date cannot be before the date of joining.' USING ERRCODE = 'P0001';
  END IF;
  IF v_com IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.community cm
                                        WHERE cm.com_id = v_com AND (cm.ins_id = c.ins OR cm.ins_id IS NULL)) THEN
    RAISE EXCEPTION 'Choose a community from the list.' USING ERRCODE = 'P0001';
  END IF;
  IF v_pwd IS NOT NULL AND length(v_pwd) < 6 THEN
    RAISE EXCEPTION 'The password needs at least 6 characters.' USING ERRCODE = 'P0001';
  END IF;
  -- the designation as the school's Staff Designation list spells it
  IF v_des IS NOT NULL THEN
    SELECT d.desname INTO v_dup FROM public.staffdesignation d
     WHERE d.ins_id = c.ins AND d.activestatus = 1 AND upper(btrim(d.desname)) = upper(v_des) LIMIT 1;
    v_des := COALESCE(v_dup, v_des);
    v_dup := NULL;
  END IF;

  -- the employee code is unique in the year
  EXECUTE format('SELECT m.stafname FROM %I.staffmast m WHERE upper(btrim(m.emp_code)) = $1 AND m.staf_id IS DISTINCT FROM $2 LIMIT 1', c.ysch)
     INTO v_dup USING v_code, v_id;
  IF v_dup IS NOT NULL THEN
    RAISE EXCEPTION 'Employee code % is already given to %.', v_code, v_dup USING ERRCODE = 'P0001';
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO public.schstaff (ins_id, stafname, shortname, gender, dob, joindate, qualification, experience,
                                 address, city, phoneno, mobileno, emailid, bloodgroup, stafcare, stafcarename,
                                 confirmationdate, staftermin, staftermindate, religion, community_id, nationality,
                                 transportreq, password, created_by, updated_by)
    VALUES (c.ins, v_name, v_short, v_gender, v_dob, v_join,
            NULLIF(btrim(r->>'qualification'), ''), NULLIF(btrim(r->>'experience'), ''),
            NULLIF(btrim(r->>'address'), ''), NULLIF(btrim(r->>'city'), ''), NULLIF(btrim(r->>'phoneno'), ''),
            v_mob, v_mail, NULLIF(upper(btrim(r->>'bloodgroup')), ''), v_care,
            CASE WHEN v_care IS NULL THEN NULL ELSE NULLIF(btrim(r->>'stafcarename'), '') END,
            v_conf, CASE WHEN v_term THEN 1 ELSE 0 END, v_termdate,
            NULLIF(btrim(r->>'religion'), ''), v_com, NULLIF(btrim(r->>'nationality'), ''),
            v_transport,
            v_pwd, c.usr, c.usr)
    RETURNING staf_id INTO v_id;
  ELSE
    UPDATE public.schstaff s SET
      stafname = v_name, shortname = v_short, gender = v_gender, dob = v_dob, joindate = v_join,
      qualification = NULLIF(btrim(r->>'qualification'), ''), experience = NULLIF(btrim(r->>'experience'), ''),
      address = NULLIF(btrim(r->>'address'), ''), city = NULLIF(btrim(r->>'city'), ''),
      phoneno = NULLIF(btrim(r->>'phoneno'), ''), mobileno = v_mob, emailid = v_mail,
      bloodgroup = NULLIF(upper(btrim(r->>'bloodgroup')), ''), stafcare = v_care,
      stafcarename = CASE WHEN v_care IS NULL THEN NULL ELSE NULLIF(btrim(r->>'stafcarename'), '') END,
      confirmationdate = v_conf, staftermin = CASE WHEN v_term THEN 1 ELSE 0 END, staftermindate = v_termdate,
      religion = NULLIF(btrim(r->>'religion'), ''), community_id = v_com,
      nationality = NULLIF(btrim(r->>'nationality'), ''),
      transportreq = v_transport,
      password = COALESCE(v_pwd, s.password),
      updated_by = c.usr
     WHERE s.staf_id = v_id AND s.ins_id = c.ins;
    IF NOT FOUND THEN RAISE EXCEPTION 'This staff member was not found.' USING ERRCODE = 'P0001'; END IF;
  END IF;

  EXECUTE format($u$
    INSERT INTO %I.staffmast AS m (staf_id, emp_code, stafname, shortname, mobile_no, emailid, designation, is_active, created_by, updated_by)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9)
    ON CONFLICT (staf_id) DO UPDATE SET
      emp_code = EXCLUDED.emp_code, stafname = EXCLUDED.stafname, shortname = EXCLUDED.shortname,
      mobile_no = EXCLUDED.mobile_no, emailid = EXCLUDED.emailid, designation = EXCLUDED.designation,
      is_active = EXCLUDED.is_active, updated_by = EXCLUDED.updated_by $u$, c.ysch)
  USING v_id, v_code, v_name, v_short, v_mob, v_mail, v_des, v_active, c.usr;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Employee code % is already in use this year.', v_code USING ERRCODE = 'P0001';
END $function$
;

COMMIT;

NOTIFY pgrst, 'reload schema';
