-- ============================================================================
-- RECOVERY: Rs 2,700 captured by Paytm on 12-10-2026 15:38 with no receipt.
-- ============================================================================
-- WHO. SANDHIYAH T, 421324104044, B.E CSE-III, stu_id 180.
--
--     Paytm order  202610121538040032
--     Paytm txn    20261012011060000316428802083332288
--     RRN          628508598587
--     payer        "Ms S T", VPA sand***006@okicici, Google Pay
--     status       TXN_SUCCESS, resultCode 01
--
-- HOW SHE WAS IDENTIFIED -- four independent facts, not one guess:
--
--   1. She owes EXACTLY this, in the two fees that make it up:
--        dem 11580 DE26/02355 MISCELLANEOUS   150.00 due
--        dem 11581 DE26/02356 EXAM FEE      2,550.00 due
--   2. She has NO payment row of any status on 12-10-2026. Nothing was
--      recorded, so nothing can be double-credited.
--   3. The PARENT APP was running for her (par_id 179, stu_id 180, mobile
--      7305715463) at 15:44:36 -- six minutes after the capture -- and it
--      queried payment WHERE paystatus='I' AND createdat < 15:29:37. That is
--      the orphan-payment sweep: the app looking for a payment that started
--      and never finished.
--   4. "Ms S T" and sand***006@okicici both read as SANDHIYAH T.
--
-- WHY THERE IS NO ROW. The order id 202610121538040032 is date+time+sequence
-- -- the shape a gateway assigns when the caller supplies none. Every id this
-- system makes is PAY-<pay_id>, PAY-<n>t<millis>, MISC<ins>T<millis> or
-- ADV<ins>T<millis>. So this payment never went through create-paytm-order;
-- it came in by QR or payment link, and nothing on our side was written.
--
-- NOT TO BE CONFUSED WITH. AKULA AMULYA (421324104004) paid Rs 2,700 at 16:07
-- the same afternoon, receipted as FC26/03988, txn ...316436045537892244.
-- Different transaction, different student, correctly receipted. The amounts
-- collide because MISCELLANEOUS 150 + EXAM FEE 2,550 is the standard bundle
-- for B.E CSE-III -- which is why the amount alone identified nobody.
--
-- WHAT THIS DOES. Raises the receipt that should have been raised on the day,
-- against both demands, carrying the Paytm order and txn ids so it can never
-- be recovered twice.
--
-- DATED TODAY, not 12-10. The number comes from today's position in the
-- COLLEGE FEES series; back-dating it would put a later number inside an
-- earlier day and every receipt-gap check would flag it from now on. The
-- capture date survives in the Paytm ids and in PART 2's note.
--
-- PART 0 refuses if anything has moved since this was written.
-- Run on LIVE. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 0 =
-- GUARD. Looks only. Refuses unless the world still matches the evidence.
-- ===========================================================================

DO $guard$
DECLARE v_misc numeric; v_exam numeric; v_dup int; v_any int;
BEGIN
  SELECT balancedue INTO v_misc FROM kcet20262027.feedemand
   WHERE dem_id = 11580 AND activestatus = 1;
  SELECT balancedue INTO v_exam FROM kcet20262027.feedemand
   WHERE dem_id = 11581 AND activestatus = 1;

  IF v_misc IS NULL OR v_exam IS NULL THEN
    RAISE EXCEPTION 'Demand 11580 and/or 11581 not found or not active.';
  END IF;
  IF v_misc <> 150.00 OR v_exam <> 2550.00 THEN
    RAISE EXCEPTION 'Balances have moved: MISCELLANEOUS is now %, EXAM FEE is '
      'now % (expected 150.00 and 2550.00). Someone has settled this another '
      'way -- check before recovering, or she is credited twice.', v_misc, v_exam;
  END IF;

  SELECT count(*) INTO v_dup FROM kcet20262027.payment
   WHERE COALESCE(payreference, '') LIKE '%316428802083332288%'
      OR COALESCE(payorderid, '')   =    '202610121538040032';
  IF v_dup > 0 THEN
    RAISE EXCEPTION 'A payment already carries this Paytm transaction. '
      'Already recovered -- nothing to do.';
  END IF;

  SELECT count(*) INTO v_any FROM kcet20262027.payment
   WHERE stu_id = 180 AND createdat::date = DATE '2026-10-12';
  IF v_any > 0 THEN
    RAISE EXCEPTION 'SANDHIYAH T now has % payment row(s) dated 12-10-2026. '
      'She had none when this was written -- look at them before recovering.', v_any;
  END IF;

  RAISE NOTICE 'PART 0 ok: 11580 owes 150, 11581 owes 2550, no receipt carries the txn.';
END
$guard$;


-- =================================================================== PART 1 =
-- Raise the receipt.
--
-- The number comes from the COLLEGE FEES series the same way a counter
-- collection draws it, so the run stays continuous and the counter advances.
-- MISCELLANEOUS and EXAM FEE both belong to that group -- the same series
-- AKULA AMULYA's FC26/03988 came from for the identical two fees.
-- ===========================================================================

DO $recover$
DECLARE
  v_seq_id int; v_cur numeric; v_sequid text; v_width int;
  v_no text; v_yr int; v_yrlabel text; v_res jsonb; v_pay_id bigint;
BEGIN
  SELECT seq_id, seqcurno, sequid, COALESCE(seqwidth::int, 5)
    INTO v_seq_id, v_cur, v_sequid, v_width
    FROM kcet20262027.sequence
   WHERE ins_id = 1 AND activestatus = 1 AND actname = 'COLLEGE FEES'
   ORDER BY seq_id LIMIT 1 FOR UPDATE;
  IF v_seq_id IS NULL THEN
    RAISE EXCEPTION 'No COLLEGE FEES receipt sequence configured.';
  END IF;
  v_cur := COALESCE(v_cur, 0) + 1;
  v_no  := regexp_replace(COALESCE(v_sequid, ''), '\d+$', '')
           || lpad(v_cur::bigint::text, v_width, '0');
  UPDATE kcet20262027.sequence SET seqcurno = v_cur WHERE seq_id = v_seq_id;

  SELECT yr_id, yrlabel INTO v_yr, v_yrlabel
    FROM kcet20262027.year WHERE activestatus = 1 ORDER BY yr_id DESC LIMIT 1;

  v_res := public.import_payment(
    1, '3410', 180, v_yr, v_yrlabel,
    v_no,
    -- DATED TODAY, NOT THE CAPTURE. The receipt number is drawn from today's
    -- position in the COLLEGE FEES series, so dating it 12-10 would drop a
    -- number from the 13th into the middle of the 12th: the register would
    -- show a jump on one day and a gap on the other, and every receipt-gap
    -- check would report it forever. The money's real date is not lost -- the
    -- Paytm order id and txn id below both carry 12-10 15:38, and PART 2 says
    -- so in writing.
    --
    -- AT TIME ZONE 'Asia/Kolkata' because paydate holds a NAIVE timestamp in
    -- IST wall-clock (AKULA AMULYA's 16:07:15 is 4:07 PM at Paytm). now()
    -- alone would cast through the session timezone -- UTC on Supabase -- and
    -- land the receipt five and a half hours early, which near midnight would
    -- put it on the wrong day entirely.
    (now() AT TIME ZONE 'Asia/Kolkata'),
    -- 'Online Transfer', not 'UPI'. The app labels every gateway payment
    -- 'Online Transfer' whatever instrument the payer used; a recovered
    -- receipt must read like the one the app would have written, or it splits
    -- off from its neighbours in any report grouped by mode. The real
    -- instrument stays recoverable from the Paytm txn id below.
    'Online Transfer',
    '20261012011060000316428802083332288',    -- the Paytm txn id
    'RECOVERY',
    '[{"dem_id": 11580, "amount": 150}, {"dem_id": 11581, "amount": 2550}]'::jsonb);

  RAISE NOTICE 'raised receipt % -> %', v_no, v_res;

  -- Stamp the order id so this can never be recovered twice, and tie the row
  -- to the account the money settled into.
  --
  -- recon_status back to 'P'. import_payment stamps 'R' because an imported
  -- receipt is historical and already settled -- but this is live money that
  -- reached the bank on 12-10 and nobody has matched the credit yet. Left at
  -- 'R' it would never appear in Bank Reconciliation, and the one statement
  -- line that proves this recovery was right would sit unmatched for good.
  SELECT pay_id INTO v_pay_id FROM kcet20262027.payment WHERE paynumber = v_no;
  UPDATE kcet20262027.payment
     SET payorderid      = '202610121538040032',
         ban_id          = COALESCE(ban_id, 1),
         paydate         = (now() AT TIME ZONE 'Asia/Kolkata'),
         recon_status    = 'P',
         reconciled_by   = NULL,
         reconciled_date = NULL
   WHERE pay_id = v_pay_id;
  RAISE NOTICE 'stamped pay_id % with the Paytm order id, recon left pending',
    v_pay_id;
END
$recover$;


-- =================================================================== PART 2 =
-- Close any webhook refusal raised for this order. Harmless if there is none
-- -- the capture never reached create-paytm-order, so one may never have been
-- written.
-- ===========================================================================

UPDATE public.webhook_refusal
   SET resolved_at = now(), resolved_by = 'RECOVERY',
       resolution_note = 'Real loss, recovered. Rs 2,700 captured 12-10 15:38 '
         'through a channel outside the app (gateway-assigned order id), so no '
         'cart and no payment row ever existed. Identified as SANDHIYAH T '
         '(421324104044) by an exact 2,700 outstanding across MISCELLANEOUS '
         '150 + EXAM FEE 2,550, no payment row that day, and parent-app '
         'orphan-sweep activity at 15:44. Receipt raised against dem 11580 '
         'and 11581, DATED THE DAY IT WAS RAISED (not 12-10) so the receipt '
         'number stays in step with its series; the money itself was captured '
         '12-10-2026 15:38, which the Paytm order and txn ids on the receipt '
         'both record.'
 WHERE order_id = '202610121538040032' AND resolved_at IS NULL;


-- ------------------------------------------------------------- VERIFY ------
-- Two rows, Rs 150 + Rs 2,550, both demands now at zero, Paytm ids present.

SELECT p.paynumber, p.paydate, p.paymethod, p.transtotalamount,
       p.payorderid, p.payreference, p.recon_status,
       d.dem_id, fd.demno, fd.demfeetype, d.transtotalamount AS line_amount,
       fd.balancedue AS now_due
  FROM kcet20262027.payment p
  JOIN kcet20262027.paymentdetails d ON d.pay_id = p.pay_id
  JOIN kcet20262027.feedemand fd     ON fd.dem_id = d.dem_id
 WHERE p.payorderid = '202610121538040032'
 ORDER BY d.dem_id;
