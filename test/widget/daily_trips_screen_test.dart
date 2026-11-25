import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/transport/daily_trips_screen.dart';

// Two pickup trips on 25-11-2026: KLM-A on VAN-02 (2 seats) driven by RAVI
// with KANNAN attending, 1 student and 1 staff expected; KLM-B on BUS-40,
// already completed.
void main() {
  final vehicles = [
    {'vehicle_id': 7, 'vehicle_code': 'VAN-02', 'seating_capacity': 2, 'additional_capacity': 0, 'status': 'ACTIVE'},
    {'vehicle_id': 8, 'vehicle_code': 'BUS-40', 'seating_capacity': 40, 'additional_capacity': 0, 'status': 'ACTIVE'},
    {'vehicle_id': 9, 'vehicle_code': 'CAR-01', 'seating_capacity': 1, 'additional_capacity': 0, 'status': 'ACTIVE'},
    {'vehicle_id': 10, 'vehicle_code': 'OLD-BUS', 'seating_capacity': 30, 'additional_capacity': 0, 'status': 'INACTIVE'},
  ];
  final staff = [
    {'staff_id': 1, 'staff_code': 'D1', 'full_name': 'RAVI', 'staff_type': 'DRIVER', 'status': 'ACTIVE'},
    {'staff_id': 2, 'staff_code': 'D2', 'full_name': 'MANI', 'staff_type': 'DRIVER', 'status': 'ACTIVE'},
    {'staff_id': 3, 'staff_code': 'A1', 'full_name': 'KANNAN', 'staff_type': 'ATTENDER', 'status': 'ACTIVE'},
  ];
  Map<String, dynamic> trip(int id, String code, int vehicle, String vehicleCode, int capacity, String status, List<Map<String, dynamic>> crew) => {
        'trip_id': id, 'trip_date': '2026-11-25', 'direction': 'PICKUP', 'status': status,
        'planned_start_at': '2026-11-25T01:30:00+00:00', 'planned_end_at': '2026-11-25T02:00:00+00:00', 'updated_at': 'u$id',
        'schedule_code': code, 'schedule_name': 'Morning', 'route_code': 'A1', 'route_name': 'Kolumam',
        'vehicle_id': vehicle, 'vehicle_code': vehicleCode, 'capacity': capacity, 'crew': crew,
        'students': 1, 'staff': 1, 'editable': status == 'SCHEDULED',
      };
  final day = {
    'trip_date': '2026-11-25',
    'trips': [
      trip(31, 'KLM-A', 7, 'VAN-02', 2, 'SCHEDULED', [
        {'staff_id': 1, 'full_name': 'RAVI', 'staff_code': 'D1', 'duty_role': 'DRIVER', 'is_substitute': false},
        {'staff_id': 3, 'full_name': 'KANNAN', 'staff_code': 'A1', 'duty_role': 'ATTENDER', 'is_substitute': false},
      ]),
      trip(32, 'KLM-B', 8, 'BUS-40', 40, 'COMPLETED', [
        {'staff_id': 2, 'full_name': 'MANI', 'staff_code': 'D2', 'duty_role': 'DRIVER', 'is_substitute': true},
      ]),
    ],
  };

  late List<Map<String, dynamic>> sent;
  late List<String> made;
  late List<Object> boarded;
  late List<Object> replaced;
  String? replaceRefused;
  var canMark = true;
  final riders = {
    'students': [
      {'enrollment_id': 9, 'stuadmno': 'ADM1', 'stuname': 'ANU', 'stuclass': 'LKG A', 'stop_name': 'Mill Gate', 'status': 'EXPECTED'},
      {'enrollment_id': 10, 'stuadmno': 'ADM2', 'stuname': 'BALA', 'stuclass': 'LKG A', 'stop_name': 'Mill Gate', 'status': 'ABSENT'},
    ],
    'staff': [
      {'enrollment_id': 4, 'emp_code': 'EMP002', 'stafname': 'SENTHIL', 'designation': 'Teacher', 'stop_name': 'Lake View', 'status': 'EXPECTED'},
    ],
  };
  // more students on the trip, for one test
  var moreStudents = <Map<String, dynamic>>[];
  // the route's riders on its other trips (Add Student): CHITRA on KLM-B not
  // marked yet, DEEPA already present there, ELAN in no vehicle
  final options = {
    'students': [
      {'enrollment_id': 21, 'stuadmno': 'ADM21', 'stuname': 'CHITRA', 'stuclass': 'UKG B', 'stop_name': 'Lake View',
       'on_trip_id': 32, 'on_trip_code': 'KLM-B', 'on_vehicle_code': 'BUS-40', 'on_trip_status': 'SCHEDULED', 'on_status': 'EXPECTED', 'present': false},
      {'enrollment_id': 22, 'stuadmno': 'ADM22', 'stuname': 'DEEPA', 'stuclass': 'UKG B', 'stop_name': 'Lake View',
       'on_trip_id': 32, 'on_trip_code': 'KLM-B', 'on_vehicle_code': 'BUS-40', 'on_trip_status': 'SCHEDULED', 'on_status': 'BOARDED', 'present': true},
      {'enrollment_id': 23, 'stuadmno': 'ADM23', 'stuname': 'ELAN', 'stuclass': 'LKG A', 'stop_name': 'Mill Gate', 'present': false},
    ],
    'staff': <Map<String, dynamic>>[],
  };

  Future<void> open(WidgetTester t, {Map<String, dynamic>? data}) async {
    sent = [];
    made = [];
    boarded = [];
    replaced = [];
    await t.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1680,
            height: 950,
            child: DailyTripsScreen(
              today: DateTime(2026, 11, 24),
              loadDay: (_) async => data ?? day,
              loadVehicles: () async => vehicles,
              loadStaff: () async => staff,
              makeTrips: (d) async {
                made.add(d);
                return 2;
              },
              saveTrips: (_, rows) async => sent = rows,
              loadRiders: (_, __) async => {
                'can_mark': canMark,
                'students': [...riders['students']!, ...moreStudents],
                'staff': riders['staff'],
              },
              loadRiderOptions: (_, __) async => options,
              saveBoarding: (date, trip, students, staff) async => boarded = [date, trip, students, staff],
              replaceTrip: (date, row) async {
                // as the server's RAISE comes back (P0001: said as written)
                if (replaceRefused != null) throw Exception('PostgrestException(message: $replaceRefused, code: P0001, details: null)');
                replaced = [date, row];
              },
            ),
          ),
        ),
      ),
    ));
    await t.pump();
    await t.pump();
  }

  Future<void> choose(WidgetTester t, String keyPrefix, String item) async {
    await t.tap(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith(keyPrefix)));
    await t.pumpAndSettle();
    await t.tap(find.text(item).last);
    await t.pumpAndSettle();
  }

  testWidgets('lists the day\'s trips; a completed one cannot change', (t) async {
    await open(t);
    expect(t.takeException(), isNull);
    expect(find.text('KLM-A'), findsOneWidget);
    expect(find.text('KLM-B'), findsOneWidget);
    expect(find.text('1 + 1 / 2'), findsOneWidget, reason: 'KLM-A: 1 student and 1 staff, 2 seats');
    expect(find.text('BUS-40'), findsOneWidget, reason: 'KLM-B is completed: its vehicle is shown, not picked');
    expect(find.byWidgetPredicate((w) => w.key == const ValueKey('dt-status-32-COMPLETED')), findsOneWidget,
        reason: 'completed today: it can be set back to Scheduled');
    expect(find.byWidgetPredicate((w) => w.key == const ValueKey('dt-veh-32-8')), findsNothing);
  });

  testWidgets('a trip is completed on its day, not before', (t) async {
    await open(t);
    await choose(t, 'dt-status-31-', 'Completed');
    await t.tap(find.text('Save 1 Change'));
    await t.pumpAndSettle();
    expect(sent, [
      {'trip_id': 31, 'updated_at': 'u31', 'status': 'COMPLETED'},
    ]);

    // tomorrow's trip: cancelled, but not completed yet
    await open(t, data: {'trip_date': '2026-11-25', 'trips': [trip(31, 'KLM-A', 7, 'VAN-02', 2, 'SCHEDULED', const [])]});
    await t.tap(find.byKey(const ValueKey('dt-day-Tomorrow')));
    await t.pumpAndSettle();
    await t.tap(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('dt-status-31-')));
    await t.pumpAndSettle();
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Completed'), findsNothing);
  });

  testWidgets('a new vehicle and driver are saved, only what changed', (t) async {
    await open(t);
    await choose(t, 'dt-veh-31-', 'BUS-40 · 40 seats');
    await choose(t, 'dt-drv-31-', 'MANI (D2)');
    expect(find.text('Save 1 Change'), findsOneWidget);
    expect(find.text('OLD-BUS · 30 seats'), findsNothing, reason: 'a vehicle out of service is not offered');
    await t.tap(find.text('Save 1 Change'));
    await t.pumpAndSettle();
    expect(sent, [
      {'trip_id': 31, 'updated_at': 'u31', 'vehicle_id': 8, 'driver_id': 2},
    ]);
  });

  testWidgets('the attender can be taken off; a vehicle too small is refused before saving', (t) async {
    await open(t);
    await choose(t, 'dt-att-31-', 'None');
    await choose(t, 'dt-veh-31-', 'CAR-01 · 1 seats');
    await t.tap(find.text('Save 1 Change'));
    await t.pump();
    expect(find.textContaining('expects 2 riders'), findsOneWidget);
    expect(sent, isEmpty);
    // back to the van: only the attender goes
    await choose(t, 'dt-veh-31-', 'VAN-02 · 2 seats');
    await t.tap(find.text('Save 1 Change'));
    await t.pumpAndSettle();
    expect(sent, [
      {'trip_id': 31, 'updated_at': 'u31', 'attender_id': null},
    ]);
  });

  testWidgets('a trip is cancelled with its reason; without one it stays', (t) async {
    await open(t);
    await choose(t, 'dt-status-31-', 'Cancelled');
    expect(find.text('Cancel trip KLM-A?'), findsOneWidget);
    await t.tap(find.text('Keep the Trip'));
    await t.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget, reason: 'nothing changed');

    await choose(t, 'dt-status-31-', 'Cancelled');
    await t.enterText(find.byKey(const ValueKey('dt-reason')), 'Bus breakdown');
    await t.pump();
    await t.tap(find.text('Cancel Trip'));
    await t.pumpAndSettle();
    expect(find.text('Bus breakdown'), findsOneWidget, reason: 'the reason under the status');
    await t.tap(find.text('Save 1 Change'));
    await t.pumpAndSettle();
    expect(sent, [
      {'trip_id': 31, 'updated_at': 'u31', 'status': 'CANCELLED', 'cancel_reason': 'Bus breakdown'},
    ]);
  });

  testWidgets('a cancelled trip of today or later can be restored', (t) async {
    final cancelled = {
      ...trip(33, 'KLM-C', 7, 'VAN-02', 2, 'CANCELLED', const []),
      'cancel_reason': 'Holiday',
    };
    await open(t, data: {'trip_date': '2026-11-25', 'trips': [cancelled]});
    expect(find.text('Holiday'), findsOneWidget);
    await choose(t, 'dt-status-33-', 'Scheduled');
    await t.tap(find.text('Save 1 Change'));
    await t.pumpAndSettle();
    expect(sent, [
      {'trip_id': 33, 'updated_at': 'u33', 'status': 'SCHEDULED'},
    ]);
  });

  bool chosen(WidgetTester t, String key) => t.widget<ChoiceChip>(find.byKey(ValueKey(key))).selected;

  testWidgets('Riders: students and staff, marked Present, Absent or Parent pickup', (t) async {
    canMark = true;
    await open(t);
    await t.tap(find.byKey(const ValueKey('dt-riders-31')));
    await t.pumpAndSettle();
    expect(find.textContaining('Present (boarded)'), findsOneWidget, reason: 'a pickup: present is boarded');
    // two tabs: the students open, the staff behind
    expect(find.textContaining('Students · 2'), findsOneWidget);
    expect(find.textContaining('Staff · 1'), findsOneWidget);
    expect(find.text('ANU'), findsOneWidget);
    expect(find.text('SENTHIL'), findsNothing);
    expect(chosen(t, 'dt-board-s10-ABSENT'), isTrue, reason: 'BALA: absence told beforehand');
    expect(find.text('TOLD BEFORE'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('dt-board-s9-PARENT_PICKUP')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('dt-board-s10-PRESENT'))); // BALA came after all
    await t.pump();
    expect(find.text('TOLD BEFORE'), findsNothing);
    await t.tap(find.byKey(const ValueKey('dt-tab-staff')));
    await t.pump();
    expect(find.text('SENTHIL'), findsOneWidget);
    expect(find.text('ANU'), findsNothing);
    expect(find.byKey(const ValueKey('dt-board-f4-PARENT_PICKUP')), findsNothing, reason: 'staff: no parent pickup');
    await t.tap(find.byKey(const ValueKey('dt-rest-present'))); // the open tab only: SENTHIL
    await t.pump();
    expect(find.textContaining('3 of 3 marked'), findsOneWidget);
    await t.tap(find.text('Save 3'));
    await t.pumpAndSettle();
    expect(boarded, [
      '2026-11-24',
      31,
      [
        {'enrollment_id': 9, 'status': 'PARENT_PICKUP'},
        {'enrollment_id': 10, 'status': 'PRESENT'},
      ],
      [
        {'enrollment_id': 4, 'status': 'PRESENT'},
      ],
    ]);
  });

  testWidgets('Riders: Deselect All takes every mark of the open tab off', (t) async {
    canMark = true;
    await open(t);
    await t.tap(find.byKey(const ValueKey('dt-riders-31')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('dt-rest-present'))); // ANU present; BALA stays absent
    await t.pump();
    expect(chosen(t, 'dt-board-s9-PRESENT'), isTrue);
    expect(chosen(t, 'dt-board-s10-ABSENT'), isTrue);
    await t.tap(find.byKey(const ValueKey('dt-deselect-all')));
    await t.pump();
    expect(chosen(t, 'dt-board-s9-PRESENT'), isFalse);
    expect(chosen(t, 'dt-board-s10-ABSENT'), isFalse);
    expect(find.textContaining('0 of 3 marked · 1 not saved'), findsOneWidget, reason: 'only BALA\'s saved absence changes');
    expect(t.widget<OutlinedButton>(find.byKey(const ValueKey('dt-deselect-all'))).onPressed, isNull, reason: 'nothing marked now');
    await t.tap(find.text('Save 1'));
    await t.pumpAndSettle();
    expect(boarded, [
      '2026-11-24',
      31,
      [
        {'enrollment_id': 10, 'status': 'EXPECTED'},
      ],
      <Map<String, dynamic>>[],
    ]);
  });

  testWidgets('Riders: Add Student puts a rider of another vehicle on this trip; one already present cannot be', (t) async {
    canMark = true;
    await open(t);
    await t.tap(find.byKey(const ValueKey('dt-riders-31')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('dt-add-riders')));
    await t.pumpAndSettle();
    expect(find.text('Add Students to Trip KLM-A'), findsOneWidget);
    expect(find.text('On KLM-B · BUS-40 · not marked'), findsOneWidget);
    expect(find.text('Already present on KLM-B · BUS-40'), findsOneWidget);
    expect(find.text('No vehicle allotted'), findsOneWidget);
    expect(t.widget<Checkbox>(find.byKey(const ValueKey('dt-pick-22'))).onChanged, isNull, reason: 'DEEPA is present on KLM-B');
    await t.tap(find.byKey(const ValueKey('dt-pick-21')));
    await t.tap(find.byKey(const ValueKey('dt-pick-23')));
    await t.pump();
    await t.tap(find.text('Add 2'));
    await t.pumpAndSettle();

    // added, Present, not saved yet; one taken off again before saving
    expect(find.text('CHITRA'), findsOneWidget);
    expect(find.text('ADDED'), findsNWidgets(2));
    expect(chosen(t, 'dt-board-s21-PRESENT'), isTrue);
    expect(find.textContaining('Students · 4'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('dt-takeoff-s23')));
    await t.pump();
    expect(find.text('ELAN'), findsNothing);
    expect(find.textContaining('1 not saved'), findsOneWidget);

    // not offered twice
    await t.tap(find.byKey(const ValueKey('dt-add-riders')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('dt-pick-21')), findsNothing);
    await t.tap(find.text('Close').last);
    await t.pumpAndSettle();

    await t.tap(find.text('Save 1'));
    await t.pumpAndSettle();
    expect(boarded, [
      '2026-11-24',
      31,
      [
        {'enrollment_id': 21, 'status': 'PRESENT', 'add': true},
      ],
      <Map<String, dynamic>>[],
    ]);
  });

  testWidgets('Riders: a rider added before can be taken off again', (t) async {
    canMark = true;
    moreStudents = [
      {'enrollment_id': 11, 'stuadmno': 'ADM11', 'stuname': 'GOKUL', 'stuclass': 'LKG B', 'stop_name': 'Mill Gate',
       'status': 'BOARDED', 'mark_method': 'MANUAL', 'is_extra': true},
    ];
    await open(t);
    await t.tap(find.byKey(const ValueKey('dt-riders-31')));
    await t.pumpAndSettle();
    expect(find.text('ADDED'), findsOneWidget);
    expect(find.byKey(const ValueKey('dt-takeoff-s9')), findsNothing, reason: 'the trip\'s own riders stay');
    await t.tap(find.byKey(const ValueKey('dt-takeoff-s11')));
    await t.pump();
    expect(find.text('TAKEN OFF'), findsOneWidget);
    expect(find.textContaining('Students · 2'), findsOneWidget, reason: 'not counted any more');
    await t.tap(find.text('Save 1'));
    await t.pumpAndSettle();
    expect(boarded, [
      '2026-11-24',
      31,
      [
        {'enrollment_id': 11, 'status': 'REMOVE'},
      ],
      <Map<String, dynamic>>[],
    ]);
    moreStudents = [];
  });

  testWidgets('Riders of a drop: Dropped, Not boarded, Parent pickup', (t) async {
    canMark = true;
    final drop = {...trip(34, 'KLM-D', 7, 'VAN-02', 2, 'SCHEDULED', const []), 'direction': 'DROP'};
    await open(t, data: {'trip_date': '2026-11-25', 'trips': [drop]});
    await t.tap(find.byKey(const ValueKey('dt-riders-34')));
    await t.pumpAndSettle();
    expect(find.text('Trip KLM-D · Drop'), findsOneWidget);
    expect(find.textContaining('Dropped (got off at the stop)'), findsOneWidget);
    expect(find.text('DROP-OFF'), findsOneWidget);
    expect(find.text('Present'), findsNothing);
    expect(find.text('Absent'), findsNothing);
    expect(find.text('Not boarded'), findsNWidgets(2));
    await t.tap(find.byKey(const ValueKey('dt-board-s9-PRESENT')));
    await t.pump();
    expect(find.text('Rest Dropped'), findsOneWidget);
    await t.tap(find.text('Save 1'));
    await t.pumpAndSettle();
    expect(boarded, [
      '2026-11-24',
      34,
      [
        {'enrollment_id': 9, 'status': 'PRESENT'}, // the server keeps a drop's as ALIGHTED
      ],
      <Map<String, dynamic>>[],
    ]);
  });

  testWidgets('Riders of a trip that cannot be marked are shown only', (t) async {
    canMark = false;
    await open(t);
    await t.tap(find.byKey(const ValueKey('dt-riders-31')));
    await t.pumpAndSettle();
    expect(find.textContaining('from the trip\'s day on'), findsOneWidget);
    expect(find.byKey(const ValueKey('dt-rest-present')), findsNothing);
    expect(find.byKey(const ValueKey('dt-deselect-all')), findsNothing);
    expect(t.widget<ChoiceChip>(find.byKey(const ValueKey('dt-board-s9-PRESENT'))).onSelected, isNull);
    canMark = true;
  });

  // KLM-C on VAN-02, cancelled for a breakdown, RAVI driving and KANNAN attending
  Map<String, dynamic> broken({Map<String, dynamic> extra = const {}}) => {
        ...trip(33, 'KLM-C', 7, 'VAN-02', 2, 'CANCELLED', [
          {'staff_id': 1, 'full_name': 'RAVI', 'staff_code': 'D1', 'duty_role': 'DRIVER', 'is_substitute': false},
          {'staff_id': 3, 'full_name': 'KANNAN', 'staff_code': 'A1', 'duty_role': 'ATTENDER', 'is_substitute': false},
        ]),
        'cancel_reason': 'Bus breakdown',
        ...extra,
      };

  testWidgets('Replace: another vehicle runs a cancelled trip, its crew kept unless changed', (t) async {
    replaceRefused = null;
    await open(t, data: {'trip_date': '2026-11-25', 'trips': [broken()]});
    await t.tap(find.byKey(const ValueKey('dt-replace-33')));
    await t.pumpAndSettle();
    expect(find.text('Replace Trip KLM-C · Pickup'), findsOneWidget);
    expect(find.textContaining('cancelled: Bus breakdown'), findsOneWidget);
    expect(find.textContaining('its 1 student and 1 staff'), findsOneWidget);
    final go = find.byKey(const ValueKey('dt-rep-go'));
    expect(t.widget<ElevatedButton>(go).onPressed, isNull, reason: 'no vehicle chosen yet');

    // the vehicles: in service, not the broken one
    await t.tap(find.byKey(const ValueKey('dt-rep-vehicle')));
    await t.pumpAndSettle();
    expect(find.text('VAN-02 · 2 seats'), findsNothing);
    expect(find.text('OLD-BUS · 30 seats'), findsNothing);
    await t.tap(find.text('CAR-01 · 1 seats').last);
    await t.pumpAndSettle();
    expect(find.textContaining('the trip expects 2 riders'), findsOneWidget);
    expect(t.widget<ElevatedButton>(go).onPressed, isNull, reason: 'too few seats');

    await choose(t, 'dt-rep-vehicle', 'BUS-40 · 40 seats');
    await choose(t, 'dt-rep-driver', 'MANI (D2)');
    await t.tap(go);
    await t.pumpAndSettle();
    expect(replaced, [
      '2026-11-24',
      {'trip_id': 33, 'updated_at': 'u33', 'vehicle_id': 8, 'driver_id': 2, 'attender_id': 3},
    ]);
    expect(find.text('Trip KLM-C replaced: BUS-40 runs it.'), findsOneWidget);
  });

  testWidgets('Replace: what the server refuses is said in the window', (t) async {
    replaceRefused = 'BUS-40 would run trips KLM-C and KLM-B at the same time.';
    await open(t, data: {'trip_date': '2026-11-25', 'trips': [broken()]});
    await t.tap(find.byKey(const ValueKey('dt-replace-33')));
    await t.pumpAndSettle();
    await choose(t, 'dt-rep-vehicle', 'BUS-40 · 40 seats');
    await t.tap(find.byKey(const ValueKey('dt-rep-go')));
    await t.pumpAndSettle();
    expect(find.textContaining('would run trips KLM-C and KLM-B'), findsOneWidget);
    expect(find.text('Replace Trip KLM-C · Pickup'), findsOneWidget, reason: 'the window stays open');
    replaceRefused = null;
  });

  testWidgets('a replaced trip is neither restored nor replaced again; its replacement says so', (t) async {
    final relief = {
      ...trip(35, 'KLM-C', 8, 'BUS-40', 40, 'SCHEDULED', const []),
      'replaces_trip_id': 33,
      'replaces_vehicle_code': 'VAN-02',
    };
    await open(t, data: {
      'trip_date': '2026-11-25',
      'trips': [
        broken(extra: {'replaced_by_trip_id': 35, 'replaced_by_vehicle_code': 'BUS-40'}),
        relief,
      ],
    });
    expect(find.text('Replaced: BUS-40 runs it'), findsOneWidget);
    expect(find.text('Pickup · Replaces VAN-02'), findsOneWidget);
    expect(find.byKey(const ValueKey('dt-replace-33')), findsNothing);
    expect(find.byKey(const ValueKey('dt-replace-35')), findsNothing, reason: 'a scheduled trip is not replaced');
    expect(find.byWidgetPredicate((w) => w.key == const ValueKey('dt-status-33-CANCELLED')), findsNothing, reason: 'not restorable');
    expect(find.text('CANCELLED'), findsOneWidget);
  });

  testWidgets('a day with no trips offers Make Trips', (t) async {
    await open(t, data: {'trip_date': '2026-11-25', 'trips': <Map<String, dynamic>>[]});
    expect(find.textContaining('No trips on'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('dt-make')));
    await t.pumpAndSettle();
    expect(made, ['2026-11-24'], reason: 'the day shown, today');
  });
}
