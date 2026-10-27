-- ############################################################################
--
--   EduCore360 -- THE PARENT APP CAN ROUTE TO A FEE GROUP'S OWN MERCHANT
--   29-09-2026
--
--   Run the whole file. TEST first, then LIVE.
--
-- ----------------------------------------------------------------------------
-- THE BUG
-- ----------------------------------------------------------------------------
-- The parent app resolved the Paytm merchant like this:
--
--     SELECT paytm_mid FROM <schema>.bank WHERE ban_id = <the group's bank>
--
-- and fell back to the institution's own merchant when that came back empty.
--
-- <schema>.bank has RLS on, and its only SELECT policy is
--
--     app_tenant_read:  (current_app_par() IS NULL) AND (ins_id = current_app_ins())
--
-- current_app_par() is the PARENT session marker. In the parent app it is
-- never null, so the policy is false for every row and the query returns ZERO
-- ROWS -- not an error. maybeSingle() hands back null, the catch block is
-- never entered, and the code takes its fallback path in silence.
--
-- Proven on TEST, same anon role, only the session differing:
--
--     admin-style session (no app.par_id)   ->  2 banks visible
--     parent-style session (app.par_id set) ->  0 banks visible
--
-- So EVERY payment made in the parent app was signed with the institution's
-- default merchant from public.paytm_configuration -- the COLLEGE one -- and
-- a hostel fee paid from a phone settled into the college account. The admin
-- app was unaffected: its session has no par_id, so it reads bank normally.
-- That is exactly why desktop looked right and mobile did not.
--
-- ----------------------------------------------------------------------------
-- THE FIX
-- ----------------------------------------------------------------------------
-- Not a new RLS policy. Opening <schema>.bank to parent sessions would hand
-- every parent the institution's account numbers, IFSCs and branch details to
-- solve a problem that needs one string.
--
-- Instead: a SECURITY DEFINER function that answers exactly one question --
-- "which merchant does this fee group settle to" -- and returns nothing else.
-- The merchant id is not a secret: it is sent to Paytm from the client to open
-- the checkout, and it appears in the order. The merchant KEY stays where it
-- has always been, in the edge function's secrets.
--
-- Takes a fee group OR a bank id, because the two callers know different
-- things: the cart knows the fee group it is paying, while stuck-payment
-- recovery only has payment.ban_id from the row it is trying to resolve.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- One CREATE OR REPLACE and two GRANTs. Reads only; writes nothing.
--
-- ############################################################################

CREATE OR REPLACE FUNCTION public.paytm_mid_for_routing(
  p_ins_id integer,
  p_fg_id  integer DEFAULT NULL,
  p_ban_id integer DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v_schema text;
  v_mid    text;
BEGIN
  IF p_fg_id IS NULL AND p_ban_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_fg_id IS NOT NULL THEN
    -- The group's own account. Scoped to the institution so a fee group id
    -- from somewhere else cannot be used to read another unit's merchant.
    EXECUTE format(
      'SELECT b.paytm_mid
         FROM %I.feegroup g
         JOIN %I.bank b ON b.ban_id = g.ban_id
        WHERE g.fg_id = $1 AND g.ins_id = $2
          AND g.activestatus = 1 AND b.activestatus = 1
        LIMIT 1', v_schema, v_schema)
      INTO v_mid USING p_fg_id, p_ins_id;
  END IF;

  IF (v_mid IS NULL OR trim(v_mid) = '') AND p_ban_id IS NOT NULL THEN
    EXECUTE format(
      'SELECT b.paytm_mid
         FROM %I.bank b
        WHERE b.ban_id = $1 AND b.ins_id = $2 AND b.activestatus = 1
        LIMIT 1', v_schema, v_schema)
      INTO v_mid USING p_ban_id, p_ins_id;
  END IF;

  -- Empty string means "not configured", same as no row: the caller must fall
  -- back to the institution merchant rather than sign an order with ''.
  RETURN NULLIF(trim(COALESCE(v_mid, '')), '');
END;
$function$;

COMMENT ON FUNCTION public.paytm_mid_for_routing(integer, integer, integer) IS
  'The Paytm merchant a fee group settles to. Exists because <schema>.bank is '
  'invisible to a parent session under RLS (app_tenant_read requires '
  'current_app_par() IS NULL), which silently routed every parent-app payment '
  'to the institution default merchant. Returns the merchant id only.';

GRANT EXECUTE ON FUNCTION public.paytm_mid_for_routing(integer, integer, integer)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- VERIFY
-- ----------------------------------------------------------------------------
-- Run as a PARENT session, which is the one that was broken. Every fee group
-- should name a merchant, and the hostel group's must differ from the
-- college's -- if they match, the money is not actually being split.
BEGIN;
  SET LOCAL ROLE anon;
  SELECT set_config('app.ins_id', '1', true);
  SELECT set_config('app.par_id', '1', true);   -- <- the session that saw 0 banks

  SELECT g.fg_id,
         g.fgdesc,
         COALESCE(public.paytm_mid_for_routing(1, g.fg_id), '(falls back to institution)')
           AS settles_to_merchant
    FROM kcet20262027.feegroup g
   WHERE g.ins_id = 1 AND g.activestatus = 1
   ORDER BY g.fg_id;
ROLLBACK;
