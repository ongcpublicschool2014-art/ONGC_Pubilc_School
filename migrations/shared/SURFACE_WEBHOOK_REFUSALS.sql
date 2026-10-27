-- =====================================================================
-- Make a REFUSED capture visible.
--
-- THE GAP. When Paytm confirms a payment late -- debited from the family,
-- pending for hours, settled afterwards -- the webhook raises the receipt.
-- But in three cases it correctly REFUSES:
--
--   * 'demand(s) no longer owe this - settled another way'
--        the family gave up waiting and paid at the counter, so crediting
--        the demand again would create money that has to be refunded
--   * 'attempt has no detail lines - cannot tell which fees it paid'
--   * amount mismatch -- Paytm took a different figure than we asked for
--        (caught in the edge function, before it ever calls this)
--
-- Each refusal is RIGHT. The problem is what happens next: the function
-- returns {ok:false, reason}, the edge function logs it and answers 200 --
-- deliberately, because a retry would not help and Paytm would keep trying
-- forever. So the outcome is: PAYTM HAS THE MONEY, THE COLLEGE HAS NO
-- RECEIPT, and the only trace is a line in an edge function log nobody
-- reads. If the attempt had already been marked 'F', even
-- fee_health_check() will not see it -- that check looks for 'I' rows.
--
-- This is the same invisibility that cost Rs 8,000 on 01-10-2026, arriving
-- through a different door.
--
-- WHAT THIS DOES. Records every refusal in a table, and adds one invariant
-- to fee_health_check() so an unresolved refusal shows up as a WARNING like
-- anything else. It changes no decision: every refusal that happened before
-- still happens, for the same reason. It only stops them being silent.
--
-- Nothing is auto-corrected. A refused capture needs a person to decide
-- whether to refund the family or receipt the money, and that is not a
-- decision a migration should make.
--
-- Idempotent. Touches no payment, demand or receipt.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Where refusals live.
--
-- Keyed by ORDER id, not pay_id: a refusal outlives the attempt it came
-- from (complete_payment_grouped replaces payment rows), and the order id
-- is the one identifier Paytm and the database agree on.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.webhook_refusal (
  order_id        text PRIMARY KEY,
  ins_id          integer,
  pay_id          bigint,
  reason          text        NOT NULL,
  amount          numeric(12,2),
  times_seen      integer     NOT NULL DEFAULT 1,
  first_seen      timestamptz NOT NULL DEFAULT now(),
  last_seen       timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz,
  resolved_by     text,
  resolution_note text
);

COMMENT ON TABLE public.webhook_refusal IS
  'Captures Paytm confirmed but the database refused to receipt. Each row is '
  'money the college has received with no receipt against it, awaiting a '
  'human decision: refund the family, or receipt it another way.';

CREATE INDEX IF NOT EXISTS webhook_refusal_unresolved
  ON public.webhook_refusal (last_seen) WHERE resolved_at IS NULL;

-- Service role only. A client must never be able to write here -- a forged
-- row would be read as "money received" by whoever works the list.
REVOKE ALL ON public.webhook_refusal FROM PUBLIC, anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. Record one. Callable by the edge function for the amount-mismatch
--    case, which never reaches webhook_complete_payment.
--
-- A webhook retry must not pile up rows: the same order updates in place
-- and counts. An ALREADY RESOLVED row is reopened only if the reason has
-- changed -- otherwise a retry would undo somebody's work.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.webhook_record_refusal(
  p_order_id text, p_reason text,
  p_ins_id integer DEFAULT NULL, p_pay_id bigint DEFAULT NULL,
  p_amount numeric DEFAULT NULL
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  INSERT INTO public.webhook_refusal
         (order_id, ins_id, pay_id, reason, amount)
  VALUES (p_order_id, p_ins_id, p_pay_id, p_reason, p_amount)
  ON CONFLICT (order_id) DO UPDATE
     SET times_seen  = public.webhook_refusal.times_seen + 1,
         last_seen   = now(),
         reason      = EXCLUDED.reason,
         ins_id      = COALESCE(EXCLUDED.ins_id, public.webhook_refusal.ins_id),
         pay_id      = COALESCE(EXCLUDED.pay_id, public.webhook_refusal.pay_id),
         amount      = COALESCE(EXCLUDED.amount, public.webhook_refusal.amount),
         resolved_at = CASE WHEN public.webhook_refusal.reason IS DISTINCT FROM EXCLUDED.reason
                            THEN NULL ELSE public.webhook_refusal.resolved_at END;
$$;

REVOKE ALL ON FUNCTION public.webhook_record_refusal(text, text, integer, bigint, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.webhook_record_refusal(text, text, integer, bigint, numeric)
  TO service_role;


-- ---------------------------------------------------------------------
-- 3. Close one, once a person has dealt with it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_webhook_refusal(
  p_order_id text, p_by text, p_note text
) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  UPDATE public.webhook_refusal
     SET resolved_at = now(), resolved_by = p_by, resolution_note = p_note
   WHERE order_id = p_order_id AND resolved_at IS NULL
  RETURNING true;
$$;

REVOKE ALL ON FUNCTION public.resolve_webhook_refusal(text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_webhook_refusal(text, text, text)
  TO service_role;


-- ---------------------------------------------------------------------
-- 4. webhook_complete_payment now records what it refuses.
--
-- Identical decisions to the deployed version -- the refusals, their
-- wording and their return shapes are unchanged. The only additions are
-- the webhook_record_refusal calls, and clearing the record on the path
-- that succeeds so a later success closes an earlier refusal.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.webhook_complete_payment(
  p_order_id text, p_reference text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_pay_id bigint;
  v_items jsonb; v_bad integer; v_res jsonb; v_amt numeric;
BEGIN
  SELECT f.pay_id, f.ins_id, f.transtotalamount
    INTO v_pay_id, v_ins, v_amt
    FROM public.webhook_find_payment(p_order_id) f;

  IF v_pay_id IS NULL THEN
    -- No row at all. Before 03-10-2026 this was the common way money went
    -- missing: create_pending_payment deleted the attempt when the family
    -- tapped Pay again, so a late capture had nothing to land on.
    PERFORM public.webhook_record_refusal(
      p_order_id, 'no payment row - the attempt is gone', NULL, NULL, NULL);
    RETURN jsonb_build_object('ok', false, 'reason', 'no payment row');
  END IF;

  v_schema := get_institution_schema(v_ins);

  -- Already receipted? Nothing to do. This is the retry path and must be
  -- silent, not an error.
  IF EXISTS (SELECT 1 FROM public.webhook_find_payment(p_order_id) f
              WHERE f.paystatus = 'C') THEN
    RETURN jsonb_build_object('ok', true, 'reason', 'already receipted');
  END IF;

  EXECUTE format(
    'SELECT jsonb_agg(jsonb_build_object(
              ''dem_id'', d.dem_id, ''amount'', d.transtotalamount,
              ''demfeetype'', f.demfeetype))
       FROM %I.paymentdetails d
       JOIN %I.feedemand f ON f.dem_id = d.dem_id
      WHERE d.pay_id = $1 AND d.activestatus = 1', v_schema, v_schema)
    INTO v_items USING v_pay_id;

  IF v_items IS NULL THEN
    PERFORM public.webhook_record_refusal(
      p_order_id, 'attempt has no detail lines - cannot tell which fees it paid',
      v_ins, v_pay_id, v_amt);
    RETURN jsonb_build_object('ok', false,
      'reason', 'attempt has no detail lines - cannot tell which fees it paid');
  END IF;

  EXECUTE format(
    'SELECT COUNT(*) FROM jsonb_array_elements($1) x
       JOIN %I.feedemand f ON f.dem_id = (x->>''dem_id'')::bigint
      WHERE f.activestatus <> 1
         OR COALESCE(f.balancedue,0) < (x->>''amount'')::numeric', v_schema)
    INTO v_bad USING v_items;

  IF v_bad > 0 THEN
    PERFORM public.webhook_record_refusal(
      p_order_id,
      format('%s demand(s) no longer owe this - settled another way', v_bad),
      v_ins, v_pay_id, v_amt);
    RETURN jsonb_build_object('ok', false,
      'reason', format('%s demand(s) no longer owe this - settled another way', v_bad));
  END IF;

  v_res := public.complete_payment_grouped(
    p_pay_id => v_pay_id, p_pay_method => 'Online Transfer',
    p_pay_reference => p_reference, p_items => v_items,
    p_ins_id => v_ins, p_status => 'C');

  -- A refusal that later succeeded is closed by the success itself.
  UPDATE public.webhook_refusal
     SET resolved_at = now(), resolved_by = 'WEBHOOK',
         resolution_note = 'receipted on a later callback'
   WHERE order_id = p_order_id AND resolved_at IS NULL;

  RETURN jsonb_build_object('ok', true, 'receipts', v_res);
END; $$;

REVOKE ALL ON FUNCTION public.webhook_complete_payment(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.webhook_complete_payment(text, text) TO service_role;


-- ---------------------------------------------------------------------
-- 5. fee_health_check() gains check 8.
--
-- Appended by rewriting the tail of the deployed function rather than
-- restating all seven existing checks, which would risk transcribing one
-- of them wrongly. The whole body is read, the new block inserted before
-- the loop ends, and the result installed.
-- ---------------------------------------------------------------------
DO $patch$
DECLARE src text; marker text; addition text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc
   WHERE proname = 'fee_health_check' AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'fee_health_check not found -- run FEE_HEALTH_CHECK.sql first';
  END IF;

  IF src LIKE '%captures Paytm confirmed but we refused%' THEN
    RAISE NOTICE 'check 8 already present';
    RETURN;
  END IF;

  -- The loop's last statement is the END of the receipt-register block.
  marker := '  END LOOP;';
  IF position(marker in src) = 0 THEN
    RAISE EXCEPTION 'could not find the loop end in fee_health_check -- not patched';
  END IF;

  addition :=
    E'\n    -- 8. Captures Paytm confirmed that the database refused to receipt.\n'
    '    --    Each is money the college HAS, with no receipt against it. The\n'
    '    --    refusal was right; being invisible was not.\n'
    '    SELECT count(*) INTO n FROM public.webhook_refusal r\n'
    '     WHERE r.resolved_at IS NULL AND COALESCE(r.ins_id, i.id) = i.id;\n'
    '    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN ''WARNING'' ELSE ''ok'' END,\n'
    '      ''captures Paytm confirmed but we refused'', n,\n'
    '      CASE WHEN n > 0 THEN ''money received with no receipt -- see public.webhook_refusal''\n'
    '           ELSE ''no refused captures outstanding'' END;\n\n';

  src := overlay(src placing addition from position(marker in src) for 0);
  EXECUTE src;
  RAISE NOTICE 'fee_health_check: check 8 added';
END $patch$;

NOTIFY pgrst, 'reload schema';


-- ---------------------------------------------------------------------
-- VERIFY -- both rows must read ok.
-- ---------------------------------------------------------------------
SELECT 'refusals are recorded' AS check,
       CASE WHEN p.prosrc LIKE '%webhook_record_refusal%' THEN 'ok' ELSE 'FAILED' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'webhook_complete_payment'

UNION ALL
SELECT 'the health check reports them',
       CASE WHEN p.prosrc LIKE '%captures Paytm confirmed but we refused%'
            THEN 'ok' ELSE 'FAILED' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'fee_health_check';
