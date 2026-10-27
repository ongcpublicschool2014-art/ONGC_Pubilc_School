-- =====================================================================
-- The receipt register, and an honest gap check -- for good.
--
-- WHY THE GAPS LOOKED REAL AND WERE NOT.
-- One number series (FC26/) is consumed by THREE tables:
--     payment.paynumber            fee receipts
--     misc_collection.mcno         miscellaneous receipts   <-- shared series
--     advance_collection.advno     advance receipts         <-- shared series
-- Every check run so far scanned `payment` alone, so each misc and advance
-- receipt looked like a missing number. On 2026-10-01, scanning payment only
-- reported 846 missing numbers; counting all three consumers reported ZERO
-- missing and zero duplicates across the whole run 1..3278. The register was
-- complete the entire time.
--
-- That is also why the "gaps" appeared to follow mobile payments and busy days:
-- those are simply the days with the most misc and advance receipts interleaved
-- between the fee receipts.
--
-- WHY CONCURRENT COLLECTION CANNOT CREATE A GAP.
-- Every writer of the counter (complete_payment_grouped, process_grouped_payment,
-- complete_payment_atomic, save_misc_collection, save_advance_collection,
-- process_refund, adjust_advance) takes
--     SELECT ... FROM sequence WHERE ... FOR UPDATE
-- before incrementing. That lock is held until commit, so simultaneous
-- collectors are serialised; and because the increment is an ordinary table
-- UPDATE inside the same transaction as the receipt row, a rollback releases
-- the number for the next caller instead of burning it. The number and the row
-- live or die together. This is the one real difference from a Postgres
-- SEQUENCE, which does burn numbers on rollback.
--
-- The two ways a number could still have been lost -- destroying a numbered row,
-- and re-running an already-receipted payment -- are closed by
-- PROTECT_RECEIPTED_PAYMENTS.sql and REFUSE_REPROCESSING_RECEIPTED_PAYMENT.sql.
--
-- SO THE FORWARD FIX IS NOT ANOTHER GUARD. It is to stop measuring the series
-- one table at a time. These two functions are the single source of truth:
--   * receipt_register(ins_id)    every number issued, with the table holding it
--   * check_receipt_gaps(ins_id)  numbers issued to nothing
-- A row from check_receipt_gaps is a real loss worth investigating. An empty
-- result is proof the register is continuous -- the answer an auditor actually
-- wants, and the one nobody could give before.
--
-- Read-only: creates two functions and changes no data. Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Every number the receipt series has issued, whatever table holds it.
--
-- Only prefixes belonging to a configured RECEIPT sequence (fg_id set) count,
-- so the 'PAY<id>' fallback numbers complete_payment_grouped invents when no
-- sequence exists are not mistaken for series members.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receipt_register(p_ins_id integer)
RETURNS TABLE (prefix text, n bigint, receipt_no text, source text,
               dated date, status text, amount numeric, collected_by text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $fn$
DECLARE v text; r record;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;

  FOR r IN EXECUTE format(
      'SELECT DISTINCT regexp_replace(sequid, ''[0-9]+$'', '''') AS pfx
         FROM %I.sequence
        WHERE ins_id = $1 AND fg_id IS NOT NULL AND activestatus = 1', v)
    USING p_ins_id
  LOOP
    RETURN QUERY EXECUTE format($q$
      SELECT $2::text, (regexp_match(p.paynumber, '([0-9]+)$'))[1]::bigint,
             p.paynumber::text, 'fee'::text, p.paydate::date,
             CASE WHEN p.activestatus = 9  THEN 'cancelled'
                  WHEN p.paystatus   = 'R' THEN 'refunded'
                  WHEN p.paystatus   = 'C' THEN 'collected'
                  ELSE 'paystatus ' || p.paystatus END,
             p.transtotalamount, p.createdby::text
        FROM %1$I.payment p
       WHERE p.ins_id = $1 AND p.paynumber LIKE $2 || '%%'
         AND p.paynumber ~ '[0-9]$'
      UNION ALL
      SELECT $2::text, (regexp_match(m.mcno, '([0-9]+)$'))[1]::bigint,
             m.mcno::text, 'misc'::text, m.mcdate::date,
             CASE WHEN m.activestatus = 9 THEN 'cancelled' ELSE 'collected' END,
             m.totalamount, m.collectedby::text
        FROM %1$I.misc_collection m
       WHERE m.ins_id = $1 AND m.mcno LIKE $2 || '%%'
         AND m.mcno ~ '[0-9]$'
      UNION ALL
      SELECT $2::text, (regexp_match(a.advno, '([0-9]+)$'))[1]::bigint,
             a.advno::text, 'advance'::text, a.advdate::date,
             CASE WHEN a.activestatus = 9  THEN 'cancelled'
                  WHEN a.paystatus   = 'R' THEN 'refunded'
                  ELSE 'collected' END,
             a.transtotalamount, a.createdby::text
        FROM %1$I.advance_collection a
       WHERE a.ins_id = $1 AND a.advno LIKE $2 || '%%'
         AND a.advno ~ '[0-9]$'
    $q$, v) USING p_ins_id, r.pfx;
  END LOOP;
END; $fn$;

COMMENT ON FUNCTION public.receipt_register(integer) IS
  'Every receipt number issued, across payment / misc_collection / '
  'advance_collection, which share one series. Scanning any single one of those '
  'tables reports the other two as missing numbers.';

-- ---------------------------------------------------------------------
-- Numbers the series has issued that no receipt carries.
--
-- Empty = the register is continuous. A row here is a genuine loss, and names
-- the receipts either side of it so the event can be found in the day's work.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_receipt_gaps(p_ins_id integer)
RETURNS TABLE (prefix text, missing_no text, n bigint,
               prev_receipt text, prev_dated date,
               next_receipt text, next_dated date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $fn$
DECLARE v text; r record;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;

  FOR r IN EXECUTE format(
      'SELECT regexp_replace(sequid, ''[0-9]+$'', '''') AS pfx,
              COALESCE(seqcurno, 0)::bigint            AS hi,
              COALESCE(seqwidth, 5)::int               AS w
         FROM %I.sequence
        WHERE ins_id = $1 AND fg_id IS NOT NULL AND activestatus = 1', v)
    USING p_ins_id
  LOOP
    RETURN QUERY
    WITH used AS (
      SELECT g.n, g.receipt_no, g.dated
        FROM public.receipt_register(p_ins_id) g
       WHERE g.prefix = r.pfx AND g.n IS NOT NULL
    ), span AS (
      -- from the first number actually issued, so a series adopted mid-year
      -- does not report everything before it as lost.
      SELECT COALESCE(MIN(used.n), 1) AS lo FROM used
    )
    SELECT r.pfx,
           r.pfx || lpad(s.g::text, r.w, '0'),
           s.g,
           (SELECT u.receipt_no FROM used u WHERE u.n < s.g ORDER BY u.n DESC LIMIT 1),
           (SELECT u.dated      FROM used u WHERE u.n < s.g ORDER BY u.n DESC LIMIT 1),
           (SELECT u.receipt_no FROM used u WHERE u.n > s.g ORDER BY u.n      LIMIT 1),
           (SELECT u.dated      FROM used u WHERE u.n > s.g ORDER BY u.n      LIMIT 1)
      FROM span, generate_series(span.lo, r.hi) AS s(g)
     WHERE NOT EXISTS (SELECT 1 FROM used u WHERE u.n = s.g)
     ORDER BY s.g;
  END LOOP;
END; $fn$;

COMMENT ON FUNCTION public.check_receipt_gaps(integer) IS
  'Receipt numbers issued to nothing. Empty is the healthy state and is proof '
  'the register is continuous. Counts misc and advance receipts, which share '
  'the fee-receipt series -- scanning payment alone reports hundreds of false '
  'gaps.';

GRANT EXECUTE ON FUNCTION public.receipt_register(integer)   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.check_receipt_gaps(integer) TO authenticated, service_role;
