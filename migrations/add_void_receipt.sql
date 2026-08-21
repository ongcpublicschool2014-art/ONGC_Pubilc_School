-- ============================================================================
-- Delete / void a fee-collection receipt (Fee Collection reprint view).
-- ============================================================================
-- A receipt is one payment row (with a receipt number) + its paymentdetails,
-- and it reduced each feedemand.balancedue / bumped paidamount / set paidstatus.
-- Voiding must REVERSE all of that so the ledger stays consistent.
--
-- Rules:
--   * Bank-reconciled receipts (recon_status='R' AND method<>'cash') are
--     protected - money is already matched to a bank deposit.
--   * Cash + not-yet-reconciled receipts can be voided.
--   * The payment row is kept (activestatus=9, paystatus='R') for an audit
--     trail; paymentdetails are marked inactive; the demands go back to pending.
-- Idempotent & safe to re-run.
-- ============================================================================

-- 1) Void-audit columns on every institution's payment table --------------------
DO $$
DECLARE
  r record;
  sname text;
BEGIN
  FOR r IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL
  LOOP
    sname := r.schema_name;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sname)
       AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = sname AND table_name = 'payment') THEN
      EXECUTE format(
        'ALTER TABLE %I.payment '
        'ADD COLUMN IF NOT EXISTS voidedby varchar(100), '
        'ADD COLUMN IF NOT EXISTS voideddate timestamp',
        sname);
      RAISE NOTICE 'Added void columns to payment in %', sname;
    END IF;
  END LOOP;
END $$;

-- 2) The void RPC ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_receipt(p_ins_id integer, p_pay_id bigint, p_user text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v text; p RECORD; d RECORD; v_is_cash boolean;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema found for ins_id %', p_ins_id; END IF;

  -- Lock the receipt row so a concurrent void/reconcile serialises.
  EXECUTE format('SELECT pay_id, paymethod, recon_status, activestatus, paynumber FROM %I.payment WHERE pay_id=$1 AND ins_id=$2 FOR UPDATE', v)
    INTO p USING p_pay_id, p_ins_id;
  IF p.pay_id IS NULL THEN
    RAISE EXCEPTION 'Receipt not found' USING ERRCODE = 'P0001';
  END IF;
  IF p.activestatus = 9 THEN
    RAISE EXCEPTION 'Receipt is already deleted' USING ERRCODE = 'P0001';
  END IF;

  v_is_cash := LOWER(COALESCE(p.paymethod, '')) = 'cash';
  -- Protect genuinely bank-matched (non-cash reconciled) receipts.
  IF p.recon_status = 'R' AND NOT v_is_cash THEN
    RAISE EXCEPTION 'Receipt % is reconciled with the bank and cannot be deleted', p.paynumber USING ERRCODE = 'P0001';
  END IF;

  -- Restore every demand this receipt settled. Cash also reduced
  -- reconbalancedue at collection, so add that back too; non-cash pending
  -- receipts never touched reconbalancedue.
  FOR d IN EXECUTE format('SELECT dem_id, transtotalamount FROM %I.paymentdetails WHERE pay_id=$1 AND activestatus=1', v) USING p_pay_id LOOP
    IF v_is_cash THEN
      EXECUTE format('UPDATE %I.feedemand SET paidamount=GREATEST(COALESCE(paidamount,0)-$1,0), balancedue=COALESCE(balancedue,0)+$1, reconbalancedue=COALESCE(reconbalancedue,0)+$1, paidstatus=''U'', pay_id=NULL WHERE dem_id=$2 AND ins_id=$3', v)
        USING d.transtotalamount, d.dem_id, p_ins_id;
    ELSE
      EXECUTE format('UPDATE %I.feedemand SET paidamount=GREATEST(COALESCE(paidamount,0)-$1,0), balancedue=COALESCE(balancedue,0)+$1, paidstatus=''U'', pay_id=NULL WHERE dem_id=$2 AND ins_id=$3', v)
        USING d.transtotalamount, d.dem_id, p_ins_id;
    END IF;
  END LOOP;

  -- Soft-void: keep the payment for audit, deactivate its details.
  EXECUTE format('UPDATE %I.paymentdetails SET activestatus=9 WHERE pay_id=$1', v) USING p_pay_id;
  EXECUTE format('UPDATE %I.payment SET activestatus=9, paystatus=''R'', voidedby=$1, voideddate=now() WHERE pay_id=$2', v)
    USING p_user, p_pay_id;

  RETURN jsonb_build_object('voided', p_pay_id, 'paynumber', p.paynumber);
END; $$;

GRANT EXECUTE ON FUNCTION public.void_receipt(integer, bigint, text) TO anon, authenticated;

NOTIFY pgrst, 'reload config';
