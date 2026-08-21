import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';

/// Interim Promotion — mid-year move of a single student to another class.
/// Pick the student by cascading Class Group → Current Class → Name (or by
/// typing the Admission No), choose a Transferred Class, then Save:
///   1. logs the transfer in the interim_promotion table,
///   2. updates students.stuclass / courname to the new class,
///   3. generates the new class's fee demands (existing demands are kept).
class InterimPromotionScreen extends StatefulWidget {
  const InterimPromotionScreen({super.key});

  @override
  State<InterimPromotionScreen> createState() => _InterimPromotionScreenState();
}

class _InterimPromotionScreenState extends State<InterimPromotionScreen> {
  final _admnController = TextEditingController();
  final _remarksController = TextEditingController();

  int? _docNo;
  DateTime _promotionDate = DateTime.now();

  List<Map<String, dynamic>> _courseList = []; // course master
  List<Map<String, dynamic>> _classList = []; // class

  String? _classGroup; // selected class group (course)
  String? _currentClass; // selected current class
  List<Map<String, dynamic>> _studentsInClass = [];
  Map<String, dynamic>? _student; // selected student
  String? _transferredCourse; // target class group
  String? _transferredClass; // target class

  // Fees the selected student has already PAID (sum of paidamount across active
  // demands). Promotion re-bills the student into the new class, which would
  // strand this money — so a paid student must be refunded first.
  double _studentPaid = 0;

  bool _loading = true;
  bool _looking = false;
  bool _loadingStudents = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _admnController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    if (auth.schema != null && auth.schema!.isNotEmpty) {
      SupabaseService.setSchema(auth.schema);
    }
    try {
      final results = await Future.wait<dynamic>([
        SupabaseService.fromSchema('course')
            .select('cour_id, courname, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('ordid', ascending: true),
        SupabaseService.fromSchema('class')
            .select('claname, cour_id, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('ordid', ascending: true),
      ]);
      final docNo = await _nextDocNo(insId);
      if (!mounted) return;
      setState(() {
        _courseList = List<Map<String, dynamic>>.from(results[0] as List);
        _classList = List<Map<String, dynamic>>.from(results[1] as List);
        _docNo = docNo;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Failed to load. ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<int> _nextDocNo(int insId) async {
    try {
      final res = await SupabaseService.fromSchema('interim_promotion')
          .select('doc_no')
          .eq('ins_id', insId)
          .order('doc_no', ascending: false)
          .limit(1)
          .maybeSingle();
      return ((res?['doc_no'] as num?)?.toInt() ?? 0) + 1;
    } catch (_) {
      return 1;
    }
  }

  // ── masters helpers ───────────────────────────────────────────────────────
  List<String> get _courseNames => _courseList
      .map((e) => e['courname']?.toString().trim() ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  List<String> _classNamesForCourse(String? group) {
    if (group == null || group.trim().isEmpty) return const [];
    final std = _courseList.firstWhere(
      (c) => (c['courname']?.toString().trim() ?? '') == group.trim(),
      orElse: () => const {},
    );
    final cgrpId = std['cour_id'];
    if (cgrpId == null) return const [];
    return _classList
        .where((cl) => cl['cour_id'] == cgrpId)
        .map((e) => e['claname']?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }

  // ── data loading ──────────────────────────────────────────────────────────
  Future<void> _loadStudentsInClass(String group, String className) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    setState(() {
      _loadingStudents = true;
      _studentsInClass = [];
      _student = null;
    });
    try {
      final res = await SupabaseService.fromSchema('students')
          .select('stu_id, stuadmno, stuname, stuclass, courname, stugender, hostel, admittyear')
          .eq('ins_id', insId)
          .eq('courname', group)
          .eq('stuclass', className)
          .eq('activestatus', 1)
          .order('stuname', ascending: true);
      if (!mounted) return;
      setState(() {
        _studentsInClass = List<Map<String, dynamic>>.from(res as List);
        _loadingStudents = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingStudents = false);
      _snack('Failed to load students. ${friendlyError(e)}', AppColors.error);
    }
  }

  /// Populate the form from a chosen student row (from the typeahead list or an
  /// exact-match lookup): load its class roster and select it.
  Future<void> _selectStudentRow(Map<String, dynamic> res) async {
    final group = res['courname']?.toString() ?? '';
    final className = res['stuclass']?.toString() ?? '';
    if (!mounted) return;
    setState(() {
      _admnController.text = res['stuadmno']?.toString() ?? '';
    });
    await _loadStudentsInClass(group, className);
    if (!mounted) return;
    setState(() {
      _classGroup = _courseNames.contains(group) ? group : null;
      _currentClass = className;
      _student = _studentsInClass.firstWhere(
        (s) => s['stu_id'] == res['stu_id'],
        orElse: () => Map<String, dynamic>.from(res),
      );
      _transferredCourse = null;
      _transferredClass = null;
    });
    await _loadStudentPaid();
  }

  /// Sum what the selected student has already paid across their active demands.
  /// A Fee Refund reduces paidamount back toward 0, so once fully refunded this
  /// returns 0 and promotion is allowed.
  Future<void> _loadStudentPaid() async {
    final student = _student;
    final stuId = (student?['stu_id'] as num?)?.toInt();
    if (stuId == null) {
      setState(() => _studentPaid = 0);
      return;
    }
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    setState(() => _studentPaid = 0);
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('feedemand')
          .select('paidamount')
          .eq('ins_id', insId)
          .eq('stu_id', stuId)
          .eq('activestatus', 1));
      var paid = 0.0;
      for (final r in rows) {
        paid += (r['paidamount'] as num?)?.toDouble() ?? 0;
      }
      if (!mounted) return;
      setState(() => _studentPaid = paid);
    } catch (_) {}
  }

  Future<void> _lookupByAdmn() async {
    final admn = _admnController.text.trim();
    if (admn.isEmpty) return;
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    setState(() => _looking = true);
    try {
      final res = await SupabaseService.fromSchema('students')
          .select('stu_id, stuadmno, stuname, stuclass, courname, stugender, hostel, admittyear')
          .eq('ins_id', insId)
          .eq('stuadmno', admn)
          .eq('activestatus', 1)
          .maybeSingle();
      if (!mounted) return;
      if (res == null) {
        setState(() => _looking = false);
        _snack('No active student with Admission No "$admn".', AppColors.warning);
        return;
      }
      await _selectStudentRow(res);
      if (!mounted) return;
      setState(() => _looking = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _looking = false);
      _snack('Lookup failed. ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<void> _save() async {
    final student = _student;
    if (student == null) {
      _popup('Student Required', 'Select a student (by class + name, or Admission No) first.', AppColors.warning);
      return;
    }
    final targetGroup = _transferredCourse;
    if (targetGroup == null || targetGroup.isEmpty) {
      _popup('Transferred Course Required', 'Select the course to transfer the student to.', AppColors.warning);
      return;
    }
    final target = _transferredClass;
    if (target == null || target.isEmpty) {
      _popup('Transferred Class Required', 'Select the class to transfer the student to.', AppColors.warning);
      return;
    }
    final currentClass = student['stuclass']?.toString().trim() ?? '';
    final currentGroup = student['courname']?.toString().trim() ?? '';
    if (targetGroup == currentGroup && target == currentClass) {
      _popup('Same Class', 'Transferred Course and Class are the same as the current class.', AppColors.warning);
      return;
    }
    // A paid student must be refunded before promotion — otherwise the amount
    // already collected is stranded when the new class's demands are raised.
    if (_studentPaid > 0.005) {
      _popup(
        'Refund Required First',
        '${student['stuname']} has already paid ₹${_studentPaid.toStringAsFixed(2)}. '
        'Process a Fee Refund for this student, then promote. Once refunded, the '
        'paid amount returns to 0 and promotion is allowed.',
        AppColors.warning,
      );
      return;
    }

    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    final inscode = auth.inscode ?? '';
    final stuId = student['stu_id'] as int;

    setState(() => _saving = true);
    try {
      await SupabaseService.fromSchema('interim_promotion').insert({
        'doc_no': _docNo,
        'ins_id': insId,
        'promotiondate': _promotionDate.toIso8601String().split('T').first,
        'stu_id': stuId,
        'stuadmno': student['stuadmno'],
        'courname': student['courname'],
        'stuclass': currentClass,
        'stuname': student['stuname'],
        'transferred_courname': targetGroup,
        'transferred_class': target,
        'remarks': _remarksController.text.trim().isEmpty ? null : _remarksController.text.trim(),
        'createdby': auth.userName,
        'activestatus': 1,
      });

      await SupabaseService.updateStudent(stuId, {
        'stuclass': target,
        if (targetGroup.isNotEmpty) 'courname': targetGroup,
      });

      final created = await SupabaseService.generateDemandsForStudent(
        insId: insId,
        inscode: inscode,
        student: student,
        targetClass: target,
        targetCourse: targetGroup,
        createdBy: auth.userName,
      );

      if (!mounted) return;
      setState(() => _saving = false);
      _snack(
        'Promoted ${student['stuname']} to $target'
        '${created > 0 ? ' • $created fee demand(s) generated for approval' : ''}.',
        AppColors.success,
      );
      _newRecord();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _popup('Save Failed', friendlyError(e), AppColors.error);
    }
  }

  Future<void> _newRecord() async {
    final auth = context.read<AuthProvider>();
    final docNo = await _nextDocNo(auth.insId ?? 1);
    if (!mounted) return;
    setState(() {
      _admnController.clear();
      _remarksController.clear();
      _classGroup = null;
      _currentClass = null;
      _studentsInClass = [];
      _student = null;
      _transferredCourse = null;
      _transferredClass = null;
      _studentPaid = 0;
      _promotionDate = DateTime.now();
      _docNo = docNo;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _promotionDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) setState(() => _promotionDate = picked);
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  void _popup(String title, String message, Color color) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: color, size: 22),
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

  @override
  Widget build(BuildContext context) {
    // Compact screens (the app's common 1366-class laptops) need tighter
    // spacing so the whole form fits the tab without scrolling.
    final compact = MediaQuery.of(context).size.width <= 1366;
    final pad = compact ? 14.0 : 20.0;
    final gap = compact ? 10.0 : 14.0;
    final btnGap = compact ? 16.0 : 24.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    // Fill the full tab (width and height): the form stretches
                    // edge-to-edge and the action buttons sit at the bottom.
                    // ConstrainedBox(minHeight) + IntrinsicHeight lets a Spacer
                    // push the buttons down while still scrolling on the rare
                    // occasion content (e.g. the Admn typeahead) exceeds the tab.
                    builder: (context, constraints) => SingleChildScrollView(
                      padding: EdgeInsets.all(pad.w),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: constraints.maxHeight - pad.w * 2),
                        child: IntrinsicHeight(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(Icons.trending_up, size: (compact ? 18 : 20).sp, color: AppColors.accent),
                                SizedBox(width: 8.w),
                                Text('Interim Promotion',
                                    style: TextStyle(fontSize: (compact ? 14 : 16).sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                              ]),
                              SizedBox(height: (compact ? 14 : 20).h),

                              _row2(
                                _field('Doc No', _readonlyBox(_docNo?.toString() ?? '—')),
                                _field('Promotion Date', _dateBox()),
                              ),
                              SizedBox(height: gap.h),

                              _row2(
                                _field('Course', _classGroupDropdown()),
                                _field('Class', _currentClassDropdown()),
                              ),
                              SizedBox(height: gap.h),

                              _row2(
                                _field('Name', _nameDropdown()),
                                _field('Admission No', _admnBox()),
                              ),
                              if (_student != null && _studentPaid > 0.005) ...[
                                SizedBox(height: gap.h),
                                _paidWarningBanner(compact),
                              ],
                              SizedBox(height: gap.h),

                              _row2(
                                _field('Transferred Course', _transferCourseDropdown()),
                                _field('Transferred Class', _transferClassDropdown()),
                              ),
                              SizedBox(height: gap.h),

                              _field('Remarks', TextField(
                                controller: _remarksController,
                                decoration: _dec(hint: 'Optional remarks'),
                                style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                              )),

                              const Spacer(),
                              SizedBox(height: btnGap.h),

                              Row(children: [
                                const Spacer(),
                                ElevatedButton.icon(
                                  onPressed: (_saving || _student == null) ? null : _save,
                                  icon: _saving
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : const Icon(Icons.save, size: 16),
                                  label: Text(_saving ? 'Saving…' : 'Save Promotion'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.accent,
                                    foregroundColor: Colors.white,
                                    padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: (compact ? 10 : 14).h),
                                  ),
                                ),
                              ]),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _row2(Widget a, Widget b) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(child: a), SizedBox(width: 16.w), Expanded(child: b)],
      );

  Widget _field(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textLight)),
          SizedBox(height: 6.h),
          child,
        ],
      );

  /// Shown when the selected student has unrefunded paid fees — promotion is
  /// blocked until a Fee Refund brings the paid amount back to 0.
  Widget _paidWarningBanner(bool compact) => Container(
        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: (compact ? 10 : 12).h),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          Icon(Icons.info_outline, size: (compact ? 16 : 18).sp, color: AppColors.warning),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              'This student has already paid ₹${_studentPaid.toStringAsFixed(2)}. '
              'Process a Fee Refund before promoting — otherwise the paid amount is '
              'stranded when the new class is billed.',
              style: TextStyle(fontSize: (compact ? 11 : 12).sp, color: AppColors.textSecondary, height: 1.35),
            ),
          ),
        ]),
      );

  Widget _readonlyBox(String text) => Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(text, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
      );

  Widget _classGroupDropdown() => DropdownButtonFormField<String>(
        initialValue: _courseNames.contains(_classGroup) ? _classGroup : null,
        isExpanded: true,
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 6,
        style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
        decoration: _dec(hint: 'Select course'),
        items: _courseNames.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
        onChanged: (v) => setState(() {
          _classGroup = v;
          _currentClass = null;
          _studentsInClass = [];
          _student = null;
          _transferredCourse = null;
          _transferredClass = null;
          _admnController.clear();
        }),
      );

  Widget _currentClassDropdown() {
    final options = _classNamesForCourse(_classGroup);
    return DropdownButtonFormField<String>(
      initialValue: options.contains(_currentClass) ? _currentClass : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(hint: 'Select class'),
      items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: _classGroup == null
          ? null
          : (v) {
              setState(() {
                _currentClass = v;
                _student = null;
                _transferredCourse = null;
                _transferredClass = null;
                _admnController.clear();
              });
              if (v != null) _loadStudentsInClass(_classGroup!, v);
            },
    );
  }

  Widget _nameDropdown() {
    final value = (_student != null && _studentsInClass.any((s) => s['stu_id'] == _student!['stu_id']))
        ? _student!['stu_id'] as int
        : null;
    return DropdownButtonFormField<int>(
      initialValue: value,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(hint: _loadingStudents ? 'Loading…' : 'Select student'),
      items: _studentsInClass
          .map((s) => DropdownMenuItem(
                value: s['stu_id'] as int,
                child: Text('${s['stuname'] ?? ''} (${s['stuadmno'] ?? ''})', overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: (_currentClass == null || _studentsInClass.isEmpty)
          ? null
          : (v) => setState(() {
                _student = _studentsInClass.firstWhere((s) => s['stu_id'] == v, orElse: () => {});
                _admnController.text = _student?['stuadmno']?.toString() ?? '';
                _transferredCourse = null;
                _transferredClass = null;
              }),
    );
  }

  Widget _admnBox() => TextField(
        controller: _admnController,
        decoration: _dec(hint: 'Type Admn No + Enter').copyWith(
          suffixIcon: _looking
              ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(icon: const Icon(Icons.search, size: 18), onPressed: _lookupByAdmn),
        ),
        style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
        // Exact lookup only (Enter or the search icon) — no per-keystroke
        // typeahead. Use the Name dropdown to pick from a list.
        onSubmitted: (_) => _lookupByAdmn(),
      );


  Widget _dateBox() => InkWell(
        onTap: _pickDate,
        borderRadius: BorderRadius.circular(8.r),
        child: InputDecorator(
          decoration: _dec().copyWith(
            suffixIcon: const Icon(Icons.calendar_today, size: 16, color: AppColors.textSecondary),
          ),
          child: Text(
            '${_promotionDate.day.toString().padLeft(2, '0')}/${_promotionDate.month.toString().padLeft(2, '0')}/${_promotionDate.year}',
            style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          ),
        ),
      );

  // Transferred Course — the class group the student is being moved into.
  Widget _transferCourseDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _courseNames.contains(_transferredCourse) ? _transferredCourse : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(hint: 'Select course'),
      items: _courseNames.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: _student == null
          ? null
          : (v) => setState(() {
                _transferredCourse = v;
                _transferredClass = null;
              }),
    );
  }

  // Transferred Class — a class within the chosen Transferred Course.
  Widget _transferClassDropdown() {
    final options = _classNamesForCourse(_transferredCourse);
    return DropdownButtonFormField<String>(
      initialValue: options.contains(_transferredClass) ? _transferredClass : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(hint: 'Select class'),
      items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (_student == null || _transferredCourse == null)
          ? null
          : (v) => setState(() => _transferredClass = v),
    );
  }

  InputDecoration _dec({String? hint}) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final vPad = compact ? 8.0 : 12.0;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textLight, fontSize: 13.sp),
      contentPadding: EdgeInsets.symmetric(horizontal: 14.w, vertical: vPad),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.accent)),
    );
  }
}
