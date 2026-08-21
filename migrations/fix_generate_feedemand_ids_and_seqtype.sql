-- FIX: demands generated from the classfeedemand template landed in feedemand
-- with NULL cla_id/sem_id/cf_id and demseqtype='DEMAND' (the set_dem_id default),
-- because generate_feedemand_from_template didn't carry those columns into
-- tempfeedemand (approval just copies whatever tempfeedemand holds).
--
-- Fix: carry cla_id/sem_id/cf_id/fee_id from classfeedemand and stamp
-- demseqtype='REGULAR' (current-year regular demand). Plus a one-time data fix
-- to backfill the rows already generated the old way.

-- 1) Forward fix — the generator ----------------------------------------------
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
       cla_id, sem_id, cf_id, fee_id, demseqtype)
    SELECT s.ins_id, s.inscode, s.yr_id, s.stu_id, s.stuadmno, s.stuclass, s.courname,
       s.yrlabel, cf.cfterm, cf.cffeetype, cf.cfamount, s.con_id, 0, cf.cfamount,
       cf.cfdduedate, 1, COALESCE(s.approvedby, 'SYSTEM'), false, COALESCE(cf.collectible, true),
       cf.cla_id, cf.sem_id, cf.cf_id, cf.fee_id, 'REGULAR'
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

-- 2) One-time data fix for rows already generated (adjust schema name if needed).

-- 2a) Resolve cla_id / sem_id / cf_id straight from the masters (the same rules
--     the classfeedemand trigger uses), so it works even when the classfeedemand
--     template itself has them NULL. Matching is by NAME — verify the class /
--     semester masters actually contain these class names and term names, else
--     nothing resolves.
UPDATE kcet20262027.feedemand fd SET cla_id = c.cla_id
FROM kcet20262027.class c
WHERE c.activestatus = 1 AND c.claname = fd.stuclass
  AND fd.cla_id IS NULL AND fd.activestatus = 1;

UPDATE kcet20262027.feedemand fd SET sem_id = sm.sem_id
FROM kcet20262027.semester sm
WHERE sm.activestatus = 1 AND sm.semname = fd.demfeeterm
  AND fd.sem_id IS NULL AND fd.activestatus = 1;

UPDATE kcet20262027.feedemand fd SET cf_id = cf.cf_id
FROM kcet20262027.classfeedemand cf
WHERE cf.activestatus = 1 AND cf.cfclass = fd.stuclass
  AND cf.cfterm = fd.demfeeterm AND cf.cffeetype = fd.demfeetype
  AND fd.cf_id IS NULL AND fd.activestatus = 1;

-- 2b) Every current-year 'DEMAND' row becomes 'REGULAR'. Arrear rows are
--     'ARREAR' and imported rows are already 'REGULAR', so neither is touched.
--     Unconditional (NOT gated on a template match) so rows whose classfeedemand
--     line was changed/removed still flip.
UPDATE kcet20262027.feedemand
SET demseqtype = 'REGULAR'
WHERE demseqtype = 'DEMAND' AND activestatus = 1;
