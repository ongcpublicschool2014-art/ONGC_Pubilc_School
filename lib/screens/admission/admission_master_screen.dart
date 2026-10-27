import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/master_usage.dart';
import '../../utils/school_terms.dart';
import '../../services/admission_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
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
      _snack('Could not add the sequence. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id, String name) async {
    // A sequence that has issued numbers cannot be removed. seqcurno is the
    // LAST number handed out -- it is created at 0 and only ever moves
    // forward -- so anything above 0 means real documents are already
    // carrying numbers from this series. Deleting it would let a new series
    // start over and re-issue numbers that are already printed on a TC or an
    // admission record.
    final cur = ((_rows.firstWhere((r) => r['seq_id'].toString() == id.toString(),
            orElse: () => const {})['seqcurno'] as num?) ?? 0).toInt();
    if (cur > 0) {
      if (mounted) {
        await showMasterInUseDialog(context,
            name: name,
            count: cur,
            noun: 'number',
            detail: 'has already issued numbers, up to $cur.',
            fix: 'Deleting it would let a new series start over and hand out '
                'numbers that are already printed on issued documents.');
      }
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(schoolTerm('Delete ${widget.heading} Number Sequence')),
        content: Text('Delete the sequence "$name"? This cannot be undone.'),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 320.w, child: _form()),
        SizedBox(width: AppUI.gap),
        Expanded(child: _list()),
      ],
    );
  }

  /// Add card per admission-master-design.md § 3: white Container, 20.w
  /// padding, 10.r radius, full AppColors.border. Title: tag icon + 15.sp w700
  /// "Admission Number Sequencing". Every field is `Column(_lbl + 6h + field)`.
  Widget _form() {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: FocusTraversalGroup(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          CardTitleBlock(icon: 'tag', title: schoolTerm('${widget.heading} Number Sequence'), subtitle: 'Set up the numbering sequence'),
          SizedBox(height: 20.h),
          _lbl('Name *'),
          TextField(
            controller: _name,
            style: AppUI.fieldText(context, filled: _name.text.trim().isNotEmpty),
            decoration: _filledFieldDec('Enter name', filled: _name.text.trim().isNotEmpty),
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: 16.h),
          _lbl('Mode *'),
          DropdownButtonFormField<String>(
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lbl('Start Number'),
                  TextField(controller: _start, keyboardType: TextInputType.number, style: AppUI.fieldText(context, filled: _start.text.trim().isNotEmpty), decoration: _filledFieldDec('e.g. 1', filled: _start.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                ],
              )),
              SizedBox(width: 8.w),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lbl('End Number'),
                  TextField(controller: _end, keyboardType: TextInputType.number, style: AppUI.fieldText(context, filled: _end.text.trim().isNotEmpty), decoration: _filledFieldDec('Optional', filled: _end.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                ],
              )),
              SizedBox(width: 8.w),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _lbl('Width (Digits)'),
                  TextField(controller: _width, keyboardType: TextInputType.number, style: AppUI.fieldText(context, filled: _width.text.trim().isNotEmpty), decoration: _filledFieldDec('e.g. 4', filled: _width.text.trim().isNotEmpty), onChanged: (_) => setState(() {})),
                ],
              )),
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
            return DropdownButtonFormField<String>(
              initialValue: value,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              style: AppUI.fieldText(context, filled: value != null),
              decoration: _filledFieldDec(
                names.isEmpty ? 'No divisions yet. Add one in the Division tab' : 'Select division',
                filled: value != null,
              ),
              items: names
                  .map((name) => DropdownMenuItem(
                        value: name,
                        child: Text(name, style: AppUI.fieldText(context)),
                      ))
                  .toList(),
              selectedItemBuilder: (context) => names
                  .map((name) => Align(
                        alignment: Alignment.centerLeft,
                        child: Text(name, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)),
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
            ),
          ),
          SizedBox(height: 8.h),
          AppUI.requiredNote(),
        ],
      ),
      ),
    );
  }

  /// List card per admission-master-design.md § 3: outer white card (10r,
  /// 16.w padding, full border) with title bar (tag icon + "Register Sequences"
  /// + count badge), then inner bordered table (8r, antiAlias).
  Widget _list() {
    // Same table as every other sequence screen (Demand / Concession /
    // Refund ...): SEQUENCE, PREFIX, PREVIEW, CURRENT -- plus delete, the only
    // way to change a register sequence (it has no edit).
    TextStyle h() => _hStyle();
    TextStyle c() => _cStyle();
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 12.h),
            child: Row(children: [
              AppUI.iconTile('tag'),
              SizedBox(width: 12.w),
              Text(schoolTerm('${widget.heading} Number Sequences'), style: AppUI.cardTitle),
              SizedBox(width: 10.w),
              AppUI.chip('${_rows.length} sequence${_rows.length == 1 ? '' : 's'}', AppStatus.info),
              const Spacer(),
            ]),
          ),
          Expanded(
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                children: [
                  Container(
                    color: AppColors.tableHeadBg,
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    child: Row(children: [
                      Expanded(flex: 3, child: Text('SEQUENCE', style: h())),
                      SizedBox(width: 90.w, child: Text('PREFIX', style: h())),
                      SizedBox(width: 140.w, child: Text('PREVIEW', style: h())),
                      SizedBox(width: 80.w, child: Text('CURRENT', textAlign: TextAlign.right, style: h())),
                      SizedBox(width: 44.w),
                    ]),
                  ),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _rows.isEmpty
                            ? AppUI.empty(title: schoolTerm('No ${widget.heading == 'TC' ? 'TC' : widget.heading.toLowerCase()} number sequence yet'), why: 'Add one with the form on the left.', icon: 'tag')
                            : ListView(children: [
                                for (final r in _rows)
                                  Builder(builder: (_) {
                                    final id = r['seq_id'] is int ? r['seq_id'] as int : int.tryParse(r['seq_id'].toString()) ?? 0;
                                    final name = r['seqname']?.toString() ?? '';
                                    final division = r['division']?.toString() ?? '';
                                    final isPrefix = (r['isprefix']?.toString() ?? 'Y') == 'Y';
                                    final affix = r['seqprefix']?.toString() ?? '';
                                    final cur = ((r['seqcurno'] as num?) ?? 0).toInt();
                                    final start = ((r['seqstart'] as num?) ?? 1).toInt();
                                    final w = ((r['seqwidth'] as num?) ?? 5).toInt();
                                    // Nothing issued yet -> the next one is the start.
                                    final num_ = (cur <= 0 ? start : cur + 1).toString().padLeft(w, '0');
                                    return Container(
                                      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppColors.divider))),
                                      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                                      child: Row(children: [
                                        Expanded(
                                          flex: 3,
                                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                                            Text(name, style: c(), overflow: TextOverflow.ellipsis),
                                            if (division.isNotEmpty && division != '-') Text(division, style: AppUI.muted, overflow: TextOverflow.ellipsis),
                                          ]),
                                        ),
                                        SizedBox(
                                          width: 90.w,
                                          child: Text(affix.isEmpty ? '—' : (isPrefix ? affix : '$affix (suffix)'),
                                              style: c().copyWith(fontWeight: FontWeight.w700, color: AppColors.primary), overflow: TextOverflow.ellipsis),
                                        ),
                                        SizedBox(
                                          width: 140.w,
                                          child: Text(isPrefix ? '$affix$num_' : '$num_$affix',
                                              style: AppUI.label.copyWith(color: AppColors.primary), overflow: TextOverflow.ellipsis),
                                        ),
                                        SizedBox(width: 80.w, child: Text(cur <= 0 ? '0' : '$cur', textAlign: TextAlign.right, style: c())),
                                        SizedBox(
                                          width: 44.w,
                                          child: Center(
                                            child: IconButton(
                                              tooltip: 'Delete',
                                              visualDensity: VisualDensity.compact,
                                              onPressed: () => _delete(id, name),
                                              icon: const AppIcon('trash', size: 16, color: AppColors.error),
                                            ),
                                          ),
                                        ),
                                      ]),
                                    );
                                  }),
                              ]),
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
