-- =====================================================================
-- LIVE -- everything today's release needs. Run ONCE, before installing
-- desktop 0.0.10 and publishing parent app 1.1.2.
--
-- PART 1 REFUSES TO GO FURTHER if enabling fee-group routing would move money.
--        0.0.10 and 1.1.2 route a collection to its FEE GROUP's own Paytm
--        merchant whenever that group's bank names one, instead of always
--        using the institution's. On a database with one fee group that is a
--        no-op -- but only if that group's bank resolves to the SAME merchant
--        the institution already uses. If it does not, this script stops
--        before changing anything and nothing is released.
--
-- PART 2 lets the PARENT APP resolve a fee group's merchant at all. It cannot
--        read <schema>.bank: that table's RLS policy requires
--        current_app_par() IS NULL, which is never true in the parent app, so
--        the query returns ZERO ROWS -- not an error. The app reads that as
--        "no merchant configured" and silently settles hostel money into the
--        college account. A SECURITY DEFINER function answers the one question
--        without exposing account numbers.
--
-- PART 3 maps the advance types to a fee group. 0.0.10 refuses to collect an
--        advance whose type is not mapped, because an unmapped advance has no
--        fee group, so no receipt series and no account.
--
-- No BEGIN: one Run commits it. Idempotent. Nothing here touches a receipt, a
-- payment or a demand.
-- =====================================================================


-- #####################################################################
-- PART 1 of 3 -- the gate. Stops the whole script if money would move.
-- #####################################################################
DO $gate$
DECLARE r record; v_ins_mid text; n int := 0;
BEGIN
  SELECT merchant_id INTO v_ins_mid
    FROM public.paytm_configuration WHERE institution_id = 1 LIMIT 1;

  FOR r IN
    SELECT g.fgdesc, NULLIF(trim(b.paytm_mid), '') AS mid
      FROM kcet20262027.feegroup g
      LEFT JOIN kcet20262027.bank b ON b.ban_id = g.ban_id
     WHERE g.ins_id = 1 AND g.activestatus = 1
  LOOP
    IF r.mid IS NOT NULL AND r.mid IS DISTINCT FROM v_ins_mid THEN
      n := n + 1;
      RAISE WARNING '% would settle to % instead of the institution merchant %',
        r.fgdesc, r.mid, v_ins_mid;
    END IF;
  END LOOP;

  IF n > 0 THEN
    -- Whether the statements BELOW this one still run depends on the client:
    -- the SQL editor wraps a Run in one transaction and rolls them back, psql
    -- does not. Either way they are harmless -- a read-only function and two
    -- settings rows. What this stops is the RELEASE, not the script.
    RAISE EXCEPTION
      'DO NOT INSTALL 0.0.10 / 1.1.2 YET: % fee group(s) would start settling '
      'into a DIFFERENT Paytm account. Read the warnings above and confirm that '
      'is intended first. (Any statements after this one are read-only or '
      'settings-only and change no money either way.)', n
      USING ERRCODE = 'check_violation';
  END IF;

  RAISE NOTICE 'gate passed: every fee group resolves the merchant it already uses';
END $gate$;


-- #####################################################################
-- PART 2 of 3 -- the parent app can resolve a fee group's merchant
-- #####################################################################
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
    -- Scoped to the institution so a fee group id from elsewhere cannot be
    -- used to read another unit's merchant.
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

  -- Empty means "not configured", same as no row: the caller falls back to the
  -- institution merchant rather than signing an order with ''.
  RETURN NULLIF(trim(COALESCE(v_mid, '')), '');
END;
$function$;

COMMENT ON FUNCTION public.paytm_mid_for_routing(integer, integer, integer) IS
  'The Paytm merchant a fee group settles to. Exists because <schema>.bank is '
  'invisible to a parent session under RLS, which silently routed every '
  'parent-app payment to the institution default merchant. Returns the '
  'merchant id only.';

GRANT EXECUTE ON FUNCTION public.paytm_mid_for_routing(integer, integer, integer)
  TO anon, authenticated;


-- #####################################################################
-- PART 3 of 3 -- advance type -> fee group
-- #####################################################################
INSERT INTO public.institution_settings
       (ins_id, setting_key, setting_value, updatedat, updatedby)
VALUES (1, 'advance_route_fg_A', '1', now(), 'ADMIN'),
       (1, 'advance_route_fg_S', '1', now(), 'ADMIN')
ON CONFLICT (ins_id, setting_key)
DO UPDATE SET setting_value = EXCLUDED.setting_value,
              updatedat     = EXCLUDED.updatedat,
              updatedby     = EXCLUDED.updatedby;

-- PostgREST caches function signatures; without this the apps keep calling the
-- old body. Outside any transaction, because NOTIFY only fires on commit.
NOTIFY pgrst, 'reload schema';


-- #####################################################################
-- VERIFY -- every row must read 'ready'.
-- #####################################################################
SELECT 'parent app can resolve a merchant' AS check,
       CASE WHEN public.paytm_mid_for_routing(1, (SELECT MIN(fg_id)
              FROM kcet20262027.feegroup WHERE ins_id=1 AND activestatus=1)) IS NOT NULL
            THEN 'ready' ELSE 'returns nothing - check bank.paytm_mid' END AS state
UNION ALL
SELECT 'advance Admission mapped',
       COALESCE((SELECT 'ready (fee group ' || setting_value || ')'
                   FROM public.institution_settings
                  WHERE ins_id=1 AND setting_key='advance_route_fg_A'
                    AND COALESCE(trim(setting_value),'') <> ''), 'NOT MAPPED')
UNION ALL
SELECT 'advance Student mapped',
       COALESCE((SELECT 'ready (fee group ' || setting_value || ')'
                   FROM public.institution_settings
                  WHERE ins_id=1 AND setting_key='advance_route_fg_S'
                    AND COALESCE(trim(setting_value),'') <> ''), 'NOT MAPPED')
UNION ALL
SELECT 'the money still adds up',
       CASE WHEN (SELECT count(*) FROM public.fee_health_check()
                   WHERE severity <> 'ok') = 0
            THEN 'ready' ELSE 'SEE fee_health_check() - do not release' END;
