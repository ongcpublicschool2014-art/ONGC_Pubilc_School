-- ############################################################################
-- EduCore360 -- PRE-ADMISSION (seat booked now, studies from next year)
-- 19-09-2026
--
-- A student admitted during THIS year who will only start NEXT year. The
-- institution takes an admission collection from them now to hold the seat.
--
-- Two facts follow from that, and this file makes the database obey both:
--
--   1. They owe nothing this year. No fee demand is raised for them.
--   2. They DO NOT MOVE UP a class at the year change. The coming year is
--      their first, so they start in the class they were admitted to --
--      promoting them would make a first-year a second-year on day one.
--
-- And the money follows them: an unspent advance is carried into the new
-- year's schema, at its remaining balance, so the deposit can be adjusted
-- against the fees it was taken for.
--
-- WHAT CHANGES
--   * public.admission          + preadmission smallint (0/1)
--   * <schema>.students         + preadmission smallint (0/1)
--   * create_institution_schema   new schemas get the column
--   * allocate_admission_to_student  copies the flag onto the student
--   * generate_feedemand_for_class   skips pre-admission students
--   * rollover_academic_year         keeps their class, clears the flag in the
--                                    new year, and carries unspent advances
--
-- save_admission needs no change: it copies whatever columns public.admission
-- has, so the app sets the flag just by sending it.
--
-- SAFE TO RE-RUN. The columns are ADD COLUMN IF NOT EXISTS and default to 0,
-- so every existing student is an ordinary one; the functions are CREATE OR
-- REPLACE. No row changes meaning.
--
-- NOTE ON THE ROLLOVER: rollover_academic_year is still not called by the app
-- (the New Year button only creates an empty schema) and has other known
-- defects -- see docs/YEAR_ROLLOVER_DESIGN.md. This file changes only the two
-- things pre-admission needs; it is not the rollover repair.
--
-- Applied and checked on the TEST project first.
-- ############################################################################


-- ############################################################################
-- 1 -- THE COLUMN, on the shared admission table and on every year schema
-- ############################################################################
ALTER TABLE public.admission
  ADD COLUMN IF NOT EXISTS preadmission smallint DEFAULT 0 NOT NULL;

DO $cols$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'students'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS '
                   'preadmission smallint DEFAULT 0 NOT NULL', r.s);
    RAISE NOTICE '%.students: preadmission present', r.s;
  END LOOP;
END $cols$;


-- ############################################################################
-- 2 -- NEW SCHEMAS GET IT TOO
-- ############################################################################
CREATE OR REPLACE FUNCTION public.create_institution_schema(
  p_schema_name text,
  p_ins_id integer DEFAULT NULL,
  p_year_label text DEFAULT NULL,
  p_start_date date DEFAULT NULL,
  p_end_date date DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_schema text := lower(p_schema_name); v_inscode varchar(10);
BEGIN
  -- Get inscode for year record
  IF p_ins_id IS NOT NULL THEN
    SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = p_ins_id;
  END IF;
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);

  -- year
  EXECUTE format('CREATE TABLE %I.year (yr_id integer NOT NULL PRIMARY KEY, ins_id integer NOT NULL, yrlabel varchar(9) NOT NULL, yrstadate date NOT NULL, yrenddate date NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- students
  -- students — `aadharno + community/caste/religion/nationality/transportmode/hostel`
  -- columns are carried over from public.admission during class allocation.
  EXECUTE format('CREATE TABLE %I.students (stu_id bigint NOT NULL PRIMARY KEY CHECK (stu_id > 0), ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, stuadmno varchar(25) NOT NULL, stuadmdate date NOT NULL, stuname varchar(50) NOT NULL, stugender char(1) NOT NULL CHECK (stugender = ANY(ARRAY[''M'',''F'',''T''])), studob date NOT NULL, stumobile varchar(30), stuemail varchar(254), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stugeocoordinates varchar(40), stubloodgrp varchar(20), stuphoto text, stuclass varchar(20) NOT NULL, cour_id integer, admit_cour_id smallint, courname varchar(20), con_id integer, stucondesc varchar(20), stuser_id varchar(25) NOT NULL, stupassword varchar(255), stumobotp numeric(6,0), stuotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now() NOT NULL, suspendeddate date, suspendedby varchar(50), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,3,4,5,9])), createdon timestamp DEFAULT now() NOT NULL, terminatedreason text, batch varchar(9), preadmission smallint DEFAULT 0 NOT NULL CHECK (preadmission = ANY(ARRAY[0,1])), admname varchar(30), quoname varchar(30), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), emisno varchar(30), umisno varchar(30), scholarship char(1), scholarshiptype varchar(60), medium varchar(30), cla_id smallint, adm_id smallint, quo_id smallint)', v_schema);
  -- No UNIQUE on stuemail: students commonly share or lack an email (bulk import
  -- of hundreds would fail on the first shared/placeholder address).
  EXECUTE format('ALTER TABLE %I.students ADD CONSTRAINT uq_students_admission UNIQUE (ins_id, stuadmno)', v_schema);

  -- parents
  EXECUTE format('CREATE TABLE %I.parents (par_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), partype char(1) NOT NULL CHECK (partype = ANY(ARRAY[''P'',''G''])), paremail varchar(254), fathername varchar(50), mothername varchar(50), guardianname varchar(50), fathermobile varchar(20), mothermobile varchar(20), guardianmobile varchar(20), fatheroccupation varchar(60), motheroccupation varchar(60), guardianoccupation varchar(60), payincharge varchar(50) NOT NULL, payinchargemob varchar(20) NOT NULL, parpassword varchar(255), parmobotp numeric(6,0), parmobotp_at timestamp, parotpstatus smallint DEFAULT 0 NOT NULL, approvedby varchar(50), approveddate timestamp DEFAULT now(), terminateddate date, terminatedby varchar(50), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[1,2,9])), ins_id integer)', v_schema);
  -- No UNIQUE on paremail: parents commonly share an email (siblings / one family
  -- email), so a bulk student import would fail on the first shared address.

  -- parentdetail
  EXECUTE format('CREATE TABLE %I.parentdetail (pd_id bigint NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), par_id bigint NOT NULL, stu_id bigint NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, stuadmno varchar(20) NOT NULL UNIQUE, stuname varchar(50) NOT NULL, stuclass varchar(20) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- feedemand — `collectible=false` rows are recorded but never shown for
  -- collection; carried through from the classfeedemand template.
  EXECUTE format('CREATE TABLE %I.feedemand (dem_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, demseqtype varchar(20) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, paidamount numeric(12,2) DEFAULT 0, fineamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) CHECK (balancedue >= 0), reconbalancedue numeric(12,2) DEFAULT 0, duedate date NOT NULL, pay_id integer, paidstatus char(1) DEFAULT ''U'' NOT NULL CHECK (paidstatus = ANY(ARRAY[''P'',''U''])), createdby varchar(50) NOT NULL, createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])), inactivedate timestamp, remarks varchar(50), fee_id integer, courname varchar(20), collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, cf_id integer, arrearclass varchar(30))', v_schema);

  -- tempfeedemand (staging — copied into feedemand by fn_approve_tempfeedemand on approval)
  EXECUTE format('CREATE TABLE %I.tempfeedemand (temp_id bigint NOT NULL PRIMARY KEY, demno varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer, stu_id bigint, stuadmno varchar(25) NOT NULL, stuclass varchar(20) NOT NULL, courname varchar(20), demfeeyear varchar(9) NOT NULL, demfeeterm varchar(20) NOT NULL, demfeetype varchar(30) NOT NULL, feeamount numeric(12,2) NOT NULL, con_id integer, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2), duedate date NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), isapproved boolean DEFAULT false, collectible boolean DEFAULT true NOT NULL, cla_id smallint, sem_id smallint, fee_id integer, cf_id integer, demseqtype varchar(20), arrearclass varchar(30))', v_schema);

  -- Demand generation + approval performance indexes. The dedup NOT EXISTS
  -- checks (generate_feedemand_from_template / _for_class) and the approval
  -- trigger's per-row feedemand lookup would otherwise sequential-scan and grow
  -- O(N^2) as feedemand fills, timing out on bulk generate/approve.
  EXECUTE format('CREATE INDEX idx_feedemand_dedup ON %I.feedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);
  EXECUTE format('CREATE INDEX idx_tempfeedemand_dedup ON %I.tempfeedemand (stu_id, demfeeterm, demfeetype) WHERE activestatus = 1', v_schema);
  EXECUTE format('CREATE INDEX idx_feedemand_demno_type ON %I.feedemand (ins_id, demno, demfeetype) WHERE activestatus = 1', v_schema);

  -- Approval trigger: copy temp → feedemand carrying the collectible flag.
  EXECUTE format('CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_dem_id bigint; v_paid numeric; v_net numeric; BEGIN IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid FROM %1$I.feedemand WHERE ins_id = NEW.ins_id AND NEW.demno IS NOT NULL AND btrim(NEW.demno) <> '''' AND demno IS NOT DISTINCT FROM NEW.demno AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype AND activestatus = 1 ORDER BY dem_id LIMIT 1; IF v_dem_id IS NOT NULL THEN v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0); UPDATE %1$I.feedemand SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount, balancedue = v_net, reconbalancedue = v_net, duedate = NEW.duedate, collectible = COALESCE(NEW.collectible, collectible), cla_id = NEW.cla_id, sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id, demseqtype = COALESCE(NEW.demseqtype, demseqtype), arrearclass = NEW.arrearclass WHERE dem_id = v_dem_id; ELSE INSERT INTO %1$I.feedemand (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue, duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible, cla_id, sem_id, fee_id, cf_id, arrearclass) VALUES (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass, NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id, NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1, NEW.createdat, NEW.createdby, ''U'', 0, COALESCE(NEW.collectible, true), NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass); END IF; NEW.activestatus := 9; END IF; RETURN NEW; END; $t$', v_schema);
  EXECUTE format('CREATE TRIGGER trg_tempfeedemand_approve BEFORE UPDATE OF isapproved ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.fn_approve_tempfeedemand()', v_schema, v_schema);

  -- feegroup
  EXECUTE format('CREATE TABLE %I.feegroup (fg_id integer NOT NULL PRIMARY KEY, fgdesc varchar(30) NOT NULL, ban_id integer, ins_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);

  -- feetype (feefineapplicable: 1 = fines apply when overdue, 0 = no fine)
  EXECUTE format('CREATE TABLE %I.feetype (fee_id integer NOT NULL PRIMARY KEY, feedesc varchar(30) NOT NULL, feeshort varchar(10) NOT NULL, feefineapplicable smallint DEFAULT 0, fg_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])), ins_id integer, type varchar(20), payseq smallint DEFAULT 100, partialallowed char(1) DEFAULT ''Y'')', v_schema);
  -- (feegroup_accountant removed — unused scaffold; no app or DB references.)
  EXECUTE format('ALTER TABLE %I.feetype ADD CONSTRAINT fk_feetype_feegroup FOREIGN KEY (fg_id) REFERENCES %I.feegroup(fg_id)', v_schema, v_schema);
  -- Lets PostgREST resolve embedded selects like feedemand?select=*,feetype(*) in the mobile app.
  EXECUTE format('ALTER TABLE %I.feedemand ADD CONSTRAINT fk_feedemand_feetype FOREIGN KEY (fee_id) REFERENCES %I.feetype(fee_id) NOT VALID', v_schema, v_schema);

  -- concessioncategory
  EXECUTE format('CREATE TABLE %I.concessioncategory (con_id integer NOT NULL PRIMARY KEY, condesc varchar(20) NOT NULL, ins_id integer NOT NULL, ordid integer, activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1])))', v_schema);

  -- course
  EXECUTE format('CREATE TABLE %I.course (cour_id integer NOT NULL PRIMARY KEY, courname varchar(100) NOT NULL, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- class
  EXECUTE format('CREATE TABLE %I.class (cla_id integer NOT NULL PRIMARY KEY, claname varchar(20) NOT NULL, ins_id integer, ordid smallint, succeedingclass integer, cour_id integer, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  -- succeedingclass is the cla_id of the next class in the promotion ladder
  -- (NULL for the terminal class). cour_id is optional / informational.

  -- admissiontype + quota + community + division + semester master lookups.
  -- (Register-number sequencing lives in the shared `sequence` table below,
  --  actname = 'REGNO' — not a separate regnoseq table anymore.)
  EXECUTE format('CREATE TABLE %I.admissiontype (adm_id smallint PRIMARY KEY, admname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);
  EXECUTE format('CREATE TABLE %I.quota (quo_id smallint PRIMARY KEY, quoname varchar(30) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);
  -- Community master (lookup for the admission form).
  EXECUTE format('CREATE TABLE %I.community (com_id smallint PRIMARY KEY, comname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);
  EXECUTE format('CREATE TABLE %I.division (div_id smallint PRIMARY KEY, divname varchar(40) NOT NULL, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);
  -- (Register-number sequencing now lives in the shared `sequence` table below,
  --  actname = 'REGNO' — the separate regnoseq table has been retired.)
  -- Semester master (drives the demfeeterm dropdown in Fee Demand / Class Fee Demand).
  EXECUTE format('CREATE TABLE %I.semester (sem_id smallint PRIMARY KEY, semname varchar(30) NOT NULL, semshort varchar(10), semtype char(1) NOT NULL DEFAULT ''S'' CHECK (semtype IN (''S'',''M'',''Y'')), semstart date, semend date, ordid smallint, ins_id integer, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);

  -- classfeedemand — `collectible` carries the "ALL" tick from the template into
  -- each generated tempfeedemand/feedemand row.
  EXECUTE format('CREATE TABLE %I.classfeedemand (cf_id integer NOT NULL PRIMARY KEY, cfclass varchar(20), cfterm varchar(20), cffeetype varchar(30), cfamount numeric(12,2), cfdduedate date, admissiontype smallint, collectible boolean DEFAULT false NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, cla_id smallint, sem_id smallint, fee_id integer)', v_schema);

  -- NOTE: on-admission (per-student-insert) fee-demand auto-generation was
  -- reverted. There is deliberately no fn_gen_feedemand_on_student function or
  -- trg_gen_feedemand_on_student trigger here. Adding a student does NOT create
  -- demands. Generate them explicitly via generate_feedemand_for_class /
  -- generate_feedemand_from_template (or the Fee Demand screen).

  -- finerule (overdue fine slabs configured by admin)
  EXECUTE format('CREATE TABLE %I.finerule (fr_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, rulename varchar(50) NOT NULL, feetype varchar(30) DEFAULT ''ALL'', from_days integer NOT NULL, to_days integer, fine_type varchar(10) DEFAULT ''FIXED'' CHECK (fine_type IN (''FIXED'',''PERCENT'')), fine_value numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamp DEFAULT now(), createdby varchar(50))', v_schema);


  -- payment
  EXECUTE format('CREATE TABLE %I.payment (pay_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), transtotalamount numeric(12,2) NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paydate timestamp, paystatus char(1) CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), paygwresponse numeric(15,0), payitems text, createdby varchar(100), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, paynumber varchar(30) UNIQUE, payorderid varchar(100), notification_read boolean DEFAULT false, paychequeno varchar(50), paychequedate date, paybankname varchar(100), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, ban_id integer, tender_amount numeric(12,2), refund_amount numeric(12,2), voidedby varchar(100), voideddate timestamp, voidreason varchar(255))', v_schema);

  -- bank: per-institution beneficiary account list. Fee groups are
  -- tagged with ban_id so a single payment can be split (mock for now —
  -- real splits later via Razorpay Route or virtual accounts).
  EXECUTE format('CREATE TABLE %I.bank (ban_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer, banname varchar(45) NOT NULL, banbranch varchar(80) NOT NULL, ifsccode varchar(15) NOT NULL, banaddress1 varchar(50) NOT NULL, banaddress2 varchar(50), banaddress3 varchar(50), banmobile varchar(15), banemail varchar(60), banaccno varchar(20) NOT NULL, banaccholder varchar(50) NOT NULL, paytm_mid varchar(40), activestatus smallint DEFAULT 1 NOT NULL CHECK (activestatus = ANY(ARRAY[0,1,9])))', v_schema);
  EXECUTE format('ALTER TABLE %I.feegroup ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_feegroup_bank', v_schema);
  EXECUTE format('ALTER TABLE %I.payment ADD CONSTRAINT %I FOREIGN KEY (ban_id) REFERENCES %I.bank(ban_id) ON DELETE SET NULL', v_schema, 'fk_' || v_schema || '_payment_bank', v_schema);

  -- paymentdetails
  EXECUTE format('CREATE TABLE %I.paymentdetails (pyd_id bigint NOT NULL PRIMARY KEY, pay_id bigint NOT NULL, dem_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(20), ins_id integer NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- paymentgateway
  EXECUTE format('CREATE TABLE %I.paymentgateway (gw_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, gwname varchar(100) NOT NULL, gwapikey varchar(255), gwapisecret varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- interim_promotion (mid-year move of a single student to another class;
  -- keeps the before/after course+class for audit)
  EXECUTE format('CREATE TABLE %I.interim_promotion (ip_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no integer NOT NULL, ins_id integer NOT NULL, promotiondate date NOT NULL, stu_id bigint, stuadmno varchar(25), stuname varchar(50), courname varchar(20), stuclass varchar(20), admname varchar(30), transferred_courname varchar(20), transferred_class varchar(20), transferred_admname varchar(30), remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE INDEX idx_interim_promotion_stu ON %I.interim_promotion (ins_id, stu_id)', v_schema);

  -- fee_refund (refund voucher header; one row per refund raised against a receipt/payment)
  EXECUTE format('CREATE TABLE %I.fee_refund (rf_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30) NOT NULL, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), refunddate date NOT NULL, pay_id bigint, paynumber varchar(30), stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), refundmode varchar(20) NOT NULL, ban_id integer, bankname varchar(100), bankref varchar(100), chequedate date, accountcode varchar(50), refundreason varchar(200), totalrefund numeric(12,2) DEFAULT 0, totaladjust numeric(12,2) DEFAULT 0, createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- fee_refunddetails (per fee-line breakdown of a refund voucher; dem_id references this schema''s feedemand by value)
  EXECUTE format('CREATE TABLE %I.fee_refunddetails (rfd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, rf_id bigint NOT NULL, dem_id bigint, ins_id integer NOT NULL, refundterm varchar(20), refundfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, refundamount numeric(12,2) DEFAULT 0, adjustamount numeric(12,2) DEFAULT 0, adjustreason varchar(200), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- concession (concession voucher header; one row per concession applied to a student) + concessiondetail (per fee-line breakdown). Written only via process_concession(). See migrations/add_concession_tables.sql.
  EXECUTE format('CREATE TABLE %I.concession (con_hdr_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, doc_no varchar(30), ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(20), condate date NOT NULL DEFAULT CURRENT_DATE, stu_id bigint, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), con_id integer, contype varchar(30), totalfee numeric(12,2) DEFAULT 0, totalconcession numeric(12,2) DEFAULT 0, totalbalance numeric(12,2) DEFAULT 0, remarks varchar(200), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE TABLE %I.concessiondetail (cond_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, con_hdr_id bigint NOT NULL, ins_id integer NOT NULL, stu_id bigint, stuadmno varchar(25), receiptno varchar(30), dem_id bigint, demfeeterm varchar(20), demfeetype varchar(30), feeamount numeric(12,2) DEFAULT 0, conamount numeric(12,2) DEFAULT 0, balancedue numeric(12,2) DEFAULT 0, con_id integer, contype varchar(30), condate date, createdby varchar(50), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE INDEX idx_concession_stu ON %I.concession (ins_id, stu_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_concessiondetail_hdr ON %I.concessiondetail (con_hdr_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_concessiondetail_stu ON %I.concessiondetail (ins_id, stu_id)', v_schema);

  -- misc_collection (standalone counter collection: BONAFIDE, APPLICATION, …).
  -- Does NOT touch feedemand. selection ''S'' = registered student, ''O'' = others.
  -- Receipt number (mcno) is drawn from the shared fee-receipt sequence.
  EXECUTE format('CREATE TABLE %I.misc_collection (mc_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), mcno varchar(30) NOT NULL, mcdate date NOT NULL DEFAULT CURRENT_DATE, selection char(1) NOT NULL DEFAULT ''S'' CHECK (selection IN (''S'',''O'')), stu_id bigint, regno varchar(25), stuclass varchar(30), stuname varchar(100) NOT NULL, courname varchar(20), city varchar(50), address varchar(255), paymode varchar(20) DEFAULT ''Cash'', ban_id integer, bankname varchar(100), transrefno varchar(50), paytm_txnid varchar(60), draweebank varchar(100), transdate date, transamt numeric(12,2), collectedby varchar(50), remarks varchar(255), totalamount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL, createdat timestamptz DEFAULT now(), createdby varchar(50), recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamptz, bank_reference varchar(100), bank_date date, paystatus char(1) DEFAULT ''C'', voidedby varchar(100), voideddate timestamptz, voidreason varchar(255))', v_schema);
  EXECUTE format('CREATE TABLE %I.misc_collection_detail (mcd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, mc_id bigint NOT NULL, ins_id integer NOT NULL, fee_id integer, feetype varchar(30) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE INDEX idx_misc_detail_mc ON %I.misc_collection_detail (mc_id)', v_schema);

  -- advance_collection (money taken BEFORE any fee is due). Mirrors `payment`'s
  -- money/reconcile columns but carries NO fg_id / fee_id -- an advance is just
  -- an amount held against the student. It is later applied to specific fee
  -- demands ("adjusted"), which advadjustment records. Receipt number (advno)
  -- comes from the schema's own sequence, actname='ADVNO' (Fee Master ->
  -- Advance No). balanceamount is GENERATED, so it can never drift from its
  -- parts. See migrations/add_advance_collection.sql.
  EXECUTE format('CREATE TABLE %I.advance_collection (adv_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id bigint NOT NULL, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), yr_id integer, yrlabel varchar(20), advno varchar(30) NOT NULL, advdate timestamp DEFAULT now() NOT NULL, advtype char(1) DEFAULT ''S'' NOT NULL CHECK (advtype = ANY(ARRAY[''A'',''S''])), transtotalamount numeric(12,2) NOT NULL CHECK (transtotalamount > 0), adjustedamount numeric(12,2) DEFAULT 0 NOT NULL, refund_amount numeric(12,2) DEFAULT 0 NOT NULL, balanceamount numeric(12,2) GENERATED ALWAYS AS (transtotalamount - adjustedamount - refund_amount) STORED, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paystatus char(1) DEFAULT ''C'' NOT NULL CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), payorderid varchar(100), paytm_txnid varchar(60), paychequeno varchar(50), paychequedate date, paybankname varchar(100), ban_id integer, recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, tender_amount numeric(12,2), remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, voidedby varchar(100), voideddate timestamp, voidreason varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE UNIQUE INDEX uq_advance_advno ON %I.advance_collection (ins_id, advno)', v_schema);
  EXECUTE format('CREATE INDEX idx_advance_stu ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1', v_schema);
  -- Drives "students with an unused advance" (the Fee Collection highlight).
  EXECUTE format('CREATE INDEX idx_advance_open ON %I.advance_collection (ins_id, stu_id) WHERE activestatus = 1 AND balanceamount > 0', v_schema);

  -- advance_detail: the fee-type breakdown of an ADMISSION advance
  -- (advtype ''A''). Mirrors misc_collection_detail. A student advance
  -- (advtype ''S'') is a plain amount and has no rows here at all.
  -- feetype is varchar(60), not misc''s 30: real fee names run long.
  EXECUTE format('CREATE TABLE %I.advance_detail (advd_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, fee_id integer, fg_id integer, feetype varchar(60) NOT NULL, amount numeric(12,2) NOT NULL DEFAULT 0, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);
  EXECUTE format('CREATE INDEX idx_advance_detail_adv ON %I.advance_detail (adv_id)', v_schema);

  -- advadjustment: one row per amount moved off an advance onto a fee demand,
  -- with the fee receipt that settlement raised.
  EXECUTE format('CREATE TABLE %I.advadjustment (adj_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, adv_id bigint NOT NULL REFERENCES %I.advance_collection(adv_id), ins_id integer NOT NULL, stu_id bigint, dem_id bigint, pay_id bigint, paynumber varchar(30), demfeeterm varchar(20), demfeetype varchar(30), adjustamount numeric(12,2) NOT NULL CHECK (adjustamount > 0), adjustdate date DEFAULT CURRENT_DATE NOT NULL, remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema, v_schema);
  EXECUTE format('CREATE INDEX idx_advadjustment_adv ON %I.advadjustment (adv_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_advadjustment_dem ON %I.advadjustment (ins_id, dem_id)', v_schema);

  -- sequence: unified numbering for BOTH fee-receipt sequences (fg_id set,
  -- actname = fee-group name) AND admission/register-number sequences
  -- (fg_id NULL, actname = 'REGNO'; the seqend + division columns apply only to
  -- register sequences). Register numbers replace the old separate regnoseq table.
  EXECUTE format('CREATE TABLE %I.sequence (seq_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, mod_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9) NOT NULL, actname varchar(30) NOT NULL, seqname varchar(50) NOT NULL, isprefix char(1) NOT NULL, seqprefix varchar(15) NOT NULL, seqstart numeric(9,0) NOT NULL, seqwidth numeric(2,0) NOT NULL, sequid varchar(18) NOT NULL, seqcurno numeric(9,0) NOT NULL, seqend numeric(9,0), division varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL, fg_id integer)', v_schema);

  -- shoppingcart
  EXECUTE format('CREATE TABLE %I.shoppingcart (car_id integer NOT NULL PRIMARY KEY, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, stu_id bigint NOT NULL, transtype varchar(10) NOT NULL, transdate date DEFAULT CURRENT_DATE NOT NULL, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, carinitiated char(1) DEFAULT ''N'' NOT NULL, createdby varchar(50) NOT NULL, createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE UNIQUE INDEX unique_active_cart_per_student ON %I.shoppingcart (stu_id) WHERE activestatus = 1', v_schema);

  -- shoppingcartdetails
  EXECUTE format('CREATE TABLE %I.shoppingcartdetails (cd_id integer NOT NULL PRIMARY KEY, car_id integer NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), ins_id integer NOT NULL, dem_id bigint NOT NULL, transdetail_id integer, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, transtotalamount numeric(12,2) NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);

  -- notice
  EXECUTE format('CREATE TABLE %I.notice (notice_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, noticetitle text NOT NULL, noticedesc text, noticepriority varchar(20) DEFAULT ''Normal'', noticecategory varchar(50) DEFAULT ''General'', noticetarget text, createdby varchar(50), createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1, noticefromdate date, noticetodate date)', v_schema);
  EXECUTE format('CREATE INDEX idx_notice_ins_id ON %I.notice (ins_id)', v_schema);

  -- notification
  EXECUTE format('CREATE TABLE %I.notification (noti_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, stu_id integer, notice_id bigint, notititle text, notibody text, notitype varchar(50), isread integer DEFAULT 0, createdat timestamptz DEFAULT now(), activestatus integer DEFAULT 1)', v_schema);
  EXECUTE format('CREATE INDEX idx_notification_notice_id ON %I.notification(notice_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_notification_ins_id ON %I.notification (ins_id)', v_schema);
  EXECUTE format('CREATE INDEX idx_notification_stu_id ON %I.notification (stu_id)', v_schema);

  -- userlogin
  EXECUTE format('CREATE TABLE %I.userlogin (ul_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), uluser varchar(50), ulusetype smallint, ultime timestamp, ulattempt smallint DEFAULT 0, ulip varchar(40), ullocation varchar(50), ulsuccess char(1) DEFAULT ''N'' NOT NULL, ulsesid numeric, ulsesstart timestamp DEFAULT now() NOT NULL, ulsesend timestamp, ulsestime timestamp)', v_schema);


  -- student_import
  EXECUTE format('CREATE TABLE %I.student_import (imp_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10) NOT NULL, yr_id integer NOT NULL, yrlabel varchar(9), stuadmno varchar(25) NOT NULL, stuname varchar(50) NOT NULL, stugender char(1), studob date, stuadmdate date, stuclass varchar(20) NOT NULL, courname varchar(20), stumobile varchar(30), stuemail varchar(254), concession varchar(50), stuaddress text, stucity varchar(50), stustate varchar(50), stucountry varchar(50), stupin varchar(6), stubloodgrp varchar(20), fathername varchar(50), fathermobile varchar(30), fatheroccupation varchar(50), mothername varchar(50), mothermobile varchar(30), motheroccupation varchar(50), guardianname varchar(50), guardianmobile varchar(30), guardianoccupation varchar(50), payincharge varchar(50), payinchargemob varchar(30), admname varchar(50), quoname varchar(50), batch varchar(9), admittyear varchar(9), aadharno varchar(20), community varchar(30), caste varchar(30), religion varchar(30), nationality varchar(30), transportmode varchar(20), hostel char(1), paremail varchar(254), cla_id smallint, cour_id integer, admit_cour_id smallint, medium varchar(30), adm_id smallint, quo_id smallint, status varchar(10) DEFAULT ''PENDING'', error_msg text, created_at timestamp DEFAULT now())', v_schema);

  -- FOREIGN KEYS
  EXECUTE format('ALTER TABLE %I.paymentdetails ADD CONSTRAINT fk_paymentdetails_payment FOREIGN KEY (pay_id) REFERENCES %I.payment(pay_id)', v_schema, v_schema);
  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_car_id_fkey FOREIGN KEY (car_id) REFERENCES %I.shoppingcart(car_id)', v_schema, v_schema);
  EXECUTE format('ALTER TABLE %I.shoppingcartdetails ADD CONSTRAINT shoppingcartdetails_dem_id_fkey FOREIGN KEY (dem_id) REFERENCES %I.feedemand(dem_id)', v_schema, v_schema);

  -- ============================================
  -- TRIGGER FUNCTIONS (per schema)
  -- ============================================

  -- Auto-increment triggers for all tables
  EXECUTE format('CREATE FUNCTION %I.set_yr_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.yr_id IS NULL OR NEW.yr_id = 0 THEN NEW.yr_id := COALESCE((SELECT MAX(yr_id) FROM %I.year), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_year_yr_id BEFORE INSERT ON %I.year FOR EACH ROW EXECUTE FUNCTION %I.set_yr_id()', v_schema, v_schema);

  -- students: sequence-backed id, no hardcoded storage URL (photos resolved client-side)
  EXECUTE format('CREATE SEQUENCE %I.students_stu_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_stu_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stu_id IS NULL OR NEW.stu_id = 0 THEN NEW.stu_id := nextval(''%I.students_stu_id_seq''); END IF; IF (NEW.cour_id IS NULL OR NEW.cour_id = 0) AND NEW.courname IS NOT NULL AND TRIM(NEW.courname) != '''' THEN SELECT c.cour_id INTO NEW.cour_id FROM %I.course c WHERE UPPER(TRIM(c.courname)) = UPPER(TRIM(NEW.courname)) AND c.ins_id = NEW.ins_id LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_students_before_insert BEFORE INSERT ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.set_stu_id()', v_schema, v_schema);

  -- parents: sequence-backed id
  EXECUTE format('CREATE SEQUENCE %I.parents_par_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_par_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.par_id IS NULL OR NEW.par_id = 0 THEN NEW.par_id := nextval(''%I.parents_par_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_parents_before_insert BEFORE INSERT ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.set_par_id()', v_schema, v_schema);

  -- parentdetail: sequence-backed id
  EXECUTE format('CREATE SEQUENCE %I.parentdetail_pd_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_pd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pd_id IS NULL OR NEW.pd_id = 0 THEN NEW.pd_id := nextval(''%I.parentdetail_pd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_parentdetail_auto_id BEFORE INSERT ON %I.parentdetail FOR EACH ROW EXECUTE FUNCTION %I.set_pd_id()', v_schema, v_schema);

  -- feedemand uses a real sequence (bulk import path — must be O(1) per row)
  EXECUTE format('CREATE SEQUENCE %I.feedemand_dem_id_seq', v_schema);
  EXECUTE format($f$CREATE FUNCTION %I.set_dem_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.dem_id IS NULL OR NEW.dem_id = 0 THEN NEW.dem_id := nextval('%I.feedemand_dem_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.dem_id::TEXT, 5, '0'); END IF; END IF; IF NEW.demseqtype IS NULL OR TRIM(NEW.demseqtype) = '' THEN NEW.demseqtype := 'DEMAND'; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.demfeetype IS NOT NULL THEN SELECT ft.fee_id INTO NEW.fee_id FROM %I.feetype ft WHERE ft.feedesc = NEW.demfeetype AND ft.activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_feedemand_before_insert BEFORE INSERT ON %I.feedemand FOR EACH ROW EXECUTE FUNCTION %I.set_dem_id()', v_schema, v_schema);

  -- tempfeedemand uses a real sequence (bulk import path — must be O(1) per row)
  EXECUTE format('CREATE SEQUENCE %I.tempfeedemand_temp_id_seq', v_schema);
  EXECUTE format($f$CREATE FUNCTION %I.set_temp_id() RETURNS trigger LANGUAGE plpgsql AS $t$ DECLARE v_sid int; v_pref text; v_w int; v_cur numeric; BEGIN IF NEW.temp_id IS NULL THEN NEW.temp_id := nextval('%I.tempfeedemand_temp_id_seq'); END IF; IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno INTO v_sid, v_pref, v_w, v_cur FROM %I.sequence WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1 ORDER BY seq_id LIMIT 1 FOR UPDATE; IF v_sid IS NOT NULL THEN v_cur := COALESCE(v_cur, 0) + 1; NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0'); UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid; ELSE NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.temp_id::TEXT, 5, '0'); END IF; END IF; RETURN NEW; END; $t$ $f$, v_schema, v_schema, v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_temp_id BEFORE INSERT ON %I.tempfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_temp_id()', v_schema, v_schema);

  -- Master-table auto-increment sequences. The NULL/0 guard lets callers
  -- supply an explicit id (needed when importing master data from a legacy
  -- system); a plain INSERT without the column gets nextval().
  EXECUTE format('CREATE SEQUENCE %I.feegroup_fg_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_fg_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fg_id IS NULL OR NEW.fg_id = 0 THEN NEW.fg_id := nextval(''%I.feegroup_fg_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_feegroup_fg_id BEFORE INSERT ON %I.feegroup FOR EACH ROW EXECUTE FUNCTION %I.set_fg_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.feetype_fee_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_fee_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.fee_id IS NULL OR NEW.fee_id = 0 THEN NEW.fee_id := nextval(''%I.feetype_fee_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_feetype_fee_id BEFORE INSERT ON %I.feetype FOR EACH ROW EXECUTE FUNCTION %I.set_fee_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.concessioncategory_con_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_con_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.con_id IS NULL OR NEW.con_id = 0 THEN NEW.con_id := nextval(''%I.concessioncategory_con_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_concession_con_id BEFORE INSERT ON %I.concessioncategory FOR EACH ROW EXECUTE FUNCTION %I.set_con_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.course_cour_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_cour_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cour_id IS NULL OR NEW.cour_id = 0 THEN NEW.cour_id := nextval(''%I.course_cour_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_course_cour_id BEFORE INSERT ON %I.course FOR EACH ROW EXECUTE FUNCTION %I.set_cour_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.class_cla_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_cla_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cla_id IS NULL OR NEW.cla_id = 0 THEN NEW.cla_id := nextval(''%I.class_cla_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_class_cla_id BEFORE INSERT ON %I.class FOR EACH ROW EXECUTE FUNCTION %I.set_cla_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.classfeedemand_cf_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_cf_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.cf_id IS NULL THEN NEW.cf_id := nextval(''%I.classfeedemand_cf_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_classfeedemand_cf_id BEFORE INSERT ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_cf_id()', v_schema, v_schema);
  -- Resolve cla_id / sem_id / fee_id from the cfclass / cfterm / cffeetype names
  -- on insert/update (schema-qualified, so it works from the session-gated RPCs).
  EXECUTE format('CREATE OR REPLACE FUNCTION %I.set_classfee_ids() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF (NEW.cla_id IS NULL OR NEW.cla_id = 0) AND NEW.cfclass IS NOT NULL THEN SELECT cla_id INTO NEW.cla_id FROM %I.class WHERE claname = NEW.cfclass AND activestatus = 1 LIMIT 1; END IF; IF (NEW.sem_id IS NULL OR NEW.sem_id = 0) AND NEW.cfterm IS NOT NULL THEN SELECT sem_id INTO NEW.sem_id FROM %I.semester WHERE semname = NEW.cfterm AND activestatus = 1 LIMIT 1; END IF; IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.cffeetype IS NOT NULL THEN SELECT fee_id INTO NEW.fee_id FROM %I.feetype WHERE feedesc = NEW.cffeetype AND activestatus = 1 LIMIT 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema, v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_classfeedemand_ids BEFORE INSERT OR UPDATE ON %I.classfeedemand FOR EACH ROW EXECUTE FUNCTION %I.set_classfee_ids()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.payment_pay_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %1$I.set_pay_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_next bigint; BEGIN IF NEW.pay_id IS NULL OR NEW.pay_id = 0 THEN PERFORM pg_advisory_xact_lock(hashtext(%1$L)::bigint); SELECT COALESCE(MAX(pay_id),0) + 1 INTO v_next FROM %1$I.payment; NEW.pay_id := v_next; END IF; RETURN NEW; END; $t$', v_schema);
  EXECUTE format('CREATE TRIGGER trg_payment_auto_increment BEFORE INSERT ON %I.payment FOR EACH ROW EXECUTE FUNCTION %I.set_pay_id()', v_schema, v_schema);

  EXECUTE format('CREATE SEQUENCE %I.paymentdetails_pyd_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_pyd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.pyd_id IS NULL OR NEW.pyd_id = 0 THEN NEW.pyd_id := nextval(''%I.paymentdetails_pyd_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_paymentdetails_auto_increment BEFORE INSERT ON %I.paymentdetails FOR EACH ROW EXECUTE FUNCTION %I.set_pyd_id()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_car_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.car_id := COALESCE((SELECT MAX(car_id) FROM %I.shoppingcart), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_generate_car_id BEFORE INSERT ON %I.shoppingcart FOR EACH ROW EXECUTE FUNCTION %I.set_car_id()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_cd_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN NEW.cd_id := COALESCE((SELECT MAX(cd_id) FROM %I.shoppingcartdetails), 0) + 1; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_generate_cd_id BEFORE INSERT ON %I.shoppingcartdetails FOR EACH ROW EXECUTE FUNCTION %I.set_cd_id()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_notice_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.notice_id IS NULL OR NEW.notice_id = 0 THEN NEW.notice_id := COALESCE((SELECT MAX(notice_id) FROM %I.notice), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_notice_id BEFORE INSERT ON %I.notice FOR EACH ROW EXECUTE FUNCTION %I.set_notice_id()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.set_noti_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ BEGIN IF NEW.noti_id IS NULL OR NEW.noti_id = 0 THEN NEW.noti_id := COALESCE((SELECT MAX(noti_id) FROM %I.notification), 0) + 1; END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_noti_id BEFORE INSERT ON %I.notification FOR EACH ROW EXECUTE FUNCTION %I.set_noti_id()', v_schema, v_schema);

  -- Password hash triggers
  EXECUTE format('CREATE FUNCTION %I.hash_student_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.stupassword IS NOT NULL AND NEW.stupassword != '''' AND LEFT(NEW.stupassword, 4) != ''$2a$'' AND LEFT(NEW.stupassword, 4) != ''$2b$'' THEN NEW.stupassword := crypt(NEW.stupassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);
  EXECUTE format('CREATE TRIGGER hash_student_password_trigger BEFORE INSERT OR UPDATE OF stupassword ON %I.students FOR EACH ROW EXECUTE FUNCTION %I.hash_student_password()', v_schema, v_schema);

  EXECUTE format('CREATE FUNCTION %I.hash_parent_password() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.parpassword IS NOT NULL AND NEW.parpassword != '''' AND LEFT(NEW.parpassword, 4) != ''$2a$'' AND LEFT(NEW.parpassword, 4) != ''$2b$'' THEN NEW.parpassword := crypt(NEW.parpassword, gen_salt(''bf'', 10)); END IF; RETURN NEW; END; $t$', v_schema);
  EXECUTE format('CREATE TRIGGER hash_parent_password_trigger BEFORE INSERT OR UPDATE OF parpassword ON %I.parents FOR EACH ROW EXECUTE FUNCTION %I.hash_parent_password()', v_schema, v_schema);

  -- Transfer Certificate entries (Admission → Transfer Certificate). One row per
  -- TC issued; save_tc_entry writes here and stamps the student's + admission's
  -- activestatus with the leaving code, so non-active students drop out of the
  -- active screens (which filter activestatus=1).
  EXECUTE format('CREATE TABLE %I.tc_entry (tc_id bigint NOT NULL PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), yr_id integer, yrlabel varchar(9), stu_id bigint, stuadmno varchar(25) NOT NULL, stuname varchar(50), stuclass varchar(20), cla_id smallint, birthdate date, joindate date, status smallint NOT NULL DEFAULT 1 CHECK (status = ANY(ARRAY[1,2,3,4,5,9])), statustype varchar(20), tcno varchar(30), tcdate date, effectfrom date, docno varchar(30), docdate date, remarks varchar(200), createdby varchar(50), createdon timestamp DEFAULT now() NOT NULL, activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
  EXECUTE format('CREATE SEQUENCE %I.tc_entry_tc_id_seq', v_schema);
  EXECUTE format('CREATE FUNCTION %I.set_tc_id() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN IF NEW.tc_id IS NULL OR NEW.tc_id = 0 THEN NEW.tc_id := nextval(''%I.tc_entry_tc_id_seq''); END IF; RETURN NEW; END; $t$', v_schema, v_schema);
  EXECUTE format('CREATE TRIGGER trg_tc_entry_tc_id BEFORE INSERT ON %I.tc_entry FOR EACH ROW EXECUTE FUNCTION %I.set_tc_id()', v_schema, v_schema);
  EXECUTE format('ALTER TABLE %I.tc_entry ENABLE ROW LEVEL SECURITY', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.tc_entry USING (true) WITH CHECK (true)', v_schema);

  -- (rollno_change lives in public, alongside public.admission — see above.)

  -- (fn_approve_tempfeedemand + trigger are defined right after the tempfeedemand
  -- table above; they carry the `collectible` flag from temp into feedemand.)

  -- RLS
  EXECUTE format('ALTER TABLE %I.notice ENABLE ROW LEVEL SECURITY', v_schema);
  EXECUTE format('ALTER TABLE %I.notification ENABLE ROW LEVEL SECURITY', v_schema);
  EXECUTE format('ALTER TABLE %I.tempfeedemand ENABLE ROW LEVEL SECURITY', v_schema);
  -- student_import was missing its ENABLE (policy created below), which tripped
  -- the Supabase "Policy Exists RLS Disabled" advisor for every new schema.
  EXECUTE format('ALTER TABLE %I.student_import ENABLE ROW LEVEL SECURITY', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.notice USING (true) WITH CHECK (true)', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.notification USING (true) WITH CHECK (true)', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.tempfeedemand USING (true) WITH CHECK (true)', v_schema);
  EXECUTE format('CREATE POLICY "Allow all" ON %I.student_import USING (true) WITH CHECK (true)', v_schema);

  -- PERMISSIONS
  EXECUTE format('GRANT USAGE ON SCHEMA %I TO anon, authenticated', v_schema);
  EXECUTE format('GRANT ALL ON ALL TABLES IN SCHEMA %I TO anon, authenticated', v_schema);
  EXECUTE format('GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO anon, authenticated', v_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO anon, authenticated', v_schema);
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO anon, authenticated', v_schema);

  -- Auto-create year records if parameters provided
  IF p_ins_id IS NOT NULL AND p_year_label IS NOT NULL THEN
    -- Insert into public.institutionyear, stamping iyrschema so the row
    -- carries the per-year schema name (e.g. 'kcet20262027') without the
    -- app having to re-derive it from inshortname + yrlabel.
    INSERT INTO public.institutionyear (ins_id, inscode, yrlabel, iyrstadate, iyrenddate, iyrschema, activestatus)
    VALUES (p_ins_id, COALESCE(v_inscode, ''), p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year'), v_schema, 1)
    ON CONFLICT (ins_id, yrlabel) DO UPDATE SET iyrschema = EXCLUDED.iyrschema;

    -- Insert into schema year table
    EXECUTE format('INSERT INTO %I.year (ins_id, yrlabel, yrstadate, yrenddate, activestatus) VALUES ($1, $2, $3, $4, 1)', v_schema)
    USING p_ins_id, p_year_label, COALESCE(p_start_date, CURRENT_DATE), COALESCE(p_end_date, CURRENT_DATE + INTERVAL '1 year');
  END IF;

  -- Expose schema to PostgREST (may fail on free tier - handled by app login)
  BEGIN
    PERFORM public.expose_schema(v_schema);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'expose_schema skipped: %', SQLERRM;
  END;

  -- Security (Option B): the money tables are written ONLY through session-gated
  -- SECURITY DEFINER RPCs (they run as owner), so a new schema is born with anon
  -- direct-write REVOKED on them. SELECT is left intact (reads unchanged). This
  -- mirrors phase3a_revoke_money_writes.sql for existing schemas.
  EXECUTE format(
    'REVOKE INSERT, UPDATE, DELETE ON %I.payment, %I.paymentdetails, %I.feedemand, '
    '%I.fee_refund, %I.fee_refunddetails, %I.concession, %I.concessiondetail, %I.students, %I.parents, %I.parentdetail, '
    '%I.advance_collection, %I.advance_detail, %I.advadjustment FROM anon',
    v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema, v_schema,
    v_schema, v_schema, v_schema);

  -- Read lockdown: enable RLS + per-tenant SELECT policy on sensitive tables so a
  -- NEW institution is born read-locked (anon can't SELECT another tenant's PII/
  -- money). Wrapped so a policy hiccup never blocks institution creation.
  BEGIN
    PERFORM public.read_lock_schema(v_schema);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'read_lock_schema skipped for %: %', v_schema, SQLERRM;
  END;

END; $$;

-- ############################################################################
-- 3 -- ALLOCATION carries the flag from the admission onto the student
-- ############################################################################
CREATE OR REPLACE FUNCTION public.allocate_admission_to_student(
  p_adm_id      bigint,
  p_schema      text,
  p_class       text,
  p_stuadmno    text,
  p_allocatedby text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$
DECLARE
  v_schema   text := lower(p_schema);
  v          public.admission%ROWTYPE;
  v_stu_id   bigint;
  v_par_id   bigint;
  v_yr_id    integer;
  v_yrlabel  varchar(9);
  v_adm_id   smallint;
  v_cla_id   smallint;
  v_cour_id  integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = v_schema) THEN
    RAISE EXCEPTION 'allocate_admission: schema % does not exist', v_schema;
  END IF;

  SELECT * INTO v FROM public.admission WHERE adm_id = p_adm_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Admission % not found', p_adm_id; END IF;
  IF v.admstatus = 'ALLOCATED' THEN
    RAISE EXCEPTION 'Admission % is already allocated', p_adm_id;
  END IF;

  -- admission no longer stores yr_id/yrlabel — derive from the target schema.
  EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
    INTO v_yr_id, v_yrlabel USING v.ins_id;
  IF v_yr_id IS NULL THEN
    RAISE EXCEPTION 'allocate_admission: cannot resolve academic year for schema %', v_schema;
  END IF;

  -- Self-heal: ensure the target schema's students table has the demographic
  -- columns (no-op if already present). Covers schemas created before this
  -- feature was added.
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS aadharno      varchar(20)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS community     varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS caste         varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS religion      varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS nationality   varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS transportmode varchar(20)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS hostel        char(1)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS emisno        varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS umisno        varchar(30)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarship     char(1)', v_schema);
  EXECUTE format('ALTER TABLE %I.students ADD COLUMN IF NOT EXISTS scholarshiptype varchar(60)', v_schema);

  -- Resolve the allocated class's ids (p_class can differ from the admission's
  -- preferred class) so the new student carries cla_id / cour_id; adm_id (from
  -- admission.admtype_id) / quo_id / medium come straight from the admission row.
  EXECUTE format('SELECT cla_id, cour_id FROM %I.class WHERE UPPER(TRIM(claname))=UPPER(TRIM($1)) AND activestatus=1 ORDER BY cla_id LIMIT 1', v_schema)
    INTO v_cla_id, v_cour_id USING p_class;

  -- 1) students (stu_id auto-assigned by the schema's set_stu_id trigger)
  EXECUTE format(
    'INSERT INTO %I.students '
    '(ins_id, inscode, yr_id, yrlabel, stuadmno, stuadmdate, stuname, stugender, studob, '
    ' stumobile, stuemail, stuaddress, stucity, stustate, stucountry, stupin, stubloodgrp, stuphoto, '
    ' stuclass, courname, con_id, stucondesc, stuser_id, stuotpstatus, '
    ' approvedby, approveddate, activestatus, createdon, batch, admname, quoname, admittyear, aadharno, '
    ' community, caste, religion, nationality, transportmode, hostel, emisno, umisno, scholarship, scholarshiptype, cla_id, cour_id, adm_id, quo_id, medium, admit_cour_id, preadmission) '
    'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,'
    ' $19,$20,$21,$22,$5,0,$23,now(),1,now(),$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34,'
    ' $41,$42,$43,$44,$35,$36,$37,$38,$39,$40,$45) RETURNING stu_id', v_schema)
  INTO v_stu_id
  USING v.ins_id, v.inscode, v_yr_id, v_yrlabel, p_stuadmno, COALESCE(v.admdate, CURRENT_DATE),
        v.stuname, v.stugender, v.studob, v.stumobile, v.stuemail, v.stuaddress, v.stucity,
        v.stustate, v.stucountry, v.stupin, v.stubloodgrp, v.stuphoto, p_class, v.courname,
        v.con_id, v.stucondesc, p_allocatedby, v.batch, v.admname, v.quoname, v.admittyear, v.aadharno,
        v.community, v.caste, v.religion, v.nationality, v.transportmode, v.hostel,
        COALESCE(v_cla_id, v.cla_id), COALESCE(v_cour_id, v.cour_id), v.admtype_id, v.quo_id, v.medium,
        COALESCE(v.admit_cour_id, v_cour_id, v.cour_id),
        -- $41-$44: appended rather than inserted mid-list so every existing
        -- placeholder keeps its number.
        v.emisno, v.umisno, v.scholarship, v.scholarshiptype,
        -- $45: seat booked now, studies from next year. Carried onto the
        -- student so the fee generator can skip them and the rollover can
        -- keep their class.
        COALESCE(v.preadmission, 0)::smallint;

  -- 2) parents — reuse an existing parent matched by payinchargemob, else create.
  IF v.payinchargemob IS NOT NULL AND TRIM(v.payinchargemob) <> '' THEN
    EXECUTE format('SELECT par_id FROM %I.parents WHERE payinchargemob = $1 LIMIT 1', v_schema)
      INTO v_par_id USING v.payinchargemob;
    IF v_par_id IS NULL THEN
      EXECUTE format('ALTER TABLE %I.parents ADD COLUMN IF NOT EXISTS paremail varchar(254)', v_schema);
      EXECUTE format(
        'INSERT INTO %I.parents '
        '(ins_id, yr_id, yrlabel, partype, fathername, fathermobile, fatheroccupation, '
        ' mothername, mothermobile, motheroccupation, guardianname, guardianmobile, guardianoccupation, '
        ' payincharge, payinchargemob, paremail, parotpstatus, approveddate, activestatus) '
        'VALUES ($1,$2,$3,''P'',$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,NULLIF(TRIM($15),''''),0,now(),1) RETURNING par_id', v_schema)
      INTO v_par_id
      USING v.ins_id, v_yr_id, v_yrlabel, v.fathername, v.fathermobile, v.fatheroccupation,
            v.mothername, v.mothermobile, v.motheroccupation, v.guardianname, v.guardianmobile,
            v.guardianoccupation, COALESCE(NULLIF(TRIM(v.payincharge), ''), v.stuname), v.payinchargemob, v.paremail;
    END IF;

    -- 3) parentdetail link
    EXECUTE format(
      'INSERT INTO %I.parentdetail '
      '(yr_id, yrlabel, par_id, stu_id, ins_id, inscode, stuadmno, stuname, stuclass, activestatus) '
      'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema)
    USING v_yr_id, v_yrlabel, v_par_id, v_stu_id, v.ins_id, v.inscode, p_stuadmno, v.stuname, p_class;
  END IF;

  -- 4) stamp the admission row as allocated (admission no longer has stu_id).
  UPDATE public.admission
     SET allocatedclass = p_class,
         admstatus = 'ALLOCATED',
         allocatedby = p_allocatedby,
         allocateddate = now()
   WHERE adm_id = p_adm_id;

  -- NOTE: fee demand is deliberately NOT generated on admission/allocation.
  -- Enrolment creates the student (+ parent) only; fee demands are raised
  -- separately from the Fee Demand screen (generate_feedemand_*). Allocation
  -- therefore never seeds tempfeedemand. (v_adm_id stays declared but unused.)

  RETURN json_build_object(
    'adm_id', p_adm_id, 'stu_id', v_stu_id, 'par_id', v_par_id,
    'stuadmno', p_stuadmno, 'class', p_class, 'status', 'ALLOCATED');
END;
$fn$;

-- ############################################################################
-- 4 -- FEE DEMANDS skip a pre-admission student
-- ############################################################################
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

-- ############################################################################
-- 5 -- ROLLOVER keeps their class, clears the flag, and carries the money
-- ############################################################################
CREATE OR REPLACE FUNCTION public.rollover_academic_year(p_ins_id integer, p_old_year_label text, p_new_year_label text, p_start_date date, p_end_date date) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
DECLARE
  v_short        text;
  v_old          text;   -- old schema name
  v_new          text;   -- new schema name
  v_new_yr       integer;
  v_active       integer := 0;
  v_carried      integer := 0;
  v_graduated    integer := 0;
  v_parents      integer := 0;
  v_pdetail      integer := 0;
  v_openrows     integer := 0;
  v_openamt      numeric(14,2) := 0;
BEGIN
  -- --- resolve schema names ------------------------------------------------
  SELECT lower(inshortname) INTO v_short
  FROM public.institution WHERE ins_id = p_ins_id;
  IF v_short IS NULL THEN
    RAISE EXCEPTION 'Institution % not found', p_ins_id;
  END IF;

  v_old := v_short || replace(p_old_year_label, '-', '');
  v_new := v_short || replace(p_new_year_label, '-', '');

  -- --- guards --------------------------------------------------------------
  IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_old) THEN
    RAISE EXCEPTION 'Old year schema % does not exist', v_old;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_new) THEN
    RAISE EXCEPTION 'New year schema % already exists - aborting to avoid clobber', v_new;
  END IF;

  -- --- 1. build the empty new-year schema (+ year / institutionyear rows) --
  PERFORM public.create_institution_schema(v_new, p_ins_id, p_new_year_label, p_start_date, p_end_date);

  EXECUTE format('SELECT yr_id FROM %I.year ORDER BY yr_id LIMIT 1', v_new) INTO v_new_yr;

  -- ========================================================================
  -- 2. MASTER / CONFIG  (copy as-is, preserve PKs, then advance sequences)
  -- ========================================================================

  -- bank  (ban_id is GENERATED ALWAYS AS IDENTITY -> OVERRIDING SYSTEM VALUE)
  EXECUTE format($q$
    INSERT INTO %1$I.bank
      (ban_id, banname, banbranch, ifsccode, banaddress1, banaddress2,
       banaddress3, banmobile, banemail, banaccno, banaccholder, activestatus)
    OVERRIDING SYSTEM VALUE
    SELECT ban_id, banname, banbranch, ifsccode, banaddress1, banaddress2,
       banaddress3, banmobile, banemail, banaccno, banaccholder, activestatus
    FROM %2$I.bank
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval(pg_get_serial_sequence('%1$I.bank','ban_id'),
      GREATEST((SELECT COALESCE(MAX(ban_id),0) FROM %1$I.bank),1))$q$, v_new);

  -- course
  EXECUTE format($q$
    INSERT INTO %1$I.course (cour_id, courname, ordid, ins_id, activestatus)
    SELECT cour_id, courname, ordid, ins_id, activestatus FROM %2$I.course
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval('%1$I.course_cour_id_seq',
      GREATEST((SELECT COALESCE(MAX(cour_id),0) FROM %1$I.course),1))$q$, v_new);

  -- class  (preserve cla_id so succeedingclass self-references stay valid)
  EXECUTE format($q$
    INSERT INTO %1$I.class (cla_id, claname, ins_id, ordid, succeedingclass, cour_id, activestatus)
    SELECT cla_id, claname, ins_id, ordid, succeedingclass, cour_id, activestatus FROM %2$I.class
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval('%1$I.class_cla_id_seq',
      GREATEST((SELECT COALESCE(MAX(cla_id),0) FROM %1$I.class),1))$q$, v_new);

  -- concessioncategory
  EXECUTE format($q$
    INSERT INTO %1$I.concessioncategory (con_id, condesc, ins_id, ordid, activestatus)
    SELECT con_id, condesc, ins_id, ordid, activestatus FROM %2$I.concessioncategory
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval('%1$I.concessioncategory_con_id_seq',
      GREATEST((SELECT COALESCE(MAX(con_id),0) FROM %1$I.concessioncategory),1))$q$, v_new);

  -- admissiontype (smallint PK, no sequence)
  EXECUTE format($q$
    INSERT INTO %1$I.admissiontype (adm_id, admname, ins_id, activestatus, createdat, createdby)
    SELECT adm_id, admname, ins_id, activestatus, createdat, createdby FROM %2$I.admissiontype
  $q$, v_new, v_old);

  -- quota (smallint PK, no sequence)
  EXECUTE format($q$
    INSERT INTO %1$I.quota (quo_id, quoname, ins_id, activestatus, createdat, createdby)
    SELECT quo_id, quoname, ins_id, activestatus, createdat, createdby FROM %2$I.quota
  $q$, v_new, v_old);

  -- paymentgateway (identity)
  EXECUTE format($q$
    INSERT INTO %1$I.paymentgateway
      (gw_id, gwname, gwapikey, gwapisecret, activestatus)
    OVERRIDING SYSTEM VALUE
    SELECT gw_id, gwname, gwapikey, gwapisecret, activestatus FROM %2$I.paymentgateway
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval(pg_get_serial_sequence('%1$I.paymentgateway','gw_id'),
      GREATEST((SELECT COALESCE(MAX(gw_id),0) FROM %1$I.paymentgateway),1))$q$, v_new);

  -- finerule (identity)
  EXECUTE format($q$
    INSERT INTO %1$I.finerule
      (fr_id, ins_id, rulename, feetype, from_days, to_days, fine_type, fine_value, activestatus, createdat, createdby)
    OVERRIDING SYSTEM VALUE
    SELECT fr_id, ins_id, rulename, feetype, from_days, to_days, fine_type, fine_value, activestatus, createdat, createdby
    FROM %2$I.finerule
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval(pg_get_serial_sequence('%1$I.finerule','fr_id'),
      GREATEST((SELECT COALESCE(MAX(fr_id),0) FROM %1$I.finerule),1))$q$, v_new);

  -- classfeedemand  (class-level fee template, no year column)
  EXECUTE format($q$
    INSERT INTO %1$I.classfeedemand (cf_id, cfclass, cfterm, cffeetype, cfamount, cfdduedate, admissiontype)
    SELECT cf_id, cfclass, cfterm, cffeetype, cfamount, cfdduedate, admissiontype FROM %2$I.classfeedemand
  $q$, v_new, v_old);
  EXECUTE format($q$SELECT setval('%1$I.classfeedemand_cf_id_seq',
      GREATEST((SELECT COALESCE(MAX(cf_id),0) FROM %1$I.classfeedemand),1))$q$, v_new);

  -- feegroup  (re-stamp year)
  EXECUTE format($q$
    INSERT INTO %1$I.feegroup (fg_id, fgdesc, ban_id, ins_id, yr_id, yrlabel, activestatus)
    SELECT fg_id, fgdesc, ban_id, ins_id, $1, $2, activestatus FROM %2$I.feegroup
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  EXECUTE format($q$SELECT setval('%1$I.feegroup_fg_id_seq',
      GREATEST((SELECT COALESCE(MAX(fg_id),0) FROM %1$I.feegroup),1))$q$, v_new);

  -- feetype  (re-stamp year, keep fg_id link)
  EXECUTE format($q$
    INSERT INTO %1$I.feetype (fee_id, feedesc, feeshort, feefineapplicable, fg_id, yr_id, yrlabel, activestatus, ins_id)
    SELECT fee_id, feedesc, feeshort, feefineapplicable, fg_id, $1, $2, activestatus, ins_id FROM %2$I.feetype
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  EXECUTE format($q$SELECT setval('%1$I.feetype_fee_id_seq',
      GREATEST((SELECT COALESCE(MAX(fee_id),0) FROM %1$I.feetype),1))$q$, v_new);

  -- sequence  (re-stamp year, RESET running number to start)
  EXECUTE format($q$
    INSERT INTO %1$I.sequence
      (ins_id, mod_id, yr_id, yrlabel, actname, seqname, isprefix, seqprefix,
       seqstart, seqwidth, sequid, seqcurno, activestatus, fg_id)
    SELECT ins_id, mod_id, $1, $2, actname, seqname, isprefix, seqprefix,
       seqstart, seqwidth, sequid, seqstart, activestatus, fg_id
    FROM %2$I.sequence
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;

  -- ========================================================================
  -- 3. PROMOTION MAP  (which students carry forward, and to which class)
  -- ========================================================================
  CREATE TEMP TABLE _promote (stu_id bigint PRIMARY KEY, new_class varchar(20)) ON COMMIT DROP;

  EXECUTE format($q$
    INSERT INTO _promote (stu_id, new_class)
    SELECT s.stu_id,
           CASE
             -- PRE-ADMISSION: admitted during this year to hold a seat for the
             -- NEXT one. The coming year is their FIRST, so they start in the
             -- class they were admitted to -- promoting them would put a
             -- first-year into second year on day one.
             WHEN COALESCE(s.preadmission, 0) = 1 THEN s.stuclass
             WHEN c.cla_id IS NULL THEN s.stuclass            -- class master unmatched: keep class
             ELSE COALESCE(nc.claname, s.stuclass)            -- promoted to next class
           END
    FROM %1$I.students s
    LEFT JOIN %1$I.class c
      ON UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
     AND c.ins_id = s.ins_id AND c.activestatus = 1
    LEFT JOIN %1$I.class nc ON nc.cla_id = c.succeedingclass
    WHERE s.activestatus = 1
      -- A pre-admission student is never "graduating", whatever class they hold.
      AND (COALESCE(s.preadmission, 0) = 1
           OR NOT (c.cla_id IS NOT NULL AND c.succeedingclass IS NULL))  -- exclude terminal/graduating
  $q$, v_old);

  EXECUTE format('SELECT COUNT(*) FROM %I.students WHERE activestatus = 1', v_old) INTO v_active;
  SELECT COUNT(*) INTO v_carried FROM _promote;
  v_graduated := v_active - v_carried;

  -- ========================================================================
  -- 4. STUDENTS  (preserve stu_id, promote class, re-stamp year)
  -- ========================================================================
  EXECUTE format($q$
    INSERT INTO %1$I.students
      (stu_id, ins_id, inscode, yr_id, yrlabel, stuadmno, stuadmdate, stuname,
       stugender, studob, stumobile, stuemail, stuaddress, stucity, stustate,
       stucountry, stupin, stugeocoordinates, stubloodgrp, stuphoto, stuclass,
       cour_id, courname, con_id, stucondesc, stuser_id, stupassword,
       stuotpstatus, approvedby, approveddate, activestatus, createdon,
       batch, admname, quoname, admittyear, preadmission)
    SELECT s.stu_id, s.ins_id, s.inscode, $1, $2, s.stuadmno, s.stuadmdate, s.stuname,
       s.stugender, s.studob, s.stumobile, s.stuemail, s.stuaddress, s.stucity, s.stustate,
       s.stucountry, s.stupin, s.stugeocoordinates, s.stubloodgrp, s.stuphoto, p.new_class,
       s.cour_id, s.courname, s.con_id, s.stucondesc, s.stuser_id, s.stupassword,
       0, s.approvedby, now(), 1, now(),
       s.batch, s.admname, s.quoname, s.admittyear, 0
    FROM %2$I.students s
    JOIN _promote p ON p.stu_id = s.stu_id
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  -- preadmission is written as 0 above: the year they were waiting for has
  -- arrived, so in the new schema they are an ordinary student of that class.

  EXECUTE format($q$SELECT setval('%1$I.students_stu_id_seq',
      GREATEST((SELECT COALESCE(MAX(stu_id),0) FROM %1$I.students),1))$q$, v_new);

  -- ========================================================================
  -- 4b. UNSPENT ADVANCES  (money in hand, so it MUST follow its student)
  -- ========================================================================
  -- The whole point of a pre-admission collection: the deposit is taken this
  -- year and adjusted against next year's fees. Left behind it would be money
  -- the institution holds and the new year cannot see. Only rows with a
  -- balance are carried -- a fully spent or refunded advance is history and
  -- belongs to the year it was settled in. adv_id is preserved so the detail
  -- rows still match, and the class is re-stamped to the class the student
  -- lands in.
  --
  -- Guarded: a schema created before the advance module has no such table.
  IF to_regclass(format('%I.advance_collection', v_old)) IS NOT NULL
     AND to_regclass(format('%I.advance_collection', v_new)) IS NOT NULL THEN
    EXECUTE format($q$
      INSERT INTO %1$I.advance_collection
        (adv_id, ins_id, inscode, stu_id, stuadmno, stuname, stuclass, courname,
         yr_id, yrlabel, advno, advdate, advtype, transtotalamount, adjustedamount,
         refund_amount, transcurrency, paystatus, paymethod, payreference,
         remarks, createdby, createdat, recon_status, reconciled_by,
         reconciled_date, bank_reference, bank_date, activestatus)
      OVERRIDING SYSTEM VALUE
      SELECT a.adv_id, a.ins_id, a.inscode, a.stu_id, a.stuadmno, a.stuname,
             p.new_class, a.courname, $1, $2, a.advno, a.advdate, a.advtype,
             -- Carried forward at its REMAINING value: what was already spent
             -- was spent in the old year and must not be spendable again.
             a.balanceamount, 0, 0,
             a.transcurrency, a.paystatus, a.paymethod, a.payreference,
             COALESCE(NULLIF(a.remarks, ''), '') , a.createdby, a.createdat,
             a.recon_status, a.reconciled_by, a.reconciled_date,
             a.bank_reference, a.bank_date, a.activestatus
        FROM %2$I.advance_collection a
        JOIN _promote p ON p.stu_id = a.stu_id
       WHERE a.activestatus = 1 AND a.balanceamount > 0
    $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
    EXECUTE format($q$SELECT setval('%1$I.advance_collection_adv_id_seq',
        GREATEST((SELECT COALESCE(MAX(adv_id),0) FROM %1$I.advance_collection),1))$q$, v_new);

    -- The fee-type breakdown an ADMISSION advance was collected against; it is
    -- what Advance Adjustment matches on, so it has to come too.
    IF to_regclass(format('%I.advance_detail', v_new)) IS NOT NULL THEN
      EXECUTE format($q$
        INSERT INTO %1$I.advance_detail (adv_id, ins_id, fee_id, fg_id, feetype, amount, activestatus)
        SELECT d.adv_id, d.ins_id, d.fee_id, d.fg_id, d.feetype, d.amount, d.activestatus
          FROM %2$I.advance_detail d
          JOIN %1$I.advance_collection a ON a.adv_id = d.adv_id
         WHERE d.activestatus = 1
      $q$, v_new, v_old);
    END IF;
  END IF;

  -- ========================================================================
  -- 5. PARENTS  (only those linked to carried students)
  -- ========================================================================
  EXECUTE format($q$
    INSERT INTO %1$I.parents
      (par_id, yr_id, yrlabel, partype, paremail, fathername, mothername,
       guardianname, fathermobile, mothermobile, guardianmobile,
       fatheroccupation, motheroccupation, guardianoccupation, payincharge,
       payinchargemob, parpassword, parotpstatus, approvedby, approveddate,
       activestatus, ins_id)
    SELECT par_id, $1, $2, partype, paremail, fathername, mothername,
       guardianname, fathermobile, mothermobile, guardianmobile,
       fatheroccupation, motheroccupation, guardianoccupation, payincharge,
       payinchargemob, parpassword, 0, approvedby, approveddate,
       activestatus, ins_id
    FROM %2$I.parents
    WHERE par_id IN (
      SELECT DISTINCT pd.par_id FROM %2$I.parentdetail pd
      JOIN _promote p ON p.stu_id = pd.stu_id
    )
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  GET DIAGNOSTICS v_parents = ROW_COUNT;

  EXECUTE format($q$SELECT setval('%1$I.parents_par_id_seq',
      GREATEST((SELECT COALESCE(MAX(par_id),0) FROM %1$I.parents),1))$q$, v_new);

  -- ========================================================================
  -- 6. PARENTDETAIL  (carried students, class updated)
  -- ========================================================================
  EXECUTE format($q$
    INSERT INTO %1$I.parentdetail
      (pd_id, yr_id, yrlabel, par_id, stu_id, ins_id, inscode, stuadmno, stuname, stuclass, activestatus)
    SELECT pd.pd_id, $1, $2, pd.par_id, pd.stu_id, pd.ins_id, pd.inscode,
       pd.stuadmno, pd.stuname, p.new_class, pd.activestatus
    FROM %2$I.parentdetail pd
    JOIN _promote p ON p.stu_id = pd.stu_id
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label;
  GET DIAGNOSTICS v_pdetail = ROW_COUNT;

  EXECUTE format($q$SELECT setval('%1$I.parentdetail_pd_id_seq',
      GREATEST((SELECT COALESCE(MAX(pd_id),0) FROM %1$I.parentdetail),1))$q$, v_new);

  -- ========================================================================
  -- 7. OPENING BALANCE  (consolidate prior-year unpaid dues per feetype)
  --    Grouped per student + feetype so bank routing (feetype->feegroup->bank)
  --    is preserved when these are collected in the new year.
  -- ========================================================================
  EXECUTE format($q$
    INSERT INTO %1$I.feedemand
      (yr_id, ins_id, inscode, stu_id, stuadmno, stuclass, demfeeyear,
       demfeeterm, demfeetype, feeamount, con_id, conamount, paidamount,
       fineamount, balancedue, reconbalancedue, duedate, paidstatus,
       createdby, activestatus, courname, remarks)
    SELECT $1, d.ins_id, d.inscode, d.stu_id, d.stuadmno, p.new_class, $2,
       'Opening Balance', d.demfeetype, SUM(d.balancedue), d.con_id, 0, 0,
       0, SUM(d.balancedue), SUM(d.balancedue), $3, 'U',
       'YEAR_ROLLOVER', 1, d.courname, ('Dues ' || $4)
    FROM %2$I.feedemand d
    JOIN _promote p ON p.stu_id = d.stu_id
    WHERE d.activestatus = 1 AND d.paidstatus = 'U' AND d.balancedue > 0
    GROUP BY d.ins_id, d.inscode, d.stu_id, d.stuadmno, p.new_class, d.demfeetype, d.con_id, d.courname
  $q$, v_new, v_old) USING v_new_yr, p_new_year_label, p_start_date, p_old_year_label;
  GET DIAGNOSTICS v_openrows = ROW_COUNT;

  EXECUTE format($q$SELECT COALESCE(SUM(balancedue),0) FROM %1$I.feedemand WHERE createdby='YEAR_ROLLOVER'$q$, v_new)
    INTO v_openamt;

  -- ========================================================================
  -- DONE
  -- ========================================================================
  RETURN json_build_object(
    'old_schema',          v_old,
    'new_schema',          v_new,
    'new_yr_id',           v_new_yr,
    'active_students',     v_active,
    'students_carried',    v_carried,
    'students_graduated',  v_graduated,
    'parents_carried',     v_parents,
    'parentdetail_carried',v_pdetail,
    'opening_balance_rows',v_openrows,
    'opening_balance_total',v_openamt
  );
END;
$_$;
GRANT EXECUTE ON FUNCTION public.rollover_academic_year(p_ins_id integer, p_old_year_label text, p_new_year_label text, p_start_date date, p_end_date date) TO anon, authenticated;


-- ############################################################################
-- 6 -- TWO PLACES THAT COUNT STUDENTS RATHER THAN DEMANDS
--
-- Every other report is demand-driven, and a pre-admission student has no
-- demands, so they are already absent from Pending Payment, Pending Details,
-- the DCB Register and the Student Ledger. Their advance DOES show in Daily
-- Collection, which is right -- the money was taken.
--
-- These two count STUDENTS, so they had to be told:
--   * Consolidated Status' class strength -- next year's intake is not this
--     class's strength.
--   * get_students_by_class, behind the Students screen.
-- ############################################################################
CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(
    p_schema TEXT, p_ins_id INT, p_tc TEXT
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r json; v_stu text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    EXECUTE format($f$
        WITH class_strength AS (
            SELECT courname, stuclass, COUNT(DISTINCT stu_id)::INT AS strength
            FROM   %1$I.students WHERE ins_id = %2$L AND activestatus = 1
              -- Next year's intake is not this class's strength.
              AND COALESCE(preadmission, 0) = 0
            GROUP BY courname, stuclass
        ),
        pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.category, t.type), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  cs.strength,
                  fd.demfeeterm::TEXT AS semester,
                  -- category = admission type (e.g. GOVERNMENT QUOTA / MANAGEMENT QUOTA)
                  COALESCE(NULLIF(s.admname, ''), 'GENERAL')::TEXT AS category,
                  COUNT(DISTINCT s.stu_id)::INT AS stud_count,
                  (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                  SUM(fd.feeamount)::NUMERIC AS due,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  SUM(fd.feeamount)::NUMERIC AS net_demand,
                  -- Paid = fee-only, approved-only (pending-approval amounts are subtracted)
                  GREATEST(
                    COALESCE(SUM(fd.paidamount),0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)
                      - COALESCE(SUM(pa.pending_fee),0),
                    0
                  )::NUMERIC AS paid,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS balance
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN class_strength cs
                 ON cs.courname = s.courname AND cs.stuclass = s.stuclass
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
          GROUP BY s.courname, s.stuclass, cs.strength,
                   fd.demfeeterm, COALESCE(NULLIF(s.admname, ''), 'GENERAL'),
                   (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)
        ) t
    $f$, p_schema, p_ins_id, v_stu) INTO r;
    RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.get_students_by_class(p_ins_id integer, p_class text) RETURNS SETOF json
LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE v text; BEGIN v := get_institution_schema(p_ins_id); IF v IS NULL THEN RETURN; END IF;
RETURN QUERY EXECUTE format('SELECT row_to_json(t) FROM (SELECT * FROM %I.students WHERE ins_id = $1 AND activestatus = 1 AND COALESCE(preadmission,0) = 0 AND stuclass = $2 ORDER BY stuname) t', v) USING p_ins_id, p_class; END; $$;

NOTIFY pgrst, 'reload schema';


-- ############################################################################
-- VERIFY -- every flag must read t.
-- ############################################################################
SELECT
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema='public' AND table_name='admission'
      AND column_name='preadmission') = 1                        AS admission_has_column,
  (SELECT bool_and(has_col) FROM (
     SELECT EXISTS (SELECT 1 FROM information_schema.columns c
                     WHERE c.table_schema=t.table_schema AND c.table_name='students'
                       AND c.column_name='preadmission') AS has_col
       FROM information_schema.tables t
      WHERE t.table_name='students'
        AND t.table_schema NOT IN ('pg_catalog','information_schema')) q
  )                                                              AS every_schema_has_column,
  (SELECT prosrc LIKE '%preadmission%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='allocate_admission_to_student')  AS allocation_copies_it,
  (SELECT prosrc LIKE '%preadmission%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='generate_feedemand_for_class')   AS demands_skip_them,
  (SELECT prosrc LIKE '%preadmission%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='rollover_academic_year')         AS rollover_keeps_class,
  (SELECT prosrc LIKE '%advance_collection%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='rollover_academic_year')         AS rollover_carries_advances,
  (SELECT prosrc LIKE '%preadmission%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='create_institution_schema')      AS new_schemas_get_column;

-- How many pre-admission students there are, per year schema.
DO $count$
DECLARE r RECORD; n int;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'students'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('SELECT count(*) FROM %I.students WHERE preadmission = 1', r.s) INTO n;
    RAISE NOTICE '%: % pre-admission student(s)', r.s, n;
  END LOOP;
END $count$;
