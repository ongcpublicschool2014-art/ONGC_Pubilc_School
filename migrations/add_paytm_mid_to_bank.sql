-- ============================================================================
-- Add Paytm merchant id (MID) to the bank master — per institution schema.
-- ============================================================================
-- A Paytm MID settles to exactly one bank account (configured during IOBPAY
-- onboarding). Storing the MID on the bank row lets each fee group route its
-- ONLINE payment to the correct merchant via the existing chain:
--   feegroup.ban_id -> bank.paytm_mid
-- so the money Paytm settles follows the same account the school already maps
-- the fee group to. NULL = use the app's default MID (PaytmConfig.mid).
--
-- Non-secret (the MID is embedded in the JS Checkout SDK URL). The merchant
-- KEY for each MID stays server-side in the edge functions. Idempotent.
-- ============================================================================

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
                   WHERE table_schema = sname AND table_name = 'bank') THEN
      EXECUTE format(
        'ALTER TABLE %I.bank ADD COLUMN IF NOT EXISTS paytm_mid varchar(40)', sname);
      RAISE NOTICE 'Added bank.paytm_mid in %', sname;
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload config';
