-- ============================================================================
-- Advance Collection — stage 1: tables, receipt sequence, collect RPC.
--
-- WHAT IT IS: money taken from a STUDENT before any fee is due. It is later
-- applied to specific fee demands ("adjusted"), which advadjustment records.
--
-- THERE ARE TWO KINDS, and advance_collection.advtype says which:
--   'A'  ADMISSION advance — collected BY FEE TYPE. The receipt carries a
--        breakdown (TUITION 10,000 / BUS 4,000 / …) in advance_detail, and the
--        header total is always the sum of those lines.
--   'S'  STUDENT advance — a plain amount, no breakdown, no advance_detail
--        rows at all.
-- Both are held against the student the same way and both are spent the same
-- way. The breakdown is a record of what the money was taken FOR; it does not
-- bind the adjustment, which stays manual on the Fee Collection screen.
--
--   advance_collection   header, mirroring `payment` (same money/reconcile
--                        columns, so Bank Reconciliation and the collection
--                        reports can treat it the same way). No fg_id / fee_id
--                        on the header -- an advance is not one fee.
--   advance_detail       fee-type breakdown of an ADMISSION advance (mirrors
--                        misc_collection_detail). Empty for a student advance.
--   advadjustment        one row per amount applied from an advance to a fee
--                        demand. Stage 2 fills these in.
--
-- BALANCE is a generated column: transtotalamount - adjustedamount - refund.
-- It can never drift from its parts, so no trigger is needed to maintain it.
--
-- RECEIPT NUMBER comes from the schema's own `sequence` table, actname='ADVNO'
-- (the DEMNO / CONNO / REFNO pattern). The row is NOT seeded here -- create it
-- in Fee Master → Advance No, exactly like Concession No and Refund No. Until
-- it exists, save_advance_collection refuses with a clear message rather than
-- inventing a number.
--
-- SECURITY: these are money tables, so anon's direct INSERT / UPDATE / DELETE
-- is revoked and all writes go through the SECURITY DEFINER, session-gated RPC
-- below. SELECT is left intact, as on the other money tables.
--
-- Applied to every institution schema. Idempotent throughout (IF NOT EXISTS +
-- ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE), so it is SAFE TO RE-RUN on a
-- schema that already has the first cut of these tables. Run on TEST first.
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

  -- Advance receipt number: its OWN sequence, separate from the fee receipt
  -- and demand sequences.
  EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5), COALESCE(seqprefix,'''')
                    FROM %I.sequence
                   WHERE ins_id=$1 AND actname=''ADVNO'' AND activestatus=1
                   ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins;
  IF v_seq_id IS NULL THEN
    RAISE EXCEPTION 'No Advance No sequence configured. Add one in Fee Master → Advance No first.';
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

NOTIFY pgrst, 'reload schema';

-- Verify 1: all three tables present in every institution schema
SELECT table_schema, table_name
  FROM information_schema.tables
 WHERE table_name IN ('advance_collection','advance_detail','advadjustment')
 ORDER BY table_schema, table_name;

-- Verify 2: the RPC is definer + callable, and takes three arguments
SELECT p.proname,
       p.prosecdef                                      AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE')  AS anon_can_execute,
       pg_get_function_identity_arguments(p.oid)         AS args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_advance_collection';

SELECT table_name,
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'SELECT') AS anon_select,
       has_table_privilege('anon', quote_ident(table_schema)||'.'||quote_ident(table_name), 'INSERT') AS anon_insert_should_be_false
  FROM information_schema.tables
 WHERE table_name IN ('advance_collection','advance_detail','advadjustment')
 ORDER BY table_name;
