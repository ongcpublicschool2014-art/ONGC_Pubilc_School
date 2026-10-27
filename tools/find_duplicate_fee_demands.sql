-- ============================================================================
-- Students billed the same fee twice.
-- ============================================================================
-- Read-only. Run either block on its own -- the Supabase SQL editor shows only
-- the LAST result set, so running the file end to end hides the summary.
--
-- WHAT COUNTS AS THE SAME FEE: same student, same fee type, same term, same
-- year, AND the same kind of demand. An ARREAR and a REGULAR for one fee type
-- are two different debts -- last year's unpaid balance and this year's bill --
-- so they are never grouped together, and two arrears raised for different
-- original classes are kept apart by arrearclass.
--
-- NOT EVERY GROUP IS A MISTAKE. A fee can legitimately be raised twice: two
-- instalments, or a top-up billed separately. Those look different from a true
-- duplicate, so each group gets a verdict rather than a flag:
--
--   LIKELY DUPLICATE  - the rows bill the SAME amount and at most one has
--                       taken money. One is almost certainly a re-import.
--   CHECK - BOTH PAID - more than one has collections against it. Never merge
--                       these blindly; money is attached to both.
--   LIKELY INSTALMENTS- the amounts differ, which is what a split bill or a
--                       top-up looks like. Usually correct.
--
-- Change the schema name if you are looking at another institution-year.
-- ============================================================================

-- ------------------------------------------------------------- SUMMARY ----
WITH g AS (
  SELECT stu_id,
         demfeetype,
         demfeeterm,
         yr_id,
         -- demfeeyear as well as yr_id: an arrear carries the year it came
         -- from as a LABEL and often has a null yr_id, so two arrears from
         -- different years would otherwise collapse into one "duplicate".
         COALESCE(demfeeyear, '')               AS demfeeyear_k,
         (COALESCE(demseqtype, '') = 'ARREAR')  AS is_arrear,
         COALESCE(arrearclass, '')              AS arrearclass,
         count(*)                               AS n,
         count(DISTINCT feeamount)              AS distinct_amounts,
         count(*) FILTER (WHERE COALESCE(paidamount, 0) > 0) AS n_paid,
         sum(feeamount)                         AS billed,
         sum(COALESCE(paidamount, 0))           AS paid
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
   GROUP BY 1, 2, 3, 4, 5, 6, 7
  HAVING count(*) > 1
)
SELECT CASE
         WHEN n_paid > 1            THEN 'CHECK - BOTH PAID'
         WHEN distinct_amounts = 1  THEN 'LIKELY DUPLICATE'
         ELSE                            'LIKELY INSTALMENTS'
       END                                   AS verdict,
       count(*)                              AS groups,
       sum(n)                                AS demand_rows,
       count(DISTINCT stu_id)                AS students,
       to_char(sum(billed), 'FM99999999990') AS billed_total,
       to_char(sum(paid),   'FM99999999990') AS paid_total
  FROM g
 GROUP BY 1
 ORDER BY 2 DESC;

-- -------------------------------------------------------------- DETAIL ----
-- One line per demand in every duplicated group, newest group first.
WITH g AS (
  SELECT stu_id,
         demfeetype,
         demfeeterm,
         yr_id,
         -- demfeeyear as well as yr_id: an arrear carries the year it came
         -- from as a LABEL and often has a null yr_id, so two arrears from
         -- different years would otherwise collapse into one "duplicate".
         COALESCE(demfeeyear, '')               AS demfeeyear_k,
         (COALESCE(demseqtype, '') = 'ARREAR')  AS is_arrear,
         COALESCE(arrearclass, '')              AS arrearclass,
         count(*)                               AS n,
         count(DISTINCT feeamount)              AS distinct_amounts,
         count(*) FILTER (WHERE COALESCE(paidamount, 0) > 0) AS n_paid,
         max(createdat)                         AS newest
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
   GROUP BY 1, 2, 3, 4, 5, 6, 7
  HAVING count(*) > 1
)
SELECT CASE
         WHEN g.n_paid > 1           THEN 'CHECK - BOTH PAID'
         WHEN g.distinct_amounts = 1 THEN 'LIKELY DUPLICATE'
         ELSE                             'LIKELY INSTALMENTS'
       END                          AS verdict,
       f.stuadmno                   AS roll_no,
       s.stuname,
       f.stuclass,
       f.demfeetype,
       f.demfeeterm,
       f.demfeeyear,
       f.demno,
       f.demseqtype,
       f.feeamount                  AS billed,
       f.conamount                  AS concession,
       f.paidamount                 AS paid,
       f.balancedue                 AS balance,
       f.cf_id,
       f.createdat::date            AS created,
       f.createdby
  FROM g
  JOIN kcet20262027.feedemand f
    ON  f.stu_id                              = g.stu_id
    AND f.demfeetype IS NOT DISTINCT FROM       g.demfeetype
    AND f.demfeeterm IS NOT DISTINCT FROM       g.demfeeterm
    AND f.yr_id      IS NOT DISTINCT FROM       g.yr_id
    AND COALESCE(f.demfeeyear, '')              = g.demfeeyear_k
    AND (COALESCE(f.demseqtype, '') = 'ARREAR') = g.is_arrear
    AND COALESCE(f.arrearclass, '')             = g.arrearclass
    AND f.activestatus = 1
  LEFT JOIN kcet20262027.students s ON s.stu_id = f.stu_id
 ORDER BY g.newest DESC, f.stuadmno, f.demfeetype, f.dem_id;
