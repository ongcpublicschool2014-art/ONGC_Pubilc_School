-- =====================================================================
-- Fix: fines collected through the PARENT APP stop being recorded.
--
-- The hardening left anon with SELECT only on feedemand. The parent app
-- writes feedemand.fineamount twice on the normal path -- after a payment
-- succeeds, and back to 0 after one fails -- and both writes are wrapped in
-- a catch that only debugPrints. So on live they fail silently: a fine paid
-- through the app never reaches the demand (the admin FINE column
-- under-reports it), and a stale fine lingers after a failed payment.
-- The money is unaffected -- the fine rides inside paidamount -- it is the
-- fineamount column that goes wrong.
--
-- This restores the write through a parent-session-gated RPC instead of a
-- table grant, so the app needs no write privilege on feedemand at all.
--
-- SCOPE: a caller can only touch demands belonging to their OWN children.
-- Ownership uses exactly the predicate the parent RLS policy uses
-- (parents.payinchargemob = current_app_parmob()), so this opens nothing
-- the parent could not already read. It is SECURITY DEFINER, which bypasses
-- RLS, so that check is made explicitly here.
--
-- NOTE ON TRUST: the fine value still comes from the client, exactly as it
-- did before the revoke -- this restores today's behaviour, it does not
-- improve on it. A tampered value cannot reduce what a student owes
-- (balancedue is a separate column); complete_payment_grouped only uses
-- balance + fine as a ceiling. The real fix is for the server to compute
-- the fine from finerule -- generate_overdue_fines_for_student already
-- does -- but that would change what parents are charged, so it needs the
-- college to confirm the rules first.
--
-- Safe to re-run.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.set_parent_demand_fines(p_fines jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text; v_mob text; v_n integer := 0;
BEGIN
  -- Parent sessions only. An admin session (par_id NULL) has its own path.
  IF public.current_app_par() IS NULL THEN
    RAISE EXCEPTION 'Not a parent session';
  END IF;
  v_mob := public.current_app_parmob();
  IF v_mob IS NULL OR v_mob = '' THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  v_ins := public.current_app_ins();
  IF v_ins IS NULL THEN RAISE EXCEPTION 'No institution on this session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  IF p_fines IS NULL OR jsonb_typeof(p_fines) <> 'array' THEN RETURN 0; END IF;

  EXECUTE format($f$
    WITH mine AS (
      SELECT d.stu_id
        FROM %1$I.parentdetail d
        JOIN %1$I.parents p ON p.par_id = d.par_id
       WHERE p.payinchargemob = $2 AND p.activestatus = 1
    ),
    want AS (
      SELECT (x->>'dem_id')::bigint AS dem_id,
             GREATEST(COALESCE((x->>'fine')::numeric, 0), 0) AS fine
        FROM jsonb_array_elements($1) x
       WHERE (x->>'dem_id') ~ '^[0-9]+$'
    )
    UPDATE %1$I.feedemand f
       SET fineamount = w.fine
      FROM want w
     WHERE f.dem_id = w.dem_id
       AND f.ins_id = $3
       AND f.activestatus = 1
       -- only this parent's own children
       AND f.stu_id IN (SELECT stu_id FROM mine)
  $f$, v_schema)
  USING p_fines, v_mob, v_ins;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $$;

GRANT EXECUTE ON FUNCTION public.set_parent_demand_fines(jsonb) TO anon, authenticated;
