-- =====================================================================
-- Stop payment.pay_id being handed out twice.
--
-- THE DEFECT.
--   set_pay_id assigns a new payment's id with
--       SELECT COALESCE(MAX(pay_id),0) + 1 FROM payment
--   so deleting the highest row RELEASES its id, and the next insert hands
--   that same id to a different student.
--
-- WHY IT COSTS REAL MONEY. The parent app's Paytm order id embeds the pay_id:
-- 'PAY-<pay_id>t<timestamp>'. If the row is removed between the app taking the
-- id and the payment completing, the id is reissued to someone else, and the
-- completion then names a row that belongs to another student.
--
-- Observed on live, 1 Oct 2026:
--   * a parent's first attempt took pay_id 2803; that row went away
--   * 13:38 IST  pay_id 2803 was REISSUED to stu_id 125 -> receipt FC26/03312
--   * 17:58:19   the app, still holding payId 2803, created PAY-2803t...
--   * 17:58:30   Paytm captured Rs 8,000
--   * the completion was refused -- 2803 already carried a receipt
--   Rs 8,000 taken from a family, recorded nowhere, found only by reconciling
--   against Paytm by hand.
--
-- The refusal was RIGHT: without it the money would have been credited to
-- stu_id 125's demand, which is worse than a visible gap. The id reuse is the
-- thing to fix.
--
-- THE FIX. Use the sequence that already exists in every schema and is
-- currently unused. A sequence never reissues a number, so a stale pay_id
-- points at a row that simply does not exist -- a case the callers already
-- handle ('Payment % not found').
--
-- It also removes a contention point: MAX+1 took an advisory lock for the
-- whole transaction, serialising every payment insert in the institution.
-- nextval needs no lock.
--
-- SAFETY. The sequence is parked above the highest id in use BEFORE the
-- trigger starts using it, so the first new id cannot collide with an existing
-- row. Explicitly supplied ids still work (the NULL/0 guard is kept), which
-- the import paths rely on.
--
-- Run when the counter is quiet: it replaces a trigger function on the payment
-- path. Idempotent. Changes no existing row.
-- =====================================================================

DO $fix$
DECLARE s text; v_max bigint; v_seq text; n int := 0;
BEGIN
  FOR s IN SELECT table_schema FROM information_schema.tables
            WHERE table_name = 'payment'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    v_seq := s || '.payment_pay_id_seq';

    -- The builder creates this sequence already; be certain for older schemas.
    EXECUTE format('CREATE SEQUENCE IF NOT EXISTS %I.payment_pay_id_seq', s);

    -- Park it above every id in use. is_called = true when rows exist, so the
    -- next value is MAX+1; false on an empty table, so the first value is 1.
    EXECUTE format('SELECT COALESCE(MAX(pay_id), 0) FROM %I.payment', s) INTO v_max;
    EXECUTE format('SELECT setval(%L, GREATEST(%s, 1), %L)',
                   v_seq, v_max, (v_max > 0));

    -- The trigger now draws from the sequence. The NULL/0 guard stays so a
    -- caller supplying an explicit id (master/collection imports) still wins.
    EXECUTE format($t$
      CREATE OR REPLACE FUNCTION %1$I.set_pay_id() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $f$
      BEGIN
        IF NEW.pay_id IS NULL OR NEW.pay_id = 0 THEN
          -- A SEQUENCE, not MAX(pay_id)+1: deleting the highest row must never
          -- release its id for reuse. The parent app's Paytm order id carries
          -- the pay_id, so a reissued id sends one family's payment at another
          -- family's receipt.
          NEW.pay_id := nextval(%2$L);
        END IF;
        RETURN NEW;
      END; $f$
    $t$, s, v_seq);

    RAISE NOTICE '%: sequence parked at %, trigger now uses nextval', s, v_max;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '% schema(s) fixed', n;
END $fix$;


-- ---------------------------------------------------------------------
-- NOTE ON NEW INSTITUTIONS.
-- create_institution_schema still writes the MAX+1 version into any tenant it
-- builds. That is fixed in complete_setup.sql and deployed by
-- FIX_TENANT_BUILDER.sql -- rebuilt from the same file -- rather than by
-- patching the function's text in place: the body is a format() string whose
-- quotes are already doubled, and editing it in the database is exactly the
-- kind of surgery that goes wrong quietly.
-- RUN FIX_TENANT_BUILDER.sql AFTER THIS ONE.
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- VERIFY -- every schema must read 'sequence'.
-- ---------------------------------------------------------------------
SELECT n.nspname AS schema,
       -- Match the ASSIGNMENT, not the words: the fixed body explains MAX+1
       -- in a comment, and matching on that phrase reports a false failure.
       CASE WHEN p.prosrc LIKE '%nextval%' THEN 'sequence' ELSE 'STILL MAX+1' END AS pay_id_source,
       (SELECT last_value FROM pg_sequences q
         WHERE q.schemaname = n.nspname AND q.sequencename = 'payment_pay_id_seq') AS seq_at,
       (SELECT max(pay_id) FROM kcet20262027.payment WHERE n.nspname = 'kcet20262027') AS highest_row
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE p.proname = 'set_pay_id'
 ORDER BY 1;
