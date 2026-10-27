-- =====================================================================
-- LIVE -- the run list for 03-10-2026.
--
-- RUN EACH STEP SEPARATELY. The Supabase SQL editor shows only the LAST
-- result set of a Run, so running steps together hides the answers that
-- decide whether to continue.
--
-- Backup taken first: E:\COLLEGE MANAGEMENT\DB\FULL_LIVE_20261003_1122.dump
--
-- STEP 0  confirm you are on LIVE
-- STEP 1  confirm the counter is quiet
-- STEP 2  the money fix -- create_pending_payment
-- STEP 3  LIVE_REMAINING_2026_10_01.sql  <-- A SEPARATE FILE, not in here
-- STEP 4  verify
-- =====================================================================


-- #####################################################################
-- STEP 0 -- are you on LIVE?
--
-- On LIVE this ERRORS with "function public.db_env() does not exist".
-- That error IS the confirmation. If it returns 'TEST' you are in the
-- wrong project -- stop.
-- #####################################################################
SELECT public.db_env();


-- #####################################################################
-- STEP 1 -- is the counter quiet?
--
-- Step 2 does CREATE OR REPLACE on a function in the payment path, which
-- takes a brief lock. Any '<-- WAIT' means try again in a few minutes.
-- #####################################################################
SELECT 'last collection'                          AS check,
       COALESCE(to_char(max(createdat), 'HH24:MI:SS')
                || '   (' || age(now(), max(createdat))::text || ' ago)',
                'none today') AS value
  FROM kcet20262027.payment WHERE createdat::date = CURRENT_DATE
UNION ALL
SELECT 'collections in the last 2 minutes',
       count(*)::text || CASE WHEN count(*) > 0 THEN '   <-- WAIT' ELSE '   ok' END
  FROM kcet20262027.payment WHERE createdat > now() - interval '2 minutes'
UNION ALL
SELECT 'payments IN FLIGHT (I, under 15 min old)',
       count(*)::text || CASE WHEN count(*) > 0 THEN '   <-- WAIT' ELSE '   ok' END
  FROM kcet20262027.payment
 WHERE paystatus = 'I' AND activestatus = 1
   AND createdat > now() - interval '15 minutes'
UNION ALL
SELECT 'other sessions running a query',
       count(*)::text || CASE WHEN count(*) > 0 THEN '   <-- check what they are' ELSE '   ok' END
  FROM pg_stat_activity
 WHERE datname = current_database() AND pid <> pg_backend_pid()
   AND state = 'active' AND backend_type = 'client backend'
UNION ALL
SELECT 'misc receipts in the last 2 minutes',
       count(*)::text || CASE WHEN count(*) > 0 THEN '   <-- WAIT' ELSE '   ok' END
  FROM kcet20262027.misc_collection WHERE createdat > now() - interval '2 minutes';


-- #####################################################################
-- STEP 2 -- THE MONEY FIX
--
-- create_pending_payment deleted EVERY 'I' row the student had, with no
-- age limit and no check on whether the gateway had been contacted. A
-- parent who opens Paytm, backs out and taps Pay again had the first row
-- deleted; if that first payment then captured, the money was recorded
-- nowhere and nothing could find it -- the orphan sweep replays from
-- `payitems` ON THAT ROW, and fee_health_check looks for 'I' ROWS.
--
-- Now it deletes only rows that never reached the gateway. A payorderid
-- means an order is open at Paytm and the row must survive.
--
-- Must print: protected: in-flight payments are no longer deleted
-- #####################################################################
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

SELECT CASE WHEN p.prosrc LIKE '%payorderid%'
            THEN 'protected: in-flight payments are no longer deleted'
            ELSE 'STILL DELETING EVERY I ROW' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'create_pending_payment';


-- #####################################################################
-- STEP 3 -- NOT IN THIS FILE
--
-- Open migrations/shared/LIVE_REMAINING_2026_10_01.sql (112 KB), select
-- all, and Run it. ALL FIVE PARTS TOGETHER, never individually: parts 1-2
-- replace complete_payment_grouped and wipe both receipt guards, parts 3-4
-- put them back. A partial run reopens the double-receipt hole.
--
-- Do not copy it out of a chat window -- it gets truncated.
-- #####################################################################


-- #####################################################################
-- STEP 4 -- verify. TWO SEPARATE RUNS, or you only see the second.
-- #####################################################################
SELECT * FROM public.fee_health_check();

SELECT * FROM public.check_receipt_gaps(1);
