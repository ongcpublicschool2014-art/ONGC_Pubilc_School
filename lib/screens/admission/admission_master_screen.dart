import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/admission_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/master_crud_panel.dart';
import '../../widgets/pill_tab.dart';

/// Admission Master — manage the admission lookups (Admission Type, Quota,
/// Community) used by the admission form. Each tab is a simple add/list/delete
/// over its per-schema master table.
///
/// Page shell follows admission-master-design.md § 1:
///   - Plain `Column` — no outer `Padding`, no `AppCard.decoration()`. The
///     Dashboard shell provides the page-level breathing room.
///   - `PillTab` row at the top (vertical: 8 padding), 6.h gap, then the
///     `TabBarView` fills the rest of the screen.
///
/// Tab order: the spec describes Community / Admission No / Concession.
/// The two extra tabs (Admission Type, Quota) preserve existing CRUD
/// functionality and follow section 7 ("When adding a new tab").
class AdmissionMasterScreen extends StatefulWidget {
  const AdmissionMasterScreen({super.key});

  @override
  State<AdmissionMasterScreen> createState() => _AdmissionMasterScreenState();
}

class _AdmissionMasterScreenState extends State<AdmissionMasterScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // Order matches the spec's primary trio first, then the project-specific
  // extras (Admission Type / Quota).
  static const _tabLabels = [
    'Admission Type', 'Quota', 'Community', 'Concession', 'Division', 'Admission No',
  ];
  static const _tabIcons = [
    'user-tick', 'ticket', 'people', 'discount-shape', 'diagram', 'tag',
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
              MasterCrudPanel(table: 'admissiontype', idCol: 'adm_id', nameCol: 'admname', title: 'Admission Type', icon: 'user-tick', countLabel: 'types', importTabIndex: 0),
              MasterCrudPanel(table: 'quota', idCol: 'quo_id', nameCol: 'quoname', title: 'Quota', icon: 'ticket', countLabel: 'quotas', importTabIndex: 1),
              MasterCrudPanel(table: 'community', idCol: 'com_id', nameCol: 'comname', title: 'Community', icon: 'people', countLabel: 'communities', importTabIndex: 9),
              MasterCrudPanel(table: 'concessioncategory', idCol: 'con_id', nameCol: 'condesc', title: 'Concession', icon: 'discount-shape', countLabel: 'concessions', importTabIndex: 6, includeCreatedBy: false),
              MasterCrudPanel(table: 'division', idCol: 'div_id', nameCol: 'divname', title: 'Division', icon: 'diagram', countLabel: 'divisions'),
              _RegNoPanel(),
            ],
          ),
        ),
      ],
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
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _width = TextEditingController();
  // Division is chosen from the Division master (dropdown), not free text.
  String? _divisionVal;
  List<Map<String, dynamic>> _divisionRows = [];
  String? _mode; // null = not chosen (shows 'Select mode' placeholder)
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
    for (final c in [_name, _affix, _start, _end, _width]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await AdmissionService.getRegSequences();
    // Division options come from the Division master. Guard so a missing
    // division table (migration not yet run) doesn't break the sequence list.
    List<Map<String, dynamic>> divs = [];
    try {
      divs = await AdmissionService.getMasterRows('division', 'div_id');
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _divisionRows = divs;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('Enter a name.', AppColors.warning);
      return;
    }
    if (_mode == null) {
      _snack('Select mode', AppColors.warning);
      return;
    }
    final auth = context.read<AuthProvider>();
    setState(() => _saving = true);
    try {
      // Register sequences live in the shared `sequence` table (actname='REGNO',
      // fg_id NULL). seq_id is auto-generated; yr_id/yrlabel are NOT NULL there.
      final year = await AdmissionService.getActiveYear(auth.insId ?? 0);
      final yrLabel = (year['yrlabel'] as String).isEmpty ? (auth.yearLabel ?? '') : year['yrlabel'] as String;
      final affix = _affix.text.trim();
      final width = _width.text.trim().isEmpty ? 4 : (int.tryParse(_width.text.trim()) ?? 4);
      final start = _start.text.trim().isEmpty ? 1 : (int.tryParse(_start.text.trim()) ?? 1);
      await AdmissionService.addRegSequence({
        'ins_id': auth.insId,
        'mod_id': 0,
        'yr_id': year['yr_id'],
        'yrlabel': yrLabel,
        'actname': 'REGNO',
        'seqname': name,
        'isprefix': _mode == 'Prefix' ? 'Y' : 'N',
        'seqprefix': affix, // NOT NULL — empty string when no affix
        'seqstart': start,
        'seqwidth': width,
        'sequid': affix.isEmpty ? 'REG' : affix,
        'seqcurno': 0,
        'seqend': _end.text.trim().isEmpty ? null : int.tryParse(_end.text.trim()),
        'division': _divisionVal,
        'activestatus': 1,
      });
      for (final c in [_name, _affix]) {
        c.clear();
      }
      _start.clear();
      _width.clear();
      _end.clear();
      setState(() {
        _mode = null;
        _divisionVal = null;
      });
      _snack('Register sequence added.', AppColors.success);
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
        title: const Text('Delete Register Sequence'),
        content: Text('Remove "$name"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AdmissionService.deleteRegSequence(id);
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

  // ── design helpers (mirrors master_data_screen / master_crud_panel) ──

  Widget _lbl(String text) =>
      Text(text, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black));

  InputDecoration _filledFieldDec(String hint, {bool filled = false}) {
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

  TextStyle _fieldTextStyle() {
    final compact = MediaQuery.of(context).size.width <= 1366;
    return TextStyle(fontWeight: FontWeight.w500, fontSize: compact ? 11 : 14, color: const Color(0xFF555555));
  }


  TextStyle _hStyle() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
  TextStyle _cStyle() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Edge-to-edge (no outer Padding) — parent pill-tab page shell handles
    // breathing room.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 320.w, child: _form()),
        SizedBox(width: 16.w),
        Expanded(child: _list()),
      ],
    );
  }

  /// Add card per admission-master-design.md § 3: white Container, 20.w
  /// padding, 10.r radius, full AppColors.border. Title: tag icon + 15.sp w700
  /// "Admission Number Sequencing". Every field is `Column(_lbl + 6h + field)`.
  Widget _form() {
    return Container(
      padding: EdgeInsets.all(20.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: FocusTraversalGroup(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const CardTitleBlock(icon: 'tag', title: 'Admission Number Sequencing', subtitle: 'set up the sequence for new admission numbers'),
          SizedBox(height: 20.h),
          _lbl('Name *'),
          SizedBox(height: 6.h),
          TextField(
            controller: _name,
            style: _fieldTextStyle().copyWith(color: _name.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            decoration: _filledFieldDec('Enter name', filled: _name.text.trim().isNotEmpty),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: 16.h),
          _lbl('Mode'),
          SizedBox(height: 6.h),
          DropdownButtonFormField<String>(
            initialValue: _mode,
            isExpanded: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
            style: _fieldTextStyle(),
            decoration: _filledFieldDec('Select mode', filled: _mode != null),
            items: [
              DropdownMenuItem(value: 'Prefix', child: Text('Prefix', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
              DropdownMenuItem(value: 'Suffix', child: Text('Suffix', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
            ],
            selectedItemBuilder: (context) => [
              Align(alignment: Alignment.centerLeft, child: Text('Prefix', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
              Align(alignment: Alignment.centerLeft, child: Text('Suffix', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
            ],
            onChanged: (v) => setState(() => _mode = v),
          ),
          SizedBox(height: 16.h),
          _lbl('Prefix / Suffix value'),
          SizedBox(height: 6.h),
          TextField(
            controller: _affix,
            style: _fieldTextStyle().copyWith(color: _affix.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            decoration: _filledFieldDec('e.g. ADM/', filled: _affix.text.trim().isNotEmpty),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: 16.h),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lbl('Start No'),
                  SizedBox(height: 6.h),
                  TextField(controller: _start, keyboardType: TextInputType.number, style: _fieldTextStyle().copyWith(color: _start.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), decoration: _filledFieldDec('1', filled: _start.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                ],
              )),
              SizedBox(width: 8.w),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lbl('End No'),
                  SizedBox(height: 6.h),
                  TextField(controller: _end, keyboardType: TextInputType.number, style: _fieldTextStyle().copyWith(color: _end.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), decoration: _filledFieldDec('-', filled: _end.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                ],
              )),
              SizedBox(width: 8.w),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lbl('Width'),
                  SizedBox(height: 6.h),
                  TextField(controller: _width, keyboardType: TextInputType.number, style: _fieldTextStyle().copyWith(color: _width.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), decoration: _filledFieldDec('4', filled: _width.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                ],
              )),
            ],
          ),
          SizedBox(height: 16.h),
          _lbl('Division'),
          SizedBox(height: 6.h),
          Builder(builder: (context) {
            final names = _divisionRows
                .map((d) => (d['divname'] ?? '').toString())
                .where((s) => s.isNotEmpty)
                .toList();
            // Guard against a stale selection not present in the current options.
            final value = names.contains(_divisionVal) ? _divisionVal : null;
            return DropdownButtonFormField<String>(
              initialValue: value,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              style: _fieldTextStyle(),
              decoration: _filledFieldDec(
                names.isEmpty ? 'No divisions — add in Division tab' : 'Select division',
                filled: value != null,
              ),
              items: names
                  .map((name) => DropdownMenuItem(
                        value: name,
                        child: Text(name, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                      ))
                  .toList(),
              selectedItemBuilder: (context) => names
                  .map((name) => Align(
                        alignment: Alignment.centerLeft,
                        child: Text(name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _divisionVal = v),
            );
          }),
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
      ),
    );
  }

  /// List card per admission-master-design.md § 3: outer white card (10r,
  /// 16.w padding, full border) with title bar (tag icon + "Register Sequences"
  /// + count badge), then inner bordered table (8r, antiAlias).
  Widget _list() {
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
              const CardTitleBlock(icon: 'tag', title: 'Register Sequences', subtitle: 'all admission number sequences in this institution'),
              SizedBox(width: 10.w),
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
                    child: Row(
                      children: [
                        Expanded(flex: 3, child: Text('NAME', style: _hStyle())),
                        Expanded(flex: 2, child: Text('DIVISION', style: _hStyle())),
                        SizedBox(width: 64.w, child: Text('PRE/SUF', style: _hStyle())),
                        SizedBox(width: 64.w, child: Text('AFFIX', style: _hStyle())),
                        SizedBox(width: 56.w, child: Text('START', style: _hStyle())),
                        SizedBox(width: 56.w, child: Text('END', style: _hStyle())),
                        SizedBox(width: 36.w, child: Text('W', style: _hStyle())),
                        SizedBox(width: 44.w, child: const SizedBox.shrink()),
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
                                separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border.withValues(alpha: 0.5)),
                                itemBuilder: (_, i) {
                                  final r = _rows[i];
                                  final id = r['seq_id'] is int ? r['seq_id'] as int : int.tryParse(r['seq_id'].toString()) ?? 0;
                                  final name = r['seqname']?.toString() ?? '';
                                  final mode = (r['isprefix']?.toString() ?? 'Y') == 'Y' ? 'Prefix' : 'Suffix';
                                  return Container(
                                    color: i.isEven ? Colors.white : AppColors.surface,
                                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 9.h),
                                    child: Row(
                                      children: [
                                        Expanded(flex: 3, child: Text(name, style: _cStyle())),
                                        Expanded(flex: 2, child: Text(r['division']?.toString() ?? '-', style: _cStyle(), overflow: TextOverflow.ellipsis)),
                                        SizedBox(width: 64.w, child: Text(mode, style: _cStyle())),
                                        SizedBox(width: 64.w, child: Text((r['seqprefix']?.toString().isEmpty ?? true) ? '-' : r['seqprefix'].toString(), style: _cStyle())),
                                        SizedBox(width: 56.w, child: Text(r['seqstart']?.toString() ?? '-', style: _cStyle())),
                                        SizedBox(width: 56.w, child: Text(r['seqend']?.toString() ?? '-', style: _cStyle())),
                                        SizedBox(width: 36.w, child: Text(r['seqwidth']?.toString() ?? '-', style: _cStyle())),
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
            ),
          ),
        ],
      ),
    );
  }
}
