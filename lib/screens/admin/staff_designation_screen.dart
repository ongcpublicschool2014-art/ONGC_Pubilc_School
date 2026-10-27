import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/app_ui.dart';
class StaffDesignationScreen extends StatefulWidget {
  const StaffDesignationScreen({super.key});

  @override
  State<StaffDesignationScreen> createState() => _StaffDesignationScreenState();
}

class _StaffDesignationScreenState extends State<StaffDesignationScreen> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _designations = [];

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  int? _selectedReportTo;


  @override
  void initState() {
    super.initState();
    _fetchDesignations();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _fetchDesignations() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);
    final data = await SupabaseService.getDesignations(insId);
    if (mounted) {
      setState(() {
        _designations = data;
        _isLoading = false;
      });
    }
  }

  Future<void> _saveDesignation() async {
    if (!_formKey.currentState!.validate()) return;

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);

    final success = await SupabaseService.createDesignation({
      'ins_id': insId,
      'desname': _nameController.text.trim(),
      'desrepto': _selectedReportTo,
      'activestatus': 1,
    });

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Designation created'), backgroundColor: AppColors.success),
        );
        _resetForm();
        _fetchDesignations();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save designation'), backgroundColor: AppColors.error),
        );
        setState(() => _isLoading = false);
      }
    }
  }


  Future<void> _deleteDesignation(int desId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Designation'),
        content: const Text('Are you sure you want to delete this designation?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (confirm != true) return;

    final success = await SupabaseService.deleteDesignation(desId);
    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Designation deleted'), backgroundColor: AppColors.success),
        );
        _fetchDesignations();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete designation'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  void _resetForm() {
    _nameController.clear();
    _selectedReportTo = null;

  }

  String _getDesignationName(int? desId) {
    if (desId == null) return '-';
    final match = _designations.where((d) => d['des_id'] == desId);
    return match.isNotEmpty ? (match.first['desname']?.toString() ?? '-') : '-';
  }

  InputDecoration _inputDecoration(String label, {bool filled = false}) {
    return AppUI.field(context, '', label: label, filled: filled);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(AppUI.gap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Form panel
          SizedBox(
            width: 360.w,
            child: Container(
              padding: EdgeInsets.all(AppUI.cardPad),
              decoration: AppUI.card(),
              child: Form(
                key: _formKey,
                child: FocusTraversalGroup(
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppUI.cardHeader(icon: 'personalcard', title: 'Add Designation'),
                    SizedBox(height: 20.h),
                    TextFormField(
                      controller: _nameController,
                      style: AppUI.fieldText(context, filled: _nameController.text.trim().isNotEmpty),
                      onChanged: (_) => setState(() {}),
                      decoration: _inputDecoration('Designation Name', filled: _nameController.text.trim().isNotEmpty),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    SizedBox(height: 16.h),
                    DropdownButtonFormField<int?>(
                      value: _selectedReportTo,
                      icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      decoration: _inputDecoration('Reports To', filled: _selectedReportTo != null),
                      items: [
                        DropdownMenuItem<int?>(value: null, child: Text('None', style: AppUI.fieldText(context))),
                        ..._designations.map((d) => DropdownMenuItem<int?>(
                              value: d['des_id'] as int,
                              child: Text(d['desname']?.toString() ?? '', style: AppUI.fieldText(context)),
                            )),
                      ],
                      selectedItemBuilder: (context) => [
                        Align(alignment: Alignment.centerLeft, child: Text('None', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
                        ..._designations.map((d) => Align(alignment: Alignment.centerLeft, child: Text(d['desname']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
                      ],
                      onChanged: (v) => setState(() => _selectedReportTo = v),
                    ),
                    SizedBox(height: 24.h),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isLoading ? null : _saveDesignation,
                            icon: AppIcon('add', size: 18),
                            label: const Text('Add'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                ),
              ),
            ),
          ),
          SizedBox(width: AppUI.gap),
          // Table panel
          Expanded(
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: AppUI.card(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 16.h),
                    child: Row(
                      children: [
                        const CardTitleBlock(icon: 'personalcard', title: 'Designations', subtitle: 'all staff designations in this institution'),
                        const Spacer(),
                        Text('${_designations.length} records', style: AppUI.muted),
                        SizedBox(width: 12.w),
                        ElevatedButton.icon(
                          onPressed: _fetchDesignations,
                          icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                          label: const Text('Refresh'),
                        ),
                      ],
                    ),
                  ),
                  // Table header
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
                    decoration: AppUI.tableHeadBar,
                    child: Row(
                      children: [
                        SizedBox(width: 40.w, child: Text('S NO.', style: AppUI.tableHead)),
                        AppUI.th('DESIGNATION NAME', flex: 3),
                        AppUI.th('REPORTS TO', flex: 3),
                        SizedBox(width: 80.w, child: Text('ACTIONS', textAlign: TextAlign.center, style: AppUI.tableHead)),
                      ],
                    ),
                  ),
                  // Data rows
                  if (_isLoading)
                    Padding(
                      padding: EdgeInsets.all(40.w),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_designations.isEmpty)
                    Padding(
                      padding: EdgeInsets.all(40.w),
                      child: AppUI.empty(title: 'No designations found', why: 'Add one with the form on the left.', icon: 'personalcard'),
                    )
                  else
                    ..._designations.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final des = entry.value;
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          border: Border(bottom: BorderSide(color: AppColors.divider)),
                        ),
                        child: Row(
                          children: [
                            SizedBox(width: 40.w, child: Text('${idx + 1}', style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
                            Expanded(flex: 3, child: Text(des['desname']?.toString() ?? '-', style: AppUI.cell)),
                            Expanded(flex: 3, child: Text(_getDesignationName(des['desrepto'] as int?), style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
                            SizedBox(
                              width: 80.w,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  InkWell(
                                    onTap: () => _deleteDesignation(des['des_id'] as int),
                                    borderRadius: BorderRadius.circular(6.r),
                                    child: Padding(
                                      padding: EdgeInsets.all(4.w),
                                      child: AppIcon('trash', size: 16, color: AppColors.error),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
