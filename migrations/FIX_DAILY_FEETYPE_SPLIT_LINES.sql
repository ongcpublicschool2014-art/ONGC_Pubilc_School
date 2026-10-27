-- ============================================================================
-- DAILY COLLECTION: a fee settled in two pieces on one receipt lost a piece.
--
-- SYMPTOM
-- A receipt that takes part of a fee in cash and part from an advance shows the
-- fee-type column SHORT, while Total is right:
--
--     FC26/02934   T/F 35,000   Total 35,500   Cash 500   Adjusted 35,000
--                      ^^^^^^ should be 35,500
--
-- CAUSE
-- Both report functions built the fee-type breakdown with
--
--     jsonb_object_agg(fd.demfeetype, pd.transtotalamount - fd.fineamount)
--
-- over one row per paymentdetails line. A demand settled twice on the same
-- receipt (cash + advance, or two part-payments) produces two rows with the
-- SAME key, and jsonb_object_agg keeps only the last one -- the 500 was
-- dropped. The same join counted the demand's fine once per line, and the
-- per-line subtraction took that fine off the fee more than once.
--
-- FIX
-- Aggregate per demand first, then per fee type, and take the fine off once.
-- Both functions get the same treatment, so the reconciled and unreconciled
-- sections cannot disagree.
--
-- Row totals are unaffected -- they were already summed from the collected
-- amounts -- so the day's money does not move. Only the breakdown is corrected.
--
-- Reproduced verbatim from complete_setup.sql apart from those two aggregates.
-- SAFE TO RE-RUN (CREATE OR REPLACE). No data is touched. TEST first.
-- ============================================================================

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
                -- FEE ONLY, and SUMMED PER FEE TYPE.
                --
                -- A demand can appear on one receipt more than once -- part
                -- cash and part advance is the everyday case -- and
                -- jsonb_object_agg keeps only the LAST value for a repeated
                -- key. A 35,500 tuition fee settled as 500 cash + 35,000
                -- advance therefore printed as 35,000: the 500 vanished from
                -- the fee-type column while the row total still read 35,500.
                --
                -- The fine comes off ONCE PER DEMAND, not once per line.
                -- pd.transtotalamount includes the fine and fd.fineamount is
                -- the whole of it, so subtracting it from every line of a split
                -- demand understated the fee by the fine each extra time.
                (SELECT COALESCE(jsonb_object_agg(t.ft, t.amt)
                                 FILTER (WHERE t.ft IS NOT NULL), '{}'::jsonb)
                   FROM (SELECT d.demfeetype AS ft, SUM(d.amt) AS amt
                           FROM (SELECT fd2.demfeetype,
                                        SUM(pd2.transtotalamount)
                                          - COALESCE(MAX(fd2.fineamount), 0) AS amt
                                   FROM %1$I.paymentdetails pd2
                                   JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                                  WHERE pd2.pay_id = p.pay_id
                                    AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')
                                  GROUP BY fd2.demfeetype, fd2.dem_id) d
                          GROUP BY d.demfeetype) t) AS fees_json,
                -- One fine per DEMAND. SUM over the joined rows counted it
                -- again for every line a split demand added.
                (SELECT COALESCE(SUM(f.fineamount), 0)
                   FROM (SELECT DISTINCT fd2.dem_id, fd2.fineamount
                           FROM %1$I.paymentdetails pd2
                           JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                          WHERE pd2.pay_id = p.pay_id
                            AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')) f)::NUMERIC AS fine,
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
                -- FEE ONLY, and SUMMED PER FEE TYPE.
                --
                -- A demand can appear on one receipt more than once -- part
                -- cash and part advance is the everyday case -- and
                -- jsonb_object_agg keeps only the LAST value for a repeated
                -- key. A 35,500 tuition fee settled as 500 cash + 35,000
                -- advance therefore printed as 35,000: the 500 vanished from
                -- the fee-type column while the row total still read 35,500.
                --
                -- The fine comes off ONCE PER DEMAND, not once per line.
                -- pd.transtotalamount includes the fine and fd.fineamount is
                -- the whole of it, so subtracting it from every line of a split
                -- demand understated the fee by the fine each extra time.
                (SELECT COALESCE(jsonb_object_agg(t.ft, t.amt)
                                 FILTER (WHERE t.ft IS NOT NULL), '{}'::jsonb)
                   FROM (SELECT d.demfeetype AS ft, SUM(d.amt) AS amt
                           FROM (SELECT fd2.demfeetype,
                                        SUM(pd2.transtotalamount)
                                          - COALESCE(MAX(fd2.fineamount), 0) AS amt
                                   FROM %1$I.paymentdetails pd2
                                   JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                                  WHERE pd2.pay_id = p.pay_id
                                    AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')
                                  GROUP BY fd2.demfeetype, fd2.dem_id) d
                          GROUP BY d.demfeetype) t) AS fees_json,
                -- One fine per DEMAND. SUM over the joined rows counted it
                -- again for every line a split demand added.
                (SELECT COALESCE(SUM(f.fineamount), 0)
                   FROM (SELECT DISTINCT fd2.dem_id, fd2.fineamount
                           FROM %1$I.paymentdetails pd2
                           JOIN %1$I.feedemand fd2 ON fd2.dem_id = pd2.dem_id
                          WHERE pd2.pay_id = p.pay_id
                            AND COALESCE(fd2.demfeeterm, '') = COALESCE(fd.demfeeterm, '')) f)::NUMERIC AS fine,
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
GRANT EXECUTE ON FUNCTION public.get_daily_collection_unreconciled(TEXT, INT, DATE, DATE) TO anon, authenticated;


NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- VERIFY -- expect both rows t.
-- ============================================================================
SELECT p.proname,
       p.prosrc LIKE '%GROUP BY fd2.demfeetype, fd2.dem_id%' AS sums_split_lines
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('get_daily_collection_report', 'get_daily_collection_unreconciled')
 ORDER BY p.proname;
