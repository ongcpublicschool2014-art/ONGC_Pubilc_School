import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../utils/master_usage.dart';
import '../../utils/friendly_error.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/app_ui.dart';

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
  final _paytmMidController = TextEditingController();

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
        const SnackBar(content: Text('Could not assign the bank account. Please try again.'), backgroundColor: AppColors.error),
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
    _paytmMidController.dispose();
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
    // Clear the controllers FIRST, then reset the form. Clearing a controller
    // fires a change that re-marks its field as "interacted", which with
    // AutovalidateMode.onUserInteraction would light up every field red with
    // "Required" on the freshly-emptied form. Calling reset() LAST clears those
    // interaction flags, so the blank form shows no validation errors.
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
    _paytmMidController.clear();
    setState(() => _editingBanId = null);
    // reset() restores each field to the value it was last BUILT with, so it
    // must run after the rebuild with the cleared controllers -- calling it
    // straight away put the typed text back and Clear appeared to do nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _formKey.currentState?.reset();
    });
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
    _paytmMidController.text = b['paytm_mid']?.toString() ?? '';
    setState(() => _editingBanId = b['ban_id'] as int?);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // ONE ACCOUNT NUMBER, ONE ROW.
    //
    // Two rows for the same account is not a harmless duplicate here: a fee
    // group routes to a ban_id, so the two halves of one real account can be
    // mapped to different groups, carry different paytm_mid values, and
    // settle money two ways while the bank statement shows one account.
    // Reconciliation then cannot tell which row a credit belongs to.
    //
    // The database enforces it too (BANK_ACCOUNT_UNIQUE.sql); this is the
    // readable version, and it names the row already using the number.
    final accNo = _accNoController.text.trim();
    final clash = _banks.firstWhere(
      (b) =>
          (b['banaccno']?.toString().trim() ?? '') == accNo &&
          b['ban_id'] != _editingBanId,
      orElse: () => const <String, dynamic>{},
    );
    if (clash.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Account number $accNo already belongs to "${clash['banname']}" — '
            '${clash['banbranch']}. Edit that account instead of adding it twice.'),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 5),
      ));
      return;
    }

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
      'paytm_mid': _paytmMidController.text.trim().isEmpty ? null : _paytmMidController.text.trim(),
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
        const SnackBar(content: Text('Could not save the bank account. Please try again.'), backgroundColor: AppColors.error),
      );
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> b) async {
    final banId = b['ban_id'] as int?;
    if (banId == null) return;

    // ── An account that signs Paytm orders may not be removed ─────────────
    // paytm_mid is the merchant online payments for this account are signed
    // with. Every order ever raised against it is matched back to Paytm THROUGH
    // this row: the recovery sweep takes the ban_id the order carries, looks up
    // the merchant here, and asks that merchant whether the money was captured.
    //
    // Delete is a SOFT delete, so the row survives -- but the account stops
    // being offered anywhere, and nobody can see that payments still depend on
    // it. A capture that arrives late for an order signed here then has nothing
    // obvious holding it together.
    //
    // Note there is deliberately NO "clear the MID and try again" instruction.
    // Clearing it breaks exactly the same lookup; it would turn a refusal into
    // a quiet failure, which is worse.
    final mid = b['paytm_mid']?.toString().trim() ?? '';
    if (mid.isNotEmpty) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cannot Delete This Bank Account'),
          content: Text(
              '"${b['banname']}" (${b['banaccno']}) carries a Paytm merchant ID, '
              'so online payments are collected through it.\n\n'
              'Every online payment ever made to this account is matched back to '
              'Paytm using this record. Removing it would leave any payment still '
              'being confirmed with no way to be traced, and the money would not '
              'reach a receipt.\n\n'
              'An account that has collected online payments stays on the list.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close')),
          ],
        ),
      );
      return;
    }

    // A fee group settles into a bank through feegroup.ban_id. Deleting the
    // bank here is a SOFT delete (activestatus = 0), so that mapping is not
    // cleared -- the group keeps pointing at an account that no longer appears
    // in any dropdown. Nothing errors; the fee group simply routes to a bank
    // nobody can see or re-select, and putting it right means finding the
    // mapping in a screen that no longer offers the account.
    //
    // So: refuse while any ACTIVE fee group still points here. A fee group that
    // was itself deleted does not count -- it holds a stale mapping that will
    // never be used, and blocking on it would leave the bank undeletable for a
    // reason the admin cannot see.
    try {
      final inUse = await SupabaseService.fromSchema('feegroup')
          .count()
          .eq('ban_id', banId)
          .eq('activestatus', 1);
      if (inUse > 0) {
        if (!mounted) return;
        await showMasterInUseDialog(
          context,
          name: b['banname']?.toString() ?? 'This bank account',
          count: inUse,
          noun: 'fee group',
          fix: 'Point those fee groups at another bank account first, in '
              'Setup → Fee Master → Fee Group.',
        );
        return;
      }
    } catch (e) {
      // The check itself failed -- the safe answer is to stop, not to delete
      // on the assumption that nothing references it.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not check whether this bank is in use. ${friendlyError(e)}'),
        backgroundColor: AppColors.error,
      ));
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Bank Account'),
        content: Text('Delete "${b['banname']}" (${b['banaccno']})? Past payments that used it are kept, but the account will no longer appear in dropdowns.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: AppUI.danger(context),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (await SupabaseService.deleteBank(banId)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bank account deleted'), backgroundColor: AppColors.success),
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
          // Page header - matches the User Creation screen.
          AppUI.cardHeader(icon: 'bank', title: 'Bank Accounts'),
          SizedBox(height: AppUI.gap),
          // Form + right column side by side (flex 3/7 like User Creation).
          LayoutBuilder(builder: (context, constraints) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: Add/Edit form
                Expanded(flex: 4, child: _buildForm()),
                SizedBox(width: AppUI.gap),
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
                            SizedBox(height: AppUI.gap),
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
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Form(
        key: _formKey,
        child: FocusTraversalGroup(
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppUI.cardHeader(
              icon: _editingBanId != null ? 'edit-2' : 'add-circle',
              title: _editingBanId != null ? 'Edit Bank Account' : 'Add Bank Account',
              trailing: [
                if (_editingBanId != null)
                  TextButton.icon(
                    onPressed: _resetForm,
                    icon: const AppIcon('add', size: 14, color: AppColors.primary),
                    label: const Text('Add New Account'),
                  ),
              ],
            ),
            SizedBox(height: 20.h),

            // Two fields per row - keeps the form compact and visually
            // balanced; the second slot is left empty when an odd field
            // doesn't have a natural partner.
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('Bank Name', _nameController, hint: 'e.g. Indian Overseas Bank', required: true, validator: _vName)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Branch', _branchController, hint: 'e.g. Cuddalore Main', required: true, validator: _vBranch)),
            ]),
            SizedBox(height: 16.h),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('IFSC Code', _ifscController, hint: 'e.g. IOBA0001234', required: true,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(11),
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                  TextInputFormatter.withFunction((oldV, newV) => newV.copyWith(text: newV.text.toUpperCase())),
                ],
                validator: _vIfsc)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Account Holder Name', _accHolderController, hint: 'Enter account holder name', required: true, validator: _vAccHolder)),
            ]),
            SizedBox(height: 16.h),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('Account Number', _accNoController, hint: 'Enter account number', required: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(18)],
                validator: _vAccNo)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Mobile Number', _mobileController, hint: 'Enter 10-digit mobile number', keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
                validator: _vMobile)),
            ]),
            SizedBox(height: 16.h),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('Email', _emailController, hint: 'e.g. finance@school.in', keyboardType: TextInputType.emailAddress, validator: _vEmail)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Address Line 1', _addr1Controller, required: true, validator: _vAddr1)),
            ]),
            SizedBox(height: 16.h),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('Address Line 2', _addr2Controller, validator: _vAddrOpt)),
              SizedBox(width: 16.w),
              Expanded(child: _labelledField('Address Line 3', _addr3Controller, validator: _vAddrOpt)),
            ]),
            SizedBox(height: 16.h),
            // Paytm MID: the online-payment merchant that settles to THIS bank
            // account. Fee groups mapped to this bank route their Paytm payment
            // to this MID. Leave blank to use the app's default MID.
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _labelledField('Paytm Merchant ID', _paytmMidController,
                hint: 'Leave blank to use the default merchant ID',
                inputFormatters: [
                  LengthLimitingTextInputFormatter(40),
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                ])),
              SizedBox(width: 16.w),
              const Expanded(child: SizedBox.shrink()),
            ]),
            SizedBox(height: 16.h),
            AppUI.requiredNote(),
            SizedBox(height: 12.h),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isSaving ? null : _resetForm,
                    icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: AppColors.primary),
                    label: const Text('Clear'),
                  ),
                ),
                SizedBox(width: AppBtn.gap(context)),
                Expanded(
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
                    label: Text(_editingBanId != null ? 'Update' : 'Add Bank Account'),
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
        AppUI.fieldLabel(label, required: required),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          onChanged: (_) => setState(() {}),
          decoration: _inputDecoration(context, hint ?? '', filled: controller.text.trim().isNotEmpty).copyWith(errorMaxLines: 3),
          style: _inputTextStyle(context, filled: controller.text.trim().isNotEmpty),
          validator: validator ?? (required ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null : null),
        ),
      ],
    );
  }

  // â”€â”€ Validators â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  String? _vName(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Enter the bank name';
    if (s.length > 45) return 'Bank name must be 45 characters or fewer';
    return null;
  }
  String? _vBranch(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Enter the branch name';
    if (s.length > 80) return 'Branch name must be 80 characters or fewer';
    return null;
  }
  String? _vIfsc(String? v) {
    final s = (v ?? '').trim().toUpperCase();
    if (s.isEmpty) return 'Enter the IFSC code';
    if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(s)) return 'Enter a valid 11-character IFSC code (e.g. IOBA0001234)';
    return null;
  }
  String? _vAccHolder(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Enter the account holder name';
    if (s.length > 50) return 'Account holder name must be 50 characters or fewer';
    return null;
  }
  String? _vAccNo(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Enter the account number';
    if (s.length < 9 || s.length > 18) return 'Account number must be 9 to 18 digits';
    return null;
  }
  String? _vMobile(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return null;
    if (s.length != 10) return 'Enter a 10-digit mobile number';
    return null;
  }
  String? _vEmail(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$').hasMatch(s)) return 'Enter a valid email address';
    if (s.length > 60) return 'Email must be 60 characters or fewer';
    return null;
  }
  String? _vAddr1(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Enter address line 1';
    if (s.length > 50) return 'Address must be 50 characters or fewer';
    return null;
  }
  String? _vAddrOpt(String? v) {
    final s = v?.trim() ?? '';
    if (s.length > 50) return 'Address must be 50 characters or fewer';
    return null;
  }

  Widget _buildAssignmentsPanel() {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4.w, right: 4.w, bottom: 8.h),
            child: Row(
              children: [
                const CardTitleBlock(icon: 'category-2', title: 'Fee Group Assignments', subtitle: 'map fee groups to their collection bank'),
                const Spacer(),
                AppUI.chip('${_feeGroups.length} groups', AppStatus.info),
              ],
            ),
          ),
          if (_loadingFeeGroups)
            const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
          else if (_feeGroups.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 8.h),
              child: AppUI.empty(
                title: 'No fee groups yet. Add them in Setup → Fee Master → Fee Group first.',
                icon: 'category-2',
              ),
            )
          else
            // Inner bordered table - mirrors the User Creation list panel.
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    decoration: AppUI.tableHeadBar,
                    child: Row(
                      children: [
                        AppUI.th('FEE GROUP', flex: 3),
                        AppUI.th('ROUTED TO', flex: 4),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  ...List.generate(_feeGroups.length, (i) {
                    final fg = _feeGroups[i];
                    final fgId = fg['fg_id'] as int?;
                    final rawBanId = fg['ban_id'] as int?;
                    // Reset to null if the saved bank was deleted - otherwise
                    // DropdownButtonFormField asserts because no item matches.
                    final currentBanId = rawBanId != null && _banks.any((b) => b['ban_id'] == rawBanId)
                        ? rawBanId
                        : null;
                    return Container(
                      padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 10.h),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.divider)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(fg['fgdesc']?.toString() ?? '',
                                    style: AppUI.cell.copyWith(fontWeight: FontWeight.w700)),
                                if (fg['yrlabel'] != null)
                                  Text(fg['yrlabel'].toString(),
                                      style: AppUI.muted),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: DropdownButtonFormField<int?>(
                              value: currentBanId,
                              icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                              isExpanded: true,
                              dropdownColor: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              elevation: 6,
                              decoration: _inputDecoration(context, 'Select bank account', filled: currentBanId != null),
                              style: _inputTextStyle(context, filled: currentBanId != null),
                              hint: Text('Select bank account', style: _inputTextStyle(context)),
                              items: [
                                DropdownMenuItem<int?>(
                                  value: null,
                                  child: Text('Not assigned', style: _inputTextStyle(context)),
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
                              selectedItemBuilder: (context) => [
                                Align(alignment: Alignment.centerLeft, child: Text('Not assigned', overflow: TextOverflow.ellipsis, style: _inputTextStyle(context, filled: true))),
                                for (final b in _banks)
                                  Align(alignment: Alignment.centerLeft, child: Text('${b['banname']} • ${b['banaccno']}', overflow: TextOverflow.ellipsis, style: _inputTextStyle(context, filled: true))),
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
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4.w, right: 4.w, bottom: 8.h),
            child: Row(
              children: [
                const CardTitleBlock(icon: 'bank', title: 'Bank Accounts', subtitle: 'all bank accounts in this institution'),
                const Spacer(),
                AppUI.chip('${_banks.length} accounts', AppStatus.info),
                SizedBox(width: 8.w),
                ElevatedButton.icon(
                  onPressed: _fetchBanks,
                  icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                  label: const Text('Refresh'),
                ),
              ],
            ),
          ),
          // Inner bordered table - sticky header + zebra rows + chevron,
          // matching the Existing Users table on the User Creation page.
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                  decoration: AppUI.tableHeadBar,
                  child: Row(
                    children: [
                      SizedBox(width: 50.w, child: Text('S NO.', style: AppUI.tableHead)),
                      SizedBox(width: 16.w),
                      AppUI.th('BANK', flex: 3),
                      AppUI.th('BRANCH', flex: 2),
                      AppUI.th('ACCOUNT NO.', flex: 3),
                      SizedBox(width: 30.w),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (_isLoading)
                  Padding(padding: EdgeInsets.all(32.w), child: const Center(child: CircularProgressIndicator()))
                else if (_banks.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(8.w),
                    child: AppUI.empty(
                      title: 'No bank accounts yet. Add one on the left.',
                      icon: 'bank',
                    ),
                  )
                else
                  ...List.generate(_banks.length, (i) {
                    final b = _banks[i];
                    return InkWell(
                      onTap: () => setState(() => _selectedBank = b),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: i == 0 ? null : const Border(top: BorderSide(color: AppColors.divider)),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 50.w,
                              child: Text('${i + 1}',
                                  style: AppUI.cell.copyWith(color: AppColors.textSecondary)),
                            ),
                            SizedBox(width: 16.w),
                            Expanded(
                              flex: 3,
                              child: Text(
                                b['banname']?.toString() ?? '-',
                                style: AppUI.cell.copyWith(fontWeight: FontWeight.w700),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                b['banbranch']?.toString() ?? '-',
                                style: AppUI.cell.copyWith(color: AppColors.textSecondary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                b['banaccno']?.toString() ?? '-',
                                style: AppUI.cell.copyWith(fontWeight: FontWeight.w600, color: AppColors.accent),
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

  /// Drilldown detail view - mirrors `_buildUserDetail` on the User Creation
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
              child: Text(label, style: AppUI.label.copyWith(color: AppColors.textSecondary)),
            ),
            Expanded(
              child: Text(value, style: AppUI.body.copyWith(color: valueColor ?? AppColors.textPrimary)),
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
      decoration: AppUI.card(),
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
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                    decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(AppUI.controlRadius)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
                        SizedBox(width: 6.w),
                        Text('Back', style: AppUI.label.copyWith(color: Colors.white)),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 12.w),
                Container(width: 1, height: 18, color: AppColors.border),
                SizedBox(width: 12.w),
                Text('Bank Accounts', style: AppUI.muted),
                SizedBox(width: 6.w),
                AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                SizedBox(width: 6.w),
                Expanded(
                  child: Text(
                    b['banname']?.toString() ?? '-',
                    style: AppUI.label,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Bank avatar + name header
          Padding(
            padding: EdgeInsets.all(AppUI.cardPad),
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
                        style: AppUI.cardTitle,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2.h),
                      Text(
                        '${b['banbranch']?.toString() ?? '-'}  •  ${b['ifsccode']?.toString() ?? '-'}',
                        style: AppUI.muted,
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
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('Account Number', b['banaccno']?.toString() ?? '-', icon: 'card', valueColor: AppColors.accent),
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('IFSC Code', b['ifsccode']?.toString() ?? '-', icon: 'code'),
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('Mobile', (b['banmobile']?.toString().trim().isEmpty ?? true) ? '-' : b['banmobile'].toString(), icon: 'call'),
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('Email', (b['banemail']?.toString().trim().isEmpty ?? true) ? '-' : b['banemail'].toString(), icon: 'sms'),
          const Divider(height: 1, indent: 20, endIndent: 20, color: AppColors.divider),
          detailRow('Address', address, icon: 'location'),
          SizedBox(height: 16.h),
          // Edit + Delete actions
          Padding(
            padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 20.h),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      _loadIntoForm(b);
                      setState(() => _selectedBank = null);
                    },
                    icon: AppIcon('edit-2', size: AppBtn.iconSize(context), color: AppColors.accent),
                    label: const Text('Edit'),
                  ),
                ),
                SizedBox(width: AppBtn.gap(context)),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _confirmDelete(b),
                    icon: AppIcon('trash', size: AppBtn.iconSize(context), color: Colors.white),
                    label: const Text('Delete'),
                    style: AppUI.danger(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(BuildContext context, String hint, {bool filled = false}) {
    return AppUI.field(context, hint, filled: filled);
  }

  TextStyle _inputTextStyle(BuildContext context, {bool filled = false}) {
    return AppUI.fieldText(context, filled: filled);
  }
}
