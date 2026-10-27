-- =====================================================================
-- Put FC26/03268 and FC26/03270 into the register as CANCELLED receipts.
--
-- WHY THEY ARE MISSING: not established. complete_payment_grouped draws a
-- number only for a SUCCESSFUL payment -- its own comment says failed rows
-- keep paynumber NULL precisely so a number is not burnt -- so the obvious
-- explanation does not hold. What is certain is that the counter reads 3278
-- against 3,276 numbers in use, so two were drawn and not kept, and both sit
-- immediately before one of JAYASURYA S's receipts. This records that fact
-- without inventing a cause for it.
--
-- NO MONEY IS INVOLVED. A gap means a number was consumed, not that a receipt
-- vanished; every receipt that exists is accounted for and no total changes.
-- They are recorded here only so the register runs unbroken and explains its
-- own gaps to an auditor.
--
-- ATTRIBUTION: both sit immediately before one of JAYASURYA S's receipts
-- (03268 -> 03269 at 18:21, 03270 -> 03271 at 18:51), which is the signature
-- of a first attempt being retried. 03270 is his beyond reasonable doubt.
-- 03268 is inference, not proof -- the record that would have shown the owner
-- was deleted -- and the void reason says so rather than pretending otherwise.
--
-- Written as activestatus 9 / paystatus 'R' / amount 0 with voidedby set,
-- which is exactly the shape Daily Collection already lists as "Cancelled"
-- with no amount, so they appear in the register and in no total.
--
-- Safe to re-run: it refuses if either number already exists.
-- =====================================================================
BEGIN;

DO $$
DECLARE
  v_stu  bigint; v_ins integer; v_yr integer; v_yrl varchar; v_code varchar;
  v_next bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM kcet20262027.payment
              WHERE paynumber IN ('FC26/03268','FC26/03270')) THEN
    RAISE EXCEPTION 'REFUSED: one of these numbers already exists.';
  END IF;

  SELECT s.stu_id, p.ins_id, p.yr_id, p.yrlabel, p.inscode
    INTO v_stu, v_ins, v_yr, v_yrl, v_code
    FROM kcet20262027.payment p
    JOIN kcet20262027.students s ON s.stu_id = p.stu_id
   WHERE p.paynumber = 'FC26/03269';
  IF v_stu IS NULL THEN
    RAISE EXCEPTION 'REFUSED: could not read the reference receipt FC26/03269.';
  END IF;

  -- payment.pay_id is NOT NULL with no default on this table, so it has to
  -- be supplied rather than left to a sequence.
  SELECT COALESCE(MAX(pay_id), 0) + 1 INTO v_next FROM kcet20262027.payment;

  INSERT INTO kcet20262027.payment
    (pay_id, ins_id, inscode, stu_id, yr_id, yrlabel, transtotalamount, transcurrency,
     paydate, paystatus, paymethod, payreference, createdby, paynumber,
     recon_status, activestatus, voidedby, voideddate, voidreason)
  VALUES
    (v_next, v_ins, v_code, v_stu, v_yr, v_yrl, 0, 'INR',
     TIMESTAMP '2026-09-30 12:51:00', 'R', 'Online Transfer', NULL, 'SYSTEM',
     'FC26/03268', 'R', 9, 'SYSTEM', NOW(),
     'Receipt number drawn but never attached to a surviving receipt. No money '
     'was taken against it. Attributed to this student from the timing of the '
     'receipt that followed; the cause was not established.'),
    (v_next + 1, v_ins, v_code, v_stu, v_yr, v_yrl, 0, 'INR',
     TIMESTAMP '2026-09-30 13:20:00', 'R', 'Online Transfer', NULL, 'SYSTEM',
     'FC26/03270', 'R', 9, 'SYSTEM', NOW(),
     'Receipt number drawn but never attached to a surviving receipt. No money '
     'was taken against it. Immediately precedes FC26/03271 for the same '
     'student; the cause was not established.');

  RAISE NOTICE 'FC26/03268 and FC26/03270 recorded as cancelled, amount 0';
END $$;

-- Confirm: both present, cancelled, zero, and the register now has no gaps.
SELECT paynumber, paystatus, transtotalamount, activestatus, voidedby
  FROM kcet20262027.payment
 WHERE paynumber IN ('FC26/03268','FC26/03269','FC26/03270','FC26/03271')
 ORDER BY paynumber;

WITH issued AS (
  SELECT paynumber AS no FROM kcet20262027.payment WHERE paynumber ~ '^FC26/[0-9]+$'
  UNION SELECT mcno FROM kcet20262027.misc_collection WHERE mcno ~ '^FC26/[0-9]+$'
  UNION SELECT advno FROM kcet20262027.advance_collection WHERE advno ~ '^FC26/[0-9]+$'),
n AS (SELECT (split_part(no,'/',2))::int AS seq FROM issued),
span AS (SELECT MIN(seq) lo, MAX(seq) hi FROM n)
SELECT COUNT(*) AS gaps_remaining
  FROM span, generate_series(span.lo, span.hi) g
 WHERE NOT EXISTS (SELECT 1 FROM n WHERE n.seq = g);

-- Review both results, then run:  COMMIT;   (or ROLLBACK; to abandon)
