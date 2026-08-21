import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

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
  /// Public Supabase Storage object. Bucket `app-updates`, file `latest.json`.
  static const String manifestUrl =
      'https://ohbjbiwrjykdugbrimxe.supabase.co/storage/v1/object/public/app-updates/latest.json';

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
