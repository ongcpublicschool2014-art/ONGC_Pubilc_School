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
