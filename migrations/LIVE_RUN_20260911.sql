-- ============================================================================
-- LIVE DEPLOYMENT -- everything added to the database on 11 Sep 2026
--
-- Verified on live before writing this: none of these objects exist there yet.
-- All of it has been run and exercised on the Seoul test project first, and
-- this combined script was itself run end-to-end on test with ON_ERROR_STOP=1.
--
--   PART 1  get_server_date()
--           Misc receipts were dated by the WORKSTATION clock while regular fee
--           receipts were stamped NOW() server-side, so a PC with a wrong date
--           dated misc a day out. The app now asks the database instead.
--
--   PART 2  feetype.payseq / partialallowed + check_fee_payment_order()
--           Fee priority configuration. The current admin build writes both
--           columns on every fee-type save, so until this runs, editing a fee
--           type on live FAILS with 'column "payseq" does not exist'.
--
--   PART 3  get_daily_collection_report / _unreconciled -- fee-only columns
--           The fee-type column carried the fine as well as the fee, and the
--           fine was ALSO shown in its own column: a 25,000 tuition fee with a
--           100 fine read as TUITION FEE 25,100 + FINE 100. Row totals are
--           untouched, so nothing that tallies to the bank or cash book moves.
--
-- NOTHING HERE CHANGES PAYMENT BEHAVIOUR.
--   * Part 1 and Part 3 create/replace functions only.
--   * Part 2 adds two columns whose defaults are the NEUTRAL values. Note that
--     PostgreSQL 11+ BACKFILLS a non-volatile DEFAULT into existing rows, so
--     every current fee type becomes payseq=100 / partialallowed='Y' -- not
--     NULL. That is exactly "unordered, part payment allowed", i.e. today's
--     behaviour. Priorities are then set per fee type in Fee Master.
--   * NO SEEDING. This script contains no INSERT/UPDATE/DELETE at all. The
--     Bus-first / Exam-last seeding lives only in the test-only file, so this
--     cannot fight whatever the office configures.
--
-- DELIBERATELY NOT INCLUDED: fee_payment_priority_enforce.sql, which wires the
-- rule into create_pending_payment so non-conforming payments are REFUSED. That
-- binds the parent app, and the new APK has not shipped -- running it now would
-- start rejecting real payments from parents on the build they are using.
--
-- SAFE TO RE-RUN in full.
-- ============================================================================


-- ####  PART 1 of 3  #########################################################
CREATE OR REPLACE FUNCTION public.get_server_date() RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER AS $$ SELECT CURRENT_DATE $$;

GRANT EXECUTE ON FUNCTION public.get_server_date() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT public.get_server_date() AS server_date;

-- ####  PART 2 of 3  #########################################################
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


-- ####  PART 3 of 3  #########################################################
-- Daily Collection -- fee-type columns show FEE ONLY, not fee + fine.
-- Reports > Daily Collection and Fee Collection > Daily Collection read the
-- same functions, so both move together and keep agreeing with each other.

CREATE OR REPLACE FUNCTION public.get_daily_collection_report(p_schema text, p_ins_id integer, p_from date, p_to date)
 RETURNS TABLE(pay_id bigint, paynumber text, stuadmno text, stuname text, courname text, stuclass text, semester text, type text, paymethod text, createdby text, fees_json jsonb, fine numeric, total numeric, paydate date)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  p.pay_id::BIGINT,
                p.paynumber::TEXT,
                s.stuadmno::TEXT,
                s.stuname::TEXT,
                s.courname::TEXT,
                s.stuclass::TEXT,
                COALESCE(fd.demfeeterm, '')::TEXT AS semester,
                (CASE WHEN BOOL_OR(UPPER(COALESCE(fd.demseqtype,''))='ARREAR') THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                p.paymethod::TEXT,
                COALESCE(p.createdby, '')::TEXT AS createdby,
                -- FEE ONLY. pd.transtotalamount is what was collected against
                -- the demand and INCLUDES the fine (a receipt legitimately
                -- carries balance + fine), while fd.fineamount on a paid demand
                -- is the fine part of it. Reporting the raw figure here put the
                -- fine inside the fee-type column AND again in the Fine column,
                -- so a 25,000 tuition fee with a 100 fine showed as 25,100 + 100.
                -- The row total is unaffected -- it is summed from the same
                -- collected amounts below, and stays the money actually taken.
                COALESCE(jsonb_object_agg(fd.demfeetype,
                             pd.transtotalamount - COALESCE(fd.fineamount, 0))
                         FILTER (WHERE fd.demfeetype IS NOT NULL),
                         '{}'::jsonb) AS fees_json,
                COALESCE(SUM(fd.fineamount), 0)::NUMERIC AS fine,
                COALESCE(SUM(pd.transtotalamount), MAX(p.transtotalamount), 0)::NUMERIC AS total,
                p.paydate::DATE
        FROM    %1$I.payment p
        LEFT JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
        LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
        LEFT JOIN %1$I.students s ON s.stu_id = p.stu_id
        WHERE   p.ins_id = %2$L AND p.activestatus = 1
            AND p.paystatus IN ('C','R') AND p.recon_status = 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $function$;


-- ── The unreconciled variant carries the identical bug ─────────────────────
-- Reports > Daily Collection's amber 'unreconciled' view reads this one.
-- Both must move together or the two views stop agreeing.

CREATE OR REPLACE FUNCTION public.get_daily_collection_unreconciled(p_schema text, p_ins_id integer, p_from date, p_to date)
 RETURNS TABLE(pay_id bigint, paynumber text, stuadmno text, stuname text, courname text, stuclass text, semester text, type text, paymethod text, createdby text, fees_json jsonb, fine numeric, total numeric, paydate date)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  p.pay_id::BIGINT,
                p.paynumber::TEXT,
                s.stuadmno::TEXT,
                s.stuname::TEXT,
                s.courname::TEXT,
                s.stuclass::TEXT,
                COALESCE(fd.demfeeterm, '')::TEXT AS semester,
                (CASE WHEN BOOL_OR(UPPER(COALESCE(fd.demseqtype,''))='ARREAR') THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                p.paymethod::TEXT,
                COALESCE(p.createdby, '')::TEXT AS createdby,
                -- FEE ONLY -- see get_daily_collection_report. The fine is
                -- reported in its own column, so leaving it inside the fee-type
                -- column counted it twice.
                COALESCE(jsonb_object_agg(fd.demfeetype,
                             pd.transtotalamount - COALESCE(fd.fineamount, 0))
                         FILTER (WHERE fd.demfeetype IS NOT NULL),
                         '{}'::jsonb) AS fees_json,
                COALESCE(SUM(fd.fineamount), 0)::NUMERIC AS fine,
                COALESCE(SUM(pd.transtotalamount), MAX(p.transtotalamount), 0)::NUMERIC AS total,
                p.paydate::DATE
        FROM    %1$I.payment p
        LEFT JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
        LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
        LEFT JOIN %1$I.students s ON s.stu_id = p.stu_id
        WHERE   p.ins_id = %2$L AND p.activestatus = 1
            AND p.paystatus IN ('C','R')
            AND p.recon_status IS DISTINCT FROM 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $function$;

NOTIFY pgrst, 'reload schema';


-- ── FINAL VERIFICATION ──────────────────────────────────────────────────────
-- Expected: server_date = today, columns_added = 2, every *_fn = 1
SELECT
  public.get_server_date() AS server_date,
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema='kcet20262027' AND table_name='feetype'
      AND column_name IN ('payseq','partialallowed'))                   AS columns_added,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='get_server_date')            AS server_date_fn,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='check_fee_payment_order')    AS priority_fn,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('get_daily_collection_report',
                                               'get_daily_collection_unreconciled')) AS report_fns;
