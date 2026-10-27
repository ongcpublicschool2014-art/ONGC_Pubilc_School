-- =====================================================================
-- LIVE: everything desktop 0.0.10 needs. Run this whole file ONCE,
-- then release the installer.
--
-- From the live preflight on 2026-10-01:
--     Advance Collection (Admission)  NOT MAPPED -> 0.0.10 refuses it
--     Advance Collection (Student)    NOT MAPPED -> 0.0.10 refuses it
--     advtype constraint              REJECTS 'M' -> mess advance cannot save
--                                     (this has never worked on live)
--     complete_payment_grouped        stamps ban_id only for 'razorpay'
--
-- FEE COLLECTION IS NOT AT RISK either way: fee-group bank routing ships
-- DISABLED in 0.0.10 and only turns on for a machine whose config.json says
-- "feeGroupSettlement": true. This file does not change where money settles.
--
-- SECTION A  the four migrations, in the order that matters (A1/A2 replace
--            complete_payment_grouped and wipe the guards; A3/A4 restore them)
-- SECTION B  the advance type -> fee group mapping
-- SECTION C  the preflight again -- every row must read "ship it"
--
-- No receipt number is at risk: nothing here runs an INSERT, UPDATE or DELETE
-- against payment or sequence. Rehearsed end to end on TEST, which finished at
-- counter 3281, receipts held 3281, gaps 0.
--
-- No BEGIN: one Run commits it. Idempotent. Run it when the counter is quiet.
-- =====================================================================


-- #####################################################################
-- SECTION A -- the four migrations
-- #####################################################################
-- #####################################################################
-- PART 1 of 4
-- #####################################################################
-- ############################################################################
--
--   EduCore360 -- SETTLE EVERY COLLECTION INTO ITS FEE GROUP'S ACCOUNT
--   25-09-2026
--
--   Runs on either project and prints which one it ran on. The same routing is
--   wanted on TEST and on LIVE, so there is no refuse-guard: apply it to TEST,
--   satisfy yourself, then apply it to LIVE.
--
-- ----------------------------------------------------------------------------
-- WHAT CHANGES
-- ----------------------------------------------------------------------------
--   FEE COLLECTION   ban_id was stamped for ONLINE channels only; cash, cheque
--                    and DD were left NULL on the reasoning that counter cash
--                    all lands in one account. Now EVERY method routes by fee
--                    group -- 2,464 of 2,501 receipts on live carry no account
--                    today, which is why hostel cash cannot be told from
--                    college cash.
--
--   MISC COLLECTION  never stamped an account at all (799 rows, all NULL). Now
--                    routed by the fee group of the fee types collected, so a
--                    MESS FEE receipt lands in hostel and a BONAFIDE in
--                    college.
--
--   ADVANCE          gains a THIRD type, 'M' (mess), alongside 'A' admission
--                    and 'S' student. Admission and student route to the
--                    COLLEGE group's account; mess routes to the HOSTEL
--                    group's. ban_id is no longer accepted from the client.
--
-- ----------------------------------------------------------------------------
-- IT DOES NOT MOVE MONEY THAT IS ALREADY COLLECTED
-- ----------------------------------------------------------------------------
-- Only NEW collections are routed. Existing receipts keep whatever ban_id they
-- have, including NULL. Back-filling historical rows would re-state which
-- account past money went into, and that is a decision about the books, not a
-- migration -- ask and I will write it separately.
--
-- ----------------------------------------------------------------------------
-- BEFORE IT CAN WORK -- READ THIS
-- ----------------------------------------------------------------------------
-- HOSTEL FEES has NO BANK ACCOUNT MAPPED, and only one account exists. Until a
-- hostel account is created (Setup -> Bank Details) and mapped to the HOSTEL
-- FEES group (Fee Master), every mess collection resolves to ban_id NULL --
-- unrouted, exactly as today. Nothing breaks; the routing simply has nowhere
-- to send it. College routing works immediately.
--
-- Unrouted is the deliberate failure mode throughout: if no group resolves,
-- ban_id stays NULL rather than guessing. Money with no account is
-- recoverable; money in the wrong account is an accounting problem.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- CREATE OR REPLACE on three functions, and a CHECK constraint replaced to
-- admit 'M'. No row is inserted, updated or deleted.
--
-- The three bodies below were read out of the deployed database with
-- pg_get_functiondef and edited surgically, so nothing except the routing can
-- have drifted.
-- ############################################################################


-- ----------------------------------------------------------------------------
-- 1 -- advtype gains 'M' (mess), on every year schema
-- ----------------------------------------------------------------------------
DO $adv$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'advance_collection'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('ALTER TABLE %I.advance_collection DROP CONSTRAINT IF EXISTS chk_advance_advtype', r.s);
    EXECUTE format($q$ALTER TABLE %I.advance_collection
      ADD CONSTRAINT chk_advance_advtype CHECK (advtype = ANY(ARRAY['A','S','M']))$q$, r.s);
  END LOOP;
END $adv$;


-- ----------------------------------------------------------------------------
-- 2 -- fee collection: route EVERY method by fee group
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
-- 3 -- misc collection: route by the fee types collected
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
-- 4 -- advance: 'M' mess, and server-resolved routing
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
  v_route_fg integer; v_ban_id integer;
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

  -- Receipt number. The two types draw from DIFFERENT series.
  --
  --   'A' ADMISSION advance -> the PAYMENT sequence, the same series a fee
  --       receipt comes from (Fee Master -> Payment Sequence). It is collected
  --       fee type by fee type against an admission and later comes off the
  --       bill itself, so what the family is handed reads as a fee receipt. The
  --       fee group comes from the FIRST line, exactly as a collection numbers
  --       its receipt per fee group.
  --
  --   'S' STUDENT advance -> ADVNO (Fee Master -> Advance No), its own series:
  --       money HELD against the student rather than a fee paid, spent later
  --       through an adjustment.
  IF v_advtype = 'A' THEN
    v_fg_id := NULLIF(p_lines->0->>'fg_id', '')::integer;
    IF v_fg_id IS NULL THEN
      -- Older client, or a line saved without its group: resolve it from the
      -- fee type the way adjust_advance does.
      EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft
                       WHERE ft.feedesc = $1 AND ft.activestatus = 1 LIMIT 1', v_schema)
        INTO v_fg_id USING (p_lines->0->>'feetype');
    END IF;

    IF v_fg_id IS NOT NULL THEN
      EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5),
                             COALESCE(NULLIF(seqprefix,''''),
                                      regexp_replace(COALESCE(sequid,''''), ''[0-9]+$'', ''''))
                        FROM %I.sequence
                       WHERE ins_id=$1 AND fg_id=$2 AND activestatus=1
                       ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
        INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins, v_fg_id;
    END IF;
    -- A fee type whose group has no sequence of its own must not cost the
    -- cashier the collection: fall back to the institution's first payment
    -- sequence, which is the only one most colleges have.
    IF v_seq_id IS NULL THEN
      EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5),
                             COALESCE(NULLIF(seqprefix,''''),
                                      regexp_replace(COALESCE(sequid,''''), ''[0-9]+$'', ''''))
                        FROM %I.sequence
                       WHERE ins_id=$1 AND fg_id IS NOT NULL AND activestatus=1
                       ORDER BY fg_id, seq_id LIMIT 1 FOR UPDATE', v_schema)
        INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins;
    END IF;
    IF v_seq_id IS NULL THEN
      RAISE EXCEPTION 'No payment sequence configured. Add one in Fee Master → Payment Sequence first.';
    END IF;
  ELSE
    EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5), COALESCE(seqprefix,'''')
                      FROM %I.sequence
                     WHERE ins_id=$1 AND actname=''ADVNO'' AND activestatus=1
                     ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins;
    IF v_seq_id IS NULL THEN
      RAISE EXCEPTION 'No Advance No sequence configured. Add one in Fee Master → Advance No first.';
    END IF;
  END IF;
  v_cur := v_cur + 1;
  v_advno := v_prefix || lpad(v_cur::bigint::text, v_width, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_cur, v_seq_id;

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
  IF v_advtype = 'M' THEN
    EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft
                     WHERE ft.activestatus = 1 AND ft.feedesc ILIKE ''%%MESS%%''
                     ORDER BY ft.fg_id LIMIT 1', v_schema) INTO v_route_fg;
    IF v_route_fg IS NULL THEN
      EXECUTE format('SELECT fg_id FROM %I.feegroup
                       WHERE ins_id = $1 AND activestatus = 1
                         AND fgdesc ILIKE ''%%HOSTEL%%'' ORDER BY fg_id LIMIT 1', v_schema)
        INTO v_route_fg USING v_ins;
    END IF;
  ELSIF v_advtype = 'A' THEN
    v_route_fg := v_fg_id;
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


NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- 5 -- VERIFY
-- ----------------------------------------------------------------------------
SELECT 'project' AS what,
       CASE WHEN to_regclass('public._this_is_the_test_project') IS NOT NULL
            THEN 'TEST' ELSE 'LIVE' END AS value,
       'ran here' AS note

UNION ALL
SELECT 'fee collection routes all methods',
       CASE WHEN prosrc LIKE '%razorpay%' THEN 'NO - still online only' ELSE 'yes' END, ''
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'process_grouped_payment'

UNION ALL
SELECT 'misc collection routes by fee type',
       CASE WHEN prosrc LIKE '%v_route_fg%' THEN 'yes' ELSE 'NO' END, ''
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_misc_collection'

UNION ALL
SELECT 'advance accepts M (mess)',
       CASE WHEN prosrc LIKE '%A (admission), S (student) or M (mess)%' THEN 'yes' ELSE 'NO' END, ''
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_advance_collection'

UNION ALL
SELECT 'fee group -> account',
       g.fgdesc || ' -> ' || COALESCE(b.banname || ' ' || b.banaccno, 'NO ACCOUNT MAPPED'),
       CASE WHEN g.ban_id IS NULL THEN 'collections here will be unrouted' ELSE '' END
  FROM kcet20262027.feegroup g
  LEFT JOIN kcet20262027.bank b ON b.ban_id = g.ban_id
 WHERE g.activestatus = 1

 ORDER BY 1;


-- #####################################################################
-- PART 2 of 4
-- #####################################################################
-- ############################################################################
--
--   EduCore360 -- ONLINE PAYMENTS RECORD THE ACCOUNT THEY SETTLED TO
--   29-09-2026
--
--   Run the whole file. TEST first, then LIVE.
--
-- ----------------------------------------------------------------------------
-- THE BUG
-- ----------------------------------------------------------------------------
-- complete_payment_grouped is the RPC the PARENT APP finalises a payment with
-- (and the one the admin app's orphan sweep replays through). It stamped the
-- beneficiary bank like this:
--
--     ban_id = CASE WHEN LOWER(p_pay_method) = 'razorpay'
--                   THEN (SELECT ban_id FROM feegroup WHERE fg_id = ...)
--                   ELSE NULL END
--
-- The parent app pays through PAYTM. p_pay_method has not been 'razorpay'
-- since that switch, so the CASE has fallen to ELSE NULL on every mobile
-- payment ever taken through Paytm -- the row never recorded which account the
-- money went to.
--
-- process_grouped_payment (the admin app's counter collection) stamps it
-- unconditionally, which is why desktop receipts carry the right account and
-- mobile ones do not. Same money, same fee groups, two different rules.
--
-- ----------------------------------------------------------------------------
-- WHAT IT BREAKS
-- ----------------------------------------------------------------------------
-- 1. Per-bank reporting and reconciliation cannot classify a mobile payment at
--    all -- it looks unrouted, not misrouted.
--
-- 2. Worse, recovery. resolveStuckPayment (parent app) and the admin app's
--    _sweepOrphanedPayments both read payment.ban_id to decide WHICH PAYTM
--    MERCHANT to ask about an order, because an order is signed with its fee
--    group's merchant. With ban_id NULL they ask the institution's default
--    merchant, which answers "no such order" for a hostel payment -- and the
--    sweep then marks a payment the parent actually made as FAILED.
--
-- The money itself settled correctly: the order is signed with the merchant
-- the app resolved from the fee group before checkout. This fixes the RECORD
-- of where it went, and the recovery paths that depend on that record.
--
-- ----------------------------------------------------------------------------
-- WHAT IT DOES NOT DO
-- ----------------------------------------------------------------------------
-- It does not backfill the payments already written with ban_id NULL. Those
-- can be recovered from their fee group later if you want them classified --
-- deliberately left out of a function change so nothing rewrites settled money
-- as a side effect.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- One CREATE OR REPLACE. No row is read back or rewritten.
--
-- ############################################################################

CREATE OR REPLACE FUNCTION public.complete_payment_grouped(p_pay_id bigint, p_pay_method text, p_pay_reference text, p_items jsonb, p_ins_id integer, p_status character DEFAULT 'C'::bpchar)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v text; v_fg_id INTEGER; v_new_pay_id BIGINT; v_pay_number TEXT;
  v_seq RECORD; v_new_no INTEGER;
  v_current_paid NUMERIC; v_current_balance NUMERIC; v_current_fine NUMERIC;
  v_new_paid NUMERIC; v_new_balance NUMERIC;
  v_result JSONB := '[]'::jsonb;
  v_group_total NUMERIC;
  v_orig RECORD;
  itm RECORD; v_fg_ids INTEGER[];
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema found'; END IF;
  -- Get original payment info. FOR UPDATE locks the row so a concurrent call
  -- for the same p_pay_id blocks here, then finds it gone after the DELETE
  -- below — prevents duplicate receipts / double-decremented feedemand.
  EXECUTE format('SELECT ins_id,inscode,stu_id,yr_id,yrlabel,createdby,payorderid,payreference FROM %I.payment WHERE pay_id=$1 FOR UPDATE',v) INTO v_orig USING p_pay_id;
  IF v_orig IS NULL THEN RAISE EXCEPTION 'Payment % not found',p_pay_id; END IF;
  -- Empty p_items = finalize the existing row in place (failure path from the
  -- mobile app passes []). The original split-by-fee-group logic below would
  -- DELETE the row and create nothing in its place, causing the failed record
  -- to vanish — so short-circuit here.
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    EXECUTE format('UPDATE %I.payment SET paystatus=$1, paymethod=$2, payreference=COALESCE($3, payreference), paydate=NOW() WHERE pay_id=$4',v)
      USING p_status, p_pay_method, p_pay_reference, p_pay_id;
    RETURN jsonb_build_array(jsonb_build_object('pay_id', p_pay_id, 'paynumber', NULL, 'fg_id', NULL, 'amount', 0));
  END IF;
  -- Collect distinct fee groups
  v_fg_ids := ARRAY[]::INTEGER[];
  FOR itm IN SELECT x.dem_id, x.amount, x.demfeetype
    FROM jsonb_to_recordset(p_items) AS x(dem_id bigint, amount numeric, demfeetype text)
  LOOP
    v_fg_id := NULL;
    EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc=$1 AND ft.activestatus=1 LIMIT 1',v) INTO v_fg_id USING itm.demfeetype;
    IF v_fg_id IS NULL THEN v_fg_id := 0; END IF;
    IF NOT v_fg_id = ANY(v_fg_ids) THEN v_fg_ids := v_fg_ids || v_fg_id; END IF;
  END LOOP;
  -- Delete original I payment
  EXECUTE format('DELETE FROM %I.paymentdetails WHERE pay_id=$1',v) USING p_pay_id;
  EXECUTE format('DELETE FROM %I.payment WHERE pay_id=$1',v) USING p_pay_id;
  -- Create per-group payments
  FOREACH v_fg_id IN ARRAY v_fg_ids LOOP
    v_group_total := 0;
    v_pay_number := NULL;
    -- EVERY payment stamps ban_id from its own fee group, whatever the
    -- method -- the same rule process_grouped_payment uses. It used to be
    -- gated on the old gateway's name in paymethod; the parent app pays
    -- through Paytm now, so that test stopped matching at the switch and
    -- every mobile payment since has been written with ban_id NULL.
    EXECUTE format('INSERT INTO %1$I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,paydate,paystatus,paymethod,payreference,createdby,payorderid,recon_status,ban_id) VALUES($1,$2,$3,$4,$5,0,''INR'',NOW(),$6,$7,$8,$9,$10,''P'',(SELECT ban_id FROM %1$I.feegroup WHERE fg_id=$11 LIMIT 1)) RETURNING pay_id',v)
    INTO v_new_pay_id USING v_orig.ins_id,v_orig.inscode,v_orig.stu_id,v_orig.yr_id,v_orig.yrlabel,p_status,p_pay_method,p_pay_reference,v_orig.createdby,v_orig.payorderid,v_fg_id;
    -- Paynumber + sequence only for successful payments. Failed/cancelled
    -- rows stay paynumber=NULL so we don't burn a receipt number on a
    -- transaction that never settled.
    IF p_status = 'C' THEN
      v_seq := NULL;
      EXECUTE format('SELECT seq_id,sequid,seqwidth,seqcurno FROM %I.sequence WHERE ins_id=$1 AND fg_id=$2 LIMIT 1 FOR UPDATE',v) INTO v_seq USING p_ins_id,v_fg_id;
      IF v_seq IS NULL THEN v_pay_number:='PAY'||v_new_pay_id;
      ELSE v_new_no:=v_seq.seqcurno+1; v_pay_number:=regexp_replace(v_seq.sequid,'\d+$','')||lpad(v_new_no::TEXT,v_seq.seqwidth::INTEGER,'0'); EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2',v) USING v_new_no,v_seq.seq_id;
      END IF;
      EXECUTE format('UPDATE %I.payment SET paynumber=$1 WHERE pay_id=$2',v) USING v_pay_number,v_new_pay_id;
    END IF;
    -- Process demands
    FOR itm IN SELECT x.dem_id, x.amount, x.demfeetype
      FROM jsonb_to_recordset(p_items) AS x(dem_id bigint, amount numeric, demfeetype text)
    LOOP
      DECLARE v_item_fg INTEGER;
      BEGIN
        EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc=$1 AND ft.activestatus=1 LIMIT 1',v) INTO v_item_fg USING itm.demfeetype;
        IF v_item_fg IS NULL THEN v_item_fg := 0; END IF;
        IF v_item_fg != v_fg_id THEN CONTINUE; END IF;
      END;
      v_group_total := v_group_total + itm.amount;
      EXECUTE format('INSERT INTO %I.paymentdetails(pay_id,dem_id,yr_id,yrlabel,ins_id,transcurrency,transtotalamount) VALUES($1,$2,$3,$4,$5,''INR'',$6)',v) USING v_new_pay_id,itm.dem_id,v_orig.yr_id,v_orig.yrlabel,p_ins_id,itm.amount;
      -- Update feedemand only on success. Same locking strategy as the
      -- cash/cheque flow: SELECT ... FOR UPDATE serialises concurrent
      -- collectors on this dem_id; if balance is already <= 0 someone
      -- else paid first and we abort the whole txn (including payment
      -- inserts above) so no duplicate receipt is produced.
      IF p_status = 'C' THEN
        EXECUTE format('SELECT paidamount, balancedue, fineamount FROM %I.feedemand WHERE dem_id=$1 AND activestatus=1 FOR UPDATE', v)
          INTO v_current_paid, v_current_balance, v_current_fine USING itm.dem_id;
        IF COALESCE(v_current_balance, 0) <= 0 THEN
          RAISE EXCEPTION 'Demand % is already paid (balance=%). Another payment may have been posted concurrently - please refresh.', itm.dem_id, v_current_balance USING ERRCODE = 'P0001';
        END IF;
      -- Never take more than is owed. A receipt legitimately carries
      -- balance + fine, so the fine is part of the ceiling; anything above it
      -- is a stale screen or a double post, and collecting it creates money
      -- that has to be refunded later.
        IF itm.amount > COALESCE(v_current_balance,0) + COALESCE(v_current_fine,0) + 0.005 THEN
          RAISE EXCEPTION 'Collection of % on demand % exceeds the amount due (balance % + fine %). Please refresh and try again.',
            itm.amount, itm.dem_id, COALESCE(v_current_balance,0), COALESCE(v_current_fine,0) USING ERRCODE = 'P0001';
        END IF;
        EXECUTE format('UPDATE %I.feedemand
                          SET paidamount = COALESCE(paidamount, 0) + $1,
                              balancedue = GREATEST(COALESCE(balancedue, 0) - $1, 0),
                              paidstatus = CASE WHEN GREATEST(COALESCE(balancedue, 0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                              pay_id     = $2
                          WHERE dem_id = $3 AND activestatus = 1', v)
        USING itm.amount, v_new_pay_id, itm.dem_id;
      END IF;
    END LOOP;
    EXECUTE format('UPDATE %I.payment SET transtotalamount=$1 WHERE pay_id=$2',v) USING v_group_total,v_new_pay_id;
    v_result := v_result || jsonb_build_object('pay_id',v_new_pay_id,'paynumber',v_pay_number,'fg_id',v_fg_id,'amount',v_group_total);
  END LOOP;
  RETURN v_result;
END; $function$;

-- PostgREST caches function signatures; without this the apps keep calling the
-- old body. Outside any transaction, because NOTIFY only fires on commit.
NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- VERIFY
-- ----------------------------------------------------------------------------
SELECT 'complete_payment_grouped stamps ban_id unconditionally' AS check,
       CASE WHEN pg_get_functiondef(p.oid) LIKE '%razorpay%'
            THEN 'STILL GATED ON razorpay' ELSE 'OK' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'complete_payment_grouped'

UNION ALL
SELECT 'process_grouped_payment stamps ban_id unconditionally',
       CASE WHEN pg_get_functiondef(p.oid) LIKE '%EVERY payment stamps ban_id%'
            THEN 'OK' ELSE 'OLD VERSION -- run BANK_ROUTING_BY_FEEGROUP.sql' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'process_grouped_payment'

UNION ALL
SELECT 'completed payments with ban_id NULL (historical, not fixed here)',
       count(*)::text
  FROM kcet20262027.payment
 WHERE activestatus = 1 AND paystatus = 'C' AND ban_id IS NULL;


-- #####################################################################
-- PART 3 of 4  -- puts back the guard parts 1-2 just wiped
-- #####################################################################
-- =====================================================================
-- Stop a payment that already carries a RECEIPT NUMBER from being failed
-- or deleted. Two separate symptoms, one cause.
--
-- SYMPTOM 1 -- a FAILED transaction showing a receipt number.
--   set_payment_status is a bare UPDATE ... WHERE pay_id = $5. The parent
--   app's failure path calls it with 'F', and nothing stops it flipping a
--   row that has already produced a receipt. On 2026-10-01 that put
--   FC26/03272 and FC26/03273 (Rs 3,600, captured by Paytm) on the failed
--   list, so the collection reports under-counted real money.
--
-- SYMPTOM 2 -- gaps in the receipt register.
--   complete_payment_grouped ends by deleting the original payment row:
--   DELETE FROM payment WHERE pay_id = $1, unconditional. Run twice for the
--   same payment -- a retry -- the second run DELETES the row holding the
--   first receipt number and draws a fresh one. The old number is gone from
--   the register while the counter has moved past it. That is FC26/03268 and
--   FC26/03270: each sits immediately before a receipt for the same student.
--
-- The rule both now follow: a receipt number, once drawn and attached, is a
-- record of money. Nothing may silently fail it or delete it.
--
-- Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Never fail a receipted payment.
--    Other transitions still work, so a pending row can still be completed
--    or failed normally; only a row that already produced a receipt is
--    protected, and only from being marked failed or cancelled.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_payment_status(
  p_ins_id integer, p_pay_id bigint, p_status text DEFAULT NULL::text,
  p_method text DEFAULT NULL::text, p_reference text DEFAULT NULL::text,
  p_touch_date boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout TO '15s'
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE v text; v_no text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;

  IF p_status IN ('F','I') THEN
    EXECUTE format('SELECT paynumber FROM %I.payment WHERE pay_id = $1', v)
      INTO v_no USING p_pay_id;
    IF COALESCE(v_no,'') <> '' THEN
      -- The receipt exists and the demand behind it has been credited.
      -- Marking it failed would hide money the college has actually taken.
      RAISE EXCEPTION
        'Payment % already carries receipt % and cannot be marked %. '
        'If the money must be given back, raise a refund.',
        p_pay_id, v_no, p_status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  EXECUTE format(
    'UPDATE %I.payment SET '
    'paystatus = COALESCE($1, paystatus), '
    'paymethod = COALESCE($2, paymethod), '
    'payreference = COALESCE($3, payreference), '
    'paydate = CASE WHEN $4 THEN now() ELSE paydate END '
    'WHERE pay_id = $5', v)
  USING p_status, p_method, p_reference, p_touch_date, p_pay_id;
END; $function$;

GRANT EXECUTE ON FUNCTION public.set_payment_status(integer, bigint, text, text, text, boolean)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. Never delete a receipted payment.
--    complete_payment_grouped is long and handles the money, so it is NOT
--    rewritten here. Only its final DELETE is narrowed, by replacing the
--    function source in place: the row is removed only while it has no
--    receipt number, which is the case it was written for (the temporary
--    'I' row). A retry then leaves the first receipt standing instead of
--    destroying it, and no number is lost.
-- ---------------------------------------------------------------------
DO $patch$
DECLARE src text; newsrc text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc
   WHERE proname = 'complete_payment_grouped' AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'complete_payment_grouped not found';
  END IF;

  -- Test for the guard BEFORE attempting the replace. The unguarded DELETE is a
  -- PREFIX of the guarded one, so replace() happily matches an already-patched
  -- source and appends the predicate a second time -- which is what produced
  -- `AND paynumber IS NULL AND paynumber IS NULL` on TEST. Checking first makes
  -- re-running genuinely idempotent.
  -- Repair the doubling an earlier, non-idempotent run of this script left
  -- behind. `AND paynumber IS NULL AND paynumber IS NULL` is harmless logically
  -- but it is not what anyone reading the function should find.
  IF position('AND paynumber IS NULL AND paynumber IS NULL' in src) > 0 THEN
    EXECUTE replace(src, 'AND paynumber IS NULL AND paynumber IS NULL',
                         'AND paynumber IS NULL');
    RAISE NOTICE 'complete_payment_grouped: collapsed a duplicated guard predicate';
    RETURN;
  END IF;

  IF position('AND paynumber IS NULL' in src) > 0 THEN
    RAISE NOTICE 'complete_payment_grouped already guarded -- nothing to do';
    RETURN;
  END IF;

  newsrc := replace(
    src,
    'DELETE FROM %I.payment WHERE pay_id=$1',
    'DELETE FROM %I.payment WHERE pay_id=$1 AND paynumber IS NULL');

  IF newsrc = src THEN
    RAISE EXCEPTION 'REFUSED: the expected DELETE was not found, so the '
                    'function has changed shape. Patch it by hand.';
  END IF;

  EXECUTE newsrc;
  RAISE NOTICE 'complete_payment_grouped: delete now skips receipted rows';
END $patch$;


-- #####################################################################
-- PART 4 of 4  -- puts back the guard parts 1-2 just wiped
-- #####################################################################
-- =====================================================================
-- Refuse to re-process a payment that has already produced a receipt.
--
-- WHY THIS IS NEEDED ON TOP OF PROTECT_RECEIPTED_PAYMENTS.
-- That migration narrowed the final delete to `AND paynumber IS NULL`, so a
-- numbered row can no longer be destroyed. On its own that is not enough, and
-- is arguably worse: if complete_payment_grouped is entered with a row that
-- already carries a receipt, it now
--     1. reads that row,
--     2. creates a SECOND receipt with a new number,
--     3. fails to delete the first, because the guard protects it,
-- leaving two receipts for one payment and the demand credited twice. That
-- trades a cosmetic gap in the register for real double-counted money.
--
-- The honest fix is to refuse at the door. A payment that has produced a
-- receipt is finished; whatever the caller wants, re-running the collection
-- is not it. The caller gets a clear error instead of a silent second receipt.
--
-- This also removes the need to delete a numbered row at all, so the two
-- guards agree: a receipt, once drawn, is immutable.
--
-- Patches the deployed source in place rather than restating 100 lines of
-- money logic, and refuses if the function has changed shape.
--
-- Safe to re-run.
-- =====================================================================
DO $patch$
DECLARE src text; newsrc text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc
   WHERE proname = 'complete_payment_grouped'
     AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'complete_payment_grouped not found';
  END IF;

  IF position('already produced receipt' in src) > 0 THEN
    RAISE NOTICE 'already guarded -- nothing to do';
    RETURN;
  END IF;

  -- 1. carry paynumber out of the row it already locks FOR UPDATE, so the
  --    check costs nothing extra and cannot race another collector.
  newsrc := replace(
    src,
    'SELECT ins_id,inscode,stu_id,yr_id,yrlabel,createdby,payorderid,payreference FROM %I.payment WHERE pay_id=$1 FOR UPDATE',
    'SELECT ins_id,inscode,stu_id,yr_id,yrlabel,createdby,payorderid,payreference,paynumber FROM %I.payment WHERE pay_id=$1 FOR UPDATE');
  IF newsrc = src THEN
    RAISE EXCEPTION 'REFUSED: the expected SELECT ... FOR UPDATE was not found.';
  END IF;
  src := newsrc;

  -- 2. refuse the moment we know the row is already receipted, before any
  --    number is drawn or any row is written.
  newsrc := replace(
    src,
    'IF v_orig IS NULL THEN RAISE EXCEPTION ''Payment % not found'',p_pay_id; END IF;',
    'IF v_orig IS NULL THEN RAISE EXCEPTION ''Payment % not found'',p_pay_id; END IF;' || E'\n' ||
    '  -- A payment that has produced a receipt is finished. Re-running the' || E'\n' ||
    '  -- collection would raise a SECOND receipt and credit the demand twice.' || E'\n' ||
    '  IF COALESCE(v_orig.paynumber,'''') <> '''' THEN' || E'\n' ||
    '    RAISE EXCEPTION ''Payment % has already produced receipt %'',' || E'\n' ||
    '      p_pay_id, v_orig.paynumber USING ERRCODE = ''check_violation'';' || E'\n' ||
    '  END IF;');
  IF newsrc = src THEN
    RAISE EXCEPTION 'REFUSED: the expected not-found check was not located.';
  END IF;

  EXECUTE newsrc;
  RAISE NOTICE 'complete_payment_grouped now refuses an already-receipted payment';
END $patch$;


-- #####################################################################

-- #####################################################################
-- SECTION B -- advance type -> fee group
--
-- Admission and Student advances route to COLLEGE FEES (the FC26/ series).
-- Mess is already mapped and is left alone; if mess advances should be
-- numbered in the HOSTEL series instead, that is a deliberate change --
-- the statement is at the bottom of SET_ADVANCE_SETTLEMENT_MAPPING.sql.
-- #####################################################################
INSERT INTO public.institution_settings (ins_id, setting_key, setting_value, updatedat, updatedby)
VALUES (1, 'advance_route_fg_A', '1', now(), 'ADMIN'),
       (1, 'advance_route_fg_S', '1', now(), 'ADMIN')
ON CONFLICT (ins_id, setting_key)
DO UPDATE SET setting_value = EXCLUDED.setting_value,
              updatedat     = EXCLUDED.updatedat,
              updatedby     = EXCLUDED.updatedby;


-- #####################################################################
-- SECTION C -- preflight. EVERY ROW MUST READ "ship it".
-- #####################################################################
SELECT * FROM (

-- ---------------------------------------------------------------------
-- 1. FEE COLLECTION -- the main counter screen.
--    0.0.10 adds no database dependency here. Fee-group bank routing ships
--    DISABLED (kFeeGroupSettlement is false unless a machine's config.json
--    opts in), so payments resolve the institution merchant exactly as 0.0.9
--    does. Listed so it is on the record, not because it can fail.
-- ---------------------------------------------------------------------
SELECT 1 AS ord,
       'Fee Collection' AS screen,
       'no new dependency - routing ships off' AS finding,
       'ship it' AS action

-- ---------------------------------------------------------------------
-- 2. ADVANCE COLLECTION -- blocked unless every type maps to a fee group.
--    0.0.10 refuses to take an advance whose type is not mapped, because an
--    unmapped advance has no fee group, so no receipt series and no account.
--    An UNMAPPED type that the cashier uses today will stop working.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 2,
       'Advance Collection (' ||
         CASE k.key_suffix WHEN 'A' THEN 'Admission'
                           WHEN 'S' THEN 'Student'
                           ELSE 'Mess' END || ')',
       CASE WHEN COALESCE(trim(s.setting_value), '') = ''
              THEN 'NOT MAPPED - this type will be refused'
            WHEN g.fg_id IS NULL
              THEN 'mapped to fee group ' || s.setting_value || ' which does not exist'
            ELSE 'mapped to ' || g.fgdesc END,
       CASE WHEN COALESCE(trim(s.setting_value), '') = '' OR g.fg_id IS NULL
              THEN 'run SET_ADVANCE_SETTLEMENT_MAPPING.sql first'
            ELSE 'ship it' END
  FROM (VALUES ('A'), ('S'), ('M')) AS k(key_suffix)
  LEFT JOIN public.institution_settings s
         ON s.ins_id = 1
        AND s.setting_key = 'advance_route_fg_' || k.key_suffix
  LEFT JOIN kcet20262027.feegroup g
         ON g.fg_id = NULLIF(trim(s.setting_value), '')::int
        AND g.ins_id = 1 AND g.activestatus = 1

-- ---------------------------------------------------------------------
-- 3. MESS ADVANCE -- needs the advtype CHECK to admit 'M'.
--    The screen offers Mess as a type. If the constraint still allows only
--    'A' and 'S', saving one fails with a constraint violation.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 3,
       'Advance Collection (Mess) - advtype constraint',
       CASE WHEN pg_get_constraintdef(c.oid) LIKE '%''M''%'
            THEN 'allows M' ELSE 'REJECTS M - a mess advance cannot be saved' END,
       CASE WHEN pg_get_constraintdef(c.oid) LIKE '%''M''%'
            THEN 'ship it'
            ELSE 'run PART 1 of LIVE_BANK_ROUTING_BUNDLE.sql first' END
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE n.nspname = 'kcet20262027' AND t.relname = 'advance_collection'
   AND c.conname = 'chk_advance_advtype'

-- ---------------------------------------------------------------------
-- 4. The ban_id fix. NOT a blocker for 0.0.10, but it is the reason real
--    payments get marked FAILED: with payment.ban_id NULL the orphan sweep
--    asks the WRONG Paytm merchant about an order, is told "no such order",
--    and writes the payment off. 0.0.10's sweep fix helps but cannot see an
--    order it is asking the wrong merchant about.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 4,
       'Orphan sweep asks the right Paytm merchant',
       CASE WHEN prosrc LIKE '%razorpay%'
            THEN 'NO - complete_payment_grouped stamps ban_id only for razorpay'
            ELSE 'yes' END,
       CASE WHEN prosrc LIKE '%razorpay%'
            THEN 'not a blocker, but run PART 2 - it is losing receipts'
            ELSE 'ship it' END
  FROM pg_proc
 WHERE proname = 'complete_payment_grouped' AND pronamespace = 'public'::regnamespace

-- ---------------------------------------------------------------------
-- 5. The double-receipt guard, rolled back on live earlier today.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 5,
       'Refuses re-receipting an already-paid row',
       CASE WHEN prosrc LIKE '%already produced receipt%'
            THEN 'yes' ELSE 'NO - a retry can raise a SECOND receipt' END,
       CASE WHEN prosrc LIKE '%already produced receipt%'
            THEN 'ship it'
            ELSE 'not a blocker, but run PART 4' END
  FROM pg_proc
 WHERE proname = 'complete_payment_grouped' AND pronamespace = 'public'::regnamespace

-- ---------------------------------------------------------------------
-- 6. The register, for reassurance.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 6, 'Receipt register continuous',
       (SELECT count(*)::text FROM public.check_receipt_gaps(1)) || ' gaps',
       CASE WHEN (SELECT count(*) FROM public.check_receipt_gaps(1)) = 0
            THEN 'ship it' ELSE 'investigate before releasing' END

) r ORDER BY r.ord, r.screen;
