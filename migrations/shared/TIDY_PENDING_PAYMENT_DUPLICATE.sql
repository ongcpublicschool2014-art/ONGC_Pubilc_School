-- ============================================================================
-- Tidy: remove a duplicated clause from create_pending_payment.
-- ============================================================================
-- COSMETIC ONLY. Live currently reads:
--
--     AND COALESCE(length(btrim(payorderid)), 0) = 0
--       AND createdat < now() - interval '15 minutes'
--       AND createdat < now() - interval '15 minutes'
--
-- on the paymentdetails DELETE. X AND X is X, so behaviour is correct and
-- always has been -- nothing was ever at risk from this.
--
-- HOW IT HAPPENED. The patch in PAYORDERID_STAMP_AND_GUARD.sql replaced the
-- detail clause (5-space indent) and then the payment clause (3-space). The
-- shorter pattern is a SUBSTRING of the rewritten longer line, so it matched
-- again and appended the guard a second time. The comment in that file
-- claiming the ordering prevented this was simply wrong; it is now fixed
-- there, and GUARD_STALE_PAYMENT_DELETE.sql counts its matches before
-- replacing anything for the same reason.
--
-- WHY BOTHER. The standing check for both deletion paths is
--
--     guard_count = 2        one per DELETE
--
-- and live answers 3, which will read as a fault to whoever runs it next.
--
-- This is the definition as it runs on TEST after the clean patch, extracted
-- with pg_get_functiondef -- not a hand-edit.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_pending_payment(p_ins_id integer, p_stu_id bigint, p_total numeric, p_yr_id integer, p_yrlabel text, p_created_by text, p_payitems text, p_details jsonb, p_ban_id integer DEFAULT NULL::integer)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET statement_timeout TO '30s'
AS $function$



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



    '     AND COALESCE(length(btrim(payorderid)), 0) = 0 AND createdat < now() - interval ''15 minutes'')', v)



  USING p_stu_id;



  EXECUTE format(



    'DELETE FROM %I.payment'



    ' WHERE stu_id=$1 AND paystatus=''I'''



    '   AND COALESCE(length(btrim(payorderid)), 0) = 0 AND createdat < now() - interval ''15 minutes''', v)



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



END; $function$;

-- ------------------------------------------------------------- VERIFY ------
-- Expect 2 and 2.
SELECT p.proname,
       (length(pg_get_functiondef(p.oid))
        - length(replace(pg_get_functiondef(p.oid), '15 minutes', '')))
         / length('15 minutes')                       AS guard_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('create_pending_payment', 'delete_stale_initiated_payments')
 ORDER BY 1;
