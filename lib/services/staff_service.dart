import 'supabase_service.dart';

/// Staff Details' only way to the server: the public.staff_* functions
/// (C:/pg_backups/school_staff_master.sql, setup part 89). The server takes
/// the school and academic year from the session token, never from these calls,
/// and never sends a password back (has_password only).
class StaffService {
  StaffService._();

  static Future<dynamic> _rpc(String fn, [Map<String, dynamic> params = const {}]) =>
      SupabaseService.client.rpc(fn, params: {'p_token': SupabaseService.sessionToken, ...params});

  static List<Map<String, dynamic>> _rows(dynamic res) => [
        for (final x in (res as List? ?? const []))
          if (x is Map) Map<String, dynamic>.from(x),
      ];

  static int? _id(dynamic res) => res is num ? res.toInt() : int.tryParse('$res');

  /// Every staff member, with the session year's emp_code / designation /
  /// is_active (in_year false: not on this year's staff list yet).
  static Future<List<Map<String, dynamic>>> list() async => _rows(await _rpc('staff_list'));

  /// {year, communities: [{com_id, comname}], designations: [{des_id, desname}]}
  static Future<Map<String, dynamic>> lookups() async =>
      Map<String, dynamic>.from(await _rpc('staff_lookups') as Map);

  /// Adds (no staf_id) or updates a staff member and this year's row.
  /// A blank password keeps the one already set.
  static Future<int?> save(Map<String, dynamic> row) async => _id(await _rpc('staff_save', {'p_row': row}));

  // No delete: a staff member who leaves is marked Relieved (staftermin).

  static Future<List<Map<String, dynamic>>> experience(int stafId) async =>
      _rows(await _rpc('staff_experience_list', {'p_staf_id': stafId}));

  static Future<int?> saveExperience(Map<String, dynamic> row) async =>
      _id(await _rpc('staff_experience_save', {'p_row': row}));

  static Future<String> removeExperience(int id) async =>
      '${await _rpc('staff_experience_delete', {'p_staffexp_id': id})}';
}
