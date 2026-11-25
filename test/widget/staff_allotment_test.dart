import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/transport/vehicle_allotment_screen.dart';

// Vehicle Allotment with staff: route A1's pickup on BUS-07 (3 seats). ANU is
// in it; BALA (a student) and RAVI (staff, whose enrollment is also numbered
// 101, like ANU's) have no vehicle yet.
void main() {
  final route = {'route_id': 1, 'route_code': 'A1', 'route_name': 'Kolumam', 'is_active': true};
  final trips = [
    {
      'schedule_id': 31, 'schedule_code': 'KLM-P', 'route_id': 1, 'direction': 'PICKUP', 'vehicle_id': 7,
      'planned_start': '08:00:00', 'planned_end': '09:00:00', 'run_days': [1, 2, 3, 4, 5, 6], 'is_active': true,
    },
  ];
  final vehicles = [
    {'vehicle_id': 7, 'vehicle_code': 'BUS-07', 'registration_no': 'TN01AB1234', 'vehicle_type': 'BUS', 'seating_capacity': 3, 'status': 'ACTIVE'},
  ];
  final stops = [
    {'stop_id': 11, 'route_id': 1, 'stop_seq': 1, 'stop_name': 'Mill Gate', 'is_active': true},
  ];
  Map<String, dynamic> student(int id, String name, {int? trip}) => {
        'enrollment_id': id, 'student_id': id + 400, 'route_id': 1, 'service_type': 'BOTH', 'status': 'ACTIVE',
        'pickup_stop_id': 11, 'drop_stop_id': 11, 'pickup_schedule_id': trip, 'drop_schedule_id': null, 'updated_at': 'u$id',
        'stuadmno': 'ADM$id', 'stuname': name, 'stuclass': 'LKG A',
      };
  // as tr_list 'staff_allotment' gives it
  final ravi = {
    'enrollment_id': 101, 'staf_id': 4, 'route_id': 1, 'service_type': 'BOTH', 'status': 'ACTIVE',
    'pickup_stop_id': 11, 'drop_stop_id': 11, 'pickup_schedule_id': null, 'drop_schedule_id': null, 'updated_at': 's101',
    'emp_code': 'EMP002', 'stafname': 'RAVI', 'designation': 'Teacher', 'staff_active': true, 'transportreq': 'BUS',
  };

  test('staff join the riders under a negative id, shown like a student', () {
    final riders = allotmentRiders([student(101, 'ANU', trip: 31)], [ravi]);
    expect([for (final r in riders) r['enrollment_id']], [101, -101], reason: 'the same enrollment number stays apart');
    expect(riders[1]['stuadmno'], 'EMP002');
    expect(riders[1]['stuname'], 'RAVI');
    expect(riders[1]['stuclass'], 'Staff · Teacher');
    expect(riders[1]['is_staff'], isTrue);
    expect(riders[1]['staff_enrollment_id'], 101);
  });

  test('a save sends the students as rows and the staff as staff_rows, under their own ids', () {
    final p = allotmentPayload(1, 'PICKUP', [
      {'enrollment_id': 102, 'schedule_id': 31, 'updated_at': 'u102'},
      {'enrollment_id': -101, 'schedule_id': 31, 'updated_at': 's101'},
    ]);
    expect(p, {
      'route_id': 1,
      'direction': 'PICKUP',
      'rows': [
        {'enrollment_id': 102, 'schedule_id': 31, 'updated_at': 'u102'},
      ],
      'staff_rows': [
        {'enrollment_id': 101, 'schedule_id': 31, 'updated_at': 's101'},
      ],
    });
  });

  testWidgets('All / Students / Staff picks who Not Allotted shows; ticks stay on the shown only', (t) async {
    await t.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1680,
            height: 950,
            child: AllotmentBoard(
              route: route,
              direction: 'PICKUP',
              trips: trips,
              vehicles: vehicles,
              stops: stops,
              enrollments: allotmentRiders([student(101, 'ANU', trip: 31), student(102, 'BALA')], [ravi]),
              onSave: (_) async {},
            ),
          ),
        ),
      ),
    ));
    await t.pump();
    expect(find.text('All · 2'), findsOneWidget);
    expect(find.text('Students · 1'), findsOneWidget);
    expect(find.text('Staff · 1'), findsOneWidget);

    // tick both, then show the staff only: BALA is hidden and unticked
    await t.tap(find.descendant(of: find.byKey(const ValueKey('al-waiting')), matching: find.byType(Checkbox)).first);
    await t.pump();
    expect(find.text('2 ticked'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('al-who-STAFF')));
    await t.pump();
    expect(find.text('RAVI'), findsOneWidget);
    expect(find.text('BALA'), findsNothing);
    expect(find.text('1 ticked'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('al-who-STUDENTS')));
    await t.pump();
    expect(find.text('BALA'), findsOneWidget);
    expect(find.text('RAVI'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('a route with no staff shows no All / Students / Staff choice', (t) async {
    await t.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1680,
            height: 950,
            child: AllotmentBoard(
              route: route,
              direction: 'PICKUP',
              trips: trips,
              vehicles: vehicles,
              stops: stops,
              enrollments: allotmentRiders([student(102, 'BALA')], const []),
              onSave: (_) async {},
            ),
          ),
        ),
      ),
    ));
    await t.pump();
    expect(find.byKey(const ValueKey('al-who-STAFF')), findsNothing);
    expect(find.text('BALA'), findsOneWidget);
  });

  testWidgets('a staff member is listed, goes into a vehicle with the students and is saved as staff', (t) async {
    var sent = <Map<String, dynamic>>[];
    await t.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1680,
            height: 950,
            child: AllotmentBoard(
              route: route,
              direction: 'PICKUP',
              trips: trips,
              vehicles: vehicles,
              stops: stops,
              enrollments: allotmentRiders([student(101, 'ANU', trip: 31), student(102, 'BALA')], [ravi]),
              onSave: (rows) async => sent = rows,
            ),
          ),
        ),
      ),
    ));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('NOT ALLOTTED · 2'), findsOneWidget);
    expect(find.text('RAVI'), findsOneWidget);
    expect(find.textContaining('Staff · Teacher'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget, reason: 'ANU in BUS-07');

    // RAVI goes in beside ANU
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('al-wait--101'))));
    await t.pump(const Duration(milliseconds: 20));
    await g.moveBy(const Offset(40, 0));
    await t.pump();
    await g.moveTo(t.getCenter(find.byKey(const ValueKey('al-trip-31'))));
    await t.pump();
    await g.up();
    await t.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    await t.tap(find.text('Save 1 Change'));
    await t.pumpAndSettle();
    expect(sent, [
      {'enrollment_id': -101, 'schedule_id': 31, 'updated_at': 's101'},
    ]);
    expect(allotmentPayload(1, 'PICKUP', sent)['staff_rows'], [
      {'enrollment_id': 101, 'schedule_id': 31, 'updated_at': 's101'},
    ]);
  });
}
