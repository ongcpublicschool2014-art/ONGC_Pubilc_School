-- ============================================================================
-- Division master — per institution schema (Admission Master → Division).
-- ============================================================================
-- A small smallint-PK lookup, same shape as community / admissiontype: managed
-- from the Admission Master screen via MasterCrudPanel. Safe / idempotent.
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
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sname) THEN
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I.division ('
        'div_id smallint PRIMARY KEY, divname varchar(40) NOT NULL, ins_id integer, '
        'activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))',
        sname);
      EXECUTE format('GRANT ALL ON %I.division TO anon, authenticated', sname);
      RAISE NOTICE 'Created division master in %', sname;
    END IF;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload config';
