import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/student_avatar.dart';
import '../../utils/school_terms.dart';

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
  /// What can still be refunded on this line: collected by this receipt less
  /// anything earlier vouchers already returned. It is the ceiling for both
  /// the Refund and Adjustment fields.
  final double feeAmount;
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
  final _docNoCtrl = TextEditingController();

  Map<String, dynamic>? _student;
  List<Map<String, dynamic>> _filteredStudents = [];

  // Filter-by-class state (Course = clagrp, Class = section in the school model).
  List<Map<String, dynamic>> _courseList = [];
  List<Map<String, dynamic>> _classList = [];
  String? _selectedCourse;
  String? _selectedClass;

  // Receipts of the selected student + the fee lines of the chosen receipt.
  List<Map<String, dynamic>> _receipts = [];

  /// Selected receipt, keyed 'P:<pay_id>' or 'A:<adv_id>'. A fee receipt and an
  /// advance receipt live in different tables with independent ids, so a bare
  /// int would let pay_id 412 and adv_id 412 select each other.
  String? _selectedKey;
  int? _selectedPayId;
  List<_RefundRow> _rows = [];

  static String _receiptKey(Map<String, dynamic> r) =>
      r['adv_id'] != null ? 'A:${r['adv_id']}' : 'P:${r['pay_id']}';

  bool get _isAdvanceSelected => _selectedKey?.startsWith('A:') ?? false;
  int? get _selectedAdvId =>
      _isAdvanceSelected ? int.tryParse(_selectedKey!.substring(2)) : null;

  // Refund header fields.
  DateTime _refundDate = DateTime.now();
  String? _docNo; // formatted refund doc no (from the REFNO sequence)
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
    _docNoCtrl.dispose();
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

  /// Preview of the next refund doc no from the REFNO sequence (Setup → Fee
  /// Master → Refund No). doc_no is a formatted string (prefix + padded), and
  /// process_refund generates the authoritative value atomically on save.
  Future<void> _loadDocNo() async {
    try {
      final s = await SupabaseService.fromSchema('sequence')
          .select('seqprefix, seqwidth, seqstart, seqcurno')
          .eq('ins_id', _insId)
          .eq('actname', 'REFNO')
          .eq('activestatus', 1)
          .order('seq_id')
          .limit(1)
          .maybeSingle();
      var next = '';
      if (s != null) {
        final start = (s['seqstart'] as num?)?.toInt() ?? 1;
        final cur = (s['seqcurno'] as num?)?.toInt() ?? 0;
        final width = (s['seqwidth'] as num?)?.toInt() ?? 5;
        final n = cur < start ? start : cur + 1;
        next = '${s['seqprefix'] ?? ''}${n.toString().padLeft(width, '0')}';
      }
      if (mounted) setState(() { _docNo = next; _docNoCtrl.text = next; });
    } catch (_) {
      if (mounted) setState(() { _docNo = ''; _docNoCtrl.text = ''; });
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
    // Keeps the existing order within each group and sends the TC batches to
    // the foot of the list (utils/class_sort.dart).
    return classGroupPartition(
        src.map((e) => e['claname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty).toSet(),
        (s) => s);
  }

  Future<void> _loadFromFilter() async {
    if (_selectedCourse == null && _selectedClass == null) {
      if (mounted) setState(() => _filteredStudents = []);
      return;
    }
    try {
      var query = SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname, stuphoto')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0);  // next year's intake: advance screens only
      if (_selectedCourse != null) query = query.eq('courname', _selectedCourse!);
      if (_selectedClass != null) query = query.eq('stuclass', _selectedClass!);
      final rows = await query.order('stuname', ascending: true).limit(500);
      if (mounted) setState(() => _filteredStudents = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  // ── student lookup ────────────────────────────────────────────────────────

  /// Students matching a typed reg no / name, for the Select Student
  /// typeahead. Returns the rows rather than holding them in state -- the
  /// Autocomplete keeps its own list.
  Future<List<Map<String, dynamic>>> _lookupStudents(String q) async {
    final term = q.trim();
    if (term.length < 2) return const [];
    try {
      final rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname, stuphoto')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0)  // next year's intake: advance screens only
          .or('stuadmno.ilike.$term%,stuname.ilike.%$term%')
          .order('stuname', ascending: true)
          .limit(50);
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      return const [];
    }
  }

  void _pick(Map<String, dynamic> s) {
    _load(s);
  }

  Future<void> _load(Map<String, dynamic> student) async {
    setState(() {
      _searching = false;
      _loading = true;
      _student = student;
      _receipts = [];
      _selectedKey = null;
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
      // Advance receipts with money still unused. Only the UNUSED balance can
      // be given back: what has already settled a fee is not the institution's
      // to return twice, and what was already refunded has gone.
      if (stuId != null) {
        try {
          final ares = await SupabaseService.fromSchema('advance_collection')
              .select('adv_id, advno, advdate, advtype, transtotalamount, '
                  'adjustedamount, refund_amount, balanceamount, paymethod, paystatus')
              .eq('ins_id', _insId)
              .eq('stu_id', stuId)
              .eq('activestatus', 1)
              .eq('paystatus', 'C')
              .order('advdate', ascending: false);
          for (final a in List<Map<String, dynamic>>.from(ares as List)) {
            final left = (a['balanceamount'] as num?)?.toDouble() ?? 0;
            if (left <= 0.009) continue;
            receipts.add({
              'adv_id': a['adv_id'],
              'paynumber': a['advno'],
              'paydate': a['advdate'],
              'transtotalamount': a['transtotalamount'],
              'balanceamount': left,
              'paymethod': a['paymethod'],
              'paystatus': a['paystatus'] ?? 'C',
              'advtype': a['advtype'],
            });
          }
          receipts.sort((x, y) => (y['paydate']?.toString() ?? '')
              .compareTo(x['paydate']?.toString() ?? ''));
        } catch (e) {
          // Advance module not deployed on this database yet.
          debugPrint('advance receipts unavailable for refund: $e');
        }
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

  /// How much of each demand on this receipt was settled from an ADVANCE
  /// rather than taken at the counter. That money never came in as cash here --
  /// it was collected when the advance was taken -- so it cannot go back out as
  /// a refund. Cancelling the receipt is what returns it, and it returns it to
  /// the advance, not to the student's hand.
  Future<Map<int, double>> _settledFromAdvance(int payId) async {
    final out = <int, double>{};
    try {
      final rows = await SupabaseService.fromSchema('advadjustment')
          .select('dem_id, adjustamount')
          .eq('ins_id', _insId)
          .eq('pay_id', payId)
          .eq('activestatus', 1);
      for (final r in List<Map<String, dynamic>>.from(rows as List)) {
        final id = (r['dem_id'] as num?)?.toInt();
        if (id == null) continue;
        out[id] = (out[id] ?? 0) + ((r['adjustamount'] as num?)?.toDouble() ?? 0);
      }
    } catch (e) {
      // Advance module not deployed — nothing on this receipt came off one.
      debugPrint('advance-settled lookup: $e');
    }
    return out;
  }

  /// How much of each demand this receipt has ALREADY had refunded or
  /// adjusted, by dem_id. Scoped to the receipt: a receipt can never give back
  /// more than it took, whatever other receipts did.
  Future<Map<int, double>> _alreadyRefunded(int payId) async {
    final out = <int, double>{};
    try {
      final heads = await SupabaseService.fromSchema('fee_refund')
          .select('rf_id')
          .eq('ins_id', _insId)
          .eq('pay_id', payId)
          .eq('activestatus', 1);
      final ids = List<Map<String, dynamic>>.from(heads as List)
          .map((e) => (e['rf_id'] as num?)?.toInt())
          .whereType<int>()
          .toList();
      if (ids.isEmpty) return out;
      final det = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('fee_refunddetails')
          .select('dem_id, refundamount, adjustamount, activestatus')
          .inFilter('rf_id', ids));
      for (final d in det) {
        // A cancelled line gave nothing back, so it frees the amount again.
        if (((d['activestatus'] as num?)?.toInt() ?? 1) == 9) continue;
        final id = (d['dem_id'] as num?)?.toInt();
        if (id == null) continue;
        out[id] = (out[id] ?? 0)
            + ((d['refundamount'] as num?)?.toDouble() ?? 0)
            + ((d['adjustamount'] as num?)?.toDouble() ?? 0);
      }
    } catch (e) {
      // Refund tables not deployed yet — fall back to the collected amount.
      debugPrint('prior refund lookup: $e');
    }
    return out;
  }

  /// Load the fee lines of the chosen receipt into the grid.
  Future<void> _onReceiptSelected(String key) async {
    setState(() {
      _selectedKey = key;
      _selectedPayId = key.startsWith('P:') ? int.tryParse(key.substring(2)) : null;
      _loadingLines = true;
      _clearRows();
    });
    try {
      if (key.startsWith('A:')) {
        final advId = int.tryParse(key.substring(2));
        final r = _receipts.firstWhere(
            (x) => (x['adv_id'] as num?)?.toInt() == advId,
            orElse: () => const {});
        final left = (r['balanceamount'] as num?)?.toDouble() ?? 0;
        // ONE line. An advance is a single sum held against the student, not a
        // set of demands, so there is nothing to spread a refund across: what
        // can come back is simply what is left of it.
        final rows = [
          _RefundRow(
            demId: 0,
            term: 'Advance',
            feeType: 'ADVANCE',
            feeGroup: r['advtype']?.toString() == 'A' ? 'Admission' : 'Student',
            feeAmount: left > 0 ? left : 0,
          )
        ];
        if (!mounted) return;
        setState(() {
          _rows = rows;
          _loadingLines = false;
        });
        return;
      }
      final payId = int.parse(key.substring(2));
      final lines = await SupabaseService.getFeeDetailsByPayId(payId, insId: _insId);
      final prior = await _alreadyRefunded(payId);
      final fromAdvance = await _settledFromAdvance(payId);
      final rows = lines
          .map((m) {
            // Fee Amt = amount actually collected in this receipt
            // (partial-safe), falling back to paidamount then feeamount...
            final collected = (m['collectedamount'] as num?)?.toDouble()
                ?? (m['paidamount'] as num?)?.toDouble()
                ?? (m['feeamount'] as num?)?.toDouble()
                ?? 0;
            final demId = (m['dem_id'] as num?)?.toInt() ?? 0;
            // ...less whatever earlier vouchers already took back from this
            // same receipt. Without this the screen kept offering the full
            // collected amount after a refund, so the same line could be
            // refunded over and over — which is how one receipt ended up
            // refunded twice.
            // ...and less the part that came off an advance rather than out of
            // the payer's pocket. Refunding that would hand back money the
            // counter never took on this receipt.
            final remaining =
                collected - (prior[demId] ?? 0) - (fromAdvance[demId] ?? 0);
            return _RefundRow(
              demId: demId,
              term: m['demfeeterm']?.toString() ?? '',
              feeType: m['demfeetype']?.toString() ?? '',
              feeGroup: m['feegroupname']?.toString() ?? '',
              feeAmount: remaining > 0 ? remaining : 0,
            );
          })
          // Nothing left to give back on this line — drop it rather than show
          // a row that can only accept 0.
          .where((r) => r.feeAmount > 0.005)
          .toList();
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

  /// Still refundable across the grid — the receipt's collection less what
  /// earlier vouchers already took back.
  double get _totalCollected => _rows.fold(0.0, (s, r) => s + r.feeAmount);
  double get _totalRefund => _rows.fold(0.0, (s, r) => s + r.refund);
  double get _totalAdjust => _rows.fold(0.0, (s, r) => s + r.adjust);

  // ── save ──────────────────────────────────────────────────────────────────
  // True if a numbering sequence with this actname (e.g. REFNO) is configured.
  Future<bool> _hasSequence(String actname, int insId) async {
    try {
      final r = await SupabaseService.fromSchema('sequence')
          .select('seq_id').eq('ins_id', insId).eq('actname', actname).eq('activestatus', 1).limit(1).maybeSingle();
      return r != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _save() async {
    if (_student == null) {
      _popup('Student Required', 'Search and select a student first.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }
    if (_selectedKey == null) {
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

    if (!await _hasSequence('REFNO', insId)) {
      _popup('Sequence Required', 'Create a Refund No sequence in Setup → Fee Master → Refund No first.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }

    if (_isAdvanceSelected) {
      if (totalAdjust > 0) {
        _popup('Adjustment Not Applicable',
            'An advance has no demand to write off against. Enter the amount to '
            'give back under Refund Amt.',
            AppColors.warning, Icons.warning_amber_rounded);
        return;
      }
      final token = auth.sessionToken;
      if (token == null || token.isEmpty) {
        _popup('Session Expired', 'Sign in again to raise this refund.',
            AppColors.error, Icons.lock_outline);
        return;
      }
      setState(() => _saving = true);
      try {
        // One RPC: it writes the voucher, its line and the advance's own
        // refund_amount in a single transaction, so a refund can never be
        // recorded without the advance's balance moving with it.
        final res = await SupabaseService.refundAdvance(token: token, header: {
          'adv_id': _selectedAdvId,
          'amount': totalRefund,
          'refunddate': _refundDate.toIso8601String().split('T').first,
          'refundmode': _refundMode,
          'ban_id': _selectedBanId?.toString(),
          'bankname': _selectedBanId == null
              ? null
              : (_banks.firstWhere((b) => b['ban_id'] == _selectedBanId,
                  orElse: () => const {})['banname']),
          'bankref': _bankRefCtrl.text.trim().isEmpty ? null : _bankRefCtrl.text.trim(),
          'chequedate': _chequeDate?.toIso8601String().split('T').first,
          'accountcode':
              _accountCodeCtrl.text.trim().isEmpty ? null : _accountCodeCtrl.text.trim(),
          'refundreason': _refundReasonCtrl.text.trim().isEmpty
              ? null
              : _refundReasonCtrl.text.trim(),
          'createdby': auth.userName,
        });
        if (!mounted) return;
        setState(() => _saving = false);
        final left = (res['balance_left'] as num?)?.toDouble() ?? 0;
        _snack(
            'Refund ${res['doc_no'] ?? ''} saved • ₹${totalRefund.toStringAsFixed(2)} '
            'off ${res['advno'] ?? 'the advance'} • ₹${left.toStringAsFixed(2)} still held.',
            AppColors.success);
        _newRecord();
      } catch (e) {
        if (mounted) {
          setState(() => _saving = false);
          _popup('Save Failed', friendlyError(e), AppColors.error, Icons.error_outline);
        }
      }
      return;
    }

    setState(() => _saving = true);
    try {
      // Build the header + detail maps once; run atomically via the
      // session-gated process_refund RPC (ins_id derived server-side), with a
      // token-less direct fallback for safety.
      final header = <String, dynamic>{
        'doc_no': _docNoCtrl.text.trim().isEmpty ? _docNo : _docNoCtrl.text.trim(),
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
              .select('feeamount, conamount, paidamount, balancedue, reconbalancedue')
              .eq('dem_id', r.demId)
              .maybeSingle();
          if (dem == null) continue;
          final feeNow = (dem['feeamount'] as num?)?.toDouble() ?? 0;
          final conNow = (dem['conamount'] as num?)?.toDouble() ?? 0;
          final paidNow = (dem['paidamount'] as num?)?.toDouble() ?? 0;
          final balNow = (dem['balancedue'] as num?)?.toDouble() ?? 0;
          final reconNow = (dem['reconbalancedue'] as num?)?.toDouble() ?? balNow;
          // Mirrors process_refund: the refund comes off the collection and the
          // balance is recomputed from the invariant rather than incremented,
          // so refunding a duplicate collection leaves the demand settled
          // instead of billing it a second time.
          final newPaid = (paidNow - r.refund).clamp(0.0, double.infinity);
          final newBal = (feeNow - conNow - newPaid).clamp(0.0, double.infinity);
          final delta = newBal - balNow;
          await SupabaseService.fromSchema('feedemand').update({
            'paidamount': newPaid,
            'balancedue': newBal,
            'reconbalancedue': (reconNow + delta).clamp(0.0, double.infinity),
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
      _filteredStudents = [];
      _selectedCourse = null;
      _selectedClass = null;
      _receipts = [];
      _selectedKey = null;
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
        title: Row(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: AppUI.cardTitle)),
        ]),
        content: Text(message, style: AppUI.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ── field styling (matches Fee Concession) ────────────────────────────────
  InputDecoration _fieldDec(String hint, {Widget? prefixIcon, Widget? suffixIcon}) {
    final d = AppUI.field(context, hint, suffix: suffixIcon);
    if (prefixIcon == null) return d;
    return d.copyWith(prefixIcon: Padding(padding: const EdgeInsets.only(left: 12, right: 8), child: prefixIcon));
  }

  TextStyle _fieldTextStyle() => AppUI.fieldText(context);

  // ── layout ────────────────────────────────────────────────────────────────
  // Master-detail: student search + Course/Class filter and the student's
  // receipts on the left; the picked receipt's refund form + fee lines on the
  // right.
  @override
  Widget build(BuildContext context) {
    final picked = _selectedKey != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(decoration: AppUI.card(), child: _header()),
      SizedBox(height: AppUI.gap),
      Expanded(
        child: AppMasterDetail(
          listTitle: _student == null ? 'Students' : 'Receipts',
          listIcon: _student == null ? 'people' : 'receipt-2',
          listSubtitle: _student == null
              ? 'Search or filter, then pick a student'
              : 'Pick the receipt to refund against',
          search: _studentSearch(),
          filters: [_courseClassFilters()],
          list: _listBody(),
          footer: _listFooter(),
          detail: picked ? _detailPane() : null,
          emptyDetail: _emptyDetail(),
          showDetail: picked,
          onBack: _clearReceipt,
        ),
      ),
    ]);
  }

  /// Drop the picked receipt (and its lines) but keep the student -- the
  /// narrow layout's Back, and what the old Receipt No dropdown being reset
  /// amounted to.
  void _clearReceipt() {
    setState(() {
      _selectedKey = null;
      _selectedPayId = null;
      _clearRows();
    });
  }

  /// Back to the student list (keeps the Course/Class filter).
  void _clearStudent() {
    setState(() {
      _student = null;
      _receipts = [];
      _selectedKey = null;
      _selectedPayId = null;
      _clearRows();
      _error = null;
    });
  }

  Widget _header() => Padding(
        padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, AppUI.cardPad, 14.h),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          AppUI.iconTile('receipt-2'),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Fee Refund', style: AppUI.cardTitle),
              SizedBox(height: 2.h),
              Text('Refund a fee-collection receipt easily', style: AppUI.muted),
            ]),
          ),
          Builder(builder: (context) {
            return ElevatedButton.icon(
              onPressed: _searching ? null : _newRecord,
              icon: AppIcon('trash', size: AppBtn.iconSize(context), color: Colors.white),
              label: const Text('Clear'),
            );
          }),
        ]),
      );

  // ── list pane ─────────────────────────────────────────────────────────────
  Widget _courseClassFilters() => Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _courseNames.contains(_selectedCourse) ? _selectedCourse : null,
            isExpanded: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            style: _fieldTextStyle(),
            decoration: _fieldDec(schoolTerm('Select Course')),
            items: _courseNames.map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) => setState(() {
              _selectedCourse = v;
              if (_selectedClass != null && !_classNamesFor(v).contains(_selectedClass)) _selectedClass = null;
              _loadFromFilter();
            }),
          ),
        ),
        SizedBox(width: 10.w),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _classNamesFor(_selectedCourse).contains(_selectedClass) ? _selectedClass : null,
            isExpanded: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            style: _fieldTextStyle(),
            decoration: _fieldDec(schoolTerm('Select Class')),
            items: _classNamesFor(_selectedCourse).map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) => setState(() {
              _selectedClass = v;
              _loadFromFilter();
            }),
          ),
        ),
      ]);

  // Typeable, and the ONLY student search on the screen. It filters the
  // Course/Class list while one is chosen, and falls back to searching every
  // student by reg no or name when none is.
  Widget _studentSearch() => LayoutBuilder(
        builder: (context, box) => Autocomplete<Map<String, dynamic>>(
          displayStringForOption: (s) => '${s['stuname']} • ${s['stuadmno']}',
          optionsBuilder: (v) async {
            final q = v.text.trim();
            if (_filteredStudents.isNotEmpty) {
              if (q.isEmpty) return _filteredStudents;
              final t = q.toLowerCase();
              return _filteredStudents.where((s) =>
                  (s['stuname']?.toString().toLowerCase() ?? '').contains(t) ||
                  (s['stuadmno']?.toString().toLowerCase() ?? '').contains(t));
            }
            // Two characters before hitting the database: one letter would
            // pull half the college back on every keystroke.
            if (q.length < 2) return const Iterable<Map<String, dynamic>>.empty();
            return _lookupStudents(q);
          },
          onSelected: _pick,
          fieldViewBuilder: (context, controller, focusNode, onSubmitted) => TextField(
            controller: controller,
            focusNode: focusNode,
            style: _fieldTextStyle(),
            decoration: _fieldDec('Type reg no or name',
                prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.textLight)),
          ),
          optionsViewBuilder: (context, onSelected, options) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(8.r),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: 320.h, maxWidth: box.maxWidth),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: options.length,
                  itemBuilder: (_, i) {
                    final s = options.elementAt(i);
                    return ListTile(
                      dense: true,
                      title: Text(s['stuname']?.toString() ?? '',
                          style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          [s['stuadmno'], s['stuclass']]
                              .where((e) => (e?.toString().trim().isNotEmpty ?? false))
                              .join(' • '),
                          style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                      onTap: () => onSelected(s),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );

  /// No student yet: the Course/Class students (tap one to load their
  /// receipts). A student picked: their chip + receipts.
  Widget _listBody() {
    if (_student == null) {
      if (_filteredStudents.isEmpty) {
        return AppUI.empty(
          icon: 'people',
          title: 'No student selected',
          why: 'Type a reg no or name above, or pick a Course and Class to list its students.',
        );
      }
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: _filteredStudents.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
        itemBuilder: (_, i) {
          final s = _filteredStudents[i];
          return _tile(
            selected: false,
            onTap: () => _pick(s),
            title: s['stuname']?.toString() ?? '',
            sub: [s['stuadmno'], s['stuclass']].where((e) => (e?.toString().trim().isNotEmpty ?? false)).join('  ·  '),
          );
        },
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: EdgeInsets.all(12.w), child: _studentChip()),
      const Divider(height: 1, color: AppColors.divider),
      Expanded(child: _receiptList()),
    ]);
  }

  Widget _receiptList() {
    if (_loading) return const AppLoading(label: 'Loading…');
    if (_receipts.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(
            icon: 'receipt-2',
            title: _error != null ? 'Something went wrong' : 'No receipts found',
            subtitle: _error ?? 'This student has no collected receipt with anything left to refund',
            action: OutlinedButton.icon(
              onPressed: _searching ? null : _newRecord,
              icon: const AppIcon('refresh', size: 15, color: AppColors.accent),
              label: const Text('Reset Filters'),
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _receipts.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
      itemBuilder: (_, i) {
        final r = _receipts[i];
        final key = _receiptKey(r);
        final isAdv = r['adv_id'] != null;
        // An advance shows what is REFUNDABLE, not what it was taken for: the
        // rest of it has already gone onto fees.
        final amt = (isAdv
                ? (r['balanceamount'] as num?)?.toDouble()
                : (r['transtotalamount'] as num?)?.toDouble()) ??
            0;
        final date = r['paydate']?.toString().split('T').first ?? '';
        final method = r['paymethod']?.toString() ?? '';
        final chip = isAdv
            ? AppUI.chip(r['advtype']?.toString() == 'A' ? 'Advance (Admission)' : 'Advance', AppStatus.info)
            : (r['paystatus']?.toString() == 'R'
                ? AppUI.chip('Part refunded', AppStatus.warning)
                : AppUI.chip('Collected', AppStatus.success));
        return _tile(
          selected: key == _selectedKey,
          onTap: () => _onReceiptSelected(key),
          title: r['paynumber']?.toString() ?? '—',
          sub: method.isEmpty ? date : '$date  ·  $method',
          amount: '₹${amt.toStringAsFixed(2)}',
          chip: chip,
        );
      },
    );
  }

  /// A dense list row: hover, selected = primaryLight + accent text.
  Widget _tile({required bool selected, required VoidCallback onTap, required String title, required String sub, String? amount, Widget? chip}) => Material(
        color: selected ? AppColors.primaryLight : Colors.white,
        child: InkWell(
          onTap: onTap,
          hoverColor: AppColors.primaryLight.withValues(alpha: 0.6),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 10.h),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AppUI.label.copyWith(color: selected ? AppColors.primary : AppColors.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                  SizedBox(height: 2.h),
                  Text(sub, style: AppUI.muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              if (amount != null || chip != null) ...[
                SizedBox(width: 10.w),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (amount != null) Text(amount, textAlign: TextAlign.right, style: AppUI.money.copyWith(color: selected ? AppColors.primary : AppColors.textPrimary)),
                  if (chip != null) ...[SizedBox(height: 4.h), chip],
                ]),
              ],
            ]),
          ),
        ),
      );

  Widget _listFooter() {
    final n = _student == null ? _filteredStudents.length : _receipts.length;
    return Text(AppUI.showing(n == 0 ? 0 : 1, n, n), style: AppUI.muted);
  }

  Widget _studentChip() {
    final s = _student!;
    final name = s['stuname']?.toString() ?? '';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        StudentAvatar(photoUrl: s['stuphoto']?.toString(), name: name, size: 44),
        SizedBox(width: 10.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(name, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
            SizedBox(height: 2.h),
            Text('Adm No: ${s['stuadmno']}  •  ${s['stuclass'] ?? ''}', style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        IconButton(
          tooltip: 'Change student',
          onPressed: _saving ? null : _clearStudent,
          icon: const Icon(Icons.close, size: 16, color: AppColors.textLight),
          splashRadius: 16,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
      ]),
    );
  }

  // ── detail pane ───────────────────────────────────────────────────────────
  Widget _emptyDetail() {
    if (_student == null) {
      return AppUI.empty(
        icon: 'receipt-2',
        title: 'Select a student',
        why: 'Search a student by reg no / name, or pick a Course and Class on the left, then choose the receipt to refund.',
      );
    }
    if (!_loading && _receipts.isEmpty) {
      return AppUI.empty(
        icon: 'receipt-2',
        title: 'Nothing to refund',
        why: _error ?? 'This student has no collected receipt with a balance left to refund.',
      );
    }
    return AppUI.empty(
      icon: 'receipt-2',
      title: 'Select a receipt',
      why: 'Pick one of ${_student!['stuname'] ?? 'the student'}\'s receipts on the left to enter the refund.',
    );
  }

  Map<String, dynamic> get _selectedReceipt =>
      _receipts.firstWhere((r) => _receiptKey(r) == _selectedKey, orElse: () => const {});

  Widget _detailPane() {
    final r = _selectedReceipt;
    final isAdv = r['adv_id'] != null;
    final amt = (isAdv
            ? (r['balanceamount'] as num?)?.toDouble()
            : (r['transtotalamount'] as num?)?.toDouble()) ??
        0;
    final date = r['paydate']?.toString().split('T').first ?? '';
    final method = r['paymethod']?.toString() ?? '';
    final sub = [date, '₹${amt.toStringAsFixed(2)}${isAdv ? ' refundable' : ''}', method].where((e) => e.isNotEmpty).join('  •  ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 14.h),
        child: AppUI.cardHeader(
          icon: 'receipt-2',
          title: 'Receipt ${r['paynumber'] ?? '—'}',
          subtitle: '${_student?['stuname'] ?? ''}  •  $sub',
          trailing: [
            if (isAdv)
              AppUI.chip(r['advtype']?.toString() == 'A' ? 'Advance (Admission)' : 'Advance', AppStatus.info)
            else if (r['paystatus']?.toString() == 'R')
              AppUI.chip('Part refunded', AppStatus.warning)
            else
              AppUI.chip('Collected', AppStatus.success),
          ],
        ),
      ),
      const Divider(height: 1, color: AppColors.divider),
      Expanded(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, AppUI.cardPad, 16.h),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _refundForm(),
            SizedBox(height: AppUI.gap),
            _resultsArea(),
          ]),
        ),
      ),
      if (_rows.isNotEmpty) _footer(),
    ]);
  }

  Widget _labeled(String label, Widget child, {bool optional = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppUI.fieldLabel(label, optional: optional),
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
          Text(m, style: AppUI.body.copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
        ]),
      ),
    );
  }

  /// Radio chip with a custom onTap (used for the Cash / Bank top-level choice).
  Widget _modeRadio(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: EdgeInsets.only(right: 14.w),
      child: InkWell(
        onTap: onTap,
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
          Text(label, style: AppUI.body.copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
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
            style: AppUI.fieldText(context).copyWith(color: value == null ? AppColors.textLight : null),
          ),
        ),
      );

  // The receipt itself is picked from the list on the left (it used to be a
  // Receipt No dropdown here); the rest of the header is unchanged.
  Widget _refundForm() {
    final bankRow = _refundMode != 'Cash';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppUI.sectionLabel('Refund Details'),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _labeled('Refund Date', _dateBox(_refundDate, 'Refund Date', () => _pickDate(initial: _refundDate, onPicked: (d) => setState(() => _refundDate = d))))),
          SizedBox(width: 14.w),
          // Auto-generated from the REFNO sequence on save — preview only.
          Expanded(child: _labeled('Ref. Doc No', TextField(
            controller: _docNoCtrl,
            readOnly: true,
            style: _fieldTextStyle(),
            decoration: _fieldDec('Set Refund No sequence in Fee Master'),
          ))),
        ]),
        SizedBox(height: 14.h),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: _labeled('Refund Mode', Padding(
              padding: EdgeInsets.only(top: 6.h),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Top-level: Cash or Bank. Bank refunds go by Cheque or DD.
                Row(children: [
                  _modeRadio('Cash', _refundMode == 'Cash', () => setState(() => _refundMode = 'Cash')),
                  _modeRadio('Bank', _refundMode != 'Cash', () => setState(() {
                    if (_refundMode == 'Cash') _refundMode = 'Cheque';
                  })),
                ]),
                if (_refundMode != 'Cash') Padding(
                  padding: EdgeInsets.only(top: 8.h, left: 4.w),
                  child: Row(children: [
                    _radioChip('Cheque'),
                    _radioChip('DD'),
                  ]),
                ),
              ]),
            )),
          ),
          SizedBox(width: 14.w),
          Expanded(child: _labeled('Account Code', TextField(controller: _accountCodeCtrl, style: _fieldTextStyle(), decoration: _fieldDec('Select or enter account code')), optional: true)),
        ]),
        SizedBox(height: 14.h),
        _labeled('Refund Reason', TextField(controller: _refundReasonCtrl, style: _fieldTextStyle(), decoration: _fieldDec('Enter reason for refund')), optional: true),
        if (bankRow) ...[
          SizedBox(height: AppUI.gap),
          AppUI.sectionLabel('Bank'),
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
            SizedBox(width: 14.w),
            Expanded(child: _labeled('Bank Ref', TextField(controller: _bankRefCtrl, style: _fieldTextStyle(), decoration: _fieldDec('Cheque/DD/UTR no')), optional: true)),
            SizedBox(width: 14.w),
            Expanded(child: _labeled('${_refundMode == 'DD' ? 'DD' : 'Cheque'} Date', _dateBox(_chequeDate, 'dd/mm/yyyy', () => _pickDate(initial: _chequeDate ?? DateTime.now(), onPicked: (d) => setState(() => _chequeDate = d))))),
          ]),
        ],
      ],
    );
  }

  // ── fee-line grid ─────────────────────────────────────────────────────────
  // Scrolls sideways rather than squeezing the amount / reason inputs when the
  // detail pane is narrow.
  Widget _resultsArea() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppUI.sectionLabel('Refund Lines'),
      LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth < 720 ? 720.0 : c.maxWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: w,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  border: Border.all(color: AppColors.cardBorder)),
              child: _grid(),
            ),
          ),
        );
      }),
    ]);
  }

  Widget _grid() {
    if (_loading || _loadingLines) {
      return SizedBox(height: 260.h, child: const AppLoading(label: 'Loading…'));
    }
    // No student, no receipt chosen, or a receipt with no lines → unified empty
    // state matching the mockup ("No receipts found").
    if (_student == null || _selectedKey == null || _rows.isEmpty) {
      final title = _error != null
          ? 'Something went wrong'
          : _student == null
              ? 'No receipts found'
              : _selectedKey == null
                  ? 'Select a receipt to refund'
                  : 'No fee lines on this receipt';
      final subtitle = _error ??
          (_student == null
              ? 'Try adjusting your filters or search for a student'
              : _selectedKey == null
                  ? 'Pick a receipt from the list on the left'
                  : 'This receipt has no refundable fee lines');
      return Container(
        constraints: BoxConstraints(minHeight: 260.h),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(vertical: 30.h),
        child: EmptyState(
          icon: 'receipt-2',
          title: title,
          subtitle: subtitle,
          action: OutlinedButton.icon(
            onPressed: _searching ? null : _newRecord,
            icon: const AppIcon('refresh', size: 15, color: AppColors.accent),
            label: const Text('Reset Filters'),
          ),
        ),
      );
    }
    TextStyle h() => AppUI.tableHead;
    TextStyle c() => AppUI.cell;
    return Column(children: [
      Container(
        color: AppColors.tableHeadBg,
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
        child: Row(children: [
          SizedBox(width: 70.w, child: Text('SEM', style: h())),
          Expanded(flex: 3, child: Text('FEE TYPE', style: h())),
          SizedBox(width: 100.w, child: Padding(padding: EdgeInsets.only(right: 4.w), child: Text('REFUNDABLE', textAlign: TextAlign.right, style: h()))),
          SizedBox(width: 120.w, child: Padding(padding: EdgeInsets.only(right: 12.w), child: Text('REFUND AMT', textAlign: TextAlign.right, style: h()))),
          SizedBox(width: 120.w, child: Padding(padding: EdgeInsets.only(right: 12.w), child: Text('ADJ AMT', textAlign: TextAlign.right, style: h()))),
          Expanded(flex: 2, child: Text('ADJUSTMENT REASON', style: h())),
        ]),
      ),
      ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
        itemBuilder: (_, i) {
          final r = _rows[i];
          return Container(
            color: i.isEven ? Colors.white : AppColors.surface,
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 4.h),
            child: Row(children: [
              SizedBox(width: 70.w, child: Text(r.term, style: c())),
              Expanded(flex: 3, child: Text(r.feeGroup.isEmpty ? r.feeType : '${r.feeType}  (${r.feeGroup})', style: AppUI.cell)),
              SizedBox(width: 100.w, child: Text(r.feeAmount.toStringAsFixed(2), textAlign: TextAlign.right, style: AppUI.money)),
              SizedBox(width: 120.w, child: Padding(padding: EdgeInsets.symmetric(horizontal: 8.w), child: _amtField(r.refundCtrl, max: r.feeAmount, label: 'Refund'))),
              SizedBox(
                  width: 120.w,
                  child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8.w),
                      // An advance has no demand behind it to write off, so
                      // only the refund half of the line applies.
                      child: _isAdvanceSelected
                          ? Text('—', textAlign: TextAlign.right, style: c())
                          : _amtField(r.adjustCtrl,
                              max: r.feeAmount - r.refund, label: 'Adjustment'))),
              Expanded(flex: 2, child: Padding(
                padding: EdgeInsets.only(left: 8.w),
                child: TextField(
                  controller: r.reasonCtrl,
                  style: AppUI.fieldText(context),
                  decoration: AppUI.field(context, 'Optional', dense: true),
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
      style: AppUI.fieldText(context),
      decoration: AppUI.field(context, '', dense: true)
          .copyWith(contentPadding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 8)),
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
          Text('$label  ', style: AppUI.muted),
          Text('₹${v.toStringAsFixed(2)}', style: AppUI.money.copyWith(fontSize: 16.sp, fontWeight: FontWeight.w800, color: color)),
        ]);
    // Footer bar: totals (wrap when the pane is narrow), Clear + Save.
    return Container(
      padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.divider))),
      child: Row(children: [
        Expanded(
          child: Wrap(spacing: 20.w, runSpacing: 6.h, children: [
            tot('Refundable:', _totalCollected, AppColors.textPrimary),
            tot('Refund:', _totalRefund, AppColors.primary),
            tot('Adjust:', _totalAdjust, AppColors.primaryHover),
          ]),
        ),
        SizedBox(width: 12.w),
        OutlinedButton.icon(
          onPressed: _saving ? null : _newRecord,
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('Clear'),
        ),
        SizedBox(width: 12.w),
        ElevatedButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.save, size: 16),
          label: const Text('Save Refund'),
        ),
      ]),
    );
  }
}
