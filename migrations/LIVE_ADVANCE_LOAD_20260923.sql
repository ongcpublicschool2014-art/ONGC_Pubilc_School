-- ############################################################################
--
--   EduCore360 -- LOAD STUDENT ADVANCES INTO LIVE, 23-09-2026
--
--   149 advance receipts from KCETAdvCol2627.xlsx, total Rs 1389156.00
--   (88 cash, 47 cheque, 14 dd)
--
--   Run the whole file, top to bottom, in the SQL editor on the LIVE project.
--   CHECK THE URL FIRST -- it must read /project/exasnbapvgfeooxyxjas. The TEST
--   project carries the same name and the same PRODUCTION chip, and the org is
--   the only thing that tells them apart at a glance.
--
-- ----------------------------------------------------------------------------
-- WHAT IT DOES
-- ----------------------------------------------------------------------------
-- Inserts 149 rows into <year schema>.advance_collection -- the exact rows
-- that are live on TEST today, read back out of TEST rather than rebuilt from
-- the spreadsheet, so live ends up matching the database that was verified.
--
-- Every row is a student advance (advtype 'S') that has already been received,
-- so all of them arrive reconciled ('R') rather than queued in Bank
-- Reconciliation.
--
-- It touches NOTHING else. No fee demand, receipt, payment or student row is
-- written -- students are only READ, to attach each advance to the right one.
--
-- ----------------------------------------------------------------------------
-- SAFE TO RUN, AND SAFE TO RE-RUN
-- ----------------------------------------------------------------------------
-- 1. ALL OR NOTHING. The SQL editor runs this as one transaction and the script
--    aborts on any problem, so it either loads all 149 rows or leaves live
--    exactly as it was. There is no half-loaded state.
--
-- 2. IT MATCHES STUDENTS BY REG NUMBER, not by the internal stu_id TEST uses.
--    If even one reg number does not resolve to exactly one student on live,
--    the script names it and stops before inserting anything.
--
-- 3. RE-RUNNING CHANGES NOTHING. uq_advance_advno (ins_id, advno) makes a
--    receipt number that is already there a no-op, so running it twice cannot
--    double anyone's advance.
--
-- 4. IT CHECKS ITS OWN WORK. After inserting it counts the rows and sums the
--    money, and aborts unless they are exactly 149 and 1389156.00. This is
--    not decoration -- it is what caught a stale source file while this script
--    was being written.
--
-- 5. IT IS REVERSIBLE. Every row is stamped createdby = 'ADVANCE IMPORT KCETAdvCol2627'.
--    To undo the whole load:
--       DELETE FROM <schema>.advance_collection WHERE createdby = 'ADVANCE IMPORT KCETAdvCol2627';
--    Do that ONLY before any of these advances has been adjusted against a
--    fee -- after that the adjustment has to be reversed first.
--
-- ----------------------------------------------------------------------------
-- TWO THINGS TO KNOW BEFORE YOU RUN IT
-- ----------------------------------------------------------------------------
-- * 3 of the 149 rows are dated 2025, totalling Rs 8695.00 --
--   the FC24 and SA25 series. They are prior-year advances that were never
--   adjusted, and the dates are as the sheet has them. They ARE included. If
--   they should not go into live, say so first: they are exactly the rows where
--   advdate < 2026-01-01.
--
-- * Each advance is money the college already holds. Once loaded, these
--   students can have it adjusted against their fees, so load this only when
--   you intend that to become available.
--
-- ----------------------------------------------------------------------------
-- WHAT YOU SHOULD SEE
-- ----------------------------------------------------------------------------
-- One row: the schema it loaded into, 149 advances, total 1389156.00, the
-- date range and how many were dated 2025. Anything else -- including an error
-- -- means nothing was written.
--
-- Dry-run against the TEST project (a restore of live) before release.
-- ############################################################################


-- ----------------------------------------------------------------------------
-- 0 -- REFUSE TO RUN ON THE TEST PROJECT
--
-- public._this_is_the_test_project exists on TEST and nowhere else. If this is
-- TEST, the script stops here and nothing below it runs -- the editor executes
-- the file as one transaction, so an abort leaves the database untouched.
--
-- Both projects are named KCET and both show the PRODUCTION chip; this is the
-- check that does not depend on noticing that.
-- ----------------------------------------------------------------------------
DO $guard$
BEGIN
  IF to_regclass('public._this_is_the_test_project') IS NOT NULL THEN
    RAISE EXCEPTION
      'This is the TEST project -- this script is for LIVE only. Nothing was written. Switch to the live project (URL must read /project/exasnbapvgfeooxyxjas) and run it again.';
  END IF;
END $guard$;


-- ----------------------------------------------------------------------------
-- 1 -- the rows
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
('FC24/09999A', '2526186', '2026-06-06'::date, 1000.00, 'cheque', '105526148468', '105526148468', NULL),
('FC24/10269A', '2526207', '2026-06-16'::date, 5000.00, 'cheque', '873082594297', '873082594297', NULL),
('FC24/10354A', '2526211', '2026-06-20'::date, 5000.00, 'cheque', '838859998226', '838859998226', NULL),
('FC24/10422A', '2526234', '2026-06-25'::date, 1000.00, 'cash', NULL, NULL, '8470'),
('FC24/10428A', '2526235', '2026-06-25'::date, 5000.00, 'cash', NULL, NULL, NULL),
('FC24/10468A', '2526246', '2026-06-27'::date, 5000.00, 'cash', NULL, NULL, NULL),
('FC24/10494A', '2526248', '2026-06-30'::date, 5000.00, 'cash', NULL, NULL, '8477'),
('FC24/10530A', '2526254', '2026-07-03'::date, 10000.00, 'cheque', '554872772039', '554872772039', '8478'),
('FC24/10576A', '421325431003', '2026-07-07'::date, 1000.00, 'cash', NULL, NULL, '164'),
('FC24/10626A', '2526271', '2026-07-15'::date, 1000.00, 'cheque', '515508148794', '515508148794', '8425'),
('FC24/10641A', '2526277', '2026-07-16'::date, 3000.00, 'cash', NULL, NULL, NULL),
('FC25/11899A', '2627126', '2026-05-26'::date, 3500.00, 'cash', NULL, NULL, '8958'),
('FC25/11901A', '2627127', '2026-05-26'::date, 30000.00, 'cash', NULL, NULL, '8959'),
('FC25/11905A', '2627128', '2026-05-26'::date, 5000.00, 'cash', NULL, NULL, '8960'),
('FC25/11907A', '2627119', '2026-05-26'::date, 5500.00, 'cheque', '1851', '1851', '5000+500/8951'),
('FC25/11908A', '2627117', '2026-05-26'::date, 10500.00, 'cheque', '6358', '6358', NULL),
('FC25/11909A', '2627118', '2026-05-26'::date, 10500.00, 'cheque', '4545', '4545', NULL),
('FC25/11917A', '2627129', '2026-05-26'::date, 15500.00, 'cash', NULL, NULL, '8962'),
('FC25/11919A', '2627131', '2026-05-26'::date, 2500.00, 'cash', NULL, NULL, '8965'),
('FC25/11935A', '2627134', '2026-05-27'::date, 2000.00, 'cash', NULL, NULL, '8744'),
('FC25/11937A', '2627135', '2026-05-27'::date, 5500.00, 'cash', NULL, NULL, '55'),
('FC25/11940A', '2627137', '2026-05-27'::date, 20500.00, 'cash', NULL, NULL, '8968'),
('FC25/11941A', '2627138', '2026-05-27'::date, 5500.00, 'cash', NULL, NULL, '8969'),
('FC25/11945A', '2627139', '2026-05-27'::date, 1500.00, 'cash', NULL, NULL, '8972'),
('FC25/11953A', '2627130', '2026-05-27'::date, 20000.00, 'cheque', '123727018809', '123727018809', NULL),
('FC25/11954A', '262789', '2026-05-27'::date, 5000.00, 'cheque', 'BY KCSAM', 'BY KCSAM', NULL),
('FC25/11958A', '2627133', '2026-05-27'::date, 500.00, 'cheque', '5209', '5209', '8961 ECE MATHAN'),
('FC25/11959A', '2627127', '2026-05-27'::date, 500.00, 'cheque', '11122', '11122', NULL),
('FC25/11970A', '2627142', '2026-05-27'::date, 5000.00, 'cash', NULL, NULL, '8849'),
('FC25/11990A', '2627144', '2026-05-29'::date, 1000.00, 'cash', NULL, NULL, NULL),
('FC25/11994A', '2627113', '2026-05-29'::date, 40000.00, 'cash', NULL, NULL, NULL),
('FC25/11995A', '2627146', '2026-05-29'::date, 3500.00, 'cash', NULL, NULL, '8912'),
('FC25/11996A', '2627147', '2026-05-29'::date, 5000.00, 'cash', NULL, NULL, NULL),
('FC25/11997A', '2627148', '2026-05-29'::date, 4000.00, 'cash', NULL, NULL, NULL),
('FC25/11999A', '2627149', '2026-05-29'::date, 16000.00, 'cash', NULL, NULL, '8823'),
('FC25/12009A', '2627141', '2026-05-29'::date, 20500.00, 'cheque', '1143', '1143', '8975'),
('FC25/12010A', '2627140', '2026-05-29'::date, 1500.00, 'cheque', '6914', '6914', '8973'),
('FC25/12012A', '2627133', '2026-05-29'::date, 1000.00, 'cheque', '70993', '70993', NULL),
('FC25/12028A', '2627151', '2026-05-30'::date, 2000.00, 'cash', NULL, NULL, '8917'),
('FC25/12064A', '2627153', '2026-06-01'::date, 4000.00, 'cash', NULL, NULL, NULL),
('FC25/12066A', '2627154', '2026-06-01'::date, 10000.00, 'cash', NULL, NULL, NULL),
('FC25/12067A', '262704', '2026-06-01'::date, 33000.00, 'cash', NULL, NULL, NULL),
('FC25/12070A', '2627155', '2026-06-01'::date, 1000.00, 'cash', NULL, NULL, NULL),
('FC25/12106A', '2627157', '2026-06-01'::date, 5500.00, 'cash', NULL, NULL, '8922'),
('FC25/12125A', '2627158', '2026-06-01'::date, 5500.00, 'cash', NULL, NULL, '8924'),
('FC25/12178A', '2627160', '2026-06-02'::date, 1000.00, 'cash', NULL, NULL, NULL),
('FC25/12186A', '2627161', '2026-06-02'::date, 2500.00, 'cash', NULL, NULL, '8927'),
('FC25/12200A', '2627162', '2026-06-03'::date, 30000.00, 'cash', NULL, NULL, NULL),
('FC25/12205A', '2627164', '2026-06-03'::date, 1500.00, 'cash', NULL, NULL, '8933'),
('FC25/12206A', '2627165', '2026-06-03'::date, 1500.00, 'cash', NULL, NULL, '8934'),
('FC25/12207A', '2627167', '2026-06-03'::date, 500.00, 'cash', NULL, NULL, '8935'),
('FC25/12209A', '2627168', '2026-06-03'::date, 3500.00, 'cash', NULL, NULL, '58'),
('FC25/12210A', '2627169', '2026-06-03'::date, 500.00, 'cash', NULL, NULL, '8936'),
('FC25/12220A', '2627172', '2026-06-03'::date, 5500.00, 'cash', NULL, NULL, '8938'),
('FC25/12221A', '2627174', '2026-06-03'::date, 2000.00, 'cheque', '2977', '2977', NULL),
('FC25/12235A', '2627175', '2026-06-03'::date, 2000.00, 'cash', NULL, NULL, NULL),
('FC25/12273A', '2627177', '2026-06-03'::date, 2000.00, 'cash', NULL, NULL, NULL),
('FC25/12277A', '2627176', '2026-06-04'::date, 25000.00, 'cheque', '33672', '33672', NULL),
('FC25/12281A', '2627170', '2026-06-04'::date, 1500.00, 'cheque', '6634', '6634', NULL),
('FC25/12282A', '2627169', '2026-06-04'::date, 5000.00, 'cheque', '8727', '8727', NULL),
('FC25/12283A', '2627168', '2026-06-04'::date, 2000.00, 'cheque', '3838', '3838', NULL),
('FC25/12284A', '2627167', '2026-06-04'::date, 2000.00, 'cheque', '24255', '24255', '8935'),
('FC25/12293A', '2627179', '2026-06-04'::date, 2500.00, 'cash', NULL, NULL, '8942'),
('FC25/12295A', '2627181', '2026-06-04'::date, 1500.00, 'cash', NULL, NULL, '8943'),
('FC25/12309A', '2627183', '2026-06-05'::date, 500.00, 'cash', NULL, NULL, '8880'),
('FC25/12315A', '2627178', '2026-06-05'::date, 10500.00, 'cheque', '652144805219', '652144805219', '8941'),
('FC25/12321A', '2627184', '2026-06-05'::date, 1000.00, 'cash', NULL, NULL, NULL),
('FC25/12322A', '2627185', '2026-06-05'::date, 2500.00, 'cash', NULL, NULL, '8883'),
('FC25/12457A', '2627186', '2026-06-06'::date, 5500.00, 'cheque', '5500', '5500', '8885'),
('FC25/12463A', '2627183', '2026-06-06'::date, 5000.00, 'cheque', '8345', '8345', NULL),
('FC25/12464A', '2627188', '2026-06-06'::date, 1500.00, 'cheque', '63436', '63436', '8945'),
('FC25/12490A', '2627189', '2026-06-08'::date, 1500.00, 'cash', NULL, NULL, '60'),
('FC25/12491A', '2627191', '2026-06-08'::date, 1500.00, 'cash', NULL, NULL, '62'),
('FC25/12496A', '2627192', '2026-06-08'::date, 1500.00, 'cash', NULL, NULL, '8887'),
('FC25/12509A', '2627194', '2026-06-09'::date, 1500.00, 'cash', NULL, NULL, '8888'),
('FC25/12517A', '2627193', '2026-06-09'::date, 25000.00, 'cheque', '1529', '1529', NULL),
('FC25/12534A', '2627196', '2026-06-10'::date, 10000.00, 'cash', NULL, NULL, NULL),
('FC25/12569A', '2627197', '2026-06-11'::date, 1000.00, 'cash', NULL, NULL, NULL),
('FC25/12575A', '2627198', '2026-06-11'::date, 6000.00, 'cash', NULL, NULL, NULL),
('FC25/12581A', '2627130', '2026-06-12'::date, 25000.00, 'cash', NULL, NULL, NULL),
('FC25/12582A', '2627165', '2026-06-12'::date, 9001.00, 'cheque', '438877693413', '438877693413', NULL),
('FC25/12583A', '2627200', '2026-06-12'::date, 10000.00, 'cash', NULL, NULL, NULL),
('FC25/12585A', '262776', '2026-06-12'::date, 15000.00, 'cheque', '652875311270', '652875311270', NULL),
('FC25/12586A', '2627198', '2026-06-12'::date, 4000.00, 'cheque', '669129034548', '669129034548', NULL),
('FC25/12589A', '2627202', '2026-06-12'::date, 5500.00, 'cheque', '616267594605', '616267594605', NULL),
('FC25/12596A', '2627129', '2026-06-12'::date, 30000.00, 'cheque', '124550232330', '124550232330', NULL),
('FC25/12602A', '2627204', '2026-06-12'::date, 4500.00, 'cash', NULL, NULL, NULL),
('FC25/12603A', '2627204', '2026-06-12'::date, 500.00, 'cheque', '11.06.2026', '11.06.2026', NULL),
('FC25/12611A', '2627205', '2026-06-13'::date, 20000.00, 'cash', NULL, NULL, NULL),
('FC25/12613A', '262717', '2026-06-13'::date, 20000.00, 'cash', NULL, NULL, NULL),
('FC25/12614A', '262718', '2026-06-13'::date, 65000.00, 'cash', NULL, NULL, NULL),
('FC25/12624A', '262798', '2026-06-15'::date, 20000.00, 'cheque', '707676257345', '707676257345', NULL),
('FC25/12627A', '2627206', '2026-06-15'::date, 15000.00, 'cash', NULL, NULL, NULL),
('FC25/12639A', '2627207', '2026-06-16'::date, 2000.00, 'cash', NULL, NULL, NULL),
('FC25/12643A', '2627208', '2026-06-16'::date, 4500.00, 'cheque', '124767054889,69', '124767054889,69', NULL),
('FC25/12650A', '262741', '2026-06-17'::date, 20000.00, 'cash', NULL, NULL, NULL),
('FC25/12651A', '2627209', '2026-06-17'::date, 5000.00, 'cash', NULL, NULL, NULL),
('FC25/12662A', '2627213', '2026-06-17'::date, 5000.00, 'cash', NULL, NULL, NULL),
('FC25/12665A', '262794', '2026-06-17'::date, 15000.00, 'cash', NULL, NULL, NULL),
('FC25/12668A', '262787', '2026-06-18'::date, 30000.00, 'cash', NULL, NULL, NULL),
('FC25/12671A', '2627212', '2026-06-18'::date, 20500.00, 'cheque', '35160', '35160', '8900'),
('FC25/12678A', '2627214', '2026-06-18'::date, 20000.00, 'cash', NULL, NULL, NULL),
('FC25/12686A', '262796', '2026-06-19'::date, 30000.00, 'cheque', '616954547748', '616954547748', NULL),
('FC25/12687A', '2627217', '2026-06-19'::date, 2000.00, 'cheque', '616952572143', '616952572143', NULL),
('FC25/12688A', '2627216', '2026-06-19'::date, 5500.00, 'cheque', '64990', '64990', '130'),
('FC25/12691A', '2627219', '2026-06-19'::date, 40500.00, 'cheque', '56037', '56037', '8904'),
('FC25/12694A', '262710', '2026-06-19'::date, 20000.00, 'cash', NULL, NULL, NULL),
('FC25/12697A', '2627220', '2026-06-19'::date, 20500.00, 'cash', NULL, NULL, '8908'),
('FC25/12699A', '2627221', '2026-06-19'::date, 80500.00, 'cash', NULL, NULL, '8905'),
('FC25/12700A', '2627176', '2026-06-19'::date, 15000.00, 'cash', NULL, NULL, NULL),
('FC25/12708A', '262753', '2026-06-22'::date, 30000.00, 'cash', NULL, NULL, '20.06.2026'),
('FC25/12709A', '2627223', '2026-06-22'::date, 10500.00, 'cash', NULL, NULL, '171'),
('FC25/12710A', '2627226', '2026-06-22'::date, 4500.00, 'cash', NULL, NULL, '68'),
('FC25/12711A', '2627229', '2026-06-22'::date, 5000.00, 'cash', NULL, NULL, NULL),
('FC25/12712A', '2627228', '2026-06-22'::date, 5000.00, 'cash', NULL, NULL, NULL),
('FC25/12714A', '2627230', '2026-06-22'::date, 1500.00, 'cash', NULL, NULL, '8979'),
('FC25/12715A', '2627231', '2026-06-22'::date, 10500.00, 'cash', NULL, NULL, '8980'),
('FC25/12717A', '2627107', '2026-06-23'::date, 20000.00, 'cash', NULL, NULL, NULL),
('FC25/12723A', '2627225', '2026-06-23'::date, 5500.00, 'cheque', '125125880876', '125125880876', '67'),
('FC25/12724A', '2627224', '2026-06-23'::date, 5500.00, 'cheque', '125125880876', '125125880876', '66'),
('FC25/12725A', '2627227', '2026-06-23'::date, 3000.00, 'cheque', '617363561337', '617363561337', '69'),
('FC25/12727A', '2627232', '2026-06-24'::date, 5500.00, 'cash', NULL, NULL, '145'),
('FC25/12730A', '262774', '2026-06-24'::date, 25000.00, 'cheque', '617436281515', '617436281515', NULL),
('FC25/12734A', '262732', '2026-06-24'::date, 25000.00, 'cash', NULL, NULL, NULL),
('FC25/12736A', '2627189', '2026-06-24'::date, 19000.00, 'cash', NULL, NULL, NULL),
('FC25/12737A', '2627191', '2026-06-24'::date, 19000.00, 'cash', NULL, NULL, NULL),
('FC25/12738A', '2627235', '2026-06-24'::date, 1500.00, 'cash', NULL, NULL, '8983'),
('FC25/12745A', '2627236', '2026-06-25'::date, 1000.00, 'cash', NULL, NULL, NULL),
('FC25/12773A', '2627237', '2026-06-29'::date, 2500.00, 'cheque', '92398078', '92398078', '175'),
('FC25/12774A', '2627198', '2026-06-29'::date, 30000.00, 'cheque', '617673646188', '617673646188', NULL),
('FC25/12775A', '2627238', '2026-06-29'::date, 1500.00, 'cash', NULL, NULL, '8984'),
('FC25/12776A', '2627234', '2026-06-29'::date, 5500.00, 'cheque', '617506332295', '617506332295', '8982'),
('FC25/12779A', '2627240', '2026-06-29'::date, 5000.00, 'cash', NULL, NULL, NULL),
('FC25/12781A', '2627241', '2026-06-29'::date, 2000.00, 'cash', NULL, NULL, '151'),
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
('SA2600299', '421324243041', '2026-07-29'::date, 10000.00, 'dd', 'FC26/00788', 'FC26/00788', NULL);


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
  EXECUTE format($q$ SELECT count(*), COALESCE(sum(transtotalamount), 0)
                       FROM %I.advance_collection WHERE createdby = 'ADVANCE IMPORT KCETAdvCol2627' $q$,
    v_schema) INTO n_got, t_got;

  IF n_got <> n_in OR t_got <> 1389156.00 THEN
    RAISE EXCEPTION 'Load does not balance: % rows / % total, expected % / 1389156.00 -- nothing kept',
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
      SELECT %L::text AS schema, count(*) AS advances,
             sum(transtotalamount) AS total,
             min(advdate)::date AS first_date, max(advdate)::date AS last_date,
             count(*) FILTER (WHERE advdate < '2026-01-01') AS dated_2025
        FROM %I.advance_collection WHERE createdby = 'ADVANCE IMPORT KCETAdvCol2627' $q$,
    v_schema, v_schema);
END $show$;

SELECT * FROM _adv_loaded;
