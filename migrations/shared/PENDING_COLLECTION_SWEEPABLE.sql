-- =====================================================================
-- Let the APP recover a late misc/advance capture, without the webhook.
--
-- WHY. WEBHOOK_CAPTURES_MISC_AND_ADVANCE made a late capture recoverable --
-- but only by the webhook, which is a separate moving part: it has to be
-- deployed, Paytm has to be configured to call it, and there is exactly one
-- callback URL for one Paytm account. A counter that cancels a UPI collect
-- and has it approved on a phone two minutes later must be recovered by the
-- app itself, the same way _sweepOrphanedPayments already recovers a fee
-- payment. Nothing about real money should depend on a webhook being
-- correctly registered.
--
-- WHAT THE SWEEP NEEDS. To ask Paytm about an order it must ask THE MERCHANT
-- THE ORDER WAS SIGNED WITH -- orders are signed per fee group now, so a
-- hostel collection lives under the hostel merchant and asking the default
-- one returns "no such order". The fee-payment sweep reads payment.ban_id for
-- this. An intent had nowhere to put it, so it is added here; both screens
-- have already resolved the bank before they sign the order, so they simply
-- pass what they know.
--
-- The column is nullable: an intent written before this migration, or one
-- whose routing could not be resolved, falls back to the institution's own
-- merchant exactly as the rest of the code does.
--
-- Idempotent. Touches no receipt.
-- =====================================================================

ALTER TABLE public.pending_collection
  ADD COLUMN IF NOT EXISTS ban_id integer;

COMMENT ON COLUMN public.pending_collection.ban_id IS
  'The fee group bank this collection was signed against. The sweep needs it '
  'to ask the right Paytm merchant -- the wrong one answers "no such order" '
  'and the capture looks like a failure.';


-- ---------------------------------------------------------------------
-- record_pending_collection gains p_ban_id.
--
-- DROPPED first, not CREATE OR REPLACE: adding a parameter makes a NEW
-- signature, so replace would leave two overloads and a call naming the
-- common arguments would be ambiguous.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.record_pending_collection(
  text, integer, text, numeric, jsonb, jsonb, text);

CREATE OR REPLACE FUNCTION public.record_pending_collection(
  p_order_id text, p_ins_id integer, p_kind text, p_amount numeric,
  p_header jsonb, p_lines jsonb DEFAULT NULL, p_created_by text DEFAULT NULL,
  p_ban_id integer DEFAULT NULL
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  INSERT INTO public.pending_collection
         (order_id, ins_id, kind, amount, header, lines, created_by, ban_id)
  VALUES (p_order_id, p_ins_id, upper(p_kind)::char(1), p_amount,
          p_header, p_lines, p_created_by, p_ban_id)
  ON CONFLICT (order_id) DO UPDATE
     SET amount = EXCLUDED.amount, header = EXCLUDED.header,
         lines  = EXCLUDED.lines,  ban_id = EXCLUDED.ban_id
   WHERE public.pending_collection.status = 'I';
$$;

GRANT EXECUTE ON FUNCTION public.record_pending_collection(
  text, integer, text, numeric, jsonb, jsonb, text, integer)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- What the sweep reads: intents old enough that the counter's own flow has
-- finished with them, and still unresolved.
--
-- 2 minutes. It was 10, to keep a sweep from racing a cashier still on the
-- Paytm page -- but that race cannot happen: the sweep only CLAIMS an intent
-- after Paytm confirms a capture, and a payment still pending at the gateway
-- reads as undecided and is left untouched. The claim handles the rest. A
-- counter watching a payment it knows was made should not wait ten minutes to
-- see it, and the wait was protecting nothing.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.open_pending_collections(p_ins_id integer)
RETURNS TABLE(order_id text, kind char, amount numeric, ban_id integer,
              created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT c.order_id, c.kind, c.amount, c.ban_id, c.created_at
    FROM public.pending_collection c
   WHERE c.ins_id = p_ins_id
     AND c.status = 'I'
     AND c.created_at < now() - interval '2 minutes'
   ORDER BY c.created_at;
$$;

GRANT EXECUTE ON FUNCTION public.open_pending_collections(integer)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- The claimed payload, for the sweeper to replay.
--
-- Separate from the claim so the app can claim, then fetch; the claim
-- already returns the payload, but a sweep that crashed between the two
-- needs a way back to it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pending_collection_payload(p_order_id text)
RETURNS TABLE(ins_id integer, kind char, amount numeric, header jsonb,
              lines jsonb, status char)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT c.ins_id, c.kind, c.amount, c.header, c.lines, c.status
    FROM public.pending_collection c WHERE c.order_id = p_order_id;
$$;

GRANT EXECUTE ON FUNCTION public.pending_collection_payload(text)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ---------------------------------------------------------------------
-- VERIFY -- every row must read ok.
-- ---------------------------------------------------------------------
SELECT 'intents carry their bank' AS check,
       CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                          WHERE table_schema='public' AND table_name='pending_collection'
                            AND column_name='ban_id') THEN 'ok' ELSE 'FAILED' END AS state
UNION ALL
SELECT 'only one record_pending_collection',
       CASE WHEN count(*) = 1 THEN 'ok' ELSE 'FAILED - ' || count(*) || ' overloads' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'record_pending_collection'
UNION ALL
SELECT 'the app can list open intents',
       CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname='public' AND p.proname='open_pending_collections')
            THEN 'ok' ELSE 'FAILED' END
 ORDER BY 1;


-- =====================================================================
-- ADDENDUM -- a late capture is dated the day the MONEY WAS TAKEN.
--
-- save_misc_collection and save_advance_collection stamp the date on the
-- database server (CURRENT_DATE / now()) and deliberately ignore any date the
-- client sends -- a workstation with a wrong clock was once dating misc
-- receipts a day out while fee receipts were correct.
--
-- That rule is right for a collection happening now, and wrong for one the
-- sweep recovers. A UPI collect approved at 11pm and captured after midnight,
-- or a bank that confirms the next morning, would be receipted on the day it
-- was FOUND rather than the day the family paid -- so that day's collection
-- never ties, and reconciling against a Paytm settlement report means doing by
-- hand what was done for the Rs 8,000 on 01-10-2026.
--
-- The intent's created_at is the honest answer, and it does not come from a
-- workstation: it was stamped by this server when the order was signed, before
-- the gateway was contacted. So the date is corrected FROM THE DATABASE'S OWN
-- CLOCK, never from the client.
--
-- Only ever moves a receipt BACKWARDS, and only one the sweep just raised.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.backdate_recovered_collection(p_order_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE c record; v text; n integer := 0;
BEGIN
  SELECT * INTO c FROM public.pending_collection WHERE order_id = p_order_id;
  IF c.order_id IS NULL OR c.status <> 'C' OR COALESCE(c.receipt_no,'') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no completed intent');
  END IF;

  v := get_institution_schema(c.ins_id);
  IF v IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no schema'); END IF;

  -- NOT short-circuited on "same day". advance_collection.advdate is a
  -- TIMESTAMP, so a collection recovered five minutes later still sits five
  -- minutes after the money was taken -- and twenty-five, and an hour, as the
  -- gap grows. Ordering within a day and matching a Paytm settlement line both
  -- depend on the time, which is exactly how the Rs 8,000 ended up at 17:58
  -- instead of 12:28. The UPDATEs below only ever move a receipt BACKWARDS, so
  -- a genuinely same-moment collection is untouched anyway.

  IF c.kind = 'M' THEN
    EXECUTE format(
      'UPDATE %I.misc_collection SET mcdate = $1
        WHERE mcno = $2 AND ins_id = $3 AND mcdate > $1', v)
      USING c.created_at::date, c.receipt_no, c.ins_id;
  ELSE
    EXECUTE format(
      'UPDATE %I.advance_collection SET advdate = $1
        WHERE advno = $2 AND ins_id = $3 AND advdate > $1', v)
      USING c.created_at, c.receipt_no, c.ins_id;
  END IF;
  GET DIAGNOSTICS n = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'moved', n,
                            'to', c.created_at, 'receipt', c.receipt_no);
END; $$;

GRANT EXECUTE ON FUNCTION public.backdate_recovered_collection(text)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

SELECT 'a recovered receipt is dated when the money was taken' AS check,
       CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                          WHERE n.nspname='public' AND p.proname='backdate_recovered_collection')
            THEN 'ok' ELSE 'FAILED' END AS state;
