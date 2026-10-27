import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/master_usage.dart';
import '../../utils/school_terms.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/pill_tab.dart';
import 'master_import_screen.dart';

/// Master Data — Course and Class masters in the Fee-Master CRUD style:
/// a left Add/Edit form + right table, with a top-right "Import CSV/Excel"
/// button that opens the bulk importer. A single sidebar entry with internal
/// Course / Class tabs (same layout as Admission Master).
///
/// Page shell follows the project's pill-tab convention (admission-master-
/// design.md § 1): a plain `Column` — no outer `Padding`, no
/// `AppCard.decoration()`. The PillTab row sits on the Dashboard surface
/// and the TabBarView fills the rest.
class MasterDataScreen extends StatefulWidget {
  /// Which tab to open at. Each tab is its own sidebar submenu, so the sidebar
  /// is normally the tab selector and [showTabBar] is false.
  final int initialTab;

  /// When false the in-screen pill tab bar is hidden.
  final bool showTabBar;

  const MasterDataScreen({super.key, this.initialTab = 0, this.showTabBar = true});


  /// The tab order, and the sidebar's link to it.
  ///
  /// On the widget rather than the State because the sidebar resolves a
  /// sub-item to a tab by LABEL, not by position, and reads this from
  /// outside the file -- see _subTab in dashboard_screen.dart.
  static const tabLabels = ['Course', 'Class'];

  @override
  State<MasterDataScreen> createState() => _MasterDataScreenState();
}

class _MasterDataScreenState extends State<MasterDataScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _tabIcons = ['teacher', 'book-1'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: MasterDataScreen.tabLabels.length,
        vsync: this,
        // clamp: a sub-index carried over from a screen with more tabs
        // would otherwise be out of range here.
        initialIndex: widget.initialTab.clamp(0, MasterDataScreen.tabLabels.length - 1));
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
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < MasterDataScreen.tabLabels.length; i++) ...[
                      PillTab(
                        icon: _tabIcons[i],
                        label: schoolTerm(MasterDataScreen.tabLabels[i]),
                        selected: selected == i,
                        onTap: () => _tabController.animateTo(i),
                      ),
                      if (i < MasterDataScreen.tabLabels.length - 1)
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
              _CourseMasterPanel(),
              _ClassMasterPanel(),
            ],
          ),
        ),
      ],
    );
  }
}

// ── shared helpers (mirrors fee-master / admission-master design contract) ──

/// Bold-black label rendered above each input (admission-master-design.md § 5).
Widget _lbl(String text) =>
    Text(schoolTerm(text), style: AppUI.label);

/// Compact-or-expanded responsive input decoration with placeholder hint.
/// Matches `_filledFieldDec` from admission-master-design.md § 5.
InputDecoration _filledFieldDec(BuildContext context, String hint, {bool filled = false}) {
  return AppUI.field(context, hint, filled: filled);
}

TextStyle _fieldTextStyle(BuildContext context, {bool filled = false}) {
  return AppUI.fieldText(context, filled: filled);
}

void _snack(BuildContext ctx, String msg, Color color) {
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(schoolTerm(msg)), backgroundColor: color));
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

/// Auto-assigned display order = max(ordid) + 1 over the already-loaded active
/// rows. Order is generated, not entered by hand.
int _nextOrder(List<Map<String, dynamic>> rows) {
  var mx = 0;
  for (final r in rows) {
    final o = (r['ordid'] is num) ? (r['ordid'] as num).toInt() : int.tryParse(r['ordid']?.toString() ?? '');
    if (o != null && o > mx) mx = o;
  }
  return mx + 1;
}

/// Outer "Add" / "Edit" card — white, 10r radius, full border, 20.w padding.
/// Uses the shared [CardTitleBlock] with optional subtitle.
Widget _addCard({required String icon, required String title, String? subtitle, required Widget child}) {
  return Container(
    padding: EdgeInsets.all(AppUI.cardPad),
    decoration: AppUI.card(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CardTitleBlock(icon: icon, title: schoolTerm(title), subtitle: subtitle == null ? null : schoolTerm(subtitle)),
        SizedBox(height: 20.h),
        child,
      ],
    ),
  );
}

/// Outer "List" card — white, 10r radius, full border, 16.w padding. Title bar
/// holds an icon-tile block + count badge + spacer + optional action.
/// The inner bordered table card sits inside.
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
    padding: EdgeInsets.all(AppUI.cardPad),
    decoration: AppUI.card(),
    child: Column(
      children: [
        Padding(
          padding: EdgeInsets.only(left: 4.w, right: 4.w, bottom: 10.h),
          child: Row(children: [
            CardTitleBlock(icon: icon, title: schoolTerm(title), subtitle: subtitle == null ? null : schoolTerm(subtitle)),
            SizedBox(width: 10.w),
            AppUI.chip('$count ${schoolTerm(countLabel)}', AppStatus.info),
            const Spacer(),
            if (action != null) action,
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

TextStyle _h() => AppUI.tableHead;
TextStyle _c() => AppUI.cell;

Future<bool> _confirmDelete(BuildContext ctx, String what) async {
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text(schoolTerm('Delete $what')),
      content: Text(schoolTerm('Remove this $what?')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete', style: TextStyle(color: AppColors.error))),
      ],
    ),
  );
  return ok == true;
}

/// Compact-or-expanded amber Import CSV/Excel button used in the list-card
/// title bar (sits in the `action` slot of `_listCard`). Opens
/// [MasterImportScreen] full-screen at [tabIndex], then runs [onReturn].
Widget _importButton(BuildContext context, {
  required String title,
  required int tabIndex,
  required bool disabled,
  required Future<void> Function() onReturn,
}) {
  final iconSize = AppBtn.iconSize(context);
  return SizedBox(
    height: AppBtn.height(context),
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
                        Text(schoolTerm('Import $title'),
                            style: AppUI.cardTitle),
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
    ),
  );
}

// ══════════════════════════════════════════════════════════════════════════
// COURSE
// ══════════════════════════════════════════════════════════════════════════
class _CourseMasterPanel extends StatefulWidget {
  const _CourseMasterPanel();
  @override
  State<_CourseMasterPanel> createState() => _CourseMasterPanelState();
}

class _CourseMasterPanelState extends State<_CourseMasterPanel> with AutomaticKeepAliveClientMixin {
  final _name = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  // School: the type is set on the STANDARD; the database copies it to
  // every section of the standard (course.classtype -> class.classtype).
  String _stdType = 'PROMOTIONAL';
  static const _stdTypes = ['PROMOTIONAL', 'TERMINAL', 'COMPLETED'];
  static const _stdTypeLabels = {
    'PROMOTIONAL': 'Promotional — moves up to the next standard',
    'TERMINAL': 'Terminal — final standard of the school',
    'COMPLETED': 'Completed — TC, students who have left',
  };
  static const _stdTypeShort = {'PROMOTIONAL': 'Promotional', 'TERMINAL': 'Terminal', 'COMPLETED': 'Completed'};
  // School: fee demand level -- SECTION (each section its own fees) or
  // STANDARD (one Section / Advance Fee Demand for every section).
  String _feeLevel = 'SECTION';
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
      final res = await SupabaseService.fromSchema('course')
          .select('*').eq('ins_id', _insId).eq('activestatus', 1);
      final list = List<Map<String, dynamic>>.from(res as List)
        ..sort((a, b) {
          final oa = (a['ordid'] is num) ? (a['ordid'] as num).toInt() : 1 << 30;
          final ob = (b['ordid'] is num) ? (b['ordid'] as num).toInt() : 1 << 30;
          if (oa != ob) return oa.compareTo(ob);
          return (a['courname'] ?? '').toString().toLowerCase().compareTo((b['courname'] ?? '').toString().toLowerCase());
        });
      if (!mounted) return;
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
      _editId = r['cour_id'] is int ? r['cour_id'] as int : int.tryParse(r['cour_id'].toString());
      _name.text = r['courname']?.toString() ?? '';
      _stdType = _stdTypes.contains(r['classtype']?.toString()) ? r['classtype'].toString() : 'PROMOTIONAL';
      _feeLevel = r['feelevel']?.toString() == 'STANDARD' ? 'STANDARD' : 'SECTION';
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _name.clear();
      _stdType = 'PROMOTIONAL';
      _feeLevel = 'SECTION';
    });
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return _snack(context, 'Enter a course name.', AppColors.warning);
    if (_rows.any((r) => (r['courname']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() &&
        (r['cour_id']?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      return _snack(context, '"$name" already exists.', AppColors.warning);
    }
    setState(() => _saving = true);
    try {
      if (_editId != null) {
        await SupabaseService.saveSchemaRow('course', {
          'courname': name,
          if (isSchool) 'classtype': _stdType,
          if (isSchool) 'feelevel': _feeLevel,
        }, pkCol: 'cour_id', pkVal: _editId!);
        if (mounted) _snack(context, 'Course updated.', AppColors.success);
      } else {
        await SupabaseService.saveSchemaRow('course', {
          'cour_id': await _nextId('course', 'cour_id'),
          'courname': name,
          'ordid': _nextOrder(_rows),
          'ins_id': _insId,
          'activestatus': 1,
          if (isSchool) 'classtype': _stdType,
          if (isSchool) 'feelevel': _feeLevel,
        });
        if (mounted) _snack(context, 'Course added.', AppColors.success);
      }
      _name.clear();
      _editId = null;
      _stdType = 'PROMOTIONAL';
      _feeLevel = 'SECTION';
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    // Checked BEFORE the confirmation: being asked "are you sure?" and only
    // then told it was never allowed is a worse experience than not being
    // asked at all.
    final name = _rows.firstWhere((r) => r['cour_id'].toString() == id.toString(),
        orElse: () => const {})['courname']?.toString();
    final used = await countReferencing('students', [('cour_id', id), ('courname', name)]);
    if (used > 0) {
      if (mounted) {
        await showMasterInUseDialog(context,
            name: name ?? schoolTerm('this course'),
            count: used,
            noun: 'student',
            fix: schoolTerm('Move them to another course first.'));
      }
      return;
    }
    if (!mounted) return;
    if (!await _confirmDelete(context, 'course')) return;
    try {
      await SupabaseService.deleteSchemaRow('course', 'cour_id', id);
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
            icon: 'teacher',
            title: _editId != null ? 'Edit Course' : 'Add Course',
            subtitle: isSchool ? 'standard / grade — LKG, UKG, I, II …' : 'top-level academic course / programme',
            child: FocusTraversalGroup(
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _lbl('Course Name *'),
                SizedBox(height: 6.h),
                TextField(
                  controller: _name,
                  style: _fieldTextStyle(context, filled: _name.text.trim().isNotEmpty),
                  decoration: _filledFieldDec(context, schoolTerm('Enter course name'), filled: _name.text.trim().isNotEmpty),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _add(),
                ),
                if (isSchool) ...[
                  SizedBox(height: 16.h),
                  _lbl('Standard Type'),
                  SizedBox(height: 6.h),
                  DropdownButtonFormField<String>(
                    initialValue: _stdType,
                    icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                    isExpanded: true,
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    elevation: 6,
                    style: _fieldTextStyle(context, filled: true),
                    decoration: _filledFieldDec(context, 'Standard type', filled: true),
                    items: _stdTypes
                        .map((k) => DropdownMenuItem(value: k, child: Text(_stdTypeLabels[k]!, overflow: TextOverflow.ellipsis,
                            style: AppUI.fieldText(context))))
                        .toList(),
                    selectedItemBuilder: (context) => _stdTypes
                        .map((k) => Align(alignment: Alignment.centerLeft, child: Text(_stdTypeShort[k]!,
                            style: AppUI.fieldText(context, filled: true))))
                        .toList(),
                    onChanged: (v) => setState(() => _stdType = v ?? 'PROMOTIONAL'),
                  ),
                  SizedBox(height: 6.h),
                  Text('All sections of this standard take this type.',
                      style: AppUI.muted.copyWith(height: 1.3)),
                  SizedBox(height: 16.h),
                  _lbl('Fee Demand By'),
                  SizedBox(height: 6.h),
                  DropdownButtonFormField<String>(
                    key: ValueKey('fl-$_editId-$_feeLevel'),
                    initialValue: _feeLevel,
                    isExpanded: true,
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    style: _fieldTextStyle(context, filled: true),
                    decoration: _filledFieldDec(context, 'Fee demand by', filled: true),
                    items: const [
                      DropdownMenuItem(value: 'SECTION', child: Text('Section -- each section its own fees')),
                      DropdownMenuItem(value: 'STANDARD', child: Text('Standard -- same fees for all sections')),
                    ],
                    selectedItemBuilder: (context) => [
                      for (final t in const ['Section', 'Standard'])
                        Align(alignment: Alignment.centerLeft, child: Text(t, style: AppUI.fieldText(context, filled: true))),
                    ],
                    onChanged: (v) => setState(() => _feeLevel = v ?? 'SECTION'),
                  ),
                  SizedBox(height: 6.h),
                  Text('How Section Fee Demand and Advance Fee Demand are defined for this standard.',
                      style: AppUI.muted.copyWith(height: 1.3)),
                ],
                SizedBox(height: 18.h),
                Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _saving ? null : _add,
                      icon: Icon(_editId != null ? Icons.save : Icons.add, size: 16),
                      label: Text(_editId != null ? 'Update' : 'Add'),
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
        ),
        SizedBox(width: AppUI.gap),
        Expanded(
          child: _listCard(
            icon: 'teacher',
            title: 'Courses',
            subtitle: 'all courses in this institution',
            count: _rows.length,
            countLabel: 'courses',
            action: _importButton(context, title: 'Course', tabIndex: 2, disabled: _saving, onReturn: _load),
            headerCells: [
              SizedBox(width: 50.w, child: Text('S NO.', style: _h())),
              Expanded(child: Text(schoolTerm('COURSE'), style: _h())),
              if (isSchool) SizedBox(width: 110.w, child: Text('TYPE', style: _h())),
              if (isSchool) SizedBox(width: 100.w, child: Text('FEE BY', style: _h())),
              SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
            ],
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? AppUI.empty(title: schoolTerm('No courses'), why: schoolTerm('Add a course with the form on the left, or use Import CSV/Excel.'), icon: 'teacher')
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['cour_id'] is int ? r['cour_id'] as int : int.tryParse(r['cour_id'].toString()) ?? 0;
                          return Container(
                            color: i.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                            child: Row(children: [
                              SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                              Expanded(child: Text(r['courname']?.toString() ?? '', style: _c())),
                              if (isSchool)
                                SizedBox(width: 110.w, child: Text(_stdTypeShort[r['classtype']?.toString()] ?? 'Promotional', style: _c())),
                              if (isSchool)
                                SizedBox(
                                  width: 100.w,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: r['feelevel']?.toString() == 'STANDARD'
                                        ? AppUI.chip('Standard', AppStatus.info)
                                        : Text('Section', style: _c()),
                                  ),
                                ),
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
// CLASS
// ══════════════════════════════════════════════════════════════════════════
class _ClassMasterPanel extends StatefulWidget {
  const _ClassMasterPanel();
  @override
  State<_ClassMasterPanel> createState() => _ClassMasterPanelState();
}

class _ClassMasterPanelState extends State<_ClassMasterPanel> with AutomaticKeepAliveClientMixin {
  // Class is picked as a level (I/II/III/IV); the saved name is "course-level".
  static const _classLevels = ['I', 'II', 'III', 'IV'];
  String? _classLevel;
  String? _courId;
  String? _succId;

  /// What KIND of class this is. The class master used to imply it: a final
  /// year was one with no succeeding class, a TC batch was one someone had
  /// named "CSE TC 25". Neither survives contact with real data -- this
  /// institution has TC classes that succeed THEMSELVES, which reads as a
  /// perfectly ordinary promotion.
  String _classType = 'PROMOTIONAL';
  static const _classTypes = ['PROMOTIONAL', 'TERMINAL', 'COMPLETED'];
  static const _classTypeLabels = {
    'PROMOTIONAL': 'Promotional — moves up to the next class',
    'TERMINAL': 'Terminal — final year of the course',
    'COMPLETED': 'Completed — TC class, students who have left',
  };
  static const _classTypeShort = {
    'PROMOTIONAL': 'Promotional', 'TERMINAL': 'Terminal', 'COMPLETED': 'Completed',
  };
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _courses = [];
  Map<String, String> _courName = {}; // cour_id → courname
  Map<String, String> _claName = {};  // cla_id  → claname
  // School: a section is typed (A, B ...) and saved as "<standard> <section>".
  final _section = TextEditingController();
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
    _section.dispose();
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        SupabaseService.fromSchema('class').select('*').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', _insId).eq('activestatus', 1),
      ]);
      final classRows = List<Map<String, dynamic>>.from((results[0] as List).cast<Map<String, dynamic>>());
      final courseRows = List<Map<String, dynamic>>.from((results[1] as List).cast<Map<String, dynamic>>());
      final courName = {for (final c in courseRows) c['cour_id'].toString(): (c['courname'] ?? '').toString()};
      final courOrd = <String, int>{
        for (final c in courseRows)
          if (c['ordid'] != null) c['cour_id'].toString(): (c['ordid'] as num).toInt(),
      };
      final claName = {for (final r in classRows) r['cla_id'].toString(): (r['claname'] ?? '').toString()};
      // Sort by course order → class order → class name, matching the Students sidebar.
      classRows.sort((a, b) {
        final ca = courOrd[a['cour_id']?.toString()] ?? 1 << 30;
        final cb = courOrd[b['cour_id']?.toString()] ?? 1 << 30;
        if (ca != cb) return ca.compareTo(cb);
        final oa = (a['ordid'] is num) ? (a['ordid'] as num).toInt() : 1 << 30;
        final ob = (b['ordid'] is num) ? (b['ordid'] as num).toInt() : 1 << 30;
        if (oa != ob) return oa.compareTo(ob);
        return (a['claname'] ?? '').toString().toLowerCase().compareTo((b['claname'] ?? '').toString().toLowerCase());
      });
      courseRows.sort((a, b) {
        final oa = (a['ordid'] is num) ? (a['ordid'] as num).toInt() : 1 << 30;
        final ob = (b['ordid'] is num) ? (b['ordid'] as num).toInt() : 1 << 30;
        if (oa != ob) return oa.compareTo(ob);
        return (a['courname'] ?? '').toString().toLowerCase().compareTo((b['courname'] ?? '').toString().toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _rows = classRows;
        _courses = courseRows;
        _courName = courName;
        _claName = claName;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The class type, coloured so a TC row is obvious in a list of 100.
  Widget _typePill(String? type) {
    final k = _classTypes.contains(type) ? type! : 'PROMOTIONAL';
    final status = k == 'COMPLETED'   // a TC class -- the ones to spot
        ? AppStatus.danger
        : k == 'TERMINAL'               // final year -- expected, not alarming
            ? AppStatus.warning
            : AppStatus.success;
    return Align(
      alignment: Alignment.centerLeft,
      child: AppUI.chip(_classTypeShort[k]!, status),
    );
  }

  void _edit(Map<String, dynamic> r) {
    setState(() {
      _editId = r['cla_id'] is int ? r['cla_id'] as int : int.tryParse(r['cla_id'].toString());
      _courId = r['cour_id']?.toString();
      _succId = r['succeedingclass']?.toString();
      _classType = _classTypes.contains(r['classtype']?.toString())
          ? r['classtype'].toString()
          : 'PROMOTIONAL';
      // Derive the level (trailing segment) from the saved "course-level" name.
      final lvl = (r['claname']?.toString().trim().split('-').last.trim() ?? '');
      _classLevel = _classLevels.contains(lvl) ? lvl : null;
      if (isSchool) {
        // "VI A" -> "A": drop the standard's name in front.
        final full = r['claname']?.toString().trim() ?? '';
        final std = (_courName[_courId] ?? '').trim();
        _section.text = std.isNotEmpty && full.toUpperCase().startsWith('${std.toUpperCase()} ')
            ? full.substring(std.length).trim()
            : full;
      }
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _classLevel = null;
      _courId = null;
      _succId = null;
      _classType = 'PROMOTIONAL';
      _section.clear();
    });
  }

  /// School: a section is named "<standard> <letter>" (LKG A). Its type is
  /// its standard's; it has no succeeding section.
  Future<void> _addSection() async {
    if (_courId == null) return _snack(context, 'Select a course.', AppColors.warning);
    final sec = _section.text.trim().toUpperCase();
    if (sec.isEmpty) return _snack(context, 'Enter the section (e.g. A).', AppColors.warning);
    final name = '${_courName[_courId] ?? ''} $sec'.trim();
    if (_rows.any((r) => (r['claname']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() &&
        (r['cla_id']?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      return _snack(context, '"$name" already exists.', AppColors.warning);
    }
    setState(() => _saving = true);
    try {
      // School: no type (it comes from the standard) and no succeeding section.
      final payload = {
        'claname': name,
        'cour_id': int.tryParse(_courId!),
      };
      if (_editId != null) {
        await SupabaseService.saveSchemaRow('class', payload, pkCol: 'cla_id', pkVal: _editId!);
        if (mounted) _snack(context, 'Class updated.', AppColors.success);
      } else {
        final inStd = _rows.where((r) => r['cour_id']?.toString() == _courId).length;
        await SupabaseService.saveSchemaRow('class', {
          'cla_id': await _nextId('class', 'cla_id'),
          ...payload,
          'ordid': inStd + 1,
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Class added.', AppColors.success);
      }
      final keepStd = _courId;
      _cancelEdit();
      _courId = keepStd; // adding A, B, C in a row: keep the standard picked
      await _load();
    } catch (e) {
      if (mounted) _snack(context, 'Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _add() async {
    if (isSchool) return _addSection();
    if (_courId == null) return _snack(context, 'Select a course.', AppColors.warning);
    if (_classLevel == null) return _snack(context, 'Select a class (I / II / III / IV).', AppColors.warning);
    // Class name is the course name combined with the level, e.g. "B.E-CSE-I".
    final courName = _courName[_courId] ?? '';
    final name = '$courName-$_classLevel';
    if (_rows.any((r) => (r['claname']?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() &&
        (r['cla_id']?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      return _snack(context, '"$name" already exists.', AppColors.warning);
    }
    setState(() => _saving = true);
    try {
      // Only a PROMOTIONAL class promotes. Forcing the link to null for the
      // other two is what stops a TC class succeeding itself -- the state the
      // live data is already in, and which no succeedingclass-based rule can
      // tell apart from a real promotion.
      final succ = _classType == 'PROMOTIONAL' ? _succId : null;
      final payload = {
        'claname': name,
        'cour_id': _courId == null ? null : int.tryParse(_courId!),
        'classtype': _classType,
        'succeedingclass': succ == null ? null : int.tryParse(succ),
        // Order by level so classes sort I → II → III → IV within each course.
        'ordid': _classLevels.indexOf(_classLevel!) + 1,
      };
      if (_editId != null) {
        await SupabaseService.saveSchemaRow('class', payload, pkCol: 'cla_id', pkVal: _editId!);
        if (mounted) _snack(context, 'Class updated.', AppColors.success);
      } else {
        await SupabaseService.saveSchemaRow('class', {
          'cla_id': await _nextId('class', 'cla_id'),
          ...payload,
          'ins_id': _insId,
          'activestatus': 1,
        });
        if (mounted) _snack(context, 'Class added.', AppColors.success);
      }
      final savedCourId = _courId;
      _cancelEdit();
      await _load();
      // Link the ladder now that the new class exists. Adding "MSc-I" before
      // "MSc-II" exists leaves nothing to point at, so instead of forcing the
      // user to come back and edit, every add re-links the course's chain.
      if (savedCourId != null) await _autoChainCourse(savedCourId);
    } catch (e) {
      if (mounted) _snack(context, 'Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Fill in each class's succeeding class from the next one up the ladder
  /// (I → II → III → IV, ordered by ordid) for the given course.
  ///
  /// Only ever fills BLANKS — an explicit choice is never overwritten, and the
  /// final class is correctly left with none.
  Future<void> _autoChainCourse(String courId) async {
    // Only promotional classes take part in the ladder. Without this the
    // chain would link a real final year into a TC batch -- which is exactly
    // how "B.E CSE -IV -> CSE TC 23" got into the live data.
    final ladder = _rows
        .where((r) =>
            r['cour_id']?.toString() == courId &&
            (r['classtype']?.toString() ?? 'PROMOTIONAL') == 'PROMOTIONAL')
        .toList()
      ..sort((a, b) {
        final oa = (a['ordid'] is num) ? (a['ordid'] as num).toInt() : 1 << 30;
        final ob = (b['ordid'] is num) ? (b['ordid'] as num).toInt() : 1 << 30;
        return oa.compareTo(ob);
      });
    if (ladder.length < 2) return;

    var linked = 0;
    for (var i = 0; i < ladder.length - 1; i++) {
      final current = ladder[i];
      final existing = current['succeedingclass']?.toString().trim() ?? '';
      if (existing.isNotEmpty) continue; // respect a manual choice
      final nextId = ladder[i + 1]['cla_id'];
      final claId = current['cla_id'] is int
          ? current['cla_id'] as int
          : int.tryParse(current['cla_id'].toString());
      if (claId == null || nextId == null) continue;
      try {
        await SupabaseService.saveSchemaRow('class',
            {'succeedingclass': nextId is int ? nextId : int.tryParse(nextId.toString())},
            pkCol: 'cla_id', pkVal: claId);
        linked++;
      } catch (_) {
        // A single failed link shouldn't abort the rest of the chain.
      }
    }
    if (linked > 0) {
      await _load();
      if (mounted) {
        _snack(context, 'Linked $linked class${linked == 1 ? '' : 'es'} to its succeeding class.', AppColors.success);
      }
    }
  }

  Future<void> _delete(int id) async {
    final name = _rows.firstWhere((r) => r['cla_id'].toString() == id.toString(),
        orElse: () => const {})['claname']?.toString();
    final used = await countReferencing('students', [('cla_id', id), ('stuclass', name)]);
    if (used > 0) {
      if (mounted) {
        await showMasterInUseDialog(context,
            name: name ?? schoolTerm('this class'),
            count: used,
            noun: 'student',
            fix: schoolTerm('Move them to another class first.'));
      }
      return;
    }
    if (!mounted) return;
    if (!await _confirmDelete(context, 'class')) return;
    try {
      await SupabaseService.deleteSchemaRow('class', 'cla_id', id);
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
            icon: 'book-1',
            title: _editId != null ? 'Edit Class' : 'Add Class',
            subtitle: isSchool ? 'section inside a standard — A, B, C …' : 'class / standard inside a course',
            child: FocusTraversalGroup(
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _lbl('Course'),
                SizedBox(height: 6.h),
                DropdownButtonFormField<String>(
                  initialValue: _courId,
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context, filled: _courId != null),
                  decoration: _filledFieldDec(context, schoolTerm('Select course'), filled: _courId != null),
                  items: [
                    ..._courses.map((c) => DropdownMenuItem(value: c['cour_id'].toString(), child: Text(c['courname']?.toString() ?? '', style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis))),
                  ],
                  selectedItemBuilder: (context) => [
                    ..._courses.map((c) => Align(alignment: Alignment.centerLeft, child: Text(c['courname']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
                  ],
                  // Changing the course resets the succeeding class — it
                  // must belong to the same course.
                  onChanged: (v) => setState(() {
                    _courId = v;
                    _succId = null;
                  }),
                ),
                SizedBox(height: 16.h),
                if (isSchool) ...[
                  _lbl('Section *'),
                  SizedBox(height: 6.h),
                  TextField(
                    controller: _section,
                    textCapitalization: TextCapitalization.characters,
                    style: _fieldTextStyle(context, filled: _section.text.trim().isNotEmpty),
                    decoration: _filledFieldDec(context, 'e.g. A', filled: _section.text.trim().isNotEmpty),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _add(),
                  ),
                  if (_courId != null && _section.text.trim().isNotEmpty) ...[
                    SizedBox(height: 6.h),
                    Text('Saved as "${_courName[_courId] ?? ''} ${_section.text.trim().toUpperCase()}"',
                        style: AppUI.muted),
                  ],
                ] else ...[
                _lbl('Class Name *'),
                SizedBox(height: 6.h),
                DropdownButtonFormField<String>(
                  initialValue: _classLevel,
                  icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context, filled: _classLevel != null),
                  decoration: _filledFieldDec(context, 'Select class', filled: _classLevel != null),
                  items: _classLevels
                      .map((lvl) => DropdownMenuItem(value: lvl, child: Text(lvl, style: AppUI.fieldText(context))))
                      .toList(),
                  selectedItemBuilder: (context) => _classLevels
                      .map((lvl) => Align(alignment: Alignment.centerLeft, child: Text(lvl, style: AppUI.fieldText(context, filled: true))))
                      .toList(),
                  onChanged: (v) => setState(() => _classLevel = v),
                ),
                ], // end college-only class-level picker
                if (!isSchool) ...[
                SizedBox(height: 16.h),
                _lbl('Class Type'),
                SizedBox(height: 6.h),
                DropdownButtonFormField<String>(
                  initialValue: _classType,
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(context, filled: true),
                  decoration: _filledFieldDec(context, 'Class type', filled: true),
                  items: _classTypes
                      .map((k) => DropdownMenuItem(
                          value: k,
                          child: Text(schoolTerm(_classTypeLabels[k]!),
                              overflow: TextOverflow.ellipsis,
                              style: AppUI.fieldText(context))))
                      .toList(),
                  selectedItemBuilder: (context) => _classTypes
                      .map((k) => Align(
                          alignment: Alignment.centerLeft,
                          child: Text(schoolTerm(_classTypeShort[k]!),
                              style: AppUI.fieldText(context, filled: true))))
                      .toList(),
                  // Cleared here, not just on save, so the field below greys
                  // out the moment the type changes.
                  onChanged: (v) => setState(() {
                    _classType = v ?? 'PROMOTIONAL';
                    if (_classType != 'PROMOTIONAL') _succId = null;
                  }),
                ),
                ], // end college-only class type (school: set on the standard)
                if (!isSchool) ...[
                SizedBox(height: 16.h),
                _lbl('Succeeding Class'),
                SizedBox(height: 6.h),
                Builder(builder: (_) {
                  // Succeeding class is scoped to the selected course
                  // (no course selected → no options to choose from).
                  // College: the next class of the same course. School: a section
                  // moves up into another standard's section (VI A -> VII A).
                  final succClasses = _rows.where((r) =>
                      r['cla_id']?.toString() != _editId?.toString() &&
                      _courId != null &&
                      (isSchool
                          ? r['cour_id']?.toString() != _courId
                          : r['cour_id']?.toString() == _courId)).toList();
                  final succValue =
                      succClasses.any((r) => r['cla_id'].toString() == _succId) ? _succId : null;
                  return DropdownButtonFormField<String>(
                    initialValue: succValue,
                    icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                    isExpanded: true,
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    elevation: 6,
                    style: _fieldTextStyle(context, filled: succValue != null),
                    decoration: _filledFieldDec(context, 'Auto — links when next class is added', filled: succValue != null),
                    items: [
                      DropdownMenuItem<String>(
                        value: '',
                        child: Text('None — final class',
                            style: AppUI.fieldText(context).copyWith(color: AppColors.textSecondary)),
                      ),
                      ...succClasses.map((r) => DropdownMenuItem(value: r['cla_id'].toString(), child: Text(r['claname']?.toString() ?? '', style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis))),
                    ],
                    selectedItemBuilder: (context) => [
                      Align(alignment: Alignment.centerLeft, child: Text('None — final class', style: AppUI.fieldText(context, filled: true))),
                      ...succClasses.map((r) => Align(alignment: Alignment.centerLeft, child: Text(r['claname']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
                    ],
                    // Disabled for COMPLETED and TC: neither promotes, so
                    // offering a target would only invite the contradiction.
                    onChanged: _classType != 'PROMOTIONAL'
                        ? null
                        : (v) => setState(() => _succId = (v == null || v.isEmpty) ? null : v),
                  );
                }),
                SizedBox(height: 6.h),
                Text(
                  _classType == 'PROMOTIONAL'
                      ? (isSchool
                          ? 'Pick the section students move up into (e.g. VI A → VII A).'
                          : 'Leave blank when adding the first class — it links automatically '
                              'once the next one exists.')
                      : _classType == 'TERMINAL'
                          ? 'The final year of the course, so it promotes to nothing.'
                          : 'A TC class, holding students who have left. Never promoted from.',
                  style: AppUI.muted.copyWith(height: 1.3),
                ),
                ], // end college-only succeeding class
                SizedBox(height: 18.h),
                Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _saving ? null : _add,
                      icon: Icon(_editId != null ? Icons.save : Icons.add, size: 16),
                      label: Text(_editId != null ? 'Update' : 'Add'),
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
        ),
        SizedBox(width: AppUI.gap),
        Expanded(
          child: _listCard(
            icon: 'book-1',
            title: 'Classes',
            subtitle: 'all classes in this institution',
            count: _rows.length,
            countLabel: 'classes',
            action: _importButton(context, title: 'Class', tabIndex: 3, disabled: _saving, onReturn: _load),
            headerCells: [
              SizedBox(width: 50.w, child: Text('S NO.', style: _h())),
              Expanded(flex: 2, child: Text(schoolTerm('COURSE'), style: _h())),
              Expanded(flex: 2, child: Text(schoolTerm('CLASS'), style: _h())),
              if (!isSchool) Expanded(flex: 2, child: Text('SUCCEEDING', style: _h())),
              if (!isSchool) SizedBox(width: 110.w, child: Text('TYPE', style: _h())),
              SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _h())),
            ],
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? AppUI.empty(title: schoolTerm('No classes'), why: schoolTerm('Add a class with the form on the left, or use Import CSV/Excel.'), icon: 'book-1')
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r['cla_id'] is int ? r['cla_id'] as int : int.tryParse(r['cla_id'].toString()) ?? 0;
                          return Container(
                            color: i.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                            child: Row(children: [
                              SizedBox(width: 50.w, child: Text('${i + 1}', style: _c())),
                              Expanded(flex: 2, child: Text(_courName['${r['cour_id'] ?? ''}'] ?? '', style: _c())),
                              Expanded(flex: 2, child: Text(r['claname']?.toString() ?? '', style: _c())),
                              if (!isSchool) Expanded(flex: 2, child: Text(_claName['${r['succeedingclass'] ?? ''}'] ?? '', style: _c())),
                              if (!isSchool) SizedBox(width: 110.w, child: _typePill(r['classtype']?.toString())),
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
