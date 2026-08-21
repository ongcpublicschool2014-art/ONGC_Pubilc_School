-- Per-institution key/value settings (Setup -> Utilities).
-- Keyed by (ins_id, setting_key); one row per configurable toggle. Public table
-- (settings are per-institution, not per-year), same access model as
-- public.admission. Idempotent.
--
-- Keys used today:
--   admission_number_mode      = 'AUTO' | 'MANUAL'  (default MANUAL)
--   fee_collection_arrear_first= 'true' | 'false'   (default true)

CREATE TABLE IF NOT EXISTS public.institution_settings (
  ins_id        integer      NOT NULL,
  setting_key   varchar(50)  NOT NULL,
  setting_value text,
  updatedat     timestamp    DEFAULT now() NOT NULL,
  updatedby     varchar(50),
  PRIMARY KEY (ins_id, setting_key)
);

ALTER TABLE public.institution_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow all" ON public.institution_settings;
CREATE POLICY "Allow all" ON public.institution_settings USING (true) WITH CHECK (true);
GRANT ALL ON public.institution_settings TO anon, authenticated;
