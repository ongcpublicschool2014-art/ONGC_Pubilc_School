-- =====================================================================
-- Read only. Run on LIVE before releasing desktop 0.0.10.
--
-- Answers one question: will anything in 0.0.10 stop working on this database
-- as it stands today?
--
-- Changes nothing. Safe any time, including mid-collection.
--
-- Read the ACTION column. "ship it" on every row means 0.0.10 is safe to
-- release against this database with no SQL run first.
-- =====================================================================
SELECT * FROM (

-- ---------------------------------------------------------------------
-- 1. FEE COLLECTION -- the main counter screen.
--    0.0.10 adds no database dependency here. Fee-group bank routing ships
--    DISABLED (kFeeGroupSettlement is false unless a machine's config.json
--    opts in), so payments resolve the institution merchant exactly as 0.0.9
--    does. Listed so it is on the record, not because it can fail.
-- ---------------------------------------------------------------------
SELECT 1 AS ord,
       'Fee Collection' AS screen,
       'no new dependency - routing ships off' AS finding,
       'ship it' AS action

-- ---------------------------------------------------------------------
-- 2. ADVANCE COLLECTION -- blocked unless every type maps to a fee group.
--    0.0.10 refuses to take an advance whose type is not mapped, because an
--    unmapped advance has no fee group, so no receipt series and no account.
--    An UNMAPPED type that the cashier uses today will stop working.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 2,
       'Advance Collection (' ||
         CASE k.key_suffix WHEN 'A' THEN 'Admission'
                           WHEN 'S' THEN 'Student'
                           ELSE 'Mess' END || ')',
       CASE WHEN COALESCE(trim(s.setting_value), '') = ''
              THEN 'NOT MAPPED - this type will be refused'
            WHEN g.fg_id IS NULL
              THEN 'mapped to fee group ' || s.setting_value || ' which does not exist'
            ELSE 'mapped to ' || g.fgdesc END,
       CASE WHEN COALESCE(trim(s.setting_value), '') = '' OR g.fg_id IS NULL
              THEN 'run SET_ADVANCE_SETTLEMENT_MAPPING.sql first'
            ELSE 'ship it' END
  FROM (VALUES ('A'), ('S'), ('M')) AS k(key_suffix)
  LEFT JOIN public.institution_settings s
         ON s.ins_id = 1
        AND s.setting_key = 'advance_route_fg_' || k.key_suffix
  LEFT JOIN kcet20262027.feegroup g
         ON g.fg_id = NULLIF(trim(s.setting_value), '')::int
        AND g.ins_id = 1 AND g.activestatus = 1

-- ---------------------------------------------------------------------
-- 3. MESS ADVANCE -- needs the advtype CHECK to admit 'M'.
--    The screen offers Mess as a type. If the constraint still allows only
--    'A' and 'S', saving one fails with a constraint violation.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 3,
       'Advance Collection (Mess) - advtype constraint',
       CASE WHEN pg_get_constraintdef(c.oid) LIKE '%''M''%'
            THEN 'allows M' ELSE 'REJECTS M - a mess advance cannot be saved' END,
       CASE WHEN pg_get_constraintdef(c.oid) LIKE '%''M''%'
            THEN 'ship it'
            ELSE 'run PART 1 of LIVE_BANK_ROUTING_BUNDLE.sql first' END
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE n.nspname = 'kcet20262027' AND t.relname = 'advance_collection'
   AND c.conname = 'chk_advance_advtype'

-- ---------------------------------------------------------------------
-- 4. The ban_id fix. NOT a blocker for 0.0.10, but it is the reason real
--    payments get marked FAILED: with payment.ban_id NULL the orphan sweep
--    asks the WRONG Paytm merchant about an order, is told "no such order",
--    and writes the payment off. 0.0.10's sweep fix helps but cannot see an
--    order it is asking the wrong merchant about.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 4,
       'Orphan sweep asks the right Paytm merchant',
       CASE WHEN prosrc LIKE '%razorpay%'
            THEN 'NO - complete_payment_grouped stamps ban_id only for razorpay'
            ELSE 'yes' END,
       CASE WHEN prosrc LIKE '%razorpay%'
            THEN 'not a blocker, but run PART 2 - it is losing receipts'
            ELSE 'ship it' END
  FROM pg_proc
 WHERE proname = 'complete_payment_grouped' AND pronamespace = 'public'::regnamespace

-- ---------------------------------------------------------------------
-- 5. The double-receipt guard, rolled back on live earlier today.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 5,
       'Refuses re-receipting an already-paid row',
       CASE WHEN prosrc LIKE '%already produced receipt%'
            THEN 'yes' ELSE 'NO - a retry can raise a SECOND receipt' END,
       CASE WHEN prosrc LIKE '%already produced receipt%'
            THEN 'ship it'
            ELSE 'not a blocker, but run PART 4' END
  FROM pg_proc
 WHERE proname = 'complete_payment_grouped' AND pronamespace = 'public'::regnamespace

-- ---------------------------------------------------------------------
-- 6. The register, for reassurance.
-- ---------------------------------------------------------------------
UNION ALL
SELECT 6, 'Receipt register continuous',
       (SELECT count(*)::text FROM public.check_receipt_gaps(1)) || ' gaps',
       CASE WHEN (SELECT count(*) FROM public.check_receipt_gaps(1)) = 0
            THEN 'ship it' ELSE 'investigate before releasing' END

) r ORDER BY r.ord, r.screen;
