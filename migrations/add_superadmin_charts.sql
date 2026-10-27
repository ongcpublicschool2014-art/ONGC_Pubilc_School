-- SuperAdmin dashboard charts: reconciled collection by payment method and by
-- month, aggregated across every active institution's schema. Powers the
-- Collection Overview donut + Monthly Trend bars + Collection-by-Mode donut.
-- Returns {"by_method":{"cash":n,"upi":n,...}, "by_month":{"2026-08":n,...}}.

CREATE OR REPLACE FUNCTION public.get_super_admin_charts(p_yrlabel text DEFAULT NULL) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  rec RECORD;
  v_schema text;
  by_method jsonb := '{}'::jsonb;
  by_month  jsonb := '{}'::jsonb;
  r RECORD;
BEGIN
  FOR rec IN
    SELECT i.ins_id, i.inshortname FROM institution i WHERE i.activestatus = 1
  LOOP
    IF p_yrlabel IS NOT NULL AND p_yrlabel <> '' THEN
      SELECT lower(rec.inshortname) || replace(iy.yrlabel, '-', '') INTO v_schema
      FROM institutionyear iy
      WHERE iy.ins_id = rec.ins_id AND iy.activestatus = 1 AND iy.yrlabel = p_yrlabel LIMIT 1;
    ELSE
      SELECT lower(rec.inshortname) || replace(iy.yrlabel, '-', '') INTO v_schema
      FROM institutionyear iy
      WHERE iy.ins_id = rec.ins_id AND iy.activestatus = 1 ORDER BY iy.iyr_id DESC LIMIT 1;
    END IF;

    IF v_schema IS NULL OR NOT EXISTS (
      SELECT 1 FROM information_schema.tables WHERE table_schema = v_schema AND table_name = 'payment'
    ) THEN
      CONTINUE;
    END IF;

    FOR r IN EXECUTE format(
      'SELECT lower(coalesce(paymethod,'''')) AS m, COALESCE(SUM(transtotalamount),0) AS amt
       FROM %I.payment WHERE ins_id=$1 AND paystatus=''C'' AND recon_status=''R'' AND activestatus=1
       GROUP BY lower(coalesce(paymethod,''''))', v_schema) USING rec.ins_id
    LOOP
      by_method := jsonb_set(by_method, ARRAY[r.m],
        to_jsonb(COALESCE((by_method->>r.m)::numeric, 0) + r.amt), true);
    END LOOP;

    FOR r IN EXECUTE format(
      'SELECT to_char(paydate, ''YYYY-MM'') AS ym, COALESCE(SUM(transtotalamount),0) AS amt
       FROM %I.payment WHERE ins_id=$1 AND paystatus=''C'' AND recon_status=''R'' AND activestatus=1
         AND paydate >= (CURRENT_DATE - INTERVAL ''12 months'')
       GROUP BY to_char(paydate, ''YYYY-MM'')', v_schema) USING rec.ins_id
    LOOP
      by_month := jsonb_set(by_month, ARRAY[r.ym],
        to_jsonb(COALESCE((by_month->>r.ym)::numeric, 0) + r.amt), true);
    END LOOP;
  END LOOP;

  RETURN json_build_object('by_method', by_method, 'by_month', by_month);
END; $$;

GRANT EXECUTE ON FUNCTION public.get_super_admin_charts(text) TO anon, authenticated;
