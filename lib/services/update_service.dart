import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config/supabase_config.dart';

/// One available update, parsed from the hosted `latest.json` manifest.
class UpdateInfo {
  final String version; // e.g. "1.1.0"
  final String url;      // direct download URL of the new installer .exe
  final String notes;    // optional release notes shown in the prompt
  final bool mandatory;  // when true, the app blocks until updated
  const UpdateInfo({
    required this.version,
    required this.url,
    this.notes = '',
    this.mandatory = false,
  });
}

/// Checks a hosted manifest for a newer app version. Never throws — a failed
/// check simply returns null so the app is never blocked by the update system.
class UpdateService {
  /// One source for every school, one Supabase project per school: the app
  /// reads the update manifest from the project IT IS CONNECTED TO (compiled
  /// default or config.json) -- bucket `app-updates`, file
  /// `latest-windows.json` (user, 2026-11-13). A school is offered an update
  /// only when its own project holds a manifest AND the installer it names;
  /// a school (or the test project) nobody uploaded to stays where it is.
  static String get manifestUrl =>
      '${_base()}/storage/v1/object/public/app-updates/latest-windows.json';

  static String _base() => SupabaseConfig.url.replaceAll(RegExp(r'/+$'), '');

  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      // Cache-bust so a freshly-published manifest is seen immediately.
      final uri = Uri.parse('$manifestUrl?t=${DateTime.now().millisecondsSinceEpoch}');
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final latest = (j['version'] ?? '').toString().trim();
      final url = (j['url'] ?? '').toString().trim();
      if (latest.isEmpty || url.isEmpty) return null;

      final current = (await PackageInfo.fromPlatform()).version; // from pubspec version
      if (!_isNewer(latest, current)) return null;

      // A valid installer for THIS school: an .exe on this school's own
      // project that is really there. Anything else is not offered.
      if (!await _installerExists(url)) return null;

      return UpdateInfo(
        version: latest,
        url: url,
        notes: (j['notes'] ?? '').toString(),
        mandatory: j['mandatory'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// [url] is an .exe on the connected project's own storage, and it exists.
  static Future<bool> _installerExists(String url) async {
    final u = Uri.tryParse(url);
    final base = Uri.tryParse(_base());
    if (u == null || base == null) return false;
    if (u.scheme != 'https' || u.host.toLowerCase() != base.host.toLowerCase()) return false;
    if (!u.path.toLowerCase().endsWith('.exe')) return false;
    try {
      final head = await http.head(u).timeout(const Duration(seconds: 8));
      if (head.statusCode == 200) return true;
      if (head.statusCode != 405) return false;
      // No HEAD here: ask for the first byte instead of the whole installer.
      final get = await http.get(u, headers: {'Range': 'bytes=0-0'}).timeout(const Duration(seconds: 8));
      return get.statusCode == 200 || get.statusCode == 206;
    } catch (_) {
      return false;
    }
  }

  /// The running app's version (major.minor.patch), for display.
  static Future<String> currentVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '';
    }
  }

  /// Numeric semantic-version compare: returns true when [a] > [b].
  static bool _isNewer(String a, String b) {
    List<int> parts(String v) =>
        v.split(RegExp(r'[.+-]')).map((x) => int.tryParse(x) ?? 0).toList();
    final pa = parts(a), pb = parts(b);
    for (var i = 0; i < 3; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
