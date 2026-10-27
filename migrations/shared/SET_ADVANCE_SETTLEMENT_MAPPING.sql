-- =====================================================================
-- Map each advance type to the fee group it settles into.
--
-- Advance Collection refuses to take money for a type that is not mapped,
-- because an unmapped advance has no fee group, so no receipt series and no
-- bank routing -- it would be collected into nowhere. The mapping is what
-- Utilities -> Advance Settlement sets; this is the same thing in SQL.
--
-- The fee groups on this institution are:
--     fg_id 1  COLLEGE FEES  -> IOB, receipt series FC26/
--     fg_id 2  HOSTEL FEES   -> IOB, receipt series HF26/
-- Both settle to the same bank, so the mapping decides the RECEIPT SERIES an
-- advance is numbered from, not where the money lands.
--
-- Types: A = Admission advance, S = Student advance, M = Mess advance.
--
-- Only A and S are set here. M is already mapped to 1 and is not blocked --
-- if Mess advances should be numbered in the HOSTEL series instead, change it
-- deliberately with the statement at the bottom rather than as a side effect
-- of this script.
--
-- Safe to re-run.
-- =====================================================================

INSERT INTO public.institution_settings (ins_id, setting_key, setting_value, updatedat, updatedby)
VALUES (1, 'advance_route_fg_A', '1', now(), 'ADMIN'),
       (1, 'advance_route_fg_S', '1', now(), 'ADMIN')
ON CONFLICT (ins_id, setting_key)
DO UPDATE SET setting_value = EXCLUDED.setting_value,
              updatedat     = EXCLUDED.updatedat,
              updatedby     = EXCLUDED.updatedby;

-- Verify: every type must show a fee group that actually exists and is active.
SELECT s.setting_key,
       CASE s.setting_key
         WHEN 'advance_route_fg_A' THEN 'Admission'
         WHEN 'advance_route_fg_S' THEN 'Student'
         WHEN 'advance_route_fg_M' THEN 'Mess' END AS advance_type,
       s.setting_value AS fg_id,
       COALESCE(g.fgdesc, '*** NOT MAPPED - collection blocked ***') AS fee_group,
       COALESCE(q.sequid, '-') AS receipt_series
  FROM public.institution_settings s
  LEFT JOIN kcet20262027.feegroup g
         ON g.fg_id = NULLIF(trim(s.setting_value), '')::int
        AND g.ins_id = s.ins_id AND g.activestatus = 1
  LEFT JOIN kcet20262027.sequence q
         ON q.fg_id = g.fg_id AND q.ins_id = g.ins_id
 WHERE s.ins_id = 1 AND s.setting_key LIKE 'advance_route_fg_%'
 ORDER BY s.setting_key;

-- Mess advances into the HOSTEL series instead -- run ONLY if that is intended:
-- UPDATE public.institution_settings SET setting_value = '2', updatedat = now()
--  WHERE ins_id = 1 AND setting_key = 'advance_route_fg_M';
