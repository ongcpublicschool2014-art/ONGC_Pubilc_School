-- =====================================================================
--  SCHOOL TRANSPORT MODULE  –  PostgreSQL 14+ schema
--  Routes / Stages / Stops, Fees, Vehicles, Staff, Duty, Trips,
--  GPS tracking, Parent notifications, Analytics
--
--  Conventions
--    * Everything lives in schema "transport".
--    * Every table carries inst_id (multi-institution). inst_id refers to
--      your EXISTING institution master; the FKs to existing masters are
--      added at the END of this file (section 12) so you can adjust the
--      table / column names to your real master tables.
--    * Surrogate keys: BIGINT GENERATED ALWAYS AS IDENTITY.
--    * Lat/Long stored as NUMERIC(9,6) so the script runs without PostGIS.
--      Optional PostGIS upgrade is in section 13.
--    * Codes are TEXT + CHECK constraints (easy to extend, Flutter friendly).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS transport;
SET search_path = transport, public;

-- ---------------------------------------------------------------------
-- 0. Common helpers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transport.fn_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Great-circle distance in metres (no PostGIS needed)
CREATE OR REPLACE FUNCTION transport.fn_distance_m(
  lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT (2 * 6371000 * asin(sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2) +
           cos(radians(lat1)) * cos(radians(lat2)) *
           power(sin(radians(lon2 - lon1) / 2), 2))))::numeric(12,2)
$$;

-- ---------------------------------------------------------------------
-- 1. Settings per institution
-- ---------------------------------------------------------------------
CREATE TABLE tr_settings (
  inst_id                 BIGINT PRIMARY KEY,
  eta_alert_minutes       SMALLINT     NOT NULL DEFAULT 10,   -- parent alert lead time
  default_geofence_m      SMALLINT     NOT NULL DEFAULT 100,  -- stop arrival radius
  school_geofence_m       SMALLINT     NOT NULL DEFAULT 200,
  overspeed_kmph          SMALLINT     NOT NULL DEFAULT 40,
  long_halt_minutes       SMALLINT     NOT NULL DEFAULT 5,
  gps_ping_interval_sec   SMALLINT     NOT NULL DEFAULT 10,
  auto_start_trip         BOOLEAN      NOT NULL DEFAULT true, -- start on geofence exit
  doc_expiry_alert_days   SMALLINT     NOT NULL DEFAULT 30,
  school_latitude         NUMERIC(9,6),
  school_longitude        NUMERIC(9,6),
  sms_provider            TEXT,                               -- e.g. MSG91 / Twilio
  sms_sender_id           TEXT,                               -- DLT header (India)
  whatsapp_enabled        BOOLEAN      NOT NULL DEFAULT false,
  push_enabled            BOOLEAN      NOT NULL DEFAULT true,
  created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_by              BIGINT
);

-- ---------------------------------------------------------------------
-- 2. Route  ->  Stage  ->  Stop   (+ stage fee)
-- ---------------------------------------------------------------------
CREATE TABLE tr_route (
  route_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id           BIGINT       NOT NULL,
  route_code        VARCHAR(20)  NOT NULL,
  route_name        VARCHAR(100) NOT NULL,
  description       TEXT,
  start_point       VARCHAR(150),
  end_point         VARCHAR(150),
  total_distance_km NUMERIC(7,2),
  est_duration_min  SMALLINT,
  route_polyline    TEXT,                    -- encoded polyline for map drawing
  is_active         BOOLEAN      NOT NULL DEFAULT true,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by        BIGINT,
  updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_by        BIGINT,
  CONSTRAINT uq_route_code UNIQUE (inst_id, route_code)
);

-- Stage = fee slab within a route (e.g. Stage 1: 0-5 km, Stage 2: 5-10 km)
CREATE TABLE tr_stage (
  stage_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id       BIGINT       NOT NULL,
  route_id      BIGINT       NOT NULL REFERENCES tr_route(route_id),
  stage_no      SMALLINT     NOT NULL,
  stage_name    VARCHAR(100) NOT NULL,
  from_km       NUMERIC(7,2),
  to_km         NUMERIC(7,2),
  is_active     BOOLEAN      NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by    BIGINT,
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_by    BIGINT,
  CONSTRAINT uq_stage_no UNIQUE (route_id, stage_no),
  CONSTRAINT uq_stage_route UNIQUE (stage_id, route_id)   -- for composite FKs
);

-- Fee fixed by the institution for a stage, per academic year
CREATE TABLE tr_stage_fee (
  stage_fee_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id         BIGINT        NOT NULL,
  stage_id        BIGINT        NOT NULL REFERENCES tr_stage(stage_id),
  acad_year_id    BIGINT        NOT NULL,
  fee_frequency   VARCHAR(10)   NOT NULL DEFAULT 'ANNUAL'
                  CHECK (fee_frequency IN ('ANNUAL','TERM','MONTHLY')),
  service_type    VARCHAR(10)   NOT NULL DEFAULT 'BOTH'
                  CHECK (service_type IN ('BOTH','PICKUP','DROP')),  -- one-way fee option
  amount          NUMERIC(10,2) NOT NULL CHECK (amount >= 0),
  fee_head_id     BIGINT,                 -- link to existing fee module head (if any)
  effective_from  DATE          NOT NULL,
  effective_to    DATE,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_by      BIGINT,
  CONSTRAINT uq_stage_fee UNIQUE (stage_id, acad_year_id, fee_frequency, service_type, effective_from)
);

-- Stop = physical pick/drop point; belongs to one stage of one route
CREATE TABLE tr_stop (
  stop_id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id             BIGINT        NOT NULL,
  route_id            BIGINT        NOT NULL,
  stage_id            BIGINT        NOT NULL,
  stop_seq            SMALLINT      NOT NULL,       -- order on the PICKUP direction
  stop_code           VARCHAR(20),
  stop_name           VARCHAR(150)  NOT NULL,
  landmark            VARCHAR(200),
  address             TEXT,
  latitude            NUMERIC(9,6)  NOT NULL,
  longitude           NUMERIC(9,6)  NOT NULL,
  geofence_radius_m   SMALLINT,                     -- NULL = use tr_settings default
  distance_from_school_km NUMERIC(7,2),
  is_active           BOOLEAN       NOT NULL DEFAULT true,
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_by          BIGINT,
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_by          BIGINT,
  CONSTRAINT fk_stop_stage FOREIGN KEY (stage_id, route_id)
             REFERENCES tr_stage(stage_id, route_id),          -- stage must be of same route
  CONSTRAINT uq_stop_seq   UNIQUE (route_id, stop_seq) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT uq_stop_route UNIQUE (stop_id, route_id),
  CONSTRAINT ck_stop_lat CHECK (latitude  BETWEEN -90  AND 90),
  CONSTRAINT ck_stop_lon CHECK (longitude BETWEEN -180 AND 180)
);
CREATE INDEX ix_stop_route ON tr_stop(route_id, stop_seq);

-- ---------------------------------------------------------------------
-- 3. Vendors (contractors) and Vehicles
-- ---------------------------------------------------------------------
CREATE TABLE tr_vendor (
  vendor_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id          BIGINT        NOT NULL,
  vendor_name      VARCHAR(150)  NOT NULL,
  contact_person   VARCHAR(100),
  mobile           VARCHAR(15),
  email            VARCHAR(120),
  address          TEXT,
  gstin            VARCHAR(15),
  pan              VARCHAR(10),
  bank_account_no  VARCHAR(30),
  bank_ifsc        VARCHAR(11),
  agreement_no     VARCHAR(50),
  agreement_from   DATE,
  agreement_to     DATE,
  is_active        BOOLEAN       NOT NULL DEFAULT true,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_by       BIGINT,
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_by       BIGINT
);

CREATE TABLE tr_vehicle (
  vehicle_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id             BIGINT       NOT NULL,
  vehicle_code        VARCHAR(20)  NOT NULL,          -- e.g. BUS-07 (painted number)
  registration_no     VARCHAR(20)  NOT NULL,
  vehicle_type        VARCHAR(15)  NOT NULL
                      CHECK (vehicle_type IN ('BUS','MINI_BUS','VAN','CAR','AUTO','OTHER')),
  make                VARCHAR(50),
  model               VARCHAR(50),
  manufacture_year    SMALLINT,
  chassis_no          VARCHAR(30),
  engine_no           VARCHAR(30),
  fuel_type           VARCHAR(10)  CHECK (fuel_type IN ('DIESEL','PETROL','CNG','ELECTRIC','HYBRID')),
  colour              VARCHAR(20),
  seating_capacity    SMALLINT     NOT NULL CHECK (seating_capacity > 0),
  permitted_capacity  SMALLINT,                        -- as per permit, if different
  ownership_type      VARCHAR(12)  NOT NULL
                      CHECK (ownership_type IN ('OWNED','CONTRACTED','LEASED','HIRED')),
  vendor_id           BIGINT REFERENCES tr_vendor(vendor_id),
  contract_basis      VARCHAR(12)  CHECK (contract_basis IN ('PER_MONTH','PER_TRIP','PER_KM')),
  contract_rate       NUMERIC(10,2),
  contract_from       DATE,
  contract_to         DATE,
  purchase_date       DATE,
  purchase_cost       NUMERIC(12,2),
  odometer_km         NUMERIC(10,1),
  -- safety fittings (statutory for school buses in many states)
  has_gps             BOOLEAN NOT NULL DEFAULT true,
  has_cctv            BOOLEAN NOT NULL DEFAULT false,
  has_speed_governor  BOOLEAN NOT NULL DEFAULT false,
  has_first_aid       BOOLEAN NOT NULL DEFAULT true,
  has_fire_extinguisher BOOLEAN NOT NULL DEFAULT true,
  has_panic_button    BOOLEAN NOT NULL DEFAULT false,
  status              VARCHAR(12)  NOT NULL DEFAULT 'ACTIVE'
                      CHECK (status IN ('ACTIVE','UNDER_REPAIR','INACTIVE','SOLD','SCRAPPED')),
  photo_url           TEXT,
  remarks             TEXT,
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by          BIGINT,
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_by          BIGINT,
  CONSTRAINT uq_vehicle_reg  UNIQUE (inst_id, registration_no),
  CONSTRAINT uq_vehicle_code UNIQUE (inst_id, vehicle_code),
  CONSTRAINT ck_vendor_needed CHECK (ownership_type = 'OWNED' OR vendor_id IS NOT NULL)
);

-- RC, insurance, fitness, permit, PUC, road tax ... with expiry tracking
CREATE TABLE tr_vehicle_document (
  vehicle_doc_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id         BIGINT       NOT NULL,
  vehicle_id      BIGINT       NOT NULL REFERENCES tr_vehicle(vehicle_id),
  doc_type        VARCHAR(20)  NOT NULL
                  CHECK (doc_type IN ('RC','INSURANCE','FITNESS','PERMIT','PUC','ROAD_TAX',
                                      'SPEED_GOVERNOR','GPS_CERT','FIRE_CERT','OTHER')),
  doc_no          VARCHAR(60),
  issuing_authority VARCHAR(100),          -- RTO / insurer name
  insurance_type  VARCHAR(20),             -- COMPREHENSIVE / THIRD_PARTY (insurance only)
  insured_value   NUMERIC(12,2),
  premium_amount  NUMERIC(10,2),
  issue_date      DATE,
  valid_from      DATE,
  expiry_date     DATE,
  file_url        TEXT,
  is_current      BOOLEAN      NOT NULL DEFAULT true,   -- older renewals kept as history
  remarks         TEXT,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by      BIGINT
);
CREATE INDEX ix_vdoc_expiry ON tr_vehicle_document(inst_id, expiry_date) WHERE is_current;
CREATE UNIQUE INDEX uq_vdoc_current ON tr_vehicle_document(vehicle_id, doc_type)
  WHERE is_current AND doc_type <> 'OTHER';

-- GPS hardware (device can be moved between vehicles -> keep history)
CREATE TABLE tr_gps_device (
  device_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id         BIGINT       NOT NULL,
  device_type     VARCHAR(12)  NOT NULL DEFAULT 'HARDWARE'
                  CHECK (device_type IN ('HARDWARE','MOBILE_APP')), -- AIS-140 box or driver phone
  imei            VARCHAR(20),
  sim_no          VARCHAR(20),
  sim_provider    VARCHAR(30),
  vendor_name     VARCHAR(100),
  protocol        VARCHAR(30),                 -- GT06 / AIS140 / HTTP etc.
  api_key_hash    TEXT,                        -- for authenticating pings
  is_active       BOOLEAN      NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT uq_gps_imei UNIQUE (imei)
);

CREATE TABLE tr_vehicle_gps_device (
  vgd_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id       BIGINT      NOT NULL,
  vehicle_id    BIGINT      NOT NULL REFERENCES tr_vehicle(vehicle_id),
  device_id     BIGINT      NOT NULL REFERENCES tr_gps_device(device_id),
  installed_on  DATE        NOT NULL,
  removed_on    DATE
);
CREATE UNIQUE INDEX uq_vgd_active_device  ON tr_vehicle_gps_device(device_id)  WHERE removed_on IS NULL;
CREATE UNIQUE INDEX uq_vgd_active_vehicle ON tr_vehicle_gps_device(vehicle_id) WHERE removed_on IS NULL;

-- Running cost (for management analysis)
CREATE TABLE tr_fuel_log (
  fuel_log_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id       BIGINT        NOT NULL,
  vehicle_id    BIGINT        NOT NULL REFERENCES tr_vehicle(vehicle_id),
  fill_date     DATE          NOT NULL,
  quantity      NUMERIC(8,2)  NOT NULL,        -- litres / kWh
  rate          NUMERIC(8,2),
  amount        NUMERIC(10,2) NOT NULL,
  odometer_km   NUMERIC(10,1),
  bill_no       VARCHAR(40),
  filled_by_staff_id BIGINT,
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_by    BIGINT
);
CREATE INDEX ix_fuel_vehicle ON tr_fuel_log(vehicle_id, fill_date);

CREATE TABLE tr_vehicle_service (
  service_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id         BIGINT        NOT NULL,
  vehicle_id      BIGINT        NOT NULL REFERENCES tr_vehicle(vehicle_id),
  service_type    VARCHAR(15)   NOT NULL
                  CHECK (service_type IN ('PERIODIC','REPAIR','TYRE','BATTERY','ACCIDENT','OTHER')),
  service_date    DATE          NOT NULL,
  odometer_km     NUMERIC(10,1),
  workshop        VARCHAR(120),
  description     TEXT,
  amount          NUMERIC(10,2),
  next_due_date   DATE,
  next_due_km     NUMERIC(10,1),
  downtime_days   SMALLINT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_by      BIGINT
);
CREATE INDEX ix_service_vehicle ON tr_vehicle_service(vehicle_id, service_date);

-- ---------------------------------------------------------------------
-- 4. Transport staff (driver, attender, ...)
-- ---------------------------------------------------------------------
CREATE TABLE tr_staff (
  staff_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id             BIGINT       NOT NULL,
  employee_id         BIGINT,                        -- link to existing HR/employee master, if any
  staff_code          VARCHAR(20)  NOT NULL,
  staff_type          VARCHAR(12)  NOT NULL
                      CHECK (staff_type IN ('DRIVER','ATTENDER','CONDUCTOR','SUPERVISOR','CLEANER')),
  employment_type     VARCHAR(12)  NOT NULL DEFAULT 'PERMANENT'
                      CHECK (employment_type IN ('PERMANENT','CONTRACT','VENDOR')),
  vendor_id           BIGINT REFERENCES tr_vendor(vendor_id),   -- if supplied by contractor
  full_name           VARCHAR(120) NOT NULL,
  gender              CHAR(1)      CHECK (gender IN ('M','F','O')),
  date_of_birth       DATE,
  blood_group         VARCHAR(4),
  mobile              VARCHAR(15)  NOT NULL,
  alt_mobile          VARCHAR(15),
  address             TEXT,
  id_proof_type       VARCHAR(20),
  id_proof_no_masked  VARCHAR(20),                   -- store masked Aadhaar etc.
  emergency_contact_name  VARCHAR(100),
  emergency_contact_phone VARCHAR(15),
  joining_date        DATE,
  relieving_date      DATE,
  experience_years    SMALLINT,
  police_verified     BOOLEAN      NOT NULL DEFAULT false,
  police_verified_on  DATE,
  photo_url           TEXT,
  app_user_id         BIGINT,                        -- login for driver/attender Flutter app
  status              VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE'
                      CHECK (status IN ('ACTIVE','ON_LEAVE','SUSPENDED','RELIEVED')),
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by          BIGINT,
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_by          BIGINT,
  CONSTRAINT uq_staff_code UNIQUE (inst_id, staff_code),
  CONSTRAINT ck_staff_vendor CHECK (employment_type <> 'VENDOR' OR vendor_id IS NOT NULL)
);

-- Driving licence, badge, medical fitness, police verification, training ...
CREATE TABLE tr_staff_document (
  staff_doc_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id          BIGINT       NOT NULL,
  staff_id         BIGINT       NOT NULL REFERENCES tr_staff(staff_id),
  doc_type         VARCHAR(20)  NOT NULL
                   CHECK (doc_type IN ('DRIVING_LICENCE','PSV_BADGE','MEDICAL_FITNESS',
                                       'POLICE_VERIFICATION','ID_PROOF','TRAINING','OTHER')),
  doc_no           VARCHAR(40),
  licence_class    VARCHAR(30),                 -- LMV / HMV / TRANS (driving licence)
  issuing_authority VARCHAR(100),
  issue_date       DATE,
  expiry_date      DATE,
  file_url         TEXT,
  is_current       BOOLEAN      NOT NULL DEFAULT true,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by       BIGINT
);
CREATE INDEX ix_sdoc_expiry ON tr_staff_document(inst_id, expiry_date) WHERE is_current;

CREATE TABLE tr_staff_leave (
  staff_leave_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id         BIGINT      NOT NULL,
  staff_id        BIGINT      NOT NULL REFERENCES tr_staff(staff_id),
  from_date       DATE        NOT NULL,
  to_date         DATE        NOT NULL,
  reason          TEXT,
  status          VARCHAR(10) NOT NULL DEFAULT 'APPROVED'
                  CHECK (status IN ('APPLIED','APPROVED','REJECTED')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (to_date >= from_date)
);

-- ---------------------------------------------------------------------
-- 5. Trip schedule (template) and duty assignment
--    One route can have several schedules: morning pickup, afternoon drop,
--    KG early drop, Saturday half-day, or 2 buses on a heavy route.
-- ---------------------------------------------------------------------
CREATE TABLE tr_trip_schedule (
  schedule_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id          BIGINT       NOT NULL,
  route_id         BIGINT       NOT NULL REFERENCES tr_route(route_id),
  schedule_code    VARCHAR(20)  NOT NULL,
  schedule_name    VARCHAR(100) NOT NULL,          -- "R5 Morning Pickup - Bus 07"
  direction        VARCHAR(6)   NOT NULL CHECK (direction IN ('PICKUP','DROP')),
  vehicle_id       BIGINT       NOT NULL REFERENCES tr_vehicle(vehicle_id),
  planned_start    TIME         NOT NULL,
  planned_end      TIME         NOT NULL,
  run_days         SMALLINT[]   NOT NULL DEFAULT '{1,2,3,4,5,6}',  -- ISO weekday 1=Mon..7=Sun
  effective_from   DATE         NOT NULL,
  effective_to     DATE,
  is_active        BOOLEAN      NOT NULL DEFAULT true,
  created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by       BIGINT,
  updated_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_by       BIGINT,
  CONSTRAINT uq_schedule_code UNIQUE (inst_id, schedule_code),
  CONSTRAINT uq_schedule_route UNIQUE (schedule_id, route_id)
);

-- Planned time at each stop for this schedule (order reverses for DROP)
CREATE TABLE tr_trip_schedule_stop (
  schedule_id     BIGINT   NOT NULL,
  route_id        BIGINT   NOT NULL,
  stop_id         BIGINT   NOT NULL,
  visit_seq       SMALLINT NOT NULL,
  planned_time    TIME     NOT NULL,
  halt_minutes    SMALLINT NOT NULL DEFAULT 1,
  PRIMARY KEY (schedule_id, stop_id),
  CONSTRAINT fk_tss_schedule FOREIGN KEY (schedule_id, route_id)
             REFERENCES tr_trip_schedule(schedule_id, route_id) ON DELETE CASCADE,
  CONSTRAINT fk_tss_stop FOREIGN KEY (stop_id, route_id)
             REFERENCES tr_stop(stop_id, route_id),          -- stop must belong to the route
  CONSTRAINT uq_tss_seq UNIQUE (schedule_id, visit_seq)
);

-- Default duty roster: who drives / attends a schedule
CREATE TABLE tr_duty_assignment (
  duty_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id         BIGINT      NOT NULL,
  schedule_id     BIGINT      NOT NULL REFERENCES tr_trip_schedule(schedule_id),
  staff_id        BIGINT      NOT NULL REFERENCES tr_staff(staff_id),
  duty_role       VARCHAR(12) NOT NULL
                  CHECK (duty_role IN ('DRIVER','ATTENDER','CONDUCTOR','SUPERVISOR')),
  is_primary      BOOLEAN     NOT NULL DEFAULT true,
  effective_from  DATE        NOT NULL,
  effective_to    DATE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      BIGINT
);
CREATE UNIQUE INDEX uq_duty_one_primary_driver
  ON tr_duty_assignment(schedule_id, duty_role)
  WHERE is_primary AND duty_role = 'DRIVER' AND effective_to IS NULL;

-- ---------------------------------------------------------------------
-- 6. Student transport enrolment
-- ---------------------------------------------------------------------
CREATE TABLE tr_student_enrollment (
  enrollment_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id           BIGINT        NOT NULL,
  acad_year_id      BIGINT        NOT NULL,
  student_id        BIGINT        NOT NULL,          -- existing student master
  route_id          BIGINT        NOT NULL,
  service_type      VARCHAR(10)   NOT NULL DEFAULT 'BOTH'
                    CHECK (service_type IN ('BOTH','PICKUP','DROP')),
  pickup_stop_id    BIGINT,
  drop_stop_id      BIGINT,
  pickup_schedule_id BIGINT,                          -- which bus (if route has >1)
  drop_schedule_id   BIGINT,
  fee_stage_id      BIGINT        NOT NULL,          -- stage used for fee (farthest stop)
  stage_fee_id      BIGINT        REFERENCES tr_stage_fee(stage_fee_id),
  fee_amount        NUMERIC(10,2),                   -- snapshot / after concession
  concession_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
  start_date        DATE          NOT NULL,
  end_date          DATE,
  status            VARCHAR(12)   NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','SUSPENDED','CANCELLED','COMPLETED')),
  rfid_tag          VARCHAR(40),                     -- optional boarding card
  cancel_reason     TEXT,
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_by        BIGINT,
  updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_by        BIGINT,
  CONSTRAINT fk_enr_pickup_stop FOREIGN KEY (pickup_stop_id, route_id) REFERENCES tr_stop(stop_id, route_id),
  CONSTRAINT fk_enr_drop_stop   FOREIGN KEY (drop_stop_id,   route_id) REFERENCES tr_stop(stop_id, route_id),
  CONSTRAINT fk_enr_stage       FOREIGN KEY (fee_stage_id,   route_id) REFERENCES tr_stage(stage_id, route_id),
  CONSTRAINT fk_enr_pick_sched  FOREIGN KEY (pickup_schedule_id, route_id) REFERENCES tr_trip_schedule(schedule_id, route_id),
  CONSTRAINT fk_enr_drop_sched  FOREIGN KEY (drop_schedule_id,   route_id) REFERENCES tr_trip_schedule(schedule_id, route_id),
  CONSTRAINT ck_enr_stops CHECK (
        (service_type = 'BOTH'   AND pickup_stop_id IS NOT NULL AND drop_stop_id IS NOT NULL)
     OR (service_type = 'PICKUP' AND pickup_stop_id IS NOT NULL)
     OR (service_type = 'DROP'   AND drop_stop_id   IS NOT NULL))
);
-- one active enrolment per student per year
CREATE UNIQUE INDEX uq_enr_active ON tr_student_enrollment(student_id, acad_year_id)
  WHERE status = 'ACTIVE';
CREATE INDEX ix_enr_pickup_stop ON tr_student_enrollment(pickup_stop_id) WHERE status = 'ACTIVE';
CREATE INDEX ix_enr_drop_stop   ON tr_student_enrollment(drop_stop_id)   WHERE status = 'ACTIVE';

-- Parent/guardian contacts that receive alerts. If your student master already
-- holds guardian mobiles, keep this only for overrides/preferences.
CREATE TABLE tr_notify_contact (
  contact_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id         BIGINT       NOT NULL,
  student_id      BIGINT       NOT NULL,
  guardian_name   VARCHAR(100),
  relation        VARCHAR(20),
  mobile          VARCHAR(15)  NOT NULL,
  app_user_id     BIGINT,                        -- parent Flutter app login (for push)
  fcm_token       TEXT,
  language_code   VARCHAR(5)   NOT NULL DEFAULT 'en',
  notify_sms      BOOLEAN      NOT NULL DEFAULT true,
  notify_whatsapp BOOLEAN      NOT NULL DEFAULT false,
  notify_push     BOOLEAN      NOT NULL DEFAULT true,
  is_active       BOOLEAN      NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT uq_contact UNIQUE (student_id, mobile)
);

-- Day-wise exceptions: student absent / will not use bus / picked by parent
CREATE TABLE tr_student_trip_exception (
  exception_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id         BIGINT      NOT NULL,
  enrollment_id   BIGINT      NOT NULL REFERENCES tr_student_enrollment(enrollment_id),
  exception_date  DATE        NOT NULL,
  direction       VARCHAR(6)  NOT NULL CHECK (direction IN ('PICKUP','DROP','BOTH')),
  reason          VARCHAR(20) NOT NULL CHECK (reason IN ('ABSENT','PARENT_PICKUP','OTHER')),
  remarks         TEXT,
  created_by      BIGINT,                   -- parent app user or staff
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_stx UNIQUE (enrollment_id, exception_date, direction)
);

-- ---------------------------------------------------------------------
-- 7. Trips (daily instances generated from schedules)
-- ---------------------------------------------------------------------
CREATE TABLE tr_trip (
  trip_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id            BIGINT        NOT NULL,
  schedule_id        BIGINT        NOT NULL REFERENCES tr_trip_schedule(schedule_id),
  route_id           BIGINT        NOT NULL REFERENCES tr_route(route_id),
  trip_date          DATE          NOT NULL,
  direction          VARCHAR(6)    NOT NULL CHECK (direction IN ('PICKUP','DROP')),
  vehicle_id         BIGINT        NOT NULL REFERENCES tr_vehicle(vehicle_id), -- actual (may be substitute)
  planned_start_at   TIMESTAMPTZ   NOT NULL,
  planned_end_at     TIMESTAMPTZ   NOT NULL,
  -- actuals captured from GPS
  actual_start_at    TIMESTAMPTZ,
  actual_end_at      TIMESTAMPTZ,
  start_source       VARCHAR(10)   CHECK (start_source IN ('GPS_AUTO','APP','ADMIN')),
  end_source         VARCHAR(10)   CHECK (end_source   IN ('GPS_AUTO','APP','ADMIN')),
  start_latitude     NUMERIC(9,6),
  start_longitude    NUMERIC(9,6),
  end_latitude       NUMERIC(9,6),
  end_longitude      NUMERIC(9,6),
  start_odometer_km  NUMERIC(10,1),
  end_odometer_km    NUMERIC(10,1),
  gps_distance_km    NUMERIC(8,2),                 -- summed from pings
  max_speed_kmph     NUMERIC(5,1),
  avg_speed_kmph     NUMERIC(5,1),
  planned_students   SMALLINT,                     -- snapshot at trip creation
  boarded_students   SMALLINT,
  status             VARCHAR(12)   NOT NULL DEFAULT 'SCHEDULED'
                     CHECK (status IN ('SCHEDULED','IN_PROGRESS','COMPLETED','CANCELLED','ABORTED')),
  cancel_reason      TEXT,
  last_latitude      NUMERIC(9,6),                 -- denormalised live position
  last_longitude     NUMERIC(9,6),
  last_ping_at       TIMESTAMPTZ,
  next_stop_id       BIGINT REFERENCES tr_stop(stop_id),
  remarks            TEXT,
  created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
  CONSTRAINT uq_trip UNIQUE (schedule_id, trip_date)
);
CREATE INDEX ix_trip_date    ON tr_trip(inst_id, trip_date);
CREATE INDEX ix_trip_vehicle ON tr_trip(vehicle_id, trip_date);
CREATE INDEX ix_trip_live    ON tr_trip(inst_id) WHERE status = 'IN_PROGRESS';

-- Actual crew on the trip (copied from duty roster, editable for substitutes)
CREATE TABLE tr_trip_staff (
  trip_id        BIGINT      NOT NULL REFERENCES tr_trip(trip_id) ON DELETE CASCADE,
  staff_id       BIGINT      NOT NULL REFERENCES tr_staff(staff_id),
  duty_role      VARCHAR(12) NOT NULL
                 CHECK (duty_role IN ('DRIVER','ATTENDER','CONDUCTOR','SUPERVISOR')),
  is_substitute  BOOLEAN     NOT NULL DEFAULT false,
  check_in_at    TIMESTAMPTZ,
  check_out_at   TIMESTAMPTZ,
  PRIMARY KEY (trip_id, staff_id)
);
CREATE INDEX ix_trip_staff_staff ON tr_trip_staff(staff_id);

-- Stop-level progress of a trip: ETA, arrival, departure, alert sent
CREATE TABLE tr_trip_stop (
  trip_id             BIGINT      NOT NULL REFERENCES tr_trip(trip_id) ON DELETE CASCADE,
  stop_id             BIGINT      NOT NULL REFERENCES tr_stop(stop_id),
  visit_seq           SMALLINT    NOT NULL,
  planned_at          TIMESTAMPTZ NOT NULL,
  eta_at              TIMESTAMPTZ,                 -- recomputed on each ping
  eta_updated_at      TIMESTAMPTZ,
  actual_arrival_at   TIMESTAMPTZ,
  actual_departure_at TIMESTAMPTZ,
  delay_minutes       SMALLINT GENERATED ALWAYS AS (
                        (EXTRACT(EPOCH FROM (actual_arrival_at - planned_at)) / 60)::smallint) STORED,
  expected_students   SMALLINT,
  boarded_count       SMALLINT,
  alighted_count      SMALLINT,
  eta_alert_sent_at   TIMESTAMPTZ,                 -- set once -> no duplicate "10 min" SMS
  status              VARCHAR(12) NOT NULL DEFAULT 'PENDING'
                      CHECK (status IN ('PENDING','APPROACHING','ARRIVED','DEPARTED','SKIPPED')),
  PRIMARY KEY (trip_id, stop_id),
  CONSTRAINT uq_trip_stop_seq UNIQUE (trip_id, visit_seq)
);
CREATE INDEX ix_trip_stop_alert ON tr_trip_stop(trip_id)
  WHERE eta_alert_sent_at IS NULL AND status IN ('PENDING','APPROACHING');

-- Student boarding / alighting on the trip (attender app / RFID)
CREATE TABLE tr_trip_student (
  trip_id         BIGINT      NOT NULL REFERENCES tr_trip(trip_id) ON DELETE CASCADE,
  enrollment_id   BIGINT      NOT NULL REFERENCES tr_student_enrollment(enrollment_id),
  student_id      BIGINT      NOT NULL,
  stop_id         BIGINT      NOT NULL REFERENCES tr_stop(stop_id),
  status          VARCHAR(16) NOT NULL DEFAULT 'EXPECTED'
                  CHECK (status IN ('EXPECTED','BOARDED','ALIGHTED','ABSENT','NO_SHOW','PARENT_PICKUP')),
  boarded_at      TIMESTAMPTZ,
  alighted_at     TIMESTAMPTZ,
  marked_by       BIGINT,                          -- tr_staff.staff_id
  mark_method     VARCHAR(8)  CHECK (mark_method IN ('MANUAL','RFID','QR','FACE')),
  PRIMARY KEY (trip_id, enrollment_id)
);
CREATE INDEX ix_trip_student_stu ON tr_trip_student(student_id);

-- Events / exceptions raised during a trip
CREATE TABLE tr_trip_event (
  event_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id       BIGINT       NOT NULL,
  trip_id       BIGINT       NOT NULL REFERENCES tr_trip(trip_id) ON DELETE CASCADE,
  event_type    VARCHAR(20)  NOT NULL
                CHECK (event_type IN ('TRIP_START','TRIP_END','STOP_ARRIVED','STOP_DEPARTED',
                                      'STOP_SKIPPED','OVERSPEED','ROUTE_DEVIATION','LONG_HALT',
                                      'LATE_START','GPS_LOST','SOS','BREAKDOWN','ACCIDENT','OTHER')),
  severity      VARCHAR(8)   NOT NULL DEFAULT 'INFO'
                CHECK (severity IN ('INFO','WARNING','CRITICAL')),
  event_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  stop_id       BIGINT REFERENCES tr_stop(stop_id),
  latitude      NUMERIC(9,6),
  longitude     NUMERIC(9,6),
  speed_kmph    NUMERIC(5,1),
  details       JSONB,
  acknowledged_by BIGINT,
  acknowledged_at TIMESTAMPTZ
);
CREATE INDEX ix_trip_event_trip ON tr_trip_event(trip_id, event_at);
CREATE INDEX ix_trip_event_open ON tr_trip_event(inst_id, event_at)
  WHERE severity <> 'INFO' AND acknowledged_at IS NULL;

-- ---------------------------------------------------------------------
-- 8. GPS data
-- ---------------------------------------------------------------------
-- Raw pings: high volume -> range-partitioned by month
CREATE TABLE tr_gps_ping (
  ping_id       BIGINT GENERATED ALWAYS AS IDENTITY,
  inst_id       BIGINT        NOT NULL,
  device_id     BIGINT        NOT NULL,
  vehicle_id    BIGINT        NOT NULL,
  trip_id       BIGINT,                         -- NULL when no trip in progress
  recorded_at   TIMESTAMPTZ   NOT NULL,         -- device time
  received_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
  latitude      NUMERIC(9,6)  NOT NULL,
  longitude     NUMERIC(9,6)  NOT NULL,
  speed_kmph    NUMERIC(5,1),
  heading_deg   SMALLINT,
  accuracy_m    NUMERIC(6,1),
  altitude_m    NUMERIC(7,1),
  ignition_on   BOOLEAN,
  battery_pct   SMALLINT,
  satellites    SMALLINT,
  raw_payload   JSONB,
  PRIMARY KEY (ping_id, recorded_at)
) PARTITION BY RANGE (recorded_at);
CREATE INDEX ix_ping_vehicle_time ON tr_gps_ping(vehicle_id, recorded_at DESC);
CREATE INDEX ix_ping_trip         ON tr_gps_ping(trip_id, recorded_at) WHERE trip_id IS NOT NULL;

-- Helper to create monthly partitions (call from a monthly cron / pg_cron)
CREATE OR REPLACE FUNCTION transport.fn_create_ping_partition(p_month date)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_from date := date_trunc('month', p_month)::date;
  v_to   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_name text := format('tr_gps_ping_%s', to_char(v_from, 'YYYYMM'));
BEGIN
  EXECUTE format('CREATE TABLE IF NOT EXISTS transport.%I PARTITION OF transport.tr_gps_ping
                  FOR VALUES FROM (%L) TO (%L)', v_name, v_from, v_to);
END $$;
CREATE TABLE tr_gps_ping_default PARTITION OF tr_gps_ping DEFAULT;

-- Latest position per vehicle (upserted on every ping; read by map screens)
CREATE TABLE tr_vehicle_live (
  vehicle_id    BIGINT PRIMARY KEY REFERENCES tr_vehicle(vehicle_id),
  inst_id       BIGINT        NOT NULL,
  trip_id       BIGINT REFERENCES tr_trip(trip_id),
  latitude      NUMERIC(9,6)  NOT NULL,
  longitude     NUMERIC(9,6)  NOT NULL,
  speed_kmph    NUMERIC(5,1),
  heading_deg   SMALLINT,
  ignition_on   BOOLEAN,
  recorded_at   TIMESTAMPTZ   NOT NULL,
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX ix_vehicle_live_inst ON tr_vehicle_live(inst_id);

-- ---------------------------------------------------------------------
-- 9. Notifications
-- ---------------------------------------------------------------------
CREATE TABLE tr_notification_template (
  template_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id         BIGINT       NOT NULL,
  event_code      VARCHAR(20)  NOT NULL
                  CHECK (event_code IN ('ETA_ALERT','TRIP_STARTED','BOARDED','DROPPED',
                                        'REACHED_SCHOOL','DELAY','TRIP_CANCELLED','SOS','DOC_EXPIRY')),
  channel         VARCHAR(10)  NOT NULL CHECK (channel IN ('SMS','WHATSAPP','PUSH','EMAIL')),
  language_code   VARCHAR(5)   NOT NULL DEFAULT 'en',
  dlt_template_id VARCHAR(30),           -- mandatory for transactional SMS in India (TRAI DLT)
  body            TEXT         NOT NULL, -- e.g. 'Dear Parent, bus {vehicle_code} will reach {stop_name} in about {eta_min} min.'
  is_active       BOOLEAN      NOT NULL DEFAULT true,
  CONSTRAINT uq_template UNIQUE (inst_id, event_code, channel, language_code)
);

-- Outbox + delivery log. Worker picks QUEUED rows, sends, updates status.
CREATE TABLE tr_notification_log (
  notification_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  inst_id           BIGINT       NOT NULL,
  event_code        VARCHAR(20)  NOT NULL,
  channel           VARCHAR(10)  NOT NULL CHECK (channel IN ('SMS','WHATSAPP','PUSH','EMAIL')),
  trip_id           BIGINT REFERENCES tr_trip(trip_id),
  stop_id           BIGINT REFERENCES tr_stop(stop_id),
  student_id        BIGINT,
  contact_id        BIGINT REFERENCES tr_notify_contact(contact_id),
  recipient         VARCHAR(200) NOT NULL,     -- mobile / fcm token / email
  template_id       BIGINT REFERENCES tr_notification_template(template_id),
  message_text      TEXT         NOT NULL,
  status            VARCHAR(10)  NOT NULL DEFAULT 'QUEUED'
                    CHECK (status IN ('QUEUED','SENT','DELIVERED','FAILED','SKIPPED')),
  attempts          SMALLINT     NOT NULL DEFAULT 0,
  provider_msg_id   VARCHAR(100),
  error_text        TEXT,
  queued_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
  sent_at           TIMESTAMPTZ,
  delivered_at      TIMESTAMPTZ,
  cost              NUMERIC(8,4)
);
-- Idempotency: one alert of a kind per student/contact/channel per trip
CREATE UNIQUE INDEX uq_notif_once
  ON tr_notification_log(trip_id, student_id, contact_id, channel, event_code)
  WHERE trip_id IS NOT NULL;
CREATE INDEX ix_notif_queue ON tr_notification_log(status, queued_at) WHERE status = 'QUEUED';

-- ---------------------------------------------------------------------
-- 10. updated_at triggers
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['tr_settings','tr_route','tr_stage','tr_stop','tr_vendor','tr_vehicle',
                           'tr_staff','tr_trip_schedule','tr_student_enrollment','tr_trip']
  LOOP
    EXECUTE format('CREATE TRIGGER trg_%s_upd BEFORE UPDATE ON transport.%I
                    FOR EACH ROW EXECUTE FUNCTION transport.fn_set_updated_at()', t, t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- 11. Business functions and analytics views
-- ---------------------------------------------------------------------

-- 11.1 Generate daily trips (+ stops, crew, expected students) from schedules.
--      Run nightly / early morning (pg_cron or backend scheduler).
CREATE OR REPLACE FUNCTION transport.fn_generate_trips(p_inst_id bigint, p_date date)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_count integer := 0; r record; v_trip bigint;
BEGIN
  FOR r IN
    SELECT s.* FROM transport.tr_trip_schedule s
     WHERE s.inst_id = p_inst_id AND s.is_active
       AND p_date >= s.effective_from AND (s.effective_to IS NULL OR p_date <= s.effective_to)
       AND EXTRACT(ISODOW FROM p_date)::smallint = ANY (s.run_days)
       AND NOT EXISTS (SELECT 1 FROM transport.tr_trip t
                        WHERE t.schedule_id = s.schedule_id AND t.trip_date = p_date)
  LOOP
    INSERT INTO transport.tr_trip(inst_id, schedule_id, route_id, trip_date, direction, vehicle_id,
                                  planned_start_at, planned_end_at)
    VALUES (r.inst_id, r.schedule_id, r.route_id, p_date, r.direction, r.vehicle_id,
            p_date + r.planned_start, p_date + r.planned_end)
    RETURNING trip_id INTO v_trip;

    INSERT INTO transport.tr_trip_stop(trip_id, stop_id, visit_seq, planned_at)
    SELECT v_trip, ss.stop_id, ss.visit_seq, p_date + ss.planned_time
      FROM transport.tr_trip_schedule_stop ss WHERE ss.schedule_id = r.schedule_id;

    INSERT INTO transport.tr_trip_staff(trip_id, staff_id, duty_role)
    SELECT v_trip, d.staff_id, d.duty_role
      FROM transport.tr_duty_assignment d
      JOIN transport.tr_staff st ON st.staff_id = d.staff_id AND st.status = 'ACTIVE'
     WHERE d.schedule_id = r.schedule_id
       AND p_date >= d.effective_from AND (d.effective_to IS NULL OR p_date <= d.effective_to)
       AND NOT EXISTS (SELECT 1 FROM transport.tr_staff_leave l
                        WHERE l.staff_id = d.staff_id AND l.status = 'APPROVED'
                          AND p_date BETWEEN l.from_date AND l.to_date);

    -- expected students for this trip (respecting one-way service and day exceptions)
    INSERT INTO transport.tr_trip_student(trip_id, enrollment_id, student_id, stop_id, status)
    SELECT v_trip, e.enrollment_id, e.student_id,
           CASE WHEN r.direction = 'PICKUP' THEN e.pickup_stop_id ELSE e.drop_stop_id END,
           CASE WHEN x.exception_id IS NULL THEN 'EXPECTED'
                WHEN x.reason = 'PARENT_PICKUP' THEN 'PARENT_PICKUP' ELSE 'ABSENT' END
      FROM transport.tr_student_enrollment e
      LEFT JOIN transport.tr_student_trip_exception x
             ON x.enrollment_id = e.enrollment_id AND x.exception_date = p_date
            AND x.direction IN (r.direction, 'BOTH')
     WHERE e.route_id = r.route_id AND e.status = 'ACTIVE'
       AND p_date >= e.start_date AND (e.end_date IS NULL OR p_date <= e.end_date)
       AND e.service_type IN ('BOTH', r.direction)
       AND COALESCE(CASE WHEN r.direction = 'PICKUP' THEN e.pickup_schedule_id
                         ELSE e.drop_schedule_id END, r.schedule_id) = r.schedule_id;

    UPDATE transport.tr_trip_stop ts
       SET expected_students = c.cnt
      FROM (SELECT stop_id, count(*) cnt FROM transport.tr_trip_student
             WHERE trip_id = v_trip AND status = 'EXPECTED' GROUP BY stop_id) c
     WHERE ts.trip_id = v_trip AND ts.stop_id = c.stop_id;

    UPDATE transport.tr_trip
       SET planned_students = (SELECT count(*) FROM transport.tr_trip_student
                                WHERE trip_id = v_trip AND status = 'EXPECTED')
     WHERE trip_id = v_trip;

    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $$;

-- 11.2 Queue "bus arriving in N minutes" alerts for one trip.
--      Called by the GPS ingestion service right after it refreshes tr_trip_stop.eta_at.
--      Idempotent: eta_alert_sent_at + uq_notif_once stop duplicates.
CREATE OR REPLACE FUNCTION transport.fn_queue_eta_alerts(p_trip_id bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_lead smallint; v_rows integer;
BEGIN
  SELECT st.eta_alert_minutes INTO v_lead
    FROM transport.tr_trip t JOIN transport.tr_settings st ON st.inst_id = t.inst_id
   WHERE t.trip_id = p_trip_id AND t.status = 'IN_PROGRESS';
  IF v_lead IS NULL THEN RETURN 0; END IF;

  WITH due AS (
    UPDATE transport.tr_trip_stop ts
       SET eta_alert_sent_at = now(), status = 'APPROACHING'
     WHERE ts.trip_id = p_trip_id
       AND ts.eta_alert_sent_at IS NULL
       AND ts.status = 'PENDING'
       AND ts.eta_at IS NOT NULL
       AND ts.eta_at <= now() + make_interval(mins => v_lead)
    RETURNING ts.trip_id, ts.stop_id, ts.eta_at
  ), ins AS (
    INSERT INTO transport.tr_notification_log
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
      JOIN transport.tr_trip t           ON t.trip_id = d.trip_id
      JOIN transport.tr_vehicle v        ON v.vehicle_id = t.vehicle_id
      JOIN transport.tr_stop s           ON s.stop_id = d.stop_id
      JOIN transport.tr_trip_student tsd ON tsd.trip_id = d.trip_id AND tsd.stop_id = d.stop_id
                                        AND tsd.status = 'EXPECTED'
      JOIN transport.tr_notify_contact c ON c.student_id = tsd.student_id AND c.is_active
      CROSS JOIN LATERAL (VALUES ('SMS', c.notify_sms), ('WHATSAPP', c.notify_whatsapp),
                                 ('PUSH', c.notify_push AND c.fcm_token IS NOT NULL)) ch(channel, wanted)
      JOIN transport.tr_notification_template tpl
           ON tpl.inst_id = t.inst_id AND tpl.event_code = 'ETA_ALERT'
          AND tpl.channel = ch.channel AND tpl.language_code = c.language_code AND tpl.is_active
     WHERE ch.wanted
    ON CONFLICT DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_rows FROM ins;
  RETURN v_rows;
END $$;

-- 11.3 Analytics views -------------------------------------------------

-- Per-trip KPIs
CREATE OR REPLACE VIEW transport.v_trip_summary AS
SELECT t.inst_id, t.trip_id, t.trip_date, t.direction,
       r.route_code, r.route_name, v.vehicle_code, v.registration_no, v.ownership_type,
       v.seating_capacity,
       (SELECT st.full_name FROM transport.tr_trip_staff ts JOIN transport.tr_staff st USING (staff_id)
         WHERE ts.trip_id = t.trip_id AND ts.duty_role = 'DRIVER' LIMIT 1)            AS driver_name,
       t.status, t.planned_start_at, t.actual_start_at, t.planned_end_at, t.actual_end_at,
       ROUND(EXTRACT(EPOCH FROM (t.actual_start_at - t.planned_start_at))/60)        AS start_delay_min,
       ROUND(EXTRACT(EPOCH FROM (t.actual_end_at   - t.planned_end_at))/60)          AS end_delay_min,
       ROUND(EXTRACT(EPOCH FROM (t.actual_end_at   - t.actual_start_at))/60)         AS duration_min,
       t.gps_distance_km, t.max_speed_kmph, t.avg_speed_kmph,
       t.planned_students, t.boarded_students,
       ROUND(100.0 * t.boarded_students / NULLIF(v.seating_capacity,0), 1)            AS occupancy_pct,
       (SELECT count(*) FROM transport.tr_trip_stop s WHERE s.trip_id = t.trip_id)    AS stops_total,
       (SELECT count(*) FROM transport.tr_trip_stop s WHERE s.trip_id = t.trip_id
           AND s.actual_arrival_at IS NOT NULL AND s.delay_minutes <= 5)              AS stops_on_time,
       (SELECT count(*) FROM transport.tr_trip_stop s WHERE s.trip_id = t.trip_id
           AND s.status = 'SKIPPED')                                                  AS stops_skipped,
       (SELECT count(*) FROM transport.tr_trip_event e WHERE e.trip_id = t.trip_id
           AND e.event_type = 'OVERSPEED')                                            AS overspeed_events,
       (SELECT count(*) FROM transport.tr_trip_event e WHERE e.trip_id = t.trip_id
           AND e.severity = 'CRITICAL')                                               AS critical_events
  FROM transport.tr_trip t
  JOIN transport.tr_route   r ON r.route_id   = t.route_id
  JOIN transport.tr_vehicle v ON v.vehicle_id = t.vehicle_id;

-- Route occupancy vs vehicle capacity (use before approving enrolments)
CREATE OR REPLACE VIEW transport.v_schedule_occupancy AS
SELECT s.inst_id, s.schedule_id, s.schedule_code, s.direction, r.route_code,
       v.vehicle_code, v.seating_capacity,
       count(e.enrollment_id)                                                AS enrolled,
       v.seating_capacity - count(e.enrollment_id)                           AS seats_free,
       ROUND(100.0 * count(e.enrollment_id) / NULLIF(v.seating_capacity,0),1) AS occupancy_pct
  FROM transport.tr_trip_schedule s
  JOIN transport.tr_route   r ON r.route_id   = s.route_id
  JOIN transport.tr_vehicle v ON v.vehicle_id = s.vehicle_id
  LEFT JOIN transport.tr_student_enrollment e
         ON e.route_id = s.route_id AND e.status = 'ACTIVE'
        AND e.service_type IN ('BOTH', s.direction)
        AND COALESCE(CASE WHEN s.direction = 'PICKUP' THEN e.pickup_schedule_id
                          ELSE e.drop_schedule_id END, s.schedule_id) = s.schedule_id
 WHERE s.is_active
 GROUP BY s.inst_id, s.schedule_id, s.schedule_code, s.direction, r.route_code,
          v.vehicle_code, v.seating_capacity;

-- Stop-wise punctuality (where are buses consistently late?)
CREATE OR REPLACE VIEW transport.v_stop_punctuality AS
SELECT t.inst_id, r.route_code, s.stop_id, s.stop_name, t.direction,
       count(*)                                          AS visits,
       ROUND(AVG(ts.delay_minutes), 1)                   AS avg_delay_min,
       percentile_cont(0.9) WITHIN GROUP (ORDER BY ts.delay_minutes) AS p90_delay_min,
       ROUND(100.0 * count(*) FILTER (WHERE ts.delay_minutes <= 5) / count(*), 1) AS on_time_pct
  FROM transport.tr_trip_stop ts
  JOIN transport.tr_trip  t ON t.trip_id  = ts.trip_id
  JOIN transport.tr_stop  s ON s.stop_id  = ts.stop_id
  JOIN transport.tr_route r ON r.route_id = t.route_id
 WHERE ts.actual_arrival_at IS NOT NULL
 GROUP BY t.inst_id, r.route_code, s.stop_id, s.stop_name, t.direction;

-- Monthly vehicle utilisation & running cost
CREATE OR REPLACE VIEW transport.v_vehicle_monthly AS
WITH trips AS (
  SELECT vehicle_id, date_trunc('month', trip_date)::date AS month,
         count(*) FILTER (WHERE status = 'COMPLETED') AS trips_completed,
         count(*) FILTER (WHERE status IN ('CANCELLED','ABORTED')) AS trips_lost,
         SUM(gps_distance_km) AS km_run,
         AVG(boarded_students) AS avg_boarded
    FROM transport.tr_trip GROUP BY 1, 2),
fuel AS (
  SELECT vehicle_id, date_trunc('month', fill_date)::date AS month,
         SUM(quantity) AS fuel_qty, SUM(amount) AS fuel_cost
    FROM transport.tr_fuel_log GROUP BY 1, 2),
svc AS (
  SELECT vehicle_id, date_trunc('month', service_date)::date AS month,
         SUM(amount) AS service_cost
    FROM transport.tr_vehicle_service GROUP BY 1, 2)
SELECT v.inst_id, v.vehicle_id, v.vehicle_code, v.ownership_type, tr.month,
       tr.trips_completed, tr.trips_lost, tr.km_run, ROUND(tr.avg_boarded, 1) AS avg_boarded,
       f.fuel_qty, f.fuel_cost, s.service_cost,
       ROUND(tr.km_run / NULLIF(f.fuel_qty, 0), 2)                                 AS km_per_unit,
       ROUND((COALESCE(f.fuel_cost,0) + COALESCE(s.service_cost,0)) / NULLIF(tr.km_run,0), 2) AS cost_per_km
  FROM transport.tr_vehicle v
  JOIN trips tr ON tr.vehicle_id = v.vehicle_id
  LEFT JOIN fuel f ON f.vehicle_id = v.vehicle_id AND f.month = tr.month
  LEFT JOIN svc  s ON s.vehicle_id = v.vehicle_id AND s.month = tr.month;

-- Documents expiring (vehicle + staff) – drives the compliance dashboard
CREATE OR REPLACE VIEW transport.v_document_expiry AS
SELECT d.inst_id, 'VEHICLE' AS owner_type, v.vehicle_code AS owner_ref, v.registration_no AS owner_name,
       d.doc_type, d.doc_no, d.expiry_date, d.expiry_date - CURRENT_DATE AS days_left
  FROM transport.tr_vehicle_document d JOIN transport.tr_vehicle v USING (vehicle_id)
 WHERE d.is_current AND d.expiry_date IS NOT NULL AND v.status = 'ACTIVE'
UNION ALL
SELECT d.inst_id, 'STAFF', s.staff_code, s.full_name,
       d.doc_type, d.doc_no, d.expiry_date, d.expiry_date - CURRENT_DATE
  FROM transport.tr_staff_document d JOIN transport.tr_staff s USING (staff_id)
 WHERE d.is_current AND d.expiry_date IS NOT NULL AND s.status = 'ACTIVE';

-- Stage-wise fee demand for the year (for accounts)
CREATE OR REPLACE VIEW transport.v_fee_demand AS
SELECT e.inst_id, e.acad_year_id, r.route_code, sg.stage_no, sg.stage_name,
       count(*) AS students,
       SUM(e.fee_amount) AS gross_fee, SUM(e.concession_amount) AS concession,
       SUM(e.fee_amount - e.concession_amount) AS net_fee
  FROM transport.tr_student_enrollment e
  JOIN transport.tr_route r  ON r.route_id  = e.route_id
  JOIN transport.tr_stage sg ON sg.stage_id = e.fee_stage_id
 WHERE e.status = 'ACTIVE'
 GROUP BY e.inst_id, e.acad_year_id, r.route_code, sg.stage_no, sg.stage_name;

-- ---------------------------------------------------------------------
-- 12. FKs to your EXISTING masters  (adjust names, then run)
-- ---------------------------------------------------------------------
-- Assumed: public.institution(inst_id), public.academic_year(acad_year_id),
--          public.student(student_id). Uncomment / rename as required.
/*
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['tr_settings','tr_route','tr_stage','tr_stage_fee','tr_stop','tr_vendor',
     'tr_vehicle','tr_vehicle_document','tr_gps_device','tr_vehicle_gps_device','tr_fuel_log',
     'tr_vehicle_service','tr_staff','tr_staff_document','tr_staff_leave','tr_trip_schedule',
     'tr_duty_assignment','tr_student_enrollment','tr_notify_contact','tr_student_trip_exception',
     'tr_trip','tr_trip_event','tr_vehicle_live','tr_notification_template','tr_notification_log']
  LOOP
    EXECUTE format('ALTER TABLE transport.%I ADD CONSTRAINT fk_%s_inst
                    FOREIGN KEY (inst_id) REFERENCES public.institution(inst_id)', t, t);
  END LOOP;
END $$;
ALTER TABLE transport.tr_stage_fee          ADD FOREIGN KEY (acad_year_id) REFERENCES public.academic_year(acad_year_id);
ALTER TABLE transport.tr_student_enrollment ADD FOREIGN KEY (acad_year_id) REFERENCES public.academic_year(acad_year_id);
ALTER TABLE transport.tr_student_enrollment ADD FOREIGN KEY (student_id)   REFERENCES public.student(student_id);
ALTER TABLE transport.tr_notify_contact     ADD FOREIGN KEY (student_id)   REFERENCES public.student(student_id);
ALTER TABLE transport.tr_trip_student       ADD FOREIGN KEY (student_id)   REFERENCES public.student(student_id);
*/

-- ---------------------------------------------------------------------
-- 13. OPTIONAL: PostGIS upgrade (recommended for geofencing at scale)
-- ---------------------------------------------------------------------
/*
CREATE EXTENSION IF NOT EXISTS postgis;
ALTER TABLE transport.tr_stop ADD COLUMN geog geography(Point,4326)
  GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(longitude::float8, latitude::float8),4326)::geography) STORED;
CREATE INDEX ix_stop_geog ON transport.tr_stop USING gist(geog);
ALTER TABLE transport.tr_route ADD COLUMN route_line geography(LineString,4326);
-- Arrival check:  ST_DWithin(stop.geog, ST_MakePoint(lon,lat)::geography, radius_m)
-- Route deviation: ST_Distance(route.route_line, ping_point) > 300
*/
