-- ============================================================================
-- Bulk-generate student fee demands from the classfeedemand template.
-- ============================================================================
-- The per-student trigger (fn_gen_feedemand_on_student) only fires when a
-- student is INSERTED. When the classfeedemand template is imported/updated for
-- students that already exist, nothing generates their demands. This RPC does
-- it in one set-based INSERT: for every active student it creates the matching
-- tempfeedemand rows (isapproved=false — they flow through the existing
-- approval trigger into feedemand). Same matching + dedup rules as the trigger,
-- so it is safe to re-run. Returns the number of demand rows created.
-- Idempotent. Run in the Supabase SQL editor.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.generate_feedemand_from_template(p_ins_id integer)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '180s'
AS $$
DECLARE v_schema text; v_count int;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;
  EXECUTE format($q$
    INSERT INTO %1$I.tempfeedemand
      (ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear,
       demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, duedate,
       activestatus, createdby, isapproved, collectible,
       cla_id, sem_id, fee_id, cf_id)
    SELECT s.ins_id, s.inscode, s.yr_id, s.stu_id, s.stuadmno, s.stuclass, s.courname,
       s.yrlabel, cf.cfterm, cf.cffeetype, cf.cfamount, s.con_id, 0, cf.cfamount,
       cf.cfdduedate, 1, COALESCE(s.approvedby, 'SYSTEM'), false, COALESCE(cf.collectible, true),
       cf.cla_id, cf.sem_id, cf.fee_id, cf.cf_id
    FROM %1$I.students s
    JOIN %1$I.classfeedemand cf
      ON cf.cfclass = s.stuclass AND cf.activestatus = 1
    LEFT JOIN %1$I.admissiontype a
      ON UPPER(TRIM(a.admname)) = UPPER(TRIM(s.admname)) AND a.activestatus = 1 AND a.ins_id = s.ins_id
    WHERE s.activestatus <> 9
      AND cf.cfamount IS NOT NULL
      AND (cf.cfdduedate IS NULL OR cf.cfdduedate >= s.stuadmdate)
      AND (cf.admissiontype IS NULL OR cf.admissiontype = a.adm_id)
      AND NOT EXISTS (SELECT 1 FROM %1$I.tempfeedemand t
            WHERE t.stu_id = s.stu_id AND t.demfeeterm = cf.cfterm
              AND t.demfeetype = cf.cffeetype AND t.activestatus = 1)
      AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd
            WHERE fd.stu_id = s.stu_id AND fd.demfeeterm = cf.cfterm
              AND fd.demfeetype = cf.cffeetype AND fd.activestatus = 1)
  $q$, v_schema);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

NOTIFY pgrst, 'reload schema';
