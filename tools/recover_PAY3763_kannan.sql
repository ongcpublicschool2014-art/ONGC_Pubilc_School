-- ============================================================================
-- RECOVERY: ₹5,125 captured by Paytm on 11-10-2026 with no receipt.
-- ============================================================================
-- WHAT HAPPENED. KANNAN D (421324114016) paid ₹5,125 by UPI from the PARENT
-- MOBILE APP at 07:04 on 11-10-2026. Paytm captured it:
--
--     order PAY-3763t1791682464994
--     txn   20261011010930000315937150009205016
--     /v3/order/status -> TXN_SUCCESS, resultCode 01
--
-- The database has no record of it. The webhook noticed and refused to guess:
--
--     webhook_refusal: "Paytm captured money for an order with no record in
--                       the database - cannot tell which fees it was for"
--
-- WHY THERE IS NO ROW. create_pending_payment (the mobile path) begins by
-- DELETING every 'I' payment for that student whose payorderid is blank --
-- and the mobile flow never writes payorderid at all. So when a second
-- attempt was made at 07:07, it deleted the row for the 07:04 payment that
-- had already succeeded, together with its paymentdetails. The 07:07 attempt
-- then failed (order PAY-3764, resultCode 810 ORDER IS CLOSE) and is on file
-- as pay_id 3765 'F' -- which is the "Failed ₹5,125" the Transactions screen
-- shows. That row is NOT this money.
--
-- WHICH FEES IT WAS FOR -- evidence, not inference. The parent's basket
-- survived the delete:
--
--     shoppingcart 127   stu 1108   ₹5,125   created 07:04:17
--       -> shoppingcartdetails 213: dem_id 5820, RF26/05789 TUITION FEE, ₹5,125
--
-- one second before Paytm's capture. And that demand's balance today is
-- exactly ₹5,125 (₹55,000 billed, ₹49,875 paid). One demand, one amount, no
-- allocation to choose.
--
-- WHAT THIS DOES. Raises the receipt that should have been raised: a payment
-- row against dem_id 5820, dated when the money was actually taken, carrying
-- the Paytm order and txn ids so it can never be double-recovered. Then
-- marks both open refusals resolved -- the other one (PAY-3767, ₹2,850) is a
-- false alarm: it was receipted normally as FC26/03894 and the webhook simply
-- arrived mid-completion.
--
-- PART 0 refuses if anything has changed since this was written -- the
-- balance moved, a receipt already carries the txn, or the cart is gone.
-- Run it on LIVE. Do NOT wrap in BEGIN: the editor supplies one.
-- ============================================================================


-- =================================================================== PART 0 =
-- GUARD. Looks only. Refuses unless the world still matches the evidence.
-- ===========================================================================

DO $guard$
DECLARE v_bal numeric; v_dup int; v_cart int; v_fine numeric;
BEGIN
  SELECT balancedue, COALESCE(fineamount, 0) INTO v_bal, v_fine
    FROM kcet20262027.feedemand
   WHERE dem_id = 5820 AND activestatus = 1;
  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Demand 5820 (RF26/05789) not found or not active.';
  END IF;
  IF v_bal <> 5125.00 THEN
    RAISE EXCEPTION 'Demand 5820 balance is now %, not 5125. Someone has already '
      'settled this -- check before recovering, or the student is charged twice.', v_bal;
  END IF;

  SELECT count(*) INTO v_dup FROM kcet20262027.payment
   WHERE payreference LIKE '%315937150009205016%'
      OR payorderid = 'PAY-3763t1791682464994';
  IF v_dup > 0 THEN
    RAISE EXCEPTION 'A payment already carries this Paytm transaction. '
      'Already recovered -- nothing to do.';
  END IF;

  SELECT count(*) INTO v_cart FROM kcet20262027.shoppingcartdetails
   WHERE car_id = 127 AND dem_id = 5820;
  IF v_cart = 0 THEN
    RAISE NOTICE 'Cart 127 no longer names demand 5820 -- proceeding on the '
      'balance match alone (still exactly 5125).';
  END IF;

  RAISE NOTICE 'PART 0 ok: demand 5820 owes 5125, no receipt carries the txn.';
END
$guard$;


-- =================================================================== PART 1 =
-- Raise the receipt.
--
-- The number is drawn from the COLLEGE FEES series the same way a counter
-- collection draws it, so the run stays continuous and the counter advances.
-- import_payment takes the number rather than allocating one, which is why
-- this does it here.
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
    1, '3410', 1108, v_yr, v_yrlabel,
    v_no,
    TIMESTAMP '2026-10-11 07:04:24',          -- when Paytm actually took it
    -- 'Online Transfer', not 'UPI'. Paytm reports the instrument the payer
    -- used; the APP labels every gateway payment 'Online Transfer' whatever
    -- the instrument was. A recovered receipt has to read like the one the
    -- app would have written, or it splits off from its neighbours in any
    -- report that groups by mode. The real instrument stays recoverable from
    -- the Paytm txn id below.
    'Online Transfer',
    '20261011010930000315937150009205016',    -- the Paytm txn id
    'RECOVERY',
    '[{"dem_id": 5820, "amount": 5125}]'::jsonb);

  RAISE NOTICE 'raised receipt % -> %', v_no, v_res;

  -- Stamp the order id so this can never be recovered twice, and tie the row
  -- to the account the money settled into.
  --
  -- recon_status back to 'P'. import_payment stamps 'R' because an imported
  -- receipt is historical and already settled -- but this is live UPI money
  -- that arrived in the bank on 11-10 and nobody has matched the credit yet.
  -- Left at 'R' it would never appear in Bank Reconciliation, and the one
  -- statement line that proves this recovery was right would sit unmatched
  -- for good.
  SELECT pay_id INTO v_pay_id FROM kcet20262027.payment WHERE paynumber = v_no;
  UPDATE kcet20262027.payment
     SET payorderid      = 'PAY-3763t1791682464994',
         ban_id          = COALESCE(ban_id, 1),
         paydate         = TIMESTAMP '2026-10-11 07:04:24',
         recon_status    = 'P',
         reconciled_by   = NULL,
         reconciled_date = NULL
   WHERE pay_id = v_pay_id;
  RAISE NOTICE 'stamped pay_id % with the Paytm order id, recon left pending',
    v_pay_id;
END
$recover$;


-- =================================================================== PART 2 =
-- Close both refusals, with a note saying what each turned out to be.
-- ===========================================================================

UPDATE public.webhook_refusal
   SET resolved_at = now(), resolved_by = 'RECOVERY',
       resolution_note = 'Real loss. Mobile payment captured 11-10 07:04; its '
         'payment row was deleted by create_pending_payment on the 07:07 retry '
         '(blank payorderid). Receipt raised from shoppingcart 127 -> dem_id '
         '5820 RF26/05789 TUITION FEE 5125, back-dated to the capture.'
 WHERE order_id = 'PAY-3763t1791682464994' AND resolved_at IS NULL;

UPDATE public.webhook_refusal
   SET resolved_at = now(), resolved_by = 'RECOVERY',
       resolution_note = 'False alarm: receipted normally as FC26/03894 '
         '(pay_id 3768, txn 20261012010930000316314056789451310). The webhook '
         'arrived mid-completion, before the row carried its reference.'
 WHERE order_id = 'PAY-3767t1791772325837' AND resolved_at IS NULL;


-- ------------------------------------------------------------- VERIFY ------
-- The recovered receipt.
SELECT pay_id, paynumber, paystatus, transtotalamount, paydate, paymethod,
       payorderid, payreference, recon_status
  FROM kcet20262027.payment
 WHERE payorderid = 'PAY-3763t1791682464994';

-- The demand it settled. Expect balance 0, paidstatus P, paid 55000.
SELECT dem_id, demno, demfeetype, feeamount, paidamount, balancedue, paidstatus
  FROM kcet20262027.feedemand WHERE dem_id = 5820;

-- No refusal left open.
SELECT order_id, amount, resolved_at IS NOT NULL AS resolved, resolution_note
  FROM public.webhook_refusal
 WHERE order_id IN ('PAY-3763t1791682464994', 'PAY-3767t1791772325837');
