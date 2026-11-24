-- =====================================================================
--  SCHOOL TRANSPORT - one schema per academic year
--  Run after transport_04_move_masters_to_public.sql, before
--  transport_02_phase1_api.sql. Safe to run again.
--
--  Masters live in public and are shared by every year. Everything that
--  belongs to a year lives in transport<yyyy><yyyy>, like the school app's
--  ongc20262027: 2026-2027 -> transport20262027, 2027-2028 ->
--  transport20272028 (transport2627 before 2026-11-20; file 04 renames an
--  old one). The tr_* API picks the schema from the year
--  the user signed in to.
--
--  Starting a year (run once per year, before anyone uses Transport in it):
--      SELECT transport_core.create_year_schema('2027-2028');
--  It copies the STRUCTURE of the latest year schema - tables, keys, checks,
--  indexes, foreign keys, triggers, views, RLS, the closed grants - with no
--  rows. IDs carry on from the source year, so they never repeat across years.
--  The stage fees' semesters come from the school app's schema of the new
--  year (e.g. ongc20272028.semester), so start the year in the school app
--  first. Monthly GPS partitions are not copied: create them for the new year
--  with transport_core.fn_create_ping_partition.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS transport_core;
REVOKE ALL ON SCHEMA transport_core FROM PUBLIC, anon, authenticated;

-- '2026-2027' / '2026-27' / '2026/2027' -> 'transport20262027'; anything else -> NULL.
CREATE OR REPLACE FUNCTION transport_core.year_schema(p_yrlabel text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE m text[]; e int;
BEGIN
  m := regexp_match(btrim(COALESCE(p_yrlabel, '')), '^(\d{4})\s*[-/]\s*(\d{2}|\d{4})$');
  IF m IS NULL THEN RETURN NULL; END IF;
  e := m[2]::int;
  IF length(m[2]) = 2 THEN  -- '2026-27' -> 2027, '2099-00' -> 2100
    e := m[1]::int - m[1]::int % 100 + e + CASE WHEN e < m[1]::int % 100 THEN 100 ELSE 0 END;
  END IF;
  RETURN 'transport' || m[1] || e;
END $$;

-- A schema name given by a caller must be a year schema that exists.
CREATE OR REPLACE FUNCTION transport_core._check_year_schema(p_schema text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_schema IS NULL OR p_schema !~ '^transport\d{8}$' OR to_regnamespace(p_schema) IS NULL THEN
    RAISE EXCEPTION 'Unknown transport year schema: %', COALESCE(p_schema, '-');
  END IF;
  RETURN p_schema;
END $$;

-- The school app's own schema for the same academic year
-- (institutionyear.iyrschema, e.g. transport20262027 -> ongc20262027). The stage
-- fees (tr_stage_fee.sem_id) are for the semesters in its semester table.
CREATE OR REPLACE FUNCTION transport_core._app_year_schema(p_year_schema text)
RETURNS text LANGUAGE plpgsql STABLE
SET search_path TO pg_catalog AS $$
DECLARE v text[];
BEGIN
  SELECT array_agg(DISTINCT iy.iyrschema::text ORDER BY iy.iyrschema::text) INTO v
    FROM public.institutionyear iy
   WHERE transport_core.year_schema(iy.yrlabel) = p_year_schema
     AND to_regclass(quote_ident(iy.iyrschema) || '.semester') IS NOT NULL;
  IF v IS NULL THEN
    RAISE EXCEPTION 'The school app has no semesters for the year of %. Start that year in the school app first.', p_year_schema;
  END IF;
  IF cardinality(v) > 1 THEN
    RAISE EXCEPTION 'More than one school works in the year of % (%): the stage fees can follow the semesters of one school only.',
      p_year_schema, array_to_string(v, ', ');
  END IF;
  RETURN v[1];
END $$;

-- ---------------------------------------------------------------------
-- Start a year: copy the structure of an existing year schema.
-- p_from_yrlabel: the year to copy; default = the latest year schema.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core.create_year_schema(p_yrlabel text, p_from_yrlabel text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql
-- Only pg_catalog on the path, so pg_get_*def() writes every table name with
-- its schema; the source schema prefix is then swapped for the new one.
SET search_path TO pg_catalog AS $$
DECLARE
  tgt text := transport_core.year_schema(p_yrlabel);
  src text; r record; v_last bigint; v_called boolean; v_def text; v_app text;
BEGIN
  IF tgt IS NULL THEN
    RAISE EXCEPTION 'Year "%" is not like 2027-2028.', p_yrlabel;
  END IF;
  IF to_regnamespace(tgt) IS NOT NULL THEN
    RAISE NOTICE 'Schema % already exists; nothing to do.', tgt;
    RETURN tgt;
  END IF;
  IF p_from_yrlabel IS NOT NULL THEN
    src := transport_core.year_schema(p_from_yrlabel);
  ELSE
    SELECT n.nspname INTO src FROM pg_namespace n
     WHERE n.nspname ~ '^transport\d{8}$' ORDER BY n.nspname DESC LIMIT 1;
  END IF;
  PERFORM transport_core._check_year_schema(src);

  EXECUTE format('CREATE SCHEMA %I', tgt);
  EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC, anon, authenticated', tgt);

  -- 1. Tables: columns, defaults, checks, identity, indexes, PK / unique.
  FOR r IN SELECT c.oid, c.relname, c.relkind FROM pg_class c
            WHERE c.relnamespace = to_regnamespace(src) AND c.relkind IN ('r', 'p') AND NOT c.relispartition
            ORDER BY c.relname LOOP
    IF r.relkind = 'p' THEN
      EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I INCLUDING ALL) PARTITION BY %s',
                     tgt, r.relname, src, r.relname, pg_get_partkeydef(r.oid));
    ELSE
      EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I INCLUDING ALL)', tgt, r.relname, src, r.relname);
    END IF;
  END LOOP;

  -- 2. Default partitions only; month partitions belong to their own year.
  FOR r IN SELECT c.relname, p.relname AS parent
             FROM pg_class c JOIN pg_inherits i ON i.inhrelid = c.oid JOIN pg_class p ON p.oid = i.inhparent
            WHERE c.relnamespace = to_regnamespace(src) AND c.relispartition
              AND pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT' LOOP
    EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I DEFAULT', tgt, r.relname, tgt, r.parent);
  END LOOP;

  -- 3. IDs carry on from the source year.
  FOR r IN SELECT c.relname, a.attname
             FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
            WHERE c.relnamespace = to_regnamespace(src) AND c.relkind IN ('r', 'p') AND NOT c.relispartition
              AND a.attidentity <> '' AND NOT a.attisdropped LOOP
    EXECUTE format('SELECT last_value, is_called FROM %s', pg_get_serial_sequence(format('%I.%I', src, r.relname), r.attname))
       INTO v_last, v_called;
    PERFORM setval(pg_get_serial_sequence(format('%I.%I', tgt, r.relname), r.attname), v_last, v_called);
  END LOOP;

  -- The staff enrollments (transport_23) are keyed to the school app's staff
  -- of the year (staffmast): the school app makes that table for a year when
  -- its staff screens are first used, so make it now if it has not yet.
  IF to_regclass(format('%I.tr_staff_enrollment', src)) IS NOT NULL
     AND to_regprocedure('public.school_staff_year(text)') IS NOT NULL THEN
    v_app := COALESCE(v_app, transport_core._app_year_schema(tgt));
    PERFORM public.school_staff_year(v_app);
  END IF;

  -- 4. Foreign keys: to the masters in public as they are, inside the year
  --    to the new year's tables, and into the school app's year (the stage
  --    fees' semesters) to the school app's schema of the new year.
  FOR r IN SELECT k.conname, c.relname, pg_get_constraintdef(k.oid) AS def, fn.nspname AS ref_sch
             FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
             JOIN pg_class f ON f.oid = k.confrelid JOIN pg_namespace fn ON fn.oid = f.relnamespace
            WHERE c.relnamespace = to_regnamespace(src) AND k.contype = 'f'
              AND k.conparentid = 0 AND NOT c.relispartition LOOP
    v_def := replace(r.def, src || '.', tgt || '.');
    IF r.ref_sch NOT IN ('public', src) THEN
      v_app := COALESCE(v_app, transport_core._app_year_schema(tgt));
      v_def := replace(v_def, 'REFERENCES ' || quote_ident(r.ref_sch) || '.', 'REFERENCES ' || quote_ident(v_app) || '.');
    END IF;
    EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s', tgt, r.relname, r.conname, v_def);
  END LOOP;

  -- 5. Triggers (updated_at); the trigger function stays in transport_core.
  FOR r IN SELECT pg_get_triggerdef(t.oid) AS def
             FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
            WHERE c.relnamespace = to_regnamespace(src) AND NOT t.tgisinternal AND t.tgparentid = 0 LOOP
    EXECUTE replace(r.def, ' ON ' || src || '.', ' ON ' || tgt || '.');
  END LOOP;

  -- 6. Views, reading the new year's tables.
  FOR r IN SELECT c.relname, pg_get_viewdef(c.oid) AS def FROM pg_class c
            WHERE c.relnamespace = to_regnamespace(src) AND c.relkind = 'v' ORDER BY c.oid LOOP
    EXECUTE format('CREATE VIEW %I.%I AS %s', tgt, r.relname, replace(r.def, src || '.', tgt || '.'));
  END LOOP;

  -- 7. Closed like every other transport table.
  FOR r IN SELECT c.relname, c.relkind FROM pg_class c
            WHERE c.relnamespace = to_regnamespace(tgt) AND c.relkind IN ('r', 'p', 'v') LOOP
    IF r.relkind IN ('r', 'p') THEN
      EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', tgt, r.relname);
    END IF;
    EXECUTE format('REVOKE ALL ON TABLE %I.%I FROM PUBLIC, anon, authenticated', tgt, r.relname);
  END LOOP;

  RETURN tgt;
END $$;

-- ---------------------------------------------------------------------
-- GPS month partitions, per year schema (call from a monthly job):
--   SELECT transport_core.fn_create_ping_partition('transport20262027', '2026-07-01');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core.fn_create_ping_partition(p_year_schema text, p_month date)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_sch  text := transport_core._check_year_schema(p_year_schema);
  v_from date := date_trunc('month', p_month)::date;
  v_to   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_name text := format('tr_gps_ping_%s', to_char(v_from, 'YYYYMM'));
BEGIN
  EXECUTE format('CREATE TABLE IF NOT EXISTS %I.%I PARTITION OF %I.tr_gps_ping FOR VALUES FROM (%L) TO (%L)',
                 v_sch, v_name, v_sch, v_from, v_to);
  EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', v_sch, v_name);
  EXECUTE format('REVOKE ALL ON TABLE %I.%I FROM PUBLIC, anon, authenticated', v_sch, v_name);
END $$;

-- ---------------------------------------------------------------------
-- Daily trips from schedules. The year schema is the academic year that
-- contains p_date for that school. The search_path is pointed at that year
-- for this call only, so the year tables are named without a schema and the
-- masters are found in public.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core.fn_generate_trips(p_inst_id bigint, p_date date)
RETURNS integer LANGUAGE plpgsql
SET search_path TO pg_catalog, public AS $$
DECLARE v_count integer := 0; r record; v_trip bigint; v_label text; v_sch text;
BEGIN
  SELECT iy.yrlabel INTO v_label FROM public.institutionyear iy
   WHERE iy.ins_id = p_inst_id AND iy.activestatus = 1
     AND p_date BETWEEN COALESCE(iy.iyrstadate, '-infinity'::date) AND COALESCE(iy.iyrenddate, 'infinity'::date)
   ORDER BY iy.yrlabel DESC LIMIT 1;
  v_sch := transport_core._check_year_schema(transport_core.year_schema(v_label));
  PERFORM set_config('search_path', format('pg_catalog, %I, public', v_sch), true);

  FOR r IN
    SELECT s.* FROM tr_trip_schedule s
     WHERE s.inst_id = p_inst_id AND s.is_active
       AND p_date >= s.effective_from AND (s.effective_to IS NULL OR p_date <= s.effective_to)
       AND EXTRACT(ISODOW FROM p_date)::smallint = ANY (s.run_days)
       AND NOT EXISTS (SELECT 1 FROM tr_trip t
                        WHERE t.schedule_id = s.schedule_id AND t.trip_date = p_date)
  LOOP
    INSERT INTO tr_trip(inst_id, schedule_id, route_id, trip_date, direction, vehicle_id,
                        planned_start_at, planned_end_at)
    VALUES (r.inst_id, r.schedule_id, r.route_id, p_date, r.direction, r.vehicle_id,
            p_date + r.planned_start, p_date + r.planned_end)
    RETURNING trip_id INTO v_trip;

    INSERT INTO tr_trip_stop(trip_id, stop_id, visit_seq, planned_at)
    SELECT v_trip, ss.stop_id, ss.visit_seq, p_date + ss.planned_time
      FROM tr_trip_schedule_stop ss WHERE ss.schedule_id = r.schedule_id;

    INSERT INTO tr_trip_staff(trip_id, staff_id, duty_role)
    SELECT v_trip, d.staff_id, d.duty_role
      FROM tr_duty_assignment d
      JOIN public.tr_staff st ON st.staff_id = d.staff_id AND st.status = 'ACTIVE'
     WHERE d.schedule_id = r.schedule_id
       AND p_date >= d.effective_from AND (d.effective_to IS NULL OR p_date <= d.effective_to)
       AND NOT EXISTS (SELECT 1 FROM tr_staff_leave l
                        WHERE l.staff_id = d.staff_id AND l.status = 'APPROVED'
                          AND p_date BETWEEN l.from_date AND l.to_date);

    -- the students and staff it expects
    PERFORM transport_core.fn_sync_trip_riders(v_sch, v_trip);

    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- ---------------------------------------------------------------------
-- The riders a day's trip expects, from the enrollments (students, and staff
-- where the year has them: transport_23/24) and the Vehicle Allotment: those
-- allotted to the trip's vehicle (its schedule) that way, and those allotted
-- to none only when the route has no other schedule running that way on the
-- day (one vehicle: nothing to choose). With two or more vehicles, a rider
-- allotted to none rides none until allotted. One-way service and the dates
-- of the enrollment count; a day exception makes a student ABSENT or
-- PARENT_PICKUP.
-- Run when a trip is made (fn_generate_trips), and again for a Scheduled trip
-- of today or later when an enrollment or an allotment of its route changes
-- (transport_core._route_trips_sync): riders who belong are added, those who
-- no longer belong are taken off, and the stop and day exception brought up
-- to date -- except a rider someone marked (mark_method set), who stays as
-- marked, and a rider added to the trip in its Riders window (is_extra,
-- transport_29), who stays on it. Returns how many riders were added, taken
-- off or changed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core.fn_sync_trip_riders(p_year_schema text, p_trip_id bigint)
RETURNS integer LANGUAGE plpgsql
SET search_path TO pg_catalog, public AS $$
DECLARE r record; v_only boolean; v_n integer := 0; v_rc integer;
BEGIN
  PERFORM set_config('search_path',
    format('pg_catalog, %I, public', transport_core._check_year_schema(p_year_schema)), true);
  SELECT t.trip_id, t.trip_date, t.direction, t.route_id, t.schedule_id INTO r FROM tr_trip t WHERE t.trip_id = p_trip_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  -- the route's only vehicle that way on the day: it takes those allotted to none
  v_only := NOT EXISTS (SELECT 1 FROM tr_trip_schedule s
                         WHERE s.route_id = r.route_id AND s.direction = r.direction AND s.schedule_id <> r.schedule_id
                           AND s.is_active AND r.trip_date >= s.effective_from
                           AND (s.effective_to IS NULL OR r.trip_date <= s.effective_to)
                           AND EXTRACT(ISODOW FROM r.trip_date)::smallint = ANY (s.run_days));

  WITH want AS (
    SELECT e.enrollment_id, e.student_id,
           CASE WHEN r.direction = 'PICKUP' THEN e.pickup_stop_id ELSE e.drop_stop_id END AS stop_id,
           CASE WHEN x.exception_id IS NULL THEN 'EXPECTED'
                WHEN x.reason = 'PARENT_PICKUP' THEN 'PARENT_PICKUP' ELSE 'ABSENT' END AS status
      FROM tr_student_enrollment e
      LEFT JOIN tr_student_trip_exception x
             ON x.enrollment_id = e.enrollment_id AND x.exception_date = r.trip_date
            AND x.direction IN (r.direction, 'BOTH')
     WHERE e.route_id = r.route_id AND e.status = 'ACTIVE'
       AND r.trip_date >= e.start_date AND (e.end_date IS NULL OR r.trip_date <= e.end_date)
       AND e.service_type IN ('BOTH', r.direction)
       AND COALESCE(CASE WHEN r.direction = 'PICKUP' THEN e.pickup_schedule_id ELSE e.drop_schedule_id END,
                    CASE WHEN v_only THEN r.schedule_id END) = r.schedule_id
  ), gone AS (
    DELETE FROM tr_trip_student ts
     WHERE ts.trip_id = r.trip_id AND ts.mark_method IS NULL AND NOT ts.is_extra
       AND NOT EXISTS (SELECT 1 FROM want w WHERE w.enrollment_id = ts.enrollment_id)
    RETURNING 1
  ), moved AS (
    UPDATE tr_trip_student ts SET stop_id = w.stop_id, status = w.status
      FROM want w
     WHERE ts.trip_id = r.trip_id AND ts.enrollment_id = w.enrollment_id AND ts.mark_method IS NULL AND NOT ts.is_extra
       AND (ts.stop_id IS DISTINCT FROM w.stop_id OR ts.status IS DISTINCT FROM w.status)
    RETURNING 1
  ), added AS (
    INSERT INTO tr_trip_student (trip_id, enrollment_id, student_id, stop_id, status)
    SELECT r.trip_id, w.enrollment_id, w.student_id, w.stop_id, w.status FROM want w
     WHERE NOT EXISTS (SELECT 1 FROM tr_trip_student ts WHERE ts.trip_id = r.trip_id AND ts.enrollment_id = w.enrollment_id)
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM gone) + (SELECT count(*) FROM moved) + (SELECT count(*) FROM added) INTO v_rc;
  v_n := v_n + v_rc;

  IF to_regclass('tr_trip_staff_rider') IS NOT NULL AND to_regclass('tr_staff_enrollment') IS NOT NULL THEN
    WITH want AS (
      SELECT e.enrollment_id, e.staf_id,
             CASE WHEN r.direction = 'PICKUP' THEN e.pickup_stop_id ELSE e.drop_stop_id END AS stop_id
        FROM tr_staff_enrollment e
       WHERE e.route_id = r.route_id AND e.status = 'ACTIVE'
         AND r.trip_date >= e.start_date AND (e.end_date IS NULL OR r.trip_date <= e.end_date)
         AND e.service_type IN ('BOTH', r.direction)
         AND COALESCE(CASE WHEN r.direction = 'PICKUP' THEN e.pickup_schedule_id ELSE e.drop_schedule_id END,
                      CASE WHEN v_only THEN r.schedule_id END) = r.schedule_id
    ), gone AS (
      DELETE FROM tr_trip_staff_rider ts
       WHERE ts.trip_id = r.trip_id AND ts.mark_method IS NULL AND NOT ts.is_extra
         AND NOT EXISTS (SELECT 1 FROM want w WHERE w.enrollment_id = ts.enrollment_id)
      RETURNING 1
    ), moved AS (
      UPDATE tr_trip_staff_rider ts SET stop_id = w.stop_id
        FROM want w
       WHERE ts.trip_id = r.trip_id AND ts.enrollment_id = w.enrollment_id AND ts.mark_method IS NULL AND NOT ts.is_extra
         AND ts.stop_id IS DISTINCT FROM w.stop_id
      RETURNING 1
    ), added AS (
      INSERT INTO tr_trip_staff_rider (trip_id, enrollment_id, staf_id, stop_id)
      SELECT r.trip_id, w.enrollment_id, w.staf_id, w.stop_id FROM want w
       WHERE NOT EXISTS (SELECT 1 FROM tr_trip_staff_rider ts WHERE ts.trip_id = r.trip_id AND ts.enrollment_id = w.enrollment_id)
      RETURNING 1
    )
    SELECT (SELECT count(*) FROM gone) + (SELECT count(*) FROM moved) + (SELECT count(*) FROM added) INTO v_rc;
    v_n := v_n + v_rc;
  END IF;

  -- the students expected at each stop, and on the trip (changed only when they differ)
  UPDATE tr_trip_stop ts
     SET expected_students = c.cnt
    FROM (SELECT s.stop_id, NULLIF((SELECT count(*) FROM tr_trip_student x
                                     WHERE x.trip_id = s.trip_id AND x.stop_id = s.stop_id AND x.status = 'EXPECTED'), 0)::smallint AS cnt
            FROM tr_trip_stop s WHERE s.trip_id = r.trip_id) c
   WHERE ts.trip_id = r.trip_id AND ts.stop_id = c.stop_id AND ts.expected_students IS DISTINCT FROM c.cnt;
  UPDATE tr_trip t
     SET planned_students = c.cnt
    FROM (SELECT count(*)::smallint AS cnt FROM tr_trip_student WHERE trip_id = r.trip_id AND status = 'EXPECTED') c
   WHERE t.trip_id = r.trip_id AND t.planned_students IS DISTINCT FROM c.cnt;
  RETURN v_n;
END $$;

-- ---------------------------------------------------------------------
-- Queue "bus arriving in N minutes" alerts for one trip of a year schema.
-- Called by the GPS ingestion service after it refreshes tr_trip_stop.eta_at.
-- Idempotent: eta_alert_sent_at + uq_notif_once stop duplicates.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS transport_core.fn_queue_eta_alerts(bigint);
CREATE OR REPLACE FUNCTION transport_core.fn_queue_eta_alerts(p_year_schema text, p_trip_id bigint)
RETURNS integer LANGUAGE plpgsql
SET search_path TO pg_catalog, public AS $$
DECLARE v_lead smallint; v_rows integer;
BEGIN
  PERFORM set_config('search_path',
    format('pg_catalog, %I, public', transport_core._check_year_schema(p_year_schema)), true);

  SELECT st.eta_alert_minutes INTO v_lead
    FROM tr_trip t JOIN public.tr_settings st ON st.inst_id = t.inst_id
   WHERE t.trip_id = p_trip_id AND t.status = 'IN_PROGRESS';
  IF v_lead IS NULL THEN RETURN 0; END IF;

  WITH due AS (
    UPDATE tr_trip_stop ts
       SET eta_alert_sent_at = now(), status = 'APPROACHING'
     WHERE ts.trip_id = p_trip_id
       AND ts.eta_alert_sent_at IS NULL
       AND ts.status = 'PENDING'
       AND ts.eta_at IS NOT NULL
       AND ts.eta_at <= now() + make_interval(mins => v_lead)
    RETURNING ts.trip_id, ts.stop_id, ts.eta_at
  ), ins AS (
    INSERT INTO tr_notification_log
          (inst_id, event_code, channel, trip_id, stop_id, student_id, contact_id,
           recipient, template_id, message_text)
    SELECT t.inst_id, 'ETA_ALERT', ch.channel, t.trip_id, d.stop_id, tsd.student_id, c.contact_id,
           CASE ch.channel WHEN 'PUSH' THEN c.fcm_token ELSE c.mobile END,
           tpl.template_id,
           replace(replace(replace(tpl.body,
                   '{vehicle_code}', v.vehicle_code),
                   '{stop_name}',    s.stop_name),
                   '{eta_min}',      GREATEST(1, ceil(EXTRACT(EPOCH FROM (d.eta_at - now()))/60))::int::text)
      FROM due d
      JOIN tr_trip t           ON t.trip_id = d.trip_id
      JOIN public.tr_vehicle v ON v.vehicle_id = t.vehicle_id
      JOIN public.tr_stop s    ON s.stop_id = d.stop_id
      JOIN tr_trip_student tsd ON tsd.trip_id = d.trip_id AND tsd.stop_id = d.stop_id
                              AND tsd.status = 'EXPECTED'
      JOIN tr_notify_contact c ON c.student_id = tsd.student_id AND c.is_active
      CROSS JOIN LATERAL (VALUES ('SMS', c.notify_sms), ('WHATSAPP', c.notify_whatsapp),
                                 ('PUSH', c.notify_push AND c.fcm_token IS NOT NULL)) ch(channel, wanted)
      JOIN tr_notification_template tpl
           ON tpl.inst_id = t.inst_id AND tpl.event_code = 'ETA_ALERT'
          AND tpl.channel = ch.channel AND tpl.language_code = c.language_code AND tpl.is_active
     WHERE ch.wanted
    ON CONFLICT DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_rows FROM ins;
  RETURN v_rows;
END $$;

-- Nothing here is for the app: only the owner (SQL editor, jobs) may run it.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA transport_core FROM PUBLIC, anon, authenticated;

-- Next: transport_02_phase1_api.sql.
