-- Daily Collection report: one row per (receipt x semester).
--
-- A receipt can pay demands across more than one term. Instead of one row per
-- receipt (with a comma-joined semester), the report now emits ONE ROW PER
-- SEMESTER on the receipt: the fee breakdown, fine and total are scoped to that
-- term (total = the receipt amount allocated to that term = SUM of its
-- paymentdetails). Rows of the same receipt share paynumber/paydate/student, so
-- per-term totals still sum to the full receipt (and the grand total is
-- unchanged). semester comes from feedemand.demfeeterm.
--
-- Adding a column to a RETURNS TABLE requires a DROP first (CREATE OR REPLACE
-- can't change the return signature). The _json wrapper calls this by name and
-- picks up the new column automatically — no change needed there.

DROP FUNCTION IF EXISTS public.get_daily_collection_report(TEXT, INT, DATE, DATE);

CREATE OR REPLACE FUNCTION public.get_daily_collection_report(
    p_schema TEXT, p_ins_id INT, p_from DATE, p_to DATE
) RETURNS TABLE (
    pay_id BIGINT, paynumber TEXT, stuadmno TEXT, stuname TEXT,
    courname TEXT, stuclass TEXT, semester TEXT, type TEXT, paymethod TEXT, createdby TEXT,
    fees_json JSONB, fine NUMERIC, total NUMERIC, paydate DATE
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  p.pay_id::BIGINT,
                p.paynumber::TEXT,
                s.stuadmno::TEXT,
                s.stuname::TEXT,
                s.courname::TEXT,
                s.stuclass::TEXT,
                COALESCE(fd.demfeeterm, '')::TEXT AS semester,
                (CASE WHEN BOOL_OR(UPPER(COALESCE(fd.demseqtype,''))='ARREAR') THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                p.paymethod::TEXT,
                COALESCE(p.createdby, '')::TEXT AS createdby,
                COALESCE(jsonb_object_agg(fd.demfeetype, pd.transtotalamount)
                         FILTER (WHERE fd.demfeetype IS NOT NULL),
                         '{}'::jsonb) AS fees_json,
                COALESCE(SUM(fd.fineamount), 0)::NUMERIC AS fine,
                COALESCE(SUM(pd.transtotalamount), MAX(p.transtotalamount), 0)::NUMERIC AS total,
                p.paydate::DATE
        FROM    %1$I.payment p
        LEFT JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
        LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
        LEFT JOIN %1$I.students s ON s.stu_id = p.stu_id
        WHERE   p.ins_id = %2$L AND p.activestatus = 1
            AND p.paystatus = 'C' AND p.recon_status = 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $$;

GRANT EXECUTE ON FUNCTION public.get_daily_collection_report(TEXT, INT, DATE, DATE) TO anon, authenticated;
