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
