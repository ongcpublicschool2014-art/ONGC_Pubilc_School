-- ============================================================================
-- Fee payment priority  (step 1 of 2: configuration + a read-only check)
--
-- THE RULES, as data rather than code:
--   * Bus fees must be cleared before anything else.
--   * Exam fee is payable only once every other pending fee is cleared.
--   * Arrears must be cleared before the same student's regular fees.
--   * Tuition may be part-paid; bus and exam must be paid in full.
--
-- Two columns on feetype express the first two, and one formula folds in the
-- third:
--
--     rank = (arrear ? 0 : 1000) + payseq
--
--   arrear bus        10      regular bus        1010
--   arrear others    100      regular others     1100
--   arrear exam      900      regular exam       1900
--
-- and one rule covers all of it:
--
--     a demand is payable only when every demand of lower rank
--     has a zero balance.
--
-- "Bus first" and "exam last" are the same rule read from either end, which is
-- why this is a sequence number rather than a pile of flags -- a new fee type
-- slots in by number without touching any code. Seniority outranks fee type
-- (the 1000), so every arrear clears before any current-year fee: oldest money
-- first, which is what an arrear rule is for.
--
-- THIS FILE CHANGES NO BEHAVIOUR. It adds the configuration and a read-only
-- function the apps can ask "may this be paid, and if not why". Step 2 puts the
-- same test inside the payment RPCs, which is where it actually binds -- the
-- mobile app holds the anon key, so a rule enforced only in the cart UI is a
-- suggestion. Shipping the check first lets the greying-out be proven against
-- real data before anything can refuse money.
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
    -- payseq 100 = the middle of the road: no fee type is ordered against
    -- another unless it is deliberately given a different number.
    -- partialallowed 'Y' = today's behaviour, so nothing becomes stricter by
    -- simply running this file.
    EXECUTE format('ALTER TABLE %I.feetype
        ADD COLUMN IF NOT EXISTS payseq         smallint DEFAULT 100,
        ADD COLUMN IF NOT EXISTS partialallowed char(1)  DEFAULT ''Y''', r.nspname);

    EXECUTE format('UPDATE %I.feetype SET payseq = 100 WHERE payseq IS NULL', r.nspname);
    EXECUTE format('UPDATE %I.feetype SET partialallowed = ''Y''
                     WHERE partialallowed IS NULL', r.nspname);

    -- Seed the three rules that were actually asked for. Matched on the fee
    -- description, and ONLY where the value is still the default -- an office
    -- that has since tuned these keeps its settings when this is re-run.
    EXECUTE format($u$
      UPDATE %I.feetype
         SET payseq = 10, partialallowed = 'N'
       WHERE activestatus = 1 AND payseq = 100
         AND upper(feedesc) LIKE 'BUS FEE%%'
    $u$, r.nspname);

    EXECUTE format($u$
      UPDATE %I.feetype
         SET payseq = 900, partialallowed = 'N'
       WHERE activestatus = 1 AND payseq = 100
         AND upper(feedesc) LIKE 'EXAM FEE%%'
    $u$, r.nspname);

    EXECUTE format($u$
      UPDATE %I.feetype
         SET partialallowed = 'Y'
       WHERE activestatus = 1 AND upper(feedesc) LIKE 'TUITION FEE%%'
    $u$, r.nspname);

    RAISE NOTICE 'feetype priority columns ready on %', r.nspname;
  END LOOP;
END
$g$;

-- ── 2. The check, as a read-only function ───────────────────────────────────
-- Returns one row per OUTSTANDING demand for the student: its rank, whether it
-- may be paid now, whether it may be part-paid, and -- when it may not -- what
-- is holding it up, in words the parent can act on.
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

-- ── 3. Verify: the configured order ─────────────────────────────────────────
SELECT feedesc, feeshort, payseq, partialallowed
  FROM kcet20262027.feetype
 WHERE activestatus = 1 AND (payseq <> 100 OR partialallowed <> 'Y')
 ORDER BY payseq, feedesc;
