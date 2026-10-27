-- Repair feedemand rows whose balancedue no longer matches their own figures.
--
-- The invariant every other function derives:
--     balancedue = GREATEST(feeamount - conamount - paidamount, 0)
--
-- It broke because the OLD process_refund added the refund onto balancedue
-- instead of deriving it. 262790 shows the result: 4,400 owed on a 2,200 fee
-- and 600 owed on a 300 fee, after RF00003 returned the full collection. A
-- demand can never owe more than its own fee, so those are wrong whatever the
-- surrounding refund history turns out to be.
--
-- >>> RUN THE FUNCTION MIGRATIONS FIRST <<<
--     fix_refund_balance_invariant.sql  and  money_invariant_hardening.sql
-- Without them the next refund re-breaks exactly these rows.
--
-- >>> Replace kch20262027 with your schema (4 places). <<<
--
-- Safe to re-run: the UPDATE only touches rows that still violate the
-- invariant, so a second run changes nothing.

-- ---------------------------------------------------------------------------
-- 1) PREVIEW -- every row that will change, and what it becomes.
--    Expect the two 262790 rows: 4,400 -> 2,200 and 600 -> 300.
-- ---------------------------------------------------------------------------
SELECT dem_id, stuadmno, demfeetype,
       feeamount, conamount, paidamount,
       balancedue      AS balance_now,
       GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0) AS balance_after,
       reconbalancedue AS recon_now,
       CASE WHEN COALESCE(paidamount,0) = 0
            THEN GREATEST(feeamount - COALESCE(conamount,0), 0)
            ELSE reconbalancedue END AS recon_after,
       paidstatus
  FROM kch20262027.feedemand
 WHERE activestatus = 1
   AND balancedue
       <> GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0)
 ORDER BY stuadmno, demfeetype;

-- ---------------------------------------------------------------------------
-- 2) APPLY.
--
-- reconbalancedue is only rewritten where paidamount = 0. With nothing
-- collected there is nothing awaiting bank reconciliation, so it must equal
-- the outstanding. Rows that DO carry a collection keep their reconbalancedue
-- untouched: it is a different quantity (it drops at reconciliation, not at
-- collection), and a pending non-cash receipt legitimately leaves it above the
-- balance. Rewriting those would corrupt the DCB and Pending Payment figures.
-- ---------------------------------------------------------------------------
UPDATE kch20262027.feedemand
   SET balancedue = GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0),
       reconbalancedue = CASE
         WHEN COALESCE(paidamount,0) = 0
           THEN GREATEST(feeamount - COALESCE(conamount,0), 0)
         ELSE reconbalancedue END,
       paidstatus = CASE
         WHEN GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0) > 0
         THEN 'U' ELSE 'P' END
 WHERE activestatus = 1
   AND balancedue
       <> GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0);

-- ---------------------------------------------------------------------------
-- 3) VERIFY -- both should return no rows.
-- ---------------------------------------------------------------------------
-- 3a) nothing still violates the invariant
SELECT dem_id, stuadmno, demfeetype, feeamount, conamount, paidamount, balancedue
  FROM kch20262027.feedemand
 WHERE activestatus = 1
   AND balancedue
       <> GREATEST(feeamount - COALESCE(conamount,0) - COALESCE(paidamount,0), 0);

-- 3b) no demand owes more than its own net fee
SELECT dem_id, stuadmno, demfeetype, feeamount, conamount, balancedue
  FROM kch20262027.feedemand
 WHERE activestatus = 1
   AND balancedue > GREATEST(feeamount - COALESCE(conamount,0), 0);

-- ---------------------------------------------------------------------------
-- 4) 262790 after the repair, for a read-back.
-- ---------------------------------------------------------------------------
SELECT dem_id, demfeetype, feeamount, conamount, paidamount, balancedue, paidstatus
  FROM kch20262027.feedemand
 WHERE stuadmno = '262790' AND activestatus = 1
 ORDER BY demfeetype;
