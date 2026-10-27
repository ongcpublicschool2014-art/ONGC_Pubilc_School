-- =====================================================================
-- RUN ON LIVE -- 07-10-2026. One script, three parts, in order.
--
-- Everything here is rehearsed on TEST against a copy of live taken at
-- 12:20 today. No BEGIN/COMMIT: the Supabase editor rolls a wrapped
-- script back and it looks like it ran.
--
--   PART 1  what live looks like now (read only)
--   PART 2  restore 11 demands billed zero that are holding money
--   PART 3  stop a blank amount creating another one
--   PART 4  the same check again -- compare with PART 1
--
-- DELIBERATELY NOT HERE, and why:
--
--   * the 41 rows billed zero with NOTHING collected. They need the
--     office to say whether a scholarship student's tuition stays SPLIT
--     across two demand lines or is CONSOLIDATED onto the tuition line.
--     Both give the same total owed; the script assumes split, and 29
--     students have already been consolidated by hand. Running it blind
--     would bill those 29 twice.
--
--   * CHANDRU R (262791) BUS FEES -- billed 0, Rs 10,000 collected. Bus
--     fees are route-based (6,600 to 23,300), his record carries no
--     route, stop or address, and the next student through the same
--     dialog that morning paid 12,500 against a 15,200 bill. Writing in
--     the 10,000 he paid would close an account that may still owe.
--
--     ONLY ONCE THE TRANSPORT OFFICE HAS CONFIRMED THE ROUTE FEE, append
--     FIX_CHANDRU_BUS_FEES.sql to this script. Part 4 then returns 0
--     instead of 1. He has already been set to 10,000 + 100 on TEST; if
--     that figure was the office's answer rather than the placeholder in
--     that file, append it and live matches.
--
--   * the B.TECH ( IT) -IV class name -- already fixed on live.
-- =====================================================================


-- #####################################################################
-- PART 1 -- BEFORE. On live as of the 12:20 dump: 12 billed zero with
-- money, 0 collected more than billed, 0 balances out of step. A lower
-- first figure just means some were corrected by hand since -- Part 2
-- only touches rows still billed zero, so it stays correct either way.
-- #####################################################################
SELECT * FROM (

  -- 1. Money taken against a bill of nothing. The loud failure: the
  --    ledger shows a NEGATIVE balance and the demand reads settled.
  --    After both fix scripts this should be 1 -- CHANDRU R's bus fee,
  --    which has no sheet figure and needs the office.
  SELECT 1 AS n,
         'billed zero WITH money collected' AS check,
         count(*)::text AS value,
         COALESCE(string_agg(DISTINCT stuadmno, ', '), '-') AS detail
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND COALESCE(feeamount,0) - COALESCE(conamount,0) <= 0
     AND COALESCE(paidamount,0) > 0

  UNION ALL

  -- 2. Billed nothing, nothing collected. The SILENT failure: reads as
  --    settled, so nobody is chased and the billing is missing from
  --    every total. Most are legitimate (a fee the student is not
  --    charged); the fix scripts only touch those the 03-09 sheet bills.
  SELECT 2, 'billed zero, nothing collected', count(*)::text, ''
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND COALESCE(feeamount,0) = 0 AND COALESCE(paidamount,0) = 0

  UNION ALL

  -- 3. Collected more than billed on a single demand. Should be zero.
  --    Anything here is either a wrong bill or a double payment.
  --
  --    fineamount IS PART OF THE BILL. A fine is collected on the fee it
  --    belongs to -- the receipt shows it in its own column, but it lands
  --    in that demand's paidamount. Leave it out and every fined student
  --    is reported as overpaid: BALAMBIKA T, tuition 25,000 with a 100
  --    fine, paid 25,100, ledger balancing to zero.
  SELECT 3, 'collected MORE than billed', count(*)::text,
         COALESCE(string_agg(stuadmno || ' ' || demfeetype, ', '), '-')
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND COALESCE(feeamount,0) > 0
     AND COALESCE(paidamount,0) > COALESCE(feeamount,0) - COALESCE(conamount,0)
                                  + COALESCE(fineamount,0) + 0.005

  UNION ALL

  -- 4. Which billing convention each scholarship student is on.
  --    SPLIT    = tuition carries the share, the grant line the rest.
  --    CONSOLIDATED = the whole fee on tuition, grant at zero.
  --    Both are valid and give the same total. A growing CONSOLIDATED
  --    count is the office moving away from the split, which is what
  --    makes a generated fix script go stale.
  SELECT 4, 'scholarship students on the SPLIT convention', count(*)::text, ''
    FROM (SELECT stuadmno FROM kcet20262027.feedemand
           WHERE activestatus = 1
             AND demfeetype IN ('SC/ST SCHOLARSHIP','FIRST GRADUATE AMOUNT')
             AND COALESCE(feeamount,0) > 0
           GROUP BY stuadmno) x

  UNION ALL

  SELECT 5, 'students with a grant line still at zero', count(*)::text, ''
    FROM (SELECT stuadmno FROM kcet20262027.feedemand
           WHERE activestatus = 1
             AND demfeetype IN ('SC/ST SCHOLARSHIP','FIRST GRADUATE AMOUNT')
             AND COALESCE(feeamount,0) = 0
           GROUP BY stuadmno) y

  UNION ALL

  -- 6. The balance columns must agree with billed - concession - paid.
  --    No trigger maintains them, so a hand edit can leave them stale
  --    and the ledger then disagrees with the demand.
  SELECT 6, 'balancedue out of step with the amounts', count(*)::text,
         COALESCE(string_agg(stuadmno || ' ' || demfeetype, ', '), '-')
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND abs(COALESCE(balancedue,0)
             - GREATEST(COALESCE(feeamount,0) - COALESCE(conamount,0)
                        - COALESCE(paidamount,0), 0)) > 0.005
) r ORDER BY n;


-- #####################################################################
-- PART 2 -- restore the amounts, from the 03-09 demand sheet.
--
-- 11 of the 12 rows above. 262791 is excluded (no sheet figure exists)
-- and 421325106054 is in the list but already corrected on live, where
-- the feeamount = 0 guard skips it -- without that guard it would be
-- cut from 55,000 back to 25,000.
-- #####################################################################
WITH correct(stuadmno, demfeetype, amount) AS (VALUES
  ('421325106005', 'TUITION FEE', 50000::numeric),
  ('421325106018', 'TUITION FEE', 25000),
  ('421325106034', 'TUITION FEE', 25000),
  ('421325106035', 'TUITION FEE', 30000),
  ('421325106042', 'TUITION FEE', 30000),
  ('421325106044', 'TUITION FEE', 55000),
  ('421325106052', 'TUITION FEE', 30000),
  ('421325106053', 'TUITION FEE', 30000),
  ('421325106054', 'TUITION FEE', 25000),
  ('421325106056', 'TUITION FEE', 50000),
  ('421325106057', 'TUITION FEE', 55000),
  ('262701',       'BUS FEES',    20000)
)
UPDATE kcet20262027.feedemand fd
   SET feeamount       = c.amount,
       -- The convention on every correctly billed row in this schema:
       -- balance = billed - concession - paid, and the two balance
       -- columns agree. No trigger maintains them, so they are set here.
       balancedue      = GREATEST(c.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0),
       reconbalancedue = GREATEST(c.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0), 0),
       paidstatus      = CASE WHEN c.amount - COALESCE(fd.conamount,0) - COALESCE(fd.paidamount,0) <= 0
                              THEN 'P' ELSE 'U' END
  FROM correct c
 WHERE fd.stuadmno   = c.stuadmno
   AND fd.demfeetype = c.demfeetype
   AND fd.activestatus = 1
   -- Guard: only a row still billed nothing. A re-run changes nothing,
   -- and a demand somebody has since corrected by hand is left alone.
   AND COALESCE(fd.feeamount,0) = 0;


-- #####################################################################
-- PART 3 -- the guard. Refuses a demand with no amount, and records who
-- created it. Verified on TEST: both changes present, anon and
-- authenticated can still call it.
-- #####################################################################
CREATE OR REPLACE FUNCTION public.add_student_fee_demand(
  p_token text, p_stuadmno text, p_cf_id integer, p_amount numeric
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text; v_dem_id bigint;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  -- A demand billed nothing is not a free fee, it is a missing amount.
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION
      'Enter the amount for this fee. A fee added with no amount is billed 0, '
      'reads as fully settled and is never collected. If the student is not '
      'charged this fee, remove it instead of leaving it blank.';
  END IF;

  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  EXECUTE format($q$
    INSERT INTO %1$I.feedemand
      (ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear,
       demfeeterm, demfeetype, feeamount, con_id, conamount, balancedue, reconbalancedue,
       paidamount, duedate, activestatus, createdby, collectible,
       cla_id, sem_id, cf_id, fee_id, demseqtype)
    SELECT s.ins_id, s.inscode, s.yr_id, s.stu_id, s.stuadmno, s.stuclass, s.courname,
       s.yrlabel, cf.cfterm, cf.cffeetype, $2, s.con_id, 0, GREATEST($2,0), GREATEST($2,0),
       0, COALESCE(cf.cfdduedate, CURRENT_DATE), 1,
       COALESCE(NULLIF(btrim(s.approvedby), ''), 'SYSTEM'), true,
       cf.cla_id, cf.sem_id, cf.cf_id, cf.fee_id, 'REGULAR'
    FROM %1$I.students s
    JOIN %1$I.classfeedemand cf ON cf.cf_id = $3 AND cf.activestatus = 1
    WHERE s.stuadmno = $1 AND s.activestatus <> 9
      AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd
            WHERE fd.stu_id = s.stu_id AND fd.demfeeterm = cf.cfterm
              AND fd.demfeetype = cf.cffeetype AND fd.activestatus = 1)
    RETURNING dem_id
  $q$, v_schema) INTO v_dem_id USING p_stuadmno, p_amount, p_cf_id;
  RETURN v_dem_id;
END; $$;


-- #####################################################################
-- PART 4 -- AFTER. Expect 1 billed zero with money -- CHANDRU R, 262791,
-- the one row no sheet can answer. 0 if his script was appended.
-- Checks 3 and 6 must both be 0. Anything else, stop and look.
-- #####################################################################
SELECT * FROM (

  -- 1. Money taken against a bill of nothing. The loud failure: the
  --    ledger shows a NEGATIVE balance and the demand reads settled.
  --    After both fix scripts this should be 1 -- CHANDRU R's bus fee,
  --    which has no sheet figure and needs the office.
  SELECT 1 AS n,
         'billed zero WITH money collected' AS check,
         count(*)::text AS value,
         COALESCE(string_agg(DISTINCT stuadmno, ', '), '-') AS detail
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND COALESCE(feeamount,0) - COALESCE(conamount,0) <= 0
     AND COALESCE(paidamount,0) > 0

  UNION ALL

  -- 2. Billed nothing, nothing collected. The SILENT failure: reads as
  --    settled, so nobody is chased and the billing is missing from
  --    every total. Most are legitimate (a fee the student is not
  --    charged); the fix scripts only touch those the 03-09 sheet bills.
  SELECT 2, 'billed zero, nothing collected', count(*)::text, ''
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND COALESCE(feeamount,0) = 0 AND COALESCE(paidamount,0) = 0

  UNION ALL

  -- 3. Collected more than billed on a single demand. Should be zero.
  --    Anything here is either a wrong bill or a double payment.
  --
  --    fineamount IS PART OF THE BILL. A fine is collected on the fee it
  --    belongs to -- the receipt shows it in its own column, but it lands
  --    in that demand's paidamount. Leave it out and every fined student
  --    is reported as overpaid: BALAMBIKA T, tuition 25,000 with a 100
  --    fine, paid 25,100, ledger balancing to zero.
  SELECT 3, 'collected MORE than billed', count(*)::text,
         COALESCE(string_agg(stuadmno || ' ' || demfeetype, ', '), '-')
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND COALESCE(feeamount,0) > 0
     AND COALESCE(paidamount,0) > COALESCE(feeamount,0) - COALESCE(conamount,0)
                                  + COALESCE(fineamount,0) + 0.005

  UNION ALL

  -- 4. Which billing convention each scholarship student is on.
  --    SPLIT    = tuition carries the share, the grant line the rest.
  --    CONSOLIDATED = the whole fee on tuition, grant at zero.
  --    Both are valid and give the same total. A growing CONSOLIDATED
  --    count is the office moving away from the split, which is what
  --    makes a generated fix script go stale.
  SELECT 4, 'scholarship students on the SPLIT convention', count(*)::text, ''
    FROM (SELECT stuadmno FROM kcet20262027.feedemand
           WHERE activestatus = 1
             AND demfeetype IN ('SC/ST SCHOLARSHIP','FIRST GRADUATE AMOUNT')
             AND COALESCE(feeamount,0) > 0
           GROUP BY stuadmno) x

  UNION ALL

  SELECT 5, 'students with a grant line still at zero', count(*)::text, ''
    FROM (SELECT stuadmno FROM kcet20262027.feedemand
           WHERE activestatus = 1
             AND demfeetype IN ('SC/ST SCHOLARSHIP','FIRST GRADUATE AMOUNT')
             AND COALESCE(feeamount,0) = 0
           GROUP BY stuadmno) y

  UNION ALL

  -- 6. The balance columns must agree with billed - concession - paid.
  --    No trigger maintains them, so a hand edit can leave them stale
  --    and the ledger then disagrees with the demand.
  SELECT 6, 'balancedue out of step with the amounts', count(*)::text,
         COALESCE(string_agg(stuadmno || ' ' || demfeetype, ', '), '-')
    FROM kcet20262027.feedemand
   WHERE activestatus = 1
     AND abs(COALESCE(balancedue,0)
             - GREATEST(COALESCE(feeamount,0) - COALESCE(conamount,0)
                        - COALESCE(paidamount,0), 0)) > 0.005
) r ORDER BY n;
