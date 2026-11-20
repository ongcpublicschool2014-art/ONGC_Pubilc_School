import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:school_admin/screens/admin/next_year_card.dart';

/// Year End's "Create the Next Academic Year" card lays out without overflow
/// on every window size the app meets: the card gets the content area beside
/// the sidebar (desktop) or the whole width (phone).
///
/// The real fonts are loaded from the app's own font cache when this PC has
/// one (text then measures as in the app); otherwise the test font is used.
Future<void> _loadCachedFonts() async {
  final dir = Directory('${Platform.environment['APPDATA']}\\com.edudesk\\EduCore 360');
  if (!dir.existsSync()) return;
  final byFamily = <String, List<File>>{};
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.ttf'))) {
    final name = f.uri.pathSegments.last;
    final parts = name.split('_');
    if (parts.length < 3) continue;
    byFamily.putIfAbsent('${parts[0]}_${parts[1]}', () => []).add(f); // e.g. Fraunces_600, as google_fonts names it
  }
  for (final e in byFamily.entries) {
    final loader = FontLoader(e.key);
    for (final f in e.value) {
      loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    await _loadCachedFonts();
  });

  const sizes = <String, Size>{
    'fullhd 1920x1080': Size(1920 - 290, 1080 - 130),
    'laptop 1366x768': Size(1366 - 290, 768 - 130),
    'small 1280x720': Size(1280 - 290, 720 - 130),
    'tablet 900x700': Size(900, 700 - 130),
    'phone 400x800': Size(400, 800),
    'phone 340x640': Size(340, 640),
  };

  for (final e in sizes.entries) {
    testWidgets('fits ${e.key}', (t) async {
      t.view.physicalSize = e.value;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final problems = <String>[];
      // google_fonts reports, from a background future, that the fonts are not
      // bundled (they come from the cache loaded above); that is not layout
      final done = Completer<void>();
      runZonedGuarded(() async {
        await t.pumpWidget(ScreenUtilInit(
          designSize: e.value.width < 600 ? const Size(390, 844) : const Size(1750, 984),
          minTextAdapt: true,
          builder: (_, __) => MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(backgroundColor: const Color(0xFFF4EFE6), body: NextYearCard(currentYear: '2026-2027', onCreated: () {})),
          ),
        ));
        await t.pump(const Duration(milliseconds: 200));
        done.complete();
      }, (err, _) {
        if (!'$err'.contains('allowRuntimeFetching')) problems.add('$err');
      });
      await done.future;
      // a layout overflow is reported as an exception
      for (Object? x = t.takeException(); x != null; x = t.takeException()) {
        final m = '$x';
        if (!m.contains('google_fonts') && !m.contains('allowRuntimeFetching')) problems.add(m);
      }
      expect(problems, isEmpty);
    });
  }
}
