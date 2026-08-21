-- SEED (data, not schema): per-institution Paytm MID routing. A DB wipe/rebuild
-- recreates the paytm_configuration TABLE but loses its ROWS — without these,
-- every unit's online payment falls back to the DEFAULT MID
-- (Krishn06051431858637) and settles into the parent account instead of each
-- unit's own bank.
--
-- Run AFTER the institutions exist (ins_id 1..4 = College/Polytechnic/Arts&
-- Science/Mens Hostel). Idempotent: only inserts a row for a unit that has no
-- active config yet. If a future rebuild assigns different ins_ids, update the
-- institution_id values to match public.institution.

INSERT INTO public.paytm_configuration (institution_id, merchant_id)
SELECT v.institution_id, v.merchant_id
FROM (VALUES
  (1, 'Krishn36335928406501'),   -- KCET (College)
  (2, 'Krishn15569334364496'),   -- Polytechnic
  (3, 'Krishn02645517368198'),   -- Arts & Science
  (4, 'Krishn33556941260773')    -- Mens Hostel
) AS v(institution_id, merchant_id)
WHERE NOT EXISTS (
  SELECT 1 FROM public.paytm_configuration p
  WHERE p.institution_id = v.institution_id AND p.is_active = true
);
