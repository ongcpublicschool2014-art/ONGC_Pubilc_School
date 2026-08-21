import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/card_title_block.dart';
class CustomRolesScreen extends StatefulWidget {
  const CustomRolesScreen({super.key});

  @override
  State<CustomRolesScreen> createState() => _CustomRolesScreenState();
}

class _CustomRolesScreenState extends State<CustomRolesScreen> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _roles = [];

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  int? _editingUrId;

  @override
  void initState() {
    super.initState();
    _fetchRoles();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _fetchRoles() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);
    final data = await SupabaseService.getUserRoles(insId);
    if (mounted) {
      setState(() {
        _roles = data;
        _isLoading = false;
      });
    }
  }

  Future<void> _saveRole() async {
    if (!_formKey.currentState!.validate()) return;

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.inscode;
    if (insId == null) return;

    setState(() => _isLoading = true);

    try {
      final success = _editingUrId != null
          ? await SupabaseService.updateUserRole(_editingUrId!, {
              'urname': _nameController.text.trim(),
            })
          : await SupabaseService.createUserRole({
              'ins_id': insId,
              'inscode': inscode ?? '',
              'urname': _nameController.text.trim(),
              'activestatus': 1,
            });

      if (!mounted) return;
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_editingUrId != null ? 'Role updated' : 'Role created'), backgroundColor: AppColors.success),
        );
        _resetForm();
        _fetchRoles();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save role'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      // Never let a failed save freeze the button (e.g. a permission error on
      // custuserroles before the session-gated RPC is deployed).
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save role'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _editRole(Map<String, dynamic> role) {
    setState(() {
      _editingUrId = role['ur_id'] as int;
      _nameController.text = role['urname']?.toString() ?? '';
    });
  }

  Future<void> _deleteRole(int urId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Role'),
        content: const Text('Are you sure you want to delete this role?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;

    final success = await SupabaseService.deleteUserRole(urId);
    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Role deleted'), backgroundColor: AppColors.success),
        );
        _fetchRoles();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete role'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _resetForm() {
    _nameController.clear();
    _editingUrId = null;
  }

  /// Table-header cell style, matching _h() in master_data_screen.dart so
  /// every master table reads identically.
  TextStyle _th() => TextStyle(
        fontSize: 12.sp,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: 0.3,
      );

  InputDecoration _inputDecoration(String label, {bool filled = false}) {
    final idle = filled ? AppColors.accent : AppColors.border;
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(fontSize: 13.sp),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r), borderSide: BorderSide(color: idle, width: 1.5)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r), borderSide: BorderSide(color: idle, width: 1.5)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10.r), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
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
                child: FocusTraversalGroup(
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        AppIcon('shield-tick', color: AppColors.accent, size: 18),
                        SizedBox(width: 8.w),
                        Text(
                          _editingUrId != null ? 'Edit Role' : 'Add Role',
                          style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    SizedBox(height: 20.h),
                    TextFormField(
                      controller: _nameController,
                      style: TextStyle(color: _nameController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: _nameController.text.trim().isNotEmpty ? FontWeight.w600 : null),
                      onChanged: (_) => setState(() {}),
                      decoration: _inputDecoration('Role Name', filled: _nameController.text.trim().isNotEmpty),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    SizedBox(height: 24.h),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isLoading ? null : _saveRole,
                            icon: AppIcon(_editingUrId != null ? 'save-2' : 'add', size: 18),
                            label: Text(_editingUrId != null ? 'Update' : 'Add'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.accent,
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                            ),
                          ),
                        ),
                        if (_editingUrId != null) ...[
                          SizedBox(width: 8.w),
                          TextButton(
                            onPressed: () => setState(() => _resetForm()),
                            child: const Text('Cancel'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
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
                  // Plain header + accent count pill, matching Bank Accounts /
                  // Master Data (they don't tint the header band).
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
                    child: Row(
                      children: [
                        const CardTitleBlock(icon: 'security-user', title: 'Custom Roles', subtitle: 'all custom roles in this institution'),
                        const Spacer(),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8.r),
                          ),
                          child: Text('${_roles.length} roles',
                              style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
                        ),
                        SizedBox(width: 12.w),
                        SizedBox(
                          height: AppBtn.height(context),
                          child: ElevatedButton.icon(
                            onPressed: _fetchRoles,
                            icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                            label: const Text('Refresh'),
                            style: ElevatedButton.styleFrom(
                              // App-wide Refresh green (used across 13 screens).
                              backgroundColor: const Color(0xFF10B981),
                              foregroundColor: Colors.white,
                              elevation: 0,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Table header — same treatment as every other master table
                  // (Master Data, Fee Master): light slate band, dark bold
                  // labels. See _h() in master_data_screen.dart.
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        SizedBox(width: 40.w, child: Text('S NO.', style: _th())),
                        Expanded(flex: 3, child: Text('ROLE NAME', style: _th())),
                        Expanded(flex: 2, child: Text('INS CODE', style: _th())),
                        SizedBox(width: 80.w, child: Text('ACTIONS', textAlign: TextAlign.center, style: _th())),
                      ],
                    ),
                  ),
                  // Data rows
                  if (_isLoading)
                    Padding(
                      padding: EdgeInsets.all(40.w),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_roles.isEmpty)
                    Padding(
                      padding: EdgeInsets.all(40.w),
                      child: Center(child: Text('No roles found', style: TextStyle(color: AppColors.textSecondary))),
                    )
                  else
                    ..._roles.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final role = entry.value;
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                        color: idx.isEven ? Colors.white : AppColors.surface,
                        child: Row(
                          children: [
                            SizedBox(width: 40.w, child: Text('${idx + 1}', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))),
                            Expanded(flex: 3, child: Text(role['urname']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500))),
                            Expanded(flex: 2, child: Text(role['inscode']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))),
                            SizedBox(
                              width: 80.w,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  InkWell(
                                    onTap: () => _editRole(role),
                                    borderRadius: BorderRadius.circular(6.r),
                                    child: Padding(
                                      padding: EdgeInsets.all(4.w),
                                      child: AppIcon('edit-2', size: 16, color: AppColors.accent),
                                    ),
                                  ),
                                  SizedBox(width: 8.w),
                                  InkWell(
                                    onTap: () => _deleteRole(role['ur_id'] as int),
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
