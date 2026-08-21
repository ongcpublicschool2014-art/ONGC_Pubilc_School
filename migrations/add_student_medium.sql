-- ============================================================================
-- Add student "Medium" (e.g. English / Tamil) end-to-end.
-- ============================================================================
-- The new student import template carries a "Medium" column. This adds a
-- `medium` column to students + the student_import staging table in every
-- institution schema, and rewrites process_student_import to carry it through.
-- (Course/Class/Admission-Type/Concession/Quota are resolved by ID on the
--  client and staged as canonical names, so the RPC needs no other change.)
-- Idempotent / safe to re-run. Run in the Supabase SQL editor.
-- ============================================================================

-- 1) Add the medium column to students + student_import in every schema.
DO $$
DECLARE r record; sname text;
BEGIN
  FOR r IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL
  LOOP
    sname := r.schema_name;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sname) THEN
      IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = sname AND table_name = 'students') THEN
        EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS medium varchar(30)', sname);
      END IF;
      IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = sname AND table_name = 'student_import') THEN
        EXECUTE format('ALTER TABLE %I.student_import ADD COLUMN IF NOT EXISTS medium varchar(30)', sname);
      END IF;
    END IF;
  END LOOP;
END $$;

-- 2) Carry medium through to students (also keeps the aadhar/etc. columns).
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
      EXECUTE format('INSERT INTO %I.students(ins_id,inscode,yr_id,yrlabel,stuadmno,stuadmdate,stuname,stugender,studob,stumobile,stuemail,stuaddress,stucity,stustate,stucountry,stupin,stubloodgrp,stuclass,courname,cour_id,con_id,stucondesc,stuser_id,stuotpstatus,approvedby,approveddate,suspendedby,terminatedby,activestatus,createdon,admname,quoname,batch,admittyear,aadharno,community,caste,religion,nationality,transportmode,hostel,medium) VALUES($1,$2,$3,$4,$5,COALESCE($6,CURRENT_DATE),$7,$8,$9,$10,NULLIF($11,''''),$12,$13,$14,$15,$16,$17,$18,$21,$26,$19,NULLIF(TRIM($20),''''),$5,0,'''',now(),'''','''',1,now(),$22,$23,$24,$25,$27,$28,$29,$30,$31,$32,$33,$34) RETURNING stu_id', v_schema) INTO v_stu_id USING rec.ins_id,rec.inscode,rec.yr_id,rec.yrlabel,rec.stuadmno,rec.stuadmdate,rec.stuname,rec.stugender,rec.studob,rec.stumobile,rec.stuemail,rec.stuaddress,rec.stucity,rec.stustate,rec.stucountry,rec.stupin,rec.stubloodgrp,rec.stuclass,v_con_id,rec.concession,rec.courname,rec.admname,rec.quoname,rec.batch,rec.admittyear,rec.cour_id,rec.aadharno,rec.community,rec.caste,rec.religion,rec.nationality,rec.transportmode,rec.hostel,rec.medium;
      v_par_id:=NULL;
      EXECUTE format('SELECT par_id FROM %I.parents WHERE payinchargemob=$1 LIMIT 1', v_schema) INTO v_par_id USING rec.payinchargemob;
      IF v_par_id IS NULL THEN
        EXECUTE format('INSERT INTO %I.parents(ins_id,yr_id,yrlabel,partype,fathername,fathermobile,fatheroccupation,mothername,mothermobile,motheroccupation,guardianname,guardianmobile,guardianoccupation,payincharge,payinchargemob,paremail,parotpstatus,approveddate,activestatus) VALUES($14,$1,$2,''P'',$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,NULLIF(TRIM($15),''''),0,now(),1) RETURNING par_id', v_schema) INTO v_par_id USING rec.yr_id,rec.yrlabel,rec.fathername,rec.fathermobile,rec.fatheroccupation,rec.mothername,rec.mothermobile,rec.motheroccupation,rec.guardianname,rec.guardianmobile,rec.guardianoccupation,rec.payincharge,rec.payinchargemob,rec.ins_id,rec.paremail;
      END IF;
      EXECUTE format('INSERT INTO %I.parentdetail(yr_id,yrlabel,par_id,stu_id,ins_id,inscode,stuadmno,stuname,stuclass,activestatus) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema) USING rec.yr_id,rec.yrlabel,v_par_id,v_stu_id,rec.ins_id,rec.inscode,rec.stuadmno,rec.stuname,rec.stuclass;
      EXECUTE format('UPDATE %I.student_import SET status=''DONE'' WHERE imp_id=$1', v_schema) USING rec.imp_id; v_imported:=v_imported+1;
    EXCEPTION WHEN OTHERS THEN
      EXECUTE format('UPDATE %I.student_import SET status=''ERROR'',error_msg=$1 WHERE imp_id=$2', v_schema) USING SQLERRM,rec.imp_id; v_skipped:=v_skipped+1;
    END;
  END LOOP;
  RETURN QUERY SELECT v_total, v_imported, v_skipped;
END; $$;

NOTIFY pgrst, 'reload config';
