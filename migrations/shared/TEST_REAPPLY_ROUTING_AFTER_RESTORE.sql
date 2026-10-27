-- ############################################################################
--
--   EduCore360 -- RE-APPLY THE FEE-GROUP ROUTING WORK ON TEST
--   28-09-2026
--
--   Run the WHOLE file in the SQL editor on the TEST project
--   (lyzmuwmqpqjqwbykfwzl). Step 0 refuses to run anywhere else.
--
-- ----------------------------------------------------------------------------
-- WHY THIS EXISTS
-- ----------------------------------------------------------------------------
-- The live dump of 28-09-2026 17:30 was restored over TEST. That rolled TEST
-- back to LIVE's schema, and live has never had the hostel/mess routing work,
-- so four migrations that were already applied to TEST were wiped with it:
--
--     FIX_ADVTYPE_MESS_CHECK          advtype would not accept 'M' (mess)
--     ADVANCE_ROUTING_CONFIG          advance settlement read from settings
--     ADVANCE_RECEIPT_SEQUENCE        advances numbered from their group
--     MISC_RECEIPT_SEQUENCE_BY_GROUP  misc receipts numbered from their group
--
-- This file is those four folded into one, in the order they must run.
--
-- ADVANCE_ROUTING_CONFIG is NOT included as a step of its own. It and
-- ADVANCE_RECEIPT_SEQUENCE rewrite the SAME function, and the second is the
-- later of the two, so only its final version appears here. Running the
-- earlier one afterwards would silently undo the receipt-sequence fix.
--
-- process_grouped_payment (step 2) is included for completeness even though
-- live already carries it, so that one run of this file leaves TEST in a
-- known state whatever it started from. CREATE OR REPLACE of an identical
-- body is a no-op.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS FILE DOES NOT DO
-- ----------------------------------------------------------------------------
-- It creates no master data. The HOSTEL FEES fee group, its bank account and
-- its receipt sequences are made in the app, not in SQL. Step 5 maps a bank to
-- HOSTEL FEES only IF that group already exists, and tells you if it does not
-- rather than inventing it.
--
-- Nor does it restore the Utilities settings (advance_route_fg_A / _S / _M,
-- misc_collection_fee_groups, the letterhead rows). Those are
-- public.institution_settings rows written by the desktop app's Utilities
-- screen -- set them there once the fee group exists. Step 6 lists what is
-- still missing.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- Every step is idempotent: constraint drops are guarded, functions are
-- CREATE OR REPLACE, and the bank mapping is one UPDATE of one column. No
-- payment, demand, receipt or advance row is read back or rewritten. It runs
-- in ONE transaction -- if any step raises, nothing at all is written.
--
-- ############################################################################

BEGIN;

-- ----------------------------------------------------------------------------
-- 0 -- REFUSE TO RUN ANYWHERE BUT TEST
-- ----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public._this_is_the_test_project') IS NULL THEN
    RAISE EXCEPTION
      'This is NOT the TEST project. Nothing was written. These four changes go to live through their own migration files, in the order named at the top of this one.';
  END IF;
END $guard$;


-- ----------------------------------------------------------------------------
-- 1 -- advtype accepts 'M' (mess advance), on every year schema
--
--      Two CHECK constraints on advtype is what made a mess advance fail
--      silently: a row must satisfy BOTH, so an older check that listed only
--      A and S rejected it however new the other one was. This drops every
--      advtype check that does not allow M, then adds one that does if none
--      is left.
-- ----------------------------------------------------------------------------
DO $fix$
DECLARE
  v_schema text;
  v_con    record;
  v_dropped int := 0;
  v_added   int := 0;
BEGIN
  FOR v_schema IN
    SELECT table_schema FROM information_schema.tables
     WHERE table_name = 'advance_collection' AND table_schema NOT IN ('pg_catalog','information_schema')
     ORDER BY table_schema
  LOOP
    -- 1. every check on advtype that forbids a mess advance
    FOR v_con IN
      EXECUTE format($q$
        SELECT c.conname, pg_get_constraintdef(c.oid) AS def
          FROM pg_constraint c
         WHERE c.conrelid = %L::regclass
           AND c.contype = 'c'
           AND pg_get_constraintdef(c.oid) ILIKE '%%advtype%%'
           AND pg_get_constraintdef(c.oid) NOT LIKE '%%''M''%%'
      $q$, v_schema || '.advance_collection')
    LOOP
      EXECUTE format('ALTER TABLE %I.advance_collection DROP CONSTRAINT %I',
                     v_schema, v_con.conname);
      v_dropped := v_dropped + 1;
    END LOOP;

    -- 2. and one that allows A, S and M, if none is left
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
       WHERE c.conrelid = (v_schema || '.advance_collection')::regclass
         AND c.contype = 'c'
         AND pg_get_constraintdef(c.oid) ILIKE '%advtype%'
    ) THEN
      EXECUTE format($q$
        ALTER TABLE %I.advance_collection
          ADD CONSTRAINT chk_advance_advtype
          CHECK (advtype::text = ANY (ARRAY['A'::text,'S'::text,'M'::text]))
      $q$, v_schema);
      v_added := v_added + 1;
    END IF;
  END LOOP;

  RAISE NOTICE 'advtype checks: % dropped, % added', v_dropped, v_added;
END $fix$;

-- ----------------------------------------------------------------------------
-- 2 -- fee collection: one payment per fee group, stamped with that group's
--      bank account
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.process_grouped_payment(p_ins_id integer, p_inscode character varying, p_stu_id bigint, p_yr_id integer, p_yrlabel character varying, p_total_amount numeric, p_created_by character varying, p_pay_method text, p_pay_reference text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v text; v_fg_id INTEGER; v_pay_id BIGINT; v_pay_number TEXT;
  v_seq RECORD; v_new_no INTEGER;
  v_current_paid NUMERIC; v_current_balance NUMERIC; v_current_fine NUMERIC;
  v_new_paid NUMERIC; v_new_balance NUMERIC;
  v_result JSONB := '[]'::jsonb;
  v_group_total NUMERIC;
  itm RECORD; v_fg_ids INTEGER[];
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema found'; END IF;
  v_fg_ids := ARRAY[]::INTEGER[];
  FOR itm IN SELECT x.dem_id, x.yr_id, x.yrlabel, x.amount, x.demfeetype
    FROM jsonb_to_recordset(p_items) AS x(dem_id bigint, yr_id integer, yrlabel text, ins_id integer, amount numeric, demfeetype text)
  LOOP
    v_fg_id := NULL;
    IF itm.demfeetype = 'FINE' THEN
      -- New format: demno starts with 'FNG<fg_id>' (group-wise fine).
      -- Older format: 'FN<orig_dem_id>' (per-demand fine) — fall back to that.
      EXECUTE format($q$
        SELECT CASE
          WHEN fn.demno LIKE 'FNG%%' THEN
            NULLIF(substring(fn.demno from '[0-9]+'), '')::int
          WHEN fn.demno LIKE 'FN%%' THEN
            (SELECT ft.fg_id FROM %I.feedemand orig
             JOIN %I.feetype ft
               ON (orig.fee_id IS NOT NULL AND ft.fee_id = orig.fee_id)
               OR (orig.fee_id IS NULL AND ft.feedesc = orig.demfeetype)
             WHERE orig.dem_id = NULLIF(substring(fn.demno from '[0-9]+'), '')::bigint
               AND ft.activestatus = 1 LIMIT 1)
          ELSE NULL
        END
        FROM %I.feedemand fn
        WHERE fn.dem_id = $1
      $q$, v, v, v) INTO v_fg_id USING itm.dem_id;
    END IF;
    IF v_fg_id IS NULL THEN
      EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc=$1 AND ft.activestatus=1 LIMIT 1',v) INTO v_fg_id USING itm.demfeetype;
    END IF;
    IF v_fg_id IS NULL THEN v_fg_id := 0; END IF;
    IF NOT v_fg_id = ANY(v_fg_ids) THEN v_fg_ids := v_fg_ids || v_fg_id; END IF;
  END LOOP;
  -- Create one payment per fee group
  FOREACH v_fg_id IN ARRAY v_fg_ids LOOP
    v_group_total := 0;
    -- EVERY payment stamps ban_id from its fee group, whatever the method.
    -- It used to be online channels only, on the reasoning that counter cash
    -- all lands in one account -- but that left hostel cash indistinguishable
    -- from college cash in the books. The fee group is what decides whose
    -- money it is; how it was handed over does not change that.
    EXECUTE format('INSERT INTO %1$I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,paydate,paystatus,paymethod,payreference,createdby,recon_status,reconciled_by,reconciled_date,ban_id) VALUES($1,$2,$3,$4,$5,0,''INR'',NOW(),''C'',$6,$7,$8,CASE WHEN LOWER($6)=''cash'' THEN ''R'' ELSE ''P'' END,CASE WHEN LOWER($6)=''cash'' THEN $8 ELSE NULL END,CASE WHEN LOWER($6)=''cash'' THEN NOW() ELSE NULL END,(SELECT ban_id FROM %1$I.feegroup WHERE fg_id=$9 LIMIT 1)) RETURNING pay_id',v)
    INTO v_pay_id USING p_ins_id,p_inscode,p_stu_id,p_yr_id,p_yrlabel,p_pay_method,p_pay_reference,p_created_by,v_fg_id;
    -- Get sequence for this fee group (with row lock for concurrency)
    v_seq := NULL;
    EXECUTE format('SELECT seq_id,sequid,seqwidth,seqcurno FROM %I.sequence WHERE ins_id=$1 AND fg_id=$2 LIMIT 1 FOR UPDATE',v) INTO v_seq USING p_ins_id,v_fg_id;
    IF v_seq IS NULL THEN v_pay_number:='PAY'||v_pay_id;
    ELSE v_new_no:=v_seq.seqcurno+1; v_pay_number:=regexp_replace(v_seq.sequid,'\d+$','')||lpad(v_new_no::TEXT,v_seq.seqwidth::INTEGER,'0'); EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2',v) USING v_new_no,v_seq.seq_id;
    END IF;
    EXECUTE format('UPDATE %I.payment SET paynumber=$1 WHERE pay_id=$2',v) USING v_pay_number,v_pay_id;
    -- Process demands for this fee group
    FOR itm IN SELECT x.dem_id, x.yr_id, x.yrlabel, x.amount, x.demfeetype
      FROM jsonb_to_recordset(p_items) AS x(dem_id bigint, yr_id integer, yrlabel text, ins_id integer, amount numeric, demfeetype text)
    LOOP
      DECLARE v_item_fg INTEGER;
      BEGIN
        v_item_fg := NULL;
        IF itm.demfeetype = 'FINE' THEN
          EXECUTE format($q$
            SELECT ft.fg_id
            FROM %I.feedemand fn
            JOIN %I.feedemand orig ON orig.dem_id = NULLIF(substring(fn.demno from '[0-9]+'), '')::bigint
            JOIN %I.feetype ft
              ON (orig.fee_id IS NOT NULL AND ft.fee_id = orig.fee_id)
              OR (orig.fee_id IS NULL AND ft.feedesc = orig.demfeetype)
            WHERE fn.dem_id = $1 AND ft.activestatus = 1
            LIMIT 1
          $q$, v, v, v) INTO v_item_fg USING itm.dem_id;
        END IF;
        IF v_item_fg IS NULL THEN
          EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc=$1 AND ft.activestatus=1 LIMIT 1',v) INTO v_item_fg USING itm.demfeetype;
        END IF;
        IF v_item_fg IS NULL THEN v_item_fg := 0; END IF;
        IF v_item_fg != v_fg_id THEN CONTINUE; END IF;
      END;
      v_group_total := v_group_total + itm.amount;
      EXECUTE format('INSERT INTO %I.paymentdetails(pay_id,dem_id,yr_id,yrlabel,ins_id,transcurrency,transtotalamount) VALUES($1,$2,$3,$4,$5,''INR'',$6)',v) USING v_pay_id,itm.dem_id,itm.yr_id,itm.yrlabel,p_ins_id,itm.amount;
      -- FOR UPDATE locks the row so concurrent collectors serialize. If the
      -- locked balance is already <= 0 another accountant got here first;
      -- raise to roll back this whole txn (including the payment row inserted
      -- above) so no duplicate receipt is created.
      EXECUTE format('SELECT paidamount,balancedue,fineamount FROM %I.feedemand WHERE dem_id=$1 AND activestatus=1 FOR UPDATE',v) INTO v_current_paid,v_current_balance,v_current_fine USING itm.dem_id;
      IF COALESCE(v_current_balance,0) <= 0 THEN
        RAISE EXCEPTION 'Demand % is already paid (balance=%). Another payment may have been posted - please refresh.', itm.dem_id, v_current_balance USING ERRCODE = 'P0001';
      END IF;
      -- Never take more than is owed. A receipt legitimately carries
      -- balance + fine, so the fine is part of the ceiling; anything above it
      -- is a stale screen or a double post, and collecting it creates money
      -- that has to be refunded later.
      IF itm.amount > COALESCE(v_current_balance,0) + COALESCE(v_current_fine,0) + 0.005 THEN
        RAISE EXCEPTION 'Collection of % on demand % exceeds the amount due (balance % + fine %). Please refresh and try again.',
          itm.amount, itm.dem_id, COALESCE(v_current_balance,0), COALESCE(v_current_fine,0) USING ERRCODE = 'P0001';
      END IF;
      v_new_paid:=COALESCE(v_current_paid,0)+itm.amount; v_new_balance:=COALESCE(v_current_balance,0)-itm.amount; IF v_new_balance<0 THEN v_new_balance:=0; END IF;
      -- For cash (auto-reconciled) payments, also sync reconbalancedue so
      -- the Pending Payment Report doesn't leave them as owed.
      IF LOWER(p_pay_method) = 'cash' THEN
        -- Reduce reconbalancedue by THIS payment only. It used to be set
        -- equal to balancedue, which silently declared every OTHER pending
        -- payment on the same demand reconciled as well -- see the header.
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1,balancedue=$2,reconbalancedue=GREATEST(COALESCE(reconbalancedue,0)-$5,0),paidstatus=CASE WHEN $2<=0 THEN ''P'' ELSE ''U'' END,pay_id=$3 WHERE dem_id=$4',v) USING v_new_paid,v_new_balance,v_pay_id,itm.dem_id,itm.amount;
      ELSE
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1,balancedue=$2,paidstatus=CASE WHEN $2<=0 THEN ''P'' ELSE ''U'' END,pay_id=$3 WHERE dem_id=$4',v) USING v_new_paid,v_new_balance,v_pay_id,itm.dem_id;
      END IF;
    END LOOP;
    EXECUTE format('UPDATE %I.payment SET transtotalamount=$1 WHERE pay_id=$2',v) USING v_group_total,v_pay_id;
    v_result := v_result || jsonb_build_object('pay_id',v_pay_id,'paynumber',v_pay_number,'fg_id',v_fg_id,'amount',v_group_total);
  END LOOP;
  RETURN v_result;
END; $function$;

-- ----------------------------------------------------------------------------
-- 3 -- advance collection: routed by settings, numbered from the routed
--      group's receipt sequence
--
--      This is the FINAL version -- ADVANCE_ROUTING_CONFIG then
--      ADVANCE_RECEIPT_SEQUENCE. It no longer reads an ADVNO sequence at all,
--      and refuses (naming the group) when that group has no receipt sequence.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_advance_collection(p_token text, p_header jsonb, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_ins integer; v_schema text; v_inscode varchar(10);
  v_yr_id integer; v_yrlabel varchar(20);
  v_seq_id int; v_cur numeric; v_width int; v_prefix text; v_advno text;
  v_adv_id bigint; v_amount numeric;
  v_paymode text; v_recon char(1);
  v_advtype char(1); v_lines_total numeric; v_line_count integer := 0;
  v_fg_id integer;
  v_route_fg integer; v_ban_id integer; v_route_set text;
  itm RECORD;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_advtype := UPPER(COALESCE(NULLIF(p_header->>'advtype',''), 'S'));
  IF v_advtype NOT IN ('A','S','M') THEN
    RAISE EXCEPTION 'Advance type must be A (admission), S (student) or M (mess)';
  END IF;

  v_amount := COALESCE((p_header->>'transtotalamount')::numeric, 0);

  IF v_advtype = 'A' THEN
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
      RAISE EXCEPTION 'An admission advance needs at least one fee type line';
    END IF;
    SELECT COALESCE(SUM((l->>'amount')::numeric), 0)
      INTO v_lines_total FROM jsonb_array_elements(p_lines) l;
    IF v_lines_total <= 0 THEN
      RAISE EXCEPTION 'The fee type amounts must add up to more than zero';
    END IF;
    -- The header total IS the sum of the lines. Taking the client's figure
    -- would let a receipt and its own breakdown tell different stories.
    v_amount := v_lines_total;
  ELSIF v_amount <= 0 THEN
    RAISE EXCEPTION 'Advance amount must be greater than zero';
  END IF;

  -- Same rule as save_misc_collection: cash never goes to reconciliation --
  -- there is no bank line to match it to, so it is realised the moment it is
  -- taken. Everything else waits for the bank. Hardcoding 'P' parked every
  -- cash advance in Bank Reconciliation forever.
  v_paymode := LOWER(COALESCE(NULLIF(p_header->>'paymethod',''), 'Cash'));
  v_recon   := CASE WHEN v_paymode LIKE '%cash%' THEN 'R' ELSE 'P' END;

  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;

  -- Year resolved server-side, like the other collection RPCs.
  EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
    INTO v_yr_id, v_yrlabel USING v_ins;

  IF v_advtype = 'A' THEN
    v_fg_id := NULLIF(p_lines->0->>'fg_id', '')::integer;
    IF v_fg_id IS NULL THEN
      -- Older client, or a line saved without its group: resolve it from the
      -- fee type the way adjust_advance does.
      EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft
                       WHERE ft.feedesc = $1 AND ft.activestatus = 1 LIMIT 1', v_schema)
        INTO v_fg_id USING (p_lines->0->>'feetype');
    END IF;
  END IF;

  -- WHICH ACCOUNT THIS ADVANCE BELONGS IN
  --
  --   'M' mess     -> the HOSTEL group: the one that owns a MESS fee type,
  --                   falling back to a group named like a hostel.
  --   'A' admission -> the group of the fee types it was itemised against,
  --                   which is already resolved above for the receipt number.
  --   'S' student  -> the COLLEGE group, falling back to the lowest fg_id,
  --                   which is the college group on every database so far.
  --
  -- Resolved SERVER-SIDE from the fee group, never taken from the client, so a
  -- cashier cannot send somebody else's account. If nothing resolves, ban_id
  -- stays NULL -- unrouted money is recoverable, money in the wrong account is
  -- an accounting problem.
  -- CONFIGURED, not guessed. public.institution_settings holds one key per
  -- advance type,
  --     advance_route_fg_A / advance_route_fg_S / advance_route_fg_M  ->  fg_id
  -- set in Setup -> Utilities -> Advance Settlement. Name matching (a fee type
  -- called MESS, a group called HOSTEL or COLLEGE) is kept BELOW as a fallback
  -- for an institution that has not configured it, so nothing changes for one
  -- that has not -- but a group called "MESS & ACCOMMODATION" or a third unit's
  -- group can now be routed to, which name matching could not do.
  v_route_fg := NULL;
  SELECT NULLIF(TRIM(s.setting_value), '') INTO v_route_set
    FROM public.institution_settings s
   WHERE s.ins_id = v_ins
     AND s.setting_key = 'advance_route_fg_' || v_advtype;

  -- Digits only, and it must be a live fee group IN THIS YEAR'S SCHEMA. Fee
  -- groups are per schema, so a setting left over from another year would
  -- otherwise bank the money against an account that is not this year's.
  IF v_route_set ~ '^[0-9]+$' THEN
    EXECUTE format('SELECT fg_id FROM %I.feegroup
                     WHERE fg_id = $1 AND ins_id = $2 AND activestatus = 1', v_schema)
      INTO v_route_fg USING v_route_set::int, v_ins;
  END IF;

  -- An admission advance is itemised AGAINST FEE TYPES, and those types name
  -- their own group. That is more specific than any configured default, so it
  -- wins -- the same rule as before.
  IF v_advtype = 'A' AND v_fg_id IS NOT NULL THEN
    v_route_fg := v_fg_id;
  END IF;

  -- ---- fallbacks, unchanged from BANK_ROUTING_BY_FEEGROUP.sql -------------
  IF v_route_fg IS NULL AND v_advtype = 'M' THEN
    EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft
                     WHERE ft.activestatus = 1 AND ft.feedesc ILIKE ''%%MESS%%''
                     ORDER BY ft.fg_id LIMIT 1', v_schema) INTO v_route_fg;
    IF v_route_fg IS NULL THEN
      EXECUTE format('SELECT fg_id FROM %I.feegroup
                       WHERE ins_id = $1 AND activestatus = 1
                         AND fgdesc ILIKE ''%%HOSTEL%%'' ORDER BY fg_id LIMIT 1', v_schema)
        INTO v_route_fg USING v_ins;
    END IF;
  END IF;
  IF v_route_fg IS NULL THEN
    EXECUTE format('SELECT fg_id FROM %I.feegroup
                     WHERE ins_id = $1 AND activestatus = 1
                       AND fgdesc ILIKE ''%%COLLEGE%%'' ORDER BY fg_id LIMIT 1', v_schema)
      INTO v_route_fg USING v_ins;
  END IF;
  IF v_route_fg IS NULL THEN
    EXECUTE format('SELECT fg_id FROM %I.feegroup
                     WHERE ins_id = $1 AND activestatus = 1 ORDER BY fg_id LIMIT 1', v_schema)
      INTO v_route_fg USING v_ins;
  END IF;
  IF v_route_fg IS NOT NULL THEN
    EXECUTE format('SELECT ban_id FROM %I.feegroup WHERE fg_id = $1', v_schema)
      INTO v_ban_id USING v_route_fg;
  END IF;


  -- ----------------------------------------------------------------------
  -- RECEIPT NUMBER -- one rule for all three types
  -- ----------------------------------------------------------------------
  -- Every advance is numbered from the RECEIPT sequence of the fee group it
  -- is banked under (Setup -> Sequence Master -> Receipt Sequence), the same
  -- series a fee receipt of that group comes from. The old ADVNO series is no
  -- longer read: it was a second numbering scheme for money that is banked
  -- exactly like the rest, and it could not tell a student advance banked into
  -- one account from a mess advance banked into another.
  --
  -- An ADMISSION advance already resolved its group from its fee lines above,
  -- and the routing block just above has put that same group in v_route_fg, so
  -- all three types read from one place.
  IF v_route_fg IS NULL THEN
    RAISE EXCEPTION 'This advance has no fee group to be banked under. Set it in Setup -> Utilities -> Advance Settlement.';
  END IF;

  EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5),
                         COALESCE(NULLIF(seqprefix,''''),
                                  regexp_replace(COALESCE(sequid,''''), ''[0-9]+$'', ''''))
                    FROM %I.sequence
                   WHERE ins_id=$1 AND fg_id=$2 AND activestatus=1
                   ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins, v_route_fg;

  IF v_seq_id IS NULL THEN
    -- Named, because "no sequence" on a screen with several fee groups is not
    -- something the cashier can act on.
    EXECUTE format('SELECT fgdesc FROM %I.feegroup WHERE fg_id=$1', v_schema)
      INTO v_prefix USING v_route_fg;
    RAISE EXCEPTION 'No receipt sequence for "%". Create one in Setup -> Sequence Master -> Receipt Sequence before collecting an advance into it.', COALESCE(v_prefix, 'that fee group');
  END IF;

  v_cur := v_cur + 1;
  v_advno := v_prefix || lpad(v_cur::bigint::text, v_width, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema)
    USING v_cur, v_seq_id;

  EXECUTE format($i$
    INSERT INTO %I.advance_collection
      (ins_id, inscode, stu_id, stuadmno, stuname, stuclass, courname, yr_id, yrlabel,
       advno, advdate, advtype, transtotalamount, paystatus, paymethod, payreference,
       payorderid, paytm_txnid, paychequeno, paychequedate, paybankname, ban_id,
       tender_amount, remarks, createdby, recon_status)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,
            $10, COALESCE($11::timestamp, now()), $12, $13, 'C', $14, $15,
            $16, $17, $18, $19, $20, $21,
            $22, $23, $24, $25)
    RETURNING adv_id$i$, v_schema)
  INTO v_adv_id
  USING v_ins, v_inscode,
        (p_header->>'stu_id')::bigint, p_header->>'stuadmno', p_header->>'stuname',
        p_header->>'stuclass', p_header->>'courname', v_yr_id, v_yrlabel,
        v_advno, NULLIF(p_header->>'advdate','')::timestamp, v_advtype, v_amount,
        p_header->>'paymethod', p_header->>'payreference',
        p_header->>'payorderid', p_header->>'paytm_txnid',
        p_header->>'paychequeno', NULLIF(p_header->>'paychequedate','')::date,
        p_header->>'paybankname', v_ban_id,
        NULLIF(p_header->>'tender_amount','')::numeric, p_header->>'remarks',
        p_header->>'createdby', v_recon;

  -- Fee-type breakdown: admission advances only.
  IF v_advtype = 'A' THEN
    FOR itm IN
      SELECT NULLIF(l->>'fee_id','')::integer  AS fee_id,
             NULLIF(l->>'fg_id','')::integer   AS fg_id,
             l->>'feetype'                     AS feetype,
             COALESCE((l->>'amount')::numeric, 0) AS amount
        FROM jsonb_array_elements(p_lines) l
    LOOP
      CONTINUE WHEN itm.amount <= 0 OR COALESCE(trim(itm.feetype), '') = '';
      EXECUTE format('INSERT INTO %I.advance_detail (adv_id, ins_id, fee_id, fg_id, feetype, amount)
                      VALUES ($1,$2,$3,$4,$5,$6)', v_schema)
        USING v_adv_id, v_ins, itm.fee_id, itm.fg_id, itm.feetype, itm.amount;
      v_line_count := v_line_count + 1;
    END LOOP;
    IF v_line_count = 0 THEN
      RAISE EXCEPTION 'An admission advance needs at least one fee type line with an amount';
    END IF;
  END IF;

  RETURN jsonb_build_object('adv_id', v_adv_id, 'advno', v_advno, 'amount', v_amount,
                            'advtype', v_advtype, 'lines', v_line_count,
                            'recon_status', v_recon,
                            'fg_id', v_route_fg, 'ban_id', v_ban_id);
END; $function$;

-- ----------------------------------------------------------------------------
-- 4 -- misc collection: receipts numbered from their own fee group's sequence
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_misc_collection(p_ins_id integer, p_header jsonb, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_schema text; v_mc_id bigint; v_total numeric; v_mcno text;
  v_route_fg integer; v_ban_id integer;
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


  -- ----------------------------------------------------------------------
  -- RECEIPT NUMBER -- from the group this receipt is banked under
  -- ----------------------------------------------------------------------
  -- It used to come from the FIRST sequence in the schema, whichever group the
  -- money was going to: a MESS FEE collected here was banked into the hostel
  -- account and numbered FC26/03067 out of the college run. The number and the
  -- account have to agree, so the number now comes from the routed group's own
  -- receipt sequence (Setup -> Sequence Master -> Receipt Sequence), exactly as
  -- a fee receipt and an advance already do.
  IF v_route_fg IS NULL THEN
    RAISE EXCEPTION 'This collection has no fee group to be banked under. Check the fee types on it.';
  END IF;

  EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), sequid, COALESCE(seqwidth::int,5)
                    FROM %I.sequence
                   WHERE ins_id=$1 AND fg_id=$2 AND activestatus=1
                   ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_cur, v_sequid, v_width USING p_ins_id, v_route_fg;

  IF v_seq_id IS NULL THEN
    -- Named: "no receipt sequence" on an institution with several fee groups
    -- is not something the cashier can act on.
    EXECUTE format('SELECT fgdesc FROM %I.feegroup WHERE fg_id=$1', v_schema)
      INTO v_prefix USING v_route_fg;
    RAISE EXCEPTION 'No receipt sequence for "%". Create one in Setup -> Sequence Master -> Receipt Sequence before collecting into it.', COALESCE(v_prefix, 'that fee group');
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

-- ----------------------------------------------------------------------------
-- 5 -- map a bank account to HOSTEL FEES, IF that group exists
--
--      Skipped with a notice when it does not, so this file can be run before
--      the group is created in Fee Master and again afterwards.
--
--      It prefers an account whose name mentions HOSTEL or MESS. Falling back
--      to the first account means both groups bank into the same place, which
--      is the very thing the routing exists to stop -- fine for testing split
--      receipts and nothing else. The verification says so when it happens.
-- ----------------------------------------------------------------------------
DO $map$
DECLARE
  v_fg   int;
  v_ban  int;
  v_name text;
BEGIN
  SELECT fg_id INTO v_fg
    FROM kcet20262027.feegroup
   WHERE ins_id = 1 AND fgdesc ILIKE '%HOSTEL%'
   ORDER BY fg_id LIMIT 1;

  IF v_fg IS NULL THEN
    RAISE NOTICE 'step 5 skipped: no fee group whose name contains HOSTEL. Create it in Fee Master, then re-run this file.';
    RETURN;
  END IF;

  SELECT ban_id, banname INTO v_ban, v_name
    FROM kcet20262027.bank
   WHERE ins_id = 1 AND activestatus = 1
     AND (banname ILIKE '%HOSTEL%' OR banname ILIKE '%MESS%')
   ORDER BY ban_id LIMIT 1;

  IF v_ban IS NULL THEN
    SELECT ban_id, banname INTO v_ban, v_name
      FROM kcet20262027.bank
     WHERE ins_id = 1 AND activestatus = 1
     ORDER BY ban_id LIMIT 1;
  END IF;

  IF v_ban IS NULL THEN
    RAISE NOTICE 'step 5 skipped: this institution has no active bank account. Add one in Setup -> Bank Details.';
    RETURN;
  END IF;

  UPDATE kcet20262027.feegroup
     SET ban_id = v_ban
   WHERE ins_id = 1 AND fg_id = v_fg;

  RAISE NOTICE 'HOSTEL FEES mapped to bank % (%)', v_ban, v_name;
END $map$;

COMMIT;


-- ----------------------------------------------------------------------------
-- 5b -- tell PostgREST the functions changed
--
--       Replacing a function does NOT invalidate PostgREST's schema cache. The
--       apps keep calling the old signature until it is reloaded, so a run
--       that reported nothing but OK above would still behave as if none of it
--       had happened -- or answer "Could not find the function ... in the
--       schema cache" outright. Outside the transaction, because NOTIFY only
--       fires on commit.
-- ----------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
NOTIFY pgrst, 'reload config';


-- ----------------------------------------------------------------------------
-- 6 -- VERIFY  (read-only -- this is the result grid you want to read)
--
--      Everything should say OK. Anything that does not is a step you still
--      have to do in the app, not a failure of this file.
-- ----------------------------------------------------------------------------
SELECT 'code: advance routed from settings' AS check,
       CASE WHEN pg_get_functiondef(p.oid) LIKE '%advance_route_fg_%'
            THEN 'OK' ELSE 'MISSING' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_advance_collection'

UNION ALL
-- Comments are stripped before matching: the replacement body MENTIONS the
-- old ADVNO series in a comment explaining why it is gone, and a plain ILIKE
-- reported that as a failure on a function that was perfectly correct.
SELECT 'code: advance uses a receipt sequence',
       CASE WHEN regexp_replace(pg_get_functiondef(p.oid), '--[^' || chr(10) || ']*', '', 'g')
                 NOT ILIKE '%ADVNO%'
            THEN 'OK' ELSE 'still reads ADVNO' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_advance_collection'

UNION ALL
SELECT 'code: misc numbered by fee group',
       CASE WHEN pg_get_functiondef(p.oid) LIKE '%fg_id%'
            THEN 'OK' ELSE 'MISSING' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_misc_collection'

UNION ALL
SELECT 'code: payment stamped with group bank',
       CASE WHEN pg_get_functiondef(p.oid) LIKE '%ban_id%'
            THEN 'OK' ELSE 'MISSING' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'process_grouped_payment'

UNION ALL
SELECT 'data: advtype checks (want exactly 1, allowing M)',
       CASE WHEN count(*) = 1 AND bool_and(pg_get_constraintdef(c.oid) LIKE '%M%')
            THEN 'OK' ELSE count(*) || ' check(s), M allowed: '
                 || bool_and(pg_get_constraintdef(c.oid) LIKE '%M%') END
  FROM pg_constraint c
 WHERE c.conrelid = 'kcet20262027.advance_collection'::regclass
   AND c.contype = 'c'
   AND pg_get_constraintdef(c.oid) ILIKE '%advtype%'

UNION ALL
SELECT 'setup: fee group ' || g.fgdesc,
       CASE WHEN g.ban_id IS NULL THEN 'NO BANK ACCOUNT -- Setup > Bank Details'
            WHEN NOT EXISTS (SELECT 1 FROM kcet20262027.sequence s
                              WHERE s.ins_id = g.ins_id AND s.fg_id = g.fg_id
                                AND s.activestatus = 1)
            THEN 'NO RECEIPT SEQUENCE -- Fee Master > Receipt Sequence'
            ELSE 'OK (bank ' || g.ban_id || ')' END
  FROM kcet20262027.feegroup g
 WHERE g.ins_id = 1 AND g.activestatus = 1

UNION ALL
SELECT 'setup: two groups share one bank account',
       CASE WHEN EXISTS (SELECT 1 FROM kcet20262027.feegroup g
                          WHERE g.ins_id = 1 AND g.activestatus = 1 AND g.ban_id IS NOT NULL
                          GROUP BY g.ban_id HAVING count(*) > 1)
            THEN 'YES -- money will not actually be split; give the hostel its own account'
            ELSE 'no' END

UNION ALL
SELECT 'setup: ' || k,
       COALESCE((SELECT left(s.setting_value, 40) FROM public.institution_settings s
                  WHERE s.ins_id = 1 AND s.setting_key = k),
                'NOT SET -- Utilities screen')
  FROM unnest(ARRAY['advance_route_fg_A','advance_route_fg_S','advance_route_fg_M',
                    'misc_collection_fee_groups']) AS k

 ORDER BY 1;
