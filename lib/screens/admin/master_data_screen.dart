import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/master_crud_panel.dart';
import '../admission/admission_master_screen.dart' show TermPanel;
import 'master_import_screen.dart';

/// Master Data — two tabs: Standard, Section.
/// Each tab offers inline add/edit/list plus a Import CSV/Excel toggle that
/// switches to the bulk import flow (reuses MasterImportScreen).
class MasterDataScreen extends StatelessWidget {
  const MasterDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Padding(
        padding: EdgeInsets.all(16.w),
        child: Container(
          decoration: AppCard.decoration(),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(18.w, 14.h, 18.w, 6.h),
                child: Row(
                  children: [
                    const AppIcon('document-upload', size: 20, color: AppColors.primary),
                    SizedBox(width: 10.w),
                    Text('Master Data',
                        style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  ],
                ),
              ),
              TabBar(
                isScrollable: true,
                labelColor: AppColors.primary,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorColor: AppColors.accent,
                labelStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700),
                tabs: const [
                  Tab(text: 'Standard'),
                  Tab(text: 'Section'),
                  Tab(text: 'Term Period'),
                ],
              ),
              Divider(height: 1.h, color: AppColors.border),
              const Expanded(
                child: TabBarView(
                  children: [
                    _PanelWithImport(importTabIndex: 0, title: 'Standard', child: MasterCrudPanel(table: 'clagrp', idCol: 'cgrp_id', nameCol: 'clagrpname', title: 'Standard', ordidCol: 'ordid')),
                    _PanelWithImport(importTabIndex: 1, title: 'Section', child: _SectionCrudPanel()),
                    TermPanel(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Section CRUD — name plus parent Standard (public.class.cgrp_id).
class _SectionCrudPanel extends StatefulWidget {
  const _SectionCrudPanel();
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

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
      );

  TextStyle _h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
  TextStyle _c() => TextStyle(fontSize: 12.sp, color: AppColors.textSecondary);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 320.w,
            child: Container(
              padding: EdgeInsets.all(16.w),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(color: AppColors.border.withValues(alpha: 0.6)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_editId != null ? 'Edit Section' : 'Add Section',
                      style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700)),
                  SizedBox(height: 12.h),
                  TextField(controller: _name, style: TextStyle(fontSize: 13.sp), decoration: _dec('Section Name *')),
                  SizedBox(height: 10.h),
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
                      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                      decoration: _dec('Standard *'),
                      items: unique.map((s) => DropdownMenuItem(value: s['cgrp_id'].toString(), child: Text(s['clagrpname']?.toString() ?? '', overflow: TextOverflow.ellipsis))).toList(),
                      onChanged: (v) => setState(() => _cgrpId = v),
                    );
                  }),
                  SizedBox(height: 14.h),
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
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(color: AppColors.border.withValues(alpha: 0.6)),
              ),
              child: Column(
                children: [
                  Container(
                    color: AppColors.tableHeadBg,
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                    child: Row(children: [
                      SizedBox(width: 50.w, child: Text('S.No', style: _h())),
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
                                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                                    child: Row(children: [
                                      SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                                      Expanded(flex: 2, child: Text(r['claname']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Local copy of the Fee-Master pattern: wraps a CRUD panel with an Import
/// CSV/Excel toggle. importTabIndex selects which Master Data tab to load.
class _PanelWithImport extends StatefulWidget {
  final Widget child;
  final int importTabIndex;
  final String title;
  const _PanelWithImport({required this.importTabIndex, required this.title, required this.child});
  @override
  State<_PanelWithImport> createState() => _PanelWithImportState();
}

class _PanelWithImportState extends State<_PanelWithImport> {
  bool _importing = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 0),
          child: Row(
            children: [
              if (_importing) ...[
                OutlinedButton.icon(
                  onPressed: () => setState(() => _importing = false),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('Back to list'),
                ),
                SizedBox(width: 10.w),
                Text('Import ${widget.title}',
                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ],
              const Spacer(),
              if (!_importing)
                ElevatedButton.icon(
                  onPressed: () => setState(() => _importing = true),
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: const Text('Import CSV/Excel'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _importing
              ? MasterImportScreen(initialTabIndex: widget.importTabIndex, showInternalTabs: false)
              : widget.child,
        ),
      ],
    );
  }
}
