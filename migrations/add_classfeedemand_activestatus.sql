-- ============================================================================
-- Add `activestatus` to the classfeedemand table.
-- ============================================================================
-- classfeedemand (the per-class fee-demand template) had no activestatus
-- column. This adds it (DEFAULT 1 = active) to every institution schema so
-- rows can be flagged active/inactive like the other master tables. Existing
-- rows become active. Idempotent / safe to re-run.
-- Run in the Supabase SQL editor.
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
       AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = sname AND table_name = 'classfeedemand') THEN
      EXECUTE format('ALTER TABLE %I.classfeedemand ADD COLUMN IF NOT EXISTS activestatus smallint DEFAULT 1 NOT NULL', sname);
      RAISE NOTICE 'Added activestatus to %.classfeedemand', sname;
    END IF;
  END LOOP;
END $$;

-- New column → refresh the PostgREST schema cache so the app can query it.
NOTIFY pgrst, 'reload schema';
