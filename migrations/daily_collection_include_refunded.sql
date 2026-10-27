-- ============================================================================
-- daily_collection_include_refunded.sql
-- Daily Collection was hiding the ORIGINAL collection of any receipt that was
-- later refunded: process_refund flips payment.paystatus 'C'→'R', and the
-- report filtered paystatus='C' only, so the receipt vanished from its
-- collection date. A refund on a LATER day must not erase the collection on the
-- day it happened.
--
-- Fix: include paystatus IN ('C','R') together with activestatus=1. Voided /
-- cancelled receipts are activestatus=9, so they stay excluded; only genuinely
-- refunded receipts (activestatus=1, paystatus='R') come back — shown as a full
-- collection on their own paydate. The refund itself is listed separately (by
-- refund date) in the report's Refunds section.
--
-- This is the LIVE (semester + type) version verbatim with only the paystatus
-- predicate changed. Same return signature, but DROP first to be safe. Run once.
-- ============================================================================

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
            AND p.paystatus IN ('C','R') AND p.recon_status = 'R'
            AND p.paydate::DATE >= %3$L AND p.paydate::DATE <= %4$L
        GROUP BY p.pay_id, p.paynumber, p.paymethod, p.createdby, p.paydate,
                 fd.demfeeterm,
                 s.stuadmno, s.stuname, s.courname, s.stuclass
        ORDER BY p.paynumber, COALESCE(fd.demfeeterm, '')
    $f$, p_schema, p_ins_id, p_from, p_to);
END $$;

GRANT EXECUTE ON FUNCTION public.get_daily_collection_report(TEXT, INT, DATE, DATE) TO anon, authenticated;
