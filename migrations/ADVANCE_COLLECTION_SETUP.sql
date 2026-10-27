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
