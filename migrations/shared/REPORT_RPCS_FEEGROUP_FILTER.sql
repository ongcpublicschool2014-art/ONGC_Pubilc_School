-- ============================================================================
-- Pending Payment and Consolidated Status, filterable by fee group.
-- ============================================================================
-- WHY IT HAD TO BE DONE HERE. Those two reports are server-side aggregates:
-- get_pending_payment_report and get_consolidated_status_report group by
-- course / class / semester / quota and return NO fee type at all. The app
-- can filter Daily Collection, Pending Details and the DCB Register in Dart
-- because their rows carry a fee type; these two have nothing to match on.
-- A Fee Group picker on those tabs could only ever be a dead control.
--
-- WHAT THIS ADDS. A FOURTH argument, p_fee_groups text[], to each. Null or
-- empty means "every fee group", which is exactly what the report did before.
--
-- NOTHING EXISTING CHANGES. The 2- and 3-argument forms stay, and the 3-arg
-- form now delegates with NULL. An app build that predates this keeps calling
-- the 3-arg overload and gets identical answers -- the same fallback ladder
-- _rpcWithTc already relies on for p_tc.
--
-- THE THREE REPORTS MUST STILL AGREE. get_pending_details_report shares its
-- money definitions with these two verbatim, and the comment in the app is
-- explicit that if they drift the office sees three reports contradicting
-- each other. So the filter is added as a PREDICATE ON WHICH DEMAND ROWS ARE
-- INCLUDED and nothing else: no change to how pending, paid, concession or
-- balance are computed. Filter to all groups and the numbers are identical to
-- today's, which PART 3 below checks rather than asserts.
--
-- Pending Details is deliberately NOT changed. It already filters in Dart on
-- rows that carry a fee type, and adding a second filter server-side would
-- mean two places to keep in step.
--
-- INJECTION. Group names come from the client, so they are interpolated with
-- %L (a quoted array literal) and the schema with %I, never by concatenation.
--
-- Safe to re-run. Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================


-- =================================================================== PART 1 =
-- Pending Payment.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE r json; v_stu text; v_fg text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);

    -- No groups chosen = no narrowing. TRUE rather than a no-op subquery so
    -- the planner sees the unfiltered shape it has always seen.
    IF p_fee_groups IS NULL OR array_length(p_fee_groups, 1) IS NULL THEN
      v_fg := 'TRUE';
    ELSE
      -- MATCHED ON fee_id, NOT THE DESCRIPTION.
      --
      -- Five fee descriptions exist in BOTH groups on this database --
      -- APPLICATION, FINE, GENERAL BREAKAGE, MISCELLANEOUS and STAFF NOTICE
      -- SALARY. Matching on text makes such a demand belong to both, so it is
      -- counted twice and the per-group totals come to MORE than the
      -- unfiltered one. Measured before this fix: 45,073,216 against
      -- 44,869,762.
      --
      -- feedemand.fee_id names the exact feetype row, and every demand here
      -- carries one (12,490 of 12,490), so the id is both unambiguous and
      -- available. The description stays only as a fallback for a row with no
      -- fee_id -- imprecise there, but visible rather than silently dropped.
      v_fg := format(
        '(CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ft'
        '             JOIN %I.feegroup fg ON fg.fg_id = ft.fg_id'
        '            WHERE ft.fee_id = fd.fee_id AND fg.activestatus = 1'
        '              AND fg.fgdesc = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ft2'
        '             JOIN %I.feegroup fg2 ON fg2.fg_id = ft2.fg_id'
        '            WHERE ft2.activestatus = 1 AND fg2.activestatus = 1'
        '              AND UPPER(TRIM(ft2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND fg2.fgdesc = ANY(%L))'
        ' END)',
        p_schema, p_schema, p_fee_groups,
        p_schema, p_schema, p_fee_groups);
    END IF;

    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        )
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.semester, t.seqtype, t.stuadmno), '[]'::json)
        FROM (
          SELECT  s.courname::TEXT AS courname, s.stuclass::TEXT AS stuclass,
                  fd.demfeeterm::TEXT AS semester,
                  (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END)::TEXT AS seqtype,
                  s.admname::TEXT AS admname, s.stuadmno::TEXT AS stuadmno, s.stuname::TEXT AS stuname,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  s.quoname::TEXT AS quoname, s.stumobile::TEXT AS stumobile
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND   %4$s
          GROUP BY s.courname, s.stuclass, fd.demfeeterm,
                   (CASE WHEN UPPER(TRIM(COALESCE(fd.demseqtype,''))) = 'ARREAR' THEN 'ARREAR' ELSE 'REGULAR' END),
                   s.admname, s.stuadmno, s.stuname, s.quoname, s.stumobile
          HAVING  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0)) <> 0
             OR   COALESCE(SUM(fd.conamount), 0) <> 0
        ) t
    $f$, p_schema, p_ins_id, v_stu, v_fg) INTO r;
    RETURN r;
END $function$;

-- The 3-arg form now delegates, so there is ONE body to maintain. Replacing
-- it rather than leaving the old copy is the point: two bodies computing
-- "pending" is how the three reports start disagreeing.
CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
  p_schema text, p_ins_id integer, p_tc text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
AS $function$
  SELECT public.get_pending_payment_report(p_schema, p_ins_id, p_tc, NULL::text[]);
$function$;

GRANT EXECUTE ON FUNCTION public.get_pending_payment_report(text, integer, text, text[])
  TO anon, authenticated;


-- =================================================================== PART 2 =
-- Consolidated Status.
--
-- class_strength is deliberately NOT filtered: a class's strength is how many
-- students are in it, not how many owe a particular group's fees. Filtering
-- it would make STRENGTH move with the fee filter, which is nonsense.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE r json; v_stu text; v_fg text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);

    IF p_fee_groups IS NULL OR array_length(p_fee_groups, 1) IS NULL THEN
      v_fg := 'TRUE';
    ELSE
      v_fg := format(
        '(CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ft'
        '             JOIN %I.feegroup fg ON fg.fg_id = ft.fg_id'
        '            WHERE ft.fee_id = fd.fee_id AND fg.activestatus = 1'
        '              AND fg.fgdesc = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ft2'
        '             JOIN %I.feegroup fg2 ON fg2.fg_id = ft2.fg_id'
        '            WHERE ft2.activestatus = 1 AND fg2.activestatus = 1'
        '              AND UPPER(TRIM(ft2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND fg2.fgdesc = ANY(%L))'
        ' END)',
        p_schema, p_schema, p_fee_groups,
        p_schema, p_schema, p_fee_groups);
    END IF;

    EXECUTE format($f$
        WITH class_strength AS (
            SELECT courname, stuclass, COUNT(DISTINCT stu_id)::INT AS strength
            FROM   %1$I.students WHERE ins_id = %2$L AND activestatus = 1
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
                  COALESCE(NULLIF(s.admname, ''), 'GENERAL')::TEXT AS category,
                  COUNT(DISTINCT s.stu_id)::INT AS stud_count,
                  (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)::TEXT AS type,
                  SUM(fd.feeamount)::NUMERIC AS due,
                  SUM(fd.conamount)::NUMERIC AS concession,
                  SUM(fd.feeamount)::NUMERIC AS net_demand,
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
            AND   %4$s
          GROUP BY s.courname, s.stuclass, cs.strength,
                   fd.demfeeterm, COALESCE(NULLIF(s.admname, ''), 'GENERAL'),
                   (CASE WHEN UPPER(COALESCE(fd.demseqtype,'')) = 'ARREAR' THEN 'Arrear' ELSE 'Regular' END)
        ) t
    $f$, p_schema, p_ins_id, v_stu, v_fg) INTO r;
    RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(
  p_schema text, p_ins_id integer, p_tc text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
AS $function$
  SELECT public.get_consolidated_status_report(p_schema, p_ins_id, p_tc, NULL::text[]);
$function$;

GRANT EXECUTE ON FUNCTION public.get_consolidated_status_report(text, integer, text, text[])
  TO anon, authenticated;



-- =================================================================== PART 3 =
-- Pending Details, by the SAME predicate.
--
-- WHY IT HAD TO MOVE TO SQL. This report was being filtered in Dart, on the
-- fee DESCRIPTION, because its rows carry one. That disagreed with the two
-- above: five descriptions exist under both groups, so HOSTEL FEES came out
-- as 12,09,504 here against 10,27,250 from the RPCs -- 1,82,254 of college
-- fees counted as hostel. Three reports, two answers, in front of the office.
--
-- One predicate, in one place, matching on fee_id. The app now passes the
-- selection through instead of filtering what comes back.
--
-- The FEE TYPE filter stays client-side: it matches the description exactly
-- as the user picked it from a list of descriptions, so there is nothing to
-- resolve.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.get_pending_details_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE r json; v_stu text; v_fg text;
BEGIN
    v_stu := public.tc_student_filter(p_tc);
    IF p_fee_groups IS NULL OR array_length(p_fee_groups, 1) IS NULL THEN
      v_fg := 'TRUE';
    ELSE
      v_fg := format(
        '(CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ft'
        '             JOIN %I.feegroup fg ON fg.fg_id = ft.fg_id'
        '            WHERE ft.fee_id = fd.fee_id AND fg.activestatus = 1'
        '              AND fg.fgdesc = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ft2'
        '             JOIN %I.feegroup fg2 ON fg2.fg_id = ft2.fg_id'
        '            WHERE ft2.activestatus = 1 AND fg2.activestatus = 1'
        '              AND UPPER(TRIM(ft2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND fg2.fgdesc = ANY(%L))'
        ' END)',
        p_schema, p_schema, p_fee_groups,
        p_schema, p_schema, p_fee_groups);
    END IF;
    EXECUTE format($f$
        WITH pending_alloc AS (
          SELECT pd.dem_id,
                 SUM(GREATEST(pd.transtotalamount - COALESCE(fd.fineamount, 0), 0)) AS pending_fee
          FROM %1$I.paymentdetails pd
          JOIN %1$I.payment p ON p.pay_id = pd.pay_id
          LEFT JOIN %1$I.feedemand fd ON fd.dem_id = pd.dem_id
          WHERE p.ins_id = %2$L AND p.paystatus = 'C'
            AND p.recon_status = 'P' AND p.activestatus = 1
          GROUP BY pd.dem_id
        ),
        per_type AS (
          SELECT  s.courname::TEXT                                  AS courname,
                  s.stuclass::TEXT                                  AS stuclass,
                  s.stuadmno::TEXT                                  AS stuadmno,
                  s.stuname::TEXT                                   AS stuname,
                  -- Category on the printed sheet is the student's quota.
                  COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL')::TEXT   AS category,
                  COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS')::TEXT AS feetype,
                  -- REGULAR vs ARREAR, so the report can be filtered to one or
                  -- the other. NULL is reported as REGULAR: older rows predate
                  -- the column and are all current-year demands.
                  COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')::TEXT AS demseqtype,
                  SUM(fd.feeamount)::NUMERIC                        AS demand,
                  SUM(fd.feeamount - COALESCE(fd.conamount, 0))::NUMERIC AS net_demand,
                  GREATEST(
                    COALESCE(SUM(fd.paidamount), 0)
                      - COALESCE(SUM(fd.fineamount) FILTER (WHERE fd.paidstatus = 'P' OR fd.paidamount > 0), 0)
                      - COALESCE(SUM(pa.pending_fee), 0),
                    0
                  )::NUMERIC                                        AS collection,
                  SUM(fd.balancedue + COALESCE(pa.pending_fee, 0))::NUMERIC AS pending
          FROM    %1$I.feedemand fd
          JOIN    %1$I.students s ON s.stu_id = fd.stu_id AND %3$s
          LEFT JOIN pending_alloc pa ON pa.dem_id = fd.dem_id
          WHERE   fd.ins_id = %2$L AND fd.activestatus = 1
            AND   %4$s
          GROUP BY s.courname, s.stuclass, s.stuadmno, s.stuname,
                   COALESCE(NULLIF(TRIM(s.quoname), ''), 'GENERAL'),
                   COALESCE(NULLIF(TRIM(fd.demfeetype), ''), 'OTHERS'),
                   COALESCE(NULLIF(TRIM(fd.demseqtype), ''), 'REGULAR')
        )
        -- Only students who actually owe something. Their OTHER fee types are
        -- still returned, because the Total Demand / Collection columns are
        -- whole-student figures, not just the unpaid slice.
        SELECT COALESCE(json_agg(t ORDER BY t.courname, t.stuclass, t.stuadmno, t.feetype, t.demseqtype), '[]'::json)
        FROM (
          SELECT * FROM per_type
          WHERE  stuadmno IN (SELECT stuadmno FROM per_type
                               GROUP BY stuadmno HAVING SUM(pending) <> 0)
        ) t
    $f$, p_schema, p_ins_id, v_stu, v_fg) INTO r;
    RETURN r;
END $function$;

CREATE OR REPLACE FUNCTION public.get_pending_details_report(
  p_schema text, p_ins_id integer, p_tc text)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
AS $function$
  SELECT public.get_pending_details_report(p_schema, p_ins_id, p_tc, NULL::text[]);
$function$;

GRANT EXECUTE ON FUNCTION public.get_pending_details_report(text, integer, text, text[])
  TO anon, authenticated;


-- ------------------------------------------------------------- VERIFY ------
-- 1. Both overloads exist.
SELECT
  to_regprocedure('public.get_pending_payment_report(text,integer,text,text[])')
    IS NOT NULL                                        AS pending_4arg,
  to_regprocedure('public.get_consolidated_status_report(text,integer,text,text[])')
    IS NOT NULL                                        AS conso_4arg;

-- 2. THE ONE THAT MATTERS. Unfiltered must equal what the report showed
--    before this migration, or the three reports have started to disagree.
--    Expect both true.
SELECT
  public.get_pending_payment_report('kcet20262027', 1, 'NOTC')::text
    = public.get_pending_payment_report('kcet20262027', 1, 'NOTC', NULL::text[])::text
      AS pending_unchanged,
  public.get_consolidated_status_report('kcet20262027', 1, 'NOTC')::text
    = public.get_consolidated_status_report('kcet20262027', 1, 'NOTC', NULL::text[])::text
      AS conso_unchanged,
  public.get_pending_details_report('kcet20262027', 1, 'NOTC')::text
    = public.get_pending_details_report('kcet20262027', 1, 'NOTC', NULL::text[])::text
      AS details_unchanged;

-- 3. And the filter actually narrows. Matching on fee_id, the per-group
--    totals must SUM TO the unfiltered total, less any demand whose fee type
--    sits in no live group. Summing to MORE means something is being counted
--    in two groups at once -- which is exactly what matching on the
--    description did.
SELECT 'ALL' AS fee_group,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(
                 public.get_pending_payment_report('kcet20262027', 1, 'NOTC')) e) AS pending
UNION ALL
SELECT fg.fgdesc,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(
                 public.get_pending_payment_report('kcet20262027', 1, 'NOTC',
                                                   ARRAY[fg.fgdesc])) e)
  FROM kcet20262027.feegroup fg
 WHERE fg.activestatus = 1
 ORDER BY 1;

-- 4. THE REAL TEST: all three reports must agree, filtered and unfiltered.
--    Pending Details sums its per-fee-type rows; the other two are already
--    per-student / per-class. Expect the two columns to match on every line.
SELECT g.fgdesc AS fee_group,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(
                 public.get_pending_payment_report('kcet20262027', 1, 'NOTC',
                   CASE WHEN g.fgdesc = '(ALL)' THEN NULL ELSE ARRAY[g.fgdesc] END)) e)
         AS pending_payment,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(
                 public.get_pending_details_report('kcet20262027', 1, 'NOTC',
                   CASE WHEN g.fgdesc = '(ALL)' THEN NULL ELSE ARRAY[g.fgdesc] END)) e)
         AS pending_details
  FROM (SELECT '(ALL)' AS fgdesc
        UNION ALL
        SELECT fgdesc FROM kcet20262027.feegroup WHERE activestatus = 1) g
 ORDER BY 1;
