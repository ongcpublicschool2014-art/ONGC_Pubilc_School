import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../utils/app_theme.dart';
import '../utils/auth_provider.dart';
import '../utils/friendly_error.dart';
import '../services/admission_service.dart';
import 'app_icon.dart';

/// Add/list/edit/delete panel for a simple smallint-PK lookup master
/// (id + name). Left form, right table. Used by Admission Master tabs.
class MasterCrudPanel extends StatefulWidget {
  final String table;
  final String idCol;
  final String nameCol;
  final String title;
  /// If true, CRUD against the per-institution schema (fromSchema); else public.
  final bool inSchema;
  /// Column name for the order field (e.g. `ordid`). When non-null, the panel
  /// auto-fills `<ordidCol> = max(existing) + 1` on insert so new rows sort
  /// last and the existing ordering is preserved. Pass null for tables that
  /// don't have an order column (e.g. `community`).
  final String? ordidCol;
  const MasterCrudPanel({
    super.key,
    required this.table,
    required this.idCol,
    required this.nameCol,
    required this.title,
    this.inSchema = false,
    this.ordidCol,
  });

  @override
  State<MasterCrudPanel> createState() => _MasterCrudPanelState();
}

class _MasterCrudPanelState extends State<MasterCrudPanel> with AutomaticKeepAliveClientMixin {
  final _nameController = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  int? _editId;
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
    final rows = await AdmissionService.getMasterRows(widget.table, widget.idCol, inSchema: widget.inSchema);
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
    if (_rows.any((r) =>
        (r[widget.nameCol]?.toString().trim().toLowerCase() ?? '') == name.toLowerCase() &&
        (r[widget.idCol]?.toString() ?? '') != (_editId?.toString() ?? ''))) {
      _snack('"$name" already exists.', AppColors.warning);
      return;
    }
    final auth = context.read<AuthProvider>();
    setState(() => _saving = true);
    try {
      if (_editId != null) {
        await AdmissionService.updateMasterRow(
            widget.table, widget.idCol, _editId!, {widget.nameCol: name},
            inSchema: widget.inSchema);
        _snack('${widget.title} updated.', AppColors.success);
      } else {
        final id = await AdmissionService.nextMasterId(widget.table, widget.idCol, inSchema: widget.inSchema);
        // No `createdby` here — half the lookup masters (clagrp, class,
        // concessioncategory, …) don't have that column, and PostgREST
        // rejects the insert when the column is unknown.
        final data = <String, dynamic>{
          widget.idCol: id,
          widget.nameCol: name,
          'ins_id': auth.insId,
          'activestatus': 1,
        };
        // Auto-assign the order field if the table supports it so new rows
        // land at the end of the current sort sequence.
        if (widget.ordidCol != null) {
          data[widget.ordidCol!] =
              await AdmissionService.nextMasterId(widget.table, widget.ordidCol!, inSchema: widget.inSchema);
        }
        await AdmissionService.addMasterRow(widget.table, data, inSchema: widget.inSchema);
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
      await AdmissionService.deleteMasterRow(widget.table, widget.idCol, id, inSchema: widget.inSchema);
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 320.w, child: _addPanel()),
          SizedBox(width: 16.w),
          Expanded(child: _listPanel()),
        ],
      ),
    );
  }

  Widget _addPanel() {
    return Container(
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
          Text('${_editId != null ? 'Edit' : 'Add'} ${widget.title}',
              style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(height: 12.h),
          TextField(
            controller: _nameController,
            style: TextStyle(fontSize: 13.sp),
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: '${widget.title} Name',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
            ),
            onSubmitted: (_) => _add(),
          ),
          SizedBox(height: 14.h),
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
    );
  }

  Widget _listPanel() {
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
            child: Row(
              children: [
                SizedBox(width: 50.w, child: Text('S.No', style: _hStyle())),
                Expanded(child: Text(widget.title.toUpperCase(), style: _hStyle())),
                SizedBox(width: 96.w, child: Text('ACTION', textAlign: TextAlign.center, style: _hStyle())),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? Center(
                        child: Text('No ${widget.title.toLowerCase()} records',
                            style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)))
                    : ListView.separated(
                        itemCount: _rows.length,
                        separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final id = r[widget.idCol] is int
                              ? r[widget.idCol] as int
                              : int.tryParse(r[widget.idCol].toString()) ?? 0;
                          final name = r[widget.nameCol]?.toString() ?? '';
                          return Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                            child: Row(
                              children: [
                                SizedBox(width: 50.w, child: Text('${i + 1}', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))),
                                Expanded(child: Text(name, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
                                SizedBox(
                                  width: 96.w,
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
                                      SizedBox(width: 10.w),
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
    );
  }

  TextStyle _hStyle() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
}
