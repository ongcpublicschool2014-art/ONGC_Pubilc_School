-- ============================================================================
-- One bank account number, one live row.
-- ============================================================================
-- WHY. Bank Accounts had no uniqueness on banaccno, so the same account could
-- be added twice. That is not a cosmetic duplicate:
--
--   * a fee group routes to a ban_id, so the two halves of ONE real account
--     can be mapped to different groups;
--   * each row carries its own paytm_mid, so online money for the same
--     account can be signed by two different merchants;
--   * the bank statement shows one account, and reconciliation cannot tell
--     which of the two rows a credit belongs to.
--
-- PARTIAL ON activestatus = 1, deliberately. A removed account keeps its
-- number -- this database already has one: ban_id 3 (KCET HOSTEL, removed)
-- holds the same number as the live ban_id 2. A full unique index would
-- refuse to build, and forcing it would mean rewriting history to satisfy a
-- rule that only needs to apply to accounts still in use.
--
-- btrim(), not the raw column: ' 123' and '123' are the same account, and a
-- trailing space is exactly the kind of thing that gets typed once.
--
-- PART 0 refuses to install if live duplicates already exist, so the index
-- build cannot fail halfway with a constraint-violation message that does not
-- say which rows caused it.
--
-- Do NOT wrap in BEGIN -- the Supabase editor rolls that back silently.
-- ============================================================================


-- =================================================================== PART 0 =
-- Refuse while any schema has two LIVE rows on one account number.
-- ===========================================================================

DO $guard$
DECLARE r record; bad text := ''; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'bank'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    FOR r IN EXECUTE format(
      'SELECT %L AS sch, btrim(banaccno) AS accno, count(*) AS c,
              string_agg(ban_id::text, '', '' ORDER BY ban_id) AS ids
         FROM %I.bank
        WHERE activestatus = 1 AND COALESCE(btrim(banaccno), '''') <> ''''
        GROUP BY btrim(banaccno) HAVING count(*) > 1', r.sch, r.sch)
    LOOP
      bad := bad || format('%s  %s: account %s on ban_id %s',
                           chr(10), r.sch, r.accno, r.ids);
      n := n + 1;
    END LOOP;
  END LOOP;
  IF n > 0 THEN
    RAISE EXCEPTION 'NOT INSTALLED. % duplicate account number(s) are still live:%',
      n,
      bad || chr(10) || chr(10)
          || 'Remove or correct the extra row in Setup > Bank Accounts, '
          || 'then run this script again.';
  END IF;
  RAISE NOTICE 'PART 0 ok: no live duplicate account numbers.';
END
$guard$;


-- =================================================================== PART 1 =
-- The index, in every institution schema.
-- ===========================================================================

DO $mk$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'bank'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format(
      'CREATE UNIQUE INDEX IF NOT EXISTS bank_accno_live_uniq
         ON %I.bank (btrim(banaccno)) WHERE activestatus = 1', r.sch);
    n := n + 1;
    RAISE NOTICE 'bank_accno_live_uniq ready in %', r.sch;
  END LOOP;
  RAISE NOTICE '% schema(s) done', n;
END
$mk$;


-- ------------------------------------------------------------- VERIFY ------
-- One row per institution schema.
SELECT schemaname, indexname
  FROM pg_indexes
 WHERE tablename = 'bank' AND indexname = 'bank_accno_live_uniq'
 ORDER BY schemaname;

-- And the accounts as they stand. A removed row may legitimately share a
-- number with a live one; two LIVE rows may not.
SELECT ban_id, banname, banbranch, banaccno, banaccholder, activestatus,
       CASE WHEN COALESCE(paytm_mid, '') = '' THEN '-' ELSE 'mid set' END AS merchant
  FROM kcet20262027.bank
 ORDER BY ban_id;
