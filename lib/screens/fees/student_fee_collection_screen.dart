import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/formatters.dart';
import '../../utils/receipt_pdf.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../services/supabase_service.dart';
import '../../services/paytm_service.dart';
import '../../config/paytm_config.dart';
import '../../widgets/paytm_checkout_dialog.dart';
import '../../widgets/receipt_widget.dart';
import 'student_fee_definition_dialog.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/focusable_tap.dart';
import '../../utils/class_sort.dart';
// Class ordering (course, then year) lives in utils/class_sort.dart -> classCompare.

const _termOrder = [
  'I TERM', 'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER',
  'II TERM', 'NOVEMBER', 'DECEMBER', 'JANUARY', 'FEBRUARY',
  'III TERM', 'III term', 'MARCH', 'APRIL', 'April',
];

int _termIndex(String t) {
  final idx = _termOrder.indexWhere((x) => x.toLowerCase() == t.toLowerCase());
  return idx >= 0 ? idx : _termOrder.length;
}

class StudentFeeCollectionScreen extends StatefulWidget {
  final VoidCallback? onNavigateToTransactions;
  const StudentFeeCollectionScreen({super.key, this.onNavigateToTransactions});

  @override
  State<StudentFeeCollectionScreen> createState() =>
      _StudentFeeCollectionScreenState();
}

class _StudentFeeCollectionScreenState
    extends State<StudentFeeCollectionScreen> {
  final _admNoController = TextEditingController();
  final _nameController = TextEditingController();
  final _classController = TextEditingController();
  final _remarksController = TextEditingController();
  final _chequeNoController = TextEditingController();
  final _upiRefController = TextEditingController();
  // Cash mode: cashier enters the tender amount; refund is computed.
  final _tenderAmountController = TextEditingController();
  double? _cashTenderAmount;
  double? _cashRefundAmount;
  final _chequeDateController = TextEditingController();
  final _bankNameController = TextEditingController();
  DateTime? _chequeDate;
  List<Map<String, dynamic>> _studentSuggestions = [];
  final LayerLink _admSearchLink = LayerLink();
  List<String> _courseList = [];
  String? _selectedCourse;
  List<String> _classList = [];
  List<String> _allClasses = [];
  Map<String, int> _classOrdid = {}; // claname(upper) -> course.ordid*N + class.ordid
  Map<String, List<String>> _courseClassMap = {};
  String? _selectedClass;
  List<Map<String, dynamic>> _classSuggestions = [];

  /// stu_id -> total outstanding across that student's active fee demands.
  /// 0 means billed but fully paid (shown as PAID in the lookup); a missing
  /// entry means their demands haven't been loaded yet.
  final Map<int, double> _balanceByStu = {};


  bool _searching = false;
  String? _errorMsg;

  Map<String, dynamic>? _student;
  Map<String, dynamic>? _parent;

  List<Map<String, dynamic>> _allDemands = [];
  bool _loadingDemands = false;

  String? _selectedTerm; // null = All

  // Regular vs Arrear collection. Students pay arrear and regular fees on
  // SEPARATE receipts, so the pending list, selection, totals and payment are
  // all scoped to one demseqtype at a time. Default 'REGULAR' (covers
  // demseqtype REGULAR/DEMAND/blank); switch to 'ARREAR' via the header toggle.
  String _seqType = 'REGULAR';
  // Utilities setting (fee_collection_arrear_first): when true, a student with
  // arrear dues opens on Arrear so arrears are cleared before regular fees.
  bool _arrearFirst = true;

  bool _isArrear(Map<String, dynamic> d) =>
      (d['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
  bool get _hasArrear => _allDemands.any(_isArrear);
  bool get _hasRegular => _allDemands.any((d) => !_isArrear(d));
  // The student still owes arrear (any arrear demand with a positive balance).
  bool get _arrearOutstanding => _allDemands.any(
      (d) => _isArrear(d) && ((d['balancedue'] as num?)?.toDouble() ?? 0) > 0);
  // Regular collection is locked while arrear is unpaid, when the arrear-first
  // Utilities toggle is on.
  bool get _regularLocked => _arrearFirst && _arrearOutstanding;
  bool _matchesSeqType(Map<String, dynamic> d) =>
      _seqType == 'ARREAR' ? _isArrear(d) : !_isArrear(d);
  List<Map<String, dynamic>> get _currentTypeDemands =>
      _allDemands.where(_matchesSeqType).toList();
  // Payment mode — null = nothing selected yet. The cashier picks one via
  // the inline chips in the bottom bar before the action button is enabled.
  String? _paymentMode;

  // Per-row controllers: keyed by dem_id
  final Map<String, TextEditingController> _fineCtrl = {};
  final Map<String, TextEditingController> _conCtrl = {};
  // Persistent FocusNodes per row so a setState that rebuilds the row table
  // doesn't make the active TextField lose focus mid-typing.
  final Map<String, FocusNode> _fineFocus = {};
  final Map<String, FocusNode> _conFocus = {};
  // Debounce the auto-check setState — pure typing within a row shouldn't
  // rebuild the table on every keystroke (which loses focus). A short pause
  // (~350ms) after the last digit triggers the actual selection flip.
  final Map<String, Timer> _conFlipTimers = {};
  // Debounces the student search so we don't fire 2 DB round-trips per keystroke.
  Timer? _searchDebounce;
  final Set<String> _selected = {};
  List<Map<String, dynamic>> _fineRules = [];

  /// Session token for gating the payment write RPCs. Null before the security
  /// migrations are run (→ helpers fall back to the legacy RPCs, non-breaking).
  String? get _sessionToken {
    try { return context.read<AuthProvider>().sessionToken; } catch (_) { return null; }
  }

  // Cached in didChangeDependencies so dispose() — where the element is
  // deactivated and context lookups throw "deactivated widget's ancestor" —
  // can still reach institution id / token for the fine-reset-on-exit.
  int? _cachedInsId;
  String? _cachedToken;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      final auth = context.read<AuthProvider>();
      _cachedInsId = auth.insId;
      _cachedToken = auth.sessionToken;
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _fetchClasses();
    _loadFineRules();
    _sweepOrphanedPayments();
    _loadUtilSettings();
  }

  /// Loads the arrear-first Utilities toggle for this institution.
  Future<void> _loadUtilSettings() async {
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    final s = await SupabaseService.getInstitutionSettings(insId);
    if (!mounted) return;
    setState(() {
      _arrearFirst = (s['fee_collection_arrear_first'] ?? 'true').toLowerCase() != 'false';
    });
  }

  Future<void> _sweepOrphanedPayments() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      final cutoff = DateTime.now().subtract(const Duration(minutes: 15)).toIso8601String();
      final orphans = await SupabaseService.fromSchema('payment')
          .select('pay_id, payorderid, payitems')
          .eq('ins_id', insId)
          .eq('paystatus', 'I')
          .lt('createdat', cutoff);
      for (final p in (orphans as List)) {
        final payId = p['pay_id'] as int;
        final orderId = p['payorderid']?.toString();
        String? paymentId;
        bool captured = false;
        if (orderId != null && orderId.isNotEmpty) {
          try {
            final s = await PaytmService.verifyPayment(orderId);
            if (s.isCaptured && s.paymentId != null) {
              captured = true;
              paymentId = s.paymentId;
            }
          } catch (_) {}
        }
        if (captured) {
          List<dynamic> items = [];
          final raw = p['payitems']?.toString();
          if (raw != null && raw.isNotEmpty) {
            try { items = jsonDecode(raw) as List<dynamic>; } catch (_) {}
          }
          try {
            await SupabaseService.completePaymentGrouped(
              token: _sessionToken, payId: payId, payMethod: 'online',
              payReference: paymentId, items: items, insId: insId, status: 'C');
          } catch (e) {
            debugPrint('Recovery complete failed for pay_id=$payId: $e');
          }
        } else {
          await SupabaseService.updatePayment(payId, {'paystatus': 'F'});
        }
      }
    } catch (e) {
      debugPrint('Orphaned payment sweep failed: $e');
    }
  }

  Future<void> _loadFineRules() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    debugPrint('FINE: Loading fine rules for insId=$insId, schema=${SupabaseService.currentSchema}');
    if (insId == null) return;
    try {
      final result = await SupabaseService.fromSchema('finerule')
          .select('*')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('from_days');
      _fineRules = List<Map<String, dynamic>>.from(result);
      debugPrint('FINE: Loaded ${_fineRules.length} rules: $_fineRules');
    } catch (e) {
      debugPrint('FINE: Error loading fine rules: $e');
    }
  }

  double _calculateFine(Map<String, dynamic> demand) {
    if (_fineRules.isEmpty) return 0;
    final dueDateStr = demand['duedate']?.toString();
    if (dueDateStr == null || dueDateStr.isEmpty) return 0;

    DateTime dueDate;
    try { dueDate = DateTime.parse(dueDateStr); } catch (_) { return 0; }

    final today = DateTime.now();
    if (!today.isAfter(dueDate)) return 0; // Not overdue

    final overdueDays = today.difference(dueDate).inDays;
    final feeType = demand['demfeetype']?.toString() ?? '';
    final feeAmount = (demand['feeamount'] as num?)?.toDouble() ?? 0;

    // Find matching rule (fee-type specific first, then ALL)
    Map<String, dynamic>? matchedRule;
    for (final rule in _fineRules) {
      final ruleType = rule['feetype']?.toString() ?? 'ALL';
      final fromDays = (rule['from_days'] as num?)?.toInt() ?? 0;
      final toDays = rule['to_days'] as num?;

      final daysMatch = overdueDays >= fromDays && (toDays == null || overdueDays <= toDays.toInt());
      if (!daysMatch) continue;

      if (ruleType == feeType) { matchedRule = rule; break; } // Exact match
      if (ruleType == 'ALL' && matchedRule == null) matchedRule = rule; // ALL fallback
    }

    if (matchedRule == null) return 0;

    final fineType = matchedRule['fine_type']?.toString() ?? 'FIXED';
    final fineValue = (matchedRule['fine_value'] as num?)?.toDouble() ?? 0;

    if (fineType == 'PERCENT') return (feeAmount * fineValue / 100);
    return fineValue;
  }

  Future<void> _fetchClasses() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    // Course/Class dropdown options. Source these from the STUDENTS table
    // (one row per student, just 2 columns) rather than the entire feedemand
    // table (many rows per student, every column) — far fewer rows and payload.
    // The actual per-class student lookup (_searchByClass) is already scoped.
    try {
      final results = await Future.wait([
        SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('students')
            .select('courname, stuclass')
            .eq('ins_id', insId)
            .eq('activestatus', 1)),
        SupabaseService.getClassOrder(insId),
      ]);
      final rows = results[0] as List<Map<String, dynamic>>;
      _classOrdid = results[1] as Map<String, int>;
      final cmp = classOrdidComparator(_classOrdid); // order by class-master ordid
      final courseSet = <String>{};
      final mapping = <String, Set<String>>{};
      for (final d in rows) {
        final course = d['courname']?.toString() ?? '';
        final cls = d['stuclass']?.toString() ?? '';
        if (course.isNotEmpty) courseSet.add(course);
        if (course.isNotEmpty && cls.isNotEmpty) {
          mapping.putIfAbsent(course, () => <String>{}).add(cls);
        }
      }
      final allClasses = mapping.values.expand((s) => s).toSet().toList()..sort(cmp);
      final courseClassMap = <String, List<String>>{ for (final e in mapping.entries) e.key: e.value.toList()..sort(cmp) };
      final courseList = courseSet.toList()..sort();
      if (mounted) setState(() {
        _courseList = courseList;
        _courseClassMap = courseClassMap;
        _allClasses = allClasses;
        _classList = allClasses;
      });
    } catch (e) { debugPrint('Error loading course-class from students: $e'); }
  }

  Future<void> _searchByClass(String className) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      // Step 1: gather every student in this class+course who has been billed
      // (has at least one fee demand), together with their outstanding total.
      // Fully-paid students are kept in the list and flagged PAID rather than
      // hidden, so a cashier can confirm someone has already settled up.
      // Both queries are paged — PostgREST caps a response at 1000 rows and
      // truncates silently, which for a large class would drop students from
      // the lookup with no error shown.
      final demRows = await SupabaseService.fetchAll(() {
        var q = SupabaseService.fromSchema('feedemand')
            .select('stu_id, balancedue')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('collectible', true) // ignore non-collectible demands in the owing flag
            .eq('stuclass', className);
        if (_selectedCourse != null) q = q.eq('courname', _selectedCourse!);
        return q;
      });
      final balances = <int, double>{};
      for (final r in demRows) {
        final id = r['stu_id'];
        if (id is! int) continue;
        balances[id] = (balances[id] ?? 0) + ((r['balancedue'] as num?)?.toDouble() ?? 0);
      }
      _balanceByStu.addAll(balances);

      // Step 2: the whole class roster. Students with no demands are listed
      // too (just without a status badge) — hiding them made the lookup look
      // broken when a class hadn't been billed yet.
      final rows = await SupabaseService.fetchAll(() {
        var q = SupabaseService.fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, courname')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('stuclass', className);
        if (_selectedCourse != null) q = q.eq('courname', _selectedCourse!);
        return q.order('stuname', ascending: true);
      });
      setState(() => _classSuggestions = rows);
    } catch (_) {}
  }

  @override
  void dispose() {
    // If the cashier is leaving without a completed payment, reset fineamount
    // to 0 on every unpaid demand currently loaded. Fine should only persist
    // on the DB after a successful payment, not just because a cashier viewed
    // the student.
    _resetFinesOnExit();
    _admNoController.dispose();
    _nameController.dispose();
    _classController.dispose();
    _remarksController.dispose();
    _chequeNoController.dispose();
    _upiRefController.dispose();
    _tenderAmountController.dispose();
    _chequeDateController.dispose();
    _bankNameController.dispose();
    for (final c in _fineCtrl.values) c.dispose();
    for (final c in _conCtrl.values) c.dispose();
    for (final f in _fineFocus.values) f.dispose();
    for (final f in _conFocus.values) f.dispose();
    for (final t in _conFlipTimers.values) t.cancel();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _resetFinesOnExit() {
    if (_allDemands.isEmpty) return;
    // Use the values cached in didChangeDependencies — dispose() must not touch
    // context (the element is already deactivated).
    final insId = _cachedInsId;
    if (insId == null) return;
    // Fire-and-forget — dispose can't await.
    for (final d in _allDemands) {
      final demId = d['dem_id'];
      final paidStatus = d['paidstatus']?.toString() ?? 'U';
      if (demId == null) continue;
      if (paidStatus == 'P') continue; // don't wipe historical paid fines
      SupabaseService.setDemandFine(token: _cachedToken, demId: demId, fineamount: 0)
          .then((_) {}, onError: (e) => debugPrint('Fine reset on exit failed for dem_id=$demId: $e'));
    }
  }

  void _clear() {
    for (final c in _fineCtrl.values) c.dispose();
    for (final c in _conCtrl.values) c.dispose();
    for (final f in _fineFocus.values) f.dispose();
    for (final f in _conFocus.values) f.dispose();
    _fineCtrl.clear();
    _conCtrl.clear();
    _fineFocus.clear();
    _conFocus.clear();
    setState(() {
      _admNoController.clear();
      _nameController.clear();
      _classController.clear();
      _remarksController.clear();
      _studentSuggestions = [];
      _classSuggestions = [];
      _selectedCourse = null;
      _selectedClass = null;
      _classList = List<String>.from(_allClasses);
      _student = null;
      _parent = null;
      _allDemands = [];
      _errorMsg = null;
      _selectedTerm = null;
      _seqType = 'REGULAR';
      _selected.clear();
      _paymentMode = null;
      _chequeNoController.clear();
      _chequeDateController.clear();
      _bankNameController.clear();
      _upiRefController.clear();
      _chequeDate = null;
    });
  }

  Future<void> _searchByAdmNo(String admno) async {
    if (admno.trim().length < 2) {
      setState(() => _studentSuggestions = []);
      return;
    }
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      final rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .ilike('stuadmno', '${admno.trim()}%')
          .limit(10);
      setState(() => _studentSuggestions = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _searchByName(String name) async {
    if (name.trim().length < 2) {
      setState(() => _studentSuggestions = []);
      return;
    }
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      final rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .ilike('stuname', '%${name.trim()}%')
          .limit(10);
      setState(() => _studentSuggestions = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  /// Debounces keystrokes so the search (2 DB round-trips) fires at most once
  /// every 300ms after the user stops typing, instead of on every character.
  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    if (v.trim().length < 2) {
      // Short/empty term → clear immediately, no round-trip.
      if (_studentSuggestions.isNotEmpty) setState(() => _studentSuggestions = []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _searchByAdmNoOrName(v);
    });
  }

  /// Combined suggestion search — matches Roll No (prefix) OR Student Name
  /// (substring) so the single search field works for both.
  Future<void> _searchByAdmNoOrName(String q) async {
    final term = q.trim();
    if (term.length < 2) {
      setState(() => _studentSuggestions = []);
      return;
    }
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      // Scope the search to the selected course / class when chosen, so the
      // cashier only matches students within the picked course + class.
      var query = SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      if (_selectedCourse != null && _selectedCourse!.isNotEmpty) {
        query = query.eq('courname', _selectedCourse!);
      }
      if (_selectedClass != null && _selectedClass!.isNotEmpty) {
        query = query.eq('stuclass', _selectedClass!);
      }
      final rows = await query
          .or('stuadmno.ilike.$term%,stuname.ilike.%$term%')
          .limit(10);
      final list = List<Map<String, dynamic>>.from(rows);
      setState(() => _studentSuggestions = list);
      // Load outstanding totals so the lookup can flag PAID here too.
      await _loadBalancesFor(
        list.map((s) => s['stu_id']).whereType<int>(),
        insId,
      );
    } catch (_) {}
  }

  /// Fill [_balanceByStu] for the given students by summing their active
  /// demands' balancedue. Students with demands but nothing owing land on 0.
  Future<void> _loadBalancesFor(Iterable<int> stuIds, int insId) async {
    final ids = stuIds.toSet().toList();
    if (ids.isEmpty) return;
    try {
      final rows = await SupabaseService.fromSchema('feedemand')
          .select('stu_id, balancedue')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('collectible', true) // ignore non-collectible demands in the owing flag
          .inFilter('stu_id', ids);
      final totals = <int, double>{};
      for (final r in (rows as List)) {
        final id = (r['stu_id'] as num?)?.toInt();
        if (id == null) continue;
        totals[id] = (totals[id] ?? 0) + ((r['balancedue'] as num?)?.toDouble() ?? 0);
      }
      if (!mounted) return;
      setState(() {
        for (final id in ids) {
          // Absent from `totals` = no demands at all; leave unset so the row
          // shows no badge rather than claiming the student has paid.
          if (totals.containsKey(id)) _balanceByStu[id] = totals[id]!;
        }
      });
    } catch (_) {}
  }

  void _selectSuggestion(Map<String, dynamic> student) {
    _admNoController.text = student['stuadmno']?.toString() ?? '';
    _nameController.text = student['stuname']?.toString() ?? '';
    _classController.text = student['stuclass']?.toString() ?? '';
    setState(() {
      _studentSuggestions = [];
      _classSuggestions = [];
    });
    _search();
  }

  Future<void> _search() async {
    final admNo = _admNoController.text.trim();
    if (admNo.isEmpty) return;

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    // Dispose old controllers + focus nodes from any previous search
    for (final c in _fineCtrl.values) c.dispose();
    for (final c in _conCtrl.values) c.dispose();
    for (final f in _fineFocus.values) f.dispose();
    for (final f in _conFocus.values) f.dispose();
    _fineCtrl.clear();
    _conCtrl.clear();
    _fineFocus.clear();
    _conFocus.clear();

    setState(() {
      _searching = true;
      _errorMsg = null;
      _student = null;
      _parent = null;
      _allDemands = [];
      _selected.clear();
      _selectedTerm = null;
    });

    try {
      // The combined search field accepts a Roll No OR a Student Name. Try
      // exact roll-no match first; if nothing, fall back to a name search
      // and use the first match (e.g. user typed a full name and hit Enter
      // without clicking a suggestion).
      var studentRows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, stugender, stumobile, stuphoto, courname')
          .eq('ins_id', insId)
          .eq('stuadmno', admNo)
          .eq('activestatus', 1)
          .limit(1);

      if ((studentRows as List).isEmpty) {
        studentRows = await SupabaseService.fromSchema('students')
            .select('stu_id, stuname, stuadmno, stuclass, stugender, stumobile, stuphoto, courname')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .ilike('stuname', '%$admNo%')
            .limit(1);
      }

      if ((studentRows as List).isEmpty) {
        setState(() {
          _errorMsg = 'No student found matching "$admNo"';
          _searching = false;
        });
        return;
      }

      final student = Map<String, dynamic>.from(studentRows.first as Map);
      final stuId = student['stu_id'] as int;
      // Use the resolved student's actual roll number for downstream lookups
      // (the search field may now hold the student name, not the admno).
      final stuAdmno = student['stuadmno']?.toString() ?? '';

      _nameController.text = student['stuname']?.toString() ?? '';
      _classController.text = student['stuclass']?.toString() ?? '';
      // Show the student name in the combined search field once a match is
      // resolved — easier to read than the raw roll no.
      _admNoController.text = student['stuname']?.toString() ?? '';
      final stuClass = student['stuclass']?.toString();
      final stuCourse = student['courname']?.toString();

      setState(() {
        _student = student;
        _searching = false;
        _loadingDemands = true;
        _studentSuggestions = [];
        if (stuCourse != null && stuCourse.isNotEmpty && _courseList.contains(stuCourse)) {
          _selectedCourse = stuCourse;
          if (_courseClassMap.containsKey(stuCourse)) {
            _classList = List<String>.from(_courseClassMap[stuCourse]!)
              ..sort(classOrdidComparator(_classOrdid));
          }
        }
        if (stuClass != null && _classList.contains(stuClass)) {
          _selectedClass = stuClass;
        }
      });

      // Fine is NOT persisted to feedemand.fineamount at search time — it is
      // only written after a successful payment (see _processPayment). The
      // cashier sees the calculated fine via _calculateFine below; if they
      // abandon without paying, the DB column stays empty.

      // Fetch parent and demands in parallel — use the resolved student's
      // actual stuadmno so the join works even when the user searched by
      // student name in the combined search field.
      final parentFuture = SupabaseService.getStudentParent(stuId, stuadmno: stuAdmno);
      final demandsFuture = SupabaseService.fromSchema('feedemand')
          .select(
              'dem_id, demno, demseqtype, yr_id, demfeeyear, demfeetype, demfeeterm, feeamount, conamount, balancedue, paidamount, fineamount, duedate, paidstatus, stuclass, collectible')
          .eq('ins_id', insId)
          .eq('stuadmno', stuAdmno)
          .eq('paidstatus', 'U')
          .gt('balancedue', 0)
          .eq('collectible', true) // only collectible demands are payable here
          .order('duedate', ascending: true);

      final parent = await parentFuture;
      final demandList =
          List<Map<String, dynamic>>.from((await demandsFuture) as List);

      // Sort by due date (oldest first) so cashiers collect overdue fees first.
      demandList.sort((a, b) {
        final da = a['duedate']?.toString() ?? '';
        final db = b['duedate']?.toString() ?? '';
        if (da.isEmpty && db.isEmpty) return 0;
        if (da.isEmpty) return 1;
        if (db.isEmpty) return -1;
        return da.compareTo(db);
      });

      _allDemands = demandList;

      // Per-row controllers: prefer the server-computed fineamount column;
      // fall back to client-side rule calculation if server hasn't populated it.
      // Default behaviour on student search: every demand row is pre-checked
      // and Col Amount is pre-filled with the balance — cashier just tweaks
      // values then hits Proceed to Pay.
      _selected.clear();
      _selectedTerm = null;
      // Arrear-first (Utilities): when enabled and the student has arrear dues,
      // open on Arrear so arrears are cleared before regular. Otherwise default
      // to Regular when present. Only the ACTIVE type is pre-selected/pre-filled
      // so the first receipt is single-type — the other type shows Col Amount 0.
      _seqType = (_arrearFirst && _hasArrear)
          ? 'ARREAR'
          : (_hasRegular ? 'REGULAR' : 'ARREAR');
      for (final d in demandList) {
        final key = d['dem_id']?.toString() ?? '';
        if (key.isNotEmpty) {
          final serverFine = (d['fineamount'] as num?)?.toDouble() ?? 0;
          final fine = serverFine > 0 ? serverFine : _calculateFine(d);
          final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
          final active = _matchesSeqType(d);
          _fineCtrl[key] = TextEditingController(text: fine > 0 ? fine.toStringAsFixed(0) : '');
          _conCtrl[key] = TextEditingController(text: (active && bal > 0) ? bal.toStringAsFixed(0) : '0');
          if (active && bal > 0) _selected.add(key);
        }
      }

      setState(() {
        _parent = parent;
        _loadingDemands = false;
      });
    } catch (e) {
      setState(() {
        _errorMsg = friendlyError(e);
        _searching = false;
        _loadingDemands = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredDemands {
    var list = _currentTypeDemands;
    if (_selectedTerm != null) {
      list = list
          .where((d) => (d['demfeetype']?.toString() ?? '') == _selectedTerm)
          .toList();
    }
    return list;
  }

  /// Unique Fee Type values across the current student's demands OF THE ACTIVE
  /// type (regular/arrear). Used by the in-table filter dropdown ("Fee Type").
  List<String> get _terms {
    final seen = <String>[];
    for (final d in _currentTypeDemands) {
      final t = d['demfeetype']?.toString() ?? '';
      if (t.isNotEmpty && !seen.contains(t)) seen.add(t);
    }
    return seen;
  }

  String _demKey(Map<String, dynamic> d) =>
      d['dem_id']?.toString() ?? '';

  double _fine(String key) =>
      double.tryParse(_fineCtrl[key]?.text ?? '') ?? 0;

  double _con(String key) =>
      double.tryParse(_conCtrl[key]?.text ?? '') ?? 0;

  double _netAmt(Map<String, dynamic> d) {
    // Net the cashier is actually collecting = Col Amount + Fine. When
    // nothing's typed in Col Amount the row contributes 0 so the cashier
    // sees exactly what they will collect.
    final key = _demKey(d);
    return _con(key) + _fine(key);
  }

  double get _totalNetSelected {
    // Bottom NET AMOUNT = sum of every row's actual NET AMT (col + fine).
    // Stays in lockstep with the per-row column so a row with Col Amount = 0
    // contributes 0 to the total even if the checkbox is still ticked.
    // Scoped to the ACTIVE type so regular and arrear totals never mix.
    var sum = 0.0;
    for (final d in _currentTypeDemands) {
      sum += _netAmt(d);
    }
    return sum;
  }

  /// Switch between collecting Regular and Arrear fees. Resets the fee-type
  /// filter and re-scopes the selection + Col Amounts to the chosen type so a
  /// receipt only ever contains one type.
  void _switchSeqType(String t) {
    if (_seqType == t) return;
    if (t == 'REGULAR' && _regularLocked) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Clear the arrear dues before collecting regular fees.'),
        backgroundColor: AppColors.warning,
      ));
      return;
    }
    setState(() {
      _seqType = t;
      _selectedTerm = null;
      _selected.clear();
      for (final d in _allDemands) {
        final k = _demKey(d);
        final active = _matchesSeqType(d);
        final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
        _conCtrl[k]?.text = (active && bal > 0) ? bal.toStringAsFixed(0) : '0';
        if (active && bal > 0) _selected.add(k);
      }
    });
  }

  Widget _buildSeqTypeToggle() {
    Widget seg(String label, String value, IconData icon) {
      final active = _seqType == value;
      final locked = value == 'REGULAR' && _regularLocked;
      final fg = active ? Colors.white : (locked ? AppColors.textLight : AppColors.textSecondary);
      final content = InkWell(
        onTap: () => _switchSeqType(value),
        borderRadius: BorderRadius.circular(8.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
          decoration: BoxDecoration(
            color: active ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8.r),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(locked ? Icons.lock_outline : icon, size: 15, color: fg),
              SizedBox(width: 6.w),
              Text(label, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: fg)),
            ],
          ),
        ),
      );
      return locked ? Tooltip(message: 'Clear arrear dues first', child: content) : content;
    }

    return Container(
      padding: EdgeInsets.all(3.w),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('Regular', 'REGULAR', Icons.receipt_long_rounded),
          seg('Arrear', 'ARREAR', Icons.history_rounded),
        ],
      ),
    );
  }

  /// Static badge shown when the student has demands of ONLY one type, so the
  /// cashier can still tell at a glance whether they're collecting a Regular or
  /// an Arrear demand (the Regular/Arrear toggle only appears when both exist).
  Widget _buildSingleTypeBadge(String type) {
    final isArrear = type == 'ARREAR';
    final color = isArrear ? const Color(0xFFB45309) : AppColors.accent;
    final bg = isArrear ? const Color(0xFFFEF3C7) : AppColors.accent.withValues(alpha: 0.12);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isArrear ? Icons.history_rounded : Icons.receipt_long_rounded, size: 15, color: color),
          SizedBox(width: 6.w),
          Text(isArrear ? 'Arrear' : 'Regular',
              style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Top: Student Lookup (horizontal) ──
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: _buildStudentLookupContent(),
            ),
            SizedBox(height: 12.h),
            // Body
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_student != null) ...[
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.border),
                      ),
                      padding: EdgeInsets.all(12.w),
                      child: _buildStudentCardContent(),
                    ),
                    SizedBox(height: 12.h),
                  ],
                  // ── Demands ──
                  Expanded(child: _buildDemandsPanel()),
                ],
              ),
            ),
          ],
        ),
        // Floating suggestions popup anchored under the search field — matches
        // the Fee Concession concession-popup style: UPPERCASE name + adm no +
        // class on a single line, first row tinted, hover in accent.
        if (_studentSuggestions.isNotEmpty || _classSuggestions.isNotEmpty)
          Positioned(
            width: _compactCtx ? 340.w : 480.w,
            child: CompositedTransformFollower(
              link: _admSearchLink,
              showWhenUnlinked: false,
              // Anchor to the search field's right edge so the (now wider) popup
              // grows leftward into the empty space instead of off-screen.
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, 6),
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(12.r),
                color: Colors.white,
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 480.h),
                  child: Builder(builder: (_) {
                    final source = _studentSuggestions.isNotEmpty ? _studentSuggestions : _classSuggestions;
                    return ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.symmetric(vertical: 4.h),
                      itemCount: source.length,
                      itemBuilder: (_, i) {
                        final s = source[i];
                        final name = (s['stuname']?.toString() ?? '').toUpperCase();
                        final admno = s['stuadmno']?.toString() ?? '';
                        final selected = i == 0;
                        return InkWell(
                          onTap: () => _selectSuggestion(s),
                          hoverColor: AppColors.accent.withValues(alpha: 0.06),
                          child: Container(
                            decoration: BoxDecoration(
                              color: selected ? AppColors.tableHeadBg : Colors.transparent,
                              border: i < source.length - 1
                                  ? Border(bottom: BorderSide(color: AppColors.border.withValues(alpha: 0.4)))
                                  : null,
                            ),
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                            // Uniform 3-column layout: Roll No | Name | Status,
                            // each a fixed slot so they line up down the list.
                            child: Row(children: [
                              // Roll No / Admn No (single identifier column)
                              SizedBox(
                                width: _compactCtx ? 110.w : 132.w,
                                child: Text(
                                  admno,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: _compactCtx ? 10 : 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                              SizedBox(width: 14.w),
                              // Name
                              Expanded(
                                child: Text(
                                  name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: _compactCtx ? 11 : 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                              SizedBox(width: 14.w),
                              // Status (fixed column so PAID/PENDING align across rows)
                              SizedBox(
                                width: _compactCtx ? 74.w : 88.w,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Builder(builder: (_) {
                                    final id = s['stu_id'];
                                    if (id is! int || !_balanceByStu.containsKey(id)) {
                                      return const SizedBox.shrink();
                                    }
                                    final bal = _balanceByStu[id]!;
                                    final paid = bal <= 0;
                                    final color = paid ? AppColors.success : AppColors.warning;
                                    return Container(
                                      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(color: color.withValues(alpha: 0.35)),
                                      ),
                                      child: Text(
                                        paid ? 'PAID' : 'PENDING',
                                        style: TextStyle(
                                          fontSize: _compactCtx ? 9 : 11,
                                          fontWeight: FontWeight.w800,
                                          color: color,
                                          letterSpacing: 0.3,
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              ),
                            ]),
                          ),
                        );
                      },
                    );
                  }),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Student Lookup ──
  Widget _buildStudentLookupContent() {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Single-line bar matching the Fee Collection reference: icon +
          // title + subtitle on the left, then Course/Class dropdowns +
          // search + Clear button all inline on the right.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const CardTitleBlock(icon: 'receipt-2', title: 'Fee Collection', subtitle: 'collect fees for the selected student'),
              const Spacer(),
              SizedBox(
                width: _compactCtx ? 150.w : 180.w,
                child: DropdownButtonFormField<String>(
                  value: _selectedCourse,
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(12.r),
                  elevation: 6,
                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                  decoration: _inputDec('Select Course', filled: _selectedCourse != null),
                  style: _ddTextStyle(),
                  hint: Text('Select Course',
                      style: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: _compactCtx ? 11 : 14)),
                  items: _courseList.map((c) => DropdownMenuItem(value: c, child: Text(c, style: _ddItemStyle()))).toList(),
                  selectedItemBuilder: (context) => _courseList.map((c) => Align(alignment: Alignment.centerLeft, child: Text(c, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: _compactCtx ? 11 : 14, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
                  onChanged: (val) {
                    setState(() {
                      _selectedCourse = val;
                      _selectedClass = null;
                      _classSuggestions = [];
                      if (val != null && _courseClassMap.containsKey(val)) {
                        _classList = List<String>.from(_courseClassMap[val]!);
                      } else if (val != null) {
                        _classList = List<String>.from(_allClasses);
                      } else {
                        _classList = List<String>.from(_allClasses);
                      }
                      _classList.sort(classOrdidComparator(_classOrdid));
                      if (val != null && val.startsWith('M') && _classList.length > 2) {
                        _classList = _classList.sublist(0, 2);
                      }
                    });
                  },
                ),
              ),
              SizedBox(width: 10.w),
              SizedBox(
                width: _compactCtx ? 150.w : 180.w,
                child: Builder(builder: (_) {
                  final seen = <String>{};
                  final items = <DropdownMenuItem<String>>[];
                  for (final c in _classList) {
                    if (c.isEmpty || !seen.add(c)) continue;
                    items.add(DropdownMenuItem(value: c, child: Text(c, style: _ddItemStyle())));
                  }
                  final value = seen.contains(_selectedClass) ? _selectedClass : null;
                  return DropdownButtonFormField<String>(
                    key: ValueKey(_selectedCourse),
                    value: value,
                    isExpanded: true,
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12.r),
                    elevation: 6,
                    icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                    decoration: _inputDec('Select Class', filled: value != null),
                    style: _ddTextStyle(),
                    hint: Text('Select Class',
                        style: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: _compactCtx ? 11 : 14)),
                    items: items,
                    selectedItemBuilder: (context) => items.map((m) => Align(alignment: Alignment.centerLeft, child: Text((m.child as Text).data ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: _compactCtx ? 11 : 14, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedClass = val;
                        _classController.text = val ?? '';
                        _classSuggestions = [];
                      });
                      if (val != null) _searchByClass(val);
                    },
                  );
                }),
              ),
              SizedBox(width: 10.w),
              CompositedTransformTarget(
                link: _admSearchLink,
                child: SizedBox(
                  width: _compactCtx ? 260.w : 340.w,
                  child: TextField(
                    controller: _admNoController,
                    onSubmitted: (_) => _search(),
                    onChanged: (v) { setState(() {}); _onSearchChanged(v); },
                    decoration: _inputDec('Admission No or Student Name', filled: _admNoController.text.trim().isNotEmpty).copyWith(
                      prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.textLight),
                    ),
                    style: _ddTextStyle().copyWith(color: _admNoController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              SizedBox(width: 10.w),
              SizedBox(
                height: _compactCtx ? 36.0 : 44.0,
                child: ElevatedButton.icon(
                  onPressed: _clear,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Clear'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: EdgeInsets.symmetric(horizontal: _compactCtx ? 16.w : 22.w),
                    textStyle: TextStyle(fontSize: _compactCtx ? 11.sp : 13.sp, fontWeight: FontWeight.w700),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_compactCtx ? 6.r : 8.r)),
                  ),
                ),
              ),
            ],
          ),
          if (_errorMsg != null) ...[
            SizedBox(height: 10.h),
            Container(
              padding: EdgeInsets.all(10.w),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                    color: AppColors.error.withValues(alpha: 0.3)),
              ),
              child: Text(_errorMsg!,
                  style: TextStyle(
                      fontSize: 13.sp, color: AppColors.error)),
            ),
          ],
        ],
      );
  }

  // ── Student Card ──
  Widget _buildStudentCardContent() {
    final name = _student!['stuname']?.toString() ?? '-';
    final admNo = _student!['stuadmno']?.toString() ?? '-';
    final className = _student!['stuclass']?.toString() ?? '-';
    final fatherName = _parent?['fathername']?.toString() ?? '-';
    final courseName = _student!['courname']?.toString() ?? '-';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Builder(builder: (_) {
          final photo = _student!['stuphoto']?.toString();
          final fallback = CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.accent.withValues(alpha: 0.12),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w700,
                  fontSize: 18.sp),
            ),
          );
          if (photo == null || photo.isEmpty) return fallback;
          return CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.accent.withValues(alpha: 0.12),
            backgroundImage: NetworkImage(photo),
            onBackgroundImageError: (_, __) {},
          );
        }),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: TextStyle(
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary),
                  overflow: TextOverflow.ellipsis),
              SizedBox(height: 2.h),
              Text('Roll No: $admNo',
                  style: TextStyle(
                      fontSize: 13.sp, color: AppColors.textSecondary)),
            ],
          ),
        ),
        SizedBox(width: 16.w),
        Container(width: 1, height: 36.h, color: AppColors.border),
        SizedBox(width: 16.w),
        Expanded(child: _detailRow('user', 'Father', fatherName)),
        SizedBox(width: 16.w),
        Container(width: 1, height: 36.h, color: AppColors.border),
        SizedBox(width: 16.w),
        Expanded(child: _detailRow('book-1', 'Course', courseName)),
        SizedBox(width: 16.w),
        Container(width: 1, height: 36.h, color: AppColors.border),
        SizedBox(width: 16.w),
        Expanded(child: _detailRow('teacher', 'Class', className)),
        SizedBox(width: 12.w),
        SizedBox(
          height: _compactCtx ? 36.0 : 44.0,
          child: OutlinedButton.icon(
            onPressed: _openStudentReceipts,
            icon: const Icon(Icons.receipt_long_outlined, size: 16),
            label: const Text('Receipts'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accent,
              side: const BorderSide(color: AppColors.accent),
              padding: EdgeInsets.symmetric(horizontal: _compactCtx ? 14.w : 18.w),
              textStyle: TextStyle(fontSize: _compactCtx ? 11.sp : 13.sp, fontWeight: FontWeight.w700),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_compactCtx ? 6.r : 8.r)),
            ),
          ),
        ),
        SizedBox(width: 8.w),
        SizedBox(
          height: _compactCtx ? 36.0 : 44.0,
          child: ElevatedButton.icon(
            onPressed: _openFeeDefinition,
            icon: const Icon(Icons.fact_check_outlined, size: 16),
            label: const Text('Fee Definition'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: EdgeInsets.symmetric(horizontal: _compactCtx ? 16.w : 22.w),
              textStyle: TextStyle(fontSize: _compactCtx ? 11.sp : 13.sp, fontWeight: FontWeight.w700),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_compactCtx ? 6.r : 8.r)),
            ),
          ),
        ),
      ],
    );
  }

  /// Open the per-student fee definition (opt the student in/out of each fee).
  Future<void> _openFeeDefinition() async {
    final s = _student;
    if (s == null) return;
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StudentFeeDefinitionDialog(
        insId: insId,
        stuAdmno: s['stuadmno']?.toString() ?? '',
        stuName: s['stuname']?.toString() ?? '',
        admName: s['admname']?.toString() ?? '',
      ),
    );
    if (saved == true) {
      // Reload demands so newly-opted fees appear. _search() resolves by the
      // search field, which after the previous search holds the student NAME
      // (a fuzzy name match could land on a different student). Restore the
      // exact roll no first so _search's exact stuadmno lookup re-resolves
      // THIS student.
      _admNoController.text = s['stuadmno']?.toString() ?? '';
      _search();
    }
  }

  String _fmtReceiptDate(dynamic v) {
    if (v == null) return '-';
    final dt = DateTime.tryParse(v.toString());
    if (dt == null) return v.toString();
    final l = dt.toLocal();
    return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')}/${l.year}';
  }

  /// Show the selected student's receipts with a per-row delete (void) option.
  Future<void> _openStudentReceipts() async {
    final s = _student;
    if (s == null) return;
    final stuId = s['stu_id'] as int?;
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (stuId == null || insId == null) return;

    Future<List<Map<String, dynamic>>> load() async {
      final rows = await SupabaseService.fromSchema('payment')
          .select('pay_id, paynumber, paydate, createdat, transtotalamount, paymethod, recon_status')
          .eq('ins_id', insId)
          .eq('stu_id', stuId)
          .eq('activestatus', 1)
          .eq('paystatus', 'C')
          .order('createdat', ascending: false);
      final payments = List<Map<String, dynamic>>.from(rows as List);
      if (payments.isEmpty) return payments;

      // Attach each receipt's fee-line breakdown (paymentdetails -> feedemand).
      final payIds = payments.map((p) => p['pay_id']).whereType<int>().toList();
      final detRows = await SupabaseService.fromSchema('paymentdetails')
          .select('pay_id, dem_id, transtotalamount')
          .inFilter('pay_id', payIds)
          .eq('activestatus', 1);
      final dets = List<Map<String, dynamic>>.from(detRows as List);
      final demIds = dets.map((d) => d['dem_id']).whereType<int>().toSet().toList();
      final demInfo = <int, Map<String, dynamic>>{};
      if (demIds.isNotEmpty) {
        final demRows = await SupabaseService.fromSchema('feedemand')
            .select('dem_id, demfeetype, demfeeterm')
            .inFilter('dem_id', demIds);
        for (final d in List<Map<String, dynamic>>.from(demRows as List)) {
          final id = d['dem_id'] as int?;
          if (id != null) demInfo[id] = d;
        }
      }
      final byPay = <int, List<Map<String, dynamic>>>{};
      for (final d in dets) {
        final pid = d['pay_id'] as int?;
        if (pid == null) continue;
        final info = demInfo[d['dem_id'] as int?];
        byPay.putIfAbsent(pid, () => []).add({
          'type': info?['demfeetype']?.toString() ?? 'Fee',
          'term': info?['demfeeterm']?.toString() ?? '',
          'amount': (d['transtotalamount'] as num?)?.toDouble() ?? 0,
        });
      }
      for (final p in payments) {
        p['_details'] = byPay[p['pay_id'] as int?] ?? const [];
      }
      return payments;
    }

    await showDialog<void>(
      context: context,
      builder: (dctx) {
        return StatefulBuilder(builder: (dctx, setDlg) {
          // Small chip that identifies the tender used for a receipt.
          Widget methodChip(String methodRaw) {
            final m = methodRaw.toLowerCase();
            IconData ic;
            Color c;
            if (m.contains('cash')) {
              ic = Icons.payments_rounded; c = const Color(0xFF059669);
            } else if (m.contains('upi') || m.contains('qr')) {
              ic = Icons.qr_code_2_rounded; c = AppColors.accent;
            } else if (m.contains('cheque') || m.contains('dd')) {
              ic = Icons.description_rounded; c = const Color(0xFFB45309);
            } else if (m.contains('razor') || m.contains('online') || m.contains('net')) {
              ic = Icons.public_rounded; c = AppColors.accent;
            } else {
              ic = Icons.account_balance_wallet_rounded; c = AppColors.textSecondary;
            }
            return Container(
              padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6.r),
                border: Border.all(color: c.withValues(alpha: 0.30)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(ic, size: 12, color: c),
                SizedBox(width: 4.w),
                Text(methodRaw.isEmpty ? '—' : methodRaw.toUpperCase(),
                    style: TextStyle(fontSize: 10.sp, fontWeight: FontWeight.w700, color: c, letterSpacing: 0.2)),
              ]),
            );
          }

          Widget iconBtn({required IconData icon, required Color color, required String tip, VoidCallback? onTap}) {
            final enabled = onTap != null;
            return Tooltip(
              message: tip,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(9.r),
                child: Container(
                  padding: EdgeInsets.all(8.w),
                  decoration: BoxDecoration(
                    color: enabled ? color.withValues(alpha: 0.10) : AppColors.border.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(9.r),
                    border: Border.all(color: enabled ? color.withValues(alpha: 0.40) : AppColors.border),
                  ),
                  child: Icon(icon, size: 16, color: enabled ? color : AppColors.textLight),
                ),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18.r)),
            titlePadding: EdgeInsets.fromLTRB(20.w, 18.h, 16.w, 6.h),
            contentPadding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 4.h),
            actionsPadding: EdgeInsets.fromLTRB(20.w, 0, 16.w, 14.h),
            title: Row(children: [
              Container(
                padding: EdgeInsets.all(9.w),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11.r),
                ),
                child: AppIcon('receipt-2', size: 18, color: AppColors.accent),
              ),
              SizedBox(width: 11.w),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('Receipts', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                  SizedBox(height: 1.h),
                  Text(
                    '${s['stuname'] ?? ''}'
                    '${(s['stuadmno']?.toString() ?? '').isNotEmpty ? '  •  ${s['stuadmno']}' : ''}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5.sp, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
                  ),
                ]),
              ),
            ]),
            content: SizedBox(
              width: 560.w,
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: load(),
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator()));
                  }
                  final receipts = snap.data ?? [];
                  if (receipts.isEmpty) {
                    return Padding(
                      padding: EdgeInsets.symmetric(vertical: 28.h),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.receipt_long_rounded, size: 40, color: AppColors.textLight),
                        SizedBox(height: 10.h),
                        Text('No receipts yet', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                        SizedBox(height: 2.h),
                        Text('Collected payments for this student will appear here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11.sp, color: AppColors.textLight)),
                      ]),
                    );
                  }
                  final grandTotal = receipts.fold<double>(
                      0, (t, p) => t + ((p['transtotalamount'] as num?)?.toDouble() ?? 0));
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(bottom: 8.h),
                        child: Row(children: [
                          Text('${receipts.length} receipt${receipts.length == 1 ? '' : 's'}',
                              style: TextStyle(fontSize: 11.5.sp, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                          const Spacer(),
                          Text('Total  ', style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                          Text('₹${formatIndianNumber(grandTotal)}',
                              style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
                        ]),
                      ),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: 400.h),
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: receipts.length,
                            itemBuilder: (_, i) {
                              final p = receipts[i];
                              final no = p['paynumber']?.toString() ?? '-';
                              final method = (p['paymethod']?.toString() ?? '').toLowerCase();
                              final recon = p['recon_status']?.toString() ?? 'P';
                              final locked = recon == 'R' && method != 'cash';
                              final amt = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
                              final date = _fmtReceiptDate(p['paydate'] ?? p['createdat']);
                              final details = (p['_details'] as List?) ?? const [];
                              return Container(
                                margin: EdgeInsets.only(bottom: 10.h),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12.r),
                                  border: Border.all(color: AppColors.border),
                                  boxShadow: const [
                                    BoxShadow(color: Color.fromRGBO(15, 23, 42, 0.04), offset: Offset(0, 2), blurRadius: 8),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // ── Receipt header ──
                                    Padding(
                                      padding: EdgeInsets.fromLTRB(12.w, 11.h, 10.w, 11.h),
                                      child: Row(children: [
                                        Expanded(
                                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                            Row(children: [
                                              Flexible(
                                                child: Text(no,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                                              ),
                                              if (locked) ...[
                                                SizedBox(width: 8.w),
                                                Container(
                                                  padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 2.h),
                                                  decoration: BoxDecoration(
                                                    color: AppColors.success.withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(5.r),
                                                  ),
                                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                    Icon(Icons.verified_rounded, size: 11, color: AppColors.success),
                                                    SizedBox(width: 3.w),
                                                    Text('RECONCILED',
                                                        style: TextStyle(fontSize: 9.sp, fontWeight: FontWeight.w800, color: AppColors.success, letterSpacing: 0.3)),
                                                  ]),
                                                ),
                                              ],
                                            ]),
                                            SizedBox(height: 5.h),
                                            Row(children: [
                                              Icon(Icons.event_rounded, size: 12, color: AppColors.textLight),
                                              SizedBox(width: 4.w),
                                              Text(date, style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                                              SizedBox(width: 8.w),
                                              methodChip(p['paymethod']?.toString() ?? ''),
                                            ]),
                                          ]),
                                        ),
                                        SizedBox(width: 10.w),
                                        Text('₹${formatIndianNumber(amt)}',
                                            style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
                                        SizedBox(width: 12.w),
                                        iconBtn(
                                          icon: Icons.print_rounded,
                                          color: AppColors.accent,
                                          tip: 'View / print receipt',
                                          onTap: () {
                                            final pid = (p['pay_id'] as num?)?.toInt();
                                            Navigator.pop(dctx);
                                            if (pid != null) _downloadReceipt(pid, no);
                                          },
                                        ),
                                        SizedBox(width: 8.w),
                                        iconBtn(
                                          icon: Icons.delete_outline_rounded,
                                          color: AppColors.error,
                                          tip: locked ? 'Reconciled — cannot delete' : 'Delete receipt',
                                          onTap: locked ? null : () async {
                                            final done = await _voidReceiptFromDialog(p);
                                            if (done) setDlg(() {});
                                          },
                                        ),
                                      ]),
                                    ),
                                    // ── Fee breakdown ──
                                    if (details.isNotEmpty)
                                      Container(
                                        width: double.infinity,
                                        padding: EdgeInsets.fromLTRB(12.w, 8.h, 12.w, 9.h),
                                        decoration: BoxDecoration(
                                          color: AppColors.surface,
                                          borderRadius: BorderRadius.only(
                                            bottomLeft: Radius.circular(11.r),
                                            bottomRight: Radius.circular(11.r),
                                          ),
                                          border: Border(top: BorderSide(color: AppColors.border)),
                                        ),
                                        child: Column(
                                          children: [
                                            for (final d in details)
                                              Padding(
                                                padding: EdgeInsets.symmetric(vertical: 2.5.h),
                                                child: Row(children: [
                                                  Container(width: 4.w, height: 4.w, margin: EdgeInsets.only(right: 8.w),
                                                      decoration: BoxDecoration(color: AppColors.textLight, shape: BoxShape.circle)),
                                                  Expanded(
                                                    child: Text(
                                                      (d['term']?.toString() ?? '').isNotEmpty
                                                          ? '${d['type']} — ${d['term']}'
                                                          : '${d['type']}',
                                                      style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary),
                                                    ),
                                                  ),
                                                  Text('₹${formatIndianNumber((d['amount'] as num?)?.toDouble() ?? 0)}',
                                                      style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                                ]),
                                              ),
                                            Padding(
                                              padding: EdgeInsets.only(top: 6.h),
                                              child: Row(children: [
                                                Expanded(child: Container(height: 1, color: AppColors.border)),
                                              ]),
                                            ),
                                            Padding(
                                              padding: EdgeInsets.only(top: 6.h),
                                              child: Row(children: [
                                                Text('Total', style: TextStyle(fontSize: 11.5.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                                                const Spacer(),
                                                Text('₹${formatIndianNumber(amt)}',
                                                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                                              ]),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  padding: EdgeInsets.symmetric(horizontal: 18.w, vertical: 10.h),
                ),
                child: Text('Close', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700)),
              ),
            ],
          );
        });
      },
    );
    // A delete restores demands to pending — refresh the page for this student.
    if (mounted) {
      _admNoController.text = s['stuadmno']?.toString() ?? '';
      _search();
    }
  }

  /// Confirm + void a single receipt from the receipts dialog. Returns true
  /// when the receipt was deleted (so the dialog list can reload).
  Future<bool> _voidReceiptFromDialog(Map<String, dynamic> p) async {
    final payId = p['pay_id'] as int?;
    if (payId == null) return false;
    final no = p['paynumber']?.toString() ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.r)),
        title: const Text('Delete Receipt'),
        content: Text('Delete receipt $no?\n\nThis voids the receipt and restores the fees it collected back to pending.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    try {
      final auth = context.read<AuthProvider>();
      await SupabaseService.voidReceipt(payId, insId: auth.insId ?? 0, user: auth.userName ?? '');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Receipt $no deleted'), backgroundColor: AppColors.success));
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed. ${friendlyError(e)}'), backgroundColor: AppColors.error));
      }
      return false;
    }
  }

  // ── Term Filter ──
  Widget _buildTermFilterContent() {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Filter by Term',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  )),
          SizedBox(height: 10.h),
          DropdownButtonFormField<String?>(
            value: _selectedTerm,
            isExpanded: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
            decoration: InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: BorderSide(color: _selectedTerm != null ? AppColors.accent : AppColors.border, width: 1.5)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: BorderSide(color: _selectedTerm != null ? AppColors.accent : AppColors.border, width: 1.5)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
            ),
            items: [
              DropdownMenuItem<String?>(value: null, child: Text('All', style: TextStyle(fontSize: 13.sp))),
              ..._terms.map((t) => DropdownMenuItem<String?>(value: t, child: Text(t, style: TextStyle(fontSize: 13.sp)))),
            ],
            selectedItemBuilder: (context) => [
              Align(alignment: Alignment.centerLeft, child: Text('All', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
              ..._terms.map((t) => Align(alignment: Alignment.centerLeft, child: Text(t, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))),
            ],
            onChanged: (v) => setState(() => _selectedTerm = v),
          ),
        ],
      );
  }


  // ── Demands Panel ──
  Widget _buildDemandsPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Panel header
          Container(
            padding:
                const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                AppIcon.linear('document-text', size: 18, color: AppColors.accent),
                SizedBox(width: 8.w),
                Text('Pending Fee Demands',
                    style: TextStyle(
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        )),
                if (_allDemands.isNotEmpty) ...[
                  SizedBox(width: 8.w),
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: 8.w, vertical: 2.h),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12.r),
                    ),
                    child: Text(
                      '${_filteredDemands.length} of ${_currentTypeDemands.length} items',
                      style: TextStyle(
                          fontSize: 13.sp,
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
                const Spacer(),
                if (_student != null && _hasRegular && _hasArrear) ...[
                  _buildSeqTypeToggle(),
                  SizedBox(width: 12.w),
                ] else if (_student != null && _allDemands.isNotEmpty) ...[
                  _buildSingleTypeBadge(_hasArrear ? 'ARREAR' : 'REGULAR'),
                  SizedBox(width: 12.w),
                ],
                if (_student != null && _terms.isNotEmpty) ...[
                  Text('Fee Type:', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  SizedBox(width: 8.w),
                  SizedBox(
                    width: 200.w,
                    height: 50,
                    child: DropdownButtonFormField<String?>(
                      value: _selectedTerm,
                      isExpanded: true,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                      icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                      decoration: _headerDropdownDec(filled: _selectedTerm != null),
                      items: [
                        DropdownMenuItem<String?>(value: null, child: Text('All', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700))),
                        ..._terms.map((t) => DropdownMenuItem<String?>(value: t, child: Text(t, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis))),
                      ],
                      selectedItemBuilder: (context) => [
                        Align(alignment: Alignment.centerLeft, child: Text('All', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                        ..._terms.map((t) => Align(alignment: Alignment.centerLeft, child: Text(t, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))),
                      ],
                      onChanged: (v) => setState(() => _selectedTerm = v),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Content
          Expanded(child: _buildDemandsContent()),
        ],
      ),
    );
  }

  Widget _buildDemandsContent() {
    if (_loadingDemands) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.accent));
    }

    if (_student == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon('search-normal-1',
                size: 52.sp, color: Colors.grey.shade300),
            SizedBox(height: 12.h),
            Text('Search a student to view pending fees',
                style: TextStyle(
                    fontSize: 13.sp, color: Colors.grey.shade400)),
          ],
        ),
      );
    }

    if (_filteredDemands.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon.linear('tick-circle',
                size: 52.sp, color: Colors.green.shade300),
            SizedBox(height: 12.h),
            Text('No pending fee demands',
                style:
                    TextStyle(fontSize: 13.sp, color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    final demands = _filteredDemands;
    final allSelected = demands.isNotEmpty &&
        demands.every((d) => _selected.contains(_demKey(d)));

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
      children: [
        // Table header + rows, sharing a reserved scrollbar lane
        Expanded(
          child: AppVerticalScrollbar(
            header: Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
          child: Row(
            children: [
              SizedBox(
                width: 32.w,
                child: Checkbox(
                  value: allSelected,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        for (final d in demands) {
                          final k = _demKey(d);
                          _selected.add(k);
                          final b = (d['balancedue'] as num?)?.toDouble() ?? 0;
                          final ctrl = _conCtrl[k];
                          if (ctrl != null && b > 0) {
                            ctrl.text = b.toStringAsFixed(0);
                          }
                        }
                      } else {
                        for (final d in demands) {
                          final k = _demKey(d);
                          _selected.remove(k);
                          final ctrl = _conCtrl[k];
                          if (ctrl != null) ctrl.text = '0';
                        }
                      }
                    });
                  },
                  fillColor: WidgetStateProperty.resolveWith((s) =>
                      s.contains(WidgetState.selected)
                          ? AppColors.accent
                          : Colors.transparent),
                  side: BorderSide(color: AppColors.border),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const _THCell('Semester', flex: 2),
              const _THCell('Fee Type', flex: 3),
              const _THCell('Due Date', flex: 3),
              const _THCell('Fee Amt', flex: 2, textAlign: TextAlign.right),
              const _THCell('Bal. Amt', flex: 2, textAlign: TextAlign.right),
              const _THCell('Col Amount', flex: 2, textAlign: TextAlign.center),
              const _THCell('Fine', flex: 2, textAlign: TextAlign.center),
              const _THCell('Net Amt', flex: 1, textAlign: TextAlign.right),
            ],
          ),
        ),
            builder: (context, controller) => FocusTraversalGroup(child: ListView.separated(
            controller: controller,
            itemCount: demands.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: Color(0xFFEEEEEE)),
            itemBuilder: (context, i) {
              final d = demands[i];
              final key = _demKey(d);
              final isSelected = _selected.contains(key);
              final feeAmt =
                  (d['feeamount'] as num?)?.toDouble() ?? 0;
              final bal =
                  (d['balancedue'] as num?)?.toDouble() ?? 0;
              final dueDate = d['duedate']?.toString() ?? '-';
              final shortDate = dueDate.length >= 10
                  ? _formatDate(dueDate.substring(0, 10))
                  : dueDate;

              return FocusTraversalGroup(child: Container(
                key: ValueKey('row-$key'),
                // Proper zebra: alternate white / warm stone by row parity,
                // independent of selection (surface #F9F8F4 was too close to
                // white to read).
                color: i.isEven ? Colors.white : AppColors.accent.withValues(alpha: 0.05),
                padding: EdgeInsets.symmetric(
                    horizontal: 12.w, vertical: 10.h),
                child: Row(
                  children: [
                    SizedBox(
                      width: 32.w,
                      child: Checkbox(
                        value: isSelected,
                        onChanged: (v) {
                          // Checking auto-fills Col Amount with the row's
                          // balance; unchecking resets it to 0 so it
                          // doesn't get included in any subsequent total.
                          final colCtrl = _conCtrl[key];
                          setState(() {
                            if (v == true) {
                              _selected.add(key);
                              if (colCtrl != null && bal > 0) {
                                colCtrl.text = bal.toStringAsFixed(0);
                              }
                            } else {
                              _selected.remove(key);
                              if (colCtrl != null) colCtrl.text = '0';
                            }
                          });
                        },
                        fillColor: WidgetStateProperty.resolveWith((s) =>
                            s.contains(WidgetState.selected)
                                ? AppColors.accent
                                : null),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    _TDCell(d['demfeeterm']?.toString() ?? '-',
                        flex: 2,
                        style: TextStyle(
                            fontSize: 13.sp,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary)),
                    _TDCell(d['demfeetype']?.toString() ?? '-',
                        flex: 3,
                        style: TextStyle(
                            fontSize: 13.sp,
                            color: AppColors.textSecondary)),
                    _TDCell(shortDate,
                        flex: 3,
                        style: TextStyle(
                            fontSize: 13.sp,
                            color: AppColors.textSecondary)),
                    _TDCell(formatIndianNumber(feeAmt),
                        flex: 2,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 13.sp,
                            color: AppColors.textPrimary)),
                    _TDCell(formatIndianNumber(bal),
                        flex: 2,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 13.sp,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFFE87722))),
                    // Col Amount editable — clamp to balance due. Typing a
                    // positive amount auto-checks the row; clearing it back
                    // to 0 / empty auto-unchecks. setState is gated so it
                    // only fires when the selection actually flips (or on
                    // clamp), so the TextField keeps focus on every
                    // keystroke within the same state. The selected-tint and
                    // NET AMOUNT total still refresh on those flips.
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4.w),
                        child: _numField(_conCtrl[key], () {
                          final ctrl = _conCtrl[key];
                          double entered = 0;
                          bool clamped = false;
                          if (ctrl != null) {
                            entered = double.tryParse(ctrl.text) ?? 0;
                            if (entered > bal) {
                              final clampedText = bal.toStringAsFixed(0);
                              ctrl.value = TextEditingValue(
                                text: clampedText,
                                selection: TextSelection.collapsed(offset: clampedText.length),
                              );
                              entered = bal;
                              clamped = true;
                              if (mounted) {
                                ScaffoldMessenger.of(context)
                                  ..hideCurrentSnackBar()
                                  ..showSnackBar(
                                    SnackBar(
                                      content: Text('Collection amount cannot exceed balance due (${formatIndianNumber(bal)})'),
                                      backgroundColor: Colors.red,
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                              }
                            }
                          }
                          // Debounce the auto-check setState — keystrokes
                          // within the same row reset a 350ms timer. The
                          // setState fires only once after typing pauses, so
                          // the user can type 5000 without losing focus per
                          // digit. Clamp errors are surfaced immediately,
                          // since those require a snackbar.
                          if (clamped) {
                            setState(() {});
                          }
                          _conFlipTimers[key]?.cancel();
                          _conFlipTimers[key] = Timer(const Duration(milliseconds: 350), () {
                            if (!mounted) return;
                            final c = _conCtrl[key];
                            if (c == null) return;
                            final v = double.tryParse(c.text) ?? 0;
                            final shouldSelect = v > 0;
                            final isAlready = _selected.contains(key);
                            if (shouldSelect == isAlready) return;
                            // Capture focus before the rebuild and re-grab
                            // it afterwards. Without this the row's
                            // selection-state rebuild can drop focus on the
                            // Col Amount field — particularly when the user
                            // is back-spacing the value down to 0.
                            final node = _conCtrl[key] != null ? _conFocus[key] : null;
                            final hadFocus = node?.hasFocus ?? false;
                            setState(() {
                              if (shouldSelect) {
                                _selected.add(key);
                              } else {
                                _selected.remove(key);
                              }
                            });
                            if (hadFocus && node != null) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted && !node.hasFocus) node.requestFocus();
                              });
                            }
                          });
                        }, fieldKey: 'col-$key', focusNode: _conFocus.putIfAbsent(key, () => FocusNode())),
                      ),
                    ),
                    // Fine editable — only when the row is checked. The
                    // cashier has to tick the row (or type a Col Amount that
                    // auto-checks it) before adjusting the fine.
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4.w),
                        child: _numField(_fineCtrl[key], () => setState(() {}), maxLength: 4, fieldKey: 'fine-$key', focusNode: _fineFocus.putIfAbsent(key, () => FocusNode()), enabled: isSelected),
                      ),
                    ),
                    // Net Amt — listens to the row's Col + Fine controllers
                    // so it refreshes on every keystroke instead of waiting
                    // for the debounce-driven setState.
                    Expanded(
                      flex: 1,
                      child: ListenableBuilder(
                        listenable: Listenable.merge([
                          if (_conCtrl[key] != null) _conCtrl[key]!,
                          if (_fineCtrl[key] != null) _fineCtrl[key]!,
                        ]),
                        builder: (_, __) {
                          final live = _netAmt(d);
                          return Text(
                            formatIndianNumber(live),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 13.sp,
                                fontWeight: FontWeight.w600,
                                color: live > 0
                                    ? AppColors.error
                                    : AppColors.textPrimary),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ));
            },
          )),
            ),
        ),

        // Footer
        Container(
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: AppColors.border)),
            borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(12.r),
                bottomRight: Radius.circular(12.r)),
          ),
          child: Row(
            children: [
              AppIcon.linear('tick-circle', size: 16, color: AppColors.accent),
              SizedBox(width: 6.w),
              Text(
                '${_selected.length} of ${demands.length} selected',
                style: TextStyle(
                    fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
              ),
              const Spacer(),
              if (_selected.isNotEmpty) ...[
                Container(
                  height: 44,
                  padding: EdgeInsets.symmetric(horizontal: 16.w),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    // Stronger fill + border so the figure pops against the
                    // surrounding white footer bar.
                    color: AppColors.accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10.r),
                    border: Border.all(color: AppColors.accent.withValues(alpha: 0.45), width: 1.2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('NET AMOUNT: ',
                          style: TextStyle(
                              fontSize: 14.sp,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                              letterSpacing: 0.3)),
                      // Live total — subscribes to every visible row's
                      // col/fine controller so it ticks per keystroke
                      // without rebuilding the TextField (which would steal
                      // focus mid-typing).
                      ListenableBuilder(
                        listenable: Listenable.merge([
                          ..._conCtrl.values,
                          ..._fineCtrl.values,
                        ]),
                        builder: (_, __) => Text(
                          '${formatIndianNumber(_totalNetSelected)}',
                          style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.accent),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 14.w),
              ],
              SizedBox(width: 6.w),
              // Payment-mode dropdown — sits just before the Save / Proceed
              // to Pay button so the cashier picks the mode and commits in
              // one motion.
              // Wrap a borderless DropdownButton in the same padded
              // container shape as the NET AMOUNT pill so the two visually
              // match in height + corner radius.
              Container(
                width: 160.w,
                height: 44,
                padding: EdgeInsets.symmetric(horizontal: 12.w),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // Match the NET AMOUNT pill's accent-tinted fill so the
                  // Mode field is visually clearly distinguished from the
                  // plain footer background.
                  color: AppColors.accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10.r),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.45), width: 1.2),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _paymentMode,
                    isExpanded: true,
                    isDense: false,
                    hint: Text('SELECT MODE', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary, letterSpacing: 0.3)),
                    icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    elevation: 6,
                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.accent, letterSpacing: 0.3),
                    items: const [
                      DropdownMenuItem(value: 'Cash', child: Text('CASH')),
                      DropdownMenuItem(value: 'QR/UPI', child: Text('QR/UPI')),
                      DropdownMenuItem(value: 'Paytm', child: Text('PAYTM')),
                      DropdownMenuItem(value: 'Cheque', child: Text('CHEQUE')),
                    ],
                    onChanged: _selected.isEmpty ? null : (v) => setState(() => _paymentMode = v),
                  ),
                ),
              ),
              SizedBox(width: 10.w),
              // Match the NET AMOUNT pill + Mode dropdown visually: same
              // accent-tinted fill, same border, same height, same corner
              // radius. Keeps the three footer elements as a unified triple.
              SizedBox(
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: (_selected.isEmpty || _paymentMode == null)
                      ? null
                      : (_paymentMode == 'Cash' ? _saveCashPayment : _onCollectAndReceipt),
                  icon: AppIcon(_paymentMode == 'Cash' ? 'save-2' : 'wallet-money', size: 16),
                  label: Text(_paymentMode == 'Cash' ? 'SAVE' : 'PROCEED TO PAY'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent.withValues(alpha: 0.18),
                    foregroundColor: AppColors.accent,
                    disabledBackgroundColor: Colors.grey.shade100,
                    disabledForegroundColor: AppColors.textSecondary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10.r),
                      side: BorderSide(color: AppColors.accent.withValues(alpha: 0.45), width: 1.2),
                    ),
                    padding: EdgeInsets.symmetric(horizontal: 20.w),
                    textStyle: TextStyle(
                        fontSize: 14.sp, fontWeight: FontWeight.w600, letterSpacing: 0.3),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
        ),
      ),
    );
  }

  bool _processing = false;

  /// Save a Cash payment. Runs the sequence pre-check then shows a small
  /// dialog asking for the tender amount; the refund (change) is computed
  /// live as the cashier types. Both values are stored on the payment row.
  Future<void> _saveCashPayment() async {
    final ok = await _ensureSequencesExist();
    if (!ok) return;
    _paymentMode = 'Cash';
    final total = _totalNetSelected;
    _tenderAmountController.text = total.toStringAsFixed(0);
    _cashTenderAmount = total;
    _cashRefundAmount = 0;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        void recompute() {
          final t = double.tryParse(_tenderAmountController.text) ?? 0;
          setSt(() {
            _cashTenderAmount = t;
            _cashRefundAmount = (t - total).clamp(0, double.infinity).toDouble();
          });
        }
        return Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
          insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 420.w),
            child: Padding(
              padding: EdgeInsets.all(22.w),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cash Payment',
                      style: TextStyle(fontSize: 18.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  SizedBox(height: 12.h),
                  _cashRow('Net Amount', '${formatIndianNumber(total)}', highlight: true),
                  SizedBox(height: 14.h),
                  Text('Tender Amount *', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                  SizedBox(height: 6.h),
                  TextField(
                    controller: _tenderAmountController,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
                    onChanged: (_) => recompute(),
                    decoration: InputDecoration(
                      hintText: 'Enter cash received',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: BorderSide(color: _tenderAmountController.text.trim().isNotEmpty ? AppColors.accent : AppColors.border, width: 1.5)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: BorderSide(color: _tenderAmountController.text.trim().isNotEmpty ? AppColors.accent : AppColors.border, width: 1.5)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
                    ),
                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: _tenderAmountController.text.trim().isNotEmpty ? AppColors.accent : null),
                  ),
                  if ((_cashTenderAmount ?? 0) < total && (_cashTenderAmount ?? 0) > 0) ...[
                    SizedBox(height: 6.h),
                    Text(
                      'Tender must be at least ${formatIndianNumber(total)}',
                      style: TextStyle(fontSize: 12.sp, color: AppColors.error, fontWeight: FontWeight.w600),
                    ),
                  ],
                  SizedBox(height: 14.h),
                  _cashRow('Refund (Change)', '${formatIndianNumber(_cashRefundAmount ?? 0)}'),
                  SizedBox(height: 20.h),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      SizedBox(width: 8.w),
                      Builder(builder: (_) {
                        final t = double.tryParse(_tenderAmountController.text) ?? 0;
                        final canConfirm = t >= total && total > 0;
                        return ElevatedButton(
                          onPressed: !canConfirm
                              ? null
                              : () {
                                  _cashTenderAmount = t;
                                  _cashRefundAmount = (t - total).clamp(0, double.infinity).toDouble();
                                  Navigator.pop(ctx, true);
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade300,
                            disabledForegroundColor: Colors.grey.shade600,
                            padding: EdgeInsets.symmetric(horizontal: 22.w, vertical: 12.h),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.r)),
                          ),
                          child: const Text('Confirm'),
                        );
                      }),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
    if (confirmed != true) return;
    await _processPayment();
  }

  Widget _cashRow(String label, String value, {bool highlight = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
        Text(value,
            style: TextStyle(
              fontSize: highlight ? 16.sp : 14.sp,
              fontWeight: FontWeight.w700,
              color: highlight ? AppColors.accent : AppColors.textPrimary,
            )),
      ],
    );
  }

  /// Shared pre-check: every fee group in the selected demands must have
  ///   (a) a payment sequence configured AND
  ///   (b) a bank account mapped (feegroup.ban_id).
  /// Returns false (with a snackbar) on the first missing requirement so the
  /// caller can abort the collection.
  Future<bool> _ensureSequencesExist() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return true;
    try {
      final sequences = await SupabaseService.fromSchema('sequence')
          .select('fg_id')
          .eq('ins_id', insId)
          .neq('actname', 'REGNO'); // exclude register-number sequences
      final seqFgIds = (sequences as List).map((s) => s['fg_id']).toSet();
      final feeGroups = await SupabaseService.fromSchema('feegroup')
          .select('fg_id, fgdesc, ban_id')
          .eq('ins_id', insId);
      final fgInfo = <int, Map<String, dynamic>>{
        for (final g in (feeGroups as List))
          (g['fg_id'] as int): Map<String, dynamic>.from(g as Map),
      };
      for (final key in _selected) {
        final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
        if (d.isEmpty) continue;
        final demfeetype = d['demfeetype']?.toString() ?? '';
        final ftResult = await SupabaseService.fromSchema('feetype')
            .select('fg_id')
            .eq('feedesc', demfeetype)
            .eq('activestatus', 1)
            .limit(1)
            .maybeSingle();
        final fgId = ftResult?['fg_id'];
        if (fgId == null) continue;
        final fgRow = fgInfo[fgId];
        final fgName = fgRow?['fgdesc']?.toString() ?? 'this fee group';
        if (!seqFgIds.contains(fgId)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Payment sequence missing for "$fgName". Create one in Sequence Creation before collecting.'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return false;
        }
        if (fgRow?['ban_id'] == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('No bank account mapped to "$fgName". Assign one in Bank Accounts → Fee Group Assignments before collecting.'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return false;
        }
      }
    } catch (_) {}
    return true;
  }

  Future<void> _onCollectAndReceipt() async {
    // Same pre-flight as Cash: every selected fee group must have BOTH a
    // payment sequence AND a bank account mapped in feegroup.ban_id.
    final ok = await _ensureSequencesExist();
    if (!ok) return;

    final totalNet = _totalNetSelected;
    // _paymentMode is already set by the inline chips in the bottom bar — don't
    // reset it to Cash here; preserve the user's choice (QR/UPI / Online / Cheque).
    _chequeNoController.clear();
    _chequeDateController.clear();
    _bankNameController.clear();
    _upiRefController.clear();
    _chequeDate = null;

    String? upiErr;
    String? chequeNoErr;
    String? chequeDateErr;
    String? bankNameErr;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          elevation: 0,
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 470.w),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 22.h),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20.r),
                border: Border.all(
                  color: Colors.grey.withValues(alpha: 0.1),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 60,
                    spreadRadius: 4,
                    offset: const Offset(0, 24),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 16,
                    spreadRadius: 0,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: FocusTraversalGroup(child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: FocusableTap(
                        onTap: () => Navigator.of(context).pop(),
                        child: AppIcon.linear('close-circle', size: 18, color: AppColors.textSecondary),
                      ),
                    ),
                    SizedBox(height: 14.h),
                    Text(
                      'Student: ${_student!['stuname']} (${_student!['stuadmno']})',
                      style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary),
                    ),
                    SizedBox(height: 6.h),
                    Text(
                      'Demands selected: ${_selected.length}',
                      style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary),
                    ),
                    SizedBox(height: 12.h),
                    Text(
                      'Total: ${formatIndianNumber(totalNet)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16.sp,
                        color: AppColors.accent,
                      ),
                    ),
                    SizedBox(height: 18.h),
                    Divider(color: AppColors.border, height: 1),
                    SizedBox(height: 18.h),
                    // Payment mode is selected via the inline chips in the
                    // bottom bar before opening this dialog — so we don't
                    // re-show the mode picker here; only the inputs for the
                    // already-chosen mode appear below.
                    if (_paymentMode == 'QR/UPI') ...[
                      Container(
                        padding: EdgeInsets.all(12.w),
                        decoration: BoxDecoration(
                          color: AppColors.info.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12.r),
                          border: Border.all(
                            color: AppColors.info.withValues(alpha: 0.16),
                          ),
                        ),
                        child: Row(
                          children: [
                            AppIcon.linear('info-circle',
                              size: 16,
                              color: AppColors.info,
                            ),
                            SizedBox(width: 8.w),
                            Expanded(
                              child: Text(
                                'Enter the UPI Transaction ID shared by the student',
                                style: TextStyle(fontSize: 11.sp, color: AppColors.info),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 14.h),
                      _buildDialogInput(
                        label: 'UPI Transaction ID *',
                        child: TextField(
                          controller: _upiRefController,
                          onChanged: (_) {
                            setDialogState(() { if (upiErr != null) upiErr = null; });
                          },
                          decoration: _dialogInputDec(hint: 'e.g. 412345678901', prefix: AppIcon('receipt-2', size: 18, color: AppColors.accent), filled: _upiRefController.text.trim().isNotEmpty).copyWith(errorText: upiErr, errorMaxLines: 2),
                          style: _dialogInputStyle().copyWith(color: _upiRefController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                    if (_paymentMode == 'Cheque') ...[
                      SizedBox(height: 18.h),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _buildDialogInput(
                              label: 'Cheque No *',
                              child: TextField(
                                controller: _chequeNoController,
                                onChanged: (_) {
                                  setDialogState(() { if (chequeNoErr != null) chequeNoErr = null; });
                                },
                                decoration: _dialogInputDec(hint: 'Enter cheque number', filled: _chequeNoController.text.trim().isNotEmpty).copyWith(errorText: chequeNoErr, errorMaxLines: 2),
                                style: _dialogInputStyle().copyWith(color: _chequeNoController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                          SizedBox(width: 12.w),
                          Expanded(
                            child: _buildDialogInput(
                              label: 'Cheque Date *',
                              child: TextField(
                                controller: _chequeDateController,
                                readOnly: true,
                                onTap: () async {
                                  final picked = await showDatePicker(
                                    context: ctx,
                                    initialDate: DateTime.now(),
                                    firstDate: DateTime(2020),
                                    lastDate: DateTime(2030),
                                  );
                                  if (picked != null) {
                                    _chequeDate = picked;
                                    _chequeDateController.text =
                                        '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
                                    setDialogState(() => chequeDateErr = null);
                                  }
                                },
                                decoration: _dialogInputDec(hint: 'DD/MM/YYYY', filled: _chequeDateController.text.trim().isNotEmpty).copyWith(
                                  suffixIcon: Padding(
                                    padding: EdgeInsets.only(right: 8.w),
                                    child: AppIcon.linear('calendar', size: 16, color: AppColors.accent),
                                  ),
                                  suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                                  errorText: chequeDateErr,
                                  errorMaxLines: 2,
                                ),
                                style: _dialogInputStyle().copyWith(color: _chequeDateController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 14.h),
                      _buildDialogInput(
                        label: 'Bank Name *',
                        child: TextField(
                          controller: _bankNameController,
                          onChanged: (_) {
                            setDialogState(() { if (bankNameErr != null) bankNameErr = null; });
                          },
                          decoration: _dialogInputDec(hint: 'Enter bank name', filled: _bankNameController.text.trim().isNotEmpty).copyWith(errorText: bankNameErr, errorMaxLines: 2),
                          style: _dialogInputStyle().copyWith(color: _bankNameController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                    SizedBox(height: 22.h),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            // Reset fineamount to 0 on all selected demands
                            // so no stale fine stays in the DB.
                            final auth = context.read<AuthProvider>();
                            final insId = auth.insId;
                            if (insId == null) return;
                            for (final key in _selected) {
                              final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
                              final demId = d['dem_id'];
                              if (demId == null) continue;
                              try {
                                await SupabaseService.setDemandFine(token: _sessionToken, demId: demId, fineamount: 0);
                              } catch (e) {
                                debugPrint('Fine reset error for dem_id=$demId: $e');
                              }
                            }
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.error,
                            backgroundColor: const Color(0xFFF3F6FD),
                            side: const BorderSide(color: AppColors.border),
                            padding: EdgeInsets.symmetric(
                              horizontal: 18.w,
                              vertical: 12.h,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12.r),
                            ),
                          ),
                          child: Text('Cancel', style: TextStyle(fontSize: 14.sp)),
                        ),
                        SizedBox(width: 10.w),
                        ElevatedButton(
                          onPressed: () {
                            if (_paymentMode == 'QR/UPI') {
                              if (_upiRefController.text.trim().isEmpty) {
                                setDialogState(() => upiErr = 'Enter the UPI Transaction ID');
                                return;
                              }
                            }
                            if (_paymentMode == 'Cheque') {
                              final no = _chequeNoController.text.trim().isEmpty;
                              final dt = _chequeDateController.text.trim().isEmpty;
                              final bk = _bankNameController.text.trim().isEmpty;
                              if (no || dt || bk) {
                                setDialogState(() {
                                  chequeNoErr = no ? 'Cheque number is required' : null;
                                  chequeDateErr = dt ? 'Cheque date is required' : null;
                                  bankNameErr = bk ? 'Bank name is required' : null;
                                });
                                return;
                              }
                            }
                            Navigator.pop(ctx);
                            _processPayment();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: EdgeInsets.symmetric(
                              horizontal: 26.w,
                              vertical: 14.h,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12.r),
                            ),
                          ),
                          child: Text(
                            _paymentMode == 'Paytm' ? 'Confirm Payment' : 'Save',
                            style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                )),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDialogInput({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary),
        ),
        SizedBox(height: 6.h),
        child,
      ],
    );
  }

  Future<void> _processPayment() async {
    if (_processing || _student == null) return;
    if (_paymentMode == 'Paytm') {
      await _processPaytmPayment();
    } else {
      await _processDirectPayment();
    }
  }

  // ── Show success dialog ──
  void _showSuccessDialog(String payNumber, double totalNet, {int? payId}) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon('tick-circle', color: AppColors.success, size: 56.sp),
            SizedBox(height: 12.h),
            Text('Payment Successful', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700)),
            SizedBox(height: 8.h),
            Text('Receipt No: $payNumber', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
            Text('Amount: ${formatIndianNumber(totalNet)}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
            Text('Mode: $_paymentMode', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
            SizedBox(height: 16.h),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _clear();
                if (payId != null) _downloadReceipt(payId, payNumber);
              },
              icon: AppIcon('document-download', size: AppBtn.iconSize(context)),
              label: const Text('Download Receipt'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.accent),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _clear();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
            ),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadReceipt(int payId, String payNumber) async {
    if (!mounted) return;
    // Show a non-dismissable spinner while we fetch + render the receipt data.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    ReceiptData? receiptData;
    try {
      receiptData = await _fetchReceiptData(payId, payNumber);
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop(); // close spinner
    if (receiptData == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load receipt details.'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (!mounted) return;
    _showReceiptPreviewDialog(receiptData);
  }

  /// Receipt preview dialog matching the Daily Collection look — header with
  /// Download / Print / close, then the rendered ReceiptWidget below.
  void _showReceiptPreviewDialog(ReceiptData receiptData) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
        child: SizedBox(
          width: 620,
          height: 920,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        try {
                          final pdf = await buildReceiptPdf(receiptData);
                          final bytes = await pdf.save();
                          final defaultName = 'Receipt_${receiptData.receiptNo.replaceAll('/', '_')}.pdf';
                          final result = await FilePicker.platform.saveFile(
                            dialogTitle: 'Save Receipt PDF',
                            fileName: defaultName,
                            type: FileType.custom,
                            allowedExtensions: ['pdf'],
                          );
                          if (result != null) {
                            final file = File(result);
                            await file.writeAsBytes(bytes);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Receipt saved successfully'), backgroundColor: Colors.green),
                              );
                            }
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
                            );
                          }
                        }
                      },
                      icon: AppIcon('document-download', size: 18),
                      label: const Text('Download'),
                    ),
                    SizedBox(width: 8.w),
                    ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        try {
                          final pdf = await buildReceiptPdf(receiptData);
                          await Printing.layoutPdf(
                            // Match the A5 page so the printer doesn't fall
                            // back to A4 and clip the right edge.
                            format: a5PageFormat,
                            onLayout: (PdfPageFormat format) async => pdf.save(),
                            name: 'Receipt_${receiptData.receiptNo.replaceAll('/', '_')}',
                          );
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
                            );
                          }
                        }
                      },
                      icon: AppIcon('printer', size: 18),
                      label: const Text('Print'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                        elevation: 0,
                        textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                      ),
                    ),
                    SizedBox(width: 8.w),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: AppIcon.linear('close-circle', size: 20),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(12.w),
                  child: Center(
                    child: Container(
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 2)),
                        ],
                      ),
                      child: ReceiptWidget(data: receiptData),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Assembles a ReceiptData object by joining payment + paymentdetails +
  /// feedemand + student + parent + institution rows. Returns null if the
  /// payment row can't be found.
  Future<ReceiptData?> _fetchReceiptData(int payId, String payNumber) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return null;

    final payment = await SupabaseService.fromSchema('payment')
        .select('pay_id, paynumber, paydate, paymethod, paystatus, payreference, transtotalamount, stu_id, recon_status, createdat')
        .eq('pay_id', payId)
        .maybeSingle();
    if (payment == null) return null;

    final stuId = payment['stu_id'] as int?;
    Map<String, dynamic>? student;
    String? payInchargeMob;
    if (stuId != null) {
      student = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname, stuaddress, stumobile')
          .eq('stu_id', stuId)
          .maybeSingle();
      try {
        final parent = await SupabaseService.getStudentParent(stuId, stuadmno: student?['stuadmno']?.toString());
        payInchargeMob = parent?['payinchargemob']?.toString();
      } catch (_) {}
    }

    // paymentdetails → fee breakdown for this payment
    final details = await SupabaseService.fromSchema('paymentdetails')
        .select('dem_id, transtotalamount')
        .eq('pay_id', payId)
        .eq('activestatus', 1);
    final detailList = List<Map<String, dynamic>>.from(details);
    final demIds = detailList.map((d) => d['dem_id'] as int?).whereType<int>().toSet().toList();

    // Pull the matching feedemand rows so we know term/feetype/duedate/fine
    // for each line in the receipt.
    final Map<int, Map<String, dynamic>> demById = {};
    if (demIds.isNotEmpty) {
      final demands = await SupabaseService.fromSchema('feedemand')
          .select('dem_id, demfeetype, demfeeterm, duedate, fineamount, feeamount, demseqtype, arrearclass')
          .inFilter('dem_id', demIds);
      for (final d in demands) {
        demById[d['dem_id'] as int] = Map<String, dynamic>.from(d);
      }
    }

    const months = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    String dateStr = '-';
    final dateRaw = payment['paydate'] ?? payment['createdat'];
    if (dateRaw != null) {
      try {
        final dt = DateTime.parse(dateRaw.toString());
        dateStr = '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
      } catch (_) {
        dateStr = dateRaw.toString();
      }
    }

    // Group fee details by term, splitting fine into its own line item.
    const monthFeeTypes = ['TUITION FEES', 'TUITION FEE', 'VAN FEES', 'VAN FEE'];
    final termMap = <String, List<ReceiptFeeItem>>{};
    for (final d in detailList) {
      final demId = d['dem_id'] as int?;
      final dem = demId != null ? demById[demId] : null;
      final feeType = dem?['demfeetype']?.toString() ?? 'Fee';
      String term = dem?['demfeeterm']?.toString() ?? '-';
      final fine = (dem?['fineamount'] as num?)?.toDouble() ?? 0;
      final collected = (d['transtotalamount'] as num?)?.toDouble() ?? 0;
      final feeOnly = (collected - fine).clamp(0, double.infinity).toDouble();
      if (monthFeeTypes.contains(feeType.toUpperCase())) {
        final duedate = dem?['duedate'];
        if (duedate != null) {
          try {
            final dt = DateTime.parse(duedate.toString());
            term = months[dt.month - 1].toUpperCase();
          } catch (_) {}
        }
      }
      termMap.putIfAbsent(term, () => []);
      termMap[term]!.add(ReceiptFeeItem(type: feeType, amount: feeOnly));
      if (fine > 0) {
        termMap[term]!.add(ReceiptFeeItem(type: '  Fine', amount: fine));
      }
    }
    final totalAmount = (payment['transtotalamount'] as num?)?.toDouble() ?? 0;
    final termDetails = termMap.isEmpty
        ? [ReceiptTermDetail(term: '-', fees: [ReceiptFeeItem(type: 'Payment', amount: totalAmount)])]
        : termMap.entries.map((e) => ReceiptTermDetail(term: e.key, fees: e.value)).toList();

    // For an ARREAR receipt, the Branch shows the arrear's ORIGINAL class
    // (feedemand.arrearclass), not the student's current class. Receipts are
    // single-type (regular/arrear collected separately), so any arrear demand
    // in this payment carries the class to display.
    String? arrearBranch;
    for (final dem in demById.values) {
      final isArr = (dem['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
      final ac = dem['arrearclass']?.toString() ?? '';
      if (isArr && ac.isNotEmpty) {
        arrearBranch = ac;
        break;
      }
    }
    final branchClass = (arrearBranch != null && arrearBranch.isNotEmpty)
        ? arrearBranch
        : (student?['stuclass']?.toString() ?? '-');

    final ins = await SupabaseService.getInstitutionInfo(insId);

    return ReceiptData(
      receiptNo: payment['paynumber']?.toString() ?? payNumber,
      date: dateStr,
      studentName: student?['stuname']?.toString() ?? '-',
      mobileNo: (payInchargeMob?.isNotEmpty == true) ? payInchargeMob! : (student?['stumobile']?.toString() ?? '-'),
      address: student?['stuaddress']?.toString() ?? '-',
      admissionNo: student?['stuadmno']?.toString() ?? '-',
      className: branchClass,
      courseName: student?['courname']?.toString().isNotEmpty == true ? student!['courname'].toString() : '-',
      schoolName: (ins.name?.isNotEmpty == true) ? ins.name! : (auth.insName ?? 'Institution'),
      schoolAddress: (ins.address?.isNotEmpty == true) ? ins.address! : '-',
      schoolLogoUrl: ins.logo,
      schoolMobile: ins.mobile,
      schoolEmail: ins.email,
      feeDetails: termDetails,
      paymentMethod: payment['paymethod']?.toString() ?? '-',
      paymentDate: dateStr,
      status: payment['paystatus']?.toString() == 'C' ? 'paid' : 'pending',
      reconStatus: payment['recon_status']?.toString() ?? 'P',
      paymentReference: payment['payreference']?.toString(),
      total: totalAmount,
    );
  }

  // ── Direct payment (Cash / Bank / Cheque) using atomic RPCs ──
  /// Fallback academic-year id for payments on demands with a NULL yr_id
  /// (arrear demands whose Fee/Arrear Year isn't in the year master).
  /// payment.yr_id and paymentdetails.yr_id are NOT NULL, so such a receipt is
  /// recorded under the current active year. Cached after the first lookup.
  int? _fallbackYrId;
  Future<int?> _currentYearId() async {
    if (_fallbackYrId != null) return _fallbackYrId;
    try {
      final r = await SupabaseService.fromSchema('year')
          .select('yr_id')
          .eq('activestatus', 1)
          .order('yr_id', ascending: false)
          .limit(1)
          .maybeSingle();
      _fallbackYrId = (r?['yr_id'] as num?)?.toInt();
    } catch (_) {}
    return _fallbackYrId;
  }

  Future<void> _processDirectPayment() async {
    setState(() => _processing = true);

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.currentUser?.inscode ?? '';
    final createdBy = auth.currentUser?.usename ?? '';
    final stuId = _student!['stu_id'] as int;
    final totalNet = _totalNetSelected;

    // Declared outside try so the catch block can reset fineamount on failure.
    final items = <Map<String, dynamic>>[];

    try {
      final selectedDemIds = _allDemands
          .where((d) => _selected.contains(_demKey(d)))
          .map((d) => d['dem_id'] as int)
          .toList();
      if (selectedDemIds.isNotEmpty) {
        final fresh = await SupabaseService.fromSchema('feedemand')
            .select('dem_id, balancedue, paidstatus')
            .eq('ins_id', insId!)
            .inFilter('dem_id', selectedDemIds);
        final stale = (fresh as List).where((r) {
          final bal = (r['balancedue'] as num?)?.toDouble() ?? 0;
          return bal <= 0 || r['paidstatus'] == 'P';
        }).toList();
        if (stale.isNotEmpty) {
          if (mounted) {
            setState(() => _processing = false);
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Already paid'),
                content: const Text(
                  'One or more selected fees have already been collected '
                  '(possibly by another user). Please refresh and try again.',
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _search();
                    },
                    child: const Text('Refresh'),
                  ),
                ],
              ),
            );
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('Pre-flight balance check failed: $e');
    }

    try {
      final firstDemand = _allDemands.firstWhere((d) => _selected.contains(_demKey(d)));
      // Arrear demands may have a NULL yr_id (year not in master); payment.yr_id
      // is NOT NULL, so fall back to the current active year.
      int? yrId = firstDemand['yr_id'] as int?;
      yrId ??= await _currentYearId();
      final yrlabel = firstDemand['demfeeyear']?.toString() ?? '';

      // Build items list with fee type info
      for (final key in _selected) {
        final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
        if (d.isEmpty) continue;
        final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
        final fine = _fine(key);
        final col = _con(key);
        final net = (col > 0 ? col : bal) + fine; // Total including fine
        items.add({
          'dem_id': d['dem_id'] as int,
          'yr_id': (d['yr_id'] as int?) ?? yrId,
          'yrlabel': d['demfeeyear']?.toString() ?? '',
          'ins_id': insId,
          'amount': net,
          'fine': fine,
          'demfeetype': d['demfeetype']?.toString() ?? '',
        });
      }

      // Build payment reference. _paymentMode is non-null here because the
      // bottom-bar button is disabled until the cashier picks a mode. We
      // store JUST the txn / cheque id (no narrative prefix) so the
      // PowerCollege SETTLEMENT ID column shows the clean value.
      final mode = _paymentMode ?? 'Cash';
      String payReference = '';
      String payMethod = mode.toLowerCase();

      if (_paymentMode == 'QR/UPI') {
        payReference = _upiRefController.text.trim();
        payMethod = 'upi';
      } else if (_paymentMode == 'Cheque') {
        payReference = _chequeNoController.text.trim();
        payMethod = 'cheque';
      }

      // Call grouped payment RPC — creates one payment per fee group
      // totalNet includes fine — paidamount will include fine (old approach)
      final result = await SupabaseService.processGroupedPayment(
        token: _sessionToken, insId: insId, inscode: inscode, stuId: stuId,
        yrId: yrId, yrlabel: yrlabel, totalAmount: totalNet, createdBy: createdBy,
        payMethod: payMethod, payReference: payReference, items: items);

      // Result is JSON array of receipt numbers
      final receipts = result is List ? result : (result is String ? [result] : []);
      final receiptStr = receipts.map((r) => r is Map ? r['paynumber'] ?? r.toString() : r.toString()).join(', ');
      // Grab the first pay_id so the Download Receipt button has something to fetch.
      int? firstPayId;
      for (final r in receipts) {
        if (r is Map && r['pay_id'] != null) {
          firstPayId = r['pay_id'] is int ? r['pay_id'] as int : int.tryParse(r['pay_id'].toString());
          break;
        }
      }

      // Update cheque details if applicable
      if (_paymentMode == 'Cheque' && receipts.isNotEmpty) {
        for (final r in receipts) {
          final payId = r is Map ? r['pay_id'] : null;
          if (payId != null) {
            await SupabaseService.updatePayment(payId, {
              'paychequeno': _chequeNoController.text.trim(),
              'paychequedate': _chequeDate != null
                  ? '${_chequeDate!.year}-${_chequeDate!.month.toString().padLeft(2, '0')}-${_chequeDate!.day.toString().padLeft(2, '0')}'
                  : null,
              'paybankname': _bankNameController.text.trim(),
            });
          }
        }
      }

      // Record tender/refund on every Cash payment row so the cashbook
      // shows what was actually handed over and what change went back.
      if (_paymentMode == 'Cash' && receipts.isNotEmpty && _cashTenderAmount != null) {
        for (final r in receipts) {
          final payId = r is Map ? r['pay_id'] : null;
          if (payId != null) {
            await SupabaseService.updatePayment(payId, {
              'tender_amount': _cashTenderAmount,
              'refund_amount': _cashRefundAmount,
            });
          }
        }
      }

      // Update fineamount column on each paid demand so reports/totals reflect
      // the fine separately. The RPC already added (bal + fine) into paidamount
      // for the row, so we just need to record how much of that was fine.
      for (final item in items) {
        final fine = (item['fine'] as num?)?.toDouble() ?? 0;
        if (fine > 0) {
          final demId = item['dem_id'];
          if (demId != null) {
            try {
              await SupabaseService.setDemandFine(token: _sessionToken, demId: demId, fineamount: fine);
            } catch (e) {
              debugPrint('Fine column update error for dem_id=$demId: $e');
            }
          }
        }
      }

      _showSuccessDialog(receiptStr, totalNet, payId: firstPayId);
    } catch (e) {
      debugPrint('PAYMENT SAVE FAILED (raw): $e');
      String errorMsg = e.toString();
      if (errorMsg.contains('already fully paid')) {
        errorMsg = 'One or more fees have already been paid. Please refresh and try again.';
      } else if (errorMsg.contains('currently being processed')) {
        errorMsg = 'These fees are already being processed. Please wait and try again.';
      } else if (errorMsg.contains('not found or inactive')) {
        errorMsg = 'One or more fees are no longer available. Please refresh.';
      }

      // Payment failed — reset fineamount to 0 on attempted demands so no
      // stale fine is left in the DB.
      for (final item in items) {
        final demId = item['dem_id'];
        if (demId != null) {
          try {
            await SupabaseService.setDemandFine(token: _sessionToken, demId: demId, fineamount: 0);
          } catch (e2) {
            debugPrint('Fine reset error for dem_id=$demId: $e2');
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Payment failed. ${friendlyError(errorMsg)}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  // ── Online payment (Paytm) ──
  // Mirrors _processOnlinePayment but uses Paytm JS Checkout and routes the
  // payment to the merchant (MID) tied to the fee group's bank account, so the
  // money settles to the correct IOBPAY entity. See docs/paytm_integration.md.
  Future<void> _processPaytmPayment() async {
    setState(() => _processing = true);

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.currentUser?.inscode ?? '';
    final createdBy = auth.currentUser?.usename ?? '';
    final stuId = _student!['stu_id'] as int;
    final totalNet = _totalNetSelected;

    // Block if an online payment for this student is still pending (<15 min),
    // so a double-tap or flaky network doesn't create a second live order.
    try {
      final pending = await SupabaseService.fromSchema('payment')
          .select('createdat')
          .eq('ins_id', insId!)
          .eq('stu_id', stuId)
          .eq('paystatus', 'I')
          .order('createdat', ascending: false)
          .limit(1)
          .maybeSingle();
      if (pending != null) {
        final createdAt = DateTime.tryParse(pending['createdat']?.toString() ?? '');
        if (createdAt != null && DateTime.now().difference(createdAt).inMinutes < 15) {
          if (mounted) {
            setState(() => _processing = false);
            final clear = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Payment already pending'),
                content: const Text(
                  'An online payment for this student was started but not '
                  'completed. If that attempt failed or the payment window was '
                  'closed, clear it and start a new payment.\n\n'
                  'Only clear if you are sure no payment actually went through.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Clear & retry'),
                  ),
                ],
              ),
            );
            if (clear == true) {
              try {
                // Mark every not-completed (status 'I') attempt for this student
                // as failed, so the guard releases and a fresh order can start.
                await SupabaseService.failPendingPayments(stuId);
                if (mounted) _processPaytmPayment(); // retry, now unblocked
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Could not clear pending payment: ${friendlyError(e)}'),
                    backgroundColor: Colors.red));
                }
              }
            }
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('Paytm pending-payment check failed: $e');
    }

    int? createdPayId; // the temp 'I' row, so we can clean it up on failure
    try {
      final firstDemand = _allDemands.firstWhere((d) => _selected.contains(_demKey(d)));
      // Arrear demands may have a NULL yr_id; payment.yr_id is NOT NULL, so fall
      // back to the current active year.
      int? yrId = firstDemand['yr_id'] as int?;
      yrId ??= await _currentYearId();
      final yrlabel = firstDemand['demfeeyear']?.toString() ?? '';

      // Build items (same shape as the Razorpay flow).
      final items = <Map<String, dynamic>>[];
      for (final key in _selected) {
        final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
        if (d.isEmpty) continue;
        final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
        final fine = _fine(key);
        final col = _con(key);
        final net = (col > 0 ? col : bal) + fine;
        items.add({
          'dem_id': d['dem_id'] as int,
          'yr_id': (d['yr_id'] as int?) ?? yrId,
          'yrlabel': d['demfeeyear']?.toString() ?? '',
          'ins_id': insId,
          'amount': net,
          'demfeetype': d['demfeetype']?.toString() ?? '',
        });
      }

      // Resolve the selected fee groups → predominant bank (ban_id) and its
      // Paytm MID, so the payment routes to the merchant that settles to the
      // correct account. Null MID falls back to the app's default merchant.
      int? paytmBanId;
      String? paytmMid;
      // Per-unit settlement: the routing MID depends only on the paying
      // institution (public.paytm_configuration), not the fee groups. The edge
      // function creates the order under this unit's OWN MID and signs it with
      // that MID's own key (PAYTM_MERCHANTS), so Paytm settles to the unit's bank.
      if (PaytmConfig.perUnitSettlement) {
        paytmMid = await SupabaseService.getPaytmMidForInstitution(insId!);
      }
      try {
        final demIds = items.map((it) => it['dem_id']).whereType<int>().toList();
        if (demIds.isNotEmpty) {
          final fdRows = await SupabaseService.fromSchema('feedemand')
              .select('fee_id').inFilter('dem_id', demIds);
          final feeIds = (fdRows as List).map((r) => r['fee_id']).whereType<int>().toSet().toList();
          if (feeIds.isNotEmpty) {
            final ftRows = await SupabaseService.fromSchema('feetype')
                .select('fg_id').inFilter('fee_id', feeIds);
            final fgIds = (ftRows as List).map((r) => r['fg_id']).whereType<int>().toSet().toList();
            if (fgIds.isNotEmpty) {
              // Single-account / per-bank routing uses the fee group's bank MID.
              if (!PaytmConfig.perUnitSettlement) {
                paytmMid = await SupabaseService.getPaytmMidForFeeGroups(fgIds);
              }
              final fgRows = await SupabaseService.fromSchema('feegroup')
                  .select('ban_id').inFilter('fg_id', fgIds);
              final banIds = (fgRows as List).map((r) => r['ban_id']).whereType<int>().toList();
              if (banIds.isNotEmpty) {
                final counts = <int, int>{};
                for (final id in banIds) { counts[id] = (counts[id] ?? 0) + 1; }
                paytmBanId = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Paytm bank/MID resolve failed: $e');
      }

      // 1. Temporary payment row (status I).
      final payId = await SupabaseService.insertPayment({
        'ins_id': insId,
        'inscode': inscode,
        'stu_id': stuId,
        'yr_id': yrId ?? 0,
        'yrlabel': yrlabel,
        'transtotalamount': totalNet,
        'transcurrency': 'INR',
        'paydate': DateTime.now().toIso8601String(),
        'paystatus': 'I',
        'createdby': createdBy,
        'recon_status': 'P',
        'payitems': jsonEncode(items),
        if (paytmBanId != null) 'ban_id': paytmBanId,
      });
      createdPayId = payId;

      // 2. Initiate the Paytm transaction (server-side checksum + MID routing).
      final order = await PaytmService.createOrder(
        payId: payId,
        amount: totalNet,
        custId: 'STU-$stuId',
        mid: paytmMid,
      );
      await SupabaseService.updatePayment(payId, {'payorderid': order.orderId});

      // 3. Show the Paytm checkout + poll for status.
      String? result;
      if (mounted) {
        result = await showPaytmCheckout(
          context,
          order: order,
          amount: totalNet,
          studentName: _student!['stuname']?.toString() ?? '',
          studentMobile: _student!['stumobile']?.toString() ?? '',
          studentEmail: _student!['stuemail']?.toString() ?? '',
          merchantName: auth.insName ?? 'KCET',
        );
      }

      // 4. Resolve final gateway reference, then complete the payment.
      final status = result == 'C' ? 'C' : 'F';
      String payRef = '';
      try {
        final s = await PaytmService.verifyPayment(order.orderId, mid: order.mid);
        payRef = s.paymentId ?? '';
      } catch (_) {}

      // Items for per-group receipts (dem_id + amount + demfeetype).
      final completeItems = <Map<String, dynamic>>[];
      for (final key in _selected) {
        final d = _allDemands.firstWhere((x) => _demKey(x) == key, orElse: () => {});
        if (d.isEmpty) continue;
        final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
        final fine = _fine(key);
        final col = _con(key);
        final net = (col > 0 ? col : bal) + fine;
        completeItems.add({
          'dem_id': d['dem_id'] as int,
          'amount': net,
          'demfeetype': d['demfeetype']?.toString() ?? '',
        });
      }

      final reference = status == 'C' ? payRef : (result == 'F' ? 'FAILED:$payRef' : 'CANCELLED');
      try {
        // Paytm gateway → distinct "Online Transfer" mode in the MODE column
        // (still buckets as Online in charts/receipts, which lowercase + match
        // .contains('online')).
        final rpResult = await SupabaseService.completePaymentGrouped(
          token: _sessionToken, payId: payId, payMethod: 'Online Transfer',
          payReference: reference, items: completeItems, insId: insId, status: status);
        final receipts = rpResult is List ? rpResult : [rpResult];
        final receiptStr = receipts.map((r) => r is Map ? r['paynumber'] ?? r.toString() : r.toString()).join(', ');
        int? firstPayId;
        for (final r in receipts) {
          if (r is Map && r['pay_id'] != null) {
            firstPayId = r['pay_id'] is int ? r['pay_id'] as int : int.tryParse(r['pay_id'].toString());
            break;
          }
        }
        // On cancel/fail, clear any transient fine on the attempted demands.
        if (status != 'C') {
          for (final item in completeItems) {
            final demId = item['dem_id'];
            if (demId != null) {
              try {
                await SupabaseService.setDemandFine(token: _sessionToken, demId: demId, fineamount: 0);
              } catch (_) {}
            }
          }
        }
        if (mounted) {
          if (status == 'C') {
            _showSuccessDialog(receiptStr, totalNet, payId: firstPayId);
          } else if (result == 'F') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Payment failed. Receipt: $receiptStr'), backgroundColor: Colors.red));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Payment cancelled. Receipt: $receiptStr'), backgroundColor: Colors.orange));
          }
        }
      } catch (e) {
        debugPrint('complete_payment_grouped (Paytm) failed: $e');
        try {
          await SupabaseService.updatePayment(payId, {'paystatus': 'F'});
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red));
        }
      }
    } catch (e, st) {
      // Surface the real cause in the run log (the snackbar only shows a
      // friendly message) so failures can be diagnosed.
      debugPrint('PAYTM PAYMENT ERROR: $e');
      debugPrint('PAYTM PAYMENT STACK: $st');
      // Clean up the orphaned 'I' row so a failed/aborted attempt (e.g. a
      // network drop) doesn't block the next retry via the 15-min pending lock.
      if (createdPayId != null) {
        try {
          await SupabaseService.updatePayment(createdPayId, {'paystatus': 'F'});
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Paytm payment failed. ${friendlyError(e)}'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  // ── Helpers ──

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      padding: EdgeInsets.all(12.w),
      child: child,
    );
  }

  // Shared decoration for the Mode + Fee Type header dropdowns so they
  // render at the exact same height regardless of focus/value state.
  InputDecoration _headerDropdownDec({bool filled = false}) {
    final idle = filled ? AppColors.accent : AppColors.border;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10.r),
      borderSide: BorderSide(color: idle, width: 1.5),
    );
    final focused = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10.r),
      borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
    );
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border,
      enabledBorder: border,
      focusedBorder: focused,
      disabledBorder: border,
    );
  }

  // Shared styling for the Cheque / UPI / Online dialog input fields so
  // every input renders with the same bold-visible look.
  InputDecoration _dialogInputDec({required String hint, Widget? prefix, bool filled = false}) {
    final idle = filled ? AppColors.accent : AppColors.border;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 14.sp,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary,
      ),
      prefixIcon: prefix,
      contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 14.h),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12.r),
        borderSide: BorderSide(color: idle, width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12.r),
        borderSide: BorderSide(color: idle, width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12.r),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      filled: true,
      fillColor: Colors.white,
      isDense: true,
    );
  }

  TextStyle _dialogInputStyle() => TextStyle(
        fontSize: 15.sp,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: 0.4,
      );

  bool get _compactCtx => MediaQuery.of(context).size.width <= 1366;

  TextStyle _ddTextStyle() =>
      TextStyle(fontWeight: FontWeight.w600, fontSize: _compactCtx ? 11 : 14, color: const Color(0xFF333333));

  TextStyle _ddItemStyle() =>
      TextStyle(fontSize: _compactCtx ? 11 : 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary);

  InputDecoration _inputDec(String hint, {bool filled = false}) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final textSize = compact ? 11.0 : 14.0;
    final hPad = compact ? 8.0 : 14.0;
    final vPad = compact ? 5.0 : 14.0;
    final radius = compact ? 5.0 : 8.0;
    final idle = filled ? AppColors.accent : AppColors.border;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: textSize),
      contentPadding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: idle, width: 1.5)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: idle, width: 1.5)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
      filled: true,
      fillColor: Colors.white,
    );
  }

  Widget _detailRow(String icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(icon, size: 15, color: AppColors.textSecondary),
        SizedBox(width: 8.w),
        Text('$label  ',
            style: TextStyle(
                fontSize: 13.sp, color: AppColors.textSecondary)),
        Expanded(
          child: Text(value,
              style: TextStyle(
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary),
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  Widget _termChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(20.r),
          border:
              Border.all(color: selected ? AppColors.accent : AppColors.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13.sp,
                fontWeight: FontWeight.w500,
                color: selected ? Colors.white : AppColors.textSecondary)),
      ),
    );
  }

  Widget _numField(TextEditingController? ctrl, VoidCallback onChange, {int? maxLength, String? fieldKey, FocusNode? focusNode, bool enabled = true}) {
    if (ctrl == null) return const SizedBox();
    final filled = ctrl.text.trim().isNotEmpty;
    final idle = filled ? AppColors.accent : AppColors.border;
    return SizedBox(
      height: 28.h,
      child: TextField(
        key: fieldKey != null ? ValueKey(fieldKey) : null,
        controller: ctrl,
        focusNode: focusNode,
        enabled: enabled,
        onChanged: (_) => onChange(),
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
          if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
        ],
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13.sp, color: filled ? AppColors.accent : null),
        decoration: InputDecoration(
          hintText: '0',
          hintStyle: TextStyle(
              fontSize: 13.sp, color: AppColors.textLight),
          contentPadding:
              EdgeInsets.symmetric(horizontal: 6.w, vertical: 4.h),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6.r),
              borderSide: BorderSide(color: idle, width: 1.5)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6.r),
              borderSide: BorderSide(color: idle, width: 1.5)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6.r),
              borderSide: const BorderSide(
                  color: AppColors.accent, width: 1.5)),
        ),
      ),
    );
  }

  String _formatDate(String iso) {
    // Convert yyyy-MM-dd → dd/MM/yyyy
    final parts = iso.split('-');
    if (parts.length == 3) return '${parts[2]}/${parts[1]}/${parts[0]}';
    return iso;
  }
}

class _THCell extends StatelessWidget {
  final String text;
  final int flex;
  final TextAlign textAlign;
  const _THCell(this.text, {this.flex = 1, this.textAlign = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(text.toUpperCase(),
          textAlign: textAlign,
          style: TextStyle(
              fontSize: 12.sp,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              letterSpacing: 0.3)),
    );
  }
}

class _TDCell extends StatelessWidget {
  final String text;
  final int flex;
  final TextStyle? style;
  final TextAlign textAlign;
  const _TDCell(this.text, {this.flex = 1, this.style, this.textAlign = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(text,
          textAlign: textAlign,
          style: style ??
              TextStyle(fontSize: 13.sp, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis),
    );
  }
}
