-- ============================================================================
-- Carry class / semester / fee-type / class-fee IDs onto the fee demands.
-- ============================================================================
-- The Fee Demand import template now includes Class Id / Semester Id / Fee Id /
-- Class Fee Id. This adds matching columns to the demand tables and carries
-- them from tempfeedemand -> feedemand on approval:
--   tempfeedemand : cla_id smallint, sem_id smallint, fee_id integer, cf_id integer
--   feedemand     : cla_id smallint, sem_id smallint, cf_id integer   (fee_id exists)
-- Also switches the approved feedemand's reconbalancedue to the imported
-- balance (COALESCE(balancedue, feeamount)) so DCB reflects it. Idempotent.
-- Run in the Supabase SQL editor.
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

      EXECUTE format('ALTER TABLE %I.tempfeedemand '
        'ADD COLUMN IF NOT EXISTS cla_id smallint, '
        'ADD COLUMN IF NOT EXISTS sem_id smallint, '
        'ADD COLUMN IF NOT EXISTS fee_id integer, '
        'ADD COLUMN IF NOT EXISTS cf_id integer', sname);
      EXECUTE format('ALTER TABLE %I.feedemand '
        'ADD COLUMN IF NOT EXISTS cla_id smallint, '
        'ADD COLUMN IF NOT EXISTS sem_id smallint, '
        'ADD COLUMN IF NOT EXISTS cf_id integer', sname);

      EXECUTE format($f$
        CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql AS $t$
        BEGIN
          IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN
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
