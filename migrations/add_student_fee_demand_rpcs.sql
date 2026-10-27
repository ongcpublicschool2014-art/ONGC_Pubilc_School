-- Student Fee Definition: add/remove a fee for a single student.
-- Powers the "Fee Definition" dialog in Fee Collection (ticking an available
-- class fee creates a demand; unticking an existing one deletes it). Safe to
-- re-run. Run on every institution DB (production + any config.json target).

-- Add a fee the student doesn't yet have, straight into feedemand (approved,
-- collectible) from a classfeedemand template row. The set_dem_id BEFORE-INSERT
-- trigger fills dem_id / demno / demseqtype / fee_id. The NOT EXISTS guard makes
-- it idempotent. Returns the new dem_id, or NULL if the fee already existed.
CREATE OR REPLACE FUNCTION public.add_student_fee_demand(
  p_token text, p_stuadmno text, p_cf_id integer, p_amount numeric
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text; v_dem_id bigint;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
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
       0, COALESCE(cf.cfdduedate, CURRENT_DATE), 1, COALESCE(s.approvedby,'SYSTEM'), true,
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

-- Remove a fee the student no longer needs. Refuses if anything has been
-- collected on it, so a demand money was taken against can never be deleted.
CREATE OR REPLACE FUNCTION public.delete_student_fee_demand(
  p_token text, p_dem_id bigint
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text; v_paid numeric;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  EXECUTE format('SELECT COALESCE(paidamount,0) FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2', v_schema)
    INTO v_paid USING p_dem_id, v_ins;
  IF COALESCE(v_paid,0) > 0 THEN
    RAISE EXCEPTION 'Cannot remove a fee that already has a collection';
  END IF;
  EXECUTE format('DELETE FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2 AND COALESCE(paidamount,0)=0', v_schema)
    USING p_dem_id, v_ins;
END; $$;

GRANT EXECUTE ON FUNCTION public.add_student_fee_demand(text, text, integer, numeric) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_student_fee_demand(text, bigint) TO anon, authenticated;
