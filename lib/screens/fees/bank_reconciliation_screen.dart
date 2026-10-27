import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/pill_tab.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:excel/excel.dart' hide Border, BorderStyle;
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/bank_parsers.dart' as parsers;
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../utils/formatters.dart';
import '../../utils/school_terms.dart';

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
  /// Selected rows, keyed 'P:<pay_id>' / 'M:<mc_id>'. A composite key, not a
  /// bare id: fee payments and misc receipts are separate tables with separate
  /// sequences, so pay_id 412 and mc_id 412 both exist and would tick each
  /// other's checkbox -- and worse, approve the wrong receipt.
  final Set<String> _selectedForRecon = {};

  /// Row identity for [_selectedForRecon].
  static String _rowKey(Map<String, dynamic> p) => p['adv_id'] != null
      ? 'A:${p['adv_id']}'
      : p['mc_id'] != null
      ? 'M:${p['mc_id']}'
      : 'P:${p['pay_id']}';

  static bool _isMisc(Map<String, dynamic> p) => p['mc_id'] != null;

  /// An ADVANCE receipt (AD26/...). Taken by cheque, UPI or Paytm it is written
  /// recon_status 'P' exactly as a fee or misc receipt is, so it belongs on this
  /// screen -- before this it was written pending and had nowhere to be settled.
  static bool _isAdvance(Map<String, dynamic> p) => p['adv_id'] != null;

  /// Payment methods whose bank line is identified by a REFERENCE (UTR / txn
  /// id) rather than a cheque number.
  ///
  /// 'Online Transfer' is what a Paytm receipt stores (see
  /// misc_collection_screen._dbPaymode), and leaving it out meant every Paytm
  /// receipt -- fee and misc alike -- was skipped by the reference matcher even
  /// when the statement carried its exact txn id.
  static bool _isRefMatchable(String method) {
    final m = method.toLowerCase().trim();
    return m == 'upi' || m == 'qr_upi' || m == 'razorpay' ||
        m == 'online transfer' || m == 'online' || m == 'paytm';
  }

  /// A statement row counts as matched when it found EITHER a fee receipt or a
  /// misc receipt.
  static bool _rowMatched(Map<String, dynamic> r) =>
      r['matched_pay_id'] != null ||
      r['matched_mc_ids'] != null ||
      r['matched_adv_ids'] != null;
  String _methodFilter = 'All';
  String _selectedBank = 'Auto detect';

  /// What the last uploaded file turned out to be, when the mode was
  /// Auto detect. Shown on the dropdown so the detection is visible after the
  /// snackbar has gone.
  ///
  /// Kept SEPARATE from _selectedBank on purpose: writing 'Paytm' into the
  /// selection would silently switch the control out of Auto detect, and the
  /// next upload — an HDFC statement, say — would then be forced through the
  /// Paytm parser.
  String? _detectedBank;
  int _reconciledPage = 0;
  static const int _reconciledPageSize = 20;
  static const List<String> _bankOptions = ['Auto detect', 'HDFC', 'ICICI', 'SBI', 'IOB', 'Paytm'];

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
      List miscPending = const [];
      List miscReconciled = const [];
      try {
        final rpcResult = await SupabaseService.client.rpc('get_bank_recon_data', params: {'p_ins_id': insId});
        final data = rpcResult as Map<String, dynamic>? ?? {};
        pending = List<Map<String, dynamic>>.from(data['pending'] ?? []);
        reconciled = List<Map<String, dynamic>>.from(data['reconciled'] ?? []);
        miscPending = List<Map<String, dynamic>>.from(data['misc_pending'] ?? []);
        miscReconciled = List<Map<String, dynamic>>.from(data['misc_reconciled'] ?? []);
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
            final students = await SupabaseService.fetchAll(() => SupabaseService
                .fromSchema('students')
                .select('stu_id, stuname, stuadmno')
                .inFilter('stu_id', stuIds));
            for (final s in students) { stuNames[s['stu_id'] as int] = '${s['stuname']} (${s['stuadmno']})'; }
          } catch (_) {}
        }
        for (final p in pending) { p['student_display'] = stuNames[p['stu_id']] ?? 'Student #${p['stu_id']}'; }
        for (final p in reconciled) { p['student_display'] = stuNames[p['stu_id']] ?? 'Student #${p['stu_id']}'; }
      }

      // Misc receipts (BONAFIDE, APPLICATION, …) reconcile through the same
      // screen. They are normalised into the payment row shape so one table
      // renders both; _src marks which table a row came from, and mc_id is
      // what tells the approve path which RPC to call.
      List<Map<String, dynamic>> asMisc(dynamic raw) => [
            for (final m in List<Map<String, dynamic>>.from(raw ?? const []))
              {
                'mc_id': m['mc_id'],
                'paynumber': m['mcno'],
                'transtotalamount': m['totalamount'],
                'paydate': m['mcdate'],
                'paymethod': m['paymode'],
                // transrefno is the UTR the cashier typed; paytm_txnid is what
                // the gateway returned. Either identifies the bank line.
                // paytm_txnid FIRST. A Paytm receipt stores the gateway ORDER id
                // in transrefno (MISC<ins>T<millis>), which appears on no bank
                // statement -- so preferring transrefno meant every Paytm misc
                // receipt showed an unmatchable reference and never reconciled.
                // paytm_txnid is the gateway's own txn id, which is what the
                // statement carries. Falls back to transrefno, the UTR/cheque no
                // a cashier types for non-Paytm modes.
                'payreference': (m['paytm_txnid']?.toString().trim().isNotEmpty ?? false)
                    ? m['paytm_txnid']
                    : m['transrefno'],
                // Kept alongside payreference: for receipts saved before the
                // txn id was stored, transrefno holds the Paytm ORDER id, which
                // is what the settlement file's order_id column carries.
                'transrefno': m['transrefno'],
                'stuname': m['stuname'],
                'stuadmno': m['regno'],
                'stuclass': m['stuclass'],
                'createdby': m['createdby'],
                'recon_status': m['recon_status'],
                'reconciled_by': m['reconciled_by'],
                'reconciled_date': m['reconciled_date'],
                'bank_reference': m['bank_reference'],
                'student_display':
                    '${m['stuname'] ?? ''} (${m['regno'] ?? ''})'.trim(),
                '_src': 'misc',
              }
          ];

      // Absent on a deployment where misc_collection_recon.sql has not been run
      // yet -- the screen then behaves exactly as it did before.
      if (miscPending.isNotEmpty) pending = [...pending, ...asMisc(miscPending)];
      if (miscReconciled.isNotEmpty) {
        reconciled = [...reconciled, ...asMisc(miscReconciled)];
      }

      // Advance receipts, normalised into the same shape. Queried directly
      // rather than through get_bank_recon_data: the advance module is newer
      // than that RPC, and reading the table here keeps one shared function off
      // the critical path of a screen every institution uses.
      List<Map<String, dynamic>> asAdvance(List<Map<String, dynamic>> raw) => [
            for (final a in raw)
              {
                'adv_id': a['adv_id'],
                'paynumber': a['advno'],
                'transtotalamount': a['transtotalamount'],
                'paydate': a['advdate'],
                'paymethod': a['paymethod'],
                // paytm_txnid FIRST, for the same reason as misc: a Paytm
                // advance stores OUR order id in payreference, which appears on
                // no bank statement, while paytm_txnid is what the statement
                // carries.
                'payreference':
                    (a['paytm_txnid']?.toString().trim().isNotEmpty ?? false)
                        ? a['paytm_txnid']
                        : a['payreference'],
                'transrefno': a['payreference'],
                'paychequeno': a['paychequeno'],
                'stuname': a['stuname'],
                'stuadmno': a['stuadmno'],
                'stuclass': a['stuclass'],
                'createdby': a['createdby'],
                'recon_status': a['recon_status'],
                'reconciled_by': a['reconciled_by'],
                'reconciled_date': a['reconciled_date'],
                'bank_reference': a['bank_reference'],
                'student_display':
                    '${a['stuname'] ?? ''} (${a['stuadmno'] ?? ''})'.trim(),
                '_src': 'advance',
              }
          ];
      try {
        const advCols = 'adv_id, advno, advdate, transtotalamount, paymethod, '
            'payreference, paytm_txnid, paychequeno, stuname, stuadmno, stuclass, '
            'createdby, recon_status, reconciled_by, reconciled_date, bank_reference';
        final advPending = await SupabaseService.fromSchema('advance_collection')
            .select(advCols)
            .eq('ins_id', insId)
            .eq('paystatus', 'C')
            .eq('recon_status', 'P')
            .eq('activestatus', 1)
            .order('advdate', ascending: false);
        final advDone = await SupabaseService.fromSchema('advance_collection')
            .select(advCols)
            .eq('ins_id', insId)
            .eq('paystatus', 'C')
            .eq('recon_status', 'R')
            .eq('activestatus', 1)
            .order('reconciled_date', ascending: false)
            .limit(100);
        pending = [
          ...pending,
          ...asAdvance(List<Map<String, dynamic>>.from(advPending as List))
        ];
        reconciled = [
          ...reconciled,
          ...asAdvance(List<Map<String, dynamic>>.from(advDone as List))
        ];
      } catch (e) {
        // Advance module not deployed on this database -- everything else on
        // the screen still works.
        debugPrint('advance receipts unavailable for reconciliation: $e');
      }

      // get_bank_recon_data returns stuname/stuadmno but not the class, and the
      // fallback path does not fetch it either. Filled in here with one lookup
      // rather than by changing an RPC on a live database. Failure is silent:
      // a missing class must not cost the cashier the reconciliation screen.
      final needClass = <int>{
        for (final p in [...pending, ...reconciled])
          if (p['stuclass'] == null && p['stu_id'] is int) p['stu_id'] as int,
      }.toList();
      if (needClass.isNotEmpty) {
        try {
          final rows = await SupabaseService.fetchAll(() => SupabaseService
              .fromSchema('students')
              .select('stu_id, stuclass')
              .inFilter('stu_id', needClass));
          final byId = <int, String>{
            for (final r in rows)
              r['stu_id'] as int: r['stuclass']?.toString() ?? '',
          };
          for (final p in [...pending, ...reconciled]) {
            p['stuclass'] ??= byId[p['stu_id']] ?? '';
          }
        } catch (e) {
          debugPrint('class lookup for bank recon failed: $e');
        }
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
          const SnackBar(content: Text('Bank statement template saved'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
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
                  'This CSV file is ${(size / 1024 / 1024).toStringAsFixed(1)} MB; the limit is 5 MB. Remove older rows and upload it again.'),
              backgroundColor: AppColors.error,
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

      // Paytm dashboard export is a fixed-column, single-quoted settlement file
      // (order_id / amount / settled_date / status ...) — parse it separately.
      //
      // "Auto detect" used to detect nothing. It was a label on a dropdown
      // whose only effect was the Paytm branch below, so choosing it sent a
      // Paytm settlement file through the generic bank-statement reader, which
      // cannot find its columns. Now the file's own header decides.
      var format = _selectedBank;
      if (format == 'Auto detect') {
        final detected = _detectBankFormat(csvString);
        if (mounted) setState(() => _detectedBank = detected);
        if (detected != null) {
          format = detected;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Detected a $detected file.'),
              backgroundColor: AppColors.success,
              duration: const Duration(seconds: 2),
            ));
          }
        }
      }
      if (format == 'Paytm') {
        _parsePaytmStatement(csvString);
        return;
      }

      // Auto-detect delimiter by scanning the first few lines - comma,
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
              content: Text('Could not find the column headings in this file. Check that it has Date, Narration (or Description) and Amount columns, then upload it again.'),
              backgroundColor: AppColors.error,
            ),
          );
        }
        return;
      }

      final headers = allRows[headerRowIdx].map((h) => h.toString().toLowerCase().trim()).toList();
      final rows = allRows.sublist(headerRowIdx);

      // Generic header sniffer - works across HDFC, ICICI, SBI, Axis, Yes,
      // Federal, IOB and most CSV/Excel statements. Picks the FIRST column
      // whose header matches the bank's varied conventions.

      // DATE - Transaction Date / Txn Date / Tran Date / Trans Date /
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

      // REFERENCE / UTR / RRN / Cheque-no - exclude bare "transaction" which
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

      // Single-column-amount banks ship a separate Dr/Cr flag - skip rows
      // marked as debit. Match the common header spellings.
      final drCrIdx = headers.indexWhere((h) =>
          h == 'dr/cr' || h == 'cr/dr' || h == 'type' ||
          h == 'txn type' || h == 'debit/credit' || h == 'credit/debit' ||
          h == 'dr cr' || h == 'cr dr');

      final bankRows = <Map<String, dynamic>>[];
      final usedPayIds = <int>{};

      final usedMcIds = <int>{};
      final usedAdvIds = <int>{};
      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.length < 2) continue;

        // If a separate withdrawal column is populated, skip - it's a debit.
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

            // Misc receipts carry mc_id and never pay_id, and settle through a
            // different RPC. They must be handled here: every branch below keys
            // on pay_id, so a misc row could never match however well its
            // reference lined up.
            if (_isMisc(payment)) {
              final mcId = payment['mc_id'] as int;
              final npr = _normalizeReference(payRef);
              if (usedMcIds.contains(mcId) || npr.isEmpty) continue;
              if (isAmountMatch &&
                  (npr.contains(normalizedBankRef) ||
                      normalizedBankRef.contains(npr))) {
                bankRow['matched_mc_ids'] = [
                  ...((bankRow['matched_mc_ids'] as List<int>?) ?? const <int>[]),
                  mcId,
                ];
                bankRow['match_type'] = 'Transaction ID + Amount Match (Miscellaneous)';
                usedMcIds.add(mcId);
                break;
              }
              continue;
            }

            // An ADVANCE settles through its own table too, so it needs the
            // same treatment: reference plus amount, and never through a
            // pay_id branch it has no id for.
            if (_isAdvance(payment)) {
              final advId = payment['adv_id'] as int;
              final npr = _normalizeReference(
                  payRef.isNotEmpty ? payRef : chequeNo);
              if (usedAdvIds.contains(advId) || npr.isEmpty) continue;
              if (isAmountMatch &&
                  (npr.contains(normalizedBankRef) ||
                      normalizedBankRef.contains(npr))) {
                bankRow['matched_adv_ids'] = [
                  ...((bankRow['matched_adv_ids'] as List<int>?) ?? const <int>[]),
                  advId,
                ];
                bankRow['match_type'] = 'Transaction ID + Amount Match (Advance)';
                usedAdvIds.add(advId);
                break;
              }
              continue;
            }

            // Bank and Razorpay references: reference must match, and the
            // total of all receipts sharing this reference must match the
            // bank amount (handles a single UTR split across multiple
            // receipts the same way cheques are grouped below).
            if (_isRefMatchable(payMethod) &&
                _normalizeReference(payRef).contains(normalizedBankRef)) {
              final refPayments = _pendingPayments
                  .where((p) {
                    final pm = p['paymethod']?.toString() ?? '';
                    final pr = p['payreference']?.toString() ?? '';
                    return _isRefMatchable(pm) &&
                        !_isMisc(p) &&
                        !_isAdvance(p) &&
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
              // Single-receipt fallback - when several payments share the
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
          SnackBar(content: Text('Could not read the CSV file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  /// Parse a Paytm dashboard "reconcile / settlement" CSV. Unlike bank
  /// statements, it has fixed named columns and single-quoted values. Each
  /// SUCCESS row is matched to a pending payment by the order_id (`PAY-<pay_id>`)
  /// plus amount, and the row's `settled_date` becomes the reconciliation date
  /// (settlement date taken FROM the imported file).
  /// Which format the uploaded file actually is, read from its own header.
  ///
  /// Only Paytm is worth detecting: it is the one format with a parser of its
  /// own. HDFC, ICICI, SBI and IOB all go through the same generic CSV reader
  /// with delimiter sniffing, so naming them would change nothing about how
  /// the file is read — the dropdown keeps them for when a file needs forcing.
  ///
  /// The Paytm export quotes every value, including the header, so the quotes
  /// come off before matching. The first few lines are scanned rather than
  /// only the first, because an export can carry a preamble row.
  String? _detectBankFormat(String csvString) {
    final head = csvString
        .split('\n')
        .take(3)
        .join(',')
        .toLowerCase()
        .replaceAll(RegExp(r'''['"]'''), '');
    if (head.contains('order_id') && head.contains('amount')) return 'Paytm';
    return null;
  }

  void _parsePaytmStatement(String csvString) {
    final allRows = CsvToListConverter(
      fieldDelimiter: ',',
      textDelimiter: "'", // Paytm wraps every value in single quotes
      eol: '\n',
      shouldParseNumbers: false,
    ).convert(csvString);
    if (allRows.length < 2) {
      _showError('The Paytm file has no rows. Download the settlement report again and upload it.');
      return;
    }

    String s(dynamic v) {
      var t = v.toString().trim();
      // Paytm wraps values as "'...'" (double- then single-quoted) and the CSV
      // reader leaves the outer quotes as literals — strip any surrounding quote
      // characters so ids/amounts are clean and don't visually merge.
      while (t.length >= 2 &&
          ((t.startsWith('"') && t.endsWith('"')) ||
              (t.startsWith("'") && t.endsWith("'")))) {
        t = t.substring(1, t.length - 1).trim();
      }
      return t;
    }
    final headers = allRows.first.map((h) => s(h).toLowerCase()).toList();
    int col(String n) => headers.indexOf(n);
    final orderIdx = col('order_id');
    final amountIdx = col('amount');
    final statusIdx = col('status');
    final settledIdx = col('settled_date');
    final txnDateIdx = col('transaction_date');
    final utrIdx = col('utr_no');
    final txnIdIdx = col('transaction_id');
    if (orderIdx < 0 || amountIdx < 0) {
      _showError('This is not a Paytm settlement file. Upload the settlement report that has order_id and amount columns.');
      return;
    }

    String cell(List<dynamic> r, int idx) => (idx >= 0 && idx < r.length) ? s(r[idx]) : '';
    final bankRows = <Map<String, dynamic>>[];
    final usedPayIds = <int>{};
    final usedMcIds = <int>{};
    final usedAdvIds = <int>{};

    for (int i = 1; i < allRows.length; i++) {
      final row = allRows[i];
      final status = cell(row, statusIdx).toUpperCase();
      if (status.isNotEmpty && status != 'SUCCESS') continue; // only settled/successful
      final amount = _parseAmount(cell(row, amountIdx));
      if (amount <= 0) continue;

      final orderId = cell(row, orderIdx);
      final settled = cell(row, settledIdx);   // <-- settlement date from the file
      final txnDate = cell(row, txnDateIdx);
      final utr = cell(row, utrIdx);
      final txnId = cell(row, txnIdIdx);
      final m = RegExp(r'PAY-(\d+)', caseSensitive: false).firstMatch(orderId);
      final payId = m != null ? int.tryParse(m.group(1)!) : null;

      final br = <String, dynamic>{
        'date': settled.isNotEmpty ? settled : txnDate,
        // Show/store the Paytm TRANSACTION ID as the reference (matching is still
        // done on the order_id → pay_id below; the txn id is the bank-side ref).
        'reference': txnId.isNotEmpty ? txnId : (utr.isNotEmpty ? utr : orderId),
        'narration': orderId.isEmpty ? 'Paytm' : 'Paytm $orderId',
        'amount': amount,
        'matched_pay_id': null,
        'match_type': '',
      };

      // Find the receipt by the order id the statement carries.
      //
      // Match on payorderid FIRST, and only then fall back to the number
      // inside it. "PAY-2494" does NOT reliably mean pay_id 2494: when a
      // payment is completed by the Paytm-aware recovery the receipt is
      // written as a NEW payment row that carries the ORIGINAL order id
      // across, so PAY-2494's receipt was pay_id 2496 and PAY-2495's was
      // 2497. Parsing the id out of the order id missed both -- real money,
      // sitting pending, reported as "No match". 7 of the 63 completed Paytm
      // receipts on this database disagree that way.
      if (!usedPayIds.contains(payId ?? -1)) {
        Map<String, dynamic> pay = <String, dynamic>{};
        if (orderId.isNotEmpty) {
          pay = _pendingPayments.firstWhere(
            (p) => !_isMisc(p) && !_isAdvance(p) &&
                   (p['payorderid']?.toString().trim() ?? '') == orderId,
            orElse: () => <String, dynamic>{},
          );
        }
        // Older receipts saved before payorderid was stored still need the
        // parsed-id path.
        if (pay.isEmpty && payId != null) {
          pay = _pendingPayments.firstWhere(
            (p) => p['pay_id'] == payId,
            orElse: () => <String, dynamic>{},
          );
        }
        if (pay.isNotEmpty) {
          final payAmount = (pay['transtotalamount'] as num?)?.toDouble() ?? 0;
          if ((payAmount - amount).abs() < 0.01) {
            final matchedId = pay['pay_id'] as int;
            br['matched_pay_id'] = matchedId;
            br['match_type'] = 'Paytm Order + Amount Match';
            usedPayIds.add(matchedId);
          }
        }
      }
      // A MISC receipt can never be found above: that lookup pulls
      // PAY-<pay_id> out of order_id, and a misc order id looks like
      // MISC<ins>T<millis> -- no pay_id, and misc rows have none anyway.
      // Match them on the gateway TXN ID plus amount, falling back to the
      // order id itself for receipts saved before the txn id was stored.
      if (br['matched_pay_id'] == null) {
        final nTxn = _normalizeReference(txnId);
        final nOrder = _normalizeReference(orderId);
        for (final p in _pendingPayments) {
          if (!_isMisc(p)) continue;
          final mcId = p['mc_id'] as int;
          if (usedMcIds.contains(mcId)) continue;
          final pAmt = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
          if ((pAmt - amount).abs() >= 0.01) continue;
          final nRef = _normalizeReference(p['payreference']?.toString() ?? '');
          final nOwn = _normalizeReference(p['transrefno']?.toString() ?? '');
          final hit = (nTxn.isNotEmpty && nRef == nTxn) ||
              (nOrder.isNotEmpty && nOwn.isNotEmpty && nOwn == nOrder);
          if (hit) {
            br['matched_mc_ids'] = <int>[mcId];
            br['match_type'] = 'Paytm Transaction + Amount Match (Miscellaneous)';
            usedMcIds.add(mcId);
            break;
          }
        }
      }
      // An ADVANCE taken through Paytm carries ADV<ins>T<millis> as its order
      // id -- no pay_id either, so it is matched the same way.
      if (br['matched_pay_id'] == null &&
          (br['matched_mc_ids'] as List<int>?) == null) {
        final nTxn = _normalizeReference(txnId);
        final nOrder = _normalizeReference(orderId);
        for (final p in _pendingPayments) {
          if (!_isAdvance(p)) continue;
          final advId = p['adv_id'] as int;
          if (usedAdvIds.contains(advId)) continue;
          final pAmt = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
          if ((pAmt - amount).abs() >= 0.01) continue;
          final nRef = _normalizeReference(p['payreference']?.toString() ?? '');
          final nOwn = _normalizeReference(p['transrefno']?.toString() ?? '');
          final hit = (nTxn.isNotEmpty && nRef == nTxn) ||
              (nOrder.isNotEmpty && nOwn.isNotEmpty && nOwn == nOrder);
          if (hit) {
            br['matched_adv_ids'] = <int>[advId];
            br['match_type'] = 'Paytm Transaction + Amount Match (Advance)';
            usedAdvIds.add(advId);
            break;
          }
        }
      }
      bankRows.add(br);
    }

    setState(() => _bankStatementRows = bankRows);
    _tabController.animateTo(1);
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppColors.error),
      );
    }
  }

  /// Batch reconcile via RPC. Returns the number of payments marked.
  /// Throws on failure -- callers must surface the error, never silently
  /// report success.
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
    if (schema == null) {
      throw StateError('Your institution could not be identified. Log out and log in again.');
    }
    // Deliberately NO direct-table fallback here. anon has no UPDATE grant on
    // payment (money-table lockdown), so a manual UPDATE can only ever fail
    // with 42501. The old fallback swallowed the RPC's real error and then
    // raised that 42501 instead, so every failure looked like a permissions
    // problem on the table no matter what had actually gone wrong. Let the
    // RPC's own error surface.
    return await SupabaseService.reconcilePayments(
      token: context.read<AuthProvider>().sessionToken,
      payIds: payIds, insId: insId, schema: schema, userName: userName,
      bankRef: bankRef, bankDate: isoBankDate);
  }

  Future<void> _reconcileSelected() async {
    if (_selectedForRecon.isEmpty) return;

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final userName = auth.userName ?? 'Admin';
    if (insId == null) return;

    setState(() => _isLoading = true);
    final payIds = <int>[];
    final mcIds = <int>[];
    final advIds = <int>[];
    for (final key in _selectedForRecon) {
      final id = int.tryParse(key.substring(2));
      if (id == null) continue;
      if (key.startsWith('A:')) {
        advIds.add(id);
      } else if (key.startsWith('M:')) {
        mcIds.add(id);
      } else {
        payIds.add(id);
      }
    }

    var count = await _reconcilePaymentsBatch(
      insId: insId,
      userName: userName,
      payIds: payIds,
    );
    count += await _reconcileMiscBatch(
      insId: insId,
      userName: userName,
      mcIds: mcIds,
    );
    count += await _reconcileAdvanceBatch(
      insId: insId,
      userName: userName,
      advIds: advIds,
    );

    _selectedForRecon.clear();
    await _loadPayments();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count payment(s) reconciled successfully'), backgroundColor: AppColors.success),
      );
    }
  }

  /// Mark ADVANCE receipts reconciled. Like misc, an advance has no feedemand
  /// behind it -- the money is held against the student until it is spent -- so
  /// there is no balance to snapshot, only the receipt to settle.
  Future<int> _reconcileAdvanceBatch({
    required int insId,
    required String userName,
    required List<int> advIds,
    String? bankRef,
    String? bankDate,
  }) async {
    if (advIds.isEmpty) return 0;
    try {
      final n = await SupabaseService.client.rpc('reconcile_advance_batch', params: {
        'p_ins_id': insId,
        'p_adv_ids': advIds,
        'p_user': userName,
        'p_bank_ref': bankRef,
        'p_bank_date': _toIsoDate(bankDate),
      });
      return (n as num?)?.toInt() ?? 0;
    } catch (e) {
      // No fallback UPDATE here: anon has no write grant on advance_collection,
      // so a direct update would fail with a bare 42501 the cashier cannot act
      // on. Better to say plainly that the migration has not been run.
      debugPrint('reconcile_advance_batch RPC failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Advances could not be reconciled. ${friendlyError(e)}'),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 6),
        ));
      }
      return 0;
    }
  }

  /// Mark misc receipts reconciled. Separate from the payment batch because a
  /// misc receipt has no feedemand behind it -- there is no balance to
  /// snapshot, only the receipt to settle.
  Future<int> _reconcileMiscBatch({
    required int insId,
    required String userName,
    required List<int> mcIds,
    String? bankRef,
    String? bankDate,
  }) async {
    if (mcIds.isEmpty) return 0;
    try {
      final n = await SupabaseService.client.rpc('reconcile_misc_batch', params: {
        'p_ins_id': insId,
        'p_mc_ids': mcIds,
        'p_user': userName,
        'p_bank_ref': bankRef,
        'p_bank_date': _toIsoDate(bankDate),
      });
      return (n as num?)?.toInt() ?? 0;
    } catch (e) {
      debugPrint('reconcile_misc_batch RPC failed, using fallback: $e');
    }

    // Fallback for a deployment without the RPC. eq('recon_status','P') so a
    // second approval cannot overwrite who settled it the first time.
    final now = DateTime.now().toIso8601String();
    var done = 0;
    for (final id in mcIds) {
      try {
        await SupabaseService.fromSchema('misc_collection').update({
          'recon_status': 'R',
          'reconciled_by': userName,
          'reconciled_date': now,
          if (bankRef != null) 'bank_reference': bankRef,
          if (_toIsoDate(bankDate) != null) 'bank_date': _toIsoDate(bankDate),
        }).eq('mc_id', id).eq('ins_id', insId).eq('recon_status', 'P');
        done++;
      } catch (e) {
        debugPrint('misc reconcile failed for mc_id $id: $e');
      }
    }
    return done;
  }

  Future<void> _reconcileFromBankMatch() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final userName = auth.userName ?? 'Admin';
    if (insId == null) return;

    final matched = _bankStatementRows.where(_rowMatched).toList();
    if (matched.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No matched transactions to reconcile'), backgroundColor: AppColors.warning),
      );
      return;
    }

    setState(() => _isLoading = true);
    int count = 0;
    String? failureMessage;

    // Each statement row settles independently: one failing row must not
    // cancel the rows after it, and whatever DID settle was already committed
    // by its own RPC, so it still has to be reported.
    int failed = 0;
    final firstErrors = <String>[];
    for (final row in matched) {
      // A statement row can settle fee receipts, misc receipts, or both --
      // they go through different RPCs, so each list is handled on its own.
      final payIds = (row['matched_pay_ids'] as List<int>?) ??
          (row['matched_pay_id'] != null
              ? <int>[row['matched_pay_id'] as int]
              : const <int>[]);
      final mcIds = (row['matched_mc_ids'] as List<int>?) ?? const <int>[];
      final advIds = (row['matched_adv_ids'] as List<int>?) ?? const <int>[];
      try {
        if (payIds.isNotEmpty) {
          count += await _reconcilePaymentsBatch(
            insId: insId,
            userName: userName,
            payIds: payIds,
            bankRef: row['reference']?.toString(),
            bankDate: row['date']?.toString(),
          );
        }
        if (mcIds.isNotEmpty) {
          count += await _reconcileMiscBatch(
            insId: insId,
            userName: userName,
            mcIds: mcIds,
            bankRef: row['reference']?.toString(),
            bankDate: row['date']?.toString(),
          );
        }
        if (advIds.isNotEmpty) {
          count += await _reconcileAdvanceBatch(
            insId: insId,
            userName: userName,
            advIds: advIds,
            bankRef: row['reference']?.toString(),
            bankDate: row['date']?.toString(),
          );
        }
      } catch (e) {
        failed++;
        // Raw exception to the console for diagnosis; the snackbar shows the
        // readable form of the first two distinct errors.
        debugPrint('Reconcile failed for ${row['reference']}: $e');
        final shown = friendlyError(e);
        if (firstErrors.length < 2 && !firstErrors.contains(shown)) {
          firstErrors.add(shown);
        }
      }
    }
    if (failed > 0) {
      final settled = count > 0 ? ' $count receipt(s) were reconciled.' : '';
      failureMessage =
          '$failed of ${matched.length} statement row(s) could not be reconciled.$settled '
          'Upload the statement again to retry the rest.\n'
          '${firstErrors.join("\n")}';
    }

    await _loadPayments();
    if (mounted) setState(() => _bankStatementRows.clear());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        failureMessage != null
            ? SnackBar(content: Text(failureMessage), backgroundColor: AppColors.error, duration: const Duration(seconds: 8))
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

  // â”€â”€ Tab 1: Pending Reconciliation â”€â”€
  Widget _buildPendingTab() {
    final filteredPending = _filteredPayments(_pendingPayments);
    return Padding(
      padding: EdgeInsets.zero,
      child: Container(
        decoration: AppUI.card(),
        child: Column(
          children: [
            // Title + actions
            Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8.h),
              child: Row(
                children: [
                  AppIcon.linear('clock', size: 18, color: AppColors.accent),
                  SizedBox(width: 8.w),
                  Text('Pending Payments', style: AppUI.cardTitle),
                  SizedBox(width: 12.w),
                  Text('${_selectedForRecon.length} selected', style: AppUI.muted),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: _selectedForRecon.isEmpty ? null : _reconcileSelected,
                    icon: AppIcon('tick-circle', size: AppBtn.iconSize(context), color: _selectedForRecon.isEmpty ? AppColors.textLight : Colors.white),
                    label: const Text('Reconcile Selected'),
                  ),
                  SizedBox(width: AppBtn.gap(context)),
                  OutlinedButton.icon(
                    onPressed: _loadPayments,
                    icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: AppColors.primary),
                    label: const Text('Refresh'),
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
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: filteredPending.isEmpty
                      ? AppUI.empty(title: 'No pending payments for reconciliation', why: _methodFilter == 'All' ? 'Every collected payment has been reconciled. Use Refresh to check for new ones.' : 'No pending $_methodFilter payments. Change the method filter to see others.', icon: 'clock')
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
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                value: filteredPending.isNotEmpty && filteredPending.every((p) => _selectedForRecon.contains(_rowKey(p))),
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selectedForRecon.addAll(filteredPending.map(_rowKey));
                                    } else {
                                      for (final p in filteredPending) {
                                        _selectedForRecon.remove(_rowKey(p));
                                      }
                                    }
                                  });
                                },
                                activeColor: AppColors.accent,
                              )),
                              Expanded(flex: 2, child: Text('RECEIPT NO', style: AppUI.tableHead)),
                              Expanded(flex: 3, child: Text('STUDENT', style: AppUI.tableHead)),
                              Expanded(flex: 2, child: Text(schoolTerm('CLASS'), style: AppUI.tableHead)),
                              Expanded(flex: 2, child: Text('AMOUNT', textAlign: TextAlign.right, style: AppUI.tableHead)),
                              SizedBox(width: 16.w),
                              Expanded(flex: 2, child: Text('MODE', style: AppUI.tableHead)),
                              Expanded(flex: 2, child: Text('DATE', style: AppUI.tableHead)),
                              Expanded(flex: 2, child: Text('REFERENCE', style: AppUI.tableHead)),
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
                                  final rowKey = _rowKey(p);
                                  final isSelected = _selectedForRecon.contains(rowKey);
                                  return Container(
                                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
                                    color: isSelected ? AppColors.accent.withValues(alpha: 0.05) : (idx.isEven ? Colors.white : AppColors.surface),
                                    child: Row(
                                      children: [
                                        SizedBox(width: 40.w, child: Checkbox(
                                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          visualDensity: VisualDensity.compact,
                                          value: isSelected,
                                          onChanged: (v) {
                                            setState(() {
                                              if (v == true) { _selectedForRecon.add(rowKey); } else { _selectedForRecon.remove(rowKey); }
                                            });
                                          },
                                          activeColor: AppColors.accent,
                                        )),
                                        Expanded(flex: 2, child: Row(children: [
                                          Flexible(child: Text(p['paynumber']?.toString() ?? '-', style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                                          // Fee and misc receipts share one FCxx/ series, so the
                                          // number alone does not say which this is -- and they
                                          // settle through different tables.
                                          if (_isMisc(p)) ...[
                                            SizedBox(width: 6.w),
                                            AppUI.chip('Misc', AppStatus.info),
                                          ],
                                          // An advance carries its own ADxx/ series, but the tag
                                          // still earns its place: it says which table settles it.
                                          if (_isAdvance(p)) ...[
                                            SizedBox(width: 6.w),
                                            AppUI.chip('Advance', AppStatus.warning),
                                          ],
                                        ])),
                                        Expanded(flex: 3, child: Text(p['student_display']?.toString() ?? '-', style: AppUI.cell)),
                                        Expanded(flex: 2, child: Text((p['stuclass']?.toString().trim().isNotEmpty ?? false) ? p['stuclass'].toString() : '-', style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                                        Expanded(flex: 2, child: Text('${formatIndianNumber((p['transtotalamount'] as num?)?.toDouble() ?? 0)}', textAlign: TextAlign.right, style: AppUI.money)),
                                        SizedBox(width: 16.w),
                                        Expanded(flex: 2, child: Text(_rawMethod(p['paymethod']?.toString()), style: AppUI.cell)),
                                        Expanded(flex: 2, child: Text(_formatDate(p['paydate']?.toString()), style: AppUI.cell)),
                                        Expanded(flex: 2, child: Text(p['payreference']?.toString() ?? '-', style: AppUI.cell, overflow: TextOverflow.ellipsis)),
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

  // â”€â”€ Tab 2: Bank Statement Upload â”€â”€
  Widget _buildBankStatementTab() {
    return Padding(
      padding: EdgeInsets.zero,
      child: Container(
        decoration: AppUI.card(),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8.h),
              child: Row(
                children: [
                  AppIcon.linear('document-upload', size: 18, color: AppColors.accent),
                  SizedBox(width: 8.w),
                  Text('Bank Statement', style: AppUI.cardTitle),
                  SizedBox(width: 12.w),
                  if (_bankStatementRows.isNotEmpty) ...[
                Text('${_bankStatementRows.where(_rowMatched).length} matched', style: TextStyle(fontSize: 13.sp, color: AppColors.success, fontWeight: FontWeight.w600)),
                SizedBox(width: 16.w),
                ElevatedButton.icon(
                  onPressed: _reconcileFromBankMatch,
                  icon: AppIcon('tick-circle', size: AppBtn.iconSize(context), color: Colors.white),
                  label: const Text('Reconcile Matched'),
                ),
              ],
              const Spacer(),
              SizedBox(
                height: AppUI.controlHeight(context),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12.w),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedBank,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                      style: AppUI.fieldText(context),
                      items: _bankOptions
                          .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                          .toList(),
                      // The CLOSED control says what was detected; the open
                      // list still offers the plain options. The value stays
                      // 'Auto detect', so the next upload is detected afresh.
                      selectedItemBuilder: (context) => _bankOptions
                          .map((b) => Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  b == 'Auto detect' && _detectedBank != null
                                      ? '$_detectedBank · detected'
                                      : b,
                                  style: TextStyle(
                                      fontSize: 13.sp,
                                      fontWeight: FontWeight.w600,
                                      color: b == 'Auto detect' && _detectedBank != null
                                          ? AppColors.success
                                          : AppColors.textPrimary),
                                ),
                              ))
                          .toList(),
                      onChanged: (v) {
                        // A deliberate choice clears the detection label:
                        // from here on the user's pick is what is used.
                        if (v != null) setState(() { _selectedBank = v; _detectedBank = null; });
                      },
                    ),
                  ),
                ),
              ),
              SizedBox(width: AppBtn.gap(context)),
              ElevatedButton.icon(
                onPressed: _uploadBankStatement,
                icon: AppIcon('document-upload', size: AppBtn.iconSize(context), color: Colors.white),
                label: const Text('Upload Bank Statement (CSV)'),
              ),
              SizedBox(width: AppBtn.gap(context)),
              OutlinedButton.icon(
                onPressed: _downloadSampleTemplate,
                icon: AppIcon('element-4', size: AppBtn.iconSize(context), color: AppColors.primary),
                label: const Text('Download CSV Template'),
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
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.cardBorder),
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
                        SizedBox(width: 52.w, child: Text('S. NO.', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text('DATE', style: AppUI.tableHead)),
                        // flex 3 + a gap: a Paytm txn id is 35 digits, so at flex 2
                        // it was ellipsised hard up against the amount with no
                        // space between the two columns.
                        Expanded(flex: 3, child: Text('REFERENCE/UTR', style: AppUI.tableHead)),
                        SizedBox(width: 12.w),
                        Expanded(flex: 2, child: Text('AMOUNT', textAlign: TextAlign.right, style: AppUI.tableHead)),
                              SizedBox(width: 16.w),
                        Expanded(flex: 2, child: Text('MATCHED WITH', style: AppUI.tableHead)),
                        Expanded(flex: 1, child: Text('MATCH TYPE', style: AppUI.tableHead)),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                        ],
                      ),
                      builder: (context, controller) => _bankStatementRows.isEmpty
                        ? AppUI.empty(
                            title: 'Upload a bank statement CSV to match with pending payments',
                            why: 'No statement loaded yet. Use Upload Bank Statement (CSV) above.',
                            icon: 'cloud-add',
                          )
                        : SingleChildScrollView(
                            controller: controller,
                            child: Column(
                              children: [
                                ..._bankStatementRows.asMap().entries.map((entry) {
                                  final idx = entry.key;
                                  final row = entry.value;
                                  final isMatched = _rowMatched(row);

                                  return Container(
                                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
                                    color: isMatched ? AppColors.success.withValues(alpha: 0.05) : (idx.isEven ? Colors.white : AppColors.surface),
                                    child: Row(
                                      children: [
                                        SizedBox(width: 52.w, child: Text('${idx + 1}', style: AppUI.cell)),
                                        Expanded(flex: 2, child: Text(row['date']?.toString() ?? '-', style: AppUI.cell)),
                                        Expanded(flex: 3, child: Text(row['reference']?.toString() ?? '-', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
                                        SizedBox(width: 12.w),
                                        Expanded(flex: 2, child: Text(formatIndianNumber((row['amount'] as num?)?.toDouble() ?? 0), textAlign: TextAlign.right, style: AppUI.money)),
                                        SizedBox(width: 16.w),
                                        Expanded(
                                          flex: 2,
                                          child: isMatched
                                              ? Builder(builder: (_) {
                                                  final payIds = (row['matched_pay_ids'] as List<int>?) ??
                                                      (row['matched_pay_id'] != null
                                                          ? <int>[row['matched_pay_id'] as int]
                                                          : const <int>[]);
                                                  final mcIds = (row['matched_mc_ids'] as List<int>?) ?? const <int>[];
                                                  final advIds = (row['matched_adv_ids'] as List<int>?) ?? const <int>[];
                                                  final payNos = [
                                                    ...payIds.map((id) {
                                                      final p = _pendingPayments.firstWhere((p) => p['pay_id'] == id, orElse: () => {});
                                                      return p.isNotEmpty ? p['paynumber']?.toString() ?? '$id' : '$id';
                                                    }),
                                                    ...mcIds.map((id) {
                                                      final m = _pendingPayments.firstWhere((p) => p['mc_id'] == id, orElse: () => {});
                                                      return m.isNotEmpty ? m['paynumber']?.toString() ?? '$id' : '$id';
                                                    }),
                                                    ...advIds.map((id) {
                                                      final a = _pendingPayments.firstWhere((p) => p['adv_id'] == id, orElse: () => {});
                                                      return a.isNotEmpty ? a['paynumber']?.toString() ?? '$id' : '$id';
                                                    }),
                                                  ].join(', ');
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

  // â”€â”€ Tab 3: Reconciled Payments â”€â”€
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
        decoration: AppUI.card(),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8.h),
              child: Row(
                children: [
                  AppIcon.linear('tick-square', size: 18, color: AppColors.accent),
                  SizedBox(width: 8.w),
                  Text('Reconciled Payments', style: AppUI.cardTitle),
                  SizedBox(width: 8.w),
                  Text('${filteredReconciled.length} records', style: AppUI.muted),
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
                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: filteredReconciled.isEmpty
            ? AppUI.empty(title: 'No reconciled payments yet', why: 'Payments appear here once they are reconciled from the Pending tab or matched from a bank statement.', icon: 'tick-square')
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
                        SizedBox(width: 52.w, child: Text('S. NO.', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text('RECEIPT NO', style: AppUI.tableHead)),
                        Expanded(flex: 3, child: Text('STUDENT', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text('AMOUNT', textAlign: TextAlign.right, style: AppUI.tableHead)),
                              SizedBox(width: 16.w),
                        Expanded(flex: 2, child: Text('MODE', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text('RECONCILED BY', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text('RECONCILED DATE', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text('BANK REFERENCE', style: AppUI.tableHead)),
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
                                  SizedBox(width: 52.w, child: Text('${globalIdx + 1}', style: AppUI.cell)),
                                  Expanded(flex: 2, child: Text(p['paynumber']?.toString() ?? '-', style: AppUI.cell)),
                                  Expanded(flex: 3, child: Text(p['student_display']?.toString() ?? '-', style: AppUI.cell)),
                                  Expanded(flex: 2, child: Text('${formatIndianNumber((p['transtotalamount'] as num?)?.toDouble() ?? 0)}', textAlign: TextAlign.right, style: AppUI.money)),
                                        SizedBox(width: 16.w),
                                  Expanded(flex: 2, child: Text(_rawMethod(p['paymethod']?.toString()), style: AppUI.cell)),
                                  Expanded(flex: 2, child: Text(p['reconciled_by']?.toString() ?? '-', style: AppUI.cell)),
                                  Expanded(flex: 2, child: Text(_formatDate(p['reconciled_date']?.toString()), style: AppUI.cell)),
                                  Expanded(flex: 2, child: Text(p['bank_reference']?.toString() ?? '-', style: AppUI.cell)),
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
                      decoration: const BoxDecoration(
                        color: AppColors.surface,
                        border: Border(top: BorderSide(color: AppColors.divider)),
                      ),
                      child: Row(
                        children: [
                          Text(AppUI.showing(pageStart + 1, pageEnd, filteredReconciled.length), style: AppUI.muted),
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
      return '${dt.day.toString().padLeft(2, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.year}';
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
  ///   - currency symbols (â‚¹ $ Â£ â‚¬ Rs.)
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

  String _rawMethod(String? rawMethod) {
    final method = (rawMethod ?? '').trim();
    return method.isEmpty ? '-' : method;
  }
}
