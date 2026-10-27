-- Money-invariant hardening. Three independent fixes, one script.
-- Every function here is a plain CREATE OR REPLACE: safe to re-run, and there
-- are no table, column or signature changes, so no client rebuild is required.
--
-- 1) void_receipt no longer ADDS the receipt back onto balancedue.
--    Same defect as the one fixed in fix_refund_balance_invariant.sql:
--    bal + amount is correct only when the demand was not over-collected.
--    Voiding one of two duplicate receipts (fee 300, paid 600, balance 0) now
--    leaves the demand settled at 300/300 instead of re-billing 300. It also
--    stops over-billing by the fine, since a receipt carries balance + fine.
--    paidstatus now follows the recomputed balance rather than being forced to
--    'U' -- another receipt may still cover the demand in full.
--
-- 2) An over-collection ceiling on ALL FOUR collection paths.
--    process_grouped_payment and complete_payment_grouped refused a payment
--    against a settled demand but capped nothing; complete_payment_atomic and
--    import_payment had no guard at all. All four now refuse an amount above
--    balance + fine (the fine belongs in the ceiling because a receipt
--    legitimately carries it). This is what would have stopped 600 being
--    collected against a 300 fee.
--    NOTE: on the online paths (complete_payment_atomic /
--    complete_payment_grouped) a raise means a payment already captured at the
--    gateway is not recorded and has to be refunded -- the same trade-off the
--    existing "already paid" guard has always made, now extended to the amount.
--
-- 3) apply_concession, save_fee_definition and rebuild_demand stop writing a
--    CLIENT-SUPPLIED balancedue. They keep p_balancedue in the signature (so
--    nothing breaks) but ignore the value and derive the balance from the row,
--    the way process_concession already does. Without this, Phase 3's REVOKE
--    would not actually close security finding #2: all three are granted to
--    anon, so any valid session could still set balancedue to anything.
--    In save_fee_definition p_balancedue is still read as a FLAG -- non-null
--    means "amount changed, recompute", null means "leave the outstanding".


-- ===== 1) void_receipt: derive the balance =====

CREATE OR REPLACE FUNCTION public.void_receipt(p_ins_id integer, p_pay_id bigint, p_user text, p_reason text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
DECLARE
  v text; p RECORD; d RECORD; v_is_cash boolean;
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
  -- Protect genuinely bank-matched (non-cash reconciled) receipts.
  IF p.recon_status = 'R' AND NOT v_is_cash THEN
    RAISE EXCEPTION 'Receipt % is reconciled with the bank and cannot be deleted', p.paynumber USING ERRCODE = 'P0001';
  END IF;

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
    IF v_is_cash THEN
      -- Cash also reduced reconbalancedue at collection, so move it back by
      -- however much the balance actually moved.
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

-- ===== 2) collection ceiling: balance + fine =====

CREATE OR REPLACE FUNCTION public.process_grouped_payment(
  p_ins_id integer, p_inscode varchar, p_stu_id bigint,
  p_yr_id integer, p_yrlabel varchar, p_total_amount numeric,
  p_created_by varchar, p_pay_method text, p_pay_reference text,
  p_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
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
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1,balancedue=$2,reconbalancedue=$2,paidstatus=CASE WHEN $2<=0 THEN ''P'' ELSE ''U'' END,pay_id=$3 WHERE dem_id=$4',v) USING v_new_paid,v_new_balance,v_pay_id,itm.dem_id;
      ELSE
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1,balancedue=$2,paidstatus=CASE WHEN $2<=0 THEN ''P'' ELSE ''U'' END,pay_id=$3 WHERE dem_id=$4',v) USING v_new_paid,v_new_balance,v_pay_id,itm.dem_id;
      END IF;
    END LOOP;
    EXECUTE format('UPDATE %I.payment SET transtotalamount=$1 WHERE pay_id=$2',v) USING v_group_total,v_pay_id;
    v_result := v_result || jsonb_build_object('pay_id',v_pay_id,'paynumber',v_pay_number,'fg_id',v_fg_id,'amount',v_group_total);
  END LOOP;
  RETURN v_result;
END; $$;

CREATE OR REPLACE FUNCTION public.complete_payment_grouped(
  p_pay_id bigint, p_pay_method text, p_pay_reference text,
  p_items jsonb, p_ins_id integer, p_status char DEFAULT 'C'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
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
    -- Razorpay payments stamp ban_id from the fee group so per-bank
    -- routing reports work. Cash / cheque / DD all land in one main
    -- account and leave ban_id NULL.
    EXECUTE format('INSERT INTO %1$I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,paydate,paystatus,paymethod,payreference,createdby,payorderid,recon_status,ban_id) VALUES($1,$2,$3,$4,$5,0,''INR'',NOW(),$6,$7,$8,$9,$10,''P'',CASE WHEN LOWER($7)=''razorpay'' THEN (SELECT ban_id FROM %1$I.feegroup WHERE fg_id=$11 LIMIT 1) ELSE NULL END) RETURNING pay_id',v)
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
END; $$;

CREATE OR REPLACE FUNCTION public.complete_payment_atomic(p_pay_id bigint, p_pay_method text, p_pay_reference text, p_items jsonb, p_ins_id integer) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_pay_number TEXT; v_item JSONB; v_dem_id BIGINT; v_amount NUMERIC; v_current_paid NUMERIC; v_current_balance NUMERIC; v_current_fine NUMERIC; v_new_paid NUMERIC; v_new_balance NUMERIC; v_stu_id BIGINT; v_pay_status CHAR(1); v text; v_seq RECORD; v_new_no INTEGER;
BEGIN
  v := get_institution_schema(p_ins_id); IF v IS NULL THEN RAISE EXCEPTION 'No schema'; END IF;
  EXECUTE format('SELECT paystatus,stu_id FROM %I.payment WHERE pay_id=$1 FOR UPDATE',v) INTO v_pay_status,v_stu_id USING p_pay_id;
  IF v_pay_status IS NULL THEN RAISE EXCEPTION 'Payment % not found',p_pay_id; END IF;
  IF v_pay_status!='I' THEN RAISE EXCEPTION 'Payment % not Initiated',p_pay_id; END IF;
  -- Generate pay number from first available RECEIPT sequence
  -- (fg_id IS NOT NULL excludes register-number sequences, which have fg_id NULL / actname 'REGNO').
  EXECUTE format('SELECT seq_id,sequid,seqwidth,seqcurno FROM %I.sequence WHERE ins_id=$1 AND fg_id IS NOT NULL LIMIT 1 FOR UPDATE',v) INTO v_seq USING p_ins_id;
  IF v_seq IS NULL THEN v_pay_number:='PAY'||p_pay_id;
  ELSE v_new_no:=v_seq.seqcurno+1; v_pay_number:=regexp_replace(v_seq.sequid,'\d+$','')||lpad(v_new_no::TEXT,v_seq.seqwidth::INTEGER,'0'); EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2',v) USING v_new_no,v_seq.seq_id;
  END IF;
  EXECUTE format('UPDATE %I.payment SET paystatus=''C'',paymethod=$1,payreference=$2,paynumber=$3,paydate=NOW(),recon_status=''P'' WHERE pay_id=$4',v) USING p_pay_method,p_pay_reference,v_pay_number,p_pay_id;
  -- Update fee demands atomically
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_dem_id:=(v_item->>'dem_id')::BIGINT; v_amount:=(v_item->>'amount')::NUMERIC;
    -- The guards the cash and grouped paths already had, which this one was
    -- missing entirely: serialise on the demand, refuse a payment against a
    -- settled demand, and refuse more than balance + fine.
    EXECUTE format('SELECT paidamount, balancedue, fineamount FROM %I.feedemand WHERE dem_id=$1 AND activestatus=1 FOR UPDATE', v)
      INTO v_current_paid, v_current_balance, v_current_fine USING v_dem_id;
    IF COALESCE(v_current_balance, 0) <= 0 THEN
      RAISE EXCEPTION 'Demand % is already paid (balance=%). Another payment may have been posted concurrently - please refresh.', v_dem_id, v_current_balance USING ERRCODE = 'P0001';
    END IF;
    IF v_amount > COALESCE(v_current_balance,0) + COALESCE(v_current_fine,0) + 0.005 THEN
      RAISE EXCEPTION 'Collection of % on demand % exceeds the amount due (balance % + fine %). Please refresh and try again.',
        v_amount, v_dem_id, COALESCE(v_current_balance,0), COALESCE(v_current_fine,0) USING ERRCODE = 'P0001';
    END IF;
    EXECUTE format('UPDATE %I.feedemand
                      SET paidamount = COALESCE(paidamount, 0) + $1,
                          balancedue = GREATEST(COALESCE(balancedue, 0) - $1, 0),
                          paidstatus = CASE WHEN GREATEST(COALESCE(balancedue, 0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                          pay_id     = $2
                      WHERE dem_id = $3 AND activestatus = 1', v)
    USING v_amount, p_pay_id, v_dem_id;
  END LOOP;
  RETURN v_pay_number;
END; $$;

CREATE OR REPLACE FUNCTION public.import_payment(
  p_ins_id integer, p_inscode text, p_stu_id integer, p_yr_id integer, p_yrlabel text,
  p_paynumber text, p_paydate timestamp, p_method text, p_reference text, p_created_by text,
  p_items jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; v_pay_id bigint; v_total numeric; it jsonb; v_dem integer; v_amt numeric;
  v_bal numeric; v_fine numeric;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;
  SELECT COALESCE(SUM((x->>'amount')::numeric), 0) INTO v_total FROM jsonb_array_elements(p_items) x;
  EXECUTE format(
    'INSERT INTO %I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,'
    'paydate,paystatus,paymethod,payreference,createdby,createdat,activestatus,paynumber,'
    'recon_status,reconciled_by,reconciled_date) '
    'VALUES($1,$2,$3,$4,$5,$6,''INR'',$7,''C'',$8,$9,$10,now(),1,$11,''R'',$10,$7) RETURNING pay_id', v)
    INTO v_pay_id
    USING p_ins_id, p_inscode, p_stu_id, p_yr_id, p_yrlabel, v_total, p_paydate, p_method, p_reference, p_created_by, p_paynumber;
  FOR it IN SELECT jsonb_array_elements(p_items) LOOP
    v_dem := NULLIF(it->>'dem_id','')::integer;
    v_amt := COALESCE((it->>'amount')::numeric, 0);
    IF v_dem IS NULL THEN CONTINUE; END IF;
    -- Refuse to post more than is owed. Re-running an import is the usual way a
    -- demand ends up collected twice; without this the second run silently
    -- doubles paidamount and the money has to be refunded afterwards.
    EXECUTE format('SELECT balancedue, fineamount FROM %I.feedemand WHERE dem_id=$1 AND activestatus=1 FOR UPDATE', v)
      INTO v_bal, v_fine USING v_dem;
    -- A missing or inactive demand is left exactly as it behaved before this
    -- guard existed: the detail row is still written and no demand is touched.
    -- Aborting an entire import over one unmatched line would be a new failure
    -- mode, and this change is only meant to stop over-collection.
    IF v_bal IS NOT NULL AND v_amt > COALESCE(v_bal,0) + COALESCE(v_fine,0) + 0.005 THEN
      RAISE EXCEPTION 'Imported receipt %: % on demand % exceeds the amount due (balance % + fine %). It may already have been imported.',
        p_paynumber, v_amt, v_dem, COALESCE(v_bal,0), COALESCE(v_fine,0) USING ERRCODE = 'P0001';
    END IF;
    EXECUTE format(
      'INSERT INTO %I.paymentdetails(pay_id,dem_id,yr_id,yrlabel,ins_id,transcurrency,transtotalamount,activestatus) '
      'VALUES($1,$2,$3,$4,$5,''INR'',$6,1)', v)
      USING v_pay_id, v_dem, p_yr_id, p_yrlabel, p_ins_id, v_amt;
    EXECUTE format(
      'UPDATE %I.feedemand SET paidamount=COALESCE(paidamount,0)+$1, '
      'balancedue=GREATEST(COALESCE(balancedue,0)-$1,0), '
      'reconbalancedue=GREATEST(COALESCE(reconbalancedue,0)-$1,0), '
      'paidstatus=CASE WHEN GREATEST(COALESCE(balancedue,0)-$1,0) <= 0 THEN ''P'' ELSE ''U'' END, '
      'pay_id=$2 WHERE dem_id=$3 AND activestatus=1', v)
      USING v_amt, v_pay_id, v_dem;
  END LOOP;
  RETURN v_pay_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.import_payment(integer,text,integer,integer,text,text,timestamp,text,text,text,jsonb) TO anon, authenticated;

-- ===== 3) derive balancedue instead of trusting the client =====

CREATE OR REPLACE FUNCTION public.apply_concession(
  p_token text, p_dem_id bigint, p_con_id integer, p_conamount numeric, p_balancedue numeric
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  -- p_balancedue stays in the signature for older clients but is deliberately
  -- IGNORED: the balance is derived from the row's own figures, exactly as
  -- process_concession does it. Taking the client's number meant anyone with a
  -- valid session could write any value into a money column -- the same hole
  -- the anon REVOKE is meant to close, reachable through the front door.
  EXECUTE format(
    'UPDATE %I.feedemand SET con_id = $1, conamount = $2, '
    'balancedue = GREATEST(COALESCE(feeamount,0) - $2 - COALESCE(paidamount,0), 0), '
    'reconbalancedue = GREATEST(COALESCE(feeamount,0) - $2 - COALESCE(paidamount,0), 0), '
    'paidstatus = CASE WHEN GREATEST(COALESCE(feeamount,0) - $2 - COALESCE(paidamount,0), 0) > 0 THEN ''U'' ELSE ''P'' END '
    'WHERE dem_id = $3 AND ins_id = $4', v_schema)
    USING p_con_id, COALESCE(p_conamount, 0), p_dem_id, v_ins;
END; $$;

CREATE OR REPLACE FUNCTION public.save_fee_definition(
  p_token text, p_dem_id bigint, p_feeamount numeric, p_collectible boolean, p_balancedue numeric DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  IF p_balancedue IS NULL THEN
    EXECUTE format('UPDATE %I.feedemand SET feeamount = $1, collectible = $2 WHERE dem_id = $3 AND ins_id = $4', v_schema)
      USING p_feeamount, p_collectible, p_dem_id, v_ins;
  ELSE
    -- p_balancedue is read only as a FLAG: non-null means "the amount changed,
    -- recompute the outstanding", null means "leave the outstanding alone".
    -- The value itself is ignored and the balance derived from the row.
    EXECUTE format(
      'UPDATE %I.feedemand SET feeamount = $1, collectible = $2, '
      'balancedue = GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0), '
      'reconbalancedue = GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0), '
      'paidstatus = CASE WHEN GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0) > 0 THEN ''U'' ELSE ''P'' END '
      'WHERE dem_id = $3 AND ins_id = $4', v_schema)
      USING p_feeamount, p_collectible, p_dem_id, v_ins;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.rebuild_demand(
  p_token text, p_dem_id bigint, p_feeamount numeric, p_balancedue numeric, p_collectible boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- p_balancedue accepted but ignored -- derived from the row instead. The Fee
  -- Master caller already computes the same figure; the server no longer takes
  -- its word for it.
  EXECUTE format(
    'UPDATE %I.feedemand SET feeamount=$1, '
    'balancedue=GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0), '
    'reconbalancedue=GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0), '
    'paidstatus=CASE WHEN GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0) > 0 THEN ''U'' ELSE ''P'' END, '
    'collectible=$2 '
    'WHERE dem_id=$3 AND ins_id=$4', v_schema)
  USING p_feeamount, p_collectible, p_dem_id, v_ins;
END; $$;
GRANT EXECUTE ON FUNCTION public.rebuild_demand(text, bigint, numeric, numeric, boolean)   TO anon, authenticated;

-- CREATE OR REPLACE keeps existing privileges; these are restated only so the
-- script is self-sufficient on a fresh database.
GRANT EXECUTE ON FUNCTION public.apply_concession(text, bigint, integer, numeric, numeric)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_fee_definition(text, bigint, numeric, boolean, numeric)     TO anon, authenticated;


-- ===== 4) process_concession: record the DELTA in concessiondetail =====
--
-- The demand was never wrong here. The Fee Concession screen seeds its field
-- from feedemand.conamount and sends back the TOTAL it wants standing on the
-- demand, so SETTING conamount is correct (accumulating would double every
-- re-save). What was wrong is concessiondetail: each voucher stored the whole
-- total, so two 3,000 vouchers against one demand summed to 6,000 in every
-- report that adds up the detail rows, while the demand correctly said 3,000.
--
-- Now each voucher line records what that voucher actually changed, which
-- makes SUM(concessiondetail.conamount) equal feedemand.conamount again. Plus
-- two guards: a line that changes nothing is skipped (and a voucher where
-- every line is a no-op is refused rather than left empty), and a concession
-- may not exceed the uncollected part of the fee -- the same rule the screen
-- already enforces, now enforced server-side too.
--
-- In normal use this changes nothing: the screen locks any row that already
-- carries a concession, so the delta equals the full amount. It only bites
-- when a second voucher does reach the same demand.

CREATE OR REPLACE FUNCTION public.process_concession(
  p_token text, p_header jsonb, p_lines jsonb
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_hdr_id integer;
  v_condate text; v_con_id integer; v_contype text; v_createdby text; v_stu_id bigint; v_stuadmno text;
  v_inscode text; v_yrid integer; v_yrlabel text;
  itm RECORD; v_fee numeric; v_paid numeric;
  v_con numeric; v_delta numeric; v_maxcon numeric; v_applied integer := 0;
  v_seq_id integer; v_num integer; v_scur numeric; v_sstart numeric;
  v_prefix text; v_width int; v_docno text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  -- doc_no = formatted CONNO sequence value (prefix + padded), same shape as
  -- feedemand.demno. Atomic bump; falls back to the client value.
  EXECUTE format('SELECT seq_id, seqstart, seqcurno, seqprefix, seqwidth FROM %I.sequence WHERE ins_id=$1 AND actname=''CONNO'' AND activestatus=1 ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_sstart, v_scur, v_prefix, v_width USING v_ins;
  IF v_seq_id IS NOT NULL THEN
    v_num := (CASE WHEN COALESCE(v_scur,0) < COALESCE(v_sstart,1) THEN COALESCE(v_sstart,1) ELSE v_scur + 1 END)::integer;
    v_docno := COALESCE(v_prefix,'') || LPAD(v_num::text, COALESCE(v_width,5)::int, '0');
    EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_num, v_seq_id;
  ELSE
    v_docno := NULLIF(p_header->>'doc_no','');
  END IF;

  -- inscode + active year are derived server-side (client can't get them wrong).
  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;
  BEGIN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema) INTO v_yrid, v_yrlabel;
  EXCEPTION WHEN OTHERS THEN v_yrid := NULL; v_yrlabel := NULL;
  END;

  v_condate   := p_header->>'condate';
  v_con_id    := NULLIF(p_header->>'con_id','')::integer;
  v_contype   := p_header->>'contype';
  v_createdby := p_header->>'createdby';
  v_stu_id    := NULLIF(p_header->>'stu_id','')::bigint;
  v_stuadmno  := p_header->>'stuadmno';

  EXECUTE format(
    'INSERT INTO %I.concession(doc_no,ins_id,inscode,yr_id,yrlabel,condate,stu_id,stuadmno,stuname,stuclass,courname,con_id,contype,totalfee,totalconcession,totalbalance,remarks,createdby,activestatus) '
    'VALUES($1,$2,$3,$4,$5,COALESCE(NULLIF($6,'''')::date,CURRENT_DATE),$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,1) RETURNING con_hdr_id', v_schema)
  INTO v_hdr_id USING
    v_docno, v_ins, v_inscode, v_yrid, v_yrlabel,
    v_condate, v_stu_id, v_stuadmno, p_header->>'stuname', p_header->>'stuclass', p_header->>'courname',
    v_con_id, v_contype, COALESCE((p_header->>'totalfee')::numeric,0), COALESCE((p_header->>'totalconcession')::numeric,0),
    COALESCE((p_header->>'totalbalance')::numeric,0), p_header->>'remarks', v_createdby;

  FOR itm IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(
    dem_id bigint, demfeeterm text, demfeetype text, feeamount numeric,
    conamount numeric, balancedue numeric)
  LOOP
    -- The client sends the TOTAL concession it wants standing on the demand --
    -- the screen seeds the field from feedemand.conamount -- so SETTING the
    -- demand is correct and must stay. concessiondetail is a different thing:
    -- it is history, and has to record what THIS voucher changed. Writing the
    -- total into every voucher is what made two 3,000 vouchers against one
    -- demand sum to 6,000 in the reports while the demand correctly held 3,000.
    v_fee := NULL; v_con := NULL; v_paid := NULL;
    IF itm.dem_id IS NOT NULL THEN
      EXECUTE format('SELECT feeamount, conamount, paidamount FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2 FOR UPDATE', v_schema)
        INTO v_fee, v_con, v_paid USING itm.dem_id, v_ins;
    END IF;
    v_delta := COALESCE(itm.conamount,0) - COALESCE(v_con,0);

    -- Re-saving the same figure changes nothing: it must not mint a second
    -- voucher line for the full amount.
    CONTINUE WHEN v_fee IS NOT NULL AND ABS(v_delta) < 0.005;

    -- A concession can only discount money that has not been collected yet.
    v_maxcon := GREATEST(COALESCE(v_fee,0) - COALESCE(v_paid,0), 0);
    IF v_fee IS NOT NULL AND COALESCE(itm.conamount,0) > v_maxcon + 0.005 THEN
      RAISE EXCEPTION 'Concession of % on demand % exceeds the uncollected amount (fee % less paid %).',
        itm.conamount, itm.dem_id, COALESCE(v_fee,0), COALESCE(v_paid,0) USING ERRCODE = 'P0001';
    END IF;

    EXECUTE format(
      'INSERT INTO %I.concessiondetail(con_hdr_id,ins_id,stu_id,stuadmno,receiptno,dem_id,demfeeterm,demfeetype,feeamount,conamount,balancedue,con_id,contype,condate,createdby,activestatus) '
      'VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,COALESCE(NULLIF($14,'''')::date,CURRENT_DATE),$15,1)', v_schema)
      USING v_hdr_id, v_ins, v_stu_id, v_stuadmno, v_docno, itm.dem_id, itm.demfeeterm, itm.demfeetype,
            itm.feeamount,
            CASE WHEN v_fee IS NULL THEN COALESCE(itm.conamount,0) ELSE v_delta END,
            COALESCE(itm.balancedue,0), v_con_id, v_contype, v_condate, v_createdby;
    v_applied := v_applied + 1;

    IF v_fee IS NOT NULL THEN
      EXECUTE format('UPDATE %I.feedemand SET con_id=$1, conamount=$2, balancedue=$3, reconbalancedue=$3, paidstatus=CASE WHEN $3>0 THEN ''U'' ELSE ''P'' END WHERE dem_id=$4 AND ins_id=$5', v_schema)
        USING v_con_id, COALESCE(itm.conamount,0),
              GREATEST(COALESCE(v_fee,0) - COALESCE(v_paid,0) - COALESCE(itm.conamount,0), 0),
              itm.dem_id, v_ins;
    END IF;
  END LOOP;

  -- Every line was a no-op. Don't leave an empty voucher behind; raising also
  -- rolls back the CONNO sequence bump made above.
  IF v_applied = 0 THEN
    RAISE EXCEPTION 'This concession changes nothing - the same amounts are already applied.' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_hdr_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.process_concession(text, jsonb, jsonb) TO anon, authenticated;
