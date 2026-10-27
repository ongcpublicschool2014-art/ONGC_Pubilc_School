-- =====================================================================
-- LIVE RELEASE -- 05-10-2026, WITHOUT THE TIMEZONE CHANGE.
--
-- Use this one on a day the DESKTOP APP IS NOT BEING UPDATED.
--
-- The timezone migration and the desktop build are a PAIR and must ship
-- together. Once live stores IST, the installed 0.0.10 parses paydate without
-- .toLocal(), so DateTime.parse normalises the +05:30 offset to UTC and any
-- payment taken between midnight and 05:30 IST disappears from the
-- Transactions screen -- fetched, then silently dropped by the date filter.
-- Daily Collection and the money are unaffected; it is that one screen, and it
-- is the screen people check during the day.
--
-- So PART 2 is not merely skipped here, it is absent. Half-applying it is the
-- failure mode worth designing against: the settings would say IST while the
-- data stayed UTC, and every new row would be stamped against the wrong clock.
--
-- WHAT IS LEFT needs no new client and touches no stored data:
--
--   PART 1  paytm_mid_for_routing -- removing a bank account must not strand
--           money already in flight under it.
--   PART 3  An advance is numbered from its fee group; the separate ADVNO
--           series is gone. This FIXES a live failure rather than changing
--           behaviour: student and mess advances are currently refused with
--           "No Advance No sequence configured" because no ADVNO sequence
--           exists. The old app will simply start working.
--   PART 4  fee_health_check gains a tenth check -- a demand that bills
--           nothing but has money against it.
--   PART 5  Closes the four misc refusals that were never real.
--
-- NO GATE, AND IT DOES NOT NEED THE COUNTER CLOSED. Nothing here moves data.
-- Parts 1 and 3 are CREATE OR REPLACE on functions, which Postgres applies
-- transactionally -- a collection already running finishes on the old
-- definition. Part 5 touches only the refusal log.
--
-- Rehearsed on TEST 05-10-2026 against a fresh restore of live.
--
-- Idempotent. NO BEGIN/COMMIT: each block is atomic on its own, and a wrapping
-- BEGIN in the Supabase editor is rolled back while looking like it ran.
--
-- STILL OUTSTANDING after this, deliberately:
--   * the timezone migration + the desktop build, together
--   * supabase functions deploy paytm-webhook  (misc/advance webhook recovery)
--   * the 22 ECE-II tuition amounts, in Fee Demand
-- =====================================================================


-- =====================================================================
-- PART 1 -- removing a bank must not strand money in flight under it
--
-- paytm_mid_for_routing answers two different questions with one filter:
--
--   by FEE GROUP  -- "where should this NEW payment settle?"
--   by BAN_ID     -- "which merchant SIGNED this order that already exists?"
--
-- Both required b.activestatus = 1. For the first that is right -- new money
-- must never route to a removed account. For the second it is wrong.
--
-- Deleting a bank is a SOFT delete. The moment it happens, every unfinished
-- intent signed with that bank loses its merchant: the lookup returns NULL,
-- the sweep falls back to the INSTITUTION default merchant, and Paytm is asked
-- about an order it never saw under that merchant. The answer is "no record" --
-- correctly treated as UNDECIDED, so nothing is written off, but nothing is
-- ever recovered either. A real capture would sit unreceipted for ever, with
-- no trace but a parent insisting they paid.
--
-- Which merchant signed an order is a HISTORICAL FACT, so that lookup no
-- longer filters activestatus. The fee-group lookup keeps it. The institution
-- scope is untouched -- that is the part doing the isolation.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.paytm_mid_for_routing(
  p_ins_id integer,
  p_fg_id  integer DEFAULT NULL,
  p_ban_id integer DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v_schema text;
  v_mid    text;
BEGIN
  IF p_fg_id IS NULL AND p_ban_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_fg_id IS NOT NULL THEN
    -- WHERE SHOULD NEW MONEY GO? activestatus = 1 kept deliberately: a removed
    -- account must not receive a fresh payment.
    EXECUTE format(
      'SELECT b.paytm_mid
         FROM %I.feegroup g
         JOIN %I.bank b ON b.ban_id = g.ban_id
        WHERE g.fg_id = $1 AND g.ins_id = $2
          AND g.activestatus = 1 AND b.activestatus = 1
        LIMIT 1', v_schema, v_schema)
      INTO v_mid USING p_fg_id, p_ins_id;
  END IF;

  IF (v_mid IS NULL OR trim(v_mid) = '') AND p_ban_id IS NOT NULL THEN
    -- WHO SIGNED THE ORDER THAT ALREADY EXISTS? A historical question, so NO
    -- activestatus filter. Still scoped to the institution.
    EXECUTE format(
      'SELECT b.paytm_mid
         FROM %I.bank b
        WHERE b.ban_id = $1 AND b.ins_id = $2
        LIMIT 1', v_schema, v_schema)
      INTO v_mid USING p_ban_id, p_ins_id;
  END IF;

  -- Empty string means "not configured", same as no row: the caller must fall
  -- back to the institution merchant rather than sign an order with ''.
  RETURN NULLIF(trim(COALESCE(v_mid, '')), '');
END;
$function$;

COMMENT ON FUNCTION public.paytm_mid_for_routing(integer, integer, integer) IS
  'The Paytm merchant a fee group settles to. Exists because <schema>.bank is '
  'invisible to a parent session under RLS, which silently routed every '
  'parent-app payment to the institution default merchant. The ban_id lookup '
  'does NOT filter activestatus: it answers which merchant signed an EXISTING '
  'order, so a since-deleted account must still resolve.';

GRANT EXECUTE ON FUNCTION public.paytm_mid_for_routing(integer, integer, integer)
  TO anon, authenticated;

-- =====================================================================
-- PART 3 -- an advance needs ONE piece of configuration: its fee group
--
-- The three kinds of advance were numbered out of TWO series: admission from
-- the fee group's own sequence (FC26/...), student and mess from a separate
-- ADVNO series (SA26/...), created on a different screen. So mapping an
-- advance to a fee group was not enough, and nothing on the counter said so --
-- the strip checked the FEE GROUP's sequence, went green, and the cashier was
-- refused at Collect with "No Advance No sequence configured", after the
-- amount had been quoted to the student.
--
-- Now every advance is numbered out of the fee group it is routed to, from
-- that group's own running series. FC26/ is already shared by payment, misc
-- and advance, so this follows the series that exists rather than inventing
-- one -- and it joins the same locked counter, which is strictly safer than a
-- second one.
--
-- The routing also now reads the CONFIGURED mapping (Setup -> Utilities ->
-- Advance Settlement) before falling back to matching on names. The client
-- already read that setting; this function matched on names, and the two
-- agreed only because both happened to land on COLLEGE FEES.
--
-- Admission advances are unchanged: the fee types they are itemised against
-- name their own group, which still overrides.
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

-- The session door. The body above is also reached by the Paytm webhook as
-- service_role with no session, so the session check belongs HERE, on the only
-- way in a client has.
CREATE OR REPLACE FUNCTION public.save_advance_collection(p_token text, p_header jsonb, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $wrap$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  RETURN public._save_advance_collection(v_ins, p_header, p_lines);
END; $wrap$;

REVOKE ALL ON FUNCTION public._save_advance_collection(integer, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._save_advance_collection(integer, jsonb, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.save_advance_collection(text, jsonb, jsonb)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- PART 4 -- fee_health_check: a demand that BILLS NOTHING but has money
-- against it.
--
-- Found 05-10-2026 by accident: 22 students in B.E ECE-II / GOVERNMENT QUOTA
-- have TUITION FEE / YEARLY billed ZERO after the 09-09-2026 import, and 13 of
-- them have been paying since July -- Rs 2,55,675 against a bill of nothing.
-- The money is receipted and banked; the BILL is missing, which is why none of
-- the nine money-side checks saw it. With feeamount zero, balancedue is zero,
-- so all 22 read as settled -- including the NINE who have paid nothing.
-- =====================================================================
DO $patch$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname = 'fee_health_check'
                AND p.prosrc LIKE '%bills nothing%') THEN
    RAISE NOTICE 'check 10 already present -- nothing to do';
    RETURN;
  END IF;
  RAISE NOTICE 'adding check 10 to fee_health_check';
END $patch$;

CREATE OR REPLACE FUNCTION public.fee_health_check()
 RETURNS TABLE(ins_id integer, institution text, severity text, check_name text, found bigint, meaning text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$

DECLARE i record; v text; n bigint;

BEGIN

  FOR i IN SELECT ins.ins_id AS id, ins.insname::text AS nm

             FROM public.institution ins

            WHERE ins.activestatus = 1 ORDER BY ins.ins_id

  LOOP

    v := get_institution_schema(i.id);

    IF v IS NULL THEN

      RETURN QUERY SELECT i.id, i.nm, 'ERROR'::text, 'schema'::text, 0::bigint,

                          'this institution has no schema'::text;

      CONTINUE;

    END IF;



    -- 1. Demand credited MORE than its receipts prove. The student looks

    --    settled and cannot be billed: money the college is owed, invisible.

    EXECUTE format($q$

      SELECT count(*) FROM %1$I.feedemand fd

       WHERE fd.activestatus = 1

         AND fd.paidamount > COALESCE(

               (SELECT SUM(pd.transtotalamount) FROM %1$I.paymentdetails pd

                  JOIN %1$I.payment p ON p.pay_id = pd.pay_id

                 WHERE pd.dem_id = fd.dem_id AND p.paynumber IS NOT NULL

                   AND p.paystatus = 'C' AND p.activestatus = 1), 0)

             + COALESCE(

               (SELECT SUM(a.adjustamount) FROM %1$I.advadjustment a

                 WHERE a.dem_id = fd.dem_id AND a.activestatus = 1), 0) + 0.005

    $q$, v) INTO n;

    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'CRITICAL' ELSE 'ok' END,

      'demand credited more than receipts prove', n,

      CASE WHEN n > 0

        THEN 'student appears settled but is not -- dues cannot be collected. '

             'Run FIX_OVERCREDITED_DEMANDS.sql (preview first).'

        ELSE 'every demand matches its receipts' END;



    -- 2. Demand credited LESS than its receipts. The opposite error: money

    --    arrived and the student is still being asked for it.

    EXECUTE format($q$

      SELECT count(*) FROM %1$I.feedemand fd

       WHERE fd.activestatus = 1

         AND fd.paidamount + 0.005 < COALESCE(

               (SELECT SUM(pd.transtotalamount) FROM %1$I.paymentdetails pd

                  JOIN %1$I.payment p ON p.pay_id = pd.pay_id

                 WHERE pd.dem_id = fd.dem_id AND p.paynumber IS NOT NULL

                   AND p.paystatus = 'C' AND p.activestatus = 1), 0)

    $q$, v) INTO n;

    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'CRITICAL' ELSE 'ok' END,

      'demand credited less than receipts prove', n,

      CASE WHEN n > 0

        THEN 'the family paid and is still being billed for it -- check before '

             'anyone chases them'

        ELSE 'no under-credited demands' END;



    -- 3. The same receipt number on more than one receipt.

    EXECUTE format($q$

      SELECT count(*) FROM (

        SELECT paynumber FROM %1$I.payment

         WHERE paynumber IS NOT NULL AND activestatus = 1

         GROUP BY paynumber HAVING count(*) > 1) d

    $q$, v) INTO n;

    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'CRITICAL' ELSE 'ok' END,

      'duplicate receipt numbers', n,

      CASE WHEN n > 0 THEN 'two receipts share a number -- the register is not trustworthy'

           ELSE 'every receipt number is unique' END;



    -- 4. A numbered receipt also marked failed or pending. Money taken, shown

    --    as not taken: this is what under-counted the collection reports.

    EXECUTE format($q$

      SELECT count(*) FROM %1$I.payment

       WHERE paynumber IS NOT NULL AND activestatus = 1 AND paystatus IN ('F','I')

    $q$, v) INTO n;

    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'CRITICAL' ELSE 'ok' END,

      'receipt marked failed or pending', n,

      CASE WHEN n > 0 THEN 'a receipt exists but the payment reads unpaid -- reports under-count'

           ELSE 'no receipted row is marked failed' END;



    -- 5. A receipt whose lines do not add up to it.

    EXECUTE format($q$

      SELECT count(*) FROM %1$I.payment p

       WHERE p.paynumber IS NOT NULL AND p.paystatus = 'C' AND p.activestatus = 1

         AND ABS(p.transtotalamount - COALESCE(

               (SELECT SUM(pd.transtotalamount) FROM %1$I.paymentdetails pd

                 WHERE pd.pay_id = p.pay_id AND pd.activestatus = 1), 0)) > 0.005

    $q$, v) INTO n;

    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,

      'receipt total does not match its lines', n,

      CASE WHEN n > 0 THEN 'the receipt and its breakdown disagree -- one of them is wrong'

           ELSE 'every receipt matches its lines' END;



    -- 6. Payments left unresolved for more than a day. Each is possibly real

    --    money with no receipt. 'I' is recoverable -- but only if somebody looks.

    EXECUTE format($q$

      SELECT count(*) FROM %1$I.payment

       WHERE paystatus = 'I' AND activestatus = 1

         AND createdat < now() - interval '24 hours'

         -- Only attempts that actually REACHED Paytm. A row with no

         -- payorderid never contacted the gateway -- somebody opened the

         -- payment screen and walked away -- so "ask Paytm about each" is

         -- advice that cannot be followed, and it is cleared anyway the next

         -- time that student starts a payment.

         AND COALESCE(length(btrim(payorderid)), 0) > 0

         -- Only attempts that actually REACHED Paytm. A row with no

         -- payorderid never contacted the gateway -- somebody opened the

         -- payment screen and walked away -- so "ask Paytm about each" is

         -- advice that cannot be followed, and it is cleared anyway the next

         -- time that student starts a payment. Leaving it in made the warning

         -- mean two different things, which is how a health check stops being

         -- read.

         AND COALESCE(length(btrim(payorderid)), 0) > 0

    $q$, v) INTO n;

    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,

      'payments unresolved over 24h', n,

      CASE WHEN n > 0 THEN 'ask Paytm about each: captured ones still need a receipt'

           ELSE 'nothing stuck' END;



    -- 7. The receipt register, via the function that counts misc and advance

    --    receipts too -- a payment-only count reports hundreds of false gaps.

    BEGIN

      SELECT count(*) INTO n FROM public.check_receipt_gaps(i.id);

      RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,

        'receipt numbers issued to nothing', n,

        CASE WHEN n > 0 THEN 'run check_receipt_gaps() for the detail'

             ELSE 'the register is continuous' END;

    EXCEPTION WHEN OTHERS THEN

      RETURN QUERY SELECT i.id, i.nm, 'ERROR'::text,

        'receipt numbers issued to nothing'::text, 0::bigint,

        ('check could not run: ' || SQLERRM)::text;

    END;


    -- 8. Captures Paytm confirmed that the database refused to receipt.
    --    Each is money the college HAS, with no receipt against it. The
    --    refusal was right; being invisible was not.
    SELECT count(*) INTO n FROM public.webhook_refusal r
     WHERE r.resolved_at IS NULL AND COALESCE(r.ins_id, i.id) = i.id;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,
      'captures Paytm confirmed but we refused', n,
      CASE WHEN n > 0 THEN 'money received with no receipt -- see public.webhook_refusal'
           ELSE 'no refused captures outstanding' END;


    -- 9. Misc/advance Paytm collections that were started and never
    --    finished. Each is possibly money taken with no receipt -- the
    --    counter may have closed believing it failed.
    SELECT count(*) INTO n FROM public.pending_collection pc
     WHERE pc.ins_id = i.id AND pc.status IN ('I','P')
       AND pc.created_at < now() - interval '2 hours';
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,
      'misc/advance payments never finished', n,
      CASE WHEN n > 0 THEN 'ask Paytm about each: captured ones still need a receipt'
           ELSE 'none outstanding' END;


    -- 10. A demand that bills NOTHING but has money against it.
    --
    --     balancedue is then 0, so the student reads as fully settled, and the
    --     ones who have NOT paid read the same way -- nobody will ever be
    --     chased. Found on 05-10-2026 by accident, while chasing an unrelated
    --     overpayment: 22 students in one class and quota (B.E ECE-II,
    --     GOVERNMENT QUOTA) had TUITION FEE / YEARLY billed zero after a fee
    --     demand import on 09-09-2026, while 13 of them had been paying since
    --     July. Rs 2,55,675 received against a bill of nothing, and roughly
    --     Rs 6.6 lakh of demand simply absent from the year.
    --
    --     The money is not at risk -- it is receipted and banked. The BILL is
    --     wrong, which is why no money-side check caught it.
    EXECUTE format($q$
      SELECT count(*) FROM %1$I.feedemand fd
       WHERE fd.activestatus = 1
         AND COALESCE(fd.feeamount, 0) - COALESCE(fd.conamount, 0) <= 0
         AND COALESCE(fd.paidamount, 0) > 0
    $q$, v) INTO n;
    RETURN QUERY SELECT i.id, i.nm, CASE WHEN n > 0 THEN 'WARNING' ELSE 'ok' END,
      'demand bills nothing but money was taken', n,
      CASE WHEN n > 0
        THEN 'the fee amount is missing, not the money. Set it in Fee Demand -- '
             'until then these students read as settled and cannot be billed.'
        ELSE 'every demand carrying money also carries an amount' END;

  END LOOP;

END; $function$;


NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- PART 5 -- close the four misc refusals that were never real.
--
-- Each is matched against its own pending_collection intent and closed ONLY
-- when that intent is settled WITH a receipt number. A refusal that is
-- genuinely outstanding is left open and reported, not swept away.
--
-- They fired because webhook_find_payment searches <schema>.payment only, so a
-- misc order never matched. The edge function fix stops new ones -- deploy it
-- with `supabase functions deploy paytm-webhook`.
-- =====================================================================
DO $resolve$
DECLARE r record; v_closed int := 0; v_left int := 0;
BEGIN
  FOR r IN
    SELECT w.order_id, w.amount, pc.receipt_no, pc.status
      FROM public.webhook_refusal w
      LEFT JOIN public.pending_collection pc ON pc.order_id = w.order_id
     WHERE w.resolved_at IS NULL
       AND w.reason LIKE '%no record in the database%'
  LOOP
    -- Only close it when the intent says it WAS receipted. "Settled with a
    -- receipt number" is the proof; the refusal's own text is not.
    IF r.status = 'C' AND COALESCE(btrim(r.receipt_no), '') <> '' THEN
      PERFORM public.resolve_webhook_refusal(
        r.order_id, 'SYSTEM',
        'False alarm. webhook_find_payment searches payment only, so a misc '
        'order never matched and was reported as unknown -- but this one was '
        'receipted as ' || r.receipt_no || '. Fixed in the edge function.');
      v_closed := v_closed + 1;
      RAISE NOTICE 'closed % -> receipt %', r.order_id, r.receipt_no;
    ELSE
      v_left := v_left + 1;
      RAISE WARNING 'LEFT OPEN: % (Rs %) has no receipted intent -- this one '
                    'may be real, work it by hand', r.order_id, r.amount;
    END IF;
  END LOOP;

  RAISE NOTICE '% closed, % left open', v_closed, v_left;
END $resolve$;


NOTIFY pgrst, 'reload schema';


-- =====================================================================
-- VERIFY -- one result set, because the Supabase editor shows only the LAST.
--
-- Rows 1-4 must read ok. Row 5 is expected to report 13 -- that is the
-- finding, not a failure. Row 6 confirms the timezone was NOT touched.
-- =====================================================================
SELECT '1. a deleted bank still resolves the order it signed' AS check, '' AS value,
       (SELECT CASE WHEN prosrc LIKE '%WHO SIGNED THE ORDER%' THEN 'ok' ELSE 'FAILED' END
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname='public' AND p.proname='paytm_mid_for_routing') AS state
UNION ALL
SELECT '2. new money still refuses a deleted bank', '',
       (SELECT CASE WHEN prosrc LIKE '%g.activestatus = 1 AND b.activestatus = 1%'
                    THEN 'ok' ELSE 'FAILED' END
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname='public' AND p.proname='paytm_mid_for_routing')
UNION ALL
SELECT '3. the ADVNO requirement is gone', '',
       (SELECT CASE WHEN prosrc LIKE '%No Advance No sequence configured%'
                    THEN 'FAILED - still demands ADVNO' ELSE 'ok' END
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname='public' AND p.proname='_save_advance_collection')
UNION ALL
SELECT '4. refusals outstanding (want 0)',
       (SELECT count(*)::text FROM public.webhook_refusal WHERE resolved_at IS NULL),
       (SELECT CASE WHEN count(*) = 0 THEN 'ok' ELSE 'LOOK' END
          FROM public.webhook_refusal WHERE resolved_at IS NULL)
UNION ALL
SELECT '5. demands billing nothing but holding money',
       (SELECT found::text FROM public.fee_health_check()
         WHERE check_name = 'demand bills nothing but money was taken' LIMIT 1),
       'expected 13 - set the amounts in Fee Demand'
UNION ALL
SELECT '6. timezone deliberately NOT changed by this script',
       current_setting('TimeZone'),
       CASE WHEN current_setting('TimeZone') = 'UTC' THEN 'ok - still UTC as intended'
            ELSE 'LOOK - something else set it' END
 ORDER BY 1;
