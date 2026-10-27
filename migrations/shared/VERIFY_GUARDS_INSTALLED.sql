-- Read-only. Run AFTER LIVE_RECEIPT_FIX_2026_10_01.sql to confirm it landed,
-- since the SQL editor does not always surface NOTICE output.
-- Every row must say OK.
SELECT 'delete guard (single, not doubled)' AS check,
       CASE WHEN prosrc LIKE '%AND paynumber IS NULL AND paynumber IS NULL%' THEN 'DOUBLED - re-run part 1'
            WHEN prosrc LIKE '%pay_id=$1 AND paynumber IS NULL%'             THEN 'OK'
            ELSE 'MISSING' END AS status
  FROM pg_proc WHERE proname='complete_payment_grouped' AND pronamespace='public'::regnamespace
UNION ALL
SELECT 'refuses re-receipting a paid row',
       CASE WHEN prosrc LIKE '%already produced receipt%' THEN 'OK' ELSE 'MISSING' END
  FROM pg_proc WHERE proname='complete_payment_grouped' AND pronamespace='public'::regnamespace
UNION ALL
SELECT 'set_payment_status refuses F/I on a receipt',
       CASE WHEN prosrc LIKE '%already carries receipt%' THEN 'OK' ELSE 'MISSING' END
  FROM pg_proc WHERE proname='set_payment_status' AND pronamespace='public'::regnamespace
UNION ALL
SELECT 'receipt_register() installed',
       CASE WHEN count(*)=1 THEN 'OK' ELSE 'MISSING' END
  FROM pg_proc WHERE proname='receipt_register' AND pronamespace='public'::regnamespace
UNION ALL
SELECT 'check_receipt_gaps() installed',
       CASE WHEN count(*)=1 THEN 'OK' ELSE 'MISSING' END
  FROM pg_proc WHERE proname='check_receipt_gaps' AND pronamespace='public'::regnamespace
UNION ALL
SELECT 'receipt register continuous',
       CASE WHEN count(*)=0 THEN 'OK - no gaps' ELSE count(*)||' GAPS' END
  FROM public.check_receipt_gaps(1);
