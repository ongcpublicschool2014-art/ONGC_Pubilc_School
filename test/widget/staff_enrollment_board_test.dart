import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/transport/student_enrollment_screen.dart';

// Staff Enrollment on route A1: Mill Gate and Main Road (stage 1), Lake View
// (stage 2). RAVI is on it (up at Mill Gate, down at Lake View). Of the staff
// who may travel, SITA and VANI have no transport yet and MANI is on A2.
void main() {
  final route = {'route_id': 1, 'route_code': 'A1', 'route_name': 'Kolumam', 'is_active': true};
  final stages = [
    {'stage_id': 21, 'route_id': 1, 'stage_no': 1, 'stage_name': 'Near'},
    {'stage_id': 22, 'route_id': 1, 'stage_no': 2, 'stage_name': 'Far'},
  ];
  final stops = [
    {'stop_id': 11, 'route_id': 1, 'stage_id': 21, 'stop_seq': 1, 'stop_name': 'Mill Gate', 'is_active': true},
    {'stop_id': 12, 'route_id': 1, 'stage_id': 21, 'stop_seq': 2, 'stop_name': 'Main Road', 'is_active': true},
    {'stop_id': 13, 'route_id': 1, 'stage_id': 22, 'stop_seq': 3, 'stop_name': 'Lake View', 'is_active': true},
  ];
  // as tr_enrollment_staff gives them (staf_id is a number)
  final staff = [
    {'staf_id': 4, 'emp_code': 'EMP002', 'stafname': 'RAVI', 'designation': 'Teacher', 'route_id': 1, 'route_code': 'A1'},
    {'staf_id': 5, 'emp_code': 'EMP003', 'stafname': 'SITA', 'designation': 'Teacher'},
    {'staf_id': 6, 'emp_code': 'EMP004', 'stafname': 'MANI', 'designation': 'Driver', 'route_id': 2, 'route_code': 'A2'},
    {'staf_id': 7, 'emp_code': 'EMP005', 'stafname': 'VANI', 'designation': 'Office Assistant'},
  ];
  Map<String, dynamic> ravi({bool active = true}) => {
        'enrollment_id': 9, 'staf_id': 4, 'route_id': 1, 'service_type': 'BOTH', 'pickup_stop_id': 11, 'drop_stop_id': 13,
        'fee_stage_id': 22, 'start_date': '2026-06-01', 'end_date': null, 'status': 'ACTIVE', 'updated_at': '2026-11-13T10:00:00+00:00',
        'emp_code': 'EMP002', 'stafname': 'RAVI', 'designation': 'Teacher', 'staff_active': active, 'transportreq': 'BUS',
      };
  var sent = <Map<String, dynamic>>[];

  Future<void> open(WidgetTester t, {List<Map<String, dynamic>>? rows}) async {
    sent = [];
    await t.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1680,
            height: 950,
            child: EnrollmentBoard(
              kind: EnrollmentKind.staff,
              route: route,
              stages: stages,
              stops: stops,
              enrollments: rows ?? [ravi()],
              people: staff,
              yearFrom: '2026-06-01',
              yearTo: '2027-05-31',
              today: DateTime(2026, 11, 13),
              onSave: (rows) async => sent = rows,
            ),
          ),
        ),
      ),
    ));
    await t.pump();
  }

  /// Drags the stop [stopId] from the left onto [target].
  Future<void> dragStop(WidgetTester t, int stopId, Finder target) async {
    final g = await t.startGesture(t.getCenter(find.byKey(ValueKey('enr-stop-$stopId'))));
    await t.pump(const Duration(milliseconds: 20));
    await g.moveBy(const Offset(40, 0));
    await t.pump();
    await g.moveTo(t.getCenter(target));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();
  }

  testWidgets('shows the staff with employee code, name and designation', (t) async {
    await open(t);
    expect(t.takeException(), isNull);
    expect(find.text('EMP CODE'), findsOneWidget);
    expect(find.text('NAME · DESIGNATION'), findsOneWidget);
    expect(find.text('EMP002'), findsOneWidget);
    expect(find.text('RAVI'), findsOneWidget);
    expect(find.text('Teacher'), findsOneWidget);
    expect(find.text('Stage 2'), findsOneWidget, reason: 'the stage of the farther stop, Lake View');
    expect(find.text('Add Staff'), findsOneWidget);
    expect(find.textContaining('1 active staff member'), findsOneWidget);
    expect(find.text('LEFT'), findsNothing);
  });

  testWidgets('a staff member no longer active is marked Left', (t) async {
    await open(t, rows: [ravi(active: false)]);
    expect(find.text('LEFT'), findsOneWidget);
  });

  testWidgets('Add Staff offers the staff given; one already on a route cannot be ticked', (t) async {
    await open(t);
    await t.tap(find.text('Add Staff'));
    await t.pumpAndSettle();
    expect(find.text('Add staff'), findsOneWidget);
    expect(find.text('All designations'), findsOneWidget);
    // (chips show their text in capitals)
    expect(find.text('ON THIS ROUTE'), findsOneWidget, reason: 'RAVI');
    expect(find.text('ON A2'), findsOneWidget, reason: 'MANI');
    await t.tap(find.byKey(const ValueKey('enr-add-6')));
    await t.tap(find.byKey(const ValueKey('enr-add-5')));
    await t.pump();
    expect(find.text('Add 1 Staff Member'), findsOneWidget, reason: 'MANI cannot be ticked');
    await t.tap(find.byKey(const ValueKey('enr-add-7')));
    await t.pump();
    await t.tap(find.text('Add 2 Staff'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('SITA'), findsOneWidget);
    expect(find.text('VANI'), findsOneWidget);
    expect(find.text('MANI'), findsNothing);
    expect(find.text('NEW'), findsNWidgets(2));
    // no stops yet: saving says so, naming the staff member, and sends nothing
    await t.tap(find.text('Save 2 Changes'));
    await t.pump();
    expect(find.text('Choose the pickup stop of EMP003 SITA.'), findsOneWidget);
    expect(sent, isEmpty);
  });

  testWidgets('stops dragged onto staff are saved under staf_id', (t) async {
    await open(t);
    await t.tap(find.text('Add Staff'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('enr-add-5')));
    await t.tap(find.byKey(const ValueKey('enr-add-7')));
    await t.pump();
    await t.tap(find.text('Add 2 Staff'));
    await t.pumpAndSettle();
    await dragStop(t, 12, find.byKey(const ValueKey('enr-who-s5'))); // Main Road onto SITA
    await dragStop(t, 11, find.byKey(const ValueKey('enr-who-s7'))); // Mill Gate onto VANI
    await dragStop(t, 13, find.byKey(const ValueKey('enr-dropzone-s7'))); // Lake View onto VANI's drop
    expect(t.takeException(), isNull);
    await t.tap(find.text('Save 2 Changes'));
    await t.pumpAndSettle();
    expect(sent, [
      {'staf_id': 5, 'service_type': 'BOTH', 'pickup_stop_id': 12, 'drop_stop_id': 12, 'start_date': '2026-11-13', 'end_date': null, 'status': 'ACTIVE'},
      {'staf_id': 7, 'service_type': 'BOTH', 'pickup_stop_id': 11, 'drop_stop_id': 13, 'start_date': '2026-11-13', 'end_date': null, 'status': 'ACTIVE'},
    ]);
    expect(find.text('Saved 2 staff.'), findsOneWidget);
  });

  testWidgets('a saved staff member\'s change is sent with the enrollment and its updated_at', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('enr-trip-e9-BOTH')));
    await t.pumpAndSettle();
    await t.tap(find.text('Pickup').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Save 1 Change'));
    await t.pumpAndSettle();
    expect(sent, [
      {
        'enrollment_id': 9, 'updated_at': '2026-11-13T10:00:00+00:00', 'staf_id': 4, 'service_type': 'PICKUP',
        'pickup_stop_id': 11, 'drop_stop_id': null, 'start_date': '2026-06-01', 'end_date': null, 'status': 'ACTIVE',
      },
    ]);
  });
}
