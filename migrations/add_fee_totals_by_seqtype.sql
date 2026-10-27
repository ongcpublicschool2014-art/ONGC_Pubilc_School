-- Dashboard drill-down: Regular vs Arrear split of demand / paid / outstanding,
-- computed server-side so the Total Fees Due / Total Collected / Outstanding
-- cards don't have to pull every feedemand row to the client.
--
-- Reconciled exactly like public.get_fee_totals:
--   * paid    = SUM(paidamount) − pending-approval allocations (un-realised)
--   * pending = SUM(reconbalancedue)
-- grouped by demseqtype ('ARREAR' → arrear, else regular).
--
-- Returns e.g. {"regular":{"demand":..,"paid":..,"pending":..},
--               "arrear":{"demand":..,"paid":..,"pending":..}}
-- A missing key means that type has no rows (treat as 0 on the client).

CREATE OR REPLACE FUNCTION public.get_fee_totals_by_seqtype(p_ins_id integer) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; r json;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN NULL; END IF;
  EXECUTE format($f$
    WITH pending_alloc AS (
      SELECT pd.dem_id,
             SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee,
             SUM(LEAST(pd.transtotalamount, COALESCE(fd.fineamount,0)))       AS pending_fine
      FROM %1$I.paymentdetails pd
      JOIN %1$I.payment p    ON p.pay_id = pd.pay_id
      JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
      WHERE p.ins_id=$1 AND p.paystatus='C' AND p.recon_status='P' AND p.activestatus=1
        AND fd.activestatus=1
      GROUP BY pd.dem_id
    ),
    agg AS (
      SELECT CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR'
                  THEN 'arrear' ELSE 'regular' END AS seqtype,
             COALESCE(SUM(fd.feeamount),0) AS demand,
             GREATEST(
               COALESCE(SUM(fd.paidamount),0)
                 - COALESCE(SUM(pa.pending_fee),0)
                 - COALESCE(SUM(pa.pending_fine),0), 0) AS paid,
             COALESCE(SUM(fd.reconbalancedue),0) AS pending
      FROM %1$I.feedemand fd
      LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
      WHERE fd.ins_id=$1 AND fd.activestatus=1
      GROUP BY 1
    )
    SELECT json_object_agg(seqtype,
             json_build_object('demand', demand, 'paid', paid, 'pending', pending))
    FROM agg
  $f$, v) INTO r USING p_ins_id;
  RETURN COALESCE(r, '{}'::json);
END; $$;

GRANT EXECUTE ON FUNCTION public.get_fee_totals_by_seqtype(integer) TO anon, authenticated;
