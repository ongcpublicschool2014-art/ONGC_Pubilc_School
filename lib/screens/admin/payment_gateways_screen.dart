import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../config/supabase_config.dart';
import '../../services/online_payment_service.dart';
import '../../services/supabase_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/payment_gateways.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/online_route_chip.dart';

/// Setup > Payment Gateways: the school's own online payment account (Paytm,
/// Razorpay, PhonePe, Cashfree or Easebuzz) with the credentials it enters
/// here. Secrets are stored encrypted and never shown again. The status card
/// on top says whether online payments are ready and where each fee group's
/// money goes (user, 2026-11-18).
class PaymentGatewaysScreen extends StatefulWidget {
  const PaymentGatewaysScreen({super.key});
  @override
  State<PaymentGatewaysScreen> createState() => _PaymentGatewaysScreenState();
}

class _PaymentGatewaysScreenState extends State<PaymentGatewaysScreen> {
  bool _loading = true, _saving = false, _testing = false;
  List<Map<String, dynamic>> _gateways = [];
  // Only the gateway account here (user, 2026-11-14: "Gateway only"): each
  // fee group's bank account -- and its Merchant / Settlement ID -- is set in
  // Setup -> Fee Master -> Fee Group.
  /// Paid at the gateway, no receipt: the office must act on these.
  List<Map<String, dynamic>> _attention = [];
  String? _busyOrder;

  // form
  int? _pgId; // null = new
  String _provider = kPgProviders.first.code;
  String _mode = 'TEST';
  String? _savedMode; // the mode on the server; null = not saved yet
  bool _hasSecret = false;
  final _name = TextEditingController();
  final Map<String, TextEditingController> _ctl = {};
  final Set<String> _shown = {}; // secret boxes shown in clear while typing

  TextEditingController _c(String k) => _ctl.putIfAbsent(k, () => TextEditingController());
  PgProvider get _prov => pgProvider(_provider) ?? kPgProviders.first;

  // For the status card.
  List<Map<String, dynamic>> _feeGroups = [], _banks = [];
  Map<int, Map<String, dynamic>> _bankMerchants = {};

  Map<String, dynamic>? get _savedGateway => _gateways.where((g) => g['pg_id'] == _pgId).firstOrNull;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<void> _load({int? select}) async {
    setState(() => _loading = true);
    try {
      final m = await PaymentGatewayService.list();
      if (!mounted) return;
      setState(() {
        _gateways = [for (final g in (m['gateways'] as List? ?? const [])) Map<String, dynamic>.from(g as Map)];
        _loading = false;
      });
      _loadAttention();
      _loadRoutes();
      final pick = select ?? (_gateways.isEmpty ? null : (_gateways.first['pg_id'] as num).toInt());
      if (pick != null) {
        _open(_gateways.firstWhere((g) => g['pg_id'] == pick, orElse: () => _gateways.first));
      } else {
        _new();
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _snack('Could not load the payment gateways. ${friendlyError(e)}', AppColors.error);
    }
  }

  /// The fee groups and banks behind the status card.
  Future<void> _loadRoutes() async {
    try {
      final insId = context.read<AuthProvider>().insId ?? 1;
      final r = await Future.wait<dynamic>([
        SupabaseService.fromSchema('feegroup')
            .select('fg_id, fgdesc, ban_id')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('fg_id', ascending: true),
        SupabaseService.getBanks(),
        PaymentGatewayService.bankMerchants(),
      ]);
      if (!mounted) return;
      setState(() {
        _feeGroups = List<Map<String, dynamic>>.from(r[0] as List);
        _banks = r[1] as List<Map<String, dynamic>>;
        _bankMerchants = r[2] as Map<int, Map<String, dynamic>>;
      });
    } catch (e) {
      debugPrint('payment gateways: fee group lookup failed: $e');
    }
  }

  /// Re-reads the status without touching what is typed in the form.
  Future<void> _refreshStatus() async {
    try {
      final m = await PaymentGatewayService.list();
      if (!mounted) return;
      setState(() {
        _gateways = [for (final g in (m['gateways'] as List? ?? const [])) Map<String, dynamic>.from(g as Map)];
      });
      await _loadRoutes();
    } catch (e) {
      debugPrint('payment gateways: status refresh failed: $e');
    }
  }

  Future<void> _loadAttention() async {
    try {
      final a = await OnlinePaymentService.attention();
      if (mounted) setState(() => _attention = a);
    } catch (e) {
      debugPrint('online_orders_attention: $e');
    }
  }

  Future<void> _retry(Map<String, dynamic> o) async {
    final id = '${o['order_id']}';
    setState(() => _busyOrder = id);
    try {
      final r = await OnlinePaymentService.retry(id);
      switch (r.status) {
        case 'C':
          _snack('Receipt raised: ${r.receiptNumbers}', AppColors.success);
        case 'X':
          _snack('Still not receipted: ${r.note}', AppColors.error);
        default:
          _snack('The gateway has not confirmed it yet. It is checked again automatically.', AppColors.warning);
      }
    } catch (e) {
      _snack(e is OnlinePaymentException ? e.message : friendlyError(e), AppColors.error);
    }
    if (mounted) setState(() => _busyOrder = null);
    _loadAttention();
  }

  /// An unconfirmed payment: ask the gateway now.
  Future<void> _checkNow(Map<String, dynamic> o) async {
    final id = '${o['order_id']}';
    setState(() => _busyOrder = id);
    try {
      final r = await OnlinePaymentService.status(id);
      switch (r.status) {
        case 'C':
          _snack('It was paid: receipt ${r.receiptNumbers}.', AppColors.success);
        case 'F' when r.moneyMayBeMoving:
          _snack('The gateway is still processing it. It is checked again automatically.', AppColors.warning);
        case 'F':
          _snack('Not paid: the gateway has no payment for it. It is closed.', AppColors.success);
        case 'X':
          _snack('Paid, but the receipt could not be raised: ${r.note}', AppColors.error);
        default:
          _snack('The gateway has not confirmed it yet. It is checked again automatically.', AppColors.warning);
      }
    } catch (e) {
      _snack(e is OnlinePaymentException ? e.message : friendlyError(e), AppColors.error);
    }
    if (mounted) setState(() => _busyOrder = null);
    _loadAttention();
  }

  Future<void> _markHandled(Map<String, dynamic> o) async {
    // An unconfirmed payment: ask the gateway first. Closing one whose money
    // is still moving is how a fee gets paid twice.
    if (o['status'] == 'I') {
      final id = '${o['order_id']}';
      setState(() => _busyOrder = id);
      OnlinePayResult? r;
      try {
        r = await OnlinePaymentService.status(id);
      } catch (_) {}
      if (mounted) setState(() => _busyOrder = null);
      if (r != null && r.status != 'I') {
        _snack('The gateway has answered for it (status ${r.status}); the list is updated.', AppColors.success);
        _loadAttention();
        return;
      }
      if (!mounted) return;
      final sure = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Payment Not Confirmed'),
          content: Text(r?.moneyMayBeMoving == true
              ? 'The gateway says this payment is STILL BEING PROCESSED: the payer\'s money may still arrive. '
                  'Close it only after checking it in the gateway\'s dashboard. If money arrives later anyway, it '
                  'comes back to this list.'
              : 'The gateway could not be asked just now. Close it only after checking it in the gateway\'s '
                  'dashboard. If money arrives later anyway, it comes back to this list.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('I Have Checked It')),
          ],
        ),
      );
      if (sure != true || !mounted) return;
    }
    final ctl = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Mark as Handled'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Use this only after the payment was dealt with by hand: refunded at the '
                'gateway, or receipted at the counter.', style: AppUI.muted),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              style: AppUI.fieldText(context),
              decoration: AppUI.field(context, 'What was done, e.g. Refunded on 03-11-2026'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Mark Handled')),
        ],
      ),
    );
    ctl.dispose();
    if (note == null || note.isEmpty) return;
    try {
      await OnlinePaymentService.markHandled('${o['order_id']}', note);
      _snack('Marked as handled.', AppColors.success);
    } catch (e) {
      _snack(friendlyError(e), AppColors.error);
    }
    _loadAttention();
  }

  Widget _attentionCard() => Container(
        padding: EdgeInsets.all(AppUI.cardPad),
        decoration: AppUI.card().copyWith(border: Border.all(color: AppColors.warning.withValues(alpha: 0.6))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppUI.cardHeader(
            icon: 'warning-2',
            title: 'Payments Needing Attention (${_attention.length})',
            subtitle: 'Paid at the gateway but not receipted, or not confirmed for over 30 minutes. '
                'Do not collect these again until they are settled.',
          ),
          SizedBox(height: 10.h),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: 200.h),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _attention.length,
              separatorBuilder: (_, __) => const Divider(height: 12),
              itemBuilder: (_, i) {
                final o = _attention[i];
                final id = '${o['order_id']}';
                final when = DateTime.tryParse('${o['createdat']}')?.toLocal();
                final busy = _busyOrder == id;
                final whenText = when == null
                    ? ''
                    : '${when.day.toString().padLeft(2, '0')}-${when.month.toString().padLeft(2, '0')}-${when.year}  ·  ';
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${switch ('${o['kind'] ?? 'FEE'}') {
                            'MISC' => 'Misc collection: ',
                            'ADVANCE' => 'Advance collection: ',
                            'ADVFEE' => 'Advance fee: ',
                            _ => '',
                          }}${o['stuname'] ?? 'Student ${o['stu_id']}'}  (${o['stuadmno'] ?? '-'})  ·  '
                          '${formatIndianNumber((o['amount'] as num?) ?? 0)}  ·  '
                          '${pgProvider('${o['provider']}')?.name ?? o['provider']}',
                          style: AppUI.body.copyWith(fontWeight: FontWeight.w600)),
                      Text('$whenText$id  ·  ${o['reference'] ?? ''}', style: AppUI.muted),
                      Text('${o['note'] ?? ''}', style: AppUI.muted.copyWith(color: AppColors.error)),
                    ]),
                  ),
                  if (o['status'] == 'I')
                    OutlinedButton(
                      onPressed: busy ? null : () => _checkNow(o),
                      child: busy
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Check Now'),
                    ),
                  if (o['can_retry'] == true)
                    OutlinedButton(
                      onPressed: busy ? null : () => _retry(o),
                      child: busy
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Retry Receipt'),
                    ),
                  SizedBox(width: 8.w),
                  TextButton(onPressed: busy ? null : () => _markHandled(o), child: const Text('Mark Handled')),
                ]);
              },
            ),
          ),
        ]),
      );

  void _new() {
    setState(() {
      _pgId = null;
      _provider = kPgProviders.first.code;
      _mode = 'TEST';
      _savedMode = null;
      _hasSecret = false;
      _name.text = '';
      for (final c in _ctl.values) {
        c.clear();
      }
      _shown.clear();
    });
  }

  void _open(Map<String, dynamic> g) {
    final cfg = Map<String, dynamic>.from((g['config'] as Map?) ?? const {});
    setState(() {
      _pgId = (g['pg_id'] as num).toInt();
      _provider = '${g['provider']}';
      _mode = '${g['mode']}';
      _savedMode = _mode;
      _hasSecret = g['has_secret'] == true;
      _name.text = '${g['name'] ?? ''}';
      for (final c in _ctl.values) {
        c.clear();
      }
      for (final f in _prov.publicFields) {
        _c(f.key).text = '${cfg[f.key] ?? ''}';
      }
      _shown.clear();
    });
  }

  /// Saves the form. Returns false when nothing was saved. [quiet]: no
  /// 'saved' message (Test Connection saves first and reports the test).
  Future<bool> _save({bool quiet = false}) async {
    // A school has one gateway, so it is simply called by the gateway's name.
    final name = _name.text.trim().isEmpty ? _prov.name : _name.text.trim();
    final config = <String, String>{
      for (final f in _prov.publicFields)
        if (_c(f.key).text.trim().isNotEmpty) f.key: _c(f.key).text.trim(),
    };
    for (final f in _prov.publicFields.where((f) => f.required)) {
      if (!config.containsKey(f.key)) return _warn('Enter the ${f.label}.');
    }
    // Razorpay keys say which mode they belong to; a mismatch makes the
    // counter show the wrong TEST/LIVE banner.
    if (_provider == 'RAZORPAY') {
      final k = config['key_id'] ?? '';
      if (_mode == 'LIVE' && k.startsWith('rzp_test_')) {
        return _warn('This is a test key (rzp_test_...). Choose Test (sandbox), or enter the live key.');
      }
      if (_mode == 'TEST' && k.startsWith('rzp_live_')) {
        return _warn('This is a live key (rzp_live_...). Choose Live, or enter the test key.');
      }
    }
    // Paytm's website name belongs to one system: WEBSTAGING is the test
    // system only. A Live order sent with it is refused when it is created.
    if (_provider == 'PAYTM') {
      final w = (config['website'] ?? '').toUpperCase();
      if (w.contains('.') || w.contains('/')) {
        return _warn('"${config['website']}" looks like a server address. Put it in Gateway Host; '
            'Website Name is a word such as DEFAULT.');
      }
      final hostTyped = (config['host'] ?? '').toLowerCase();
      if (hostTyped.isNotEmpty && !hostTyped.contains('paytm')) {
        return _warn('Gateway Host should be a Paytm server, e.g. securegw.paytm.in or secure.paytmpayments.com.');
      }
      if (_mode == 'LIVE' && w == 'WEBSTAGING') {
        return _warn('WEBSTAGING is Paytm\'s test website name. For Live, enter the website name from the Paytm '
            'dashboard (Developer Settings > API Keys, Production), usually DEFAULT.');
      }
      if (_mode == 'TEST' && w.isNotEmpty && w != 'WEBSTAGING') {
        return _warn('For Test (sandbox), Paytm\'s website name is WEBSTAGING.');
      }
    }
    final typed = {
      for (final f in _prov.secretFields)
        if (_c(f.key).text.trim().isNotEmpty) f.key: _c(f.key).text.trim(),
    };
    // Test and Live never share keys: keeping the old ones would only fail
    // when somebody pays.
    if (_pgId != null && _savedMode != null && _savedMode != _mode && typed.isEmpty) {
      final keys = _prov.secretFields.where((f) => f.required).map((f) => f.label).join(', ');
      return _warn('Test and Live use different keys. Enter the ${_mode == 'LIVE' ? 'Live' : 'Test'} $keys.');
    }
    // New gateway, or a different provider: every required secret is needed.
    final needAll = _pgId == null || !_hasSecret;
    if (needAll || typed.isNotEmpty) {
      for (final f in _prov.secretFields.where((f) => f.required)) {
        if (!typed.containsKey(f.key)) {
          return _warn(needAll ? 'Enter the ${f.label}.' : 'Enter the ${f.label} too: secrets are saved together.');
        }
      }
    }
    if (_mode == 'LIVE' && _savedMode != 'LIVE' && !await _confirmLive()) return false;
    // A new account, or one that changed mode, is tested straight away.
    final testAfter = _savedMode != _mode;
    setState(() => _saving = true);
    try {
      final id = await PaymentGatewayService.save(
        pgId: _pgId,
        provider: _provider,
        name: name,
        mode: _mode,
        config: config,
        secret: typed.isEmpty ? null : typed,
        isDefault: true, // the school has one gateway
      );
      if (!quiet) _snack('Payment gateway saved.', AppColors.success);
      await _load(select: id);
      if (!quiet && testAfter) await _runTest();
      return true;
    } catch (e) {
      _snack('Could not save the gateway. ${friendlyError(e)}', AppColors.error);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _warn(String m) {
    _snack(m, AppColors.warning);
    return false;
  }

  Future<bool> _confirmLive() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go Live?'),
        content: SizedBox(
          width: 440,
          child: Text('Parents and the fee counter will pay real money through this ${_prov.name} account. '
              'The connection is tested as soon as it is saved.', style: AppUI.body),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Go Live')),
        ],
      ),
    );
    return ok == true;
  }

  /// Saves what is on screen first, so the test is of these values and not of
  /// the last saved ones.
  Future<void> _test() async {
    if (!await _save(quiet: true)) return;
    await _runTest();
  }

  /// Asks the gateway, keeps the answer for the status card and says it.
  Future<void> _runTest() async {
    final id = _pgId;
    if (id == null || !mounted) return;
    setState(() => _testing = true);
    final r = await PaymentGatewayService.test(id);
    try {
      await PaymentGatewayService.noteTest(id, r.ok, r.message);
    } catch (e) {
      debugPrint('payment gateways: could not keep the test result: $e');
    }
    if (mounted) setState(() => _testing = false);
    _snack(r.ok ? 'Connected: ${r.message}' : r.message, r.ok ? AppColors.success : AppColors.error);
    await _refreshStatus();
  }

  /// One step of the status card.
  Widget _step(bool done, String title, String sub, {bool failed = false}) => Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
            done ? Icons.check_circle : (failed ? Icons.error : Icons.radio_button_unchecked),
            size: 18.sp,
            color: done ? AppColors.primary : (failed ? AppColors.error : AppColors.textLight),
          ),
          SizedBox(width: 8.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppUI.label),
              Text(sub, style: AppUI.muted.copyWith(color: failed ? AppColors.error : null)),
            ]),
          ),
        ]),
      );

  /// Is online payment ready, and where does each fee group's money go?
  Widget _statusCard() {
    final g = _savedGateway;
    final saved = g != null && g['has_secret'] == true;
    final tested = g?['last_test_ok'] == true;
    final testFailed = g?['last_test_ok'] == false;
    final testedOn = DateTime.tryParse('${g?['last_test_at'] ?? ''}')?.toLocal();
    final isLive = '${g?['mode'] ?? ''}' == 'LIVE';
    Map<String, dynamic>? bankOf(dynamic id) => _banks.where((b) => '${b['ban_id']}' == '$id').firstOrNull;
    final routes = [
      for (final f in _feeGroups)
        (f, bankOf(f['ban_id']), onlineRouteFor(gateway: g, bank: bankOf(f['ban_id']), bankMerchants: _bankMerchants)),
    ];
    final notReady = routes.where((r) => !r.$3.ready).length;
    final mapped = routes.isNotEmpty && notReady == 0;
    final ready = saved && tested && mapped;
    String bankText(Map<String, dynamic>? b) {
      if (b == null) return 'No bank account';
      final acc = '${b['banaccno'] ?? ''}'.trim();
      return '${'${b['banname'] ?? ''}'.trim()}${acc.isEmpty ? '' : '  ·  ${pgMaskId(acc)}'}';
    }

    return Container(
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Online payment status', style: AppUI.cardTitle)),
          AppUI.chip(
            !ready ? 'Not ready yet' : (isLive ? 'Ready for online payments' : 'Ready in Test mode: no real money'),
            !ready ? AppStatus.warning : (isLive ? AppStatus.success : AppStatus.info),
          ),
        ]),
        SizedBox(height: 12.h),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _step(saved, 'Gateway saved', saved ? '${_prov.name}, ${isLive ? 'Live' : 'Test'} mode' : 'Enter the account and keys below'),
          SizedBox(width: 12.w),
          _step(
            tested,
            'Connection tested',
            tested
                ? 'Passed on ${formatDmy(testedOn)}'
                : testFailed
                    ? 'Failed. Check the keys and test again'
                    : 'Press Test Connection below',
            failed: testFailed,
          ),
          SizedBox(width: 12.w),
          _step(
            mapped,
            'Fee groups ready',
            routes.isEmpty
                ? 'Add them in Setup → Fee Master → Fee Group'
                : mapped
                    ? 'All ${routes.length} can be paid online'
                    : '$notReady of ${routes.length} need attention in Setup → Fee Master → Fee Group',
          ),
        ]),
        if (routes.isNotEmpty) ...[
          SizedBox(height: 12.h),
          Container(
            color: AppColors.tableHeadBg,
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 7.h),
            child: Row(children: [
              Expanded(child: Text('FEE GROUP', style: AppUI.caps)),
              Expanded(child: Text('BANK ACCOUNT', style: AppUI.caps)),
              Expanded(child: Text('ONLINE MONEY GOES TO', style: AppUI.caps)),
            ]),
          ),
          for (final r in routes)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
              child: Row(children: [
                Expanded(child: Text('${r.$1['fgdesc'] ?? ''}'.trim(), style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                Expanded(child: Text(bankText(r.$2), style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                Expanded(child: onlineRouteChip(r.$3)),
              ]),
            ),
        ],
      ]),
    );
  }

  Future<void> _delete() async {
    final id = _pgId;
    if (id == null) return;
    // Deleting stops every online payment of the school, so it takes typing
    // the gateway's name, not one click. The server also refuses while a
    // payment through it is still being confirmed.
    final name = _gateways.where((g) => g['pg_id'] == id).map((g) => '${g['name']}'.trim()).firstOrNull ??
        _name.text.trim();
    final typed = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Delete $name?'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  'Online fee payments stop at once, at the counter and in the parent app, until a gateway is set up '
                  'again. Its saved keys are destroyed. Payments already received are not affected.',
                  style: AppUI.body),
              const SizedBox(height: 14),
              Text('Type the gateway name to confirm: $name', style: AppUI.label),
              const SizedBox(height: 6),
              TextField(
                controller: typed,
                autofocus: true,
                style: AppUI.fieldText(context),
                decoration: AppUI.field(context, name),
                onChanged: (_) => setD(() {}),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
              onPressed: typed.text.trim().toUpperCase() == name.toUpperCase() ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Delete Gateway'),
            ),
          ],
        ),
      ),
    );
    typed.dispose();
    if (ok != true) return;
    try {
      await PaymentGatewayService.delete(id);
      _snack('Payment gateway deleted.', AppColors.success);
      await _load();
    } catch (e) {
      _snack('Could not delete the gateway. ${friendlyError(e)}', AppColors.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_attention.isNotEmpty) ...[
        _attentionCard(),
        SizedBox(height: AppUI.gap),
      ],
      Expanded(child: _formCard()),
    ]);
  }

  /// Where this gateway sends its server-to-server payment notices.
  String _webhookUrl(int pgId) => '${SupabaseConfig.url}/functions/v1/pay-webhook?pg=$pgId';

  Widget _formCard() {
    final prov = _prov;
    Widget field(PgField f) {
      final secret = f.secret;
      final hint = secret && _hasSecret && _pgId != null ? 'Saved ••••••  (type to replace)' : f.hint;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppUI.fieldLabel(f.label, required: f.required && !(secret && _hasSecret), optional: !f.required),
        TextField(
          controller: _c(f.key),
          obscureText: secret && !_shown.contains(f.key),
          style: AppUI.fieldText(context),
          decoration: AppUI.field(context, hint).copyWith(
            suffixIcon: secret
                ? IconButton(
                    tooltip: _shown.contains(f.key) ? 'Hide' : 'Show',
                    icon: Icon(_shown.contains(f.key) ? Icons.visibility_off : Icons.visibility, size: 18),
                    onPressed: () => setState(() => _shown.contains(f.key) ? _shown.remove(f.key) : _shown.add(f.key)),
                  )
                : null,
          ),
        ),
      ]);
    }

    Widget grid(List<PgField> fs) => LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth > 700 ? 2 : 1;
          final w = (c.maxWidth - (cols - 1) * 14.w) / cols;
          return Wrap(spacing: 14.w, runSpacing: 12.h, children: [for (final f in fs) SizedBox(width: w, child: field(f))]);
        });

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: ListView(
            // Room on the right for the scrollbar, so it never sits over the
            // fields (user, 2026-11-13).
            padding: EdgeInsets.only(right: 16.w),
            children: [
        _statusCard(),
        SizedBox(height: 18.h),
        AppUI.cardHeader(
          icon: 'setting-2',
          title: _pgId == null ? 'New Gateway' : _name.text.trim().isEmpty ? 'Gateway' : _name.text.trim(),
          subtitle: prov.help,
          trailing: [
            if (_pgId != null)
              TextButton.icon(
                onPressed: _saving ? null : _delete,
                icon: const AppIcon('trash', size: 16, color: AppColors.error),
                label: Text('Delete', style: TextStyle(color: AppColors.error)),
              ),
          ],
        ),
        SizedBox(height: 16.h),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppUI.fieldLabel('Gateway', required: true),
              DropdownButtonFormField<String>(
                initialValue: _provider,
                isExpanded: true,
                decoration: AppUI.field(context, ''),
                items: [for (final p in kPgProviders) DropdownMenuItem(value: p.code, child: Text(p.name))],
                // One gateway per school, and its type is fixed once saved:
                // to use another, delete this one first.
                onChanged: _pgId != null ? null : (v) => setState(() {
                  if (v == null || v == _provider) return;
                  _provider = v;
                  _hasSecret = false; // another provider's secret does not carry over
                  for (final c in _ctl.values) {
                    c.clear();
                  }
                }),
              ),
              if (_pgId != null)
                Padding(
                  padding: EdgeInsets.only(top: 4.h),
                  child: Text('One gateway per school. To use another, delete this one first.', style: AppUI.muted),
                ),
            ]),
          ),
          SizedBox(width: 14.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppUI.fieldLabel('Mode', required: true),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'TEST', label: Text('Test (sandbox)')),
                  ButtonSegment(value: 'LIVE', label: Text('Live')),
                ],
                selected: {_mode},
                onSelectionChanged: (v) => setState(() => _mode = v.first),
              ),
            ]),
          ),
        ]),
        SizedBox(height: 16.h),
        AppUI.sectionLabel('Account'),
        grid(prov.publicFields),
        SizedBox(height: 16.h),
        AppUI.sectionLabel('Secret keys'),
        Text('Stored encrypted. They are never shown again; leave a box empty to keep what is saved.', style: AppUI.muted),
        SizedBox(height: 8.h),
        grid(prov.secretFields),
        if (_pgId != null) ...[
          SizedBox(height: 16.h),
          AppUI.sectionLabel('Webhook URL'),
          Text('Enter this in the ${prov.name} dashboard as the payment webhook / notify URL. '
              'Payments are confirmed even if the payer closes the window.', style: AppUI.muted),
          SizedBox(height: 8.h),
          Row(children: [
            Expanded(child: SelectableText(_webhookUrl(_pgId!), style: AppUI.body)),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _webhookUrl(_pgId!)));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Webhook URL copied.')));
              },
            ),
          ]),
        ],
            ],
          ),
        ),
        // The actions stay in view below the scrolling fields -- they used to
        // sit at the end of the list, cut off at the bottom of the card.
        const Divider(height: 1, color: AppColors.divider),
        SizedBox(height: 12.h),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          OutlinedButton.icon(
            onPressed: _testing || _saving ? null : _test,
            icon: _testing
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_tethering, size: 16),
            label: const Text('Test Connection'),
          ),
          SizedBox(width: 10.w),
          ElevatedButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: const Text('Save'),
          ),
        ]),
        SizedBox(height: 8.h),
        Align(
          alignment: Alignment.centerRight,
          child: Text("Each fee group's bank account is set in Setup → Fee Master → Fee Group.", style: AppUI.muted),
        ),
      ]),
    );
  }

}
