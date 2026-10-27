-- =====================================================================
-- Fix: "update or delete on table feedemand violates foreign key
--       constraint shoppingcartdetails_dem_id_fkey"   (SQLSTATE 23503)
--
-- Student Fee Definition -> remove a fee calls delete_student_fee_demand.
-- The function checks paidamount but nothing else, so when a PARENT has
-- that same demand sitting in their shopping cart, shoppingcartdetails
-- still references the row and the DELETE is refused. The clerk sees a raw
-- database error and the fee cannot be removed -- on 2026-09-29 this fired
-- five times in forty seconds, which is somebody clicking again and again.
--
-- A cart line pointing at a demand nobody owes any more is meaningless, so
-- the fix is to clear it first. The one case where that is NOT safe is a
-- payment already in flight (carinitiated <> 'N'): pulling a line out from
-- under an open Paytm order would leave the parent paying for something the
-- office has just deleted. That case is refused, with a message the clerk
-- can act on.
--
-- Safe to re-run.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.delete_student_fee_demand(
  p_token text, p_dem_id bigint
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text; v_paid numeric; v_busy int;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  EXECUTE format('SELECT COALESCE(paidamount,0) FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2', v_schema)
    INTO v_paid USING p_dem_id, v_ins;
  IF COALESCE(v_paid,0) > 0 THEN
    RAISE EXCEPTION 'Cannot remove a fee that already has a collection';
  END IF;

  -- A parent is mid-payment on this fee. Leave it alone.
  -- 'N' = cart still open, 'I' = checkout initiated. Tested as <> 'N' rather
  -- than = 'I' so any future state counts as busy and fails safe.
  EXECUTE format('SELECT COUNT(*) FROM %I.shoppingcartdetails d
                    JOIN %I.shoppingcart c ON c.car_id = d.car_id
                   WHERE d.dem_id = $1 AND c.activestatus = 1
                     AND COALESCE(c.carinitiated,''N'') <> ''N''', v_schema, v_schema)
    INTO v_busy USING p_dem_id;
  IF COALESCE(v_busy,0) > 0 THEN
    RAISE EXCEPTION 'A parent is paying this fee right now. Try again in a few minutes.';
  END IF;

  -- Drop the cart lines, then any cart header they leave empty -- an empty
  -- cart would otherwise block the parent's next one (there is a unique
  -- index allowing only one active cart per student).
  EXECUTE format('DELETE FROM %I.shoppingcartdetails WHERE dem_id = $1', v_schema)
    USING p_dem_id;
  EXECUTE format('DELETE FROM %I.shoppingcart c
                   WHERE c.ins_id = $1
                     AND NOT EXISTS (SELECT 1 FROM %I.shoppingcartdetails d
                                      WHERE d.car_id = c.car_id)', v_schema, v_schema)
    USING v_ins;

  EXECUTE format('DELETE FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2 AND COALESCE(paidamount,0)=0', v_schema)
    USING p_dem_id, v_ins;
END; $$;

GRANT EXECUTE ON FUNCTION public.delete_student_fee_demand(text, bigint) TO anon, authenticated;
