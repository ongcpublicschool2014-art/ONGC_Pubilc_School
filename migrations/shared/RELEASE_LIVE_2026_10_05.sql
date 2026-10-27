-- =====================================================================
-- LIVE RELEASE -- 05-10-2026.  Run this ONE script.
--
-- Everything live is missing that TEST already has and has been verified with.
-- Two changes, plus a read-only audit at the end.
--
--   PART 1  paytm_mid_for_routing -- removing a bank account must not strand
--           money already in flight under it.
--   PART 2  The database thinks in IST, not UTC, and the timestamps already
--           stored are brought into the same clock.
--
-- ---------------------------------------------------------------------
-- RUN IT WHEN THE COUNTER IS CLOSED.
--
-- PART 0 refuses while any payment has been started in the last 20 minutes:
-- moving the clock under a half-finished collection would cost it the
-- 15-minute grace window in webhook_record_refusal. A refusal changes NOTHING
-- -- the editor rolls the whole batch back, as it did this afternoon -- so a
-- refused run is safe to simply repeat later.
--
-- AFTERWARDS, RESTART THE PROJECT (Dashboard -> Settings -> General ->
-- Restart). ALTER DATABASE/ROLE only applies to NEW connections and Supavisor
-- holds a pool open; until it recycles, fresh writes stamp UTC while history
-- is IST.
--
-- AND PUSH THE DESKTOP UPDATE. The installed 0.0.10 parses paydate without
-- .toLocal(), so once this runs it would hide any payment taken between
-- midnight and 05:30 IST from the Transactions screen. Daily Collection and
-- the money are unaffected; it is that one screen.
-- ---------------------------------------------------------------------
--
-- WHAT IT COSTS, exactly. Three receipts change DAY, all one student
-- (JAYASURYA S, who pays from a phone just after midnight):
--     FC26/03272  Rs 2,000   30 Sep -> 1 Oct
--     FC26/03273  Rs 1,600   30 Sep -> 1 Oct
--     FC26/03330  Rs 1,700    4 Oct -> 5 Oct
-- So SEPTEMBER's total falls Rs 3,600 and OCTOBER's rises Rs 3,600. Every
-- other receipt keeps its date; only the printed TIME moves, to the real one.
-- No amount, receipt number, demand, balance or ledger changes, and the grand
-- total is identical before and after.
--
-- Verified end to end on TEST (05-10-2026): 24,760 timestamps shifted, 0 misc
-- dates needed correcting, all five checks ok, busiest cash hour moved 05:00
-- -> 09:00, receipts disagreeing with Paytm fell 7 -> 4.
--
-- Idempotent. NO BEGIN/COMMIT: each DO block is atomic on its own, and a
-- wrapping BEGIN in the Supabase editor is rolled back while looking like it
-- ran.
-- =====================================================================


-- ---------------------------------------------------------------------
-- PART 0 -- the gate and the ledger
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tz_migration (
  step       text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now(),
  note       text
);
REVOKE ALL ON public.tz_migration FROM PUBLIC, anon, authenticated;

DO $gate$
DECLARE v_schema text := 'kcet20262027'; v_bad int; v_inflight int;
BEGIN
  IF to_regclass(v_schema || '.payment') IS NULL THEN
    RAISE EXCEPTION 'schema % not found here -- wrong database?', v_schema;
  END IF;

  -- students and parents carry BEFORE UPDATE password-HASHING triggers, so the
  -- shift in PART 2 runs them across every row. They guard on the $2a$/$2b$
  -- prefix and no-op on an already-hashed password -- but a PLAINTEXT one would
  -- be silently rewritten and that login would break. Refuse rather than risk it.
  EXECUTE format(
    'SELECT (SELECT count(*) FROM %1$I.students
              WHERE COALESCE(stupassword,'''') <> ''''
                AND left(stupassword,4) NOT IN (''$2a$'',''$2b$''))
          + (SELECT count(*) FROM %1$I.parents
              WHERE COALESCE(parpassword,'''') <> ''''
                AND left(parpassword,4) NOT IN (''$2a$'',''$2b$''))', v_schema)
    INTO v_bad;
  IF v_bad > 0 THEN
    RAISE EXCEPTION
      'REFUSING: % student/parent row(s) hold a non-hashed password. Shifting '
      'their timestamps would fire the hashing trigger and rewrite those '
      'credentials. Hash them deliberately first, then re-run.', v_bad;
  END IF;

  EXECUTE format(
    'SELECT count(*) FROM %I.payment
      WHERE paystatus = ''I'' AND activestatus = 1
        AND createdat > now() - interval ''20 minutes''', v_schema)
    INTO v_inflight;
  IF v_inflight > 0 THEN
    RAISE EXCEPTION
      'REFUSING: % payment attempt(s) started in the last 20 minutes. Run this '
      'when the counter is closed. Nothing has been changed.', v_inflight;
  END IF;

  RAISE NOTICE 'gate passed: no plaintext credentials, nothing in flight';
END $gate$;


-- =====================================================================
-- PART 1 -- removing a bank must not strand money in flight under it
--
-- paytm_mid_for_routing answers two different questions with one filter:
--
--   by FEE GROUP  -- "where should this NEW payment settle?"
--   by BAN_ID     -- "which merchant SIGNED this order that already exists?"
--
-- Both required b.activestatus = 1. For the first that is right -- new money
-- must never route to a removed account. For the second it is wrong.
--
-- Deleting a bank is a SOFT delete. The moment it happens, every unfinished
-- intent signed with that bank loses its merchant: the lookup returns NULL,
-- the sweep falls back to the INSTITUTION default merchant, and Paytm is asked
-- about an order it never saw under that merchant. The answer is "no record" --
-- correctly treated as UNDECIDED, so nothing is written off, but nothing is
-- ever recovered either. A real capture would sit unreceipted for ever, with
-- no trace but a parent insisting they paid.
--
-- Which merchant signed an order is a HISTORICAL FACT, so that lookup no
-- longer filters activestatus. The fee-group lookup keeps it. The institution
-- scope is untouched -- that is the part doing the isolation.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.paytm_mid_for_routing(
  p_ins_id integer,
  p_fg_id  integer DEFAULT NULL,
  p_ban_id integer DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v_schema text;
  v_mid    text;
BEGIN
  IF p_fg_id IS NULL AND p_ban_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_fg_id IS NOT NULL THEN
    -- WHERE SHOULD NEW MONEY GO? activestatus = 1 kept deliberately: a removed
    -- account must not receive a fresh payment.
    EXECUTE format(
      'SELECT b.paytm_mid
         FROM %I.feegroup g
         JOIN %I.bank b ON b.ban_id = g.ban_id
        WHERE g.fg_id = $1 AND g.ins_id = $2
          AND g.activestatus = 1 AND b.activestatus = 1
        LIMIT 1', v_schema, v_schema)
      INTO v_mid USING p_fg_id, p_ins_id;
  END IF;

  IF (v_mid IS NULL OR trim(v_mid) = '') AND p_ban_id IS NOT NULL THEN
    -- WHO SIGNED THE ORDER THAT ALREADY EXISTS? A historical question, so NO
    -- activestatus filter. Still scoped to the institution.
    EXECUTE format(
      'SELECT b.paytm_mid
         FROM %I.bank b
        WHERE b.ban_id = $1 AND b.ins_id = $2
        LIMIT 1', v_schema, v_schema)
      INTO v_mid USING p_ban_id, p_ins_id;
  END IF;

  -- Empty string means "not configured", same as no row: the caller must fall
  -- back to the institution merchant rather than sign an order with ''.
  RETURN NULLIF(trim(COALESCE(v_mid, '')), '');
END;
$function$;

COMMENT ON FUNCTION public.paytm_mid_for_routing(integer, integer, integer) IS
  'The Paytm merchant a fee group settles to. Exists because <schema>.bank is '
  'invisible to a parent session under RLS, which silently routed every '
  'parent-app payment to the institution default merchant. The ban_id lookup '
  'does NOT filter activestatus: it answers which merchant signed an EXISTING '
  'order, so a since-deleted account must still resolve.';

GRANT EXECUTE ON FUNCTION public.paytm_mid_for_routing(integer, integer, integer)
  TO anon, authenticated;


-- =====================================================================
-- PART 2 -- the database thinks in IST
-- =====================================================================

-- 2a. The settings. Tried statement by statement: on a managed project
--     `postgres` may not own the database, in which case ALTER DATABASE is
--     refused and the role settings carry it. (On TEST all six took.)
DO $tz$
DECLARE r record; v_ok text := ''; v_no text := '';
BEGIN
  BEGIN
    EXECUTE format('ALTER DATABASE %I SET TimeZone = %L',
                   current_database(), 'Asia/Kolkata');
    v_ok := v_ok || 'database:' || current_database() || ' ';
  EXCEPTION WHEN OTHERS THEN
    v_no := v_no || 'database ';
  END;

  FOR r IN SELECT rolname FROM pg_roles
            WHERE rolname IN ('postgres','authenticator','anon','authenticated',
                              'service_role','supabase_auth_admin',
                              'supabase_storage_admin','pgbouncer')
            ORDER BY rolname
  LOOP
    BEGIN
      EXECUTE format('ALTER ROLE %I SET TimeZone = %L', r.rolname, 'Asia/Kolkata');
      v_ok := v_ok || r.rolname || ' ';
    EXCEPTION WHEN OTHERS THEN
      v_no := v_no || r.rolname || ' ';
    END;
  END LOOP;

  RAISE NOTICE 'timezone SET on: %', COALESCE(NULLIF(v_ok, ''), 'nothing');
  IF NULLIF(v_no, '') IS NOT NULL THEN
    RAISE WARNING 'could NOT set on: %', v_no;
  END IF;
END $tz$;


-- 2b. Bring the stored timestamps into the same clock. Driven off
--     information_schema rather than a hand-typed list, so a column added
--     since this was written is covered and none is missed.
--
--     LEFT ALONE, deliberately: the 35 user-entered `date` columns (due dates,
--     DOB, admission and cheque dates -- calendar facts somebody typed), the
--     7 timestamptz columns (absolute instants, never wrong), and paydate /
--     advdate of exactly 00:00:00 (the 9 Sep bulk import, where midnight means
--     "this day, time unknown" and the date is already right).
DO $shift$
DECLARE v_schema text := 'kcet20262027'; r record; n bigint; total bigint := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM public.tz_migration WHERE step = 'data_shift') THEN
    RAISE NOTICE 'already applied on % -- shifting nothing',
      (SELECT applied_at FROM public.tz_migration WHERE step = 'data_shift');
    RETURN;
  END IF;

  FOR r IN SELECT table_name AS t, column_name AS c
             FROM information_schema.columns
            WHERE table_schema = v_schema
              AND data_type = 'timestamp without time zone'
            ORDER BY table_name, column_name
  LOOP
    IF r.c IN ('paydate', 'advdate') THEN
      EXECUTE format(
        'UPDATE %I.%I SET %I = %I + interval ''5 hours 30 minutes''
          WHERE %I IS NOT NULL AND %I::time <> ''00:00:00''',
        v_schema, r.t, r.c, r.c, r.c, r.c);
    ELSE
      EXECUTE format(
        'UPDATE %I.%I SET %I = %I + interval ''5 hours 30 minutes''
          WHERE %I IS NOT NULL',
        v_schema, r.t, r.c, r.c, r.c);
    END IF;
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
    IF n > 0 THEN RAISE NOTICE '  %.% -> % row(s)', r.t, r.c, n; END IF;
  END LOOP;

  INSERT INTO public.tz_migration(step, note)
  VALUES ('data_shift', format('%s naive timestamp values advanced 5h30m', total));
  RAISE NOTICE 'PART 2b done: % value(s) advanced', total;
END $shift$;


-- 2c. misc_collection.mcdate is a DATE defaulted from CURRENT_DATE, so it has
--     no time field to reveal the error. createdat here is timestamptz -- an
--     absolute instant -- so the true IST day is exact. Guarded twice: only
--     where the stored date equals the UTC day (i.e. it was DEFAULTED, not
--     chosen) AND differs from the IST day, so a hand-picked or back-dated
--     mcdate survives untouched. On TEST this corrected 0 rows.
DO $mc$
DECLARE n bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM public.tz_migration WHERE step = 'mcdate_fix') THEN
    RAISE NOTICE 'already applied -- skipping'; RETURN;
  END IF;

  UPDATE kcet20262027.misc_collection
     SET mcdate = (createdat AT TIME ZONE 'Asia/Kolkata')::date
   WHERE createdat IS NOT NULL
     AND mcdate =  (createdat AT TIME ZONE 'UTC')::date
     AND mcdate <> (createdat AT TIME ZONE 'Asia/Kolkata')::date;
  GET DIAGNOSTICS n = ROW_COUNT;

  INSERT INTO public.tz_migration(step, note)
  VALUES ('mcdate_fix', format('%s misc receipt date(s) moved to the IST day', n));
  RAISE NOTICE 'PART 2c done: % misc receipt date(s) corrected', n;
END $mc$;

NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- VERIFY -- one result set, because the Supabase editor shows only the LAST.
-- Every row must read 'ok'.
--
-- The last two rows are a READ-ONLY AUDIT and change nothing. They are here
-- because a pg_restore into TEST was found to have silently re-opened these:
-- recreating a table in `public` lets Supabase's default privileges grant anon
-- everything, and the original REVOKE is never replayed -- a dump records the
-- grants that exist, never the ones deliberately absent. Live should never
-- have been through that, but it is worth one look. If either reads LOOK,
-- tell me before doing anything: blanket-revoking would break the Transactions
-- screen, which legitimately calls list_pending_collections as anon.
-- =====================================================================
WITH peak AS (
  SELECT extract(hour from paydate)::int AS h, count(*) AS c
    FROM kcet20262027.payment
   WHERE paynumber IS NOT NULL AND activestatus = 1
     AND lower(COALESCE(paymethod, '')) = 'cash'
     AND paydate::time <> '00:00:00'
   GROUP BY 1 ORDER BY c DESC LIMIT 1
),
online AS (
  SELECT paydate, regexp_replace(payreference, '^PAYTM-WH:', '') AS ref
    FROM kcet20262027.payment
   WHERE paynumber IS NOT NULL AND activestatus = 1
     AND regexp_replace(payreference, '^PAYTM-WH:', '') ~ '^20[0-9]{6}[0-9]{10,}$'
),
strays AS (
  SELECT count(*) AS n
    FROM kcet20262027.payment
   WHERE paynumber IS NOT NULL AND activestatus = 1
     AND paydate::date < createdat::date
     AND paydate::time <> '00:00:00'
     AND paynumber <> 'FC26/03327'   -- the Rs 8,000 recovery, back-dated on purpose
)
SELECT '1. timezone settings -> Asia/Kolkata' AS check,
       (SELECT count(*)::text FROM pg_db_role_setting
         WHERE array_to_string(setconfig, ',') ILIKE '%Asia/Kolkata%') AS value,
       CASE WHEN (SELECT count(*) FROM pg_db_role_setting
                   WHERE array_to_string(setconfig, ',') ILIKE '%Asia/Kolkata%') > 0
            THEN 'ok' ELSE 'FAILED - nothing took' END AS state
UNION ALL
SELECT '2. busiest cash hour (was 05:00; want 09-11)',
       (SELECT h || ':00 with ' || c || ' receipts' FROM peak),
       (SELECT CASE WHEN h BETWEEN 9 AND 11 THEN 'ok' ELSE 'LOOK' END FROM peak)
UNION ALL
SELECT '3. online receipts on a different day to Paytm (want 4)',
       (SELECT count(*) FILTER (
                 WHERE paydate::date <> to_date(substring(ref,1,8),'YYYYMMDD'))::text
          FROM online),
       (SELECT CASE WHEN count(*) FILTER (
                 WHERE paydate::date <> to_date(substring(ref,1,8),'YYYYMMDD')) = 4
                    THEN 'ok' ELSE 'LOOK' END FROM online)
UNION ALL
SELECT '4. the three that move, now on their Paytm day',
       (SELECT string_agg(paynumber || ' = ' || paydate::date, ',  ' ORDER BY paynumber)
          FROM kcet20262027.payment
         WHERE paynumber IN ('FC26/03272','FC26/03273','FC26/03330')),
       (SELECT CASE WHEN count(*) = 3 THEN 'ok' ELSE 'LOOK' END
          FROM kcet20262027.payment
         WHERE (paynumber IN ('FC26/03272','FC26/03273') AND paydate::date = DATE '2026-10-01')
            OR (paynumber = 'FC26/03330'                 AND paydate::date = DATE '2026-10-05'))
UNION ALL
SELECT '5. receipts still dated before they were written (want 0)',
       (SELECT n::text FROM strays),
       (SELECT CASE WHEN n = 0 THEN 'ok' ELSE 'LOOK' END FROM strays)
UNION ALL
SELECT '6. a deleted bank still resolves the order it signed',
       '', (SELECT CASE WHEN prosrc LIKE '%WHO SIGNED THE ORDER%' THEN 'ok' ELSE 'FAILED' END
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname='public' AND p.proname='paytm_mid_for_routing')
UNION ALL
SELECT '7. new money still refuses a deleted bank',
       '', (SELECT CASE WHEN prosrc LIKE '%g.activestatus = 1 AND b.activestatus = 1%'
                        THEN 'ok' ELSE 'FAILED' END
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname='public' AND p.proname='paytm_mid_for_routing')
UNION ALL
SELECT 'AUDIT. anon cannot write the recovery tables',
       'pending_collection / webhook_refusal',
       CASE WHEN has_table_privilege('anon','public.pending_collection','INSERT')
              OR has_table_privilege('anon','public.webhook_refusal','INSERT')
            THEN 'LOOK - anon can write' ELSE 'ok' END
UNION ALL
SELECT 'AUDIT. webhook-only functions are service_role only',
       'webhook_record_refusal',
       CASE WHEN EXISTS (
              SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
               WHERE n.nspname='public' AND p.proname='webhook_record_refusal'
                 AND has_function_privilege('anon', p.oid, 'EXECUTE'))
            THEN 'LOOK - anon can execute' ELSE 'ok' END
 ORDER BY 1;
