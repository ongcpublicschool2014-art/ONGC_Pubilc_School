-- =====================================================================
-- public.fee_health_check() -- does the money still add up?
--
-- WHY THIS EXISTS. The JAYASURYA S case (2026-10-01) was found by accident:
-- someone happened to open Fee Collection and the Student Ledger for the same
-- student and noticed they disagreed. Nothing in the system was checking. The
-- demand had been credited Rs 14,700 that no receipt accounted for, and it
-- would have sat there indefinitely -- the student simply never being asked
-- for money the college was owed.
--
-- Guards stop the NEXT occurrence of a cause you already understand. This
-- catches the next occurrence of a cause you do not, by testing the things
-- that must be true regardless of how they came to be false:
--
--   * a demand is credited exactly what its receipts and advance adjustments
--     prove arrived -- no more, no less
--   * every receipt number issued belongs to exactly one receipt
--   * a row carrying a receipt number is not also marked failed or pending
--   * a receipt's lines add up to the receipt
--   * a payment does not sit unresolved for days
--
-- Each is an INVARIANT. When one breaks, something is wrong even if nobody
-- knows yet what did it -- which is exactly the position we were in this
-- morning.
--
-- Read-only. Safe on live, any time, including mid-collection.
-- Covers every institution; new ones are included without editing this.
--
--   SELECT * FROM public.fee_health_check();
--
-- Every row should read 'ok'. Anything else names the check, the count, and
-- what it means.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.fee_health_check()
RETURNS TABLE (ins_id integer, institution text, severity text,
               check_name text, found bigint, meaning text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $fn$
DECLARE i record; v text; n bigint;
BEGIN
  FOR i IN SELECT ins.ins_id AS id, ins.insname::text AS nm
             FROM public.institution ins
            WHERE ins.activestatus = 1 ORDER BY ins.ins_id
  LOOP
    v := get_institution_schema(i.id);
    IF v IS NULL THEN
      RETURN QUERY SELECT i.id, i.nm, 'ERROR'::text, 'schema'::text, 0::bigint,
                          'this institution has no schema'::text;
      CONTINUE;
    END IF;

    -- 1. Demand credited MORE than its receipts prove. The student looks
    --    settled and cannot be billed: money the college is owed, invisible.
    EXECUTE format($q$
      SELECT count(*) FROM %1$I.feedemand fd
       WHERE fd.activestatus = 1
         AND fd.paidamount > COALESCE(
               (SELECT SUM(pd.transtotalamount) FROM %1$I.paymentdetails pd
                  JOIN %1$I.payment p ON p.pay_id = pd.pay_id
                 WHERE pd.dem_id = fd.dem_id AND p.paynumber IS NOT NULL
                   AND p.paystatus = 'C' AND p.activestatus = 1), 0)
             + COALESCE(
               (SELECT SUM(a.adjustamount) FROM %1$I.advadjustment a
                 WHERE a.dem_id = fd.dem_id AND a.activestatus = 1), 0) + 0.005
    $q$, v) INTO n;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'CRITICAL' ELSE 'ok' END,
      'demand credited more than receipts prove', n,
      CASE WHEN n > 0
        THEN 'student appears settled but is not -- dues cannot be collected. '
             'Run FIX_OVERCREDITED_DEMANDS.sql (preview first).'
        ELSE 'every demand matches its receipts' END;

    -- 2. Demand credited LESS than its receipts. The opposite error: money
    --    arrived and the student is still being asked for it.
    EXECUTE format($q$
      SELECT count(*) FROM %1$I.feedemand fd
       WHERE fd.activestatus = 1
         AND fd.paidamount + 0.005 < COALESCE(
               (SELECT SUM(pd.transtotalamount) FROM %1$I.paymentdetails pd
                  JOIN %1$I.payment p ON p.pay_id = pd.pay_id
                 WHERE pd.dem_id = fd.dem_id AND p.paynumber IS NOT NULL
                   AND p.paystatus = 'C' AND p.activestatus = 1), 0)
    $q$, v) INTO n;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'CRITICAL' ELSE 'ok' END,
      'demand credited less than receipts prove', n,
      CASE WHEN n > 0
        THEN 'the family paid and is still being billed for it -- check before '
             'anyone chases them'
        ELSE 'no under-credited demands' END;

    -- 3. The same receipt number on more than one receipt.
    EXECUTE format($q$
      SELECT count(*) FROM (
        SELECT paynumber FROM %1$I.payment
         WHERE paynumber IS NOT NULL AND activestatus = 1
         GROUP BY paynumber HAVING count(*) > 1) d
    $q$, v) INTO n;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'CRITICAL' ELSE 'ok' END,
      'duplicate receipt numbers', n,
      CASE WHEN n > 0 THEN 'two receipts share a number -- the register is not trustworthy'
           ELSE 'every receipt number is unique' END;

    -- 4. A numbered receipt also marked failed or pending. Money taken, shown
    --    as not taken: this is what under-counted the collection reports.
    EXECUTE format($q$
      SELECT count(*) FROM %1$I.payment
       WHERE paynumber IS NOT NULL AND activestatus = 1 AND paystatus IN ('F','I')
    $q$, v) INTO n;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'CRITICAL' ELSE 'ok' END,
      'receipt marked failed or pending', n,
      CASE WHEN n > 0 THEN 'a receipt exists but the payment reads unpaid -- reports under-count'
           ELSE 'no receipted row is marked failed' END;

    -- 5. A receipt whose lines do not add up to it.
    EXECUTE format($q$
      SELECT count(*) FROM %1$I.payment p
       WHERE p.paynumber IS NOT NULL AND p.paystatus = 'C' AND p.activestatus = 1
         AND ABS(p.transtotalamount - COALESCE(
               (SELECT SUM(pd.transtotalamount) FROM %1$I.paymentdetails pd
                 WHERE pd.pay_id = p.pay_id AND pd.activestatus = 1), 0)) > 0.005
    $q$, v) INTO n;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,
      'receipt total does not match its lines', n,
      CASE WHEN n > 0 THEN 'the receipt and its breakdown disagree -- one of them is wrong'
           ELSE 'every receipt matches its lines' END;

    -- 6. Payments left unresolved for more than a day. Each is possibly real
    --    money with no receipt. 'I' is recoverable -- but only if somebody looks.
    EXECUTE format($q$
      SELECT count(*) FROM %1$I.payment
       WHERE paystatus = 'I' AND activestatus = 1
         AND createdat < now() - interval '24 hours'
    $q$, v) INTO n;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,
      'payments unresolved over 24h', n,
      CASE WHEN n > 0 THEN 'ask Paytm about each: captured ones still need a receipt'
           ELSE 'nothing stuck' END;

    -- 7. The receipt register, via the function that counts misc and advance
    --    receipts too -- a payment-only count reports hundreds of false gaps.
    BEGIN
      SELECT count(*) INTO n FROM public.check_receipt_gaps(i.id);
      RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,
        'receipt numbers issued to nothing', n,
        CASE WHEN n > 0 THEN 'run check_receipt_gaps() for the detail'
             ELSE 'the register is continuous' END;
    EXCEPTION WHEN OTHERS THEN
      RETURN QUERY SELECT i.id, i.nm, 'ERROR'::text,
        'receipt numbers issued to nothing'::text, 0::bigint,
        ('check could not run: ' || SQLERRM)::text;
    END;
  END LOOP;
END; $fn$;

COMMENT ON FUNCTION public.fee_health_check() IS
  'Invariants that must hold however the data got that way: demands credited '
  'exactly what receipts prove, receipt numbers unique and continuous, no '
  'receipted row marked failed, receipts matching their lines, nothing left '
  'unresolved. Read-only. Every row should read ok.';

GRANT EXECUTE ON FUNCTION public.fee_health_check() TO authenticated, service_role;

SELECT * FROM public.fee_health_check();
