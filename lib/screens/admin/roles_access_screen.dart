import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/app_menu.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/pill_tab.dart';
import 'custom_roles_screen.dart';

/// Roles & Access — Admin-only. Two tabs:
///   * Roles       — create/rename the institution's roles (custuserroles).
///   * Menu Access — tick which sidebar menus each role may see.
///
/// Menu grants are stored per role in public.rolemenuaccess. A role with no
/// rows has never been configured and keeps the app's built-in defaults, so
/// this screen is additive — nothing changes until an Admin saves something.
class RolesAccessScreen extends StatefulWidget {
  const RolesAccessScreen({super.key});

  @override
  State<RolesAccessScreen> createState() => _RolesAccessScreenState();
}

class _RolesAccessScreenState extends State<RolesAccessScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab;
  static const _tabLabels = ['Roles', 'Menu Access'];
  static const _tabIcons = ['security-user', 'lock-1'];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _tabLabels.length, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: _tab,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < _tabLabels.length; i++) ...[
                    PillTab(
                      icon: _tabIcons[i],
                      label: _tabLabels[i],
                      selected: _tab.index == i,
                      onTap: () => _tab.animateTo(i),
                    ),
                    if (i < _tabLabels.length - 1) SizedBox(width: PillTab.gap(context)),
                  ],
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: const [
              CustomRolesScreen(),
              _MenuAccessTab(),
            ],
          ),
        ),
      ],
    );
  }
}

// ==================== Tab 2: Menu Access ====================

class _MenuAccessTab extends StatefulWidget {
  const _MenuAccessTab();

  @override
  State<_MenuAccessTab> createState() => _MenuAccessTabState();
}

class _MenuAccessTabState extends State<_MenuAccessTab> {
  List<Map<String, dynamic>> _roles = [];
  Map<int, Set<String>> _access = {};
  int? _urId;
  Set<String> _selected = {};
  bool _loading = true, _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  bool get _isAdminRole {
    final r = _roles.firstWhere((e) => e['ur_id'] == _urId, orElse: () => const {});
    return (r['urname']?.toString().toLowerCase() ?? '') == 'admin';
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        SupabaseService.getUserRoles(_insId),
        SupabaseService.getRoleMenuAccess(_insId),
      ]);
      if (!mounted) return;
      final roles = results[0] as List<Map<String, dynamic>>;
      final access = results[1] as Map<int, Set<String>>;
      setState(() {
        _roles = roles;
        _access = access;
        _loading = false;
      });
      if (roles.isNotEmpty) _pickRole((roles.first['ur_id'] as num).toInt());
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Failed to load. ${friendlyError(e)}', AppColors.error);
    }
  }

  /// Select a role and seed the tick-list. If the role has never been
  /// configured, pre-tick whatever it can see today under the built-in
  /// defaults, so saving is a no-op rather than a surprise revocation.
  void _pickRole(int urId) {
    final role = _roles.firstWhere((r) => r['ur_id'] == urId, orElse: () => const {});
    final roleName = role['urname']?.toString() ?? '';
    final configured = _access[urId];
    setState(() {
      _urId = urId;
      _selected = configured != null
          ? {...configured}
          : {
              for (final i in kAssignableNavItems)
                if (_defaultVisible(i, roleName)) i.label,
            };
    });
  }

  /// Mirrors the sidebar's built-in default visibility for a role name.
  bool _defaultVisible(AppNavItem item, String roleName) {
    final isAdmin = roleName.toLowerCase() == 'admin';
    final isAccountant = roleName.toLowerCase() == 'accountant';
    // Mirror the sidebar: an unconfigured Admin sees everything EXCEPT the
    // accountant-only screens. Pre-ticking those too would make a no-change
    // Save silently grant them.
    if (isAdmin) return !item.accountantOnly;
    if (item.adminOnly) return false;
    if (item.accountantOnly && !isAccountant) return false;
    if (item.hideForAccountant && isAccountant) return false;
    return true;
  }

  Future<void> _save() async {
    if (_urId == null) return;
    setState(() => _saving = true);
    try {
      await SupabaseService.saveRoleMenuAccess(
        insId: _insId,
        urId: _urId!,
        // Belt-and-braces: force the never-revocable menus back in for Admin,
        // so a stale UI state can't persist a lockout.
        allowed: _isAdminRole ? {..._selected, ...kAlwaysAllowedForAdmin} : _selected,
        createdBy: context.read<AuthProvider>().userName,
      );
      if (!mounted) return;
      setState(() {
        _access[_urId!] = {..._selected};
        _saving = false;
      });
      _snack('Menu access saved. Affected users see it next time they log in.', AppColors.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Save failed. ${friendlyError(e)}', AppColors.error);
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c, duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_roles.isEmpty) {
      return Center(child: Text('No roles found. Create one in the Roles tab first.',
          style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)));
    }

    // Group the assignable menus by their sidebar section.
    final sections = <String, List<AppNavItem>>{};
    for (final i in kAssignableNavItems) {
      sections.putIfAbsent(i.section, () => []).add(i);
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(18.w, 14.h, 18.w, 10.h),
            child: Row(children: [
              const AppIcon('lock-1', size: 20, color: AppColors.primary),
              SizedBox(width: 10.w),
              Text('Menu Access', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              SizedBox(width: 10.w),
              Text('choose which menus a role can open', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
              const Spacer(),
              SizedBox(
                width: 220.w,
                child: DropdownButtonFormField<int>(
                  initialValue: _urId,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Select role',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.border)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.border)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.accent)),
                  ),
                  items: _roles
                      .map((r) => DropdownMenuItem(
                            value: (r['ur_id'] as num).toInt(),
                            child: Text(r['urname']?.toString() ?? '', overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) { if (v != null) _pickRole(v); },
                ),
              ),
            ]),
          ),

          if (_isAdminRole)
            Padding(
              padding: EdgeInsets.fromLTRB(18.w, 0, 18.w, 10.h),
              child: Container(
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8.r),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 18.sp, color: AppColors.warning),
                  SizedBox(width: 10.w),
                  Expanded(
                    child: Text(
                      'You can hide menus from the Admin role, but ${kAlwaysAllowedForAdmin.where((m) => m != 'Dashboard').join(' and ')} stay locked on — without them no Admin could undo the change.',
                      style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary),
                    ),
                  ),
                ]),
              ),
            ),

          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(18.w, 0, 18.w, 12.h),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in sections.entries) ...[
                    Padding(
                      padding: EdgeInsets.only(top: 10.h, bottom: 6.h),
                      child: Row(children: [
                        Text(entry.key,
                            style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: AppColors.textLight)),
                        SizedBox(width: 10.w),
                        Expanded(child: Divider(color: AppColors.border, height: 1)),
                        SizedBox(width: 10.w),
                        _sectionToggle(entry.value),
                      ]),
                    ),
                    Wrap(
                      spacing: 8.w,
                      runSpacing: 8.h,
                      children: [for (final i in entry.value) _menuChip(i)],
                    ),
                  ],
                ],
              ),
            ),
          ),

          Padding(
            padding: EdgeInsets.all(14.w),
            child: Row(children: [
              Text(
                '${_selected.length} of ${kAssignableNavItems.length} menus allowed',
                style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save, size: 16),
                label: const Text('Save Access'),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  /// "All / None" toggle for a whole section.
  Widget _sectionToggle(List<AppNavItem> items) {
    final all = items.every((i) => _selected.contains(i.label));
    return InkWell(
      onTap: () => setState(() {
        if (all) {
          // Never clear a locked menu (Admin's Users / Roles & Access).
          _selected.removeAll(items.where((i) => !_isLocked(i)).map((i) => i.label));
        } else {
          _selected.addAll(items.map((i) => i.label));
        }
      }),
      borderRadius: BorderRadius.circular(6.r),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
        child: Text(all ? 'Clear' : 'Select all',
            style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
      ),
    );
  }

  /// Menus that can't be unticked for the current role. Only applies to Admin:
  /// revoking these would leave nobody able to re-open Roles & Access.
  bool _isLocked(AppNavItem item) =>
      _isAdminRole && kAlwaysAllowedForAdmin.contains(item.label);

  Widget _menuChip(AppNavItem item) {
    final on = _selected.contains(item.label);
    final locked = _isLocked(item);
    return InkWell(
      onTap: locked
          ? () => _snack('${item.label} must stay enabled for Admin — otherwise no one could undo it.', AppColors.warning)
          : () => setState(() => on ? _selected.remove(item.label) : _selected.add(item.label)),
      borderRadius: BorderRadius.circular(8.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
        decoration: BoxDecoration(
          color: on ? AppColors.primary.withValues(alpha: 0.08) : Colors.white,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: on ? AppColors.primary : AppColors.border, width: on ? 1.4 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(locked ? Icons.lock : (on ? Icons.check_box : Icons.check_box_outline_blank),
              size: 17.sp, color: on ? AppColors.primary : AppColors.textLight),
          SizedBox(width: 8.w),
          AppIcon(item.icon, size: 15.sp, color: on ? AppColors.primary : AppColors.textSecondary),
          SizedBox(width: 6.w),
          Text(item.label,
              style: TextStyle(fontSize: 12.5.sp, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? AppColors.textPrimary : AppColors.textSecondary)),
        ]),
      ),
    );
  }
}
