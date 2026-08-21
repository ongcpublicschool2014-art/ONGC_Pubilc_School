-- ============================================================================
-- Configurable Demand Number (demno) sequence.
-- ============================================================================
-- demno was hardcoded by the set_dem_id / set_temp_id BEFORE-INSERT triggers as
-- 'DE' + 2-digit year + '/' + LPAD(id,5). This lets each institution configure
-- a single demand-number sequence in the shared `sequence` table:
--     actname = 'DEMNO', fg_id NULL, isprefix 'Y', seqprefix + seqwidth set.
-- When such a row exists the triggers emit  <seqprefix><LPAD(seqcurno+1, seqwidth)>
-- (e.g. DM00001) and advance seqcurno (row-locked). With no DEMNO row they fall
-- back to the original DExx/NNNNN format, so existing institutions are unchanged
-- until they create a sequence in Fee Master -> Demand No. Idempotent.
-- Run in the Supabase SQL editor.
-- ============================================================================

DO $do$
DECLARE r record; sname text;
BEGIN
  FOR r IN
    SELECT DISTINCT lower(i.inshortname) || replace(iy.yrlabel, '-', '') AS schema_name
    FROM public.institution i
    JOIN public.institutionyear iy ON iy.ins_id = i.ins_id
    WHERE i.inshortname IS NOT NULL
  LOOP
    sname := r.schema_name;
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = sname)
       AND EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = sname AND table_name = 'feedemand') THEN

      EXECUTE format($f$
        CREATE OR REPLACE FUNCTION %I.set_dem_id() RETURNS trigger LANGUAGE plpgsql AS $t$
        DECLARE v_sid int; v_pref text; v_w int; v_cur numeric;
        BEGIN
          IF NEW.dem_id IS NULL OR NEW.dem_id = 0 THEN NEW.dem_id := nextval('%I.feedemand_dem_id_seq'); END IF;
          IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN
            SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno
              INTO v_sid, v_pref, v_w, v_cur
              FROM %I.sequence
              WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1
              ORDER BY seq_id LIMIT 1 FOR UPDATE;
            IF v_sid IS NOT NULL THEN
              v_cur := COALESCE(v_cur, 0) + 1;
              NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0');
              UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid;
            ELSE
              NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.dem_id::text, 5, '0');
            END IF;
          END IF;
          IF NEW.demseqtype IS NULL OR TRIM(NEW.demseqtype) = '' THEN NEW.demseqtype := 'DEMAND'; END IF;
          IF (NEW.fee_id IS NULL OR NEW.fee_id = 0) AND NEW.demfeetype IS NOT NULL THEN
            SELECT ft.fee_id INTO NEW.fee_id FROM %I.feetype ft WHERE ft.feedesc = NEW.demfeetype AND ft.activestatus = 1 LIMIT 1;
          END IF;
          RETURN NEW;
        END;
        $t$
      $f$, sname, sname, sname, sname, sname);

      EXECUTE format($f$
        CREATE OR REPLACE FUNCTION %I.set_temp_id() RETURNS trigger LANGUAGE plpgsql AS $t$
        DECLARE v_sid int; v_pref text; v_w int; v_cur numeric;
        BEGIN
          IF NEW.temp_id IS NULL THEN NEW.temp_id := nextval('%I.tempfeedemand_temp_id_seq'); END IF;
          IF NEW.demno IS NULL OR TRIM(NEW.demno) = '' THEN
            SELECT seq_id, COALESCE(seqprefix,''), COALESCE(seqwidth::int,5), seqcurno
              INTO v_sid, v_pref, v_w, v_cur
              FROM %I.sequence
              WHERE ins_id = NEW.ins_id AND actname = 'DEMNO' AND activestatus = 1
              ORDER BY seq_id LIMIT 1 FOR UPDATE;
            IF v_sid IS NOT NULL THEN
              v_cur := COALESCE(v_cur, 0) + 1;
              NEW.demno := v_pref || LPAD(v_cur::bigint::text, v_w, '0');
              UPDATE %I.sequence SET seqcurno = v_cur WHERE seq_id = v_sid;
            ELSE
              NEW.demno := 'DE' || RIGHT(SPLIT_PART(COALESCE(NEW.demfeeyear, ''), '-', 1), 2) || '/' || LPAD(NEW.temp_id::text, 5, '0');
            END IF;
          END IF;
          RETURN NEW;
        END;
        $t$
      $f$, sname, sname, sname, sname);

    END IF;
  END LOOP;
END $do$;

NOTIFY pgrst, 'reload schema';
