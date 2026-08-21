import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/supabase_config.dart';
import 'utils/app_token_http_client.dart';
import 'utils/app_theme.dart';
import 'utils/app_routes.dart';
import 'utils/auth_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Silence all debugPrint calls in release builds. Every existing
  // debugPrint across the codebase routes through this handler, so
  // this single override keeps debug behaviour identical while
  // preventing logs from leaking in production.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // Initialize Supabase. A custom http client attaches the app session token as
  // an `x-app-token` header on every request so the server's db-pre-request hook
  // can enforce per-tenant reads via RLS (see read_lockdown_foundation.sql).
  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
    httpClient: AppTokenHttpClient(),
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
      ],
      child: const SchoolAdminApp(),
    ),
  );
}

class SchoolAdminApp extends StatelessWidget {
  const SchoolAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      // Design baseline tuned so 1366×768 renders at ~78% scale
      // (1366/1750 ≈ 0.78). On 1920×1080 things scale up to ~110%, so the
      // UI feels proportional on both common laptop and desktop sizes.
      // Mobile screens (welcome/onboarding/login/forgot) use fixed pixel
      // values, so they aren't affected.
      designSize: const Size(1750, 984),
      minTextAdapt: true,
      builder: (context, child) {
        return MaterialApp(
          title: 'EduCore360 - School Administration',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeMode.light,
          scrollBehavior: const _AppScrollBehavior(),
          initialRoute: AppRoutes.splash,
          routes: AppRoutes.routes,
          builder: (context, child) {
            // Apply project-wide compact button styling at <= 1366 only.
            // Inline ElevatedButton.styleFrom() calls in screens still win
            // (they don't inherit theme), but every "stock" button picks
            // this up without per-call MediaQuery checks.
            final screenW = MediaQuery.of(context).size.width;
            final compact = screenW <= 1366;
            if (screenW < 1200) {
              // Small screens / windows: below the 1366 tier there was no
              // baseline, so the 1607 design shrank the whole UI to ~60% on a
              // ~1000px window. Track the width to hold a readable ~85% scale
              // (clamped so tiny/odd sizes stay sensible).
              final dw = (screenW / 0.85).clamp(1000.0, 1560.0);
              ScreenUtil.init(context, designSize: Size(dw, dw * 984 / 1750), minTextAdapt: true);
            } else if (compact) {
              // Re-initialize ScreenUtil with a tighter design baseline so
              // .sp/.w/.h/.r values render at ~85% at 1366 instead of ~78%.
              // 1366 / 1607 ≈ 0.85. The outer ScreenUtilInit(1750, 984) keeps
              // applying at 1920+, so this only affects 1366.
              ScreenUtil.init(context, designSize: const Size(1607, 904), minTextAdapt: true);
            }
            if (!compact || child == null) return child ?? const SizedBox.shrink();
            return Theme(
              data: AppTheme.compactButtons(Theme.of(context)),
              child: child,
            );
          },
        );
      },
    );
  }
}

/// App-wide scroll behaviour:
/// - Adds trackpad and stylus to the default drag set (mouse is intentionally
///   omitted — enabling it makes mouse-drag inside TextFields a scroll
///   gesture, which breaks click-drag text selection).
/// - Uses a smooth bouncing physics so wheel/drag inertia feels natural.
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  // Always-visible scrollbar WITH a visible track on desktop. Setting
  // thumb/track visibility on the Scrollbar widget directly is more
  // reliable than relying on ScrollbarThemeData resolution alone.
  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    if (axisDirectionToAxis(details.direction) == Axis.vertical) {
      switch (getPlatform(context)) {
        case TargetPlatform.linux:
        case TargetPlatform.macOS:
        case TargetPlatform.windows:
          return Scrollbar(
            controller: details.controller,
            thumbVisibility: true,
            trackVisibility: true,
            child: child,
          );
        case TargetPlatform.android:
        case TargetPlatform.fuchsia:
        case TargetPlatform.iOS:
          break;
      }
    }
    return super.buildScrollbar(context, child, details);
  }
}
