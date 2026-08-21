import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/focusable_tap.dart';
import '../../widgets/pill_tab.dart';
import '../admin/master_import_screen.dart';
import '../admin/settings_screen.dart' show PaymentSequenceTab, FineRulesTab;

/// Fee Master — clean CRUD (Admission-Master style) for the fee lookups:
/// Fee Group, Fee Type, Concession, Class Fee Demand, Payment Sequence, Fine
/// Rules. Each tab is a left "Add" form + right table. Payment Sequence and
/// Fine Rules were previously in a standalone "Sequence Creation" sidebar
/// entry; they live here now so all fee configuration is in one place.
/// Fee Master — pill-tab page shell per fee-master-design.md § 1.
class FeeMasterScreen extends StatefulWidget {
  const FeeMasterScreen({super.key});

  @override
  State<FeeMasterScreen> createState() => _FeeMasterScreenState();
}

class _FeeMasterScreenState extends State<FeeMasterScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _tabLabels = [
    'Fee Group', 'Fee Type', 'Semester', 'Class Fee Demand', 'Payment Sequence', 'Demand No', 'Fine Rules',
  ];
  static const _tabIcons = [
    'receipt-discount', 'tag', 'calendar-1', 'category', 'sort', 'hashtag', 'warning-2',
  ];

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
            children: const [
              _FeeGroupPanel(),
              _FeeTypePanel(),
              _SemesterPanel(),
              _ClassFeeDemandPanel(),
              PaymentSequenceTab(),
              _DemandSequencePanel(),
              FineRulesTab(),
            ],
          ),
        ),
      ],
    );
  }
}

// ── shared bits ───────────────────────────────────────────────────────────
InputDecoration _dec(String label, {bool filled = false}) {
  final idle = filled ? AppColors.accent : AppColors.border;
  return InputDecoration(
    labelText: label,
    isDense: true,
    contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: BorderSide(color: idle, width: 1.5)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: BorderSide(color: idle, width: 1.5)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
  );
}

void _snack(BuildContext ctx, String msg, Color color) {
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
}

Future<Map<String, dynamic>?> _currentYear(int insId) async {
  final years = await SupabaseService.getYears(insId);
  return years.isNotEmpty ? years.first : null;
}

/// Next id for a per-schema master = max(idCol) + 1. These tables have
/// sequence-backed triggers, but explicit-id imports leave the sequence
/// behind, so supplying an explicit id avoids primary-key collisions.
Future<int> _nextId(String table, String idCol) async {
  final res = await SupabaseService.fromSchema(table)
      .select(idCol).order(idCol, ascending: false).limit(1).maybeSingle();
  final cur = res?[idCol];
  final n = cur is int ? cur : int.tryParse(cur?.toString() ?? '0') ?? 0;
  return n + 1;
}

TextStyle _h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
TextStyle _c() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);

// ── design helpers (mirrors master_data_screen / admission-master-design.md) ──

Widget _lbl(String text) =>
    Text(text, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black));

// [filled] = the field has a value. Filled fields get an amber (accent)
// border; empty fields stay grey; the focused border is always amber.
InputDecoration _filledFieldDec(BuildContext context, String hint, {bool filled = false}) {
  final compact = MediaQuery.of(context).size.width <= 1366;
  final textSize = compact ? 11.0 : 14.0;
  final hPad = compact ? 8.0 : 14.0;
  final vPad = compact ? 5.0 : 14.0;
  final radius = compact ? 5.0 : 8.0;
  final idle = filled ? AppColors.accent : AppColors.border;
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: textSize),
    contentPadding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: idle, width: 1.5)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: idle, width: 1.5)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
    filled: true,
    fillColor: Colors.white,
  );
}

TextStyle _fieldTextStyle(BuildContext context) {
  final compact = MediaQuery.of(context).size.width <= 1366;
  return TextStyle(fontWeight: FontWeight.w500, fontSize: compact ? 11 : 14, color: const Color(0xFF555555));
}

/// Outer Add card — white, 10r, full border, 20w padding. Header uses the
/// shared [CardTitleBlock] with optional subtitle.
Widget _addCard({required String icon, required String title, String? subtitle, required Widget child}) {
  return Container(
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
        CardTitleBlock(icon: icon, title: title, subtitle: subtitle),
        SizedBox(height: 20.h),
        child,
      ],
    ),
  );
}

/// Outer List card — title row with icon-tile block + count badge + optional
/// action; inner bordered table card inside.
Widget _listCard({
  required String icon,
  required String title,
  String? subtitle,
  required int count,
  required String countLabel,
  required List<Widget> headerCells,
  required Widget body,
  Widget? action,
}) {
  return Container(
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
            CardTitleBlock(icon: icon, title: title, subtitle: subtitle),
            SizedBox(width: 10.w),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: Text('$count $countLabel',
                  style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
            ),
            const Spacer(),
            if (action != null) action,
          ]),
        ),
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                Container(
                  color: AppColors.tableHeadBg,
                  padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                  child: Row(children: headerCells),
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// Compact-or-expanded amber Import CSV/Excel button — sits in the
/// `action` slot of `_listCard`. Opens [MasterImportScreen] at [tabIndex],
/// then runs [onReturn].
Widget _importButton(BuildContext context, {
  required String title,
  required int tabIndex,
  required bool disabled,
  required Future<void> Function() onReturn,
}) {
  final compact = MediaQuery.of(context).size.width <= 1366;
  final btnHeight = compact ? 30.0 : 40.0;
  final iconSize = compact ? 12.0 : 16.0;
  final hPad = compact ? 10.0 : 18.0;
  final radius = compact ? 6.0 : 10.0;
  final textSize = compact ? 11.0 : 13.0;
  return SizedBox(
    height: btnHeight,
    child: ElevatedButton.icon(
      onPressed: disabled
          ? null
          : () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    backgroundColor: AppColors.surface,
                    appBar: AppBar(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.textPrimary,
                      elevation: 0,
                      shape: const Border(bottom: BorderSide(color: AppColors.border)),
                      title: Row(children: [
                        const AppIcon('document-upload', size: 20, color: AppColors.primary),
                        SizedBox(width: 10.w),
                        Text('Import $title',
                            style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      ]),
                    ),
                    body: Padding(
                      padding: EdgeInsets.all(16.w),
                      child: MasterImportScreen(initialTabIndex: tabIndex, showInternalTabs: false),
                    ),
                  ),
                ),
              );
              await onReturn();
            },
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
// FEE GROUP
// ══════════════════════════════════════════════════════════════════════════
class _FeeGroupPanel extends StatefulWidget {
  const _FeeGroupPanel();
  @override
  State<_FeeGroupPanel> createState() => _FeeGroupPanelState();
}

class _FeeGroupPanelState extends State<_FeeGroupPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  int? _editId; // non-null while editing an existing row
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
      final res = await SupabaseService.fromSchema('feegroup')
          .select('*').eq('ins_id', _insId).eq('activestatus', 1).order('fg_id', ascending: true);
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
        await SupabaseService.saveSchemaRow('feegroup', {'fgdesc': name}, pkCol: 'fg_id', pkVal: _editId!);
        if (mounted) _snack(context, 'Fee group updated.', AppColors.success);
      } else {
        final yr = await _currentYear(_insId);
        await SupabaseService.saveSchemaRow('feegroup', {
          'fg_id': await _nextId('feegroup', 'fg_id'),
          'fgdesc': name,
          'ins_id': _insId,
          'yr_id': yr != null ? int.tryParse(yr['yr_id'].toString()) ?? 0 : 0,
          'yrlabel': yr?['yrlabel']?.toString() ?? '',
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
      await SupabaseService.deleteSchemaRow('feegroup', 'fg_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320.w,
          child: _addCard(
            icon: 'receipt-discount',
            title: _editId != null ? 'Edit Fee Group' : 'Add Fee Group',
            subtitle: 'group fees by category',
            child: FocusTraversalGroup(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _lbl('Group Name *'),
                SizedBox(height: 6.h),
                TextField(
                  controller: _name,
                  style: _fieldTextStyle(context).copyWith(color: _name.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                  decoration: _filledFieldDec(context, 'Enter group name', filled: _name.text.trim().isNotEmpty),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _add(),
                ),
                SizedBox(height: 18.h),
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
            )),
          ),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: _listCard(
            icon: 'receipt-discount',
            title: 'Fee Groups',
            subtitle: 'all fee groups in this institution',
            count: _rows.length,
            countLabel: 'groups',
            action: _importButton(context, title: 'Fee Group', tabIndex: 4, disabled: _saving, onReturn: _load),
            headerCells: [
              SizedBox(width: 50.w, child: Text('S NO.', style: _h())),
              Expanded(child: Text('GROUP NAME', style: _h())),
              SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
            ],
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(child: Text('No fee groups', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border.withValues(alpha: 0.5)),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['fg_id'] is int ? r['fg_id'] as int : int.tryParse(r['fg_id'].toString()) ?? 0;
                          return Container(
                            color: i.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                            child: Row(children: [
                              SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                              Expanded(child: Text(r['fgdesc']?.toString() ?? '', style: _c())),
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
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// FEE TYPE
// ══════════════════════════════════════════════════════════════════════════
class _FeeTypePanel extends StatefulWidget {
  const _FeeTypePanel();
  @override
  State<_FeeTypePanel> createState() => _FeeTypePanelState();
}

class _FeeTypePanelState extends State<_FeeTypePanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  final _short = TextEditingController();
  final _type = TextEditingController();
  String? _fgId;
  String? _fine;
  List<Map<String, dynamic>> _feeGroups = [];
  List<Map<String, dynamic>> _rows = [];
  Map<int, String> _fgName = {};
  int? _editId; // non-null while editing an existing row
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
    _type.dispose();
    super.dispose();
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['fee_id'] is int ? r['fee_id'] as int : int.tryParse(r['fee_id'].toString());
      _name.text = r['feedesc']?.toString() ?? '';
      _short.text = r['feeshort']?.toString() ?? '';
      _type.text = r['type']?.toString() ?? '';
      _fgId = r['fg_id']?.toString();
      _fine = '${r['feefineapplicable'] ?? 0}' == '1' ? 'Yes' : 'No';
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
      _short.clear();
      _type.clear();
      _fine = null;
    });
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final groups = await SupabaseService.getFeeGroups(_insId);
      final fgList = List<Map<String, dynamic>>.from(groups);
      final fgIds = fgList.map((g) => g['fg_id'] as int).toList();
      final types = fgIds.isEmpty
          ? <dynamic>[]
          : await SupabaseService.fromSchema('feetype').select('*').inFilter('fg_id', fgIds).eq('activestatus', 1).order('fee_id', ascending: true);
      if (!mounted) return;
      setState(() {
        _feeGroups = fgList;
        _fgName = {for (final g in fgList) g['fg_id'] as int: g['fgdesc']?.toString() ?? ''};
        _rows = List<Map<String, dynamic>>.from(types);
        // Start with no fee group selected so the 'Select fee group'
        // placeholder shows (edit mode sets _fgId explicitly).
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
        await SupabaseService.saveSchemaRow('feetype', {
          'feedesc': name,
          'feeshort': _short.text.trim(),
          'fg_id': int.tryParse(_fgId!),
          'feefineapplicable': _fine == 'Yes' ? 1 : 0,
          'type': _type.text.trim().isEmpty ? null : _type.text.trim(),
        }, pkCol: 'fee_id', pkVal: _editId!);
        if (mounted) _snack(context, 'Fee type updated.', AppColors.success);
      } else {
        final yr = await _currentYear(_insId);
        await SupabaseService.saveSchemaRow('feetype', {
          'fee_id': await _nextId('feetype', 'fee_id'),
          'feedesc': name,
          'feeshort': _short.text.trim(),
          'fg_id': int.tryParse(_fgId!),
          'feefineapplicable': _fine == 'Yes' ? 1 : 0,
          'type': _type.text.trim().isEmpty ? null : _type.text.trim(),
          'yr_id': yr != null ? int.tryParse(yr['yr_id'].toString()) ?? 0 : 0,
          'yrlabel': yr?['yrlabel']?.toString() ?? '',
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Fee type added.', AppColors.success);
      }
      _name.clear();
      _short.clear();
      _type.clear();
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
      await SupabaseService.deleteSchemaRow('feetype', 'fee_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320.w,
          child: _addCard(
            icon: 'tag',
            title: _editId != null ? 'Edit Fee Type' : 'Add Fee Type',
            subtitle: 'individual fees inside a group',
            child: FocusTraversalGroup(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _lbl('Fee Name *'),
                SizedBox(height: 6.h),
                TextField(controller: _name, style: _fieldTextStyle(context).copyWith(color: _name.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), decoration: _filledFieldDec(context, 'Enter fee name', filled: _name.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                SizedBox(height: 16.h),
                _lbl('Short Name'),
                SizedBox(height: 6.h),
                TextField(controller: _short, style: _fieldTextStyle(context).copyWith(color: _short.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), decoration: _filledFieldDec(context, 'Enter short name', filled: _short.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                SizedBox(height: 16.h),
                _lbl('Fee Group *'),
                SizedBox(height: 6.h),
                DropdownButtonFormField<String>(
                  initialValue: _fgId,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context),
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  decoration: _filledFieldDec(context, 'Select fee group', filled: _fgId != null),
                  items: _feeGroups.map((g) => DropdownMenuItem(value: g['fg_id'].toString(), child: Text(g['fgdesc']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis))).toList(),
                  selectedItemBuilder: (context) => _feeGroups.map((g) => Align(alignment: Alignment.centerLeft, child: Text(g['fgdesc']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
                  onChanged: (v) => setState(() => _fgId = v),
                ),
                SizedBox(height: 16.h),
                _lbl('Fine Applicable'),
                SizedBox(height: 6.h),
                DropdownButtonFormField<String>(
                  initialValue: _fine,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context),
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  decoration: _filledFieldDec(context, 'Select option', filled: _fine != null),
                  items: [
                    DropdownMenuItem(value: 'No', child: Text('No', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
                    DropdownMenuItem(value: 'Yes', child: Text('Yes', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
                  ],
                  selectedItemBuilder: (context) => [
                    Align(alignment: Alignment.centerLeft, child: Text('No', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                    Align(alignment: Alignment.centerLeft, child: Text('Yes', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                  ],
                  onChanged: (v) => setState(() => _fine = v),
                ),
                SizedBox(height: 16.h),
                _lbl('Type'),
                SizedBox(height: 6.h),
                TextField(controller: _type, style: _fieldTextStyle(context).copyWith(color: _type.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), decoration: _filledFieldDec(context, 'Enter type (e.g. COL)', filled: _type.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                SizedBox(height: 18.h),
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
            )),
          ),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: _listCard(
            icon: 'tag',
            title: 'Fee Types',
            subtitle: 'all fee types in this institution',
            count: _rows.length,
            countLabel: 'types',
            action: _importButton(context, title: 'Fee Type', tabIndex: 5, disabled: _saving, onReturn: _load),
            headerCells: [
              SizedBox(width: 50.w, child: Text('S NO.', style: _h())),
              Expanded(flex: 3, child: Text('FEE NAME', style: _h())),
              SizedBox(width: 80.w, child: Text('SHORT', style: _h())),
              Expanded(flex: 2, child: Text('FEE GROUP', style: _h())),
              SizedBox(width: 60.w, child: Text('FINE', style: _h())),
              SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
            ],
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(child: Text('No fee types', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border.withValues(alpha: 0.5)),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['fee_id'] is int ? r['fee_id'] as int : int.tryParse(r['fee_id'].toString()) ?? 0;
                          final fine = '${r['feefineapplicable'] ?? 0}' == '1' ? 'Yes' : 'No';
                          return Container(
                            color: i.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                            child: Row(children: [
                              SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                              Expanded(flex: 3, child: Text(r['feedesc']?.toString() ?? '', style: _c())),
                              SizedBox(width: 80.w, child: Text(r['feeshort']?.toString() ?? '', style: _c())),
                              Expanded(flex: 2, child: Text(_fgName[r['fg_id']] ?? '', style: _c())),
                              SizedBox(width: 60.w, child: Text(fine, style: _c())),
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
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// SEMESTER
// ══════════════════════════════════════════════════════════════════════════
class _SemesterPanel extends StatefulWidget {
  const _SemesterPanel();
  @override
  State<_SemesterPanel> createState() => _SemesterPanelState();
}

class _SemesterPanelState extends State<_SemesterPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  final _short = TextEditingController();
  String? _type; // S = Semester, M = Monthly, Y = Yearly (null = not chosen)
  DateTime? _startDate;
  DateTime? _endDate;
  List<Map<String, dynamic>> _rows = [];
  int? _editId; // non-null while editing an existing row
  bool _loading = true, _saving = false;

  // Type flag ↔ label, shared by the Add dropdown and the table.
  static const _typeLabels = {'S': 'Semester', 'M': 'Monthly', 'Y': 'Yearly'};

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
      final res = await SupabaseService.fromSchema('semester')
          .select('*').eq('ins_id', _insId).eq('activestatus', 1);
      if (!mounted) return;
      // Order by the master-defined ordid, falling back to sem_id (also handles
      // schemas where the ordid column hasn't been added yet).
      final list = List<Map<String, dynamic>>.from(res as List)
        ..sort((a, b) {
          int key(Map<String, dynamic> r) => r['ordid'] is num
              ? (r['ordid'] as num).toInt()
              : (r['sem_id'] is num ? (r['sem_id'] as num).toInt() : 1 << 30);
          return key(a).compareTo(key(b));
        });
      setState(() {
        _rows = list;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['sem_id'] is int ? r['sem_id'] as int : int.tryParse(r['sem_id'].toString());
      _name.text = r['semname']?.toString() ?? '';
      _short.text = r['semshort']?.toString() ?? '';
      final t = r['semtype']?.toString().trim() ?? '';
      _type = _typeLabels.containsKey(t) ? t : 'S';
      _startDate = DateTime.tryParse(r['semstart']?.toString() ?? '');
      _endDate = DateTime.tryParse(r['semend']?.toString() ?? '');
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
      _short.clear();
      _type = null;
      _startDate = null;
      _endDate = null;
    });
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack(context, 'Enter a semester name.', AppColors.warning);
    if (_type == null) return _snack(context, 'Select a type.', AppColors.warning);
    if (_rows.any((r) => (r['semname']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() &&
        (r['sem_id']?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      return _snack(context, '"$name" already exists.', AppColors.warning);
    }
    if (_startDate != null && _endDate != null && _endDate!.isBefore(_startDate!)) {
      return _snack(context, 'End date must be on or after the start date.', AppColors.warning);
    }
    setState(() => _saving = true);
    try {
      final short = _short.text.trim();
      String? d(DateTime? v) => v?.toIso8601String().split('T').first;
      if (_editId != null) {
        await SupabaseService.saveSchemaRow('semester', {
          'semname': name,
          'semshort': short.isEmpty ? null : short,
          'semtype': _type,
          'semstart': d(_startDate),
          'semend': d(_endDate),
        }, pkCol: 'sem_id', pkVal: _editId!);
        if (mounted) _snack(context, 'Semester updated.', AppColors.success);
      } else {
        await SupabaseService.saveSchemaRow('semester', {
          'sem_id': await _nextId('semester', 'sem_id'),
          'semname': name,
          'semshort': short.isEmpty ? null : short,
          'semtype': _type,
          'semstart': d(_startDate),
          'semend': d(_endDate),
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Semester added.', AppColors.success);
      }
      _name.clear();
      _short.clear();
      _type = null;
      _startDate = null;
      _endDate = null;
      _editId = null;
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    if (!await _confirmDelete(context, 'semester')) return;
    try {
      await SupabaseService.deleteSchemaRow('semester', 'sem_id', id);
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  Widget _semDateField(DateTime? value, String hint, ValueChanged<DateTime> onPick) {
    final filled = value != null;
    return InkWell(
      borderRadius: BorderRadius.circular(8.r),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          firstDate: DateTime(now.year - 5),
          lastDate: DateTime(now.year + 6),
        );
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: _filledFieldDec(context, hint, filled: filled),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              filled ? _fmtDate(value) : hint,
              style: _fieldTextStyle(context).copyWith(
                color: filled ? AppColors.accent : AppColors.textLight,
                fontWeight: filled ? FontWeight.w600 : null,
              ),
            ),
            Icon(Icons.calendar_today_outlined, size: 14.sp, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320.w,
          child: _addCard(
            icon: 'calendar-1',
            title: _editId != null ? 'Edit Semester' : 'Add Semester',
            subtitle: 'collection cycles for the academic year',
            child: FocusTraversalGroup(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _lbl('Semester Name *'),
                SizedBox(height: 6.h),
                TextField(controller: _name, style: _fieldTextStyle(context).copyWith(color: _name.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), decoration: _filledFieldDec(context, 'Enter semester name', filled: _name.text.trim().isNotEmpty), onChanged: (_) => setState(() {}), onSubmitted: (_) => _add()),
                SizedBox(height: 16.h),
                _lbl('Short Name'),
                SizedBox(height: 6.h),
                TextField(controller: _short, style: _fieldTextStyle(context).copyWith(color: _short.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), decoration: _filledFieldDec(context, 'Enter short name', filled: _short.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                SizedBox(height: 16.h),
                _lbl('Type *'),
                SizedBox(height: 6.h),
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context),
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  decoration: _filledFieldDec(context, 'Select type', filled: _type != null),
                  items: _typeLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)))).toList(),
                  selectedItemBuilder: (context) => _typeLabels.entries.map((e) => Align(alignment: Alignment.centerLeft, child: Text(e.value, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
                  onChanged: (v) => setState(() => _type = v),
                ),
                SizedBox(height: 16.h),
                _lbl('Start Date'),
                SizedBox(height: 6.h),
                _semDateField(_startDate, 'Select start date', (dt) => setState(() => _startDate = dt)),
                SizedBox(height: 16.h),
                _lbl('End Date'),
                SizedBox(height: 6.h),
                _semDateField(_endDate, 'Select end date', (dt) => setState(() => _endDate = dt)),
                SizedBox(height: 18.h),
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
            )),
          ),
        ),
        SizedBox(width: 16.w),
        Expanded(
          child: _listCard(
            icon: 'calendar-1',
            title: 'Semesters',
            subtitle: 'all collection cycles in this institution',
            count: _rows.length,
            countLabel: 'terms',
            action: _importButton(context, title: 'Semester', tabIndex: 8, disabled: _saving, onReturn: _load),
            headerCells: [
              Expanded(child: Text('S NO.', style: _h())),
              Expanded(child: Text('SEMESTER NAME', style: _h())),
              Expanded(child: Text('SHORT', style: _h())),
              Expanded(child: Text('TYPE', style: _h())),
              Expanded(child: Text('START DATE', style: _h())),
              Expanded(child: Text('END DATE', style: _h())),
              Expanded(child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
            ],
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(child: Text('No semesters', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border.withValues(alpha: 0.5)),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['sem_id'] is int ? r['sem_id'] as int : int.tryParse(r['sem_id'].toString()) ?? 0;
                          final type = _typeLabels[r['semtype']?.toString().trim()] ?? 'Semester';
                          final sd = DateTime.tryParse(r['semstart']?.toString() ?? '');
                          final ed = DateTime.tryParse(r['semend']?.toString() ?? '');
                          return Container(
                            color: i.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                            child: Row(children: [
                              Expanded(child: Text('${i + 1}', style: _c())),
                              Expanded(child: Text(r['semname']?.toString() ?? '', style: _c())),
                              Expanded(child: Text(r['semshort']?.toString() ?? '', style: _c())),
                              Expanded(child: Text(type, style: _c())),
                              Expanded(child: Text(sd != null ? _fmtDate(sd) : '-', style: _c())),
                              Expanded(child: Text(ed != null ? _fmtDate(ed) : '-', style: _c())),
                              Expanded(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// CLASS FEE DEMAND
// ══════════════════════════════════════════════════════════════════════════

class _FeeLine {
  String? feeType;
  final amount = TextEditingController();
  bool applyAll = false; // ALL tick → feedemand.collectible (true/false)
  bool isCustom = false; // user-added via "Add Row" — fee type is a dropdown
  void dispose() => amount.dispose();
}

class _ClassFeeDemandPanel extends StatefulWidget {
  const _ClassFeeDemandPanel();
  @override
  State<_ClassFeeDemandPanel> createState() => _ClassFeeDemandPanelState();
}

class _ClassFeeDemandPanelState extends State<_ClassFeeDemandPanel> with AutomaticKeepAliveClientMixin {
  String? _cls;
  String? _sem;
  String? _admId; // null => all admission types
  DateTime? _due;
  bool _editMode = false; // false = New (blank grid), true = Edit (prefilled)
  final List<_FeeLine> _lines = [];

  List<String> _classNames = [];
  List<String> _semesters = [];
  // Semester name -> {start, end} dates, used to bound the Pay-On-or-Before picker.
  List<String> _feeTypeNames = [];
  List<Map<String, dynamic>> _admTypes = [];
  Map<String, String> _admName = {};
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
      // Retry the batch a couple of times so a dropped connection self-heals
      // instead of leaving the panel stuck/blank on the flaky network.
      List<dynamic> results = const [];
      for (var attempt = 0;; attempt++) {
        try {
          results = await Future.wait([
            // Page past PostgREST's 1000-row cap — an institution can have far
            // more class-fee definitions across all classes/sems/quotas, and Edit
            // needs every row to prefill. Ordered by cf_id for stable paging.
            SupabaseService.fetchAll(() => SupabaseService.fromSchema('classfeedemand').select('*').eq('activestatus', 1).order('cf_id')),
            SupabaseService.fromSchema('class').select('claname, ordid, cour_id').eq('ins_id', _insId).eq('activestatus', 1),
            SupabaseService.fromSchema('feetype').select('feedesc').eq('activestatus', 1),
            SupabaseService.fromSchema('admissiontype').select('adm_id, admname').eq('ins_id', _insId).eq('activestatus', 1),
            SupabaseService.fromSchema('semester').select('semname, semstart, semend').eq('ins_id', _insId).eq('activestatus', 1),
            SupabaseService.fromSchema('course').select('cour_id, ordid').eq('ins_id', _insId).eq('activestatus', 1),
          ]);
          break;
        } catch (_) {
          if (attempt >= 2) rethrow;
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from((results[0] as List).cast<Map<String, dynamic>>());
        // Order classes by course order, then class order (matches the
        // dashboard's class-wise ordering) instead of plain alphabetical.
        final courseOrd = <int, int>{
          for (final c in (results[5] as List))
            if ((c['cour_id'] as num?) != null)
              (c['cour_id'] as num).toInt(): (c['ordid'] as num?)?.toInt() ?? 9999,
        };
        final seenClass = <String>{};
        final classRows = (results[1] as List).where((e) {
          final nm = e['claname']?.toString().trim() ?? '';
          return nm.isNotEmpty && seenClass.add(nm);
        }).toList()
          ..sort((a, b) {
            final ca = courseOrd[(a['cour_id'] as num?)?.toInt()] ?? 9999;
            final cb = courseOrd[(b['cour_id'] as num?)?.toInt()] ?? 9999;
            if (ca != cb) return ca.compareTo(cb);
            final oa = (a['ordid'] as num?)?.toInt() ?? 9999;
            final ob = (b['ordid'] as num?)?.toInt() ?? 9999;
            return oa.compareTo(ob);
          });
        _classNames = classRows.map((e) => e['claname'].toString().trim()).toList();
        _feeTypeNames = (results[2] as List).map((e) => e['feedesc']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList()..sort();
        _admTypes = List<Map<String, dynamic>>.from((results[3] as List).cast<Map<String, dynamic>>());
        _semesters = (results[4] as List).map((e) => e['semname']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList()..sort();
        _admName = {for (final a in _admTypes) a['adm_id'].toString(): a['admname']?.toString() ?? ''};
        // Start with no class selected so the 'Select Class' placeholder shows.
        if (_cls != null) _reloadGrid();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  double get _total => _lines.fold(0.0, (s, l) => s + (double.tryParse(l.amount.text.trim()) ?? 0));


  String _amtStr(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// Rebuild the grid for the current Class / Semester / Admn Type selection:
  /// one row per active fee type, with AMOUNT (and ALL) pre-filled from any
  /// existing classfeedemand record that matches the selection. Fee types
  /// without an existing record show a blank amount. Called inside an existing
  /// setState whenever Class, Semester or Admn Type changes.
  void _loadLinesForSelection() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines.clear();
    // Existing records matching the current selection (class + sem + adm type).
    final existing = <String, Map<String, dynamic>>{};
    for (final r in _rows) {
      if ((r['cfclass']?.toString() ?? '') != _cls) continue;
      if (_sem != null && (r['cfterm']?.toString() ?? '') != _sem) continue;
      final admMatch = _admId == null
          ? r['admissiontype'] == null
          : r['admissiontype']?.toString() == _admId;
      if (!admMatch) continue;
      existing[r['cffeetype']?.toString() ?? ''] = r;
    }
    for (final ft in _feeTypeNames) {
      final line = _FeeLine()..feeType = ft;
      final r = existing[ft];
      if (r != null) {
        final amt = r['cfamount'];
        final n = amt is num ? amt : double.tryParse(amt?.toString() ?? '');
        if (n != null) line.amount.text = _amtStr(n);
        line.applyAll = r['collectible'] == true; // restore the ALL tick on edit
      }
      _lines.add(line);
    }
    if (_lines.isEmpty) {
      for (var i = 0; i < 5; i++) {
        _lines.add(_FeeLine());
      }
    }
  }

  /// Blank grid for NEW mode: one row per fee type, no amounts / ticks, nothing
  /// marked as existing (so nothing is locked).
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

  /// Rebuild the grid for the current selection per the active mode: New shows
  /// blank rows, Edit prefills from saved classfeedemand.
  void _reloadGrid() => _editMode ? _loadLinesForSelection() : _blankLines();

  Future<void> _save() async {
    if (_cls == null || _sem == null || _due == null) {
      return _snack(context, 'Select Class, Semester and Pay-On-or-Before date.', AppColors.warning);
    }
    final lines = _lines.where((l) => l.feeType != null && l.amount.text.trim().isNotEmpty).toList();
    if (lines.isEmpty) return _snack(context, 'Add at least one fee line.', AppColors.warning);
    final auth = context.read<AuthProvider>(); // capture before async gaps
    setState(() => _saving = true);
    int done = 0;
    int demCount = 0;
    final fails = <String>[];

    // Idempotent save: replace the template rows for THIS Class + Semester +
    // Admn Type so unticking/editing persists instead of leaving stale rows
    // (an insert-only save left the old collectible=true row behind, so the
    // ALL tick reappeared on reload).
    try {
      await SupabaseService.deleteSchemaRowsWhere('classfeedemand', {
        'cfclass': _cls!,
        'cfterm': _sem!,
        'admissiontype': _admId != null ? int.tryParse(_admId!) : null,
      });
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      return _snack(context, 'Save failed clearing old rows. ${friendlyError(e)}', AppColors.error);
    }

    for (final l in lines) {
      try {
        await SupabaseService.saveSchemaRow('classfeedemand', {
          'cf_id': await _nextId('classfeedemand', 'cf_id'),
          'cfclass': _cls,
          'cfterm': _sem,
          'cffeetype': l.feeType,
          'cfamount': double.tryParse(l.amount.text.trim()),
          'cfdduedate': _due!.toIso8601String().split('T').first,
          'admissiontype': _admId != null ? int.tryParse(_admId!) : null,
          'collectible': l.applyAll,
        });
        done++;
      } catch (e) {
        fails.add('${l.feeType}: ${friendlyError(e)}');
      }
    }
    // New mode: stage a tempfeedemand per student for EVERY fee line (→ Fee
    // Demand Approval → feedemand). Edit mode: push the edited amounts straight
    // into the students' existing feedemand rows instead of staging new ones.
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
      // When no demands were generated, make it explicit that no students
      // matched (the most common confusion) instead of a silent "Saved".
      final noStudents = !_editMode && demCount == 0;
      _snack(
        context,
        _editMode
            ? 'Updated $done fee line(s)${demCount > 0 ? ' • $demCount student demand(s) updated' : ''}.'
            : noStudents
                ? 'Saved $done fee line(s), but no students match this class${_admId != null ? ' + admission type' : ''} — no demands created.'
                : 'Saved $done fee line(s) • $demCount demand(s) sent for approval.',
        noStudents ? AppColors.warning : AppColors.success,
      );
      setState(() {
        for (final l in _lines) {
          l.dispose();
        }
        _lines
          ..clear()
          ..addAll(List.generate(5, (_) => _FeeLine()));
      });
    }
    await _load();
    if (fails.isNotEmpty && mounted) _snack(context, 'Saved $done, ${fails.length} failed. ${fails.first}', AppColors.error);
  }

  /// Stage a tempfeedemand row for every active student in the class × each fee
  /// line (→ Fee Demand Approval, isapproved=false). collectible = line.applyAll
  /// and is carried into feedemand by the approval trigger. temp_id/demno are
  /// filled by the schema's set_temp_id trigger.
  Future<int> _generateTempDemands(List<_FeeLine> lines, AuthProvider auth, {String? forClass}) async {
    final cls = forClass ?? _cls!;
    final insId = auth.insId ?? 1;
    final years = await SupabaseService.getYears(insId);
    final yr = years.isNotEmpty ? years.first : null;
    final yrId = yr != null ? int.tryParse(yr['yr_id'].toString()) ?? 0 : 0;
    final yrLabel = yr?['yrlabel']?.toString() ?? '';
    // Restrict to the chosen admission type (null = All).
    String? admName;
    if (_admId != null) {
      admName = _admTypes
          .firstWhere((a) => a['adm_id'].toString() == _admId, orElse: () => const {})['admname']
          ?.toString();
    }
    // Paged: a truncated roster here would silently skip students when
    // generating demands, leaving them unbilled with no error.
    final students = await SupabaseService.fetchAll(() {
      var q = SupabaseService.fromSchema('students')
          .select('stu_id, stuadmno, courname')
          .eq('ins_id', insId)
          .eq('stuclass', cls)
          .eq('activestatus', 1);
      if (admName != null && admName.isNotEmpty) q = q.eq('admname', admName);
      return q;
    });
    if (students.isEmpty) return 0;
    final rows = <Map<String, dynamic>>[];
    final due = _due!.toIso8601String().split('T').first;
    for (final s in students) {
      for (final l in lines) {
        final amt = double.tryParse(l.amount.text.trim()) ?? 0;
        rows.add({
          'ins_id': insId,
          'inscode': auth.inscode ?? '',
          'yr_id': yrId,
          'stu_id': s['stu_id'],
          'stuadmno': s['stuadmno'],
          'stuclass': cls,
          'courname': s['courname'],
          'demfeeyear': yrLabel,
          'demfeeterm': _sem,
          'demfeetype': l.feeType,
          'feeamount': amt,
          'balancedue': amt,
          'duedate': due,
          'createdby': auth.userName,
          'isapproved': false,
          'activestatus': 1,
          'collectible': l.applyAll,
        });
      }
    }
    if (rows.isEmpty) return 0;
    await SupabaseService.importSchemaRows('tempfeedemand',
        List<Map<String, dynamic>>.from(rows));
    return rows.length;
  }

  /// Edit mode: push the edited Class Fee Demand amounts into the students'
  /// existing UNPAID feedemand rows (same class + term + fee type, restricted to
  /// the chosen admission type). Recomputes balancedue = amount - concession -
  /// paid. Returns the number of student demand rows updated.
  Future<int> _propagateToFeedemand(List<_FeeLine> lines, AuthProvider auth) async {
    final insId = auth.insId ?? 1;
    // Resolve the admno set for the chosen admission type (null = all students).
    Set<String>? allowed;
    if (_admId != null) {
      final admName = _admTypes
          .firstWhere((a) => a['adm_id'].toString() == _admId, orElse: () => const {})['admname']
          ?.toString();
      final studs = await SupabaseService.fromSchema('students')
          .select('stuadmno')
          .eq('ins_id', insId)
          .eq('stuclass', _cls!)
          .eq('activestatus', 1)
          .eq('admname', admName ?? '');
      allowed = {for (final s in (studs as List)) (s as Map)['stuadmno'].toString()};
    }

    var updated = 0;
    for (final l in lines) {
      final amt = double.tryParse(l.amount.text.trim()) ?? 0;
      final res = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, stuadmno, conamount, paidamount')
          .eq('ins_id', insId)
          .eq('stuclass', _cls!)
          .eq('demfeeterm', _sem!)
          .eq('demfeetype', l.feeType!)
          .eq('paidstatus', 'U')
          .eq('activestatus', 1);
      for (final r in (res as List)) {
        final m = r as Map;
        if (allowed != null && !allowed.contains(m['stuadmno'].toString())) continue;
        final con = (m['conamount'] as num?)?.toDouble() ?? 0;
        final paid = (m['paidamount'] as num?)?.toDouble() ?? 0;
        final bal = (amt - con - paid) > 0 ? (amt - con - paid) : 0;
        await SupabaseService.rebuildDemand(
          (m['dem_id'] as num).toInt(),
          feeamount: amt,
          balancedue: bal,
          collectible: l.applyAll,
        );
        updated++;
      }
    }
    return updated;
  }

  /// Copy the current grid's fee lines (amounts + ALL ticks) to one or more
  /// other classes for the same Semester + Admn Type. Replaces each target's
  /// existing template rows (idempotent) and stages tempfeedemand for that
  /// class's students.
  Future<void> _copyFee() async {
    final lines = _lines.where((l) => l.feeType != null && l.amount.text.trim().isNotEmpty).toList();
    if (lines.isEmpty) return _snack(context, 'Enter fee amounts to copy.', AppColors.warning);
    if (_sem == null || _due == null) {
      return _snack(context, 'Select Semester and Pay-On-or-Before before copying.', AppColors.warning);
    }
    final targets = await _pickTargetClasses();
    if (targets == null || targets.isEmpty) return;

    final auth = context.read<AuthProvider>();
    setState(() => _saving = true);
    final due = _due!.toIso8601String().split('T').first;
    final admType = _admId != null ? int.tryParse(_admId!) : null;
    var classesDone = 0, demTotal = 0;
    final fails = <String>[];
    for (final cls in targets) {
      try {
        // Idempotent: clear this target's template rows for the selection.
        await SupabaseService.deleteSchemaRowsWhere('classfeedemand', {
          'cfclass': cls,
          'cfterm': _sem!,
          'admissiontype': admType,
        });
        for (final l in lines) {
          await SupabaseService.saveSchemaRow('classfeedemand', {
            'cf_id': await _nextId('classfeedemand', 'cf_id'),
            'cfclass': cls,
            'cfterm': _sem,
            'cffeetype': l.feeType,
            'cfamount': double.tryParse(l.amount.text.trim()),
            'cfdduedate': due,
            'admissiontype': admType,
            'collectible': l.applyAll,
          });
        }
        demTotal += await _generateTempDemands(lines, auth, forClass: cls);
        classesDone++;
      } catch (e) {
        fails.add('$cls: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    _snack(
      context,
      fails.isEmpty
          ? 'Copied fees to $classesDone class(es) • $demTotal demand(s) staged.'
          : 'Copied to $classesDone, ${fails.length} failed. ${fails.first}',
      fails.isEmpty ? AppColors.success : AppColors.error,
    );
    await _load();
  }

  /// Multi-select dialog of target classes (excludes the source class).
  Future<List<String>?> _pickTargetClasses() async {
    final picked = <String>{};
    return showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final options = _classNames.where((c) => c != _cls).toList();
          return AlertDialog(
            title: Text('Copy fees to classes', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
            content: SizedBox(
              width: 360.w,
              height: 360.h,
              child: options.isEmpty
                  ? Center(child: Text('No other classes', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                  : ListView(
                      children: [
                        Padding(
                          padding: EdgeInsets.only(bottom: 4.h),
                          child: Text('From ${_cls ?? ''} • ${_sem ?? ''} • ${_admId == null ? 'All' : (_admName[_admId] ?? '')}',
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
      await SupabaseService.deleteSchemaRow('classfeedemand', 'cf_id', id, soft: false);
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
    // Saved Demands panel removed — the creation form spans the full width.
    return _creation();
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
    return Container(
      // Outer white card wrapping the whole creation panel (mode buttons,
      // filter row, fee table, total/save) so it visually mirrors the
      // Saved Demands card on the right.
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        // Single top row — filters on the left, mode buttons on the right.
        // Each filter is an Expanded slot, mode buttons get fixed widths so
        // everything fits side-by-side without wrapping.
        Padding(
          padding: EdgeInsets.only(bottom: 10.h),
          child: FocusTraversalGroup(child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: DropdownButtonFormField<String>(
                initialValue: _cls,
                isExpanded: true,
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(12),
                elevation: 6,
                style: _fieldTextStyle(context),
                icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                decoration: _filledFieldDec(context, 'Select Class', filled: _cls != null),
                hint: Text('Select Class',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: MediaQuery.of(context).size.width <= 1366 ? 11 : 14)),
                items: _classNames.map((e) => DropdownMenuItem(value: e, child: Text(e, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis))).toList(),
                // Polished filled state: the chosen value reads bold + accent,
                // clearly distinct from the muted placeholder.
                selectedItemBuilder: (context) => _classNames.map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
                onChanged: (v) => setState(() { _cls = v; _reloadGrid(); }),
              )),
              SizedBox(width: 8.w),
              Expanded(child: DropdownButtonFormField<String>(
                initialValue: _sem,
                isExpanded: true,
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(12),
                elevation: 6,
                style: _fieldTextStyle(context),
                icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                decoration: _filledFieldDec(context, 'Select Semester', filled: _sem != null),
                hint: Text('Select Semester',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: MediaQuery.of(context).size.width <= 1366 ? 11 : 14)),
                items: _semesters.map((e) => DropdownMenuItem(value: e, child: Text(e, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis))).toList(),
                selectedItemBuilder: (context) => _semesters.map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
                onChanged: (v) => setState(() { _sem = v; _reloadGrid(); }),
              )),
              SizedBox(width: 8.w),
              Expanded(child: DropdownButtonFormField<String>(
                initialValue: _admId,
                isExpanded: true,
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(12),
                elevation: 6,
                style: _fieldTextStyle(context),
                icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                decoration: _filledFieldDec(context, 'All Admission Types', filled: _admId != null),
                hint: Text('All Admission Types',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: MediaQuery.of(context).size.width <= 1366 ? 11 : 14)),
                items: [
                  // 'all' is a sentinel → normalised to null (applies to every
                  // admission type). Null shows the "All Admission Types" hint.
                  DropdownMenuItem(value: 'all', child: Text('All Admission Types', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis)),
                  ..._admTypes.map((a) => DropdownMenuItem(value: a['adm_id'].toString(), child: Text(a['admname']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis))),
                ],
                selectedItemBuilder: (context) => [
                  Align(alignment: Alignment.centerLeft, child: Text('All Admission Types', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                  ..._admTypes.map((a) => Align(alignment: Alignment.centerLeft, child: Text(a['admname']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))),
                ],
                onChanged: (v) => setState(() { _admId = v == 'all' ? null : v; _reloadGrid(); }),
              )),
              SizedBox(width: 8.w),
              Expanded(child: FocusableTap(
                onTap: () async {
                  final now = DateTime.now();
                  // Due date is independent of the semester start/end dates.
                  final first = DateTime(now.year - 1);
                  final last = DateTime(now.year + 5);
                  final initial = (_due != null && !_due!.isBefore(first) && !_due!.isAfter(last))
                      ? _due!
                      : now;
                  final p = await showDatePicker(context: context, initialDate: initial, firstDate: first, lastDate: last);
                  if (p != null) setState(() => _due = p);
                },
                child: InputDecorator(
                  // InputDecorator doesn't render hintText when a child widget is
                  // present, so we render the placeholder text inline ourselves.
                  decoration: _filledFieldDec(context, '', filled: _due != null),
                  child: Text(
                    _due == null ? 'Pay On or Before' : _fmt(_due!),
                    style: _due == null
                        ? TextStyle(fontSize: 13.sp, color: AppColors.textPrimary.withValues(alpha: 0.6))
                        : _fieldTextStyle(context).copyWith(color: AppColors.accent),
                  ),
                ),
              )),
              SizedBox(width: 10.w),
              // Action buttons are mouse-only — kept out of Tab so the key
              // moves only through the input fields (dropdowns + amounts).
              ExcludeFocus(child: _modeButton('New', Icons.add, !_editMode, () => setState(() {
                _editMode = false;
                _reloadGrid();
              }))),
              SizedBox(width: 8.w),
              ExcludeFocus(child: _modeButton('Edit', Icons.edit, _editMode, () => setState(() {
                _editMode = true;
                _reloadGrid();
              }))),
              SizedBox(width: 8.w),
              ExcludeFocus(
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _copyFee,
                  icon: const Icon(Icons.copy_all, size: 15),
                  label: const Text('Copy Fee'),
                ),
              ),
              SizedBox(width: 8.w),
              ExcludeFocus(
                child: _importButton(context, title: 'Class Fee Demand', tabIndex: 7, disabled: _saving, onReturn: _load),
              ),
            ],
          )),
        ),
        SizedBox(height: 4.h),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12.r), border: Border.all(color: AppColors.border.withValues(alpha: 0.6))),
            child: Column(children: [
              Container(color: AppColors.tableHeadBg, padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h), child: Row(children: [
                Expanded(flex: 3, child: Text('FEE TYPE', style: _h())),
                SizedBox(width: 140.w, child: Text('AMOUNT', style: _h())),
                SizedBox(width: 70.w, child: Text('ALL', textAlign: TextAlign.center, style: _h())),
                SizedBox(width: 44.w, child: Text('', style: _h())),
              ])),
              Expanded(child: FocusTraversalGroup(child: ListView.separated(itemCount: _lines.length, separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.4)), itemBuilder: (_, i) {
                final l = _lines[i];
                return Container(color: i.isEven ? Colors.white : AppColors.surface, padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 5.h), child: Row(children: [
                  Expanded(flex: 3, child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 10.h),
                    child: l.isCustom
                        ? DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: l.feeType,
                              isExpanded: true,
                              isDense: true,
                              dropdownColor: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              elevation: 6,
                              icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                              hint: Text('Select fee type', style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary.withValues(alpha: 0.5))),
                              items: _feeTypeNames.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
                              onChanged: (v) => setState(() => l.feeType = v),
                            ),
                          )
                        : Text(l.feeType ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                  )),
                  SizedBox(width: 8.w),
                  SizedBox(width: 132.w, child: TextField(controller: l.amount, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: l.amount.text.trim().isNotEmpty ? AppColors.accent : AppColors.textPrimary), decoration: _dec('', filled: l.amount.text.trim().isNotEmpty), onChanged: (_) => setState(() {}))),
                  SizedBox(width: 70.w, child: Center(child: Tooltip(message: 'Tick = collectible from all students (feedemand.collectible = true)', child: ExcludeFocus(child: Checkbox(value: l.applyAll, activeColor: AppColors.accent, visualDensity: VisualDensity.compact, onChanged: (v) => setState(() => l.applyAll = v ?? false)))))),
                  SizedBox(width: 44.w, child: l.isCustom
                      ? IconButton(
                          tooltip: 'Remove row',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() { l.dispose(); _lines.removeAt(i); }),
                          icon: const AppIcon('trash', size: 16, color: AppColors.error),
                        )
                      : null),
                ]));
              }))),
              Divider(height: 1.h, color: AppColors.border),
              Padding(padding: EdgeInsets.all(12.w), child: Row(children: [
                OutlinedButton.icon(
                  onPressed: () => setState(() => _lines.add(_FeeLine()..isCustom = true)),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Row'),
                ),
                SizedBox(width: 12.w),
                Flexible(child: Text('Tick ALL to make a fee collectible from every student', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.sp, color: AppColors.textLight))),
                const Spacer(),
                Text('Total  ', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                Text(_total.toStringAsFixed(2), style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
                SizedBox(width: 16.w),
                ElevatedButton.icon(onPressed: _saving ? null : _save, icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save, size: 16), label: const Text('Save'), style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white)),
              ])),
            ]),
          ),
        ),
      ],
      ),
    );
  }

  // Saved Demands panel — currently hidden (not rendered in build); kept so it
  // can be restored if needed.
  // ignore: unused_element
  Widget _existing() {
    final filtered = _cls == null ? _rows : _rows.where((r) => (r['cfclass']?.toString() ?? '') == _cls).toList();
    return _listCard(
      icon: 'category',
      title: 'Saved Demands',
      subtitle: 'class-wise fee demands for the academic year',
      count: filtered.length,
      countLabel: 'items',
      action: _importButton(context, title: 'Class Fee Demand', tabIndex: 7, disabled: _saving, onReturn: _load),
      headerCells: [
        SizedBox(width: 70.w, child: Text('TERM', style: _h())),
        Expanded(flex: 2, child: Text('FEE TYPE', style: _h())),
        SizedBox(width: 70.w, child: Text('AMT', style: _h())),
        Expanded(child: Text('ADM', style: _h())),
        SizedBox(width: 44.w, child: Text('', style: _h())),
      ],
      body: filtered.isEmpty
          ? Center(child: Text('No fee demands', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
          : ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border.withValues(alpha: 0.5)),
              itemBuilder: (_, i) {
                final r = filtered[i];
                final id = r['cf_id'] is int ? r['cf_id'] as int : int.tryParse(r['cf_id'].toString()) ?? 0;
                return Container(
                  color: i.isEven ? Colors.white : AppColors.surface,
                  padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  child: Row(children: [
                    SizedBox(width: 70.w, child: Text(r['cfterm']?.toString() ?? '', style: _c())),
                    Expanded(flex: 2, child: Text(r['cffeetype']?.toString() ?? '', style: _c())),
                    SizedBox(width: 70.w, child: Text(r['cfamount']?.toString() ?? '', style: _c())),
                    Expanded(child: Text(_admName['${r['admissiontype'] ?? ''}'] ?? 'All', style: _c())),
                    SizedBox(width: 44.w, child: Center(child: InkWell(onTap: () => _delete(id), child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 15, color: AppColors.error))))),
                  ]),
                );
              },
            ),
    );
  }
}

// ── Demand No sequence ─────────────────────────────────────────────────────
/// Single institution-wide demand-number (demno) sequence, stored in the shared
/// `sequence` table with actname='DEMNO', fg_id NULL. Once configured, new fee
/// demands emit <prefix><padded seqcurno+1> (e.g. DM00001) instead of the
/// default DExx/NNNNN — see migrations/add_demno_sequence.sql (the set_dem_id /
/// set_temp_id triggers read this row).
class _DemandSequencePanel extends StatefulWidget {
  const _DemandSequencePanel();
  @override
  State<_DemandSequencePanel> createState() => _DemandSequencePanelState();
}

class _DemandSequencePanelState extends State<_DemandSequencePanel> with AutomaticKeepAliveClientMixin {
  bool _loading = true, _saving = false;
  Map<String, dynamic>? _seq;
  final _prefixCtrl = TextEditingController(text: 'DM');
  final _widthCtrl = TextEditingController(text: '5');
  final _startCtrl = TextEditingController(text: '1');

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _prefixCtrl.dispose();
    _widthCtrl.dispose();
    _startCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await SupabaseService.fromSchema('sequence')
          .select()
          .eq('ins_id', insId)
          .eq('actname', 'DEMNO')
          .eq('activestatus', 1)
          .order('seq_id')
          .limit(1)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _seq = res == null ? null : Map<String, dynamic>.from(res);
        if (_seq != null) {
          _prefixCtrl.text = _seq!['seqprefix']?.toString() ?? '';
          _widthCtrl.text = ((_seq!['seqwidth'] as num?)?.toInt() ?? 5).toString();
          _startCtrl.text = ((_seq!['seqstart'] as num?)?.toInt() ?? 1).toString();
        }
        _loading = false;
      });
    } catch (e) {
      debugPrint('DEMNO load: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _width => (int.tryParse(_widthCtrl.text.trim()) ?? 5).clamp(1, 9);
  int get _start => int.tryParse(_startCtrl.text.trim()) ?? 1;
  String get _preview => '${_prefixCtrl.text.trim().toUpperCase()}${_start.toString().padLeft(_width, '0')}';

  Future<void> _save() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    var prefix = _prefixCtrl.text.trim().toUpperCase();
    if (prefix.isEmpty) {
      _snack(context, 'Enter a prefix.', AppColors.warning);
      return;
    }
    if (prefix.length > 15) prefix = prefix.substring(0, 15);
    final width = _width;
    final start = _start.clamp(1, 999999999);
    setState(() => _saving = true);
    try {
      final sequid0 = '$prefix${start.toString().padLeft(width, '0')}';
      final sequid = sequid0.length > 18 ? sequid0.substring(0, 18) : sequid0;
      // Only ever ONE demand sequence per institution: reuse the existing row
      // if there is one (even if it wasn't loaded into state), else insert.
      int? seqId = (_seq?['seq_id'] as num?)?.toInt();
      if (seqId == null) {
        final existing = await SupabaseService.fromSchema('sequence')
            .select('seq_id')
            .eq('ins_id', insId)
            .eq('actname', 'DEMNO')
            .eq('activestatus', 1)
            .order('seq_id')
            .limit(1)
            .maybeSingle();
        seqId = (existing?['seq_id'] as num?)?.toInt();
      }
      if (seqId != null) {
        await SupabaseService.saveSchemaRow('sequence', {
          'seqprefix': prefix,
          'seqname': prefix,
          'seqwidth': width,
          'seqstart': start,
          'sequid': sequid,
        }, pkCol: 'seq_id', pkVal: seqId);
      } else {
        final year = await _currentYear(insId);
        await SupabaseService.saveSchemaRow('sequence', {
          'ins_id': insId,
          'mod_id': 0,
          'yr_id': year?['yr_id'] ?? 0,
          'yrlabel': year?['yrlabel']?.toString() ?? '',
          'actname': 'DEMNO',
          'seqname': prefix,
          'isprefix': 'Y',
          'seqprefix': prefix,
          'seqstart': start,
          'seqwidth': width,
          'sequid': sequid,
          'seqcurno': start - 1, // first demand number == start
          'fg_id': null,
        });
      }
      if (mounted) {
        _snack(context, 'Demand No sequence saved.', AppColors.success);
        _load();
      }
    } catch (e) {
      if (mounted) _snack(context, friendlyError(e), AppColors.error);
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: EdgeInsets.only(top: 8.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 340.w, child: _form()),
          SizedBox(width: 16.w),
          Expanded(child: _info()),
        ],
      ),
    );
  }

  Widget _form() {
    final exists = _seq != null;
    return Container(
      padding: EdgeInsets.all(20.w),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10.r), border: Border.all(color: AppColors.border)),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Icon(Icons.tag_rounded, color: AppColors.accent, size: 20.sp),
              SizedBox(width: 8.w),
              Expanded(child: Text('Demand No Sequence', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary))),
            ]),
            SizedBox(height: 4.h),
            Text('one demand-number sequence for the whole institution', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
            SizedBox(height: 20.h),
            _lbl('Prefix *'),
            SizedBox(height: 6.h),
            TextField(
              controller: _prefixCtrl,
              textCapitalization: TextCapitalization.characters,
              style: _fieldTextStyle(context).copyWith(color: _prefixCtrl.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
              decoration: _filledFieldDec(context, 'e.g. DM', filled: _prefixCtrl.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: 16.h),
            _lbl('Number Width'),
            SizedBox(height: 6.h),
            TextField(
              controller: _widthCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: _fieldTextStyle(context).copyWith(color: _widthCtrl.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
              decoration: _filledFieldDec(context, '5', filled: _widthCtrl.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: 16.h),
            _lbl(exists ? 'Start Number (locked)' : 'Start Number'),
            SizedBox(height: 6.h),
            TextField(
              controller: _startCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              enabled: !exists, // the start is locked once the counter is running
              style: _fieldTextStyle(context).copyWith(color: _startCtrl.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
              decoration: _filledFieldDec(context, '1', filled: _startCtrl.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
            ),
            SizedBox(height: 12.h),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
              decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8.r), border: Border.all(color: AppColors.accent.withValues(alpha: 0.25))),
              child: Row(children: [
                Text('Preview:  ', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                Expanded(child: Text(_prefixCtrl.text.trim().isEmpty ? '—' : _preview, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w800, color: AppColors.accent), overflow: TextOverflow.ellipsis)),
              ]),
            ),
            SizedBox(height: 18.h),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(exists ? Icons.save_rounded : Icons.add, size: 16),
                label: Text(exists ? 'Update' : 'Create'),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Right panel — the configured demand sequence, as a table matching the
  /// Payment Sequence tab.
  Widget _info() {
    final s = _seq;
    final width = (s?['seqwidth'] as num?)?.toInt() ?? 5;
    final cur = (s?['seqcurno'] as num?)?.toInt() ?? 0;
    final start = (s?['seqstart'] as num?)?.toInt() ?? 1;
    final prefix = s?['seqprefix']?.toString() ?? '';
    final preview = '$prefix${start.toString().padLeft(width, '0')}';
    final count = s == null ? 0 : 1;
    TextStyle h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
    TextStyle c() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);
    return Container(
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10.r), border: Border.all(color: AppColors.border)),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4.w, right: 4.w, bottom: 10.h),
            child: Row(children: [
              Icon(Icons.tag_rounded, color: AppColors.accent, size: 18.sp),
              SizedBox(width: 8.w),
              Text('Demand Sequences', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              SizedBox(width: 10.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8.r)),
                child: Text('$count sequence${count == 1 ? '' : 's'}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
              ),
              const Spacer(),
            ]),
          ),
          Expanded(
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8.r), border: Border.all(color: AppColors.border)),
              child: Column(
                children: [
                  Container(
                    color: AppColors.tableHeadBg,
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    child: Row(children: [
                      Expanded(flex: 3, child: Text('SEQUENCE', style: h())),
                      SizedBox(width: 90.w, child: Text('PREFIX', style: h())),
                      SizedBox(width: 120.w, child: Text('PREVIEW', style: h())),
                      SizedBox(width: 80.w, child: Text('CURRENT', style: h())),
                    ]),
                  ),
                  Expanded(
                    child: s == null
                        ? Center(child: Text('No demand sequence yet', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                        : ListView(
                            children: [
                              Container(
                                color: Colors.white,
                                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                                child: Row(children: [
                                  Expanded(flex: 3, child: Text('Demand No', style: c(), overflow: TextOverflow.ellipsis)),
                                  SizedBox(width: 90.w, child: Text(prefix, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.primary))),
                                  SizedBox(width: 120.w, child: Text(preview, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                                  SizedBox(width: 80.w, child: Text('$cur', style: c())),
                                ]),
                              ),
                            ],
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
