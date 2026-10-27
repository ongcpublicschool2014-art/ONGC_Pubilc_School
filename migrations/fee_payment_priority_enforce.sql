-- ============================================================================
-- Fee payment priority  (step 2 of 2: server-side enforcement)
--
-- Step 1 added the configuration and a read-only check. This makes it BIND:
-- the same rules now run inside create_pending_payment, so a payment that
-- breaks them is refused before a payment row exists and before the gateway is
-- ever contacted.
--
-- WHY THE SERVER AND NOT THE APP: the mobile app ships with the anon key, so a
-- rule enforced in the cart is a suggestion -- anyone with the key can call the
-- RPC directly. The cart keeps its greying-out for a good experience; this is
-- what actually holds.
--
-- TWO RULES ENFORCED
--   1. ORDER  a demand may be paid only when every LOWER-ranked demand is
--             already clear OR is fully covered by this same payment.
--   2. PARTIAL an amount below the balance is refused when the fee type is
--             configured partialallowed = 'N'.
--
-- RULE 1'S "OR FULLY COVERED" MATTERS. A parent paying Bus + Tuition in one go
-- clears the bus with that very payment, so refusing it would be wrong. But a
-- PART payment of the bus does not clear it, so the tuition stays blocked --
-- otherwise ₹1 of bus would unlock everything behind it.
--
-- SCOPE: THE PARENT APP ONLY. By decision, these rules bind self-service
-- payments and NOT the counter. The admin app never calls this function -- it
-- creates its payment row through insert_payment -- so counter staff continue
-- to collect any fee in any order, for any amount, exactly as before.
--
-- The consequence to be aware of: a parent refused online can pay the same fee
-- at the counter. That is accepted -- the counter is staffed and can judge an
-- exception; the app cannot. If the counter should ever be bound too, it needs
-- an Override Fee Priority permission first, so genuine exceptions stay
-- possible and are recorded.
--
-- SAFE TO RE-RUN.
-- ============================================================================

-- ── 1. The assertion ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assert_fee_payment_allowed(
    p_ins_id  integer,
    p_stu_id  bigint,
    p_details jsonb
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text; bad record;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL OR p_details IS NULL OR jsonb_array_length(p_details) = 0 THEN
    RETURN;
  END IF;

  -- Nothing to enforce on a database where the columns were never added.
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = v AND table_name = 'feetype' AND column_name = 'payseq'
  ) THEN
    RETURN;
  END IF;

  EXECUTE format($q$
    WITH pay AS (
      SELECT (x->>'dem_id')::bigint AS dem_id,
             COALESCE((x->>'amount')::numeric, 0) AS amount
        FROM jsonb_array_elements($2) x
    ),
    d AS (
      SELECT fd.dem_id, fd.demfeetype, fd.balancedue,
             COALESCE(ft.partialallowed, 'Y') AS partialallowed,
             CASE WHEN upper(trim(coalesce(fd.demseqtype,''))) = 'ARREAR'
                  THEN 0 ELSE 1000 END + COALESCE(ft.payseq, 100) AS rank
        FROM %1$I.feedemand fd
        LEFT JOIN %1$I.feetype ft
               ON ft.feedesc = fd.demfeetype AND ft.ins_id = fd.ins_id
                  AND ft.activestatus = 1
       WHERE fd.ins_id = $1 AND fd.stu_id = $3
         AND fd.activestatus = 1 AND fd.balancedue > 0
    )
    SELECT d.demfeetype, d.balancedue, p.amount, d.partialallowed,
           (SELECT string_agg(DISTINCT b.demfeetype, ', ')
              FROM d b
              LEFT JOIN pay bp ON bp.dem_id = b.dem_id
             WHERE b.rank < d.rank
               -- clear, or fully covered by THIS payment
               AND COALESCE(bp.amount, 0) < b.balancedue) AS blockers
      FROM d JOIN pay p ON p.dem_id = d.dem_id
     WHERE
       -- rule 1: something of lower rank is neither clear nor being cleared
       EXISTS (SELECT 1 FROM d b
                 LEFT JOIN pay bp ON bp.dem_id = b.dem_id
                WHERE b.rank < d.rank
                  AND COALESCE(bp.amount, 0) < b.balancedue)
       -- rule 2: a part payment of a fee type that does not allow one
       OR (d.partialallowed = 'N' AND p.amount < d.balancedue)
     LIMIT 1
  $q$, v) INTO bad USING p_ins_id, p_details, p_stu_id;

  IF bad IS NULL THEN RETURN; END IF;

  IF bad.blockers IS NOT NULL THEN
    RAISE EXCEPTION 'Clear % before paying %', bad.blockers, bad.demfeetype
      USING ERRCODE = 'check_violation';
  ELSE
    RAISE EXCEPTION '% must be paid in full (% due, % offered)',
      bad.demfeetype, bad.balancedue, bad.amount
      USING ERRCODE = 'check_violation';
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.assert_fee_payment_allowed(integer, bigint, jsonb) TO anon, authenticated;

-- ── 2. create_pending_payment calls it ──────────────────────────────────────
-- Byte-for-byte the existing function with ONE added line, marked below. It is
-- short and self-contained, so it is replaced in full rather than patched.
CREATE OR REPLACE FUNCTION public.create_pending_payment(
  p_ins_id integer, p_stu_id bigint, p_total numeric,
  p_yr_id integer, p_yrlabel text, p_created_by text,
  p_payitems text, p_details jsonb, p_ban_id integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET statement_timeout = '30s'
AS $$
DECLARE
  v text; v_inscode text; v_pay_id bigint; v_fallback_yr int; v_yr int; it jsonb;
BEGIN
  v := get_institution_schema(p_ins_id);
  IF v IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

  -- ADDED: refuse before any row is written or the gateway is contacted.
  PERFORM public.assert_fee_payment_allowed(p_ins_id, p_stu_id, p_details);

  EXECUTE format('SELECT inscode FROM %I.students WHERE stu_id=$1', v) INTO v_inscode USING p_stu_id;
  EXECUTE format('SELECT yr_id FROM %I.year WHERE activestatus=1 ORDER BY yr_id DESC LIMIT 1', v) INTO v_fallback_yr;
  v_yr := COALESCE(NULLIF(p_yr_id, 0), v_fallback_yr);
  EXECUTE format('DELETE FROM %I.paymentdetails WHERE pay_id IN (SELECT pay_id FROM %I.payment WHERE stu_id=$1 AND paystatus=''I'')', v, v) USING p_stu_id;
  EXECUTE format('DELETE FROM %I.payment WHERE stu_id=$1 AND paystatus=''I''', v) USING p_stu_id;
  EXECUTE format(
    'INSERT INTO %I.payment(ins_id,inscode,stu_id,yr_id,yrlabel,transtotalamount,transcurrency,'
    'paydate,paystatus,recon_status,createdby,payitems,activestatus,ban_id) '
    'VALUES($1,$2,$3,$4,$5,$6,''INR'',now(),''I'',''P'',$7,$8,1,$9) RETURNING pay_id', v)
  INTO v_pay_id USING p_ins_id, v_inscode, p_stu_id, v_yr, p_yrlabel, p_total, p_created_by, p_payitems, p_ban_id;
  FOR it IN SELECT jsonb_array_elements(p_details) LOOP
    EXECUTE format(
      'INSERT INTO %I.paymentdetails(pay_id,dem_id,yr_id,yrlabel,ins_id,transcurrency,transtotalamount,activestatus) '
      'VALUES($1,$2,$3,$4,$5,''INR'',$6,1)', v)
    USING v_pay_id, (it->>'dem_id')::bigint, COALESCE(NULLIF((it->>'yr_id')::int, 0), v_fallback_yr),
          (it->>'yrlabel'), p_ins_id, (it->>'amount')::numeric;
  END LOOP;
  RETURN v_pay_id;
END; $$;
GRANT EXECUTE ON FUNCTION public.create_pending_payment(integer, bigint, numeric, integer, text, text, text, jsonb, integer) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 3. Verify ───────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='assert_fee_payment_allowed') AS assertion_fn,
  (SELECT position('assert_fee_payment_allowed' IN prosrc) > 0 FROM pg_proc p
     JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='create_pending_payment')     AS wired_in;
