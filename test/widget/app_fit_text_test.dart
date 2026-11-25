import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/widgets/app_search_field.dart';
import 'package:school_admin/widgets/app_ui.dart';

const _hint = 'Search by name, admission no. or mobile';

Future<double?> _hintSize(WidgetTester tester, double width) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ScreenUtilInit(
    designSize: const Size(1750, 984),
    builder: (_, __) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: const AppSearchField(hintText: _hint))),
      ),
    ),
  ));
  expect(find.byType(AppFitText), findsOneWidget);
  return tester.renderObject<RenderAppFitText>(find.byType(AppFitText)).usedFontSize;
}

void main() {
  testWidgets('a long field hint never shrinks below 80%', (tester) async {
    final narrow = await _hintSize(tester, 160);
    expect(narrow, closeTo(12.5 * 0.8, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a hint that fits keeps its size', (tester) async {
    final wide = await _hintSize(tester, 1200);
    expect(wide, 12.5);
  });

  testWidgets('works inside IntrinsicHeight', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            child: IntrinsicHeight(child: Row(children: [Expanded(child: AppFitText(_hint))])),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(AppFitText)).height, greaterThan(0));
  });

  // The baseline is asked for by an ancestor that is not the direct parent
  // (here the Row, through the Padding) — as a dropdown's InputDecorator does.
  // Reading `size` there trips a debug assertion and blanks the whole screen
  // (the "Request Code" tab of Activate This PC).
  testWidgets('gives its baseline to an ancestor that is not its parent', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Padding(padding: EdgeInsets.all(4), child: AppFitText(_hint)),
            Text('x'),
          ],
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
