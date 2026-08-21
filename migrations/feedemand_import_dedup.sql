-- ============================================================================
-- Fee Demand re-import: UPDATE the existing demand instead of duplicating it.
-- ============================================================================
-- Re-importing a fee demand for a student who already has that demand (same
-- fee type + term + year) was inserting a SECOND feedemand row, which inflated
-- the pending balance. Example: a 2000 demand with 1000 already paid (balance
-- 1000) became 3000 after a re-import = old balance 1000 + a new duplicate 2000.
--
-- This rewrites fn_approve_tempfeedemand so that, on approval, if a matching
-- ACTIVE demand already exists it UPDATES that demand's amounts and RE-DERIVES
-- the balance from the amount already paid (payments preserved) instead of
-- inserting a duplicate. First-time imports (no match) insert exactly as before.
--
-- Match key: ins_id + stu_id + demfeetype + demfeeterm + yr_id (one demand per
-- student per fee type per term per year). Idempotent — run in the SQL editor.
-- ============================================================================

DO $do$
DECLARE r record; sname text;
BEGIN
  FOR r IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL
  LOOP
    sname := r.schema_name;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sname)
       AND EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = sname AND table_name = 'feedemand') THEN

      EXECUTE format($f$
        CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql AS $t$
        DECLARE v_dem_id bigint; v_paid numeric; v_net numeric;
        BEGIN
          IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN
            -- Existing active demand for this student + fee type + term + year?
            SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid
            FROM %1$I.feedemand
            WHERE ins_id = NEW.ins_id AND stu_id = NEW.stu_id
              AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype
              AND demfeeterm IS NOT DISTINCT FROM NEW.demfeeterm
              AND yr_id     IS NOT DISTINCT FROM NEW.yr_id
              AND activestatus = 1
            ORDER BY dem_id LIMIT 1;

            IF v_dem_id IS NOT NULL THEN
              -- Re-import: refresh amounts, PRESERVE payments, never duplicate.
              v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0);
              UPDATE %1$I.feedemand
                 SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount,
                     balancedue = v_net, reconbalancedue = v_net, duedate = NEW.duedate,
                     collectible = COALESCE(NEW.collectible, collectible),
                     cla_id = NEW.cla_id, sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id
               WHERE dem_id = v_dem_id;
            ELSE
              INSERT INTO %1$I.feedemand
                (demno, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear,
                 demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue,
                 duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible,
                 cla_id, sem_id, fee_id, cf_id)
              VALUES
                (NEW.demno, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass,
                 NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id,
                 NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1,
                 NEW.createdat, NEW.createdby, 'U', 0, COALESCE(NEW.collectible, true),
                 NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id);
            END IF;
            NEW.activestatus := 9;
          END IF;
          RETURN NEW;
        END;
        $t$
      $f$, sname);

    END IF;
  END LOOP;
END $do$;

NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- OPTIONAL — clean up duplicates already created by the old behaviour.
-- The trigger above stops NEW duplicates, but any demand duplicated before this
-- fix still shows the inflated balance. Run PER SCHEMA (replace kcet20262027).
--
-- 1) PREVIEW the duplicates first:
--    SELECT stu_id, demfeetype, demfeeterm, yr_id, count(*), array_agg(dem_id),
--           array_agg(paidamount), array_agg(balancedue)
--    FROM kcet20262027.feedemand
--    WHERE activestatus = 1
--    GROUP BY stu_id, demfeetype, demfeeterm, yr_id
--    HAVING count(*) > 1;
--
-- 2) Soft-delete the extras, KEEPING the row with the most paid (then oldest):
--    WITH ranked AS (
--      SELECT dem_id, ROW_NUMBER() OVER (
--               PARTITION BY ins_id, stu_id, demfeetype, demfeeterm, yr_id
--               ORDER BY COALESCE(paidamount,0) DESC, dem_id ASC) AS rn
--      FROM kcet20262027.feedemand WHERE activestatus = 1)
--    UPDATE kcet20262027.feedemand f SET activestatus = 9
--    FROM ranked r WHERE f.dem_id = r.dem_id AND r.rn > 1;
-- ============================================================================
