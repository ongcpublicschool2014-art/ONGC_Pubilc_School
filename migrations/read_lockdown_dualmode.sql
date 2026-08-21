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
