-- =====================================================================
-- LIVE -- the 03-10-2026 evening release. EVERYTHING, ONE RUN.
--
-- Run AFTER LIVE_ALL_2026_10_03.sql, which is already on live.
-- One transaction: if any part fails, nothing is applied.
--
-- WHAT THIS CLOSES
--
--   A  REFUSALS STOP BEING SILENT. When Paytm confirms money and the database
--      declines to receipt it -- demand already settled another way, no detail
--      lines, amount mismatch, or no record of the order at all -- the refusal
--      is right, but it was a line in an edge function log nobody reads while
--      Paytm held money with no receipt. Now a row in webhook_refusal, and a
--      warning in fee_health_check().
--
--   B  MISC AND ADVANCE CAN BE CAPTURED AT ALL. Fee collection writes an 'I'
--      row BEFORE contacting Paytm, which is what lets a late capture be
--      receipted. Misc and advance wrote NOTHING until the payment succeeded
--      -- "Paytm takes the money BEFORE the receipt exists" -- so a capture
--      landing after the counter moved on had no amount, no student and no fee
--      types to work from. They now record an intent first.
--
--   C  THE APP RECOVERS THEM WITHOUT THE WEBHOOK. A webhook is the wrong
--      thing for money to depend on: it must be deployed, Paytm must be
--      configured to call it, and there is one callback URL for one Paytm
--      account. The admin app now sweeps open intents the same way it sweeps
--      orphaned fee payments.
--
--   D  A RECOVERED RECEIPT KEEPS THE DAY THE MONEY WAS TAKEN. The save
--      functions stamp now() -- right for a collection happening now, wrong
--      for one recovered a day later. JAYASURYA, 30-09-2026: Rs 2,000 and
--      Rs 1,600 debited that evening, captured around midnight; receipted the
--      next morning they would carry 1 OCTOBER, leaving 30 September short by
--      Rs 3,600 and never tying against the Paytm report. The honest date is
--      the intent's created_at -- stamped by this server before the gateway
--      was contacted, never a workstation clock.
--
-- Changes no existing receipt, demand, payment or sequence.
--
-- THE APPS AND THE EDGE FUNCTION ARE SEPARATE, AND MUST COME AFTER THIS:
--   supabase functions deploy paytm-webhook \
--     --project-ref exasnbapvgfeooxyxjas --no-verify-jwt
--   then the admin app build, then the parent app build.
-- Deploying the function BEFORE this runs makes it call functions that do not
-- exist yet -- the calls are wrapped, so nothing breaks, but refusals would go
-- unrecorded until it is redeployed.
-- =====================================================================

-- #####################################################################
-- GATE -- says which database this is, and refuses if money is moving.
-- #####################################################################
DO $gate$
DECLARE n_recent int; n_flight int; n_misc int; v_env text;
BEGIN
  v_env := CASE WHEN to_regclass('public._this_is_the_test_project') IS NOT NULL
                THEN 'TEST' ELSE 'LIVE' END;

  SELECT count(*) INTO n_recent FROM kcet20262027.payment
   WHERE createdat > now() - interval '2 minutes';
  SELECT count(*) INTO n_flight FROM kcet20262027.payment
   WHERE paystatus = 'I' AND activestatus = 1
     AND createdat > now() - interval '15 minutes';
  SELECT count(*) INTO n_misc FROM kcet20262027.misc_collection
   WHERE createdat > now() - interval '2 minutes';

  IF n_recent > 0 OR n_flight > 0 OR n_misc > 0 THEN
    RAISE EXCEPTION
      'REFUSED on %: the counter is busy -- % collection(s), % misc receipt(s) '
      'in the last 2 minutes, % payment(s) in flight. This replaces functions '
      'on the collection path and takes a brief lock. Nothing has been '
      'changed. Wait a few minutes and run it again.',
      v_env, n_recent, n_misc, n_flight
      USING ERRCODE = 'check_violation';
  END IF;

  RAISE NOTICE 'gate passed on %: the counter is quiet', v_env;
END $gate$;


-- #####################################################################
-- PART A
-- #####################################################################
-- =====================================================================
-- Make a REFUSED capture visible.
--
-- THE GAP. When Paytm confirms a payment late -- debited from the family,
-- pending for hours, settled afterwards -- the webhook raises the receipt.
-- But in three cases it correctly REFUSES:
--
--   * 'demand(s) no longer owe this - settled another way'
--        the family gave up waiting and paid at the counter, so crediting
--        the demand again would create money that has to be refunded
--   * 'attempt has no detail lines - cannot tell which fees it paid'
--   * amount mismatch -- Paytm took a different figure than we asked for
--        (caught in the edge function, before it ever calls this)
--
-- Each refusal is RIGHT. The problem is what happens next: the function
-- returns {ok:false, reason}, the edge function logs it and answers 200 --
-- deliberately, because a retry would not help and Paytm would keep trying
-- forever. So the outcome is: PAYTM HAS THE MONEY, THE COLLEGE HAS NO
-- RECEIPT, and the only trace is a line in an edge function log nobody
-- reads. If the attempt had already been marked 'F', even
-- fee_health_check() will not see it -- that check looks for 'I' rows.
--
-- This is the same invisibility that cost Rs 8,000 on 01-10-2026, arriving
-- through a different door.
--
-- WHAT THIS DOES. Records every refusal in a table, and adds one invariant
-- to fee_health_check() so an unresolved refusal shows up as a WARNING like
-- anything else. It changes no decision: every refusal that happened before
-- still happens, for the same reason. It only stops them being silent.
--
-- Nothing is auto-corrected. A refused capture needs a person to decide
-- whether to refund the family or receipt the money, and that is not a
-- decision a migration should make.
--
-- Idempotent. Touches no payment, demand or receipt.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Where refusals live.
--
-- Keyed by ORDER id, not pay_id: a refusal outlives the attempt it came
-- from (complete_payment_grouped replaces payment rows), and the order id
-- is the one identifier Paytm and the database agree on.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.webhook_refusal (
  order_id        text PRIMARY KEY,
  ins_id          integer,
  pay_id          bigint,
  reason          text        NOT NULL,
  amount          numeric(12,2),
  times_seen      integer     NOT NULL DEFAULT 1,
  first_seen      timestamptz NOT NULL DEFAULT now(),
  last_seen       timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz,
  resolved_by     text,
  resolution_note text
);

COMMENT ON TABLE public.webhook_refusal IS
  'Captures Paytm confirmed but the database refused to receipt. Each row is '
  'money the college has received with no receipt against it, awaiting a '
  'human decision: refund the family, or receipt it another way.';

CREATE INDEX IF NOT EXISTS webhook_refusal_unresolved
  ON public.webhook_refusal (last_seen) WHERE resolved_at IS NULL;

-- Service role only. A client must never be able to write here -- a forged
-- row would be read as "money received" by whoever works the list.
REVOKE ALL ON public.webhook_refusal FROM PUBLIC, anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. Record one. Callable by the edge function for the amount-mismatch
--    case, which never reaches webhook_complete_payment.
--
-- A webhook retry must not pile up rows: the same order updates in place
-- and counts. An ALREADY RESOLVED row is reopened only if the reason has
-- changed -- otherwise a retry would undo somebody's work.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.webhook_record_refusal(
  p_order_id text, p_reason text,
  p_ins_id integer DEFAULT NULL, p_pay_id bigint DEFAULT NULL,
  p_amount numeric DEFAULT NULL
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  INSERT INTO public.webhook_refusal
         (order_id, ins_id, pay_id, reason, amount)
  VALUES (p_order_id, p_ins_id, p_pay_id, p_reason, p_amount)
  ON CONFLICT (order_id) DO UPDATE
     SET times_seen  = public.webhook_refusal.times_seen + 1,
         last_seen   = now(),
         reason      = EXCLUDED.reason,
         ins_id      = COALESCE(EXCLUDED.ins_id, public.webhook_refusal.ins_id),
         pay_id      = COALESCE(EXCLUDED.pay_id, public.webhook_refusal.pay_id),
         amount      = COALESCE(EXCLUDED.amount, public.webhook_refusal.amount),
         resolved_at = CASE WHEN public.webhook_refusal.reason IS DISTINCT FROM EXCLUDED.reason
                            THEN NULL ELSE public.webhook_refusal.resolved_at END;
$$;

REVOKE ALL ON FUNCTION public.webhook_record_refusal(text, text, integer, bigint, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.webhook_record_refusal(text, text, integer, bigint, numeric)
  TO service_role;


-- ---------------------------------------------------------------------
-- 3. Close one, once a person has dealt with it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_webhook_refusal(
  p_order_id text, p_by text, p_note text
) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  UPDATE public.webhook_refusal
     SET resolved_at = now(), resolved_by = p_by, resolution_note = p_note
   WHERE order_id = p_order_id AND resolved_at IS NULL
  RETURNING true;
$$;

REVOKE ALL ON FUNCTION public.resolve_webhook_refusal(text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_webhook_refusal(text, text, text)
  TO service_role;


-- ---------------------------------------------------------------------
-- 4. webhook_complete_payment now records what it refuses.
--
-- Identical decisions to the deployed version -- the refusals, their
-- wording and their return shapes are unchanged. The only additions are
-- the webhook_record_refusal calls, and clearing the record on the path
-- that succeeds so a later success closes an earlier refusal.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.webhook_complete_payment(
  p_order_id text, p_reference text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_pay_id bigint;
  v_items jsonb; v_bad integer; v_res jsonb; v_amt numeric;
BEGIN
  SELECT f.pay_id, f.ins_id, f.transtotalamount
    INTO v_pay_id, v_ins, v_amt
    FROM public.webhook_find_payment(p_order_id) f;

  IF v_pay_id IS NULL THEN
    -- No row at all. Before 03-10-2026 this was the common way money went
    -- missing: create_pending_payment deleted the attempt when the family
    -- tapped Pay again, so a late capture had nothing to land on.
    PERFORM public.webhook_record_refusal(
      p_order_id, 'no payment row - the attempt is gone', NULL, NULL, NULL);
    RETURN jsonb_build_object('ok', false, 'reason', 'no payment row');
  END IF;

  v_schema := get_institution_schema(v_ins);

  -- Already receipted? Nothing to do. This is the retry path and must be
  -- silent, not an error.
  IF EXISTS (SELECT 1 FROM public.webhook_find_payment(p_order_id) f
              WHERE f.paystatus = 'C') THEN
    RETURN jsonb_build_object('ok', true, 'reason', 'already receipted');
  END IF;

  EXECUTE format(
    'SELECT jsonb_agg(jsonb_build_object(
              ''dem_id'', d.dem_id, ''amount'', d.transtotalamount,
              ''demfeetype'', f.demfeetype))
       FROM %I.paymentdetails d
       JOIN %I.feedemand f ON f.dem_id = d.dem_id
      WHERE d.pay_id = $1 AND d.activestatus = 1', v_schema, v_schema)
    INTO v_items USING v_pay_id;

  IF v_items IS NULL THEN
    PERFORM public.webhook_record_refusal(
      p_order_id, 'attempt has no detail lines - cannot tell which fees it paid',
      v_ins, v_pay_id, v_amt);
    RETURN jsonb_build_object('ok', false,
      'reason', 'attempt has no detail lines - cannot tell which fees it paid');
  END IF;

  EXECUTE format(
    'SELECT COUNT(*) FROM jsonb_array_elements($1) x
       JOIN %I.feedemand f ON f.dem_id = (x->>''dem_id'')::bigint
      WHERE f.activestatus <> 1
         OR COALESCE(f.balancedue,0) < (x->>''amount'')::numeric', v_schema)
    INTO v_bad USING v_items;

  IF v_bad > 0 THEN
    PERFORM public.webhook_record_refusal(
      p_order_id,
      format('%s demand(s) no longer owe this - settled another way', v_bad),
      v_ins, v_pay_id, v_amt);
    RETURN jsonb_build_object('ok', false,
      'reason', format('%s demand(s) no longer owe this - settled another way', v_bad));
  END IF;

  v_res := public.complete_payment_grouped(
    p_pay_id => v_pay_id, p_pay_method => 'Online Transfer',
    p_pay_reference => p_reference, p_items => v_items,
    p_ins_id => v_ins, p_status => 'C');

  -- A refusal that later succeeded is closed by the success itself.
  UPDATE public.webhook_refusal
     SET resolved_at = now(), resolved_by = 'WEBHOOK',
         resolution_note = 'receipted on a later callback'
   WHERE order_id = p_order_id AND resolved_at IS NULL;

  RETURN jsonb_build_object('ok', true, 'receipts', v_res);
END; $$;

REVOKE ALL ON FUNCTION public.webhook_complete_payment(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.webhook_complete_payment(text, text) TO service_role;


-- ---------------------------------------------------------------------
-- 5. fee_health_check() gains check 8.
--
-- Appended by rewriting the tail of the deployed function rather than
-- restating all seven existing checks, which would risk transcribing one
-- of them wrongly. The whole body is read, the new block inserted before
-- the loop ends, and the result installed.
-- ---------------------------------------------------------------------
DO $patch$
DECLARE src text; marker text; addition text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc
   WHERE proname = 'fee_health_check' AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'fee_health_check not found -- run FEE_HEALTH_CHECK.sql first';
  END IF;

  IF src LIKE '%captures Paytm confirmed but we refused%' THEN
    RAISE NOTICE 'check 8 already present';
    RETURN;
  END IF;

  -- The loop's last statement is the END of the receipt-register block.
  marker := '  END LOOP;';
  IF position(marker in src) = 0 THEN
    RAISE EXCEPTION 'could not find the loop end in fee_health_check -- not patched';
  END IF;

  addition :=
    E'\n    -- 8. Captures Paytm confirmed that the database refused to receipt.\n'
    '    --    Each is money the college HAS, with no receipt against it. The\n'
    '    --    refusal was right; being invisible was not.\n'
    '    SELECT count(*) INTO n FROM public.webhook_refusal r\n'
    '     WHERE r.resolved_at IS NULL AND COALESCE(r.ins_id, i.id) = i.id;\n'
    '    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN ''WARNING'' ELSE ''ok'' END,\n'
    '      ''captures Paytm confirmed but we refused'', n,\n'
    '      CASE WHEN n > 0 THEN ''money received with no receipt -- see public.webhook_refusal''\n'
    '           ELSE ''no refused captures outstanding'' END;\n\n';

  src := overlay(src placing addition from position(marker in src) for 0);
  EXECUTE src;
  RAISE NOTICE 'fee_health_check: check 8 added';
END $patch$;

NOTIFY pgrst, 'reload schema';


-- #####################################################################
-- PART B
-- #####################################################################
-- =====================================================================
-- The webhook can capture MISC COLLECTION and ADVANCE too.
--
-- THE GAP. Fee collection writes an 'I' payment row BEFORE it contacts
-- Paytm, carrying the fee lines in `payitems`. That row is what lets a late
-- capture be receipted hours later.
--
-- Misc and advance do neither. From misc_collection_screen.dart:
--
--     "Paytm takes the money BEFORE the receipt exists."
--     "A misc collection has no payment row to derive an order id from,
--      so it carries its own."
--
-- They sign an order as MISC<ins>T<ms> / ADV<ins>T<ms> with pay_id = -1
-- (kNoPaymentRow) and write NOTHING until the payment succeeds. So if the
-- capture is late, or the counter machine dies between paying and saving,
-- the money is taken and the database has no record that it ever happened --
-- not the amount, not the student, not which fee types. The webhook looks
-- the order up in `payment`, finds nothing, and logs UNMATCHED.
--
-- Both are ADMIN-APP ONLY, so an accountant is present when it happens. That
-- narrows what this has to cover: not a parent walking off mid-payment, but
-- a capture that lands after the screen has moved on, and a counter that
-- believes the payment failed when Paytm took the money.
--
-- THE FIX. Give them the same thing fee collection has: an intent recorded
-- BEFORE the gateway is contacted, holding everything needed to raise the
-- receipt afterwards. Kept in a table of its own rather than as a pending
-- row in misc_collection, because a misc row draws its receipt number the
-- moment it is inserted -- a pending one would burn a number on a payment
-- that may never happen, and the register would gap.
--
-- WHO RAISES THE RECEIPT. Whoever gets there first, exactly once. The
-- counter normally does, the moment Paytm returns. The webhook does only if
-- the counter did not. They agree through claim_pending_collection(), an
-- atomic UPDATE that exactly one caller can win -- without it a late
-- callback arriving just as the accountant saves would produce two receipts
-- for one payment.
--
-- Idempotent. Touches no existing receipt, demand or sequence.
--
-- NEEDS THE APP CHANGE TOO: until the two desktop screens call
-- record_pending_collection() before paying, there is still nothing for the
-- webhook to find. This migration is the half that must go first.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. The intent.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pending_collection (
  order_id    text PRIMARY KEY,
  ins_id      integer     NOT NULL,
  kind        char(1)     NOT NULL CHECK (kind IN ('M','A')),  -- Misc / Advance
  amount      numeric(12,2) NOT NULL,
  header      jsonb       NOT NULL,
  lines       jsonb,
  created_by  text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  -- I initiated · P claimed, being completed · C receipted · F failed · X abandoned
  status      char(1)     NOT NULL DEFAULT 'I' CHECK (status IN ('I','P','C','F','X')),
  claimed_by  text,
  claimed_at  timestamptz,
  receipt_no  text,
  settled_at  timestamptz
);

COMMENT ON TABLE public.pending_collection IS
  'What a misc or advance Paytm collection WAS FOR, recorded before the '
  'gateway is contacted. Without it a late capture cannot be receipted: '
  'nothing else records the lines. Not a receipt -- no number is drawn here.';

CREATE INDEX IF NOT EXISTS pending_collection_open
  ON public.pending_collection (created_at) WHERE status IN ('I','P');

REVOKE ALL ON public.pending_collection FROM PUBLIC, anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. Record one, before contacting Paytm. Called by the admin app.
--
-- SECURITY DEFINER so the app needs no table grant. It writes no money and
-- draws no receipt number, so an abandoned intent costs nothing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_pending_collection(
  p_order_id text, p_ins_id integer, p_kind text, p_amount numeric,
  p_header jsonb, p_lines jsonb DEFAULT NULL, p_created_by text DEFAULT NULL
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  INSERT INTO public.pending_collection
         (order_id, ins_id, kind, amount, header, lines, created_by)
  VALUES (p_order_id, p_ins_id, upper(p_kind)::char(1), p_amount,
          p_header, p_lines, p_created_by)
  ON CONFLICT (order_id) DO UPDATE
     SET amount = EXCLUDED.amount, header = EXCLUDED.header,
         lines  = EXCLUDED.lines
   WHERE public.pending_collection.status = 'I';
$$;

GRANT EXECUTE ON FUNCTION public.record_pending_collection(
  text, integer, text, numeric, jsonb, jsonb, text) TO anon, authenticated;


-- ---------------------------------------------------------------------
-- 3. Claim it. Exactly one caller wins.
--
-- The counter and the webhook can both arrive; the loser gets no rows and
-- must not raise a receipt. This is the whole defence against a double
-- receipt for one payment.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_pending_collection(
  p_order_id text, p_by text
) RETURNS TABLE(ins_id integer, kind char, amount numeric, header jsonb, lines jsonb)
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  UPDATE public.pending_collection c
     SET status = 'P', claimed_by = p_by, claimed_at = now()
   WHERE c.order_id = p_order_id AND c.status = 'I'
  RETURNING c.ins_id, c.kind, c.amount, c.header, c.lines;
$$;

GRANT EXECUTE ON FUNCTION public.claim_pending_collection(text, text)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. Close one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.settle_pending_collection(
  p_order_id text, p_status text, p_receipt_no text DEFAULT NULL
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  UPDATE public.pending_collection
     SET status = upper(p_status)::char(1), receipt_no = p_receipt_no,
         settled_at = now()
   WHERE order_id = p_order_id;
$$;

GRANT EXECUTE ON FUNCTION public.settle_pending_collection(text, text, text)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. An advance that does not need a session.
--
-- save_advance_collection resolves the institution from a session token,
-- which the webhook does not have. The body is moved VERBATIM to an
-- internal that takes ins_id -- extracted from the deployed definition by
-- the generator, not retyped -- and the public entry point becomes a thin
-- wrapper that still demands a valid session. No client gains anything:
-- the internal is service_role only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._save_advance_collection(p_ins integer, p_header jsonb, p_lines jsonb DEFAULT NULL::jsonb)
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
  -- The institution is given, not derived from a session: this body is also
  -- reached by the Paytm webhook, which runs as service_role with no session.
  -- The SESSION CHECK IS NOT REMOVED -- it moves to the wrapper below, which
  -- is the only door a client can come through.
  v_ins := p_ins;
  IF v_ins IS NULL THEN RAISE EXCEPTION 'No institution'; END IF;
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

REVOKE ALL ON FUNCTION public._save_advance_collection(integer, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._save_advance_collection(integer, jsonb, jsonb)
  TO service_role;

-- The client's door. Unchanged behaviour: a session is still required.
CREATE OR REPLACE FUNCTION public.save_advance_collection(
  p_token text, p_header jsonb, p_lines jsonb DEFAULT NULL::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions' AS $w$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  RETURN public._save_advance_collection(v_ins, p_header, p_lines);
END; $w$;

GRANT EXECUTE ON FUNCTION public.save_advance_collection(text, jsonb, jsonb)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- 6. The webhook completes a misc or advance it finds an intent for.
--
-- Called by webhook_complete_payment when the order id matches no payment
-- row. Claims first; if the claim loses, the counter already receipted it
-- and this does nothing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.webhook_complete_collection(
  p_order_id text, p_reference text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE c record; v_res jsonb; v_no text; v_hdr jsonb;
BEGIN
  SELECT * INTO c FROM public.claim_pending_collection(p_order_id, 'WEBHOOK');
  IF c.ins_id IS NULL THEN
    -- Either there is no intent (an order from before this change, or a fee
    -- payment), or somebody else already has it.
    IF EXISTS (SELECT 1 FROM public.pending_collection
                WHERE order_id = p_order_id AND status IN ('P','C')) THEN
      RETURN jsonb_build_object('ok', true, 'reason', 'already being handled');
    END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'no pending collection');
  END IF;

  -- Carry Paytm's transaction id onto the receipt, so it can be matched
  -- against a settlement report the same way every other receipt is.
  v_hdr := c.header || jsonb_build_object('paytm_txnid', p_reference);

  BEGIN
    IF c.kind = 'M' THEN
      v_res := public.save_misc_collection(c.ins_id, v_hdr, COALESCE(c.lines, '[]'::jsonb));
      v_no  := v_res->>'mcno';
    ELSE
      v_res := public._save_advance_collection(c.ins_id, v_hdr, c.lines);
      v_no  := v_res->>'advno';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Put it back so a retry or a person can try again, and make it visible.
    UPDATE public.pending_collection SET status = 'I', claimed_by = NULL,
           claimed_at = NULL WHERE order_id = p_order_id;
    PERFORM public.webhook_record_refusal(
      p_order_id, 'could not raise the receipt: ' || SQLERRM,
      c.ins_id, NULL, c.amount);
    RETURN jsonb_build_object('ok', false, 'reason', SQLERRM);
  END;

  PERFORM public.settle_pending_collection(p_order_id, 'C', v_no);
  RETURN jsonb_build_object('ok', true, 'kind', c.kind, 'receipt', v_no);
END; $$;

REVOKE ALL ON FUNCTION public.webhook_complete_collection(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.webhook_complete_collection(text, text)
  TO service_role;


-- ---------------------------------------------------------------------
-- 7. webhook_complete_payment tries a collection before giving up.
--
-- Only the 'no payment row' branch changes: before recording a refusal, it
-- now asks whether the order was a misc or advance intent.
-- ---------------------------------------------------------------------
DO $patch$
DECLARE src text; old_block text; new_block text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
   WHERE proname = 'webhook_complete_payment' AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'webhook_complete_payment not found';
  END IF;
  IF src LIKE '%webhook_complete_collection%' THEN
    RAISE NOTICE 'already routes to collections';
    RETURN;
  END IF;
  IF src NOT LIKE '%webhook_record_refusal%' THEN
    RAISE EXCEPTION 'run SURFACE_WEBHOOK_REFUSALS.sql first';
  END IF;

  old_block := 'RETURN jsonb_build_object(''ok'', false, ''reason'', ''no payment row'');';
  IF position(old_block in src) = 0 THEN
    RAISE EXCEPTION 'could not find the no-payment-row branch -- not patched';
  END IF;

  new_block :=
    'DECLARE v_coll jsonb; BEGIN '
    '  v_coll := public.webhook_complete_collection(p_order_id, p_reference); '
    '  IF (v_coll->>''ok'')::boolean THEN RETURN v_coll; END IF; '
    'END; '
    'RETURN jsonb_build_object(''ok'', false, ''reason'', ''no payment row'');';

  src := replace(src, old_block, new_block);
  EXECUTE src;
  RAISE NOTICE 'webhook_complete_payment now tries misc/advance intents';
END $patch$;


-- ---------------------------------------------------------------------
-- 8. fee_health_check(): an intent nobody closed.
-- ---------------------------------------------------------------------
DO $patch$
DECLARE src text; marker text; addition text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
   WHERE proname = 'fee_health_check' AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN RAISE EXCEPTION 'fee_health_check not found'; END IF;
  IF src LIKE '%misc/advance payments never finished%' THEN
    RAISE NOTICE 'check 9 already present'; RETURN;
  END IF;

  marker := '  END LOOP;';
  IF position(marker in src) = 0 THEN
    RAISE EXCEPTION 'could not find the loop end -- not patched';
  END IF;

  addition :=
    E'\n    -- 9. Misc/advance Paytm collections that were started and never\n'
    '    --    finished. Each is possibly money taken with no receipt -- the\n'
    '    --    counter may have closed believing it failed.\n'
    '    SELECT count(*) INTO n FROM public.pending_collection pc\n'
    '     WHERE pc.ins_id = i.id AND pc.status IN (''I'',''P'')\n'
    '       AND pc.created_at < now() - interval ''2 hours'';\n'
    '    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN ''WARNING'' ELSE ''ok'' END,\n'
    '      ''misc/advance payments never finished'', n,\n'
    '      CASE WHEN n > 0 THEN ''ask Paytm about each: captured ones still need a receipt''\n'
    '           ELSE ''none outstanding'' END;\n\n';

  src := overlay(src placing addition from position(marker in src) for 0);
  EXECUTE src;
  RAISE NOTICE 'fee_health_check: check 9 added';
END $patch$;

NOTIFY pgrst, 'reload schema';

NOTIFY pgrst, 'reload schema';


-- #####################################################################
-- PART C -- the app sweeps open intents itself
-- #####################################################################
-- =====================================================================
-- Let the APP recover a late misc/advance capture, without the webhook.
--
-- WHY. WEBHOOK_CAPTURES_MISC_AND_ADVANCE made a late capture recoverable --
-- but only by the webhook, which is a separate moving part: it has to be
-- deployed, Paytm has to be configured to call it, and there is exactly one
-- callback URL for one Paytm account. A counter that cancels a UPI collect
-- and has it approved on a phone two minutes later must be recovered by the
-- app itself, the same way _sweepOrphanedPayments already recovers a fee
-- payment. Nothing about real money should depend on a webhook being
-- correctly registered.
--
-- WHAT THE SWEEP NEEDS. To ask Paytm about an order it must ask THE MERCHANT
-- THE ORDER WAS SIGNED WITH -- orders are signed per fee group now, so a
-- hostel collection lives under the hostel merchant and asking the default
-- one returns "no such order". The fee-payment sweep reads payment.ban_id for
-- this. An intent had nowhere to put it, so it is added here; both screens
-- have already resolved the bank before they sign the order, so they simply
-- pass what they know.
--
-- The column is nullable: an intent written before this migration, or one
-- whose routing could not be resolved, falls back to the institution's own
-- merchant exactly as the rest of the code does.
--
-- Idempotent. Touches no receipt.
-- =====================================================================

ALTER TABLE public.pending_collection
  ADD COLUMN IF NOT EXISTS ban_id integer;

COMMENT ON COLUMN public.pending_collection.ban_id IS
  'The fee group bank this collection was signed against. The sweep needs it '
  'to ask the right Paytm merchant -- the wrong one answers "no such order" '
  'and the capture looks like a failure.';


-- ---------------------------------------------------------------------
-- record_pending_collection gains p_ban_id.
--
-- DROPPED first, not CREATE OR REPLACE: adding a parameter makes a NEW
-- signature, so replace would leave two overloads and a call naming the
-- common arguments would be ambiguous.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.record_pending_collection(
  text, integer, text, numeric, jsonb, jsonb, text);

CREATE OR REPLACE FUNCTION public.record_pending_collection(
  p_order_id text, p_ins_id integer, p_kind text, p_amount numeric,
  p_header jsonb, p_lines jsonb DEFAULT NULL, p_created_by text DEFAULT NULL,
  p_ban_id integer DEFAULT NULL
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  INSERT INTO public.pending_collection
         (order_id, ins_id, kind, amount, header, lines, created_by, ban_id)
  VALUES (p_order_id, p_ins_id, upper(p_kind)::char(1), p_amount,
          p_header, p_lines, p_created_by, p_ban_id)
  ON CONFLICT (order_id) DO UPDATE
     SET amount = EXCLUDED.amount, header = EXCLUDED.header,
         lines  = EXCLUDED.lines,  ban_id = EXCLUDED.ban_id
   WHERE public.pending_collection.status = 'I';
$$;

GRANT EXECUTE ON FUNCTION public.record_pending_collection(
  text, integer, text, numeric, jsonb, jsonb, text, integer)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- What the sweep reads: intents old enough that the counter's own flow has
-- finished with them, and still unresolved.
--
-- 2 minutes. It was 10, to keep a sweep from racing a cashier still on the
-- Paytm page -- but that race cannot happen: the sweep only CLAIMS an intent
-- after Paytm confirms a capture, and a payment still pending at the gateway
-- reads as undecided and is left untouched. The claim handles the rest. A
-- counter watching a payment it knows was made should not wait ten minutes to
-- see it, and the wait was protecting nothing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.open_pending_collections(p_ins_id integer)
RETURNS TABLE(order_id text, kind char, amount numeric, ban_id integer,
              created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT c.order_id, c.kind, c.amount, c.ban_id, c.created_at
    FROM public.pending_collection c
   WHERE c.ins_id = p_ins_id
     AND c.status = 'I'
     AND c.created_at < now() - interval '2 minutes'
   ORDER BY c.created_at;
$$;

GRANT EXECUTE ON FUNCTION public.open_pending_collections(integer)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- The claimed payload, for the sweeper to replay.
--
-- Separate from the claim so the app can claim, then fetch; the claim
-- already returns the payload, but a sweep that crashed between the two
-- needs a way back to it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pending_collection_payload(p_order_id text)
RETURNS TABLE(ins_id integer, kind char, amount numeric, header jsonb,
              lines jsonb, status char)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT c.ins_id, c.kind, c.amount, c.header, c.lines, c.status
    FROM public.pending_collection c WHERE c.order_id = p_order_id;
$$;

GRANT EXECUTE ON FUNCTION public.pending_collection_payload(text)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- ADDENDUM -- a late capture is dated the day the MONEY WAS TAKEN.
--
-- save_misc_collection and save_advance_collection stamp the date on the
-- database server (CURRENT_DATE / now()) and deliberately ignore any date the
-- client sends -- a workstation with a wrong clock was once dating misc
-- receipts a day out while fee receipts were correct.
--
-- That rule is right for a collection happening now, and wrong for one the
-- sweep recovers. A UPI collect approved at 11pm and captured after midnight,
-- or a bank that confirms the next morning, would be receipted on the day it
-- was FOUND rather than the day the family paid -- so that day's collection
-- never ties, and reconciling against a Paytm settlement report means doing by
-- hand what was done for the Rs 8,000 on 01-10-2026.
--
-- The intent's created_at is the honest answer, and it does not come from a
-- workstation: it was stamped by this server when the order was signed, before
-- the gateway was contacted. So the date is corrected FROM THE DATABASE'S OWN
-- CLOCK, never from the client.
--
-- Only ever moves a receipt BACKWARDS, and only one the sweep just raised.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.backdate_recovered_collection(p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE c record; v text; n integer := 0;
BEGIN
  SELECT * INTO c FROM public.pending_collection WHERE order_id = p_order_id;
  IF c.order_id IS NULL OR c.status <> 'C' OR COALESCE(c.receipt_no,'') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no completed intent');
  END IF;

  v := get_institution_schema(c.ins_id);
  IF v IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no schema'); END IF;

  -- NOT short-circuited on "same day". advance_collection.advdate is a
  -- TIMESTAMP, so a collection recovered five minutes later still sits five
  -- minutes after the money was taken -- and twenty-five, and an hour, as the
  -- gap grows. Ordering within a day and matching a Paytm settlement line both
  -- depend on the time, which is exactly how the Rs 8,000 ended up at 17:58
  -- instead of 12:28. The UPDATEs below only ever move a receipt BACKWARDS, so
  -- a genuinely same-moment collection is untouched anyway.

  IF c.kind = 'M' THEN
    EXECUTE format(
      'UPDATE %I.misc_collection SET mcdate = $1
        WHERE mcno = $2 AND ins_id = $3 AND mcdate > $1', v)
      USING c.created_at::date, c.receipt_no, c.ins_id;
  ELSE
    EXECUTE format(
      'UPDATE %I.advance_collection SET advdate = $1
        WHERE advno = $2 AND ins_id = $3 AND advdate > $1', v)
      USING c.created_at, c.receipt_no, c.ins_id;
  END IF;
  GET DIAGNOSTICS n = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'moved', n,
                            'to', c.created_at, 'receipt', c.receipt_no);
END; $$;

GRANT EXECUTE ON FUNCTION public.backdate_recovered_collection(text)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- #####################################################################
-- PART D -- a recovered FEE payment keeps its day
-- #####################################################################
-- =====================================================================
-- A recovered fee payment is dated the day the MONEY WAS TAKEN.
--
-- complete_payment_grouped stamps paydate = NOW(). That is right when the
-- payment completes normally -- the receipt happens as the money is taken --
-- and wrong for one the sweep recovers hours or days later.
--
-- THE CASE. JAYASURYA, 30-09-2026: Rs 2,000 and Rs 1,600 debited that evening,
-- captured by Paytm around midnight. Recovered the next morning, the receipts
-- would carry 1 OCTOBER -- so 30 September's Daily Collection is short by
-- Rs 3,600 and never ties against the Paytm report, and the difference has to
-- be chased by hand. The same reconciliation that found the missing Rs 8,000.
--
-- WHERE THE HONEST DATE COMES FROM. The 'I' row's createdat, stamped by this
-- server when the payment was initiated, before the gateway was contacted.
-- Never a workstation clock -- ignoring client dates is why misc receipts
-- stopped landing a day out.
--
-- complete_payment_grouped carries payorderid onto the rows it creates, so the
-- receipts can still be found after the original row is gone.
--
-- Only ever moves a receipt BACKWARDS, never forwards, and only one that
-- carries the order id it is asked about.
--
-- Idempotent. Changes no amount, no demand, no receipt number.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.backdate_recovered_payment(
  p_ins_id integer, p_order_id text, p_when timestamp
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v text; n integer := 0;
BEGIN
  IF p_order_id IS NULL OR btrim(p_order_id) = '' OR p_when IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'order id and date required');
  END IF;

  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no schema'); END IF;

  -- paynumber IS NOT NULL: only a RAISED receipt is moved. An attempt without
  -- one has no place in any report, so its date decides nothing.
  -- paydate > p_when: backwards only. A receipt that is already dated earlier
  -- is left exactly as it is.
  EXECUTE format(
    'UPDATE %I.payment SET paydate = $1
      WHERE payorderid = $2 AND ins_id = $3
        AND paynumber IS NOT NULL AND paystatus = ''C''
        AND paydate > $1', v)
    USING p_when, p_order_id, p_ins_id;
  GET DIAGNOSTICS n = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'moved', n, 'to', p_when);
END; $$;

GRANT EXECUTE ON FUNCTION public.backdate_recovered_payment(integer, text, timestamp)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- #####################################################################
-- PART E -- two counters collecting at the same instant
--
-- FEE COLLECTION is safe: it takes the receipt number under
-- `SELECT ... FOR UPDATE`, so concurrent collectors serialise, and
-- payment.paynumber is UNIQUE so the database would refuse a duplicate even
-- if the lock were lost. ADVANCE is safe for the same reason.
--
-- MISC COLLECTION IS NOT, AND THIS IS A REGRESSION FROM TODAY.
-- LIVE_ALL_2026_10_03.sql carried the save_misc_collection from
-- LIVE_REMAINING_2026_10_01.sql, which reads the sequence WITHOUT FOR UPDATE:
--
--     SELECT seq_id, seqcurno, sequid, seqwidth FROM <schema>.sequence
--      WHERE ins_id = $1 AND activestatus = 1 ORDER BY seq_id LIMIT 1
--
-- Two cashiers saving at the same moment read the same seqcurno, build the
-- same mcno, and both insert it -- and mcno has NO unique constraint, so
-- nothing refuses the second one. The result is two different receipts
-- printed with one number and a gap in the register, discovered weeks later
-- by someone reconciling.
--
-- The window is milliseconds, which is why it has not bitten yet. It is also
-- why it would be nearly impossible to reproduce on purpose.
--
-- FIXED BY ADDING THE LOCK ONLY. The sequence SELECTION is deliberately left
-- exactly as it is -- changing which sequence a misc receipt draws from would
-- renumber receipts, which is not something a concurrency fix should do.
-- #####################################################################
DO $misc_lock$
DECLARE src text; old_sel text; new_sel text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
   WHERE proname = 'save_misc_collection' AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN RAISE EXCEPTION 'save_misc_collection not found'; END IF;

  IF src LIKE '%ORDER BY seq_id LIMIT 1 FOR UPDATE%' THEN
    RAISE NOTICE 'misc collection already takes its receipt number under a lock';
    RETURN;
  END IF;

  -- The literal in the deployed body is:  ORDER BY seq_id LIMIT 1', v_schema)
  -- pg_get_functiondef returns it dollar-quoted, so the inner quotes are NOT
  -- doubled -- matching on the closing paren alone misses it.
  old_sel := 'ORDER BY seq_id LIMIT 1'', v_schema)';
  new_sel := 'ORDER BY seq_id LIMIT 1 FOR UPDATE'', v_schema)';
  IF position(old_sel in src) = 0 THEN
    RAISE EXCEPTION 'could not find the misc sequence read -- NOT patched, '
                    'two cashiers can still draw the same receipt number';
  END IF;

  src := replace(src, old_sel, new_sel);
  EXECUTE src;
  RAISE NOTICE 'misc collection now takes its receipt number under a lock';
END $misc_lock$;


-- ---------------------------------------------------------------------
-- And a constraint behind the lock, so a future edit cannot quietly
-- reintroduce this. payment.paynumber has had one all along; misc and
-- advance never did.
--
-- Added only if the data is already clean -- a CREATE UNIQUE INDEX on a table
-- that already holds duplicates would abort the whole release, and a release
-- is the wrong moment to discover a historical duplicate. If it is skipped,
-- the NOTICE says so and fee_health_check()'s 'duplicate receipt numbers'
-- check is already watching.
-- ---------------------------------------------------------------------
DO $uniq$
DECLARE s text; n bigint;
BEGIN
  FOR s IN SELECT table_schema FROM information_schema.tables
            WHERE table_name = 'misc_collection'
              AND table_schema NOT IN ('pg_catalog','information_schema')
  LOOP
    EXECUTE format('SELECT count(*) FROM (SELECT mcno FROM %I.misc_collection '
                   'WHERE activestatus = 1 GROUP BY ins_id, mcno '
                   'HAVING count(*) > 1) d', s) INTO n;
    IF n > 0 THEN
      RAISE NOTICE '%: % duplicate mcno already present -- unique index SKIPPED', s, n;
    ELSE
      EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS misc_collection_mcno_uniq '
                     'ON %I.misc_collection (ins_id, mcno) WHERE activestatus = 1', s);
      RAISE NOTICE '%: misc receipt numbers are now unique', s;
    END IF;

    EXECUTE format('SELECT count(*) FROM (SELECT advno FROM %I.advance_collection '
                   'WHERE activestatus = 1 GROUP BY ins_id, advno '
                   'HAVING count(*) > 1) d', s) INTO n;
    IF n > 0 THEN
      RAISE NOTICE '%: % duplicate advno already present -- unique index SKIPPED', s, n;
    ELSE
      EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS advance_collection_advno_uniq '
                     'ON %I.advance_collection (ins_id, advno) WHERE activestatus = 1', s);
      RAISE NOTICE '%: advance receipt numbers are now unique', s;
    END IF;
  END LOOP;
END $uniq$;



-- #####################################################################
-- PART F -- the Transactions screen can SEE unfinished collections
-- #####################################################################
-- =====================================================================
-- Let the Transactions screen SEE unfinished misc/advance collections.
--
-- public.pending_collection is REVOKEd from anon/authenticated on purpose: a
-- forged row there would read as "money the college received" to whoever works
-- the list. But the revoke takes SELECT with it, so the admin app -- which
-- reads with the anon key -- could not show them at all.
--
-- WRITING stays locked. Only reading is opened, and only through this
-- function. It takes ins_id rather than a session token: the first version
-- demanded a session and silently returned nothing when one could not be
-- resolved, which is indistinguishable from "there is nothing to show" -- a
-- bad property for a screen whose job is to reveal money that may be at risk.
-- The same anon key already reads payment rows with names and amounts, so this
-- exposes nothing new.
--
-- Read-only. Writes still go through record/claim/settle.
-- =====================================================================
DROP FUNCTION IF EXISTS public.list_pending_collections(text, date, date);

CREATE OR REPLACE FUNCTION public.list_pending_collections(
  p_ins_id integer, p_from date DEFAULT NULL, p_to date DEFAULT NULL
) RETURNS TABLE(order_id text, kind char, amount numeric, header jsonb,
                status char, created_at timestamptz, receipt_no text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions AS $$
  SELECT c.order_id, c.kind, c.amount, c.header, c.status,
         c.created_at, c.receipt_no
    FROM public.pending_collection c
   WHERE c.ins_id = p_ins_id
     AND (p_from IS NULL OR c.created_at >= p_from::timestamptz)
     AND (p_to   IS NULL OR c.created_at <  (p_to + 1)::timestamptz)
   ORDER BY c.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.list_pending_collections(integer, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_pending_collections(integer, date, date)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

NOTIFY pgrst, 'reload schema';


-- #####################################################################
-- VERIFY -- the only result you will see. Every row must read ok.
-- #####################################################################
SELECT 'A1 refusals are recorded' AS check,
       CASE WHEN p.prosrc LIKE '%webhook_record_refusal%' THEN 'ok' ELSE 'FAILED' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='webhook_complete_payment'
UNION ALL
SELECT 'A2 health check reports refusals',
       CASE WHEN p.prosrc LIKE '%captures Paytm confirmed but we refused%' THEN 'ok' ELSE 'FAILED' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='fee_health_check'
UNION ALL
SELECT 'B1 intents can be recorded',
       CASE WHEN to_regclass('public.pending_collection') IS NOT NULL THEN 'ok' ELSE 'FAILED' END
UNION ALL
SELECT 'B2 advance can be raised without a session',
       CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname='public' AND p.proname='_save_advance_collection')
            THEN 'ok' ELSE 'FAILED' END
UNION ALL
SELECT 'B3 the client door still demands a session',
       CASE WHEN p.prosrc LIKE '%session_context%' THEN 'ok' ELSE 'FAILED' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='save_advance_collection'
UNION ALL
SELECT 'B4 the webhook tries misc/advance',
       CASE WHEN p.prosrc LIKE '%webhook_complete_collection%' THEN 'ok' ELSE 'FAILED' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='webhook_complete_payment'
UNION ALL
SELECT 'B5 health check reports unfinished ones',
       CASE WHEN p.prosrc LIKE '%misc/advance payments never finished%' THEN 'ok' ELSE 'FAILED' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='fee_health_check'
UNION ALL
SELECT 'C1 intents carry their bank',
       CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                          WHERE table_schema='public' AND table_name='pending_collection'
                            AND column_name='ban_id') THEN 'ok' ELSE 'FAILED' END
UNION ALL
SELECT 'C2 only one record_pending_collection',
       CASE WHEN count(*) = 1 THEN 'ok' ELSE 'FAILED - ' || count(*) || ' overloads' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='record_pending_collection'
UNION ALL
SELECT 'C3 the app can list open intents',
       CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname='public' AND p.proname='open_pending_collections')
            THEN 'ok' ELSE 'FAILED' END
UNION ALL
SELECT 'D1 a recovered misc/advance keeps its day',
       CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname='public' AND p.proname='backdate_recovered_collection')
            THEN 'ok' ELSE 'FAILED' END
UNION ALL
SELECT 'D2 a recovered fee payment keeps its day',
       CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname='public' AND p.proname='backdate_recovered_payment')
            THEN 'ok' ELSE 'FAILED' END
UNION ALL
SELECT 'E1 a client cannot forge an intent or a refusal',
       CASE WHEN has_table_privilege('anon','public.pending_collection','INSERT')
              OR has_table_privilege('anon','public.webhook_refusal','INSERT')
            THEN 'FAILED - anon can write' ELSE 'ok' END
UNION ALL
SELECT 'E1b misc takes its receipt number under a lock',
       CASE WHEN p.prosrc LIKE '%ORDER BY seq_id LIMIT 1 FOR UPDATE%' THEN 'ok'
            ELSE 'FAILED - two cashiers can draw the same number' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='save_misc_collection'
UNION ALL
SELECT 'F1 the app can list unfinished collections',
       CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname='public' AND p.proname='list_pending_collections')
            THEN 'ok' ELSE 'FAILED' END
UNION ALL
SELECT 'E2 the money still adds up',
       CASE WHEN (SELECT count(*) FROM public.fee_health_check()
                   WHERE severity NOT IN ('ok','WARNING')) = 0
            THEN 'ok' ELSE 'SEE public.fee_health_check()' END
 ORDER BY 1;
