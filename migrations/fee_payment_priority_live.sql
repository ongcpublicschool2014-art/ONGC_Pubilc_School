-- ============================================================================
-- Fee payment priority -- columns + read-only check   (LIVE)
--
-- Same as fee_payment_priority.sql but WITHOUT the seeding blocks: Bus/Exam/
-- Tuition are configured from Fee Master in the admin app, so hard-coding them
-- here would only fight with whatever the office sets.
--
-- THE MODEL
--   payseq          clearance order. Lower clears first. 100 = neutral.
--   partialallowed  'Y' = part payment accepted, 'N' = full balance only.
--
--   rank = (arrear ? 0 : 1000) + payseq
--
--   and one rule: a demand is payable only when every demand of LOWER rank
--   has a zero balance.
--
--   Bus 10 therefore clears before everything; Exam 900 after everything; and
--   the 1000 makes every arrear clear before the same student's current-year
--   fees. A new fee type slots in by number without touching any code.
--
-- CHANGES NO BEHAVIOUR. It adds two columns (neutral defaults, so nothing is
-- ordered or restricted until the office configures it) and one read-only
-- function. Nothing refuses money. Enforcement inside the payment RPCs is a
-- separate, later step.
--
-- WHY RUN IT ON LIVE NOW: the admin build writes payseq/partialallowed on every
-- fee type save, so without these columns editing a fee type on live fails with
-- 'column "payseq" does not exist'.
--
-- SAFE TO RE-RUN.
-- ============================================================================

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
