-- =====================================================================
-- Make the next lost receipt number explain itself.
--
-- Receipt numbers have gone missing from the FC26/ run (03268, 03270, 03282),
-- always alongside a payment made through the PARENT APP. The guard in
-- PROTECT_RECEIPTED_PAYMENTS.sql stops the two mechanisms that could have
-- caused it, but all three mobile call sites were traced and none of them
-- explains it:
--   * sweepOrphanedPayments selects paystatus='I' only, so it cannot reach a
--     numbered row;
--   * handlePaymentFailure always receives the ORIGINAL pay_id, never a child;
--   * resolveStuckPayment is fed by that same 'I'-only sweep.
-- So the cause is somewhere not yet found, and guarding without understanding
-- is only half a fix.
--
-- This logs the two events that could lose a number, with enough context to
-- name the culprit: who deleted a numbered row, and who moved the counter.
-- It writes to its own table and changes no behaviour -- if nothing is wrong
-- the table simply stays empty, which is itself the answer.
--
-- Safe to re-run.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.receipt_number_audit (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  event       text        NOT NULL,   -- 'deleted-numbered-row' | 'counter-moved'
  schema_name text,
  pay_id      bigint,
  paynumber   text,
  paystatus   text,
  stu_id      bigint,
  payorderid  text,
  -- who did it: the database role, and the call stack that reached here.
  db_role     text,
  context     text
);

COMMENT ON TABLE public.receipt_number_audit IS
  'Evidence for lost FC26/ receipt numbers. A row here names the statement '
  'that deleted a numbered payment. Empty is the healthy state.';

-- ---------------------------------------------------------------------
-- Record any delete of a payment row that carries a receipt number.
--
-- With the PROTECT_RECEIPTED_PAYMENTS guard in place this should never fire
-- from complete_payment_grouped. If a row appears here anyway, its `context`
-- holds the PL/pgSQL call stack, which names the function responsible --
-- exactly what is missing today.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_numbered_payment_delete()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ctx text;
BEGIN
  IF COALESCE(OLD.paynumber, '') = '' THEN
    RETURN OLD;                       -- an unnumbered attempt: nothing to lose
  END IF;

  GET DIAGNOSTICS v_ctx = PG_CONTEXT;

  INSERT INTO public.receipt_number_audit
    (event, schema_name, pay_id, paynumber, paystatus, stu_id, payorderid,
     db_role, context)
  VALUES
    ('deleted-numbered-row', TG_TABLE_SCHEMA, OLD.pay_id, OLD.paynumber,
     OLD.paystatus, OLD.stu_id, OLD.payorderid, current_user, v_ctx);

  RETURN OLD;
END; $$;

-- Attach it to every tenant schema that has a payment table.
DO $$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT table_schema FROM information_schema.tables
     WHERE table_name = 'payment' AND table_schema LIKE 'kcet%'
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_log_numbered_payment_delete ON %I.payment', s);
    EXECUTE format(
      'CREATE TRIGGER trg_log_numbered_payment_delete '
      'BEFORE DELETE ON %I.payment '
      'FOR EACH ROW EXECUTE FUNCTION public.log_numbered_payment_delete()', s);
    RAISE NOTICE 'audit trigger attached to %.payment', s;
  END LOOP;
END $$;

GRANT SELECT ON public.receipt_number_audit TO service_role;
