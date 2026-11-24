-- Tests for transport_02_phase1_api.sql. Run ONLY inside a transaction that is
-- rolled back: the last statement raises TESTS_OK / TESTS_FAILED so nothing stays.
CREATE FUNCTION pg_temp.fails(p_sql text, p_needle text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(p_needle) IN lower(SQLERRM)) > 0 THEN RETURN NULL; END IF;
    RETURN 'wrong error for [' || left(p_sql, 70) || ']: ' || SQLERRM;
  END;
  RETURN 'did not fail: ' || left(p_sql, 90);
END $f$;

DO $t$
DECLARE
  bad text[] := '{}'; n integer := 0; msg text; u integer; tk_a text := repeat('a', 32); tk_ac text := repeat('c', 32);
  tk_p text := repeat('p', 32); tk_x text := repeat('x', 32); tk_old text := repeat('o', 32);
  r1 bigint; r2 bigint; g1 bigint; g2 bigint; f1 bigint; s1 bigint; s2 bigint; v1 bigint; d1 bigint; d2 bigint; w1 bigint;
  st bigint; alien bigint; alien_stage bigint; j jsonb; iyr_now integer; iyr_old integer;
  fe integer; sm smallint; app_sch text;

BEGIN
  SELECT use_id INTO u FROM public.institutionusers WHERE activestatus = 1 LIMIT 1;
  SELECT iyr_id INTO iyr_now FROM public.institutionyear WHERE ins_id = 1 AND yrlabel = '2026-2027';
  SELECT iyr_id INTO iyr_old FROM public.institutionyear WHERE ins_id = 1 AND yrlabel = '2025-2026';
  -- a stage fee needs a fee head and a semester of the year (transport_16)
  SELECT iyrschema INTO app_sch FROM public.institutionyear WHERE iyr_id = iyr_now;
  SELECT fee_id INTO fe FROM public.feetype WHERE ins_id = 1 AND feecat = 'TRA' AND activestatus = 1 ORDER BY fee_id LIMIT 1;
  IF to_regclass(quote_ident(app_sch) || '.semester') IS NOT NULL THEN
    EXECUTE format('SELECT sem_id FROM %I.semester WHERE ins_id = 1 ORDER BY sem_id LIMIT 1', app_sch) INTO sm;
  END IF;
  IF fe IS NULL OR sm IS NULL THEN
    RAISE EXCEPTION 'TESTS_FAILED: school 1 needs a transport fee type (feetype, feecat TRA) and a 2026-2027 semester to test the stage fees.';
  END IF;
  INSERT INTO public.app_session (token_hash, use_id, ins_id, role, yrlabel) VALUES
    (encode(extensions.digest(tk_a, 'sha256'), 'hex'), u, 1, 'Admin', '2026-2027');
  INSERT INTO public.app_session (token_hash, use_id, ins_id, role, yrlabel) VALUES
    (encode(extensions.digest(tk_ac, 'sha256'), 'hex'), u, 1, 'Accountant', '2026-2027');
  INSERT INTO public.app_session (token_hash, par_id, par_mob, ins_id, role) VALUES
    (encode(extensions.digest(tk_p, 'sha256'), 'hex'), 1, '9999999999', 1, 'parent');
  INSERT INTO public.app_session (token_hash, use_id, ins_id, role, expires_at) VALUES
    (encode(extensions.digest(tk_x, 'sha256'), 'hex'), u, 1, 'Admin', now() - interval '1 day');
  INSERT INTO public.app_session (token_hash, use_id, ins_id, role, yrlabel) VALUES
    (encode(extensions.digest(tk_old, 'sha256'), 'hex'), u, 1, 'Admin', '2025-2026');

  -- 1. the happy path, every entity
  r1 := public.tr_save(tk_a, 'route', '{"route_code":" r5 ","route_name":"North Line","description":"  "}');
  IF (SELECT route_code FROM public.tr_route WHERE route_id = r1) <> 'R5' THEN bad := bad || ('code not trimmed/upper')::text; END IF;
  IF (SELECT description FROM public.tr_route WHERE route_id = r1) IS NOT NULL THEN bad := bad || ('blank text not null')::text; END IF;
  IF (SELECT created_by FROM public.tr_route WHERE route_id = r1) <> u THEN bad := bad || ('created_by not from session')::text; END IF;
  r2 := public.tr_save(tk_a, 'route', '{"route_code":"R6","route_name":"South Line"}');
  g1 := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', r1, 'stage_no', 1, 'stage_name', 'Stage 1', 'from_km', 0, 'to_km', 5));
  g2 := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', r2, 'stage_no', 1, 'stage_name', 'Stage 1'));
  f1 := public.tr_save(tk_a, 'stage_fee', jsonb_build_object('route_id', r1, 'stage_id', g1, 'fee_id', fe, 'sem_id', sm,
                                                             'amount', 5000, 'effective_from', '2026-06-01', 'inst_id', 999));
  IF (SELECT activestatus FROM transport20262027.tr_stage_fee WHERE stage_fee_id = f1) IS DISTINCT FROM 1::smallint
     OR (SELECT created_by FROM transport20262027.tr_stage_fee WHERE stage_fee_id = f1) IS DISTINCT FROM u THEN
    bad := bad || ('stage fee not active by default, or created_by not from session')::text;
  END IF;
  s1 := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', r1, 'stage_id', g1, 'stop_seq', 1, 'stop_name', 'Mill Gate', 'latitude', 13.05, 'longitude', 80.27));
  s2 := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', r1, 'stage_id', g1, 'stop_seq', 2, 'stop_name', 'Main Road', 'latitude', 13.06, 'longitude', 80.28));
  w1 := public.tr_save(tk_a, 'vendor', '{"vendor_name":"Sri Travels","mobile":"9876543210","gstin":"33abcde1234f1z5"}');
  v1 := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'bus-07', 'registration_no', 'tn01ab1234', 'vehicle_type', 'BUS', 'seating_capacity', 40, 'ownership_type', 'OWNED'));
  d1 := public.tr_save(tk_a, 'vehicle_doc', jsonb_build_object('vehicle_id', v1, 'doc_type', 'INSURANCE', 'doc_no', 'A1', 'expiry_date', '2026-12-31'));
  d2 := public.tr_save(tk_a, 'vehicle_doc', jsonb_build_object('vehicle_id', v1, 'doc_type', 'INSURANCE', 'doc_no', 'A2', 'expiry_date', '2027-12-31'));
  IF (SELECT is_current FROM public.tr_vehicle_document WHERE vehicle_doc_id = d1) THEN bad := bad || ('old doc still current')::text; END IF;
  IF NOT (SELECT is_current FROM public.tr_vehicle_document WHERE vehicle_doc_id = d2) THEN bad := bad || ('new doc not current')::text; END IF;
  st := public.tr_save(tk_a, 'staff', '{"staff_code":"d1","staff_type":"DRIVER","full_name":"Kumar","mobile":"9876500000","id_proof_no_masked":"1234 5678 9012"}');
  IF (SELECT id_proof_no_masked FROM public.tr_staff WHERE staff_id = st) <> 'XXXXXXXX9012' THEN bad := bad || ('full ID number stored')::text; END IF;
  PERFORM public.tr_save(tk_a, 'staff_doc', jsonb_build_object('staff_id', st, 'doc_type', 'DRIVING_LICENCE', 'expiry_date', '2030-01-01'));
  n := n + 12;

  -- update keeps untouched columns
  PERFORM public.tr_save(tk_a, 'route', jsonb_build_object('route_id', r1, 'route_name', 'North Line 2'));
  IF (SELECT route_code FROM public.tr_route WHERE route_id = r1) <> 'R5' THEN bad := bad || ('partial update wiped code')::text; END IF;
  IF (SELECT updated_by FROM public.tr_route WHERE route_id = r1) <> u THEN bad := bad || ('updated_by missing')::text; END IF;
  -- tables without updated_by also update
  PERFORM public.tr_save(tk_a, 'vehicle_doc', jsonb_build_object('vehicle_doc_id', d2, 'doc_no', 'A2-B'));
  IF (SELECT doc_no FROM public.tr_vehicle_document WHERE vehicle_doc_id = d2) <> 'A2-B' THEN bad := bad || ('doc update lost')::text; END IF;
  IF NOT (SELECT is_current FROM public.tr_vehicle_document WHERE vehicle_doc_id = d2) THEN bad := bad || ('doc edit lost current flag')::text; END IF;
  PERFORM public.tr_save(tk_a, 'stage_fee', jsonb_build_object('stage_fee_id', f1, 'amount', 5500));
  IF (SELECT amount FROM transport20262027.tr_stage_fee WHERE stage_fee_id = f1) <> 5500 THEN bad := bad || ('fee update lost')::text; END IF;
  n := n + 4;

  -- 2. readable errors
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'route','{"route_code":"R5","route_name":"x"}')$q$, tk_a), 'route code is already used'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'stop',%L)$q$, tk_a, jsonb_build_object('route_id', r1, 'stage_id', g1, 'stop_seq', 1, 'stop_name', 'dup', 'latitude', 1, 'longitude', 1)), 'already has that order'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle',%L)$q$, tk_a, jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'B2', 'registration_no', 'TN01AB1234', 'vehicle_type', 'BUS', 'seating_capacity', 40, 'ownership_type', 'OWNED')), 'registration number is already'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle',%L)$q$, tk_a, jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'B3', 'registration_no', 'X3', 'vehicle_type', 'BUS', 'seating_capacity', 40, 'ownership_type', 'HIRED')), 'choose the vendor'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle',%L)$q$, tk_a, jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'B4', 'registration_no', 'X4', 'vehicle_type', 'BUS', 'seating_capacity', 0, 'ownership_type', 'OWNED')), 'more than zero'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'route','{"route_code":"R9"}')$q$, tk_a), 'enter the route name'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'stage',%L)$q$, tk_a, jsonb_build_object('route_id', r1, 'stage_no', 'abc', 'stage_name', 'x')), 'not valid'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'stage',%L)$q$, tk_a, jsonb_build_object('route_id', r1, 'stage_no', 7, 'stage_name', 'x', 'from_km', 9, 'to_km', 1)), 'from km'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'stage_fee',%L)$q$, tk_a, jsonb_build_object('route_id', r1, 'stage_id', g1, 'fee_id', fe, 'sem_id', sm, 'amount', -1, 'effective_from', '2026-07-01')), 'negative'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'vendor','{"vendor_name":"x","mobile":"123"}')$q$, tk_a), 'valid mobile'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_list(%L,'nonsense')$q$, tk_a), 'unknown transport'); bad := bad || msg;
  -- the fuel is compulsory (transport_20): missing, unknown, or cleared on an edit
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle',%L)$q$, tk_a, jsonb_build_object('vehicle_code', 'B5', 'registration_no', 'X5', 'vehicle_type', 'BUS', 'seating_capacity', 40, 'ownership_type', 'OWNED')), 'enter the fuel type'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle',%L)$q$, tk_a, jsonb_build_object('fuel_type', 'GAS', 'vehicle_code', 'B6', 'registration_no', 'X6', 'vehicle_type', 'BUS', 'seating_capacity', 40, 'ownership_type', 'OWNED')), 'choose the fuel'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle',%L)$q$, tk_a, jsonb_build_object('vehicle_id', v1, 'fuel_type', ' ')), 'enter the fuel type'); bad := bad || msg;
  -- the additional capacity (transport_21): 0 for a new vehicle and when left
  -- empty; never negative, nor more than the seats
  IF (SELECT additional_capacity FROM public.tr_vehicle WHERE vehicle_id = v1) IS DISTINCT FROM 0::smallint THEN
    bad := bad || ('a new vehicle''s additional capacity is not 0')::text;
  END IF;
  PERFORM public.tr_save(tk_a, 'vehicle', jsonb_build_object('vehicle_id', v1, 'additional_capacity', 4));
  IF (SELECT additional_capacity FROM public.tr_vehicle WHERE vehicle_id = v1) IS DISTINCT FROM 4::smallint THEN
    bad := bad || ('the additional capacity was not saved')::text;
  END IF;
  PERFORM public.tr_save(tk_a, 'vehicle', jsonb_build_object('vehicle_id', v1, 'additional_capacity', ''));
  IF (SELECT additional_capacity FROM public.tr_vehicle WHERE vehicle_id = v1) IS DISTINCT FROM 0::smallint THEN
    bad := bad || ('an empty additional capacity is not 0')::text;
  END IF;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle',%L)$q$, tk_a, jsonb_build_object('vehicle_id', v1, 'additional_capacity', -1)), 'additional capacity cannot be negative'); bad := bad || msg;
  msg := pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle',%L)$q$, tk_a, jsonb_build_object('vehicle_id', v1, 'additional_capacity', 41)), 'cannot be more than the seating capacity'); bad := bad || msg;
  n := n + 19;

  -- 3. who may call
  FOREACH msg IN ARRAY ARRAY[
    format($q$SELECT public.tr_list(%L,'route')$q$, tk_p),
    format($q$SELECT public.tr_save(%L,'route','{"route_code":"P","route_name":"p"}')$q$, tk_p),
    format($q$SELECT public.tr_delete(%L,'route',%s)$q$, tk_p, r1),
    format($q$SELECT public.tr_settings_get(%L)$q$, tk_p),
    format($q$SELECT public.tr_lookups(%L)$q$, tk_p)] LOOP
    bad := bad || pg_temp.fails(msg, 'school staff');
    n := n + 1;
  END LOOP;
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'route')$q$, tk_ac), 'no access');
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle','{}')$q$, tk_ac), 'no access');
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_settings_save(%L,'{}')$q$, tk_ac), 'no access');
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'route')$q$, tk_x), 'expired');
  bad := bad || pg_temp.fails($q$SELECT public.tr_list(NULL,'route')$q$, 'not authenticated');
  bad := bad || pg_temp.fails($q$SELECT public.tr_list('short','route')$q$, 'not authenticated');
  n := n + 6;

  -- 4. another school's records cannot be seen or touched
  INSERT INTO public.tr_route(inst_id, route_code, route_name) VALUES (999, 'ZZ', 'Other School') RETURNING route_id INTO alien;
  INSERT INTO public.tr_stage (inst_id, route_id, stage_no, stage_name) VALUES (999, alien, 1, 'Other') RETURNING stage_id INTO alien_stage;
  j := public.tr_list(tk_a, 'route');
  IF j::text LIKE '%Other School%' THEN bad := bad || ('list leaked another school')::text; END IF;
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'route',%L)$q$, tk_a, jsonb_build_object('route_id', alien, 'route_name', 'hacked')), 'not found');
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'route',%s)$q$, tk_a, alien), 'not found');
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'stage',%L)$q$, tk_a, jsonb_build_object('route_id', alien, 'stage_no', 2, 'stage_name', 'x')), 'not found');
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'stop',%L)$q$, tk_a, jsonb_build_object('route_id', r1, 'stage_id', alien_stage, 'stop_seq', 9, 'stop_name', 'x', 'latitude', 1, 'longitude', 1)), 'not found');
  PERFORM public.tr_save(tk_a, 'route', jsonb_build_object('route_id', r1, 'inst_id', 999, 'created_by', 12345));
  IF (SELECT inst_id FROM public.tr_route WHERE route_id = r1) <> 1 THEN bad := bad || ('inst_id was writable')::text; END IF;
  IF (SELECT created_by FROM public.tr_route WHERE route_id = r1) <> u THEN bad := bad || ('created_by was writable')::text; END IF;
  -- SQL text in a filter key or value stays data
  IF jsonb_array_length(public.tr_list(tk_a, 'route', jsonb_build_object('route_code', $q$x' OR '1'='1$q$))) <> 0 THEN bad := bad || ('filter value injected')::text; END IF;
  -- an unlisted filter key is ignored: the same rows as no filter (works on a DB with real routes too)
  IF jsonb_array_length(public.tr_list(tk_a, 'route', jsonb_build_object('inst_id', 999)))
     <> jsonb_array_length(public.tr_list(tk_a, 'route')) THEN bad := bad || ('unlisted filter key used')::text; END IF;
  n := n + 9;

  -- 5. stop on a stage of another route of the same school is refused
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'stop',%L)$q$, tk_a, jsonb_build_object('route_id', r1, 'stage_id', g2, 'stop_seq', 9, 'stop_name', 'x', 'latitude', 1, 'longitude', 1)), 'different route');
  n := n + 1;

  -- 6. delete rules
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'stage',%s)$q$, tk_a, g1), 'active stop');
  IF public.tr_delete(tk_a, 'stop', s2) <> 'INACTIVE' THEN bad := bad || ('stop not soft deleted')::text; END IF;
  IF (SELECT is_active FROM public.tr_stop WHERE stop_id = s2) THEN bad := bad || ('stop still active')::text; END IF;
  IF public.tr_delete(tk_a, 'vehicle', v1) <> 'INACTIVE' THEN bad := bad || ('vehicle not inactive')::text; END IF;
  IF public.tr_delete(tk_a, 'staff', st) <> 'RELIEVED' THEN bad := bad || ('staff not relieved')::text; END IF;
  IF public.tr_delete(tk_a, 'vehicle_doc', d1) <> 'DELETED' THEN bad := bad || ('doc not deleted')::text; END IF;
  IF public.tr_delete(tk_a, 'stage_fee', f1) <> 'DELETED' THEN bad := bad || ('fee not deleted')::text; END IF;
  n := n + 7;

  -- 7. fees follow the session's year
  f1 := public.tr_save(tk_a, 'stage_fee', jsonb_build_object('route_id', r1, 'stage_id', g1, 'fee_id', fe, 'sem_id', sm, 'amount', 6000, 'effective_from', '2026-06-01'));
  IF jsonb_array_length(public.tr_list(tk_a, 'stage_fee', jsonb_build_object('route_id', r1))) <> 1 THEN bad := bad || ('fee missing in its year')::text; END IF;
  -- 2025-2026 has no year schema (transport20252026), so its fees cannot be read
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'stage_fee',%L)$q$, tk_old, jsonb_build_object('route_id', r1)), 'not been set up');
  IF jsonb_array_length(public.tr_list(tk_a, 'stage_fee', jsonb_build_object('route_id', r2))) <> 0 THEN bad := bad || ('fee route filter wrong')::text; END IF;
  n := n + 3;

  -- 7b. a stage fee is per semester and fee head of the school, for a stage of
  --     its route (transport_16); it has no inst_id: the route says the school
  DECLARE q text := $q$SELECT public.tr_save(%L,'stage_fee',%L)$q$; base jsonb; alien_fee bigint;
  BEGIN
    base := jsonb_build_object('route_id', r1, 'stage_id', g1, 'fee_id', fe, 'sem_id', sm, 'amount', 100, 'effective_from', '2026-08-01');
    bad := bad || pg_temp.fails(format(q, tk_a, base - 'sem_id'), 'enter the term');
    bad := bad || pg_temp.fails(format(q, tk_a, base - 'fee_id'), 'enter the fee type');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('stage_id', g2)), 'different route');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('fee_id', -1)), 'fee type was not found');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('sem_id', 32000)), 'term was not found');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('activestatus', 5)), 'active status must be');
    -- one fee per stage, service, semester and start date; a one-way fee is another
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('effective_from', '2026-06-01')), 'already has a fee for that term');
    IF public.tr_save(tk_a, 'stage_fee', base || jsonb_build_object('effective_from', '2026-06-01', 'service_type', 'PICKUP')) IS NULL
       OR jsonb_array_length(public.tr_list(tk_a, 'stage_fee', jsonb_build_object('route_id', r1, 'sem_id', sm))) <> 2 THEN
      bad := bad || ('a one-way fee next to the both-ways fee was not saved or listed')::text;
    END IF;
    -- another school's stage fee cannot be seen, changed or deleted, nor a fee put on its route
    INSERT INTO transport20262027.tr_stage_fee (route_id, stage_id, fee_id, sem_id, amount, effective_from)
      VALUES (alien, alien_stage, fe, sm, 1, '2026-06-01') RETURNING stage_fee_id INTO alien_fee;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.tr_list(tk_a, 'stage_fee')) x WHERE (x->>'stage_fee_id')::bigint = alien_fee) THEN
      bad := bad || ('stage fee list leaked another school')::text;
    END IF;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('stage_fee_id', alien_fee, 'amount', 2)), 'not found');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'stage_fee',%s)$q$, tk_a, alien_fee), 'not found');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('route_id', alien, 'stage_id', alien_stage)), 'route was not found');
    -- the semesters are the school app's own, of the same year
    IF (SELECT k.confrelid::regclass::text FROM pg_constraint k
         WHERE k.conrelid = 'transport20262027.tr_stage_fee'::regclass AND k.conname = 'tr_stage_fee_sem_id_fkey')
       IS DISTINCT FROM quote_ident(app_sch) || '.semester' THEN
      bad := bad || ('transport20262027 stage fees do not use the semesters of ' || app_sch);
    END IF;
  END;
  n := n + 13;

  -- 8. settings (defaults are only checked for a school that has not saved any)
  j := public.tr_settings_get(tk_a);
  DECLARE eta0 integer := (j->>'eta_alert_minutes')::int;
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.tr_settings WHERE inst_id = 1) AND eta0 <> 10 THEN bad := bad || ('settings default wrong')::text; END IF;
    PERFORM public.tr_settings_save(tk_a, '{"overspeed_kmph":45,"school_latitude":13.1,"inst_id":999}');
    j := public.tr_settings_get(tk_a);
    IF (j->>'overspeed_kmph')::int <> 45 OR (j->>'eta_alert_minutes')::int IS DISTINCT FROM eta0 OR (j->>'inst_id')::int <> 1 THEN
      bad := bad || ('settings save wrong: ' || j::text)::text;
    END IF;
  END;
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_settings_save(%L,'{"school_latitude":200}')$q$, tk_a), 'between -90');
  bad := bad || pg_temp.fails(format($q$SELECT public.tr_settings_save(%L,'{"overspeed_kmph":0}')$q$, tk_a), 'more than zero');
  n := n + 4;

  -- 9. lookups
  j := public.tr_lookups(tk_old);
  IF j->>'year' <> '2025-2026' THEN bad := bad || ('lookups year wrong')::text; END IF;
  n := n + 1;

  -- 10. the year and code schemas are closed to the app's role
  IF has_schema_privilege('anon', 'transport20262027', 'USAGE') THEN bad := bad || ('anon can use schema')::text; END IF;
  IF has_schema_privilege('anon', 'transport_core', 'USAGE') THEN bad := bad || ('anon can use transport_core')::text; END IF;
  IF has_function_privilege('anon', 'transport_core.save(text,text,jsonb)', 'EXECUTE') THEN bad := bad || ('anon can run transport_core.save')::text; END IF;
  IF NOT has_function_privilege('anon', 'public.tr_save(text,text,jsonb)', 'EXECUTE') THEN bad := bad || ('anon cannot run tr_save')::text; END IF;
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
              WHERE ns.nspname = 'transport20262027' AND c.relkind IN ('r','p') AND NOT c.relrowsecurity) THEN bad := bad || ('a table has no RLS')::text; END IF;
  n := n + 5;

  -- 11. the masters moved to public (transport_04) are just as closed
  FOREACH msg IN ARRAY ARRAY['tr_settings','tr_route','tr_stage','tr_stop','tr_vendor','tr_vehicle',
                             'tr_vehicle_document','tr_vehicle_gps_device','tr_vehicle_service','tr_gps_device',
                             'tr_staff','tr_staff_document'] LOOP
    IF to_regclass(format('public.%I', msg)) IS NULL THEN bad := bad || ('not moved to public: ' || msg); CONTINUE; END IF;
    IF to_regclass(format('transport20262027.%I', msg)) IS NOT NULL THEN bad := bad || ('still in transport20262027: ' || msg); END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = format('public.%I', msg)::regclass) THEN bad := bad || ('no RLS: ' || msg); END IF;
    IF has_table_privilege('anon', format('public.%I', msg), 'SELECT,INSERT,UPDATE,DELETE')
       OR has_table_privilege('authenticated', format('public.%I', msg), 'SELECT,INSERT,UPDATE,DELETE') THEN
      bad := bad || ('app role can reach public.' || msg);
    END IF;
    n := n + 1;
  END LOOP;

  -- 12. one schema per academic year
  IF transport_core.year_schema('2026-2027') IS DISTINCT FROM 'transport20262027'
     OR transport_core.year_schema('2027-28') IS DISTINCT FROM 'transport20272028'
     OR transport_core.year_schema('2099-00') IS DISTINCT FROM 'transport20992100'
     OR transport_core.year_schema('next year') IS NOT NULL THEN bad := bad || ('year_schema naming wrong')::text; END IF;
  -- a year the school app has not started has no semesters for the stage fees
  bad := bad || pg_temp.fails($q$SELECT transport_core.create_year_schema('2098-2099', '2026-2027')$q$, 'start that year in the school app first');
  -- starting a year copies the structure. 2025-2026 is in the school app
  -- (ongc20252026) but not in transport (section 7); gone with the rollback.
  IF transport_core.create_year_schema('2025-2026', '2026-2027') IS DISTINCT FROM 'transport20252026' THEN bad := bad || ('create_year_schema name wrong')::text; END IF;
  DECLARE a integer; b integer;
  BEGIN
    SELECT count(*) INTO a FROM pg_class WHERE relnamespace = 'transport20262027'::regnamespace AND relkind IN ('r','p','v') AND NOT relispartition;
    SELECT count(*) INTO b FROM pg_class WHERE relnamespace = 'transport20252026'::regnamespace AND relkind IN ('r','p','v') AND NOT relispartition;
    IF a <> b THEN bad := bad || format('new year has %s of %s tables/views', b, a); END IF;
    SELECT count(*) INTO a FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
     WHERE c.relnamespace = 'transport20262027'::regnamespace AND k.contype = 'f' AND k.conparentid = 0 AND NOT c.relispartition;
    SELECT count(*) INTO b FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
     WHERE c.relnamespace = 'transport20252026'::regnamespace AND k.contype = 'f' AND k.conparentid = 0 AND NOT c.relispartition;
    IF a <> b THEN bad := bad || format('new year has %s of %s foreign keys', b, a); END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_class f ON f.oid = k.confrelid
                WHERE c.relnamespace = 'transport20252026'::regnamespace AND k.contype = 'f'
                  AND f.relnamespace = 'transport20262027'::regnamespace) THEN bad := bad || ('new year has a key into the old year')::text; END IF;
    SELECT count(*) INTO a FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relnamespace = 'transport20262027'::regnamespace AND NOT t.tgisinternal AND t.tgparentid = 0;
    SELECT count(*) INTO b FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relnamespace = 'transport20252026'::regnamespace AND NOT t.tgisinternal AND t.tgparentid = 0;
    IF a <> b THEN bad := bad || format('new year has %s of %s triggers', b, a); END IF;
    IF EXISTS (SELECT 1 FROM pg_class c WHERE c.relnamespace = 'transport20252026'::regnamespace
                  AND c.relkind IN ('r','p') AND NOT c.relrowsecurity) THEN bad := bad || ('new year table without RLS')::text; END IF;
    IF has_schema_privilege('anon', 'transport20252026', 'USAGE') THEN bad := bad || ('anon can use the new year schema')::text; END IF;
    -- GPS devices are a master (transport_10): a new year gets no copy
    IF to_regclass('transport20252026.tr_gps_device') IS NOT NULL THEN bad := bad || ('the new year got its own GPS device table')::text; END IF;
    -- no fee snapshot on the enrolment (transport_15), in any year, old or new
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema ~ '^transport\d{8}$' AND table_name IN ('tr_student_enrollment', 'v_fee_demand')
                  AND column_name IN ('stage_fee_id', 'fee_amount', 'concession_amount', 'gross_fee', 'concession', 'net_fee'))
       OR to_regclass('transport20252026.v_fee_demand') IS NULL THEN
      bad := bad || ('the enrolment fee snapshot is back, or the new year has no v_fee_demand')::text;
    END IF;
    -- the stage fees of every year are by semester (transport_16), and a new
    -- year's follow the semesters of its own year in the school app
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema ~ '^transport\d{8}$' AND table_name = 'tr_stage_fee'
                  AND column_name IN ('inst_id', 'acad_year_id', 'fee_frequency', 'fee_head_id')) THEN
      bad := bad || ('a year schema still has the old tr_stage_fee columns')::text;
    END IF;
    IF (SELECT k.confrelid::regclass::text FROM pg_constraint k
         WHERE k.conrelid = 'transport20252026.tr_stage_fee'::regclass AND k.conname = 'tr_stage_fee_sem_id_fkey')
       IS DISTINCT FROM (SELECT quote_ident(iyrschema) || '.semester' FROM public.institutionyear WHERE iyr_id = iyr_old) THEN
      bad := bad || ('the new year''s stage fees do not use its own year''s semesters')::text;
    END IF;
    -- IDs carry on from the source year (f1 above used the 2026-2027 sequence)
    IF pg_sequence_last_value(pg_get_serial_sequence('transport20252026.tr_stage_fee', 'stage_fee_id')::regclass)
       IS DISTINCT FROM pg_sequence_last_value(pg_get_serial_sequence('transport20262027.tr_stage_fee', 'stage_fee_id')::regclass) THEN
      bad := bad || ('ids do not carry on into the new year')::text;
    END IF;
  END;
  n := n + 13;

  -- 13. GPS devices (a master in public since transport_10), the vehicle's
  --     device, driving licence, photo and attachments (transport_06 .. 08)
  DECLARE dv bigint; dv_other bigint; vv bigint;
    up text := 'https://x.supabase.co/storage/v1/object/public/InstitutionLogos/transport/';
  BEGIN
    dv := public.tr_save(tk_a, 'gps_device', '{"device_type":"HARDWARE","imei":"imei-1","sim_no":"999"}');
    IF (SELECT imei FROM public.tr_gps_device WHERE device_id = dv) <> 'IMEI-1' THEN bad := bad || ('imei not upper')::text; END IF;
    IF (SELECT created_by FROM public.tr_gps_device WHERE device_id = dv) <> u THEN bad := bad || ('device created_by missing')::text; END IF;
    vv := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'bus-08', 'registration_no', 'tn01ab9999', 'vehicle_type', 'BUS',
                                                             'seating_capacity', 30, 'ownership_type', 'OWNED', 'gps_device_id', dv));
    -- the vehicle form no longer sets the device: GPS Mapping does (section 15)
    IF (SELECT gps_device_id FROM public.tr_vehicle WHERE vehicle_id = vv) IS NOT NULL THEN bad := bad || ('the vehicle form set the gps device')::text; END IF;
    PERFORM public.tr_save(tk_a, 'vehicle_gps', jsonb_build_object('changes', jsonb_build_array(
              jsonb_build_object('vehicle_id', vv, 'device_id', dv, 'date', CURRENT_DATE))));
    IF (SELECT gps_device_id FROM public.tr_vehicle WHERE vehicle_id = vv) IS DISTINCT FROM dv THEN bad := bad || ('vehicle gps device not saved')::text; END IF;
    INSERT INTO public.tr_gps_device (inst_id, device_type) VALUES (999, 'HARDWARE') RETURNING device_id INTO dv_other;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle_gps',%L)$q$, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vv, 'device_id', dv_other, 'was_device_id', dv, 'date', CURRENT_DATE)))), 'gps device was not found');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'gps_device',%L)$q$, tk_a, '{"device_type":"HARDWARE","imei":"IMEI-1"}'), 'imei number is already');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'gps_device',%s)$q$, tk_a, dv), 'in use');
    j := public.tr_list(tk_a, 'gps_device');
    IF NOT j @> jsonb_build_array(jsonb_build_object('device_id', dv)) OR j @> jsonb_build_array(jsonb_build_object('device_id', dv_other)) THEN
      bad := bad || ('device list wrong')::text;
    END IF;
    -- a master: the same devices in every year, even one with no year schema (2025-2026)
    IF NOT public.tr_list(tk_old, 'gps_device') @> jsonb_build_array(jsonb_build_object('device_id', dv)) THEN
      bad := bad || ('GPS devices not shared by every year')::text;
    END IF;
    IF (SELECT count(*) FROM pg_constraint k
         WHERE k.confrelid = 'public.tr_gps_device'::regclass AND k.contype = 'f'
           AND k.conname IN ('tr_vehicle_gps_device_id_fkey', 'tr_vehicle_gps_device_device_id_fkey')) <> 2 THEN
      bad := bad || ('the vehicle links do not point at public.tr_gps_device')::text;
    END IF;
    PERFORM public.tr_save(tk_a, 'staff', jsonb_build_object('staff_id', st, 'license_number', 'tn01 2020', 'license_type', 'hmv',
                                                             'license_valid_till', '2030-05-01', 'photo_url', up || 'staff/1.jpg'));
    IF (SELECT license_number || '/' || license_type || '/' || license_valid_till FROM public.tr_staff WHERE staff_id = st) <> 'TN01 2020/HMV/2030-05-01' THEN
      bad := bad || ('licence not saved')::text;
    END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'staff',%L)$q$, tk_a, jsonb_build_object('staff_id', st, 'photo_url', 'http://x.co/a.jpg')), 'attached file is not valid');
    PERFORM public.tr_save(tk_a, 'vehicle_doc', jsonb_build_object('vehicle_doc_id', d2, 'file_url', up || 'vehicle-docs/1_RC.pdf'));
    IF (SELECT file_url FROM public.tr_vehicle_document WHERE vehicle_doc_id = d2) IS DISTINCT FROM up || 'vehicle-docs/1_RC.pdf' THEN bad := bad || ('doc file not saved')::text; END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle_doc',%L)$q$, tk_a, jsonb_build_object('vehicle_doc_id', d2, 'file_url', 'https://evil.example.com/x.pdf')), 'attached file is not valid');
  END;
  n := n + 14;

  -- 14. trip schedules with their stops (tr_trip_schedule + tr_trip_schedule_stop),
  --     and the day's trip made from them (tr_trip_stop)
  DECLARE sc bigint; s3 bigint; s4 bigint; vb bigint; base jsonb; two jsonb;
  BEGIN
    s3 := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', r1, 'stage_id', g1, 'stop_seq', 3, 'stop_name', 'Lake View', 'latitude', 13.07, 'longitude', 80.29));
    s4 := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', r2, 'stage_id', g2, 'stop_seq', 1, 'stop_name', 'South Gate', 'latitude', 13.01, 'longitude', 80.21));
    vb := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-bus-1', 'registration_no', 'zt01zz0001', 'vehicle_type', 'BUS',
                                                             'seating_capacity', 40, 'ownership_type', 'OWNED'));
    base := jsonb_build_object('schedule_code', ' zt-sch-1 ', 'schedule_name', 'Morning Pickup', 'route_id', r1, 'direction', 'PICKUP',
                               'vehicle_id', vb, 'planned_start', '07:00', 'planned_end', '08:00', 'run_days', '[3,1,1,2]'::jsonb,
                               'effective_from', '2026-06-01');
    two := jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '07:05'),
                             jsonb_build_object('stop_id', s3, 'planned_time', '07:20', 'halt_minutes', 2));
    sc := public.tr_save(tk_a, 'schedule', base || jsonb_build_object('stops', two));
    IF (SELECT schedule_code || ' ' || run_days::text FROM transport20262027.tr_trip_schedule WHERE schedule_id = sc) IS DISTINCT FROM 'ZT-SCH-1 {1,2,3}' THEN
      bad := bad || ('schedule code or days not cleaned')::text;
    END IF;
    IF (SELECT string_agg(format('%s:%s:%s:%s:%s', stop_id, visit_seq, planned_time, halt_minutes, route_id), ',' ORDER BY visit_seq)
          FROM transport20262027.tr_trip_schedule_stop WHERE schedule_id = sc)
       IS DISTINCT FROM format('%s:1:07:05:00:1:%s,%s:2:07:20:00:2:%s', s1, r1, s3, r1) THEN
      bad := bad || ('schedule stops not saved in visit order')::text;
    END IF;
    j := public.tr_list(tk_a, 'schedule', jsonb_build_object('schedule_id', sc));
    IF jsonb_array_length(j) <> 1 OR jsonb_array_length(j->0->'stops') <> 2 OR (j->0->'stops'->1->>'stop_id')::bigint <> s3 THEN
      bad := bad || ('schedule list has the wrong stops')::text;
    END IF;
    n := n + 3;

    -- readable errors
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || '{"schedule_code":"zt-sch-2"}'), 'choose the stops');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || '{"schedule_code":"zt-sch-2","stops":[]}'), 'at least one stop');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('stops', two)), 'schedule code is already used');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2', 'planned_end', '06:00', 'stops', two)), 'end time must be after');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2',
             'stops', jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '07:30'), jsonb_build_object('stop_id', s3, 'planned_time', '07:10')))), 'visit order');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2',
             'stops', jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '08:30')))), 'between the start time and the end time');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2',
             'stops', jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '07:05'), jsonb_build_object('stop_id', s1, 'planned_time', '07:10')))), 'listed twice');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2',
             'stops', jsonb_build_array(jsonb_build_object('stop_id', s4, 'planned_time', '07:05')))), 'not on this route');
    -- s2 was switched off in section 6
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2',
             'stops', jsonb_build_array(jsonb_build_object('stop_id', s2, 'planned_time', '07:05')))), 'switched off');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2', 'run_days', '[]'::jsonb, 'stops', two)), 'days this schedule runs');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2', 'run_days', '[8]'::jsonb, 'stops', two)), 'weekdays');
    -- v1 was made inactive in section 6
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2', 'vehicle_id', v1, 'stops', two)), 'vehicle is not active');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2', 'direction', 'BOTH', 'stops', two)), 'pickup or drop');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, base || jsonb_build_object('schedule_code', 'zt-sch-2', 'route_id', alien, 'stops', two)), 'route was not found');
    n := n + 14;

    -- an edit replaces the stops, a plain edit keeps them, a new route needs its own
    PERFORM public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_id', sc, 'stops', jsonb_build_array(jsonb_build_object('stop_id', s3, 'planned_time', '07:30'))));
    IF (SELECT count(*) FROM transport20262027.tr_trip_schedule_stop WHERE schedule_id = sc) <> 1 THEN bad := bad || ('schedule stops not replaced')::text; END IF;
    PERFORM public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_id', sc, 'schedule_name', 'Renamed'));
    IF (SELECT count(*) FROM transport20262027.tr_trip_schedule_stop WHERE schedule_id = sc) <> 1 THEN bad := bad || ('plain edit lost the stops')::text; END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, jsonb_build_object('schedule_id', sc, 'route_id', r2)), 'choose the stops');
    PERFORM public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_id', sc, 'route_id', r2,
                                                               'stops', jsonb_build_array(jsonb_build_object('stop_id', s4, 'planned_time', '07:15'))));
    IF (SELECT route_id FROM transport20262027.tr_trip_schedule WHERE schedule_id = sc) IS DISTINCT FROM r2
       OR (SELECT string_agg(stop_id || '@' || route_id, ',') FROM transport20262027.tr_trip_schedule_stop WHERE schedule_id = sc) IS DISTINCT FROM s4 || '@' || r2 THEN
      bad := bad || ('schedule route change not saved')::text;
    END IF;
    n := n + 4;

    -- the day's trip gets the schedule's stops (2026-11-16 is a Monday)
    BEGIN
      PERFORM transport_core.fn_generate_trips(1, '2026-11-16');
      IF (SELECT string_agg(ts.stop_id || '@' || ts.visit_seq, ',' ORDER BY ts.visit_seq)
            FROM transport20262027.tr_trip t JOIN transport20262027.tr_trip_stop ts ON ts.trip_id = t.trip_id
           WHERE t.schedule_id = sc AND t.trip_date = '2026-11-16' AND ts.planned_at = '2026-11-16'::date + '07:15'::time)
         IS DISTINCT FROM s4 || '@1' THEN
        bad := bad || ('the day''s trip did not get the schedule stops')::text;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      bad := bad || ('fn_generate_trips failed: ' || SQLERRM);
    END;
    n := n + 1;

    -- refused while a student uses it; then switched off, not removed
    INSERT INTO transport20262027.tr_student_enrollment (inst_id, acad_year_id, student_id, route_id, service_type, pickup_stop_id, pickup_schedule_id, fee_stage_id, start_date)
    VALUES (1, iyr_now, -1, r2, 'PICKUP', s4, sc, g2, '2026-06-01');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'schedule',%s)$q$, tk_a, sc), 'still use this schedule');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_a, jsonb_build_object('schedule_id', sc, 'route_id', r1,
             'stops', jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '07:05')))), 'students are enrolled');
    IF (SELECT count(*) FROM transport20262027.tr_trip_schedule_stop WHERE schedule_id = sc AND stop_id = s4) <> 1 THEN
      bad := bad || ('a refused save lost the stops')::text;
    END IF;
    DELETE FROM transport20262027.tr_student_enrollment WHERE pickup_schedule_id = sc;
    -- two statements: one statement reads the row as it was before its own tr_delete
    IF public.tr_delete(tk_a, 'schedule', sc) <> 'INACTIVE' THEN bad := bad || ('schedule delete did not say INACTIVE')::text; END IF;
    IF (SELECT is_active FROM transport20262027.tr_trip_schedule WHERE schedule_id = sc) THEN bad := bad || ('schedule still active after delete')::text; END IF;
    n := n + 5;

    -- the Trip Schedules menu is needed (the Accountant role here has no transport menus)
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'schedule')$q$, tk_ac), 'no access');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'schedule',%L)$q$, tk_ac, base || jsonb_build_object('schedule_code', 'zt-sch-3', 'stops', two)), 'no access');
    n := n + 2;
  END;

  -- 15. GPS Mapping: the device on each vehicle, with its history
  --     (tr_vehicle_gps_device, transport_11), saved as one batch
  DECLARE da bigint; db bigint; dc bigint; dx bigint; va bigint; vb bigint; vs bigint; d0 date := CURRENT_DATE;
    q text := $q$SELECT public.tr_save(%L,'vehicle_gps',%L)$q$;
  BEGIN
    da := public.tr_save(tk_a, 'gps_device', '{"device_type":"HARDWARE","imei":"zt-gps-a"}');
    db := public.tr_save(tk_a, 'gps_device', '{"device_type":"HARDWARE","imei":"zt-gps-b"}');
    dc := public.tr_save(tk_a, 'gps_device', '{"device_type":"MOBILE_APP","imei":"zt-gps-c","is_active":false}');
    INSERT INTO public.tr_gps_device (inst_id, device_type) VALUES (999, 'HARDWARE') RETURNING device_id INTO dx;
    va := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-gps-1', 'registration_no', 'zt01gp0001', 'vehicle_type', 'BUS',
                                                             'seating_capacity', 40, 'ownership_type', 'OWNED', 'has_gps', false));
    vb := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-gps-2', 'registration_no', 'zt01gp0002', 'vehicle_type', 'VAN',
                                                             'seating_capacity', 12, 'ownership_type', 'OWNED'));
    vs := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-gps-3', 'registration_no', 'zt01gp0003', 'vehicle_type', 'VAN',
                                                             'seating_capacity', 12, 'ownership_type', 'OWNED', 'status', 'SOLD'));

    -- a device goes on: its history row, and the vehicle shows it with GPS turned on
    IF public.tr_save(tk_a, 'vehicle_gps', jsonb_build_object('changes', jsonb_build_array(
         jsonb_build_object('vehicle_id', va, 'device_id', da, 'date', d0 - 10)))) <> 1 THEN
      bad := bad || ('gps save did not count its vehicles')::text;
    END IF;
    IF (SELECT count(*) FROM public.tr_vehicle_gps_device
         WHERE vehicle_id = va AND device_id = da AND installed_on = d0 - 10 AND removed_on IS NULL AND created_by = u) <> 1 THEN
      bad := bad || ('device did not go on')::text;
    END IF;
    IF (SELECT gps_device_id = da AND has_gps FROM public.tr_vehicle WHERE vehicle_id = va) IS NOT TRUE THEN
      bad := bad || ('vehicle does not show its new device')::text;
    END IF;
    n := n + 3;

    -- readable errors
    bad := bad || pg_temp.fails(format(q, tk_a, '{"changes":[]}'), 'nothing to save');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', va, 'date', d0)))), 'changed by someone else');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vb, 'device_id', db, 'date', d0 + 5)))), 'cannot be in the future');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vb, 'device_id', db)))), 'choose the date');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vb, 'device_id', db, 'date', d0), jsonb_build_object('vehicle_id', vb, 'date', d0)))), 'listed twice');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vb, 'device_id', da, 'date', d0)))), 'is on zt-gps-1');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vb, 'device_id', dc, 'date', d0)))), 'switched off');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vb, 'device_id', dx, 'date', d0)))), 'gps device was not found');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vs, 'device_id', db, 'date', d0)))), 'cannot go on it');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', va, 'was_device_id', da, 'date', d0 - 20)))), 'the day its gps device went on');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'vehicle',%L)$q$, tk_a, jsonb_build_object('vehicle_id', va, 'has_gps', false)),
             'take it off in gps mapping');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'vehicle_gps',%s)$q$, tk_a,
             (SELECT vgd_id FROM public.tr_vehicle_gps_device WHERE vehicle_id = va)), 'history is kept');
    -- the Vehicles menu is needed
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'vehicle_gps')$q$, tk_ac), 'no access');
    bad := bad || pg_temp.fails(format(q, tk_ac, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vb, 'device_id', db, 'date', d0)))), 'no access');
    n := n + 14;

    -- a device moves to another vehicle in one save: off one and on the other the same day,
    -- whatever the order of the rows
    PERFORM public.tr_save(tk_a, 'vehicle_gps', jsonb_build_object('changes', jsonb_build_array(
              jsonb_build_object('vehicle_id', vb, 'device_id', da, 'date', d0 - 4),
              jsonb_build_object('vehicle_id', va, 'was_device_id', da, 'date', d0 - 4))));
    IF (SELECT gps_device_id FROM public.tr_vehicle WHERE vehicle_id = va) IS NOT NULL
       OR (SELECT gps_device_id FROM public.tr_vehicle WHERE vehicle_id = vb) IS DISTINCT FROM da THEN
      bad := bad || ('device did not move to the other vehicle')::text;
    END IF;
    IF (SELECT string_agg(format('%s:%s:%s', CASE vehicle_id WHEN va THEN 'va' WHEN vb THEN 'vb' END, installed_on - d0,
                                 COALESCE((removed_on - d0)::text, 'on')), ',' ORDER BY installed_on)
          FROM public.tr_vehicle_gps_device WHERE device_id = da) IS DISTINCT FROM 'va:-10:-4,vb:-4:on' THEN
      bad := bad || ('device history after the move is wrong')::text;
    END IF;
    n := n + 2;

    -- the day a device went on can be corrected, but not into the history before it
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('changes', jsonb_build_array(
             jsonb_build_object('vehicle_id', vb, 'device_id', da, 'was_device_id', da, 'date', d0 - 6)))), 'earlier gps history');
    PERFORM public.tr_save(tk_a, 'vehicle_gps', jsonb_build_object('changes', jsonb_build_array(
              jsonb_build_object('vehicle_id', vb, 'device_id', da, 'was_device_id', da, 'date', d0 - 3))));
    IF (SELECT installed_on FROM public.tr_vehicle_gps_device WHERE vehicle_id = vb AND removed_on IS NULL) IS DISTINCT FROM d0 - 3 THEN
      bad := bad || ('installed date not corrected')::text;
    END IF;
    n := n + 2;

    -- two vehicles swap devices in one save; the list gives a vehicle's history, latest first
    PERFORM public.tr_save(tk_a, 'vehicle_gps', jsonb_build_object('changes', jsonb_build_array(
              jsonb_build_object('vehicle_id', va, 'device_id', db, 'date', d0 - 2))));
    PERFORM public.tr_save(tk_a, 'vehicle_gps', jsonb_build_object('changes', jsonb_build_array(
              jsonb_build_object('vehicle_id', va, 'device_id', da, 'was_device_id', db, 'date', d0 - 1),
              jsonb_build_object('vehicle_id', vb, 'device_id', db, 'was_device_id', da, 'date', d0 - 1))));
    IF (SELECT string_agg(vehicle_id || '=' || gps_device_id, ',' ORDER BY vehicle_id) FROM public.tr_vehicle WHERE vehicle_id IN (va, vb))
       IS DISTINCT FROM format('%s=%s,%s=%s', va, da, vb, db) THEN
      bad := bad || ('devices did not swap')::text;
    END IF;
    j := public.tr_list(tk_a, 'vehicle_gps', jsonb_build_object('vehicle_id', va));
    IF jsonb_array_length(j) <> 3 OR (j->0->>'device_id')::bigint <> da OR j->0->>'removed_on' IS NOT NULL THEN
      bad := bad || ('vehicle gps history list is wrong')::text;
    END IF;
    n := n + 2;
  END;

  -- 16. duty roster (tr_duty_assignment): who drives and attends a schedule,
  --     and the day's trip crew made from it (tr_trip_staff)
  DECLARE sa bigint; sb bigint; vd bigint; dr1 bigint; dr2 bigint; at1 bigint; du bigint; sched jsonb;
    q text := $q$SELECT public.tr_save(%L,'duty',%L)$q$;
  BEGIN
    vd := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-duty-1', 'registration_no', 'zt01du0001', 'vehicle_type', 'BUS',
                                                             'seating_capacity', 40, 'ownership_type', 'OWNED'));
    sched := jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'vehicle_id', vd, 'run_days', '[1,2,3,4,5,6]'::jsonb, 'effective_from', '2026-06-01',
                                'stops', jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '07:45')));
    -- A runs 07:00-08:00 and B 07:30-08:30, so one person cannot be on both
    sa := public.tr_save(tk_a, 'schedule', sched || '{"schedule_code":"zt-duty-a","schedule_name":"Duty A","planned_start":"07:00","planned_end":"08:00"}');
    sb := public.tr_save(tk_a, 'schedule', sched || '{"schedule_code":"zt-duty-b","schedule_name":"Duty B","planned_start":"07:30","planned_end":"08:30"}');
    dr1 := public.tr_save(tk_a, 'staff', '{"staff_code":"zt-du-d1","staff_type":"DRIVER","full_name":"Driver One","mobile":"9876500001"}');
    dr2 := public.tr_save(tk_a, 'staff', '{"staff_code":"zt-du-d2","staff_type":"DRIVER","full_name":"Driver Two","mobile":"9876500002"}');
    at1 := public.tr_save(tk_a, 'staff', '{"staff_code":"zt-du-a1","staff_type":"ATTENDER","full_name":"Attender One","mobile":"9876500003"}');

    -- saved as sent; is_primary and inst_id are not the caller's to set
    du := public.tr_save(tk_a, 'duty', jsonb_build_object('schedule_id', sa, 'staff_id', dr1, 'duty_role', 'DRIVER', 'effective_from', '2026-06-01',
                                                          'is_primary', false, 'inst_id', 999));
    IF (SELECT format('%s:%s:%s:%s:%s:%s', schedule_id, staff_id, duty_role, is_primary, inst_id, created_by)
          FROM transport20262027.tr_duty_assignment WHERE duty_id = du) IS DISTINCT FROM format('%s:%s:DRIVER:t:1:%s', sa, dr1, u) THEN
      bad := bad || ('duty not saved as sent')::text;
    END IF;
    PERFORM public.tr_save(tk_a, 'duty', jsonb_build_object('schedule_id', sa, 'staff_id', at1, 'duty_role', 'ATTENDER', 'effective_from', '2026-06-01'));
    IF jsonb_array_length(public.tr_list(tk_a, 'duty', jsonb_build_object('schedule_id', sa))) <> 2 THEN bad := bad || ('duty list is wrong')::text; END IF;
    n := n + 2;

    -- readable errors
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', sb, 'staff_id', at1, 'duty_role', 'DRIVER', 'effective_from', '2026-06-01')), 'not a driver');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', sa, 'staff_id', dr2, 'duty_role', 'DRIVER', 'effective_from', '2026-07-01')),
             'already has a driver, driver one');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', sa, 'staff_id', at1, 'duty_role', 'SUPERVISOR', 'effective_from', '2026-07-01')),
             'already has a duty on this schedule');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', sb, 'staff_id', dr1, 'duty_role', 'DRIVER', 'effective_from', '2026-06-01')),
             'already on schedule zt-duty-a (7:00 am to 8:00 am)');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', sb, 'staff_id', dr2, 'duty_role', 'DRIVER', 'effective_from', '2026-07-01',
                                                                   'effective_to', '2026-06-01')), 'cannot be before');
    -- st was relieved in section 6
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', sb, 'staff_id', st, 'duty_role', 'ATTENDER', 'effective_from', '2026-06-01')), 'is relieved');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', sb, 'staff_id', dr2, 'effective_from', '2026-06-01')), 'enter the duty');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', sb, 'staff_id', dr2, 'duty_role', 'CLEANER', 'effective_from', '2026-06-01')), 'choose the duty');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', -1, 'staff_id', dr2, 'duty_role', 'DRIVER', 'effective_from', '2026-06-01')), 'schedule was not found');
    -- the Duty Roster menu is needed
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'duty')$q$, tk_ac), 'no access');
    bad := bad || pg_temp.fails(format(q, tk_ac, jsonb_build_object('schedule_id', sb, 'staff_id', dr2, 'duty_role', 'DRIVER', 'effective_from', '2026-06-01')), 'no access');
    n := n + 11;

    -- an ended duty frees the schedule and the driver from the next day
    PERFORM public.tr_save(tk_a, 'duty', jsonb_build_object('duty_id', du, 'effective_to', '2026-06-30'));
    PERFORM public.tr_save(tk_a, 'duty', jsonb_build_object('schedule_id', sa, 'staff_id', dr2, 'duty_role', 'DRIVER', 'effective_from', '2026-07-01'));
    PERFORM public.tr_save(tk_a, 'duty', jsonb_build_object('schedule_id', sb, 'staff_id', dr1, 'duty_role', 'DRIVER', 'effective_from', '2026-07-01'));
    IF (SELECT count(*) FROM transport20262027.tr_duty_assignment WHERE schedule_id IN (sa, sb) AND duty_role = 'DRIVER') <> 3 THEN
      bad := bad || ('an ended duty did not free the schedule or the driver')::text;
    END IF;
    n := n + 1;

    -- the day's trip takes that day's duties as its crew (2026-11-16 is a Monday)
    BEGIN
      PERFORM transport_core.fn_generate_trips(1, '2026-11-16');
      IF (SELECT string_agg(ts.staff_id || ':' || ts.duty_role, ',' ORDER BY ts.duty_role)
            FROM transport20262027.tr_trip t JOIN transport20262027.tr_trip_staff ts ON ts.trip_id = t.trip_id
           WHERE t.schedule_id = sa AND t.trip_date = '2026-11-16') IS DISTINCT FROM format('%s:ATTENDER,%s:DRIVER', at1, dr2) THEN
        bad := bad || ('the day''s trip did not get its crew from the duty roster')::text;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      bad := bad || ('fn_generate_trips failed: ' || SQLERRM);
    END;
    n := n + 1;

    -- a staff member with an open duty stays; a duty is removed (two statements:
    -- one statement reads the row as it was before its own tr_delete); a
    -- switched-off schedule takes no new duty
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'staff',%s)$q$, tk_a, at1), 'still open');
    IF public.tr_delete(tk_a, 'duty', du) <> 'DELETED' THEN bad := bad || ('duty delete did not say DELETED')::text; END IF;
    IF EXISTS (SELECT 1 FROM transport20262027.tr_duty_assignment WHERE duty_id = du) THEN bad := bad || ('duty not removed')::text; END IF;
    PERFORM public.tr_delete(tk_a, 'schedule', sb);
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('schedule_id', sb, 'staff_id', at1, 'duty_role', 'ATTENDER', 'effective_from', '2026-07-01')),
             'switched off');
    n := n + 4;
  END;

  -- 17. student enrollment (tr_student_enrollment): the students on a route,
  --     saved as the screen's batch, and the day's trip that expects them.
  --     The students are the main app's, from the year's own schema.
  DECLARE ysch text; ids bigint[]; ya bigint; yb bigint; yc bigint; who text; g3 bigint; s3 bigint; s4 bigint; s5 bigint; vz bigint; sz bigint;
    ea bigint; up timestamptz; q text := $q$SELECT public.tr_save(%L,'enrollment',%L)$q$;
  BEGIN
    SELECT iyrschema INTO ysch FROM public.institutionyear WHERE iyr_id = iyr_now;
    -- the stops section 14 added: Lake View on R5, South Gate on R6
    SELECT stop_id INTO s3 FROM public.tr_stop WHERE route_id = r1 AND stop_seq = 3;
    SELECT stop_id INTO s4 FROM public.tr_stop WHERE route_id = r2 AND stop_seq = 1;
    -- three active students of the year with no transport yet
    EXECUTE format('SELECT array_agg(stu_id ORDER BY stu_id) FROM (SELECT s.stu_id FROM %I.students s WHERE s.ins_id = 1 AND s.activestatus = 1
                      AND NOT EXISTS (SELECT 1 FROM transport20262027.tr_student_enrollment e WHERE e.student_id = s.stu_id AND e.status = ''ACTIVE'')
                     ORDER BY s.stu_id LIMIT 3) x', ysch) INTO ids;
    IF cardinality(ids) IS DISTINCT FROM 3 THEN RAISE EXCEPTION 'TESTS_FAILED: section 17 needs 3 active students in %.students', ysch; END IF;
    ya := ids[1]; yb := ids[2]; yc := ids[3];
    EXECUTE format('SELECT stuadmno FROM %I.students WHERE stu_id = $1', ysch) INTO who USING yc;
    -- R5 gets a second stage with a farther stop
    g3 := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', r1, 'stage_no', 2, 'stage_name', 'Stage 2'));
    s5 := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', r1, 'stage_id', g3, 'stop_seq', 5, 'stop_name', 'Far End', 'latitude', 13.09, 'longitude', 80.3));

    -- two new students: Both (picked up in stage 1, dropped in stage 2) and Pickup only (its drop stop is cleared)
    IF public.tr_save(tk_a, 'enrollment', jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
         jsonb_build_object('student_id', ya, 'service_type', 'BOTH', 'pickup_stop_id', s1, 'drop_stop_id', s5, 'start_date', '2026-06-01'),
         jsonb_build_object('student_id', yb, 'service_type', 'PICKUP', 'pickup_stop_id', s3, 'drop_stop_id', s5, 'start_date', '2026-06-01')))) <> 2 THEN
      bad := bad || ('enrollment save did not count its rows')::text;
    END IF;
    SELECT enrollment_id INTO ea FROM transport20262027.tr_student_enrollment WHERE student_id = ya AND status = 'ACTIVE';
    IF (SELECT format('%s:%s:%s:%s:%s:%s', route_id, fee_stage_id, acad_year_id, status, created_by, inst_id)
          FROM transport20262027.tr_student_enrollment WHERE enrollment_id = ea)
       IS DISTINCT FROM format('%s:%s:%s:ACTIVE:%s:1', r1, g3, iyr_now, u) THEN
      bad := bad || ('enrollment not saved with the farther stop''s stage and the session year')::text;
    END IF;
    IF (SELECT drop_stop_id IS NULL AND fee_stage_id = g1 FROM transport20262027.tr_student_enrollment WHERE student_id = yb AND status = 'ACTIVE') IS NOT TRUE THEN
      bad := bad || ('a pickup-only enrollment kept its drop stop, or got the wrong stage')::text;
    END IF;
    j := public.tr_list(tk_a, 'enrollment', jsonb_build_object('route_id', r1));
    IF jsonb_array_length(j) <> 2 OR j->0->>'stuname' IS NULL OR j->0->>'stuadmno' IS NULL OR j->0->>'stuclass' IS NULL THEN
      bad := bad || ('the enrollment list lacks the students'' details')::text;
    END IF;
    j := public.tr_students(tk_a);
    IF (SELECT count(*) FROM jsonb_array_elements(j->'students') x WHERE (x->>'stu_id')::bigint = ya AND x->>'route_code' = 'R5') <> 1
       OR j->>'year_from' IS DISTINCT FROM (SELECT iyrstadate::text FROM public.institutionyear WHERE iyr_id = iyr_now) THEN
      bad := bad || ('the student list does not show the route or the year')::text;
    END IF;
    n := n + 5;

    -- readable errors, each naming the student
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'BOTH', 'pickup_stop_id', s1, 'start_date', '2026-06-01')))), 'choose the drop stop of ' || who);
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'PICKUP', 'pickup_stop_id', s4, 'start_date', '2026-06-01')))), 'is not on route r5');
    -- s2 was switched off in section 6
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'PICKUP', 'pickup_stop_id', s2, 'start_date', '2026-06-01')))), 'is switched off');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'PICKUP', 'pickup_stop_id', s1, 'start_date', '2026-07-01', 'end_date', '2026-06-01')))),
             'cannot be before the start date');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'PICKUP', 'pickup_stop_id', s1, 'start_date', '2025-06-01')))), 'within the academic year');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'BUS', 'pickup_stop_id', s1, 'start_date', '2026-06-01')))), 'choose the trip type');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'PICKUP', 'pickup_stop_id', s1, 'start_date', '2026-06-01', 'status', 'GONE')))), 'choose the status');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'PICKUP', 'pickup_stop_id', s1)))), 'choose the start date');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'PICKUP', 'pickup_stop_id', s1, 'start_date', '2026-06-01'),
             jsonb_build_object('student_id', yc, 'service_type', 'PICKUP', 'pickup_stop_id', s3, 'start_date', '2026-06-01')))), 'listed twice');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', -1, 'service_type', 'PICKUP', 'pickup_stop_id', s1, 'start_date', '2026-06-01')))), 'student was not found');
    -- one active enrollment a year: ya is on R5, so not on R6 too
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r2, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', ya, 'service_type', 'PICKUP', 'pickup_stop_id', s4, 'start_date', '2026-06-01')))), 'already enrolled on route r5');
    -- never deleted: a student who stops is Cancelled
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'enrollment',%s)$q$, tk_a, ea), 'set the status to cancelled');
    -- the Student Enrollment menu is needed
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'enrollment')$q$, tk_ac), 'no access');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_students(%L)$q$, tk_ac), 'no access');
    bad := bad || pg_temp.fails(format(q, tk_ac, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('student_id', yc, 'service_type', 'PICKUP', 'pickup_stop_id', s1, 'start_date', '2026-06-01')))), 'no access');
    n := n + 15;

    -- an edit someone else made first is refused; then ya moves to R6
    -- (Cancelled on R5 from 31-10-2026, added on R6 from 01-11-2026)
    SELECT updated_at INTO up FROM transport20262027.tr_student_enrollment WHERE enrollment_id = ea;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', ea, 'student_id', ya, 'service_type', 'BOTH', 'pickup_stop_id', s1, 'drop_stop_id', s5,
                                'start_date', '2026-06-01', 'status', 'CANCELLED', 'updated_at', up - interval '1 second')))), 'changed by someone else');
    PERFORM public.tr_save(tk_a, 'enrollment', jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', ea, 'student_id', ya, 'service_type', 'BOTH', 'pickup_stop_id', s1, 'drop_stop_id', s5,
                                 'start_date', '2026-06-01', 'end_date', '2026-10-31', 'status', 'CANCELLED', 'updated_at', up))));
    PERFORM public.tr_save(tk_a, 'enrollment', jsonb_build_object('route_id', r2, 'rows', jsonb_build_array(
              jsonb_build_object('student_id', ya, 'service_type', 'DROP', 'drop_stop_id', s4, 'start_date', '2026-11-01'))));
    IF (SELECT string_agg(route_id || ':' || status, ',' ORDER BY enrollment_id) FROM transport20262027.tr_student_enrollment WHERE student_id = ya)
       IS DISTINCT FROM format('%s:CANCELLED,%s:ACTIVE', r1, r2) THEN
      bad := bad || ('the student did not move to the other route')::text;
    END IF;
    n := n + 2;

    -- the day's pickup trip on R5 expects yb at its pickup stop (2026-11-17 is a Tuesday)
    BEGIN
      vz := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-enr-1', 'registration_no', 'zt01en0001', 'vehicle_type', 'BUS',
                                                               'seating_capacity', 40, 'ownership_type', 'OWNED'));
      sz := public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_code', 'zt-enr-p', 'schedule_name', 'Enrollment Pickup', 'route_id', r1,
               'direction', 'PICKUP', 'vehicle_id', vz, 'planned_start', '06:30', 'planned_end', '06:55', 'run_days', '[1,2,3,4,5,6]'::jsonb,
               'effective_from', '2026-06-01', 'stops', jsonb_build_array(jsonb_build_object('stop_id', s3, 'planned_time', '06:40'))));
      -- R5 also has section 16's pickup: with two vehicles a student rides the one allotted (Vehicle Allotment)
      UPDATE transport20262027.tr_student_enrollment SET pickup_schedule_id = sz WHERE route_id = r1 AND student_id = yb AND status = 'ACTIVE';
      PERFORM transport_core.fn_generate_trips(1, '2026-11-17');
      IF (SELECT string_agg(ts.student_id || '@' || ts.stop_id || ':' || ts.status, ',')
            FROM transport20262027.tr_trip t JOIN transport20262027.tr_trip_student ts ON ts.trip_id = t.trip_id
           WHERE t.schedule_id = sz AND t.trip_date = '2026-11-17') IS DISTINCT FROM format('%s@%s:EXPECTED', yb, s3) THEN
        bad := bad || ('the day''s trip does not expect the enrolled student')::text;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      bad := bad || ('enrollment trip check failed: ' || SQLERRM);
    END;
    n := n + 1;
  END;

  -- 17b. staff enrollment (tr_staff_enrollment, transport_23): the staff on a
  --      route, saved as the Staff Enrollment tab's batch. Only staff of the
  --      year (staffmast) who are active and whose transport is BUS are
  --      offered, added, or made Active again. Its own two routes, so the
  --      students of section 17 do not count.
  DECLARE ids numeric[]; fa numeric; fb numeric; fc numeric; who text; rs bigint; rt bigint; ga bigint; gb bigint; gt bigint;
    pa bigint; pb bigint; pt bigint; ea bigint; eb bigint; up timestamptz; q text := $q$SELECT public.tr_save(%L,'staff_enrollment',%L)$q$;
  BEGIN
    IF NOT transport_core._staff_ready(app_sch, 'transport20262027') THEN
      RAISE EXCEPTION 'TESTS_FAILED: section 17b needs %.staffmast with transportreq, and transport20262027.tr_staff_enrollment (transport_23)', app_sch;
    END IF;
    -- three staff of the year: fa and fb may travel (active, BUS), fc may not (OWN); none on a route
    EXECUTE format('SELECT array_agg(staf_id ORDER BY staf_id) FROM (SELECT m.staf_id FROM %I.staffmast m
                      JOIN public.schstaff s ON s.staf_id = m.staf_id WHERE s.ins_id = 1 ORDER BY m.staf_id LIMIT 3) x', app_sch) INTO ids;
    IF cardinality(ids) IS DISTINCT FROM 3 THEN RAISE EXCEPTION 'TESTS_FAILED: section 17b needs 3 staff of school 1 in %.staffmast', app_sch; END IF;
    fa := ids[1]; fb := ids[2]; fc := ids[3];
    EXECUTE format('UPDATE %I.staffmast SET is_active = true, transportreq = CASE WHEN staf_id = $3 THEN ''OWN'' ELSE ''BUS'' END
                     WHERE staf_id IN ($1, $2, $3)', app_sch) USING fa, fb, fc;
    UPDATE transport20262027.tr_staff_enrollment SET status = 'CANCELLED' WHERE staf_id IN (fa, fb, fc) AND status = 'ACTIVE';
    EXECUTE format('SELECT emp_code FROM %I.staffmast WHERE staf_id = $1', app_sch) INTO who USING fb;
    -- a route of two stages (its far stop in stage 2), and a second route
    rs := public.tr_save(tk_a, 'route', '{"route_code":"zt-senr1","route_name":"Staff Line"}');
    ga := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rs, 'stage_no', 1, 'stage_name', 'Near'));
    gb := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rs, 'stage_no', 2, 'stage_name', 'Far'));
    pa := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', rs, 'stage_id', ga, 'stop_seq', 1, 'stop_name', 'Staff Gate', 'latitude', 13.01, 'longitude', 80.21));
    pb := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', rs, 'stage_id', gb, 'stop_seq', 2, 'stop_name', 'Staff Far End', 'latitude', 13.02, 'longitude', 80.22));
    rt := public.tr_save(tk_a, 'route', '{"route_code":"zt-senr2","route_name":"Staff Line Two"}');
    gt := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rt, 'stage_no', 1, 'stage_name', 'Near'));
    pt := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', rt, 'stage_id', gt, 'stop_seq', 1, 'stop_name', 'Staff Corner', 'latitude', 13.03, 'longitude', 80.23));

    -- only the staff who may travel are offered
    j := public.tr_enrollment_staff(tk_a);
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'staff') x WHERE (x->>'staf_id')::numeric = fa)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'staff') x WHERE (x->>'staf_id')::numeric = fb)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(j->'staff') x WHERE (x->>'staf_id')::numeric = fc)
       OR j->>'year_from' IS DISTINCT FROM (SELECT iyrstadate::text FROM public.institutionyear WHERE iyr_id = iyr_now) THEN
      bad := bad || ('the staff list offers the wrong staff, or not the year')::text;
    END IF;
    -- two staff: Both (up in stage 1, down in stage 2) and Pickup only (its drop stop is cleared)
    IF public.tr_save(tk_a, 'staff_enrollment', jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
         jsonb_build_object('staf_id', fa, 'service_type', 'BOTH', 'pickup_stop_id', pa, 'drop_stop_id', pb, 'start_date', '2026-06-01'),
         jsonb_build_object('staf_id', fb, 'service_type', 'PICKUP', 'pickup_stop_id', pa, 'drop_stop_id', pb, 'start_date', '2026-06-01')))) <> 2 THEN
      bad := bad || ('staff enrollment save did not count its rows')::text;
    END IF;
    SELECT enrollment_id INTO ea FROM transport20262027.tr_staff_enrollment WHERE staf_id = fa AND status = 'ACTIVE';
    SELECT enrollment_id INTO eb FROM transport20262027.tr_staff_enrollment WHERE staf_id = fb AND status = 'ACTIVE';
    IF (SELECT format('%s:%s:%s:%s:%s:%s', route_id, fee_stage_id, acad_year_id, status, created_by, inst_id)
          FROM transport20262027.tr_staff_enrollment WHERE enrollment_id = ea)
       IS DISTINCT FROM format('%s:%s:%s:ACTIVE:%s:1', rs, gb, iyr_now, u) THEN
      bad := bad || ('staff enrollment not saved with the farther stop''s stage and the session year')::text;
    END IF;
    IF (SELECT drop_stop_id IS NULL AND fee_stage_id = ga FROM transport20262027.tr_staff_enrollment WHERE enrollment_id = eb) IS NOT TRUE THEN
      bad := bad || ('a pickup-only staff enrollment kept its drop stop, or got the wrong stage')::text;
    END IF;
    j := public.tr_list(tk_a, 'staff_enrollment', jsonb_build_object('route_id', rs));
    IF jsonb_array_length(j) <> 2 OR j->0->>'emp_code' IS NULL OR j->0->>'stafname' IS NULL OR (j->0->>'staff_active')::boolean IS NOT TRUE THEN
      bad := bad || ('the staff enrollment list lacks the staff details')::text;
    END IF;
    j := public.tr_enrollment_staff(tk_a);
    IF (SELECT count(*) FROM jsonb_array_elements(j->'staff') x WHERE (x->>'staf_id')::numeric = fa AND x->>'route_code' = 'ZT-SENR1') <> 1 THEN
      bad := bad || ('the staff list does not show the route')::text;
    END IF;
    n := n + 6;

    -- readable errors, each naming the staff member
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rt, 'rows', jsonb_build_array(
             jsonb_build_object('staf_id', fc, 'service_type', 'PICKUP', 'pickup_stop_id', pt, 'start_date', '2026-06-01')))), 'whose transport is bus');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rt, 'rows', jsonb_build_array(
             jsonb_build_object('staf_id', fb, 'service_type', 'BOTH', 'pickup_stop_id', pt, 'start_date', '2026-06-01')))), 'choose the drop stop of ' || who);
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', ea, 'staf_id', fa, 'service_type', 'PICKUP', 'pickup_stop_id', pt, 'start_date', '2026-06-01')))),
             'is not on route zt-senr1');
    -- one active enrollment a year: fa is on ZT-SENR1, so not on ZT-SENR2 too
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rt, 'rows', jsonb_build_array(
             jsonb_build_object('staf_id', fa, 'service_type', 'PICKUP', 'pickup_stop_id', pt, 'start_date', '2026-06-01')))), 'already enrolled on route zt-senr1');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', ea, 'staf_id', fa, 'service_type', 'BOTH', 'pickup_stop_id', pa, 'drop_stop_id', pb, 'start_date', '2026-06-01'),
             jsonb_build_object('staf_id', fa, 'service_type', 'PICKUP', 'pickup_stop_id', pa, 'start_date', '2026-06-01')))), 'listed twice');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
             jsonb_build_object('staf_id', -1, 'service_type', 'PICKUP', 'pickup_stop_id', pa, 'start_date', '2026-06-01')))), 'staff member was not found');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', ea, 'staf_id', fa, 'service_type', 'BOTH', 'pickup_stop_id', pa, 'drop_stop_id', pb,
                                'start_date', '2025-06-01')))), 'within the academic year');
    -- never deleted: a staff member who stops is Cancelled
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'staff_enrollment',%s)$q$, tk_a, ea), 'set the status to cancelled');
    -- a route, stage or stop the staff still use is not switched off
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'route',%s)$q$, tk_a, rs), 'staff still use this route');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'stage',%s)$q$, tk_a, gb), 'staff still use this stage');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'stop',%s)$q$, tk_a, pb), 'staff or schedule(s) still use this stop');
    -- the Student Enrollment menu is needed
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'staff_enrollment')$q$, tk_ac), 'no access');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_enrollment_staff(%L)$q$, tk_ac), 'no access');
    bad := bad || pg_temp.fails(format(q, tk_ac, jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
             jsonb_build_object('staf_id', fb, 'service_type', 'PICKUP', 'pickup_stop_id', pa, 'start_date', '2026-06-01')))), 'no access');
    n := n + 15;

    -- an edit someone else made first is refused; fb is Cancelled, and once
    -- fb no longer comes by bus (OWN) cannot be made Active again
    SELECT updated_at INTO up FROM transport20262027.tr_staff_enrollment WHERE enrollment_id = eb;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', eb, 'staf_id', fb, 'service_type', 'PICKUP', 'pickup_stop_id', pa,
                                'start_date', '2026-06-01', 'status', 'CANCELLED', 'updated_at', up - interval '1 second')))), 'changed by someone else');
    PERFORM public.tr_save(tk_a, 'staff_enrollment', jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', eb, 'staf_id', fb, 'service_type', 'PICKUP', 'pickup_stop_id', pa,
                                 'start_date', '2026-06-01', 'end_date', '2026-10-31', 'status', 'CANCELLED', 'updated_at', up))));
    EXECUTE format('UPDATE %I.staffmast SET transportreq = ''OWN'' WHERE staf_id = $1', app_sch) USING fb;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', eb, 'staf_id', fb, 'service_type', 'PICKUP', 'pickup_stop_id', pa,
                                'start_date', '2026-06-01', 'status', 'ACTIVE')))), 'cannot be made active again');
    -- the saved row of one who has left can still be changed: fa now gets on and off at the far stop
    EXECUTE format('UPDATE %I.staffmast SET is_active = false WHERE staf_id = $1', app_sch) USING fa;
    PERFORM public.tr_save(tk_a, 'staff_enrollment', jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', ea, 'staf_id', fa, 'service_type', 'BOTH', 'pickup_stop_id', pb, 'drop_stop_id', pb,
                                 'start_date', '2026-06-01'))));
    IF (SELECT string_agg(staf_id || ':' || status || ':' || pickup_stop_id, ',' ORDER BY staf_id)
          FROM transport20262027.tr_staff_enrollment WHERE staf_id IN (fa, fb) AND route_id = rs)
       IS DISTINCT FROM format('%s:ACTIVE:%s,%s:CANCELLED:%s', fa, pb, fb, pa) THEN
      bad := bad || ('the staff enrollments were not changed as saved')::text;
    END IF;
    j := public.tr_list(tk_a, 'staff_enrollment', jsonb_build_object('route_id', rs));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j) x WHERE (x->>'staf_id')::numeric = fa AND (x->>'staff_active')::boolean = false) THEN
      bad := bad || ('the staff enrollment list does not say the staff member left')::text;
    END IF;
    n := n + 4;
  END;

  -- 18. vehicle allotment: the vehicle (schedule) each student of a route
  --     travels in, one way at a time, within the vehicle's seats
  DECLARE ysch text; ids bigint[]; v2 bigint; v40 bigint; pa bigint; pb bigint; pd bigint; px bigint;
    e1 bigint; e2 bigint; e3 bigint; ep bigint; eo bigint; up timestamptz;
    q text := $q$SELECT public.tr_save(%L,'allotment',%L)$q$;
  BEGIN
    SELECT iyrschema INTO ysch FROM public.institutionyear WHERE iyr_id = iyr_now;
    -- three more active students with no transport yet, on R5 both ways at Mill Gate
    EXECUTE format('SELECT array_agg(stu_id ORDER BY stu_id) FROM (SELECT s.stu_id FROM %I.students s WHERE s.ins_id = 1 AND s.activestatus = 1
                      AND NOT EXISTS (SELECT 1 FROM transport20262027.tr_student_enrollment e WHERE e.student_id = s.stu_id AND e.status = ''ACTIVE'')
                     ORDER BY s.stu_id LIMIT 3) x', ysch) INTO ids;
    IF cardinality(ids) IS DISTINCT FROM 3 THEN RAISE EXCEPTION 'TESTS_FAILED: section 18 needs 3 more active students in %.students', ysch; END IF;
    PERFORM public.tr_save(tk_a, 'enrollment', jsonb_build_object('route_id', r1, 'rows', jsonb_build_array(
              jsonb_build_object('student_id', ids[1], 'service_type', 'BOTH', 'pickup_stop_id', s1, 'drop_stop_id', s1, 'start_date', '2026-06-01'),
              jsonb_build_object('student_id', ids[2], 'service_type', 'BOTH', 'pickup_stop_id', s1, 'drop_stop_id', s1, 'start_date', '2026-06-01'),
              jsonb_build_object('student_id', ids[3], 'service_type', 'BOTH', 'pickup_stop_id', s1, 'drop_stop_id', s1, 'start_date', '2026-06-01'))));
    SELECT enrollment_id INTO e1 FROM transport20262027.tr_student_enrollment WHERE student_id = ids[1] AND status = 'ACTIVE';
    SELECT enrollment_id INTO e2 FROM transport20262027.tr_student_enrollment WHERE student_id = ids[2] AND status = 'ACTIVE';
    SELECT enrollment_id INTO e3 FROM transport20262027.tr_student_enrollment WHERE student_id = ids[3] AND status = 'ACTIVE';
    -- section 17 left a pickup-only student on R5, and one on R6
    SELECT enrollment_id INTO ep FROM transport20262027.tr_student_enrollment WHERE route_id = r1 AND service_type = 'PICKUP' AND status = 'ACTIVE' ORDER BY enrollment_id LIMIT 1;
    SELECT enrollment_id INTO eo FROM transport20262027.tr_student_enrollment WHERE route_id = r2 AND status = 'ACTIVE' ORDER BY enrollment_id LIMIT 1;
    -- R5's pickup trips on a 2-seat van and a 40-seat bus, a drop trip, and a switched-off pickup trip
    v2 := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-al-van', 'registration_no', 'zt01al0002', 'vehicle_type', 'VAN',
                                                             'seating_capacity', 2, 'ownership_type', 'OWNED'));
    v40 := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-al-bus', 'registration_no', 'zt01al0040', 'vehicle_type', 'BUS',
                                                              'seating_capacity', 40, 'ownership_type', 'OWNED'));
    pa := public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_code', 'zt-al-pa', 'schedule_name', 'Van Pickup', 'route_id', r1, 'direction', 'PICKUP',
            'vehicle_id', v2, 'planned_start', '05:00', 'planned_end', '05:30', 'run_days', '[1,2,3,4,5,6]'::jsonb, 'effective_from', '2026-06-01',
            'stops', jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '05:10'))));
    pb := public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_code', 'zt-al-pb', 'schedule_name', 'Bus Pickup', 'route_id', r1, 'direction', 'PICKUP',
            'vehicle_id', v40, 'planned_start', '05:30', 'planned_end', '06:00', 'run_days', '[1,2,3,4,5,6]'::jsonb, 'effective_from', '2026-06-01',
            'stops', jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '05:40'))));
    pd := public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_code', 'zt-al-pd', 'schedule_name', 'Bus Drop', 'route_id', r1, 'direction', 'DROP',
            'vehicle_id', v40, 'planned_start', '15:00', 'planned_end', '15:30', 'run_days', '[1,2,3,4,5,6]'::jsonb, 'effective_from', '2026-06-01',
            'stops', jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '15:20'))));
    px := public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_code', 'zt-al-px', 'schedule_name', 'Old Pickup', 'route_id', r1, 'direction', 'PICKUP',
            'vehicle_id', v40, 'planned_start', '06:00', 'planned_end', '06:30', 'run_days', '[1,2,3,4,5,6]'::jsonb, 'effective_from', '2026-06-01',
            'stops', jsonb_build_array(jsonb_build_object('stop_id', s1, 'planned_time', '06:10'))));
    PERFORM public.tr_delete(tk_a, 'schedule', px);

    -- two students into the 2-seat van, for the pickup only
    IF public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
         jsonb_build_object('enrollment_id', e1, 'schedule_id', pa), jsonb_build_object('enrollment_id', e2, 'schedule_id', pa)))) <> 2 THEN
      bad := bad || ('allotment save did not count its rows')::text;
    END IF;
    IF (SELECT count(*) FROM transport20262027.tr_student_enrollment WHERE enrollment_id IN (e1, e2) AND pickup_schedule_id = pa AND drop_schedule_id IS NULL) <> 2 THEN
      bad := bad || ('students not allotted to the van for the pickup only')::text;
    END IF;
    j := public.tr_list(tk_a, 'allotment', jsonb_build_object('route_id', r1));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j) x
                    WHERE (x->>'enrollment_id')::bigint = e1 AND (x->>'pickup_schedule_id')::bigint = pa AND x->>'stuname' IS NOT NULL) THEN
      bad := bad || ('the allotment list lacks the vehicle or the student')::text;
    END IF;
    n := n + 3;

    -- the van is full: a third student is refused, naming the vehicle and its seats
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', e3, 'schedule_id', pa)))), 'zt-al-van (trip zt-al-pa) would have 3 students for 2 seats');
    -- with 1 additional (three small children on the van's two seats) the
    -- third student fits, and a fourth is refused, naming the capacity; the
    -- occupancy view counts the same capacity
    PERFORM public.tr_save(tk_a, 'vehicle', jsonb_build_object('vehicle_id', v2, 'additional_capacity', 1));
    PERFORM public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', e3, 'schedule_id', pa))));
    IF (SELECT count(*) FROM transport20262027.tr_student_enrollment WHERE pickup_schedule_id = pa AND status = 'ACTIVE') <> 3 THEN
      bad := bad || ('the additional capacity was not counted in the allotment')::text;
    END IF;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', ep, 'schedule_id', pa)))),
             'zt-al-van (trip zt-al-pa) would have 4 students for a capacity of 3 (2 seats + 1 additional)');
    IF NOT EXISTS (SELECT 1 FROM transport20262027.v_schedule_occupancy o
                    WHERE o.schedule_id = pa AND o.capacity = 3 AND o.additional_capacity = 1 AND o.seats_free = 3 - o.enrolled) THEN
      bad := bad || ('v_schedule_occupancy does not count the additional capacity')::text;
    END IF;
    n := n + 3;
    -- back to the van's 2 seats, without the third student
    PERFORM public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', e3, 'schedule_id', null))));
    PERFORM public.tr_save(tk_a, 'vehicle', jsonb_build_object('vehicle_id', v2, 'additional_capacity', 0));
    -- in one save, one student moves to the bus and the third takes the free seat
    PERFORM public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', e3, 'schedule_id', pa), jsonb_build_object('enrollment_id', e2, 'schedule_id', pb))));
    IF (SELECT string_agg(enrollment_id || ':' || pickup_schedule_id, ',' ORDER BY enrollment_id)
          FROM transport20262027.tr_student_enrollment WHERE enrollment_id IN (e1, e2, e3))
       IS DISTINCT FROM format('%s:%s,%s:%s,%s:%s', e1, pa, e2, pb, e3, pa) THEN
      bad := bad || ('the move to the bus was not saved')::text;
    END IF;
    -- the drop is allotted on its own; taking a student out leaves no vehicle
    PERFORM public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', r1, 'direction', 'DROP', 'rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', e1, 'schedule_id', pd))));
    PERFORM public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', e1, 'schedule_id', null))));
    IF (SELECT pickup_schedule_id IS NULL AND drop_schedule_id = pd FROM transport20262027.tr_student_enrollment WHERE enrollment_id = e1) IS NOT TRUE THEN
      bad := bad || ('the drop vehicle, or taking a student out, was not saved')::text;
    END IF;
    n := n + 3;

    -- readable errors
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', e3, 'schedule_id', pd)))), 'is not on a pickup trip of route r5');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', e3, 'schedule_id', px)))), 'or that trip is switched off');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'direction', 'DROP', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', ep, 'schedule_id', pd)))), 'travels pickup only');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', eo, 'schedule_id', pa)))), 'not on route r5 any more');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', e3, 'schedule_id', pa), jsonb_build_object('enrollment_id', e3, 'schedule_id', pb)))), 'listed twice');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'direction', 'BOTH', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', e3, 'schedule_id', pa)))), 'choose pickup or drop');
    SELECT updated_at INTO up FROM transport20262027.tr_student_enrollment WHERE enrollment_id = e3;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', e3, 'schedule_id', pb, 'updated_at', up - interval '1 second')))), 'changed by someone else');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'allotment',%s)$q$, tk_a, e3), 'move them back to not allotted');
    -- the Vehicle Allotment menu is needed
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'allotment')$q$, tk_ac), 'no access');
    bad := bad || pg_temp.fails(format(q, tk_ac, jsonb_build_object('route_id', r1, 'direction', 'PICKUP', 'rows', jsonb_build_array(
             jsonb_build_object('enrollment_id', e3, 'schedule_id', pb)))), 'no access');
    n := n + 10;

    -- the day's trips follow it: e3 in the van only, e2 in the bus only (2026-11-18 is a Wednesday)
    BEGIN
      PERFORM transport_core.fn_generate_trips(1, '2026-11-18');
      IF (SELECT count(*) FROM transport20262027.tr_trip t JOIN transport20262027.tr_trip_student ts ON ts.trip_id = t.trip_id
           WHERE t.trip_date = '2026-11-18' AND ((t.schedule_id = pa AND ts.enrollment_id = e3) OR (t.schedule_id = pb AND ts.enrollment_id = e2))) <> 2
         OR EXISTS (SELECT 1 FROM transport20262027.tr_trip t JOIN transport20262027.tr_trip_student ts ON ts.trip_id = t.trip_id
           WHERE t.trip_date = '2026-11-18' AND ((t.schedule_id = pa AND ts.enrollment_id = e2) OR (t.schedule_id = pb AND ts.enrollment_id = e3))) THEN
        bad := bad || ('the day''s trips do not follow the vehicle allotment')::text;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      bad := bad || ('allotment trip check failed: ' || SQLERRM);
    END;
    n := n + 1;
  END;

  -- 18b. staff in Vehicle Allotment: a route's staff are listed for the
  --      screen (staff_allotment) and take seats in the same vehicles as its
  --      students, saved in the same batch (staff_rows); the capacity counts
  --      both. Its own route and a 2-seat van.
  DECLARE ids numeric[]; fa numeric; fb numeric; st bigint; rs bigint; gs bigint; ps bigint; vs bigint; ss bigint;
    es bigint; efa bigint; efb bigint; q text := $q$SELECT public.tr_save(%L,'allotment',%L)$q$;
  BEGIN
    IF NOT transport_core._staff_ready(app_sch, 'transport20262027') THEN
      RAISE EXCEPTION 'TESTS_FAILED: section 18b needs %.staffmast with transportreq, and transport20262027.tr_staff_enrollment (transport_23)', app_sch;
    END IF;
    EXECUTE format('SELECT array_agg(staf_id ORDER BY staf_id) FROM (SELECT m.staf_id FROM %I.staffmast m
                      JOIN public.schstaff s ON s.staf_id = m.staf_id WHERE s.ins_id = 1 ORDER BY m.staf_id LIMIT 2) x', app_sch) INTO ids;
    IF cardinality(ids) IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'TESTS_FAILED: section 18b needs 2 staff of school 1 in %.staffmast', app_sch; END IF;
    fa := ids[1]; fb := ids[2];
    EXECUTE format('UPDATE %I.staffmast SET is_active = true, transportreq = ''BUS'' WHERE staf_id IN ($1, $2)', app_sch) USING fa, fb;
    UPDATE transport20262027.tr_staff_enrollment SET status = 'CANCELLED' WHERE staf_id IN (fa, fb) AND status = 'ACTIVE';
    EXECUTE format('SELECT s.stu_id FROM %I.students s WHERE s.ins_id = 1 AND s.activestatus = 1
                      AND NOT EXISTS (SELECT 1 FROM transport20262027.tr_student_enrollment e WHERE e.student_id = s.stu_id AND e.status = ''ACTIVE'')
                     ORDER BY s.stu_id LIMIT 1', app_sch) INTO st;
    IF st IS NULL THEN RAISE EXCEPTION 'TESTS_FAILED: section 18b needs an active student with no transport in %.students', app_sch; END IF;
    -- a route with one stop, a 2-seat van picking up there, one student and two staff on it
    rs := public.tr_save(tk_a, 'route', '{"route_code":"zt-sal","route_name":"Staff Van Line"}');
    gs := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rs, 'stage_no', 1, 'stage_name', 'Near'));
    ps := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', rs, 'stage_id', gs, 'stop_seq', 1, 'stop_name', 'Van Corner', 'latitude', 13.04, 'longitude', 80.24));
    vs := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-sal-van', 'registration_no', 'zt01sa0002', 'vehicle_type', 'VAN',
                                                             'seating_capacity', 2, 'ownership_type', 'OWNED'));
    ss := public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_code', 'zt-sal-p', 'schedule_name', 'Staff Van Pickup', 'route_id', rs, 'direction', 'PICKUP',
            'vehicle_id', vs, 'planned_start', '06:00', 'planned_end', '06:30', 'run_days', '[1,2,3,4,5,6]'::jsonb, 'effective_from', '2026-06-01',
            'stops', jsonb_build_array(jsonb_build_object('stop_id', ps, 'planned_time', '06:10'))));
    PERFORM public.tr_save(tk_a, 'enrollment', jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
              jsonb_build_object('student_id', st, 'service_type', 'BOTH', 'pickup_stop_id', ps, 'drop_stop_id', ps, 'start_date', '2026-06-01'))));
    PERFORM public.tr_save(tk_a, 'staff_enrollment', jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
              jsonb_build_object('staf_id', fa, 'service_type', 'BOTH', 'pickup_stop_id', ps, 'drop_stop_id', ps, 'start_date', '2026-06-01'),
              jsonb_build_object('staf_id', fb, 'service_type', 'PICKUP', 'pickup_stop_id', ps, 'start_date', '2026-06-01'))));
    SELECT enrollment_id INTO es FROM transport20262027.tr_student_enrollment WHERE student_id = st AND status = 'ACTIVE';
    SELECT enrollment_id INTO efa FROM transport20262027.tr_staff_enrollment WHERE staf_id = fa AND status = 'ACTIVE';
    SELECT enrollment_id INTO efb FROM transport20262027.tr_staff_enrollment WHERE staf_id = fb AND status = 'ACTIVE';

    -- listed for the screen, with the staff details
    j := public.tr_list(tk_a, 'staff_allotment', jsonb_build_object('route_id', rs));
    IF jsonb_array_length(j) <> 2 OR j->0->>'emp_code' IS NULL OR j->0->>'stafname' IS NULL THEN
      bad := bad || ('the staff are not listed for Vehicle Allotment')::text;
    END IF;
    -- a student and a staff member go into the van together, in one batch
    IF public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', rs, 'direction', 'PICKUP',
         'rows', jsonb_build_array(jsonb_build_object('enrollment_id', es, 'schedule_id', ss)),
         'staff_rows', jsonb_build_array(jsonb_build_object('enrollment_id', efa, 'schedule_id', ss)))) <> 2 THEN
      bad := bad || ('the allotment did not count the student and the staff member')::text;
    END IF;
    IF (SELECT pickup_schedule_id FROM transport20262027.tr_staff_enrollment WHERE enrollment_id = efa) IS DISTINCT FROM ss
       OR (SELECT pickup_schedule_id FROM transport20262027.tr_student_enrollment WHERE enrollment_id = es) IS DISTINCT FROM ss THEN
      bad := bad || ('the student and the staff member were not put in the van')::text;
    END IF;
    -- 2 seats: a second staff member is one too many
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('route_id', rs, 'direction', 'PICKUP',
             'staff_rows', jsonb_build_array(jsonb_build_object('enrollment_id', efb, 'schedule_id', ss)))), 'would have 1 student and 2 staff for 2 seats');
    -- the student comes out and the second staff member goes in, staff rows only for them
    PERFORM public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', rs, 'direction', 'PICKUP',
              'rows', jsonb_build_array(jsonb_build_object('enrollment_id', es, 'schedule_id', null)),
              'staff_rows', jsonb_build_array(jsonb_build_object('enrollment_id', efb, 'schedule_id', ss))));
    IF (SELECT count(*) FROM transport20262027.tr_staff_enrollment WHERE pickup_schedule_id = ss AND status = 'ACTIVE') <> 2
       OR (SELECT pickup_schedule_id FROM transport20262027.tr_student_enrollment WHERE enrollment_id = es) IS NOT NULL THEN
      bad := bad || ('the van does not hold the two staff only')::text;
    END IF;
    -- the trip the staff ride is not switched off
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'schedule',%s)$q$, tk_a, ss), 'staff still use this schedule');
    -- saved only with the students; the Vehicle Allotment menu is needed
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'staff_allotment',%L)$q$, tk_a, '{}'), 'saved with the students');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_list(%L,'staff_allotment')$q$, tk_ac), 'no access');
    n := n + 8;
  END;

  -- 19. Stage Fees (the screen's batch, _stage_fee_save): the fees of a
  --     route's stages for a term, fee type, way and dates, saved together
  DECLARE q text := $q$SELECT public.tr_save(%L,'stage_fee',%L)$q$; hdr jsonb; rf bigint; ga bigint; gb bigint; g_off bigint;
    ka bigint; kb bigint; t1 date; t2 date; fe_other integer; saved bigint; sm2 smallint; u1 date; u2 date;
  BEGIN
    EXECUTE format('SELECT semstart, semend FROM %I.semester WHERE sem_id = $1 AND ins_id = 1', app_sch) INTO t1, t2 USING sm;
    SELECT fee_id INTO fe_other FROM public.feetype WHERE ins_id = 1 AND feecat IS DISTINCT FROM 'TRA' ORDER BY fee_id LIMIT 1;
    rf := public.tr_save(tk_a, 'route', '{"route_code":"FEE-T1","route_name":"Fee Line"}');
    ga := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rf, 'stage_no', 1, 'stage_name', 'Near'));
    gb := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rf, 'stage_no', 2, 'stage_name', 'Far'));
    g_off := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rf, 'stage_no', 3, 'stage_name', 'Closed', 'is_active', false));
    hdr := jsonb_build_object('route_id', rf, 'sem_id', sm, 'service_type', 'BOTH', 'fee_id', fe,
                              'effective_from', COALESCE(t1, DATE '2026-06-01'), 'effective_to', t2);

    -- two new fees, with the header's fee type, term and dates (saved in a
    -- statement of its own: a check in the same statement would not see them)
    saved := public.tr_save(tk_a, 'stage_fee', hdr || jsonb_build_object('fees', jsonb_build_array(
         jsonb_build_object('stage_id', ga, 'amount', 1000), jsonb_build_object('stage_id', gb, 'amount', '1500.50'))));
    IF saved <> 2
       OR (SELECT count(*) FROM transport20262027.tr_stage_fee
            WHERE route_id = rf AND sem_id = sm AND service_type = 'BOTH' AND fee_id = fe AND created_by = u
              AND effective_from = COALESCE(t1, DATE '2026-06-01') AND effective_to IS NOT DISTINCT FROM t2) <> 2
       OR (SELECT amount FROM transport20262027.tr_stage_fee WHERE stage_id = gb) <> 1500.50 THEN
      bad := bad || ('stage fees batch: new fees not saved as sent')::text;
    END IF;
    SELECT stage_fee_id INTO ka FROM transport20262027.tr_stage_fee WHERE stage_id = ga;
    SELECT stage_fee_id INTO kb FROM transport20262027.tr_stage_fee WHERE stage_id = gb;
    -- one changed (and no end date now), one removed by an empty amount
    saved := public.tr_save(tk_a, 'stage_fee', hdr || jsonb_build_object('effective_to', NULL, 'fees', jsonb_build_array(
         jsonb_build_object('stage_id', ga, 'stage_fee_id', ka, 'amount', 1200),
         jsonb_build_object('stage_id', gb, 'stage_fee_id', kb, 'amount', ''))));
    IF saved <> 2
       OR (SELECT amount FROM transport20262027.tr_stage_fee WHERE stage_fee_id = ka) <> 1200
       OR (SELECT effective_to FROM transport20262027.tr_stage_fee WHERE stage_fee_id = ka) IS NOT NULL
       OR EXISTS (SELECT 1 FROM transport20262027.tr_stage_fee WHERE stage_fee_id = kb) THEN
      bad := bad || ('stage fees batch: change or removal not saved')::text;
    END IF;
    -- the change says who made it (transport_22)
    IF (SELECT updated_by FROM transport20262027.tr_stage_fee WHERE stage_fee_id = ka) IS DISTINCT FROM u THEN
      bad := bad || ('stage fees batch: the change does not say who made it')::text;
    END IF;
    n := n + 1;

    -- refused, each with a readable reason
    bad := bad || pg_temp.fails(format(q, tk_a, hdr - 'sem_id' || jsonb_build_object('fees', jsonb_build_array(jsonb_build_object('stage_id', gb, 'amount', 1)))), 'choose the term');
    IF fe_other IS NOT NULL THEN
      bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('fee_id', fe_other, 'fees', jsonb_build_array(jsonb_build_object('stage_id', gb, 'amount', 1)))), 'transport fee type');
      bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'stage_fee',%L)$q$, tk_a, jsonb_build_object('route_id', rf, 'stage_id', gb,
               'fee_id', fe_other, 'sem_id', sm, 'amount', 1, 'effective_from', COALESCE(t1, DATE '2026-06-01'))), 'transport fee type');
    END IF;
    IF t2 IS NOT NULL THEN
      bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('effective_from', t2 + 1, 'effective_to', NULL,
               'fees', jsonb_build_array(jsonb_build_object('stage_id', gb, 'amount', 1)))), 'must be within');
    END IF;
    bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('effective_to', COALESCE(t1, DATE '2026-06-01') - 1,
             'fees', jsonb_build_array(jsonb_build_object('stage_id', gb, 'amount', 1)))), 'cannot be before');
    bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('fees', jsonb_build_array(jsonb_build_object('stage_id', g1, 'amount', 1)))), 'not on route');
    bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('fees', jsonb_build_array(
             jsonb_build_object('stage_id', gb, 'amount', 1), jsonb_build_object('stage_id', gb, 'amount', 2)))), 'listed twice');
    bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('fees', jsonb_build_array(jsonb_build_object('stage_id', gb, 'amount', -5)))), 'stage 2 (far) cannot be negative');
    bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('fees', jsonb_build_array(
             jsonb_build_object('stage_id', gb, 'stage_fee_id', ka, 'amount', 1)))), 'was not found for this term');
    bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('fees', jsonb_build_array(jsonb_build_object('stage_id', ga, 'amount', 1)))), 'already has a fee for this term');
    bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('fees', '[]'::jsonb)), 'nothing to save');
    bad := bad || pg_temp.fails(format(q, tk_ac, hdr || jsonb_build_object('fees', jsonb_build_array(jsonb_build_object('stage_id', gb, 'amount', 1)))), 'no access');
    -- all or nothing: a good row is not kept when another one is refused
    bad := bad || pg_temp.fails(format(q, tk_a, hdr || jsonb_build_object('fees', jsonb_build_array(
             jsonb_build_object('stage_id', gb, 'amount', 900), jsonb_build_object('stage_id', g_off, 'amount', 1)))), 'switched off');
    IF EXISTS (SELECT 1 FROM transport20262027.tr_stage_fee WHERE stage_id = gb) THEN
      bad := bad || ('stage fees batch kept a row of a refused save')::text;
    END IF;

    -- the screen's lookups: the year's terms, and only transport fee types
    j := public.tr_lookups(tk_a);
    IF NOT (j->'terms') @> jsonb_build_array(jsonb_build_object('sem_id', sm)) THEN
      bad := bad || ('lookups have no terms of the year')::text;
    END IF;
    IF NOT (j->'feetypes') @> jsonb_build_array(jsonb_build_object('fee_id', fe))
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(j->'feetypes') f JOIN public.feetype ft ON ft.fee_id = (f->>'fee_id')::integer
                   WHERE ft.feecat IS DISTINCT FROM 'TRA') THEN
      bad := bad || ('lookups fee types are not the transport ones')::text;
    END IF;

    -- Copy to Term (the screen): the route's fees saved with the batch into
    -- another term, with that term's dates; a fee it already has is updated
    -- (not doubled), and the first term keeps its own
    EXECUTE format('SELECT sem_id, semstart, semend FROM %I.semester WHERE ins_id = 1 AND sem_id <> $1 ORDER BY sem_id LIMIT 1', app_sch)
       INTO sm2, u1, u2 USING sm;
    IF sm2 IS NULL OR u1 IS NULL THEN
      bad := bad || ('school 1 needs a second 2026-2027 term with dates to test Copy to Term')::text;
    ELSE
      saved := public.tr_save(tk_a, 'stage_fee', hdr || jsonb_build_object('sem_id', sm2, 'effective_from', u1, 'effective_to', u2,
                 'fees', jsonb_build_array(jsonb_build_object('stage_id', ga, 'amount', 999))));
      SELECT stage_fee_id INTO kb FROM transport20262027.tr_stage_fee WHERE stage_id = ga AND sem_id = sm2;
      saved := public.tr_save(tk_a, 'stage_fee', hdr || jsonb_build_object('sem_id', sm2, 'effective_from', u1, 'effective_to', u2,
                 'fees', jsonb_build_array(jsonb_build_object('stage_id', ga, 'stage_fee_id', kb, 'amount', 1200),
                                           jsonb_build_object('stage_id', gb, 'amount', 800))));
      IF saved <> 2
         OR (SELECT count(*) FROM transport20262027.tr_stage_fee WHERE sem_id = sm2 AND stage_id IN (ga, gb)) <> 2
         OR (SELECT amount FROM transport20262027.tr_stage_fee WHERE stage_fee_id = kb) <> 1200
         OR NOT EXISTS (SELECT 1 FROM transport20262027.tr_stage_fee
                         WHERE stage_id = gb AND sem_id = sm2 AND service_type = 'BOTH' AND amount = 800 AND fee_id = fe
                           AND effective_from = u1 AND effective_to IS NOT DISTINCT FROM u2) THEN
        bad := bad || ('copy to term: not saved into the other term with its dates, or a fee there was doubled')::text;
      END IF;
      IF (SELECT amount FROM transport20262027.tr_stage_fee WHERE stage_fee_id = ka) <> 1200
         OR EXISTS (SELECT 1 FROM transport20262027.tr_stage_fee WHERE stage_id = gb AND sem_id = sm) THEN
        bad := bad || ('copy to term changed the first term''s fees')::text;
      END IF;
    END IF;
    n := n + 20;
  END;

  -- 20. Stage Fee Process (stage_fee_process, the Stage Fees screen's
  --     Process Fees): the students of the ticked routes billed for a term
  --     and fee type from their stage fees, in the school app's fee demands
  --     (app_sch.feedemand); each demand kept in tr_stage_fee_demand
  DECLARE rp bigint; rq bigint; pa bigint; pb bigint; sa bigint; sb bigint; ids bigint[]; ya bigint; yb bigint; yc bigint;
    kfar bigint; dem bigint; demb bigint; res jsonb; rw jsonb; t1 date; t2 date; saved bigint; fe_other integer; who text;
    hdr jsonb; v numeric[]; ok boolean; q text := $q$SELECT public.tr_stage_fee_process(%L,%L)$q$;
  BEGIN
    EXECUTE format('SELECT semstart, semend FROM %I.semester WHERE sem_id = $1 AND ins_id = 1', app_sch) INTO t1, t2 USING sm;
    t1 := COALESCE(t1, DATE '2026-06-01');
    SELECT fee_id INTO fe_other FROM public.feetype WHERE ins_id = 1 AND feecat IS DISTINCT FROM 'TRA' ORDER BY fee_id LIMIT 1;
    rp := public.tr_save(tk_a, 'route', '{"route_code":"PROC-1","route_name":"Process Line"}');
    rq := public.tr_save(tk_a, 'route', '{"route_code":"PROC-2","route_name":"Empty Line"}');
    pa := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rp, 'stage_no', 1, 'stage_name', 'Near'));
    pb := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rp, 'stage_no', 2, 'stage_name', 'Far'));
    sa := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', rp, 'stage_id', pa, 'stop_seq', 1, 'stop_name', 'Gate', 'latitude', 13.01, 'longitude', 80.21));
    sb := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', rp, 'stage_id', pb, 'stop_seq', 2, 'stop_name', 'Hill', 'latitude', 13.02, 'longitude', 80.22));
    -- the term's fees: Near 1000 and Far 2000 both ways, Far 1200 pickup only
    hdr := jsonb_build_object('route_id', rp, 'sem_id', sm, 'service_type', 'BOTH', 'fee_id', fe, 'effective_from', t1, 'effective_to', t2);
    saved := public.tr_save(tk_a, 'stage_fee', hdr || jsonb_build_object('fees', jsonb_build_array(
               jsonb_build_object('stage_id', pa, 'amount', 1000), jsonb_build_object('stage_id', pb, 'amount', 2000))));
    saved := public.tr_save(tk_a, 'stage_fee', hdr || jsonb_build_object('service_type', 'PICKUP', 'fees', jsonb_build_array(
               jsonb_build_object('stage_id', pb, 'amount', 1200))));
    SELECT stage_fee_id INTO kfar FROM transport20262027.tr_stage_fee WHERE stage_id = pb AND sem_id = sm AND service_type = 'BOTH';

    -- two active students of the year with no transport and no such fee
    -- demand yet, whose class has a fee for the term and fee type in the fee
    -- master (classfeedemand); and one whose class has none
    EXECUTE format($s$SELECT array_agg(stu_id ORDER BY stu_id) FROM (
                        SELECT s.stu_id FROM %1$I.students s
                         WHERE s.ins_id = 1 AND s.activestatus = 1
                           AND NOT EXISTS (SELECT 1 FROM transport20262027.tr_student_enrollment e WHERE e.student_id = s.stu_id AND e.status = 'ACTIVE')
                           AND NOT EXISTS (SELECT 1 FROM %1$I.feedemand fd WHERE fd.stu_id = s.stu_id AND fd.activestatus = 1 AND fd.fee_id = $2)
                           AND EXISTS (SELECT 1 FROM %1$I.classfeedemand cf WHERE cf.activestatus = 1 AND cf.sem_id = $1 AND cf.fee_id = $2
                                        AND (cf.cla_id = s.cla_id OR upper(btrim(cf.cfclass)) = upper(btrim(s.stuclass))))
                         ORDER BY s.stu_id LIMIT 2) x$s$, app_sch) INTO ids USING sm, fe;
    EXECUTE format($s$SELECT s.stu_id, s.stuadmno FROM %1$I.students s
                       WHERE s.ins_id = 1 AND s.activestatus = 1
                         AND NOT EXISTS (SELECT 1 FROM transport20262027.tr_student_enrollment e WHERE e.student_id = s.stu_id AND e.status = 'ACTIVE')
                         AND NOT EXISTS (SELECT 1 FROM %1$I.classfeedemand cf WHERE cf.activestatus = 1 AND cf.fee_id = $2
                                          AND (cf.sem_id = $1 OR cf.sem_id IS NULL)
                                          AND (cf.cla_id = s.cla_id OR upper(btrim(cf.cfclass)) = upper(btrim(s.stuclass))))
                       ORDER BY s.stu_id LIMIT 1$s$, app_sch) INTO yc, who USING sm, fe;
    IF cardinality(ids) IS DISTINCT FROM 2 OR yc IS NULL THEN
      RAISE EXCEPTION 'TESTS_FAILED: section 20 needs, in %.students, 2 active students without transport whose class has a fee for the term and transport fee type in classfeedemand, and 1 whose class has none', app_sch;
    END IF;
    ya := ids[1]; yb := ids[2];
    -- ya both ways, dropped at Far: 2000; yb pickup only from Far: 1200; yc both ways at Near
    saved := public.tr_save(tk_a, 'enrollment', jsonb_build_object('route_id', rp, 'rows', jsonb_build_array(
               jsonb_build_object('student_id', ya, 'service_type', 'BOTH', 'pickup_stop_id', sa, 'drop_stop_id', sb, 'start_date', t1),
               jsonb_build_object('student_id', yb, 'service_type', 'PICKUP', 'pickup_stop_id', sb, 'start_date', t1),
               jsonb_build_object('student_id', yc, 'service_type', 'BOTH', 'pickup_stop_id', sa, 'drop_stop_id', sa, 'start_date', t1))));

    -- the routes to tick: the school's own, PROC-1 with 3 students, 2 stages with a fee, nothing billed yet
    j := public.tr_stage_fee_routes(tk_a, jsonb_build_object('sem_id', sm, 'fee_id', fe));
    SELECT x INTO rw FROM jsonb_array_elements(j) x WHERE (x->>'route_id')::bigint = rp;
    IF rw IS NULL OR (rw->>'students')::int <> 3 OR (rw->>'stages')::int <> 2 OR (rw->>'processed')::int <> 0
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(j) x WHERE (x->>'route_id')::bigint = alien) THEN
      bad := bad || ('process routes: wrong counts before processing, or another school''s route listed: ' || COALESCE(rw::text, '-'));
    END IF;

    -- first run: ya and yb billed, yc left out (no class fee), PROC-2 has nobody
    res := public.tr_stage_fee_process(tk_a, jsonb_build_object('sem_id', sm, 'fee_id', fe, 'route_ids', jsonb_build_array(rp, rq)));
    IF (res->>'students')::int <> 3 OR (res->>'added')::int <> 2 OR (res->>'updated')::int <> 0 OR (res->>'skipped')::int <> 1 THEN
      bad := bad || ('process: first run did not add 2 and leave 1 out: ' || res::text);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(res->'problems') x WHERE x->>'stuadmno' = who AND x->>'reason' ILIKE '%class fee demand%')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(res->'problems') x WHERE x->>'route_code' = 'PROC-2' AND x->>'reason' ILIKE '%no students%') THEN
      bad := bad || ('process: no message for a class without a class fee, or for a route with no students: ' || res::text);
    END IF;
    EXECUTE format('SELECT dem_id, ARRAY[feeamount, balancedue, reconbalancedue, paidamount] FROM %I.feedemand
                     WHERE stu_id = $1 AND fee_id = $2 AND sem_id = $3 AND activestatus = 1', app_sch) INTO dem, v USING ya, fe, sm;
    IF dem IS NULL OR v IS DISTINCT FROM ARRAY[2000, 2000, 2000, 0]::numeric[] THEN
      bad := bad || ('process: the both-ways student''s demand is not Far''s 2000, unpaid')::text;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.feedemand WHERE dem_id = $1 AND demseqtype = ''REGULAR'' AND paidstatus = ''U''
                      AND cf_id IS NOT NULL AND btrim(createdby) <> '''' AND demfeeyear = ''2026-2027'' AND duedate IS NOT NULL)', app_sch) INTO ok USING dem;
    IF ok IS NOT TRUE THEN bad := bad || ('process: a new demand lacks its year, class fee, due date or maker')::text; END IF;
    EXECUTE format('SELECT dem_id FROM %I.feedemand WHERE stu_id = $1 AND fee_id = $2 AND sem_id = $3 AND activestatus = 1 AND feeamount = 1200', app_sch)
       INTO demb USING yb, fe, sm;
    IF demb IS NULL THEN bad := bad || ('process: the pickup-only student was not billed the pickup fee')::text; END IF;
    IF (SELECT count(*) FROM transport20262027.tr_stage_fee_demand WHERE route_id = rp AND sem_id = sm AND fee_id = fe) <> 2
       OR NOT EXISTS (SELECT 1 FROM transport20262027.tr_stage_fee_demand WHERE dem_id = dem AND stage_fee_id = kfar AND amount = 2000 AND processed_by = u) THEN
      bad := bad || ('process: the demands were not kept in tr_stage_fee_demand')::text;
    END IF;
    j := public.tr_stage_fee_routes(tk_a, jsonb_build_object('sem_id', sm, 'fee_id', fe));
    IF (SELECT (x->>'processed')::int FROM jsonb_array_elements(j) x WHERE (x->>'route_id')::bigint = rp) IS DISTINCT FROM 2 THEN
      bad := bad || ('process routes: the processed route does not show its 2 demands')::text;
    END IF;

    -- again with nothing changed: nothing added or doubled
    res := public.tr_stage_fee_process(tk_a, jsonb_build_object('sem_id', sm, 'fee_id', fe, 'route_ids', jsonb_build_array(rp)));
    EXECUTE format('SELECT count(*) = 1 FROM %I.feedemand WHERE stu_id = $1 AND fee_id = $2 AND sem_id = $3 AND activestatus = 1', app_sch)
       INTO ok USING ya, fe, sm;
    IF (res->>'unchanged')::int <> 2 OR (res->>'added')::int <> 0 OR (res->>'updated')::int <> 0 OR ok IS NOT TRUE THEN
      bad := bad || ('process: a second run changed or doubled a demand: ' || res::text);
    END IF;

    -- ya paid 2000, then Far goes up to 2500: 2500, paid 2000, balance 500
    EXECUTE format('UPDATE %I.feedemand SET paidamount = 2000, balancedue = 0, reconbalancedue = 0, paidstatus = ''P'' WHERE dem_id = $1', app_sch) USING dem;
    saved := public.tr_save(tk_a, 'stage_fee', hdr || jsonb_build_object('fees', jsonb_build_array(
               jsonb_build_object('stage_id', pb, 'stage_fee_id', kfar, 'amount', 2500))));
    res := public.tr_stage_fee_process(tk_a, jsonb_build_object('sem_id', sm, 'fee_id', fe, 'route_ids', jsonb_build_array(rp)));
    IF (res->>'updated')::int <> 1 OR (res->>'unchanged')::int <> 1 THEN
      bad := bad || ('process: a raised fee did not update the demand: ' || res::text);
    END IF;
    EXECUTE format('SELECT ARRAY[feeamount, paidamount, balancedue, reconbalancedue] FROM %I.feedemand WHERE dem_id = $1 AND paidstatus = ''U''', app_sch)
       INTO v USING dem;
    IF v IS DISTINCT FROM ARRAY[2500, 2000, 500, 500]::numeric[] THEN
      bad := bad || ('process: a raised fee does not leave 500 to pay on top of the 2000 paid: ' || COALESCE(v::text, '-'));
    END IF;

    -- Far down to 1500, below the 2000 paid: refused for ya, whose demand stays at 2500
    saved := public.tr_save(tk_a, 'stage_fee', hdr || jsonb_build_object('fees', jsonb_build_array(
               jsonb_build_object('stage_id', pb, 'stage_fee_id', kfar, 'amount', 1500))));
    res := public.tr_stage_fee_process(tk_a, jsonb_build_object('sem_id', sm, 'fee_id', fe, 'route_ids', jsonb_build_array(rp)));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(res->'problems') x
                    WHERE (x->>'student_id')::bigint = ya AND x->>'reason' ILIKE '%below the 2,000.00 already paid%') THEN
      bad := bad || ('process: a fee below what is paid was not refused with a reason: ' || res::text);
    END IF;
    EXECUTE format('SELECT ARRAY[feeamount, paidamount, balancedue] FROM %I.feedemand WHERE dem_id = $1', app_sch) INTO v USING dem;
    IF v IS DISTINCT FROM ARRAY[2500, 2000, 500]::numeric[]
       OR (SELECT amount FROM transport20262027.tr_stage_fee_demand WHERE dem_id = dem) <> 2500 THEN
      bad := bad || ('process: a refused fee still changed the demand')::text;
    END IF;

    -- a stage fee students were billed from cannot be removed
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'stage_fee',%L)$q$, tk_a, hdr || jsonb_build_object('fees', jsonb_build_array(
             jsonb_build_object('stage_id', pb, 'stage_fee_id', kfar, 'amount', '')))), 'cannot be removed');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'stage_fee',%s)$q$, tk_a, kfar), 'fee demand(s) were made');

    -- refused, each with a readable reason
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('sem_id', sm, 'fee_id', fe, 'route_ids', '[]'::jsonb)), 'tick the routes');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('sem_id', sm, 'fee_id', fe, 'route_ids', jsonb_build_array(alien))), 'was not found');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('fee_id', fe, 'route_ids', jsonb_build_array(rp))), 'choose the term');
    IF fe_other IS NOT NULL THEN
      bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('sem_id', sm, 'fee_id', fe_other, 'route_ids', jsonb_build_array(rp))), 'transport fee type');
    END IF;
    bad := bad || pg_temp.fails(format(q, tk_ac, jsonb_build_object('sem_id', sm, 'fee_id', fe, 'route_ids', jsonb_build_array(rp))), 'no access');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_stage_fee_routes(%L,%L)$q$, tk_ac, jsonb_build_object('sem_id', sm, 'fee_id', fe)), 'no access');
    n := n + 21;
  END;

  -- 21. Vehicle service (tr_vehicle_service, the Vehicles screen's Service
  --     tab): each record is of the session's academic year (transport_19),
  --     which the caller cannot choose; another year neither lists nor
  --     changes it; readable refusals.
  DECLARE q text := $q$SELECT public.tr_save(%L,'vehicle_service',%L)$q$; vh bigint; vs bigint; vs2 bigint; alien_veh bigint;
    base jsonb; yfrom date;
  BEGIN
    SELECT iyrstadate INTO yfrom FROM public.institutionyear WHERE iyr_id = iyr_now;
    vh := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-svc', 'registration_no', 'ztsvc01', 'vehicle_type', 'VAN',
                                                             'seating_capacity', 12, 'ownership_type', 'OWNED'));
    base := jsonb_build_object('vehicle_id', vh, 'service_type', 'PERIODIC', 'service_date', yfrom + 20);
    vs := public.tr_save(tk_a, 'vehicle_service', base || jsonb_build_object('odometer_km', 15000, 'workshop', ' City Motors ', 'amount', 4500,
            'downtime_days', 2, 'next_due_date', yfrom + 110, 'next_due_km', 20000, 'acad_year_id', iyr_old, 'inst_id', 999));
    IF (SELECT format('%s:%s:%s:%s', acad_year_id, inst_id, created_by, workshop) FROM public.tr_vehicle_service WHERE service_id = vs)
       IS DISTINCT FROM format('%s:1:%s:City Motors', iyr_now, u) THEN
      bad := bad || ('service: the year, school, maker or workshop is wrong (the year must be the session''s)')::text;
    END IF;
    -- listed in its year, the latest service first
    vs2 := public.tr_save(tk_a, 'vehicle_service', base || jsonb_build_object('service_type', 'TYRE', 'service_date', yfrom + 40));
    j := public.tr_list(tk_a, 'vehicle_service', jsonb_build_object('vehicle_id', vh));
    IF jsonb_array_length(j) <> 2 OR (j->0->>'service_id')::bigint IS DISTINCT FROM vs2 THEN
      bad := bad || ('service: not listed, or not latest first')::text;
    END IF;
    -- another year does not see it, change it or delete it
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.tr_list(tk_old, 'vehicle_service')) x WHERE (x->>'service_id')::bigint IN (vs, vs2)) THEN
      bad := bad || ('service: listed in another year')::text;
    END IF;
    bad := bad || pg_temp.fails(format(q, tk_old, jsonb_build_object('service_id', vs, 'amount', 1)), 'another academic year');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'vehicle_service',%s)$q$, tk_old, vs), 'another academic year');
    -- an edit keeps the other values and the year
    PERFORM public.tr_save(tk_a, 'vehicle_service', jsonb_build_object('service_id', vs, 'amount', 4800, 'acad_year_id', iyr_old));
    IF (SELECT format('%s:%s:%s', amount, odometer_km, acad_year_id) FROM public.tr_vehicle_service WHERE service_id = vs)
       IS DISTINCT FROM format('4800.00:15000.0:%s', iyr_now) THEN
      bad := bad || ('service: an edit lost a value or changed the year')::text;
    END IF;
    -- refused, each with a readable reason
    bad := bad || pg_temp.fails(format(q, tk_a, base - 'service_date'), 'enter the service date');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('service_date', yfrom - 1)), 'must be in the academic year');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('service_type', 'WASH')), 'choose the service type');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('amount', -5)), 'amount cannot be negative');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('next_due_date', yfrom + 10)), 'next due date cannot be before');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('odometer_km', 900, 'next_due_km', 800)), 'next due km cannot be less');
    INSERT INTO public.tr_vehicle (inst_id, vehicle_code, registration_no, vehicle_type, fuel_type, seating_capacity, ownership_type)
      VALUES (999, 'ZZ-SVC', 'ZZSVC999', 'BUS', 'DIESEL', 30, 'OWNED') RETURNING vehicle_id INTO alien_veh;
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('vehicle_id', alien_veh)), 'vehicle was not found');
    bad := bad || pg_temp.fails(format(q, tk_ac, base), 'no access');
    msg := public.tr_delete(tk_a, 'vehicle_service', vs2);  -- its own statement, so the check below sees the delete
    IF msg IS DISTINCT FROM 'DELETED' OR EXISTS (SELECT 1 FROM public.tr_vehicle_service WHERE service_id = vs2) THEN
      bad := bad || ('service: not deleted (' || COALESCE(msg, '-') || ')')::text;
    END IF;
    n := n + 15;
  END;

  -- 22. Fuel log (tr_fuel_log, the Vehicles screen's Fuel tab): a year
  --     record in the session year's schema, its fill date in that year; an
  --     empty amount is the quantity at the rate; a Vehicles user may list
  --     the staff (to pick who filled) but not change them; readable refusals.
  DECLARE q text := $q$SELECT public.tr_save(%L,'fuel_log',%L)$q$; vh bigint; fl bigint; fl2 bigint; drv bigint; alien_veh bigint;
    alien_drv bigint; base jsonb; yfrom date; tk_v text := repeat('v', 32);
  BEGIN
    SELECT iyrstadate INTO yfrom FROM public.institutionyear WHERE iyr_id = iyr_now;
    vh := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-fuel', 'registration_no', 'ztfuel01', 'vehicle_type', 'VAN',
                                                             'seating_capacity', 12, 'ownership_type', 'OWNED'));
    drv := public.tr_save(tk_a, 'staff', '{"staff_code":"zt-fd","staff_type":"DRIVER","full_name":"Fuel Driver","mobile":"9876500011"}');
    base := jsonb_build_object('vehicle_id', vh, 'fill_date', yfrom + 15, 'quantity', 40);
    fl := public.tr_save(tk_a, 'fuel_log', base || jsonb_build_object('rate', 92.5, 'amount', 3700, 'odometer_km', 15200,
            'bill_no', ' B-101 ', 'filled_by_staff_id', drv, 'inst_id', 999));
    IF (SELECT format('%s:%s:%s:%s:%s', inst_id, created_by, bill_no, amount, filled_by_staff_id) FROM transport20262027.tr_fuel_log WHERE fuel_log_id = fl)
       IS DISTINCT FROM format('1:%s:B-101:3700.00:%s', u, drv) THEN
      bad := bad || ('fuel: the school, maker, bill number, amount or filled by is wrong')::text;
    END IF;
    -- an empty amount is the quantity at the rate
    fl2 := public.tr_save(tk_a, 'fuel_log', base || jsonb_build_object('fill_date', yfrom + 30, 'quantity', 35.5, 'rate', 94.25));
    IF (SELECT amount FROM transport20262027.tr_fuel_log WHERE fuel_log_id = fl2) IS DISTINCT FROM 3345.88 THEN
      bad := bad || ('fuel: an empty amount is not the quantity at the rate')::text;
    END IF;
    -- listed in its year, the latest fill first; another year (its own year
    -- schema, made in section 12) neither lists, changes nor deletes it
    j := public.tr_list(tk_a, 'fuel_log', jsonb_build_object('vehicle_id', vh));
    IF jsonb_array_length(j) <> 2 OR (j->0->>'fuel_log_id')::bigint IS DISTINCT FROM fl2 THEN
      bad := bad || ('fuel: not listed, or not latest first')::text;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.tr_list(tk_old, 'fuel_log')) x WHERE (x->>'fuel_log_id')::bigint IN (fl, fl2)) THEN
      bad := bad || ('fuel: listed in another year')::text;
    END IF;
    bad := bad || pg_temp.fails(format(q, tk_old, jsonb_build_object('fuel_log_id', fl, 'amount', 1)), 'was not found');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_delete(%L,'fuel_log',%s)$q$, tk_old, fl), 'was not found');
    -- an edit keeps the other values, the amount too
    PERFORM public.tr_save(tk_a, 'fuel_log', jsonb_build_object('fuel_log_id', fl, 'quantity', 41));
    IF (SELECT format('%s:%s:%s', quantity, amount, odometer_km) FROM transport20262027.tr_fuel_log WHERE fuel_log_id = fl)
       IS DISTINCT FROM '41.00:3700.00:15200.0' THEN
      bad := bad || ('fuel: an edit lost a value')::text;
    END IF;
    -- refused, each with a readable reason
    bad := bad || pg_temp.fails(format(q, tk_a, base - 'fill_date'), 'enter the fill date');
    bad := bad || pg_temp.fails(format(q, tk_a, base - 'quantity' || '{"amount":100}'), 'enter the quantity');
    bad := bad || pg_temp.fails(format(q, tk_a, base), 'enter the amount, or the rate');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('fill_date', yfrom - 1, 'amount', 100)), 'must be in the academic year');
    bad := bad || pg_temp.fails(format(q, tk_a, base || '{"quantity":0,"amount":100}'), 'quantity must be more than zero');
    bad := bad || pg_temp.fails(format(q, tk_a, base || '{"amount":-5}'), 'amount cannot be negative');
    bad := bad || pg_temp.fails(format(q, tk_a, base || '{"rate":-1}'), 'rate cannot be negative');
    INSERT INTO public.tr_vehicle (inst_id, vehicle_code, registration_no, vehicle_type, fuel_type, seating_capacity, ownership_type)
      VALUES (999, 'ZZ-FUEL', 'ZZFUEL999', 'BUS', 'DIESEL', 30, 'OWNED') RETURNING vehicle_id INTO alien_veh;
    INSERT INTO public.tr_staff (inst_id, staff_code, staff_type, full_name, mobile)
      VALUES (999, 'ZZ-FD', 'DRIVER', 'Other School Driver', '9876500012') RETURNING staff_id INTO alien_drv;
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('vehicle_id', alien_veh, 'amount', 100)), 'vehicle was not found');
    bad := bad || pg_temp.fails(format(q, tk_a, base || jsonb_build_object('filled_by_staff_id', alien_drv, 'amount', 100)), 'staff member was not found');
    bad := bad || pg_temp.fails(format(q, tk_ac, base || '{"amount":100}'), 'no access');
    -- a role with only the Vehicles menu lists the staff but cannot change them
    INSERT INTO public.app_session (token_hash, use_id, ins_id, ur_id, role, yrlabel) VALUES
      (encode(extensions.digest(tk_v, 'sha256'), 'hex'), u, 1, 987654, 'Transport Clerk', '2026-2027');
    INSERT INTO public.rolemenuaccess (ins_id, ur_id, menulabel, activestatus) VALUES (1, 987654, 'Vehicles', 1);
    IF NOT public.tr_list(tk_v, 'staff') @> jsonb_build_array(jsonb_build_object('staff_id', drv)) THEN
      bad := bad || ('fuel: a Vehicles user cannot list the staff')::text;
    END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_save(%L,'staff',%L)$q$, tk_v, jsonb_build_object('staff_id', drv, 'full_name', 'X')), 'no access');
    msg := public.tr_delete(tk_a, 'fuel_log', fl2);  -- its own statement, so the check below sees the delete
    IF msg IS DISTINCT FROM 'DELETED' OR EXISTS (SELECT 1 FROM transport20262027.tr_fuel_log WHERE fuel_log_id = fl2) THEN
      bad := bad || ('fuel: not deleted (' || COALESCE(msg, '-') || ')')::text;
    END IF;
    n := n + 20;
  END;

  -- 23. Who made and who last changed a record (transport_22): the columns
  --     and updated_at triggers are on every table of the list, and each
  --     save that changes a record writes the session's user as updated_by
  --     (a new record has none yet).
  DECLARE vh bigint; sf bigint; dv bigint; vd1 bigint; vd2 bigint; sd bigint; vs bigint; fl bigint; du bigint;
    miss text; yfrom date;
  BEGIN
    SELECT string_agg(format('%s.%s.%s', x.sch, x.tbl, x.col), ', ') INTO miss
      FROM (VALUES ('public', 'tr_settings', 'created_by'),
                   ('public', 'tr_gps_device', 'updated_at'), ('public', 'tr_gps_device', 'updated_by'),
                   ('public', 'tr_vehicle_document', 'updated_at'), ('public', 'tr_vehicle_document', 'updated_by'),
                   ('public', 'tr_vehicle_service', 'updated_at'), ('public', 'tr_vehicle_service', 'updated_by'),
                   ('public', 'tr_staff_document', 'updated_at'), ('public', 'tr_staff_document', 'updated_by'),
                   ('transport20262027', 'tr_stage_fee', 'updated_at'), ('transport20262027', 'tr_stage_fee', 'updated_by'),
                   ('transport20262027', 'tr_fuel_log', 'updated_at'), ('transport20262027', 'tr_fuel_log', 'updated_by'),
                   ('transport20262027', 'tr_duty_assignment', 'updated_at'), ('transport20262027', 'tr_duty_assignment', 'updated_by'),
                   ('transport20262027', 'tr_student_trip_exception', 'updated_at'), ('transport20262027', 'tr_student_trip_exception', 'updated_by'),
                   ('transport20262027', 'tr_staff_leave', 'created_by'), ('transport20262027', 'tr_staff_leave', 'updated_at'), ('transport20262027', 'tr_staff_leave', 'updated_by'),
                   ('transport20262027', 'tr_notify_contact', 'created_by'), ('transport20262027', 'tr_notify_contact', 'updated_at'), ('transport20262027', 'tr_notify_contact', 'updated_by'),
                   ('transport20262027', 'tr_trip', 'created_by'), ('transport20262027', 'tr_trip', 'updated_by')) x(sch, tbl, col)
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                        WHERE c.table_schema = x.sch AND c.table_name = x.tbl AND c.column_name = x.col
                          AND (x.col <> 'updated_at' OR (c.is_nullable = 'NO' AND c.column_default = 'now()')))
        OR (x.col = 'updated_at' AND NOT EXISTS (SELECT 1 FROM pg_trigger t
                                                  WHERE t.tgrelid = format('%I.%I', x.sch, x.tbl)::regclass
                                                    AND t.tgname = 'trg_' || x.tbl || '_upd'));
    IF miss IS NOT NULL THEN bad := bad || ('audit columns or updated_at triggers missing: ' || miss)::text; END IF;
    -- the trigger keeps updated_at, whatever a change sends
    SELECT iyrstadate INTO yfrom FROM public.institutionyear WHERE iyr_id = iyr_now;
    vh := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-aud', 'registration_no', 'ztaud01',
                                                             'vehicle_type', 'VAN', 'seating_capacity', 12, 'ownership_type', 'OWNED'));
    fl := public.tr_save(tk_a, 'fuel_log', jsonb_build_object('vehicle_id', vh, 'fill_date', yfrom + 5, 'quantity', 20, 'amount', 1900));
    UPDATE transport20262027.tr_fuel_log SET updated_at = '2000-01-01' WHERE fuel_log_id = fl;
    IF (SELECT updated_at FROM transport20262027.tr_fuel_log WHERE fuel_log_id = fl) IS DISTINCT FROM now() THEN
      bad := bad || ('the updated_at trigger did not set the time')::text;
    END IF;
    -- a new record: made by the user, not changed by anyone yet
    dv := public.tr_save(tk_a, 'gps_device', '{"device_type":"HARDWARE","imei":"zt-aud-1"}');
    vd1 := public.tr_save(tk_a, 'vehicle_doc', jsonb_build_object('vehicle_id', vh, 'doc_type', 'INSURANCE', 'doc_no', 'AUD1', 'expiry_date', '2027-01-31'));
    sd := public.tr_save(tk_a, 'staff_doc', jsonb_build_object('staff_id', st, 'doc_type', 'MEDICAL_FITNESS', 'expiry_date', '2028-01-01'));
    vs := public.tr_save(tk_a, 'vehicle_service', jsonb_build_object('vehicle_id', vh, 'service_type', 'REPAIR', 'service_date', yfrom + 6));
    SELECT string_agg(x.what, ', ') INTO miss FROM (VALUES
        ('gps device',     (SELECT updated_by FROM public.tr_gps_device WHERE device_id = dv)),
        ('document',       (SELECT updated_by FROM public.tr_vehicle_document WHERE vehicle_doc_id = vd1)),
        ('staff document', (SELECT updated_by FROM public.tr_staff_document WHERE staff_doc_id = sd)),
        ('service record', (SELECT updated_by FROM public.tr_vehicle_service WHERE service_id = vs)),
        ('fuel entry',     (SELECT updated_by FROM transport20262027.tr_fuel_log WHERE fuel_log_id = fl))
      ) x(what, who) WHERE x.who IS NOT NULL;
    IF miss IS NOT NULL THEN bad := bad || ('a new record already says it was changed: ' || miss)::text; END IF;
    -- each change says who made it: the generic save, and a new current
    -- document marking the old one not current
    PERFORM public.tr_save(tk_a, 'gps_device', jsonb_build_object('device_id', dv, 'sim_provider', 'Jio'));
    vd2 := public.tr_save(tk_a, 'vehicle_doc', jsonb_build_object('vehicle_id', vh, 'doc_type', 'INSURANCE', 'doc_no', 'AUD2', 'expiry_date', '2028-01-31'));
    PERFORM public.tr_save(tk_a, 'staff_doc', jsonb_build_object('staff_doc_id', sd, 'doc_no', 'B-9'));
    PERFORM public.tr_save(tk_a, 'vehicle_service', jsonb_build_object('service_id', vs, 'amount', 900));
    PERFORM public.tr_save(tk_a, 'fuel_log', jsonb_build_object('fuel_log_id', fl, 'bill_no', 'F-1'));
    SELECT duty_id INTO du FROM transport20262027.tr_duty_assignment WHERE inst_id = 1 ORDER BY duty_id LIMIT 1;
    IF du IS NOT NULL THEN
      PERFORM public.tr_save(tk_a, 'duty', jsonb_build_object('duty_id', du,
                'effective_to', (SELECT effective_to FROM transport20262027.tr_duty_assignment WHERE duty_id = du)));
    END IF;
    SELECT string_agg(x.what, ', ') INTO miss FROM (VALUES
        ('gps device',      (SELECT updated_by FROM public.tr_gps_device WHERE device_id = dv)),
        ('old document',    (SELECT updated_by FROM public.tr_vehicle_document WHERE vehicle_doc_id = vd1)),
        ('staff document',  (SELECT updated_by FROM public.tr_staff_document WHERE staff_doc_id = sd)),
        ('service record',  (SELECT updated_by FROM public.tr_vehicle_service WHERE service_id = vs)),
        ('fuel entry',      (SELECT updated_by FROM transport20262027.tr_fuel_log WHERE fuel_log_id = fl)),
        ('duty',            CASE WHEN du IS NULL THEN u ELSE (SELECT updated_by FROM transport20262027.tr_duty_assignment WHERE duty_id = du) END)
      ) x(what, who) WHERE x.who IS DISTINCT FROM u;
    IF miss IS NOT NULL THEN bad := bad || ('a change does not say who made it: ' || miss)::text; END IF;
    IF du IS NULL THEN bad := bad || ('section 23 found no duty to change')::text; END IF;
    -- a school's settings row, made on first use, says who made it (school
    -- 1's row is older than the column, so it is made again here)
    DELETE FROM public.tr_settings WHERE inst_id = 1;
    j := public.tr_settings_get(tk_a);
    IF (SELECT format('%s:%s', created_by, updated_by) FROM public.tr_settings WHERE inst_id = 1) IS DISTINCT FROM format('%s:%s', u, u) THEN
      bad := bad || ('the settings row does not say who made it')::text;
    END IF;
    n := n + 6;
  END;

  -- 24. the parent app's bus map (tr_parent_bus): a parent sees their own
  --     child's route, its stops in order with the child's stop marked, the
  --     trip's vehicle and where it is; not another child, not a staff
  --     session; no transport -> enrolled false; Transport off -> enabled false
  DECLARE tk_pb text := repeat('b', 32); pa integer; kid bigint; other bigint; sc bigint; s5 bigint; vb bigint;
  BEGIN
    EXECUTE format('SELECT pd.par_id, pd.stu_id FROM %I.parentdetail pd JOIN %I.students s ON s.stu_id = pd.stu_id
                     WHERE pd.ins_id = 1 AND pd.activestatus = 1 AND s.activestatus = 1
                       AND NOT EXISTS (SELECT 1 FROM transport20262027.tr_student_enrollment e
                                        WHERE e.student_id = s.stu_id AND e.status = ''ACTIVE'')
                     ORDER BY pd.pd_id LIMIT 1', app_sch, app_sch) INTO pa, kid;
    IF kid IS NULL THEN
      RAISE EXCEPTION 'TESTS_FAILED: section 24 needs, in %.parentdetail, an active student without transport', app_sch;
    END IF;
    EXECUTE format('SELECT s.stu_id FROM %I.students s WHERE s.ins_id = 1 AND s.activestatus = 1
                       AND NOT EXISTS (SELECT 1 FROM %I.parentdetail pd WHERE pd.stu_id = s.stu_id AND pd.par_id = $1 AND pd.activestatus = 1)
                     ORDER BY s.stu_id LIMIT 1', app_sch, app_sch) INTO other USING pa;
    INSERT INTO public.app_session (token_hash, par_id, par_mob, ins_id, role) VALUES
      (encode(extensions.digest(tk_pb, 'sha256'), 'hex'), pa, '9999999998', 1, 'parent');
    -- a route of its own: 2 stops (the later one first in pickup order), 1 switched off
    s5 := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', r2, 'stage_id', g2, 'stop_seq', 9, 'stop_name', 'Bus Map End', 'latitude', 13.02, 'longitude', 80.22));
    vb := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-map-1', 'registration_no', 'zt01zz0024',
                                                             'vehicle_type', 'BUS', 'seating_capacity', 40, 'ownership_type', 'OWNED'));
    sc := public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_code', 'zt-map', 'schedule_name', 'Map Pickup', 'route_id', r2,
            'direction', 'PICKUP', 'vehicle_id', vb, 'planned_start', '07:00', 'planned_end', '08:00', 'effective_from', '2026-06-01',
            'stops', jsonb_build_array(jsonb_build_object('stop_id', s5, 'planned_time', '07:10'))));
    INSERT INTO transport20262027.tr_student_enrollment (inst_id, acad_year_id, student_id, route_id, service_type, pickup_stop_id, pickup_schedule_id, fee_stage_id, start_date)
    VALUES (1, iyr_now, kid, r2, 'PICKUP', s5, sc, g2, '2026-06-01');
    INSERT INTO transport20262027.tr_vehicle_live (vehicle_id, inst_id, latitude, longitude, speed_kmph, heading_deg, recorded_at)
    VALUES (vb, 1, 13.015, 80.215, 28.5, 45, now());

    j := public.tr_parent_bus(tk_pb, kid);
    IF (j->>'enabled')::boolean IS NOT TRUE OR (j->>'enrolled')::boolean IS NOT TRUE OR j#>>'{route,code}' IS DISTINCT FROM 'R6' THEN
      bad := bad || ('parent bus: not the child''s route: ' || left(j::text, 120));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'stops') x
                    WHERE (x->>'stop_id')::bigint = s5 AND (x->>'pickup')::boolean AND (x->>'lat')::numeric = 13.02 AND (x->>'lon')::numeric = 80.22) THEN
      bad := bad || ('parent bus: the child''s pickup stop is not marked, or has no position')::text;
    END IF;
    IF (SELECT array_agg((x->>'seq')::int ORDER BY o) FROM jsonb_array_elements(j->'stops') WITH ORDINALITY a(x, o))
       IS DISTINCT FROM (SELECT array_agg(stop_seq::int ORDER BY stop_seq) FROM public.tr_stop WHERE route_id = r2 AND is_active) THEN
      bad := bad || ('parent bus: the stops are not the route''s active stops in pickup order')::text;
    END IF;
    IF jsonb_array_length(j->'trips') <> 1 OR j#>>'{trips,0,direction}' <> 'PICKUP' OR (j#>>'{trips,0,vehicle,vehicle_id}')::bigint IS DISTINCT FROM vb
       OR (j#>>'{trips,0,live,lat}')::numeric IS DISTINCT FROM 13.015 OR j#>>'{trips,0,planned_start}' <> '07:00' THEN
      bad := bad || ('parent bus: the trip, its vehicle or where it is: ' || left((j->'trips')::text, 160));
    END IF;
    n := n + 4;
    IF other IS NOT NULL THEN
      bad := bad || pg_temp.fails(format($q$SELECT public.tr_parent_bus(%L, %s)$q$, tk_pb, other), 'not on your account');
    END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_parent_bus(%L, %s)$q$, tk_a, kid), 'for the parent app');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_parent_bus(%L, %s)$q$, repeat('z', 32), kid), 'expired session');
    n := n + 3;
    -- no position yet: the trip is there without one
    DELETE FROM transport20262027.tr_vehicle_live WHERE vehicle_id = vb;
    IF public.tr_parent_bus(tk_pb, kid)#>'{trips,0,live}' IS DISTINCT FROM 'null'::jsonb THEN
      bad := bad || ('parent bus: a position for a vehicle that sent none')::text;
    END IF;
    -- the transport ended yesterday: nothing to show
    UPDATE transport20262027.tr_student_enrollment SET end_date = (now() AT TIME ZONE 'Asia/Kolkata')::date - 1
     WHERE student_id = kid AND status = 'ACTIVE';
    IF (public.tr_parent_bus(tk_pb, kid)->>'enrolled')::boolean IS NOT FALSE THEN
      bad := bad || ('parent bus: an ended transport still shows')::text;
    END IF;
    -- Transport switched off for the school (Module Control)
    IF EXISTS (SELECT 1 FROM public.modules WHERE ins_id = 1 AND modshort = 'TRN') THEN
      UPDATE public.modules SET activestatus = 0 WHERE ins_id = 1 AND modshort = 'TRN';
    ELSE
      INSERT INTO public.modules (ins_id, modtype, modname, modshort, activestatus) VALUES (1, 'C', 'Transport', 'TRN', 0);
    END IF;
    IF (public.tr_parent_bus(tk_pb, kid)->>'enabled')::boolean IS NOT FALSE THEN
      bad := bad || ('parent bus: shown while Transport is switched off')::text;
    END IF;
    n := n + 3;
  END;

  -- 25. Daily Trips (transport_24-26): a day's trips are made from the
  --     schedules with their students, staff riders and crew; a trip's
  --     vehicle and crew change for that day only. Its own route, two
  --     pickup trips at the same time, a 1-seat car, a van and a bus.
  DECLARE d date; rs bigint; gs bigint; ps bigint; v1 bigint; v2 bigint; v40 bigint; dr1 bigint; dr2 bigint; at1 bigint;
    sa bigint; sb bigint; st bigint; fa numeric; ta bigint; tb bigint; up timestamptz; k integer; nt bigint; tc bigint; es bigint; ef bigint;
    qb text := $q$SELECT public.tr_trip_board_save(%L,%L)$q$;
    q text := $q$SELECT public.tr_trip_save(%L,%L)$q$;
    qr text := $q$SELECT public.tr_trip_replace(%L,%L)$q$;
  BEGIN
    IF NOT transport_core._staff_ready(app_sch, 'transport20262027') OR to_regclass('transport20262027.tr_trip_staff_rider') IS NULL THEN
      RAISE EXCEPTION 'TESTS_FAILED: section 25 needs staff transport (transport_23, transport_24)';
    END IF;
    -- a school day (Monday to Saturday) after today, in the session year
    SELECT g::date INTO d FROM generate_series(transport_core._today() + 1, transport_core._today() + 8, interval '1 day') g
     WHERE extract(isodow FROM g) BETWEEN 1 AND 6 ORDER BY g LIMIT 1;
    IF NOT EXISTS (SELECT 1 FROM public.institutionyear WHERE iyr_id = iyr_now AND d BETWEEN iyrstadate AND iyrenddate) THEN
      RAISE EXCEPTION 'TESTS_FAILED: section 25 needs % in the session year', d;
    END IF;
    rs := public.tr_save(tk_a, 'route', '{"route_code":"zt-dt","route_name":"Daily Line"}');
    gs := public.tr_save(tk_a, 'stage', jsonb_build_object('route_id', rs, 'stage_no', 1, 'stage_name', 'Near'));
    ps := public.tr_save(tk_a, 'stop', jsonb_build_object('route_id', rs, 'stage_id', gs, 'stop_seq', 1, 'stop_name', 'Daily Corner', 'latitude', 13.05, 'longitude', 80.25));
    v1 := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'PETROL', 'vehicle_code', 'zt-dt-car', 'registration_no', 'zt01dt0001',
                                                             'vehicle_type', 'VAN', 'seating_capacity', 1, 'ownership_type', 'OWNED'));
    v2 := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-dt-van', 'registration_no', 'zt01dt0002',
                                                             'vehicle_type', 'VAN', 'seating_capacity', 2, 'ownership_type', 'OWNED'));
    v40 := public.tr_save(tk_a, 'vehicle', jsonb_build_object('fuel_type', 'DIESEL', 'vehicle_code', 'zt-dt-bus', 'registration_no', 'zt01dt0040',
                                                              'vehicle_type', 'BUS', 'seating_capacity', 40, 'ownership_type', 'OWNED'));
    dr1 := public.tr_save(tk_a, 'staff', '{"staff_code":"zt-dt-d1","staff_type":"DRIVER","full_name":"Day Driver One","mobile":"9876511101"}');
    dr2 := public.tr_save(tk_a, 'staff', '{"staff_code":"zt-dt-d2","staff_type":"DRIVER","full_name":"Day Driver Two","mobile":"9876511102"}');
    at1 := public.tr_save(tk_a, 'staff', '{"staff_code":"zt-dt-a1","staff_type":"ATTENDER","full_name":"Day Attender","mobile":"9876511103"}');
    sa := public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_code', 'zt-dt-a', 'schedule_name', 'Day Van', 'route_id', rs, 'direction', 'PICKUP',
            'vehicle_id', v2, 'planned_start', '07:00', 'planned_end', '07:30', 'run_days', '[1,2,3,4,5,6]'::jsonb, 'effective_from', '2026-06-01',
            'stops', jsonb_build_array(jsonb_build_object('stop_id', ps, 'planned_time', '07:10'))));
    sb := public.tr_save(tk_a, 'schedule', jsonb_build_object('schedule_code', 'zt-dt-b', 'schedule_name', 'Day Bus', 'route_id', rs, 'direction', 'PICKUP',
            'vehicle_id', v40, 'planned_start', '07:00', 'planned_end', '07:30', 'run_days', '[1,2,3,4,5,6]'::jsonb, 'effective_from', '2026-06-01',
            'stops', jsonb_build_array(jsonb_build_object('stop_id', ps, 'planned_time', '07:10'))));
    PERFORM public.tr_save(tk_a, 'duty', jsonb_build_object('schedule_id', sa, 'staff_id', dr1, 'duty_role', 'DRIVER', 'effective_from', '2026-06-01'));
    PERFORM public.tr_save(tk_a, 'duty', jsonb_build_object('schedule_id', sa, 'staff_id', at1, 'duty_role', 'ATTENDER', 'effective_from', '2026-06-01'));
    PERFORM public.tr_save(tk_a, 'duty', jsonb_build_object('schedule_id', sb, 'staff_id', dr2, 'duty_role', 'DRIVER', 'effective_from', '2026-06-01'));
    -- a student and a staff member on the route: the student allotted to A's van, the staff member to no vehicle yet
    EXECUTE format('SELECT s.stu_id FROM %I.students s WHERE s.ins_id = 1 AND s.activestatus = 1
                      AND NOT EXISTS (SELECT 1 FROM transport20262027.tr_student_enrollment e WHERE e.student_id = s.stu_id AND e.status = ''ACTIVE'')
                     ORDER BY s.stu_id LIMIT 1', app_sch) INTO st;
    EXECUTE format('SELECT m.staf_id FROM %I.staffmast m JOIN public.schstaff s ON s.staf_id = m.staf_id WHERE s.ins_id = 1 ORDER BY m.staf_id LIMIT 1', app_sch) INTO fa;
    IF st IS NULL OR fa IS NULL THEN RAISE EXCEPTION 'TESTS_FAILED: section 25 needs a student with no transport and a staff member in %', app_sch; END IF;
    EXECUTE format('UPDATE %I.staffmast SET is_active = true, transportreq = ''BUS'' WHERE staf_id = $1', app_sch) USING fa;
    UPDATE transport20262027.tr_staff_enrollment SET status = 'CANCELLED' WHERE staf_id = fa AND status = 'ACTIVE';
    PERFORM public.tr_save(tk_a, 'enrollment', jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
              jsonb_build_object('student_id', st, 'service_type', 'BOTH', 'pickup_stop_id', ps, 'drop_stop_id', ps, 'start_date', '2026-06-01'))));
    PERFORM public.tr_save(tk_a, 'staff_enrollment', jsonb_build_object('route_id', rs, 'rows', jsonb_build_array(
              jsonb_build_object('staf_id', fa, 'service_type', 'BOTH', 'pickup_stop_id', ps, 'drop_stop_id', ps, 'start_date', '2026-06-01'))));
    PERFORM public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', rs, 'direction', 'PICKUP', 'rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', (SELECT enrollment_id FROM transport20262027.tr_student_enrollment
                                                    WHERE route_id = rs AND student_id = st AND status = 'ACTIVE'), 'schedule_id', sa))));

    -- Make Trips: the day's trips with their riders and crew; a second time makes none
    IF public.tr_trips_make(tk_a, d) < 2 THEN bad := bad || ('Make Trips did not make the day''s trips')::text; END IF;
    SELECT trip_id INTO ta FROM transport20262027.tr_trip WHERE schedule_id = sa AND trip_date = d;
    SELECT trip_id INTO tb FROM transport20262027.tr_trip WHERE schedule_id = sb AND trip_date = d;
    -- two pickups on the route: the staff member, allotted to neither, rides neither; B (no one allotted) expects nobody
    IF EXISTS (SELECT 1 FROM transport20262027.tr_trip_staff_rider WHERE trip_id IN (ta, tb))
       OR EXISTS (SELECT 1 FROM transport20262027.tr_trip_student WHERE trip_id = tb) THEN
      bad := bad || ('a rider is on a trip of a vehicle not allotted to them')::text;
    END IF;
    -- allotted after the trips were made: the trips follow (the staff member onto B, then onto A)
    PERFORM public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', rs, 'direction', 'PICKUP', 'staff_rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', (SELECT enrollment_id FROM transport20262027.tr_staff_enrollment
                                                    WHERE route_id = rs AND staf_id = fa AND status = 'ACTIVE'), 'schedule_id', sb))));
    IF (SELECT count(*) FROM transport20262027.tr_trip_staff_rider WHERE trip_id = tb AND staf_id = fa) <> 1
       OR EXISTS (SELECT 1 FROM transport20262027.tr_trip_staff_rider WHERE trip_id = ta) THEN
      bad := bad || ('the trips did not follow an allotment made after them')::text;
    END IF;
    PERFORM public.tr_save(tk_a, 'allotment', jsonb_build_object('route_id', rs, 'direction', 'PICKUP', 'staff_rows', jsonb_build_array(
              jsonb_build_object('enrollment_id', (SELECT enrollment_id FROM transport20262027.tr_staff_enrollment
                                                    WHERE route_id = rs AND staf_id = fa AND status = 'ACTIVE'), 'schedule_id', sa))));
    IF EXISTS (SELECT 1 FROM transport20262027.tr_trip_staff_rider WHERE trip_id = tb) THEN
      bad := bad || ('a rider moved to another vehicle stayed on the old trip')::text;
    END IF;
    IF (SELECT count(*) FROM transport20262027.tr_trip_student WHERE trip_id = ta AND student_id = st AND status = 'EXPECTED') <> 1
       OR (SELECT count(*) FROM transport20262027.tr_trip_staff_rider WHERE trip_id = ta AND staf_id = fa AND status = 'EXPECTED') <> 1
       OR (SELECT string_agg(duty_role || ':' || staff_id, ',' ORDER BY duty_role) FROM transport20262027.tr_trip_staff WHERE trip_id = ta)
          IS DISTINCT FROM format('ATTENDER:%s,DRIVER:%s', at1, dr1) THEN
      bad := bad || ('the day''s trip lacks its student, its staff rider or its crew')::text;
    END IF;
    IF public.tr_trips_make(tk_a, d) <> 0 THEN bad := bad || ('Make Trips made a day''s trips twice')::text; END IF;
    j := public.tr_daily_trips(tk_a, d);
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'trips') x
                    WHERE (x->>'trip_id')::bigint = ta AND (x->>'students')::int = 1 AND (x->>'staff')::int = 1
                      AND (x->>'editable')::boolean AND (x->>'vehicle_id')::bigint = v2 AND jsonb_array_length(x->'crew') = 2) THEN
      bad := bad || ('Daily Trips does not list the trip with its riders, vehicle and crew')::text;
    END IF;

    -- the vehicle: seats for the riders, and not on another trip at the same time; a swap is one save
    SELECT updated_at INTO up FROM transport20262027.tr_trip WHERE trip_id = ta;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', ta, 'updated_at', up, 'vehicle_id', v1)))), 'expects 2 riders');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', ta, 'vehicle_id', v40)))), 'at the same time');
    k := public.tr_trip_save(tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
           jsonb_build_object('trip_id', ta, 'updated_at', up, 'vehicle_id', v40), jsonb_build_object('trip_id', tb, 'vehicle_id', v2))));
    IF k <> 2 OR (SELECT vehicle_id FROM transport20262027.tr_trip WHERE trip_id = ta) IS DISTINCT FROM v40
       OR (SELECT vehicle_id FROM transport20262027.tr_trip WHERE trip_id = tb) IS DISTINCT FROM v2 THEN
      bad := bad || format('the two trips did not swap their vehicles: saved %s, A has %s, B has %s (van %s, bus %s)', k,
               (SELECT vehicle_id FROM transport20262027.tr_trip WHERE trip_id = ta),
               (SELECT vehicle_id FROM transport20262027.tr_trip WHERE trip_id = tb), v2, v40);
    END IF;
    -- the crew: a driver drives, and one trip at a time; drivers swap in one save, as substitutes
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', ta, 'driver_id', at1)))), 'is not a driver');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', ta, 'driver_id', dr2)))), 'at the same time');
    k := public.tr_trip_save(tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
           jsonb_build_object('trip_id', ta, 'driver_id', dr2, 'attender_id', null), jsonb_build_object('trip_id', tb, 'driver_id', dr1))));
    IF (SELECT string_agg(duty_role || ':' || staff_id || ':' || is_substitute, ',') FROM transport20262027.tr_trip_staff WHERE trip_id = ta)
          IS DISTINCT FROM format('DRIVER:%s:true', dr2)
       OR (SELECT string_agg(duty_role || ':' || staff_id || ':' || is_substitute, ',') FROM transport20262027.tr_trip_staff WHERE trip_id = tb)
          IS DISTINCT FROM format('DRIVER:%s:true', dr1) THEN
      bad := bad || ('the drivers were not swapped as substitutes, or the attender stayed')::text;
    END IF;
    -- an old copy (one transaction: now() does not move, so the copy is a second older), a cancelled trip, a past day, and the menu
    SELECT updated_at INTO up FROM transport20262027.tr_trip WHERE trip_id = ta;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', ta, 'updated_at', up - interval '1 second', 'vehicle_id', v2)))), 'changed by someone else');
    UPDATE transport20262027.tr_trip SET status = 'CANCELLED' WHERE trip_id = tb;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', tb, 'vehicle_id', v40)))), 'is cancelled');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_trips_make(%L,%L)$q$, tk_a, transport_core._today() - 1), 'past day');
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_daily_trips(%L,%L)$q$, tk_ac, d), 'no access');
    bad := bad || pg_temp.fails(format(q, tk_ac, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', ta, 'vehicle_id', v2)))), 'no access');
    -- cancel needs its reason; a cancelled trip changes only by being restored
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', ta, 'status', 'CANCELLED')))), 'give the reason');
    k := public.tr_trip_save(tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
           jsonb_build_object('trip_id', ta, 'status', 'CANCELLED', 'cancel_reason', ' Road closed '))));
    IF k <> 1 OR (SELECT status || ':' || cancel_reason FROM transport20262027.tr_trip WHERE trip_id = ta) IS DISTINCT FROM 'CANCELLED:Road closed' THEN
      bad := bad || ('the trip was not cancelled with its reason')::text;
    END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_trip_board_save(%L,%L)$q$, tk_a,
             jsonb_build_object('trip_date', d, 'trip_id', ta, 'students', '[]'::jsonb)), 'is cancelled');
    PERFORM public.tr_trip_save(tk_a, jsonb_build_object('trip_date', d, 'trips', jsonb_build_array(
              jsonb_build_object('trip_id', ta, 'status', 'SCHEDULED'))));
    IF (SELECT status || ':' || COALESCE(cancel_reason, '-') FROM transport20262027.tr_trip WHERE trip_id = ta) IS DISTINCT FROM 'SCHEDULED:-' THEN
      bad := bad || ('the cancelled trip was not restored')::text;
    END IF;
    -- boarding: from the trip's day on
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_trip_board_save(%L,%L)$q$, tk_a,
             jsonb_build_object('trip_date', d, 'trip_id', ta, 'students', '[]'::jsonb)), 'can be entered from its day');
    UPDATE transport20262027.tr_trip SET trip_date = transport_core._today() WHERE trip_id = ta;
    j := public.tr_trip_riders(tk_a, transport_core._today(), ta);
    IF (j->>'can_mark')::boolean IS NOT TRUE OR jsonb_array_length(j->'students') <> 1 OR jsonb_array_length(j->'staff') <> 1
       OR j->'students'->0->>'stuname' IS NULL OR j->'staff'->0->>'stafname' IS NULL OR j->'students'->0->>'stop_name' IS NULL
       OR j->>'direction' IS DISTINCT FROM 'PICKUP' THEN
      bad := bad || ('the trip''s students and staff are not listed for boarding')::text;
    END IF;
    PERFORM public.tr_trip_board_save(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta,
              'students', jsonb_build_array(jsonb_build_object('enrollment_id', (j->'students'->0->>'enrollment_id')::bigint, 'status', 'PARENT_PICKUP')),
              'staff', jsonb_build_array(jsonb_build_object('enrollment_id', (j->'staff'->0->>'enrollment_id')::bigint, 'status', 'PRESENT'))));
    IF (SELECT status FROM transport20262027.tr_trip_student WHERE trip_id = ta AND student_id = st) IS DISTINCT FROM 'PARENT_PICKUP'
       OR (SELECT status || ':' || (boarded_at IS NOT NULL) || ':' || mark_method FROM transport20262027.tr_trip_staff_rider WHERE trip_id = ta AND staf_id = fa)
          IS DISTINCT FROM 'BOARDED:true:MANUAL' THEN
      bad := bad || ('the boarding entry was not saved')::text;
    END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_trip_board_save(%L,%L)$q$, tk_a,
             jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta, 'staff', jsonb_build_array(
               jsonb_build_object('enrollment_id', (j->'staff'->0->>'enrollment_id')::bigint, 'status', 'PARENT_PICKUP')))), 'choose present, absent');
    PERFORM public.tr_trip_board_save(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta,
              'students', jsonb_build_array(jsonb_build_object('enrollment_id', (j->'students'->0->>'enrollment_id')::bigint, 'status', 'BOARDED'))));
    IF (SELECT boarded_students FROM transport20262027.tr_trip WHERE trip_id = ta) IS DISTINCT FROM 1::smallint THEN
      bad := bad || ('the picked student is not counted on the trip')::text;
    END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_trip_board_save(%L,%L)$q$, tk_a,
             jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta, 'students', jsonb_build_array(
               jsonb_build_object('enrollment_id', (j->'students'->0->>'enrollment_id')::bigint, 'status', 'NO_SHOW')))), 'choose present, absent');
    -- on a drop, present is alighted (got off at the stop; when it boarded is kept); absent stays absent
    UPDATE transport20262027.tr_trip SET direction = 'DROP' WHERE trip_id = ta;
    PERFORM public.tr_trip_board_save(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta,
              'students', jsonb_build_array(jsonb_build_object('enrollment_id', (j->'students'->0->>'enrollment_id')::bigint, 'status', 'PRESENT')),
              'staff', jsonb_build_array(jsonb_build_object('enrollment_id', (j->'staff'->0->>'enrollment_id')::bigint, 'status', 'ABSENT'))));
    IF (SELECT status || ':' || (alighted_at IS NOT NULL) || ':' || (boarded_at IS NOT NULL) FROM transport20262027.tr_trip_student WHERE trip_id = ta AND student_id = st)
          IS DISTINCT FROM 'ALIGHTED:true:true'
       OR (SELECT status || ':' || (boarded_at IS NULL) FROM transport20262027.tr_trip_staff_rider WHERE trip_id = ta AND staf_id = fa) IS DISTINCT FROM 'ABSENT:true'
       OR (SELECT boarded_students FROM transport20262027.tr_trip WHERE trip_id = ta) IS DISTINCT FROM 1::smallint THEN
      bad := bad || ('a drop''s present was not saved as alighted')::text;
    END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_trip_riders(%L,%L,%s)$q$, tk_ac, transport_core._today(), ta), 'no access');
    -- Replace Trip: A (today, the bus, driver 2, its riders marked) cancelled and run by the van, with its
    -- riders as marked, once; only a cancelled trip, another vehicle, a driver, and the menu
    bad := bad || pg_temp.fails(format(qr, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta,
             'vehicle_id', v2, 'driver_id', dr1)), 'Only a cancelled trip');
    PERFORM public.tr_trip_save(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trips', jsonb_build_array(
              jsonb_build_object('trip_id', ta, 'status', 'CANCELLED', 'cancel_reason', 'Bus breakdown'))));
    bad := bad || pg_temp.fails(format(qr, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta,
             'vehicle_id', v40, 'driver_id', dr1)), 'own vehicle');
    bad := bad || pg_temp.fails(format(qr, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta,
             'vehicle_id', v2)), 'Choose the driver');
    bad := bad || pg_temp.fails(format(qr, tk_ac, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta,
             'vehicle_id', v2, 'driver_id', dr1)), 'no access');
    nt := public.tr_trip_replace(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta,
            'vehicle_id', v2, 'driver_id', dr1, 'attender_id', at1));
    IF (SELECT format('%s:%s:%s:%s:%s', replaces_trip_id, status, vehicle_id, schedule_id, trip_date) FROM transport20262027.tr_trip WHERE trip_id = nt)
          IS DISTINCT FROM format('%s:SCHEDULED:%s:%s:%s', ta, v2, sa, transport_core._today())
       OR (SELECT status FROM transport20262027.tr_trip_student WHERE trip_id = nt AND student_id = st) IS DISTINCT FROM 'ALIGHTED'
       OR (SELECT status FROM transport20262027.tr_trip_staff_rider WHERE trip_id = nt AND staf_id = fa) IS DISTINCT FROM 'ABSENT'
       OR (SELECT count(*) FROM transport20262027.tr_trip_stop WHERE trip_id = nt) <> (SELECT count(*) FROM transport20262027.tr_trip_stop WHERE trip_id = ta)
       OR (SELECT string_agg(duty_role || ':' || staff_id || ':' || is_substitute, ',' ORDER BY duty_role) FROM transport20262027.tr_trip_staff WHERE trip_id = nt)
          IS DISTINCT FROM format('ATTENDER:%s:false,DRIVER:%s:false', at1, dr1) THEN
      bad := bad || ('the replacement trip was not made like the cancelled one, with the vehicle and crew chosen')::text;
    END IF;
    j := public.tr_daily_trips(tk_a, transport_core._today());
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'trips') x WHERE (x->>'trip_id')::bigint = ta
                      AND (x->>'replaced_by_trip_id')::bigint = nt
                      AND x->>'replaced_by_vehicle_code' = (SELECT vehicle_code FROM public.tr_vehicle WHERE vehicle_id = v2))
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'trips') x WHERE (x->>'trip_id')::bigint = nt
                      AND (x->>'replaces_trip_id')::bigint = ta AND (x->>'editable')::boolean
                      AND x->>'replaces_vehicle_code' = (SELECT vehicle_code FROM public.tr_vehicle WHERE vehicle_id = v40)) THEN
      bad := bad || format('Daily Trips does not show the trip and its replacement: %s',
               (SELECT jsonb_agg(x) FROM jsonb_array_elements(j->'trips') x WHERE (x->>'trip_id')::bigint IN (ta, nt)));
    END IF;
    bad := bad || pg_temp.fails(format(qr, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', ta,
             'vehicle_id', v1, 'driver_id', dr2)), 'already replaced');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', ta, 'status', 'SCHEDULED')))), 'cannot be restored');
    PERFORM public.tr_trips_make(tk_a, transport_core._today());
    IF (SELECT count(*) FROM transport20262027.tr_trip WHERE schedule_id = sa AND trip_date = transport_core._today()) <> 2 THEN
      bad := bad || ('Make Trips made a replaced trip again')::text;
    END IF;

    -- Add Student / Add Staff: a rider of the route on another vehicle's trip that way (here A's replacement,
    -- turned back into A's pickup) rides B's trip of today instead; one already present elsewhere is refused
    UPDATE transport20262027.tr_trip SET direction = 'PICKUP' WHERE trip_id = nt;
    SELECT trip_id INTO tc FROM transport20262027.tr_trip WHERE schedule_id = sb AND trip_date = transport_core._today();
    SELECT enrollment_id INTO es FROM transport20262027.tr_student_enrollment WHERE route_id = rs AND student_id = st AND status = 'ACTIVE';
    SELECT enrollment_id INTO ef FROM transport20262027.tr_staff_enrollment WHERE route_id = rs AND staf_id = fa AND status = 'ACTIVE';
    PERFORM public.tr_trip_board_save(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', nt,
              'staff', jsonb_build_array(jsonb_build_object('enrollment_id', ef, 'status', 'EXPECTED'))));
    j := public.tr_trip_rider_options(tk_a, transport_core._today(), tc);
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'students') x
                    WHERE (x->>'enrollment_id')::bigint = es AND (x->>'present')::boolean AND (x->>'on_trip_id')::bigint = nt)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'staff') x
                       WHERE (x->>'enrollment_id')::bigint = ef AND NOT (x->>'present')::boolean AND (x->>'on_trip_id')::bigint = nt
                         AND x->>'on_status' = 'EXPECTED') THEN
      bad := bad || format('Add Student / Add Staff does not offer the route''s riders of other trips: %s', j);
    END IF;
    bad := bad || pg_temp.fails(format(qb, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', tc,
             'students', jsonb_build_array(jsonb_build_object('enrollment_id', es, 'status', 'PRESENT', 'add', true)))), 'already present on trip');
    PERFORM public.tr_trip_board_save(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', tc,
              'staff', jsonb_build_array(jsonb_build_object('enrollment_id', ef, 'status', 'PRESENT', 'add', true))));
    IF (SELECT status || ':' || is_extra || ':' || mark_method FROM transport20262027.tr_trip_staff_rider WHERE trip_id = tc AND staf_id = fa)
          IS DISTINCT FROM 'BOARDED:true:MANUAL'
       OR (SELECT status FROM transport20262027.tr_trip_staff_rider WHERE trip_id = nt AND staf_id = fa) IS DISTINCT FROM 'ABSENT' THEN
      bad := bad || ('the added staff member is not present on the trip, or still expected on their own')::text;
    END IF;
    bad := bad || pg_temp.fails(format(qb, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', tc,
             'staff', jsonb_build_array(jsonb_build_object('enrollment_id', ef, 'status', 'PRESENT', 'add', true)))), 'is already on trip');
    bad := bad || pg_temp.fails(format(qb, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', nt,
             'staff', jsonb_build_array(jsonb_build_object('enrollment_id', ef, 'status', 'PRESENT')))), 'already present on trip');
    -- the trips follow the allotment, but keep a rider added
    PERFORM transport_core.fn_sync_trip_riders('transport20262027', tc);
    j := public.tr_trip_riders(tk_a, transport_core._today(), tc);
    IF jsonb_array_length(j->'staff') <> 1 OR (j->'staff'->0->>'is_extra')::boolean IS NOT TRUE THEN
      bad := bad || ('an added rider was not kept on the trip, or not shown as added')::text;
    END IF;
    -- taken off again; only an added rider can be, and the menu
    bad := bad || pg_temp.fails(format(qb, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', nt,
             'students', jsonb_build_array(jsonb_build_object('enrollment_id', es, 'status', 'REMOVE')))), 'Only a student added');
    PERFORM public.tr_trip_board_save(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trip_id', tc,
              'staff', jsonb_build_array(jsonb_build_object('enrollment_id', ef, 'status', 'REMOVE'))));
    IF EXISTS (SELECT 1 FROM transport20262027.tr_trip_staff_rider WHERE trip_id = tc AND staf_id = fa) THEN
      bad := bad || ('the added rider was not taken off')::text;
    END IF;
    bad := bad || pg_temp.fails(format($q$SELECT public.tr_trip_rider_options(%L,%L,%s)$q$, tk_ac, transport_core._today(), tc), 'no access');

    -- Completed: on the trip's day or after (a past day's only its status), ended when marked; then
    -- fixed until set back to Scheduled (today), and its boarding can still be entered
    PERFORM public.tr_trip_save(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trips', jsonb_build_array(
              jsonb_build_object('trip_id', tc, 'status', 'COMPLETED'))));
    IF (SELECT status || ':' || (actual_end_at IS NOT NULL) || ':' || end_source FROM transport20262027.tr_trip WHERE trip_id = tc)
         IS DISTINCT FROM 'COMPLETED:true:ADMIN'
       OR (public.tr_trip_riders(tk_a, transport_core._today(), tc)->>'can_mark')::boolean IS NOT TRUE THEN
      bad := bad || ('the trip was not completed, or its boarding cannot be entered any more')::text;
    END IF;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', tc, 'vehicle_id', v1)))), 'is completed');
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', tc, 'status', 'CANCELLED', 'cancel_reason', 'x')))), 'is completed');
    PERFORM public.tr_trip_save(tk_a, jsonb_build_object('trip_date', transport_core._today(), 'trips', jsonb_build_array(
              jsonb_build_object('trip_id', tc, 'status', 'SCHEDULED'))));
    IF (SELECT status || ':' || (actual_end_at IS NULL) || ':' || COALESCE(end_source, '-') FROM transport20262027.tr_trip WHERE trip_id = tc)
         IS DISTINCT FROM 'SCHEDULED:true:-' THEN
      bad := bad || ('the completed trip was not set back to Scheduled')::text;
    END IF;
    UPDATE transport20262027.tr_trip SET trip_date = d + 1 WHERE trip_id = tc;  -- (B's own trip is on d)
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', d + 1, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', tc, 'status', 'COMPLETED')))), 'can be completed on that day or after');
    UPDATE transport20262027.tr_trip SET trip_date = transport_core._today() - 1 WHERE trip_id = tc;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', transport_core._today() - 1, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', tc, 'status', 'COMPLETED', 'vehicle_id', v1)))), 'past day');
    PERFORM public.tr_trip_save(tk_a, jsonb_build_object('trip_date', transport_core._today() - 1, 'trips', jsonb_build_array(
              jsonb_build_object('trip_id', tc, 'status', 'COMPLETED'))));
    IF (SELECT status FROM transport20262027.tr_trip WHERE trip_id = tc) IS DISTINCT FROM 'COMPLETED' THEN
      bad := bad || ('a past day''s trip could not be completed')::text;
    END IF;
    bad := bad || pg_temp.fails(format(q, tk_a, jsonb_build_object('trip_date', transport_core._today() - 1, 'trips', jsonb_build_array(
             jsonb_build_object('trip_id', tc, 'status', 'SCHEDULED')))), 'past day');
    -- the nightly run makes tomorrow's trips without failing
    PERFORM transport_core.generate_next_day_trips();
    n := n + 25;
  END;

  bad := array_remove(bad, NULL);
  IF cardinality(bad) > 0 THEN RAISE EXCEPTION 'TESTS_FAILED % of %: %', cardinality(bad), n, array_to_string(bad, ' || '); END IF;
  RAISE EXCEPTION 'TESTS_OK % checks', n;
END $t$;
