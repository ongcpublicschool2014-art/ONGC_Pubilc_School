-- ============================================================================
-- LIVE DEPLOYMENT -- everything added to the database on 11 Sep 2026
--
-- Verified on live before writing this: NONE of the objects below exist there
-- yet (get_server_date 0, check_fee_payment_order 0, payseq/partialallowed 0).
-- All of it has been run and exercised on the Seoul test project first.
--
--   PART 1  get_server_date()          -- fixes misc receipts dated by the PC
--   PART 2  fee priority columns + read-only check
--
-- BOTH PARTS ARE NON-BREAKING. Part 1 creates a new function and alters
-- nothing. Part 2 adds two columns with NEUTRAL defaults and one read-only
-- function -- nothing refuses money, nothing changes order, until the office
-- configures a fee type in Fee Master.
--
-- DELIBERATELY NOT INCLUDED: the enforcement step
-- (migrations/fee_payment_priority_enforce.sql), which wires the rule into
-- create_pending_payment so payments that break it are refused. That binds the
-- PARENT APP, and the new APK has not shipped yet -- running it now would start
-- refusing real payments from parents on the current build. Run it after the
-- app ships.
--
-- SAFE TO RE-RUN in full.
-- ============================================================================


-- ####  PART 1 of 2  #########################################################
CREATE OR REPLACE FUNCTION public.get_server_date() RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER AS $$ SELECT CURRENT_DATE $$;

GRANT EXECUTE ON FUNCTION public.get_server_date() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT public.get_server_date() AS server_date;

-- ####  PART 2 of 2  #########################################################
-- ── 1. Configuration columns ────────────────────────────────────────────────
DO $g$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'feetype')
       AND left(nspname,3) <> 'pg_'
       AND nspname NOT IN ('public','information_schema','auth','storage',
                           'realtime','vault','extensions','graphql','graphql_public')
  LOOP
    -- Defaults are the NEUTRAL values, not "off": 100 means this fee type is
    -- not ordered against any other, 'Y' means a part payment is accepted.
    --
    -- PostgreSQL 11+ BACKFILLS a non-volatile DEFAULT into existing rows, so
    -- every current fee type comes out of this as payseq=100 / partialallowed='Y'
    -- -- NOT NULL. That is harmless precisely because those are the neutral
    -- values: nothing is ordered and nothing is restricted until the office sets
    -- a fee type in Fee Master. But do not expect blanks on the Fee Master form
    -- afterwards; it shows what is stored, and 100 will be stored.
    EXECUTE format('ALTER TABLE %I.feetype
        ADD COLUMN IF NOT EXISTS payseq         smallint DEFAULT 100,
        ADD COLUMN IF NOT EXISTS partialallowed char(1)  DEFAULT ''Y''', r.nspname);

    RAISE NOTICE 'feetype priority columns ready on %', r.nspname;
  END LOOP;
END
$g$;

-- ── 2. The check, as a read-only function ───────────────────────────────────
-- One row per OUTSTANDING demand for the student: its rank, whether it may be
-- paid now, whether it may be part-paid, and -- when it may not -- what is
-- holding it up, in words a parent can act on.
--
-- Both apps and (later) the payment RPC call THIS, so the cart, the counter and
-- the server cannot drift apart on what the rule means.
CREATE OR REPLACE FUNCTION public.check_fee_payment_order(
    p_ins_id integer,
    p_stu_id bigint
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER STABLE AS $$
DECLARE v text; r json;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN '[]'::json; END IF;

  EXECUTE format($q$
    WITH d AS (
      SELECT fd.dem_id, fd.demfeetype, fd.demfeeterm, fd.demseqtype,
             fd.balancedue,
             COALESCE(ft.payseq, 100)              AS payseq,
             COALESCE(ft.partialallowed, 'Y')      AS partialallowed,
             CASE WHEN upper(trim(coalesce(fd.demseqtype,''))) = 'ARREAR'
                  THEN 0 ELSE 1000 END + COALESCE(ft.payseq, 100) AS rank
        FROM %1$I.feedemand fd
        LEFT JOIN %1$I.feetype ft
               ON ft.feedesc = fd.demfeetype AND ft.ins_id = fd.ins_id
                  AND ft.activestatus = 1
       WHERE fd.ins_id = $1 AND fd.stu_id = $2
         AND fd.activestatus = 1 AND fd.balancedue > 0
    )
    SELECT COALESCE(json_agg(t ORDER BY t.rank, t.demfeetype), '[]'::json)
    FROM (
      SELECT d.dem_id, d.demfeetype, d.demfeeterm, d.demseqtype,
             d.balancedue, d.rank,
             (d.partialallowed = 'Y')                       AS partial_allowed,
             NOT EXISTS (SELECT 1 FROM d b WHERE b.rank < d.rank) AS payable,
             (SELECT string_agg(DISTINCT b.demfeetype, ', ' ORDER BY b.demfeetype)
                FROM d b WHERE b.rank < d.rank)             AS blocked_by,
             (SELECT bool_or(upper(trim(coalesce(b.demseqtype,''))) = 'ARREAR')
                FROM d b WHERE b.rank < d.rank)             AS blocked_by_arrear
        FROM d
    ) t
  $q$, v) INTO r USING p_ins_id, p_stu_id;

  RETURN COALESCE(r, '[]'::json);
END $$;
GRANT EXECUTE ON FUNCTION public.check_fee_payment_order(integer, bigint) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 3. Verify ───────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema='kcet20262027' AND table_name='feetype'
      AND column_name IN ('payseq','partialallowed'))            AS columns_added,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='check_fee_payment_order') AS check_function;

-- ── FINAL VERIFICATION ──────────────────────────────────────────────────────
-- Expected:  server_date = today   columns_added = 2   both functions = 1
SELECT
  public.get_server_date() AS server_date,
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema='kcet20262027' AND table_name='feetype'
      AND column_name IN ('payseq','partialallowed'))                 AS columns_added,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='check_fee_payment_order')  AS check_fn,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='get_server_date')          AS server_date_fn;
