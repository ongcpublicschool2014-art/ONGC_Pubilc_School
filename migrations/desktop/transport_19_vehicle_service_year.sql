-- transport_19_vehicle_service_year.sql
--
-- tr_vehicle_service gets acad_year_id: the academic year a service record
-- belongs to (public.institutionyear.iyr_id, the same value as
-- tr_student_enrollment.acad_year_id). The table stays in public with the
-- other vehicle masters; the column says which year each record is for.
--
-- Rows already there get the year of their school (inst_id) whose dates
-- cover the service date. If a row has no such year the run stops and
-- nothing is changed: correct that row's service date (or the school's
-- academic year dates), then run again.
--
-- Safe to run again.
BEGIN;

ALTER TABLE public.tr_vehicle_service
  ADD COLUMN IF NOT EXISTS acad_year_id INTEGER
    CONSTRAINT fk_service_year REFERENCES public.institutionyear(iyr_id);

DO $$
DECLARE n integer; ids text;
BEGIN
  UPDATE public.tr_vehicle_service v
     SET acad_year_id = (SELECT iy.iyr_id FROM public.institutionyear iy
                          WHERE iy.ins_id = v.inst_id
                            AND v.service_date BETWEEN iy.iyrstadate AND iy.iyrenddate
                          ORDER BY iy.iyrstadate DESC LIMIT 1)
   WHERE v.acad_year_id IS NULL;

  SELECT count(*) INTO n FROM public.tr_vehicle_service WHERE acad_year_id IS NULL;
  IF n > 0 THEN
    SELECT string_agg(service_id::text, ', ') INTO ids
      FROM (SELECT service_id FROM public.tr_vehicle_service
             WHERE acad_year_id IS NULL ORDER BY service_id LIMIT 20) x;
    RAISE EXCEPTION '% vehicle service record(s) have a service date outside every academic year of their school (service_id %). Correct the service date or the year dates, then run again; nothing was changed.', n, ids;
  END IF;
END $$;

ALTER TABLE public.tr_vehicle_service ALTER COLUMN acad_year_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS ix_service_year ON public.tr_vehicle_service (acad_year_id, vehicle_id);

COMMIT;
