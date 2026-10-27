-- ############################################################################
--
--   EduCore360 -- WHERE AN ADVANCE IS BANKED BECOMES CONFIGURATION
--   26-09-2026
--
--   Run the whole file in the SQL editor. Safe on either project.
--
-- ----------------------------------------------------------------------------
-- WHAT WAS WRONG WITH IT
-- ----------------------------------------------------------------------------
-- An advance carries no fee group of its own, so save_advance_collection had to
-- work out which account to bank it into. It did that by MATCHING NAMES:
--
--     'M' mess      a fee type whose name contains MESS, else a fee group
--                   whose name contains HOSTEL
--     'S' student   a fee group whose name contains COLLEGE, else the lowest
--                   fg_id
--     'A' admission the group of the fee types it is itemised against
--
-- Nobody chose that. Rename HOSTEL FEES to "MESS & ACCOMMODATION" and mess
-- advances fall through to the college group -- no error, a correct-looking
-- receipt, and the money in the wrong account. A third unit's fee group could
-- not be routed to at all.
--
-- ----------------------------------------------------------------------------
-- WHAT IT DOES NOW
-- ----------------------------------------------------------------------------
-- Reads public.institution_settings, one key per advance type:
--
--     advance_route_fg_A  ->  fg_id
--     advance_route_fg_S  ->  fg_id
--     advance_route_fg_M  ->  fg_id
--
-- set in the app under Setup -> Utilities -> Advance Settlement. The name
-- matching above is kept as a FALLBACK, so an institution that has configured
-- nothing behaves exactly as it does today.
--
-- Two things the function refuses to trust:
--   * a value that is not digits;
--   * an fg_id that is not a live fee group in THIS year's schema -- fee groups
--     are per schema, and a setting left from another year would bank money
--     against an account that is not this year's.
-- Either way it falls back rather than failing, because an unrouted advance is
-- recoverable and one in the wrong account is an accounting problem.
--
-- An ADMISSION advance still follows its own fee types: they name a group
-- explicitly, which beats a default.
--
-- ----------------------------------------------------------------------------
-- ORDER
-- ----------------------------------------------------------------------------
-- This file replaces save_advance_collection WHOLESALE, from the body deployed
-- on TEST, so it does not matter whether BANK_ROUTING_BY_FEEGROUP.sql has run
-- yet -- for THIS function. That file is still needed for the other two
-- (process_grouped_payment and save_misc_collection) and is still un-run on
-- live.
--
-- Nothing is seeded: with no settings rows the behaviour is unchanged, and the
-- three keys are written by the Utilities screen when someone sets them.
--
-- Safe to re-run: one CREATE OR REPLACE. No advance, payment or demand row is
-- touched.
-- ############################################################################

CREATE OR REPLACE FUNCTION public.save_advance_collection(p_token text, p_header jsonb, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_ins integer; v_schema text; v_inscode varchar(10);
  v_yr_id integer; v_yrlabel varchar(20);
  v_seq_id int; v_cur numeric; v_width int; v_prefix text; v_advno text;
  v_adv_id bigint; v_amount numeric;
  v_paymode text; v_recon char(1);
  v_advtype char(1); v_lines_total numeric; v_line_count integer := 0;
  v_fg_id integer;
  v_route_fg integer; v_ban_id integer; v_route_set text;
  itm RECORD;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_advtype := UPPER(COALESCE(NULLIF(p_header->>'advtype',''), 'S'));
  IF v_advtype NOT IN ('A','S','M') THEN
    RAISE EXCEPTION 'Advance type must be A (admission), S (student) or M (mess)';
  END IF;

  v_amount := COALESCE((p_header->>'transtotalamount')::numeric, 0);

  IF v_advtype = 'A' THEN
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
      RAISE EXCEPTION 'An admission advance needs at least one fee type line';
    END IF;
    SELECT COALESCE(SUM((l->>'amount')::numeric), 0)
      INTO v_lines_total FROM jsonb_array_elements(p_lines) l;
    IF v_lines_total <= 0 THEN
      RAISE EXCEPTION 'The fee type amounts must add up to more than zero';
    END IF;
    -- The header total IS the sum of the lines. Taking the client's figure
    -- would let a receipt and its own breakdown tell different stories.
    v_amount := v_lines_total;
  ELSIF v_amount <= 0 THEN
    RAISE EXCEPTION 'Advance amount must be greater than zero';
  END IF;

  -- Same rule as save_misc_collection: cash never goes to reconciliation --
  -- there is no bank line to match it to, so it is realised the moment it is
  -- taken. Everything else waits for the bank. Hardcoding 'P' parked every
  -- cash advance in Bank Reconciliation forever.
  v_paymode := LOWER(COALESCE(NULLIF(p_header->>'paymethod',''), 'Cash'));
  v_recon   := CASE WHEN v_paymode LIKE '%cash%' THEN 'R' ELSE 'P' END;

  SELECT inscode INTO v_inscode FROM public.institution WHERE ins_id = v_ins;

  -- Year resolved server-side, like the other collection RPCs.
  EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
    INTO v_yr_id, v_yrlabel USING v_ins;

  -- Receipt number. The two types draw from DIFFERENT series.
  --
  --   'A' ADMISSION advance -> the PAYMENT sequence, the same series a fee
  --       receipt comes from (Fee Master -> Payment Sequence). It is collected
  --       fee type by fee type against an admission and later comes off the
  --       bill itself, so what the family is handed reads as a fee receipt. The
  --       fee group comes from the FIRST line, exactly as a collection numbers
  --       its receipt per fee group.
  --
  --   'S' STUDENT advance -> ADVNO (Fee Master -> Advance No), its own series:
  --       money HELD against the student rather than a fee paid, spent later
  --       through an adjustment.
  IF v_advtype = 'A' THEN
    v_fg_id := NULLIF(p_lines->0->>'fg_id', '')::integer;
    IF v_fg_id IS NULL THEN
      -- Older client, or a line saved without its group: resolve it from the
      -- fee type the way adjust_advance does.
      EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft
                       WHERE ft.feedesc = $1 AND ft.activestatus = 1 LIMIT 1', v_schema)
        INTO v_fg_id USING (p_lines->0->>'feetype');
    END IF;

    IF v_fg_id IS NOT NULL THEN
      EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5),
                             COALESCE(NULLIF(seqprefix,''''),
                                      regexp_replace(COALESCE(sequid,''''), ''[0-9]+$'', ''''))
                        FROM %I.sequence
                       WHERE ins_id=$1 AND fg_id=$2 AND activestatus=1
                       ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
        INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins, v_fg_id;
    END IF;
    -- A fee type whose group has no sequence of its own must not cost the
    -- cashier the collection: fall back to the institution's first payment
    -- sequence, which is the only one most colleges have.
    IF v_seq_id IS NULL THEN
      EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5),
                             COALESCE(NULLIF(seqprefix,''''),
                                      regexp_replace(COALESCE(sequid,''''), ''[0-9]+$'', ''''))
                        FROM %I.sequence
                       WHERE ins_id=$1 AND fg_id IS NOT NULL AND activestatus=1
                       ORDER BY fg_id, seq_id LIMIT 1 FOR UPDATE', v_schema)
        INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins;
    END IF;
    IF v_seq_id IS NULL THEN
      RAISE EXCEPTION 'No payment sequence configured. Add one in Fee Master → Payment Sequence first.';
    END IF;
  ELSE
    EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5), COALESCE(seqprefix,'''')
                      FROM %I.sequence
                     WHERE ins_id=$1 AND actname=''ADVNO'' AND activestatus=1
                     ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins;
    IF v_seq_id IS NULL THEN
      RAISE EXCEPTION 'No Advance No sequence configured. Add one in Fee Master → Advance No first.';
    END IF;
  END IF;
  v_cur := v_cur + 1;
  v_advno := v_prefix || lpad(v_cur::bigint::text, v_width, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_cur, v_seq_id;

  -- WHICH ACCOUNT THIS ADVANCE BELONGS IN
  --
  --   'M' mess     -> the HOSTEL group: the one that owns a MESS fee type,
  --                   falling back to a group named like a hostel.
  --   'A' admission -> the group of the fee types it was itemised against,
  --                   which is already resolved above for the receipt number.
  --   'S' student  -> the COLLEGE group, falling back to the lowest fg_id,
  --                   which is the college group on every database so far.
  --
  -- Resolved SERVER-SIDE from the fee group, never taken from the client, so a
  -- cashier cannot send somebody else's account. If nothing resolves, ban_id
  -- stays NULL -- unrouted money is recoverable, money in the wrong account is
  -- an accounting problem.
  -- CONFIGURED, not guessed. public.institution_settings holds one key per
  -- advance type,
  --     advance_route_fg_A / advance_route_fg_S / advance_route_fg_M  ->  fg_id
  -- set in Setup -> Utilities -> Advance Settlement. Name matching (a fee type
  -- called MESS, a group called HOSTEL or COLLEGE) is kept BELOW as a fallback
  -- for an institution that has not configured it, so nothing changes for one
  -- that has not -- but a group called "MESS & ACCOMMODATION" or a third unit's
  -- group can now be routed to, which name matching could not do.
  v_route_fg := NULL;
  SELECT NULLIF(TRIM(s.setting_value), '') INTO v_route_set
    FROM public.institution_settings s
   WHERE s.ins_id = v_ins
     AND s.setting_key = 'advance_route_fg_' || v_advtype;

  -- Digits only, and it must be a live fee group IN THIS YEAR'S SCHEMA. Fee
  -- groups are per schema, so a setting left over from another year would
  -- otherwise bank the money against an account that is not this year's.
  IF v_route_set ~ '^[0-9]+$' THEN
    EXECUTE format('SELECT fg_id FROM %I.feegroup
                     WHERE fg_id = $1 AND ins_id = $2 AND activestatus = 1', v_schema)
      INTO v_route_fg USING v_route_set::int, v_ins;
  END IF;

  -- An admission advance is itemised AGAINST FEE TYPES, and those types name
  -- their own group. That is more specific than any configured default, so it
  -- wins -- the same rule as before.
  IF v_advtype = 'A' AND v_fg_id IS NOT NULL THEN
    v_route_fg := v_fg_id;
  END IF;

  -- ---- fallbacks, unchanged from BANK_ROUTING_BY_FEEGROUP.sql -------------
  IF v_route_fg IS NULL AND v_advtype = 'M' THEN
    EXECUTE format('SELECT ft.fg_id FROM %I.feetype ft
                     WHERE ft.activestatus = 1 AND ft.feedesc ILIKE ''%%MESS%%''
                     ORDER BY ft.fg_id LIMIT 1', v_schema) INTO v_route_fg;
    IF v_route_fg IS NULL THEN
      EXECUTE format('SELECT fg_id FROM %I.feegroup
                       WHERE ins_id = $1 AND activestatus = 1
                         AND fgdesc ILIKE ''%%HOSTEL%%'' ORDER BY fg_id LIMIT 1', v_schema)
        INTO v_route_fg USING v_ins;
    END IF;
  END IF;
  IF v_route_fg IS NULL THEN
    EXECUTE format('SELECT fg_id FROM %I.feegroup
                     WHERE ins_id = $1 AND activestatus = 1
                       AND fgdesc ILIKE ''%%COLLEGE%%'' ORDER BY fg_id LIMIT 1', v_schema)
      INTO v_route_fg USING v_ins;
  END IF;
  IF v_route_fg IS NULL THEN
    EXECUTE format('SELECT fg_id FROM %I.feegroup
                     WHERE ins_id = $1 AND activestatus = 1 ORDER BY fg_id LIMIT 1', v_schema)
      INTO v_route_fg USING v_ins;
  END IF;
  IF v_route_fg IS NOT NULL THEN
    EXECUTE format('SELECT ban_id FROM %I.feegroup WHERE fg_id = $1', v_schema)
      INTO v_ban_id USING v_route_fg;
  END IF;

  EXECUTE format($i$
    INSERT INTO %I.advance_collection
      (ins_id, inscode, stu_id, stuadmno, stuname, stuclass, courname, yr_id, yrlabel,
       advno, advdate, advtype, transtotalamount, paystatus, paymethod, payreference,
       payorderid, paytm_txnid, paychequeno, paychequedate, paybankname, ban_id,
       tender_amount, remarks, createdby, recon_status)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,
            $10, COALESCE($11::timestamp, now()), $12, $13, 'C', $14, $15,
            $16, $17, $18, $19, $20, $21,
            $22, $23, $24, $25)
    RETURNING adv_id$i$, v_schema)
  INTO v_adv_id
  USING v_ins, v_inscode,
        (p_header->>'stu_id')::bigint, p_header->>'stuadmno', p_header->>'stuname',
        p_header->>'stuclass', p_header->>'courname', v_yr_id, v_yrlabel,
        v_advno, NULLIF(p_header->>'advdate','')::timestamp, v_advtype, v_amount,
        p_header->>'paymethod', p_header->>'payreference',
        p_header->>'payorderid', p_header->>'paytm_txnid',
        p_header->>'paychequeno', NULLIF(p_header->>'paychequedate','')::date,
        p_header->>'paybankname', v_ban_id,
        NULLIF(p_header->>'tender_amount','')::numeric, p_header->>'remarks',
        p_header->>'createdby', v_recon;

  -- Fee-type breakdown: admission advances only.
  IF v_advtype = 'A' THEN
    FOR itm IN
      SELECT NULLIF(l->>'fee_id','')::integer  AS fee_id,
             NULLIF(l->>'fg_id','')::integer   AS fg_id,
             l->>'feetype'                     AS feetype,
             COALESCE((l->>'amount')::numeric, 0) AS amount
        FROM jsonb_array_elements(p_lines) l
    LOOP
      CONTINUE WHEN itm.amount <= 0 OR COALESCE(trim(itm.feetype), '') = '';
      EXECUTE format('INSERT INTO %I.advance_detail (adv_id, ins_id, fee_id, fg_id, feetype, amount)
                      VALUES ($1,$2,$3,$4,$5,$6)', v_schema)
        USING v_adv_id, v_ins, itm.fee_id, itm.fg_id, itm.feetype, itm.amount;
      v_line_count := v_line_count + 1;
    END LOOP;
    IF v_line_count = 0 THEN
      RAISE EXCEPTION 'An admission advance needs at least one fee type line with an amount';
    END IF;
  END IF;

  RETURN jsonb_build_object('adv_id', v_adv_id, 'advno', v_advno, 'amount', v_amount,
                            'advtype', v_advtype, 'lines', v_line_count,
                            'recon_status', v_recon,
                            'fg_id', v_route_fg, 'ban_id', v_ban_id);
END; $function$;


-- ----------------------------------------------------------------------------
-- VERIFY
-- ----------------------------------------------------------------------------
-- 1 = the function now reads the setting, 0 = the old build is still deployed.
SELECT 'reads advance_route_fg_*' AS what,
       count(*)::text AS value
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'save_advance_collection'
   AND pg_get_functiondef(p.oid) LIKE '%advance_route_fg_%'

UNION ALL
-- What is configured today (no rows = every type still name-matched).
SELECT 'configured: ' || s.setting_key,
       s.setting_value
  FROM public.institution_settings s
 WHERE s.setting_key LIKE 'advance_route_fg_%'
 ORDER BY 1;
