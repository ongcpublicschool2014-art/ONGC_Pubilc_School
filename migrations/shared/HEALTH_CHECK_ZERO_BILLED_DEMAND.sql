-- =====================================================================
-- fee_health_check: a tenth check -- a demand that BILLS NOTHING but has
-- money against it.
--
-- WHY. On 05-10-2026, while chasing an unrelated overpayment, 22 students in
-- B.E ECE-II / GOVERNMENT QUOTA turned out to have TUITION FEE / YEARLY billed
-- ZERO. Thirteen of them had been paying since July -- Rs 2,55,675 of ordinary
-- cash receipts against a bill of nothing. Their 32 classmates on the same
-- quota came through the same 09-09-2026 import billed normally, mostly
-- Rs 30,000.
--
-- The money was never at risk: every rupee is receipted and banked. What was
-- wrong was the BILL, which is exactly why none of the nine existing checks
-- saw it -- they all follow the money, and here the money is fine.
--
-- The damage is in what it hides. With feeamount zero, balancedue is zero, so
-- all 22 read as fully settled -- including the NINE who have paid nothing.
-- Nobody will chase them, and roughly Rs 6.6 lakh of demand is simply missing
-- from the year's totals.
--
-- It was found by accident. That is the part worth fixing.
--
-- WARNING, not CRITICAL: no money is lost or at risk, and a legitimately
-- zero-value demand that somebody paid into by mistake would also land here.
-- It needs a human, not an alarm.
--
-- Patched into the deployed function rather than restated -- nine other checks
-- depend on it being left alone. Idempotent: it checks for itself first.
-- =====================================================================

DO $patch$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname = 'fee_health_check'
                AND p.prosrc LIKE '%bills nothing%') THEN
    RAISE NOTICE 'check 10 already present -- nothing to do';
    RETURN;
  END IF;
  RAISE NOTICE 'adding check 10 to fee_health_check';
END $patch$;

CREATE OR REPLACE FUNCTION public.fee_health_check()
 RETURNS TABLE(ins_id integer, institution text, severity text, check_name text, found bigint, meaning text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$

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

         -- Only attempts that actually REACHED Paytm. A row with no

         -- payorderid never contacted the gateway -- somebody opened the

         -- payment screen and walked away -- so "ask Paytm about each" is

         -- advice that cannot be followed, and it is cleared anyway the next

         -- time that student starts a payment.

         AND COALESCE(length(btrim(payorderid)), 0) > 0

         -- Only attempts that actually REACHED Paytm. A row with no

         -- payorderid never contacted the gateway -- somebody opened the

         -- payment screen and walked away -- so "ask Paytm about each" is

         -- advice that cannot be followed, and it is cleared anyway the next

         -- time that student starts a payment. Leaving it in made the warning

         -- mean two different things, which is how a health check stops being

         -- read.

         AND COALESCE(length(btrim(payorderid)), 0) > 0

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


    -- 8. Captures Paytm confirmed that the database refused to receipt.
    --    Each is money the college HAS, with no receipt against it. The
    --    refusal was right; being invisible was not.
    SELECT count(*) INTO n FROM public.webhook_refusal r
     WHERE r.resolved_at IS NULL AND COALESCE(r.ins_id, i.id) = i.id;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,
      'captures Paytm confirmed but we refused', n,
      CASE WHEN n > 0 THEN 'money received with no receipt -- see public.webhook_refusal'
           ELSE 'no refused captures outstanding' END;


    -- 9. Misc/advance Paytm collections that were started and never
    --    finished. Each is possibly money taken with no receipt -- the
    --    counter may have closed believing it failed.
    SELECT count(*) INTO n FROM public.pending_collection pc
     WHERE pc.ins_id = i.id AND pc.status IN ('I','P')
       AND pc.created_at < now() - interval '2 hours';
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,
      'misc/advance payments never finished', n,
      CASE WHEN n > 0 THEN 'ask Paytm about each: captured ones still need a receipt'
           ELSE 'none outstanding' END;


    -- 10. A demand that bills NOTHING but has money against it.
    --
    --     balancedue is then 0, so the student reads as fully settled, and the
    --     ones who have NOT paid read the same way -- nobody will ever be
    --     chased. Found on 05-10-2026 by accident, while chasing an unrelated
    --     overpayment: 22 students in one class and quota (B.E ECE-II,
    --     GOVERNMENT QUOTA) had TUITION FEE / YEARLY billed zero after a fee
    --     demand import on 09-09-2026, while 13 of them had been paying since
    --     July. Rs 2,55,675 received against a bill of nothing, and roughly
    --     Rs 6.6 lakh of demand simply absent from the year.
    --
    --     The money is not at risk -- it is receipted and banked. The BILL is
    --     wrong, which is why no money-side check caught it.
    EXECUTE format($q$
      SELECT count(*) FROM %1$I.feedemand fd
       WHERE fd.activestatus = 1
         AND COALESCE(fd.feeamount, 0) - COALESCE(fd.conamount, 0) <= 0
         AND COALESCE(fd.paidamount, 0) > 0
    $q$, v) INTO n;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,
      'demand bills nothing but money was taken', n,
      CASE WHEN n > 0
        THEN 'the fee amount is missing, not the money. Set it in Fee Demand -- '
             'until then these students read as settled and cannot be billed.'
        ELSE 'every demand carrying money also carries an amount' END;

  END LOOP;

END; $function$;


NOTIFY pgrst, 'reload schema';


-- ---------------------------------------------------------------------
-- VERIFY -- the first row must read ok, and the second shows what it finds.
-- ---------------------------------------------------------------------
SELECT 'check 10 is installed' AS check,
       CASE WHEN p.prosrc LIKE '%bills nothing%' THEN 'ok' ELSE 'FAILED' END AS state,
       '' AS detail
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'fee_health_check'
UNION ALL
SELECT 'the nine existing checks survived',
       CASE WHEN p.prosrc LIKE '%misc/advance payments never finished%'
             AND p.prosrc LIKE '%demand credited more than receipts prove%'
            THEN 'ok' ELSE 'FAILED' END, ''
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'fee_health_check'
 ORDER BY 1;

-- What the whole health check says now. Every row should read 'ok' except the
-- new one, which is expected to report 13 until the amounts are set.
SELECT severity, check_name, found, meaning FROM public.fee_health_check()
 ORDER BY CASE severity WHEN 'CRITICAL' THEN 0 WHEN 'WARNING' THEN 1 ELSE 2 END,
          check_name;
