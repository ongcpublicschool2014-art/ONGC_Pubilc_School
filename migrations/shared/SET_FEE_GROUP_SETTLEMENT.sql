-- =====================================================================
-- Turn fee-group bank routing ON or OFF for an institution, from SQL.
--
-- With it on, an ONLINE collection settles into the merchant of the fee
-- group's own bank -- hostel fees into the hostel account -- instead of the
-- institution's single merchant. Cash, cheque and DD are unaffected: they are
-- banked by the receipt, not by the gateway.
--
-- The setting is PER INSTITUTION (institution_settings.ins_id), so one tenant
-- can route by fee group while another does not. Set it for each institution
-- that needs it; leaving it unset means off.
--
-- Every counter picks the change up within 60 seconds (the settings cache
-- TTL). No rebuild, no file on each machine.
--
-- TURN IT OFF THE SAME WAY, and that is the point: the first time real money
-- routes to a newly onboarded merchant is exactly when an instant undo is
-- wanted, and a rebuild-and-release is not one.
--
-- BEFORE TURNING IT ON, all of these must be true for THAT institution, or its
-- online payments are either refused (safe) or settle to the wrong account:
--   1. the fee group exists and names a bank
--   2. that bank carries its own paytm_mid
--   3. the group has its own receipt sequence
--   4. that merchant's KEY is in the PAYTM_MERCHANTS edge secret
--   5. LIVE_BANK_ROUTING_BUNDLE.sql has been run
-- The readiness report at the bottom checks 1-3 and 5, for every institution.
-- Only you can check 4.
--
-- COST OF TURNING IT ON: a student owing dues in TWO groups can no longer pay
-- them in one online transaction -- one Paytm order settles to exactly one
-- merchant, so the counter takes two payments.
-- =====================================================================

-- >>> SET THE INSTITUTION HERE. Run the readiness report at the bottom first
-- >>> if you are not sure which ins_id you want.
\set target_ins 1

-- ON:
INSERT INTO public.institution_settings
       (ins_id, setting_key, setting_value, updatedat, updatedby)
VALUES (:target_ins, 'fee_group_settlement', 'true', now(), 'ADMIN')
ON CONFLICT (ins_id, setting_key)
DO UPDATE SET setting_value = EXCLUDED.setting_value,
              updatedat     = EXCLUDED.updatedat,
              updatedby     = EXCLUDED.updatedby;

-- OFF -- run this instead to revert, same shape:
-- INSERT INTO public.institution_settings
--        (ins_id, setting_key, setting_value, updatedat, updatedby)
-- VALUES (:target_ins, 'fee_group_settlement', 'false', now(), 'ADMIN')
-- ON CONFLICT (ins_id, setting_key)
-- DO UPDATE SET setting_value = EXCLUDED.setting_value, updatedat = now();
--
-- In the Supabase SQL editor \set is not available -- replace :target_ins with
-- the number, e.g. VALUES (1, 'fee_group_settlement', 'true', now(), 'ADMIN').


-- ---------------------------------------------------------------------
-- READINESS, every institution and every fee group.
--
-- A group that can be collected online needs a bank, that bank's own merchant,
-- and its own receipt sequence. Anything less and its payments cannot route.
--
-- Each institution lives in its own schema, so this resolves the schema the
-- way the app does (get_institution_schema) rather than naming one. An
-- institution added later appears here with no edit.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fee_group_routing_readiness()
RETURNS TABLE (ins_id integer, insname text, item text, value text, note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $fn$
DECLARE i record; v text;
BEGIN
  -- one row for the migration state, which is database-wide
  RETURN QUERY
  SELECT NULL::integer, NULL::text, 'migrations applied'::text,
         CASE WHEN p.prosrc LIKE '%razorpay%' THEN 'NO' ELSE 'yes' END::text,
         CASE WHEN p.prosrc LIKE '%razorpay%'
              THEN 'run LIVE_BANK_ROUTING_BUNDLE.sql first' ELSE '' END::text
    FROM pg_proc p
   WHERE p.proname = 'complete_payment_grouped'
     AND p.pronamespace = 'public'::regnamespace;

  FOR i IN SELECT ins.ins_id AS id, ins.insname::text AS nm
             FROM public.institution ins
            WHERE ins.activestatus = 1 ORDER BY ins.ins_id
  LOOP
    RETURN QUERY
    SELECT i.id, i.nm, 'setting'::text,
           COALESCE((SELECT s.setting_value FROM public.institution_settings s
                      WHERE s.ins_id = i.id
                        AND s.setting_key = 'fee_group_settlement'),
                    '(not set - off)')::text,
           'counters pick this up within 60s'::text;

    v := get_institution_schema(i.id);
    IF v IS NULL THEN
      RETURN QUERY SELECT i.id, i.nm, 'schema'::text, 'MISSING'::text,
                          'this institution has no schema'::text;
      CONTINUE;
    END IF;

    RETURN QUERY EXECUTE format($q$
      SELECT $1::integer, $2::text,
             ('group: ' || g.fgdesc)::text,
             (COALESCE(b.banname, 'NO BANK') || ' / ' ||
              CASE WHEN COALESCE(trim(b.paytm_mid), '') = '' THEN 'NO MERCHANT'
                   ELSE b.paytm_mid END || ' / ' ||
              COALESCE(q.sequid, 'NO SEQUENCE'))::text,
             (CASE WHEN b.ban_id IS NULL
                        OR COALESCE(trim(b.paytm_mid), '') = ''
                        OR q.seq_id IS NULL
                   THEN 'NOT READY - online payments here will not route'
                   ELSE 'ready' END)::text
        FROM %1$I.feegroup g
        LEFT JOIN %1$I.bank b ON b.ban_id = g.ban_id
        LEFT JOIN %1$I.sequence q ON q.fg_id = g.fg_id AND q.ins_id = g.ins_id
       WHERE g.ins_id = $1 AND g.activestatus = 1
       ORDER BY g.fg_id
    $q$, v) USING i.id, i.nm;
  END LOOP;
END; $fn$;

GRANT EXECUTE ON FUNCTION public.fee_group_routing_readiness() TO authenticated, service_role;

SELECT * FROM public.fee_group_routing_readiness();
