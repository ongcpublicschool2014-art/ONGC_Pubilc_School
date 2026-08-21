-- ============================================================================
-- Backfill cla_id / adm_id / quo_id on existing students.
-- ============================================================================
-- Rows imported before add_student_entity_ids.sql have NULL cla_id/adm_id/quo_id.
-- This fills them by matching each student's stored NAME against the class /
-- admissiontype / quota masters (only where the id is still NULL). Safe to
-- re-run. (medium has no source to backfill — re-import or set it manually.)
-- Run in the Supabase SQL editor AFTER add_student_entity_ids.sql.
-- ============================================================================

DO $$
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
       AND EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = sname AND table_name = 'students') THEN
      EXECUTE format($q$
        UPDATE %1$I.students s SET
          cla_id = COALESCE(s.cla_id, (SELECT c.cla_id FROM %1$I.class c
                     WHERE UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass)) AND c.ins_id = s.ins_id AND c.activestatus = 1 LIMIT 1)),
          adm_id = COALESCE(s.adm_id, (SELECT a.adm_id FROM %1$I.admissiontype a
                     WHERE UPPER(TRIM(a.admname)) = UPPER(TRIM(s.admname)) AND a.ins_id = s.ins_id AND a.activestatus = 1 LIMIT 1)),
          quo_id = COALESCE(s.quo_id, (SELECT q.quo_id FROM %1$I.quota q
                     WHERE UPPER(TRIM(q.quoname)) = UPPER(TRIM(s.quoname)) AND q.ins_id = s.ins_id AND q.activestatus = 1 LIMIT 1))
        WHERE s.activestatus <> 9
          AND (s.cla_id IS NULL OR s.adm_id IS NULL OR s.quo_id IS NULL)
      $q$, sname);
      RAISE NOTICE 'Backfilled cla_id/adm_id/quo_id in %.students', sname;
    END IF;
  END LOOP;
END $$;
