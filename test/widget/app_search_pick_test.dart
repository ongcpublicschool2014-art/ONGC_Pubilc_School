import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/widgets/app_search_pick.dart';

/// The searchable one-choice field (user, 2026-11-24: "search option to fetch
/// the teacher easily").
void main() {
  const staff = [
    AppSearchPickItem<num>(3, 'Lakshmi Narayanan R', detail: 'EMP001 · Principal'),
    AppSearchPickItem<num>(4, 'Senthil Kumar P', detail: 'EMP002 · Teacher'),
    AppSearchPickItem<num>(5, 'Fathima Begum S', detail: 'EMP003 · Teacher'),
  ];

  Future<List<num?>> open(WidgetTester t, {num? value = 3}) async {
    final picked = <num?>[];
    await t.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: StatefulBuilder(
                builder: (_, set) => AppSearchPickField<num>(
                  key: const ValueKey('field'),
                  value: value,
                  items: staff,
                  noneLabel: 'Nobody',
                  title: 'Class teacher',
                  onChanged: (v) => set(() {
                    value = v;
                    picked.add(v);
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.byKey(const ValueKey('field')));
    await t.pumpAndSettle();
    return picked;
  }

  testWidgets('opens under the field with every teacher and Nobody', (t) async {
    await open(t);
    final field = t.getRect(find.byKey(const ValueKey('field')));
    final search = t.getRect(find.byKey(const ValueKey('search-pick-field')));
    expect(search.top, greaterThan(field.bottom), reason: 'under the field');
    for (final s in staff) {
      expect(find.text(s.label), findsWidgets);
    }
    expect(find.byKey(const ValueKey('search-pick-none')), findsOneWidget);
  });

  testWidgets('typing part of a name finds the teacher', (t) async {
    final picked = await open(t);
    await t.enterText(find.byKey(const ValueKey('search-pick-field')), 'sent');
    await t.pump();
    expect(find.text('Fathima Begum S'), findsNothing);
    await t.tap(find.text('Senthil Kumar P'));
    await t.pumpAndSettle();
    expect(picked, [4]);
    expect(find.text('Senthil Kumar P'), findsOneWidget, reason: 'shown in the field');
  });

  testWidgets('the employee code or designation is searched too; Enter takes the first match', (t) async {
    final picked = await open(t);
    await t.enterText(find.byKey(const ValueKey('search-pick-field')), 'emp003');
    await t.pump();
    expect(find.text('Senthil Kumar P'), findsNothing);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
    expect(picked, [5]);
  });

  testWidgets('every word must match: "kumar teacher"', (t) async {
    await open(t);
    await t.enterText(find.byKey(const ValueKey('search-pick-field')), 'kumar teacher');
    await t.pump();
    Finder inList(String t) => find.descendant(of: find.byType(ListView), matching: find.text(t));
    expect(inList('Senthil Kumar P'), findsOneWidget);
    expect(inList('Lakshmi Narayanan R'), findsNothing, reason: 'Principal, not a teacher');
  });

  testWidgets('Nobody clears it; tapping outside changes nothing', (t) async {
    final picked = await open(t);
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();
    expect(picked, isEmpty);
    await t.tap(find.byKey(const ValueKey('field')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('search-pick-none')));
    await t.pumpAndSettle();
    expect(picked, [null]);
    expect(find.text('Nobody'), findsOneWidget);
  });

  testWidgets('Escape closes it', (t) async {
    final picked = await open(t);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-pick-field')), findsNothing);
    expect(picked, isEmpty);
  });
}
