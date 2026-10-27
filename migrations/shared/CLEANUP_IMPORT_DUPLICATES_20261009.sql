-- ============================================================================
-- Undo the duplicate demands raised by the 9 Oct 2026 fee-demand import.
-- ============================================================================
-- WHAT HAPPENED. fn_approve_tempfeedemand decides update-or-insert by matching
-- the staged row's DEMNO against feedemand. The sheet that was imported was a
-- REJECTS sheet: its Demand No column held newly allocated numbers the database
-- had never issued (and by the time it was imported, Excel had blanked the
-- column outright). No match, so every row that was already billed came back as
-- a SECOND demand. RITHISH S went to Rs 93,000 due -- Rs 43,000 still owed on
-- the real demand plus a fresh Rs 50,000 one.
--
-- WHAT THIS DOES. For each demand raised on 9 Oct that duplicates an older
-- active demand for the same student + fee type + term + year:
--   * carries the new row's figures onto the ORIGINAL demand, which is what
--     the import was meant to do -- amount, concession, due date and the
--     import ids, with the balance re-derived from what has been paid;
--   * copies the duplicate into kcet20262027._deleted_import_dupes_20261009
--     and then DELETES it.
--
-- WHY DELETE AND NOT A SOFT DELETE. feedemand_activestatus_check allows only
-- 0 or 1 -- the 9 used on tempfeedemand and payment is rejected here. 0 would
-- pass, but nothing in the app ever writes it, so such a row sits in a state
-- the code has never seen, and any report that forgets `activestatus = 1`
-- would still add it to a student's balance. The app's own
-- SupabaseService.deleteFeeDemand hard-deletes, guarded on paidamount = 0 --
-- the same guard used here. The backup table is the audit trail.
--
-- WHAT IT WILL NOT TOUCH.
--   * A duplicate that has taken any money (paidamount > 0, or any
--     paymentdetails row against it). There were none on 9 Oct; the guard is
--     here so this stays safe if it is run later or on another database.
--   * The 30 duplicate pairs that pre-date 9 Oct. Some are legitimate -- roll
--     262709 holds two TUITION FEE demands from 9 Sep, Rs 47,500 and Rs 20,000,
--     both part-paid. Merging those would destroy a bill, so the cut-off date
--     is deliberate and this script is NOT a general de-duplicator.
--
-- HOW TO RUN IT, in the Supabase SQL editor: select PART 1 alone and run it,
-- read the numbers, then select PART 2 alone and run that, then PART 3. The
-- editor only ever shows the LAST result set, so running the whole file in one
-- go would hide PART 1's preview behind PART 3's verification.
--
-- Idempotent: a second run finds nothing, because the duplicates are gone from
-- feedemand.
--
-- Do NOT wrap in BEGIN -- the Supabase SQL editor rolls that back silently,
-- and it looks like it ran.
-- ============================================================================

-- ---------------------------------------------------------------- PART 1 ---
-- Preview. Changes nothing.
WITH dup AS (
  SELECT n.dem_id  AS new_id,  n.demno AS new_demno,  n.feeamount AS new_amt,
         n.conamount AS new_con, n.duedate AS new_due, n.cf_id AS new_cf,
         n.cla_id AS new_cla, n.sem_id AS new_sem, n.fee_id AS new_fee,
         o.dem_id AS old_id,  o.demno AS old_demno,  o.feeamount AS old_amt,
         o.paidamount AS old_paid, n.stuadmno, n.demfeetype, n.demfeeterm
    FROM kcet20262027.feedemand n
    JOIN kcet20262027.feedemand o
      ON  o.ins_id      =  n.ins_id
      AND o.stu_id      =  n.stu_id
      AND o.demfeetype  IS NOT DISTINCT FROM n.demfeetype
      AND o.demfeeterm  IS NOT DISTINCT FROM n.demfeeterm
      AND o.yr_id       IS NOT DISTINCT FROM n.yr_id
      AND o.activestatus = 1
      AND o.dem_id      <  n.dem_id
   WHERE n.activestatus = 1
     AND n.createdat::date = DATE '2026-10-09'
     AND COALESCE(n.paidamount, 0) = 0
     AND NOT EXISTS (SELECT 1 FROM kcet20262027.paymentdetails pd
                      WHERE pd.dem_id = n.dem_id)
)
SELECT 'duplicates to retire'                       AS what, count(*)::text AS value FROM dup
UNION ALL
SELECT 'students affected',      count(DISTINCT stuadmno)::text FROM dup
UNION ALL
SELECT 'billing removed (Rs)',   to_char(sum(new_amt), 'FM9999999990')  FROM dup
UNION ALL
SELECT 'originals whose amount changes',
       count(*) FILTER (WHERE new_amt IS DISTINCT FROM old_amt)::text   FROM dup
UNION ALL
SELECT 'skipped: duplicate has taken money',
       (SELECT count(*)::text
          FROM kcet20262027.feedemand n
          JOIN kcet20262027.feedemand o
            ON o.ins_id = n.ins_id AND o.stu_id = n.stu_id
           AND o.demfeetype IS NOT DISTINCT FROM n.demfeetype
           AND o.demfeeterm IS NOT DISTINCT FROM n.demfeeterm
           AND o.yr_id      IS NOT DISTINCT FROM n.yr_id
           AND o.activestatus = 1 AND o.dem_id < n.dem_id
         WHERE n.activestatus = 1
           AND n.createdat::date = DATE '2026-10-09'
           AND (COALESCE(n.paidamount, 0) > 0
                OR EXISTS (SELECT 1 FROM kcet20262027.paymentdetails pd
                            WHERE pd.dem_id = n.dem_id)));

-- ---------------------------------------------------------------- PART 2 ---
-- Apply. The whole block is ONE statement, so a failure anywhere rolls the
-- entire cleanup back -- a half-done pass is not possible.
DO $cleanup$
DECLARE
  r record;
  v_net numeric;
  n_upd int := 0;
  n_ret int := 0;
BEGIN
  -- Audit trail: the duplicates as they were, kept outside feedemand so no
  -- query can pick them up again. Survives a re-run; rows are appended.
  CREATE TABLE IF NOT EXISTS kcet20262027._deleted_import_dupes_20261009
    (LIKE kcet20262027.feedemand);

  FOR r IN
    SELECT n.dem_id AS new_id, n.feeamount AS new_amt, n.conamount AS new_con,
           n.con_id AS new_conid, n.duedate AS new_due, n.cf_id AS new_cf,
           n.cla_id AS new_cla, n.sem_id AS new_sem, n.fee_id AS new_fee,
           o.dem_id AS old_id, COALESCE(o.paidamount, 0) AS old_paid
      FROM kcet20262027.feedemand n
      JOIN kcet20262027.feedemand o
        ON  o.ins_id      =  n.ins_id
        AND o.stu_id      =  n.stu_id
        AND o.demfeetype  IS NOT DISTINCT FROM n.demfeetype
        AND o.demfeeterm  IS NOT DISTINCT FROM n.demfeeterm
        AND o.yr_id       IS NOT DISTINCT FROM n.yr_id
        AND o.activestatus = 1
        AND o.dem_id      <  n.dem_id
     WHERE n.activestatus = 1
       AND n.createdat::date = DATE '2026-10-09'
       AND COALESCE(n.paidamount, 0) = 0
       AND NOT EXISTS (SELECT 1 FROM kcet20262027.paymentdetails pd
                        WHERE pd.dem_id = n.dem_id)
     ORDER BY n.dem_id
  LOOP
    -- No trigger maintains balancedue, so it is derived here, exactly as
    -- fn_approve_tempfeedemand does it: billed - concession - paid, floored.
    v_net := GREATEST(COALESCE(r.new_amt, 0) - COALESCE(r.new_con, 0) - r.old_paid, 0);

    UPDATE kcet20262027.feedemand
       SET feeamount       = r.new_amt,
           con_id          = r.new_conid,
           conamount       = r.new_con,
           balancedue      = v_net,
           reconbalancedue = v_net,
           paidstatus      = CASE WHEN v_net <= 0 THEN 'P' ELSE 'U' END,
           duedate         = COALESCE(r.new_due, duedate),
           cla_id          = COALESCE(r.new_cla, cla_id),
           sem_id          = COALESCE(r.new_sem, sem_id),
           fee_id          = COALESCE(r.new_fee, fee_id),
           cf_id           = COALESCE(r.new_cf,  cf_id)
     WHERE dem_id = r.old_id;
    n_upd := n_upd + 1;

    INSERT INTO kcet20262027._deleted_import_dupes_20261009
      SELECT * FROM kcet20262027.feedemand WHERE dem_id = r.new_id;

    DELETE FROM kcet20262027.feedemand WHERE dem_id = r.new_id;
    n_ret := n_ret + 1;
  END LOOP;

  RAISE NOTICE 'originals updated: %, duplicates removed: %', n_upd, n_ret;
END
$cleanup$;

-- ---------------------------------------------------------------- PART 3 ---
-- Verify. Both numbers should be 0.
SELECT 'duplicates left from 9 Oct' AS what, count(*)::text AS value
  FROM kcet20262027.feedemand n
  JOIN kcet20262027.feedemand o
    ON o.ins_id = n.ins_id AND o.stu_id = n.stu_id
   AND o.demfeetype IS NOT DISTINCT FROM n.demfeetype
   AND o.demfeeterm IS NOT DISTINCT FROM n.demfeeterm
   AND o.yr_id      IS NOT DISTINCT FROM n.yr_id
   AND o.activestatus = 1 AND o.dem_id < n.dem_id
 WHERE n.activestatus = 1 AND n.createdat::date = DATE '2026-10-09'
UNION ALL
SELECT 'demands where paid exceeds billed', count(*)::text
  FROM kcet20262027.feedemand
 WHERE activestatus = 1
   AND COALESCE(paidamount, 0)
       > COALESCE(feeamount, 0) - COALESCE(conamount, 0)
         + COALESCE(fineamount, 0) + 0.005;
