import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/app_text.dart';
import '../../utils/receipt_pdf.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/receipt_widget.dart';
import '../../widgets/receipt_preview.dart';
import '../../utils/save_path.dart';

/// Full page listing every payment awaiting reconciliation (recon_status = 'P').
/// Each row can download its receipt — which is printed "* Subject to
/// Realization" because the payment isn't yet reconciled.
class PendingApprovalScreen extends StatefulWidget {
  const PendingApprovalScreen({super.key});

  @override
  State<PendingApprovalScreen> createState() => _PendingApprovalScreenState();
}

class _PendingApprovalScreenState extends State<PendingApprovalScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  /// Row currently generating a receipt, keyed 'P:<pay_id>' / 'M:<mc_id>' /
  /// 'A:<adv_id>'.
  /// Not a bare pay_id: a misc row has none, and `null == null` made every
  /// misc row show a permanent spinner.
  String? _busyKey;

  static String _rowKey(Map<String, dynamic> p) =>
      p['adv_id'] != null
          ? 'A:${p['adv_id']}'
          : (p['mc_id'] != null ? 'M:${p['mc_id']}' : 'P:${p['pay_id']}');
  String? _insName, _insAddress, _insLogo, _insMobile, _insEmail;

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final auth = context.read<AuthProvider>();
    if (auth.schema != null && auth.schema!.isNotEmpty) {
      SupabaseService.setSchema(auth.schema);
    }
    setState(() => _loading = true);
    try {
      final info = await SupabaseService.getInstitutionInfo(_insId);
      // Query only the un-reconciled rows directly (a small set) instead of
      // fetching every payment ever made and filtering client-side.
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('payment')
          .select('pay_id, stu_id, paynumber, transtotalamount, paydate, paymethod, payreference')
          .eq('ins_id', _insId).eq('activestatus', 1)
          .eq('paystatus', 'C').eq('recon_status', 'P')
          .order('paydate', ascending: false));
      // Attach student name/class for just these payers in one query.
      final stuIds = rows.map((r) => r['stu_id']).where((id) => id != null).toSet().toList();
      if (stuIds.isNotEmpty) {
        final students = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, courname')
            .inFilter('stu_id', stuIds));
        final stuMap = {for (final s in students) s['stu_id']: s};
        for (final p in rows) {
          final s = stuMap[p['stu_id']];
          if (s != null) {
            p['stuname'] = s['stuname'];
            p['stuadmno'] = s['stuadmno'];
            p['stuclass'] = s['stuclass'];
            p['courname'] = s['courname'];
          }
        }
      }
      // Misc receipts (BONAFIDE, APPLICATION, …) wait for the same bank
      // approval, so they belong on the same list -- otherwise this screen
      // reports less money outstanding than Bank Reconciliation does.
      // Normalised into the payment row shape; mc_id marks which is which.
      try {
        final misc = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('misc_collection')
            .select('mc_id, mcno, mcdate, totalamount, paymode, transrefno, '
                'paytm_txnid, stuname, regno, stuclass, courname')
            .eq('ins_id', _insId).eq('activestatus', 1)
            .eq('recon_status', 'P')
            .order('mcdate', ascending: false));
        for (final m in misc) {
          rows.add({
            'mc_id': m['mc_id'],
            'paynumber': m['mcno'],
            'transtotalamount': m['totalamount'],
            'paydate': m['mcdate'],
            'paymethod': m['paymode'],
            // paytm_txnid first -- see bank_reconciliation_screen: a Paytm misc
            // receipt keeps the ORDER id in transrefno, which matches no bank line.
            'payreference': (m['paytm_txnid']?.toString().trim().isNotEmpty ?? false)
                ? m['paytm_txnid']
                : m['transrefno'],
            'stuname': m['stuname'],
            'stuadmno': m['regno'],
            'stuclass': m['stuclass'],
            'courname': m['courname'],
          });
        }
        // Newest first across both sources, so the two do not interleave oddly.
        rows.sort((a, b) => (b['paydate']?.toString() ?? '')
            .compareTo(a['paydate']?.toString() ?? ''));
      } catch (e) {
        // No recon_status column yet (migration not run): misc simply does not
        // appear, exactly as before, rather than breaking the whole screen.
        debugPrint('pending misc unavailable: $e');
      }

      // Advances wait for the same approval: a cheque or UPI advance is money
      // in hand but unconfirmed, and Bank Reconciliation already lists it. This
      // screen has to agree with that one.
      try {
        final adv = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('advance_collection')
            .select('adv_id, advno, advdate, advtype, transtotalamount, paymethod, '
                'payreference, paytm_txnid, stuname, stuadmno, stuclass, courname')
            .eq('ins_id', _insId).eq('activestatus', 1)
            .eq('paystatus', 'C')
            .eq('recon_status', 'P')
            .order('advdate', ascending: false));
        for (final a in adv) {
          rows.add({
            'adv_id': a['adv_id'],
            'advtype': a['advtype'],
            'paynumber': a['advno'],
            'transtotalamount': a['transtotalamount'],
            'paydate': a['advdate'],
            'paymethod': a['paymethod'],
            // paytm_txnid first, for the same reason misc prefers it: our own
            // order id appears on no bank statement.
            'payreference': (a['paytm_txnid']?.toString().trim().isNotEmpty ?? false)
                ? a['paytm_txnid']
                : a['payreference'],
            'stuname': a['stuname'],
            'stuadmno': a['stuadmno'],
            'stuclass': a['stuclass'],
            'courname': a['courname'],
          });
        }
        rows.sort((a, b) => (b['paydate']?.toString() ?? '')
            .compareTo(a['paydate']?.toString() ?? ''));
      } catch (e) {
        debugPrint('pending advances unavailable: $e');
      }

      if (!mounted) return;
      setState(() {
        _insName = info.name;
        _insAddress = info.address;
        _insLogo = info.logo;
        _insMobile = info.mobile;
        _insEmail = info.email;
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(friendlyError(e), AppColors.error);
    }
  }

  double get _total => _rows.fold(0, (s, p) => s + ((p['transtotalamount'] as num?)?.toDouble() ?? 0));

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  String _inr(double v) {
    final s = v.abs().round().toString();
    if (s.length <= 3) return '₹$s';
    final last3 = s.substring(s.length - 3);
    final rest = s.substring(0, s.length - 3);
    final withCommas = rest.replaceAllMapped(RegExp(r'\B(?=(\d{2})+(?!\d))'), (_) => ',');
    return '₹$withCommas,$last3';
  }

  // ── Receipt building (mirrors the Transactions screen) ─────────────────────
  /// Institution settings, for the per-fee-group receipt letterhead.
  Map<String, String> _lhSettings = const {};

  /// The letterhead for a receipt of [fgId] -- the group resolved from the
  /// receipt's OWN fee types, so a hostel receipt approved here carries the
  /// hostel head however long after it was collected.
  Future<({String name, String address, String banner})> _lh(int? fgId) async {
    final insId = context.read<AuthProvider>().insId;
    // Asked every time, not once per screen: getInstitutionSettings
    // now serves a shared 60-second cache, so this costs nothing and a
    // letterhead changed on another machine reaches this counter without
    // restarting the app.
    if (insId != null) {
      _lhSettings = await SupabaseService.getInstitutionSettings(insId);
    }
    return SupabaseService.letterheadFor(
      fgId: fgId,
      settings: _lhSettings,
      fallbackName: _insName ?? '-',
      fallbackAddress: _insAddress ?? '-',
    );
  }

  Future<ReceiptData> _receiptFor(Map<String, dynamic> p) async {
    if (p['adv_id'] != null) return _advanceReceiptFor(p);
    if (p['mc_id'] != null) return _miscReceiptFor(p);
    final payId = p['pay_id'] as int?;
    final date = DateTime.tryParse(p['paydate']?.toString() ?? '') ?? DateTime.now();
    final dateStr = formatDmy(date);

    final feeTypesOnReceipt = <String>{};
    List<ReceiptTermDetail> feeDetails = [];
    String? arrearBranch, payBranch;
    if (payId != null) {
      try {
        final details = await SupabaseService.getFeeDetailsByPayId(payId);
        if (details.isNotEmpty) {
          for (final d in details) {
            final sc = d['stuclass']?.toString() ?? '';
            if (payBranch == null && sc.isNotEmpty) payBranch = sc;
            final isArr = (d['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
            final ac = d['arrearclass']?.toString() ?? '';
            if (isArr && ac.isNotEmpty) { arrearBranch = ac; break; }
          }
          final termMap = <String, List<ReceiptFeeItem>>{};
          for (final d in details) {
            final term = (d['demfeeterm']?.toString().trim().isNotEmpty == true) ? d['demfeeterm'].toString() : '-';
            final feeType = d['demfeetype']?.toString() ?? d['feegroupname']?.toString() ?? 'Fee';
            final fine = (d['fineamount'] as num?)?.toDouble() ?? 0.0;
            final collected = (d['collectedamount'] as num?)?.toDouble() ?? (d['feeamount'] as num?)?.toDouble() ?? 0.0;
            final feeOnly = (collected - fine).clamp(0, double.infinity).toDouble();
            termMap.putIfAbsent(term, () => []);
            termMap[term]!.add(ReceiptFeeItem(type: feeType, amount: feeOnly));
            if (fine > 0) termMap[term]!.add(ReceiptFeeItem(type: '  Fine', amount: fine));
          }
          feeTypesOnReceipt.addAll(
              details.map((d) => d['demfeetype']?.toString() ?? ''));
          feeDetails = termMap.entries.map((e) => ReceiptTermDetail(term: e.key, fees: e.value)).toList();
        }
      } catch (_) {}
    }
    final total = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
    if (feeDetails.isEmpty) {
      feeDetails = [ReceiptTermDetail(term: '-', fees: [ReceiptFeeItem(type: 'Payment', amount: total)])];
    }

    // Student contact details for the receipt header.
    String mobile = '-', address = '-';
    final stuId = p['stu_id'];
    if (stuId != null) {
      try {
        final s = await SupabaseService.fromSchema('students')
            .select('stumobile, stuaddress')
            .eq('stu_id', stuId)
            .limit(1);
        final list = s as List;
        if (list.isNotEmpty) {
          mobile = list[0]['stumobile']?.toString() ?? '-';
          address = list[0]['stuaddress']?.toString() ?? '-';
        }
      } catch (_) {}
    }

    final lh = await _lh(
        await SupabaseService.feeGroupOfFeeTypes(feeTypesOnReceipt.toList()));
    return ReceiptData(
      receiptNo: p['paynumber']?.toString() ?? '$payId',
      date: dateStr,
      studentName: p['stuname']?.toString() ?? '-',
      mobileNo: mobile,
      address: address,
      admissionNo: p['stuadmno']?.toString() ?? '-',
      className: (arrearBranch != null && arrearBranch.isNotEmpty)
          ? arrearBranch
          : (payBranch != null && payBranch.isNotEmpty ? payBranch : (p['stuclass']?.toString() ?? '-')),
      courseName: p['courname']?.toString() ?? '-',
      schoolName: lh.name,
      schoolAddress: lh.address,
      headerBanner: lh.banner,
      schoolLogoUrl: _insLogo,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      feeDetails: feeDetails,
      paymentMethod: p['paymethod']?.toString() ?? '-',
      paymentDate: dateStr,
      status: 'pending',
      reconStatus: 'P', // → "* Subject to Realization" on the receipt
      paymentReference: p['payreference']?.toString(),
      total: total,
    );
  }

  /// Receipt for an ADVANCE. An admission advance lists the fee types it was
  /// collected for (advance_detail); a student advance is a plain amount and
  /// gets one line. reconStatus 'P' is what puts "* Subject to Realization" on
  /// it -- which is the whole point of it being on this screen.
  Future<ReceiptData> _advanceReceiptFor(Map<String, dynamic> p) async {
    final advId = p['adv_id'];
    final date = DateTime.tryParse(p['paydate']?.toString() ?? '') ?? DateTime.now();
    final dateStr = formatDmy(date);
    final total = (p['transtotalamount'] as num?)?.toDouble() ?? 0;

    final items = <ReceiptFeeItem>[];
    try {
      final det = await SupabaseService.fromSchema('advance_detail')
          .select('feetype, amount')
          .eq('adv_id', advId)
          .eq('activestatus', 1);
      for (final d in List<Map<String, dynamic>>.from(det as List)) {
        items.add(ReceiptFeeItem(
          type: d['feetype']?.toString() ?? 'ADVANCE',
          amount: (d['amount'] as num?)?.toDouble() ?? 0,
        ));
      }
    } catch (e) {
      debugPrint('advance receipt detail failed: $e');
    }
    if (items.isEmpty) items.add(ReceiptFeeItem(type: 'ADVANCE', amount: total));

    String mobile = '-', address = '-';
    final admno = p['stuadmno']?.toString() ?? '';
    if (admno.isNotEmpty) {
      try {
        final srows = await SupabaseService.fromSchema('students')
            .select('stumobile, stuaddress')
            .eq('stuadmno', admno)
            .limit(1);
        final list = srows as List;
        if (list.isNotEmpty) {
          mobile = list[0]['stumobile']?.toString() ?? '-';
          address = list[0]['stuaddress']?.toString() ?? '-';
        }
      } catch (_) {}
    }

    final advLh = await _lh((await SupabaseService.resolveRoutingTarget(
      insId: context.read<AuthProvider>().insId ?? 1,
      advType: (p['advtype']?.toString() ?? 'S').toUpperCase(),
    )).fgId);
    return ReceiptData(
      receiptNo: p['paynumber']?.toString() ?? '$advId',
      date: dateStr,
      studentName: p['stuname']?.toString() ?? '-',
      mobileNo: mobile,
      address: address,
      admissionNo: admno.isEmpty ? '-' : admno,
      className: p['stuclass']?.toString() ?? '-',
      courseName: p['courname']?.toString() ?? '-',
      schoolName: advLh.name,
      schoolAddress: advLh.address,
      headerBanner: advLh.banner,
      schoolLogoUrl: _insLogo,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      feeDetails: [
        // Said plain "Advance" for both student and mess, so the two were
        // indistinguishable on paper.
        ReceiptTermDetail(
            term: SupabaseService.advanceHeadName(p['advtype']?.toString()),
            fees: items),
      ],
      paymentMethod: p['paymethod']?.toString() ?? '-',
      paymentDate: dateStr,
      status: 'paid',
      reconStatus: 'P',
      paymentReference: p['payreference']?.toString(),
      total: total,
    );
  }

  /// Receipt for a misc collection. Built from misc_collection_detail rather
  /// than paymentdetails/feedemand -- a misc receipt has neither. reconStatus
  /// 'P' is what puts "* Subject to Realization" on it, the same marker an
  /// unreconciled fee receipt carries.
  Future<ReceiptData> _miscReceiptFor(Map<String, dynamic> p) async {
    final mcId = p['mc_id'];
    final date = DateTime.tryParse(p['paydate']?.toString() ?? '') ?? DateTime.now();
    final dateStr = formatDmy(date);

    final items = <ReceiptFeeItem>[];
    try {
      final det = await SupabaseService.fromSchema('misc_collection_detail')
          .select('feetype, amount')
          .eq('mc_id', mcId)
          .eq('activestatus', 1);
      for (final d in List<Map<String, dynamic>>.from(det as List)) {
        items.add(ReceiptFeeItem(
          type: d['feetype']?.toString() ?? 'Misc',
          amount: (d['amount'] as num?)?.toDouble() ?? 0,
        ));
      }
    } catch (e) {
      debugPrint('misc receipt detail failed: $e');
    }

    final total = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
    if (items.isEmpty) {
      items.add(ReceiptFeeItem(type: 'Miscellaneous Collection', amount: total));
    }

    // Contact details: the misc row carries its own address (it can be raised
    // for a non-student), so fall back to that when there is no student.
    String mobile = '-', address = p['address']?.toString() ?? '-';
    final admno = p['stuadmno']?.toString() ?? '';
    if (admno.isNotEmpty) {
      try {
        final srows = await SupabaseService.fromSchema('students')
            .select('stumobile, stuaddress')
            .eq('stuadmno', admno)
            .limit(1);
        final list = srows as List;
        if (list.isNotEmpty) {
          mobile = list[0]['stumobile']?.toString() ?? '-';
          address = list[0]['stuaddress']?.toString() ?? address;
        }
      } catch (_) {}
    }

    final miscLh = await _lh(await SupabaseService.feeGroupOfFeeTypes(
        [for (final it in items) it.type]));
    return ReceiptData(
      receiptNo: p['paynumber']?.toString() ?? '$mcId',
      date: dateStr,
      studentName: p['stuname']?.toString() ?? '-',
      mobileNo: mobile,
      address: address,
      admissionNo: admno.isEmpty ? '-' : admno,
      className: p['stuclass']?.toString() ?? '-',
      courseName: p['courname']?.toString() ?? '-',
      schoolName: miscLh.name,
      schoolAddress: miscLh.address,
      headerBanner: miscLh.banner,
      schoolLogoUrl: _insLogo,
      schoolMobile: _insMobile,
      schoolEmail: _insEmail,
      feeDetails: [ReceiptTermDetail(term: 'Miscellaneous Collection', fees: items)],
      paymentMethod: p['paymethod']?.toString() ?? '-',
      paymentDate: dateStr,
      status: 'pending',
      reconStatus: 'P', // → "* Subject to Realization"
      paymentReference: p['payreference']?.toString(),
      total: total,
    );
  }

  /// Preview the receipt first; Download / Print are offered from inside.
  Future<void> _showReceiptPreview(Map<String, dynamic> p) async {
    setState(() => _busyKey = _rowKey(p));
    ReceiptData data;
    try {
      data = await _receiptFor(p);
    } catch (e) {
      _snack(friendlyError(e), AppColors.error);
      return;
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 620,
          height: 920,
          child: Column(children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton.icon(
                  onPressed: () { Navigator.pop(ctx); _download(p); },
                  icon: const AppIcon('receipt-2', size: 18, color: AppColors.primary),
                  label: const Text('Download'),
                ),
                SizedBox(width: 8.w),
                ElevatedButton.icon(
                  onPressed: () { Navigator.pop(ctx); _print(p); },
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print'),
                ),
                SizedBox(width: 8.w),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close, size: 20)),
              ]),
            ),
            const Divider(height: 1, color: AppColors.divider),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(12.w),
                child: Center(
                  child: Container(
                    decoration: BoxDecoration(boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 2)),
                    ]),
                    child: ReceiptPreview(data: data),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _download(Map<String, dynamic> p) async {
    final payId = p['pay_id'] as int?;
    setState(() => _busyKey = _rowKey(p));
    try {
      final data = await _receiptFor(p);
      final pdf = await buildReceiptPdf(data);
      final bytes = await pdf.save();
      final receiptNo = p['paynumber']?.toString() ?? '$payId';
      final fileName = 'Receipt_${receiptNo.replaceAll('/', '_')}.pdf';
      final result = await pickSavePath(
        dialogTitle: 'Save Receipt', fileName: fileName, type: FileType.custom, allowedExtensions: ['pdf']);
      if (result != null) {
        await File(result).writeAsBytes(bytes);
        _snack('Receipt saved to $result', AppColors.accent);
      }
    } catch (e) {
      _snack(friendlyError(e), AppColors.error);
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _print(Map<String, dynamic> p) async {
    final payId = p['pay_id'] as int?;
    setState(() => _busyKey = _rowKey(p));
    try {
      final data = await _receiptFor(p);
      await Printing.layoutPdf(
        format: await receiptPaper(),
        onLayout: (fmt) async => (await buildReceiptPdf(data, pageFormat: fmt)).save(),
        name: 'Receipt_${(p['paynumber']?.toString() ?? '$payId').replaceAll('/', '_')}',
      );
    } catch (e) {
      _snack(friendlyError(e), AppColors.error);
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.cardBorder)),
        title: Row(children: [
          AppUI.iconTile('clock', color: AppColors.warning, size: 18),
          SizedBox(width: 12.w),
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Pending Approval', style: AppUI.cardTitle),
            Text('Payments awaiting reconciliation', style: AppUI.muted),
          ]),
        ]),
        actions: [
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh, size: 20), tooltip: 'Refresh'),
          SizedBox(width: 8.w),
        ],
      ),
      body: _loading
          ? const AppLoading(label: 'Loading pending payments…')
          : _rows.isEmpty
              ? const EmptyState(icon: 'tick-circle', title: 'Nothing pending', subtitle: 'All payments have been reconciled.')
              : Padding(
                  padding: EdgeInsets.all(AppUI.gap),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // The ONLY amber on the screen, besides the badge in the
                    // app bar. Every row below is pending -- that is what the
                    // screen is -- so colouring each one says nothing and
                    // leaves no colour left for the things that do differ.
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
                      decoration: BoxDecoration(
                        color: AppColors.warningBg,
                        borderRadius: BorderRadius.circular(AppUI.controlRadius),
                        border: Border.all(color: AppColors.warning.withValues(alpha: 0.22)),
                      ),
                      child: Row(children: [
                        const AppIcon('info-circle', size: 16, color: AppColors.warning),
                        SizedBox(width: 9.w),
                        Expanded(child: RichText(
                          text: TextSpan(children: [
                            TextSpan(
                              text: '${_rows.length} payment${_rows.length == 1 ? '' : 's'}',
                              style: AppUI.label),
                            TextSpan(
                              text: ' awaiting reconciliation — receipts print "Subject to Realization".',
                              style: AppUI.body.copyWith(fontSize: 13.sp, color: AppColors.textSecondary)),
                          ]),
                        )),
                        SizedBox(width: 12.w),
                        Text(_inr(_total),
                            style: AppUI.money.copyWith(fontWeight: FontWeight.w800, color: AppColors.warning)),
                        SizedBox(width: 4.w),
                        Text('total', style: AppUI.muted),
                      ]),
                    ),
                    SizedBox(height: AppUI.gap),
                    Expanded(
                      child: Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: AppUI.card(),
                        child: Column(children: [
                          _headerRow(),
                          Expanded(
                            child: ListView.separated(
                              itemCount: _rows.length,
                              // A hairline, not a full-strength rule, and no
                              // zebra striping: 40 rows of alternating fill is
                              // what made the table read as a pattern first and
                              // a list of payments second.
                              separatorBuilder: (_, __) => const Divider(
                                  height: 1, thickness: 1,
                                  color: AppColors.divider),
                              itemBuilder: (_, i) => _dataRow(_rows[i]),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ]),
                ),
    );
  }

  Widget _headerRow() {
    Widget h(String t, {int flex = 2, TextAlign align = TextAlign.left}) =>
        AppUI.th(t, flex: flex, align: align);
    // The shared table-head bar, held down by a hairline under it.
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.tableHeadBg,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 11.h),
      child: Row(children: [
        h('STUDENT', flex: 4),
        h('RECEIPT NO.', flex: 3),
        h('MODE', flex: 2),
        h('DATE', flex: 2),
        h('AMOUNT', flex: 2, align: TextAlign.right),
        h('ACTION', flex: 3, align: TextAlign.right),
      ]),
    );
  }

  /// Which icon a payment mode gets. Cash, bank and card are told apart by
  /// SHAPE, not by colour -- three coloured chips in one column would be three
  /// more hues on a screen that already has an amber banner and a blue action.
  String _modeIcon(String mode) {
    final m = mode.toUpperCase();
    if (m.contains('CASH')) return 'money-2';
    if (m.contains('CARD')) return 'card';
    if (m.contains('CHEQUE') || m.contains('DD') || m.contains('DRAFT')) {
      return 'receipt-2';
    }
    return 'bank';
  }

  /// The MODE cell: a quiet neutral chip. It reads as a label rather than a
  /// state, which is right -- how someone paid is not good news or bad.
  Widget _modeChip(String mode) {
    if (mode.trim().isEmpty || mode == '-') {
      return Text('—', style: AppUI.muted);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
        decoration: BoxDecoration(
          color: AppColors.tableHeadBg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AppIcon(_modeIcon(mode), size: 13, color: AppColors.textLight),
          SizedBox(width: 6.w),
          Flexible(
            child: Text(mode, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          ),
        ]),
      ),
    );
  }

  Widget _dataRow(Map<String, dynamic> p) {
    final name = (p['stuname']?.toString() ?? '').trim();
    final admno = p['stuadmno']?.toString() ?? '';
    final cls = p['stuclass']?.toString() ?? '';
    final receipt = p['paynumber']?.toString() ?? '';
    final mode = p['paymethod']?.toString() ?? '-';
    final amount = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
    final rawDate = p['paydate']?.toString() ?? '';
    final date = rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;
    final busy = _busyKey == _rowKey(p);
    // Fee and misc receipts share one FCxx/ series, so the number alone does
    // not say which this is -- and the receipt behind them is built from
    // different tables.
    final isMisc = p['mc_id'] != null;
    final isAdvance = p['adv_id'] != null;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
      child: Row(children: [
        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name.isEmpty ? '—' : name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppUI.cell.copyWith(fontWeight: FontWeight.w700)),
          SizedBox(height: 2.h),
          Text([if (admno.isNotEmpty) admno, if (cls.isNotEmpty) cls].join(' • '),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
        ])),
        // The Misc tag lives INSIDE the receipt column, not beside it. As a
        // sibling of the Expanded columns it consumed width on misc rows only,
        // so every column after it sat further right than on a fee row.
        Expanded(flex: 3, child: Row(children: [
          // Misc and Advance DO earn a tag: unlike "pending", they are true of
          // some rows and not others, and they change which table the receipt
          // is built from.
          if (isMisc) ...[
            AppUI.chip('Miscellaneous', AppStatus.info),
            SizedBox(width: 6.w),
          ],
          // Not amber -- amber is the banner's, and a tag that borrows it
          // reads as "this row is the pending one".
          if (isAdvance) ...[
            AppUI.chip('Advance', AppStatus.neutral),
            SizedBox(width: 6.w),
          ],
          Flexible(child: Text(receipt, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppUI.cell.copyWith(color: AppColors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()]))),
        ])),
        Expanded(flex: 2, child: _modeChip(mode)),
        Expanded(flex: 2, child: Text(date,
            style: AppUI.cell.copyWith(color: AppColors.textSecondary, fontFeatures: const [FontFeature.tabularFigures()]))),
        // Dark, not amber. Amber on every amount made the column shout the one
        // thing every row has in common, and made the real variable -- how much
        // -- harder to scan, because 40 highlights highlight nothing. Tabular
        // figures so the digits line up down the column.
        Expanded(flex: 2, child: Text(_inr(amount), textAlign: TextAlign.right,
            style: AppUI.money.copyWith(fontFeatures: const [FontFeature.tabularFigures()]))),
        Expanded(flex: 3, child: Align(
          alignment: Alignment.centerRight,
          child: busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
              : TextButton.icon(
                  onPressed: () => _showReceiptPreview(p),
                  icon: const AppIcon('receipt-2', size: 15, color: AppColors.primary),
                  label: const Text('View Receipt'),
                ),
        )),
      ]),
    );
  }
}
