import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/widgets/app_ui.dart';
import 'package:school_admin/widgets/app_dropdown_field.dart';

void main() {
  testWidgets('an empty dropdown centres its placeholder like a text field', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (ctx, __) => MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => Center(
            child: SizedBox(width: 300, child: Column(mainAxisSize: MainAxisSize.min, children: [
              AppDropdownField<String>(
                key: const Key('dd'),
                isExpanded: true,
                decoration: AppUI.field(context, 'Select standard'),
                items: const [DropdownMenuItem(value: 'a', child: Text('A'))],
                onChanged: (_) {},
              ),
              TextField(key: const Key('tf'), decoration: AppUI.field(context, 'Type here')),
            ])),
          )),
        ),
      ),
    ));
    for (final k in ['dd', 'tf']) {
      final box = tester.renderObject<RenderBox>(find.byKey(Key(k)));
      final top = box.localToGlobal(Offset.zero).dy;
      final tb = tester.renderObject<RenderBox>(k == 'dd' ? find.descendant(of: find.byType(IndexedStack), matching: find.byType(AppFitText)).first : find.descendant(of: find.byKey(const Key('tf')), matching: find.byType(AppFitText)));
      final ty = tb.localToGlobal(Offset.zero).dy;
      final off = (ty - top + tb.size.height / 2) - box.size.height / 2;
      expect(off.abs(), lessThan(2), reason: '$k placeholder is ${off}px off centre');
    }
  });
}
