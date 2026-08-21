-- ============================================================================
-- PowerCollege export: add Receipt No (paynumber) + Transaction ID (payreference).
-- ============================================================================
-- The report layout is Roll No, Name, Class, Demand No, Receipt No, Transaction
-- Date, Transaction ID, Payment Mode, Semester, Fee Type, Amount. `docno`
-- already carries the demand number; this adds `paynumber` (receipt) and
-- `payreference` (transaction id) to the returned columns. Idempotent.
-- Run in the Supabase SQL editor.
-- ============================================================================

-- Return columns changed, so the old signature must be dropped first
-- (CREATE OR REPLACE can't alter a function's RETURNS TABLE shape).
DROP FUNCTION IF EXISTS public.get_powercollege_export(text, integer, date, date);

CREATE OR REPLACE FUNCTION public.get_powercollege_export(
  p_schema text,
  p_ins_id integer,
  p_from   date,
  p_to     date
) RETURNS TABLE (
  stuadmno         TEXT,
  stuname          TEXT,
  stuclass         TEXT,
  courname         TEXT,
  paydate          TIMESTAMP,
  paymethod        TEXT,
  docno            TEXT,
  demfeeterm       TEXT,
  demfeetype       TEXT,
  amount           NUMERIC,
  fine             NUMERIC,
  banname          TEXT,
  settlement_id    TEXT,
  settlement_date  TIMESTAMP,
  paynumber        TEXT,
  payreference     TEXT
) LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY EXECUTE format($f$
    SELECT s.stuadmno::TEXT,
           s.stuname::TEXT,
           s.stuclass::TEXT,
           COALESCE(s.courname, '')::TEXT,
           p.paydate,
           COALESCE(p.paymethod, '')::TEXT,
           COALESCE(fd.demno, '')::TEXT,
           COALESCE(fd.demfeeterm, '')::TEXT,
           COALESCE(fd.demfeetype, '')::TEXT,
           GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)::NUMERIC,
           LEAST(pd.transtotalamount, COALESCE(fd.fineamount, 0))::NUMERIC,
           COALESCE(b.banname, '')::TEXT,
           CASE
             WHEN lower(COALESCE(p.paymethod, '')) = 'cash' THEN ''
             ELSE COALESCE(NULLIF(p.bank_reference, ''), NULLIF(p.payreference, ''), p.paynumber, '')
           END::TEXT,
           COALESCE(p.reconciled_date, p.paydate),
           COALESCE(p.paynumber, '')::TEXT,
           COALESCE(p.payreference, '')::TEXT
      FROM %1$I.payment p
      JOIN %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
      JOIN %1$I.feedemand fd      ON fd.dem_id = pd.dem_id
      JOIN %1$I.students s        ON s.stu_id = p.stu_id
      LEFT JOIN %1$I.bank b       ON b.ban_id = p.ban_id
     WHERE p.ins_id = $1
       AND p.activestatus = 1
       AND p.paystatus = 'C'
       AND p.recon_status = 'R'   -- reconciled payments only
       AND p.paydate::date BETWEEN $2 AND $3
     ORDER BY p.paydate, p.pay_id, pd.pyd_id
  $f$, p_schema)
  USING p_ins_id, p_from, p_to;
END $$;

GRANT EXECUTE ON FUNCTION public.get_powercollege_export(text, integer, date, date) TO anon, authenticated;

NOTIFY pgrst, 'reload config';
