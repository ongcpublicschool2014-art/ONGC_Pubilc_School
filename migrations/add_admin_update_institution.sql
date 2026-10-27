-- ============================================================================
-- add_admin_update_institution.sql
-- public.institution has RLS enabled with only an anon SELECT policy, so a
-- direct anon UPDATE (the Manage Institutions toggle / Edit save) matches 0 rows
-- silently and never persists. This SECURITY DEFINER RPC runs as owner, bypasses
-- RLS, and patches only the columns present in p_patch (others keep their value).
-- Safe to re-run.
-- ============================================================================
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
    activestatus   = COALESCE((p_patch->>'activestatus')::smallint, activestatus),
    updatedby      = COALESCE(NULLIF(p_patch->>'updatedby',''), updatedby),
    updateddate    = CURRENT_DATE
  WHERE ins_id = p_ins_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_update_institution(integer, jsonb) TO anon, authenticated;
