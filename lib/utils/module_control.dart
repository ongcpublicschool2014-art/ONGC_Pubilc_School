import '../services/supabase_service.dart';
import 'app_menu.dart';
import 'school_terms.dart';

/// Module Control: which modules / menus an institution gets, set by the
/// software vendor when installing for a client (hidden screen, Ctrl+Shift+M
/// on the sign-in screen, behind the vendor password). Stored in
///   public.modules       one row per module (modshort below)
///   public.activitytype  one row per menu   (actname = AppNavItem.label)
/// activestatus 0 = switched off. A menu with no row is on. The app can only
/// read these tables; writes go through the vendor_* RPCs
/// (C:/pg_backups/school_vendor_modules.sql).

/// Sections that are never listed: the Dashboard is always on.
const Set<String> kLockedSections = {'MAIN MENU'};

/// Menus that are always on, whatever is switched off: without them a school
/// could not manage its own logins. Listed with a locked switch.
const Set<String> kAlwaysOnMenus = kAlwaysAllowedForAdmin;

/// Sidebar section -> its row in public.modules: (modshort, modname, modtype).
/// modtype 'C' = money collection, 'A' = administrative.
const Map<String, (String, String, String)> kModuleOfSection = {
  'ADMISSION': ('ADM', 'Admission', 'A'),
  'STUDENTS': ('STU', 'Student Details', 'A'),
  'TC': ('TC', 'Transfer Certificate', 'A'),
  'FEES': ('FEE', 'Fees', 'C'),
  'TRANSPORT': ('TRN', 'Transport', 'C'),
  'BANKING': ('BANK', 'Banking', 'C'),
  'REPORTS': ('RPT', 'Reports', 'A'),
  'SETUP': ('SETUP', 'Setup', 'A'),
  'GENERAL': ('GEN', 'General', 'A'),
};

/// Short code for a menu (activitytype.actshort, max 10): its initials.
String activityShort(String label) {
  final initials = label.split(RegExp(r'[^A-Za-z0-9]+')).where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase()).join();
  final s = initials.isEmpty ? 'ACT' : initials;
  return s.length > 10 ? s.substring(0, 10) : s;
}

/// The menu labels switched off for [insId]: a menu whose activitytype row
/// is off, or whose module is off. A module that is off hides every menu of
/// its section, also one added to the app after the module was last saved
/// (no activitytype row yet). Empty (everything on) when nothing is
/// configured or the tables cannot be read.
Future<Set<String>> loadDisabledMenus(int insId) async {
  try {
    final r = await Future.wait([
      SupabaseService.client.from('modules').select('mod_id, modshort, activestatus').eq('ins_id', insId),
      SupabaseService.client.from('activitytype').select('actname, mod_id, activestatus').eq('ins_id', insId),
    ]);
    final offModules = [
      for (final m in (r[0] as List))
        if ((m['activestatus'] as num?)?.toInt() == 0) m,
    ];
    final modOff = {for (final m in offModules) (m['mod_id'] as num?)?.toInt()};
    final codeOff = {for (final m in offModules) '${m['modshort'] ?? ''}'.trim().toUpperCase()};
    final sectionOff = {
      for (final e in kModuleOfSection.entries)
        if (codeOff.contains(e.value.$1)) e.key,
    };
    return {
      for (final a in (r[1] as List))
        if (((a['activestatus'] as num?)?.toInt() == 0 || modOff.contains((a['mod_id'] as num?)?.toInt())) &&
            !kAlwaysOnMenus.contains('${a['actname']}'))
          '${a['actname']}',
      for (final i in kAppNavItems)
        if (sectionOff.contains(i.section) && !kAlwaysOnMenus.contains(i.label)) i.label,
    };
  } catch (_) {
    return {};
  }
}

/// Menus the vendor can switch, grouped by section in sidebar order -- only
/// those that exist on a [school] (or college) database. Passed in, not read
/// from [isSchool]: before an institution login no schema is set.
Map<String, List<AppNavItem>> switchableMenus({required bool school}) {
  final out = <String, List<AppNavItem>>{};
  for (final i in kAppNavItems) {
    if (kLockedSections.contains(i.section) || !kModuleOfSection.containsKey(i.section)) continue;
    if (school ? kSchoolHiddenNavItems.contains(i.label) : kCollegeHiddenSubItems.contains(i.label)) continue;
    out.putIfAbsent(i.section, () => []).add(i);
  }
  return out;
}

/// The vendor password and saving (all checked by the database).
class VendorModules {
  VendorModules._();

  static Future<bool> passwordIsSet() async => (await SupabaseService.client.rpc('vendor_password_is_set')) == true;

  static Future<bool> check(String pass) async =>
      (await SupabaseService.client.rpc('vendor_check', params: {'p_pass': pass})) == true;

  static Future<void> setPassword(String? oldPass, String newPass) =>
      SupabaseService.client.rpc('vendor_set_password', params: {'p_old': oldPass, 'p_new': newPass});

  /// Saves every switchable menu of [insId]: off when in [off].
  static Future<void> save(String pass, int insId, Set<String> off, {required bool school}) async {
    final modules = [
      for (final e in switchableMenus(school: school).entries)
        {
          'modshort': kModuleOfSection[e.key]!.$1,
          'modname': kModuleOfSection[e.key]!.$2,
          'modtype': kModuleOfSection[e.key]!.$3,
          'activities': [
            for (final i in e.value)
              {'actname': i.label, 'actshort': activityShort(i.label), 'active': kAlwaysOnMenus.contains(i.label) || !off.contains(i.label)},
          ],
        },
    ];
    await SupabaseService.client.rpc('vendor_save_modules', params: {'p_pass': pass, 'p_ins_id': insId, 'p_modules': modules});
  }
}
