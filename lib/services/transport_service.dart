import 'supabase_service.dart';

/// The transport module's only way to the server: the public.tr_* functions
/// (migrations/desktop/transport_02_phase1_api.sql). The server takes the
/// school and academic year from the session token, never from these calls.
class TransportService {
  TransportService._();

  static Future<dynamic> _rpc(String fn, [Map<String, dynamic> params = const {}]) =>
      SupabaseService.client.rpc(fn, params: {'p_token': SupabaseService.sessionToken, ...params});

  static Future<List<Map<String, dynamic>>> list(String entity, {Map<String, dynamic> filter = const {}}) async {
    final res = await _rpc('tr_list', {'p_entity': entity, 'p_filter': filter});
    return [
      for (final x in (res as List? ?? const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];
  }

  /// Inserts when the row has no key, updates otherwise. Returns the row's id.
  static Future<int?> save(String entity, Map<String, dynamic> row) async {
    final res = await _rpc('tr_save', {'p_entity': entity, 'p_row': row});
    return res is num ? res.toInt() : int.tryParse('$res');
  }

  /// Returns what happened: DELETED, INACTIVE or RELIEVED.
  static Future<String> remove(String entity, int id) async =>
      '${await _rpc('tr_delete', {'p_entity': entity, 'p_id': id})}';

  static Future<Map<String, dynamic>> settings() async =>
      Map<String, dynamic>.from(await _rpc('tr_settings_get') as Map);

  static Future<void> saveSettings(Map<String, dynamic> row) => _rpc('tr_settings_save', {'p_row': row});

  /// For Stage Fees: {year: '2026-2027', feetypes: [{fee_id, feedesc,
  /// feeshort}, ...] (transport ones: fee category TRA), terms: [{sem_id,
  /// semname, semshort, semstart, semend}, ...] (the year's semesters)}
  static Future<Map<String, dynamic>> lookups() async =>
      Map<String, dynamic>.from(await _rpc('tr_lookups') as Map);

  /// The session year's active students, for Student Enrollment, in class
  /// order: {year_from, year_to, students: [{stu_id, stuadmno, stuname,
  /// stuclass, cla_id, route_id, route_code}, ...]}, route_* being the route
  /// of the student's active enrollment, if any.
  static Future<Map<String, dynamic>> students() async =>
      Map<String, dynamic>.from(await _rpc('tr_students') as Map);

  /// The staff who may travel, for Staff Enrollment: the session year's
  /// staff (staffmast) who are active and whose transport is BUS, by employee
  /// code: {year_from, year_to, staff: [{staf_id, emp_code, stafname,
  /// shortname, designation, route_id, route_code}, ...]}, route_* being the
  /// route of the staff member's active enrollment, if any.
  static Future<Map<String, dynamic>> enrollmentStaff() async =>
      Map<String, dynamic>.from(await _rpc('tr_enrollment_staff') as Map);

  /// Daily Trips: the trips of [date] (yyyy-mm-dd), made the evening before:
  /// {trip_date, today, trips: [{trip_id, direction, status, planned_start_at,
  /// planned_end_at, updated_at, schedule_code, schedule_name, route_code,
  /// route_name, vehicle_id, vehicle_code, registration_no, capacity,
  /// crew: [{staff_id, full_name, staff_code, staff_type, duty_role,
  /// is_substitute}], students, staff, editable}, ...]}.
  static Future<Map<String, dynamic>> dailyTrips(String date) async =>
      Map<String, dynamic>.from(await _rpc('tr_daily_trips', {'p_date': date}) as Map);

  /// Makes [date]'s trips now, as the nightly run would; returns how many.
  static Future<int> makeTrips(String date) async {
    final res = await _rpc('tr_trips_make', {'p_date': date});
    return res is num ? res.toInt() : int.tryParse('$res') ?? 0;
  }

  /// Saves changes to [date]'s trips: [{trip_id, updated_at, vehicle_id?,
  /// driver_id?, attender_id?}, ...], a key left out not changed.
  static Future<void> saveTrips(String date, List<Map<String, dynamic>> trips) =>
      _rpc('tr_trip_save', {'p_row': {'trip_date': date, 'trips': trips}});

  /// Replace Trip: another vehicle runs a cancelled trip of today or later,
  /// with its stops and riders: {trip_id, updated_at, vehicle_id, driver_id,
  /// attender_id}. Returns the new trip's id.
  static Future<int?> replaceTrip(String date, Map<String, dynamic> row) async {
    final res = await _rpc('tr_trip_replace', {'p_row': {'trip_date': date, ...row}});
    return res is num ? res.toInt() : int.tryParse('$res');
  }

  /// A trip's students and staff with their stop and boarding status, in
  /// the order the bus reaches the stops (a pickup from the far stop):
  /// {trip_id, direction, can_mark, students: [{enrollment_id, stuadmno,
  /// stuname, stuclass, stop_name, stop_seq, status, boarded_at,
  /// mark_method}], staff: [{enrollment_id, emp_code, stafname, designation,
  /// stop_name, stop_seq, status, boarded_at, mark_method}]}.
  static Future<Map<String, dynamic>> tripRiders(String date, int tripId) async =>
      Map<String, dynamic>.from(await _rpc('tr_trip_riders', {'p_date': date, 'p_trip_id': tripId}) as Map);

  /// For a trip's Add Student / Add Staff: the route's riders that way on
  /// the day who are not on the trip, each with the trip they are on:
  /// {students: [{enrollment_id, stuadmno, stuname, stuclass, stop_name,
  /// on_trip_id, on_trip_code, on_vehicle_code, on_trip_status, on_status,
  /// present}], staff: [... emp_code, stafname, designation ...]}; present:
  /// already present on another trip, so not to be added.
  static Future<Map<String, dynamic>> tripRiderOptions(String date, int tripId) async =>
      Map<String, dynamic>.from(await _rpc('tr_trip_rider_options', {'p_date': date, 'p_trip_id': tripId}) as Map);

  /// Boarding entry for a trip: [{enrollment_id, status}] for its students
  /// and its staff; status PRESENT (kept as BOARDED on a pickup, ALIGHTED on
  /// a drop), ABSENT, PARENT_PICKUP (students) or EXPECTED (not marked).
  /// A row with add: true puts a rider of the route on the trip; status
  /// REMOVE takes an added one off again.
  static Future<void> saveBoarding(String date, int tripId, List<Map<String, dynamic>> students, List<Map<String, dynamic>> staff) =>
      _rpc('tr_trip_board_save', {
        'p_row': {'trip_date': date, 'trip_id': tripId, 'students': students, 'staff': staff},
      });

  /// For the Stage Fee Process: the school's routes, each with its students,
  /// the stages that have a fee for the term and fee type, and the fee
  /// demands already made from them: [{route_id, route_code, route_name,
  /// is_active, students, stages, processed, processed_at}, ...].
  static Future<List<Map<String, dynamic>>> stageFeeRoutes(int semId, int feeId) async {
    final res = await _rpc('tr_stage_fee_routes', {
      'p_filter': {'sem_id': semId, 'fee_id': feeId},
    });
    return [
      for (final x in (res as List? ?? const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];
  }

  /// Bills the students of the routes for the term and fee type from their
  /// stage fees, in the school app's fee demands: {sem_id, fee_id,
  /// route_ids}. Returns {students, added, updated, unchanged, skipped,
  /// problems: [{route_code, stage, stuadmno, stuname, stuclass, reason}]}.
  static Future<Map<String, dynamic>> processStageFees(Map<String, dynamic> payload) async =>
      Map<String, dynamic>.from(await _rpc('tr_stage_fee_process', {'p_row': payload}) as Map);
}
