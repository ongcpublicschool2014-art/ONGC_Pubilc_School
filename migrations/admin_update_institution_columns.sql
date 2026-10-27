-- admin_update_institution: widen the column whitelist.
--
-- The function patches public.institution from a jsonb of allowed columns, and
-- six were missing: insaddress1/2/3, it_id, insrecognised and insaffstayear.
-- The Edit Institution screen could show and change them, the client sent
-- them, and the UPDATE quietly ignored them -- which is why Institution Type
-- and the address lines "were not editable".
--
-- insaddress1 is NOT NULL on the table, so it uses NULLIF to refuse a blank;
-- the optional address lines accept a blank so they can be cleared.
--
-- Idempotent: plain CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION public.admin_update_institution(p_ins_id integer, p_patch jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  UPDATE public.institution SET
    insname        = COALESCE(NULLIF(p_patch->>'insname',''), insname),
    inshortname    = COALESCE(p_patch->>'inshortname', inshortname),
    inscode        = COALESCE(NULLIF(p_patch->>'inscode',''), inscode),
    insautusername = COALESCE(NULLIF(p_patch->>'insautusername',''), insautusername),
    insdesignation = COALESCE(p_patch->>'insdesignation', insdesignation),
    insmobno       = COALESCE(NULLIF(p_patch->>'insmobno',''), insmobno),
    insmail        = COALESCE(p_patch->>'insmail', insmail),
    insaffliation  = COALESCE(p_patch->>'insaffliation', insaffliation),
    insaffno       = COALESCE(p_patch->>'insaffno', insaffno),
    inscity        = COALESCE(p_patch->>'inscity', inscity),
    insstate       = COALESCE(p_patch->>'insstate', insstate),
    inscountry     = COALESCE(p_patch->>'inscountry', inscountry),
    inspincode     = COALESCE(NULLIF(p_patch->>'inspincode',''), inspincode),
    -- Address, type, recognition and affiliation year were missing from this
    -- whitelist, so the Edit Institution screen could change them on screen and
    -- the update silently dropped them. insaddress1 is NOT NULL, so NULLIF
    -- guards it; the optional lines accept a blank to clear them.
    insaddress1    = COALESCE(NULLIF(p_patch->>'insaddress1',''), insaddress1),
    insaddress2    = COALESCE(p_patch->>'insaddress2', insaddress2),
    insaddress3    = COALESCE(p_patch->>'insaddress3', insaddress3),
    it_id          = COALESCE((p_patch->>'it_id')::integer, it_id),
    insrecognised  = COALESCE(NULLIF(p_patch->>'insrecognised',''), insrecognised),
    insaffstayear  = COALESCE(p_patch->>'insaffstayear', insaffstayear),
    activestatus   = COALESCE((p_patch->>'activestatus')::smallint, activestatus),
    updatedby      = COALESCE(NULLIF(p_patch->>'updatedby',''), updatedby),
    updateddate    = CURRENT_DATE
  WHERE ins_id = p_ins_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_update_institution(integer, jsonb) TO anon, authenticated;
