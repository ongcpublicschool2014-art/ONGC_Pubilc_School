-- =====================================================================
-- Stop create_pending_payment deleting a payment that is LIVE at Paytm.
--
-- THE DEFECT. Every time a parent taps Pay, the RPC runs:
--
--     DELETE FROM <schema>.paymentdetails
--      WHERE pay_id IN (SELECT pay_id FROM <schema>.payment
--                        WHERE stu_id = $1 AND paystatus = 'I');
--     DELETE FROM <schema>.payment
--      WHERE stu_id = $1 AND paystatus = 'I';
--
-- Unconditional. No age limit, no check on whether the gateway was ever
-- contacted. The Dart caller calls these rows "stale (initiated-but-abandoned)"
-- but nothing in the SQL defines stale -- it deletes EVERY 'I' row the student
-- has, including one created seconds ago that Paytm still has open.
--
-- HOW IT TAKES REAL MONEY.
--   1. Parent taps Pay. pay_id 2803 is written, order PAY-2803t... is signed,
--      the Paytm page opens.
--   2. Parent backs out, or the checkout popup closes on its own.
--   3. Parent taps Pay again -- for ANY fee. This RPC deletes row 2803.
--   4. The first Paytm page is still alive. The parent completes it, or the
--      bank confirms late. Paytm captures against order PAY-2803t...
--   5. The completion names pay_id 2803. The row is gone. Money taken,
--      recorded nowhere, and invisible to every recovery path:
--        * the desktop orphan sweep replays from `payitems` ON THAT ROW
--        * fee_health_check looks for unresolved 'I' ROWS
--      Delete the row and both go blind. It is findable only by reconciling
--      the Paytm settlement report by hand.
--
-- THIS IS NOT WHAT TOOK THE Rs 8,000 ON 01-10-2026. That one was pay_id reuse:
-- the row for 2803 still existed, carrying ANOTHER student's receipt, so the
-- completion was refused -- loudly, and correctly. This hole is quieter: the
-- row is simply absent, nothing refuses anything, and no trace is left in the
-- database at all. Same family of defect, worse failure mode, still open.
--
-- WHY check_fees_locked DOES NOT COVER THIS. It blocks a retry only when the
-- SAME dem_ids are already 'I' and only for 15 minutes. It does not fire when
-- the parent pays DIFFERENT fees (the in-flight row is for other demands and
-- gets deleted anyway), nor after 15 minutes, and the Dart caller skips it
-- entirely if the RPC call throws.
--
-- NOT THE SAME BUG AS pay_id REUSE. FIX_PAY_ID_REUSE stopped a deleted row's
-- id being handed to ANOTHER student -- the worst outcome, money credited to
-- the wrong family. This is the outcome underneath it: the row disappearing
-- while money is in flight. The sequence fix does not address it.
--
-- THE FIX. Delete only rows that never reached the gateway. `payorderid` is
-- written (by the create-paytm-order edge function server-side, and by
-- set_payment_order from the app) the moment an order exists, so an 'I' row
-- with no payorderid provably never reached Paytm and no money can exist
-- against it. Anything that DID reach Paytm is left alone -- which is
-- precisely what the sweep and the health check need to find it.
--
-- SIDE EFFECT, INTENDED: abandoned-at-the-gateway rows now survive instead of
-- being silently erased, so fee_health_check() will start reporting them.
-- That is the point. Each one is a payment nobody has confirmed either way;
-- resolve it from the Paytm dashboard (a Pending row with a BLANK Payment
-- Option is an abandoned checkout and safe to close with
-- set_payment_status(..., p_touch_date => false)).
--
-- Idempotent. Changes no existing row. Run any time.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.create_pending_payment(
  p_ins_id integer, p_stu_id bigint, p_total numeric,
  p_yr_id integer, p_yrlabel text, p_created_by text,
  p_payitems text, p_details jsonb, p_ban_id integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout = '30s'
AS $$
DECLARE
  v text; v_inscode text; v_pay_id bigint; v_fallback_yr int; v_yr int; it jsonb;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

  PERFORM public.assert_fee_payment_allowed(p_ins_id, p_stu_id, p_details);

  EXECUTE format('SELECT inscode FROM %I.students WHERE stu_id=$1', v) INTO v_inscode USING p_stu_id;
  EXECUTE format('SELECT yr_id FROM %I.year WHERE activestatus=1 ORDER BY yr_id DESC LIMIT 1', v) INTO v_fallback_yr;
  v_yr := COALESCE(NULLIF(p_yr_id, 0), v_fallback_yr);

  -- Clear the student's abandoned attempts -- but ONLY those that never
  -- reached the gateway. A row carrying a payorderid has an order open at
  -- Paytm and may still capture; deleting it loses the money outright,
  -- because the completion then names a pay_id that does not exist and
  -- neither the orphan sweep nor fee_health_check has anything left to find.
  -- length(btrim(...)) rather than = '' so the test carries no nested quotes
  -- through two levels of format(); NULL and whitespace both read as absent.
  EXECUTE format(
    'DELETE FROM %1$I.paymentdetails WHERE pay_id IN ('
    '  SELECT pay_id FROM %1$I.payment'
    '   WHERE stu_id=$1 AND paystatus=''I'''
    '     AND COALESCE(length(btrim(payorderid)), 0) = 0)', v)
  USING p_stu_id;
  EXECUTE format(
    'DELETE FROM %I.payment'
    ' WHERE stu_id=$1 AND paystatus=''I'''
    '   AND COALESCE(length(btrim(payorderid)), 0) = 0', v)
  USING p_stu_id;

  EXECUTE format(
    'INSERT INTO %I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,'
    'paydate,paystatus,recon_status,createdby,payitems,activestatus,ban_id) '
    'VALUES($1,$2,$3,$4,$5,$6,''INR'',now(),''I'',''P'',$7,$8,1,$9) RETURNING pay_id', v)
  INTO v_pay_id USING p_ins_id, v_inscode, p_stu_id, v_yr, p_yrlabel, p_total, p_created_by, p_payitems, p_ban_id;

  FOR it IN SELECT jsonb_array_elements(p_details) LOOP
    EXECUTE format(
      'INSERT INTO %I.paymentdetails(pay_id,dem_id,yr_id,yrlabel,ins_id,transcurrency,transtotalamount,activestatus) '
      'VALUES($1,$2,$3,$4,$5,''INR'',$6,1)', v)
    USING v_pay_id, (it->>'dem_id')::bigint, COALESCE(NULLIF((it->>'yr_id')::int, 0), v_fallback_yr),
          (it->>'yrlabel'), p_ins_id, (it->>'amount')::numeric;
  END LOOP;

  RETURN v_pay_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.create_pending_payment(
  integer, bigint, numeric, integer, text, text, text, jsonb, integer)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ---------------------------------------------------------------------
-- VERIFY -- must read 'protected'.
-- ---------------------------------------------------------------------
SELECT CASE WHEN p.prosrc LIKE '%payorderid%'
            THEN 'protected: in-flight payments are no longer deleted'
            ELSE 'STILL DELETING EVERY I ROW' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'create_pending_payment';
