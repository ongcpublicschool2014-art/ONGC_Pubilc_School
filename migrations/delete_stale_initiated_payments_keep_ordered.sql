-- ============================================================================
-- delete_stale_initiated_payments -- never delete a payment that reached Paytm.
--
-- WHY: the parent app calls this when it restores a cart left mid-payment,
-- which is exactly what a phone shows after the app closes during checkout.
-- It deleted EVERY in-progress ('I') payment for the student -- including one
-- where Paytm had already taken the money but the app died before recording
-- it. That erased the only record: no receipt, fee still due, and the
-- desktop's Paytm-aware recovery could no longer find it.
--
-- NOW: only 'I' payments with no order id are deleted (no gateway order, so
-- nothing can have been charged). Payments with an order id stay 'I' and are
-- resolved against Paytm by the sweeps.
--
-- Server-side, so it protects every installed app version immediately.
-- Same signature: CREATE OR REPLACE keeps the existing grant. SAFE TO RE-RUN.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.delete_stale_initiated_payments(p_ins_id integer, p_stu_id bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout = '15s'
AS $$
DECLARE v text; n integer;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN 0; END IF;
  -- Only payments that never got a gateway order id: nothing can have been
  -- charged. One WITH an order id may have been paid, so it stays 'I' for the
  -- Paytm-aware sweeps to complete or fail -- deleting it lost the record.
  EXECUTE format('DELETE FROM %I.paymentdetails WHERE pay_id IN '
                 '(SELECT pay_id FROM %I.payment WHERE stu_id=$1 AND paystatus=''I'' '
                 'AND NULLIF(btrim(payorderid), '''') IS NULL)', v, v)
    USING p_stu_id;
  EXECUTE format('WITH d AS (DELETE FROM %I.payment WHERE stu_id=$1 AND paystatus=''I'' '
                 'AND NULLIF(btrim(payorderid), '''') IS NULL RETURNING 1) '
                 'SELECT count(*) FROM d', v)
    INTO n USING p_stu_id;
  RETURN n;
END; $$;

GRANT EXECUTE ON FUNCTION public.delete_stale_initiated_payments(integer, bigint) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify: expects keeps_ordered_payments = true
SELECT position('payorderid' in p.prosrc) > 0 AS keeps_ordered_payments
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'delete_stale_initiated_payments';
