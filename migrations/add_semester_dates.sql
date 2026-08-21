-- ============================================================================
-- Add start/end dates to the semester master — per institution schema.
-- ============================================================================
-- Lets each semester/term carry a start and end date (shown + editable in
-- Fee Master → Semester). Nullable; idempotent (safe to re-run).
-- ============================================================================

DO $$
DECLARE
  r record;
  sname text;
BEGIN
  FOR r IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL
  LOOP
    sname := r.schema_name;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sname)
       AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = sname AND table_name = 'semester') THEN
      EXECUTE format('ALTER TABLE %I.semester ADD COLUMN IF NOT EXISTS semstart date', sname);
      EXECUTE format('ALTER TABLE %I.semester ADD COLUMN IF NOT EXISTS semend date', sname);
      RAISE NOTICE 'Added semester.semstart/semend in %', sname;
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload config';
