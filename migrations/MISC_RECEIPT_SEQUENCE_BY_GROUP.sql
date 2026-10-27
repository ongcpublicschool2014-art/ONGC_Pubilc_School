-- ############################################################################
--
--   EduCore360 -- A MISC RECEIPT IS NUMBERED BY ITS OWN FEE GROUP
--   26-09-2026
--
--   Run the whole file in the SQL editor. Safe on either project.
--   Run BANK_ROUTING_BY_FEEGROUP.sql first -- this builds on it.
--
-- ----------------------------------------------------------------------------
-- WHAT WAS WRONG
-- ----------------------------------------------------------------------------
-- save_misc_collection took its receipt number from the FIRST sequence in the
-- schema, whatever fee group the money was going to:
--
--     Misc Collection, HOSTEL FEES, MESS FEE 100  ->  receipt FC26/03067
--
-- The money was banked into the hostel account (ban_id follows the fee group,
-- as it has since BANK_ROUTING_BY_FEEGROUP.sql) while the number came out of
-- the COLLEGE run. The receipt and the account disagreed, and the college
-- series gained a number no college money was collected against.
--
-- ----------------------------------------------------------------------------
-- WHAT IT DOES NOW
-- ----------------------------------------------------------------------------
-- The routing decision moves ABOVE the numbering, and the number comes from
-- the routed group's own receipt sequence -- Setup -> Sequence Master ->
-- Receipt Sequence -- exactly as a fee receipt and an advance already do. A
-- mess fee collected here is now HF26/00001, not FC26/03067.
--
-- Nothing else in the function changes: the group is still resolved from the
-- fee types collected, server-side, and a mixed receipt still takes the lowest
-- fg_id, because a receipt is one document and sits in one account.
--
-- ----------------------------------------------------------------------------
-- BEFORE IT WILL COLLECT
-- ----------------------------------------------------------------------------
-- Every fee group collected on this counter needs a receipt sequence. Without
-- one the collection is REFUSED, naming the group -- rather than borrowing
-- another group's series, which is the fault being fixed. On live that means
-- HOSTEL FEES needs its own sequence before a mess fee can be taken there.
--
-- Receipts already issued keep their numbers; nothing is renumbered.
-- Safe to re-run: one CREATE OR REPLACE. No collection row is touched.
-- ############################################################################

CREATE OR REPLACE FUNCTION public.save_misc_collection(p_ins_id integer, p_header jsonb, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_schema text; v_mc_id bigint; v_total numeric; v_mcno text;
  v_route_fg integer; v_ban_id integer;
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


  -- ----------------------------------------------------------------------
  -- RECEIPT NUMBER -- from the group this receipt is banked under
  -- ----------------------------------------------------------------------
  -- It used to come from the FIRST sequence in the schema, whichever group the
  -- money was going to: a MESS FEE collected here was banked into the hostel
  -- account and numbered FC26/03067 out of the college run. The number and the
  -- account have to agree, so the number now comes from the routed group's own
  -- receipt sequence (Setup -> Sequence Master -> Receipt Sequence), exactly as
  -- a fee receipt and an advance already do.
  IF v_route_fg IS NULL THEN
    RAISE EXCEPTION 'This collection has no fee group to be banked under. Check the fee types on it.';
  END IF;

  EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), sequid, COALESCE(seqwidth::int,5)
                    FROM %I.sequence
                   WHERE ins_id=$1 AND fg_id=$2 AND activestatus=1
                   ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
    INTO v_seq_id, v_cur, v_sequid, v_width USING p_ins_id, v_route_fg;

  IF v_seq_id IS NULL THEN
    -- Named: "no receipt sequence" on an institution with several fee groups
    -- is not something the cashier can act on.
    EXECUTE format('SELECT fgdesc FROM %I.feegroup WHERE fg_id=$1', v_schema)
      INTO v_prefix USING v_route_fg;
    RAISE EXCEPTION 'No receipt sequence for "%". Create one in Setup -> Sequence Master -> Receipt Sequence before collecting into it.', COALESCE(v_prefix, 'that fee group');
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


-- ----------------------------------------------------------------------------
-- VERIFY
-- ----------------------------------------------------------------------------
-- reads_group_sequence = 1 is the point of the file. Then one row per fee
-- group: any group collected on the Misc counter that shows NONE will refuse.
SELECT 'numbers from the group sequence' AS what,
       count(*) FILTER (WHERE pg_get_functiondef(p.oid) LIKE '%RECEIPT NUMBER -- from the group%')::text AS value
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname='public' AND p.proname='save_misc_collection'

UNION ALL
SELECT 'receipt sequence: ' || g.fgdesc,
       COALESCE((SELECT s.sequid FROM kcet20262027.sequence s
                  WHERE s.ins_id=g.ins_id AND s.fg_id=g.fg_id AND s.activestatus=1
                  ORDER BY s.seq_id LIMIT 1), 'NONE')
  FROM kcet20262027.feegroup g
 WHERE g.ins_id=1 AND g.activestatus=1
 ORDER BY 1;
