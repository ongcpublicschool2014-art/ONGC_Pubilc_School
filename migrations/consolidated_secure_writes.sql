-- ############################################################################
-- CONSOLIDATED session-gated WRITE RPCs (Option B security hardening).
-- Run this whole block once in the Supabase SQL editor. Idempotent & non-
-- breaking (adds functions; revokes NOTHING). Deploy BEFORE phase3a_revoke.
-- ############################################################################

-- ==== secure_app_session.sql ============================================================
-- ============================================================================
-- Phase 0 — Server-issued session tokens (foundation for the write lockdown).
-- ============================================================================
-- The app has no server-side identity today: every request runs as the shared
-- anon role, so RLS can't tell users/institutions apart and grants are wide open
-- (see docs/SECURITY_REVIEW.md). This adds a server-minted session token that
-- later write RPCs will require, deriving ins_id/role SERVER-SIDE from the token
-- instead of trusting a client-supplied p_ins_id.
--
-- Design (mirrors the existing device_activations hashed-code pattern):
--   * Only a SHA-256 HASH of the token is stored; the client holds the raw token.
--   * create_app_session RE-VERIFIES the bcrypt password (scoped to the chosen
--     institution) before minting — a client cannot forge a session for another
--     user by passing a use_id.
--   * session_context(token) validates + returns (use_id, ins_id, ur_id) or
--     RAISEs; write RPCs call it first and use its ins_id.
--   * app_session is REVOKEd from anon/authenticated + RLS-enabled: reachable
--     only through these SECURITY DEFINER functions.
--
-- Additive and non-breaking — nothing calls these yet. Idempotent.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Session store ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.app_session (
  token_hash   text        PRIMARY KEY,          -- sha256(raw token), hex
  use_id       integer     NOT NULL,
  ins_id       integer     NOT NULL,
  ur_id        integer,
  role         text,
  device_id    text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL DEFAULT now() + interval '30 days',
  revoked      boolean     NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS ix_app_session_lookup
  ON public.app_session (token_hash) WHERE NOT revoked;

-- Lock the table away from direct client access (default privileges would have
-- granted anon ALL on this new public table). Access is only via the functions.
REVOKE ALL ON public.app_session FROM anon, authenticated;
ALTER TABLE public.app_session ENABLE ROW LEVEL SECURITY;  -- no policy => no direct rows

-- ── Mint a session (after verifying credentials, scoped to the institution) ──
CREATE OR REPLACE FUNCTION public.create_app_session(
  p_email          text,
  p_plain_password text,
  p_ins_id         integer,
  p_is_super_admin boolean DEFAULT false,
  p_device_id      text    DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_schema text; v_use_id integer; v_ur_id integer; v_urname text; v_ins_id integer; v_token text;
BEGIN
  -- Mirrors public.verify_user_login's proven lookup + bcrypt check, but binds
  -- the result to a session. Identity (use_id, ins_id, role) is taken from the
  -- matched row — never from the client — so a caller can't forge a session.
  IF p_is_super_admin THEN
    -- Super admins log in by username; single public row with inscode='SUPER'.
    SELECT use_id, ur_id, urname, ins_id INTO v_use_id, v_ur_id, v_urname, v_ins_id
    FROM public.institutionusers
    WHERE lower(usename) = lower(p_email) AND inscode = 'SUPER' AND activestatus = 1
      AND usepassword = crypt(p_plain_password, usepassword)
    LIMIT 1;
  ELSE
    -- public.institutionusers first (where the app creates users)...
    SELECT use_id, ur_id, urname, ins_id INTO v_use_id, v_ur_id, v_urname, v_ins_id
    FROM public.institutionusers
    WHERE usemail = p_email AND activestatus = 1
      AND usepassword = crypt(p_plain_password, usepassword)
    LIMIT 1;
    -- ...then the selected institution's schema copy (legacy data).
    IF v_use_id IS NULL THEN
      v_schema := get_institution_schema(p_ins_id);
      IF v_schema IS NOT NULL THEN
        EXECUTE format(
          'SELECT use_id, ur_id, urname, ins_id FROM %I.institutionusers '
          'WHERE usemail = $1 AND activestatus = 1 '
          '  AND usepassword = crypt($2, usepassword) LIMIT 1', v_schema)
        INTO v_use_id, v_ur_id, v_urname, v_ins_id USING p_email, p_plain_password;
      END IF;
    END IF;
  END IF;

  IF v_use_id IS NULL THEN
    RAISE EXCEPTION 'Invalid credentials';
  END IF;

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  INSERT INTO public.app_session(token_hash, use_id, ins_id, ur_id, role, device_id)
  VALUES (encode(digest(v_token, 'sha256'), 'hex'), v_use_id,
          COALESCE(v_ins_id, p_ins_id), v_ur_id, v_urname, p_device_id);
  RETURN v_token;
END; $$;

-- ── Validate a token; return the caller's context (or RAISE) ────────────────
-- Write RPCs call: SELECT ins_id INTO v_ins FROM public.session_context(p_token);
CREATE OR REPLACE FUNCTION public.session_context(p_token text)
RETURNS TABLE(use_id integer, ins_id integer, ur_id integer, role text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE v_hash text; r record;
BEGIN
  IF p_token IS NULL OR length(p_token) < 16 THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  v_hash := encode(digest(p_token, 'sha256'), 'hex');
  SELECT s.use_id, s.ins_id, s.ur_id, s.role INTO r
  FROM public.app_session s
  WHERE s.token_hash = v_hash AND NOT s.revoked AND s.expires_at > now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid or expired session';
  END IF;
  UPDATE public.app_session SET last_seen_at = now() WHERE token_hash = v_hash;
  use_id := r.use_id; ins_id := r.ins_id; ur_id := r.ur_id; role := r.role;
  RETURN NEXT;
END; $$;

-- ── Revoke (logout) ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.revoke_session(p_token text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF p_token IS NULL THEN RETURN; END IF;
  UPDATE public.app_session SET revoked = true
  WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex');
END; $$;

GRANT EXECUTE ON FUNCTION public.create_app_session(text, text, integer, boolean, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.session_context(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_session(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_payments_phase1.sql ============================================================
-- ============================================================================
-- Phase 1a — session-gated wrappers for PAYMENT COMPLETION (money path).
-- ============================================================================
-- Part of the write-lockdown remediation (docs/SECURITY_REVIEW.md, plan
-- buzzing-twirling-turtle). Today the client calls complete_payment_grouped /
-- process_grouped_payment directly with a client-supplied p_ins_id — anyone with
-- the anon key can call them for any institution. These wrappers require a valid
-- session token and derive ins_id SERVER-SIDE from it (via session_context),
-- ignoring any client value, then forward to the existing completion logic.
--
-- ADDITIVE + NON-BREAKING: the raw functions stay callable until the Phase 3
-- REVOKE. The client is rewired to call these *_secure wrappers in Phase 2
-- (only after secure_app_session.sql is run, so a real token exists).
-- Requires: secure_app_session.sql (session_context). Idempotent.
-- ============================================================================

-- Wrapper for complete_payment_grouped (offline/cash + online completion).
CREATE OR REPLACE FUNCTION public.complete_payment_secure(
  p_token         text,
  p_pay_id        bigint,
  p_pay_method    text,
  p_pay_reference text,
  p_items         jsonb,
  p_status        character DEFAULT 'C'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);  -- RAISEs if invalid/expired
  RETURN public.complete_payment_grouped(p_pay_id, p_pay_method, p_pay_reference, p_items, v_ins, p_status);
END; $$;

-- Wrapper for process_grouped_payment (grouped multi-fee-group collection).
CREATE OR REPLACE FUNCTION public.process_grouped_payment_secure(
  p_token         text,
  p_inscode       character varying,
  p_stu_id        bigint,
  p_yr_id         integer,
  p_yrlabel       character varying,
  p_total_amount  numeric,
  p_created_by    character varying,
  p_pay_method    text,
  p_pay_reference text,
  p_items         jsonb,
  p_seq_id        integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);  -- RAISEs if invalid/expired
  -- p_seq_id accepted for forward-compat but NOT forwarded: process_grouped_payment
  -- has no 11th param, so forwarding it fails with "function does not exist".
  RETURN public.process_grouped_payment(v_ins, p_inscode, p_stu_id, p_yr_id, p_yrlabel,
                                        p_total_amount, p_created_by, p_pay_method, p_pay_reference,
                                        p_items);
END; $$;

GRANT EXECUTE ON FUNCTION public.complete_payment_secure(text, bigint, text, text, jsonb, character)
  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_grouped_payment_secure(text, character varying, bigint, integer, character varying, numeric, character varying, text, text, jsonb, integer)
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_feedemand_phase1b.sql ============================================================
-- ============================================================================
-- Phase 1b — session-gated RPCs for feedemand mutations (Group A, money-adjacent).
-- ============================================================================
-- Today the client updates <schema>.feedemand directly (fines, concessions,
-- fee-definition edits) using the anon key — anyone can rewrite balances. These
-- RPCs require a valid session token, derive ins_id SERVER-SIDE from it, and
-- scope every UPDATE to that institution (dem_id AND ins_id). The client rewires
-- to them with a fallback (non-breaking). Requires secure_app_session.sql.
-- Idempotent.
-- ============================================================================

-- Set/clear the fine on one demand (fee-collection flow).
CREATE OR REPLACE FUNCTION public.set_demand_fine(
  p_token text, p_dem_id bigint, p_fineamount numeric
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  EXECUTE format('UPDATE %I.feedemand SET fineamount = $1 WHERE dem_id = $2 AND ins_id = $3', v_schema)
    USING COALESCE(p_fineamount, 0), p_dem_id, v_ins;
END; $$;

-- Apply a concession to one demand (Fee Concession screen).
CREATE OR REPLACE FUNCTION public.apply_concession(
  p_token text, p_dem_id bigint, p_con_id integer, p_conamount numeric, p_balancedue numeric
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  EXECUTE format(
    'UPDATE %I.feedemand SET con_id = $1, conamount = $2, balancedue = $3, reconbalancedue = $3 '
    'WHERE dem_id = $4 AND ins_id = $5', v_schema)
    USING p_con_id, p_conamount, p_balancedue, p_dem_id, v_ins;
END; $$;

-- Save a per-student fee definition (Student Fee Definition dialog). p_balancedue
-- NULL = amount unchanged → do NOT touch the outstanding (preserve payments).
CREATE OR REPLACE FUNCTION public.save_fee_definition(
  p_token text, p_dem_id bigint, p_feeamount numeric, p_collectible boolean,
  p_balancedue numeric DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  IF p_balancedue IS NULL THEN
    EXECUTE format('UPDATE %I.feedemand SET feeamount = $1, collectible = $2 '
                   'WHERE dem_id = $3 AND ins_id = $4', v_schema)
      USING p_feeamount, p_collectible, p_dem_id, v_ins;
  ELSE
    EXECUTE format('UPDATE %I.feedemand SET feeamount = $1, collectible = $2, '
                   'balancedue = $3, reconbalancedue = $3 WHERE dem_id = $4 AND ins_id = $5', v_schema)
      USING p_feeamount, p_collectible, p_balancedue, p_dem_id, v_ins;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.set_demand_fine(text, bigint, numeric) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_concession(text, bigint, integer, numeric, numeric) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_fee_definition(text, bigint, numeric, boolean, numeric) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_reconcile_phase1b.sql ============================================================
-- ============================================================================
-- Phase 1b — session-gated wrapper for bank reconciliation.
-- ============================================================================
-- reconcile_payments_batch is SECURITY INVOKER (runs as the caller), so it only
-- works today thanks to anon's table grants and would BREAK on the Phase 3
-- REVOKE. This DEFINER wrapper validates the session token, derives ins_id +
-- schema server-side, and calls the batch — which then runs with the wrapper's
-- (owner) privileges, so it survives the REVOKE. The client calls the wrapper;
-- reconcile_payments_batch itself will be REVOKEd from anon in Phase 3.
-- Requires secure_app_session.sql. Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reconcile_payments_secure(
  p_token text, p_pay_ids integer[], p_user text,
  p_bank_ref text DEFAULT NULL, p_bank_date text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  RETURN public.reconcile_payments_batch(v_schema, v_ins, p_pay_ids, p_user, p_bank_ref, p_bank_date);
END; $$;

GRANT EXECUTE ON FUNCTION public.reconcile_payments_secure(text, integer[], text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_refund_phase1b.sql ============================================================
-- ============================================================================
-- Phase 1b — session-gated ATOMIC refund (Group A).
-- ============================================================================
-- The client does a refund as 4 separate anon writes (fee_refund header +
-- fee_refunddetails + payment update + per-demand feedemand re-open). This does
-- all of it in ONE SECURITY DEFINER function, gated by the session token, with
-- ins_id derived server-side. p_header/p_lines are the same maps the client
-- built. Returns the new rf_id. Requires secure_app_session.sql. Idempotent def.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_refund(
  p_token text, p_header jsonb, p_lines jsonb
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_rf_id integer; v_pay_id integer;
  v_total_refund numeric; v_existing numeric;
  itm RECORD; v_paid numeric; v_bal numeric; v_recon numeric;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_pay_id := (p_header->>'pay_id')::integer;
  v_total_refund := COALESCE((p_header->>'totalrefund')::numeric, 0);

  -- 1. Refund header (ins_id forced from the session)
  EXECUTE format(
    'INSERT INTO %I.fee_refund(doc_no,ins_id,inscode,yrlabel,refunddate,pay_id,paynumber,stu_id,stuadmno,stuname,stuclass,refundmode,ban_id,bankname,bankref,chequedate,accountcode,refundreason,totalrefund,totaladjust,createdby,activestatus) '
    'VALUES($1,$2,$3,$4,NULLIF($5,'''')::date,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,NULLIF($16,'''')::date,$17,$18,$19,$20,$21,1) RETURNING rf_id', v_schema)
  INTO v_rf_id USING
    (p_header->>'doc_no')::integer, v_ins, p_header->>'inscode', p_header->>'yrlabel', p_header->>'refunddate',
    v_pay_id, p_header->>'paynumber', (p_header->>'stu_id')::bigint, p_header->>'stuadmno', p_header->>'stuname',
    p_header->>'stuclass', p_header->>'refundmode', NULLIF(p_header->>'ban_id','')::integer, p_header->>'bankname',
    p_header->>'bankref', p_header->>'chequedate', p_header->>'accountcode', p_header->>'refundreason',
    v_total_refund, COALESCE((p_header->>'totaladjust')::numeric, 0), p_header->>'createdby';

  -- 2. Detail lines + 4. re-open each refunded demand (money returned = owed again)
  FOR itm IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(
    dem_id bigint, refundterm text, refundfeetype text, feeamount numeric,
    refundamount numeric, adjustamount numeric, adjustreason text)
  LOOP
    EXECUTE format('INSERT INTO %I.fee_refunddetails(rf_id,dem_id,ins_id,refundterm,refundfeetype,feeamount,refundamount,adjustamount,adjustreason,activestatus) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,1)', v_schema)
      USING v_rf_id, itm.dem_id, v_ins, itm.refundterm, itm.refundfeetype, itm.feeamount, itm.refundamount, itm.adjustamount, itm.adjustreason;

    IF COALESCE(itm.refundamount, 0) > 0 THEN
      EXECUTE format('SELECT paidamount, balancedue, reconbalancedue FROM %I.feedemand WHERE dem_id=$1 AND ins_id=$2', v_schema)
        INTO v_paid, v_bal, v_recon USING itm.dem_id, v_ins;
      IF v_paid IS NOT NULL THEN
        EXECUTE format('UPDATE %I.feedemand SET paidamount=$1, balancedue=$2, reconbalancedue=$3, paidstatus=$4 WHERE dem_id=$5 AND ins_id=$6', v_schema)
          USING GREATEST(COALESCE(v_paid,0) - itm.refundamount, 0),
                COALESCE(v_bal,0) + itm.refundamount,
                COALESCE(v_recon, v_bal, 0) + itm.refundamount,
                CASE WHEN COALESCE(v_bal,0) + itm.refundamount > 0 THEN 'U' ELSE 'P' END,
                itm.dem_id, v_ins;
      END IF;
    END IF;
  END LOOP;

  -- 3. Mark the receipt refunded + accumulate refund_amount
  EXECUTE format('SELECT COALESCE(refund_amount,0) FROM %I.payment WHERE pay_id=$1 AND ins_id=$2', v_schema)
    INTO v_existing USING v_pay_id, v_ins;
  EXECUTE format('UPDATE %I.payment SET refund_amount=$1, paystatus=''R'' WHERE pay_id=$2 AND ins_id=$3', v_schema)
    USING COALESCE(v_existing, 0) + v_total_refund, v_pay_id, v_ins;

  RETURN v_rf_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.process_refund(text, jsonb, jsonb) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_feedemand_phase1c.sql ============================================================
-- ============================================================================
-- Phase 1c — the last two non-payment feedemand client writes (Group A).
-- ============================================================================
-- After these, every CLIENT-side write to feedemand goes through a session-gated
-- RPC (set_demand_fine / apply_concession / save_fee_definition / process_refund
-- / reconcile_payments_secure / complete_payment_* + these two). Server-side
-- triggers and the payment RPCs still write feedemand directly, as intended.
--
--  * update_demand_class  — Section Transfer cascades a student's class/course
--                           onto all their demand rows (WHERE stu_id).
--  * rebuild_demand        — Fee Master edit-mode pushes recomputed amounts into
--                           a single demand row (WHERE dem_id).
-- Both derive ins_id/schema server-side. Requires secure_app_session.sql.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_demand_class(
  p_token text, p_stu_id bigint, p_class text, p_courname text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  EXECUTE format(
    'UPDATE %I.feedemand SET stuclass=$1, courname=COALESCE(NULLIF($2,''''), courname) '
    'WHERE stu_id=$3 AND ins_id=$4', v_schema)
  USING p_class, p_courname, p_stu_id, v_ins;
END; $$;

CREATE OR REPLACE FUNCTION public.rebuild_demand(
  p_token text, p_dem_id bigint, p_feeamount numeric, p_balancedue numeric, p_collectible boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  EXECUTE format(
    'UPDATE %I.feedemand SET feeamount=$1, balancedue=$2, reconbalancedue=$2, collectible=$3 '
    'WHERE dem_id=$4 AND ins_id=$5', v_schema)
  USING p_feeamount, p_balancedue, p_collectible, p_dem_id, v_ins;
END; $$;

GRANT EXECUTE ON FUNCTION public.update_demand_class(text, bigint, text, text)             TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rebuild_demand(text, bigint, numeric, numeric, boolean)   TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_payments_phase1d.sql ============================================================
-- ============================================================================
-- Phase 1d — session-gated PAYMENT pre-completion writes (Group A, Paytm-only).
-- ============================================================================
-- These are the payment-row bookkeeping writes AROUND the gateway flow (create
-- the 'I' row, stamp the order id, mark 'F' on failure, record cheque/tender
-- details). The money-critical transition to 'C' (completed) is NOT here — it
-- happens only inside complete_payment_grouped, which re-derives paid amounts
-- from the demands. So update_payment deliberately:
--   * WHITELISTS a fixed set of non-money columns, and
--   * REJECTS paystatus 'C'/'R' (completion/refund go through their own RPCs).
-- This closes the forgery hole (a client can't UPDATE a payment to completed or
-- rewrite its amount) while still letting the gateway flow do its bookkeeping.
-- Requires secure_app_session.sql. Idempotent.
-- ============================================================================

-- insert_payment: create the temporary 'I' payment row. ins_id forced; any
-- client pay_id/paystatus is ignored (status is always born 'I').
CREATE OR REPLACE FUNCTION public.insert_payment(
  p_token text, p_data jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_id bigint;
  v_data jsonb; v_cols text; v_sel text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_data := (p_data - 'pay_id') || jsonb_build_object('ins_id', v_ins, 'paystatus', 'I');

  SELECT string_agg(quote_ident(column_name), ','),
         string_agg('r.' || quote_ident(column_name), ',')
    INTO v_cols, v_sel
    FROM information_schema.columns
   WHERE table_schema = v_schema AND table_name = 'payment' AND v_data ? column_name;

  EXECUTE format(
    'INSERT INTO %I.payment (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.payment, $1) r RETURNING pay_id',
    v_schema, v_cols, v_sel, v_schema)
  INTO v_id USING v_data;
  RETURN v_id;
END; $$;

-- update_payment: whitelisted pre-completion field updates on one payment row.
CREATE OR REPLACE FUNCTION public.update_payment(
  p_token text, p_pay_id bigint, p_data jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_data jsonb; v_set text;
  c_allowed text[] := ARRAY[
    'payorderid','payreference','paychequeno','paychequedate',
    'paybankname','tender_amount','refund_amount','paystatus'
  ];
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- A client may only ever move a payment to a NON-completed state. Completion
  -- ('C') is exclusively complete_payment_grouped; refund ('R') is process_refund.
  IF p_data ? 'paystatus' AND (p_data->>'paystatus') NOT IN ('F','I','P') THEN
    RAISE EXCEPTION 'update_payment cannot set paystatus=%', p_data->>'paystatus';
  END IF;

  -- Keep only whitelisted keys (drops transtotalamount, paidamount, etc.).
  SELECT jsonb_object_agg(key, value) INTO v_data
    FROM jsonb_each(p_data) WHERE key = ANY(c_allowed);
  IF v_data IS NULL THEN RETURN; END IF;

  SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
    INTO v_set
    FROM information_schema.columns
   WHERE table_schema = v_schema AND table_name = 'payment' AND v_data ? column_name;
  IF v_set IS NULL THEN RETURN; END IF;

  EXECUTE format(
    'UPDATE %I.payment t SET %s FROM jsonb_populate_record(NULL::%I.payment, $1) r WHERE t.pay_id=$2 AND t.ins_id=$3',
    v_schema, v_set, v_schema)
  USING v_data, p_pay_id, v_ins;
END; $$;

-- fail_pending_payments: release a student's pending lock by marking every
-- not-completed ('I') attempt failed. Scoped to the session's institution.
CREATE OR REPLACE FUNCTION public.fail_pending_payments(
  p_token text, p_stu_id bigint
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  EXECUTE format(
    'UPDATE %I.payment SET paystatus=''F'' WHERE ins_id=$1 AND stu_id=$2 AND paystatus=''I''', v_schema)
  USING v_ins, p_stu_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.insert_payment(text, jsonb)                TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_payment(text, bigint, jsonb)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_pending_payments(text, bigint)        TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_students_groupb.sql ============================================================
-- ============================================================================
-- Group B — session-gated Student / Parent writes (PII).
-- ============================================================================
-- Mirrors the Group-A money RPCs: every function validates the session token,
-- derives ins_id SERVER-SIDE (ignoring any client-supplied ins_id/stu_id), and
-- writes into the caller's own institution schema. After Phase 3 REVOKE these
-- become the ONLY way anon can write students/parents/parentdetail.
--
-- Wide PII rows have dozens of columns, so instead of hardcoding column lists we
-- upsert via jsonb_populate_record(NULL::<schema>.<table>, data): it casts the
-- JSON to the table's real column types automatically. We intersect the JSON
-- keys with the table's ACTUAL columns (information_schema) so a stray key can't
-- break the statement and only real columns are touched. Requires
-- secure_app_session.sql (session_context). Idempotent (CREATE OR REPLACE).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- save_student(p_token, p_data, p_stu_id)
--   p_stu_id NULL  -> INSERT (returns the new stu_id)
--   p_stu_id given -> UPDATE that student (scoped to the session's ins_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_student(
  p_token text, p_data jsonb, p_stu_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- Force server-derived ins_id; never trust a client stu_id inside the payload.
  v_data := (p_data - 'stu_id') || jsonb_build_object('ins_id', v_ins);

  IF p_stu_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'students' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO %I.students (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.students, $1) r RETURNING stu_id',
      v_schema, v_cols, v_sel, v_schema)
    INTO v_id USING v_data;
    RETURN v_id;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'students' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE %I.students t SET %s FROM jsonb_populate_record(NULL::%I.students, $1) r WHERE t.stu_id=$2 AND t.ins_id=$3',
      v_schema, v_set, v_schema)
    USING v_data, p_stu_id, v_ins;
    RETURN p_stu_id;
  END IF;
END; $$;

-- ---------------------------------------------------------------------------
-- save_parent(p_token, p_data, p_par_id)  -> INSERT (new par_id) or UPDATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_parent(
  p_token text, p_data jsonb, p_par_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  v_data := (p_data - 'par_id') || jsonb_build_object('ins_id', v_ins);

  IF p_par_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'parents' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO %I.parents (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.parents, $1) r RETURNING par_id',
      v_schema, v_cols, v_sel, v_schema)
    INTO v_id USING v_data;
    RETURN v_id;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'parents' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE %I.parents t SET %s FROM jsonb_populate_record(NULL::%I.parents, $1) r WHERE t.par_id=$2 AND t.ins_id=$3',
      v_schema, v_set, v_schema)
    USING v_data, p_par_id, v_ins;
    RETURN p_par_id;
  END IF;
END; $$;

-- ---------------------------------------------------------------------------
-- save_parentdetail(p_token, p_data, p_stu_id)
--   p_stu_id NULL  -> INSERT link row (student <-> parent)
--   p_stu_id given -> UPDATE the student's parentdetail row (denormalized sync)
-- The row lives in the caller's institution schema, so the server-derived
-- schema is itself the tenant boundary (no ins_id column needed to scope it).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_parentdetail(
  p_token text, p_data jsonb, p_stu_id bigint DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- ins_id is forced only if parentdetail actually has that column (the
  -- information_schema intersection below drops it otherwise).
  v_data := p_data || jsonb_build_object('ins_id', v_ins);

  IF p_stu_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'parentdetail' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO %I.parentdetail (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.parentdetail, $1) r',
      v_schema, v_cols, v_sel, v_schema)
    USING v_data;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = 'parentdetail' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE %I.parentdetail t SET %s FROM jsonb_populate_record(NULL::%I.parentdetail, $1) r WHERE t.stu_id=$2',
      v_schema, v_set, v_schema)
    USING v_data, p_stu_id;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.save_student(text, jsonb, bigint)       TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_parent(text, jsonb, bigint)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_parentdetail(text, jsonb, bigint)  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_admission_groupc.sql ============================================================
-- ============================================================================
-- Group C — session-gated Admission writes (public.admission).
-- ============================================================================
-- admission lives in the PUBLIC schema, so its tenant boundary is the ins_id
-- COLUMN (not a schema). Both functions validate the session token and force
-- ins_id server-side.
--
--  * save_admission        — insert/update public.admission (ins_id forced).
--  * allocate_admission_secure — thin wrapper over the existing
--        allocate_admission_to_student(...). It VERIFIES the admission belongs
--        to the caller's institution and derives the target schema server-side,
--        closing the old hole where the client passed an arbitrary p_schema.
--
-- Requires secure_app_session.sql (session_context). Idempotent.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- save_admission(p_token, p_data, p_adm_id)
--   p_adm_id NULL  -> INSERT (returns new adm_id)
--   p_adm_id given -> UPDATE that admission (scoped to the session's ins_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_admission(
  p_token text, p_data jsonb, p_adm_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  -- Force server-derived ins_id; never trust a client adm_id inside the payload.
  v_data := (p_data - 'adm_id') || jsonb_build_object('ins_id', v_ins);

  IF p_adm_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'admission' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO public.admission (%s) SELECT %s FROM jsonb_populate_record(NULL::public.admission, $1) r RETURNING adm_id',
      v_cols, v_sel)
    INTO v_id USING v_data;
    RETURN v_id;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'admission' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE public.admission t SET %s FROM jsonb_populate_record(NULL::public.admission, $1) r WHERE t.adm_id=$2 AND t.ins_id=$3',
      v_set)
    USING v_data, p_adm_id, v_ins;
    RETURN p_adm_id;
  END IF;
END; $$;

-- ---------------------------------------------------------------------------
-- allocate_admission_secure(p_token, p_adm_id, p_class, p_stuadmno, p_allocatedby)
--   Token-gated wrapper: verifies the admission is the caller's, derives the
--   institution schema server-side, then calls the existing allocator.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.allocate_admission_secure(
  p_token text, p_adm_id bigint, p_class text, p_stuadmno text, p_allocatedby text DEFAULT NULL
) RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_adm_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  SELECT ins_id INTO v_adm_ins FROM public.admission WHERE adm_id = p_adm_id;
  IF v_adm_ins IS NULL THEN RAISE EXCEPTION 'Admission % not found', p_adm_id; END IF;
  IF v_adm_ins <> v_ins THEN
    RAISE EXCEPTION 'Admission % does not belong to this institution', p_adm_id;
  END IF;

  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  RETURN public.allocate_admission_to_student(p_adm_id, v_schema, p_class, p_stuadmno, p_allocatedby);
END; $$;

GRANT EXECUTE ON FUNCTION public.save_admission(text, jsonb, bigint)                        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_admission_secure(text, bigint, text, text, text)  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_masters_groupd.sql ============================================================
-- ============================================================================
-- Group D — session-gated master / config writes (institution-schema tables).
-- ============================================================================
-- Master/config tables are low-risk config data (fee types, classes, quotas,
-- sequences, notices…) that all live INSIDE the caller's institution schema —
-- so the server-derived schema is itself the tenant boundary. Rather than one
-- RPC per table, a single pair of generic, WHITELISTED functions handles them:
--
--   save_schema_row(p_token, p_table, p_data, p_pk_col, p_pk_val)
--       p_pk_val NULL  -> INSERT (returns the pk when p_pk_col given, else NULL)
--       p_pk_val given -> UPDATE that row by p_pk_col
--   delete_schema_row(p_token, p_table, p_pk_col, p_pk_val, p_soft)
--       p_soft true (default) -> activestatus=0 ; false -> hard DELETE
--
-- The whitelist (is_schema_row_writable) is the safety mechanism: money/PII
-- tables (payment, feedemand, students, …) are DELIBERATELY excluded — those
-- have their own dedicated, validated RPCs. Type-safe via jsonb_populate_record.
-- Requires secure_app_session.sql (session_context). Idempotent.
-- ============================================================================

-- Only these institution-schema tables may be written through the generic RPCs.
CREATE OR REPLACE FUNCTION public.is_schema_row_writable(p_table text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_table IN (
    'tempfeedemand','bank','feegroup','feetype','sequence','course','class',
    'classfeedemand','semester','notification','finerule','notice',
    'admissiontype','quota','community','concessioncategory','division',
    'interim_promotion'
  );
$$;

CREATE OR REPLACE FUNCTION public.save_schema_row(
  p_token text, p_table text, p_data jsonb,
  p_pk_col text DEFAULT NULL, p_pk_val bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_schema_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via save_schema_row', p_table;
  END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  -- Force server-derived ins_id (only lands if the table actually has ins_id).
  v_data := p_data || jsonb_build_object('ins_id', v_ins);

  IF p_pk_val IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = p_table AND v_data ? column_name;

    IF p_pk_col IS NULL THEN
      EXECUTE format(
        'INSERT INTO %I.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.%I, $1) r',
        v_schema, p_table, v_cols, v_sel, v_schema, p_table)
      USING v_data;
      RETURN NULL;
    ELSE
      EXECUTE format(
        'INSERT INTO %I.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::%I.%I, $1) r RETURNING %I',
        v_schema, p_table, v_cols, v_sel, v_schema, p_table, p_pk_col)
      INTO v_id USING v_data;
      RETURN v_id;
    END IF;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = p_table AND v_data ? column_name;

    EXECUTE format(
      'UPDATE %I.%I t SET %s FROM jsonb_populate_record(NULL::%I.%I, $1) r WHERE t.%I=$2',
      v_schema, p_table, v_set, v_schema, p_table, p_pk_col)
    USING v_data, p_pk_val;
    RETURN p_pk_val;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.delete_schema_row(
  p_token text, p_table text, p_pk_col text, p_pk_val bigint, p_soft boolean DEFAULT true
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_schema_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via delete_schema_row', p_table;
  END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;

  IF p_soft THEN
    EXECUTE format('UPDATE %I.%I SET activestatus=0 WHERE %I=$1', v_schema, p_table, p_pk_col)
      USING p_pk_val;
  ELSE
    EXECUTE format('DELETE FROM %I.%I WHERE %I=$1', v_schema, p_table, p_pk_col)
      USING p_pk_val;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.is_schema_row_writable(text)                             TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_schema_row(text, text, jsonb, text, bigint)         TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_schema_row(text, text, text, bigint, boolean)     TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_roles_groupc2.sql ============================================================
-- ============================================================================
-- Group C part 2 — session-gated Roles & Access writes.
-- ============================================================================
-- public.custuserroles and public.rolemenuaccess were created WITHOUT anon
-- write grants, so the Roles & Access screen's direct inserts fail with
-- "permission denied for table custuserroles" (42501) — role creation never
-- worked. These SECURITY DEFINER RPCs both FIX that (definer bypasses the grant
-- gap) and secure it: the session token is validated and ins_id is derived
-- SERVER-SIDE, so a role/menu grant can only ever be written for the caller's
-- own institution. Requires secure_app_session.sql. Idempotent.
-- ============================================================================

-- save_user_role(p_token, p_data, p_ur_id): NULL ur_id -> INSERT (returns ur_id), else UPDATE
CREATE OR REPLACE FUNCTION public.save_user_role(
  p_token text, p_data jsonb, p_ur_id bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  v_data := (p_data - 'ur_id') || jsonb_build_object('ins_id', v_ins);

  IF p_ur_id IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'custuserroles' AND v_data ? column_name;

    EXECUTE format(
      'INSERT INTO public.custuserroles (%s) SELECT %s FROM jsonb_populate_record(NULL::public.custuserroles, $1) r RETURNING ur_id',
      v_cols, v_sel)
    INTO v_id USING v_data;
    RETURN v_id;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'custuserroles' AND v_data ? column_name;

    EXECUTE format(
      'UPDATE public.custuserroles t SET %s FROM jsonb_populate_record(NULL::public.custuserroles, $1) r WHERE t.ur_id=$2 AND t.ins_id=$3',
      v_set)
    USING v_data, p_ur_id, v_ins;
    RETURN p_ur_id;
  END IF;
END; $$;

-- delete_user_role(p_token, p_ur_id): soft-delete the caller's role.
CREATE OR REPLACE FUNCTION public.delete_user_role(p_token text, p_ur_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  UPDATE public.custuserroles SET activestatus = 0 WHERE ur_id = p_ur_id AND ins_id = v_ins;
END; $$;

-- save_role_menu_access(p_token, p_ur_id, p_labels, p_createdby): replace a
-- role's menu grants (delete-then-insert) scoped to the caller's institution.
CREATE OR REPLACE FUNCTION public.save_role_menu_access(
  p_token text, p_ur_id bigint, p_labels text[], p_createdby text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer; lbl text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;

  DELETE FROM public.rolemenuaccess WHERE ins_id = v_ins AND ur_id = p_ur_id;
  IF p_labels IS NOT NULL THEN
    FOREACH lbl IN ARRAY p_labels LOOP
      INSERT INTO public.rolemenuaccess(ins_id, ur_id, menulabel, createdby, activestatus)
      VALUES (v_ins, p_ur_id, lbl, p_createdby, 1);
    END LOOP;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.save_user_role(text, jsonb, bigint)                 TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_user_role(text, bigint)                      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_role_menu_access(text, bigint, text[], text)   TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_publicrows_groupc2.sql ============================================================
-- ============================================================================
-- Group C part 2 — session-gated writes for institution-scoped PUBLIC tables.
-- ============================================================================
-- institutionusers (staff accounts — a privilege-escalation surface: with the
-- anon key anyone could insert an admin user for ANY institution) and
-- staffdesignation live in the PUBLIC schema, so their tenant boundary is the
-- ins_id COLUMN. Generic whitelisted pair, analogous to save_schema_row but for
-- public tables: token validated, ins_id forced server-side, and UPDATE/DELETE
-- scoped by ins_id so a caller can only touch its own institution's rows.
--
-- NOTE institutionusers.usepassword is hashed by a BEFORE-INSERT trigger; that
-- trigger fires on this INSERT exactly as on a direct one, so passwords stay
-- bcrypt-hashed. Requires secure_app_session.sql. Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_public_row_writable(p_table text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_table IN ('institutionusers','staffdesignation');
$$;

CREATE OR REPLACE FUNCTION public.save_public_row(
  p_token text, p_table text, p_data jsonb,
  p_pk_col text DEFAULT NULL, p_pk_val bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_id bigint;
  v_data jsonb; v_cols text; v_sel text; v_set text;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_public_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via save_public_row', p_table;
  END IF;

  -- Force server-derived ins_id; drop the pk so a serial default applies.
  v_data := p_data || jsonb_build_object('ins_id', v_ins);
  IF p_pk_col IS NOT NULL THEN v_data := v_data - p_pk_col; END IF;

  IF p_pk_val IS NULL THEN
    SELECT string_agg(quote_ident(column_name), ','),
           string_agg('r.' || quote_ident(column_name), ',')
      INTO v_cols, v_sel
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = p_table AND v_data ? column_name;

    IF p_pk_col IS NULL THEN
      EXECUTE format(
        'INSERT INTO public.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I, $1) r',
        p_table, v_cols, v_sel, p_table)
      USING v_data;
      RETURN NULL;
    ELSE
      EXECUTE format(
        'INSERT INTO public.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I, $1) r RETURNING %I',
        p_table, v_cols, v_sel, p_table, p_pk_col)
      INTO v_id USING v_data;
      RETURN v_id;
    END IF;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=r.' || quote_ident(column_name), ',')
      INTO v_set
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = p_table AND v_data ? column_name;

    EXECUTE format(
      'UPDATE public.%I t SET %s FROM jsonb_populate_record(NULL::public.%I, $1) r WHERE t.%I=$2 AND t.ins_id=$3',
      p_table, v_set, p_table, p_pk_col)
    USING v_data, p_pk_val, v_ins;
    RETURN p_pk_val;
  END IF;
END; $$;

CREATE OR REPLACE FUNCTION public.delete_public_row(
  p_token text, p_table text, p_pk_col text, p_pk_val bigint, p_soft boolean DEFAULT true
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ins integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_public_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via delete_public_row', p_table;
  END IF;

  IF p_soft THEN
    EXECUTE format('UPDATE public.%I SET activestatus=0 WHERE %I=$1 AND ins_id=$2', p_table, p_pk_col)
      USING p_pk_val, v_ins;
  ELSE
    EXECUTE format('DELETE FROM public.%I WHERE %I=$1 AND ins_id=$2', p_table, p_pk_col)
      USING p_pk_val, v_ins;
  END IF;
END; $$;

GRANT EXECUTE ON FUNCTION public.is_public_row_writable(text)                          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_public_row(text, text, jsonb, text, bigint)      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_public_row(text, text, text, bigint, boolean)  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- ==== secure_superadmin_self.sql ============================================================
-- ============================================================================
-- Super-admin self-service account update (closes the last institutionusers hole).
-- ============================================================================
-- The Super-Admin "My Account" screen edits the super admin's OWN row with a
-- direct anon UPDATE (super_admin_dashboard.dart:4351) — the only remaining
-- un-gated institutionusers write, and the reason anon UPDATE couldn't be
-- revoked. Super admins have no session token (they log in cross-institution),
-- so instead of a token this RPC RE-VERIFIES the current bcrypt password
-- server-side — that IS the authorization. It can only ever touch the single
-- row whose (username + inscode='SUPER' + current password) match, and it
-- whitelists the self-service fields, so role/ins_id can't be escalated.
-- The usepassword hash trigger still fires on the UPDATE. Requires pgcrypto in
-- extensions (search_path). Idempotent. After deploying, anon UPDATE on
-- institutionusers can be revoked (see phase3b_revoke_pii_users.sql).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_super_admin_self(
  p_username text, p_current_password text, p_updates jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_use_id integer; v_set text; v_data jsonb;
  c_allowed text[] := ARRAY['usename','usemail','usephone','usedob','usepassword'];
BEGIN
  -- Authorization = current-password re-verification (mirrors verify_user_login
  -- for super admins: username lookup, inscode 'SUPER', bcrypt check).
  SELECT use_id INTO v_use_id
  FROM public.institutionusers
  WHERE lower(usename) = lower(p_username) AND inscode = 'SUPER' AND activestatus = 1
    AND usepassword = crypt(p_current_password, usepassword)
  LIMIT 1;
  IF v_use_id IS NULL THEN RAISE EXCEPTION 'Invalid credentials'; END IF;

  -- Keep only the self-service fields (drops ur_id/ins_id/activestatus/etc.).
  SELECT jsonb_object_agg(key, value) INTO v_data
    FROM jsonb_each(p_updates) WHERE key = ANY(c_allowed);
  IF v_data IS NULL THEN RETURN; END IF;

  SELECT string_agg(quote_ident(key) || '=r.' || quote_ident(key), ',')
    INTO v_set
    FROM jsonb_object_keys(v_data) AS key;

  EXECUTE format(
    'UPDATE public.institutionusers t SET %s '
    'FROM jsonb_populate_record(NULL::public.institutionusers, $1) r WHERE t.use_id=$2',
    v_set)
  USING v_data, v_use_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.update_super_admin_self(text, text, jsonb) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ==== secure_imports_groupd2.sql ============================================================
-- ============================================================================
-- Group D part 2 — session-gated BULK/IMPORT writes for master tables.
-- ============================================================================
-- The single-row master writes already go through save_schema_row. The
-- remaining un-gated writes are BATCH operations (Master Import upserts,
-- classfeedemand batch insert, tempfeedemand batch) and COMPOUND-condition
-- deletes (classfeedemand cleared by class+term+admissiontype). These two
-- generic functions cover them, reusing the same is_schema_row_writable
-- whitelist and forcing ins_id server-side. Requires secure_app_session.sql +
-- secure_masters_groupd.sql (is_schema_row_writable). Idempotent.
-- ============================================================================

-- import_schema_rows: batch INSERT (p_conflict_col NULL) or UPSERT-on-conflict
-- of a JSON array of rows into a whitelisted institution-schema table.
CREATE OR REPLACE FUNCTION public.import_schema_rows(
  p_token text, p_table text, p_rows jsonb, p_conflict_col text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_rows jsonb;
  v_cols text; v_sel text; v_upd text; v_n integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_schema_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not importable via import_schema_rows', p_table;
  END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RETURN 0;
  END IF;

  -- Force server-derived ins_id on every row (only lands if the column exists).
  SELECT jsonb_agg(elem || jsonb_build_object('ins_id', v_ins))
    INTO v_rows FROM jsonb_array_elements(p_rows) elem;

  -- Column list = real columns present in the FIRST row (imports are uniform).
  SELECT string_agg(quote_ident(column_name), ','),
         string_agg('r.' || quote_ident(column_name), ',')
    INTO v_cols, v_sel
    FROM information_schema.columns
   WHERE table_schema = v_schema AND table_name = p_table AND (v_rows->0) ? column_name;

  IF p_conflict_col IS NULL THEN
    EXECUTE format(
      'INSERT INTO %I.%I (%s) SELECT %s FROM jsonb_populate_recordset(NULL::%I.%I, $1) r',
      v_schema, p_table, v_cols, v_sel, v_schema, p_table)
    USING v_rows;
  ELSE
    SELECT string_agg(quote_ident(column_name) || '=EXCLUDED.' || quote_ident(column_name), ',')
      INTO v_upd
      FROM information_schema.columns
     WHERE table_schema = v_schema AND table_name = p_table
       AND (v_rows->0) ? column_name AND column_name <> p_conflict_col;
    EXECUTE format(
      'INSERT INTO %I.%I (%s) SELECT %s FROM jsonb_populate_recordset(NULL::%I.%I, $1) r '
      'ON CONFLICT (%I) DO UPDATE SET %s',
      v_schema, p_table, v_cols, v_sel, v_schema, p_table, p_conflict_col, v_upd)
    USING v_rows;
  END IF;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $$;

-- delete_schema_rows_where: hard-DELETE rows matching an equality map (each
-- key = column, value = required value; NULL value => IS NULL). For the
-- classfeedemand idempotent-clear (class + term + admissiontype). Whitelisted.
CREATE OR REPLACE FUNCTION public.delete_schema_rows_where(
  p_token text, p_table text, p_match jsonb
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_ins integer; v_schema text; v_where text; v_n integer;
BEGIN
  SELECT ins_id INTO v_ins FROM public.session_context(p_token);
  IF v_ins IS NULL THEN RAISE EXCEPTION 'Invalid or expired session'; END IF;
  IF NOT public.is_schema_row_writable(p_table) THEN
    RAISE EXCEPTION 'Table % is not writable via delete_schema_rows_where', p_table;
  END IF;
  v_schema := get_institution_schema(v_ins);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for institution %', v_ins; END IF;
  IF p_match IS NULL OR jsonb_typeof(p_match) <> 'object' THEN
    RAISE EXCEPTION 'p_match must be a JSON object';
  END IF;

  -- Build "col = value / col IS NULL" only over REAL columns of the table.
  SELECT string_agg(
           CASE WHEN jsonb_typeof(p_match->k) = 'null'
                THEN format('%I IS NULL', k)
                ELSE format('%I = %L', k, p_match->>k) END, ' AND ')
    INTO v_where
    FROM jsonb_object_keys(p_match) AS k
   WHERE EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema = v_schema AND c.table_name = p_table
                    AND c.column_name = k);
  IF v_where IS NULL THEN RAISE EXCEPTION 'No valid match columns'; END IF;

  EXECUTE format('DELETE FROM %I.%I WHERE %s', v_schema, p_table, v_where);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $$;

GRANT EXECUTE ON FUNCTION public.import_schema_rows(text, text, jsonb, text)      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_schema_rows_where(text, text, jsonb)      TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
