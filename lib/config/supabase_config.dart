import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'paytm_config.dart';
import '../services/supabase_service.dart';

/// Supabase configuration.
///
/// The URL + anon key are compiled in as DEFAULTS, but can be OVERRIDDEN at
/// runtime by a `config.json` — so the same build can point at a different
/// Supabase project WITHOUT rebuilding. Searched, first valid wins:
///   1. config.json next to the .exe
///   2. %APPDATA%\FITSchool\config.json   (user-writable, survives updates)
///
/// FIT School is a separate product from the college app (EduCore360): its
/// own compiled-in project (the school's live server), its own config.json
/// folder, data folder (Runner.rc ProductName) and installer AppId, so one
/// app's settings or update can never move the other.
///
/// config.json format:
///   {
///     "supabaseUrl": "https://xxxx.supabase.co",
///     "supabaseAnonKey": "eyJ...anon key..."
///   }
///
/// Call [load] ONCE at startup BEFORE Supabase.initialize(). If no valid file is
/// found the compiled defaults are used, so a plain install keeps working.
class SupabaseConfig {
  SupabaseConfig._();

  // Compiled-in defaults (used when no valid config.json is found).
  static const String _defaultUrl = 'https://xjdvrrcmvyjocxynmhql.supabase.co';
  static const String _defaultAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhqZHZycmNtdnlqb2N4eW5taHFsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk5NDg5MjUsImV4cCI6MjA5NTUyNDkyNX0.P1wWT1owyJztt5dHC0BpOHYtlQWXrf8MC7Iih3Nj3Bg';

  /// Active connection values (defaults unless overridden by [load]).
  static String url = _defaultUrl;
  static String anonKey = _defaultAnonKey;

  /// Where the active values came from — 'default (compiled-in)' or the
  /// config.json path. Handy for a debug log / an About screen.
  static String source = 'default (compiled-in)';

  /// True while the app is talking to the COMPILED-IN project (production).
  /// Anything that must never be weakened in production keys off this.
  static bool get isDefaultProject => url == _defaultUrl;

  /// Opt-in test convenience from config.json: skip the one-time device
  /// activation gate. HONOURED ONLY when [isDefaultProject] is false — i.e.
  /// a config.json has pointed the app at some OTHER project. Dropping a
  /// config.json next to a production install therefore cannot unlock it:
  /// the bypass dies with the production URL.
  static bool skipDeviceActivation = false;

  /// COMPILE-TIME bypass of the device activation gate, for a test installer
  /// that has to run without a config.json beside it.
  ///
  /// Unlike [skipDeviceActivation] this is NOT conditional on the project: it
  /// waives the gate wherever the build is installed, production included.
  /// That is the whole point -- and the whole danger -- so it is a
  /// `bool.fromEnvironment` and nothing else can turn it on:
  ///
  ///     flutter build windows --release --dart-define=SKIP_DEVICE_ACTIVATION=true
  ///
  /// An ordinary `flutter build windows --release` leaves it false, so a
  /// release cut without that flag can never ship unlocked, however the build
  /// was invoked. There is deliberately no config.json key and no UI for it.
  /// NOTE: this was a `bool.fromEnvironment('SKIP_DEVICE_ACTIVATION')` until
  /// 06-10-2026. The define did not survive the Windows AOT build -- the
  /// constant still folded to false with the flag passed, and after a
  /// `flutter clean` too -- so the bypass silently did nothing and the test
  /// installer still asked for an activation code. A plain constant cannot
  /// fail that way: what the source says is what the build does.
  ///
  /// MUST BE false ON ANY COMMIT AND ANY RELEASE BUILD. Flip to true, build
  /// the test installer, flip it straight back.
  static const bool forceSkipDeviceActivation = false;

  /// Load an optional config.json to override [url] / [anonKey] at runtime.
  /// Never throws; silently keeps the compiled defaults on any problem.
  static Future<void> load() async {
    // Build-time override, mainly for the WEB build (which cannot read a
    // config.json from disk):
    //   flutter run -d edge --dart-define=SUPABASE_URL=https://xxxx.supabase.co
    //                       --dart-define=SUPABASE_ANON_KEY=sb_publishable_...
    // Both must be given. The test-only config.json switches are deliberately
    // NOT settable this way, so they stay off.
    const envUrl = String.fromEnvironment('SUPABASE_URL');
    const envKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    if (envUrl.isNotEmpty && envKey.isNotEmpty) {
      url = envUrl;
      anonKey = envKey;
      source = 'dart-define';
      debugPrint('SupabaseConfig: using --dart-define override ($envUrl)');
      return;
    }
    if (kIsWeb) return; // dart:io not available on web
    for (final path in _candidatePaths()) {
      try {
        final f = File(path);
        if (!f.existsSync()) continue;
        final data = jsonDecode(await f.readAsString());
        if (data is! Map) continue;
        final u = (data['supabaseUrl'] ?? data['url'])?.toString().trim();
        final k = (data['supabaseAnonKey'] ?? data['anonKey'] ?? data['key'])?.toString().trim();
        if (u != null && u.isNotEmpty && k != null && k.isNotEmpty) {
          url = u;
          anonKey = k;
          source = path;
          skipDeviceActivation = data['skipDeviceActivation'] == true;
          // "paytmStaging": true sends Paytm to the staging gateway with the
          // staging MID. Same gate as above: it only has effect because a
          // config.json has already pointed this machine somewhere other than
          // the compiled-in production project.
          PaytmConfig.isProduction = data['paytmStaging'] != true;
          // "feeGroupSettlement": true routes an online collection to the FEE
          // GROUP's own Paytm merchant (hostel fees -> the hostel account)
          // instead of the institution's single merchant. Same gate again: it
          // is a per-machine opt-in for testing that routing, never a shipped
          // default, because it also stops a student paying college and hostel
          // dues in one online transaction.
          SupabaseService.kFeeGroupSettlement =
              data['feeGroupSettlement'] == true;
          debugPrint('SupabaseConfig: using override from $path');
          return;
        }
      } catch (_) {
        // Malformed file — try the next candidate, else fall back to defaults.
      }
    }
  }

  static List<String> _candidatePaths() {
    final sep = Platform.pathSeparator;
    final paths = <String>[];
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      paths.add('$exeDir${sep}config.json');
    } catch (_) {}
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      paths.add('$appData${sep}FITSchool${sep}config.json');
    }
    return paths;
  }
}
