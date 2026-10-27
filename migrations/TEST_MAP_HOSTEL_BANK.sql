-- ############################################################################
--
--   EduCore360 -- MAP A BANK ACCOUNT TO "HOSTEL FEES"   (TEST ONLY)
--   25-09-2026
--
--   Run the whole file in the SQL editor on the TEST project.
--   It REFUSES to run on live -- see the guard in step 0.
--
-- ----------------------------------------------------------------------------
-- WHY
-- ----------------------------------------------------------------------------
-- kcet20262027.feegroup reads:
--
--     fg_id  fgdesc         ban_id   payment sequences
--       1    COLLEGE FEES      1            1
--       2    HOSTEL FEES     NULL           1     <-- this file
--
-- Fee Collection refuses a collection whose selected dues include a group with
-- no bank account, and it refuses the WHOLE collection, not just that group --
-- a receipt has to be banked somewhere. So with a mess fee on screen nothing at
-- all can be taken, college fees included. That is what "both groups cannot be
-- selected to pay" was.
--
-- BANK_ROUTING_BY_FEEGROUP.sql then stamps every payment with its own group's
-- ban_id, so this mapping is also what decides where hostel money lands.
--
-- ----------------------------------------------------------------------------
-- WHICH ACCOUNT IT PICKS
-- ----------------------------------------------------------------------------
-- 1. a bank whose name mentions HOSTEL or MESS, if one exists;
-- 2. otherwise the institution's first account -- TEST has only IOB, which is
--    also COLLEGE FEES' account.
--
-- (2) is fine for testing the split receipts and nothing else: both groups then
-- bank into the same account, which is exactly what the routing feature exists
-- to stop. The verification at the end says so in as many words when it
-- happens. On live, run LIVE_MAP_HOSTEL_BANK.sql instead -- that one refuses
-- unless a real hostel account exists.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- One UPDATE of one column on one row. Re-running maps the same account again.
-- No payment, demand or receipt row is touched, and nothing already banked
-- moves: ban_id is stamped onto a payment when it is raised, not read back
-- afterwards.
-- ############################################################################

-- ----------------------------------------------------------------------------
-- 0 -- REFUSE TO RUN ANYWHERE BUT TEST
-- ----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public._this_is_the_test_project') IS NULL THEN
    RAISE EXCEPTION
      'This is NOT the TEST project. Nothing was written. On live use LIVE_MAP_HOSTEL_BANK.sql, which insists on a real hostel account.';
  END IF;
END $guard$;


-- ----------------------------------------------------------------------------
-- 1 -- map it
-- ----------------------------------------------------------------------------
DO $map$
DECLARE
  v_fg   int;
  v_ban  int;
  v_name text;
BEGIN
  SELECT fg_id INTO v_fg
    FROM kcet20262027.feegroup
   WHERE ins_id = 1 AND fgdesc ILIKE '%HOSTEL%'
   ORDER BY fg_id LIMIT 1;

  IF v_fg IS NULL THEN
    RAISE EXCEPTION
      'No fee group whose name contains HOSTEL. Nothing was written -- create it in Fee Master first.';
  END IF;

  -- A hostel/mess account if there is one ...
  SELECT ban_id, banname INTO v_ban, v_name
    FROM kcet20262027.bank
   WHERE ins_id = 1 AND activestatus = 1
     AND (banname ILIKE '%HOSTEL%' OR banname ILIKE '%MESS%')
   ORDER BY ban_id LIMIT 1;

  -- ... otherwise whatever account exists, so TEST can collect at all.
  IF v_ban IS NULL THEN
    SELECT ban_id, banname INTO v_ban, v_name
      FROM kcet20262027.bank
     WHERE ins_id = 1 AND activestatus = 1
     ORDER BY ban_id LIMIT 1;
  END IF;

  IF v_ban IS NULL THEN
    RAISE EXCEPTION
      'This institution has no active bank account at all. Nothing was written -- add one in Setup -> Bank Details.';
  END IF;

  UPDATE kcet20262027.feegroup
     SET ban_id = v_ban
   WHERE ins_id = 1 AND fg_id = v_fg;
END $map$;


-- ----------------------------------------------------------------------------
-- 2 -- VERIFY
-- ----------------------------------------------------------------------------
-- Every group with its account, and a plain statement of whether hostel money
-- is now going to land in the college account.
SELECT g.fg_id,
       g.fgdesc,
       g.ban_id,
       b.banname,
       CASE
         WHEN g.ban_id IS NULL THEN 'STILL UNMAPPED - cannot be collected'
         WHEN g.fgdesc ILIKE '%HOSTEL%'
          AND g.ban_id = (SELECT ban_id FROM kcet20262027.feegroup
                           WHERE ins_id = 1 AND fgdesc ILIKE '%COLLEGE%'
                           ORDER BY fg_id LIMIT 1)
           THEN 'SHARES THE COLLEGE ACCOUNT - fine on TEST, wrong on live'
         ELSE 'ok'
       END AS state
  FROM kcet20262027.feegroup g
  LEFT JOIN kcet20262027.bank b ON b.ban_id = g.ban_id
 WHERE g.ins_id = 1
 ORDER BY g.fg_id;
