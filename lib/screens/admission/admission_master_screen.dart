import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/admission_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/master_crud_panel.dart';
import '../../widgets/pill_tab.dart';
import '../admin/master_import_screen.dart';

/// Admission Master — manage the admission lookups (Community + Reg No)
/// used by the admission form. Both tables live in `public` (single-institution
/// app, consistent with the other moved masters).
class AdmissionMasterScreen extends StatefulWidget {
  const AdmissionMasterScreen({super.key});

  @override
  State<AdmissionMasterScreen> createState() => _AdmissionMasterScreenState();
}

class _AdmissionMasterScreenState extends State<AdmissionMasterScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _tabLabels = ['Community', 'Admission No', 'Concession'];
  static const _tabIcons = ['people', 'tag', 'discount-shape'];

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
        // Pill-style tabs matching Fee Master / Master Data / Reports.
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
              MasterCrudPanel(
                table: 'community',
                idCol: 'com_id',
                nameCol: 'comname',
                title: 'Community',
                icon: 'people',
                countLabel: 'communities',
              ),
              _RegNoPanel(),
              _ConcessionPanelWithImport(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Term Periods — name + from/to dates.
class TermPanel extends StatefulWidget {
  const TermPanel({super.key});

  @override
  State<TermPanel> createState() => TermPanelState();
}

class TermPanelState extends State<TermPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  DateTime? _from;
  DateTime? _to;
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _saving = false;
  int? _editingId;

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

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await AdmissionService.getMasterRows('termperiod', 'tp_id', inSchema: true);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  String _fmt(DateTime? d) => d == null
      ? '-'
      : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  String? _iso(DateTime? d) => d?.toIso8601String().split('T').first;

  Future<void> _pickDate(bool from) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (from ? _from : _to) ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) setState(() => from ? _from = picked : _to = picked);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('Enter a term name.', AppColors.warning);
      return;
    }
    final auth = context.read<AuthProvider>();
    setState(() => _saving = true);
    try {
      if (_editingId != null) {
        await AdmissionService.updateMasterRow('termperiod', 'tp_id', _editingId!, {
          'termname': name,
          'fromdate': _iso(_from),
          'todate': _iso(_to),
        }, inSchema: true);
        _snack('Term updated.', AppColors.success);
      } else {
        final id = await AdmissionService.nextMasterId('termperiod', 'tp_id', inSchema: true);
        await AdmissionService.addMasterRow('termperiod', {
          'tp_id': id,
          'termname': name,
          'fromdate': _iso(_from),
          'todate': _iso(_to),
          'ins_id': auth.insId,
          'activestatus': 1,
          'createdby': auth.userName,
        }, inSchema: true);
        _snack('Term added.', AppColors.success);
      }
      _name.clear();
      _from = null;
      _to = null;
      _editingId = null;
      await _load();
    } catch (e) {
      _snack('Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Term'),
        content: Text('Remove "$name"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AdmissionService.deleteMasterRow('termperiod', 'tp_id', id, inSchema: true);
      _snack('Removed.', AppColors.success);
      await _load();
    } catch (e) {
      _snack('Delete failed. ${friendlyError(e)}', AppColors.error);
    }
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editingId = r['tp_id'] is int ? r['tp_id'] as int : int.tryParse(r['tp_id'].toString());
      _name.text = r['termname']?.toString() ?? '';
      _from = DateTime.tryParse(r['fromdate']?.toString() ?? '');
      _to = DateTime.tryParse(r['todate']?.toString() ?? '');
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingId = null;
      _name.clear();
      _from = null;
      _to = null;
    });
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

  Widget _dateButton(String label, DateTime? value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: _filledFieldDec(label),
        child: Text(value == null ? label : _fmt(value),
            style: TextStyle(
                fontSize: 13.sp,
                color: value == null
                    ? AppColors.textPrimary.withValues(alpha: 0.6)
                    : AppColors.textPrimary)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 340.w, child: _form()),
        SizedBox(width: 16.w),
        Expanded(child: _list()),
      ],
    );
  }

  Widget _form() {
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
          Row(children: [
            const AppIcon('calendar-1', size: 18, color: AppColors.accent),
            SizedBox(width: 8.w),
            Text('${_editingId != null ? 'Edit' : 'Add'} Term Period',
                style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ]),
          SizedBox(height: 20.h),
          Text('Term Name *', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black)),
          SizedBox(height: 6.h),
          TextField(controller: _name, style: TextStyle(fontSize: 13.sp), decoration: _filledFieldDec('Enter term name')),
          SizedBox(height: 16.h),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('From Date *', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black)),
                    SizedBox(height: 6.h),
                    _dateButton('Select from date', _from, () => _pickDate(true)),
                  ],
                ),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('To Date *', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black)),
                    SizedBox(height: 6.h),
                    _dateButton('Select to date', _to, () => _pickDate(false)),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 18.h),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(_editingId != null ? Icons.save : Icons.add, size: 16),
                  label: Text(_editingId != null ? 'Update' : 'Add'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
                ),
              ),
              if (_editingId != null) ...[
                SizedBox(width: 8.w),
                OutlinedButton(onPressed: _saving ? null : _cancelEdit, child: const Text('Cancel')),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _list() {
    TextStyle h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
    final innerTable = Container(
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
            child: Row(
              children: [
                Expanded(flex: 3, child: Text('TERM', style: h())),
                SizedBox(width: 110.w, child: Text('FROM DATE', style: h())),
                SizedBox(width: 110.w, child: Text('TO DATE', style: h())),
                SizedBox(width: 80.w, child: Text('', style: h())),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(child: Text('No term periods', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['tp_id'] is int ? r['tp_id'] as int : int.tryParse(r['tp_id'].toString()) ?? 0;
                          final name = r['termname']?.toString() ?? '';
                          final from = r['fromdate'] != null ? DateTime.tryParse(r['fromdate'].toString()) : null;
                          final to = r['todate'] != null ? DateTime.tryParse(r['todate'].toString()) : null;
                          TextStyle c() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);
                          return Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                            child: Row(
                              children: [
                                Expanded(flex: 3, child: Text(name, style: c())),
                                SizedBox(width: 110.w, child: Text(_fmt(from), style: c())),
                                SizedBox(width: 110.w, child: Text(_fmt(to), style: c())),
                                SizedBox(
                                  width: 80.w,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      InkWell(
                                        onTap: () => _edit(r),
                                        borderRadius: BorderRadius.circular(6.r),
                                        child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('edit-2', size: 16, color: AppColors.primary)),
                                      ),
                                      SizedBox(width: 8.w),
                                      InkWell(
                                        onTap: () => _delete(id, name),
                                        borderRadius: BorderRadius.circular(6.r),
                                        child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 16, color: AppColors.error)),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );

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
              const AppIcon('calendar-1', size: 18, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('Term Periods',
                  style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text('${_rows.length} terms',
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
              ),
              const Spacer(),
            ]),
          ),
          Expanded(child: innerTable),
        ],
      ),
    );
  }
}

/// Register Number Sequencing — richer master (name, prefix/suffix, range, width).
class _RegNoPanel extends StatefulWidget {
  const _RegNoPanel();

  @override
  State<_RegNoPanel> createState() => _RegNoPanelState();
}

class _RegNoPanelState extends State<_RegNoPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  final _affix = TextEditingController();
  final _start = TextEditingController(text: '1');
  final _end = TextEditingController();
  final _width = TextEditingController(text: '4');
  final _division = TextEditingController();
  String _mode = 'Prefix';
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _saving = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _affix, _start, _end, _width, _division]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await AdmissionService.getMasterRows('regnoseq', 'rns_id');
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('Enter a name.', AppColors.warning);
      return;
    }
    final auth = context.read<AuthProvider>();
    setState(() => _saving = true);
    try {
      final id = await AdmissionService.nextMasterId('regnoseq', 'rns_id');
      await AdmissionService.addMasterRow('regnoseq', {
        'rns_id': id,
        'rnsname': name,
        'rnsmode': _mode == 'Prefix' ? 'P' : 'S',
        'rnsaffix': _affix.text.trim().isEmpty ? null : _affix.text.trim(),
        'rnsstart': int.tryParse(_start.text.trim()),
        'rnsend': _end.text.trim().isEmpty ? null : int.tryParse(_end.text.trim()),
        'rnswidth': int.tryParse(_width.text.trim()),
        'rnscurrent': 0,
        'division': _division.text.trim().isEmpty ? null : _division.text.trim(),
        'ins_id': auth.insId,
        'activestatus': 1,
        'createdby': auth.userName,
      });
      for (final c in [_name, _affix, _division]) {
        c.clear();
      }
      _start.text = '1';
      _width.text = '4';
      _end.clear();
      setState(() => _mode = 'Prefix');
      _snack('Admission sequence added.', AppColors.success);
      await _load();
    } catch (e) {
      _snack('Add failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Admission Sequence'),
        content: Text('Remove "$name"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AdmissionService.deleteMasterRow('regnoseq', 'rns_id', id);
      _snack('Removed.', AppColors.success);
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

  Widget _lbl(String text) => Text(text, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 340.w, child: _form()),
        SizedBox(width: 16.w),
        Expanded(child: _list()),
      ],
    );
  }

  Widget _form() {
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
          Row(children: [
            const AppIcon('tag', size: 18, color: AppColors.accent),
            SizedBox(width: 8.w),
            Text('Admission Number Sequencing',
                style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ]),
          SizedBox(height: 20.h),
          _lbl('Name *'),
          SizedBox(height: 6.h),
          TextField(controller: _name, style: TextStyle(fontSize: 13.sp), decoration: _filledFieldDec('Enter name')),
          SizedBox(height: 16.h),
          _lbl('Mode'),
          SizedBox(height: 6.h),
          DropdownButtonFormField<String>(
            initialValue: _mode,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            decoration: _filledFieldDec('Select mode'),
            items: const [
              DropdownMenuItem(value: 'Prefix', child: Text('Prefix')),
              DropdownMenuItem(value: 'Suffix', child: Text('Suffix')),
            ],
            onChanged: (v) => setState(() => _mode = v ?? 'Prefix'),
          ),
          SizedBox(height: 16.h),
          _lbl('Prefix / Suffix value'),
          SizedBox(height: 6.h),
          TextField(controller: _affix, style: TextStyle(fontSize: 13.sp), decoration: _filledFieldDec('e.g. ADM/')),
          SizedBox(height: 16.h),
          Row(
            children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _lbl('Start No'),
                  SizedBox(height: 6.h),
                  TextField(controller: _start, keyboardType: TextInputType.number, style: TextStyle(fontSize: 13.sp), decoration: _filledFieldDec('1')),
                ]),
              ),
              SizedBox(width: 8.w),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _lbl('End No'),
                  SizedBox(height: 6.h),
                  TextField(controller: _end, keyboardType: TextInputType.number, style: TextStyle(fontSize: 13.sp), decoration: _filledFieldDec('—')),
                ]),
              ),
              SizedBox(width: 8.w),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _lbl('Width'),
                  SizedBox(height: 6.h),
                  TextField(controller: _width, keyboardType: TextInputType.number, style: TextStyle(fontSize: 13.sp), decoration: _filledFieldDec('4')),
                ]),
              ),
            ],
          ),
          SizedBox(height: 16.h),
          _lbl('Division'),
          SizedBox(height: 6.h),
          TextField(controller: _division, style: TextStyle(fontSize: 13.sp), maxLines: 2, decoration: _filledFieldDec('Division description')),
          SizedBox(height: 18.h),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _add,
              icon: _saving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.add, size: 16),
              label: const Text('Add'),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    TextStyle h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
    final innerTable = Container(
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
            child: Row(
              children: [
                Expanded(flex: 3, child: Text('NAME', style: h())),
                SizedBox(width: 64.w, child: Text('PRE/SUF', style: h())),
                SizedBox(width: 64.w, child: Text('AFFIX', style: h())),
                SizedBox(width: 56.w, child: Text('START', style: h())),
                SizedBox(width: 56.w, child: Text('END', style: h())),
                SizedBox(width: 36.w, child: Text('W', style: h())),
                SizedBox(width: 44.w, child: Text('', style: h())),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(child: Text('No register sequences', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['rns_id'] is int ? r['rns_id'] as int : int.tryParse(r['rns_id'].toString()) ?? 0;
                          final name = r['rnsname']?.toString() ?? '';
                          final mode = (r['rnsmode']?.toString() ?? 'P') == 'P' ? 'Prefix' : 'Suffix';
                          TextStyle c() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);
                          return Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                            child: Row(
                              children: [
                                Expanded(flex: 3, child: Text(name, style: c())),
                                SizedBox(width: 64.w, child: Text(mode, style: c())),
                                SizedBox(width: 64.w, child: Text(r['rnsaffix']?.toString() ?? '-', style: c())),
                                SizedBox(width: 56.w, child: Text(r['rnsstart']?.toString() ?? '-', style: c())),
                                SizedBox(width: 56.w, child: Text(r['rnsend']?.toString() ?? '-', style: c())),
                                SizedBox(width: 36.w, child: Text(r['rnswidth']?.toString() ?? '-', style: c())),
                                SizedBox(
                                  width: 44.w,
                                  child: Center(
                                    child: InkWell(
                                      onTap: () => _delete(id, name),
                                      borderRadius: BorderRadius.circular(6.r),
                                      child: Padding(padding: EdgeInsets.all(4.w), child: const AppIcon('trash', size: 16, color: AppColors.error)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );

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
              const AppIcon('tag', size: 18, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('Register Sequences',
                  style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text('${_rows.length} sequences',
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
              ),
              const Spacer(),
            ]),
          ),
          Expanded(child: innerTable),
        ],
      ),
    );
  }
}

/// Concession tab — combines inline add/edit (MasterCrudPanel) with the
/// Master Data → Concession Excel import flow, toggled by a top-right button.
class _ConcessionPanelWithImport extends StatefulWidget {
  const _ConcessionPanelWithImport();
  @override
  State<_ConcessionPanelWithImport> createState() => _ConcessionPanelWithImportState();
}

class _ConcessionPanelWithImportState extends State<_ConcessionPanelWithImport> {
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
                Text('Import Concession',
                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ],
            ),
          ),
          const Expanded(child: MasterImportScreen(initialTabIndex: 4, showInternalTabs: false)),
        ],
      );
    }
    return MasterCrudPanel(
      table: 'concessioncategory',
      idCol: 'con_id',
      nameCol: 'condesc',
      title: 'Concession',
      icon: 'discount-shape',
      countLabel: 'concessions',
      inSchema: true,
      ordidCol: 'ordid',
      onImport: () => setState(() => _importing = true),
    );
  }
}

