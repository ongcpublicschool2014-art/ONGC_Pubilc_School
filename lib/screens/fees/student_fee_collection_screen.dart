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
import 'package:webview_windows/webview_windows.dart'
    if (dart.library.html) 'webview_windows_stub.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/receipt_pdf.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../services/supabase_service.dart';
import '../../widgets/receipt_widget.dart';

import '../../widgets/app_icon.dart';
const _classOrder = ['PKG', 'LKG', 'UKG', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII'];

int _classIndex(String c) {
  final idx = _classOrder.indexOf(c.toUpperCase());
  return idx >= 0 ? idx : _classOrder.length;
}

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
  List<String> _courseList = [];
  String? _selectedCourse;
  List<String> _classList = [];
  List<String> _allClasses = [];
  Map<String, List<String>> _courseClassMap = {};
  String? _selectedClass;
  List<Map<String, dynamic>> _classSuggestions = [];


  bool _searching = false;
  String? _errorMsg;

  Map<String, dynamic>? _student;
  Map<String, dynamic>? _parent;

  List<Map<String, dynamic>> _allDemands = [];
  bool _loadingDemands = false;

  String? _selectedTerm; // null = All
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
  final Set<String> _selected = {};
  List<Map<String, dynamic>> _fineRules = [];

  @override
  void initState() {
    super.initState();
    _fetchClasses();
    _loadFineRules();
    _sweepOrphanedPayments();
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
            final resp = await SupabaseService.client.functions.invoke(
              'get-razorpay-payment', body: {'order_id': orderId},
            );
            final data = resp.data as Map<String, dynamic>;
            if (data['status'] == 'captured' && data['payment_id'] != null) {
              captured = true;
              paymentId = data['payment_id'].toString();
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
            await SupabaseService.client.rpc('complete_payment_grouped', params: {
              'p_pay_id': payId,
              'p_pay_method': 'online',
              'p_pay_reference': paymentId,
              'p_items': items,
              'p_ins_id': insId,
              'p_status': 'C',
            });
          } catch (e) {
            debugPrint('Recovery complete failed for pay_id=$payId: $e');
          }
        } else {
          await SupabaseService.fromSchema('payment')
              .update({'paystatus': 'F'})
              .eq('pay_id', payId)
              .eq('ins_id', insId);
        }
      }
    } catch (e) {
      debugPrint('Orphaned payment sweep failed: $e');
    }
  }

  /// Resolve a single pending 'I' payment on demand, bypassing the 15-min
  /// orphan sweep. Called from the "Check status now" button so a cashier in
  /// a flaky-network school doesn't have to wait after a polling timeout.
  Future<void> _resolvePendingPayment({
    required int? payId,
    required String? orderId,
    required String? itemsRaw,
    required int? insId,
  }) async {
    if (payId == null || insId == null) return;
    setState(() => _processing = true);
    bool captured = false;
    String? paymentId;
    try {
      if (orderId != null && orderId.isNotEmpty) {
        final resp = await SupabaseService.client.functions.invoke(
          'get-razorpay-payment', body: {'order_id': orderId},
        );
        final data = resp.data as Map<String, dynamic>;
        if (data['status'] == 'captured' && data['payment_id'] != null) {
          captured = true;
          paymentId = data['payment_id'].toString();
        }
      }
    } catch (e) {
      debugPrint('Razorpay status check failed: $e');
    }

    if (captured) {
      List<dynamic> items = [];
      if (itemsRaw != null && itemsRaw.isNotEmpty) {
        try { items = jsonDecode(itemsRaw) as List<dynamic>; } catch (_) {}
      }
      try {
        await SupabaseService.client.rpc('complete_payment_grouped', params: {
          'p_pay_id': payId,
          'p_pay_method': 'online',
          'p_pay_reference': paymentId,
          'p_items': items,
          'p_ins_id': insId,
          'p_status': 'C',
        });
      } catch (e) {
        debugPrint('Recovery complete failed for pay_id=$payId: $e');
      }
    } else {
      try {
        await SupabaseService.fromSchema('payment')
            .update({'paystatus': 'F'})
            .eq('pay_id', payId)
            .eq('ins_id', insId);
      } catch (e) {
        debugPrint('Mark-failed for pay_id=$payId failed: $e');
      }
    }

    if (mounted) {
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(captured
              ? 'Pending payment recovered. Please re-open the student.'
              : 'No captured payment found — cleared pending lock. You can retry now.'),
          backgroundColor: captured ? Colors.green : Colors.orange,
        ),
      );
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
    // Get courses and classes from feedemand table
    try {
      final demands = await SupabaseService.getFeeDemands(insId);
      final courseSet = <String>{};
      final mapping = <String, Set<String>>{};
      for (final d in demands) {
        final course = d['courname']?.toString() ?? '';
        final cls = d['stuclass']?.toString() ?? '';
        if (course.isNotEmpty) courseSet.add(course);
        if (course.isNotEmpty && cls.isNotEmpty) {
          mapping.putIfAbsent(course, () => <String>{}).add(cls);
        }
      }
      final allClasses = mapping.values.expand((s) => s).toSet().toList();
      allClasses.sort((a, b) => _classIndex(a).compareTo(_classIndex(b)));
      final courseClassMap = <String, List<String>>{ for (final e in mapping.entries) e.key: e.value.toList()..sort((a, b) => _classIndex(a).compareTo(_classIndex(b))) };
      final courseList = courseSet.toList()..sort();
      if (mounted) setState(() {
        _courseList = courseList;
        _courseClassMap = courseClassMap;
        _allClasses = allClasses;
        _classList = allClasses;
      });
    } catch (e) { debugPrint('Error loading course-class from feedemand: $e'); }
  }

  Future<void> _searchByClass(String className) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      // Step 1: gather stu_ids in this class+course that still have at least
      // one fee demand with balancedue > 0 — students who are fully paid up
      // should not appear in the lookup at all.
      var demQuery = SupabaseService.fromSchema('feedemand')
          .select('stu_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('stuclass', className)
          .gt('balancedue', 0);
      if (_selectedCourse != null) {
        demQuery = demQuery.eq('courname', _selectedCourse!);
      }
      final demRows = await demQuery;
      final pendingStuIds = <int>{};
      for (final r in (demRows as List)) {
        final id = r['stu_id'];
        if (id is int) pendingStuIds.add(id);
      }
      if (pendingStuIds.isEmpty) {
        setState(() => _classSuggestions = []);
        return;
      }

      // Step 2: fetch only those students.
      var query = SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('stuclass', className)
          .inFilter('stu_id', pendingStuIds.toList());
      if (_selectedCourse != null) {
        query = query.eq('courname', _selectedCourse!);
      }
      final rows = await query.order('stuname', ascending: true);
      setState(() => _classSuggestions = List<Map<String, dynamic>>.from(rows));
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
    super.dispose();
  }

  void _resetFinesOnExit() {
    if (_allDemands.isEmpty) return;
    final insId = context.read<AuthProvider>().insId;
    if (insId == null) return;
    // Fire-and-forget — dispose can't await.
    for (final d in _allDemands) {
      final demId = d['dem_id'];
      final paidStatus = d['paidstatus']?.toString() ?? 'U';
      if (demId == null) continue;
      if (paidStatus == 'P') continue; // don't wipe historical paid fines
      SupabaseService.fromSchema('feedemand')
          .update({'fineamount': 0})
          .eq('dem_id', demId)
          .eq('ins_id', insId)
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
      final rows = await SupabaseService.fromSchema('students')
          .select('stu_id, stuname, stuadmno, stuclass, courname')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .or('stuadmno.ilike.$term%,stuname.ilike.%$term%')
          .limit(10);
      setState(() => _studentSuggestions = List<Map<String, dynamic>>.from(rows));
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
              ..sort((a, b) => _classIndex(a).compareTo(_classIndex(b)));
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
              'dem_id, demno, yr_id, demfeeyear, demfeetype, demfeeterm, feeamount, conamount, balancedue, paidamount, fineamount, duedate, paidstatus, stuclass')
          .eq('ins_id', insId)
          .eq('stuadmno', stuAdmno)
          .eq('paidstatus', 'U')
          .gt('balancedue', 0)
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
      for (final d in demandList) {
        final key = d['dem_id']?.toString() ?? '';
        if (key.isNotEmpty) {
          final serverFine = (d['fineamount'] as num?)?.toDouble() ?? 0;
          final fine = serverFine > 0 ? serverFine : _calculateFine(d);
          final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
          _fineCtrl[key] = TextEditingController(text: fine > 0 ? fine.toStringAsFixed(0) : '');
          _conCtrl[key] = TextEditingController(text: bal > 0 ? bal.toStringAsFixed(0) : '');
          if (bal > 0) _selected.add(key);
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
    if (_selectedTerm == null) return _allDemands;
    return _allDemands.where((d) =>
        (d['demfeetype']?.toString() ?? '') == _selectedTerm).toList();
  }

  /// Unique Fee Type values across the current student's demands. Used by
  /// the in-table filter dropdown (label: "Fee Type").
  List<String> get _terms {
    final seen = <String>[];
    for (final d in _allDemands) {
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
    var sum = 0.0;
    for (final d in _allDemands) {
      sum += _netAmt(d);
    }
    return sum;
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
        // Floating suggestions popup over the body (doesn't push content down)
        if (_studentSuggestions.isNotEmpty || _classSuggestions.isNotEmpty)
          Positioned(
            left: 260,
            width: 500,
            top: 115,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              shadowColor: Colors.black.withValues(alpha: 0.15),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 520),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _studentSuggestions.isNotEmpty
                      ? _studentSuggestions.length
                      : _classSuggestions.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final source = _studentSuggestions.isNotEmpty ? _studentSuggestions : _classSuggestions;
                    final s = source[i];
                    return ListTile(
                      dense: true,
                      title: Text(s['stuname']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                      subtitle: Text('Roll: ${s['stuadmno']} • ${s['courname'] ?? ''} ${s['stuclass']}', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
                      onTap: () => _selectSuggestion(s),
                    );
                  },
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
          Row(
            children: [
              AppIcon.linear('search-normal', size: 18, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('Student Lookup',
                  style: TextStyle(
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      )),
              const Spacer(),
              SizedBox(
                height: AppBtn.height(context),
                child: ElevatedButton.icon(
                  onPressed: _clear,
                  icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: Colors.white),
                  label: const Text('Clear'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 14.h),
          // Single-line filter row: Course | Class | Search by Roll/Name.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: DropdownButtonFormField<String>(
                    value: _selectedCourse,
                    isExpanded: true,
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    elevation: 6,
                    decoration: _inputDec('Course'),
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                    items: _courseList.map((c) => DropdownMenuItem(value: c, child: Text(c, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)))).toList(),
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
                        _classList.sort((a, b) => _classIndex(a).compareTo(_classIndex(b)));
                        if (val != null && val.startsWith('M') && _classList.length > 2) {
                          _classList = _classList.sublist(0, 2);
                        }
                      });
                    },
                  ),
                ),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: Builder(builder: (_) {
                    final seen = <String>{};
                    final items = <DropdownMenuItem<String>>[];
                    for (final c in _classList) {
                      if (c.isEmpty || !seen.add(c)) continue;
                      items.add(DropdownMenuItem(value: c, child: Text(c, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600))));
                    }
                    final value = seen.contains(_selectedClass) ? _selectedClass : null;
                    return DropdownButtonFormField<String>(
                      key: ValueKey(_selectedCourse),
                      value: value,
                      isExpanded: true,
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 6,
                      decoration: _inputDec('Class'),
                      style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                      items: items,
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
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _admNoController,
                    onSubmitted: (_) => _search(),
                    onChanged: _searchByAdmNoOrName,
                    decoration: _inputDec('Search by Roll No or Name'),
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                    expands: true,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.center,
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
      ],
    );
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
            decoration: InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: BorderSide(color: AppColors.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: BorderSide(color: AppColors.border)),
            ),
            items: [
              DropdownMenuItem<String?>(value: null, child: Text('All', style: TextStyle(fontSize: 13.sp))),
              ..._terms.map((t) => DropdownMenuItem<String?>(value: t, child: Text(t, style: TextStyle(fontSize: 13.sp)))),
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
                      '${_filteredDemands.length} of ${_allDemands.length} items',
                      style: TextStyle(
                          fontSize: 13.sp,
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
                const Spacer(),
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
                      decoration: _headerDropdownDec(),
                      items: [
                        DropdownMenuItem<String?>(value: null, child: Text('All', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700))),
                        ..._terms.map((t) => DropdownMenuItem<String?>(value: t, child: Text(t, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis))),
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
            builder: (context, controller) => ListView.separated(
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

              return Container(
                key: ValueKey('row-$key'),
                color: isSelected
                    ? AppColors.accent.withValues(alpha: 0.04)
                    : null,
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
                    _TDCell(feeAmt.toStringAsFixed(2),
                        flex: 2,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 13.sp,
                            color: AppColors.textPrimary)),
                    _TDCell(bal.toStringAsFixed(2),
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
                                      content: Text('Collection amount cannot exceed balance due (₹${bal.toStringAsFixed(0)})'),
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
                            live.toStringAsFixed(2),
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
              );
            },
          ),
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
                  height: 58,
                  padding: EdgeInsets.symmetric(horizontal: 22.w),
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
                              fontSize: 19.sp,
                              fontWeight: FontWeight.w800,
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
                          'Rs.${_totalNetSelected.toStringAsFixed(2)}',
                          style: TextStyle(fontSize: 19.sp, fontWeight: FontWeight.w800, color: AppColors.accent),
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
                width: 200.w,
                height: 58,
                padding: EdgeInsets.symmetric(horizontal: 16.w),
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
                    hint: Text('SELECT MODE', style: TextStyle(fontSize: 19.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary, letterSpacing: 0.3)),
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    elevation: 6,
                    style: TextStyle(fontSize: 19.sp, fontWeight: FontWeight.w800, color: AppColors.accent, letterSpacing: 0.3),
                    items: const [
                      DropdownMenuItem(value: 'Cash', child: Text('CASH')),
                      DropdownMenuItem(value: 'QR/UPI', child: Text('QR/UPI')),
                      DropdownMenuItem(value: 'Online', child: Text('ONLINE')),
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
                height: 58,
                child: ElevatedButton.icon(
                  onPressed: (_selected.isEmpty || _paymentMode == null)
                      ? null
                      : (_paymentMode == 'Cash' ? _saveCashPayment : _onCollectAndReceipt),
                  icon: AppIcon(_paymentMode == 'Cash' ? 'save-2' : 'wallet-money', size: 20),
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
                    padding: EdgeInsets.symmetric(horizontal: 32.w),
                    textStyle: TextStyle(
                        fontSize: 19.sp, fontWeight: FontWeight.w800, letterSpacing: 0.3),
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
                  _cashRow('Net Amount', 'Rs.${total.toStringAsFixed(2)}', highlight: true),
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
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
                    ),
                    style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600),
                  ),
                  if ((_cashTenderAmount ?? 0) < total && (_cashTenderAmount ?? 0) > 0) ...[
                    SizedBox(height: 6.h),
                    Text(
                      'Tender must be at least Rs.${total.toStringAsFixed(2)}',
                      style: TextStyle(fontSize: 12.sp, color: AppColors.error, fontWeight: FontWeight.w600),
                    ),
                  ],
                  SizedBox(height: 14.h),
                  _cashRow('Refund (Change)', 'Rs.${(_cashRefundAmount ?? 0).toStringAsFixed(2)}'),
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
          .eq('ins_id', insId);
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: GestureDetector(
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
                      'Total: Rs.${totalNet.toStringAsFixed(2)}',
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
                            if (upiErr != null) setDialogState(() => upiErr = null);
                          },
                          decoration: _dialogInputDec(hint: 'e.g. 412345678901', prefix: AppIcon('receipt-2', size: 18, color: AppColors.accent)).copyWith(errorText: upiErr, errorMaxLines: 2),
                          style: _dialogInputStyle(),
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
                                  if (chequeNoErr != null) setDialogState(() => chequeNoErr = null);
                                },
                                decoration: _dialogInputDec(hint: 'Enter cheque number').copyWith(errorText: chequeNoErr, errorMaxLines: 2),
                                style: _dialogInputStyle(),
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
                                decoration: _dialogInputDec(hint: 'DD/MM/YYYY').copyWith(
                                  suffixIcon: Padding(
                                    padding: EdgeInsets.only(right: 8.w),
                                    child: AppIcon.linear('calendar', size: 16, color: AppColors.accent),
                                  ),
                                  suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                                  errorText: chequeDateErr,
                                  errorMaxLines: 2,
                                ),
                                style: _dialogInputStyle(),
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
                            if (bankNameErr != null) setDialogState(() => bankNameErr = null);
                          },
                          decoration: _dialogInputDec(hint: 'Enter bank name').copyWith(errorText: bankNameErr, errorMaxLines: 2),
                          style: _dialogInputStyle(),
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
                                await SupabaseService.fromSchema('feedemand')
                                    .update({'fineamount': 0})
                                    .eq('dem_id', demId)
                                    .eq('ins_id', insId);
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
                            _paymentMode == 'Online' ? 'Confirm Payment' : 'Save',
                            style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
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
    if (_paymentMode == 'Online') {
      await _processOnlinePayment();
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
            Text('Amount: Rs.${totalNet.toStringAsFixed(2)}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
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
          .select('dem_id, demfeetype, demfeeterm, duedate, fineamount, feeamount')
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

    final ins = await SupabaseService.getInstitutionInfo(insId);

    return ReceiptData(
      receiptNo: payment['paynumber']?.toString() ?? payNumber,
      date: dateStr,
      studentName: student?['stuname']?.toString() ?? '-',
      mobileNo: (payInchargeMob?.isNotEmpty == true) ? payInchargeMob! : (student?['stumobile']?.toString() ?? '-'),
      address: student?['stuaddress']?.toString() ?? '-',
      admissionNo: student?['stuadmno']?.toString() ?? '-',
      className: student?['stuclass']?.toString() ?? '-',
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
      final yrId = firstDemand['yr_id'] as int?;
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
          'yr_id': d['yr_id'],
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
      final result = await SupabaseService.client.rpc('process_grouped_payment', params: {
        'p_ins_id': insId,
        'p_inscode': inscode,
        'p_stu_id': stuId,
        'p_yr_id': yrId,
        'p_yrlabel': yrlabel,
        'p_total_amount': totalNet,
        'p_created_by': createdBy,
        'p_pay_method': payMethod,
        'p_pay_reference': payReference,
        'p_items': items,
      });

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
            await SupabaseService.fromSchema('payment').update({
              'paychequeno': _chequeNoController.text.trim(),
              'paychequedate': _chequeDate != null
                  ? '${_chequeDate!.year}-${_chequeDate!.month.toString().padLeft(2, '0')}-${_chequeDate!.day.toString().padLeft(2, '0')}'
                  : null,
              'paybankname': _bankNameController.text.trim(),
            }).eq('pay_id', payId).eq('ins_id', insId!);
          }
        }
      }

      // Record tender/refund on every Cash payment row so the cashbook
      // shows what was actually handed over and what change went back.
      if (_paymentMode == 'Cash' && receipts.isNotEmpty && _cashTenderAmount != null) {
        for (final r in receipts) {
          final payId = r is Map ? r['pay_id'] : null;
          if (payId != null) {
            await SupabaseService.fromSchema('payment').update({
              'tender_amount': _cashTenderAmount,
              'refund_amount': _cashRefundAmount,
            }).eq('pay_id', payId).eq('ins_id', insId!);
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
              await SupabaseService.fromSchema('feedemand')
                  .update({'fineamount': fine})
                  .eq('dem_id', demId)
                  .eq('ins_id', insId!);
            } catch (e) {
              debugPrint('Fine column update error for dem_id=$demId: $e');
            }
          }
        }
      }

      _showSuccessDialog(receiptStr, totalNet, payId: firstPayId);
    } catch (e) {
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
            await SupabaseService.fromSchema('feedemand')
                .update({'fineamount': 0})
                .eq('dem_id', demId)
                .eq('ins_id', insId!);
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

  // ── Online payment (Razorpay) ──
  Timer? _pollTimer;

  Future<void> _processOnlinePayment() async {
    setState(() => _processing = true);

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.currentUser?.inscode ?? '';
    final createdBy = auth.currentUser?.usename ?? '';
    final stuId = _student!['stu_id'] as int;
    final totalNet = _totalNetSelected;
    final amountInPaise = (totalNet * 100).round();

    try {
      final pending = await SupabaseService.fromSchema('payment')
          .select('pay_id, createdat, payorderid, payitems')
          .eq('ins_id', insId!)
          .eq('stu_id', stuId)
          .eq('paystatus', 'I')
          .order('createdat', ascending: false)
          .limit(1)
          .maybeSingle();
      if (pending != null) {
        final createdAtStr = pending['createdat']?.toString();
        final createdAt = createdAtStr != null ? DateTime.tryParse(createdAtStr) : null;
        if (createdAt != null) {
          final ageMin = DateTime.now().difference(createdAt).inMinutes;
          if (ageMin < 15) {
            final waitMin = 15 - ageMin;
            final stalePayId = pending['pay_id'] as int?;
            final staleOrderId = pending['payorderid']?.toString();
            final staleItemsRaw = pending['payitems']?.toString();
            if (mounted) {
              setState(() => _processing = false);
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Payment in progress'),
                  content: Text(
                    'An online payment for this student is still pending.\n'
                    'Please try again in about $waitMin minute${waitMin == 1 ? '' : 's'}, '
                    "or tap 'Check status now' to verify with Razorpay immediately.",
                  ),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _resolvePendingPayment(
                          payId: stalePayId,
                          orderId: staleOrderId,
                          itemsRaw: staleItemsRaw,
                          insId: insId,
                        );
                      },
                      child: const Text('Check status now'),
                    ),
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
                  ],
                ),
              );
            }
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('Pending-payment check failed: $e');
    }

    try {
      final firstDemand = _allDemands.firstWhere((d) => _selected.contains(_demKey(d)));
      final yrId = firstDemand['yr_id'] as int?;
      final yrlabel = firstDemand['demfeeyear']?.toString() ?? '';

      // Build items with demfeetype for grouping
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
          'yr_id': d['yr_id'],
          'yrlabel': d['demfeeyear']?.toString() ?? '',
          'ins_id': insId,
          'amount': net,
          'demfeetype': d['demfeetype']?.toString() ?? '',
        });
      }

      // Resolve a beneficiary bank for this Razorpay payment by walking
      // the items → feedemand.fee_id → feetype.fg_id → feegroup.ban_id
      // chain and picking the most common ban_id. Razorpay batches all
      // fee groups into one transaction, so we stamp the predominant
      // group's bank — good enough for the testing/demo flow. Mixed
      // multi-bank payments leave ban_id NULL and a real split-payment
      // gateway (Razorpay Route / virtual accounts) handles them later.
      int? razorpayBanId;
      try {
        final demIds = items.map((it) => it['dem_id']).whereType<int>().toList();
        if (demIds.isNotEmpty) {
          final fdRows = await SupabaseService.fromSchema('feedemand')
              .select('fee_id')
              .inFilter('dem_id', demIds);
          final feeIds = (fdRows as List)
              .map((r) => r['fee_id'])
              .whereType<int>()
              .toSet()
              .toList();
          if (feeIds.isNotEmpty) {
            final ftRows = await SupabaseService.fromSchema('feetype')
                .select('fg_id')
                .inFilter('fee_id', feeIds);
            final fgIds = (ftRows as List)
                .map((r) => r['fg_id'])
                .whereType<int>()
                .toSet()
                .toList();
            if (fgIds.isNotEmpty) {
              final fgRows = await SupabaseService.fromSchema('feegroup')
                  .select('ban_id')
                  .inFilter('fg_id', fgIds);
              final banIds = (fgRows as List)
                  .map((r) => r['ban_id'])
                  .whereType<int>()
                  .toList();
              if (banIds.isNotEmpty) {
                // Pick the ban_id that appears most often.
                final counts = <int, int>{};
                for (final id in banIds) {
                  counts[id] = (counts[id] ?? 0) + 1;
                }
                final entry = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
                razorpayBanId = entry.key;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('ban_id resolve failed: $e');
      }

      // 1. Create a temporary payment for Razorpay order (status I)
      final inserted = await SupabaseService.fromSchema('payment').insert({
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
        if (razorpayBanId != null) 'ban_id': razorpayBanId,
      }).select('pay_id').single();
      final payId = inserted['pay_id'] as int;

      // 2. Create Razorpay order
      final orderResponse = await SupabaseService.client.functions.invoke(
        'create-razorpay-order',
        body: {
          'amount': amountInPaise,
          'currency': 'INR',
          'pay_id': payId,
          'receipt': 'PAY-$payId',
        },
      );

      final orderData = orderResponse.data is Map<String, dynamic>
          ? orderResponse.data as Map<String, dynamic>
          : <String, dynamic>{};
      final orderId = orderData['order_id'] as String;

      // Update payorderid
      await SupabaseService.fromSchema('payment').update({
        'payorderid': orderId,
      }).eq('pay_id', payId).eq('ins_id', insId!);

      // 3. Build checkout HTML and open in browser
      final studentName = _student!['stuname']?.toString() ?? '';
      final studentMobile = _student!['stumobile']?.toString() ?? '';
      final studentEmail = _student!['stuemail']?.toString() ?? '';

      final html = '''
<!DOCTYPE html>
<html>
<head>
  <title>TBS School - Fee Payment</title>
  <meta charset="utf-8">
  <style>
    body { font-family: Arial, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
    .container { text-align: center; padding: 40px; background: white; border-radius: 12px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
    .success { color: #4CAF50; font-size: 24px; }
    .failed { color: #F44336; font-size: 24px; }
    .info { color: #666; margin-top: 10px; }
  </style>
  <script src="https://checkout.razorpay.com/v1/checkout.js"></script>
</head>
<body>
  <div class="container" id="status">
    <p>Opening Razorpay Checkout...</p>
  </div>
  <script>
    var options = {
      key: 'rzp_test_RQsgJgVFwM7kov',
      amount: $amountInPaise,
      currency: 'INR',
      name: 'TBS School',
      description: 'School Fees Payment',
      order_id: '$orderId',
      prefill: {
        name: '${studentName.replaceAll("'", "\\'")}',
        contact: '$studentMobile',
        email: '$studentEmail'
      },
      theme: { color: '#00B4AB' },
      notes: { pay_id: '$payId', student_id: '$stuId' },
      handler: function(response) {
        document.getElementById('status').innerHTML =
          '<p class="success">Payment Successful!</p>' +
          '<p class="info">Payment ID: ' + response.razorpay_payment_id + '</p>' +
          '<p class="info">You can close this window now.</p>';
      }
    };
    var rzp = new Razorpay(options);
    rzp.on('payment.failed', function(response) {
      document.getElementById('status').innerHTML =
        '<p class="failed">Payment Failed</p>' +
        '<p class="info">' + response.error.description + '</p>' +
        '<p class="info">You can close this window now.</p>';
    });
    rzp.open();
  </script>
</body>
</html>
''';

      // Write temp HTML file for WebView
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/tbs_razorpay_checkout_$payId.html');
      await tempFile.writeAsString(html);

      // 4. Show WebView dialog with Razorpay checkout + polling
      if (mounted) {
        await _showRazorpayWebViewDialog(payId, insId, totalNet, tempFile.path, inscode, stuId, createdBy);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Online payment failed. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      _pollTimer?.cancel();
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _showRazorpayWebViewDialog(int payId, int? insId, double totalNet, String htmlPath, String inscode, int stuId, String createdBy) async {
    final completer = Completer<String?>(); // 'C', 'F', or null (cancelled)
    final webviewController = WebviewController();

    try {
      await webviewController.initialize();
      await webviewController.setBackgroundColor(Colors.white);

      // Razorpay checkout URL allowlist (S5). The webview only ever loads a
      // local HTML file we generate; that HTML in turn loads checkout.js
      // from `checkout.razorpay.com`. Any other navigation target is
      // suspicious — log it and surface to the user. This is defence in
      // depth: the local HTML is the primary control.
      const allowedHosts = <String>{
        'checkout.razorpay.com',
        'api.razorpay.com',
        'lumberjack.razorpay.com',
        'lumberjack-cx.razorpay.com',
      };
      try {
        webviewController.url.listen((current) {
          if (current.isEmpty) return;
          final uri = Uri.tryParse(current);
          if (uri == null) return;
          if (uri.scheme == 'file' || uri.scheme == 'about' || uri.scheme == 'data') return;
          if (uri.scheme != 'https') {
            debugPrint('Razorpay webview blocked non-https navigation: $current');
            return;
          }
          if (!allowedHosts.contains(uri.host)) {
            debugPrint('Razorpay webview navigated to unexpected host: ${uri.host}');
          }
        });
      } catch (_) {
        // url stream may not be available on all platforms; skip silently.
      }

      await webviewController.loadUrl(Uri.file(htmlPath).toString());
    } catch (e) {
      if (!completer.isCompleted) completer.complete(null);
      // Most common failure here on Windows 10 pre-Oct-2021 boxes is the
      // WebView2 runtime not being installed. Give a specific, actionable
      // message instead of the raw exception text so the accountant knows
      // to call IT / install the runtime, not that payments are broken.
      final msg = e.toString().toLowerCase();
      final isWebView2Missing = msg.contains('webview2') ||
          msg.contains('not found') ||
          msg.contains('0x80070002');
      if (mounted) {
        if (isWebView2Missing) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Online payments unavailable'),
              content: const Text(
                'Microsoft Edge WebView2 runtime is missing on this PC, '
                'so the online payment window cannot open.\n\n'
                'Install the "Evergreen Bootstrapper" from:\n'
                'https://developer.microsoft.com/microsoft-edge/webview2/\n\n'
                'Or collect this payment as Cash / Cheque / UPI while IT installs it.',
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
              ],
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to open payment window. ${friendlyError(e)}'), backgroundColor: Colors.red),
          );
        }
      }
      return;
    }

    // Start polling for payment status. Cap total polling at 10 minutes.
    final pollStarted = DateTime.now();
    const pollMaxDuration = Duration(minutes: 10);
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (DateTime.now().difference(pollStarted) > pollMaxDuration) {
        timer.cancel();
        try {
          final payRec = await SupabaseService.fromSchema('payment')
              .select('payorderid').eq('pay_id', payId).single();
          final orderId = payRec['payorderid']?.toString();
          if (orderId != null && orderId.isNotEmpty) {
            final finalResp = await SupabaseService.client.functions.invoke(
              'get-razorpay-payment', body: {'order_id': orderId},
            );
            final fd = finalResp.data as Map<String, dynamic>;
            if (fd['status'] == 'captured' && fd['payment_id'] != null) {
              await SupabaseService.fromSchema('payment').update({
                'payreference': fd['payment_id'].toString(),
              }).eq('pay_id', payId).eq('ins_id', insId!);
              if (!completer.isCompleted) completer.complete('C');
              return;
            }
          }
        } catch (_) {}
        if (!completer.isCompleted) completer.complete('F');
        return;
      }
      try {
        final payRecord = await SupabaseService.fromSchema('payment')
            .select('payorderid')
            .eq('pay_id', payId)
            .single();

        final orderId = payRecord['payorderid']?.toString();
        if (orderId == null || orderId.isEmpty) return;

        final rpResponse = await SupabaseService.client.functions.invoke(
          'get-razorpay-payment',
          body: {'order_id': orderId},
        );

        final rpData = rpResponse.data as Map<String, dynamic>;
        final rpPaymentId = rpData['payment_id']?.toString();
        final rpStatus = rpData['status']?.toString();

        if (rpPaymentId != null && rpPaymentId.isNotEmpty) {
          if (rpStatus == 'captured') {
            timer.cancel();
            await SupabaseService.fromSchema('payment').update({
              'payreference': rpPaymentId,
            }).eq('pay_id', payId).eq('ins_id', insId!);
            if (!completer.isCompleted) completer.complete('C');
          } else if (rpStatus == 'failed') {
            timer.cancel();
            await SupabaseService.fromSchema('payment').update({
              'payreference': rpPaymentId,
            }).eq('pay_id', payId).eq('ins_id', insId!);
            if (!completer.isCompleted) completer.complete('F');
          }
        }
      } catch (_) {}
    });

    // Show WebView dialog. Capture its BuildContext so polling paths can
    // pop before we dispose the WebviewController.
    BuildContext? dialogCtx;
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialogCtx = ctx;
          return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
          child: SizedBox(
            width: 500.w,
            height: 620.h,
            child: Column(
              children: [
                // Header
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(14.r)),
                  ),
                  child: Row(
                    children: [
                      AppIcon.linear('wallet-money', color: Colors.white, size: 20),
                      SizedBox(width: 8.w),
                      Expanded(
                        child: Text(
                          'Razorpay Payment  -  Rs.${totalNet.toStringAsFixed(2)}',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15.sp),
                        ),
                      ),
                      InkWell(
                        onTap: () async {
                          _pollTimer?.cancel();
                          try {
                            final checkPay = await SupabaseService.fromSchema('payment')
                                .select('payreference')
                                .eq('pay_id', payId)
                                .eq('ins_id', insId!)
                                .maybeSingle();
                            final ref = checkPay?['payreference']?.toString() ?? '';
                            if (ref.isNotEmpty && ref.startsWith('pay_')) {
                              Navigator.pop(ctx);
                              if (!completer.isCompleted) completer.complete('C');
                              return;
                            }
                          } catch (_) {}
                          Navigator.pop(ctx);
                          if (!completer.isCompleted) completer.complete(null);
                        },
                        child: AppIcon.linear('close-circle', color: Colors.white, size: 20),
                      ),
                    ],
                  ),
                ),
                // WebView
                Expanded(
                  child: Webview(webviewController),
                ),
              ],
            ),
          ),
        );
        },
      );
    }

    final result = await completer.future;

    // Pop dialog first (if polling paths finished without popping).
    if (dialogCtx != null && dialogCtx!.mounted) {
      final nav = Navigator.maybeOf(dialogCtx!);
      if (nav != null && nav.canPop()) {
        nav.pop();
      }
    }

    // Let the exit animation finish before disposing the Webview.
    await Future.delayed(const Duration(milliseconds: 300));
    try { webviewController.dispose(); } catch (_) {}

    if (result == 'C' || result == 'F' || result == null) {
      final status = result == 'C' ? 'C' : 'F';

      // Get Razorpay reference
      String rpRef = '';
      try {
        final payRecord = await SupabaseService.fromSchema('payment')
            .select('payreference')
            .eq('pay_id', payId)
            .eq('ins_id', insId!)
            .maybeSingle();
        rpRef = payRecord?['payreference']?.toString() ?? '';
      } catch (_) {}

      // Build items with demfeetype for per-group receipts
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
          'amount': net,
          'demfeetype': d['demfeetype']?.toString() ?? '',
        });
      }

      // Store just the gateway txn id (no narrative prefix) so the
      // PowerCollege SETTLEMENT ID column shows it cleanly. Failed /
      // cancelled flows still get a short tag so they're distinguishable.
      String payRef = status == 'C' ? rpRef : (result == 'F' ? 'FAILED:$rpRef' : 'CANCELLED');

      try {
        final rpResult = await SupabaseService.client.rpc('complete_payment_grouped', params: {
          'p_pay_id': payId,
          'p_pay_method': 'online',
          'p_pay_reference': payRef,
          'p_items': items,
          'p_ins_id': insId,
          'p_status': status,
        });

        final receipts = rpResult is List ? rpResult : [rpResult];
        final receiptStr = receipts.map((r) => r is Map ? r['paynumber'] ?? r.toString() : r.toString()).join(', ');
        int? firstPayIdRp;
        for (final r in receipts) {
          if (r is Map && r['pay_id'] != null) {
            firstPayIdRp = r['pay_id'] is int ? r['pay_id'] as int : int.tryParse(r['pay_id'].toString());
            break;
          }
        }

        // On cancel/fail, explicitly reset fineamount to 0 on the attempted
        // demands so no stale fine value is left in the DB.
        if (status != 'C') {
          for (final item in items) {
            final demId = item['dem_id'];
            if (demId != null) {
              try {
                await SupabaseService.fromSchema('feedemand')
                    .update({'fineamount': 0})
                    .eq('dem_id', demId)
                    .eq('ins_id', insId!);
              } catch (e) {
                debugPrint('Fine reset error for dem_id=$demId: $e');
              }
            }
          }
        }

        if (mounted) {
          if (status == 'C') {
            _showSuccessDialog(receiptStr, totalNet, payId: firstPayIdRp);
          } else if (result == 'F') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Payment failed. Receipt: $receiptStr'), backgroundColor: Colors.red),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Payment cancelled. Receipt: $receiptStr'), backgroundColor: Colors.orange),
            );
          }
        }
      } catch (e) {
        debugPrint('complete_payment_grouped failed: $e');
        // Fallback: just mark as failed
        try {
          await SupabaseService.fromSchema('payment').update({
            'paystatus': 'F',
          }).eq('pay_id', payId).eq('ins_id', insId!);
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e)), backgroundColor: Colors.red),
          );
        }
      }
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
  InputDecoration _headerDropdownDec() {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10.r),
      borderSide: const BorderSide(color: AppColors.border),
    );
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border,
      enabledBorder: border,
      focusedBorder: border,
      disabledBorder: border,
    );
  }

  // Shared styling for the Cheque / UPI / Online dialog input fields so
  // every input renders with the same bold-visible look.
  InputDecoration _dialogInputDec({required String hint, Widget? prefix}) {
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
        borderSide: BorderSide(color: AppColors.border, width: 1.4),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12.r),
        borderSide: BorderSide(color: AppColors.border, width: 1.4),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12.r),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.8),
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

  InputDecoration _inputDec(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle:
          TextStyle(fontSize: 13.sp, color: AppColors.textLight),
      isDense: true,
      contentPadding:
          EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8.r),
          borderSide: BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8.r),
          borderSide: BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8.r),
          borderSide:
              const BorderSide(color: AppColors.accent, width: 1.5)),
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
        style: TextStyle(fontSize: 13.sp),
        decoration: InputDecoration(
          hintText: '0',
          hintStyle: TextStyle(
              fontSize: 13.sp, color: AppColors.textLight),
          contentPadding:
              EdgeInsets.symmetric(horizontal: 6.w, vertical: 4.h),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6.r),
              borderSide: BorderSide(color: AppColors.border)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6.r),
              borderSide: BorderSide(color: AppColors.border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6.r),
              borderSide: const BorderSide(
                  color: AppColors.accent, width: 1.2)),
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
              fontSize: 13.sp,
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
