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
import '../../widgets/app_search_field.dart';

/// Admission module — left: list of admissions; right: detail/edit form.
/// New admissions land in PUBLIC `admission` as PENDING. An admin allocates
/// a section, which moves the record into the per-schema students/parents
/// tables via the `allocate_admission_to_student` RPC.
class AdmissionScreen extends StatefulWidget {
  const AdmissionScreen({super.key});

  @override
  State<AdmissionScreen> createState() => _AdmissionScreenState();
}

class _AdmissionScreenState extends State<AdmissionScreen> {
  final _searchController = TextEditingController();

  // ── multi-step wizard state ──────────────────────────────────────
  int _currentStep = 0;
  static const _wizardSteps = [
    {'icon': 'document-text', 'label': 'Admission'},
    {'icon': 'user', 'label': 'Applicant'},
    {'icon': 'book-1', 'label': 'Academic'},
    {'icon': 'people', 'label': 'Family'},
  ];

  // ── form controllers ──────────────────────────────────────────────
  final _admnoController = TextEditingController();
  final _nameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _emailController = TextEditingController();
  final _aadharController = TextEditingController();
  final _emisController = TextEditingController();
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _pinController = TextEditingController();
  final _prevSchoolController = TextEditingController();
  final _prevClassController = TextEditingController();
  final _prevBoardController = TextEditingController();
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
  final _casteController = TextEditingController();
  final _religionController = TextEditingController();
  final _nationalityController = TextEditingController();
  final _remarksController = TextEditingController();

  String? _gender;
  String? _bloodGroup;
  DateTime? _dob;
  DateTime _admDate = DateTime.now();
  String? _source = 'WALK-IN';
  String? _selectedYrId;
  String? _selectedYrLabel;
  String? _selectedAdmittedStandard;
  String? _selectedStandard;
  String? _selectedSection;
  String? _selectedConId;
  String? _selectedMedium;
  String? _transportMode;
  String? _hostel;
  String? _selectedCommunity;
  String? _selectedRegSeqId;
  String _regMode = 'Manual';

  static const _regModes = ['Manual', 'Auto'];
  static const _mediumOptions = ['English', 'Tamil', 'Hindi', 'French', 'Telugu', 'Malayalam', 'Other'];
  static const _transportOptions = ['Own', 'College'];
  static const _hostelOptions = ['Yes', 'No'];
  static const _genders = ['Male', 'Female', 'Other'];
  static const _bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
  static const _sources = ['WALK-IN', 'ONLINE', 'REFERRAL', 'AGENT'];

  List<AdmissionModel> _admissions = [];
  List<Map<String, dynamic>> _years = [];
  List<Map<String, dynamic>> _standardList = []; // {cgrp_id, clagrpname}
  List<Map<String, dynamic>> _sectionList = [];  // {claname, cgrp_id}
  List<Map<String, dynamic>> _concessions = [];
  List<String> _communities = [];
  List<Map<String, dynamic>> _regSeqs = [];

  AdmissionModel? _selected;
  String _statusFilter = 'ALL';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _searchController, _admnoController, _nameController, _mobileController,
      _emailController, _aadharController, _emisController, _addressController,
      _cityController, _stateController, _pinController,
      _prevSchoolController, _prevClassController, _prevBoardController, _prevPercentController,
      _fatherNameController, _fatherMobileController, _motherNameController,
      _motherMobileController, _guardianNameController, _guardianMobileController,
      _fatherOccController, _motherOccController, _guardianOccController,
      _casteController, _religionController, _nationalityController, _remarksController,
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
        SupabaseService.client.from('institutionyear').select('iyr_id, yrlabel').eq('ins_id', insId).eq('activestatus', 1).order('iyr_id', ascending: false),
        SupabaseService.client.from('clagrp').select('cgrp_id, clagrpname, ordid').eq('ins_id', insId).eq('activestatus', 1).order('ordid', ascending: true).order('clagrpname', ascending: true),
        SupabaseService.client.from('class').select('claname, cgrp_id, ordid').eq('ins_id', insId).eq('activestatus', 1).order('ordid', ascending: true).order('claname', ascending: true),
        SupabaseService.fromSchema('concessioncategory').select('con_id, condesc').eq('activestatus', 1),
        SupabaseService.client.from('community').select('comname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.client.from('regnoseq').select('*').eq('activestatus', 1).order('rns_id', ascending: true),
      ]);
      if (!mounted) return;
      setState(() {
        _admissions = results[0] as List<AdmissionModel>;
        // institutionyear returns iyr_id as the year row id; the admission table
        // stores yr_id which on this app's single-institution setup is the same
        // sequence — we map iyr_id → yr_id for the dropdown.
        _years = (results[1] as List).map((r) => {
          'yr_id': r['iyr_id'],
          'yrlabel': r['yrlabel'],
        }).cast<Map<String, dynamic>>().toList();
        _standardList = List<Map<String, dynamic>>.from(results[2] as List);
        _sectionList = List<Map<String, dynamic>>.from(results[3] as List);
        _concessions = List<Map<String, dynamic>>.from(results[4] as List);
        _communities = (results[5] as List)
            .map((e) => e['comname']?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty).toSet().toList();
        _regSeqs = List<Map<String, dynamic>>.from(results[6] as List);
        if (_years.isNotEmpty && _selectedYrId == null) {
          _selectedYrId = _years.first['yr_id'].toString();
          _selectedYrLabel = _years.first['yrlabel']?.toString();
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Failed to load admissions. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  // ── standard / section options ────────────────────────────────────
  List<String> get _standardNames =>
      (_standardList.map((e) => e['clagrpname']?.toString().trim() ?? '')
          .where((s) => s.isNotEmpty).toSet().toList());

  List<String> _sectionNamesFor(String? standardName) {
    Iterable<Map<String, dynamic>> src = _sectionList;
    if (standardName != null && standardName.trim().isNotEmpty) {
      final std = _standardList.firstWhere(
        (c) => (c['clagrpname']?.toString().trim() ?? '') == standardName.trim(),
        orElse: () => const {},
      );
      final cgrpId = std['cgrp_id'];
      src = cgrpId == null
          ? const <Map<String, dynamic>>[]
          : _sectionList.where((cl) => cl['cgrp_id'] == cgrpId);
    }
    return (src.map((e) => e['claname']?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty).toSet().toList());
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
      _admDate = DateTime.now();
      _dob = null;
      _gender = null;
      _bloodGroup = null;
      _source = 'WALK-IN';
      _selectedAdmittedStandard = null;
      _selectedStandard = null;
      _selectedSection = null;
      _selectedConId = null;
      _selectedMedium = null;
      _transportMode = null;
      _hostel = null;
      _selectedCommunity = null;
      _selectedRegSeqId = null;
      _regMode = 'Manual';
      if (_years.isNotEmpty) {
        _selectedYrId = _years.first['yr_id'].toString();
        _selectedYrLabel = _years.first['yrlabel']?.toString();
      }
      _admnoController.clear();
      for (final c in [
        _nameController, _mobileController, _emailController, _aadharController, _emisController,
        _addressController, _cityController, _stateController, _pinController,
        _prevSchoolController, _prevClassController, _prevBoardController, _prevPercentController,
        _fatherNameController, _fatherMobileController, _motherNameController, _motherMobileController,
        _guardianNameController, _guardianMobileController,
        _fatherOccController, _motherOccController, _guardianOccController,
        _casteController, _religionController, _nationalityController, _remarksController,
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
      _source = _sources.contains(a.admsource) ? a.admsource : 'WALK-IN';
      _selectedYrId = a.yrId != 0 ? a.yrId.toString() : _selectedYrId;
      _selectedYrLabel = a.yrlabel.isNotEmpty ? a.yrlabel : _selectedYrLabel;
      _selectedAdmittedStandard = _standardNames.contains(a.admclagrpname) ? a.admclagrpname : null;
      _selectedStandard = _standardNames.contains(a.clagrpname) ? a.clagrpname : null;
      _selectedSection = _sectionNamesFor(a.clagrpname).contains(a.stuclass) ? a.stuclass : null;
      _selectedConId = a.conId?.toString();
      _selectedMedium = _mediumOptions.contains(a.medium) ? a.medium : null;
      _transportMode = a.transportmode == 'OWN' ? 'Own' : a.transportmode == 'COLLEGE' ? 'College' : null;
      _hostel = a.hostel == 'Y' ? 'Yes' : a.hostel == 'N' ? 'No' : null;
      _admnoController.text = a.admno;
      _nameController.text = a.stuname;
      _mobileController.text = a.stumobile ?? '';
      _emailController.text = a.stuemail ?? '';
      _aadharController.text = a.aadharno ?? '';
      _emisController.text = a.emisno ?? '';
      _addressController.text = a.stuaddress ?? '';
      _cityController.text = a.stucity ?? '';
      _stateController.text = a.stustate ?? '';
      _pinController.text = a.stupin ?? '';
      _prevSchoolController.text = a.prevschool ?? '';
      _prevClassController.text = a.prevclass ?? '';
      _prevBoardController.text = a.prevboard ?? '';
      _prevPercentController.text = a.prevpercent?.toString() ?? '';
      _fatherNameController.text = a.fathername ?? '';
      _fatherMobileController.text = a.fathermobile ?? '';
      _motherNameController.text = a.mothername ?? '';
      _motherMobileController.text = a.mothermobile ?? '';
      _guardianNameController.text = a.guardianname ?? '';
      _guardianMobileController.text = a.guardianmobile ?? '';
      _selectedCommunity = _communities.contains(a.community) ? a.community : null;
      _selectedRegSeqId = null;
      _regMode = 'Manual';
      _casteController.text = a.caste ?? '';
      _religionController.text = a.religion ?? '';
      _nationalityController.text = a.nationality ?? '';
      _fatherOccController.text = a.fatheroccupation ?? '';
      _motherOccController.text = a.motheroccupation ?? '';
      _guardianOccController.text = a.guardianoccupation ?? '';
      _remarksController.text = a.admremarks ?? '';
    });
  }

  String? _genderCode(String? g) =>
      g == 'Male' ? 'M' : g == 'Female' ? 'F' : g == 'Other' ? 'T' : null;

  int _nextRegNum(Map<String, dynamic> seq) {
    final cur = (seq['rnscurrent'] as num?)?.toInt() ?? 0;
    final start = (seq['rnsstart'] as num?)?.toInt() ?? 1;
    return cur < start ? start : cur + 1;
  }

  String _buildRegNo(Map<String, dynamic> seq) {
    final width = (seq['rnswidth'] as num?)?.toInt() ?? 0;
    final padded = _nextRegNum(seq).toString().padLeft(width, '0');
    final affix = seq['rnsaffix']?.toString() ?? '';
    return (seq['rnsmode']?.toString() ?? 'P') == 'P' ? '$affix$padded' : '$padded$affix';
  }

  /// Pay-in-charge auto-derived from Father → Mother → Guardian
  /// (first with both name and mobile).
  List<String> _derivePayer() {
    final f = _fatherNameController.text.trim(), fm = _fatherMobileController.text.trim();
    final m = _motherNameController.text.trim(), mm = _motherMobileController.text.trim();
    final g = _guardianNameController.text.trim(), gm = _guardianMobileController.text.trim();
    if (f.isNotEmpty && fm.isNotEmpty) return [f, fm];
    if (m.isNotEmpty && mm.isNotEmpty) return [m, mm];
    if (g.isNotEmpty && gm.isNotEmpty) return [g, gm];
    return ['', ''];
  }

  Map<String, dynamic> _formData() {
    final auth = context.read<AuthProvider>();
    String? t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    final payer = _derivePayer();
    return {
      'ins_id': auth.insId ?? 1,
      'inscode': auth.inscode ?? '',
      'yr_id': int.tryParse(_selectedYrId ?? '0') ?? 0,
      'yrlabel': _selectedYrLabel ?? '',
      'admno': _admnoController.text.trim(),
      'admdate': _admDate.toIso8601String().split('T').first,
      'admsource': _source,
      'stuname': _nameController.text.trim(),
      'stugender': _genderCode(_gender) ?? 'M',
      'studob': _dob?.toIso8601String().split('T').first,
      'stumobile': t(_mobileController),
      'stuemail': t(_emailController),
      'aadharno': t(_aadharController),
      'emisno': t(_emisController),
      'stuaddress': t(_addressController),
      'stucity': t(_cityController),
      'stustate': t(_stateController),
      'stupin': t(_pinController),
      'stubloodgrp': _bloodGroup,
      'clagrpname': _selectedStandard,
      'admclagrpname': _selectedAdmittedStandard ?? _selectedStandard,
      'stuclass': _selectedSection,
      'con_id': _selectedConId != null ? int.tryParse(_selectedConId!) : null,
      'stucondesc': _selectedConId != null
          ? _concessions.firstWhere((c) => c['con_id'].toString() == _selectedConId,
              orElse: () => const {})['condesc']
          : null,
      'medium': _selectedMedium,
      'prevschool': t(_prevSchoolController),
      'prevclass': t(_prevClassController),
      'prevboard': t(_prevBoardController),
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

  bool _validate() {
    if (_admnoController.text.trim().isEmpty ||
        _nameController.text.trim().isEmpty ||
        _gender == null ||
        _dob == null) {
      _snack('Please fill the required fields (Admission No, Name, Gender, Date of Birth).', AppColors.error);
      return false;
    }
    if (_derivePayer()[1].isEmpty) {
      _snack('Enter Name + Mobile for at least one of Father / Mother / Guardian (used as Pay In Charge).', AppColors.error);
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (!_validate()) return;
    setState(() => _saving = true);
    try {
      if (_selected == null) {
        await AdmissionService.addAdmission(_formData());
        if (_selectedRegSeqId != null) {
          final seq = _regSeqs.firstWhere(
            (s) => s['rns_id'].toString() == _selectedRegSeqId,
            orElse: () => const {},
          );
          if (seq.isNotEmpty) {
            await AdmissionService.bumpRegSeqCurrent(int.parse(_selectedRegSeqId!), _nextRegNum(seq));
          }
        }
        _snack('Admission saved.', AppColors.success);
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

  /// Allocate the selected admission into a section — moves the record to
  /// students/parents/parentdetail via the SECURITY DEFINER RPC.
  Future<void> _allocate() async {
    final a = _selected;
    if (a == null || a.isAllocated) return;
    final by = context.read<AuthProvider>().userName;
    String? chosenSection = a.stuclass;
    final admnoCtrl = TextEditingController(text: a.admno);
    final picked = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Allocate Section'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${a.stuname} • ${a.admno}',
                    style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                SizedBox(height: 12.h),
                DropdownButtonFormField<String>(
                  initialValue: _sectionNamesFor(a.clagrpname).contains(chosenSection) ? chosenSection : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Section *', isDense: true, border: OutlineInputBorder()),
                  items: _sectionNamesFor(a.clagrpname)
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (v) => setLocal(() => chosenSection = v),
                ),
                SizedBox(height: 10.h),
                TextField(
                  controller: admnoCtrl,
                  decoration: const InputDecoration(labelText: 'Admission No *', isDense: true, border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (chosenSection == null || chosenSection!.isEmpty || admnoCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, {'section': chosenSection!, 'admno': admnoCtrl.text.trim()});
              },
              child: const Text('Allocate'),
            ),
          ],
        ),
      ),
    );
    admnoCtrl.dispose();
    if (picked == null) return;
    setState(() => _saving = true);
    try {
      final stuId = await AdmissionService.allocateClass(
        admId: a.admId,
        className: picked['section']!,
        stuadmno: picked['admno']!,
        allocatedBy: by,
      );
      _snack('Allocated. Student #$stuId created.', AppColors.success);
      await _load();
      if (mounted) setState(() => _selected = null);
    } catch (e) {
      _snack('Allocation failed. ${friendlyError(e)}', AppColors.error);
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
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 320.w, child: _buildList()),
        SizedBox(width: 12.w),
        Expanded(child: _buildDetail()),
      ],
    );
  }

  Widget _buildList() {
    final counts = _statusCounts;
    final filtered = _filtered;
    return Container(
      decoration: AppCard.decoration(),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 12.h),
            child: Row(
              children: [
                const AppIcon('profile-add', size: 18, color: AppColors.primary),
                SizedBox(width: 8.w),
                Text('Admissions',
                    style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.primary)),
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
                SizedBox(
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
                ),
              ],
            ),
          ),
          SizedBox(height: 14.h),
          _statusChips(counts),
          SizedBox(height: 12.h),
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
                        itemBuilder: (_, i) => _listTile(filtered[i]),
                      ),
          ),
        ],
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
                style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : color)),
            SizedBox(width: 5.w),
            Text('$count',
                style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : color)),
          ],
        ),
      ),
    );
  }

  Widget _listTile(AdmissionModel a) {
    final selected = _selected?.admId == a.admId;
    final color = _statusColor(a.admstatus);
    return Material(
      color: selected ? AppColors.accent.withValues(alpha: 0.1) : Colors.transparent,
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
          style: TextStyle(fontSize: small ? 10.sp : 12.sp, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _buildDetail() {
    return Container(
      decoration: AppCard.decoration(),
      child: Column(
        children: [
          _detailHeader(),
          Divider(height: 1.h, color: AppColors.border),
          _buildStepperHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(18.w, 0, 18.w, 18.h),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_readonly) _allocatedBanner(),
                  if (_currentStep == 0) ..._stepAdmissionBlocks(),
                  if (_currentStep == 1) ..._stepApplicantBlocks(),
                  if (_currentStep == 2) ..._stepAcademicBlocks(),
                  if (_currentStep == 3) ..._stepFamilyBlocks(),
                  _buildWizardNav(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepperHeader() {
    return Container(
      padding: EdgeInsets.fromLTRB(18.w, 14.h, 18.w, 14.h),
      color: Colors.white,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(_wizardSteps.length * 2 - 1, (index) {
          if (index.isOdd) {
            final stepBefore = index ~/ 2;
            final isDone = stepBefore < _currentStep;
            return Expanded(
              child: Container(
                height: 3,
                margin: EdgeInsets.symmetric(horizontal: 6.w),
                decoration: BoxDecoration(
                  color: isDone ? AppColors.success : AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }
          final stepIndex = index ~/ 2;
          final step = _wizardSteps[stepIndex];
          final isActive = stepIndex == _currentStep;
          final isDone = stepIndex < _currentStep;
          final color = isDone
              ? AppColors.success
              : isActive
                  ? AppColors.primary
                  : AppColors.textSecondary.withValues(alpha: 0.4);
          return GestureDetector(
            onTap: () => setState(() => _currentStep = stepIndex),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36.w,
                  height: 36.w,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isDone || isActive ? color : Colors.white,
                    border: Border.all(color: color, width: 2),
                    shape: BoxShape.circle,
                  ),
                  child: isDone
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : AppIcon(step['icon'] as String, size: 16,
                          color: isActive ? Colors.white : color),
                ),
                SizedBox(height: 6.h),
                Text(step['label'] as String,
                    style: TextStyle(
                        fontSize: 12.sp,
                        fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                        color: color)),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildWizardNav() {
    return Padding(
      padding: EdgeInsets.only(top: 8.h),
      child: Row(
        children: [
          if (_currentStep > 0)
            OutlinedButton.icon(
              onPressed: () => setState(() => _currentStep -= 1),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back'),
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 18.w, vertical: 12.h),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.r)),
              ),
            ),
          const Spacer(),
          if (_currentStep < _wizardSteps.length - 1)
            ElevatedButton.icon(
              onPressed: () => setState(() => _currentStep += 1),
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text('Next'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 12.h),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.r)),
              ),
            )
          else
            _wizardSaveButton(),
        ],
      ),
    );
  }

  /// Final step's "Save Admission" CTA — reuses the existing _actionBar's
  /// save handler so the wizard saves through the same path.
  Widget _wizardSaveButton() {
    // The existing _actionBar wraps the save button with disable/saving state
    // logic; we mirror that here so the wizard's last step behaves the same.
    return ElevatedButton.icon(
      onPressed: _saving || _readonly ? null : _save,
      icon: _saving
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.save, size: 16),
      label: const Text('Save Admission'),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 12.h),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.r)),
      ),
    );
  }

  List<Widget> _stepAdmissionBlocks() {
    return [
      _section('Admission', [
                    _row([
                      _dropdown('Admission No Mode', _regMode, _regModes, (v) => setState(() {
                            _regMode = v ?? 'Manual';
                            if (_regMode == 'Manual') _selectedRegSeqId = null;
                          })),
                      _regSeqField(),
                      _text('Admission No *', _admnoController, enabled: _regMode == 'Manual'),
                    ]),
                    _row([
                      _dateField('Admission Date', _admDate, (d) => setState(() => _admDate = d)),
                      _yearDropdown(),
                      _dropdown('Source', _source, _sources, (v) => setState(() => _source = v)),
                    ]),
                  ]),
    ];
  }

  List<Widget> _stepApplicantBlocks() {
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
                      _text('EMIS No', _emisController),
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
    ];
  }

  List<Widget> _stepAcademicBlocks() {
    return [
      _section('Applied For', [
                    _row([
                      _dropdown('Admitted Standard', _selectedAdmittedStandard, _standardNames,
                          (v) => setState(() => _selectedAdmittedStandard = v)),
                      _dropdown('Current Standard', _selectedStandard, _standardNames, (v) => setState(() {
                            _selectedStandard = v;
                            if (_selectedSection != null && !_sectionNamesFor(v).contains(_selectedSection)) {
                              _selectedSection = null;
                            }
                          })),
                      _dropdown('Section', _selectedSection, _sectionNamesFor(_selectedStandard),
                          (v) => setState(() => _selectedSection = v)),
                    ]),
                    _row([
                      _dropdownMap('Concession', _selectedConId, _concessions, 'con_id', 'condesc',
                          (v) => setState(() => _selectedConId = v)),
                      _dropdown('Medium', _selectedMedium, _mediumOptions,
                          (v) => setState(() => _selectedMedium = v)),
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
                      _text('School', _prevSchoolController),
                      _text('Class', _prevClassController),
                      _text('Board', _prevBoardController),
                    ]),
                    _row([
                      _text('Marks %', _prevPercentController, keyboard: TextInputType.number),
                      const Spacer(),
                      const Spacer(),
                    ]),
                  ]),
    ];
  }

  List<Widget> _stepFamilyBlocks() {
    return [
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
                  Text(a.admno, style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
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
    final canAllocate = a != null && a.isPending;
    return Padding(
      padding: EdgeInsets.all(14.w),
      child: Row(
        children: [
          if (a != null && !allocated)
            OutlinedButton.icon(
              onPressed: _saving ? null : _cancel,
              icon: const Icon(Icons.block, size: 16),
              label: const Text('Cancel'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
                padding: EdgeInsets.symmetric(horizontal: 12.w),
              ),
            ),
          const Spacer(),
          if (canAllocate) ...[
            ElevatedButton.icon(
              onPressed: _saving ? null : _allocate,
              icon: const Icon(Icons.assignment_ind, size: 16),
              label: const Text('Allocate Section'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
              ),
            ),
            SizedBox(width: 8.w),
          ],
          if (!allocated)
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save, size: 16),
              label: Text(a == null ? 'Save Admission' : 'Update'),
            ),
          if (allocated)
            Text('Allocated — record locked',
                style: TextStyle(fontSize: 12.sp, fontStyle: FontStyle.italic, color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  // ── form helpers ──────────────────────────────────────────────────
  Widget _section(String title, List<Widget> children) {
    const sectionIcons = {
      'Admission': 'document-text',
      'Applicant': 'user',
      'Applied For': 'book-1',
      'Additional Details': 'info-circle',
      'Previous School': 'teacher',
      'Parent / Guardian': 'people',
      'Remarks': 'note',
    };
    final icon = sectionIcons[title] ?? 'document-text';
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: 14.h),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(16.w, 12.h, 16.w, 12.h),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.06),
              borderRadius: BorderRadius.vertical(top: Radius.circular(10.r)),
              border: const Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                AppIcon(icon, size: 18, color: AppColors.accent),
                SizedBox(width: 10.w),
                Text(title,
                    style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16.w, 14.h, 16.w, 16.h),
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
            cells[i] is Spacer ? cells[i] : Expanded(child: cells[i]),
            if (i != cells.length - 1) SizedBox(width: 12.w),
          ],
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: EdgeInsets.only(bottom: 6.h),
        child: Text(text,
            style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w800, color: Colors.black)),
      );

  InputDecoration _dec({String? hint}) {
    final compact = MediaQuery.of(context).size.width <= 1366;
    final textSize = compact ? 11.0 : 14.0;
    final hPad = compact ? 8.0 : 14.0;
    final vPad = compact ? 5.0 : 14.0;
    final radius = compact ? 5.0 : 8.0;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textPrimary.withValues(alpha: 0.6), fontSize: textSize),
      contentPadding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      filled: true,
      fillColor: _readonly ? AppColors.surface : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: AppColors.accent)),
    );
  }

  Widget _text(String label, TextEditingController c,
      {bool enabled = true, TextInputType? keyboard, int maxLines = 1}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        TextFormField(
          controller: c,
          enabled: enabled && !_readonly,
          keyboardType: keyboard,
          maxLines: maxLines,
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          decoration: _dec(),
        ),
      ],
    );
  }

  Widget _dropdown(String label, String? value, List<String> items, ValueChanged<String?> onChanged) {
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
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          decoration: _dec(),
          items: items
              .map((e) => DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: _readonly ? null : onChanged,
        ),
      ],
    );
  }

  Widget _dropdownMap(String label, String? value, List<Map<String, dynamic>> items,
      String valueKey, String labelKey, ValueChanged<String?> onChanged) {
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
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          decoration: _dec(),
          items: items
              .map((e) => DropdownMenuItem(
                    value: e[valueKey].toString(),
                    child: Text(e[labelKey]?.toString() ?? '', overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: _readonly ? null : onChanged,
        ),
      ],
    );
  }

  Widget _regSeqField() {
    final values = _regSeqs.map((s) => s['rns_id'].toString()).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Admission Sequence'),
        DropdownButtonFormField<String>(
          initialValue: values.contains(_selectedRegSeqId) ? _selectedRegSeqId : null,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          decoration: _dec(),
          hint: Text('Auto Admission No', style: TextStyle(fontSize: 13.sp, color: AppColors.textLight)),
          items: _regSeqs
              .map((s) => DropdownMenuItem(
                    value: s['rns_id'].toString(),
                    child: Text(s['rnsname']?.toString() ?? '', overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (_readonly || _regMode != 'Auto')
              ? null
              : (v) => setState(() {
                    _selectedRegSeqId = v;
                    final seq = _regSeqs.firstWhere(
                      (s) => s['rns_id'].toString() == v,
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
          style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
          decoration: _dec(),
          items: _years
              .map((y) => DropdownMenuItem(
                    value: y['yr_id'].toString(),
                    child: Text(y['yrlabel']?.toString() ?? '', overflow: TextOverflow.ellipsis),
                  ))
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

  Widget _dateField(String label, DateTime? value, ValueChanged<DateTime> onPick) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        InkWell(
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
            decoration: _dec(),
            child: Text(
              value == null
                  ? 'Pick date'
                  : '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}',
              style: TextStyle(
                  fontSize: 13.sp,
                  color: value == null ? AppColors.textLight : AppColors.textPrimary),
            ),
          ),
        ),
      ],
    );
  }
}
