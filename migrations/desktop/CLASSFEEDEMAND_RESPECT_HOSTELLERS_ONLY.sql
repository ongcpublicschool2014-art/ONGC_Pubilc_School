-- ============================================================================
-- Class Fee Demand must not bill a HOSTELLERS ONLY fee to day scholars.
-- ============================================================================
-- WHAT WENT WRONG. HOSTEL FEES is ticked HOSTELLERS ONLY, and Student Fee
-- Definition honours that -- but Class Fee Demand never asked. Saving MESS FEE
-- 100 for B.TECH AI&DS-I staged 71 demands, one per student in the class,
-- hostellers and day scholars alike. They are sitting in Fee Demand Approval
-- now, Pending.
--
-- There are two ways a class fee becomes a student demand:
--   1. the Class Fee Demand screen, which builds the rows in Dart
--      (fee_master_screen.dart -- fixed in the app, ships with the exe)
--   2. public.generate_feedemand_for_class, the RPC the master import calls
--      after loading a template file                        <- PART A below
-- Fixing only the screen would leave the import re-creating the same rows, so
-- the rule is enforced in both.
--
-- THE RULE. A fee is withheld from a non-hosteller only when EVERY group it
-- appears under is ticked. One open group means the fee is legitimately
-- billable to everyone and must not be withheld -- the same test the app
-- applies, so the two paths cannot disagree. A fee in no group at all is
-- unaffected.
--
-- A blank students.hostel counts as NOT a hosteller, matching the screen's
-- own "Day scholars only" filter (hostel.eq.N OR hostel.is.null).
--
-- Requires FEEGROUP_HOSTELLERS_ONLY.sql (adds feegroup.hostellers_only).
-- Run each PART separately -- the Supabase editor shows only the last result.
-- Do NOT wrap in BEGIN -- the editor rolls that back silently and it looks
-- like it ran.
-- ============================================================================


-- =================================================================== PART A =
-- The import-path generator learns the rule.
-- Unchanged from the current definition except for the AND block marked
-- HOSTELLERS ONLY near the end of the WHERE.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.generate_feedemand_for_class(
  p_ins_id integer, p_class text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET statement_timeout = '120s'
AS $$
DECLARE v_schema text; v_count int;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;
  EXECUTE format($q$
    INSERT INTO %1$I.tempfeedemand
      (ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear,
       demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, duedate,
       activestatus, createdby, isapproved, collectible,
       cla_id, sem_id, cf_id, fee_id, demseqtype)
    SELECT s.ins_id, s.inscode, s.yr_id, s.stu_id, s.stuadmno, s.stuclass, s.courname,
       s.yrlabel, cf.cfterm, cf.cffeetype, cf.cfamount, s.con_id, 0, cf.cfamount,
       cf.cfdduedate, 1, COALESCE(s.approvedby, 'SYSTEM'), false, COALESCE(cf.collectible, true),
       cf.cla_id, cf.sem_id, cf.cf_id, cf.fee_id, 'REGULAR'
    FROM %1$I.students s
    JOIN %1$I.classfeedemand cf
      ON cf.cfclass = s.stuclass AND cf.activestatus = 1
    LEFT JOIN %1$I.admissiontype a
      ON UPPER(TRIM(a.admname)) = UPPER(TRIM(s.admname)) AND a.activestatus = 1 AND a.ins_id = s.ins_id
    WHERE s.activestatus <> 9
      -- A pre-admission student has paid to hold a seat for NEXT year and is
      -- not studying this one, so this year's fees are not theirs to owe.
      -- They pick the new year's demands up after the rollover, by which time
      -- the flag is cleared.
      AND COALESCE(s.preadmission, 0) = 0
      AND s.stuclass = $1
      AND cf.cfamount IS NOT NULL
      AND (cf.cfdduedate IS NULL OR cf.cfdduedate >= s.stuadmdate)
      AND (cf.admissiontype IS NULL OR cf.admissiontype = a.adm_id)
      -- HOSTELLERS ONLY. Raise the fee when the student IS a hosteller, or no
      -- group it belongs to is ticked, or at least one of its groups is open.
      -- cf.fee_id identifies the exact feetype row when the trigger resolved
      -- it; older template rows have it NULL and are matched by name.
      AND (
            COALESCE(UPPER(TRIM(s.hostel)), 'N') = 'Y'
            OR NOT EXISTS (
                 SELECT 1 FROM %1$I.feetype ft
                   JOIN %1$I.feegroup fg ON fg.fg_id = ft.fg_id
                  WHERE ft.activestatus = 1
                    AND (CASE WHEN cf.fee_id IS NOT NULL THEN ft.fee_id = cf.fee_id
                              ELSE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(cf.cffeetype)) END)
                    AND fg.hostellers_only)
            OR EXISTS (
                 SELECT 1 FROM %1$I.feetype ft
                   JOIN %1$I.feegroup fg ON fg.fg_id = ft.fg_id
                  WHERE ft.activestatus = 1
                    AND (CASE WHEN cf.fee_id IS NOT NULL THEN ft.fee_id = cf.fee_id
                              ELSE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(cf.cffeetype)) END)
                    AND NOT fg.hostellers_only)
          )
      AND NOT EXISTS (SELECT 1 FROM %1$I.tempfeedemand t
            WHERE t.stu_id = s.stu_id AND t.demfeeterm = cf.cfterm
              AND t.demfeetype = cf.cffeetype AND t.activestatus = 1)
      AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd
            WHERE fd.stu_id = s.stu_id AND fd.demfeeterm = cf.cfterm
              AND fd.demfeetype = cf.cffeetype AND fd.activestatus = 1)
  $q$, v_schema) USING p_class;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
GRANT EXECUTE ON FUNCTION public.generate_feedemand_for_class(integer, text) TO anon, authenticated;


-- =================================================================== PART B =
-- LOOK FIRST. Every PENDING demand that breaks the rule -- the 71 MESS FEE
-- rows and anything else like them. Read this before running PART C.
-- ===========================================================================

SELECT t.stuclass,
       t.demfeeterm,
       t.demfeetype,
       COALESCE(UPPER(TRIM(s.hostel)), '(blank)') AS hostel,
       COUNT(*)      AS rows_staged,
       SUM(t.feeamount) AS amount
  FROM kcet20262027.tempfeedemand t
  JOIN kcet20262027.students s ON s.stu_id = t.stu_id
 WHERE t.activestatus = 1
   AND t.isapproved = false
   AND COALESCE(UPPER(TRIM(s.hostel)), 'N') <> 'Y'
   AND EXISTS (SELECT 1 FROM kcet20262027.feetype ft
                 JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
                WHERE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(t.demfeetype))
                  AND ft.activestatus = 1 AND fg.hostellers_only)
   AND NOT EXISTS (SELECT 1 FROM kcet20262027.feetype ft
                     JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
                    WHERE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(t.demfeetype))
                      AND ft.activestatus = 1 AND NOT fg.hostellers_only)
 GROUP BY 1, 2, 3, 4
 ORDER BY 1, 3;


-- =================================================================== PART C =
-- Withdraw them. activestatus = 9 is exactly what the approval trigger stamps
-- on a temp row once it is done with -- the row drops out of Fee Demand
-- Approval, stops blocking a later legitimate generate (the dedup check reads
-- activestatus = 1), and is still there to look at. Nothing is deleted.
--
-- Only touches PENDING rows. An already-approved demand is in feedemand and
-- may have money against it; PART D reports those instead.
-- ===========================================================================

UPDATE kcet20262027.tempfeedemand t
   SET activestatus = 9
  FROM kcet20262027.students s
 WHERE s.stu_id = t.stu_id
   AND t.activestatus = 1
   AND t.isapproved = false
   AND COALESCE(UPPER(TRIM(s.hostel)), 'N') <> 'Y'
   AND EXISTS (SELECT 1 FROM kcet20262027.feetype ft
                 JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
                WHERE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(t.demfeetype))
                  AND ft.activestatus = 1 AND fg.hostellers_only)
   AND NOT EXISTS (SELECT 1 FROM kcet20262027.feetype ft
                     JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
                    WHERE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(t.demfeetype))
                      AND ft.activestatus = 1 AND NOT fg.hostellers_only);


-- =================================================================== PART D =
-- REPORT ONLY -- approved demands that break the rule, if any slipped through
-- before this fix. Nothing is changed: a demand with paidamount > 0 has money
-- against it and cancelling it is an office decision, not a migration's.
-- Expect 0 rows. If not, send me this output.
-- ===========================================================================

SELECT fd.demno, fd.stuadmno, s.stuname, fd.stuclass, fd.demfeetype,
       fd.feeamount, fd.paidamount, fd.balancedue,
       COALESCE(UPPER(TRIM(s.hostel)), '(blank)') AS hostel
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id
 WHERE fd.activestatus = 1
   AND COALESCE(UPPER(TRIM(s.hostel)), 'N') <> 'Y'
   AND EXISTS (SELECT 1 FROM kcet20262027.feetype ft
                 JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
                WHERE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(fd.demfeetype))
                  AND ft.activestatus = 1 AND fg.hostellers_only)
   AND NOT EXISTS (SELECT 1 FROM kcet20262027.feetype ft
                     JOIN kcet20262027.feegroup fg ON fg.fg_id = ft.fg_id
                    WHERE UPPER(TRIM(ft.feedesc)) = UPPER(TRIM(fd.demfeetype))
                      AND ft.activestatus = 1 AND NOT fg.hostellers_only)
 ORDER BY fd.stuclass, fd.demfeetype, fd.stuadmno;
