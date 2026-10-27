-- ============================================================================
-- get_server_date() -- one authoritative clock for date-stamping
--
-- WHY: a workstation with a wrong system date was dating misc-collection
-- receipts a day out while regular fee receipts stayed correct. The difference
-- was where the date came from:
--
--   regular fee  process_grouped_payment stamps paydate NOW()      -> server
--   misc         save_misc_collection took mcdate from the client  -> the PC
--
-- mcdate is already fixed in the app (it no longer sends one, so the RPC's
-- CURRENT_DATE fallback applies). This closes the remaining hole: transdate,
-- the instrument date Bank Reconciliation matches against the bank statement.
-- Every non-cash mode seeded it from the client clock -- Paytm directly, and
-- Cheque/DD/QR-UPI as the pre-filled default a cashier normally accepts. The
-- app now seeds its collection date from this function instead.
--
-- PURELY ADDITIVE. It creates a new function and alters nothing existing, so
-- it cannot change the behaviour of any current screen or RPC. The app falls
-- back to its local clock if this function is absent, so the two can be
-- deployed in either order.
--
-- SAFE TO RE-RUN.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_server_date() RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER AS $$ SELECT CURRENT_DATE $$;

GRANT EXECUTE ON FUNCTION public.get_server_date() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT public.get_server_date() AS server_date;
