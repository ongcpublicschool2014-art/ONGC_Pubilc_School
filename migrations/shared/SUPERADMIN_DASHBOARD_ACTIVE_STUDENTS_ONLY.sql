-- ============================================================================
-- Superadmin dashboard: count ACTIVE students only, like every other screen.
-- ============================================================================
-- WHAT WAS WRONG. DASHBOARD_ACTIVE_STUDENTS_ONLY.sql narrowed get_fee_totals
-- and get_fee_totals_by_seqtype to students.activestatus = 1. The superadmin
-- dashboard calls neither: it has its own pair of RPCs, and they were left
-- summing feedemand with no students join at all.
--
-- So the same college read two different ways on the same day --
--
--     institution admin   Total Fees Due   9,50,82,063
--     superadmin          Total Fees Due   9,52,75,163
--
-- -- and the superadmin, the one person who cannot open the institution
-- screen to check, saw the larger number.
--
-- WHAT THIS DOES. Adds the SAME join, written the SAME way, to both:
--
--   get_super_admin_dashboard     total_demand / total_collected /
--                                 total_pending / total_concession /
--                                 total_fine, and the pending-approval
--                                 figure subtracted from collected
--   get_super_admin_dashboard_v2  its own totals, and pending_approval --
--                                 the only number the app actually takes
--                                 from v2, and the one behind the Pending
--                                 Approval card
--
-- Everything else in both functions is byte-for-byte what was on the server:
-- these were generated from pg_get_functiondef and patched, not retyped.
--
-- NOT TOUCHED, deliberately:
--   today_collected    a receipt-level figure, already identical on both
--                      screens -- it reads payment, which carries no student
--                      status to narrow by
--   transaction_count  the same, a count of receipts
--   student_count      already WHERE activestatus = 1
--   misc_collection    no student link to join on
--
-- THE NUMBERS WILL DROP, by exactly the demand of students who have left.
-- That is the point. PART 0 prints the before so the change can be explained
-- rather than discovered.
--
-- Run AFTER DASHBOARD_ACTIVE_STUDENTS_ONLY.sql -- the verification at the
-- bottom compares the two screens, and it can only pass once both are fixed.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 0 =
-- What the superadmin sees TODAY, beside what the institution admin sees.
-- Keep this output. Expect the two to DISAGREE.
-- ===========================================================================

SELECT 'BEFORE' AS state,
       (e->>'insname')                  AS institution,
       (e->>'total_demand')::numeric    AS sa_demand,
       (e->>'total_collected')::numeric AS sa_collected,
       (e->>'total_pending')::numeric   AS sa_pending,
       (public.get_fee_totals((e->>'ins_id')::int)->>'total_demand')::numeric  AS admin_demand,
       (public.get_fee_totals((e->>'ins_id')::int)->>'total_paid')::numeric    AS admin_collected,
       (public.get_fee_totals((e->>'ins_id')::int)->>'total_pending')::numeric AS admin_pending
  FROM json_array_elements(public.get_super_admin_dashboard(NULL)) e;


-- =================================================================== PART 1 =
-- The dashboard the superadmin actually reads.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_super_admin_dashboard(p_yrlabel text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  rec RECORD;
  v_schema text;
  v_demand numeric;
  v_collected numeric;
  v_pending numeric;
  v_concession numeric;
  v_misc numeric;
  v_fine numeric;
  v_transactions int;
  v_students int;
  results json;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _sa_dashboard (
    ins_id int, insname text, inscode text, inshortname text, inslogo text,
    activestatus int, total_demand numeric, total_collected numeric,
    total_pending numeric, total_concession numeric, total_misc numeric,
    total_fine numeric, transaction_count int, student_count int
  ) ON COMMIT DROP;

  TRUNCATE _sa_dashboard;

  FOR rec IN
    SELECT i.ins_id, i.insname, i.inscode, i.inshortname, i.inslogo, i.activestatus
    FROM institution i WHERE i.activestatus = 1 ORDER BY i.ins_id
  LOOP
    v_demand := 0; v_collected := 0; v_pending := 0; v_concession := 0; v_misc := 0; v_fine := 0; v_transactions := 0; v_students := 0;

    -- Pick schema for this institution. If a yrlabel was supplied, match
    -- it exactly so all institutions report numbers for the same academic
    -- period; otherwise fall back to the institution's latest year so
    -- existing callers keep their current behaviour.
    IF p_yrlabel IS NOT NULL AND p_yrlabel <> '' THEN
      SELECT lower(rec.inshortname) || replace(iy.yrlabel, '-', '')
      INTO v_schema
      FROM institutionyear iy
      WHERE iy.ins_id = rec.ins_id
        AND iy.activestatus = 1
        AND iy.yrlabel = p_yrlabel
      LIMIT 1;
    ELSE
      SELECT lower(rec.inshortname) || replace(iy.yrlabel, '-', '')
      INTO v_schema
      FROM institutionyear iy
      WHERE iy.ins_id = rec.ins_id AND iy.activestatus = 1
      ORDER BY iy.iyr_id DESC LIMIT 1;
    END IF;

    IF v_schema IS NOT NULL AND EXISTS (
      SELECT 1 FROM information_schema.tables WHERE table_schema = v_schema AND table_name = 'feedemand'
    ) THEN
      -- Total Pending = Demand − Collection − PendingApproval (computed, so the
      -- three cards always tally even when stored balancedue/reconbalancedue
      -- drifts from feeamount − paidamount by concession/overpayment amounts).
      -- Total Collection = fee portion only (subtract fineamount and pending-approval).
      -- Pending = SUM(reconbalancedue).
      -- Collection matches get_fee_totals EXACTLY (gross paidamount − pending
      -- fee − pending fine); total_fine mirrors get_fee_totals' fine.
      -- ACTIVE STUDENTS ONLY -- the same join get_fee_totals makes, written
      -- the same way so the two cannot drift again. Without it this card
      -- counted demands raised against students who have since been issued a
      -- TC, and the superadmin's Total Fees Due stood above the institution
      -- admin's for the same college on the same day.
      EXECUTE format('SELECT COALESCE(SUM(fd.feeamount),0), COALESCE(SUM(fd.paidamount),0), COALESCE(SUM(fd.reconbalancedue),0), COALESCE(SUM(fd.conamount),0), COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus=''P'' OR fd.paidamount > 0),0) FROM %1$I.feedemand fd JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1 WHERE fd.ins_id=$1 AND fd.activestatus=1', v_schema)
      INTO v_demand, v_collected, v_pending, v_concession, v_fine USING rec.ins_id;
      DECLARE
        v_pa_fee numeric := 0;
        v_pa_fine numeric := 0;
      BEGIN
        EXECUTE format('
          SELECT COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)),0),
                 COALESCE(SUM(LEAST(pd.transtotalamount, COALESCE(fd.fineamount,0))),0)
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
          WHERE p.ins_id=$1 AND p.paystatus=''C'' AND p.recon_status=''P'' AND p.activestatus=1
            AND fd.activestatus=1
        ', v_schema) INTO v_pa_fee, v_pa_fine USING rec.ins_id;
        v_collected := GREATEST(v_collected - v_pa_fee - v_pa_fine, 0);
        v_fine := GREATEST(v_fine - v_pa_fine, 0);
      END;

      -- Miscellaneous collection (table absent in older schemas → 0).
      IF EXISTS (
        SELECT 1 FROM information_schema.tables WHERE table_schema = v_schema AND table_name = 'misc_collection'
      ) THEN
        EXECUTE format('SELECT COALESCE(SUM(totalamount),0) FROM %I.misc_collection WHERE ins_id=$1 AND activestatus=1 AND COALESCE(recon_status,''R'')=''R''', v_schema)
        INTO v_misc USING rec.ins_id;
      END IF;

      -- Transaction count
      EXECUTE format('SELECT COUNT(*) FROM %I.payment WHERE ins_id=$1 AND paystatus=''C'' AND activestatus=1', v_schema)
      INTO v_transactions USING rec.ins_id;

      -- Student count
      EXECUTE format('SELECT COUNT(*) FROM %I.students WHERE ins_id=$1 AND activestatus=1', v_schema)
      INTO v_students USING rec.ins_id;
    END IF;

    INSERT INTO _sa_dashboard VALUES (
      rec.ins_id, rec.insname, rec.inscode, rec.inshortname, rec.inslogo,
      rec.activestatus, v_demand, v_collected, v_pending, v_concession, v_misc, v_fine, v_transactions, v_students
    );
  END LOOP;

  SELECT json_agg(row_to_json(t)) INTO results FROM _sa_dashboard t;
  RETURN COALESCE(results, '[]'::json);
END; $function$;


-- =================================================================== PART 2 =
-- v2. The app takes only pending_approval and today_collected from this one,
-- but a function that disagrees with its sibling is a trap for whoever reads
-- it next -- so its totals are narrowed too.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_super_admin_dashboard_v2(p_yrlabel text DEFAULT NULL::text)
 RETURNS TABLE(ins_id integer, insname text, inscode text, inshortname text, inslogo text, activestatus smallint, student_count integer, total_demand numeric, total_collected numeric, total_pending numeric, pending_approval numeric, today_collected numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
    rec       RECORD;
    schema_n  TEXT;
    short_n   TEXT;
    yr_label  TEXT;
    demand    NUMERIC;
    collected NUMERIC;
    pending   NUMERIC;
    pending_a NUMERIC;
    today_c   NUMERIC;
    stu_cnt   INT;
BEGIN
    FOR rec IN
        SELECT i.ins_id, i.insname, i.inscode, i.inshortname, i.inslogo, i.activestatus
        FROM   public.institution i
        ORDER  BY i.ins_id
    LOOP
        short_n  := lower(rec.inshortname);
        yr_label := NULL;
        IF p_yrlabel IS NOT NULL AND btrim(p_yrlabel) <> '' THEN
            SELECT iy.yrlabel INTO yr_label
            FROM   public.institutionyear iy
            WHERE  iy.ins_id = rec.ins_id AND iy.activestatus = 1 AND iy.yrlabel = p_yrlabel
            LIMIT  1;
        END IF;
        IF yr_label IS NULL THEN
            SELECT iy.yrlabel INTO yr_label
            FROM   public.institutionyear iy
            WHERE  iy.ins_id = rec.ins_id AND iy.activestatus = 1
            ORDER  BY iy.iyr_id DESC
            LIMIT  1;
        END IF;

        IF yr_label IS NULL OR short_n IS NULL THEN
            ins_id := rec.ins_id; insname := rec.insname; inscode := rec.inscode;
            inshortname := rec.inshortname; inslogo := rec.inslogo; activestatus := rec.activestatus;
            student_count := 0; total_demand := 0; total_collected := 0; total_pending := 0;
            pending_approval := 0; today_collected := 0;
            RETURN NEXT; CONTINUE;
        END IF;
        schema_n := short_n || replace(yr_label, '-', '');

        IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = schema_n) THEN
            ins_id := rec.ins_id; insname := rec.insname; inscode := rec.inscode;
            inshortname := rec.inshortname; inslogo := rec.inslogo; activestatus := rec.activestatus;
            student_count := 0; total_demand := 0; total_collected := 0; total_pending := 0;
            pending_approval := 0; today_collected := 0;
            RETURN NEXT; CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)), 0)
            FROM   %1$I.payment p
            JOIN   %1$I.paymentdetails pd ON pd.pay_id = p.pay_id
            JOIN   %1$I.feedemand fd ON fd.dem_id = pd.dem_id
            JOIN   %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
            WHERE  p.ins_id = %2$L AND p.activestatus = 1 AND p.paystatus = 'C'
              AND  p.recon_status = 'P' AND fd.activestatus = 1
        $q$, schema_n, rec.ins_id)
        INTO pending_a;

        EXECUTE format($q$
            SELECT
                COALESCE(SUM(fd.feeamount), 0),
                COALESCE(SUM(fd.balancedue), 0) + %3$L::numeric,
                COALESCE(SUM(fd.feeamount), 0) - (COALESCE(SUM(fd.balancedue), 0) + %3$L::numeric)
            FROM %1$I.feedemand fd
            JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
            WHERE fd.ins_id = %2$L AND fd.activestatus = 1
        $q$, schema_n, rec.ins_id, pending_a)
        INTO demand, pending, collected;

        -- recon_status='R' only: Today Collection counts RECONCILED money (cash
        -- auto-reconciles). Unreconciled payments are Pending Approval, not
        -- collection — matches the institution dashboard's Today Collection.
        EXECUTE format($q$
            SELECT COALESCE(SUM(transtotalamount), 0)
            FROM %1$I.payment
            WHERE ins_id = %2$L AND activestatus = 1 AND paystatus = 'C'
              AND recon_status = 'R'
              AND paydate >= CURRENT_DATE AND paydate < CURRENT_DATE + 1
        $q$, schema_n, rec.ins_id)
        INTO today_c;

        EXECUTE format($q$
            SELECT COUNT(*) FROM %I.students WHERE ins_id = %L AND activestatus = 1
        $q$, schema_n, rec.ins_id)
        INTO stu_cnt;

        ins_id := rec.ins_id; insname := rec.insname; inscode := rec.inscode;
        inshortname := rec.inshortname; inslogo := rec.inslogo; activestatus := rec.activestatus;
        student_count := stu_cnt; total_demand := demand; total_collected := collected;
        total_pending := pending; pending_approval := pending_a; today_collected := today_c;
        RETURN NEXT;
    END LOOP;
END $function$;



-- ------------------------------------------------------------- VERIFY ------
-- 1. AFTER, side by side. All three pairs must now match exactly.
SELECT 'AFTER' AS state,
       (e->>'insname')               AS institution,
       (e->>'total_demand')::numeric AS sa_demand,
       (public.get_fee_totals((e->>'ins_id')::int)->>'total_demand')::numeric AS admin_demand,
       (e->>'total_demand')::numeric
         = (public.get_fee_totals((e->>'ins_id')::int)->>'total_demand')::numeric  AS demand_matches,
       (e->>'total_collected')::numeric
         = (public.get_fee_totals((e->>'ins_id')::int)->>'total_paid')::numeric    AS collected_matches,
       (e->>'total_pending')::numeric
         = (public.get_fee_totals((e->>'ins_id')::int)->>'total_pending')::numeric AS pending_matches
  FROM json_array_elements(public.get_super_admin_dashboard(NULL)) e;

-- 2. One line: every institution agrees on all three. Expect true.
SELECT bool_and(
         (e->>'total_demand')::numeric
           = (public.get_fee_totals((e->>'ins_id')::int)->>'total_demand')::numeric
         AND (e->>'total_collected')::numeric
           = (public.get_fee_totals((e->>'ins_id')::int)->>'total_paid')::numeric
         AND (e->>'total_pending')::numeric
           = (public.get_fee_totals((e->>'ins_id')::int)->>'total_pending')::numeric
       ) AS all_three_match_every_institution
  FROM json_array_elements(public.get_super_admin_dashboard(NULL)) e;

-- 3. v2's Pending Approval must equal what the institution dashboard
--    subtracts from its Collected card. Expect true.
SELECT v.pending_approval = pa.amount AS pending_approval_matches
  FROM public.get_super_admin_dashboard_v2(NULL) v
  JOIN LATERAL (
    SELECT COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)),0) AS amount
      FROM kcet20262027.paymentdetails pd
      JOIN kcet20262027.payment p    ON p.pay_id = pd.pay_id
      JOIN kcet20262027.feedemand fd ON fd.dem_id = pd.dem_id
      JOIN kcet20262027.students s   ON s.stu_id = fd.stu_id AND s.activestatus = 1
     WHERE p.ins_id = v.ins_id AND p.paystatus='C' AND p.recon_status='P'
       AND p.activestatus=1 AND fd.activestatus=1
  ) pa ON TRUE
 WHERE v.ins_id = 1;
