import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../models/institution_user_model.dart';

import '../../widgets/app_icon.dart';
class AdminCreationScreen extends StatefulWidget {
  const AdminCreationScreen({super.key});

  @override
  State<AdminCreationScreen> createState() => _AdminCreationScreenState();
}

class _AdminCreationScreenState extends State<AdminCreationScreen> {
  bool _isLoading = false;
  List<InstitutionUserModel> _users = [];

  // Form controllers
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  String? _selectedDesignation;
  int? _selectedDesId;
  int? _selectedReportTo;
  String? _selectedRole;
  InstitutionUserModel? _selectedUser; // for drilldown

  List<Map<String, dynamic>> _designationsList = [];
  List<Map<String, dynamic>> _rolesList = [];

  @override
  void initState() {
    super.initState();
    _fetchUsers();
    _fetchDesignations();
    _fetchRoles();
  }

  Future<void> _fetchDesignations() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    final list = await SupabaseService.getDesignations(insId);
    if (mounted) setState(() => _designationsList = list);
  }

  Future<void> _fetchRoles() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    final list = await SupabaseService.getRoles(insId);
    if (mounted) setState(() => _rolesList = list);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _fetchUsers() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);
    try {
      final users = await SupabaseService.getInstitutionUsers(insId);
      if (!mounted) return;
      setState(() => _users = users);
    } catch (e) {
      debugPrint('Error loading users: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }


  void _showAddDesignationDialog() {
    final controller = TextEditingController();
    int? reportsTo;
    String? nameError;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              AppIcon.linear('personalcard', size: 18, color: AppColors.textSecondary),
              SizedBox(width: 8.w),
              Text('Add Designation', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Designation Name', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
              SizedBox(height: 6.h),
              TextField(
                controller: controller,
                autofocus: true,
                onChanged: (v) {
                  final overflow = v.trim().length > 50;
                  final next = overflow ? 'Designation must be less than 50 characters' : null;
                  if (nameError != next) {
                    setDialogState(() => nameError = next);
                  }
                },
                decoration: InputDecoration(
                  hintText: 'Enter designation name',
                  border: const OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                  errorText: nameError,
                ),
              ),
              SizedBox(height: 16.h),
              Text('Reports To', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
              SizedBox(height: 6.h),
              DropdownButtonFormField<int?>(
                value: reportsTo,
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(12),
                elevation: 6,
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  ..._designationsList.map((d) => DropdownMenuItem(
                        value: d['des_id'] as int?,
                        child: Text(d['desname'] as String),
                      )),
                ],
                onChanged: (v) => setDialogState(() => reportsTo = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton.icon(
              icon: AppIcon('add', size: 16, color: Colors.white),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h)),
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setDialogState(() => nameError = 'Designation name is required');
                  return;
                }
                if (name.length > 50) {
                  setDialogState(() => nameError = 'Designation cannot exceed 50 characters');
                  return;
                }
                final auth = Provider.of<AuthProvider>(ctx, listen: false);
                final insId = auth.insId;
                if (insId == null) return;
                final ok = await SupabaseService.createDesignation({
                  'ins_id': insId,
                  'desname': name,
                  'desrepto': reportsTo,
                  'activestatus': 1,
                });
                if (!mounted) return;
                if (ok) {
                  Navigator.pop(ctx);
                  final desigs = await SupabaseService.getDesignations(insId);
                  setState(() {
                    _designationsList = desigs;
                    _selectedDesignation = name;
                    final match = desigs.firstWhere((d) => d['desname'] == name, orElse: () => {});
                    _selectedDesId = match['des_id'] as int?;
                  });
                }
              },
              label: const Text('Add', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createUser() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedDesignation == null || _selectedRole == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all required fields')),
      );
      return;
    }

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.inscode;
    if (insId == null) return;

    final roleData = _rolesList.firstWhere((r) => r['urname'] == _selectedRole);

    final data = {
      'ins_id': insId,
      'inscode': inscode ?? '',
      'usename': _nameController.text.trim(),
      'usemail': _emailController.text.trim(),
      'usephone': _phoneController.text.trim(),
      'usepassword': _passwordController.text.trim(),
      'usestadate': DateTime.now().toIso8601String().split('T').first,
      'useotpstatus': 0,
      'usedob': '2000-01-01',
      'ur_id': roleData['ur_id'],
      'urname': _selectedRole,
      'des_id': _selectedDesId,
      'desname': _selectedDesignation,
      'userepto': _selectedReportTo ?? 0,
      'activestatus': 1,
    };

    setState(() => _isLoading = true);
    final success = await SupabaseService.createInstitutionUser(data);
    if (mounted) {
      setState(() => _isLoading = false);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('User created successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        _clearForm();
        _fetchUsers();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to create user. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _clearForm() {
    // Reset first so onUserInteraction fields drop their "touched" flag —
    // otherwise autovalidation re-flags the now-empty fields as "Required".
    _formKey.currentState?.reset();
    _nameController.clear();
    _emailController.clear();
    _phoneController.clear();
    _passwordController.clear();
    setState(() {
      _selectedDesignation = null;
      _selectedDesId = null;
      _selectedReportTo = null;
      _selectedRole = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              AppIcon('security-user',
                  color: AppColors.accent, size: 18),
              SizedBox(width: 10.w),
              Text(
                'User Creation',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: 20.h),

          // Form + User list side by side
          LayoutBuilder(builder: (context, constraints) {
            final screenWidth = MediaQuery.of(context).size.width;
            final isCompact = screenWidth <= 1366;
            return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: Creation Form
              Expanded(
                flex: 3,
                child: _buildCreationForm(),
              ),
              SizedBox(width: isCompact ? 12.w : 24.w),
              // Right: Existing Users List
              Expanded(
                flex: 7,
                child: _buildUserList(),
              ),
            ],
          );
          }),
        ],
      ),
    );
  }

  Widget _buildCreationForm() {
    return Container(
      padding: EdgeInsets.all(20.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIcon('user-add',
                    size: 18, color: AppColors.accent),
                SizedBox(width: 8.w),
                Text('Create New User',
                    style:
                        TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
              ],
            ),
            SizedBox(height: 20.h),

            // Staff Designation
            Text('Staff Designation *',
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                    color: Colors.black)),
            SizedBox(height: 6.h),
            DropdownButtonFormField<String>(
              value: _selectedDesignation,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _inputDecoration(context, 'Select designation'),
              style: _inputTextStyle(context),
              items: [
                ..._designationsList.map((d) => DropdownMenuItem(
                      value: d['desname'] as String,
                      child: Text(d['desname'] as String),
                    )),
                DropdownMenuItem(
                  value: '__add_new__',
                  child: Row(
                    children: [
                      AppIcon.linear('add-circle', size: 16, color: Color(0xFF00BFA5)),
                      SizedBox(width: 8.w),
                      Text('Add New Designation', style: TextStyle(color: Color(0xFF00BFA5), fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
              onChanged: (v) {
                if (v == '__add_new__') {
                  _showAddDesignationDialog();
                  return;
                }
                final match = _designationsList.firstWhere(
                  (d) => d['desname'] == v,
                  orElse: () => {},
                );
                setState(() {
                  _selectedDesignation = v;
                  _selectedDesId = match['des_id'] as int?;
                });
              },
              validator: (v) => v == null || v == '__add_new__' ? 'Required' : null,
            ),
            SizedBox(height: 16.h),

            // Designation Report To
            Text('Designation Report To',
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                    color: Colors.black)),
            SizedBox(height: 6.h),
            DropdownButtonFormField<int>(
              value: _selectedReportTo,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _inputDecoration(context, 'Select reporting person'),
              style: _inputTextStyle(context),
              items: [
                const DropdownMenuItem(value: 0, child: Text('None')),
                ..._users.map((u) => DropdownMenuItem(
                      value: u.useId,
                      child: Text('${u.usename} (${u.desname})'),
                    )),
              ],
              onChanged: (v) => setState(() => _selectedReportTo = v),
            ),
            SizedBox(height: 16.h),

            // Role
            Text('Role *',
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                    color: Colors.black)),
            SizedBox(height: 6.h),
            DropdownButtonFormField<String>(
              value: _selectedRole,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _inputDecoration(context, 'Select role'),
              style: _inputTextStyle(context),
              items: _rolesList
                  .where((r) => (r['urname'] as String) != 'Admin')
                  .map((r) => DropdownMenuItem(
                      value: r['urname'] as String,
                      child: Text(r['urname'] as String)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedRole = v),
              validator: (v) => v == null ? 'Required' : null,
            ),
            SizedBox(height: 16.h),

            // User Name
            Text('User Name *',
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                    color: Colors.black)),
            SizedBox(height: 6.h),
            TextFormField(
              controller: _nameController,
              decoration: _inputDecoration(context, 'Enter user name'),
              style: _inputTextStyle(context),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return 'Required';
                if (s.length > 50) return 'User name must be less than 50 characters';
                return null;
              },
            ),
            SizedBox(height: 16.h),

            // Email
            Text('Email *',
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                    color: Colors.black)),
            SizedBox(height: 6.h),
            TextFormField(
              controller: _emailController,
              decoration: _inputDecoration(context, 'Enter email'),
              style: _inputTextStyle(context),
              keyboardType: TextInputType.emailAddress,
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return 'Required';
                final emailRe = RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');
                if (!emailRe.hasMatch(s)) return 'Enter a valid email address';
                return null;
              },
            ),
            SizedBox(height: 16.h),

            // Phone
            Text('Phone *',
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                    color: Colors.black)),
            SizedBox(height: 6.h),
            TextFormField(
              controller: _phoneController,
              decoration: _inputDecoration(context, 'Enter phone number'),
              style: _inputTextStyle(context),
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return 'Required';
                if (s.length != 10) return 'Phone must be 10 digits';
                return null;
              },
            ),
            SizedBox(height: 16.h),

            // Password
            Text('Password *',
                style: TextStyle(
                    fontSize: 13.sp,
                    fontWeight: FontWeight.w800,
                    color: Colors.black)),
            SizedBox(height: 6.h),
            TextFormField(
              controller: _passwordController,
              decoration: _inputDecoration(context, 'Enter password').copyWith(
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  icon: AppIcon(
                    _obscurePassword ? 'eye-slash' : 'eye',
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              style: _inputTextStyle(context),
              obscureText: _obscurePassword,
              validator: (v) {
                final s = v ?? '';
                if (s.isEmpty) return 'Required';
                if (s.length < 8) return 'Password must be at least 8 characters';
                return null;
              },
            ),
            SizedBox(height: 24.h),

            // Buttons — full-width pair (Clear + Create User) sharing the
            // form row 50/50.
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: AppBtn.height(context),
                    child: OutlinedButton.icon(
                      onPressed: _clearForm,
                      icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: AppColors.textPrimary),
                      label: const Text('Clear'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.border),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: AppBtn.gap(context)),
                Expanded(
                  child: SizedBox(
                    height: AppBtn.height(context),
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _createUser,
                      icon: _isLoading
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: const CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : AppIcon('user-add', size: AppBtn.iconSize(context), color: Colors.white),
                      label: const Text('Create User'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _inputTextStyle(BuildContext context) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    return TextStyle(
      fontWeight: FontWeight.w500,
      fontSize: compact ? 11 : 14,
      color: const Color(0xFF555555),
    );
  }

  InputDecoration _inputDecoration(BuildContext context, String hint) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final textSize = compact ? 11.0 : 14.0;
    final hPad = compact ? 8.0 : 14.0;
    final vPad = compact ? 5.0 : 14.0;
    final radius = compact ? 5.0 : 8.0;

    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: textSize),
      contentPadding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: AppColors.accent),
      ),
      filled: true,
      fillColor: Colors.white,
    );
  }

  Widget _buildUserList() {
    // If a user is selected, show drilldown
    if (_selectedUser != null) {
      return _buildUserDetail(_selectedUser!);
    }

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
            padding: EdgeInsets.only(left: 4.w, right: 4.w, bottom: 8.h),
            child: Row(
              children: [
                AppIcon('people', size: 18, color: AppColors.accent),
                SizedBox(width: 8.w),
                Text('Existing Users', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
                const Spacer(),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text('${_users.length} users', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
                ),
                SizedBox(width: 8.w),
                SizedBox(
                  height: AppBtn.height(context),
                  child: ElevatedButton.icon(
                    onPressed: _fetchUsers,
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
          // Inner bordered table (same pattern as Master Data)
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
          // Simplified table header
          Container(
            padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
            color: AppColors.tableHeadBg,
            child: Row(
              children: [
                SizedBox(width: 50.w, child: Text('S NO.', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                SizedBox(width: 16.w),
                Expanded(flex: 3, child: Text('NAME', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                Expanded(flex: 2, child: Text('DESIGNATION', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                Expanded(flex: 2, child: Text('ROLE', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                SizedBox(width: 70.w, child: Text('STATUS', textAlign: TextAlign.center, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                SizedBox(width: 30.w),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_isLoading)
            Padding(padding: EdgeInsets.all(32.w), child: Center(child: CircularProgressIndicator()))
          else if (_users.isEmpty)
            Padding(padding: EdgeInsets.all(32.w), child: Center(child: Text('No users found', style: TextStyle(color: AppColors.textPrimary))))
          else
            ...List.generate(_users.length, (i) {
              final u = _users[i];
              return InkWell(
                onTap: () => setState(() => _selectedUser = u),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                  color: i.isEven ? Colors.white : AppColors.surface,
                  child: Row(
                    children: [
                      SizedBox(width: 50.w, child: Text('${i + 1}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                      SizedBox(width: 16.w),
                      Expanded(
                        flex: 3,
                        child: Text(u.usename, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                      ),
                      Expanded(flex: 2, child: Text(u.desname, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                      Expanded(
                        flex: 2,
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
                              decoration: BoxDecoration(
                                color: u.urname.toLowerCase() == 'admin' ? AppColors.accent.withValues(alpha: 0.1) : Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(6.r),
                              ),
                              child: Text(u.urname, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: u.urname.toLowerCase() == 'admin' ? AppColors.accent : AppColors.textPrimary)),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 70.w,
                        child: Center(
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
                            decoration: BoxDecoration(
                              color: u.isActive ? AppColors.success.withValues(alpha: 0.1) : AppColors.error.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6.r),
                            ),
                            child: Text(u.isActive ? 'Active' : 'Inactive', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: u.isActive ? AppColors.success : AppColors.error)),
                          ),
                        ),
                      ),
                      SizedBox(width: 30.w, child: AppIcon.linear('Chevron Right', size: 18, color: AppColors.textPrimary)),
                    ],
                  ),
                ),
              );
            }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserDetail(InstitutionUserModel u) {
    final reportTo = u.userepto > 0
        ? _users.where((x) => x.useId == u.userepto).map((x) => x.usename).firstOrNull
        : null;

    Widget detailRow(String label, String value, {String? icon, Color? valueColor}) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 10.h, horizontal: 20.w),
        child: Row(
          children: [
            if (icon != null) ...[
              AppIcon(icon, size: 16, color: AppColors.accent),
              SizedBox(width: 10.w),
            ],
            SizedBox(
              width: 130.w,
              child: Text(label, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            ),
            Expanded(
              child: Text(value, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: valueColor ?? AppColors.textPrimary)),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header with back button + breadcrumb
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
            child: Row(
              children: [
                InkWell(
                  onTap: () => setState(() => _selectedUser = null),
                  borderRadius: BorderRadius.circular(8.r),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                    decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(8.r)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
                      SizedBox(width: 6.w),
                      Text('Back', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: Colors.white)),
                    ]),
                  ),
                ),
                SizedBox(width: 12.w),
                Container(width: 1, height: 18, color: AppColors.border),
                SizedBox(width: 12.w),
                Text('User Creation', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                SizedBox(width: 6.w),
                AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                SizedBox(width: 6.w),
                Text(u.urname, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const Spacer(),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                  decoration: BoxDecoration(
                    color: u.isActive ? AppColors.success.withValues(alpha: 0.1) : AppColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text(u.isActive ? 'Active' : 'Inactive', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: u.isActive ? AppColors.success : AppColors.error)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // User avatar + name header
          Padding(
            padding: EdgeInsets.all(20.w),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28.r,
                  backgroundColor: AppColors.accent.withValues(alpha: 0.1),
                  child: Text(
                    u.usename.isNotEmpty ? u.usename[0].toUpperCase() : '?',
                    style: TextStyle(fontSize: 22.sp, fontWeight: FontWeight.w700, color: AppColors.accent),
                  ),
                ),
                SizedBox(width: 16.w),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.usename, style: TextStyle(fontSize: 18.sp, fontWeight: FontWeight.w700)),
                    SizedBox(height: 2.h),
                    Text('${u.desname} - ${u.urname}', style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Detail rows
          SizedBox(height: 8.h),
          detailRow('Email', u.usemail, icon: 'sms'),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('Phone', u.usephone, icon: 'call'),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('Designation', u.desname, icon: 'personalcard'),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('Role', u.urname, icon: 'shield-tick', valueColor: u.urname.toLowerCase() == 'admin' ? AppColors.accent : null),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('Reports To', reportTo ?? 'None', icon: 'profile-circle'),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('Start Date', '${u.usestadate.day.toString().padLeft(2, '0')}/${u.usestadate.month.toString().padLeft(2, '0')}/${u.usestadate.year}', icon: 'calendar-1'),
          if (u.usecategory != null && u.usecategory!.isNotEmpty) ...[
            Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
            detailRow('Category', u.usecategory!, icon: 'category'),
          ],
          SizedBox(height: 16.h),
          // Terminate button
          if (u.isActive && u.urname.toLowerCase() != 'admin')
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 20.h),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _confirmTerminate(u),
                  icon: AppIcon('forbidden-2', size: 18),
                  label: const Text('Terminate', style: TextStyle(fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _confirmTerminate(InstitutionUserModel u) {
    final reasonController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
        title: const Text('Terminate User', style: TextStyle(fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to terminate "${u.usename}"? This will deactivate their account.'),
            SizedBox(height: 16.h),
            TextField(
              controller: reasonController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason for termination *',
                hintText: 'Enter reason...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final reason = reasonController.text.trim();
              if (reason.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Please enter a reason'), backgroundColor: Colors.red),
                );
                return;
              }
              Navigator.pop(ctx);
              _terminateUser(u, reason);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
            ),
            child: const Text('Terminate'),
          ),
        ],
      ),
    );
  }

  Future<void> _terminateUser(InstitutionUserModel u, String reason) async {
    setState(() => _isLoading = true);
    final auth = context.read<AuthProvider>();
    final terminatedBy = auth.userName ?? '';
    final success = await SupabaseService.terminateInstitutionUser(u.useId, terminatedBy: terminatedBy, terminatedReason: reason);
    if (mounted) {
      setState(() => _isLoading = false);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User terminated successfully'), backgroundColor: Colors.green),
        );
        setState(() => _selectedUser = null);
        _fetchUsers();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to terminate user'), backgroundColor: Colors.red),
        );
      }
    }
  }
}
