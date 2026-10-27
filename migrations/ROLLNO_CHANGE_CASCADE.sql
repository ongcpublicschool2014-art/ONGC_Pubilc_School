-- ############################################################################
-- EduCore360 -- ROLL-NUMBER CHANGE MUST REACH ADVANCES AND MISC RECEIPTS
-- 19-09-2026
--
-- public.save_rollno_change renames the student and then cascades the new
-- number to every table that stores it. Two were missing:
--
--   * <schema>.advance_collection.stuadmno
--   * <schema>.misc_collection.regno      (same number, different column name,
--                                          so it could not ride the loop)
--
-- A roll number is an IDENTITY, not a historical attribute. Once it changes
-- the old one names nobody, so a row left behind under it cannot be found --
-- and in the case of an advance, money is still sitting on it.
--
-- Every tenant table that carries a roll number was checked; after this the
-- list is complete:
--     students, feedemand, tempfeedemand, concession, concessiondetail,
--     fee_refund, parentdetail, tc_entry, interim_promotion,
--     advance_collection, misc_collection, public.admission.
--   * student_import is deliberately left out -- it is the raw import staging
--     table, not a record of the student.
--   * payment, paymentdetails and advadjustment key on stu_id and hold no roll
--     number, so nothing on them can go stale.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE, one function, no data change of its own.
-- Applied and checked on the TEST project first.
-- ############################################################################


-- ############################################################################
-- BEFORE (READ-ONLY) -- rows whose roll number no longer matches the student's.
-- These are the ones already stranded by earlier roll-number changes.
-- ############################################################################
DO $before$
DECLARE r RECORD; n_adv int; n_misc int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'students'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    n_adv := 0; n_misc := 0;
    BEGIN
      EXECUTE format($q$
        SELECT count(*) FROM %I.advance_collection a
          JOIN %I.students s ON s.stu_id = a.stu_id
         WHERE a.stuadmno IS DISTINCT FROM s.stuadmno $q$, r.s, r.s) INTO n_adv;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
    BEGIN
      EXECUTE format($q$
        SELECT count(*) FROM %I.misc_collection m
          JOIN %I.students s ON s.stu_id = m.stu_id
         WHERE m.regno IS DISTINCT FROM s.stuadmno $q$, r.s, r.s) INTO n_misc;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
    RAISE NOTICE '%: % advance row(s), % misc receipt(s) under an old roll number',
                 r.s, n_adv, n_misc;
  END LOOP;
END $before$;


-- ############################################################################
-- THE FUNCTION
-- ############################################################################
CREATE OR REPLACE FUNCTION public.save_rollno_change(
  p_token text, p_effectdate date, p_rows jsonb, p_createdby text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_inscode varchar(10);
  itm RECORD; v_count int := 0; v_exists boolean; v_tbl text;
  v_stuid bigint; v_stuname text; v_stuclass text; v_claid smallint;
  v_old text; v_new text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;

  FOR itm IN SELECT * FROM jsonb_to_recordset(p_rows) AS x(oldrollno text, newrollno text)
  LOOP
    v_old := TRIM(COALESCE(itm.oldrollno, ''));
    v_new := TRIM(COALESCE(itm.newrollno, ''));
    CONTINUE WHEN v_new = '' OR v_old = '' OR v_new = v_old;

    EXECUTE format('SELECT stu_id, stuname, stuclass, cla_id FROM %I.students WHERE ins_id=$1 AND stuadmno=$2 LIMIT 1', v_schema)
      INTO v_stuid, v_stuname, v_stuclass, v_claid USING v_ins, v_old;
    IF v_stuid IS NULL THEN CONTINUE; END IF;

    -- the new number must be free (students + admission both have UNIQUE on it)
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.students WHERE ins_id=$1 AND stuadmno=$2 AND stu_id<>$3)', v_schema)
      INTO v_exists USING v_ins, v_new, v_stuid;
    IF v_exists THEN RAISE EXCEPTION 'Roll number % is already in use by another student', v_new; END IF;
    -- ...including a pending admission that has not been allocated yet, which
    -- would otherwise break the admission UNIQUE(ins_id, admno) mid-cascade.
    SELECT EXISTS(SELECT 1 FROM public.admission WHERE ins_id = v_ins AND admno = v_new)
      INTO v_exists;
    IF v_exists THEN RAISE EXCEPTION 'Roll number % is already used by an admission record', v_new; END IF;

    -- No once-per-day limit: correcting a number the same day is normal, and
    -- every step is logged below, so the trail stays complete. The checks that
    -- matter -- that the new number is not already taken by another student or
    -- a pending admission -- are above and still enforced.

    -- master row
    EXECUTE format('UPDATE %I.students SET stuadmno=$1 WHERE ins_id=$2 AND stuadmno=$3', v_schema)
      USING v_new, v_ins, v_old;
    -- every table keyed by stuadmno (skipped if a legacy schema lacks one)
    --
    -- advance_collection was missing from this list. A roll number is an
    -- IDENTITY, not a historical attribute: once it changes, the old one names
    -- nobody, and an advance left under it cannot be found by the screens --
    -- which look the student up by roll number -- while money is still on it.
    FOREACH v_tbl IN ARRAY ARRAY['feedemand','tempfeedemand','concession','concessiondetail',
                                 'fee_refund','parentdetail','tc_entry','interim_promotion',
                                 'advance_collection'] LOOP
      BEGIN
        EXECUTE format('UPDATE %I.%I SET stuadmno=$1 WHERE ins_id=$2 AND stuadmno=$3', v_schema, v_tbl)
          USING v_new, v_ins, v_old;
      EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
      END;
    END LOOP;
    -- misc_collection holds the same number under a different name (regno), so
    -- it cannot ride the loop above.
    BEGIN
      EXECUTE format('UPDATE %I.misc_collection SET regno=$1 WHERE ins_id=$2 AND regno=$3', v_schema)
        USING v_new, v_ins, v_old;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
    -- the shared admission row links by admno = stuadmno
    UPDATE public.admission SET admno = v_new WHERE ins_id = v_ins AND admno = v_old;

    INSERT INTO public.rollno_change(ins_id, inscode, stu_id, oldrollno, newrollno,
                                     stuname, stuclass, cla_id, effectdate, createdby)
    VALUES (v_ins, v_inscode, v_stuid, v_old, v_new,
            v_stuname, v_stuclass, v_claid, p_effectdate, p_createdby);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END; $$;

GRANT EXECUTE ON FUNCTION public.save_rollno_change(text, date, jsonb, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- FIX THE ROWS ALREADY STRANDED -- roll-number changes made before this update
-- left these behind. Matched by stu_id, which never changes.
-- It changes DATA, so read the BEFORE output first and run this only if the
-- counts it printed are what you expect.
-- ############################################################################
DO $fix$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'students'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    BEGIN
      EXECUTE format($q$
        UPDATE %I.advance_collection a SET stuadmno = s.stuadmno
          FROM %I.students s
         WHERE s.stu_id = a.stu_id AND a.stuadmno IS DISTINCT FROM s.stuadmno $q$,
        r.s, r.s);
      GET DIAGNOSTICS n = ROW_COUNT;
      RAISE NOTICE '%: % advance row(s) renumbered', r.s, n;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
    BEGIN
      EXECUTE format($q$
        UPDATE %I.misc_collection m SET regno = s.stuadmno
          FROM %I.students s
         WHERE s.stu_id = m.stu_id AND m.regno IS DISTINCT FROM s.stuadmno $q$,
        r.s, r.s);
      GET DIAGNOSTICS n = ROW_COUNT;
      RAISE NOTICE '%: % misc receipt(s) renumbered', r.s, n;
    EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
    END;
  END LOOP;
END $fix$;


-- ############################################################################
-- VERIFY -- both flags must read t, and the counts above must be 0.
-- ############################################################################
SELECT p.prosrc LIKE '%advance_collection%' AS cascades_to_advances,
       p.prosrc LIKE '%misc_collection SET regno%' AS cascades_to_misc
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_rollno_change';
