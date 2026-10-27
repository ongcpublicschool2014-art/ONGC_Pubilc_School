-- ############################################################################
--
--   READ-ONLY CHECK -- is LIVE ready for the public fee portal (the website)?
--
--   Run the whole thing in the Supabase SQL editor on the LIVE project
--   (exasnbapvgfeooxyxjas). It reads catalog tables only: it creates nothing,
--   changes nothing and touches no student, demand, payment or receipt row.
--
--   The website was pointing at a DIFFERENT, older project
--   (ohbjbiwrjykdugbrimxe) until 23-09-2026. Pointing it at live only works if
--   live carries the objects the portal calls with the public `anon` key. This
--   says whether it does.
--
--   Every row must read OK. Anything else is listed under WHAT TO DO at the
--   bottom of this file.
--
-- ############################################################################

WITH fn AS (
  SELECT p.oid,
         p.proname,
         pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('get_portal_student_fees',
                       'create_portal_payment',
                       'complete_payment_grouped')
),
need_fn (ord, name) AS (
  VALUES (1, 'get_portal_student_fees'),   -- student + demand lookup
         (2, 'create_portal_payment'),     -- the temp 'I' payment row
         (3, 'complete_payment_grouped')   -- receipt + demand settlement
),
need_tbl (ord, tab, why) AS (
  VALUES (1, 'public.institution',         'institution dropdown'),
         (2, 'public.institutionyear',     'resolves the active year schema'),
         (3, 'public.paytm_configuration', 'per-institution Paytm MID')
)
SELECT * FROM (

  -- 1 -- the three RPCs the portal calls, and anon's right to execute them
  SELECT n.ord                                   AS ord,
         '1. RPC'                                AS part,
         CASE WHEN f.oid IS NULL                                  THEN 'MISSING'
              WHEN has_function_privilege('anon', f.oid, 'EXECUTE') THEN 'OK'
              ELSE 'NO EXECUTE FOR anon'
         END                                     AS status,
         n.name || '(' || COALESCE(f.args, '?') || ')' AS detail
    FROM need_fn n
    LEFT JOIN fn f ON f.proname = n.name

  UNION ALL

  -- 2 -- the three tables the portal SELECTs directly
  SELECT t.ord,
         '2. TABLE',
         CASE WHEN to_regclass(t.tab) IS NULL                                  THEN 'MISSING'
              WHEN has_table_privilege('anon', to_regclass(t.tab), 'SELECT')   THEN 'OK'
              ELSE 'NO SELECT FOR anon'
         END,
         t.tab || '  -- ' || t.why
    FROM need_tbl t

  UNION ALL

  -- 3 -- RLS: a table with RLS on and no policy returns 0 rows to anon, which
  --      looks exactly like "student not found" rather than an error.
  SELECT t.ord,
         '3. RLS',
         CASE WHEN to_regclass(t.tab) IS NULL THEN 'MISSING'
              WHEN NOT c.relrowsecurity      THEN 'RLS off (anon reads all)'
              WHEN p.n > 0                   THEN 'RLS on, ' || p.n || ' policy(ies)'
              ELSE 'RLS ON WITH NO POLICY -- READS 0 ROWS'
         END,
         t.tab
    FROM need_tbl t
    LEFT JOIN pg_class c ON c.oid = to_regclass(t.tab)
    LEFT JOIN LATERAL (SELECT count(*) AS n FROM pg_policies
                        WHERE schemaname || '.' || tablename = t.tab) p ON TRUE

  UNION ALL

  -- 4 -- which MID each institution's money would settle to. The website's
  --      own fallback is Krishn06051431858637 and is used ONLY when an
  --      institution has no active row here.
  SELECT 10 + row_number() OVER (ORDER BY pc.institution_id),
         '4. PAYTM MID',
         CASE WHEN pc.is_active THEN 'ACTIVE' ELSE 'inactive' END,
         'ins_id ' || pc.institution_id || ' -> ' || pc.merchant_id
           || '  (website=' || pc.website || ')'
    FROM public.paytm_configuration pc

) z
ORDER BY part, ord;

-- ############################################################################
-- WHAT TO DO ABOUT EACH RESULT
-- ############################################################################
--
--  1. RPC ... MISSING
--       The portal cannot look a student up or take a payment at all. Deploy
--       migrations/secure_portal_rpcs.sql (or deploy_all_secure_rpcs.sql) to
--       live, then re-run this check.
--
--  1. RPC ... NO EXECUTE FOR anon
--       The function is there but the website cannot call it. Grant it:
--         GRANT EXECUTE ON FUNCTION public.get_portal_student_fees(integer, text)
--            TO anon, authenticated;
--       and the same for create_portal_payment / complete_payment_grouped,
--       matching the argument list the query printed.
--
--  2. TABLE ... NO SELECT FOR anon
--       The institution dropdown comes up empty, or the year schema resolves
--       to a wrong name and the payment update silently no-ops.
--
--  3. RLS ... RLS ON WITH NO POLICY
--       The worst case to debug: no error, just zero rows, so the site reports
--       "student not found" for every roll number. Needs a SELECT policy for
--       anon on that table.
--
--  4. PAYTM MID
--       Confirm each institution settles to its OWN merchant. An institution
--       with no row here falls back to the website's compiled-in
--       Krishn06051431858637 -- which is NOT the MID the desktop app uses
--       (Krishn36335928406501). If a unit is missing here, money lands in the
--       wrong sub-account.
--
--  NOT VISIBLE FROM SQL -- check these in the dashboard:
--       * Edge Functions: create-paytm-order and get-paytm-payment must both be
--         DEPLOYED on live, with the secrets PAYTM_MERCHANTS (or PAYTM_MID +
--         PAYTM_MERCHANT_KEY), PAYTM_WEBSITE and PAYTM_HOST set. Without them
--         the checkout refuses with "No merchant key configured for MID ...".
--       * Settings -> API -> Exposed schemas must include the per-year schemas
--         (e.g. kcet2627) for the portal's payorderid update. That update is
--         wrapped in a try/catch and is non-fatal, so this one is cosmetic.
--       * Storage: bucket app-updates must be public, so maintenance.json is
--         reachable. The site now reads it from THIS project.
-- ############################################################################
