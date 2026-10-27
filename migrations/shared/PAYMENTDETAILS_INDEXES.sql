-- ============================================================================
-- paymentdetails: index the two columns everything joins it by.
-- ============================================================================
-- WHAT IT FIXES. Daily Collection over 01-07-2026 to 12-10-2026 came back
-- "No collections in this range" on a database holding 3,487 receipts for
-- exactly that range. It had not found nothing -- the query was killed:
--
--     daily collection load error: PostgrestException(
--       message: canceling statement due to statement timeout, code: 57014)
--
-- `anon` carries statement_timeout = 3s (authenticated gets 8s), and
-- get_daily_collection_report_json took 3.2s. Just over the line, so a short
-- range worked and a term-long one did not.
--
-- THE CAUSE. paymentdetails had ONE index: its primary key on pyd_id. Nothing
-- on pay_id, which every receipt query joins through, and nothing on dem_id,
-- which the ledger and demand-wise reports join through. Postgres does not
-- index a foreign key column for you -- fk_paymentdetails_payment exists on
-- pay_id and buys no read speed at all. So each report pass re-scanned the
-- whole table.
--
-- MEASURED on the 12-10-2026 restore, same call, same range:
--     before   3,208 ms   -> over the 3s limit, report dies
--     after      380 ms   -> 8.4x faster, well inside it
--
-- Raising the timeout was the other option and is the wrong one: it would
-- have left every other anon query slow and hidden the next regression.
--
-- Safe to run with the counter open. CREATE INDEX takes a SHARE lock, which
-- blocks writes to paymentdetails for the few seconds it runs -- on a table
-- this size that is imperceptible, and no existing row is touched. Use
-- CONCURRENTLY instead (see the note at the bottom) if you would rather not
-- block writes at all.
--
-- Idempotent -- IF NOT EXISTS on both. Loops every institution schema.
-- Do NOT wrap in BEGIN: the Supabase editor rolls that back silently, and
-- CREATE INDEX CONCURRENTLY cannot run in a transaction at all.
-- ============================================================================

DO $pd$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'paymentdetails'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS idx_paymentdetails_pay ON %I.paymentdetails (pay_id)',
      r.sch);
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS idx_paymentdetails_dem ON %I.paymentdetails (dem_id)',
      r.sch);
    -- A new index is invisible to the planner until the table is analysed,
    -- so the report stays slow until autovacuum gets round to it otherwise.
    EXECUTE format('ANALYZE %I.paymentdetails', r.sch);
    n := n + 1;
    RAISE NOTICE 'paymentdetails indexed in %', r.sch;
  END LOOP;
  RAISE NOTICE '% schema(s) done', n;
END
$pd$;


-- ------------------------------------------------------------- VERIFY ------
-- Expect both idx_paymentdetails_pay and idx_paymentdetails_dem per schema.
SELECT schemaname, indexname
  FROM pg_indexes
 WHERE tablename = 'paymentdetails'
   AND indexname IN ('idx_paymentdetails_pay', 'idx_paymentdetails_dem')
 ORDER BY schemaname, indexname;

-- And that the report now fits inside the 3s anon budget. Expect well under.
-- \timing on
-- SELECT jsonb_array_length(
--          public.get_daily_collection_report_json(
--            'kcet20262027', 1, '2026-07-01', '2026-10-12')::jsonb) AS rows;


-- ---------------------------------------------------------------------------
-- IF YOU WOULD RATHER NOT BLOCK WRITES, run these four by hand instead of the
-- block above -- CONCURRENTLY cannot be used inside a DO block or a
-- transaction, so there is no way to loop it.
--
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_paymentdetails_pay
--     ON kcet20262027.paymentdetails (pay_id);
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_paymentdetails_dem
--     ON kcet20262027.paymentdetails (dem_id);
--   ANALYZE kcet20262027.paymentdetails;
--
-- A CONCURRENTLY build that fails leaves an INVALID index behind; check with
--   SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
-- and DROP any it lists before retrying.
-- ---------------------------------------------------------------------------
