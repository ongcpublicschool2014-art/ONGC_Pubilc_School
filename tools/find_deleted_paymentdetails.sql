-- ============================================================================
-- Recover 2 deleted paymentdetails rows. READ-ONLY -- nothing here writes.
-- ============================================================================
-- THE ROWS ARE DERIVABLE. A paymentdetails row holds only four facts that
-- matter: which receipt, which demand, how much, for which institution. Every
-- one of them survives the delete somewhere else:
--
--   pay_id    the payment row is untouched, and its total is now larger than
--             the sum of the lines left against it -- by exactly what went
--   dem_id    feedemand is untouched too: paidamount and balancedue live on
--             the demand itself, so the demand still knows it was paid, it
--             just no longer knows which receipt paid it
--   amount    the same figure from both ends, which is what makes this safe
--             -- two independent sources that have to agree
--
-- So the backup not having the row does not matter. It was never the only
-- copy of the information.
--
-- WHAT IS ACTUALLY BROKEN. Not the money. The student's ledger, the demand's
-- balance and the receipt total are all still right. What is broken is the
-- LINK between them -- which shows up in Bank Reconciliation, in Pending
-- Approval, in the DCB Register's receipt column, and in any report that
-- joins payment to feedemand. That is why this is a re-link, not a re-posting.
--
-- Run ONE STEP AT A TIME -- the Supabase editor shows only the last result
-- set. Send me STEP 1 and STEP 2 and I will write the exact INSERT.
-- ============================================================================


-- ---------------------------------------------------------------- STEP 1 ---
-- THE RECEIPT END. Receipts whose lines no longer add up to the receipt.
--
-- `missing` is the rupee value that was deleted from that receipt. With two
-- rows gone you will see either one receipt short by both, or two receipts
-- short by one each.
-- ---------------------------------------------------------------------------

SELECT p.pay_id,
       p.paynumber,
       p.paydate,
       p.stu_id,
       s.stuadmno,
       s.stuname,
       p.transtotalamount                             AS receipt_total,
       COALESCE(SUM(pd.transtotalamount), 0)          AS allocated_now,
       p.transtotalamount - COALESCE(SUM(pd.transtotalamount), 0) AS missing,
       count(pd.pyd_id)                               AS lines_left,
       p.paymethod, p.paystatus, p.recon_status, p.activestatus,
       p.yr_id, p.yrlabel, p.ins_id
  FROM kcet20262027.payment p
  LEFT JOIN kcet20262027.students s ON s.stu_id = p.stu_id
  LEFT JOIN kcet20262027.paymentdetails pd ON pd.pay_id = p.pay_id
 WHERE p.ins_id = 1
 GROUP BY p.pay_id, p.paynumber, p.paydate, p.stu_id, s.stuadmno, s.stuname,
          p.transtotalamount, p.paymethod, p.paystatus, p.recon_status,
          p.activestatus, p.yr_id, p.yrlabel, p.ins_id
HAVING p.transtotalamount <> COALESCE(SUM(pd.transtotalamount), 0)
 ORDER BY p.paydate DESC, p.pay_id DESC;


-- ---------------------------------------------------------------- STEP 2 ---
-- THE DEMAND END. Demands that have been paid but no longer carry a receipt
-- line for all of it.
--
-- This is the half that names dem_id -- the one thing STEP 1 cannot tell you.
-- `unlinked` should match a `missing` from STEP 1, rupee for rupee. Where two
-- demands each show an unlinked amount and one receipt is short by their sum,
-- that is both deleted rows found.
--
-- fineamount is added in because a receipt line carries fee AND fine together
-- while paidamount is the fee alone -- comparing them without it would report
-- every fined demand as unlinked.
-- ---------------------------------------------------------------------------

SELECT fd.dem_id,
       fd.demno,
       s.stuadmno,
       s.stuname,
       fd.demfeetype,
       fd.feeamount,
       fd.paidamount,
       fd.fineamount,
       fd.balancedue,
       fd.paidstatus,
       COALESCE((SELECT SUM(pd.transtotalamount)
                   FROM kcet20262027.paymentdetails pd
                  WHERE pd.dem_id = fd.dem_id), 0)      AS linked_now,
       fd.paidamount + COALESCE(fd.fineamount, 0)
         - COALESCE((SELECT SUM(pd.transtotalamount)
                       FROM kcet20262027.paymentdetails pd
                      WHERE pd.dem_id = fd.dem_id), 0)  AS unlinked,
       fd.yr_id, fd.yrlabel, fd.ins_id
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id
 WHERE fd.ins_id = 1
   AND fd.activestatus = 1
   AND COALESCE(fd.paidamount, 0) > 0
   AND fd.paidamount + COALESCE(fd.fineamount, 0)
       <> COALESCE((SELECT SUM(pd.transtotalamount)
                      FROM kcet20262027.paymentdetails pd
                     WHERE pd.dem_id = fd.dem_id), 0)
 ORDER BY fd.dem_id DESC;


-- ---------------------------------------------------------------- STEP 3 ---
-- Only if STEP 1 and STEP 2 disagree, or either comes back empty.
--
-- Narrow to the student and look at everything at once -- receipts, lines and
-- demands side by side. Put the roll number in.
-- ---------------------------------------------------------------------------

SELECT p.pay_id, p.paynumber, p.paydate, p.transtotalamount AS receipt_total,
       p.paymethod, p.recon_status, p.activestatus,
       pd.pyd_id, pd.dem_id, pd.transtotalamount AS line_amount,
       fd.demno, fd.demfeetype, fd.feeamount, fd.paidamount, fd.balancedue,
       fd.fineamount, fd.paidstatus
  FROM kcet20262027.payment p
  JOIN kcet20262027.students s ON s.stu_id = p.stu_id
  LEFT JOIN kcet20262027.paymentdetails pd ON pd.pay_id = p.pay_id
  LEFT JOIN kcet20262027.feedemand fd ON fd.dem_id = pd.dem_id
 WHERE s.stuadmno = 'PUT-ROLL-NO-HERE'
 ORDER BY p.paydate DESC, p.pay_id DESC, pd.pyd_id;


-- ---------------------------------------------------------------- STEP 4 ---
-- The sequence, so the rebuilt rows get ids that cannot collide.
--
-- pyd_id has both a DEFAULT and the set_pyd_id BEFORE-INSERT trigger, so the
-- INSERT will not supply one -- but if last_value has fallen behind max(pyd_id)
-- (which happens when rows were ever inserted with an explicit id) the next
-- insert fails on the primary key. Better to know that now than mid-repair.
-- ---------------------------------------------------------------------------

SELECT (SELECT MAX(pyd_id) FROM kcet20262027.paymentdetails) AS max_pyd_id,
       last_value                                            AS sequence_at,
       last_value > (SELECT MAX(pyd_id) FROM kcet20262027.paymentdetails)
                                                             AS sequence_is_ahead
  FROM kcet20262027.paymentdetails_pyd_id_seq;
