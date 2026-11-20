import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/pill_tab.dart';
import '../../utils/friendly_error.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../widgets/sequence_ui.dart';
import '../../widgets/sequence_type_field.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
        // Tabs (pill style - same pattern as Master Data / Reports)
        ListenableBuilder(
          listenable: _tabController,
          builder: (context, _) {
            final selected = _tabController.index;
            const tabLabels = ['Receipt Sequence', 'Fine Rules'];
            const tabIcons = ['receipt-1', 'judge'];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: // Wrap, not a horizontal scroll view: the row can run past the
              // window on a laptop screen, and a horizontal
              // SingleChildScrollView has no scrollbar and ignores the mouse
              // wheel on desktop, leaving the last tabs unreachable.
              Wrap(
                spacing: PillTab.gap(context),
                runSpacing: 8,
                children: [
                  for (var i = 0; i < tabLabels.length; i++)
                    PillTab(
                      icon: tabIcons[i],
                      label: tabLabels[i],
                      selected: selected == i,
                      onTap: () => _tabController.animateTo(i),
                    ),
                ],
              ),
            );
          },
        ),
        // Content - inner cards bring their own border, so no outer frame needed.
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              PaymentSequenceTab(),
              FineRulesTab(),
            ],
          ),
        ),
      ],
    );
  }
}

// ==================== Tab 1: Staff Designation ====================

class _StaffDesignationTab extends StatefulWidget {
  const _StaffDesignationTab();

  @override
  State<_StaffDesignationTab> createState() => _StaffDesignationTabState();
}

class _StaffDesignationTabState extends State<_StaffDesignationTab> with AutomaticKeepAliveClientMixin {
  bool _isLoading = false;
  List<Map<String, dynamic>> _designations = [];

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  int? _selectedReportTo;
  int? _editingDesId;

  @override
  bool get wantKeepAlive => true;

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

    bool success;
    if (_editingDesId != null) {
      success = await SupabaseService.updateDesignation(_editingDesId!, {
        'desname': _nameController.text.trim(),
        'desrepto': _selectedReportTo,
      });
    } else {
      success = await SupabaseService.createDesignation({
        'ins_id': insId,
        'desname': _nameController.text.trim(),
        'desrepto': _selectedReportTo,
        'activestatus': 1,
      });
    }

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_editingDesId != null ? 'Designation updated' : 'Designation created'), backgroundColor: AppColors.success),
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

  void _editDesignation(Map<String, dynamic> des) {
    setState(() {
      _editingDesId = des['des_id'] as int;
      _nameController.text = des['desname']?.toString() ?? '';
      _selectedReportTo = des['desrepto'] as int?;
    });
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
    _editingDesId = null;
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
    super.build(context);
    return Padding(
      padding: EdgeInsets.only(top: 4.h),
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
                    Row(
                      children: [
                        Icon(Icons.badge_rounded, color: AppColors.accent, size: 22.sp),
                        SizedBox(width: 8.w),
                        Text(
                          _editingDesId != null ? 'Edit Designation' : 'Add Designation',
                          style: AppUI.cardTitle,
                        ),
                      ],
                    ),
                    SizedBox(height: 20.h),
                    TextFormField(
                      controller: _nameController,
                      style: AppUI.fieldText(context, filled: _nameController.text.trim().isNotEmpty),
                      onChanged: (_) => setState(() {}),
                      decoration: _inputDecoration('Designation Name', filled: _nameController.text.trim().isNotEmpty),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    SizedBox(height: 16.h),
                    AppDropdownField<int?>(
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
                            icon: Icon(_editingDesId != null ? Icons.save : Icons.add, size: 18.sp),
                            label: Text(_editingDesId != null ? 'Update' : 'Add'),
                          ),
                        ),
                        if (_editingDesId != null) ...[
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
              decoration: AppUI.card(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(AppUI.cardRadius)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.badge_rounded, size: 18.sp, color: AppColors.accent),
                        SizedBox(width: 8.w),
                        Text('Designations', style: AppUI.cardTitle),
                        const Spacer(),
                        Text('${_designations.length} records', style: AppUI.muted),
                        SizedBox(width: 12.w),
                        SizedBox(
                          height: AppBtn.height(context),
                          child: ElevatedButton.icon(
                            onPressed: _fetchDesignations,
                            icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                            label: const Text('Refresh'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        SizedBox(width: 40.w, child: Text('S NO.', style: AppUI.tableHead)),
                        Expanded(flex: 3, child: Text('DESIGNATION NAME', style: AppUI.tableHead)),
                        Expanded(flex: 3, child: Text('REPORTS TO', style: AppUI.tableHead)),
                        SizedBox(width: 80.w, child: Text('ACTIONS', textAlign: TextAlign.center, style: AppUI.tableHead)),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  if (_isLoading)
                    Padding(padding: EdgeInsets.all(40.w), child: Center(child: CircularProgressIndicator()))
                  else if (_designations.isEmpty)
                    AppUI.empty(title: 'No designations found', why: 'Add a designation with the form on the left.', icon: 'briefcase')
                  else
                    ..._designations.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final des = entry.value;
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                        color: idx.isEven ? Colors.white : AppColors.surface,
                        child: Row(
                          children: [
                            SizedBox(width: 40.w, child: Text('${idx + 1}', style: AppUI.cell)),
                            Expanded(flex: 3, child: Text(des['desname']?.toString() ?? '-', style: AppUI.cell)),
                            Expanded(flex: 3, child: Text(_getDesignationName(des['desrepto'] as int?), style: AppUI.cell)),
                            SizedBox(
                              width: 80.w,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  InkWell(onTap: () => _editDesignation(des), borderRadius: BorderRadius.circular(6.r), child: Padding(padding: EdgeInsets.all(4.w), child: Icon(Icons.edit_rounded, size: 16.sp, color: AppColors.accent))),
                                  SizedBox(width: 8.w),
                                  InkWell(onTap: () => _deleteDesignation(des['des_id'] as int), borderRadius: BorderRadius.circular(6.r), child: Padding(padding: EdgeInsets.all(4.w), child: Icon(Icons.delete_rounded, size: 16.sp, color: AppColors.error))),
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

// ==================== Tab 2: Custom Roles ====================

class _CustomRolesTab extends StatefulWidget {
  const _CustomRolesTab();

  @override
  State<_CustomRolesTab> createState() => _CustomRolesTabState();
}

class _CustomRolesTabState extends State<_CustomRolesTab> with AutomaticKeepAliveClientMixin {
  bool _isLoading = false;
  List<Map<String, dynamic>> _roles = [];

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  int? _editingUrId;

  @override
  bool get wantKeepAlive => true;

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

    bool success;
    if (_editingUrId != null) {
      success = await SupabaseService.updateUserRole(_editingUrId!, {
        'urname': _nameController.text.trim(),
      });
    } else {
      success = await SupabaseService.createUserRole({
        'ins_id': insId,
        'inscode': inscode ?? '',
        'urname': _nameController.text.trim(),
        'activestatus': 1,
      });
    }

    if (mounted) {
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
        setState(() => _isLoading = false);
      }
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

  InputDecoration _inputDecoration(String label, {bool filled = false}) {
    return AppUI.field(context, '', label: label, filled: filled);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: EdgeInsets.only(top: 4.h),
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
                    Row(
                      children: [
                        Icon(Icons.security_rounded, color: AppColors.accent, size: 22.sp),
                        SizedBox(width: 8.w),
                        Text(
                          _editingUrId != null ? 'Edit Role' : 'Add Role',
                          style: AppUI.cardTitle,
                        ),
                      ],
                    ),
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
                            icon: Icon(_editingUrId != null ? Icons.save : Icons.add, size: 18.sp),
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
              decoration: AppUI.card(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(AppUI.cardRadius)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.admin_panel_settings_rounded, size: 18.sp, color: AppColors.accent),
                        SizedBox(width: 8.w),
                        Text('Custom Roles', style: AppUI.cardTitle),
                        const Spacer(),
                        Text('${_roles.length} records', style: AppUI.muted),
                        SizedBox(width: 12.w),
                        SizedBox(
                          height: AppBtn.height(context),
                          child: ElevatedButton.icon(
                            onPressed: _fetchRoles,
                            icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                            label: const Text('Refresh'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        SizedBox(width: 40.w, child: Text('S NO.', style: AppUI.tableHead)),
                        Expanded(flex: 3, child: Text('ROLE NAME', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text('INS CODE', style: AppUI.tableHead)),
                        SizedBox(width: 80.w, child: Text('ACTIONS', textAlign: TextAlign.center, style: AppUI.tableHead)),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  if (_isLoading)
                    Padding(padding: EdgeInsets.all(40.w), child: Center(child: CircularProgressIndicator()))
                  else if (_roles.isEmpty)
                    AppUI.empty(title: 'No roles found', why: 'Add a role with the form on the left.', icon: 'security-user')
                  else
                    ..._roles.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final role = entry.value;
                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                        color: idx.isEven ? Colors.white : AppColors.surface,
                        child: Row(
                          children: [
                            SizedBox(width: 40.w, child: Text('${idx + 1}', style: AppUI.cell)),
                            Expanded(flex: 3, child: Text(role['urname']?.toString() ?? '-', style: AppUI.cell)),
                            Expanded(flex: 2, child: Text(role['inscode']?.toString() ?? '-', style: AppUI.cell)),
                            SizedBox(
                              width: 80.w,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  InkWell(onTap: () => _editRole(role), borderRadius: BorderRadius.circular(6.r), child: Padding(padding: EdgeInsets.all(4.w), child: Icon(Icons.edit_rounded, size: 16.sp, color: AppColors.accent))),
                                  SizedBox(width: 8.w),
                                  InkWell(onTap: () => _deleteRole(role['ur_id'] as int), borderRadius: BorderRadius.circular(6.r), child: Padding(padding: EdgeInsets.all(4.w), child: Icon(Icons.delete_rounded, size: 16.sp, color: AppColors.error))),
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

// ==================== Tab 3: Payment Sequence ====================

class PaymentSequenceTab extends StatefulWidget {
  /// null = the regular fee receipt series. ADVFEENO = Advance Receipt No.,
  /// ARRFEENO = Arrear Receipt No., MISCFEENO = Miscellaneous Receipt No.:
  /// their own series, one per fee group
  /// (division 'FG:<fg_id>'). fg_id stays empty on those rows: that column
  /// marks a REGULAR fee receipt series.
  final String? series;
  const PaymentSequenceTab({super.key, this.series});

  @override
  State<PaymentSequenceTab> createState() => PaymentSequenceTabState();
}

class PaymentSequenceTabState extends State<PaymentSequenceTab> with AutomaticKeepAliveClientMixin {
  bool _isLoading = false;
  bool _isSaving = false;
  List<Map<String, dynamic>> _feeGroups = [];
  List<Map<String, dynamic>> _sequences = [];
  final _widthController = TextEditingController(text: '5');
  final _prefixController = TextEditingController();
  String? _selectedFgId; // fee group being configured in the create form
  Map<String, dynamic>? _editing; // the receipt sequence being edited

  bool get _adv => widget.series != null;

  /// What this tab's series are called.
  String get _kind => switch (widget.series) {
        'ADVFEENO' => 'Advance Receipt',
        'ARRFEENO' => 'Arrear Receipt',
        'MISCFEENO' => 'Miscellaneous Receipt',
        _ => 'Receipt',
      };

  /// This series is listed on this tab.
  bool _inTab(Map<String, dynamic> s) => _adv ? s['actname'] == widget.series : s['fg_id'] != null;

  /// The fee group a series belongs to.
  int? _fgOf(Map<String, dynamic> s) => _adv
      ? int.tryParse('${s['division'] ?? ''}'.replaceFirst('FG:', ''))
      : (s['fg_id'] as num?)?.toInt();

  /// Two series with one prefix would issue the same receipt number.
  bool _prefixTaken(String prefix) =>
      _adv &&
      _sequences.any((s) =>
          '${s['seqprefix'] ?? ''}'.toUpperCase() == prefix.toUpperCase() && s['seq_id'] != _editing?['seq_id']);

  void _edit(Map<String, dynamic> s) {
    setState(() {
      _editing = s;
      _selectedFgId = _fgOf(s)?.toString();
      _prefixController.text = s['seqprefix']?.toString() ?? '';
      _widthController.text = '${(s['seqwidth'] as num?)?.toInt() ?? 4}';
    });
  }

  void _cancelEdit() => setState(() {
        _editing = null;
        _selectedFgId = null;
        _prefixController.clear();
        _widthController.text = '5';
      });

  Future<void> _updateEditing() async {
    final e = _editing;
    if (e == null) return;
    final prefix = _prefixController.text.trim().toUpperCase();
    if (prefix.isEmpty) { _snack('Enter a prefix.', AppColors.warning); return; }
    if (_prefixTaken(prefix)) { _snack('$prefix is already used by another series. Enter a different prefix.', AppColors.warning); return; }
    final width = (int.tryParse(_widthController.text.trim()) ?? 4).clamp(1, 9);
    setState(() => _isSaving = true);
    try {
      await SupabaseService.saveSchemaRow('sequence', {
        'seqprefix': prefix,
        'seqname': prefix,
        'seqwidth': width,
        'sequid': '$prefix${'1'.padLeft(width, '0')}',
      }, pkCol: 'seq_id', pkVal: (e['seq_id'] as num).toInt());
      _cancelEdit();
      _snack('Receipt sequence updated.', AppColors.success);
      await _fetchData();
    } catch (err) {
      _snack('Could not save the sequence. ${friendlyError(err)}', AppColors.error);
    }
    if (mounted) setState(() => _isSaving = false);
  }

  Future<void> _delete(Map<String, dynamic> s, String name) async {
    if (!await SequenceUI.confirmDelete(context,
        name: name,
        current: (s['seqcurno'] as num?)?.toInt() ?? 0,
        start: (s['seqstart'] as num?)?.toInt() ?? 1)) {
      return;
    }
    try {
      await SupabaseService.deleteSchemaRow('sequence', 'seq_id', (s['seq_id'] as num).toInt());
      if (_editing?['seq_id'] == s['seq_id']) _cancelEdit();
      _snack('Receipt sequence deleted.', AppColors.success);
      await _fetchData();
    } catch (err) {
      _snack('Could not delete the sequence. ${friendlyError(err)}', AppColors.error);
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  @override
  void dispose() {
    _widthController.dispose();
    _prefixController.dispose();
    super.dispose();
  }

  Future<void> _fetchData() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    setState(() => _isLoading = true);
    try {
      final fgResult = await SupabaseService.fromSchema('feegroup')
          .select('fg_id, fgdesc')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('fgdesc');
      final seqResult = await SupabaseService.fromSchema('sequence')
          .select()
          .eq('ins_id', insId)
          .eq('activestatus', 1) // deleted ones are switched off
          .neq('actname', 'REGNO'); // exclude register-number sequences
      if (mounted) {
        setState(() {
          _feeGroups = List<Map<String, dynamic>>.from(fgResult);
          _sequences = List<Map<String, dynamic>>.from(seqResult);
          if (_sequences.isNotEmpty) {
            _widthController.text = _sequences.first['seqwidth']?.toString() ?? '4';
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Sequence fetch error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Map<String, dynamic>? _getSequenceForFg(int fgId) {
    try {
      return _sequences.firstWhere((s) => _inTab(s) && _fgOf(s) == fgId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveSequenceForFg(int fgId, String fgDesc, String prefix) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isSaving = true);
    try {
      final width = int.tryParse(_widthController.text.trim()) ?? 4;
      final sequid = '${prefix.toUpperCase()}${'1'.padLeft(width, '0')}';

      // Get year info
      final yearResult = await SupabaseService.fromSchema('year')
          .select('yr_id, yrlabel')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('yr_id', ascending: false)
          .limit(1)
          .maybeSingle();
      final yrId = yearResult?['yr_id'] ?? 0;
      final yrLabel = yearResult?['yrlabel']?.toString() ?? '';

      await SupabaseService.saveSchemaRow('sequence', {
        'ins_id': insId,
        'mod_id': 0,
        'yr_id': yrId,
        'yrlabel': yrLabel,
        'actname': widget.series ?? fgDesc,
        'seqname': prefix.toUpperCase(),
        'isprefix': 'Y',
        'seqprefix': prefix.toUpperCase(),
        'seqstart': 1,
        'seqwidth': width,
        'sequid': sequid,
        'seqcurno': 0,
        if (_adv) 'division': 'FG:$fgId' else 'fg_id': fgId,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$_kind sequence created for $fgDesc.'), backgroundColor: AppColors.success),
        );
        _fetchData();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
        );
      }
    }
    if (mounted) setState(() => _isSaving = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) return const Center(child: CircularProgressIndicator());

    // No fee groups yet: these series have to wait, but the Sequence Type
    // dropdown stays, or Sequence Master could not reach the series that need
    // no fee group (Admission No., Refund No. ...).
    if (_feeGroups.isEmpty) {
      return SequenceUI.layout(
        form: Container(
          padding: EdgeInsets.all(AppUI.cardPad),
          decoration: AppUI.card(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('$_kind No. Sequence', style: AppUI.cardTitle),
            SizedBox(height: 20.h),
            const SequenceTypeField(),
            Text('This sequence is created for each fee group, so add the fee groups first.', style: AppUI.muted),
          ]),
        ),
        list: Container(
          height: double.infinity,
          decoration: AppUI.card(),
          child: AppUI.empty(title: 'No fee groups found', why: 'Add fee groups first in Setup → Fee Master → Fee Group.', icon: 'receipt-1'),
        ),
      );
    }

    return SequenceUI.layout(form: _form(), list: _list());
  }

  /// Fee group's initials, max 3 chars — the suggested prefix.
  String _autoPrefix(String fgDesc) {
    final initials = fgDesc.split(' ').where((w) => w.isNotEmpty).map((w) => w[0]).join().toUpperCase();
    final p = initials.isEmpty ? '' : initials.substring(0, initials.length.clamp(0, 3));
    return _adv && p.isNotEmpty ? '${widget.series == 'ARRFEENO' ? 'R' : _kind[0]}$p' : p;
  }

  Widget _lbl(String t) => Text(t, style: AppUI.label);

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  // Matches _filledFieldDec used by the other Fee Master tabs so every master
  // form field is the same size.
  InputDecoration _dec(String hint, {bool filled = false}) {
    return AppUI.field(context, hint, filled: filled);
  }

  Future<void> _createFromForm() async {
    final fgId = int.tryParse(_selectedFgId ?? '');
    if (fgId == null) { _snack('Select a fee group.', AppColors.warning); return; }
    final prefix = _prefixController.text.trim();
    if (prefix.isEmpty) { _snack('Enter a prefix.', AppColors.warning); return; }
    if (_prefixTaken(prefix)) { _snack('$prefix is already used by another series. Enter a different prefix.', AppColors.warning); return; }
    final fg = _feeGroups.firstWhere((g) => g['fg_id'] == fgId, orElse: () => const {});
    await _saveSequenceForFg(fgId, fg['fgdesc']?.toString() ?? '', prefix);
    if (mounted) setState(() { _selectedFgId = null; _prefixController.clear(); });
  }

  /// The form card every sequence screen shares (SequenceUI).
  Widget _form() {
    // Only fee groups without a sequence yet can be configured.
    final editFg = _editing == null ? null : _fgOf(_editing!);
    final available = _feeGroups
        .where((fg) => fg['fg_id'] == editFg || _getSequenceForFg(fg['fg_id'] as int) == null)
        .toList();
    final width = int.tryParse(_widthController.text.trim()) ?? 4;
    final preview = '${_prefixController.text.trim()}${'1'.padLeft(width, '0')}';
    final safeFg = available.any((fg) => fg['fg_id'].toString() == _selectedFgId) ? _selectedFgId : null;
    return SequenceUI.formCard(
      title: '$_kind No. Sequence',
      subtitle: 'One ${_kind.toLowerCase()} sequence for each fee group',
      preview: _prefixController.text.trim().isEmpty ? null : preview,
      button: SequenceUI.saveButton(
          saving: _isSaving,
          editing: _editing != null,
          onPressed: _editing != null ? _updateEditing : (available.isEmpty ? null : _createFromForm)),
      onCancel: _editing == null ? null : _cancelEdit,
      fields: [
            _lbl('Fee Group *'),
            SizedBox(height: 6.h),
            AppDropdownField<String>(
              initialValue: safeFg,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              style: AppUI.fieldText(context),
              decoration: _dec(available.isEmpty ? 'All fee groups configured' : 'Select fee group', filled: safeFg != null),
              items: available.map((fg) => DropdownMenuItem(value: fg['fg_id'].toString(), child: Text(fg['fgdesc']?.toString() ?? '', style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis))).toList(),
              // The fee group of a sequence being edited can't change.
              onChanged: available.isEmpty || _editing != null ? null : (v) => setState(() {
                _selectedFgId = v;
                final fg = available.firstWhere((g) => g['fg_id'].toString() == v, orElse: () => const {});
                _prefixController.text = _autoPrefix(fg['fgdesc']?.toString() ?? '');
              }),
            ),
            SizedBox(height: 16.h),
            _lbl('Prefix *'),
            SizedBox(height: 6.h),
            TextField(
              controller: _prefixController,
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) => setState(() {}),
              style: AppUI.fieldText(context, filled: _prefixController.text.trim().isNotEmpty),
              decoration: _dec('e.g. TF', filled: _prefixController.text.trim().isNotEmpty),
            ),
            SizedBox(height: 16.h),
            _lbl('Number of Digits'),
            SizedBox(height: 6.h),
            TextField(
              controller: _widthController,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              style: AppUI.fieldText(context, filled: _widthController.text.trim().isNotEmpty),
              decoration: _dec('e.g. 5', filled: _widthController.text.trim().isNotEmpty),
            ),
      ],
    );
  }

  /// The list every sequence screen shares (SequenceUI).
  Widget _list() {
    final rows = _sequences.where(_inTab).toList();
    final fgName = {for (final g in _feeGroups) g['fg_id']: g['fgdesc']?.toString() ?? ''};
    return SequenceUI.listCard(
      title: '$_kind No. Sequences',
      loading: false,
      emptyTitle: 'No ${_kind.toLowerCase()} sequences yet',
      emptyWhy: 'Create one with the form on the left.',
      rows: rows.map((s) {
        final prefix = s['seqprefix']?.toString() ?? '';
        final width = (s['seqwidth'] as num?)?.toInt() ?? 4;
        final start = (s['seqstart'] as num?)?.toInt() ?? 1;
        final cur = (s['seqcurno'] as num?)?.toInt() ?? 0;
        return SeqRow(
          name: fgName[_fgOf(s)] ?? (_adv ? 'Any fee group' : s['actname']?.toString() ?? ''),
          prefix: prefix,
          next: SequenceUI.nextNumber(affix: prefix, current: cur, start: start, width: width),
          lastIssued: SequenceUI.lastIssued(current: cur, start: start),
          selected: _editing?['seq_id'] == s['seq_id'],
          onEdit: () => _edit(s),
          onDelete: () => _delete(s, fgName[_fgOf(s)] ?? prefix),
        );
      }).toList(),
    );
  }

}

// ==================== Fine Rules Tab ====================

class FineRulesTab extends StatefulWidget {
  const FineRulesTab({super.key});

  @override
  State<FineRulesTab> createState() => FineRulesTabState();
}

class FineRulesTabState extends State<FineRulesTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<Map<String, dynamic>> _rules = [];
  bool _loading = true;

  final _ruleNameCtrl = TextEditingController();
  String? _ruleNameError;
  final _fromDaysCtrl = TextEditingController();
  final _toDaysCtrl = TextEditingController();
  final _fineValueCtrl = TextEditingController();
  String? _fineType; // null = no fine type chosen yet (shows placeholder)
  String? _feeType; // null = no fee type chosen yet (shows placeholder)
  List<String> _feeTypes = [];
  int? _editingId;

  @override
  void initState() {
    super.initState();
    _loadRules();
    _loadFeeTypes();
  }

  @override
  void dispose() {
    _ruleNameCtrl.dispose();
    _fromDaysCtrl.dispose();
    _toDaysCtrl.dispose();
    _fineValueCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRules() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      final result = await SupabaseService.fromSchema('finerule')
          .select('*')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('from_days');
      if (mounted) setState(() { _rules = List<Map<String, dynamic>>.from(result); _loading = false; });
    } catch (e) {
      debugPrint('Error loading fine rules: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadFeeTypes() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      // Only show fee types where fines are applicable (feefineapplicable = 1)
      final response = await SupabaseService.fromSchema('feetype')
          .select('feedesc')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('feefineapplicable', 1)
          .order('fee_id', ascending: true);
      final types = (response as List)
          .map((e) => e['feedesc']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      if (mounted) {
        setState(() {
          _feeTypes = types;
          // Start with no fee type selected so the 'Select fee type'
          // placeholder shows (edit mode sets _feeType explicitly).
          if (_feeType != null && !types.contains(_feeType)) {
            _feeType = null;
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading fine-applicable fee types: $e');
    }
  }

  void _clearForm() {
    _ruleNameCtrl.clear();
    _fromDaysCtrl.clear();
    _toDaysCtrl.clear();
    _fineValueCtrl.clear();
    _fineType = null;
    _feeType = null;
    _editingId = null;
  }

  void _editRule(Map<String, dynamic> rule) {
    setState(() {
      _editingId = rule['fr_id'] as int?;
      _ruleNameCtrl.text = rule['rulename']?.toString() ?? '';
      _fromDaysCtrl.text = rule['from_days']?.toString() ?? '';
      _toDaysCtrl.text = rule['to_days']?.toString() ?? '';
      _fineValueCtrl.text = rule['fine_value']?.toString() ?? '';
      _fineType = rule['fine_type']?.toString() ?? 'FIXED';
      final ruleFeeType = rule['feetype']?.toString() ?? '';
      _feeType = (ruleFeeType.isNotEmpty && _feeTypes.contains(ruleFeeType))
          ? ruleFeeType
          : null;
    });
  }

  Future<void> _saveRule() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    final ruleName = _ruleNameCtrl.text.trim();
    final fromDays = int.tryParse(_fromDaysCtrl.text.trim());
    final toDays = _toDaysCtrl.text.trim().isEmpty ? null : int.tryParse(_toDaysCtrl.text.trim());
    final fineValue = double.tryParse(_fineValueCtrl.text.trim());

    if (ruleName.isEmpty || fromDays == null || fineValue == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the rule name, from days and fine value.'), backgroundColor: AppColors.error),
      );
      return;
    }
    if (_feeType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a fee type.'), backgroundColor: AppColors.error),
      );
      return;
    }
    if (_fineType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a fine type.'), backgroundColor: AppColors.error),
      );
      return;
    }
    if (ruleName.length > 50) {
      setState(() => _ruleNameError = 'Rule name must be 50 characters or fewer');
      return;
    }

    final data = {
      'ins_id': insId,
      'rulename': ruleName,
      'feetype': _feeType,
      'from_days': fromDays,
      'to_days': toDays,
      'fine_type': _fineType,
      'fine_value': fineValue,
      'activestatus': 1,
      'createdby': auth.userName ?? 'Admin',
    };

    // _clearForm() below resets _editingId, so remember which message to show.
    final wasEditing = _editingId != null;
    try {
      if (_editingId != null) {
        await SupabaseService.saveSchemaRow('finerule', data, pkCol: 'fr_id', pkVal: _editingId!);
      } else {
        await SupabaseService.saveSchemaRow('finerule', data);
      }
      _clearForm();
      _loadRules();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(wasEditing ? 'Fine rule updated.' : 'Fine rule created.'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error));
    }
  }

  Future<void> _deleteRule(int frId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Fine Rule'),
        content: const Text('Are you sure you want to delete this fine rule?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await SupabaseService.deleteSchemaRow('finerule', 'fr_id', frId);
      _loadRules();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fine rule deleted.'), backgroundColor: AppColors.success));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Container(
      color: AppColors.surface,
      child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left: Form
        SizedBox(
          width: 350.w,
          child: SingleChildScrollView(
            child: Container(
              padding: EdgeInsets.all(AppUI.cardPad),
              decoration: AppUI.card(),
              child: FocusTraversalGroup(
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppIcon.linear('judge', size: 20, color: AppColors.accent),
                      SizedBox(width: 8.w),
                      Text(_editingId != null ? 'Edit Fine Rule' : 'Add Fine Rule',
                          style: AppUI.cardTitle),
                    ],
                  ),
                  SizedBox(height: 20.h),
                  _fieldLabel('Rule Name', required: true),
                  SizedBox(height: 6.h),
                  TextField(
                    controller: _ruleNameCtrl,
                    style: _fieldTextStyle(filled: _ruleNameCtrl.text.trim().isNotEmpty),
                    onChanged: (v) {
                      final overflow = v.trim().length > 50;
                      final next = overflow ? 'Rule name must be 50 characters or fewer' : null;
                      setState(() => _ruleNameError = next);
                    },
                    decoration: _fieldDecoration(hint: 'e.g. 1 week overdue', filled: _ruleNameCtrl.text.trim().isNotEmpty).copyWith(errorText: _ruleNameError, errorMaxLines: 3),
                  ),
                  SizedBox(height: 14.h),
                  _fieldLabel('Fee Type', required: true),
                  SizedBox(height: 6.h),
                  AppDropdownField<String>(
                    value: _feeType,
                    icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                    isExpanded: true,
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    elevation: 6,
                    style: _fieldTextStyle(filled: _feeType != null),
                    decoration: _fieldDecoration(hint: 'Select fee type', filled: _feeType != null),
                    items: _feeTypes.map((f) => DropdownMenuItem(value: f, child: Text(f, style: _fieldTextStyle()))).toList(),
                    selectedItemBuilder: (context) => _feeTypes.map((f) => Align(alignment: Alignment.centerLeft, child: Text(f, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
                    onChanged: (v) => setState(() => _feeType = v),
                  ),
                  SizedBox(height: 14.h),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _fieldLabel('From Days', required: true),
                            SizedBox(height: 6.h),
                            TextField(
                              controller: _fromDaysCtrl,
                              keyboardType: TextInputType.number,
                              style: _fieldTextStyle(filled: _fromDaysCtrl.text.trim().isNotEmpty),
                              onChanged: (_) => setState(() {}),
                              decoration: _fieldDecoration(hint: 'e.g. 1', filled: _fromDaysCtrl.text.trim().isNotEmpty),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 12.w),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _fieldLabel('To Days'),
                            SizedBox(height: 6.h),
                            TextField(
                              controller: _toDaysCtrl,
                              keyboardType: TextInputType.number,
                              style: _fieldTextStyle(filled: _toDaysCtrl.text.trim().isNotEmpty),
                              onChanged: (_) => setState(() {}),
                              decoration: _fieldDecoration(hint: 'Blank = no limit', filled: _toDaysCtrl.text.trim().isNotEmpty),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 14.h),
                  _fieldLabel('Fine Type', required: true),
                  SizedBox(height: 6.h),
                  AppDropdownField<String>(
                    value: _fineType,
                    icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                    isExpanded: true,
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    elevation: 6,
                    style: _fieldTextStyle(filled: _fineType != null),
                    decoration: _fieldDecoration(hint: 'Select fine type', filled: _fineType != null),
                    items: const [
                      DropdownMenuItem(value: 'FIXED', child: Text('Fixed Amount (₹)')),
                      DropdownMenuItem(value: 'PERCENT', child: Text('Percentage (%)')),
                    ],
                    selectedItemBuilder: (context) => [
                      Align(alignment: Alignment.centerLeft, child: Text('Fixed Amount (₹)', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
                      Align(alignment: Alignment.centerLeft, child: Text('Percentage (%)', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))),
                    ],
                    onChanged: (v) => setState(() => _fineType = v),
                  ),
                  SizedBox(height: 14.h),
                  _fieldLabel(
                      _fineType == 'FIXED'
                          ? 'Fine Amount (₹)'
                          : _fineType == 'PERCENT'
                              ? 'Fine Percentage (%)'
                              : 'Fine Value',
                      required: true),
                  SizedBox(height: 6.h),
                  TextField(
                    controller: _fineValueCtrl,
                    keyboardType: TextInputType.number,
                    style: _fieldTextStyle(filled: _fineValueCtrl.text.trim().isNotEmpty),
                    onChanged: (_) => setState(() {}),
                    decoration: _fieldDecoration(hint: _fineType == 'FIXED' ? 'e.g. 50' : 'e.g. 2', filled: _fineValueCtrl.text.trim().isNotEmpty),
                  ),
                  SizedBox(height: 22.h),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: AppBtn.height(context),
                          child: ElevatedButton.icon(
                            onPressed: _saveRule,
                            icon: Icon(_editingId != null ? Icons.save_rounded : Icons.add_rounded, size: AppBtn.iconSize(context)),
                            label: Text(_editingId != null ? AppText.update : AppText.save),
                          ),
                        ),
                      ),
                      if (_editingId != null) ...[
                        SizedBox(width: AppBtn.gap(context)),
                        SizedBox(
                          height: AppBtn.height(context),
                          child: OutlinedButton.icon(
                            onPressed: () => setState(() => _clearForm()),
                            icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: AppColors.primary),
                            label: const Text('Cancel'),
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: 10.h),
                  AppUI.requiredNote(),
                ],
              ),
              ),
            ),
          ),
        ),
        SizedBox(width: AppUI.gap),
        // Right: Rules list
        Expanded(
          child: Container(
              decoration: AppUI.card(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16.w, 16.w, 16.w, 8.h),
                    child: Row(
                      children: [
                        AppIcon.linear('task-square', size: 20, color: AppColors.accent),
                        SizedBox(width: 8.w),
                        Text('Fine Rules', style: AppUI.cardTitle),
                        const Spacer(),
                        Text('${_rules.length} rule${_rules.length == 1 ? '' : 's'}', style: AppUI.muted),
                        SizedBox(width: AppBtn.gap(context)),
                        SizedBox(
                          height: AppBtn.height(context),
                          child: ElevatedButton.icon(
                            onPressed: _loadRules,
                            icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                            label: const Text('Refresh'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_loading)
                    const Expanded(child: Center(child: CircularProgressIndicator()))
                  else if (_rules.isEmpty)
                    Expanded(child: AppUI.empty(title: 'No fine rules configured', why: 'Add a rule with the form on the left.', icon: 'judge'))
                  else
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 16.w),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10.r),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: AppColors.cardBorder),
                              borderRadius: BorderRadius.circular(10.r),
                            ),
                            child: Builder(builder: (ctx) {
                              const flexes = <int>[3, 3, 2, 2, 3, 2, 2];
                              const headers = <String>[
                                'RULE NAME', 'FEE TYPE', 'FROM DAY', 'TO DAY',
                                'FINE TYPE', 'VALUE', 'ACTION',
                              ];
                              final hStyle = AppUI.tableHead;
                              // Per-column alignment so the header text and
                              // the data underneath stay visually aligned.
                              // FROM/TO/VALUE â†’ centerRight (numbers).
                              // ACTIONS â†’ centerRight (icons sit at far right
                              // matching the header). Everything else â†’ left.
                              Alignment alignOf(int i) {
                                if (i == 2 || i == 3 || i == 5 || i == 6) {
                                  return Alignment.centerRight;
                                }
                                return Alignment.centerLeft;
                              }
                              Widget cell(int i, Widget child) => Expanded(
                                    flex: flexes[i],
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 8.w),
                                      child: Align(
                                        alignment: alignOf(i),
                                        child: child,
                                      ),
                                    ),
                                  );
                              return Column(
                                children: [
                                  // Sticky header.
                                  Container(
                                    color: AppColors.tableHeadBg,
                                    padding: EdgeInsets.symmetric(
                                        horizontal: 20, vertical: 12.h),
                                    child: Row(children: [
                                      for (int i = 0;
                                          i < headers.length;
                                          i++)
                                        cell(
                                            i,
                                            Text(headers[i],
                                                style: hStyle)),
                                    ]),
                                  ),
                                  Container(
                                      height: 1,
                                      color: AppColors.divider),
                                  Expanded(
                                    child: AppVerticalScrollbar(
                                      builder: (context, sc) =>
                                          ListView.separated(
                                      controller: sc,
                                      itemCount: _rules.length,
                                      separatorBuilder: (_, __) =>
                                          const Divider(
                                              height: 1,
                                              color: AppColors.divider),
                                      itemBuilder: (_, i) {
                                        final r = _rules[i];
                                        final fineType = r['fine_type']
                                                ?.toString() ??
                                            'FIXED';
                                        final fineValue =
                                            (r['fine_value'] as num?)
                                                    ?.toDouble() ??
                                                0;
                                        final isFixed =
                                            fineType == 'FIXED';
                                        return Container(
                                          color: i.isOdd
                                              ? AppColors.surface
                                              : Colors.white,
                                          padding: EdgeInsets.symmetric(
                                              horizontal: 20,
                                              vertical: 9.h),
                                          child: Row(children: [
                                            cell(
                                                0,
                                                Text(
                                                    r['rulename']
                                                            ?.toString() ??
                                                        '',
                                                    style: AppUI.cell)),
                                            cell(
                                                1,
                                                _chip(
                                                    label: r['feetype']
                                                            ?.toString() ??
                                                        'All Fee Types',
                                                    color: AppColors
                                                        .accent)),
                                            cell(
                                                2,
                                                Text(
                                                    '${r['from_days'] ?? 0}',
                                                    style: AppUI.cell)),
                                            cell(
                                                3,
                                                Text(
                                                    r['to_days'] !=
                                                            null
                                                        ? '${r['to_days']}'
                                                        : '∞',
                                                    style: AppUI.cell)),
                                            cell(
                                                4,
                                                _chip(
                                                    label: isFixed
                                                        ? 'Fixed'
                                                        : 'Percentage',
                                                    color: isFixed
                                                        ? AppColors
                                                            .success
                                                        : AppColors
                                                            .warning)),
                                            cell(
                                                5,
                                                Text(
                                                    isFixed
                                                        ? '${formatIndianNumber(fineValue)}'
                                                        : '${fineValue.toStringAsFixed(1)}%',
                                                    style: AppUI.money)),
                                            cell(
                                                6,
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize
                                                          .min,
                                                  children: [
                                                    _actionBtn(
                                                      iconName:
                                                          'edit-2',
                                                      color: AppColors
                                                          .accent,
                                                      tooltip: 'Edit',
                                                      onTap: () =>
                                                          _editRule(
                                                              r),
                                                    ),
                                                    SizedBox(
                                                        width: 6.w),
                                                    _actionBtn(
                                                      iconName:
                                                          'trash',
                                                      color: AppColors
                                                          .error,
                                                      tooltip:
                                                          'Delete',
                                                      onTap: () =>
                                                          _deleteRule(
                                                              r['fr_id']
                                                                  as int),
                                                    ),
                                                  ],
                                                )),
                                          ]),
                                        );
                                      },
                                    ),
                                    ),
                                  ),
                                ],
                              );
                            }),
                          ),
                        ),
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

  Widget _fieldLabel(String text, {bool required = false}) {
    return Text(
      required ? '$text *' : text,
      style: AppUI.label,
    );
  }

  TextStyle _fieldTextStyle({bool filled = false}) {
    return AppUI.fieldText(context, filled: filled);
  }

  InputDecoration _fieldDecoration({String? hint, bool filled = false}) {
    return AppUI.field(context, hint ?? '', filled: filled);
  }

  Widget _chip({required String label, required Color color}) {
    final status = color == AppColors.success
        ? AppStatus.success
        : color == AppColors.warning
            ? AppStatus.warning
            : color == AppColors.error
                ? AppStatus.danger
                : AppStatus.info;
    // Shrink rather than cut the chip when the column is narrow.
    return FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: AppUI.chip(label, status));
  }

  // Plain icon button - matches the other Fee Master tabs (MasterCrudPanel):
  // no tinted background box, just the icon.
  Widget _actionBtn({required String iconName, required Color color, required String tooltip, required VoidCallback onTap}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6.r),
        child: Padding(
          padding: EdgeInsets.all(4.w),
          child: AppIcon(iconName, size: 16, color: color),
        ),
      ),
    );
  }
}
