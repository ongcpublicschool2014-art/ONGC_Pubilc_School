-- ############################################################################
--
--   EduCore360 -- LOAD THE 15 "SA" ADVANCES INTO LIVE, 24-09-2026
--
--   The SA-numbered advance receipts from KCETAdvCol2627.xlsx -- 15 rows,
--   total Rs 55,155.00 (14 dd, 1 cheque), dated 25-10-2025 to 29-07-2026.
--
--   Run the whole file, top to bottom, in the SQL editor on the LIVE project.
--   It refuses to run on TEST, so a mis-click costs nothing.
--
-- ----------------------------------------------------------------------------
-- HOW THIS RELATES TO THE 149-ROW LOAD
-- ----------------------------------------------------------------------------
-- LIVE_ADVANCE_LOAD_20260923.sql carries all 149 advances from that
-- spreadsheet: 134 with FC receipt numbers and these 15 with SA ones. This
-- file is the SA slice on its own, for loading them separately.
--
-- THE TWO COMPOSE, IN EITHER ORDER, AND NEITHER DOUBLE-COUNTS:
--
--   * Both stamp the same createdby, 'ADVANCE IMPORT KCETAdvCol2627', so after
--     both have run the 149-row script's own check still sees 149 / 1389156.00.
--   * uq_advance_advno (ins_id, advno) plus ON CONFLICT DO NOTHING means a
--     receipt already present is skipped, not duplicated.
--   * This file's check counts only the SA rows, so running the 149 first and
--     this one second still passes -- it finds the 15 already there and
--     confirms them rather than failing on a count it did not write.
--
-- So: run this now for the SA advances, and the 149-row file later for the
-- rest, or not at all. Nothing is lost either way.
--
-- ----------------------------------------------------------------------------
-- WHAT IT DOES
-- ----------------------------------------------------------------------------
-- Inserts 15 rows into <year schema>.advance_collection -- the exact rows that
-- are live on TEST today, read back out of TEST rather than rebuilt from the
-- spreadsheet, so live ends up matching the database that was verified.
--
-- Every row is a student advance (advtype 'S') that has ALREADY BEEN RECEIVED,
-- so each arrives reconciled ('R') rather than queued in Bank Reconciliation.
-- None of the 15 has been adjusted or refunded, so each lands with its full
-- amount still available to spend.
--
-- It touches NOTHING else. No fee demand, receipt, payment or student row is
-- written -- students are only READ, to attach each advance to the right one.
--
-- ----------------------------------------------------------------------------
-- IT KEEPS THE SHEET'S OWN RECEIPT NUMBERS
-- ----------------------------------------------------------------------------
-- SA2500334 ... SA2600299 are carried across exactly as they are. They are NOT
-- renumbered from the ADVNO sequence, because these receipts were already
-- issued to families under those numbers.
--
-- That also means they do not advance the ADVNO counter, and they cannot
-- collide with it: ADVNO issues SA + 5 digits (SA00001), seven characters,
-- while these are SA + 7 digits, nine. See ADVNO_PREFIX_SA.sql, which reads
-- the highest number actually issued before setting the counter.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RUN, AND SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- 1. ALL OR NOTHING. The SQL editor runs this as one transaction and it aborts
--    on any problem, so it loads all 15 rows or leaves live exactly as it was.
--
-- 2. IT MATCHES STUDENTS BY REG NUMBER, not by the internal stu_id TEST uses.
--    If even one reg number does not resolve to exactly one student on live,
--    the script names it and stops before inserting anything.
--
-- 3. RE-RUNNING CHANGES NOTHING, for the reasons above.
--
-- 4. IT CHECKS ITS OWN WORK -- 15 rows and 55,155.00 exactly, or nothing is
--    kept.
--
-- ----------------------------------------------------------------------------
-- BEFORE IT WILL WORK
-- ----------------------------------------------------------------------------
-- advance_collection has to exist on live, which means
-- LIVE_RELEASE_0_0_8.sql must have run first. Without it this file stops at
-- the insert, having written nothing.
--
-- ----------------------------------------------------------------------------
-- WHAT YOU SHOULD SEE
-- ----------------------------------------------------------------------------
-- ONE row: the schema, 15 advances, 55155.00, the first and last dates, and
-- how many are dated 2025 (3 of them -- those are genuine, not typos; the
-- SA25 prefix covers 5 receipts, but 2 of those were paid in 2026).
-- ############################################################################


-- ----------------------------------------------------------------------------
-- 0 -- REFUSE TO RUN ON THE TEST PROJECT
--
-- public._this_is_the_test_project exists on TEST and nowhere else. Both
-- projects are named KCET and both show the PRODUCTION chip; this is the check
-- that does not depend on noticing that.
-- ----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public._this_is_the_test_project') IS NOT NULL THEN
    RAISE EXCEPTION
      'This is the TEST project -- these advances are already loaded here. Nothing was written. Switch to the live project (URL must read /project/exasnbapvgfeooxyxjas) and run it again.';
  END IF;
END $guard$;


-- ----------------------------------------------------------------------------
-- 1 -- the 15 advances, exactly as they stand on TEST
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _adv_in (
  advno    text,
  stuadmno text,
  advdate  date,
  amount   numeric(12,2),
  mode     text,
  ref      text,
  chq      text,
  remarks  text
) ON COMMIT DROP;

INSERT INTO _adv_in VALUES
('SA2500334', '421324105030', '2025-10-25'::date, 1475.00, 'dd', 'FC25/02776', 'FC25/02776', NULL),
('SA2500339', '421323104003', '2025-11-08'::date, 2220.00, 'dd', 'FC25/00733', 'FC25/00733', NULL),
('SA2500346', '421325114019', '2025-12-27'::date, 5000.00, 'dd', 'FC25/00217', 'FC25/00217', NULL),
('SA2500348', '421323105049', '2026-04-15'::date, 4880.00, 'dd', 'FC25/06699', 'FC25/06699', NULL),
('SA2500354', '421325103012', '2026-05-11'::date, 7550.00, 'dd', 'FC25/06222', 'FC25/06222', NULL),
('SA2600001', '421323205040', '2026-07-15'::date, 600.00, 'dd', 'FC24/09228', 'FC24/09228', NULL),
('SA2600004', '421324105014', '2026-07-15'::date, 500.00, 'dd', 'FC24/04501', 'FC24/04501', NULL),
('SA2600005', '421325205042', '2026-07-15'::date, 6000.00, 'cheque', 'FC25/01892', 'FC25/01892', NULL),
('SA2600006', '421323205042', '2026-07-15'::date, 275.00, 'dd', 'FC25/04826', 'FC25/04826', NULL),
('SA2600007', '421323114019', '2026-07-15'::date, 55.00, 'dd', 'FC25/05237', 'FC25/05237', NULL),
('SA2600295', '421323104003', '2026-07-20'::date, 5675.00, 'dd', 'FC26/00371', 'FC26/00371', NULL),
('SA2600296', '421324104034', '2026-07-22'::date, 1175.00, 'dd', 'FC26/00415', 'FC26/00415', NULL),
('SA2600297', '421324205029', '2026-07-23'::date, 4875.00, 'dd', 'FC26/00615', 'FC26/00615', NULL),
('SA2600298', '421324106032', '2026-07-28'::date, 4875.00, 'dd', 'FC26/00736', 'FC26/00736', NULL),
('SA2600299', '421324243041', '2026-07-29'::date, 10000.00, 'dd', 'FC26/00788', 'FC26/00788', NULL);;


-- ----------------------------------------------------------------------------
-- 2 -- resolve the year schema, check every reg number, then load
-- ----------------------------------------------------------------------------
DO $load$
DECLARE
  v_schema  text;
  v_missing text;
  v_dupes   text;
  n_in  int;
  n_got int;
  t_got numeric;
BEGIN
  -- The active year schema, resolved the way the app resolves it.
  SELECT lower(i.inshortname) || replace(y.yrlabel, '-', '')
    INTO v_schema
    FROM public.institution i
    JOIN public.institutionyear y ON y.ins_id = i.ins_id AND y.activestatus = 1
   WHERE i.ins_id = 1
   ORDER BY y.iyr_id DESC
   LIMIT 1;

  IF v_schema IS NULL THEN
    RAISE EXCEPTION 'No active academic year for ins_id 1 -- nothing loaded';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_schema) THEN
    RAISE EXCEPTION 'Resolved schema % does not exist -- nothing loaded', v_schema;
  END IF;
  IF to_regclass(format('%I.advance_collection', v_schema)) IS NULL THEN
    RAISE EXCEPTION 'advance_collection does not exist in % -- run LIVE_RELEASE_0_0_8.sql first. Nothing loaded.', v_schema;
  END IF;

  -- Reg numbers that match no student on live.
  EXECUTE format($q$
    SELECT string_agg(i.stuadmno || ' (' || i.advno || ')', ', ' ORDER BY i.advno)
      FROM _adv_in i
     WHERE NOT EXISTS (SELECT 1 FROM %I.students s
                        WHERE s.ins_id = 1 AND s.stuadmno = i.stuadmno) $q$,
    v_schema) INTO v_missing;
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'These reg numbers are not on live: % -- nothing loaded', v_missing;
  END IF;

  -- A reg number held by more than one student row would attach the advance to
  -- an arbitrary one, so refuse rather than guess.
  EXECUTE format($q$
    SELECT string_agg(x.stuadmno, ', ')
      FROM (SELECT s.stuadmno
              FROM %I.students s
             WHERE s.ins_id = 1
               AND s.stuadmno IN (SELECT stuadmno FROM _adv_in)
             GROUP BY s.stuadmno HAVING count(*) > 1) x $q$,
    v_schema) INTO v_dupes;
  IF v_dupes IS NOT NULL THEN
    RAISE EXCEPTION 'These reg numbers match more than one student: % -- nothing loaded', v_dupes;
  END IF;

  -- Load. Everything except the money comes from the student record, so class
  -- and course are the CURRENT ones -- the sheet had transferred students under
  -- their old class.
  EXECUTE format($q$
    INSERT INTO %I.advance_collection
      (ins_id, inscode, stu_id, stuadmno, stuname, stuclass, courname, yr_id, yrlabel,
       advno, advdate, advtype, transtotalamount, paymethod, payreference,
       paychequeno, recon_status, reconciled_by, reconciled_date,
       remarks, createdby, createdat, activestatus)
    SELECT s.ins_id, s.inscode, s.stu_id, s.stuadmno, s.stuname, s.stuclass, s.courname,
           s.yr_id, s.yrlabel,
           i.advno, i.advdate::timestamp, 'S', i.amount, i.mode, NULLIF(i.ref, ''),
           NULLIF(i.chq, ''),
           'R', 'ADVANCE IMPORT KCETAdvCol2627', now(),
           NULLIF(i.remarks, ''), 'ADVANCE IMPORT KCETAdvCol2627', now(), 1
      FROM _adv_in i
      JOIN %I.students s ON s.ins_id = 1 AND s.stuadmno = i.stuadmno
    ON CONFLICT (ins_id, advno) DO NOTHING $q$,
    v_schema, v_schema);

  SELECT count(*) INTO n_in FROM _adv_in;
  -- Counted SA-ONLY, not by the createdby tag alone. The 149-row load stamps
  -- the same tag, so if it has already run, a tag-wide count would find 149
  -- here and fail on a number this file never claimed to write.
  EXECUTE format($q$ SELECT count(*), COALESCE(sum(transtotalamount), 0)
                       FROM %I.advance_collection
                      WHERE createdby = 'ADVANCE IMPORT KCETAdvCol2627'
                        AND advno LIKE 'SA%%' $q$,
    v_schema) INTO n_got, t_got;

  IF n_got <> n_in OR t_got <> 55155.00 THEN
    RAISE EXCEPTION 'Load does not balance: % rows / % total, expected % / 55155.00 -- nothing kept',
      n_got, t_got, n_in;
  END IF;
END $load$;


-- ----------------------------------------------------------------------------
-- 3 -- what was loaded (the editor shows only this last result)
-- ----------------------------------------------------------------------------
DO $show$
DECLARE v_schema text;
BEGIN
  SELECT lower(i.inshortname) || replace(y.yrlabel, '-', '')
    INTO v_schema
    FROM public.institution i
    JOIN public.institutionyear y ON y.ins_id = i.ins_id AND y.activestatus = 1
   WHERE i.ins_id = 1 ORDER BY y.iyr_id DESC LIMIT 1;
  EXECUTE format($q$
    CREATE TEMP VIEW _adv_loaded AS
      SELECT %L::text AS schema, count(*) AS sa_advances,
             sum(transtotalamount) AS total,
             min(advdate)::date AS first_date, max(advdate)::date AS last_date,
             count(*) FILTER (WHERE advdate < '2026-01-01') AS dated_2025
        FROM %I.advance_collection
       WHERE createdby = 'ADVANCE IMPORT KCETAdvCol2627' AND advno LIKE 'SA%%' $q$,
    v_schema, v_schema);
END $show$;

SELECT * FROM _adv_loaded;
