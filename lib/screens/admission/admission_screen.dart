import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/mobile_rules.dart';
import '../../utils/reg_sequence.dart';
import '../../utils/school_terms.dart';
import '../../services/supabase_service.dart';
import '../../services/admission_service.dart';
import '../../models/admission_model.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/focusable_tap.dart';
import '../../widgets/app_dropdown_field.dart';

/// Admission module — master/detail.
/// New admissions are captured into the PUBLIC `admission` table. An admin
/// then allocates a class, which moves the record into the institution
/// schema's students/parents/parentdetail tables.
class AdmissionScreen extends StatefulWidget {
  const AdmissionScreen({super.key});

  @override
  State<AdmissionScreen> createState() => _AdmissionScreenState();
}

class _AdmissionScreenState extends State<AdmissionScreen> {
  final _searchController = TextEditingController();

  // ── form controllers ──────────────────────────────────────────────
  final _admnoController = TextEditingController();
  final _nameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _emailController = TextEditingController();
  final _parentEmailController = TextEditingController();
  final _mediumController = TextEditingController();
  /// RawAutocomplete needs a focus node alongside the controller it is given.
  final _mediumFocus = FocusNode();
  final _aadharController = TextEditingController();
  final _emisController = TextEditingController();
  final _umisController = TextEditingController();
  final _scholarshipTypeController = TextEditingController();
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _pinController = TextEditingController();
  final _batchController = TextEditingController();
  final _prevSchoolController = TextEditingController();
  final _prevClassController = TextEditingController();
  final _prevPercentController = TextEditingController();
  final _fatherNameController = TextEditingController();
  final _fatherMobileController = TextEditingController();
  final _motherNameController = TextEditingController();
  final _motherMobileController = TextEditingController();
  final _guardianNameController = TextEditingController();
  final _guardianMobileController = TextEditingController();
  final _fatherOccController = TextEditingController();
  final _motherOccController = TextEditingController();
  final _guardianOccController = TextEditingController();
  final _payNameController = TextEditingController();
  final _idMark1Controller = TextEditingController();
  final _idMark2Controller = TextEditingController();
  final _payMobileController = TextEditingController();
  final _casteController = TextEditingController();
  final _religionController = TextEditingController();
  final _nationalityController = TextEditingController();
  final _remarksController = TextEditingController();

  String? _gender;
  String? _bloodGroup;
  DateTime? _dob;
  DateTime? _admDate = DateTime.now(); // defaults to today; editable, overwritten when editing
  String? _source;

  /// Seat booked now, studies from NEXT year.
  ///
  /// The student is created in THIS year's schema so the admission collection
  /// can be taken against them, but they owe nothing this year and they do NOT
  /// move up a class at the year change -- the coming year is their first.
  /// Carried to public.admission.preadmission, and from there onto the student
  /// row at allocation.
  bool _preAdmission = false;
  String? _selectedYrId;
  String? _selectedYrLabel;
  String? _selectedCourse;
  String? _selectedClass;
  String? _selectedAdmName;
  String? _selectedQuoName;
  String? _selectedConId;
  /// The GENERAL concession category -- a new admission starts with it
  /// (user, 2026-11-16); still changeable.
  String? get _generalConId => _concessions
      .firstWhere((c) => '${c['condesc'] ?? ''}'.trim().toUpperCase() == 'GENERAL', orElse: () => const {})['con_id']
      ?.toString();
  String? _transportMode; // 'Own' | 'College' (school: 'Institution')
  String? _hostel;        // 'Yes' | 'No'
  /// Government scholarship eligibility, 'Yes' | 'No' | null (not answered).
  /// The type field only appears — and is only required — when this is Yes.
  String? _scholarship;
  String? _selectedCommunity;
  String? _selectedDivision;
  String? _selectedRegSeqId; // chosen register-number sequence (sequence.seq_id)
  String? _regMode; // null = not chosen | 'Manual' | 'Auto'

  static const _regModes = ['Manual', 'Auto'];

  /// The institution's Utilities policy (Setup -> Utilities ->
  /// admission_number_mode): 'AUTO' or 'MANUAL'. Once loaded it LOCKS the Reg No
  /// Mode picker to itself either way. AUTO additionally locks the Register No
  /// field (the sequence fills it); MANUAL leaves that field typed by hand and
  /// takes the Register Sequence picker out of play entirely.
  String? _utilRegMode;
  bool get _regNoLocked => _utilRegMode == 'AUTO' || _regMode == 'Auto';

  /// School says Institution where college says College; stored as
  /// INSTITUTION / COLLEGE, and either code reads back on both.
  static String get _instTransport => isSchool ? 'Institution' : 'College';
  static List<String> get _transportOptions => ['Own', _instTransport];
  static const _hostelOptions = ['Yes', 'No'];
  static const _yesNoOptions = ['Yes', 'No'];

  // ── data ──────────────────────────────────────────────────────────
  /// Shown in the list: admissions whose student is in the current year's
  /// schema, plus PENDING ones (no student yet, waiting for a section).
  List<AdmissionModel> _admissions = [];
  /// Every admission of the institution, all years. Used for the Admission
  /// No. duplicate check and field suggestions, so an older year's number is
  /// never reused.
  List<AdmissionModel> _allAdmissions = [];
  // New admission started with Add Sibling: the brother / sister whose family
  // details were copied (shown as a note; cleared on a fresh form).
  AdmissionModel? _siblingOf;
  List<Map<String, dynamic>> _years = [];
  List<Map<String, dynamic>> _courseList = []; // {cour_id, courname}
  List<Map<String, dynamic>> _classList = [];  // {claname, cour_id}
  List<Map<String, dynamic>> _admissionTypes = [];
  List<Map<String, dynamic>> _quotas = [];
  List<Map<String, dynamic>> _concessions = [];
  List<String> _communities = [];
  List<String> _divisions = [];
  Map<int, String> _divisionById = {};
  List<Map<String, dynamic>> _regSeqs = []; // register-number sequences

  AdmissionModel? _selected; // null → new-admission mode

  /// Values already recorded in one column, for that field's suggestions.
  /// Deduplicated case-insensitively but shown in their original casing, so
  /// "English" and "english" don't both appear. Read from the admission list
  /// already loaded, so it costs no query and grows as new values are entered.
  List<String> _optionsOf(String? Function(AdmissionModel) pick) {
    final seen = <String, String>{};
    for (final a in _allAdmissions) {
      final v = (pick(a) ?? '').trim();
      if (v.isEmpty) continue;
      seen.putIfAbsent(v.toLowerCase(), () => v);
    }
    return seen.values.toList()..sort();
  }

  /// Focus nodes for the suggestion fields. RawAutocomplete needs one
  /// alongside the controller it is given, and they must persist across
  /// rebuilds — so they live here rather than being made in build().
  final _suggestFocus = <String, FocusNode>{};
  FocusNode _focusFor(String key) =>
      _suggestFocus.putIfAbsent(key, () => FocusNode());

  /// Register numbers already in use, upper-cased and trimmed so the check is
  /// case- and space-insensitive ("adm2600001" collides with "ADM2600001").
  /// Built from the admission list that is already loaded, so it costs no extra
  /// query and refreshes with it after every save. CANCELLED admissions are not
  /// in that list, which is deliberate — their number is free to reuse.
  Set<String> get _takenRegNos {
    final own = (_selected?.admno ?? '').trim().toUpperCase();
    return _allAdmissions
        .map((a) => a.admno.trim().toUpperCase())
        .where((n) => n.isNotEmpty && n != own)
        .toSet();
  }

  /// True when the typed Register No already belongs to another admission.
  /// Only meaningful in Manual: in Auto the field is filled from the sequence
  /// and locked, so the user has nothing to correct.
  /// EMIS No. / APAAR ID of this year's students -> their admission no.
  Map<String, String> _studentEmis = {};

  /// The admission no. that already holds the typed EMIS No. / APAAR ID, or
  /// null. One ID belongs to one child; this record's own student is skipped.
  String? get _emisOwner {
    final v = _emisController.text.trim();
    if (v.isEmpty) return null;
    final own = (_selected?.admno ?? '').trim().toUpperCase();
    for (final a in _allAdmissions) {
      if (a.admstatus == 'CANCELLED' || (a.emisno ?? '').trim() != v) continue;
      final n = a.admno.trim().toUpperCase();
      if (n != own && (_selected == null || a.admId != _selected!.admId)) return a.admno.trim();
    }
    final s = _studentEmis[v];
    return (s != null && s != own) ? s : null;
  }

  bool get _regNoDuplicate {
    if (_regNoLocked) return false;
    final v = _admnoController.text.trim().toUpperCase();
    if (v.isEmpty) return false;
    return _takenRegNos.contains(v);
  }
  String _statusFilter = 'ALL';
  String? _courseFilter; // left-list Course filter (null = all courses)
  String? _classFilter;  // left-list Class filter (null = all classes)
  bool _loading = true;
  bool _saving = false;

  // ── wizard step state ────────────────────────────────────────────────
  // 4-step wizard per admission-design.md § 5:
  //   0  document-text  Admission   → Admission
  //   1  user           Applicant   → Applicant
  //   2  book-1         Academic    → Applied For, Additional Details, Previous School
  //   3  people         Family      → Parent / Guardian, Remarks
  int _currentTab = 0;          // detail tab (0..5)
  // Set once Next/Save is pressed with something missing: required fields
  // that are still empty then draw a red border and a short note, instead of
  // the message living only in a snackbar at the bottom of the window.
  bool _showErrors = false;
  int _page = 0;                // left-list page (0-based)
  // Tablet width only (panes stacked): true once a row or New is picked, so
  // the form shows instead of the list. Layout state, not form state.
  bool _narrowDetail = false;
  String? _photoUrl;            // student photo URL (uploaded to storage)
  bool _isUploadingPhoto = false;
  static const _pageSize = 10;
  /// The notebook section the cursor is in (its numeral turns teal).
  int _activeSection = 0;

  static const _tabLabels = [
    'Personal Details', 'Academic Details', 'Parent / Guardian',
    'Address Details', 'Previous School', 'Other Details',
  ];

  static List<String> get _genders => [kBoyLabel, kGirlLabel, 'Other'];
  static const _bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
  static const _sources = ['WALK-IN', 'ONLINE', 'REFERRAL', 'AGENT'];
  // The stored source codes above, as the dropdown shows them. Display only.
  static const _sourceLabels = {'WALK-IN': 'Walk-in', 'ONLINE': 'Online', 'REFERRAL': 'Referral', 'AGENT': 'Agent'};

  @override
  void initState() {
    super.initState();
    for (final c in [
      _fatherNameController, _fatherMobileController, _motherNameController,
      _motherMobileController, _guardianNameController, _guardianMobileController,
    ]) {
      c.addListener(_syncPayer);
    }
    _load();
    _loadRegModeDefault();
  }

  /// What Pay In Charge was last filled with automatically.
  List<String> _autoPayer = const ['', ''];

  /// Pay In Charge follows Father -> Mother -> Guardian (the first with both a
  /// name and a mobile) until the office types its own: a box still empty,
  /// or still holding what was filled automatically, is refilled.
  void _syncPayer() {
    final name = _payNameController.text.trim(), mob = _payMobileController.text.trim();
    final untouched = (name.isEmpty || name == _autoPayer[0]) && (mob.isEmpty || mob == _autoPayer[1]);
    if (!untouched) return;
    final d = _derivePayer();
    _autoPayer = d;
    if (name != d[0]) _payNameController.text = d[0];
    if (mob != d[1]) _payMobileController.text = d[1];
  }

  /// Seeds the Reg No Mode from the institution's Utilities setting
  /// (admission_number_mode: AUTO -> 'Auto', else 'Manual'). Only applied when
  /// the user hasn't already picked a mode this session.
  Future<void> _loadRegModeDefault() async {
    final s = await SupabaseService.getInstitutionSettings(_insId);
    if (!mounted) return;
    final mode = (s['admission_number_mode'] ?? 'MANUAL').toUpperCase() == 'AUTO'
        ? 'AUTO'
        : 'MANUAL';
    setState(() {
      _utilRegMode = mode;
      // The Utilities value is a policy in BOTH directions, not a default: the
      // picker mirrors it and is locked, so AUTO can't be typed around and
      // MANUAL can't silently start consuming the sequence.
      _regMode = mode == 'AUTO' ? 'Auto' : 'Manual';
    });
    _maybeAutoPickRegSeq();
  }

  /// Once the Reg No Mode and register sequences are both loaded, auto-select the
  /// first sequence and fill the suggested Register No — so Auto is fully
  /// automatic (no manual pick) and Manual still shows a suggestion. No-op while
  /// editing an existing admission, or once a sequence is already chosen.
  void _maybeAutoPickRegSeq() {
    if (!mounted || _readonly || _selected != null) return;
    // MANUAL: no sequence is used at all — clear any leftover pick so the
    // Register Sequence field stays empty and the number is typed by hand.
    if (!_regNoLocked) {
      if (_selectedRegSeqId != null) setState(() => _selectedRegSeqId = null);
      return;
    }
    // AUTO: default to the first sequence and generate the number into the
    // (locked) Register No field.
    if (_regSeqs.isEmpty || _selectedRegSeqId != null) return;
    if (_admnoController.text.trim().isNotEmpty) return;
    // Division-wise: the standard decides; until one is picked, the general
    // sequence (if any) is shown.
    if (_seqByDivision) {
      setState(() => _pickDivision(_divisionOfCourse(_selectedCourse)));
      return;
    }
    final seq = _regSeqs.first;
    setState(() {
      _selectedRegSeqId = seq['seq_id'].toString();
      _admnoController.text = _buildRegNo(seq);
    });
  }

  @override
  void dispose() {
    _mediumFocus.dispose();
    for (final f in _suggestFocus.values) {
      f.dispose();
    }
    for (final c in [
      _searchController, _admnoController, _nameController, _mobileController,
      _emailController, _aadharController, _emisController, _umisController,
      _scholarshipTypeController,
      _addressController,
      _cityController, _stateController, _pinController, _batchController,
      _prevSchoolController, _prevClassController, _prevPercentController,
      _fatherNameController, _fatherMobileController, _motherNameController,
      _motherMobileController, _guardianNameController, _guardianMobileController,
      _fatherOccController, _motherOccController, _guardianOccController,
      _payNameController, _payMobileController, _idMark1Controller, _idMark2Controller,
      _casteController, _religionController, _nationalityController,
      _parentEmailController, _mediumController,
      _remarksController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    final insId = _insId;
    try {
      final results = await Future.wait<dynamic>([
        AdmissionService.getAdmissions(insId),
        SupabaseService.getYears(insId),
        SupabaseService.fromSchema('course').select('*').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.getAdmissionTypes(insId),
        SupabaseService.getQuotas(insId),
        SupabaseService.getConcessions(insId),
        SupabaseService.fromSchema('community').select('comname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('sequence').select('*').eq('actname', 'REGNO').eq('activestatus', 1).order('seq_id', ascending: true),
        // Admission Master -> Division (may be empty or missing)
        SupabaseService.fromSchema('division').select('div_id, divname').eq('ins_id', insId).eq('activestatus', 1).then((v) => v, onError: (_) => <dynamic>[]),
        // Admission numbers of this year's students (null if it can't be read:
        // then nothing is hidden).
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
                .select('stuadmno, emisno').eq('ins_id', insId))
            .then<Set<String>?>((rows) {
              // Students' EMIS / APAAR IDs too: the EMIS / APAAR ID screen
              // edits them on the student, not on the admission.
              _studentEmis = {
                for (final r in rows)
                  if ('${r['emisno'] ?? ''}'.trim().isNotEmpty)
                    '${r['emisno']}'.trim(): '${r['stuadmno'] ?? ''}'.trim().toUpperCase(),
              };
              return rows.map((r) => '${r['stuadmno'] ?? ''}'.trim().toUpperCase()).toSet();
            }, onError: (_) => null),
      ]);
      if (!mounted) return;
      setState(() {
        _allAdmissions = results[0] as List<AdmissionModel>;
        final thisYear = results[10] as Set<String>?;
        _admissions = thisYear == null
            ? _allAdmissions
            : _allAdmissions.where((a) =>
                a.admstatus == AdmissionStatus.pending ||
                thisYear.contains(a.admno.trim().toUpperCase())).toList();
        _years = results[1] as List<Map<String, dynamic>>;
        _courseList = List<Map<String, dynamic>>.from(results[2] as List);
        _classList = List<Map<String, dynamic>>.from(results[3] as List);
        _admissionTypes = results[4] as List<Map<String, dynamic>>;
        _quotas = results[5] as List<Map<String, dynamic>>;
        _concessions = results[6] as List<Map<String, dynamic>>;
        // the form already open for a new admission gets GENERAL too
        if (_selected == null && _selectedConId == null) _selectedConId = _generalConId;
        _communities = (results[7] as List)
            .map((e) => e['comname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty).toSet().toList()..sort();
        _regSeqs = List<Map<String, dynamic>>.from(results[8] as List);
        _divisionById = {
          for (final e in (results[9] as List))
            if ((e as Map)['div_id'] != null) (e['div_id'] as num).toInt(): '${e['divname'] ?? ''}'.trim(),
        };
        _divisions = (results[9] as List)
            .map((e) => (e as Map)['divname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty).toSet().toList()..sort();
        _loading = false;
      });
      _maybeAutoPickRegSeq();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Failed to load admissions. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  // ── course / class options ────────────────────────────────────────
  List<String> get _courseNames =>
      (_courseList.map((e) => e['courname']?.toString().trim() ?? '')
          .where((s) => s.isNotEmpty).toSet().toList()
        ..sort());

  /// Class names belonging to [courname] (matched via class.cour_id). When
  /// no course is selected (null/empty), returns all classes.
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

  // ── status helpers ────────────────────────────────────────────────
  Color _statusColor(String s) {
    switch (s) {
      case AdmissionStatus.pending: return AppColors.warning;
      case AdmissionStatus.allocated: return AppColors.success;
      case AdmissionStatus.cancelled: return AppColors.textLight;
      default: return AppColors.textSecondary;
    }
  }

  Map<String, int> get _statusCounts {
    final m = <String, int>{};
    for (final a in _admissions) {
      m[a.admstatus] = (m[a.admstatus] ?? 0) + 1;
    }
    return m;
  }

  // Effective class of an admission — allocated class once enrolled, else the
  // preferred class it was admitted into.
  String _admClass(AdmissionModel a) =>
      (a.isAllocated && (a.allocatedclass ?? '').isNotEmpty)
          ? a.allocatedclass!
          : (a.stuclass ?? '');

  // Course / class options for the left-list filters — derived from the actual
  // admissions so only courses/classes that have records appear. Classes narrow
  // to the selected course.
  List<String> get _courseOptions =>
      (_admissions.map((a) => a.courname ?? '').where((c) => c.isNotEmpty).toSet().toList()..sort());
  List<String> get _classOptions {
    final inCourse = _admissions.where((a) => _courseFilter == null || (a.courname ?? '') == _courseFilter);
    return (inCourse.map(_admClass).where((c) => c.isNotEmpty).toSet().toList()..sort());
  }

  List<AdmissionModel> get _filtered {
    final q = _searchController.text.trim().toLowerCase();
    return _admissions.where((a) {
      if (_statusFilter != 'ALL' && a.admstatus != _statusFilter) return false;
      if (_courseFilter != null && (a.courname ?? '') != _courseFilter) return false;
      if (_classFilter != null && _admClass(a) != _classFilter) return false;
      if (q.isEmpty) return true;
      return a.stuname.toLowerCase().contains(q) ||
          a.admno.toLowerCase().contains(q) ||
          (a.stumobile ?? '').toLowerCase().contains(q);
    }).toList();
  }

  bool get _readonly => _selected?.isAllocated ?? false;
  // Allocated records stay editable now; only the core identity / enrolment
  // fields (Register No, Admission Date, Course, Class, Admission Type) lock —
  // the field builders take a per-field `locked` flag and these pass
  // `_coreLocked`. Batch is deliberately NOT among them: it names the intake
  // year and changing it moves no student and breaks no link.
  bool get _coreLocked => _selected?.isAllocated ?? false;
  // A TC has been issued (leaving status) → the whole record is view-only.
  bool get _tcLocked => _selected?.isTcLocked ?? false;

  // ── form lifecycle ────────────────────────────────────────────────
  void _newAdmission() {
    setState(() {
      _selected = null;
      _currentTab = 0;
      _showErrors = false;   // a fresh form starts unmarked
      _photoUrl = null;
      // Default the admission date to today; the user can still change it.
      _admDate = DateTime.now();
      _dob = null;
      _gender = null;
      _bloodGroup = null;
      _source = null;
      _preAdmission = false;
      _selectedCourse = null;
      _selectedClass = null;
      _selectedAdmName = null;
      _selectedQuoName = null;
      _selectedConId = _generalConId;
      _transportMode = null;
      _hostel = null;
      _scholarship = null;
      _selectedCommunity = null;
      _selectedDivision = null;
      _selectedRegSeqId = null;
      // The Utilities policy SURVIVES a New. It is not something the clerk
      // picked, it is how this institution numbers admissions -- and the picker
      // is locked to it, so clearing it left a required field empty that could
      // not be filled in, and the form refused to save with 'Select Reg No
      // Mode'. _maybeAutoPickRegSeq below puts the sequence and the suggested
      // Register No back with it.
      _regMode = _utilRegMode == null
          ? null
          : (_utilRegMode == 'AUTO' ? 'Auto' : 'Manual');
      _selectedYrId = null;
      _selectedYrLabel = null;
      _admnoController.clear();
      for (final c in [
        _nameController, _mobileController, _emailController, _aadharController,
        _emisController, _umisController, _scholarshipTypeController,
        _addressController, _cityController, _stateController,
        _pinController, _batchController, _prevSchoolController,
        _prevClassController, _prevPercentController, _fatherNameController,
        _fatherMobileController, _motherNameController, _motherMobileController,
        _guardianNameController, _guardianMobileController,
        _fatherOccController, _motherOccController, _guardianOccController,
        _payNameController, _payMobileController, _idMark1Controller, _idMark2Controller,
        _casteController, _religionController, _nationalityController,
        _parentEmailController, _mediumController,
        _remarksController,
      ]) {
        c.clear();
      }
      _autoPayer = const ['', ''];
      _siblingOf = null;
    });
    // AUTO institutions get their sequence and next number straight back, so
    // the clerk can type the student in without touching numbering at all.
    _maybeAutoPickRegSeq();
  }

  void _populate(AdmissionModel a) {
    setState(() {
      _siblingOf = null;
      _selected = a;
      _currentTab = 0;
      _showErrors = false;   // a fresh form starts unmarked
      _photoUrl = a.stuphoto;
      _admDate = a.admdate;
      _dob = a.studob;
      _gender = a.genderLabel;
      _bloodGroup = _bloodGroups.contains(a.stubloodgrp) ? a.stubloodgrp : null;
      _source = _sources.contains(a.admsource) ? a.admsource : null;
      _preAdmission = (a.preadmission ?? 0) == 1;
      _selectedYrId = a.yrId != 0 ? a.yrId.toString() : _selectedYrId;
      _selectedYrLabel = a.yrlabel.isNotEmpty ? a.yrlabel : _selectedYrLabel;
      _selectedCourse = _courseNames.contains(a.courname) ? a.courname : null;
      _selectedClass = _classNamesFor(a.courname).contains(a.stuclass) ? a.stuclass : null;
      _selectedAdmName = a.admname;
      _selectedQuoName = a.quoname;
      _selectedConId = a.conId?.toString();
      _transportMode = a.transportmode == 'OWN'
          ? 'Own'
          : (a.transportmode == 'COLLEGE' || a.transportmode == 'INSTITUTION') ? _instTransport : null;
      _hostel = a.hostel == 'Y' ? 'Yes' : a.hostel == 'N' ? 'No' : null;
      _admnoController.text = a.admno;
      _nameController.text = a.stuname;
      _mobileController.text = a.stumobile ?? '';
      _emailController.text = a.stuemail ?? '';
      _mediumController.text = a.medium ?? '';
      _parentEmailController.text = a.paremail ?? '';
      _aadharController.text = a.aadharno ?? '';
      _emisController.text = a.emisno ?? '';
      _umisController.text = a.umisno ?? '';
      _scholarship = a.scholarship == 'Y' ? 'Yes' : a.scholarship == 'N' ? 'No' : null;
      _scholarshipTypeController.text = a.scholarshiptype ?? '';
      _addressController.text = a.stuaddress ?? '';
      _cityController.text = a.stucity ?? '';
      _stateController.text = a.stustate ?? '';
      _pinController.text = a.stupin ?? '';
      _batchController.text = a.batch ?? '';
      _prevSchoolController.text = a.prevschool ?? '';
      _prevClassController.text = a.prevclass ?? '';
      _prevPercentController.text = a.prevpercent?.toString() ?? '';
      _fatherNameController.text = a.fathername ?? '';
      _fatherMobileController.text = a.fathermobile ?? '';
      _motherNameController.text = a.mothername ?? '';
      _motherMobileController.text = a.mothermobile ?? '';
      _guardianNameController.text = a.guardianname ?? '';
      _guardianMobileController.text = a.guardianmobile ?? '';
      _selectedCommunity = _communities.contains(a.community) ? a.community : null;
      _selectedDivision = (a.division ?? '').trim().isEmpty ? null : a.division!.trim();
      _selectedRegSeqId = null; // existing record already has a Register No
      _regMode = 'Manual';
      _casteController.text = a.caste ?? '';
      _religionController.text = a.religion ?? '';
      _nationalityController.text = a.nationality ?? '';
      _fatherOccController.text = a.fatheroccupation ?? '';
      _motherOccController.text = a.motheroccupation ?? '';
      _guardianOccController.text = a.guardianoccupation ?? '';
      _payNameController.text = a.payincharge ?? '';
      _payMobileController.text = a.payinchargemob ?? '';
      _autoPayer = _derivePayer();
      _remarksController.text = a.admremarks ?? '';
      _idMark1Controller.text = a.idmark1 ?? '';
      _idMark2Controller.text = a.idmark2 ?? '';
    });
  }

  String? _genderCode(String? g) => genderCode(g);

  /// The next counter value a register sequence would issue.
  int _nextRegNum(Map<String, dynamic> seq) {
    final cur = (seq['seqcurno'] as num?)?.toInt() ?? 0;
    final start = (seq['seqstart'] as num?)?.toInt() ?? 1;
    return cur < start ? start : cur + 1;
  }

  /// Build the formatted register number for a sequence (prefix/suffix + pad).
  String _buildRegNo(Map<String, dynamic> seq) {
    final width = (seq['seqwidth'] as num?)?.toInt() ?? 0;
    final padded = _nextRegNum(seq).toString().padLeft(width, '0');
    final affix = seq['seqprefix']?.toString() ?? '';
    return (seq['isprefix']?.toString() ?? 'Y') == 'Y' ? '$affix$padded' : '$padded$affix';
  }

  /// Admissions on the same Pay In Charge mobile -- the brothers / sisters
  /// that share one parent record (and one parent-app login) once allocated.
  List<AdmissionModel> _siblingsOnNumber() {
    final mob = _payMobileController.text.trim();
    if (mob.length < 10) return const [];
    return _allAdmissions.where((a) =>
        a.admstatus != 'CANCELLED' &&
        (a.payinchargemob ?? '').trim() == mob &&
        (_selected == null || a.admId != _selected!.admId)).toList();
  }

  /// Add Sibling: pick an existing student and copy the family details
  /// (parents, guardian, pay in charge, address, community) into this new
  /// admission. The same Pay In Charge mobile makes section allocation reuse
  /// that family's parent record, so both children share one parent login.
  Future<void> _pickSibling() async {
    final search = TextEditingController();
    final picked = await showDialog<AdmissionModel>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final q = search.text.trim().toLowerCase();
        final list = _allAdmissions.where((a) {
          if (a.admstatus == 'CANCELLED') return false;
          if (q.isEmpty) return true;
          return [a.stuname, a.admno, a.stuclass, a.fathername, a.mothername, a.guardianname,
                  a.payincharge, a.payinchargemob, a.fathermobile, a.mothermobile]
              .any((v) => (v ?? '').toLowerCase().contains(q));
        }).take(50).toList();
        return AlertDialog(
          title: const Text('Add Sibling'),
          content: SizedBox(
            width: 560.w,
            height: 460.h,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(schoolTerm('Find the brother or sister already in the school. Their family details are copied into this admission.'),
                    style: AppUI.muted),
                SizedBox(height: 10.h),
                AppSearchField(
                  controller: search,
                  autofocus: true,
                  hintText: schoolTerm('Search by name, register no., parent name or mobile'),
                  onChanged: (_) => setD(() {}),
                ),
                SizedBox(height: 8.h),
                Expanded(
                  child: list.isEmpty
                      ? AppUI.empty(title: 'No student found', why: 'Try another name, number or mobile.', icon: 'people')
                      : ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                          itemBuilder: (_, i) {
                            final a = list[i];
                            final parent = [a.payincharge, a.payinchargemob]
                                .where((v) => (v ?? '').trim().isNotEmpty).join(' · ');
                            return ListTile(
                              dense: true,
                              leading: AppIcon('user', size: 18, color: AppColors.primary),
                              title: Text(a.stuname, style: AppUI.cell),
                              subtitle: Text(
                                  [a.admno, a.stuclass ?? '', if (parent.isNotEmpty) parent]
                                      .where((v) => v.trim().isNotEmpty).join('  |  '),
                                  style: AppUI.muted),
                              onTap: () => Navigator.pop(ctx, a),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ],
        );
      }),
    );
    search.dispose();
    if (picked == null || !mounted) return;
    _applySibling(picked);
  }

  void _applySibling(AdmissionModel s) {
    setState(() {
      _fatherNameController.text = s.fathername ?? '';
      _fatherMobileController.text = s.fathermobile ?? '';
      _fatherOccController.text = s.fatheroccupation ?? '';
      _motherNameController.text = s.mothername ?? '';
      _motherMobileController.text = s.mothermobile ?? '';
      _motherOccController.text = s.motheroccupation ?? '';
      _guardianNameController.text = s.guardianname ?? '';
      _guardianMobileController.text = s.guardianmobile ?? '';
      _guardianOccController.text = s.guardianoccupation ?? '';
      _parentEmailController.text = s.paremail ?? '';
      // Exactly the sibling's payer, so allocation finds the same parent record.
      _payNameController.text = s.payincharge ?? '';
      _payMobileController.text = s.payinchargemob ?? '';
      _autoPayer = _derivePayer();
      _addressController.text = s.stuaddress ?? '';
      _cityController.text = s.stucity ?? '';
      _stateController.text = s.stustate ?? '';
      _pinController.text = s.stupin ?? '';
      if (_communities.contains(s.community)) _selectedCommunity = s.community;
      _casteController.text = s.caste ?? '';
      _religionController.text = s.religion ?? '';
      _nationalityController.text = s.nationality ?? '';
      _siblingOf = s;
    });
    _snack('Family details copied from ${s.stuname}. Enter this student\'s own details and save.', AppColors.success);
  }

  /// Pay-in-charge is auto-derived from the parent/guardian details with the
  /// priority Father → Mother → Guardian (first one that has BOTH a name and a
  /// mobile number). Returns [name, mobile], or ['', ''] if none qualify.
  List<String> _derivePayer() {
    final f = _fatherNameController.text.trim(), fm = _fatherMobileController.text.trim();
    final m = _motherNameController.text.trim(), mm = _motherMobileController.text.trim();
    final g = _guardianNameController.text.trim(), gm = _guardianMobileController.text.trim();
    // Prefer the first parent with both Name and Mobile, then fall back to the
    // first with a Name — so Pay In Charge is auto-filled from the parent
    // details (Father → Mother → Guardian).
    if (f.isNotEmpty && fm.isNotEmpty) return [f, fm];
    if (m.isNotEmpty && mm.isNotEmpty) return [m, mm];
    if (g.isNotEmpty && gm.isNotEmpty) return [g, gm];
    if (f.isNotEmpty) return [f, fm];
    if (m.isNotEmpty) return [m, mm];
    if (g.isNotEmpty) return [g, gm];
    return ['', ''];
  }

  /// The Pre-admission tick, with the consequence spelled out next to it.
  ///
  /// It is a money decision, not a preference: ticking it means no fee demand
  /// is raised for this student this year and the year change leaves them in
  /// the class shown above.
  Widget _preAdmissionField() {
    return InkWell(
      onTap: _coreLocked ? null : () => setState(() => _preAdmission = !_preAdmission),
      borderRadius: BorderRadius.circular(8.r),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 4.h),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 34.w,
            child: Checkbox(
              value: _preAdmission,
              visualDensity: VisualDensity.compact,
              onChanged: _coreLocked
                  ? null
                  : (v) => setState(() => _preAdmission = v == true),
            ),
          ),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Pre-admission (starts next academic year)',
                      style: TextStyle(
                          fontSize: 13.sp,
                          fontWeight: FontWeight.w700,
                          color: _preAdmission
                              ? AppColors.primary
                              : AppColors.textPrimary)),
                  SizedBox(height: 2.h),
                  Text(
                      schoolTerm('Collect next year\'s fees now. No fee demand is raised '
                      'for the current academic year, and Year End Process keeps the '
                      'student in the chosen class instead of promoting them.'),
                      style: AppUI.muted),
                ]),
          ),
        ]),
      ),
    );
  }

  Map<String, dynamic> _formData() {
    final auth = context.read<AuthProvider>();
    String? t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    // Pay In Charge as shown on the form (filled from a parent, or typed).
    final payer = [_payNameController.text.trim(), _payMobileController.text.trim()];
    return {
      'ins_id': auth.insId ?? 1,
      'inscode': auth.inscode ?? '',
      // yr_id/yrlabel removed from public.admission — the year is derived from
      // the schema during allocate_admission_to_student.
      'admno': _admnoController.text.trim(),
      'admdate': _admDate?.toIso8601String().split('T').first,
      'admsource': _source,
      'preadmission': _preAdmission ? 1 : 0,
      'stuname': _nameController.text.trim(),
      'stugender': _genderCode(_gender) ?? 'M',
      'studob': _dob?.toIso8601String().split('T').first,
      'stumobile': t(_mobileController),
      'stuemail': t(_emailController),
      'aadharno': t(_aadharController),
      'emisno': t(_emisController),
      if (!isSchool) 'umisno': t(_umisController), // a school has no UMIS
      'stuaddress': t(_addressController),
      'stucity': t(_cityController),
      'stustate': t(_stateController),
      'stupin': t(_pinController),
      'stubloodgrp': _bloodGroup,
      'stuphoto': _photoUrl,
      'courname': _selectedCourse,
      'stuclass': _selectedClass,
      // A school has no admission type / quota / batch columns.
      if (!isSchool) 'admname': _selectedAdmName,
      if (!isSchool) 'quoname': _selectedQuoName,
      // Entity IDs resolved from the selected master names, so public.admission
      // carries them the same way the student import does.
      'cour_id': _idFor(_courseList, 'courname', _selectedCourse, 'cour_id'),
      'admit_cour_id': _idFor(_courseList, 'courname', _selectedCourse, 'cour_id'),
      'cla_id': _classIdFor(_selectedClass, _idFor(_courseList, 'courname', _selectedCourse, 'cour_id')),
      if (!isSchool) 'admtype_id': _idFor(_admissionTypes, 'admname', _selectedAdmName, 'adm_id'),
      if (!isSchool) 'quo_id': _idFor(_quotas, 'quoname', _selectedQuoName, 'quo_id'),
      // Admitted year defaults to the current academic year.
      'admittyear': _years.isNotEmpty ? _years.first['yrlabel']?.toString() : null,
      'medium': t(_mediumController),
      'con_id': _selectedConId != null ? int.tryParse(_selectedConId!) : null,
      'stucondesc': _selectedConId != null
          ? _concessions.firstWhere((c) => c['con_id'].toString() == _selectedConId,
              orElse: () => const {})['condesc']
          : null,
      if (!isSchool) 'batch': t(_batchController),
      'prevschool': t(_prevSchoolController),
      'prevclass': t(_prevClassController),
      'prevpercent': _prevPercentController.text.trim().isEmpty
          ? null
          : double.tryParse(_prevPercentController.text.trim()),
      'fathername': t(_fatherNameController),
      'fathermobile': t(_fatherMobileController),
      'fatheroccupation': t(_fatherOccController),
      'mothername': t(_motherNameController),
      'mothermobile': t(_motherMobileController),
      'motheroccupation': t(_motherOccController),
      'guardianname': t(_guardianNameController),
      'guardianmobile': t(_guardianMobileController),
      'guardianoccupation': t(_guardianOccController),
      'payincharge': payer[0].isEmpty ? null : payer[0],
      'payinchargemob': payer[1].isEmpty ? null : payer[1],
      'paremail': t(_parentEmailController),
      'community': _selectedCommunity,
      'division': _selectedDivision,
      'caste': t(_casteController),
      'religion': t(_religionController),
      'nationality': t(_nationalityController),
      'transportmode': _transportMode == 'Own'
          ? 'OWN'
          : _transportMode == _instTransport ? _instTransport.toUpperCase() : null,
      'hostel': _hostel == 'Yes' ? 'Y' : _hostel == 'No' ? 'N' : null,
      'scholarship': _scholarship == 'Yes' ? 'Y' : _scholarship == 'No' ? 'N' : null,
      // Only meaningful when eligible — a leftover type from a Yes that was
      // switched back to No would otherwise be saved.
      'scholarshiptype': _scholarship == 'Yes' ? t(_scholarshipTypeController) : null,
      'admremarks': t(_remarksController),
      'idmark1': t(_idMark1Controller),
      'idmark2': t(_idMark2Controller),
      'createdby': auth.userName,
    };
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

  /// A filled field must be exactly [n] characters; an empty one is fine (the
  /// mandatory check, where there is one, is separate).
  bool _lenOk(TextEditingController c, int n) {
    final v = c.text.trim();
    return v.isEmpty || v.length == n;
  }

  /// Batch is an academic-year span: YYYY-YYYY, 9 characters, second year after
  /// the first (e.g. 2026-2029).
  bool _batchOk(String v) {
    final m = RegExp(r'^(\d{4})-(\d{4})$').firstMatch(v);
    if (m == null) return false;
    return int.parse(m.group(2)!) > int.parse(m.group(1)!);
  }

  /// Validates only the fields that live on [tab]. Next calls this so a missing
  /// required field is caught on the tab that owns it, instead of surfacing at
  /// Save several tabs later with no clue where to go. Tabs 3-5 (Address,
  /// Previous School, Other Details) carry no required fields; Address checks only
  /// that a filled Pin Code is 6 digits.
  bool _validateTab(int tab) {
    switch (tab) {
      case 0: // Personal Details
        if (_nameController.text.trim().isEmpty || _gender == null || _dob == null) {
          _snack('Personal Details: enter Full Name, Gender and Date of Birth.',
              AppColors.error);
          return false;
        }
        // Length rules apply only to a filled field — neither is mandatory.
        if (!_lenOk(_mobileController, 10)) {
          _snack('Mobile must be exactly 10 digits.', AppColors.error);
          return false;
        }
        if (!_lenOk(_aadharController, 12)) {
          _snack('Aadhaar No. must be exactly 12 digits.', AppColors.error);
          return false;
        }
        if (emisInvalid(_emisController.text)) {
          _snack('$kEmisRuleMsg.', AppColors.error);
          return false;
        }
        final emisOwner = _emisOwner;
        if (emisOwner != null) {
          _snack('EMIS No. / APAAR ID ${_emisController.text.trim()} is already used by $emisOwner. Enter this student\'s own ID.',
              AppColors.error);
          return false;
        }
        return true;
      case 1: // Academic Details
        if (_regMode == null) {
          _snack(schoolTerm('Select the register number mode (Manual or Auto).'), AppColors.error);
          return false;
        }
        // Division-wise: a standard whose division cannot be numbered is
        // stopped here, with where to create the sequence.
        if (_seqByDivision && _regNoLocked && _selected == null && _selectedCourse != null) {
          final c = regSeqFor(_regSeqs, _divisionOfCourse(_selectedCourse));
          if (c.blocked) {
            _snack(c.notice!, AppColors.error);
            return false;
          }
        }
        if (_admnoController.text.trim().isEmpty) {
          _snack(schoolTerm('Enter the register number.'), AppColors.error);
          return false;
        }
        // A manually typed number can collide with an existing admission; the
        // sequence-generated one can't.
        if (_regNoDuplicate) {
          _snack(schoolTerm('Register No. ${_admnoController.text.trim()} is already used by another admission. Enter a different number.'),
              AppColors.error);
          return false;
        }
        if (_admDate == null) {
          _snack('Select the date of admission.', AppColors.error);
          return false;
        }
        // Course + Class are mandatory — the student is enrolled straight into
        // the class at admission (Class Allocation is for Fast Admission rows).
        if (_selectedCourse == null || _selectedCourse!.trim().isEmpty) {
          _snack(schoolTerm('Select a course.'), AppColors.error);
          return false;
        }
        // School: the section is only a suggestion here -- Section Allocation
        // places the student, so it may be left blank.
        if (!isSchool && (_selectedClass == null || _selectedClass!.trim().isEmpty)) {
          _snack(schoolTerm('Select a class.'), AppColors.error);
          return false;
        }
        if (!isSchool && (_selectedAdmName == null || _selectedAdmName!.trim().isEmpty)) {
          _snack('Select an admission type.', AppColors.error);
          return false;
        }
        // Eligibility on its own says nothing about which scheme; a Yes with no
        // type is the answer half-given.
        if (_scholarship == 'Yes' && _scholarshipTypeController.text.trim().isEmpty) {
          _snack('Enter the Scholarship Type, or set Scholarship Eligible to No.',
              AppColors.error);
          return false;
        }
        // Batch is an academic-year span: 9 characters, YYYY-YYYY, consecutive.
        final batch = _batchController.text.trim();
        if (isSchool) return true; // a school has no batch
        if (batch.isEmpty) {
          _snack('Enter the batch, e.g. 2026-2029.', AppColors.error);
          return false;
        }
        if (!_batchOk(batch)) {
          _snack('Batch must be 9 characters in the form YYYY-YYYY, e.g. 2026-2029.',
              AppColors.error);
          return false;
        }
        return true;
      case 2: // Parent / Guardian
        // Pay-in-charge is auto-derived from a parent/guardian, so at least one
        // of Father / Mother / Guardian must have both a name and a mobile.
        if (_derivePayer()[1].isEmpty) {
          _snack('Enter a name and mobile number for at least one parent or guardian. That person becomes the Pay In Charge.',
              AppColors.error);
          return false;
        }
        for (final e in {
          'Father': _fatherMobileController,
          'Mother': _motherMobileController,
          'Guardian': _guardianMobileController,
        }.entries) {
          if (!_lenOk(e.value, 10)) {
            _snack('${e.key} Mobile must be exactly 10 digits.', AppColors.error);
            return false;
          }
        }
        if (_payNameController.text.trim().isEmpty || _payMobileController.text.trim().isEmpty) {
          _snack('Enter the Payment In Charge and Pay In Charge Mobile.', AppColors.error);
          return false;
        }
        // The Pay In Charge mobile links brothers and sisters to one parent
        // record, so a placeholder (9999999999) would join unrelated families.
        final payErr = payerMobileError('Pay In Charge Mobile', _payMobileController.text);
        if (payErr != null) {
          _snack(payErr, AppColors.error);
          return false;
        }
        return true;
      case 3: // Address Details
        if (!_lenOk(_pinController, 6)) {
          _snack('Pin Code must be exactly 6 digits.', AppColors.error);
          return false;
        }
        return true;
      default:
        return true;
    }
  }

  /// Save-time check — runs every tab's rules in order and, on the first
  /// failure, switches to the tab that owns it so the flagged field is on
  /// screen. Direct tab clicks stay unrestricted (you must be able to go back
  /// and fix things); this is the net that makes that safe.
  bool _validate() {
    for (var t = 0; t < _tabLabels.length; t++) {
      if (!_validateTab(t)) {
        setState(() => _showErrors = true);
        return false;
      }
    }
    return true;
  }

  Future<void> _save() async {
    if (!_validate()) return;
    final userName = context.read<AuthProvider>().userName; // capture before async gaps
    setState(() => _saving = true);
    try {
      if (_selected == null) {
        // The number is CLAIMED AT SAVE, not computed at form-open: two
        // operators with the form open at once used to get the same number.
        // In Auto -- or Manual while the typed value is still the suggestion --
        // the server hands out the next number (claim_reg_no) and that one is
        // used for both the admission and the allocation. A number the operator
        // typed themselves is never replaced.
        // Division-wise: always the sequence of the standard being saved.
        if (_seqByDivision && _regNoLocked) {
          _selectedRegSeqId = regSeqFor(_regSeqs, _divisionOfCourse(_selectedCourse)).seq?['seq_id']?.toString();
        }
        final seq = _selectedRegSeqId == null
            ? const <String, dynamic>{}
            : _regSeqs.firstWhere((s) => s['seq_id'].toString() == _selectedRegSeqId, orElse: () => const {});
        final usesSequence = seq.isNotEmpty &&
            (_regMode == 'Auto' || _regNoLocked || _admnoController.text.trim() == _buildRegNo(seq));
        // School: save_admission numbers it inside the save (no lost numbers,
        // taken ones skipped). College: claim first, then save, as before.
        String? claimed;
        final int admId;
        if (isSchool && usesSequence) {
          final r = await AdmissionService.addAdmissionNumbered(_formData(), int.parse(_selectedRegSeqId!));
          admId = r.admId;
          claimed = r.admno;
          _admnoController.text = r.admno;
        } else {
          claimed = usesSequence ? await AdmissionService.claimRegNo(int.parse(_selectedRegSeqId!)) : null;
          if (claimed != null) _admnoController.text = claimed;
          admId = await AdmissionService.addAdmission(_formData());
        }
        final savedNo = _admnoController.text.trim();
        // No claim_reg_no on this database: advance the counter from the client
        // as before (racy, but it still saves).
        if (claimed == null && usesSequence) {
          await AdmissionService.bumpRegSeqCurrent(int.parse(_selectedRegSeqId!), _nextRegNum(seq));
        }
        // Class selected → move straight to students; no class → leave the
        // admission pending for Class Allocation. A school always waits for
        // Section Allocation (the chosen section only pre-fills it there).
        var enrolled = false;
        if (!isSchool && _selectedClass != null && _selectedClass!.trim().isNotEmpty) {
          try {
            await AdmissionService.allocateClass(
              admId: admId,
              className: _selectedClass!.trim(),
              stuadmno: _admnoController.text.trim(),
              allocatedBy: userName,
            );
            enrolled = true;
          } catch (_) {
            // Admission is saved; allocation can be retried from Class Allocation.
          }
        }
        // Names the number: it can differ from the preview another operator
        // claimed first.
        _snack(enrolled
                ? 'Admission $savedNo saved and added to Students.'
                : isSchool
                    ? 'Admission saved as $savedNo. Allocate the section in Section Allocation.'
                    : 'Admission $savedNo saved.',
            AppColors.success);
        // Reset the register fields so _load()'s auto-pick fills the NEXT number
        // (the sequence counter was just bumped above).
        _admnoController.clear();
        _selectedRegSeqId = null;
      } else {
        await AdmissionService.updateAdmission(_selected!.admId, _formData());
        // A still-PENDING admission now has a class (mandatory) → enrol it now,
        // so nothing is left waiting in Class Allocation.
        var enrolled = false;
        var allocFailed = false;
        if (!isSchool &&
            !_selected!.isAllocated &&
            _selectedClass != null &&
            _selectedClass!.trim().isNotEmpty) {
          try {
            await AdmissionService.allocateClass(
              admId: _selected!.admId,
              className: _selectedClass!.trim(),
              stuadmno: _admnoController.text.trim(),
              allocatedBy: userName,
            );
            enrolled = true;
          } catch (e) {
            allocFailed = true;
            _snack('Admission updated, but the student could not be allocated to the class. ${friendlyError(e)} Allocate them from Class Allocation.',
                AppColors.warning);
          }
        }
        // Every successful save says so -- a pending admission used to be saved
        // silently and the form reset, so it looked lost and was entered again.
        if (!allocFailed) {
          _snack(enrolled ? 'Admission updated and added to Students.' : 'Admission updated.',
              AppColors.success);
        }
      }
      await _load();
      // Full reset (not just deselect) so the next entry starts clean — a
      // lingering admno would insert-collide on the following Save.
      if (mounted) _newAdmission();
    } catch (e) {
      _snack('Could not save the admission. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _cancel() async {
    final a = _selected;
    if (a == null) return;
    final by = context.read<AuthProvider>().userName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Admission'),
        content: Text('Cancel the admission for ${a.stuname}? The record will be marked as cancelled.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Admission')),
          ElevatedButton(
            style: AppUI.danger(ctx),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel Admission'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await AdmissionService.cancelAdmission(a.admId, by: by);
      _snack('Admission cancelled.', AppColors.textSecondary);
      await _load();
      if (mounted) _newAdmission();
    } catch (e) {
      _snack('Could not cancel the admission. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  // Per-institution photo bucket (student-photos-<inscode>), same as Students.
  String _photoBucket(String inscode) => 'student-photos-${inscode.toLowerCase()}';

  /// Pick + upload a student photo to the institution's storage bucket and keep
  /// the public URL in _photoUrl. The URL is saved as stuphoto on save (and
  /// propagated to the enrolled student by save_admission).
  Future<void> _uploadPhoto() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;
    final auth = context.read<AuthProvider>();
    final inscode = auth.inscode ?? 'ins';
    setState(() => _isUploadingPhoto = true);
    try {
      // Ensure the per-institution bucket exists (no-op if already there).
      try {
        await SupabaseService.client.rpc('ensure_student_photo_bucket', params: {'p_inscode': inscode});
      } catch (_) {/* bucket may already exist / RPC absent — upload still tries */}
      final ext = (file.extension ?? 'jpg').toLowerCase();
      const mimeMap = {
        'jpg': 'image/jpeg', 'jpeg': 'image/jpeg',
        'png': 'image/png', 'webp': 'image/webp', 'gif': 'image/gif',
      };
      final mimeType = mimeMap[ext] ?? 'image/jpeg';
      final bucket = _photoBucket(inscode);
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.$ext';
      await SupabaseService.client.storage.from(bucket).uploadBinary(
        fileName, file.bytes!, fileOptions: FileOptions(contentType: mimeType),
      );
      final url = SupabaseService.client.storage.from(bucket).getPublicUrl(fileName);
      if (mounted) setState(() => _photoUrl = url);
    } catch (e) {
      _snack('Could not upload the photo. ${friendlyError(e)} Try a JPG or PNG image.', AppColors.error);
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  // ── build ─────────────────────────────────────────────────────────
  // Master-detail (AppMasterDetail): the searchable, filterable admissions
  // list on the left, the admission form on the right. At tablet width the
  // panes stack -- the list first, the form after a row or New is picked.
  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return AppMasterDetail(
      listTitle: 'Admissions',
      listIcon: 'profile-add',
      listSubtitle: 'All admission records in this institution',
      listActions: [AppUI.chip('${_admissions.length}', AppStatus.info)],
      // Search (name / admission no / mobile) + New.
      search: Row(
        children: [
          Expanded(
            child: AppSearchField(
              controller: _searchController,
              hintText: schoolTerm('Search by name, register no. or mobile'),
              onChanged: (_) => setState(() => _page = 0),
            ),
          ),
          SizedBox(width: 8.w),
          _newButton(),
        ],
      ),
      filters: [
        // Course + Class filters -- pick a course then a class to jump
        // straight to that group of students.
        Row(
          children: [
            Expanded(child: _listFilterDropdown(schoolTerm('All Courses'), _courseFilter, _courseOptions, (v) => setState(() {
                  _courseFilter = v;
                  _page = 0;
                  if (_classFilter != null && !_classOptions.contains(_classFilter)) _classFilter = null;
                }))),
            SizedBox(width: 8.w),
            Expanded(child: _listFilterDropdown(schoolTerm('All Classes'), _classFilter, _classOptions,
                (v) => setState(() { _classFilter = v; _page = 0; }))),
          ],
        ),
        _statusChips(_statusCounts),
      ],
      list: _listBody(filtered),
      footer: (!_loading && filtered.isNotEmpty) ? _paginationBar(filtered.length) : null,
      detail: _buildDetail(),
      showDetail: _narrowDetail,
      onBack: () => setState(() => _narrowDetail = false),
    );
  }

  // ── left panel ────────────────────────────────────────────────────
  Widget _listBody(List<AdmissionModel> filtered) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (filtered.isEmpty) {
      return AppUI.empty(
        title: 'No admissions',
        why: 'No admission records match the current filters. Use Add Admission to add one.',
        icon: 'profile-add',
      );
    }
    final total = filtered.length;
    final pages = (total / _pageSize).ceil();
    final page = _page.clamp(0, pages > 0 ? pages - 1 : 0);
    final start = page * _pageSize;
    final end = (start + _pageSize) > total ? total : (start + _pageSize);
    final slice = filtered.sublist(start, end);
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: slice.length,
      itemBuilder: (_, i) => _listTile(slice[i], start + i),
    );
  }

  Widget _newButton() {
    return ElevatedButton.icon(
      onPressed: () {
        _newAdmission();
        setState(() => _narrowDetail = true);
      },
      icon: const Icon(Icons.add, size: 16),
      label: const Text('Add Admission'),
    );
  }

  /// Bottom pagination bar: "Showing X to Y of Z" + compact page controls.
  Widget _paginationBar(int total) {
    final pages = (total / _pageSize).ceil();
    final page = _page.clamp(0, pages > 0 ? pages - 1 : 0);
    final start = total == 0 ? 0 : page * _pageSize + 1;
    final end = (page * _pageSize + _pageSize) > total ? total : (page * _pageSize + _pageSize);
    // Compact page list: first, last, and current ± 1, de-duped and sorted.
    final nums = <int>{0, pages - 1, page - 1, page, page + 1}
        .where((p) => p >= 0 && p < pages)
        .toList()
      ..sort();
    // The list pane's footer slot already draws the divider and padding.
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppUI.showing(start, end, total), style: AppUI.muted),
          SizedBox(height: 6.h),
          Row(
            children: [
              _pageArrow(Icons.chevron_left, page > 0 ? () => setState(() => _page = page - 1) : null),
              SizedBox(width: 4.w),
              for (int i = 0; i < nums.length; i++) ...[
                if (i > 0 && nums[i] != nums[i - 1] + 1)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 2.w),
                    child: Text('…', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
                  ),
                _pageNum(nums[i], nums[i] == page),
              ],
              SizedBox(width: 4.w),
              _pageArrow(Icons.chevron_right, page < pages - 1 ? () => setState(() => _page = page + 1) : null),
            ],
          ),
        ],
    );
  }

  Widget _pageNum(int p, bool active) {
    return InkWell(
      onTap: () => setState(() => _page = p),
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 2.w),
        width: 26.w,
        height: 26.w,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(6.r),
          border: Border.all(color: active ? AppColors.primary : AppColors.border),
        ),
        child: Text('${p + 1}',
            style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600, color: active ? Colors.white : AppColors.textPrimary)),
      ),
    );
  }

  Widget _pageArrow(IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6.r),
      child: Container(
        width: 26.w,
        height: 26.w,
        alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6.r), border: Border.all(color: AppColors.border)),
        child: Icon(icon, size: 16, color: onTap == null ? AppColors.textLight : AppColors.textSecondary),
      ),
    );
  }

  /// Compact left-list filter dropdown (Course / Class). A null value shows the
  /// hint and means "no filter".
  Widget _listFilterDropdown(String hint, String? value, List<String> options, ValueChanged<String?> onChanged) {
    final filled = options.contains(value);
    return AppDropdownField<String>(
      initialValue: filled ? value : null,
      isExpanded: true,
      isDense: true,
      dropdownColor: Colors.white,
      icon: const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.textSecondary),
      style: AppUI.fieldText(context, filled: filled),
      decoration: AppUI.field(context, '', filled: filled),
      items: [
        DropdownMenuItem<String>(value: null, child: Text(hint, style: AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500))),
        ...options.map((e) => DropdownMenuItem(value: e, child: Text(e, style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis))),
      ],
      onChanged: onChanged,
    );
  }

  Widget _statusChips(Map<String, int> counts) {
    final chips = <Widget>[_chip('ALL', 'All', _admissions.length, AppColors.primary)];
    for (final s in AdmissionStatus.ordered) {
      final c = counts[s] ?? 0;
      if (c == 0 && _statusFilter != s) continue;
      chips.add(_chip(s, AdmissionStatus.label(s), c, _statusColor(s)));
    }
    return SizedBox(
      height: 34.h,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        children: [
          for (final w in chips) Padding(padding: EdgeInsets.only(right: 6.w), child: w),
        ],
      ),
    );
  }

  Widget _chip(String value, String label, int count, Color color) {
    final selected = _statusFilter == value;
    return InkWell(
      onTap: () => setState(() { _statusFilter = value; _page = 0; }),
      borderRadius: BorderRadius.circular(16.r),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
        decoration: BoxDecoration(
          color: selected ? color : color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(color: selected ? color : color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : color)),
            SizedBox(width: 5.w),
            Text('$count',
                style: TextStyle(
                    fontSize: 11.sp,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : color)),
          ],
        ),
      ),
    );
  }

  Widget _listTile(AdmissionModel a, int i) {
    final selected = _selected?.admId == a.admId;
    final color = _statusColor(a.admstatus);
    return Material(
      color: selected
          ? AppColors.primaryLight
          : (i.isEven ? Colors.white : AppColors.surface),
      child: InkWell(
        hoverColor: AppColors.primaryLight.withValues(alpha: 0.6),
        onTap: () {
          _populate(a);
          setState(() => _narrowDetail = true);
        },
        child: Container(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad - 3, 9.h, AppUI.cardPad, 9.h),
          decoration: BoxDecoration(
            color: selected ? AppColors.primaryTint : null,
            border: Border(
              left: BorderSide(color: selected ? AppColors.primary : Colors.transparent, width: 3),
              bottom: const BorderSide(color: AppColors.divider),
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16.r,
                backgroundColor: color.withValues(alpha: 0.12),
                child: Text(
                  a.stuname.isNotEmpty ? a.stuname[0].toUpperCase() : '?',
                  style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13.sp),
                ),
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.stuname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                            fontSize: 13.sp,
                            color: selected ? AppColors.primary : AppColors.textPrimary)),
                    SizedBox(height: 4.h),
                    Row(children: [
                      AppUI.admTag(a.admno, size: 11.5),
                      SizedBox(width: 6.w),
                      Flexible(
                        child: Text(
                            a.isAllocated && a.allocatedclass != null
                                ? a.allocatedclass!
                                : (a.stuclass ?? ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppUI.muted),
                      ),
                    ]),
                  ],
                ),
              ),
              _statusBadge(a.admstatus, small: true),
            ],
          ),
        ),
      ),
    );
  }

  // Status pill from the kit (colour + label). Mirrors _statusColor.
  Widget _statusBadge(String s, {bool small = false}) {
    final kind = switch (s) {
      AdmissionStatus.pending => AppStatus.warning,
      AdmissionStatus.allocated => AppStatus.success,
      _ => AppStatus.neutral,
    };
    return AppUI.chip(AdmissionStatus.label(s), kind);
  }

  // ── right panel ───────────────────────────────────────────────────
  // The detail pane of AppMasterDetail is the card; this fills it.
  Widget _buildDetail() {
    return Column(
        children: [
          // mouse-only (Back / More): Tab starts at the first field
          ExcludeFocus(child: _detailTopBar()),
          Divider(height: 1.h, color: AppColors.divider),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(AppUI.cardPad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_tcLocked) _tcLockedBanner()
                  else if (_readonly) _allocatedBanner(),
                  // TC-issued records are fully view-only (IgnorePointer + dimmed).
                  Opacity(
                    opacity: _tcLocked ? 0.75 : 1,
                    child: IgnorePointer(
                      ignoring: _tcLocked,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _studentInfoHeader(),
                          // ONE PAGE: every group of fields in order (no tabs),
                          // each as a "notebook" section.
                          for (var t = 0; t < _tabLabels.length; t++) _notebookSection(t),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _detailFooter(), // AppFormFooter draws its own top divider
        ],
    );
  }

  /// A notebook section: a big Fraunces numeral and the section name in
  /// a left margin, a thin burnt-orange rule, the fields on the right. The
  /// numeral of the section being edited is teal, the others faint. On a
  /// narrow pane it falls back to a plain heading above the fields.
  Widget _notebookSection(int t) {
    final title = _tabLabels[t];
    final active = _activeSection == t;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (has) {
        if (has && _activeSection != t) setState(() => _activeSection = t);
      },
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 900) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _pageHeading(title, first: t == 0),
            ..._tabSections(t),
          ]);
        }
        final words = title.split(' ');
        return Padding(
          padding: EdgeInsets.only(top: t == 0 ? 4.h : 26.h),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 150.w,
                child: Padding(
                  padding: EdgeInsets.only(right: 18.w, top: 2.h),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text((t + 1).toString().padLeft(2, '0'),
                        style: AppFonts.body(size: 40.sp, weight: FontWeight.w800, color: active ? AppColors.primary : AppColors.faint).copyWith(height: 1)),
                    SizedBox(height: 6.h),
                    Text(words.first, textAlign: TextAlign.right, style: AppFonts.body(size: 17.sp, weight: FontWeight.w700).copyWith(height: 1.15)),
                    if (words.length > 1)
                      Text(words.skip(1).join(' '), textAlign: TextAlign.right, style: AppUI.muted),
                  ]),
                ),
              ),
              // the margin rule is the fields' left edge, so it is as tall as they are
              Expanded(
                child: Container(
                  padding: EdgeInsets.only(left: 22.w),
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: AppColors.error.withValues(alpha: 0.32), width: 1.5))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: _tabSections(t)),
                ),
              ),
            ]),
        );
      }),
    );
  }

  /// Heading over each group of the single-page form (Personal Details,
  /// Academic Details ...) -- the narrow-pane form of [_notebookSection].
  Widget _pageHeading(String title, {bool first = false}) => Padding(
        padding: EdgeInsets.only(top: first ? 4.h : 22.h, bottom: 10.h),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!first) Divider(height: 1.h, color: AppColors.divider),
          if (!first) SizedBox(height: 16.h),
          Text(title, style: AppUI.cardTitle.copyWith(color: AppColors.primary)),
        ]),
      );

  /// New-admission wizard progress (AppStepper). Scrolls sideways when the
  /// pane is too narrow for all six labelled steps.
  // ignore: unused_element
  Widget _wizardStepper() {
    return LayoutBuilder(
      builder: (context, c) {
        final pad = AppUI.cardPad;
        final width = (c.maxWidth - pad * 2).clamp(900.0, double.infinity);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12.h),
          child: SizedBox(width: width, child: AppStepper(steps: _tabLabels, current: _currentTab)),
        );
      },
    );
  }

  // Top bar: Back, breadcrumb, status badge, More menu.
  Widget _detailTopBar() {
    final a = _selected;
    return Padding(
      padding: EdgeInsets.fromLTRB(14.w, 12.h, 14.w, 12.h),
      child: Row(
        children: [
          OutlinedButton.icon(
            // Deselect AND clear the form. Just nulling _selected left the fields
            // populated with the previous record's data (incl. its admno), which
            // then insert-collided on Save (23505). _newAdmission() resets fully.
            // At tablet width it also returns to the list pane.
            onPressed: _saving
                ? null
                : () {
                    _newAdmission();
                    setState(() => _narrowDetail = false);
                  },
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Back'),
          ),
          SizedBox(width: 12.w),
          Flexible(
            child: Text(
              a == null ? 'Admissions  ›  New Admission' : 'Admissions  ›  ${a.stuname} (${a.admno})',
              overflow: TextOverflow.ellipsis,
              style: AppUI.muted.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const Spacer(),
          if (a != null) _statusBadge(a.admstatus),
          if (a != null && !a.isAllocated) ...[
            SizedBox(width: 8.w),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) { if (v == 'cancel') _cancel(); },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'cancel', child: Text('Cancel Admission')),
              ],
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 7.h),
                decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(AppUI.controlRadius)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('More', style: AppUI.label.copyWith(color: AppColors.textSecondary)),
                  const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.textSecondary),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Horizontal tab bar (6 tabs). Not shown any more: the form is one page.
  // ignore: unused_element
  Widget _tabBar() {
    return SizedBox(
      height: 44.h,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 8.w),
        children: [
          for (int i = 0; i < _tabLabels.length; i++)
            InkWell(
              onTap: () {
                // New entry = wizard. Going BACK is always allowed (you have to
                // be able to fix an earlier tab), but going FORWARD requires
                // every tab you would skip past to be complete — otherwise the
                // tab strip is a way around the Next button's check.
                // Editing an existing record navigates freely; Save still runs
                // the full sweep and jumps to whatever is missing.
                if (_selected == null && i > _currentTab) {
                  for (var t = _currentTab; t < i; t++) {
                    if (!_validateTab(t)) {
                      setState(() {
                        _showErrors = true;
                        _currentTab = t;
                      });
                      return;
                    }
                  }
                }
                setState(() => _currentTab = i);
              },
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 14.w),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(
                    color: _currentTab == i ? AppColors.primary : Colors.transparent, width: 2.5)),
                ),
                child: Text(_tabLabels[i],
                    style: TextStyle(
                      fontSize: 14.sp,
                      fontWeight: _currentTab == i ? FontWeight.w700 : FontWeight.w600,
                      color: _currentTab == i ? AppColors.primary : AppColors.textLight)),
              ),
            ),
        ],
      ),
    );
  }

  // "Student Information" header with photo + Upload, atop the tab content.
  Widget _studentInfoHeader() {
    final a = _selected;
    final name = a?.stuname ?? _nameController.text.trim();
    return Padding(
      padding: EdgeInsets.only(bottom: 12.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppUI.iconTile('user'),
          SizedBox(width: 12.w),
          Padding(
            padding: EdgeInsets.only(top: 8.h),
            child: Text('Student Information', style: AppUI.cardTitle),
          ),
          SizedBox(width: 16.w),
          // Add Sibling (new admissions only): copy a brother's / sister's
          // family details so both share one parent record.
          if (a == null)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 2.h),
                child: Wrap(
                  spacing: 10.w,
                  runSpacing: 6.h,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _pickSibling,
                      icon: AppIcon('people', size: 16, color: AppColors.primary),
                      label: const Text('Add Sibling'),
                      style: AppUI.secondary(context),
                    ),
                    if (_siblingOf != null)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        AppUI.chip(schoolTerm('Sibling of ${_siblingOf!.stuname} (${_siblingOf!.admno}${(_siblingOf!.stuclass ?? '').isEmpty ? '' : ', ${_siblingOf!.stuclass}'})'),
                            AppStatus.info),
                        IconButton(
                          tooltip: 'Clear the sibling note (the copied details stay)',
                          onPressed: () => setState(() => _siblingOf = null),
                          icon: const Icon(Icons.close, size: 14),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        ),
                      ]),
                  ],
                ),
              ),
            )
          else
            const Spacer(),
          // Upload / Remove photo are mouse actions: kept out of Tab
          ExcludeFocus(child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                width: 46.w,
                height: 46.w,
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryLight),
                child: (_photoUrl != null && _photoUrl!.isNotEmpty)
                    ? Image.network(_photoUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _avatarInitial(name))
                    : _avatarInitial(name),
              ),
              SizedBox(height: 2.h),
              TextButton.icon(
                onPressed: _isUploadingPhoto ? null : _uploadPhoto,
                icon: _isUploadingPhoto
                    ? SizedBox(width: 12.w, height: 12.w, child: const CircularProgressIndicator(strokeWidth: 2))
                    : AppIcon('camera', size: 14, color: AppColors.primary),
                label: Text(_isUploadingPhoto ? 'Uploading…' : 'Upload Photo', style: TextStyle(fontSize: 12.sp)),
                style: TextButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 6.w), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ),
              // Clear the selected/existing photo (persists as NULL on save).
              if (!_isUploadingPhoto && _photoUrl != null && _photoUrl!.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() => _photoUrl = null),
                  icon: Icon(Icons.delete_outline, size: 14, color: AppColors.error),
                  label: Text('Remove Photo', style: TextStyle(fontSize: 12.sp, color: AppColors.error)),
                  style: TextButton.styleFrom(padding: EdgeInsets.symmetric(horizontal: 6.w), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                ),
            ],
          )),
        ],
      ),
    );
  }

  Widget _avatarInitial(String name) => Center(
        child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700, fontSize: 16.sp)),
      );

  // Footer: Cancel Admission (pending) | Cancel | Next / Save.
  // New entry = wizard: "Next" steps through the tabs, "Save Admission" only on
  // the last tab. Edit = "Save Changes" available on every tab.
  Widget _detailFooter() {
    final a = _selected;
    final allocated = a?.isAllocated ?? false;
    final isNew = a == null;
    // One page: no Next / Previous -- Save checks every section.
    // AppFormFooter: step / hint note on the left; Cancel Admission (pending
    // records), Cancel, Previous (wizard) and Next / Save on the right.
    return AppFormFooter(
      note: AppText.requiredNote,
      actions: [
        if (a != null && !allocated)
          OutlinedButton.icon(
            onPressed: _saving ? null : _cancel,
            icon: const Icon(Icons.block, size: 16),
            label: const Text('Cancel Admission'),
            style: AppUI.secondary(context).copyWith(
              foregroundColor: const WidgetStatePropertyAll(AppColors.error),
              side: WidgetStatePropertyAll(BorderSide(color: AppColors.error.withValues(alpha: 0.5))),
            ),
          ),
        OutlinedButton(
          // Same reset as Back — clear the form, not just deselect (see note there).
          onPressed: _saving ? null : _newAdmission,
          child: const Text('Cancel'),
        ),
        // No Save/Next on a TC-locked (view-only) record.
        if (!_tcLocked) ...[
          ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save, size: 16),
              label: Text(isNew ? 'Save Admission' : 'Update Admission'),
            ),
        ],
      ],
    );
  }

  /// Sections rendered for the given detail tab (0..5).
  List<Widget> _tabSections(int tab) {
    switch (tab) {
      case 0: // Personal Details
        return [
          _section('Basic details', [
            _row([
              _text('Full Name *', _nameController, required: true),
              _dropdown('Gender *', _gender, _genders, (v) => setState(() => _gender = v), required: true),
              _dateField('Date of Birth *', _dob, (d) => setState(() => _dob = d), required: true),
            ]),
            _row([
              _text('Mobile', _mobileController, keyboard: TextInputType.phone, maxLen: 10),
              _text('Email', _emailController, keyboard: TextInputType.emailAddress),
              _dropdown('Blood Group', _bloodGroup, _bloodGroups, (v) => setState(() => _bloodGroup = v)),
            ]),
          ]),
          _section('Government IDs', [
            _row([
              _text('Aadhaar No.', _aadharController, digitsOnly: true, maxLen: 12),
              // Government identifiers alongside Aadhar. Neither is mandatory:
              // EMIS comes from the school record and UMIS is issued on
              // university enrolment, so a fresher often has one and not the
              // other. Digits-only, but no fixed length — formats vary by year.
              _text(schoolTerm('EMIS No'), _emisController, digitsOnly: true, maxLen: emisMaxLength,
                  extraError: emisInvalid(_emisController.text) || _emisOwner != null,
                  extraMsg: emisInvalid(_emisController.text) ? kEmisRuleMsg : 'Already used by $_emisOwner'),
              // Three slots, like the rows above, so the boxes line up with them.
              if (isSchool) const Spacer() else _text('UMIS No', _umisController, digitsOnly: true, maxLen: 30),
            ]),
          ]),
        ];
      case 1: // Academic Details
        return [
          _section('Registration', [
            _row([
              _dropdown(schoolTerm('Register No. Mode'), _regMode, _regModes, (v) => setState(() => _regMode = v),
                  hint: 'Select mode', locked: _utilRegMode != null, required: true),
              _regSeqField(),
              // The duplicate note shows as soon as the number is typed rather
              // than waiting for Next — it is knowable immediately, and finding
              // out at the end of the tab means retyping.
              // A greyed-out number reads as reserved; in Auto it is only a
              // preview -- the real one is claimed when Save is pressed.
              _text(schoolTerm('Register No. *'),
                  _admnoController, enabled: !_regNoLocked,
                  hint: _regNoLocked && _selected == null ? '${AppText.generated} on save' : null,
                  locked: _coreLocked || _regNoLocked, required: true,
                  extraError: _regNoDuplicate, extraMsg: 'This number is already used. Enter a different number.'),
            ]),
            _row([
              _dateField(AppText.dateOfAdmission, _admDate, (d) => setState(() => _admDate = d), hint: 'Select date of admission', locked: _coreLocked, required: true),
              _dropdown('Source', _source, _sources, (v) => setState(() => _source = v), display: _sourceLabels),
              // Batch stays editable after allocation, unlike the other core
              // fields. It is a label for the intake year, not part of the
              // student's identity or enrolment -- correcting a mistyped batch
              // moves nothing and breaks no link, where changing Register No,
              // Course or Class after allocation would.
              // School: no Division field -- it comes from the standard
              // (Master Data > Standard), set when the standard is picked.
              if (isSchool) const SizedBox.shrink() else _text('Batch', _batchController, required: true, maxLen: 9),
            ]),
            // School: the tick and its note take the full row, so the note
            // reads in two lines instead of a tall narrow column.
            if (isSchool)
              _row([_preAdmissionField()])
            else
              _row([_preAdmissionField(), _divisionField(), const SizedBox.shrink()]),
          ]),
          _section(schoolTerm('Course & class'), [
            _row([
              _dropdown(schoolTerm('Course'), _selectedCourse, _courseNames, (v) => setState(() {
                    _selectedCourse = v;
                    if (_selectedClass != null && !_classNamesFor(v).contains(_selectedClass)) _selectedClass = null;
                    // the standard's division (Master Data -> Standard). School:
                    // always the standard's (no field); college: still changeable.
                    final div = _divisionOfCourse(v);
                    if (isSchool || div != null) _pickDivision(div);
                  }), locked: _coreLocked, required: true),
              _dropdown(schoolTerm('Class'), _selectedClass, _classNamesFor(_selectedCourse),
                  (v) => setState(() => _selectedClass = v), hint: schoolTerm('Select class'),
                  locked: _coreLocked, required: !isSchool),
              _suggestText('Medium', _mediumController, _mediumFocus,
                  _optionsOf((a) => a.medium), hint: 'Type or select a medium'),
            ]),
            _row([
              if (!isSchool) ...[
              _dropdownMap('Admission Type', _selectedAdmName, _admissionTypes, 'admname', 'admname',
                  (v) => setState(() => _selectedAdmName = v), locked: _coreLocked, required: true),
              _dropdownMap('Quota', _selectedQuoName, _quotas, 'quoname', 'quoname',
                  (v) => setState(() => _selectedQuoName = v)),
              ],
              _dropdownMap('Concession', _selectedConId, _concessions, 'con_id', 'condesc',
                  (v) => setState(() => _selectedConId = v)),
              // School: no admission type / quota -- keep the 3-column shape.
              if (isSchool) ...[const Spacer(), const Spacer()],
            ]),
          ]),
          // School: no scholarship details.
          if (!isSchool) _section('Scholarship', [_row([
              _dropdown('Scholarship Eligible', _scholarship, _yesNoOptions,
                  (v) => setState(() {
                        _scholarship = v;
                        // Answering No retires the type — leaving the old text
                        // visible would suggest it still applies.
                        if (v != 'Yes') _scholarshipTypeController.clear();
                      }), hint: 'Select yes or no'),
              // The type is asked for only when eligible; otherwise the row
              // keeps its shape with a Spacer rather than reflowing the columns.
              if (_scholarship == 'Yes')
                _suggestText('Scholarship Type', _scholarshipTypeController,
                    _focusFor('scholarshipType'),
                    _optionsOf((a) => a.scholarshiptype),
                    required: true, hint: 'Type or select a scholarship')
              else
                const Spacer(),
              const Spacer(),
            ])]),
        ];
      case 2: // Parent / Guardian
        return [
          _section('Parent / Guardian', [
            _row([
              _text('Father Name', _fatherNameController),
              _text('Father Mobile', _fatherMobileController, keyboard: TextInputType.phone, maxLen: 10),
              _suggestText('Father Occupation', _fatherOccController, _focusFor('fatherOcc'),
                  _optionsOf((a) => a.fatheroccupation), hint: 'Type or select an occupation'),
            ]),
            _row([
              _text('Mother Name', _motherNameController),
              _text('Mother Mobile', _motherMobileController, keyboard: TextInputType.phone, maxLen: 10),
              _suggestText('Mother Occupation', _motherOccController, _focusFor('motherOcc'),
                  _optionsOf((a) => a.motheroccupation), hint: 'Type or select an occupation'),
            ]),
            _row([
              _text('Guardian Name', _guardianNameController),
              _text('Guardian Mobile', _guardianMobileController, keyboard: TextInputType.phone, maxLen: 10),
              _suggestText('Guardian Occupation', _guardianOccController, _focusFor('guardianOcc'),
                  _optionsOf((a) => a.guardianoccupation), hint: 'Type or select an occupation'),
            ]),
          ]),
          _section('Contact & pay in charge', [
            _row([
              _text('Payment In Charge *', _payNameController, required: true),
              _text('Pay In Charge Mobile *', _payMobileController, keyboard: TextInputType.phone, maxLen: 10, required: true,
                  extraError: _payMobileController.text.trim().isNotEmpty &&
                      payerMobileError('Pay In Charge Mobile', _payMobileController.text) != null,
                  extraMsg: 'Enter the payer\'s own 10-digit mobile (starting 6-9), not a placeholder.'),
              _text('Parent Email', _parentEmailController, keyboard: TextInputType.emailAddress),
            ]),
            Padding(
              padding: EdgeInsets.only(top: 4.h),
              child: Row(children: [
                Icon(Icons.info_outline, size: 14.sp, color: AppColors.textLight),
                SizedBox(width: 6.w),
                Expanded(
                  child: Text(
                    'Payment In Charge fills in from Father → Mother → Guardian (the first with both Name and Mobile). '
                    'Change it if someone else pays.',
                    style: AppUI.muted,
                  ),
                ),
              ]),
            ),
            // Brothers / sisters on this Pay In Charge mobile (one parent login).
            Builder(builder: (_) {
              final sibs = _siblingsOnNumber();
              if (sibs.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: EdgeInsets.only(top: 8.h),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  AppIcon('people', size: 14, color: AppColors.primary),
                  SizedBox(width: 6.w),
                  Expanded(
                    child: Text(
                      schoolTerm('Siblings on this mobile (same parent login): ') +
                          sibs.map((b) => '${b.stuname} (${[b.admno, b.stuclass ?? ''].where((v) => v.trim().isNotEmpty).join(', ')})').join('; '),
                      style: AppUI.body.copyWith(color: AppColors.primary),
                    ),
                  ),
                ]),
              );
            }),
          ]),
        ];
      case 3: // Address Details
        return [
          _section('Address', [
            _row([ _text('Address', _addressController) ]),
            _row([
              _suggestText('City', _cityController, _focusFor('city'),
                  _optionsOf((a) => a.stucity), hint: 'Type or select a city'),
              _suggestText('State', _stateController, _focusFor('state'),
                  _optionsOf((a) => a.stustate), hint: 'Type or select a state'),
              _text('Pin Code', _pinController, digitsOnly: true, maxLen: 6,
                  extraError: !_lenOk(_pinController, 6), extraMsg: 'Pin Code must be 6 digits'),
            ]),
          ]),
          _section('Transport & hostel', [
            _row([
              _dropdown('Transport', _transportMode, _transportOptions, (v) => setState(() => _transportMode = v)),
              _dropdown('Hostel', _hostel, _hostelOptions, (v) => setState(() => _hostel = v)),
              const Spacer(),
            ]),
          ]),
        ];
      case 4: // Previous School
        return [
          _section('Previous School', [
            _row([
              _text('School / College', _prevSchoolController),
              _text(isSchool ? 'Standard' : 'Class / Course', _prevClassController),
              _text('Marks %', _prevPercentController, keyboard: TextInputType.number),
            ]),
          ]),
        ];
      case 5: // Other Details
      default:
        return [
          _section('Other Details', [
            _row([
              _dropdown('Community', _selectedCommunity, _communities, (v) => setState(() => _selectedCommunity = v)),
              _suggestText('Caste', _casteController, _focusFor('caste'),
                  _optionsOf((a) => a.caste), hint: 'Type or select a caste'),
              _suggestText('Religion', _religionController, _focusFor('religion'),
                  _optionsOf((a) => a.religion), hint: 'Type or select a religion'),
            ]),
            _row([
              _suggestText('Nationality', _nationalityController, _focusFor('nationality'),
                  _optionsOf((a) => a.nationality), hint: 'Type or select a nationality'),
              const Spacer(),
              const Spacer(),
            ]),
          ]),
          // Printed on the TC (Personal Marks of Identification).
          _section('Personal identification', [
            _row([
              _text('Identification Mark 1', _idMark1Controller, hint: 'e.g. A mole on the right thumb'),
              _text('Identification Mark 2', _idMark2Controller, hint: 'e.g. A scar on the left knee'),
            ]),
          ]),
          _section('Notes', [
            _row([ _text('Notes', _remarksController, maxLines: 2) ]),
          ]),
        ];
    }
  }

  // Status labels for the TC-locked banner (mirror the TC module's codes).
  static const Map<int, String> _statusNames = {
    2: 'Discontinued', 3: 'Transferred', 4: 'Completed', 5: 'Others', 9: 'Terminated',
  };

  Widget _tcLockedBanner() {
    final a = _selected!;
    final label = _statusNames[a.activestatus] ?? 'Inactive';
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 14.h),
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const AppIcon('lock', size: 16, color: AppColors.warning),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              'Transfer Certificate issued — status: $label. This record is view-only.',
              style: TextStyle(fontSize: 13.sp, color: AppColors.warning, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _allocatedBanner() {
    final a = _selected!;
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 14.h),
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: AppColors.successBg,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const AppIcon('tick-circle', size: 16, color: AppColors.success),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              isSchool
                  ? schoolTerm('Allocated to ${a.allocatedclass ?? '—'}. You can edit this record, but Register No., Date of Admission, Course and Class are locked.')
                  : 'Allocated to ${a.allocatedclass ?? '—'}. You can edit this record, but Register No., Date of Admission, Course, Class and Admission Type are locked.',
              style: TextStyle(fontSize: 13.sp, color: AppColors.success, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }


  // ── form widget helpers ───────────────────────────────────────────
  /// A group of form rows under a small-caps heading (AppUI.sectionLabel).
  /// The detail pane is the card, so a section is flat -- no card of its own.
  /// Each section is its own focus-traversal group, in reading order.
  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: EdgeInsets.only(bottom: 14.h),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppUI.sectionLabel(title),
          FocusTraversalGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(List<Widget> cells) {
    return Padding(
      padding: EdgeInsets.only(bottom: 10.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            // A Spacer is already an Expanded — wrapping it in another Expanded
            // triggers "Competing ParentDataWidgets", so pass it through.
            cells[i] is Spacer ? cells[i] : Expanded(child: cells[i]),
            if (i != cells.length - 1) SizedBox(width: 12.w),
          ],
        ],
      ),
    );
  }

  // Label above each field (AppUI.fieldLabel). Labels already carrying their
  // own trailing " *" and fields marked required both get the same red star,
  // so every mandatory field is marked the same way.
  // [optional] adds a muted "(optional)" -- only for plain optional inputs.
  Widget _label(String text, {bool required = false, bool optional = false}) {
    final t = text.trim();
    final hasStar = t.endsWith('*');
    final base = hasStar ? t.substring(0, t.length - 1).trimRight() : text;
    return AppUI.fieldLabel(base, required: required || hasStar, optional: optional && !required && !hasStar);
  }

  /// Not individually required, but not optional either: at least one of
  /// Father / Mother / Guardian needs both a Name and a Mobile (it becomes Pay
  /// In Charge). These carry no tag; the note under them explains the rule.
  static const _conditionalLabels = {
    'Father Name', 'Father Mobile', 'Mother Name', 'Mother Mobile',
    'Guardian Name', 'Guardian Mobile',
  };

  // The shared AppUI field; locked fields get the page tint, a flagged field
  // (required + empty after Next/Save, or a duplicate) a red edge.
  InputDecoration _dec({bool filled = false, String? hint, bool locked = false,
      bool error = false}) {
    final base = AppUI.field(context, hint ?? '', filled: filled);
    OutlineInputBorder b(Color c, double w) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        borderSide: BorderSide(color: c, width: w));
    return base.copyWith(
      // read-only: transparent over the striped backing (see _text)
      fillColor: locked ? Colors.transparent : AppColors.fieldBg,
      border: error ? b(AppColors.error, 1) : null,
      enabledBorder: error ? b(AppColors.error, 1) : null,
      focusedBorder: error ? b(AppColors.error, 2) : null,
    );
  }

  /// True when [empty] is a required field the user has not filled and Next or
  /// Save has already been pressed. Drives the red border + note.
  bool _err(bool required, bool empty) => _showErrors && required && empty;

  /// Small red note under a highlighted field.
  Widget _errNote(bool show, String msg) => !show
      ? const SizedBox.shrink()
      : Padding(
          padding: EdgeInsets.only(top: 4.h, left: 2.w),
          child: Text(msg,
              style: TextStyle(fontSize: 12.sp, color: AppColors.error, fontWeight: FontWeight.w600)),
        );

  /// [extraError] flags a problem the empty/required test can't see (e.g. a
  /// duplicate register number) and shows [extraMsg] under the field. Unlike
  /// the Required note it does not wait for _showErrors.
  Widget _text(String label, TextEditingController c,
      {bool enabled = true, TextInputType? keyboard, int maxLines = 1,
      bool locked = false, bool required = false, bool digitsOnly = false,
      int? maxLen, bool extraError = false, String? extraMsg, String? hint}) {
    final filled = c.text.trim().isNotEmpty;
    final bad = _err(required, !filled) || extraError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label, required: required, optional: !required && !_conditionalLabels.contains(label)),
        if (locked || !enabled)
          DecoratedBox(decoration: AppUI.readOnly(), child: _textField(c, enabled, locked, keyboard, digitsOnly, maxLen, maxLines, filled, hint, bad))
        else
          _textField(c, enabled, locked, keyboard, digitsOnly, maxLen, maxLines, filled, hint, bad),
        _errNote(bad, extraError ? (extraMsg ?? 'Invalid') : 'Required'),
      ],
    );
  }

  Widget _textField(TextEditingController c, bool enabled, bool locked, TextInputType? keyboard, bool digitsOnly, int? maxLen,
      int maxLines, bool filled, String? hint, bool bad) {
    final readOnly = locked || !enabled;
    return TextFormField(
          controller: c,
          enabled: enabled && !locked,
          keyboardType: keyboard,
          // Phone fields take digits only. keyboardType alone restricts nothing
          // on desktop — it only hints which soft keyboard to show, and Windows
          // never shows one, so letters and symbols were accepted.
          inputFormatters: <TextInputFormatter>[
            if (digitsOnly || keyboard == TextInputType.phone)
              FilteringTextInputFormatter.digitsOnly,
            if (maxLen != null) LengthLimitingTextInputFormatter(maxLen),
          ],
          maxLines: maxLines,
          onChanged: (_) => setState(() {}),
          // a read-only number (e.g. the auto Admission No.) reads as mono
          style: readOnly ? AppUI.mono.copyWith(color: AppColors.primaryDark, fontWeight: FontWeight.w600) : AppUI.fieldText(context, filled: filled),
          decoration: _dec(filled: filled, hint: hint, locked: readOnly, error: bad),
        );
  }

  /// A text field that suggests values already used, without restricting the
  /// entry to them — a medium that has never been typed before still saves.
  /// Focusing an empty field lists everything on file; typing narrows it.
  Widget _suggestText(String label, TextEditingController c, FocusNode focus,
      List<String> options, {bool required = false, String? hint}) {
    final filled = c.text.trim().isNotEmpty;
    final bad = _err(required, !filled);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label, required: required, optional: !required && !_conditionalLabels.contains(label)),
        RawAutocomplete<String>(
          textEditingController: c,
          focusNode: focus,
          optionsBuilder: (v) {
            final q = v.text.trim().toLowerCase();
            if (q.isEmpty) return options;
            return options.where((o) => o.toLowerCase().contains(q));
          },
          onSelected: (_) => setState(() {}),
          fieldViewBuilder: (context, ctrl, fn, onSubmit) => TextFormField(
            controller: ctrl,
            focusNode: fn,
            onChanged: (_) => setState(() {}),
            style: AppUI.fieldText(context, filled: filled),
            decoration: _dec(filled: filled, hint: hint, error: bad),
          ),
          optionsViewBuilder: (context, onSelected, opts) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 6,
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: 240.h, maxWidth: 320.w),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: opts.length,
                  itemBuilder: (_, i) {
                    final o = opts.elementAt(i);
                    return ListTile(
                      dense: true,
                      title: Text(o, style: AppUI.fieldText(context)),
                      onTap: () => onSelected(o),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        _errNote(bad, 'Required'),
      ],
    );
  }

  Widget _dropdown(String label, String? value, List<String> items, ValueChanged<String?> onChanged,
      {String? hint, bool locked = false, bool required = false, Map<String, String> display = const {}}) {
    final bad = _err(required, value == null || value.trim().isEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label, required: required, optional: !required && !_conditionalLabels.contains(label)),
        AppDropdownField<String>(
          initialValue: items.contains(value) ? value : null,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          style: AppUI.fieldText(context),
          decoration: _dec(filled: items.contains(value), hint: hint ?? 'Select ${label.replaceAll(' *', '').trim().toLowerCase()}', locked: locked),
          items: items
              .map((e) => DropdownMenuItem(value: e, child: Text(display[e] ?? e, style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis)))
              .toList(),
          selectedItemBuilder: (context) => items
              .map((e) => Align(alignment: Alignment.centerLeft, child: Text(display[e] ?? e, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))))
              .toList(),
          onChanged: locked ? null : onChanged,
        ),
        _errNote(bad, 'Required'),
      ],
    );
  }

  Widget _dropdownMap(String label, String? value, List<Map<String, dynamic>> items,
      String valueKey, String labelKey, ValueChanged<String?> onChanged,
      {String? hint, bool locked = false, bool required = false}) {
    final values = items.map((e) => e[valueKey].toString()).toList();
    final bad = _err(required, value == null || value.trim().isEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label, required: required, optional: !required && !_conditionalLabels.contains(label)),
        AppDropdownField<String>(
          initialValue: values.contains(value) ? value : null,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          style: AppUI.fieldText(context),
          decoration: _dec(filled: values.contains(value), hint: hint ?? 'Select ${label.replaceAll(' *', '').trim().toLowerCase()}', locked: locked, error: bad),
          items: items
              .map((e) => DropdownMenuItem(
                    value: e[valueKey].toString(),
                    child: Text(e[labelKey]?.toString() ?? '', style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          selectedItemBuilder: (context) => items
              .map((e) => Align(alignment: Alignment.centerLeft, child: Text(e[labelKey]?.toString() ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))))
              .toList(),
          onChanged: locked ? null : onChanged,
        ),
        _errNote(bad, 'Required'),
      ],
    );
  }

  /// Register-sequence picker. Selecting one auto-fills the Register No field
  /// from the sequence's current counter (prefix/suffix + zero-padded next no).
  /// Division (Admission Master -> Division). Optional. Picking one also picks
  /// that division's Register Sequence when one exists and the number comes
  /// from a sequence -- Reg No sequences are kept per division.
  /// Division name of a standard (course.div_id), or null.
  String? _divisionOfCourse(String? courname) {
    if (courname == null) return null;
    final c = _courseList.firstWhere((e) => e['courname']?.toString() == courname, orElse: () => const {});
    final id = c['div_id'];
    if (id == null) return null;
    final name = _divisionById[(id as num).toInt()];
    return (name == null || name.isEmpty) ? null : name;
  }

  /// The school keeps its admission number sequences division-wise.
  bool get _seqByDivision => isSchool && regSeqDivisionWise(_regSeqs);

  /// Set the division (call inside setState). A new admission whose number
  /// comes from a sequence also takes that division's Register Sequence.
  void _pickDivision(String? v) {
    _selectedDivision = v;
    if (_seqByDivision) {
      if (!_regNoLocked || _selected != null) return;
      final seq = regSeqFor(_regSeqs, v).seq;
      _selectedRegSeqId = seq?['seq_id']?.toString();
      _admnoController.text = seq == null ? '' : _buildRegNo(seq);
      return;
    }
    if (_regNoLocked && _selected == null && v != null) {
      final m = _regSeqs.where((s) => (s['division'] ?? '').toString().trim().toUpperCase() == v.toUpperCase());
      if (m.isNotEmpty) {
        _selectedRegSeqId = m.first['seq_id'].toString();
        _admnoController.text = _buildRegNo(m.first);
      }
    }
  }

  Widget _divisionField() {
    final items = <String>{..._divisions, if (_selectedDivision != null) _selectedDivision!}.toList();
    return _dropdown(isSchool ? 'Division *' : 'Division', _selectedDivision, items, (v) => setState(() => _pickDivision(v)),
        hint: _divisions.isEmpty ? 'No divisions yet. Add one in Master Data' : 'Select division', required: isSchool);
  }

  Widget _regSeqField() {
    final values = _regSeqs.map((s) => s['seq_id'].toString()).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(schoolTerm('Register Sequence')),
        AppDropdownField<String>(
          // Division-wise the sequence changes with the standard.
          key: ValueKey('reg-seq-$_selectedRegSeqId'),
          initialValue: values.contains(_selectedRegSeqId) ? _selectedRegSeqId : null,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          style: AppUI.fieldText(context),
          decoration: _dec(
              filled: values.contains(_selectedRegSeqId), locked: !_regNoLocked || _seqByDivision),
          hint: Text(schoolTerm('Select register sequence'), style: AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)),
          items: _regSeqs
              .map((s) => DropdownMenuItem(
                    value: s['seq_id'].toString(),
                    child: Text(s['seqname']?.toString() ?? '', style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          selectedItemBuilder: (context) => _regSeqs
              .map((s) => Align(alignment: Alignment.centerLeft, child: Text(s['seqname']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))))
              .toList(),
          // Enabled in both Auto and Manual — picking a sequence fills the
          // suggested number. In Auto the Register No field is locked; in Manual
          // it stays editable so the user can overwrite the suggestion.
          // Only usable in AUTO — in MANUAL the number is typed, so there is no
          // sequence to choose.
          // Division-wise it follows the standard, so it cannot be changed here.
          onChanged: (_readonly || _regMode == null || !_regNoLocked || _seqByDivision)
              ? null
              : (v) => setState(() {
                    _selectedRegSeqId = v;
                    final seq = _regSeqs.firstWhere(
                      (s) => s['seq_id'].toString() == v,
                      orElse: () => const {},
                    );
                    if (seq.isNotEmpty) _admnoController.text = _buildRegNo(seq);
                  }),
        ),
        // AUTO with nothing to draw from would leave the locked Register No
        // empty and the form unsaveable, with no hint why. Say where to fix it.
        if (_regNoLocked && _regSeqs.isEmpty)
          Padding(
            padding: EdgeInsets.only(top: 4.h, left: 2.w),
            child: Text(schoolTerm('No register sequence yet. Add one in Admission Master.'),
                style: TextStyle(fontSize: 12.sp, color: AppColors.error, fontWeight: FontWeight.w600)),
          ),
        // Division-wise: this standard's division has no sequence of its own.
        if (_seqByDivision && _regNoLocked && _selected == null && _selectedCourse != null)
          Builder(builder: (_) {
            final c = regSeqFor(_regSeqs, _divisionOfCourse(_selectedCourse));
            if (c.notice == null) return const SizedBox.shrink();
            return Padding(
              padding: EdgeInsets.only(top: 4.h, left: 2.w),
              child: Text(c.notice!,
                  style: TextStyle(fontSize: 12.sp, color: c.blocked ? AppColors.error : AppColors.warning, fontWeight: FontWeight.w600)),
            );
          }),
      ],
    );
  }

  Widget _yearDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Academic Year'),
        AppDropdownField<String>(
          initialValue: _selectedYrId,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          style: AppUI.fieldText(context),
          decoration: _dec(filled: _selectedYrId != null, hint: 'Select academic year'),
          items: _years
              .map((y) => DropdownMenuItem(
                    value: y['yr_id'].toString(),
                    child: Text(y['yrlabel']?.toString() ?? '', style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          selectedItemBuilder: (context) => _years
              .map((y) => Align(alignment: Alignment.centerLeft, child: Text(y['yrlabel']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true))))
              .toList(),
          onChanged: _readonly
              ? null
              : (v) => setState(() {
                    _selectedYrId = v;
                    _selectedYrLabel = _years
                        .firstWhere((y) => y['yr_id'].toString() == v,
                            orElse: () => const {})['yrlabel']
                        ?.toString();
                  }),
        ),
      ],
    );
  }

  Widget _dateField(String label, DateTime? value, ValueChanged<DateTime> onPick,
      {String? hint, bool locked = false, bool required = false}) {
    final placeholder = hint ?? 'Select ${label.replaceAll(' *', '').trim().toLowerCase()}';
    final bad = _err(required, value == null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label, required: required, optional: !required && !_conditionalLabels.contains(label)),
        FocusableTap(
          onTap: locked
              ? null
              : () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: value ?? now,
                    firstDate: DateTime(1950),
                    lastDate: DateTime(now.year + 5),
                  );
                  if (picked != null) onPick(picked);
                },
          child: InputDecorator(
            decoration: _dec(filled: value != null, locked: locked, error: bad),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value == null ? placeholder : _fmtDate(value),
                    style: value == null
                        ? AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)
                        : AppUI.fieldText(context, filled: true),
                  ),
                ),
                const AppIcon.linear('calendar', size: 14, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
        _errNote(bad, 'Required'),
      ],
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
}
