-- =====================================================================
--  SCHOOL TRANSPORT - Phase 1 API (masters)
--  Run after transport_01_schema.sql, transport_04_move_masters_to_public.sql
--  and transport_05_year_schemas.sql. Safe to run again.
--
--  Where things live:
--    public          the masters (tr_settings, tr_route, tr_stage, tr_stop,
--                    tr_vendor, tr_vehicle*, tr_gps_device, tr_staff*),
--                    shared by all years
--    transport<yyyy><yyyy> one schema per academic year (2026-2027 -> transport20262027)
--                    with the year's records, e.g. tr_stage_fee, tr_trip_schedule
--    transport_core  these functions
--  The app reaches all of it only through the public.tr_* functions below.
--  anon has no grants on the tables and no access to the other schemas.
--  Every call:
--    * needs a staff session token (parent sessions are refused),
--    * takes the school and the academic year from the session, never from
--      the caller; the year also picks the year schema,
--    * checks the role against the entity's menu in Roles & Access,
--    * writes only the columns listed for that entity in transport_core._entity.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Session: who is calling, for which school and academic year, and that
-- year's schema (ysch; it may not exist yet - see _year).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._ctx(
  p_token text, p_menus text[] DEFAULT NULL, p_default text DEFAULT 'admin',
  OUT ins integer, OUT usr integer, OUT iyr bigint, OUT yr text, OUT ysch text)
RETURNS record LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE v record; v_label text;
BEGIN
  SELECT c.use_id, c.ins_id, c.ur_id, c.role INTO v FROM public.session_context(p_token) c;
  IF v.use_id IS NULL THEN
    RAISE EXCEPTION 'Transport is for school staff. Please sign in with a staff login.';
  END IF;
  IF COALESCE(v.ins_id, 0) <= 0 THEN
    RAISE EXCEPTION 'Sign in to a school to use Transport.';
  END IF;
  IF p_menus IS NOT NULL AND NOT public._role_can(v.ins_id, v.ur_id, v.role, p_menus, p_default) THEN
    RAISE EXCEPTION 'Your role (%) has no access to %. Ask the Admin to grant it in Setup -> Roles & Access.',
      COALESCE(NULLIF(v.role, ''), '-'), p_menus[1];
  END IF;
  ins := v.ins_id;
  usr := v.use_id;
  v_label := NULLIF(current_setting('app.session_yrlabel', true), '');
  SELECT iy.iyr_id, iy.yrlabel INTO iyr, yr
    FROM public.institutionyear iy
   WHERE iy.ins_id = v.ins_id AND iy.activestatus = 1
   ORDER BY (iy.yrlabel IS NOT DISTINCT FROM v_label) DESC,
            (CURRENT_DATE BETWEEN COALESCE(iy.iyrstadate, '-infinity'::date) AND COALESCE(iy.iyrenddate, 'infinity'::date)) DESC,
            iy.yrlabel DESC
   LIMIT 1;
  ysch := transport_core.year_schema(yr);
END $$;

-- The session year's schema, or a readable error when that year has not
-- been started with transport_core.create_year_schema.
CREATE OR REPLACE FUNCTION transport_core._year(p_ysch text, p_yr text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_ysch IS NULL OR to_regnamespace(p_ysch) IS NULL THEN
    RAISE EXCEPTION 'Transport has not been set up for the year %. Ask the Admin to start it.', COALESCE(p_yr, '-');
  END IF;
  RETURN p_ysch;
END $$;

-- The main app's students of an academic year live in that year's own
-- schema (institutionyear.iyrschema, e.g. ongc20262027.students). Returns
-- it, with the year's first and last day, or a readable error.
CREATE OR REPLACE FUNCTION transport_core._student_year(p_iyr bigint, OUT sch text, OUT from_date date, OUT to_date date)
RETURNS record LANGUAGE plpgsql STABLE
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
BEGIN
  SELECT iy.iyrschema, iy.iyrstadate, iy.iyrenddate INTO sch, from_date, to_date
    FROM public.institutionyear iy WHERE iy.iyr_id = p_iyr;
  IF sch IS NULL OR to_regclass(format('%I.students', sch)) IS NULL THEN
    RAISE EXCEPTION 'The students of this academic year were not found.';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- What each entity is, and which columns the app may write.
-- sch: 'public' for a master; NULL for a year record, which goes to the
--      session year's schema.
-- parents: column -> [schema, table, key, noun]. An empty schema means the
--          session year's schema.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._entity(
  p text,
  OUT sch text, OUT tbl text, OUT pk text, OUT noun text, OUT menus text[], OUT cols text[], OUT req jsonb,
  OUT upper_cols text[], OUT parents jsonb, OUT del text, OUT ord text, OUT has_upd boolean)
RETURNS record LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  sch := 'public'; upper_cols := '{}'; parents := '{}'; has_upd := true;
  CASE p
  WHEN 'route' THEN
    tbl := 'tr_route'; pk := 'route_id'; noun := 'route'; menus := ARRAY['Routes & Stops'];
    cols := ARRAY['route_code','route_name','description','start_point','end_point','total_distance_km','est_duration_min','is_active'];
    req := '{"route_code":"route code","route_name":"route name"}';
    upper_cols := ARRAY['route_code']; del := 'active'; ord := 't.route_code';
  WHEN 'stage' THEN
    tbl := 'tr_stage'; pk := 'stage_id'; noun := 'stage'; menus := ARRAY['Routes & Stops'];
    cols := ARRAY['route_id','stage_no','stage_name','from_km','to_km','is_active'];
    req := '{"route_id":"route","stage_no":"stage number","stage_name":"stage name"}';
    parents := '{"route_id":["public","tr_route","route_id","route"]}'; del := 'active'; ord := 't.route_id, t.stage_no';
  WHEN 'stage_fee' THEN
    -- year record: the fee of a stage of a route, per term (the school app's
    -- semester of the year) and transport fee head (transport_16). It has no
    -- inst_id: it belongs to the school of its route (see _of_school). The
    -- Stage Fees screen saves a route's stages together (_stage_fee_save).
    sch := NULL;
    tbl := 'tr_stage_fee'; pk := 'stage_fee_id'; noun := 'stage fee'; menus := ARRAY['Stage Fees'];
    cols := ARRAY['route_id','stage_id','service_type','fee_id','sem_id','amount','effective_from','effective_to','activestatus'];
    req := '{"route_id":"route","stage_id":"stage","fee_id":"fee type","sem_id":"term","amount":"amount","effective_from":"effective from date"}';
    parents := '{"route_id":["public","tr_route","route_id","route"],"stage_id":["public","tr_stage","stage_id","stage"]}'; del := 'hard';
    ord := 't.route_id, t.stage_id, t.sem_id, t.service_type, t.effective_from';
  WHEN 'stop' THEN
    tbl := 'tr_stop'; pk := 'stop_id'; noun := 'stop'; menus := ARRAY['Routes & Stops'];
    cols := ARRAY['route_id','stage_id','stop_seq','stop_code','stop_name','landmark','address','latitude','longitude','geofence_radius_m','distance_from_school_km','is_active'];
    req := '{"route_id":"route","stage_id":"stage","stop_seq":"stop order","stop_name":"stop name","latitude":"latitude","longitude":"longitude"}';
    upper_cols := ARRAY['stop_code'];
    parents := '{"route_id":["public","tr_route","route_id","route"],"stage_id":["public","tr_stage","stage_id","stage"]}';
    del := 'active'; ord := 't.route_id, t.stop_seq';
  WHEN 'vendor' THEN
    tbl := 'tr_vendor'; pk := 'vendor_id'; noun := 'vendor'; menus := ARRAY['Vehicles','Transport Staff'];
    cols := ARRAY['vendor_name','contact_person','mobile','email','address','gstin','pan','bank_account_no','bank_ifsc','agreement_no','agreement_from','agreement_to','is_active'];
    req := '{"vendor_name":"vendor name"}';
    upper_cols := ARRAY['gstin','pan','bank_ifsc']; del := 'active'; ord := 't.vendor_name';
  WHEN 'vehicle' THEN
    -- gps_device_id is not written here: it follows the GPS Mapping tab (vehicle_gps)
    tbl := 'tr_vehicle'; pk := 'vehicle_id'; noun := 'vehicle'; menus := ARRAY['Vehicles'];
    cols := ARRAY['vehicle_code','registration_no','vehicle_type','make','model','manufacture_year','chassis_no','engine_no','fuel_type','colour',
                  'seating_capacity','additional_capacity','permitted_capacity','ownership_type','vendor_id','contract_basis','contract_rate','contract_from','contract_to',
                  'purchase_date','purchase_cost','odometer_km','has_gps','has_cctv','has_speed_governor','has_first_aid','has_fire_extinguisher','has_panic_button',
                  'status','remarks'];
    req := '{"vehicle_code":"vehicle code","registration_no":"registration number","vehicle_type":"vehicle type","fuel_type":"fuel type","seating_capacity":"seating capacity","ownership_type":"ownership"}';
    upper_cols := ARRAY['vehicle_code','registration_no','chassis_no','engine_no'];
    parents := '{"vendor_id":["public","tr_vendor","vendor_id","vendor"]}';
    del := 'status:INACTIVE'; ord := 't.vehicle_code';
  WHEN 'gps_device' THEN
    -- a master since transport_10: a tracker stays with its bus from year to year
    tbl := 'tr_gps_device'; pk := 'device_id'; noun := 'GPS device'; menus := ARRAY['Vehicles'];
    cols := ARRAY['device_type','imei','sim_no','sim_provider','vendor_name','protocol','is_active'];
    req := '{"device_type":"device type"}';
    upper_cols := ARRAY['imei']; del := 'hard'; ord := 't.imei NULLS LAST, t.device_id';
  WHEN 'vehicle_gps' THEN
    -- which GPS device was on which vehicle, and when (tr_vehicle_gps_device,
    -- the history behind the GPS Mapping tab). Listed one row at a time, but
    -- saved only as the tab's batch of changes (_vehicle_gps_save), never
    -- deleted: a device that comes off keeps its row, with removed_on.
    tbl := 'tr_vehicle_gps_device'; pk := 'vgd_id'; noun := 'GPS device change'; menus := ARRAY['Vehicles'];
    cols := ARRAY['vehicle_id','device_id','installed_on','removed_on'];
    req := '{}'; del := 'none'; ord := 't.vehicle_id, t.installed_on DESC, t.vgd_id DESC';
  WHEN 'vehicle_doc' THEN
    tbl := 'tr_vehicle_document'; pk := 'vehicle_doc_id'; noun := 'document'; menus := ARRAY['Vehicles'];
    cols := ARRAY['vehicle_id','doc_type','doc_no','issuing_authority','insurance_type','insured_value','premium_amount','issue_date','valid_from','expiry_date','is_current','file_url','remarks'];
    req := '{"vehicle_id":"vehicle","doc_type":"document type"}';
    parents := '{"vehicle_id":["public","tr_vehicle","vehicle_id","vehicle"]}'; del := 'hard';
    ord := 't.is_current DESC, t.expiry_date NULLS LAST';
  WHEN 'vehicle_service' THEN
    -- a vehicle's service or repair (the Vehicles screen's Service tab). The
    -- table is a master in public, but each record is of one academic year
    -- (acad_year_id, transport_19): listed, saved and removed in the session's
    -- year only, which save writes on a new record (see save).
    tbl := 'tr_vehicle_service'; pk := 'service_id'; noun := 'service record'; menus := ARRAY['Vehicles'];
    cols := ARRAY['vehicle_id','service_type','service_date','odometer_km','workshop','description','amount',
                  'next_due_date','next_due_km','downtime_days'];
    req := '{"vehicle_id":"vehicle","service_type":"service type","service_date":"service date"}';
    parents := '{"vehicle_id":["public","tr_vehicle","vehicle_id","vehicle"]}'; del := 'hard';
    ord := 't.service_date DESC, t.service_id DESC';
  WHEN 'fuel_log' THEN
    -- year record: a vehicle's fuel fill or charge (the Vehicles screen's
    -- Fuel tab), in the session year's schema. Its fill date falls in that
    -- year; an empty amount is the quantity at the rate (see save).
    sch := NULL;
    tbl := 'tr_fuel_log'; pk := 'fuel_log_id'; noun := 'fuel entry'; menus := ARRAY['Vehicles'];
    cols := ARRAY['vehicle_id','fill_date','quantity','rate','amount','odometer_km','bill_no','filled_by_staff_id'];
    req := '{"vehicle_id":"vehicle","fill_date":"fill date","quantity":"quantity"}';
    parents := '{"vehicle_id":["public","tr_vehicle","vehicle_id","vehicle"],"filled_by_staff_id":["public","tr_staff","staff_id","staff member"]}';
    del := 'hard'; ord := 't.fill_date DESC, t.fuel_log_id DESC';
  WHEN 'staff' THEN
    tbl := 'tr_staff'; pk := 'staff_id'; noun := 'staff member'; menus := ARRAY['Transport Staff'];
    cols := ARRAY['staff_code','staff_type','employment_type','vendor_id','full_name','gender','date_of_birth','blood_group','mobile','alt_mobile','address',
                  'id_proof_type','id_proof_no_masked','emergency_contact_name','emergency_contact_phone','joining_date','relieving_date','experience_years',
                  'police_verified','police_verified_on','license_number','license_type','license_valid_till','photo_url','status'];
    req := '{"staff_code":"staff code","staff_type":"staff type","full_name":"name","mobile":"mobile number"}';
    upper_cols := ARRAY['staff_code','blood_group','license_number','license_type'];
    parents := '{"vendor_id":["public","tr_vendor","vendor_id","vendor"]}'; del := 'status:RELIEVED'; ord := 't.staff_code';
  WHEN 'staff_doc' THEN
    tbl := 'tr_staff_document'; pk := 'staff_doc_id'; noun := 'document'; menus := ARRAY['Transport Staff'];
    cols := ARRAY['staff_id','doc_type','doc_no','licence_class','issuing_authority','issue_date','expiry_date','is_current','file_url'];
    req := '{"staff_id":"staff member","doc_type":"document type"}';
    parents := '{"staff_id":["public","tr_staff","staff_id","staff member"]}'; del := 'hard';
    ord := 't.is_current DESC, t.expiry_date NULLS LAST';
  WHEN 'schedule' THEN
    sch := NULL;  -- year record; its stops (tr_trip_schedule_stop) are saved with it, see save
    tbl := 'tr_trip_schedule'; pk := 'schedule_id'; noun := 'schedule'; menus := ARRAY['Trip Schedules'];
    cols := ARRAY['schedule_code','schedule_name','route_id','direction','vehicle_id','planned_start','planned_end','run_days',
                  'effective_from','effective_to','is_active'];
    req := '{"schedule_code":"schedule code","schedule_name":"schedule name","route_id":"route","direction":"direction","vehicle_id":"vehicle","planned_start":"start time","planned_end":"end time","effective_from":"effective from date"}';
    upper_cols := ARRAY['schedule_code'];
    parents := '{"route_id":["public","tr_route","route_id","route"],"vehicle_id":["public","tr_vehicle","vehicle_id","vehicle"]}';
    del := 'active';
    ord := '(SELECT r.route_code FROM public.tr_route r WHERE r.route_id = t.route_id), t.direction DESC, t.planned_start, t.schedule_code';
  WHEN 'enrollment' THEN
    -- year record: a student's transport on a route (tr_student_enrollment).
    -- Listed one route at a time with the student's admission number, name
    -- and class (see list); saved only as the Student Enrollment screen's
    -- batch (_enrollment_save); never deleted: a student who stops
    -- travelling is Cancelled. The cols are the list's filters.
    sch := NULL;
    tbl := 'tr_student_enrollment'; pk := 'enrollment_id'; noun := 'student enrollment'; menus := ARRAY['Student Enrollment'];
    cols := ARRAY['route_id','student_id','service_type','pickup_stop_id','drop_stop_id','start_date','end_date','status'];
    req := '{}'; del := 'none'; ord := 't.route_id, t.enrollment_id';
  WHEN 'allotment' THEN
    -- the same rows as 'enrollment' (tr_student_enrollment), for the Vehicle
    -- Allotment screen: listed a route at a time with the students' details;
    -- saved only as that screen's batch (_allotment_save), which sets the
    -- vehicle (the schedule) a student travels in one way; never deleted.
    sch := NULL;
    tbl := 'tr_student_enrollment'; pk := 'enrollment_id'; noun := 'vehicle allotment'; menus := ARRAY['Vehicle Allotment'];
    cols := ARRAY['route_id','student_id','service_type','status','pickup_schedule_id','drop_schedule_id'];
    req := '{}'; del := 'none'; ord := 't.route_id, t.enrollment_id';
  WHEN 'staff_allotment' THEN
    -- the same rows as 'staff_enrollment' (tr_staff_enrollment), for the
    -- Vehicle Allotment screen, where the staff take seats with the students:
    -- listed a route at a time with the staff details (none while the year has
    -- no staff transport); saved with the students as the 'allotment' batch
    -- (its staff_rows, _allotment_save); never deleted.
    sch := NULL;
    tbl := 'tr_staff_enrollment'; pk := 'enrollment_id'; noun := 'vehicle allotment'; menus := ARRAY['Vehicle Allotment'];
    cols := ARRAY['route_id','staf_id','service_type','status','pickup_schedule_id','drop_schedule_id'];
    req := '{}'; del := 'none'; ord := 't.route_id, t.enrollment_id';
  WHEN 'staff_enrollment' THEN
    -- year record: a staff member's transport on a route (tr_staff_enrollment,
    -- transport_23), kept like a student's: listed one route at a time with
    -- the staff member's employee code, name and designation (see list);
    -- saved only as the Staff Enrollment tab's batch (_staff_enrollment_save);
    -- never deleted: Cancelled instead. The tab is on the Student Enrollment
    -- screen (the app shows that menu as Student/Staff Enrollment).
    sch := NULL;
    tbl := 'tr_staff_enrollment'; pk := 'enrollment_id'; noun := 'staff enrollment'; menus := ARRAY['Student Enrollment'];
    cols := ARRAY['route_id','staf_id','service_type','pickup_stop_id','drop_stop_id','start_date','end_date','status'];
    req := '{}'; del := 'none'; ord := 't.route_id, t.enrollment_id';
  WHEN 'duty' THEN
    -- year record: who drives or attends a schedule, from a date (to a date).
    -- Each day's trip takes its crew from these (fn_generate_trips).
    -- is_primary is not written: every duty is a main one (the default).
    sch := NULL;
    tbl := 'tr_duty_assignment'; pk := 'duty_id'; noun := 'duty'; menus := ARRAY['Duty Roster'];
    cols := ARRAY['schedule_id','staff_id','duty_role','effective_from','effective_to'];
    req := '{"schedule_id":"schedule","staff_id":"staff member","duty_role":"duty","effective_from":"effective from date"}';
    parents := '{"schedule_id":["","tr_trip_schedule","schedule_id","schedule"],"staff_id":["public","tr_staff","staff_id","staff member"]}';
    del := 'hard';
    ord := 't.schedule_id, CASE t.duty_role WHEN ''DRIVER'' THEN 1 WHEN ''CONDUCTOR'' THEN 2 WHEN ''ATTENDER'' THEN 3 ELSE 4 END, t.effective_from DESC, t.duty_id';
  ELSE
    RAISE EXCEPTION 'Unknown transport record type.';
  END CASE;
END $$;

-- The condition that a row t of the entity belongs to the school whose id is
-- the query parameter p_param ('$1', '$2', ...): its inst_id, or for a stage
-- fee, which has none, the school of its route.
CREATE OR REPLACE FUNCTION transport_core._of_school(p_entity text, p_param text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_entity
    WHEN 'stage_fee' THEN format('t.route_id IN (SELECT own.route_id FROM public.tr_route own WHERE own.inst_id = %s)', p_param)
    ELSE format('t.inst_id = %s', p_param)
  END
$$;

-- A constraint name -> the sentence the user sees.
CREATE OR REPLACE FUNCTION transport_core._friendly(p_constraint text, p_noun text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_constraint
    WHEN 'uq_route_code'    THEN 'This route code is already used.'
    WHEN 'uq_stage_no'      THEN 'This route already has a stage with that number.'
    WHEN 'uq_stage_fee'     THEN 'This stage already has a fee for that term, service and date.'
    WHEN 'tr_stage_fee_fee_id_fkey' THEN 'The selected fee type was not found.'
    WHEN 'tr_stage_fee_sem_id_fkey' THEN 'The selected term was not found.'
    WHEN 'uq_stop_seq'      THEN 'Another stop on this route already has that order number.'
    WHEN 'uq_vehicle_reg'   THEN 'This registration number is already added.'
    WHEN 'uq_vehicle_code'  THEN 'This vehicle code is already used.'
    WHEN 'uq_staff_code'    THEN 'This staff code is already used.'
    WHEN 'uq_vdoc_current'  THEN 'This vehicle already has a current document of that type.'
    WHEN 'ck_vendor_needed' THEN 'Choose the vendor for a vehicle that is not owned by the school.'
    WHEN 'ck_staff_vendor'  THEN 'Choose the vendor for staff supplied by a vendor.'
    WHEN 'fk_stop_stage'    THEN 'That stage belongs to a different route.'
    WHEN 'ck_stop_lat'      THEN 'Latitude must be between -90 and 90.'
    WHEN 'ck_stop_lon'      THEN 'Longitude must be between -180 and 180.'
    WHEN 'tr_stage_fee_amount_check' THEN 'The amount cannot be negative.'
    WHEN 'tr_vehicle_seating_capacity_check' THEN 'Seating capacity must be more than zero.'
    WHEN 'ck_vehicle_additional' THEN 'The additional capacity cannot be negative.'
    WHEN 'tr_vehicle_fuel_type_check' THEN 'Choose the fuel: Diesel, Petrol, CNG, Electric or Hybrid.'
    WHEN 'uq_gps_imei'      THEN 'This IMEI number is already added.'
    WHEN 'tr_vehicle_gps_device_id_fkey' THEN 'The selected GPS device was not found.'
    WHEN 'tr_vehicle_gps_device_device_id_fkey' THEN 'The selected GPS device was not found.'
    WHEN 'uq_vgd_active_device'  THEN 'This GPS device is already on another vehicle.'
    WHEN 'uq_vgd_active_vehicle' THEN 'This vehicle already has a GPS device.'
    WHEN 'ck_vgd_dates'     THEN 'A GPS device cannot come off a vehicle before the day it went on.'
    WHEN 'uq_schedule_code' THEN 'This schedule code is already used.'
    WHEN 'tr_trip_schedule_direction_check' THEN 'Choose Pickup or Drop.'
    WHEN 'fk_tss_stop'      THEN 'A chosen stop is not on this route.'
    WHEN 'fk_enr_pick_sched' THEN 'Students are enrolled on this schedule, so its route cannot be changed.'
    WHEN 'fk_enr_drop_sched' THEN 'Students are enrolled on this schedule, so its route cannot be changed.'
    WHEN 'uq_duty_one_primary_driver' THEN 'This schedule already has a driver with no end date. Set an Effective To date on that duty first.'
    WHEN 'tr_duty_assignment_duty_role_check' THEN 'Choose the duty: Driver, Attender, Conductor or Supervisor.'
    WHEN 'uq_enr_active'     THEN 'A student can be active on only one route at a time. Refresh and try again.'
    WHEN 'ck_enr_stops'      THEN 'Choose the stops the trip type needs: pickup and drop for Both.'
    WHEN 'fk_enr_pickup_stop' THEN 'A chosen stop is not on this route.'
    WHEN 'fk_enr_drop_stop'  THEN 'A chosen stop is not on this route.'
    WHEN 'fk_enr_stage'      THEN 'The fee stage is not on this route.'
    WHEN 'tr_student_enrollment_service_type_check' THEN 'Choose the trip type: Both, Pickup or Drop.'
    WHEN 'tr_student_enrollment_status_check' THEN 'Choose the status: Active, Suspended, Cancelled or Completed.'
    WHEN 'uq_senr_active'     THEN 'A staff member can be active on only one route at a time. Refresh and try again.'
    WHEN 'ck_senr_stops'      THEN 'Choose the stops the trip type needs: pickup and drop for Both.'
    WHEN 'fk_senr_pickup_stop' THEN 'A chosen stop is not on this route.'
    WHEN 'fk_senr_drop_stop'  THEN 'A chosen stop is not on this route.'
    WHEN 'fk_senr_stage'      THEN 'The fee stage is not on this route.'
    WHEN 'fk_senr_staff'      THEN 'The staff member was not found in this academic year.'
    WHEN 'fk_senr_pick_sched' THEN 'Staff are enrolled on this schedule, so its route cannot be changed.'
    WHEN 'fk_senr_drop_sched' THEN 'Staff are enrolled on this schedule, so its route cannot be changed.'
    WHEN 'tr_staff_enrollment_service_type_check' THEN 'Choose the trip type: Both, Pickup or Drop.'
    WHEN 'tr_staff_enrollment_status_check' THEN 'Choose the status: Active, Suspended, Cancelled or Completed.'
    WHEN 'tr_vehicle_service_service_type_check' THEN 'Choose the service type: Periodic, Repair, Tyre, Battery, Accident or Other.'
    WHEN 'fk_service_year'   THEN 'The academic year of this service record was not found.'
    ELSE 'This ' || p_noun || ' could not be saved. Please check the values entered.'
  END
$$;

-- ---------------------------------------------------------------------
-- List
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core.list(p_token text, p_entity text, p_filter jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE e record; c record; v_sch text; v_where text := ''; k text; v text; out_rows jsonb; v_menus text[]; v_json text := 'to_jsonb(t)';
  v_stu text;
BEGIN
  SELECT * INTO e FROM transport_core._entity(p_entity);
  -- Trip Schedules picks routes, their stops and vehicles, Duty Roster
  -- picks schedules and staff, Student Enrollment picks routes, their
  -- stages and stops, Vehicle Allotment picks routes, their stops,
  -- schedules and vehicles, Stage Fees picks routes and their stages, and
  -- the Vehicles screen's Fuel tab picks who filled the fuel (staff): they
  -- may list them but not change them (save and remove still need the
  -- entity's own menu).
  v_menus := e.menus
          || CASE WHEN p_entity IN ('route', 'stop', 'vehicle') THEN ARRAY['Trip Schedules'] ELSE '{}'::text[] END
          || CASE WHEN p_entity IN ('schedule', 'staff') THEN ARRAY['Duty Roster'] ELSE '{}'::text[] END
          || CASE WHEN p_entity = 'staff' THEN ARRAY['Vehicles'] ELSE '{}'::text[] END
          || CASE WHEN p_entity IN ('route', 'stage', 'stop') THEN ARRAY['Student Enrollment'] ELSE '{}'::text[] END
          || CASE WHEN p_entity IN ('route', 'stop', 'schedule', 'vehicle') THEN ARRAY['Vehicle Allotment'] ELSE '{}'::text[] END
          || CASE WHEN p_entity IN ('route', 'stage') THEN ARRAY['Stage Fees'] ELSE '{}'::text[] END
          -- Daily Trips picks a day's vehicle and crew
          || CASE WHEN p_entity IN ('vehicle', 'staff') THEN ARRAY['Daily Trips'] ELSE '{}'::text[] END;
  SELECT * INTO c FROM transport_core._ctx(p_token, v_menus);
  v_sch := COALESCE(e.sch, transport_core._year(c.ysch, c.yr));
  FOR k, v IN SELECT * FROM jsonb_each_text(COALESCE(p_filter, '{}')) LOOP
    CONTINUE WHEN v IS NULL;
    IF k = e.pk OR k = ANY (e.cols) THEN
      v_where := v_where || format(' AND t.%I::text = %L', k, v);
    END IF;
  END LOOP;
  IF p_entity = 'schedule' THEN
    -- each schedule with its stops, in visit order
    v_json := format('to_jsonb(t) || jsonb_build_object(''stops'', COALESCE((SELECT jsonb_agg(to_jsonb(ss) - ''route_id'' ORDER BY ss.visit_seq)
                        FROM %I.tr_trip_schedule_stop ss WHERE ss.schedule_id = t.schedule_id), ''[]''::jsonb))', v_sch);
  END IF;
  IF p_entity IN ('enrollment', 'allotment') THEN
    -- the session year's enrollments, each with the student's admission
    -- number, name, class and status from the main app's students of that year
    v_where := v_where || format(' AND t.acad_year_id = %s', COALESCE(c.iyr, -1));
    SELECT y.sch INTO v_stu FROM transport_core._student_year(c.iyr) y;
    v_json := format('to_jsonb(t) || COALESCE((SELECT jsonb_build_object(''stuadmno'', s.stuadmno, ''stuname'', s.stuname, ''stuclass'', s.stuclass,
                        ''cla_id'', s.cla_id, ''stu_status'', s.activestatus) FROM %I.students s WHERE s.stu_id = t.student_id), ''{}''::jsonb)', v_stu);
  END IF;
  IF p_entity IN ('staff_enrollment', 'staff_allotment') THEN
    -- the session year's staff enrollments, each with the staff member's
    -- employee code, name and designation, and whether they are still active
    -- and on the bus, from the school app's staff of that year (staffmast).
    -- Vehicle Allotment gets none while the year has no staff transport.
    SELECT y.sch INTO v_stu FROM transport_core._student_year(c.iyr) y;
    IF NOT transport_core._staff_ready(v_stu, v_sch) THEN
      IF p_entity = 'staff_allotment' THEN RETURN '[]'::jsonb; END IF;
      RAISE EXCEPTION 'Staff transport has not been set up for the year %.', COALESCE(c.yr, '-');
    END IF;
    v_where := v_where || format(' AND t.acad_year_id = %s', COALESCE(c.iyr, -1));
    v_json := format('to_jsonb(t) || COALESCE((SELECT jsonb_build_object(''emp_code'', m.emp_code, ''stafname'', m.stafname,
                        ''designation'', m.designation, ''staff_active'', m.is_active, ''transportreq'', m.transportreq)
                        FROM %I.staffmast m WHERE m.staf_id = t.staf_id), ''{}''::jsonb)', v_stu);
  END IF;
  IF p_entity = 'vehicle_service' THEN
    v_where := v_where || format(' AND t.acad_year_id = %s', COALESCE(c.iyr, -1));  -- the session year's records
  END IF;
  EXECUTE format('SELECT COALESCE(jsonb_agg(%s ORDER BY %s), ''[]''::jsonb) FROM %I.%I t WHERE %s %s',
                 v_json, e.ord, v_sch, e.tbl, transport_core._of_school(p_entity, '$1'), v_where)
     INTO out_rows USING c.ins;
  RETURN out_rows;
END $$;

-- ---------------------------------------------------------------------
-- A schedule's stops as the app sends them ([{stop_id, planned_time,
-- halt_minutes}, ...] in visit order), checked and numbered: each one an
-- active stop of the schedule's route, listed once, with a time between the
-- schedule's start and end that is not before the stop before it. visit_seq
-- is the order sent. Returns the rows to store in tr_trip_schedule_stop.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._schedule_stops(p_stops jsonb, p_route bigint, p_start time, p_end time)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE s jsonb; v_id bigint; v_t time; v_prev time; v_halt integer; v_ids bigint[] := '{}'; v_out jsonb := '[]';
BEGIN
  IF jsonb_typeof(p_stops) IS DISTINCT FROM 'array' OR jsonb_array_length(p_stops) = 0 THEN
    RAISE EXCEPTION 'Choose at least one stop for this schedule.';
  END IF;
  FOR s IN SELECT x FROM jsonb_array_elements(p_stops) x LOOP
    v_id := NULLIF(s->>'stop_id', '')::bigint;
    IF v_id IS NULL THEN RAISE EXCEPTION 'A stop is missing. Refresh and try again.'; END IF;
    IF v_id = ANY (v_ids) THEN RAISE EXCEPTION 'A stop is listed twice.'; END IF;
    v_t := NULLIF(btrim(s->>'planned_time'), '')::time;
    IF v_t IS NULL THEN RAISE EXCEPTION 'Enter the time for every stop.'; END IF;
    IF v_t < p_start OR v_t > p_end THEN
      RAISE EXCEPTION 'Each stop time must be between the start time and the end time.';
    END IF;
    IF v_t < v_prev THEN RAISE EXCEPTION 'Stop times must go in visit order.'; END IF;
    v_halt := COALESCE(NULLIF(btrim(s->>'halt_minutes'), '')::integer, 1);
    IF v_halt NOT BETWEEN 0 AND 60 THEN RAISE EXCEPTION 'Halt time must be 0 to 60 minutes.'; END IF;
    v_ids := v_ids || v_id;
    v_prev := v_t;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
               'stop_id', v_id, 'visit_seq', cardinality(v_ids), 'planned_time', v_t, 'halt_minutes', v_halt));
  END LOOP;
  IF EXISTS (SELECT 1 FROM unnest(v_ids) i
              WHERE NOT EXISTS (SELECT 1 FROM public.tr_stop p WHERE p.stop_id = i AND p.route_id = p_route)) THEN
    RAISE EXCEPTION 'A chosen stop is not on this route.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.tr_stop p WHERE p.stop_id = ANY (v_ids) AND NOT p.is_active) THEN
    RAISE EXCEPTION 'A chosen stop is switched off. Untick it, or switch it on in Routes & Stops.';
  END IF;
  RETURN v_out;
END $$;

-- ---------------------------------------------------------------------
-- GPS Mapping: the device on each vehicle (tr_vehicle_gps_device). The app
-- sends the grid's changed rows together:
--   {"changes": [{"vehicle_id": 7, "device_id": 3, "was_device_id": 2, "date": "2026-11-12"}, ...]}
-- device_id is the device the vehicle has from that date (empty: none),
-- was_device_id the one the app showed on it (so a change someone else saved
-- meanwhile is not overwritten), date the day of the change:
--   none before, a device now     -> the device went on that day
--   a device before, none now     -> it came off that day
--   a device before, another now  -> the old one came off and the new one went on that day
--   the same device, another date -> the day it went on is corrected
-- Nothing is deleted: a device that comes off keeps its row, with removed_on.
-- Devices come off first, so one save can move a device to another vehicle,
-- or swap two. The history of a vehicle, or of a device, never overlaps.
-- Then tr_vehicle.gps_device_id is set to match, and has_gps turned on for a
-- vehicle that gets a device. Returns the number of vehicles in the save.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._vehicle_gps_save(p_ins integer, p_usr integer, p_row jsonb)
RETURNS bigint LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE
  ch jsonb; v_ids bigint[] := '{}'; v_vid bigint; v_new bigint; v_was bigint; v_date date; v_last date;
  v_code text; v_status text; v_cur_id bigint; v_cur_dev bigint; v_cur_on date; v_name text; v_active boolean; v_other text;
BEGIN
  IF jsonb_typeof(p_row->'changes') IS DISTINCT FROM 'array' OR jsonb_array_length(p_row->'changes') = 0 THEN
    RAISE EXCEPTION 'Nothing to save.';
  END IF;

  -- 1. Check every row; take off the devices that come off; correct dates.
  FOR ch IN SELECT x FROM jsonb_array_elements(p_row->'changes') x LOOP
    IF jsonb_typeof(ch) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
    v_vid := NULLIF(ch->>'vehicle_id', '')::bigint;
    IF v_vid IS NULL THEN RAISE EXCEPTION 'A vehicle is missing. Refresh and try again.'; END IF;
    IF v_vid = ANY (v_ids) THEN RAISE EXCEPTION 'A vehicle is listed twice.'; END IF;
    v_ids := v_ids || v_vid;
    SELECT t.vehicle_code INTO v_code FROM public.tr_vehicle t WHERE t.vehicle_id = v_vid AND t.inst_id = p_ins FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'The selected vehicle was not found.'; END IF;
    v_date := NULLIF(btrim(ch->>'date'), '')::date;
    IF v_date IS NULL THEN RAISE EXCEPTION 'Choose the date for %.', v_code; END IF;
    -- a day of slack: the server's date can still be yesterday in the school's time zone
    IF v_date > CURRENT_DATE + 1 THEN RAISE EXCEPTION 'The date for % cannot be in the future.', v_code; END IF;
    v_new := NULLIF(ch->>'device_id', '')::bigint;
    v_was := NULLIF(ch->>'was_device_id', '')::bigint;
    SELECT m.vgd_id, m.device_id, m.installed_on INTO v_cur_id, v_cur_dev, v_cur_on
      FROM public.tr_vehicle_gps_device m WHERE m.vehicle_id = v_vid AND m.removed_on IS NULL FOR UPDATE;
    IF v_cur_dev IS DISTINCT FROM v_was THEN
      RAISE EXCEPTION 'The GPS device of % was changed by someone else. Refresh and try again.', v_code;
    END IF;
    CONTINUE WHEN v_cur_id IS NULL;
    IF v_new IS DISTINCT FROM v_cur_dev THEN
      IF v_date < v_cur_on THEN
        RAISE EXCEPTION 'The date for % cannot be before %, the day its GPS device went on.', v_code, to_char(v_cur_on, 'DD-MM-YYYY');
      END IF;
      UPDATE public.tr_vehicle_gps_device SET removed_on = v_date, updated_by = p_usr WHERE vgd_id = v_cur_id;
    ELSIF v_date <> v_cur_on THEN
      SELECT max(m.removed_on) INTO v_last FROM public.tr_vehicle_gps_device m
       WHERE (m.vehicle_id = v_vid OR m.device_id = v_cur_dev) AND m.vgd_id <> v_cur_id;
      IF v_date < v_last THEN
        RAISE EXCEPTION 'The date for % cannot be before %, when the earlier GPS history of this vehicle or device ends.',
          v_code, to_char(v_last, 'DD-MM-YYYY');
      END IF;
      UPDATE public.tr_vehicle_gps_device SET installed_on = v_date, updated_by = p_usr WHERE vgd_id = v_cur_id;
    END IF;
  END LOOP;

  -- 2. Put on the devices that go on.
  FOR ch IN SELECT x FROM jsonb_array_elements(p_row->'changes') x LOOP
    v_vid := (ch->>'vehicle_id')::bigint;
    v_new := NULLIF(ch->>'device_id', '')::bigint;
    CONTINUE WHEN v_new IS NULL
               OR EXISTS (SELECT 1 FROM public.tr_vehicle_gps_device m
                           WHERE m.vehicle_id = v_vid AND m.device_id = v_new AND m.removed_on IS NULL);
    v_date := (ch->>'date')::date;
    SELECT t.vehicle_code, t.status INTO v_code, v_status FROM public.tr_vehicle t WHERE t.vehicle_id = v_vid;
    IF v_status NOT IN ('ACTIVE', 'UNDER_REPAIR') THEN
      RAISE EXCEPTION '% is %, so a GPS device cannot go on it.', v_code, lower(replace(v_status, '_', ' '));
    END IF;
    SELECT COALESCE(d.imei, 'Device #' || d.device_id), d.is_active INTO v_name, v_active
      FROM public.tr_gps_device d WHERE d.device_id = v_new AND d.inst_id = p_ins FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'The selected GPS device was not found.'; END IF;
    IF NOT v_active THEN RAISE EXCEPTION 'The GPS device % is switched off. Switch it on in GPS Devices first.', v_name; END IF;
    SELECT t.vehicle_code INTO v_other
      FROM public.tr_vehicle_gps_device m JOIN public.tr_vehicle t ON t.vehicle_id = m.vehicle_id
     WHERE m.device_id = v_new AND m.removed_on IS NULL;
    IF v_other IS NOT NULL THEN
      RAISE EXCEPTION 'The GPS device % is on %. Take it off there first.', v_name, v_other;
    END IF;
    SELECT max(m.removed_on) INTO v_last FROM public.tr_vehicle_gps_device m WHERE m.vehicle_id = v_vid OR m.device_id = v_new;
    IF v_date < v_last THEN
      RAISE EXCEPTION 'The date for % cannot be before %, when the earlier GPS history of this vehicle or device ends.',
        v_code, to_char(v_last, 'DD-MM-YYYY');
    END IF;
    INSERT INTO public.tr_vehicle_gps_device (inst_id, vehicle_id, device_id, installed_on, created_by, updated_by)
    VALUES (p_ins, v_vid, v_new, v_date, p_usr, p_usr);
  END LOOP;

  -- 3. Each vehicle shows the device on it now.
  UPDATE public.tr_vehicle t
     SET gps_device_id = x.device_id, has_gps = t.has_gps OR x.device_id IS NOT NULL, updated_by = p_usr
    FROM (SELECT i.vid, (SELECT m.device_id FROM public.tr_vehicle_gps_device m
                          WHERE m.vehicle_id = i.vid AND m.removed_on IS NULL) AS device_id
            FROM unnest(v_ids) i(vid)) x
   WHERE t.vehicle_id = x.vid
     AND (t.gps_device_id IS DISTINCT FROM x.device_id OR (x.device_id IS NOT NULL AND NOT t.has_gps));
  RETURN cardinality(v_ids);
END $$;

-- ---------------------------------------------------------------------
-- Student Enrollment: the students on one route (tr_student_enrollment).
-- The app sends the screen's changed rows together:
--   {"route_id": 5, "rows": [{"enrollment_id": 9 (none for a new student),
--     "student_id": 483, "service_type": "BOTH", "pickup_stop_id": 11,
--     "drop_stop_id": 11, "start_date": "2026-06-01", "end_date": null,
--     "status": "ACTIVE", "updated_at": "..." (as listed)}, ...]}
-- Every row is checked, and an error names the student (admission number
-- and name): an active student of the session year (a new row), on a route
-- that is switched on (a new row); the stops the trip type needs (Both:
-- pickup and drop; Pickup: pickup; Drop: drop; the other one is cleared),
-- each a stop of this route and switched on unless it was already saved;
-- a start date, an end date not before it, both within the academic year;
-- one active enrollment per student in the year (on any route); and a row
-- someone else changed meanwhile (updated_at) is refused. The fee stage is
-- the stage of the farther stop (the higher stage number). Nothing is
-- deleted: a student who stops travelling is Cancelled (or Completed).
-- Returns the number of rows saved.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._enrollment_save(p_ins integer, p_usr integer, p_iyr bigint, p_sch text, p_row jsonb)
RETURNS bigint LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE
  y record; x jsonb; v_route bigint; v_code text; v_on boolean; v_ids bigint[] := '{}';
  v_eid bigint; v_stu bigint; v_who text; v_stat integer; v_old jsonb; v_type text; v_pick bigint; v_drop bigint;
  v_stage bigint; v_start date; v_end date; v_status text; v_bad text; v_other text;
BEGIN
  SELECT * INTO y FROM transport_core._student_year(p_iyr);
  IF jsonb_typeof(p_row->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(p_row->'rows') = 0 THEN
    RAISE EXCEPTION 'Nothing to save.';
  END IF;
  v_route := NULLIF(p_row->>'route_id', '')::bigint;
  SELECT r.route_code, r.is_active INTO v_code, v_on FROM public.tr_route r WHERE r.route_id = v_route AND r.inst_id = p_ins;
  IF v_code IS NULL THEN RAISE EXCEPTION 'The selected route was not found.'; END IF;

  FOR x IN SELECT r FROM jsonb_array_elements(p_row->'rows') r LOOP
    IF jsonb_typeof(x) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
    v_eid := NULLIF(x->>'enrollment_id', '')::bigint;
    v_stu := NULLIF(x->>'student_id', '')::bigint;
    IF v_stu IS NULL THEN RAISE EXCEPTION 'A student is missing. Refresh and try again.'; END IF;
    IF v_stu = ANY (v_ids) THEN RAISE EXCEPTION 'A student is listed twice. Keep one row for each student.'; END IF;
    v_ids := v_ids || v_stu;
    -- the student, named in every message below
    v_who := NULL;
    EXECUTE format('SELECT concat_ws('' '', s.stuadmno, s.stuname), s.activestatus FROM %I.students s WHERE s.stu_id = $1 AND s.ins_id = $2', y.sch)
       INTO v_who, v_stat USING v_stu, p_ins;
    IF v_who IS NULL THEN RAISE EXCEPTION 'A student was not found in this academic year. Refresh and try again.'; END IF;

    v_old := NULL;
    IF v_eid IS NOT NULL THEN
      EXECUTE format('SELECT to_jsonb(t) FROM %I.tr_student_enrollment t WHERE t.enrollment_id = $1 AND t.inst_id = $2 AND t.acad_year_id = $3 FOR UPDATE', p_sch)
         INTO v_old USING v_eid, p_ins, p_iyr;
      IF v_old IS NULL OR (v_old->>'route_id')::bigint <> v_route OR (v_old->>'student_id')::bigint <> v_stu THEN
        RAISE EXCEPTION 'The enrollment of % was not found on this route. Refresh and try again.', v_who;
      END IF;
      IF x ? 'updated_at' AND (x->>'updated_at')::timestamptz IS DISTINCT FROM (v_old->>'updated_at')::timestamptz THEN
        RAISE EXCEPTION 'The enrollment of % was changed by someone else. Refresh and try again.', v_who;
      END IF;
    ELSE
      IF v_stat IS DISTINCT FROM 1 THEN RAISE EXCEPTION '% is not an active student.', v_who; END IF;
      IF NOT v_on THEN RAISE EXCEPTION 'Route % is switched off, so no student can be added to it.', v_code; END IF;
    END IF;

    v_type := COALESCE(NULLIF(btrim(x->>'service_type'), ''), 'BOTH');
    IF v_type NOT IN ('BOTH', 'PICKUP', 'DROP') THEN RAISE EXCEPTION 'Choose the trip type of %: Both, Pickup or Drop.', v_who; END IF;
    v_pick := CASE WHEN v_type IN ('BOTH', 'PICKUP') THEN NULLIF(x->>'pickup_stop_id', '')::bigint END;
    v_drop := CASE WHEN v_type IN ('BOTH', 'DROP') THEN NULLIF(x->>'drop_stop_id', '')::bigint END;
    IF v_type <> 'DROP' AND v_pick IS NULL THEN RAISE EXCEPTION 'Choose the pickup stop of %.', v_who; END IF;
    IF v_type <> 'PICKUP' AND v_drop IS NULL THEN RAISE EXCEPTION 'Choose the drop stop of %.', v_who; END IF;
    IF (SELECT count(*) FROM public.tr_stop p WHERE p.stop_id IN (v_pick, v_drop) AND p.route_id = v_route)
       <> (SELECT count(DISTINCT i) FROM unnest(ARRAY[v_pick, v_drop]) i WHERE i IS NOT NULL) THEN
      RAISE EXCEPTION 'A stop chosen for % is not on route %.', v_who, v_code;
    END IF;
    SELECT string_agg(p.stop_name, ', ') INTO v_bad FROM public.tr_stop p
     WHERE p.stop_id IN (v_pick, v_drop) AND NOT p.is_active
       AND p.stop_id NOT IN (COALESCE((v_old->>'pickup_stop_id')::bigint, -1), COALESCE((v_old->>'drop_stop_id')::bigint, -1));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'The stop % chosen for % is switched off.', v_bad, v_who; END IF;
    -- the fee stage: the stage of the farther stop
    SELECT g.stage_id INTO v_stage FROM public.tr_stop p JOIN public.tr_stage g ON g.stage_id = p.stage_id
     WHERE p.stop_id IN (v_pick, v_drop) ORDER BY g.stage_no DESC, g.stage_id DESC LIMIT 1;

    v_start := NULLIF(btrim(x->>'start_date'), '')::date;
    v_end := NULLIF(btrim(x->>'end_date'), '')::date;
    IF v_start IS NULL THEN RAISE EXCEPTION 'Choose the start date of %.', v_who; END IF;
    IF v_end < v_start THEN RAISE EXCEPTION 'The end date of % cannot be before the start date.', v_who; END IF;
    IF v_start < y.from_date OR v_start > y.to_date OR v_end > y.to_date THEN
      RAISE EXCEPTION 'The dates of % must be within the academic year (% to %).', v_who,
        to_char(y.from_date, 'DD-MM-YYYY'), to_char(y.to_date, 'DD-MM-YYYY');
    END IF;

    v_status := COALESCE(NULLIF(btrim(x->>'status'), ''), 'ACTIVE');
    IF v_status NOT IN ('ACTIVE', 'SUSPENDED', 'CANCELLED', 'COMPLETED') THEN
      RAISE EXCEPTION 'Choose the status of %: Active, Suspended, Cancelled or Completed.', v_who;
    END IF;
    IF v_status = 'ACTIVE' THEN
      v_other := NULL;
      EXECUTE format('SELECT r.route_code FROM %I.tr_student_enrollment t JOIN public.tr_route r ON r.route_id = t.route_id
                       WHERE t.student_id = $1 AND t.acad_year_id = $2 AND t.status = ''ACTIVE'' AND t.enrollment_id IS DISTINCT FROM $3 LIMIT 1', p_sch)
         INTO v_other USING v_stu, p_iyr, v_eid;
      IF v_other IS NOT NULL THEN RAISE EXCEPTION '% is already enrolled on route %.', v_who, v_other; END IF;
    END IF;

    IF v_eid IS NULL THEN
      EXECUTE format('INSERT INTO %I.tr_student_enrollment (inst_id, acad_year_id, student_id, route_id, service_type, pickup_stop_id, drop_stop_id,
                        fee_stage_id, start_date, end_date, status, created_by, updated_by)
                      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12)', p_sch)
        USING p_ins, p_iyr, v_stu, v_route, v_type, v_pick, v_drop, v_stage, v_start, v_end, v_status, p_usr;
    ELSE
      EXECUTE format('UPDATE %I.tr_student_enrollment SET service_type = $2, pickup_stop_id = $3, drop_stop_id = $4, fee_stage_id = $5,
                        start_date = $6, end_date = $7, status = $8, updated_by = $9 WHERE enrollment_id = $1', p_sch)
        USING v_eid, v_type, v_pick, v_drop, v_stage, v_start, v_end, v_status, p_usr;
    END IF;
  END LOOP;
  PERFORM transport_core._route_trips_sync(p_ins, p_sch, v_route);  -- the trips already made follow
  RETURN cardinality(v_ids);
END $$;

-- ---------------------------------------------------------------------
-- True when a year is ready for staff transport: the school app's staff of
-- the year (p_app.staffmast) with their transport (transportreq), and the
-- year's tr_staff_enrollment (p_sch, transport_23).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._staff_ready(p_app text, p_sch text)
RETURNS boolean LANGUAGE sql STABLE
SET search_path TO 'pg_catalog' AS $$
  SELECT to_regclass(format('%I.tr_staff_enrollment', p_sch)) IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_attribute a
                  WHERE a.attrelid = to_regclass(format('%I.staffmast', p_app))
                    AND a.attname = 'transportreq' AND NOT a.attisdropped)
$$;

-- ---------------------------------------------------------------------
-- Staff Enrollment (a tab of the Student Enrollment screen): which staff
-- travel on a route, and where they get on and off. The same rows and rules
-- as a student's (_enrollment_save above), in tr_staff_enrollment
-- (transport_23); the staff are the school app's staff of the year
-- (staffmast, by staf_id). Only a staff member who is active (is_active)
-- and whose transport is BUS (transportreq) is put on a route, or made
-- Active again; the saved row of one who is not can still be changed or
-- Cancelled. Returns the number of rows saved.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._staff_enrollment_save(p_ins integer, p_usr integer, p_iyr bigint, p_sch text, p_row jsonb)
RETURNS bigint LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE
  y record; x jsonb; v_route bigint; v_code text; v_on boolean; v_ids numeric[] := '{}';
  v_eid bigint; v_staf numeric; v_who text; v_bus boolean; v_old jsonb; v_type text; v_pick bigint; v_drop bigint;
  v_stage bigint; v_start date; v_end date; v_status text; v_bad text; v_other text;
BEGIN
  SELECT * INTO y FROM transport_core._student_year(p_iyr);
  IF NOT transport_core._staff_ready(y.sch, p_sch) THEN
    RAISE EXCEPTION 'Staff transport has not been set up for this academic year.';
  END IF;
  IF jsonb_typeof(p_row->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(p_row->'rows') = 0 THEN
    RAISE EXCEPTION 'Nothing to save.';
  END IF;
  v_route := NULLIF(p_row->>'route_id', '')::bigint;
  SELECT r.route_code, r.is_active INTO v_code, v_on FROM public.tr_route r WHERE r.route_id = v_route AND r.inst_id = p_ins;
  IF v_code IS NULL THEN RAISE EXCEPTION 'The selected route was not found.'; END IF;

  FOR x IN SELECT r FROM jsonb_array_elements(p_row->'rows') r LOOP
    IF jsonb_typeof(x) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
    v_eid := NULLIF(x->>'enrollment_id', '')::bigint;
    v_staf := NULLIF(x->>'staf_id', '')::numeric;
    IF v_staf IS NULL THEN RAISE EXCEPTION 'A staff member is missing. Refresh and try again.'; END IF;
    IF v_staf = ANY (v_ids) THEN RAISE EXCEPTION 'A staff member is listed twice. Keep one row for each staff member.'; END IF;
    v_ids := v_ids || v_staf;
    -- the staff member, named in every message below; v_bus: may travel
    v_who := NULL;
    EXECUTE format('SELECT concat_ws('' '', m.emp_code, m.stafname), (m.is_active AND upper(btrim(m.transportreq)) = ''BUS'')
                      FROM %I.staffmast m JOIN public.schstaff s ON s.staf_id = m.staf_id
                     WHERE m.staf_id = $1 AND s.ins_id = $2', y.sch)
       INTO v_who, v_bus USING v_staf, p_ins;
    IF v_who IS NULL THEN RAISE EXCEPTION 'A staff member was not found in this academic year. Refresh and try again.'; END IF;

    v_old := NULL;
    IF v_eid IS NOT NULL THEN
      EXECUTE format('SELECT to_jsonb(t) FROM %I.tr_staff_enrollment t WHERE t.enrollment_id = $1 AND t.inst_id = $2 AND t.acad_year_id = $3 FOR UPDATE', p_sch)
         INTO v_old USING v_eid, p_ins, p_iyr;
      IF v_old IS NULL OR (v_old->>'route_id')::bigint <> v_route OR (v_old->>'staf_id')::numeric <> v_staf THEN
        RAISE EXCEPTION 'The enrollment of % was not found on this route. Refresh and try again.', v_who;
      END IF;
      IF x ? 'updated_at' AND (x->>'updated_at')::timestamptz IS DISTINCT FROM (v_old->>'updated_at')::timestamptz THEN
        RAISE EXCEPTION 'The enrollment of % was changed by someone else. Refresh and try again.', v_who;
      END IF;
    ELSE
      IF v_bus IS NOT TRUE THEN RAISE EXCEPTION '% is not an active staff member whose transport is BUS.', v_who; END IF;
      IF NOT v_on THEN RAISE EXCEPTION 'Route % is switched off, so no staff member can be added to it.', v_code; END IF;
    END IF;

    v_type := COALESCE(NULLIF(btrim(x->>'service_type'), ''), 'BOTH');
    IF v_type NOT IN ('BOTH', 'PICKUP', 'DROP') THEN RAISE EXCEPTION 'Choose the trip type of %: Both, Pickup or Drop.', v_who; END IF;
    v_pick := CASE WHEN v_type IN ('BOTH', 'PICKUP') THEN NULLIF(x->>'pickup_stop_id', '')::bigint END;
    v_drop := CASE WHEN v_type IN ('BOTH', 'DROP') THEN NULLIF(x->>'drop_stop_id', '')::bigint END;
    IF v_type <> 'DROP' AND v_pick IS NULL THEN RAISE EXCEPTION 'Choose the pickup stop of %.', v_who; END IF;
    IF v_type <> 'PICKUP' AND v_drop IS NULL THEN RAISE EXCEPTION 'Choose the drop stop of %.', v_who; END IF;
    IF (SELECT count(*) FROM public.tr_stop p WHERE p.stop_id IN (v_pick, v_drop) AND p.route_id = v_route)
       <> (SELECT count(DISTINCT i) FROM unnest(ARRAY[v_pick, v_drop]) i WHERE i IS NOT NULL) THEN
      RAISE EXCEPTION 'A stop chosen for % is not on route %.', v_who, v_code;
    END IF;
    SELECT string_agg(p.stop_name, ', ') INTO v_bad FROM public.tr_stop p
     WHERE p.stop_id IN (v_pick, v_drop) AND NOT p.is_active
       AND p.stop_id NOT IN (COALESCE((v_old->>'pickup_stop_id')::bigint, -1), COALESCE((v_old->>'drop_stop_id')::bigint, -1));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'The stop % chosen for % is switched off.', v_bad, v_who; END IF;
    -- the fee stage: the stage of the farther stop
    SELECT g.stage_id INTO v_stage FROM public.tr_stop p JOIN public.tr_stage g ON g.stage_id = p.stage_id
     WHERE p.stop_id IN (v_pick, v_drop) ORDER BY g.stage_no DESC, g.stage_id DESC LIMIT 1;

    v_start := NULLIF(btrim(x->>'start_date'), '')::date;
    v_end := NULLIF(btrim(x->>'end_date'), '')::date;
    IF v_start IS NULL THEN RAISE EXCEPTION 'Choose the start date of %.', v_who; END IF;
    IF v_end < v_start THEN RAISE EXCEPTION 'The end date of % cannot be before the start date.', v_who; END IF;
    IF v_start < y.from_date OR v_start > y.to_date OR v_end > y.to_date THEN
      RAISE EXCEPTION 'The dates of % must be within the academic year (% to %).', v_who,
        to_char(y.from_date, 'DD-MM-YYYY'), to_char(y.to_date, 'DD-MM-YYYY');
    END IF;

    v_status := COALESCE(NULLIF(btrim(x->>'status'), ''), 'ACTIVE');
    IF v_status NOT IN ('ACTIVE', 'SUSPENDED', 'CANCELLED', 'COMPLETED') THEN
      RAISE EXCEPTION 'Choose the status of %: Active, Suspended, Cancelled or Completed.', v_who;
    END IF;
    IF v_status = 'ACTIVE' THEN
      IF v_old IS NOT NULL AND v_old->>'status' <> 'ACTIVE' AND v_bus IS NOT TRUE THEN
        RAISE EXCEPTION '% is not an active staff member whose transport is BUS, so cannot be made Active again.', v_who;
      END IF;
      v_other := NULL;
      EXECUTE format('SELECT r.route_code FROM %I.tr_staff_enrollment t JOIN public.tr_route r ON r.route_id = t.route_id
                       WHERE t.staf_id = $1 AND t.acad_year_id = $2 AND t.status = ''ACTIVE'' AND t.enrollment_id IS DISTINCT FROM $3 LIMIT 1', p_sch)
         INTO v_other USING v_staf, p_iyr, v_eid;
      IF v_other IS NOT NULL THEN RAISE EXCEPTION '% is already enrolled on route %.', v_who, v_other; END IF;
    END IF;

    IF v_eid IS NULL THEN
      EXECUTE format('INSERT INTO %I.tr_staff_enrollment (inst_id, acad_year_id, staf_id, route_id, service_type, pickup_stop_id, drop_stop_id,
                        fee_stage_id, start_date, end_date, status, created_by, updated_by)
                      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12)', p_sch)
        USING p_ins, p_iyr, v_staf, v_route, v_type, v_pick, v_drop, v_stage, v_start, v_end, v_status, p_usr;
    ELSE
      EXECUTE format('UPDATE %I.tr_staff_enrollment SET service_type = $2, pickup_stop_id = $3, drop_stop_id = $4, fee_stage_id = $5,
                        start_date = $6, end_date = $7, status = $8, updated_by = $9 WHERE enrollment_id = $1', p_sch)
        USING v_eid, v_type, v_pick, v_drop, v_stage, v_start, v_end, v_status, p_usr;
    END IF;
  END LOOP;
  PERFORM transport_core._route_trips_sync(p_ins, p_sch, v_route);  -- the trips already made follow
  RETURN cardinality(v_ids);
END $$;

-- ---------------------------------------------------------------------
-- Vehicle Allotment: which vehicle each student of a route travels in, one
-- way at a time. The vehicle is a schedule of the route in that direction
-- (tr_trip_schedule, with its vehicle), kept on the enrollment as
-- pickup_schedule_id or drop_schedule_id; none means not allotted yet (such
-- a student rides only when the route has one vehicle that way: see
-- transport_core.fn_sync_trip_riders). The trips already made for today or
-- later follow the change (_route_trips_sync). The app sends
-- the screen's changed rows together:
--   {"route_id": 5, "direction": "PICKUP",
--    "rows": [{"enrollment_id": 9, "schedule_id": 3 (none: not allotted),
--              "updated_at": "..." (as listed)}, ...]}
-- Each row must be an active enrollment of this route in the session year
-- that travels that way (Both, or that direction), unchanged by anyone else
-- meanwhile; each schedule one of this route's, in that direction, switched
-- on. Then no schedule given students may have more active students than
-- its vehicle's capacity: its seats plus its additional capacity for small
-- children (transport_21). Errors name the student or the vehicle.
-- The staff of the route (tr_staff_enrollment, transport_23) take seats in
-- the same vehicles: their changed rows come as "staff_rows", in the same
-- shape (their own enrollment ids), are checked the same way, and count
-- towards the capacity with the students.
-- Returns the number of rows saved.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._allotment_save(p_ins integer, p_usr integer, p_iyr bigint, p_sch text, p_row jsonb)
RETURNS bigint LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE
  y record; x jsonb; v_route bigint; v_code text; v_dir text; v_col text; v_ids bigint[] := '{}'; v_scheds bigint[] := '{}';
  v_eid bigint; v_sid bigint; v_old jsonb; v_who text; v_ok boolean;
  v_bus text; v_trip text; v_seats integer; v_extra integer; v_n bigint;
  v_rows jsonb := COALESCE(p_row->'rows', '[]'::jsonb); v_srows jsonb := COALESCE(p_row->'staff_rows', '[]'::jsonb);
  v_staff boolean; v_sids bigint[] := '{}'; v_nst bigint; v_nsf bigint;
BEGIN
  SELECT * INTO y FROM transport_core._student_year(p_iyr);
  IF jsonb_typeof(v_rows) IS DISTINCT FROM 'array' OR jsonb_typeof(v_srows) IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_rows) + jsonb_array_length(v_srows) = 0 THEN
    RAISE EXCEPTION 'Nothing to save.';
  END IF;
  -- the staff ride in the same vehicles, where the year has staff transport
  v_staff := transport_core._staff_ready(y.sch, p_sch);
  IF jsonb_array_length(v_srows) > 0 AND NOT v_staff THEN
    RAISE EXCEPTION 'Staff transport has not been set up for this academic year.';
  END IF;
  v_route := NULLIF(p_row->>'route_id', '')::bigint;
  SELECT r.route_code INTO v_code FROM public.tr_route r WHERE r.route_id = v_route AND r.inst_id = p_ins;
  IF v_code IS NULL THEN RAISE EXCEPTION 'The selected route was not found.'; END IF;
  v_dir := p_row->>'direction';
  IF v_dir IS DISTINCT FROM 'PICKUP' AND v_dir IS DISTINCT FROM 'DROP' THEN RAISE EXCEPTION 'Choose Pickup or Drop.'; END IF;
  v_col := CASE v_dir WHEN 'PICKUP' THEN 'pickup_schedule_id' ELSE 'drop_schedule_id' END;

  FOR x IN SELECT r FROM jsonb_array_elements(v_rows) r LOOP
    IF jsonb_typeof(x) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
    v_eid := NULLIF(x->>'enrollment_id', '')::bigint;
    IF v_eid IS NULL THEN RAISE EXCEPTION 'A student is missing. Refresh and try again.'; END IF;
    IF v_eid = ANY (v_ids) THEN RAISE EXCEPTION 'A student is listed twice.'; END IF;
    v_ids := v_ids || v_eid;
    v_old := NULL;
    EXECUTE format('SELECT to_jsonb(t) FROM %I.tr_student_enrollment t WHERE t.enrollment_id = $1 AND t.inst_id = $2 AND t.acad_year_id = $3 FOR UPDATE', p_sch)
       INTO v_old USING v_eid, p_ins, p_iyr;
    IF v_old IS NULL OR (v_old->>'route_id')::bigint IS DISTINCT FROM v_route THEN
      RAISE EXCEPTION 'A student is not on route % any more. Refresh and try again.', v_code;
    END IF;
    -- the student, named in the messages below
    v_who := NULL;
    EXECUTE format('SELECT concat_ws('' '', s.stuadmno, s.stuname) FROM %I.students s WHERE s.stu_id = $1', y.sch)
       INTO v_who USING (v_old->>'student_id')::bigint;
    v_who := COALESCE(NULLIF(v_who, ''), 'A student');
    IF x ? 'updated_at' AND (x->>'updated_at')::timestamptz IS DISTINCT FROM (v_old->>'updated_at')::timestamptz THEN
      RAISE EXCEPTION 'The transport of % was changed by someone else. Refresh and try again.', v_who;
    END IF;
    IF v_old->>'status' IS DISTINCT FROM 'ACTIVE' THEN
      RAISE EXCEPTION '% is not active on route % any more. Refresh and try again.', v_who, v_code;
    END IF;
    IF v_old->>'service_type' NOT IN ('BOTH', v_dir) THEN
      RAISE EXCEPTION '% travels % only, so has no % vehicle. Refresh and try again.', v_who, initcap(v_old->>'service_type'), lower(v_dir);
    END IF;
    v_sid := NULLIF(x->>'schedule_id', '')::bigint;
    IF v_sid IS NOT NULL THEN
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.tr_trip_schedule s
                       WHERE s.schedule_id = $1 AND s.inst_id = $2 AND s.route_id = $3 AND s.direction = $4 AND s.is_active)', p_sch)
         INTO v_ok USING v_sid, p_ins, v_route, v_dir;
      IF NOT v_ok THEN
        RAISE EXCEPTION 'The vehicle chosen for % is not on a % trip of route %, or that trip is switched off. Refresh and try again.',
          v_who, lower(v_dir), v_code;
      END IF;
      v_scheds := v_scheds || v_sid;
    END IF;
    EXECUTE format('UPDATE %I.tr_student_enrollment SET %I = $2, updated_by = $3 WHERE enrollment_id = $1', p_sch, v_col)
      USING v_eid, v_sid, p_usr;
  END LOOP;

  -- the staff, checked the same way
  FOR x IN SELECT r FROM jsonb_array_elements(v_srows) r LOOP
    IF jsonb_typeof(x) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
    v_eid := NULLIF(x->>'enrollment_id', '')::bigint;
    IF v_eid IS NULL THEN RAISE EXCEPTION 'A staff member is missing. Refresh and try again.'; END IF;
    IF v_eid = ANY (v_sids) THEN RAISE EXCEPTION 'A staff member is listed twice.'; END IF;
    v_sids := v_sids || v_eid;
    v_old := NULL;
    EXECUTE format('SELECT to_jsonb(t) FROM %I.tr_staff_enrollment t WHERE t.enrollment_id = $1 AND t.inst_id = $2 AND t.acad_year_id = $3 FOR UPDATE', p_sch)
       INTO v_old USING v_eid, p_ins, p_iyr;
    IF v_old IS NULL OR (v_old->>'route_id')::bigint IS DISTINCT FROM v_route THEN
      RAISE EXCEPTION 'A staff member is not on route % any more. Refresh and try again.', v_code;
    END IF;
    v_who := NULL;
    EXECUTE format('SELECT concat_ws('' '', m.emp_code, m.stafname) FROM %I.staffmast m WHERE m.staf_id = $1', y.sch)
       INTO v_who USING (v_old->>'staf_id')::numeric;
    v_who := COALESCE(NULLIF(v_who, ''), 'A staff member');
    IF x ? 'updated_at' AND (x->>'updated_at')::timestamptz IS DISTINCT FROM (v_old->>'updated_at')::timestamptz THEN
      RAISE EXCEPTION 'The transport of % was changed by someone else. Refresh and try again.', v_who;
    END IF;
    IF v_old->>'status' IS DISTINCT FROM 'ACTIVE' THEN
      RAISE EXCEPTION '% is not active on route % any more. Refresh and try again.', v_who, v_code;
    END IF;
    IF v_old->>'service_type' NOT IN ('BOTH', v_dir) THEN
      RAISE EXCEPTION '% travels % only, so has no % vehicle. Refresh and try again.', v_who, initcap(v_old->>'service_type'), lower(v_dir);
    END IF;
    v_sid := NULLIF(x->>'schedule_id', '')::bigint;
    IF v_sid IS NOT NULL THEN
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.tr_trip_schedule s
                       WHERE s.schedule_id = $1 AND s.inst_id = $2 AND s.route_id = $3 AND s.direction = $4 AND s.is_active)', p_sch)
         INTO v_ok USING v_sid, p_ins, v_route, v_dir;
      IF NOT v_ok THEN
        RAISE EXCEPTION 'The vehicle chosen for % is not on a % trip of route %, or that trip is switched off. Refresh and try again.',
          v_who, lower(v_dir), v_code;
      END IF;
      v_scheds := v_scheds || v_sid;
    END IF;
    EXECUTE format('UPDATE %I.tr_staff_enrollment SET %I = $2, updated_by = $3 WHERE enrollment_id = $1', p_sch, v_col)
      USING v_eid, v_sid, p_usr;
  END LOOP;

  -- no vehicle with more riders (students, and staff) than its capacity (seats + additional)
  EXECUTE format('SELECT v.vehicle_code, s.schedule_code, v.seating_capacity, v.additional_capacity,
                         count(*) FILTER (WHERE NOT t.staff), count(*) FILTER (WHERE t.staff)
                    FROM (SELECT x.%2$I AS sid, false AS staff FROM %1$I.tr_student_enrollment x
                           WHERE x.%2$I = ANY ($1) AND x.status = ''ACTIVE'' AND x.acad_year_id = $2 %3$s) t
                    JOIN %1$I.tr_trip_schedule s ON s.schedule_id = t.sid
                    JOIN public.tr_vehicle v ON v.vehicle_id = s.vehicle_id
                   GROUP BY v.vehicle_code, s.schedule_code, v.seating_capacity, v.additional_capacity
                  HAVING count(*) > v.seating_capacity + v.additional_capacity
                   ORDER BY s.schedule_code LIMIT 1', p_sch, v_col,
                 CASE WHEN v_staff THEN format('UNION ALL SELECT x.%2$I, true FROM %1$I.tr_staff_enrollment x
                           WHERE x.%2$I = ANY ($1) AND x.status = ''ACTIVE'' AND x.acad_year_id = $2', p_sch, v_col) ELSE '' END)
     INTO v_bus, v_trip, v_seats, v_extra, v_nst, v_nsf USING v_scheds, p_iyr;
  IF v_bus IS NOT NULL THEN
    RAISE EXCEPTION '% (trip %) would have % for %. Take some out, or use a bigger vehicle.', v_bus, v_trip,
      CASE WHEN v_nsf = 0 THEN format('%s students', v_nst)
           ELSE format('%s %s and %s staff', v_nst, CASE WHEN v_nst = 1 THEN 'student' ELSE 'students' END, v_nsf) END,
      CASE WHEN v_extra > 0 THEN format('a capacity of %s (%s seats + %s additional)', v_seats + v_extra, v_seats, v_extra)
           ELSE format('%s seats', v_seats) END;
  END IF;
  PERFORM transport_core._route_trips_sync(p_ins, p_sch, v_route);  -- the trips already made follow
  RETURN cardinality(v_ids) + cardinality(v_sids);
END $$;

-- After an enrollment or a Vehicle Allotment change on a route: the route's
-- trips already made for today or later, still Scheduled, follow it
-- (transport_core.fn_sync_trip_riders). Riders someone marked stay as they
-- are. Returns how many riders changed.
CREATE OR REPLACE FUNCTION transport_core._route_trips_sync(p_ins integer, p_sch text, p_route bigint)
RETURNS integer LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public' AS $$
DECLARE v_trip bigint; v_n integer := 0;
BEGIN
  IF p_route IS NULL OR to_regclass(format('%I.tr_trip', p_sch)) IS NULL THEN RETURN 0; END IF;
  FOR v_trip IN EXECUTE format('SELECT trip_id FROM %I.tr_trip WHERE inst_id = $1 AND route_id = $2
                                  AND status = ''SCHEDULED'' AND trip_date >= $3 ORDER BY trip_id', p_sch)
      USING p_ins, p_route, transport_core._today() LOOP
    v_n := v_n + transport_core.fn_sync_trip_riders(p_sch, v_trip);
  END LOOP;
  RETURN v_n;
END $$;

-- ---------------------------------------------------------------------
-- Stage Fees: the fee of each stage of one route, for one term (the school
-- app's semester of the session year) and one way, saved together from the
-- Stage Fees screen (tr_stage_fee):
--   {"route_id": 5, "sem_id": 1, "service_type": "BOTH", "fee_id": 2,
--    "effective_from": "2026-06-01", "effective_to": "2026-11-30",
--    "fees": [{"stage_id": 21, "stage_fee_id": 7 (none for a new fee),
--              "amount": 5000 (empty: remove the stage's fee)}, ...]}
-- The fee type and the dates are given to every fee sent. Checked: the
-- route is the school's; the term is the school's in the session year and
-- the dates are within it, To not before From; the fee type is the school's,
-- switched on and a transport fee (feecat TRA); each stage is on the route,
-- listed once, and switched on for a new fee; an amount is not negative; a
-- stage_fee_id is that stage's fee for this term and way; and a stage has
-- one fee per term, way and start date. Errors name the stage.
-- Returns the number of stages saved.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._stage_fee_save(p_ins integer, p_usr integer, p_iyr bigint, p_sch text, p_row jsonb)
RETURNS bigint LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE
  y record; x jsonb; v_route bigint; v_code text; v_sem smallint; v_term text; v_t1 date; v_t2 date;
  v_fee integer; v_cat text; v_fee_on smallint; v_type text; v_from date; v_to date;
  v_stage bigint; v_ids bigint[] := '{}'; v_who text; v_on boolean; v_sid bigint; v_old jsonb; v_amt numeric; v_dup boolean;
  v_n bigint := 0;
BEGIN
  SELECT * INTO y FROM transport_core._student_year(p_iyr);
  IF jsonb_typeof(p_row->'fees') IS DISTINCT FROM 'array' OR jsonb_array_length(p_row->'fees') = 0 THEN
    RAISE EXCEPTION 'Nothing to save.';
  END IF;
  v_route := NULLIF(p_row->>'route_id', '')::bigint;
  SELECT r.route_code INTO v_code FROM public.tr_route r WHERE r.route_id = v_route AND r.inst_id = p_ins;
  IF v_code IS NULL THEN RAISE EXCEPTION 'The selected route was not found.'; END IF;

  v_sem := NULLIF(p_row->>'sem_id', '')::smallint;
  IF v_sem IS NULL THEN RAISE EXCEPTION 'Choose the term.'; END IF;
  IF to_regclass(quote_ident(y.sch) || '.semester') IS NOT NULL THEN
    EXECUTE format('SELECT COALESCE(NULLIF(btrim(s.semname), ''''), ''the term''), s.semstart, s.semend
                      FROM %I.semester s WHERE s.sem_id = $1 AND s.ins_id = $2', y.sch)
       INTO v_term, v_t1, v_t2 USING v_sem, p_ins;
  END IF;
  IF v_term IS NULL THEN RAISE EXCEPTION 'The selected term was not found in this academic year.'; END IF;

  v_fee := NULLIF(p_row->>'fee_id', '')::integer;
  IF v_fee IS NULL THEN RAISE EXCEPTION 'Choose the fee type.'; END IF;
  SELECT f.feecat, f.activestatus INTO v_cat, v_fee_on FROM public.feetype f WHERE f.fee_id = v_fee AND f.ins_id = p_ins;
  IF NOT FOUND THEN RAISE EXCEPTION 'The selected fee type was not found.'; END IF;
  IF v_cat IS DISTINCT FROM 'TRA' THEN RAISE EXCEPTION 'Choose a transport fee type (fee category TRA).'; END IF;
  IF v_fee_on IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'The selected fee type is switched off.'; END IF;

  v_type := COALESCE(NULLIF(btrim(p_row->>'service_type'), ''), 'BOTH');
  IF v_type NOT IN ('BOTH', 'PICKUP', 'DROP') THEN RAISE EXCEPTION 'Choose the service: Both, Pickup or Drop.'; END IF;
  v_from := NULLIF(btrim(p_row->>'effective_from'), '')::date;
  v_to := NULLIF(btrim(p_row->>'effective_to'), '')::date;
  IF v_from IS NULL THEN RAISE EXCEPTION 'Choose the Effective From date.'; END IF;
  IF v_to < v_from THEN RAISE EXCEPTION 'The Effective To date cannot be before the Effective From date.'; END IF;
  IF v_from < v_t1 OR v_from > v_t2 OR v_to > v_t2 THEN
    RAISE EXCEPTION 'The dates must be within % (% to %).', v_term, to_char(v_t1, 'DD-MM-YYYY'), to_char(v_t2, 'DD-MM-YYYY');
  END IF;

  FOR x IN SELECT r FROM jsonb_array_elements(p_row->'fees') r LOOP
    IF jsonb_typeof(x) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
    v_stage := NULLIF(x->>'stage_id', '')::bigint;
    IF v_stage IS NULL THEN RAISE EXCEPTION 'A stage is missing. Refresh and try again.'; END IF;
    IF v_stage = ANY (v_ids) THEN RAISE EXCEPTION 'A stage is listed twice. Keep one row for each stage.'; END IF;
    v_ids := v_ids || v_stage;
    -- the stage, named in every message below
    v_who := NULL;
    SELECT format('Stage %s (%s)', g.stage_no, g.stage_name), g.is_active INTO v_who, v_on
      FROM public.tr_stage g WHERE g.stage_id = v_stage AND g.route_id = v_route;
    IF v_who IS NULL THEN RAISE EXCEPTION 'A stage is not on route %. Refresh and try again.', v_code; END IF;

    v_sid := NULLIF(x->>'stage_fee_id', '')::bigint;
    IF v_sid IS NOT NULL THEN
      EXECUTE format('SELECT to_jsonb(t) FROM %I.tr_stage_fee t WHERE t.stage_fee_id = $1 FOR UPDATE', p_sch) INTO v_old USING v_sid;
      IF v_old IS NULL OR (v_old->>'route_id')::bigint <> v_route OR (v_old->>'stage_id')::bigint <> v_stage
         OR (v_old->>'sem_id')::smallint <> v_sem OR v_old->>'service_type' <> v_type THEN
        RAISE EXCEPTION 'The fee of % was not found for this term. Refresh and try again.', v_who;
      END IF;
    END IF;

    -- an empty amount removes the stage's fee, unless students were billed
    -- from it (the Stage Fee Process, tr_stage_fee_demand)
    IF NULLIF(btrim(x->>'amount'), '') IS NULL THEN
      IF v_sid IS NOT NULL THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.tr_stage_fee_demand d WHERE d.stage_fee_id = $1)', p_sch) INTO v_dup USING v_sid;
        IF v_dup THEN
          RAISE EXCEPTION 'Students'' fee demands were made from the fee of %, so it cannot be removed. Change the amount and process the route again instead.', v_who;
        END IF;
        EXECUTE format('DELETE FROM %I.tr_stage_fee WHERE stage_fee_id = $1', p_sch) USING v_sid;
        v_n := v_n + 1;
      END IF;
      CONTINUE;
    END IF;
    v_amt := (x->>'amount')::numeric;
    IF v_amt < 0 THEN RAISE EXCEPTION 'The fee of % cannot be negative.', v_who; END IF;
    IF v_sid IS NULL AND NOT v_on THEN RAISE EXCEPTION '% is switched off, so it cannot get a new fee.', v_who; END IF;
    -- one fee of a stage per term, way and start date
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.tr_stage_fee t WHERE t.stage_id = $1 AND t.service_type = $2 AND t.sem_id = $3
                     AND t.effective_from = $4 AND t.stage_fee_id IS DISTINCT FROM $5)', p_sch)
       INTO v_dup USING v_stage, v_type, v_sem, v_from, v_sid;
    IF v_dup THEN
      RAISE EXCEPTION '% already has a fee for this term and service from %. Refresh and try again.', v_who, to_char(v_from, 'DD-MM-YYYY');
    END IF;

    IF v_sid IS NULL THEN
      EXECUTE format('INSERT INTO %I.tr_stage_fee (route_id, stage_id, service_type, fee_id, sem_id, amount, effective_from, effective_to, created_by)
                      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)', p_sch)
        USING v_route, v_stage, v_type, v_fee, v_sem, v_amt, v_from, v_to, p_usr;
    ELSE
      EXECUTE format('UPDATE %I.tr_stage_fee SET fee_id = $2, amount = $3, effective_from = $4, effective_to = $5, updated_by = $6
                       WHERE stage_fee_id = $1', p_sch)
        USING v_sid, v_fee, v_amt, v_from, v_to, p_usr;
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- A copy of every route's stage fees from one term to another, saved at
-- once, was tried and not wanted: Copy to Term copies one route with the
-- batch above. Gone from any database that had it.
DROP FUNCTION IF EXISTS transport_core._stage_fee_copy(integer, integer, bigint, text, jsonb);

-- ---------------------------------------------------------------------
-- Save (insert when the key is empty, else update)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core.save(p_token text, p_entity text, p_row jsonb)
RETURNS bigint LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE
  e record; c record; v_sch text; k text; val jsonb; s text; x text;
  v_row jsonb := '{}'; v_old jsonb; v_eff jsonb; v_id bigint; v_out bigint; v_list text; v_sel text; v_set text;
  v_con text; v_digits text; v_found boolean; p jsonb; v_stops jsonb;
  v_name text; v_type text; v_status text; v_code text; v_t1 time; v_t2 time; v_d1 date; v_d2 date;
BEGIN
  SELECT * INTO e FROM transport_core._entity(p_entity);
  SELECT * INTO c FROM transport_core._ctx(p_token, e.menus);
  v_sch := COALESCE(e.sch, transport_core._year(c.ysch, c.yr));
  IF jsonb_typeof(p_row) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
  IF p_entity = 'vehicle_gps' THEN
    RETURN transport_core._vehicle_gps_save(c.ins, c.usr, p_row);  -- the GPS Mapping tab's batch
  END IF;
  IF p_entity = 'enrollment' THEN
    RETURN transport_core._enrollment_save(c.ins, c.usr, c.iyr, v_sch, p_row);  -- the Student Enrollment screen's batch
  END IF;
  IF p_entity = 'staff_enrollment' THEN
    RETURN transport_core._staff_enrollment_save(c.ins, c.usr, c.iyr, v_sch, p_row);  -- the Staff Enrollment tab's batch
  END IF;
  IF p_entity = 'allotment' THEN
    RETURN transport_core._allotment_save(c.ins, c.usr, c.iyr, v_sch, p_row);  -- the Vehicle Allotment screen's batch
  END IF;
  IF p_entity = 'staff_allotment' THEN
    RAISE EXCEPTION 'The staff''s vehicles are saved with the students'' on the Vehicle Allotment screen.';
  END IF;
  IF p_entity = 'stage_fee' AND p_row ? 'fees' THEN
    RETURN transport_core._stage_fee_save(c.ins, c.usr, c.iyr, v_sch, p_row);  -- the Stage Fees screen's batch
  END IF;

  -- Only listed columns; text trimmed, blank means empty, codes upper case.
  FOR k, val IN SELECT * FROM jsonb_each(p_row) LOOP
    CONTINUE WHEN NOT (k = ANY (e.cols));
    IF jsonb_typeof(val) = 'string' THEN
      s := NULLIF(btrim(val #>> '{}'), '');
      IF s IS NOT NULL AND k = ANY (e.upper_cols) THEN s := upper(s); END IF;
      val := to_jsonb(s);
    END IF;
    v_row := v_row || jsonb_build_object(k, val);
  END LOOP;

  v_id := NULLIF(p_row->>e.pk, '')::bigint;
  IF v_id IS NOT NULL THEN
    EXECUTE format('SELECT to_jsonb(t) FROM %I.%I t WHERE t.%I = $1 AND %s', v_sch, e.tbl, e.pk, transport_core._of_school(p_entity, '$2'))
       INTO v_old USING v_id, c.ins;
    IF v_old IS NULL THEN RAISE EXCEPTION 'This % was not found. Refresh and try again.', e.noun; END IF;
    v_eff := v_old || v_row;
  ELSE
    v_eff := v_row;
  END IF;

  FOR k, x IN SELECT * FROM jsonb_each_text(e.req) LOOP
    IF v_eff->>k IS NULL THEN RAISE EXCEPTION 'Enter the %.', x; END IF;
  END LOOP;

  -- A parent record must belong to this school.
  FOR k, p IN SELECT * FROM jsonb_each(e.parents) LOOP
    IF v_row->>k IS NOT NULL THEN
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I t WHERE t.%I = $1 AND t.inst_id = $2)',
                     COALESCE(NULLIF(p->>0, ''), transport_core._year(c.ysch, c.yr)), p->>1, p->>2)
         INTO v_found USING (v_row->>k)::bigint, c.ins;
      IF NOT v_found THEN RAISE EXCEPTION 'The selected % was not found.', p->>3; END IF;
    END IF;
  END LOOP;

  IF p_entity = 'stage' AND (v_eff->>'from_km')::numeric > (v_eff->>'to_km')::numeric THEN
    RAISE EXCEPTION 'From km cannot be more than To km.';
  END IF;

  -- The additional capacity (small children, transport_21): left empty it is
  -- none, and it is never more than the seats.
  IF p_entity = 'vehicle' THEN
    IF v_row ? 'additional_capacity' AND v_row->>'additional_capacity' IS NULL THEN
      v_row := v_row || '{"additional_capacity": 0}';
      v_eff := v_eff || '{"additional_capacity": 0}';
    END IF;
    IF (v_eff->>'additional_capacity')::integer > (v_eff->>'seating_capacity')::integer THEN
      RAISE EXCEPTION 'The additional capacity cannot be more than the seating capacity.';
    END IF;
  END IF;

  IF p_entity = 'vehicle' AND v_old->>'gps_device_id' IS NOT NULL AND (v_eff->>'has_gps')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'This vehicle has a GPS device on it. Take it off in GPS Mapping before turning GPS off.';
  END IF;

  IF p_entity = 'stage_fee' THEN
    IF (v_eff->>'effective_to')::date < (v_eff->>'effective_from')::date THEN
      RAISE EXCEPTION 'The Effective To date cannot be before the Effective From date.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.tr_stage g
                    WHERE g.stage_id = (v_eff->>'stage_id')::bigint AND g.route_id = (v_eff->>'route_id')::bigint) THEN
      RAISE EXCEPTION 'That stage belongs to a different route.';
    END IF;
    -- a transport fee head (fee category TRA) of this school's fee module
    IF v_row->>'fee_id' IS NOT NULL THEN
      SELECT f.feecat INTO x FROM public.feetype f WHERE f.fee_id = (v_row->>'fee_id')::integer AND f.ins_id = c.ins;
      IF NOT FOUND THEN RAISE EXCEPTION 'The selected fee type was not found.'; END IF;
      IF x IS DISTINCT FROM 'TRA' THEN RAISE EXCEPTION 'Choose a transport fee type (fee category TRA).'; END IF;
    END IF;
    -- a term of this school in the session's year (the school app's semester)
    IF v_row->>'sem_id' IS NOT NULL THEN
      SELECT y.sch INTO x FROM transport_core._student_year(c.iyr) y;
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.semester s WHERE s.sem_id = $1 AND s.ins_id = $2)', x)
         INTO v_found USING (v_row->>'sem_id')::smallint, c.ins;
      IF NOT v_found THEN RAISE EXCEPTION 'The selected term was not found.'; END IF;
    END IF;
    IF v_row->>'activestatus' IS NOT NULL AND v_row->>'activestatus' NOT IN ('0', '1') THEN
      RAISE EXCEPTION 'Active status must be 1 (active) or 0 (inactive).';
    END IF;
    -- checked here as well as by uq_stage_fee, whose name a new year's copy does not keep
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.tr_stage_fee t WHERE t.stage_id = $1 AND t.service_type = $2 AND t.sem_id = $3
                     AND t.effective_from = $4 AND t.stage_fee_id IS DISTINCT FROM $5)', v_sch)
       INTO v_found USING (v_eff->>'stage_id')::bigint, COALESCE(v_eff->>'service_type', 'BOTH'), (v_eff->>'sem_id')::smallint,
                          (v_eff->>'effective_from')::date, v_id;
    IF v_found THEN RAISE EXCEPTION 'This stage already has a fee for that term, service and date.'; END IF;
  END IF;

  IF p_entity IN ('vendor', 'staff') THEN
    FOREACH k IN ARRAY ARRAY['mobile', 'alt_mobile', 'emergency_contact_phone'] LOOP
      IF v_row->>k IS NOT NULL AND (v_row->>k) !~ '^\+?[0-9]{10,14}$' THEN
        RAISE EXCEPTION 'Enter a valid mobile number (10 digits).';
      END IF;
    END LOOP;
  END IF;

  -- A file or photo must be the app's own upload (the public bucket's
  -- transport/ folder), never any other link. An unchanged value is left alone.
  FOREACH k IN ARRAY ARRAY['file_url', 'photo_url'] LOOP
    IF v_row->>k IS NOT NULL AND v_row->>k IS DISTINCT FROM v_old->>k
       AND (v_row->>k) !~ '^https://[^/?#]+/storage/v1/object/public/InstitutionLogos/transport/' THEN
      RAISE EXCEPTION 'The attached file is not valid. Please attach it again.';
    END IF;
  END LOOP;

  IF p_entity = 'staff' AND v_row->>'id_proof_no_masked' IS NOT NULL THEN
    -- never keep a full ID number such as Aadhaar: last four digits only
    v_digits := regexp_replace(v_row->>'id_proof_no_masked', '[^0-9]', '', 'g');
    IF length(v_digits) >= 8 THEN
      v_row := v_row || jsonb_build_object('id_proof_no_masked', 'XXXXXXXX' || right(v_digits, 4));
    END IF;
  END IF;

  IF p_entity = 'stop' THEN
    -- this rule is deferred by the schema; check it now so the error is readable
    SET CONSTRAINTS public.uq_stop_seq IMMEDIATE;
  END IF;

  -- A new current document replaces the old one, which stays as history.
  IF p_entity IN ('vehicle_doc', 'staff_doc') AND COALESCE((v_eff->>'is_current')::boolean, true)
     AND v_eff->>'doc_type' <> 'OTHER' THEN
    x := CASE p_entity WHEN 'vehicle_doc' THEN 'vehicle_id' ELSE 'staff_id' END;
    EXECUTE format('UPDATE %I.%I SET is_current = false, updated_by = $5
                     WHERE inst_id = $1 AND %I = $2 AND doc_type = $3 AND is_current AND %I IS DISTINCT FROM $4',
                   v_sch, e.tbl, x, e.pk)
      USING c.ins, (v_eff->>x)::bigint, v_eff->>'doc_type', v_id, c.usr;
  END IF;

  IF p_entity = 'schedule' THEN
    IF (v_eff->>'planned_end')::time <= (v_eff->>'planned_start')::time THEN
      RAISE EXCEPTION 'The end time must be after the start time.';
    END IF;
    IF (v_eff->>'effective_to')::date < (v_eff->>'effective_from')::date THEN
      RAISE EXCEPTION 'The Effective To date cannot be before the Effective From date.';
    END IF;
    -- run days: ISO weekdays, 1 = Monday .. 7 = Sunday; at least one, kept in order
    IF v_row ? 'run_days' THEN
      IF jsonb_typeof(v_row->'run_days') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Choose the days this schedule runs.';
      END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_row->'run_days') d WHERE d IS NULL OR d !~ '^[1-7]$') THEN
        RAISE EXCEPTION 'Run days must be weekdays 1 (Monday) to 7 (Sunday).';
      END IF;
      SELECT jsonb_agg(DISTINCT d::smallint ORDER BY d::smallint) INTO val FROM jsonb_array_elements_text(v_row->'run_days') d;
      IF val IS NULL THEN RAISE EXCEPTION 'Choose the days this schedule runs.'; END IF;
      v_row := v_row || jsonb_build_object('run_days', val);
    END IF;
    -- a newly chosen route or vehicle must be in use
    IF v_row ? 'route_id' AND (v_row->>'route_id')::bigint IS DISTINCT FROM (v_old->>'route_id')::bigint
       AND NOT EXISTS (SELECT 1 FROM public.tr_route r WHERE r.route_id = (v_row->>'route_id')::bigint AND r.is_active) THEN
      RAISE EXCEPTION 'The selected route is switched off.';
    END IF;
    IF v_row ? 'vehicle_id' AND (v_row->>'vehicle_id')::bigint IS DISTINCT FROM (v_old->>'vehicle_id')::bigint
       AND NOT EXISTS (SELECT 1 FROM public.tr_vehicle vh WHERE vh.vehicle_id = (v_row->>'vehicle_id')::bigint AND vh.status = 'ACTIVE') THEN
      RAISE EXCEPTION 'The selected vehicle is not active.';
    END IF;
    -- checked here as well as by uq_schedule_code, whose name a new year's copy does not keep
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.tr_trip_schedule t WHERE t.inst_id = $1 AND t.schedule_code = $2 AND t.schedule_id IS DISTINCT FROM $3)', v_sch)
       INTO v_found USING c.ins, v_eff->>'schedule_code', v_id;
    IF v_found THEN RAISE EXCEPTION 'This schedule code is already used.'; END IF;
    -- The stops come with the schedule and replace the ones it had. They must
    -- come when the schedule is new, or when its route or times change.
    IF p_row ? 'stops' THEN
      v_stops := transport_core._schedule_stops(p_row->'stops', (v_eff->>'route_id')::bigint,
                                                (v_eff->>'planned_start')::time, (v_eff->>'planned_end')::time);
      IF v_id IS NOT NULL THEN
        -- removed before the update, so the schedule's route can change
        EXECUTE format('DELETE FROM %I.tr_trip_schedule_stop WHERE schedule_id = $1', v_sch) USING v_id;
      END IF;
    ELSIF v_id IS NULL
       OR (v_eff->>'route_id')::bigint IS DISTINCT FROM (v_old->>'route_id')::bigint
       OR (v_eff->>'planned_start')::time IS DISTINCT FROM (v_old->>'planned_start')::time
       OR (v_eff->>'planned_end')::time IS DISTINCT FROM (v_old->>'planned_end')::time THEN
      RAISE EXCEPTION 'Choose the stops for this schedule.';
    END IF;
  END IF;

  -- A duty: a staff member on a schedule, from a date (an open end runs on).
  -- Each day's trip copies the duties of that day to its crew (tr_trip_staff,
  -- one row per staff member), so a duty must not clash with another one.
  IF p_entity = 'duty' THEN
    IF (v_eff->>'effective_to')::date < (v_eff->>'effective_from')::date THEN
      RAISE EXCEPTION 'The Effective To date cannot be before the Effective From date.';
    END IF;
    -- a newly chosen schedule or staff member must be in use
    IF v_row ? 'schedule_id' AND (v_row->>'schedule_id')::bigint IS DISTINCT FROM (v_old->>'schedule_id')::bigint THEN
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.tr_trip_schedule s WHERE s.schedule_id = $1 AND s.is_active)', v_sch)
         INTO v_found USING (v_row->>'schedule_id')::bigint;
      IF NOT v_found THEN RAISE EXCEPTION 'The selected schedule is switched off.'; END IF;
    END IF;
    SELECT f.full_name, f.staff_type, f.status INTO v_name, v_type, v_status
      FROM public.tr_staff f WHERE f.staff_id = (v_eff->>'staff_id')::bigint AND f.inst_id = c.ins;
    IF v_row ? 'staff_id' AND (v_row->>'staff_id')::bigint IS DISTINCT FROM (v_old->>'staff_id')::bigint AND v_status <> 'ACTIVE' THEN
      RAISE EXCEPTION '% is %, so cannot be given a duty.', v_name, lower(replace(v_status, '_', ' '));
    END IF;
    IF v_eff->>'duty_role' = 'DRIVER' AND v_type IS DISTINCT FROM 'DRIVER' THEN
      RAISE EXCEPTION '% is not a driver. Only Driver staff can take the Driver duty.', v_name;
    END IF;
    -- on a schedule: each staff member once at a time, and one driver at a time
    EXECUTE format('SELECT f.full_name, d.staff_id = $5
                      FROM %I.tr_duty_assignment d JOIN public.tr_staff f ON f.staff_id = d.staff_id
                     WHERE d.inst_id = $1 AND d.schedule_id = $2 AND d.duty_id IS DISTINCT FROM $3
                       AND daterange(d.effective_from, d.effective_to, ''[]'') && daterange($6, $7, ''[]'')
                       AND (d.staff_id = $5 OR (d.duty_role = ''DRIVER'' AND $4 = ''DRIVER''))
                     ORDER BY d.staff_id = $5 DESC LIMIT 1', v_sch)
       INTO v_code, v_found
      USING c.ins, (v_eff->>'schedule_id')::bigint, v_id, v_eff->>'duty_role', (v_eff->>'staff_id')::bigint,
            (v_eff->>'effective_from')::date, (v_eff->>'effective_to')::date;
    IF v_found THEN
      RAISE EXCEPTION '% already has a duty on this schedule for those dates.', v_name;
    ELSIF v_code IS NOT NULL THEN
      RAISE EXCEPTION 'This schedule already has a driver, %, for those dates. Set an Effective To date on that duty first.', v_code;
    END IF;
    -- not on another schedule that runs at the same time on a shared day,
    -- for a date both duties and both schedules cover
    EXECUTE format('SELECT o.schedule_code, o.planned_start, o.planned_end
                      FROM %1$I.tr_duty_assignment d
                      JOIN %1$I.tr_trip_schedule o ON o.schedule_id = d.schedule_id AND o.is_active
                      JOIN %1$I.tr_trip_schedule me ON me.schedule_id = $2
                     WHERE d.inst_id = $1 AND d.staff_id = $3 AND d.schedule_id <> $2 AND d.duty_id IS DISTINCT FROM $4
                       AND o.run_days && me.run_days
                       AND o.planned_start < me.planned_end AND me.planned_start < o.planned_end
                       AND GREATEST(d.effective_from, $5, o.effective_from, me.effective_from)
                           <= LEAST(COALESCE(d.effective_to, ''infinity''), COALESCE($6, ''infinity''),
                                    COALESCE(o.effective_to, ''infinity''), COALESCE(me.effective_to, ''infinity''))
                     ORDER BY o.planned_start LIMIT 1', v_sch)
       INTO v_code, v_t1, v_t2
      USING c.ins, (v_eff->>'schedule_id')::bigint, (v_eff->>'staff_id')::bigint, v_id,
            (v_eff->>'effective_from')::date, (v_eff->>'effective_to')::date;
    IF v_code IS NOT NULL THEN
      RAISE EXCEPTION '% is already on schedule % (% to %) at that time.', v_name, v_code,
        to_char(DATE '2000-01-01' + v_t1, 'FMHH12:MI AM'), to_char(DATE '2000-01-01' + v_t2, 'FMHH12:MI AM');
    END IF;
  END IF;

  -- A service record belongs to the session's academic year: a new one gets
  -- it, its service date falls in it, and a record of another year is left
  -- alone. The next service is not due before this one.
  IF p_entity = 'vehicle_service' THEN
    IF c.iyr IS NULL THEN RAISE EXCEPTION 'No academic year is open for this school.'; END IF;
    IF v_id IS NOT NULL AND (v_old->>'acad_year_id')::bigint IS DISTINCT FROM c.iyr THEN
      RAISE EXCEPTION 'This service record is of another academic year. Open that year to change it.';
    END IF;
    SELECT iy.iyrstadate, iy.iyrenddate INTO v_d1, v_d2 FROM public.institutionyear iy WHERE iy.iyr_id = c.iyr;
    IF (v_eff->>'service_date')::date NOT BETWEEN v_d1 AND v_d2 THEN
      RAISE EXCEPTION 'The service date must be in the academic year % (% to %).',
        c.yr, to_char(v_d1, 'DD-MM-YYYY'), to_char(v_d2, 'DD-MM-YYYY');
    END IF;
    FOR k, x IN SELECT * FROM (VALUES ('odometer_km', 'odometer reading'), ('amount', 'amount'),
                                      ('downtime_days', 'downtime'), ('next_due_km', 'next due km')) f(k, x) LOOP
      IF (v_eff->>k)::numeric < 0 THEN RAISE EXCEPTION 'The % cannot be negative.', x; END IF;
    END LOOP;
    IF (v_eff->>'next_due_date')::date < (v_eff->>'service_date')::date THEN
      RAISE EXCEPTION 'The next due date cannot be before the service date.';
    END IF;
    IF (v_eff->>'next_due_km')::numeric < (v_eff->>'odometer_km')::numeric THEN
      RAISE EXCEPTION 'The next due km cannot be less than the odometer reading.';
    END IF;
    IF v_id IS NULL THEN
      v_row := v_row || jsonb_build_object('acad_year_id', c.iyr);
    END IF;
  END IF;

  -- A fuel entry is in the session year's schema, so its fill date falls in
  -- that year. The amount is as on the bill; left empty, it is the quantity
  -- at the rate.
  IF p_entity = 'fuel_log' THEN
    SELECT iy.iyrstadate, iy.iyrenddate INTO v_d1, v_d2 FROM public.institutionyear iy WHERE iy.iyr_id = c.iyr;
    IF (v_eff->>'fill_date')::date NOT BETWEEN v_d1 AND v_d2 THEN
      RAISE EXCEPTION 'The fill date must be in the academic year % (% to %).',
        c.yr, to_char(v_d1, 'DD-MM-YYYY'), to_char(v_d2, 'DD-MM-YYYY');
    END IF;
    IF (v_eff->>'quantity')::numeric <= 0 THEN RAISE EXCEPTION 'The quantity must be more than zero.'; END IF;
    FOR k, x IN SELECT * FROM (VALUES ('rate', 'rate'), ('amount', 'amount'), ('odometer_km', 'odometer reading')) f(k, x) LOOP
      IF (v_eff->>k)::numeric < 0 THEN RAISE EXCEPTION 'The % cannot be negative.', x; END IF;
    END LOOP;
    IF v_eff->>'amount' IS NULL THEN
      IF v_eff->>'rate' IS NULL THEN RAISE EXCEPTION 'Enter the amount, or the rate to work it out.'; END IF;
      v_row := v_row || jsonb_build_object('amount', round((v_eff->>'quantity')::numeric * (v_eff->>'rate')::numeric, 2));
    END IF;
  END IF;

  IF v_id IS NULL THEN
    SELECT string_agg(format('%I', j), ', '), string_agg(format('r.%I', j), ', ')
      INTO v_list, v_sel FROM jsonb_object_keys(v_row) j;
    -- a stage fee has no inst_id: its route says the school
    EXECUTE format('INSERT INTO %1$I.%2$I (%6$s created_by, %3$s) SELECT %7$s $2, %4$s FROM jsonb_populate_record(NULL::%1$I.%2$I, $3) r RETURNING %5$I',
                   v_sch, e.tbl, v_list, v_sel, e.pk,
                   CASE WHEN p_entity = 'stage_fee' THEN '' ELSE 'inst_id,' END, CASE WHEN p_entity = 'stage_fee' THEN '' ELSE '$1,' END)
       INTO v_out USING c.ins, c.usr, v_row;
  ELSE
    SELECT string_agg(format('%1$I = r.%1$I', j), ', ') INTO v_set FROM jsonb_object_keys(v_row) j;
    IF v_set IS NULL THEN
      v_out := v_id;  -- no column changed (a schedule may still get new stops below)
    ELSE
      IF e.has_upd THEN v_set := v_set || ', updated_by = $2'; END IF;
      EXECUTE format('UPDATE %1$I.%2$I t SET %3$s FROM jsonb_populate_record(NULL::%1$I.%2$I, $3) r WHERE t.%4$I = $4 AND %5$s RETURNING t.%4$I',
                     v_sch, e.tbl, v_set, e.pk, transport_core._of_school(p_entity, '$1'))
         INTO v_out USING c.ins, c.usr, v_row, v_id;
    END IF;
  END IF;

  IF v_stops IS NOT NULL THEN
    EXECUTE format('INSERT INTO %I.tr_trip_schedule_stop (schedule_id, route_id, stop_id, visit_seq, planned_time, halt_minutes)
                    SELECT $1, $2, (s->>''stop_id'')::bigint, (s->>''visit_seq'')::smallint, (s->>''planned_time'')::time, (s->>''halt_minutes'')::smallint
                      FROM jsonb_array_elements($3) s', v_sch)
      USING v_out, (v_eff->>'route_id')::bigint, v_stops;
  END IF;
  RETURN v_out;
EXCEPTION
  WHEN unique_violation OR check_violation OR foreign_key_violation THEN
    GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
    RAISE EXCEPTION '%', transport_core._friendly(v_con, e.noun);
  WHEN not_null_violation THEN
    RAISE EXCEPTION 'Please fill in all the required fields.';
  WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_datetime_format
       OR datetime_field_overflow OR string_data_right_truncation THEN
    RAISE EXCEPTION 'One of the values is not valid or is too long. Please check and try again.';
END $$;

-- ---------------------------------------------------------------------
-- Delete. Masters are switched off so history keeps its links; documents
-- and fees are removed. Records still used in the session's year are
-- refused (older years keep their links through the foreign keys).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core.remove(p_token text, p_entity text, p_id bigint)
RETURNS text LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE e record; c record; v_sch text; v_y text; v_found boolean; n integer := 0; v_why text; v_senr boolean := false;
BEGIN
  SELECT * INTO e FROM transport_core._entity(p_entity);
  SELECT * INTO c FROM transport_core._ctx(p_token, e.menus);
  IF e.del = 'none' THEN
    RAISE EXCEPTION '%', CASE p_entity
      WHEN 'enrollment' THEN 'A student''s transport is kept as a record. To stop it, set the status to Cancelled.'
      WHEN 'staff_enrollment' THEN 'A staff member''s transport is kept as a record. To stop it, set the status to Cancelled.'
      WHEN 'allotment' THEN 'To take a student out of a vehicle, move them back to Not Allotted and save.'
      WHEN 'staff_allotment' THEN 'To take a staff member out of a vehicle, move them back to Not Allotted and save.'
      ELSE 'GPS device history is kept. To take a device off a vehicle, use GPS Mapping.' END;
  END IF;
  v_sch := COALESCE(e.sch, transport_core._year(c.ysch, c.yr));
  -- the session year's schema, if that year has been started
  v_y := CASE WHEN to_regnamespace(c.ysch) IS NOT NULL THEN c.ysch END;
  -- and its staff on the routes (transport_23), counted with the students
  IF v_y IS NOT NULL THEN
    v_senr := to_regclass(format('%I.tr_staff_enrollment', v_y)) IS NOT NULL;
  END IF;
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I t WHERE t.%I = $1 AND %s)', v_sch, e.tbl, e.pk, transport_core._of_school(p_entity, '$2'))
     INTO v_found USING p_id, c.ins;
  IF NOT v_found THEN RAISE EXCEPTION 'This % was not found. Refresh and try again.', e.noun; END IF;
  IF p_entity = 'vehicle_service'
     AND NOT EXISTS (SELECT 1 FROM public.tr_vehicle_service t WHERE t.service_id = p_id AND t.acad_year_id = c.iyr) THEN
    RAISE EXCEPTION 'This service record is of another academic year. Open that year to delete it.';
  END IF;

  IF p_entity = 'route' THEN
    IF v_y IS NOT NULL THEN
      EXECUTE format('SELECT (SELECT count(*) FROM %1$I.tr_trip_schedule s WHERE s.route_id = $1 AND s.is_active)
                           + (SELECT count(*) FROM %1$I.tr_student_enrollment x WHERE x.route_id = $1 AND x.status = ''ACTIVE'')', v_y)
         INTO n USING p_id;
    END IF;
    IF v_senr THEN
      EXECUTE format('SELECT $2 + (SELECT count(*) FROM %I.tr_staff_enrollment x WHERE x.route_id = $1 AND x.status = ''ACTIVE'')', v_y)
         INTO n USING p_id, n;
    END IF;
    v_why := 'schedule(s), student(s) or staff still use this route';
  ELSIF p_entity = 'stage' THEN
    SELECT count(*) INTO n FROM public.tr_stop s WHERE s.stage_id = p_id AND s.is_active;
    IF v_y IS NOT NULL THEN
      EXECUTE format('SELECT $2 + (SELECT count(*) FROM %I.tr_student_enrollment x WHERE x.fee_stage_id = $1 AND x.status = ''ACTIVE'')', v_y)
         INTO n USING p_id, n;
    END IF;
    IF v_senr THEN
      EXECUTE format('SELECT $2 + (SELECT count(*) FROM %I.tr_staff_enrollment x WHERE x.fee_stage_id = $1 AND x.status = ''ACTIVE'')', v_y)
         INTO n USING p_id, n;
    END IF;
    v_why := 'active stop(s), student(s) or staff still use this stage';
  ELSIF p_entity = 'stop' THEN
    IF v_y IS NOT NULL THEN
      EXECUTE format('SELECT (SELECT count(*) FROM %1$I.tr_student_enrollment x WHERE $1 IN (x.pickup_stop_id, x.drop_stop_id) AND x.status = ''ACTIVE'')
                           + (SELECT count(*) FROM %1$I.tr_trip_schedule_stop ss JOIN %1$I.tr_trip_schedule s ON s.schedule_id = ss.schedule_id
                               WHERE ss.stop_id = $1 AND s.is_active)', v_y)
         INTO n USING p_id;
    END IF;
    IF v_senr THEN
      EXECUTE format('SELECT $2 + (SELECT count(*) FROM %I.tr_staff_enrollment x WHERE $1 IN (x.pickup_stop_id, x.drop_stop_id) AND x.status = ''ACTIVE'')', v_y)
         INTO n USING p_id, n;
    END IF;
    v_why := 'student(s), staff or schedule(s) still use this stop';
  ELSIF p_entity = 'vendor' THEN
    SELECT (SELECT count(*) FROM public.tr_vehicle v WHERE v.vendor_id = p_id AND v.status = 'ACTIVE')
         + (SELECT count(*) FROM public.tr_staff f WHERE f.vendor_id = p_id AND f.status = 'ACTIVE') INTO n;
    v_why := 'active vehicle(s) or staff still belong to this vendor';
  ELSIF p_entity = 'vehicle' THEN
    IF v_y IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM %I.tr_trip_schedule s WHERE s.vehicle_id = $1 AND s.is_active', v_y)
         INTO n USING p_id;
    END IF;
    v_why := 'schedule(s) still use this vehicle';
  ELSIF p_entity = 'staff' THEN
    IF v_y IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM %I.tr_duty_assignment d
                       WHERE d.staff_id = $1 AND (d.effective_to IS NULL OR d.effective_to >= CURRENT_DATE)', v_y)
         INTO n USING p_id;
    END IF;
    v_why := 'duty assignment(s) are still open for this staff member';
  ELSIF p_entity = 'schedule' THEN
    EXECUTE format('SELECT count(*) FROM %I.tr_student_enrollment x
                     WHERE $1 IN (x.pickup_schedule_id, x.drop_schedule_id) AND x.status = ''ACTIVE''', v_sch)
       INTO n USING p_id;
    IF to_regclass(format('%I.tr_staff_enrollment', v_sch)) IS NOT NULL THEN
      EXECUTE format('SELECT $2 + (SELECT count(*) FROM %I.tr_staff_enrollment x
                       WHERE $1 IN (x.pickup_schedule_id, x.drop_schedule_id) AND x.status = ''ACTIVE'')', v_sch)
         INTO n USING p_id, n;
    END IF;
    v_why := 'student(s) or staff still use this schedule';
  ELSIF p_entity = 'stage_fee' THEN
    EXECUTE format('SELECT count(*) FROM %I.tr_stage_fee_demand d WHERE d.stage_fee_id = $1', v_sch) INTO n USING p_id;
    v_why := 'student fee demand(s) were made from this stage fee';
  END IF;
  IF n > 0 THEN RAISE EXCEPTION '% %.', n, v_why; END IF;

  IF e.del = 'active' THEN
    EXECUTE format('UPDATE %I.%I t SET is_active = false, updated_by = $3 WHERE t.%I = $1 AND %s',
                   v_sch, e.tbl, e.pk, transport_core._of_school(p_entity, '$2'))
      USING p_id, c.ins, c.usr;
    RETURN 'INACTIVE';
  ELSIF e.del LIKE 'status:%' THEN
    EXECUTE format('UPDATE %I.%I t SET status = %L, updated_by = $3 WHERE t.%I = $1 AND %s',
                   v_sch, e.tbl, split_part(e.del, ':', 2), e.pk, transport_core._of_school(p_entity, '$2'))
      USING p_id, c.ins, c.usr;
    RETURN split_part(e.del, ':', 2);
  END IF;
  EXECUTE format('DELETE FROM %I.%I t WHERE t.%I = $1 AND %s', v_sch, e.tbl, e.pk, transport_core._of_school(p_entity, '$2'))
     USING p_id, c.ins;
  RETURN 'DELETED';
EXCEPTION
  WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'This % is in use, so it cannot be deleted.', e.noun;
END $$;

-- ---------------------------------------------------------------------
-- Settings: one row per school (a master, in public)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core.settings_get(p_token text)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; v jsonb;
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Transport Setup']);
  INSERT INTO public.tr_settings (inst_id, created_by, updated_by) VALUES (c.ins, c.usr, c.usr) ON CONFLICT (inst_id) DO NOTHING;
  SELECT to_jsonb(s) INTO v FROM public.tr_settings s WHERE s.inst_id = c.ins;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION transport_core.settings_save(p_token text, p_row jsonb)
RETURNS void LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; r public.tr_settings; v_set text; k text;
  allowed text[] := ARRAY['eta_alert_minutes','default_geofence_m','school_geofence_m','overspeed_kmph','long_halt_minutes',
                          'gps_ping_interval_sec','auto_start_trip','doc_expiry_alert_days','school_latitude','school_longitude',
                          'sms_provider','sms_sender_id','whatsapp_enabled','push_enabled'];
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Transport Setup']);
  r := jsonb_populate_record(NULL::public.tr_settings, p_row);
  IF r.school_latitude NOT BETWEEN -90 AND 90 THEN RAISE EXCEPTION 'School latitude must be between -90 and 90.'; END IF;
  IF r.school_longitude NOT BETWEEN -180 AND 180 THEN RAISE EXCEPTION 'School longitude must be between -180 and 180.'; END IF;
  FOREACH k IN ARRAY ARRAY['eta_alert_minutes','default_geofence_m','school_geofence_m','overspeed_kmph','long_halt_minutes','gps_ping_interval_sec','doc_expiry_alert_days'] LOOP
    IF (p_row->>k)::numeric <= 0 THEN RAISE EXCEPTION 'Values must be more than zero.'; END IF;
  END LOOP;
  INSERT INTO public.tr_settings (inst_id, created_by, updated_by) VALUES (c.ins, c.usr, c.usr) ON CONFLICT (inst_id) DO NOTHING;
  SELECT string_agg(format('%1$I = x.%1$I', j), ', ') INTO v_set
    FROM jsonb_object_keys(p_row) j WHERE j = ANY (allowed);
  IF v_set IS NULL THEN RETURN; END IF;
  EXECUTE format('UPDATE public.tr_settings t SET %s, updated_by = $2 FROM jsonb_populate_record(NULL::public.tr_settings, $3) x WHERE t.inst_id = $1', v_set)
    USING c.ins, c.usr, p_row;
EXCEPTION
  WHEN not_null_violation THEN RAISE EXCEPTION 'Please fill in all the settings.';
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'One of the values is not valid. Please check and try again.';
END $$;

-- For the Stage Fees screen: the session's academic year, the school's
-- transport fee types (switched on, fee category TRA) and the year's terms
-- (the school app's semesters, switched on, in order, with their dates).
CREATE OR REPLACE FUNCTION transport_core.lookups(p_token text)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; v_app text; v_terms jsonb := '[]';
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token);
  SELECT iy.iyrschema INTO v_app FROM public.institutionyear iy WHERE iy.iyr_id = c.iyr;
  IF to_regclass(quote_ident(v_app) || '.semester') IS NOT NULL THEN
    EXECUTE format('SELECT COALESCE(jsonb_agg(jsonb_build_object(''sem_id'', s.sem_id, ''semname'', s.semname, ''semshort'', s.semshort,
                      ''semstart'', s.semstart, ''semend'', s.semend) ORDER BY s.ordid NULLS LAST, s.semstart NULLS LAST, s.sem_id), ''[]''::jsonb)
                      FROM %I.semester s WHERE s.ins_id = $1 AND s.activestatus = 1', v_app)
       INTO v_terms USING c.ins;
  END IF;
  RETURN jsonb_build_object(
    'year', c.yr,
    'feetypes', (SELECT COALESCE(jsonb_agg(jsonb_build_object('fee_id', f.fee_id, 'feedesc', f.feedesc, 'feeshort', f.feeshort) ORDER BY f.feedesc), '[]'::jsonb)
                   FROM public.feetype f WHERE f.ins_id = c.ins AND f.activestatus = 1 AND f.feecat = 'TRA'),
    'terms', v_terms);
END $$;

-- The school's active students of the session year, for the Student
-- Enrollment screen's Add Students window, in class order, each with the
-- route of its active enrollment (if any); and the academic year's first
-- and last day: {"year_from", "year_to", "students": [...]}.
CREATE OR REPLACE FUNCTION transport_core.students(p_token text)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; y record; v_sch text; v_out jsonb;
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Student Enrollment']);
  v_sch := transport_core._year(c.ysch, c.yr);
  SELECT * INTO y FROM transport_core._student_year(c.iyr);
  EXECUTE format('SELECT COALESCE(jsonb_agg(jsonb_build_object(''stu_id'', s.stu_id, ''stuadmno'', s.stuadmno, ''stuname'', s.stuname,
                    ''stuclass'', s.stuclass, ''cla_id'', s.cla_id, ''route_id'', e.route_id, ''route_code'', r.route_code)
                    ORDER BY cl.cour_id NULLS LAST, cl.ordid NULLS LAST, s.stuclass, s.stuname, s.stu_id), ''[]''::jsonb)
                    FROM %I.students s
                    LEFT JOIN public.class cl ON cl.cla_id = s.cla_id
                    LEFT JOIN %I.tr_student_enrollment e ON e.student_id = s.stu_id AND e.acad_year_id = $2 AND e.status = ''ACTIVE''
                    LEFT JOIN public.tr_route r ON r.route_id = e.route_id
                   WHERE s.ins_id = $1 AND s.activestatus = 1', y.sch, v_sch)
     INTO v_out USING c.ins, c.iyr;
  RETURN jsonb_build_object('year_from', y.from_date, 'year_to', y.to_date, 'students', v_out);
END $$;

-- The staff who may travel, for the Staff Enrollment tab's Add Staff
-- window: the school's staff of the session year (staffmast) who are active
-- (is_active) and whose transport is BUS (transportreq), by employee code,
-- each with the route of its active enrollment (if any); and the academic
-- year's first and last day: {"year_from", "year_to", "staff": [...]}.
CREATE OR REPLACE FUNCTION transport_core.enrollment_staff(p_token text)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; y record; v_sch text; v_out jsonb;
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Student Enrollment']);
  v_sch := transport_core._year(c.ysch, c.yr);
  SELECT * INTO y FROM transport_core._student_year(c.iyr);
  IF NOT transport_core._staff_ready(y.sch, v_sch) THEN
    RAISE EXCEPTION 'Staff transport has not been set up for the year %.', COALESCE(c.yr, '-');
  END IF;
  EXECUTE format('SELECT COALESCE(jsonb_agg(jsonb_build_object(''staf_id'', m.staf_id, ''emp_code'', m.emp_code, ''stafname'', m.stafname,
                    ''shortname'', m.shortname, ''designation'', m.designation, ''route_id'', e.route_id, ''route_code'', r.route_code)
                    ORDER BY upper(m.emp_code), upper(m.stafname), m.staf_id), ''[]''::jsonb)
                    FROM %I.staffmast m
                    JOIN public.schstaff s ON s.staf_id = m.staf_id AND s.ins_id = $1
                    LEFT JOIN %I.tr_staff_enrollment e ON e.staf_id = m.staf_id AND e.acad_year_id = $2 AND e.status = ''ACTIVE''
                    LEFT JOIN public.tr_route r ON r.route_id = e.route_id
                   WHERE m.is_active AND upper(btrim(m.transportreq)) = ''BUS''', y.sch, v_sch)
     INTO v_out USING c.ins, c.iyr;
  RETURN jsonb_build_object('year_from', y.from_date, 'year_to', y.to_date, 'staff', v_out);
END $$;

-- ---------------------------------------------------------------------
-- Daily Trips. Each evening pg_cron makes the next day's trips from the
-- trip schedules (generate_next_day_trips, transport_26); the Daily Trips
-- screen lists a day's trips, can make them for a day now (Make Trips), and
-- changes a trip's vehicle and crew for that day only (trip_save). India
-- time decides what "today" is.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core._today()
RETURNS date LANGUAGE sql STABLE AS $$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date $$;

-- The year schema of the school's academic year that holds p_date.
CREATE OR REPLACE FUNCTION transport_core._date_year(p_ins integer, p_date date)
RETURNS text LANGUAGE plpgsql STABLE
SET search_path TO 'pg_catalog', 'public' AS $$
DECLARE v_label text; v_sch text;
BEGIN
  SELECT iy.yrlabel INTO v_label FROM public.institutionyear iy
   WHERE iy.ins_id = p_ins AND iy.activestatus = 1
     AND p_date BETWEEN COALESCE(iy.iyrstadate, '-infinity'::date) AND COALESCE(iy.iyrenddate, 'infinity'::date)
   ORDER BY iy.yrlabel DESC LIMIT 1;
  v_sch := transport_core.year_schema(v_label);
  IF v_sch IS NULL OR to_regnamespace(v_sch) IS NULL THEN
    RAISE EXCEPTION 'No academic year with transport covers %.', to_char(p_date, 'DD-MM-YYYY');
  END IF;
  RETURN v_sch;
END $$;

-- The trips of a day, each with its schedule, route, vehicle and crew, and
-- how many students and staff it expects:
--   {"trip_date", "today", "trips": [{trip_id, direction, status,
--    planned_start_at, planned_end_at, updated_at, cancel_reason,
--    schedule_id, schedule_code, schedule_name, route_id, route_code,
--    route_name, vehicle_id, vehicle_code, registration_no, capacity,
--    crew: [{staff_id, full_name, staff_code, staff_type, duty_role,
--    is_substitute}], students, staff, editable, replaces_trip_id,
--    replaces_vehicle_code, replaced_by_trip_id, replaced_by_vehicle_code}, ...]}
-- editable: Scheduled, and today or later. replaces_*: a replacement trip's
-- cancelled trip (trip_replace); replaced_by_*: a cancelled trip's replacement.
CREATE OR REPLACE FUNCTION transport_core.daily_trips(p_token text, p_date date)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; v_sch text; v_out jsonb; v_today date := transport_core._today();
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Daily Trips']);
  IF p_date IS NULL THEN RAISE EXCEPTION 'Choose the day.'; END IF;
  v_sch := transport_core._date_year(c.ins, p_date);
  EXECUTE format($q$
    SELECT COALESCE(jsonb_agg(q.x ORDER BY q.st, q.code, q.id), '[]'::jsonb) FROM (
      SELECT t.planned_start_at AS st, s.schedule_code AS code, t.trip_id AS id, jsonb_build_object(
        'trip_id', t.trip_id, 'trip_date', t.trip_date, 'direction', t.direction, 'status', t.status,
        'planned_start_at', t.planned_start_at, 'planned_end_at', t.planned_end_at,
        'updated_at', t.updated_at, 'cancel_reason', t.cancel_reason,
        'schedule_id', t.schedule_id, 'schedule_code', s.schedule_code, 'schedule_name', s.schedule_name,
        'route_id', t.route_id, 'route_code', r.route_code, 'route_name', r.route_name,
        'vehicle_id', t.vehicle_id, 'vehicle_code', v.vehicle_code, 'registration_no', v.registration_no,
        'capacity', v.seating_capacity + COALESCE(v.additional_capacity, 0),
        'crew', COALESCE((SELECT jsonb_agg(jsonb_build_object('staff_id', f.staff_id, 'full_name', f.full_name,
                    'staff_code', f.staff_code, 'staff_type', f.staff_type, 'duty_role', ts.duty_role,
                    'is_substitute', ts.is_substitute)
                    ORDER BY CASE ts.duty_role WHEN 'DRIVER' THEN 1 WHEN 'CONDUCTOR' THEN 2 WHEN 'ATTENDER' THEN 3 ELSE 4 END, f.full_name)
                  FROM %1$I.tr_trip_staff ts JOIN public.tr_staff f ON f.staff_id = ts.staff_id
                 WHERE ts.trip_id = t.trip_id), '[]'::jsonb),
        'students', (SELECT count(*) FROM %1$I.tr_trip_student x WHERE x.trip_id = t.trip_id AND x.status = 'EXPECTED'),
        'staff', %2$s,
        'editable', t.status = 'SCHEDULED' AND t.trip_date >= $3,
        'replaces_trip_id', t.replaces_trip_id,
        'replaces_vehicle_code', (SELECT ov.vehicle_code FROM %1$I.tr_trip o JOIN public.tr_vehicle ov ON ov.vehicle_id = o.vehicle_id
                                   WHERE o.trip_id = t.replaces_trip_id),
        'replaced_by_trip_id', (SELECT n.trip_id FROM %1$I.tr_trip n WHERE n.replaces_trip_id = t.trip_id),
        'replaced_by_vehicle_code', (SELECT nv.vehicle_code FROM %1$I.tr_trip n JOIN public.tr_vehicle nv ON nv.vehicle_id = n.vehicle_id
                                      WHERE n.replaces_trip_id = t.trip_id)) AS x
        FROM %1$I.tr_trip t
        JOIN %1$I.tr_trip_schedule s ON s.schedule_id = t.schedule_id
        JOIN public.tr_route r ON r.route_id = t.route_id
        JOIN public.tr_vehicle v ON v.vehicle_id = t.vehicle_id
       WHERE t.inst_id = $1 AND t.trip_date = $2) q $q$,
    v_sch,
    CASE WHEN to_regclass(format('%I.tr_trip_staff_rider', v_sch)) IS NOT NULL
         THEN format('(SELECT count(*) FROM %I.tr_trip_staff_rider y WHERE y.trip_id = t.trip_id AND y.status = ''EXPECTED'')', v_sch)
         ELSE '0' END)
    INTO v_out USING c.ins, p_date, v_today;
  RETURN jsonb_build_object('trip_date', p_date, 'today', v_today, 'trips', v_out);
END $$;

-- Make Trips: a day's trips now (today or later), as the nightly run would.
-- Trips the day already has are left as they are. Returns how many were made.
CREATE OR REPLACE FUNCTION transport_core.trips_make(p_token text, p_date date)
RETURNS integer LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record;
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Daily Trips']);
  IF p_date IS NULL THEN RAISE EXCEPTION 'Choose the day.'; END IF;
  IF p_date < transport_core._today() THEN
    RAISE EXCEPTION 'Trips cannot be made for a past day (%).', to_char(p_date, 'DD-MM-YYYY');
  END IF;
  PERFORM transport_core._date_year(c.ins, p_date);  -- a year with transport holds the day
  RETURN transport_core.fn_generate_trips(c.ins, p_date);
END $$;

-- The Daily Trips screen's changes to one day's trips, saved together:
--   {"trip_date": "2026-11-25",
--    "trips": [{"trip_id": 7, "updated_at": "..." (as listed),
--               "vehicle_id": 3, "driver_id": 12, "attender_id": 15 (null: none),
--               "status": "CANCELLED", "cancel_reason": "..." (or "COMPLETED", or "SCHEDULED": restore)}, ...]}
-- A key left out is not changed. A cancelled trip needs its reason, and
-- changes only by being restored to Scheduled (today or later), unless
-- another trip replaced it (trip_replace). A Scheduled or running trip is
-- Completed on its day or after (a past day's too: only its status then);
-- the end is kept as the time it was marked (end_source ADMIN), unless the
-- GPS gave one. A completed trip changes only by being set back to Scheduled
-- (today), e.g. completed by mistake. Only a Scheduled trip of today or later can
-- change. The vehicle: the school's, in service, with seats for the students
-- and staff the trip expects. The driver: active, a Driver, licence valid on
-- the day; an attender: active. Neither on approved leave that day. The
-- trip's other crew (conductor, supervisor) stay. A crew member who is not
-- the schedule's duty for the day is marked a substitute. At the end no
-- changed trip may share its vehicle or a crew member with another trip at
-- the same time (so two trips can swap their vehicles in one save).
-- Returns the number of trips changed.
CREATE OR REPLACE FUNCTION transport_core.trip_save(p_token text, p_row jsonb)
RETURNS bigint LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE
  c record; x jsonb; t record; v_sch text; v_date date; v_today date := transport_core._today();
  v_vids bigint[] := '{}'; v_cids bigint[] := '{}'; v_done bigint[] := '{}';
  v_veh bigint; v_sid bigint; v_role text; v_key text; v_old bigint[]; v_changed boolean;
  v_name text; v_type text; v_status text; v_valid date; v_seats integer; v_riders bigint; v_a text; v_b text;
  v_rider_sql text; v_rc bigint; v_leave boolean; v_new text; v_reason text; v_count bigint := 0; v_by text;
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Daily Trips']);
  IF jsonb_typeof(p_row->'trips') IS DISTINCT FROM 'array' OR jsonb_array_length(p_row->'trips') = 0 THEN
    RAISE EXCEPTION 'Nothing to save.';
  END IF;
  v_date := NULLIF(p_row->>'trip_date', '')::date;
  IF v_date IS NULL THEN RAISE EXCEPTION 'Choose the day.'; END IF;
  v_sch := transport_core._date_year(c.ins, v_date);
  -- the riders a trip expects: its students, and its staff where the year has them
  v_rider_sql := format('SELECT (SELECT count(*) FROM %1$I.tr_trip_student x WHERE x.trip_id = $1 AND x.status = ''EXPECTED'')', v_sch)
              || CASE WHEN to_regclass(format('%I.tr_trip_staff_rider', v_sch)) IS NOT NULL
                      THEN format(' + (SELECT count(*) FROM %I.tr_trip_staff_rider y WHERE y.trip_id = $1 AND y.status = ''EXPECTED'')', v_sch)
                      ELSE '' END;

  FOR x IN SELECT r FROM jsonb_array_elements(p_row->'trips') r LOOP
    IF jsonb_typeof(x) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
    EXECUTE format('SELECT t.trip_id, t.trip_date, t.schedule_id, t.vehicle_id, t.status, t.updated_at,
                           t.planned_start_at, t.planned_end_at, s.schedule_code
                      FROM %1$I.tr_trip t JOIN %1$I.tr_trip_schedule s ON s.schedule_id = t.schedule_id
                     WHERE t.trip_id = $1 AND t.inst_id = $2 AND t.trip_date = $3 FOR UPDATE OF t', v_sch)
       INTO t USING NULLIF(x->>'trip_id', '')::bigint, c.ins, v_date;
    GET DIAGNOSTICS v_rc = ROW_COUNT;
    IF v_rc = 0 THEN RAISE EXCEPTION 'A trip was not found on %. Refresh and try again.', to_char(v_date, 'DD-MM-YYYY'); END IF;
    IF t.trip_id = ANY (v_done) THEN RAISE EXCEPTION 'Trip % is listed twice.', t.schedule_code; END IF;
    v_done := v_done || t.trip_id;
    IF x ? 'updated_at' AND (x->>'updated_at')::timestamptz IS DISTINCT FROM t.updated_at THEN
      RAISE EXCEPTION 'Trip % was changed by someone else. Refresh and try again.', t.schedule_code;
    END IF;
    v_new := NULLIF(btrim(x->>'status'), '');
    IF v_new IS NOT NULL AND v_new NOT IN ('SCHEDULED', 'CANCELLED', 'COMPLETED') THEN
      RAISE EXCEPTION 'Trip % can only be cancelled, completed, or set back to Scheduled.', t.schedule_code;
    END IF;
    IF t.status = 'CANCELLED' AND v_new IS DISTINCT FROM 'SCHEDULED' THEN
      RAISE EXCEPTION 'Trip % is cancelled, so it cannot be changed. Restore it first.', t.schedule_code;
    ELSIF t.status = 'COMPLETED' AND v_new IS DISTINCT FROM 'SCHEDULED' THEN
      RAISE EXCEPTION 'Trip % is completed, so it cannot be changed. Set it back to Scheduled first.', t.schedule_code;
    ELSIF t.status = 'IN_PROGRESS' AND (v_new IS DISTINCT FROM 'COMPLETED' OR x ?| ARRAY['vehicle_id', 'driver_id', 'attender_id']) THEN
      RAISE EXCEPTION 'Trip % is running, so it can only be completed.', t.schedule_code;
    ELSIF t.status NOT IN ('SCHEDULED', 'CANCELLED', 'COMPLETED', 'IN_PROGRESS') THEN
      RAISE EXCEPTION 'Trip % is %, so it cannot be changed.', t.schedule_code, lower(t.status);
    END IF;
    -- a past day's trip: only completed (its status alone)
    IF t.trip_date < v_today AND NOT (v_new = 'COMPLETED' AND NOT x ?| ARRAY['vehicle_id', 'driver_id', 'attender_id']) THEN
      RAISE EXCEPTION 'Trip % is of a past day, so it cannot be changed.', t.schedule_code;
    END IF;
    IF v_new = 'COMPLETED' AND t.trip_date > v_today THEN
      RAISE EXCEPTION 'Trip % is on %, so it can be completed on that day or after.', t.schedule_code, to_char(t.trip_date, 'DD-MM-YYYY');
    END IF;
    v_changed := false;

    -- a completed trip set back to Scheduled (e.g. completed by mistake): checked like a changed one
    IF t.status = 'COMPLETED' THEN
      EXECUTE format('UPDATE %I.tr_trip SET status = ''SCHEDULED'',
                        actual_end_at = CASE WHEN end_source = ''ADMIN'' THEN NULL ELSE actual_end_at END,
                        end_source = CASE WHEN end_source = ''ADMIN'' THEN NULL ELSE end_source END
                      WHERE trip_id = $1', v_sch) USING t.trip_id;
      v_vids := v_vids || t.trip_id;
      v_cids := v_cids || t.trip_id;
      v_changed := true;
    END IF;

    -- a cancelled trip restored: Scheduled again, and checked like a changed one
    IF t.status = 'CANCELLED' THEN
      v_by := NULL;
      EXECUTE format('SELECT v.vehicle_code FROM %I.tr_trip n JOIN public.tr_vehicle v ON v.vehicle_id = n.vehicle_id
                       WHERE n.replaces_trip_id = $1', v_sch) INTO v_by USING t.trip_id;
      IF v_by IS NOT NULL THEN
        RAISE EXCEPTION 'Trip % was replaced (% runs it), so it cannot be restored.', t.schedule_code, v_by;
      END IF;
      EXECUTE format('UPDATE %I.tr_trip SET status = ''SCHEDULED'', cancel_reason = NULL WHERE trip_id = $1', v_sch) USING t.trip_id;
      v_vids := v_vids || t.trip_id;
      v_cids := v_cids || t.trip_id;
      v_changed := true;
    END IF;

    -- the vehicle
    IF x ? 'vehicle_id' AND NULLIF(x->>'vehicle_id', '')::bigint IS DISTINCT FROM t.vehicle_id THEN
      v_veh := NULLIF(x->>'vehicle_id', '')::bigint;
      IF v_veh IS NULL THEN RAISE EXCEPTION 'Choose the vehicle of trip %.', t.schedule_code; END IF;
      v_name := NULL;
      SELECT v.vehicle_code, v.status, v.seating_capacity + COALESCE(v.additional_capacity, 0)
        INTO v_name, v_status, v_seats
        FROM public.tr_vehicle v WHERE v.vehicle_id = v_veh AND v.inst_id = c.ins;
      IF v_name IS NULL THEN RAISE EXCEPTION 'The vehicle chosen for trip % was not found.', t.schedule_code; END IF;
      IF v_status IS DISTINCT FROM 'ACTIVE' THEN
        RAISE EXCEPTION '% is %, so it cannot run trip %.', v_name, lower(replace(v_status, '_', ' ')), t.schedule_code;
      END IF;
      EXECUTE v_rider_sql INTO v_riders USING t.trip_id;
      IF v_riders > v_seats THEN
        RAISE EXCEPTION '% takes %, but trip % expects % riders.', v_name,
          CASE WHEN v_seats = 1 THEN '1 rider' ELSE v_seats || ' riders' END, t.schedule_code, v_riders;
      END IF;
      EXECUTE format('UPDATE %I.tr_trip SET vehicle_id = $2 WHERE trip_id = $1', v_sch) USING t.trip_id, v_veh;
      v_vids := v_vids || t.trip_id;
      v_changed := true;
    END IF;

    -- the driver and the attender
    FOREACH v_role IN ARRAY ARRAY['DRIVER', 'ATTENDER'] LOOP
      v_key := lower(v_role) || '_id';
      CONTINUE WHEN NOT x ? v_key;
      v_sid := NULLIF(x->>v_key, '')::bigint;
      EXECUTE format('SELECT COALESCE(array_agg(staff_id ORDER BY staff_id), ''{}'') FROM %I.tr_trip_staff WHERE trip_id = $1 AND duty_role = $2', v_sch)
         INTO v_old USING t.trip_id, v_role;
      CONTINUE WHEN v_old = CASE WHEN v_sid IS NULL THEN '{}'::bigint[] ELSE ARRAY[v_sid] END;  -- unchanged
      IF v_role = 'DRIVER' AND v_sid IS NULL THEN RAISE EXCEPTION 'Choose the driver of trip %.', t.schedule_code; END IF;
      IF v_sid IS NOT NULL THEN
        v_name := NULL;
        SELECT f.full_name, f.staff_type, f.status, f.license_valid_till INTO v_name, v_type, v_status, v_valid
          FROM public.tr_staff f WHERE f.staff_id = v_sid AND f.inst_id = c.ins;
        IF v_name IS NULL THEN RAISE EXCEPTION 'The staff member chosen for trip % was not found.', t.schedule_code; END IF;
        IF v_status IS DISTINCT FROM 'ACTIVE' THEN
          RAISE EXCEPTION '% is %, so cannot crew trip %.', v_name, lower(replace(v_status, '_', ' ')), t.schedule_code;
        END IF;
        IF v_role = 'DRIVER' AND v_type IS DISTINCT FROM 'DRIVER' THEN
          RAISE EXCEPTION '% is not a driver. Only Driver staff can drive trip %.', v_name, t.schedule_code;
        END IF;
        IF v_role = 'DRIVER' AND v_valid IS NOT NULL AND v_valid < t.trip_date THEN
          RAISE EXCEPTION 'The driving licence of % expired on %.', v_name, to_char(v_valid, 'DD-MM-YYYY');
        END IF;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.tr_staff_leave l WHERE l.staff_id = $1 AND l.status = ''APPROVED''
                                        AND $2 BETWEEN l.from_date AND l.to_date)', v_sch)
           INTO v_leave USING v_sid, t.trip_date;
        IF v_leave THEN RAISE EXCEPTION '% is on leave on %.', v_name, to_char(t.trip_date, 'DD-MM-YYYY'); END IF;
      END IF;
      -- this role's crew is replaced; the new one leaves any other role on this trip
      EXECUTE format('DELETE FROM %I.tr_trip_staff WHERE trip_id = $1 AND (duty_role = $2 OR staff_id = $3)', v_sch)
        USING t.trip_id, v_role, v_sid;
      IF v_sid IS NOT NULL THEN
        EXECUTE format('INSERT INTO %1$I.tr_trip_staff (trip_id, staff_id, duty_role, is_substitute)
                        SELECT $1, $2, $3, NOT EXISTS (SELECT 1 FROM %1$I.tr_duty_assignment d
                                                        WHERE d.schedule_id = $4 AND d.staff_id = $2 AND d.duty_role = $3
                                                          AND $5 >= d.effective_from AND (d.effective_to IS NULL OR $5 <= d.effective_to))', v_sch)
          USING t.trip_id, v_sid, v_role, t.schedule_id, t.trip_date;
      END IF;
      v_cids := v_cids || t.trip_id;
      v_changed := true;
    END LOOP;

    -- cancelled, with the reason
    IF v_new = 'CANCELLED' THEN
      v_reason := NULLIF(btrim(x->>'cancel_reason'), '');
      IF v_reason IS NULL THEN RAISE EXCEPTION 'Give the reason for cancelling trip %.', t.schedule_code; END IF;
      EXECUTE format('UPDATE %I.tr_trip SET status = ''CANCELLED'', cancel_reason = $2 WHERE trip_id = $1', v_sch)
        USING t.trip_id, left(v_reason, 500);
      v_changed := true;
    END IF;

    -- completed: ended when marked, unless the GPS gave the end
    IF v_new = 'COMPLETED' THEN
      EXECUTE format('UPDATE %I.tr_trip SET status = ''COMPLETED'', actual_end_at = COALESCE(actual_end_at, now()),
                        end_source = COALESCE(end_source, ''ADMIN'') WHERE trip_id = $1', v_sch) USING t.trip_id;
      v_changed := true;
    END IF;

    IF v_changed THEN
      EXECUTE format('UPDATE %I.tr_trip SET updated_by = $2, updated_at = now() WHERE trip_id = $1', v_sch) USING t.trip_id, c.usr;
      v_count := v_count + 1;
    END IF;
  END LOOP;

  -- no vehicle and no crew member on two trips at the same time
  v_name := NULL;
  EXECUTE format('SELECT v.vehicle_code, sa.schedule_code, sb.schedule_code
                    FROM %1$I.tr_trip a
                    JOIN %1$I.tr_trip b ON b.inst_id = a.inst_id AND b.trip_date = a.trip_date AND b.trip_id <> a.trip_id
                                       AND b.vehicle_id = a.vehicle_id AND b.status <> ''CANCELLED''
                                       AND b.planned_start_at < a.planned_end_at AND a.planned_start_at < b.planned_end_at
                    JOIN %1$I.tr_trip_schedule sa ON sa.schedule_id = a.schedule_id
                    JOIN %1$I.tr_trip_schedule sb ON sb.schedule_id = b.schedule_id
                    JOIN public.tr_vehicle v ON v.vehicle_id = a.vehicle_id
                   WHERE a.trip_id = ANY ($1) AND a.status <> ''CANCELLED'' ORDER BY sa.schedule_code, sb.schedule_code LIMIT 1', v_sch)
     INTO v_name, v_a, v_b USING v_vids;
  IF v_name IS NOT NULL THEN RAISE EXCEPTION '% would run trips % and % at the same time.', v_name, v_a, v_b; END IF;
  EXECUTE format('SELECT f.full_name, sa.schedule_code, sb.schedule_code
                    FROM %1$I.tr_trip a
                    JOIN %1$I.tr_trip_staff ca ON ca.trip_id = a.trip_id
                    JOIN %1$I.tr_trip_staff cb ON cb.staff_id = ca.staff_id AND cb.trip_id <> a.trip_id
                    JOIN %1$I.tr_trip b ON b.trip_id = cb.trip_id AND b.trip_date = a.trip_date AND b.status <> ''CANCELLED''
                                       AND b.planned_start_at < a.planned_end_at AND a.planned_start_at < b.planned_end_at
                    JOIN %1$I.tr_trip_schedule sa ON sa.schedule_id = a.schedule_id
                    JOIN %1$I.tr_trip_schedule sb ON sb.schedule_id = b.schedule_id
                    JOIN public.tr_staff f ON f.staff_id = ca.staff_id
                   WHERE a.trip_id = ANY ($1) AND a.status <> ''CANCELLED'' ORDER BY sa.schedule_code, sb.schedule_code LIMIT 1', v_sch)
     INTO v_name, v_a, v_b USING v_cids;
  IF v_name IS NOT NULL THEN RAISE EXCEPTION '% would crew trips % and % at the same time.', v_name, v_a, v_b; END IF;
  RETURN v_count;
END $$;

-- Replace Trip: a cancelled trip of today or later (e.g. its bus broke
-- down) run by another vehicle:
--   {"trip_date", "trip_id" (the cancelled trip), "updated_at" (as listed),
--    "vehicle_id", "driver_id", "attender_id" (null or left out: none)}
-- The new trip is the same schedule's, at the same times, with the same
-- stops, the cancelled trip's students and staff (with the boarding marked
-- so far) and its other crew (conductor, supervisor), and replaces_trip_id
-- the cancelled trip (transport_28). Its vehicle, driver and attender are then
-- set and checked as the Daily Trips changes are (trip_save): in service,
-- seats, licence, leave, and not on another trip at the same time. A trip is
-- replaced once; to run it with its own vehicle, restore it instead.
-- Returns the new trip's id.
CREATE OR REPLACE FUNCTION transport_core.trip_replace(p_token text, p_row jsonb)
RETURNS bigint LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; t record; v_sch text; v_date date; v_rc bigint; v_new bigint; v_veh bigint; v_by text; v_name text;
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Daily Trips']);
  v_date := NULLIF(p_row->>'trip_date', '')::date;
  IF v_date IS NULL OR NULLIF(p_row->>'trip_id', '') IS NULL THEN RAISE EXCEPTION 'Choose the trip to replace.'; END IF;
  v_sch := transport_core._date_year(c.ins, v_date);
  EXECUTE format('SELECT t.trip_id, t.trip_date, t.status, t.vehicle_id, t.updated_at, s.schedule_code
                    FROM %1$I.tr_trip t JOIN %1$I.tr_trip_schedule s ON s.schedule_id = t.schedule_id
                   WHERE t.trip_id = $1 AND t.inst_id = $2 AND t.trip_date = $3 FOR UPDATE OF t', v_sch)
     INTO t USING NULLIF(p_row->>'trip_id', '')::bigint, c.ins, v_date;
  GET DIAGNOSTICS v_rc = ROW_COUNT;
  IF v_rc = 0 THEN RAISE EXCEPTION 'The trip was not found on %. Refresh and try again.', to_char(v_date, 'DD-MM-YYYY'); END IF;
  IF p_row ? 'updated_at' AND (p_row->>'updated_at')::timestamptz IS DISTINCT FROM t.updated_at THEN
    RAISE EXCEPTION 'Trip % was changed by someone else. Refresh and try again.', t.schedule_code;
  END IF;
  IF t.status IS DISTINCT FROM 'CANCELLED' THEN
    RAISE EXCEPTION 'Only a cancelled trip can be replaced. Cancel trip % first, with its reason.', t.schedule_code;
  END IF;
  IF t.trip_date < transport_core._today() THEN
    RAISE EXCEPTION 'Trip % is of a past day, so it cannot be replaced.', t.schedule_code;
  END IF;
  EXECUTE format('SELECT v.vehicle_code FROM %I.tr_trip n JOIN public.tr_vehicle v ON v.vehicle_id = n.vehicle_id
                   WHERE n.replaces_trip_id = $1', v_sch) INTO v_by USING t.trip_id;
  IF v_by IS NOT NULL THEN RAISE EXCEPTION 'Trip % was already replaced: % runs it.', t.schedule_code, v_by; END IF;
  v_veh := NULLIF(p_row->>'vehicle_id', '')::bigint;
  IF v_veh IS NULL THEN RAISE EXCEPTION 'Choose the vehicle that runs trip % instead.', t.schedule_code; END IF;
  IF v_veh = t.vehicle_id THEN
    SELECT v.vehicle_code INTO v_name FROM public.tr_vehicle v WHERE v.vehicle_id = v_veh;
    RAISE EXCEPTION '% is the cancelled trip''s own vehicle. Choose another, or restore trip % to run it with %.', v_name, t.schedule_code, v_name;
  END IF;
  IF NULLIF(p_row->>'driver_id', '') IS NULL THEN RAISE EXCEPTION 'Choose the driver of trip %.', t.schedule_code; END IF;

  -- the new trip, as the cancelled one; its vehicle is set below
  EXECUTE format('INSERT INTO %1$I.tr_trip (inst_id, schedule_id, route_id, trip_date, direction, vehicle_id,
                    planned_start_at, planned_end_at, planned_students, boarded_students, replaces_trip_id, created_by, updated_by)
                  SELECT o.inst_id, o.schedule_id, o.route_id, o.trip_date, o.direction, o.vehicle_id,
                         o.planned_start_at, o.planned_end_at, o.planned_students, o.boarded_students, o.trip_id, $2, $2
                    FROM %1$I.tr_trip o WHERE o.trip_id = $1
                  RETURNING trip_id', v_sch) INTO v_new USING t.trip_id, c.usr;
  EXECUTE format('INSERT INTO %1$I.tr_trip_stop (trip_id, stop_id, visit_seq, planned_at, expected_students, boarded_count, alighted_count)
                  SELECT $2, stop_id, visit_seq, planned_at, expected_students, boarded_count, alighted_count
                    FROM %1$I.tr_trip_stop WHERE trip_id = $1', v_sch) USING t.trip_id, v_new;
  -- the riders, with what was marked so far
  EXECUTE format('INSERT INTO %1$I.tr_trip_student (trip_id, enrollment_id, student_id, stop_id, status, boarded_at, alighted_at, marked_by, mark_method, is_extra)
                  SELECT $2, enrollment_id, student_id, stop_id, status, boarded_at, alighted_at, marked_by, mark_method, is_extra
                    FROM %1$I.tr_trip_student WHERE trip_id = $1', v_sch) USING t.trip_id, v_new;
  IF to_regclass(format('%I.tr_trip_staff_rider', v_sch)) IS NOT NULL THEN
    EXECUTE format('INSERT INTO %1$I.tr_trip_staff_rider (trip_id, enrollment_id, staf_id, stop_id, status, boarded_at, alighted_at, marked_by, mark_method, is_extra)
                    SELECT $2, enrollment_id, staf_id, stop_id, status, boarded_at, alighted_at, marked_by, mark_method, is_extra
                      FROM %1$I.tr_trip_staff_rider WHERE trip_id = $1', v_sch) USING t.trip_id, v_new;
  END IF;
  -- the other crew go along; the driver and the attender are the ones chosen
  EXECUTE format('INSERT INTO %1$I.tr_trip_staff (trip_id, staff_id, duty_role, is_substitute)
                  SELECT $2, staff_id, duty_role, is_substitute FROM %1$I.tr_trip_staff
                   WHERE trip_id = $1 AND duty_role NOT IN (''DRIVER'', ''ATTENDER'')', v_sch) USING t.trip_id, v_new;

  -- the vehicle (never the cancelled trip's, so always checked), driver and attender
  PERFORM transport_core.trip_save(p_token, jsonb_build_object('trip_date', v_date, 'trips', jsonb_build_array(
    jsonb_build_object('trip_id', v_new, 'vehicle_id', v_veh, 'driver_id', p_row->'driver_id')
    || CASE WHEN NULLIF(p_row->>'attender_id', '') IS NOT NULL THEN jsonb_build_object('attender_id', p_row->'attender_id') ELSE '{}'::jsonb END)));
  RETURN v_new;
END $$;

-- A trip's riders, for the Daily Trips screen's boarding entry: its
-- students and staff with their stop and boarding status:
--   {"trip_id", "can_mark", "students": [{enrollment_id, student_id, stuadmno,
--    stuname, stuclass, stop_id, stop_name, stop_seq, status, boarded_at,
--    mark_method, is_extra}], "staff": [{enrollment_id, staf_id, emp_code, stafname,
--    designation, stop_id, stop_name, stop_seq, status, boarded_at, mark_method,
--    is_extra}], "direction"}
-- is_extra: added to the trip in its Riders window (trip_board_save).
-- In the order the bus reaches them: a drop by the stops' order, a pickup the
-- other way round (the far stop first). mark_method empty with a status other
-- than EXPECTED: the parents told it beforehand (a day exception).
-- can_mark: the trip is of today or a past day, and not cancelled.
CREATE OR REPLACE FUNCTION transport_core.trip_riders(p_token text, p_date date, p_trip_id bigint)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; v_sch text; y record; v_status text; v_date date; v_dir text; v_stu jsonb; v_staff jsonb := '[]';
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Daily Trips']);
  IF p_date IS NULL THEN RAISE EXCEPTION 'Choose the day.'; END IF;
  v_sch := transport_core._date_year(c.ins, p_date);
  EXECUTE format('SELECT t.status, t.trip_date, t.direction FROM %I.tr_trip t WHERE t.trip_id = $1 AND t.inst_id = $2 AND t.trip_date = $3', v_sch)
     INTO v_status, v_date, v_dir USING p_trip_id, c.ins, p_date;
  IF v_status IS NULL THEN RAISE EXCEPTION 'The trip was not found on %. Refresh and try again.', to_char(p_date, 'DD-MM-YYYY'); END IF;
  SELECT iy.iyrschema AS sch INTO y FROM public.institutionyear iy
   WHERE iy.ins_id = c.ins AND transport_core.year_schema(iy.yrlabel) = v_sch ORDER BY iy.yrlabel DESC LIMIT 1;
  EXECUTE format($q$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('enrollment_id', x.enrollment_id, 'student_id', x.student_id,
             'stuadmno', s.stuadmno, 'stuname', s.stuname, 'stuclass', s.stuclass,
             'stop_id', x.stop_id, 'stop_name', p.stop_name, 'stop_seq', p.stop_seq,
             'status', x.status, 'boarded_at', x.boarded_at, 'mark_method', x.mark_method, 'is_extra', x.is_extra)
             ORDER BY CASE WHEN $2 = 'PICKUP' THEN -p.stop_seq ELSE p.stop_seq END NULLS LAST, s.stuname, x.enrollment_id), '[]'::jsonb)
      FROM %1$I.tr_trip_student x
      LEFT JOIN %2$I.students s ON s.stu_id = x.student_id
      LEFT JOIN public.tr_stop p ON p.stop_id = x.stop_id
     WHERE x.trip_id = $1 $q$, v_sch, y.sch)
    INTO v_stu USING p_trip_id, v_dir;
  IF to_regclass(format('%I.tr_trip_staff_rider', v_sch)) IS NOT NULL AND to_regclass(format('%I.staffmast', y.sch)) IS NOT NULL THEN
    EXECUTE format($q$
      SELECT COALESCE(jsonb_agg(jsonb_build_object('enrollment_id', x.enrollment_id, 'staf_id', x.staf_id,
               'emp_code', m.emp_code, 'stafname', m.stafname, 'designation', m.designation,
               'stop_id', x.stop_id, 'stop_name', p.stop_name, 'stop_seq', p.stop_seq,
               'status', x.status, 'boarded_at', x.boarded_at, 'mark_method', x.mark_method, 'is_extra', x.is_extra)
               ORDER BY CASE WHEN $2 = 'PICKUP' THEN -p.stop_seq ELSE p.stop_seq END NULLS LAST, m.stafname, x.enrollment_id), '[]'::jsonb)
        FROM %1$I.tr_trip_staff_rider x
        LEFT JOIN %2$I.staffmast m ON m.staf_id = x.staf_id
        LEFT JOIN public.tr_stop p ON p.stop_id = x.stop_id
       WHERE x.trip_id = $1 $q$, v_sch, y.sch)
      INTO v_staff USING p_trip_id, v_dir;
  END IF;
  RETURN jsonb_build_object('trip_id', p_trip_id, 'direction', v_dir,
    'can_mark', v_status <> 'CANCELLED' AND v_date <= transport_core._today(),
    'students', v_stu, 'staff', v_staff);
END $$;

-- For a trip's Riders window, Add Student / Add Staff: the riders of the
-- trip's route travelling that way on the day who are not on this trip --
-- on another vehicle's trip (e.g. they missed it), or allotted to no vehicle
-- -- each with the trip they are on and how they are marked there:
--   {"students": [{enrollment_id, student_id, stuadmno, stuname, stuclass,
--     stop_name, stop_seq, on_trip_id, on_trip_code, on_vehicle_code,
--     on_trip_status, on_status, present}],
--    "staff": [{enrollment_id, staf_id, emp_code, stafname, designation,
--     stop_name, stop_seq, on_trip_id, ...the same}]}
-- present: already boarded (or dropped) on another trip that way that day,
-- so they cannot be added (trip_board_save refuses it too).
CREATE OR REPLACE FUNCTION transport_core.trip_rider_options(p_token text, p_date date, p_trip_id bigint)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; v_sch text; v_app text; v_route bigint; v_dir text; v_rc bigint; v_stu jsonb; v_staff jsonb := '[]';
  v_from text := $f$
    LEFT JOIN LATERAL (
      SELECT o.trip_id, sc.schedule_code AS code, v.vehicle_code AS vcode, t2.status AS tstatus, o.status
        FROM %1$I.%3$I o JOIN %1$I.tr_trip t2 ON t2.trip_id = o.trip_id
        JOIN %1$I.tr_trip_schedule sc ON sc.schedule_id = t2.schedule_id
        JOIN public.tr_vehicle v ON v.vehicle_id = t2.vehicle_id
       WHERE o.enrollment_id = e.enrollment_id AND o.trip_id <> $1 AND t2.trip_date = $3 AND t2.direction = $4
       ORDER BY (t2.status <> 'CANCELLED' AND o.status IN ('BOARDED', 'ALIGHTED')) DESC, (t2.status = 'CANCELLED'), t2.trip_id
       LIMIT 1) w ON true
    LEFT JOIN public.tr_stop p ON p.stop_id = CASE WHEN $4 = 'PICKUP' THEN e.pickup_stop_id ELSE e.drop_stop_id END
   WHERE e.route_id = $2 AND e.status = 'ACTIVE'
     AND $3 >= e.start_date AND (e.end_date IS NULL OR $3 <= e.end_date) AND e.service_type IN ('BOTH', $4)
     AND NOT EXISTS (SELECT 1 FROM %1$I.%3$I h WHERE h.trip_id = $1 AND h.enrollment_id = e.enrollment_id) $f$;
  v_on text := $o$'on_trip_id', w.trip_id, 'on_trip_code', w.code, 'on_vehicle_code', w.vcode, 'on_trip_status', w.tstatus,
                 'on_status', w.status, 'present', COALESCE(w.tstatus <> 'CANCELLED' AND w.status IN ('BOARDED', 'ALIGHTED'), false)$o$;
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Daily Trips']);
  IF p_date IS NULL THEN RAISE EXCEPTION 'Choose the day.'; END IF;
  v_sch := transport_core._date_year(c.ins, p_date);
  EXECUTE format('SELECT t.route_id, t.direction FROM %I.tr_trip t WHERE t.trip_id = $1 AND t.inst_id = $2 AND t.trip_date = $3', v_sch)
     INTO v_route, v_dir USING p_trip_id, c.ins, p_date;
  GET DIAGNOSTICS v_rc = ROW_COUNT;
  IF v_rc = 0 THEN RAISE EXCEPTION 'The trip was not found on %. Refresh and try again.', to_char(p_date, 'DD-MM-YYYY'); END IF;
  SELECT iy.iyrschema INTO v_app FROM public.institutionyear iy
   WHERE iy.ins_id = c.ins AND transport_core.year_schema(iy.yrlabel) = v_sch ORDER BY iy.yrlabel DESC LIMIT 1;
  EXECUTE format('SELECT COALESCE(jsonb_agg(jsonb_build_object(''enrollment_id'', e.enrollment_id, ''student_id'', e.student_id,
                    ''stuadmno'', s.stuadmno, ''stuname'', s.stuname, ''stuclass'', s.stuclass,
                    ''stop_name'', p.stop_name, ''stop_seq'', p.stop_seq, ' || v_on || ')
                    ORDER BY CASE WHEN $4 = ''PICKUP'' THEN -p.stop_seq ELSE p.stop_seq END NULLS LAST, s.stuname), ''[]''::jsonb)
                    FROM %1$I.tr_student_enrollment e LEFT JOIN %2$I.students s ON s.stu_id = e.student_id ' || v_from,
                 v_sch, v_app, 'tr_trip_student')
     INTO v_stu USING p_trip_id, v_route, p_date, v_dir;
  IF to_regclass(format('%I.tr_trip_staff_rider', v_sch)) IS NOT NULL AND to_regclass(format('%I.staffmast', v_app)) IS NOT NULL THEN
    EXECUTE format('SELECT COALESCE(jsonb_agg(jsonb_build_object(''enrollment_id'', e.enrollment_id, ''staf_id'', e.staf_id,
                      ''emp_code'', m.emp_code, ''stafname'', m.stafname, ''designation'', m.designation,
                      ''stop_name'', p.stop_name, ''stop_seq'', p.stop_seq, ' || v_on || ')
                      ORDER BY CASE WHEN $4 = ''PICKUP'' THEN -p.stop_seq ELSE p.stop_seq END NULLS LAST, m.stafname), ''[]''::jsonb)
                      FROM %1$I.tr_staff_enrollment e LEFT JOIN %2$I.staffmast m ON m.staf_id = e.staf_id ' || v_from,
                   v_sch, v_app, 'tr_trip_staff_rider')
       INTO v_staff USING p_trip_id, v_route, p_date, v_dir;
  END IF;
  RETURN jsonb_build_object('students', v_stu, 'staff', v_staff);
END $$;

-- Boarding entry for one trip, saved together:
--   {"trip_date": "2026-11-25", "trip_id": 7,
--    "students": [{"enrollment_id": 9, "status": "PRESENT"}, ...],
--    "staff":    [{"enrollment_id": 4, "status": "ABSENT"}, ...]}
-- status: PRESENT, kept as BOARDED on a pickup and as ALIGHTED on a drop
-- (BOARDED or ALIGHTED sent are taken the same way), ABSENT, PARENT_PICKUP
-- (students only), or EXPECTED (not marked yet). A rider is present on one
-- trip each way a day: present here is refused when already present on
-- another trip that way that day (a cancelled trip does not count).
-- A row with "add": true adds a rider of the trip's route travelling that way
-- on the day who is not on the trip (Add Student / Add Staff, e.g. one who
-- missed their own vehicle; trip_rider_options lists them): at their stop,
-- kept on the trip whatever the allotment (is_extra, transport_29), and on
-- their own trip that way that day, if not marked there yet, marked absent.
-- The vehicle must then still have the seats. "status": "REMOVE" takes an
-- added rider off again. Only on the day of the trip or after, and not for a
-- cancelled trip. Who marked it and when are kept (MANUAL). The trip's
-- boarded students, and each stop's, are counted again. Returns how many
-- riders were saved.
CREATE OR REPLACE FUNCTION transport_core.trip_board_save(p_token text, p_row jsonb)
RETURNS bigint LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; v_sch text; v_date date; v_trip bigint; v_status text; v_code text; x jsonb; v_st text; v_n bigint := 0; v_rc bigint;
  v_kind text; v_tbl text; v_dir text; v_route bigint; v_veh bigint; v_app text; v_eid bigint; v_add boolean; v_added integer := 0;
  v_stop bigint; v_pid numeric; v_who text; v_other text; v_vname text; v_seats integer; v_riders bigint;
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Daily Trips']);
  v_date := NULLIF(p_row->>'trip_date', '')::date;
  v_trip := NULLIF(p_row->>'trip_id', '')::bigint;
  IF v_date IS NULL OR v_trip IS NULL THEN RAISE EXCEPTION 'Choose the trip.'; END IF;
  v_sch := transport_core._date_year(c.ins, v_date);
  EXECUTE format('SELECT t.status, s.schedule_code, t.direction, t.route_id, t.vehicle_id
                    FROM %1$I.tr_trip t JOIN %1$I.tr_trip_schedule s ON s.schedule_id = t.schedule_id
                   WHERE t.trip_id = $1 AND t.inst_id = $2 AND t.trip_date = $3 FOR UPDATE OF t', v_sch)
     INTO v_status, v_code, v_dir, v_route, v_veh USING v_trip, c.ins, v_date;
  IF v_status IS NULL THEN RAISE EXCEPTION 'The trip was not found on %. Refresh and try again.', to_char(v_date, 'DD-MM-YYYY'); END IF;
  IF v_status = 'CANCELLED' THEN RAISE EXCEPTION 'Trip % is cancelled, so no boarding can be entered.', v_code; END IF;
  IF v_date > transport_core._today() THEN
    RAISE EXCEPTION 'Boarding for trip % can be entered from its day, %.', v_code, to_char(v_date, 'DD-MM-YYYY');
  END IF;
  -- the school app's year, for the riders' names in the messages
  SELECT iy.iyrschema INTO v_app FROM public.institutionyear iy
   WHERE iy.ins_id = c.ins AND transport_core.year_schema(iy.yrlabel) = v_sch ORDER BY iy.yrlabel DESC LIMIT 1;

  FOREACH v_kind IN ARRAY ARRAY['students', 'staff'] LOOP
    CONTINUE WHEN p_row->v_kind IS NULL;
    IF jsonb_typeof(p_row->v_kind) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
    v_tbl := CASE v_kind WHEN 'students' THEN 'tr_trip_student' ELSE 'tr_trip_staff_rider' END;
    IF jsonb_array_length(p_row->v_kind) > 0 AND to_regclass(format('%I.%I', v_sch, v_tbl)) IS NULL THEN
      RAISE EXCEPTION 'Staff transport has not been set up for this academic year.';
    END IF;
    FOR x IN SELECT r FROM jsonb_array_elements(p_row->v_kind) r LOOP
      v_eid := NULLIF(x->>'enrollment_id', '')::bigint;
      v_add := COALESCE(NULLIF(x->>'add', '')::boolean, false);
      v_st := upper(NULLIF(btrim(x->>'status'), ''));

      -- an added rider taken off again
      IF v_st = 'REMOVE' THEN
        EXECUTE format('DELETE FROM %I.%I WHERE trip_id = $1 AND enrollment_id = $2 AND is_extra', v_sch, v_tbl) USING v_trip, v_eid;
        GET DIAGNOSTICS v_rc = ROW_COUNT;
        IF v_rc = 0 THEN
          RAISE EXCEPTION 'Only a % added to trip % can be taken off it.', CASE v_kind WHEN 'students' THEN 'student' ELSE 'staff member' END, v_code;
        END IF;
        v_n := v_n + 1;
        CONTINUE;
      END IF;

      -- present: boarded on a pickup, alighted (got off at the stop) on a drop
      IF v_st IN ('PRESENT', 'BOARDED', 'ALIGHTED') THEN
        v_st := CASE WHEN v_dir = 'DROP' THEN 'ALIGHTED' ELSE 'BOARDED' END;
      END IF;
      IF v_st IS NULL OR v_st NOT IN ('EXPECTED', 'BOARDED', 'ALIGHTED', 'ABSENT', 'PARENT_PICKUP')
         OR (v_kind = 'staff' AND v_st = 'PARENT_PICKUP') THEN
        RAISE EXCEPTION 'Choose Present, Absent%.', CASE WHEN v_kind = 'students' THEN ' or Parent pickup' ELSE '' END;
      END IF;

      IF v_add OR v_st IN ('BOARDED', 'ALIGHTED') THEN
        v_who := NULL;
        IF v_app IS NOT NULL THEN
          IF v_kind = 'students' THEN
            EXECUTE format('SELECT concat_ws('' '', s.stuadmno, s.stuname) FROM %I.tr_student_enrollment e
                              JOIN %I.students s ON s.stu_id = e.student_id WHERE e.enrollment_id = $1', v_sch, v_app) INTO v_who USING v_eid;
          ELSIF to_regclass(format('%I.staffmast', v_app)) IS NOT NULL THEN
            EXECUTE format('SELECT concat_ws('' '', m.emp_code, m.stafname) FROM %I.tr_staff_enrollment e
                              JOIN %I.staffmast m ON m.staf_id = e.staf_id WHERE e.enrollment_id = $1', v_sch, v_app) INTO v_who USING v_eid;
          END IF;
        END IF;
        v_who := COALESCE(NULLIF(v_who, ''), CASE v_kind WHEN 'students' THEN 'The student' ELSE 'The staff member' END);
        -- present on one trip each way a day
        v_other := NULL;
        EXECUTE format('SELECT s.schedule_code FROM %1$I.%2$I o JOIN %1$I.tr_trip t2 ON t2.trip_id = o.trip_id
                          JOIN %1$I.tr_trip_schedule s ON s.schedule_id = t2.schedule_id
                         WHERE o.enrollment_id = $1 AND o.trip_id <> $2 AND t2.trip_date = $3 AND t2.direction = $4
                           AND t2.status <> ''CANCELLED'' AND o.status IN (''BOARDED'', ''ALIGHTED'')
                         ORDER BY t2.trip_id LIMIT 1', v_sch, v_tbl)
           INTO v_other USING v_eid, v_trip, v_date, v_dir;
        IF v_other IS NOT NULL THEN RAISE EXCEPTION '% is already present on trip %.', v_who, v_other; END IF;
      END IF;

      -- a rider of the route added to this trip
      IF v_add THEN
        v_stop := NULL;
        EXECUTE format('SELECT CASE WHEN $3 = ''PICKUP'' THEN e.pickup_stop_id ELSE e.drop_stop_id END, e.%I::numeric
                          FROM %I.%I e WHERE e.enrollment_id = $1 AND e.route_id = $2 AND e.status = ''ACTIVE''
                           AND $4 >= e.start_date AND (e.end_date IS NULL OR $4 <= e.end_date) AND e.service_type IN (''BOTH'', $3)',
                       CASE v_kind WHEN 'students' THEN 'student_id' ELSE 'staf_id' END, v_sch,
                       CASE v_kind WHEN 'students' THEN 'tr_student_enrollment' ELSE 'tr_staff_enrollment' END)
           INTO v_stop, v_pid USING v_eid, v_route, v_dir, v_date;
        IF v_stop IS NULL THEN
          RAISE EXCEPTION '% does not travel % on the route of trip % that day. Refresh and try again.', v_who, lower(v_dir), v_code;
        END IF;
        EXECUTE format('INSERT INTO %I.%I (trip_id, enrollment_id, %I, stop_id, status, is_extra)
                        VALUES ($1, $2, $3, $4, ''EXPECTED'', true) ON CONFLICT DO NOTHING', v_sch, v_tbl,
                       CASE v_kind WHEN 'students' THEN 'student_id' ELSE 'staf_id' END)
          USING v_trip, v_eid, v_pid, v_stop;
        GET DIAGNOSTICS v_rc = ROW_COUNT;
        IF v_rc = 0 THEN RAISE EXCEPTION '% is already on trip %.', v_who, v_code; END IF;
        -- not marked on their own trip that way yet: absent there, as they ride this one
        EXECUTE format('UPDATE %1$I.%2$I o SET status = ''ABSENT'', boarded_at = NULL, alighted_at = NULL, marked_by = $4, mark_method = ''MANUAL''
                          FROM %1$I.tr_trip t2
                         WHERE t2.trip_id = o.trip_id AND o.enrollment_id = $1 AND o.trip_id <> $2 AND t2.trip_date = $3
                           AND t2.direction = $5 AND t2.status <> ''CANCELLED'' AND o.status = ''EXPECTED''', v_sch, v_tbl)
          USING v_eid, v_trip, v_date, c.usr, v_dir;
        v_added := v_added + 1;
      END IF;

      EXECUTE format('UPDATE %I.%I SET status = $3,
                        boarded_at = CASE WHEN $3 = ''BOARDED'' THEN COALESCE(boarded_at, now()) WHEN $3 = ''ALIGHTED'' THEN boarded_at END,
                        alighted_at = CASE WHEN $3 = ''ALIGHTED'' THEN COALESCE(alighted_at, now()) END,
                        marked_by = CASE WHEN $3 = ''EXPECTED'' THEN NULL ELSE $4 END,
                        mark_method = CASE WHEN $3 = ''EXPECTED'' THEN NULL ELSE ''MANUAL'' END
                      WHERE trip_id = $1 AND enrollment_id = $2', v_sch, v_tbl)
        USING v_trip, v_eid, v_st, c.usr;
      GET DIAGNOSTICS v_rc = ROW_COUNT;
      IF v_rc = 0 THEN
        RAISE EXCEPTION 'A % is not on trip % any more. Refresh and try again.', CASE v_kind WHEN 'students' THEN 'student' ELSE 'staff member' END, v_code;
      END IF;
      v_n := v_n + 1;
    END LOOP;
  END LOOP;

  -- riders added: the vehicle still has the seats for everyone travelling
  IF v_added > 0 THEN
    SELECT v.vehicle_code, v.seating_capacity + COALESCE(v.additional_capacity, 0) INTO v_vname, v_seats
      FROM public.tr_vehicle v WHERE v.vehicle_id = v_veh;
    EXECUTE format('SELECT (SELECT count(*) FROM %I.tr_trip_student x WHERE x.trip_id = $1 AND x.status IN (''EXPECTED'', ''BOARDED'', ''ALIGHTED''))', v_sch)
         || CASE WHEN to_regclass(format('%I.tr_trip_staff_rider', v_sch)) IS NOT NULL
                 THEN format(' + (SELECT count(*) FROM %I.tr_trip_staff_rider y WHERE y.trip_id = $1 AND y.status IN (''EXPECTED'', ''BOARDED'', ''ALIGHTED''))', v_sch)
                 ELSE '' END
       INTO v_riders USING v_trip;
    IF v_riders > v_seats THEN
      RAISE EXCEPTION '% takes %, but trip % would then have % riders.', v_vname,
        CASE WHEN v_seats = 1 THEN '1 rider' ELSE v_seats || ' riders' END, v_code, v_riders;
    END IF;
  END IF;

  -- the boarded students of the trip and of each stop
  EXECUTE format('UPDATE %1$I.tr_trip t SET boarded_students = (SELECT count(*) FROM %1$I.tr_trip_student x
                    WHERE x.trip_id = t.trip_id AND x.status IN (''BOARDED'', ''ALIGHTED'')), updated_by = $2, updated_at = now()
                  WHERE t.trip_id = $1', v_sch) USING v_trip, c.usr;
  EXECUTE format('UPDATE %1$I.tr_trip_stop ts SET boarded_count = (SELECT count(*) FROM %1$I.tr_trip_student x
                    WHERE x.trip_id = ts.trip_id AND x.stop_id = ts.stop_id AND x.status IN (''BOARDED'', ''ALIGHTED''))
                  WHERE ts.trip_id = $1', v_sch) USING v_trip;
  RETURN v_n;
END $$;

-- The nightly run (pg_cron, transport_26): tomorrow's trips for every school
-- with a route in use. A school whose trips cannot be made (e.g. no academic
-- year with transport holds tomorrow) is skipped with a warning; the others
-- still get theirs. Returns how many trips were made.
CREATE OR REPLACE FUNCTION transport_core.generate_next_day_trips()
RETURNS integer LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public' AS $$
DECLARE v_day date := transport_core._today() + 1; v_ins bigint; v_n integer := 0;
BEGIN
  FOR v_ins IN SELECT DISTINCT r.inst_id FROM public.tr_route r WHERE r.is_active ORDER BY 1 LOOP
    BEGIN
      v_n := v_n + transport_core.fn_generate_trips(v_ins, v_day);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'The trips of % for school % were not made: %', to_char(v_day, 'DD-MM-YYYY'), v_ins, SQLERRM;
    END;
  END LOOP;
  RETURN v_n;
END $$;

-- ---------------------------------------------------------------------
-- Stage Fee Process (the Stage Fees screen's Process Fees): the students
-- of the ticked routes are billed for a term and fee type from their stage
-- fees, in the school app's fee demands of the session year.
-- ---------------------------------------------------------------------
-- The routes to tick: the school's routes, each with its students (active
-- transport in the session year), the stages that have a fee for the term
-- and fee type, and the fee demands the process has made or updated from
-- them (still active in the fee screens), with the last time:
-- [{"route_id", "route_code", "route_name", "is_active", "students",
--   "stages", "processed", "processed_at"}, ...] in route order.
-- p_filter: {"sem_id": 1, "fee_id": 2}
CREATE OR REPLACE FUNCTION transport_core.stage_fee_routes(p_token text, p_filter jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE c record; y record; v_sch text; v_sem smallint; v_fee integer; v_out jsonb;
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Stage Fees']);
  v_sch := transport_core._year(c.ysch, c.yr);
  SELECT * INTO y FROM transport_core._student_year(c.iyr);
  v_sem := NULLIF(p_filter->>'sem_id', '')::smallint;
  v_fee := NULLIF(p_filter->>'fee_id', '')::integer;
  IF v_sem IS NULL THEN RAISE EXCEPTION 'Choose the term.'; END IF;
  IF v_fee IS NULL THEN RAISE EXCEPTION 'Choose the fee type.'; END IF;
  IF to_regclass(quote_ident(y.sch) || '.feedemand') IS NULL THEN
    RAISE EXCEPTION 'The fee demands of this academic year were not found.';
  END IF;
  EXECUTE format($q$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'route_id', rt.route_id, 'route_code', rt.route_code, 'route_name', rt.route_name, 'is_active', rt.is_active,
             'students', (SELECT count(*) FROM %1$I.tr_student_enrollment e
                           WHERE e.route_id = rt.route_id AND e.inst_id = $1 AND e.acad_year_id = $2 AND e.status = 'ACTIVE'),
             'stages', (SELECT count(DISTINCT f.stage_id) FROM %1$I.tr_stage_fee f
                         WHERE f.route_id = rt.route_id AND f.sem_id = $3 AND f.fee_id = $4 AND f.activestatus = 1),
             'processed', d.n, 'processed_at', d.last_at)
           ORDER BY rt.route_code), '[]'::jsonb)
      FROM public.tr_route rt
     CROSS JOIN LATERAL (SELECT count(*) AS n, max(x.processed_at) AS last_at
                           FROM %1$I.tr_stage_fee_demand x
                           JOIN %2$I.feedemand fd ON fd.dem_id = x.dem_id AND fd.activestatus = 1
                          WHERE x.route_id = rt.route_id AND x.sem_id = $3 AND x.fee_id = $4) d
     WHERE rt.inst_id = $1$q$, v_sch, y.sch)
    INTO v_out USING c.ins, c.iyr, v_sem, v_fee;
  RETURN v_out;
END $$;

-- The process. For every student whose transport is active on a ticked
-- route and runs in the term:
--   * the stage fee of their fee stage and way (Both / Pickup / Drop) for
--     the term and fee type; the latest start date, if it has several;
--   * their class's fee for that term and fee type in the fee master
--     (classfeedemand), which gives the due date. Without one the student
--     is left out, with a message;
--   * their fee demand of that term and fee type (not an arrear) takes the
--     stage fee as its amount, or is made (REGULAR) when they have none.
--     The balance is the amount less concession and paid. An amount below
--     what is already paid + concession is refused for that student, who
--     keeps the demand as it was;
--   * each demand made or updated is kept in tr_stage_fee_demand.
-- A student refused (no stage fee, no class fee, below paid, or any refusal
-- of the fee screens' own checks, e.g. an online payment in progress) does
-- not stop the others. Running it again is safe: new students are added,
-- changed fees updated, the rest left as they are. One run at a time per
-- school, term and fee type.
-- p_row: {"sem_id": 1, "fee_id": 2, "route_ids": [20, 21]}
-- Returns {"students", "added", "updated", "unchanged", "skipped",
--          "problems": [{"route_code", "stage", "stuadmno", "stuname",
--                        "stuclass", "reason"}, ...]}.
CREATE OR REPLACE FUNCTION transport_core.stage_fee_process(p_token text, p_row jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE
  c record; y record; r record; cf record; v_sch text;
  v_sem smallint; v_term text; v_t1 date; v_t2 date; v_fee integer; v_feename text; v_cat text; v_on smallint;
  v_routes bigint[]; v_seen bigint[] := '{}'; v_by text; v_way text; v_why text; v_done text;
  v_dems bigint[]; v_dem bigint; v_old numeric; v_paid numeric; v_con numeric;
  v_n integer := 0; v_add integer := 0; v_upd integer := 0; v_same integer := 0; v_skip integer := 0;
  v_problems jsonb := '[]';
BEGIN
  SELECT * INTO c FROM transport_core._ctx(p_token, ARRAY['Stage Fees']);
  v_sch := transport_core._year(c.ysch, c.yr);
  SELECT * INTO y FROM transport_core._student_year(c.iyr);
  IF jsonb_typeof(p_row) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Nothing to process.'; END IF;

  v_sem := NULLIF(p_row->>'sem_id', '')::smallint;
  IF v_sem IS NULL THEN RAISE EXCEPTION 'Choose the term.'; END IF;
  IF to_regclass(quote_ident(y.sch) || '.semester') IS NOT NULL THEN
    EXECUTE format('SELECT COALESCE(NULLIF(btrim(s.semname), ''''), ''the term''), s.semstart, s.semend
                      FROM %I.semester s WHERE s.sem_id = $1 AND s.ins_id = $2', y.sch)
       INTO v_term, v_t1, v_t2 USING v_sem, c.ins;
  END IF;
  IF v_term IS NULL THEN RAISE EXCEPTION 'The selected term was not found in this academic year.'; END IF;

  v_fee := NULLIF(p_row->>'fee_id', '')::integer;
  IF v_fee IS NULL THEN RAISE EXCEPTION 'Choose the fee type.'; END IF;
  SELECT f.feedesc, f.feecat, f.activestatus INTO v_feename, v_cat, v_on FROM public.feetype f WHERE f.fee_id = v_fee AND f.ins_id = c.ins;
  IF NOT FOUND THEN RAISE EXCEPTION 'The selected fee type was not found.'; END IF;
  IF v_cat IS DISTINCT FROM 'TRA' THEN RAISE EXCEPTION 'Choose a transport fee type (fee category TRA).'; END IF;
  IF v_on IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'The selected fee type is switched off.'; END IF;

  IF jsonb_typeof(p_row->'route_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(p_row->'route_ids') = 0 THEN
    RAISE EXCEPTION 'Tick the routes to process.';
  END IF;
  SELECT array_agg(DISTINCT (x #>> '{}')::bigint) INTO v_routes FROM jsonb_array_elements(p_row->'route_ids') x;
  IF EXISTS (SELECT 1 FROM unnest(v_routes) AS t(id)
              WHERE NOT EXISTS (SELECT 1 FROM public.tr_route rt WHERE rt.route_id = t.id AND rt.inst_id = c.ins)) THEN
    RAISE EXCEPTION 'A ticked route was not found. Refresh and try again.';
  END IF;

  IF to_regclass(quote_ident(y.sch) || '.feedemand') IS NULL OR to_regclass(quote_ident(y.sch) || '.classfeedemand') IS NULL THEN
    RAISE EXCEPTION 'The fee demands of this academic year were not found.';
  END IF;
  -- the school app takes no new fee demands once its Year End is done
  IF to_regprocedure('public._school_assert_year_open(integer,text,text)') IS NOT NULL THEN
    PERFORM public._school_assert_year_open(c.ins, y.sch, 'transport fee demands');
  END IF;
  -- one run at a time for a school, term and fee type: two at once would
  -- both find no demand and make it twice
  PERFORM pg_advisory_xact_lock(hashtext(format('tr_stage_fee_process:%s:%s:%s', c.ins, v_sem, v_fee)));
  -- who made the demands, as the fee screens show it
  SELECT NULLIF(btrim(u.usename), '') INTO v_by FROM public.institutionusers u WHERE u.use_id = c.usr;
  v_by := COALESCE(v_by, 'TRANSPORT');

  FOR r IN EXECUTE format($q$
      SELECT e.route_id, rt.route_code, rt.route_name, e.service_type, e.start_date, e.end_date, e.student_id,
             g.stage_no, g.stage_name, s.stu_id, s.stuadmno, s.stuname, s.stuclass, s.cla_id,
             sf.stage_fee_id, sf.amount
        FROM %1$I.tr_student_enrollment e
        JOIN public.tr_route rt ON rt.route_id = e.route_id
        LEFT JOIN public.tr_stage g ON g.stage_id = e.fee_stage_id
        LEFT JOIN %2$I.students s ON s.stu_id = e.student_id AND s.ins_id = $1 AND s.activestatus = 1
        LEFT JOIN LATERAL (SELECT f.stage_fee_id, f.amount FROM %1$I.tr_stage_fee f
                            WHERE f.route_id = e.route_id AND f.stage_id = e.fee_stage_id AND f.service_type = e.service_type
                              AND f.sem_id = $3 AND f.fee_id = $4 AND f.activestatus = 1
                            ORDER BY f.effective_from DESC, f.stage_fee_id DESC LIMIT 1) sf ON true
       WHERE e.inst_id = $1 AND e.acad_year_id = $2 AND e.status = 'ACTIVE' AND e.route_id = ANY ($5)
       ORDER BY rt.route_code, g.stage_no, s.stuclass, s.stuname, e.student_id$q$, v_sch, y.sch)
    USING c.ins, c.iyr, v_sem, v_fee, v_routes
  LOOP
    v_n := v_n + 1;
    v_seen := v_seen || r.route_id;
    v_why := NULL;
    v_done := NULL;
    v_way := CASE r.service_type WHEN 'PICKUP' THEN 'pickup only' WHEN 'DROP' THEN 'drop only' ELSE 'both ways' END;
    IF r.stu_id IS NULL THEN
      v_why := 'Not among this year''s active students in the school app.';
    ELSIF r.start_date > v_t2 OR r.end_date < v_t1 THEN
      v_why := format('Transport from %s%s is outside %s.', to_char(r.start_date, 'DD-MM-YYYY'),
                      COALESCE(' to ' || to_char(r.end_date, 'DD-MM-YYYY'), ''), v_term);
    ELSIF r.stage_fee_id IS NULL THEN
      v_why := format('Stage %s (%s) has no %s for %s, %s. Set it in Stage Fees first.', r.stage_no, r.stage_name, v_feename, v_term, v_way);
    ELSE
      -- one student at a time: a refusal here is theirs alone
      BEGIN
        EXECUTE format($q$SELECT cf.cf_id, cf.cfterm, cf.cffeetype, cf.cfdduedate, cf.cla_id, cf.collectible
                            FROM %I.classfeedemand cf
                           WHERE cf.activestatus = 1
                             AND (cf.cla_id = $1 OR upper(btrim(cf.cfclass)) = upper(btrim($2)))
                             AND (cf.sem_id = $3 OR (cf.sem_id IS NULL AND upper(btrim(cf.cfterm)) = upper(btrim($4))))
                             AND (cf.fee_id = $5 OR (cf.fee_id IS NULL AND upper(btrim(cf.cffeetype)) = upper(btrim($6))))
                           ORDER BY (cf.cla_id IS NOT DISTINCT FROM $1) DESC, cf.cf_id
                           LIMIT 1$q$, y.sch)
           INTO cf USING r.cla_id, r.stuclass, v_sem, v_term, v_fee, v_feename;
        IF cf.cf_id IS NULL THEN
          v_why := format('Class %s has no %s for %s in the fee master (class fee demand). Add it there first.',
                          COALESCE(NULLIF(btrim(r.stuclass), ''), '-'), v_feename, v_term);
        ELSE
          -- the student's demand of this term and fee type, locked
          EXECUTE format($q$SELECT array_agg(x.dem_id ORDER BY x.dem_id) FROM (
                              SELECT fd.dem_id FROM %I.feedemand fd
                               WHERE fd.ins_id = $1 AND fd.stu_id = $2 AND fd.activestatus = 1
                                 AND COALESCE(fd.demseqtype, '') <> 'ARREAR'
                                 AND (fd.sem_id = $3 OR (fd.sem_id IS NULL AND upper(btrim(fd.demfeeterm)) = upper(btrim($4))))
                                 AND (fd.fee_id = $5 OR (fd.fee_id IS NULL AND upper(btrim(fd.demfeetype)) = upper(btrim($6))))
                               FOR UPDATE) x$q$, y.sch)
             INTO v_dems USING c.ins, r.stu_id, v_sem, COALESCE(cf.cfterm, v_term), v_fee, COALESCE(cf.cffeetype, v_feename);
          IF cardinality(v_dems) > 1 THEN
            v_why := format('Has %s %s demands for %s. Correct them in the fee screens first.', cardinality(v_dems), v_feename, v_term);
          ELSIF v_dems IS NULL THEN
            IF r.amount <= 0 THEN
              v_why := format('The %s of Stage %s is 0, so no fee demand was made.', v_feename, r.stage_no);
            ELSE
              EXECUTE format($q$INSERT INTO %1$I.feedemand
                                  (ins_id, inscode, yr_id, stu_id, stuadmno, stuclass, courname, demfeeyear, demfeeterm, demfeetype,
                                   feeamount, con_id, conamount, balancedue, reconbalancedue, paidamount, duedate, activestatus,
                                   createdby, collectible, cla_id, sem_id, cf_id, fee_id, demseqtype, remarks)
                                SELECT s.ins_id, s.inscode, s.yr_id, s.stu_id, s.stuadmno, s.stuclass, s.courname, s.yrlabel, $3, $4,
                                       $5, s.con_id, 0, $5, $5, 0, $6, 1,
                                       $7, $8, $9, $10, $11, $12, 'REGULAR', $13
                                  FROM %1$I.students s WHERE s.stu_id = $1 AND s.ins_id = $2
                                RETURNING dem_id$q$, y.sch)
                 INTO v_dem
                USING r.stu_id, c.ins, COALESCE(cf.cfterm, v_term), COALESCE(cf.cffeetype, v_feename), r.amount,
                      COALESCE(cf.cfdduedate, v_t2, y.to_date, CURRENT_DATE), v_by, COALESCE(cf.collectible, true),
                      COALESCE(cf.cla_id, r.cla_id), v_sem, cf.cf_id, v_fee, 'TRANSPORT ' || upper(r.route_name);
              v_done := 'added';
            END IF;
          ELSE
            v_dem := v_dems[1];
            EXECUTE format('SELECT feeamount, COALESCE(paidamount, 0), COALESCE(conamount, 0) FROM %I.feedemand WHERE dem_id = $1', y.sch)
               INTO v_old, v_paid, v_con USING v_dem;
            IF v_old = r.amount THEN
              v_done := 'unchanged';
            ELSIF r.amount + 0.005 < v_paid + v_con THEN
              v_why := format('The new fee %s is below the %s already paid%s, so the fee demand was left at %s.',
                              to_char(r.amount, 'FM99,99,99,990.00'), to_char(v_paid, 'FM99,99,99,990.00'),
                              CASE WHEN v_con > 0 THEN ' + ' || to_char(v_con, 'FM99,99,99,990.00') || ' concession' ELSE '' END,
                              to_char(v_old, 'FM99,99,99,990.00'));
            ELSE
              -- as the fee screens change an amount (rebuild_demand)
              EXECUTE format($q$UPDATE %I.feedemand SET feeamount = $2,
                                  balancedue = GREATEST($2 - COALESCE(conamount, 0) - COALESCE(paidamount, 0), 0),
                                  reconbalancedue = GREATEST(COALESCE(reconbalancedue, balancedue, 0)
                                                    + GREATEST($2 - COALESCE(conamount, 0) - COALESCE(paidamount, 0), 0) - COALESCE(balancedue, 0), 0),
                                  paidstatus = CASE WHEN GREATEST($2 - COALESCE(conamount, 0) - COALESCE(paidamount, 0), 0) > 0 THEN 'U' ELSE 'P' END
                                WHERE dem_id = $1$q$, y.sch)
                USING v_dem, r.amount;
              v_done := 'updated';
            END IF;
          END IF;
          IF v_done IS NOT NULL THEN
            EXECUTE format($q$INSERT INTO %I.tr_stage_fee_demand (sem_id, fee_id, route_id, stage_fee_id, dem_id, amount, processed_by)
                              VALUES ($1, $2, $3, $4, $5, $6, $7)
                              ON CONFLICT (dem_id) DO UPDATE SET sem_id = EXCLUDED.sem_id, fee_id = EXCLUDED.fee_id,
                                route_id = EXCLUDED.route_id, stage_fee_id = EXCLUDED.stage_fee_id, amount = EXCLUDED.amount,
                                processed_at = now(), processed_by = EXCLUDED.processed_by$q$, v_sch)
              USING v_sem, v_fee, r.route_id, r.stage_fee_id, v_dem, r.amount, c.usr;
          END IF;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_done := NULL;
        v_why := SQLERRM;
      END;
    END IF;

    IF v_done = 'added' THEN v_add := v_add + 1;
    ELSIF v_done = 'updated' THEN v_upd := v_upd + 1;
    ELSIF v_done = 'unchanged' THEN v_same := v_same + 1;
    ELSE
      v_skip := v_skip + 1;
      v_problems := v_problems || jsonb_build_object('route_code', r.route_code, 'stage', format('Stage %s', r.stage_no),
                      'student_id', r.student_id, 'stuadmno', r.stuadmno, 'stuname', r.stuname, 'stuclass', r.stuclass, 'reason', v_why);
    END IF;
  END LOOP;

  -- a ticked route with nobody on it
  SELECT v_problems || COALESCE(jsonb_agg(jsonb_build_object('route_code', rt.route_code,
                                  'reason', 'No students have active transport on this route.') ORDER BY rt.route_code), '[]'::jsonb)
    INTO v_problems FROM public.tr_route rt WHERE rt.route_id = ANY (v_routes) AND NOT (rt.route_id = ANY (v_seen));

  RETURN jsonb_build_object('students', v_n, 'added', v_add, 'updated', v_upd, 'unchanged', v_same, 'skipped', v_skip,
                            'problems', v_problems);
END $$;

-- ---------------------------------------------------------------------
-- The parent app's School Bus map: for one of the parent's own children,
-- the route with its stops in pickup order (the child's pickup and drop
-- stop marked) and the child's trips (pickup, drop) with the vehicle of
-- today's trip (or of the schedule) and where it is now (tr_vehicle_live).
-- A parent session only (app_session.par_id); the child must be the
-- parent's (parentdetail of the school's year). The year is the school
-- year covering today (a parent session has none).
--   {"enabled": false}                    Transport switched off for the school
--   {"enabled": true, "enrolled": false}  no active transport for the child
--   {"enabled": true, "enrolled": true, "route": {...}, "stops": [...],
--    "trips": [{"direction", "planned_start", "runs_today", "trip_status",
--               "vehicle": {...}, "live": {"lat", "lon", ...} | null}, ...]}
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport_core.parent_bus(p_token text, p_stu_id bigint)
RETURNS jsonb LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'extensions' AS $$
DECLARE w record; e record; v_sch text; v_lbl text; v_ysch text; v_today date; v_route jsonb; v_stops jsonb; v_trips jsonb;
BEGIN
  SELECT * INTO w FROM public._online_who(p_token);  -- 'Invalid or expired session' when not signed in
  IF w.par_id IS NULL THEN
    RAISE EXCEPTION 'The bus map is for the parent app.' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.modules m
              WHERE m.ins_id = w.ins_id AND upper(btrim(m.modshort)) = 'TRN' AND m.activestatus = 0) THEN
    RETURN jsonb_build_object('enabled', false);
  END IF;
  v_sch := public.get_institution_schema(w.ins_id);
  IF v_sch IS NULL OR p_stu_id IS NULL OR NOT public._online_parent_owns(v_sch, w.par_id, p_stu_id) THEN
    RAISE EXCEPTION 'This student is not on your account.' USING ERRCODE = '42501';
  END IF;
  SELECT iy.yrlabel INTO v_lbl FROM public.institutionyear iy
   WHERE iy.ins_id = w.ins_id AND lower(iy.iyrschema) = v_sch AND iy.activestatus = 1
   ORDER BY iy.iyr_id DESC LIMIT 1;
  v_ysch := transport_core.year_schema(v_lbl);
  IF v_ysch IS NULL OR to_regnamespace(v_ysch) IS NULL THEN
    RETURN jsonb_build_object('enabled', true, 'enrolled', false);
  END IF;
  v_today := (now() AT TIME ZONE 'Asia/Kolkata')::date;

  EXECUTE format('SELECT * FROM %I.tr_student_enrollment
                   WHERE inst_id = $1 AND student_id = $2 AND status = ''ACTIVE'' AND (end_date IS NULL OR end_date >= $3)
                   ORDER BY start_date DESC NULLS LAST, enrollment_id DESC LIMIT 1', v_ysch)
     INTO e USING w.ins_id, p_stu_id, v_today;
  IF e.enrollment_id IS NULL THEN
    RETURN jsonb_build_object('enabled', true, 'enrolled', false);
  END IF;

  SELECT jsonb_build_object('route_id', r.route_id, 'code', r.route_code, 'name', r.route_name,
                            'start_point', r.start_point, 'end_point', r.end_point,
                            'distance_km', r.total_distance_km, 'duration_min', r.est_duration_min)
    INTO v_route FROM public.tr_route r WHERE r.route_id = e.route_id AND r.inst_id = w.ins_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'stop_id', p.stop_id, 'name', p.stop_name, 'code', p.stop_code, 'landmark', p.landmark,
           'seq', p.stop_seq, 'stage_no', g.stage_no, 'lat', p.latitude, 'lon', p.longitude,
           'pickup', p.stop_id = e.pickup_stop_id, 'drop', p.stop_id = e.drop_stop_id)
           ORDER BY p.stop_seq NULLS LAST, g.stage_no NULLS LAST, p.stop_id), '[]'::jsonb)
    INTO v_stops
    FROM public.tr_stop p LEFT JOIN public.tr_stage g ON g.stage_id = p.stage_id
   WHERE p.route_id = e.route_id AND p.inst_id = w.ins_id
     AND (p.is_active OR p.stop_id IN (e.pickup_stop_id, e.drop_stop_id));

  EXECUTE format($q$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'schedule_id', sc.schedule_id, 'code', sc.schedule_code, 'name', sc.schedule_name, 'direction', sc.direction,
             'planned_start', to_char(sc.planned_start, 'HH24:MI'), 'planned_end', to_char(sc.planned_end, 'HH24:MI'),
             'runs_today', EXTRACT(ISODOW FROM $2)::smallint = ANY (sc.run_days),
             'trip_status', t.status, 'next_stop_id', t.next_stop_id,
             'vehicle', CASE WHEN v.vehicle_id IS NULL THEN NULL ELSE jsonb_build_object(
                          'vehicle_id', v.vehicle_id, 'code', v.vehicle_code, 'registration_no', v.registration_no,
                          'type', v.vehicle_type) END,
             'live', CASE WHEN l.vehicle_id IS NULL THEN NULL ELSE jsonb_build_object(
                          'lat', l.latitude, 'lon', l.longitude, 'speed_kmph', l.speed_kmph, 'heading_deg', l.heading_deg,
                          'recorded_at', l.recorded_at) END)
             ORDER BY sc.planned_start, sc.schedule_id), '[]'::jsonb)
      FROM %1$I.tr_trip_schedule sc
      LEFT JOIN %1$I.tr_trip t ON t.schedule_id = sc.schedule_id AND t.trip_date = $2
      LEFT JOIN public.tr_vehicle v ON v.vehicle_id = COALESCE(t.vehicle_id, sc.vehicle_id) AND v.inst_id = $3
      LEFT JOIN %1$I.tr_vehicle_live l ON l.vehicle_id = v.vehicle_id
     WHERE sc.schedule_id = ANY ($1) AND sc.inst_id = $3 AND sc.is_active$q$, v_ysch)
     INTO v_trips USING ARRAY[e.pickup_schedule_id, e.drop_schedule_id], v_today, w.ins_id;

  RETURN jsonb_build_object('enabled', true, 'enrolled', true, 'service_type', e.service_type,
                            'start_date', e.start_date, 'end_date', e.end_date, 'today', v_today, 'now', now(),
                            'route', v_route, 'pickup_stop_id', e.pickup_stop_id, 'drop_stop_id', e.drop_stop_id,
                            'stops', v_stops, 'trips', v_trips);
END $$;

-- ---------------------------------------------------------------------
-- The only doors from the app. Run as owner; the checks are in _ctx
-- (tr_parent_bus: in parent_bus).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tr_list(p_token text, p_entity text, p_filter jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.list(p_token, p_entity, p_filter) $$;

CREATE OR REPLACE FUNCTION public.tr_save(p_token text, p_entity text, p_row jsonb)
RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.save(p_token, p_entity, p_row) $$;

CREATE OR REPLACE FUNCTION public.tr_delete(p_token text, p_entity text, p_id bigint)
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.remove(p_token, p_entity, p_id) $$;

CREATE OR REPLACE FUNCTION public.tr_settings_get(p_token text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.settings_get(p_token) $$;

CREATE OR REPLACE FUNCTION public.tr_settings_save(p_token text, p_row jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.settings_save(p_token, p_row) $$;

CREATE OR REPLACE FUNCTION public.tr_lookups(p_token text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.lookups(p_token) $$;

CREATE OR REPLACE FUNCTION public.tr_students(p_token text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.students(p_token) $$;

CREATE OR REPLACE FUNCTION public.tr_enrollment_staff(p_token text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.enrollment_staff(p_token) $$;

CREATE OR REPLACE FUNCTION public.tr_daily_trips(p_token text, p_date date)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.daily_trips(p_token, p_date) $$;

CREATE OR REPLACE FUNCTION public.tr_trips_make(p_token text, p_date date)
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.trips_make(p_token, p_date) $$;

CREATE OR REPLACE FUNCTION public.tr_trip_save(p_token text, p_row jsonb)
RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.trip_save(p_token, p_row) $$;

CREATE OR REPLACE FUNCTION public.tr_trip_replace(p_token text, p_row jsonb)
RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.trip_replace(p_token, p_row) $$;

CREATE OR REPLACE FUNCTION public.tr_trip_riders(p_token text, p_date date, p_trip_id bigint)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.trip_riders(p_token, p_date, p_trip_id) $$;

CREATE OR REPLACE FUNCTION public.tr_trip_rider_options(p_token text, p_date date, p_trip_id bigint)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.trip_rider_options(p_token, p_date, p_trip_id) $$;

CREATE OR REPLACE FUNCTION public.tr_trip_board_save(p_token text, p_row jsonb)
RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.trip_board_save(p_token, p_row) $$;

CREATE OR REPLACE FUNCTION public.tr_stage_fee_routes(p_token text, p_filter jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.stage_fee_routes(p_token, p_filter) $$;

CREATE OR REPLACE FUNCTION public.tr_stage_fee_process(p_token text, p_row jsonb)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.stage_fee_process(p_token, p_row) $$;

CREATE OR REPLACE FUNCTION public.tr_parent_bus(p_token text, p_stu_id bigint)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public'
AS $$ SELECT transport_core.parent_bus(p_token, p_stu_id) $$;

REVOKE ALL ON FUNCTION public.tr_list(text, text, jsonb), public.tr_save(text, text, jsonb), public.tr_delete(text, text, bigint),
                       public.tr_settings_get(text), public.tr_settings_save(text, jsonb), public.tr_lookups(text),
                       public.tr_students(text), public.tr_stage_fee_routes(text, jsonb), public.tr_stage_fee_process(text, jsonb),
                       public.tr_parent_bus(text, bigint), public.tr_enrollment_staff(text),
                       public.tr_daily_trips(text, date), public.tr_trips_make(text, date), public.tr_trip_save(text, jsonb),
                       public.tr_trip_replace(text, jsonb), public.tr_trip_rider_options(text, date, bigint),
                       public.tr_trip_riders(text, date, bigint), public.tr_trip_board_save(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tr_list(text, text, jsonb), public.tr_save(text, text, jsonb), public.tr_delete(text, text, bigint),
                          public.tr_settings_get(text), public.tr_settings_save(text, jsonb), public.tr_lookups(text),
                          public.tr_students(text), public.tr_stage_fee_routes(text, jsonb), public.tr_stage_fee_process(text, jsonb),
                          public.tr_parent_bus(text, bigint), public.tr_enrollment_staff(text),
                          public.tr_daily_trips(text, date), public.tr_trips_make(text, date), public.tr_trip_save(text, jsonb),
                          public.tr_trip_replace(text, jsonb), public.tr_trip_rider_options(text, date, bigint),
                       public.tr_trip_riders(text, date, bigint), public.tr_trip_board_save(text, jsonb)
                          TO anon, authenticated;

-- ---------------------------------------------------------------------
-- Everything else stays closed, even if a schema is ever exposed by mistake.
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA transport_core FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SCHEMA transport_core FROM PUBLIC, anon, authenticated;
DO $$
DECLARE s record; r record; t text;
BEGIN
  -- every year schema: transport20262027, transport20272028, ...
  FOR s IN SELECT n.nspname FROM pg_namespace n WHERE n.nspname ~ '^transport\d{8}$' LOOP
    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC, anon, authenticated', s.nspname);
    FOR r IN SELECT c.relname, c.relkind FROM pg_class c
              WHERE c.relnamespace = to_regnamespace(s.nspname) AND c.relkind IN ('r', 'p', 'v') LOOP
      IF r.relkind IN ('r', 'p') THEN
        EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', s.nspname, r.relname);
      END IF;
      EXECUTE format('REVOKE ALL ON TABLE %I.%I FROM PUBLIC, anon, authenticated', s.nspname, r.relname);
    END LOOP;
  END LOOP;
  -- the masters in public: PostgREST serves public, so RLS on and no grants
  -- to the app roles. The tr_* functions above still reach them as owner.
  -- (tr_gps_device reaches public in transport_10, which locks it the same way)
  FOREACH t IN ARRAY ARRAY['tr_settings','tr_route','tr_stage','tr_stop','tr_vendor','tr_vehicle',
                           'tr_vehicle_document','tr_vehicle_gps_device','tr_vehicle_service','tr_gps_device',
                           'tr_staff','tr_staff_document'] LOOP
    CONTINUE WHEN to_regclass(format('public.%I', t)) IS NULL;
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon, authenticated', t);
  END LOOP;
END $$;
