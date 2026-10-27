-- ============================================================================
-- Pending Details report: expose REGULAR vs ARREAR.
--
-- WHY: the report could not be filtered to arrear-only or regular-only,
-- because the RPC collapsed both into one figure per fee type. Adding
-- demseqtype to the projection (and the GROUP BY) lets the client split them.
--
-- NULL/blank demseqtype is reported as REGULAR: rows written before the column
-- existed are all current-year demands, and treating them as neither would
-- make them vanish from both halves of the filter.
--
-- Same signature, so CREATE OR REPLACE is enough -- no DROP, no downtime.
--
-- NOTE for the client: a student can now return TWO rows for the same fee type
-- (one REGULAR, one ARREAR). Anything pivoting this must ACCUMULATE per fee
-- type, not assign.
--
-- SAFE TO RE-RUN. Run on TEST first.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_pending_details_report(
    p_schema TEXT, p_ins_id INT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json;
BEGIN
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        ),
        per_type AS (
          SELECT  s.courname::TEXT                                  AS courname,
                  s.stuclass::TEXT                                  AS stuclass,
                  s.stuadmno::TEXT                                  AS stuadmno,
                  s.stuname::TEXT                                   AS stuname,
                  -- Category on the printed sheet is the student's quota.
                  COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL')::TEXT   AS category,
                  COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS')::TEXT AS feetype,
                  -- REGULAR vs ARREAR, so the report can be filtered to one or
                  -- the other. NULL is reported as REGULAR: older rows predate
                  -- the column and are all current-year demands.
                  COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')::TEXT AS demseqtype,
                  SUM(fd.feeamount)::NUMERIC                        AS demand,
                  SUM(fd.feeamount - COALESCE(fd.conamount, 0))::NUMERIC AS net_demand,
                  GREATEST(
                    COALESCE(SUM(fd.paidamount), 0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus = 'P' OR fd.paidamount > 0), 0)
                      - COALESCE(SUM(pa.pending_fee), 0),
                    0
                  )::NUMERIC                                        AS collection,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, s.stuadmno, s.stuname,
                   COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL'),
                   COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS'),
                   COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')
        )
        -- Only students who actually owe something. Their OTHER fee types are
        -- still returned, because the Total Demand / Collection columns are
        -- whole-student figures, not just the unpaid slice.
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.stuadmno, t.feetype, t.demseqtype), '[]'::json)
        FROM (
          SELECT * FROM per_type
          WHERE  stuadmno IN (SELECT stuadmno FROM per_type
                               GROUP BY stuadmno HAVING SUM(pending) <> 0)
        ) t
    $f$, p_schema, p_ins_id) INTO r;
    RETURN r;
END $$;

GRANT EXECUTE ON FUNCTION public.get_pending_details_report(TEXT, INT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verify: every row should carry a demseqtype of REGULAR or ARREAR.
SELECT DISTINCT value->>'demseqtype' AS demseqtype
  FROM json_array_elements(
         public.get_pending_details_report('kcet20262027', 1)
       ) AS value
 ORDER BY 1;
