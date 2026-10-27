-- ============================================================================
-- FIX: create_institution_schema is missing the misc recon columns
--
-- WHY THIS IS NEEDED
-- misc_collection_recon.sql section 7 guarded with
--     position('recon_status char(1) DEFAULT ''P''' IN src) > 0  -> skip
-- searching the WHOLE generator source. That exact string also appears in the
-- PAYMENT table's DDL, so the guard matched, the block reported "already done"
-- and patched nothing. misc_collection_paystatus.sql section 3 did not have the
-- flaw (it isolates the misc DDL first), which is why the generator now has
-- paystatus/voidedby but NOT recon_status/paytm_txnid.
--
-- EFFECT: existing institutions are fine -- their tables were altered directly.
-- But a NEW institution would get a misc_collection without these columns, and
-- save_misc_collection (which inserts paytm_txnid and recon_status) would fail
-- on its first misc receipt.
--
-- SAFE TO RE-RUN.
-- ============================================================================

DO $fix$
DECLARE src text; old_misc text; new_misc text; i int; j int;
BEGIN
  SELECT prosrc INTO src FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema'
   LIMIT 1;

  IF src IS NULL THEN
    RAISE NOTICE 'create_institution_schema not found - skipping';
    RETURN;
  END IF;

  -- Isolate the misc_collection CREATE TABLE. Everything below tests and
  -- rewrites THIS substring only -- the mistake being fixed here came from
  -- searching the whole source, where payment's DDL looks identical.
  i := position('CREATE TABLE %I.misc_collection' IN src);
  IF i = 0 THEN
    RAISE NOTICE 'misc_collection DDL not found - CHECK BY HAND';
    RETURN;
  END IF;
  old_misc := substr(src, i, 4000);
  j := position(''', v_schema)' IN old_misc);
  IF j = 0 THEN
    RAISE NOTICE 'could not find the end of the misc DDL - CHECK BY HAND';
    RETURN;
  END IF;
  old_misc := left(old_misc, j - 1);

  IF position('recon_status' IN old_misc) > 0 THEN
    RAISE NOTICE 'generator already builds misc_collection with recon_status - nothing to do';
    RETURN;
  END IF;

  IF right(old_misc, 1) <> ')' THEN
    RAISE NOTICE 'misc DDL does not end as expected - CHECK BY HAND';
    RETURN;
  END IF;

  -- Replace the WHOLE misc DDL, not a short tail: the tail this generator now
  -- ends with ("voidreason varchar(255))") also terminates the payment table,
  -- and replace() would rewrite both.
  -- Dollar-quoted so the doubled quotes around P are readable: the text has to
  -- land in the body as  DEFAULT ''P''  because it sits inside a format('...')
  -- literal there.
  new_misc := left(old_misc, length(old_misc) - 1)
    || $cols$, paytm_txnid varchar(60), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamptz, bank_reference varchar(100), bank_date date)$cols$;

  EXECUTE 'CREATE OR REPLACE FUNCTION public.create_institution_schema('
          || 'p_schema_name text, p_ins_id integer DEFAULT NULL,'
          || 'p_year_label text DEFAULT NULL, p_start_date date DEFAULT NULL,'
          || 'p_end_date date DEFAULT NULL) RETURNS void'
          || ' LANGUAGE plpgsql SECURITY DEFINER AS $fnx$'
          || replace(src, old_misc, new_misc) || '$fnx$';

  RAISE NOTICE 'create_institution_schema now builds misc_collection with the recon columns';
END
$fix$;

-- ── Verify: BOTH sets of columns must be in the misc DDL, and payment must
--    still be intact (one occurrence of its own voidreason tail).
DO $v$
DECLARE src text; misc text; i int; j int;
BEGIN
  SELECT prosrc INTO src FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_institution_schema' LIMIT 1;
  i := position('CREATE TABLE %I.misc_collection' IN src);
  misc := substr(src, i, 4000);
  j := position(''', v_schema)' IN misc);
  misc := left(misc, j - 1);

  RAISE NOTICE 'misc DDL -> paytm_txnid:%  recon_status:%  paystatus:%  voidedby:%',
    position('paytm_txnid'  IN misc) > 0,
    position('recon_status' IN misc) > 0,
    position('paystatus'    IN misc) > 0,
    position('voidedby'     IN misc) > 0;
  RAISE NOTICE 'payment DDL still present: %',
    position('CREATE TABLE %I.payment (' IN src) > 0;
END
$v$;

NOTIFY pgrst, 'reload schema';
