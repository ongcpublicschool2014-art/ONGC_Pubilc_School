import 'package:flutter/foundation.dart';

import 'supabase_service.dart';

/// The Attendance module's only way to the server: the public.att_*
/// functions (C:/pg_backups/attendance/school_attendance_api.sql; tables in
/// school_attendance.sql). The server takes the school and the academic year
/// from the session token and checks the menu (Roles & Access) itself.
class AttendanceService {
  AttendanceService._();

  /// Tests only: answers the att_* calls (and [students]) instead of the server.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic> params)? debugRpc;

  static Future<dynamic> _rpc(String fn, [Map<String, dynamic> params = const {}]) {
    final hook = debugRpc;
    if (hook != null) return hook(fn, params);
    return SupabaseService.client.rpc(fn, params: {'p_token': SupabaseService.sessionToken, ...params});
  }

  static Map<String, dynamic> _map(dynamic res) => res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};

  static List<Map<String, dynamic>> _rows(dynamic res) => [
        for (final x in (res as List? ?? const []))
          if (x is Map) Map<String, dynamic>.from(x),
      ];

  /// `yyyy-mm-dd`, the way the server takes a date.
  static String day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── lookups ──────────────────────────────────────────────────────────────
  /// {yrlabel, today, year:{start,end}, streams, terms, sections, staff,
  /// divisions, statuses, staff_roles, session_teachers, settings}
  static Future<Map<String, dynamic>> lookups() async => _map(await _rpc('att_lookups'));

  // ── setup ────────────────────────────────────────────────────────────────
  static Future<void> saveStream(Map<String, dynamic> row) => _rpc('att_stream_save', {'p_row': row});
  static Future<void> saveTerm(Map<String, dynamic> row) => _rpc('att_term_save', {'p_row': row});
  static Future<void> deleteTerm(int termId) => _rpc('att_term_delete', {'p_term_id': termId});

  /// [{cla_id, academic_year_id (null = no attendance), class_teacher_staf_id, room_no, is_active}]
  static Future<void> saveSections(List<Map<String, dynamic>> rows) => _rpc('att_section_save', {'p_rows': rows});

  static Future<List<Map<String, dynamic>>> calendar(int academicYearId) async =>
      _rows(await _rpc('att_calendar_list', {'p_academic_year_id': academicYearId}));
  static Future<int> saveCalendar(Map<String, dynamic> row) async => _int(await _rpc('att_calendar_save', {'p_row': row}));
  static Future<void> deleteCalendarDay(int id) => _rpc('att_calendar_delete', {'p_calendar_day_id': id});
  static Future<int> markWeekends(int academicYearId, List<int> weekdays, List<int> saturdays) async => _int(await _rpc(
      'att_calendar_weekends', {'p_academic_year_id': academicYearId, 'p_weekdays': weekdays, 'p_saturdays': saturdays}));

  /// [{weekday 1..7, session_code, staf_id (null = nobody)}]
  static Future<void> saveSessionTeachers(int claId, List<Map<String, dynamic>> rows) =>
      _rpc('att_session_teachers_save', {'p_cla': claId, 'p_rows': rows});

  /// The attendance staff (<year>.att_staff): {staff_id?, staf_id (new), mobile_no, email, is_active}.
  static Future<void> saveAttStaff(Map<String, dynamic> row) => _rpc('att_staff_save', {'p_row': row});
  /// Adds every one of this year's staff not on the list yet; returns how many.
  static Future<int> addAllAttStaff() async => _int(await _rpc('att_staff_add_all'));
  static Future<void> deleteAttStaff(int staffId) => _rpc('att_staff_delete', {'p_staff_id': staffId});

  static Future<void> saveStaffRole(Map<String, dynamic> row) => _rpc('att_staff_role_save', {'p_row': row});
  static Future<void> deleteStaffRole(int id) => _rpc('att_staff_role_delete', {'p_staff_role_id': id});
  static Future<void> saveStatus(Map<String, dynamic> row) => _rpc('att_status_save', {'p_row': row});
  static Future<Map<String, dynamic>> saveSettings(Map<String, dynamic> row) async =>
      _map(await _rpc('att_settings_save', {'p_row': row}));

  // ── the daily register ───────────────────────────────────────────────────
  /// {date, today, sections: [{cla_id, claname, courname, strength, fn_working, an_working,
  /// day_type, remarks, term_name, fn: {status, total, present, absent, leave}|null, an: ...}], settings}
  static Future<Map<String, dynamic>> registerDay(DateTime date) async =>
      _map(await _rpc('att_register_day', {'p_date': day(date)}));

  /// {term_id, term_name, day, sheet|null, editable, why_locked, needs_reason, students: [...]}
  static Future<Map<String, dynamic>> register(int claId, DateTime date, String session) async =>
      _map(await _rpc('att_register_get', {'p_cla': claId, 'p_date': day(date), 'p_session': session}));

  /// [entries] = [{stu_id, status_code, remarks}]. Returns the register as saved.
  static Future<Map<String, dynamic>> saveRegister(int claId, DateTime date, String session,
          List<Map<String, dynamic>> entries, {required bool submit, String? reason}) async =>
      _map(await _rpc('att_register_save', {
        'p_cla': claId,
        'p_date': day(date),
        'p_session': session,
        'p_entries': entries,
        'p_submit': submit,
        'p_reason': reason,
      }));

  static Future<Map<String, dynamic>> clearRegister(int claId, DateTime date, String session, {String? reason}) async =>
      _map(await _rpc('att_register_clear', {'p_cla': claId, 'p_date': day(date), 'p_session': session, 'p_reason': reason}));

  // ── leave and out-pass ───────────────────────────────────────────────────
  /// [status]: null = all, 'PENDING', or one status.
  static Future<List<Map<String, dynamic>>> leaves({DateTime? from, DateTime? to, String? status}) async =>
      _rows(await _rpc('att_leave_list', {
        'p_from': from == null ? null : day(from),
        'p_to': to == null ? null : day(to),
        'p_status': status,
      }));
  static Future<void> saveLeave(Map<String, dynamic> row) => _rpc('att_leave_save', {'p_row': row});

  /// [action]: SUBMIT / APPROVE / REJECT / RETURN / CANCEL. Returns the new status.
  static Future<String> actOnLeave(int leaveId, String action, {String? remarks}) async =>
      '${await _rpc('att_leave_act', {'p_leave_id': leaveId, 'p_action': action, 'p_remarks': remarks})}';

  static Future<List<Map<String, dynamic>>> outpasses({DateTime? from, DateTime? to}) async => _rows(await _rpc(
      'att_outpass_list', {'p_from': from == null ? null : day(from), 'p_to': to == null ? null : day(to)}));

  /// Returns {outpass_id, outpass_no}.
  static Future<Map<String, dynamic>> saveOutpass(Map<String, dynamic> row) async =>
      _map(await _rpc('att_outpass_save', {'p_row': row}));
  static Future<void> cancelOutpass(int id) => _rpc('att_outpass_cancel', {'p_outpass_id': id});

  // ── reports ──────────────────────────────────────────────────────────────
  /// {rows: [{stu_id, stuadmno, stuname, claname, working_sessions, present_sessions,
  /// absent_sessions, leave_sessions, working_days, present_days, attendance_pct}], min_pct}
  static Future<Map<String, dynamic>> summary({int? termId, int? claId}) async =>
      _map(await _rpc('att_report_summary', {'p_term_id': termId, 'p_cla': claId}));

  static Future<List<Map<String, dynamic>>> absentees(DateTime from, DateTime to, {int? claId}) async =>
      _rows(await _rpc('att_report_absentees', {'p_from': day(from), 'p_to': day(to), 'p_cla': claId}));

  /// {from, to, days: [{date, fn_working, an_working, day_type, remarks}],
  /// students: [{stu_id, stuadmno, stuname, marks: {"yyyy-mm-dd FN": "P"}, working_sessions, present_sessions}]}
  static Future<Map<String, dynamic>> monthRegister(int claId, DateTime month) async =>
      _map(await _rpc('att_report_register', {'p_cla': claId, 'p_month': day(month)}));

  // ── students (for leave and out-pass) ────────────────────────────────────
  /// This year's students: stu_id, stuadmno, stuname, stuclass, cla_id.
  static Future<List<Map<String, dynamic>>> students() async {
    final hook = debugRpc;
    if (hook != null) return _rows(await hook('students', const {}));
    final rows = await SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
        .select('stu_id, stuadmno, stuname, stuclass, cla_id, preadmission')
        .eq('activestatus', 1));
    return [
      for (final r in rows)
        if (((r['preadmission'] as num?)?.toInt() ?? 0) == 0) Map<String, dynamic>.from(r),
    ]..sort((a, b) => '${a['stuname']}'.toUpperCase().compareTo('${b['stuname']}'.toUpperCase()));
  }

  static int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
}
