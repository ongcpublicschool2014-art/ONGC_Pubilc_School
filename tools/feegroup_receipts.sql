-- ============================================================================
-- Receipts generated, fee group wise.
-- ============================================================================
-- THREE TABLES ISSUE RECEIPTS, not one:
--     payment.paynumber             fee collection
--     misc_collection.mcno          counter collection (BONAFIDE, ...)
--     advance_collection.advno      advances
-- They draw from the SAME per-group series, so FC26/00412 may be a misc
-- receipt sitting between two fee receipts. Counting `payment` alone
-- understates every group. All three are unioned.
--
-- HOW A RECEIPT IS ATTRIBUTED TO A GROUP. None of the three stores fg_id, so:
--   1. BY SERIES -- the receipt number's prefix matched against
--      sequence.seqprefix, whose row carries fg_id. This is how the number was
--      issued in the first place, so it is the real answer.
--   2. BY BANK -- ban_id on the receipt, and only when EXACTLY ONE active fee
--      group maps to that account. Two groups sharing a bank makes it a guess,
--      and a guess is left unattributed rather than quietly assigned.
--   3. Otherwise UNATTRIBUTED, listed by query 3. Those are not lost money --
--      they are receipts whose series has no sequence row, which is worth
--      fixing because an in-app collection for that group has no series to
--      number from and will borrow another group's run.
--
-- CANCELLED RECEIPTS STILL COUNT AS GENERATED. A voided receipt consumed its
-- number and the number can never be reused, so `issued` counts everything and
-- `live` / `cancelled` split it. Money columns are summed over LIVE rows only.
--
-- Each query stands alone. Run them one at a time -- the Supabase editor shows
-- only the last result set. Read-only throughout.
--
-- Schema is kcet20262027; change it for another institution-year.
-- ============================================================================


-- The attribution used by queries 1-3. Repeated in each because the Supabase
-- editor runs one statement at a time and a CTE cannot be shared between them.


-- ========================================= 1. FEE GROUP x SOURCE TABLE ======
-- Who issued what. The series column shows which prefix each group is using.
-- ===========================================================================

WITH r AS (
  SELECT 'fee'     AS src, paynumber AS rno, paydate::date AS dt,
         transtotalamount AS amt, ban_id, activestatus
    FROM kcet20262027.payment            WHERE paynumber IS NOT NULL AND btrim(paynumber) <> ''
  UNION ALL
  SELECT 'misc',    mcno,  mcdate,        totalamount,      ban_id, activestatus
    FROM kcet20262027.misc_collection    WHERE mcno      IS NOT NULL AND btrim(mcno)      <> ''
  UNION ALL
  SELECT 'advance', advno, advdate::date, transtotalamount, ban_id, activestatus
    FROM kcet20262027.advance_collection WHERE advno     IS NOT NULL AND btrim(advno)     <> ''
), p AS (
  -- Split on TRAILING digits only: 'FC26/03794' -> 'FC26/' + 3794. The prefix
  -- carries the year digits, so anchoring at the end is what keeps it intact.
  SELECT r.*, regexp_replace(btrim(rno), '[0-9]+$', '') AS prefix,
         (regexp_match(btrim(rno), '([0-9]+)$'))[1]::bigint AS seq
    FROM r WHERE btrim(rno) ~ '[0-9]+$'
), att AS (
  SELECT p.*, COALESCE(sg.fgdesc, bg.fgdesc) AS fee_group
    FROM p
    LEFT JOIN LATERAL (
      SELECT fg.fgdesc FROM kcet20262027.sequence s
        JOIN kcet20262027.feegroup fg ON fg.fg_id = s.fg_id
       WHERE s.seqprefix = p.prefix AND s.activestatus = 1 LIMIT 1) sg ON true
    LEFT JOIN LATERAL (
      SELECT max(fg.fgdesc) AS fgdesc FROM kcet20262027.feegroup fg
       WHERE fg.ban_id = p.ban_id AND fg.activestatus = 1
      HAVING count(*) = 1) bg ON true
)
SELECT COALESCE(fee_group, '(unattributed)')          AS fee_group,
       prefix                                         AS series,
       src                                            AS source,
       count(*)                                       AS issued,
       count(*) FILTER (WHERE activestatus = 1)       AS live,
       count(*) FILTER (WHERE activestatus <> 1)      AS cancelled,
       min(seq)                                       AS lowest_no,
       max(seq)                                       AS highest_no,
       min(dt)                                        AS first_date,
       max(dt)                                        AS last_date,
       COALESCE(sum(amt) FILTER (WHERE activestatus = 1), 0) AS amount_live
  FROM att
 GROUP BY 1, 2, 3
 ORDER BY 1, 2, 3;


-- ================================================ 2. FEE GROUP TOTALS =======
-- The headline, with the three sources split across columns.
-- ===========================================================================

WITH r AS (
  SELECT 'fee'     AS src, paynumber AS rno, paydate::date AS dt,
         transtotalamount AS amt, ban_id, activestatus
    FROM kcet20262027.payment            WHERE paynumber IS NOT NULL AND btrim(paynumber) <> ''
  UNION ALL
  SELECT 'misc',    mcno,  mcdate,        totalamount,      ban_id, activestatus
    FROM kcet20262027.misc_collection    WHERE mcno      IS NOT NULL AND btrim(mcno)      <> ''
  UNION ALL
  SELECT 'advance', advno, advdate::date, transtotalamount, ban_id, activestatus
    FROM kcet20262027.advance_collection WHERE advno     IS NOT NULL AND btrim(advno)     <> ''
), p AS (
  SELECT r.*, regexp_replace(btrim(rno), '[0-9]+$', '') AS prefix
    FROM r WHERE btrim(rno) ~ '[0-9]+$'
), att AS (
  SELECT p.*, COALESCE(sg.fgdesc, bg.fgdesc) AS fee_group
    FROM p
    LEFT JOIN LATERAL (
      SELECT fg.fgdesc FROM kcet20262027.sequence s
        JOIN kcet20262027.feegroup fg ON fg.fg_id = s.fg_id
       WHERE s.seqprefix = p.prefix AND s.activestatus = 1 LIMIT 1) sg ON true
    LEFT JOIN LATERAL (
      SELECT max(fg.fgdesc) AS fgdesc FROM kcet20262027.feegroup fg
       WHERE fg.ban_id = p.ban_id AND fg.activestatus = 1
      HAVING count(*) = 1) bg ON true
)
-- GROUPING(), not COALESCE(): ROLLUP emits NULL for the total row and an
-- unattributed receipt is NULL too. Labelled the same, the total reads as a
-- third fee group.
SELECT CASE WHEN GROUPING(fee_group) = 1 THEN '== TOTAL =='
            ELSE COALESCE(fee_group, '(unattributed)') END AS fee_group,
       count(*)                                        AS receipts_issued,
       count(*) FILTER (WHERE activestatus = 1)        AS live,
       count(*) FILTER (WHERE activestatus <> 1)       AS cancelled,
       count(*) FILTER (WHERE src = 'fee')             AS from_fee,
       count(*) FILTER (WHERE src = 'misc')            AS from_misc,
       count(*) FILTER (WHERE src = 'advance')         AS from_advance,
       COALESCE(sum(amt) FILTER (WHERE activestatus = 1), 0) AS amount_live
  FROM att
 GROUP BY ROLLUP (fee_group)
 ORDER BY GROUPING(fee_group), fee_group;


-- ============================= 3. UNATTRIBUTED -- read before believing 1-2 =
-- Receipt series that match no sequence row and whose bank does not identify
-- a single group. Empty result = every receipt is accounted for.
--
-- A series listed here means that group has no receipt sequence configured
-- (Setup -> Sequence Master). The numbers in the data came from elsewhere --
-- an import, usually -- and the NEXT in-app collection for that group will
-- borrow another group's run.
-- ===========================================================================

WITH r AS (
  SELECT 'fee'     AS src, paynumber AS rno, transtotalamount AS amt, ban_id
    FROM kcet20262027.payment            WHERE paynumber IS NOT NULL AND btrim(paynumber) <> ''
  UNION ALL
  SELECT 'misc',    mcno,  totalamount,      ban_id
    FROM kcet20262027.misc_collection    WHERE mcno      IS NOT NULL AND btrim(mcno)      <> ''
  UNION ALL
  SELECT 'advance', advno, transtotalamount, ban_id
    FROM kcet20262027.advance_collection WHERE advno     IS NOT NULL AND btrim(advno)     <> ''
), p AS (
  SELECT r.*, regexp_replace(btrim(rno), '[0-9]+$', '') AS prefix
    FROM r WHERE btrim(rno) ~ '[0-9]+$'
)
SELECT p.prefix                      AS series,
       p.src                         AS source,
       count(*)                      AS receipts,
       sum(p.amt)                    AS amount,
       count(DISTINCT p.ban_id)      AS distinct_banks,
       'no sequence row for this prefix' AS why
  FROM p
  LEFT JOIN LATERAL (
    SELECT 1 FROM kcet20262027.sequence s
     WHERE s.seqprefix = p.prefix AND s.activestatus = 1 AND s.fg_id IS NOT NULL
     LIMIT 1) sg ON true
  LEFT JOIN LATERAL (
    SELECT 1 FROM kcet20262027.feegroup fg
     WHERE fg.ban_id = p.ban_id AND fg.activestatus = 1
    HAVING count(*) = 1) bg ON true
 WHERE sg IS NULL AND bg IS NULL
 GROUP BY 1, 2
 ORDER BY count(*) DESC, 1;


-- ===================================== 4. THE SERIES BEHIND EACH GROUP ======
-- What each group is configured to issue, and where its counter stands against
-- the highest number actually used. A counter BEHIND the highest used number
-- means the next receipt will collide; ahead is normal (numbers drawn for
-- attempts that never became receipts). A group with no row here cannot issue
-- a receipt of its own at all.
-- ===========================================================================

WITH used AS (
  SELECT regexp_replace(btrim(rno), '[0-9]+$', '') AS prefix,
         max((regexp_match(btrim(rno), '([0-9]+)$'))[1]::bigint) AS highest_used,
         count(*) AS receipts
    FROM (
      SELECT paynumber AS rno FROM kcet20262027.payment            WHERE paynumber IS NOT NULL AND btrim(paynumber) <> ''
      UNION ALL
      SELECT mcno             FROM kcet20262027.misc_collection    WHERE mcno      IS NOT NULL AND btrim(mcno)      <> ''
      UNION ALL
      SELECT advno            FROM kcet20262027.advance_collection WHERE advno     IS NOT NULL AND btrim(advno)     <> ''
    ) x
   WHERE btrim(rno) ~ '[0-9]+$'
   GROUP BY 1
)
SELECT fg.fg_id,
       fg.fgdesc                AS fee_group,
       fg.ban_id,
       s.actname,
       s.seqprefix              AS series,
       s.seqcurno               AS counter,
       u.highest_used,
       COALESCE(u.receipts, 0)  AS receipts_issued,
       CASE
         WHEN s.seq_id IS NULL                  THEN 'NO SEQUENCE -- cannot issue its own receipts'
         WHEN u.highest_used IS NULL            THEN 'configured, nothing issued yet'
         WHEN s.seqcurno >= u.highest_used      THEN 'OK'
         ELSE 'BEHIND -- next receipt will collide'
       END                      AS verdict
  FROM kcet20262027.feegroup fg
  LEFT JOIN kcet20262027.sequence s
         ON s.fg_id = fg.fg_id AND s.activestatus = 1
  LEFT JOIN used u ON u.prefix = s.seqprefix
 WHERE fg.activestatus = 1
 ORDER BY fg.fg_id;
