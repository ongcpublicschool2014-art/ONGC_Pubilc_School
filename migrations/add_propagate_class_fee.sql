-- ============================================================================
-- add_propagate_class_fee.sql
-- Speeds up Fee Master "edit & save": propagating an updated class-fee template
-- to existing unpaid feedemand rows was an N+1 — one SELECT per fee line, then
-- one UPDATE per matching student demand, all SEQUENTIAL (a class of 200
-- students × ~10 fee types ≈ 2000 round-trips while the user waits).
--
-- This RPC does it set-based: ONE UPDATE per fee line, server-side, in a single
-- call. It reproduces the client math exactly (rebuild_demand):
--   feeamount        = line amount
--   balancedue       = GREATEST(amount - conamount - paidamount, 0)
--   reconbalancedue  = same as balancedue
--   collectible      = line's "apply to all" flag
-- and only touches UNPAID (paidstatus='U'), active rows for the class/term/type,
-- optionally restricted to a set of admission numbers (admission-type filter).
--
-- SECURITY DEFINER + get_institution_schema(p_ins_id) like the other tenant
-- RPCs. The client keeps the old per-row loop as a fallback, so this is
-- non-breaking — it just makes the save fast once run. Idempotent. Run once.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.propagate_class_fee(
  p_ins_id integer,
  p_class  text,
  p_term   text,
  p_lines  jsonb,               -- [{feetype, amount, collectible}, ...]
  p_admnos text[] DEFAULT NULL  -- NULL = all students in the class
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v text; ln jsonb; total int := 0; n int;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema found for ins_id %', p_ins_id; END IF;

  FOR ln IN SELECT * FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb)) LOOP
    EXECUTE format(
      'UPDATE %I.feedemand SET '
      '  feeamount = $1, '
      '  balancedue = GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0), '
      '  reconbalancedue = GREATEST($1 - COALESCE(conamount,0) - COALESCE(paidamount,0), 0), '
      '  collectible = $2 '
      'WHERE ins_id = $3 AND stuclass = $4 AND demfeeterm = $5 AND demfeetype = $6 '
      '  AND paidstatus = ''U'' AND activestatus = 1 '
      '  AND ($7::text[] IS NULL OR stuadmno = ANY($7))', v)
    USING (ln->>'amount')::numeric,
          COALESCE((ln->>'collectible')::boolean, true),
          p_ins_id, p_class, p_term, (ln->>'feetype'), p_admnos;
    GET DIAGNOSTICS n = ROW_COUNT;
    total := total + n;
  END LOOP;

  RETURN total;
END; $$;

GRANT EXECUTE ON FUNCTION public.propagate_class_fee(integer, text, text, jsonb, text[]) TO anon, authenticated;

NOTIFY pgrst, 'reload config';
