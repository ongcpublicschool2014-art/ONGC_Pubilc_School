-- ============================================================================
-- Auto-generate fee demands when a student is added (any path).
-- ============================================================================
-- Adds a per-schema AFTER-INSERT trigger on `students`. Whenever a student is
-- created — admission allocation, fast admission, manual add, or import — it
-- checks the `classfeedemand` template for the student's class and stages the
-- matching fee demands into `tempfeedemand` (isapproved = false). They then
-- appear in Fee Demand Approval and the existing approve trigger moves them to
-- `feedemand`.
--
--   * Matched on class + admission type (admissiontype NULL = applies to all);
--     adm_id is resolved from the student's admission-type name.
--   * Uses the template's due date (cfdduedate) and `collectible` flag.
--   * Skips anything already pending (tempfeedemand) or already in feedemand,
--     so it is safe to re-run / re-create students.
--
-- Safe / idempotent. Run in the Supabase SQL editor.
-- ============================================================================

DO $$
DECLARE
  r record;
  s text;
BEGIN
  FOR r IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL
  LOOP
    s := r.schema_name;
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = s);
    -- needs students, classfeedemand, tempfeedemand, feedemand, admissiontype
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = s AND table_name = 'classfeedemand');

    EXECUTE format('CREATE OR REPLACE FUNCTION %1$I.fn_gen_feedemand_on_student() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_adm_id smallint; BEGIN IF NEW.admname IS NOT NULL AND TRIM(NEW.admname) <> '''' THEN SELECT adm_id INTO v_adm_id FROM %1$I.admissiontype WHERE UPPER(TRIM(admname))=UPPER(TRIM(NEW.admname)) AND activestatus=1 LIMIT 1; END IF; INSERT INTO %1$I.tempfeedemand (ins_id,inscode,yr_id,stu_id,stuadmno,stuclass,courname,demfeeyear,demfeeterm,demfeetype,feeamount,con_id,conamount,balancedue,duedate,activestatus,createdby,isapproved,collectible,cla_id,sem_id,fee_id,cf_id) SELECT NEW.ins_id,NEW.inscode,NEW.yr_id,NEW.stu_id,NEW.stuadmno,NEW.stuclass,NEW.courname,NEW.yrlabel,cf.cfterm,cf.cffeetype,cf.cfamount,NEW.con_id,0,cf.cfamount,cf.cfdduedate,1,COALESCE(NEW.approvedby,''SYSTEM''),false,COALESCE(cf.collectible,true),cf.cla_id,cf.sem_id,cf.fee_id,cf.cf_id FROM %1$I.classfeedemand cf WHERE cf.cfclass=NEW.stuclass AND (cf.admissiontype IS NULL OR cf.admissiontype=v_adm_id) AND cf.cfamount IS NOT NULL AND (cf.cfdduedate IS NULL OR cf.cfdduedate >= NEW.stuadmdate) AND NOT EXISTS (SELECT 1 FROM %1$I.tempfeedemand t WHERE t.stu_id=NEW.stu_id AND t.demfeeterm=cf.cfterm AND t.demfeetype=cf.cffeetype AND t.activestatus=1) AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd WHERE fd.stu_id=NEW.stu_id AND fd.demfeeterm=cf.cfterm AND fd.demfeetype=cf.cffeetype AND fd.activestatus=1); RETURN NEW; END; $t$', s);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_gen_feedemand_on_student ON %1$I.students', s);
    EXECUTE format('CREATE TRIGGER trg_gen_feedemand_on_student AFTER INSERT ON %1$I.students FOR EACH ROW EXECUTE FUNCTION %1$I.fn_gen_feedemand_on_student()', s);
    RAISE NOTICE 'Installed fee-demand trigger in %', s;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload config';
