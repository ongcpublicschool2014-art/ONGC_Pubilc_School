-- ============================================================================
-- Widen transportmode to varchar(20).
-- ============================================================================
-- The student import now stores the Transport Mode meaning rather than the raw
-- flag: N = 'OWN', Y = 'INSTITUTION'. 'INSTITUTION' is 11 chars, so the old
-- varchar(10) is too small. Widen students.transportmode + student_import
-- .transportmode in every schema. Idempotent. Run in the Supabase SQL editor.
-- ============================================================================

DO $$
DECLARE r record; sname text;
BEGIN
  FOR r IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL
  LOOP
    sname := r.schema_name;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sname) THEN
      IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = sname AND table_name = 'students') THEN
        EXECUTE format('ALTER TABLE %I.students ALTER COLUMN transportmode TYPE varchar(20)', sname);
      END IF;
      IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = sname AND table_name = 'student_import') THEN
        EXECUTE format('ALTER TABLE %I.student_import ALTER COLUMN transportmode TYPE varchar(20)', sname);
      END IF;
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
