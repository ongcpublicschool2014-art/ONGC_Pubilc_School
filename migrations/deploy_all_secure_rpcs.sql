-- ============================================================================
-- FULL-SECURE DEPLOY (all 3 apps) — RPCs + updated read_lock_schema.
-- Additive/safe: deploys functions only. NOTHING locks until you run the
-- separate ROLLOUT afterwards. Run this whole file once.
-- ============================================================================

-- ============================================================================
-- FIX: multi-institution parents under dual-mode RLS.
-- ============================================================================
-- A parent whose mobile is registered at several institutions has a DIFFERENT
-- par_id in each schema. The parent token carries only ONE (ins_id, par_id), so
-- a `par_id = current_app_par()` policy matched only the home schema and hid the
-- parent's students in every OTHER school. Fix: also carry the parent's MOBILE in
-- the session; RLS resolves the correct par_id per-schema from it (parents is
-- open, so the policy subquery can read it). read_lock_schema's parent predicates
-- are updated to use current_app_parmob() (see read_lockdown_dualmode.sql).
--
-- DB-ONLY — the mobile app is unchanged (it already logs in by mobile; the token
-- just gains par_mob). Existing tokens lack par_mob → parents re-login once to get
-- a scoped token. Deploy this, then the updated read_lock_schema + re-run rollout.
-- ============================================================================

ALTER TABLE public.app_session ADD COLUMN IF NOT EXISTS par_mob text;

-- create_parent_session: store the parent's mobile alongside par_id.
CREATE OR REPLACE FUNCTION public.create_parent_session(
  p_mobile text, p_plain_password text, p_ins_id integer, p_device_id text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_par_id integer; v_token text;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;
  EXECUTE format(
    'SELECT par_id FROM %I.parents WHERE payinchargemob = $1 AND activestatus = 1 '
    '  AND parpassword IS NOT NULL AND parpassword = crypt($2, parpassword) LIMIT 1', v_schema)
  INTO v_par_id USING p_mobile, p_plain_password;
  IF v_par_id IS NULL THEN RAISE EXCEPTION 'Invalid credentials'; END IF;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  INSERT INTO public.app_session(token_hash, use_id, ins_id, par_id, par_mob, role, device_id)
  VALUES (encode(digest(v_token, 'sha256'), 'hex'), NULL, p_ins_id, v_par_id, p_mobile, 'parent', p_device_id);
  RETURN v_token;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_parent_session(text, text, integer, text) TO anon, authenticated;

-- app_pre_request: publish app.ins_id, app.par_id AND app.par_mob from the token.
CREATE OR REPLACE FUNCTION public.app_pre_request() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_token text; v_ins integer; v_par integer; v_mob text;
BEGIN
  BEGIN
    v_token := current_setting('request.headers', true)::json->>'x-app-token';
  EXCEPTION WHEN OTHERS THEN v_token := NULL; END;
  IF v_token IS NULL OR length(v_token) < 16 THEN
    PERFORM set_config('app.ins_id', '', true);
    PERFORM set_config('app.par_id', '', true);
    PERFORM set_config('app.par_mob', '', true);
    RETURN;
  END IF;
  SELECT ins_id, par_id, par_mob INTO v_ins, v_par, v_mob FROM public.app_session
   WHERE token_hash = encode(digest(v_token, 'sha256'), 'hex') AND NOT revoked AND expires_at > now();
  PERFORM set_config('app.ins_id', COALESCE(v_ins::text, ''), true);
  PERFORM set_config('app.par_id', COALESCE(v_par::text, ''), true);
  PERFORM set_config('app.par_mob', COALESCE(v_mob, ''), true);
END; $$;
ALTER ROLE authenticator SET pgrst.db_pre_request = 'public.app_pre_request';

-- Current request's parent mobile (parent sessions only) for cross-schema RLS.
CREATE OR REPLACE FUNCTION public.current_app_parmob() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.par_mob', true), ''); $$;
GRANT EXECUTE ON FUNCTION public.current_app_parmob() TO anon, authenticated;


-- ============================================================================
-- PATH B — parent pre-login flows via SECURITY DEFINER RPCs.  [foundation]
-- ============================================================================
-- Goal: let the parent mobile app do institution-discovery / OTP / password-set
-- WITHOUT reading or writing `parents` directly, so `parents` can finally be
-- RLS-locked (Path A left it open because these pre-token flows touch it).
-- Login itself already has create_parent_session (verifies parpassword → token);
-- post-login the parent reads only their OWN parents row via the par_id RLS policy.
--
-- ADDITIVE + NON-BREAKING: nothing calls these until the Path-B mobile release is
-- wired to them. Deploy them, ship that mobile build, THEN add 'parents' to
-- read_lock_schema's sensitive[] and re-run the rollout. Also a security win on
-- its own: set_parent_password requires a verified OTP (closes today's
-- anon-can-set-any-parent-password hole), and none of these leak parpassword.
-- Requires get_institution_schema (exists). Idempotent (CREATE OR REPLACE).
-- ============================================================================

-- 1) Discover every institution where this mobile is an active parent.
--    Returns ins_id/schema/has_password only — never the password hash itself.
CREATE OR REPLACE FUNCTION public.find_parent_institutions(p_mobile text)
RETURNS TABLE(ins_id integer, schema text, has_password boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r record; v_ins integer; v_has boolean;
BEGIN
  FOR r IN
    SELECT n.nspname AS sch FROM pg_namespace n
    WHERE n.nspname NOT IN ('public','pg_catalog','information_schema','extensions')
      AND n.nspname NOT LIKE 'pg_%'
      AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema=n.nspname AND table_name='parents')
  LOOP
    v_ins := NULL; v_has := NULL;
    BEGIN
      EXECUTE format(
        'SELECT ins_id, (COALESCE(length(parpassword),0) > 0) FROM %I.parents '
        'WHERE payinchargemob=$1 AND activestatus=1 ORDER BY par_id LIMIT 1', r.sch)
      INTO v_ins, v_has USING p_mobile;
    EXCEPTION WHEN OTHERS THEN v_ins := NULL; END;
    IF v_ins IS NOT NULL THEN
      ins_id := v_ins; schema := r.sch; has_password := COALESCE(v_has,false);
      RETURN NEXT;
    END IF;
  END LOOP;
END; $$;
GRANT EXECUTE ON FUNCTION public.find_parent_institutions(text) TO anon, authenticated;

-- 2) Store a client-generated OTP against the parent (server validates existence).
--    Client still sends the SMS; this just records the OTP + returns status so the
--    client can branch (registered vs new account). parotpstatus reset to 0.
CREATE OR REPLACE FUNCTION public.request_parent_otp(p_mobile text, p_ins_id integer, p_otp integer)
RETURNS TABLE(is_found boolean, has_password boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_par integer; v_has boolean;
BEGIN
  is_found := false; has_password := false;
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RETURN NEXT; RETURN; END IF;
  EXECUTE format(
    'SELECT par_id, (COALESCE(length(parpassword),0)>0) FROM %I.parents '
    'WHERE payinchargemob=$1 AND activestatus=1 ORDER BY par_id LIMIT 1', v_schema)
  INTO v_par, v_has USING p_mobile;
  IF v_par IS NULL THEN RETURN NEXT; RETURN; END IF;
  EXECUTE format('UPDATE %I.parents SET parmobotp=$1, parotpstatus=0 WHERE par_id=$2', v_schema)
    USING p_otp, v_par;
  is_found := true; has_password := COALESCE(v_has,false); RETURN NEXT;
END; $$;
GRANT EXECUTE ON FUNCTION public.request_parent_otp(text, integer, integer) TO anon, authenticated;

-- 3) Verify an OTP; on match set parotpstatus=1 and clear the stored OTP.
CREATE OR REPLACE FUNCTION public.verify_parent_otp(p_mobile text, p_ins_id integer, p_otp integer)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_par integer;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RETURN false; END IF;
  EXECUTE format(
    'SELECT par_id FROM %I.parents WHERE payinchargemob=$1 AND parmobotp=$2 AND activestatus=1 '
    'ORDER BY par_id LIMIT 1', v_schema)
  INTO v_par USING p_mobile, p_otp;
  IF v_par IS NULL THEN RETURN false; END IF;
  EXECUTE format('UPDATE %I.parents SET parotpstatus=1, parmobotp=NULL WHERE par_id=$1', v_schema)
    USING v_par;
  RETURN true;
END; $$;
GRANT EXECUTE ON FUNCTION public.verify_parent_otp(text, integer, integer) TO anon, authenticated;

-- 4) Set the parent password (REQUIRES a verified OTP), fanning to peer schemas
--    where the same mobile is registered. The bcrypt trigger hashes parpassword.
CREATE OR REPLACE FUNCTION public.set_parent_password(
  p_mobile text, p_ins_id integer, p_new_password text, p_peer_ins_ids integer[] DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_schema text; v_ok boolean; v_peer integer; v_ps text;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;
  -- Guard: OTP must be verified for this mobile in the primary schema.
  EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.parents WHERE payinchargemob=$1 AND parotpstatus=1 AND activestatus=1)', v_schema)
    INTO v_ok USING p_mobile;
  IF NOT COALESCE(v_ok,false) THEN RAISE EXCEPTION 'OTP not verified'; END IF;
  -- Primary schema: set password (trigger bcrypts) + reset OTP.
  EXECUTE format('UPDATE %I.parents SET parpassword=$1, parmobotp=NULL, parotpstatus=0 WHERE payinchargemob=$2 AND activestatus=1', v_schema)
    USING p_new_password, p_mobile;
  -- Peers (same person, other institutions) — best effort, no OTP re-check.
  IF p_peer_ins_ids IS NOT NULL THEN
    FOREACH v_peer IN ARRAY p_peer_ins_ids LOOP
      BEGIN
        v_ps := get_institution_schema(v_peer);
        IF v_ps IS NOT NULL AND v_ps <> v_schema THEN
          EXECUTE format('UPDATE %I.parents SET parpassword=$1, parmobotp=NULL WHERE payinchargemob=$2 AND activestatus=1', v_ps)
            USING p_new_password, p_mobile;
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
  END IF;
  RETURN true;
END; $$;
GRANT EXECUTE ON FUNCTION public.set_parent_password(text, integer, text, integer[]) TO anon, authenticated;

-- ============================================================================
-- After deploying these + the Path-B mobile release that calls them, lock parents:
--   add 'parents' back to read_lock_schema's sensitive[] (parent scope
--   par_id = current_app_par(); also give it permissive write policies since the
--   RPCs are DEFINER and bypass RLS, so anon writes can then be REVOKED too), then
--   re-run the rollout. Optional hardening: rate-limit verify_parent_otp attempts.
-- ============================================================================


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


-- ============================================================================
-- read_lock_schema v2 — DUAL-MODE reads (admin = whole institution,
--                        parent = only their own students).  [Step 2]
-- ============================================================================
-- A session token carries BOTH ins_id and (for parents) par_id, so
-- app_pre_request publishes BOTH GUCs. An ADMIN session has par_id NULL; a
-- PARENT session has par_id set (and also an ins_id!). The SELECT policy branches:
--   admin  (current_app_par() IS NULL)     -> whole institution   (ins_id match)
--   parent (current_app_par() IS NOT NULL) -> only rows for THEIR students
-- The `current_app_par() IS NULL` guard on the admin branch is exactly what stops
-- a parent (who ALSO has ins_id) from reading the whole institution's data.
--
-- Per-table parent scope:
--   students / feedemand / payment / fee_refund : stu_id ∈ parent's students
--   parentdetail                                : par_id = current_app_par()
--   paymentdetails                              : pay_id ∈ parent's payments
--   fee_refunddetails                           : rf_id  ∈ parent's refunds
--   notification                                : stu_id NULL (broadcast) OR ∈ theirs
--   bank / tempfeedemand / interim_promotion    : ADMIN ONLY (mobile never reads)
--   parents                                     : NOT locked this release (Path A) —
--       login/OTP/discovery read it pre-token; full lock = Path B (login RPCs).
--
-- WRITES: the parent mobile app still writes payment / paymentdetails / parents /
-- notification directly (anon holds grants), so those get permissive write
-- policies here to keep writing working — RLS-on with only a SELECT policy would
-- DENY every INSERT/UPDATE. Tables whose anon writes are already REVOKED
-- (students/parentdetail/feedemand/fee_refund*) need no write policy: the missing
-- grant denies anon, and the SECURITY DEFINER RPCs (owned by postgres) bypass RLS.
-- Write-HARDENING (parent-scoped WITH CHECK / route through RPCs) is a later phase.
--
-- ⚠ Idempotent + additive: this ONLY redefines the helper function. It does NOT
--   change any live policy until read_lock_schema(<schema>) is CALLED (see the
--   ROLLOUT block at the bottom — run that ONLY after the mobile release that
--   sends x-app-token is live on parents' phones, else old app builds see 0 rows).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.read_lock_schema(p_schema text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  t text; pol record; has_ins boolean; v_parent text; v_using text;
  -- `parents` IS locked (Path B): every app's pre-token access to parents now goes
  -- through SECURITY DEFINER RPCs that bypass RLS — mobile (create_parent_session,
  -- find_parent_institutions, request/verify_parent_otp, set_parent_password) and the
  -- public portal (get_portal_student_fees). Parent branch scopes parents by mobile.
  sensitive text[] := ARRAY[
    'students','parents','parentdetail','payment','paymentdetails','feedemand',
    'fee_refund','fee_refunddetails','bank','tempfeedemand','interim_promotion','notification'];
  -- Tables written directly by EITHER app (anon still holds write grants). Reads
  -- stay locked above; permissive write policies just avoid breaking existing
  -- direct-write paths (e.g. desktop tempfeedemand staging). Write-hardening later.
  writable  text[] := ARRAY['payment','paymentdetails','notification','bank','tempfeedemand','interim_promotion'];
BEGIN
  FOREACH t IN ARRAY sensitive LOOP
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema=p_schema AND table_name=t) THEN CONTINUE; END IF;
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', p_schema, t);

    -- Drop legacy allow-all (qual=true) AND any prior app_* policies (idempotent re-run).
    FOR pol IN SELECT policyname FROM pg_policies
       WHERE schemaname=p_schema AND tablename=t
         AND ((permissive='PERMISSIVE' AND qual='true') OR starts_with(policyname,'app_'))
    LOOP EXECUTE format('DROP POLICY %I ON %I.%I', pol.policyname, p_schema, t); END LOOP;

    SELECT EXISTS(SELECT 1 FROM information_schema.columns
                   WHERE table_schema=p_schema AND table_name=t AND column_name='ins_id') INTO has_ins;

    -- Parent-scoping predicate (NULL => admin-only table; a parent session gets 0 rows).
    -- Scope by MOBILE (current_app_parmob()) resolved to par_id IN THIS schema, so a
    -- multi-institution parent (different par_id per school) sees their kids everywhere.
    -- `parents` is open, so the policy subquery can read it. PARIDS = this schema's
    -- par_id(s) for the session's mobile.
    v_parent := CASE t
      WHEN 'students'          THEN format('stu_id IN (SELECT stu_id FROM %1$I.parentdetail WHERE par_id IN (SELECT par_id FROM %1$I.parents WHERE payinchargemob = public.current_app_parmob() AND activestatus=1))', p_schema)
      WHEN 'feedemand'         THEN format('stu_id IN (SELECT stu_id FROM %1$I.parentdetail WHERE par_id IN (SELECT par_id FROM %1$I.parents WHERE payinchargemob = public.current_app_parmob() AND activestatus=1))', p_schema)
      WHEN 'payment'           THEN format('stu_id IN (SELECT stu_id FROM %1$I.parentdetail WHERE par_id IN (SELECT par_id FROM %1$I.parents WHERE payinchargemob = public.current_app_parmob() AND activestatus=1))', p_schema)
      WHEN 'fee_refund'        THEN format('stu_id IN (SELECT stu_id FROM %1$I.parentdetail WHERE par_id IN (SELECT par_id FROM %1$I.parents WHERE payinchargemob = public.current_app_parmob() AND activestatus=1))', p_schema)
      WHEN 'parentdetail'      THEN format('par_id IN (SELECT par_id FROM %1$I.parents WHERE payinchargemob = public.current_app_parmob() AND activestatus=1)', p_schema)
      WHEN 'paymentdetails'    THEN format('pay_id IN (SELECT pay_id FROM %1$I.payment WHERE stu_id IN (SELECT stu_id FROM %1$I.parentdetail WHERE par_id IN (SELECT par_id FROM %1$I.parents WHERE payinchargemob = public.current_app_parmob() AND activestatus=1)))', p_schema)
      WHEN 'fee_refunddetails' THEN format('rf_id IN (SELECT rf_id FROM %1$I.fee_refund WHERE stu_id IN (SELECT stu_id FROM %1$I.parentdetail WHERE par_id IN (SELECT par_id FROM %1$I.parents WHERE payinchargemob = public.current_app_parmob() AND activestatus=1)))', p_schema)
      WHEN 'notification'      THEN format('(stu_id IS NULL OR stu_id IN (SELECT stu_id FROM %1$I.parentdetail WHERE par_id IN (SELECT par_id FROM %1$I.parents WHERE payinchargemob = public.current_app_parmob() AND activestatus=1)))', p_schema)
      WHEN 'parents'           THEN 'payinchargemob = public.current_app_parmob()'
      ELSE NULL   -- bank, tempfeedemand, interim_promotion => admin only
    END;

    IF has_ins THEN
      IF v_parent IS NULL THEN
        v_using := '(public.current_app_par() IS NULL AND ins_id = public.current_app_ins())';
      ELSE
        v_using := format(
          '(public.current_app_par() IS NULL AND ins_id = public.current_app_ins())'
          ' OR (public.current_app_par() IS NOT NULL AND %s)', v_parent);
      END IF;
    ELSE
      -- No ins_id column (not expected for these tables) — require a valid session.
      v_using := 'public.current_app_ins() IS NOT NULL';
    END IF;

    EXECUTE format('CREATE POLICY app_tenant_read ON %I.%I FOR SELECT USING (%s)', p_schema, t, v_using);

    -- Keep the parent app's direct writes working (reads already secured above).
    -- Permissive for now (writes are already open via anon grants); Step 4 tightens.
    IF t = ANY(writable) THEN
      EXECUTE format('CREATE POLICY app_write_ins ON %I.%I FOR INSERT WITH CHECK (true)', p_schema, t);
      EXECUTE format('CREATE POLICY app_write_upd ON %I.%I FOR UPDATE USING (true) WITH CHECK (true)', p_schema, t);
      EXECUTE format('CREATE POLICY app_write_del ON %I.%I FOR DELETE USING (true)', p_schema, t);
    END IF;
  END LOOP;
END; $$;
GRANT EXECUTE ON FUNCTION public.read_lock_schema(text) TO anon, authenticated;

-- ============================================================================
-- ROLLOUT — APPLY the dual-mode policies to every existing institution schema.
-- ⚠⚠ BREAKING for the CURRENT (token-less) mobile builds. Run this block ONLY
--    AFTER the mobile release that sends x-app-token is deployed to parents.
--    Until then, leave it commented out. Re-runnable.
-- ============================================================================
-- DO $rollout$
-- DECLARE s text;
-- BEGIN
--   FOR s IN
--     SELECT nspname FROM pg_namespace
--      WHERE nspname NOT IN ('public','pg_catalog','information_schema','extensions')
--        AND nspname NOT LIKE 'pg_%'
--        AND EXISTS (SELECT 1 FROM information_schema.tables
--                     WHERE table_schema = nspname AND table_name = 'students')
--   LOOP
--     PERFORM public.read_lock_schema(s);
--     RAISE NOTICE 'dual-mode read-locked schema %', s;
--   END LOOP;
-- END $rollout$;
-- NOTIFY pgrst, 'reload schema';

-- ============================================================================
-- ROLLBACK (restore open reads+writes on ONE table if a screen breaks):
--   ALTER TABLE <schema>.<table> DISABLE ROW LEVEL SECURITY;   -- fastest, or:
--   DROP POLICY IF EXISTS app_tenant_read ON <schema>.<table>;
--   DROP POLICY IF EXISTS app_write_ins   ON <schema>.<table>;
--   DROP POLICY IF EXISTS app_write_upd   ON <schema>.<table>;
--   DROP POLICY IF EXISTS app_write_del   ON <schema>.<table>;
--   CREATE POLICY "<table> allow all" ON <schema>.<table> FOR ALL
--     TO anon, authenticated USING (true) WITH CHECK (true);
-- ============================================================================
