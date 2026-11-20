import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/master_usage.dart';
import '../../utils/school_terms.dart';
import '../../services/admission_service.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/master_crud_panel.dart';
import '../../widgets/pill_tab.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/sequence_ui.dart';

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
/// Tab order: the spec describes Community / Reg No / Concession.
/// The two extra tabs (Admission Type, Quota) preserve existing CRUD
/// functionality and follow section 7 ("When adding a new tab").
class AdmissionMasterScreen extends StatefulWidget {
  /// Which tab to open at. Each tab is its own sidebar submenu, so the sidebar
  /// is normally the tab selector and [showTabBar] is false.
  final int initialTab;

  /// When false the in-screen pill tab bar is hidden.
  final bool showTabBar;

  const AdmissionMasterScreen({super.key, this.initialTab = 0, this.showTabBar = true});

  /// The tab order, and the sidebar's link to it.
  ///
  /// On the widget rather than the State because the sidebar resolves a
  /// sub-item to a tab by LABEL, not by position, and reads this from
  /// outside the file -- see _subTab in dashboard_screen.dart.
  static const tabLabels = [
    'Admission Type', 'Quota', 'Community', 'Concession', 'Division', 'Reg No', 'TC Sequence',
  ];

  @override
  State<AdmissionMasterScreen> createState() => _AdmissionMasterScreenState();
}

class _AdmissionMasterScreenState extends State<AdmissionMasterScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // Order matches the spec's primary trio first, then the project-specific
  // extras (Admission Type / Quota).
  static const _tabIcons = [
    'user-tick', 'ticket', 'people', 'discount-shape', 'diagram', 'tag', 'document-text',
  ];

  // What a tab shows when its label (a sidebar key -- never change it) is
  // too short to read on its own. Display only.
  static const _tabTitles = {'Reg No': 'Register No. Sequence'};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: AdmissionMasterScreen.tabLabels.length,
        vsync: this,
        // clamp: a sub-index carried over from a screen with more tabs
        // would otherwise be out of range here.
        initialIndex: _startTab());
  }

  // A school has no Admission Type / Quota (tabs 0 and 1), so it opens at
  // Community instead. College is unchanged.
  int _startTab() {
    final i = widget.initialTab.clamp(0, AdmissionMasterScreen.tabLabels.length - 1);
    return (isSchool && i < 2) ? 2 : i;
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
        if (widget.showTabBar)
        ListenableBuilder(
          listenable: _tabController,
          builder: (context, _) {
            final selected = _tabController.index;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: // Wrap, not a horizontal scroll view: the row can run past the
              // window on a laptop screen, and a horizontal
              // SingleChildScrollView has no scrollbar and ignores the mouse
              // wheel on desktop, leaving the last tabs unreachable.
              Wrap(
                spacing: PillTab.gap(context),
                runSpacing: 8,
                children: [
                  for (var i = 0; i < AdmissionMasterScreen.tabLabels.length; i++)
                    if (!isSchool || i >= 2)
                    PillTab(
                      icon: _tabIcons[i],
                      label: schoolTerm(_tabTitles[AdmissionMasterScreen.tabLabels[i]] ?? AdmissionMasterScreen.tabLabels[i]),
                      selected: selected == i,
                      onTap: () => _tabController.animateTo(i),
                    ),
                ],
              ),
            );
          },
        ),
        SizedBox(height: 6.h),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              // School: no admissiontype / quota tables -- placeholders keep
              // the tab indexes (resolved by label) unchanged.
              if (isSchool) const SizedBox.shrink() else const MasterCrudPanel(table: 'admissiontype', idCol: 'adm_id', nameCol: 'admname', title: 'Admission Type', icon: 'user-tick', countLabel: 'types', importTabIndex: 0),
              if (isSchool) const SizedBox.shrink() else const MasterCrudPanel(table: 'quota', idCol: 'quo_id', nameCol: 'quoname', title: 'Quota', icon: 'ticket', countLabel: 'quotas', importTabIndex: 1),
              const MasterCrudPanel(table: 'community', idCol: 'com_id', nameCol: 'comname', title: 'Community', icon: 'people', countLabel: 'communities', importTabIndex: 9),
              const MasterCrudPanel(table: 'concessioncategory', idCol: 'con_id', nameCol: 'condesc', title: 'Concession', icon: 'discount-shape', countLabel: 'concessions', importTabIndex: 6, includeCreatedBy: false),
              const MasterCrudPanel(table: 'division', idCol: 'div_id', nameCol: 'divname', title: 'Division', icon: 'diagram', countLabel: 'divisions', hideImport: true),
              const _RegNoPanel(),
              const _RegNoPanel(actname: 'TCNO', sequidDefault: 'TC', heading: 'TC'),
            ],
          ),
        ),
      ],
    );
  }
}

/// Register Number Sequencing — richer master (name, prefix/suffix, range, width).
class _RegNoPanel extends StatefulWidget {
  const _RegNoPanel({this.actname = 'REGNO', this.sequidDefault = 'REG', this.heading = 'Register'});
  // actname distinguishes register (REGNO) from TC (TCNO) sequences in the shared
  // `sequence` table; heading labels the cards/dialogs.
  final String actname;
  final String sequidDefault;
  final String heading;

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
  // The row being edited (null = adding). Its start is locked once it has
  // issued numbers.
  Map<String, dynamic>? _editing;

  bool get _startLocked {
    final r = _editing;
    if (r == null) return false;
    return SequenceUI.issued(
        current: ((r['seqcurno'] as num?) ?? 0).toInt(), start: ((r['seqstart'] as num?) ?? 1).toInt());
  }

  void _edit(Map<String, dynamic> r) {
    final names = _divisionRows.map((d) => (d['divname'] ?? '').toString()).toSet();
    setState(() {
      _editing = r;
      _name.text = r['seqname']?.toString() ?? '';
      _mode = (r['isprefix']?.toString() ?? 'Y') == 'Y' ? 'Prefix' : 'Suffix';
      _affix.text = r['seqprefix']?.toString() ?? '';
      _start.text = '${((r['seqstart'] as num?) ?? 1).toInt()}';
      _end.text = r['seqend'] == null ? '' : '${r['seqend']}';
      _width.text = '${((r['seqwidth'] as num?) ?? 4).toInt()}';
      final d = r['division']?.toString();
      _divisionVal = names.contains(d) ? d : null;
    });
  }

  void _cancelEdit() {
    for (final c in [_name, _affix, _start, _end, _width]) {
      c.clear();
    }
    setState(() {
      _editing = null;
      _mode = null;
      _divisionVal = null;
    });
  }

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
    final rows = await AdmissionService.getRegSequences(actname: widget.actname);
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
      _snack('Enter a sequence name.', AppColors.warning);
      return;
    }
    if (_mode == null) {
      _snack('Select a mode (prefix or suffix).', AppColors.warning);
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
      final editing = _editing;
      if (editing != null) {
        await SupabaseService.saveSchemaRow(
            'sequence',
            {
              'seqname': name,
              'isprefix': _mode == 'Prefix' ? 'Y' : 'N',
              'seqprefix': affix,
              if (!_startLocked) 'seqstart': start,
              'seqwidth': width,
              'sequid': affix.isEmpty ? widget.sequidDefault : affix,
              'seqend': _end.text.trim().isEmpty ? null : int.tryParse(_end.text.trim()),
              'division': _divisionVal,
            },
            pkCol: 'seq_id',
            pkVal: (editing['seq_id'] as num).toInt());
        _cancelEdit();
        _snack(schoolTerm('${widget.heading} number sequence updated.'), AppColors.success);
        await _load();
        return;
      }
      await AdmissionService.addRegSequence({
        'ins_id': auth.insId,
        'mod_id': 0,
        'yr_id': year['yr_id'],
        'yrlabel': yrLabel,
        'actname': widget.actname,
        'seqname': name,
        'isprefix': _mode == 'Prefix' ? 'Y' : 'N',
        'seqprefix': affix, // NOT NULL — empty string when no affix
        'seqstart': start,
        'seqwidth': width,
        'sequid': affix.isEmpty ? widget.sequidDefault : affix,
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
      _snack(schoolTerm('${widget.heading} number sequence added.'), AppColors.success);
      await _load();
    } catch (e) {
      _snack('Could not save the sequence. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id, String name) async {
    final r = _rows.firstWhere((r) => r['seq_id'].toString() == id.toString(), orElse: () => const {});
    if (!await SequenceUI.confirmDelete(context,
        name: name,
        current: ((r['seqcurno'] as num?) ?? 0).toInt(),
        start: ((r['seqstart'] as num?) ?? 1).toInt())) {
      return;
    }
    try {
      await AdmissionService.deleteRegSequence(id);
      if (_editing?['seq_id'].toString() == id.toString()) _cancelEdit();
      _snack('Sequence deleted.', AppColors.success);
      await _load();
    } catch (e) {
      _snack('Could not delete the sequence. ${friendlyError(e)}', AppColors.error);
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  // ── design helpers (mirrors master_data_screen / master_crud_panel) ──

  Widget _lbl(String text) => text.endsWith(' *')
      ? AppUI.fieldLabel(text.substring(0, text.length - 2), required: true)
      : AppUI.fieldLabel(text);

  InputDecoration _filledFieldDec(String hint, {bool filled = false}) =>
      AppUI.field(context, hint, filled: filled);

  TextStyle _hStyle() => AppUI.tableHead;
  TextStyle _cStyle() => AppUI.cell;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Edge-to-edge (no outer Padding) — parent pill-tab page shell handles
    // breathing room.
    return SequenceUI.layout(form: _form(), list: _list());
  }

  /// The form card every sequence screen shares (SequenceUI).
  Widget _form() {
    final isPrefix = _mode != 'Suffix';
    final affix = _affix.text.trim();
    final startTxt = _start.text.trim();
    final w = (int.tryParse(_width.text.trim()) ?? 4).clamp(1, 9);
    final n = (int.tryParse(startTxt) ?? 1).toString().padLeft(w, '0');
    return SequenceUI.formCard(
      title: schoolTerm('${widget.heading} Number Sequence'),
      subtitle: 'Set up the numbering sequence',
      preview: affix.isEmpty && startTxt.isEmpty ? null : (isPrefix ? '$affix$n' : '$n$affix'),
      previewHint: 'Enter a prefix or suffix to see the preview',
      button: SequenceUI.saveButton(saving: _saving, editing: _editing != null, onPressed: _add),
      onCancel: _editing == null ? null : _cancelEdit,
      fields: [
          _lbl('Name *'),
          TextField(
            controller: _name,
            style: AppUI.fieldText(context, filled: _name.text.trim().isNotEmpty),
            decoration: _filledFieldDec('Enter name', filled: _name.text.trim().isNotEmpty),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: 16.h),
          _lbl('Mode *'),
          AppDropdownField<String>(
            initialValue: _mode,
            isExpanded: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
            style: AppUI.fieldText(context, filled: _mode != null),
            decoration: _filledFieldDec('Select mode', filled: _mode != null),
            items: [
              DropdownMenuItem(value: 'Prefix', child: Text('Prefix', style: AppUI.fieldText(context))),
              DropdownMenuItem(value: 'Suffix', child: Text('Suffix', style: AppUI.fieldText(context))),
            ],
            selectedItemBuilder: (context) => [
              Align(alignment: Alignment.centerLeft, child: Text('Prefix', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
              Align(alignment: Alignment.centerLeft, child: Text('Suffix', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
            ],
            onChanged: (v) => setState(() => _mode = v),
          ),
          SizedBox(height: 16.h),
          _lbl('Prefix / Suffix Value'),
          TextField(
            controller: _affix,
            style: AppUI.fieldText(context, filled: _affix.text.trim().isNotEmpty),
            decoration: _filledFieldDec('e.g. ADM/', filled: _affix.text.trim().isNotEmpty),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: 16.h),
          // Two per row: three across a 320-wide card left each field ~65px,
          // too narrow for its placeholder and the "Width (Digits)" label.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lbl(_startLocked ? 'Start Number (Locked)' : 'Start Number'),
                  TextField(controller: _start, enabled: !_startLocked, keyboardType: TextInputType.number, style: AppUI.fieldText(context, filled: _start.text.trim().isNotEmpty), decoration: _filledFieldDec('e.g. 1', filled: _start.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                ],
              )),
              SizedBox(width: 12.w),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lbl('End Number'),
                  TextField(controller: _end, keyboardType: TextInputType.number, style: AppUI.fieldText(context, filled: _end.text.trim().isNotEmpty), decoration: _filledFieldDec('Optional', filled: _end.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                ],
              )),
            ],
          ),
          SizedBox(height: 16.h),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lbl('Number of Digits'),
                  TextField(controller: _width, keyboardType: TextInputType.number, style: AppUI.fieldText(context, filled: _width.text.trim().isNotEmpty), decoration: _filledFieldDec('e.g. 4', filled: _width.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                ],
              )),
              SizedBox(width: 12.w),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
          SizedBox(height: 16.h),
          _lbl('Division'),
          Builder(builder: (context) {
            final names = _divisionRows
                .map((d) => (d['divname'] ?? '').toString())
                .where((s) => s.isNotEmpty)
                .toList();
            // Guard against a stale selection not present in the current options.
            final value = names.contains(_divisionVal) ? _divisionVal : null;
            // "All divisions" is a real choice: a school that does not number
            // admissions division-wise keeps one common sequence, and a
            // sequence given a division can be put back (user, 2026-11-18).
            return AppDropdownField<String?>(
              key: ValueKey('seq-division-${_editing?['seq_id']}-$value'),
              initialValue: value,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              style: AppUI.fieldText(context, filled: value != null),
              decoration: _filledFieldDec('All divisions', filled: value != null),
              items: [
                DropdownMenuItem<String?>(value: null, child: Text('All divisions', style: AppUI.fieldText(context))),
                ...names.map((name) => DropdownMenuItem<String?>(
                      value: name,
                      child: Text(name, style: AppUI.fieldText(context)),
                    )),
              ],
              selectedItemBuilder: (context) => [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('All divisions', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)),
                ),
                ...names.map((name) => Align(
                      alignment: Alignment.centerLeft,
                      child: Text(name, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)),
                    )),
              ],
              onChanged: (v) => setState(() => _divisionVal = v),
            );
          }),
          if (widget.actname == 'REGNO') ...[
            SizedBox(height: 4.h),
            Text('All divisions: one number series for the whole school. Pick a division only if each division has its own series.',
                style: AppUI.muted),
          ],
      ],
    );
  }

  /// The list every sequence screen shares (SequenceUI). Delete only: a
  /// register sequence has no edit.
  Widget _list() {
    return SequenceUI.listCard(
      title: schoolTerm('${widget.heading} Number Sequences'),
      loading: _loading,
      emptyTitle: schoolTerm('No ${widget.heading == 'TC' ? 'TC' : widget.heading.toLowerCase()} number sequence yet'),
      rows: _rows.map((r) {
        final id = r['seq_id'] is int ? r['seq_id'] as int : int.tryParse(r['seq_id'].toString()) ?? 0;
        final name = r['seqname']?.toString() ?? '';
        final division = r['division']?.toString() ?? '';
        final suffix = (r['isprefix']?.toString() ?? 'Y') != 'Y';
        final affix = r['seqprefix']?.toString() ?? '';
        final cur = ((r['seqcurno'] as num?) ?? 0).toInt();
        final start = ((r['seqstart'] as num?) ?? 1).toInt();
        final w = ((r['seqwidth'] as num?) ?? 5).toInt();
        return SeqRow(
          name: name,
          sub: division == '-' ? null : division,
          prefix: suffix && affix.isNotEmpty ? '$affix (suffix)' : affix,
          next: SequenceUI.nextNumber(affix: affix, suffix: suffix, current: cur, start: start, width: w),
          lastIssued: SequenceUI.lastIssued(current: cur, start: start),
          selected: _editing?['seq_id'].toString() == id.toString(),
          onEdit: () => _edit(r),
          onDelete: () => _delete(id, name),
        );
      }).toList(),
    );
  }
}
