import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/app_menu.dart';
import '../../utils/module_control.dart';
import '../../utils/dashboard_tiles.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/pill_tab.dart';
import '../../widgets/app_ui.dart';
import 'custom_roles_screen.dart';
import '../../widgets/app_dropdown_field.dart';

/// Roles & Access — Admin-only. Two tabs:
///   * Roles       — create/rename the institution's roles (custuserroles).
///   * Menu Access — tick which sidebar menus each role may see, and which
///     dashboard cards and charts it may see on the landing page.
///
/// Menu grants are stored per role in public.rolemenuaccess. A role with no
/// rows has never been configured and keeps the app's built-in defaults, so
/// this screen is additive — nothing changes until an Admin saves something.
///
/// Dashboard tiles share that table, prefixed (see utils/dashboard_tiles.dart)
/// so a tile key can never be read as a menu label. Saving also writes
/// kDashboardConfiguredMarker: without it, a role with every tile unticked
/// would look unconfigured and be shown the whole dashboard.
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
            child: // Wrap, not a horizontal scroll view: the row can run past the
              // window on a laptop screen, and a horizontal
              // SingleChildScrollView has no scrollbar and ignores the mouse
              // wheel on desktop, leaving the last tabs unreachable.
              Wrap(
                spacing: PillTab.gap(context),
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _tabLabels.length; i++)
                    PillTab(
                      icon: _tabIcons[i],
                      label: _tabLabels[i],
                      selected: _tab.index == i,
                      onTap: () => _tab.animateTo(i),
                    ),
                ],
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
  /// Menus switched off for this institution by the vendor (Module
  /// Control): not offered here. A grant already saved for one is kept, so
  /// switching the module back on restores it.
  Set<String> _disabled = {};
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
        loadDisabledMenus(_insId),
      ]);
      if (!mounted) return;
      final roles = results[0] as List<Map<String, dynamic>>;
      final access = results[1] as Map<int, Set<String>>;
      setState(() {
        _roles = roles;
        _access = access;
        _disabled = results[2] as Set<String>;
        _loading = false;
      });
      if (roles.isNotEmpty) _pickRole((roles.first['ur_id'] as num).toInt());
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load roles and menu access. ${friendlyError(e)}', AppColors.error);
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
      // A role nobody has configured keeps the built-in menu defaults and the
      // whole dashboard -- no marker, so every tile reads as allowed.
      _selected = configured != null
          ? {...configured}
          : {
              for (final i in kAssignableNavItems)
                if (_defaultVisible(i, roleName)) i.label,
              ...kAllDashboardTiles.map((d) => d.key),
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
        // The marker says the dashboard HAS been configured, so unticking
        // every tile means an empty dashboard rather than a default one.
        allowed: {
          ...(_isAdminRole ? {..._selected, ...kAlwaysAllowedForAdmin} : _selected),
          kDashboardConfiguredMarker,
        },
        createdBy: context.read<AuthProvider>().userName,
      );
      if (!mounted) return;
      setState(() {
        _access[_urId!] = {..._selected, kDashboardConfiguredMarker};
        _saving = false;
      });
      _snack('Menu access saved. Affected users see it next time they log in.', AppColors.success);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Could not save menu access. ${friendlyError(e)}', AppColors.error);
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
      return AppUI.empty(
        title: 'No roles found. Create one in the Roles tab first.',
        why: 'Menu access is set per role, and this institution has none yet.',
        icon: 'security-user',
      );
    }

    // Group the assignable menus by their sidebar section.
    final sections = <String, List<AppNavItem>>{};
    for (final i in kAssignableNavItems.where((i) => !_disabled.contains(i.label))) {
      sections.putIfAbsent(i.section, () => []).add(i);
    }

    return Container(
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, AppUI.cardPad, 12.h),
            child: AppUI.cardHeader(
              icon: 'lock-1',
              title: 'Menu Access',
              subtitle: 'Choose which menus a role can open',
              trailing: [
              SizedBox(
                width: 220.w,
                child: AppDropdownField<int>(
                  initialValue: _urId,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: AppUI.fieldText(context),
                  decoration: AppUI.field(context, 'Select role', filled: _urId != null),
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
              padding: EdgeInsets.fromLTRB(AppUI.cardPad, 0, AppUI.cardPad, 12.h),
              child: Container(
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  color: AppColors.warningBg,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 18.sp, color: AppColors.warning),
                  SizedBox(width: 10.w),
                  Expanded(
                    child: Text(
                      'You can hide menus from the Admin role, but ${kAlwaysAllowedForAdmin.join(' and ')} stay locked on — without them no Admin could undo the change.',
                      style: AppUI.muted.copyWith(color: AppColors.warning),
                    ),
                  ),
                ]),
              ),
            ),

          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(AppUI.cardPad, 0, AppUI.cardPad, 12.h),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in sections.entries)
                    // The Dashboard menu and the cards / panels it shows are
                    // one decision, so they share one card (user, 2026-11-13).
                    if (entry.value.any((i) => i.label == 'Dashboard'))
                      _dashboardCard(entry.value)
                    else
                      _accessCard(
                        name: entry.key,
                        icon: kSectionMeta[entry.key]?[0] ?? 'element-3',
                        tint: _sectionTint(entry.key),
                        granted: entry.value
                            .where((i) => _selected.contains(i.label))
                            .length,
                        total: entry.value.length,
                        toggle: _sectionToggle(entry.value),
                        children: [for (final i in entry.value) _menuChip(i)],
                      ),
                ],
              ),
            ),
          ),

          Padding(
            padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 14.h),
            child: Row(children: [
              _countPill('MENUS', _menuCount, kAssignableNavItems.length,
                  AppColors.primary),
              SizedBox(width: 10.w),
              _countPill('DASHBOARD TILES', _tileCount,
                  kAllDashboardTiles.length, AppColors.demand),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save, size: 16),
                label: const Text('Save Access'),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  /// "12 of 39 MENUS" as a pill: the two counts used to be one grey sentence,
  /// and the number that matters -- how much this role can reach -- was the
  /// hardest thing on the screen to find.
  Widget _countPill(String label, int n, int total, Color tint) => Container(
        padding: EdgeInsets.symmetric(horizontal: 11.w, vertical: 6.h),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$n',
              style: TextStyle(
                  fontSize: 13.sp, fontWeight: FontWeight.w800, color: tint)),
          Text(' / $total  ',
              style: AppUI.muted),
          Text(label, style: AppUI.caps),
        ]),
      );

  /// A colour per section, so a long grant list is scanned by shape rather
  /// than read line by line -- and so a section is recognisable here by the
  /// same hue it carries in the sidebar family it belongs to.
  Color _sectionTint(String section) => switch (section) {
        'ADMISSION' => AppColors.accent,
        'STUDENTS' => AppColors.success,
        'TC' => AppColors.demand,
        'FEES' => AppColors.warning,
        'REPORTS' => AppColors.demand,
        'BANKING' => AppColors.today,
        'SETUP' => AppColors.primaryDark,
        'GENERAL' => AppColors.info,
        _ => AppColors.primary,
      };

  /// One section of grants: its own card, its own colour, and a count of what
  /// is granted out of what exists. The count is the thing an administrator
  /// actually checks -- it used to be a bare heading over a run of chips.
  Widget _accessCard({
    required String name,
    required String icon,
    required Color tint,
    required int granted,
    required int total,
    required Widget toggle,
    required List<Widget> children,
  }) {
    final all = granted == total;
    final none = granted == 0;
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 12.h),
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: EdgeInsets.fromLTRB(16.w, 10.h, 16.w, 10.h),
          decoration: const BoxDecoration(
            color: AppColors.tableHeadBg,
            border: Border(bottom: BorderSide(color: AppColors.divider)),
          ),
          child: Row(children: [
            AppUI.iconTile(icon, color: tint, size: 14),
            SizedBox(width: 10.w),
            Text(name, style: AppUI.caps.copyWith(color: AppColors.textPrimary)),
            SizedBox(width: 9.w),
            AppUI.chip('$granted/$total',
                all ? AppStatus.success : (none ? AppStatus.neutral : AppStatus.info)),
            const Spacer(),
            toggle,
          ]),
        ),
        Padding(
          padding: EdgeInsets.all(16.w),
          child: Wrap(spacing: 8.w, runSpacing: 8.h, children: children),
        ),
      ]),
    );
  }

  /// DASHBOARD: the Dashboard menu, then its cards and its charts & panels
  /// under small headings -- one card, one Select All / Clear.
  Widget _dashboardCard(List<AppNavItem> items) {
    final tiles = [for (final t in kDashboardTileSections.values) ...t];
    Widget heading(String t) => SizedBox(
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.only(top: 6.h),
            child: Text(t, style: AppUI.caps.copyWith(color: AppColors.textSecondary)),
          ),
        );
    return _accessCard(
      name: 'DASHBOARD',
      icon: 'element-3',
      tint: AppColors.demand,
      granted: items.where((i) => _selected.contains(i.label)).length +
          tiles.where((d) => _selected.contains(d.key)).length,
      total: items.length + tiles.length,
      toggle: _sectionToggle(items, tiles: tiles),
      children: [
        for (final i in items) _menuChip(i),
        for (final sec in kDashboardTileSections.entries) ...[
          heading(sec.key.replaceFirst('DASHBOARD · ', '')),
          for (final d in sec.value) _tileChip(d),
        ],
      ],
    );
  }

  /// "All / None" toggle for a whole section ([tiles]: the Dashboard's
  /// cards and panels, toggled with it).
  Widget _sectionToggle(List<AppNavItem> items, {List<DashboardTile> tiles = const []}) {
    final all = items.every((i) => _selected.contains(i.label)) && tiles.every((d) => _selected.contains(d.key));
    return InkWell(
      onTap: () => setState(() {
        if (all) {
          // Never clear a locked menu (Admin's Users / Roles & Access).
          _selected.removeAll(items.where((i) => !_isLocked(i)).map((i) => i.label));
          _selected.removeAll(tiles.map((d) => d.key));
        } else {
          _selected.addAll(items.map((i) => i.label));
          _selected.addAll(tiles.map((d) => d.key));
        }
      }),
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 5.h),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(all ? Icons.remove_done : Icons.done_all,
              size: 13.sp, color: AppColors.primary),
          SizedBox(width: 5.w),
          Text(all ? 'Clear' : 'Select All',
              style: AppUI.label.copyWith(fontSize: 12.sp, color: AppColors.primary)),
        ]),
      ),
    );
  }

  /// Menus that can't be unticked for the current role. Only applies to Admin:
  /// revoking these would leave nobody able to re-open Roles & Access.
  bool _isLocked(AppNavItem item) =>
      _isAdminRole && kAlwaysAllowedForAdmin.contains(item.label);

  /// Menu grants only -- the tile keys share _selected but are counted apart,
  /// so "12 of 37 menus" does not silently include dashboard tiles.
  int get _menuCount =>
      kAssignableNavItems.where((i) => _selected.contains(i.label)).length;

  int get _tileCount =>
      kAllDashboardTiles.where((d) => _selected.contains(d.key)).length;

  /// One dashboard card or panel. Nothing here is ever locked: hiding every
  /// tile leaves the dashboard empty but still reachable, and Menu Access
  /// itself is what an Admin needs to undo it.
  Widget _tileChip(DashboardTile tile) {
    final on = _selected.contains(tile.key);
    return InkWell(
      onTap: () => setState(() => on ? _selected.remove(tile.key) : _selected.add(tile.key)),
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
        decoration: BoxDecoration(
          color: on ? AppColors.primaryLight : Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: on ? AppColors.primary : AppColors.border, width: on ? 1.4 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(on ? Icons.check_box : Icons.check_box_outline_blank,
              size: 17.sp, color: on ? AppColors.primary : AppColors.textLight),
          SizedBox(width: 8.w),
          AppIcon(tile.icon, size: 15.sp, color: on ? AppColors.primary : AppColors.textSecondary),
          SizedBox(width: 8.w),
          Text(tile.label,
              style: AppUI.body.copyWith(
                  fontSize: 13.sp,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  color: on ? AppColors.primary : AppColors.textPrimary)),
        ]),
      ),
    );
  }

  Widget _menuChip(AppNavItem item) {
    final on = _selected.contains(item.label);
    final locked = _isLocked(item);
    return InkWell(
      onTap: locked
          ? () => _snack('${item.navTitle} must stay enabled for Admin — otherwise no one could undo it.', AppColors.warning)
          : () => setState(() => on ? _selected.remove(item.label) : _selected.add(item.label)),
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
        decoration: BoxDecoration(
          color: on ? AppColors.primaryLight : Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: on ? AppColors.primary : AppColors.border, width: on ? 1.4 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(locked ? Icons.lock : (on ? Icons.check_box : Icons.check_box_outline_blank),
              size: 17.sp, color: on ? AppColors.primary : AppColors.textLight),
          SizedBox(width: 8.w),
          AppIcon(item.icon, size: 15.sp, color: on ? AppColors.primary : AppColors.textSecondary),
          SizedBox(width: 6.w),
          Text(item.navTitle,
              style: AppUI.body.copyWith(fontSize: 13.sp, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: on ? AppColors.textPrimary : AppColors.textSecondary)),
        ]),
      ),
    );
  }
}
