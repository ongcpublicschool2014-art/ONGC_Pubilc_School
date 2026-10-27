-- ############################################################################
--
--   EduCore360 -- THE HOSTEL FEES PAYTM MERCHANT
--   25-09-2026
--
--   Runs on EITHER project. The merchant is a PRODUCTION Paytm account in both
--   cases -- the TEST database is wired to the real gateway, so a payment taken
--   on the test machine is real money. Check paytmStaging before pressing
--   Proceed to Pay there.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS SETS, AND WHY IT IS ON THE BANK ROW
-- ----------------------------------------------------------------------------
-- An online payment settles to a Paytm MERCHANT, and a merchant is registered
-- against one bank account. So the merchant belongs on the bank row, and the
-- fee group reaches it through the account it is already mapped to:
--
--     feegroup.fgdesc = 'HOSTEL FEES'
--        -> feegroup.ban_id      (LIVE_MAP_HOSTEL_BANK.sql / TEST_...)
--           -> bank.paytm_mid    (this file)
--
--   Mens Hostel     Krishn33556941260773   <-- set here
--   College (KCET)  Krishn36335928406501   (already live, per institution)
--
-- The app resolves the fee group's bank first and only falls back to the
-- institution's merchant when the bank names none, so a hostel fee collected
-- online lands in the hostel account and a college fee in the college one.
--
-- ----------------------------------------------------------------------------
-- BEFORE THIS WORKS END TO END
-- ----------------------------------------------------------------------------
-- The edge functions sign each order with that merchant's OWN key, read from
-- their PAYTM_MERCHANTS secret ({"<mid>":"<key>", ...}). Until the hostel MID
-- has an entry there, a hostel online payment is REJECTED server-side. That is
-- the safe failure -- it is refused, not mis-settled -- but it is a refusal the
-- cashier will see, so set the secret first.
--
-- Cash, cheque and DD are unaffected: they are banked by feegroup.ban_id, which
-- needs no merchant at all.
--
-- ----------------------------------------------------------------------------
-- IT WILL NOT GUESS
-- ----------------------------------------------------------------------------
-- If no active bank account names HOSTEL or MESS, the file stops and writes
-- nothing rather than putting the hostel merchant on some other account -- that
-- would route COLLEGE money into the hostel merchant, which is the same mistake
-- in the other direction and just as invisible afterwards.
--
-- Add the account first: Setup -> Bank Details (the screen has a Paytm MID
-- field, so this can equally be typed there instead of run here).
--
-- Safe to re-run: one UPDATE of one column. Nothing already settled moves.
-- ############################################################################

DO $mid$
DECLARE
  v_ban  int;
  v_name text;
BEGIN
  SELECT ban_id, banname INTO v_ban, v_name
    FROM kcet20262027.bank
   WHERE ins_id = 1 AND activestatus = 1
     AND (banname ILIKE '%HOSTEL%' OR banname ILIKE '%MESS%')
   ORDER BY ban_id LIMIT 1;

  IF v_ban IS NULL THEN
    RAISE EXCEPTION
      'No active bank account whose name mentions HOSTEL or MESS. NOTHING was written -- add the hostel account in Setup -> Bank Details first.';
  END IF;

  UPDATE kcet20262027.bank
     SET paytm_mid = 'Krishn33556941260773'
   WHERE ban_id = v_ban;
END $mid$;


-- ----------------------------------------------------------------------------
-- VERIFY
-- ----------------------------------------------------------------------------
-- Expect one row per fee group. Each should name a different account, and the
-- hostel one should carry the Mens Hostel merchant. A group whose merchant is
-- blank falls back to the institution's merchant (the college one).
SELECT g.fg_id,
       g.fgdesc,
       b.banname,
       b.paytm_mid,
       CASE
         WHEN g.ban_id IS NULL THEN 'UNMAPPED - cannot be collected at all'
         WHEN g.fgdesc ILIKE '%HOSTEL%' AND COALESCE(b.paytm_mid,'') = ''
           THEN 'falls back to the institution merchant - online hostel fees settle to COLLEGE'
         WHEN g.fgdesc ILIKE '%HOSTEL%' AND b.paytm_mid = 'Krishn33556941260773'
           THEN 'ok - Mens Hostel merchant'
         ELSE 'ok'
       END AS state
  FROM kcet20262027.feegroup g
  LEFT JOIN kcet20262027.bank b ON b.ban_id = g.ban_id
 WHERE g.ins_id = 1
 ORDER BY g.fg_id;
