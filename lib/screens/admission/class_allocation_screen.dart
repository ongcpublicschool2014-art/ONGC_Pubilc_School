import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../services/admission_service.dart';
import '../../models/admission_model.dart';
import '../../widgets/app_icon.dart';

/// Class Allocation — batch-allocate admitted (PENDING) admissions into classes.
/// Pick a course, assign each student a class via the grid, then Save to move
/// them all into students/parents/parentdetail at once.
class ClassAllocationScreen extends StatefulWidget {
  const ClassAllocationScreen({super.key});

  @override
  State<ClassAllocationScreen> createState() => _ClassAllocationScreenState();
}

class _ClassAllocationScreenState extends State<ClassAllocationScreen> {
  List<AdmissionModel> _pending = [];
  List<Map<String, dynamic>> _courseList = []; // {cour_id, courname}
  List<Map<String, dynamic>> _classList = [];  // {claname, cour_id}

  String? _selectedCourse;
  String _orderBy = 'Admission No';
  final Map<int, String?> _rowClass = {}; // adm_id -> chosen class
  bool _loading = true;
  bool _saving = false;

  static const _orderOptions = ['Admission No', 'Student Name', 'Gender + Student Name'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    final insId = _insId;
    try {
      final results = await Future.wait<dynamic>([
        AdmissionService.getAdmissions(insId),
        SupabaseService.fromSchema('course').select('cour_id, courname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
      ]);
      if (!mounted) return;
      setState(() {
        _pending = (results[0] as List<AdmissionModel>).where((a) => a.isPending).toList();
        _courseList = List<Map<String, dynamic>>.from(results[1] as List);
        _classList = List<Map<String, dynamic>>.from(results[2] as List);
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Failed to load. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  // ── options ───────────────────────────────────────────────────────
  List<String> get _courseNames =>
      (_courseList.map((e) => e['courname']?.toString().trim() ?? '')
          .where((s) => s.isNotEmpty).toSet().toList()
        ..sort());

  List<String> _classNamesFor(String? courname) {
    Iterable<Map<String, dynamic>> src = _classList;
    if (courname != null && courname.trim().isNotEmpty) {
      final cm = _courseList.firstWhere(
        (c) => (c['courname']?.toString().trim() ?? '') == courname.trim(),
        orElse: () => const {},
      );
      final courId = cm['cour_id'];
      src = courId == null
          ? const <Map<String, dynamic>>[]
          : _classList.where((cl) => cl['cour_id'] == courId);
    }
    return (src.map((e) => e['claname']?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty).toSet().toList()
      ..sort());
  }

  /// Pending admissions for the selected course, sorted by the Order By choice.
  List<AdmissionModel> get _rows {
    if (_selectedCourse == null) return [];
    final list = _pending
        .where((a) => (a.courname?.trim() ?? '') == _selectedCourse)
        .toList();
    list.sort((a, b) {
      switch (_orderBy) {
        case 'Student Name':
          return a.stuname.toLowerCase().compareTo(b.stuname.toLowerCase());
        case 'Gender + Student Name':
          final s = a.stugender.compareTo(b.stugender);
          return s != 0 ? s : a.stuname.toLowerCase().compareTo(b.stuname.toLowerCase());
        default: // Admission No
          return a.admno.compareTo(b.admno);
      }
    });
    return list;
  }

  // ── actions ───────────────────────────────────────────────────────
  /// Pick one class and apply it to every student in the current course filter.
  Future<void> _autoFill() async {
    final options = _classNamesFor(_selectedCourse);
    if (options.isEmpty) {
      _snack('No classes available for $_selectedCourse.', AppColors.warning);
      return;
    }
    String? picked = options.length == 1 ? options.first : null;
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Auto Fill class'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Apply one class to all ${_rows.length} student(s) in $_selectedCourse.',
                  style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
              SizedBox(height: 14.h),
              DropdownButtonFormField<String>(
                initialValue: picked,
                isExpanded: true,
                icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                decoration: const InputDecoration(labelText: 'Class'),
                items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)))).toList(),
                selectedItemBuilder: (context) => options.map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)))).toList(),
                onChanged: (v) => setLocal(() => picked = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () { if (picked != null) Navigator.pop(ctx, picked); },
              child: const Text('Apply to all'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    setState(() {
      for (final a in _rows) {
        _rowClass[a.admId] = chosen;
      }
    });
  }

  Future<void> _save() async {
    final toAllocate = _rows.where((a) => (_rowClass[a.admId] ?? '').isNotEmpty).toList();
    if (toAllocate.isEmpty) {
      _snack('Assign a class to at least one student first.', AppColors.warning);
      return;
    }
    final by = context.read<AuthProvider>().userName;
    setState(() => _saving = true);
    int done = 0;
    final failures = <String>[];
    for (final a in toAllocate) {
      try {
        await AdmissionService.allocateClass(
          admId: a.admId,
          className: _rowClass[a.admId]!,
          stuadmno: a.admno,
          allocatedBy: by,
        );
        done++;
      } catch (e) {
        failures.add('${a.admno} ${a.stuname}: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    _rowClass.clear();
    await _load();
    if (!mounted) return;
    if (failures.isEmpty) {
      _snack('Allocated $done student(s).', AppColors.success);
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Allocated $done, ${failures.length} failed'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [for (final f in failures) Padding(
                  padding: EdgeInsets.only(bottom: 4.h),
                  child: Text('• $f', style: TextStyle(fontSize: 12.sp, color: AppColors.error)),
                )],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  // ── build ─────────────────────────────────────────────────────────
  // Page shell per admission-design.md § 1: edge-to-edge outer card (no
  // Padding(16.w) wrapper). Outer card is white / 16 logical-px radius /
  // AppColors.border.
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            // Outer white card.
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Padding(
              // Padding around all inner content so it doesn't touch the
              // outer card edge.
              padding: EdgeInsets.fromLTRB(16.w, 4.h, 16.w, 12.h),
              child: Column(
                children: [
                  _topBar(),
                  SizedBox(height: 8.h),
                  // Inner bordered table card — header band + body rows.
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        children: [
                          _tableHeader(),
                          Expanded(child: _body()),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 8.h),
                  _actionBar(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Single top bar: icon + "Section Allocation" + subtitle on the left,
  /// pushed-right Standard dropdown + Order By dropdown + navy Auto Fill +
  /// amber "X pending" chip.
  Widget _topBar() {
    // Horizontal padding only — vertical breathing comes from the outer
    // Padding wrapper in build().
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.h),
      child: Row(
        children: [
          const AppIcon('book-1', size: 20, color: AppColors.primary),
          SizedBox(width: 10.w),
          Text('Class Allocation',
              style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(width: 10.w),
          Text('Admitted — pending allocation',
              style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          SizedBox(width: 200.w, child: _courseDropdown()),
          SizedBox(width: 10.w),
          SizedBox(width: 170.w, child: _orderDropdown()),
          SizedBox(width: 10.w),
          // Sized to match the Import CSV/Excel button used elsewhere in the
          // project (compact / expanded responsive).
          Builder(builder: (context) {
            final compact = MediaQuery.of(context).size.width <= 1366;
            final btnHeight = compact ? 30.0 : 40.0;
            final iconSize = compact ? 12.0 : 16.0;
            final hPad = compact ? 10.0 : 18.0;
            final radius = compact ? 6.0 : 10.0;
            final textSize = compact ? 11.0 : 13.0;
            return SizedBox(
              height: btnHeight,
              child: ElevatedButton.icon(
                onPressed: _selectedCourse == null ? null : _autoFill,
                icon: Icon(Icons.auto_fix_high, size: iconSize, color: Colors.white),
                label: const Text('Auto Fill'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: EdgeInsets.symmetric(horizontal: hPad),
                  textStyle: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
                ),
              ),
            );
          }),
          SizedBox(width: 10.w),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Text('${_pending.length} pending',
                style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.warning)),
          ),
        ],
      ),
    );
  }

  Widget _courseDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _selectedCourse,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(filled: _selectedCourse != null),
      hint: Text('Select Course', style: TextStyle(fontSize: 13.sp, color: AppColors.textLight)),
      items: _courseNames.map((e) => DropdownMenuItem(
            value: e,
            child: Text(e, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
          )).toList(),
      selectedItemBuilder: (context) => _courseNames.map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
      onChanged: (v) => setState(() {
        _selectedCourse = v;
        _rowClass.clear();
      }),
    );
  }

  Widget _orderDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _orderBy,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
      decoration: _dec(filled: true, hint: 'Order by'),
      items: _orderOptions.map((e) => DropdownMenuItem(
            value: e,
            child: Text(e, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          )).toList(),
      selectedItemBuilder: (context) => _orderOptions.map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
      onChanged: (v) => setState(() => _orderBy = v ?? 'Admission No'),
    );
  }

  Widget _tableHeader() {
    TextStyle s() => TextStyle(
        fontSize: 12.sp,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: 0.3);
    return Container(
      color: AppColors.tableHeadBg,
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
      child: Row(
        children: [
          SizedBox(width: 140.w, child: Text('REG. NO', style: s())),
          Expanded(flex: 3, child: Text('STUDENT NAME', style: s())),
          SizedBox(width: 80.w, child: Text('GENDER', style: s())),
          Expanded(flex: 2, child: Text('COURSE', style: s())),
          SizedBox(width: 220.w, child: Text('CLASS', style: s())),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_selectedCourse == null) {
      return Center(
        child: Text('Select a standard to list admitted students',
            style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
      );
    }
    final rows = _rows;
    if (rows.isEmpty) {
      return Center(
        child: Text('No pending admissions for $_selectedCourse',
            style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
      );
    }
    final options = _classNamesFor(_selectedCourse);
    return FocusTraversalGroup(
      child: ListView.builder(
        itemCount: rows.length,
        itemBuilder: (_, i) => _row(rows[i], i, options),
      ),
    );
  }

  Widget _row(AdmissionModel a, int index, List<String> options) {
    final cell = TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);
    return Container(
      color: index.isEven ? Colors.white : AppColors.surface,
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
      child: Row(
        children: [
          SizedBox(width: 140.w, child: Text(a.admno, style: cell)),
          Expanded(flex: 3, child: Text(a.stuname, style: cell)),
          SizedBox(width: 80.w, child: Text(a.genderLabel, style: cell)),
          Expanded(flex: 2, child: Text(a.courname ?? '—', style: cell)),
          SizedBox(
            width: 220.w,
            child: DropdownButtonFormField<String>(
              initialValue: options.contains(_rowClass[a.admId]) ? _rowClass[a.admId] : null,
              isExpanded: true,
              isDense: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              decoration: _cellDec(filled: options.contains(_rowClass[a.admId])),
              hint: Text('Select class', style: TextStyle(fontSize: 12.sp, color: AppColors.textLight)),
              items: options.map((e) => DropdownMenuItem(value: e, child: Text(e, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis))).toList(),
              selectedItemBuilder: (context) => options.map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
              onChanged: (v) => setState(() => _rowClass[a.admId] = v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBar() {
    final count = _rows.where((a) => (_rowClass[a.admId] ?? '').isNotEmpty).length;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6.h),
      child: Row(
        children: [
          if (count > 0)
            Text('$count selected for allocation',
                style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _saving || count == 0 ? null : _save,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: Text(_saving ? 'Allocating…' : 'Save Allocation'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }

  // Compact-or-expanded responsive decoration per admission-design.md § 4:
  // isDense off, 14.h vertical padding at expanded sizes, 5/8 radius, focused
  // border in accent. Used by the top-bar dropdowns.
  InputDecoration _dec({bool filled = false, String? hint}) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final hPad = compact ? 10.0 : 14.0;
    final vPad = compact ? 8.0 : 14.0;
    final radius = compact ? 6.0 : 8.0;
    final idle = filled ? AppColors.accent : AppColors.border;
    return InputDecoration(
      contentPadding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      filled: true,
      fillColor: Colors.white,
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: 13.sp),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: idle, width: 1.5)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: idle, width: 1.5)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
    );
  }

  // Compact decoration for inline row dropdowns — keeps body rows tight.
  InputDecoration _cellDec({bool filled = false, String? hint}) {
    final idle = filled ? AppColors.accent : AppColors.border;
    return InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
        filled: true,
        fillColor: Colors.white,
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: 12.sp),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6.r),
            borderSide: BorderSide(color: idle, width: 1.5)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6.r),
            borderSide: BorderSide(color: idle, width: 1.5)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6.r),
            borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
      );
  }
}
