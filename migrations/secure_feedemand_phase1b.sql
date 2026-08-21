-- ============================================================================
-- Phase 1b — session-gated RPCs for feedemand mutations (Group A, money-adjacent).
-- ============================================================================
-- Today the client updates <schema>.feedemand directly (fines, concessions,
-- fee-definition edits) using the anon key — anyone can rewrite balances. These
-- RPCs require a valid session token, derive ins_id SERVER-SIDE from it, and
-- scope every UPDATE to that institution (dem_id AND ins_id). The client rewires
-- to them with a fallback (non-breaking). Requires secure_app_session.sql.
-- Idempotent.
-- ============================================================================

-- Set/clear the fine on one demand (fee-collection flow).
CREATE OR REPLACE FUNCTION public.set_demand_fine(
  p_token text, p_dem_id bigint, p_fineamount numeric
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  EXECUTE format('UPDATE %I.feedemand SET fineamount = $1 WHERE dem_id = $2 AND ins_id = $3', v_schema)
    USING COALESCE(p_fineamount, 0), p_dem_id, v_ins;
END; $$;

-- Apply a concession to one demand (Fee Concession screen).
CREATE OR REPLACE FUNCTION public.apply_concession(
  p_token text, p_dem_id bigint, p_con_id integer, p_conamount numeric, p_balancedue numeric
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  EXECUTE format(
    'UPDATE %I.feedemand SET con_id = $1, conamount = $2, balancedue = $3, reconbalancedue = $3 '
    'WHERE dem_id = $4 AND ins_id = $5', v_schema)
    USING p_con_id, p_conamount, p_balancedue, p_dem_id, v_ins;
END; $$;

-- Save a per-student fee definition (Student Fee Definition dialog). p_balancedue
-- NULL = amount unchanged → do NOT touch the outstanding (preserve payments).
CREATE OR REPLACE FUNCTION public.save_fee_definition(
  p_token text, p_dem_id bigint, p_feeamount numeric, p_collectible boolean,
  p_balancedue numeric DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  IF p_balancedue IS NULL THEN
    EXECUTE format('UPDATE %I.feedemand SET feeamount = $1, collectible = $2 '
                   'WHERE dem_id = $3 AND ins_id = $4', v_schema)
      USING p_feeamount, p_collectible, p_dem_id, v_ins;
  ELSE
    EXECUTE format('UPDATE %I.feedemand SET feeamount = $1, collectible = $2, '
                   'balancedue = $3, reconbalancedue = $3 WHERE dem_id = $4 AND ins_id = $5', v_schema)
      USING p_feeamount, p_collectible, p_balancedue, p_dem_id, v_ins;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.set_demand_fine(text, bigint, numeric) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_concession(text, bigint, integer, numeric, numeric) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_fee_definition(text, bigint, numeric, boolean, numeric) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
