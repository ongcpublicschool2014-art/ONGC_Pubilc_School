import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/master_crud_panel.dart';
import '../../widgets/pill_tab.dart';
import '../admission/admission_master_screen.dart' show TermPanel;
import 'master_import_screen.dart';

/// Master Data — three tabs: Standard, Section, Term Period.
/// Each tab offers inline add/edit/list plus an "Import CSV/Excel" toggle that
/// switches to the bulk import flow (reuses MasterImportScreen).
class MasterDataScreen extends StatefulWidget {
  const MasterDataScreen({super.key});

  @override
  State<MasterDataScreen> createState() => _MasterDataScreenState();
}

class _MasterDataScreenState extends State<MasterDataScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _tabLabels = ['Standard', 'Section', 'Term Period'];
  static const _tabIcons = ['book-1', 'category', 'calendar-1'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabLabels.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pill-style tabs matching Fee Master / Reports / Dashboard.
        ListenableBuilder(
          listenable: _tabController,
          builder: (context, _) {
            final selected = _tabController.index;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < _tabLabels.length; i++) ...[
                      PillTab(
                        icon: _tabIcons[i],
                        label: _tabLabels[i],
                        selected: selected == i,
                        onTap: () => _tabController.animateTo(i),
                      ),
                      if (i < _tabLabels.length - 1)
                        SizedBox(width: PillTab.gap(context)),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
        SizedBox(height: 6.h),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _PanelWithImport(
                importTabIndex: 0,
                title: 'Standard',
                childBuilder: (onImport) => MasterCrudPanel(
                  table: 'clagrp',
                  idCol: 'cgrp_id',
                  nameCol: 'clagrpname',
                  title: 'Standard',
                  icon: 'book-1',
                  ordidCol: 'ordid',
                  onImport: onImport,
                ),
              ),
              _PanelWithImport(
                importTabIndex: 1,
                title: 'Section',
                childBuilder: (onImport) => _SectionCrudPanel(onImport: onImport),
              ),
              const TermPanel(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Section CRUD — name plus parent Standard (public.class.cgrp_id).
class _SectionCrudPanel extends StatefulWidget {
  final VoidCallback? onImport;
  const _SectionCrudPanel({this.onImport});
  @override
  State<_SectionCrudPanel> createState() => _SectionCrudPanelState();
}

class _SectionCrudPanelState extends State<_SectionCrudPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _standards = [];
  Map<int, String> _stdName = {};
  String? _cgrpId;
  int? _editId;
  bool _loading = true, _saving = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        SupabaseService.client.from('clagrp').select('cgrp_id, clagrpname, ordid').eq('ins_id', _insId).eq('activestatus', 1).order('ordid', ascending: true).order('clagrpname', ascending: true),
        SupabaseService.client.from('class').select('*').eq('ins_id', _insId).eq('activestatus', 1).order('ordid', ascending: true).order('claname', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _standards = List<Map<String, dynamic>>.from(results[0] as List);
        _stdName = {for (final s in _standards) s['cgrp_id'] as int: s['clagrpname']?.toString() ?? ''};
        _rows = List<Map<String, dynamic>>.from(results[1] as List);
        _cgrpId ??= _standards.isNotEmpty ? _standards.first['cgrp_id'].toString() : null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['cla_id'] is int ? r['cla_id'] as int : int.tryParse(r['cla_id'].toString());
      _name.text = r['claname']?.toString() ?? '';
      _cgrpId = r['cgrp_id']?.toString();
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
      _cgrpId = _standards.isNotEmpty ? _standards.first['cgrp_id'].toString() : null;
    });
  }

  Future<int> _nextId() async {
    final res = await SupabaseService.client.from('class').select('cla_id').order('cla_id', ascending: false).limit(1).maybeSingle();
    final cur = res?['cla_id'];
    final n = cur is int ? cur : int.tryParse(cur?.toString() ?? '0') ?? 0;
    return n + 1;
  }

  Future<int> _nextOrdid() async {
    final res = await SupabaseService.client.from('class').select('ordid').order('ordid', ascending: false).limit(1).maybeSingle();
    final cur = res?['ordid'];
    final n = cur is int ? cur : int.tryParse(cur?.toString() ?? '0') ?? 0;
    return n + 1;
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack('Enter a section name.', AppColors.warning);
    if (_cgrpId == null) return _snack('Pick a Standard.', AppColors.warning);
    setState(() => _saving = true);
    try {
      if (_editId != null) {
        await SupabaseService.client.from('class').update({
          'claname': name,
          'cgrp_id': int.tryParse(_cgrpId!),
        }).eq('cla_id', _editId!);
        _snack('Section updated.', AppColors.success);
      } else {
        await SupabaseService.client.from('class').insert({
          'cla_id': await _nextId(),
          'claname': name,
          'cgrp_id': int.tryParse(_cgrpId!),
          'ordid': await _nextOrdid(),
          'ins_id': _insId,
          'activestatus': 1,
        });
        _snack('Section added.', AppColors.success);
      }
      _name.clear();
      _editId = null;
      await _load();
    } catch (e) {
      _snack('Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Section'),
        content: const Text('Remove this section?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await SupabaseService.client.from('class').update({'activestatus': 0}).eq('cla_id', id);
      await _load();
    } catch (e) {
      _snack('Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  /// Filled input decoration matching the User Creation form style — bold
  /// label rendered above (handled separately), placeholder hint inside.
  InputDecoration _filledFieldDec(String hint) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final textSize = compact ? 11.0 : 14.0;
    final hPad = compact ? 8.0 : 14.0;
    final vPad = compact ? 5.0 : 14.0;
    final radius = compact ? 5.0 : 8.0;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: textSize),
      contentPadding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.accent)),
      filled: true,
      fillColor: Colors.white,
    );
  }

  TextStyle _h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
  TextStyle _c() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          SizedBox(
            width: 320.w,
            child: Container(
              padding: EdgeInsets.all(20.w),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    const AppIcon('category', size: 18, color: AppColors.accent),
                    SizedBox(width: 8.w),
                    Text(_editId != null ? 'Edit Section' : 'Add Section',
                        style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
                  ]),
                  SizedBox(height: 20.h),
                  Text('Section Name *', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black)),
                  SizedBox(height: 6.h),
                  TextField(controller: _name, style: TextStyle(fontSize: 13.sp), decoration: _filledFieldDec('Enter section name')),
                  SizedBox(height: 16.h),
                  Text('Standard *', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black)),
                  SizedBox(height: 6.h),
                  Builder(builder: (_) {
                    final seen = <String>{};
                    final unique = <Map<String, dynamic>>[];
                    for (final s in _standards) {
                      final id = s['cgrp_id']?.toString() ?? '';
                      if (id.isEmpty || !seen.add(id)) continue;
                      unique.add(s);
                    }
                    final selected = seen.contains(_cgrpId) ? _cgrpId : null;
                    return DropdownButtonFormField<String>(
                      initialValue: selected,
                      isExpanded: true,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                      decoration: _filledFieldDec('Select standard'),
                      items: unique.map((s) => DropdownMenuItem(value: s['cgrp_id'].toString(), child: Text(s['clagrpname']?.toString() ?? '', overflow: TextOverflow.ellipsis))).toList(),
                      onChanged: (v) => setState(() => _cgrpId = v),
                    );
                  }),
                  SizedBox(height: 18.h),
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: Icon(_editId != null ? Icons.save : Icons.add, size: 16),
                        label: Text(_editId != null ? 'Update' : 'Add'),
                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
                      ),
                    ),
                    if (_editId != null) ...[
                      SizedBox(width: 8.w),
                      OutlinedButton(onPressed: _saving ? null : _cancelEdit, child: const Text('Cancel')),
                    ],
                  ]),
                ],
              ),
            ),
          ),
          SizedBox(width: 16.w),
          Expanded(
            child: Container(
              padding: EdgeInsets.all(16.w),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.only(left: 4.w, right: 4.w, bottom: 10.h),
                    child: Row(children: [
                      const AppIcon('category', size: 18, color: AppColors.accent),
                      SizedBox(width: 8.w),
                      Text('Sections',
                          style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
                      SizedBox(width: 8.w),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8.r),
                        ),
                        child: Text('${_rows.length} sections',
                            style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
                      ),
                      const Spacer(),
                      if (widget.onImport != null) _importButton(widget.onImport!),
                    ]),
                  ),
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(children: [
                  Container(
                    color: AppColors.tableHeadBg,
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    child: Row(children: [
                      SizedBox(width: 50.w, child: Text('S NO.', style: _h())),
                      Expanded(flex: 2, child: Text('SECTION', style: _h())),
                      Expanded(flex: 2, child: Text('STANDARD', style: _h())),
                      SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
                    ]),
                  ),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _rows.isEmpty
                            ? Center(child: Text('No sections', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                            : ListView.separated(
                                itemCount: _rows.length,
                                separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
                                itemBuilder: (_, i) {
                                  final r = _rows[i];
                                  final id = r['cla_id'] is int ? r['cla_id'] as int : int.tryParse(r['cla_id'].toString()) ?? 0;
                                  final stdName = _stdName[r['cgrp_id']] ?? '';
                                  return Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                                    child: Row(children: [
                                      SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                                      Expanded(flex: 2, child: Text(r['claname']?.toString() ?? '', style: _c())),
                                      Expanded(flex: 2, child: Text(stdName, style: _c())),
                                      SizedBox(width: 90.w, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                        InkWell(onTap: () => _edit(r), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('edit-2', size: 16, color: AppColors.primary))),
                                        SizedBox(width: 8.w),
                                        InkWell(onTap: () => _delete(id), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 16, color: AppColors.error))),
                                      ])),
                                    ]),
                                  );
                                },
                              ),
                  ),
                ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
    );
  }

  Widget _importButton(VoidCallback onTap) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final btnHeight = compact ? 30.0 : 40.0;
    final iconSize = compact ? 12.0 : 16.0;
    final hPad = compact ? 10.0 : 18.0;
    final radius = compact ? 6.0 : 10.0;
    final textSize = compact ? 11.0 : 13.0;
    return SizedBox(
      height: btnHeight,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: AppIcon('document-upload', size: iconSize, color: Colors.white),
        label: const Text('Import CSV/Excel'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: EdgeInsets.symmetric(horizontal: hPad),
          textStyle: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        ),
      ),
    );
  }
}

/// Local copy of the Fee-Master pattern: wraps a CRUD panel with an Import
/// CSV/Excel toggle. importTabIndex selects which Master Data tab to load.
/// Wraps a CRUD panel with an "Import CSV/Excel" toggle. The toggle button is
/// rendered INSIDE the child panel's table-card header (via the [onImport]
/// callback passed to [childBuilder]) — matching the Fee Master layout. When
/// imports are active, the body is replaced by the Master Data import view.
class _PanelWithImport extends StatefulWidget {
  final Widget Function(VoidCallback onImport) childBuilder;
  final int importTabIndex;
  final String title;
  const _PanelWithImport({required this.importTabIndex, required this.title, required this.childBuilder});
  @override
  State<_PanelWithImport> createState() => _PanelWithImportState();
}

class _PanelWithImportState extends State<_PanelWithImport> {
  bool _importing = false;

  @override
  Widget build(BuildContext context) {
    if (_importing) {
      return Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(0, 4.h, 0, 0),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => setState(() => _importing = false),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('Back to list'),
                ),
                SizedBox(width: 10.w),
                Text('Import ${widget.title}',
                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ],
            ),
          ),
          Expanded(child: MasterImportScreen(initialTabIndex: widget.importTabIndex, showInternalTabs: false)),
        ],
      );
    }
    return widget.childBuilder(() => setState(() => _importing = true));
  }
}
