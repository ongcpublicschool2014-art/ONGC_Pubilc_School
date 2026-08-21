-- ============================================================================
-- Fee Group / Fee Type import: drop the Year column, auto-set it in the DB.
-- ============================================================================
-- The Import Fee Group / Fee Type screens no longer carry a Year column. This
-- updates process_master_import so the FEEGROUP and FEETYPE branches resolve
-- the year from the schema's ACTIVE year instead of reading it from the import
-- (col3 for FEEGROUP, col5 for FEETYPE). Fee Type's "Fine Applicable" therefore
-- moves from col6 to col5. All other import types are unchanged.
-- Safe / idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_master_import(p_ins_id integer) RETURNS TABLE(total integer, imported integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rec RECORD; v_total int:=0; v_imported int:=0; v_skipped int:=0; v_fg_id int; v_schema text; v_id int; v_adm_id smallint; v_yr_id int; v_yrlabel text;
BEGIN
  v_schema := get_institution_schema(p_ins_id);
  FOR rec IN SELECT * FROM master_import WHERE ins_id=p_ins_id AND status='PENDING' ORDER BY imp_id LOOP
    v_total := v_total+1;
    BEGIN
      -- Every import row must carry an explicit id in col1. Blank or
      -- non-numeric ids are rejected outright — no sequence fallback.
      IF rec.col1 IS NULL OR TRIM(rec.col1) = '' THEN
        UPDATE master_import SET status='ERROR', error_msg='Missing id in column 1' WHERE imp_id=rec.imp_id;
        v_skipped := v_skipped+1; CONTINUE;
      END IF;
      BEGIN v_id := TRIM(rec.col1)::int; EXCEPTION WHEN OTHERS THEN
        UPDATE master_import SET status='ERROR', error_msg='Invalid id: "'||rec.col1||'"' WHERE imp_id=rec.imp_id;
        v_skipped := v_skipped+1; CONTINUE;
      END;
      IF v_schema IS NULL THEN
        UPDATE master_import SET status='ERROR', error_msg='No institution schema' WHERE imp_id=rec.imp_id;
        v_skipped := v_skipped+1; CONTINUE;
      END IF;

      CASE rec.imp_type
      WHEN 'FEEGROUP' THEN
        -- Year is auto-set to the schema's active year (no longer imported).
        EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
          INTO v_yr_id, v_yrlabel USING p_ins_id;
        IF v_yr_id IS NULL THEN
          UPDATE master_import SET status='ERROR', error_msg='No active year configured in year master' WHERE imp_id=rec.imp_id;
          v_skipped:=v_skipped+1; CONTINUE;
        END IF;
        EXECUTE format('INSERT INTO %I.feegroup(fg_id,fgdesc,ins_id,yr_id,yrlabel,ban_id,activestatus) VALUES($1,$2,$3,$4,$5,NULL,1)', v_schema) USING v_id,TRIM(rec.col2),p_ins_id,v_yr_id,v_yrlabel;
      WHEN 'FEETYPE' THEN
        EXECUTE format('SELECT fg_id FROM %I.feegroup WHERE UPPER(TRIM(fgdesc))=UPPER($1) AND ins_id=$2 AND activestatus=1 LIMIT 1', v_schema) INTO v_fg_id USING TRIM(rec.col4),p_ins_id;
        IF v_fg_id IS NULL THEN UPDATE master_import SET status='ERROR',error_msg='Fee group "'||rec.col4||'" not found' WHERE imp_id=rec.imp_id; v_skipped:=v_skipped+1; CONTINUE; END IF;
        -- Year is auto-set to the schema's active year (no longer imported).
        EXECUTE format('SELECT yr_id, yrlabel FROM %I.year WHERE ins_id=$1 AND activestatus=1 ORDER BY yr_id DESC LIMIT 1', v_schema)
          INTO v_yr_id, v_yrlabel USING p_ins_id;
        IF v_yr_id IS NULL THEN
          UPDATE master_import SET status='ERROR', error_msg='No active year configured in year master' WHERE imp_id=rec.imp_id;
          v_skipped:=v_skipped+1; CONTINUE;
        END IF;
        -- Fine Applicable is now col5 (Year column removed from the import).
        EXECUTE format('INSERT INTO %I.feetype(fee_id,feedesc,feeshort,fg_id,yr_id,yrlabel,feefineapplicable,activestatus,ins_id) VALUES($1,$2,$3,$4,$5,$6,COALESCE(NULLIF($7,'''')::smallint,0),1,$8)', v_schema) USING v_id,TRIM(rec.col2),TRIM(rec.col3),v_fg_id,v_yr_id,v_yrlabel,TRIM(rec.col5),p_ins_id;
      WHEN 'CONCESSION' THEN
        EXECUTE format('INSERT INTO %I.concessioncategory(con_id,condesc,ins_id,ordid,activestatus) VALUES($1,$2,$3,NULLIF($4,'''')::int,1)', v_schema) USING v_id,TRIM(rec.col2),p_ins_id,TRIM(rec.col3);
      WHEN 'CLASSFEEDEMAND' THEN
        -- cf_id is assigned by the set_cf_id BEFORE-INSERT trigger; col1 is a
        -- placeholder row number that we ignore here.
        -- col7 is an admissiontype NAME (e.g. "MANAGEMENT QUOTA"). Look up
        -- adm_id from the per-schema admissiontype master and store that
        -- smallint id. Falls back to direct numeric cast for legacy 1/2/3.
        IF NULLIF(TRIM(rec.col7),'') IS NULL THEN
          v_adm_id := NULL;
        ELSIF TRIM(rec.col7) ~ '^\d+$' THEN
          v_adm_id := TRIM(rec.col7)::smallint;
        ELSE
          EXECUTE format('SELECT adm_id FROM %I.admissiontype WHERE UPPER(TRIM(admname))=UPPER($1) AND ins_id=$2 AND activestatus=1 LIMIT 1', v_schema)
            INTO v_adm_id USING TRIM(rec.col7), p_ins_id;
          IF v_adm_id IS NULL THEN
            UPDATE master_import SET status='ERROR', error_msg='Admission Type "'||rec.col7||'" not found in admissiontype master' WHERE imp_id=rec.imp_id;
            v_skipped := v_skipped+1;
            CONTINUE;
          END IF;
        END IF;
        EXECUTE format('INSERT INTO %I.classfeedemand(cfclass,cfterm,cffeetype,cfamount,cfdduedate,admissiontype) VALUES($1,NULLIF($2,''''),$3,NULLIF($4,'''')::numeric(12,2),NULLIF($5,'''')::date,$6)', v_schema)
          USING TRIM(rec.col2),TRIM(rec.col3),TRIM(rec.col4),TRIM(rec.col5),TRIM(rec.col6),v_adm_id;
      ELSE
        UPDATE master_import SET status='ERROR',error_msg='Unknown type: '||rec.imp_type WHERE imp_id=rec.imp_id; v_skipped:=v_skipped+1; CONTINUE;
      END CASE;
      UPDATE master_import SET status='DONE' WHERE imp_id=rec.imp_id; v_imported:=v_imported+1;
    EXCEPTION WHEN unique_violation THEN
      UPDATE master_import SET status='ERROR', error_msg='ID '||COALESCE(v_id::text, rec.col1)||' already exists — row rejected' WHERE imp_id=rec.imp_id; v_skipped:=v_skipped+1;
    WHEN OTHERS THEN
      UPDATE master_import SET status='ERROR',error_msg=SQLERRM WHERE imp_id=rec.imp_id; v_skipped:=v_skipped+1;
    END;
  END LOOP;
  RETURN QUERY SELECT v_total, v_imported, v_skipped;
END; $$;

GRANT EXECUTE ON FUNCTION public.process_master_import(integer) TO anon, authenticated;

NOTIFY pgrst, 'reload config';
