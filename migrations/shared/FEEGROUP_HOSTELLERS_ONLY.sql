-- ============================================================================
-- A fee group can be marked HOSTELLERS ONLY.
-- ============================================================================
-- WHAT IT FIXES. Student Fee Definition (Fee Collection > Fee Definition)
-- offers every class fee for the student's class and admission type. Nothing
-- narrows it by fee group, so a day scholar is offered MESS FEE and the hostel
-- MISC -- ABARNA P, B.E CSE-I, GOVERNMENT QUOTA, was shown MESS FEE 3,000.
--
-- WHY A FLAG AND NOT A NAME. The obvious shortcut is to hide any group whose
-- name contains HOSTEL. This codebase already threw that away once, for
-- payment routing: "the guess is usually right, which means it is trusted;
-- when it is wrong the money banks somewhere nobody chose." Hiding a fee by a
-- guess has the same shape -- a hosteller silently not billed for mess -- and
-- the name test misses "MA" (mess advance) entirely. So the rule is stated on
-- the group itself, where someone can see it and change it.
--
-- It is also reusable: Misc Collection and Advance can offer the same groups
-- by the same rule instead of each inventing its own.
--
-- A blank students.hostel counts as NOT a hosteller, which is how the Class
-- Fee Demand "Hostellers only" filter already treats it
-- (hostel.eq.N OR hostel.is.null).
--
-- Adds one column to feegroup in every institution schema, defaulting to
-- false so nothing changes until a group is ticked. Idempotent.
-- Do NOT wrap in BEGIN -- the Supabase SQL editor rolls that back silently.
-- ============================================================================

DO $do$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feegroup'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.feegroup
         ADD COLUMN IF NOT EXISTS hostellers_only boolean NOT NULL DEFAULT false',
      r.sch);
    n := n + 1;
    RAISE NOTICE 'feegroup.hostellers_only ready in %', r.sch;
  END LOOP;
  RAISE NOTICE '% schema(s) updated', n;
END
$do$;

-- ---------------------------------------------------------------------------
-- Tick the groups that are hostel-only TODAY, so the flag matches reality the
-- moment it exists. Both of these bank into the hostel account:
--   HOSTEL FEES -- mess and hostel miscellaneous
--   MA          -- mess advance
-- Only sets rows still at the default, so a later change by hand is not undone
-- if this is re-run.
-- ---------------------------------------------------------------------------
DO $seed$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.columns
     WHERE table_name = 'feegroup' AND column_name = 'hostellers_only'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
  LOOP
    EXECUTE format(
      'UPDATE %I.feegroup SET hostellers_only = true
        WHERE hostellers_only = false
          AND (upper(fgdesc) LIKE ''%%HOSTEL%%'' OR upper(btrim(fgdesc)) = ''MA'')',
      r.sch);
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN RAISE NOTICE 'ticked % group(s) in %', n, r.sch; END IF;
  END LOOP;
END
$seed$;

-- ------------------------------------------------------------- VERIFY ------
-- Expect HOSTEL FEES and MA true, COLLEGE FEES and SA false.
SELECT fg_id, fgdesc, ban_id, hostellers_only
  FROM kcet20262027.feegroup
 ORDER BY fg_id;
