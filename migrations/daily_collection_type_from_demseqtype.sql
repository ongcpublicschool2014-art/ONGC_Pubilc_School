-- Daily Collection report: add a TYPE column (Regular / Arrear) derived from
-- feedemand.demseqtype. Receipts are single-type, so BOOL_OR over the payment's
-- demands classifies the whole receipt. Public RPC — run once.
-- DROP first: adding the `type` column changes the return signature, which
-- CREATE OR REPLACE cannot do (ERROR 42P13).

DROP FUNCTION IF EXISTS public.get_daily_collection_report(text, integer, date, date);

CREATE OR REPLACE FUNCTION public.get_daily_collection_report(
    p_schema TEXT, p_ins_id INT, p_from DATE, p_to DATE
) RETURNS TABLE (
    pay_id BIGINT, paynumber TEXT, stuadmno TEXT, stuname TEXT,
    courname TEXT, stuclass TEXT, type TEXT, paymethod TEXT, createdby TEXT,
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
                (CASE WHEN BOOL_OR(UPPER(COALESCE(fd.demseqtype,''))='ARREAR') THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                p.paymethod::TEXT,
                COALESCE(p.createdby, '')::TEXT AS createdby,
                COALESCE(jsonb_object_agg(fd.demfeetype, pd.transtotalamount)
                         FILTER (WHERE fd.demfeetype IS NOT NULL),
                         '{}'::jsonb) AS fees_json,
                COALESCE(SUM(fd.fineamount), 0)::NUMERIC AS fine,
                p.transtotalamount::NUMERIC AS total,
                p.paydate::DATE
        FROM    %1$I.payment p
        LEFT JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
        LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
        LEFT JOIN %1$I.students s ON s.stu_id = p.stu_id
        WHERE   p.ins_id = %2$L AND p.activestatus = 1
            AND p.paystatus = 'C' AND p.recon_status = 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby,
                 p.transtotalamount, p.paydate,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber
    $f$, p_schema, p_ins_id, p_from, p_to);
END $$;

GRANT EXECUTE ON FUNCTION public.get_daily_collection_report(TEXT, INT, DATE, DATE) TO anon, authenticated;
