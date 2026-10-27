-- ============================================================================
-- Misc Collection must number its receipt from its OWN fee group's series.
-- ============================================================================
-- WHAT WENT WRONG. A Misc Collection of DOBHI (a HOSTEL FEES fee type) for
-- Rs 100 was saved as receipt FC26/03926 -- the COLLEGE FEES series. The money
-- was routed correctly: the row carries ban_id = 2, the hostel account. Only
-- the NUMBER came from the wrong book.
--
-- THE CAUSE, in save_misc_collection:
--
--     -- Receipt number from the SHARED fee-collection sequence ...
--     SELECT seq_id, seqcurno, sequid, seqwidth FROM <schema>.sequence
--      WHERE ins_id=$1 AND activestatus=1 ORDER BY seq_id LIMIT 1 FOR UPDATE
--
-- No fg_id filter, so it always took seq_id 1 -- COLLEGE FEES. Worse, it ran
-- BEFORE the fee group was resolved (that happens ~40 lines later), so the
-- number could not have been group-aware even in principle.
--
-- Two consequences beyond the wrong prefix:
--   * the COLLEGE FEES counter was advanced by hostel collections, so the
--     college series has gaps it cannot account for;
--   * seq_id 1 being a receipt series at all was luck. DEMNO (DE26/) and TCNO
--     are in the same table with fg_id NULL; had either sorted first, misc
--     receipts would have been numbered out of the demand or TC series.
--
-- THE FIX. Resolve the fee group first, then draw from THAT group's sequence.
-- If the group has no sequence, REFUSE -- the same rule
-- save_advance_collection follows, and the one the Advance Collection routing
-- strip already warns about before money is taken. Borrowing another group's
-- run corrupts both books and cannot be unpicked afterwards.
--
-- Everything else in the function is byte-for-byte unchanged: this was built
-- by transforming the deployed definition, not by retyping it, so the insert
-- column list and its 27 placeholders cannot have drifted.
--
-- BEFORE YOU RUN IT, check every group that can receive a misc collection has
-- a sequence -- otherwise collections that used to succeed (wrongly) will now
-- be refused (rightly). tools/feegroup_receipts.sql query 4 lists them.
--
-- Do NOT wrap in BEGIN -- the Supabase editor rolls that back silently.
-- ============================================================================

-- =================================================================== PART 0 =
-- REFUSES TO INSTALL if any active fee group has no receipt sequence.
--
-- After this change a group without a sequence cannot take a misc collection
-- at all -- it is refused instead of being numbered out of another group's
-- run. That is the point, but it would stop the counter mid-day if a group
-- were missing one. So the install checks first and raises, and because the
-- Supabase editor runs the whole script as one batch, a raise here means the
-- function below is NOT replaced. Nothing is half-applied.
--
-- Fix whatever it names (Setup > Sequence Master) and run the script again.
-- ===========================================================================

DO $guard$
DECLARE r record; bad text := ''; n int := 0;
BEGIN
  FOR r IN
    SELECT table_schema AS sch
      FROM information_schema.tables
     WHERE table_name = 'feegroup'
       AND table_schema NOT IN ('public', 'pg_catalog', 'information_schema')
       AND table_schema NOT LIKE 'pg_%'
  LOOP
    FOR r IN EXECUTE format(
      'SELECT %L AS sch, fg.fg_id, fg.fgdesc
         FROM %I.feegroup fg
        WHERE fg.activestatus = 1
          AND NOT EXISTS (SELECT 1 FROM %I.sequence s
                           WHERE s.fg_id = fg.fg_id AND s.activestatus = 1)
        ORDER BY fg.fg_id', r.sch, r.sch, r.sch)
    LOOP
      bad := bad || format('%s  fg_id %s  %s', chr(10), r.fg_id, r.fgdesc)
                 || ' (' || r.sch || ')';
      n := n + 1;
    END LOOP;
  END LOOP;
  IF n > 0 THEN
    RAISE EXCEPTION 'NOT INSTALLED. % fee group(s) have no receipt sequence, '
      'and a misc collection against them would now be REFUSED:%',
      n,
      bad || chr(10) || chr(10)
          || 'Add a sequence for each in Setup > Sequence Master, '
          || 'then run this script again.';
  END IF;
  RAISE NOTICE 'PART 0 ok: every active fee group has a receipt sequence.';
END
$guard$;


-- =================================================================== PART 1 =
-- The function itself.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.save_misc_collection(p_ins_id integer, p_header jsonb, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_schema text; v_mc_id bigint; v_total numeric; v_mcno text;
  v_route_fg integer; v_ban_id integer; v_fg_name text;
  v_seq_id int; v_cur int; v_sequid text; v_width int; v_prefix text;
  v_yr_id int; v_yrlabel text; itm jsonb;
  v_paymode text; v_recon char(1);
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', p_ins_id; END IF;
  -- Year: fall back to the institution's current year when the client sends none.
  v_yr_id   := NULLIF(p_header->>'yr_id','')::int;
  v_yrlabel := NULLIF(p_header->>'yrlabel','');
  IF v_yr_id IS NULL OR v_yrlabel IS NULL THEN
    EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1
                    ORDER BY yr_id DESC LIMIT 1', v_schema)
      INTO v_yr_id, v_yrlabel USING p_ins_id;
  END IF;
  SELECT COALESCE(SUM((x->>'amount')::numeric), 0) INTO v_total FROM jsonb_array_elements(p_lines) x;
  -- WHICH ACCOUNT THIS RECEIPT BELONGS IN -- the fee group of the fee types
  -- actually collected, resolved server-side rather than trusted from the
  -- client. A misc receipt carrying MESS FEE therefore lands in the hostel
  -- account and a BONAFIDE in the college one, without the cashier choosing.
  -- Mixed groups on one receipt take the FIRST line's group; the receipt is a
  -- single document and cannot sit in two accounts.
  EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft
                   WHERE ft.activestatus = 1
                     AND ft.feedesc = ANY ($1) ORDER BY ft.fg_id LIMIT 1', v_schema)
    INTO v_route_fg
    USING ARRAY(SELECT x->>'feetype' FROM jsonb_array_elements(p_lines) x
                 WHERE COALESCE(TRIM(x->>'feetype'), '') <> '');
  IF v_route_fg IS NULL THEN
    EXECUTE format('SELECT fg_id FROM %I.feegroup
                     WHERE ins_id = $1 AND activestatus = 1
                       AND fgdesc ILIKE ''%%COLLEGE%%'' ORDER BY fg_id LIMIT 1', v_schema)
      INTO v_route_fg USING p_ins_id;
  END IF;
  IF v_route_fg IS NOT NULL THEN
    EXECUTE format('SELECT ban_id FROM %I.feegroup WHERE fg_id = $1', v_schema)
      INTO v_ban_id USING v_route_fg;
  END IF;
  -- RECEIPT NUMBER FROM THIS RECEIPT'S OWN GROUP.
  --
  -- It used to read `ORDER BY seq_id LIMIT 1` -- the first active sequence,
  -- whatever it happened to be -- so EVERY misc receipt was numbered from
  -- COLLEGE FEES. A HOSTEL FEES collection of DOBHI Rs 100 came out as
  -- FC26/03926 while banking correctly into the hostel account: right money,
  -- wrong receipt book, and no way to tell afterwards which series it
  -- belonged to. It was also luck that seq_id 1 was a receipt series at all;
  -- had DEMNO sorted first, a misc receipt would have been numbered DE26/.
  --
  -- Numbered AFTER the group is resolved, not before, because the group is
  -- what decides which series to draw from.
  IF v_route_fg IS NOT NULL THEN
    EXECUTE format('SELECT seq_id, seqcurno, sequid, seqwidth FROM %I.sequence
                     WHERE ins_id=$1 AND activestatus=1 AND fg_id=$2
                     ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_cur, v_sequid, v_width USING p_ins_id, v_route_fg;
    IF v_seq_id IS NULL THEN
      -- REFUSE rather than borrow another group's run. This is the same rule
      -- save_advance_collection follows, and the one the Advance Collection
      -- routing strip already warns about before the cashier takes money.
      EXECUTE format('SELECT fgdesc FROM %I.feegroup WHERE fg_id=$1', v_schema)
        INTO v_fg_name USING v_route_fg;
      RAISE EXCEPTION 'No receipt sequence configured for fee group % - add one in Setup > Sequence Master before collecting against it',
        COALESCE(v_fg_name, v_route_fg::text);
    END IF;
  ELSE
    -- No group at all (a fee type in no group, and no COLLEGE group to fall
    -- back to). Nothing better to go on, so the old behaviour stands -- but
    -- fg_id IS NOT NULL keeps it off DEMNO and TCNO, which are not receipt
    -- series and were only ever excluded by luck of ordering.
    EXECUTE format('SELECT seq_id, seqcurno, sequid, seqwidth FROM %I.sequence
                     WHERE ins_id=$1 AND activestatus=1 AND fg_id IS NOT NULL
                     ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_cur, v_sequid, v_width USING p_ins_id;
    IF v_seq_id IS NULL THEN RAISE EXCEPTION 'No receipt sequence configured'; END IF;
  END IF;
  v_cur    := COALESCE(v_cur, 0) + 1;
  v_prefix := regexp_replace(COALESCE(v_sequid, ''), '\d+$', '');
  v_mcno   := v_prefix || lpad(v_cur::bigint::text, COALESCE(v_width, 5)::int, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_cur, v_seq_id;
  -- Cash never goes to reconciliation: there is no bank line to match it to,
  -- which is exactly the rule fee payments already use.
  v_paymode := LOWER(COALESCE(NULLIF(p_header->>'paymode',''), 'Cash'));
  v_recon   := CASE WHEN v_paymode LIKE '%cash%' THEN 'R' ELSE 'P' END;
  EXECUTE format('INSERT INTO %I.misc_collection
      (ins_id,inscode,yr_id,yrlabel,mcno,mcdate,selection,stu_id,regno,stuclass,stuname,courname,
       city,address,paymode,ban_id,bankname,transrefno,draweebank,transdate,transamt,collectedby,remarks,
       totalamount,activestatus,createdby,paytm_txnid,recon_status,reconciled_by,reconciled_date)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,1,$25,$26,
             $27,
             CASE WHEN $27 = ''R'' THEN $22 ELSE NULL END,
             CASE WHEN $27 = ''R'' THEN NOW() ELSE NULL END)
     RETURNING mc_id', v_schema)
    INTO v_mc_id
    USING p_ins_id, p_header->>'inscode', v_yr_id, v_yrlabel,
          v_mcno, COALESCE(NULLIF(p_header->>'mcdate','')::date, CURRENT_DATE),
          COALESCE(NULLIF(p_header->>'selection',''), 'S'), NULLIF(p_header->>'stu_id','')::bigint,
          p_header->>'regno', p_header->>'stuclass', p_header->>'stuname', p_header->>'courname',
          p_header->>'city', p_header->>'address',
          COALESCE(NULLIF(p_header->>'paymode',''), 'Cash'), v_ban_id,
          p_header->>'bankname', p_header->>'transrefno', p_header->>'draweebank',
          NULLIF(p_header->>'transdate','')::date, NULLIF(p_header->>'transamt','')::numeric,
          p_header->>'collectedby', p_header->>'remarks', v_total,
          COALESCE(NULLIF(p_header->>'collectedby',''), 'SYSTEM'),
          NULLIF(p_header->>'paytm_txnid',''),
          v_recon;
  FOR itm IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    CONTINUE WHEN COALESCE(TRIM(itm->>'feetype'), '') = '';
    EXECUTE format('INSERT INTO %I.misc_collection_detail (mc_id,ins_id,fee_id,feetype,amount,activestatus)
        VALUES ($1,$2,$3,$4,$5,1)', v_schema)
      USING v_mc_id, p_ins_id, NULLIF(itm->>'fee_id','')::integer, itm->>'feetype',
            COALESCE(NULLIF(itm->>'amount','')::numeric, 0);
  END LOOP;
  RETURN jsonb_build_object('mc_id', v_mc_id, 'mcno', v_mcno, 'total', v_total,
                            'recon_status', v_recon);
END;
$function$;


-- ------------------------------------------------------------- VERIFY ------
-- 1. Every active fee group needs its own series, or collections against it
--    are now refused. Expect no row saying NO SEQUENCE.
SELECT fg.fg_id, fg.fgdesc,
       s.seqprefix, s.sequid, s.seqcurno,
       CASE WHEN s.seq_id IS NULL THEN 'NO SEQUENCE - misc will be REFUSED'
            ELSE 'ok' END AS state
  FROM kcet20262027.feegroup fg
  LEFT JOIN kcet20262027.sequence s
         ON s.fg_id = fg.fg_id AND s.activestatus = 1
 WHERE fg.activestatus = 1
 ORDER BY fg.fg_id;

-- 2. The function now scopes the lookup by fg_id. Expect true.
SELECT pg_get_functiondef(p.oid) LIKE '%AND fg_id=$2%' AS numbers_by_fee_group
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_misc_collection';
