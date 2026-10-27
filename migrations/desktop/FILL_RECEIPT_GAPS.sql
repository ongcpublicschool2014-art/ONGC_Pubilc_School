-- =====================================================================
-- Record EVERY missing FC26/ number as a cancelled receipt, so the register
-- runs unbroken. Finds the gaps itself -- no number is hardcoded.
--
-- A gap means a receipt number was drawn and the row holding it was later
-- deleted (see PROTECT_RECEIPTED_PAYMENTS.sql, which stops that happening
-- again). NO MONEY IS INVOLVED: every receipt that exists is accounted for
-- and no total changes. These rows exist only so the register explains its
-- own gaps to an auditor.
--
-- Each is written as activestatus 9 / paystatus 'R' / amount 0 with voidedby
-- set -- the shape Daily Collection already lists as "Cancelled" with no
-- amount -- and attributed to the student on the NEXT receipt in the run,
-- which is the attempt that followed. The void reason says that is inference.
--
-- Safe to re-run: it only fills numbers that are still missing.
-- =====================================================================
DO $$
DECLARE
  r        record;
  v_next   bigint;
  v_filled int := 0;
BEGIN
  SELECT COALESCE(MAX(pay_id), 0) INTO v_next FROM kcet20262027.payment;

  FOR r IN
    WITH issued AS (
      SELECT paynumber AS no FROM kcet20262027.payment  WHERE paynumber ~ '^FC26/[0-9]+$'
      UNION SELECT mcno  FROM kcet20262027.misc_collection   WHERE mcno  ~ '^FC26/[0-9]+$'
      UNION SELECT advno FROM kcet20262027.advance_collection WHERE advno ~ '^FC26/[0-9]+$'
    ),
    n    AS (SELECT (split_part(no,'/',2))::int AS seq FROM issued),
    span AS (SELECT MIN(seq) lo, MAX(seq) hi FROM n),
    gaps AS (
      SELECT g AS seq FROM span, generate_series(span.lo, span.hi) g
       WHERE NOT EXISTS (SELECT 1 FROM n WHERE n.seq = g)
    )
    -- the receipt that follows each gap tells us whose attempt it was
    SELECT gaps.seq,
           (SELECT p.stu_id  FROM kcet20262027.payment p
             WHERE p.paynumber ~ '^FC26/[0-9]+$'
               AND (split_part(p.paynumber,'/',2))::int > gaps.seq
             ORDER BY (split_part(p.paynumber,'/',2))::int LIMIT 1) AS stu_id,
           (SELECT p.paydate FROM kcet20262027.payment p
             WHERE p.paynumber ~ '^FC26/[0-9]+$'
               AND (split_part(p.paynumber,'/',2))::int > gaps.seq
             ORDER BY (split_part(p.paynumber,'/',2))::int LIMIT 1) AS paydate,
           (SELECT p.ins_id  FROM kcet20262027.payment p
             WHERE p.paynumber ~ '^FC26/[0-9]+$'
               AND (split_part(p.paynumber,'/',2))::int > gaps.seq
             ORDER BY (split_part(p.paynumber,'/',2))::int LIMIT 1) AS ins_id,
           (SELECT p.yr_id   FROM kcet20262027.payment p
             WHERE p.paynumber ~ '^FC26/[0-9]+$'
               AND (split_part(p.paynumber,'/',2))::int > gaps.seq
             ORDER BY (split_part(p.paynumber,'/',2))::int LIMIT 1) AS yr_id,
           (SELECT p.yrlabel FROM kcet20262027.payment p
             WHERE p.paynumber ~ '^FC26/[0-9]+$'
               AND (split_part(p.paynumber,'/',2))::int > gaps.seq
             ORDER BY (split_part(p.paynumber,'/',2))::int LIMIT 1) AS yrlabel,
           (SELECT p.inscode FROM kcet20262027.payment p
             WHERE p.paynumber ~ '^FC26/[0-9]+$'
               AND (split_part(p.paynumber,'/',2))::int > gaps.seq
             ORDER BY (split_part(p.paynumber,'/',2))::int LIMIT 1) AS inscode
      FROM gaps ORDER BY gaps.seq
  LOOP
    IF r.stu_id IS NULL THEN
      RAISE NOTICE 'FC26/% skipped: no later receipt to attribute it to',
                   LPAD(r.seq::text, 5, '0');
      CONTINUE;
    END IF;

    v_next := v_next + 1;
    INSERT INTO kcet20262027.payment
      (pay_id, ins_id, inscode, stu_id, yr_id, yrlabel, transtotalamount,
       transcurrency, paydate, paystatus, paymethod, createdby, paynumber,
       recon_status, activestatus, voidedby, voideddate, voidreason)
    VALUES
      (v_next, r.ins_id, r.inscode, r.stu_id, r.yr_id, r.yrlabel, 0, 'INR',
       r.paydate, 'R', 'Online Transfer', 'SYSTEM',
       'FC26/' || LPAD(r.seq::text, 5, '0'), 'R', 9, 'SYSTEM', NOW(),
       'Receipt number drawn but never attached to a surviving receipt. No '
       'money was taken against it. Attributed to the student on the next '
       'receipt in the run; that attribution is inference, not proof.');
    v_filled := v_filled + 1;
  END LOOP;

  RAISE NOTICE '% gap(s) recorded as cancelled receipts', v_filled;
END $$;

-- Confirm the register is now unbroken.
WITH issued AS (
  SELECT paynumber AS no FROM kcet20262027.payment  WHERE paynumber ~ '^FC26/[0-9]+$'
  UNION SELECT mcno  FROM kcet20262027.misc_collection   WHERE mcno  ~ '^FC26/[0-9]+$'
  UNION SELECT advno FROM kcet20262027.advance_collection WHERE advno ~ '^FC26/[0-9]+$'),
n AS (SELECT (split_part(no,'/',2))::int AS seq FROM issued),
span AS (SELECT MIN(seq) lo, MAX(seq) hi FROM n)
SELECT COUNT(*) AS gaps_remaining
  FROM span, generate_series(span.lo, span.hi) g
 WHERE NOT EXISTS (SELECT 1 FROM n WHERE n.seq = g);
