import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';

/// Fee Refund — raise a refund against a fee-collection receipt. Look up a
/// student, pick one of their receipts, then enter a Refund Amount (and an
/// optional Adjustment Amount + reason) per fee line. Saving:
///   1. writes a fee_refund voucher (+ fee_refunddetails lines),
///   2. adds the total to payment.refund_amount and marks the receipt 'R',
///   3. re-opens each refunded demand (reduces paidamount / raises balancedue)
///      so the amount shows as owed again.
///
/// Adapted to the college course/class model (course/courname + class/claname);
/// the reference used the school clagrp/clagrpname model.
class FeeRefundScreen extends StatefulWidget {
  const FeeRefundScreen({super.key});

  @override
  State<FeeRefundScreen> createState() => _FeeRefundScreenState();
}

/// One refundable fee line taken from the selected receipt.
class _RefundRow {
  final int demId;
  final String term;
  final String feeType;
  final String feeGroup;
  final double feeAmount; // amount originally collected on this line (the ceiling)
  final TextEditingController refundCtrl;
  final TextEditingController adjustCtrl;
  final TextEditingController reasonCtrl;

  _RefundRow({
    required this.demId,
    required this.term,
    required this.feeType,
    required this.feeGroup,
    required this.feeAmount,
  })  : refundCtrl = TextEditingController(),
        adjustCtrl = TextEditingController(),
        reasonCtrl = TextEditingController();

  double get refund {
    final v = double.tryParse(refundCtrl.text.trim()) ?? 0;
    if (v < 0) return 0;
    return v > feeAmount ? feeAmount : v;
  }

  double get adjust {
    final v = double.tryParse(adjustCtrl.text.trim()) ?? 0;
    if (v < 0) return 0;
    final max = feeAmount - refund;
    return v > max ? (max < 0 ? 0 : max) : v;
  }

  void dispose() {
    refundCtrl.dispose();
    adjustCtrl.dispose();
    reasonCtrl.dispose();
  }
}

class _FeeRefundScreenState extends State<FeeRefundScreen> {
  final _searchCtrl = TextEditingController();
  final _bankRefCtrl = TextEditingController();
  final _accountCodeCtrl = TextEditingController();
  final _refundReasonCtrl = TextEditingController();

  Map<String, dynamic>? _student;
  List<Map<String, dynamic>> _suggestions = [];
  List<Map<String, dynamic>> _filteredStudents = [];

  // Filter-by-class state (Course = clagrp, Class = section in the school model).
  List<Map<String, dynamic>> _courseList = [];
  List<Map<String, dynamic>> _classList = [];
  String? _selectedCourse;
  String? _selectedClass;

  // Receipts of the selected student + the fee lines of the chosen receipt.
  List<Map<String, dynamic>> _receipts = [];
  int? _selectedPayId;
  List<_RefundRow> _rows = [];

  // Refund header fields.
  DateTime _refundDate = DateTime.now();
  int? _docNo;
  String _refundMode = 'Cash';
  List<Map<String, dynamic>> _banks = [];
  int? _selectedBanId;
  DateTime? _chequeDate;

  bool _searching = false, _loading = false, _loadingLines = false, _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCoursesClasses();
    _loadBanks();
    _loadDocNo();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _bankRefCtrl.dispose();
    _accountCodeCtrl.dispose();
    _refundReasonCtrl.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  // ── masters / init loads ──────────────────────────────────────────────────
  Future<void> _loadCoursesClasses() async {
    try {
      final results = await Future.wait<dynamic>([
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', _insId).eq('activestatus', 1).order('ordid', ascending: true).order('courname', ascending: true),
        SupabaseService.fromSchema('class').select('claname, cour_id, ordid').eq('ins_id', _insId).eq('activestatus', 1).order('ordid', ascending: true).order('claname', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _courseList = List<Map<String, dynamic>>.from(results[0] as List);
        _classList = List<Map<String, dynamic>>.from(results[1] as List);
      });
    } catch (_) {}
  }

  Future<void> _loadBanks() async {
    try {
      final res = await SupabaseService.getBanks();
      if (mounted) setState(() => _banks = res);
    } catch (_) {}
  }

  Future<void> _loadDocNo() async {
    try {
      final res = await SupabaseService.fromSchema('fee_refund')
          .select('doc_no')
          .eq('ins_id', _insId)
          .order('doc_no', ascending: false)
          .limit(1)
          .maybeSingle();
      final next = ((res?['doc_no'] as num?)?.toInt() ?? 0) + 1;
      if (mounted) setState(() => _docNo = next);
    } catch (_) {
      if (mounted) setState(() => _docNo = 1);
    }
  }

  List<String> get _courseNames =>
      (_courseList.map((e) => e['courname']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList());

  List<String> _classNamesFor(String? courseName) {
    Iterable<Map<String, dynamic>> src = _classList;
    if (courseName != null && courseName.trim().isNotEmpty) {
      final crs = _courseList.firstWhere(
        (c) => (c['courname']?.toString().trim() ?? '') == courseName.trim(),
        orElse: () => const {},
      );
      final courId = crs['cour_id'];
      src = courId == null ? const <Map<String, dynamic>>[] : _classList.where((cl) => cl['cour_id'] == courId);
    }
    return (src.map((e) => e['claname']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList());
  }

  Future<void> _loadFromFilter() async {
    if (_selectedCourse == null && _selectedClass == null) {
      if (mounted) setState(() => _filteredStudents = []);
      return;
    }
    try {
      var query = SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname')
          .eq('ins_id', _insId)
          .eq('activestatus', 1);
      if (_selectedCourse != null) query = query.eq('courname', _selectedCourse!);
      if (_selectedClass != null) query = query.eq('stuclass', _selectedClass!);
      final rows = await query.order('stuname', ascending: true).limit(500);
      if (mounted) setState(() => _filteredStudents = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  // ── student lookup ────────────────────────────────────────────────────────
  Future<void> _suggest(String q) async {
    final term = q.trim();
    if (term.length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    try {
      final rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .or('stuadmno.ilike.$term%,stuname.ilike.%$term%')
          .order('stuname', ascending: true)
          .limit(200);
      if (mounted) setState(() => _suggestions = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  void _pick(Map<String, dynamic> s) {
    _searchCtrl.text = s['stuadmno']?.toString() ?? '';
    setState(() => _suggestions = []);
    _load(s);
  }

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _suggestions = [];
    });
    try {
      var rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname')
          .eq('ins_id', _insId)
          .eq('stuadmno', q)
          .eq('activestatus', 1)
          .limit(1);
      if ((rows as List).isEmpty) {
        rows = await SupabaseService.fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, courname')
            .eq('ins_id', _insId)
            .eq('activestatus', 1)
            .ilike('stuname', '%$q%')
            .limit(1);
      }
      if ((rows as List).isEmpty) {
        setState(() {
          _error = 'No student found matching "$q"';
          _searching = false;
          _student = null;
        });
        return;
      }
      await _load(Map<String, dynamic>.from(rows.first as Map));
    } catch (e) {
      setState(() {
        _error = friendlyError(e);
        _searching = false;
      });
    }
  }

  /// Select a student and load their refundable receipts.
  Future<void> _load(Map<String, dynamic> student) async {
    setState(() {
      _searching = false;
      _loading = true;
      _student = student;
      _receipts = [];
      _selectedPayId = null;
      _clearRows();
    });
    try {
      // Show ALL of the student's collected receipts — query payment directly by
      // stu_id. (The old feedemand.pay_id derivation missed receipts: a demand
      // only stores its LATEST payment's pay_id, and demands no longer paidstatus
      // 'P' dropped out entirely.) 'C' = collected, 'R' = partially refunded.
      final stuId = student['stu_id'];
      var receipts = <Map<String, dynamic>>[];
      if (stuId != null) {
        final res = await SupabaseService.fromSchema('payment')
            .select('pay_id, paynumber, paydate, transtotalamount, paymethod, paystatus, refund_amount')
            .eq('ins_id', _insId)
            .eq('stu_id', stuId)
            .inFilter('paystatus', ['C', 'R'])
            .eq('activestatus', 1)
            .order('paydate', ascending: false);
        receipts = List<Map<String, dynamic>>.from(res as List);
        // Drop receipts with nothing left to refund (already fully refunded).
        // A partially-refunded receipt still has a balance, so it stays.
        receipts = receipts.where((r) {
          final total = (r['transtotalamount'] as num?)?.toDouble() ?? 0;
          final refunded = (r['refund_amount'] as num?)?.toDouble() ?? 0;
          return total - refunded > 0.009;
        }).toList();
      }
      if (!mounted) return;
      setState(() {
        _receipts = receipts;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  /// Load the fee lines of the chosen receipt into the grid.
  Future<void> _onReceiptSelected(int payId) async {
    setState(() {
      _selectedPayId = payId;
      _loadingLines = true;
      _clearRows();
    });
    try {
      final lines = await SupabaseService.getFeeDetailsByPayId(payId, insId: _insId);
      final rows = lines.map((m) {
        // Fee Amt = amount actually collected in this receipt (partial-safe),
        // falling back to paidamount then feeamount.
        final collected = (m['collectedamount'] as num?)?.toDouble()
            ?? (m['paidamount'] as num?)?.toDouble()
            ?? (m['feeamount'] as num?)?.toDouble()
            ?? 0;
        return _RefundRow(
          demId: (m['dem_id'] as num?)?.toInt() ?? 0,
          term: m['demfeeterm']?.toString() ?? '',
          feeType: m['demfeetype']?.toString() ?? '',
          feeGroup: m['feegroupname']?.toString() ?? '',
          feeAmount: collected,
        );
      }).toList();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loadingLines = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingLines = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  double get _totalCollected => _rows.fold(0.0, (s, r) => s + r.feeAmount);
  double get _totalRefund => _rows.fold(0.0, (s, r) => s + r.refund);
  double get _totalAdjust => _rows.fold(0.0, (s, r) => s + r.adjust);

  // ── save ──────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (_student == null) {
      _popup('Student Required', 'Search and select a student first.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }
    if (_selectedPayId == null) {
      _popup('Receipt Required', 'Select the receipt to refund against.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }
    final lines = _rows.where((r) => r.refund > 0 || r.adjust > 0).toList();
    if (lines.isEmpty) {
      _popup('Nothing to Refund', 'Enter a Refund Amount (or Adjustment) on at least one fee line.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }

    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    final totalRefund = _totalRefund;
    final totalAdjust = _totalAdjust;
    final receipt = _receipts.firstWhere((r) => (r['pay_id'] as num?)?.toInt() == _selectedPayId, orElse: () => const {});

    setState(() => _saving = true);
    try {
      // Build the header + detail maps once; run atomically via the
      // session-gated process_refund RPC (ins_id derived server-side), with a
      // token-less direct fallback for safety.
      final header = <String, dynamic>{
        'doc_no': _docNo,
        'ins_id': insId,
        'inscode': auth.inscode,
        'yrlabel': auth.yearLabel,
        'refunddate': _refundDate.toIso8601String().split('T').first,
        'pay_id': _selectedPayId,
        'paynumber': receipt['paynumber'],
        'stu_id': _student!['stu_id'],
        'stuadmno': _student!['stuadmno'],
        'stuname': _student!['stuname'],
        'stuclass': _student!['stuclass'],
        'refundmode': _refundMode,
        'ban_id': _selectedBanId,
        'bankname': _selectedBanId == null ? null : (_banks.firstWhere((b) => b['ban_id'] == _selectedBanId, orElse: () => const {})['banname']),
        'bankref': _bankRefCtrl.text.trim().isEmpty ? null : _bankRefCtrl.text.trim(),
        'chequedate': _chequeDate?.toIso8601String().split('T').first,
        'accountcode': _accountCodeCtrl.text.trim().isEmpty ? null : _accountCodeCtrl.text.trim(),
        'refundreason': _refundReasonCtrl.text.trim().isEmpty ? null : _refundReasonCtrl.text.trim(),
        'totalrefund': totalRefund,
        'totaladjust': totalAdjust,
        'createdby': auth.userName,
        'activestatus': 1,
      };
      final refundLines = lines
          .map((r) => {
                'dem_id': r.demId,
                'refundterm': r.term,
                'refundfeetype': r.feeType,
                'feeamount': r.feeAmount,
                'refundamount': r.refund,
                'adjustamount': r.adjust,
                'adjustreason': r.reasonCtrl.text.trim().isEmpty ? null : r.reasonCtrl.text.trim(),
                'activestatus': 1,
              })
          .toList();

      final token = auth.sessionToken;
      if (token != null && token.isNotEmpty) {
        await SupabaseService.client.rpc('process_refund', params: {
          'p_token': token, 'p_header': header, 'p_lines': refundLines,
        });
      } else {
        // Legacy direct path (token-less safety fallback).
        final hdr = await SupabaseService.fromSchema('fee_refund').insert(header).select('rf_id').single();
        final rfId = (hdr['rf_id'] as num).toInt();
        await SupabaseService.fromSchema('fee_refunddetails')
            .insert(refundLines.map((l) => {...l, 'rf_id': rfId}).toList());
        final existingRefund = (receipt['refund_amount'] as num?)?.toDouble() ?? 0;
        await SupabaseService.fromSchema('payment').update({
          'refund_amount': existingRefund + totalRefund,
          'paystatus': 'R',
        }).eq('pay_id', _selectedPayId as Object);
        for (final r in lines) {
          if (r.refund <= 0) continue;
          final dem = await SupabaseService.fromSchema('feedemand')
              .select('paidamount, balancedue, reconbalancedue')
              .eq('dem_id', r.demId)
              .maybeSingle();
          if (dem == null) continue;
          final paidNow = (dem['paidamount'] as num?)?.toDouble() ?? 0;
          final balNow = (dem['balancedue'] as num?)?.toDouble() ?? 0;
          final reconNow = (dem['reconbalancedue'] as num?)?.toDouble() ?? balNow;
          final newPaid = (paidNow - r.refund).clamp(0, double.infinity);
          final newBal = balNow + r.refund;
          await SupabaseService.fromSchema('feedemand').update({
            'paidamount': newPaid,
            'balancedue': newBal,
            'reconbalancedue': reconNow + r.refund,
            'paidstatus': newBal > 0 ? 'U' : 'P',
          }).eq('dem_id', r.demId);
        }
      }

      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Refund saved for ${_student!['stuname']} • total ₹${totalRefund.toStringAsFixed(2)}.', AppColors.success);
      _newRecord();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _popup('Save Failed', friendlyError(e), AppColors.error, Icons.error_outline);
      }
    }
  }

  void _clearRows() {
    for (final r in _rows) {
      r.dispose();
    }
    _rows = [];
  }

  Future<void> _newRecord() async {
    setState(() {
      _searchCtrl.clear();
      _bankRefCtrl.clear();
      _accountCodeCtrl.clear();
      _refundReasonCtrl.clear();
      _student = null;
      _suggestions = [];
      _filteredStudents = [];
      _selectedCourse = null;
      _selectedClass = null;
      _receipts = [];
      _selectedPayId = null;
      _clearRows();
      _refundDate = DateTime.now();
      _refundMode = 'Cash';
      _selectedBanId = null;
      _chequeDate = null;
      _error = null;
    });
    await _loadDocNo();
  }

  Future<void> _pickDate({required DateTime initial, required ValueChanged<DateTime> onPicked}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) onPicked(picked);
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  void _popup(String title, String message, Color color, IconData icon) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
        ]),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: TextButton.styleFrom(foregroundColor: color),
            child: const Text('OK', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // ── field styling (matches Fee Concession) ────────────────────────────────
  InputDecoration _fieldDec(String hint, {Widget? prefixIcon, Widget? suffixIcon}) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final textSize = compact ? 11.0 : 14.0;
    final hPad = compact ? 8.0 : 14.0;
    final vPad = compact ? 5.0 : 14.0;
    final radius = compact ? 5.0 : 8.0;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: textSize),
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      contentPadding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.accent)),
      filled: true,
      fillColor: Colors.white,
      isDense: true,
    );
  }

  TextStyle _fieldTextStyle() {
    final compact = MediaQuery.of(context).size.width <= 1366;
    return TextStyle(fontWeight: FontWeight.w500, fontSize: compact ? 11 : 14, color: AppColors.textPrimary);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              _lookup(),
              if (_student != null) ...[
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(16.w, 4.h, 16.w, 8.h),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _refundForm(),
                        SizedBox(height: 12.h),
                        _gridCard(),
                      ],
                    ),
                  ),
                ),
                _footer(),
              ] else
                Expanded(
                  child: Center(
                    child: Text(_error ?? 'Search a student by Admission No or Name',
                        style: TextStyle(fontSize: 13.sp, color: _error != null ? AppColors.error : AppColors.textSecondary)),
                  ),
                ),
            ],
          ),
          if (_suggestions.isNotEmpty) _suggestionsOverlay(),
        ],
      ),
    );
  }

  Widget _header() => Padding(
        padding: EdgeInsets.fromLTRB(18.w, 14.h, 18.w, 10.h),
        child: Row(children: [
          const AppIcon('receipt-2', size: 20, color: AppColors.primary),
          SizedBox(width: 10.w),
          Text('Fee Refund', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(width: 10.w),
          Text('refund a fee-collection receipt', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          SizedBox(
            width: 280.w,
            child: TextField(
              controller: _searchCtrl,
              style: _fieldTextStyle(),
              decoration: _fieldDec(
                'Admission No or Student Name',
                prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.textLight),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 16, color: AppColors.textLight),
                        splashRadius: 14,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _suggestions = []);
                        },
                      ),
              ),
              onChanged: _suggest,
              onSubmitted: (_) => _search(),
            ),
          ),
          SizedBox(width: 10.w),
          Builder(builder: (context) {
            final compact = MediaQuery.of(context).size.width <= 1366;
            return SizedBox(
              height: compact ? 30.0 : 40.0,
              child: ElevatedButton.icon(
                onPressed: _searching ? null : _newRecord,
                icon: AppIcon('refresh', size: compact ? 12.0 : 16.0, color: Colors.white),
                label: const Text('New'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: EdgeInsets.symmetric(horizontal: compact ? 10.0 : 18.0),
                  textStyle: TextStyle(fontSize: compact ? 11.0 : 13.0, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(compact ? 6.0 : 10.0)),
                ),
              ),
            );
          }),
        ]),
      );

  Widget _lookup() => Padding(
        padding: EdgeInsets.fromLTRB(18.w, 0, 18.w, 12.h),
        child: Row(children: [
          SizedBox(
            width: 200.w,
            child: DropdownButtonFormField<String>(
              initialValue: _courseNames.contains(_selectedCourse) ? _selectedCourse : null,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              style: _fieldTextStyle(),
              decoration: _fieldDec('Select Course'),
              items: _courseNames.map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setState(() {
                _selectedCourse = v;
                if (_selectedClass != null && !_classNamesFor(v).contains(_selectedClass)) _selectedClass = null;
                _loadFromFilter();
              }),
            ),
          ),
          SizedBox(width: 10.w),
          SizedBox(
            width: 180.w,
            child: DropdownButtonFormField<String>(
              initialValue: _classNamesFor(_selectedCourse).contains(_selectedClass) ? _selectedClass : null,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              style: _fieldTextStyle(),
              decoration: _fieldDec('Select Class'),
              items: _classNamesFor(_selectedCourse).map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setState(() {
                _selectedClass = v;
                _loadFromFilter();
              }),
            ),
          ),
          SizedBox(width: 10.w),
          SizedBox(
            width: 220.w,
            child: DropdownButtonFormField<String>(
              initialValue: () {
                final id = _student?['stu_id']?.toString();
                return _filteredStudents.any((s) => s['stu_id']?.toString() == id) ? id : null;
              }(),
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              style: _fieldTextStyle(),
              decoration: _fieldDec('Select Student'),
              items: _filteredStudents
                  .map((s) => DropdownMenuItem(value: s['stu_id']?.toString(), child: Text('${s['stuname']} • ${s['stuadmno']}', overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: _filteredStudents.isEmpty
                  ? null
                  : (v) {
                      if (v == null) return;
                      final picked = _filteredStudents.firstWhere((e) => e['stu_id']?.toString() == v, orElse: () => const {});
                      if (picked.isNotEmpty) _pick(picked);
                    },
            ),
          ),
          const Spacer(),
          if (_student != null) _studentChip(),
        ]),
      );

  Widget _suggestionsOverlay() => Positioned(
        top: 56.h,
        right: 120.w,
        width: 280.w,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(8.r),
          child: Container(
            constraints: BoxConstraints(maxHeight: 420.h),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8.r), border: Border.all(color: AppColors.border)),
            child: Scrollbar(
              thumbVisibility: true,
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _suggestions.length,
                itemBuilder: (_, i) {
                  final s = _suggestions[i];
                  return InkWell(
                    onTap: () => _pick(s),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                      child: Row(children: [
                        Expanded(child: Text('${s['stuname']} • ${s['stuadmno']}', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary))),
                        Text(s['stuclass']?.toString() ?? '', style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

  Widget _studentChip() {
    final s = _student!;
    final name = s['stuname']?.toString() ?? '';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 32.w,
          height: 32.w,
          decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(8.r)),
          alignment: Alignment.center,
          child: Text(initial, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
        SizedBox(width: 10.w),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(name, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(height: 2.h),
          Text('Adm No: ${s['stuadmno']}  •  ${s['stuclass'] ?? ''}', style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
        ]),
      ]),
    );
  }

  // ── refund header form ────────────────────────────────────────────────────
  Widget _labeled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600, color: AppColors.textLight)),
          SizedBox(height: 4.h),
          child,
        ],
      );

  Widget _radioChip(String m) {
    final selected = _refundMode == m;
    return Padding(
      padding: EdgeInsets.only(right: 10.w),
      child: InkWell(
        onTap: () => setState(() => _refundMode = m),
        borderRadius: BorderRadius.circular(8.r),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 16.w,
            height: 16.w,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? AppColors.accent : AppColors.border, width: 2),
            ),
            child: selected
                ? Center(child: Container(width: 8.w, height: 8.w, decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.accent)))
                : null,
          ),
          SizedBox(width: 6.w),
          Text(m, style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
        ]),
      ),
    );
  }

  Widget _dateBox(DateTime? value, String hint, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8.r),
        child: InputDecorator(
          decoration: _fieldDec(hint, suffixIcon: const Icon(Icons.calendar_today, size: 15, color: AppColors.textSecondary)),
          child: Text(
            value == null ? hint : '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}',
            style: TextStyle(fontSize: 13.sp, color: value == null ? AppColors.textLight : AppColors.textPrimary),
          ),
        ),
      );

  Widget _refundForm() {
    final bankRow = _refundMode != 'Cash';
    return Container(
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 2,
              child: _labeled('Receipt No', DropdownButtonFormField<int>(
                initialValue: _selectedPayId,
                isExpanded: true,
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(12),
                elevation: 6,
                style: _fieldTextStyle(),
                decoration: _fieldDec(_receipts.isEmpty ? 'No receipts found' : 'Select receipt'),
                items: _receipts.map((r) {
                  final no = r['paynumber']?.toString() ?? '—';
                  final amt = (r['transtotalamount'] as num?)?.toDouble() ?? 0;
                  final date = r['paydate']?.toString().split('T').first ?? '';
                  return DropdownMenuItem(value: (r['pay_id'] as num?)?.toInt(), child: Text('$no  •  ₹${amt.toStringAsFixed(0)}  •  $date', overflow: TextOverflow.ellipsis));
                }).toList(),
                onChanged: _receipts.isEmpty ? null : (v) { if (v != null) _onReceiptSelected(v); },
              )),
            ),
            SizedBox(width: 12.w),
            Expanded(child: _labeled('Refund Date', _dateBox(_refundDate, 'Refund Date', () => _pickDate(initial: _refundDate, onPicked: (d) => setState(() => _refundDate = d))))),
            SizedBox(width: 12.w),
            Expanded(child: _labeled('Ref. Doc No', Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 11.h),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8.r), border: Border.all(color: AppColors.border)),
              child: Text(_docNo?.toString() ?? '—', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            ))),
          ]),
          SizedBox(height: 12.h),
          _labeled('Refund Mode', Row(children: [
            for (final m in const ['Cash', 'Cheque', 'DD', 'Others']) _radioChip(m),
          ])),
          if (bankRow) ...[
            SizedBox(height: 12.h),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                flex: 2,
                child: _labeled('Bank Name', DropdownButtonFormField<int>(
                  initialValue: _selectedBanId,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 6,
                  style: _fieldTextStyle(),
                  decoration: _fieldDec('Select bank'),
                  items: _banks.map((b) {
                    final name = b['banname']?.toString() ?? '';
                    final branch = b['banbranch']?.toString() ?? '';
                    return DropdownMenuItem(value: b['ban_id'] as int?, child: Text(branch.isEmpty ? name : '$name — $branch', overflow: TextOverflow.ellipsis));
                  }).toList(),
                  onChanged: (v) => setState(() => _selectedBanId = v),
                )),
              ),
              SizedBox(width: 12.w),
              Expanded(child: _labeled('Bank Ref', TextField(controller: _bankRefCtrl, style: _fieldTextStyle(), decoration: _fieldDec('Cheque/DD/UTR no')))),
              SizedBox(width: 12.w),
              Expanded(child: _labeled('Cheque Date', _dateBox(_chequeDate, 'dd/mm/yyyy', () => _pickDate(initial: _chequeDate ?? DateTime.now(), onPicked: (d) => setState(() => _chequeDate = d))))),
            ]),
          ],
          SizedBox(height: 12.h),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _labeled('Account Code', TextField(controller: _accountCodeCtrl, style: _fieldTextStyle(), decoration: _fieldDec('Optional')))),
            SizedBox(width: 12.w),
            Expanded(flex: 2, child: _labeled('Refund Reason', TextField(controller: _refundReasonCtrl, style: _fieldTextStyle(), decoration: _fieldDec('Reason for refund')))),
          ]),
        ],
      ),
    );
  }

  // ── fee-line grid ─────────────────────────────────────────────────────────
  Widget _gridCard() {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8.r), border: Border.all(color: AppColors.border)),
      child: _grid(),
    );
  }

  Widget _grid() {
    if (_loading) return SizedBox(height: 160.h, child: const Center(child: CircularProgressIndicator()));
    if (_selectedPayId == null) {
      return SizedBox(height: 120.h, child: Center(child: Text('Select a receipt to list its fee lines', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))));
    }
    if (_loadingLines) return SizedBox(height: 160.h, child: const Center(child: CircularProgressIndicator()));
    if (_rows.isEmpty) {
      return SizedBox(height: 120.h, child: Center(child: Text('No fee lines found on this receipt', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary))));
    }
    TextStyle h() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3);
    TextStyle c() => TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);
    return Column(children: [
      Container(
        color: AppColors.tableHeadBg,
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
        child: Row(children: [
          SizedBox(width: 70.w, child: Text('SEM', style: h())),
          Expanded(flex: 3, child: Text('FEE TYPE', style: h())),
          SizedBox(width: 100.w, child: Padding(padding: EdgeInsets.only(right: 4.w), child: Text('FEE AMT', textAlign: TextAlign.right, style: h()))),
          SizedBox(width: 120.w, child: Padding(padding: EdgeInsets.only(right: 12.w), child: Text('REFUND AMT', textAlign: TextAlign.right, style: h()))),
          SizedBox(width: 120.w, child: Padding(padding: EdgeInsets.only(right: 12.w), child: Text('ADJ AMT', textAlign: TextAlign.right, style: h()))),
          Expanded(flex: 2, child: Text('ADJUSTMENT REASON', style: h())),
        ]),
      ),
      ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _rows.length,
        separatorBuilder: (_, __) => Divider(height: 1.h, color: AppColors.border.withValues(alpha: 0.5)),
        itemBuilder: (_, i) {
          final r = _rows[i];
          return Container(
            color: i.isEven ? Colors.white : AppColors.surface,
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 4.h),
            child: Row(children: [
              SizedBox(width: 70.w, child: Text(r.term, style: c())),
              Expanded(flex: 3, child: Text(r.feeGroup.isEmpty ? r.feeType : '${r.feeType}  (${r.feeGroup})', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
              SizedBox(width: 100.w, child: Text(r.feeAmount.toStringAsFixed(2), textAlign: TextAlign.right, style: c())),
              SizedBox(width: 120.w, child: Padding(padding: EdgeInsets.symmetric(horizontal: 8.w), child: _amtField(r.refundCtrl, max: r.feeAmount, label: 'Refund'))),
              SizedBox(width: 120.w, child: Padding(padding: EdgeInsets.symmetric(horizontal: 8.w), child: _amtField(r.adjustCtrl, max: r.feeAmount - r.refund, label: 'Adjustment'))),
              Expanded(flex: 2, child: Padding(
                padding: EdgeInsets.only(left: 8.w),
                child: TextField(
                  controller: r.reasonCtrl,
                  style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary),
                  decoration: InputDecoration(isDense: true, hintText: 'Optional', hintStyle: TextStyle(fontSize: 11.sp, color: AppColors.textLight), contentPadding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h), border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.r))),
                ),
              )),
            ]),
          );
        },
      ),
    ]);
  }

  Widget _amtField(TextEditingController ctrl, {required double max, required String label}) {
    return TextField(
      controller: ctrl,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      style: TextStyle(fontSize: 12.sp, color: AppColors.textPrimary),
      decoration: InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h), border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.r))),
      onChanged: (val) {
        final entered = double.tryParse(val.trim());
        final cap = max < 0 ? 0.0 : max;
        if (entered != null && entered > cap) {
          final clamped = cap.toStringAsFixed(cap == cap.roundToDouble() ? 0 : 2);
          ctrl.text = clamped;
          ctrl.selection = TextSelection.collapsed(offset: clamped.length);
          _snack('$label can\'t exceed ${cap.toStringAsFixed(0)}.', AppColors.warning);
        }
        setState(() {});
      },
    );
  }

  Widget _footer() {
    Widget tot(String label, double v, Color color) => Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$label  ', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          Text('₹${v.toStringAsFixed(2)}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: color)),
        ]);
    return Padding(
      padding: EdgeInsets.all(14.w),
      child: Row(children: [
        tot('Collected:', _totalCollected, AppColors.textPrimary),
        SizedBox(width: 20.w),
        tot('Refund:', _totalRefund, AppColors.primary),
        SizedBox(width: 20.w),
        tot('Adjust:', _totalAdjust, AppColors.accentDark),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _saving ? null : _newRecord,
          icon: const Icon(Icons.note_add_outlined, size: 16),
          label: const Text('New'),
        ),
        SizedBox(width: 12.w),
        ElevatedButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save, size: 16),
          label: const Text('Save Refund'),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
        ),
      ]),
    );
  }
}
