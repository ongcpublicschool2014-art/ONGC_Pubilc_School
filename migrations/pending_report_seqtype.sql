-- Pending Payment report: split each group by Regular / Arrear.
--
-- The report already emits one row per student per semester; this adds
-- demseqtype as another grouping key, so a student carrying both a regular and
-- an arrear due now gets a row for each and the screen can filter on it. The
-- classification is the same rule Fee Collection and Fee Concession use --
-- anything not explicitly 'ARREAR' counts as REGULAR -- so a null or blank
-- demseqtype can never hide a due.
--
-- Grand totals are unchanged: the same demands are still counted, just grouped
-- one level finer.
--
-- Idempotent: plain CREATE OR REPLACE, safe to run more than once.

CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
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
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.seqtype, t.stuadmno), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  fd.demfeeterm::TEXT AS semester,
                  -- Regular vs Arrear, same rule as Fee Collection and Fee
                  -- Concession: anything not explicitly ARREAR counts as
                  -- REGULAR, so a null/blank demseqtype never hides a due.
                  (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END)::TEXT AS seqtype,
                  s.admname::TEXT AS admname, s.stuadmno::TEXT AS stuadmno, s.stuname::TEXT AS stuname,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  s.quoname::TEXT AS quoname, s.stumobile::TEXT AS stumobile
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, fd.demfeeterm,
                   (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END),
                   s.admname, s.stuadmno, s.stuname, s.quoname, s.stumobile
          -- Keep a group that has nothing pending but DID receive a concession:
          -- dropping it also dropped its conamount, so the report's CON. AMT
          -- total came out short of SUM(feedemand.conamount).
          HAVING  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0)) <> 0
             OR   COALESCE(SUM(fd.conamount), 0) <> 0
        ) t
    $f$, p_schema, p_ins_id) INTO r;
    RETURN r;
END $$;
