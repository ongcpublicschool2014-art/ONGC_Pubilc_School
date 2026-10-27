import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../models/institution_user_model.dart';
import '../../utils/friendly_error.dart';
import '../../utils/app_text.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/app_ui.dart';
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

  /// Non-null while the left-hand form is editing an EXISTING user
  /// instead of creating one. In that mode the password is optional:
  /// blank means "keep the current password".
  InstitutionUserModel? _editingUser;

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
              Text('Add Designation', style: AppUI.cardTitle),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Designation Name *', style: AppUI.label),
              SizedBox(height: 6.h),
              TextField(
                controller: controller,
                autofocus: true,
                style: AppUI.fieldText(context, filled: controller.text.trim().isNotEmpty),
                onChanged: (v) {
                  final overflow = v.trim().length > 50;
                  final next = overflow ? 'Designation name must be 50 characters or fewer' : null;
                  setDialogState(() => nameError = next);
                },
                decoration: AppUI.field(context, 'Enter designation name', filled: controller.text.trim().isNotEmpty).copyWith(
                  errorText: nameError,
                ),
              ),
              SizedBox(height: 16.h),
              Text('Reports To', style: AppUI.label),
              SizedBox(height: 6.h),
              DropdownButtonFormField<int?>(
                value: reportsTo,
                icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(12),
                elevation: 6,
                decoration: AppUI.field(context, '', filled: reportsTo != null),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None')),
                  ..._designationsList.map((d) => DropdownMenuItem(
                        value: d['des_id'] as int?,
                        child: Text(d['desname'] as String),
                      )),
                ],
                selectedItemBuilder: (context) => [
                  Align(alignment: Alignment.centerLeft, child: Text('None', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
                  ..._designationsList.map((d) => Align(alignment: Alignment.centerLeft, child: Text(d['desname'] as String, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
                ],
                onChanged: (v) => setDialogState(() => reportsTo = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton.icon(
              icon: AppIcon('add', size: 16, color: Colors.white),
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setDialogState(() => nameError = 'Designation name is required');
                  return;
                }
                if (name.length > 50) {
                  setDialogState(() => nameError = 'Designation name must be 50 characters or fewer');
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
              label: const Text('Add'),
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
        const SnackBar(content: Text('Select a staff designation and a role.')),
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
            content: Text('User created.'),
            backgroundColor: AppColors.success,
          ),
        );
        _clearForm();
        _fetchUsers();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to create user. Please try again.'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  void _clearForm() {
    // A TextFormField built with a controller captures its initialValue from
    // controller.text AT BUILD TIME, and Form.reset() restores that captured
    // text. So clearing the controllers and then calling reset() in the same
    // pass puts the old values straight back -- which is why the form still
    // showed the edited user after a successful save.
    //
    // Clear the controllers now, and reset only AFTER a frame has rebuilt the
    // fields with the (now empty) controllers: by then the captured value is
    // empty, so reset() just clears the "interacted" flags -- no red 'Required'
    // on the blank fields, and no resurrected text.
    _nameController.clear();
    _emailController.clear();
    _phoneController.clear();
    _passwordController.clear();
    setState(() {
      _selectedDesignation = null;
      _selectedDesId = null;
      _selectedReportTo = null;
      _selectedRole = null;
      _editingUser = null; // Clear doubles as Cancel while editing
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _formKey.currentState?.reset();
    });
  }

  /// Load an existing user into the left form.
  ///
  /// A dropdown value is only applied when it still exists in its master list:
  /// DropdownButtonFormField asserts if its value is not among its items, and a
  /// designation, role or reporting person can be removed after the user was
  /// created. Form.reset() is deliberately NOT called here -- it would restore
  /// each field to the value it was built with and wipe what we just loaded.
  void _startEdit(InstitutionUserModel u) {
    _nameController.text = u.usename;
    _emailController.text = u.usemail;
    _phoneController.text = u.usephone;
    _passwordController.clear(); // blank = keep the current password
    setState(() {
      _editingUser = u;
      _selectedUser = null; // back to the list, so the form is on screen
      // A dropdown value must match EXACTLY ONE of that dropdown's items --
      // zero or 2+ both trip an assertion in DropdownButtonFormField. So count
      // against the same set the items are built from, not the raw master list.
      final desMatches =
          _designationsList.where((d) => d['desname'] == u.desname).length;
      _selectedDesignation = desMatches == 1 ? u.desname : null;
      _selectedDesId = desMatches == 1 ? u.desId : null;

      // The Role dropdown deliberately omits 'Admin', so the admin's own role is
      // never selectable. Leave it unset -- _updateUser keeps the existing role
      // when nothing is chosen, so an admin's name/email/phone stay editable.
      final roleMatches = _rolesList
          .where((r) => r['urname'] == u.urname && r['urname'] != 'Admin')
          .length;
      _selectedRole = roleMatches == 1 ? u.urname : null;

      _selectedReportTo =
          (u.userepto == 0 || _users.any((x) => x.useId == u.userepto)) ? u.userepto : 0;
    });
  }

  /// The form's primary action: create when blank, update when editing.
  Future<void> _saveUser() =>
      _editingUser == null ? _createUser() : _updateUser(_editingUser!);

  Future<void> _updateUser(InstitutionUserModel u) async {
    if (!_formKey.currentState!.validate()) return;

    // Anything the form could not pre-select (the Admin role is absent from the
    // Role list by design; a designation can be removed from its master) is kept
    // as it is rather than blocking the edit.
    final roleName = _selectedRole ?? u.urname;
    final roleId = _selectedRole == null
        ? u.urId
        : _rolesList.firstWhere((r) => r['urname'] == _selectedRole)['ur_id'];
    final desName = _selectedDesignation ?? u.desname;
    final desId = _selectedDesignation == null ? u.desId : _selectedDesId;

    if (roleName.isEmpty || desName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a staff designation and a role.')),
      );
      return;
    }

    final pwd = _passwordController.text.trim();

    // Only the editable fields. ins_id / inscode / usestadate / activestatus are
    // left alone, and usepassword is sent ONLY when a new one was typed --
    // otherwise the hash trigger would re-hash on every save.
    final data = <String, dynamic>{
      'usename': _nameController.text.trim(),
      'usemail': _emailController.text.trim(),
      'usephone': _phoneController.text.trim(),
      'ur_id': roleId,
      'urname': roleName,
      'des_id': desId,
      'desname': desName,
      'userepto': _selectedReportTo ?? 0,
      if (pwd.isNotEmpty) 'usepassword': pwd,
    };

    setState(() => _isLoading = true);
    try {
      await SupabaseService.updateInstitutionUser(u.useId, data);
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${data['usename']} updated'
              '${pwd.isNotEmpty ? ' (password changed)' : ''}'),
          backgroundColor: AppColors.success,
        ),
      );
      _clearForm();
      _fetchUsers();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update the user. ${friendlyError(e)}'), backgroundColor: AppColors.error),
      );
    }
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
                'Users',
                style: AppUI.cardTitle,
              ),
            ],
          ),
          SizedBox(height: 20.h),

          // Form + User list side by side
          LayoutBuilder(builder: (context, constraints) {
            return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: Creation Form
              Expanded(
                flex: 3,
                child: _buildCreationForm(),
              ),
              SizedBox(width: AppUI.gap),
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
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Form(
        key: _formKey,
        child: FocusTraversalGroup(
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIcon('user-add',
                    size: 18, color: AppColors.accent),
                SizedBox(width: 8.w),
                Text(_editingUser == null ? 'Create New User' : 'Edit User',
                    style: AppUI.cardTitle),
              ],
            ),
            SizedBox(height: 20.h),

            // Staff Designation
            Text('Staff Designation *',
                style: AppUI.label),
            SizedBox(height: 6.h),
            DropdownButtonFormField<String>(
              value: _selectedDesignation,
              icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _inputDecoration(context, 'Select designation', filled: _selectedDesignation != null),
              style: _inputTextStyle(context, filled: _selectedDesignation != null),
              items: [
                ..._designationsList.map((d) => DropdownMenuItem(
                      value: d['desname'] as String,
                      child: Text(d['desname'] as String),
                    )),
                DropdownMenuItem(
                  value: '__add_new__',
                  child: Row(
                    children: [
                      AppIcon.linear('add-circle', size: 16, color: AppColors.primary),
                      SizedBox(width: 8.w),
                      Text('Add New Designation', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
              selectedItemBuilder: (context) => [
                ..._designationsList.map((d) => Align(alignment: Alignment.centerLeft, child: Text(d['desname'] as String, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
                Align(alignment: Alignment.centerLeft, child: Text('Add New Designation', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
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
              validator: (v) => v == null || v == '__add_new__' ? 'Select a staff designation' : null,
            ),
            SizedBox(height: 16.h),

            // Designation Report To
            Text('Reports To',
                style: AppUI.label),
            SizedBox(height: 6.h),
            DropdownButtonFormField<int>(
              value: _selectedReportTo,
              icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _inputDecoration(context, 'Select reporting person', filled: _selectedReportTo != null),
              style: _inputTextStyle(context, filled: _selectedReportTo != null),
              items: [
                const DropdownMenuItem(value: 0, child: Text('None')),
                ..._users.map((u) => DropdownMenuItem(
                      value: u.useId,
                      child: Text('${u.usename} (${u.desname})'),
                    )),
              ],
              selectedItemBuilder: (context) => [
                Align(alignment: Alignment.centerLeft, child: Text('None', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
                ..._users.map((u) => Align(alignment: Alignment.centerLeft, child: Text('${u.usename} (${u.desname})', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))),
              ],
              onChanged: (v) => setState(() => _selectedReportTo = v),
            ),
            SizedBox(height: 16.h),

            // Role
            Text('Role *',
                style: AppUI.label),
            SizedBox(height: 6.h),
            DropdownButtonFormField<String>(
              value: _selectedRole,
              icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _inputDecoration(context, 'Select role', filled: _selectedRole != null),
              style: _inputTextStyle(context, filled: _selectedRole != null),
              items: _rolesList
                  .where((r) => (r['urname'] as String) != 'Admin')
                  .map((r) => DropdownMenuItem(
                      value: r['urname'] as String,
                      child: Text(r['urname'] as String)))
                  .toList(),
              selectedItemBuilder: (context) => _rolesList
                  .where((r) => (r['urname'] as String) != 'Admin')
                  .map((r) => Align(alignment: Alignment.centerLeft, child: Text(r['urname'] as String, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))))
                  .toList(),
              onChanged: (v) => setState(() => _selectedRole = v),
              validator: (v) => v == null ? 'Select a role' : null,
            ),
            SizedBox(height: 16.h),

            // User Name
            Text('User Name *',
                style: AppUI.label),
            SizedBox(height: 6.h),
            TextFormField(
              controller: _nameController,
              decoration: _inputDecoration(context, 'Enter user name', filled: _nameController.text.trim().isNotEmpty),
              style: _inputTextStyle(context, filled: _nameController.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return 'Enter the user name';
                if (s.length > 50) return 'User name must be 50 characters or fewer';
                return null;
              },
            ),
            SizedBox(height: 16.h),

            // Email
            Text('Email *',
                style: AppUI.label),
            SizedBox(height: 6.h),
            TextFormField(
              controller: _emailController,
              decoration: _inputDecoration(context, 'Enter email address', filled: _emailController.text.trim().isNotEmpty),
              style: _inputTextStyle(context, filled: _emailController.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
              keyboardType: TextInputType.emailAddress,
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return 'Enter an email address';
                final emailRe = RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');
                if (!emailRe.hasMatch(s)) return 'Enter a valid email address';
                return null;
              },
            ),
            SizedBox(height: 16.h),

            // Phone
            Text('Phone *',
                style: AppUI.label),
            SizedBox(height: 6.h),
            TextFormField(
              controller: _phoneController,
              decoration: _inputDecoration(context, 'Enter phone number', filled: _phoneController.text.trim().isNotEmpty),
              style: _inputTextStyle(context, filled: _phoneController.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return 'Enter a phone number';
                if (s.length != 10) return 'Enter a 10-digit phone number';
                return null;
              },
            ),
            SizedBox(height: 16.h),

            // Password
            Text(_editingUser == null ? 'Password *' : 'Password',
                style: AppUI.label),
            SizedBox(height: 6.h),
            TextFormField(
              controller: _passwordController,
              decoration: _inputDecoration(context,
                      _editingUser == null ? 'Enter password' : 'Leave blank to keep the current password',
                      filled: _passwordController.text.trim().isNotEmpty)
                  .copyWith(
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
              style: _inputTextStyle(context, filled: _passwordController.text.trim().isNotEmpty),
              onChanged: (_) => setState(() {}),
              obscureText: _obscurePassword,
              validator: (v) {
                final s = v ?? '';
                // While editing, blank means "keep the current password".
                if (s.isEmpty) return _editingUser == null ? 'Enter a password' : null;
                if (s.length < 8) return 'Password must be at least 8 characters';
                return null;
              },
            ),
            SizedBox(height: 16.h),
            AppUI.requiredNote(),
            SizedBox(height: 12.h),

            // Buttons - full-width pair (Clear + Create User) sharing the
            // form row 50/50.
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: AppBtn.height(context),
                    child: OutlinedButton.icon(
                      onPressed: _clearForm,
                      icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: AppColors.primary),
                      label: Text(_editingUser == null ? 'Clear' : 'Cancel'),
                    ),
                  ),
                ),
                SizedBox(width: AppBtn.gap(context)),
                Expanded(
                  child: SizedBox(
                    height: AppBtn.height(context),
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _saveUser,
                      icon: _isLoading
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: const CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : AppIcon('user-add', size: AppBtn.iconSize(context), color: Colors.white),
                      label: Text(_editingUser == null ? 'Create User' : 'Update User'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

  TextStyle _inputTextStyle(BuildContext context, {bool filled = false}) {
    return AppUI.fieldText(context, filled: filled);
  }

  InputDecoration _inputDecoration(BuildContext context, String hint, {bool filled = false}) {
    return AppUI.field(context, hint, filled: filled);
  }

  Widget _buildUserList() {
    // If a user is selected, show drilldown
    if (_selectedUser != null) {
      return _buildUserDetail(_selectedUser!);
    }

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4.w, right: 4.w, bottom: 8.h),
            child: Row(
              children: [
                const CardTitleBlock(icon: 'people', title: 'Existing Users', subtitle: 'all user accounts in this institution'),
                const Spacer(),
                AppUI.chip('${_users.length} users', AppStatus.info),
                SizedBox(width: 8.w),
                SizedBox(
                  height: AppBtn.height(context),
                  child: ElevatedButton.icon(
                    onPressed: _fetchUsers,
                    icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                    label: const Text('Refresh'),
                  ),
                ),
              ],
            ),
          ),
          // Inner bordered table (same pattern as Master Data)
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              children: [
          // Simplified table header
          Container(
            padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
            color: AppColors.tableHeadBg,
            child: Row(
              children: [
                SizedBox(width: 50.w, child: Text('S NO.', style: AppUI.tableHead)),
                SizedBox(width: 16.w),
                Expanded(flex: 3, child: Text('NAME', style: AppUI.tableHead)),
                Expanded(flex: 2, child: Text('DESIGNATION', style: AppUI.tableHead)),
                Expanded(flex: 2, child: Text('ROLE', style: AppUI.tableHead)),
                SizedBox(width: 70.w, child: Text('STATUS', textAlign: TextAlign.center, style: AppUI.tableHead)),
                SizedBox(width: 50.w, child: Text('EDIT', textAlign: TextAlign.center, style: AppUI.tableHead)),
                SizedBox(width: 30.w),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_isLoading)
            Padding(padding: EdgeInsets.all(32.w), child: Center(child: CircularProgressIndicator()))
          else if (_users.isEmpty)
            AppUI.empty(title: 'No users found', why: 'Create the first user with the form on the left.', icon: 'people')
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
                      SizedBox(width: 50.w, child: Text('${i + 1}', style: AppUI.cell)),
                      SizedBox(width: 16.w),
                      Expanded(
                        flex: 3,
                        child: Text(u.usename, style: AppUI.cell),
                      ),
                      Expanded(flex: 2, child: Text(u.desname, style: AppUI.cell)),
                      Expanded(
                        flex: 2,
                        child: Row(
                          children: [
                            AppUI.chip(u.urname, u.urname.toLowerCase() == 'admin' ? AppStatus.info : AppStatus.neutral),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 70.w,
                        child: Center(
                          child: AppUI.chip(u.isActive ? 'Active' : 'Inactive', u.isActive ? AppStatus.success : AppStatus.danger),
                        ),
                      ),
                      // Edit straight from the row. _startEdit loads the user
                      // into the left form and clears _selectedUser, so the
                      // list stays put -- no drilling into the detail card
                      // first. Terminated users have no form to load, and the
                      // detail card hides its Edit button for them too.
                      SizedBox(
                        width: 50.w,
                        child: u.isActive
                            ? Center(
                                child: Tooltip(
                                  message: 'Edit ${u.usename}',
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(6.r),
                                    onTap: () => _startEdit(u),
                                    child: Padding(
                                      padding: EdgeInsets.all(6.w),
                                      child: const AppIcon('edit-2', size: 18, color: AppColors.accent),
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
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
              child: Text(label, style: AppUI.muted),
            ),
            Expanded(
              child: Text(value, style: AppUI.body.copyWith(color: valueColor ?? AppColors.textPrimary)),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: AppUI.card(),
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
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                    decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(AppUI.controlRadius)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
                      SizedBox(width: 6.w),
                      Text('Back', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: Colors.white)),
                    ]),
                  ),
                ),
                SizedBox(width: 12.w),
                Container(width: 1, height: 18, color: AppColors.divider),
                SizedBox(width: 12.w),
                Text('Users', style: AppUI.muted),
                SizedBox(width: 6.w),
                AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                SizedBox(width: 6.w),
                Text(u.urname, style: AppUI.label),
                const Spacer(),
                AppUI.chip(u.isActive ? 'Active' : 'Inactive', u.isActive ? AppStatus.success : AppStatus.danger),
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
                  backgroundColor: AppColors.primaryLight,
                  child: Text(
                    u.usename.isNotEmpty ? u.usename[0].toUpperCase() : '?',
                    style: TextStyle(fontSize: 22.sp, fontWeight: FontWeight.w800, color: AppColors.primary),
                  ),
                ),
                SizedBox(width: 16.w),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.usename, style: AppUI.cardTitle),
                    SizedBox(height: 2.h),
                    Text('${u.desname} - ${u.urname}', style: AppUI.muted),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Detail rows
          SizedBox(height: 8.h),
          detailRow('Email', u.usemail, icon: 'sms'),
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('Phone', u.usephone, icon: 'call'),
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('Designation', u.desname, icon: 'personalcard'),
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('Role', u.urname, icon: 'shield-tick', valueColor: u.urname.toLowerCase() == 'admin' ? AppColors.accent : null),
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('Reports To', reportTo ?? 'None', icon: 'profile-circle'),
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('Start Date', formatDmy(u.usestadate), icon: 'calendar-1'),
          if (u.usecategory != null && u.usecategory!.isNotEmpty) ...[
            const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
            detailRow('Category', u.usecategory!, icon: 'category'),
          ],
          SizedBox(height: 16.h),
          // Actions. Edit loads this user into the left form; Terminate stays
          // off the Admin role so an institution can't lose its last admin.
          if (u.isActive)
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 20.h),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _startEdit(u),
                    icon: const AppIcon('edit-2', size: 18, color: AppColors.accent),
                    label: const Text('Edit'),
                  ),
                ),
                if (u.urname.toLowerCase() != 'admin') ...[
                  SizedBox(width: 12.w),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _confirmTerminate(u),
                      icon: AppIcon('forbidden-2', size: 18),
                      label: const Text('Terminate'),
                      style: AppUI.danger(context),
                    ),
                  ),
                ],
              ]),
            ),
        ],
      ),
    );
  }

  void _confirmTerminate(InstitutionUserModel u) {
    final reasonController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Terminate User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to terminate "${u.usename}"? This will deactivate their account.'),
            SizedBox(height: 16.h),
            TextField(
              controller: reasonController,
              maxLines: 3,
              style: AppUI.fieldText(context, filled: reasonController.text.trim().isNotEmpty),
              onChanged: (_) => setDialogState(() {}),
              decoration: AppUI.field(context, 'Enter the reason for termination', label: 'Reason for termination *', filled: reasonController.text.trim().isNotEmpty),
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
                  const SnackBar(content: Text('Please enter a reason'), backgroundColor: AppColors.error),
                );
                return;
              }
              Navigator.pop(ctx);
              _terminateUser(u, reason);
            },
            style: AppUI.danger(context),
            child: const Text('Terminate'),
          ),
        ],
      ),
      ),
    );
  }

  Future<void> _terminateUser(InstitutionUserModel u, String reason) async {
    setState(() => _isLoading = true);
    final auth = context.read<AuthProvider>();
    final terminatedBy = auth.userName ?? '';
    final success = await SupabaseService.terminateInstitutionUser(u.useId, insId: auth.insId ?? 0, terminatedBy: terminatedBy, terminatedReason: reason);
    if (mounted) {
      setState(() => _isLoading = false);
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User terminated successfully'), backgroundColor: AppColors.success),
        );
        setState(() => _selectedUser = null);
        _fetchUsers();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not terminate the user. Please try again.'), backgroundColor: AppColors.error),
        );
      }
    }
  }
}
