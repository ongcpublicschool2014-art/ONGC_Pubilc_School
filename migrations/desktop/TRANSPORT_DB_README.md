# Transport module: database

Everything the transport module needs in the database is in this folder, and
these files rebuild it exactly. `transport_db.ps1 -Action check` proves that on
any database that has the module. It was last proved on 2026-11-19 against the
DEMO SCHOOL test project: 949 objects, no differences, API tests 325 of 325.

## Files

| File | What it does | Runs |
|---|---|---|
| `transport_install_order.txt` | The SQL files below in install order, and when each one runs. | |
| `transport_db.ps1` | Install, update, check, test, start a year. Uses the Supabase Management API. | |
| `transport_01_schema.sql` | All transport tables, indexes and views, created in a schema named `transport`. | once |
| `transport_04_move_masters_to_public.sql` | Moves the masters (routes, stages, stops, vendors, vehicles, staff and their documents, settings) to `public`. Renames `transport` to the year schema `transport20262027` (and an old `transport2627` to it). Moves the shared helpers to `transport_core`. | always |
| `transport_05_year_schemas.sql` | Year functions: `create_year_schema`, monthly GPS partitions, daily trip generation, ETA alerts. | always |
| `transport_02_phase1_api.sql` | The app's API (`public.tr_list`, `tr_save`, `tr_delete`, `tr_settings_get`, `tr_settings_save`, `tr_lookups`, `tr_students`, `tr_stage_fee_routes`, `tr_stage_fee_process`; for the parent mobile app `tr_parent_bus`) and the `transport_core` code behind it. Locks every table: RLS on, no grants to app roles. | always |
| `transport_03_admin_menu_access.sql` | Gives the 4 Transport menus to Admin roles that already have a saved menu list. | once |
| `transport_06_vehicle_gps_device_id.sql` | Adds `tr_vehicle.gps_device_id`, linked to `tr_gps_device`. | always |
| `transport_07_staff_license.sql` | Adds licence number, licence type and valid-till date to `tr_staff`. | always |
| `transport_08_gps_device_created_by.sql` | Adds `tr_gps_device.created_by` in every year schema. | always |
| `transport_09_trip_schedules_menu.sql` | Gives the Trip Schedules menu to Admin roles that already have a saved menu list. | once |
| `transport_10_gps_device_to_public.sql` | Moves the GPS devices (`tr_gps_device`) from the year schema to `public`, so they are a master shared by every year, like the vehicles that point at them. | always |
| `transport_11_vehicle_gps_history.sql` | Makes `tr_vehicle_gps_device` the history of which GPS device is on which vehicle: who made or changed a row and when, a device never comes off before it went on, an `updated_at` trigger, indexes. Moves a device chosen on the vehicle form before the GPS Mapping tab into the history. | always |
| `transport_12_duty_roster_menu.sql` | Gives the Duty Roster menu to Admin roles that already have a saved menu list. | once |
| `transport_13_student_enrollment_menu.sql` | Gives the Student Enrollment menu to Admin roles that already have a saved menu list. | once |
| `transport_14_vehicle_allotment_menu.sql` | Gives the Vehicle Allotment menu to Admin roles that already have a saved menu list. | once |
| `transport_15_enrollment_drop_fee_snapshot.sql` | Removes the unused fee snapshot (`stage_fee_id`, `fee_amount`, `concession_amount`) from `tr_student_enrollment` in every year schema. `v_fee_demand` keeps its stage-wise student count without the money columns. | always |
| `transport_16_stage_fee_by_semester.sql` | Drops `tr_stage_fee` in every year schema and makes it again by route, stage, service, fee head (`feetype`) and semester (the school app's `semester` table of the same year). Its old rows are deleted. | always |
| `transport_17_stage_fees_menu.sql` | Gives the Stage Fees menu to Admin roles that already have a saved menu list. | once |
| `transport_18_stage_fee_demand.sql` | Adds `tr_stage_fee_demand` in every year schema: each fee demand the Stage Fee Process made or updated (term, fee type, route, stage fee, `dem_id`, amount, who and when). | always |
| `transport_19_vehicle_service_year.sql` | Adds `tr_vehicle_service.acad_year_id`, the academic year of each service record (key to `institutionyear`). Rows already there get their year from the service date. | always |
| `transport_20_vehicle_fuel_required.sql` | Makes `tr_vehicle.fuel_type` compulsory (`NOT NULL`). A vehicle with no fuel stops the run, named, and nothing is changed: set its fuel in Transport -> Vehicles, then run again. | always |
| `transport_21_vehicle_additional_capacity.sql` | Adds `tr_vehicle.additional_capacity` (small children a vehicle may take beyond its seats; 0 by default, never negative) and makes `v_schedule_occupancy` of every year schema count a vehicle's capacity as seats + additional. | always |
| `transport_22_audit_columns.sql` | Adds who made / last changed a record, and when, to the 12 transport tables that lacked some of it (`created_by`, `updated_at`, `updated_by`), with the `updated_at` triggers; in public and in every year schema. | always |
| `transport_02_phase1_tests.sql` | API tests (325 checks). They always roll back. Not part of the install. | |

`once` files run only on a new install. `always` files run on install and
again on every update, so they must be safe to run twice.

## Before installing on another database

The main FIT School database must already be set up there. The transport
module uses these objects from it:

- `public.session_context(text)` and `public._role_can(...)` for sign-in and menu access
- the tables `public.institutionyear`, `public.feetype`, `public.rolemenuaccess` and `public.institutionusers`
- for Student Enrollment (read only): each academic year's student table, in the
  schema named by `institutionyear.iyrschema` (e.g. `ongc20262027.students`:
  `stu_id`, `ins_id`, `stuadmno`, `stuname`, `stuclass`, `cla_id`,
  `activestatus`), and `public.class` (`cla_id`, `cour_id`, `ordid`) for the
  class order. A year without a student table shows a readable error.
- for the stage fees: each academic year's semester table in the same schema
  (e.g. `ongc20262027.semester`: `sem_id`, `ins_id`). `tr_stage_fee.sem_id` is a
  foreign key to it, and `tr_stage_fee.fee_id` to `public.feetype`.
- for the Stage Fee Process (it WRITES the school app's fee demands): each
  academic year's `feedemand` and `classfeedemand` in the same schema, and the
  student table's `inscode`, `yr_id`, `yrlabel`, `courname` and `con_id`. It
  adds and updates `feedemand` rows the way the fee screens do
  (`add_student_fee_demand`, `rebuild_demand`): never below paid + concession.
  It calls `public._school_assert_year_open` when the database has it.
- the storage bucket `InstitutionLogos` (public read, anon upload). Staff photos
  and document attachments go into its `transport/` folder.

`-Action install` checks for all of these before it changes anything.

## Install on a new database

You need a personal access token (Supabase → Account → Access Tokens) and the
project ref, which is the 20-letter id in the project URL.

```powershell
$env:SUPABASE_ACCESS_TOKEN = 'sbp_...'
.\migrations\desktop\transport_db.ps1 -Action install -ProjectRef <ref>
```

All the files run in one transaction, so if anything fails nothing is kept.
The script shows the project name and asks before it changes anything.

To install without the script, open the Supabase SQL Editor and run each file
listed in `transport_install_order.txt`, from top to bottom. Run each file as
a whole.

After installing:

1. **Start the school's year if it isn't 2026-2027.** The first year schema is
   always `transport20262027`. For any other year, run
   `-Action year -Year 2027-2028`. It copies the structure with no rows. Start
   the year in the school app first: the new year's stage fees use its
   semesters (e.g. `ongc20272028.semester`), and the script stops if there are none.
2. **Check the menus.** Admin roles with a saved menu list get the Transport
   menus from files 03, 09, 12, 13, 14 and 17. Grant other roles in Setup → Roles & Access.
3. **Point the app at the database** (`config.json` next to the exe), then sign in.

## Update a database that already has transport

```powershell
.\migrations\desktop\transport_db.ps1 -Action update -ProjectRef <ref>
```

This runs every `always` file again, in one transaction. It doesn't run the
`once` files.

A `once` file added after a database got transport (such as 09, 12, 13 and
14, the Trip Schedules, Duty Roster, Student Enrollment and Vehicle Allotment
menus) is not run by update. Run that file once on the database yourself (SQL Editor, the whole
file), or grant the menu in Setup → Roles & Access instead.

## One script to run by hand

Without the Management API (no access token), the install and the update can
be run as one `.sql` file each in the Supabase SQL Editor or with `psql`:

```powershell
.\migrations\desktop\transport_db.ps1 -Action script
```

This writes, from the files in `transport_install_order.txt`:

- `single\transport_full_install.sql`: every file in order, for a database
  without transport (the same SQL as `-Action install`).
- `single\transport_update.sql`: the `always` files in order, for a database
  that has transport (the same SQL as `-Action update`).

Each is one transaction (`BEGIN` … `COMMIT`: all or nothing) and first stops,
changing nothing, if it is run on the wrong kind of database. With `psql`, add
`-v ON_ERROR_STOP=1`. Don't edit them: change the files and run
`-Action script` again. (Proved 2026-11-19 on DEMO SCHOOL: the update ran as a
file; the install ran in full on a moved-aside copy inside a transaction that was
rolled back, and refused the real database because transport is on it.)

## Check and test

```powershell
.\migrations\desktop\transport_db.ps1 -Action check -ProjectRef <ref>
.\migrations\desktop\transport_db.ps1 -Action test  -ProjectRef <ref>
```

- **check** installs the module from the files inside a transaction that is
  always rolled back. It then compares every schema, table, column, constraint,
  index, trigger, view, function, grant, RLS setting and owner with the live
  database. "No differences" means the files are complete. Transport calls in
  the app wait a few seconds while it runs.
- **test** runs `transport_02_phase1_tests.sql`, which is rolled back. It uses
  school `ins_id` 1 and the years 2026-2027 and 2025-2026, so it's meant for
  the test database.

## Rules for every database change

1. **Write the change in a file first.** That covers anything in the database
   that belongs to transport: schemas, tables, columns, indexes, functions,
   grants and data fixes. Then apply it from the file, never by hand.
2. **Change functions where they live.** API functions are in
   `transport_02_phase1_api.sql` and year functions are in
   `transport_05_year_schemas.sql`. Edit them there, then run `-Action update`.
3. **Put everything else in a new numbered file.** Name it
   `transport_NN_<what>.sql` with the next number, and add it at the end of
   `transport_install_order.txt`.
   - Mark it `always` if it can be re-run safely, using `IF NOT EXISTS` or
     guarded `DO` blocks. This should be the usual case.
   - Mark it `once` only for a one-time data step that must not run twice.
   - Wrap it in `BEGIN; … COMMIT;`.
   - Don't edit a numbered file after it has been applied to a database. Add a
     new file instead.
4. **Change every year schema, not just one.** For year tables such as
   `transport20262027`, loop over every schema matching `^transport\d{8}$` (file 08
   shows how). New years copy the latest year's structure.
5. **Test new API behaviour.** Add a check for it to
   `transport_02_phase1_tests.sql`.
6. **Confirm after applying.** `-Action check` must report "No differences" and
   `-Action test` must report TESTS_OK.

## Change log

| Date | File | Change |
|---|---|---|
| 2026-11-06 | 01, 03 | Module created: tables, indexes, views; Transport menus for Admins. |
| 2026-11-07 | 04, 05 | Masters moved to `public`; one schema per academic year; `transport_core`. |
| 2026-11-11 | 06 | `tr_vehicle.gps_device_id` added (can be empty), linked to `tr_gps_device`. |
| 2026-11-11 | 07 | `tr_staff.license_number`, `license_type` and `license_valid_till` added. `photo_url` already existed. |
| 2026-11-11 | 08 | `tr_gps_device.created_by` added (needed by `tr_save`). |
| 2026-11-11 | 02 | New `gps_device` record type. Vehicle GPS device, staff licence and photo, and document attachment (`file_url`) can be saved. A file or photo link is accepted only if it is the app's own upload. |
| 2026-11-11 | 02 tests | Fixed broken table names and failure messages. Tests no longer assume an empty database. 11 checks added for the items above. |
| 2026-11-12 | 02 | New `schedule` record type for the Trip Schedules screen: a trip schedule (`tr_trip_schedule`) saved together with its stops (`tr_trip_schedule_stop`). Every stop must be an active stop of the schedule's route, listed once, with a time between the start and end time, in visit order. The list returns each schedule with its stops. Delete switches a schedule off, and is refused while students are enrolled on it. The Trip Schedules menu may list routes, stops and vehicles, but not change them. |
| 2026-11-12 | 09 | Trip Schedules menu for Admin roles with a saved menu list. |
| 2026-11-12 | 02 tests | 29 checks for schedules, including the day's trip stops (`tr_trip_stop`) made from them. |
| 2026-11-12 | 10 | `tr_gps_device` moved from `transport2627` to `public` with its rows, ID sequence, IMEI rule, `created_by` and both vehicle links. New years get no copy; an empty copy in an older-started year is dropped. Fixes the 2027-2028 GPS device rollover limit. |
| 2026-11-12 | 02 | `gps_device` is a master: listed and saved in `public` whatever the session year, and the vehicle's GPS device is checked there. Locked with the other masters. |
| 2026-11-12 | 02 tests | GPS device checks read `public`; 4 checks added (in `public`, no copy in a new year, the same devices in every year, both vehicle links point at `public`). |
| 2026-11-12 | 11 | `tr_vehicle_gps_device` gets `created_at`, `created_by`, `updated_at`, `updated_by`, the rule `ck_vgd_dates` (removed on or after installed), an `updated_at` trigger and indexes by vehicle and by device. Devices already chosen on the vehicle form become history rows; `tr_vehicle.gps_device_id` then matches the history. |
| 2026-11-12 | 02 | New `vehicle_gps` record type for the GPS Mapping tab (Vehicles menu). The tab's changes are saved together: a device goes on, comes off, is replaced, or the day it went on is corrected; one save can move a device to another vehicle or swap two. Nothing is deleted: a device that comes off keeps its row with `removed_on`. A vehicle's history, and a device's, never overlap. Refused: a switched-off device, a device still on another vehicle, a sold, scrapped or inactive vehicle, a future date, and a change someone else saved meanwhile. `tr_vehicle.gps_device_id` follows the history and is no longer saved from the vehicle form; GPS cannot be turned off on a vehicle that has a device on it. |
| 2026-11-12 | 02 tests | 24 checks for GPS Mapping (section 15, and the vehicle form in section 13). |
| 2026-11-13 | 02 | New `duty` record type for the Duty Roster screen: who drives or attends a trip schedule (`tr_duty_assignment`), from a date, to a date or open. Every duty is a main one (`is_primary` is not written). Refused: an end before the start, a switched-off schedule, a staff member who is not active, a Driver duty for staff who are not drivers, the same person twice on a schedule for overlapping dates, a second driver on a schedule for overlapping dates, and one person on two schedules that share a day and overlap in time. Delete removes the duty; trips already made keep their crew. The Duty Roster menu may list schedules and staff, but not change them. |
| 2026-11-13 | 12 | Duty Roster menu for Admin roles with a saved menu list. Applied by hand to DEMO SCHOOL. |
| 2026-11-13 | 02 tests | 19 checks for the duty roster (section 16), including the day's trip crew (`tr_trip_staff`) made from it. |
| 2026-11-13 | 02 | New `enrollment` record type for the Student Enrollment screen (`tr_student_enrollment`). Listed a route at a time, in the session year, with each student's admission number, name, class and status read from the year's student table. Saved only as the screen's batch (`_enrollment_save`): each row needs the stops its trip type uses (Both: pickup and drop; Pickup or Drop: that one; the other is cleared), each a stop of the route and switched on unless already saved; a start date; an end date not before it; both within the academic year; one active enrollment per student in the year; and no change by someone else meanwhile (`updated_at`). Errors name the student. The fee stage is the stage of the farther stop. Never deleted: a student who stops travelling is Cancelled. New door `public.tr_students`: the year's active students in class order, with the route each is active on, and the year's first and last day. The Student Enrollment menu may list routes, stages and stops. |
| 2026-11-13 | 13 | Student Enrollment menu for Admin roles with a saved menu list. Applied by hand to DEMO SCHOOL. |
| 2026-11-13 | 02 tests | 23 checks for student enrollment (section 17), including the day's trip that expects the student (`tr_trip_student`). |
| 2026-11-13 | 02 | New `allotment` record type for the Vehicle Allotment screen: the same rows as `enrollment`, listed the same way. Saved only as the screen's batch (`_allotment_save`), which sets the vehicle a student travels in one way: a trip schedule of the route in that direction, switched on, kept as `pickup_schedule_id` or `drop_schedule_id` (none: not allotted). Each row must be an active enrollment of the route and year that travels that way, unchanged by anyone else meanwhile (`updated_at`). Refused: a vehicle that would have more active students than its `seating_capacity` (the error names the vehicle and trip). Never deleted. The Vehicle Allotment menu may list routes, stops, schedules and vehicles. |
| 2026-11-13 | 14 | Vehicle Allotment menu for Admin roles with a saved menu list. Applied by hand to DEMO SCHOOL. |
| 2026-11-13 | 02 tests | 17 checks for vehicle allotment (section 18), including the day's trips, which expect each student only in their own vehicle. |
| 2026-11-16 | 15 | `tr_student_enrollment.stage_fee_id`, `fee_amount` and `concession_amount` removed in every year schema (nothing read or wrote them; no row had a value on DEMO SCHOOL). The fee stage stays in `fee_stage_id`, the stage fees in `tr_stage_fee`. `v_fee_demand` made again without `gross_fee`, `concession` and `net_fee`: the stage-wise count of active students. |
| 2026-11-16 | 02 tests | 1 check: no year schema, old or newly started, has the fee snapshot columns, and a new year still gets `v_fee_demand`. |
| 2026-11-16 | 16 | `tr_stage_fee` dropped and made again in every year schema (it was empty on DEMO SCHOOL): `stage_fee_id`, `route_id`, `stage_id`, `service_type` (Both / Pickup / Drop), `fee_id` (→ `public.feetype`), `sem_id` (→ the school app's `semester` of the same year, e.g. `ongc20262027.semester`), `amount` (not negative), `effective_from`, `effective_to`, `activestatus` (default 1), `created_at`, `created_by`; one fee per stage, service, semester and start date (`uq_stage_fee`). Gone: `inst_id`, `acad_year_id`, `fee_frequency`, `fee_head_id`. IDs carry on. |
| 2026-11-16 | 05 | New `transport_core._app_year_schema`: the school app's schema for a transport year (from `institutionyear.iyrschema`). `create_year_schema` points a new year's semester key at the new year's semester table, and stops if the school app has not started that year. |
| 2026-11-16 | 02 | `stage_fee` follows the new table: writes `route_id`, `stage_id`, `service_type`, `fee_id`, `sem_id`, `amount`, `effective_from`, `effective_to` and `activestatus`. Route, stage, fee type, semester, amount and start date are required. The stage must be on the route, the fee type the school's, and the semester the school's in the session year. `activestatus` must be 0 or 1. A second fee for the same stage, service, semester and start date is refused by name. A stage fee belongs to the school of its route (new `transport_core._of_school`, used by list, save and delete). The list filters by any written column, `route_id` included. |
| 2026-11-16 | 02 tests | 16 checks: the stage fee rules above, another school's stage fees out of reach, the semester keys of the year and of a newly started year, no old columns left, and a year the school app has not started is refused. The year-start checks now start 2025-2026 (in the school app, not in transport) instead of 2098-2099. |
| 2026-11-16 | 02 | Stage fees belong to the new Stage Fees menu (was Routes & Stops); that menu may list routes and stages. New batch for the Stage Fees screen (`_stage_fee_save`, `tr_save 'stage_fee'` with `fees`): one route, term (`sem_id`) and way, with one fee type and Effective From / To for every stage sent; an empty amount removes the stage's fee. Refused: a route or term not of the school (the term from the session year), dates outside the term or To before From, a fee type that is not the school's, switched on and fee category `TRA`, a stage not on the route or listed twice, a new fee on a switched-off stage, a negative amount, a `stage_fee_id` that is not that stage's for the term and way, and a second fee of a stage for the same term, way and start date. All or nothing; errors name the stage. The one-row `stage_fee` save also takes only `TRA` fee types, and says "term" for the semester. `tr_lookups` now gives only the `TRA` fee types (with `feeshort`) and the year's `terms` (`sem_id`, `semname`, `semshort`, `semstart`, `semend`, switched on, in order). |
| 2026-11-16 | 17 | Stage Fees menu for Admin roles with a saved menu list. Applied by hand to DEMO SCHOOL. |
| 2026-11-16 | 02 tests | 18 checks for the Stage Fees batch (section 19): new, changed and removed fees, each refusal above, all or nothing, the Accountant refused, and the lookups' terms and `TRA` fee types. |
| 2026-11-16 | 02 | Stage Fees, Copy from Term for all routes (`_stage_fee_copy`, `tr_save 'stage_fee'` with `copy_from` and `sem_id`): the newest fee of each stage and way in one term is copied to another term of the session year, for every route of the school, with the same fee type and amount and the new term's dates (its first to its last day). A stage that already has a fee in the new term for that way keeps it, so running it again copies nothing. Left out: switched-off routes and stages, and fee types that are switched off or not `TRA`. Refused: the same term, a term not of the school in the session year, and a new term with no start date. Returns the number copied. (Copying one route into the screen is done by the app and saved with the batch.) |
| 2026-11-16 | 02 tests | 5 checks for Copy from Term: copied with the new term's dates, an existing fee kept, nothing copied twice, the same term and an unknown term refused, the Accountant refused. |
| 2026-11-16 | 02 | `_stage_fee_copy` (Copy from Term for all routes, above) dropped again (`DROP FUNCTION IF EXISTS`): not wanted. The Stage Fees screen's Copy to Term copies the open route's saved fees of the chosen fee type and way to the same route, fee type and way of another term, with that term's dates, using the `_stage_fee_save` batch (a fee that term already has for the stage is updated). |
| 2026-11-16 | 02 tests | The 5 Copy from Term checks replaced by 2 for Copy to Term: saved into the other term with its dates, an existing fee there updated (not doubled), and the first term's fees unchanged. |
| 2026-11-16 | 18 | `tr_stage_fee_demand` in every year schema: one row per fee demand (`dem_id`, unique; no foreign key, `feedemand` belongs to the fee screens) the Stage Fee Process made or updated, with the term (`sem_id`, key to the school app's semester of the year), fee type (`fee_id`), route, stage fee (`stage_fee_id`, key), amount, `processed_at` and `processed_by`. |
| 2026-11-16 | 02 | Stage Fee Process (Stage Fees screen, Process Fees). `tr_stage_fee_routes`: the school's routes for a term and fee type, with their students, the stages that have a fee, and the fee demands already made from them (the processed tick). `tr_stage_fee_process` (`sem_id`, `fee_id`, `route_ids`): for each student with active transport on a ticked route in the term, the stage fee of their stage and way; their class's fee for the term and fee type in `classfeedemand` (none: left out, with a message); their fee demand of the term and fee type (not an arrear) updated to that amount, or made (`REGULAR`, due date from the class fee). A fee below paid + concession is refused for that student and the demand kept. Every demand made or updated goes into `tr_stage_fee_demand`. Each student on their own: one refusal does not stop the rest. Can run again. A stage fee that has been billed cannot be removed (`_stage_fee_save`, `remove`). |
| 2026-11-16 | 02 tests | 21 checks for the Stage Fee Process (section 20): the route list, new demands with the right amount, way, year, class fee and maker, a student whose class has no class fee and a route with nobody reported, kept in `tr_stage_fee_demand`, a second run changing nothing, a raised fee leaving the balance over what is paid, a fee below what is paid refused, a billed stage fee not removable, and the refusals (no route, another school's route, no term, a non-`TRA` fee type, the Accountant). |
| 2026-11-17 | 19 | `tr_vehicle_service.acad_year_id` added: `INTEGER NOT NULL`, key `fk_service_year` to `institutionyear(iyr_id)` (the same value as `tr_student_enrollment.acad_year_id`), index `ix_service_year (acad_year_id, vehicle_id)`. Rows already there get the year of their school that covers the service date; a row outside every year stops the run with its `service_id`, and nothing is changed. DEMO SCHOOL had no rows. |
| 2026-11-17 | 02 | New record type `vehicle_service` (`tr_vehicle_service`, the Vehicles screen's Service tab; Vehicles menu) for `tr_list`, `tr_save`, `tr_delete`. Listed for the session's academic year only, latest service first. A new record gets the session's year (the caller cannot choose it); a record of another year cannot be changed or deleted from this one. Refused, with a reason: a service date outside the year, a negative odometer, amount, downtime or next due km, a next due date before the service date, a next due km below the odometer, an unknown service type, another school's vehicle. |
| 2026-11-17 | 02 tests | 15 checks for vehicle service (section 21): the session's year, school and maker written whatever the caller sends, the list and its order, another year neither listing, changing nor deleting a record, an edit keeping the rest, each refusal above, the Accountant refused, delete. |
| 2026-11-18 | 02 | New record type `fuel_log` (`tr_fuel_log`, a year table, the Vehicles screen's Fuel tab; Vehicles menu) for `tr_list`, `tr_save`, `tr_delete`. It lives in the session year's schema, so another year neither lists, changes nor deletes it; latest fill first. The fill date must fall in the session's academic year. The amount is as on the bill; left empty, it is quantity × rate (rounded to paise), and with no rate either it is refused. Refused, with a reason: no vehicle, fill date or quantity, a quantity of zero or less, a negative rate, amount or odometer, another school's vehicle or staff member (`filled_by_staff_id`). The schema is unchanged. `tr_list 'staff'` is now also allowed for the Vehicles menu (to pick who filled the fuel), list only: saving staff still needs Transport Staff. |
| 2026-11-18 | 02 tests | 20 checks for the fuel log (section 22): school, maker, bill number (trimmed), amount and filled by written, an empty amount worked out from the rate, the list and its order, another year neither listing, changing nor deleting an entry, an edit keeping the rest, each refusal above, the Accountant refused, a Vehicles-only role listing the staff but not saving them, delete. |
| 2026-11-18 | 20 | `tr_vehicle.fuel_type` made `NOT NULL` (the check `tr_vehicle_fuel_type_check` is unchanged: `DIESEL`, `PETROL`, `CNG`, `ELECTRIC`, `HYBRID`). No fuel is guessed: vehicles with none stop the run, listed with their school, and nothing is changed. DEMO SCHOOL had none. File 01 is not changed (it runs only on a new install, and 20 runs after it). |
| 2026-11-18 | 02 | `vehicle` record type: the fuel type is required ("Enter the fuel type."), also when an edit clears it; an unknown fuel reads "Choose the fuel: Diesel, Petrol, CNG, Electric or Hybrid." |
| 2026-11-18 | 02 tests | 3 checks for the compulsory fuel (section 2): missing, unknown, and cleared on an edit. Every vehicle the tests make now has a fuel. |
| 2026-11-18 | 21 | `tr_vehicle.additional_capacity` added: `SMALLINT NOT NULL DEFAULT 0`, check `ck_vehicle_additional` (`>= 0`). It is how many students more than its seats a vehicle may take, for small children (three small children on a two-seat bench: 1). Vehicles already there get 0. `v_schedule_occupancy` made again in every year schema (`CREATE OR REPLACE`, so its columns keep their names and order): `seats_free` and `occupancy_pct` now from seats + additional, and two columns added at the end, `additional_capacity` and `capacity` (seats + additional). New years copy it. |
| 2026-11-18 | 02 | `vehicle` record type writes `additional_capacity`: left empty it is 0; more than the seating capacity is refused ("The additional capacity cannot be more than the seating capacity."), a negative one reads "The additional capacity cannot be negative." Vehicle Allotment (`_allotment_save`): a vehicle's capacity is its seats + additional capacity; over it, the message names the capacity, e.g. "would have 4 students for a capacity of 3 (2 seats + 1 additional)" (with no additional it still says "for 2 seats"). |
| 2026-11-18 | 02 tests | 8 checks for the additional capacity: 0 for a new vehicle, saved, an empty value made 0, negative and more than the seats refused (section 2); in Vehicle Allotment the van with 2 seats + 1 additional takes a third student, refuses a fourth naming the capacity, and `v_schedule_occupancy` counts the same capacity (section 18). |
| 2026-11-19 | 22 | Audit columns added (all `BIGINT` for who, `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`). public: `tr_settings.created_by`; `tr_gps_device`, `tr_vehicle_document`, `tr_vehicle_service`, `tr_staff_document` get `updated_at`, `updated_by`. Every year schema: `tr_stage_fee`, `tr_fuel_log`, `tr_duty_assignment`, `tr_student_trip_exception` get `updated_at`, `updated_by`; `tr_staff_leave`, `tr_notify_contact` get `created_by`, `updated_at`, `updated_by`; `tr_trip` gets `created_by`, `updated_by` (it had `updated_at`). Each new `updated_at` has a trigger `trg_<table>_upd` (`transport_core.fn_set_updated_at`), like the tables that had one, and starts as the row's `created_at` (rows already there; DEMO SCHOOL: 16 stage fees, 3 duties, 1 staff document). No foreign keys on the who columns, as on the rest. New years copy the columns and triggers. (The request listed `tr_vehicle_document` under transport2627; it is a master in public since file 04, so it is changed there.) |
| 2026-11-19 | 02 | Changes now say who made them: `updated_by` is written by `tr_save` for stage fees, vehicle and staff documents, GPS devices, vehicle service, fuel entries and duties (`has_upd` no longer off for them), by the Stage Fees batch (`_stage_fee_save`) when it changes a fee, and on the old document a new current one replaces. A school's settings row, made on first use, gets `created_by`. Not written by the app yet (no screen or API writes them): `tr_staff_leave`, `tr_notify_contact`, `tr_student_trip_exception`; `tr_trip` is made by the trip job (`fn_generate_trips`), which has no user, so its `created_by` stays empty. |
| 2026-11-19 | tool | `transport_db.ps1 -Action script` writes `single\transport_full_install.sql` and `single\transport_update.sql` (one file each, one transaction, a guard for the wrong kind of database); see "One script to run by hand". No project or token needed for it. |
| 2026-11-19 | 02 tests | 7 checks (section 23, and one in 19): every listed column and `updated_at` trigger is there, the trigger sets the time whatever a change sends, a new record has no `updated_by`, each change above writes the session's user, the Stage Fees batch change, and a new settings row's `created_by`. |
| 2026-11-20 | 04, 05, loops | Year schemas named like the school app's (`ongc20262027`): `transport<yyyy><yyyy>`, so 2026-2027 is `transport20262027` (was `transport2627`). `transport_core.year_schema` gives the new name (a 2-digit end year such as `2026-27` or `2099-00` becomes 2027 / 2100); `_check_year_schema`, `create_year_schema` and the year loops of files 02, 10, 15, 16, 18, 21 and 22 match `^transport\d{8}$`. File 04 first renames any old `transport<yy><yy>` schema (rows, keys, views and grants go with it), so `-Action update` moves a database across. `transport_db.ps1` knows both names. |
| 2026-11-20 | 02 tests | `year_schema` checks use the new names, plus `2099-00` -> `transport20992100`. |
| 2026-11-20 | 02 | `public.tr_parent_bus(p_token, p_stu_id)` for the parent mobile app's bus map (`transport_core.parent_bus`): a parent session only (`app_session.par_id`, via `_online_who`), the child must be the parent's (`parentdetail`, `_online_parent_owns`); the school year covering today. Returns the child's route, its stops in pickup order (active ones, plus the child's own; pickup / drop marked, with positions) and the child's pickup and drop trips: schedule times, whether it runs today, today's trip status and next stop, the vehicle (today's trip's, else the schedule's) and its last position from `tr_vehicle_live`. Transport switched off in Module Control (`modules` TRN `activestatus` 0) -> `{"enabled": false}`; no active transport (or it ended) -> `{"enrolled": false}`. Granted to anon / authenticated like the other `tr_*`; the checks are inside. |
| 2026-11-20 | 02 tests | Section 24, 10 checks: the child's route, stop marked with its position, stops in order, the trip with vehicle and position; refused for another child, a staff session and a bad token; no position -> `live` null; ended transport -> not enrolled; Transport off -> not enabled. |
| 2026-11-20 | 08 | Its year-schema loop matched `^transport[0-9]{4}$` (written with `[0-9]`, so the rename above missed it): a new install skipped `tr_gps_device.created_by`. Now `^transport[0-9]{8}$`. Found by running the school setup script on an empty database and comparing it with live. |
| 2026-11-20 | 05, 02 | GPS positions from the trackers: `transport_core.gps_ingest(p)` (05) finds the device by IMEI (active), its vehicle on that day (GPS Mapping history, else `tr_vehicle.gps_device_id`) and the year schema covering that day; keeps the ping in `tr_gps_ping`, makes it the vehicle's `tr_vehicle_live` when newer, and moves today's trip in progress (`last_*`). Skips (and names) an unknown / switched-off device, a device on no vehicle, a 0 / 0 or out-of-range position, a clock more than 10 minutes ahead, a position older than 7 days. `public.tr_gps_ingest(p_positions)` (02) takes one position or a list (500 at most) and is granted to **service_role only**: it is called by the Edge Function `supabase/functions/gps-ingest` (setup in its README). |
| 2026-11-20 | 02 tests | Section 25, 7 checks: the vehicle's position from a list of 6 (older kept but not live; 4 skipped with their reasons), the ping's details, service role only, a single position, a switched-off device. 342 checks. |

## Known limits

- **The first year schema is always `transport20262027`.** File 04 names it that
  whatever year the module is installed in.
- **Stage fees follow one school's semesters per year.** `tr_stage_fee` has no
  `inst_id`, and its `sem_id` key can point at only one semester table. If
  more than one school works in the same year on a database, files 05 and 16
  stop with a readable error.
- **Uploaded files are public by link.** Staff photos and document attachments
  are in the public `InstitutionLogos` bucket, so anyone with a file's link can
  open it.
