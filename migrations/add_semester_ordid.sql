-- ============================================================================
-- Add an explicit display-order column to the semester master.
-- ============================================================================
-- The semester master had no order column (it was implicitly ordered by
-- sem_id). The new Semester import (Master Import → Semester) carries a
-- "Semester Order" column; this adds `ordid smallint` to every schema's
-- `semester` table to hold it. Lists fall back to sem_id when ordid is NULL.
-- Idempotent. Run in the Supabase SQL editor.
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
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sname)
       AND EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = sname AND table_name = 'semester') THEN
      EXECUTE format('ALTER TABLE %I.semester ADD COLUMN IF NOT EXISTS ordid smallint', sname);
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
