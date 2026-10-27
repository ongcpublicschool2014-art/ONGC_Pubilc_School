-- =====================================================================
-- Stop a fee demand being created with no amount.
--
-- WHAT IT FIXES. add_student_fee_demand accepts p_amount = 0 without
-- complaint, writing feeamount 0 and balancedue 0 -- a demand that reads
-- FULLY SETTLED the instant it is created. Nobody is chased, and the
-- billing is absent from every total.
--
-- That is how dem_id 10126 was made on 05-10-2026 11:40:31: one call,
-- amount left blank, and Rs 10,000 collected into it 55 seconds later.
-- The API log shows only THREE calls to this function all that day -- the
-- other two, seven minutes later for another student, carried 100 and
-- 15,200 correctly. So the path is used rarely and a blank goes unseen;
-- there is no volume to make the pattern obvious.
--
-- TWO CHANGES:
--
-- 1. REFUSE A ZERO OR NULL AMOUNT. A fee type a student is not charged
--    is removed, not billed at nothing. GREATEST($2,0) only ever clamped
--    negatives; zero passed straight through.
--
-- 2. RECORD WHO DID IT. createdby was COALESCE(s.approvedby,'SYSTEM'),
--    and approvedby is an EMPTY STRING for many students rather than
--    null -- so COALESCE never fired and the row recorded nobody. 349
--    demands are untraceable that way, 10126 among them. NULLIF makes
--    an empty string fall back to SYSTEM.
--
-- Everything else is unchanged, including the NOT EXISTS guard that
-- stops a duplicate fee type being added.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.add_student_fee_demand(
  p_token text, p_stuadmno text, p_cf_id integer, p_amount numeric
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text; v_dem_id bigint;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  -- A demand billed nothing is not a free fee, it is a missing amount.
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION
      'Enter the amount for this fee. A fee added with no amount is billed 0, '
      'reads as fully settled and is never collected. If the student is not '
      'charged this fee, remove it instead of leaving it blank.';
  END IF;

  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  EXECUTE format($q$
    INSERT INTO %1$I.feedemand
      (ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear,
       demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue,
       paidamount, duedate, activestatus, createdby, collectible,
       cla_id, sem_id, cf_id, fee_id, demseqtype)
    SELECT s.ins_id, s.inscode, s.yr_id, s.stu_id, s.stuadmno, s.stuclass, s.courname,
       s.yrlabel, cf.cfterm, cf.cffeetype, $2, s.con_id, 0, GREATEST($2,0), GREATEST($2,0),
       0, COALESCE(cf.cfdduedate, CURRENT_DATE), 1,
       COALESCE(NULLIF(btrim(s.approvedby), ''), 'SYSTEM'), true,
       cf.cla_id, cf.sem_id, cf.cf_id, cf.fee_id, 'REGULAR'
    FROM %1$I.students s
    JOIN %1$I.classfeedemand cf ON cf.cf_id = $3 AND cf.activestatus = 1
    WHERE s.stuadmno = $1 AND s.activestatus <> 9
      AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd
            WHERE fd.stu_id = s.stu_id AND fd.demfeeterm = cf.cfterm
              AND fd.demfeetype = cf.cffeetype AND fd.activestatus = 1)
    RETURNING dem_id
  $q$, v_schema) INTO v_dem_id USING p_stuadmno, p_amount, p_cf_id;
  RETURN v_dem_id;
END; $$;

-- Verify: a zero amount must now be refused, and the function must still
-- be callable by the app's role.
SELECT has_function_privilege('anon',
         'public.add_student_fee_demand(text,text,integer,numeric)', 'EXECUTE') AS anon_can_call,
       has_function_privilege('authenticated',
         'public.add_student_fee_demand(text,text,integer,numeric)', 'EXECUTE') AS auth_can_call;
