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
import '../../widgets/app_dropdown_field.dart';
import '../../config/supabase_config.dart';
import '../../utils/payment_gateways.dart';

/// Bank account master for the active institution. Each row represents a
/// beneficiary account a fee group can route to (school's main account,
/// transport vendor, hostel, etc.). Layout mirrors the User Creation
/// screen: flex 3/7 with a stacked single-column form on the left and the
/// assignments + list (or drilldown) on the right.
class BankDetailsScreen extends StatefulWidget {
  /// Off by default: a fee group picks its bank in Fee Master -> Fee Group
  /// (user, 2026-11-14), so the old assignment box is not shown.
  final bool showAssignments;
  /// false inside the Manage Bank Accounts pop-up (it has its own title bar).
  final bool showHeader;
  const BankDetailsScreen({super.key, this.showAssignments = false, this.showHeader = true});

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

  // A bank that is its OWN merchant at the school's gateway (e.g. the hostel's
  // Paytm MID with its own key). Its fees are paid under that merchant.
  Map<String, dynamic>? _gw; // the school's gateway, if any
  Map<int, Map<String, dynamic>> _bankMerchants = {};
  /// How this bank takes online payments: MAIN = the gateway's main account,
  /// SUB = a sub-account under it, OWN = a separate merchant with its own key.
  String _settle = 'MAIN';
  bool get _ownMerchant => _settle == 'OWN';
  bool _ownHasSecret = false;
  bool _ownTesting = false;
  final Map<String, TextEditingController> _ownCtl = {};
  TextEditingController _own(String k) => _ownCtl.putIfAbsent(k, () => TextEditingController());
  PgProvider? get _gwProv => _gw == null ? null : pgProvider('${_gw!['provider']}');
  bool get _canOwn => _gwProv != null && _gwProv!.code != 'PHONEPE';
  // When non-null, the right column shows the bank detail drilldown
  // (back button + breadcrumb + detail rows) instead of the
  // assignments + list.
  Map<String, dynamic>? _selectedBank;

  @override
  void initState() {
    super.initState();
    _fetchBanks();
    _fetchFeeGroups();
    _fetchGateway();
  }

  Future<void> _fetchGateway() async {
    try {
      final l = await PaymentGatewayService.list();
      final gws = (l['gateways'] as List? ?? const []);
      Map<int, Map<String, dynamic>> bm = {};
      try {
        bm = await PaymentGatewayService.bankMerchants();
      } catch (_) {
        // database not updated yet: no per-bank merchants
      }
      if (!mounted) return;
      setState(() {
        _gw = gws.isEmpty ? null : Map<String, dynamic>.from(gws.first as Map);
        _bankMerchants = bm;
      });
    } catch (e) {
      debugPrint('bank screen: gateway lookup failed: $e');
    }
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
    for (final c in _ownCtl.values) {
      c.dispose();
    }
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
    for (final c in _ownCtl.values) {
      c.clear();
    }
    setState(() {
      _editingBanId = null;
      _settle = 'MAIN';
      _ownHasSecret = false;
    });
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
    final m = _bankMerchants[(b['ban_id'] as num?)?.toInt() ?? -1];
    for (final c in _ownCtl.values) {
      c.clear();
    }
    _own('website').text = '${(m?['config'] as Map?)?['website'] ?? ''}';
    setState(() {
      _editingBanId = b['ban_id'] as int?;
      final mid = _paytmMidController.text.trim();
      _settle = m != null
          ? 'OWN'
          : (mid.isEmpty || _gw == null || _gwProv?.code == 'PHONEPE' || pgIsMainMerchantId(_gw!, mid))
              ? 'MAIN'
              : 'SUB';
      _ownHasSecret = m?['has_secret'] == true;
    });
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

    // Own merchant account: it needs the bank's ID, and its key the first time.
    final ownSecret = <String, String>{
      if (_ownMerchant && _gwProv != null)
        for (final f in _gwProv!.secretFields)
          if (_own(f.key).text.trim().isNotEmpty) f.key: _own(f.key).text.trim(),
    };
    if (_ownMerchant) {
      if (_paytmMidController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Enter the Merchant / Settlement ID of this separate merchant account.'),
            backgroundColor: AppColors.warning));
        return;
      }
      final need = _gwProv!.secretFields.where((f) => f.required && !ownSecret.containsKey(f.key));
      if (!_ownHasSecret && need.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Enter the ${need.first.label} of this merchant account.'), backgroundColor: AppColors.warning));
        return;
      }
    }

    setState(() => _isSaving = true);

    // Leaving "Separate merchant" is refused while one of its payments is still
    // open. Ask FIRST: saving the bank and then being refused left the bank and
    // its merchant saying different things.
    if (_editingBanId != null && _canOwn && !_ownMerchant && _bankMerchants.containsKey(_editingBanId)) {
      try {
        await PaymentGatewayService.deleteBankMerchant(_editingBanId!);
      } catch (e) {
        if (!mounted) return;
        setState(() => _isSaving = false);
        final open = '$e'.contains('still being confirmed');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(open
                ? 'Nothing was changed. An online payment through this merchant is still being confirmed. '
                    'Change it after that payment is settled (Setup → Payment Gateways → Payments Needing Attention).'
                : 'Nothing was changed. ${friendlyError(e)}'),
            backgroundColor: AppColors.warning,
            duration: const Duration(seconds: 8)));
        return;
      }
    }

    // The ID only means something for the choice made in the form. A row that
    // already names the main merchant keeps it.
    final typedMid = _paytmMidController.text.trim();
    final String? midToSave = typedMid.isEmpty
        ? null
        : (_gw == null || _settle != 'MAIN' || pgIsMainMerchantId(_gw!, typedMid))
            ? typedMid
            : null;

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
      'paytm_mid': midToSave,
      'activestatus': 1,
    };

    bool ok;
    int? banId = _editingBanId;
    if (_editingBanId != null) {
      ok = await SupabaseService.updateBank(_editingBanId!, data);
    } else {
      banId = await SupabaseService.addBank(data);
      ok = banId != null;
    }

    // The bank's own merchant keys (encrypted on the server).
    String? ownError;
    if (ok && banId != null && _canOwn) {
      try {
        if (_ownMerchant) {
          final website = _own('website').text.trim();
          await PaymentGatewayService.saveBankMerchant(
              banId,
              {if (_gwProv!.code == 'PAYTM' && website.isNotEmpty) 'website': website.toUpperCase()},
              ownSecret.isEmpty ? null : ownSecret);
        }
      } catch (e) {
        ownError = friendlyError(e);
      }
      await _fetchGateway();
    }
    if (ownError != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Bank saved, but its merchant account was not: $ownError'),
          backgroundColor: AppColors.error, duration: const Duration(seconds: 7)));
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
              '"${b['banname']}" (${b['banaccno']}) carries a merchant ID, '
              'so online payments are collected through it.\n\n'
              'Every online payment ever made to this account is matched back to '
              'the gateway using this record. Removing it would leave any payment still '
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
      // room for the scrollbar, so it never sits over the cards' right edge
      padding: const EdgeInsets.only(right: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Page header - matches the User Creation screen.
          if (widget.showHeader) ...[
            AppUI.cardHeader(icon: 'bank', title: 'Bank Accounts'),
            SizedBox(height: AppUI.gap),
          ],
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
                            if (widget.showAssignments) ...[
                              _buildAssignmentsPanel(),
                              SizedBox(height: AppUI.gap),
                            ],
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
            _onlineSection(),
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

  /// One choice of how this bank takes online payments.
  Widget _settleOption(String value, String title, String sub) {
    final on = _settle == value;
    return InkWell(
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      onTap: () => setState(() => _settle = value),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 5.h),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18.sp, color: on ? AppColors.primary : AppColors.textLight),
          SizedBox(width: 8.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppUI.label),
              Text(sub, style: AppUI.muted),
            ]),
          ),
        ]),
      ),
    );
  }

  /// Online payments for this bank: one question, with only the fields the
  /// answer needs, worded for the school's own gateway (user, 2026-11-18).
  Widget _onlineSection() {
    final idFormat = [
      LengthLimitingTextInputFormatter(60),
      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_-]')),
    ];
    final prov = _gwProv;
    if (prov == null) {
      // No gateway yet: nothing to choose from.
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _labelledField('Merchant / Settlement ID', _paytmMidController,
            hint: 'Optional',
            helper: 'Only for online payments. It can be added after the payment gateway is set up.',
            inputFormatters: idFormat)),
        SizedBox(width: 16.w),
        const Expanded(child: SizedBox.shrink()),
      ]);
    }
    if (prov.code == 'PHONEPE') {
      return Text('PhonePe pays all online money into its main account, so nothing is needed here.', style: AppUI.muted);
    }
    final label = pgSplitLabel(prov.code) ?? 'Merchant ID';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AppUI.fieldLabel('Online payments for this bank'),
      _settleOption('MAIN', 'Main ${prov.name} account', 'Online money goes to the main account. No ID is needed.'),
      _settleOption('SUB', '${prov.name} sub-account', 'The payment is split to this bank using its $label.'),
      _settleOption('OWN', 'Separate ${prov.name} merchant',
          'Its own merchant account and key, for example a hostel MID. Paid separately from other fee groups.'),
      if (_settle == 'SUB') ...[
        SizedBox(height: 8.h),
        _labelledField(label, _paytmMidController, required: true, inputFormatters: idFormat, validator: (v) {
          final s = (v ?? '').trim();
          return s.isEmpty ? 'Enter the $label' : pgMerchantIdError(_gw!, s);
        }),
      ],
      if (_settle == 'OWN') ...[
        SizedBox(height: 8.h),
        _labelledField('Merchant ID', _paytmMidController, required: true, inputFormatters: idFormat),
        _ownMerchantSection(),
      ],
    ]);
  }

  /// "Separate merchant account": this bank's ID is its own merchant at the
  /// school's gateway (own key), not a sub-account under the main merchant.
  Widget _ownMerchantSection() {
    final prov = _gwProv!;
    final pgId = (_gw!['pg_id'] as num).toInt();
    final saved = _editingBanId != null && _bankMerchants.containsKey(_editingBanId);
    final webhook = _editingBanId == null
        ? ''
        : '${SupabaseConfig.url}/functions/v1/pay-webhook?pg=$pgId&ban=$_editingBanId';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_ownMerchant) ...[        SizedBox(height: 10.h),
        Wrap(spacing: 16.w, runSpacing: 10.h, children: [
          for (final f in prov.secretFields)
            SizedBox(
              width: 300.w,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AppUI.fieldLabel(f.label, required: f.required && !_ownHasSecret, optional: !f.required),
                TextField(
                  controller: _own(f.key),
                  obscureText: true,
                  style: AppUI.fieldText(context),
                  decoration: AppUI.field(context, _ownHasSecret ? 'Saved ••••••  (type to replace)' : f.hint),
                ),
              ]),
            ),
          if (prov.code == 'PAYTM')
            SizedBox(
              width: 300.w,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AppUI.fieldLabel('Website Name', optional: true),
                TextField(
                  controller: _own('website'),
                  style: AppUI.fieldText(context),
                  decoration: AppUI.field(context, 'Blank = same as the gateway'),
                ),
              ]),
            ),
        ]),
        if (saved) ...[
          SizedBox(height: 10.h),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _ownTesting
                  ? null
                  : () async {
                      setState(() => _ownTesting = true);
                      final r = await PaymentGatewayService.test(pgId, banId: _editingBanId);
                      if (!mounted) return;
                      setState(() => _ownTesting = false);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(r.ok ? 'Connected: ${r.message}' : r.message),
                          backgroundColor: r.ok ? AppColors.success : AppColors.error));
                    },
              icon: _ownTesting
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering, size: 16),
              label: const Text('Test Connection'),
            ),
            SizedBox(width: 12.w),
            Expanded(child: SelectableText('Webhook: $webhook', style: AppUI.muted)),
            IconButton(
              tooltip: 'Copy webhook URL',
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () => Clipboard.setData(ClipboardData(text: webhook)),
            ),
          ]),
        ],
      ],
    ]);
  }

  Widget _labelledField(
    String label,
    TextEditingController controller, {
    String? hint,
    String? helper,
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
          decoration: _inputDecoration(context, hint ?? '', filled: controller.text.trim().isNotEmpty).copyWith(
            errorMaxLines: 3,
            // [helper] explains the field in a caption under it, so the
            // placeholder itself can stay short.
            helperText: helper,
            helperMaxLines: 2,
            helperStyle: helper == null ? null : AppUI.muted,
          ),
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
                AppUI.chip('${_feeGroups.length} group${_feeGroups.length == 1 ? '' : 's'}', AppStatus.info),
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
                            child: AppDropdownField<int?>(
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
                AppUI.chip('${_banks.length} account${_banks.length == 1 ? '' : 's'}', AppStatus.info),
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
