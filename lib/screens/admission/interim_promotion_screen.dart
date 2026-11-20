import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/form_section_panel.dart';
import '../../widgets/student_avatar.dart';
import '../../widgets/app_dropdown_field.dart';

/// Interim Promotion — mid-year move of a single student to another class.
/// Pick the student by cascading Class Group → Current Class → Name (or by
/// typing the Reg No), choose a Transferred Class, then Save:
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

  // Admission type. Shown on BOTH sides of the form: the left side is the
  // student's CURRENT type (read-only, proves what is changing), the right
  // side is the type they are transferring INTO. The new type — not the old
  // one — decides which of the target class's fees apply, and it is written
  // back onto the student when the transfer is saved.
  List<Map<String, dynamic>> _admTypeList = []; // admissiontype master
  String? _currentAdmName; // display only, from the selected student
  int? _currentAdmId;
  String? _transferredAdmName; // selected target admission type

  // Fees the selected student has already PAID (sum of paidamount across active
  // demands). Promotion re-bills the student into the new class, which would
  // strand this money — so a paid student must be refunded first.
  double _studentPaid = 0;

  // Course-transfer fee adjustment. Once a student + transferred class are
  // chosen, show the current course's fees (Paid/Balance) and the new course's
  // fee structure; the admin ticks which new fees to credit the old paid amount
  // to (map: classfeedemand cf_id -> amount applied).
  List<Map<String, dynamic>> _currentFees = [];
  List<Map<String, dynamic>> _newFees = [];
  final Map<int, double> _applyCredit = {};
  // Per-fee new-course amounts typed on the Adjust Fees page (cf_id -> NET amount
  // = new fee − old paid).
  final Map<int, double> _applyAmount = {};
  // Per-fee old PAID applied on the Adjust Fees page (cf_id -> amount). Kept so
  // this summary bar shows the SAME chips as the Adjust Fees page.
  final Map<int, double> _applyPaid = {};
  /// Set once Apply Credit has run for this student. Apply hands back the NET
  /// fee (fee - matched old paid), so reopening the page editable would treat
  /// that net as the gross and Auto-match would deduct the old paid twice.
  /// Reopening is therefore view-only until Reset.
  bool _creditApplied = false;
  bool _loadingFees = false;

  // Concession total across the fees ticked on the Adjust Fees page.
  double get _appliedTotal =>
      _applyCredit.values.fold(0.0, (s, v) => s + v);
  // Old paid applied across the ticked fees.
  double get _oldPaidUsed =>
      _applyPaid.values.fold(0.0, (s, v) => s + v);
  // NET new-course total = sum of the ticked new-fee amounts (_applyAmount holds
  // only the ticked fees). Falls back to the raw classfeedemand total before adjust.
  double get _newFeesTotal => _applyAmount.isNotEmpty
      ? _applyAmount.values.fold(0.0, (s, v) => s + v)
      : _newFees.fold(
          0.0, (s, f) => s + ((f['cfamount'] as num?)?.toDouble() ?? 0));
  // Full new-course total (before old-paid reduction) = net + old paid used —
  // mirrors the Adjust Fees page "New Course Total" chip.
  double get _newCourseTotal => _newFeesTotal + _oldPaidUsed;
  double get _toBePaid => (_newFeesTotal - _appliedTotal).clamp(0, double.infinity);

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
        // No admission type on the school database.
        if (!isSchool)
          SupabaseService.fromSchema('admissiontype')
              .select('adm_id, admname')
              .eq('ins_id', insId)
              .eq('activestatus', 1)
              .order('adm_id', ascending: true),
      ]);
      final docNo = await _nextDocNo(insId);
      if (!mounted) return;
      setState(() {
        _courseList = List<Map<String, dynamic>>.from(results[0] as List);
        _classList = List<Map<String, dynamic>>.from(results[1] as List);
        _admTypeList = results.length > 2
            ? List<Map<String, dynamic>>.from(results[2] as List)
            : <Map<String, dynamic>>[];
        _docNo = docNo;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load the transfer details. ${friendlyError(e)}', AppColors.error);
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
    // Keeps the master's own order within each group and sends the TC
    // batches to the foot of the list (utils/class_sort.dart).
    return classGroupPartition(
        _classList
            .where((cl) => cl['cour_id'] == cgrpId)
            .map((e) => e['claname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty),
        (s) => s);
  }

  // ── data loading ──────────────────────────────────────────────────────────
  Future<void> _loadStudentsInClass(String group, String className) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    setState(() {
      _loadingStudents = true;
      _studentsInClass = [];
      _student = null;
      _syncAdmTypeFromStudent();
    });
    try {
      final res = await SupabaseService.fromSchema('students')
          .select(_studentCols)
          .eq('ins_id', insId)
          .eq('courname', group)
          .eq('stuclass', className)
          .eq('activestatus', 1)
          .eq('preadmission', 0)  // next year's intake: advance screens only
          .order('stuname', ascending: true);
      if (!mounted) return;
      setState(() {
        _studentsInClass = List<Map<String, dynamic>>.from(res as List);
        _loadingStudents = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingStudents = false);
      _snack('Could not load the students. ${friendlyError(e)}', AppColors.error);
    }
  }

  /// Populate the form from a chosen student row (from the typeahead list or an
  /// exact-match lookup): load its class roster and select it.

  /// Read the selected student's admission type into the read-only left-hand
  /// field, and seed the Transfer To side with the same value. Seeding rather
  /// than leaving it blank matters: most transfers keep the admission type, so
  /// a blank would make the common case an extra click AND would silently
  /// change the fees that load. The admin can still change it.
  void _syncAdmTypeFromStudent() {
    final s = _student;
    if (s == null) {
      _currentAdmName = null;
      _currentAdmId = null;
      _transferredAdmName = null;
      return;
    }
    _currentAdmId = (s['adm_id'] as num?)?.toInt();
    var name = s['admname']?.toString().trim();
    // students.adm_id and students.admname are both frequently NULL on
    // imported rows, and either one can be the populated one. Resolve
    // whichever is missing from the master so the field is never blank for a
    // student who does have a type.
    if (_currentAdmId != null && (name == null || name.isEmpty)) {
      for (final a in _admTypeList) {
        if ((a['adm_id'] as num?)?.toInt() == _currentAdmId) {
          name = a['admname']?.toString();
          break;
        }
      }
    } else if (_currentAdmId == null && name != null && name.isNotEmpty) {
      for (final a in _admTypeList) {
        if ((a['admname']?.toString().trim().toUpperCase() ?? '') ==
            name.toUpperCase()) {
          _currentAdmId = (a['adm_id'] as num?)?.toInt();
          break;
        }
      }
    }
    _currentAdmName = (name == null || name.isEmpty) ? null : name;
    _transferredAdmName = _currentAdmName;
  }

  /// The class/course the student ENDS UP in. A blank Transfer To selection
  /// means "stay put" -- which is the admission-type-only case: same course,
  /// same class, different quota, fees re-derived from the new type.
  String? get _effectiveTargetClass =>
      (_transferredClass != null && _transferredClass!.isNotEmpty)
          ? _transferredClass
          : _student?['stuclass']?.toString();

  String? get _effectiveTargetCourse =>
      (_transferredCourse != null && _transferredCourse!.isNotEmpty)
          ? _transferredCourse
          : _student?['courname']?.toString();

  /// True when the admin picked a different admission type from the student's
  /// current one. On its own this is enough to justify a transfer.
  bool get _admTypeChanged =>
      _transferredAdmId != null && _transferredAdmId != _currentAdmId;

  /// Something must actually change before fees are re-derived, or merely
  /// selecting a student would rebuild their demands.
  bool get _hasTargetChange =>
      (_transferredClass != null && _transferredClass!.isNotEmpty) ||
      _admTypeChanged;

  /// adm_id for the Transfer To admission type (null when none is chosen).
  int? get _transferredAdmId {
    final n = _transferredAdmName;
    if (n == null) return null;
    for (final a in _admTypeList) {
      if ((a['admname']?.toString().trim() ?? '') == n.trim()) {
        return (a['adm_id'] as num?)?.toInt();
      }
    }
    return null;
  }

  /// Student columns read by this screen. School has no admission type.
  String get _studentCols => isSchool
      ? 'stu_id, stuadmno, stuname, stuclass, courname, stugender, hostel, admittyear, stuphoto'
      : 'stu_id, stuadmno, stuname, stuclass, courname, stugender, hostel, admittyear, adm_id, admname, stuphoto';

  List<String> get _admTypeNames => _admTypeList
      .map((a) => a['admname']?.toString() ?? '')
      .where((e) => e.isNotEmpty)
      .toList();
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
      _syncAdmTypeFromStudent();
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
    _loadTransferFees();
  }

  /// Load the current course fees (Paid/Balance) + the new course's fee
  /// structure, and pre-fill the credit allocation greedily from the old paid
  /// amount. Runs once a student AND a transferred class are both chosen.
  Future<void> _loadTransferFees() async {
    final student = _student;
    final target = _effectiveTargetClass;
    if (student == null || target == null || target.isEmpty || !_hasTargetChange) {
      if (mounted) {
        setState(() {
          _currentFees = [];
          _newFees = [];
          _applyCredit.clear();
          _applyAmount.clear();
          _creditApplied = false;
          _applyPaid.clear();
        });
      }
      return;
    }
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    final stuId = (student['stu_id'] as num).toInt();
    setState(() => _loadingFees = true);
    try {
      // Admission-type used to filter the new class's fees. This is the
      // TRANSFER TO type, not the student's current one: after the transfer
      // they ARE the new type, so the new course's fees must be selected by
      // it. Falls back to the student's existing type when the admin has not
      // picked one, which preserves the old behaviour.
      final admId = _transferredAdmId ?? _currentAdmId;

      final results = await Future.wait<dynamic>([
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('feedemand')
            .select(
                'demfeetype, demfeeterm, feeamount, conamount, paidamount, balancedue')
            .eq('ins_id', insId)
            .eq('stu_id', stuId)
            .eq('activestatus', 1)),
        // classfeedemand is per-schema and has NO ins_id column.
        SupabaseService.fromSchema('classfeedemand')
            .select(isSchool
                ? 'cf_id, cffeetype, cfterm, cfamount'
                : 'cf_id, cffeetype, cfterm, cfamount, admissiontype')
            .eq('cfclass', target)
            .eq('activestatus', 1)
            .order('cf_id', ascending: true),
      ]);
      final current = List<Map<String, dynamic>>.from(results[0] as List);
      final newAll = List<Map<String, dynamic>>.from(results[1] as List);
      final newFees = newAll.where((f) {
        if ((f['cfamount'] as num?) == null) return false;
        final at = f['admissiontype'];
        return at == null || (admId != null && (at as num).toInt() == admId);
      }).toList();

      // Old-paid credit pool = what the student has already paid on the current
      // course, summed from the SAME active-demand rows shown in the Current
      // card — so the "Old Paid" summary and the card can never disagree. (The
      // separately-timed _loadStudentPaid can silently fail and leave 0.)
      final paidSum = current.fold<double>(
          0, (s, f) => s + ((f['paidamount'] as num?)?.toDouble() ?? 0));

      if (!mounted) return;
      setState(() {
        _studentPaid = paidSum;
        _currentFees = current;
        _newFees = newFees;
        // Start with nothing applied; the admin types amounts + ticks credit.
        _applyCredit.clear();
        _applyAmount.clear();
        _creditApplied = false;
        _applyPaid.clear();
        _loadingFees = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingFees = false);
      _snack('${schoolTerm('Could not load the fees for the new course.')} ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<void> _lookupByAdmn() async {
    final admn = _admnController.text.trim();
    if (admn.isEmpty) return;
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    setState(() => _looking = true);
    try {
      final res = await SupabaseService.fromSchema('students')
          .select(_studentCols)
          .eq('ins_id', insId)
          .eq('stuadmno', admn)
          .eq('activestatus', 1)
          .eq('preadmission', 0)  // next year's intake: advance screens only
          .maybeSingle();
      if (!mounted) return;
      if (res == null) {
        setState(() => _looking = false);
        _snack(schoolTerm('No active student found with Register No. "$admn". Check the number and try again.'), AppColors.warning);
        return;
      }
      await _selectStudentRow(res);
      if (!mounted) return;
      setState(() => _looking = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _looking = false);
      _snack('Could not look up the student. ${friendlyError(e)}', AppColors.error);
    }
  }

  Future<void> _save() async {
    final student = _student;
    if (student == null) {
      _popup('Student Required', schoolTerm('Select a student first, by class and name or by Register No.'), AppColors.warning);
      return;
    }
    // Course/Class may be left blank: that means "keep the current one", which
    // is how an admission-type-only change is expressed. Only one of the two
    // may be blank on its own, though -- a course with no class is ambiguous.
    if ((_transferredCourse ?? '').isNotEmpty && (_transferredClass ?? '').isEmpty) {
      _popup(schoolTerm('Transferred Class Required'), schoolTerm('Select the class within the chosen course.'), AppColors.warning);
      return;
    }
    final targetGroup = _effectiveTargetCourse;
    final target = _effectiveTargetClass;
    if (targetGroup == null || targetGroup.isEmpty || target == null || target.isEmpty) {
      _popup(schoolTerm('Transferred Class Required'), schoolTerm('Select the class to transfer the student to.'), AppColors.warning);
      return;
    }
    final currentClass = student['stuclass']?.toString().trim() ?? '';
    final currentGroup = student['courname']?.toString().trim() ?? '';
    if (targetGroup == currentGroup && target == currentClass && !_admTypeChanged) {
      _popup('Nothing Changed',
          isSchool
              ? schoolTerm('Select a different course or class to transfer to.')
              : 'Select a different course, class or admission type to '
                  'transfer to.', AppColors.warning);
      return;
    }
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    final stuId = student['stu_id'] as int;

    // New-course fees: only the ones ticked on the Adjust Fees page (present in
    // _applyAmount). feeamt = new fee, credit = concession; on the demand
    // feeamount=feeamt, conamount=credit, balancedue=feeamt-credit.
    final items = [
      for (final e in _applyAmount.entries)
        if (e.value > 0.004)
          {
            'cf_id': e.key,
            'feeamt': e.value,
            'credit': _applyCredit[e.key] ?? 0,
          },
    ];
    if (items.isEmpty) {
      _popup(schoolTerm('Set the New Course Fees'),
          schoolTerm('Open "Adjust Fees" and enter the fee amounts for the new course before transferring.'),
          AppColors.warning);
      return;
    }

    setState(() => _saving = true);
    try {
      // One atomic RPC: void old demands, generate the new course's demands,
      // apply the carried credit to the ticked fees, and log the transfer.
      final res = await SupabaseService.client.rpc(
        'transfer_course_with_credit',
        params: {
          'p_ins_id': insId,
          'p_stu_id': stuId,
          'p_target_class': target,
          'p_target_course': targetGroup,
          'p_credits': items,
          'p_doc_no': _docNo,
          // The admission type the student becomes. NULL leaves it unchanged,
          // so an older server build (or a blank selection) behaves exactly as
          // it did before this field existed.
          // School has no admission type: always NULL there (server ignores it).
          'p_target_adm_id': isSchool ? null : _transferredAdmId,
          'p_promotion_date': _promotionDate.toIso8601String().split('T').first,
          'p_created_by': auth.userName,
          'p_remarks': _remarksController.text.trim().isEmpty
              ? null
              : _remarksController.text.trim(),
        },
      );
      final map = res is Map ? res : const {};
      final newCount = (map['new_demands'] as num?)?.toInt() ?? 0;
      // Already-paid money is applied HERE, on the Adjust Fees page: Auto-match
      // takes it off the new fees' amounts (the old product's rule), so the
      // server never sees it as credit and its "leftover" is the whole paid
      // amount. Report what this screen applied, and as unused only the paid
      // money that matched no new fee (it was telling the cashier to refund
      // money that had in fact been used).
      final paidUsed = _oldPaidUsed;
      final concession = (map['applied'] as num?)?.toDouble() ?? 0;
      final unused = (_studentPaid - paidUsed).clamp(0, double.infinity);
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(
        'Transferred ${student['stuname']} to $target. $newCount new fee '
        '${newCount == 1 ? 'demand' : 'demands'} raised; '
        '₹${paidUsed.toStringAsFixed(0)} already paid adjusted against the new fees'
        '${concession > 0.5 ? ', ₹${concession.toStringAsFixed(0)} concession' : ''}'
        '${unused > 0.5 ? '. ₹${unused.toStringAsFixed(0)} already paid matched no new fee: refund it separately' : ''}.',
        AppColors.success,
      );
      _newRecord();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _popup('Transfer Not Saved', friendlyError(e), AppColors.error);
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
      _syncAdmTypeFromStudent();
      _transferredCourse = null;
      _transferredClass = null;
      _studentPaid = 0;
      _currentFees = [];
      _newFees = [];
      _applyCredit.clear();
      _applyAmount.clear();
      _creditApplied = false;
      _applyPaid.clear();
      _loadingFees = false;
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
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(title)),
        ]),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Compact screens (the app's common 1366-class laptops) need tighter
    // spacing so the whole form fits the tab without scrolling.
    final width = MediaQuery.of(context).size.width;
    final compact = width <= 1366;
    // Below this the two panels would each be too narrow for a label and its
    // field, so they stack instead.
    final twoUp = width >= 1180;
    final pad = compact ? 14.0 : 20.0;
    final gap = compact ? 10.0 : 14.0;
    final btnGap = compact ? 16.0 : 24.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            decoration: AppUI.card(),
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
                              CardTitleBlock(
                                  icon: 'ranking',
                                  title: 'Student Transfer',
                                  iconSize: (compact ? 18 : 20).toDouble()),
                              SizedBox(height: (compact ? 14 : 20).h),

                              // The two panels sit side by side on a wide
                              // window and stack on a narrow one. Full width
                              // each, a lone field stretched the whole screen.
                              _twoUpPanels(
                                twoUp: twoUp,
                                gap: gap,
                                left: _sectionPanel(
                                title: 'Student Details',
                                icon: 'people',
                                compact: compact,
                                child: Column(children: [
                                  _row2(
                                    _field('Document No.', _readonlyBox(_docNo?.toString() ?? AppText.generated), icon: 'receipt-2'),
                                    _field('Transfer Date', _dateBox(), icon: 'calendar-1'),
                                  ),
                                  SizedBox(height: gap.h),
                                  _row2(
                                    _field(schoolTerm('Course'), _classGroupDropdown(), icon: 'ranking'),
                                    _field(schoolTerm('Class'), _currentClassDropdown(), icon: 'grid-1'),
                                  ),
                                  SizedBox(height: gap.h),
                                  _row2(
                                    _field(
                                      'Name *',
                                      // Always a Row, dropdown last, so picking a
                                      // student keeps the same dropdown element
                                      // (and its focus) -- only the photo appears.
                                      Row(children: [
                                        if (_student != null && _student!.isNotEmpty) ...[
                                          StudentAvatar(
                                            photoUrl: _student!['stuphoto']?.toString(),
                                            name: _student!['stuname']?.toString() ?? '',
                                            size: 44,
                                          ),
                                          SizedBox(width: 10.w),
                                        ],
                                        Expanded(child: _nameDropdown()),
                                      ]),
                                      icon: 'people',
                                    ),
                                    _field(schoolTerm('Register No.'), _admnBox(), icon: 'user-add'),
                                  ),
                                  if (!isSchool) ...[
                                    SizedBox(height: gap.h),
                                    _field('Admission Type', _currentAdmTypeBox(), icon: 'user-tick'),
                                  ],
                                ]),
                              ),

                              // Section 2 — destination course/class + remarks.
                                right: _sectionPanel(
                                title: 'Transfer To',
                                icon: 'ranking',
                                compact: compact,
                                child: Column(children: [
                                  // Side by side each panel is half as wide, so
                                  // these two stack instead of sharing a row.
                                  if (twoUp) ...[
                                    _field(schoolTerm('Transferred Course'), _transferCourseDropdown(), icon: 'ranking'),
                                    SizedBox(height: gap.h),
                                    _field(schoolTerm('Transferred Class *'), _transferClassDropdown(), icon: 'grid-1'),
                                  ] else
                                    _row2(
                                      _field(schoolTerm('Transferred Course'), _transferCourseDropdown(), icon: 'ranking'),
                                      _field(schoolTerm('Transferred Class *'), _transferClassDropdown(), icon: 'grid-1'),
                                    ),
                                  if (!isSchool) ...[
                                    SizedBox(height: gap.h),
                                    _field('Transferred Admission Type', _transferAdmTypeDropdown(), icon: 'user-tick'),
                                  ],
                                  SizedBox(height: gap.h),
                                  _field('Remarks', TextField(
                                    controller: _remarksController,
                                    onChanged: (_) => setState(() {}),
                                    decoration: _dec(hint: 'Add remarks (optional)', filled: _remarksController.text.trim().isNotEmpty),
                                    style: _valueStyle(_remarksController.text.trim().isNotEmpty),
                                  ), icon: 'receipt-edit'),
                                ]),
                              ),
                              ),
                              SizedBox(height: gap.h),

                              // Fee adjustment — carry the old paid amount onto
                              // the fees the student is moving to. Shown as soon
                              // as ANYTHING changes: a new class, or just a new
                              // admission type within the same class (the fees
                              // differ by quota, so that alone needs adjusting).
                              if (_student != null && _hasTargetChange)
                                _feeAdjustBar(compact),
                              const Spacer(),
                              SizedBox(height: btnGap.h),

                              // Footer action bar.
                              const Divider(height: 1, color: AppColors.divider),
                              SizedBox(height: (compact ? 12 : 16).h),
                              Row(children: [
                                if (_student != null)
                                  Text('Transferring ${_student!['stuname'] ?? ''}',
                                      style: AppUI.muted.copyWith(fontWeight: FontWeight.w600)),
                                const Spacer(),
                                AppUI.requiredNote(),
                                SizedBox(width: 16.w),
                                OutlinedButton.icon(
                                  onPressed: _saving ? null : _resetForm,
                                  icon: const Icon(Icons.refresh, size: 16),
                                  label: const Text(AppText.clear),
                                ),
                                SizedBox(width: 12.w),
                                ElevatedButton.icon(
                                  onPressed: (_saving || _student == null) ? null : _save,
                                  icon: _saving
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : const AppIcon('ranking', size: 16, color: Colors.white),
                                  label: Text(_saving ? 'Saving…' : 'Save Transfer'),
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

  /// Clear the whole form back to a blank Course Transfer.
  void _resetForm() {
    setState(() {
      _classGroup = null;
      _currentClass = null;
      _student = null;
      _syncAdmTypeFromStudent();
      _studentsInClass = [];
      _transferredCourse = null;
      _transferredClass = null;
      _admnController.clear();
      _remarksController.clear();
      _currentFees = [];
      _newFees = [];
      _applyCredit.clear();
      _applyAmount.clear();
      _creditApplied = false;
      _applyPaid.clear();
    });
  }

  /// Two panels across on a wide window, stacked on a narrow one.
  Widget _twoUpPanels({
    required bool twoUp,
    required double gap,
    required Widget left,
    required Widget right,
  }) {
    if (!twoUp) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [left, SizedBox(height: gap.h), right],
      );
    }
    // NO IntrinsicHeight here -- see the same note in Transfer Certificate. It
    // forces the Row to the height Flutter *computes* for its children, which
    // can land a few pixels under what they actually lay out to and show the
    // "BOTTOM OVERFLOWED" stripe. With CrossAxisAlignment.start the panels are
    // not stretched to a common height anyway, so it bought nothing.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        SizedBox(width: gap.w),
        Expanded(child: right),
      ],
    );
  }

  Widget _row2(Widget a, Widget b) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Expanded(child: a), SizedBox(width: 16.w), Expanded(child: b)],
      );

  /// Both the panel and the field label now come from
  /// [FormSectionPanel] / [FormFieldLabel] so this screen and Transfer
  /// Certificate render identically. These thin wrappers keep the call sites
  /// below unchanged.
  Widget _sectionPanel({required String title, required String icon, required bool compact, required Widget child}) =>
      FormSectionPanel(title: title, icon: icon, compact: compact, child: child);

  Widget _field(String label, Widget child, {String? icon}) =>
      FormFieldLabel(label: label, icon: icon, child: child);

  /// Shown when the selected student has unrefunded paid fees — promotion is
  /// blocked until a Fee Refund brings the paid amount back to 0.
  Widget _readonlyBox(String text) => Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
        constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Text(text, style: AppUI.fieldText(context)),
      );

  Widget _classGroupDropdown() {
    final has = _courseNames.contains(_classGroup);
    return AppDropdownField<String>(
        initialValue: has ? _classGroup : null,
        isExpanded: true,
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 6,
        icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
        style: AppUI.fieldText(context),
        decoration: _dec(hint: schoolTerm('Select course'), filled: has),
        items: _courseNames.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
        selectedItemBuilder: (context) => _courseNames
            .map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: _valueStyle(true))))
            .toList(),
        onChanged: (v) => setState(() {
          _classGroup = v;
          _currentClass = null;
          _studentsInClass = [];
          _student = null;
          _syncAdmTypeFromStudent();
          _transferredCourse = null;
          _transferredClass = null;
          _admnController.clear();
        }),
      );
  }

  Widget _currentClassDropdown() {
    final options = _classNamesForCourse(_classGroup);
    final has = options.contains(_currentClass);
    return AppDropdownField<String>(
      initialValue: has ? _currentClass : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      style: AppUI.fieldText(context),
      decoration: _dec(hint: schoolTerm('Select class'), filled: has),
      items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      selectedItemBuilder: (context) => options
          .map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: _valueStyle(true))))
          .toList(),
      onChanged: _classGroup == null
          ? null
          : (v) {
              setState(() {
                _currentClass = v;
                _student = null;
                _syncAdmTypeFromStudent();
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
    return AppDropdownField<int>(
      initialValue: value,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      style: AppUI.fieldText(context),
      decoration: _dec(hint: _loadingStudents ? 'Loading…' : 'Select student', filled: value != null),
      items: _studentsInClass
          .map((s) => DropdownMenuItem(
                value: s['stu_id'] as int,
                child: Text('${s['stuname'] ?? ''} (${s['stuadmno'] ?? ''})', overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      selectedItemBuilder: (context) => _studentsInClass
          .map((s) => Align(alignment: Alignment.centerLeft, child: Text('${s['stuname'] ?? ''} (${s['stuadmno'] ?? ''})', overflow: TextOverflow.ellipsis, style: _valueStyle(true))))
          .toList(),
      onChanged: (_currentClass == null || _studentsInClass.isEmpty)
          ? null
          : (v) => setState(() {
                _student = _studentsInClass.firstWhere((s) => s['stu_id'] == v, orElse: () => {});
                _syncAdmTypeFromStudent();
                _admnController.text = _student?['stuadmno']?.toString() ?? '';
                _transferredCourse = null;
                _transferredClass = null;
              }),
    );
  }

  Widget _admnBox() {
    final has = _admnController.text.trim().isNotEmpty;
    return TextField(
      controller: _admnController,
      onChanged: (_) => setState(() {}),
      decoration: _dec(hint: schoolTerm('Enter register no. and press Enter'), filled: has).copyWith(
        suffixIcon: _looking
            ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(icon: const Icon(Icons.search, size: 18), onPressed: _lookupByAdmn),
      ),
      style: _valueStyle(has),
      // Exact lookup only (Enter or the search icon) — no per-keystroke
      // typeahead. Use the Name dropdown to pick from a list.
      onSubmitted: (_) => _lookupByAdmn(),
    );
  }


  Widget _dateBox() => InkWell(
        onTap: _pickDate,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        child: InputDecorator(
          decoration: _dec(filled: true).copyWith(
            suffixIcon: const Icon(Icons.calendar_today, size: 16, color: AppColors.primary),
          ),
          child: Text(
            formatDmy(_promotionDate),
            style: _valueStyle(true),
          ),
        ),
      );

  // ─── Course-transfer fee adjustment ────────────────────────────────────────

  /// Inline summary + "Adjust Fees" button. The fee grid itself is edited on a
  /// full page ([FeeAdjustPage]) so its scrollable lists get real height — the
  /// form body here sits inside an IntrinsicHeight that can't measure a lazy
  /// ListView.
  Widget _feeAdjustBar(bool compact) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(spacing: 24.w, runSpacing: 6.h, children: [
              _sumChip('Previously Paid', _studentPaid, AppColors.textPrimary),
              _sumChip(schoolTerm('New Course Total'), _newCourseTotal, AppColors.textPrimary),
              _sumChip('Previously Paid Adjusted', _oldPaidUsed, AppColors.success),
              _sumChip('Concession', _appliedTotal, AppColors.warning),
              _sumChip('To Be Paid', _toBePaid, AppColors.error),
            ]),
          ),
          SizedBox(width: 14.w),
          OutlinedButton.icon(
            onPressed: _loadingFees ? null : _openFeeAdjust,
            icon: _loadingFees
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary))
                : const Icon(Icons.tune, size: 18),
            label: Text(_loadingFees ? 'Loading…' : 'Adjust Fees'),
            style: AppUI.secondary(context),
          ),
        ],
      ),
    );
  }

  /// Open the fee structure on its own page; apply the returned credit map.
  Future<void> _openFeeAdjust() async {
    final student = _student;
    final target = _effectiveTargetClass;
    if (student == null || target == null) return;
    if (_newFees.isEmpty) {
      _snack(schoolTerm('No fee structure found for $target. Define its class fees first.'),
          AppColors.warning);
      return;
    }
    final result =
        await Navigator.of(context).push<Map<String, Map<int, double>>>(
      MaterialPageRoute(
        builder: (_) => FeeAdjustPage(
          studentName: student['stuname']?.toString() ?? '',
          currentClass: student['stuclass']?.toString() ?? '',
          targetClass: target,
          currentAdmName: _currentAdmName,
          targetAdmName: _transferredAdmName ?? _currentAdmName,
          studentPaid: _studentPaid,
          currentFees: _currentFees,
          newFees: _newFees,
          initialCredits: Map<int, double>.from(_applyCredit),
          initialAmounts: Map<int, double>.from(_applyAmount),
          locked: _creditApplied,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.containsKey('reset')) {
      // Start the adjustment over from the untouched class-fee amounts.
      setState(() {
        _applyCredit.clear();
        _applyAmount.clear();
        _applyPaid.clear();
        _creditApplied = false;
      });
      _openFeeAdjust();      // straight back in, editable
      return;
    }
    setState(() {
      _applyCredit
        ..clear()
        ..addAll(result['credits'] ?? {});
      _applyAmount
        ..clear()
        ..addAll(result['amounts'] ?? {});
      _applyPaid
        ..clear()
        ..addAll(result['paid'] ?? {});
      _creditApplied = true;
    });
  }

  Widget _sumChip(String label, double value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppUI.muted.copyWith(fontWeight: FontWeight.w600)),
        Text('₹ ${value.toStringAsFixed(0)}',
            style: TextStyle(
                fontSize: 15.sp, fontWeight: FontWeight.w800, color: color)),
      ],
    );
  }

  Widget _transferCourseDropdown() {
    final has = _courseNames.contains(_transferredCourse);
    return AppDropdownField<String>(
      initialValue: has ? _transferredCourse : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      style: AppUI.fieldText(context),
      decoration: _dec(hint: schoolTerm('Select course'), filled: has),
      items: _courseNames.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      selectedItemBuilder: (context) => _courseNames
          .map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: _valueStyle(true))))
          .toList(),
      onChanged: _student == null
          ? null
          : (v) => setState(() {
                _transferredCourse = v;
                _transferredClass = null;
              }),
    );
  }

  // Current Admission Type — read-only. It is a property of the selected
  // student, not a filter, so it is rendered as a disabled field rather than a
  // dropdown: showing it lets the admin see what is about to change.
  Widget _currentAdmTypeBox() {
    final v = _currentAdmName;
    final has = v != null && v.isNotEmpty;
    return TextField(
      key: ValueKey('curAdm_${v ?? ''}'),
      controller: TextEditingController(text: has ? v : ''),
      enabled: false,
      decoration: _dec(
        hint: _student == null ? 'Select a student' : 'Not set',
        filled: has,
      ),
      style: _valueStyle(has),
    );
  }

  // Transferred Admission Type — the type the student becomes. Drives which of
  // the target class's fees load, and is written onto the student on save.
  Widget _transferAdmTypeDropdown() {
    final options = _admTypeNames;
    final has = options.contains(_transferredAdmName);
    return AppDropdownField<String>(
      initialValue: has ? _transferredAdmName : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      style: AppUI.fieldText(context),
      decoration: _dec(hint: 'Select admission type', filled: has),
      items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      selectedItemBuilder: (context) => options
          .map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: _valueStyle(true))))
          .toList(),
      onChanged: _student == null
          ? null
          : (v) {
              setState(() => _transferredAdmName = v);
              // The fee grid is selected by admission type, so changing it has
              // to re-run the load — otherwise the admin would allocate credit
              // against the previous type's fees.
              _loadTransferFees();
            },
    );
  }

  // Transferred Class — a class within the chosen Transferred Course.
  Widget _transferClassDropdown() {
    final options = _classNamesForCourse(_transferredCourse);
    final has = options.contains(_transferredClass);
    return AppDropdownField<String>(
      initialValue: has ? _transferredClass : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      style: AppUI.fieldText(context),
      decoration: _dec(hint: schoolTerm('Select class'), filled: has),
      items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))).toList(),
      selectedItemBuilder: (context) => options
          .map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: _valueStyle(true))))
          .toList(),
      onChanged: (_student == null || _transferredCourse == null)
          ? null
          : (v) {
              setState(() => _transferredClass = v);
              _loadTransferFees();
            },
    );
  }

  // The shared AppUI field: filled fields get the accent edge (and the value
  // text turns accent) so a completed field reads as "set" at a glance.
  InputDecoration _dec({String? hint, bool filled = false}) =>
      AppUI.field(context, hint ?? '', filled: filled);

  /// Value text style (AppUI.fieldText): accent when the field is filled.
  TextStyle _valueStyle(bool filled) => AppUI.fieldText(context, filled: filled);
}

/// Full-page fee-structure adjustment for an Interim Promotion → Course
/// Transfer, ported from the legacy VB frmClassTransfer. Shows the current
/// course's paid fees alongside the new course's fees (typed per student, since
/// college classfeedemand is 0). Each new fee has a Fee Amount, a Concession
/// (Auto-match fills it from the same fee's old paid + old concession; editable
/// across fee types), and Balance = Fee − Concession; a checkbox includes/excludes
/// the fee. On the demand: feeamount=Fee, conamount=Concession, balancedue=Fee−Con.
/// Pops {'amounts','credits'} for the ticked fees on Apply, or null on Cancel.
class FeeAdjustPage extends StatefulWidget {
  final String studentName;
  final String currentClass;
  final String targetClass;
  /// Admission type on each side. Shown in the panel headers because the fee
  /// list on the right is SELECTED by the target type -- without it on screen
  /// two different fee sets look identical, and there is no way to tell which
  /// one you are allocating credit against.
  final String? currentAdmName;
  final String? targetAdmName;
  final double studentPaid;
  final List<Map<String, dynamic>> currentFees;
  final List<Map<String, dynamic>> newFees;
  final Map<int, double> initialCredits;
  final Map<int, double> initialAmounts;
  /// True once Apply Credit has been pressed for this student. Apply returns
  /// the NET fee (fee - matched old paid), so reopening editable would treat
  /// that net as the gross and Auto-match would subtract the old paid a SECOND
  /// time. Locked = view only, with Reset to start the adjustment over.
  final bool locked;

  const FeeAdjustPage({
    super.key,
    required this.studentName,
    required this.currentClass,
    required this.targetClass,
    this.currentAdmName,
    this.targetAdmName,
    required this.studentPaid,
    required this.currentFees,
    required this.newFees,
    required this.initialCredits,
    required this.initialAmounts,
    this.locked = false,
  });

  @override
  State<FeeAdjustPage> createState() => _FeeAdjustPageState();
}

class _FeeAdjustPageState extends State<FeeAdjustPage> {
  // Full typed new-course fee. The visible Fee Amount = this − matched old paid
  // (VB col8 -= paid), and that net is what lands on feedemand.feeamount.
  late final Map<int, double> _amounts;
  // Matched old PAID per fee (reduces the Fee Amount, VB col8 -= paid).
  late final Map<int, double> _paid;
  // Concession per fee (old CONCESSION carried by Auto-match + any manual amount,
  // editable across fee types) -> feedemand.conamount.
  // Balance = (Fee Amount − old paid) − Concession -> feedemand.balancedue.
  late final Map<int, double> _credits;
  // Fees the admin has UNchecked (excluded from the transfer). A fee is included
  // when it has an amount and isn't excluded (checkbox = include this fee).
  final Set<int> _excluded = {};
  final Map<int, TextEditingController> _feeCtrls = {};
  final Map<int, TextEditingController> _conCtrls = {};
  // Cached display order (amount>0 first). Recomputed only at stable points
  // (init / Auto-match / Clear), NOT on each keystroke — otherwise typing the
  // first digit reorders the list and steals focus from the field.
  late List<Map<String, dynamic>> _ordered;

  double _amtOf(int cfId) => _amounts[cfId] ?? 0;
  double _paidOf(int cfId) => _paid[cfId] ?? 0;
  // Fee Amount shown/saved = new fee − old paid.
  double _netFee(int cfId) =>
      (_amtOf(cfId) - _paidOf(cfId)).clamp(0, double.infinity).toDouble();
  double _conOf(int cfId) => _credits[cfId] ?? 0;
  double _balanceOf(int cfId) =>
      (_netFee(cfId) - _conOf(cfId)).clamp(0, double.infinity).toDouble();
  bool _included(int cfId) =>
      _amtOf(cfId) > 0.004 && !_excluded.contains(cfId);

  double _inc(int cfId, double v) => _included(cfId) ? v : 0;
  double get _paidApplied => widget.newFees.fold(0.0,
      (s, f) => s + _inc((f['cf_id'] as num).toInt(), _paidOf((f['cf_id'] as num).toInt())));
  double get _conTotal => widget.newFees.fold(0.0,
      (s, f) => s + _inc((f['cf_id'] as num).toInt(), _conOf((f['cf_id'] as num).toInt())));
  double get _newTotal => widget.newFees.fold(0.0,
      (s, f) => s + _inc((f['cf_id'] as num).toInt(), _amtOf((f['cf_id'] as num).toInt())));
  double get _toBePaid => widget.newFees.fold(0.0,
      (s, f) => s + _inc((f['cf_id'] as num).toInt(), _balanceOf((f['cf_id'] as num).toInt())));

  @override
  void initState() {
    super.initState();
    _amounts = {};
    _paid = {};
    _credits = Map<int, double>.from(widget.initialCredits);
    for (final f in widget.newFees) {
      final cfId = (f['cf_id'] as num).toInt();
      final a = widget.initialAmounts[cfId] ??
          (f['cfamount'] as num?)?.toDouble() ??
          0;
      _amounts[cfId] = a;
      _feeCtrls[cfId] =
          TextEditingController(text: a > 0 ? a.toStringAsFixed(0) : '');
      final c = _credits[cfId] ?? 0;
      _conCtrls[cfId] =
          TextEditingController(text: c > 0 ? c.toStringAsFixed(0) : '');
    }
    _ordered = _orderedNewFees();
  }

  @override
  void dispose() {
    for (final c in _feeCtrls.values) {
      c.dispose();
    }
    for (final c in _conCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // Match key: fee type + semester (mirrors the VB match on term + fee).
  String _type(dynamic type) => (type ?? '').toString().trim().toUpperCase();

  String _key(dynamic type, dynamic term) =>
      '${(type ?? '').toString().trim().toUpperCase()}'
      '|${(term ?? '').toString().trim().toUpperCase()}';

  // Fee Amount edited: it redefines the fee, so drop the matched old paid (the
  // field now shows the raw typed value); keep the concession within the net.
  void _onFeeChanged(int cfId, String raw) {
    final a = double.tryParse(raw.trim()) ?? 0;
    setState(() {
      _amounts[cfId] = a < 0 ? 0 : a;
      _paid.remove(cfId);
      final net = _netFee(cfId);
      final c = _credits[cfId];
      if (c != null && c > net) {
        if (net <= 0.004) {
          _credits.remove(cfId);
          _conCtrls[cfId]?.text = '';
        } else {
          _credits[cfId] = net;
          _conCtrls[cfId]?.text = net.toStringAsFixed(0);
        }
      }
    });
  }

  // Concession edited directly (manual, cross-fee-type); capped at the net fee.
  void _onConChanged(int cfId, String raw) {
    final v = double.tryParse(raw.trim()) ?? 0;
    final cap = _netFee(cfId);
    final val = v < 0 ? 0.0 : (v > cap ? cap : v);
    setState(() {
      if (val <= 0.004) {
        _credits.remove(cfId);
      } else {
        _credits[cfId] = val;
      }
    });
    if ((val - v).abs() > 0.001) {
      final c = _conCtrls[cfId]!;
      c.text = val > 0 ? val.toStringAsFixed(0) : '';
      c.selection = TextSelection.collapsed(offset: c.text.length);
    }
  }

  // Mirrors the VB CmdTrans exactly: for each new fee, find the same
  // type+semester old fee; when the new fee amount >= that fee's PAID, reduce the
  // new Fee Amount by the paid (feeamount = new fee − old paid, VB col8 -= paid).
  // If the new fee is smaller than the paid, VB leaves it (that paid is unused).
  // Concession is NOT touched here — it stays manual (the VB form has none).
  void _autoFill() {
    var matched = 0;
    var unusedPaid = 0.0;
    setState(() {
      _paid.clear();
      final remainPaid = <int, double>{};
      for (var j = 0; j < widget.currentFees.length; j++) {
        remainPaid[j] =
            (widget.currentFees[j]['paidamount'] as num?)?.toDouble() ?? 0;
      }
      // Two passes. First match on fee type AND term, then on fee type alone
      // for whatever old paid is left: a course transfer usually lands the
      // student in a different semester, so requiring the term to match as well
      // left most fees uncredited (old FINE VII SEM vs new FINE VIII SEM).
      for (final exactTerm in [true, false]) {
        for (final f in widget.newFees) {
          final cfId = (f['cf_id'] as num).toInt();
          final amt = _amtOf(cfId);
          if (amt <= 0) continue;
          // Never credit a fee more than its own amount.
          var room = amt - (_paid[cfId] ?? 0);
          if (room <= 0.004) continue;
          final nType = _type(f['cffeetype']);
          final nKey = _key(f['cffeetype'], f['cfterm']);
          for (var j = 0; j < widget.currentFees.length; j++) {
            final avail = remainPaid[j] ?? 0;
            if (avail <= 0.004) continue;
            final cur = widget.currentFees[j];
            if (exactTerm) {
              if (_key(cur['demfeetype'], cur['demfeeterm']) != nKey) continue;
            } else {
              if (_type(cur['demfeetype']) != nType) continue;
            }
            // Take as much as fits — the old code only matched when the new fee
            // was >= the old paid, so a smaller new fee got NO credit at all.
            final take = room < avail ? room : avail;
            _paid[cfId] = (_paid[cfId] ?? 0) + take;
            remainPaid[j] = avail - take;
            room -= take;
            if (room <= 0.004) break;
          }
        }
      }
      matched = _paid.values.where((v) => v > 0.004).length;
      for (final f in widget.newFees) {
        final id = (f['cf_id'] as num).toInt();
        _feeCtrls[id]?.text = _netFee(id) > 0
            ? _netFee(id).toStringAsFixed(0)
            : (_amtOf(id) > 0 ? '0' : '');
      }
      unusedPaid = remainPaid.values.fold(0.0, (s, v) => s + v);
      _ordered = _orderedNewFees();
    });
    final msg = _paidApplied <= 0.004
        ? (_newTotal <= 0.004
            ? schoolTerm('Enter the new course fee amounts first, then press Auto-match.')
            : schoolTerm('No fees matched. The new course has no fee of the same type that was already paid.'))
        : '₹${_paidApplied.toStringAsFixed(0)} already paid was adjusted against $matched ${matched == 1 ? 'fee' : 'fees'}.'
            '${unusedPaid > 0.5 ? ' ₹${unusedPaid.toStringAsFixed(0)} could not be adjusted and should be refunded.' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: _paidApplied > 0.004 ? AppColors.success : AppColors.warning,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _clearAll() {
    setState(() {
      _paid.clear();
      _credits.clear();
      for (final f in widget.newFees) {
        final id = (f['cf_id'] as num).toInt();
        _feeCtrls[id]?.text =
            _amtOf(id) > 0 ? _amtOf(id).toStringAsFixed(0) : '';
        _conCtrls[id]?.text = '';
      }
      _ordered = _orderedNewFees();
    });
  }

  // Show fees with a typed amount first, otherwise keep the fee-defined
  // order (classfeedemand cf_id = the order the class fees were defined).
  List<Map<String, dynamic>> _orderedNewFees() {
    final list = List<Map<String, dynamic>>.from(widget.newFees);
    list.sort((a, b) {
      final ca = (a['cf_id'] as num).toInt();
      final cb = (b['cf_id'] as num).toInt();
      final pa = _amtOf(ca) > 0.004 ? 0 : 1;
      final pb = _amtOf(cb) > 0.004 ? 0 : 1;
      return pa != pb ? pa - pb : ca.compareTo(cb);
    });
    return list;
  }

  void _toggleInclude(int cfId) {
    if (widget.locked) return;   // view-only after Apply Credit
    if (_amtOf(cfId) <= 0.004) return;
    setState(() {
      if (_excluded.contains(cfId)) {
        _excluded.remove(cfId);
      } else {
        _excluded.add(cfId);
      }
    });
  }

  // Compact right-aligned numeric field shared by the Fee Amount / Concession cells.
  Widget _numField(TextEditingController? ctrl, void Function(String) onCh,
      {Color? color}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 8.w),
      child: SizedBox(
        height: 36,
        child: TextField(
          controller: ctrl,
          enabled: !widget.locked,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.right,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: AppUI.fieldText(context).copyWith(color: color),
          decoration: AppUI.field(context, '0', dense: true).copyWith(
            contentPadding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 8),
          ),
          onChanged: onCh,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        surfaceTintColor: Colors.white,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.cardBorder)),
        title: Text('Adjust Fees — ${widget.studentName}', style: AppUI.cardTitle),
      ),
      body: Padding(
        padding: EdgeInsets.all(AppUI.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _summaryStrip(),
            SizedBox(height: AppUI.gap),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _currentCard()),
                  SizedBox(width: AppUI.gap),
                  Expanded(flex: 1, child: _newCard()),
                ],
              ),
            ),
            SizedBox(height: AppUI.gap),
            Row(
              children: [
                if (widget.locked)
                  Expanded(
                    child: Text(
                      'Credit already applied. These amounts are the fees after the '
                      'previously paid amount was deducted. Use Clear and Adjust Again to change them.',
                      style: AppUI.muted,
                    ),
                  )
                else
                  const Spacer(),
                if (widget.locked) ...[
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pop(<String, Map<int, double>>{'reset': <int, double>{}}),
                    icon: const Icon(Icons.refresh, size: 18),
                    style: AppUI.secondary(context).copyWith(
                      foregroundColor: const WidgetStatePropertyAll(AppColors.error),
                      side: const WidgetStatePropertyAll(BorderSide(color: AppColors.error)),
                    ),
                    label: const Text('Clear and Adjust Again'),
                  ),
                  SizedBox(width: 12.w),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ] else ...[
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                SizedBox(width: 12.w),
                ElevatedButton.icon(
                  onPressed: () {
                    // Return only the fees that are ticked for transfer.
                    final amounts = <int, double>{};
                    final credits = <int, double>{};
                    final paid = <int, double>{};
                    for (final f in widget.newFees) {
                      final id = (f['cf_id'] as num).toInt();
                      if (!_included(id)) continue;
                      // feeamount = new fee − old paid (VB col8 -= paid).
                      amounts[id] = _netFee(id);
                      final c = _conOf(id);
                      if (c > 0.004) credits[id] = c;
                      final p = _paidOf(id);
                      if (p > 0.004) paid[id] = p;
                    }
                    Navigator.of(context).pop(<String, Map<int, double>>{
                      'amounts': amounts,
                      'credits': credits,
                      'paid': paid,
                    });
                  },
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Apply Credit'),
                ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryStrip() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Wrap(spacing: 28.w, runSpacing: 8.h, children: [
        _chip('Previously Paid', widget.studentPaid, AppColors.textPrimary),
        _chip(schoolTerm('New Course Total'), _newTotal, AppColors.textPrimary),
        _chip('Previously Paid Adjusted', _paidApplied, AppColors.success),
        _chip('Concession', _conTotal, AppColors.warning),
        _chip('To Be Paid', _toBePaid, AppColors.error),
      ]),
    );
  }

  Widget _chip(String label, double value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppUI.muted.copyWith(fontWeight: FontWeight.w600)),
        Text('₹ ${value.toStringAsFixed(0)}',
            style: TextStyle(
                fontSize: 16.sp, fontWeight: FontWeight.w800, color: color)),
      ],
    );
  }

  Widget _cardShell(String title, Color titleColor, Widget child) {
    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 14.h),
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppUI.label.copyWith(fontSize: 15.sp, fontWeight: FontWeight.w800, color: titleColor)),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _hcell(String text, {int flex = 1, TextAlign align = TextAlign.left}) {
    return Expanded(
      flex: flex,
      child: Text(text.toUpperCase(),
          textAlign: align,
          style: AppUI.tableHead),
    );
  }

  Widget _currentCard() {
    return _cardShell(
      'Current — ${widget.currentClass}'
      '${(widget.currentAdmName ?? '').isEmpty ? '' : ' · ${widget.currentAdmName}'}'
      '  (Paid ₹${widget.studentPaid.toStringAsFixed(0)})',
      AppColors.textSecondary,
      Column(
        children: [
          Container(
            decoration: AppUI.tableHeadBar,
            padding: EdgeInsets.fromLTRB(12.w, 10.h, 12.w, 10.h),
            child: Row(children: [
              _hcell('Fee Type', flex: 3),
              _hcell(schoolTerm('Semester'), flex: 2),
              _hcell('Fee Amount', flex: 2, align: TextAlign.right),
              _hcell('Concession', flex: 2, align: TextAlign.right),
              _hcell('Paid', flex: 2, align: TextAlign.right),
              _hcell('Balance', flex: 2, align: TextAlign.right),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: widget.currentFees.isEmpty
                ? AppUI.empty(
                    title: schoolTerm('No dues on the current course.'),
                    why: schoolTerm('No fee demand is raised for this student on the current course.'),
                    icon: 'receipt-2')
                : ListView.separated(
                    padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
                    itemCount: widget.currentFees.length,
                    separatorBuilder: (_, __) => SizedBox(height: 2.h),
                    itemBuilder: (_, i) {
                      final f = widget.currentFees[i];
                      return Padding(
                        padding: EdgeInsets.symmetric(vertical: 5.h),
                        child: Row(children: [
                          Expanded(
                              flex: 3,
                              child: Text('${f['demfeetype'] ?? ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppUI.cell)),
                          Expanded(
                              flex: 2,
                              child: Text('${f['demfeeterm'] ?? ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
                          Expanded(
                              flex: 2,
                              child: Text(
                                  ((f['feeamount'] as num?)?.toDouble() ?? 0)
                                      .toStringAsFixed(0),
                                  textAlign: TextAlign.right,
                                  style: AppUI.money)),
                          Expanded(
                              flex: 2,
                              child: Text(
                                  ((f['conamount'] as num?)?.toDouble() ?? 0)
                                      .toStringAsFixed(0),
                                  textAlign: TextAlign.right,
                                  style: AppUI.money.copyWith(color: AppColors.textSecondary))),
                          Expanded(
                              flex: 2,
                              child: Text(
                                  ((f['paidamount'] as num?)?.toDouble() ?? 0)
                                      .toStringAsFixed(0),
                                  textAlign: TextAlign.right,
                                  style: AppUI.money.copyWith(color: AppColors.success))),
                          Expanded(
                              flex: 2,
                              child: Text(
                                  ((f['balancedue'] as num?)?.toDouble() ?? 0)
                                      .toStringAsFixed(0),
                                  textAlign: TextAlign.right,
                                  style: AppUI.money.copyWith(color: AppColors.error))),
                        ]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _newCard() {
    return _cardShell(
      'New — ${widget.targetClass}'
      '${(widget.targetAdmName ?? '').isEmpty ? '' : ' · ${widget.targetAdmName}'}'
      '  (enter fees, then press Auto-match)',
      AppColors.primary,
      Column(
        children: [
          // Prominent per-fee match action (mirrors the VB "Trans" step):
          // type the new fees, then reduce each by the matching old paid.
          Padding(
            padding: EdgeInsets.fromLTRB(12.w, 8.h, 12.w, 2.h),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '1) Type each fee  2) Auto-match fills Concession from the same fee already paid  3) Balance = Fee − Concession',
                    style: AppUI.muted,
                  ),
                ),
                SizedBox(width: 8.w),
                ElevatedButton.icon(
                  onPressed: widget.locked ? null : _autoFill,
                  icon: const Icon(Icons.bolt, size: 16),
                  label: const Text('Auto-match'),
                ),
                SizedBox(width: 8.w),
                ElevatedButton.icon(
                  onPressed: widget.locked ? null : _clearAll,
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text('Clear'),
                ),
              ],
            ),
          ),
          Container(
            decoration: AppUI.tableHeadBar,
            padding: EdgeInsets.fromLTRB(12.w, 10.h, 12.w, 10.h),
            child: Row(children: [
              SizedBox(width: 26.w),
              _hcell('Fee Type', flex: 4),
              _hcell(schoolTerm('Semester'), flex: 2),
              _hcell('Fee Amount', flex: 3, align: TextAlign.right),
              _hcell('Concession', flex: 3, align: TextAlign.right),
              _hcell('Balance', flex: 2, align: TextAlign.right),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: Builder(builder: (_) {
              final ordered = _ordered;
              return ListView.separated(
              padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h),
              itemCount: ordered.length,
              separatorBuilder: (_, __) => SizedBox(height: 2.h),
              itemBuilder: (_, i) {
                final f = ordered[i];
                final cfId = (f['cf_id'] as num).toInt();
                final bal = _balanceOf(cfId);
                final has = _amtOf(cfId) > 0.004;
                final inc = _included(cfId);
                return Padding(
                  key: ValueKey(cfId),
                  padding:
                      EdgeInsets.symmetric(vertical: 3.h, horizontal: 4.w),
                  child: Row(children: [
                    // Include-in-transfer checkbox (VB "App" column).
                    SizedBox(
                      width: 26.w,
                      child: InkWell(
                        onTap: has ? () => _toggleInclude(cfId) : null,
                        child: Icon(
                            inc
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            size: 20,
                            color: !has
                                ? AppColors.border
                                : (inc
                                    ? AppColors.primary
                                    : AppColors.textLight)),
                      ),
                    ),
                    Expanded(
                        flex: 4,
                        child: Text('${f['cffeetype'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppUI.cell)),
                    Expanded(
                        flex: 2,
                        child: Text('${f['cfterm'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
                    // Fee Amount (editable) -> feedemand.feeamount.
                    Expanded(
                        flex: 3,
                        child: _numField(_feeCtrls[cfId],
                            (v) => _onFeeChanged(cfId, v))),
                    // Concession (editable, cross-fee-type) -> feedemand.conamount.
                    Expanded(
                        flex: 3,
                        child: _numField(_conCtrls[cfId],
                            (v) => _onConChanged(cfId, v),
                            color: AppColors.success)),
                    // Balance = Fee Amount − Concession -> feedemand.balancedue.
                    Expanded(
                        flex: 2,
                        child: Text(bal.toStringAsFixed(0),
                            textAlign: TextAlign.right,
                            style: AppUI.money.copyWith(
                                color: bal > 0
                                    ? AppColors.error
                                    : AppColors.success))),
                  ]),
                );
              },
            );
            }),
          ),
        ],
      ),
    );
  }
}
