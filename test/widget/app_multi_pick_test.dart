import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/widgets/app_multi_pick.dart';

/// The reports' many-choice filter (one style on every report, 2026-11-24):
/// a panel under the field that opened it, not a dialog in the middle.
void main() {
  /// A 300 x 42 field at [fieldTop]; tapping it opens the panel under it.
  Future<void> open<T>(WidgetTester t, {required List<AppPickGroup<T>> groups, double fieldTop = 100}) async {
    await t.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            Positioned(
              left: 200,
              top: fieldTop,
              width: 300,
              height: 42,
              child: Builder(builder: (ctx) => ElevatedButton(
                    key: const ValueKey('field'),
                    onPressed: () => showAppMultiPick<T>(ctx, anchor: ctx, title: 'Select Fee Types', groups: groups, selected: const {}),
                    child: const Text('Fee Type'),
                  )),
            ),
          ]),
        ),
      ),
    ));
    await t.tap(find.byKey(const ValueKey('field')));
    await t.pumpAndSettle();
  }

  testWidgets('opens just under the field, not in the middle of the screen', (t) async {
    await open<String>(t, groups: [('', [('TUTION FEE', 'TUTION FEE'), ('BOOK FEE', 'BOOK FEE')])]);
    final title = t.getRect(find.text('Select Fee Types'));
    final field = t.getRect(find.byKey(const ValueKey('field')));
    expect(title.top, greaterThan(field.bottom), reason: 'below the field');
    expect(title.top - field.bottom, lessThan(40), reason: 'right under it');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('opens above a field low on the screen', (t) async {
    await open<String>(t, groups: [('', [for (var i = 0; i < 6; i++) ('F$i', 'Fee $i')])], fieldTop: 700);
    final apply = t.getRect(find.byKey(const ValueKey('multi-pick-apply')));
    expect(apply.bottom, lessThanOrEqualTo(700), reason: 'the panel ends above the field');
  });

  testWidgets('Select All, Clear, Apply and Cancel', (t) async {
    Set<String>? got;
    var closed = false;
    await t.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(builder: (ctx) => ElevatedButton(
                  key: const ValueKey('field'),
                  onPressed: () async {
                    got = await showAppMultiPick<String>(ctx, anchor: ctx, title: 'Fees', groups: [
                      ('', [('A', 'Alpha'), ('B', 'Beta')]),
                    ], selected: const {});
                    closed = true;
                  },
                  child: const Text('open'),
                )),
          ),
        ),
      ),
    ));
    await t.tap(find.byKey(const ValueKey('field')));
    await t.pumpAndSettle();
    await t.tap(find.text('Select All'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('multi-pick-apply')));
    await t.pumpAndSettle();
    expect(closed, isTrue);
    expect(got, {'A', 'B'});

    closed = false;
    await t.tap(find.byKey(const ValueKey('field')));
    await t.pumpAndSettle();
    await t.tap(find.text('Alpha'));
    await t.pump();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(closed, isTrue);
    expect(got, isNull, reason: 'Cancel changes nothing');
  });

  testWidgets('a long list has a search; Select All ticks only the matches', (t) async {
    Set<String>? got;
    await t.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(builder: (ctx) => ElevatedButton(
                  key: const ValueKey('field'),
                  onPressed: () async => got = await showAppMultiPick<String>(ctx,
                      anchor: ctx,
                      title: 'Fees',
                      groups: [('', [for (final n in ['TUTION FEE', 'BOOK FEE', 'BUS FEE', 'LAB FEE', 'EXAM FEE', 'SPORTS FEE', 'UNIFORM', 'DIARY', 'ID CARD']) (n, n)])],
                      selected: const {}),
                  child: const Text('open'),
                )),
          ),
        ),
      ),
    ));
    await t.tap(find.byKey(const ValueKey('field')));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'fee');
    await t.pump();
    expect(find.text('UNIFORM'), findsNothing);
    await t.tap(find.text('Select All'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('multi-pick-apply')));
    await t.pumpAndSettle();
    expect(got, {'TUTION FEE', 'BOOK FEE', 'BUS FEE', 'LAB FEE', 'EXAM FEE', 'SPORTS FEE'});
  });

  testWidgets('a group heading ticks its group; "tick at least one" stops Apply', (t) async {
    Set<int>? got;
    await t.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(builder: (ctx) => ElevatedButton(
                  key: const ValueKey('field'),
                  onPressed: () async => got = await showAppMultiPick<int>(ctx,
                      anchor: ctx,
                      title: 'Sections',
                      requireOne: true,
                      groups: [
                        ('I', [(1, 'I A'), (2, 'I B')]),
                        ('II', [(3, 'II A')]),
                      ],
                      selected: const {}),
                  child: const Text('open'),
                )),
          ),
        ),
      ),
    ));
    await t.tap(find.byKey(const ValueKey('field')));
    await t.pumpAndSettle();
    final apply = find.byKey(const ValueKey('multi-pick-apply'));
    expect(t.widget<ElevatedButton>(apply).onPressed, isNull, reason: 'nothing ticked yet');
    expect(find.text('Tick at least one.'), findsOneWidget);
    await t.tap(find.text('I'));
    await t.pump();
    await t.tap(apply);
    await t.pumpAndSettle();
    expect(got, {1, 2});
  });
}
