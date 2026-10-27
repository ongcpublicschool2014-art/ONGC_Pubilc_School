-- ============================================================================
-- Clear ALL data from one institution schema, plus that institution's rows in
-- public.admission and public.rollno_change.
--
-- Structure survives: tables, triggers, sequences, policies and grants all stay,
-- so the app keeps working and you can re-import straight away. Only rows go.
--
-- Run STEP 1 alone first. It only counts, and it is the ONLY reliable count --
-- the app's anon key is blocked by RLS on students / payment / feedemand and
-- reports 0 rows for them no matter what is really there. The SQL editor runs
-- as postgres and sees everything.
-- ============================================================================


-- ════════════════════════════════════════════════════════════════════════════
-- STEP 1 — COUNT FIRST. Run this alone and read it.
-- ════════════════════════════════════════════════════════════════════════════
DO $count$
DECLARE
  v_schema text := 'kcet20262027';   -- ◄─ EDIT
  v_ins    int  := 1;                -- ◄─ EDIT
  r        record;
  n        bigint;
  v_pay    bigint := 0;
  v_total  bigint := 0;
BEGIN
  RAISE NOTICE '--- % (ins_id %) ---', v_schema, v_ins;
  FOR r IN SELECT tablename FROM pg_tables
            WHERE schemaname = v_schema ORDER BY tablename
  LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I', v_schema, r.tablename) INTO n;
    v_total := v_total + n;
    IF n > 0 THEN RAISE NOTICE '  %-26s %s', r.tablename, n; END IF;
    IF r.tablename = 'payment' THEN v_pay := n; END IF;
  END LOOP;
  RAISE NOTICE '  %-26s %s', '(schema total)', v_total;

  SELECT count(*) INTO n FROM public.admission WHERE ins_id = v_ins;
  RAISE NOTICE '  %-26s %s', 'public.admission', n;
  SELECT count(*) INTO n FROM public.rollno_change WHERE ins_id = v_ins;
  RAISE NOTICE '  %-26s %s', 'public.rollno_change', n;

  IF v_pay > 0 THEN
    RAISE NOTICE ' ';
    RAISE NOTICE '*** % payment row(s). This wipe deletes every receipt and its', v_pay;
    RAISE NOTICE '*** payment history. Back up before STEP 2 -- there is no undo.';
  END IF;
END
$count$;


-- ════════════════════════════════════════════════════════════════════════════
-- STEP 2 — WIPE.
--
-- One transaction: if any part fails, nothing is deleted.
--
-- TRUNCATE ... CASCADE rather than DELETE, so foreign keys are followed
-- automatically instead of hand-ordering thirty tables. Every FK in the schema
-- points within the schema, so CASCADE cannot reach outside it.
-- ════════════════════════════════════════════════════════════════════════════
DO $wipe$
DECLARE
  v_schema text := 'kcet20262027';   -- ◄─ EDIT
  v_ins    int  := 1;                -- ◄─ EDIT

  -- Tables kept. `year` is the schema's own academic-year record: it is created
  -- by create_institution_schema, never imported, and allocate_admission_to_student
  -- reads it to resolve yr_id -- wipe it and class allocation fails until it is
  -- put back by hand. Empty the array (ARRAY[]::text[]) for a truly total wipe.
  v_keep text[] := ARRAY['year'];

  -- This destroys receipts and payment history. It refuses to run while
  -- payments exist until you set this true, deliberately, having taken a backup.
  i_have_a_backup boolean := false;

  r        record;
  v_list   text;
  v_pay    bigint;
  v_before bigint := 0;
  v_adm    bigint;
  v_roll   bigint;
  n        bigint;
BEGIN
  -- ── guards ────────────────────────────────────────────────────────────────
  IF v_schema IS NULL OR v_schema = '' THEN
    RAISE EXCEPTION 'Set v_schema first';
  END IF;
  IF v_schema IN ('public','storage','auth','extensions','graphql','realtime','vault') THEN
    RAISE EXCEPTION 'Refusing to wipe %: that is not an institution schema', v_schema;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
    RAISE EXCEPTION 'Schema % does not exist', v_schema;
  END IF;
  -- A schema with no students table is not one of ours.
  IF NOT EXISTS (SELECT 1 FROM pg_tables
                  WHERE schemaname = v_schema AND tablename = 'students') THEN
    RAISE EXCEPTION 'Schema % has no students table -- wrong schema?', v_schema;
  END IF;

  EXECUTE format('SELECT count(*) FROM %I.payment', v_schema) INTO v_pay;
  IF v_pay > 0 AND NOT i_have_a_backup THEN
    RAISE EXCEPTION
      'Refusing: % payment row(s) in %. This deletes every receipt and its '
      'payment history. Take a backup, then set i_have_a_backup := true.',
      v_pay, v_schema;
  END IF;

  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = v_schema LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I', v_schema, r.tablename) INTO n;
    v_before := v_before + n;
  END LOOP;

  -- ── the schema ────────────────────────────────────────────────────────────
  SELECT string_agg(format('%I.%I', schemaname, tablename), ', ')
    INTO v_list
    FROM pg_tables
   WHERE schemaname = v_schema
     AND NOT (tablename = ANY(v_keep));

  IF v_list IS NULL THEN
    RAISE NOTICE 'No tables to clear in %', v_schema;
  ELSE
    -- RESTART IDENTITY resets the GENERATED ALWAYS AS IDENTITY columns.
    EXECUTE 'TRUNCATE TABLE ' || v_list || ' RESTART IDENTITY CASCADE';
  END IF;

  -- The standalone sequences the BEFORE-INSERT triggers call nextval() on are
  -- not owned by any column, so RESTART IDENTITY above does not touch them.
  -- Without this the next student picks up where the deleted ones left off.
  FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname = v_schema LOOP
    EXECUTE format('ALTER SEQUENCE %I.%I RESTART WITH 1', v_schema, r.sequencename);
  END LOOP;

  -- ── the shared public rows for this institution ───────────────────────────
  -- Scoped by ins_id: these tables hold every institution's rows.
  DELETE FROM public.rollno_change WHERE ins_id = v_ins;
  GET DIAGNOSTICS v_roll = ROW_COUNT;
  DELETE FROM public.admission WHERE ins_id = v_ins;
  GET DIAGNOSTICS v_adm = ROW_COUNT;

  RAISE NOTICE '--- cleared ---';
  RAISE NOTICE '  %-26s % rows across % table(s)', v_schema, v_before,
               (SELECT count(*) FROM pg_tables WHERE schemaname = v_schema);
  RAISE NOTICE '  %-26s %', 'public.admission', v_adm;
  RAISE NOTICE '  %-26s %', 'public.rollno_change', v_roll;
  IF array_length(v_keep, 1) IS NOT NULL THEN
    RAISE NOTICE '  kept: %', array_to_string(v_keep, ', ');
  END IF;
END
$wipe$;


-- ════════════════════════════════════════════════════════════════════════════
-- STEP 3 — confirm. Re-run STEP 1: everything should read zero except `year`.
-- ════════════════════════════════════════════════════════════════════════════
