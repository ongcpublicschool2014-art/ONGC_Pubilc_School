import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../services/supabase_service.dart';
import '../../services/admission_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
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
  // One parent pair per row. Which parent it IS comes from the screen-level
  // Parent Type selector, so the same two columns serve Father/Mother/Guardian.
  final parentName = TextEditingController();
  final parentMobile = TextEditingController();
  /// Government EMIS number. Optional — it often arrives weeks after the
  /// admission, and the EMIS / UMIS screen fills it in bulk later.
  final emisNo = TextEditingController();
  /// Which parent this row's name/mobile pair belongs to. Per row, so one
  /// batch can mix father-, mother- and guardian-led records.
  String parentType = 'F';
  String? sex; // M | F | T
  String? course;
  String? cls;
  /// Admission -> Division (required on school; fills from the standard).
  String? division;
  String? admType;
  DateTime? dob;
  DateTime admDate = DateTime.now();

  void dispose() {
    regNo.dispose();
    name.dispose();
    batch.dispose();
    parentName.dispose();
    parentMobile.dispose();
    emisNo.dispose();
  }

  bool get isBlank => name.text.trim().isEmpty;
}

class _FastAdmissionScreenState extends State<FastAdmissionScreen> {
  final List<_FastRow> _rows = [];

  /// A chosen Register Sequence supplies the number, so the column is
  /// read-only — the same rule Admission Entry follows in Auto mode. Clearing
  /// the sequence hands the column back for manual entry.
  bool get _regNoLocked => _selectedRegSeqId != null;

  /// Every row in THIS batch is a pre-admission: seat booked now, studies from
  /// next year.
  ///
  /// A batch switch rather than a per-row tick, because a pre-admission intake
  /// is entered as a batch — and the grid is already twelve columns wide.
  /// Mixed batches are entered as two saves.
  bool _preAdmission = false;

  /// Register numbers already used by an admission, upper-cased so the check
  /// ignores case and spacing. CANCELLED admissions are excluded — their number
  /// is free to reuse, same rule as Admission Entry.
  Set<String> _takenRegNos = <String>{};
  // Single-letter flag, same style as the gender column.
  static const _parentOptions = {'F': 'Father', 'M': 'Mother', 'G': 'Guardian'};

  /// The name/mobile headers follow the rows: when every filled row picks the
  /// same parent they read FATHER/MOTHER/GUARDIAN, and fall back to the neutral
  /// PARENT when a batch mixes them.
  String get _headerParent {
    final used = _rows.where((r) => !r.isBlank).map((r) => r.parentType).toSet();
    final code = used.length == 1
        ? used.first
        : (used.isEmpty && _rows.isNotEmpty ? _rows.first.parentType : null);
    return code == null ? 'Parent' : (_parentOptions[code] ?? 'Parent');
  }
  /// Set once Save All is pressed with something missing, so the offending
  /// cells go red instead of the problem living only in a snackbar.
  bool _showErrors = false;
  List<Map<String, dynamic>> _courseList = []; // {cour_id, courname}
  /// Division master (div_id -> name).
  Map<int, String> _divById = {};
  List<String> get _divisions => (_divById.values.where((s) => s.isNotEmpty).toSet().toList()..sort());
  /// The division of a standard (course.div_id), or null.
  String? _divisionOfCourse(String? courname) {
    if (courname == null) return null;
    final c = _courseList.firstWhere((e) => e['courname']?.toString() == courname, orElse: () => const {});
    final id = c['div_id'];
    return id == null ? null : _divById[(id as num).toInt()];
  }
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
    // Course, then year, with the TC batches last (utils/class_sort.dart).
    // A plain alphabetical sort put "CSE TC 25" above "B.E CSE -I".
    return (src.map((e) => e['claname']?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty).toSet().toList()
      ..sort(classCompare));
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

  /// The institution's Utilities admission-number policy: 'AUTO' or 'MANUAL'.
  /// Null until it has been read.
  String? _utilRegMode;

  /// MANUAL means the number is typed, so there is no sequence to pick — the
  /// picker is disabled rather than merely left unselected, so the sequence
  /// can't be started by hand and quietly begin consuming numbers against a
  /// policy that says otherwise.
  bool get _seqPickerEnabled => _utilRegMode != 'MANUAL';

  /// Reads the Utilities mode and, when it is AUTO, selects the first register
  /// sequence so blank Register No cells are auto-numbered on save. The mode is
  /// stored either way — it also drives whether the picker is usable at all.
  Future<void> _maybeAutoPickSeq() async {
    if (!mounted) return;
    final s = await SupabaseService.getInstitutionSettings(_insId);
    if (!mounted) return;
    final mode = (s['admission_number_mode'] ?? 'MANUAL').toUpperCase() == 'AUTO'
        ? 'AUTO'
        : 'MANUAL';
    setState(() {
      _utilRegMode = mode;
      if (mode == 'AUTO') {
        if (_selectedRegSeqId == null && _regSeqs.isNotEmpty) {
          _selectedRegSeqId = _regSeqs.first['seq_id'].toString();
        }
      } else {
        // Policy is MANUAL: drop any sequence so the Register No column is
        // typed, and clear it in both directions rather than only on load.
        _selectedRegSeqId = null;
      }
    });
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
        SupabaseService.fromSchema('course').select('*').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.getAdmissionTypes(insId),
        SupabaseService.getYears(insId),
        SupabaseService.fromSchema('sequence').select('*').eq('actname', 'REGNO').eq('activestatus', 1).order('seq_id', ascending: true),
        // Existing register numbers, for the duplicate check. fetchAll because
        // there are already more than PostgREST's 1000-row page.
        SupabaseService.fetchAll(() => SupabaseService.client
            .from('admission')
            .select('admno')
            .eq('ins_id', insId)
            .neq('admstatus', 'CANCELLED')),
        SupabaseService.fromSchema('division').select('div_id, divname').eq('ins_id', insId).eq('activestatus', 1)
            .then((v) => v, onError: (_) => <dynamic>[]),
      ]));
      if (!mounted) return;
      setState(() {
        _courseList = List<Map<String, dynamic>>.from(results[0] as List);
        _classList = List<Map<String, dynamic>>.from(results[1] as List);
        _admTypes = List<Map<String, dynamic>>.from(results[2] as List);
        _years = results[3] as List<Map<String, dynamic>>;
        _regSeqs = List<Map<String, dynamic>>.from(results[4] as List);
        _divById = {
          for (final e in (results[6] as List))
            if ((e as Map)['div_id'] != null) (e['div_id'] as num).toInt(): '${e['divname'] ?? ''}'.trim(),
        };
        _takenRegNos = List<Map<String, dynamic>>.from(results[5] as List)
            .map((e) => (e['admno']?.toString() ?? '').trim().toUpperCase())
            .where((e) => e.isNotEmpty)
            .toSet();
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
        _snack('Could not load admission data. ${friendlyError(e)} Press Refresh to try again.', AppColors.error);
      }
    }
  }

  void _addRow() => setState(() => _rows.add(_FastRow()));

  /// Drop row [i]. The last row is emptied instead of removed, so the grid
  /// always has somewhere to type -- and its controllers are disposed either
  /// way, because a TextEditingController that outlives its field leaks.
  void _removeRow(int i) {
    setState(() {
      if (_rows.length == 1) {
        _rows[0].dispose();
        _rows[0] = _FastRow();
        return;
      }
      _rows.removeAt(i).dispose();
    });
  }

  // ── validation rules, mirroring Admission Entry ──────────────────────────
  //
  // Each returns true only for a value that is present AND wrong, so a blank
  // field is left to the "required" check and never shows two errors at once.

  /// Batch must read YYYY-YYYY with the second year after the first.
  bool _batchBad(String v) {
    final t = v.trim();
    if (t.isEmpty) return false;
    final m = RegExp(r'^(\d{4})-(\d{4})$').firstMatch(t);
    if (m == null) return true;
    return int.parse(m.group(2)!) <= int.parse(m.group(1)!);
  }

  /// A mobile number is 10 digits exactly (the field already accepts digits
  /// only, so this is purely a length rule).
  bool _mobileBad(String v) {
    final t = v.trim();
    return t.isNotEmpty && t.length != 10;
  }

  /// A typed register number must not belong to an existing admission, nor be
  /// repeated on another row of this grid — the batch is saved in one go, so
  /// two identical numbers here would collide with each other.
  bool _regNoBad(_FastRow row) {
    if (_regNoLocked) return false; // generated from the sequence, not typed
    final v = row.regNo.text.trim().toUpperCase();
    if (v.isEmpty) return false; // blank = take the next sequence number
    if (_takenRegNos.contains(v)) return true;
    return _rows.any((o) =>
        !identical(o, row) && o.regNo.text.trim().toUpperCase() == v);
  }


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
      _snack('Fill in at least one student row before saving.', AppColors.warning);
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
      _snack(schoolTerm('Select the register number sequence. Rows with a blank Register No. are numbered from it on save.'), AppColors.warning);
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
      if (r.course == null) miss.add(schoolTerm('Course'));
      // School: optional -- Section Allocation places the student.
      if (!isSchool && r.cls == null) miss.add(schoolTerm('Class'));
      if (isSchool && r.division == null) miss.add('Division');
      // A school has no admission type / batch.
      if (!isSchool && r.admType == null) miss.add('Admission Type');
      if (!isSchool && r.batch.text.trim().isEmpty) miss.add('Batch');
      if (r.dob == null) miss.add(AppText.dateOfBirth);
      if (r.parentName.text.trim().isEmpty) miss.add('${_parentOptions[r.parentType] ?? 'Parent'} Name');
      if (r.parentMobile.text.trim().isEmpty) miss.add('${_parentOptions[r.parentType] ?? 'Parent'} Mobile');
      // Same rules Admission Entry applies, checked here so a bad value is
      // caught before the batch is written rather than by the database.
      if (_regNoBad(r)) miss.add(schoolTerm('Register No (already used)'));
      if (!isSchool && _batchBad(r.batch.text)) miss.add('Batch (YYYY-YYYY)');
      if (_mobileBad(r.parentMobile.text)) miss.add('Mobile (10 digits)');
      if (miss.isNotEmpty) problems.add('Row ${_rows.indexOf(r) + 1}: ${miss.join(', ')}');
    }
    if (problems.isNotEmpty) {
      // Mark the offending cells so the row is findable without reading the
      // message — the grid can be long and the snackbar names only one row.
      setState(() => _showErrors = true);
      _snack('Fill in the required fields. ${problems.first}${problems.length > 1 ? ' (+${problems.length - 1} more)' : ''}', AppColors.error);
      return;
    }
    if (_showErrors) setState(() => _showErrors = false);

    setState(() => _saving = true);
    int done = 0;
    var seqN = seq.isEmpty ? 0 : _seqNext(seq); // running admission number, advanced per saved row
    var claimedAny = false; // any number handed out by claim_reg_no
    final failures = <String>[];
    for (final r in entries) {
      try {
        // Manual register no overrides the auto sequence when entered.
        final manualRegNo = _regNoLocked ? '' : r.regNo.text.trim();
        // Each auto-numbered row claims its own number on the server, so a
        // batch and another operator's entry never collide.
        String? claimed;
        // School: the number is assigned inside save_admission (below).
        final serverNumbers = isSchool && manualRegNo.isEmpty && seq.isNotEmpty;
        if (!serverNumbers && manualRegNo.isEmpty && seq.isNotEmpty) {
          claimed = await AdmissionService.claimRegNo(int.parse(seq['seq_id'].toString()));
          if (claimed != null) claimedAny = true;
        }
        var admno = manualRegNo.isNotEmpty ? manualRegNo : (claimed ?? _seqFormat(seq, seqN));
        final data = <String, dynamic>{
          'ins_id': auth.insId ?? 1,
          'inscode': auth.inscode ?? '',
          // yr_id/yrlabel removed from public.admission (year derived at allocation).
          'admno': admno,
          'admdate': r.admDate.toIso8601String().split('T').first,
          'admsource': 'WALK-IN',
          'preadmission': _preAdmission ? 1 : 0,
          'stuname': r.name.text.trim(),
          'stugender': r.sex,
          'studob': r.dob?.toIso8601String().split('T').first,
          'courname': r.course,
          'stuclass': r.cls,
          'division': r.division,
          if (!isSchool) 'admname': r.admType,
          // Entity IDs resolved from the selected masters (quota/medium not in this form).
          'cour_id': _idFor(_courseList, 'courname', r.course, 'cour_id'),
          'admit_cour_id': _idFor(_courseList, 'courname', r.course, 'cour_id'),
          'cla_id': _classIdFor(r.cls, _idFor(_courseList, 'courname', r.course, 'cour_id')),
          if (!isSchool) 'admtype_id': _idFor(_admTypes, 'admname', r.admType, 'adm_id'),
          if (!isSchool) 'batch': r.batch.text.trim().isEmpty ? null : r.batch.text.trim(),
          'emisno': r.emisNo.text.trim().isEmpty ? null : r.emisNo.text.trim(),
          // Admitted year defaults to the current academic year label.
          'admittyear': _selectedYrLabel,
          // Parent details go to the columns for the selected Parent Type, and
          // also auto-fill the Pay In Charge pair whichever parent it is.
          ..._parentColumns(r),
          'createdby': auth.userName,
        };
        final int admId;
        if (serverNumbers) {
          final res = await AdmissionService.addAdmissionNumbered(data, int.parse(seq['seq_id'].toString()));
          admId = res.admId;
          admno = res.admno;
          claimedAny = true; // the server moved the counter: no end-of-batch bump
        } else {
          admId = await AdmissionService.addAdmission(data);
        }
        // Class selected → move straight to students (skip Class Allocation).
        // No class → leave the admission pending for allocation later.
        // A school always waits for Section Allocation (r.cls pre-fills it).
        if (!isSchool && r.cls != null && r.cls!.trim().isNotEmpty) {
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
    // Skipped once the server has claimed numbers: bumping to seqN - 1 would
    // drag the counter BACKWARDS over numbers claim_reg_no just issued.
    if (!claimedAny && done > 0 && needsSeq && seq.isNotEmpty) {
      try {
        await AdmissionService.bumpRegSeqCurrent(int.parse(seq['seq_id'].toString()), seqN - 1);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _saving = false);
    _refreshLastRegNo();

    if (failures.isEmpty) {
      _snack('$done ${done == 1 ? 'admission' : 'admissions'} saved.', AppColors.success);
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
          title: Text('$done Saved, ${failures.length} Not Saved'),
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
      _wClass = _wCol, _wType = _wCol, _wBatch = _wCol, _wDob = _wCol,
      _wPtype = _wCol, _wFather = _wCol, _wFmob = _wCol, _wEmis = _wCol, _wDiv = _wCol;

  /// The trailing remove-row button. Narrow: it is an icon, not a field.
  static const _wKill = 46.0;

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
            decoration: AppUI.card(),
            child: Padding(
              padding: EdgeInsets.fromLTRB(AppUI.cardPad, 8.h, AppUI.cardPad, 12.h),
              child: Column(
                children: [
                  _topBar(),
                  SizedBox(height: 8.h),
                  // Inner bordered table card.
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppUI.controlRadius),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : LayoutBuilder(builder: (ctx, constraints) {
                              // Fit all columns to the viewport: scale down so
                              // every column is visible (no cut-off). Only when
                              // the screen is very narrow do we stop shrinking
                              // and allow horizontal scroll (with a visible bar).
                              // School: no ADM TYPE / BATCH columns.
                              final baseSum = _wRegNo + _wName + _wSex + _wCourse + _wClass + (isSchool ? _wDiv : _wType + _wBatch) + _wDob + _wPtype + _wFather + _wFmob + _wEmis + _wKill + 32;
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
                                                // One past the rows: the last
                                                // item is the hint that fills
                                                // the empty half of the screen.
                                                itemCount: _rows.length + 1,
                                                itemBuilder: (_, i) => i == _rows.length
                                                    ? _listHint()
                                                    : _rowWidget(i, scale),
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
  /// admission columns for the row's parent pair, keyed off _parentType.
  Map<String, dynamic> _parentColumns(_FastRow r) {
    final name = r.parentName.text.trim().isEmpty ? null : r.parentName.text.trim();
    final mob = r.parentMobile.text.trim().isEmpty ? null : r.parentMobile.text.trim();
    final prefix = switch (r.parentType) {
      'M' => 'mother',
      'G' => 'guardian',
      _ => 'father',
    };
    return {
      '${prefix}name': name,
      '${prefix}mobile': mob,
      // Pay In Charge is derived from whichever parent was captured.
      'payincharge': name,
      'payinchargemob': mob,
    };
  }

  Widget _topBar() {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.h),
      child: Row(
        children: [
          AppUI.iconTile('profile-add'),
          SizedBox(width: 12.w),
          Text('Fast Admission', style: AppUI.cardTitle),
          SizedBox(width: 10.w),
          Text(schoolTerm('Bulk entry. Allocate classes later.'), style: AppUI.muted),
          const Spacer(),
          _preAdmissionSwitch(),
          SizedBox(width: 10.w),
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

  Widget _regSeqDropdown() => Tooltip(
      message: _seqPickerEnabled
          ? schoolTerm('Register numbers come from this sequence')
          : schoolTerm('Admission number mode is Manual in Utilities — type the Register No on each row'),
      child: DropdownButtonFormField<String>(
        initialValue: _selectedRegSeqId,
        isExpanded: true,
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        elevation: 6,
        icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
        style: AppUI.fieldText(context, filled: _selectedRegSeqId != null),
        decoration: _topBarDec(filled: _selectedRegSeqId != null),
        hint: Text(_seqPickerEnabled ? 'Select sequence' : 'Manual numbering (set in Utilities)',
            overflow: TextOverflow.ellipsis,
            style: AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)),
        items: _regSeqs.map((s) => DropdownMenuItem(
              value: s['seq_id'].toString(),
              child: Text(s['seqname']?.toString() ?? '', style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis),
            )).toList(),
        selectedItemBuilder: (context) => _regSeqs.map((s) => Align(alignment: Alignment.centerLeft, child: Text(s['seqname']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
        // null disables the field: under a MANUAL policy there is nothing to
        // choose.
        onChanged: !_seqPickerEnabled
            ? null
            : (v) => setState(() {
                  _selectedRegSeqId = v;
                  // Under a sequence the number is generated, so clear anything
                  // typed by hand — otherwise the grid would show one number
                  // and save another.
                  if (v != null) {
                    for (final r in _rows) {
                      r.regNo.clear();
                    }
                  }
                }),
      ));

  // Taller decoration for the top-bar Sequence dropdown so it lines up with
  // the navy Fill button visually.
  InputDecoration _topBarDec({bool filled = false, String? hint}) =>
      AppUI.field(context, hint ?? '', filled: filled);

  /// Marks the whole batch as pre-admission. Filled and loud when on: it
  /// changes what every row saved after it means, and it is easy to leave
  /// switched on by mistake between batches.
  Widget _preAdmissionSwitch() {
    final on = _preAdmission;
    return InkWell(
      onTap: () => setState(() => _preAdmission = !_preAdmission),
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      child: Tooltip(
        message: on
            ? schoolTerm('Every row saved now is admitted for next academic year. No fee '
                'demand is raised for the current year, and Year End Process keeps '
                'the student in the class entered below.')
            : 'Turn on for students who start next academic year.',
        child: Container(
          constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          decoration: BoxDecoration(
            color: on ? AppColors.warningBg : Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(
                color: on ? AppColors.warning : AppColors.border, width: 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.event_available : Icons.event_outlined,
                size: 15.sp, color: on ? AppColors.warning : AppColors.textSecondary),
            SizedBox(width: 6.w),
            Text('PRE-ADMISSION',
                style: TextStyle(
                    fontSize: 10.sp,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: on ? AppColors.warning : AppColors.textSecondary)),
            SizedBox(width: 6.w),
            Text(on ? 'NEXT YEAR' : 'OFF',
                style: TextStyle(
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w800,
                    color: on
                        ? AppColors.warning
                        : AppColors.textLight)),
          ]),
        ),
      ),
    );
  }

  /// Inline display of the last admission reg no, sitting next to the
  /// Register Sequence label. Tap to refresh.
  Widget _lastRegNoChip() => InkWell(
        onTap: _refreshLastRegNo,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        // The number the cashier types the NEXT one from, so it earns emphasis:
        // a solid accent chip rather than a faint tint, with the number itself
        // the largest thing in it.
        child: Container(
          constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          decoration: BoxDecoration(
            color: AppColors.primaryLight,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.35), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history, size: 15.sp, color: AppColors.primary),
              SizedBox(width: 6.w),
              Text(schoolTerm('LAST REGISTER NO.'),
                  style: TextStyle(
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: AppColors.primary)),
              SizedBox(width: 8.w),
              Text(_lastRegNo ?? '—',
                  style: TextStyle(
                      fontSize: 15.sp,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      color: AppColors.primary)),
            ],
          ),
        ),
      );

  /// What to do next, in the space under the rows.
  ///
  /// This screen opens with one blank row and three-quarters of a blank page,
  /// which reads as "nothing here" rather than "start typing". The hint is
  /// part of the list, so it sits right under the last row and scrolls with
  /// it instead of floating in the middle of the table.
  Widget _listHint() {
    final filled = _rows.where((r) => !r.isBlank).length;
    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 28.h, 16.w, 28.h),
      child: Column(children: [
        Container(
          padding: EdgeInsets.all(14.w),
          decoration: BoxDecoration(
            color: AppColors.primaryLight,
            borderRadius: BorderRadius.circular(AppUI.cardRadius),
          ),
          child: AppIcon.linear(filled == 0 ? 'people' : 'tick-circle',
              size: 22, color: AppColors.primary),
        ),
        SizedBox(height: 12.h),
        Text(
          filled == 0
              ? 'One row per student'
              : '$filled student${filled == 1 ? '' : 's'} ready to save',
          style: TextStyle(
              fontSize: 15.sp,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary),
        ),
        SizedBox(height: 4.h),
        SizedBox(
          width: 420.w,
          child: Text(
            filled == 0
                ? schoolTerm('Fill the row above and press Add Row for the next one. Leave '
                    'Register No blank and it is numbered from the sequence on save.')
                : schoolTerm('Press Add Row for another student, or Save All to save them. '
                    'Classes are allocated later.'),
            textAlign: TextAlign.center,
            style: AppUI.muted.copyWith(height: 1.45),
          ),
        ),
        SizedBox(height: 14.h),
        OutlinedButton.icon(
          onPressed: _addRow,
          icon: const Icon(Icons.add, size: 15),
          label: const Text('Add Row'),
        ),
      ]),
    );
  }

  Widget _tableHeader(double scale) {
    TextStyle s() => AppUI.tableHead;
    Widget c(String t, double w) => SizedBox(width: w * scale, child: Padding(padding: EdgeInsets.symmetric(horizontal: 6.w), child: Text(t, style: s())));
    return Container(
      // Tinted, with an accent rule under it: twelve columns of grey headings
      // over a grey strip gave the eye nothing to land on.
      decoration: const BoxDecoration(
        color: AppColors.tableHeadBg,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
      child: Row(
        children: [
          // ' *' marks a column every filled row must have.
          c(schoolTerm('REGISTER NO'), _wRegNo), c('STUDENT NAME *', _wName), c('GENDER *', _wSex), c(schoolTerm('COURSE *'), _wCourse),
          c(schoolTerm(isSchool ? 'CLASS' : 'CLASS *'), _wClass),
          if (isSchool) c('DIVISION *', _wDiv),
          if (!isSchool) ...[c('ADMISSION TYPE *', _wType), c('BATCH *', _wBatch)],
          c('DATE OF BIRTH *', _wDob),
          c('PARENT TYPE *', _wPtype),
          c('${_headerParent.toUpperCase()} NAME *', _wFather),
          c('${_headerParent.toUpperCase()} MOBILE *', _wFmob),
          c(schoolTerm('EMIS NO'), _wEmis),
          // No heading: the column holds one icon per row, and a word above it
          // would read as another field.
          SizedBox(width: _wKill * scale),
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
        // Same zebra as the Fee Collection grid -- AppColors.surface is so
        // close to white that the rows read as one block.
        color: i.isEven ? Colors.white : AppColors.primaryLight.withValues(alpha: 0.5),
        border: const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 13.h),
      child: Row(
        children: [
          _cell(
              w(_wRegNo),
              _textCell(r.regNo,
                  hint: _regNoLocked ? AppText.autoFilled : 'Enter number',
                  locked: _regNoLocked,
                  invalid: _regNoBad(r))),
          _cell(w(_wName), _textCell(r.name, hint: 'Enter name', required: true)),
          _cell(w(_wSex), _dropCell(r.sex, _sexOptions.entries.map((e) => MapEntry(e.key, e.value)).toList(), (v) => setState(() => r.sex = v), hint: 'Select', required: true)),
          _cell(w(_wCourse), _dropCell(r.course, _courses.map((e) => MapEntry(e, e)).toList(), (v) => setState(() {
            r.course = v;
            // Drop a class that no longer belongs to the newly chosen course.
            if (r.cls != null && !_classNamesFor(v).contains(r.cls)) r.cls = null;
            // the standard's division fills in (still changeable)
            r.division = _divisionOfCourse(v) ?? r.division;
          }), hint: 'Select', required: true)),
          _cell(w(_wClass), _dropCell(r.cls, _classNamesFor(r.course).map((e) => MapEntry(e, e)).toList(), (v) => setState(() => r.cls = v), hint: 'Select', required: !isSchool)),
          if (isSchool)
            _cell(w(_wDiv), _dropCell(r.division, {..._divisions, if (r.division != null) r.division!}.map((e) => MapEntry(e, e)).toList(),
                (v) => setState(() => r.division = v), hint: 'Select', required: true)),
          if (!isSchool) ...[
          _cell(w(_wType), _dropCell(r.admType, _admTypes.map((e) => MapEntry(e['admname'].toString(), e['admname'].toString())).toList(), (v) => setState(() => r.admType = v), hint: 'Select', required: true)),
          _cell(w(_wBatch), _textCell(r.batch, hint: 'YYYY-YYYY', required: true, invalid: _batchBad(r.batch.text))),
          ],
          _cell(w(_wDob), _dateCell(r.dob, (d) => setState(() => r.dob = d), required: true)),
          _cell(
              w(_wPtype),
              _dropCell(r.parentType, _parentOptions.entries.map((e) => MapEntry(e.key, e.value)).toList(),
                  (v) => setState(() => r.parentType = v ?? 'F'),
                  hint: 'Select', required: true)),
          _cell(w(_wFather), _textCell(r.parentName, hint: 'Enter name', required: true)),
          _cell(w(_wFmob), _textCell(r.parentMobile, hint: 'Enter mobile', required: true, digitsOnly: true, maxLen: 10, invalid: _mobileBad(r.parentMobile.text))),
          _cell(w(_wEmis), _textCell(r.emisNo, hint: schoolTerm('Enter EMIS no.'), digitsOnly: true, maxLen: 30)),
          // Removing a row belongs ON the row -- a single button at the bottom
          // cannot say WHICH row, and this grid runs to dozens of them.
          SizedBox(
            width: w(_wKill),
            child: Center(
              child: IconButton(
                tooltip: _rows.length == 1 ? 'Clear this row' : 'Delete this row',
                onPressed: _saving ? null : () => _removeRow(i),
                icon: Icon(Icons.close_rounded, size: 17.sp),
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  foregroundColor: AppColors.error.withValues(alpha: 0.75),
                  hoverColor: AppColors.error.withValues(alpha: 0.10),
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// Every cell is the same box: the column width, and a fixed height applied
  /// OUTSIDE the field. The decoration's own constraint is not enough on its
  /// own — a DropdownButtonFormField will not render shorter than Material's
  /// 48px minimum interactive height, so at 46 the dropdown columns sat taller
  /// than the text ones.
  /// Sets the column WIDTH only. Height is left to the field: see _cellDec —
  /// forcing it here made the wrapper and the field disagree, which is what
  /// left the text columns shorter than the dropdowns.
  Widget _cell(double w, Widget child) => SizedBox(
        width: w,
        child: Padding(
          // Unscaled: the gutter has to be identical in every column or the
          // boxes end up different widths.
          padding: const EdgeInsets.symmetric(horizontal: _cellGutter),
          child: child,
        ),
      );

  /// Gutter each side of a cell, unscaled so every column is the same width.
  static const double _cellGutter = 3;

  /// ONE decoration for every cell, so all three field types render through
  /// the same InputDecorator and cannot disagree: a plain rectangle, 40 high,
  /// 6px corners, 1.5px border.
  ///
  /// The reason this works now and did not before is [_dropCell]'s
  /// `itemHeight: null` — a DropdownButtonFormField otherwise floors at
  /// kMinInteractiveDimension (48) and grew past whatever the text fields did.
  /// Drawing the box by hand around a collapsed field was the wrong answer:
  /// the wrapper and the field then sized separately and the text columns came
  /// out shorter and rounder than the dropdowns.
  InputDecoration _cellDec({bool filled = false, String? hint, bool error = false, bool locked = false}) {
    // No isDense and no min height on purpose. The height is whatever this
    // padding plus an 11sp line comes to — identical for a TextField, a
    // DropdownButtonFormField and an InputDecorator, because all three are
    // given exactly this decoration and exactly that text style.
    final d = AppUI.field(context, hint ?? '', filled: filled, dense: true).copyWith(
      isDense: false,
      constraints: const BoxConstraints(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
      fillColor: locked ? AppColors.surface : null,
      hintMaxLines: 1,
      hintStyle: TextStyle(color: AppColors.textLight, fontSize: 11.sp),
    );
    if (!error) return d;
    OutlineInputBorder red(double w) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          borderSide: BorderSide(color: AppColors.error, width: w),
        );
    return d.copyWith(border: red(1), enabledBorder: red(1), disabledBorder: red(1), focusedBorder: red(2));
  }

  TextStyle _cellText(bool filled) => AppUI.fieldText(context, filled: filled).copyWith(fontSize: 11.sp);

  /// [invalid] marks a value that is present but wrong (bad batch, short
  /// mobile, duplicate register no). Unlike the required-but-empty highlight it
  /// shows immediately rather than waiting for Save All — in a grid this long,
  /// finding out at the end means hunting for the row.
  Widget _textCell(TextEditingController c,
      {String? hint, bool required = false, bool digitsOnly = false,
      int? maxLen, bool invalid = false, bool locked = false}) {
    final filled = c.text.trim().isNotEmpty;
    final bad = (_showErrors && required && !filled) || invalid;
    return TextField(
      controller: c,
      enabled: !locked,
      textAlignVertical: TextAlignVertical.center,
      inputFormatters: <TextInputFormatter>[
        if (digitsOnly) FilteringTextInputFormatter.digitsOnly,
        if (maxLen != null) LengthLimitingTextInputFormatter(maxLen),
      ],
      style: _cellText(filled),
      decoration: _cellDec(filled: filled, hint: hint, error: bad, locked: locked),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _dropCell(String? value, List<MapEntry<String, String>> items, ValueChanged<String?> onChanged,
      {String? hint, bool required = false}) {
    final values = items.map((e) => e.key).toList();
    final bad = _showErrors && required && value == null;
    return DropdownButtonFormField<String>(
      initialValue: values.contains(value) ? value : null,
      isExpanded: true,
      isDense: true,
      // Without this the button floors at kMinInteractiveDimension (48) and no
      // shared height below that can hold.
      itemHeight: null,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      icon: const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.textSecondary),
      style: _cellText(false),
      // The dropdown draws its own hint (it ignores hintMaxLines), so give it
      // a one-line Text -- a longer hint wrapped and was cut in half.
      hint: hint == null
          ? null
          : Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppColors.textLight, fontSize: 11.sp)),
      decoration: _cellDec(filled: values.contains(value), error: bad),
      items: items
          .map((e) => DropdownMenuItem(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis, style: _cellText(false)),
              ))
          .toList(),
      selectedItemBuilder: (context) => items
          .map((e) => Align(
              alignment: Alignment.centerLeft,
              child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: _cellText(true))))
          .toList(),
      onChanged: onChanged,
    );
  }

  Widget _dateCell(DateTime? value, ValueChanged<DateTime> onPick, {bool required = false}) {
    final filled = value != null;
    final bad = _showErrors && required && !filled;
    return FocusableTap(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(context: context, initialDate: value ?? DateTime(now.year - 17), firstDate: DateTime(1950), lastDate: DateTime(now.year + 5));
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: _cellDec(filled: filled, error: bad),
        // Always a real line of text — an empty child would collapse this cell
        // shorter than its neighbours. The placeholder is drawn as the value so
        // the height is identical whether or not a date is set.
        child: Text(
          value == null ? AppText.dateHint : _fmt(value),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: filled
              ? _cellText(true)
              : TextStyle(color: AppColors.textLight, fontSize: 11.sp),
        ),
      ),
    );
  }

  String _fmt(DateTime d) => formatDmy(d);

  Widget _actionBar() {
    final count = _rows.where((r) => !r.isBlank).length;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6.h),
      child: Row(
        children: [
          // A pill, and it lights up once there is something to save: this is
          // the number the operator checks before pressing Save All.
          AppUI.chip('$count ${count == 1 ? 'student' : 'students'} ready to save', count == 0 ? AppStatus.neutral : AppStatus.info),
          const Spacer(),
          AppUI.requiredNote(),
          SizedBox(width: 12.w),
          ElevatedButton.icon(
            onPressed: _saving || count == 0 ? null : _saveAll,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save, size: 16),
            label: Text(_saving ? 'Saving…' : 'Save All'),
          ),
        ],
      ),
    );
  }
}
