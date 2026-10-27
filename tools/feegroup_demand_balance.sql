-- ============================================================================
-- Demand and balance, fee group wise.
-- ============================================================================
-- HOW A DEMAND FINDS ITS GROUP. feedemand carries no fg_id. The chain is
--     feedemand.fee_id -> feetype.fee_id -> feetype.fg_id -> feegroup
-- and fee_id is NOT always set: demands raised before the id back-fill, and
-- any whose template did not resolve, have it NULL. Joining on fee_id alone
-- silently drops those rows and the totals come out light.
--
-- So each demand resolves by fee_id when it has one and by fee-type NAME when
-- it does not. The name is the weaker key -- the same fee name can exist
-- under more than one group -- so the lookup takes ONE group deterministically
-- (lowest fee_id) and query 4 lists every demand where that choice was a
-- guess. If query 4 is empty, the numbers here are exact.
--
-- WHAT THE MONEY COLUMNS MEAN
--     billed      feeamount        what was charged
--     concession  conamount        written off
--     collected   paidamount       received against the demand
--     balance     balancedue       still owed, EXCLUDING fine (and never < 0)
--     fine        fineamount       added on top of balance when overdue
--     total_due   balance + fine   what the student actually has to pay
--
-- activestatus = 1 only: a cancelled demand is not owed. COLLECTIBLE is split
-- out because a non-collectible demand is recorded but never presented for
-- collection -- counting it in "balance" overstates what the office can chase.
--
-- Each query stands alone. Run them one at a time -- the Supabase editor shows
-- only the last result set. Read-only throughout; nothing here writes.
--
-- Schema is kcet20262027; change it for another institution-year.
-- ============================================================================


-- ============================================== 1. FEE GROUP WISE TOTALS ====
-- The headline. One row per fee group.
-- ===========================================================================

WITH dem AS (
  SELECT fd.stu_id, fd.feeamount, fd.conamount, fd.paidamount,
         COALESCE(fd.fineamount, 0) AS fineamount, fd.balancedue,
         COALESCE(fd.collectible, true) AS collectible,
         g.fg_id, g.fgdesc
    FROM kcet20262027.feedemand fd
    LEFT JOIN LATERAL (
      SELECT fg.fg_id, fg.fgdesc
        FROM kcet20262027.feetype ft
        JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
       WHERE CASE WHEN fd.fee_id IS NOT NULL
                  THEN ft.fee_id = fd.fee_id
                  ELSE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(fd.demfeetype))
             END
       ORDER BY ft.fee_id
       LIMIT 1
    ) g ON true
   WHERE fd.activestatus = 1
)
-- GROUPING(), not COALESCE(). ROLLUP emits NULL for the grand-total row, and
-- a demand that matched no group is ALSO NULL here -- label both the same way
-- and the total reads as a third fee group. GROUPING() is the only thing that
-- tells the two apart.
SELECT CASE WHEN GROUPING(fgdesc) = 1 THEN '== TOTAL =='
            ELSE COALESCE(fgdesc, '(no group)') END         AS fee_group,
       count(*)                                             AS demands,
       count(DISTINCT stu_id)                               AS students,
       sum(feeamount)                                       AS billed,
       sum(conamount)                                       AS concession,
       sum(paidamount)                                      AS collected,
       sum(balancedue)                                      AS balance,
       sum(fineamount)                                      AS fine,
       sum(balancedue) + sum(fineamount)                    AS total_due,
       COALESCE(sum(balancedue) FILTER (WHERE collectible), 0)     AS balance_collectible,
       COALESCE(sum(balancedue) FILTER (WHERE NOT collectible), 0) AS balance_not_collectible
  FROM dem
 GROUP BY ROLLUP (fgdesc)
 ORDER BY GROUPING(fgdesc), fgdesc;


-- ================================ 2. FEE GROUP x FEE TYPE (the drill-down) ==
-- Where a group's balance actually sits.
-- ===========================================================================

WITH dem AS (
  SELECT fd.demfeetype, fd.stu_id, fd.feeamount, fd.conamount, fd.paidamount,
         COALESCE(fd.fineamount, 0) AS fineamount, fd.balancedue,
         g.fgdesc
    FROM kcet20262027.feedemand fd
    LEFT JOIN LATERAL (
      SELECT fg.fgdesc
        FROM kcet20262027.feetype ft
        JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
       WHERE CASE WHEN fd.fee_id IS NOT NULL
                  THEN ft.fee_id = fd.fee_id
                  ELSE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(fd.demfeetype))
             END
       ORDER BY ft.fee_id
       LIMIT 1
    ) g ON true
   WHERE fd.activestatus = 1
)
SELECT COALESCE(fgdesc, '(no group)') AS fee_group,
       demfeetype                     AS fee_type,
       count(*)                       AS demands,
       count(DISTINCT stu_id)         AS students,
       sum(feeamount)                 AS billed,
       sum(conamount)                 AS concession,
       sum(paidamount)                AS collected,
       sum(balancedue)                AS balance,
       sum(fineamount)                AS fine
  FROM dem
 GROUP BY 1, 2
 ORDER BY 1, sum(balancedue) DESC, 2;


-- ===================================== 3. FEE GROUP x CLASS (who owes) ======
-- Same totals cut by class, so a group's outstanding can be chased.
-- ===========================================================================

WITH dem AS (
  SELECT fd.stuclass, fd.stu_id, fd.feeamount, fd.paidamount,
         COALESCE(fd.fineamount, 0) AS fineamount, fd.balancedue,
         g.fgdesc
    FROM kcet20262027.feedemand fd
    LEFT JOIN LATERAL (
      SELECT fg.fgdesc
        FROM kcet20262027.feetype ft
        JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
       WHERE CASE WHEN fd.fee_id IS NOT NULL
                  THEN ft.fee_id = fd.fee_id
                  ELSE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(fd.demfeetype))
             END
       ORDER BY ft.fee_id
       LIMIT 1
    ) g ON true
   WHERE fd.activestatus = 1
     AND COALESCE(fd.collectible, true)
)
SELECT COALESCE(fgdesc, '(no group)')          AS fee_group,
       stuclass                                AS class,
       count(DISTINCT stu_id)                  AS students,
       sum(feeamount)                          AS billed,
       sum(paidamount)                         AS collected,
       sum(balancedue)                         AS balance,
       sum(fineamount)                         AS fine,
       count(*) FILTER (WHERE balancedue > 0)  AS unpaid_demands
  FROM dem
 GROUP BY 1, 2
HAVING sum(balancedue) > 0
 ORDER BY 1, sum(balancedue) DESC;


-- =========================== 4. TRUST CHECK -- run this before believing 1 ==
-- 4a Demands that could not be placed in any group at all, and demands whose
--    group was picked by NAME from more than one candidate. Both make the
--    totals above approximate. Empty result = the totals are exact.
-- ===========================================================================

SELECT CASE WHEN g.hits = 0 THEN 'no group at all'
            WHEN fd.fee_id IS NULL AND g.hits > 1 THEN 'name matches ' || g.hits || ' groups'
       END                              AS problem,
       fd.demfeetype                    AS fee_type,
       count(*)                         AS demands,
       sum(fd.feeamount)                AS billed,
       sum(fd.balancedue)               AS balance,
       count(*) FILTER (WHERE fd.fee_id IS NULL) AS of_which_fee_id_null
  FROM kcet20262027.feedemand fd
  CROSS JOIN LATERAL (
    SELECT count(DISTINCT fg.fg_id) AS hits
      FROM kcet20262027.feetype ft
      JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
     WHERE CASE WHEN fd.fee_id IS NOT NULL
                THEN ft.fee_id = fd.fee_id
                ELSE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(fd.demfeetype))
           END
  ) g
 WHERE fd.activestatus = 1
   AND (g.hits = 0 OR (fd.fee_id IS NULL AND g.hits > 1))
 GROUP BY 1, 2
 ORDER BY sum(fd.balancedue) DESC, 2;


-- --------------------------------------------------------------------- 4b --
-- Does balancedue still agree with its own parts? It should be
-- feeamount - conamount - paidamount, floored at 0. A row that drifted is a
-- demand whose balance was written directly instead of recomputed, and it
-- makes every total above wrong by that much. Expect 0 rows.
-- ---------------------------------------------------------------------------

SELECT fd.demno, fd.stuadmno, fd.stuclass, fd.demfeetype,
       fd.feeamount, fd.conamount, fd.paidamount, fd.balancedue,
       GREATEST(fd.feeamount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0)
         AS balance_should_be
  FROM kcet20262027.feedemand fd
 WHERE fd.activestatus = 1
   AND fd.balancedue IS DISTINCT FROM
       GREATEST(fd.feeamount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0)
 ORDER BY abs(fd.balancedue -
              GREATEST(fd.feeamount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0)) DESC
 LIMIT 200;
