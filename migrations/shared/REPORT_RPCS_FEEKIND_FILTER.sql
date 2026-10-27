-- ============================================================================
-- The report RPCs also filter by FEE KIND (feetype.type: COL / TRA / HOS).
-- ============================================================================
-- A SECOND AXIS, not a replacement. The fee GROUP says which bank account the
-- money lands in; the KIND says what sort of charge it is. They are genuinely
-- independent -- the HOSTEL FEES group holds COL-typed fees on this database
-- -- so the two filters are ANDed, and either on its own still works.
--
-- Same shape as the group filter added alongside it: a 5th argument,
-- p_fee_kinds text[], null or empty meaning every kind. The 4-, 3- and 2-arg
-- forms all remain and delegate, so an older app build is unaffected.
--
-- MATCHED THROUGH fee_id for the same reason as the group: five fee
-- descriptions exist under two groups each, and the id resolves them.
--
-- Do NOT wrap in BEGIN -- the editor supplies one.
-- ============================================================================



-- ------------------------------------------------- get_pending_payment_report --

CREATE OR REPLACE FUNCTION public.get_pending_payment_report(p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[], p_fee_kinds text[])
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
    -- FEE KIND (feetype.type: COL / TRA / HOS). A SECOND axis, ANDed with
    -- the group above. The group says which bank account the money lands in;
    -- the kind says what sort of charge it is, and a HOSTEL FEES group holds
    -- COL-typed fees on this database, so neither implies the other.
    --
    -- Through fee_id for the same reason as the group: five descriptions
    -- exist under two groups each and only the id resolves them.
    IF p_fee_kinds IS NOT NULL AND array_length(p_fee_kinds, 1) IS NOT NULL THEN
      v_fg := v_fg || format(
        ' AND (CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk'
        '            WHERE ftk.fee_id = fd.fee_id'
        '              AND UPPER(TRIM(COALESCE(ftk.type,''''''''))) = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk2'
        '            WHERE ftk2.activestatus = 1'
        '              AND UPPER(TRIM(ftk2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND UPPER(TRIM(COALESCE(ftk2.type,''''''''))) = ANY(%L))'
        ' END)',
        p_schema, p_fee_kinds, p_schema, p_fee_kinds);
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

CREATE OR REPLACE FUNCTION public.get_pending_payment_report(
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w$
  SELECT public.get_pending_payment_report(p_schema, p_ins_id, p_tc, p_fee_groups, NULL::text[]);
$w$;

GRANT EXECUTE ON FUNCTION public.get_pending_payment_report(text, integer, text, text[], text[])
  TO anon, authenticated;

-- ------------------------------------------------- get_consolidated_status_report --

CREATE OR REPLACE FUNCTION public.get_consolidated_status_report(p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[], p_fee_kinds text[])
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
    -- FEE KIND (feetype.type: COL / TRA / HOS). A SECOND axis, ANDed with
    -- the group above. The group says which bank account the money lands in;
    -- the kind says what sort of charge it is, and a HOSTEL FEES group holds
    -- COL-typed fees on this database, so neither implies the other.
    --
    -- Through fee_id for the same reason as the group: five descriptions
    -- exist under two groups each and only the id resolves them.
    IF p_fee_kinds IS NOT NULL AND array_length(p_fee_kinds, 1) IS NOT NULL THEN
      v_fg := v_fg || format(
        ' AND (CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk'
        '            WHERE ftk.fee_id = fd.fee_id'
        '              AND UPPER(TRIM(COALESCE(ftk.type,''''''''))) = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk2'
        '            WHERE ftk2.activestatus = 1'
        '              AND UPPER(TRIM(ftk2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND UPPER(TRIM(COALESCE(ftk2.type,''''''''))) = ANY(%L))'
        ' END)',
        p_schema, p_fee_kinds, p_schema, p_fee_kinds);
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
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w$
  SELECT public.get_consolidated_status_report(p_schema, p_ins_id, p_tc, p_fee_groups, NULL::text[]);
$w$;

GRANT EXECUTE ON FUNCTION public.get_consolidated_status_report(text, integer, text, text[], text[])
  TO anon, authenticated;

-- ------------------------------------------------- get_pending_details_report --

CREATE OR REPLACE FUNCTION public.get_pending_details_report(p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[], p_fee_kinds text[])
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
    -- FEE KIND (feetype.type: COL / TRA / HOS). A SECOND axis, ANDed with
    -- the group above. The group says which bank account the money lands in;
    -- the kind says what sort of charge it is, and a HOSTEL FEES group holds
    -- COL-typed fees on this database, so neither implies the other.
    --
    -- Through fee_id for the same reason as the group: five descriptions
    -- exist under two groups each and only the id resolves them.
    IF p_fee_kinds IS NOT NULL AND array_length(p_fee_kinds, 1) IS NOT NULL THEN
      v_fg := v_fg || format(
        ' AND (CASE WHEN fd.fee_id IS NOT NULL THEN'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk'
        '            WHERE ftk.fee_id = fd.fee_id'
        '              AND UPPER(TRIM(COALESCE(ftk.type,''''''''))) = ANY(%L))'
        ' ELSE'
        '   EXISTS (SELECT 1 FROM %I.feetype ftk2'
        '            WHERE ftk2.activestatus = 1'
        '              AND UPPER(TRIM(ftk2.feedesc)) = UPPER(TRIM(fd.demfeetype))'
        '              AND UPPER(TRIM(COALESCE(ftk2.type,''''''''))) = ANY(%L))'
        ' END)',
        p_schema, p_fee_kinds, p_schema, p_fee_kinds);
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
  p_schema text, p_ins_id integer, p_tc text, p_fee_groups text[])
RETURNS json LANGUAGE sql SECURITY DEFINER AS $w$
  SELECT public.get_pending_details_report(p_schema, p_ins_id, p_tc, p_fee_groups, NULL::text[]);
$w$;

GRANT EXECUTE ON FUNCTION public.get_pending_details_report(text, integer, text, text[], text[])
  TO anon, authenticated;

-- ------------------------------------------------------------- VERIFY ------
-- 1. Unfiltered is unchanged, for all three. Expect true, true, true.
SELECT
  public.get_pending_payment_report('kcet20262027',1,'NOTC',NULL::text[])::text
    = public.get_pending_payment_report('kcet20262027',1,'NOTC',NULL::text[],NULL::text[])::text
      AS pending_unchanged,
  public.get_consolidated_status_report('kcet20262027',1,'NOTC',NULL::text[])::text
    = public.get_consolidated_status_report('kcet20262027',1,'NOTC',NULL::text[],NULL::text[])::text
      AS conso_unchanged,
  public.get_pending_details_report('kcet20262027',1,'NOTC',NULL::text[])::text
    = public.get_pending_details_report('kcet20262027',1,'NOTC',NULL::text[],NULL::text[])::text
      AS details_unchanged;

-- 2. The kinds partition the whole, and the two reports still agree.
SELECT k AS fee_kind,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_payment_report(
                 'kcet20262027',1,'NOTC',NULL::text[],
                 CASE WHEN k='(ALL)' THEN NULL ELSE ARRAY[k] END)) e) AS pending_payment,
       (SELECT SUM((e->>'pending')::numeric)
          FROM json_array_elements(public.get_pending_details_report(
                 'kcet20262027',1,'NOTC',NULL::text[],
                 CASE WHEN k='(ALL)' THEN NULL ELSE ARRAY[k] END)) e) AS pending_details
  FROM unnest(ARRAY['(ALL)','COL','TRA','HOS']) k
 ORDER BY 1;
