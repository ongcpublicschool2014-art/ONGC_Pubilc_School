import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/admin/staff_screen.dart';
import 'package:school_admin/screens/transport/duty_roster_screen.dart';
import 'package:school_admin/screens/transport/gps_mapping_panel.dart';
import 'package:school_admin/screens/transport/routes_stops_screen.dart';
import 'package:school_admin/screens/transport/stage_fee_process_dialog.dart';
import 'package:school_admin/screens/transport/stage_fees_screen.dart';
import 'package:school_admin/screens/transport/student_enrollment_screen.dart';
import 'package:school_admin/screens/transport/transport_master_panel.dart';
import 'package:school_admin/screens/transport/transport_setup_screen.dart';
import 'package:school_admin/screens/transport/transport_staff_screen.dart';
import 'package:school_admin/screens/transport/trip_schedules_screen.dart';
import 'package:school_admin/screens/transport/vehicle_allotment_screen.dart';
import 'package:school_admin/screens/transport/vehicles_screen.dart';
import 'package:school_admin/utils/app_text.dart';
import 'package:school_admin/widgets/app_ui.dart';

/// Each transport screen has to lay out inside the dashboard's bounded area.
/// With no server in a test the lists land on their error state, and the
/// screen's frame must still draw: a layout error here leaves the page blank
/// in a release build, with nothing shown to the user.
void main() {
  final screens = <String, Widget Function()>{
    'Transport Setup': () => const TransportSetupScreen(),
    'Routes & Stops': () => const RoutesStopsScreen(),
    'Vehicles': () => const VehiclesScreen(),
    'GPS Mapping': () => const GpsMappingPanel(),
    'Transport Staff': () => const TransportStaffScreen(),
    'Trip Schedules': () => const TripSchedulesScreen(),
    'Duty Roster': () => const DutyRosterScreen(),
    'Student Enrollment': () => const StudentEnrollmentScreen(),
    'Vehicle Allotment': () => const VehicleAllotmentScreen(),
    'Stage Fees': () => const StageFeesScreen(),
    // Staff Details uses the same panel on its own functions (staff_*).
    'Staff Details': () => const StaffScreen(),
  };

  testWidgets('the search box lays out in a header row, as on every screen', (t) async {
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: AppUI.cardHeader(icon: 'bus', title: 'T', trailing: [
            SizedBox(width: 220, child: TrSearchField(hint: 'Search', onChanged: (_) {})),
          ]),
        ),
      ),
    ));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('Search'), findsOneWidget);
  });

  // Staff Details' password: never filled in from the record, typed hidden,
  // and sent only when typed (blank keeps the current one on the server).
  testWidgets('a password field starts empty and hides what is typed', (t) async {
    final key = GlobalKey<TrFormBodyState>();
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TrFormBody(key: key, initial: const {'password': r'$2a$10$hash'}, fields: const [
              TrField('password', 'Password', kind: TrKind.password),
            ]),
          ),
        ),
      ),
    ));
    await t.pump();
    final field = t.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.controller!.text, isEmpty);
    expect(key.currentState!.collect(), {'password': null});
    await t.enterText(find.byType(TextField), 'secret12');
    expect(key.currentState!.collect(), {'password': 'secret12'});
  });

  // A photo field sits in the form's top-right corner, beside the first group
  // (above it, still on the right, when the form is too narrow), wherever it
  // is in the field list.
  for (final width in const [380.0, 480.0, 712.0]) {
    testWidgets('a form photo sits top-right at width ${width.toInt()}', (t) async {
      await t.binding.setSurfaceSize(const Size(1366, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: const TrFormBody(fields: [
                    TrField('code', 'Code', section: 'Staff'),
                    TrField('name', 'Name'),
                    TrField('mobile', 'Mobile', kind: TrKind.mobile),
                    TrField('address', 'Address', kind: TrKind.multiline, full: true),
                    TrField('licence', 'Licence', section: 'Licence'),
                    TrField('photo', 'Photo', kind: TrKind.photo),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
      final photo = t.getRect(find.text('Add photo'));
      expect(photo.left, greaterThan(width / 2), reason: 'on the right');
      expect(t.getRect(find.text('Code')).left, lessThan(photo.left), reason: 'fields to its left');
      expect(photo.top, lessThan(t.getRect(find.text('Licence')).top), reason: 'with the first group');
    });
  }

  testWidgets('a document attachment shows its file name, or Attach File when empty', (t) async {
    await t.binding.setSurfaceSize(const Size(1366, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    const field = TrField('file_url', 'Attachment', kind: TrKind.file, full: true);
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 712,
            child: Column(children: [
              TrFormBody(fields: [field], initial: {
                'file_url': 'https://x.supabase.co/storage/v1/object/public/InstitutionLogos/transport/vehicle-docs/1731300000000000_RC_Book.pdf',
              }),
              TrFormBody(fields: [field]),
            ]),
          ),
        ),
      ),
    ));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('RC_Book.pdf'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);
    expect(find.text('Attach File'), findsOneWidget);
  });

  // Every transport date is typed day first: 01/04/2026 is 1 April.
  testWidgets('the date picker takes dd/mm/yyyy', (t) async {
    await t.binding.setSurfaceSize(const Size(1366, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    DateTime? picked;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                picked = await trPickDate(context, initialDate: DateTime(2026, 4, 1), firstDate: DateTime(2000), lastDate: DateTime(2030)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Wed, 1 Apr'), findsOneWidget);
    await t.tap(find.byTooltip('Switch to input'));
    await t.pumpAndSettle();
    expect(find.text('01/04/2026'), findsOneWidget);
    expect(find.text('dd/mm/yyyy'), findsWidgets);
    await t.enterText(find.byType(TextField), '15/04/2026');
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(picked, DateTime(2026, 4, 15));
  });

  // Delete is in the edit dialog (an existing record), not on the list.
  for (final editing in const [true, false]) {
    testWidgets('the form dialog ${editing ? 'offers' : 'has no'} Delete when ${editing ? 'editing' : 'adding'}', (t) async {
      await t.binding.setSurfaceSize(const Size(1366, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTrFormDialog(context,
                    entity: 'route',
                    pk: 'route_id',
                    title: 'Edit route',
                    icon: 'routing',
                    fields: const [TrField('route_name', 'Route Name')],
                    initial: editing ? const {'route_id': 5, 'route_name': 'North Line'} : const {},
                    delete: const TrDelete('Delete route R5?', 'The route is switched off.')),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Delete'), editing ? findsOneWidget : findsNothing);
      if (!editing) return;
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(find.text('Delete route R5?'), findsOneWidget, reason: 'asks first');
      await t.tap(find.text('Cancel').last);
      await t.pumpAndSettle();
      expect(find.text('Edit route'), findsOneWidget, reason: 'the edit dialog stays open');
    });
  }

  // Duty Roster's staff field: only the staff of the chosen duty, and a
  // change of duty clears a staff member who no longer fits.
  testWidgets('a choice can follow another field: the staff of the chosen duty', (t) async {
    await t.binding.setSurfaceSize(const Size(1366, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    const staff = [(1, 'Kumar R', 'DRIVER'), (2, 'Mani S', 'ATTENDER')];
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 712,
            child: TrFormBody(initial: const {'duty_role': 'DRIVER', 'staff_id': 1}, fields: [
              const TrField('duty_role', 'Duty', kind: TrKind.choice, required: true, options: [('DRIVER', 'Driver'), ('ATTENDER', 'Attender')]),
              TrField('staff_id', 'Staff Member', kind: TrKind.choice, required: true, hint: 'Staff of the chosen duty',
                  optionsFor: (v) => [for (final s in staff) if (s.$3 == v['duty_role']) (s.$1, s.$2)]),
            ]),
          ),
        ),
      ),
    ));
    await t.pump();
    expect(find.text('Kumar R'), findsOneWidget);
    await t.tap(find.text('Kumar R'));
    await t.pumpAndSettle();
    expect(find.text('Mani S'), findsNothing, reason: 'an attender is not offered for the Driver duty');
    await t.tap(find.text('Kumar R').last);
    await t.pumpAndSettle();

    await t.tap(find.text('Driver'));
    await t.pumpAndSettle();
    await t.tap(find.text('Attender').last);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('Kumar R'), findsNothing, reason: 'the driver no longer fits, so the choice is cleared');
    expect(find.text('Staff of the chosen duty'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tr-staff_id-null')));
    await t.pumpAndSettle();
    expect(find.text('Mani S'), findsWidgets);
    expect(find.text('Kumar R'), findsNothing);
  });

  // The schedule dialog with a route of three stops: Mill Gate, Main Road,
  // Lake View. The schedule serves the first and the last.
  group('trip schedule dialog', () {
    final routes = [
      {'route_id': 1, 'route_code': 'R5', 'route_name': 'North Line', 'is_active': true},
    ];
    final stops = [
      {'stop_id': 11, 'route_id': 1, 'stop_seq': 1, 'stop_name': 'Mill Gate', 'is_active': true},
      {'stop_id': 12, 'route_id': 1, 'stop_seq': 2, 'stop_name': 'Main Road', 'is_active': true},
      {'stop_id': 13, 'route_id': 1, 'stop_seq': 3, 'stop_name': 'Lake View', 'is_active': true},
    ];
    final vehicles = [
      {'vehicle_id': 7, 'vehicle_code': 'BUS-07', 'registration_no': 'TN01AB1234', 'seating_capacity': 40, 'status': 'ACTIVE'},
    ];
    Map<String, dynamic> schedule(String direction) => {
          'schedule_id': 3,
          'schedule_code': 'R5-AM',
          'schedule_name': 'Morning',
          'route_id': 1,
          'direction': direction,
          'vehicle_id': 7,
          'planned_start': '07:00:00',
          'planned_end': '08:00:00',
          'run_days': [1, 2, 3, 4, 5, 6],
          'effective_from': '2026-06-01',
          'is_active': true,
          'stops': [
            {'stop_id': 11, 'visit_seq': 1, 'planned_time': '07:05:00', 'halt_minutes': 1},
            {'stop_id': 13, 'visit_seq': 2, 'planned_time': '07:30:00', 'halt_minutes': 2},
          ],
        };
    Future<void> open(WidgetTester t, Map<String, dynamic>? initial, {Size size = const Size(1366, 768)}) async {
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(body: TripScheduleDialog(initial: initial, routes: routes, stops: stops, vehicles: vehicles)),
        ),
      ));
      await t.pump();
    }

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets('lays out with its stops at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
        await open(t, schedule('PICKUP'), size: size);
        expect(t.takeException(), isNull);
        expect(find.text('Mill Gate'), findsOneWidget);
        expect(find.text('Main Road'), findsOneWidget);
        expect(find.text('7:05 AM'), findsOneWidget);
        expect(find.text('7:30 AM'), findsOneWidget);
        expect(find.textContaining('2 of 3 ticked'), findsOneWidget);
      });
    }

    testWidgets('a new schedule asks for the route first', (t) async {
      await open(t, null);
      expect(t.takeException(), isNull);
      expect(find.text('Choose the route to list its stops.'), findsOneWidget);
    });

    // stops as the dialog saves a drop: in visit order, the last stop first
    testWidgets('a drop runs the route from the last stop to the first', (t) async {
      await open(t, {
        ...schedule('DROP'),
        'stops': [
          {'stop_id': 13, 'visit_seq': 1, 'planned_time': '07:05:00', 'halt_minutes': 1},
          {'stop_id': 11, 'visit_seq': 2, 'planned_time': '07:30:00', 'halt_minutes': 2},
        ],
      });
      expect(t.getRect(find.text('Lake View')).top, lessThan(t.getRect(find.text('Mill Gate')).top));
      expect(find.textContaining('Drop: the route\'s stops from the last to the first'), findsOneWidget);
    });

    // a route numbered from the school outward: its pickup runs the other way
    testWidgets('reverse order turns the stops round, and they keep their times', (t) async {
      await open(t, schedule('PICKUP'));
      expect(t.getRect(find.text('Mill Gate')).top, lessThan(t.getRect(find.text('Lake View')).top));
      await t.tap(find.text('Reverse order'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(t.getRect(find.text('Lake View')).top, lessThan(t.getRect(find.text('Mill Gate')).top));
      expect(t.getRect(find.text('7:05 AM')).top, closeTo(t.getRect(find.text('Mill Gate')).top, 30), reason: 'the time stays with its stop');
      expect(find.textContaining('from the last to the first'), findsOneWidget);
    });

    testWidgets('a pickup saved from the last stop to the first opens that way', (t) async {
      await open(t, {
        ...schedule('PICKUP'),
        'stops': [
          {'stop_id': 13, 'visit_seq': 1, 'planned_time': '07:05:00', 'halt_minutes': 1},
          {'stop_id': 11, 'visit_seq': 2, 'planned_time': '07:30:00', 'halt_minutes': 2},
        ],
      });
      expect(t.getRect(find.text('Lake View')).top, lessThan(t.getRect(find.text('Mill Gate')).top));
    });

    testWidgets('spread times evenly puts the ticked stops between start and end', (t) async {
      await open(t, schedule('PICKUP'));
      await t.tap(find.text('Spread times evenly'));
      await t.pumpAndSettle();
      await t.tap(find.text('Replace')); // times were already set
      await t.pumpAndSettle();
      // two ticked stops over 7:00-8:00 on a pickup: 7:00 and 7:30
      expect(find.text('7:05 AM'), findsNothing);
      expect(find.text('7:00 AM'), findsNWidgets(2)); // the start time and Mill Gate
      expect(find.text('7:30 AM'), findsOneWidget);
    });
  });

  // Student Enrollment on route A1: Mill Gate and Main Road (stage 1), Lake
  // View (stage 2). ANU is on it (up at Mill Gate, down at Lake View). Of the
  // year's other students BALA and DEVI have no transport; CHITRA is on A2.
  group('enrollment board', () {
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
    final students = [
      {'stu_id': 501, 'stuadmno': 'ADM1', 'stuname': 'ANU', 'stuclass': 'LKG A', 'route_id': 1, 'route_code': 'A1'},
      {'stu_id': 502, 'stuadmno': 'ADM2', 'stuname': 'BALA', 'stuclass': 'LKG A'},
      {'stu_id': 503, 'stuadmno': 'ADM3', 'stuname': 'CHITRA', 'stuclass': 'UKG B', 'route_id': 2, 'route_code': 'A2'},
      {'stu_id': 504, 'stuadmno': 'ADM4', 'stuname': 'DEVI', 'stuclass': 'UKG B'},
    ];
    final enrollments = [
      {
        'enrollment_id': 9, 'student_id': 501, 'route_id': 1, 'service_type': 'BOTH', 'pickup_stop_id': 11, 'drop_stop_id': 13,
        'fee_stage_id': 22, 'start_date': '2026-06-01', 'end_date': null, 'status': 'ACTIVE', 'updated_at': '2026-11-13T10:00:00+00:00',
        'stuadmno': 'ADM1', 'stuname': 'ANU', 'stuclass': 'LKG A', 'stu_status': 1,
      },
    ];
    var sent = <Map<String, dynamic>>[];

    Future<void> open(WidgetTester t, {Size size = const Size(1920, 1080), List<Map<String, dynamic>>? rows}) async {
      sent = [];
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: size.width - 240,
              height: size.height - 130,
              child: EnrollmentBoard(
                route: route,
                stages: stages,
                stops: stops,
                enrollments: rows ?? enrollments,
                students: students,
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

    /// Adds BALA and DEVI with Add Students.
    Future<void> addTwo(WidgetTester t) async {
      await t.tap(find.text('Add Students'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('enr-add-502')));
      await t.tap(find.byKey(const ValueKey('enr-add-504')));
      await t.pump();
      await t.tap(find.text('Add 2 Students'));
      await t.pumpAndSettle();
    }

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets('lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
        await open(t, size: size);
        expect(t.takeException(), isNull);
        expect(find.text('ANU'), findsOneWidget);
        expect(find.text('Stage 2'), findsOneWidget, reason: 'the stage of the farther stop, Lake View');
        expect(find.text('↑1  ↓0'), findsOneWidget, reason: 'Mill Gate: ANU gets on there');
        expect(find.text('↑0  ↓1'), findsOneWidget, reason: 'Lake View: ANU gets off there');
      });
    }

    testWidgets('a long list keeps its up-and-down scrollbar in sight; dragging it scrolls', (t) async {
      final many = [
        for (var k = 1; k <= 40; k++)
          {
            ...enrollments[0],
            'enrollment_id': 100 + k, 'student_id': 600 + k,
            'stuadmno': 'ADM${600 + k}', 'stuname': 'STUDENT ${k.toString().padLeft(2, '0')}',
          },
      ];
      // 1366 wide: the table also scrolls sideways
      await open(t, size: const Size(1366, 768), rows: many);
      await t.pumpAndSettle(); // the scrollbar shows its thumb a frame later
      expect(t.takeException(), isNull);
      final bar = t.getRect(find.byKey(const ValueKey('enr-vbar')));
      expect(bar.right, lessThanOrEqualTo(1366 - 240), reason: 'at the panel edge, not off past the wide table');
      expect(find.text('STUDENT 40'), findsNothing);
      // the thumb starts at the top right: drag it to the bottom with a mouse,
      // as on the school's Windows PCs (a phone's scrollbar is not draggable)
      await t.dragFrom(Offset(bar.right - 4, bar.top + 30), Offset(0, bar.height), kind: PointerDeviceKind.mouse);
      await t.pumpAndSettle();
      expect(find.text('STUDENT 40'), findsOneWidget, reason: 'the last student comes into view');
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Add Students: Down / Up move along the rows, Space or Enter ticks', (t) async {
      await open(t);
      await t.tap(find.text('Add Students'));
      await t.pumpAndSettle();
      Future<void> press(LogicalKeyboardKey k) async {
        await t.sendKeyEvent(k);
        await t.pumpAndSettle();
      }

      // rows: ANU (on this route), BALA, CHITRA (on A2), DEVI
      await press(LogicalKeyboardKey.arrowDown); // ANU
      await press(LogicalKeyboardKey.space);
      expect(find.textContaining('0 ticked'), findsOneWidget, reason: 'ANU is already on this route');
      await press(LogicalKeyboardKey.arrowDown); // BALA
      await press(LogicalKeyboardKey.space);
      expect(find.textContaining('1 ticked'), findsOneWidget);
      await press(LogicalKeyboardKey.arrowDown); // CHITRA
      await press(LogicalKeyboardKey.enter);
      expect(find.textContaining('1 ticked'), findsOneWidget, reason: 'CHITRA is on A2');
      await press(LogicalKeyboardKey.arrowDown); // DEVI
      await press(LogicalKeyboardKey.enter);
      expect(find.textContaining('2 ticked'), findsOneWidget);
      await press(LogicalKeyboardKey.arrowDown); // stays on DEVI, the last row
      await press(LogicalKeyboardKey.arrowUp); // CHITRA
      await press(LogicalKeyboardKey.arrowUp); // BALA
      await press(LogicalKeyboardKey.space); // untick BALA
      expect(find.textContaining('1 ticked'), findsOneWidget);
      await t.tap(find.text('Add 1 Student'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('DEVI'), findsOneWidget);
      expect(find.text('BALA'), findsNothing);
    });

    testWidgets('Add Students adds the ticked students; one already on a route cannot be ticked', (t) async {
      await open(t);
      await t.tap(find.text('Add Students'));
      await t.pumpAndSettle();
      // (chips show their text in capitals)
      expect(find.text('ON THIS ROUTE'), findsOneWidget, reason: 'ANU');
      expect(find.text('ON A2'), findsOneWidget, reason: 'CHITRA');
      await t.tap(find.byKey(const ValueKey('enr-add-503')));
      await t.tap(find.byKey(const ValueKey('enr-add-502')));
      await t.tap(find.byKey(const ValueKey('enr-add-504')));
      await t.pump();
      await t.tap(find.text('Add 2 Students'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('BALA'), findsOneWidget);
      expect(find.text('DEVI'), findsOneWidget);
      expect(find.text('CHITRA'), findsNothing);
      expect(find.text('NEW'), findsNWidgets(2));
      // no stops yet: saving says so, naming the student, and sends nothing
      await t.tap(find.text('Save 2 Changes'));
      await t.pump();
      expect(find.text('Choose the pickup stop of ADM2 BALA.'), findsOneWidget);
      expect(sent, isEmpty);
    });

    testWidgets('a stop dragged onto a student sets both stops; onto a column, that one', (t) async {
      await open(t);
      await addTwo(t);
      await dragStop(t, 12, find.byKey(const ValueKey('enr-who-s502'))); // Main Road onto BALA
      await dragStop(t, 11, find.byKey(const ValueKey('enr-who-s504'))); // Mill Gate onto DEVI
      await dragStop(t, 13, find.byKey(const ValueKey('enr-dropzone-s504'))); // Lake View onto DEVI's drop
      expect(t.takeException(), isNull);
      await t.tap(find.text('Save 2 Changes'));
      await t.pumpAndSettle();
      expect(sent, [
        {'student_id': 502, 'service_type': 'BOTH', 'pickup_stop_id': 12, 'drop_stop_id': 12, 'start_date': '2026-11-13', 'end_date': null, 'status': 'ACTIVE'},
        {'student_id': 504, 'service_type': 'BOTH', 'pickup_stop_id': 11, 'drop_stop_id': 13, 'start_date': '2026-11-13', 'end_date': null, 'status': 'ACTIVE'},
      ]);
    });

    testWidgets('a stop dropped on a ticked student goes to every ticked student', (t) async {
      await open(t);
      await addTwo(t);
      for (final k in ['s502', 's504']) {
        await t.tap(find.descendant(of: find.byKey(ValueKey('enr-row-$k')), matching: find.byType(Checkbox)));
      }
      await t.pump();
      expect(find.text('2 ticked: set'), findsOneWidget);
      await dragStop(t, 13, find.byKey(const ValueKey('enr-who-s502'))); // Lake View onto BALA, ticked with DEVI
      await t.tap(find.text('Save 2 Changes'));
      await t.pumpAndSettle();
      expect([for (final r in sent) '${r['student_id']}:${r['pickup_stop_id']}:${r['drop_stop_id']}'], ['502:13:13', '504:13:13']);
    });

    testWidgets('a pickup-only student has no drop stop, and saves without one', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('enr-trip-e9-BOTH')));
      await t.pumpAndSettle();
      await t.tap(find.text('Pickup').last);
      await t.pumpAndSettle();
      expect(find.text('Stage 1'), findsOneWidget, reason: 'only Mill Gate counts now');
      await t.tap(find.text('Save 1 Change'));
      await t.pumpAndSettle();
      expect(sent, [
        {
          'enrollment_id': 9, 'updated_at': '2026-11-13T10:00:00+00:00', 'student_id': 501, 'service_type': 'PICKUP',
          'pickup_stop_id': 11, 'drop_stop_id': null, 'start_date': '2026-06-01', 'end_date': null, 'status': 'ACTIVE',
        },
      ]);
    });

    testWidgets('the stops are listed in route order, and the search finds one', (t) async {
      await open(t);
      expect(find.textContaining('STAGE 1'), findsNothing, reason: 'no stage headings on the left (the list keeps its Stage column)');
      expect(t.getRect(find.byKey(const ValueKey('enr-stop-11'))).top, lessThan(t.getRect(find.byKey(const ValueKey('enr-stop-13'))).top));
      await t.enterText(find.descendant(of: find.byKey(const ValueKey('enr-stop-search')), matching: find.byType(TextField)), 'lake');
      await t.pump();
      expect(find.byKey(const ValueKey('enr-stop-13')), findsOneWidget);
      expect(find.byKey(const ValueKey('enr-stop-11')), findsNothing);
      expect(find.byKey(const ValueKey('enr-stop-12')), findsNothing);
    });

    testWidgets('clicking a stop shows only its students', (t) async {
      await open(t);
      await addTwo(t);
      await t.tap(find.byKey(const ValueKey('enr-stop-13'))); // Lake View
      await t.pumpAndSettle();
      expect(find.text('ANU'), findsOneWidget);
      expect(find.text('BALA'), findsNothing);
      expect(find.text('At Lake View'), findsOneWidget);
    });
  });

  // Vehicle Allotment on route A1, Pickup: BUS-07 (3 seats) runs trip KLM-P
  // at 8:00, VAN-02 (10 seats) runs KLM-P2 at 7:30. ANU is in BUS-07; BALA,
  // CHITRA (pickup only) and DEVI have no vehicle. EZHIL travels Drop only
  // and FATHIMA is cancelled, so neither is listed for the pickup.
  group('vehicle allotment board', () {
    final route = {'route_id': 1, 'route_code': 'A1', 'route_name': 'Kolumam', 'is_active': true};
    final trips = [
      {
        'schedule_id': 31, 'schedule_code': 'KLM-P', 'route_id': 1, 'direction': 'PICKUP', 'vehicle_id': 7,
        'planned_start': '08:00:00', 'planned_end': '09:00:00', 'run_days': [1, 2, 3, 4, 5, 6], 'is_active': true,
      },
      {
        'schedule_id': 32, 'schedule_code': 'KLM-P2', 'route_id': 1, 'direction': 'PICKUP', 'vehicle_id': 8,
        'planned_start': '07:30:00', 'planned_end': '08:30:00', 'run_days': [1, 2, 3, 4, 5, 6], 'is_active': true,
      },
    ];
    final vehicles = [
      {'vehicle_id': 7, 'vehicle_code': 'BUS-07', 'registration_no': 'TN01AB1234', 'vehicle_type': 'BUS', 'seating_capacity': 3, 'status': 'ACTIVE'},
      {'vehicle_id': 8, 'vehicle_code': 'VAN-02', 'registration_no': 'TN01CD5678', 'vehicle_type': 'VAN', 'seating_capacity': 10, 'status': 'ACTIVE'},
    ];
    final stops = [
      {'stop_id': 11, 'route_id': 1, 'stop_seq': 1, 'stop_name': 'Mill Gate', 'is_active': true},
      {'stop_id': 13, 'route_id': 1, 'stop_seq': 3, 'stop_name': 'Lake View', 'is_active': true},
    ];
    Map<String, dynamic> enr(int id, String name, String type, {required int stop, int? trip, int? drop, String status = 'ACTIVE'}) => {
          'enrollment_id': id, 'student_id': id + 400, 'route_id': 1, 'service_type': type, 'status': status,
          'pickup_stop_id': type == 'DROP' ? null : stop, 'drop_stop_id': type == 'PICKUP' ? null : stop,
          'pickup_schedule_id': trip, 'drop_schedule_id': drop, 'updated_at': 'u$id',
          'stuadmno': 'ADM$id', 'stuname': name, 'stuclass': 'LKG A',
        };
    final enrollments = [
      enr(101, 'ANU', 'BOTH', stop: 11, trip: 31),
      enr(102, 'BALA', 'BOTH', stop: 13),
      enr(103, 'CHITRA', 'PICKUP', stop: 11),
      enr(104, 'DEVI', 'BOTH', stop: 11),
      enr(105, 'EZHIL', 'DROP', stop: 13),
      enr(106, 'FATHIMA', 'BOTH', stop: 13, status: 'CANCELLED'),
    ];
    var sent = <Map<String, dynamic>>[];

    Future<void> open(
      WidgetTester t, {
      Size size = const Size(1920, 1080),
      List<Map<String, dynamic>>? rows,
      List<Map<String, dynamic>> otherTrips = const [],
      List<Map<String, dynamic>>? vehicleRows,
    }) async {
      sent = [];
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: size.width - 240,
              height: size.height - 130,
              child: AllotmentBoard(
                route: route,
                direction: 'PICKUP',
                trips: trips,
                otherTrips: otherTrips,
                vehicles: vehicleRows ?? vehicles,
                stops: stops,
                enrollments: rows ?? enrollments,
                onSave: (rows) async => sent = rows,
              ),
            ),
          ),
        ),
      ));
      await t.pump();
    }

    Future<void> dragTo(WidgetTester t, Finder from, Finder to) async {
      final g = await t.startGesture(t.getCenter(from));
      await t.pump(const Duration(milliseconds: 20));
      await g.moveBy(const Offset(40, 0));
      await t.pump();
      await g.moveTo(t.getCenter(to));
      await t.pump();
      await g.up();
      await t.pumpAndSettle();
    }

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets('lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
        await open(t, size: size);
        expect(t.takeException(), isNull);
        expect(find.text('NOT ALLOTTED · 3'), findsOneWidget);
        for (final name in ['BALA', 'CHITRA', 'DEVI']) {
          expect(find.text(name), findsOneWidget);
        }
        expect(find.text('EZHIL'), findsNothing, reason: 'drop only');
        expect(find.text('FATHIMA'), findsNothing, reason: 'cancelled');
        expect(find.text('1/3'), findsOneWidget, reason: 'BUS-07 card, with ANU');
        expect(find.text('0/10'), findsOneWidget, reason: 'VAN-02 card');
        expect(find.text('0 of 10 seats · 10 free'), findsOneWidget, reason: 'VAN-02, the first trip, open on the right');
      });
    }

    testWidgets('a student dragged onto a vehicle goes in, and is saved with it', (t) async {
      await open(t);
      expect(find.text('Undo All'), findsNothing, reason: 'nothing to undo yet');
      await dragTo(t, find.byKey(const ValueKey('al-wait-102')), find.byKey(const ValueKey('al-trip-31')));
      expect(t.takeException(), isNull);
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('NOT ALLOTTED · 2'), findsOneWidget);
      expect(find.text('Undo All'), findsOneWidget);
      await t.tap(find.text('Save 1 Change'));
      await t.pumpAndSettle();
      expect(sent, [
        {'enrollment_id': 102, 'schedule_id': 31, 'updated_at': 'u102'},
      ]);
    });

    testWidgets('a vehicle takes no more students than its seats', (t) async {
      await open(t);
      for (final id in [102, 103, 104]) {
        await t.tap(find.descendant(of: find.byKey(ValueKey('al-wait-$id')), matching: find.byType(Checkbox)));
      }
      await t.pump();
      // three ticked students onto BUS-07, which has two free seats: refused
      await dragTo(t, find.byKey(const ValueKey('al-wait-102')), find.byKey(const ValueKey('al-trip-31')));
      expect(find.text('BUS-07 has 2 free seats, not 3. Tick fewer students, or use another vehicle.'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      // onto VAN-02 they all fit
      await dragTo(t, find.byKey(const ValueKey('al-wait-102')), find.byKey(const ValueKey('al-trip-32')));
      expect(find.text('3/10'), findsOneWidget);
      expect(find.text('3 of 10 seats · 7 free'), findsOneWidget, reason: 'VAN-02 open on the right');
      expect(find.text('NOT ALLOTTED · 0'), findsOneWidget);
      expect(find.text('All allotted'), findsOneWidget);
    });

    testWidgets('the open vehicle seats its students; Take out puts one back', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('al-trip-31'))); // open BUS-07
      await t.pumpAndSettle();
      expect(find.text('BUS-07'), findsOneWidget, reason: 'the open vehicle, on the right');
      expect(find.text('TN01AB1234'), findsOneWidget, reason: 'its number plate');
      final freeSeats = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('al-free-'));
      expect(find.byKey(const ValueKey('al-seat-101')), findsOneWidget, reason: 'ANU on a seat');
      expect(freeSeats, findsNWidgets(2));
      await t.tap(find.descendant(of: find.byKey(const ValueKey('al-in-101')), matching: find.byTooltip('Take out')));
      await t.pumpAndSettle();
      expect(find.text('NOT ALLOTTED · 4'), findsOneWidget);
      expect(freeSeats, findsNWidgets(3));
      await t.tap(find.text('Save 1 Change'));
      await t.pumpAndSettle();
      expect(sent, [
        {'enrollment_id': 101, 'schedule_id': null, 'updated_at': 'u101'},
      ]);
    });

    testWidgets('a 30-seat bus shows every seat, without scrolling, in a small window', (t) async {
      final bigVan = [
        vehicles[0],
        {...vehicles[1], 'seating_capacity': 30}, // VAN-02, open first (the 7:30 trip)
      ];
      await open(t, size: const Size(1366, 768), vehicleRows: bigVan);
      expect(t.takeException(), isNull);
      expect(find.byType(Scrollable).evaluate().where((e) => e.findAncestorWidgetOfExactType<FittedBox>() != null), isEmpty,
          reason: 'the bus is not in a scroll view');
      final screen = Offset.zero & const Size(1366, 768);
      for (final no in [1, 4, 27, 30]) {
        final seat = t.getRect(find.byKey(ValueKey('al-free-$no')));
        expect(screen.contains(seat.topLeft) && screen.contains(seat.bottomRight), isTrue, reason: 'seat $no on screen');
      }
      expect(t.getRect(find.byKey(const ValueKey('al-free-1'))).left, greaterThan(t.getRect(find.byKey(const ValueKey('al-free-30'))).left),
          reason: 'seat 1 at the front, on the right');
    });

    testWidgets('a student dropped on the open vehicle goes into it', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('al-trip-31'))); // open BUS-07
      await t.pumpAndSettle();
      await dragTo(t, find.byKey(const ValueKey('al-wait-104')), find.byKey(const ValueKey('al-bus')));
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('al-seat-104')), findsOneWidget, reason: 'DEVI on a seat');
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('2 of 3 seats · 1 free'), findsOneWidget);
    });

    // BUS-07 with 1 additional (small children): it takes 4, its 3 seats + 1
    testWidgets('a vehicle takes its seats plus its additional capacity', (t) async {
      final withExtra = [
        {...vehicles[0], 'additional_capacity': 1},
        vehicles[1],
      ];
      await open(t, vehicleRows: withExtra);
      expect(find.text('1/4'), findsOneWidget, reason: 'BUS-07 card, with ANU');
      for (final id in [102, 103, 104]) {
        await t.tap(find.descendant(of: find.byKey(ValueKey('al-wait-$id')), matching: find.byType(Checkbox)));
      }
      await t.pump();
      // three ticked students onto BUS-07: they fit only with the additional one
      await dragTo(t, find.byKey(const ValueKey('al-wait-102')), find.byKey(const ValueKey('al-trip-31')));
      expect(t.takeException(), isNull);
      expect(find.text('4/4'), findsOneWidget);
      expect(find.text('NOT ALLOTTED · 0'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('al-trip-31'))); // open BUS-07
      await t.pumpAndSettle();
      expect(find.text('4 of 4 seats · 0 free'), findsOneWidget);
      expect(find.text('3 seats + 1 additional'), findsOneWidget);
    });

    // For Copy from Drop: BUS-07 runs drop trip KLM-D (41), VAN-02 runs
    // KLM-D2 (42). ANU (both ways) is in BUS-07 for the pickup but VAN-02
    // for the drop; BALA (both) has BUS-07 for the drop only; CHITRA travels
    // the pickup only; DEVI (both) has no drop vehicle yet.
    final dropTrips = [
      {'schedule_id': 41, 'schedule_code': 'KLM-D', 'route_id': 1, 'direction': 'DROP', 'vehicle_id': 7, 'is_active': true},
      {'schedule_id': 42, 'schedule_code': 'KLM-D2', 'route_id': 1, 'direction': 'DROP', 'vehicle_id': 8, 'is_active': true},
    ];
    final withDrop = [
      enr(101, 'ANU', 'BOTH', stop: 11, trip: 31, drop: 42),
      enr(102, 'BALA', 'BOTH', stop: 13, drop: 41),
      enr(103, 'CHITRA', 'PICKUP', stop: 11),
      enr(104, 'DEVI', 'BOTH', stop: 11),
      enr(105, 'EZHIL', 'DROP', stop: 13, drop: 41),
    ];

    testWidgets('Copy from Drop puts students who travel both ways in their drop vehicle', (t) async {
      await open(t, rows: withDrop, otherTrips: dropTrips);
      await t.tap(find.byKey(const ValueKey('al-copy')));
      await t.pumpAndSettle();
      expect(find.text('Copy from Drop'), findsNWidgets(2), reason: 'the button and the dialog title');
      expect(find.text('Also move the 1 already in a different pickup vehicle'), findsOneWidget, reason: 'ANU');
      expect(find.text('Copy 1'), findsOneWidget, reason: 'BALA only: ANU stays unless asked');
      await t.tap(find.byKey(const ValueKey('al-copy-go')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('2/3'), findsOneWidget, reason: 'BUS-07: ANU and BALA');
      expect(find.text('NOT ALLOTTED · 2'), findsOneWidget, reason: 'CHITRA (pickup only) and DEVI (no drop vehicle)');
      await t.tap(find.text('Save 1 Change'));
      await t.pumpAndSettle();
      expect(sent, [
        {'enrollment_id': 102, 'schedule_id': 31, 'updated_at': 'u102'},
      ]);
    });

    testWidgets('Copy from Drop can also move students already in another vehicle', (t) async {
      await open(t, rows: withDrop, otherTrips: dropTrips);
      await t.tap(find.byKey(const ValueKey('al-copy')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('al-copy-replace')));
      await t.pumpAndSettle();
      expect(find.text('Copy 2'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('al-copy-go')));
      await t.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget, reason: 'BUS-07: BALA');
      expect(find.text('1/10'), findsOneWidget, reason: 'VAN-02: ANU');
      await t.tap(find.text('Save 2 Changes'));
      await t.pumpAndSettle();
      expect(sent, [
        {'enrollment_id': 101, 'schedule_id': 32, 'updated_at': 'u101'},
        {'enrollment_id': 102, 'schedule_id': 31, 'updated_at': 'u102'},
      ]);
    });
  });

  // GPS Mapping: BUS-07 has IMEI-1 since 01-11-2026 (IMEI-2 before that),
  // BUS-08 has none, sold BUS-10 still has IMEI-3, sold BUS-09 has none.
  // IMEI-4 is switched off. Today is 12-11-2026.
  group('gps mapping grid', () {
    final vehicles = [
      {'vehicle_id': 7, 'vehicle_code': 'BUS-07', 'registration_no': 'TN01AB1234', 'vehicle_type': 'BUS', 'status': 'ACTIVE'},
      {'vehicle_id': 8, 'vehicle_code': 'BUS-08', 'registration_no': 'TN01AB5678', 'vehicle_type': 'MINI_BUS', 'status': 'ACTIVE'},
      {'vehicle_id': 9, 'vehicle_code': 'BUS-09', 'registration_no': 'TN01AB0009', 'vehicle_type': 'VAN', 'status': 'SOLD'},
      {'vehicle_id': 10, 'vehicle_code': 'BUS-10', 'registration_no': 'TN01AB0010', 'vehicle_type': 'VAN', 'status': 'SOLD'},
    ];
    final devices = [
      {'device_id': 1, 'device_type': 'HARDWARE', 'imei': 'IMEI-1', 'is_active': true},
      {'device_id': 2, 'device_type': 'HARDWARE', 'imei': 'IMEI-2', 'is_active': true},
      {'device_id': 3, 'device_type': 'HARDWARE', 'imei': 'IMEI-3', 'is_active': true},
      {'device_id': 4, 'device_type': 'MOBILE_APP', 'imei': 'IMEI-4', 'is_active': false},
    ];
    final links = [
      {'vgd_id': 1, 'vehicle_id': 7, 'device_id': 1, 'installed_on': '2026-11-01', 'removed_on': null},
      {'vgd_id': 3, 'vehicle_id': 7, 'device_id': 2, 'installed_on': '2026-09-01', 'removed_on': '2026-11-01'},
      {'vgd_id': 2, 'vehicle_id': 10, 'device_id': 3, 'installed_on': '2026-10-01', 'removed_on': null},
    ];
    var sent = <Map<String, dynamic>>[];

    Future<void> open(WidgetTester t, {Size size = const Size(1366, 768)}) async {
      sent = [];
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: size.width - 240,
              height: size.height - 130,
              child: GpsMappingGrid(
                vehicles: vehicles,
                devices: devices,
                links: links,
                today: DateTime(2026, 11, 12),
                onSave: (changes) async => sent = changes,
              ),
            ),
          ),
        ),
      ));
      await t.pump();
    }

    /// Opens the device list of a vehicle's row (showing [current]) and picks [item].
    Future<void> pick(WidgetTester t, int vehicleId, int? current, String item) async {
      await t.tap(find.byKey(ValueKey('gps-device-$vehicleId-$current')));
      await t.pumpAndSettle();
      await t.tap(find.text(item).last);
      await t.pumpAndSettle();
    }

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets('lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
        await open(t, size: size);
        expect(t.takeException(), isNull);
        expect(find.text('BUS-07'), findsOneWidget);
        expect(find.text('BUS-08'), findsOneWidget);
        expect(find.text('BUS-10'), findsOneWidget, reason: 'sold, but a device is still on it');
        expect(find.text('BUS-09'), findsNothing, reason: 'sold, with no device');
        expect(find.text('IMEI-1 · Hardware'), findsOneWidget);
        expect(find.text('01-11-2026'), findsOneWidget);
      });
    }

    testWidgets('a device on another vehicle says where and cannot be picked', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('gps-device-8-null')));
      await t.pumpAndSettle();
      expect(find.text('IMEI-3 · Hardware · on BUS-10'), findsOneWidget);
      expect(find.textContaining('IMEI-4'), findsNothing, reason: 'switched off, and on no vehicle');
      final held = find.ancestor(of: find.text('IMEI-1 · Hardware · on BUS-07'), matching: find.byType(DropdownMenuItem<int?>));
      expect(t.widget<DropdownMenuItem<int?>>(held).enabled, isFalse);
      final free = find.ancestor(of: find.text('IMEI-2 · Hardware').last, matching: find.byType(DropdownMenuItem<int?>));
      expect(t.widget<DropdownMenuItem<int?>>(free).enabled, isTrue);
    });

    testWidgets('a free device put on a vehicle is saved from today', (t) async {
      await open(t);
      await pick(t, 8, null, 'IMEI-2 · Hardware');
      expect(find.text('PUT ON'), findsOneWidget);
      expect(find.text('12-11-2026'), findsOneWidget);
      expect(find.textContaining('1 change not saved'), findsOneWidget);
      await t.tap(find.text('Save 1 Change'));
      await t.pumpAndSettle();
      expect(sent, [
        {'vehicle_id': 8, 'device_id': 2, 'was_device_id': null, 'date': '2026-11-12'},
      ]);
      expect(find.text('PUT ON'), findsNothing, reason: 'saved, so nothing is waiting');
    });

    testWidgets('a device moves to another vehicle in one save', (t) async {
      await open(t);
      await pick(t, 10, 3, 'No device');
      expect(find.text('TAKE OFF'), findsOneWidget);
      await pick(t, 8, null, 'IMEI-3 · Hardware'); // free now that BUS-10 lets it go
      expect(find.text('PUT ON'), findsOneWidget);
      await t.tap(find.text('Save 2 Changes'));
      await t.pumpAndSettle();
      expect(sent, [
        {'vehicle_id': 10, 'device_id': null, 'was_device_id': 3, 'date': '2026-11-12'},
        {'vehicle_id': 8, 'device_id': 3, 'was_device_id': null, 'date': '2026-11-12'},
      ]);
    });

    testWidgets('Undo All puts the rows back as saved', (t) async {
      await open(t);
      await pick(t, 7, 1, 'IMEI-2 · Hardware');
      expect(find.text('REPLACE'), findsOneWidget);
      await t.tap(find.text('Undo All'));
      await t.pumpAndSettle();
      expect(find.text('REPLACE'), findsNothing);
      expect(find.text('IMEI-1 · Hardware'), findsOneWidget);
    });

    testWidgets("the clock shows a vehicle's GPS history", (t) async {
      await open(t);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('gps-row-7')), matching: find.byTooltip('GPS history')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('GPS history: BUS-07'), findsOneWidget);
      expect(find.text('ON NOW'), findsOneWidget);
      expect(find.text('01-09-2026'), findsOneWidget);
      expect(find.text('11'), findsOneWidget, reason: 'IMEI-1: 01-11-2026 to today');
      expect(find.text('61'), findsOneWidget, reason: 'IMEI-2: 01-09-2026 to 01-11-2026');
    });
  });

  group('stage fee board', () {
    final route = {'route_id': 1, 'route_code': 'A1', 'route_name': 'Kolumam', 'is_active': true};
    final term = {'sem_id': 1, 'semname': 'TERM 1', 'semstart': '2026-06-01', 'semend': '2026-11-30'};
    final stages = [
      {'stage_id': 22, 'route_id': 1, 'stage_no': 2, 'stage_name': 'Far', 'from_km': 5, 'to_km': 10, 'is_active': true},
      {'stage_id': 21, 'route_id': 1, 'stage_no': 1, 'stage_name': 'Near', 'from_km': 0, 'to_km': 5, 'is_active': true},
      {'stage_id': 23, 'route_id': 1, 'stage_no': 3, 'stage_name': 'Closed', 'is_active': false},
    ];
    final busFee = [
      {'fee_id': 2, 'feedesc': 'BUS FEE'},
    ];
    final fees = [
      {
        'stage_fee_id': 7, 'route_id': 1, 'stage_id': 21, 'service_type': 'BOTH', 'fee_id': 2, 'sem_id': 1, 'amount': 5000.00,
        'effective_from': '2026-06-01', 'effective_to': '2026-11-30', 'activestatus': 1,
      },
    ];
    Map<String, dynamic>? sent;
    final term2 = {'sem_id': 2, 'semname': 'TERM II', 'semstart': '2026-12-01', 'semend': '2027-02-28'};
    // TERM II already has a fee for Near (stage 21), none for Far
    final term2Fees = [
      {'stage_fee_id': 31, 'stage_id': 21, 'service_type': 'BOTH', 'fee_id': 2, 'sem_id': 2, 'amount': 5200, 'effective_from': '2026-12-01'},
    ];
    Map<String, dynamic>? copied;

    Future<void> open(WidgetTester t, {Size size = const Size(1920, 1080), List<Map<String, dynamic>>? rows, List<Map<String, dynamic>>? feeTypes}) async {
      sent = null;
      copied = null;
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: size.width - 240,
              height: size.height - 130,
              child: StageFeeBoard(
                route: route,
                term: term,
                service: 'BOTH',
                stages: stages,
                fees: rows ?? fees,
                feeTypes: feeTypes ?? busFee,
                onSave: (p) async => sent = p,
                otherTerms: [term2],
                loadTerm: (sem) async => sem == 2 ? term2Fees : const [],
                onCopy: (p) async => copied = p,
              ),
            ),
          ),
        ),
      ));
      await t.pump();
    }

    Finder amount(int stage) => find.byKey(ValueKey('sf-amount-$stage'));
    String text(WidgetTester t, int stage) => t.widget<TextField>(amount(stage)).controller!.text;

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets('lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
        await open(t, size: size);
        expect(t.takeException(), isNull);
        expect(find.text('Near'), findsOneWidget);
        expect(find.text('Far'), findsOneWidget);
        expect(find.text('Closed'), findsNothing, reason: 'a switched-off stage with no fee is not shown');
        expect(text(t, 21), '5000');
        expect(text(t, 22), '');
        expect(find.text('BUS FEE'), findsOneWidget);
        expect(find.text('01-06-2026'), findsOneWidget);
        expect(find.text('30-11-2026'), findsOneWidget);
        expect(t.getTopLeft(find.text('Near')).dy, lessThan(t.getTopLeft(find.text('Far')).dy), reason: 'in stage order');
      });
    }

    testWidgets('a new amount and a cleared one are saved together, with the fee type and dates', (t) async {
      await open(t);
      await t.enterText(amount(22), '4500');
      await t.enterText(amount(21), '');
      await t.pump();
      expect(find.text('NEW'), findsOneWidget);
      expect(find.text('REMOVE'), findsOneWidget);
      await t.tap(find.text('Save 2 Changes'));
      await t.pumpAndSettle();
      expect(sent, {
        'route_id': 1,
        'sem_id': 1,
        'service_type': 'BOTH',
        'fee_id': 2,
        'effective_from': '2026-06-01',
        'effective_to': '2026-11-30',
        'fees': [
          {'stage_id': 21, 'stage_fee_id': 7, 'amount': ''},
          {'stage_id': 22, 'amount': '4500'},
        ],
      });
    });

    testWidgets('a new date goes to every saved fee; an unchanged amount is not a change', (t) async {
      await open(t);
      await t.enterText(amount(21), '5000.00');
      await t.pump();
      expect(find.text(AppText.save), findsOneWidget, reason: '5000.00 is the saved 5000');
      await t.tap(find.byKey(const ValueKey('sf-to-clear')));
      await t.pump();
      expect(find.text('CHANGED'), findsOneWidget);
      await t.tap(find.text('Save 1 Change'));
      await t.pumpAndSettle();
      expect(sent?['effective_to'], isNull);
      expect(sent?['fees'], [
        {'stage_id': 21, 'stage_fee_id': 7, 'amount': '5000.00'},
      ]);
    });

    testWidgets('the fee type must be chosen when there are several', (t) async {
      await open(t, rows: const [], feeTypes: [...busFee, {'fee_id': 4, 'feedesc': 'VAN FEE'}]);
      await t.enterText(amount(21), '3000');
      await t.pump();
      await t.tap(find.text('Save 1 Change'));
      await t.pump();
      expect(find.text('Choose the fee type.'), findsOneWidget);
      expect(sent, isNull);
    });

    testWidgets('only an amount can be typed, up to 2 decimals', (t) async {
      await open(t);
      await t.enterText(amount(22), '12a');
      expect(text(t, 22), '');
      await t.enterText(amount(22), '99.999');
      expect(text(t, 22), '');
      await t.enterText(amount(22), '99.75');
      expect(text(t, 22), '99.75');
    });

    testWidgets('Down and Enter go to the next stage, Up to the one before', (t) async {
      await open(t);
      bool focused(int stage) => t.widget<EditableText>(find.descendant(of: amount(stage), matching: find.byType(EditableText))).focusNode.hasFocus;
      await t.tap(amount(21));
      await t.pump();
      expect(focused(21), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(focused(22), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      expect(focused(21), isTrue);
      await t.testTextInput.receiveAction(TextInputAction.next);
      await t.pump();
      expect(focused(22), isTrue);
    });

    testWidgets('Undo All puts the saved fees back', (t) async {
      await open(t);
      await t.enterText(amount(21), '7000');
      await t.enterText(amount(22), '100');
      await t.pump();
      await t.tap(find.text('Undo All'));
      await t.pump();
      expect(text(t, 21), '5000');
      expect(text(t, 22), '');
      expect(find.text(AppText.save), findsOneWidget);
    });

    testWidgets('Copy to Term copies the route\'s saved fees to the same route and fee type of the picked term', (t) async {
      await open(t, rows: [
        ...fees,
        {
          'stage_fee_id': 9, 'route_id': 1, 'stage_id': 22, 'service_type': 'BOTH', 'fee_id': 2, 'sem_id': 1, 'amount': '6500.50',
          'effective_from': '2026-06-01', 'effective_to': '2026-11-30',
        },
      ]);
      await t.tap(find.byKey(const ValueKey('sf-copy')));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing, reason: 'no window: just the list of the other terms');
      await t.tap(find.byKey(const ValueKey('sf-copy-to-2')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(copied, {
        'route_id': 1,
        'sem_id': 2,
        'service_type': 'BOTH',
        'fee_id': 2,
        'effective_from': '2026-12-01',
        'effective_to': '2027-02-28',
        'fees': [
          {'stage_id': 21, 'stage_fee_id': 31, 'amount': '5000'}, // TERM II's own fee for Near takes the amount
          {'stage_id': 22, 'amount': '6500.5'},
        ],
      });
      expect(find.text('Copied 2 stage fees of route A1 (BUS FEE, both ways) to TERM II.'), findsOneWidget);
      expect(text(t, 21), '5000', reason: 'this term stays as it is');
      expect(sent, isNull);
    });

    testWidgets('Copy to Term copies only saved fees: not while changes are unsaved', (t) async {
      await open(t);
      await t.enterText(amount(22), '1');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('sf-copy')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sf-copy-to-2')), findsNothing);
      await t.tap(find.text('Undo All'));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('sf-copy')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sf-copy-to-2')), findsOneWidget);
    });

    testWidgets('a switched-off stage keeps its saved fee, but takes no new one', (t) async {
      await open(t, rows: [
        ...fees,
        {
          'stage_fee_id': 8, 'route_id': 1, 'stage_id': 23, 'service_type': 'BOTH', 'fee_id': 2, 'sem_id': 1, 'amount': '9000',
          'effective_from': '2026-06-01', 'effective_to': '2026-11-30',
        },
      ]);
      expect(find.text('Closed'), findsOneWidget);
      expect(find.text('OFF'), findsOneWidget);
      expect(t.widget<TextField>(amount(23)).enabled, isTrue);
      await open(t);
      expect(find.text('Closed'), findsNothing);
    });
  });

  group('stage fee process dialog', () {
    final terms = [
      {'sem_id': 1, 'semname': 'TERM 1', 'semstart': '2026-06-01', 'semend': '2026-11-30'},
      {'sem_id': 2, 'semname': 'TERM II', 'semstart': '2026-12-01', 'semend': '2027-02-28'},
    ];
    final busFee = [
      {'fee_id': 2, 'feedesc': 'BUS FEE'},
    ];
    // A1 not processed; A2 processed (it can be run again); A3 has nobody;
    // A4 has no stage fee for the term
    List<Map<String, dynamic>> routes() => [
          {'route_id': 20, 'route_code': 'A1', 'route_name': 'Kolumam', 'is_active': true, 'students': 21, 'stages': 8, 'processed': 0},
          {
            'route_id': 21, 'route_code': 'A2', 'route_name': 'Amaravathi', 'is_active': true, 'students': 4, 'stages': 3, 'processed': 4,
            'processed_at': '2026-11-16T05:30:00+00:00',
          },
          {'route_id': 22, 'route_code': 'A3', 'route_name': 'Empty Line', 'is_active': true, 'students': 0, 'stages': 2, 'processed': 0},
          {'route_id': 23, 'route_code': 'A4', 'route_name': 'No Fee Line', 'is_active': true, 'students': 5, 'stages': 0, 'processed': 0},
        ];
    late List<String> loads;
    Map<String, dynamic>? sent;
    late Set<int> done;

    Future<void> open(WidgetTester t, {Size size = const Size(1920, 1080), List<Map<String, dynamic>>? feeTypes}) async {
      loads = [];
      sent = null;
      done = {};
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: StageFeeProcessDialog(
              terms: terms,
              feeTypes: feeTypes ?? busFee,
              semId: 1,
              loadRoutes: (sem, fee) async {
                loads.add('$sem:$fee');
                return [
                  for (final r in routes()) {...r, if (done.contains(r['route_id'])) 'processed': r['students']},
                ];
              },
              onProcess: (p) async {
                sent = p;
                done.addAll((p['route_ids'] as List).cast<int>());
                return {
                  'students': 25, 'added': 20, 'updated': 2, 'unchanged': 2, 'skipped': 1,
                  'problems': [
                    {
                      'route_code': 'A1', 'stage': 'Stage 3', 'stuadmno': 'ADM00085', 'stuname': 'ANUSHKA R', 'stuclass': 'PKG A',
                      'reason': 'The new fee 1,000.00 is below the 1,500.00 already paid, so the fee demand was left at 1,500.00.',
                    },
                  ],
                };
              },
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
    }

    Checkbox pick(WidgetTester t, int route) => t.widget<Checkbox>(find.byKey(ValueKey('sfp-pick-$route')));

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets('lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
        await open(t, size: size);
        expect(t.takeException(), isNull);
        expect(loads, ['1:2'], reason: 'the open term, and the only transport fee type');
        for (final name in ['Kolumam', 'Amaravathi', 'Empty Line', 'No Fee Line']) {
          expect(find.text(name), findsOneWidget);
        }
        expect(find.byKey(const ValueKey('sfp-done-21-true')), findsOneWidget, reason: 'A2 is processed');
        expect(find.byKey(const ValueKey('sfp-done-20-false')), findsOneWidget, reason: 'A1 is not');
        expect(find.text('4 students · 16-11-2026'), findsOneWidget);
      });
    }

    testWidgets('a route with no students or no stage fee cannot be ticked; a processed one can', (t) async {
      await open(t);
      expect(pick(t, 20).onChanged, isNotNull);
      expect(pick(t, 21).onChanged, isNotNull, reason: 'a processed route can be run again');
      expect(pick(t, 22).onChanged, isNull);
      expect(pick(t, 23).onChanged, isNull);
      await t.tap(find.byKey(const ValueKey('sfp-all')));
      await t.pump();
      expect(find.text('Process 2 Routes'), findsOneWidget);
      expect(pick(t, 22).value, isFalse);
    });

    testWidgets('the ticked routes are processed for the term and fee type; then they show the tick', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('sfp-pick-20')));
      await t.pump();
      await t.tap(find.text('Process 1 Route'));
      await t.pumpAndSettle();
      expect(find.text('Process 1 route?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sfp-confirm')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(sent, {
        'sem_id': 1,
        'fee_id': 2,
        'route_ids': [20],
      });
      expect(find.byKey(const ValueKey('sfp-result')), findsOneWidget);
      expect(find.text('TERM 1 BUS FEE: 25 students processed. 20 added, 2 updated, 2 already right, 1 not processed.'), findsOneWidget);
      expect(find.textContaining('below the 1,500.00 already paid'), findsOneWidget);
      expect(loads, ['1:2', '1:2'], reason: 'the routes are listed again');
      expect(find.byKey(const ValueKey('sfp-done-20-true')), findsOneWidget);
      expect(pick(t, 20).value, isFalse, reason: 'nothing stays ticked');
    });

    testWidgets('Cancel in the question processes nothing', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('sfp-pick-21')));
      await t.pump();
      await t.tap(find.text('Process 1 Route'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(sent, isNull);
      expect(pick(t, 21).value, isTrue);
    });

    testWidgets('with several fee types, the routes wait for the fee type; another term lists its own', (t) async {
      await open(t, feeTypes: [...busFee, {'fee_id': 4, 'feedesc': 'VAN FEE'}]);
      expect(loads, isEmpty);
      expect(find.text('Choose the term and fee type'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sfp-fee-null')));
      await t.pumpAndSettle();
      await t.tap(find.text('VAN FEE').last);
      await t.pumpAndSettle();
      expect(loads, ['1:4']);
      await t.tap(find.byKey(const ValueKey('sfp-term-1')));
      await t.pumpAndSettle();
      await t.tap(find.text('TERM II').last);
      await t.pumpAndSettle();
      expect(loads, ['1:4', '2:4']);
      expect(find.text('Kolumam'), findsOneWidget);
    });
  });

  for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
    for (final e in screens.entries) {
      testWidgets('${e.key} lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
        await t.binding.setSurfaceSize(size);
        addTearDown(() => t.binding.setSurfaceSize(null));
        await t.pumpWidget(ScreenUtilInit(
          designSize: const Size(1750, 984),
          builder: (_, __) => MaterialApp(
            home: Scaffold(body: SizedBox(width: size.width - 240, height: size.height - 130, child: e.value())),
          ),
        ));
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
        expect(t.takeException(), isNull);
      });
    }

    // the Vehicles screen's Service tab, with the five tabs in one row
    testWidgets('Vehicles: Service tab lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(body: SizedBox(width: size.width - 240, height: size.height - 130, child: const VehiclesScreen())),
        ),
      ));
      await t.pump();
      await t.tap(find.text('Service'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);
      expect(find.text('Vehicle Service'), findsOneWidget);
      expect(find.text('Add service record'), findsOneWidget);
    });

    // the Fuel tab, after Service, with the six tabs in one row
    testWidgets('Vehicles: Fuel tab lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      await t.binding.setSurfaceSize(size);
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(body: SizedBox(width: size.width - 240, height: size.height - 130, child: const VehiclesScreen())),
        ),
      ));
      await t.pump();
      final service = t.getTopLeft(find.text('Service')).dx;
      final fuel = t.getTopLeft(find.text('Fuel')).dx;
      final devices = t.getTopLeft(find.text('GPS Devices')).dx;
      expect(service < fuel && fuel < devices, isTrue, reason: 'Fuel comes after Service and before GPS Devices');
      await t.tap(find.text('Fuel'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);
      expect(find.text('Fuel Log'), findsOneWidget);
      expect(find.text('Add fuel entry'), findsOneWidget);
    });
  }
}
