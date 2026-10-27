-- ============================================================================
-- Dashboards: Due / Collected / Outstanding are FEE ONLY. Fine stands alone.
-- ============================================================================
-- WHAT WAS WRONG. A fine is not held in a column of its own -- it is added
-- INTO feeamount when it is raised, and fineamount merely records how much of
-- that total is fine:
--
--     BALAMBIKA T   TUITION FEE   feeamount 25,100   fineamount 100
--                                 (every other TUITION FEE is 25,000)
--
-- So the same 100 was inside Total Fees Due, inside Total Collected, AND
-- reported again by the Fine Collected card sitting beside them. Add the
-- cards up and the fine is counted twice.
--
-- get_super_admin_dashboard even says so in its own comments --
-- "Total Collection = fee portion only (subtract fineamount and
-- pending-approval)" -- but the code only ever subtracted pending-approval.
-- The comment described an intention nothing implemented.
--
-- WHAT THIS DOES. Takes the fine out of all three figures, in all four
-- functions, so each card states one thing once:
--
--     Due           fee billed,          no fine
--     Collected     fee money received,  no fine
--     Outstanding   fee still owed,      no fine
--     Fine          the collected fine, on its own
--
-- BOTH HALVES, not one. A fine that has been collected sits in Collected; a
-- fine not yet collected sits in Outstanding. Subtract only the collected
-- half and the cards stop adding up by the rest. So:
--
--     Due         -= every fine on an active demand
--     Collected   -= the collected part
--     Outstanding -= the uncollected part
--
-- "Collected" follows the definition the Fine card already used -- fineamount
-- where paidstatus = 'P' OR paidamount > 0. That is not exact for a demand
-- paid in part, which counts its whole fine as collected; it is kept because
-- it is the split the Fine card has always reported, and inventing a second
-- definition here is how two numbers that should agree come to differ.
--
-- ALL FOUR, not one. get_fee_totals feeds the institution cards,
-- get_fee_totals_by_seqtype the Regular/Arrear drill-down behind them,
-- get_super_admin_dashboard the superadmin cards, _v2 its Pending Approval.
-- Fixing fewer would re-open the split SUPERADMIN_DASHBOARD_ACTIVE_STUDENTS_
-- ONLY.sql just closed.
--
-- NOT TOUCHED: Fine Collected itself, Misc Collection, Today Collection,
-- Concession, transaction and student counts.
--
-- Everything outside the marked edits is byte-for-byte what was on the
-- server: generated from pg_get_functiondef and patched, not retyped.
--
-- Run AFTER DASHBOARD_ACTIVE_STUDENTS_ONLY.sql and
-- SUPERADMIN_DASHBOARD_ACTIVE_STUDENTS_ONLY.sql.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 0 =
-- Before. Keep this output -- the fine is inside demand and inside paid.
-- ===========================================================================

SELECT 'BEFORE' AS state,
       (public.get_fee_totals(1)->>'total_demand')::numeric  AS total_demand,
       (public.get_fee_totals(1)->>'total_paid')::numeric    AS total_paid,
       (public.get_fee_totals(1)->>'total_pending')::numeric AS total_pending,
       (public.get_fee_totals(1)->>'total_fine')::numeric    AS total_fine,
       COALESCE(SUM(fd.fineamount), 0)                       AS fine_on_demands
  FROM kcet20262027.feedemand fd
  JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
 WHERE fd.ins_id = 1 AND fd.activestatus = 1;


-- =================================================================== PART 1 =
-- The institution dashboard cards.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_fee_totals(p_ins_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v text;
  v_total_demand numeric := 0;
  v_total_paid numeric := 0;
  v_total_fine numeric := 0;
  v_total_pending numeric := 0;
  v_pending_approval_fee numeric := 0;
  v_pending_approval_fine numeric := 0;
  -- EVERY fine on an active demand, paid or not. v_total_fine below
  -- is only the collected part, so the two together split the fine
  -- out of Collected and out of Outstanding respectively.
  v_fine_all numeric := 0;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN
    RETURN json_build_object('total_demand',0,'total_pending',0,'total_paid',0,'total_fine',0);
  END IF;

  -- Pending-approval allocations, narrowed to active students for the same
  -- reason as the totals below: a figure subtracted from an active-only total
  -- has to be an active-only figure, or the subtraction takes away money that
  -- was never added.
  EXECUTE format('
    SELECT COALESCE(SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)),0),
           COALESCE(SUM(LEAST(pd.transtotalamount, COALESCE(fd.fineamount,0))),0)
    FROM %1$I.paymentdetails pd
    JOIN %1$I.payment p ON p.pay_id = pd.pay_id
    JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
    JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
    WHERE p.ins_id=$1 AND p.paystatus=''C'' AND p.recon_status=''P'' AND p.activestatus=1
      AND fd.activestatus=1
  ', v) INTO v_pending_approval_fee, v_pending_approval_fine USING p_ins_id;

  -- ACTIVE STUDENTS ONLY. s.activestatus = 1 is exactly what
  -- tc_student_filter('NOTC') produces, which is what every report uses
  -- unless asked for leavers.
  EXECUTE format('
    SELECT COALESCE(SUM(fd.feeamount),0),
           COALESCE(SUM(fd.paidamount),0),
           COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus=''P'' OR fd.paidamount > 0),0),
           COALESCE(SUM(fd.reconbalancedue),0),
           COALESCE(SUM(fd.fineamount),0)
    FROM %1$I.feedemand fd
    JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
    WHERE fd.ins_id=$1 AND fd.activestatus=1
  ', v) INTO v_total_demand, v_total_paid, v_total_fine, v_total_pending, v_fine_all USING p_ins_id;

  -- FEE ONLY. A fine is added INTO feeamount when it is raised -- a 25,000
  -- TUITION FEE with a 100 fine is stored as feeamount 25,100 -- so it was
  -- inside Total Fees Due, inside Total Collected, and reported a third time
  -- by the Fine Collected card beside them.
  --
  -- Taken out of all three, so each card states one thing once:
  --   Due         the fee billed, no fine
  --   Collected   fee money received, no fine
  --   Outstanding fee still owed, no fine
  --   Fine        the fine, collected, on its own
  --
  -- Both halves of the fine have to go, or the cards stop tallying: the
  -- collected part out of Collected, the uncollected part out of Outstanding.
  -- Together they are v_fine_all, which is what comes off Due.
  v_total_demand  := v_total_demand - v_fine_all;
  v_total_pending := v_total_pending - (v_fine_all - v_total_fine);
  -- v_total_fine is still the GROSS collected fine here, which is what has to
  -- come out of paid. Only the fee half of an unreconciled allocation is
  -- subtracted now -- its fine half was never in this figure to begin with.
  v_total_paid := GREATEST(v_total_paid - v_total_fine - v_pending_approval_fee, 0);
  v_total_fine := GREATEST(v_total_fine - v_pending_approval_fine, 0);

  RETURN json_build_object(
    'total_demand',  v_total_demand,
    'total_paid',    v_total_paid,
    'total_pending', v_total_pending,
    'total_fine',    v_total_fine
  );
END; $function$;


-- =================================================================== PART 2 =
-- The Regular / Arrear drill-down behind those cards.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_fee_totals_by_seqtype(p_ins_id integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE v text; r json;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RETURN NULL; END IF;
  EXECUTE format($f$
    WITH pending_alloc AS (
      SELECT pd.dem_id,
             SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount,0), 0)) AS pending_fee,
             SUM(LEAST(pd.transtotalamount, COALESCE(fd.fineamount,0)))       AS pending_fine
      FROM %1$I.paymentdetails pd
      JOIN %1$I.payment p    ON p.pay_id = pd.pay_id
      JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
      JOIN %1$I.students s   ON s.stu_id = fd.stu_id AND s.activestatus = 1
      WHERE p.ins_id=$1 AND p.paystatus='C' AND p.recon_status='P' AND p.activestatus=1
        AND fd.activestatus=1
      GROUP BY pd.dem_id
    ),
    agg AS (
      SELECT CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR'
                  THEN 'arrear' ELSE 'regular' END AS seqtype,
             -- FEE ONLY, the same split get_fee_totals makes -- see the comment
             -- there. The card and this drill-down have to agree, so the two
             -- have to subtract the same thing.
             COALESCE(SUM(fd.feeamount),0)
               - COALESCE(SUM(fd.fineamount),0) AS demand,
             GREATEST(
               COALESCE(SUM(fd.paidamount),0)
                 - COALESCE(SUM(fd.fineamount)
                     FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)
                 - COALESCE(SUM(pa.pending_fee),0), 0) AS paid,
             COALESCE(SUM(fd.reconbalancedue),0)
               - (COALESCE(SUM(fd.fineamount),0)
                  - COALESCE(SUM(fd.fineamount)
                      FILTER (WHERE fd.paidstatus='P' OR fd.paidamount > 0),0)) AS pending
      FROM %1$I.feedemand fd
      JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
      LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
      WHERE fd.ins_id=$1 AND fd.activestatus=1
      GROUP BY 1
    )
    SELECT json_object_agg(seqtype,
             json_build_object('demand', demand, 'paid', paid, 'pending', pending))
    FROM agg
  $f$, v) INTO r USING p_ins_id;
  RETURN COALESCE(r, '{}'::json);
END; $function$;


-- =================================================================== PART 3 =
-- The superadmin cards.
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
  v_fine_all numeric;
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
      EXECUTE format('SELECT COALESCE(SUM(fd.feeamount),0), COALESCE(SUM(fd.paidamount),0), COALESCE(SUM(fd.reconbalancedue),0), COALESCE(SUM(fd.conamount),0), COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus=''P'' OR fd.paidamount > 0),0), COALESCE(SUM(fd.fineamount),0) FROM %1$I.feedemand fd JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1 WHERE fd.ins_id=$1 AND fd.activestatus=1', v_schema)
      INTO v_demand, v_collected, v_pending, v_concession, v_fine, v_fine_all USING rec.ins_id;
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
        -- FEE ONLY -- the identical split get_fee_totals makes, see the
        -- comment there. Order matters: v_fine is still the gross collected
        -- fine on these three lines, and only becomes the net figure for the
        -- Fine card on the last one.
        v_demand    := v_demand - COALESCE(v_fine_all, 0);
        v_pending   := v_pending - (COALESCE(v_fine_all, 0) - v_fine);
        v_collected := GREATEST(v_collected - v_fine - v_pa_fee, 0);
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


-- =================================================================== PART 4 =
-- v2, kept in step with its sibling.
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
            -- FEE ONLY, same split as get_fee_totals. Written as a CTE because
            -- the three figures each need the fine totals and repeating them
            -- inline three times is how a formula comes to differ from itself.
            WITH t AS (
                SELECT COALESCE(SUM(fd.feeamount), 0)  AS fee,
                       COALESCE(SUM(fd.balancedue), 0) AS bal,
                       COALESCE(SUM(fd.fineamount), 0) AS fine_all,
                       COALESCE(SUM(fd.fineamount)
                         FILTER (WHERE fd.paidstatus = 'P' OR fd.paidamount > 0), 0) AS fine_paid
                FROM %1$I.feedemand fd
                JOIN %1$I.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
                WHERE fd.ins_id = %2$L AND fd.activestatus = 1
            )
            SELECT fee - fine_all,
                   (bal - (fine_all - fine_paid)) + %3$L::numeric,
                   (fee - fine_all) - ((bal - (fine_all - fine_paid)) + %3$L::numeric)
            FROM t
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
-- 1. AFTER. total_demand and total_paid must each be lower than the BEFORE
--    row by the fine; total_fine unchanged.
SELECT 'AFTER' AS state,
       (public.get_fee_totals(1)->>'total_demand')::numeric  AS total_demand,
       (public.get_fee_totals(1)->>'total_paid')::numeric    AS total_paid,
       (public.get_fee_totals(1)->>'total_pending')::numeric AS total_pending,
       (public.get_fee_totals(1)->>'total_fine')::numeric    AS total_fine;

-- 2. No fine left anywhere in the three figures. Expect all three true.
WITH f AS (
  SELECT COALESCE(SUM(fd.feeamount), 0)  AS fee,
         COALESCE(SUM(fd.fineamount), 0) AS fine_all,
         COALESCE(SUM(fd.fineamount)
           FILTER (WHERE fd.paidstatus = 'P' OR fd.paidamount > 0), 0) AS fine_paid
    FROM kcet20262027.feedemand fd
    JOIN kcet20262027.students s ON s.stu_id = fd.stu_id AND s.activestatus = 1
   WHERE fd.ins_id = 1 AND fd.activestatus = 1
)
SELECT (public.get_fee_totals(1)->>'total_demand')::numeric = f.fee - f.fine_all
         AS demand_is_fee_only,
       (public.get_fee_totals(1)->>'total_fine')::numeric <= f.fine_paid
         AS fine_card_unchanged,
       f.fine_all > 0 AS there_was_a_fine_to_remove
  FROM f;

-- 3. The card still equals the sum of its drill-down. Expect both true.
SELECT
  (public.get_fee_totals(1)->>'total_demand')::numeric
    = ((public.get_fee_totals_by_seqtype(1)->'regular'->>'demand')::numeric
     + (public.get_fee_totals_by_seqtype(1)->'arrear'->>'demand')::numeric)
      AS demand_agrees,
  (public.get_fee_totals(1)->>'total_pending')::numeric
    = ((public.get_fee_totals_by_seqtype(1)->'regular'->>'pending')::numeric
     + (public.get_fee_totals_by_seqtype(1)->'arrear'->>'pending')::numeric)
      AS pending_agrees;

-- 4. Superadmin still equals institution admin, on all three. Expect true.
SELECT bool_and(
         (e->>'total_demand')::numeric
           = (public.get_fee_totals((e->>'ins_id')::int)->>'total_demand')::numeric
         AND (e->>'total_collected')::numeric
           = (public.get_fee_totals((e->>'ins_id')::int)->>'total_paid')::numeric
         AND (e->>'total_pending')::numeric
           = (public.get_fee_totals((e->>'ins_id')::int)->>'total_pending')::numeric
       ) AS superadmin_matches_institution
  FROM json_array_elements(public.get_super_admin_dashboard(NULL)) e;

-- 5. The cards tally: Due - Collected - Outstanding. Print it; on a database
--    with no concession and no unreconciled FINE this is 0.
SELECT (public.get_fee_totals(1)->>'total_demand')::numeric
         - (public.get_fee_totals(1)->>'total_paid')::numeric
         - (public.get_fee_totals(1)->>'total_pending')::numeric AS tally_gap;
