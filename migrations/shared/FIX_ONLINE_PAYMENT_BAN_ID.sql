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
