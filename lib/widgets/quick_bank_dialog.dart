import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../screens/admin/bank_details_screen.dart';
import '../services/supabase_service.dart';
import '../utils/app_theme.dart';
import '../utils/friendly_error.dart';
import '../utils/payment_gateways.dart';
import 'app_ui.dart';

/// Every bank account in full -- edit, delete, the Merchant / Settlement ID,
/// a separate merchant account with its own key, Test Connection, webhook --
/// in a pop-up over Fee Master -> Fee Group. (Payment Gateways holds only the
/// gateway account now; user, 2026-11-14.)
Future<void> showManageBanksDialog(BuildContext context) async {
  final size = MediaQuery.of(context).size;
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 20.h),
      backgroundColor: AppColors.surface,
      child: SizedBox(
        width: size.width * 0.92,
        height: size.height * 0.88,
        child: Padding(
          padding: EdgeInsets.all(AppUI.cardPad),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: AppUI.cardHeader(icon: 'bank', title: 'Bank Accounts', subtitle: 'add, edit or remove the school\'s bank accounts')),
              IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
            ]),
            SizedBox(height: AppUI.gap),
            const Expanded(child: BankDetailsScreen(showHeader: false)),
          ]),
        ),
      ),
    ),
  );
}

/// Adds a bank account from wherever it is needed -- Fee Master -> Fee Group
/// picks the group's bank and can create one on the spot (user, 2026-11-14:
/// "use feegroup master and bring bank account creation because its easy for
/// user"). The essentials only, checked as Setup -> Payment Gateways -> Bank
/// Accounts checks them; a merchant / settlement ID is added there later.
///
/// Returns the new ban_id, or null when cancelled.
Future<int?> showQuickBankDialog(BuildContext context, {List<Map<String, dynamic>> existing = const []}) {
  return showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _QuickBankDialog(existing: existing),
  );
}

class _QuickBankDialog extends StatefulWidget {
  final List<Map<String, dynamic>> existing;
  const _QuickBankDialog({required this.existing});

  @override
  State<_QuickBankDialog> createState() => _QuickBankDialogState();
}

class _QuickBankDialogState extends State<_QuickBankDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _branch = TextEditingController();
  final _ifsc = TextEditingController();
  final _addr = TextEditingController();
  final _accNo = TextEditingController();
  final _holder = TextEditingController();
  final _mid = TextEditingController(); // the sub-account's ID
  bool _saving = false;

  // Online payments for this bank, worded for the school's own gateway.
  Map<String, dynamic>? _gw;
  bool _sub = false; // false = the gateway's main account

  @override
  void initState() {
    super.initState();
    _loadGateway();
  }

  Future<void> _loadGateway() async {
    try {
      final l = await PaymentGatewayService.list();
      final gws = (l['gateways'] as List? ?? const []);
      if (mounted && gws.isNotEmpty) setState(() => _gw = Map<String, dynamic>.from(gws.first as Map));
    } catch (e) {
      debugPrint('new bank: gateway lookup failed: $e');
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _branch, _ifsc, _addr, _accNo, _holder, _mid]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _req(String? v, String what, int max) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Enter the $what';
    if (s.length > max) return '${what[0].toUpperCase()}${what.substring(1)} must be $max characters or fewer';
    return null;
  }

  String? _vIfsc(String? v) {
    final s = (v ?? '').trim().toUpperCase();
    if (s.isEmpty) return 'Enter the IFSC code';
    if (!RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$').hasMatch(s)) return 'Enter a valid 11-character IFSC code (e.g. IOBA0001234)';
    return null;
  }

  String? _vAccNo(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'Enter the account number';
    if (s.length < 9 || s.length > 18) return 'Account number must be 9 to 18 digits';
    // One account number, one row (as the Bank Accounts screen).
    final clash = widget.existing.where((b) => '${b['banaccno'] ?? ''}'.trim() == s);
    if (clash.isNotEmpty) return 'Already added as "${clash.first['banname']}" -- pick it instead';
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final id = await SupabaseService.addBank({
        'banname': _name.text.trim(),
        'banbranch': _branch.text.trim(),
        'ifsccode': _ifsc.text.trim().toUpperCase(),
        'banaddress1': _addr.text.trim(),
        'banaccno': _accNo.text.trim(),
        'banaccholder': _holder.text.trim(),
        'paytm_mid': _sub && _mid.text.trim().isNotEmpty ? _mid.text.trim() : null,
        'activestatus': 1,
      });
      if (!mounted) return;
      Navigator.of(context).pop(id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add the bank account. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  Widget _field(String label, TextEditingController c, String hint, String? Function(String?) v,
      {List<TextInputFormatter>? fmt, TextCapitalization cap = TextCapitalization.none}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      AppUI.fieldLabel(label, required: true),
      TextFormField(
        controller: c,
        enabled: !_saving,
        inputFormatters: fmt,
        textCapitalization: cap,
        style: AppUI.fieldText(context, filled: true),
        decoration: AppUI.field(context, hint),
        validator: v,
        autovalidateMode: AutovalidateMode.onUserInteraction,
      ),
    ]);
  }

  Widget _option(bool sub, String title, String text) {
    final on = _sub == sub;
    return InkWell(
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      onTap: _saving ? null : () => setState(() => _sub = sub),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 5.h),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18.sp, color: on ? AppColors.primary : AppColors.textLight),
          SizedBox(width: 8.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppUI.label),
              Text(text, style: AppUI.muted),
            ]),
          ),
        ]),
      ),
    );
  }

  /// One question, with only the field the answer needs.
  Widget _online() {
    final provider = '${_gw?['provider'] ?? ''}'.toUpperCase();
    final name = pgProvider(provider)?.name ?? provider;
    final label = pgSplitLabel(provider);
    if (_gw == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('Online payment settings can be added after the payment gateway is set up.', style: AppUI.muted),
      );
    }
    if (label == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('$name pays all online money into its main account, so nothing is needed here.', style: AppUI.muted),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      AppUI.fieldLabel('Online payments for this bank'),
      _option(false, 'Main $name account', 'Online money goes to the main account. No ID is needed.'),
      _option(true, '$name sub-account', 'The payment is split to this bank using its $label.'),
      if (_sub) ...[
        SizedBox(height: 8.h),
        AppUI.fieldLabel(label, required: true),
        TextFormField(
          controller: _mid,
          enabled: !_saving,
          inputFormatters: [LengthLimitingTextInputFormatter(60), FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_-]'))],
          style: AppUI.fieldText(context, filled: true),
          decoration: AppUI.field(context, label),
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (v) {
            final s = (v ?? '').trim();
            return s.isEmpty ? 'Enter the $label' : pgMerchantIdError(_gw!, s);
          },
        ),
      ],
      SizedBox(height: 4.h),
      Text('A separate $name merchant with its own key: save, then use Manage bank accounts.', style: AppUI.muted),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    Widget pair(Widget a, Widget b) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: a),
          SizedBox(width: 12.w),
          Expanded(child: b),
        ]);
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.account_balance_outlined, color: AppColors.primary),
        SizedBox(width: 10.w),
        Text('New Bank Account', style: AppUI.cardTitle),
      ]),
      content: SizedBox(
        width: 560.w,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              pair(
                _field('Bank Name', _name, 'e.g. Indian Overseas Bank', (v) => _req(v, 'bank name', 45), cap: TextCapitalization.characters),
                _field('Branch', _branch, 'Branch name', (v) => _req(v, 'branch name', 80), cap: TextCapitalization.words),
              ),
              SizedBox(height: 12.h),
              pair(
                _field('Account No.', _accNo, '9 to 18 digits', _vAccNo, fmt: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(18)]),
                _field('IFSC Code', _ifsc, 'e.g. IOBA0001234', _vIfsc,
                    fmt: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')), LengthLimitingTextInputFormatter(11)], cap: TextCapitalization.characters),
              ),
              SizedBox(height: 12.h),
              pair(
                _field('Account Holder', _holder, 'Name on the account', (v) => _req(v, 'account holder name', 50), cap: TextCapitalization.words),
                _field('Address', _addr, 'Branch address', (v) => _req(v, 'address', 50)),
              ),
              SizedBox(height: 12.h),
              _online(),
            ]),
          ),
        ),
      ),
      actions: [
        OutlinedButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save, size: 16, color: Colors.white),
          label: const Text('Save Bank Account'),
        ),
      ],
    );
  }
}
