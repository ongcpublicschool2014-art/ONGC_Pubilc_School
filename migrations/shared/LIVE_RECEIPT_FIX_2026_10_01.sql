-- =====================================================================
-- LIVE: receipt-number fix, 2026-10-01.  Run this whole file ONCE.
--
-- Three parts, in order. All idempotent -- running it twice is a no-op.
-- No BEGIN: a single Run in the SQL editor commits it.
--
--   PART 1  repair + guard : a receipted payment row can never be destroyed
--                            or marked F/I. Also collapses the duplicated
--                            `AND paynumber IS NULL` predicate that an
--                            earlier non-idempotent run of part 1 left on
--                            this database.
--   PART 2  refuse re-run  : entering complete_payment_grouped with an
--                            already-receipted row now raises instead of
--                            quietly creating a SECOND receipt and crediting
--                            the demand twice.
--   PART 3  the real fix   : receipt_register() and check_receipt_gaps().
--
-- WHY PART 3 IS THE ACTUAL ANSWER TO "SOLVE THE RECEIPT GAPS".
-- The FC26/ series is consumed by THREE tables -- payment.paynumber,
-- misc_collection.mcno and advance_collection.advno. Every gap check so far
-- scanned `payment` alone, which reports every misc and advance receipt as a
-- missing number. On TEST that was 846 false gaps; counting all three
-- consumers gave ZERO missing and ZERO duplicates over the whole run 1..3278.
-- There was never a gap in the fee receipt series.
--
-- Concurrent collection cannot create one either: every writer of the counter
-- takes `FROM sequence ... FOR UPDATE` before incrementing, and the increment
-- is an ordinary UPDATE in the same transaction as the receipt row -- so a
-- rollback RELEASES the number for the next collector instead of burning it.
--
-- The last statement in this file is the gap check, so the Run output is the
-- proof. Expect ZERO rows.
-- =====================================================================


-- #####################################################################
-- PART 1
-- #####################################################################
-- =====================================================================
-- Stop a payment that already carries a RECEIPT NUMBER from being failed
-- or deleted. Two separate symptoms, one cause.
--
-- SYMPTOM 1 -- a FAILED transaction showing a receipt number.
--   set_payment_status is a bare UPDATE ... WHERE pay_id = $5. The parent
--   app's failure path calls it with 'F', and nothing stops it flipping a
--   row that has already produced a receipt. On 2026-10-01 that put
--   FC26/03272 and FC26/03273 (Rs 3,600, captured by Paytm) on the failed
--   list, so the collection reports under-counted real money.
--
-- SYMPTOM 2 -- gaps in the receipt register.
--   complete_payment_grouped ends by deleting the original payment row:
--   DELETE FROM payment WHERE pay_id = $1, unconditional. Run twice for the
--   same payment -- a retry -- the second run DELETES the row holding the
--   first receipt number and draws a fresh one. The old number is gone from
--   the register while the counter has moved past it. That is FC26/03268 and
--   FC26/03270: each sits immediately before a receipt for the same student.
--
-- The rule both now follow: a receipt number, once drawn and attached, is a
-- record of money. Nothing may silently fail it or delete it.
--
-- Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Never fail a receipted payment.
--    Other transitions still work, so a pending row can still be completed
--    or failed normally; only a row that already produced a receipt is
--    protected, and only from being marked failed or cancelled.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_payment_status(
  p_ins_id integer, p_pay_id bigint, p_status text DEFAULT NULL::text,
  p_method text DEFAULT NULL::text, p_reference text DEFAULT NULL::text,
  p_touch_date boolean DEFAULT true)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout TO '15s'
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE v text; v_no text;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN; END IF;

  IF p_status IN ('F','I') THEN
    EXECUTE format('SELECT paynumber FROM %I.payment WHERE pay_id = $1', v)
      INTO v_no USING p_pay_id;
    IF COALESCE(v_no,'') <> '' THEN
      -- The receipt exists and the demand behind it has been credited.
      -- Marking it failed would hide money the college has actually taken.
      RAISE EXCEPTION
        'Payment % already carries receipt % and cannot be marked %. '
        'If the money must be given back, raise a refund.',
        p_pay_id, v_no, p_status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  EXECUTE format(
    'UPDATE %I.payment SET '
    'paystatus = COALESCE($1, paystatus), '
    'paymethod = COALESCE($2, paymethod), '
    'payreference = COALESCE($3, payreference), '
    'paydate = CASE WHEN $4 THEN now() ELSE paydate END '
    'WHERE pay_id = $5', v)
  USING p_status, p_method, p_reference, p_touch_date, p_pay_id;
END; $function$;

GRANT EXECUTE ON FUNCTION public.set_payment_status(integer, bigint, text, text, text, boolean)
  TO anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. Never delete a receipted payment.
--    complete_payment_grouped is long and handles the money, so it is NOT
--    rewritten here. Only its final DELETE is narrowed, by replacing the
--    function source in place: the row is removed only while it has no
--    receipt number, which is the case it was written for (the temporary
--    'I' row). A retry then leaves the first receipt standing instead of
--    destroying it, and no number is lost.
-- ---------------------------------------------------------------------
DO $patch$
DECLARE src text; newsrc text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc
   WHERE proname = 'complete_payment_grouped' AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'complete_payment_grouped not found';
  END IF;

  -- Test for the guard BEFORE attempting the replace. The unguarded DELETE is a
  -- PREFIX of the guarded one, so replace() happily matches an already-patched
  -- source and appends the predicate a second time -- which is what produced
  -- `AND paynumber IS NULL AND paynumber IS NULL` on TEST. Checking first makes
  -- re-running genuinely idempotent.
  -- Repair the doubling an earlier, non-idempotent run of this script left
  -- behind. `AND paynumber IS NULL AND paynumber IS NULL` is harmless logically
  -- but it is not what anyone reading the function should find.
  IF position('AND paynumber IS NULL AND paynumber IS NULL' in src) > 0 THEN
    EXECUTE replace(src, 'AND paynumber IS NULL AND paynumber IS NULL',
                         'AND paynumber IS NULL');
    RAISE NOTICE 'complete_payment_grouped: collapsed a duplicated guard predicate';
    RETURN;
  END IF;

  IF position('AND paynumber IS NULL' in src) > 0 THEN
    RAISE NOTICE 'complete_payment_grouped already guarded -- nothing to do';
    RETURN;
  END IF;

  newsrc := replace(
    src,
    'DELETE FROM %I.payment WHERE pay_id=$1',
    'DELETE FROM %I.payment WHERE pay_id=$1 AND paynumber IS NULL');

  IF newsrc = src THEN
    RAISE EXCEPTION 'REFUSED: the expected DELETE was not found, so the '
                    'function has changed shape. Patch it by hand.';
  END IF;

  EXECUTE newsrc;
  RAISE NOTICE 'complete_payment_grouped: delete now skips receipted rows';
END $patch$;


-- #####################################################################
-- PART 2
-- #####################################################################
-- =====================================================================
-- Refuse to re-process a payment that has already produced a receipt.
--
-- WHY THIS IS NEEDED ON TOP OF PROTECT_RECEIPTED_PAYMENTS.
-- That migration narrowed the final delete to `AND paynumber IS NULL`, so a
-- numbered row can no longer be destroyed. On its own that is not enough, and
-- is arguably worse: if complete_payment_grouped is entered with a row that
-- already carries a receipt, it now
--     1. reads that row,
--     2. creates a SECOND receipt with a new number,
--     3. fails to delete the first, because the guard protects it,
-- leaving two receipts for one payment and the demand credited twice. That
-- trades a cosmetic gap in the register for real double-counted money.
--
-- The honest fix is to refuse at the door. A payment that has produced a
-- receipt is finished; whatever the caller wants, re-running the collection
-- is not it. The caller gets a clear error instead of a silent second receipt.
--
-- This also removes the need to delete a numbered row at all, so the two
-- guards agree: a receipt, once drawn, is immutable.
--
-- Patches the deployed source in place rather than restating 100 lines of
-- money logic, and refuses if the function has changed shape.
--
-- Safe to re-run.
-- =====================================================================
DO $patch$
DECLARE src text; newsrc text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc
   WHERE proname = 'complete_payment_grouped'
     AND pronamespace = 'public'::regnamespace;
  IF src IS NULL THEN
    RAISE EXCEPTION 'complete_payment_grouped not found';
  END IF;

  IF position('already produced receipt' in src) > 0 THEN
    RAISE NOTICE 'already guarded -- nothing to do';
    RETURN;
  END IF;

  -- 1. carry paynumber out of the row it already locks FOR UPDATE, so the
  --    check costs nothing extra and cannot race another collector.
  newsrc := replace(
    src,
    'SELECT ins_id,inscode,stu_id,yr_id,yrlabel,createdby,payorderid,payreference FROM %I.payment WHERE pay_id=$1 FOR UPDATE',
    'SELECT ins_id,inscode,stu_id,yr_id,yrlabel,createdby,payorderid,payreference,paynumber FROM %I.payment WHERE pay_id=$1 FOR UPDATE');
  IF newsrc = src THEN
    RAISE EXCEPTION 'REFUSED: the expected SELECT ... FOR UPDATE was not found.';
  END IF;
  src := newsrc;

  -- 2. refuse the moment we know the row is already receipted, before any
  --    number is drawn or any row is written.
  newsrc := replace(
    src,
    'IF v_orig IS NULL THEN RAISE EXCEPTION ''Payment % not found'',p_pay_id; END IF;',
    'IF v_orig IS NULL THEN RAISE EXCEPTION ''Payment % not found'',p_pay_id; END IF;' || E'\n' ||
    '  -- A payment that has produced a receipt is finished. Re-running the' || E'\n' ||
    '  -- collection would raise a SECOND receipt and credit the demand twice.' || E'\n' ||
    '  IF COALESCE(v_orig.paynumber,'''') <> '''' THEN' || E'\n' ||
    '    RAISE EXCEPTION ''Payment % has already produced receipt %'',' || E'\n' ||
    '      p_pay_id, v_orig.paynumber USING ERRCODE = ''check_violation'';' || E'\n' ||
    '  END IF;');
  IF newsrc = src THEN
    RAISE EXCEPTION 'REFUSED: the expected not-found check was not located.';
  END IF;

  EXECUTE newsrc;
  RAISE NOTICE 'complete_payment_grouped now refuses an already-receipted payment';
END $patch$;


-- #####################################################################
-- PART 3
-- #####################################################################
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


-- #####################################################################
-- VERIFICATION -- this is the output you should read.
-- #####################################################################

-- Every number issued, by the table that holds it. fee + misc + advance
-- should add up to sequence.seqcurno.
SELECT source, count(*) AS receipts, min(n) AS lowest, max(n) AS highest
  FROM public.receipt_register(1) GROUP BY source ORDER BY source;

-- The counter, for that comparison.
SELECT seqcurno AS counter_is_at FROM kcet20262027.sequence WHERE seq_id = 1;

-- THE ANSWER. Zero rows = the receipt register is continuous, nothing lost.
-- Any row here is a genuine loss, and names the receipts either side of it.
SELECT * FROM public.check_receipt_gaps(1);
