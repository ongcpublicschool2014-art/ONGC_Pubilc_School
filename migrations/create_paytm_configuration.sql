-- ============================================================================
-- public.paytm_configuration — per-institution Paytm Sub-MID routing.
-- ============================================================================
-- Maps each institution (public.institution.ins_id) to the Paytm SUB Merchant
-- ID its online payments transact under — and therefore the bank account Paytm
-- settles them to. Account model for this trust:
--   * ONE parent production merchant + ONE parent Merchant KEY (secret)
--   * FOUR sub MIDs (one per institution), with NO separate keys
--   * every request signs with the PARENT key + the selected SUB MID
--
-- SECURITY: the Merchant KEY is NEVER stored here (or anywhere in the DB or the
-- client). It lives only as the edge-function env var PAYTM_MERCHANT_KEY. This
-- table holds ONLY non-secret routing config. Idempotent.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.paytm_configuration (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  institution_id integer NOT NULL
                 REFERENCES public.institution(ins_id) ON DELETE CASCADE,
  merchant_id    varchar(40) NOT NULL,             -- Paytm SUB MID (non-secret)
  website        varchar(40) NOT NULL DEFAULT 'DEFAULT',
  industry_type  varchar(40) NOT NULL DEFAULT 'Retail109',
  channel_id     varchar(10) NOT NULL DEFAULT 'WEB',
  is_active      boolean     NOT NULL DEFAULT true,
  created_date   timestamptz NOT NULL DEFAULT now(),
  modified_date  timestamptz NOT NULL DEFAULT now()
);

-- At most ONE active config per institution (the row used for routing).
CREATE UNIQUE INDEX IF NOT EXISTS ux_paytm_config_active_institution
  ON public.paytm_configuration(institution_id) WHERE is_active;

-- Keep modified_date fresh on every update.
CREATE OR REPLACE FUNCTION public.touch_paytm_configuration()
RETURNS trigger AS $$
BEGIN
  NEW.modified_date := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_touch_paytm_configuration ON public.paytm_configuration;
CREATE TRIGGER trg_touch_paytm_configuration
  BEFORE UPDATE ON public.paytm_configuration
  FOR EACH ROW EXECUTE FUNCTION public.touch_paytm_configuration();

-- Non-secret routing data: allow authenticated clients to read it. Writes are
-- done by admins via the app / SQL only.
ALTER TABLE public.paytm_configuration ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS paytm_config_read ON public.paytm_configuration;
CREATE POLICY paytm_config_read ON public.paytm_configuration
  FOR SELECT TO authenticated, anon USING (true);

-- ---------------------------------------------------------------------------
-- SEED (fill in each ins_id, then activate). Look up ins_id first:
--     SELECT ins_id, insname FROM public.institution ORDER BY ins_id;
--
-- ⚠️ Keep is_active = false for the sub MIDs until Paytm confirms EITHER
--    (a) the parent key may transact for the sub MID and settle to its bank
--        (aggregator / linked-MID model), OR
--    (b) split settlement is enabled.
--    Activating a sub MID before then makes that institution's live payments
--    fail. Until active, routing falls back to the default parent MID.
-- ---------------------------------------------------------------------------
-- INSERT INTO public.paytm_configuration (institution_id, merchant_id, is_active) VALUES
--   (<eng ins_id>,    'Krishn36335928406501', false),   -- Engineering
--   (<hostel ins_id>, 'Krishn33556941260773', false),   -- Mens Hostel
--   (<arts ins_id>,   'Krishn02645517368198', false),   -- Arts & Science
--   (<poly ins_id>,   'Krishn15569334364496', false);   -- Polytechnic

NOTIFY pgrst, 'reload config';
NOTIFY pgrst, 'reload schema';
