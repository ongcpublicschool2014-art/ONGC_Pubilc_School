-- =====================================================================
-- An advance needs ONE piece of configuration: its fee group.
--
-- WHAT WAS WRONG. The three kinds of advance were numbered out of TWO series:
--
--   'A' admission      -> the fee group's own sequence  (FC26/...)
--   'S' / 'M' student, -> a separate ADVNO series        (SA26/...)
--       mess              Fee Master -> Advance No
--
-- So mapping the advance to a fee group was not enough. A second, unrelated
-- sequence had to exist, created on a different screen, and nothing on the
-- collection counter said so -- the strip checked the FEE GROUP's sequence,
-- found COLLEGE FEES', went green, and the cashier was refused at Collect:
--
--     "No Advance No sequence configured. Add one in Fee Master -> Advance No"
--
-- after the amount had been quoted to the student. 05-10-2026, mess advance.
--
-- WHAT THIS DOES. Every advance is now numbered out of the fee group it is
-- routed to, from that group's own running series -- the same one its fee
-- receipts come from. One mapping decides both where the money goes and what
-- the receipt is called, and an advance reads continuously with the receipts
-- beside it in the register. FC26/ is already shared by payment, misc and
-- advance, so this follows the series that exists rather than inventing one.
--
-- AND the routing itself now reads the CONFIGURED mapping -- Setup ->
-- Utilities -> Advance Settlement, advance_route_fg_<A|S|M> -- before falling
-- back to matching on fee-type and group names. The client already read that
-- setting; this function matched on names. They agreed only because both
-- happened to land on COLLEGE FEES here. Now the strip's promise and the
-- receipt agree by construction.
--
-- WHAT IS NOT TOUCHED
--   * Admission advances behave exactly as before: the fee types they are
--     itemised against name their own group, which is more specific than any
--     default, so it still overrides.
--   * Numbers already issued from ADVNO (SA26/0001, SA26/0002) keep theirs.
--     Nothing is renumbered. An ADVNO row left in the sequence table is simply
--     never read again.
--   * Amounts, banking, reconciliation status and the advance ledger.
--
-- Built by surgery on the DEPLOYED definition rather than retyped -- the body
-- handles money. Idempotent.
-- =====================================================================

CREATE OR REPLACE FUNCTION public._save_advance_collection(p_ins integer, p_header jsonb, p_lines jsonb DEFAULT NULL::jsonb)
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

  v_route_fg integer; v_ban_id integer;

  itm RECORD;

BEGIN

  -- The institution is given, not derived from a session: this body is also

  -- reached by the Paytm webhook, which runs as service_role with no session.

  -- The SESSION CHECK IS NOT REMOVED -- it moves to the wrapper below, which

  -- is the only door a client can come through.

  v_ins := p_ins;

  IF v_ins IS NULL THEN RAISE EXCEPTION 'No institution'; END IF;

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



  -- ── WHICH ACCOUNT, AND THEREFORE WHICH NUMBER ─────────────────────────
  -- Resolved FIRST now, because the receipt number comes out of this group's
  -- own series (immediately below). The account and the number are one
  -- decision, so they are made in one place.
  --
  -- The CONFIGURED mapping wins: Setup -> Utilities -> Advance Settlement,
  -- stored as advance_route_fg_<A|S|M>. That is the single piece of
  -- configuration an advance needs, and it is exactly what the counter strip
  -- shows before the cashier takes the money. Reading it HERE is what makes
  -- the strip's promise and the receipt agree by construction: previously the
  -- client read this setting while the server matched on fee-type and group
  -- NAMES, and the two agreed only because both happened to land on COLLEGE
  -- FEES on this database.
  --
  -- Only when nothing is configured do the name rules apply:
  --   'M' mess      -> the group owning a MESS fee type, else a HOSTEL group
  --   anything left -> the COLLEGE group, else the lowest fg_id
  --
  -- 'A' admission is itemised against fee types and those name their own
  -- group, which is more specific than any default, so it overrides.
  --
  -- Never taken from the client, so a cashier cannot send somebody else's
  -- account.
  BEGIN
    SELECT NULLIF(btrim(setting_value), '')::integer
      INTO v_route_fg
      FROM public.institution_settings
     WHERE ins_id = v_ins
       AND setting_key = 'advance_route_fg_' || v_advtype;
  EXCEPTION WHEN OTHERS THEN
    -- A setting somebody typed by hand must not cost the collection.
    v_route_fg := NULL;
  END;

  -- A group from another schema, or one since deleted, is ignored rather than
  -- trusted: fee groups are per schema.
  IF v_route_fg IS NOT NULL THEN
    DECLARE v_chk integer;
    BEGIN
      EXECUTE format('SELECT fg_id FROM %I.feegroup
                       WHERE fg_id = $1 AND ins_id = $2 AND activestatus = 1', v_schema)
        INTO v_chk USING v_route_fg, v_ins;
      v_route_fg := v_chk;
    END;
  END IF;

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
      v_route_fg := v_fg_id;
    END IF;
  END IF;

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

  -- ── RECEIPT NUMBER ────────────────────────────────────────────────────
  -- Out of the ROUTED FEE GROUP's own running series -- the same one that
  -- group's fee receipts come from. So one mapping configures both where the
  -- money goes and what the receipt is called, and an advance reads
  -- continuously with the receipts beside it in the register.
  --
  -- This replaces the separate ADVNO series that student and mess advances
  -- used to draw from. That series was a second thing to configure, invisible
  -- from the screen that needed it, and its absence refused the collection
  -- outright -- after the cashier had quoted the amount, because the counter
  -- was checking the fee group's sequence while this function wanted ADVNO.
  --
  -- Numbers already issued from ADVNO (SA26/...) keep theirs. Nothing is
  -- renumbered, and an ADVNO row left in the sequence table is simply unused.
  IF v_route_fg IS NOT NULL THEN
    EXECUTE format('SELECT seq_id, COALESCE(seqcurno,0), COALESCE(seqwidth::int,5),
                           COALESCE(NULLIF(seqprefix,''''),
                                    regexp_replace(COALESCE(sequid,''''), ''[0-9]+$'', ''''))
                      FROM %I.sequence
                     WHERE ins_id=$1 AND fg_id=$2 AND activestatus=1
                     ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_cur, v_width, v_prefix USING v_ins, v_route_fg;
  END IF;
  -- A group with no sequence of its own must not cost the cashier the
  -- collection: fall back to the institution's first payment sequence, which
  -- is the only one most colleges have.
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
    RAISE EXCEPTION 'No receipt sequence configured. Add one in Setup → Sequence Master → Receipt Sequence first.';
  END IF;
  v_cur := v_cur + 1;
  v_advno := v_prefix || lpad(v_cur::bigint::text, v_width, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_cur, v_seq_id;

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


NOTIFY pgrst, 'reload schema';


-- ---------------------------------------------------------------------
-- VERIFY -- all four must read ok.
-- ---------------------------------------------------------------------
SELECT '1. the ADVNO requirement is gone' AS check,
       CASE WHEN p.prosrc LIKE '%No Advance No sequence configured%'
            THEN 'FAILED - still demands ADVNO' ELSE 'ok' END AS state
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = '_save_advance_collection'
UNION ALL
SELECT '2. the configured fee group mapping is read',
       CASE WHEN p.prosrc LIKE '%advance_route_fg_%' THEN 'ok'
            ELSE 'FAILED - still matches on names only' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = '_save_advance_collection'
UNION ALL
SELECT '3. the number comes from the routed group''s sequence',
       CASE WHEN p.prosrc LIKE '%USING v_ins, v_route_fg%' THEN 'ok'
            ELSE 'FAILED' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = '_save_advance_collection'
UNION ALL
SELECT '4. mess advance would now be numbered from',
       COALESCE((SELECT g.fgdesc || ' (' || s.seqprefix || ', next ' ||
                        (COALESCE(s.seqcurno,0) + 1)::text || ')'
                   FROM public.institution_settings st
                   JOIN kcet20262027.feegroup g
                     ON g.fg_id = NULLIF(btrim(st.setting_value), '')::integer
                   JOIN kcet20262027.sequence s
                     ON s.fg_id = g.fg_id AND s.activestatus = 1
                  WHERE st.ins_id = 1 AND st.setting_key = 'advance_route_fg_M'
                  LIMIT 1),
                'NOTHING - map it in Utilities -> Advance Settlement')
 ORDER BY 1;
