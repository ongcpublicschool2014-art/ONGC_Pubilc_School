-- Transactions screen: make a date range cost what the range is worth.
--
-- WHY. public.fn_get_transactions(p_ins_id) takes an institution and nothing
-- else, so the Transactions screen asked PostgREST to filter its OUTPUT by
-- date. The function is plpgsql and cannot be inlined, so Postgres had to
-- build every payment row the institution has ever had, LEFT JOIN students for
-- each one and sort the whole set by createdat, and only then discard all but
-- the day being looked at. Drawing today cost the whole year -- and cost
-- exactly the same on a day with no transactions at all, which is how a screen
-- showing four zeroes still took several seconds.
--
-- This overload takes the dates and puts them in the WHERE, inside the
-- function, where an index can be used. The row shape is identical to
-- fn_get_transactions, so the client falls back to the old call unchanged if
-- this has not been run.
--
-- Read-only. Creates one function and one index per institution schema.
-- Safe to re-run. Do NOT wrap in BEGIN.

CREATE OR REPLACE FUNCTION public.fn_get_transactions_range(
  p_ins_id integer,
  p_from   date DEFAULT NULL,
  p_to     date DEFAULT NULL
) RETURNS TABLE(
  pay_id integer, ins_id integer, stu_id integer, payno text, stuname text,
  payamount numeric, paycurrency text, paymethod text, payreference text,
  paydate timestamptz, paystatus text, createdat timestamptz, recon_status text
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;

  -- The date test, explained once rather than inside the string:
  --   * both bounds or neither -- a half-open range reads as no filter, the
  --     same way the client treats it;
  --   * the upper bound is the NEXT day, EXCLUSIVE, so a receipt stamped at any
  --     time on the last day is included whatever the column stores;
  --   * an attempt that never completed has no paydate and is dated by when it
  --     was raised -- dropping those would hide exactly the pending and failed
  --     rows this screen exists to show.
  RETURN QUERY EXECUTE format(
    'SELECT p.pay_id::int, p.ins_id::int, p.stu_id::int, p.paynumber::text, s.stuname::text, p.transtotalamount, p.transcurrency::text, p.paymethod::text, p.payreference::text, p.paydate::timestamptz, p.paystatus::text, p.createdat::timestamptz, p.recon_status::text FROM %I.payment p LEFT JOIN %I.students s ON s.stu_id = p.stu_id WHERE p.ins_id = $1 AND ($2 IS NULL OR $3 IS NULL OR (p.paydate >= $2 AND p.paydate < ($3 + 1)) OR (p.paydate IS NULL AND p.createdat >= $2 AND p.createdat < ($3 + 1))) ORDER BY p.createdat DESC',
    v, v)
  USING p_ins_id, p_from, p_to;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_get_transactions_range(integer, date, date)
  TO anon, authenticated, service_role;

-- The index the new WHERE can actually use. One per institution schema that
-- has a payment table; skipped where it already exists.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT table_schema AS s
    FROM information_schema.tables
    WHERE table_name = 'payment'
      AND table_schema NOT IN ('pg_catalog', 'information_schema', 'public')
  LOOP
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS payment_ins_paydate_idx'
      ' ON %I.payment (ins_id, paydate DESC)', r.s);
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS payment_ins_createdat_idx'
      ' ON %I.payment (ins_id, createdat DESC)', r.s);
    RAISE NOTICE 'indexed %.payment', r.s;
  END LOOP;
END $$;

-- Proof it works. Should return today's rows (very likely none) and should be
-- fast whatever the answer.
SELECT count(*) AS todays_transactions
FROM public.fn_get_transactions_range(1, current_date, current_date);
