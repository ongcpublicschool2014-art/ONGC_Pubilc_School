import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';

import '../../widgets/app_icon.dart';

/// Bank account master for the active institution. Each row represents a
/// beneficiary account a fee group can route to (school's main account,
/// transport vendor, hostel, etc.). Layout mirrors the User Creation
/// screen: flex 3/7 with a stacked single-column form on the left and the
/// assignments + list (or drilldown) on the right.
class BankDetailsScreen extends StatefulWidget {
  const BankDetailsScreen({super.key});

  @override
  State<BankDetailsScreen> createState() => _BankDetailsScreenState();
}

class _BankDetailsScreenState extends State<BankDetailsScreen> {
  bool _isLoading = false;
  bool _isSaving = false;
  List<Map<String, dynamic>> _banks = [];
  List<Map<String, dynamic>> _feeGroups = [];
  bool _loadingFeeGroups = false;

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _branchController = TextEditingController();
  final _ifscController = TextEditingController();
  final _addr1Controller = TextEditingController();
  final _addr2Controller = TextEditingController();
  final _addr3Controller = TextEditingController();
  final _mobileController = TextEditingController();
  final _emailController = TextEditingController();
  final _accNoController = TextEditingController();
  final _accHolderController = TextEditingController();

  int? _editingBanId;
  // When non-null, the right column shows the bank detail drilldown
  // (back button + breadcrumb + detail rows) instead of the
  // assignments + list.
  Map<String, dynamic>? _selectedBank;

  @override
  void initState() {
    super.initState();
    _fetchBanks();
    _fetchFeeGroups();
  }

  Future<void> _fetchFeeGroups() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _loadingFeeGroups = true);
    final groups = await SupabaseService.getFeeGroups(insId);
    if (!mounted) return;
    setState(() {
      _feeGroups = groups;
      _loadingFeeGroups = false;
    });
  }

  Future<void> _assignBank(int fgId, int? banId) async {
    final ok = await SupabaseService.setFeeGroupBank(fgId, banId);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bank account assigned'), backgroundColor: AppColors.success),
      );
      _fetchFeeGroups();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to assign bank account'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _branchController.dispose();
    _ifscController.dispose();
    _addr1Controller.dispose();
    _addr2Controller.dispose();
    _addr3Controller.dispose();
    _mobileController.dispose();
    _emailController.dispose();
    _accNoController.dispose();
    _accHolderController.dispose();
    super.dispose();
  }

  Future<void> _fetchBanks() async {
    setState(() => _isLoading = true);
    final data = await SupabaseService.getBanks();
    if (mounted) {
      setState(() {
        _banks = data;
        _isLoading = false;
      });
    }
  }

  void _resetForm() {
    _formKey.currentState?.reset();
    _nameController.clear();
    _branchController.clear();
    _ifscController.clear();
    _addr1Controller.clear();
    _addr2Controller.clear();
    _addr3Controller.clear();
    _mobileController.clear();
    _emailController.clear();
    _accNoController.clear();
    _accHolderController.clear();
    setState(() => _editingBanId = null);
  }

  void _loadIntoForm(Map<String, dynamic> b) {
    _nameController.text = b['banname']?.toString() ?? '';
    _branchController.text = b['banbranch']?.toString() ?? '';
    _ifscController.text = b['ifsccode']?.toString() ?? '';
    _addr1Controller.text = b['banaddress1']?.toString() ?? '';
    _addr2Controller.text = b['banaddress2']?.toString() ?? '';
    _addr3Controller.text = b['banaddress3']?.toString() ?? '';
    _mobileController.text = b['banmobile']?.toString() ?? '';
    _emailController.text = b['banemail']?.toString() ?? '';
    _accNoController.text = b['banaccno']?.toString() ?? '';
    _accHolderController.text = b['banaccholder']?.toString() ?? '';
    setState(() => _editingBanId = b['ban_id'] as int?);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final data = <String, dynamic>{
      'banname': _nameController.text.trim(),
      'banbranch': _branchController.text.trim(),
      'ifsccode': _ifscController.text.trim().toUpperCase(),
      'banaddress1': _addr1Controller.text.trim(),
      'banaddress2': _addr2Controller.text.trim().isEmpty ? null : _addr2Controller.text.trim(),
      'banaddress3': _addr3Controller.text.trim().isEmpty ? null : _addr3Controller.text.trim(),
      'banmobile': _mobileController.text.trim().isEmpty ? null : _mobileController.text.trim(),
      'banemail': _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
      'banaccno': _accNoController.text.trim(),
      'banaccholder': _accHolderController.text.trim(),
      'activestatus': 1,
    };

    bool ok;
    if (_editingBanId != null) {
      ok = await SupabaseService.updateBank(_editingBanId!, data);
    } else {
      ok = (await SupabaseService.addBank(data)) != null;
    }

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_editingBanId != null ? 'Bank account updated' : 'Bank account added'),
          backgroundColor: AppColors.success,
        ),
      );
      _resetForm();
      _fetchBanks();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save bank account'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete bank account?'),
        content: Text('Remove "${b['banname']}" (${b['banaccno']})? Existing fee groups and payments referencing it stay intact but the account stops appearing in dropdowns.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final banId = b['ban_id'] as int?;
    if (banId == null) return;
    if (await SupabaseService.deleteBank(banId)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bank account removed'), backgroundColor: AppColors.success),
      );
      if (_editingBanId == banId) _resetForm();
      setState(() => _selectedBank = null);
      _fetchBanks();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Page header — matches the User Creation screen.
          Row(
            children: [
              AppIcon('bank', color: AppColors.accent, size: 18),
              SizedBox(width: 10.w),
              Text(
                'Bank Accounts',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: 20.h),
          // Form + right column side by side (flex 3/7 like User Creation).
          LayoutBuilder(builder: (context, constraints) {
            final screenWidth = MediaQuery.of(context).size.width;
            final isCompact = screenWidth <= 1366;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: Add/Edit form
                Expanded(flex: 4, child: _buildForm()),
                SizedBox(width: isCompact ? 12.w : 24.w),
                // Right: drilldown when a bank is selected, otherwise
                // Fee Group Assignments stacked above the Bank Accounts list.
                Expanded(
                  flex: 6,
                  child: _selectedBank != null
                      ? _buildBankDetail(_selectedBank!)
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildAssignmentsPanel(),
                            SizedBox(height: 16.h),
                            _buildList(),
                          ],
                        ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildForm() {
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
                AppIcon(_editingBanId != null ? 'edit-2' : 'add-circle',
                    size: 18, color: AppColors.accent),
                SizedBox(width: 8.w),
                Text(_editingBanId != null ? 'Edit Bank Account' : 'Add Bank Account',
                    style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
                const Spacer(),
                if (_editingBanId != null)
                  TextButton.icon(
                    onPressed: _resetForm,
                    icon: const AppIcon('add', size: 14, color: AppColors.textSecondary),
                    label: const Text('New'),
                  ),
              ],
            ),
            SizedBox(height: 20.h),

            // Two fields per row — keeps the form compact and visually
            // balanced; the second slot is left empty when an odd field
            // doesn't have a natural partner.
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('Bank Name', _nameController, hint: 'IOB', required: true, validator: _vName)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Branch', _branchController, hint: 'Cuddalore Main', required: true, validator: _vBranch)),
            ]),
            SizedBox(height: 16.h),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('IFSC Code', _ifscController, hint: 'IOBA0001234', required: true,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(11),
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                  TextInputFormatter.withFunction((oldV, newV) => newV.copyWith(text: newV.text.toUpperCase())),
                ],
                validator: _vIfsc)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Account Holder', _accHolderController, hint: 'KCET College', required: true, validator: _vAccHolder)),
            ]),
            SizedBox(height: 16.h),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('Account Number', _accNoController, hint: '1234567890', required: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(18)],
                validator: _vAccNo)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Mobile', _mobileController, hint: '10-digit mobile', keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
                validator: _vMobile)),
            ]),
            SizedBox(height: 16.h),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('Email', _emailController, hint: 'finance@school.in', keyboardType: TextInputType.emailAddress, validator: _vEmail)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Address Line 1', _addr1Controller, required: true, validator: _vAddr1)),
            ]),
            SizedBox(height: 16.h),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('Address Line 2', _addr2Controller, validator: _vAddrOpt)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Address Line 3', _addr3Controller, validator: _vAddrOpt)),
            ]),
            SizedBox(height: 24.h),

            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: AppBtn.height(context),
                    child: OutlinedButton.icon(
                      onPressed: _isSaving ? null : _resetForm,
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
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : AppIcon(
                              _editingBanId != null ? 'tick-circle' : 'add',
                              size: AppBtn.iconSize(context),
                              color: Colors.white,
                            ),
                      label: Text(_editingBanId != null ? 'Update' : 'Add Bank'),
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

  Widget _labelledField(
    String label,
    TextEditingController controller, {
    String? hint,
    bool required = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          required ? '$label *' : label,
          style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black),
        ),
        SizedBox(height: 6.h),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          decoration: _inputDecoration(context, hint ?? '').copyWith(errorMaxLines: 3),
          style: _inputTextStyle(context),
          validator: validator ?? (required ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null : null),
        ),
      ],
    );
  }

  // ── Validators ────────────────────────────────────────────────
  String? _vName(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Required';
    if (s.length > 45) return 'Bank name must be less than 45 characters';
    return null;
  }
  String? _vBranch(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Required';
    if (s.length > 80) return 'Branch must be less than 80 characters';
    return null;
  }
  String? _vIfsc(String? v) {
    final s = (v ?? '').trim().toUpperCase();
    if (s.isEmpty) return 'Required';
    if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(s)) return 'IFSC must be 11 chars (e.g. IOBA0001234)';
    return null;
  }
  String? _vAccHolder(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Required';
    if (s.length > 50) return 'Account holder must be less than 50 characters';
    return null;
  }
  String? _vAccNo(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Required';
    if (s.length < 9 || s.length > 18) return 'Account number must be 9 to 18 digits';
    return null;
  }
  String? _vMobile(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s.length != 10) return 'Mobile must be 10 digits';
    return null;
  }
  String? _vEmail(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$').hasMatch(s)) return 'Enter a valid email address';
    if (s.length > 60) return 'Email must be less than 60 characters';
    return null;
  }
  String? _vAddr1(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Required';
    if (s.length > 50) return 'Address must be less than 50 characters';
    return null;
  }
  String? _vAddrOpt(String? v) {
    final s = v?.trim() ?? '';
    if (s.length > 50) return 'Address must be less than 50 characters';
    return null;
  }

  Widget _buildAssignmentsPanel() {
    return Container(
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4.w, right: 4.w, bottom: 8.h),
            child: Row(
              children: [
                const AppIcon('category-2', size: 18, color: AppColors.accent),
                SizedBox(width: 8.w),
                Text('Fee Group Assignments',
                    style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const Spacer(),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text(
                    '${_feeGroups.length} groups',
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent),
                  ),
                ),
              ],
            ),
          ),
          if (_loadingFeeGroups)
            const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
          else if (_feeGroups.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 24.h),
              child: Center(
                child: Text('No fee groups yet. Import fee groups in Master Data first.',
                    style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
              ),
            )
          else
            // Inner bordered table — mirrors the User Creation list panel.
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        Expanded(flex: 3, child: Text('FEE GROUP', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 4, child: Text('ROUTED TO', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  ...List.generate(_feeGroups.length, (i) {
                    final fg = _feeGroups[i];
                    final fgId = fg['fg_id'] as int?;
                    final rawBanId = fg['ban_id'] as int?;
                    // Reset to null if the saved bank was deleted — otherwise
                    // DropdownButtonFormField asserts because no item matches.
                    final currentBanId = rawBanId != null && _banks.any((b) => b['ban_id'] == rawBanId)
                        ? rawBanId
                        : null;
                    return Container(
                      padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 10.h),
                      color: i.isEven ? Colors.white : AppColors.surface,
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(fg['fgdesc']?.toString() ?? '',
                                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                                if (fg['yrlabel'] != null)
                                  Text(fg['yrlabel'].toString(),
                                      style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: DropdownButtonFormField<int?>(
                              value: currentBanId,
                              isExpanded: true,
                              dropdownColor: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              elevation: 6,
                              decoration: _inputDecoration(context, '— No account —'),
                              style: _inputTextStyle(context),
                              hint: Text('— No account —', style: _inputTextStyle(context)),
                              items: [
                                DropdownMenuItem<int?>(
                                  value: null,
                                  child: Text('— No account —', style: _inputTextStyle(context)),
                                ),
                                for (final b in _banks)
                                  DropdownMenuItem<int?>(
                                    value: b['ban_id'] as int?,
                                    child: Text(
                                      '${b['banname']} • ${b['banaccno']}',
                                      style: _inputTextStyle(context),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: fgId == null ? null : (v) => _assignBank(fgId, v),
                            ),
                          ),
                        ],
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

  Widget _buildList() {
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
                AppIcon('bank', size: 18, color: AppColors.accent),
                SizedBox(width: 8.w),
                Text('Bank Accounts',
                    style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
                const Spacer(),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Text('${_banks.length} accounts',
                      style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
                ),
                SizedBox(width: 8.w),
                SizedBox(
                  height: AppBtn.height(context),
                  child: ElevatedButton.icon(
                    onPressed: _fetchBanks,
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
          // Inner bordered table — sticky header + zebra rows + chevron,
          // matching the Existing Users table on the User Creation page.
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                  color: AppColors.tableHeadBg,
                  child: Row(
                    children: [
                      SizedBox(width: 50.w, child: Text('S NO.', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                      SizedBox(width: 16.w),
                      Expanded(flex: 3, child: Text('BANK', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                      Expanded(flex: 2, child: Text('BRANCH', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                      Expanded(flex: 3, child: Text('A/C NO.', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                      SizedBox(width: 30.w),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (_isLoading)
                  Padding(padding: EdgeInsets.all(32.w), child: const Center(child: CircularProgressIndicator()))
                else if (_banks.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(32.w),
                    child: Center(
                      child: Text('No bank accounts yet. Add one on the left.',
                          style: TextStyle(color: AppColors.textPrimary)),
                    ),
                  )
                else
                  ...List.generate(_banks.length, (i) {
                    final b = _banks[i];
                    return InkWell(
                      onTap: () => setState(() => _selectedBank = b),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                        color: i.isEven ? Colors.white : AppColors.surface,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 50.w,
                              child: Text('${i + 1}',
                                  style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                            ),
                            SizedBox(width: 16.w),
                            Expanded(
                              flex: 3,
                              child: Text(
                                b['banname']?.toString() ?? '-',
                                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                b['banbranch']?.toString() ?? '-',
                                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                b['banaccno']?.toString() ?? '-',
                                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            SizedBox(
                              width: 30.w,
                              child: AppIcon.linear('Chevron Right', size: 18, color: AppColors.textPrimary),
                            ),
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

  /// Drilldown detail view — mirrors `_buildUserDetail` on the User Creation
  /// page. Back button + breadcrumb on top, then bank avatar/name header,
  /// then labelled detail rows, then Edit + Delete actions.
  Widget _buildBankDetail(Map<String, dynamic> b) {
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
              width: 140.w,
              child: Text(label, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            ),
            Expanded(
              child: Text(value, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: valueColor ?? AppColors.textPrimary)),
            ),
          ],
        ),
      );
    }

    final addressLines = <String>[
      b['banaddress1']?.toString() ?? '',
      b['banaddress2']?.toString() ?? '',
      b['banaddress3']?.toString() ?? '',
    ].where((s) => s.trim().isNotEmpty).toList();
    final address = addressLines.isEmpty ? '-' : addressLines.join(', ');

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
          // Back button + breadcrumb
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
            child: Row(
              children: [
                InkWell(
                  onTap: () => setState(() => _selectedBank = null),
                  borderRadius: BorderRadius.circular(8.r),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                    decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(8.r)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
                        SizedBox(width: 6.w),
                        Text('Back', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: Colors.white)),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 12.w),
                Container(width: 1, height: 18, color: AppColors.border),
                SizedBox(width: 12.w),
                Text('Bank Accounts', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                SizedBox(width: 6.w),
                AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                SizedBox(width: 6.w),
                Expanded(
                  child: Text(
                    b['banname']?.toString() ?? '-',
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Bank avatar + name header
          Padding(
            padding: EdgeInsets.all(20.w),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28.r,
                  backgroundColor: AppColors.accent.withValues(alpha: 0.1),
                  child: AppIcon('bank', size: 26, color: AppColors.accent),
                ),
                SizedBox(width: 16.w),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b['banname']?.toString() ?? '-',
                        style: TextStyle(fontSize: 18.sp, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        '${b['banbranch']?.toString() ?? '-'}  •  ${b['ifsccode']?.toString() ?? '-'}',
                        style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Detail rows
          SizedBox(height: 8.h),
          detailRow('Account Holder', b['banaccholder']?.toString() ?? '-', icon: 'profile-circle'),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('Account Number', b['banaccno']?.toString() ?? '-', icon: 'card', valueColor: AppColors.accent),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('IFSC Code', b['ifsccode']?.toString() ?? '-', icon: 'code'),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('Mobile', (b['banmobile']?.toString().trim().isEmpty ?? true) ? '-' : b['banmobile'].toString(), icon: 'call'),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('Email', (b['banemail']?.toString().trim().isEmpty ?? true) ? '-' : b['banemail'].toString(), icon: 'sms'),
          Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.border.withValues(alpha: 0.5)),
          detailRow('Address', address, icon: 'location'),
          SizedBox(height: 16.h),
          // Edit + Delete actions
          Padding(
            padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 20.h),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: AppBtn.height(context),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _loadIntoForm(b);
                        setState(() => _selectedBank = null);
                      },
                      icon: AppIcon('edit-2', size: AppBtn.iconSize(context), color: AppColors.accent),
                      label: const Text('Edit'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accent,
                        side: const BorderSide(color: AppColors.accent),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: AppBtn.gap(context)),
                Expanded(
                  child: SizedBox(
                    height: AppBtn.height(context),
                    child: ElevatedButton.icon(
                      onPressed: () => _confirmDelete(b),
                      icon: AppIcon('trash', size: AppBtn.iconSize(context), color: Colors.white),
                      label: const Text('Delete'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.error,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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

  TextStyle _inputTextStyle(BuildContext context) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    return TextStyle(
      fontWeight: FontWeight.w500,
      fontSize: compact ? 11 : 14,
      color: const Color(0xFF555555),
    );
  }
}
