-- ============================================================================
-- add_void_receipt_reason.sql
-- Adds a cancellation REASON to the receipt-void flow (the new Fee Cancel
-- Receipt screen). Extends add_void_receipt.sql:
--   • voidreason column on every institution's payment table (audit trail).
--   • void_receipt gains a p_reason argument (stored in voidreason).
--
-- The 3-arg void_receipt(integer,bigint,text) is DROPPED and replaced by the
-- 4-arg overload with p_reason DEFAULT NULL, so:
--   • a 3-key call (legacy Fee Collection delete) still resolves — p_reason
--     defaults to NULL — with NO overload ambiguity (only one function exists);
--   • the new 4-key call records the reason.
-- The client (SupabaseService.voidReceipt) sends 4 params and, if this migration
-- hasn't run yet, falls back to the 3-arg signature — so rollout is non-breaking
-- in either order.
-- Idempotent & safe to re-run.
-- ============================================================================

-- 1) voidreason column on every institution's payment table ---------------------
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
        'ALTER TABLE %I.payment ADD COLUMN IF NOT EXISTS voidreason varchar(255)',
        sname);
      RAISE NOTICE 'Added voidreason to payment in %', sname;
    END IF;
  END LOOP;
END $$;

-- 2) Replace the void RPC with the reason-aware version -------------------------
DROP FUNCTION IF EXISTS public.void_receipt(integer, bigint, text);

CREATE OR REPLACE FUNCTION public.void_receipt(
  p_ins_id integer, p_pay_id bigint, p_user text, p_reason text DEFAULT NULL)
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
  EXECUTE format('UPDATE %I.payment SET activestatus=9, paystatus=''R'', voidedby=$1, voideddate=now(), voidreason=$2 WHERE pay_id=$3', v)
    USING p_user, NULLIF(TRIM(COALESCE(p_reason, '')), ''), p_pay_id;

  RETURN jsonb_build_object('voided', p_pay_id, 'paynumber', p.paynumber);
END; $$;

GRANT EXECUTE ON FUNCTION public.void_receipt(integer, bigint, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload config';
