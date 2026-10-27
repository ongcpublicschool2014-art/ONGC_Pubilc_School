-- ============================================================================
-- Mobile payments must carry their Paytm order id.
-- ============================================================================
-- WHAT IS BROKEN. create-paytm-order tries to write the order id onto the
-- payment row with:
--
--     supabase.from("payment").update({ payorderid: orderId }).eq("pay_id", …)
--
-- `from("payment")` with no schema means public.payment -- which DOES NOT
-- EXIST. The table lives in <institution schema>. So the update matches
-- nothing, and the failure is swallowed:
--
--     } catch (_) { /* Non-fatal: the client also updates payorderid. */ }
--
-- The DESKTOP client saves itself by stamping it a line later. The MOBILE app
-- does not, so a mobile payment's order id is never written anywhere. Three
-- things follow, and all three happened to KANNAN D on 11-10-2026:
--
--   1. webhook_find_payment matches ONLY on payorderid, so the webhook can
--      never turn a mobile payment into a receipt. No receipt number.
--   2. _sweepOrphanedPayments needs payorderid to ask Paytm, so it can never
--      recover one either. Status never changes.
--   3. create_pending_payment DELETES 'I' rows whose payorderid is blank, as
--      a proxy for "never reached the gateway". With the stamp never written,
--      that proxy is always true -- so the next attempt deletes the row for
--      an attempt that has ALREADY BEEN PAID, along with its detail lines.
--
-- Of 1,149 completed gateway payments, 755 have no payorderid.
--
-- WHAT THIS DOES.
--   PART 1  stamp_payorderid() -- writes the order id into the right
--           institution schema, which the edge function could not do.
--   PART 2  create_pending_payment stops deleting rows younger than 15
--           minutes, so even a missed stamp cannot destroy a live attempt.
--
-- PART 3 is NOT here: create-paytm-order must call stamp_payorderid instead
-- of from("payment"), and must stop swallowing the failure. Deploy that with
-- this -- PART 1 alone changes nothing until something calls it.
--
-- Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 1 =
-- Stamp the order id onto the payment row, in whichever schema it lives.
--
-- Loops the active institutions exactly as webhook_find_payment does: the
-- edge function knows a pay_id but not which tenant it belongs to.
--
-- Only fills a BLANK payorderid. It will not overwrite one already set, so
-- the desktop's own stamp is never clobbered and a replay cannot repoint a
-- row at a different order.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.stamp_payorderid(
  p_pay_id bigint, p_order_id text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $fn$
DECLARE v_ins integer; v_schema text; v_n integer; v_existing text;
BEGIN
  IF p_pay_id IS NULL OR p_pay_id <= 0 THEN RETURN false; END IF;
  IF COALESCE(btrim(p_order_id), '') = '' THEN RETURN false; END IF;

  FOR v_ins IN SELECT i.ins_id FROM public.institution i WHERE i.activestatus = 1 LOOP
    v_schema := get_institution_schema(v_ins);
    CONTINUE WHEN v_schema IS NULL;

    EXECUTE format(
      'UPDATE %I.payment SET payorderid = $1
        WHERE pay_id = $2 AND activestatus = 1
          AND COALESCE(btrim(payorderid), '''') = ''''', v_schema)
      USING btrim(p_order_id), p_pay_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN RETURN true; END IF;

    -- Already stamped with this same order id: idempotent, report success so
    -- a retried call does not read as a failure.
    EXECUTE format(
      'SELECT btrim(payorderid) FROM %I.payment WHERE pay_id = $1', v_schema)
      INTO v_existing USING p_pay_id;
    IF v_existing = btrim(p_order_id) THEN RETURN true; END IF;
  END LOOP;

  RETURN false;
END;
$fn$;

-- The edge function calls this with the service role key.
GRANT EXECUTE ON FUNCTION public.stamp_payorderid(bigint, text) TO service_role;


-- =================================================================== PART 2 =
-- create_pending_payment must not delete a live attempt.
--
-- Its delete uses "payorderid is blank" to mean "never reached the gateway,
-- so nothing can have been charged". Sound reasoning, false premise: the
-- stamp was never written. Until every caller stamps reliably, age is the
-- safer test -- a row created in the last 15 minutes may have a checkout
-- open right now, whatever its payorderid says.
--
-- 15 minutes matches _sweepOrphanedPayments' own cutoff, so a row this
-- refuses to delete is one the sweep has already taken responsibility for.
-- ===========================================================================

DO $patch$
DECLARE
  src text;
  old_det CONSTANT text := '     AND COALESCE(length(btrim(payorderid)), 0) = 0)';
  new_det CONSTANT text := '     AND COALESCE(length(btrim(payorderid)), 0) = 0'
                           ' AND createdat < now() - interval ''''15 minutes'''')';
  old_pay CONSTANT text := '   AND COALESCE(length(btrim(payorderid)), 0) = 0';
  new_pay CONSTANT text := '   AND COALESCE(length(btrim(payorderid)), 0) = 0'
                           ' AND createdat < now() - interval ''''15 minutes''''';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_pending_payment';
  IF src IS NULL THEN
    RAISE NOTICE 'create_pending_payment does not exist'; RETURN;
  END IF;
  IF src LIKE '%15 minutes%' THEN
    RAISE NOTICE 'create_pending_payment already guarded'; RETURN;
  END IF;
  IF position(old_det in src) = 0 OR position(old_pay in src) = 0 THEN
    RAISE EXCEPTION 'create_pending_payment does not carry the expected delete '
      '-- NOT patched. Its definition has changed since this was written.';
  END IF;
  -- ORDER AND GUARD BOTH MATTER, and getting this wrong is not theoretical:
  -- the first version of this patch ran old_det then old_pay and produced
  --
  --     ... = 0 AND createdat < now() - interval '15 minutes'
  --             AND createdat < now() - interval '15 minutes'
  --
  -- on live. old_pay (3-space indent) is a SUBSTRING of old_det (5-space),
  -- so replacing the detail line first leaves text the payment pattern still
  -- matches, and it appends the clause a second time. Harmless -- X AND X is
  -- X -- but wrong, and it propagated into complete_setup.sql.
  --
  -- Fixed by anchoring the payment form on its line ending rather than
  -- letting it float: the detail form ends in ')', the payment form does not.
  src := replace(src, old_det, new_det);
  src := replace(src, old_pay || '''', new_pay || '''');
  EXECUTE src;
  RAISE NOTICE 'patched public.create_pending_payment';
END
$patch$;


-- ------------------------------------------------------------- VERIFY ------
-- 1. Both changes are in. Expect true, true.
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'stamp_payorderid') = 1
                                                      AS stamp_fn_exists,
  (SELECT pg_get_functiondef(p.oid) LIKE '%15 minutes%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'create_pending_payment')
                                                      AS delete_is_age_guarded;

-- 2. How many gateway payments still have no order id. This does not shrink
--    retroactively -- it should stop GROWING once create-paytm-order is
--    redeployed. Worth noting the number now to compare against tomorrow.
SELECT paystatus,
       count(*) FILTER (WHERE COALESCE(btrim(payorderid), '') = '') AS missing,
       count(*) AS total
  FROM kcet20262027.payment
 WHERE activestatus = 1
   AND LOWER(btrim(COALESCE(paymethod, ''))) IN
       ('online transfer', 'online', 'upi', 'imps', 'neft', 'rtgs',
        'neft/rtgs', 'paytm', 'card')
 GROUP BY 1 ORDER BY 1;
