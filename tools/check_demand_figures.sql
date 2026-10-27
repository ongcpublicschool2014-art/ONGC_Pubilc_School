-- ============================================================================
-- Why the demand / outstanding figures differ between screens.
-- ============================================================================
-- Read-only. Nothing here changes anything.
--
-- Uses only the 3-argument report RPCs, which exist on every database, so it
-- runs on live whether or not the fee-group filter work has been applied.
--
-- Run ONE AT A TIME -- the Supabase editor shows only the last result set.
--
-- Schema is kcet20262027 throughout.
-- ============================================================================


-- ================================================== 1. EVERY FIGURE AT ONCE =
-- One row. Each column is a different definition of the same English word,
-- which is the whole problem: four screens, four definitions.
-- ===========================================================================

WITH active AS (
  SELECT fd.*
    FROM kcet20262027.feedemand fd
    JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
   WHERE fd.ins_id = 1 AND fd.activestatus = 1
),
everyone AS (
  SELECT fd.* FROM kcet20262027.feedemand fd
   WHERE fd.ins_id = 1 AND fd.activestatus = 1
)
SELECT
  -- What the college has billed. The honest "total demand".
  (SELECT COALESCE(SUM(feeamount),0) FROM active)            AS demand_active_students,
  (SELECT COALESCE(SUM(feeamount),0) FROM everyone)          AS demand_incl_leavers,

  -- Two columns that should mean the same thing and do not.
  (SELECT COALESCE(SUM(balancedue),0) FROM active)           AS balancedue,
  (SELECT COALESCE(SUM(reconbalancedue),0) FROM active)      AS reconbalancedue,
  (SELECT count(*) FROM active WHERE balancedue <> reconbalancedue)
                                                             AS rows_that_disagree,

  -- The arithmetic the ledger implies.
  (SELECT COALESCE(SUM(feeamount - conamount - paidamount),0) FROM active)
                                                             AS fee_less_con_less_paid,

  -- What the REPORTS say. Pending Payment and Pending Details both count
  -- collected-but-unreconciled money back as still due.
  (SELECT SUM((e->>'pending')::numeric)
     FROM json_array_elements(
            public.get_pending_payment_report('kcet20262027', 1, 'NOTC')) e)
                                                             AS pending_payment_report,
  (SELECT SUM((e->>'pending')::numeric)
     FROM json_array_elements(
            public.get_pending_details_report('kcet20262027', 1, 'NOTC')) e)
                                                             AS pending_details_report,

  -- And what Pending Details prints as "Total Demand" -- which is the demand
  -- of STUDENTS WHO STILL OWE, not the college's total. A student who has
  -- paid in full is dropped from that report entirely, and their demand with
  -- them.
  (SELECT SUM((e->>'demand')::numeric)
     FROM json_array_elements(
            public.get_pending_details_report('kcet20262027', 1, 'NOTC')) e)
                                                             AS pending_details_demand,

  -- The dashboard cards.
  (public.get_fee_totals(1)->>'total_demand')::numeric        AS dashboard_demand,
  (public.get_fee_totals(1)->>'total_pending')::numeric       AS dashboard_outstanding;


-- ===================================== 2. THE ROWS WHERE THE TWO BALANCES DIFFER =
-- balancedue is what the student owes. reconbalancedue is what they owe once
-- unreconciled receipts are discounted. They drift apart when money has been
-- collected but not yet matched to a bank statement -- so a difference here
-- is usually real and temporary, not corruption.
--
-- Anything where reconbalancedue > balancedue by more than a receipt's worth,
-- or where either is negative, is worth a closer look.
-- ===========================================================================

SELECT fd.dem_id, fd.demno, s.stuadmno, s.stuname, s.stuclass,
       fd.demfeetype, fd.feeamount, fd.conamount, fd.paidamount,
       fd.balancedue, fd.reconbalancedue,
       (fd.reconbalancedue - fd.balancedue) AS difference,
       fd.paidstatus
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
 WHERE fd.ins_id = 1 AND fd.activestatus = 1
   AND fd.balancedue <> fd.reconbalancedue
 ORDER BY abs(fd.reconbalancedue - fd.balancedue) DESC, fd.dem_id;


-- ========================== 3. DEMANDS WHOSE ARITHMETIC DOES NOT ADD UP =
-- balancedue should be feeamount - conamount - paidamount. Where it is not,
-- something wrote one of the columns without the others -- and THAT is the
-- kind of wrong that does not fix itself.
--
-- An empty result here means the ledger is internally consistent and the
-- differences between screens are definitional, not data corruption.
-- ===========================================================================

SELECT fd.dem_id, fd.demno, s.stuadmno, s.stuname,
       fd.demfeetype, fd.feeamount, fd.conamount, fd.paidamount, fd.balancedue,
       (fd.feeamount - fd.conamount - fd.paidamount) AS should_be,
       fd.balancedue - (fd.feeamount - fd.conamount - fd.paidamount) AS out_by
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
 WHERE fd.ins_id = 1 AND fd.activestatus = 1
   AND fd.balancedue <> (fd.feeamount - fd.conamount - fd.paidamount)
 ORDER BY abs(fd.balancedue - (fd.feeamount - fd.conamount - fd.paidamount)) DESC
 LIMIT 100;


-- ============================ 4. WHAT PENDING DETAILS LEAVES OUT =
-- The students that report never shows, because they owe nothing. Their
-- demand is missing from its "Total Demand" column -- this is the gap between
-- that column and the real total.
-- ===========================================================================

SELECT count(DISTINCT s.stu_id)        AS fully_paid_students,
       COALESCE(SUM(fd.feeamount),0)   AS their_demand,
       COALESCE(SUM(fd.paidamount),0)  AS their_collection
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
 WHERE fd.ins_id = 1 AND fd.activestatus = 1
   AND s.stu_id NOT IN (
         SELECT fd2.stu_id FROM kcet20262027.feedemand fd2
          WHERE fd2.ins_id = 1 AND fd2.activestatus = 1
            AND COALESCE(fd2.balancedue, 0) <> 0);


-- ======================================= 5. DEMAND BY FEE GROUP AND KIND =
-- Where the money actually sits. Useful for checking a filtered report:
-- filter the screen to one group and its total should equal the line here.
-- ===========================================================================

SELECT COALESCE(fg.fgdesc, '(no group)')                   AS fee_group,
       COALESCE(NULLIF(TRIM(ft.type), ''), '(no type)')    AS fee_kind,
       count(*)                                            AS demands,
       COALESCE(SUM(fd.feeamount), 0)                      AS demand,
       COALESCE(SUM(fd.paidamount), 0)                     AS collected,
       COALESCE(SUM(fd.balancedue), 0)                     AS balance
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
  LEFT JOIN kcet20262027.feetype  ft ON ft.fee_id = fd.fee_id
  LEFT JOIN kcet20262027.feegroup fg ON fg.fg_id  = ft.fg_id
 WHERE fd.ins_id = 1 AND fd.activestatus = 1
 GROUP BY ROLLUP (fg.fgdesc, COALESCE(NULLIF(TRIM(ft.type), ''), '(no type)'))
 ORDER BY 1 NULLS LAST, 2 NULLS LAST;
