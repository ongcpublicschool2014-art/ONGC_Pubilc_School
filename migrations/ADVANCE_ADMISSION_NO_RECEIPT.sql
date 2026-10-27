-- ============================================================================
-- adjust_advance -- two corrections. Replaces the function whole.
--
-- 1. An ADMISSION advance no longer raises a receipt.
--
-- An admission advance is money taken from a student joining NEXT year, before
-- any bill exists. Applying it REDUCES the fee (feeamount comes down); it does
-- not pay one. Until now the standalone path still wrote a payment row for it,
-- so every reduction appeared in Daily Collection as a receipt for money that
-- was never handed over today -- and then had to be netted straight back out
-- again to stop the day's total double-counting it.
--
--   advtype 'A'  ->  no payment row, no paynumber, no paymentdetails.
--                    advadjustment is written with pay_id / paynumber NULL and
--                    is the only record. 'receipts' comes back empty.
--   advtype 'S'  ->  still raises a proper fee receipt: it settles the demand
--                    exactly as cash does.
--
-- 2. A STUDENT advance now brings reconbalancedue down with the balance.
--
-- reconbalancedue means "owed after reconciliation", and the dashboard's
-- Outstanding is its sum. The student branch moved balancedue and left
-- reconbalancedue alone, so a demand settled from an advance went on being
-- reported as owed: a 65,000 fee with 500 left showed 35,500 outstanding.
--
-- It follows the ADVANCE's own reconciliation state, not blindly: cash was
-- banked the day it was received, while an advance still waiting on a cheque
-- has not been confirmed and keeps the figure up until the bank says so. For
-- the same reason a standalone adjustment receipt now inherits the advance's
-- recon_status instead of always claiming 'R'.
--
-- Nothing already written is changed. Rows damaged by (2) before this fix are
-- repaired by migrations/QUERY_fix_reconbalancedue.sql, which recomputes
-- reconbalancedue from what is genuinely unreconciled.
--
-- The function below is the CURRENT one from
-- migrations/ADVANCE_COLLECTION_SETUP.sql, reproduced verbatim so the two
-- cannot drift. Running either file gives the same function.
--
-- SAFE TO RE-RUN (CREATE OR REPLACE). No data is touched. TEST first.
-- ============================================================================

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
-- VERIFY -- expect one row, every flag t.
-- ============================================================================
SELECT p.proname,
       p.prosecdef                                       AS security_definer,
       has_function_privilege('anon', p.oid, 'EXECUTE')  AS anon_can_execute,
       p.prosrc LIKE '%IF v_advtype <> ''A'' THEN%'      AS skips_receipt_for_admission,
       p.prosrc LIKE '%v_adv_reconciled%'                AS moves_reconbalancedue
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'adjust_advance';
