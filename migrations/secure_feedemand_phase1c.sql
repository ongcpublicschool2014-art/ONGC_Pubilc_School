-- ============================================================================
-- Phase 1c — the last two non-payment feedemand client writes (Group A).
-- ============================================================================
-- After these, every CLIENT-side write to feedemand goes through a session-gated
-- RPC (set_demand_fine / apply_concession / save_fee_definition / process_refund
-- / reconcile_payments_secure / complete_payment_* + these two). Server-side
-- triggers and the payment RPCs still write feedemand directly, as intended.
--
--  * update_demand_class  — Section Transfer cascades a student's class/course
--                           onto all their demand rows (WHERE stu_id).
--  * rebuild_demand        — Fee Master edit-mode pushes recomputed amounts into
--                           a single demand row (WHERE dem_id).
-- Both derive ins_id/schema server-side. Requires secure_app_session.sql.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_demand_class(
  p_token text, p_stu_id bigint, p_class text, p_courname text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  EXECUTE format(
    'UPDATE %I.feedemand SET stuclass=$1, courname=COALESCE(NULLIF($2,''''), courname) '
    'WHERE stu_id=$3 AND ins_id=$4', v_schema)
  USING p_class, p_courname, p_stu_id, v_ins;
END; $$;

CREATE OR REPLACE FUNCTION public.rebuild_demand(
  p_token text, p_dem_id bigint, p_feeamount numeric, p_balancedue numeric, p_collectible boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  EXECUTE format(
    'UPDATE %I.feedemand SET feeamount=$1, balancedue=$2, reconbalancedue=$2, collectible=$3 '
    'WHERE dem_id=$4 AND ins_id=$5', v_schema)
  USING p_feeamount, p_balancedue, p_collectible, p_dem_id, v_ins;
END; $$;

GRANT EXECUTE ON FUNCTION public.update_demand_class(text, bigint, text, text)             TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rebuild_demand(text, bigint, numeric, numeric, boolean)   TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
