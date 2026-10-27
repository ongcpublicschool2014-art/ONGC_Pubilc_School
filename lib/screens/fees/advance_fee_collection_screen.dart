import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../services/paytm_service.dart';
import '../../services/pending_collection_sweep.dart';
import '../../services/supabase_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/class_sort.dart';
import '../../utils/friendly_error.dart';
import '../../utils/receipt_pdf.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';
import '../../widgets/paytm_checkout_dialog.dart';
import '../../widgets/receipt_widget.dart';
import 'advance_fee_definition_dialog.dart';

/// Advance Fee Collection (school) -- next academic year's fees, collected now.
///
/// What a student owes for next year lives in <year schema>.stuadvdemand,
/// built by generate_student_advance from the Advance Fee Definition through
/// Section Matching (a pre-admission is already in next year's section). The
/// cashier ticks the lines being paid (a smaller amount is a part payment) and
/// collect_student_advance issues ONE admission-advance receipt for them --
/// same receipt series, bank, reconciliation, void and Advance Adjustment as
/// every other advance -- and moves the money onto the lines. Voiding the
/// receipt hands it back (trigger on advance_detail).
class AdvanceFeeCollectionScreen extends StatefulWidget {
  const AdvanceFeeCollectionScreen({super.key});

  @override
  State<AdvanceFeeCollectionScreen> createState() => _AdvanceFeeCollectionScreenState();
}

class _PayLine {
  final Map<String, dynamic> row;
  final TextEditingController pay = TextEditingController();
  bool get ticked => (double.tryParse(pay.text.trim()) ?? 0) > 0;
  _PayLine(this.row);
}

class _AdvanceFeeCollectionScreenState extends State<AdvanceFeeCollectionScreen> {
  // masters
  List<Map<String, dynamic>> _students = [];
  Map<int, String> _className = {};
  Map<int, String> _courseName = {};
  List<Map<String, dynamic>> _courseList = []; // in standard order
  int? _fCour, _fCla; // Standard / Section filters on the search
  Map<int, (int, int)> _nextOf = {}; // current cla_id -> (next cla_id, next cour_id)
  List<Map<String, dynamic>> _classes = [];
  String _nextYear = '';
  Map<String, String> _settings = const {};
  String _insName = '', _insAddress = '-';
  String? _insLogo, _insMobile, _insEmail;

  // the student on screen
  Map<String, dynamic>? _student;
  final List<_PayLine> _lines = [];
  List<Map<String, dynamic>> _receipts = []; // {adv_id, advno, advdate, total, mode, active, lines:[{term, feetype, amount}]}

  // payment
  String? _mode;
  final _refCtrl = TextEditingController();
  final _bankCtrl = TextEditingController();
  final _remarksCtrl = TextEditingController();
  DateTime? _refDate;

  bool _loading = true, _busy = false;
  int _raised = 0; // the student's raised demands, paid ones included
  Map<int, double> _due = {}; // stu_id -> advance balance, for the search tags

  static const _modes = ['Cash', 'QR/UPI', 'Paytm', 'Cheque', 'DD'];

  // Paytm: OUR order id (also the pending-collection intent's key) and
  // Paytm's transaction id once the payment is confirmed.
  String? _payOrderId, _paytmTxnId;

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
    // As Fee Collection / Advance Collection: a Paytm payment confirmed after
    // a counter closed is receipted on the next open.
    WidgetsBinding.instance.addPostFrameCallback((_) => _sweepPending());
  }

  Future<void> _sweepPending() async {
    try {
      final auth = context.read<AuthProvider>();
      final insId = auth.insId;
      if (insId == null) return;
      final res = await PendingCollectionSweep.run(insId: insId, sessionToken: auth.sessionToken);
      if (res.receipted > 0) {
        _snack('${res.receipted} Paytm payment(s) confirmed after the counter closed have been receipted.', AppColors.success);
      }
    } catch (e) {
      debugPrint('advance fee sweep: $e');
    }
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.pay.dispose();
    }
    _refCtrl.dispose();
    _bankCtrl.dispose();
    _remarksCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: c));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, courname, cla_id, cour_id, preadmission, stumobile, stuphoto')
            .eq('ins_id', _insId)
            .eq('activestatus', 1)
            .order('stuadmno')),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid, classtype').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('classmatch').select('curclassid, nextclassid, nextcourseid').eq('activestatus', 1),
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('stuadvdemand').select('stu_id, balance').eq('activestatus', 1)),
        SupabaseService.getYears(_insId),
        SupabaseService.getInstitutionSettings(_insId),
        SupabaseService.getInstitutionInfo(_insId),
      ]);
      if (!mounted) return;
      final years = r[5] as List;
      final cur = years.isNotEmpty ? '${(years.first as Map)['yrlabel'] ?? ''}' : '';
      final p = cur.split('-').map(int.tryParse).toList();
      final info = r[7] as ({String? name, String? logo, String? address, String? mobile, String? email});
      setState(() {
        _students = List<Map<String, dynamic>>.from((r[0] as List).cast<Map<String, dynamic>>());
        _classes = List<Map<String, dynamic>>.from((r[1] as List).cast<Map<String, dynamic>>())
          ..sort((a, b) => classCompare('${a['claname']}', '${b['claname']}'));
        _className = {for (final c in _classes) _id(c['cla_id'])!: '${c['claname']}'};
        _courseList = List<Map<String, dynamic>>.from((r[2] as List).cast<Map<String, dynamic>>())
          ..sort((a, b) => (_id(a['ordid']) ?? 9999).compareTo(_id(b['ordid']) ?? 9999));
        _courseName = {for (final c in _courseList) _id(c['cour_id'])!: '${c['courname']}'};
        _nextOf = {
          for (final m in (r[3] as List)) _id(m['curclassid'])!: (_id(m['nextclassid'])!, _id(m['nextcourseid'])!),
        };
        _nextYear = p.length == 2 && p[0] != null && p[1] != null ? '${p[0]! + 1}-${p[1]! + 1}' : '';
        _settings = r[6] as Map<String, String>;
        _due = {};
        for (final d in (r[4] as List)) {
          final id = _id(d['stu_id']);
          if (id != null) _due[id] = (_due[id] ?? 0) + _num(d['balance']);
        }
        _insName = info.name ?? 'Institution';
        _insAddress = info.address ?? '-';
        _insLogo = info.logo;
        _insMobile = info.mobile;
        _insEmail = info.email;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Could not load students and classes. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  /// Next year's (section, standard) of [s]: its own section for a
  /// pre-admission, else what Section Matching says. The section is null when
  /// the next standard has no section of that letter yet -- its standard-wise
  /// advance fees still apply (as the server's school_next_section).
  (int?, int)? _applicable(Map<String, dynamic> s) {
    final cla = _id(s['cla_id']);
    if (cla == null) return null;
    if ((_id(s['preadmission']) ?? 0) == 1) return (cla, _id(s['cour_id']) ?? 0);
    return _nextOf[cla] ?? _nextByOrder(cla);
  }

  /// No Section Matching for [cla]: the next standard in order and its
  /// same-letter section (LKG A -> UKG A) -- the server's school_next_section
  /// does the same. None for a non-promotional or the last standard.
  (int?, int)? _nextByOrder(int cla) {
    final c = _classes.firstWhere((x) => _id(x['cla_id']) == cla, orElse: () => const {});
    final cour = _id(c['cour_id']);
    final i = _courseList.indexWhere((x) => _id(x['cour_id']) == cour);
    if (i < 0 || i + 1 >= _courseList.length) return null;
    if ('${_courseList[i]['classtype'] ?? 'PROMOTIONAL'}'.toUpperCase() != 'PROMOTIONAL') return null;
    String suffix(String name, String std) =>
        (name.toUpperCase().startsWith(std.toUpperCase()) ? name.substring(std.length) : name).trim().toUpperCase();
    final want = suffix('${c['claname']}', '${_courseList[i]['courname']}');
    final next = _courseList[i + 1];
    for (final n in _classes.where((x) => _id(x['cour_id']) == _id(next['cour_id']))) {
      if (suffix('${n['claname']}', '${next['courname']}') == want) return (_id(n['cla_id'])!, _id(next['cour_id'])!);
    }
    return (null, _id(next['cour_id'])!);
  }

  /// "UKG A (UKG)", or "III (section not set yet)" when only the standard is known.
  String _appName((int?, int) app) => app.$1 == null
      ? schoolTerm('${_courseName[app.$2] ?? '-'} (class not set yet)')
      : '${_className[app.$1] ?? '-'} (${_courseName[app.$2] ?? '-'})';

  Future<void> _selectStudent(Map<String, dynamic> s) async {
    setState(() {
      _student = s;
      _busy = true;
    });
    await _loadStudentLines();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _loadStudentLines() async {
    final s = _student;
    if (s == null) return;
    try {
      final rows = List<Map<String, dynamic>>.from((await SupabaseService.fromSchema('stuadvdemand')
              .select('*')
              .eq('stu_id', s['stu_id'])
              .eq('activestatus', 1)
              .order('afterm')
              .order('affeetype') as List)
          .cast<Map<String, dynamic>>());
      // Only RAISED demands are shown, as on Fee Collection: they come from
      // Advance Fee Definition -> Save, or the student's Fee Definition.
      // Receipts that paid any of these lines.
      final ids = rows.map((r) => _id(r['sad_id'])).whereType<int>().toList();
      var receipts = <Map<String, dynamic>>[];
      if (ids.isNotEmpty) {
        final det = List<Map<String, dynamic>>.from((await SupabaseService.fromSchema('advance_detail')
                .select('adv_id, sad_id, feetype, amount, activestatus')
                .inFilter('sad_id', ids) as List)
            .cast<Map<String, dynamic>>());
        final advIds = det.map((d) => _id(d['adv_id'])).whereType<int>().toSet().toList();
        if (advIds.isNotEmpty) {
          final heads = List<Map<String, dynamic>>.from((await SupabaseService.fromSchema('advance_collection')
                  .select('adv_id, advno, advdate, transtotalamount, paymethod, payreference, activestatus, recon_status')
                  .inFilter('adv_id', advIds)
                  .order('adv_id', ascending: false) as List)
              .cast<Map<String, dynamic>>());
          final termOf = {for (final r in rows) _id(r['sad_id']): '${r['afterm']}'};
          receipts = [
            for (final h in heads)
              {
                ...h,
                'lines': [
                  for (final d in det.where((d) => _id(d['adv_id']) == _id(h['adv_id'])))
                    {'term': termOf[_id(d['sad_id'])] ?? '', 'feetype': '${d['feetype']}', 'amount': _num(d['amount'])},
                ],
              },
          ];
        }
      }
      if (!mounted) return;
      setState(() {
        for (final l in _lines) {
          l.pay.dispose();
        }
        // PENDING demands only, as Fee Collection: a fully paid one is
        // history and shows under Receipts.
        _raised = rows.length;
        _lines
          ..clear()
          ..addAll(rows.where((r) => _num(r['balance']) > 0).map(_PayLine.new));
        _receipts = receipts;
      });
    } catch (e) {
      _snack('Could not load the advance fees. ${friendlyError(e)}', AppColors.error);
    }
  }

  double get _total => _lines.fold(0.0, (s, l) => s + (double.tryParse(l.pay.text.trim()) ?? 0));

  static String _dbMode(String? m) => switch (m) {
        'QR/UPI' => 'upi',
        'Cheque' => 'cheque',
        'DD' => 'dd',
        'Paytm' => 'Online Transfer',
        _ => 'cash',
      };

  /// Footer "Save & Collect" / "Proceed to Pay" -- as Fee Collection: cash
  /// asks for the tendered amount (and shows the change), every other mode
  /// for its reference details; then the receipt is issued.
  Future<void> _onPay() async {
    final s = _student;
    if (s == null || _mode == null) return;
    final pay = _lines.where((l) => l.ticked).toList();
    if (pay.isEmpty) return _snack('Tick or enter an amount for at least one fee line.', AppColors.warning);
    for (final l in pay) {
      final bal = _num(l.row['balance']);
      if ((double.tryParse(l.pay.text.trim()) ?? 0) > bal) {
        return _snack('${l.row['afterm']} ${l.row['affeetype']}: the amount is more than the balance of ₹${bal.toStringAsFixed(2)}.', AppColors.error);
      }
    }
    final total = _total;
    double? tender;
    if (_mode == 'Cash') {
      tender = await _cashDialog(total);
      if (tender == null) return;
    } else if (_mode == 'Paytm') {
      // Paytm takes the money BEFORE the receipt exists; nothing is saved
      // unless Paytm confirms it.
      if (!await _payWithPaytm(pay, total)) return;
    } else {
      if (await _detailsDialog(total) != true) return;
    }
    await _collect(pay, total, tender ?? total);
  }

  /// The receipt header collect_student_advance (and a recovered Paytm
  /// intent) is saved with. stuadv marks it as an ADVANCE FEE payment, so the
  /// recovery sweep raises it through collect_student_advance as well.
  Map<String, dynamic> _collectHeader(double tender) {
    final s = _student!;
    final cash = _mode == 'Cash';
    final paytm = _mode == 'Paytm';
    return {
      'stu_id': s['stu_id'],
      'stuadmno': s['stuadmno'],
      'stuname': s['stuname'],
      'stuclass': s['stuclass'],
      'courname': s['courname'],
      'paymethod': _dbMode(_mode),
      'payreference': paytm ? (_paytmTxnId ?? _payOrderId) : (cash ? null : _refCtrl.text.trim()),
      'payorderid': paytm ? _payOrderId : null,
      'paytm_txnid': paytm ? _paytmTxnId : null,
      'paychequeno': (_mode == 'Cheque' || _mode == 'DD') ? _refCtrl.text.trim() : null,
      'paychequedate': cash ? null : (_refDate ?? DateTime.now()).toIso8601String().split('T').first,
      'paybankname': paytm ? 'PAYTM' : (cash ? null : _bankCtrl.text.trim()),
      'tender_amount': tender,
      'remarks': _remarksCtrl.text.trim().isEmpty ? 'Advance fee $_nextYear' : _remarksCtrl.text.trim(),
      'createdby': context.read<AuthProvider>().userName,
      'stuadv': true,
    };
  }

  List<Map<String, dynamic>> _collectLines(List<_PayLine> pay) => [
        for (final l in pay) {'sad_id': l.row['sad_id'], 'af_id': l.row['af_id'], 'amount': double.tryParse(l.pay.text.trim()) ?? 0},
      ];

  /// Paytm checkout, as Advance Collection: route to the fee group's
  /// merchant, record the intent BEFORE contacting Paytm (so a capture that
  /// lands after this window closes is still receipted by the sweep), then
  /// take the payment. True only when Paytm CONFIRMS the money.
  Future<bool> _payWithPaytm(List<_PayLine> pay, double amount) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    final feeTypes = [for (final l in pay) '${l.row['affeetype']}'];
    final banId = !await SupabaseService.feeGroupSettlementEnabled(insId)
        ? null
        : await SupabaseService.resolveRoutingBanId(insId: insId, advType: 'A', feeTypes: feeTypes);
    final routing = await SupabaseService.resolvePaytmRouting(insId: insId, banId: banId);
    if (!routing.ok) {
      _snack(routing.error!, AppColors.error);
      return false;
    }
    _paytmTxnId = null;
    final orderId = 'ADF${insId}T${DateTime.now().millisecondsSinceEpoch}';
    _payOrderId = orderId;
    try {
      await SupabaseService.client.rpc('record_pending_collection', params: {
        'p_order_id': orderId,
        'p_ins_id': insId,
        'p_kind': 'A',
        'p_amount': amount,
        'p_header': _collectHeader(amount),
        'p_lines': _collectLines(pay),
        'p_created_by': auth.userName ?? '',
        'p_ban_id': banId,
      });
    } catch (e) {
      debugPrint('record_pending_collection failed for $orderId: $e');
    }
    try {
      final order = await PaytmService.createOrder(
        payId: PaytmService.kNoPaymentRow,
        amount: amount,
        custId: 'STU-${_student?['stuadmno'] ?? insId}',
        orderId: orderId,
        mid: routing.mid,
      );
      if (!mounted) return false;
      _payOrderId = order.orderId;
      final payMid = routing.mid ?? '';
      final midTail = payMid.length > 6 ? payMid.substring(payMid.length - 6) : payMid;
      final status = await showPaytmCheckout(
        context,
        order: order,
        amount: amount,
        studentName: _student?['stuname']?.toString() ?? '',
        merchantName: '${auth.insName ?? _insName} - ADVANCE FEE $_nextYear',
        settlingTo: midTail.isEmpty ? '' : 'merchant …$midTail',
      );
      if (status == 'C') {
        try {
          final st = await PaytmService.verifyPayment(order.orderId, mid: order.mid);
          _paytmTxnId = st.paymentId;
        } catch (e) {
          debugPrint('Paytm txnid lookup failed: $e');
        }
        return true;
      }
      final why = PaytmService.lastGatewayMessage;
      _snack(
          '${status == 'F' ? 'Payment failed or was cancelled' : 'Payment not confirmed'}'
          '${why.isEmpty ? '' : ' — $why'} — nothing was saved.',
          AppColors.warning);
      return false;
    } catch (e) {
      _snack('Could not start the Paytm payment. ${e.toString().replaceFirst('Exception: ', '')}', AppColors.error);
      return false;
    }
  }

  Future<double?> _cashDialog(double net) {
    final ctrl = TextEditingController(text: net.toStringAsFixed(0));
    return showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final tender = double.tryParse(ctrl.text.trim()) ?? 0;
        final short = tender < net;
        Widget row(String l, String v, {bool hi = false}) => Padding(
              padding: EdgeInsets.symmetric(vertical: 6.h),
              child: Row(children: [
                Text(l, style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                const Spacer(),
                Text(v, style: TextStyle(fontSize: hi ? 16.sp : 14.sp, fontWeight: FontWeight.w700, color: hi ? AppColors.accent : AppColors.textPrimary)),
              ]),
            );
        return Dialog(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 420.w),
            child: Padding(
              padding: EdgeInsets.all(22.w),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Cash Payment', style: AppUI.cardTitle),
                SizedBox(height: 14.h),
                row('Net Amount', '₹${net.toStringAsFixed(2)}', hi: true),
                SizedBox(height: 8.h),
                AppUI.fieldLabel('Cash Received', required: true),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
                  style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                  decoration: AppUI.field(context, ''),
                  onChanged: (_) => setLocal(() {}),
                ),
                if (short)
                  Padding(
                    padding: EdgeInsets.only(top: 6.h),
                    child: Text('Cash received cannot be less than the net amount.', style: TextStyle(fontSize: 12.sp, color: AppColors.error)),
                  ),
                SizedBox(height: 8.h),
                row('Change to Return', '₹${(short ? 0 : tender - net).toStringAsFixed(2)}'),
                SizedBox(height: 18.h),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  AppUI.requiredNote(),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  SizedBox(width: 8.w),
                  ElevatedButton(
                    onPressed: short ? null : () => Navigator.pop(ctx, tender),
                    child: const Text('Confirm'),
                  ),
                ]),
              ]),
            ),
          ),
        );
      }),
    ).whenComplete(ctrl.dispose);
  }

  Future<bool?> _detailsDialog(double net) {
    final upi = _mode == 'QR/UPI';
    InputDecoration dec(String hint, {bool filled = false}) => AppUI.field(context, hint, filled: filled);
    Widget label(String t) => AppUI.fieldLabel(t);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final ok = _refCtrl.text.trim().isNotEmpty;
        return Dialog(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 470.w),
            child: Padding(
              padding: EdgeInsets.all(22.w),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Text('${_mode!} Payment Details', style: AppUI.cardTitle),
                  const Spacer(),
                  IconButton(onPressed: () => Navigator.pop(ctx, false), icon: const Icon(Icons.close, size: 20)),
                ]),
                SizedBox(height: 6.h),
                Text('Student: ${_student?['stuname'] ?? ''}', style: AppUI.muted),
                Text('Lines selected: ${_lines.where((l) => l.ticked).length}', style: AppUI.muted),
                SizedBox(height: 4.h),
                Text('Total: ₹${net.toStringAsFixed(2)}', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.accent)),
                SizedBox(height: 16.h),
                if (upi) ...[
                  label('UPI Transaction ID *'),
                  TextField(controller: _refCtrl, autofocus: true, decoration: dec('Enter UPI transaction ID', filled: ok), onChanged: (_) => setLocal(() {})),
                ] else ...[
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        label('${_mode!} No *'),
                        TextField(controller: _refCtrl, autofocus: true, decoration: dec('Enter ${_mode == 'DD' ? 'DD' : 'cheque'} number', filled: ok), onChanged: (_) => setLocal(() {})),
                      ]),
                    ),
                    SizedBox(width: 12.w),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        label('${_mode!} Date'),
                        InkWell(
                          onTap: () async {
                            final now = DateTime.now();
                            final d = await showDatePicker(context: ctx, initialDate: _refDate ?? now, firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 1));
                            if (d != null) setLocal(() => _refDate = d);
                          },
                          child: InputDecorator(
                            decoration: dec('', filled: _refDate != null),
                            child: Text(_refDate == null ? 'Today (select to change)' : formatDmy(_refDate),
                                style: AppUI.fieldText(context, filled: _refDate != null)),
                          ),
                        ),
                      ]),
                    ),
                  ]),
                  SizedBox(height: 12.h),
                  label('Bank Name'),
                  TextField(controller: _bankCtrl, decoration: dec('Enter bank name', filled: _bankCtrl.text.trim().isNotEmpty), onChanged: (_) => setLocal(() {})),
                ],
                SizedBox(height: 20.h),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  AppUI.requiredNote(),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  SizedBox(width: 10.w),
                  ElevatedButton(
                    onPressed: ok ? () => Navigator.pop(ctx, true) : null,
                    child: const Text('Save'),
                  ),
                ]),
              ]),
            ),
          ),
        );
      }),
    );
  }

  Future<void> _collect(List<_PayLine> pay, double total, double tender) async {
    final paytm = _mode == 'Paytm';
    setState(() => _busy = true);
    try {
      // A Paytm payment is CLAIMED first: the recovery sweep may be raising
      // this same receipt from its intent, and only one writer may win.
      if (paytm && _payOrderId != null) {
        final claim = await SupabaseService.client
            .rpc('claim_pending_collection', params: {'p_order_id': _payOrderId, 'p_by': 'COUNTER'});
        if (!(claim is List && claim.isNotEmpty)) {
          _snack('This Paytm payment has already been receipted automatically -- see Receipts.', AppColors.warning);
          await _loadStudentLines();
          return;
        }
      }
      final res = await SupabaseService.client.rpc('collect_student_advance', params: {
        'p_token': SupabaseService.sessionToken,
        'p_header': _collectHeader(tender),
        'p_lines': _collectLines(pay),
      });
      final m = res is Map ? res : const {};
      if (paytm && _payOrderId != null) {
        try {
          await SupabaseService.client.rpc('settle_pending_collection',
              params: {'p_order_id': _payOrderId, 'p_status': 'C', 'p_receipt_no': '${m['advno'] ?? ''}'});
        } catch (e) {
          debugPrint('settle_pending_collection failed: $e');
        }
      }
      final receiptLines = [
        for (final l in pay)
          {'term': '${l.row['afterm']}', 'feetype': '${l.row['affeetype']}', 'amount': double.tryParse(l.pay.text.trim()) ?? 0},
      ];
      final mode = _mode!;
      _refCtrl.clear();
      _bankCtrl.clear();
      _remarksCtrl.clear();
      _refDate = null;
      if (mounted) {
        _showSuccess(
          advno: '${m['advno'] ?? ''}',
          total: total,
          mode: mode,
          onDownload: () => _showReceipt(
            advno: '${m['advno'] ?? ''}',
            date: DateTime.now(),
            lines: receiptLines,
            mode: mode,
            fgId: _id(m['fg_id']),
            recon: '${m['recon_status'] ?? 'R'}',
          ),
        );
      }
    } catch (e) {
      _snack('Could not collect the advance fee. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _void(Map<String, dynamic> rec) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancel Receipt ${rec['advno']}'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('The ₹${_num(rec['transtotalamount']).toStringAsFixed(2)} goes back onto the student\'s advance fee balance.',
                style: AppUI.muted),
            SizedBox(height: 12.h),
            TextField(controller: reasonCtrl, style: AppUI.fieldText(context), decoration: AppUI.field(context, 'Enter reason for cancelling', label: 'Reason *')),
            SizedBox(height: 10.h),
            Align(alignment: Alignment.centerLeft, child: AppUI.requiredNote()),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(AppText.close)),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: AppUI.danger(context),
            child: const Text('Cancel Receipt'),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (ok != true) return;
    if (reason.isEmpty) return _snack('Enter a reason to cancel the receipt.', AppColors.warning);
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await SupabaseService.client.rpc('void_advance_receipt', params: {
        'p_token': SupabaseService.sessionToken,
        'p_adv_id': rec['adv_id'],
        'p_user': context.read<AuthProvider>().userName,
        'p_reason': reason,
      });
      _snack('Receipt ${rec['advno']} cancelled.', AppColors.success);
      await _loadStudentLines();
    } catch (e) {
      _snack('Could not cancel the receipt. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fee Collection's "Payment Successful": receipt no, amount, mode, then
  /// Download Receipt or Done -- both clear the screen for the next student.
  void _showSuccess({required String advno, required double total, required String mode, required VoidCallback onDownload}) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          AppIcon('tick-circle', color: AppColors.success, size: 56.sp),
          SizedBox(height: 12.h),
          Text('Payment Successful', style: AppUI.cardTitle),
          SizedBox(height: 8.h),
          Text('Receipt No.: $advno', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
          Text('Amount: ₹${total.toStringAsFixed(2)}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
          Text('${AppText.paymentMode}: $mode', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
          SizedBox(height: 16.h),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              onDownload();
              _clearAll();
            },
            icon: AppIcon('document-download', size: AppBtn.iconSize(context)),
            label: const Text('Download Receipt'),
          ),
        ]),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _clearAll();
            },
            child: const Text(AppText.close),
          ),
        ],
      ),
    );
  }

  /// Back to an empty screen (as Fee Collection's Clear), with the search
  /// tags refreshed so the student just paid shows their new status.
  void _clearAll() {
    setState(() {
      _student = null;
      for (final l in _lines) {
        l.pay.dispose();
      }
      _lines.clear();
      _receipts = [];
      _raised = 0;
      _mode = null;
      _searchKey++;
    });
    _load();
  }

  void _showReceipt({
    required String advno,
    required DateTime date,
    required List<Map<String, dynamic>> lines,
    required String mode,
    int? fgId,
    String recon = 'R',
    bool cancelled = false,
  }) {
    final dateStr = formatDmy(date);
    final s = _student ?? const <String, dynamic>{};
    final lh = SupabaseService.letterheadFor(fgId: fgId, settings: _settings, fallbackName: _insName, fallbackAddress: _insAddress);
    final byTerm = <String, List<ReceiptFeeItem>>{};
    for (final l in lines) {
      byTerm.putIfAbsent('${l['term']} ($_nextYear)', () => []).add(ReceiptFeeItem(type: '${l['feetype']}', amount: _num(l['amount'])));
    }
    final total = lines.fold<double>(0, (t, l) => t + _num(l['amount']));
    final data = ReceiptData(
      receiptNo: advno,
      date: dateStr,
      studentName: '${s['stuname'] ?? '-'}',
      mobileNo: '${s['stumobile'] ?? '-'}',
      address: '-',
      admissionNo: '${s['stuadmno'] ?? '-'}',
      className: '${s['stuclass'] ?? '-'}',
      courseName: '${s['courname'] ?? '-'}',
      schoolName: lh.name,
      schoolAddress: lh.address,
      headerBanner: lh.banner,
      schoolLogoUrl: _insLogo,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      feeDetails: [for (final e in byTerm.entries) ReceiptTermDetail(term: e.key, fees: e.value)],
      paymentMethod: mode.toLowerCase(),
      paymentDate: dateStr,
      status: 'paid',
      reconStatus: recon,
      total: total,
      cancelled: cancelled,
    );
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 620,
          height: 920,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton.icon(
                  onPressed: () async {
                    try {
                      final bytes = await (await buildReceiptPdf(data)).save();
                      final path = await FilePicker.platform.saveFile(
                        dialogTitle: 'Save Receipt PDF',
                        fileName: 'Receipt_${advno.replaceAll('/', '_')}.pdf',
                        type: FileType.custom,
                        allowedExtensions: ['pdf'],
                      );
                      if (path != null) await File(path).writeAsBytes(bytes);
                    } catch (e) {
                      _snack(friendlyError(e), AppColors.error);
                    }
                  },
                  icon: const AppIcon('document-download', size: 18),
                  label: const Text('Download'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      await Printing.layoutPdf(
                        format: a5PageFormat,
                        onLayout: (fmt) async => (await buildReceiptPdf(data, pageFormat: fmt)).save(),
                        name: 'Receipt_${advno.replaceAll('/', '_')}',
                      );
                    } catch (e) {
                      _snack(friendlyError(e), AppColors.error);
                    }
                  },
                  icon: const AppIcon('printer', size: 18, color: Colors.white),
                  label: const Text('Print'),
                ),
                const SizedBox(width: 8),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const AppIcon.linear('close-circle', size: 20)),
              ]),
            ),
            const Divider(height: 1),
            Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(12), child: Center(child: ReceiptWidget(data: data)))),
          ]),
        ),
      ),
    );
  }

  // ── UI (the Fee Collection screen's layout and styles) ─────────────────
  bool get _compact => MediaQuery.of(context).size.width <= 1366;

  InputDecoration _inputDec(String hint, {bool filled = false}) => AppUI.field(context, hint, filled: filled);

  TextStyle _ddTextStyle() => AppUI.fieldText(context);

  BoxDecoration get _cardDec => AppUI.card();

  ButtonStyle _solidBtn() => AppUI.primary(context);

  ButtonStyle _outlineBtn() => AppUI.secondary(context);

  Widget _detailRow(String icon, String label, String value, {Color? color}) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppIcon(icon, size: 15, color: AppColors.textSecondary),
        SizedBox(width: 8.w),
        Text('$label  ', style: AppUI.muted),
        Expanded(
          child: Text(value,
              style: AppUI.label.copyWith(color: color ?? AppColors.textPrimary), overflow: TextOverflow.ellipsis),
        ),
      ]);

  Widget _th(String t, int flex, {TextAlign align = TextAlign.left}) => Expanded(
        flex: flex,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6.w),
          child: Text(t.toUpperCase(),
              textAlign: align, style: AppUI.tableHead),
        ),
      );

  Widget _td(String t, int flex, {TextAlign align = TextAlign.left, TextStyle? style}) => Expanded(
        flex: flex,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6.w),
          child: Text(t,
              textAlign: align,
              overflow: TextOverflow.ellipsis,
              style: style ?? AppUI.cell),
        ),
      );

  Widget _numField(TextEditingController ctrl, {bool enabled = true}) {
    final filled = ctrl.text.trim().isNotEmpty;
    return TextField(
      controller: ctrl,
      enabled: enabled,
      onChanged: (_) => setState(() {}),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
      textAlign: TextAlign.center,
      style: AppUI.fieldText(context, filled: filled),
      decoration: AppUI.field(context, '0', filled: filled, dense: true),
    );
  }

  static String _dmy(dynamic v) {
    final x = DateTime.tryParse('${v ?? ''}');
    return x == null ? '-' : formatDmy(x);
  }

  @override
  Widget build(BuildContext context) {
    if (!isSchool) {
      return Center(child: Text('Advance Fee Collection is used on the school database only.', style: AppUI.muted));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        decoration: _cardDec,
        padding: EdgeInsets.all(AppUI.cardPad),
        child: _lookup(),
      ),
      SizedBox(height: AppUI.gap),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_student != null) ...[
            Container(decoration: _cardDec, padding: EdgeInsets.all(AppUI.cardPad), child: _studentCard()),
            SizedBox(height: AppUI.gap),
          ],
          Expanded(child: _demandsPanel()),
        ]),
      ),
    ]);
  }

  // Title row, as Fee Collection: icon tile, title, Spacer, Standard,
  // Section, search, Clear.
  Widget _lookup() => Row(children: [
        AppUI.iconTile('empty-wallet-add'),
        SizedBox(width: 12.w),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Advance Fee Collection', style: AppUI.cardTitle),
          Text('Collect next year\'s fees in advance', style: AppUI.muted),
        ]),
        const Spacer(),
        SizedBox(
          width: _compact ? 150.w : 180.w,
          child: _filterDrop(
            schoolTerm('Select course'),
            _fCour,
            [for (final c in _courseList) (_id(c['cour_id'])!, '${c['courname']}')],
            (v) => setState(() {
              _fCour = v;
              _fCla = null;
              _searchKey++;
            }),
          ),
        ),
        SizedBox(width: 10.w),
        SizedBox(
          width: _compact ? 150.w : 180.w,
          child: _filterDrop(
            schoolTerm('Select class'),
            _fCla,
            [
              for (final c in _classes)
                if (_fCour == null || _id(c['cour_id']) == _fCour) (_id(c['cla_id'])!, '${c['claname']}'),
            ],
            (v) => setState(() {
              _fCla = v;
              _searchKey++;
            }),
          ),
        ),
        SizedBox(width: 10.w),
        SizedBox(width: _compact ? 260.w : 340.w, child: _studentSearch()),
        SizedBox(width: 10.w),
        ElevatedButton.icon(
            onPressed: () => setState(() {
              _student = null;
              for (final l in _lines) {
                l.pay.dispose();
              }
              _lines.clear();
              _receipts = [];
              _mode = null;
              _fCour = null;
              _fCla = null;
              _searchKey++;
            }),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Clear'),
            style: _solidBtn(),
        ),
      ]);

  int _searchKey = 0;

  Widget _filterDrop(String hint, int? value, List<(int, String)> items, ValueChanged<int?> onChanged) {
    return DropdownButtonFormField<int>(
      key: ValueKey('$hint-$value-${items.length}'),
      initialValue: items.any((e) => e.$1 == value) ? value : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12.r),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      style: _ddTextStyle(),
      decoration: _inputDec(hint, filled: value != null),
      hint: Text(hint, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)),
      items: [
        for (final e in items)
          DropdownMenuItem(value: e.$1, child: Text(e.$2, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context))),
      ],
      selectedItemBuilder: (_) => [
        for (final e in items)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(e.$2, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _studentSearch() => Autocomplete<Map<String, dynamic>>(
        key: ValueKey('adv-search-$_searchKey'),
        displayStringForOption: (s) => '${s['stuadmno']} - ${s['stuname']}',
        optionsBuilder: (v) {
          final q = v.text.trim().toLowerCase();
          if (q.isEmpty && _fCour == null && _fCla == null) return const Iterable.empty();
          return _students
              .where((s) =>
                  (_fCla == null || _id(s['cla_id']) == _fCla) &&
                  (_fCour == null || _id(s['cour_id']) == _fCour) &&
                  (q.isEmpty || '${s['stuadmno']}'.toLowerCase().contains(q) || '${s['stuname']}'.toLowerCase().contains(q)))
              .take(50);
        },
        onSelected: _selectStudent,
        fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
          controller: ctrl,
          focusNode: focus,
          style: _ddTextStyle().copyWith(color: ctrl.text.isNotEmpty ? AppColors.accent : null),
          decoration: _inputDec(schoolTerm('Search by register no. or name'), filled: ctrl.text.isNotEmpty)
              .copyWith(
                  prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.textLight),
                  prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 0)),
        ),
        // Wider than the search box and growing LEFTWARD from its right edge,
        // as Fee Collection's list does -- the box's own width squeezed the
        // name onto three lines.
        optionsViewBuilder: (context, onSelected, options) => OverflowBox(
          alignment: Alignment.topRight,
          minWidth: _compact ? 340.w : 480.w,
          maxWidth: _compact ? 340.w : 480.w,
          maxHeight: 480.h,
          child: Align(
          alignment: Alignment.topRight,
          child: Material(
            elevation: 6,
            color: Colors.white,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(12.r),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 480.h, maxWidth: _compact ? 340.w : 480.w),
              child: ListView.builder(
                padding: EdgeInsets.symmetric(vertical: 4.h),
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (_, i) {
                  final s = options.elementAt(i);
                  final due = _due[_id(s['stu_id'])];
                  final tag = due == null ? null : (due > 0 ? 'PENDING' : 'PAID');
                  return InkWell(
                    onTap: () => onSelected(s),
                    hoverColor: AppColors.accent.withValues(alpha: 0.06),
                    child: Container(
                      decoration: BoxDecoration(
                        color: i == 0 ? AppColors.tableHeadBg : null,
                        border: const Border(bottom: BorderSide(color: AppColors.divider)),
                      ),
                      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                      child: Row(children: [
                        SizedBox(
                          width: _compact ? 110.w : 132.w,
                          child: Text('${s['stuadmno']}', style: TextStyle(fontSize: _compact ? 10 : 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                        ),
                        SizedBox(width: 14.w),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text('${s['stuname']}'.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: _compact ? 11 : 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary, letterSpacing: 0.2)),
                            Text('${s['stuclass'] ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: _compact ? 9 : 11, fontWeight: FontWeight.w500, color: AppColors.textLight)),
                          ]),
                        ),
                        SizedBox(width: 14.w),
                        SizedBox(
                          width: _compact ? 74.w : 88.w,
                          child: tag == null
                              ? const SizedBox.shrink()
                              : Align(
                                  alignment: Alignment.centerRight,
                                  child: AppUI.chip(tag, (due ?? 0) > 0 ? AppStatus.warning : AppStatus.success),
                                ),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ),
          ),
        ),
      );

  // Avatar, name + Adm No, then the detail columns and the buttons.
  Widget _studentCard() {
    final s = _student!;
    final app = _applicable(s);
    final name = '${s['stuname'] ?? ''}';
    Widget sep() => Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 16.w),
          Container(width: 1, height: 36.h, color: AppColors.divider),
          SizedBox(width: 16.w),
        ]);
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      StudentAvatar(photoUrl: s['stuphoto']?.toString(), name: name, size: 44),
      SizedBox(width: 12.w),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(height: 2.h),
          Text('${schoolTerm('Roll Number')}: ${s['stuadmno']}${(_id(s['preadmission']) ?? 0) == 1 ? '  ·  Pre-admission' : ''}',
              style: AppUI.muted),
        ]),
      ),
      sep(),
      Expanded(child: _detailRow('teacher', schoolTerm('Class'), '${s['stuclass'] ?? '-'}')),
      sep(),
      Expanded(
        child: _detailRow('book-1', schoolTerm('Applicable Class'),
            app == null ? schoolTerm('No next class') : _appName(app),
            color: app == null ? AppColors.error : AppColors.accent),
      ),
      sep(),
      Expanded(child: _detailRow('calendar-1', 'Academic Year', _nextYear)),
      SizedBox(width: 16.w),
      OutlinedButton.icon(
        onPressed: _openReceipts,
        icon: const Icon(Icons.receipt_long_outlined, size: 16),
        label: const Text('Receipts'),
        style: _outlineBtn(),
      ),
      SizedBox(width: 8.w),
      ElevatedButton.icon(
        onPressed: _busy ? null : _openFeeDefinition,
        icon: const Icon(Icons.fact_check_outlined, size: 16),
        label: const Text('Fee Definition'),
        style: _solidBtn(),
      ),
    ]);
  }

  /// The student's own advance fees, as Fee Collection's Fee Definition.
  Future<void> _openFeeDefinition() async {
    final s = _student;
    if (s == null) return;
    final app = _applicable(s);
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AdvanceFeeDefinitionDialog(
        student: s,
        nextClaId: app?.$1,
        nextCourId: app?.$2,
        nextClassName: app == null ? '-' : (app.$1 == null ? (_courseName[app.$2] ?? '-') : (_className[app.$1] ?? '-')),
        nextYear: _nextYear,
      ),
    );
    if (saved == true) await _loadStudentLines();
  }

  // Panel shell + header (title, count pill, year badge).
  Widget _demandsPanel() {
    final ticked = _lines.where((l) => l.ticked).length;
    return Container(
      decoration: _cardDec,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, AppUI.cardPad, 0),
          child: Row(children: [
            AppUI.iconTile('document-text', size: 18),
            SizedBox(width: 12.w),
            Text('Pending Advance Fee Demands', style: AppUI.cardTitle),
            SizedBox(width: 10.w),
            AppUI.chip('$ticked of ${_lines.length} items', AppStatus.info),
            const Spacer(),
            if (_nextYear.isNotEmpty)
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.event_note_rounded, size: 15, color: AppColors.accent),
                  SizedBox(width: 6.w),
                  Text('Advance · $_nextYear', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.accent)),
                ]),
              ),
          ]),
        ),
        Expanded(child: _demandsContent()),
      ]),
    );
  }

  Widget _demandsContent() {
    if (_loading || (_busy && _student != null && _lines.isEmpty)) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_student == null) {
      return AppUI.empty(icon: 'search-normal-1', title: 'Search for a student to view advance fees');
    }
    if (_lines.isEmpty && _raised > 0) {
      return AppUI.empty(
        icon: 'tick-circle',
        title: 'No pending advance fee demands',
        why: 'Everything raised for $_nextYear is paid -- see Receipts.',
      );
    }
    if (_lines.isEmpty) {
      return AppUI.empty(
        icon: 'tick-circle',
        title: 'No advance fee demands',
        why: _applicable(_student!) == null
            ? schoolTerm('This student has no next class (final course, or no matching class next year). Set it in Setup → Fee Master → Class Matching.')
            : schoolTerm('Nothing raised for ${_appName(_applicable(_student!)!)} yet -- save its Advance Fee Definition (Setup -> Fee Master), or add fees in Fee Definition.'),
      );
    }
    // One card per term, like Fee Collection's fee-group cards.
    final terms = <String, List<_PayLine>>{};
    for (final l in _lines) {
      terms.putIfAbsent('${l.row['afterm']}', () => []).add(l);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(AppUI.cardPad, 12.h, AppUI.cardPad, AppUI.cardPad),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
        child: Column(children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              children: [for (final e in terms.entries) _termCard(e.key, e.value)],
            ),
          ),
          _footer(),
        ]),
      ),
    );
  }

  Widget _termCard(String term, List<_PayLine> rows) {
    final open = rows.where((l) => _num(l.row['balance']) > 0).toList();
    final all = open.isNotEmpty && open.every((l) => l.ticked);
    final bal = rows.fold<double>(0, (t, l) => t + _num(l.row['balance']));
    final collecting = rows.fold<double>(0, (t, l) => t + (double.tryParse(l.pay.text.trim()) ?? 0));
    final live = collecting > 0;
    const color = AppColors.accent;
    return Container(
      margin: EdgeInsets.only(bottom: 14.h),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: live ? color : AppColors.cardBorder, width: live ? 1.4 : 1),
        boxShadow: live ? [BoxShadow(color: color.withValues(alpha: 0.10), blurRadius: 10)] : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: live ? color.withValues(alpha: 0.10) : AppColors.surface,
          padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
          child: Row(children: [
            Container(
              width: 28.w,
              height: 28.w,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(7.r), border: Border.all(color: color.withValues(alpha: 0.35))),
              child: const AppIcon('calendar-1', size: 15, color: color),
            ),
            SizedBox(width: 10.w),
            Text(term.toUpperCase(), style: TextStyle(fontSize: 13.5.sp, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: color)),
            SizedBox(width: 6.w),
            Text('(${rows.length} items)', style: AppUI.muted),
            if (live) ...[
              SizedBox(width: 10.w),
              AppUI.chip('COLLECTING NOW', AppStatus.info),
            ],
            const Spacer(),
            Text('Balance ', style: TextStyle(fontSize: 11.5.sp, color: AppColors.textLight)),
            Text('₹${bal.toStringAsFixed(2)}', style: TextStyle(fontSize: 12.5.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            if (live) ...[
              SizedBox(width: 16.w),
              Text('Collecting ', style: TextStyle(fontSize: 11.5.sp, color: AppColors.textLight)),
              Text('₹${collecting.toStringAsFixed(2)}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: color)),
            ],
          ]),
        ),
        Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
          child: Row(children: [
            SizedBox(
              width: 32.w,
              child: Checkbox(
                value: all,
                activeColor: color,
                visualDensity: VisualDensity.compact,
                onChanged: open.isEmpty || _busy
                    ? null
                    : (v) => setState(() {
                          for (final l in open) {
                            l.pay.text = v == true ? _num(l.row['balance']).toStringAsFixed(0) : '';
                          }
                        }),
              ),
            ),
            _th(schoolTerm('Semester'), 2),
            _th('Fee Type', 3),
            _th('Due Date', 2),
            _th('Fee Amount (₹)', 2, align: TextAlign.right),
            _th('Paid (₹)', 2, align: TextAlign.right),
            _th('Balance Amount (₹)', 2, align: TextAlign.right),
            _th('Collect Amount (₹)', 3, align: TextAlign.center),
          ]),
        ),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: AppColors.divider),
          _row(rows[i], i),
        ],
      ]),
    );
  }

  Widget _row(_PayLine l, int i) {
    final r = l.row;
    final bal = _num(r['balance']);
    final paid = _num(r['paidamount']);
    final done = '${r['paidstatus']}' == 'P';
    return Container(
      color: i.isEven ? Colors.white : AppColors.accent.withValues(alpha: 0.05),
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
      child: Row(children: [
        SizedBox(
          width: 32.w,
          child: Checkbox(
            value: l.ticked,
            activeColor: AppColors.accent,
            visualDensity: VisualDensity.compact,
            onChanged: bal <= 0 || _busy ? null : (v) => setState(() => l.pay.text = v == true ? bal.toStringAsFixed(0) : ''),
          ),
        ),
        _td('${r['afterm']}', 2, style: AppUI.cell),
        _td('${r['affeetype']}', 3, style: AppUI.cell.copyWith(color: AppColors.textSecondary)),
        _td(_dmy(r['duedate']), 2, style: AppUI.cell.copyWith(color: AppColors.textSecondary)),
        _td(_num(r['feeamount']).toStringAsFixed(2), 2, align: TextAlign.right, style: AppUI.money),
        _td(paid > 0 ? paid.toStringAsFixed(2) : '—', 2,
            align: TextAlign.right,
            style: paid > 0 ? AppUI.money.copyWith(color: AppColors.success) : AppUI.cell.copyWith(color: AppColors.textLight)),
        _td(bal.toStringAsFixed(2), 2,
            align: TextAlign.right, style: AppUI.money.copyWith(color: AppColors.warning)),
        Expanded(
          flex: 3,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 4.w),
            child: done
                ? Center(child: AppUI.chip('PAID', AppStatus.success))
                : _numField(l.pay, enabled: !_busy),
          ),
        ),
      ]),
    );
  }

  // Footer: selection count, NET AMOUNT pill, SELECT MODE, pay button.
  Widget _footer() {
    final n = _lines.where((l) => l.ticked).length;
    final total = _total;
    final modeOn = total > 0 && !_busy;
    final canPay = modeOn && _mode != null;
    final cash = _mode == 'Cash';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.divider)),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
      ),
      child: Row(children: [
        Icon(Icons.check_circle, size: 17.sp, color: n == 0 ? AppColors.textLight : AppColors.accent),
        SizedBox(width: 6.w),
        Text('$n of ${_lines.length} selected', style: AppUI.label),
        const Spacer(),
        if (n > 0) ...[
          Container(
            height: AppUI.controlHeight(context),
            padding: EdgeInsets.symmetric(horizontal: 16.w),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10.r),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.30)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Net Amount: ', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary, letterSpacing: 0.3)),
              Text('₹${total.toStringAsFixed(2)}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
            ]),
          ),
          SizedBox(width: 14.w),
        ],
        SizedBox(width: 6.w),
        Container(
          width: 160.w,
          height: AppUI.controlHeight(context),
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10.r),
            border: Border.all(color: (!modeOn || _mode == null) ? AppColors.border : AppColors.accent, width: 1.2),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _mode,
              isExpanded: true,
              hint: Text('Select payment mode', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.3)),
              items: [
                for (final m in _modes)
                  DropdownMenuItem(value: m, child: Text(m == 'QR/UPI' ? 'QR / UPI' : m, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.accent))),
              ],
              onChanged: modeOn ? (v) => setState(() => _mode = v) : null,
            ),
          ),
        ),
        SizedBox(width: 10.w),
        ElevatedButton.icon(
          onPressed: canPay ? _onPay : null,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textLight))
              : Icon(_mode == 'Paytm' ? Icons.open_in_new : Icons.send_rounded, size: 16),
          label: Text(cash ? 'Save & Collect' : 'Proceed to Pay'),
        ),
      ]),
    );
  }

  // Receipts dialog, as Fee Collection's: cards with number, date, mode,
  // amount, the fee breakdown, and print / void.
  void _openReceipts() {
    final s = _student;
    if (s == null) return;
    Color modeColor(String m) {
      final x = m.toLowerCase();
      if (x.contains('cash')) return AppColors.success;
      if (x.contains('upi') || x.contains('qr')) return AppColors.accent;
      if (x.contains('cheque') || x == 'dd') return AppColors.warning;
      return AppColors.textSecondary;
    }

    final active = _receipts.where((r) => (_id(r['activestatus']) ?? 1) == 1).toList();
    final sum = active.fold<double>(0, (t, r) => t + _num(r['transtotalamount']));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          AppUI.iconTile('receipt-2', size: 18),
          SizedBox(width: 12.w),
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Advance Receipts', style: AppUI.cardTitle),
            Text('${s['stuname']} • ${s['stuadmno']}', style: AppUI.muted),
          ]),
        ]),
        content: SizedBox(
          width: 560.w,
          child: _receipts.isEmpty
              ? Padding(
                  padding: EdgeInsets.symmetric(vertical: 30.h),
                  child: AppUI.empty(
                    icon: 'receipt-2',
                    title: 'No receipts yet',
                    why: 'Advance fee receipts for $_nextYear show here.',
                  ),
                )
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Text('${_receipts.length} receipts', style: AppUI.muted),
                    const Spacer(),
                    Text('Total ₹${sum.toStringAsFixed(2)}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
                  ]),
                  SizedBox(height: 10.h),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: 400.h),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _receipts.length,
                      separatorBuilder: (_, __) => SizedBox(height: 10.h),
                      itemBuilder: (_, i) {
                        final rec = _receipts[i];
                        final on = (_id(rec['activestatus']) ?? 1) == 1;
                        final date = DateTime.tryParse('${rec['advdate'] ?? ''}') ?? DateTime.now();
                        final mode = '${rec['paymethod'] ?? 'cash'}';
                        final mc = modeColor(mode);
                        final lines = List<Map<String, dynamic>>.from(rec['lines'] as List);
                        Widget iconBtn(IconData ic, Color c, String tip, VoidCallback onTap) => Tooltip(
                              message: tip,
                              child: InkWell(
                                onTap: onTap,
                                borderRadius: BorderRadius.circular(9.r),
                                child: Container(
                                  padding: EdgeInsets.all(8.w),
                                  decoration: BoxDecoration(
                                      color: c.withValues(alpha: 0.10),
                                      borderRadius: BorderRadius.circular(9.r),
                                      border: Border.all(color: c.withValues(alpha: 0.40))),
                                  child: Icon(ic, size: 16, color: c),
                                ),
                              ),
                            );
                        return Container(
                          clipBehavior: Clip.antiAlias,
                          decoration: AppUI.card(),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Padding(
                              padding: EdgeInsets.all(12.w),
                              child: Row(children: [
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(children: [
                                      Text('${rec['advno']}',
                                          style: TextStyle(
                                              fontSize: 14.sp,
                                              fontWeight: FontWeight.w800,
                                              color: on ? AppColors.textPrimary : AppColors.textLight,
                                              decoration: on ? null : TextDecoration.lineThrough)),
                                      if (!on) ...[
                                        SizedBox(width: 8.w),
                                        AppUI.chip('VOID', AppStatus.danger),
                                      ],
                                    ]),
                                    SizedBox(height: 4.h),
                                    Row(children: [
                                      const Icon(Icons.event, size: 13, color: AppColors.textLight),
                                      SizedBox(width: 4.w),
                                      Text(_dmy(rec['advdate']), style: AppUI.muted),
                                      SizedBox(width: 8.w),
                                      Container(
                                        padding: EdgeInsets.symmetric(horizontal: 7.w, vertical: 2.h),
                                        decoration: BoxDecoration(color: mc.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(999)),
                                        child: Text(mode.toUpperCase(), style: TextStyle(fontSize: 10.5.sp, fontWeight: FontWeight.w700, color: mc)),
                                      ),
                                    ]),
                                  ]),
                                ),
                                Text('₹${_num(rec['transtotalamount']).toStringAsFixed(2)}',
                                    style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
                                SizedBox(width: 10.w),
                                iconBtn(Icons.print_outlined, AppColors.accent, 'Print', () {
                                  _showReceipt(
                                    advno: '${rec['advno']}',
                                    date: date,
                                    lines: lines,
                                    mode: mode,
                                    recon: '${rec['recon_status'] ?? 'R'}',
                                    cancelled: !on,
                                  );
                                }),
                                if (on) ...[
                                  SizedBox(width: 6.w),
                                  iconBtn(Icons.block, AppColors.error, 'Cancel Receipt', () async {
                                    Navigator.pop(ctx);
                                    await _void(rec);
                                  }),
                                ],
                              ]),
                            ),
                            Container(
                              color: AppColors.surface,
                              padding: EdgeInsets.fromLTRB(12.w, 8.h, 12.w, 10.h),
                              decoration: null,
                              child: Column(children: [
                                for (final l in lines)
                                  Padding(
                                    padding: EdgeInsets.symmetric(vertical: 2.h),
                                    child: Row(children: [
                                      Container(width: 5, height: 5, decoration: const BoxDecoration(color: AppColors.textLight, shape: BoxShape.circle)),
                                      SizedBox(width: 8.w),
                                      Expanded(child: Text('${l['feetype']} — ${l['term']}', style: AppUI.muted)),
                                      Text('₹${_num(l['amount']).toStringAsFixed(2)}', textAlign: TextAlign.right, style: AppUI.money.copyWith(fontSize: 13.sp)),
                                    ]),
                                  ),
                              ]),
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
                ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }
}
