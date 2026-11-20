import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../services/supabase_service.dart';
import '../../utils/app_menu.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../utils/module_control.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';

/// Module Control -- for the software vendor, not the client. Opened from the
/// sign-in screen with Ctrl+Shift+M and unlocked with the vendor password
/// (checked by the database; set once per client database at installation).
/// Switches modules, or single menus in them, on and off per institution: a
/// switched-off menu disappears for every user there, Admin and the client's
/// Super Admin included. Dashboard, Users and Roles & Access are always on.
class ModuleControlScreen extends StatefulWidget {
  const ModuleControlScreen({super.key});
  @override
  State<ModuleControlScreen> createState() => _ModuleControlScreenState();
}

class _ModuleControlScreenState extends State<ModuleControlScreen> {
  // gate
  bool _checking = true, _hasPassword = false, _busy = false;
  String? _pass; // the vendor password, once accepted (kept in memory only)
  final _passCtl = TextEditingController(), _newCtl = TextEditingController(), _confirmCtl = TextEditingController();
  String? _gateError;

  // control
  bool _loading = true, _loadingIns = false, _saving = false;
  bool _school = true;
  List<Map<String, dynamic>> _institutions = [];
  String _query = '';
  int? _insId;
  Set<String> _saved = {};
  Set<String> _off = {};
  final Set<String> _open = {};

  bool get _dirty => _off.length != _saved.length || !_off.containsAll(_saved);

  @override
  void initState() {
    super.initState();
    _checkGate();
  }

  @override
  void dispose() {
    _passCtl.dispose();
    _newCtl.dispose();
    _confirmCtl.dispose();
    super.dispose();
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<void> _checkGate() async {
    try {
      final set = await VendorModules.passwordIsSet();
      if (mounted) setState(() => _hasPassword = set);
    } catch (e) {
      if (mounted) setState(() => _gateError = 'Module Control is not installed on this database. ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _unlock() async {
    final p = _passCtl.text;
    if (p.isEmpty) return;
    setState(() {
      _busy = true;
      _gateError = null;
    });
    try {
      if (await VendorModules.check(p)) {
        _pass = p;
        _passCtl.clear();
        await _load();
      } else if (mounted) {
        setState(() => _gateError = 'Wrong vendor password.');
      }
    } catch (e) {
      if (mounted) setState(() => _gateError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// First time on this database: the vendor sets the password.
  Future<void> _setFirstPassword() async {
    final n = _newCtl.text, c = _confirmCtl.text;
    if (n.length < 6) return setState(() => _gateError = 'Use at least 6 characters.');
    if (n != c) return setState(() => _gateError = 'The two passwords do not match.');
    setState(() {
      _busy = true;
      _gateError = null;
    });
    try {
      await VendorModules.setPassword(null, n);
      _pass = n;
      _newCtl.clear();
      _confirmCtl.clear();
      _hasPassword = true;
      await _load();
    } catch (e) {
      if (mounted) setState(() => _gateError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Vendor Password'),
        content: SizedBox(
          width: 380.w,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _newCtl, obscureText: true, decoration: AppUI.field(ctx, 'New password (at least 6 characters)')),
            SizedBox(height: 10.h),
            TextField(controller: _confirmCtl, obscureText: true, decoration: AppUI.field(ctx, 'Re-enter new password')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Change')),
        ],
      ),
    );
    final n = _newCtl.text, c = _confirmCtl.text;
    _newCtl.clear();
    _confirmCtl.clear();
    if (ok != true) return;
    if (n.length < 6 || n != c) {
      return _snack(n.length < 6 ? 'Use at least 6 characters.' : 'The two passwords do not match.', AppColors.warning);
    }
    try {
      await VendorModules.setPassword(_pass, n);
      _pass = n;
      _snack('Vendor password changed.', AppColors.success);
    } catch (e) {
      _snack('Could not change the password. ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // A school database keeps fee types in public; a college one per
      // institution schema. Decides which menus exist here.
      // Only "no such table" means college. Before sign-in the school
      // database refuses the read itself ("no valid session"), and taking
      // that for "college" listed the college menus and left out Transport
      // and every school-only menu (2026-11-13).
      final school = await SupabaseService.client.from('feetype').select('fee_id').limit(1).then((_) => true,
          onError: (e) => !(e is PostgrestException && (e.code == 'PGRST205' || e.code == '42P01')));
      final rows = await SupabaseService.client
          .from('institution')
          .select('ins_id, insname, inscode, inscity, activestatus')
          .order('insname');
      if (!mounted) return;
      setState(() {
        _school = school;
        _institutions = List<Map<String, dynamic>>.from(rows as List);
        _loading = false;
      });
      if (_institutions.isNotEmpty) await _pick((_institutions.first['ins_id'] as num).toInt());
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _snack('Could not load the institutions. ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<void> _pick(int insId) async {
    if (_dirty && _insId != null && insId != _insId) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard changes?'),
          content: const Text('The module changes for this institution are not saved yet.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Editing')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
          ],
        ),
      );
      if (discard != true) return;
    }
    setState(() {
      _insId = insId;
      _loadingIns = true;
    });
    final off = await loadDisabledMenus(insId);
    if (!mounted || _insId != insId) return;
    setState(() {
      _saved = off;
      _off = {...off};
      _open.clear();
      _loadingIns = false;
    });
  }

  Future<void> _save() async {
    final insId = _insId, pass = _pass;
    if (insId == null || pass == null) return;
    setState(() => _saving = true);
    try {
      await VendorModules.save(pass, insId, _off, school: _school);
      if (!mounted) return;
      setState(() => _saved = {..._off});
      _snack('Modules saved. The institution sees the change the next time its menu loads (sign in or Refresh).', AppColors.success);
    } catch (e) {
      _snack('Could not save the modules. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(20.w),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Back'),
              ),
              SizedBox(width: 16.w),
              Expanded(child: Text('Module Control', style: AppFonts.heading(size: 26))),
              if (_pass != null)
                OutlinedButton.icon(
                  onPressed: _changePassword,
                  icon: const Icon(Icons.key, size: 16),
                  label: const Text('Change Vendor Password'),
                ),
            ]),
            SizedBox(height: 16.h),
            Expanded(child: _pass == null ? _gate() : _control()),
          ]),
        ),
      ),
    );
  }

  // ── gate ──────────────────────────────────────────────────────────────────
  Widget _gate() {
    if (_checking) return const Center(child: CircularProgressIndicator());
    final first = !_hasPassword;
    return Center(
      child: Container(
        width: 460.w,
        padding: EdgeInsets.all(AppUI.cardPad),
        decoration: AppUI.card(),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppUI.cardHeader(
            icon: 'lock',
            title: first ? 'Set the Vendor Password' : 'Vendor Password',
            subtitle: first
                ? 'First use on this database. Only your company should know it: it controls which modules this client gets.'
                : 'For the software vendor only.',
          ),
          SizedBox(height: 16.h),
          if (first) ...[
            TextField(controller: _newCtl, obscureText: true, autofocus: true, decoration: AppUI.field(context, 'New password (at least 6 characters)')),
            SizedBox(height: 10.h),
            TextField(
              controller: _confirmCtl,
              obscureText: true,
              decoration: AppUI.field(context, 'Re-enter password'),
              onSubmitted: (_) => _busy ? null : _setFirstPassword(),
            ),
          ] else
            TextField(
              controller: _passCtl,
              obscureText: true,
              autofocus: true,
              decoration: AppUI.field(context, 'Enter the vendor password'),
              onSubmitted: (_) => _busy ? null : _unlock(),
            ),
          if (_gateError != null) ...[
            SizedBox(height: 10.h),
            Text(_gateError!, style: AppUI.muted.copyWith(color: AppColors.error)),
          ],
          SizedBox(height: 16.h),
          ElevatedButton(
            onPressed: _busy || _gateError?.startsWith('Module Control is not installed') == true
                ? null
                : (first ? _setFirstPassword : _unlock),
            child: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(first ? 'Set Password' : 'Unlock'),
          ),
        ]),
      ),
    );
  }

  // ── control ───────────────────────────────────────────────────────────────
  Widget _control() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: 380.w, child: _institutionList()),
      SizedBox(width: AppUI.gap),
      Expanded(child: _modules()),
    ]);
  }

  Widget _institutionList() {
    final q = _query.trim().toLowerCase();
    final list = _institutions.where((r) {
      if (q.isEmpty) return true;
      return '${r['insname'] ?? ''} ${r['inscode'] ?? ''} ${r['inscity'] ?? ''}'.toLowerCase().contains(q);
    }).toList();
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(icon: 'buildings-2', title: 'Institutions', subtitle: 'Pick one to set its modules'),
        SizedBox(height: 14.h),
        TextField(
          style: AppUI.fieldText(context),
          decoration: AppUI.field(context, 'Search by name, code or city', leadingIcon: 'search-normal'),
          onChanged: (v) => setState(() => _query = v),
        ),
        SizedBox(height: 10.h),
        Expanded(
          child: list.isEmpty
              ? AppUI.empty(title: 'No institutions found', icon: 'buildings-2')
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => SizedBox(height: 6.h),
                  itemBuilder: (_, i) {
                    final r = list[i];
                    final id = (r['ins_id'] as num).toInt();
                    final on = id == _insId;
                    final active = (r['activestatus'] as num?)?.toInt() == 1;
                    return InkWell(
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                      onTap: () => _pick(id),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                        decoration: BoxDecoration(
                          color: on ? AppColors.primarySoft : Colors.white,
                          borderRadius: BorderRadius.circular(AppUI.controlRadius),
                          border: Border.all(color: on ? AppColors.primary : AppColors.border),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${r['insname'] ?? ''}', style: AppUI.label, overflow: TextOverflow.ellipsis),
                              Text(
                                [r['inscode'], r['inscity']].where((x) => '${x ?? ''}'.trim().isNotEmpty).join(' · '),
                                style: AppUI.muted,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ]),
                          ),
                          if (!active) AppUI.chip('Inactive', AppStatus.neutral),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  Widget _modules() {
    final ins = _institutions.where((r) => r['ins_id'] == _insId).firstOrNull;
    final groups = switchableMenus(school: _school);
    final offCount = _off.length;
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'element-3',
          title: ins == null ? 'Modules' : 'Modules · ${ins['insname'] ?? ''}',
          subtitle: 'Switched-off modules and menus disappear for every user of this institution, Admin and Super Admin '
              'included. Dashboard, Users and Roles & Access are always on.',
          trailing: [
            if (_insId != null && !_loadingIns)
              AppUI.chip(offCount == 0 ? 'All on' : '$offCount menu(s) off', offCount == 0 ? AppStatus.success : AppStatus.warning),
          ],
        ),
        SizedBox(height: 14.h),
        Expanded(
          child: _insId == null
              ? AppUI.empty(title: 'No institution selected', why: 'Pick an institution on the left.', icon: 'buildings-2')
              : _loadingIns
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(children: [for (final e in groups.entries) _moduleTile(e.key, e.value)]),
        ),
        SizedBox(height: 12.h),
        Row(children: [
          Expanded(child: Text(_dirty ? 'Changes not saved yet.' : '', style: AppUI.muted.copyWith(color: AppColors.warning))),
          OutlinedButton(
            onPressed: _dirty && !_saving ? () => setState(() => _off = {..._saved}) : null,
            child: const Text('Undo Changes'),
          ),
          SizedBox(width: 10.w),
          ElevatedButton.icon(
            onPressed: _dirty && !_saving ? _save : null,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: const Text('Save'),
          ),
        ]),
      ]),
    );
  }

  Widget _moduleTile(String section, List<AppNavItem> items) {
    final meta = kSectionMeta[section] ?? ['element-3', section];
    // Always-on menus (Users, Roles & Access) do not count: "off" means every
    // menu that CAN be switched off is.
    final free = items.where((i) => !kAlwaysOnMenus.contains(i.label)).toList();
    final onCount = items.where((i) => !_off.contains(i.label)).length;
    final allOn = onCount == items.length, allOff = free.every((i) => _off.contains(i.label));
    final open = _open.contains(section);
    return Container(
      margin: EdgeInsets.only(bottom: 10.h),
      decoration: BoxDecoration(
        color: allOff ? AppColors.surface : Colors.white,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          onTap: () => setState(() => open ? _open.remove(section) : _open.add(section)),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
            child: Row(children: [
              AppUI.iconTile(meta[0], color: allOff ? AppColors.textLight : AppColors.primary),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(kModuleOfSection[section]?.$2 ?? meta[1],
                      style: AppUI.label.copyWith(color: allOff ? AppColors.textSecondary : AppColors.textPrimary)),
                  Text(
                      allOn
                          ? 'All ${items.length} menus on'
                          : (allOff
                              ? (free.length < items.length ? 'Switched off (except ${kAlwaysOnMenus.join(' and ')})' : 'Switched off')
                              : '$onCount of ${items.length} menus on'),
                      style: AppUI.muted),
                ]),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more, color: AppColors.textSecondary),
              SizedBox(width: 8.w),
              Tooltip(
                message: allOff ? 'Switch the whole module on' : 'Switch the whole module off',
                child: Switch(
                  value: !allOff,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() {
                            for (final i in free) {
                              v ? _off.remove(i.label) : _off.add(i.label);
                            }
                          }),
                ),
              ),
            ]),
          ),
        ),
        if (open)
          Padding(
            padding: EdgeInsets.fromLTRB(60.w, 0, 14.w, 10.h),
            child: Column(children: [
              for (final i in items)
                Row(children: [
                  AppIcon(i.icon, size: 16, color: _off.contains(i.label) ? AppColors.textLight : AppColors.primary),
                  SizedBox(width: 10.w),
                  Expanded(
                    child: Text(i.title ?? i.label,
                        style: AppUI.body.copyWith(color: _off.contains(i.label) ? AppColors.textSecondary : AppColors.textPrimary)),
                  ),
                  if (kAlwaysOnMenus.contains(i.label))
                    Tooltip(
                      message: 'Always on: the school must be able to manage its own logins.',
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('Always on', style: AppUI.muted),
                        const Switch(value: true, onChanged: null),
                      ]),
                    )
                  else
                    Switch(
                      value: !_off.contains(i.label),
                      onChanged: _saving ? null : (v) => setState(() => v ? _off.remove(i.label) : _off.add(i.label)),
                    ),
                ]),
            ]),
          ),
      ]),
    );
  }
}
