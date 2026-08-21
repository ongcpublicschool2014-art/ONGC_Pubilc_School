-- ============================================================================
-- PUBLIC FEE PORTAL (kect_flutter) — scoped SECURITY DEFINER RPCs.
-- ============================================================================
-- The portal is ANONYMOUS (no login/token): a student enters their admission
-- number and pays. It read students/feedemand/parents/parentdetail directly, so
-- the read-lockdown blanked it. These two RPCs let it keep working while those
-- tables stay RLS-locked:
--   * get_portal_student_fees(ins_id, admno) — returns ONLY the entered student's
--     info + fee demands + payer (one student per call — no bulk dump possible).
--   * create_portal_payment(ins_id, stu_id, amount, items) — inserts the temp
--     'I' payment row and RETURNS pay_id (a plain INSERT ... RETURNING is filtered
--     to 0 rows by the SELECT policy when there is no token).
-- The Paytm flow itself is UNCHANGED (create-paytm-order -> get-paytm-payment ->
-- complete_payment_grouped, same as the admin app). Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_portal_student_fees(p_ins_id integer, p_admno text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_student jsonb; v_demands jsonb; v_payer jsonb; v_stu_id bigint;
BEGIN
  IF p_admno IS NULL OR btrim(p_admno) = '' THEN RETURN NULL; END IF;
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RETURN NULL; END IF;

  EXECUTE format(
    'SELECT to_jsonb(t) FROM (SELECT stu_id, stuadmno, stuname, stuclass, courname, stumobile, stuemail, inscode '
    'FROM %I.students WHERE stuadmno=$1 AND activestatus=1 LIMIT 1) t', v_schema)
  INTO v_student USING btrim(p_admno);
  IF v_student IS NULL THEN RETURN NULL; END IF;
  v_stu_id := (v_student->>'stu_id')::bigint;

  EXECUTE format(
    'SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.duedate), ''[]''::jsonb) FROM '
    '(SELECT dem_id, demfeetype, demfeeterm, demfeeyear, yr_id, inscode, feeamount, conamount, '
    'paidamount, fineamount, balancedue, duedate, paidstatus FROM %I.feedemand '
    'WHERE stuadmno=$1 AND activestatus=1) d', v_schema)
  INTO v_demands USING btrim(p_admno);

  EXECUTE format(
    'SELECT to_jsonb(p) FROM (SELECT par_id, payincharge, payinchargemob FROM %I.parents '
    'WHERE par_id IN (SELECT par_id FROM %I.parentdetail WHERE stu_id=$1 AND activestatus=1) '
    'AND activestatus=1 LIMIT 1) p', v_schema, v_schema)
  INTO v_payer USING v_stu_id;

  RETURN jsonb_build_object('student', v_student,
                            'demands', COALESCE(v_demands, '[]'::jsonb),
                            'payer', v_payer);
END; $$;
GRANT EXECUTE ON FUNCTION public.get_portal_student_fees(integer, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_portal_payment(
  p_ins_id integer, p_stu_id bigint, p_amount numeric, p_items jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_inscode text; v_yr_id integer; v_yrlabel text; v_pay_id bigint;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;
  -- Derive inscode + year from the student (server-side — never trust the client).
  EXECUTE format('SELECT inscode, yr_id, yrlabel FROM %I.students WHERE stu_id=$1 AND activestatus=1 LIMIT 1', v_schema)
  INTO v_inscode, v_yr_id, v_yrlabel USING p_stu_id;
  IF v_inscode IS NULL THEN RAISE EXCEPTION 'Student not found'; END IF;

  EXECUTE format(
    'INSERT INTO %I.payment(ins_id, inscode, stu_id, yr_id, yrlabel, transtotalamount, transcurrency, '
    'paydate, paystatus, createdby, recon_status, payitems) '
    'VALUES ($1,$2,$3,$4,$5,$6,''INR'',now(),''I'',''PORTAL'',''P'',$7) RETURNING pay_id', v_schema)
  INTO v_pay_id USING p_ins_id, v_inscode, p_stu_id, COALESCE(v_yr_id, 0), COALESCE(v_yrlabel, ''), p_amount, p_items::text;
  RETURN v_pay_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_portal_payment(integer, bigint, numeric, jsonb) TO anon, authenticated;
