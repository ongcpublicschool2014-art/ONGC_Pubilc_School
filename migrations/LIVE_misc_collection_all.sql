-- ############################################################################
-- LIVE MIGRATION -- misc collection: bank reconciliation + paid status
--
-- Two migrations in one script, in dependency order. Both are idempotent, and
-- each ends with its own verification output. Watch for:
--   PART A  "<schema>: 0 pending, <N> reconciled"   <- 0 pending is the check
--           generator_has_recon_columns = true
--   PART B  "<schema>: <N> collected, 0 cancelled, 0 unset"  <- 0 unset
--           generator_has_paystatus = true
--
-- Anything else on a first run means historic misc money changed state --
-- stop there.
-- ############################################################################

-- ############################ PART A ########################################
-- ============================================================================
-- Bank Reconciliation for MISC COLLECTION
--
-- Misc receipts (BONAFIDE, APPLICATION, …) have never been part of bank
-- reconciliation: misc_collection has no recon columns at all, so a UPI misc
-- receipt counted as collected the instant it was saved, with nothing to tick
-- off against the bank statement.
--
-- This gives misc receipts the same lifecycle as fee payments:
--   cash      -> recon_status 'R' immediately (no bank line to match)
--   non-cash  -> recon_status 'P' until approved in Bank Reconciliation
--
-- SAFE TO RE-RUN. Read the backfill note below before running it a second time.
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
    -- recon_status is added WITHOUT a default on purpose. With a default of
    -- 'P' every historic row would become "pending approval" and the money
    -- already banked months ago would drop out of every collection total.
    -- No default => existing rows get NULL => the backfill below can tell
    -- "already collected, before this feature existed" apart from "genuinely
    -- awaiting approval", and re-running this file cannot approve a real
    -- pending receipt.
    -- paytm_txnid belongs to an earlier migration, but a database restored
    -- from a backup taken before it will not have the column -- and this file
    -- replaces save_misc_collection, which writes to it. Added here so the
    -- migration stands on its own; a no-op where it already exists.
    EXECUTE format('ALTER TABLE %I.misc_collection
        ADD COLUMN IF NOT EXISTS paytm_txnid     varchar(60),
        ADD COLUMN IF NOT EXISTS recon_status    char(1),
        ADD COLUMN IF NOT EXISTS reconciled_by   varchar(50),
        ADD COLUMN IF NOT EXISTS reconciled_date timestamptz,
        ADD COLUMN IF NOT EXISTS bank_reference  varchar(100),
        ADD COLUMN IF NOT EXISTS bank_date       date', r.nspname);

    EXECUTE format('UPDATE %I.misc_collection SET recon_status = ''R''
                     WHERE recon_status IS NULL', r.nspname);

    -- Only now does 'P' become the default, so it applies to NEW rows only.
    EXECUTE format('ALTER TABLE %I.misc_collection
                    ALTER COLUMN recon_status SET DEFAULT ''P''', r.nspname);

    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_misc_recon
                      ON %I.misc_collection (ins_id, recon_status, activestatus)',
                   r.nspname);

    RAISE NOTICE 'misc_collection recon columns ready on %', r.nspname;
  END LOOP;
END
$g$;

-- ── 2. New misc receipts: cash settles at once, everything else waits ───────
-- Only the INSERT changes; the rest of the function is byte-for-byte as it was.
CREATE OR REPLACE FUNCTION public.save_misc_collection(
    p_ins_id integer, p_header jsonb, p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_schema text; v_mc_id bigint; v_total numeric; v_mcno text;
  v_seq_id int; v_cur int; v_sequid text; v_width int; v_prefix text;
  v_yr_id int; v_yrlabel text; itm jsonb;
  v_paymode text; v_recon char(1);
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;

  -- Year: fall back to the institution's current year when the client sends none.
  v_yr_id   := NULLIF(p_header->>'yr_id','')::int;
  v_yrlabel := NULLIF(p_header->>'yrlabel','');
  IF v_yr_id IS NULL OR v_yrlabel IS NULL THEN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1
                    ORDER BY yr_id DESC LIMIT 1', v_schema)
      INTO v_yr_id, v_yrlabel USING p_ins_id;
  END IF;

  -- Receipt number from the SHARED fee-collection sequence, so misc and fee
  -- receipts stay on one continuous FCxx/ series.
  EXECUTE format('SELECT seq_id, seqcurno, sequid, seqwidth FROM %I.sequence
                   WHERE ins_id=$1 AND activestatus=1 ORDER BY seq_id LIMIT 1', v_schema)
    INTO v_seq_id, v_cur, v_sequid, v_width USING p_ins_id;
  IF v_seq_id IS NULL THEN RAISE EXCEPTION 'No receipt sequence configured'; END IF;

  v_cur    := COALESCE(v_cur, 0) + 1;
  v_prefix := regexp_replace(COALESCE(v_sequid, ''), '\d+$', '');
  v_mcno   := v_prefix || lpad(v_cur::bigint::text, COALESCE(v_width, 5)::int, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_cur, v_seq_id;

  SELECT COALESCE(SUM((x->>'amount')::numeric), 0) INTO v_total FROM jsonb_array_elements(p_lines) x;

  -- Cash never goes to reconciliation: there is no bank line to match it to,
  -- which is exactly the rule fee payments already use.
  v_paymode := LOWER(COALESCE(NULLIF(p_header->>'paymode',''), 'Cash'));
  v_recon   := CASE WHEN v_paymode LIKE '%cash%' THEN 'R' ELSE 'P' END;

  EXECUTE format('INSERT INTO %I.misc_collection
      (ins_id,inscode,yr_id,yrlabel,mcno,mcdate,selection,stu_id,regno,stuclass,stuname,courname,
       city,address,paymode,ban_id,bankname,transrefno,draweebank,transdate,transamt,collectedby,remarks,
       totalamount,activestatus,createdby,paytm_txnid,recon_status,reconciled_by,reconciled_date)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,1,$25,$26,
             $27,
             CASE WHEN $27 = ''R'' THEN $22 ELSE NULL END,
             CASE WHEN $27 = ''R'' THEN NOW() ELSE NULL END)
     RETURNING mc_id', v_schema)
    INTO v_mc_id
    USING p_ins_id, p_header->>'inscode', v_yr_id, v_yrlabel,
          v_mcno, COALESCE(NULLIF(p_header->>'mcdate','')::date, CURRENT_DATE),
          COALESCE(NULLIF(p_header->>'selection',''), 'S'), NULLIF(p_header->>'stu_id','')::bigint,
          p_header->>'regno', p_header->>'stuclass', p_header->>'stuname', p_header->>'courname',
          p_header->>'city', p_header->>'address',
          COALESCE(NULLIF(p_header->>'paymode',''), 'Cash'), NULLIF(p_header->>'ban_id','')::integer,
          p_header->>'bankname', p_header->>'transrefno', p_header->>'draweebank',
          NULLIF(p_header->>'transdate','')::date, NULLIF(p_header->>'transamt','')::numeric,
          p_header->>'collectedby', p_header->>'remarks', v_total,
          COALESCE(NULLIF(p_header->>'collectedby',''), 'SYSTEM'),
          NULLIF(p_header->>'paytm_txnid',''),
          v_recon;

  FOR itm IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    CONTINUE WHEN COALESCE(TRIM(itm->>'feetype'), '') = '';
    EXECUTE format('INSERT INTO %I.misc_collection_detail (mc_id,ins_id,fee_id,feetype,amount,activestatus)
        VALUES ($1,$2,$3,$4,$5,1)', v_schema)
      USING v_mc_id, p_ins_id, NULLIF(itm->>'fee_id','')::integer, itm->>'feetype',
            COALESCE(NULLIF(itm->>'amount','')::numeric, 0);
  END LOOP;

  RETURN jsonb_build_object('mc_id', v_mc_id, 'mcno', v_mcno, 'total', v_total,
                            'recon_status', v_recon);
END;
$$;
GRANT EXECUTE ON FUNCTION public.save_misc_collection(integer, jsonb, jsonb) TO anon, authenticated;

-- ── 3. Bank Reconciliation reads misc alongside fee payments ────────────────
CREATE OR REPLACE FUNCTION public.get_bank_recon_data(p_ins_id integer) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; r json;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN '{}'::json; END IF;
  EXECUTE format('SELECT json_build_object(
    ''pending'', COALESCE((SELECT json_agg(t) FROM (SELECT p.pay_id,p.paynumber,p.transtotalamount,p.paydate,p.paymethod,p.payreference,p.paychequeno,p.payorderid,p.stu_id,p.createdby,p.recon_status,s.stuname,s.stuadmno,s.stuclass FROM %1$I.payment p LEFT JOIN %1$I.students s ON s.stu_id=p.stu_id AND s.ins_id=p.ins_id WHERE p.ins_id=$1 AND p.paystatus=''C'' AND p.recon_status=''P'' AND p.activestatus=1 ORDER BY p.paydate DESC) t), ''[]''::json),
    ''reconciled'', COALESCE((SELECT json_agg(t) FROM (SELECT p.pay_id,p.paynumber,p.transtotalamount,p.paydate,p.paymethod,p.payreference,p.stu_id,p.createdby,p.recon_status,p.reconciled_by,p.reconciled_date,p.bank_reference,s.stuname,s.stuadmno,s.stuclass FROM %1$I.payment p LEFT JOIN %1$I.students s ON s.stu_id=p.stu_id AND s.ins_id=p.ins_id WHERE p.ins_id=$1 AND p.paystatus=''C'' AND p.recon_status=''R'' AND p.activestatus=1 ORDER BY p.reconciled_date DESC) t), ''[]''::json),
    ''misc_pending'', COALESCE((SELECT json_agg(t) FROM (SELECT m.mc_id,m.mcno,m.mcdate,m.totalamount,m.paymode,m.transrefno,m.paytm_txnid,m.stuname,m.regno,m.stuclass,m.createdby,m.recon_status FROM %1$I.misc_collection m WHERE m.ins_id=$1 AND m.recon_status=''P'' AND m.activestatus=1 ORDER BY m.mcdate DESC) t), ''[]''::json),
    ''misc_reconciled'', COALESCE((SELECT json_agg(t) FROM (SELECT m.mc_id,m.mcno,m.mcdate,m.totalamount,m.paymode,m.transrefno,m.paytm_txnid,m.stuname,m.regno,m.stuclass,m.createdby,m.recon_status,m.reconciled_by,m.reconciled_date,m.bank_reference FROM %1$I.misc_collection m WHERE m.ins_id=$1 AND m.recon_status=''R'' AND m.activestatus=1 ORDER BY m.reconciled_date DESC NULLS LAST LIMIT 200) t), ''[]''::json)
  )', v) INTO r USING p_ins_id;
  RETURN COALESCE(r, '{}'::json);
END; $$;
GRANT EXECUTE ON FUNCTION public.get_bank_recon_data(integer) TO anon, authenticated;

-- ── 4. Approving misc receipts ──────────────────────────────────────────────
-- Separate from reconcile_payments_batch because a misc receipt has no
-- feedemand behind it: there is no balance to snapshot, only the receipt to
-- mark settled. Returns the number of rows actually moved.
CREATE OR REPLACE FUNCTION public.reconcile_misc_batch(
    p_ins_id    integer,
    p_mc_ids    bigint[],
    p_user      text,
    p_bank_ref  text DEFAULT NULL,
    p_bank_date text DEFAULT NULL
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; n integer := 0;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;
  IF p_mc_ids IS NULL OR array_length(p_mc_ids,1) IS NULL THEN RETURN 0; END IF;

  -- recon_status='P' in the WHERE clause, so approving twice cannot rewrite the
  -- reconciled_by / reconciled_date of a receipt somebody else already settled.
  EXECUTE format('UPDATE %I.misc_collection
                     SET recon_status    = ''R'',
                         reconciled_by   = $2,
                         reconciled_date = NOW(),
                         bank_reference  = COALESCE($3, bank_reference),
                         bank_date       = COALESCE($4::date, bank_date)
                   WHERE ins_id = $5 AND mc_id = ANY($1)
                     AND recon_status = ''P'' AND activestatus = 1', v)
    USING p_mc_ids, p_user, NULLIF(p_bank_ref,''), NULLIF(p_bank_date,''), p_ins_id;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;
GRANT EXECUTE ON FUNCTION public.reconcile_misc_batch(integer, bigint[], text, text, text) TO anon, authenticated;

-- ── 5. Verify ───────────────────────────────────────────────────────────────
-- Expect: every historic row 'R', and only genuinely new non-cash receipts 'P'.
DO $v$
DECLARE r record; c_p int; c_r int;
BEGIN
  FOR r IN SELECT nspname FROM pg_namespace n
            WHERE EXISTS (SELECT 1 FROM pg_class c
                           WHERE c.relnamespace=n.oid AND c.relname='misc_collection')
              AND left(nspname,3) <> 'pg_'
              AND nspname NOT IN ('public','information_schema','auth','storage',
                                  'realtime','vault','extensions','graphql','graphql_public')
  LOOP
    EXECUTE format('SELECT count(*) FILTER (WHERE recon_status=''P''),
                           count(*) FILTER (WHERE recon_status=''R'')
                      FROM %I.misc_collection WHERE activestatus=1', r.nspname)
      INTO c_p, c_r;
    RAISE NOTICE '%: % pending, % reconciled', r.nspname, c_p, c_r;
  END LOOP;
END
$v$;

NOTIFY pgrst, 'reload schema';

-- ── 6. The super-admin dashboard must stop counting unapproved misc ────────
-- get_super_admin_dashboard sums misc_collection.totalamount with no status
-- filter. Left alone it reports money the bank has not confirmed, while the
-- college dashboard (which now filters) reports less -- two figures for the
-- same number is worse than either one being wrong.
--
-- Patched by rewriting the stored source rather than pasting the whole
-- function here: it is long, unrelated to this change, and re-typing it is how
-- an unrelated regression gets introduced.
--
-- NOTE ON QUOTING: the text being spliced in lands INSIDE a format('...')
-- string in the function body, so the body must read  ''R''  -- a single 'R'
-- would close that literal early ("syntax error at or near R"). The search and
-- replacement are dollar-quoted for exactly this reason: inside a dollar-quoted
-- literal a quote is just a quote, so what you read here is what gets stored.
-- COALESCE(recon_status,'R') so a row predating these columns still counts.
DO $d$
DECLARE src text; patched text;
BEGIN
  SELECT prosrc INTO src FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'get_super_admin_dashboard'
   LIMIT 1;

  IF src IS NULL THEN
    RAISE NOTICE 'get_super_admin_dashboard not found - skipping';
    RETURN;
  END IF;

  patched := replace(
    src,
    $old$SELECT COALESCE(SUM(totalamount),0) FROM %I.misc_collection WHERE ins_id=$1 AND activestatus=1$old$,
    $new$SELECT COALESCE(SUM(totalamount),0) FROM %I.misc_collection WHERE ins_id=$1 AND activestatus=1 AND COALESCE(recon_status,''R'')=''R''$new$
  );

  IF patched = src THEN
    RAISE NOTICE 'misc sum already filtered (or not found) in get_super_admin_dashboard';
    RETURN;
  END IF;

  EXECUTE 'CREATE OR REPLACE FUNCTION public.get_super_admin_dashboard(p_yrlabel text DEFAULT NULL)'
          || ' RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $fn$' || patched || '$fn$';
  RAISE NOTICE 'get_super_admin_dashboard now counts approved misc only';
END
$d$;

-- ── 7. New institutions must be born with these columns ────────────────────
-- Section 1 only touches schemas that exist TODAY. create_institution_schema
-- builds misc_collection for every institution created from here on, so
-- without this the next college would come up missing the recon columns and
-- save_misc_collection would fail on its first non-cash misc receipt.
--
-- Patched in place rather than by re-pasting the whole generator: it is ~300
-- lines of DDL for every table in a tenant schema, most of it unrelated, and
-- this database's copy may differ from the repo's.
DO $s$
DECLARE src text; patched text; tail text; add_txn boolean;
BEGIN
  SELECT prosrc INTO src FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema'
   LIMIT 1;

  IF src IS NULL THEN
    RAISE NOTICE 'create_institution_schema not found - skipping';
    RETURN;
  END IF;

  IF position($chk$recon_status char(1) DEFAULT ''P''$chk$ IN src) > 0 THEN
    RAISE NOTICE 'generator already creates the recon columns - nothing to do';
    RETURN;
  END IF;

  -- This database's generator may predate paytm_txnid; only add what is absent.
  add_txn := position($chk$paytm_txnid varchar(60)$chk$ IN src) = 0;

  -- The tail of the misc_collection CREATE TABLE. Unique in the generator:
  -- every other table declares createdat as `timestamp`, not `timestamptz`.
  tail := $old$createdat timestamptz DEFAULT now(), createdby varchar(50))$old$;

  IF position(tail IN src) = 0 THEN
    RAISE NOTICE 'misc_collection DDL not found in the generator - CHECK BY HAND';
    RETURN;
  END IF;

  -- Doubled quotes around P: this text sits inside a format('CREATE TABLE ...')
  -- literal in the generator body, so a single quote would end that string.
  patched := replace(src, tail,
      $new$createdat timestamptz DEFAULT now(), createdby varchar(50)$new$
      || CASE WHEN add_txn THEN $t$, paytm_txnid varchar(60)$t$ ELSE '' END
      || $rec$, recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamptz, bank_reference varchar(100), bank_date date)$rec$);

  EXECUTE 'CREATE OR REPLACE FUNCTION public.create_institution_schema('
          || 'p_schema_name text, p_ins_id integer DEFAULT NULL,'
          || 'p_year_label text DEFAULT NULL, p_start_date date DEFAULT NULL,'
          || 'p_end_date date DEFAULT NULL) RETURNS void'
          || ' LANGUAGE plpgsql SECURITY DEFINER AS $fn2$' || patched || '$fn2$';

  RAISE NOTICE 'create_institution_schema now builds misc_collection with the recon columns%',
               CASE WHEN add_txn THEN ' (and paytm_txnid)' ELSE '' END;
END
$s$;

-- Verify: the generator's misc_collection DDL should now mention recon_status.
SELECT position('recon_status' IN prosrc) > 0 AS generator_has_recon_columns
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema';


-- ############################ PART B ########################################
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
