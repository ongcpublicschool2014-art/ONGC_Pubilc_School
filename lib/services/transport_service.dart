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
