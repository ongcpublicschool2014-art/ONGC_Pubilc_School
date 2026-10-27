-- ############################################################################
-- EduCore360 -- LIVE UPDATE, 18-09-2026
--
-- One file, run top to bottom in the SQL editor. It carries every database
-- change made since the last live update, in dependency order:
--
--   1. ADVANCE_COLLECTION_SETUP.sql           Advance Collection module: the three tables in every institution schema, plus save_advance_collection() and adjust_advance().
--   2. ADVANCE_CANCEL_REFUND.sql              Cancel / refund an advance, and let void_receipt cancel an advance-adjustment receipt (it replaces public.
--   3. ADVANCE_BANK_RECON.sql                 reconcile_advance_batch(): a non-cash advance settles in Bank Reconciliation.
--   4. FIX_DAILY_FEETYPE_SPLIT_LINES.sql      Daily Collection: a fee settled in two pieces on one receipt no longer loses a piece (replaces the two report functions).
--   5. fix_reconbalancedue_cash_payment.sql   A cash payment no longer wipes OTHER pending payments off reconbalancedue (replaces process_grouped_payment).
--
-- ALL OF IT IS SAFE TO RE-RUN. Every table is CREATE TABLE IF NOT EXISTS and
-- every function is CREATE OR REPLACE. No row is inserted, updated or deleted
-- anywhere: this file changes structure and code only.
--
-- Applied and exercised on the TEST project first (a full restore of live,
-- 18-09-2026), including advance collection, adjustment, cancel, refund, bank
-- reconciliation and a Paytm payment through the staging gateway.
--
-- ---------------------------------------------------------------------------
-- FOUR FUNCTIONS ARE REPLACED WHOLE, NOT JUST ADDED:
--     public.void_receipt
--     public.process_grouped_payment
--     public.get_daily_collection_report
--     public.get_daily_collection_unreconciled
-- Their bodies here come from C:\pg_backups\complete_setup.sql with one
-- deliberate change each. If live has drifted from that file, this overwrites
-- the drift. The PRE-FLIGHT section below prints what live has RIGHT NOW --
-- run it first and keep the output, so there is something to compare against
-- and to restore from.
-- ---------------------------------------------------------------------------
--
-- AFTER RUNNING, two things are configuration rather than schema, so they are
-- deliberately NOT in this file:
--   * A numbering sequence for advances (Fee Master -> Advance No). A STUDENT
--     advance refuses without it. An ADMISSION advance does not need one -- it
--     draws from the payment sequence, like a fee receipt.
--   * A numbering sequence for refunds (Fee Master -> Refund No), if this
--     institution has never raised one.
-- The last query in this file reports whether they exist.
-- ############################################################################


-- ############################################################################
-- PRE-FLIGHT (READ-ONLY) -- run this section on its own first and SAVE the
-- output. It is the current definition of everything this file replaces.
-- ############################################################################
SELECT p.proname,
       pg_get_functiondef(p.oid) AS current_definition_on_this_database
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('void_receipt', 'process_grouped_payment',
                     'get_daily_collection_report', 'get_daily_collection_unreconciled')
 ORDER BY p.proname;



-- ############################################################################
-- PART 1 of 5 -- ADVANCE_COLLECTION_SETUP.sql
--
-- Advance Collection module: the three tables in every institution schema, plus save_advance_collection() and adjust_advance().
-- ############################################################################

-- ============================================================================
-- ADVANCE COLLECTION -- complete setup. RUN THIS WHOLE FILE, TOP TO BOTTOM.
-- RUN IT ON TEST FIRST. It changes money tables.
--
-- Creates, in EVERY institution schema:
--   advance_collection   money taken from a STUDENT before any fee is due.
--                        Mirrors payment's money/reconcile columns but carries
--                        no fg_id / fee_id on the header. balanceamount is
--                        GENERATED (taken - adjusted - refunded), so it cannot
--                        drift from its parts.
--   advance_detail       fee-type breakdown of an ADMISSION advance.
--   advadjustment        one row per amount moved off an advance onto a fee
--                        demand, with the receipt that settlement raised.
--
-- TWO KINDS OF ADVANCE, told apart by advance_collection.advtype:
--   'A'  ADMISSION advance -- collected BY FEE TYPE. The receipt carries a
--        breakdown (TUITION 10,000 / BUS 4,000 / ...) in advance_detail and the
--        header total is always the sum of those lines.
--   'S'  STUDENT advance -- a plain amount, no breakdown.
-- Both are held against the student the same way and spent the same way.
--
-- and, in public:
--   save_advance_collection(p_token, p_header, p_lines)  take an advance
--   adjust_advance(p_token, p_adv_id, p_lines, p_by, p_pay_id)
--                                                        spend it on demands.
--     With p_pay_id it ATTACHES to the cash receipt the cashier just raised --
--     one receipt, one sequence number, total = cash + advance. Without it the
--     advance covered everything and it raises its own receipt.
--
-- BEFORE THE FIRST ADVANCE CAN BE TAKEN: open Fee Master -> Advance No and
-- save a sequence (e.g. prefix AD26/ width 5, start 1). Nothing is seeded here
-- -- save_advance_collection refuses with a clear message rather than inventing
-- a receipt number. Same pattern as Concession No and Refund No.
--
-- IDEMPOTENT throughout (IF NOT EXISTS / ADD COLUMN IF NOT EXISTS / CREATE OR
-- REPLACE) -- safe to re-run, including on a schema that already has the first
-- cut of these tables. It creates no data.
--
-- RE-RUN THIS ON TEST even though the first cut is already applied there. It
-- carries three changes made since:
--   1. advtype + advance_detail (the two kinds of advance above).
--   2. paytm_txnid on the header, so a Paytm advance records the gateway's own
--      transaction id apart from our order id -- the same split
--      misc_collection uses.
--   3. save_advance_collection sets recon_status the way save_misc_collection
--      does: cash is 'R' (realised on the spot -- no bank line will ever match
--      it), everything else 'P'. It used to hardcode 'P', which parked every
--      cash advance in Bank Reconciliation forever.
-- The 2-argument save_advance_collection is DROPPED and replaced by the
-- 3-argument one; leaving both would give PostgREST two overloads to choose
-- between.
-- ============================================================================

DO $adv$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'payment')
       AND nspname NOT IN ('public','information_schema')
       AND nspname NOT LIKE 'pg\_%'
  LOOP
    -- ---- header: the advance receipt -------------------------------------
    EXECUTE format($t$
      CREATE TABLE IF NOT EXISTS %I.advance_collection (
        adv_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        ins_id            integer NOT NULL,
        inscode           varchar(10),
        stu_id            bigint NOT NULL,
        stuadmno          varchar(25),
        stuname           varchar(50),
        stuclass          varchar(20),
        courname          varchar(20),
        yr_id             integer,
        yrlabel           varchar(20),
        advno             varchar(30) NOT NULL,
        advdate           timestamp DEFAULT now() NOT NULL,
        -- 'A' admission advance (itemised in advance_detail), 'S' student
        -- advance (amount only).
        advtype           char(1) DEFAULT 'S' NOT NULL
                            CHECK (advtype = ANY(ARRAY['A','S'])),
        transtotalamount  numeric(12,2) NOT NULL CHECK (transtotalamount > 0),
        adjustedamount    numeric(12,2) DEFAULT 0 NOT NULL,
        refund_amount     numeric(12,2) DEFAULT 0 NOT NULL,
        -- always exactly what is left; cannot drift from its parts
        balanceamount     numeric(12,2) GENERATED ALWAYS AS
                            (transtotalamount - adjustedamount - refund_amount) STORED,
        transcurrency     varchar(20) DEFAULT 'INR' NOT NULL,
        paystatus         char(1) DEFAULT 'C' NOT NULL
                            CHECK (paystatus = ANY(ARRAY['I','C','F','R'])),
        paymethod         varchar(60),
        payreference      varchar(100),
        payorderid        varchar(100),
        -- Paytm's own transaction id, kept apart from payreference (which
        -- holds OUR order id), exactly as misc_collection.paytm_txnid does.
        paytm_txnid       varchar(60),
        paychequeno       varchar(50),
        paychequedate     date,
        paybankname       varchar(100),
        ban_id            integer,
        recon_status      char(1) DEFAULT 'P',
        reconciled_by     varchar(50),
        reconciled_date   timestamp,
        bank_reference    varchar(100),
        bank_date         date,
        tender_amount     numeric(12,2),
        remarks           varchar(255),
        createdby         varchar(50),
        createdat         timestamp DEFAULT now() NOT NULL,
        voidedby          varchar(100),
        voideddate        timestamp,
        voidreason        varchar(255),
        activestatus      smallint DEFAULT 1 NOT NULL
      )$t$, s);

    -- Schemas that got the FIRST cut of this table (no advtype / paytm_txnid)
    -- are brought up to date here rather than by a second migration file.
    EXECUTE format($t$
      ALTER TABLE %I.advance_collection
        ADD COLUMN IF NOT EXISTS advtype     char(1) DEFAULT 'S' NOT NULL,
        ADD COLUMN IF NOT EXISTS paytm_txnid varchar(60)$t$, s);
    EXECUTE format('ALTER TABLE %I.advance_collection DROP CONSTRAINT IF EXISTS chk_advance_advtype', s);
    EXECUTE format($t$ALTER TABLE %I.advance_collection
      ADD CONSTRAINT chk_advance_advtype CHECK (advtype = ANY(ARRAY['A','S']))$t$, s);

    -- One advance receipt number per institution.
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS uq_advance_advno ON %I.advance_collection (ins_id, advno)', s);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advance_stu ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1', s);
    -- Drives "students with an unused advance" (the Fee Collection highlight).
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advance_open ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1 AND balanceamount > 0', s);

    -- ---- detail: what an ADMISSION advance was taken for -----------------
    -- Mirrors misc_collection_detail. feetype is varchar(60), not misc's 30:
    -- real fee names run long (DUPLICATE TRANSFER CERTIFICATE is 29) and there
    -- is no reason to inherit a limit that is one rename away from failing.
    EXECUTE format($t$
      CREATE TABLE IF NOT EXISTS %I.advance_detail (
        advd_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        adv_id        bigint NOT NULL,
        ins_id        integer NOT NULL,
        fee_id        integer,
        fg_id         integer,
        feetype       varchar(60) NOT NULL,
        amount        numeric(12,2) NOT NULL DEFAULT 0,
        activestatus  smallint DEFAULT 1 NOT NULL
      )$t$, s);
    EXECUTE format('ALTER TABLE %I.advance_detail DROP CONSTRAINT IF EXISTS fk_advance_detail_advance', s);
    EXECUTE format('ALTER TABLE %I.advance_detail ADD CONSTRAINT fk_advance_detail_advance FOREIGN KEY (adv_id) REFERENCES %I.advance_collection(adv_id)', s, s);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advance_detail_adv ON %I.advance_detail (adv_id)', s);

    -- ---- child: what the advance was applied to --------------------------
    EXECUTE format($t$
      CREATE TABLE IF NOT EXISTS %I.advadjustment (
        adj_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        adv_id         bigint NOT NULL,
        ins_id         integer NOT NULL,
        stu_id         bigint,
        dem_id         bigint,
        -- the fee receipt raised when the adjustment settled the demand
        pay_id         bigint,
        paynumber      varchar(30),
        demfeeterm     varchar(20),
        demfeetype     varchar(30),
        adjustamount   numeric(12,2) NOT NULL CHECK (adjustamount > 0),
        adjustdate     date DEFAULT CURRENT_DATE NOT NULL,
        remarks        varchar(255),
        createdby      varchar(50),
        createdat      timestamp DEFAULT now() NOT NULL,
        activestatus   smallint DEFAULT 1 NOT NULL
      )$t$, s);

    EXECUTE format('ALTER TABLE %I.advadjustment DROP CONSTRAINT IF EXISTS fk_advadjustment_advance', s);
    EXECUTE format('ALTER TABLE %I.advadjustment ADD CONSTRAINT fk_advadjustment_advance FOREIGN KEY (adv_id) REFERENCES %I.advance_collection(adv_id)', s, s);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advadjustment_adv ON %I.advadjustment (adv_id)', s);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_advadjustment_dem ON %I.advadjustment (ins_id, dem_id)', s);

    -- ---- money-table lockdown (same posture as payment/feedemand) --------
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON %I.advance_collection, %I.advance_detail, %I.advadjustment FROM anon', s, s, s);
    EXECUTE format('GRANT SELECT ON %I.advance_collection, %I.advance_detail, %I.advadjustment TO anon, authenticated', s, s, s);

    RAISE NOTICE 'advance_collection + advance_detail + advadjustment ready in %', s;
  END LOOP;
END
$adv$;


-- ============================================================================
-- save_advance_collection — take an advance and issue its receipt.
--
-- ins_id comes from the session, never the client. The receipt number is drawn
-- from the ADVNO sequence row under FOR UPDATE, so two counters cannot take the
-- same number.
--
-- p_lines is the fee-type breakdown, REQUIRED for an admission advance
-- (advtype 'A') and ignored for a student advance (advtype 'S'):
--   [{"fee_id":18,"fg_id":2,"feetype":"TUITION FEE","amount":10000}, …]
--
-- The 2-argument version is dropped first: adding p_lines with a DEFAULT would
-- otherwise leave two overloads that PostgREST can resolve either way.
-- ============================================================================
DROP FUNCTION IF EXISTS public.save_advance_collection(text, jsonb);

CREATE OR REPLACE FUNCTION public.save_advance_collection(
  p_token text, p_header jsonb, p_lines jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text; v_inscode varchar(10);
  v_yr_id integer; v_yrlabel varchar(20);
  v_seq_id int; v_cur numeric; v_width int; v_prefix text; v_advno text;
  v_adv_id bigint; v_amount numeric;
  v_paymode text; v_recon char(1);
  v_advtype char(1); v_lines_total numeric; v_line_count integer := 0;
  v_fg_id integer;
  itm RECORD;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_advtype := UPPER(COALESCE(NULLIF(p_header->>'advtype',''), 'S'));
  IF v_advtype NOT IN ('A','S') THEN
    RAISE EXCEPTION 'Advance type must be A (admission) or S (student)';
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
        p_header->>'paybankname', NULLIF(p_header->>'ban_id','')::integer,
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
                            'recon_status', v_recon);
END; $$;

GRANT EXECUTE ON FUNCTION public.save_advance_collection(text, jsonb, jsonb) TO anon, authenticated;


-- Advance Collection — stage 2: adjust_advance().
--
-- Applies part (or all) of a student's advance to specific fee demands. The
-- demand is settled exactly as a counter collection settles it, and a real fee
-- receipt is raised, so the student ledger, receipt reprint and DCB all behave
-- normally.
--
-- MIRRORS complete_payment_grouped: receipts are grouped per FEE GROUP (a
-- receipt number comes from that group's sequence), each demand row is locked
-- FOR UPDATE before it is touched, and the amount can never exceed what is
-- owed (balance + fine).
--
-- TWO KINDS OF ADVANCE, and they do DIFFERENT THINGS to the demand.
--
--   'S' STUDENT advance -- money held against a student already studying. It
--     PAYS the demand: paidamount goes up, balancedue comes down, exactly as a
--     counter collection does.
--
--   'A' ADMISSION advance -- taken from a student admitted for NEXT year, so
--     there is no bill to settle when it is collected. It does NOT pay the
--     demand; it REDUCES IT. feeamount comes down by the amount applied (and
--     balancedue with it, since balance is feeamount less concession less paid)
--     while paidamount is left alone -- the student is billed net of what they
--     already handed over at admission. feedemand.pay_id is deliberately NOT
--     stamped either: this receipt did not pay the demand.
--
--   Both are chosen manually by the cashier, both draw the advance down and
--     both are recorded in advadjustment. Only the STUDENT advance produces a
--     RECEIPT: it settles a demand the way money does. An admission advance
--     reduces a bill, so there is nothing to give a receipt for -- and a
--     receipt would show up in Daily Collection as a collection that never
--     happened, only to be netted straight back out again. Its advadjustment
--     rows therefore carry pay_id / paynumber NULL.
--
-- TWO MODES.
--
--   p_pay_id GIVEN  -- the normal counter case. The cashier is collecting the
--     rest in cash, so the payment row ALREADY EXISTS. The advance attaches to
--     it: its lines become paymentdetails on that receipt and its amount is
--     added to payment.transtotalamount, so ONE receipt shows the whole
--     settlement (cash + advance) and one number is drawn from the sequence.
--
--   p_pay_id NULL   -- the advance covers everything, so no cash receipt
--     exists. For a STUDENT advance a receipt is raised per fee group, as
--     below. For an ADMISSION advance no payment row is written at all: the
--     demand is reduced and the advadjustment row is the only record.
--
-- EITHER WAY advadjustment records the amount against the receipt's pay_id, so
-- a REPRINT can show the advance long after the screen state is gone.
--
-- NO NEW BANK MONEY MOVES HERE. The cash arrived when the advance was taken.
-- With p_pay_id the receipt keeps the cashier's own paymethod; standalone it is
-- written with:
--     paymethod    = 'Advance Adjustment'
--     payreference = the advance number (AD26/00001)
--     recon_status = 'R'
-- Reconciliation is marked done because no bank line will ever arrive for it —
-- leaving it 'P' would park it in Bank Reconciliation forever. `paymethod`
-- is what the collection reports must exclude so the money is not counted
-- twice (once as the advance, once as this receipt).
--
-- Everything happens in ONE transaction: if any line fails, no demand is
-- touched, no receipt is raised and the advance is untouched.
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). Run on TEST first.
-- ============================================================================

-- Dropped first: adding a defaulted argument makes a NEW signature, and two
-- overloads would leave PostgREST free to pick either one.
DROP FUNCTION IF EXISTS public.adjust_advance(text, bigint, jsonb, text);

CREATE OR REPLACE FUNCTION public.adjust_advance(
  p_token text, p_adv_id bigint, p_lines jsonb, p_created_by text DEFAULT NULL,
  p_pay_id bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text;
  v_adv RECORD; v_total numeric := 0;
  v_fg_ids integer[] := '{}'; v_fg_id integer; v_item_fg integer;
  v_pay_id bigint; v_paynumber text; v_group_total numeric;
  v_seq RECORD; v_new_no integer;
  v_cur_paid numeric; v_cur_bal numeric; v_cur_fine numeric;
  v_stu_id bigint; v_term text; v_type text;
  itm RECORD; v_result jsonb := '[]'::jsonb;
  v_attach boolean := p_pay_id IS NOT NULL;
  v_pay RECORD;
  v_advtype char(1);
  v_adv_reconciled boolean;
  v_cur_fee numeric; v_cap numeric;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Nothing to adjust';
  END IF;

  -- Lock the advance: two counters cannot spend the same balance.
  EXECUTE format('SELECT adv_id, ins_id, stu_id, advno, balanceamount, paystatus, activestatus,
                         inscode, yr_id, yrlabel, createdby, COALESCE(advtype, ''S'') AS advtype,
                         COALESCE(recon_status, ''P'') AS recon_status
                    FROM %I.advance_collection
                   WHERE adv_id = $1 AND ins_id = $2 FOR UPDATE', v_schema)
    INTO v_adv USING p_adv_id, v_ins;
  IF v_adv.adv_id IS NULL THEN RAISE EXCEPTION 'Advance % not found', p_adv_id; END IF;
  IF v_adv.activestatus <> 1 OR v_adv.paystatus <> 'C' THEN
    RAISE EXCEPTION 'Advance % is cancelled or not collected', v_adv.advno;
  END IF;
  v_advtype := COALESCE(v_adv.advtype, 'S');
  -- Was the advance's own money confirmed by the bank? Cash is, at once;
  -- a cheque is not until it clears. It decides whether settling a demand from
  -- this advance may also bring reconbalancedue down -- see the student branch.
  v_adv_reconciled := (COALESCE(v_adv.recon_status, 'P') = 'R');

  SELECT COALESCE(SUM((l->>'amount')::numeric), 0) INTO v_total
    FROM jsonb_array_elements(p_lines) l;
  IF v_total <= 0 THEN RAISE EXCEPTION 'Adjustment amount must be greater than zero'; END IF;
  IF v_total > v_adv.balanceamount + 0.005 THEN
    RAISE EXCEPTION 'Adjusting % exceeds the advance balance of % on %',
      v_total, v_adv.balanceamount, v_adv.advno USING ERRCODE = 'P0001';
  END IF;

  -- ---- ATTACH MODE -------------------------------------------------------
  -- Settle every line onto the receipt the cashier just raised, instead of
  -- raising another one.
  IF v_attach THEN
    EXECUTE format('SELECT pay_id, paynumber, stu_id, paystatus, activestatus
                      FROM %I.payment WHERE pay_id = $1 AND ins_id = $2 FOR UPDATE', v_schema)
      INTO v_pay USING p_pay_id, v_ins;
    IF v_pay.pay_id IS NULL THEN
      RAISE EXCEPTION 'Receipt % not found', p_pay_id;
    END IF;
    IF COALESCE(v_pay.activestatus, 1) = 9 OR v_pay.paystatus <> 'C' THEN
      RAISE EXCEPTION 'Receipt % is cancelled or incomplete', p_pay_id USING ERRCODE = 'P0001';
    END IF;
    -- The advance and the receipt must belong to the same student, or an
    -- advance could be spent on somebody else's fees.
    IF v_pay.stu_id <> v_adv.stu_id THEN
      RAISE EXCEPTION 'Receipt % belongs to another student', p_pay_id USING ERRCODE = 'P0001';
    END IF;

    v_pay_id := v_pay.pay_id;
    v_paynumber := v_pay.paynumber;

    FOR itm IN SELECT (l->>'dem_id')::bigint AS dem_id, (l->>'amount')::numeric AS amount
                 FROM jsonb_array_elements(p_lines) l
    LOOP
      EXECUTE format('SELECT demfeeterm, demfeetype FROM %I.feedemand WHERE dem_id = $1', v_schema)
        INTO v_term, v_type USING itm.dem_id;

      -- Same lock and guards a counter collection uses.
      EXECUTE format('SELECT paidamount, balancedue, fineamount FROM %I.feedemand
                       WHERE dem_id = $1 AND activestatus = 1 FOR UPDATE', v_schema)
        INTO v_cur_paid, v_cur_bal, v_cur_fine USING itm.dem_id;
      IF COALESCE(v_cur_bal, 0) <= 0 THEN
        RAISE EXCEPTION 'Demand % is already paid. Please refresh.', itm.dem_id USING ERRCODE = 'P0001';
      END IF;
      -- An ADMISSION advance reduces the bill, so it can never take feeamount
      -- below what has already been paid on it -- that would leave a demand
      -- owing a negative amount. The balance is exactly that headroom, and a
      -- fine is NOT part of it: a fine is not something a reduced bill erases.
      IF v_advtype = 'A' THEN
        v_cap := COALESCE(v_cur_bal, 0);
        IF itm.amount > v_cap + 0.005 THEN
          RAISE EXCEPTION 'Reducing demand % by % exceeds the % still billed on it.',
            itm.dem_id, itm.amount, v_cap USING ERRCODE = 'P0001';
        END IF;
      ELSIF itm.amount > COALESCE(v_cur_bal,0) + COALESCE(v_cur_fine,0) + 0.005 THEN
        RAISE EXCEPTION 'Adjusting % on demand % exceeds the amount due (balance % + fine %).',
          itm.amount, itm.dem_id, COALESCE(v_cur_bal,0), COALESCE(v_cur_fine,0) USING ERRCODE = 'P0001';
      END IF;

      EXECUTE format('INSERT INTO %I.paymentdetails
                        (pay_id, dem_id, yr_id, yrlabel, ins_id, transcurrency, transtotalamount)
                      VALUES ($1,$2,$3,$4,$5,''INR'',$6)', v_schema)
        USING v_pay_id, itm.dem_id, v_adv.yr_id, v_adv.yrlabel, v_ins, itm.amount;

      IF v_advtype = 'A' THEN
        -- ADMISSION advance: bill the student LESS, do not record a payment.
        -- feeamount carries the reduction; balancedue and reconbalancedue
        -- follow it; paidamount and pay_id are untouched, because no money
        -- moved against this demand today.
        EXECUTE format('UPDATE %I.feedemand
                          SET feeamount        = GREATEST(COALESCE(feeamount,0) - $1, 0),
                              balancedue       = GREATEST(COALESCE(balancedue,0) - $1, 0),
                              reconbalancedue  = GREATEST(COALESCE(reconbalancedue,0) - $1, 0),
                              paidstatus       = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0
                                                      THEN ''P'' ELSE ''U'' END
                        WHERE dem_id = $2 AND activestatus = 1', v_schema)
          USING itm.amount, itm.dem_id;
      ELSE
        -- STUDENT advance: settles the demand exactly as cash would.
        --
        -- reconbalancedue comes down WITH the balance, but only when the
        -- advance's own money is already confirmed. That figure means "owed
        -- after reconciliation", and an advance taken in cash was banked the
        -- day it was received -- leaving it alone reported the fee as still
        -- outstanding after it had been settled (a 65,000 demand with 500 left
        -- showed 35,500 owed). An advance still waiting on a cheque has not
        -- been confirmed, so it stays up until the bank says so.
        IF v_adv_reconciled THEN
          EXECUTE format('UPDATE %I.feedemand
                            SET paidamount      = COALESCE(paidamount,0) + $1,
                                balancedue      = GREATEST(COALESCE(balancedue,0) - $1, 0),
                                reconbalancedue = GREATEST(COALESCE(reconbalancedue,0) - $1, 0),
                                paidstatus      = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                                pay_id          = $2
                          WHERE dem_id = $3 AND activestatus = 1', v_schema)
            USING itm.amount, v_pay_id, itm.dem_id;
        ELSE
          EXECUTE format('UPDATE %I.feedemand
                            SET paidamount = COALESCE(paidamount,0) + $1,
                                balancedue = GREATEST(COALESCE(balancedue,0) - $1, 0),
                                paidstatus = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                                pay_id     = $2
                          WHERE dem_id = $3 AND activestatus = 1', v_schema)
            USING itm.amount, v_pay_id, itm.dem_id;
        END IF;
      END IF;

      EXECUTE format('INSERT INTO %I.advadjustment
                        (adv_id, ins_id, stu_id, dem_id, pay_id, paynumber,
                         demfeeterm, demfeetype, adjustamount, createdby)
                      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)', v_schema)
        USING p_adv_id, v_ins, v_adv.stu_id, itm.dem_id, v_pay_id, v_paynumber,
              v_term, v_type, itm.amount, COALESCE(p_created_by, v_adv.createdby);
    END LOOP;

    -- The receipt now settles cash AND advance, so its total says so.
    EXECUTE format('UPDATE %I.payment SET transtotalamount = COALESCE(transtotalamount,0) + $1
                     WHERE pay_id = $2', v_schema)
      USING v_total, p_pay_id;

    EXECUTE format('UPDATE %I.advance_collection
                      SET adjustedamount = COALESCE(adjustedamount,0) + $1
                    WHERE adv_id = $2', v_schema)
      USING v_total, p_adv_id;

    RETURN jsonb_build_object(
      'advno', v_adv.advno, 'adjusted', v_total, 'attached_to', v_paynumber,
      'receipts', jsonb_build_array(jsonb_build_object(
        'pay_id', v_pay_id, 'paynumber', v_paynumber, 'amount', v_total)));
  END IF;

  -- ---- STANDALONE MODE ---------------------------------------------------
  -- Which fee groups are involved (one receipt per group, like a collection).
  FOR itm IN SELECT (l->>'dem_id')::bigint AS dem_id, (l->>'amount')::numeric AS amount
               FROM jsonb_array_elements(p_lines) l
  LOOP
    IF itm.amount IS NULL OR itm.amount <= 0 THEN
      RAISE EXCEPTION 'Each line must carry an amount greater than zero';
    END IF;
    -- The demand must belong to the SAME student as the advance.
    EXECUTE format('SELECT stu_id, demfeeterm, demfeetype FROM %I.feedemand
                     WHERE dem_id = $1 AND ins_id = $2 AND activestatus = 1', v_schema)
      INTO v_stu_id, v_term, v_type USING itm.dem_id, v_ins;
    IF v_stu_id IS NULL THEN RAISE EXCEPTION 'Demand % not found', itm.dem_id; END IF;
    IF v_stu_id <> v_adv.stu_id THEN
      RAISE EXCEPTION 'Demand % belongs to another student', itm.dem_id USING ERRCODE = 'P0001';
    END IF;

    EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc = $1 AND ft.activestatus = 1 LIMIT 1', v_schema)
      INTO v_item_fg USING v_type;
    v_item_fg := COALESCE(v_item_fg, 0);
    IF NOT (v_item_fg = ANY(v_fg_ids)) THEN v_fg_ids := v_fg_ids || v_item_fg; END IF;
  END LOOP;

  -- One receipt per fee group -- for a STUDENT advance.
  FOREACH v_fg_id IN ARRAY v_fg_ids LOOP
    v_group_total := 0;
    v_pay_id := NULL;
    v_paynumber := NULL;

    -- An ADMISSION advance raises NO receipt and draws NO receipt number. It
    -- reduces what the student is billed; no money changes hands today, so
    -- there is nothing to receipt -- and a receipt would appear in Daily
    -- Collection as a collection that never happened, to be netted straight
    -- back out again. A STUDENT advance settles a demand the way cash does, so
    -- it gets the receipt, the sequence number and the paymentdetails lines.
    IF v_advtype <> 'A' THEN
      EXECUTE format($p$
        INSERT INTO %I.payment
          (ins_id, inscode, stu_id, yr_id, yrlabel, transtotalamount, transcurrency,
           paydate, paystatus, paymethod, payreference, createdby, recon_status, activestatus)
        VALUES ($1,$2,$3,$4,$5,0,'INR', now(), 'C', 'Advance Adjustment', $6, $7, $8, 1)
        RETURNING pay_id$p$, v_schema)
      INTO v_pay_id
      USING v_ins, v_adv.inscode, v_adv.stu_id, v_adv.yr_id, v_adv.yrlabel,
            v_adv.advno, COALESCE(p_created_by, v_adv.createdby),
            -- Mirrors the ADVANCE, rather than always claiming 'R'. No bank
            -- line will ever arrive for this receipt, but if the advance behind
            -- it is still waiting on one, neither is this money.
            CASE WHEN v_adv_reconciled THEN 'R' ELSE 'P' END;

      -- Receipt number from that fee group's sequence (same rule as a collection).
      v_seq := NULL;
      EXECUTE format('SELECT seq_id, sequid, seqwidth, seqcurno FROM %I.sequence
                       WHERE ins_id = $1 AND fg_id = $2 LIMIT 1 FOR UPDATE', v_schema)
        INTO v_seq USING v_ins, v_fg_id;
      IF v_seq IS NULL THEN
        v_paynumber := 'ADJ' || v_pay_id;
      ELSE
        v_new_no := v_seq.seqcurno + 1;
        v_paynumber := regexp_replace(v_seq.sequid, '\d+$', '') || lpad(v_new_no::text, v_seq.seqwidth::integer, '0');
        EXECUTE format('UPDATE %I.sequence SET seqcurno = $1 WHERE seq_id = $2', v_schema)
          USING v_new_no, v_seq.seq_id;
      END IF;
      EXECUTE format('UPDATE %I.payment SET paynumber = $1 WHERE pay_id = $2', v_schema)
        USING v_paynumber, v_pay_id;
    END IF;

    FOR itm IN SELECT (l->>'dem_id')::bigint AS dem_id, (l->>'amount')::numeric AS amount
                 FROM jsonb_array_elements(p_lines) l
    LOOP
      EXECUTE format('SELECT demfeeterm, demfeetype FROM %I.feedemand WHERE dem_id = $1', v_schema)
        INTO v_term, v_type USING itm.dem_id;
      EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft WHERE ft.feedesc = $1 AND ft.activestatus = 1 LIMIT 1', v_schema)
        INTO v_item_fg USING v_type;
      CONTINUE WHEN COALESCE(v_item_fg, 0) <> v_fg_id;

      -- Lock and guard the demand exactly as a counter collection does.
      EXECUTE format('SELECT paidamount, balancedue, fineamount FROM %I.feedemand
                       WHERE dem_id = $1 AND activestatus = 1 FOR UPDATE', v_schema)
        INTO v_cur_paid, v_cur_bal, v_cur_fine USING itm.dem_id;
      IF COALESCE(v_cur_bal, 0) <= 0 THEN
        RAISE EXCEPTION 'Demand % is already paid. Please refresh.', itm.dem_id USING ERRCODE = 'P0001';
      END IF;
      -- An ADMISSION advance reduces the bill, so it can never take feeamount
      -- below what has already been paid on it -- that would leave a demand
      -- owing a negative amount. The balance is exactly that headroom, and a
      -- fine is NOT part of it: a fine is not something a reduced bill erases.
      IF v_advtype = 'A' THEN
        v_cap := COALESCE(v_cur_bal, 0);
        IF itm.amount > v_cap + 0.005 THEN
          RAISE EXCEPTION 'Reducing demand % by % exceeds the % still billed on it.',
            itm.dem_id, itm.amount, v_cap USING ERRCODE = 'P0001';
        END IF;
      ELSIF itm.amount > COALESCE(v_cur_bal,0) + COALESCE(v_cur_fine,0) + 0.005 THEN
        RAISE EXCEPTION 'Adjusting % on demand % exceeds the amount due (balance % + fine %).',
          itm.amount, itm.dem_id, COALESCE(v_cur_bal,0), COALESCE(v_cur_fine,0) USING ERRCODE = 'P0001';
      END IF;

      -- Only when there IS a receipt. A paymentdetails row with no payment
      -- behind it is an orphan every receipt and ledger query would trip over.
      IF v_pay_id IS NOT NULL THEN
        EXECUTE format('INSERT INTO %I.paymentdetails
                          (pay_id, dem_id, yr_id, yrlabel, ins_id, transcurrency, transtotalamount)
                        VALUES ($1,$2,$3,$4,$5,''INR'',$6)', v_schema)
          USING v_pay_id, itm.dem_id, v_adv.yr_id, v_adv.yrlabel, v_ins, itm.amount;
      END IF;

      IF v_advtype = 'A' THEN
        -- ADMISSION advance: bill the student LESS, do not record a payment.
        -- feeamount carries the reduction; balancedue and reconbalancedue
        -- follow it; paidamount and pay_id are untouched, because no money
        -- moved against this demand today.
        EXECUTE format('UPDATE %I.feedemand
                          SET feeamount        = GREATEST(COALESCE(feeamount,0) - $1, 0),
                              balancedue       = GREATEST(COALESCE(balancedue,0) - $1, 0),
                              reconbalancedue  = GREATEST(COALESCE(reconbalancedue,0) - $1, 0),
                              paidstatus       = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0
                                                      THEN ''P'' ELSE ''U'' END
                        WHERE dem_id = $2 AND activestatus = 1', v_schema)
          USING itm.amount, itm.dem_id;
      ELSE
        -- STUDENT advance: settles the demand exactly as cash would.
        --
        -- reconbalancedue comes down WITH the balance, but only when the
        -- advance's own money is already confirmed. That figure means "owed
        -- after reconciliation", and an advance taken in cash was banked the
        -- day it was received -- leaving it alone reported the fee as still
        -- outstanding after it had been settled (a 65,000 demand with 500 left
        -- showed 35,500 owed). An advance still waiting on a cheque has not
        -- been confirmed, so it stays up until the bank says so.
        IF v_adv_reconciled THEN
          EXECUTE format('UPDATE %I.feedemand
                            SET paidamount      = COALESCE(paidamount,0) + $1,
                                balancedue      = GREATEST(COALESCE(balancedue,0) - $1, 0),
                                reconbalancedue = GREATEST(COALESCE(reconbalancedue,0) - $1, 0),
                                paidstatus      = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                                pay_id          = $2
                          WHERE dem_id = $3 AND activestatus = 1', v_schema)
            USING itm.amount, v_pay_id, itm.dem_id;
        ELSE
          EXECUTE format('UPDATE %I.feedemand
                            SET paidamount = COALESCE(paidamount,0) + $1,
                                balancedue = GREATEST(COALESCE(balancedue,0) - $1, 0),
                                paidstatus = CASE WHEN GREATEST(COALESCE(balancedue,0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                                pay_id     = $2
                          WHERE dem_id = $3 AND activestatus = 1', v_schema)
            USING itm.amount, v_pay_id, itm.dem_id;
        END IF;
      END IF;

      EXECUTE format('INSERT INTO %I.advadjustment
                        (adv_id, ins_id, stu_id, dem_id, pay_id, paynumber,
                         demfeeterm, demfeetype, adjustamount, createdby)
                      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)', v_schema)
        USING p_adv_id, v_ins, v_adv.stu_id, itm.dem_id, v_pay_id, v_paynumber,
              v_term, v_type, itm.amount, COALESCE(p_created_by, v_adv.createdby);

      v_group_total := v_group_total + itm.amount;
    END LOOP;

    IF v_pay_id IS NOT NULL THEN
      EXECUTE format('UPDATE %I.payment SET transtotalamount = $1 WHERE pay_id = $2', v_schema)
        USING v_group_total, v_pay_id;

      -- 'receipts' stays EMPTY for an admission advance, and the app reads it:
      -- no receipt number is quoted to the cashier because none exists.
      v_result := v_result || jsonb_build_object(
        'pay_id', v_pay_id, 'paynumber', v_paynumber, 'fg_id', v_fg_id, 'amount', v_group_total);
    END IF;
  END LOOP;

  -- Finally draw the advance down. balanceamount is generated, so it follows.
  EXECUTE format('UPDATE %I.advance_collection
                    SET adjustedamount = COALESCE(adjustedamount,0) + $1
                  WHERE adv_id = $2', v_schema)
    USING v_total, p_adv_id;

  RETURN jsonb_build_object('advno', v_adv.advno, 'adjusted', v_total, 'receipts', v_result);
END; $$;

GRANT EXECUTE ON FUNCTION public.adjust_advance(text, bigint, jsonb, text, bigint) TO anon, authenticated;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- every row below should read as described.
-- ============================================================================

-- 1. All three tables exist in every institution schema.
SELECT table_schema, table_name
  FROM information_schema.tables
 WHERE table_name IN ('advance_collection','advance_detail','advadjustment')
 ORDER BY table_schema, table_name;

-- 2. Both RPCs are SECURITY DEFINER and callable by anon. save_advance_collection
--    must show THREE arguments (p_token text, p_header jsonb, p_lines jsonb)
--    and appear exactly ONCE -- a second, 2-argument row means the DROP did not
--    take and PostgREST has an ambiguous overload.
SELECT p.proname,
       p.prosecdef                                      AS security_definer,   -- expect t
       has_function_privilege('anon', p.oid, 'EXECUTE')  AS anon_can_execute,   -- expect t
       pg_get_function_identity_arguments(p.oid)         AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('save_advance_collection','adjust_advance')
 ORDER BY p.proname, args;

-- 3. anon can READ the money tables but NOT write them.
SELECT table_schema, table_name,
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'SELECT') AS anon_select,              -- expect t
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'INSERT') AS anon_insert_expect_false, -- expect f
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'UPDATE') AS anon_update_expect_false, -- expect f
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'DELETE') AS anon_delete_expect_false  -- expect f
  FROM information_schema.tables
 WHERE table_name IN ('advance_collection','advance_detail','advadjustment')
 ORDER BY table_schema, table_name;

-- 4. Does the Advance No sequence exist yet? "No ADVNO sequence anywhere yet"
--    is normal on a fresh install -- create it in Fee Master -> Advance No
--    before collecting. Walks every schema, so it needs no schema name.
DO $chk$
DECLARE s text; r record; found boolean := false;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'sequence')
       AND nspname NOT IN ('public','information_schema')
       AND nspname NOT LIKE 'pg\_%'
  LOOP
    FOR r IN EXECUTE format(
      'SELECT ins_id, seqprefix, seqwidth, seqcurno,
              seqprefix || lpad((seqcurno + 1)::bigint::text, seqwidth::int, ''0'') AS next_advno
         FROM %I.sequence WHERE actname = ''ADVNO'' AND activestatus = 1', s)
    LOOP
      found := true;
      RAISE NOTICE 'ADVNO in %: ins_id=% prefix=% width=% current=% -> next receipt %',
        s, r.ins_id, r.seqprefix, r.seqwidth, r.seqcurno, r.next_advno;
    END LOOP;
  END LOOP;
  IF NOT found THEN
    RAISE NOTICE 'No ADVNO sequence anywhere yet -- create one in Fee Master -> Advance No.';
  END IF;
END
$chk$;


-- ############################################################################
-- PART 2 of 5 -- ADVANCE_CANCEL_REFUND.sql
--
-- Cancel / refund an advance, and let void_receipt cancel an advance-adjustment receipt (it replaces public.void_receipt -- see the PRE-FLIGHT note).
-- ############################################################################

-- ============================================================================
-- Advance Collection -- stage 3: CANCEL and REFUND an advance receipt.
--
-- An advance is money in hand like any other receipt, so the two screens that
-- undo money must reach it:
--
--   Fee Cancel Receipt  ->  void_advance_receipt()
--   Fee Refund          ->  refund_advance()
--
-- WHY TWO VERBS, AND WHEN EACH ONE IS RIGHT
--   CANCEL is for a receipt that should never have existed -- wrong student,
--   wrong amount, keyed twice. The advance is struck out whole. It is refused
--   once ANY of it has been applied to a fee, because a demand has already been
--   settled or reduced on the strength of it: reverse that first, from Fee
--   Cancel Receipt (a student advance's adjustment receipt) or by collecting
--   the fee again (an admission advance's reduction).
--
--   REFUND is for money the institution is giving back -- the student left, or
--   took an advance they no longer need. The receipt stays valid and what was
--   already spent on fees stays spent; only the UNUSED balance goes back.
--
-- BANK PROTECTION, same rule the fee and misc voids use: a non-cash receipt the
-- bank has already confirmed (recon_status 'R') cannot be cancelled behind the
-- statement's back. Cash never reconciles, so it stays cancellable.
--
-- BALANCE, never recomputed by hand. advance_collection.balanceamount is
--     transtotalamount - adjustedamount - refund_amount
-- as a generated column, so a refund only has to add to refund_amount and the
-- balance follows. Nothing can drift.
--
-- The refund voucher is an ordinary fee_refund row, so the existing refund
-- register lists it beside every other refund:
--     pay_id     NULL      -- an advance is not a payment row
--     paynumber  AD26/...  -- the advance receipt it came off
--     one fee_refunddetails line, dem_id NULL, refundfeetype 'ADVANCE'
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). No data is touched. TEST first.
-- ============================================================================


-- ============================================================================
-- void_advance_receipt(p_token, p_adv_id, p_user, p_reason)
--
-- Session-gated: ins_id and the schema come from the token, never from the
-- caller, so one institution cannot cancel another's receipt.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.void_advance_receipt(
  p_token text, p_adv_id bigint, p_user text DEFAULT NULL, p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text; v_adv RECORD; v_is_cash boolean;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- Locked: a cancel and an adjustment must not cross.
  EXECUTE format('SELECT adv_id, advno, advtype, transtotalamount, adjustedamount,
                         refund_amount, balanceamount, paymethod, paystatus,
                         COALESCE(recon_status, ''P'') AS recon_status, activestatus
                    FROM %I.advance_collection
                   WHERE adv_id = $1 AND ins_id = $2 FOR UPDATE', v_schema)
    INTO v_adv USING p_adv_id, v_ins;

  IF v_adv.adv_id IS NULL THEN
    RAISE EXCEPTION 'Advance receipt % not found', p_adv_id;
  END IF;
  IF v_adv.activestatus <> 1 OR v_adv.paystatus = 'R' THEN
    RAISE EXCEPTION 'Advance % is already cancelled', v_adv.advno USING ERRCODE = 'P0001';
  END IF;

  -- Already spent on fees: the demand it touched has to be put back first.
  IF COALESCE(v_adv.adjustedamount, 0) > 0.005 THEN
    RAISE EXCEPTION 'Advance % has % already applied to fees. Reverse the adjustment before cancelling it.',
      v_adv.advno, to_char(v_adv.adjustedamount, 'FM99,99,99,990.00') USING ERRCODE = 'P0001';
  END IF;
  -- Partly given back already: cancelling would erase the record of a refund
  -- that actually happened.
  IF COALESCE(v_adv.refund_amount, 0) > 0.005 THEN
    RAISE EXCEPTION 'Advance % has % already refunded and cannot be cancelled.',
      v_adv.advno, to_char(v_adv.refund_amount, 'FM99,99,99,990.00') USING ERRCODE = 'P0001';
  END IF;

  v_is_cash := LOWER(COALESCE(v_adv.paymethod, '')) LIKE '%cash%';
  IF v_adv.recon_status = 'R' AND NOT v_is_cash THEN
    RAISE EXCEPTION 'Advance % is reconciled with the bank and cannot be cancelled',
      v_adv.advno USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('UPDATE %I.advance_collection
                     SET paystatus    = ''R'',
                         activestatus = 9,
                         voidedby     = $1,
                         voideddate   = now(),
                         voidreason   = $2
                   WHERE adv_id = $3 AND ins_id = $4', v_schema)
    USING p_user, NULLIF(p_reason, ''), p_adv_id, v_ins;

  -- The fee-type breakdown goes with it, so a cancelled advance cannot turn up
  -- in the Advance Adjustment screen's HELD column.
  EXECUTE format('UPDATE %I.advance_detail SET activestatus = 9 WHERE adv_id = $1', v_schema)
    USING p_adv_id;

  RETURN jsonb_build_object(
    'adv_id', v_adv.adv_id, 'advno', v_adv.advno,
    'amount', v_adv.transtotalamount, 'cancelled', true);
END; $$;

GRANT EXECUTE ON FUNCTION public.void_advance_receipt(text, bigint, text, text) TO anon, authenticated;


-- ============================================================================
-- refund_advance(p_token, p_header)
--
-- p_header: adv_id, amount, refundmode, refunddate, refundreason,
--           ban_id, bankname, bankref, chequedate, accountcode, createdby
--
-- Returns the voucher: {rf_id, doc_no, advno, refunded, balance_left}.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refund_advance(
  p_token text, p_header jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text; v_adv RECORD;
  v_amount numeric; v_rf_id bigint;
  v_seq_id integer; v_num integer; v_scur numeric; v_sstart numeric;
  v_prefix text; v_width int; v_docno text;
  v_yrid integer; v_yrlabel text; v_left numeric;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_amount := ROUND(COALESCE((p_header->>'amount')::numeric, 0), 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Refund amount must be greater than zero' USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format('SELECT adv_id, advno, advtype, inscode, stu_id, stuadmno, stuname,
                         stuclass, yr_id, yrlabel, transtotalamount, adjustedamount,
                         refund_amount, balanceamount, paystatus, activestatus
                    FROM %I.advance_collection
                   WHERE adv_id = $1 AND ins_id = $2 FOR UPDATE', v_schema)
    INTO v_adv USING (p_header->>'adv_id')::bigint, v_ins;

  IF v_adv.adv_id IS NULL THEN
    RAISE EXCEPTION 'Advance receipt % not found', p_header->>'adv_id';
  END IF;
  IF v_adv.activestatus <> 1 OR v_adv.paystatus = 'R' THEN
    RAISE EXCEPTION 'Advance % is cancelled', v_adv.advno USING ERRCODE = 'P0001';
  END IF;
  -- Only the UNUSED balance can go back: what has already settled a fee is not
  -- the institution's to return twice.
  IF v_amount > COALESCE(v_adv.balanceamount, 0) + 0.005 THEN
    RAISE EXCEPTION 'Refunding % exceeds the % still unused on advance %.',
      to_char(v_amount, 'FM99,99,99,990.00'),
      to_char(COALESCE(v_adv.balanceamount, 0), 'FM99,99,99,990.00'),
      v_adv.advno USING ERRCODE = 'P0001';
  END IF;

  -- Active academic year, resolved server-side like process_refund does.
  BEGIN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id = $1 AND activestatus = 1
                     ORDER BY yr_id DESC LIMIT 1', v_schema)
      INTO v_yrid, v_yrlabel USING v_ins;
  EXCEPTION WHEN OTHERS THEN v_yrid := NULL; v_yrlabel := NULL;
  END;

  -- doc_no from the REFNO sequence, drawn FOR UPDATE, exactly as a fee refund
  -- does -- so advance refunds and fee refunds share one voucher series.
  EXECUTE format('SELECT seq_id, seqstart, seqcurno, seqprefix, seqwidth FROM %I.sequence
                   WHERE ins_id = $1 AND actname = ''REFNO'' AND activestatus = 1
                   ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_sstart, v_scur, v_prefix, v_width USING v_ins;
  IF v_seq_id IS NOT NULL THEN
    v_num := (CASE WHEN COALESCE(v_scur, 0) < COALESCE(v_sstart, 1)
                   THEN COALESCE(v_sstart, 1) ELSE v_scur + 1 END)::integer;
    v_docno := COALESCE(v_prefix, '') || LPAD(v_num::text, COALESCE(v_width, 5)::int, '0');
    EXECUTE format('UPDATE %I.sequence SET seqcurno = $1 WHERE seq_id = $2', v_schema)
      USING v_num, v_seq_id;
  ELSE
    v_docno := NULLIF(p_header->>'doc_no', '');
  END IF;
  IF v_docno IS NULL THEN
    RAISE EXCEPTION 'No Refund No sequence configured. Add a REFNO sequence in Fee Master first.'
      USING ERRCODE = 'P0001';
  END IF;

  EXECUTE format(
    'INSERT INTO %I.fee_refund(doc_no,ins_id,inscode,yr_id,yrlabel,refunddate,pay_id,paynumber,
                               stu_id,stuadmno,stuname,stuclass,refundmode,ban_id,bankname,bankref,
                               chequedate,accountcode,refundreason,totalrefund,totaladjust,
                               createdby,activestatus)
     VALUES($1,$2,$3,$4,$5,COALESCE(NULLIF($6,'''')::date, CURRENT_DATE),NULL,$7,
            $8,$9,$10,$11,$12,$13,$14,$15,
            NULLIF($16,'''')::date,$17,$18,$19,0,
            $20,1) RETURNING rf_id', v_schema)
  INTO v_rf_id USING
    v_docno, v_ins, v_adv.inscode, COALESCE(v_adv.yr_id, v_yrid),
    COALESCE(NULLIF(v_adv.yrlabel, ''), v_yrlabel),
    p_header->>'refunddate', v_adv.advno,
    v_adv.stu_id, v_adv.stuadmno, v_adv.stuname, v_adv.stuclass,
    COALESCE(NULLIF(p_header->>'refundmode', ''), 'Cash'),
    NULLIF(p_header->>'ban_id', '')::integer,
    p_header->>'bankname', p_header->>'bankref', p_header->>'chequedate',
    p_header->>'accountcode', p_header->>'refundreason',
    v_amount, p_header->>'createdby';

  -- dem_id NULL: an advance is not owed against any one demand. The line still
  -- names what it was, so the refund register reads the same as every other.
  EXECUTE format(
    'INSERT INTO %I.fee_refunddetails(rf_id,dem_id,ins_id,refundterm,refundfeetype,
                                      feeamount,refundamount,adjustamount,activestatus)
     VALUES($1,NULL,$2,''Advance'',''ADVANCE'',$3,$4,0,1)', v_schema)
    USING v_rf_id, v_ins, v_adv.transtotalamount, v_amount;

  -- balanceamount is generated from this, so the advance's remaining balance
  -- follows on its own.
  EXECUTE format('UPDATE %I.advance_collection
                     SET refund_amount = COALESCE(refund_amount, 0) + $1
                   WHERE adv_id = $2 AND ins_id = $3', v_schema)
    USING v_amount, v_adv.adv_id, v_ins;

  EXECUTE format('SELECT balanceamount FROM %I.advance_collection WHERE adv_id = $1', v_schema)
    INTO v_left USING v_adv.adv_id;

  RETURN jsonb_build_object(
    'rf_id', v_rf_id, 'doc_no', v_docno, 'advno', v_adv.advno,
    'refunded', v_amount, 'balance_left', v_left);
END; $$;

GRANT EXECUTE ON FUNCTION public.refund_advance(text, jsonb) TO anon, authenticated;


-- ============================================================================
-- void_receipt_with_advance(p_token, p_pay_id, p_user, p_reason)
--
-- Cancelling a fee receipt that an ADVANCE helped settle. void_receipt on its
-- own puts the demand back but leaves the advance showing the money as spent,
-- so the student would lose it: the fee is owed again AND the advance is gone.
-- This wrapper does both halves in one transaction --
--
--   1. void_receipt()  -- restores every demand, voids the payment for audit
--   2. hands the advance's share back: advance_collection.adjustedamount comes
--      down by what this receipt took, so balanceamount (generated) rises again
--   3. deactivates the advadjustment rows, so nothing is netted off twice in
--      Daily Collection or the dashboard
--
-- A receipt with no advance behind it behaves exactly as void_receipt does.
--
-- REFUSED for an ADMISSION advance. That adjustment reduced feeamount rather
-- than paying it, so void_receipt's reversal (paidamount down, balance up) is
-- the wrong shape entirely -- it would bill the student for money they handed
-- over at admission. Legacy receipts only: the current adjust_advance raises no
-- receipt for an admission advance at all.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.void_receipt_with_advance(
  p_token text, p_pay_id bigint, p_user text DEFAULT NULL, p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE
  v_ins integer; v_schema text; v_res jsonb;
  v_total numeric := 0; v_admission integer := 0; r RECORD;
  v_pm text; v_rs text; v_host_restores boolean;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- No advance module on this database: an ordinary void is all there is to do.
  IF to_regclass(format('%I.advadjustment', v_schema)) IS NULL THEN
    RETURN COALESCE(public.void_receipt(v_ins, p_pay_id, p_user, p_reason), '{}'::jsonb);
  END IF;

  EXECUTE format('SELECT count(*)
                    FROM %I.advadjustment aj
                    JOIN %I.advance_collection a ON a.adv_id = aj.adv_id
                   WHERE aj.pay_id = $1 AND aj.ins_id = $2 AND aj.activestatus = 1
                     AND COALESCE(a.advtype, ''S'') = ''A''', v_schema, v_schema)
    INTO v_admission USING p_pay_id, v_ins;
  IF v_admission > 0 THEN
    RAISE EXCEPTION 'This receipt carries an ADMISSION advance, which reduced the fee rather than paying it. Cancelling it here would bill the student twice -- reverse it from the Advance side instead.'
      USING ERRCODE = 'P0001';
  END IF;

  -- Will void_receipt put reconbalancedue back on our behalf? It does that for
  -- cash and for a cleared advance-adjustment receipt. When the advance rode on
  -- a cheque or UPI receipt instead, it will not -- and the advance's own share
  -- DID come off reconbalancedue when it was applied, so this has to restore it.
  EXECUTE format('SELECT LOWER(COALESCE(paymethod, '''')), COALESCE(recon_status, ''P'')
                    FROM %I.payment WHERE pay_id = $1 AND ins_id = $2', v_schema)
    INTO v_pm, v_rs USING p_pay_id, v_ins;
  v_host_restores := (v_pm = 'cash') OR (v_pm = 'advance adjustment' AND v_rs = 'R');

  -- Demands first: if this refuses (reconciled receipt, already void), nothing
  -- has been handed back to any advance.
  v_res := public.void_receipt(v_ins, p_pay_id, p_user, p_reason);

  IF NOT v_host_restores THEN
    FOR r IN EXECUTE format('SELECT aj.dem_id, SUM(aj.adjustamount) AS amt
                               FROM %I.advadjustment aj
                               JOIN %I.advance_collection a ON a.adv_id = aj.adv_id
                              WHERE aj.pay_id = $1 AND aj.ins_id = $2 AND aj.activestatus = 1
                                AND COALESCE(a.recon_status, ''P'') = ''R''
                              GROUP BY aj.dem_id', v_schema, v_schema)
             USING p_pay_id, v_ins
    LOOP
      EXECUTE format('UPDATE %I.feedemand
                         SET reconbalancedue = COALESCE(reconbalancedue, 0) + $1
                       WHERE dem_id = $2 AND ins_id = $3', v_schema)
        USING r.amt, r.dem_id, v_ins;
    END LOOP;
  END IF;

  FOR r IN EXECUTE format('SELECT adv_id, SUM(adjustamount) AS amt
                             FROM %I.advadjustment
                            WHERE pay_id = $1 AND ins_id = $2 AND activestatus = 1
                            GROUP BY adv_id', v_schema)
           USING p_pay_id, v_ins
  LOOP
    EXECUTE format('UPDATE %I.advance_collection
                       SET adjustedamount = GREATEST(COALESCE(adjustedamount, 0) - $1, 0)
                     WHERE adv_id = $2 AND ins_id = $3', v_schema)
      USING r.amt, r.adv_id, v_ins;
    v_total := v_total + COALESCE(r.amt, 0);
  END LOOP;

  EXECUTE format('UPDATE %I.advadjustment SET activestatus = 9
                   WHERE pay_id = $1 AND ins_id = $2 AND activestatus = 1', v_schema)
    USING p_pay_id, v_ins;

  RETURN COALESCE(v_res, '{}'::jsonb)
         || jsonb_build_object('returned_to_advance', v_total);
END; $$;

GRANT EXECUTE ON FUNCTION public.void_receipt_with_advance(text, bigint, text, text) TO anon, authenticated;



-- ============================================================================
-- void_receipt -- an ADVANCE ADJUSTMENT receipt is not a bank-matched receipt.
--
-- adjust_advance writes its receipt with recon_status 'R' because no bank line
-- will ever arrive for it: the money was banked when the advance was taken.
-- void_receipt read that 'R' as "the bank has confirmed this" and refused to
-- cancel it, so an advance applied to the wrong fee could not be undone at all.
--
-- Two named conditions replace the single cash test:
--   v_no_bank_leg    -- paymethod 'Advance Adjustment'; never protect it
--   v_restore_recon  -- did this receipt actually reduce reconbalancedue when
--                       it was taken? Cash always did; an advance adjustment
--                       did when the advance behind it had cleared
--
-- Everything else is reproduced verbatim from complete_setup.sql so nothing
-- else drifts. SAFE TO RE-RUN. No data is touched.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.void_receipt(p_ins_id integer, p_pay_id bigint, p_user text, p_reason text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
DECLARE
  v text; p RECORD; d RECORD; v_is_cash boolean;
  v_no_bank_leg boolean; v_restore_recon boolean;
  v_fee numeric; v_con numeric; v_paid numeric; v_bal numeric; v_recon numeric;
  v_newpaid numeric; v_newbal numeric; v_delta numeric;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema found for ins_id %', p_ins_id; END IF;

  -- Lock the receipt row so a concurrent void/reconcile serialises.
  EXECUTE format('SELECT pay_id, paymethod, recon_status, activestatus, paynumber FROM %I.payment WHERE pay_id=$1 AND ins_id=$2 FOR UPDATE', v)
    INTO p USING p_pay_id, p_ins_id;
  IF p.pay_id IS NULL THEN
    RAISE EXCEPTION 'Receipt not found' USING ERRCODE = 'P0001';
  END IF;
  IF p.activestatus = 9 THEN
    RAISE EXCEPTION 'Receipt is already deleted' USING ERRCODE = 'P0001';
  END IF;

  v_is_cash := LOWER(COALESCE(p.paymethod, '')) = 'cash';
  -- An 'Advance Adjustment' receipt has NO BANK LEG. The money was banked when
  -- the advance was taken; adjust_advance marks the receipt reconciled for that
  -- reason alone, not because a statement line matched it. Treating that as
  -- bank-matched made such a receipt impossible to cancel at all -- the one
  -- receipt a cashier most often needs to undo, because it is how an advance is
  -- applied to the wrong fee.
  v_no_bank_leg := LOWER(COALESCE(p.paymethod, '')) = 'advance adjustment';
  -- Protect genuinely bank-matched (non-cash reconciled) receipts.
  IF p.recon_status = 'R' AND NOT v_is_cash AND NOT v_no_bank_leg THEN
    RAISE EXCEPTION 'Receipt % is reconciled with the bank and cannot be deleted', p.paynumber USING ERRCODE = 'P0001';
  END IF;
  -- Whether reconbalancedue must be put back is a separate question: it was
  -- only ever reduced by a receipt that counted as reconciled when it was
  -- taken. Cash always did; an advance adjustment did if the advance behind it
  -- had cleared.
  v_restore_recon := v_is_cash OR (v_no_bank_leg AND p.recon_status = 'R');

  -- Restore every demand this receipt settled. Cash also reduced
  -- reconbalancedue at collection, so add that back too; non-cash pending
  -- receipts never touched reconbalancedue.
  FOR d IN EXECUTE format('SELECT dem_id, transtotalamount FROM %I.paymentdetails WHERE pay_id=$1 AND activestatus=1', v) USING p_pay_id LOOP
    -- Take the receipt's money back off the demand, then RECOMPUTE the balance
    -- from the invariant the rest of the system uses (feeamount - conamount -
    -- paidamount) rather than adding the receipt amount back on. Incrementing
    -- is right only when the demand was not over-collected: voiding one of two
    -- duplicate receipts (fee 300, paid 600, balance 0) has to leave the demand
    -- settled at 300/300, and bal + amount would re-bill a student who is
    -- square. It also gets fines right -- a receipt carries balance + fine, so
    -- adding the whole receipt back over-billed by the fine.
    -- paidstatus now follows the recomputed balance instead of being forced to
    -- 'U': another receipt may still cover this demand in full.
    EXECUTE format('SELECT feeamount, conamount, paidamount, balancedue, reconbalancedue FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2 FOR UPDATE', v)
      INTO v_fee, v_con, v_paid, v_bal, v_recon USING d.dem_id, p_ins_id;
    CONTINUE WHEN v_fee IS NULL;
    v_newpaid := GREATEST(COALESCE(v_paid,0) - d.transtotalamount, 0);
    v_newbal  := GREATEST(COALESCE(v_fee,0) - COALESCE(v_con,0) - v_newpaid, 0);
    v_delta   := v_newbal - COALESCE(v_bal,0);
    IF v_restore_recon THEN
      -- Cash also reduced reconbalancedue at collection, so move it back by
      -- however much the balance actually moved. An advance adjustment did the
      -- same, for the same reason.
      EXECUTE format('UPDATE %I.feedemand SET paidamount=$1, balancedue=$2, reconbalancedue=$3, paidstatus=$4, pay_id=NULL WHERE dem_id=$5 AND ins_id=$6', v)
        USING v_newpaid, v_newbal, GREATEST(COALESCE(v_recon, v_bal, 0) + v_delta, 0),
              CASE WHEN v_newbal > 0 THEN 'U' ELSE 'P' END, d.dem_id, p_ins_id;
    ELSE
      EXECUTE format('UPDATE %I.feedemand SET paidamount=$1, balancedue=$2, paidstatus=$3, pay_id=NULL WHERE dem_id=$4 AND ins_id=$5', v)
        USING v_newpaid, v_newbal, CASE WHEN v_newbal > 0 THEN 'U' ELSE 'P' END, d.dem_id, p_ins_id;
    END IF;
  END LOOP;

  -- Soft-void: keep the payment for audit, deactivate its details.
  EXECUTE format('UPDATE %I.paymentdetails SET activestatus=9 WHERE pay_id=$1', v) USING p_pay_id;
  EXECUTE format('UPDATE %I.payment SET activestatus=9, paystatus=''R'', voidedby=$1, voideddate=now(), voidreason=$2 WHERE pay_id=$3', v)
    USING p_user, NULLIF(TRIM(COALESCE(p_reason, '')), ''), p_pay_id;

  RETURN jsonb_build_object('voided', p_pay_id, 'paynumber', p.paynumber);
END; $_$;
GRANT EXECUTE ON FUNCTION public.void_receipt(integer, bigint, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- expect four rows, every flag t (advance_adjustment_cancellable
-- is meaningful only on void_receipt; the other three read f).
-- ============================================================================
SELECT p.proname,
       p.prosecdef                                      AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
       pg_get_function_identity_arguments(p.oid)        AS args,
       p.prosrc LIKE '%v_no_bank_leg%'                  AS advance_adjustment_cancellable
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('void_advance_receipt', 'refund_advance',
                     'void_receipt_with_advance', 'void_receipt')
 ORDER BY p.proname;


-- ############################################################################
-- PART 3 of 5 -- ADVANCE_BANK_RECON.sql
--
-- reconcile_advance_batch(): a non-cash advance settles in Bank Reconciliation.
-- ############################################################################

-- ============================================================================
-- Advance Collection -- stage 4: a non-cash advance reaches Bank Reconciliation.
--
-- save_advance_collection already marks cash 'R' and everything else 'P', the
-- same rule a misc receipt follows. But the Bank Reconciliation screen only
-- ever read payment and misc_collection, so an advance taken by cheque, UPI or
-- Paytm was written as pending and then had nowhere to go: it could not be
-- ticked, matched against a statement, or settled. It simply sat there.
--
-- This adds the missing half -- the batch approve -- and the screen now lists
-- advances alongside fee and misc receipts.
--
-- Mirrors reconcile_misc_batch exactly, including the guard that matters:
-- recon_status = 'P' in the WHERE clause, so approving twice cannot rewrite the
-- reconciled_by / reconciled_date of a receipt somebody else already settled.
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). TEST first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reconcile_advance_batch(
    p_ins_id    integer,
    p_adv_ids   bigint[],
    p_user      text,
    p_bank_ref  text DEFAULT NULL,
    p_bank_date text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
DECLARE v text; n integer := 0;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;
  IF p_adv_ids IS NULL OR array_length(p_adv_ids, 1) IS NULL THEN RETURN 0; END IF;

  EXECUTE format('UPDATE %I.advance_collection
                     SET recon_status    = ''R'',
                         reconciled_by   = $2,
                         reconciled_date = NOW(),
                         bank_reference  = COALESCE($3, bank_reference),
                         bank_date       = COALESCE($4::date, bank_date)
                   WHERE ins_id = $5 AND adv_id = ANY($1)
                     AND recon_status = ''P'' AND activestatus = 1', v)
    USING p_adv_ids, p_user, NULLIF(p_bank_ref, ''), NULLIF(p_bank_date, ''), p_ins_id;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END; $$;

GRANT EXECUTE ON FUNCTION public.reconcile_advance_batch(integer, bigint[], text, text, text) TO anon, authenticated;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- expect one row, both flags t.
-- ============================================================================
SELECT p.proname,
       p.prosecdef                                      AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'reconcile_advance_batch';


-- ############################################################################
-- PART 4 of 5 -- FIX_DAILY_FEETYPE_SPLIT_LINES.sql
--
-- Daily Collection: a fee settled in two pieces on one receipt no longer loses a piece (replaces the two report functions).
-- ############################################################################

-- ============================================================================
-- DAILY COLLECTION: a fee settled in two pieces on one receipt lost a piece.
--
-- SYMPTOM
-- A receipt that takes part of a fee in cash and part from an advance shows the
-- fee-type column SHORT, while Total is right:
--
--     FC26/02934   T/F 35,000   Total 35,500   Cash 500   Adjusted 35,000
--                      ^^^^^^ should be 35,500
--
-- CAUSE
-- Both report functions built the fee-type breakdown with
--
--     jsonb_object_agg(fd.demfeetype, pd.transtotalamount - fd.fineamount)
--
-- over one row per paymentdetails line. A demand settled twice on the same
-- receipt (cash + advance, or two part-payments) produces two rows with the
-- SAME key, and jsonb_object_agg keeps only the last one -- the 500 was
-- dropped. The same join counted the demand's fine once per line, and the
-- per-line subtraction took that fine off the fee more than once.
--
-- FIX
-- Aggregate per demand first, then per fee type, and take the fine off once.
-- Both functions get the same treatment, so the reconciled and unreconciled
-- sections cannot disagree.
--
-- Row totals are unaffected -- they were already summed from the collected
-- amounts -- so the day's money does not move. Only the breakdown is corrected.
--
-- Reproduced verbatim from complete_setup.sql apart from those two aggregates.
-- SAFE TO RE-RUN (CREATE OR REPLACE). No data is touched. TEST first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_daily_collection_report(
    p_schema TEXT, p_ins_id INT, p_from DATE, p_to DATE
) RETURNS TABLE (
    pay_id BIGINT, paynumber TEXT, stuadmno TEXT, stuname TEXT,
    courname TEXT, stuclass TEXT, semester TEXT, type TEXT, paymethod TEXT, createdby TEXT,
    fees_json JSONB, fine NUMERIC, total NUMERIC, paydate DATE
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  p.pay_id::BIGINT,
                p.paynumber::TEXT,
                s.stuadmno::TEXT,
                s.stuname::TEXT,
                s.courname::TEXT,
                s.stuclass::TEXT,
                COALESCE(fd.demfeeterm, '')::TEXT AS semester,
                (CASE WHEN BOOL_OR(UPPER(COALESCE(fd.demseqtype,''))='ARREAR') THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                p.paymethod::TEXT,
                COALESCE(p.createdby, '')::TEXT AS createdby,
                -- FEE ONLY, and SUMMED PER FEE TYPE.
                --
                -- A demand can appear on one receipt more than once -- part
                -- cash and part advance is the everyday case -- and
                -- jsonb_object_agg keeps only the LAST value for a repeated
                -- key. A 35,500 tuition fee settled as 500 cash + 35,000
                -- advance therefore printed as 35,000: the 500 vanished from
                -- the fee-type column while the row total still read 35,500.
                --
                -- The fine comes off ONCE PER DEMAND, not once per line.
                -- pd.transtotalamount includes the fine and fd.fineamount is
                -- the whole of it, so subtracting it from every line of a split
                -- demand understated the fee by the fine each extra time.
                (SELECT COALESCE(jsonb_object_agg(t.ft, t.amt)
                                 FILTER (WHERE t.ft IS NOT NULL), '{}'::jsonb)
                   FROM (SELECT d.demfeetype AS ft, SUM(d.amt) AS amt
                           FROM (SELECT fd2.demfeetype,
                                        SUM(pd2.transtotalamount)
                                          - COALESCE(MAX(fd2.fineamount), 0) AS amt
                                   FROM %1$I.paymentdetails pd2
                                   JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                                  WHERE pd2.pay_id = p.pay_id
                                    AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')
                                  GROUP BY fd2.demfeetype, fd2.dem_id) d
                          GROUP BY d.demfeetype) t) AS fees_json,
                -- One fine per DEMAND. SUM over the joined rows counted it
                -- again for every line a split demand added.
                (SELECT COALESCE(SUM(f.fineamount), 0)
                   FROM (SELECT DISTINCT fd2.dem_id, fd2.fineamount
                           FROM %1$I.paymentdetails pd2
                           JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                          WHERE pd2.pay_id = p.pay_id
                            AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')) f)::NUMERIC AS fine,
                COALESCE(SUM(pd.transtotalamount), MAX(p.transtotalamount), 0)::NUMERIC AS total,
                p.paydate::DATE
        FROM    %1$I.payment p
        LEFT JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
        LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
        LEFT JOIN %1$I.students s ON s.stu_id = p.stu_id
        WHERE   p.ins_id = %2$L AND p.activestatus = 1
            AND p.paystatus IN ('C','R') AND p.recon_status = 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $$;
GRANT EXECUTE ON FUNCTION public.get_daily_collection_report(TEXT, INT, DATE, DATE) TO anon, authenticated;


CREATE OR REPLACE FUNCTION public.get_daily_collection_unreconciled(
    p_schema TEXT, p_ins_id INT, p_from DATE, p_to DATE
) RETURNS TABLE (
    pay_id BIGINT, paynumber TEXT, stuadmno TEXT, stuname TEXT,
    courname TEXT, stuclass TEXT, semester TEXT, type TEXT, paymethod TEXT, createdby TEXT,
    fees_json JSONB, fine NUMERIC, total NUMERIC, paydate DATE
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  p.pay_id::BIGINT,
                p.paynumber::TEXT,
                s.stuadmno::TEXT,
                s.stuname::TEXT,
                s.courname::TEXT,
                s.stuclass::TEXT,
                COALESCE(fd.demfeeterm, '')::TEXT AS semester,
                (CASE WHEN BOOL_OR(UPPER(COALESCE(fd.demseqtype,''))='ARREAR') THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                p.paymethod::TEXT,
                COALESCE(p.createdby, '')::TEXT AS createdby,
                -- FEE ONLY, and SUMMED PER FEE TYPE.
                --
                -- A demand can appear on one receipt more than once -- part
                -- cash and part advance is the everyday case -- and
                -- jsonb_object_agg keeps only the LAST value for a repeated
                -- key. A 35,500 tuition fee settled as 500 cash + 35,000
                -- advance therefore printed as 35,000: the 500 vanished from
                -- the fee-type column while the row total still read 35,500.
                --
                -- The fine comes off ONCE PER DEMAND, not once per line.
                -- pd.transtotalamount includes the fine and fd.fineamount is
                -- the whole of it, so subtracting it from every line of a split
                -- demand understated the fee by the fine each extra time.
                (SELECT COALESCE(jsonb_object_agg(t.ft, t.amt)
                                 FILTER (WHERE t.ft IS NOT NULL), '{}'::jsonb)
                   FROM (SELECT d.demfeetype AS ft, SUM(d.amt) AS amt
                           FROM (SELECT fd2.demfeetype,
                                        SUM(pd2.transtotalamount)
                                          - COALESCE(MAX(fd2.fineamount), 0) AS amt
                                   FROM %1$I.paymentdetails pd2
                                   JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                                  WHERE pd2.pay_id = p.pay_id
                                    AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')
                                  GROUP BY fd2.demfeetype, fd2.dem_id) d
                          GROUP BY d.demfeetype) t) AS fees_json,
                -- One fine per DEMAND. SUM over the joined rows counted it
                -- again for every line a split demand added.
                (SELECT COALESCE(SUM(f.fineamount), 0)
                   FROM (SELECT DISTINCT fd2.dem_id, fd2.fineamount
                           FROM %1$I.paymentdetails pd2
                           JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                          WHERE pd2.pay_id = p.pay_id
                            AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')) f)::NUMERIC AS fine,
                COALESCE(SUM(pd.transtotalamount), MAX(p.transtotalamount), 0)::NUMERIC AS total,
                p.paydate::DATE
        FROM    %1$I.payment p
        LEFT JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
        LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
        LEFT JOIN %1$I.students s ON s.stu_id = p.stu_id
        WHERE   p.ins_id = %2$L AND p.activestatus = 1
            AND p.paystatus IN ('C','R')
            AND p.recon_status IS DISTINCT FROM 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $$;
GRANT EXECUTE ON FUNCTION public.get_daily_collection_unreconciled(TEXT, INT, DATE, DATE) TO anon, authenticated;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- expect both rows t.
-- ============================================================================
SELECT p.proname,
       p.prosrc LIKE '%GROUP BY fd2.demfeetype, fd2.dem_id%' AS sums_split_lines
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('get_daily_collection_report', 'get_daily_collection_unreconciled')
 ORDER BY p.proname;


-- ############################################################################
-- PART 5 of 5 -- fix_reconbalancedue_cash_payment.sql
--
-- A cash payment no longer wipes OTHER pending payments off reconbalancedue (replaces process_grouped_payment).
-- ############################################################################

-- ============================================================================
-- FIX: a cash payment wiped OTHER pending payments off reconbalancedue.
--
-- WHAT WENT WRONG
-- process_grouped_payment has two branches. Cash is auto-reconciled, so it
-- syncs reconbalancedue; everything else leaves it alone until the bank
-- confirms. The cash branch set
--
--     reconbalancedue = balancedue
--
-- which is only right when nothing else on that demand is awaiting
-- reconciliation. When something is, that assignment declares it reconciled
-- too, and the money vanishes from Outstanding without the bank ever
-- confirming it.
--
-- A real case (demand 9178, fee 82,500):
--     7,500  upi              pending
--    20,000  Online Transfer  pending
--    10,000  cash             auto-reconciled
--
--   before the cash:  balancedue 55,000   reconbalancedue 82,500
--   after  the cash:  balancedue 45,000   reconbalancedue 45,000   <-- wrong
--   correct:                              reconbalancedue 72,500
--
-- 27,500 of unconfirmed money disappeared, and the dashboard stopped adding up:
-- Total Fees Due - Total Collected no longer equalled Outstanding.
--
-- THE FIX
-- Reduce reconbalancedue by THIS payment's own amount instead of collapsing it:
--
--     reconbalancedue = GREATEST(COALESCE(reconbalancedue,0) - itm.amount, 0)
--
-- On a demand with nothing pending this gives exactly the same answer it gives
-- today, so ordinary collections are unaffected. On a demand that does have
-- pending payments it keeps them pending, which is the point.
--
-- Only the one line changes; the rest of the function is reproduced verbatim
-- from complete_setup.sql so nothing else drifts.
--
-- ALSO RUN migrations/QUERY_fix_reconbalancedue.sql to repair rows already
-- damaged by this. This migration stops it happening again; it does not go
-- back and correct history.
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). No data is touched. TEST first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_grouped_payment(
  p_ins_id integer, p_inscode varchar, p_stu_id bigint,
  p_yr_id integer, p_yrlabel varchar, p_total_amount numeric,
  p_created_by varchar, p_pay_method text, p_pay_reference text,
  p_items jsonb
) RETURNS jsonb
-- search_path is PINNED, matching what is already on live. A
-- SECURITY DEFINER function without it is a privilege-escalation vector
-- (and Supabase's advisor flags it). complete_setup.sql had lost this
-- clause, so rebuilding the function from it would have silently
-- stripped the hardening off live.
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $$
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
    -- Online-channel payments (razorpay / QR-UPI / online) stamp ban_id from
    -- the fee group so per-bank routing reports work. Cash / cheque / DD all
    -- land in one main account, so they leave ban_id NULL.
    EXECUTE format('INSERT INTO %1$I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,paydate,paystatus,paymethod,payreference,createdby,recon_status,reconciled_by,reconciled_date,ban_id) VALUES($1,$2,$3,$4,$5,0,''INR'',NOW(),''C'',$6,$7,$8,CASE WHEN LOWER($6)=''cash'' THEN ''R'' ELSE ''P'' END,CASE WHEN LOWER($6)=''cash'' THEN $8 ELSE NULL END,CASE WHEN LOWER($6)=''cash'' THEN NOW() ELSE NULL END,CASE WHEN LOWER($6) IN (''razorpay'',''upi'',''qr_upi'',''online'') THEN (SELECT ban_id FROM %1$I.feegroup WHERE fg_id=$9 LIMIT 1) ELSE NULL END) RETURNING pay_id',v)
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
END; $$;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- the cash branch must now decrement, not assign.
-- Expect: has_fix = t, still_collapses = f
-- ============================================================================
SELECT p.proname,
       prosrc LIKE '%reconbalancedue=GREATEST(COALESCE(reconbalancedue,0)-$5,0)%' AS has_fix,
       prosrc LIKE '%balancedue=$2,reconbalancedue=$2,%'                          AS still_collapses
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'process_grouped_payment';



-- ############################################################################
-- FINAL VERIFY -- one row per object. Every 'present' column should read t.
-- ############################################################################
NOTIFY pgrst, 'reload schema';

SELECT 'advance tables (per schema)' AS what,
       count(*) FILTER (WHERE table_name = 'advance_collection') AS advance_collection,
       count(*) FILTER (WHERE table_name = 'advance_detail')     AS advance_detail,
       count(*) FILTER (WHERE table_name = 'advadjustment')      AS advadjustment
  FROM information_schema.tables
 WHERE table_name IN ('advance_collection', 'advance_detail', 'advadjustment');

SELECT p.proname,
       p.prosecdef                                      AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
       CASE
         WHEN p.proname = 'adjust_advance'          THEN p.prosrc LIKE '%v_adv_reconciled%'
         WHEN p.proname = 'save_advance_collection' THEN p.prosrc LIKE '%fg_id=$2 AND activestatus=1%'
         WHEN p.proname = 'void_receipt'            THEN p.prosrc LIKE '%v_no_bank_leg%'
         WHEN p.proname = 'process_grouped_payment' THEN p.prosrc LIKE '%reconbalancedue=GREATEST(COALESCE(reconbalancedue,0)-$5,0)%'
         WHEN p.proname LIKE 'get_daily_collection%' THEN p.prosrc LIKE '%GROUP BY fd2.demfeetype, fd2.dem_id%'
         ELSE true
       END                                              AS carries_this_updates_change
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('save_advance_collection', 'adjust_advance', 'void_advance_receipt',
                     'refund_advance', 'void_receipt_with_advance', 'reconcile_advance_batch',
                     'get_daily_collection_report', 'get_daily_collection_unreconciled',
                     'process_grouped_payment', 'void_receipt')
 ORDER BY p.proname;

-- Numbering sequences (CONFIGURATION, not created by this file). A missing
-- ADVNO only blocks STUDENT advances; a missing REFNO only blocks refunds.
-- Both are added in Fee Master -> Advance No / Refund No.
DO $seqchk$
DECLARE r RECORD; v_adv int; v_ref int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'sequence' AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('SELECT count(*) FROM %I.sequence WHERE actname = ''ADVNO'' AND activestatus = 1', r.s) INTO v_adv;
    EXECUTE format('SELECT count(*) FROM %I.sequence WHERE actname = ''REFNO'' AND activestatus = 1', r.s) INTO v_ref;
    RAISE NOTICE '%: ADVNO %, REFNO %', r.s,
      CASE WHEN v_adv > 0 THEN 'configured' ELSE 'MISSING -- student advances will refuse' END,
      CASE WHEN v_ref > 0 THEN 'configured' ELSE 'MISSING -- refunds will refuse' END;
  END LOOP;
END $seqchk$;
