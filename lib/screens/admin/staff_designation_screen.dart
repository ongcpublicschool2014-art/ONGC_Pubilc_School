import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';

import '../../widgets/app_icon.dart';
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
          const SnackBar(content: Text('Failed to save designation'), backgroundColor: Colors.red),
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
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
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
          const SnackBar(content: Text('Failed to delete designation'), backgroundColor: Colors.red),
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

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(fontSize: 13.sp),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r)),
      contentPadding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(20.w),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Form panel
          SizedBox(
            width: 360.w,
            child: Container(
              padding: EdgeInsets.all(20.w),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        AppIcon('personalcard', color: AppColors.accent, size: 18),
                        SizedBox(width: 8.w),
                        Text(
                          'Add Designation',
                          style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    SizedBox(height: 20.h),
                    TextFormField(
                      controller: _nameController,
                      decoration: _inputDecoration('Designation Name'),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    SizedBox(height: 16.h),
                    DropdownButtonFormField<int?>(
                      value: _selectedReportTo,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      decoration: _inputDecoration('Reports To'),
                      items: [
                        DropdownMenuItem<int?>(value: null, child: Text('None', style: TextStyle(fontSize: 13.sp))),
                        ..._designations.map((d) => DropdownMenuItem<int?>(
                              value: d['des_id'] as int,
                              child: Text(d['desname']?.toString() ?? '', style: TextStyle(fontSize: 13.sp)),
                            )),
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
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accent,
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(width: 24.w),
          // Table panel
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.vertical(top: Radius.circular(12.r)),
                    ),
                    child: Row(
                      children: [
                        AppIcon('personalcard', size: 18, color: AppColors.accent),
                        SizedBox(width: 8.w),
                        Text('Designations', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Text('${_designations.length} records', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                        SizedBox(width: 12.w),
                        SizedBox(
                          height: AppBtn.height(context),
                          child: ElevatedButton.icon(
                            onPressed: _fetchDesignations,
                            icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                            label: const Text('Refresh'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF10B981),
                              foregroundColor: Colors.white,
                              elevation: 0,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Table header
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    color: const Color(0xFF6C8EEF),
                    child: Row(
                      children: [
                        SizedBox(width: 40.w, child: Text('S NO.', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: Colors.white))),
                        Expanded(flex: 3, child: Text('DESIGNATION NAME', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: Colors.white))),
                        Expanded(flex: 3, child: Text('REPORTS TO', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: Colors.white))),
                        SizedBox(width: 80.w, child: Text('ACTIONS', textAlign: TextAlign.center, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: Colors.white))),
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
                      child: Center(child: Text('No designations found', style: TextStyle(color: AppColors.textSecondary))),
                    )
                  else
                    ..._designations.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final des = entry.value;
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
                        decoration: BoxDecoration(
                          color: idx.isEven ? Colors.white : AppColors.surface,
                          border: Border(bottom: BorderSide(color: AppColors.border.withValues(alpha: 0.5))),
                        ),
                        child: Row(
                          children: [
                            SizedBox(width: 40.w, child: Text('${idx + 1}', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))),
                            Expanded(flex: 3, child: Text(des['desname']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500))),
                            Expanded(flex: 3, child: Text(_getDesignationName(des['desrepto'] as int?), style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))),
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
                                      child: AppIcon('trash', size: 16, color: Colors.red),
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
