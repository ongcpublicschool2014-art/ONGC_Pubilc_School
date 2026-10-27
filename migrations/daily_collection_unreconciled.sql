-- ════════════════════════════════════════════════════════════════
-- daily_collection_unreconciled.sql
-- Daily Collection, the other half: receipts taken but NOT yet matched
-- against a bank statement.
--
-- get_daily_collection_report only ever returns recon_status='R', so money
-- collected today is invisible in the report until someone reconciles it —
-- which reads as "the counter took nothing". This returns the complement, with
-- exactly the same columns, so the screen can list it underneath its own total.
--
-- IS DISTINCT FROM 'R' rather than = 'P': a NULL recon_status is unreconciled
-- too, and = 'P' would quietly drop those rows from both halves of the report.
--
-- Idempotent: CREATE OR REPLACE.
-- ════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_daily_collection_unreconciled(
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
            AND p.paystatus IN ('C','R')
            AND p.recon_status IS DISTINCT FROM 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $$;

CREATE OR REPLACE FUNCTION public.get_daily_collection_unreconciled_json(
  p_schema text, p_ins_id integer, p_from date, p_to date
) RETURNS json LANGUAGE sql STABLE AS $$
  SELECT COALESCE(json_agg(t), '[]'::json)
  FROM public.get_daily_collection_unreconciled(p_schema, p_ins_id, p_from, p_to) t;
$$;

GRANT EXECUTE ON FUNCTION public.get_daily_collection_unreconciled(TEXT, INT, DATE, DATE) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_daily_collection_unreconciled_json(text, integer, date, date) TO anon, authenticated;

-- Verify: both halves should together equal every payment in the range.
SELECT 'reconciled'   AS half, count(*) FROM public.get_daily_collection_report(
         'kcet20262027', 1, CURRENT_DATE - 30, CURRENT_DATE)
UNION ALL
SELECT 'unreconciled', count(*) FROM public.get_daily_collection_unreconciled(
         'kcet20262027', 1, CURRENT_DATE - 30, CURRENT_DATE);
