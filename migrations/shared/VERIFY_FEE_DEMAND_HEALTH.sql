-- =====================================================================
-- FEE DEMAND HEALTH -- read only. Run on TEST before live, and on live
-- after. Safe with the counter open; writes nothing.
--
-- ONE result set: the Supabase editor shows only the last one, so every
-- check is a row of the same query.
-- =====================================================================

SELECT * FROM (

  -- 1. Money taken against a bill of nothing. The loud failure: the
  --    ledger shows a NEGATIVE balance and the demand reads settled.
  --    After both fix scripts this should be 1 -- CHANDRU R's bus fee,
  --    which has no sheet figure and needs the office.
  SELECT 1 AS n,
         'billed zero WITH money collected' AS check,
         count(*)::text AS value,
         COALESCE(string_agg(DISTINCT stuadmno, ', '), '-') AS detail
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND COALESCE(feeamount,0) - COALESCE(conamount,0) <= 0
     AND COALESCE(paidamount,0) > 0

  UNION ALL

  -- 2. Billed nothing, nothing collected. The SILENT failure: reads as
  --    settled, so nobody is chased and the billing is missing from
  --    every total. Most are legitimate (a fee the student is not
  --    charged); the fix scripts only touch those the 03-09 sheet bills.
  SELECT 2, 'billed zero, nothing collected', count(*)::text, ''
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND COALESCE(feeamount,0) = 0 AND COALESCE(paidamount,0) = 0

  UNION ALL

  -- 3. Collected more than billed on a single demand. Should be zero.
  --    Anything here is either a wrong bill or a double payment.
  --
  --    fineamount IS PART OF THE BILL. A fine is collected on the fee it
  --    belongs to -- the receipt shows it in its own column, but it lands
  --    in that demand's paidamount. Leave it out and every fined student
  --    is reported as overpaid: BALAMBIKA T, tuition 25,000 with a 100
  --    fine, paid 25,100, ledger balancing to zero.
  SELECT 3, 'collected MORE than billed', count(*)::text,
         COALESCE(string_agg(stuadmno || ' ' || demfeetype, ', '), '-')
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND COALESCE(feeamount,0) > 0
     AND COALESCE(paidamount,0) > COALESCE(feeamount,0) - COALESCE(conamount,0)
                                  + COALESCE(fineamount,0) + 0.005

  UNION ALL

  -- 4. Which billing convention each scholarship student is on.
  --    SPLIT    = tuition carries the share, the grant line the rest.
  --    CONSOLIDATED = the whole fee on tuition, grant at zero.
  --    Both are valid and give the same total. A growing CONSOLIDATED
  --    count is the office moving away from the split, which is what
  --    makes a generated fix script go stale.
  SELECT 4, 'scholarship students on the SPLIT convention', count(*)::text, ''
    FROM (SELECT stuadmno FROM kcet20262027.feedemand
           WHERE activestatus = 1
             AND demfeetype IN ('SC/ST SCHOLARSHIP','FIRST GRADUATE AMOUNT')
             AND COALESCE(feeamount,0) > 0
           GROUP BY stuadmno) x

  UNION ALL

  SELECT 5, 'students with a grant line still at zero', count(*)::text, ''
    FROM (SELECT stuadmno FROM kcet20262027.feedemand
           WHERE activestatus = 1
             AND demfeetype IN ('SC/ST SCHOLARSHIP','FIRST GRADUATE AMOUNT')
             AND COALESCE(feeamount,0) = 0
           GROUP BY stuadmno) y

  UNION ALL

  -- 6. The balance columns must agree with billed - concession - paid.
  --    No trigger maintains them, so a hand edit can leave them stale
  --    and the ledger then disagrees with the demand.
  SELECT 6, 'balancedue out of step with the amounts', count(*)::text,
         COALESCE(string_agg(stuadmno || ' ' || demfeetype, ', '), '-')
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND abs(COALESCE(balancedue,0)
             - GREATEST(COALESCE(feeamount,0) - COALESCE(conamount,0)
                        - COALESCE(paidamount,0), 0)) > 0.005
) r ORDER BY n;
