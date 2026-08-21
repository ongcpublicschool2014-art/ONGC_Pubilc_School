-- ============================================================================
-- Fee Demand approval: restore de-duplication (UPDATE-or-INSERT) + arrear cols.
-- ============================================================================
-- The arrear migration (add_demseqtype_arrearclass.sql) rewrote
-- fn_approve_tempfeedemand as a plain INSERT, which regressed the earlier
-- dedup fix (feedemand_import_dedup.sql) — re-importing a demand created a
-- DUPLICATE feedemand row again.
--
-- This restores the dedup: on approval, if a matching ACTIVE demand exists it
-- UPDATEs it (payments preserved) instead of inserting a duplicate; else it
-- inserts. It also carries demseqtype + arrearclass, and the match key includes
-- demfeeyear + a normalized Regular/Arrear flag so a Regular and an Arrear
-- demand for the same fee type/term (or two arrears of different years that both
-- have NULL yr_id) are NOT merged. SECURITY DEFINER (write lockdown). Idempotent.
--
-- Match key: ins_id + stu_id + demfeetype + demfeeterm + yr_id + demfeeyear
--            + (ARREAR vs REGULAR).
-- ============================================================================

DO $do$
DECLARE schema_name TEXT;
BEGIN
    FOR schema_name IN
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT IN ('public', 'pg_catalog', 'information_schema', 'pg_toast', 'extensions', 'auth', 'storage', 'realtime', 'supabase_functions', 'graphql', 'graphql_public', 'pgsodium', 'pgsodium_masks', 'vault', 'net', '_realtime', 'supabase_migrations')
        AND nspname NOT LIKE 'pg_%'
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = schema_name AND table_name = 'feedemand') THEN
            EXECUTE format($f$
              CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger
              LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$
              DECLARE v_dem_id bigint; v_paid numeric; v_net numeric;
              BEGIN
                IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN
                  SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid
                  FROM %1$I.feedemand
                  WHERE ins_id = NEW.ins_id AND stu_id = NEW.stu_id
                    AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype
                    AND demfeeterm IS NOT DISTINCT FROM NEW.demfeeterm
                    AND yr_id      IS NOT DISTINCT FROM NEW.yr_id
                    AND demfeeyear IS NOT DISTINCT FROM NEW.demfeeyear
                    AND (CASE WHEN UPPER(COALESCE(demseqtype,'')) = 'ARREAR' THEN 'A' ELSE 'R' END)
                      = (CASE WHEN UPPER(COALESCE(NEW.demseqtype,'')) = 'ARREAR' THEN 'A' ELSE 'R' END)
                    AND activestatus = 1
                  ORDER BY dem_id LIMIT 1;

                  IF v_dem_id IS NOT NULL THEN
                    v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0);
                    UPDATE %1$I.feedemand
                       SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount,
                           balancedue = v_net, reconbalancedue = v_net, duedate = NEW.duedate,
                           collectible = COALESCE(NEW.collectible, collectible),
                           cla_id = NEW.cla_id, sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id,
                           demseqtype = COALESCE(NEW.demseqtype, demseqtype), arrearclass = NEW.arrearclass
                     WHERE dem_id = v_dem_id;
                  ELSE
                    INSERT INTO %1$I.feedemand
                      (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear,
                       demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue,
                       duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible,
                       cla_id, sem_id, fee_id, cf_id, arrearclass)
                    VALUES
                      (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass,
                       NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id,
                       NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1,
                       NEW.createdat, NEW.createdby, 'U', 0, COALESCE(NEW.collectible, true),
                       NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass);
                  END IF;
                  NEW.activestatus := 9;
                END IF;
                RETURN NEW;
              END;
              $t$
            $f$, schema_name);
            RAISE NOTICE 'Updated fn_approve_tempfeedemand on %', schema_name;
        END IF;
    END LOOP;
END $do$;

NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- OPTIONAL — clean up duplicates already created by the plain-INSERT version.
-- Run PER SCHEMA (replace kcet20262027). Keeps the most-paid (then oldest) row.
--
-- Preview first:
--   SELECT stu_id, demfeetype, demfeeterm, yr_id, demfeeyear,
--          (CASE WHEN UPPER(COALESCE(demseqtype,'''')) = ''ARREAR'' THEN ''A'' ELSE ''R'' END) AS typ,
--          count(*), array_agg(dem_id), array_agg(paidamount), array_agg(balancedue)
--   FROM kcet20262027.feedemand WHERE activestatus = 1
--   GROUP BY 1,2,3,4,5,6 HAVING count(*) > 1;
--
-- Soft-delete the extras:
--   WITH ranked AS (
--     SELECT dem_id, ROW_NUMBER() OVER (
--       PARTITION BY ins_id, stu_id, demfeetype, demfeeterm, yr_id, demfeeyear,
--                    (CASE WHEN UPPER(COALESCE(demseqtype,'')) = 'ARREAR' THEN 'A' ELSE 'R' END)
--       ORDER BY COALESCE(paidamount,0) DESC, dem_id ASC) AS rn
--     FROM kcet20262027.feedemand WHERE activestatus = 1)
--   UPDATE kcet20262027.feedemand f SET activestatus = 9
--   FROM ranked r WHERE f.dem_id = r.dem_id AND r.rn > 1;
-- ============================================================================
