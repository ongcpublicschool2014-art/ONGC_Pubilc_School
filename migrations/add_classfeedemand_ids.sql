-- ============================================================================
-- Store class / semester / fee-type IDs on classfeedemand (alongside names).
-- ============================================================================
-- classfeedemand keeps class/term/feetype as names + admissiontype (adm_id).
-- The Class Fee Demand import template also carries Class Id / Semester Id /
-- Fee Id, so this adds matching columns and the import writes them:
--   classfeedemand : cla_id smallint, sem_id smallint, fee_id integer
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
       AND EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = sname AND table_name = 'classfeedemand') THEN
      EXECUTE format('ALTER TABLE %I.classfeedemand '
        'ADD COLUMN IF NOT EXISTS cla_id smallint, '
        'ADD COLUMN IF NOT EXISTS sem_id smallint, '
        'ADD COLUMN IF NOT EXISTS fee_id integer', sname);
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
