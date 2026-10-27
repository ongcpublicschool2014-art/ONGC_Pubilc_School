-- admit_cour_id (the originally-admitted course) was left NULL on admissions
-- created by paths that didn't supply it (older builds / imports without the
-- column), even though cour_id was set. This adds a BEFORE INSERT default so
-- every future admission gets admit_cour_id = cour_id when not supplied, and
-- backfills existing rows. DB-only; safe to re-run.
--
-- Note: a course TRANSFER changes cour_id but deliberately leaves admit_cour_id
-- unchanged (the admitted course is fixed at admission), so this default is
-- INSERT-only and never disturbs transferred records.

CREATE OR REPLACE FUNCTION public.admission_default_admit_cour()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.admit_cour_id IS NULL AND NEW.cour_id IS NOT NULL THEN
    NEW.admit_cour_id := NEW.cour_id::smallint;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_admission_default_admit_cour ON public.admission;
CREATE TRIGGER trg_admission_default_admit_cour
  BEFORE INSERT ON public.admission
  FOR EACH ROW EXECUTE FUNCTION public.admission_default_admit_cour();

-- One-time backfill of existing rows: set the admitted course to the enrolled
-- course wherever it's missing.
UPDATE public.admission
   SET admit_cour_id = cour_id::smallint
 WHERE admit_cour_id IS NULL
   AND cour_id IS NOT NULL;
