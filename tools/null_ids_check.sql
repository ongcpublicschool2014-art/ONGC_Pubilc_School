-- ============================================================================
-- Demands missing their resolved ids (fee_id, and the three beside it).
-- ============================================================================
-- WHY IT MATTERS. feedemand stores the fee as TEXT (demfeetype) and as an id
-- (fee_id). The text is what prints; the id is what every join uses -- fee
-- group, bank routing, group-wise balance. A NULL fee_id still shows the right
-- fee name on screen, so nothing looks wrong, but the demand falls out of any
-- report that goes through feetype -> feegroup, and nothing says it did.
--
-- cf_id / cla_id / sem_id are the same story: they tie a demand back to the
-- classfeedemand template that raised it. NULL and the demand cannot be
-- traced, and the Fee Demand import reports it as missing ids.
--
-- Query 1 counts them. Query 2 says which are FIXABLE -- a NULL fee_id whose
-- demfeetype still matches exactly one active fee type can simply be filled
-- in. Query 4 is that back-fill, and it is commented out: read 1-3 first.
--
-- Read-only except query 4. Run one at a time -- the Supabase editor shows
-- only the last result set. Schema is kcet20262027.
-- ============================================================================


-- ===================================================== 1. THE COUNTS ========
-- One row per table. active rows only; a cancelled demand is not worth fixing.
-- ===========================================================================

SELECT 'feedemand'  AS tbl, count(*) AS active_rows,
       count(*) FILTER (WHERE fee_id IS NULL) AS fee_id_null,
       count(*) FILTER (WHERE cla_id IS NULL) AS cla_id_null,
       count(*) FILTER (WHERE sem_id IS NULL) AS sem_id_null,
       count(*) FILTER (WHERE cf_id  IS NULL) AS cf_id_null
  FROM kcet20262027.feedemand WHERE activestatus = 1
UNION ALL
SELECT 'tempfeedemand', count(*),
       count(*) FILTER (WHERE fee_id IS NULL),
       count(*) FILTER (WHERE cla_id IS NULL),
       count(*) FILTER (WHERE sem_id IS NULL),
       count(*) FILTER (WHERE cf_id  IS NULL)
  FROM kcet20262027.tempfeedemand WHERE activestatus = 1
UNION ALL
SELECT 'classfeedemand', count(*),
       count(*) FILTER (WHERE fee_id IS NULL),
       count(*) FILTER (WHERE cla_id IS NULL),
       count(*) FILTER (WHERE sem_id IS NULL),
       NULL                      -- cf_id IS the key here
  FROM kcet20262027.classfeedemand WHERE activestatus = 1;


-- ======================================= 2. THE NULL fee_id ROWS, GROUPED ===
-- By fee name, with how many active fee types that name matches:
--     1  -> fixable, query 4 fills it
--     0  -> the fee type no longer exists (or the name is misspelt)
--    >1  -> ambiguous, a human must choose; query 4 deliberately skips these
-- ===========================================================================

SELECT fd.demfeetype                           AS fee_type,
       count(*)                                AS demands,
       count(DISTINCT fd.stu_id)               AS students,
       sum(fd.feeamount)                       AS billed,
       sum(fd.balancedue)                      AS balance,
       m.matches                               AS matching_fee_types,
       CASE WHEN m.matches = 1 THEN 'fixable'
            WHEN m.matches = 0 THEN 'no such fee type'
            ELSE 'ambiguous -- choose by hand' END AS verdict
  FROM kcet20262027.feedemand fd
  CROSS JOIN LATERAL (
    SELECT count(*) AS matches
      FROM kcet20262027.feetype ft
     WHERE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(fd.demfeetype))
       AND ft.activestatus = 1
  ) m
 WHERE fd.activestatus = 1
   AND fd.fee_id IS NULL
 GROUP BY fd.demfeetype, m.matches
 ORDER BY count(*) DESC, fd.demfeetype;


-- ================================== 3. A LOOK AT THE ACTUAL ROWS ============
-- The first 100, so you can see what they are before changing anything.
-- ===========================================================================

SELECT fd.dem_id, fd.demno, fd.stuadmno, fd.stuclass, fd.demfeeterm,
       fd.demfeetype, fd.feeamount, fd.paidamount, fd.balancedue,
       fd.cla_id, fd.sem_id, fd.cf_id, fd.demseqtype, fd.createdat
  FROM kcet20262027.feedemand fd
 WHERE fd.activestatus = 1
   AND fd.fee_id IS NULL
 ORDER BY fd.createdat DESC NULLS LAST, fd.dem_id DESC
 LIMIT 100;


-- ====================================== 4. THE BACK-FILL (commented out) ====
-- Fills fee_id ONLY where the name matches exactly one active fee type.
-- Touches nothing else: no amount, no balance, no status. Ambiguous and
-- unmatched names are left for a human, which is why query 2 comes first.
--
-- Uncomment to run. Do NOT wrap it in BEGIN -- the Supabase editor rolls that
-- back on its own and it looks exactly like a successful run.
-- ===========================================================================

-- UPDATE kcet20262027.feedemand fd
--    SET fee_id = ft.fee_id
--   FROM kcet20262027.feetype ft
--  WHERE fd.activestatus = 1
--    AND fd.fee_id IS NULL
--    AND UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(fd.demfeetype))
--    AND ft.activestatus = 1
--    AND (SELECT count(*) FROM kcet20262027.feetype f2
--          WHERE UPPER(TRIM(f2.feedesc)) = UPPER(TRIM(fd.demfeetype))
--            AND f2.activestatus = 1) = 1;
