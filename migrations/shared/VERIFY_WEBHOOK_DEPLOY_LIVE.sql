-- =====================================================================
-- VERIFY THE paytm-webhook DEPLOY -- READ ONLY.
--
-- Run on LIVE in the Supabase SQL editor. Writes nothing, locks nothing,
-- safe with the counter open. ONE result set on purpose: the editor shows
-- only the last one, so every check is a row of the same query.
--
-- Checks 1-6 are the database side the deployed function depends on. They
-- were shipped by RELEASE_2026_10_03_EVENING.sql, NOT by the 05-10 script,
-- so they should already pass.
--
-- Checks 7-10 are what the deploy actually changes: before it, a misc or
-- advance callback returned early, so the webhook could never raise one of
-- those receipts and every successful one was logged as a false refusal.
-- =====================================================================

WITH fn AS (
  SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.oid
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
)
SELECT * FROM (
  SELECT 1 AS n, 'webhook_find_payment exists' AS check,
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE proname='webhook_find_payment')
              THEN 'ok' ELSE 'MISSING' END AS status,
         '' AS detail
  UNION ALL
  SELECT 2, 'webhook_complete_payment exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE proname='webhook_complete_payment')
              THEN 'ok' ELSE 'MISSING' END, ''
  UNION ALL
  SELECT 3, 'webhook_fail_payment exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE proname='webhook_fail_payment')
              THEN 'ok' ELSE 'MISSING' END, ''
  UNION ALL
  SELECT 4, 'webhook_record_refusal exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE proname='webhook_record_refusal')
              THEN 'ok' ELSE 'MISSING' END, ''
  UNION ALL
  -- The one today's edge function change calls. Without it the new
  -- fall-through logs "unavailable" and the deploy achieves nothing.
  SELECT 5, 'webhook_complete_collection exists',
         CASE WHEN EXISTS (SELECT 1 FROM fn WHERE proname='webhook_complete_collection')
              THEN 'ok' ELSE 'MISSING - the deploy cannot recover misc/advance' END, ''
  UNION ALL
  -- The function authenticates as service_role. If the grant is absent the
  -- call fails at run time even though the function is there.
  SELECT 6, 'service_role may execute it',
         COALESCE((SELECT CASE WHEN has_function_privilege('service_role', oid, 'EXECUTE')
                          THEN 'ok' ELSE 'NOT GRANTED' END
                     FROM fn WHERE proname='webhook_complete_collection' LIMIT 1),
                  'n/a - function missing'), ''
  UNION ALL
  -- Receipts the WEBHOOK raised, as opposed to the counter or the app sweep.
  SELECT 7, 'misc/advance receipts raised by the webhook',
         'info',
         COALESCE((SELECT count(*)::text || ' receipted'
                     FROM public.pending_collection
                    WHERE claimed_by = 'WEBHOOK' AND status = 'C'), '0 receipted')
  UNION ALL
  -- Intents still open past the point a live payment would have resolved.
  -- These are exactly what the webhook now exists to pick up.
  SELECT 8, 'intents open longer than 15 min',
         CASE WHEN (SELECT count(*) FROM public.pending_collection
                     WHERE status = 'I' AND created_at < now() - interval '15 min') = 0
              THEN 'ok' ELSE 'look at these' END,
         (SELECT COALESCE(string_agg(order_id || ' Rs ' || amount, ', '
                                     ORDER BY created_at), 'none')
            FROM public.pending_collection
           WHERE status = 'I' AND created_at < now() - interval '15 min')
  UNION ALL
  -- Money Paytm confirmed that the database would not receipt.
  SELECT 9, 'unresolved refusals',
         CASE WHEN (SELECT count(*) FROM public.webhook_refusal
                     WHERE resolved_at IS NULL) = 0
              THEN 'ok' ELSE 'needs a human' END,
         (SELECT COALESCE(count(*)::text || ' totalling Rs ' ||
                          COALESCE(sum(amount), 0), '0')
            FROM public.webhook_refusal WHERE resolved_at IS NULL)
  UNION ALL
  -- The false ones: a successful misc/advance logged as "no record in the
  -- database" purely because the function returned early. After this deploy
  -- the count must stop growing. Any still open are historical.
  SELECT 10, 'false refusals of the kind this deploy stops',
         'info',
         (SELECT COALESCE(count(*)::text || ' open, newest ' ||
                          COALESCE(max(last_seen)::text, '-'), '0 open')
            FROM public.webhook_refusal
           WHERE resolved_at IS NULL
             AND reason LIKE '%no record in the%database%')
) r ORDER BY n;
