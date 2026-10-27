import 'dart:io';
import '../config/supabase_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'supabase_service.dart';

/// Per-device install gate. Each Windows PC enters a one-time activation
/// code on first launch; the code is bound to the machine's Windows
/// MachineGuid server-side. Every login verifies that binding is still
/// active before the user can reach the dashboard.
class DeviceService {
  static const _storage = FlutterSecureStorage(
    wOptions: WindowsOptions(useBackwardCompatibility: true),
  );

  static const _kDeviceId = 'device_id';
  static const _kBoundInsId = 'device_bound_ins_id';
  static const _kMachineName = 'device_machine_name';
  static const _kIsSuperAdmin = 'device_is_super_admin';

  static String? _cachedDeviceId;

  /// Windows MachineGuid (HKLM\SOFTWARE\Microsoft\Cryptography). Stable
  /// across app reinstalls; changes on OS reinstall.
  static Future<String> getDeviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;

    if (!Platform.isWindows) {
      final stored = await _storage.read(key: _kDeviceId);
      _cachedDeviceId = stored ?? 'dev-${DateTime.now().millisecondsSinceEpoch}';
      await _storage.write(key: _kDeviceId, value: _cachedDeviceId);
      return _cachedDeviceId!;
    }

    try {
      final result = await Process.run(
        'reg',
        ['query', r'HKLM\SOFTWARE\Microsoft\Cryptography', '/v', 'MachineGuid'],
        runInShell: true,
      );
      final out = (result.stdout as String).trim();
      final match = RegExp(r'MachineGuid\s+REG_SZ\s+([0-9a-fA-F-]+)').firstMatch(out);
      if (match != null) {
        _cachedDeviceId = match.group(1)!.trim();
        return _cachedDeviceId!;
      }
    } catch (e) {
      debugPrint('DeviceService: MachineGuid read failed: $e');
    }

    final stored = await _storage.read(key: _kDeviceId);
    if (stored != null && stored.isNotEmpty) {
      _cachedDeviceId = stored;
      return stored;
    }
    final generated = 'win-${DateTime.now().microsecondsSinceEpoch}';
    await _storage.write(key: _kDeviceId, value: generated);
    _cachedDeviceId = generated;
    return generated;
  }

  static Future<String> getMachineName() async {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'unknown';
    }
  }

  /// True if this PC has been activated for any role.
  ///
  /// Only the local secure_storage is consulted. On a fresh install (after
  /// the user uninstalled+reinstalled the app) the storage is wiped, so
  /// this returns false and the activation-code prompt is shown again — the
  /// office can audit each install and re-bind the PC explicitly.
  static Future<bool> isActivated() async {
    // Test builds may waive the gate, but only while pointed at a non-production
    // project (see SupabaseConfig.skipDeviceActivation). A production install
    // has no config.json, so this is false there and the gate stands.
    if (SupabaseConfig.skipDeviceActivation && !SupabaseConfig.isDefaultProject) {
      return true;
    }
    // A build made with --dart-define=SKIP_DEVICE_ACTIVATION=true. Waives the
    // gate unconditionally, so such a build must never be handed out as a
    // release -- it is for a test PC that cannot be given a config.json.
    if (SupabaseConfig.forceSkipDeviceActivation) {
      debugPrint('DEVICE ACTIVATION BYPASSED - test build, not for release');
      return true;
    }
    final bound = await _storage.read(key: _kBoundInsId);
    final sa = await _storage.read(key: _kIsSuperAdmin);
    return (bound != null && bound.isNotEmpty) || sa == 'true';
  }

  /// The ins_id this PC was activated for, or null (super-admin / inactive).
  static Future<int?> boundInstitutionId() async {
    final v = await _storage.read(key: _kBoundInsId);
    return v == null ? null : int.tryParse(v);
  }

  static Future<bool> isSuperAdminDevice() async {
    final v = await _storage.read(key: _kIsSuperAdmin);
    return v == 'true';
  }

  static Future<({bool ok, String? error, int? insId, bool isSuperAdmin})>
      activate(String code) async {
    try {
      final deviceId = await getDeviceId();
      final machineName = await getMachineName();
      final result = await SupabaseService.client.rpc('activate_device', params: {
        'p_code': code.trim().toUpperCase(),
        'p_device_id': deviceId,
        'p_machine_name': machineName,
      });
      final map = Map<String, dynamic>.from(result as Map);
      final insId = map['ins_id'] as int?;
      final isSuperAdmin = map['is_super_admin'] == true;
      await _storage.write(key: _kMachineName, value: machineName);
      if (isSuperAdmin) {
        await _storage.write(key: _kIsSuperAdmin, value: 'true');
        await _storage.delete(key: _kBoundInsId);
      } else {
        await _storage.write(key: _kBoundInsId, value: '$insId');
        await _storage.delete(key: _kIsSuperAdmin);
      }
      return (ok: true, error: null, insId: insId, isSuperAdmin: isSuperAdmin);
    } catch (e) {
      final msg = e.toString().replaceFirst(RegExp(r'^.*?:\s*'), '');
      return (ok: false, error: msg, insId: null, isSuperAdmin: false);
    }
  }

  /// Login-time check. Pass insId = null for super-admin login.
  static Future<bool> verify(int? insId) async {
    try {
      final deviceId = await getDeviceId();
      final result = await SupabaseService.client.rpc('verify_device', params: {
        'p_ins_id': insId,
        'p_device_id': deviceId,
      });
      return result == true;
    } catch (e) {
      debugPrint('DeviceService.verify failed: $e');
      return false;
    }
  }

  static Future<void> clearLocal() async {
    await _storage.delete(key: _kBoundInsId);
    await _storage.delete(key: _kMachineName);
    await _storage.delete(key: _kIsSuperAdmin);
  }
}
