-- New Roll Number (Admission → New Roll Number).
-- 1) public.rollno_change log table (+ same-date unique, RLS, grants). It lives
--    in public, alongside public.admission, because a renumber spans both sides:
--    the shared admission row and the tenant's students row move together.
-- 2) Drops any earlier PER-SCHEMA rollno_change (superseded by the public one).
-- 3) save_rollno_change RPC: renumbers a student by replacing stuadmno on
--    students and CASCADING the new number to every table keyed by stuadmno
--    (feedemand, tempfeedemand, concession, concessiondetail, fee_refund,
--    parentdetail, tc_entry, interim_promotion) plus public.admission.admno —
--    all in ONE transaction — then logs the change.
-- DB-only; safe to re-run.

CREATE TABLE IF NOT EXISTS public.rollno_change (
  rc_id        bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ins_id       integer     NOT NULL,
  inscode      varchar(10),
  stu_id       bigint,
  oldrollno    varchar(25) NOT NULL,
  newrollno    varchar(25) NOT NULL,
  stuname      varchar(50),
  stuclass     varchar(20),
  cla_id       smallint,
  effectdate   date        NOT NULL,
  createdby    varchar(50),
  createdon    timestamp   DEFAULT now() NOT NULL,
  activestatus smallint    DEFAULT 1 NOT NULL
);
-- An earlier cut of this file carried the academic year; a renumber isn't
-- year-scoped (effectdate carries the timing), so drop them if already created.
ALTER TABLE public.rollno_change
  DROP COLUMN IF EXISTS yr_id,
  DROP COLUMN IF EXISTS yrlabel;
-- VB rule: a student's roll number may not be updated twice on one date.
CREATE UNIQUE INDEX IF NOT EXISTS uq_rollno_change_day
  ON public.rollno_change (ins_id, stu_id, effectdate);
CREATE INDEX IF NOT EXISTS idx_rollno_change_ins
  ON public.rollno_change (ins_id, effectdate DESC);
ALTER TABLE public.rollno_change ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow all" ON public.rollno_change;
CREATE POLICY "Allow all" ON public.rollno_change USING (true) WITH CHECK (true);
GRANT ALL ON public.rollno_change TO anon, authenticated;

-- Retire the per-schema copy created by the first cut of this migration. It has
-- no rows in any live DB (the screen has never been shipped), so this is a plain
-- drop; the trigger fn and its sequence go with it.
DO $$
DECLARE r RECORD; v_schema text;
BEGIN
  FOR r IN SELECT DISTINCT ins_id FROM public.admission WHERE ins_id IS NOT NULL LOOP
    v_schema := public.get_institution_schema(r.ins_id);
    IF v_schema IS NULL THEN CONTINUE; END IF;
    BEGIN
      EXECUTE format('DROP TABLE IF EXISTS %I.rollno_change', v_schema);
      EXECUTE format('DROP FUNCTION IF EXISTS %I.set_rc_id()', v_schema);
      EXECUTE format('DROP SEQUENCE IF EXISTS %I.rollno_change_rc_id_seq', v_schema);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'rollno_change drop skip schema %: %', v_schema, SQLERRM;
    END;
  END LOOP;
END $$;

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
    -- ...including a pending admission not yet allocated, which would otherwise
    -- break the admission UNIQUE(ins_id, admno) mid-cascade.
    SELECT EXISTS(SELECT 1 FROM public.admission WHERE ins_id = v_ins AND admno = v_new)
      INTO v_exists;
    IF v_exists THEN RAISE EXCEPTION 'Roll number % is already used by an admission record', v_new; END IF;

    -- one renumber per student per effect date
    SELECT EXISTS(SELECT 1 FROM public.rollno_change
                   WHERE ins_id = v_ins AND stu_id = v_stuid AND effectdate = p_effectdate)
      INTO v_exists;
    IF v_exists THEN
      RAISE EXCEPTION 'Roll number % was already updated on %', v_old, p_effectdate;
    END IF;

    EXECUTE format('UPDATE %I.students SET stuadmno=$1 WHERE ins_id=$2 AND stuadmno=$3', v_schema)
      USING v_new, v_ins, v_old;
    FOREACH v_tbl IN ARRAY ARRAY['feedemand','tempfeedemand','concession','concessiondetail',
                                 'fee_refund','parentdetail','tc_entry','interim_promotion'] LOOP
      BEGIN
        EXECUTE format('UPDATE %I.%I SET stuadmno=$1 WHERE ins_id=$2 AND stuadmno=$3', v_schema, v_tbl)
          USING v_new, v_ins, v_old;
      EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
      END;
    END LOOP;
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
