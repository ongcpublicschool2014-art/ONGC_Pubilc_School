import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/attendance/attendance_entry_screen.dart';
import 'package:school_admin/screens/attendance/attendance_report_screen.dart';
import 'package:school_admin/screens/attendance/attendance_setup_screen.dart';
import 'package:school_admin/screens/attendance/leave_outpass_screen.dart';
import 'package:school_admin/services/attendance_service.dart';
import 'package:school_admin/utils/app_menu.dart';
import 'package:school_admin/utils/module_control.dart';
import 'package:school_admin/utils/school_terms.dart';

/// The ATTENDANCE screens (2026-11-24) against answers shaped like the
/// att_* functions' (school_attendance_api.sql, checked on the test database).
void main() {
  const statuses = [
    {'status_code': 'P', 'status_name': 'Present', 'counts_as_present': true, 'notify_parent': false, 'display_color': '#2E7D32', 'display_order': 1, 'is_active': true},
    {'status_code': 'A', 'status_name': 'Absent', 'counts_as_present': false, 'notify_parent': true, 'display_color': '#C62828', 'display_order': 2, 'is_active': true},
    {'status_code': 'L', 'status_name': 'Leave (approved)', 'counts_as_present': false, 'notify_parent': false, 'display_color': '#F9A825', 'display_order': 3, 'is_active': true},
    {'status_code': 'OD', 'status_name': 'On duty', 'counts_as_present': true, 'notify_parent': false, 'display_color': '#1565C0', 'display_order': 4, 'is_active': true},
    {'status_code': 'LT', 'status_name': 'Late', 'counts_as_present': true, 'notify_parent': false, 'display_color': '#6A1B9A', 'display_order': 5, 'is_active': true},
  ];
  const settings = {
    'fn_start_time': '08:45:00', 'an_start_time': '13:15:00', 'teacher_edit_window_minutes': 120, 'auto_lock_time': '18:00:00',
    'absent_sms_delay_minutes': 30, 'min_attendance_pct': 75.0, 'allow_backdated_days': 3,
  };
  Map<String, dynamic> lookups() => {
        'yrlabel': '2026-2027',
        'today': '2026-11-24',
        'year': {'start': '2026-06-01', 'end': '2027-05-31'},
        'streams': [
          {'stream_id': 1, 'stream_code': 'CBSE', 'stream_name': 'CBSE', 'is_active': true, 'academic_year_id': 1, 'start_date': '2026-06-01', 'end_date': '2027-05-31', 'status': 'OPEN'},
        ],
        'terms': [
          {'term_id': 1, 'academic_year_id': 1, 'sem_id': 1, 'term_name': 'Term I', 'term_seq': 1, 'start_date': '2026-06-01', 'end_date': '2026-09-30', 'sheets': 0},
          {'term_id': 2, 'academic_year_id': 1, 'term_name': 'Term II', 'term_seq': 2, 'start_date': '2026-10-01', 'end_date': '2027-01-31', 'sheets': 3},
        ],
        // the Term master (Fee Master -> Term)
        'semesters': [
          {'sem_id': 1, 'semname': 'TERM 1', 'semstart': '2026-06-01', 'semend': '2026-11-30', 'ordid': 1},
          {'sem_id': 2, 'semname': 'TERM II', 'semstart': '2026-12-01', 'semend': '2027-02-28', 'ordid': 2},
        ],
        'sections': [
          {'cla_id': 10, 'claname': 'I A', 'cour_id': 4, 'courname': 'I', 'div_id': 2, 'divname': 'PRIMARY', 'academic_year_id': 1, 'stream_id': 1,
            'class_teacher_staf_id': 3, 'class_teacher': 'Lakshmi Narayanan R', 'room_no': '101', 'is_active': true, 'set_up': true, 'strength': 3, 'sheets': 2},
          {'cla_id': 11, 'claname': 'I B', 'cour_id': 4, 'courname': 'I', 'div_id': 2, 'divname': 'PRIMARY', 'academic_year_id': null, 'stream_id': null,
            'class_teacher_staf_id': null, 'class_teacher': null, 'room_no': null, 'is_active': false, 'set_up': false, 'strength': 10, 'sheets': 0},
        ],
        'staff': [
          {'staf_id': 3, 'stafname': 'Lakshmi Narayanan R', 'emp_code': 'EMP001', 'designation': 'Principal'},
          {'staf_id': 4, 'stafname': 'Senthil Kumar P', 'emp_code': 'EMP002', 'designation': 'Teacher'},
          {'staf_id': 5, 'stafname': 'Fathima Begum S', 'emp_code': 'EMP003', 'designation': 'Teacher', 'mobile_no': '9840011003', 'email': 'fathima.s@example.com'},
        ],
        // the attendance staff (<year>.att_staff): Fathima is not on it
        'att_staff': [
          {'staff_id': 1, 'staffmast_id': 3, 'staf_id': 3, 'emp_code': 'EMP001', 'full_name': 'Lakshmi Narayanan R', 'designation': 'Principal',
            'mobile_no': '9840011001', 'email': null, 'is_active': true, 'class_teacher_of': 1, 'marks_sessions': 1, 'roles': []},
          {'staff_id': 2, 'staffmast_id': 4, 'staf_id': 4, 'emp_code': 'EMP002', 'full_name': 'Senthil Kumar P', 'designation': 'Teacher',
            'mobile_no': null, 'email': null, 'is_active': true, 'class_teacher_of': 0, 'marks_sessions': 0,
            'roles': [
              {'staff_role_id': 1, 'role_code': 'DIVISION_INCHARGE', 'div_id': 2, 'divname': 'PRIMARY', 'is_active': true},
            ]},
        ],
        'divisions': [
          {'div_id': 2, 'divname': 'PRIMARY'},
        ],
        'statuses': statuses,
        'staff_roles': [
          {'staff_role_id': 1, 'staf_id': 4, 'stafname': 'Senthil Kumar P', 'role_code': 'DIVISION_INCHARGE', 'div_id': 2, 'divname': 'PRIMARY', 'is_active': true},
        ],
        'session_teachers': [
          {'session_teacher_id': 1, 'cla_id': 10, 'weekday': 1, 'session_code': 'FN', 'staf_id': 3, 'stafname': 'Lakshmi Narayanan R', 'effective_from': '2026-11-24'},
        ],
        'settings': settings,
      };
  Map<String, dynamic> day({List<Map<String, dynamic>>? sections}) => {
        'date': '2026-11-24',
        'today': '2026-11-24',
        'settings': settings,
        'sections': sections ??
            [
              {'cla_id': 10, 'claname': 'I A', 'courname': 'I', 'div_id': 2, 'stream_id': 1, 'stream_code': 'CBSE', 'class_teacher': 'Lakshmi Narayanan R',
                'strength': 3, 'in_year': true, 'fn_working': true, 'an_working': true, 'day_type': 'WORKING', 'term_name': 'Term II',
                'fn': {'status': 'SUBMITTED', 'total': 3, 'present': 2, 'absent': 1, 'leave': 0}, 'an': null},
            ],
      };
  Map<String, dynamic> register({bool editable = true, String? why, String? status}) => {
        'cla_id': 10,
        'att_date': '2026-11-24',
        'session_code': 'FN',
        'today': '2026-11-24',
        'day': {'fn_working': true, 'an_working': true, 'day_type': 'WORKING', 'in_year': true},
        'term_id': 2,
        'term_name': 'Term II',
        'sheet': status == null ? null : {'sheet_id': 1, 'status': status, 'entry_mode': 'OFFICE_REGISTER', 'marked_by_name': 'ADMIN', 'submitted_at': '2026-11-24T10:00:00'},
        'editable': editable,
        'why_locked': why,
        'needs_reason': status == 'SUBMITTED',
        'students': [
          {'stu_id': 492, 'stuadmno': 'ADM00180', 'stuname': 'DHARSHINI S', 'stugender': 'F', 'status_code': 'P', 'saved': status != null},
          {'stu_id': 683, 'stuadmno': 'ADM00202', 'stuname': 'MANOJ', 'stugender': 'M', 'status_code': 'L', 'leave_id': 5, 'saved': status != null, 'note': 'On leave (Medical)'},
          {'stu_id': 513, 'stuadmno': 'ADM00183', 'stuname': 'POOJA S', 'stugender': 'F', 'status_code': 'P', 'saved': status != null},
        ],
      };

  /// Shows [screen] at [size] with the att_* calls answered by [rpc];
  /// returns the calls made.
  Future<List<(String, Map<String, dynamic>)>> show(WidgetTester t, Widget screen, Future<dynamic> Function(String fn, Map<String, dynamic> p) rpc,
      {Size size = const Size(1366, 768)}) async {
    final calls = <(String, Map<String, dynamic>)>[];
    AttendanceService.debugRpc = (fn, p) {
      calls.add((fn, p));
      return rpc(fn, p);
    };
    addTearDown(() => AttendanceService.debugRpc = null);
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(body: SizedBox(width: size.width - 300, height: size.height - 130, child: screen)),
      ),
    ));
    await t.pumpAndSettle();
    return calls;
  }

  group('Attendance Entry', () {
    /// Picks [name] in the student's status dropdown.
    Future<void> mark(WidgetTester t, int stu, String name) async {
      await t.tap(find.byKey(ValueKey('att-status-$stu')));
      await t.pumpAndSettle();
      await t.tap(find.text(name).last);
      await t.pumpAndSettle();
    }

    Future<dynamic> Function(String, Map<String, dynamic>) entryRpc({String? status, bool editable = true, String? why}) => (fn, p) async => switch (fn) {
          'att_lookups' => lookups(),
          'att_register_day' => day(),
          'att_register_get' => register(status: status, editable: editable, why: why),
          'att_register_save' => register(status: p['p_submit'] == true ? 'SUBMITTED' : (status ?? 'DRAFT')),
          _ => null,
        };

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets('lays out at ${size.width.toInt()} x ${size.height.toInt()}', (t) async {
        await show(t, const AttendanceEntryScreen(), entryRpc(), size: size);
        expect(t.takeException(), isNull);
        expect(find.byKey(const ValueKey('att-section-10')), findsOneWidget);
        expect(find.text('DHARSHINI S'), findsOneWidget);
        expect(find.text('On leave (Medical)'), findsOneWidget, reason: 'the approved leave is shown');
        expect(find.byKey(const ValueKey('att-status-492')), findsOneWidget, reason: 'a status dropdown per student');
        expect(t.getSize(find.byKey(const ValueKey('att-row-492'))).height, lessThan(70), reason: 'one line per student');
      });
    }

    testWidgets('marking absent and submitting sends every student', (t) async {
      final calls = await show(t, const AttendanceEntryScreen(), entryRpc());
      await mark(t, 492, 'Absent');
      await t.tap(find.byKey(const ValueKey('att-submit')));
      await t.pumpAndSettle();
      await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Submit')));
      await t.pumpAndSettle();
      final save = calls.lastWhere((c) => c.$1 == 'att_register_save').$2;
      expect(save['p_submit'], isTrue);
      expect(save['p_session'], 'FN');
      expect(save['p_date'], '2026-11-24');
      final entries = (save['p_entries'] as List).cast<Map<String, dynamic>>();
      expect(entries.length, 3);
      expect(entries.firstWhere((e) => e['stu_id'] == 492)['status_code'], 'A');
      expect(entries.firstWhere((e) => e['stu_id'] == 683)['status_code'], 'L', reason: 'the leave stays');
      expect(find.text('SUBMITTED'), findsOneWidget);
    });

    testWidgets('All Present keeps a student on leave', (t) async {
      final calls = await show(t, const AttendanceEntryScreen(), entryRpc());
      await mark(t, 513, 'Absent');
      await t.tap(find.byKey(const ValueKey('att-all-present')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('att-save-draft')));
      await t.pumpAndSettle();
      final entries = (calls.lastWhere((c) => c.$1 == 'att_register_save').$2['p_entries'] as List).cast<Map<String, dynamic>>();
      expect({for (final e in entries) e['stu_id']: e['status_code']}, {492: 'P', 683: 'L', 513: 'P'});
    });

    testWidgets('a change to a submitted register asks for the reason', (t) async {
      final calls = await show(t, const AttendanceEntryScreen(), entryRpc(status: 'SUBMITTED'));
      expect(find.text('Save Changes'), findsOneWidget);
      await mark(t, 513, 'Absent');
      await t.tap(find.byKey(const ValueKey('att-submit')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('att-reason')), 'Was sent home sick');
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      final save = calls.lastWhere((c) => c.$1 == 'att_register_save').$2;
      expect(save['p_reason'], 'Was sent home sick');
      expect(save['p_submit'], isFalse);
    });

    testWidgets('the dropdown offers every status in use, with its name', (t) async {
      await show(t, const AttendanceEntryScreen(), entryRpc());
      await t.tap(find.byKey(const ValueKey('att-status-492')));
      await t.pumpAndSettle();
      for (final n in ['Present', 'Absent', 'Leave (approved)', 'On duty', 'Late']) {
        expect(find.text(n), findsWidgets, reason: n);
      }
    });

    testWidgets('the field shows the short name; the list the whole of it', (t) async {
      await show(t, const AttendanceEntryScreen(), entryRpc());
      await mark(t, 492, 'On duty');
      final field = find.byKey(const ValueKey('att-status-492'));
      expect(find.descendant(of: field, matching: find.text('On duty')), findsOneWidget);
      expect(find.descendant(of: field, matching: find.textContaining('(')), findsNothing);
      await t.tap(find.byKey(const ValueKey('att-status-513')));
      await t.pumpAndSettle();
      expect(find.text('Leave (approved)'), findsWidgets, reason: 'the list keeps the whole name');
    });

    testWidgets('a register that cannot be changed says why and offers no save', (t) async {
      await show(t, const AttendanceEntryScreen(), entryRpc(editable: false, why: 'This date is still to come.'));
      expect(find.text('This date is still to come.'), findsOneWidget);
      expect(find.byKey(const ValueKey('att-submit')), findsNothing);
      expect(find.byKey(const ValueKey('att-all-present')), findsNothing);
    });

    testWidgets('no sections yet: points to Attendance Setup', (t) async {
      await show(t, const AttendanceEntryScreen(), (fn, p) async => switch (fn) {
            'att_lookups' => lookups(),
            'att_register_day' => day(sections: const []),
            _ => null,
          });
      expect(find.text('No sections take attendance yet'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('Attendance Setup', () {
    Future<dynamic> setupRpc(String fn, Map<String, dynamic> p) async => switch (fn) {
          'att_lookups' => lookups(),
          'att_calendar_list' => [
              {'calendar_day_id': 1, 'cal_date': '2026-11-14', 'div_id': null, 'fn_working': false, 'an_working': false, 'day_type': 'HOLIDAY', 'remarks': "Children's Day"},
              {'calendar_day_id': 2, 'cal_date': '2026-11-21', 'div_id': null, 'fn_working': true, 'an_working': false, 'day_type': 'HALF_DAY', 'remarks': null},
            ],
          _ => 1,
        };

    testWidgets('every tab lays out at 1366 x 768', (t) async {
      await show(t, const AttendanceSetupScreen(), setupRpc);
      for (var i = 0; i < AttendanceSetupScreen.tabLabels.length; i++) {
        await t.tap(find.byKey(ValueKey('att-setup-tab-$i')));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: AttendanceSetupScreen.tabLabels[i]);
      }
    });

    testWidgets('Year & Terms lists the stream and its terms', (t) async {
      await show(t, const AttendanceSetupScreen(), setupRpc);
      expect(find.text('CBSE'), findsWidgets);
      expect(find.text('Term I'), findsOneWidget);
      expect(find.text('Term II'), findsOneWidget);
    });

    testWidgets('Add Term: picked from the Term master, its dates filled in', (t) async {
      final calls = await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-add-term')));
      await t.pumpAndSettle();
      final save = find.byKey(const ValueKey('term-save'));
      expect(t.widget<ElevatedButton>(save).onPressed, isNull, reason: 'nothing picked yet');
      await t.tap(find.byKey(const ValueKey('term-pick')));
      await t.pumpAndSettle();
      expect(find.text('TERM 1'), findsNothing, reason: 'already a term of this stream');
      await t.tap(find.text('TERM II').last);
      await t.pumpAndSettle();
      expect(find.text('01-Dec-2026'), findsOneWidget);
      expect(find.text('28-Feb-2027'), findsOneWidget);
      await t.tap(save);
      await t.pumpAndSettle();
      final row = calls.lastWhere((c) => c.$1 == 'att_term_save').$2['p_row'] as Map<String, dynamic>;
      expect(row['sem_id'], 2);
      expect(row['start_date'], '2026-12-01');
      expect(row['end_date'], '2027-02-28');
      expect(row.containsKey('term_name'), isFalse, reason: 'the name comes from the master');
    });

    testWidgets('Calendar: a day in the list opens for editing', (t) async {
      await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-setup-tab-3')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('cal-list-1')));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Back to normal'), findsOneWidget, reason: 'an existing entry');
      expect(find.text("Children's Day"), findsWidgets, reason: 'its note loaded');
    });

    testWidgets('Attendance Staff: add one from this year\'s staff; Add All', (t) async {
      final calls = await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-setup-tab-1')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Lakshmi Narayanan R'), findsOneWidget);
      expect(find.text('Class teacher of 1 · Who Marks 1'), findsOneWidget);
      // only the one not on the list is offered
      await t.tap(find.byKey(const ValueKey('attstaff-staff')));
      await t.pumpAndSettle();
      final list = find.byType(ListView).last;
      expect(find.descendant(of: list, matching: find.text('Fathima Begum S')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('Senthil Kumar P')), findsNothing);
      await t.tap(find.descendant(of: list, matching: find.text('Fathima Begum S')));
      await t.pumpAndSettle();
      // filled from Staff Details
      expect(find.text('9840011003'), findsOneWidget);
      expect(find.text('fathima.s@example.com'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('attstaff-mobile')), '9876500011');
      await t.tap(find.byKey(const ValueKey('attstaff-save')));
      await t.pumpAndSettle();
      final row = calls.lastWhere((c) => c.$1 == 'att_staff_save').$2['p_row'] as Map<String, dynamic>;
      expect(row, {'staf_id': 5, 'mobile_no': '9876500011', 'email': 'fathima.s@example.com', 'roles': []});
      await t.tap(find.byKey(const ValueKey('attstaff-add-all')));
      await t.pumpAndSettle();
      expect(calls.any((c) => c.$1 == 'att_staff_add_all'), isTrue);
    });

    testWidgets('Attendance Staff: edit makes one inactive', (t) async {
      final calls = await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-setup-tab-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attstaff-edit-2')));
      await t.pumpAndSettle();
      expect(find.text('Edit Attendance Staff'), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('attstaff-active')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attstaff-active')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('attstaff-save')));
      await t.pumpAndSettle();
      final row = calls.lastWhere((c) => c.$1 == 'att_staff_save').$2['p_row'] as Map<String, dynamic>;
      expect(row, {
        'staff_id': 2, 'mobile_no': '', 'email': '', 'is_active': false,
        'roles': [
          {'role_code': 'DIVISION_INCHARGE', 'div_id': 2},
        ],
      });
    });

    testWidgets('Attendance Staff: roles are shown, added and removed in the same form', (t) async {
      final calls = await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-setup-tab-1')));
      await t.pumpAndSettle();
      expect(find.text('Division in-charge (PRIMARY)'), findsOneWidget, reason: 'the Role column');
      expect(find.text('Staff Roles'), findsNothing, reason: 'no tab of its own any more');
      // edit Lakshmi: make her Principal (all divisions) and a Teacher of PRIMARY
      await t.tap(find.byKey(const ValueKey('attstaff-edit-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attstaff-role')));
      await t.pumpAndSettle();
      await t.tap(find.text('Principal').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attstaff-division')));
      await t.pumpAndSettle();
      await t.tap(find.text('All divisions').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attstaff-add-role')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attstaff-role-PRINCIPAL-null')), findsOneWidget);
      // a division in-charge needs a division: the only one is filled in
      await t.tap(find.byKey(const ValueKey('attstaff-role')));
      await t.pumpAndSettle();
      await t.tap(find.text('Division in-charge').last);
      await t.pumpAndSettle();
      // Save takes the one being picked too
      await t.tap(find.byKey(const ValueKey('attstaff-save')));
      await t.pumpAndSettle();
      final row = calls.lastWhere((c) => c.$1 == 'att_staff_save').$2['p_row'] as Map<String, dynamic>;
      expect(row['roles'], [
        {'role_code': 'PRINCIPAL', 'div_id': null},
        {'role_code': 'DIVISION_INCHARGE', 'div_id': 2},
      ]);
    });

    testWidgets('Attendance Staff: x removes a role', (t) async {
      final calls = await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-setup-tab-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attstaff-edit-2')));
      await t.pumpAndSettle();
      final chip = find.byKey(const ValueKey('attstaff-role-DIVISION_INCHARGE-2'));
      expect(chip, findsOneWidget);
      await t.ensureVisible(chip);
      await t.pumpAndSettle();
      await t.tap(find.descendant(of: chip, matching: find.byType(Icon)).last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attstaff-save')));
      await t.pumpAndSettle();
      final row = calls.lastWhere((c) => c.$1 == 'att_staff_save').$2['p_row'] as Map<String, dynamic>;
      expect(row['roles'], isEmpty);
    });

    testWidgets('the teacher pickers offer only the attendance staff', (t) async {
      await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-setup-tab-4')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('who-10-1-AN')));
      await t.pumpAndSettle();
      final list = find.byType(ListView).last;
      expect(find.descendant(of: list, matching: find.text('Senthil Kumar P')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('Fathima Begum S')), findsNothing, reason: 'not an attendance staff');
    });

    testWidgets('Sections: picking a stream saves that section', (t) async {
      final calls = await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-setup-tab-2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('sec-stream-11')));
      await t.pumpAndSettle();
      await t.tap(find.text('CBSE').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('att-sections-save')));
      await t.pumpAndSettle();
      final rows = (calls.lastWhere((c) => c.$1 == 'att_section_save').$2['p_rows'] as List).cast<Map<String, dynamic>>();
      expect(rows.length, 1);
      expect(rows.single['cla_id'], 11);
      expect(rows.single['academic_year_id'], 1);
      expect(rows.single['is_active'], isTrue);
    });

    testWidgets('the calendar: a colour per kind of day, half day says which session works', (t) async {
      await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-setup-tab-3')));
      await t.pumpAndSettle();
      expect(find.textContaining("Children's Day"), findsWidgets);
      final half = find.descendant(of: find.byKey(const ValueKey('cal-day-21')), matching: find.text('Half day (FN)'));
      final holiday = find.descendant(of: find.byKey(const ValueKey('cal-day-14')), matching: find.text('Holiday'));
      final off = find.descendant(of: find.byKey(const ValueKey('cal-day-15')), matching: find.text('Weekly off'));
      expect(half, findsOneWidget);
      expect(holiday, findsOneWidget);
      expect(off, findsOneWidget, reason: 'a Sunday with no entry');
      final colours = {for (final f in [half, holiday, off]) t.widget<Text>(f).style!.color};
      expect(colours.length, 3, reason: 'three kinds, three colours');
    });

    testWidgets('Who Marks: teachers searched; Same as Monday and Class Teacher for FN', (t) async {
      final calls = await show(t, const AttendanceSetupScreen(), setupRpc);
      await t.tap(find.byKey(const ValueKey('att-setup-tab-4')));
      await t.pumpAndSettle();
      // Monday AN: search "sent"
      await t.tap(find.byKey(const ValueKey('who-10-1-AN')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('search-pick-field')), 'sent');
      await t.pump();
      await t.tap(find.text('Senthil Kumar P').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('who-copy-monday')));
      await t.pump();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      final rows = (calls.lastWhere((c) => c.$1 == 'att_session_teachers_save').$2['p_rows'] as List).cast<Map<String, dynamic>>();
      num? at(int w, String s) => rows.firstWhere((r) => r['weekday'] == w && r['session_code'] == s)['staf_id'] as num?;
      for (var w = 1; w <= 6; w++) {
        expect(at(w, 'FN'), 3, reason: 'Monday FN copied to day $w');
        expect(at(w, 'AN'), 4, reason: 'Monday AN copied to day $w');
      }
      expect(at(7, 'FN'), isNull, reason: 'Sunday left alone');
    });
  });

  group('Leave & Out-pass', () {
    const leave = {
      'leave_id': 5, 'stu_id': 683, 'stuadmno': 'ADM00202', 'stuname': 'MANOJ', 'claname': 'I A', 'leave_type': 'MEDICAL',
      'from_date': '2026-11-24', 'from_session': 'FN', 'to_date': '2026-11-25', 'to_session': 'AN', 'reason': 'Fever',
      'certificate_required': true, 'status': 'PENDING_CLASS_INCHARGE', 'requested_by_name': 'Father', 'approvals': [],
    };

    testWidgets('a pending leave is approved from the list', (t) async {
      final calls = await show(t, const LeaveOutpassScreen(), (fn, p) async => switch (fn) {
            'att_leave_list' => [leave],
            'att_leave_act' => 'PENDING_DIVISION_INCHARGE',
            _ => const [],
          });
      expect(find.text('MANOJ'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.byKey(const ValueKey('leave-approve-5')));
      await t.pumpAndSettle();
      final act = calls.lastWhere((c) => c.$1 == 'att_leave_act').$2;
      expect(act['p_leave_id'], 5);
      expect(act['p_action'], 'APPROVE');
    });

    testWidgets('the out-pass tab lists the day\'s out-passes', (t) async {
      await show(t, const LeaveOutpassScreen(), (fn, p) async => switch (fn) {
            'att_outpass_list' => [
                {'outpass_id': 1, 'outpass_no': 'OP0001', 'stu_id': 492, 'stuadmno': 'ADM00180', 'stuname': 'DHARSHINI S', 'claname': 'I A',
                  'out_date': '2026-11-24', 'out_time': '12:00:00', 'reason_category': 'SICKNESS', 'picked_up_by_name': 'Father',
                  'picked_up_by_mobile': '9876543210', 'leave_session': 'AN', 'status': 'ISSUED'},
              ],
            _ => const [],
          });
      await t.tap(find.byKey(const ValueKey('lo-tab-outpass')));
      await t.pumpAndSettle();
      expect(find.text('OP0001'), findsOneWidget);
      expect(find.textContaining('12:00 PM'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('Attendance Report', () {
    Future<dynamic> reportRpc(String fn, Map<String, dynamic> p) async => switch (fn) {
          'att_lookups' => lookups(),
          'att_report_summary' => {
              'min_pct': 75,
              'rows': [
                {'stu_id': 492, 'stuadmno': 'ADM00180', 'stuname': 'DHARSHINI S', 'claname': 'I A', 'working_sessions': 40, 'present_sessions': 38,
                  'absent_sessions': 2, 'leave_sessions': 0, 'working_days': 20.0, 'present_days': 19.0, 'attendance_pct': 95.0},
                {'stu_id': 683, 'stuadmno': 'ADM00202', 'stuname': 'MANOJ', 'claname': 'I A', 'working_sessions': 40, 'present_sessions': 20,
                  'absent_sessions': 10, 'leave_sessions': 10, 'working_days': 20.0, 'present_days': 10.0, 'attendance_pct': 50.0},
              ],
            },
          'att_report_absentees' => const [],
          'att_report_register' => {
              'from': '2026-11-01',
              'to': '2026-11-30',
              'days': [
                for (var d = 1; d <= 30; d++)
                  {'date': '2026-11-${d.toString().padLeft(2, '0')}', 'fn_working': d % 7 != 1, 'an_working': d % 7 != 1, 'day_type': 'WORKING'},
              ],
              'students': [
                {'stu_id': 683, 'stuadmno': 'ADM00202', 'stuname': 'MANOJ', 'marks': {'2026-11-24 FN': 'A', '2026-11-24 AN': 'L'}, 'working_sessions': 2, 'present_sessions': 0},
              ],
            },
          _ => null,
        };

    testWidgets('summary: shortage only leaves the students below the minimum', (t) async {
      await show(t, const AttendanceReportScreen(), reportRpc);
      expect(find.text('DHARSHINI S'), findsOneWidget);
      expect(find.text('MANOJ'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rep-short')));
      await t.pumpAndSettle();
      expect(find.text('DHARSHINI S'), findsNothing);
      expect(find.text('MANOJ'), findsOneWidget);
    });

    testWidgets('absentees and the monthly register lay out', (t) async {
      await show(t, const AttendanceReportScreen(), reportRpc);
      await t.tap(find.byKey(const ValueKey('rep-tab-1')));
      await t.pumpAndSettle();
      expect(find.text('Nobody missed a session on these dates'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rep-tab-2')));
      await t.pumpAndSettle();
      expect(find.textContaining('MANOJ'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('menu', () {
    test('an ATTENDANCE section with the four menus the server checks', () {
      final items = kAppNavItems.where((i) => i.section == 'ATTENDANCE').map((i) => i.label).toList();
      expect(items, ['Attendance Entry', 'Leave & Out-pass', 'Attendance Report', 'Attendance Setup']);
      expect(kSectionMeta.containsKey('ATTENDANCE'), isTrue);
      expect(kModuleOfSection['ATTENDANCE']?.$1, 'ATT');
    });

    test('it comes right after Staff', () {
      final sections = <String>[];
      for (final i in kAppNavItems) {
        if (sections.isEmpty || sections.last != i.section) sections.add(i.section);
      }
      expect(sections.indexOf('ATTENDANCE'), sections.indexOf('STAFF') + 1);
    });

    test('a college does not get it', () {
      for (final l in const ['Attendance Entry', 'Leave & Out-pass', 'Attendance Report', 'Attendance Setup']) {
        expect(kCollegeHiddenSubItems.contains(l), isTrue, reason: l);
      }
    });
  });
}
