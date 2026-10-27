-- SuperAdmin dashboard: add Total Concession + Total Misc Collection per
-- institution. Concession = SUM(feedemand.conamount); Misc = SUM(misc_collection
-- .totalamount) (table guarded — older schemas may not have it).

CREATE OR REPLACE FUNCTION public.get_super_admin_dashboard(p_yrlabel text DEFAULT NULL) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  rec RECORD;
  v_schema text;
  v_demand numeric;
  v_collected numeric;
  v_pending numeric;
  v_concession numeric;
  v_misc numeric;
  v_fine numeric;
  v_transactions int;
  v_students int;
  results json;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _sa_dashboard (
    ins_id int, insname text, inscode text, inshortname text, inslogo text,
    activestatus int, total_demand numeric, total_collected numeric,
    total_pending numeric, total_concession numeric, total_misc numeric,
    total_fine numeric, transaction_count int, student_count int
  ) ON COMMIT DROP;

  TRUNCATE _sa_dashboard;

  FOR rec IN
    SELECT i.ins_id, i.insname, i.inscode, i.inshortname, i.inslogo, i.activestatus
    FROM institution i WHERE i.activestatus = 1 ORDER BY i.ins_id
  LOOP
    v_demand := 0; v_collected := 0; v_pending := 0; v_concession := 0; v_misc := 0;
    v_fine := 0; v_transactions := 0; v_students := 0;

    IF p_yrlabel IS NOT NULL AND p_yrlabel <> '' THEN
      SELECT lower(rec.inshortname) || replace(iy.yrlabel, '-', '') INTO v_schema
      FROM institutionyear iy
      WHERE iy.ins_id = rec.ins_id AND iy.activestatus = 1 AND iy.yrlabel = p_yrlabel LIMIT 1;
    ELSE
      SELECT lower(rec.inshortname) || replace(iy.yrlabel, '-', '') INTO v_schema
      FROM institutionyear iy
      WHERE iy.ins_id = rec.ins_id AND iy.activestatus = 1 ORDER BY iy.iyr_id DESC LIMIT 1;
    END IF;

    IF v_schema IS NOT NULL AND EXISTS (
      SELECT 1 FROM information_schema.tables WHERE table_schema = v_schema AND table_name = 'feedemand'
    ) THEN
      -- Collection matches get_fee_totals EXACTLY (what the institution admin
      -- sees): gross SUM(paidamount) − pending-approval fee − pending-approval
      -- fine (keeps the reconciled fine portion in the collected figure).
      -- Pending = SUM(reconbalancedue). Concession = SUM(conamount).
      EXECUTE format('SELECT COALESCE(SUM(feeamount),0), COALESCE(SUM(paidamount),0), COALESCE(SUM(reconbalancedue),0), COALESCE(SUM(conamount),0), COALESCE(SUM(fineamount) FILTER (WHERE paidstatus=''P'' OR paidamount > 0),0) FROM %I.feedemand WHERE ins_id=$1 AND activestatus=1', v_schema)
      INTO v_demand, v_collected, v_pending, v_concession, v_fine USING rec.ins_id;
      DECLARE
        v_pa_fee numeric := 0;
        v_pa_fine numeric := 0;
      BEGIN
        EXECUTE format('
          SELECT COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)),0),
                 COALESCE(SUM(LEAST(pd.transtotalamount, COALESCE(fd.fineamount,0))),0)
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id=$1 AND p.paystatus=''C'' AND p.recon_status=''P'' AND p.activestatus=1
            AND fd.activestatus=1
        ', v_schema) INTO v_pa_fee, v_pa_fine USING rec.ins_id;
        v_collected := GREATEST(v_collected - v_pa_fee - v_pa_fine, 0);
        v_fine := GREATEST(v_fine - v_pa_fine, 0);
      END;

      -- Miscellaneous collection (table absent in older schemas → 0).
      IF EXISTS (
        SELECT 1 FROM information_schema.tables WHERE table_schema = v_schema AND table_name = 'misc_collection'
      ) THEN
        EXECUTE format('SELECT COALESCE(SUM(totalamount),0) FROM %I.misc_collection WHERE ins_id=$1 AND activestatus=1', v_schema)
        INTO v_misc USING rec.ins_id;
      END IF;

      EXECUTE format('SELECT COUNT(*) FROM %I.payment WHERE ins_id=$1 AND paystatus=''C'' AND activestatus=1', v_schema)
      INTO v_transactions USING rec.ins_id;
      EXECUTE format('SELECT COUNT(*) FROM %I.students WHERE ins_id=$1 AND activestatus=1', v_schema)
      INTO v_students USING rec.ins_id;
    END IF;

    INSERT INTO _sa_dashboard VALUES (
      rec.ins_id, rec.insname, rec.inscode, rec.inshortname, rec.inslogo,
      rec.activestatus, v_demand, v_collected, v_pending, v_concession, v_misc,
      v_fine, v_transactions, v_students
    );
  END LOOP;

  SELECT json_agg(row_to_json(t)) INTO results FROM _sa_dashboard t;
  RETURN COALESCE(results, '[]'::json);
END; $$;
