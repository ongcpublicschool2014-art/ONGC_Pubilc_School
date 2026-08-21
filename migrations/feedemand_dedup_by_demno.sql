-- Fee-demand approval dedup keyed on DEMNO (ALL SCHEMAS).
-- On approval, fn_approve_tempfeedemand matches an existing feedemand by
-- (ins_id, demno, demfeetype) — the source demand number plus the fee-type line
-- within it — and UPDATEs it (amount/concession/duedate refreshed, balance =
-- feeamount - concession - already-paid; payments preserved), else INSERTs.
-- Replaces the previous (stu_id + term + year + Regular/Arrear) match key.
-- demno separates Regular vs Arrear naturally (different demand numbers), so the
-- demseqtype CASE is no longer needed. If a staged row has a blank demno it is
-- always inserted (never merged into another blank). Idempotent.

DO $$
DECLARE schema_name TEXT;
BEGIN
  FOR schema_name IN
    SELECT nspname FROM pg_namespace
    WHERE nspname NOT IN ('public', 'pg_catalog', 'information_schema', 'pg_toast', 'extensions', 'auth', 'storage', 'realtime', 'supabase_functions', 'graphql', 'graphql_public', 'pgsodium', 'pgsodium_masks', 'vault', 'net', '_realtime', 'supabase_migrations')
    AND nspname NOT LIKE 'pg_%'
  LOOP
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = schema_name AND table_name = 'tempfeedemand') THEN
      EXECUTE format($f$
        CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger
        LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$
        DECLARE v_dem_id bigint; v_paid numeric; v_net numeric;
        BEGIN
          IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN
            SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid
            FROM %1$I.feedemand
            WHERE ins_id = NEW.ins_id
              AND NEW.demno IS NOT NULL AND btrim(NEW.demno) <> ''
              AND demno IS NOT DISTINCT FROM NEW.demno
              AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype
              AND activestatus = 1
            ORDER BY dem_id LIMIT 1;
            IF v_dem_id IS NOT NULL THEN
              v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0);
              UPDATE %1$I.feedemand
                 SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount,
                     balancedue = v_net, reconbalancedue = v_net, duedate = NEW.duedate,
                     collectible = COALESCE(NEW.collectible, collectible), cla_id = NEW.cla_id,
                     sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id,
                     demseqtype = COALESCE(NEW.demseqtype, demseqtype), arrearclass = NEW.arrearclass
               WHERE dem_id = v_dem_id;
            ELSE
              INSERT INTO %1$I.feedemand (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno,
                stuclass, courname, demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount,
                balancedue, reconbalancedue, duedate, activestatus, createdat, createdby, paidstatus,
                paidamount, collectible, cla_id, sem_id, fee_id, cf_id, arrearclass)
              VALUES (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno,
                NEW.stuclass, NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount,
                NEW.con_id, NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate,
                1, NEW.createdat, NEW.createdby, 'U', 0, COALESCE(NEW.collectible, true), NEW.cla_id,
                NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass);
            END IF;
            NEW.activestatus := 9;
          END IF;
          RETURN NEW;
        END; $t$
      $f$, schema_name);
      RAISE NOTICE 'demno-keyed approval trigger installed on schema: %', schema_name;
    END IF;
  END LOOP;
END $$;
