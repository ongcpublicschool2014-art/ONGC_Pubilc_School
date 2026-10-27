-- =====================================================================
-- RECEIPT REGISTER CHECK -- every institution. Read only, safe on live.
--
-- Replaces CHECK_RECEIPT_GAPS_STANDALONE.sql, which was written when there was
-- one institution and hardcoded ins_id 1 and the schema name kcet20262027. A
-- check that silently covers only the first tenant is worse than no check: it
-- reports "0 gaps" for a database it never looked at.
--
-- This walks public.institution and asks check_receipt_gaps() for each one, so
-- institutions added later are included without editing anything.
--
-- Requires RECEIPT_REGISTER_AND_GAP_CHECK.sql (installed on live and TEST).
--
-- READ IT LIKE THIS:
--   'total'   how many numbers each table holds, per institution
--   'counter' that series' seqcurno; the totals must add up to it
--   'GAP'     a number issued to nothing. NONE is the healthy result.
--
-- Remember the series is SHARED: payment.paynumber, misc_collection.mcno and
-- advance_collection.advno all draw from it. A check that scans `payment`
-- alone reports every misc receipt as missing -- on live that was 853 false
-- gaps.
-- =====================================================================
DO $$
DECLARE
  i record;
  n_gaps bigint;
  n_held bigint;
BEGIN
  FOR i IN SELECT ins_id, insname FROM public.institution
            WHERE activestatus = 1 ORDER BY ins_id
  LOOP
    BEGIN
      SELECT count(*) INTO n_held FROM public.receipt_register(i.ins_id);
      SELECT count(*) INTO n_gaps FROM public.check_receipt_gaps(i.ins_id);
      IF n_gaps = 0 THEN
        RAISE NOTICE '[%] % -- % receipts, NO GAPS', i.ins_id, i.insname, n_held;
      ELSE
        RAISE WARNING '[%] % -- % receipts, % GAP(S). Run the query below for details.',
          i.ins_id, i.insname, n_held, n_gaps;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[%] % -- could not be checked: %', i.ins_id, i.insname, SQLERRM;
    END;
  END LOOP;
END $$;

-- The detail, for every institution at once. ZERO ROWS IS THE HEALTHY RESULT.
SELECT i.ins_id, i.insname, g.*
  FROM public.institution i
 CROSS JOIN LATERAL public.check_receipt_gaps(i.ins_id) g
 WHERE i.activestatus = 1
 ORDER BY i.ins_id, g.n;

-- The register totals, per institution and per source. The totals for one
-- institution must add up to that series' counter.
SELECT i.ins_id, i.insname, r.prefix, r.source,
       count(*) AS receipts, min(r.n) AS lowest, max(r.n) AS highest
  FROM public.institution i
 CROSS JOIN LATERAL public.receipt_register(i.ins_id) r
 WHERE i.activestatus = 1
 GROUP BY i.ins_id, i.insname, r.prefix, r.source
 ORDER BY i.ins_id, r.prefix, r.source;
