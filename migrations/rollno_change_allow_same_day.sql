-- ============================================================================
-- New Roll Number: allow more than one renumber per student per day.
--
-- A student's register number could only be changed once per effect date. The
-- rule came across from the VB system and was enforced twice over:
--
--   1. UNIQUE INDEX uq_rollno_change_day (ins_id, stu_id, effectdate)
--   2. an explicit check in save_rollno_change that raised
--      'Roll number % was already updated on %'
--
-- Both are removed here. Removing only the check would swap a clear message for
-- a raw 23505 unique-violation, so they have to go together.
--
-- What still protects the data (unchanged, in save_rollno_change):
--   * the new number must not belong to another student in this institution
--   * nor to an admission record that has not been allocated yet
--   * the whole renumber runs in one transaction and cascades to students,
--     every per-schema table keyed by stuadmno, and public.admission
--
-- Every renumber is still logged as its own rollno_change row, so a number
-- corrected twice in a day reads as two entries rather than a silent overwrite.
--
-- Idempotent: DROP INDEX IF EXISTS + CREATE INDEX IF NOT EXISTS + CREATE OR
-- REPLACE.
-- ============================================================================

DROP INDEX IF EXISTS public.uq_rollno_change_day;

-- Same columns, without the uniqueness: the lookups it served are still worth
-- indexing.
CREATE INDEX IF NOT EXISTS idx_rollno_change_student
  ON public.rollno_change (ins_id, stu_id, effectdate);

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
    FOREACH v_tbl IN ARRAY ARRAY['feedemand','tempfeedemand','concession','concessiondetail',
                                 'fee_refund','parentdetail','tc_entry','interim_promotion'] LOOP
      BEGIN
        EXECUTE format('UPDATE %I.%I SET stuadmno=$1 WHERE ins_id=$2 AND stuadmno=$3', v_schema, v_tbl)
          USING v_new, v_ins, v_old;
      EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
      END;
    END LOOP;
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

-- Verify: the unique index should be gone, the plain one present.
SELECT indexname, indexdef
  FROM pg_indexes
 WHERE schemaname = 'public' AND tablename = 'rollno_change'
 ORDER BY indexname;
