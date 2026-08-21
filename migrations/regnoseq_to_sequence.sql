-- ============================================================================
-- Retire the separate regnoseq table — store register/admission-number
-- sequences in the shared `sequence` table instead.
-- ============================================================================
-- Register-number sequencing used to live in its own per-schema `regnoseq`
-- table. It now lives as rows in the same `sequence` table that holds fee-
-- receipt sequences, discriminated by:
--     actname = 'REGNO'  AND  fg_id IS NULL
-- Field mapping (regnoseq -> sequence):
--     rns_id      -> seq_id      (now IDENTITY / auto — old ids are not kept)
--     rnsname     -> seqname     (widened to varchar(50))
--     rnsmode P/S -> isprefix    ('P' -> 'Y', 'S' -> 'N')
--     rnsaffix    -> seqprefix   (widened to varchar(15))
--     rnsstart    -> seqstart
--     rnsend      -> seqend      (new column)
--     rnswidth    -> seqwidth    (widened to numeric(2,0))
--     rnscurrent  -> seqcurno
--     division    -> division    (new column)
--
-- Run in the Supabase SQL editor. Idempotent: register rows are copied only
-- once per schema, then regnoseq is dropped. Mirrors the create_institution_schema
-- changes in complete_setup.sql (sequence table + complete_payment_atomic guard).
--
-- IMPORTANT: deploy the matching app build (which reads register sequences from
-- `sequence`) together with this migration — after it runs, regnoseq is gone.
-- ============================================================================

-- 1) Re-guard the Razorpay single-receipt RPC so it never grabs a register row
--    (register sequences have fg_id NULL; receipt sequences always have fg_id).
CREATE OR REPLACE FUNCTION public.complete_payment_atomic(p_pay_id bigint, p_pay_method text, p_pay_reference text, p_items jsonb, p_ins_id integer) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_pay_number TEXT; v_item JSONB; v_dem_id BIGINT; v_amount NUMERIC; v_current_paid NUMERIC; v_current_balance NUMERIC; v_new_paid NUMERIC; v_new_balance NUMERIC; v_stu_id BIGINT; v_pay_status CHAR(1); v text; v_seq RECORD; v_new_no INTEGER;
BEGIN
  v := get_institution_schema(p_ins_id); IF v IS NULL THEN RAISE EXCEPTION 'No schema'; END IF;
  EXECUTE format('SELECT paystatus,stu_id FROM %I.payment WHERE pay_id=$1 FOR UPDATE',v) INTO v_pay_status,v_stu_id USING p_pay_id;
  IF v_pay_status IS NULL THEN RAISE EXCEPTION 'Payment % not found',p_pay_id; END IF;
  IF v_pay_status!='I' THEN RAISE EXCEPTION 'Payment % not Initiated',p_pay_id; END IF;
  -- Generate pay number from first available RECEIPT sequence
  -- (fg_id IS NOT NULL excludes register-number sequences, which have fg_id NULL / actname 'REGNO').
  EXECUTE format('SELECT seq_id,sequid,seqwidth,seqcurno FROM %I.sequence WHERE ins_id=$1 AND fg_id IS NOT NULL LIMIT 1 FOR UPDATE',v) INTO v_seq USING p_ins_id;
  IF v_seq IS NULL THEN v_pay_number:='PAY'||p_pay_id;
  ELSE v_new_no:=v_seq.seqcurno+1; v_pay_number:=regexp_replace(v_seq.sequid,'\d+$','')||lpad(v_new_no::TEXT,v_seq.seqwidth::INTEGER,'0'); EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2',v) USING v_new_no,v_seq.seq_id;
  END IF;
  EXECUTE format('UPDATE %I.payment SET paystatus=''C'',paymethod=$1,payreference=$2,paynumber=$3,paydate=NOW(),recon_status=''P'' WHERE pay_id=$4',v) USING p_pay_method,p_pay_reference,v_pay_number,p_pay_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_dem_id:=(v_item->>'dem_id')::BIGINT; v_amount:=(v_item->>'amount')::NUMERIC;
    EXECUTE format('UPDATE %I.feedemand
                      SET paidamount = COALESCE(paidamount, 0) + $1,
                          balancedue = GREATEST(COALESCE(balancedue, 0) - $1, 0),
                          paidstatus = CASE WHEN GREATEST(COALESCE(balancedue, 0) - $1, 0) <= 0 THEN ''P'' ELSE ''U'' END,
                          pay_id     = $2
                      WHERE dem_id = $3 AND activestatus = 1', v)
    USING v_amount, p_pay_id, v_dem_id;
  END LOOP;
  RETURN v_pay_number;
END; $$;

-- 2) Per-schema migration: generalise `sequence`, copy register rows, drop regnoseq.
DO $mig$
DECLARE
  rec RECORD;
  s text;
  v_yr_id integer;
  v_yrlabel text;
  v_existing integer;
BEGIN
  FOR rec IN
    SELECT table_schema AS schema_name
    FROM information_schema.tables
    WHERE table_name = 'regnoseq'
  LOOP
    s := rec.schema_name;

    -- (a) Widen / add the columns register sequences need.
    EXECUTE format('ALTER TABLE %I.sequence ALTER COLUMN seqname TYPE varchar(50)', s);
    EXECUTE format('ALTER TABLE %I.sequence ALTER COLUMN seqprefix TYPE varchar(15)', s);
    EXECUTE format('ALTER TABLE %I.sequence ALTER COLUMN seqwidth TYPE numeric(2,0)', s);
    EXECUTE format('ALTER TABLE %I.sequence ADD COLUMN IF NOT EXISTS seqend numeric(9,0)', s);
    EXECUTE format('ALTER TABLE %I.sequence ADD COLUMN IF NOT EXISTS division varchar(50)', s);

    -- (b) Copy register sequences across — once (idempotent).
    EXECUTE format('SELECT count(*) FROM %I.sequence WHERE actname = ''REGNO''', s) INTO v_existing;
    IF v_existing = 0 THEN
      v_yr_id := 0; v_yrlabel := '';
      BEGIN
        EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE activestatus = 1 ORDER BY yr_id DESC LIMIT 1', s)
          INTO v_yr_id, v_yrlabel;
      EXCEPTION WHEN OTHERS THEN
        v_yr_id := 0; v_yrlabel := '';
      END;
      v_yr_id := COALESCE(v_yr_id, 0);
      v_yrlabel := COALESCE(v_yrlabel, '');

      EXECUTE format($ins$
        INSERT INTO %1$I.sequence
          (ins_id, mod_id, yr_id, yrlabel, actname, seqname, isprefix, seqprefix,
           seqstart, seqwidth, sequid, seqcurno, seqend, division, activestatus)
        SELECT COALESCE(ins_id, 0), 0, %2$s, %3$L, 'REGNO', rnsname,
               CASE WHEN rnsmode = 'P' THEN 'Y' ELSE 'N' END,
               COALESCE(rnsaffix, ''), COALESCE(rnsstart, 1), COALESCE(rnswidth, 4),
               LEFT(COALESCE(NULLIF(rnsaffix, ''), 'REG'), 18), COALESCE(rnscurrent, 0),
               rnsend, division, COALESCE(activestatus, 1)
        FROM %1$I.regnoseq
      $ins$, s, v_yr_id, v_yrlabel);
    END IF;

    -- (c) Retire the separate table.
    EXECUTE format('DROP TABLE IF EXISTS %I.regnoseq', s);

    RAISE NOTICE 'regnoseq -> sequence migrated for schema %', s;
  END LOOP;
END $mig$;

-- 3) Rebuild the PostgREST schema cache (sequence structure changed, regnoseq gone).
NOTIFY pgrst, 'reload schema';
