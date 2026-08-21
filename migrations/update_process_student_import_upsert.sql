-- Re-import should UPDATE an existing student (matched by roll no / stuadmno)
-- instead of erroring on the unique constraint and skipping. This is the current
-- process_student_import from complete_setup.sql: it looks up the student by
-- (ins_id, stuadmno); if found it UPDATEs every field, else INSERTs — and does
-- the same upsert for parentdetail and the public.admission mirror. Run this on
-- the live DB (older builds had an INSERT-only version that skipped duplicates).
-- Safe CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION public.process_student_import(p_ins_id integer) RETURNS TABLE(total integer, imported integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER
-- Bulk import of hundreds of students (per-row class/course/parent lookups)
-- can exceed the anon role's short statement_timeout. Give this function
-- its own 5-minute budget so large institution imports complete.
SET statement_timeout = '300s'
AS $$
DECLARE rec RECORD; v_stu_id bigint; v_par_id bigint; v_con_id integer; v_pd_exists boolean; v_total int:=0; v_imported int:=0; v_skipped int:=0; v_schema text;
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
      -- Upsert student by admission no: UPDATE if it already exists, else INSERT.
      v_stu_id:=NULL;
      EXECUTE format('SELECT stu_id FROM %I.students WHERE ins_id=$1 AND stuadmno=$2 LIMIT 1', v_schema) INTO v_stu_id USING rec.ins_id, rec.stuadmno;
      IF v_stu_id IS NOT NULL THEN
        EXECUTE format('UPDATE %I.students SET inscode=$2,yr_id=$3,yrlabel=$4,stuadmdate=COALESCE($6,stuadmdate),stuname=$7,stugender=$8,studob=$9,stumobile=$10,stuemail=NULLIF($11,''''),stuaddress=$12,stucity=$13,stustate=$14,stucountry=$15,stupin=$16,stubloodgrp=$17,stuclass=$18,courname=$21,cour_id=$26,admit_cour_id=$38,con_id=$19,stucondesc=NULLIF(TRIM($20),''''),admname=$22,quoname=$23,batch=$24,admittyear=$25,aadharno=$27,community=$28,caste=$29,religion=$30,nationality=$31,transportmode=$32,hostel=$33,medium=$34,cla_id=$35,adm_id=$36,quo_id=$37,activestatus=1 WHERE stu_id=$39', v_schema) USING rec.ins_id,rec.inscode,rec.yr_id,rec.yrlabel,rec.stuadmno,rec.stuadmdate,rec.stuname,rec.stugender,rec.studob,rec.stumobile,rec.stuemail,rec.stuaddress,rec.stucity,rec.stustate,rec.stucountry,rec.stupin,rec.stubloodgrp,rec.stuclass,v_con_id,rec.concession,rec.courname,rec.admname,rec.quoname,rec.batch,rec.admittyear,rec.cour_id,rec.aadharno,rec.community,rec.caste,rec.religion,rec.nationality,rec.transportmode,rec.hostel,rec.medium,rec.cla_id,rec.adm_id,rec.quo_id,rec.admit_cour_id,v_stu_id;
      ELSE
      EXECUTE format('INSERT INTO %I.students(ins_id,inscode,yr_id,yrlabel,stuadmno,stuadmdate,stuname,stugender,studob,stumobile,stuemail,stuaddress,stucity,stustate,stucountry,stupin,stubloodgrp,stuclass,courname,cour_id,admit_cour_id,con_id,stucondesc,stuser_id,stuotpstatus,approvedby,approveddate,suspendedby,terminatedby,activestatus,createdon,admname,quoname,batch,admittyear,aadharno,community,caste,religion,nationality,transportmode,hostel,medium,cla_id,adm_id,quo_id) VALUES($1,$2,$3,$4,$5,COALESCE($6,CURRENT_DATE),$7,$8,$9,$10,NULLIF($11,''''),$12,$13,$14,$15,$16,$17,$18,$21,$26,$38,$19,NULLIF(TRIM($20),''''),$5,0,'''',now(),'''','''',1,now(),$22,$23,$24,$25,$27,$28,$29,$30,$31,$32,$33,$34,$35,$36,$37) RETURNING stu_id', v_schema) INTO v_stu_id USING rec.ins_id,rec.inscode,rec.yr_id,rec.yrlabel,rec.stuadmno,rec.stuadmdate,rec.stuname,rec.stugender,rec.studob,rec.stumobile,rec.stuemail,rec.stuaddress,rec.stucity,rec.stustate,rec.stucountry,rec.stupin,rec.stubloodgrp,rec.stuclass,v_con_id,rec.concession,rec.courname,rec.admname,rec.quoname,rec.batch,rec.admittyear,rec.cour_id,rec.aadharno,rec.community,rec.caste,rec.religion,rec.nationality,rec.transportmode,rec.hostel,rec.medium,rec.cla_id,rec.adm_id,rec.quo_id,rec.admit_cour_id;
      END IF;
      v_par_id:=NULL;
      EXECUTE format('SELECT par_id FROM %I.parents WHERE payinchargemob=$1 LIMIT 1', v_schema) INTO v_par_id USING rec.payinchargemob;
      IF v_par_id IS NULL THEN
        EXECUTE format('INSERT INTO %I.parents(ins_id,yr_id,yrlabel,partype,fathername,fathermobile,fatheroccupation,mothername,mothermobile,motheroccupation,guardianname,guardianmobile,guardianoccupation,payincharge,payinchargemob,paremail,parotpstatus,approveddate,activestatus) VALUES($14,$1,$2,''P'',$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,NULLIF(TRIM($15),''''),0,now(),1) RETURNING par_id', v_schema) INTO v_par_id USING rec.yr_id,rec.yrlabel,rec.fathername,rec.fathermobile,rec.fatheroccupation,rec.mothername,rec.mothermobile,rec.motheroccupation,rec.guardianname,rec.guardianmobile,rec.guardianoccupation,rec.payincharge,rec.payinchargemob,rec.ins_id,rec.paremail;
      END IF;
      -- Parentdetail: one active link per student — update it, else insert.
      EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.parentdetail WHERE stu_id=$1 AND activestatus=1)', v_schema) INTO v_pd_exists USING v_stu_id;
      IF v_pd_exists THEN
        EXECUTE format('UPDATE %I.parentdetail SET par_id=$1,yr_id=$2,yrlabel=$3,inscode=$4,stuadmno=$5,stuname=$6,stuclass=$7 WHERE stu_id=$8 AND activestatus=1', v_schema) USING v_par_id,rec.yr_id,rec.yrlabel,rec.inscode,rec.stuadmno,rec.stuname,rec.stuclass,v_stu_id;
      ELSE
      EXECUTE format('INSERT INTO %I.parentdetail(yr_id,yrlabel,par_id,stu_id,ins_id,inscode,stuadmno,stuname,stuclass,activestatus) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema) USING rec.yr_id,rec.yrlabel,v_par_id,v_stu_id,rec.ins_id,rec.inscode,rec.stuadmno,rec.stuname,rec.stuclass;
      END IF;
      -- Mirror into public.admission as an ALLOCATED record (upsert by ins_id+admno).
      -- Live admission links by admno (no stu_id/yr_id columns); carries the id
      -- columns cla_id/cour_id/admit_cour_id/admtype_id/quo_id/medium/paremail.
      -- Narrow columns LEFT()-capped so a long value can't overflow the row.
      INSERT INTO public.admission (
        ins_id, inscode, admno, admdate, admsource, admstatus,
        allocatedclass, allocatedby, allocateddate,
        stuname, stugender, studob, stumobile, stuemail, stuaddress, stucity, stustate, stucountry,
        stupin, stubloodgrp, aadharno, courname, stuclass, admname, quoname, con_id, stucondesc,
        batch, admittyear, community, caste, religion, nationality, transportmode, hostel,
        fathername, fathermobile, fatheroccupation, mothername, mothermobile, motheroccupation,
        guardianname, guardianmobile, guardianoccupation, payincharge, payinchargemob,
        cla_id, cour_id, admit_cour_id, admtype_id, quo_id, medium, paremail,
        createdby, activestatus
      ) VALUES (
        rec.ins_id, rec.inscode, rec.stuadmno, COALESCE(rec.stuadmdate, CURRENT_DATE), 'IMPORT', 'ALLOCATED',
        LEFT(rec.stuclass,20), 'IMPORT', now(),
        rec.stuname, rec.stugender, rec.studob, LEFT(rec.stumobile,30), NULLIF(rec.stuemail,''), rec.stuaddress, rec.stucity, rec.stustate, rec.stucountry,
        rec.stupin, rec.stubloodgrp, rec.aadharno, LEFT(rec.courname,20), LEFT(rec.stuclass,20), LEFT(rec.admname,30), LEFT(rec.quoname,30), v_con_id, LEFT(NULLIF(TRIM(rec.concession),''),20),
        rec.batch, rec.admittyear, rec.community, rec.caste, rec.religion, rec.nationality, LEFT(rec.transportmode,10), rec.hostel,
        rec.fathername, LEFT(rec.fathermobile,20), rec.fatheroccupation, rec.mothername, LEFT(rec.mothermobile,20), rec.motheroccupation,
        rec.guardianname, LEFT(rec.guardianmobile,20), rec.guardianoccupation, LEFT(rec.payincharge,50), LEFT(rec.payinchargemob,20),
        rec.cla_id, rec.cour_id::smallint, rec.admit_cour_id, rec.adm_id, rec.quo_id, rec.medium, NULLIF(rec.paremail,''),
        'IMPORT', 1
      )
      ON CONFLICT (ins_id, admno) DO UPDATE SET
        admstatus='ALLOCATED', allocatedclass=EXCLUDED.allocatedclass, allocatedby='IMPORT', allocateddate=now(),
        stuname=EXCLUDED.stuname, stugender=EXCLUDED.stugender, studob=EXCLUDED.studob,
        stumobile=EXCLUDED.stumobile, stuemail=EXCLUDED.stuemail, stuaddress=EXCLUDED.stuaddress,
        stucity=EXCLUDED.stucity, stustate=EXCLUDED.stustate, stucountry=EXCLUDED.stucountry,
        stupin=EXCLUDED.stupin, stubloodgrp=EXCLUDED.stubloodgrp, aadharno=EXCLUDED.aadharno,
        courname=EXCLUDED.courname, stuclass=EXCLUDED.stuclass, admname=EXCLUDED.admname, quoname=EXCLUDED.quoname,
        con_id=EXCLUDED.con_id, stucondesc=EXCLUDED.stucondesc, batch=EXCLUDED.batch, admittyear=EXCLUDED.admittyear,
        community=EXCLUDED.community, caste=EXCLUDED.caste, religion=EXCLUDED.religion, nationality=EXCLUDED.nationality,
        transportmode=EXCLUDED.transportmode, hostel=EXCLUDED.hostel,
        fathername=EXCLUDED.fathername, fathermobile=EXCLUDED.fathermobile, fatheroccupation=EXCLUDED.fatheroccupation,
        mothername=EXCLUDED.mothername, mothermobile=EXCLUDED.mothermobile, motheroccupation=EXCLUDED.motheroccupation,
        guardianname=EXCLUDED.guardianname, guardianmobile=EXCLUDED.guardianmobile, guardianoccupation=EXCLUDED.guardianoccupation,
        payincharge=EXCLUDED.payincharge, payinchargemob=EXCLUDED.payinchargemob,
        cla_id=EXCLUDED.cla_id, cour_id=EXCLUDED.cour_id, admit_cour_id=EXCLUDED.admit_cour_id,
        admtype_id=EXCLUDED.admtype_id, quo_id=EXCLUDED.quo_id, medium=EXCLUDED.medium, paremail=EXCLUDED.paremail,
        activestatus=1;
      EXECUTE format('UPDATE %I.student_import SET status=''DONE'' WHERE imp_id=$1', v_schema) USING rec.imp_id; v_imported:=v_imported+1;
    EXCEPTION WHEN OTHERS THEN
      EXECUTE format('UPDATE %I.student_import SET status=''ERROR'',error_msg=$1 WHERE imp_id=$2', v_schema) USING SQLERRM,rec.imp_id; v_skipped:=v_skipped+1;
    END;
  END LOOP;
  RETURN QUERY SELECT v_total, v_imported, v_skipped;
END; $$;

NOTIFY pgrst, 'reload schema';
