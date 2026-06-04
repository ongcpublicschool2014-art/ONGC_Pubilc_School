import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../admin/settings_screen.dart' show PaymentSequenceTab, FineRulesTab;
import '../admin/master_import_screen.dart';

/// Fee Master — clean CRUD (Admission-Master style) for the fee lookups:
/// Fee Group, Fee Type, Concession. Left "Add" form + right table.
/// Class Fee Demand uses the existing import screen (Master Data tab).
class FeeMasterScreen extends StatelessWidget {
  const FeeMasterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
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
                    const AppIcon('receipt-discount', size: 20, color: AppColors.primary),
                    SizedBox(width: 10.w),
                    Text('Fee Master',
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
                  Tab(text: 'Fee Group'),
                  Tab(text: 'Fee Type'),
                  Tab(text: 'Term'),
                  Tab(text: 'Class Fee Demand'),
                  Tab(text: 'Payment Sequence'),
                  Tab(text: 'Fine Rules'),
                ],
              ),
              Divider(height: 1.h, color: AppColors.border),
              const Expanded(
                child: TabBarView(
                  children: [
                    _PanelWithImport(child: _FeeGroupPanel(), importTabIndex: 2, title: 'Fee Group'),
                    _PanelWithImport(child: _FeeTypePanel(), importTabIndex: 3, title: 'Fee Type'),
                    _FeeTermPanel(),
                    _PanelWithImport(child: _ClassFeeDemandPanel(), importTabIndex: 5, title: 'Class Fee Demand'),
                    PaymentSequenceTab(),
                    FineRulesTab(),
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

// ── shared bits ───────────────────────────────────────────────────────────
InputDecoration _dec(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
    );

void _snack(BuildContext ctx, String msg, Color color) {
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
}

/// Next id = max(idCol) + 1. Pass [inSchema] = true for per-schema tables.
Future<int> _nextId(String table, String idCol, {bool inSchema = false}) async {
  final src = inSchema ? SupabaseService.fromSchema(table) : SupabaseService.client.from(table);
  final res = await src.select(idCol).order(idCol, ascending: false).limit(1).maybeSingle();
  final cur = res?[idCol];
  final n = cur is int ? cur : int.tryParse(cur?.toString() ?? '0') ?? 0;
  return n + 1;
}

Widget _tableShell({required List<Widget> headerCells, required Widget body}) {
  return Container(
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
          child: Row(children: headerCells),
        ),
        Expanded(child: body),
      ],
    ),
  );
}

TextStyle _h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
TextStyle _c() => TextStyle(fontSize: 12.sp, color: AppColors.textSecondary);

Future<bool> _confirmDelete(BuildContext ctx, String what) async {
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text('Delete $what'),
      content: Text('Remove this $what?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete', style: TextStyle(color: AppColors.error))),
      ],
    ),
  );
  return ok == true;
}

// ══════════════════════════════════════════════════════════════════════════
// FEE GROUP  (public)
// ══════════════════════════════════════════════════════════════════════════
class _FeeGroupPanel extends StatefulWidget {
  const _FeeGroupPanel();
  @override
  State<_FeeGroupPanel> createState() => _FeeGroupPanelState();
}

class _FeeGroupPanelState extends State<_FeeGroupPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
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
      final res = await SupabaseService.client
          .from('feegroup')
          .select('*')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .order('fg_id', ascending: true);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['fg_id'] is int ? r['fg_id'] as int : int.tryParse(r['fg_id'].toString());
      _name.text = r['fgdesc']?.toString() ?? '';
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
    });
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack(context, 'Enter a group name.', AppColors.warning);
    if (_rows.any((r) => (r['fgdesc']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() &&
        (r['fg_id']?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      return _snack(context, '"$name" already exists.', AppColors.warning);
    }
    setState(() => _saving = true);
    try {
      if (_editId != null) {
        await SupabaseService.client.from('feegroup').update({'fgdesc': name}).eq('fg_id', _editId!);
        if (mounted) _snack(context, 'Fee group updated.', AppColors.success);
      } else {
        await SupabaseService.client.from('feegroup').insert({
          'fg_id': await _nextId('feegroup', 'fg_id'),
          'fgdesc': name,
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Fee group added.', AppColors.success);
      }
      _name.clear();
      _editId = null;
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    if (!await _confirmDelete(context, 'fee group')) return;
    try {
      await SupabaseService.client.from('feegroup').update({'activestatus': 0}).eq('fg_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

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
                  Text(_editId != null ? 'Edit Fee Group' : 'Add Fee Group', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700)),
                  SizedBox(height: 12.h),
                  TextField(controller: _name, style: TextStyle(fontSize: 13.sp), decoration: _dec('Group Name *'), onSubmitted: (_) => _add()),
                  SizedBox(height: 14.h),
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _add,
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
            child: _tableShell(
              headerCells: [
                SizedBox(width: 50.w, child: Text('S.No', style: _h())),
                Expanded(child: Text('GROUP NAME', style: _h())),
                SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
              ],
              body: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rows.isEmpty
                      ? Center(child: Text('No fee groups', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                      : ListView.separated(
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
                          itemBuilder: (_, i) {
                            final r = _rows[i];
                            final id = r['fg_id'] is int ? r['fg_id'] as int : int.tryParse(r['fg_id'].toString()) ?? 0;
                            return Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                              child: Row(children: [
                                SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                                Expanded(child: Text(r['fgdesc']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
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
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// FEE TYPE  (public)
// ══════════════════════════════════════════════════════════════════════════
class _FeeTypePanel extends StatefulWidget {
  const _FeeTypePanel();
  @override
  State<_FeeTypePanel> createState() => _FeeTypePanelState();
}

class _FeeTypePanelState extends State<_FeeTypePanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  final _short = TextEditingController();
  String? _fgId;
  String _fine = 'No';
  String _kind = 'Regular';
  List<Map<String, dynamic>> _feeGroups = [];
  List<Map<String, dynamic>> _rows = [];
  Map<int, String> _fgName = {};
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
    _short.dispose();
    super.dispose();
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['fee_id'] is int ? r['fee_id'] as int : int.tryParse(r['fee_id'].toString());
      _name.text = r['feedesc']?.toString() ?? '';
      _short.text = r['feeshort']?.toString() ?? '';
      _fgId = r['fg_id']?.toString();
      _fine = '${r['feefineapplicable'] ?? 0}' == '1' ? 'Yes' : 'No';
      _kind = '${r['feeoptional'] ?? 0}' == '1' ? 'Optional' : 'Regular';
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
      _short.clear();
      _fine = 'No';
      _kind = 'Regular';
    });
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final groupsRes = await SupabaseService.client
          .from('feegroup')
          .select('fg_id, fgdesc')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .order('fg_id', ascending: true);
      final fgList = List<Map<String, dynamic>>.from(groupsRes as List);
      final fgIds = fgList.map((g) => g['fg_id'] as int).toList();
      final types = fgIds.isEmpty
          ? <dynamic>[]
          : await SupabaseService.client.from('feetype').select('*').inFilter('fg_id', fgIds).eq('activestatus', 1).order('fee_id', ascending: true);
      if (!mounted) return;
      setState(() {
        _feeGroups = fgList;
        _fgName = {for (final g in fgList) g['fg_id'] as int: g['fgdesc']?.toString() ?? ''};
        _rows = List<Map<String, dynamic>>.from(types);
        _fgId ??= fgList.isNotEmpty ? fgList.first['fg_id'].toString() : null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack(context, 'Enter a fee name.', AppColors.warning);
    if (_fgId == null) return _snack(context, 'Add a Fee Group first.', AppColors.warning);
    setState(() => _saving = true);
    try {
      if (_editId != null) {
        await SupabaseService.client.from('feetype').update({
          'feedesc': name,
          'feeshort': _short.text.trim(),
          'fg_id': int.tryParse(_fgId!),
          'feefineapplicable': _fine == 'Yes' ? 1 : 0,
          'feeoptional': _kind == 'Optional' ? 1 : 0,
        }).eq('fee_id', _editId!);
        if (mounted) _snack(context, 'Fee type updated.', AppColors.success);
      } else {
        await SupabaseService.client.from('feetype').insert({
          'fee_id': await _nextId('feetype', 'fee_id'),
          'feedesc': name,
          'feeshort': _short.text.trim(),
          'fg_id': int.tryParse(_fgId!),
          'feefineapplicable': _fine == 'Yes' ? 1 : 0,
          'feeoptional': _kind == 'Optional' ? 1 : 0,
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Fee type added.', AppColors.success);
      }
      _name.clear();
      _short.clear();
      _kind = 'Regular';
      _editId = null;
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    if (!await _confirmDelete(context, 'fee type')) return;
    try {
      await SupabaseService.client.from('feetype').update({'activestatus': 0}).eq('fee_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

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
                  Text(_editId != null ? 'Edit Fee Type' : 'Add Fee Type', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700)),
                  SizedBox(height: 12.h),
                  TextField(controller: _name, style: TextStyle(fontSize: 13.sp), decoration: _dec('Fee Name *')),
                  SizedBox(height: 10.h),
                  TextField(controller: _short, style: TextStyle(fontSize: 13.sp), decoration: _dec('Short Name')),
                  SizedBox(height: 10.h),
                  DropdownButtonFormField<String>(
                    initialValue: _fgId,
                    isExpanded: true,
                    style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                    decoration: _dec('Fee Group *'),
                    items: _feeGroups.map((g) => DropdownMenuItem(value: g['fg_id'].toString(), child: Text(g['fgdesc']?.toString() ?? '', overflow: TextOverflow.ellipsis))).toList(),
                    onChanged: (v) => setState(() => _fgId = v),
                  ),
                  SizedBox(height: 10.h),
                  DropdownButtonFormField<String>(
                    initialValue: _fine,
                    isExpanded: true,
                    style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                    decoration: _dec('Fine Applicable'),
                    items: const [DropdownMenuItem(value: 'No', child: Text('No')), DropdownMenuItem(value: 'Yes', child: Text('Yes'))],
                    onChanged: (v) => setState(() => _fine = v ?? 'No'),
                  ),
                  SizedBox(height: 10.h),
                  DropdownButtonFormField<String>(
                    initialValue: _kind,
                    isExpanded: true,
                    style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                    decoration: _dec('Type'),
                    items: const [DropdownMenuItem(value: 'Regular', child: Text('Regular')), DropdownMenuItem(value: 'Optional', child: Text('Optional'))],
                    onChanged: (v) => setState(() => _kind = v ?? 'Regular'),
                  ),
                  SizedBox(height: 14.h),
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _add,
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
            child: _tableShell(
              headerCells: [
                SizedBox(width: 50.w, child: Text('S.No', style: _h())),
                Expanded(flex: 3, child: Text('FEE NAME', style: _h())),
                SizedBox(width: 80.w, child: Text('SHORT', style: _h())),
                Expanded(flex: 2, child: Text('FEE GROUP', style: _h())),
                SizedBox(width: 60.w, child: Text('FINE', style: _h())),
                SizedBox(width: 80.w, child: Text('TYPE', style: _h())),
                SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
              ],
              body: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rows.isEmpty
                      ? Center(child: Text('No fee types', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                      : ListView.separated(
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
                          itemBuilder: (_, i) {
                            final r = _rows[i];
                            final id = r['fee_id'] is int ? r['fee_id'] as int : int.tryParse(r['fee_id'].toString()) ?? 0;
                            final fine = '${r['feefineapplicable'] ?? 0}' == '1' ? 'Yes' : 'No';
                            final kind = '${r['feeoptional'] ?? 0}' == '1' ? 'Optional' : 'Regular';
                            return Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                              child: Row(children: [
                                SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                                Expanded(flex: 3, child: Text(r['feedesc']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
                                SizedBox(width: 80.w, child: Text(r['feeshort']?.toString() ?? '', style: _c())),
                                Expanded(flex: 2, child: Text(_fgName[r['fg_id']] ?? '', style: _c())),
                                SizedBox(width: 60.w, child: Text(fine, style: _c())),
                                SizedBox(width: 80.w, child: Text(kind, style: _c())),
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
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// CONCESSION  (per-schema)
// ══════════════════════════════════════════════════════════════════════════
class _ConcessionPanel extends StatefulWidget {
  const _ConcessionPanel();
  @override
  State<_ConcessionPanel> createState() => _ConcessionPanelState();
}

class _ConcessionPanelState extends State<_ConcessionPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
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

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['con_id'] is int ? r['con_id'] as int : int.tryParse(r['con_id'].toString());
      _name.text = r['condesc']?.toString() ?? '';
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
    });
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await SupabaseService.fromSchema('concessioncategory')
          .select('*').eq('ins_id', _insId).eq('activestatus', 1).order('con_id', ascending: true);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack(context, 'Enter a concession name.', AppColors.warning);
    if (_rows.any((r) => (r['condesc']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() &&
        (r['con_id']?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      return _snack(context, '"$name" already exists.', AppColors.warning);
    }
    setState(() => _saving = true);
    try {
      if (_editId != null) {
        await SupabaseService.fromSchema('concessioncategory').update({'condesc': name}).eq('con_id', _editId!);
        if (mounted) _snack(context, 'Concession updated.', AppColors.success);
      } else {
        await SupabaseService.fromSchema('concessioncategory').insert({
          'con_id': await _nextId('concessioncategory', 'con_id', inSchema: true),
          'condesc': name,
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Concession added.', AppColors.success);
      }
      _name.clear();
      _editId = null;
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    if (!await _confirmDelete(context, 'concession')) return;
    try {
      await SupabaseService.fromSchema('concessioncategory').update({'activestatus': 0}).eq('con_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

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
                  Text(_editId != null ? 'Edit Concession' : 'Add Concession', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700)),
                  SizedBox(height: 12.h),
                  TextField(controller: _name, style: TextStyle(fontSize: 13.sp), decoration: _dec('Concession Name *'), onSubmitted: (_) => _add()),
                  SizedBox(height: 14.h),
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _add,
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
            child: _tableShell(
              headerCells: [
                SizedBox(width: 50.w, child: Text('S.No', style: _h())),
                Expanded(child: Text('CONCESSION NAME', style: _h())),
                SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
              ],
              body: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rows.isEmpty
                      ? Center(child: Text('No concessions', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                      : ListView.separated(
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
                          itemBuilder: (_, i) {
                            final r = _rows[i];
                            final id = r['con_id'] is int ? r['con_id'] as int : int.tryParse(r['con_id'].toString()) ?? 0;
                            return Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                              child: Row(children: [
                                SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                                Expanded(child: Text(r['condesc']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
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
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// CLASS FEE DEMAND  (per-schema classfeedemand + tempfeedemand staging)
// ══════════════════════════════════════════════════════════════════════════
class _FeeLine {
  String? feeType;
  final amount = TextEditingController();
  bool fromExisting = false;
  int? cfId;
  // 1 = first option (New/Boy/DayScholar), 2 = second (Old/Girl/Hosteler), 3 = Both.
  int cfnob = 3;
  int cfbgb = 3;
  int cfdhb = 3;
  void dispose() => amount.dispose();
}

class _ClassFeeDemandPanel extends StatefulWidget {
  const _ClassFeeDemandPanel();
  @override
  State<_ClassFeeDemandPanel> createState() => _ClassFeeDemandPanelState();
}

class _ClassFeeDemandPanelState extends State<_ClassFeeDemandPanel> with AutomaticKeepAliveClientMixin {
  String? _section;
  String? _term;
  DateTime? _due;
  bool _editMode = false;
  final List<_FeeLine> _lines = [];

  List<String> _sectionNames = [];
  List<String> _termNames = [];
  List<String> _feeTypeNames = [];
  Map<String, int> _feeOptionalByName = {};
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _saving = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < 5; i++) {
      _lines.add(_FeeLine());
    }
    _load();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        SupabaseService.fromSchema('classfeedemand').select('*'),
        SupabaseService.client.from('class').select('claname, ordid').eq('ins_id', _insId).eq('activestatus', 1).order('ordid', ascending: true).order('claname', ascending: true),
        SupabaseService.client.from('feetype').select('feedesc, feeoptional').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('term').select('termname').eq('ins_id', _insId).eq('activestatus', 1),
      ]);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from((results[0] as List).cast<Map<String, dynamic>>());
        _sectionNames = (results[1] as List).map((e) => e['claname']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList();
        _feeTypeNames = (results[2] as List).map((e) => e['feedesc']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList()..sort();
        _feeOptionalByName = {
          for (final e in (results[2] as List))
            ((e as Map)['feedesc']?.toString().trim() ?? ''): ((e['feeoptional'] as num?)?.toInt() ?? 0)
        }..removeWhere((k, _) => k.isEmpty);
        _termNames = (results[3] as List).map((e) => e['termname']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList()..sort();
        _section ??= _sectionNames.isNotEmpty ? _sectionNames.first : null;
        if (_section != null) _reloadGrid();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  double get _total => _lines.fold(0.0, (s, l) => s + (double.tryParse(l.amount.text.trim()) ?? 0));

  String _amtStr(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  void _loadLinesForSelection() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines.clear();
    final existing = <String, Map<String, dynamic>>{};
    for (final r in _rows) {
      if ((r['cfclass']?.toString() ?? '') != _section) continue;
      if (_term != null && (r['cfterm']?.toString() ?? '') != _term) continue;
      existing[r['cffeetype']?.toString() ?? ''] = r;
    }
    for (final ft in _feeTypeNames) {
      final line = _FeeLine()..feeType = ft;
      final r = existing[ft];
      if (r != null) {
        final amt = r['cfamount'];
        final n = amt is num ? amt : double.tryParse(amt?.toString() ?? '');
        if (n != null) line.amount.text = _amtStr(n);
        line.fromExisting = true;
        line.cfId = r['cf_id'] is int ? r['cf_id'] as int : int.tryParse(r['cf_id'].toString());
        line.cfnob = (r['cfnob'] as num?)?.toInt() ?? 3;
        line.cfbgb = (r['cfbgb'] as num?)?.toInt() ?? 3;
        line.cfdhb = (r['cfdhb'] as num?)?.toInt() ?? 3;
      }
      _lines.add(line);
    }
    if (_lines.isEmpty) {
      for (var i = 0; i < 5; i++) {
        _lines.add(_FeeLine());
      }
    }
  }

  void _blankLines() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines.clear();
    for (final ft in _feeTypeNames) {
      _lines.add(_FeeLine()..feeType = ft);
    }
    if (_lines.isEmpty) {
      for (var i = 0; i < 5; i++) {
        _lines.add(_FeeLine());
      }
    }
  }

  void _reloadGrid() => _editMode ? _loadLinesForSelection() : _blankLines();

  Future<int> _nextCfId() => _nextId('classfeedemand', 'cf_id', inSchema: true);

  Future<void> _save() async {
    if (_section == null || _term == null || _due == null) {
      return _snack(context, 'Select Section, Term and Pay-On-or-Before date.', AppColors.warning);
    }
    final lines = _lines.where((l) => l.feeType != null && l.amount.text.trim().isNotEmpty).toList();
    if (lines.isEmpty) return _snack(context, 'Enter at least one fee amount.', AppColors.warning);
    final auth = context.read<AuthProvider>();
    setState(() => _saving = true);
    int done = 0;
    int demCount = 0;
    final fails = <String>[];
    try {
      await SupabaseService.fromSchema('classfeedemand').delete().eq('cfclass', _section!).eq('cfterm', _term!);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      return _snack(context, 'Save failed clearing old rows. ${friendlyError(e)}', AppColors.error);
    }
    for (final l in lines) {
      try {
        await SupabaseService.fromSchema('classfeedemand').insert({
          'cf_id': await _nextCfId(),
          'cfclass': _section,
          'cfterm': _term,
          'cffeetype': l.feeType,
          'cfamount': double.tryParse(l.amount.text.trim()),
          'cfdduedate': _due!.toIso8601String().split('T').first,
          'cfnob': l.cfnob,
          'cfbgb': l.cfbgb,
          'cfdhb': l.cfdhb,
        });
        done++;
      } catch (e) {
        fails.add('${l.feeType}: ${friendlyError(e)}');
      }
    }
    if (fails.isEmpty) {
      try {
        demCount = _editMode
            ? await _propagateToFeedemand(lines, auth)
            : await _generateTempDemands(lines, auth);
      } catch (e) {
        fails.add('Demand ${_editMode ? 'update' : 'generation'}: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (fails.isEmpty) {
      _snack(
        context,
        _editMode
            ? 'Updated $done fee line(s)${demCount > 0 ? ' • $demCount student demand(s) updated' : ''}.'
            : 'Saved $done fee line(s)${demCount > 0 ? ' • $demCount demand(s) sent for approval' : ''}.',
        AppColors.success,
      );
    } else if (mounted) {
      _snack(context, 'Saved $done, ${fails.length} failed. ${fails.first}', AppColors.error);
    }
    await _load();
  }

  Future<int> _generateTempDemands(List<_FeeLine> lines, AuthProvider auth, {String? forSection}) async {
    final cls = forSection ?? _section!;
    final insId = auth.insId ?? 1;
    final yearRes = await SupabaseService.client
        .from('institutionyear')
        .select('iyr_id, yrlabel')
        .eq('ins_id', insId)
        .eq('activestatus', 1)
        .order('iyr_id', ascending: false)
        .limit(1)
        .maybeSingle();
    final yrId = yearRes != null ? int.tryParse(yearRes['iyr_id'].toString()) ?? 0 : 0;
    final yrLabel = yearRes?['yrlabel']?.toString() ?? '';
    final studentsRes = await SupabaseService.fromSchema('students')
        .select('stu_id, stuadmno, clagrpname, stugender, hostel, admittyear')
        .eq('ins_id', insId)
        .eq('stuclass', cls)
        .eq('activestatus', 1);
    final students = List<Map<String, dynamic>>.from(studentsRes as List);
    if (students.isEmpty) return 0;
    final rows = <Map<String, dynamic>>[];
    final due = _due!.toIso8601String().split('T').first;
    bool match(Map<String, dynamic> s, _FeeLine l) {
      // cfnob: 1=New (admittyear == current), 2=Old (admittyear != current), 3=Both
      if (l.cfnob == 1 && (s['admittyear']?.toString() ?? '') != yrLabel) return false;
      if (l.cfnob == 2 && (s['admittyear']?.toString() ?? '') == yrLabel) return false;
      // cfbgb: 1=Boy (M), 2=Girl (F), 3=Both
      if (l.cfbgb == 1 && (s['stugender']?.toString() ?? '') != 'M') return false;
      if (l.cfbgb == 2 && (s['stugender']?.toString() ?? '') != 'F') return false;
      // cfdhb: 1=Day Scholar (hostel != Y), 2=Hosteler (Y), 3=Both
      final isHosteler = (s['hostel']?.toString() ?? '') == 'Y';
      if (l.cfdhb == 1 && isHosteler) return false;
      if (l.cfdhb == 2 && !isHosteler) return false;
      return true;
    }
    for (final s in students) {
      for (final l in lines) {
        if (!match(s, l)) continue;
        final amt = double.tryParse(l.amount.text.trim()) ?? 0;
        rows.add({
          'ins_id': insId,
          'inscode': auth.inscode ?? '',
          'yr_id': yrId,
          'stu_id': s['stu_id'],
          'stuadmno': s['stuadmno'],
          'stuclass': cls,
          'clagrpname': s['clagrpname'],
          'demfeeyear': yrLabel,
          'demfeeterm': _term,
          'demfeetype': l.feeType,
          'feeamount': amt,
          'balancedue': amt,
          'duedate': due,
          'createdby': auth.userName,
          'isapproved': false,
          'activestatus': 1,
          'feeoptional': _feeOptionalByName[l.feeType ?? ''] ?? 0,
          'collectible': (_feeOptionalByName[l.feeType ?? ''] ?? 0) == 0,
        });
      }
    }
    if (rows.isEmpty) return 0;
    await SupabaseService.fromSchema('tempfeedemand').insert(rows);
    return rows.length;
  }

  Future<int> _propagateToFeedemand(List<_FeeLine> lines, AuthProvider auth) async {
    final insId = auth.insId ?? 1;
    final due = _due!.toIso8601String().split('T').first;
    var updated = 0;
    for (final l in lines) {
      final amt = double.tryParse(l.amount.text.trim()) ?? 0;
      // 1) Approved demands — recalc balance, push new amount.
      final fdRes = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, conamount, paidamount')
          .eq('ins_id', insId)
          .eq('stuclass', _section!)
          .eq('demfeeterm', _term!)
          .eq('demfeetype', l.feeType!)
          .eq('paidstatus', 'U')
          .eq('activestatus', 1);
      for (final r in (fdRes as List)) {
        final m = r as Map;
        final con = (m['conamount'] as num?)?.toDouble() ?? 0;
        final paid = (m['paidamount'] as num?)?.toDouble() ?? 0;
        final bal = (amt - con - paid) > 0 ? (amt - con - paid) : 0;
        await SupabaseService.fromSchema('feedemand').update({
          'feeamount': amt,
          'balancedue': bal,
          'reconbalancedue': bal,
          'duedate': due,
        }).eq('dem_id', m['dem_id']);
        updated++;
      }
      // 2) Pending tempfeedemand (still in approval queue) — push amount + due.
      final tfdRes = await SupabaseService.fromSchema('tempfeedemand')
          .select('temp_id, conamount')
          .eq('ins_id', insId)
          .eq('stuclass', _section!)
          .eq('demfeeterm', _term!)
          .eq('demfeetype', l.feeType!)
          .eq('isapproved', false)
          .eq('activestatus', 1);
      for (final r in (tfdRes as List)) {
        final m = r as Map;
        final con = (m['conamount'] as num?)?.toDouble() ?? 0;
        final bal = (amt - con) > 0 ? (amt - con) : 0;
        await SupabaseService.fromSchema('tempfeedemand').update({
          'feeamount': amt,
          'balancedue': bal,
          'duedate': due,
        }).eq('temp_id', m['temp_id']);
        updated++;
      }
    }
    return updated;
  }

  Future<void> _copyFee() async {
    final lines = _lines.where((l) => l.feeType != null && l.amount.text.trim().isNotEmpty).toList();
    if (lines.isEmpty) return _snack(context, 'Enter fee amounts to copy.', AppColors.warning);
    if (_term == null || _due == null) {
      return _snack(context, 'Select Term and Pay-On-or-Before before copying.', AppColors.warning);
    }
    final targets = await _pickTargetSections();
    if (targets == null || targets.isEmpty) return;
    final auth = context.read<AuthProvider>();
    setState(() => _saving = true);
    final due = _due!.toIso8601String().split('T').first;
    var sectionsDone = 0, demTotal = 0;
    final fails = <String>[];
    for (final cls in targets) {
      try {
        await SupabaseService.fromSchema('classfeedemand').delete().eq('cfclass', cls).eq('cfterm', _term!);
        for (final l in lines) {
          await SupabaseService.fromSchema('classfeedemand').insert({
            'cf_id': await _nextCfId(),
            'cfclass': cls,
            'cfterm': _term,
            'cffeetype': l.feeType,
            'cfamount': double.tryParse(l.amount.text.trim()),
            'cfdduedate': due,
          });
        }
        demTotal += await _generateTempDemands(lines, auth, forSection: cls);
        sectionsDone++;
      } catch (e) {
        fails.add('$cls: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    _snack(
      context,
      fails.isEmpty
          ? 'Copied fees to $sectionsDone section(s) • $demTotal demand(s) staged.'
          : 'Copied to $sectionsDone, ${fails.length} failed. ${fails.first}',
      fails.isEmpty ? AppColors.success : AppColors.error,
    );
    await _load();
  }

  Future<List<String>?> _pickTargetSections() async {
    final picked = <String>{};
    return showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final options = _sectionNames.where((c) => c != _section).toList();
          return AlertDialog(
            title: Text('Copy fees to sections', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
            content: SizedBox(
              width: 360.w,
              height: 360.h,
              child: options.isEmpty
                  ? Center(child: Text('No other sections', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                  : ListView(
                      children: [
                        Padding(
                          padding: EdgeInsets.only(bottom: 4.h),
                          child: Text('From ${_section ?? ''} • ${_term ?? ''}',
                              style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
                        ),
                        for (final c in options)
                          CheckboxListTile(
                            dense: true,
                            value: picked.contains(c),
                            title: Text(c, style: TextStyle(fontSize: 13.sp)),
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (v) => setLocal(() => v == true ? picked.add(c) : picked.remove(c)),
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, picked.toList()),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
                child: Text('Copy to ${picked.length}'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _delete(int id) async {
    if (!await _confirmDelete(context, 'fee line')) return;
    try {
      await SupabaseService.fromSchema('classfeedemand').delete().eq('cf_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

  String _fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: _creation()),
          SizedBox(width: 16.w),
          Expanded(flex: 2, child: _existing()),
        ],
      ),
    );
  }

  Widget _flagDropdown(int value, Map<int, String> opts, ValueChanged<int> onChanged) {
    return DropdownButtonFormField<int>(
      initialValue: opts.containsKey(value) ? value : 3,
      isExpanded: true,
      isDense: true,
      style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 8.h),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.r)),
      ),
      items: opts.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (v) => onChanged(v ?? 3),
    );
  }

  Widget _modeButton(String label, IconData icon, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: active ? AppColors.primary : AppColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15.sp, color: active ? Colors.white : AppColors.textSecondary),
          SizedBox(width: 6.w),
          Text(label, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: active ? Colors.white : AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _creation() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: 10.h),
          child: Row(children: [
            _modeButton('New', Icons.add, !_editMode, () => setState(() {
              _editMode = false;
              _reloadGrid();
            })),
            SizedBox(width: 10.w),
            _modeButton('Edit', Icons.edit, _editMode, () => setState(() {
              _editMode = true;
              _reloadGrid();
            })),
            SizedBox(width: 10.w),
            OutlinedButton.icon(
              onPressed: _saving ? null : _copyFee,
              icon: const Icon(Icons.copy_all, size: 15),
              label: const Text('Copy Fee'),
            ),
            SizedBox(width: 12.w),
            Text(_editMode ? 'Editing saved demand for this selection' : 'Creating a new demand',
                style: TextStyle(fontSize: 11.sp, color: AppColors.textLight)),
          ]),
        ),
        Container(
          padding: EdgeInsets.all(12.w),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12.r), border: Border.all(color: AppColors.border.withValues(alpha: 0.6))),
          child: Wrap(spacing: 12.w, runSpacing: 10.h, children: [
            SizedBox(width: 190.w, child: DropdownButtonFormField<String>(initialValue: _section, isExpanded: true, style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary), decoration: _dec('Section *'), items: _sectionNames.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(), onChanged: (v) => setState(() {
              _section = v;
              _reloadGrid();
            }))),
            SizedBox(width: 190.w, child: DropdownButtonFormField<String>(initialValue: _term, isExpanded: true, style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary), decoration: _dec('Term *'), items: _termNames.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(), onChanged: (v) => setState(() {
              _term = v;
              _reloadGrid();
            }))),
            SizedBox(width: 200.w, child: InkWell(onTap: () async {
              final now = DateTime.now();
              final p = await showDatePicker(context: context, initialDate: _due ?? now, firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 5));
              if (p != null) setState(() => _due = p);
            }, child: InputDecorator(decoration: _dec('Pay On or Before *'), child: Text(_due == null ? 'Select' : _fmt(_due!), style: TextStyle(fontSize: 13.sp, color: _due == null ? AppColors.textLight : AppColors.textPrimary))))),
          ]),
        ),
        SizedBox(height: 12.h),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12.r), border: Border.all(color: AppColors.border.withValues(alpha: 0.6))),
            child: Column(children: [
              Container(color: AppColors.tableHeadBg, padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h), child: Row(children: [
                Expanded(flex: 3, child: Text('FEE TYPE', style: _h())),
                SizedBox(width: 120.w, child: Text('AMOUNT', style: _h())),
                SizedBox(width: 100.w, child: Text('NEW/OLD', style: _h())),
                SizedBox(width: 100.w, child: Text('BOY/GIRL', style: _h())),
                SizedBox(width: 110.w, child: Text('DAY/HOSTEL', style: _h())),
              ])),
              Expanded(child: ListView.separated(itemCount: _lines.length, separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.4)), itemBuilder: (_, i) {
                final l = _lines[i];
                return Padding(padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 5.h), child: Row(children: [
                  Expanded(flex: 3, child: Padding(padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 10.h), child: Text(l.feeType ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary)))),
                  SizedBox(width: 8.w),
                  SizedBox(width: 112.w, child: TextField(controller: l.amount, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary), decoration: _dec(''), onChanged: (_) => setState(() {}))),
                  SizedBox(width: 8.w),
                  SizedBox(width: 92.w, child: _flagDropdown(l.cfnob, const {1: 'New', 2: 'Old', 3: 'Both'}, (v) => setState(() => l.cfnob = v))),
                  SizedBox(width: 8.w),
                  SizedBox(width: 92.w, child: _flagDropdown(l.cfbgb, const {1: 'Boy', 2: 'Girl', 3: 'Both'}, (v) => setState(() => l.cfbgb = v))),
                  SizedBox(width: 8.w),
                  SizedBox(width: 102.w, child: _flagDropdown(l.cfdhb, const {1: 'Day', 2: 'Hostel', 3: 'Both'}, (v) => setState(() => l.cfdhb = v))),
                ]));
              })),
              Divider(height: 1.h, color: AppColors.border),
              Padding(padding: EdgeInsets.all(12.w), child: Row(children: [
                Text(_editMode ? 'Edit pushes amounts into existing unpaid demands' : 'New stages tempfeedemand for approval', style: TextStyle(fontSize: 11.sp, color: AppColors.textLight)),
                const Spacer(),
                Text('Total  ', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                Text(_total.toStringAsFixed(2), style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
                SizedBox(width: 16.w),
                ElevatedButton.icon(onPressed: _saving ? null : _save, icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save, size: 16), label: const Text('Save'), style: ElevatedButton.styleFrom(backgroundColor: AppColors.success, foregroundColor: Colors.white)),
              ])),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _existing() {
    final filtered = _section == null ? _rows : _rows.where((r) => (r['cfclass']?.toString() ?? '') == _section).toList();
    return _tableShell(
      headerCells: [
        SizedBox(width: 70.w, child: Text('TERM', style: _h())),
        Expanded(flex: 2, child: Text('FEE TYPE', style: _h())),
        SizedBox(width: 70.w, child: Text('AMT', style: _h())),
        SizedBox(width: 44.w, child: Text('', style: _h())),
      ],
      body: filtered.isEmpty
          ? Center(child: Text('No fee demands', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)), itemBuilder: (_, i) {
              final r = filtered[i];
              final id = r['cf_id'] is int ? r['cf_id'] as int : int.tryParse(r['cf_id'].toString()) ?? 0;
              return Padding(padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h), child: Row(children: [
                SizedBox(width: 70.w, child: Text(r['cfterm']?.toString() ?? '', style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary))),
                Expanded(flex: 2, child: Text(r['cffeetype']?.toString() ?? '', style: _c())),
                SizedBox(width: 70.w, child: Text(r['cfamount']?.toString() ?? '', style: _c())),
                SizedBox(width: 44.w, child: Center(child: InkWell(onTap: () => _delete(id), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 15, color: AppColors.error))))),
              ]));
            }),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// TERM  (per-schema name + short + Term/Month type)
// ══════════════════════════════════════════════════════════════════════════
class _FeeTermPanel extends StatefulWidget {
  const _FeeTermPanel();
  @override
  State<_FeeTermPanel> createState() => _FeeTermPanelState();
}

class _FeeTermPanelState extends State<_FeeTermPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  final _short = TextEditingController();
  String _type = 'T'; // T = Term, M = Month
  List<Map<String, dynamic>> _rows = [];
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
    _short.dispose();
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await SupabaseService.fromSchema('term')
          .select('*').eq('ins_id', _insId).eq('activestatus', 1).order('term_id', ascending: true);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['term_id'] is int ? r['term_id'] as int : int.tryParse(r['term_id'].toString());
      _name.text = r['termname']?.toString() ?? '';
      _short.text = r['termshort']?.toString() ?? '';
      _type = (r['termtype']?.toString() ?? 'T') == 'M' ? 'M' : 'T';
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
      _short.clear();
      _type = 'T';
    });
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack(context, 'Enter a term name.', AppColors.warning);
    if (_rows.any((r) => (r['termname']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() &&
        (r['term_id']?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      return _snack(context, '"$name" already exists.', AppColors.warning);
    }
    setState(() => _saving = true);
    try {
      if (_editId != null) {
        await SupabaseService.fromSchema('term').update({
          'termname': name,
          'termshort': _short.text.trim().isEmpty ? null : _short.text.trim(),
          'termtype': _type,
        }).eq('term_id', _editId!);
        if (mounted) _snack(context, 'Term updated.', AppColors.success);
      } else {
        await SupabaseService.fromSchema('term').insert({
          'term_id': await _nextId('term', 'term_id', inSchema: true),
          'termname': name,
          'termshort': _short.text.trim().isEmpty ? null : _short.text.trim(),
          'termtype': _type,
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Term added.', AppColors.success);
      }
      _name.clear();
      _short.clear();
      _type = 'T';
      _editId = null;
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    if (!await _confirmDelete(context, 'term')) return;
    try {
      await SupabaseService.fromSchema('term').update({'activestatus': 0}).eq('term_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

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
                  Text(_editId != null ? 'Edit Term' : 'Add Term', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700)),
                  SizedBox(height: 12.h),
                  TextField(controller: _name, style: TextStyle(fontSize: 13.sp), decoration: _dec('Term Name *')),
                  SizedBox(height: 10.h),
                  TextField(controller: _short, style: TextStyle(fontSize: 13.sp), decoration: _dec('Short Name')),
                  SizedBox(height: 10.h),
                  DropdownButtonFormField<String>(
                    initialValue: _type,
                    isExpanded: true,
                    style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                    decoration: _dec('Term / Month'),
                    items: const [
                      DropdownMenuItem(value: 'T', child: Text('Term')),
                      DropdownMenuItem(value: 'M', child: Text('Month')),
                    ],
                    onChanged: (v) => setState(() => _type = v ?? 'T'),
                  ),
                  SizedBox(height: 14.h),
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saving ? null : _add,
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
            child: _tableShell(
              headerCells: [
                SizedBox(width: 50.w, child: Text('S.No', style: _h())),
                Expanded(flex: 3, child: Text('TERM', style: _h())),
                SizedBox(width: 100.w, child: Text('SHORT', style: _h())),
                SizedBox(width: 90.w, child: Text('TYPE', style: _h())),
                SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
              ],
              body: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _rows.isEmpty
                      ? Center(child: Text('No terms', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                      : ListView.separated(
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
                          itemBuilder: (_, i) {
                            final r = _rows[i];
                            final id = r['term_id'] is int ? r['term_id'] as int : int.tryParse(r['term_id'].toString()) ?? 0;
                            final type = (r['termtype']?.toString() ?? 'T') == 'M' ? 'Month' : 'Term';
                            return Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                              child: Row(children: [
                                SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                                Expanded(flex: 3, child: Text(r['termname']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
                                SizedBox(width: 100.w, child: Text(r['termshort']?.toString() ?? '', style: _c())),
                                SizedBox(width: 90.w, child: Text(type, style: _c())),
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
          ),
        ],
      ),
    );
  }
}

/// Wraps a CRUD panel with an "Import CSV/Excel" toggle that swaps the body
/// for the Master Data import view. Pass the Master Data tab index for the
/// import target (0=Standard, 1=Section, 2=Fee Group, 3=Fee Type, 4=Concession,
/// 5=Class Fee Demand).
class _PanelWithImport extends StatefulWidget {
  final Widget child;
  final int importTabIndex;
  final String title;
  const _PanelWithImport({required this.child, required this.importTabIndex, required this.title});
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
