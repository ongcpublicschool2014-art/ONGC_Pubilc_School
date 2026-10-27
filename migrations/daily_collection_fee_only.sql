-- ============================================================================
-- Daily Collection -- fee-type columns show FEE ONLY, not fee + fine
--
-- THE BUG (Daily Collection report, receipt FC26/02670):
--     feedemand.feeamount             25,000   the tuition fee
--     feedemand.fineamount               100   the fine collected with it
--     paymentdetails.transtotalamount  25,100   what was taken for that demand
--
-- The report put transtotalamount straight into the TUITION FEE column, so the
-- fine was counted inside the fee column AND shown again in the Fine column:
--     TUITION FEE 25,100   FINE 100    <- the same 100 twice
-- It now reads:
--     TUITION FEE 25,000   FINE 100    <- and 25,000 + 100 reconciles
--
-- THE ROW TOTAL DOES NOT CHANGE. It is SUM(pd.transtotalamount) -- the money
-- actually collected -- and is untouched, so nothing that tallies against the
-- bank or the cash book moves. Only the split between the fee column and the
-- fine column is corrected.
--
-- Fee Collection > Daily Collection reads the SAME function, so both screens
-- are fixed together and continue to reconcile with each other.
--
-- Read-only reporting function. SAFE TO RE-RUN.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_daily_collection_report(p_schema text, p_ins_id integer, p_from date, p_to date)
 RETURNS TABLE(pay_id bigint, paynumber text, stuadmno text, stuname text, courname text, stuclass text, semester text, type text, paymethod text, createdby text, fees_json jsonb, fine numeric, total numeric, paydate date)
 LANGUAGE plpgsql
AS $function$
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
                -- FEE ONLY. pd.transtotalamount is what was collected against
                -- the demand and INCLUDES the fine (a receipt legitimately
                -- carries balance + fine), while fd.fineamount on a paid demand
                -- is the fine part of it. Reporting the raw figure here put the
                -- fine inside the fee-type column AND again in the Fine column,
                -- so a 25,000 tuition fee with a 100 fine showed as 25,100 + 100.
                -- The row total is unaffected -- it is summed from the same
                -- collected amounts below, and stays the money actually taken.
                COALESCE(jsonb_object_agg(fd.demfeetype,
                             pd.transtotalamount - COALESCE(fd.fineamount, 0))
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
END $function$;


-- ── The unreconciled variant carries the identical bug ─────────────────────
-- Reports > Daily Collection's amber 'unreconciled' view reads this one.
-- Both must move together or the two views stop agreeing.

CREATE OR REPLACE FUNCTION public.get_daily_collection_unreconciled(p_schema text, p_ins_id integer, p_from date, p_to date)
 RETURNS TABLE(pay_id bigint, paynumber text, stuadmno text, stuname text, courname text, stuclass text, semester text, type text, paymethod text, createdby text, fees_json jsonb, fine numeric, total numeric, paydate date)
 LANGUAGE plpgsql
AS $function$
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
                -- FEE ONLY -- see get_daily_collection_report. The fine is
                -- reported in its own column, so leaving it inside the fee-type
                -- column counted it twice.
                COALESCE(jsonb_object_agg(fd.demfeetype,
                             pd.transtotalamount - COALESCE(fd.fineamount, 0))
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
END $function$;

NOTIFY pgrst, 'reload schema';

-- Verify: FC26/02670 should show TUITION FEE 25000 with fine 100, total 25325.
SELECT paynumber, fees_json, fine, total
  FROM public.get_daily_collection_report('kcet20262027', 1,
                                          DATE '2026-09-09', DATE '2026-09-09')
 WHERE fine > 0;
