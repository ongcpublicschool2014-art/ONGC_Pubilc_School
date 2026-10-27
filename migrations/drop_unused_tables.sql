-- Cleanup: drop two unused tables (2026-08-24).
--
-- 1) public.bank — legacy/unused. Bank accounts live PER institution schema as
--    %I.bank (the Bank Accounts screen + feegroup/payment FKs use that one).
--    Nothing (FK, view, function, or app code) references public.bank.
--
-- 2) <schema>.feegroup_accountant — an unwired scaffold from the fee-group ->
--    accountant access-mapping plan. No app code and no DB function references
--    it. It is a PER-SCHEMA table, so drop it in each institution schema.
--
-- Both removed from complete_setup.sql and update_create_institution_schema.sql
-- so fresh setups / new schemas no longer create them.

-- 1) Public legacy bank table.
DROP TABLE IF EXISTS public.bank;

-- 2) Per-schema access-mapping scaffold — repeat per institution schema.
DROP TABLE IF EXISTS kcet20262027.feegroup_accountant;

-- To drop feegroup_accountant from EVERY institution schema at once:
-- DO $$
-- DECLARE r record;
-- BEGIN
--   FOR r IN
--     SELECT n.nspname AS schema
--     FROM pg_namespace n
--     WHERE EXISTS (SELECT 1 FROM pg_class c
--                   WHERE c.relnamespace = n.oid AND c.relname = 'feegroup_accountant')
--   LOOP
--     EXECUTE format('DROP TABLE IF EXISTS %I.feegroup_accountant', r.schema);
--   END LOOP;
-- END $$;
