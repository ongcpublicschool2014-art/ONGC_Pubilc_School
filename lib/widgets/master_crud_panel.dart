import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../utils/app_theme.dart';
import '../utils/auth_provider.dart';
import '../utils/friendly_error.dart';
import '../services/admission_service.dart';
import '../screens/admin/master_import_screen.dart';
import 'app_icon.dart';
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
  /// Defaults to '${title.toLowerCase()}s'.
  final String? countLabel;
  /// When set, an "Import" button is shown that opens the bulk Excel/CSV
  /// importer ([MasterImportScreen]) at this tab index (0 = Admission Type,
  /// 1 = Quota). Leave null to hide the button for masters without an importer.
  final int? importTabIndex;
  /// Some lookup tables (e.g. concessioncategory) have no `createdby` audit
  /// column. Set false to omit it from inserts so the save doesn't fail.
  final bool includeCreatedBy;
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
      _snack('Enter a ${widget.title.toLowerCase()} name.', AppColors.warning);
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
      _snack('Save failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${widget.title}'),
        content: Text('Remove "$name"?'),
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
      _snack('${widget.title} removed.', AppColors.success);
      await _load();
    } catch (e) {
      _snack('Delete failed. ${friendlyError(e)}', AppColors.error);
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
            shape: const Border(bottom: BorderSide(color: AppColors.border)),
            title: Row(
              children: [
                const AppIcon('document-upload', size: 20, color: AppColors.primary),
                SizedBox(width: 10.w),
                Text('Import ${widget.title}',
                    style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
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
                  style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
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
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
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
      _snack('Nothing to import.', AppColors.warning);
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
        'Imported $added ${widget.title.toLowerCase()}${added == 1 ? '' : 's'}'
        '${skipped > 0 ? ', skipped $skipped duplicate${skipped == 1 ? '' : 's'}' : ''}.',
        AppColors.success,
      );
    } catch (e) {
      await _load();
      _snack('Import stopped after $added added. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── design helpers (mirror master_data_screen / fee-master / admission-master) ──

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


  Widget _importButton() {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final btnHeight = compact ? 30.0 : 40.0;
    final iconSize = compact ? 12.0 : 16.0;
    final hPad = compact ? 10.0 : 18.0;
    final radius = compact ? 6.0 : 10.0;
    final textSize = compact ? 11.0 : 13.0;
    return SizedBox(
      height: btnHeight,
      child: ElevatedButton.icon(
        onPressed: _saving ? null : _openImport,
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

  /// Lightweight paste-a-list import button for simple name-only masters
  /// (shown when there is no full CSV/Excel importer for this master).
  Widget _bulkImportButton() {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final btnHeight = compact ? 30.0 : 40.0;
    final iconSize = compact ? 12.0 : 16.0;
    final hPad = compact ? 10.0 : 18.0;
    final radius = compact ? 6.0 : 10.0;
    final textSize = compact ? 11.0 : 13.0;
    return SizedBox(
      height: btnHeight,
      child: ElevatedButton.icon(
        onPressed: _saving ? null : _bulkImport,
        icon: AppIcon('document-upload', size: iconSize, color: Colors.white),
        label: const Text('Import'),
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
        SizedBox(width: 16.w),
        Expanded(child: _listPanel()),
      ],
    );
  }

  /// Add/Edit card. White fill, 10r radius, full border, 20.w padding. Title
  /// row: amber icon + 15.sp w700 title. Bold-black label above the input.
  Widget _addPanel() {
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
            style: _fieldTextStyle().copyWith(color: _nameController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            textCapitalization: TextCapitalization.characters,
            decoration: _filledFieldDec('Enter ${widget.title.toLowerCase()} name', filled: _nameController.text.trim().isNotEmpty),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _add(),
          ),
          SizedBox(height: 18.h),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _add,
                  icon: _saving
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(_editId != null ? Icons.save : Icons.add, size: 16),
                  label: Text(_editId != null ? 'Update' : 'Add'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
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

  /// List card. White fill, 10r radius, full border, 16.w padding. Title bar:
  /// amber icon + 15.sp w700 title + amber count badge + Spacer + optional
  /// amber Import CSV/Excel button. Inside is the inner bordered table card.
  Widget _listPanel() {
    final countLabel = widget.countLabel ?? '${widget.title.toLowerCase()}s';
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
              CardTitleBlock(icon: widget.icon, title: '${widget.title}s', subtitle: 'all ${widget.title.toLowerCase()} records'),
              SizedBox(width: 10.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text('${_rows.length} $countLabel',
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
              ),
              const Spacer(),
              if (widget.importTabIndex != null) _importButton() else _bulkImportButton(),
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
                            ? Center(child: Text('No ${widget.title.toLowerCase()} records',
                                style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                            : ListView.separated(
                                itemCount: _rows.length,
                                separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border.withValues(alpha: 0.5)),
                                itemBuilder: (_, i) {
                                  final r = _rows[i];
                                  final id = r[widget.idCol] is int
                                      ? r[widget.idCol] as int
                                      : int.tryParse(r[widget.idCol].toString()) ?? 0;
                                  final name = r[widget.nameCol]?.toString() ?? '';
                                  return Container(
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
