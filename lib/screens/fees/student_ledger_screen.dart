import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/ledger_logic.dart' as ledger;
import '../../services/supabase_service.dart';
import '../../models/student_model.dart';
import '../../utils/formatters.dart';

class StudentLedgerScreen extends StatefulWidget {
  const StudentLedgerScreen({super.key});

  @override
  State<StudentLedgerScreen> createState() => _StudentLedgerScreenState();
}

class _StudentLedgerScreenState extends State<StudentLedgerScreen> {
  // Class list
  List<String> _classes = [];
  Map<String, int> _classCounts = {};
  Map<String, Map<String, int>> _courseClassCounts = {};
  Map<String, int> _classOrdMap = {};
  Map<String, int> _courseOrdMap = {};
  List<StudentModel> _allStudents = [];
  bool _loadingClasses = true;

  // Selected class & students
  String? _selectedClass;
  final Map<String, List<StudentModel>> _cachedClassStudents = {};
  bool _loadingStudents = false;

  // Single-open accordion state for the course list — opening one course
  // auto-collapses any previously open course.
  String? _expandedCourse;
  final Map<String, ExpansibleController> _courseExpansionCtrls = {};

  // Search in student list
  final _searchController = TextEditingController();

  // Selected student & ledger data
  StudentModel? _selectedStudent;
  Map<String, dynamic>? _parent;
  List<Map<String, dynamic>> _demands = [];
  bool _loadingLedger = false;

  static const List<String> _classOrder = [
    'PKG', 'LKG', 'UKG', 'I', 'II', 'III', 'IV', 'V',
    'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII',
  ];
  static const List<Color> _classColors = [
    Color(0xFF6366F1), Color(0xFF8B5CF6), Color(0xFFA855F7),
    Color(0xFFEC4899), Color(0xFFF43F5E), Color(0xFFEF4444),
    Color(0xFFF97316), Color(0xFFF59E0B), Color(0xFF22C55E),
    Color(0xFF6C8EEF), Color(0xFF06B6D4), Color(0xFF6C8EEF),
    Color(0xFF2563EB), Color(0xFF7C3AED), Color(0xFF9333EA), Color(0xFFDB2777),
  ];

  Color _classColor(String cls) {
    final i = _classOrder.indexOf(cls);
    return (i >= 0 && i < _classColors.length) ? _classColors[i] : AppColors.accent;
  }

  @override
  void initState() {
    super.initState();
    _loadClasses();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadClasses() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _loadingClasses = true);
    try {
      final results = await Future.wait<dynamic>([
        SupabaseService.getStudents(insId),
        // class + course masters with ordid for sidebar ordering — same
        // source the Students screen sidebar uses.
        SupabaseService.fromSchema('class').select('claname, ordid').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('clagrp').select('clagrpname, ordid').eq('ins_id', insId).eq('activestatus', 1),
      ]);
      final students = results[0] as List<StudentModel>;
      final classMaster = results[1] as List<dynamic>;
      final courseMaster = results[2] as List<dynamic>;
      final classOrdMap = <String, int>{
        for (final r in classMaster)
          if (r['claname'] != null && r['ordid'] != null)
            r['claname'].toString().trim(): (r['ordid'] as num).toInt(),
      };
      final courseOrdMap = <String, int>{
        for (final r in courseMaster)
          if (r['clagrpname'] != null && r['ordid'] != null)
            r['clagrpname'].toString().trim(): (r['ordid'] as num).toInt(),
      };

      final counts = <String, int>{};
      final courseCounts = <String, Map<String, int>>{};
      for (final s in students) {
        counts[s.stuclass] = (counts[s.stuclass] ?? 0) + 1;
        final course = s.clagrpname ?? 'Other';
        courseCounts.putIfAbsent(course, () => {});
        courseCounts[course]![s.stuclass] = (courseCounts[course]![s.stuclass] ?? 0) + 1;
      }
      final rawClasses = counts.keys.toList();
      final ordered = _classOrder.where(rawClasses.contains).toList();
      final extra = rawClasses.where((c) => !_classOrder.contains(c)).toList()
        ..sort((a, b) {
          final ai = classOrdMap[a.trim()] ?? classOrdMap[a] ?? 1 << 30;
          final bi = classOrdMap[b.trim()] ?? classOrdMap[b] ?? 1 << 30;
          if (ai != bi) return ai.compareTo(bi);
          return a.compareTo(b);
        });
      if (!mounted) return;
      setState(() {
        _allStudents = students;
        _classes = [...ordered, ...extra];
        _classCounts = counts;
        _courseClassCounts = courseCounts;
        _classOrdMap = classOrdMap;
        _courseOrdMap = courseOrdMap;
        _loadingClasses = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingClasses = false);
    }
  }

  Future<void> _selectClass(String className) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    setState(() {
      _selectedClass = className;
      _selectedStudent = null;
      _demands = [];
      _searchController.clear();
    });
    if (_cachedClassStudents[className] == null) {
      setState(() => _loadingStudents = true);
      final students = await SupabaseService.getStudentsByClass(insId, className);
      if (mounted) {
        setState(() {
          _cachedClassStudents[className] = students;
          _loadingStudents = false;
        });
      }
    }
  }

  Future<void> _selectStudent(StudentModel student) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    setState(() {
      _selectedStudent = student;
      _demands = [];
      _parent = null;
      _loadingLedger = true;
    });
    try {
      debugPrint('LEDGER: insId=$insId stuId=${student.stuId} stuadmno=${student.stuadmno}');

      final parentFuture = SupabaseService.getStudentParent(student.stuId, stuadmno: student.stuadmno);

      // Try stuadmno first (primary key used in feedemand)
      const selectFields = 'dem_id, demno, demfeetype, demfeeterm, feeamount, conamount, paidamount, fineamount, balancedue, reconbalancedue, duedate, paidstatus, pay_id';
      final demandsByAdmno = await SupabaseService.fromSchema('feedemand')
          .select(selectFields)
          .eq('ins_id', insId)
          .eq('stuadmno', student.stuadmno)
          .order('duedate', ascending: true);

      debugPrint('LEDGER: demands by stuadmno=${(demandsByAdmno as List).length}');

      // Fallback to stu_id if no results
      List<Map<String, dynamic>> demandList;
      if ((demandsByAdmno as List).isEmpty) {
        final demandsByStuId = await SupabaseService.fromSchema('feedemand')
            .select(selectFields)
            .eq('ins_id', insId)
            .eq('stu_id', student.stuId)
            .order('duedate', ascending: true);
        debugPrint('LEDGER: demands by stu_id=${(demandsByStuId as List).length}');
        demandList = List<Map<String, dynamic>>.from(demandsByStuId as List);
      } else {
        demandList = List<Map<String, dynamic>>.from(demandsByAdmno as List);
      }

      // Fetch payment info for paid demands
      final payIds = demandList
          .where((d) => (d['paidstatus'] == 'P' || (d['paidstatus'] == 'U' && ((d['paidamount'] as num?)?.toDouble() ?? 0) > 0)) && d['pay_id'] != null)
          .map((d) => d['pay_id'] as int)
          .toSet()
          .toList();

      Map<int, Map<String, dynamic>> paymentMap = {};
      if (payIds.isNotEmpty) {
        final payments = await SupabaseService.fromSchema('payment')
            .select('pay_id, paynumber, paydate, paymethod')
            .eq('ins_id', insId)
            .inFilter('pay_id', payIds);
        for (final p in (payments as List)) {
          paymentMap[p['pay_id'] as int] = Map<String, dynamic>.from(p);
        }
      }

      // Attach payment data to demands
      for (var i = 0; i < demandList.length; i++) {
        final payId = demandList[i]['pay_id'];
        if (payId != null && paymentMap.containsKey(payId)) {
          demandList[i]['payment'] = paymentMap[payId];
        }
      }

      final parent = await parentFuture;

      if (mounted) {
        setState(() {
          _parent = parent;
          _demands = demandList;
          _loadingLedger = false;
        });
      }
    } catch (e) {
      debugPrint('LEDGER ERROR: $e');
      if (mounted) setState(() => _loadingLedger = false);
    }
  }

  // Card totals are derived by the pure helper in lib/utils/ledger_logic.dart
  // so the formula is unit-tested and stays consistent with the dashboard.
  ledger.LedgerTotals get _totals => ledger.computeLedgerTotals(_demands);
  double get _totalDemand => _totals.demand;
  double get _totalPaid => _totals.paid;
  double get _totalPending => _totals.pending;

  // Ledger rows from feedemand: unpaid = debit only, paid = debit + credit
  List<Map<String, dynamic>> get _ledgerRows {
    final rows = <Map<String, dynamic>>[];
    for (final d in _demands) {
      final raw = d['duedate']?.toString() ?? '';
      final paidAmount = (d['paidamount'] as num?)?.toDouble() ?? 0;
      final hasPaid = paidAmount > 0;
      final payment = d['payment'];

      // Demand row (debit)
      rows.add({
        'date': raw.length >= 10 ? raw.substring(0, 10) : raw,
        'docno': d['demno']?.toString() ?? d['dem_id']?.toString() ?? '-',
        'term': d['demfeeterm']?.toString() ?? '-',
        'feetype': d['demfeetype']?.toString() ?? '-',
        'reference': '-',
        'debit': (d['feeamount'] as num?)?.toDouble() ?? 0.0,
        'credit': 0.0,
        'fine': 0.0,
        'type': 'demand',
      });

      // Payment row (credit) — only show for reconciled rows so RECEIVED
      // entries match the Paid card. Unreconciled rows surface as a Demand
      // with Pending balance only.
      final amt = (d['feeamount'] as num?)?.toDouble() ?? 0.0;
      final reconBal = (d['reconbalancedue'] as num?)?.toDouble()
          ?? (d['balancedue'] as num?)?.toDouble() ?? amt;
      final isReconciled = reconBal <= 0;
      if (hasPaid && payment is Map && isReconciled) {
        final payDate = payment['paydate']?.toString() ?? raw;
        final payNumber = payment['paynumber']?.toString() ?? '-';
        final payMethod = payment['paymethod']?.toString() ?? '-';
        final balance = (d['balancedue'] as num?)?.toDouble() ?? 0.0;
        final isPartial = balance > 0;
        rows.add({
          'date': payDate.length >= 10 ? payDate.substring(0, 10) : payDate,
          'docno': payNumber,
          'term': d['demfeeterm']?.toString() ?? '-',
          'feetype': isPartial ? 'Partial Payment ($payMethod)' : 'Payment ($payMethod)',
          'reference': d['demno']?.toString() ?? d['dem_id']?.toString() ?? '-',
          'debit': balance,
          'credit': paidAmount - ((d['fineamount'] as num?)?.toDouble() ?? 0),
          'fine': (d['fineamount'] as num?)?.toDouble() ?? 0,
          'type': 'payment',
        });
      }
    }
    // Demands first (sorted by date), then payments (sorted by date)
    rows.sort((a, b) {
      final typeA = a['type'] == 'demand' ? 0 : 1;
      final typeB = b['type'] == 'demand' ? 0 : 1;
      if (typeA != typeB) return typeA.compareTo(typeB);
      return (a['date'] as String).compareTo(b['date'] as String);
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // ── Left: Class list ──
        Container(
          width: 260.w,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Container(
                padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 10.h),
                child: Row(
                  children: [
                    AppIcon('people', size: 20, color: AppColors.accent),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text('Students',
                          style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    ),
                    if (!_loadingClasses)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10.r),
                        ),
                        child: Text(
                          '${_classCounts.values.fold(0, (a, b) => a + b)}',
                          style: TextStyle(fontSize: 13.sp, color: AppColors.accent, fontWeight: FontWeight.w700),
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 1.h, color: AppColors.border),
              Expanded(
                child: _loadingClasses
                    ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
                    : ListView.builder(
                        padding: EdgeInsets.symmetric(vertical: 4.h),
                        itemCount: _courseClassCounts.keys.length,
                        itemBuilder: (context, courseIndex) {
                          final courseNames = _courseClassCounts.keys.toList()
                            ..sort((a, b) {
                              final ai = _courseOrdMap[a.trim()] ?? _courseOrdMap[a] ?? 1 << 30;
                              final bi = _courseOrdMap[b.trim()] ?? _courseOrdMap[b] ?? 1 << 30;
                              if (ai != bi) return ai.compareTo(bi);
                              return a.compareTo(b);
                            });
                          final courseName = courseNames[courseIndex];
                          final rawClassCounts = _courseClassCounts[courseName]!;
                          final classCounts = <String, int>{
                            for (final k in rawClassCounts.keys.toList()
                              ..sort((a, b) {
                                final ai = _classOrdMap[a.trim()] ?? _classOrdMap[a] ?? 1 << 30;
                                final bi = _classOrdMap[b.trim()] ?? _classOrdMap[b] ?? 1 << 30;
                                if (ai != bi) return ai.compareTo(bi);
                                return a.compareTo(b);
                              }))
                              k: rawClassCounts[k]!,
                          };
                          final courseTotal = classCounts.values.fold<int>(0, (s, c) => s + c);
                          final controller = _courseExpansionCtrls.putIfAbsent(
                            courseName,
                            () => ExpansibleController(),
                          );

                          return ExpansionTile(
                            key: PageStorageKey<String>('course-$courseName'),
                            controller: controller,
                            initiallyExpanded: _expandedCourse == courseName,
                            onExpansionChanged: (isExpanded) {
                              // Defer to the next frame so we don't trigger
                              // setState while another ExpansionTile is still
                              // notifying its controller during the current
                              // build (collapse() chains into onExpansionChanged
                              // synchronously).
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted) return;
                                if (isExpanded) {
                                  final prev = _expandedCourse;
                                  if (prev != null && prev != courseName) {
                                    final prevCtrl = _courseExpansionCtrls[prev];
                                    try {
                                      prevCtrl?.collapse();
                                    } catch (_) {
                                      // Controller not attached (tile off-screen).
                                    }
                                  }
                                  setState(() => _expandedCourse = courseName);
                                } else if (_expandedCourse == courseName) {
                                  setState(() => _expandedCourse = null);
                                }
                              });
                            },
                            tilePadding: EdgeInsets.symmetric(horizontal: 14.w),
                            title: Text(courseName, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                                  decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12.r)),
                                  child: Text('$courseTotal', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
                                ),
                                SizedBox(width: 6.w),
                                AppIcon.linear('Chevron Down', size: 16, color: AppColors.textSecondary),
                              ],
                            ),
                            children: classCounts.keys.map((cls) {
                              final count = classCounts[cls] ?? 0;
                          final color = _classColor(cls);
                          final isSelected = _selectedClass == cls;
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => _selectClass(cls),
                              child: Container(
                                padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
                                decoration: BoxDecoration(
                                  color: isSelected ? color.withValues(alpha: 0.08) : null,
                                  border: const Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 34.w, height: 34.h,
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: isSelected ? 0.2 : 0.1),
                                        borderRadius: BorderRadius.circular(9.r),
                                      ),
                                      child: Center(child: AppIcon('book-1', size: 16, color: color)),
                                    ),
                                    SizedBox(width: 10.w),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(cls,
                                              style: TextStyle(fontSize: 13.sp, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500, color: isSelected ? color : AppColors.textPrimary)),
                                          Text('$count students',
                                              style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: isSelected ? 0.2 : 0.1),
                                        borderRadius: BorderRadius.circular(10.r),
                                      ),
                                      child: Text('$count', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: color)),
                                    ),
                                    SizedBox(width: 6.w),
                                    AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                                  ],
                                ),
                              ),
                            ),
                          );
                            }).toList(),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),

        SizedBox(width: 12.w),

        // ── Right: Student list OR Ledger ──
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: AppColors.border),
            ),
            child: _selectedStudent != null
                ? _buildLedger()
                : _selectedClass == null
                    ? _buildAllStudentsList()
                    : _buildStudentList(),
          ),
        ),
      ],
    );
  }

  // ── All Students List (default view) ──
  Widget _buildAllStudentsList() {
    final q = _searchController.text.toLowerCase();
    final students = q.isEmpty
        ? _allStudents
        : _allStudents.where((s) =>
            s.stuname.toLowerCase().contains(q) ||
            s.stuadmno.toLowerCase().contains(q) ||
            (s.clagrpname ?? '').toLowerCase().contains(q)).toList();

    return Column(
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(14.w, 10.h, 14.w, 0),
          child: Row(
            children: [
              AppIcon('people', size: 20, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('All Students', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10.r)),
                child: Text('${students.length}', style: TextStyle(fontSize: 12.sp, color: AppColors.primary, fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              AppSearchField(
                controller: _searchController,
                hintText: 'Search...',
                onChanged: (_) => setState(() {}),
                width: 240.w,
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.w),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        Expanded(flex: 1, child: Text('S NO.', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('ROLL NO', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 3, child: Text('STUDENT NAME', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('STANDARD', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('CLASS', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 1, child: Text('GENDER', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 1, child: Text('ACTION', textAlign: TextAlign.right, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                      ],
                    ),
                  ),
                  Container(height: 1, color: AppColors.border),
                  Expanded(
                    child: AppVerticalScrollbar(
                      builder: (context, scrollCtrl) => ListView.separated(
                      controller: scrollCtrl,
                      itemCount: students.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border),
                      itemBuilder: (context, i) {
                        final s = students[i];
                        final cellStyle = TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _selectStudent(s),
                            child: Container(
                              color: i.isOdd ? AppColors.surface : Colors.white,
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                              child: Row(
                                children: [
                                  Expanded(flex: 1, child: Text('${i + 1}', style: cellStyle)),
                                  Expanded(flex: 2, child: Text(s.stuadmno, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                                  Expanded(flex: 3, child: Text(s.stuname, style: cellStyle, overflow: TextOverflow.ellipsis)),
                                  Expanded(flex: 2, child: Text(s.clagrpname ?? '-', style: cellStyle)),
                                  Expanded(flex: 2, child: Text(s.stuclass, style: cellStyle)),
                                  Expanded(flex: 1, child: Text(s.stugender, style: cellStyle)),
                                  Expanded(flex: 1, child: Align(alignment: Alignment.centerRight, child: AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary))),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Student List ──
  Widget _buildStudentList() {
    final cls = _selectedClass!;
    final color = _classColor(cls);
    final allStudents = _cachedClassStudents[cls] ?? [];
    final q = _searchController.text.toLowerCase();
    final students = q.isEmpty
        ? allStudents
        : allStudents.where((s) =>
            s.stuname.toLowerCase().contains(q) ||
            s.stuadmno.toLowerCase().contains(q)).toList();

    return Column(
      children: [
        // Header
        Container(
          padding: EdgeInsets.fromLTRB(12.w, 10.h, 16.w, 10.h),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.06),
            borderRadius: BorderRadius.only(topLeft: Radius.circular(12.r), topRight: Radius.circular(12.r)),
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              AppIcon('book-1', size: 14, color: color),
              SizedBox(width: 6.w),
              Text(cls,
                  style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: color)),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10.r),
                ),
                child: Text('${allStudents.length} students',
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: color)),
              ),
              const Spacer(),
              AppSearchField(
                controller: _searchController,
                hintText: 'Search...',
                onChanged: (_) => setState(() {}),
                width: 260.w,
              ),
            ],
          ),
        ),

        // Table header + rows, sharing a reserved scrollbar lane
        Expanded(
          child: AppVerticalScrollbar(
            header: Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
          child: Row(
            children: [
              Expanded(flex: 1, child: Text('S NO.', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
              Expanded(flex: 2, child: Text('ROLL NO', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
              Expanded(flex: 3, child: Text('STUDENT NAME', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
              Expanded(flex: 2, child: Text('STANDARD', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
              Expanded(flex: 1, child: Text('GENDER', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
              Expanded(flex: 1, child: Text('ACTION', textAlign: TextAlign.right, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
            ],
          ),
        ),
            builder: (context, controller) => _loadingStudents
              ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
              : students.isEmpty
                  ? Center(child: Text('No students found', style: TextStyle(fontSize: 13.sp, color: Colors.grey.shade400)))
                  : ListView.separated(
                      controller: controller,
                      itemCount: students.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFEEEEEE)),
                      itemBuilder: (context, i) {
                        final s = students[i];
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _selectStudent(s),
                            child: Container(
                              color: i.isOdd ? AppColors.surface : Colors.white,
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                              child: Row(
                                children: [
                                  Expanded(flex: 1, child: Text('${i + 1}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 2, child: Text(s.stuadmno, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                                  Expanded(flex: 3, child: Text(s.stuname, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis)),
                                  Expanded(flex: 2, child: Text(s.clagrpname ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 1, child: Text(s.stugender, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                  Expanded(flex: 1, child: Align(alignment: Alignment.centerRight, child: AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary))),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
        ),
      ],
    );
  }

  // ── Ledger ──
  Widget _buildLedger() {
    final s = _selectedStudent!;
    final fatherName = _parent?['fathername']?.toString() ?? '-';

    return Column(
      children: [
        // Back + student info
        Container(
          padding: EdgeInsets.fromLTRB(14.w, 10.h, 14.w, 0),
          child: Row(
            children: [
              InkWell(
                onTap: () => setState(() {
                  _selectedStudent = null;
                  _demands = [];
                  _parent = null;
                }),
                borderRadius: BorderRadius.circular(8.r),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
                      SizedBox(width: 6.w),
                      Text('Back', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: Colors.white)),
                    ],
                  ),
                ),
              ),
              SizedBox(width: 12.w),
              Container(width: 1, height: 18, color: AppColors.border),
              SizedBox(width: 12.w),
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.accent.withValues(alpha: 0.12),
                child: (s.stuphoto != null && s.stuphoto!.startsWith('http'))
                    ? ClipOval(
                        child: Image.network(
                          s.stuphoto!,
                          width: 40.w, height: 40.h, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Text(s.stuname.isNotEmpty ? s.stuname[0].toUpperCase() : '?',
                              style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 14.sp)),
                        ),
                      )
                    : Text(s.stuname.isNotEmpty ? s.stuname[0].toUpperCase() : '?',
                        style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 14.sp)),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.stuname, style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    Text('Roll: ${s.stuadmno}  •  ${s.clagrpname ?? ''} ${s.stuclass}  •  Father: $fatherName',
                        style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              if (!_loadingLedger) ...[
                _chip('Demand', formatIndianNumber(_totalDemand), AppColors.textPrimary),
                SizedBox(width: 8.w),
                _chip('Paid', formatIndianNumber(_totalPaid), Colors.green.shade700),
                SizedBox(width: 8.w),
                _chip('Pending', formatIndianNumber(_totalPending), AppColors.error),
                SizedBox(width: 12.w),
                SizedBox(
                  height: AppBtn.height(context),
                  child: ElevatedButton.icon(
                  onPressed: _demands.isNotEmpty ? _exportToExcel : null,
                  icon: AppIcon('document-download', size: AppBtn.iconSize(context), color: Colors.white),
                  label: const Text('Export'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.4),
                    disabledForegroundColor: Colors.white,
                    elevation: 0,
                  ),
                  ),
                ),
              ],
            ],
          ),
        ),

        Expanded(
          child: _loadingLedger
              ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
              : _buildDemandsTab(),
        ),
      ],
    );
  }

  Widget _buildDemandsTab() {
    final rows = _ledgerRows;
    // Footer totals must agree with the Demand/Paid/Pending cards above:
    //   DUE     = total demand (sum of feeamount)
    //   RECEIVED = recon-aware paid (only reconciled portion)
    //   FINE    = recon-aware fine
    //   CLOSING = recon-aware pending
    final totalDebit  = _totalDemand;
    final totalCredit = _totalPaid;
    final totalFine   = _demands.fold(0.0, (s, d) {
      final amt = (d['feeamount'] as num?)?.toDouble() ?? 0;
      final reconBal = (d['reconbalancedue'] as num?)?.toDouble()
          ?? (d['balancedue'] as num?)?.toDouble() ?? amt;
      final fa = (d['fineamount'] as num?)?.toDouble() ?? 0;
      return s + (reconBal <= 0 ? fa : 0);
    });
    final closingBalance = _totalPending;

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.w),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
      children: [
        Expanded(
          child: AppVerticalScrollbar(
            header: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
        // ── Column header ──
        Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
          child: Row(
            children: [
              SizedBox(width: 100.w, child: const _TH('DATE')),
              SizedBox(width: 110.w, child: const _TH('DOC.NO')),
              SizedBox(width: 90.w,  child: const _TH('SEMESTER')),
              const Expanded(            child: _TH('FEE TYPE')),
              SizedBox(width: 110.w, child: const _TH('REFERENCE')),
              SizedBox(width: 100.w, child: const _TH('DUE', align: TextAlign.right)),
              SizedBox(width: 100.w, child: const _TH('RECEIVED', align: TextAlign.right)),
              SizedBox(width: 80.w, child: const _TH('FINE', align: TextAlign.right)),
            ],
          ),
        ),
        Container(height: 1, color: AppColors.border),
              ],
            ),
            builder: (context, controller) => rows.isEmpty
              ? Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppIcon.linear('receipt-2', size: 48.sp, color: Colors.grey.shade300),
                            SizedBox(height: 12.h),
                            Text('No fee demands found for this student',
                                style: TextStyle(fontSize: 13.sp, color: Colors.grey.shade400)),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : ListView.separated(
                  controller: controller,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFEEEEEE)),
                  itemBuilder: (context, i) {
                    final r      = rows[i];
                    final debit  = r['debit']  as double;
                    final credit = r['credit'] as double;
                    final isDemand = r['type'] == 'demand';
                    return Container(
                      color: i.isOdd ? AppColors.surface : Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 6.h),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 100.w,
                            child: Text(_fmt(r['date'] as String),
                                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                          ),
                          SizedBox(
                            width: 110.w,
                            child: Text(r['docno'] as String,
                                style: TextStyle(
                                    fontSize: 13.sp,
                                    fontWeight: FontWeight.w600,
                                    color: isDemand ? AppColors.accent : Colors.green.shade700)),
                          ),
                          SizedBox(
                            width: 90.w,
                            child: Text(r['term'] as String,
                                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                          ),
                          Expanded(
                            child: Row(
                              children: [
                                Container(
                                  width: 6.w, height: 6.h,
                                  margin: EdgeInsets.only(right: 6.w),
                                  decoration: BoxDecoration(
                                    color: isDemand ? AppColors.error.withValues(alpha: 0.7) : Colors.green.shade400,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                Expanded(
                                  child: Text(r['feetype'] as String,
                                      style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 110.w,
                            child: Text(r['reference'] as String,
                                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                                overflow: TextOverflow.ellipsis),
                          ),
                          SizedBox(
                            width: 100.w,
                            child: Text(
                              debit > 0 ? formatIndianNumber(debit) : '-',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontSize: 13.sp,
                                  fontWeight: FontWeight.w600,
                                  color: debit > 0 ? AppColors.error : AppColors.textSecondary),
                            ),
                          ),
                          SizedBox(
                            width: 100.w,
                            child: Text(
                              credit > 0 ? formatIndianNumber(credit) : '-',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontSize: 13.sp,
                                  fontWeight: FontWeight.w600,
                                  color: credit > 0 ? Colors.green.shade700 : AppColors.textSecondary),
                            ),
                          ),
                          SizedBox(
                            width: 80.w,
                            child: Text(
                              ((r['fine'] as num?)?.toDouble() ?? 0) > 0
                                  ? formatIndianNumber((r['fine'] as num).toDouble())
                                  : '-',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontSize: 13.sp,
                                  fontWeight: FontWeight.w600,
                                  color: ((r['fine'] as num?)?.toDouble() ?? 0) > 0
                                      ? Colors.orange.shade800
                                      : AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ),
        ),

        // ── Footer ──
        Container(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
          child: Column(
            children: [
              // Total row — same dark bg as header
              Container(
                color: AppColors.tableHeadBg,
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                child: Row(
                  children: [
                    SizedBox(width: 100.w),
                    SizedBox(width: 110.w),
                    SizedBox(width: 90.w),
                    Expanded(
                      child: Text('TOTAL',
                          style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary, letterSpacing: 0.5.w)),
                    ),
                    SizedBox(width: 110.w),
                    SizedBox(
                      width: 100.w,
                      child: Text(formatIndianNumber(totalDebit),
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                    ),
                    SizedBox(
                      width: 100.w,
                      child: Text(formatIndianNumber(totalCredit),
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                    ),
                    SizedBox(
                      width: 80.w,
                      child: Text(
                          totalFine > 0 ? formatIndianNumber(totalFine) : '-',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                    ),
                  ],
                ),
              ),
              // Closing Balance row — slightly lighter dark
              Container(
                color: AppColors.tableHeadBg,
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                child: Row(
                  children: [
                    SizedBox(width: 100.w),
                    SizedBox(width: 110.w),
                    SizedBox(width: 90.w),
                    Expanded(
                      child: Text('CLOSING BALANCE',
                          style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary, letterSpacing: 0.5.w)),
                    ),
                    SizedBox(width: 110.w),
                    SizedBox(
                      width: 280.w,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 6.h),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8.r),
                            border: Border.all(
                                color: AppColors.primary.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            closingBalance <= 0
                                ? '${formatIndianNumber(closingBalance.abs())}  Fine'
                                : '${formatIndianNumber(closingBalance)}  Due',
                            style: TextStyle(
                                fontSize: 14.sp,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary),
                          ),
                        ),
                      ),
                    ),
                  ],
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


  Future<void> _exportToExcel() async {
    final s = _selectedStudent!;
    final fatherName = _parent?['fathername']?.toString() ?? '-';
    final rows = _ledgerRows;
    final totalDebit = rows.fold(0.0, (s, r) => s + (r['debit'] as double));
    final totalCredit = rows.fold(0.0, (s, r) => s + (r['credit'] as double));
    final closingBal = totalDebit - totalCredit;

    // Fetch institution info
    final auth = Provider.of<AuthProvider>(context, listen: false);
    String insName = auth.insName ?? '';
    String insAddress = '';
    String insMobile = '';
    String insEmail = '';
    if (auth.insId != null) {
      final insInfo = await SupabaseService.getInstitutionInfo(auth.insId!);
      if (insInfo.name != null) insName = insInfo.name!;
      if (insInfo.address != null) insAddress = insInfo.address!;
      if (insInfo.mobile != null) insMobile = insInfo.mobile!;
      if (insInfo.email != null) insEmail = insInfo.email!;
    }

    final excel = xl.Excel.createExcel();
    final sheetName = 'Ledger';
    excel.rename('Sheet1', sheetName);
    final sheet = excel[sheetName];

    // Styles
    final headerStyle = xl.CellStyle(
      bold: true,
      fontSize: 14,
      horizontalAlign: xl.HorizontalAlign.Center,
    );
    final insStyle = xl.CellStyle(
      bold: true,
      fontSize: 13,
      horizontalAlign: xl.HorizontalAlign.Center,
    );
    final insDetailStyle = xl.CellStyle(
      fontSize: 10,
      horizontalAlign: xl.HorizontalAlign.Center,
    );
    final labelStyle = xl.CellStyle(bold: true, fontSize: 13);
    final colHeaderStyle = xl.CellStyle(
      bold: true,
      fontSize: 13,
      backgroundColorHex: xl.ExcelColor.fromHexString('#1E2532'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
    );
    final debitStyle = xl.CellStyle(
      fontColorHex: xl.ExcelColor.fromHexString('#EF4444'),
      bold: true,
    );
    final creditStyle = xl.CellStyle(
      fontColorHex: xl.ExcelColor.fromHexString('#22C55E'),
      bold: true,
    );
    final totalRowStyle = xl.CellStyle(
      bold: true,
      fontSize: 13,
      backgroundColorHex: xl.ExcelColor.fromHexString('#1E2532'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
    );

    int row = 0;

    // Institution name
    final insNameCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
    insNameCell.value = xl.TextCellValue(insName.toUpperCase());
    insNameCell.cellStyle = insStyle;
    sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row),
        xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row));
    row++;

    // Institution address
    if (insAddress.isNotEmpty) {
      final addrCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
      addrCell.value = xl.TextCellValue(insAddress);
      addrCell.cellStyle = insDetailStyle;
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row),
          xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row));
      row++;
    }

    // Institution contact (mobile & email)
    final contactParts = <String>[];
    if (insMobile.isNotEmpty) contactParts.add('Ph: $insMobile');
    if (insEmail.isNotEmpty) contactParts.add('Email: $insEmail');
    if (contactParts.isNotEmpty) {
      final contactCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
      contactCell.value = xl.TextCellValue(contactParts.join('  |  '));
      contactCell.cellStyle = insDetailStyle;
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row),
          xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row));
      row++;
    }
    row++; // blank row after institution info

    // Title
    final titleCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
    titleCell.value = xl.TextCellValue('STUDENT LEDGER - YEAR:  2025-2026');
    titleCell.cellStyle = headerStyle;
    sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row),
        xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row));
    row += 1;

    // Student info
    void addInfo(String label, String value) {
      final c1 = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
      c1.value = xl.TextCellValue(label);
      c1.cellStyle = labelStyle;
      final c2 = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row));
      c2.value = xl.TextCellValue(value);
      row++;
    }

    addInfo('Class', ':  ${s.stuclass}');
    addInfo('Student Name', ':  ${s.stuname}');
    // Add roll no on same row as student name but further right
    final admCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row - 1));
    admCell.value = xl.TextCellValue('Roll No : ${s.stuadmno}');
    admCell.cellStyle = labelStyle;
    addInfo('Father Name', ':  $fatherName');
    row++;

    // "Regular Fee Details:" label
    final regCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
    regCell.value = xl.TextCellValue('Regular Fee Details :');
    regCell.cellStyle = labelStyle;
    row++;

    // Column headers
    final headers = ['Date', 'Doc No.', 'Semester', 'Fee Type', 'Reference', 'Debit (Rs.)', 'Credit (Rs.)'];
    for (var c = 0; c < headers.length; c++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row));
      cell.value = xl.TextCellValue(headers[c]);
      cell.cellStyle = colHeaderStyle;
    }
    row++;

    // Data rows
    for (final r in rows) {
      final isDemand = r['type'] == 'demand';
      final debit = r['debit'] as double;
      final credit = r['credit'] as double;

      final dateStr = _fmt(r['date'] as String);
      final docNo = r['docno'] as String;
      final reference = isDemand ? 'Reg Demand' : 'Reg Collection${_capitalize(r['feetype'] as String)}';

      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value = xl.TextCellValue(dateStr);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value = xl.TextCellValue(docNo);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value = xl.TextCellValue(r['term'] as String);
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row)).value = xl.TextCellValue(
          isDemand ? (r['feetype'] as String) : '');
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row)).value = xl.TextCellValue(reference);

      if (debit > 0) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row));
        cell.value = xl.DoubleCellValue(debit);
        cell.cellStyle = debitStyle;
      }
      if (credit > 0) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row));
        cell.value = xl.DoubleCellValue(credit);
        cell.cellStyle = creditStyle;
      }
      row++;
    }

    // G Total row
    final gtLabels = ['', '', '', '', 'G Total'];
    for (var c = 0; c < gtLabels.length; c++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row));
      cell.value = xl.TextCellValue(gtLabels[c]);
      cell.cellStyle = totalRowStyle;
    }
    final gtDebit = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row));
    gtDebit.value = xl.DoubleCellValue(totalDebit);
    gtDebit.cellStyle = totalRowStyle;
    final gtCredit = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row));
    gtCredit.value = xl.DoubleCellValue(totalCredit);
    gtCredit.cellStyle = totalRowStyle;
    row++;

    // Closing Bal row
    final cbCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
    cbCell.value = xl.TextCellValue('Closing Bal');
    cbCell.cellStyle = labelStyle;
    final cbVal = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row));
    cbVal.value = xl.DoubleCellValue(closingBal.abs());
    cbVal.cellStyle = labelStyle;
    row++;

    // Net Closing Balance row
    final ncbCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row));
    ncbCell.value = xl.TextCellValue('Net Closing Balance');
    ncbCell.cellStyle = labelStyle;
    final ncbVal = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row));
    ncbVal.value = xl.DoubleCellValue(closingBal.abs());
    ncbVal.cellStyle = labelStyle;

    // Column widths
    sheet.setColumnWidth(0, 14);
    sheet.setColumnWidth(1, 16);
    sheet.setColumnWidth(2, 14);
    sheet.setColumnWidth(3, 20);
    sheet.setColumnWidth(4, 22);
    sheet.setColumnWidth(5, 14);
    sheet.setColumnWidth(6, 14);

    // Save
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Student Ledger',
      fileName: 'Ledger_${s.stuadmno}_${s.stuname.replaceAll(' ', '_')}.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );

    if (result != null) {
      final path = result.endsWith('.xlsx') ? result : '$result.xlsx';
      final bytes = excel.encode();
      if (bytes != null) {
        await File(path).writeAsBytes(bytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ledger exported to $path'), backgroundColor: Colors.green),
          );
        }
      }
    }
  }

  String _capitalize(String s) {
    // Extract payment method from "Payment (cash)" => "Cash"
    final match = RegExp(r'Payment \((\w+)\)').firstMatch(s);
    if (match != null) {
      final method = match.group(1)!;
      return method[0].toUpperCase() + method.substring(1);
    }
    return s;
  }

  Widget _chip(String label, String value, Color color) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600, color: color.withValues(alpha: 0.85), letterSpacing: 0.2)),
          SizedBox(height: 2.h),
          Text(value, style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w800, color: color)),
        ],
      ),
    );
  }


  Widget _emptyState(String icon, String msg) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      AppIcon(icon, size: 48.sp, color: Colors.grey.shade300),
      SizedBox(height: 12.h),
      Text(msg, style: TextStyle(fontSize: 13.sp, color: Colors.grey.shade400)),
    ]),
  );

  String _fmt(String iso) {
    final p = iso.split('-');
    return p.length == 3 ? '${p[2]}/${p[1]}/${p[0]}' : iso;
  }
}

class _TH extends StatelessWidget {
  final String text;
  final TextAlign align;
  const _TH(this.text, {this.align = TextAlign.left});
  @override
  Widget build(BuildContext context) =>
      Text(text, textAlign: align, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3));
}

