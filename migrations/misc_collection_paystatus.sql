-- ============================================================================
-- Misc Collection: paid status + cancellation
--
-- misc_collection records no payment status at all, and a misc receipt raised
-- by mistake (wrong student, wrong amount, wrong fee type) cannot be cancelled
-- from the app -- Fee Cancel Receipt only handles the payment table. The only
-- recourse today is editing the row by hand.
--
-- This mirrors what payment already does:
--   paystatus 'C' = collected (every saved receipt; the row is only written
--                   once the money is confirmed)
--             'R' = voided, kept for audit with voidedby/voideddate/voidreason
--
-- A voided receipt keeps its row (activestatus 9) so the FCxx/ series stays
-- continuous and the cancellation is auditable.
--
-- SAFE TO RE-RUN.
-- ============================================================================

-- ── 1. Columns on every institution schema ──────────────────────────────────
DO $g$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'misc_collection')
       AND left(nspname,3) <> 'pg_'
       AND nspname NOT IN ('public','information_schema','auth','storage',
                           'realtime','vault','extensions','graphql','graphql_public')
  LOOP
    -- Added without a default, then backfilled, then defaulted -- the same
    -- shape as the recon columns. Every existing misc row IS collected money,
    -- so it must land on 'C'; the NULL window is what makes the backfill
    -- distinguishable and the whole file safe to re-run.
    EXECUTE format('ALTER TABLE %I.misc_collection
        ADD COLUMN IF NOT EXISTS paystatus  char(1),
        ADD COLUMN IF NOT EXISTS voidedby   varchar(100),
        ADD COLUMN IF NOT EXISTS voideddate timestamptz,
        ADD COLUMN IF NOT EXISTS voidreason varchar(255)', r.nspname);

    EXECUTE format('UPDATE %I.misc_collection SET paystatus = ''C''
                     WHERE paystatus IS NULL', r.nspname);

    EXECUTE format('ALTER TABLE %I.misc_collection
                    ALTER COLUMN paystatus SET DEFAULT ''C''', r.nspname);

    RAISE NOTICE 'misc_collection paystatus ready on %', r.nspname;
  END LOOP;
END
$g$;

-- ── 2. Voiding a misc receipt ───────────────────────────────────────────────
-- Deliberately NOT void_receipt: that one restores feedemand balances, and a
-- misc receipt settles no demand -- there is nothing to put back. All this does
-- is void the receipt and leave an audit trail.
CREATE OR REPLACE FUNCTION public.void_misc_receipt(
    p_ins_id integer,
    p_mc_id  bigint,
    p_user   text,
    p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; rec record; v_is_cash boolean;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;

  EXECUTE format('SELECT mc_id, mcno, totalamount, paymode, activestatus,
                         COALESCE(paystatus,''C'') AS paystatus,
                         COALESCE(recon_status,''R'') AS recon_status
                    FROM %I.misc_collection
                   WHERE ins_id = $1 AND mc_id = $2', v)
    INTO rec USING p_ins_id, p_mc_id;

  IF rec IS NULL THEN
    RAISE EXCEPTION 'Misc receipt % not found', p_mc_id;
  END IF;
  IF rec.activestatus <> 1 OR rec.paystatus = 'R' THEN
    RAISE EXCEPTION 'Receipt % is already cancelled', rec.mcno;
  END IF;

  -- Same protection the fee void applies: money the bank has already confirmed
  -- cannot be voided behind the statement's back. Cash never reconciles, so it
  -- stays cancellable.
  v_is_cash := LOWER(COALESCE(rec.paymode, '')) LIKE '%cash%';
  IF rec.recon_status = 'R' AND NOT v_is_cash THEN
    RAISE EXCEPTION 'Receipt % is reconciled with the bank and cannot be cancelled', rec.mcno;
  END IF;

  EXECUTE format('UPDATE %I.misc_collection
                     SET paystatus    = ''R'',
                         activestatus = 9,
                         voidedby     = $2,
                         voideddate   = NOW(),
                         voidreason   = $3
                   WHERE ins_id = $1 AND mc_id = $4', v)
    USING p_ins_id, p_user, NULLIF(p_reason,''), p_mc_id;

  -- The detail lines go with it, so a cancelled receipt cannot resurface in a
  -- fee-type breakdown.
  EXECUTE format('UPDATE %I.misc_collection_detail SET activestatus = 9
                   WHERE mc_id = $1', v) USING p_mc_id;

  RETURN jsonb_build_object('mc_id', rec.mc_id, 'mcno', rec.mcno,
                            'amount', rec.totalamount, 'cancelled', true);
END; $$;
GRANT EXECUTE ON FUNCTION public.void_misc_receipt(integer, bigint, text, text) TO anon, authenticated;

-- ── 3. New institutions get the columns too ────────────────────────────────
DO $s$
DECLARE src text; patched text; misc_ddl text; tail text; i int;
BEGIN
  SELECT prosrc INTO src FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema'
   LIMIT 1;

  IF src IS NULL THEN
    RAISE NOTICE 'create_institution_schema not found - skipping';
    RETURN;
  END IF;

  -- Isolate the misc_collection CREATE TABLE before testing anything: the word
  -- "paystatus" also appears in the payment table's DDL, so a whole-source
  -- search would report "already done" on a generator that has never been
  -- touched.
  i := position('CREATE TABLE %I.misc_collection' IN src);
  IF i = 0 THEN
    RAISE NOTICE 'misc_collection DDL not found in the generator - CHECK BY HAND';
    RETURN;
  END IF;
  misc_ddl := substr(src, i, 4000);
  misc_ddl := left(misc_ddl, position(''', v_schema)' IN misc_ddl));

  IF position('paystatus' IN misc_ddl) > 0 THEN
    RAISE NOTICE 'generator already creates paystatus - nothing to do';
    RETURN;
  END IF;

  -- Two possible tails, depending on whether misc_collection_recon.sql has run
  -- on this database yet. Try the post-recon one first.
  tail := $t1$bank_reference varchar(100), bank_date date)$t1$;
  IF position(tail IN misc_ddl) = 0 THEN
    tail := $t2$createdat timestamptz DEFAULT now(), createdby varchar(50))$t2$;
  END IF;
  IF position(tail IN misc_ddl) = 0 THEN
    RAISE NOTICE 'misc_collection DDL tail not recognised - CHECK BY HAND';
    RETURN;
  END IF;

  -- left(tail, length-1) drops exactly ONE closing paren. rtrim(tail, ')')
  -- would strip every trailing ')', turning "varchar(50))" into "varchar(50".
  patched := replace(src, tail,
      left(tail, length(tail) - 1) ||
      $add$, paystatus char(1) DEFAULT ''C'', voidedby varchar(100), voideddate timestamptz, voidreason varchar(255))$add$);

  EXECUTE 'CREATE OR REPLACE FUNCTION public.create_institution_schema('
          || 'p_schema_name text, p_ins_id integer DEFAULT NULL,'
          || 'p_year_label text DEFAULT NULL, p_start_date date DEFAULT NULL,'
          || 'p_end_date date DEFAULT NULL) RETURNS void'
          || ' LANGUAGE plpgsql SECURITY DEFINER AS $fn3$' || patched || '$fn3$';

  RAISE NOTICE 'create_institution_schema now builds misc_collection with paystatus';
END
$s$;

-- ── 4. Verify ───────────────────────────────────────────────────────────────
DO $v$
DECLARE r record; c_c int; c_r int; c_null int;
BEGIN
  FOR r IN SELECT nspname FROM pg_namespace n
            WHERE EXISTS (SELECT 1 FROM pg_class c
                           WHERE c.relnamespace=n.oid AND c.relname='misc_collection')
              AND left(nspname,3) <> 'pg_'
              AND nspname NOT IN ('public','information_schema','auth','storage',
                                  'realtime','vault','extensions','graphql','graphql_public')
  LOOP
    EXECUTE format('SELECT count(*) FILTER (WHERE paystatus=''C''),
                           count(*) FILTER (WHERE paystatus=''R''),
                           count(*) FILTER (WHERE paystatus IS NULL)
                      FROM %I.misc_collection', r.nspname)
      INTO c_c, c_r, c_null;
    RAISE NOTICE '%: % collected, % cancelled, % unset (unset must be 0)',
                 r.nspname, c_c, c_r, c_null;
  END LOOP;
END
$v$;

SELECT position('paystatus' IN prosrc) > 0 AS generator_has_paystatus
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema';

NOTIFY pgrst, 'reload schema';
