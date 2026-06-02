import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/pill_tab.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle;
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/bank_parsers.dart' as parsers;
import '../../utils/friendly_error.dart';
import '../../utils/formatters.dart';
import '../../services/supabase_service.dart';

class BankReconciliationScreen extends StatefulWidget {
  const BankReconciliationScreen({super.key});

  @override
  State<BankReconciliationScreen> createState() => _BankReconciliationScreenState();
}

class _BankReconciliationScreenState extends State<BankReconciliationScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _pendingPayments = [];
  List<Map<String, dynamic>> _reconciledPayments = [];
  List<Map<String, dynamic>> _bankStatementRows = [];
  bool _isLoading = false;
  final Set<int> _selectedForRecon = {};
  String _methodFilter = 'All';
  String _selectedBank = 'Auto detect';
  int _reconciledPage = 0;
  static const int _reconciledPageSize = 20;
  static const List<String> _bankOptions = ['Auto detect', 'HDFC', 'ICICI', 'SBI', 'IOB'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadPayments();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadPayments() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);
    try {
      // Single RPC call for all bank recon data
      List pending;
      List reconciled;
      try {
        final rpcResult = await SupabaseService.client.rpc('get_bank_recon_data', params: {'p_ins_id': insId});
        final data = rpcResult as Map<String, dynamic>? ?? {};
        pending = List<Map<String, dynamic>>.from(data['pending'] ?? []);
        reconciled = List<Map<String, dynamic>>.from(data['reconciled'] ?? []);
        // Build student_display from RPC data (already has stuname, stuadmno)
        for (final p in pending) {
          p['student_display'] = '${p['stuname'] ?? ''} (${p['stuadmno'] ?? ''})'.trim();
          if (p['student_display'] == '()') p['student_display'] = 'Student #${p['stu_id']}';
        }
        for (final p in reconciled) {
          p['student_display'] = '${p['stuname'] ?? ''} (${p['stuadmno'] ?? ''})'.trim();
          if (p['student_display'] == '()') p['student_display'] = 'Student #${p['stu_id']}';
        }
      } catch (e) {
        debugPrint('RPC get_bank_recon_data failed, using fallback: $e');
        // Fallback to direct queries
        final results = await Future.wait([
          SupabaseService.fromSchema('payment')
              .select('pay_id, paynumber, transtotalamount, paydate, paymethod, payreference, paychequeno, payorderid, stu_id, createdby, recon_status')
              .eq('ins_id', insId).eq('paystatus', 'C').eq('recon_status', 'P').eq('activestatus', 1).order('paydate', ascending: false),
          SupabaseService.fromSchema('payment')
              .select('pay_id, paynumber, transtotalamount, paydate, paymethod, payreference, stu_id, createdby, recon_status, reconciled_by, reconciled_date, bank_reference')
              .eq('ins_id', insId).eq('paystatus', 'C').eq('recon_status', 'R').eq('activestatus', 1).order('reconciled_date', ascending: false).limit(100),
        ]);
        pending = results[0]; reconciled = results[1];
        final allPayments = [...pending, ...reconciled];
        final stuIds = allPayments.map((p) => p['stu_id']).toSet().toList();
        Map<int, String> stuNames = {};
        if (stuIds.isNotEmpty) {
          try {
            final students = await SupabaseService.fromSchema('students').select('stu_id, stuname, stuadmno').inFilter('stu_id', stuIds);
            for (final s in students) { stuNames[s['stu_id'] as int] = '${s['stuname']} (${s['stuadmno']})'; }
          } catch (_) {}
        }
        for (final p in pending) { p['student_display'] = stuNames[p['stu_id']] ?? 'Student #${p['stu_id']}'; }
        for (final p in reconciled) { p['student_display'] = stuNames[p['stu_id']] ?? 'Student #${p['stu_id']}'; }
      }

      if (mounted) {
        setState(() {
          _pendingPayments = List<Map<String, dynamic>>.from(pending);
          _reconciledPayments = List<Map<String, dynamic>>.from(reconciled);
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Load payments error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _downloadSampleTemplate() async {
    try {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Bank Statement Template',
        fileName: 'bank_statement_template.csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (result == null) return;

      final csv = 'Date,Narration,Chq/Ref No,Value Date,Withdrawal,Deposit,Balance\n'
          '01/04/2026,UPI/412345678901/STUDENT NAME/SBI,412345678901,01/04/2026,,4200.00,154200.00\n'
          '01/04/2026,NEFT/HDFC001234/PARENT NAME,HDFC001234,01/04/2026,,6100.00,160300.00\n'
          '01/04/2026,CHQ CLG/123456,123456,01/04/2026,,2000.00,162300.00\n';

      await File(result).writeAsString(csv);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Template saved successfully'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _uploadBankStatement() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (result == null || result.files.single.path == null) return;

    try {
      final file = File(result.files.single.path!);

      // Reject anything obviously larger than a real bank statement so a
      // malformed multi-MB file can't lock the UI parsing it.
      const maxBytes = 5 * 1024 * 1024; // 5 MB
      final size = await file.length();
      if (size > maxBytes) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'CSV is ${(size / 1024 / 1024).toStringAsFixed(1)} MB — limit is 5 MB. Please trim the file.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Read bytes and decode robustly: strip UTF-8 / UTF-16 BOM, try UTF-8
      // first, fall back to Latin-1 on decode failure. Covers HDFC/ICICI CSV
      // downloads that arrive as Windows-1252.
      final bytes = await file.readAsBytes();
      String csvString = _decodeBankBytes(bytes);
      csvString = csvString.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

      // Auto-detect delimiter by scanning the first few lines — comma,
      // semicolon, or tab. Some co-op and European bank exports use ';'
      // or '\t' as the field separator.
      final delimiter = _detectDelimiter(csvString);

      final allRows = CsvToListConverter(
        fieldDelimiter: delimiter,
        eol: '\n',
        shouldParseNumbers: false,
      ).convert(csvString);

      // Find the header row. Preamble rows ("Account: 12345", "Statement
      // from...") push the real header below row 0. Accept the first row
      // that has both a date-like column and a particular/narration column.
      final headerRowIdx = _findHeaderRow(allRows);
      if (headerRowIdx < 0 || allRows.length - headerRowIdx < 2) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not find a recognisable header row. Expected columns include Date, Narration/Description, Amount.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final headers = allRows[headerRowIdx].map((h) => h.toString().toLowerCase().trim()).toList();
      final rows = allRows.sublist(headerRowIdx);

      // Generic header sniffer — works across HDFC, ICICI, SBI, Axis, Yes,
      // Federal, IOB and most CSV/Excel statements. Picks the FIRST column
      // whose header matches the bank's varied conventions.

      // DATE — Transaction Date / Txn Date / Tran Date / Trans Date /
      // Posting Date / Posted Date / Date. Prefer the transaction-style
      // variants so a bank that has both "Transaction Date" and "Value Date"
      // doesn't accidentally pick Value Date.
      var dateIdx = headers.indexWhere((h) =>
          h.contains('txn date') || h.contains('transaction date') ||
          h.contains('tran date') || h.contains('trans date') ||
          h.contains('posting date') || h.contains('posted date') ||
          h.contains('post date'));
      if (dateIdx < 0) {
        dateIdx = headers.indexWhere((h) => h.contains('date') && !h.contains('value'));
      }

      // REFERENCE / UTR / RRN / Cheque-no — exclude bare "transaction" which
      // would collide with "Transaction Date".
      final refIdx = headers.indexWhere((h) =>
          h.contains('utr') || h.contains('rrn') ||
          h.contains('chq') || h.contains('cheque') ||
          h.contains('ref no') || h.contains('ref.no') ||
          h.contains('reference') || h.contains('ref ') || h == 'ref' ||
          h.contains('instrument') || h.contains('inst no') || h.contains('inst.no') ||
          h.contains('txn id') || h.contains('txn ref') || h.contains('txn no') ||
          h.contains('transaction id') || h.contains('transaction ref') || h.contains('transaction no'));
      final narrationIdx = headers.indexWhere((h) =>
          h.contains('narration') || h.contains('description') ||
          h.contains('particular') || h.contains('remark') ||
          h.contains('details') || h == 'desc');

      // Distinct Credit / Deposit column. Falls back to a generic Amount
      // column only when no deposit column exists, so banks that have BOTH
      // "Amount" and "Deposit Amt" don't pick the ambiguous Amount column.
      final depositIdx = headers.indexWhere((h) =>
          (h.contains('deposit') || h.contains('credit') ||
           h.contains('cr amount') || h.contains('cr amt') ||
           h.contains('credit amount') || h.contains('credit amt')) &&
          !h.contains('debit'));
      final withdrawalIdx = headers.indexWhere((h) =>
          h.contains('withdrawal') || h.contains('debit') ||
          h.contains('dr amount') || h.contains('dr amt') ||
          h.contains('debit amount') || h.contains('debit amt'));
      final amountIdx = depositIdx >= 0
          ? depositIdx
          : headers.indexWhere((h) =>
              h == 'amount' || h == 'amt' ||
              h.endsWith(' amount') || h.endsWith(' amt') ||
              h.startsWith('amount ') || h.startsWith('amt '));

      // Single-column-amount banks ship a separate Dr/Cr flag — skip rows
      // marked as debit. Match the common header spellings.
      final drCrIdx = headers.indexWhere((h) =>
          h == 'dr/cr' || h == 'cr/dr' || h == 'type' ||
          h == 'txn type' || h == 'debit/credit' || h == 'credit/debit' ||
          h == 'dr cr' || h == 'cr dr');

      final bankRows = <Map<String, dynamic>>[];
      final usedPayIds = <int>{};

      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.length < 2) continue;

        // If a separate withdrawal column is populated, skip — it's a debit.
        if (withdrawalIdx >= 0 && withdrawalIdx < row.length) {
          final w = _parseAmount(row[withdrawalIdx].toString());
          if (w > 0) continue;
        }
        // If a Dr/Cr marker says Dr, skip.
        if (drCrIdx >= 0 && drCrIdx < row.length) {
          final t = row[drCrIdx].toString().trim().toLowerCase();
          if (t == 'dr' || t == 'debit' || t == 'd') continue;
        }

        final amount = amountIdx >= 0 && amountIdx < row.length
            ? _parseAmount(row[amountIdx].toString())
            : 0.0;
        if (amount <= 0) continue; // zero rows, blanks, or unparseable

        bankRows.add({
          'date': dateIdx >= 0 && dateIdx < row.length ? row[dateIdx].toString().trim() : '',
          'reference': refIdx >= 0 && refIdx < row.length ? row[refIdx].toString().trim() : '',
          'narration': narrationIdx >= 0 && narrationIdx < row.length ? row[narrationIdx].toString().trim() : '',
          'amount': amount,
          'matched_pay_id': null,
          'match_type': '',
        });
      }

      // Auto-match: reference and amount must both match
      for (final bankRow in bankRows) {
        final bankRef = (bankRow['reference']?.toString() ?? '').trim();
        final bankNarration = (bankRow['narration']?.toString() ?? '').trim();
        final amount = bankRow['amount'] as double;

        if (bankRef.isEmpty) continue;

        final normalizedBankRef = _normalizeReference(bankRef);
        final normalizedNarration = _normalizeReference(bankNarration);

        // Match only when both reference and amount line up
        if (bankRef.isNotEmpty) {
          for (final payment in _pendingPayments) {
            if (usedPayIds.contains(payment['pay_id'])) continue;
            final payMethod = payment['paymethod']?.toString() ?? '';
            final payRef = payment['payreference']?.toString() ?? '';
            final chequeNo = payment['paychequeno']?.toString() ?? '';
            final payAmount = (payment['transtotalamount'] as num?)?.toDouble() ?? 0;
            final isAmountMatch = (payAmount - amount).abs() < 0.01;

            // Bank and Razorpay references: reference must match, and the
            // total of all receipts sharing this reference must match the
            // bank amount (handles a single UTR split across multiple
            // receipts the same way cheques are grouped below).
            if ((payMethod == 'upi' || payMethod == 'qr_upi' || payMethod == 'razorpay') &&
                _normalizeReference(payRef).contains(normalizedBankRef)) {
              final refPayments = _pendingPayments
                  .where((p) {
                    final pm = p['paymethod']?.toString() ?? '';
                    final pr = p['payreference']?.toString() ?? '';
                    return (pm == 'upi' || pm == 'qr_upi' || pm == 'razorpay') &&
                        !usedPayIds.contains(p['pay_id']) &&
                        _normalizeReference(pr).contains(normalizedBankRef);
                  })
                  .toList();
              final refPayIds = refPayments
                  .map((p) => p['pay_id'] as int)
                  .toList();
              final refTotal = refPayments.fold<double>(
                0,
                (sum, p) => sum + ((p['transtotalamount'] as num?)?.toDouble() ?? 0),
              );

              if ((refTotal - amount).abs() < 0.01 && refPayIds.isNotEmpty) {
                bankRow['matched_pay_id'] = payment['pay_id'];
                bankRow['matched_pay_ids'] = refPayIds;
                final label = payMethod == 'razorpay' ? 'Razorpay' : 'UTR';
                bankRow['match_type'] = refPayIds.length == 1
                    ? '$label + Amount Match'
                    : '$label + Amount Match (${refPayIds.length} receipts)';
                usedPayIds.addAll(refPayIds);
                break;
              }
              // Fall through to single-receipt amount-match for legacy data
              if (isAmountMatch) {
                bankRow['matched_pay_id'] = payment['pay_id'];
                bankRow['match_type'] = payMethod == 'razorpay'
                    ? 'Razorpay + Amount Match'
                    : 'UTR + Amount Match';
                usedPayIds.add(payment['pay_id'] as int);
                break;
              }
            }

            // Cheque: cheque number must match, and total of grouped receipts must match bank amount
            if (payMethod == 'cheque' &&
                chequeNo.isNotEmpty &&
                normalizedBankRef.contains(_normalizeReference(chequeNo))) {
              // Find all payments with this cheque number
              final chequePayments = _pendingPayments
                  .where((p) => p['paychequeno']?.toString() == chequeNo && !usedPayIds.contains(p['pay_id']))
                  .toList();
              final chequePayIds = chequePayments
                  .map((p) => p['pay_id'] as int)
                  .toList();
              final chequeTotal = chequePayments.fold<double>(
                0,
                (sum, p) => sum + ((p['transtotalamount'] as num?)?.toDouble() ?? 0),
              );

              if ((chequeTotal - amount).abs() < 0.01 && chequePayIds.isNotEmpty) {
                bankRow['matched_pay_id'] = payment['pay_id'];
                bankRow['matched_pay_ids'] = chequePayIds;
                bankRow['match_type'] = 'Cheque + Amount Match (${chequePayIds.length} receipts)';
                usedPayIds.addAll(chequePayIds);
                break;
              }
              // Single-receipt fallback — when several payments share the
              // same cheque number but the bank only cleared one of them,
              // match just the receipt whose amount equals the bank line.
              if (isAmountMatch) {
                bankRow['matched_pay_id'] = payment['pay_id'];
                bankRow['match_type'] = 'Cheque + Amount Match';
                usedPayIds.add(payment['pay_id'] as int);
                break;
              }
            }

            // Narration-derived reference also needs amount match
            if (bankNarration.isNotEmpty && payRef.isNotEmpty) {
              final normalizedPayRef = _normalizeReference(payRef);
              if (normalizedPayRef.isNotEmpty &&
                  isAmountMatch &&
                  normalizedNarration.contains(normalizedPayRef)) {
                bankRow['matched_pay_id'] = payment['pay_id'];
                bankRow['match_type'] = 'Narration + Amount Match';
                usedPayIds.add(payment['pay_id'] as int);
                break;
              }
            }
          }
        }
      }

      setState(() => _bankStatementRows = bankRows);
      _tabController.animateTo(1); // Switch to Bank Statement tab
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('CSV could not be read. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Batch reconcile via RPC; falls back to per-row updates if the RPC
  /// is not yet deployed. Returns the number of payments marked.
  Future<int> _reconcilePaymentsBatch({
    required int insId,
    required String userName,
    required List<int> payIds,
    String? bankRef,
    String? bankDate,
  }) async {
    if (payIds.isEmpty) return 0;
    final isoBankDate = _toIsoDate(bankDate);
    final schema = SupabaseService.currentSchema;
    try {
      if (schema != null) {
        final result = await SupabaseService.client.rpc('reconcile_payments_batch', params: {
          'p_schema': schema,
          'p_ins_id': insId,
          'p_pay_ids': payIds,
          'p_user': userName,
          'p_bank_ref': bankRef,
          'p_bank_date': isoBankDate,
        });
        return (result as num?)?.toInt() ?? payIds.length;
      }
    } catch (e) {
      debugPrint('reconcile_payments_batch RPC failed, using fallback: $e');
    }

    final now = DateTime.now().toIso8601String();
    await Future.wait(payIds.map((payId) =>
      SupabaseService.fromSchema('payment').update({
        'recon_status': 'R',
        'reconciled_by': userName,
        'reconciled_date': now,
        if (bankRef != null) 'bank_reference': bankRef,
        if (isoBankDate != null) 'bank_date': isoBankDate,
      }).eq('pay_id', payId).eq('ins_id', insId)
    ));
    try {
      // Resolve affected demands via paymentdetails, NOT feedemand.pay_id:
      // a demand with two partial payments overwrites pay_id with the
      // latest one, so a pay_id-based lookup misses earlier partials.
      final details = await SupabaseService.fromSchema('paymentdetails')
          .select('dem_id')
          .eq('ins_id', insId)
          .inFilter('pay_id', payIds);
      final demIds = (details as List)
          .map((d) => d['dem_id'])
          .where((id) => id != null)
          .toSet()
          .toList();

      for (final demId in demIds) {
        // Recompute reconbalancedue as feeamount - conamount - sum of all
        // reconciled+captured payments on this demand. Matches the
        // reconcile_payments_batch RPC formula so UI fallback and RPC
        // paths converge on the same number.
        final fdRow = await SupabaseService.fromSchema('feedemand')
            .select('feeamount, conamount')
            .eq('dem_id', demId)
            .eq('ins_id', insId)
            .maybeSingle();
        if (fdRow == null) continue;
        final feeAmount = (fdRow['feeamount'] as num?)?.toDouble() ?? 0;
        final conAmount = (fdRow['conamount'] as num?)?.toDouble() ?? 0;

        final reconciledDetails = await SupabaseService.fromSchema('paymentdetails')
            .select('transtotalamount, payment!inner(paystatus, recon_status)')
            .eq('dem_id', demId)
            .eq('ins_id', insId)
            .eq('payment.paystatus', 'C')
            .eq('payment.recon_status', 'R');
        double reconciledTotal = 0;
        for (final r in (reconciledDetails as List)) {
          reconciledTotal += (r['transtotalamount'] as num?)?.toDouble() ?? 0;
        }

        final newReconBal = (feeAmount - conAmount - reconciledTotal).clamp(0.0, double.infinity);
        await SupabaseService.fromSchema('feedemand')
            .update({'reconbalancedue': newReconBal})
            .eq('dem_id', demId)
            .eq('ins_id', insId);
      }
    } catch (e) {
      debugPrint('Fallback feedemand update error: $e');
    }
    return payIds.length;
  }

  Future<void> _reconcileSelected() async {
    if (_selectedForRecon.isEmpty) return;

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final userName = auth.userName ?? 'Admin';
    if (insId == null) return;

    setState(() => _isLoading = true);
    final payIdList = _selectedForRecon.toList();
    final count = await _reconcilePaymentsBatch(
      insId: insId,
      userName: userName,
      payIds: payIdList,
    );

    _selectedForRecon.clear();
    await _loadPayments();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count payment(s) reconciled successfully'), backgroundColor: AppColors.success),
      );
    }
  }

  Future<void> _reconcileFromBankMatch() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final userName = auth.userName ?? 'Admin';
    if (insId == null) return;

    final matched = _bankStatementRows.where((r) => r['matched_pay_id'] != null).toList();
    if (matched.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No matched transactions to reconcile'), backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() => _isLoading = true);
    int count = 0;
    String? failureMessage;

    try {
      // One batch call per bank-statement row (may cover multiple pay_ids).
      for (final row in matched) {
        final payIds = row['matched_pay_ids'] as List<int>? ?? [row['matched_pay_id'] as int];
        count += await _reconcilePaymentsBatch(
          insId: insId,
          userName: userName,
          payIds: payIds,
          bankRef: row['reference']?.toString(),
          bankDate: row['date']?.toString(),
        );
      }
    } catch (e) {
      // Log the raw exception so it shows up in the Flutter run console —
      // friendlyError() collapses unknown errors into "Something went wrong"
      // which makes diagnosis impossible. Both go to the user/log.
      debugPrint('Reconcile from bank statement failed: $e');
      failureMessage = friendlyError(e);
      // Append a short tail of the raw message for the snackbar — keeps the
      // friendly summary but surfaces the actual cause to the user.
      final raw = e.toString();
      final tail = raw.length > 120 ? raw.substring(0, 120) + '…' : raw;
      failureMessage = '$failureMessage\n($tail)';
    }

    await _loadPayments();
    if (mounted) setState(() => _bankStatementRows.clear());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        failureMessage != null
            ? SnackBar(content: Text('Reconcile failed: $failureMessage'), backgroundColor: Colors.red, duration: const Duration(seconds: 8))
            : SnackBar(content: Text('$count payment(s) reconciled from bank statement'), backgroundColor: AppColors.success),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pill-style tabs (matches Fee Collection/Reports)
        ListenableBuilder(
          listenable: _tabController,
          builder: (context, _) {
            final selected = _tabController.index;
            final tabLabels = [
              'Pending (${_pendingPayments.length})',
              'Bank Statement',
              'Reconciled (${_reconciledPayments.length})',
            ];
            final tabIcons = ['clock', 'document-upload', 'tick-square'];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < tabLabels.length; i++) ...[
                      PillTab(
                        icon: tabIcons[i],
                        label: tabLabels[i],
                        selected: selected == i,
                        onTap: () => _tabController.animateTo(i),
                      ),
                      if (i < tabLabels.length - 1) SizedBox(width: PillTab.gap(context)),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
        SizedBox(height: 6.h),

        // Content
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildPendingTab(),
                    _buildBankStatementTab(),
                    _buildReconciledTab(),
                  ],
                ),
        ),
      ],
    );
  }

  // ── Tab 1: Pending Reconciliation ──
  Widget _buildPendingTab() {
    final filteredPending = _filteredPayments(_pendingPayments);
    return Padding(
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            // Title + actions
            Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8.h),
              child: Row(
                children: [
                  AppIcon.linear('clock', size: 18, color: AppColors.accent),
                  SizedBox(width: 8.w),
                  Text('Pending Payments', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  SizedBox(width: 12.w),
                  Text('${_selectedForRecon.length} selected', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                  const Spacer(),
                  SizedBox(
                    height: AppBtn.height(context),
                    child: ElevatedButton.icon(
                      onPressed: _selectedForRecon.isEmpty ? null : _reconcileSelected,
                      icon: AppIcon('tick-circle', size: AppBtn.iconSize(context), color: Colors.white),
                      label: Text('Approve Selected', style: TextStyle(fontSize: 13.sp)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        elevation: 0,
                      ),
                    ),
                  ),
                  SizedBox(width: AppBtn.gap(context)),
                  SizedBox(
                    height: AppBtn.height(context),
                    child: ElevatedButton.icon(
                      onPressed: _loadPayments,
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
            // Table wrapped in inner rounded card
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: filteredPending.isEmpty
                      ? Center(child: Text('No pending payments for reconciliation', style: TextStyle(color: AppColors.textSecondary)))
                      : Column(
                          children: [
                        // Header + rows, sharing a reserved scrollbar lane
                        Expanded(
                          child: AppVerticalScrollbar(
                            header: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                          color: AppColors.tableHeadBg,
                          child: Row(
                            children: [
                              SizedBox(width: 40.w, child: Checkbox(
                                value: filteredPending.isNotEmpty && filteredPending.every((p) => _selectedForRecon.contains(p['pay_id'] as int)),
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selectedForRecon.addAll(filteredPending.map((p) => p['pay_id'] as int));
                                    } else {
                                      for (final p in filteredPending) {
                                        _selectedForRecon.remove(p['pay_id'] as int);
                                      }
                                    }
                                  });
                                },
                                activeColor: AppColors.accent,
                              )),
                              Expanded(flex: 2, child: Text('PAY NO', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                              Expanded(flex: 3, child: Text('STUDENT', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                              Expanded(flex: 2, child: Text('AMOUNT', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                              Expanded(flex: 2, child: Text('METHOD', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                              Expanded(flex: 2, child: Text('DATE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                              Expanded(flex: 2, child: Text('REFERENCE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                              ],
                            ),
                            builder: (context, controller) => SingleChildScrollView(
                            controller: controller,
                            child: Column(
                              children: [
                                ...filteredPending.asMap().entries.map((entry) {
                                  final idx = entry.key;
                                  final p = entry.value;
                                  final payId = p['pay_id'] as int;
                                  final isSelected = _selectedForRecon.contains(payId);
                                  return Container(
                                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
                                    color: isSelected ? AppColors.accent.withValues(alpha: 0.05) : (idx.isEven ? Colors.white : AppColors.surface),
                                    child: Row(
                                      children: [
                                        SizedBox(width: 40.w, child: Checkbox(
                                          value: isSelected,
                                          onChanged: (v) {
                                            setState(() {
                                              if (v == true) { _selectedForRecon.add(payId); } else { _selectedForRecon.remove(payId); }
                                            });
                                          },
                                          activeColor: AppColors.accent,
                                        )),
                                        Expanded(flex: 2, child: Text(p['paynumber']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                        Expanded(flex: 3, child: Text(p['student_display']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                        Expanded(flex: 2, child: Text(formatIndianNumber((p['transtotalamount'] as num?)?.toDouble() ?? 0), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                        Expanded(flex: 2, child: Text(_methodLabel(p['paymethod']?.toString()), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                        Expanded(flex: 2, child: Text(_formatDate(p['paydate']?.toString()), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                        Expanded(flex: 2, child: Text(p['payreference']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis)),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                          ),
                        ),
                      ],
                    ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Tab 2: Bank Statement Upload ──
  Widget _buildBankStatementTab() {
    return Padding(
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8.h),
              child: Row(
                children: [
                  AppIcon.linear('document-upload', size: 18, color: AppColors.accent),
                  SizedBox(width: 8.w),
                  Text('Bank Statement', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  SizedBox(width: 12.w),
                  if (_bankStatementRows.isNotEmpty) ...[
                Text('${_bankStatementRows.where((r) => r['matched_pay_id'] != null).length} matched', style: TextStyle(fontSize: 13.sp, color: AppColors.success, fontWeight: FontWeight.w600)),
                SizedBox(width: 16.w),
                SizedBox(
                  height: AppBtn.height(context),
                  child: ElevatedButton.icon(
                    onPressed: _reconcileFromBankMatch,
                    icon: AppIcon('tick-circle', size: AppBtn.iconSize(context), color: Colors.white),
                    label: Text('Reconcile Matched', style: TextStyle(fontSize: 13.sp)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      foregroundColor: Colors.white,
                      elevation: 0,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              SizedBox(
                height: 40,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12.w),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(10.r),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedBank,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                      items: _bankOptions
                          .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _selectedBank = v);
                      },
                    ),
                  ),
                ),
              ),
              SizedBox(width: AppBtn.gap(context)),
              SizedBox(
                height: AppBtn.height(context),
                child: ElevatedButton.icon(
                  onPressed: _uploadBankStatement,
                  icon: AppIcon('document-upload', size: AppBtn.iconSize(context), color: Colors.white),
                  label: Text('Upload Bank Statement (CSV)', style: TextStyle(fontSize: 13.sp)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                  ),
                ),
              ),
              SizedBox(width: AppBtn.gap(context)),
              SizedBox(
                height: AppBtn.height(context),
                child: ElevatedButton.icon(
                  onPressed: _downloadSampleTemplate,
                  icon: AppIcon('element-4', size: AppBtn.iconSize(context), color: Colors.white),
                  label: Text('Format to Excel', style: TextStyle(fontSize: 13.sp)),
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
        // Table in a rounded card
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  // Table header + rows, sharing a reserved scrollbar lane
                  Expanded(
                    child: AppVerticalScrollbar(
                      header: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        SizedBox(width: 40.w, child: Text('S.NO', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('DATE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('REFERENCE/UTR', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('AMOUNT', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('MATCHED WITH', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 1, child: Text('MATCH TYPE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                        ],
                      ),
                      builder: (context, controller) => _bankStatementRows.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppIcon.linear('cloud-add', size: 48.sp, color: AppColors.textLight),
                                SizedBox(height: 12.h),
                                Text('Upload a bank statement CSV to match with pending payments', style: TextStyle(color: AppColors.textSecondary)),
                              ],
                            ),
                          )
                        : SingleChildScrollView(
                            controller: controller,
                            child: Column(
                              children: [
                                ..._bankStatementRows.asMap().entries.map((entry) {
                                  final idx = entry.key;
                                  final row = entry.value;
                                  final isMatched = row['matched_pay_id'] != null;

                                  return Container(
                                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
                                    color: isMatched ? AppColors.success.withValues(alpha: 0.05) : (idx.isEven ? Colors.white : AppColors.surface),
                                    child: Row(
                                      children: [
                                        SizedBox(width: 40.w, child: Text('${idx + 1}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                        Expanded(flex: 2, child: Text(row['date']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                        Expanded(flex: 2, child: Text(row['reference']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                        Expanded(flex: 2, child: Text(formatIndianNumber((row['amount'] as num?)?.toDouble() ?? 0), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                        Expanded(
                                          flex: 2,
                                          child: isMatched
                                              ? Builder(builder: (_) {
                                                  final payIds = row['matched_pay_ids'] as List<int>? ?? [row['matched_pay_id'] as int];
                                                  final payNos = payIds.map((id) {
                                                    final p = _pendingPayments.firstWhere((p) => p['pay_id'] == id, orElse: () => {});
                                                    return p.isNotEmpty ? p['paynumber']?.toString() ?? '$id' : '$id';
                                                  }).join(', ');
                                                  return Row(
                                                    children: [
                                                      AppIcon('link-1', size: 14, color: AppColors.success),
                                                      SizedBox(width: 4.w),
                                                      Flexible(child: Text(payNos, style: TextStyle(fontSize: 12.sp, color: AppColors.success, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                                                    ],
                                                  );
                                                })
                                              : Text('No match', style: TextStyle(fontSize: 12.sp, color: AppColors.textLight)),
                                        ),
                                        Expanded(
                                          flex: 1,
                                          child: isMatched
                                              ? Text(row['match_type']?.toString() ?? '', style: TextStyle(fontSize: 11.sp, color: AppColors.accent, fontWeight: FontWeight.w500))
                                              : const SizedBox.shrink(),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                      ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
        ),
      ),
    );
  }

  // ── Tab 3: Reconciled Payments ──
  Widget _buildReconciledTab() {
    final filteredReconciled = _filteredPayments(_reconciledPayments);
    // Sort by reconciled_date desc so the newest reconciliations appear first.
    filteredReconciled.sort((a, b) {
      final da = a['reconciled_date']?.toString() ?? '';
      final db = b['reconciled_date']?.toString() ?? '';
      return db.compareTo(da);
    });
    final totalPages = (filteredReconciled.length / _reconciledPageSize).ceil().clamp(1, 9999);
    if (_reconciledPage >= totalPages) _reconciledPage = totalPages - 1;
    final pageStart = _reconciledPage * _reconciledPageSize;
    final pageEnd = (pageStart + _reconciledPageSize).clamp(0, filteredReconciled.length);
    final pageRows = filteredReconciled.isEmpty
        ? const <Map<String, dynamic>>[]
        : filteredReconciled.sublist(pageStart, pageEnd);
    return Padding(
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8.h),
              child: Row(
                children: [
                  AppIcon.linear('tick-square', size: 18, color: AppColors.accent),
                  SizedBox(width: 8.w),
                  Text('Reconciled Payments', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  SizedBox(width: 8.w),
                  Text('${filteredReconciled.length} records', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: filteredReconciled.isEmpty
            ? Center(child: Text('No reconciled payments yet', style: TextStyle(color: AppColors.textSecondary)))
            : Column(
                children: [
                  Expanded(
                    child: AppVerticalScrollbar(
                      header: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        SizedBox(width: 40.w, child: Text('#', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('PAY NO', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 3, child: Text('STUDENT', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('AMOUNT', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('METHOD', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('RECONCILED BY', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('RECONCILED DATE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('BANK REF', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                        ],
                      ),
                      builder: (context, controller) => SingleChildScrollView(
                      controller: controller,
                      child: Column(
                        children: [
                          ...pageRows.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final p = entry.value;
                            final globalIdx = pageStart + idx;
                            return Container(
                              padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
                              color: idx.isEven ? Colors.white : AppColors.surface,
                              child: Row(
                                children: [
                                  SizedBox(width: 40.w, child: Text('${globalIdx + 1}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 2, child: Text(p['paynumber']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 3, child: Text(p['student_display']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 2, child: Text(formatIndianNumber((p['transtotalamount'] as num?)?.toDouble() ?? 0), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 2, child: Text(_methodLabel(p['paymethod']?.toString()), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 2, child: Text(p['reconciled_by']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 2, child: Text(_formatDate(p['reconciled_date']?.toString()), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 2, child: Text(p['bank_reference']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                    ),
                  ),
                  if (filteredReconciled.length > _reconciledPageSize)
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        border: Border(top: BorderSide(color: AppColors.border)),
                      ),
                      child: Row(
                        children: [
                          Text('${pageStart + 1}–$pageEnd of ${filteredReconciled.length}',
                              style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.chevron_left),
                            onPressed: _reconciledPage > 0 ? () => setState(() => _reconciledPage--) : null,
                          ),
                          Text('Page ${_reconciledPage + 1} of $totalPages',
                              style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                          IconButton(
                            icon: const Icon(Icons.chevron_right),
                            onPressed: _reconciledPage < totalPages - 1 ? () => setState(() => _reconciledPage++) : null,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '-';
    try {
      final dt = DateTime.parse(dateStr);
      return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    } catch (_) {
      return dateStr;
    }
  }

  String _normalizeReference(String value) => parsers.normalizeReference(value);

  String? _toIsoDate(String? raw) => parsers.toIsoDate(raw);

  String _decodeBankBytes(List<int> bytes) => parsers.decodeBankBytes(bytes);

  String _detectDelimiter(String text) => parsers.detectDelimiter(text);

  int _findHeaderRow(List<List<dynamic>> rows) => parsers.findHeaderRow(rows);

  /// Parse an amount cell. Handles:
  ///   - thousand separators ("1,200.00", "1.200,00" European style)
  ///   - currency symbols (₹ $ £ € Rs.)
  ///   - trailing Dr/Cr suffix ("1,200.00 Cr")
  ///   - accounting parentheses for negatives ("(1,200.00)" -> -1200)
  ///   - non-breaking spaces
  double _parseAmount(String raw) => parsers.parseAmount(raw);

  List<Map<String, dynamic>> _filteredPayments(List<Map<String, dynamic>> payments) {
    if (_methodFilter == 'All') return payments;
    return payments.where((payment) => _methodCategory(payment['paymethod']?.toString()) == _methodFilter).toList();
  }

  String _methodCategory(String? rawMethod) {
    final method = (rawMethod ?? '').toLowerCase().trim();
    if (method == 'cash') return 'Cash';
    if (method == 'razorpay') return 'Razorpay';
    return 'Bank';
  }

  String _methodLabel(String? rawMethod) {
    final method = (rawMethod ?? '').toLowerCase().trim();
    switch (method) {
      case 'cash':
        return 'Cash';
      case 'razorpay':
        return 'Razorpay';
      case 'upi':
      case 'qr_upi':
        return 'Bank';
      case 'cheque':
        return 'Bank';
      case 'online':
        return 'Bank';
      default:
        return method.isEmpty ? '-' : _methodCategory(method);
    }
  }
}
