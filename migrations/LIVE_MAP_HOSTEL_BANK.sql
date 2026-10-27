-- ############################################################################
--
--   EduCore360 -- MAP THE HOSTEL BANK ACCOUNT TO "HOSTEL FEES"   (LIVE)
--   25-09-2026
--
--   Run the whole file in the SQL editor on the LIVE project.
--   It REFUSES to run on TEST, and it REFUSES to run at all until a hostel
--   bank account exists.
--
-- ----------------------------------------------------------------------------
-- WHAT IT DOES
-- ----------------------------------------------------------------------------
-- Points kcet20262027.feegroup's HOSTEL group at the hostel bank account.
-- After BANK_ROUTING_BY_FEEGROUP.sql that mapping is what every hostel receipt
-- is stamped with -- fee collection, misc collection and mess advances alike --
-- so it decides where the money is banked.
--
-- Until it is set, Fee Collection refuses any collection that includes a hostel
-- due, and refuses the whole collection with it: a receipt must have somewhere
-- to be banked.
--
-- ----------------------------------------------------------------------------
-- WHAT IT WILL NOT DO
-- ----------------------------------------------------------------------------
-- It will NOT fall back to the college account. Hostel money in the college
-- account is the single failure this whole feature exists to prevent, and it is
-- not visible afterwards -- the receipt looks correct either way. So if there is
-- no account whose name mentions HOSTEL or MESS, the file stops and writes
-- nothing.
--
-- PREREQUISITE, in the app, before running this:
--   Setup -> Bank Details -> add the hostel account (name it so it contains the
--   word HOSTEL, e.g. "IOB - HOSTEL" / "KCET MESS ACCOUNT").
--
-- If the hostel account is already named something else, edit step 1's match
-- or set v_ban by hand -- do not relax it into "first account found".
--
-- ----------------------------------------------------------------------------
-- SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- One UPDATE of one column on one row. Nothing already banked moves: ban_id is
-- stamped onto a payment when it is raised, never read back afterwards. Payment,
-- demand and receipt rows are untouched.
-- ############################################################################

-- ----------------------------------------------------------------------------
-- 0 -- REFUSE TO RUN ON THE TEST PROJECT
-- ----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public._this_is_the_test_project') IS NOT NULL THEN
    RAISE EXCEPTION
      'This is the TEST project. Nothing was written. Use TEST_MAP_HOSTEL_BANK.sql here, or switch to the live project (URL must read /project/exasnbapvgfeooxyxjas).';
  END IF;
END $guard$;


-- ----------------------------------------------------------------------------
-- 1 -- map it, or stop
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

  SELECT ban_id, banname INTO v_ban, v_name
    FROM kcet20262027.bank
   WHERE ins_id = 1 AND activestatus = 1
     AND (banname ILIKE '%HOSTEL%' OR banname ILIKE '%MESS%')
   ORDER BY ban_id LIMIT 1;

  IF v_ban IS NULL THEN
    RAISE EXCEPTION
      'No active bank account whose name mentions HOSTEL or MESS. NOTHING was written -- add the hostel account in Setup -> Bank Details first. This file will not fall back to the college account.';
  END IF;

  UPDATE kcet20262027.feegroup
     SET ban_id = v_ban
   WHERE ins_id = 1 AND fg_id = v_fg;
END $map$;


-- ----------------------------------------------------------------------------
-- 2 -- VERIFY
-- ----------------------------------------------------------------------------
-- Expect one row per fee group, each with its own -- DIFFERENT -- account.
SELECT g.fg_id,
       g.fgdesc,
       g.ban_id,
       b.banname,
       CASE
         WHEN g.ban_id IS NULL THEN 'UNMAPPED - cannot be collected'
         WHEN g.fgdesc ILIKE '%HOSTEL%'
          AND g.ban_id = (SELECT ban_id FROM kcet20262027.feegroup
                           WHERE ins_id = 1 AND fgdesc ILIKE '%COLLEGE%'
                           ORDER BY fg_id LIMIT 1)
           THEN 'WRONG - hostel is sharing the college account'
         ELSE 'ok'
       END AS state
  FROM kcet20262027.feegroup g
  LEFT JOIN kcet20262027.bank b ON b.ban_id = g.ban_id
 WHERE g.ins_id = 1
 ORDER BY g.fg_id;
