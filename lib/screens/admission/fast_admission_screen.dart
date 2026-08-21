import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../services/admission_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_tap.dart';

/// Fast Admission — spreadsheet-style bulk entry. Each row is a quick admission
/// captured into public.admission (PENDING); allocate classes later in the
/// Class Allocation screen. Supports register-sequence auto-numbering.
class FastAdmissionScreen extends StatefulWidget {
  const FastAdmissionScreen({super.key});

  @override
  State<FastAdmissionScreen> createState() => _FastAdmissionScreenState();
}

class _FastRow {
  final regNo = TextEditingController(); // manual register/admission no (overrides sequence)
  final name = TextEditingController();
  final batch = TextEditingController();
  final fatherName = TextEditingController();
  final fatherMobile = TextEditingController();
  String? sex; // M | F | T
  String? course;
  String? cls;
  String? admType;
  DateTime? dob;
  DateTime admDate = DateTime.now();

  void dispose() {
    regNo.dispose();
    name.dispose();
    batch.dispose();
    fatherName.dispose();
    fatherMobile.dispose();
  }

  bool get isBlank => name.text.trim().isEmpty;
}

class _FastAdmissionScreenState extends State<FastAdmissionScreen> {
  final List<_FastRow> _rows = [];
  List<Map<String, dynamic>> _courseList = []; // {cour_id, courname}
  List<Map<String, dynamic>> _classList = [];  // {claname, cour_id}

  List<String> get _courses =>
      (_courseList.map((e) => e['courname']?.toString().trim() ?? '')
          .where((s) => s.isNotEmpty).toSet().toList()
        ..sort());

  /// Class names belonging to [courname] (matched via class.cour_id). With no
  /// course selected, returns all classes; the Class dropdown is scoped to the
  /// chosen Course.
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
  List<Map<String, dynamic>> _admTypes = [];
  List<Map<String, dynamic>> _years = [];
  List<Map<String, dynamic>> _regSeqs = [];
  String? _selectedYrLabel;
  String? _selectedRegSeqId;
  String? _lastRegNo; // last admission reg no — shown inline next to the label
  bool _loading = true;
  bool _saving = false;

  static const _sexOptions = {'M': 'Male', 'F': 'Female', 'T': 'Other'};

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      if (mounted) _maybeAutoPickSeq();
    });
    _refreshLastRegNo();
  }

  /// When the Utilities admission-number mode is AUTO, auto-select the first
  /// register sequence so blank Register No cells are auto-numbered on save
  /// (no manual sequence pick). No-op if a sequence is already chosen.
  Future<void> _maybeAutoPickSeq() async {
    if (!mounted || _selectedRegSeqId != null || _regSeqs.isEmpty) return;
    final s = await SupabaseService.getInstitutionSettings(_insId);
    if (!mounted || _selectedRegSeqId != null || _regSeqs.isEmpty) return;
    if ((s['admission_number_mode'] ?? 'MANUAL').toUpperCase() == 'AUTO') {
      setState(() => _selectedRegSeqId = _regSeqs.first['seq_id'].toString());
    }
  }

  // Scroll controllers so the entry grid shows visible scrollbars.
  final ScrollController _vScroll = ScrollController();
  final ScrollController _hScroll = ScrollController();

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    _vScroll.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  /// Retry a network call a couple of times with a short backoff so a single
  /// dropped connection (handshake/timeout) self-heals instead of stranding
  /// the screen on the spinner.
  Future<T> _withRetry<T>(Future<T> Function() fn, {int retries = 2}) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await fn();
      } catch (_) {
        if (attempt >= retries) rethrow;
        await Future.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final insId = _insId;
    try {
      final results = await _withRetry(() => Future.wait<dynamic>([
        SupabaseService.fromSchema('course').select('cour_id, courname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.getAdmissionTypes(insId),
        SupabaseService.getYears(insId),
        SupabaseService.fromSchema('sequence').select('*').eq('actname', 'REGNO').eq('activestatus', 1).order('seq_id', ascending: true),
      ]));
      if (!mounted) return;
      setState(() {
        _courseList = List<Map<String, dynamic>>.from(results[0] as List);
        _classList = List<Map<String, dynamic>>.from(results[1] as List);
        _admTypes = List<Map<String, dynamic>>.from(results[2] as List);
        _years = results[3] as List<Map<String, dynamic>>;
        _regSeqs = List<Map<String, dynamic>>.from(results[4] as List);
        if (_years.isNotEmpty) {
          _selectedYrLabel = _years.first['yrlabel']?.toString();
        }
        if (_rows.isEmpty) {
          _rows.add(_FastRow());
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Failed to load. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  void _addRow() => setState(() => _rows.add(_FastRow()));


  int _seqNext(Map<String, dynamic> seq) {
    final cur = (seq['seqcurno'] as num?)?.toInt() ?? 0;
    final start = (seq['seqstart'] as num?)?.toInt() ?? 1;
    return cur < start ? start : cur + 1;
  }

  String _seqFormat(Map<String, dynamic> seq, int n) {
    final width = (seq['seqwidth'] as num?)?.toInt() ?? 0;
    final padded = n.toString().padLeft(width, '0');
    final affix = seq['seqprefix']?.toString() ?? '';
    return (seq['isprefix']?.toString() ?? 'Y') == 'Y' ? '$affix$padded' : '$padded$affix';
  }


  /// Fetch the most-recent admission reg no and store it for the inline label.
  Future<void> _refreshLastRegNo() async {
    try {
      final res = await SupabaseService.client
          .from('admission')
          .select('admno')
          .eq('ins_id', _insId)
          .order('adm_id', ascending: false)
          .limit(1)
          .maybeSingle();
      final last = res?['admno']?.toString();
      if (!mounted) return;
      setState(() => _lastRegNo = (last == null || last.isEmpty) ? null : last);
    } catch (_) {
      // leave the previous value in place on failure
    }
  }

  /// Look up an integer id for [name] in [list] (row[nameKey]==name → row[idKey]).
  int? _idFor(List<Map<String, dynamic>> list, String nameKey, String? name, String idKey) {
    if (name == null || name.trim().isEmpty) return null;
    for (final m in list) {
      if (m[nameKey]?.toString() == name) {
        final v = m[idKey];
        return v is int ? v : int.tryParse(v?.toString() ?? '');
      }
    }
    return null;
  }

  /// Class id for [className], scoped to [courId] when the class row carries it.
  int? _classIdFor(String? className, int? courId) {
    if (className == null || className.trim().isEmpty) return null;
    for (final m in _classList) {
      if (m['claname']?.toString() != className) continue;
      final rowCour = m['cour_id'] is int
          ? m['cour_id'] as int
          : int.tryParse(m['cour_id']?.toString() ?? '');
      if (courId != null && rowCour != null && rowCour != courId) continue;
      final v = m['cla_id'];
      return v is int ? v : int.tryParse(v?.toString() ?? '');
    }
    return null;
  }

  Future<void> _saveAll() async {
    final auth = context.read<AuthProvider>();
    final entries = _rows.where((r) => !r.isBlank).toList();
    if (entries.isEmpty) {
      _snack('Enter at least one row.', AppColors.warning);
      return;
    }
    // Numbers are auto-generated from the selected sequence — but a row with a
    // manually-typed Register No doesn't need one. Require a sequence only when
    // at least one row is left blank for auto-numbering.
    final needsSeq = entries.any((r) => r.regNo.text.trim().isEmpty);
    Map<String, dynamic> seq = const {};
    if (_selectedRegSeqId != null) {
      seq = _regSeqs.firstWhere((s) => s['seq_id'].toString() == _selectedRegSeqId, orElse: () => const {});
    }
    if (needsSeq && seq.isEmpty) {
      _snack('Select an Admission Sequence — blank Register No rows are auto-numbered on save.', AppColors.warning);
      return;
    }
    // validate
    final problems = <String>[];
    for (var i = 0; i < entries.length; i++) {
      final r = entries[i];
      final miss = <String>[];
      // All columns are mandatory.
      if (r.name.text.trim().isEmpty) miss.add('Name');
      if (r.sex == null) miss.add('Gender');
      if (r.course == null) miss.add('Course');
      if (r.cls == null) miss.add('Class');
      if (r.admType == null) miss.add('Adm Type');
      if (r.batch.text.trim().isEmpty) miss.add('Batch');
      if (r.dob == null) miss.add('Birth Date');
      if (r.fatherName.text.trim().isEmpty) miss.add('Father Name');
      if (r.fatherMobile.text.trim().isEmpty) miss.add('Father Mobile');
      if (miss.isNotEmpty) problems.add('Row ${_rows.indexOf(r) + 1}: ${miss.join(', ')}');
    }
    if (problems.isNotEmpty) {
      _snack('Fill required fields — ${problems.first}${problems.length > 1 ? ' (+${problems.length - 1} more)' : ''}', AppColors.error);
      return;
    }

    setState(() => _saving = true);
    int done = 0;
    var seqN = seq.isEmpty ? 0 : _seqNext(seq); // running admission number, advanced per saved row
    final failures = <String>[];
    for (final r in entries) {
      try {
        // Manual register no overrides the auto sequence when entered.
        final manualRegNo = r.regNo.text.trim();
        final admno = manualRegNo.isNotEmpty ? manualRegNo : _seqFormat(seq, seqN);
        final admId = await AdmissionService.addAdmission({
          'ins_id': auth.insId ?? 1,
          'inscode': auth.inscode ?? '',
          // yr_id/yrlabel removed from public.admission (year derived at allocation).
          'admno': admno,
          'admdate': r.admDate.toIso8601String().split('T').first,
          'admsource': 'WALK-IN',
          'stuname': r.name.text.trim(),
          'stugender': r.sex,
          'studob': r.dob?.toIso8601String().split('T').first,
          'courname': r.course,
          'stuclass': r.cls,
          'admname': r.admType,
          // Entity IDs resolved from the selected masters (quota/medium not in this form).
          'cour_id': _idFor(_courseList, 'courname', r.course, 'cour_id'),
          'admit_cour_id': _idFor(_courseList, 'courname', r.course, 'cour_id'),
          'cla_id': _classIdFor(r.cls, _idFor(_courseList, 'courname', r.course, 'cour_id')),
          'admtype_id': _idFor(_admTypes, 'admname', r.admType, 'adm_id'),
          'batch': r.batch.text.trim().isEmpty ? null : r.batch.text.trim(),
          // Admitted year defaults to the current academic year label.
          'admittyear': _selectedYrLabel,
          // Father details — also auto-fill the Pay In Charge fields.
          'fathername': r.fatherName.text.trim().isEmpty ? null : r.fatherName.text.trim(),
          'fathermobile': r.fatherMobile.text.trim().isEmpty ? null : r.fatherMobile.text.trim(),
          'payincharge': r.fatherName.text.trim().isEmpty ? null : r.fatherName.text.trim(),
          'payinchargemob': r.fatherMobile.text.trim().isEmpty ? null : r.fatherMobile.text.trim(),
          'createdby': auth.userName,
        });
        // Class selected → move straight to students (skip Class Allocation).
        // No class → leave the admission pending for allocation later.
        if (r.cls != null && r.cls!.trim().isNotEmpty) {
          try {
            await AdmissionService.allocateClass(
              admId: admId,
              className: r.cls!.trim(),
              stuadmno: admno,
              allocatedBy: auth.userName,
            );
          } catch (_) {
            // Admission is saved; allocation can be retried from Class Allocation.
          }
        }
        if (manualRegNo.isEmpty) seqN++; // advance sequence only when it was used
        done++;
      } catch (e) {
        failures.add('${r.name.text.trim()}: ${friendlyError(e)}');
      }
    }
    // bump the register sequence to the last number actually assigned (only if
    // auto-numbering was used — all-manual saves don't touch the sequence).
    if (done > 0 && needsSeq && seq.isNotEmpty) {
      try {
        await AdmissionService.bumpRegSeqCurrent(int.parse(seq['seq_id'].toString()), seqN - 1);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _saving = false);
    _refreshLastRegNo();

    if (failures.isEmpty) {
      _snack('Saved $done admission(s).', AppColors.success);
      // reset to fresh blank rows
      for (final r in _rows) {
        r.dispose();
      }
      setState(() {
        _rows.clear();
        _rows.add(_FastRow());
        _selectedRegSeqId = null;
      });
      _load();
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Saved $done, ${failures.length} failed'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [for (final f in failures) Padding(padding: EdgeInsets.only(bottom: 4.h), child: Text('• $f', style: TextStyle(fontSize: 12.sp, color: AppColors.error)))],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  // ── columns ───────────────────────────────────────────────────────
  // All entry columns share one width so the grid reads as uniform cells.
  static const _wCol = 130.0;
  static const _wRegNo = _wCol, _wName = _wCol, _wSex = _wCol, _wCourse = _wCol,
      _wClass = _wCol, _wType = _wCol, _wBatch = _wCol, _wDob = _wCol, _wFather = _wCol, _wFmob = _wCol;

  // Page shell per admission-design.md § 1: outer white card with padding,
  // inner bordered table card matches Section Allocation pattern.
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
              padding: EdgeInsets.fromLTRB(16.w, 4.h, 16.w, 12.h),
              child: Column(
                children: [
                  _topBar(),
                  SizedBox(height: 8.h),
                  // Inner bordered table card.
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : LayoutBuilder(builder: (ctx, constraints) {
                              // Fit all columns to the viewport: scale down so
                              // every column is visible (no cut-off). Only when
                              // the screen is very narrow do we stop shrinking
                              // and allow horizontal scroll (with a visible bar).
                              const baseSum = _wRegNo + _wName + _wSex + _wCourse + _wClass + _wType + _wBatch + _wDob + _wFather + _wFmob + 32;
                              final viewport = constraints.maxWidth;
                              final ratio = viewport / baseSum;
                              final scale = ratio < 0.7 ? 0.7 : ratio;
                              final tableW = scale * baseSum < viewport ? viewport : scale * baseSum;
                              return Scrollbar(
                                controller: _hScroll,
                                thumbVisibility: tableW > viewport,
                                child: SingleChildScrollView(
                                  controller: _hScroll,
                                  scrollDirection: Axis.horizontal,
                                  physics: tableW <= viewport ? const NeverScrollableScrollPhysics() : null,
                                  child: SizedBox(
                                    width: tableW,
                                    child: Column(
                                      children: [
                                        _tableHeader(scale),
                                        Expanded(
                                          child: Scrollbar(
                                            controller: _vScroll,
                                            thumbVisibility: true,
                                            child: FocusTraversalGroup(
                                              child: ListView.builder(
                                                controller: _vScroll,
                                                itemCount: _rows.length,
                                                itemBuilder: (_, i) => _rowWidget(i, scale),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }),
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

  /// Single top bar: icon + "Fast Admission" + subtitle on the left,
  /// pushed-right Sequence dropdown + Last-no chip + navy Fill button.
  Widget _topBar() {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.h),
      child: Row(
        children: [
          const AppIcon('profile-add', size: 20, color: AppColors.primary),
          SizedBox(width: 10.w),
          Text('Fast Admission',
              style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(width: 10.w),
          Text('bulk entry — allocate sections later',
              style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          SizedBox(width: 200.w, child: _regSeqDropdown()),
          SizedBox(width: 10.w),
          _lastRegNoChip(),
          SizedBox(width: 10.w),
          OutlinedButton.icon(
            onPressed: _loading ? null : _load,
            icon: _loading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const AppIcon('refresh', size: 16, color: AppColors.primary),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }

  Widget _regSeqDropdown() => DropdownButtonFormField<String>(
        initialValue: _selectedRegSeqId,
        isExpanded: true,
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 6,
        icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
        style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
        decoration: _topBarDec(filled: _selectedRegSeqId != null),
        hint: Text('Select Sequence', style: TextStyle(fontSize: 13.sp, color: AppColors.textLight)),
        items: _regSeqs.map((s) => DropdownMenuItem(
              value: s['seq_id'].toString(),
              child: Text(s['seqname']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
            )).toList(),
        selectedItemBuilder: (context) => _regSeqs.map((s) => Align(alignment: Alignment.centerLeft, child: Text(s['seqname']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
        onChanged: (v) => setState(() => _selectedRegSeqId = v),
      );

  // Taller decoration for the top-bar Sequence dropdown so it lines up with
  // the navy Fill button visually.
  InputDecoration _topBarDec({bool filled = false, String? hint}) {
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

  /// Inline display of the last admission reg no, sitting next to the
  /// Register Sequence label. Tap to refresh.
  Widget _lastRegNoChip() => InkWell(
        onTap: _refreshLastRegNo,
        borderRadius: BorderRadius.circular(8.r),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8.r),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.20)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history, size: 14.sp, color: AppColors.primary),
              SizedBox(width: 6.w),
              Text('Last Admission No: ', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
              Text(_lastRegNo ?? '—',
                  style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ],
          ),
        ),
      );

  Widget _tableHeader(double scale) {
    TextStyle s() => TextStyle(
        fontSize: 12.sp,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: 0.3);
    Widget c(String t, double w) => SizedBox(width: w * scale, child: Padding(padding: EdgeInsets.symmetric(horizontal: 6.w), child: Text(t, style: s())));
    return Container(
      color: AppColors.tableHeadBg,
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
      child: Row(
        children: [
          c('REGISTER NO', _wRegNo), c('STUDENT NAME', _wName), c('GENDER', _wSex), c('COURSE', _wCourse),
          c('CLASS', _wClass), c('ADM TYPE', _wType), c('BATCH', _wBatch), c('BIRTH DATE', _wDob),
          c('FATHER NAME', _wFather), c('FATHER MOBILE', _wFmob),
        ],
      ),
    );
  }

  Widget _rowWidget(int i, double scale) {
    final r = _rows[i];
    double w(double base) => base * scale;
    return FocusTraversalGroup(
      child: Container(
      decoration: BoxDecoration(
        color: i.isEven ? Colors.white : AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border.withValues(alpha: 0.4))),
      ),
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 13.h),
      child: Row(
        children: [
          _cell(w(_wRegNo), _textCell(r.regNo, hint: 'Reg No')),
          _cell(w(_wName), _textCell(r.name)),
          _cell(w(_wSex), _dropCell(r.sex, _sexOptions.entries.map((e) => MapEntry(e.key, e.key)).toList(), (v) => setState(() => r.sex = v), hint: 'Select gender')),
          _cell(w(_wCourse), _dropCell(r.course, _courses.map((e) => MapEntry(e, e)).toList(), (v) => setState(() {
            r.course = v;
            // Drop a class that no longer belongs to the newly chosen course.
            if (r.cls != null && !_classNamesFor(v).contains(r.cls)) r.cls = null;
          }), hint: 'Select course')),
          _cell(w(_wClass), _dropCell(r.cls, _classNamesFor(r.course).map((e) => MapEntry(e, e)).toList(), (v) => setState(() => r.cls = v), hint: 'Select class')),
          _cell(w(_wType), _dropCell(r.admType, _admTypes.map((e) => MapEntry(e['admname'].toString(), e['admname'].toString())).toList(), (v) => setState(() => r.admType = v), hint: 'Select type')),
          _cell(w(_wBatch), _textCell(r.batch)),
          _cell(w(_wDob), _dateCell(r.dob, (d) => setState(() => r.dob = d))),
          _cell(w(_wFather), _textCell(r.fatherName)),
          _cell(w(_wFmob), _textCell(r.fatherMobile)),
        ],
      ),
      ),
    );
  }

  Widget _cell(double w, Widget child) => SizedBox(width: w, child: Padding(padding: EdgeInsets.symmetric(horizontal: 3.w), child: child));

  InputDecoration _cellDec({bool filled = false, String? hint}) {
    final idle = filled ? AppColors.accent : AppColors.border;
    return InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 16.h),
        filled: true,
        fillColor: Colors.white,
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: 11.sp),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6.r), borderSide: BorderSide(color: idle, width: 1.5)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6.r), borderSide: BorderSide(color: idle, width: 1.5)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6.r), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
      );
  }

  Widget _textCell(TextEditingController c, {String? hint}) {
    final filled = c.text.trim().isNotEmpty;
    return TextField(
        controller: c,
        style: TextStyle(fontSize: 11.sp, color: filled ? AppColors.accent : AppColors.textPrimary, fontWeight: filled ? FontWeight.w600 : null),
        decoration: _cellDec(filled: filled, hint: hint),
        onChanged: (_) => setState(() {}),
      );
  }

  Widget _dropCell(String? value, List<MapEntry<String, String>> items, ValueChanged<String?> onChanged, {String? hint}) {
    final values = items.map((e) => e.key).toList();
    return DropdownButtonFormField<String>(
      initialValue: values.contains(value) ? value : null,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      style: TextStyle(fontSize: 11.sp, color: AppColors.textPrimary),
      decoration: _cellDec(filled: values.contains(value), hint: hint),
      items: items.map((e) => DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          )).toList(),
      selectedItemBuilder: (context) => items.map((e) => Align(alignment: Alignment.centerLeft, child: Text(e.value, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
      onChanged: onChanged,
    );
  }

  Widget _dateCell(DateTime? value, ValueChanged<DateTime> onPick) {
    final filled = value != null;
    return FocusableTap(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(context: context, initialDate: value ?? DateTime(now.year - 17), firstDate: DateTime(1950), lastDate: DateTime(now.year + 5));
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: _cellDec(filled: filled),
        child: Text(value == null ? '—' : _fmt(value), style: TextStyle(fontSize: 11.sp, color: value == null ? AppColors.textLight : AppColors.accent, fontWeight: value == null ? null : FontWeight.w600)),
      ),
    );
  }

  String _fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  Widget _actionBar() {
    final count = _rows.where((r) => !r.isBlank).length;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6.h),
      child: Row(
        children: [
          OutlinedButton.icon(onPressed: _addRow, icon: const Icon(Icons.add, size: 16), label: const Text('Add Row')),
          SizedBox(width: 10.w),
          Text('$count filled', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _saving || count == 0 ? null : _saveAll,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: Text(_saving ? 'Saving…' : 'Save All'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }
}
