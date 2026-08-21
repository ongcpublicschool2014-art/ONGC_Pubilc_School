-- Arrear fee-demand support: demseqtype + arrearclass (ALL SCHEMAS)
-- ------------------------------------------------------------------
-- The Fee Demand import must handle two formats:
--   * REGULAR  -> no "Type" column; demseqtype defaults to 'DEMAND'
--   * ARREAR   -> "Type" column = ARREAR, plus an "Arrear Class" column
--                 (the ORIGINAL class the arrear was raised under, which
--                  differs from the student's current class).
--
-- feedemand already has demseqtype (NOT NULL, defaulted to 'DEMAND' by the
-- set_dem_id trigger). It was MISSING from the tempfeedemand staging table,
-- and neither table had a column for the arrear's original class.
--
-- This migration adds:
--   * tempfeedemand.demseqtype  varchar(20)   -- carries ARREAR/DEMAND through staging
--   * tempfeedemand.arrearclass varchar(30)   -- original class on the staging row
--   * feedemand.arrearclass     varchar(30)   -- original class on the final demand
-- and extends fn_approve_tempfeedemand to copy both into feedemand on approval.
--
-- Run once in the Supabase SQL editor - auto-detects every schema with a
-- tempfeedemand table. Idempotent (ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE).

DO $$
DECLARE
    schema_name TEXT;
BEGIN
    FOR schema_name IN
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT IN ('public', 'pg_catalog', 'information_schema', 'pg_toast', 'extensions', 'auth', 'storage', 'realtime', 'supabase_functions', 'graphql', 'graphql_public', 'pgsodium', 'pgsodium_masks', 'vault', 'net', '_realtime', 'supabase_migrations')
        AND nspname NOT LIKE 'pg_%'
    LOOP
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = schema_name AND table_name = 'tempfeedemand') THEN
            -- 1. Staging table: carry the arrear Type + original class
            EXECUTE format('ALTER TABLE %I.tempfeedemand ADD COLUMN IF NOT EXISTS demseqtype varchar(20)', schema_name);
            EXECUTE format('ALTER TABLE %I.tempfeedemand ADD COLUMN IF NOT EXISTS arrearclass varchar(30)', schema_name);

            -- 2. Final table: original class (demseqtype already exists here)
            EXECUTE format('ALTER TABLE %I.feedemand ADD COLUMN IF NOT EXISTS arrearclass varchar(30)', schema_name);

            -- 3. Approval trigger: copy demseqtype + arrearclass into feedemand.
            --    demseqtype may be NULL for regular imports; the set_dem_id
            --    BEFORE-INSERT trigger on feedemand defaults it to 'DEMAND'.
            EXECUTE format('CREATE OR REPLACE FUNCTION %I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ BEGIN IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN INSERT INTO %I.feedemand (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue, duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible, cla_id, sem_id, fee_id, cf_id, arrearclass) VALUES (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass, NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id, NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1, NEW.createdat, NEW.createdby, ''U'', 0, COALESCE(NEW.collectible, true), NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass); NEW.activestatus := 9; END IF; RETURN NEW; END; $t$', schema_name, schema_name);

            RAISE NOTICE 'Updated schema: %', schema_name;
        END IF;
    END LOOP;
END $$;

-- Add demseqtype to get_fee_demands (public) so the Fee Collection "Pending
-- Fees" drilldown can separate Regular vs Arrear. Single shared function.
CREATE OR REPLACE FUNCTION public.get_fee_demands(p_ins_id integer) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE v text; r json; BEGIN v := get_institution_schema(p_ins_id); IF v IS NULL THEN RETURN NULL; END IF;
EXECUTE format('SELECT json_agg(json_build_object(''dem_id'',fd.dem_id,''fee_id'',fd.fee_id,''ins_id'',fd.ins_id,''stu_id'',fd.stu_id,''feeamount'',fd.feeamount,''conamount'',fd.conamount,''paidamount'',fd.paidamount,''fineamount'',fd.fineamount,''duedate'',fd.duedate,''paidstatus'',fd.paidstatus,''pay_id'',fd.pay_id,''demseqtype'',fd.demseqtype,''stuclass'',fd.stuclass,''courname'',fd.courname,''stuadmno'',fd.stuadmno,''demfeetype'',fd.demfeetype,''demfeeterm'',fd.demfeeterm,''balancedue'',fd.balancedue,''reconbalancedue'',fd.reconbalancedue,''stuname'',s.stuname) ORDER BY fd.courname,fd.stuclass) FROM %I.feedemand fd LEFT JOIN %I.students s ON s.stu_id=fd.stu_id WHERE fd.ins_id=$1 AND fd.activestatus=1', v, v) INTO r USING p_ins_id; RETURN r; END; $$;
