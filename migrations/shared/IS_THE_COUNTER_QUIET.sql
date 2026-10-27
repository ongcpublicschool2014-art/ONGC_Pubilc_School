-- Read only. Run on LIVE immediately before a migration that replaces a
-- function on the payment path.
--
-- A collection running at the instant CREATE OR REPLACE takes its lock can
-- fail once and need retrying. Nothing is lost -- the number and the row live
-- or die together -- but it is avoidable noise at a counter.
--
-- GO when: last collection is several minutes old, nothing in the last 2
--          minutes, no payment in flight, no other session writing.
-- WAIT when: anything shows activity in the last 2 minutes, or a payment is
--          'I' and less than ~15 minutes old -- someone is mid-checkout.
SELECT 'last collection'                          AS check,
       COALESCE(to_char(max(createdat), 'HH24:MI:SS')
                || '   (' || age(now(), max(createdat))::text || ' ago)',
                'none today') AS value
  FROM kcet20262027.payment WHERE createdat::date = CURRENT_DATE

UNION ALL
SELECT 'collections in the last 2 minutes',
       count(*)::text || CASE WHEN count(*) > 0 THEN '   <-- WAIT' ELSE '   ok' END
  FROM kcet20262027.payment WHERE createdat > now() - interval '2 minutes'

UNION ALL
SELECT 'collections in the last 15 minutes',
       count(*)::text
  FROM kcet20262027.payment WHERE createdat > now() - interval '15 minutes'

UNION ALL
-- A payment sitting at 'I' and only minutes old is someone at the Paytm
-- window right now. Replacing the function under them is what to avoid.
SELECT 'payments IN FLIGHT (I, under 15 min old)',
       count(*)::text || CASE WHEN count(*) > 0 THEN '   <-- WAIT' ELSE '   ok' END
  FROM kcet20262027.payment
 WHERE paystatus = 'I' AND activestatus = 1
   AND createdat > now() - interval '15 minutes'

UNION ALL
-- Other sessions actively running statements against this database.
SELECT 'other sessions running a query',
       count(*)::text || CASE WHEN count(*) > 0 THEN '   <-- check what they are' ELSE '   ok' END
  FROM pg_stat_activity
 WHERE datname = current_database() AND pid <> pg_backend_pid()
   AND state = 'active' AND backend_type = 'client backend'

UNION ALL
SELECT 'misc receipts in the last 2 minutes',
       count(*)::text || CASE WHEN count(*) > 0 THEN '   <-- WAIT' ELSE '   ok' END
  FROM kcet20262027.misc_collection WHERE createdat > now() - interval '2 minutes';
