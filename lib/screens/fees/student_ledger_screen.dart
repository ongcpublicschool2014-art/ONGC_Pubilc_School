import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/ledger_logic.dart' as ledger;
import '../../services/supabase_service.dart';
import '../../models/student_model.dart';
import '../../utils/formatters.dart';
import '../../utils/school_terms.dart';

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

  // Single-open accordion state for the course list - opening one course
  // auto-collapses any previously open course.
  String? _expandedCourse;
  final Map<String, ExpansibleController> _courseExpansionCtrls = {};

  // Search in student list
  final _searchController = TextEditingController();

  // Selected student & ledger data
  StudentModel? _selectedStudent;
  Map<String, dynamic>? _parent;
  List<Map<String, dynamic>> _demands = [];
  // Misc collections for the selected student: {feetype, amount, docno, docdate}.
  List<Map<String, dynamic>> _miscRows = [];
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
        // class + course masters with ordid for sidebar ordering - same
        // source the Students screen sidebar uses.
        SupabaseService.fromSchema('class').select('claname, ordid').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('course').select('courname, ordid').eq('ins_id', insId).eq('activestatus', 1),
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
          if (r['courname'] != null && r['ordid'] != null)
            r['courname'].toString().trim(): (r['ordid'] as num).toInt(),
      };

      final counts = <String, int>{};
      final courseCounts = <String, Map<String, int>>{};
      for (final s in students) {
        counts[s.stuclass] = (counts[s.stuclass] ?? 0) + 1;
        final course = s.courname ?? 'Other';
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
        // Master ordid order within each group, TC batches last
        // (utils/class_sort.dart).
        _classes = classGroupPartition([...ordered, ...extra], (s) => s);
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
      _miscRows = [];
      _parent = null;
      _loadingLedger = true;
    });
    try {
      debugPrint('LEDGER: insId=$insId stuId=${student.stuId} stuadmno=${student.stuadmno}');

      final parentFuture = SupabaseService.getStudentParent(student.stuId, stuadmno: student.stuadmno);
      final miscFuture = _loadMiscForStudent(insId, student);

      // Try stuadmno first (primary key used in feedemand). demseqtype +
      // demfeeyear drive the Regular / Arrear grouping.
      const selectFields = 'dem_id, demno, demfeetype, demfeeterm, demseqtype, demfeeyear, feeamount, conamount, paidamount, fineamount, balancedue, reconbalancedue, duedate, paidstatus, pay_id';
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
      final misc = await miscFuture;

      if (mounted) {
        setState(() {
          _parent = parent;
          _demands = demandList;
          _miscRows = misc;
          _loadingLedger = false;
        });
      }
    } catch (e) {
      debugPrint('LEDGER ERROR: $e');
      if (mounted) setState(() => _loadingLedger = false);
    }
  }

  /// Miscellaneous collections for this student — flattened to one row per fee
  /// type per receipt. Misc has no demand, so only Collection is populated.
  Future<List<Map<String, dynamic>>> _loadMiscForStudent(int insId, StudentModel student) async {
    try {
      var mc = await SupabaseService.fromSchema('misc_collection')
          .select('mc_id, mcno, mcdate')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('stu_id', student.stuId)
          .order('mcdate', ascending: true);
      var headers = List<Map<String, dynamic>>.from(mc as List);
      if (headers.isEmpty) {
        // Fallback: match by registration number.
        mc = await SupabaseService.fromSchema('misc_collection')
            .select('mc_id, mcno, mcdate')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('regno', student.stuadmno)
            .order('mcdate', ascending: true);
        headers = List<Map<String, dynamic>>.from(mc as List);
      }
      if (headers.isEmpty) return [];
      final mcIds = headers.map((h) => h['mc_id']).where((id) => id != null).toList();
      final details = await SupabaseService.fromSchema('misc_collection_detail')
          .select('mc_id, feetype, amount')
          .eq('activestatus', 1)
          .inFilter('mc_id', mcIds);
      final byMc = <dynamic, List<Map<String, dynamic>>>{};
      for (final d in List<Map<String, dynamic>>.from(details as List)) {
        (byMc[d['mc_id']] ??= []).add(d);
      }
      final rows = <Map<String, dynamic>>[];
      for (final h in headers) {
        final raw = h['mcdate']?.toString() ?? '';
        final date = raw.length >= 10 ? raw.substring(0, 10) : raw;
        for (final d in (byMc[h['mc_id']] ?? const [])) {
          rows.add({
            'feetype': d['feetype']?.toString() ?? 'Misc',
            'amount': (d['amount'] as num?)?.toDouble() ?? 0,
            'docno': h['mcno']?.toString() ?? '-',
            'docdate': date,
          });
        }
      }
      return rows;
    } catch (_) {
      return [];
    }
  }

  // Card totals are derived by the pure helper in lib/utils/ledger_logic.dart
  // so the formula is unit-tested and stays consistent with the dashboard.
  ledger.LedgerTotals get _totals => ledger.computeLedgerTotals(_demands);
  double get _totalDemand => _totals.demand;
  double get _totalPaid => _totals.paid;
  double get _totalPending => _totals.pending;


  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // â”€â”€ Left: Class list â”€â”€
        Container(
          width: 260.w,
          clipBehavior: Clip.antiAlias,
          decoration: AppUI.card(),
          child: Column(
            children: [
              Container(
                padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 10.h),
                child: Row(
                  children: [
                    AppIcon.linear('people', size: 20, color: AppColors.primary),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text('Students', style: AppUI.cardTitle),
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
                          style: TextStyle(fontSize: 12.sp, color: AppColors.accent, fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 1.h, color: AppColors.divider),
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
                            // Ordid order within each group, TC batches last.
                            for (final k in classGroupPartition(
                                rawClassCounts.keys.toList()
                                  ..sort((a, b) {
                                    final ai = _classOrdMap[a.trim()] ?? _classOrdMap[a] ?? 1 << 30;
                                    final bi = _classOrdMap[b.trim()] ?? _classOrdMap[b] ?? 1 << 30;
                                    if (ai != bi) return ai.compareTo(bi);
                                    return a.compareTo(b);
                                  }),
                                (s) => s))
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
                                  border: const Border(bottom: BorderSide(color: AppColors.divider, width: 1)),
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

        // â”€â”€ Right: Student list OR Ledger â”€â”€
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: AppUI.card(),
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

  // â”€â”€ All Students List (default view) â”€â”€
  Widget _buildAllStudentsList() {
    final q = _searchController.text.toLowerCase();
    final students = q.isEmpty
        ? _allStudents
        : _allStudents.where((s) =>
            s.stuname.toLowerCase().contains(q) ||
            s.stuadmno.toLowerCase().contains(q) ||
            (s.courname ?? '').toLowerCase().contains(q)).toList();

    return Column(
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(14.w, 10.h, 14.w, 0),
          child: Row(
            children: [
              AppIcon.linear('people', size: 20, color: AppColors.primary),
              SizedBox(width: 8.w),
              Text('All Students', style: AppUI.cardTitle),
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
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: AppColors.cardBorder),
              ),
              child: Column(
                children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        Expanded(flex: 1, child: Text('S NO.', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text(schoolTerm('ROLL NO'), style: AppUI.tableHead)),
                        Expanded(flex: 3, child: Text('STUDENT NAME', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text(schoolTerm('COURSE'), style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text(schoolTerm('CLASS'), style: AppUI.tableHead)),
                        if (!isSchool) Expanded(flex: 2, child: Text('BATCH', style: AppUI.tableHead)),
                        Expanded(flex: 1, child: Text('GENDER', style: AppUI.tableHead)),
                        Expanded(flex: 1, child: Text('ACTION', textAlign: TextAlign.right, style: AppUI.tableHead)),
                      ],
                    ),
                  ),
                  Container(height: 1, color: AppColors.divider),
                  Expanded(
                    child: AppVerticalScrollbar(
                      builder: (context, scrollCtrl) => ListView.separated(
                      controller: scrollCtrl,
                      itemCount: students.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (context, i) {
                        final s = students[i];
                        final cellStyle = AppUI.cell;
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _selectStudent(s),
                            child: Container(
                              color: i.isOdd ? AppColors.surface : Colors.white,
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                              child: Row(
                                children: [
                                  Expanded(flex: 1, child: Text('${i + 1}', style: cellStyle)),
                                  Expanded(flex: 2, child: Text(s.stuadmno, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                                  Expanded(flex: 3, child: Text(s.stuname, style: cellStyle, overflow: TextOverflow.ellipsis)),
                                  Expanded(flex: 2, child: Text(s.courname ?? '-', style: cellStyle)),
                                  Expanded(flex: 2, child: Text(s.stuclass, style: cellStyle)),
                                  if (!isSchool) Expanded(flex: 2, child: Text(s.batch ?? '-', style: cellStyle)),
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

  // â”€â”€ Student List â”€â”€
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
              Expanded(flex: 1, child: Text('S NO.', style: AppUI.tableHead)),
              Expanded(flex: 2, child: Text(schoolTerm('ROLL NO'), style: AppUI.tableHead)),
              Expanded(flex: 3, child: Text('STUDENT NAME', style: AppUI.tableHead)),
              Expanded(flex: 2, child: Text(schoolTerm('COURSE'), style: AppUI.tableHead)),
              if (!isSchool) Expanded(flex: 2, child: Text('BATCH', style: AppUI.tableHead)),
              Expanded(flex: 1, child: Text('GENDER', style: AppUI.tableHead)),
              Expanded(flex: 1, child: Text('ACTION', textAlign: TextAlign.right, style: AppUI.tableHead)),
            ],
          ),
        ),
            builder: (context, controller) => _loadingStudents
              ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
              : students.isEmpty
                  ? AppUI.empty(
                      title: 'No students found',
                      why: q.isEmpty ? 'No students in this class yet.' : 'No student matches the search. Clear the search to see everyone.',
                      icon: 'people',
                    )
                  : ListView.separated(
                      controller: controller,
                      itemCount: students.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (context, i) {
                        final s = students[i];
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _selectStudent(s),
                            child: Container(
                              color: i.isOdd ? AppColors.surface : Colors.white,
                              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                              child: Row(
                                children: [
                                  Expanded(flex: 1, child: Text('${i + 1}', style: AppUI.cell)),
                                  Expanded(flex: 2, child: Text(s.stuadmno, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                                  Expanded(flex: 3, child: Text(s.stuname, style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                                  Expanded(flex: 2, child: Text(s.courname ?? '-', style: AppUI.cell)),
                                  if (!isSchool) Expanded(flex: 2, child: Text(s.batch ?? '-', style: AppUI.cell)),
                                  Expanded(flex: 1, child: Text(s.stugender, style: AppUI.cell)),
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

  // â”€â”€ Ledger â”€â”€
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
              StudentAvatar(photoUrl: s.stuphoto, name: s.stuname, size: 44),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.stuname, style: AppUI.cardTitle),
                    Text('${isSchool ? 'Adm No' : 'Roll'}: ${s.stuadmno}  *  ${s.courname ?? ''} ${s.stuclass}  *  Father: $fatherName',
                        style: AppUI.muted),
                  ],
                ),
              ),
              if (!_loadingLedger) ...[
                _chip('Demand', '${formatIndianNumber(_totalDemand)}', AppColors.textPrimary),
                SizedBox(width: 8.w),
                _chip('Paid', '${formatIndianNumber(_totalPaid)}', AppColors.success),
                SizedBox(width: 8.w),
                _chip('Pending', '${formatIndianNumber(_totalPending)}', AppColors.error),
                SizedBox(width: 12.w),
                ElevatedButton.icon(
                  onPressed: _demands.isNotEmpty ? _exportToExcel : null,
                  icon: AppIcon('document-download', size: AppBtn.iconSize(context), color: _demands.isNotEmpty ? Colors.white : AppColors.textLight),
                  label: const Text('Export'),
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

  // Column widths for the grouped Regular / Arrear / Misc grid (Excel-style).
  static const double _wDetails = 96, _wFee = 180, _wDemand = 92, _wConcess = 84,
      _wNet = 100, _wColl = 96, _wDoc = 112, _wDate = 96, _wBal = 100;

  /// Builds the grouped ledger: Regular section, then Arrear (sub-grouped by
  /// year), then Misc (collection-only). Each 'data' row carries demand /
  /// concession / net / collection / balance + doc no & date.
  List<Map<String, dynamic>> _buildGrid() {
    final out = <Map<String, dynamic>>[];
    bool isArr(Map d) => (d['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
    Map<String, dynamic> dataRow(Map d) {
      final fee = (d['feeamount'] as num?)?.toDouble() ?? 0;
      final con = (d['conamount'] as num?)?.toDouble() ?? 0;
      final paid = (d['paidamount'] as num?)?.toDouble() ?? 0;
      final pay = d['payment'];
      final hasPay = paid > 0 && pay is Map;
      String docno = '-', docdate = '-';
      if (hasPay) {
        docno = pay['paynumber']?.toString() ?? '-';
        final r = pay['paydate']?.toString() ?? '';
        docdate = r.length >= 10 ? _fmt(r.substring(0, 10)) : r;
      }
      return {
        'kind': 'data',
        'details': d['demfeeterm']?.toString() ?? '-',
        'feetype': d['demfeetype']?.toString() ?? '-',
        'demand': fee, 'concess': con, 'net': fee - con,
        'collection': paid, 'docno': docno, 'docdate': docdate,
        'balance': (fee - con) - paid,
      };
    }

    final regular = _demands.where((d) => !isArr(d)).toList();
    final arrears = _demands.where(isArr).toList();
    if (regular.isNotEmpty) {
      out.add({'kind': 'section', 'label': 'Regular'});
      for (final d in regular) {
        out.add(dataRow(d));
      }
    }
    if (arrears.isNotEmpty) {
      out.add({'kind': 'section', 'label': 'Arrear'});
      final byYear = <String, List<Map<String, dynamic>>>{};
      for (final d in arrears) {
        final y = (d['demfeeyear']?.toString().trim().isNotEmpty == true) ? d['demfeeyear'].toString() : '-';
        (byYear[y] ??= []).add(d);
      }
      for (final e in byYear.entries) {
        out.add({'kind': 'year', 'label': e.key});
        for (final d in e.value) {
          out.add(dataRow(d));
        }
      }
    }
    if (_miscRows.isNotEmpty) {
      out.add({'kind': 'section', 'label': 'Misc'});
      for (final m in _miscRows) {
        out.add({
          'kind': 'data', 'misc': true,
          'details': '', 'feetype': m['feetype']?.toString() ?? 'Misc',
          'demand': null, 'concess': null, 'net': null,
          'collection': (m['amount'] as num?)?.toDouble() ?? 0,
          'docno': m['docno']?.toString() ?? '-',
          'docdate': _fmt(m['docdate']?.toString() ?? ''),
          'balance': null,
        });
      }
    }
    return out;
  }

  Widget _buildDemandsTab() {
    final grid = _buildGrid();
    double tDemand = 0, tCon = 0, tNet = 0, tColl = 0, tBal = 0;
    for (final r in grid) {
      if (r['kind'] != 'data') continue;
      tDemand += (r['demand'] as double?) ?? 0;
      tCon += (r['concess'] as double?) ?? 0;
      tNet += (r['net'] as double?) ?? 0;
      tColl += (r['collection'] as double?) ?? 0;
      tBal += (r['balance'] as double?) ?? 0;
    }
    const totalW = _wDetails + _wFee + _wDemand + _wConcess + _wNet + _wColl + _wDoc + _wDate + _wBal;

    Widget cell(String t, double w, {TextAlign align = TextAlign.left, bool head = false, Color? color, bool bold = false}) => SizedBox(
          width: w.w,
          child: Text(t, textAlign: align, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: (head ? AppUI.tableHead : AppUI.cell).copyWith(
                  fontSize: head ? 11.5.sp : 12.5.sp,
                  fontWeight: (head || bold) ? FontWeight.w700 : FontWeight.w500,
                  color: color)),
        );
    String amt(double? v) => v == null ? '' : (v == 0 ? '-' : formatIndianNumber(v));

    final header = Container(
      color: AppColors.tableHeadBg,
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
      child: Row(children: [
        cell('DETAILS', _wDetails, head: true),
        cell('FEE TYPE', _wFee, head: true),
        cell('DEMAND', _wDemand, align: TextAlign.right, head: true),
        cell('CONCESS.', _wConcess, align: TextAlign.right, head: true),
        cell('NET DEMAND', _wNet, align: TextAlign.right, head: true),
        cell('COLLECTION', _wColl, align: TextAlign.right, head: true),
        cell('DOC. NO', _wDoc, head: true),
        cell('DOC. DATE', _wDate, head: true),
        cell('BALANCE', _wBal, align: TextAlign.right, head: true),
      ]),
    );

    final totalRow = Container(
      color: AppColors.tableHeadBg,
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
      child: Row(children: [
        cell('TOTAL', _wDetails, head: true),
        cell('', _wFee),
        cell(formatIndianNumber(tDemand), _wDemand, align: TextAlign.right, head: true),
        cell(formatIndianNumber(tCon), _wConcess, align: TextAlign.right, head: true),
        cell(formatIndianNumber(tNet), _wNet, align: TextAlign.right, head: true),
        cell(formatIndianNumber(tColl), _wColl, align: TextAlign.right, head: true, color: AppColors.success),
        cell('', _wDoc),
        cell('', _wDate),
        cell(formatIndianNumber(tBal), _wBal, align: TextAlign.right, head: true, color: AppColors.error),
      ]),
    );

    Widget rowWidget(int i) {
      final r = grid[i];
      final kind = r['kind'];
      if (kind == 'section') {
        return Container(
          width: totalW.w,
          color: AppColors.accent.withValues(alpha: 0.08),
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
          child: Text(r['label'] as String,
              style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: AppColors.accent)),
        );
      }
      if (kind == 'year') {
        return Container(
          width: totalW.w,
          color: AppColors.surface,
          padding: EdgeInsets.symmetric(horizontal: 22.w, vertical: 6.h),
          child: Text(r['label'] as String,
              style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        );
      }
      final misc = r['misc'] == true;
      return Container(
        color: i.isOdd ? AppColors.surface : Colors.white,
        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 7.h),
        child: Row(children: [
          cell(r['details'] as String? ?? '', _wDetails),
          cell(r['feetype'] as String, _wFee, color: misc ? AppColors.today : AppColors.textPrimary, bold: true),
          cell(amt(r['demand'] as double?), _wDemand, align: TextAlign.right),
          cell(amt(r['concess'] as double?), _wConcess, align: TextAlign.right),
          cell(amt(r['net'] as double?), _wNet, align: TextAlign.right, color: AppColors.textPrimary),
          cell(amt(r['collection'] as double?), _wColl, align: TextAlign.right, color: AppColors.success),
          cell(r['docno'] as String? ?? '-', _wDoc),
          cell(r['docdate'] as String? ?? '-', _wDate),
          cell(amt(r['balance'] as double?), _wBal, align: TextAlign.right, color: AppColors.error, bold: true),
        ]),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.w),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: totalW.w,
            child: Column(children: [
              header,
              Container(height: 1, color: AppColors.divider),
              Expanded(
                child: grid.isEmpty
                    ? AppUI.empty(
                        title: 'No fee demands found for this student',
                        why: 'No fee demand has been raised for this student yet.',
                        icon: 'receipt-2',
                      )
                    : ListView.separated(
                        itemCount: grid.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                        itemBuilder: (context, i) => rowWidget(i),
                      ),
              ),
              Container(height: 1, color: AppColors.divider),
              totalRow,
            ]),
          ),
        ),
      ),
    );
  }


  Future<void> _exportToExcel() async {
    final s = _selectedStudent!;
    final fatherName = _parent?['fathername']?.toString() ?? '-';
    final grid = _buildGrid();
    double tDemand = 0, tCon = 0, tNet = 0, tColl = 0, tBal = 0;
    for (final r in grid) {
      if (r['kind'] != 'data') continue;
      tDemand += (r['demand'] as double?) ?? 0;
      tCon += (r['concess'] as double?) ?? 0;
      tNet += (r['net'] as double?) ?? 0;
      tColl += (r['collection'] as double?) ?? 0;
      tBal += (r['balance'] as double?) ?? 0;
    }

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

    addInfo(schoolTerm('Class'), ':  ${s.stuclass}');
    addInfo('Student Name', ':  ${s.stuname}');
    // Add roll no on same row as student name but further right
    final admCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row - 1));
    admCell.value = xl.TextCellValue('${schoolTerm('Roll No')} : ${s.stuadmno}');
    admCell.cellStyle = labelStyle;
    addInfo('Father Name', ':  $fatherName');
    row++;

    // Column headers — the Excel format the user provided.
    final headers = ['Details', 'FeeType', 'Demand', 'Concess.', 'Net Demand', 'Collection', 'Doc. No', 'Doc.Date', 'Balance'];
    for (var c = 0; c < headers.length; c++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row));
      cell.value = xl.TextCellValue(headers[c]);
      cell.cellStyle = colHeaderStyle;
    }
    row++;

    void put(int col, String text, {xl.CellStyle? style}) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
      cell.value = xl.TextCellValue(text);
      if (style != null) cell.cellStyle = style;
    }
    void putNum(int col, double? v, {xl.CellStyle? style}) {
      if (v == null) return;
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
      cell.value = xl.DoubleCellValue(v);
      if (style != null) cell.cellStyle = style;
    }

    // Grouped data rows (Regular / Arrear-by-year / Misc).
    for (final r in grid) {
      final kind = r['kind'];
      if (kind == 'section') {
        put(0, r['label'] as String, style: labelStyle);
        row++;
        continue;
      }
      if (kind == 'year') {
        put(0, r['label'] as String, style: labelStyle);
        row++;
        continue;
      }
      put(0, r['details'] as String? ?? '');
      put(1, r['feetype'] as String);
      putNum(2, r['demand'] as double?, style: debitStyle);
      putNum(3, r['concess'] as double?);
      putNum(4, r['net'] as double?);
      putNum(5, r['collection'] as double?, style: creditStyle);
      put(6, r['docno'] as String? ?? '-');
      put(7, r['docdate'] as String? ?? '-');
      putNum(8, r['balance'] as double?);
      row++;
    }

    // Total row
    put(0, 'Total', style: totalRowStyle);
    for (final c in [1, 6, 7]) {
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = totalRowStyle;
    }
    putNum(2, tDemand, style: totalRowStyle);
    putNum(3, tCon, style: totalRowStyle);
    putNum(4, tNet, style: totalRowStyle);
    putNum(5, tColl, style: totalRowStyle);
    putNum(8, tBal, style: totalRowStyle);

    // Column widths
    sheet.setColumnWidth(0, 14);
    sheet.setColumnWidth(1, 22);
    sheet.setColumnWidth(2, 13);
    sheet.setColumnWidth(3, 12);
    sheet.setColumnWidth(4, 14);
    sheet.setColumnWidth(5, 13);
    sheet.setColumnWidth(6, 16);
    sheet.setColumnWidth(7, 13);
    sheet.setColumnWidth(8, 13);

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
            SnackBar(content: Text('Ledger exported to $path'), backgroundColor: AppColors.success),
          );
        }
      }
    }
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


  Widget _emptyState(String icon, String msg) => AppUI.empty(title: msg, icon: icon);

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
      Text(text, textAlign: align, style: AppUI.tableHead);
}

