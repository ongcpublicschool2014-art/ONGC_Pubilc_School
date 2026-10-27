-- ============================================================================
-- Rs 2,700 at 15:38 on 12-10-2026 -- who was using the app?
-- ============================================================================
-- Paytm identifies the PAYER but not the student:
--     Ms S T, Google Pay, UPI sand***006@okicici, RRN 628508598587
-- No customer id was sent with the order, and there is no cart, payment row
-- or pending_collection to tie it to anyone.
--
-- So the question becomes: whose session was active when the order was made?
-- userlogin records parent and student sessions with a timestamp.
--
-- NONE OF THIS IS PROOF. It narrows the field; the office should confirm with
-- the family before the money is credited. Crediting the wrong student is
-- worse than leaving it uncredited -- they stop chasing it, and the real
-- payer still shows a balance.
-- ============================================================================


-- ============================================ 1. SESSIONS AROUND THE PAYMENT =
-- Anyone logged in between 15:00 and 16:00 today.
-- ===========================================================================

SELECT ul.ul_id, ul.uluser, ul.ulusetype, ul.ultime, ul.ulsesstart,
       ul.ulsuccess, ul.ulip
  FROM kcet20262027.userlogin ul
 WHERE COALESCE(ul.ulsesstart, ul.ultime)
       BETWEEN TIMESTAMP '2026-10-12 15:00' AND TIMESTAMP '2026-10-12 16:00'
 ORDER BY COALESCE(ul.ulsesstart, ul.ultime);


-- ======================== 2. OWES Rs 2,700 **AND** A PARENT NAMED S-SOMETHING =
-- Cross the 55 students who owe exactly Rs 2,700 against a parent/guardian or
-- payer whose name begins with S -- "Ms S T" on the Paytm record.
--
-- A short list here plus the family's confirmation is enough to act on. A
-- single hit is still not proof on its own.
-- ===========================================================================

SELECT s.stuadmno, s.stuname, s.stuclass,
       fd.dem_id, fd.demno, fd.demfeetype, fd.balancedue,
       p.fathername, p.mothername, p.guardianname,
       p.payincharge, p.payinchargemob, s.stumobile
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id
  LEFT JOIN kcet20262027.parentdetail pd ON pd.stu_id = s.stu_id
  LEFT JOIN kcet20262027.parents p ON p.par_id = pd.par_id
 WHERE fd.activestatus = 1
   AND fd.balancedue = 2700.00
   AND (   upper(COALESCE(p.mothername, ''))   LIKE 'S%'
        OR upper(COALESCE(p.fathername, ''))   LIKE 'S%'
        OR upper(COALESCE(p.guardianname, '')) LIKE 'S%'
        OR upper(COALESCE(p.payincharge, ''))  LIKE 'S%'
        OR upper(COALESCE(s.stuname, ''))      LIKE 'SAND%')
 ORDER BY s.stuadmno;


-- ================================= 3. ANY TRACE OF ACTIVITY IN THAT MINUTE =
-- Notifications are written per student and carry a timestamp. If the app
-- raised one around the payment, it names the student directly.
-- ===========================================================================

SELECT n.noti_id, n.stu_id, s.stuadmno, s.stuname,
       n.notititle, n.notitype, n.createdat
  FROM kcet20262027.notification n
  LEFT JOIN kcet20262027.students s ON s.stu_id = n.stu_id
 WHERE n.createdat BETWEEN TIMESTAMP '2026-10-12 15:20'
                       AND TIMESTAMP '2026-10-12 16:10'
 ORDER BY n.createdat;
