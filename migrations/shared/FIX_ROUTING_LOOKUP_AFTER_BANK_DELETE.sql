-- =====================================================================
-- Deleting a bank account must not strand money already in flight under it.
--
-- WHAT IS WRONG. paytm_mid_for_routing answers two different questions with
-- the same filter:
--
--   by FEE GROUP  -- "which merchant should this NEW payment settle to?"
--   by BAN_ID     -- "which merchant SIGNED this order that already exists?"
--
-- Both required b.activestatus = 1. For the first that is right: new money
-- must never be routed to an account somebody has removed. For the second it
-- is wrong, and quietly dangerous.
--
-- Deleting a bank in the admin app is a SOFT delete -- activestatus goes to 0
-- and the row stays. The moment that happens, every unfinished intent signed
-- with that bank loses its merchant: the lookup returns NULL, the sweep falls
-- back to the INSTITUTION default merchant, and Paytm is asked about an order
-- it never saw under that merchant. The answer is "no record".
--
-- "No record" is correctly treated as UNDECIDED rather than failed, so nothing
-- is written off -- but nothing is ever recovered either. A real capture sits
-- in pending_collection for ever, no receipt is raised, and the only visible
-- trace is a parent insisting they paid. Removing a bank account from a setup
-- screen is not an action anybody expects to cost money.
--
-- THE FIX. Which merchant signed an order is a HISTORICAL FACT. Whether that
-- account is still in use today has no bearing on it, so the ban_id lookup no
-- longer filters on activestatus. The fee-group lookup keeps the filter,
-- because that one is about where the NEXT payment should go.
--
-- The institution scope (b.ins_id = $2) is untouched -- it is what stops a
-- ban_id from another unit being used to read somebody else's merchant.
--
-- Replaced whole rather than patched in place: the body is short and the
-- surgery is one clause, so restating it is clearer than a text replace and
-- cannot half-apply. Idempotent.
-- =====================================================================
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
    -- WHERE SHOULD NEW MONEY GO? The group's own account. Scoped to the
    -- institution so a fee group id from somewhere else cannot be used to read
    -- another unit's merchant. activestatus = 1 is kept deliberately: a
    -- removed account must not receive a fresh payment.
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
    -- WHO SIGNED THE ORDER THAT ALREADY EXISTS? A historical question, so NO
    -- activestatus filter. The recovery sweep reaches here with the ban_id the
    -- order was signed with; if the account has since been removed and this
    -- returned NULL, the sweep would ask the institution's default merchant
    -- about an order it never saw, be told "no record", and leave a real
    -- capture unreceipted for ever.
    --
    -- Still scoped to the institution, which is the part that matters for
    -- isolation.
    EXECUTE format(
      'SELECT b.paytm_mid
         FROM %I.bank b
        WHERE b.ban_id = $1 AND b.ins_id = $2
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
  'to the institution default merchant. Returns the merchant id only. The '
  'ban_id lookup does NOT filter activestatus: it answers which merchant '
  'signed an EXISTING order, so a since-deleted account must still resolve.';

GRANT EXECUTE ON FUNCTION public.paytm_mid_for_routing(integer, integer, integer)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ---------------------------------------------------------------------
-- VERIFY -- both rows must read ok.
-- ---------------------------------------------------------------------
SELECT 'a deleted bank still resolves the order it signed' AS check,
       CASE WHEN p.prosrc LIKE '%WHO SIGNED THE ORDER%' THEN 'ok' ELSE 'FAILED' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'paytm_mid_for_routing'
UNION ALL
SELECT 'new money still refuses a deleted bank',
       CASE WHEN p.prosrc LIKE '%g.activestatus = 1 AND b.activestatus = 1%'
            THEN 'ok' ELSE 'FAILED' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'paytm_mid_for_routing'
 ORDER BY 1;
