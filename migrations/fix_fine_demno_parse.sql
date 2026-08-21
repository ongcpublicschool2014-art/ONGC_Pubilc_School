-- FIX: "Payment failed" when a selected demand is a FINE whose demno is not in
-- the exact FN<digits> / FNG<digits> shape (e.g. 'FN/2601673').
--
-- Root cause: process_grouped_payment resolved a fine's fee group by stripping
-- the first 2-3 chars of demno and casting the rest to bigint/int. For a demno
-- like 'FN/2601673' the leftover was '/2601673', so the ::bigint cast raised
--   invalid input syntax for type bigint: "/2601673"  (SQLSTATE 22P02)
-- and the whole payment rolled back.
--
-- Fix: extract the first digit-run with a regex and null-safe cast
--   NULLIF(substring(fn.demno from '[0-9]+'), '')::bigint
-- If the demno has no usable digits, this yields NULL -> the orig-demand lookup
-- simply finds nothing and the code falls back to the fee-type lookup (fg 0),
-- so the collection always completes instead of crashing.

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
  v_current_paid NUMERIC; v_current_balance NUMERIC;
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
      EXECUTE format('SELECT paidamount,balancedue FROM %I.feedemand WHERE dem_id=$1 AND activestatus=1 FOR UPDATE',v) INTO v_current_paid,v_current_balance USING itm.dem_id;
      IF COALESCE(v_current_balance,0) <= 0 THEN
        RAISE EXCEPTION 'Demand % is already paid (balance=%). Another payment may have been posted - please refresh.', itm.dem_id, v_current_balance USING ERRCODE = 'P0001';
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

GRANT EXECUTE ON FUNCTION public.process_grouped_payment(integer, varchar, bigint, integer, varchar, numeric, varchar, text, text, jsonb) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
