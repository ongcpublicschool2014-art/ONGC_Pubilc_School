-- =====================================================================
-- LIVE RELEASE -- 13-10-2026.  ONE SCRIPT. Paste it all, Run once.
-- =====================================================================
-- Pairs with desktop 0.0.16 and parent app 1.1.6.
--
-- MOST OF THIS IS ALREADY ON LIVE. Parts A and B went out on the evening of
-- 12-10, and C, D and E during 13-10. They are here so one script describes
-- the whole state, and because every part is idempotent -- an applied part
-- reports "already patched" and changes nothing. Only PART F is new.
--
--   PART A  stamp_payorderid() + create_pending_payment's age guard.
--           THE EDGE FUNCTION MUST MATCH -- see the note at the end.
--   PART B  paymentdetails indexes, unique bank account numbers, misc
--           receipts numbered from their own fee group, cash-only
--           cancellation, hostellers-only fee groups.
--   PART C  list_webhook_refusals() -- read-only, cannot clear a refusal.
--   PART D  delete_stale_initiated_payments guarded the same way as
--           create_pending_payment. It is called by the PARENT APP and runs
--           the same DELETE with the same false test.
--   PART E  removes a duplicated guard clause. Cosmetic: X AND X is X.
--   PART F  feetype.ordid, seeded, plus the generator so a NEW institution
--           is born with it.
--   PART G  read-only verification. Expect every column true except
--           feetype_unset, which counts what you have not numbered yet.
--
-- ---------------------------------------------------------------------
-- PART ORDER MATTERS, ONCE. PART B replaces create_institution_schema
-- WHOLESALE with a copy written on 12-10, which predates feetype.ordid and
-- therefore drops it. PART F patches it back. This order is correct, and the
-- dry run ends with the column present.
--
-- The consequence outlives this script: RELEASE_LIVE_2026_10_12_EVENING.sql
-- must NOT be run on its own again. It would silently walk the generator back
-- and the next institution would be born without feetype.ordid -- the same
-- trap as the September webhook file, which reverts refusal recording.
--
-- A migration file is a photograph of the day it was written. Before running
-- an older one, check what newer files touch the same function:
--     grep -rln "FUNCTION public.<name>" migrations/
--
-- ---------------------------------------------------------------------
-- ALL OR NOTHING. The editor runs this as one transaction, so a raise
-- anywhere rolls back everything before it. A refused run changes nothing.
--
-- Do NOT add BEGIN -- the editor supplies it, and typing your own makes the
-- editor roll the script back while reporting success.
--
-- IF YOU WILL SET THE FEE-TYPE ORDER YOURSELF, comment out PART F's seeding
-- block ($seed$ ... $seed$). It only ever fills NULLs, so running it first
-- and renumbering afterwards works too -- but leaving rows NULL lets
-- feetype_unset below tell you how many are still to do. The app sorts
-- unnumbered fee types LAST, so a half-finished numbering still reads well.
-- =====================================================================


-- #####################################################################
-- PART A -- payorderid: stamp + the 15-minute delete guard
-- #####################################################################

-- ============================================================================
-- Mobile payments must carry their Paytm order id.
-- ============================================================================
-- WHAT IS BROKEN. create-paytm-order tries to write the order id onto the
-- payment row with:
--
--     supabase.from("payment").update({ payorderid: orderId }).eq("pay_id", …)
--
-- `from("payment")` with no schema means public.payment -- which DOES NOT
-- EXIST. The table lives in <institution schema>. So the update matches
-- nothing, and the failure is swallowed:
--
--     } catch (_) { /* Non-fatal: the client also updates payorderid. */ }
--
-- The DESKTOP client saves itself by stamping it a line later. The MOBILE app
-- does not, so a mobile payment's order id is never written anywhere. Three
-- things follow, and all three happened to KANNAN D on 11-10-2026:
--
--   1. webhook_find_payment matches ONLY on payorderid, so the webhook can
--      never turn a mobile payment into a receipt. No receipt number.
--   2. _sweepOrphanedPayments needs payorderid to ask Paytm, so it can never
--      recover one either. Status never changes.
--   3. create_pending_payment DELETES 'I' rows whose payorderid is blank, as
--      a proxy for "never reached the gateway". With the stamp never written,
--      that proxy is always true -- so the next attempt deletes the row for
--      an attempt that has ALREADY BEEN PAID, along with its detail lines.
--
-- Of 1,149 completed gateway payments, 755 have no payorderid.
--
-- WHAT THIS DOES.
--   PART 1  stamp_payorderid() -- writes the order id into the right
--           institution schema, which the edge function could not do.
--   PART 2  create_pending_payment stops deleting rows younger than 15
--           minutes, so even a missed stamp cannot destroy a live attempt.
--
-- PART 3 is NOT here: create-paytm-order must call stamp_payorderid instead
-- of from("payment"), and must stop swallowing the failure. Deploy that with
-- this -- PART 1 alone changes nothing until something calls it.
--
-- Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 1 =
-- Stamp the order id onto the payment row, in whichever schema it lives.
--
-- Loops the active institutions exactly as webhook_find_payment does: the
-- edge function knows a pay_id but not which tenant it belongs to.
--
-- Only fills a BLANK payorderid. It will not overwrite one already set, so
-- the desktop's own stamp is never clobbered and a replay cannot repoint a
-- row at a different order.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.stamp_payorderid(
  p_pay_id bigint, p_order_id text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $fn$
DECLARE v_ins integer; v_schema text; v_n integer; v_existing text;
BEGIN
  IF p_pay_id IS NULL OR p_pay_id <= 0 THEN RETURN false; END IF;
  IF COALESCE(btrim(p_order_id), '') = '' THEN RETURN false; END IF;

  FOR v_ins IN SELECT i.ins_id FROM public.institution i WHERE i.activestatus = 1 LOOP
    v_schema := get_institution_schema(v_ins);
    CONTINUE WHEN v_schema IS NULL;

    EXECUTE format(
      'UPDATE %I.payment SET payorderid = $1
        WHERE pay_id = $2 AND activestatus = 1
          AND COALESCE(btrim(payorderid), '''') = ''''', v_schema)
      USING btrim(p_order_id), p_pay_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN RETURN true; END IF;

    -- Already stamped with this same order id: idempotent, report success so
    -- a retried call does not read as a failure.
    EXECUTE format(
      'SELECT btrim(payorderid) FROM %I.payment WHERE pay_id = $1', v_schema)
      INTO v_existing USING p_pay_id;
    IF v_existing = btrim(p_order_id) THEN RETURN true; END IF;
  END LOOP;

  RETURN false;
END;
$fn$;

-- The edge function calls this with the service role key.
GRANT EXECUTE ON FUNCTION public.stamp_payorderid(bigint, text) TO service_role;


-- =================================================================== PART 2 =
-- create_pending_payment must not delete a live attempt.
--
-- Its delete uses "payorderid is blank" to mean "never reached the gateway,
-- so nothing can have been charged". Sound reasoning, false premise: the
-- stamp was never written. Until every caller stamps reliably, age is the
-- safer test -- a row created in the last 15 minutes may have a checkout
-- open right now, whatever its payorderid says.
--
-- 15 minutes matches _sweepOrphanedPayments' own cutoff, so a row this
-- refuses to delete is one the sweep has already taken responsibility for.
-- ===========================================================================

DO $patch$
DECLARE
  src text;
  old_det CONSTANT text := '     AND COALESCE(length(btrim(payorderid)), 0) = 0)';
  new_det CONSTANT text := '     AND COALESCE(length(btrim(payorderid)), 0) = 0'
                           ' AND createdat < now() - interval ''''15 minutes'''')';
  old_pay CONSTANT text := '   AND COALESCE(length(btrim(payorderid)), 0) = 0';
  new_pay CONSTANT text := '   AND COALESCE(length(btrim(payorderid)), 0) = 0'
                           ' AND createdat < now() - interval ''''15 minutes''''';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_pending_payment';
  IF src IS NULL THEN
    RAISE NOTICE 'create_pending_payment does not exist'; RETURN;
  END IF;
  IF src LIKE '%15 minutes%' THEN
    RAISE NOTICE 'create_pending_payment already guarded'; RETURN;
  END IF;
  IF position(old_det in src) = 0 OR position(old_pay in src) = 0 THEN
    RAISE EXCEPTION 'create_pending_payment does not carry the expected delete '
      '-- NOT patched. Its definition has changed since this was written.';
  END IF;
  -- ORDER AND GUARD BOTH MATTER, and getting this wrong is not theoretical:
  -- the first version of this patch ran old_det then old_pay and produced
  --
  --     ... = 0 AND createdat < now() - interval '15 minutes'
  --             AND createdat < now() - interval '15 minutes'
  --
  -- on live. old_pay (3-space indent) is a SUBSTRING of old_det (5-space),
  -- so replacing the detail line first leaves text the payment pattern still
  -- matches, and it appends the clause a second time. Harmless -- X AND X is
  -- X -- but wrong, and it propagated into complete_setup.sql.
  --
  -- Fixed by anchoring the payment form on its line ending rather than
  -- letting it float: the detail form ends in ')', the payment form does not.
  src := replace(src, old_det, new_det);
  src := replace(src, old_pay || '''', new_pay || '''');
  EXECUTE src;
  RAISE NOTICE 'patched public.create_pending_payment';
END
$patch$;

-- #####################################################################
-- PART B -- the 12-10 evening release (indexes, bank uniqueness, misc receipt numbering, cash-only cancellation, hostellers-only fee groups)
-- #####################################################################

-- =====================================================================
-- LIVE RELEASE -- evening of 12-10-2026.  ONE SCRIPT. Paste it all, Run once.
-- =====================================================================
-- Five changes, each already applied and tested on the TEST restore of this
-- morning's live dump.
--
--   PART 0  GUARDS. Change nothing; refuse if the configuration would make a
--           later part break something. Read these first if it stops.
--   PART 1  paymentdetails indexes -- Daily Collection over a long date range
--           was dying on anon's 3s statement_timeout and reporting
--           "No collections in this range". 3,208ms -> 369ms measured.
--   PART 2  bank account numbers unique -- the same account could be added
--           twice, and each row carries its own paytm_mid, so one real
--           account could settle money two ways.
--   PART 3  misc receipts numbered from their OWN fee group's series. A
--           HOSTEL FEES collection came out as FC26/03926.
--   PART 4  only a CASH receipt may be cancelled. An online transfer, UPI,
--           NEFT, cheque, DD or advance adjustment is returned through Fee
--           Refund instead.
--   PART 5  fee groups can be marked HOSTELLERS ONLY, and the two paths that
--           raise class demands both honour it.
--   PART 6  read-only verification. Expect every column true.
--
-- ---------------------------------------------------------------------
-- ALL OR NOTHING. The Supabase editor runs this as one transaction, so a
-- raise anywhere rolls back everything before it. A refused run changes
-- nothing and is safe to repeat after fixing what it named.
--
-- Do NOT add BEGIN -- the editor supplies it, and typing your own makes the
-- editor roll the script back while reporting success.
--
-- RE-RUNNABLE. Every part is idempotent: CREATE OR REPLACE, IF NOT EXISTS,
-- and the seed only touches rows still at their default.
--
-- SAFE AT THE COUNTER, with one caveat: PART 2 takes a brief write lock on
-- `bank` and PART 1 on `paymentdetails` while the indexes build -- a second
-- or two each at this size.
--
-- PAIRS WITH the desktop build of 12-10-2026. PART 5's screen half and
-- PART 4's wording live in the app; the database halves are here.
-- =====================================================================


-- =================================================================== PART 0 =
-- GUARDS. These only look.
--
-- 0a  Two LIVE bank rows on one account number would make PART 2's unique
--     index impossible to build.
-- ===========================================================================

DO $guard$
DECLARE r record; bad text := ''; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'bank'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    FOR r IN EXECUTE format(
      'SELECT %L AS sch, btrim(banaccno) AS accno, count(*) AS c,
              string_agg(ban_id::text, '', '' ORDER BY ban_id) AS ids
         FROM %I.bank
        WHERE activestatus = 1 AND COALESCE(btrim(banaccno), '''') <> ''''
        GROUP BY btrim(banaccno) HAVING count(*) > 1', r.sch, r.sch)
    LOOP
      bad := bad || format('%s  %s: account %s on ban_id %s',
                           chr(10), r.sch, r.accno, r.ids);
      n := n + 1;
    END LOOP;
  END LOOP;
  IF n > 0 THEN
    RAISE EXCEPTION 'NOT INSTALLED. % duplicate account number(s) are still live:%',
      n,
      bad || chr(10) || chr(10)
          || 'Remove or correct the extra row in Setup > Bank Accounts, '
          || 'then run this script again.';
  END IF;
  RAISE NOTICE 'PART 0 ok: no live duplicate account numbers.';
END
$guard$;


-- ---------------------------------------------------------------------- 0b -
-- A fee group with no receipt sequence. After PART 3 a misc collection
-- against such a group is REFUSED rather than numbered out of another
-- group's run, so it must be configured before, not after.
-- ---------------------------------------------------------------------------

DO $guard$
DECLARE r record; bad text := ''; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feegroup'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    FOR r IN EXECUTE format(
      'SELECT %L AS sch, fg.fg_id, fg.fgdesc
         FROM %I.feegroup fg
        WHERE fg.activestatus = 1
          AND NOT EXISTS (SELECT 1 FROM %I.sequence s
                           WHERE s.fg_id = fg.fg_id AND s.activestatus = 1)
        ORDER BY fg.fg_id', r.sch, r.sch, r.sch)
    LOOP
      bad := bad || format('%s  fg_id %s  %s', chr(10), r.fg_id, r.fgdesc)
                 || ' (' || r.sch || ')';
      n := n + 1;
    END LOOP;
  END LOOP;
  IF n > 0 THEN
    RAISE EXCEPTION 'NOT INSTALLED. % fee group(s) have no receipt sequence, '
      'and a misc collection against them would now be REFUSED:%',
      n,
      bad || chr(10) || chr(10)
          || 'Add a sequence for each in Setup > Sequence Master, '
          || 'then run this script again.';
  END IF;
  RAISE NOTICE 'PART 0 ok: every active fee group has a receipt sequence.';
END
$guard$;


-- =================================================================== PART 1 =
-- paymentdetails: index the two columns everything joins it by.
--
-- The table had ONE index, its primary key on pyd_id. Nothing on pay_id,
-- which every receipt query joins through, nor dem_id, which the ledger and
-- demand-wise reports use. A foreign key does not index its own column.
-- ===========================================================================

DO $pd$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'paymentdetails'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS idx_paymentdetails_pay ON %I.paymentdetails (pay_id)',
      r.sch);
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS idx_paymentdetails_dem ON %I.paymentdetails (dem_id)',
      r.sch);
    -- A new index is invisible to the planner until the table is analysed,
    -- so the report stays slow until autovacuum gets round to it otherwise.
    EXECUTE format('ANALYZE %I.paymentdetails', r.sch);
    n := n + 1;
    RAISE NOTICE 'paymentdetails indexed in %', r.sch;
  END LOOP;
  RAISE NOTICE '% schema(s) done', n;
END
$pd$;


-- =================================================================== PART 2 =
-- One live row per bank account number.
--
-- PARTIAL on activestatus = 1 on purpose: a REMOVED account keeps its number
-- (this database has such a row), and btrim so a stray space is not treated
-- as a different account.
-- ===========================================================================

DO $mk$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'bank'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format(
      'CREATE UNIQUE INDEX IF NOT EXISTS bank_accno_live_uniq
         ON %I.bank (btrim(banaccno)) WHERE activestatus = 1', r.sch);
    n := n + 1;
    RAISE NOTICE 'bank_accno_live_uniq ready in %', r.sch;
  END LOOP;
  RAISE NOTICE '% schema(s) done', n;
END
$mk$;


-- =================================================================== PART 3 =
-- Misc receipts come from their own fee group's series.
--
-- The number used to be drawn before the fee group was even resolved, with
-- `ORDER BY seq_id LIMIT 1` -- always COLLEGE FEES. A group with no sequence
-- is now REFUSED rather than numbered from another group's run, which is
-- what PART 0b checks for.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.save_misc_collection(p_ins_id integer, p_header jsonb, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_schema text; v_mc_id bigint; v_total numeric; v_mcno text;
  v_route_fg integer; v_ban_id integer; v_fg_name text;
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
  SELECT COALESCE(SUM((x->>'amount')::numeric), 0) INTO v_total FROM jsonb_array_elements(p_lines) x;
  -- WHICH ACCOUNT THIS RECEIPT BELONGS IN -- the fee group of the fee types
  -- actually collected, resolved server-side rather than trusted from the
  -- client. A misc receipt carrying MESS FEE therefore lands in the hostel
  -- account and a BONAFIDE in the college one, without the cashier choosing.
  -- Mixed groups on one receipt take the FIRST line's group; the receipt is a
  -- single document and cannot sit in two accounts.
  EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft
                   WHERE ft.activestatus = 1
                     AND ft.feedesc = ANY ($1) ORDER BY ft.fg_id LIMIT 1', v_schema)
    INTO v_route_fg
    USING ARRAY(SELECT x->>'feetype' FROM jsonb_array_elements(p_lines) x
                 WHERE COALESCE(TRIM(x->>'feetype'), '') <> '');
  IF v_route_fg IS NULL THEN
    EXECUTE format('SELECT fg_id FROM %I.feegroup
                     WHERE ins_id = $1 AND activestatus = 1
                       AND fgdesc ILIKE ''%%COLLEGE%%'' ORDER BY fg_id LIMIT 1', v_schema)
      INTO v_route_fg USING p_ins_id;
  END IF;
  IF v_route_fg IS NOT NULL THEN
    EXECUTE format('SELECT ban_id FROM %I.feegroup WHERE fg_id = $1', v_schema)
      INTO v_ban_id USING v_route_fg;
  END IF;
  -- RECEIPT NUMBER FROM THIS RECEIPT'S OWN GROUP.
  --
  -- It used to read `ORDER BY seq_id LIMIT 1` -- the first active sequence,
  -- whatever it happened to be -- so EVERY misc receipt was numbered from
  -- COLLEGE FEES. A HOSTEL FEES collection of DOBHI Rs 100 came out as
  -- FC26/03926 while banking correctly into the hostel account: right money,
  -- wrong receipt book, and no way to tell afterwards which series it
  -- belonged to. It was also luck that seq_id 1 was a receipt series at all;
  -- had DEMNO sorted first, a misc receipt would have been numbered DE26/.
  --
  -- Numbered AFTER the group is resolved, not before, because the group is
  -- what decides which series to draw from.
  IF v_route_fg IS NOT NULL THEN
    EXECUTE format('SELECT seq_id, seqcurno, sequid, seqwidth FROM %I.sequence
                     WHERE ins_id=$1 AND activestatus=1 AND fg_id=$2
                     ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_cur, v_sequid, v_width USING p_ins_id, v_route_fg;
    IF v_seq_id IS NULL THEN
      -- REFUSE rather than borrow another group's run. This is the same rule
      -- save_advance_collection follows, and the one the Advance Collection
      -- routing strip already warns about before the cashier takes money.
      EXECUTE format('SELECT fgdesc FROM %I.feegroup WHERE fg_id=$1', v_schema)
        INTO v_fg_name USING v_route_fg;
      RAISE EXCEPTION 'No receipt sequence configured for fee group % - add one in Setup > Sequence Master before collecting against it',
        COALESCE(v_fg_name, v_route_fg::text);
    END IF;
  ELSE
    -- No group at all (a fee type in no group, and no COLLEGE group to fall
    -- back to). Nothing better to go on, so the old behaviour stands -- but
    -- fg_id IS NOT NULL keeps it off DEMNO and TCNO, which are not receipt
    -- series and were only ever excluded by luck of ordering.
    EXECUTE format('SELECT seq_id, seqcurno, sequid, seqwidth FROM %I.sequence
                     WHERE ins_id=$1 AND activestatus=1 AND fg_id IS NOT NULL
                     ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_cur, v_sequid, v_width USING p_ins_id;
    IF v_seq_id IS NULL THEN RAISE EXCEPTION 'No receipt sequence configured'; END IF;
  END IF;
  v_cur    := COALESCE(v_cur, 0) + 1;
  v_prefix := regexp_replace(COALESCE(v_sequid, ''), '\d+$', '');
  v_mcno   := v_prefix || lpad(v_cur::bigint::text, COALESCE(v_width, 5)::int, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_cur, v_seq_id;
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
          COALESCE(NULLIF(p_header->>'paymode',''), 'Cash'), v_ban_id,
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
$function$;


-- =================================================================== PART 4 =
-- Only a cash receipt may be cancelled.
--
-- One rule function, called by all three void_* functions, so they cannot
-- drift apart. recon_status is not consulted: it records whether a credit
-- has been MATCHED on a statement, not whether the money arrived.
--
-- Each void_* is patched in its OWN DO block. A single block for all three
-- means a failure on the last silently rolls back the first two while their
-- NOTICEs still claim success.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.receipt_cancel_block_reason(
  p_paymethod text, p_recon_status text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  -- CASH IS THE ONLY CANCELLABLE MODE. Everything else -- cheque, DD, UPI,
  -- NEFT, online transfer, challan, card, an advance adjustment, or a mode
  -- nobody recorded -- is refused.
  --
  -- The test is deliberately "is it cash", not "is it one of these other
  -- things". A spelling nobody anticipated then fails CLOSED: it is refused
  -- and someone asks why, instead of slipping through a list that did not
  -- happen to name it.
  --
  -- recon_status is not consulted at all. It records whether the credit has
  -- been MATCHED on a statement, not whether the money arrived.
  SELECT CASE
    WHEN LOWER(COALESCE(btrim(p_paymethod), '')) = 'cash' THEN NULL
    WHEN LOWER(COALESCE(btrim(p_paymethod), '')) = 'advance adjustment' THEN
      'This receipt was settled from an advance. Reverse it from Advance '
      'Adjustment so the advance goes back to the student -- cancelling here '
      'would void the receipt without returning it.'
    ELSE
      'Only a cash receipt can be cancelled. This one was paid by '
      || COALESCE(NULLIF(btrim(p_paymethod), ''), 'another mode')
      || ' -- return it through Fee Refund, which records where the money '
      || 'went. Cancelling would erase the receipt and leave the payment '
      || 'unexplained.'
  END;
$fn$;

GRANT EXECUTE ON FUNCTION public.receipt_cancel_block_reason(text, text)
  TO anon, authenticated;


DO $vr$
DECLARE src text;
  oldg CONSTANT text := 'IF p.recon_status = ''R'' AND NOT v_is_cash AND NOT v_no_bank_leg THEN';
  newg CONSTANT text := 'IF public.receipt_cancel_block_reason(p.paymethod, p.recon_status) IS NOT NULL THEN';
  oldr CONSTANT text := 'RAISE EXCEPTION ''Receipt % is reconciled with the bank and cannot be deleted'', p.paynumber';
  newr CONSTANT text := 'RAISE EXCEPTION ''%'', public.receipt_cancel_block_reason(p.paymethod, p.recon_status)';
BEGIN
  SELECT pg_get_functiondef(pr.oid) INTO src
    FROM pg_proc pr JOIN pg_namespace ns ON ns.oid = pr.pronamespace
   WHERE ns.nspname = 'public' AND pr.proname = 'void_receipt';
  IF src IS NULL THEN RAISE NOTICE 'void_receipt does not exist'; RETURN; END IF;
  IF src LIKE '%receipt_cancel_block_reason%' THEN
    RAISE NOTICE 'void_receipt already patched'; RETURN;
  END IF;
  IF position(oldg in src) = 0 THEN
    RAISE EXCEPTION 'void_receipt does not carry the expected guard -- NOT patched. '
      'Its definition has changed since this migration was written.';
  END IF;
  src := replace(src, oldg, newg);
  IF position(oldr in src) > 0 THEN src := replace(src, oldr, newr); END IF;
  EXECUTE src;
  RAISE NOTICE 'patched public.void_receipt';
END
$vr$;

DO $vm$
DECLARE src text;
  oldg CONSTANT text := 'IF rec.recon_status = ''R'' AND NOT v_is_cash THEN';
  newg CONSTANT text := 'IF public.receipt_cancel_block_reason(rec.paymode, rec.recon_status) IS NOT NULL THEN';
  oldr CONSTANT text := 'RAISE EXCEPTION ''Receipt % is reconciled with the bank and cannot be cancelled'', rec.mcno';
  newr CONSTANT text := 'RAISE EXCEPTION ''%'', public.receipt_cancel_block_reason(rec.paymode, rec.recon_status)';
BEGIN
  SELECT pg_get_functiondef(pr.oid) INTO src
    FROM pg_proc pr JOIN pg_namespace ns ON ns.oid = pr.pronamespace
   WHERE ns.nspname = 'public' AND pr.proname = 'void_misc_receipt';
  IF src IS NULL THEN RAISE NOTICE 'void_misc_receipt does not exist'; RETURN; END IF;
  IF src LIKE '%receipt_cancel_block_reason%' THEN
    RAISE NOTICE 'void_misc_receipt already patched'; RETURN;
  END IF;
  IF position(oldg in src) = 0 THEN
    RAISE EXCEPTION 'void_misc_receipt does not carry the expected guard -- NOT patched. '
      'Its definition has changed since this migration was written.';
  END IF;
  src := replace(src, oldg, newg);
  IF position(oldr in src) > 0 THEN src := replace(src, oldr, newr); END IF;
  EXECUTE src;
  RAISE NOTICE 'patched public.void_misc_receipt';
END
$vm$;

DO $va$
DECLARE src text;
  oldg CONSTANT text := 'IF v_adv.recon_status = ''R'' AND NOT v_is_cash THEN';
  newg CONSTANT text := 'IF public.receipt_cancel_block_reason(v_adv.paymethod, v_adv.recon_status) IS NOT NULL THEN';
  oldr CONSTANT text := 'RAISE EXCEPTION ''Advance % is reconciled with the bank and cannot be cancelled'',
      v_adv.advno USING ERRCODE = ''P0001'';';
  newr CONSTANT text := 'RAISE EXCEPTION ''%'', public.receipt_cancel_block_reason(v_adv.paymethod, v_adv.recon_status) USING ERRCODE = ''P0001'';';
BEGIN
  SELECT pg_get_functiondef(pr.oid) INTO src
    FROM pg_proc pr JOIN pg_namespace ns ON ns.oid = pr.pronamespace
   WHERE ns.nspname = 'public' AND pr.proname = 'void_advance_receipt';
  IF src IS NULL THEN RAISE NOTICE 'void_advance_receipt does not exist'; RETURN; END IF;
  IF src LIKE '%receipt_cancel_block_reason%' THEN
    RAISE NOTICE 'void_advance_receipt already patched'; RETURN;
  END IF;
  IF position(oldg in src) = 0 THEN
    RAISE EXCEPTION 'void_advance_receipt does not carry the expected guard -- NOT patched. '
      'Its definition has changed since this migration was written.';
  END IF;
  src := replace(src, oldg, newg);
  IF position(oldr in src) > 0 THEN src := replace(src, oldr, newr); END IF;
  EXECUTE src;
  RAISE NOTICE 'patched public.void_advance_receipt';
END
$va$;


-- =================================================================== PART 5 =
-- HOSTELLERS ONLY fee groups.
--
-- 5a the column, on every existing schema, ticked on HOSTEL FEES and MA.
--    It ticks nothing if those groups do not exist yet -- create them in
--    Setup > Fee Master > Fee Group and tick them there.
-- ===========================================================================

DO $do$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feegroup'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.feegroup
         ADD COLUMN IF NOT EXISTS hostellers_only boolean NOT NULL DEFAULT false',
      r.sch);
    n := n + 1;
    RAISE NOTICE 'feegroup.hostellers_only ready in %', r.sch;
  END LOOP;
  RAISE NOTICE '% schema(s) updated', n;
END
$do$;

DO $seed$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.columns
     WHERE table_name = 'feegroup' AND column_name = 'hostellers_only'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
  LOOP
    EXECUTE format(
      'UPDATE %I.feegroup SET hostellers_only = true
        WHERE hostellers_only = false
          AND (upper(fgdesc) LIKE ''%%HOSTEL%%'' OR upper(btrim(fgdesc)) = ''MA'')',
      r.sch);
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN RAISE NOTICE 'ticked % group(s) in %', n, r.sch; END IF;
  END LOOP;
END
$seed$;


-- ---------------------------------------------------------------------- 5b -
-- generate_feedemand_for_class -- the RPC the master import calls -- stops
-- billing a hostel-only fee to day scholars. The Class Fee Demand SCREEN
-- enforces the same rule in Dart; this is the other path.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.generate_feedemand_for_class(
  p_ins_id integer, p_class text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '120s'
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
      -- A pre-admission student has paid to hold a seat for NEXT year and is
      -- not studying this one, so this year's fees are not theirs to owe.
      -- They pick the new year's demands up after the rollover, by which time
      -- the flag is cleared.
      AND COALESCE(s.preadmission, 0) = 0
      AND s.stuclass = $1
      AND cf.cfamount IS NOT NULL
      AND (cf.cfdduedate IS NULL OR cf.cfdduedate >= s.stuadmdate)
      AND (cf.admissiontype IS NULL OR cf.admissiontype = a.adm_id)
      -- HOSTELLERS ONLY. Raise the fee when the student IS a hosteller, or no
      -- group it belongs to is ticked, or at least one of its groups is open.
      -- cf.fee_id identifies the exact feetype row when the trigger resolved
      -- it; older template rows have it NULL and are matched by name.
      AND (
            COALESCE(UPPER(TRIM(s.hostel)), 'N') = 'Y'
            OR NOT EXISTS (
                 SELECT 1 FROM %1$I.feetype ft
                   JOIN %1$I.feegroup fg ON fg.fg_id = ft.fg_id
                  WHERE ft.activestatus = 1
                    AND (CASE WHEN cf.fee_id IS NOT NULL THEN ft.fee_id = cf.fee_id
                              ELSE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(cf.cffeetype)) END)
                    AND fg.hostellers_only)
            OR EXISTS (
                 SELECT 1 FROM %1$I.feetype ft
                   JOIN %1$I.feegroup fg ON fg.fg_id = ft.fg_id
                  WHERE ft.activestatus = 1
                    AND (CASE WHEN cf.fee_id IS NOT NULL THEN ft.fee_id = cf.fee_id
                              ELSE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(cf.cffeetype)) END)
                    AND NOT fg.hostellers_only)
          )
      AND NOT EXISTS (SELECT 1 FROM %1$I.tempfeedemand t
            WHERE t.stu_id = s.stu_id AND t.demfeeterm = cf.cfterm
              AND t.demfeetype = cf.cffeetype AND t.activestatus = 1)
      AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd
            WHERE fd.stu_id = s.stu_id AND fd.demfeeterm = cf.cfterm
              AND fd.demfeetype = cf.cffeetype AND fd.activestatus = 1)
  $q$, v_schema) USING p_class;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
GRANT EXECUTE ON FUNCTION public.generate_feedemand_for_class(integer, text) TO anon, authenticated;


-- ---------------------------------------------------------------------- 5c -
-- create_institution_schema, so the NEXT institution-year is born with
-- hostellers_only, the paymentdetails indexes and the bank unique index.
-- CREATE OR REPLACE only: no existing schema or row is touched.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_institution_schema(p_schema_name text, p_ins_id integer DEFAULT NULL::integer, p_year_label text DEFAULT NULL::text, p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$

DECLARE v_schema text := lower(p_schema_name); v_inscode varchar(10);

BEGIN

  -- Get inscode for year record

  IF p_ins_id IS NOT NULL THEN

    SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = p_ins_id;

  END IF;

  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);



  -- year

  EXECUTE format('CREATE TABLE %I.year (yr_id integer NOT NULL PRIMARY KEY, ins_id integer NOT NULL, yrlabel varchar(9) NOT NULL, yrstadate date NOT NULL, yrenddate date NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- students

  -- students — `aadharno + community/caste/religion/nationality/transportmode/hostel`

  -- columns are carried over from public.admission during class allocation.

  EXECUTE format('CREATE TABLE %I.students (stu_id bigint NOT NULL PRIMARY KEY CHECK (stu_id > 0), ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, stuadmno varchar(25) NOT NULL, stuadmdate date NOT NULL, stuname varchar(50) NOT NULL, stugender char(1) NOT NULL CHECK (stugender = ANY(ARRAY[''M'',''F'',''T''])), studob date NOT NULL, stumobile varchar(30), stuemail varchar(254), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stugeocoordinates varchar(40), stubloodgrp varchar(20), stuphoto text, stuclass varchar(20) NOT NULL, cour_id integer, admit_cour_id smallint, courname varchar(20), con_id integer, stucondesc varchar(20), stuser_id varchar(25) NOT NULL, stupassword varchar(255), stumobotp numeric(6,0), stuotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now() NOT NULL, suspendeddate date, suspendedby varchar(50), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,3,4,5,9])), createdon timestamp DEFAULT now() NOT NULL, terminatedreason text, batch varchar(9), preadmission smallint DEFAULT 0 NOT NULL CHECK (preadmission = ANY(ARRAY[0,1])), admname varchar(30), quoname varchar(30), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), emisno varchar(30), umisno varchar(30), scholarship char(1), scholarshiptype varchar(60), medium varchar(30), cla_id smallint, adm_id smallint, quo_id smallint)', v_schema);

  -- No UNIQUE on stuemail: students commonly share or lack an email (bulk import

  -- of hundreds would fail on the first shared/placeholder address).

  EXECUTE format('ALTER TABLE %I.students ADD CONSTRAINT uq_students_admission UNIQUE (ins_id, stuadmno)', v_schema);



  -- parents

  EXECUTE format('CREATE TABLE %I.parents (par_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), partype char(1) NOT NULL CHECK (partype = ANY(ARRAY[''P'',''G''])), paremail varchar(254), fathername varchar(50), mothername varchar(50), guardianname varchar(50), fathermobile varchar(20), mothermobile varchar(20), guardianmobile varchar(20), fatheroccupation varchar(60), motheroccupation varchar(60), guardianoccupation varchar(60), payincharge varchar(50) NOT NULL, payinchargemob varchar(20) NOT NULL, parpassword varchar(255), parmobotp numeric(6,0), parmobotp_at timestamp, parotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now(), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,9])), ins_id integer)', v_schema);

  -- No UNIQUE on paremail: parents commonly share an email (siblings / one family

  -- email), so a bulk student import would fail on the first shared address.



  -- parentdetail

  EXECUTE format('CREATE TABLE %I.parentdetail (pd_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), par_id bigint NOT NULL, stu_id bigint NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, stuadmno varchar(20) NOT NULL UNIQUE, stuname varchar(50) NOT NULL, stuclass varchar(20) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- feedemand — `collectible=false` rows are recorded but never shown for

  -- collection; carried through from the classfeedemand template.

  EXECUTE format('CREATE TABLE %I.feedemand (dem_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, demseqtype varchar(20) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, paidamount numeric(12,2) DEFAULT 0, fineamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) CHECK (balancedue >= 0), reconbalancedue numeric(12,2) DEFAULT 0, duedate date NOT NULL, pay_id integer, paidstatus char(1) DEFAULT ''U'' NOT NULL CHECK (paidstatus = ANY(ARRAY[''P'',''U''])), createdby varchar(50) NOT NULL, createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])), inactivedate timestamp, remarks varchar(50), fee_id integer, courname varchar(20), collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, cf_id integer, arrearclass varchar(30))', v_schema);



  -- tempfeedemand (staging — copied into feedemand by fn_approve_tempfeedemand on approval)

  EXECUTE format('CREATE TABLE %I.tempfeedemand (temp_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, courname varchar(20), demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2), duedate date NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), isapproved boolean DEFAULT false, collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, fee_id integer, cf_id integer, demseqtype varchar(20), arrearclass varchar(30))', v_schema);



  -- Demand generation + approval performance indexes. The dedup NOT EXISTS

  -- checks (generate_feedemand_from_template / _for_class) and the approval

  -- trigger's per-row feedemand lookup would otherwise sequential-scan and grow

  -- O(N^2) as feedemand fills, timing out on bulk generate/approve.

  EXECUTE format('CREATE INDEX idx_feedemand_dedup ON %I.feedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);

  EXECUTE format('CREATE INDEX idx_tempfeedemand_dedup ON %I.tempfeedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);

  EXECUTE format('CREATE INDEX idx_feedemand_demno_type ON %I.feedemand (ins_id, demno, demfeetype) WHERE activestatus = 1', v_schema);



  -- Approval trigger: copy temp → feedemand carrying the collectible flag.

  EXECUTE format('CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_dem_id bigint; v_paid numeric; v_net numeric; BEGIN IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid FROM %1$I.feedemand WHERE ins_id = NEW.ins_id AND NEW.demno IS NOT NULL AND btrim(NEW.demno) <> '''' AND demno IS NOT DISTINCT FROM NEW.demno AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype AND activestatus = 1 ORDER BY dem_id LIMIT 1; IF v_dem_id IS NOT NULL THEN v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0); UPDATE %1$I.feedemand SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount, balancedue = v_net, reconbalancedue = v_net, paidstatus = CASE WHEN v_net <= 0 THEN ''P'' ELSE ''U'' END, duedate = NEW.duedate, collectible = COALESCE(NEW.collectible, collectible), cla_id = NEW.cla_id, sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id, demseqtype = COALESCE(NEW.demseqtype, demseqtype), arrearclass = NEW.arrearclass WHERE dem_id = v_dem_id; ELSE INSERT INTO %1$I.feedemand (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue, duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible, cla_id, sem_id, fee_id, cf_id, arrearclass) VALUES (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass, NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id, NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1, NEW.createdat, NEW.createdby, ''U'', 0, COALESCE(NEW.collectible, true), NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass); END IF; NEW.activestatus := 9; END IF; RETURN NEW; END; $t$', v_schema);

  EXECUTE format('CREATE TRIGGER trg_tempfeedemand_approve BEFORE UPDATE OF isapproved ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.fn_approve_tempfeedemand()', v_schema, v_schema);



  -- feegroup

  EXECUTE format('CREATE TABLE %I.feegroup (fg_id integer NOT NULL PRIMARY KEY, fgdesc varchar(30) NOT NULL, ban_id integer, ins_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, hostellers_only boolean DEFAULT false NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);



  -- feetype (feefineapplicable: 1 = fines apply when overdue, 0 = no fine)

  EXECUTE format('CREATE TABLE %I.feetype (fee_id integer NOT NULL PRIMARY KEY, feedesc varchar(30) NOT NULL, feeshort varchar(10) NOT NULL, feefineapplicable smallint DEFAULT 0, fg_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])), ins_id integer, type varchar(20), payseq smallint DEFAULT 100, partialallowed char(1) DEFAULT ''Y'')', v_schema);

  -- (feegroup_accountant removed — unused scaffold; no app or DB references.)

  EXECUTE format('ALTER TABLE %I.feetype ADD CONSTRAINT fk_feetype_feegroup FOREIGN KEY (fg_id) REFERENCES %I.feegroup(fg_id)', v_schema, v_schema);

  -- Lets PostgREST resolve embedded selects like feedemand?select=*,feetype(*) in the mobile app.

  EXECUTE format('ALTER TABLE %I.feedemand ADD CONSTRAINT fk_feedemand_feetype FOREIGN KEY (fee_id) REFERENCES %I.feetype(fee_id) NOT VALID', v_schema, v_schema);



  -- concessioncategory

  EXECUTE format('CREATE TABLE %I.concessioncategory (con_id integer NOT NULL PRIMARY KEY, condesc varchar(20) NOT NULL, ins_id integer NOT NULL, ordid integer, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])))', v_schema);



  -- course

  EXECUTE format('CREATE TABLE %I.course (cour_id integer NOT NULL PRIMARY KEY, courname varchar(100) NOT NULL, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- class

  EXECUTE format('CREATE TABLE %I.class (cla_id integer NOT NULL PRIMARY KEY, claname varchar(20) NOT NULL, ins_id integer, ordid smallint, succeedingclass integer, cour_id integer, activestatus smallint DEFAULT 1 NOT NULL, classtype varchar(12) DEFAULT ''PROMOTIONAL'' NOT NULL CHECK (classtype = ANY(ARRAY[''PROMOTIONAL'',''TERMINAL'',''COMPLETED''])))', v_schema);

  -- succeedingclass is the cla_id of the next class in the promotion ladder

  -- (NULL for the terminal class). cour_id is optional / informational.



  -- admissiontype + quota + community + division + semester master lookups.

  -- (Register-number sequencing lives in the shared `sequence` table below,

  --  actname = 'REGNO' — not a separate regnoseq table anymore.)

  EXECUTE format('CREATE TABLE %I.admissiontype (adm_id smallint PRIMARY KEY, admname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  EXECUTE format('CREATE TABLE %I.quota (quo_id smallint PRIMARY KEY, quoname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  -- Community master (lookup for the admission form).

  EXECUTE format('CREATE TABLE %I.community (com_id smallint PRIMARY KEY, comname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  EXECUTE format('CREATE TABLE %I.division (div_id smallint PRIMARY KEY, divname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  -- (Register-number sequencing now lives in the shared `sequence` table below,

  --  actname = 'REGNO' — the separate regnoseq table has been retired.)

  -- Semester master (drives the demfeeterm dropdown in Fee Demand / Class Fee Demand).

  EXECUTE format('CREATE TABLE %I.semester (sem_id smallint PRIMARY KEY, semname varchar(30) NOT NULL, semshort varchar(10), semtype char(1) NOT NULL DEFAULT ''S'' CHECK (semtype IN (''S'',''M'',''Y'')), semstart date, semend date, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);



  -- classfeedemand — `collectible` carries the "ALL" tick from the template into

  -- each generated tempfeedemand/feedemand row.

  EXECUTE format('CREATE TABLE %I.classfeedemand (cf_id integer NOT NULL PRIMARY KEY, cfclass varchar(20), cfterm varchar(20), cffeetype varchar(30), cfamount numeric(12,2), cfdduedate date, admissiontype smallint, collectible boolean DEFAULT false NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, cla_id smallint, sem_id smallint, fee_id integer)', v_schema);



  -- NOTE: on-admission (per-student-insert) fee-demand auto-generation was

  -- reverted. There is deliberately no fn_gen_feedemand_on_student function or

  -- trg_gen_feedemand_on_student trigger here. Adding a student does NOT create

  -- demands. Generate them explicitly via generate_feedemand_for_class /

  -- generate_feedemand_from_template (or the Fee Demand screen).



  -- finerule (overdue fine slabs configured by admin)

  EXECUTE format('CREATE TABLE %I.finerule (fr_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, rulename varchar(50) NOT NULL, feetype varchar(30) DEFAULT ''ALL'', from_days integer NOT NULL, to_days integer, fine_type varchar(10) DEFAULT ''FIXED'' CHECK (fine_type IN (''FIXED'',''PERCENT'')), fine_value numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);





  -- payment

  EXECUTE format('CREATE TABLE %I.payment (pay_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), transtotalamount numeric(12,2) NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paydate timestamp, paystatus char(1) CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), paygwresponse numeric(15,0), payitems text, createdby varchar(100), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, paynumber varchar(30) UNIQUE, payorderid varchar(100), notification_read boolean DEFAULT false, paychequeno varchar(50), paychequedate date, paybankname varchar(100), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, ban_id integer, tender_amount numeric(12,2), refund_amount numeric(12,2), voidedby varchar(100), voideddate timestamp, voidreason varchar(255))', v_schema);



  -- bank: per-institution beneficiary account list. Fee groups are

  -- tagged with ban_id so a single payment can be split (mock for now —

  -- real splits later via Razorpay Route or virtual accounts).

  EXECUTE format('CREATE TABLE %I.bank (ban_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer, banname varchar(45) NOT NULL, banbranch varchar(80) NOT NULL, ifsccode varchar(15) NOT NULL, banaddress1 varchar(50) NOT NULL, banaddress2 varchar(50), banaddress3 varchar(50), banmobile varchar(15), banemail varchar(60), banaccno varchar(20) NOT NULL, banaccholder varchar(50) NOT NULL, paytm_mid varchar(40), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);

  -- One live row per account number. Two rows for one real account can be
  -- routed to different fee groups and carry different paytm_mid values,
  -- settling the same account's money two ways while the bank statement
  -- shows one account. Partial on activestatus=1 so a REMOVED account keeps
  -- its number; btrim so a stray space is not a different account.
  EXECUTE format('CREATE UNIQUE INDEX bank_accno_live_uniq ON %I.bank (btrim(banaccno)) WHERE activestatus = 1', v_schema);
  EXECUTE format('ALTER TABLE %I.feegroup ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_feegroup_bank', v_schema);

  EXECUTE format('ALTER TABLE %I.payment ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_payment_bank', v_schema);



  -- paymentdetails

  EXECUTE format('CREATE TABLE %I.paymentdetails (pyd_id bigint NOT NULL PRIMARY KEY, pay_id bigint NOT NULL, dem_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), ins_id integer NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- paymentdetails is joined by pay_id (every receipt query) and dem_id (the
  -- ledger and demand-wise reports). A foreign key does NOT index its own
  -- column, so without these the Daily Collection report re-scans the whole
  -- table per pass -- 3.2s against anon's 3s statement_timeout, which reads
  -- in the UI as "No collections in this range". See
  -- migrations/shared/PAYMENTDETAILS_INDEXES.sql.
  EXECUTE format('CREATE INDEX idx_paymentdetails_pay ON %I.paymentdetails (pay_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_paymentdetails_dem ON %I.paymentdetails (dem_id)', v_schema);

  -- paymentgateway

  EXECUTE format('CREATE TABLE %I.paymentgateway (gw_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, gwname varchar(100) NOT NULL, gwapikey varchar(255), gwapisecret varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- interim_promotion (mid-year move of a single student to another class;

  -- keeps the before/after course+class for audit)

  EXECUTE format('CREATE TABLE %I.interim_promotion (ip_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no integer NOT NULL, ins_id integer NOT NULL, promotiondate date NOT NULL, stu_id bigint, stuadmno varchar(25), stuname varchar(50), courname varchar(20), stuclass varchar(20), admname varchar(30), transferred_courname varchar(20), transferred_class varchar(20), transferred_admname varchar(30), remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE INDEX idx_interim_promotion_stu ON %I.interim_promotion (ins_id, stu_id)', v_schema);



  -- fee_refund (refund voucher header; one row per refund raised against a receipt/payment)

  EXECUTE format('CREATE TABLE %I.fee_refund (rf_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), refunddate date NOT NULL, pay_id bigint, paynumber varchar(30), stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), refundmode varchar(20) NOT NULL, ban_id integer, bankname varchar(100), bankref varchar(100), chequedate date, accountcode varchar(50), refundreason varchar(200), totalrefund numeric(12,2) DEFAULT 0, totaladjust numeric(12,2) DEFAULT 0, createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- fee_refunddetails (per fee-line breakdown of a refund voucher; dem_id references this schema''s feedemand by value)

  EXECUTE format('CREATE TABLE %I.fee_refunddetails (rfd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, rf_id bigint NOT NULL, dem_id bigint, ins_id integer NOT NULL, refundterm varchar(20), refundfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, refundamount numeric(12,2) DEFAULT 0, adjustamount numeric(12,2) DEFAULT 0, adjustreason varchar(200), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- concession (concession voucher header; one row per concession applied to a student) + concessiondetail (per fee-line breakdown). Written only via process_concession(). See migrations/add_concession_tables.sql.

  EXECUTE format('CREATE TABLE %I.concession (con_hdr_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30), ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), condate date NOT NULL DEFAULT CURRENT_DATE, stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), con_id integer, contype varchar(30), totalfee numeric(12,2) DEFAULT 0, totalconcession numeric(12,2) DEFAULT 0, totalbalance numeric(12,2) DEFAULT 0, remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE TABLE %I.concessiondetail (cond_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, con_hdr_id bigint NOT NULL, ins_id integer NOT NULL, stu_id bigint, stuadmno varchar(25), receiptno varchar(30), dem_id bigint, demfeeterm varchar(20), demfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) DEFAULT 0, con_id integer, contype varchar(30), condate date, createdby varchar(50), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE INDEX idx_concession_stu ON %I.concession (ins_id, stu_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_concessiondetail_hdr ON %I.concessiondetail (con_hdr_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_concessiondetail_stu ON %I.concessiondetail (ins_id, stu_id)', v_schema);



  -- misc_collection (standalone counter collection: BONAFIDE, APPLICATION, …).

  -- Does NOT touch feedemand. selection ''S'' = registered student, ''O'' = others.

  -- Receipt number (mcno) is drawn from the shared fee-receipt sequence.

  EXECUTE format('CREATE TABLE %I.misc_collection (mc_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), mcno varchar(30) NOT NULL, mcdate date NOT NULL DEFAULT CURRENT_DATE, selection char(1) NOT NULL DEFAULT ''S'' CHECK (selection IN (''S'',''O'')), stu_id bigint, regno varchar(25), stuclass varchar(30), stuname varchar(100) NOT NULL, courname varchar(20), city varchar(50), address varchar(255), paymode varchar(20) DEFAULT ''Cash'', ban_id integer, bankname varchar(100), transrefno varchar(50), paytm_txnid varchar(60), draweebank varchar(100), transdate date, transamt numeric(12,2), collectedby varchar(50), remarks varchar(255), totalamount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamptz, bank_reference varchar(100), bank_date date, paystatus char(1) DEFAULT ''C'', voidedby varchar(100), voideddate timestamptz, voidreason varchar(255))', v_schema);

  EXECUTE format('CREATE TABLE %I.misc_collection_detail (mcd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, mc_id bigint NOT NULL, ins_id integer NOT NULL, fee_id integer, feetype varchar(30) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE INDEX idx_misc_detail_mc ON %I.misc_collection_detail (mc_id)', v_schema);



  -- A misc receipt number must be unique per institution, the way advance has

  -- uq_advance_advno and payment.paynumber has its own UNIQUE. Without it two

  -- cashiers saving in the same instant could draw the same FC number and

  -- nothing would refuse the second -- the race PART E closed on the existing

  -- schemas. Partial on activestatus=1 so a voided receipt cannot block it.

  EXECUTE format('CREATE UNIQUE INDEX misc_collection_mcno_uniq ON %I.misc_collection (ins_id, mcno) WHERE activestatus = 1', v_schema);



  -- advance_collection (money taken BEFORE any fee is due). Mirrors `payment`'s

  -- money/reconcile columns but carries NO fg_id / fee_id -- an advance is just

  -- an amount held against the student. It is later applied to specific fee

  -- demands ("adjusted"), which advadjustment records. Receipt number (advno)

  -- comes from the schema's own sequence, actname='ADVNO' (Fee Master ->

  -- Advance No). balanceamount is GENERATED, so it can never drift from its

  -- parts. See migrations/add_advance_collection.sql.

  EXECUTE format('CREATE TABLE %I.advance_collection (adv_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id bigint NOT NULL, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), yr_id integer, yrlabel varchar(20), advno varchar(30) NOT NULL, advdate timestamp DEFAULT now() NOT NULL, advtype char(1) DEFAULT ''S'' NOT NULL CONSTRAINT chk_advance_advtype CHECK (advtype = ANY(ARRAY[''A'',''S'',''M''])), transtotalamount numeric(12,2) NOT NULL CHECK (transtotalamount > 0), adjustedamount numeric(12,2) DEFAULT 0 NOT NULL, refund_amount numeric(12,2) DEFAULT 0 NOT NULL, balanceamount numeric(12,2) GENERATED ALWAYS AS (transtotalamount - adjustedamount - refund_amount) STORED, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paystatus char(1) DEFAULT ''C'' NOT NULL CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), payorderid varchar(100), paytm_txnid varchar(60), paychequeno varchar(50), paychequedate date, paybankname varchar(100), ban_id integer, recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, tender_amount numeric(12,2), remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, voidedby varchar(100), voideddate timestamp, voidreason varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE UNIQUE INDEX uq_advance_advno ON %I.advance_collection (ins_id, advno)', v_schema);

  EXECUTE format('CREATE INDEX idx_advance_stu ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1', v_schema);

  -- Drives "students with an unused advance" (the Fee Collection highlight).

  EXECUTE format('CREATE INDEX idx_advance_open ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1 AND balanceamount > 0', v_schema);



  -- advance_detail: the fee-type breakdown of an ADMISSION advance

  -- (advtype ''A''). Mirrors misc_collection_detail. A student advance

  -- (advtype ''S'') is a plain amount and has no rows here at all.

  -- feetype is varchar(60), not misc''s 30: real fee names run long.

  EXECUTE format('CREATE TABLE %I.advance_detail (advd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, fee_id integer, fg_id integer, feetype varchar(60) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);

  EXECUTE format('CREATE INDEX idx_advance_detail_adv ON %I.advance_detail (adv_id)', v_schema);



  -- advadjustment: one row per amount moved off an advance onto a fee demand,

  -- with the fee receipt that settlement raised.

  EXECUTE format('CREATE TABLE %I.advadjustment (adj_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, stu_id bigint, dem_id bigint, pay_id bigint, paynumber varchar(30), demfeeterm varchar(20), demfeetype varchar(30), adjustamount numeric(12,2) NOT NULL CHECK (adjustamount > 0), adjustdate date DEFAULT CURRENT_DATE NOT NULL, remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);

  EXECUTE format('CREATE INDEX idx_advadjustment_adv ON %I.advadjustment (adv_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_advadjustment_dem ON %I.advadjustment (ins_id, dem_id)', v_schema);



  -- sequence: unified numbering for BOTH fee-receipt sequences (fg_id set,

  -- actname = fee-group name) AND admission/register-number sequences

  -- (fg_id NULL, actname = 'REGNO'; the seqend + division columns apply only to

  -- register sequences). Register numbers replace the old separate regnoseq table.

  EXECUTE format('CREATE TABLE %I.sequence (seq_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, mod_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, actname varchar(30) NOT NULL, seqname varchar(50) NOT NULL, isprefix char(1) NOT NULL, seqprefix varchar(15) NOT NULL, seqstart numeric(9,0) NOT NULL, seqwidth numeric(2,0) NOT NULL, sequid varchar(18) NOT NULL, seqcurno numeric(9,0) NOT NULL, seqend numeric(9,0), division varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, fg_id integer)', v_schema);



  -- shoppingcart

  EXECUTE format('CREATE TABLE %I.shoppingcart (car_id integer NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, stu_id bigint NOT NULL, transtype varchar(10) NOT NULL, transdate date DEFAULT CURRENT_DATE NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, carinitiated char(1) DEFAULT ''N'' NOT NULL, createdby varchar(50) NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE UNIQUE INDEX unique_active_cart_per_student ON %I.shoppingcart (stu_id) WHERE activestatus = 1', v_schema);



  -- shoppingcartdetails

  EXECUTE format('CREATE TABLE %I.shoppingcartdetails (cd_id integer NOT NULL PRIMARY KEY, car_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, dem_id bigint NOT NULL, transdetail_id integer, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);



  -- notice

  EXECUTE format('CREATE TABLE %I.notice (notice_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, noticetitle text NOT NULL, noticedesc text, noticepriority varchar(20) DEFAULT ''Normal'', noticecategory varchar(50) DEFAULT ''General'', noticetarget text, createdby varchar(50), createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1, noticefromdate date, noticetodate date)', v_schema);

  EXECUTE format('CREATE INDEX idx_notice_ins_id ON %I.notice (ins_id)', v_schema);



  -- notification

  EXECUTE format('CREATE TABLE %I.notification (noti_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, stu_id integer, notice_id bigint, notititle text, notibody text, notitype varchar(50), isread integer DEFAULT 0, createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1)', v_schema);

  EXECUTE format('CREATE INDEX idx_notification_notice_id ON %I.notification(notice_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_notification_ins_id ON %I.notification (ins_id)', v_schema);

  EXECUTE format('CREATE INDEX idx_notification_stu_id ON %I.notification (stu_id)', v_schema);



  -- userlogin

  EXECUTE format('CREATE TABLE %I.userlogin (ul_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), uluser varchar(50), ulusetype smallint, ultime timestamp, ulattempt smallint DEFAULT 0, ulip varchar(40), ullocation varchar(50), ulsuccess char(1) DEFAULT ''N'' NOT NULL, ulsesid numeric, ulsesstart timestamp DEFAULT now() NOT NULL, ulsesend timestamp, ulsestime timestamp)', v_schema);





  -- student_import

  EXECUTE format('CREATE TABLE %I.student_import (imp_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), stuadmno varchar(25) NOT NULL, stuname varchar(50) NOT NULL, stugender char(1), studob date, stuadmdate date, stuclass varchar(20) NOT NULL, courname varchar(20), stumobile varchar(30), stuemail varchar(254), concession varchar(50), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stubloodgrp varchar(20), fathername varchar(50), fathermobile varchar(30), fatheroccupation varchar(50), mothername varchar(50), mothermobile varchar(30), motheroccupation varchar(50), guardianname varchar(50), guardianmobile varchar(30), guardianoccupation varchar(50), payincharge varchar(50), payinchargemob varchar(30), admname varchar(50), quoname varchar(50), batch varchar(9), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), paremail varchar(254), cla_id smallint, cour_id integer, admit_cour_id smallint, medium varchar(30), adm_id smallint, quo_id smallint, status varchar(10) DEFAULT ''PENDING'', error_msg text, created_at timestamp DEFAULT now())', v_schema);



  -- FOREIGN KEYS

  EXECUTE format('ALTER TABLE %I.paymentdetails ADD CONSTRAINT fk_paymentdetails_payment FOREIGN KEY (pay_id) REFERENCES %I.payment(pay_id)', v_schema, v_schema);

  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_car_id_fkey FOREIGN KEY (car_id) REFERENCES %I.shoppingcart(car_id)', v_schema, v_schema);

  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_dem_id_fkey FOREIGN KEY (dem_id) REFERENCES %I.feedemand(dem_id)', v_schema, v_schema);



  -- ============================================

  -- TRIGGER FUNCTIONS (per schema)

  -- ============================================



  -- Auto-increment triggers for all tables

  EXECUTE format('CREATE FUNCTION %I.set_yr_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.yr_id IS NULL OR NEW.yr_id = 0 THEN NEW.yr_id := COALESCE((SELECT MAX(yr_id) FROM %I.year), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_year_yr_id BEFORE INSERT ON %I.year FOR EACH ROW EXECUTE FUNCTION %I.set_yr_id()', v_schema, v_schema);



  -- students: sequence-backed id, no hardcoded storage URL (photos resolved client-side)

  EXECUTE format('CREATE SEQUENCE %I.students_stu_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_stu_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stu_id IS NULL OR NEW.stu_id = 0 THEN NEW.stu_id := nextval(''%I.students_stu_id_seq''); END IF; IF (NEW.cour_id IS NULL OR NEW.cour_id = 0) AND NEW.courname IS NOT NULL AND TRIM(NEW.courname) != '''' THEN SELECT c.cour_id INTO NEW.cour_id FROM %I.course c WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM(NEW.courname)) AND c.ins_id = NEW.ins_id LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_students_before_insert BEFORE INSERT ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.set_stu_id()', v_schema, v_schema);



  -- parents: sequence-backed id

  EXECUTE format('CREATE SEQUENCE %I.parents_par_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_par_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.par_id IS NULL OR NEW.par_id = 0 THEN NEW.par_id := nextval(''%I.parents_par_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_parents_before_insert BEFORE INSERT ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.set_par_id()', v_schema, v_schema);



  -- parentdetail: sequence-backed id

  EXECUTE format('CREATE SEQUENCE %I.parentdetail_pd_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_pd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pd_id IS NULL OR NEW.pd_id = 0 THEN NEW.pd_id := nextval(''%I.parentdetail_pd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_parentdetail_auto_id BEFORE INSERT ON %I.parentdetail FOR EACH ROW EXECUTE FUNCTION %I.set_pd_id()', v_schema, v_schema);



  -- feedemand uses a real sequence (bulk import path — must be O(1) per row)

  EXECUTE format('CREATE SEQUENCE %I.feedemand_dem_id_seq', v_schema);

  EXECUTE format($f$CREATE FUNCTION %I.set_dem_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.dem_id IS NULL OR NEW.dem_id = 0 THEN NEW.dem_id := nextval('%I.feedemand_dem_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.dem_id::TEXT, 5, '0'); END IF; END IF; IF NEW.demseqtype IS NULL OR TRIM(NEW.demseqtype) = '' THEN NEW.demseqtype := 'DEMAND'; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.demfeetype IS NOT NULL THEN SELECT ft.fee_id INTO NEW.fee_id FROM %I.feetype ft WHERE ft.feedesc = NEW.demfeetype AND ft.activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_feedemand_before_insert BEFORE INSERT ON %I.feedemand FOR EACH ROW EXECUTE FUNCTION %I.set_dem_id()', v_schema, v_schema);



  -- tempfeedemand uses a real sequence (bulk import path — must be O(1) per row)

  EXECUTE format('CREATE SEQUENCE %I.tempfeedemand_temp_id_seq', v_schema);

  EXECUTE format($f$CREATE FUNCTION %I.set_temp_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.temp_id IS NULL THEN NEW.temp_id := nextval('%I.tempfeedemand_temp_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.temp_id::TEXT, 5, '0'); END IF; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_temp_id BEFORE INSERT ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_temp_id()', v_schema, v_schema);



  -- Master-table auto-increment sequences. The NULL/0 guard lets callers

  -- supply an explicit id (needed when importing master data from a legacy

  -- system); a plain INSERT without the column gets nextval().

  EXECUTE format('CREATE SEQUENCE %I.feegroup_fg_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_fg_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fg_id IS NULL OR NEW.fg_id = 0 THEN NEW.fg_id := nextval(''%I.feegroup_fg_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_feegroup_fg_id BEFORE INSERT ON %I.feegroup FOR EACH ROW EXECUTE FUNCTION %I.set_fg_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.feetype_fee_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_fee_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fee_id IS NULL OR NEW.fee_id = 0 THEN NEW.fee_id := nextval(''%I.feetype_fee_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_feetype_fee_id BEFORE INSERT ON %I.feetype FOR EACH ROW EXECUTE FUNCTION %I.set_fee_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.concessioncategory_con_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_con_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.con_id IS NULL OR NEW.con_id = 0 THEN NEW.con_id := nextval(''%I.concessioncategory_con_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_concession_con_id BEFORE INSERT ON %I.concessioncategory FOR EACH ROW EXECUTE FUNCTION %I.set_con_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.course_cour_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_cour_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cour_id IS NULL OR NEW.cour_id = 0 THEN NEW.cour_id := nextval(''%I.course_cour_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_course_cour_id BEFORE INSERT ON %I.course FOR EACH ROW EXECUTE FUNCTION %I.set_cour_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.class_cla_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_cla_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cla_id IS NULL OR NEW.cla_id = 0 THEN NEW.cla_id := nextval(''%I.class_cla_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_class_cla_id BEFORE INSERT ON %I.class FOR EACH ROW EXECUTE FUNCTION %I.set_cla_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.classfeedemand_cf_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_cf_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cf_id IS NULL THEN NEW.cf_id := nextval(''%I.classfeedemand_cf_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_classfeedemand_cf_id BEFORE INSERT ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_cf_id()', v_schema, v_schema);

  -- Resolve cla_id / sem_id / fee_id from the cfclass / cfterm / cffeetype names

  -- on insert/update (schema-qualified, so it works from the session-gated RPCs).

  EXECUTE format('CREATE OR REPLACE FUNCTION %I.set_classfee_ids() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF (NEW.cla_id IS NULL OR NEW.cla_id = 0) AND NEW.cfclass IS NOT NULL THEN SELECT cla_id INTO NEW.cla_id FROM %I.class WHERE claname = NEW.cfclass AND activestatus = 1 LIMIT 1; END IF; IF (NEW.sem_id IS NULL OR NEW.sem_id = 0) AND NEW.cfterm IS NOT NULL THEN SELECT sem_id INTO NEW.sem_id FROM %I.semester WHERE semname = NEW.cfterm AND activestatus = 1 LIMIT 1; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.cffeetype IS NOT NULL THEN SELECT fee_id INTO NEW.fee_id FROM %I.feetype WHERE feedesc = NEW.cffeetype AND activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_classfeedemand_ids BEFORE INSERT OR UPDATE ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_classfee_ids()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.payment_pay_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %1$I.set_pay_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ BEGIN IF NEW.pay_id IS NULL OR NEW.pay_id = 0 THEN NEW.pay_id := nextval(''%1$I.payment_pay_id_seq''); END IF; RETURN NEW; END; $t$', v_schema);

  EXECUTE format('CREATE TRIGGER trg_payment_auto_increment BEFORE INSERT ON %I.payment FOR EACH ROW EXECUTE FUNCTION %I.set_pay_id()', v_schema, v_schema);



  EXECUTE format('CREATE SEQUENCE %I.paymentdetails_pyd_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_pyd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pyd_id IS NULL OR NEW.pyd_id = 0 THEN NEW.pyd_id := nextval(''%I.paymentdetails_pyd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_paymentdetails_auto_increment BEFORE INSERT ON %I.paymentdetails FOR EACH ROW EXECUTE FUNCTION %I.set_pyd_id()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_car_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.car_id := COALESCE((SELECT MAX(car_id) FROM %I.shoppingcart), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_generate_car_id BEFORE INSERT ON %I.shoppingcart FOR EACH ROW EXECUTE FUNCTION %I.set_car_id()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_cd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.cd_id := COALESCE((SELECT MAX(cd_id) FROM %I.shoppingcartdetails), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_generate_cd_id BEFORE INSERT ON %I.shoppingcartdetails FOR EACH ROW EXECUTE FUNCTION %I.set_cd_id()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_notice_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.notice_id IS NULL OR NEW.notice_id = 0 THEN NEW.notice_id := COALESCE((SELECT MAX(notice_id) FROM %I.notice), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_notice_id BEFORE INSERT ON %I.notice FOR EACH ROW EXECUTE FUNCTION %I.set_notice_id()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.set_noti_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ BEGIN IF NEW.noti_id IS NULL OR NEW.noti_id = 0 THEN NEW.noti_id := COALESCE((SELECT MAX(noti_id) FROM %I.notification), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_noti_id BEFORE INSERT ON %I.notification FOR EACH ROW EXECUTE FUNCTION %I.set_noti_id()', v_schema, v_schema);



  -- Password hash triggers

  EXECUTE format('CREATE FUNCTION %I.hash_student_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stupassword IS NOT NULL AND NEW.stupassword != '''' AND LEFT(NEW.stupassword, 4) != ''$2a$'' AND LEFT(NEW.stupassword, 4) != ''$2b$'' THEN NEW.stupassword := crypt(NEW.stupassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);

  EXECUTE format('CREATE TRIGGER hash_student_password_trigger BEFORE INSERT OR UPDATE OF stupassword ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.hash_student_password()', v_schema, v_schema);



  EXECUTE format('CREATE FUNCTION %I.hash_parent_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.parpassword IS NOT NULL AND NEW.parpassword != '''' AND LEFT(NEW.parpassword, 4) != ''$2a$'' AND LEFT(NEW.parpassword, 4) != ''$2b$'' THEN NEW.parpassword := crypt(NEW.parpassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);

  EXECUTE format('CREATE TRIGGER hash_parent_password_trigger BEFORE INSERT OR UPDATE OF parpassword ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.hash_parent_password()', v_schema, v_schema);



  -- Transfer Certificate entries (Admission → Transfer Certificate). One row per

  -- TC issued; save_tc_entry writes here and stamps the student's + admission's

  -- activestatus with the leaving code, so non-active students drop out of the

  -- active screens (which filter activestatus=1).

  EXECUTE format('CREATE TABLE %I.tc_entry (tc_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), stu_id bigint, stuadmno varchar(25) NOT NULL, stuname varchar(50), stuclass varchar(20), cla_id smallint, birthdate date, joindate date, status smallint NOT NULL DEFAULT 1 CHECK (status = ANY(ARRAY[1,2,3,4,5,9])), statustype varchar(20), tcno varchar(30), tcdate date, effectfrom date, docno varchar(30), docdate date, remarks varchar(200), createdby varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  EXECUTE format('CREATE SEQUENCE %I.tc_entry_tc_id_seq', v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_tc_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.tc_id IS NULL OR NEW.tc_id = 0 THEN NEW.tc_id := nextval(''%I.tc_entry_tc_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);

  EXECUTE format('CREATE TRIGGER trg_tc_entry_tc_id BEFORE INSERT ON %I.tc_entry FOR EACH ROW EXECUTE FUNCTION %I.set_tc_id()', v_schema, v_schema);

  EXECUTE format('ALTER TABLE %I.tc_entry ENABLE ROW LEVEL SECURITY', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.tc_entry USING (true) WITH CHECK (true)', v_schema);



  -- (rollno_change lives in public, alongside public.admission — see above.)



  -- (fn_approve_tempfeedemand + trigger are defined right after the tempfeedemand

  -- table above; they carry the `collectible` flag from temp into feedemand.)



  -- RLS

  EXECUTE format('ALTER TABLE %I.notice ENABLE ROW LEVEL SECURITY', v_schema);

  EXECUTE format('ALTER TABLE %I.notification ENABLE ROW LEVEL SECURITY', v_schema);

  EXECUTE format('ALTER TABLE %I.tempfeedemand ENABLE ROW LEVEL SECURITY', v_schema);

  -- student_import was missing its ENABLE (policy created below), which tripped

  -- the Supabase "Policy Exists RLS Disabled" advisor for every new schema.

  EXECUTE format('ALTER TABLE %I.student_import ENABLE ROW LEVEL SECURITY', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.notice USING (true) WITH CHECK (true)', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.notification USING (true) WITH CHECK (true)', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.tempfeedemand USING (true) WITH CHECK (true)', v_schema);

  EXECUTE format('CREATE POLICY "Allow all" ON %I.student_import USING (true) WITH CHECK (true)', v_schema);



  -- PERMISSIONS

  EXECUTE format('GRANT USAGE ON SCHEMA %I TO anon, authenticated', v_schema);

  EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO anon, authenticated', v_schema);

  EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO anon, authenticated', v_schema);

  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO anon, authenticated', v_schema);

  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO anon, authenticated', v_schema);



  -- Auto-create year records if parameters provided

  IF p_ins_id IS NOT NULL AND p_year_label IS NOT NULL THEN

    -- Insert into public.institutionyear, stamping iyrschema so the row

    -- carries the per-year schema name (e.g. 'kcet20262027') without the

    -- app having to re-derive it from inshortname + yrlabel.

    INSERT INTO public.institutionyear (ins_id, inscode, yrlabel, iyrstadate, iyrenddate, iyrschema, activestatus)

    VALUES (p_ins_id, COALESCE(v_inscode, ''), p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year'), v_schema, 1)

    ON CONFLICT (ins_id, yrlabel) DO UPDATE SET iyrschema = EXCLUDED.iyrschema;



    -- Insert into schema year table

    EXECUTE format('INSERT INTO %I.year (ins_id, yrlabel, yrstadate, yrenddate, activestatus) VALUES ($1, $2, $3, $4, 1)', v_schema)

    USING p_ins_id, p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year');

  END IF;



  -- Expose schema to PostgREST (may fail on free tier - handled by app login)

  BEGIN

    PERFORM public.expose_schema(v_schema);

  EXCEPTION WHEN OTHERS THEN

    RAISE NOTICE 'expose_schema skipped: %', SQLERRM;

  END;



  -- Security (Option B): the money tables are written ONLY through session-gated

  -- SECURITY DEFINER RPCs (they run as owner), so a new schema is born with anon

  -- direct-write REVOKED on them. SELECT is left intact (reads unchanged). This

  -- mirrors phase3a_revoke_money_writes.sql for existing schemas.

  EXECUTE format(

    'REVOKE INSERT, UPDATE, DELETE ON %I.payment, %I.paymentdetails, %I.feedemand, '

    '%I.fee_refund, %I.fee_refunddetails, %I.concession, %I.concessiondetail, %I.students, %I.parents, %I.parentdetail, '

    '%I.advance_collection, %I.advance_detail, %I.advadjustment FROM anon',

    v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema,

    v_schema, v_schema, v_schema);



  -- Read lockdown: enable RLS + per-tenant SELECT policy on sensitive tables so a

  -- NEW institution is born read-locked (anon can't SELECT another tenant's PII/

  -- money). Wrapped so a policy hiccup never blocks institution creation.

  BEGIN

    PERFORM public.read_lock_schema(v_schema);

  EXCEPTION WHEN OTHERS THEN

    RAISE NOTICE 'read_lock_schema skipped for %: %', v_schema, SQLERRM;

  END;



END; $function$;


-- ---------------------------------------------------------------------- 5d -
-- Withdraw any demand already staged against a non-hosteller for a
-- hostel-only fee. activestatus = 9 is what the approval trigger stamps on a
-- temp row it has finished with: it leaves Fee Demand Approval, stops
-- blocking a later legitimate generate, and is still there to look at.
-- PENDING rows only; nothing approved is touched.
-- ---------------------------------------------------------------------------

DO $wd$
DECLARE r record; n int; total int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.columns
     WHERE table_name = 'feegroup' AND column_name = 'hostellers_only'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
  LOOP
    EXECUTE format($q$
      UPDATE %1$I.tempfeedemand t
         SET activestatus = 9
        FROM %1$I.students s
       WHERE s.stu_id = t.stu_id
         AND t.activestatus = 1
         AND t.isapproved = false
         AND COALESCE(UPPER(TRIM(s.hostel)), 'N') <> 'Y'
         AND EXISTS (SELECT 1 FROM %1$I.feetype ft
                       JOIN %1$I.feegroup fg ON fg.fg_id = ft.fg_id
                      WHERE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(t.demfeetype))
                        AND ft.activestatus = 1 AND fg.hostellers_only)
         AND NOT EXISTS (SELECT 1 FROM %1$I.feetype ft
                           JOIN %1$I.feegroup fg ON fg.fg_id = ft.fg_id
                          WHERE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(t.demfeetype))
                            AND ft.activestatus = 1 AND NOT fg.hostellers_only)
    $q$, r.sch);
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
    IF n > 0 THEN RAISE NOTICE 'withdrew % staged demand(s) in %', n, r.sch; END IF;
  END LOOP;
  RAISE NOTICE 'withdrawn in total: %', total;
END
$wd$;


-- =================================================================== PART 6 =
-- VERIFICATION. Read-only. Expect every column true.
-- ===========================================================================

SELECT
  (SELECT count(*) FROM pg_indexes
    WHERE tablename = 'paymentdetails'
      AND indexname IN ('idx_paymentdetails_pay', 'idx_paymentdetails_dem')) >= 2
                                                            AS p1_pd_indexes,
  (SELECT count(*) FROM pg_indexes
    WHERE tablename = 'bank' AND indexname = 'bank_accno_live_uniq') >= 1
                                                            AS p2_bank_unique,
  (SELECT pg_get_functiondef(p.oid) LIKE '%AND fg_id=$2%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'save_misc_collection')
                                                            AS p3_misc_series,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('void_receipt', 'void_misc_receipt', 'void_advance_receipt')
      AND pg_get_functiondef(p.oid) LIKE '%receipt_cancel_block_reason%') = 3
                                                            AS p4_cash_only,
  (SELECT count(*) FROM information_schema.columns
    WHERE table_name = 'feegroup' AND column_name = 'hostellers_only') >= 1
                                                            AS p5a_column,
  (SELECT pg_get_functiondef(p.oid) LIKE '%hostellers_only%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'generate_feedemand_for_class')
                                                            AS p5b_class_rule,
  (SELECT pg_get_functiondef(p.oid) LIKE '%hostellers_only%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema')
                                                            AS p5c_generator;

-- The cancel rule, spelled out. Cash cancellable, everything else refused.
SELECT mode,
       COALESCE(left(public.receipt_cancel_block_reason(mode, 'R'), 40),
                '-- CANCELLABLE --') AS verdict
  FROM (VALUES ('Cash'), ('Online Transfer'), ('UPI'), ('NEFT/RTGS'),
               ('Cheque'), ('DD'), ('Advance Adjustment')) t(mode);

-- Fee groups: account, merchant and receipt series. Anything blank here is
-- configuration still to do, not a failed install.
SELECT fg.fg_id, fg.fgdesc, fg.hostellers_only, fg.ban_id,
       CASE WHEN COALESCE(b.paytm_mid, '') = '' THEN 'no merchant' ELSE 'ok' END AS merchant,
       COALESCE(s.seqprefix, 'NO SERIES') AS receipt_series
  FROM kcet20262027.feegroup fg
  LEFT JOIN kcet20262027.bank b ON b.ban_id = fg.ban_id
  LEFT JOIN kcet20262027.sequence s ON s.fg_id = fg.fg_id AND s.activestatus = 1
 WHERE fg.activestatus = 1
 ORDER BY fg.fg_id;

-- #####################################################################
-- PART C -- list_webhook_refusals -- the office can SEE unmatched captures
-- #####################################################################

-- ============================================================================
-- Let the office SEE the refusals. Read-only.
-- ============================================================================
-- WHAT IS WRONG TODAY. public.webhook_refusal is where the system records
-- money Paytm confirmed that it could not turn into a receipt. It works: on
-- 12-10-2026 a Rs 2,700 capture at 15:38:04 was flagged at 15:38:06.913 --
-- under three seconds.
--
-- Nobody ever sees it. The table is service_role only, and no screen in any
-- app reads it. student_fee_collection_screen.dart WRITES refusals and
-- nothing anywhere reads them back. So that Rs 2,700 sat unnoticed for
-- nineteen hours and took a morning of log archaeology to attribute to
-- SANDHIYAH T -- a question the database had already asked, out loud, before
-- the parent had put her phone down.
--
-- Detection without delivery is not detection.
--
-- WHAT THIS DOES. One STABLE SECURITY DEFINER reader so the desktop app can
-- list them. Same shape as open_pending_collections: takes an institution,
-- granted to anon and authenticated.
--
-- WHAT IT DELIBERATELY DOES NOT DO. It cannot write. Resolving a refusal
-- stays with resolve_webhook_refusal (service_role) and with the recovery
-- scripts, which close the row as part of raising the receipt. A refusal is
-- a claim that the college holds money it has not receipted; a client that
-- could clear that claim could hide it.
--
-- ins_id IS NULL rows are INCLUDED. The commonest refusal -- "no payment row,
-- the attempt is gone" -- has no payment row to read an institution from, so
-- ins_id is null. Those are precisely the ones that need a human, and
-- filtering them out would hide the entire class of problem this exists for.
-- Harmless while one institution is live; revisit when a second one is.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.list_webhook_refusals(
  p_ins_id integer,
  p_include_resolved boolean DEFAULT false,
  p_limit integer DEFAULT 200
)
RETURNS TABLE(
  order_id        text,
  ins_id          integer,
  pay_id          bigint,
  amount          numeric,
  reason          text,
  times_seen      integer,
  first_seen      timestamptz,
  last_seen       timestamptz,
  resolved_at     timestamptz,
  resolved_by     text,
  resolution_note text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT r.order_id, r.ins_id, r.pay_id, r.amount, r.reason,
         r.times_seen, r.first_seen, r.last_seen,
         r.resolved_at, r.resolved_by, r.resolution_note
    FROM public.webhook_refusal r
   WHERE (r.ins_id = p_ins_id OR r.ins_id IS NULL)
     AND (p_include_resolved OR r.resolved_at IS NULL)
   ORDER BY (r.resolved_at IS NULL) DESC, r.last_seen DESC
   LIMIT GREATEST(COALESCE(p_limit, 200), 1);
$$;

GRANT EXECUTE ON FUNCTION public.list_webhook_refusals(integer, boolean, integer)
  TO anon, authenticated;

-- #####################################################################
-- PART D -- the SECOND delete path guarded too
-- #####################################################################

-- ============================================================================
-- Close the SECOND door into the same room.
-- ============================================================================
-- WHAT THIS IS. On 12-10-2026 create_pending_payment was taught not to delete
-- a payment row younger than 15 minutes, because "payorderid is blank" had
-- turned out to be a false proxy for "nothing can have been charged" -- that
-- is how KANNAN D's Rs 5,125 was destroyed by his own retry.
--
-- delete_stale_initiated_payments does the SAME DELETE, with the SAME test,
-- and was never guarded:
--
--     DELETE FROM <schema>.payment
--      WHERE stu_id = $1 AND paystatus = 'I'
--        AND NULLIF(btrim(payorderid), '') IS NULL
--
-- It is called by the PARENT APP -- seen on live at 13-10-2026 11:17:33, one
-- minute after a real payment went through the same screen.
--
-- HOW BIG IS THE WINDOW NOW. Smaller than it was, not closed. Since the edge
-- function was repaired, a payment that reaches the gateway is stamped within
-- about a second -- live shows insert_payment at 11:16:13 and
-- stamp_payorderid at 11:16:14. But between those two instants the row exists
-- with a blank payorderid and Paytm may already have an order open. A second
-- session calling this in that second deletes a live attempt, and the money
-- arrives with nothing to land on.
--
-- One second times every payment is not a risk worth leaving in place when
-- the fix is the same clause that is already on the other path.
--
-- WHY AGE AND NOT SOMETHING CLEVERER. 15 minutes matches
-- _sweepOrphanedPayments' own cutoff, so any row this refuses to delete is
-- one the sweep has already taken responsibility for. The two must agree, or
-- a row falls between them.
--
-- Patches the live definition in place rather than replacing it, so an
-- unrelated change to this function since cannot be silently reverted.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================

DO $patch$
DECLARE
  src text;
  old_txt CONSTANT text := 'AND NULLIF(btrim(payorderid), '''''''') IS NULL';
  new_txt CONSTANT text := 'AND NULLIF(btrim(payorderid), '''''''') IS NULL '
                           'AND createdat < now() - interval ''''15 minutes''''';
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
   WHERE n2.nspname = 'public' AND p.proname = 'delete_stale_initiated_payments';

  IF src IS NULL THEN
    RAISE NOTICE 'delete_stale_initiated_payments does not exist - nothing to do';
    RETURN;
  END IF;

  IF src LIKE '%15 minutes%' THEN
    RAISE NOTICE 'delete_stale_initiated_payments already guarded';
    RETURN;
  END IF;

  -- Both DELETEs carry the clause, so expect exactly two replacements. Any
  -- other count means the function is not what this was written against, and
  -- guessing at a money path is how the duplicated clause got onto live in
  -- the create_pending_payment patch.
  n := (length(src) - length(replace(src, old_txt, ''))) / length(old_txt);
  IF n <> 2 THEN
    RAISE EXCEPTION 'Expected the payorderid test twice, found % - NOT patched. '
      'The function has changed since this was written; read it before forcing.', n;
  END IF;

  src := replace(src, old_txt, new_txt);
  EXECUTE src;
  RAISE NOTICE 'patched public.delete_stale_initiated_payments (% clause(s))', n;
END
$patch$;

-- #####################################################################
-- PART E -- tidy: the duplicated guard clause on create_pending_payment
-- #####################################################################

-- ============================================================================
-- Tidy: remove a duplicated clause from create_pending_payment.
-- ============================================================================
-- COSMETIC ONLY. Live currently reads:
--
--     AND COALESCE(length(btrim(payorderid)), 0) = 0
--       AND createdat < now() - interval '15 minutes'
--       AND createdat < now() - interval '15 minutes'
--
-- on the paymentdetails DELETE. X AND X is X, so behaviour is correct and
-- always has been -- nothing was ever at risk from this.
--
-- HOW IT HAPPENED. The patch in PAYORDERID_STAMP_AND_GUARD.sql replaced the
-- detail clause (5-space indent) and then the payment clause (3-space). The
-- shorter pattern is a SUBSTRING of the rewritten longer line, so it matched
-- again and appended the guard a second time. The comment in that file
-- claiming the ordering prevented this was simply wrong; it is now fixed
-- there, and GUARD_STALE_PAYMENT_DELETE.sql counts its matches before
-- replacing anything for the same reason.
--
-- WHY BOTHER. The standing check for both deletion paths is
--
--     guard_count = 2        one per DELETE
--
-- and live answers 3, which will read as a fault to whoever runs it next.
--
-- This is the definition as it runs on TEST after the clean patch, extracted
-- with pg_get_functiondef -- not a hand-edit.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_pending_payment(p_ins_id integer, p_stu_id bigint, p_total numeric, p_yr_id integer, p_yrlabel text, p_created_by text, p_payitems text, p_details jsonb, p_ban_id integer DEFAULT NULL::integer)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET statement_timeout TO '30s'
AS $function$



DECLARE



  v text; v_inscode text; v_pay_id bigint; v_fallback_yr int; v_yr int; it jsonb;



BEGIN



  v := get_institution_schema(p_ins_id);



  IF v IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;







  PERFORM public.assert_fee_payment_allowed(p_ins_id, p_stu_id, p_details);







  EXECUTE format('SELECT inscode FROM %I.students WHERE stu_id=$1', v) INTO v_inscode USING p_stu_id;



  EXECUTE format('SELECT yr_id FROM %I.year WHERE activestatus=1 ORDER BY yr_id DESC LIMIT 1', v) INTO v_fallback_yr;



  v_yr := COALESCE(NULLIF(p_yr_id, 0), v_fallback_yr);







  -- length(btrim(...)) rather than = '' so the test carries no nested quotes



  -- through two levels of format(); NULL and whitespace both read as absent.



  EXECUTE format(



    'DELETE FROM %1$I.paymentdetails WHERE pay_id IN ('



    '  SELECT pay_id FROM %1$I.payment'



    '   WHERE stu_id=$1 AND paystatus=''I'''



    '     AND COALESCE(length(btrim(payorderid)), 0) = 0 AND createdat < now() - interval ''15 minutes'')', v)



  USING p_stu_id;



  EXECUTE format(



    'DELETE FROM %I.payment'



    ' WHERE stu_id=$1 AND paystatus=''I'''



    '   AND COALESCE(length(btrim(payorderid)), 0) = 0 AND createdat < now() - interval ''15 minutes''', v)



  USING p_stu_id;







  EXECUTE format(



    'INSERT INTO %I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,'



    'paydate,paystatus,recon_status,createdby,payitems,activestatus,ban_id) '



    'VALUES($1,$2,$3,$4,$5,$6,''INR'',now(),''I'',''P'',$7,$8,1,$9) RETURNING pay_id', v)



  INTO v_pay_id USING p_ins_id, v_inscode, p_stu_id, v_yr, p_yrlabel, p_total, p_created_by, p_payitems, p_ban_id;







  FOR it IN SELECT jsonb_array_elements(p_details) LOOP



    EXECUTE format(



      'INSERT INTO %I.paymentdetails(pay_id,dem_id,yr_id,yrlabel,ins_id,transcurrency,transtotalamount,activestatus) '



      'VALUES($1,$2,$3,$4,$5,''INR'',$6,1)', v)



    USING v_pay_id, (it->>'dem_id')::bigint, COALESCE(NULLIF((it->>'yr_id')::int, 0), v_fallback_yr),



          (it->>'yrlabel'), p_ins_id, (it->>'amount')::numeric;



  END LOOP;







  RETURN v_pay_id;



END; $function$;

-- #####################################################################
-- PART F -- feetype.ordid -- report columns and the Fee Type picker in the order the office chooses
-- #####################################################################

-- ============================================================================
-- feetype.ordid -- let the office decide the order fee types appear in.
-- ============================================================================
-- WHY. Reports lay fee types out as columns and sort them ALPHABETICALLY, so
-- a statement reads ADMISSION, A.U.SPORTS FEE, BUS FEES, EXAM FEE, TUITION
-- FEE -- which is nobody's idea of how a fee statement should read. TUITION
-- FEE is the one everybody looks for and it lands near the end because of its
-- initial letter.
--
-- Every other master that has a meaningful running order already carries this
-- column, with the same name and type: class, course, semester,
-- concessioncategory. feetype was the odd one out.
--
-- WHAT THIS DOES.
--   PART 1  adds ordid smallint to feetype in EVERY institution schema.
--   PART 2  seeds it so nothing is NULL on day one -- grouped by fee group,
--           then by fee_id within the group, which is the order they were
--           created and the closest thing to an intended sequence that
--           exists today. The office can renumber freely afterwards.
--   PART 3  patches create_institution_schema so a NEW institution is born
--           with the column instead of inheriting the old shape.
--
-- ORDERING IS ADVISORY, NOT A KEY. Duplicates and gaps are fine: the app
-- falls back to the fee description so two rows sharing an ordid still come
-- out in a stable, predictable order rather than shuffling between runs.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 1 =
-- The column, in every institution schema.
-- ===========================================================================

DO $add$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feetype'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.feetype ADD COLUMN IF NOT EXISTS ordid smallint', r.sch);
    RAISE NOTICE 'feetype.ordid ready in %', r.sch;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '% schema(s) updated', n;
END
$add$;


-- =================================================================== PART 2 =
-- Seed it. Only rows still NULL, so a re-run never undoes the office's work.
-- ===========================================================================

DO $seed$
DECLARE r record; n int := 0; c int;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feetype'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format($q$
      WITH ranked AS (
        SELECT fee_id,
               (row_number() OVER (ORDER BY COALESCE(fg_id, 32767), fee_id))::smallint AS seq
          FROM %I.feetype
      )
      UPDATE %I.feetype f
         SET ordid = ranked.seq
        FROM ranked
       WHERE f.fee_id = ranked.fee_id
         AND f.ordid IS NULL
    $q$, r.sch, r.sch);
    GET DIAGNOSTICS c = ROW_COUNT;
    RAISE NOTICE '% : % fee type(s) numbered', r.sch, c;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '% schema(s) seeded', n;
END
$seed$;


-- =================================================================== PART 3 =
-- New institutions get it too.
--
-- Patches the live generator text rather than replacing the whole function --
-- 55,000 characters of it -- so an unrelated change made since cannot be
-- silently reverted by this migration.
-- ===========================================================================

DO $gen$
DECLARE
  src text;
  feetype_ddl text;
  -- The real column is partialALLowed. An earlier draft of this migration
  -- searched for 'partiallowed' and would have matched nothing; it was saved
  -- only by a guard that was ALSO wrong -- 'src LIKE ''%feetype%ordid%''' is
  -- true of any generator containing both words anywhere, and ordid already
  -- exists on class, course and semester. Two loose tests cancelling out is
  -- not a safety net.
  old_txt CONSTANT text := 'partialallowed char(1) DEFAULT ''''Y''''';
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'create_institution_schema';

  IF src IS NULL THEN
    RAISE NOTICE 'create_institution_schema not found - nothing to patch';
    RETURN;
  END IF;

  -- Look at FEETYPE'S OWN definition, not the whole function.
  feetype_ddl := substring(src from 'CREATE TABLE %I.feetype[^;]*');
  IF feetype_ddl IS NULL THEN
    RAISE EXCEPTION 'Could not find feetype in the generator -- NOT patched.';
  END IF;

  IF feetype_ddl LIKE '%ordid%' THEN
    RAISE NOTICE 'generator already creates feetype.ordid';
    RETURN;
  END IF;

  n := (length(src) - length(replace(src, old_txt, ''))) / length(old_txt);
  IF n <> 1 THEN
    RAISE EXCEPTION 'Expected feetype''s partiallowed column once in the '
      'generator, found % -- NOT patched. Read the function before forcing; '
      'guessing at a schema builder is how a new institution is born broken.', n;
  END IF;

  src := replace(src, old_txt, 'ordid smallint, ' || old_txt);
  EXECUTE src;
  RAISE NOTICE 'patched create_institution_schema: feetype gains ordid';
END
$gen$;


-- #####################################################################
-- PART G -- VERIFICATION
-- #####################################################################

SELECT
  to_regprocedure('public.stamp_payorderid(bigint,text)') IS NOT NULL
    AS a_stamp_fn,
  (SELECT pg_get_functiondef(p.oid) LIKE '%15 minutes%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='create_pending_payment')
    AS a_delete_guarded,
  EXISTS (SELECT 1 FROM pg_indexes
           WHERE schemaname='kcet20262027' AND indexname='idx_paymentdetails_pay')
    AS b_pd_index,
  EXISTS (SELECT 1 FROM pg_indexes
           WHERE schemaname='kcet20262027' AND indexname='bank_accno_live_uniq')
    AS b_bank_unique,
  to_regprocedure('public.receipt_cancel_block_reason(text,text)') IS NOT NULL
    AS b_cancel_rule,
  EXISTS (SELECT 1 FROM information_schema.columns
           WHERE table_schema='kcet20262027' AND table_name='feegroup'
             AND column_name='hostellers_only')
    AS b_hostel_flag,
  to_regprocedure('public.list_webhook_refusals(integer,boolean,integer)') IS NOT NULL
    AS c_refusal_reader,
  NOT has_table_privilege('anon','public.webhook_refusal','UPDATE')
    AS c_anon_cannot_clear,
  (SELECT pg_get_functiondef(p.oid) LIKE '%15 minutes%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='delete_stale_initiated_payments')
    AS d_stale_guarded,
  EXISTS (SELECT 1 FROM information_schema.columns
           WHERE table_schema='kcet20262027' AND table_name='feetype'
             AND column_name='ordid')
    AS f_feetype_ordid,
  (SELECT substring(pg_get_functiondef(p.oid)
                    from 'CREATE TABLE %I.feetype[^;]*') LIKE '%ordid%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='create_institution_schema')
    AS f_generator_has_it,
  (SELECT count(*) FROM kcet20262027.feetype
    WHERE activestatus = 1 AND ordid IS NULL)
    AS feetype_unset;


-- =====================================================================
-- AFTERWARDS:
--
--   1. PART G: every column true, feetype_unset is a count not a verdict.
--   2. Set the fee-type order if you have not:
--        SELECT ordid, fee_id, feedesc FROM kcet20262027.feetype
--         WHERE activestatus = 1 ORDER BY ordid, feedesc;
--        UPDATE kcet20262027.feetype SET ordid = 1 WHERE feedesc = 'TUITION FEE';
--   3. create-paytm-order is ALREADY redeployed (verified live 13-10 11:16 --
--      rpc/stamp_payorderid called by the edge runtime, no 404 PATCH). Only
--      redeploy it if PART A reports it had to create stamp_payorderid afresh.
--   4. Upload the desktop installer, THEN latest.json.
--   5. Re-dump complete_setup.sql so the file keeps matching live.
-- =====================================================================
