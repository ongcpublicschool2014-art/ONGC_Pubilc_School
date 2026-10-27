-- ============================================================================
-- Miscellaneous Fee Collection
-- ----------------------------------------------------------------------------
-- A standalone counter collection (BONAFIDE CERTIFICATE, APPLICATION, …) that
-- does NOT touch feedemand — it never reduces any demand. Stored in its own two
-- per-schema tables. The receipt number is drawn from the SAME fee-collection
-- sequence (public receipt series, per fee group) so misc + regular receipts
-- share one continuous FCxx/ number series.
--
-- Modes: 'S' = registered Student (stu_id/regno/class filled), 'O' = Others
-- (free-text name/class/city/address, no reg no).
--
-- Idempotent. Run once in the Supabase SQL editor.
-- ============================================================================

-- 1) Tables on every existing tenant schema ---------------------------------
DO $do$
DECLARE s text;
BEGIN
  FOR s IN
    SELECT nspname FROM pg_namespace
    WHERE nspname NOT LIKE 'pg_%'
      AND nspname NOT IN ('public','information_schema','extensions','auth','storage',
                          'realtime','supabase_functions','graphql','graphql_public',
                          'pgsodium','pgsodium_masks','vault','net','_realtime','supabase_migrations')
  LOOP
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema=s AND table_name='sequence') THEN
      EXECUTE format($f$
        CREATE TABLE IF NOT EXISTS %1$I.misc_collection (
          mc_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
          ins_id      integer NOT NULL,
          inscode     varchar(10),
          yr_id       integer,
          yrlabel     varchar(9),
          mcno        varchar(30) NOT NULL,
          mcdate      date NOT NULL DEFAULT CURRENT_DATE,
          selection   char(1) NOT NULL DEFAULT 'S' CHECK (selection IN ('S','O')),
          stu_id      bigint,
          regno       varchar(25),
          stuclass    varchar(30),
          stuname     varchar(100) NOT NULL,
          city        varchar(50),
          address     varchar(255),
          paymode     varchar(20) DEFAULT 'Cash',
          ban_id      integer,
          bankname    varchar(100),
          transrefno  varchar(50),
          draweebank  varchar(100),
          transdate   date,
          transamt    numeric(12,2),
          collectedby varchar(50),
          remarks     varchar(255),
          totalamount numeric(12,2) NOT NULL DEFAULT 0,
          fg_id       integer,
          activestatus smallint DEFAULT 1 NOT NULL,
          createdat   timestamptz DEFAULT now(),
          createdby   varchar(50)
        )
      $f$, s);
      EXECUTE format($f$
        CREATE TABLE IF NOT EXISTS %1$I.misc_collection_detail (
          mcd_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
          mc_id      bigint NOT NULL,
          ins_id     integer NOT NULL,
          fee_id     integer,
          feetype    varchar(30) NOT NULL,
          amount     numeric(12,2) NOT NULL DEFAULT 0,
          activestatus smallint DEFAULT 1 NOT NULL
        )
      $f$, s);
      -- Drop the redundant mcprefix column if an earlier run created it (mcno
      -- already carries the prefix, e.g. HF26/00018).
      EXECUTE format('ALTER TABLE %I.misc_collection DROP COLUMN IF EXISTS mcprefix', s);
      EXECUTE format('CREATE INDEX IF NOT EXISTS idx_misc_detail_mc ON %I.misc_collection_detail (mc_id)', s);
      EXECUTE format('GRANT ALL ON %I.misc_collection TO anon, authenticated', s);
      EXECUTE format('GRANT ALL ON %I.misc_collection_detail TO anon, authenticated', s);
      RAISE NOTICE 'misc_collection tables ready on schema %', s;
    END IF;
  END LOOP;
END $do$;

-- 2) Writer RPC --------------------------------------------------------------
-- Draws the receipt number from the fee group's receipt sequence (the same
-- series regular Fee Collection uses), stores header + lines, returns the mcno.
CREATE OR REPLACE FUNCTION public.save_misc_collection(
  p_ins_id integer, p_header jsonb, p_lines jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_schema text;
  v_mc_id  bigint;
  v_fg_id  integer;
  v_seq_id integer; v_sequid text; v_width numeric; v_cur numeric;
  v_prefix text; v_mcno text;
  v_total  numeric := 0;
  itm jsonb;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  IF v_schema IS NULL THEN RAISE EXCEPTION 'No schema for ins_id %', p_ins_id; END IF;

  v_fg_id := NULLIF(p_header->>'fg_id','')::integer;

  -- Receipt number from the shared fee-collection sequence (per fee group).
  IF v_fg_id IS NOT NULL THEN
    EXECUTE format('SELECT seq_id, sequid, seqwidth, seqcurno FROM %I.sequence WHERE ins_id=$1 AND fg_id=$2 LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_sequid, v_width, v_cur USING p_ins_id, v_fg_id;
  END IF;
  IF v_seq_id IS NULL THEN
    EXECUTE format('SELECT seq_id, sequid, seqwidth, seqcurno FROM %I.sequence WHERE ins_id=$1 AND fg_id IS NOT NULL ORDER BY seq_id LIMIT 1 FOR UPDATE', v_schema)
      INTO v_seq_id, v_sequid, v_width, v_cur USING p_ins_id;
  END IF;
  IF v_seq_id IS NULL THEN RAISE EXCEPTION 'No receipt sequence configured for this institution'; END IF;

  v_cur    := COALESCE(v_cur, 0) + 1;
  v_prefix := regexp_replace(COALESCE(v_sequid, ''), '\d+$', '');
  v_mcno   := v_prefix || lpad(v_cur::bigint::text, COALESCE(v_width, 5)::int, '0');
  EXECUTE format('UPDATE %I.sequence SET seqcurno=$1 WHERE seq_id=$2', v_schema) USING v_cur, v_seq_id;

  SELECT COALESCE(SUM((x->>'amount')::numeric), 0) INTO v_total
  FROM jsonb_array_elements(p_lines) x;

  EXECUTE format('INSERT INTO %I.misc_collection
      (ins_id,inscode,yr_id,yrlabel,mcno,mcdate,selection,stu_id,regno,stuclass,stuname,
       city,address,paymode,ban_id,bankname,transrefno,draweebank,transdate,transamt,collectedby,remarks,
       totalamount,fg_id,activestatus,createdby)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,1,$25)
     RETURNING mc_id', v_schema)
    INTO v_mc_id
    USING p_ins_id,
          p_header->>'inscode',
          NULLIF(p_header->>'yr_id','')::integer,
          p_header->>'yrlabel',
          v_mcno,
          COALESCE(NULLIF(p_header->>'mcdate','')::date, CURRENT_DATE),
          COALESCE(NULLIF(p_header->>'selection',''), 'S'),
          NULLIF(p_header->>'stu_id','')::bigint,
          p_header->>'regno', p_header->>'stuclass', p_header->>'stuname',
          p_header->>'city', p_header->>'address',
          COALESCE(NULLIF(p_header->>'paymode',''), 'Cash'),
          NULLIF(p_header->>'ban_id','')::integer,
          p_header->>'bankname', p_header->>'transrefno', p_header->>'draweebank',
          NULLIF(p_header->>'transdate','')::date,
          NULLIF(p_header->>'transamt','')::numeric,
          p_header->>'collectedby', p_header->>'remarks',
          v_total, v_fg_id, COALESCE(NULLIF(p_header->>'collectedby',''), 'SYSTEM');

  FOR itm IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    CONTINUE WHEN COALESCE(TRIM(itm->>'feetype'), '') = '';
    EXECUTE format('INSERT INTO %I.misc_collection_detail (mc_id,ins_id,fee_id,feetype,amount,activestatus)
        VALUES ($1,$2,$3,$4,$5,1)', v_schema)
      USING v_mc_id, p_ins_id,
            NULLIF(itm->>'fee_id','')::integer,
            itm->>'feetype',
            COALESCE(NULLIF(itm->>'amount','')::numeric, 0);
  END LOOP;

  RETURN jsonb_build_object('mc_id', v_mc_id, 'mcno', v_mcno, 'total', v_total);
END;
$$;

GRANT EXECUTE ON FUNCTION public.save_misc_collection(integer, jsonb, jsonb) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
