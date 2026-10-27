import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/student_avatar.dart';
import '../../utils/school_terms.dart';

/// Fee Cancel Receipt — void a whole fee-collection receipt from one place.
/// Look up a student, pick one of their receipts, review the fee lines it
/// settled, enter a cancellation reason, then Cancel. Voiding (via the
/// void_receipt RPC):
///   1. restores every demand the receipt settled (balancedue back up, paid
///      down, paidstatus 'U', pay_id cleared),
///   2. soft-voids the payment (activestatus=9, paystatus='R') keeping it for
///      audit with voidedby / voideddate / voidreason.
/// Bank-reconciled non-cash receipts are protected server-side.
///
/// Mirrors the Fee Refund lookup layout; the action is an all-or-nothing void
/// rather than a per-line refund.
class FeeCancelScreen extends StatefulWidget {
  const FeeCancelScreen({super.key});

  @override
  State<FeeCancelScreen> createState() => _FeeCancelScreenState();
}

class _FeeCancelScreenState extends State<FeeCancelScreen> {
  final _searchCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();

  Map<String, dynamic>? _student;
  List<Map<String, dynamic>> _filteredStudents = [];

  // Filter-by-course/class options — derived from the students themselves so
  // they populate for every institution (some, e.g. hostels, have no course/
  // class master rows, only courname/stuclass strings on students).
  List<String> _courseOptions = [];
  Map<String, Set<String>> _classByCourse = {};
  List<String> _allClassOptions = [];
  String? _selectedCourse;
  String? _selectedClass;

  // Receipts of the selected student + the fee lines of the chosen receipt.
  List<Map<String, dynamic>> _receipts = [];
  /// Selected receipt, keyed 'P:<pay_id>' / 'M:<mc_id>' / 'A:<adv_id>'. Fee,
  /// misc and advance receipts live in three different tables with independent
  /// ids, so a bare int would let pay_id 412 and mc_id 412 select each other --
  /// and cancel the wrong receipt.
  String? _selectedKey;

  static String _receiptKey(Map<String, dynamic> r) => r['adv_id'] != null
      ? 'A:${r['adv_id']}'
      : (r['mc_id'] != null ? 'M:${r['mc_id']}' : 'P:${r['pay_id']}');

  static bool _isMisc(Map<String, dynamic> r) => r['mc_id'] != null;
  static bool _isAdvance(Map<String, dynamic> r) => r['adv_id'] != null;
  List<Map<String, dynamic>> _lines = [];

  bool _searching = false, _loading = false, _loadingLines = false, _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCoursesClasses();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  // ── filter options (student-derived) ─────────────────────────────────────────
  Future<void> _loadCoursesClasses() async {
    try {
      // Distinct courname / stuclass from active students — reliable across
      // institutions that don't maintain course/class master rows.
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('students')
          .select('courname, stuclass')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0));  // next year's intake: advance screens only
      final courses = <String>{};
      final classByCourse = <String, Set<String>>{};
      final allClasses = <String>{};
      for (final r in rows) {
        final c = (r['courname']?.toString() ?? '').trim();
        final cl = (r['stuclass']?.toString() ?? '').trim();
        if (c.isNotEmpty) courses.add(c);
        if (cl.isNotEmpty) allClasses.add(cl);
        if (c.isNotEmpty && cl.isNotEmpty) classByCourse.putIfAbsent(c, () => <String>{}).add(cl);
      }
      if (!mounted) return;
      setState(() {
        _courseOptions = courses.toList()..sort();
        _classByCourse = classByCourse;
        _allClassOptions = allClasses.toList()..sort();
      });
    } catch (_) {}
  }

  List<String> get _courseNames => _courseOptions;

  List<String> _classNamesFor(String? courseName) {
    if (courseName == null || courseName.trim().isEmpty) return _allClassOptions;
    final set = _classByCourse[courseName.trim()];
    if (set == null || set.isEmpty) return _allClassOptions;
    return set.toList()..sort();
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

  // ── student lookup ──────────────────────────────────────────────────────────

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
      _lines = [];
      _reasonCtrl.clear();
    });
    try {
      final stuId = student['stu_id'];
      var receipts = <Map<String, dynamic>>[];
      if (stuId != null) {
        final res = await SupabaseService.fromSchema('payment')
            .select('pay_id, paynumber, paydate, transtotalamount, paymethod, paystatus, recon_status')
            .eq('ins_id', _insId)
            .eq('stu_id', stuId)
            .inFilter('paystatus', ['C', 'R'])
            .eq('activestatus', 1)
            .order('paydate', ascending: false);
        receipts = List<Map<String, dynamic>>.from(res as List);
      }

      // Misc receipts for the same student. Matched on regno rather than
      // stu_id: a misc receipt can be raised for someone with no student row,
      // so regno is the field it always carries.
      final admno = student['stuadmno']?.toString() ?? '';
      if (admno.isNotEmpty) {
        try {
          final mres = await SupabaseService.fromSchema('misc_collection')
              .select('mc_id, mcno, mcdate, totalamount, paymode, paystatus, recon_status')
              .eq('ins_id', _insId)
              .eq('regno', admno)
              .eq('activestatus', 1)
              .order('mcdate', ascending: false);
          for (final m in List<Map<String, dynamic>>.from(mres as List)) {
            receipts.add({
              'mc_id': m['mc_id'],
              'paynumber': m['mcno'],
              'paydate': m['mcdate'],
              'transtotalamount': m['totalamount'],
              'paymethod': m['paymode'],
              'paystatus': m['paystatus'] ?? 'C',
              'recon_status': m['recon_status'] ?? 'R',
            });
          }
          receipts.sort((a, b) => (b['paydate']?.toString() ?? '')
              .compareTo(a['paydate']?.toString() ?? ''));
        } catch (e) {
          // Older database without the misc paystatus columns: fee receipts
          // still cancel, misc simply does not appear.
          debugPrint('misc receipts unavailable for cancel: $e');
        }
      }

      // Advance receipts (AD26/...) for the same student. They belong in this
      // list for the same reason misc receipts do: a cashier undoing a receipt
      // keyed by mistake should not have to know which screen raised it.
      // Whether a given one CAN be cancelled is the server's call -- it refuses
      // any advance already applied to a fee, and says so.
      if (stuId != null) {
        try {
          final ares = await SupabaseService.fromSchema('advance_collection')
              .select('adv_id, advno, advdate, advtype, transtotalamount, '
                  'adjustedamount, refund_amount, paymethod, paystatus, recon_status')
              .eq('ins_id', _insId)
              .eq('stu_id', stuId)
              .eq('activestatus', 1)
              .order('advdate', ascending: false);
          for (final a in List<Map<String, dynamic>>.from(ares as List)) {
            receipts.add({
              'adv_id': a['adv_id'],
              'paynumber': a['advno'],
              'paydate': a['advdate'],
              'transtotalamount': a['transtotalamount'],
              'paymethod': a['paymethod'],
              'paystatus': a['paystatus'] ?? 'C',
              'recon_status': a['recon_status'] ?? 'R',
              'advtype': a['advtype'],
              'adjustedamount': a['adjustedamount'],
            });
          }
          receipts.sort((a, b) => (b['paydate']?.toString() ?? '')
              .compareTo(a['paydate']?.toString() ?? ''));
        } catch (e) {
          // Advance module not deployed on this database yet.
          debugPrint('advance receipts unavailable for cancel: $e');
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

  /// Load the fee lines of the chosen receipt (read-only preview).
  Future<void> _onReceiptSelected(String key) async {
    setState(() {
      _selectedKey = key;
      _loadingLines = true;
      _lines = [];
    });
    try {
      if (key.startsWith('A:')) {
        final advId = int.tryParse(key.substring(2));
        final r = _receipts.firstWhere(
            (x) => (x['adv_id'] as num?)?.toInt() == advId,
            orElse: () => const {});
        final total = (r['transtotalamount'] as num?)?.toDouble() ?? 0;
        var lines = <Map<String, dynamic>>[];
        try {
          // An ADMISSION advance was collected fee type by fee type, so it can
          // show what it was taken for.
          final det = await SupabaseService.fromSchema('advance_detail')
              .select('feetype, amount')
              .eq('adv_id', advId as Object)
              .eq('activestatus', 1);
          lines = [
            for (final d in List<Map<String, dynamic>>.from(det as List))
              {
                'demfeetype': d['feetype'],
                'demfeeterm': 'Advance',
                'feeamount': d['amount'],
                'collectedamount': d['amount'],
              }
          ];
        } catch (_) {
          lines = [];
        }
        if (lines.isEmpty) {
          // A STUDENT advance is a plain amount with no breakdown.
          lines = [
            {
              'demfeetype': 'ADVANCE',
              'demfeeterm': 'Advance',
              'feeamount': total,
              'collectedamount': total,
            }
          ];
        }
        if (!mounted) return;
        setState(() { _lines = lines; _loadingLines = false; });
        return;
      }
      if (key.startsWith('M:')) {
        final mcId = int.tryParse(key.substring(2));
        final det = await SupabaseService.fromSchema('misc_collection_detail')
            .select('feetype, amount')
            .eq('mc_id', mcId as Object)
            .eq('activestatus', 1);
        final lines = [
          for (final d in List<Map<String, dynamic>>.from(det as List))
            {
              'demfeetype': d['feetype'],
              'demfeeterm': 'Misc',
              'feeamount': d['amount'],
              'collectedamount': d['amount'],
            }
        ];
        if (!mounted) return;
        setState(() { _lines = lines; _loadingLines = false; });
        return;
      }
      final payId = int.parse(key.substring(2));
      var lines = await SupabaseService.getFeeDetailsByPayId(payId, insId: _insId);
      // A later payment may have overwritten feedemand.pay_id, so the by-pay_id
      // lookup returns nothing even though the receipt is real. Re-join through
      // paymentdetails (which keep this receipt's dem_ids) to show its lines.
      if (lines.isEmpty) lines = await _linesViaPaymentDetails(payId);
      if (!mounted) return;
      setState(() {
        _lines = lines;
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

  /// Re-join a receipt's lines through paymentdetails → feedemand by dem_id,
  /// for receipts whose feedemand.pay_id was later overwritten.
  Future<List<Map<String, dynamic>>> _linesViaPaymentDetails(int payId) async {
    try {
      final pd = await SupabaseService.fromSchema('paymentdetails')
          .select('dem_id, transtotalamount')
          .eq('pay_id', payId);
      final rows = List<Map<String, dynamic>>.from(pd as List);
      final demIds = rows.map((r) => r['dem_id']).where((e) => e != null).toList();
      if (demIds.isEmpty) return [];
      final dems = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, stuclass, demfeeterm, demfeetype, fee_id, feeamount, fineamount, demseqtype, arrearclass')
          .inFilter('dem_id', demIds);
      final demMap = {for (final d in (dems as List)) d['dem_id']: Map<String, dynamic>.from(d as Map)};
      return rows.map((r) {
        final d = Map<String, dynamic>.from(demMap[r['dem_id']] ?? <String, dynamic>{});
        d['collectedamount'] = r['transtotalamount'];
        return d;
      }).toList();
    } catch (e) {
      debugPrint('Error re-joining receipt lines via paymentdetails: $e');
      return [];
    }
  }

  Map<String, dynamic>? get _selectedReceipt {
    if (_selectedKey == null) return null;
    final r = _receipts.firstWhere((e) => _receiptKey(e) == _selectedKey,
        orElse: () => const {});
    return r.isEmpty ? null : r;
  }

  /// A receipt may only be cancelled on the day it was collected. Cancelling an
  /// older one would reopen fees inside a day whose collection is already
  /// reported and, for a bank/UPI receipt, already banked.
  bool get _isPastDateLock {
    final r = _selectedReceipt;
    if (r == null) return false;
    final paid = (r['paydate']?.toString() ?? '').split('T').first;
    if (paid.isEmpty) return false;
    final now = DateTime.now();
    final today = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return paid != today;
  }

  /// Why this receipt cannot be cancelled, or null when it can be.
  ///
  /// CASH ONLY. The notes go back across the same counter and nothing ever
  /// reached a bank, so a cash receipt can be undone here. Every other mode
  /// is money that has left the payer -- the remedy is a FEE REFUND, which
  /// records where it went, rather than erasing the receipt and leaving the
  /// payment unexplained.
  ///
  /// The test is "is it cash", not "is it one of these other things", so a
  /// spelling nobody anticipated fails CLOSED: refused, and someone asks why.
  ///
  /// recon_status is deliberately not consulted. It records whether a credit
  /// has been MATCHED on a statement, not whether the money arrived -- an
  /// unreconciled online transfer is in the bank just the same.
  ///
  /// Mirrors public.receipt_cancel_block_reason, which all three void_*
  /// functions call. This copy is only so the counter sees the reason before
  /// pressing the button; the database is what enforces it.
  String? get _cancelBlockReason {
    final r = _selectedReceipt;
    if (r == null) return null;
    final raw = (r['paymethod']?.toString() ?? '').trim();
    final method = raw.toLowerCase();

    if (method == 'cash') return null;

    // An advance adjustment collected nothing -- it moved money banked when
    // the ADVANCE was taken. Voiding it here would erase the receipt without
    // giving the advance back, so the student would lose both.
    if (method == 'advance adjustment') {
      return 'This receipt was settled from an advance. Reverse it from '
          'Advance Adjustment so the advance goes back to the student — '
          'cancelling here would void the receipt without returning it.';
    }

    return 'Only a cash receipt can be cancelled. This one was paid by '
        '${raw.isEmpty ? 'another mode' : raw} — return it through Fee '
        'Refund, which records where the money went.';
  }

  bool get _isReconciledLock => _cancelBlockReason != null;

  double _lineAmount(Map<String, dynamic> d) =>
      (d['collectedamount'] as num?)?.toDouble() ??
      (d['paidamount'] as num?)?.toDouble() ??
      (d['feeamount'] as num?)?.toDouble() ??
      0;

  double get _totalCollected {
    final r = _selectedReceipt;
    if (r != null) return (r['transtotalamount'] as num?)?.toDouble() ?? 0;
    return _lines.fold(0.0, (s, d) => s + _lineAmount(d));
  }

  // ── cancel ──────────────────────────────────────────────────────────────────
  Future<void> _cancel() async {
    if (_student == null) {
      _popup('Student Required', 'Search and select a student first.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }
    if (_selectedKey == null) {
      _popup('Receipt Required', 'Select the receipt to cancel.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }
    if (_isPastDateLock) {
      _popup(
          'Only Today’s Receipts',
          'This receipt was collected on '
              '${_selectedReceipt?['paydate']?.toString().split('T').first ?? 'an earlier date'}. '
              'Only a receipt collected today can be cancelled here — use a fee refund for an earlier one.',
          AppColors.error,
          Icons.event_busy);
      return;
    }
    if (_isReconciledLock) {
      _popup('Cannot Cancel This Receipt', _cancelBlockReason!, AppColors.error, Icons.lock_outline);
      return;
    }
    if (_reasonCtrl.text.trim().isEmpty) {
      _popup('Reason Required', 'Enter a reason for cancelling this receipt.', AppColors.warning, Icons.warning_amber_rounded);
      return;
    }
    final receipt = _selectedReceipt;
    final no = receipt?['paynumber']?.toString() ?? '';
    // Capture identity before the confirm-dialog await (no BuildContext across gaps).
    final auth = context.read<AuthProvider>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.error, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text('Cancel Receipt $no?', style: AppUI.cardTitle)),
        ]),
        content: Text(
          // What cancelling actually undoes differs by receipt, and saying the
          // wrong thing here is how a cashier ends up expecting a demand to
          // re-open that never moved.
          _selectedKey!.startsWith('A:')
              ? 'This voids advance receipt $no for ${_student!['stuname']} '
                  '(₹${_totalCollected.toStringAsFixed(2)}). No fee demand changes — '
                  'an advance that has already been applied to one cannot be '
                  'cancelled at all.\n\n'
                  'The receipt is kept for audit and stamped CANCELLED. This cannot be undone.'
              : _selectedKey!.startsWith('M:')
                  ? 'This voids misc receipt $no for ${_student!['stuname']} '
                      '(₹${_totalCollected.toStringAsFixed(2)}). A misc receipt settles no '
                      'fee demand, so nothing returns to pending.\n\n'
                      'The receipt is kept for audit and stamped CANCELLED. This cannot be undone.'
                  : 'This voids receipt $no for ${_student!['stuname']} and restores the '
                      '₹${_totalCollected.toStringAsFixed(2)} it collected back to pending.\n\n'
                      'The receipt is kept for audit and stamped CANCELLED. This cannot be undone.',
          style: AppUI.body,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Receipt')),
          ElevatedButton(
            style: AppUI.danger(ctx),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel Receipt'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _saving = true);
    try {
      final id = int.parse(_selectedKey!.substring(2));
      if (_selectedKey!.startsWith('A:')) {
        await SupabaseService.voidAdvanceReceipt(
          id,
          token: auth.sessionToken ?? '',
          user: auth.userName ?? '',
          reason: _reasonCtrl.text.trim(),
        );
      } else if (_selectedKey!.startsWith('M:')) {
        await SupabaseService.voidMiscReceipt(
          id,
          insId: auth.insId ?? _insId,
          user: auth.userName ?? '',
          reason: _reasonCtrl.text.trim(),
        );
      } else {
        await SupabaseService.voidReceipt(
          id,
          insId: auth.insId ?? _insId,
          user: auth.userName ?? '',
          reason: _reasonCtrl.text.trim(),
          // With the token the void also gives the advance its money back.
          token: auth.sessionToken,
        );
      }
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Receipt $no cancelled for ${_student!['stuname']}.', AppColors.success);
      // Re-load the student's remaining receipts (the cancelled one drops off).
      final s = _student!;
      _reasonCtrl.clear();
      await _load(s);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _popup('Cancel Failed', friendlyError(e), AppColors.error, Icons.error_outline);
      }
    }
  }

  Future<void> _newRecord() async {
    setState(() {
      _searchCtrl.clear();
      _reasonCtrl.clear();
      _student = null;
      _filteredStudents = [];
      _selectedCourse = null;
      _selectedClass = null;
      _receipts = [];
      _selectedKey = null;
      _lines = [];
      _error = null;
    });
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

  // ── field styling (matches Fee Refund) ───────────────────────────────────────
  InputDecoration _fieldDec(String hint, {Widget? prefixIcon, Widget? suffixIcon}) {
    final d = AppUI.field(context, hint, suffix: suffixIcon);
    if (prefixIcon == null) return d;
    return d.copyWith(prefixIcon: Padding(padding: const EdgeInsets.only(left: 12, right: 8), child: prefixIcon));
  }

  TextStyle _fieldTextStyle() => AppUI.fieldText(context);

  // ── layout ──────────────────────────────────────────────────────────────────
  // Master-detail: student search + Course/Class filter and the student's
  // receipts on the left; the picked receipt's details, cancellation reason
  // and fee lines on the right.
  @override
  Widget build(BuildContext context) {
    final picked = _selectedKey != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(decoration: AppUI.card(), child: _header()),
      SizedBox(height: AppUI.gap),
      Expanded(
        child: AppMasterDetail(
          listTitle: _student == null ? 'Students' : 'Receipts',
          listIcon: _student == null ? 'people' : 'receipt-discount',
          listSubtitle: _student == null
              ? 'Search or filter, then pick a student'
              : 'Pick the receipt to cancel',
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

  /// Drop the picked receipt but keep the student -- the narrow layout's Back.
  void _clearReceipt() {
    setState(() {
      _selectedKey = null;
      _lines = [];
    });
  }

  /// Back to the student list (keeps the Course/Class filter).
  void _clearStudent() {
    setState(() {
      _student = null;
      _receipts = [];
      _selectedKey = null;
      _lines = [];
      _reasonCtrl.clear();
      _error = null;
    });
  }

  Widget _header() => Padding(
        padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, AppUI.cardPad, 14.h),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          AppUI.iconTile('receipt-discount', color: AppColors.error),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Fee Cancel Receipt', style: AppUI.cardTitle),
              SizedBox(height: 2.h),
              Text('Void a fee-collection receipt and restore its fees', style: AppUI.muted),
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

  // ── list pane ───────────────────────────────────────────────────────────────
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

  /// Misc receipts are tagged: they share the FCxx/ series with fee receipts,
  /// so the number alone does not identify them. An advance says so too, and
  /// whether it is an admission or a student one -- they cancel under
  /// different conditions.
  Widget? _kindChip(Map<String, dynamic> r) {
    if (_isAdvance(r)) {
      return AppUI.chip(r['advtype']?.toString() == 'A' ? 'Advance (Admission)' : 'Advance', AppStatus.info);
    }
    if (_isMisc(r)) return AppUI.chip('Misc', AppStatus.neutral);
    if (r['paystatus']?.toString() == 'R') return AppUI.chip('Part refunded', AppStatus.warning);
    return null;
  }

  Widget _receiptList() {
    if (_loading) return const AppLoading(label: 'Loading…');
    if (_receipts.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(
            icon: 'receipt-discount',
            title: _error != null ? 'Something went wrong' : 'No receipts found',
            subtitle: _error ?? 'This student has no active receipt to cancel',
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
        final amt = (r['transtotalamount'] as num?)?.toDouble() ?? 0;
        final date = r['paydate']?.toString().split('T').first ?? '';
        final method = r['paymethod']?.toString() ?? '';
        return _tile(
          selected: key == _selectedKey,
          onTap: () => _onReceiptSelected(key),
          title: r['paynumber']?.toString() ?? '—',
          sub: method.isEmpty ? date : '$date  ·  $method',
          amount: '₹${amt.toStringAsFixed(2)}',
          chip: _kindChip(r),
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

  // ── detail pane ─────────────────────────────────────────────────────────────
  Widget _emptyDetail() {
    if (_student == null) {
      return AppUI.empty(
        icon: 'receipt-discount',
        title: 'Select a student',
        why: 'Search a student by reg no / name, or pick a Course and Class on the left, then choose the receipt to cancel.',
      );
    }
    if (!_loading && _receipts.isEmpty) {
      return AppUI.empty(
        icon: 'receipt-discount',
        title: 'Nothing to cancel',
        why: _error ?? 'This student has no active receipt.',
      );
    }
    return AppUI.empty(
      icon: 'receipt-discount',
      title: 'Select a receipt',
      why: 'Pick one of ${_student!['stuname'] ?? 'the student'}\'s receipts on the left to review and cancel it.',
    );
  }

  Widget _detailPane() {
    final r = _selectedReceipt ?? const <String, dynamic>{};
    final amt = (r['transtotalamount'] as num?)?.toDouble() ?? 0;
    final chip = _kindChip(r);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(AppUI.cardPad, AppUI.cardPad, AppUI.cardPad, 14.h),
        child: AppUI.cardHeader(
          icon: 'receipt-discount',
          title: 'Receipt ${r['paynumber'] ?? '—'}',
          subtitle: '${_student?['stuname'] ?? ''}  •  ₹${amt.toStringAsFixed(2)}',
          trailing: [if (chip != null) chip],
        ),
      ),
      const Divider(height: 1, color: AppColors.divider),
      Expanded(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, AppUI.cardPad, 16.h),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _cancelForm(),
            SizedBox(height: AppUI.gap),
            _resultsArea(),
          ]),
        ),
      ),
      _footer(),
    ]);
  }

  Widget _labeled(String label, Widget child, {bool optional = false, bool required = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppUI.fieldLabel(label, optional: optional, required: required),
          child,
        ],
      );

  Widget _readonlyBox(String value) => InputDecorator(
        decoration: _fieldDec(''),
        child: Text(value.isEmpty ? '-' : value, style: AppUI.fieldText(context)),
      );

  // The receipt itself is picked from the list on the left (it used to be a
  // Receipt No dropdown here).
  Widget _cancelForm() {
    final r = _selectedReceipt;
    final dateStr = r?['paydate']?.toString().split('T').first ?? '-';
    final mode = r?['paymethod']?.toString() ?? '-';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppUI.sectionLabel('Receipt Details'),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _labeled('Receipt Date', _readonlyBox(dateStr))),
          SizedBox(width: 14.w),
          Expanded(child: _labeled('Payment Mode', _readonlyBox(mode))),
        ]),
        SizedBox(height: 14.h),
        _labeled('Cancellation Reason', TextField(
          controller: _reasonCtrl,
          style: _fieldTextStyle(),
          maxLines: 2,
          decoration: _fieldDec('Why is this receipt being cancelled?'),
        ), required: true),
        // Same banner treatment as the reconciled lock, so a disabled Cancel
        // button always has a visible reason next to it.
        if (_isPastDateLock) ...[
          SizedBox(height: 12.h),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
            decoration: BoxDecoration(
              color: AppColors.errorBg,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
            ),
            child: Row(children: [
              const Icon(Icons.event_busy, size: 16, color: AppColors.error),
              SizedBox(width: 8.w),
              Expanded(
                  child: Text(
                      'Only a receipt collected today can be cancelled. This one is dated '
                      '${_selectedReceipt?['paydate']?.toString().split('T').first ?? '-'}.',
                      style: TextStyle(fontSize: 12.sp, color: AppColors.error, fontWeight: FontWeight.w600))),
            ]),
          ),
        ],
        if (_isReconciledLock) ...[
          SizedBox(height: 12.h),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
            decoration: BoxDecoration(
              color: AppColors.errorBg,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
            ),
            child: Row(children: [
              const Icon(Icons.lock_outline, size: 16, color: AppColors.error),
              SizedBox(width: 8.w),
              Expanded(child: Text(_cancelBlockReason ?? '', style: TextStyle(fontSize: 12.sp, color: AppColors.error, fontWeight: FontWeight.w600))),
            ]),
          ),
        ],
      ],
    );
  }

  // ── read-only fee-line preview ───────────────────────────────────────────────
  Widget _resultsArea() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppUI.sectionLabel('Fee Lines'),
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.cardBorder)),
        child: _grid(),
      ),
    ]);
  }

  Widget _grid() {
    if (_loading || _loadingLines) {
      return SizedBox(height: 260.h, child: const AppLoading(label: 'Loading…'));
    }
    if (_student == null || _selectedKey == null || _lines.isEmpty) {
      final title = _error != null
          ? 'Something went wrong'
          : _student == null
              ? 'No receipts found'
              : _selectedKey == null
                  ? 'Select a receipt to cancel'
                  : 'No line preview for this receipt';
      final subtitle = _error ??
          (_student == null
              ? 'Try adjusting your filters or search for a student'
              : _selectedKey == null
                  ? 'Pick a receipt from the list on the left'
                  : 'Its fees may have been re-billed since — you can still cancel it below.');
      return Container(
        constraints: BoxConstraints(minHeight: 260.h),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(vertical: 30.h),
        child: EmptyState(
          icon: 'receipt-discount',
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
          Expanded(flex: 2, child: Text('STATUS', style: h())),
          SizedBox(width: 130.w, child: Padding(padding: EdgeInsets.only(right: 12.w), child: Text('AMOUNT', textAlign: TextAlign.right, style: h()))),
        ]),
      ),
      ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _lines.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
        itemBuilder: (_, i) {
          final d = _lines[i];
          final term = d['demfeeterm']?.toString() ?? '';
          final feeType = d['demfeetype']?.toString() ?? d['feegroupname']?.toString() ?? 'Fee';
          final group = d['feegroupname']?.toString() ?? '';
          return Container(
            color: i.isEven ? Colors.white : AppColors.surface,
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
            child: Row(children: [
              SizedBox(width: 70.w, child: Text(term, style: c())),
              Expanded(flex: 3, child: Text(group.isEmpty ? feeType : '$feeType  ($group)', style: AppUI.cell)),
              Expanded(flex: 2, child: _paidChip()),
              SizedBox(width: 130.w, child: Padding(padding: EdgeInsets.only(right: 12.w), child: Text('₹${_lineAmount(d).toStringAsFixed(2)}', textAlign: TextAlign.right, style: AppUI.money))),
            ]),
          );
        },
      ),
    ]);
  }

  Widget _paidChip() => Align(
        alignment: Alignment.centerLeft,
        child: AppUI.chip('Paid', AppStatus.success),
      );

  Widget _footer() {
    // Footer bar: receipt total, Clear + Cancel Receipt.
    return Container(
      padding: EdgeInsets.symmetric(horizontal: AppUI.cardPad, vertical: 12.h),
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.divider))),
      child: Row(children: [
        Text('Receipt Total  ', style: AppUI.muted),
        Text('₹${_totalCollected.toStringAsFixed(2)}', style: AppUI.money.copyWith(fontSize: 16.sp, fontWeight: FontWeight.w800)),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: _saving ? null : _newRecord,
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('Clear'),
        ),
        SizedBox(width: 12.w),
        ElevatedButton.icon(
          onPressed: (_saving || _isReconciledLock || _isPastDateLock) ? null : _cancel,
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.block, size: 16),
          label: const Text('Cancel Receipt'),
          style: AppUI.danger(context),
        ),
      ]),
    );
  }
}
