import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/transport/opted_students_panel.dart';
import 'package:school_admin/screens/transport/student_enrollment_screen.dart';
import 'package:school_admin/widgets/pill_tab.dart';

/// The server's students: the test's save sets the mode, as the server does.
List<Map<String, dynamic>> _students() => [
      {'stu_id': 1, 'stuadmno': 'ADM001', 'stuname': 'Anitha R', 'stuclass': 'LKG A', 'cla_id': 4, 'transportmode': 'BUS'},
      {'stu_id': 2, 'stuadmno': 'ADM002', 'stuname': 'Bala K', 'stuclass': 'LKG A', 'cla_id': 4, 'transportmode': 'OWN'},
      {'stu_id': 3, 'stuadmno': 'ADM003', 'stuname': 'Chitra M', 'stuclass': 'UKG B', 'cla_id': 8, 'transportmode': ' bus'},
      {'stu_id': 4, 'stuadmno': 'ADM004', 'stuname': 'Divya S', 'stuclass': 'UKG B', 'cla_id': 8, 'transportmode': null},
    ];

Future<void> _open(WidgetTester t, List<Map<String, dynamic>> db, {List<Set<int>>? opted, bool failSave = false}) async {
  await t.binding.setSurfaceSize(const Size(1366, 768));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(ScreenUtilInit(
    designSize: const Size(1750, 984),
    builder: (_, __) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1100,
          height: 620,
          child: OptedStudentsPanel(
            load: () async => [for (final r in db) Map<String, dynamic>.from(r)],
            save: (ids) async {
              if (failSave) throw Exception('no network');
              for (final r in db) {
                if (ids.contains(r['stu_id'])) r['transportmode'] = 'BUS';
              }
            },
            onOptedChanged: opted?.add,
          ),
        ),
      ),
    ),
  ));
  await t.pump();
  await t.pump();
}

ElevatedButton _button(WidgetTester t, String text) => t.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, text));

void main() {
  testWidgets('lists only the BUS students, with S.No, class, admission no and name', (t) async {
    final opted = <Set<int>>[];
    await _open(t, _students(), opted: opted);
    expect(t.takeException(), isNull);
    for (final h in ['S.NO', 'CLASS', 'ADMISSION NO', 'STUDENT NAME']) {
      expect(find.text(h), findsOneWidget);
    }
    expect(find.text('Anitha R'), findsOneWidget);
    expect(find.text('Chitra M'), findsOneWidget); // ' bus' counts
    expect(find.text('Bala K'), findsNothing);
    expect(find.text('Divya S'), findsNothing);
    expect(opted.last, {1, 3});
    expect(_button(t, 'Save').onPressed, isNull); // nothing to save
  });

  testWidgets('Add Students offers the others; Save opts the ticked ones', (t) async {
    final db = _students();
    final opted = <Set<int>>[];
    await _open(t, db, opted: opted);

    await t.tap(find.widgetWithText(ElevatedButton, 'Add Students'));
    await t.pumpAndSettle();
    expect(find.text('Bala K'), findsOneWidget);
    expect(find.text('Divya S'), findsOneWidget);
    expect(find.byKey(const ValueKey('opted-add-1')), findsNothing); // already opted

    await t.tap(find.text('Bala K'));
    await t.pump();
    await t.tap(find.widgetWithText(ElevatedButton, 'Add 1 Student'));
    await t.pumpAndSettle();

    // on the list, marked, and not opted until saved
    expect(find.text('Bala K'), findsOneWidget);
    expect(find.text('NOT SAVED'), findsOneWidget);
    expect(db[1]['transportmode'], 'OWN');
    expect(opted.last, {1, 3});

    await t.tap(find.widgetWithText(ElevatedButton, 'Save 1 Student'));
    await t.pumpAndSettle();
    expect(db[1]['transportmode'], 'BUS');
    expect(find.text('NOT SAVED'), findsNothing);
    expect(find.text('Bala K'), findsOneWidget);
    expect(opted.last, {1, 2, 3});
    expect(t.takeException(), isNull);
  });

  testWidgets('a student added by mistake comes off before saving', (t) async {
    await _open(t, _students());
    await t.tap(find.widgetWithText(ElevatedButton, 'Add Students'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('opted-add-all')));
    await t.pump();
    await t.tap(find.widgetWithText(ElevatedButton, 'Add 2 Students'));
    await t.pumpAndSettle();
    expect(find.text('NOT SAVED'), findsNWidgets(2));

    await t.tap(find.byTooltip('Take off the list').first);
    await t.pump();
    expect(find.text('NOT SAVED'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Save 1 Student'), findsOneWidget);
  });

  testWidgets('a failed save keeps the students on the list, still not saved', (t) async {
    final db = _students();
    await _open(t, db, failSave: true);
    await t.tap(find.widgetWithText(ElevatedButton, 'Add Students'));
    await t.pumpAndSettle();
    await t.tap(find.text('Divya S'));
    await t.pump();
    await t.tap(find.widgetWithText(ElevatedButton, 'Add 1 Student'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(ElevatedButton, 'Save 1 Student'));
    await t.pumpAndSettle();
    expect(db[3]['transportmode'], isNull);
    expect(find.text('NOT SAVED'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Save 1 Student'), findsOneWidget);
  });

  // Student Enrollment has the tab on its left, and opens on its own tab.
  testWidgets('Student Enrollment has Opted Students as its left tab', (t) async {
    await t.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => const MaterialApp(home: Scaffold(body: SizedBox(width: 1100, height: 620, child: StudentEnrollmentScreen()))),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    final tabs = t.widgetList<PillTab>(find.byType(PillTab)).toList();
    expect([for (final p in tabs) p.label], ['Opted Students', 'Student Enrollment', 'Staff Enrollment']);
    expect([for (final p in tabs) p.selected], [false, true, false]);

    await t.tap(find.widgetWithText(PillTab, 'Opted Students'));
    await t.pump();
    expect(t.takeException(), isNull);
    expect([for (final p in t.widgetList<PillTab>(find.byType(PillTab))) p.selected], [true, false, false]);

    // Staff Enrollment opens (and loads) on its own tab
    await t.tap(find.widgetWithText(PillTab, 'Staff Enrollment'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
    expect([for (final p in t.widgetList<PillTab>(find.byType(PillTab))) p.selected], [false, false, true]);
  });
}
