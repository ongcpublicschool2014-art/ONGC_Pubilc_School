-- =====================================================================
--  SCHOOL TRANSPORT - tr_staff driving licence details
--
--  Adds licence number, type and validity to tr_staff (all optional).
--  photo_url is listed too; it already exists (text, nullable), so
--  IF NOT EXISTS leaves it untouched.
--
--  Safe to run again.
-- =====================================================================

BEGIN;

ALTER TABLE public.tr_staff
  ADD COLUMN IF NOT EXISTS license_number     VARCHAR(50) NULL,
  ADD COLUMN IF NOT EXISTS license_type       VARCHAR(30) NULL,
  ADD COLUMN IF NOT EXISTS license_valid_till DATE        NULL,
  ADD COLUMN IF NOT EXISTS photo_url          TEXT        NULL;

COMMIT;
