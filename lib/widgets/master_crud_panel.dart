import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../utils/app_text.dart';
import '../utils/app_theme.dart';
import '../utils/auth_provider.dart';
import '../utils/friendly_error.dart';
import '../utils/master_usage.dart';
import '../services/admission_service.dart';
import '../screens/admin/master_import_screen.dart';
import 'app_icon.dart';
import 'app_ui.dart';
import 'card_title_block.dart';

/// Reusable add/list/delete panel for a simple smallint-PK lookup master
/// (id + name). A left "Add" form and a right table with a per-row delete,
/// matching the Admission Master layout. Used by Admission Master and the
/// Master Data → Semester tab.
class MasterCrudPanel extends StatefulWidget {
  final String table;
  final String idCol;
  final String nameCol;
  final String title;
  /// AppIcon name used in the Add card and list-card title bar (e.g. 'people',
  /// 'discount-shape'). Defaults to 'category' if not provided.
  final String icon;
  /// Plural noun for the count badge ("X groups", "X communities", ...).
  /// Defaults to the lower-case plural of [title].
  final String? countLabel;
  /// When set, an "Import" button is shown that opens the bulk Excel/CSV
  /// importer ([MasterImportScreen]) at this tab index (0 = Admission Type,
  /// 1 = Quota). Leave null to hide the button for masters without an importer.
  final int? importTabIndex;
  /// Some lookup tables (e.g. concessioncategory) have no `createdby` audit
  /// column. Set false to omit it from inserts so the save doesn't fail.
  final bool includeCreatedBy;
  /// Hide the Import button entirely (add-one-at-a-time only). Used for masters
  /// like Division where bulk import isn't wanted.
  final bool hideImport;
  const MasterCrudPanel({
    super.key,
    required this.table,
    required this.idCol,
    required this.nameCol,
    required this.title,
    this.icon = 'category',
    this.countLabel,
    this.importTabIndex,
    this.includeCreatedBy = true,
    this.hideImport = false,
  });

  @override
  State<MasterCrudPanel> createState() => _MasterCrudPanelState();
}

class _MasterCrudPanelState extends State<MasterCrudPanel> with AutomaticKeepAliveClientMixin {
  final _nameController = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  int? _editId; // non-null while editing an existing row
  bool _loading = true;
  bool _saving = false;

  @override
  bool get wantKeepAlive => true;

  /// Display plural of the title: "Community" -> "Communities",
  /// "Quota" -> "Quotas". Display only.
  String get _pluralTitle {
    final t = widget.title;
    if (t.length > 1 && t.endsWith('y') && !'aeiou'.contains(t[t.length - 2].toLowerCase())) {
      return '${t.substring(0, t.length - 1)}ies';
    }
    return '${t}s';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await AdmissionService.getMasterRows(widget.table, widget.idCol);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  void _edit(int id, String name) {
    setState(() {
      _editId = id;
      _nameController.text = name;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editId = null;
      _nameController.clear();
    });
  }

  Future<void> _add() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _snack('Enter the ${widget.title.toLowerCase()} name.', AppColors.warning);
      return;
    }
    if (_rows.any((r) => (r[widget.nameCol]?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() &&
        (r[widget.idCol]?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      _snack('"$name" already exists.', AppColors.warning);
      return;
    }
    final auth = context.read<AuthProvider>();
    setState(() => _saving = true);
    try {
      if (_editId != null) {
        await AdmissionService.updateMasterRow(widget.table, widget.idCol, _editId!, {widget.nameCol: name});
        _snack('${widget.title} updated.', AppColors.success);
      } else {
        final id = await AdmissionService.nextMasterId(widget.table, widget.idCol);
        await AdmissionService.addMasterRow(widget.table, {
          widget.idCol: id,
          widget.nameCol: name,
          'ins_id': auth.insId,
          'activestatus': 1,
          if (widget.includeCreatedBy) 'createdby': auth.userName,
        });
        _snack('${widget.title} added.', AppColors.success);
      }
      _nameController.clear();
      _editId = null;
      await _load();
    } catch (e) {
      _snack('Could not save the ${widget.title.toLowerCase()}. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// What each master this panel drives is referenced BY.
  ///
  /// Keyed on the table, so adding a new master here without an entry is
  /// visible: it gets no check, and that is a decision rather than an
  /// oversight. The id is listed before the name deliberately -- see
  /// countReferencing.
  static const _usage = <String, List<(String, String, String, String, String)>>{
    // table              refs table   id col    name col        noun       what to do
    'admissiontype':     [('students', 'adm_id', 'admname',      'student', 'Change their admission type first.')],
    'quota':             [('students', 'quo_id', 'quoname',      'student', 'Change their quota first.')],
    'concessioncategory':[('students', 'con_id', 'stucondesc',   'student', 'Remove the concession from them first.')],
    'community':         [('students', '',       'community',    'student', 'Change their community first.')],
    // Division: set on a standard (course.div_id) and copied to students by name.
    'division':          [('course',   'div_id', '',             'standard', 'Set another division (or None) on those standards first.'),
                          ('students', '',       'division',     'student',  'Change their division first.')],
    // Medium: students carry it by name (students.medium).
    'medium':            [('students', '',       'medium',       'student',  'Change their medium first.')],
  };

  /// Refused before the confirmation dialog: being asked "are you sure?" and
  /// only then told it was never allowed is worse than not being asked.
  Future<bool> _blockedByUsage(int id, String name) async {
    final refs = _usage[widget.table];
    if (refs == null) return false;
    for (final (refTable, idCol, nameCol, noun, fix) in refs) {
      final n = await countReferencing(refTable, [
        if (idCol.isNotEmpty) (idCol, id),
        if (nameCol.isNotEmpty) (nameCol, name),
      ]);
      if (n == 0) continue;
      if (mounted) {
        await showMasterInUseDialog(context,
            name: name, count: n, noun: noun, fix: fix);
      }
      return true;
    }
    return false;
  }

  Future<void> _delete(int id, String name) async {
    if (await _blockedByUsage(id, name)) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${widget.title}'),
        content: Text('Delete "$name"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AdmissionService.deleteMasterRow(widget.table, widget.idCol, id);
      _snack('${widget.title} deleted.', AppColors.success);
      await _load();
    } catch (e) {
      _snack('Could not delete "$name". ${friendlyError(e)}', AppColors.error);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _openImport() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: AppColors.surface,
          appBar: AppBar(
            backgroundColor: Colors.white,
            foregroundColor: AppColors.textPrimary,
            elevation: 0,
            shape: const Border(bottom: BorderSide(color: AppColors.cardBorder)),
            title: Row(
              children: [
                const AppIcon('document-upload', size: 20, color: AppColors.primary),
                SizedBox(width: 10.w),
                Text('Import ${widget.title}', style: AppUI.cardTitle),
              ],
            ),
          ),
          body: Padding(
            padding: EdgeInsets.all(16.w),
            child: MasterImportScreen(
              initialTabIndex: widget.importTabIndex!,
              showInternalTabs: false,
            ),
          ),
        ),
      ),
    );
    // The importer writes directly to the master table; refresh the list so
    // newly imported rows appear after returning from the import screen.
    if (mounted) await _load();
  }

  /// Lightweight bulk import for simple name-only masters (Community, Concession,
  /// Division…). Paste one name per line (commas also split); duplicates and
  /// names already present are skipped.
  Future<void> _bulkImport() async {
    final auth = context.read<AuthProvider>();
    final ctrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Import ${widget.title}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Paste one ${widget.title.toLowerCase()} per line. '
                  'Duplicates and existing records are skipped.',
                  style: AppUI.muted),
              SizedBox(height: 10.h),
              TextField(
                controller: ctrl,
                minLines: 6,
                maxLines: 12,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                style: _fieldTextStyle(),
                decoration: _filledFieldDec('e.g.\nBC\nMBC\nSC\nST\nOC'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    final raw = ctrl.text;
    ctrl.dispose();
    if (go != true) return;

    // Split on newlines/commas, trim, drop blanks, dedupe (case-insensitive).
    final seen = <String>{};
    final names = <String>[];
    for (final part in raw.split(RegExp(r'[\r\n,]+'))) {
      final n = part.trim();
      if (n.isEmpty) continue;
      if (seen.add(n.toLowerCase())) names.add(n);
    }
    if (names.isEmpty) {
      _snack('Nothing to import. Paste at least one name, one per line.', AppColors.warning);
      return;
    }

    final existing = _rows
        .map((r) => r[widget.nameCol]?.toString().trim().toLowerCase() ?? '')
        .toSet();
    setState(() => _saving = true);
    int added = 0, skipped = 0;
    try {
      for (final name in names) {
        if (existing.contains(name.toLowerCase())) {
          skipped++;
          continue;
        }
        final id = await AdmissionService.nextMasterId(widget.table, widget.idCol);
        await AdmissionService.addMasterRow(widget.table, {
          widget.idCol: id,
          widget.nameCol: name,
          'ins_id': auth.insId,
          'activestatus': 1,
          if (widget.includeCreatedBy) 'createdby': auth.userName,
        });
        existing.add(name.toLowerCase());
        added++;
      }
      await _load();
      _snack(
        'Imported $added ${added == 1 ? widget.title.toLowerCase() : _pluralTitle.toLowerCase()}'
        '${skipped > 0 ? ', skipped $skipped duplicate${skipped == 1 ? '' : 's'}' : ''}.',
        AppColors.success,
      );
    } catch (e) {
      await _load();
      _snack('Import stopped after $added record${added == 1 ? ' was' : 's were'} added. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── design helpers (mirror master_data_screen / fee-master / admission-master) ──

  Widget _lbl(String text) => Text(text, style: AppUI.label);

  InputDecoration _filledFieldDec(String hint, {bool filled = false}) =>
      AppUI.field(context, hint, filled: filled);

  TextStyle _fieldTextStyle() => AppUI.fieldText(context);

  TextStyle _hStyle() => AppUI.tableHead;
  TextStyle _cStyle() => AppUI.cell;


  Widget _importButton() {
    return ElevatedButton.icon(
      onPressed: _saving ? null : _openImport,
      icon: AppIcon('document-upload', size: AppBtn.iconSize(context), color: Colors.white),
      label: const Text(AppText.import),
    );
  }

  /// Lightweight paste-a-list import button for simple name-only masters
  /// (shown when there is no full CSV/Excel importer for this master).
  Widget _bulkImportButton() {
    return ElevatedButton.icon(
      onPressed: _saving ? null : _bulkImport,
      icon: AppIcon('document-upload', size: AppBtn.iconSize(context), color: Colors.white),
      label: const Text(AppText.import),
    );
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // No outer Padding — the parent (pill-tab page shell) controls breathing
    // room; this widget renders edge-to-edge inside the TabBarView.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 320.w, child: _addPanel()),
        SizedBox(width: AppUI.gap),
        Expanded(child: _listPanel()),
      ],
    );
  }

  /// Add/Edit card: the kit card with a title block and a labelled input.
  Widget _addPanel() {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: FocusTraversalGroup(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          CardTitleBlock(
            icon: widget.icon,
            title: '${_editId != null ? 'Edit' : 'Add'} ${widget.title}',
            subtitle: 'create a new ${widget.title.toLowerCase()} record',
          ),
          SizedBox(height: 20.h),
          _lbl('${widget.title} Name *'),
          SizedBox(height: 6.h),
          TextField(
            controller: _nameController,
            style: AppUI.fieldText(context, filled: _nameController.text.trim().isNotEmpty),
            textCapitalization: TextCapitalization.characters,
            decoration: _filledFieldDec('Enter ${widget.title.toLowerCase()} name', filled: _nameController.text.trim().isNotEmpty),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _add(),
          ),
          SizedBox(height: 16.h),
          AppUI.requiredNote(),
          SizedBox(height: 12.h),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _add,
                  icon: _saving
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(_editId != null ? Icons.save : Icons.add, size: 16),
                  label: Text(_editId != null ? 'Update' : 'Add'),
                ),
              ),
              if (_editId != null) ...[
                SizedBox(width: 8.w),
                OutlinedButton(onPressed: _saving ? null : _cancelEdit, child: const Text('Cancel')),
              ],
            ],
          ),
        ],
        ),
      ),
    );
  }

  /// List card: the kit card with a title block, count chip, optional
  /// Import button, and the inner bordered table.
  Widget _listPanel() {
    final countLabel = widget.countLabel ?? _pluralTitle.toLowerCase();
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4.w, right: 4.w, bottom: 10.h),
            child: Row(children: [
              CardTitleBlock(icon: widget.icon, title: _pluralTitle, subtitle: 'all ${widget.title.toLowerCase()} records'),
              SizedBox(width: 10.w),
              AppUI.chip('${_rows.length} ${_rows.length == 1 ? _singular(countLabel) : countLabel}', AppStatus.info),
              const Spacer(),
              if (!widget.hideImport)
                (widget.importTabIndex != null ? _importButton() : _bulkImportButton()),
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
                    decoration: AppUI.tableHeadBar,
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    child: Row(
                      children: [
                        SizedBox(width: 50.w, child: Text('S NO.', style: _hStyle())),
                        Expanded(child: Text(widget.title.toUpperCase(), style: _hStyle())),
                        SizedBox(width: 90.w, child: Text('ACTION', textAlign: TextAlign.center, style: _hStyle())),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _rows.isEmpty
                            ? AppUI.empty(
                                title: 'No ${widget.title.toLowerCase()} records',
                                why: 'Nothing has been added yet. Use the Add form on the left.',
                                icon: widget.icon)
                            : ListView.separated(
                                itemCount: _rows.length,
                                separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                                itemBuilder: (_, i) {
                                  final r = _rows[i];
                                  final id = r[widget.idCol] is int
                                      ? r[widget.idCol] as int
                                      : int.tryParse(r[widget.idCol].toString()) ?? 0;
                                  final name = r[widget.nameCol]?.toString() ?? '';
                                  return Container(
                                    // Alternate rows, like every other master list.
                                    color: i.isEven ? Colors.white : AppColors.surface,
                                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                                    child: Row(
                                      children: [
                                        SizedBox(width: 50.w, child: Text('${i + 1}', style: _cStyle())),
                                        Expanded(child: Text(name, style: _cStyle())),
                                        SizedBox(
                                          width: 90.w,
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              InkWell(
                                                onTap: () => _edit(id, name),
                                                borderRadius: BorderRadius.circular(6.r),
                                                child: Padding(
                                                  padding: EdgeInsets.all(4.w),
                                                  child: const AppIcon('edit-2', size: 16, color: AppColors.primary),
                                                ),
                                              ),
                                              SizedBox(width: 8.w),
                                              InkWell(
                                                onTap: () => _delete(id, name),
                                                borderRadius: BorderRadius.circular(6.r),
                                                child: Padding(
                                                  padding: EdgeInsets.all(4.w),
                                                  child: const AppIcon('trash', size: 16, color: AppColors.error),
                                                ),
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
            ),
          ),
        ],
      ),
    );
  }
}

/// "divisions" -> "division", "communities" -> "community", "matches" -> "match"
/// for a count of 1.
String _singular(String plural) {
  if (plural.endsWith('ies')) return '${plural.substring(0, plural.length - 3)}y';
  if (RegExp(r'(ches|shes|sses|xes)$').hasMatch(plural)) return plural.substring(0, plural.length - 2);
  if (plural.endsWith('s')) return plural.substring(0, plural.length - 1);
  return plural;
}
