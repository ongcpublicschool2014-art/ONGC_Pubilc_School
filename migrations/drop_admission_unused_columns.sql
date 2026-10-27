-- Drop unused columns from public.admission: stu_id, yr_id, yrlabel.
--   * yr_id / yrlabel — the academic year is resolved from the target schema at
--     allocation; admission never stores it.
--   * stu_id — allocated admissions link to the schema student by
--     admno = stuadmno (unique per institution), not by a stored stu_id
--     (it was always NULL on the live table).
--
-- Safe from the app side: admissions load with select('*') and _formData never
-- sends these columns; AdmissionModel defaults any missing key, so no app
-- rebuild is needed.
--
-- IMPORTANT: this is IRREVERSIBLE. Take a snapshot first, e.g.
--   CREATE TABLE public.admission_bak AS SELECT * FROM public.admission;
--
-- NOTE on the RPC: the ONLY function that referenced admission.stu_id was
-- transfer_course_with_credit's admission-sync step. course_transfer_update_admission.sql
-- has been updated to match by admno only (no stu_id) — run that CURRENT version
-- if you deploy it. The student-import mirror already omits these columns.

ALTER TABLE public.admission
  DROP COLUMN IF EXISTS stu_id,
  DROP COLUMN IF EXISTS yr_id,
  DROP COLUMN IF EXISTS yrlabel;
