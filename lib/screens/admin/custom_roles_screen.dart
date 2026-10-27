import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/app_ui.dart';
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
          const SnackBar(content: Text('Failed to save role'), backgroundColor: AppColors.error),
        );
      }
    } catch (e) {
      // Never let a failed save freeze the button (e.g. a permission error on
      // custuserroles before the session-gated RPC is deployed).
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save role'), backgroundColor: AppColors.error),
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
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: AppColors.error))),
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
          const SnackBar(content: Text('Failed to delete role'), backgroundColor: AppColors.error),
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
  TextStyle _th() => AppUI.tableHead;

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
                    AppUI.cardHeader(icon: 'shield-tick', title: _editingUrId != null ? 'Edit Role' : 'Add Role'),
                    SizedBox(height: 20.h),
                    TextFormField(
                      controller: _nameController,
                      style: AppUI.fieldText(context, filled: _nameController.text.trim().isNotEmpty),
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
                  // Plain header + accent count pill, matching Bank Accounts /
                  // Master Data (they don't tint the header band).
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 16.h),
                    child: Row(
                      children: [
                        const CardTitleBlock(icon: 'security-user', title: 'Custom Roles', subtitle: 'all custom roles in this institution'),
                        const Spacer(),
                        AppUI.chip('${_roles.length} roles', AppStatus.info),
                        SizedBox(width: 12.w),
                        ElevatedButton.icon(
                          onPressed: _fetchRoles,
                          icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                          label: const Text('Refresh'),
                        ),
                      ],
                    ),
                  ),
                  // Table header — same treatment as every other master table
                  // (Master Data, Fee Master): light slate band, dark bold
                  // labels. See _h() in master_data_screen.dart.
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
                    decoration: AppUI.tableHeadBar,
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
                      child: AppUI.empty(title: 'No roles found', why: 'Add one with the form on the left.', icon: 'security-user'),
                    )
                  else
                    ..._roles.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final role = entry.value;
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          border: Border(bottom: BorderSide(color: AppColors.divider)),
                        ),
                        child: Row(
                          children: [
                            SizedBox(width: 40.w, child: Text('${idx + 1}', style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
                            Expanded(flex: 3, child: Text(role['urname']?.toString() ?? '-', style: AppUI.cell)),
                            Expanded(flex: 2, child: Text(role['inscode']?.toString() ?? '-', style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
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
