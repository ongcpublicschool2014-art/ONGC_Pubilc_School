-- ============================================================================
-- Move the recovered KANNAN D receipt to TODAY's date.
-- ============================================================================
-- The recovery dated it 11-10-2026 07:04:24, when Paytm actually took the
-- money. The office wants it on today's collection instead, so this moves
-- paydate forward to now.
--
-- WHAT THIS COSTS, so it is a decision and not a surprise:
--   * today's Daily Collection gains Rs 5,125 that the bank credited
--     YESTERDAY;
--   * 11-10's collection stays without it (it never had it);
--   * Bank Reconciliation will match a receipt dated 12-10 against a
--     statement credit dated 11-10. Still matchable -- the Paytm txn id is on
--     the row -- but the dates will not agree, so whoever reconciles should
--     know why.
-- Both dates fall in October, so no month or year total moves.
--
-- The Paytm order id, txn id and the resolution note keep the real capture
-- time, so the audit trail still says when the money actually arrived.
--
-- Identified by payorderid, not by receipt number: the receipt number differs
-- between databases, the order id does not.
-- Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================

DO $redate$
DECLARE v_pay_id bigint; v_no text; v_old timestamp;
BEGIN
  SELECT pay_id, paynumber, paydate INTO v_pay_id, v_no, v_old
    FROM kcet20262027.payment
   WHERE payorderid = 'PAY-3763t1791682464994' AND activestatus = 1;

  IF v_pay_id IS NULL THEN
    RAISE EXCEPTION 'The recovered receipt was not found. Run '
      'tools/recover_PAY3763_kannan.sql first.';
  END IF;

  UPDATE kcet20262027.payment
     SET paydate = localtimestamp
   WHERE pay_id = v_pay_id;

  RAISE NOTICE 'receipt % (pay_id %) moved from % to today',
    v_no, v_pay_id, v_old;
END
$redate$;

-- Keep the note honest about both facts: when the money arrived, and when the
-- receipt is dated.
UPDATE public.webhook_refusal
   SET resolution_note = resolution_note
         || ' Receipt subsequently re-dated to 12-10-2026 at the office''s '
         || 'request; the money itself was captured 11-10 07:04.'
 WHERE order_id = 'PAY-3763t1791682464994'
   AND resolution_note NOT LIKE '%re-dated%';


-- ------------------------------------------------------------- VERIFY ------
SELECT pay_id, paynumber, paydate, transtotalamount, paymethod,
       payorderid, payreference, recon_status
  FROM kcet20262027.payment
 WHERE payorderid = 'PAY-3763t1791682464994';
