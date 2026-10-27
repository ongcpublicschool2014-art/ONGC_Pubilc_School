-- ============================================================================
-- reconbalancedue has drifted from what it should be, on a handful of rows.
-- ============================================================================
-- TWO CONVENTIONS, ONE CONCEPT. "What is still outstanding once money that
-- has not cleared the bank is discounted" is computed two ways:
--
--   Pending Payment / Pending Details / Consolidated Status
--       computed live:  balancedue + unreconciled allocations
--   DCB Register / Dashboard
--       stored column:  feedemand.reconbalancedue
--
-- They agree on 12,486 of 12,490 demands. On four they do not, by Rs 11,425,
-- and the stored column is the one that is wrong -- it is a cache of a figure
-- the other reports derive from the payment rows themselves.
--
-- WHERE THE DRIFT CAME FROM.
--
--   Rs 7,825 is from today's two recoveries. import_payment writes paidamount
--   and balancedue but not reconbalancedue, so a recovered receipt left at
--   recon_status 'P' -- deliberately, so it would appear in Bank
--   Reconciliation -- never had its reconciled balance put back:
--       5820  KANNAN D     TUITION FEE    5,125
--       11581 SANDHIYAH T  EXAM FEE       2,550
--       11580 SANDHIYAH T  MISCELLANEOUS    150
--
--   Rs 3,600 is older and different in character: BHUVANESH B's EXAM FEE
--   carries balancedue 4,500 against reconbalancedue 900 with nothing
--   collected at all, which is a demand amount changed without the reconciled
--   column following.
--
-- WHAT THIS DOES. Recomputes reconbalancedue from the payment rows, for the
-- drifted rows only. Rows already correct are untouched, so this is safe to
-- run whether or not anything is wrong.
--
-- NOT a new definition: the formula is lifted from get_pending_payment_report,
-- which is what the other three reports already use.
--
-- Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 0 =
-- What will change, before it changes. Read this first.
-- ===========================================================================

WITH alloc AS (
  SELECT pd.dem_id,
         SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS unrecon
    FROM kcet20262027.paymentdetails pd
    JOIN kcet20262027.payment p    ON p.pay_id = pd.pay_id
    JOIN kcet20262027.feedemand fd ON fd.dem_id = pd.dem_id
   WHERE p.ins_id = 1 AND p.paystatus = 'C'
     AND p.recon_status = 'P' AND p.activestatus = 1
     AND fd.activestatus = 1
   GROUP BY pd.dem_id
)
SELECT fd.dem_id, fd.demno, s.stuadmno, s.stuname, fd.demfeetype,
       fd.feeamount, fd.paidamount, fd.balancedue,
       COALESCE(a.unrecon, 0)                       AS unreconciled,
       fd.reconbalancedue                           AS stored_now,
       fd.balancedue + COALESCE(a.unrecon, 0)       AS will_become,
       fd.balancedue + COALESCE(a.unrecon, 0) - fd.reconbalancedue AS change
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
  LEFT JOIN alloc a ON a.dem_id = fd.dem_id
 WHERE fd.ins_id = 1 AND fd.activestatus = 1
   AND fd.reconbalancedue <> fd.balancedue + COALESCE(a.unrecon, 0)
 ORDER BY abs(fd.balancedue + COALESCE(a.unrecon, 0) - fd.reconbalancedue) DESC;


-- =================================================================== PART 1 =
-- Put them right.
--
-- Only rows that disagree are written, so the UPDATE count IS the number of
-- drifted rows -- if it comes back larger than PART 0 listed, stop and look.
-- ===========================================================================

-- Written as a correlated subquery rather than a CTE join: UPDATE ... FROM
-- cannot LEFT JOIN the way this needs, and a plain join would skip every
-- demand that has no unreconciled payment at all -- which is most of them,
-- and includes BHUVANESH B, whose row is wrong precisely because nothing has
-- been collected against it.
UPDATE kcet20262027.feedemand fd
   SET reconbalancedue = fd.balancedue + COALESCE((
         SELECT SUM(GREATEST(pd.transtotalamount - COALESCE(fd2.fineamount, 0), 0))
           FROM kcet20262027.paymentdetails pd
           JOIN kcet20262027.payment p     ON p.pay_id = pd.pay_id
           JOIN kcet20262027.feedemand fd2 ON fd2.dem_id = pd.dem_id
          WHERE pd.dem_id = fd.dem_id
            AND p.ins_id = 1 AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
            AND fd2.activestatus = 1), 0)
 WHERE fd.ins_id = 1
   AND fd.activestatus = 1
   AND fd.reconbalancedue <> fd.balancedue + COALESCE((
         SELECT SUM(GREATEST(pd.transtotalamount - COALESCE(fd2.fineamount, 0), 0))
           FROM kcet20262027.paymentdetails pd
           JOIN kcet20262027.payment p     ON p.pay_id = pd.pay_id
           JOIN kcet20262027.feedemand fd2 ON fd2.dem_id = pd.dem_id
          WHERE pd.dem_id = fd.dem_id
            AND p.ins_id = 1 AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
            AND fd2.activestatus = 1), 0);


-- ------------------------------------------------------------- VERIFY ------
-- The two conventions must now give the same total. Expect rows_adrift 0 and
-- drift 0.00.
WITH alloc AS (
  SELECT pd.dem_id,
         SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS unrecon
    FROM kcet20262027.paymentdetails pd
    JOIN kcet20262027.payment p    ON p.pay_id = pd.pay_id
    JOIN kcet20262027.feedemand fd ON fd.dem_id = pd.dem_id
   WHERE p.ins_id = 1 AND p.paystatus = 'C'
     AND p.recon_status = 'P' AND p.activestatus = 1
     AND fd.activestatus = 1
   GROUP BY pd.dem_id
)
SELECT COALESCE(SUM(fd.balancedue + COALESCE(a.unrecon, 0)), 0) AS computed,
       COALESCE(SUM(fd.reconbalancedue), 0)                     AS stored,
       COALESCE(SUM(fd.balancedue + COALESCE(a.unrecon, 0)), 0)
         - COALESCE(SUM(fd.reconbalancedue), 0)                 AS drift,
       count(*) FILTER (
         WHERE fd.reconbalancedue <> fd.balancedue + COALESCE(a.unrecon, 0))
                                                                AS rows_adrift
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
  LEFT JOIN alloc a ON a.dem_id = fd.dem_id
 WHERE fd.ins_id = 1 AND fd.activestatus = 1;
