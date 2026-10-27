-- =====================================================================
-- LIVE -- stop payment.pay_id being handed out twice. Run ONCE.
--
-- THE DEFECT. set_pay_id assigns a new payment's id with
--     SELECT COALESCE(MAX(pay_id),0) + 1 FROM payment
-- so deleting the highest row RELEASES its id and the next insert hands that
-- same id to a different student.
--
-- WHY IT COSTS REAL MONEY. The parent app's Paytm order id embeds the pay_id
-- ('PAY-<pay_id>t<timestamp>'). On 1 Oct 2026 a parent's first attempt took
-- pay_id 2803; that row went away; 2803 was reissued to another student and
-- became receipt FC26/03312; the parent -- still holding payId 2803 -- paid
-- Rs 8,000 at 17:58 and Paytm captured it. The completion was refused because
-- 2803 already carried a receipt, so the money was recorded NOWHERE and was
-- found only by reconciling against Paytm by hand.
--
-- The refusal was right: without it the Rs 8,000 would have been credited to
-- the OTHER student's demand, which is worse than a visible gap. The id reuse
-- is the thing to fix.
--
-- PART 1 switches every existing schema to the payment_pay_id_seq sequence
--        that already exists and has never been used. A sequence never
--        reissues a number, so a stale pay_id points at a row that simply does
--        not exist -- which the callers already handle.
-- PART 2 fixes create_institution_schema, so the NEXT institution is not built
--        with the defect.
--
-- PROVEN ON TEST against a faithful copy of live's behaviour:
--     before:  BUG REPRODUCED: pay_id 2827 reissued to a different student
--     after:   ids 2828, 2829, 2830 -- each issued once, never reused
--              explicit id honoured: 999777   (imports still work)
--     new tenant: ids 1 then 2 -- no reuse
--
-- SAFETY. The sequence is parked above the highest id in use BEFORE the
-- trigger starts using it, so the first new id cannot collide. No existing row
-- is changed. Idempotent. No BEGIN -- one Run commits it.
--
-- RUN IT WHEN THE COUNTER IS QUIET (IS_THE_COUNTER_QUIET.sql): it replaces
-- functions on the payment path, so a collection at that instant may error
-- once and be retried.
-- =====================================================================


-- #####################################################################
-- PART 1 of 2 -- every existing schema
-- #####################################################################
DO $fix$
DECLARE s text; v_max bigint; v_seq text; n int := 0;
BEGIN
  FOR s IN SELECT table_schema FROM information_schema.tables
            WHERE table_name = 'payment'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    v_seq := s || '.payment_pay_id_seq';

    -- The builder creates this sequence already; be certain for older schemas.
    EXECUTE format('CREATE SEQUENCE IF NOT EXISTS %I.payment_pay_id_seq', s);

    -- Park it above every id in use. is_called = true when rows exist, so the
    -- next value is MAX+1; false on an empty table, so the first value is 1.
    EXECUTE format('SELECT COALESCE(MAX(pay_id), 0) FROM %I.payment', s) INTO v_max;
    EXECUTE format('SELECT setval(%L, GREATEST(%s, 1), %L)',
                   v_seq, v_max, (v_max > 0));

    -- The trigger now draws from the sequence. The NULL/0 guard stays so a
    -- caller supplying an explicit id (master/collection imports) still wins.
    EXECUTE format($t$
      CREATE OR REPLACE FUNCTION %1$I.set_pay_id() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $f$
      BEGIN
        IF NEW.pay_id IS NULL OR NEW.pay_id = 0 THEN
          -- A SEQUENCE, not MAX(pay_id)+1: deleting the highest row must never
          -- release its id for reuse. The parent app's Paytm order id carries
          -- the pay_id, so a reissued id sends one family's payment at another
          -- family's receipt.
          NEW.pay_id := nextval(%2$L);
        END IF;
        RETURN NEW;
      END; $f$
    $t$, s, v_seq);

    RAISE NOTICE '%: sequence parked at %, trigger now uses nextval', s, v_max;
    n := n + 1;
  END LOOP;
  RAISE NOTICE '% schema(s) fixed', n;
END $fix$;




-- #####################################################################
-- PART 2 of 2 -- the builder, so the NEXT institution is clean
-- #####################################################################
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
  EXECUTE format('CREATE OR REPLACE FUNCTION %1$I.fn_approve_tempfeedemand() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ DECLARE v_dem_id bigint; v_paid numeric; v_net numeric; BEGIN IF NEW.isapproved = true AND (OLD.isapproved = false OR OLD.isapproved IS NULL) THEN SELECT dem_id, COALESCE(paidamount, 0) INTO v_dem_id, v_paid FROM %1$I.feedemand WHERE ins_id = NEW.ins_id AND NEW.demno IS NOT NULL AND btrim(NEW.demno) <> '''' AND demno IS NOT DISTINCT FROM NEW.demno AND demfeetype IS NOT DISTINCT FROM NEW.demfeetype AND activestatus = 1 ORDER BY dem_id LIMIT 1; IF v_dem_id IS NOT NULL THEN v_net := GREATEST(COALESCE(NEW.feeamount,0) - COALESCE(NEW.conamount,0) - v_paid, 0); UPDATE %1$I.feedemand SET feeamount = NEW.feeamount, con_id = NEW.con_id, conamount = NEW.conamount, balancedue = v_net, reconbalancedue = v_net, paidstatus = CASE WHEN v_net <= 0 THEN ''P'' ELSE ''U'' END, duedate = NEW.duedate, collectible = COALESCE(NEW.collectible, collectible), cla_id = NEW.cla_id, sem_id = NEW.sem_id, fee_id = NEW.fee_id, cf_id = NEW.cf_id, demseqtype = COALESCE(NEW.demseqtype, demseqtype), arrearclass = NEW.arrearclass WHERE dem_id = v_dem_id; ELSE INSERT INTO %1$I.feedemand (demno, demseqtype, ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear, demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue, duedate, activestatus, createdat, createdby, paidstatus, paidamount, collectible, cla_id, sem_id, fee_id, cf_id, arrearclass) VALUES (NEW.demno, NEW.demseqtype, NEW.ins_id, NEW.inscode, NEW.yr_id, NEW.stu_id, NEW.stuadmno, NEW.stuclass, NEW.courname, NEW.demfeeyear, NEW.demfeeterm, NEW.demfeetype, NEW.feeamount, NEW.con_id, NEW.conamount, NEW.balancedue, COALESCE(NEW.balancedue, NEW.feeamount), NEW.duedate, 1, NEW.createdat, NEW.createdby, ''U'', 0, COALESCE(NEW.collectible, true), NEW.cla_id, NEW.sem_id, NEW.fee_id, NEW.cf_id, NEW.arrearclass); END IF; NEW.activestatus := 9; END IF; RETURN NEW; END; $t$', v_schema);
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
  EXECUTE format('CREATE TABLE %I.class (cla_id integer NOT NULL PRIMARY KEY, claname varchar(20) NOT NULL, ins_id integer, ordid smallint, succeedingclass integer, cour_id integer, activestatus smallint DEFAULT 1 NOT NULL, classtype varchar(12) DEFAULT ''PROMOTIONAL'' NOT NULL CHECK (classtype = ANY(ARRAY[''PROMOTIONAL'',''TERMINAL'',''COMPLETED''])))', v_schema);
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
  EXECUTE format('CREATE TABLE %I.advance_collection (adv_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ins_id integer NOT NULL, inscode varchar(10), stu_id bigint NOT NULL, stuadmno varchar(25), stuname varchar(50), stuclass varchar(20), courname varchar(20), yr_id integer, yrlabel varchar(20), advno varchar(30) NOT NULL, advdate timestamp DEFAULT now() NOT NULL, advtype char(1) DEFAULT ''S'' NOT NULL CONSTRAINT chk_advance_advtype CHECK (advtype = ANY(ARRAY[''A'',''S'',''M''])), transtotalamount numeric(12,2) NOT NULL CHECK (transtotalamount > 0), adjustedamount numeric(12,2) DEFAULT 0 NOT NULL, refund_amount numeric(12,2) DEFAULT 0 NOT NULL, balanceamount numeric(12,2) GENERATED ALWAYS AS (transtotalamount - adjustedamount - refund_amount) STORED, transcurrency varchar(20) DEFAULT ''INR'' NOT NULL, paystatus char(1) DEFAULT ''C'' NOT NULL CHECK (paystatus = ANY(ARRAY[''I'',''C'',''F'',''R''])), paymethod varchar(60), payreference varchar(100), payorderid varchar(100), paytm_txnid varchar(60), paychequeno varchar(50), paychequedate date, paybankname varchar(100), ban_id integer, recon_status char(1) DEFAULT ''P'', reconciled_by varchar(50), reconciled_date timestamp, bank_reference varchar(100), bank_date date, tender_amount numeric(12,2), remarks varchar(255), createdby varchar(50), createdat timestamp DEFAULT now() NOT NULL, voidedby varchar(100), voideddate timestamp, voidreason varchar(255), activestatus smallint DEFAULT 1 NOT NULL)', v_schema);
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
  EXECUTE format('CREATE FUNCTION %1$I.set_pay_id() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $t$ BEGIN IF NEW.pay_id IS NULL OR NEW.pay_id = 0 THEN NEW.pay_id := nextval(''%1$I.payment_pay_id_seq''); END IF; RETURN NEW; END; $t$', v_schema);
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

-- #####################################################################
-- PART 2 -- normalise advtype on every existing tenant schema
--
-- Drops BOTH spellings before adding the right one. BANK_ROUTING_BY_FEEGROUP
-- only knew about the named form, so a schema built by the drifted builder
-- kept an auto-named constraint that still refused 'M'.
-- #####################################################################
DO $adv$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT table_schema AS s FROM information_schema.tables
            WHERE table_name = 'advance_collection'
              AND table_schema NOT IN ('pg_catalog','information_schema')
            ORDER BY table_schema
  LOOP
    EXECUTE format('ALTER TABLE %I.advance_collection DROP CONSTRAINT IF EXISTS chk_advance_advtype', r.s);
    EXECUTE format('ALTER TABLE %I.advance_collection DROP CONSTRAINT IF EXISTS advance_collection_advtype_check', r.s);
    EXECUTE format($q$ALTER TABLE %I.advance_collection
      ADD CONSTRAINT chk_advance_advtype CHECK (advtype = ANY(ARRAY['A','S','M']))$q$, r.s);
    RAISE NOTICE 'advtype normalised on %', r.s;
  END LOOP;
END $adv$;


-- #####################################################################
-- VERIFY -- every tenant must allow A, S and M.
-- #####################################################################
SELECT n.nspname AS schema, pg_get_constraintdef(c.oid) AS advtype_rule,
       CASE WHEN pg_get_constraintdef(c.oid) LIKE '%M%' THEN 'ok' ELSE 'STILL REJECTS M' END AS state
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
 WHERE t.relname = 'advance_collection' AND c.contype = 'c'
   AND pg_get_constraintdef(c.oid) LIKE '%advtype%'
 ORDER BY 1;


-- #####################################################################
-- VERIFY -- pay_id_source must read 'sequence', and seq_at must equal
-- highest_row (so the next payment gets highest_row + 1 and cannot collide).
-- #####################################################################
SELECT n.nspname AS schema,
       CASE WHEN p.prosrc LIKE '%nextval%' THEN 'sequence' ELSE 'STILL MAX+1' END AS pay_id_source,
       (SELECT last_value FROM pg_sequences q
         WHERE q.schemaname = n.nspname AND q.sequencename = 'payment_pay_id_seq') AS seq_at,
       (SELECT max(pay_id) FROM kcet20262027.payment WHERE n.nspname = 'kcet20262027') AS highest_row
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE p.proname = 'set_pay_id' ORDER BY 1;

SELECT 'a NEW institution would use the sequence too' AS check,
       CASE WHEN prosrc LIKE '%payment_pay_id_seq%' THEN 'yes' ELSE 'NO - rerun part 2' END AS state
  FROM pg_proc WHERE proname='create_institution_schema' AND pronamespace='public'::regnamespace;

SELECT * FROM public.fee_health_check();
