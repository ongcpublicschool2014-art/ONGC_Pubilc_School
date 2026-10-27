-- =====================================================================
-- Make the database think in IST, the way everybody using it does.
--
-- WHAT WAS WRONG. Every naive `timestamp` column is stamped with NOW() in a
-- session whose TimeZone is UTC, so it holds UTC -- while the people reading
-- it, the receipts it prints, and Paytm's settlement report are all IST.
-- Dart parses "2026-10-04 18:55:51" (no Z, no offset) as local time and prints
-- it unconverted, so nothing corrects it on the way out either.
--
-- THE PROOF, from the counter's own CASH receipts (hour of paydate):
--     hour  3   4   5   6   7   8   9  10  11
--     count 39  38  60  18  31  20  17  11   3
-- A college counter does not take 60 cash payments at 5am. Add 5h30m and the
-- peak lands at 10:30 IST tapering to 16:30 -- the actual working day.
--
-- WHAT IT COST. Anything paid between 00:00 and 05:30 IST is filed under the
-- PREVIOUS day. Three receipts so far, confirmed against Paytm's own
-- transaction id (which carries Paytm's IST date):
--     FC26/03272  Rs  2,000  reads 30 Sep 19:05 -> really 1 Oct 00:35
--     FC26/03273  Rs  1,600  reads 30 Sep 19:08 -> really 1 Oct 00:38
--     FC26/03330  Rs  1,700  reads  4 Oct 18:55 -> really 5 Oct 00:25
-- The first two are filed in SEPTEMBER for money Paytm settled in OCTOBER.
-- Parents pay from phones at night, so this recurs every month.
--
-- (Four others -- FC26/03260..03263 -- are also on a different day to Paytm,
-- but those are hand-keyed entries from 30 Sep for captures on 28/29 Sep. A
-- data-entry matter, not this bug. They are deliberately NOT touched.)
--
-- WHAT THIS DOES
--   PART 1  points the database and its roles at Asia/Kolkata, so every
--           future NOW() and CURRENT_DATE is IST. That single change covers
--           complete_payment_grouped, save_misc_collection,
--           save_advance_collection, set_payment_status, the back-dating
--           functions (they cast a timestamptz down to naive, picking up the
--           session zone) and every `paydate >= CURRENT_DATE` report filter.
--   PART 2  advances the timestamps already stored by 5h30m, so history reads
--           in the same clock as everything written from now on. Without it
--           the two halves disagree and reports spanning tonight are wrong.
--   PART 3  repairs misc_collection.mcdate, which is a DATE defaulted from
--           CURRENT_DATE and so has no time field to reveal the error.
--
-- WHAT IT DELIBERATELY LEAVES ALONE
--   * The 35 user-entered `date` columns -- due dates, DOB, admission and
--     cheque dates. Those are calendar facts somebody typed; shifting them
--     would be vandalism.
--   * paydate / advdate values of exactly 00:00:00. Those are the 9 Sep bulk
--     import, where midnight means "this day, time unknown". The date is
--     already right.
--   * pending_collection.created_at and the 6 other timestamptz columns.
--     Those store an absolute instant and were never wrong.
--
-- SAFETY CHECKED BEFORE WRITING THIS
--   * students and parents carry BEFORE UPDATE password-HASHING triggers, so
--     an UPDATE touching those tables could have re-hashed every credential.
--     Both guard on the $2a$/$2b$ prefix, and a count confirmed 0 rows hold a
--     non-hashed password -- so the triggers no-op. PART 0 re-checks this on
--     the database it is actually running against and REFUSES if that is not
--     still true.
--   * The only other UPDATE triggers are on classfeedemand and tempfeedemand,
--     neither of which has a naive timestamp column, so neither fires.
--
-- RUN IT WHEN THE COUNTER IS CLOSED. PART 0 refuses while a payment is in
-- flight: moving the clock under a half-finished collection would cost it the
-- 15-minute grace window in webhook_record_refusal.
--
-- AFTERWARDS, RESTART THE PROJECT (Dashboard -> Settings -> General ->
-- Restart). ALTER DATABASE/ROLE only applies to NEW connections and Supavisor
-- holds a pool open; until it recycles, new writes stamp UTC while history is
-- IST. The restart closes that window at once.
--
-- Idempotent -- PART 0 records itself and a second run shifts nothing.
-- NO BEGIN/COMMIT: each DO block is atomic on its own, and a wrapping BEGIN in
-- the Supabase editor gets rolled back while looking like it ran.
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

  -- Would the password triggers do anything? They must not.
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
      'their timestamps would fire the hashing trigger and silently rewrite '
      'those credentials. Hash them deliberately first, then re-run.', v_bad;
  END IF;

  -- Is a collection half-finished right now?
  EXECUTE format(
    'SELECT count(*) FROM %I.payment
      WHERE paystatus = ''I'' AND activestatus = 1
        AND createdat > now() - interval ''20 minutes''', v_schema)
    INTO v_inflight;
  IF v_inflight > 0 THEN
    RAISE EXCEPTION
      'REFUSING: % payment attempt(s) started in the last 20 minutes. Run this '
      'when the counter is closed.', v_inflight;
  END IF;

  RAISE NOTICE 'gate passed: no plaintext credentials, nothing in flight';
END $gate$;


-- ---------------------------------------------------------------------
-- PART 1 -- point the database at Asia/Kolkata
--
-- Tried statement by statement. On a managed project `postgres` may not own
-- the database, in which case ALTER DATABASE is refused and the role-level
-- settings have to carry it -- so a failure here warns rather than aborts,
-- and the VERIFY at the bottom reports what actually took effect.
-- ---------------------------------------------------------------------
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


-- ---------------------------------------------------------------------
-- PART 2 -- bring the stored timestamps into the same clock
--
-- Driven off information_schema rather than a hand-typed list, so a column
-- added since this was written is covered too, and none is missed.
-- ---------------------------------------------------------------------
DO $shift$
DECLARE v_schema text := 'kcet20262027'; r record; n bigint; total bigint := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM public.tz_migration WHERE step = 'data_shift') THEN
    RAISE NOTICE 'PART 2 already applied on % -- shifting nothing',
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
      -- exact midnight = the 9 Sep bulk import, "day known, time not"
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
  RAISE NOTICE 'PART 2 done: % value(s) advanced', total;
END $shift$;


-- ---------------------------------------------------------------------
-- PART 3 -- misc_collection.mcdate
--
-- A DATE defaulted from CURRENT_DATE, so a misc receipt taken after midnight
-- IST silently carries yesterday. createdat here is timestamptz -- an absolute
-- instant, never wrong -- so the true IST day is recoverable exactly.
--
-- Guarded twice: only where the stored date equals the UTC day (i.e. it was
-- defaulted, not chosen) AND differs from the IST day. A back-dated or
-- hand-picked mcdate therefore survives untouched.
-- ---------------------------------------------------------------------
DO $mc$
DECLARE n bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM public.tz_migration WHERE step = 'mcdate_fix') THEN
    RAISE NOTICE 'PART 3 already applied -- skipping'; RETURN;
  END IF;

  UPDATE kcet20262027.misc_collection
     SET mcdate = (createdat AT TIME ZONE 'Asia/Kolkata')::date
   WHERE createdat IS NOT NULL
     AND mcdate =  (createdat AT TIME ZONE 'UTC')::date
     AND mcdate <> (createdat AT TIME ZONE 'Asia/Kolkata')::date;
  GET DIAGNOSTICS n = ROW_COUNT;

  INSERT INTO public.tz_migration(step, note)
  VALUES ('mcdate_fix', format('%s misc receipt date(s) moved to the IST day', n));
  RAISE NOTICE 'PART 3 done: % misc receipt date(s) corrected', n;
END $mc$;


-- =====================================================================
-- VERIFY
-- =====================================================================

-- 1. What will a NEW connection use? Every row must read Asia/Kolkata.
SELECT COALESCE(d.datname, 'ROLE: ' || r.rolname) AS applies_to,
       s.setconfig                                AS settings
  FROM pg_db_role_setting s
  LEFT JOIN pg_database d ON d.oid = s.setdatabase
  LEFT JOIN pg_roles    r ON r.oid = s.setrole
 WHERE array_to_string(s.setconfig, ',') ILIKE '%timezone%'
 ORDER BY 1;

-- 2. The counter's working day. Should now peak 09:00-11:00, not 03:00-05:00.
SELECT extract(hour from paydate)::int AS hour_in_paydate, count(*) AS receipts
  FROM kcet20262027.payment
 WHERE paynumber IS NOT NULL AND activestatus = 1
   AND lower(COALESCE(paymethod, '')) = 'cash'
   AND paydate::time <> '00:00:00'
 GROUP BY 1 ORDER BY 1;

-- 3. Against Paytm's own IST date. wrong_day must fall from 7 to 4 -- the 4
--    survivors being the hand-keyed entries of 30 Sep, which are not this bug.
WITH online AS (
  SELECT paynumber, paydate,
         regexp_replace(payreference, '^PAYTM-WH:', '') AS ref
    FROM kcet20262027.payment
   WHERE paynumber IS NOT NULL AND activestatus = 1
     AND regexp_replace(payreference, '^PAYTM-WH:', '') ~ '^20[0-9]{6}[0-9]{10,}$'
)
SELECT count(*) AS online_receipts_checked,
       count(*) FILTER (
         WHERE paydate::date <> to_date(substring(ref, 1, 8), 'YYYYMMDD')
       ) AS wrong_day
  FROM online;

-- 4. The three that prompted this. Each must now sit on its Paytm day.
SELECT paynumber, transtotalamount AS amount, paydate AS receipt_now_says
  FROM kcet20262027.payment
 WHERE paynumber IN ('FC26/03272', 'FC26/03273', 'FC26/03330')
 ORDER BY paynumber;

-- 5. Nothing may remain dated before the day it was written.
SELECT count(*) AS receipts_still_dated_before_they_were_written
  FROM kcet20262027.payment
 WHERE paynumber IS NOT NULL AND activestatus = 1
   AND paydate::date < createdat::date
   AND paynumber <> 'FC26/03327';   -- the Rs 8,000 recovery, back-dated on purpose

-- 6. What ran.
SELECT step, applied_at, note FROM public.tz_migration ORDER BY applied_at;
