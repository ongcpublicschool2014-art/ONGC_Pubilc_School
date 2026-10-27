-- ============================================================================
-- add_ledger_demseqtype.sql
-- Student Ledger (Reports tab) needs demseqtype + demfeeyear to split the ledger
-- into Regular / Arrear (by year). Adds both columns to get_student_ledger_report.
-- RETURNS TABLE signature changes → DROP + CREATE (CREATE OR REPLACE can't alter
-- the OUT columns). Safe to re-run.
-- ============================================================================
DROP FUNCTION IF EXISTS public.get_student_ledger_report(TEXT, INT, TEXT);

CREATE FUNCTION public.get_student_ledger_report(
    p_schema TEXT, p_ins_id INT, p_stuadmno TEXT
) RETURNS TABLE (
    demfeeterm TEXT, demfeetype TEXT, demseqtype TEXT, demfeeyear TEXT,
    feeamount NUMERIC, conamount NUMERIC, paidamount NUMERIC,
    fineamount NUMERIC, balancedue NUMERIC, reconbalancedue NUMERIC,
    paynumber TEXT, paydate DATE, duedate DATE
) LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format($f$
        SELECT  fd.demfeeterm::TEXT, fd.demfeetype::TEXT,
                COALESCE(fd.demseqtype,'DEMAND')::TEXT, fd.demfeeyear::TEXT,
                fd.feeamount::NUMERIC, fd.conamount::NUMERIC,
                fd.paidamount::NUMERIC, fd.fineamount::NUMERIC,
                fd.balancedue::NUMERIC, fd.reconbalancedue::NUMERIC,
                p.paynumber::TEXT, p.paydate::date, fd.duedate
        FROM    %1$I.feedemand fd
        LEFT JOIN %1$I.payment p ON p.pay_id = fd.pay_id
        WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND fd.stuadmno = %3$L
        ORDER BY fd.duedate
    $f$, p_schema, p_ins_id, p_stuadmno);
END $$;

GRANT EXECUTE ON FUNCTION public.get_student_ledger_report(TEXT, INT, TEXT) TO anon, authenticated;
