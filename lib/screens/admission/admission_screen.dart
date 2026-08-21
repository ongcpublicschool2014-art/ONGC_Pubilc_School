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
import '../../widgets/card_title_block.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/focusable_tap.dart';

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
  final _aadharController = TextEditingController();
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
  String? _selectedYrId;
  String? _selectedYrLabel;
  String? _selectedCourse;
  String? _selectedClass;
  String? _selectedAdmName;
  String? _selectedQuoName;
  String? _selectedConId;
  String? _transportMode; // 'Own' | 'College'
  String? _hostel;        // 'Yes' | 'No'
  String? _selectedCommunity;
  String? _selectedRegSeqId; // chosen register-number sequence (sequence.seq_id)
  String? _regMode; // null = not chosen | 'Manual' | 'Auto'

  static const _regModes = ['Manual', 'Auto'];

  static const _transportOptions = ['Own', 'College'];
  static const _hostelOptions = ['Yes', 'No'];

  // ── data ──────────────────────────────────────────────────────────
  List<AdmissionModel> _admissions = [];
  List<Map<String, dynamic>> _years = [];
  List<Map<String, dynamic>> _courseList = []; // {cour_id, courname}
  List<Map<String, dynamic>> _classList = [];  // {claname, cour_id}
  List<Map<String, dynamic>> _admissionTypes = [];
  List<Map<String, dynamic>> _quotas = [];
  List<Map<String, dynamic>> _concessions = [];
  List<String> _communities = [];
  List<Map<String, dynamic>> _regSeqs = []; // register-number sequences

  AdmissionModel? _selected; // null → new-admission mode
  String _statusFilter = 'ALL';
  bool _loading = true;
  bool _saving = false;

  // ── wizard step state ────────────────────────────────────────────────
  // 4-step wizard per admission-design.md § 5:
  //   0  document-text  Admission   → Admission
  //   1  user           Applicant   → Applicant
  //   2  book-1         Academic    → Applied For, Additional Details, Previous School
  //   3  people         Family      → Parent / Guardian, Remarks
  int _currentStep = 0;
  static const _wizardLabels = ['Admission', 'Applicant', 'Academic'];
  static const _wizardIcons = ['document-text', 'user', 'book-1'];

  static const _genders = ['Male', 'Female', 'Other'];
  static const _bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
  static const _sources = ['WALK-IN', 'ONLINE', 'REFERRAL', 'AGENT'];

  @override
  void initState() {
    super.initState();
    _load();
    _loadRegModeDefault();
  }

  /// Seeds the Reg No Mode from the institution's Utilities setting
  /// (admission_number_mode: AUTO -> 'Auto', else 'Manual'). Only applied when
  /// the user hasn't already picked a mode this session.
  Future<void> _loadRegModeDefault() async {
    final s = await SupabaseService.getInstitutionSettings(_insId);
    if (!mounted || _regMode != null) return;
    setState(() {
      _regMode = (s['admission_number_mode'] ?? 'MANUAL').toUpperCase() == 'AUTO' ? 'Auto' : 'Manual';
    });
    _maybeAutoPickRegSeq();
  }

  /// Once the Reg No Mode and register sequences are both loaded, auto-select the
  /// first sequence and fill the suggested Register No — so Auto is fully
  /// automatic (no manual pick) and Manual still shows a suggestion. No-op while
  /// editing an existing admission, or once a sequence is already chosen.
  void _maybeAutoPickRegSeq() {
    if (!mounted || _readonly || _selected != null) return;
    if (_regMode == null || _regSeqs.isEmpty || _selectedRegSeqId != null) return;
    if (_admnoController.text.trim().isNotEmpty) return;
    final seq = _regSeqs.first;
    setState(() {
      _selectedRegSeqId = seq['seq_id'].toString();
      _admnoController.text = _buildRegNo(seq);
    });
  }

  @override
  void dispose() {
    for (final c in [
      _searchController, _admnoController, _nameController, _mobileController,
      _emailController, _aadharController, _addressController,
      _cityController, _stateController, _pinController, _batchController,
      _prevSchoolController, _prevClassController, _prevPercentController,
      _fatherNameController, _fatherMobileController, _motherNameController,
      _motherMobileController, _guardianNameController, _guardianMobileController,
      _fatherOccController, _motherOccController, _guardianOccController,
      _payNameController, _payMobileController,
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
        SupabaseService.fromSchema('course').select('cour_id, courname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.getAdmissionTypes(insId),
        SupabaseService.getQuotas(insId),
        SupabaseService.getConcessions(insId),
        SupabaseService.fromSchema('community').select('comname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('sequence').select('*').eq('actname', 'REGNO').eq('activestatus', 1).order('seq_id', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _admissions = results[0] as List<AdmissionModel>;
        _years = results[1] as List<Map<String, dynamic>>;
        _courseList = List<Map<String, dynamic>>.from(results[2] as List);
        _classList = List<Map<String, dynamic>>.from(results[3] as List);
        _admissionTypes = results[4] as List<Map<String, dynamic>>;
        _quotas = results[5] as List<Map<String, dynamic>>;
        _concessions = results[6] as List<Map<String, dynamic>>;
        _communities = (results[7] as List)
            .map((e) => e['comname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty).toSet().toList()..sort();
        _regSeqs = List<Map<String, dynamic>>.from(results[8] as List);
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
    return (src.map((e) => e['claname']?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty).toSet().toList()
      ..sort());
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

  List<AdmissionModel> get _filtered {
    final q = _searchController.text.trim().toLowerCase();
    return _admissions.where((a) {
      if (_statusFilter != 'ALL' && a.admstatus != _statusFilter) return false;
      if (q.isEmpty) return true;
      return a.stuname.toLowerCase().contains(q) ||
          a.admno.toLowerCase().contains(q) ||
          (a.stumobile ?? '').toLowerCase().contains(q);
    }).toList();
  }

  bool get _readonly => _selected?.isAllocated ?? false;

  // ── form lifecycle ────────────────────────────────────────────────
  void _newAdmission() {
    setState(() {
      _selected = null;
      // Default the admission date to today; the user can still change it.
      _admDate = DateTime.now();
      _dob = null;
      _gender = null;
      _bloodGroup = null;
      _source = null;
      _selectedCourse = null;
      _selectedClass = null;
      _selectedAdmName = null;
      _selectedQuoName = null;
      _selectedConId = null;
      _transportMode = null;
      _hostel = null;
      _selectedCommunity = null;
      _selectedRegSeqId = null;
      _regMode = null;
      _selectedYrId = null;
      _selectedYrLabel = null;
      _admnoController.clear();
      for (final c in [
        _nameController, _mobileController, _emailController, _aadharController,
        _addressController, _cityController, _stateController,
        _pinController, _batchController, _prevSchoolController,
        _prevClassController, _prevPercentController, _fatherNameController,
        _fatherMobileController, _motherNameController, _motherMobileController,
        _guardianNameController, _guardianMobileController,
        _fatherOccController, _motherOccController, _guardianOccController,
        _payNameController, _payMobileController,
        _casteController, _religionController, _nationalityController,
        _parentEmailController, _mediumController,
        _remarksController,
      ]) {
        c.clear();
      }
    });
  }

  void _populate(AdmissionModel a) {
    setState(() {
      _selected = a;
      _admDate = a.admdate;
      _dob = a.studob;
      _gender = a.genderLabel;
      _bloodGroup = _bloodGroups.contains(a.stubloodgrp) ? a.stubloodgrp : null;
      _source = _sources.contains(a.admsource) ? a.admsource : null;
      _selectedYrId = a.yrId != 0 ? a.yrId.toString() : _selectedYrId;
      _selectedYrLabel = a.yrlabel.isNotEmpty ? a.yrlabel : _selectedYrLabel;
      _selectedCourse = _courseNames.contains(a.courname) ? a.courname : null;
      _selectedClass = _classNamesFor(a.courname).contains(a.stuclass) ? a.stuclass : null;
      _selectedAdmName = a.admname;
      _selectedQuoName = a.quoname;
      _selectedConId = a.conId?.toString();
      _transportMode = a.transportmode == 'OWN' ? 'Own' : a.transportmode == 'COLLEGE' ? 'College' : null;
      _hostel = a.hostel == 'Y' ? 'Yes' : a.hostel == 'N' ? 'No' : null;
      _admnoController.text = a.admno;
      _nameController.text = a.stuname;
      _mobileController.text = a.stumobile ?? '';
      _emailController.text = a.stuemail ?? '';
      _mediumController.text = a.medium ?? '';
      _parentEmailController.text = a.paremail ?? '';
      _aadharController.text = a.aadharno ?? '';
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
      _remarksController.text = a.admremarks ?? '';
    });
  }

  String? _genderCode(String? g) =>
      g == 'Male' ? 'M' : g == 'Female' ? 'F' : g == 'Other' ? 'T' : null;

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

  Map<String, dynamic> _formData() {
    final auth = context.read<AuthProvider>();
    String? t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    final payer = _derivePayer();
    return {
      'ins_id': auth.insId ?? 1,
      'inscode': auth.inscode ?? '',
      // yr_id/yrlabel removed from public.admission — the year is derived from
      // the schema during allocate_admission_to_student.
      'admno': _admnoController.text.trim(),
      'admdate': _admDate?.toIso8601String().split('T').first,
      'admsource': _source,
      'stuname': _nameController.text.trim(),
      'stugender': _genderCode(_gender) ?? 'M',
      'studob': _dob?.toIso8601String().split('T').first,
      'stumobile': t(_mobileController),
      'stuemail': t(_emailController),
      'aadharno': t(_aadharController),
      'stuaddress': t(_addressController),
      'stucity': t(_cityController),
      'stustate': t(_stateController),
      'stupin': t(_pinController),
      'stubloodgrp': _bloodGroup,
      'courname': _selectedCourse,
      'stuclass': _selectedClass,
      'admname': _selectedAdmName,
      'quoname': _selectedQuoName,
      // Entity IDs resolved from the selected master names, so public.admission
      // carries them the same way the student import does.
      'cour_id': _idFor(_courseList, 'courname', _selectedCourse, 'cour_id'),
      'admit_cour_id': _idFor(_courseList, 'courname', _selectedCourse, 'cour_id'),
      'cla_id': _classIdFor(_selectedClass, _idFor(_courseList, 'courname', _selectedCourse, 'cour_id')),
      'admtype_id': _idFor(_admissionTypes, 'admname', _selectedAdmName, 'adm_id'),
      'quo_id': _idFor(_quotas, 'quoname', _selectedQuoName, 'quo_id'),
      // Admitted year defaults to the current academic year.
      'admittyear': _years.isNotEmpty ? _years.first['yrlabel']?.toString() : null,
      'medium': t(_mediumController),
      'con_id': _selectedConId != null ? int.tryParse(_selectedConId!) : null,
      'stucondesc': _selectedConId != null
          ? _concessions.firstWhere((c) => c['con_id'].toString() == _selectedConId,
              orElse: () => const {})['condesc']
          : null,
      'batch': t(_batchController),
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
      'caste': t(_casteController),
      'religion': t(_religionController),
      'nationality': t(_nationalityController),
      'transportmode': _transportMode == 'Own' ? 'OWN' : _transportMode == 'College' ? 'COLLEGE' : null,
      'hostel': _hostel == 'Yes' ? 'Y' : _hostel == 'No' ? 'N' : null,
      'admremarks': t(_remarksController),
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

  bool _validate() {
    if (_regMode == null) {
      _snack('Select Reg No Mode', AppColors.error);
      return false;
    }
    if (_admDate == null) {
      _snack('Select Admission Date', AppColors.error);
      return false;
    }
    if (_source == null) {
      _snack('Select Source', AppColors.error);
      return false;
    }
    if (_admnoController.text.trim().isEmpty ||
        _nameController.text.trim().isEmpty ||
        _gender == null ||
        _dob == null) {
      _snack('Please fill the required fields (Register No, Name, Gender, Date of Birth).', AppColors.error);
      return false;
    }
    // Pay-in-charge is auto-derived from a parent/guardian, so at least one of
    // Father / Mother / Guardian must have both a name and a mobile number.
    if (_derivePayer()[1].isEmpty) {
      _snack('Enter Name + Mobile for at least one of Father / Mother / Guardian (used as Pay In Charge).', AppColors.error);
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (!_validate()) return;
    final userName = context.read<AuthProvider>().userName; // capture before async gaps
    setState(() => _saving = true);
    try {
      if (_selected == null) {
        final admId = await AdmissionService.addAdmission(_formData());
        // Advance the chosen register sequence so the next admission gets the
        // next no. In Auto the suggestion is always used; in Manual the user may
        // overwrite it, so only consume a sequence number when the entered value
        // still matches the suggestion (otherwise the manual number stands alone).
        if (_selectedRegSeqId != null) {
          final seq = _regSeqs.firstWhere(
            (s) => s['seq_id'].toString() == _selectedRegSeqId,
            orElse: () => const {},
          );
          if (seq.isNotEmpty &&
              (_regMode == 'Auto' || _admnoController.text.trim() == _buildRegNo(seq))) {
            await AdmissionService.bumpRegSeqCurrent(int.parse(_selectedRegSeqId!), _nextRegNum(seq));
          }
        }
        // Class selected → move straight to students; no class → leave the
        // admission pending for Class Allocation.
        var enrolled = false;
        if (_selectedClass != null && _selectedClass!.trim().isNotEmpty) {
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
        _snack(enrolled ? 'Admission saved & moved to students.' : 'Admission saved.', AppColors.success);
        // Reset the register fields so _load()'s auto-pick fills the NEXT number
        // (the sequence counter was just bumped above).
        _admnoController.clear();
        _selectedRegSeqId = null;
      } else {
        await AdmissionService.updateAdmission(_selected!.admId, _formData());
        _snack('Admission updated.', AppColors.success);
      }
      await _load();
      if (mounted) setState(() => _selected = null);
    } catch (e) {
      _snack('Save failed. ${friendlyError(e)}', AppColors.error);
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
        title: const Text('Cancel admission'),
        content: Text('Cancel the admission for ${a.stuname}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel admission'),
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
      if (mounted) setState(() => _selected = null);
    } catch (e) {
      _snack('Cancel failed. ${friendlyError(e)}', AppColors.error);
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

  // ── build ─────────────────────────────────────────────────────────
  // Page shell per admission-design.md § 1: edge-to-edge 2-pane layout (the
  // list and detail cards each carry their own white card, so no outer card
  // wraps the whole screen).
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 340.w, child: _buildList()),
        SizedBox(width: 16.w),
        Expanded(child: _buildDetail()),
      ],
    );
  }

  // ── left panel ────────────────────────────────────────────────────
  Widget _buildList() {
    final counts = _statusCounts;
    final filtered = _filtered;
    return Container(
      decoration: AppCard.decoration(),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 8.h),
            child: Row(
              children: [
                const CardTitleBlock(icon: 'profile-add', title: 'Admissions', subtitle: 'all admission records in this institution'),
                const Spacer(),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 3.h),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12.r),
                  ),
                  child: Text('${_admissions.length}',
                      style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 14.w),
            child: Row(
              children: [
                Expanded(
                  child: AppSearchField(
                    controller: _searchController,
                    hintText: 'Search name / no / mobile',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                SizedBox(width: 8.w),
                _newButton(),
              ],
            ),
          ),
          SizedBox(height: 8.h),
          _statusChips(counts),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? Center(
                        child: Text('No admissions',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 13.sp)),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.symmetric(vertical: 4.h),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) => _listTile(filtered[i], i),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _newButton() {
    return SizedBox(
      height: 36.h,
      child: ElevatedButton.icon(
        onPressed: _newAdmission,
        icon: const Icon(Icons.add, size: 16),
        label: const Text('New'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          elevation: 0,
        ),
      ),
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
        padding: EdgeInsets.symmetric(horizontal: 14.w),
        children: [
          for (final w in chips) Padding(padding: EdgeInsets.only(right: 6.w), child: w),
        ],
      ),
    );
  }

  Widget _chip(String value, String label, int count, Color color) {
    final selected = _statusFilter == value;
    return InkWell(
      onTap: () => setState(() => _statusFilter = value),
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
          ? AppColors.accent.withValues(alpha: 0.1)
          : (i.isEven ? Colors.white : AppColors.surface),
      child: InkWell(
        onTap: () => _populate(a),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 9.h),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
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
                            color: AppColors.textPrimary)),
                    SizedBox(height: 1.h),
                    Text(
                        '${a.admno}'
                        '${a.isAllocated && a.allocatedclass != null ? ' • ${a.allocatedclass}' : a.stuclass != null && a.stuclass!.isNotEmpty ? ' • ${a.stuclass}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
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

  Widget _statusBadge(String s, {bool small = false}) {
    final color = _statusColor(s);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 7.w : 10.w, vertical: small ? 3.h : 5.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: Text(AdmissionStatus.label(s),
          style: TextStyle(
              fontSize: small ? 10.sp : 12.sp, fontWeight: FontWeight.w700, color: color)),
    );
  }

  // ── right panel ───────────────────────────────────────────────────
  Widget _buildDetail() {
    return Container(
      decoration: AppCard.decoration(),
      child: Column(
        children: [
          _detailHeader(),
          Divider(height: 1.h, color: AppColors.border),
          _stepperHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(18.w),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_readonly) _allocatedBanner(),
                  ..._stepSections(_currentStep),
                ],
              ),
            ),
          ),
          Divider(height: 1.h, color: AppColors.border),
          _actionBar(),
        ],
      ),
    );
  }

  /// Sections rendered for the given wizard step.
  List<Widget> _stepSections(int step) {
    switch (step) {
      case 0:
        return [
          _section('Admission', [
            _row([
              _dropdown('Reg No Mode', _regMode, _regModes, (v) => setState(() {
                    _regMode = v;
                    // Both Manual (suggest + edit) and Auto (generate + lock) use
                    // a register sequence, so keep the chosen sequence across modes.
                  }), hint: 'Select mode'),
              _regSeqField(),
              _text('Register No *', _admnoController, enabled: _regMode == 'Manual'),
            ]),
            _row([
              _dateField('Admission Date', _admDate, (d) => setState(() => _admDate = d), hint: 'Select date'),
              _dropdown('Source', _source, _sources, (v) => setState(() => _source = v)),
            ]),
          ]),
        ];
      case 1:
        return [
          _section('Applicant', [
            _row([
              _text('Full Name *', _nameController),
              _dropdown('Gender *', _gender, _genders, (v) => setState(() => _gender = v)),
              _dateField('Date of Birth *', _dob, (d) => setState(() => _dob = d)),
            ]),
            _row([
              _text('Mobile', _mobileController, keyboard: TextInputType.phone),
              _text('Email', _emailController, keyboard: TextInputType.emailAddress),
              _dropdown('Blood Group', _bloodGroup, _bloodGroups, (v) => setState(() => _bloodGroup = v)),
            ]),
            _row([
              _text('Aadhar No', _aadharController),
              const Spacer(),
              const Spacer(),
            ]),
            _row([
              _text('Address', _addressController),
              _text('City', _cityController),
              _text('State', _stateController),
            ]),
            _row([
              _text('Pin Code', _pinController),
              const Spacer(),
              const Spacer(),
            ]),
          ]),
          _section('Parent / Guardian', [
            _row([
              _text('Father Name', _fatherNameController),
              _text('Father Mobile', _fatherMobileController, keyboard: TextInputType.phone),
              _text('Father Occupation', _fatherOccController),
            ]),
            _row([
              _text('Mother Name', _motherNameController),
              _text('Mother Mobile', _motherMobileController, keyboard: TextInputType.phone),
              _text('Mother Occupation', _motherOccController),
            ]),
            _row([
              _text('Guardian Name', _guardianNameController),
              _text('Guardian Mobile', _guardianMobileController, keyboard: TextInputType.phone),
              _text('Guardian Occupation', _guardianOccController),
            ]),
            _row([
              _text('Parent Email', _parentEmailController, keyboard: TextInputType.emailAddress),
              const Spacer(),
              const Spacer(),
            ]),
            Padding(
              padding: EdgeInsets.only(top: 4.h),
              child: Row(children: [
                Icon(Icons.info_outline, size: 14.sp, color: AppColors.textLight),
                SizedBox(width: 6.w),
                Expanded(
                  child: Text(
                    'Pay In Charge is set automatically from Father → Mother → Guardian (the first with both Name and Mobile).',
                    style: TextStyle(fontSize: 11.sp, color: AppColors.textLight),
                  ),
                ),
              ]),
            ),
          ]),
          _section('Remarks', [
            _text('Notes', _remarksController, maxLines: 2),
          ]),
        ];
      case 2:
      default:
        return [
          _section('Applied For', [
            _row([
              _dropdown('Course', _selectedCourse, _courseNames, (v) => setState(() {
                    _selectedCourse = v;
                    // drop a class that no longer belongs to the chosen course
                    if (_selectedClass != null && !_classNamesFor(v).contains(_selectedClass)) {
                      _selectedClass = null;
                    }
                  })),
              _dropdown('Preferred Class', _selectedClass, _classNamesFor(_selectedCourse),
                  (v) => setState(() => _selectedClass = v), hint: 'Select class'),
              _text('Batch', _batchController),
            ]),
            _row([
              _dropdownMap('Admission Type', _selectedAdmName, _admissionTypes, 'admname', 'admname',
                  (v) => setState(() => _selectedAdmName = v)),
              _dropdownMap('Quota', _selectedQuoName, _quotas, 'quoname', 'quoname',
                  (v) => setState(() => _selectedQuoName = v)),
              _dropdownMap('Concession', _selectedConId, _concessions, 'con_id', 'condesc',
                  (v) => setState(() => _selectedConId = v)),
            ]),
            _row([
              _text('Medium', _mediumController),
              const Spacer(),
              const Spacer(),
            ]),
          ]),
          _section('Additional Details', [
            _row([
              _dropdown('Community', _selectedCommunity, _communities,
                  (v) => setState(() => _selectedCommunity = v)),
              _text('Caste', _casteController),
              _text('Religion', _religionController),
            ]),
            _row([
              _text('Nationality', _nationalityController),
              _dropdown('Transport', _transportMode, _transportOptions,
                  (v) => setState(() => _transportMode = v)),
              _dropdown('Hostel', _hostel, _hostelOptions,
                  (v) => setState(() => _hostel = v)),
            ]),
          ]),
          _section('Previous School', [
            _row([
              _text('School / College', _prevSchoolController),
              _text('Class / Course', _prevClassController),
              _text('Marks %', _prevPercentController, keyboard: TextInputType.number),
            ]),
          ]),
        ];
    }
  }

  /// Top-of-detail stepper header: row of circles (36w) + label + connector
  /// bars between them. Tap any circle to jump.
  Widget _stepperHeader() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 14.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(_wizardLabels.length * 2 - 1, (i) {
          if (i.isEven) {
            return _stepCell(i ~/ 2);
          }
          return Expanded(child: _stepConnector(i ~/ 2));
        }),
      ),
    );
  }

  Widget _stepCell(int index) {
    final isDone = index < _currentStep;
    final isActive = index == _currentStep;
    final color = isDone
        ? AppColors.success
        : isActive
            ? AppColors.primary
            : AppColors.textSecondary.withValues(alpha: 0.4);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _currentStep = index),
          customBorder: const CircleBorder(),
          child: Container(
            width: 36.w,
            height: 36.w,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Center(
              child: AppIcon(_wizardIcons[index], size: 18, color: Colors.white),
            ),
          ),
        ),
        SizedBox(height: 4.h),
        Text(
          _wizardLabels[index],
          style: TextStyle(
            fontSize: 12.sp,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }

  /// Horizontal connector bar between step circles. Padded down so it lines
  /// up with the circle center rather than the column's vertical centre.
  Widget _stepConnector(int afterIndex) {
    final filled = afterIndex < _currentStep;
    return Padding(
      padding: EdgeInsets.only(bottom: 18.h),
      child: Container(
        height: 2,
        color: filled ? AppColors.success : AppColors.border,
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
        color: AppColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const AppIcon('tick-circle', size: 16, color: AppColors.success),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              'Allocated to ${a.allocatedclass ?? '—'} — admitted as student #${a.stuId}. Record is locked.',
              style: TextStyle(fontSize: 12.sp, color: AppColors.success, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailHeader() {
    final a = _selected;
    return Padding(
      padding: EdgeInsets.fromLTRB(18.w, 14.h, 18.w, 14.h),
      child: Row(
        children: [
          AppIcon(a == null ? 'profile-add' : 'profile-circle', size: 20, color: AppColors.primary),
          SizedBox(width: 10.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a == null ? 'New Admission' : a.stuname,
                    style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                if (a != null)
                  Text(a.admno,
                      style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
              ],
            ),
          ),
          if (a != null) _statusBadge(a.admstatus),
        ],
      ),
    );
  }

  Widget _actionBar() {
    final a = _selected;
    final allocated = a?.isAllocated ?? false;
    final isLastStep = _currentStep == _wizardLabels.length - 1;
    return Padding(
      padding: EdgeInsets.all(14.w),
      child: Row(
        children: [
          if (a != null && !allocated)
            OutlinedButton.icon(
              onPressed: _saving ? null : _cancel,
              icon: const Icon(Icons.block, size: 16),
              label: const Text('Cancel Admission'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
                padding: EdgeInsets.symmetric(horizontal: 12.w),
              ),
            ),
          if (_currentStep > 0) ...[
            SizedBox(width: a != null && !allocated ? 8.w : 0),
            OutlinedButton.icon(
              onPressed: _saving ? null : () => setState(() => _currentStep -= 1),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back'),
            ),
          ],
          const Spacer(),
          if (!allocated)
            if (isLastStep)
              // Final step — Save Admission (amber per spec § 8).
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save, size: 16),
                label: Text(a == null ? 'Save Admission' : 'Update'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                ),
              )
            else
              // Steps 0-2 — Next (amber per spec § 8).
              ElevatedButton.icon(
                onPressed: _saving ? null : () => setState(() => _currentStep += 1),
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('Next'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                ),
              ),
          if (allocated)
            Text('Allocated — record locked (allocate in the Class Allocation module)',
                style: TextStyle(fontSize: 12.sp, fontStyle: FontStyle.italic, color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  // ── form widget helpers ───────────────────────────────────────────
  /// Section card per admission-design.md § 5:
  ///   - Outer Container: white, 10r radius, AppColors.border border,
  ///     bottom margin 14h.
  ///   - Header band: AppColors.accent @ 0.06 background, bottom border,
  ///     padding 16.w / 12.h. Section icon + 15.sp w700 title.
  ///   - Body: Padding(16.w / 14.h / 16.w / 16.h) wrapping the form rows.
  Widget _section(String title, List<Widget> children) {
    const sectionIcons = {
      'Admission':          'document-text',
      'Applicant':          'user',
      'Applied For':        'book-1',
      'Additional Details': 'info-circle',
      'Previous School':    'teacher',
      'Parent / Guardian':  'people',
      'Remarks':            'note',
    };
    final icon = sectionIcons[title] ?? 'category';
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 14.h),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Accent-tinted header band with icon + title.
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.06),
              border: const Border(
                bottom: BorderSide(color: AppColors.border),
              ),
            ),
            child: CardTitleBlock(icon: icon, title: title),
          ),
          // Body — wraps the form rows.
          Padding(
            padding: EdgeInsets.fromLTRB(16.w, 14.h, 16.w, 16.h),
            child: FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
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

  // Per admission-design.md § 4: bold black label above each field.
  Widget _label(String text) => Padding(
        padding: EdgeInsets.only(bottom: 6.h, left: 2.w),
        child: Text(text,
            style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black)),
      );

  // Per admission-design.md § 4: isDense OFF, 14 vertical padding, focused
  // border in accent.
  InputDecoration _dec({bool filled = false, String? hint}) {
    final idle = filled ? AppColors.accent : AppColors.border;
    return InputDecoration(
        contentPadding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 14.h),
        filled: true,
        fillColor: _readonly ? AppColors.surface : Colors.white,
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: 13.sp),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.r),
            borderSide: BorderSide(color: idle, width: 1.5)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.r),
            borderSide: BorderSide(color: idle, width: 1.5)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.r),
            borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
      );
  }

  Widget _text(String label, TextEditingController c,
      {bool enabled = true, TextInputType? keyboard, int maxLines = 1}) {
    final filled = c.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        TextFormField(
          controller: c,
          enabled: enabled && !_readonly,
          keyboardType: keyboard,
          maxLines: maxLines,
          onChanged: (_) => setState(() {}),
          style: TextStyle(fontSize: 13.sp, color: filled ? AppColors.accent : AppColors.textPrimary, fontWeight: filled ? FontWeight.w600 : null),
          decoration: _dec(filled: filled),
        ),
      ],
    );
  }

  Widget _dropdown(String label, String? value, List<String> items, ValueChanged<String?> onChanged, {String? hint}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        DropdownButtonFormField<String>(
          initialValue: items.contains(value) ? value : null,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          decoration: _dec(filled: items.contains(value), hint: hint ?? 'Select ${label.replaceAll(' *', '').trim().toLowerCase()}'),
          items: items
              .map((e) => DropdownMenuItem(value: e, child: Text(e, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis)))
              .toList(),
          selectedItemBuilder: (context) => items
              .map((e) => Align(alignment: Alignment.centerLeft, child: Text(e, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))))
              .toList(),
          onChanged: _readonly ? null : onChanged,
        ),
      ],
    );
  }

  Widget _dropdownMap(String label, String? value, List<Map<String, dynamic>> items,
      String valueKey, String labelKey, ValueChanged<String?> onChanged, {String? hint}) {
    final values = items.map((e) => e[valueKey].toString()).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        DropdownButtonFormField<String>(
          initialValue: values.contains(value) ? value : null,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          decoration: _dec(filled: values.contains(value), hint: hint ?? 'Select ${label.replaceAll(' *', '').trim().toLowerCase()}'),
          items: items
              .map((e) => DropdownMenuItem(
                    value: e[valueKey].toString(),
                    child: Text(e[labelKey]?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          selectedItemBuilder: (context) => items
              .map((e) => Align(alignment: Alignment.centerLeft, child: Text(e[labelKey]?.toString() ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))))
              .toList(),
          onChanged: _readonly ? null : onChanged,
        ),
      ],
    );
  }

  /// Register-sequence picker. Selecting one auto-fills the Register No field
  /// from the sequence's current counter (prefix/suffix + zero-padded next no).
  Widget _regSeqField() {
    final values = _regSeqs.map((s) => s['seq_id'].toString()).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Register Sequence'),
        DropdownButtonFormField<String>(
          initialValue: values.contains(_selectedRegSeqId) ? _selectedRegSeqId : null,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          decoration: _dec(filled: values.contains(_selectedRegSeqId)),
          hint: Text('Select register sequence', style: TextStyle(fontSize: 13.sp, color: AppColors.textLight)),
          items: _regSeqs
              .map((s) => DropdownMenuItem(
                    value: s['seq_id'].toString(),
                    child: Text(s['seqname']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          selectedItemBuilder: (context) => _regSeqs
              .map((s) => Align(alignment: Alignment.centerLeft, child: Text(s['seqname']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))))
              .toList(),
          // Enabled in both Auto and Manual — picking a sequence fills the
          // suggested number. In Auto the Register No field is locked; in Manual
          // it stays editable so the user can overwrite the suggestion.
          onChanged: (_readonly || _regMode == null)
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
      ],
    );
  }

  Widget _yearDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Academic Year'),
        DropdownButtonFormField<String>(
          initialValue: _selectedYrId,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          decoration: _dec(filled: _selectedYrId != null, hint: 'Select year'),
          items: _years
              .map((y) => DropdownMenuItem(
                    value: y['yr_id'].toString(),
                    child: Text(y['yrlabel']?.toString() ?? '', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          selectedItemBuilder: (context) => _years
              .map((y) => Align(alignment: Alignment.centerLeft, child: Text(y['yrlabel']?.toString() ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))))
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

  Widget _dateField(String label, DateTime? value, ValueChanged<DateTime> onPick, {String? hint}) {
    final placeholder = hint ?? 'Select ${label.replaceAll(' *', '').trim().toLowerCase()}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        FocusableTap(
          onTap: _readonly
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
            decoration: _dec(filled: value != null),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value == null ? placeholder : _fmtDate(value),
                    style: TextStyle(
                        fontSize: 13.sp,
                        color: value == null ? AppColors.textLight : AppColors.accent,
                        fontWeight: value == null ? null : FontWeight.w600),
                  ),
                ),
                const AppIcon.linear('calendar', size: 14, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
}
