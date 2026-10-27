-- EMIS / UMIS numbers on the admission record.
--
--   EMIS — Educational Management Information System number, carried from the
--          student's school record.
--   UMIS — University Management Information System number, issued once the
--          student is enrolled with the affiliating university.
--
-- Both are government identifiers entered per student, alongside Aadhar. They
-- are nullable and unconstrained on purpose: a student may arrive with one,
-- both or neither, and a UMIS number often only exists after enrolment.
--
-- Added to public.admission AND to every tenant schema's students table, so
-- the value survives class allocation (which copies demographic columns across)
-- and is available to reports and the TC.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS throughout, safe to re-run.

ALTER TABLE public.admission
  ADD COLUMN IF NOT EXISTS emisno varchar(30),
  ADD COLUMN IF NOT EXISTS umisno varchar(30);

-- Every institution schema that already exists.
DO $emis$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT nspname FROM pg_namespace n
     WHERE EXISTS (SELECT 1 FROM pg_class c
                    WHERE c.relnamespace = n.oid AND c.relname = 'students')
       AND nspname NOT IN ('public','information_schema')
       AND nspname NOT LIKE 'pg\_%'
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS emisno varchar(30)', r.nspname);
    EXECUTE format(
      'ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS umisno varchar(30)', r.nspname);
    RAISE NOTICE 'added emisno/umisno to %.students', r.nspname;
  END LOOP;
END
$emis$;

-- Verify.
SELECT table_schema, column_name
  FROM information_schema.columns
 WHERE column_name IN ('emisno','umisno')
 ORDER BY table_schema, column_name;
