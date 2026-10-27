import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:excel/excel.dart' as xl;
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions, PostgrestException;
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../models/student_model.dart';
import '../../utils/app_text.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';

class StudentsScreen extends StatefulWidget {
  final StudentModel? initialStudent;
  const StudentsScreen({super.key, this.initialStudent});

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  final _formKey = GlobalKey<FormState>();

  // Student Info
  String? _selectedYrId;
  String? _selectedYrLabel;
  List<Map<String, dynamic>> _years = [];
  final _admNoController = TextEditingController();
  final _nameController = TextEditingController();
  String? _selectedGender;
  DateTime? _admDate;
  DateTime? _dob;
  final _mobileController = TextEditingController();
  final _emailController = TextEditingController();
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _countryController = TextEditingController();
  final _pinController = TextEditingController();
  String? _selectedBloodGroup;
  String? _selectedClass;
  List<String> _classes = [];
  String? _selectedConId;
  List<Map<String, dynamic>> _concessions = [];
  String? _selectedAdmName;
  List<Map<String, dynamic>> _admissionTypes = [];
  String? _selectedQuoName;
  List<Map<String, dynamic>> _quotas = [];
  final _batchController = TextEditingController();
  final _admittedYearController = TextEditingController();
  // Demographic / identity fields (also populated from bulk import)
  final _aadharController = TextEditingController();
  final _emisController = TextEditingController();
  final _umisController = TextEditingController();
  final _mediumController = TextEditingController();
  final _communityController = TextEditingController();
  final _casteController = TextEditingController();
  final _religionController = TextEditingController();
  final _nationalityController = TextEditingController();
  final _transportController = TextEditingController();
  String? _selectedHostel; // 'Y' / 'N'
  String? _photoUrl;
  String? _insName;
  String? _insLogo;

  // Parent Info
  String _selectedParentTab = 'Father';
  final _parentEmailController = TextEditingController();
  final _fatherNameController = TextEditingController();
  final _fatherMobileController = TextEditingController();
  final _fatherOccController = TextEditingController();
  final _motherNameController = TextEditingController();
  final _motherMobileController = TextEditingController();
  final _motherOccController = TextEditingController();
  final _guardianNameController = TextEditingController();
  final _guardianMobileController = TextEditingController();
  final _guardianOccController = TextEditingController();

  // Payment in charge
  final _payNameController = TextEditingController();
  final _payMobileController = TextEditingController();

  bool _isUploadingPhoto = false;
  bool _isImportingPhotos = false;
  int _photoUploadDone = 0;
  int _photoUploadTotal = 0;
  bool _isFormEnabled = true;
  int? _selectedParId; // linked parent id of the selected student (for edits)
  List<StudentModel> _students = [];
  Map<String, int> _classCounts = {};
  // Master-table ordering: claname -> ordid, courname -> ordid.
  // Used by _buildClassList to honour the institution's preferred sort.
  Map<String, int> _classOrdMap = {};
  Map<String, int> _courseOrdMap = {};
  Map<String, List<StudentModel>> _cachedClassStudents = {};
  bool _loadingClassStudents = false;
  StudentModel? _selectedStudent;
  String? _selectedClassFilter; // null = show class list, non-null = show students of that class
  String? _selectedCourseFilter; // tracks which course the selected class belongs to
  // Single-open accordion state for the course list - opening one course
  // auto-collapses any previously open course.
  String? _expandedCourse;
  final Map<String, ExpansibleController> _courseExpansionCtrls = {};
  final _searchController = TextEditingController();
  final _globalSearchController = TextEditingController();
  List<StudentModel> _globalSearchResults = [];
  bool _isGlobalSearching = false;
  // Import state
  bool _showImport = false;
  // True only while the pre-import prerequisite check (master data + admission
  // master) is running, so the Import button is disabled during that check.
  bool _checkingImportPrereq = false;
  String? _importFileName;
  List<String> _importHeaders = [];
  List<List<dynamic>> _importRows = [];
  bool _importValidated = false;
  Map<int, String> _rowErrors = {}; // rowIndex -> tooltip message (composed from cell errors)
  Map<int, Map<String, String>> _cellErrors = {}; // rowIndex -> {fieldKey -> reason}
  List<String?> _importMappings = [];
  int _importStep = 0; // 0=grid, 2=importing, 3=done
  int _importedCount = 0;
  int _skippedCount = 0;
  int _totalCount = 0;
  List<String> _importErrors = [];
  String? _importErrorMsg;

  // Class + course masters cached at file-pick time so _validateImportRow can
  // reject rows whose class/course doesn't exist or whose classâ†’course
  // mapping disagrees with the master.
  Set<String> _importClassNames = {};         // normalized claname
  Set<String> _importCourseNames = {};        // normalized courname
  Map<String, String?> _importClassToCourse = {}; // normalized claname â†’ normalized course name (from class.cour_id)

  // Column order mirrors the export template exactly: all name/value columns
  // first, then every ID column grouped at the end.
  static const _importGridKeys = [
    'stuadmno', 'stuname', 'stugender',
    'courname', 'stuclass', 'admname',
    'batch', 'stuadmdate', 'studob', 'admittyear', 'medium',
    'concession', 'quoname',
    'stumobile', 'stuemail',
    'stuaddress', 'stucity', 'stustate', 'stucountry', 'stupin', 'stubloodgrp',
    'aadharno', 'community', 'caste', 'religion', 'nationality', 'transportmode', 'hostel', 'division',
    'fathername', 'fathermobile', 'fatheroccupation',
    'mothername', 'mothermobile', 'motheroccupation',
    'guardianname', 'guardianmobile', 'guardianoccupation', 'paremail',
    'payincharge', 'payinchargemob',
    'admitted_course_id', 'course_id', 'class_id', 'admission_type_id', 'concession_id', 'quota_id',
  ];

  // A school has no admission type / quota / batch, so these grid columns are
  // dropped there (grid, template, sample). College keeps the full list.
  static const _schoolDropGridKeys = {'admname', 'batch', 'quoname', 'admission_type_id', 'quota_id'};
  List<String> get _gridKeys => isSchool
      ? _importGridKeys.where((k) => !_schoolDropGridKeys.contains(k)).toList()
      : _importGridKeys;

  // Labels + order mirror the student import Excel template.
  static const Map<String, String> _importGridLabels = {
    'stuadmno': 'Reg. No *',
    'stuname': 'Name *',
    'stugender': 'Gender *',
    'courname': 'Course *',
    'stuclass': 'Class *',
    'admname': 'Admission Type *',
    'batch': 'Batch *',
    'stuadmdate': 'Admission Date *',
    'studob': 'DOB *',
    'admittyear': 'Admitted Year *',
    'medium': 'Medium *',
    'concession': 'Concession',
    'quoname': 'Quota',
    'stumobile': 'Mobile',
    'stuemail': 'Email',
    'stuaddress': 'Address',
    'stucity': 'City',
    'stustate': 'State',
    'stucountry': 'Country',
    'stupin': 'PIN',
    'stubloodgrp': 'Blood Group',
    'aadharno': 'Aadhar No',
    'community': 'Community',
    'caste': 'Caste',
    'religion': 'Religion',
    'nationality': 'Nationality',
    'transportmode': 'Transport Mode',
    'hostel': 'Hostel (Y/N)',
    'division': 'Division',
    'fathername': 'Father Name',
    'fathermobile': 'Father Mobile',
    'fatheroccupation': 'Father Occupation',
    'mothername': 'Mother Name',
    'mothermobile': 'Mother Mobile',
    'motheroccupation': 'Mother Occupation',
    'guardianname': 'Guardian Name',
    'guardianmobile': 'Guardian Mobile',
    'guardianoccupation': 'Guardian Occupation',
    'paremail': 'Parent Email',
    'payincharge': 'Payment In Charge',
    'payinchargemob': 'Payment Mobile',
    'admitted_course_id': 'Admitted Course Id',
    'course_id': 'Course Id',
    'class_id': 'Class Id',
    'admission_type_id': 'Admission Type Id',
    'concession_id': 'Concession Id',
    'quota_id': 'Quota id',
  };

  final ScrollController _importScrollController = ScrollController();

  // Required = the NOT NULL columns on students/parents (studob is NOT NULL;
  // con_id is nullable so Concession is optional). payincharge / payinchargemob
  // are NOT listed here: they're auto-filled from a parent (see
  // _deriveImportPayer) when left blank, and validated conditionally.
  static const _importRequiredFields = {'stuadmno', 'stuname', 'stugender', 'studob', 'stuclass'};

  TextStyle get _inputStyle => AppUI.fieldText(context);

  final List<String> _bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
  final List<String> _genders = ['Male', 'Female', 'Other'];
  static const List<String> _classOrder = [
    'PKG', 'LKG', 'UKG', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII',
  ];

  // Every class/course tile uses one uniform colour (no per-class palette).
  Color _getClassColor(String className) => AppColors.accent;

  @override
  void initState() {
    super.initState();
    _loadDropdowns();
  }

  @override
  void dispose() {
    _importScrollController.dispose();
    _admNoController.dispose();
    _nameController.dispose();
    _mobileController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _countryController.dispose();
    _pinController.dispose();
    _fatherNameController.dispose();
    _fatherMobileController.dispose();
    _fatherOccController.dispose();
    _motherNameController.dispose();
    _motherMobileController.dispose();
    _motherOccController.dispose();
    _guardianNameController.dispose();
    _guardianMobileController.dispose();
    _guardianOccController.dispose();
    _payNameController.dispose();
    _payMobileController.dispose();
    _batchController.dispose();
    _admittedYearController.dispose();
    _aadharController.dispose();
    _mediumController.dispose();
    _communityController.dispose();
    _casteController.dispose();
    _religionController.dispose();
    _nationalityController.dispose();
    _transportController.dispose();
    _parentEmailController.dispose();
    _searchController.dispose();
    _globalSearchController.dispose();
    super.dispose();
  }

  Future<void> _performGlobalSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _globalSearchResults = [];
        _isGlobalSearching = false;
      });
      return;
    }
    setState(() => _isGlobalSearching = true);
    try {
      final auth = context.read<AuthProvider>();
      final insId = auth.insId ?? 1;
      final q = query.trim().toLowerCase();
      final result = await SupabaseService.client
          .from('student')
          .select()
          .eq('ins_id', insId)
          .or('stuname.ilike.%$q%,stuadmno.ilike.%$q%,stumobile.ilike.%$q%')
          .limit(20);
      final students = (result as List).map((e) => StudentModel.fromJson(e)).toList();
      if (mounted) {
        setState(() {
          _globalSearchResults = students;
          _isGlobalSearching = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isGlobalSearching = false);
    }
  }

  Future<void> _loadDropdowns() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;

    // Stage 1: parallel - includes class counts so list shows immediately with correct counts
    final results = await Future.wait<dynamic>([
      SupabaseService.getYears(insId),
      SupabaseService.getConcessions(insId),
      SupabaseService.getClasses(insId),
      SupabaseService.getInstitutionInfo(insId),
      SupabaseService.getStudentCountsByClass(insId),
      SupabaseService.getAdmissionTypes(insId),
      SupabaseService.getQuotas(insId),
      // class + course masters with ordid for the sidebar ordering.
      SupabaseService.fromSchema('class').select('claname, ordid').eq('ins_id', insId).eq('activestatus', 1),
      SupabaseService.fromSchema('course').select('courname, ordid').eq('ins_id', insId).eq('activestatus', 1),
    ]);

    if (!mounted) return;
    final years = results[0] as List<Map<String, dynamic>>;
    final concessions = results[1] as List<Map<String, dynamic>>;
    final rawClasses = (results[2] as List<String>).toSet().toList();
    final insInfo = results[3] as ({String? name, String? logo, String? address, String? mobile, String? email});
    final classCounts = results[4] as Map<String, int>;
    final admissionTypes = results[5] as List<Map<String, dynamic>>;
    final quotas = results[6] as List<Map<String, dynamic>>;
    final classMaster = results[7] as List<dynamic>;
    final courseMaster = results[8] as List<dynamic>;
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
    // Dedupe rawClasses while preserving first-seen order - the class table
    // sometimes has multiple rows with the same claname (different cour_id),
    // which would otherwise crash DropdownButton with duplicate values.
    final seen = <String>{};
    final dedupedRaw = <String>[];
    for (final c in rawClasses) {
      if (c.isNotEmpty && seen.add(c)) dedupedRaw.add(c);
    }
    // Order by the class master's ordid (the institution's preferred order),
    // so college classes like "B.E CIVIL-I" sort correctly. Classes missing an
    // ordid fall to the end alphabetically.
    final allClasses = dedupedRaw
      ..sort((a, b) {
        // Promotional and terminal classes first, TC batches last. Applied
        // before ordid, because a TC class carries an ordid like any other and
        // would otherwise sort back in among the live years.
        final g = classGroupRank(a).compareTo(classGroupRank(b));
        if (g != 0) return g;
        final oa = classOrdMap[a.trim()], ob = classOrdMap[b.trim()];
        if (oa != null && ob != null) return oa != ob ? oa.compareTo(ob) : a.compareTo(b);
        if (oa != null) return -1;
        if (ob != null) return 1;
        return a.compareTo(b);
      });
    setState(() {
      _years = years;
      _concessions = concessions;
      _admissionTypes = admissionTypes;
      _quotas = quotas;
      _classes = allClasses;
      _classCounts = classCounts;
      _classOrdMap = classOrdMap;
      _courseOrdMap = courseOrdMap;
      _insName = insInfo.name;
      _insLogo = insInfo.logo;
      if (years.isNotEmpty) {
        _selectedYrId = years.first['yr_id'].toString();
        _selectedYrLabel = years.first['yrlabel'];
      }
      // Don't auto-select - show all students by default
    });

    // Stage 2: background - load all students for search/export
    final students = await SupabaseService.getStudents(insId);
    if (!mounted) return;
    setState(() => _students = students);

    // Auto-select initial student if provided
    if (widget.initialStudent != null) {
      final s = students.firstWhere(
        (s) => s.stuId == widget.initialStudent!.stuId,
        orElse: () => widget.initialStudent!,
      );
      setState(() {
        _selectedClassFilter = s.stuclass;
        _selectedStudent = s;
      });
      _populateStudentForm(s);
    }
  }

  String? _normalizeBloodGroup(String? raw) {
    if (raw == null) return null;
    // Map DB variants like "B+VE", "B-VE", "O+VE" â†’ canonical dropdown values
    const map = {
      'A+VE': 'A+', 'A-VE': 'A-',
      'B+VE': 'B+', 'B-VE': 'B-',
      'AB+VE': 'AB+', 'AB-VE': 'AB-',
      'O+VE': 'O+', 'O-VE': 'O-',
    };
    final upper = raw.trim().toUpperCase();
    final normalized = map[upper] ?? raw.trim();
    return _bloodGroups.contains(normalized) ? normalized : null;
  }

  Future<void> _populateStudentForm(StudentModel s) async {
    // Clear any previously typed/shown data before populating
    _admNoController.clear();
    _nameController.clear();
    _mobileController.clear();
    _emailController.clear();
    _addressController.clear();
    _cityController.clear();
    _stateController.clear();
    _countryController.clear();
    _pinController.clear();
    _fatherNameController.clear();
    _fatherMobileController.clear();
    _fatherOccController.clear();
    _motherNameController.clear();
    _motherMobileController.clear();
    _motherOccController.clear();
    _guardianNameController.clear();
    _guardianMobileController.clear();
    _guardianOccController.clear();
    _payNameController.clear();
    _payMobileController.clear();
    _batchController.clear();
    _admittedYearController.clear();
    _aadharController.clear();
    _mediumController.clear();
    _communityController.clear();
    _casteController.clear();
    _religionController.clear();
    _nationalityController.clear();
    _transportController.clear();
    _parentEmailController.clear();
    setState(() {
      _selectedGender = null;
      _selectedBloodGroup = null;
      _selectedClass = null;
      _selectedConId = null;
      _selectedAdmName = null;
      _selectedQuoName = null;
      _selectedHostel = null;
      _admDate = null;
      _dob = null;
      _photoUrl = null;
      if (_years.isNotEmpty) {
        _selectedYrId = _years.first['yr_id'].toString();
        _selectedYrLabel = _years.first['yrlabel'];
      }
    });

    String clean(String? v) => (v == null || v.toUpperCase() == 'NULL') ? '' : v;

    _admNoController.text = s.stuadmno;
    _nameController.text = s.stuname;
    _mobileController.text = s.stumobile;
    _emailController.text = clean(s.stuemail);
    _addressController.text = clean(s.stuaddress);
    _cityController.text = clean(s.stucity);
    _stateController.text = clean(s.stustate);
    _countryController.text = clean(s.stucountry);
    _pinController.text = clean(s.stupin);
    _batchController.text = clean(s.batch);
    _admittedYearController.text = clean(s.admittyear);
    _mediumController.text = clean(s.medium);
    _aadharController.text = clean(s.aadharno);
    _emisController.text = clean(s.emisno);
    _umisController.text = clean(s.umisno);
    _communityController.text = clean(s.community);
    _casteController.text = clean(s.caste);
    _religionController.text = clean(s.religion);
    _nationalityController.text = clean(s.nationality);
    _transportController.text = clean(s.transportmode);

    // Fetch parent data
    final parent = await SupabaseService.getStudentParent(s.stuId);
    if (!mounted) return;

    _parentEmailController.text = clean(parent?['paremail']?.toString());
    _fatherNameController.text = clean(parent?['fathername']?.toString());
    _fatherMobileController.text = clean(parent?['fathermobile']?.toString());
    _fatherOccController.text = clean(parent?['fatheroccupation']?.toString());
    _motherNameController.text = clean(parent?['mothername']?.toString());
    _motherMobileController.text = clean(parent?['mothermobile']?.toString());
    _motherOccController.text = clean(parent?['motheroccupation']?.toString());
    _guardianNameController.text = clean(parent?['guardianname']?.toString());
    _guardianMobileController.text = clean(parent?['guardianmobile']?.toString());
    _guardianOccController.text = clean(parent?['guardianoccupation']?.toString());
    _payNameController.text = clean(parent?['payincharge']?.toString());
    _payMobileController.text = clean(parent?['payinchargemob']?.toString());

    setState(() {
      _selectedStudent = s;
      _selectedParId = parent?['par_id'] is int
          ? parent!['par_id'] as int
          : int.tryParse('${parent?['par_id'] ?? ''}');
      _selectedGender = s.gender;
      _selectedBloodGroup = _normalizeBloodGroup(s.stubloodgrp);
      _selectedClass = s.stuclass.trim();
      _selectedConId = s.conId?.toString();
      _selectedAdmName = s.admname;
      _selectedQuoName = s.quoname;
      _selectedHostel = (s.hostel == 'Y' || s.hostel == 'N') ? s.hostel : null;
      _admDate = s.stuadmdate;
      _dob = s.studob;
      _photoUrl = s.stuphoto;
      _isFormEnabled = false; // view only: student details are not edited here
    });
  }

  void _clearForm() {
    _admNoController.clear();
    _nameController.clear();
    _mobileController.clear();
    _emailController.clear();
    _addressController.clear();
    _cityController.clear();
    _stateController.clear();
    _countryController.clear();
    _pinController.clear();
    _fatherNameController.clear();
    _fatherMobileController.clear();
    _fatherOccController.clear();
    _motherNameController.clear();
    _motherMobileController.clear();
    _motherOccController.clear();
    _guardianNameController.clear();
    _guardianMobileController.clear();
    _guardianOccController.clear();
    _payNameController.clear();
    _payMobileController.clear();
    _batchController.clear();
    _admittedYearController.clear();
    _aadharController.clear();
    _mediumController.clear();
    _communityController.clear();
    _casteController.clear();
    _religionController.clear();
    _nationalityController.clear();
    _transportController.clear();
    _parentEmailController.clear();
    setState(() {
      _selectedGender = null;
      _selectedBloodGroup = null;
      _selectedClass = null;
      _selectedConId = null;
      _selectedAdmName = null;
      _selectedQuoName = null;
      _selectedHostel = null;
      _admDate = null;
      _dob = null;
      _photoUrl = null;
      _selectedStudent = null;
      _isFormEnabled = true;
      if (_years.isNotEmpty) {
        _selectedYrId = _years.first['yr_id'].toString();
        _selectedYrLabel = _years.first['yrlabel'];
      }
    });
  }

  bool _isSaving = false;

  // Every mobile number must be exactly 10 digits (or left blank). The input
  // formatters already block non-digits and >10; this catches a short (<10)
  // entry at save. Returns the first offending field's message, else null.
  String? _mobileError() {
    final checks = <String, String>{
      'Student Mobile': _mobileController.text.trim(),
      'Father Mobile': _fatherMobileController.text.trim(),
      'Mother Mobile': _motherMobileController.text.trim(),
      'Guardian Mobile': _guardianMobileController.text.trim(),
      'Payment Mobile': _payMobileController.text.trim(),
    };
    for (final e in checks.entries) {
      if (e.value.isNotEmpty && e.value.length != 10) {
        return '${e.key} must be exactly 10 digits';
      }
    }
    return null;
  }

  Future<void> _saveNewStudent() async {
    if (_admNoController.text.trim().isEmpty ||
        _nameController.text.trim().isEmpty ||
        _selectedClass == null ||
        _mobileController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(schoolTerm('Fill in all required fields: Roll No., Student Name, Class and Mobile Number.')), backgroundColor: AppColors.error),
      );
      return;
    }
    final mobErr = _mobileError();
    if (mobErr != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mobErr), backgroundColor: AppColors.error),
      );
      return;
    }

    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    final inscode = auth.inscode ?? '';
    final yrId = int.tryParse(_selectedYrId ?? '1') ?? 1;
    final yrLabel = _selectedYrLabel ?? '';
    final now = DateTime.now().toIso8601String().split('T').first;

    setState(() => _isSaving = true);

    try {
      final stuId = await SupabaseService.addStudent({
        'ins_id': insId,
        'inscode': inscode,
        'yr_id': yrId,
        'yrlabel': yrLabel,
        'stuadmno': _admNoController.text.trim(),
        'stuadmdate': (_admDate ?? DateTime.now()).toIso8601String().split('T').first,
        'stuname': _nameController.text.trim(),
        'stugender': _selectedGender == 'Female' ? 'F' : _selectedGender == 'Male' ? 'M' : 'O',
        'studob': _dob?.toIso8601String().split('T').first,
        'stumobile': _mobileController.text.trim(),
        'stuemail': _emailController.text.trim().isNotEmpty ? _emailController.text.trim() : null,
        'stuaddress': _addressController.text.trim().isNotEmpty ? _addressController.text.trim() : null,
        'stucity': _cityController.text.trim().isNotEmpty ? _cityController.text.trim() : null,
        'stustate': _stateController.text.trim().isNotEmpty ? _stateController.text.trim() : null,
        'stucountry': _countryController.text.trim().isNotEmpty ? _countryController.text.trim() : null,
        'stupin': _pinController.text.trim().isNotEmpty ? _pinController.text.trim() : null,
        'stubloodgrp': _selectedBloodGroup,
        'stuclass': _selectedClass,
        'con_id': _selectedConId != null ? int.tryParse(_selectedConId!) : null,
        'stucondesc': _selectedConId != null ? _concessions.firstWhere((c) => c['con_id'].toString() == _selectedConId, orElse: () => {})['condesc'] : null,
        // A school has no admission type / quota / batch columns.
        if (!isSchool) 'admname': _selectedAdmName,
        if (!isSchool) 'quoname': _selectedQuoName,
        if (!isSchool) 'batch': _batchController.text.trim().isNotEmpty ? _batchController.text.trim() : null,
        'admittyear': _admittedYearController.text.trim().isNotEmpty ? _admittedYearController.text.trim() : null,
        'medium': _mediumController.text.trim().isNotEmpty ? _mediumController.text.trim() : null,
        'aadharno': _aadharController.text.trim().isNotEmpty ? _aadharController.text.trim() : null,
        'emisno': _emisController.text.trim().isNotEmpty ? _emisController.text.trim() : null,
        if (!isSchool) 'umisno': _umisController.text.trim().isNotEmpty ? _umisController.text.trim() : null,
        'community': _communityController.text.trim().isNotEmpty ? _communityController.text.trim() : null,
        'caste': _casteController.text.trim().isNotEmpty ? _casteController.text.trim() : null,
        'religion': _religionController.text.trim().isNotEmpty ? _religionController.text.trim() : null,
        'nationality': _nationalityController.text.trim().isNotEmpty ? _nationalityController.text.trim() : null,
        'transportmode': _transportController.text.trim().isNotEmpty ? _transportController.text.trim() : null,
        'hostel': _selectedHostel,
        'stuphoto': _photoUrl,
        'stuser_id': _admNoController.text.trim(),
        'stuotpstatus': 0,
        'approvedby': '',
        'approveddate': now,
        'suspendedby': '',
        'terminatedby': '',
        'activestatus': 1,
        'createdon': now,
      });

      // Save parent
      final fatherMob = _fatherMobileController.text.trim().isNotEmpty ? _fatherMobileController.text.trim() : null;
      final motherMob = _motherMobileController.text.trim().isNotEmpty ? _motherMobileController.text.trim() : null;
      final payMob = _payMobileController.text.trim().isNotEmpty ? _payMobileController.text.trim() : null;

      final existingParId = await SupabaseService.findParentByMobile(
        insId: insId,
        fatherMobile: fatherMob,
        motherMobile: motherMob,
        payMobile: payMob,
      );

      final parId = existingParId ?? await SupabaseService.saveParent({
        'yr_id': yrId,
        'yrlabel': yrLabel,
        'partype': 'P',
        'paremail': _parentEmailController.text.trim().isNotEmpty ? _parentEmailController.text.trim() : null,
        'fathername': _fatherNameController.text.trim().isNotEmpty ? _fatherNameController.text.trim() : null,
        'fathermobile': fatherMob,
        'fatheroccupation': _fatherOccController.text.trim().isNotEmpty ? _fatherOccController.text.trim() : null,
        'mothername': _motherNameController.text.trim().isNotEmpty ? _motherNameController.text.trim() : null,
        'mothermobile': motherMob,
        'motheroccupation': _motherOccController.text.trim().isNotEmpty ? _motherOccController.text.trim() : null,
        'guardianname': _guardianNameController.text.trim().isNotEmpty ? _guardianNameController.text.trim() : null,
        'guardianmobile': _guardianMobileController.text.trim().isNotEmpty ? _guardianMobileController.text.trim() : null,
        'guardianoccupation': _guardianOccController.text.trim().isNotEmpty ? _guardianOccController.text.trim() : null,
        'payincharge': _payNameController.text.trim().isNotEmpty ? _payNameController.text.trim() : null,
        'payinchargemob': payMob,
        'parotpstatus': 0,
        'approveddate': now,
        'activestatus': 1,
      });

      // Link parent to student
      await SupabaseService.saveParentDetail({
        'yr_id': yrId,
        'yrlabel': yrLabel,
        'par_id': parId,
        'stu_id': stuId,
        'ins_id': insId,
        'inscode': inscode,
        'stuadmno': _admNoController.text.trim(),
        'stuname': _nameController.text.trim(),
        'stuclass': _selectedClass,
        'activestatus': 1,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Student added successfully'), backgroundColor: AppColors.success),
        );
        _clearForm();
        _loadDropdowns();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the student. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Save edits to the currently-selected student (student + parent +
  /// parentdetail), then return to view mode.
  Future<void> _updateStudent() async {
    final s = _selectedStudent;
    if (s == null) return;
    // Mobile is not required on edit — many existing students have none.
    if (_admNoController.text.trim().isEmpty ||
        _nameController.text.trim().isEmpty ||
        _selectedClass == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(schoolTerm('Fill in all required fields: Roll No., Student Name and Class.')), backgroundColor: AppColors.error),
      );
      return;
    }
    final mobErr = _mobileError();
    if (mobErr != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mobErr), backgroundColor: AppColors.error),
      );
      return;
    }
    setState(() => _isSaving = true);
    try {
      await SupabaseService.updateStudent(s.stuId, {
        'stuadmno': _admNoController.text.trim(),
        'stuadmdate': (_admDate ?? DateTime.now()).toIso8601String().split('T').first,
        'stuname': _nameController.text.trim(),
        'stugender': _selectedGender == 'Female' ? 'F' : _selectedGender == 'Male' ? 'M' : 'O',
        'studob': _dob?.toIso8601String().split('T').first,
        'stumobile': _mobileController.text.trim(),
        'stuemail': _emailController.text.trim().isNotEmpty ? _emailController.text.trim() : null,
        'stuaddress': _addressController.text.trim().isNotEmpty ? _addressController.text.trim() : null,
        'stucity': _cityController.text.trim().isNotEmpty ? _cityController.text.trim() : null,
        'stustate': _stateController.text.trim().isNotEmpty ? _stateController.text.trim() : null,
        'stucountry': _countryController.text.trim().isNotEmpty ? _countryController.text.trim() : null,
        'stupin': _pinController.text.trim().isNotEmpty ? _pinController.text.trim() : null,
        'stubloodgrp': _selectedBloodGroup,
        'stuclass': _selectedClass,
        'con_id': _selectedConId != null ? int.tryParse(_selectedConId!) : null,
        'stucondesc': _selectedConId != null ? _concessions.firstWhere((c) => c['con_id'].toString() == _selectedConId, orElse: () => {})['condesc'] : null,
        // A school has no admission type / quota / batch columns.
        if (!isSchool) 'admname': _selectedAdmName,
        if (!isSchool) 'quoname': _selectedQuoName,
        if (!isSchool) 'batch': _batchController.text.trim().isNotEmpty ? _batchController.text.trim() : null,
        'admittyear': _admittedYearController.text.trim().isNotEmpty ? _admittedYearController.text.trim() : null,
        'medium': _mediumController.text.trim().isNotEmpty ? _mediumController.text.trim() : null,
        'aadharno': _aadharController.text.trim().isNotEmpty ? _aadharController.text.trim() : null,
        'emisno': _emisController.text.trim().isNotEmpty ? _emisController.text.trim() : null,
        if (!isSchool) 'umisno': _umisController.text.trim().isNotEmpty ? _umisController.text.trim() : null,
        'community': _communityController.text.trim().isNotEmpty ? _communityController.text.trim() : null,
        'caste': _casteController.text.trim().isNotEmpty ? _casteController.text.trim() : null,
        'religion': _religionController.text.trim().isNotEmpty ? _religionController.text.trim() : null,
        'nationality': _nationalityController.text.trim().isNotEmpty ? _nationalityController.text.trim() : null,
        'transportmode': _transportController.text.trim().isNotEmpty ? _transportController.text.trim() : null,
        'hostel': _selectedHostel,
        'stuphoto': _photoUrl,
      });

      // Update the linked parent, if any.
      if (_selectedParId != null) {
        String? t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
        try {
          await SupabaseService.updateParent(_selectedParId!, {
            'paremail': t(_parentEmailController),
            'fathername': t(_fatherNameController),
            'fathermobile': t(_fatherMobileController),
            'fatheroccupation': t(_fatherOccController),
            'mothername': t(_motherNameController),
            'mothermobile': t(_motherMobileController),
            'motheroccupation': t(_motherOccController),
            'guardianname': t(_guardianNameController),
            'guardianmobile': t(_guardianMobileController),
            'guardianoccupation': t(_guardianOccController),
            'payincharge': t(_payNameController),
            'payinchargemob': t(_payMobileController),
          });
        } catch (_) {}
      }

      // Keep the denormalized parentdetail fields in sync.
      try {
        await SupabaseService.updateParentDetail(s.stuId, {
          'stuadmno': _admNoController.text.trim(),
          'stuname': _nameController.text.trim(),
          'stuclass': _selectedClass,
        });
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Student updated successfully'), backgroundColor: AppColors.success),
        );
        _loadDropdowns();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update the student. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Cancel the current form: discard a new entry, or exit edit mode and
  /// reload the selected student's saved values.
  void _cancelForm() {
    final s = _selectedStudent;
    if (s == null) {
      _clearForm();
    } else {
      _populateStudentForm(s); // re-loads saved values and returns to view mode
    }
  }

  Widget _avatarPlaceholder() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return AppIcon('user', size: 36.sp, color: AppColors.accent);
    return Center(
      child: Text(
        name[0].toUpperCase(),
        style: TextStyle(fontSize: 28.sp, fontWeight: FontWeight.w700, color: AppColors.accent),
      ),
    );
  }

  // Per-institution bucket name. Each institution gets its own bucket
  // (student-photos-kcet, student-photos-kcsam, ...) so quotas / deletion
  // are isolated per school.
  String _photoBucket(String inscode) => 'student-photos-${inscode.toLowerCase()}';

  Future<void> _uploadPhoto() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    final auth = context.read<AuthProvider>();
    final inscode = auth.inscode ?? 'ins';

    setState(() => _isUploadingPhoto = true);
    try {
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not upload the photo. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  /// Bulk-upload student photos by filename convention:
  /// the file's stem (e.g. "6522" in "6522.jpg") is treated as the Roll No
  /// (stuadmno) and matched against the already-loaded students list for
  /// this institution. Each matched student's stuphoto URL is updated.
  /// Unmatched filenames are reported to the admin so they can fix the
  /// mismatches on the next pass.
  Future<void> _bulkImportPhotos() async {
    // Pick a FOLDER (Windows desktop). The app then enumerates every image
    // file inside and uploads them - much faster than Ctrl+A in the file
    // picker when a school has hundreds of photos.
    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: schoolTerm('Select the folder of photos named by roll no. (e.g. 6522.jpg)'),
    );
    if (folderPath == null) return;

    const imageExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};
    List<File> imageFiles;
    try {
      final dir = Directory(folderPath);
      imageFiles = dir
          .listSync(recursive: false)
          .whereType<File>()
          .where((f) {
            final name = f.path.toLowerCase();
            final dot = name.lastIndexOf('.');
            if (dot < 0) return false;
            return imageExts.contains(name.substring(dot));
          })
          .toList();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read folder. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (imageFiles.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No JPG, PNG, WEBP or GIF files found in that folder. Choose another folder.'),
            backgroundColor: AppColors.warning,
          ),
        );
      }
      return;
    }

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.inscode ?? 'ins';
    if (insId == null) return;

    // Build a Roll No â†’ stu_id lookup from the already-loaded students list.
    // Case-insensitive match so "6522.jpg" and "6522.JPG" both work.
    final rollToStuId = <String, int>{
      for (final s in _students) s.stuadmno.toLowerCase(): s.stuId,
    };

    final successes = <String>[];
    final unmatched = <String>[];
    final failed = <String>[];

    setState(() {
      _isImportingPhotos = true;
      _photoUploadDone = 0;
      _photoUploadTotal = imageFiles.length;
    });

    try {
      await SupabaseService.client.rpc('ensure_student_photo_bucket', params: {
        'p_inscode': inscode,
      });
    } catch (e) {
      debugPrint('ensure_student_photo_bucket failed: $e');
    }

    const mimeMap = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg',
      'png': 'image/png', 'webp': 'image/webp', 'gif': 'image/gif',
    };

    for (final file in imageFiles) {
      final fileName = file.path.split(Platform.pathSeparator).last;
      try {
        final dot = fileName.lastIndexOf('.');
        final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
        final ext = dot > 0 ? fileName.substring(dot + 1).toLowerCase() : 'jpg';
        final roll = stem.trim().toLowerCase();
        final stuId = rollToStuId[roll];
        if (stuId == null) {
          unmatched.add(fileName);
          continue;
        }
        final bytes = await file.readAsBytes();
        final mimeType = mimeMap[ext] ?? 'image/jpeg';
        // Per-institution bucket (student-photos-<inscode>); upsert so
        // re-uploading a photo for the same Roll No overwrites cleanly.
        final bucket = _photoBucket(inscode);
        final path = '$roll.$ext';
        await SupabaseService.client.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mimeType, upsert: true),
        );
        final url = SupabaseService.client.storage.from(bucket).getPublicUrl(path);
        await SupabaseService.updateStudent(stuId, {'stuphoto': url});
        successes.add(fileName);
      } catch (e) {
        failed.add('$fileName: ${friendlyError(e)}');
      } finally {
        if (mounted) setState(() => _photoUploadDone++);
      }
    }

    if (mounted) {
      setState(() => _isImportingPhotos = false);
      // Refresh the students list so new stuphoto URLs show in cards.
      final refreshed = await SupabaseService.getStudents(insId, forceRefresh: true);
      if (mounted) setState(() => _students = refreshed);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Photo Import Complete'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Uploaded: ${successes.length}',
                      style: TextStyle(color: AppColors.success, fontWeight: FontWeight.w700, fontSize: 14.sp)),
                  if (unmatched.isNotEmpty) ...[
                    SizedBox(height: 8.h),
                    Text(schoolTerm('Not matched (${unmatched.length}): no student has this roll no.'),
                        style: TextStyle(color: AppColors.warning, fontWeight: FontWeight.w700, fontSize: 13.sp)),
                    for (final n in unmatched.take(20))
                      Padding(padding: EdgeInsets.only(left: 8.w, top: 2.h), child: Text('• $n', style: TextStyle(fontSize: 12.sp))),
                    if (unmatched.length > 20)
                      Padding(padding: EdgeInsets.only(left: 8.w, top: 2.h), child: Text('... and ${unmatched.length - 20} more', style: TextStyle(fontSize: 12.sp, fontStyle: FontStyle.italic))),
                  ],
                  if (failed.isNotEmpty) ...[
                    SizedBox(height: 8.h),
                    Text('Failed (${failed.length}):',
                        style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w700, fontSize: 13.sp)),
                    for (final n in failed.take(10))
                      Padding(padding: EdgeInsets.only(left: 8.w, top: 2.h), child: Text('• $n', style: TextStyle(fontSize: 12.sp))),
                  ],
                ],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
    }
  }

  List<StudentModel> get _filteredStudents {
    final q = _searchController.text.toLowerCase();
    final filtered = q.isEmpty
        ? List<StudentModel>.from(_students)
        : _students.where((s) =>
            s.stuname.toLowerCase().contains(q) ||
            s.stuadmno.toLowerCase().contains(q) ||
            s.stuclass.toLowerCase().contains(q),
          ).toList();
    // Sort by course ordid â†’ class ordid â†’ name so the main list mirrors the
    // sidebar grouping (which is also driven by the same master ordids).
    int courseOrd(StudentModel s) =>
        _courseOrdMap[(s.courname ?? '').trim()] ?? 1 << 30;
    int classOrd(StudentModel s) =>
        _classOrdMap[s.stuclass.trim()] ?? 1 << 30;
    filtered.sort((a, b) {
      final ca = courseOrd(a);
      final cb = courseOrd(b);
      if (ca != cb) return ca.compareTo(cb);
      // Within a course: promotional, then terminal, then TC -- so the main
      // list mirrors the sidebar, which groups the same way.
      final g = classGroupRank(a.stuclass).compareTo(classGroupRank(b.stuclass));
      if (g != 0) return g;
      final la = classOrd(a);
      final lb = classOrd(b);
      if (la != lb) return la.compareTo(lb);
      return a.stuname.toLowerCase().compareTo(b.stuname.toLowerCase());
    });
    return filtered;
  }

  /// Group filtered students by class, ordered by [_classOrder].
  Map<String, List<StudentModel>> get _groupedStudents {
    final students = _filteredStudents;
    final map = <String, List<StudentModel>>{};
    for (final s in students) {
      final cls = s.stuclass.isNotEmpty ? s.stuclass : 'Unassigned';
      map.putIfAbsent(cls, () => []).add(s);
    }
    // Sort keys by _classOrder
    final sortedKeys = map.keys.toList()..sort((a, b) {
      final ai = _classOrder.indexOf(a);
      final bi = _classOrder.indexOf(b);
      final aIdx = ai == -1 ? 999 : ai;
      final bIdx = bi == -1 ? 999 : bi;
      return aIdx.compareTo(bIdx);
    });
    return {for (final k in sortedKeys) k: map[k]!};
  }

  Widget _buildStudentAvatar(StudentModel s, Color classColor, bool isSelected) {
    final bgColor = isSelected
        ? classColor.withValues(alpha: 0.2)
        : classColor.withValues(alpha: 0.1);
    final letter = Text(
      s.stuname.isNotEmpty ? s.stuname[0].toUpperCase() : '?',
      style: TextStyle(color: classColor, fontWeight: FontWeight.w700, fontSize: 13.sp),
    );

    if (s.stuphoto != null && s.stuphoto!.startsWith('http')) {
      return CircleAvatar(
        radius: 16.r,
        backgroundColor: bgColor,
        child: ClipOval(
          child: Image.network(
            s.stuphoto!,
            width: 32.w,
            height: 32.h,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => letter,
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: 16.r,
      backgroundColor: bgColor,
      child: letter,
    );
  }

  // â”€â”€â”€ Left Panel Builders â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  // Group classes by course with correct counts
  Map<String, Map<String, int>> _getCoursewiseClassCounts() {
    final courseMap = <String, Map<String, int>>{};
    for (final s in _students) {
      final course = s.courname ?? 'Other';
      final cls = s.stuclass;
      courseMap.putIfAbsent(course, () => {});
      courseMap[course]![cls] = (courseMap[course]![cls] ?? 0) + 1;
    }
    if (courseMap.isEmpty && _classes.isNotEmpty) {
      courseMap['All'] = { for (final c in _classes) c: _classCounts[c] ?? 0 };
    }
    return courseMap;
  }

  Widget _buildClassList() {
    if (_classes.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final courseClassCounts = _getCoursewiseClassCounts();
    // Sort courses by master-table ordid (falls back to alphabetical).
    int courseOrdOf(String name) =>
        _courseOrdMap[name.trim()] ?? _courseOrdMap[name] ?? 1 << 30;
    final courseNames = courseClassCounts.keys.toList()
      ..sort((a, b) {
        final oa = courseOrdOf(a);
        final ob = courseOrdOf(b);
        if (oa != ob) return oa.compareTo(ob);
        return a.compareTo(b);
      });

    return ListView.builder(
      padding: EdgeInsets.symmetric(vertical: 4.h),
      itemCount: courseNames.length,
      itemBuilder: (context, courseIndex) {
        final courseName = courseNames[courseIndex];
        final classCounts = courseClassCounts[courseName]!;
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
            if (isExpanded) {
              final prev = _expandedCourse;
              if (prev != null && prev != courseName) {
                final prevCtrl = _courseExpansionCtrls[prev];
                try {
                  prevCtrl?.collapse();
                } catch (_) {
                  // Controller not attached (tile off-screen). Tile will
                  // pick up the collapsed state via initiallyExpanded
                  // when next rebuilt.
                }
              }
              setState(() => _expandedCourse = courseName);
            } else if (_expandedCourse == courseName) {
              setState(() => _expandedCourse = null);
            }
          },
          tilePadding: EdgeInsets.symmetric(horizontal: 14.w),
          // Expanded course gets a grey backdrop; its classes render as indented
          // white cards inside it, so parent (course) vs child (class) is clear.
          backgroundColor: AppColors.surface,
          collapsedBackgroundColor: Colors.transparent,
          shape: const Border(),
          collapsedShape: const Border(),
          childrenPadding: EdgeInsets.fromLTRB(12.w, 2.h, 10.w, 8.h),
          title: Text(courseName.toUpperCase(), style: TextStyle(fontSize: 12.5.sp, fontWeight: FontWeight.w800, color: AppColors.primary, letterSpacing: 0.4)),
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
          children: (classCounts.keys.toList()
                ..sort((a, b) {
                  // Promotional, then terminal, then TC -- before ordid, for
                  // the same reason the master list does it: a TC batch
                  // carries an ordid like any other class, so ordid alone
                  // sorted CSE TC 25 and TC 26 above B.E CSE -I.
                  final g = classGroupRank(a).compareTo(classGroupRank(b));
                  if (g != 0) return g;
                  // Then the master-table ordid, the institution's preferred
                  // order; unknown classes fall to the end alphabetically.
                  int ordOf(String n) =>
                      _classOrdMap[n.trim()] ?? _classOrdMap[n] ?? 1 << 30;
                  final oa = ordOf(a);
                  final ob = ordOf(b);
                  if (oa != ob) return oa.compareTo(ob);
                  return a.compareTo(b);
                }))
              .map((className) {
            final count = classCounts[className] ?? 0;
            final classColor = _getClassColor(className);
            final isSelected = _selectedClassFilter == className && _selectedCourseFilter == courseName;
            return Padding(
              padding: EdgeInsets.only(bottom: 6.h),
              child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10.r),
                onTap: () async {
                  setState(() {
                    _selectedClassFilter = className;
                    _selectedCourseFilter = courseName;
                    _selectedStudent = null;
                    _searchController.clear();
                  });
                  if ((_groupedStudents[className]?.isEmpty ?? true) && _cachedClassStudents[className] == null) {
                    setState(() => _loadingClassStudents = true);
                    final auth = context.read<AuthProvider>();
                    final insId = auth.insId ?? 1;
                    final classStudents = await SupabaseService.getStudentsByClass(insId, className);
                    if (mounted) {
                      setState(() {
                        _cachedClassStudents[className] = classStudents;
                        _loadingClassStudents = false;
                      });
                    }
                  }
                },
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
                  decoration: BoxDecoration(
                    color: isSelected ? classColor.withValues(alpha: 0.10) : Colors.white,
                    borderRadius: BorderRadius.circular(10.r),
                    border: Border.all(color: isSelected ? classColor.withValues(alpha: 0.55) : AppColors.border, width: isSelected ? 1.4 : 1),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30.w, height: 30.h,
                        decoration: BoxDecoration(
                          color: classColor.withValues(alpha: isSelected ? 0.2 : 0.1),
                          borderRadius: BorderRadius.circular(8.r),
                        ),
                        child: Center(child: AppIcon('book-1', size: 15, color: classColor)),
                      ),
                      SizedBox(width: 10.w),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(className, style: TextStyle(fontSize: 13.sp, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500, color: isSelected ? classColor : AppColors.textPrimary)),
                            Text('$count students', style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                        decoration: BoxDecoration(
                          color: classColor.withValues(alpha: isSelected ? 0.2 : 0.1),
                          borderRadius: BorderRadius.circular(10.r),
                        ),
                        child: Text('$count', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: classColor)),
                      ),
                      SizedBox(width: 6.w),
                      AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                    ],
                  ),
                ),
              ),
            ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildStudentListForClass(String className) {
    var allStudents = _groupedStudents[className]?.isNotEmpty == true
        ? _groupedStudents[className]!
        : _cachedClassStudents[className] ?? [];
    // Filter by course if selected
    if (_selectedCourseFilter != null) {
      allStudents = allStudents.where((s) => (s.courname ?? 'Other') == _selectedCourseFilter).toList();
    }
    if (_loadingClassStudents && allStudents.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final q = _searchController.text.toLowerCase();
    final students = q.isEmpty
        ? allStudents
        : allStudents.where((s) =>
            s.stuname.toLowerCase().contains(q) ||
            s.stuadmno.toLowerCase().contains(q)).toList();
    final classColor = _getClassColor(className);

    return Column(
      children: [
        // Back button + class header
        Container(
          padding: EdgeInsets.fromLTRB(6.w, 6.h, 14.w, 6.h),
          decoration: BoxDecoration(
            color: classColor.withValues(alpha: 0.06),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(() {
                  _selectedClassFilter = null;
                  _selectedStudent = null;
                  _searchController.clear();
                }),
                icon: AppIcon.linear('Chevron Left', size: 18),
                color: classColor,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              AppIcon('book-1', size: 14, color: classColor.withValues(alpha: 0.7)),
              SizedBox(width: 6.w),
              Text(schoolTerm('Class $className'), style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: classColor)),
              SizedBox(width: 6.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 6.w, vertical: 1.h),
                decoration: BoxDecoration(
                  color: classColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: Text('${allStudents.length}', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: classColor.withValues(alpha: 0.7))),
              ),
            ],
          ),
        ),
        Divider(height: 1.h, color: AppColors.border),
        // Student list
        Expanded(
          child: students.isEmpty
              ? const EmptyState(icon: 'people', title: 'No students found', subtitle: 'Try a different search, or import students.')
              : ListView.builder(
                  padding: EdgeInsets.symmetric(vertical: 4.h),
                  itemCount: students.length,
                  itemBuilder: (context, index) {
                    final s = students[index];
                    final isSelected = _selectedStudent?.stuId == s.stuId;
                    return Material(
                      color: isSelected ? AppColors.accent.withValues(alpha: 0.1) : Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          setState(() => _selectedStudent = s);
                          _populateStudentForm(s);
                        },
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
                          child: Row(
                            children: [
                              _buildStudentAvatar(s, classColor, isSelected),
                              SizedBox(width: 10.w),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(s.stuname, style: TextStyle(fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600, fontSize: 13.sp, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
                                    Text(s.stuadmno, style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                AppIcon('tick-circle', size: 16, color: AppColors.accent),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  List<Widget> _buildImportActionButtons() {
    final iconSize = AppBtn.iconSize(context);
    final gap = AppBtn.gap(context);

    Widget importPhotos = ElevatedButton.icon(
      onPressed: _isImportingPhotos ? null : _bulkImportPhotos,
      icon: _isImportingPhotos
          ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : Icon(Icons.photo_library, size: iconSize),
      label: Text(_isImportingPhotos
          ? 'Uploading ${_photoUploadDone}/$_photoUploadTotal…'
          : 'Import Photos'),
    );

    Widget importCsv = ElevatedButton.icon(
      onPressed: _checkingImportPrereq ? null : _onImportCsvPressed,
      icon: _checkingImportPrereq
          ? SizedBox(width: iconSize, height: iconSize, child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : AppIcon(_showImport ? 'close-circle' : 'document-upload', size: iconSize),
      label: Text(_showImport ? 'Close Import' : 'Import CSV/Excel'),
      style: _showImport ? AppUI.danger(context) : null,
    );

    return [
      SizedBox(width: gap),
      importPhotos,
      SizedBox(width: gap),
      importCsv,
    ];
  }

  /// Opens the CSV/Excel import panel — but only after confirming the import
  /// prerequisites are in place. Students can be imported only once Master Data
  /// (classes) and Admission Master (admission types) have been imported, so the
  /// incoming rows have course/class and admission mappings to resolve against.
  Future<void> _onImportCsvPressed() async {
    // Closing the panel is always allowed.
    if (_showImport) {
      setState(() {
        _showImport = false;
        _resetImport();
      });
      return;
    }

    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    setState(() => _checkingImportPrereq = true);
    final pre = await SupabaseService.getStudentImportPrerequisites(insId);
    if (!mounted) return;
    setState(() => _checkingImportPrereq = false);

    if (!pre.hasMasterData || !pre.hasAdmissionMaster) {
      _showImportPrereqDialog(pre.hasMasterData, pre.hasAdmissionMaster);
      return;
    }
    setState(() => _showImport = true);
  }

  void _showImportPrereqDialog(bool hasMasterData, bool hasAdmissionMaster) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.info_outline_rounded, color: AppColors.warning),
            const SizedBox(width: 10),
            const Text('Import Prerequisites'),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Before importing students, please import the following first:'),
              const SizedBox(height: 16),
              _prereqRow(schoolTerm('Master Data (Courses & Classes)'), hasMasterData),
              // A school has no admission types to import.
              if (!isSchool) ...[
              const SizedBox(height: 10),
              _prereqRow('Admission Master (Admission Types)', hasAdmissionMaster),
              ],
              const SizedBox(height: 16),
              Text(
                isSchool
                    ? 'Go to Setup → Master Data to import these, then try again.'
                    : 'Go to Setup → Master Data and Setup → Admission Master to import these, then try again.',
                style: AppUI.muted.copyWith(height: 1.4),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _prereqRow(String label, bool done) {
    return Row(
      children: [
        Icon(done ? Icons.check_circle_rounded : Icons.cancel_rounded,
            color: done ? AppColors.success : AppColors.error, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: AppUI.label),
        ),
        AppUI.chip(done ? 'Done' : 'Missing', done ? AppStatus.success : AppStatus.danger),
      ],
    );
  }

  Widget _buildAllStudentsTable() {
    final q = _searchController.text.toLowerCase();
    final allStudents = q.isEmpty
        ? _students
        : _students.where((s) => s.stuname.toLowerCase().contains(q) || s.stuadmno.toLowerCase().contains(q) || (s.courname ?? '').toLowerCase().contains(q)).toList();
    final totalStudents = allStudents.length;

    final cellStyle = AppUI.cell;

    return Column(
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(16.w, 10.h, 16.w, 0),
          child: Row(
            children: [
              const CardTitleBlock(icon: 'people', title: 'All Students', subtitle: 'Browse and search the student directory'),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10.r)),
                child: Text('$totalStudents students', style: TextStyle(fontSize: 12.sp, color: AppColors.primary, fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              AppSearchField(
                controller: _searchController,
                hintText: schoolTerm('Search by name, roll no. or course'),
                onChanged: (_) => setState(() {}),
                width: 300.w,
              ),
              ..._buildImportActionButtons(),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.w),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: AppUI.card(),
              child: AppVerticalScrollbar(
                header: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        Expanded(flex: 1, child: Text('S. NO.', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text(schoolTerm('ROLL NO.'), style: AppUI.tableHead)),
                        Expanded(flex: 3, child: Text('STUDENT NAME', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text(schoolTerm('COURSE'), style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text(schoolTerm('CLASS'), style: AppUI.tableHead)),
                        if (!isSchool) Expanded(flex: 2, child: Text('BATCH', style: AppUI.tableHead)),
                        Expanded(flex: 2, child: Text('MOBILE NO.', style: AppUI.tableHead)),
                        Expanded(flex: 1, child: Text('VIEW', textAlign: TextAlign.right, style: AppUI.tableHead)),
                      ],
                    ),
                  ),
                  Container(height: 1, color: AppColors.divider),
                  ],
                ),
                builder: (context, controller) => ListView.separated(
                      controller: controller,
                      itemCount: allStudents.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (context, index) {
                        final s = allStudents[index];
                        final serialNo = index + 1;
                        return InkWell(
                          onTap: () => _populateStudentForm(s),
                          child: Container(
                            color: index.isEven ? Colors.white : AppColors.surface,
                            padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                            child: Row(
                              children: [
                                Expanded(flex: 1, child: Text('$serialNo', style: cellStyle)),
                                Expanded(flex: 2, child: Text(s.stuadmno, style: cellStyle)),
                                Expanded(flex: 3, child: Text(s.stuname, style: cellStyle, overflow: TextOverflow.ellipsis)),
                                Expanded(flex: 2, child: Text(s.courname ?? '-', style: cellStyle)),
                                Expanded(flex: 2, child: Text(s.stuclass, style: cellStyle)),
                                if (!isSchool) Expanded(flex: 2, child: Text(s.batch ?? '-', style: cellStyle)),
                                Expanded(flex: 2, child: Text(s.stumobile.isEmpty ? '-' : s.stumobile, style: cellStyle)),
                                Expanded(flex: 1, child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Container(
                                    width: 30.w,
                                    height: 30.w,
                                    decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8.r)),
                                    child: const Center(child: AppIcon('user', size: 16, color: AppColors.accent)),
                                  ),
                                )),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildClassStudentTable(String className) {
    var allStudents = _groupedStudents[className]?.isNotEmpty == true
        ? _groupedStudents[className]!
        : _cachedClassStudents[className] ?? [];
    // Filter by course
    if (_selectedCourseFilter != null) {
      allStudents = allStudents.where((s) => (s.courname ?? 'Other') == _selectedCourseFilter).toList();
    }
    if (_loadingClassStudents && allStudents.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final classColor = _getClassColor(className);

    // Search filter
    final q = _searchController.text.toLowerCase();
    final filteredStudents = q.isEmpty
        ? allStudents
        : allStudents.where((s) =>
            s.stuname.toLowerCase().contains(q) ||
            s.stuadmno.toLowerCase().contains(q)).toList();

    return Container(
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Ledger-style class header: icon + class name (colored) + count
          // pill + search field + import buttons (same as the All Students view).
          // Class switching happens via the sidebar.
          Container(
            padding: EdgeInsets.fromLTRB(12.w, 10.h, 16.w, 10.h),
            decoration: BoxDecoration(
              color: classColor.withValues(alpha: 0.06),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(AppUI.cardRadius),
                topRight: Radius.circular(AppUI.cardRadius),
              ),
              border: const Border(bottom: BorderSide(color: AppColors.divider)),
            ),
            child: Row(
              children: [
                AppIcon('book-1', size: 14, color: classColor),
                SizedBox(width: 6.w),
                Text(
                  className,
                  style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: classColor),
                ),
                SizedBox(width: 8.w),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                  decoration: BoxDecoration(
                    color: classColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10.r),
                  ),
                  child: Text(
                    '${allStudents.length} students',
                    style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: classColor),
                  ),
                ),
                const Spacer(),
                AppSearchField(
                  controller: _searchController,
                  hintText: schoolTerm('Search by name or roll no.'),
                  onChanged: (_) => setState(() {}),
                  width: 260.w,
                ),
                ..._buildImportActionButtons(),
              ],
            ),
          ),
          // Table header + rows, sharing a reserved scrollbar lane
          Expanded(
            child: AppVerticalScrollbar(
              header: Container(
                padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                color: AppColors.tableHeadBg,
                child: Row(
                  children: [
                    Expanded(flex: 1, child: Text('S. NO.', style: AppUI.tableHead)),
                    Expanded(flex: 2, child: Text(schoolTerm('ROLL NO.'), style: AppUI.tableHead)),
                    Expanded(flex: 3, child: Text('STUDENT NAME', style: AppUI.tableHead)),
                    Expanded(flex: 2, child: Text(schoolTerm('COURSE'), style: AppUI.tableHead)),
                    if (!isSchool) Expanded(flex: 2, child: Text('BATCH', style: AppUI.tableHead)),
                    Expanded(flex: 1, child: Text('GENDER', style: AppUI.tableHead)),
                    Expanded(flex: 2, child: Text('MOBILE NO.', style: AppUI.tableHead)),
                    Expanded(flex: 1, child: Text('VIEW', textAlign: TextAlign.right, style: AppUI.tableHead)),
                  ],
                ),
              ),
              builder: (context, controller) => filteredStudents.isEmpty
                ? AppUI.empty(
                    icon: 'people',
                    title: 'No students found',
                    why: q.isEmpty
                        ? schoolTerm('No students in this class yet. Use Import CSV/Excel to add them.')
                        : 'No student matches your search.',
                  )
                : ListView.separated(
                    controller: controller,
                    padding: EdgeInsets.zero,
                    itemCount: filteredStudents.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                    itemBuilder: (context, index) {
                      final s = filteredStudents[index];
                      return InkWell(
                        onTap: () {
                          setState(() => _selectedStudent = s);
                          _populateStudentForm(s);
                        },
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
                          color: index.isEven ? Colors.white : AppColors.surface,
                          child: Row(
                            children: [
                              Expanded(flex: 1, child: Text('${index + 1}', style: AppUI.cell)),
                              Expanded(flex: 2, child: Text(s.stuadmno, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                              Expanded(flex: 3, child: Text(s.stuname, style: AppUI.cell, overflow: TextOverflow.ellipsis)),
                              Expanded(flex: 2, child: Text(s.courname ?? '-', style: AppUI.cell)),
                              if (!isSchool) Expanded(flex: 2, child: Text(s.batch ?? '-', style: AppUI.cell)),
                              Expanded(flex: 1, child: Text(s.stugender, style: AppUI.cell)),
                              Expanded(flex: 2, child: Text(s.stumobile, style: AppUI.cell)),
                              Expanded(flex: 1, child: Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  width: 30.w,
                                  height: 30.w,
                                  decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8.r)),
                                  child: const Center(child: AppIcon('user', size: 16, color: AppColors.accent)),
                                ),
                              )),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
            ),
          ),
        ],
      ),
    );
  }

  // â”€â”€â”€ Build â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [

        // Global search results
        if (_globalSearchController.text.isNotEmpty) ...[
          Container(
            constraints: BoxConstraints(maxHeight: 300.h),
            decoration: AppUI.card(),
            child: _isGlobalSearching
                ? const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
                : _globalSearchResults.isEmpty
                    ? AppUI.empty(
                        icon: 'people',
                        title: 'No students found',
                        why: 'No student matches that search. Try a different name or number.',
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _globalSearchResults.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                        itemBuilder: (context, index) {
                          final s = _globalSearchResults[index];
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 16.r,
                              backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                              child: Text(s.stuname[0].toUpperCase(), style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700, fontSize: 12.sp)),
                            ),
                            title: Text(s.stuname, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.sp)),
                            subtitle: Text(schoolTerm('Adm No: ${s.stuadmno} | Mobile: ${s.stumobile} | Class: ${s.stuclass}'), style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
                            onTap: () async {
                              _globalSearchController.clear();
                              setState(() {
                                _globalSearchResults = [];
                                _selectedClassFilter = s.stuclass;
                                _selectedStudent = s;
                                _searchController.clear();
                              });
                              if (_cachedClassStudents[s.stuclass] == null) {
                                setState(() => _loadingClassStudents = true);
                                final auth = context.read<AuthProvider>();
                                final insId = auth.insId ?? 1;
                                final classStudents = await SupabaseService.getStudentsByClass(insId, s.stuclass);
                                if (mounted) {
                                  setState(() {
                                    _cachedClassStudents[s.stuclass] = classStudents;
                                    _loadingClassStudents = false;
                                  });
                                }
                              }
                            },
                          );
                        },
                      ),
          ),
          SizedBox(height: 12.h),
        ],

        Expanded(
          child: _showImport ? _buildStudentImportSection() : Form(
            key: _formKey,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // LEFT - Student List
                SizedBox(
                  width: 260.w,
            child: Container(
              decoration: AppUI.card(),
              child: Column(
                children: [
                  // Header
                  Container(
                    padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 10.h),
                    child: Column(
                      children: [
                        AppUI.cardHeader(
                          icon: 'people',
                          title: 'Student Details',
                          trailing: [
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10.r),
                              ),
                              child: Text('${_students.isNotEmpty ? _students.length : _classCounts.values.fold(0, (s, c) => s + c)}', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
                            ),
                          ],
                        ),
                        SizedBox(height: 0.h),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.divider),
                  // Class list (always visible)
                  Expanded(
                    child: _buildClassList(),
                  ),
                ],
              ),
            ),
          ),

          SizedBox(width: AppUI.gap),

          // RIGHT - Student Details or Class Table
          Expanded(
            child: _selectedStudent == null
                ? Container(
                    decoration: AppUI.card(),
                    clipBehavior: Clip.antiAlias,
                    child: _selectedClassFilter != null ? _buildClassStudentTable(_selectedClassFilter!) : _buildAllStudentsTable(),
                  )
                : Column(
                    children: [
                      // Back breadcrumb
                      if (_selectedStudent != null)
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                          margin: EdgeInsets.only(bottom: 8.h),
                          decoration: AppUI.card(),
                          child: Row(
                            children: [
                              InkWell(
                                onTap: () => setState(() { _selectedStudent = null; }),
                                borderRadius: BorderRadius.circular(8.r),
                                child: Container(
                                  padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                                  decoration: BoxDecoration(
                                    color: AppColors.accent,
                                    borderRadius: BorderRadius.circular(AppUI.controlRadius),
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
                              Text('Students', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                              SizedBox(width: 6.w),
                              AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                              SizedBox(width: 6.w),
                              Text(_selectedStudent!.stuname, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                              SizedBox(width: 6.w),
                              Text('(${_selectedStudent!.stuadmno})', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Student Information panel
                              Container(
                                width: double.infinity,
                                padding: EdgeInsets.all(AppUI.cardPad),
                                decoration: AppUI.card(),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              AppUI.cardHeader(icon: 'user', title: 'Student Information'),
                                              SizedBox(height: 6.h),
                                              Row(children: [
                                                if (_insLogo != null)
                                                  Image.network(
                                                    _insLogo!,
                                                    width: 48.w, height: 48.h, fit: BoxFit.contain,
                                                    errorBuilder: (_, __, ___) => AppIcon('teacher', color: AppColors.accent, size: 44.sp),
                                                  )
                                                else
                                                  AppIcon('teacher', color: AppColors.accent, size: 44.sp),
                                                SizedBox(width: 8.w),
                                                Flexible(
                                                  child: Text(
                                                    _insName ?? context.read<AuthProvider>().insName ?? context.read<AuthProvider>().inscode ?? '',
                                                    style: TextStyle(fontSize: 15.sp, color: AppColors.textPrimary, fontWeight: FontWeight.w700),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ]),
                                            ],
                                          ),
                                        ),
                                        Column(
                                          children: [
                                            Container(
                                              width: 72.w, height: 72.h,
                                              decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.accent.withValues(alpha: 0.1)),
                                              child: ClipOval(
                                                child: _photoUrl != null
                                                    ? Image.network(_photoUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _avatarPlaceholder())
                                                    : _avatarPlaceholder(),
                                              ),
                                            ),
                                            TextButton.icon(
                                              onPressed: (_isFormEnabled && !_isUploadingPhoto) ? _uploadPhoto : null,
                                              icon: _isUploadingPhoto
                                                  ? SizedBox(width: 14.w, height: 14.h, child: const CircularProgressIndicator(strokeWidth: 2))
                                                  : AppIcon('camera', size: 14),
                                              label: Text(_isUploadingPhoto ? 'Uploading...' : 'Upload Photo', style: TextStyle(fontSize: 13.sp)),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const Divider(color: AppColors.divider),
                                    SizedBox(height: 4.h),
                                    IgnorePointer(
                                      ignoring: !_isFormEnabled,
                                      child: _buildStudentFields(),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: AppUI.gap),
                              _panel(title: 'Parent / Guardian Information', icon: 'people', child: _buildParentFields()),
                              SizedBox(height: AppUI.gap),
                              _panel(title: 'Payment In Charge', icon: 'indianrupeesign.circle.fill', child: _buildPaymentFields()),
                              if (_selectedStudent == null || _isFormEnabled) ...[
                                SizedBox(height: 16.h),
                                Align(alignment: Alignment.centerLeft, child: AppUI.requiredNote()),
                                SizedBox(height: 8.h),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextButton.icon(
                                        onPressed: _isSaving ? null : _cancelForm,
                                        icon: AppIcon('close-circle', size: 16),
                                        label: const Text('Cancel'),
                                        style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
                                      ),
                                    ),
                                    SizedBox(width: 12.w),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: _isSaving ? null : (_selectedStudent == null ? _saveNewStudent : _updateStudent),
                                        icon: _isSaving
                                            ? SizedBox(width: 18.w, height: 18.h, child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                            : AppIcon('save-2', size: 18),
                                        label: Text(_isSaving ? 'Saving...' : (_selectedStudent == null ? 'Save' : 'Update')),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              SizedBox(height: 24.h),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // â”€â”€â”€ Left panel: Student fields â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildStudentFields() {
    return FocusTraversalGroup(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row3(
          _fieldFull(label: 'Academic Year *', child: DropdownButtonFormField<String>(
            initialValue: _selectedYrId,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            decoration: _dec('Select academic year', filled: _selectedYrId != null),
            icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
            style: _inputStyle,
            items: _years.map((y) => DropdownMenuItem(value: y['yr_id'].toString(), child: Text(y['yrlabel']))).toList(),
            selectedItemBuilder: (context) => _years.map((y) => Align(alignment: Alignment.centerLeft, child: Text(y['yrlabel'], overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
            onChanged: (v) => setState(() {
              _selectedYrId = v;
              _selectedYrLabel = v != null
                  ? _years.firstWhere((y) => y['yr_id'].toString() == v)['yrlabel']
                  : null;
            }),
            validator: (v) => v == null ? 'Required' : null,
          )),
          _fieldFull(label: schoolTerm('Roll Number *'), child: TextFormField(
            controller: _admNoController,
            decoration: _dec(schoolTerm('Enter roll no.'), filled: _admNoController.text.trim().isNotEmpty),
            style: _inputStyle.copyWith(color: _admNoController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            onChanged: (_) => setState(() {}),
            validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
          )),
          _fieldFull(label: 'Student Name *', child: TextFormField(
            controller: _nameController,
            decoration: _dec('Enter full name', filled: _nameController.text.trim().isNotEmpty),
            style: _inputStyle.copyWith(color: _nameController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            onChanged: (_) => setState(() {}),
            validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
          )),
        ),
        SizedBox(height: 14.h),

        _row3(
          _fieldFull(
            label: '${AppText.dateOfAdmission} *',
            child: InkWell(
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _admDate ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(),
                );
                if (d != null) setState(() => _admDate = d);
              },
              child: InputDecorator(
                decoration: _dec('Select date of admission', filled: _admDate != null).copyWith(
                  suffixIcon: Padding(
                    padding: EdgeInsets.only(right: 10.w),
                    child: AppIcon('calendar-1', size: 14, color: AppColors.textSecondary),
                  ),
                ),
                child: Text(
                  _admDate != null
                      ? formatDmy(_admDate)
                      : 'Select date of admission',
                  style: _admDate != null
                      ? AppUI.fieldText(context, filled: true)
                      : AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ),
          _fieldFull(label: 'Gender *', child: DropdownButtonFormField<String>(
            initialValue: _selectedGender,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            decoration: _dec('Select gender', filled: _selectedGender != null),
            icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
            style: _inputStyle,
            items: _genders.map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
            selectedItemBuilder: (context) => _genders.map((g) => Align(alignment: Alignment.centerLeft, child: Text(g, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
            onChanged: (v) => setState(() => _selectedGender = v),
            validator: (v) => v == null ? 'Required' : null,
          )),
          _fieldFull(label: 'Date of Birth *', child: InkWell(
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _dob ?? DateTime(2015),
                firstDate: DateTime(1990),
                lastDate: DateTime.now(),
              );
              if (d != null) setState(() => _dob = d);
            },
            child: InputDecorator(
              decoration: _dec('Select date of birth', filled: _dob != null),
              child: Text(
                _dob != null
                    ? formatDmy(_dob)
                    : 'Select date of birth',
                style: _dob != null
                    ? AppUI.fieldText(context, filled: true)
                    : AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500),
              ),
            ),
          )),
        ),
        SizedBox(height: 14.h),

        _row3(
          _fieldFull(label: _selectedStudent == null ? 'Mobile Number *' : 'Mobile Number', child: TextFormField(
            controller: _mobileController,
            decoration: _dec('Enter mobile', filled: _mobileController.text.trim().isNotEmpty),
            style: _inputStyle.copyWith(color: _mobileController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
          )),
          _fieldFull(label: 'Email', child: TextFormField(
            controller: _emailController,
            decoration: _dec('Enter email', filled: _emailController.text.trim().isNotEmpty),
            style: _inputStyle.copyWith(color: _emailController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.emailAddress,
          )),
          _fieldFull(label: schoolTerm('Course'), child: TextFormField(
            initialValue: _selectedStudent?.courname ?? '',
            decoration: _dec(schoolTerm('Auto-filled from class'), filled: (_selectedStudent?.courname ?? '').trim().isNotEmpty),
            style: _inputStyle.copyWith(color: (_selectedStudent?.courname ?? '').trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            enabled: false,
          )),
        ),
        SizedBox(height: 14.h),

        _row3(
          _fieldFull(label: schoolTerm('Class *'), child: Builder(builder: (_) {
            final classOptions = [
              ..._classes,
              if (_selectedClass != null &&
                  _selectedClass!.isNotEmpty &&
                  !_classes.contains(_selectedClass))
                _selectedClass!,
            ];
            return DropdownButtonFormField<String>(
              initialValue: classOptions.contains(_selectedClass) ? _selectedClass : null,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _dec(schoolTerm('Select class'), filled: _selectedClass != null),
              icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              style: _inputStyle,
              items: classOptions.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
              selectedItemBuilder: (context) => classOptions.map((c) => Align(alignment: Alignment.centerLeft, child: Text(c, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
              onChanged: (v) => setState(() => _selectedClass = v),
              validator: (v) => v == null ? 'Required' : null,
            );
          })),
          _fieldFull(label: 'Blood Group', child: DropdownButtonFormField<String>(
            initialValue: _selectedBloodGroup,
            isExpanded: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            decoration: _dec('Select blood group', filled: _selectedBloodGroup != null),
            icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
            style: _inputStyle,
            items: _bloodGroups.map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
            selectedItemBuilder: (context) => _bloodGroups.map((g) => Align(alignment: Alignment.centerLeft, child: Text(g, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
            onChanged: (v) => setState(() => _selectedBloodGroup = v),
          )),
          _fieldFull(label: 'Concession', child: Builder(builder: (_) {
            // Dedupe by con_id - duplicate master rows would otherwise crash
            // DropdownButton with "2 or more items with the same value".
            final seen = <String>{};
            final items = <DropdownMenuItem<String>>[];
            for (final c in _concessions) {
              final v = c['con_id']?.toString();
              if (v == null || !seen.add(v)) continue;
              items.add(DropdownMenuItem(value: v, child: Text((c['condesc'] ?? '').toString(), overflow: TextOverflow.ellipsis)));
            }
            final value = seen.contains(_selectedConId) ? _selectedConId : null;
            return DropdownButtonFormField<String>(
              initialValue: value,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _dec('Select concession', filled: value != null),
              icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              style: _inputStyle,
              items: items,
              selectedItemBuilder: (context) => items.map((e) => Align(alignment: Alignment.centerLeft, child: Text((e.child as Text).data ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
              onChanged: (v) => setState(() => _selectedConId = v),
            );
          })),
        ),
        SizedBox(height: 14.h),

        // A school has no admission type / quota / batch.
        if (!isSchool) ...[
        _row3(
          _fieldFull(label: 'Admission Type', child: Builder(builder: (_) {
            final seen = <String>{};
            final items = <DropdownMenuItem<String>>[];
            for (final a in _admissionTypes) {
              final v = a['admname']?.toString();
              if (v == null || v.isEmpty || !seen.add(v)) continue;
              items.add(DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis)));
            }
            final value = seen.contains(_selectedAdmName) ? _selectedAdmName : null;
            return DropdownButtonFormField<String>(
              initialValue: value,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _dec('Select admission type', filled: value != null),
              icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              style: _inputStyle,
              items: items,
              selectedItemBuilder: (context) => items.map((e) => Align(alignment: Alignment.centerLeft, child: Text((e.child as Text).data ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
              onChanged: (v) => setState(() => _selectedAdmName = v),
            );
          })),
          _fieldFull(label: 'Quota', child: Builder(builder: (_) {
            final seen = <String>{};
            final items = <DropdownMenuItem<String>>[];
            for (final q in _quotas) {
              final v = q['quoname']?.toString();
              if (v == null || v.isEmpty || !seen.add(v)) continue;
              items.add(DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis)));
            }
            final value = seen.contains(_selectedQuoName) ? _selectedQuoName : null;
            return DropdownButtonFormField<String>(
              initialValue: value,
              isExpanded: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              decoration: _dec('Select quota', filled: value != null),
              icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              style: _inputStyle,
              items: items,
              selectedItemBuilder: (context) => items.map((e) => Align(alignment: Alignment.centerLeft, child: Text((e.child as Text).data ?? '', overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
              onChanged: (v) => setState(() => _selectedQuoName = v),
            );
          })),
          _fieldFull(label: 'Batch', child: TextFormField(
            controller: _batchController,
            decoration: _dec('e.g. 2024-2028', filled: _batchController.text.trim().isNotEmpty),
            style: _inputStyle.copyWith(color: _batchController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            onChanged: (_) => setState(() {}),
          )),
        ),
        SizedBox(height: 14.h),
        ],

        _fieldFull(label: 'Address *', child: TextFormField(
          controller: _addressController,
          decoration: _dec('Enter address', filled: _addressController.text.trim().isNotEmpty),
          style: _inputStyle.copyWith(color: _addressController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
          onChanged: (_) => setState(() {}),
          maxLines: 2,
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
        )),
        SizedBox(height: 14.h),

        _row4(
          _fieldFull(label: 'City', child: TextFormField(controller: _cityController, decoration: _dec('Enter city', filled: _cityController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _cityController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
          _fieldFull(label: 'State', child: TextFormField(controller: _stateController, decoration: _dec('Enter state', filled: _stateController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _stateController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
          _fieldFull(label: 'Country', child: TextFormField(controller: _countryController, decoration: _dec('Enter country', filled: _countryController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _countryController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
          _fieldFull(label: 'PIN Code *', child: TextFormField(
            controller: _pinController,
            decoration: _dec('Enter PIN code', filled: _pinController.text.trim().isNotEmpty),
            style: _inputStyle.copyWith(color: _pinController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'Required'
                : v.trim().length != 6 ? 'PIN code must be 6 digits' : null,
          )),
        ),
        SizedBox(height: 14.h),

        _row4(
          _fieldFull(label: 'Aadhaar No.', child: TextFormField(
            controller: _aadharController,
            decoration: _dec('Enter Aadhaar number', filled: _aadharController.text.trim().isNotEmpty),
            style: _inputStyle.copyWith(color: _aadharController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          )),
          _fieldFull(label: 'Community', child: TextFormField(controller: _communityController, decoration: _dec('Enter community', filled: _communityController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _communityController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
          _fieldFull(label: 'Caste', child: TextFormField(controller: _casteController, decoration: _dec('Enter caste', filled: _casteController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _casteController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
          _fieldFull(label: 'Religion', child: TextFormField(controller: _religionController, decoration: _dec('Enter religion', filled: _religionController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _religionController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
        ),
        // EMIS / UMIS — government identifiers carried over from admission.
        // Digits only, like Aadhar, but no fixed length: the formats differ and
        // have changed between intakes.
        _row4(
          _fieldFull(label: schoolTerm('EMIS No'), child: TextFormField(
            controller: _emisController,
            decoration: _dec(schoolTerm('Enter EMIS no'), filled: _emisController.text.trim().isNotEmpty),
            style: _inputStyle.copyWith(color: _emisController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          )),
          // A school has no UMIS number.
          isSchool ? const SizedBox.shrink() : _fieldFull(label: 'UMIS No', child: TextFormField(
            controller: _umisController,
            decoration: _dec('Enter UMIS no', filled: _umisController.text.trim().isNotEmpty),
            style: _inputStyle.copyWith(color: _umisController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          )),
          const SizedBox.shrink(),
          const SizedBox.shrink(),
        ),
        SizedBox(height: 14.h),

        _row4(
          _fieldFull(label: 'Nationality', child: TextFormField(controller: _nationalityController, decoration: _dec('Enter nationality', filled: _nationalityController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _nationalityController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
          _fieldFull(label: 'Transport Mode', child: TextFormField(controller: _transportController, decoration: _dec('e.g. Bus / Own', filled: _transportController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _transportController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
          _fieldFull(label: 'Hostel', child: DropdownButtonFormField<String>(
            initialValue: _selectedHostel,
            isExpanded: true,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            decoration: _dec('Select yes or no', filled: _selectedHostel != null),
            icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
            style: _inputStyle,
            items: const [
              DropdownMenuItem(value: 'Y', child: Text('Yes')),
              DropdownMenuItem(value: 'N', child: Text('No')),
            ],
            selectedItemBuilder: (context) => ['Yes', 'No'].map((g) => Align(alignment: Alignment.centerLeft, child: Text(g, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: true)))).toList(),
            onChanged: (v) => setState(() => _selectedHostel = v),
          )),
          _fieldFull(label: 'Admitted Year', child: TextFormField(controller: _admittedYearController, decoration: _dec('e.g. 2025-2026', filled: _admittedYearController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _admittedYearController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
        ),
        SizedBox(height: 14.h),

        _row4(
          _fieldFull(label: 'Medium', child: TextFormField(controller: _mediumController, decoration: _dec('e.g. English / Tamil', filled: _mediumController.text.trim().isNotEmpty), style: _inputStyle.copyWith(color: _mediumController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600), onChanged: (_) => setState(() {}))),
          const SizedBox(),
          const SizedBox(),
          const SizedBox(),
        ),
      ],
    ),
    );
  }

  // â”€â”€â”€ Right panel: Parent fields â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildParentFields() {
    final controllers = _selectedParentTab == 'Father'
        ? (_fatherNameController, _fatherMobileController, _fatherOccController)
        : _selectedParentTab == 'Mother'
            ? (_motherNameController, _motherMobileController, _motherOccController)
            : (_guardianNameController, _guardianMobileController, _guardianOccController);
    final prefix = _selectedParentTab;

    return FocusTraversalGroup(
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8.w,
          runSpacing: 8.h,
          children: ['Father', 'Mother', 'Guardian'].map((tab) {
            final selected = _selectedParentTab == tab;
            return ChoiceChip(
              label: Text(tab),
              selected: selected,
              onSelected: (_) => setState(() => _selectedParentTab = tab),
              labelStyle: TextStyle(color: selected ? AppColors.primary : AppColors.textSecondary, fontWeight: FontWeight.w700),
            );
          }).toList(),
        ),
        SizedBox(height: 16.h),

        IgnorePointer(
          ignoring: !_isFormEnabled,
          child: _row3(
            _fieldFull(label: '$prefix Name', child: TextFormField(
              controller: controllers.$1,
              decoration: _dec("Enter ${prefix.toLowerCase()}'s name", filled: controllers.$1.text.trim().isNotEmpty),
              style: _inputStyle.copyWith(color: controllers.$1.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
              onChanged: (_) => setState(() {}),
            )),
            _fieldFull(label: '$prefix Mobile', child: TextFormField(
              controller: controllers.$2,
              decoration: _dec('Enter mobile', filled: controllers.$2.text.trim().isNotEmpty),
              style: _inputStyle.copyWith(color: controllers.$2.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
              onChanged: (_) => setState(() {}),
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
            )),
            _fieldFull(label: '$prefix Occupation', child: TextFormField(
              controller: controllers.$3,
              decoration: _dec('Enter occupation', filled: controllers.$3.text.trim().isNotEmpty),
              style: _inputStyle.copyWith(color: controllers.$3.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
              onChanged: (_) => setState(() {}),
            )),
          ),
        ),
        SizedBox(height: 14.h),
        // Parent email is a single parents-level field (shared across tabs).
        IgnorePointer(
          ignoring: !_isFormEnabled,
          child: _row3(
            _fieldFull(label: 'Parent Email', child: TextFormField(
              controller: _parentEmailController,
              decoration: _dec('Enter parent email', filled: _parentEmailController.text.trim().isNotEmpty),
              style: _inputStyle.copyWith(color: _parentEmailController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
              onChanged: (_) => setState(() {}),
              keyboardType: TextInputType.emailAddress,
            )),
            const SizedBox.shrink(),
            const SizedBox.shrink(),
          ),
        ),
      ],
    ),
    );
  }

  // â”€â”€â”€ Right panel: Payment fields â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildPaymentFields() {
    return FocusTraversalGroup(
      child: IgnorePointer(
      ignoring: !_isFormEnabled,
      child: _row2(
      _fieldFull(label: 'Name *', child: TextFormField(
        controller: _payNameController,
        decoration: _dec('Enter name', filled: _payNameController.text.trim().isNotEmpty),
        style: _inputStyle.copyWith(color: _payNameController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
        onChanged: (_) => setState(() {}),
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
      )),
      _fieldFull(label: 'Mobile Number *', child: TextFormField(
        controller: _payMobileController,
        decoration: _dec('Enter mobile', filled: _payMobileController.text.trim().isNotEmpty),
        style: _inputStyle.copyWith(color: _payMobileController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
        onChanged: (_) => setState(() {}),
        keyboardType: TextInputType.phone,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
      )),
    ),
    ));
  }

  // â”€â”€â”€ Excel Import â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Known student fields for column mapping
  static const _importFields = <String, String>{
    '': '-- Skip --',
    'stuadmno': 'Roll No',
    'stuname': 'Name',
    'stugender': 'Gender',
    'studob': 'DOB',
    'stumobile': 'Mobile',
    'stuclass': 'Class',
    'courname': 'Course',
    'stuemail': 'Email',
    'stuaddress': 'Address',
    'stucity': 'City',
    'stustate': 'State',
    'stucountry': 'Country',
    'stupin': 'PIN',
    'stubloodgrp': 'Blood Group',
    'aadharno': 'Aadhar No',
    'community': 'Community',
    'caste': 'Caste',
    'religion': 'Religion',
    'nationality': 'Nationality',
    'transportmode': 'Transport Mode',
    'hostel': 'Hostel (Y/N)',
    'division': 'Division',
    'stuadmdate': 'Admission Date',
    'admittyear': 'Admitted Year',
    'fathername': 'Father Name',
    'fathermobile': 'Father Mobile',
    'fatheroccupation': 'Father Occupation',
    'mothername': 'Mother Name',
    'mothermobile': 'Mother Mobile',
    'motheroccupation': 'Mother Occupation',
    'guardianname': 'Guardian Name',
    'guardianmobile': 'Guardian Mobile',
    'guardianoccupation': 'Guardian Occupation',
    'paremail': 'Parent Email',
    'payincharge': 'Payment In Charge',
    'payinchargemob': 'Payment Mobile',
    'admname': 'Admission Type',
    'quoname': 'Quota',
    'batch': 'Batch',
    'medium': 'Medium',
    // ID columns — resolved to canonical names on staging (id wins over name).
    'course_id': 'Course Id',
    'class_id': 'Class Id',
    'admission_type_id': 'Admission Type Id',
    'concession_id': 'Concession Id',
    'quota_id': 'Quota Id',
    'admitted_course_id': 'Admitted Course Id',
  };

  /// Auto-map header text to field key (case-insensitive)
  static String _autoMapHeader(String header) {
    // Strip the trailing "*" used to flag mandatory columns in our templates
    // ("Roll No *" â†’ "roll no") so re-uploaded templates still auto-map.
    // Normalise: drop the "*" mandatory flag, turn dots into spaces ("REG.NO"
    // -> "reg no"), lowercase, and collapse runs of whitespace.
    final h = collegeTerm(header).replaceAll('*', '').replaceAll('.', ' ').toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    const map = {
      'adm no': 'stuadmno', 'admission number': 'stuadmno', 'admno': 'stuadmno', 'admission no': 'stuadmno', 'roll no': 'stuadmno', 'rollno': 'stuadmno', 'roll number': 'stuadmno',
      'reg no': 'stuadmno', 'regno': 'stuadmno', 'reg number': 'stuadmno', 'register no': 'stuadmno', 'register number': 'stuadmno', 'registration no': 'stuadmno', 'registration number': 'stuadmno',
      'name': 'stuname', 'student name': 'stuname', 'stuname': 'stuname',
      'gender': 'stugender', 'sex': 'stugender',
      'dob': 'studob', 'date of birth': 'studob', 'birth date': 'studob',
      'mobile': 'stumobile', 'phone': 'stumobile', 'mobile no': 'stumobile', 'phone no': 'stumobile',
      'class': 'stuclass', 'grade': 'stuclass',
      'course': 'courname', 'course name': 'courname', 'courname': 'courname',
      'email': 'stuemail', 'e-mail': 'stuemail',
      'address': 'stuaddress',
      'city': 'stucity', 'town': 'stucity',
      'state': 'stustate',
      'country': 'stucountry',
      'pin': 'stupin', 'pincode': 'stupin', 'pin code': 'stupin', 'zip': 'stupin', 'zip code': 'stupin',
      'blood group': 'stubloodgrp', 'bloodgroup': 'stubloodgrp',
      'aadhar no': 'aadharno', 'aadhaar no': 'aadharno', 'aadhar': 'aadharno', 'aadhaar': 'aadharno', 'aadharno': 'aadharno', 'aadhar number': 'aadharno', 'aadhaar number': 'aadharno',
      'community': 'community',
      'division': 'division', 'div': 'division', 'division name': 'division',
      'caste': 'caste',
      'religion': 'religion',
      'nationality': 'nationality',
      'transport mode': 'transportmode', 'transportmode': 'transportmode', 'transport': 'transportmode',
      'hostel': 'hostel', 'hostel (y/n)': 'hostel', 'hosteller': 'hostel',
      'admission date': 'stuadmdate', 'adm date': 'stuadmdate',
      'admitted year': 'admittyear', 'admittedyear': 'admittyear', 'admittyear': 'admittyear', 'adm year': 'admittyear', 'admndate': 'admittyear',
      'father name': 'fathername', 'fathername': 'fathername',
      'father mobile': 'fathermobile', 'fathermobile': 'fathermobile', 'father phone': 'fathermobile',
      'father occupation': 'fatheroccupation', 'fatheroccupation': 'fatheroccupation',
      'mother name': 'mothername', 'mothername': 'mothername',
      'mother mobile': 'mothermobile', 'mothermobile': 'mothermobile', 'mother phone': 'mothermobile',
      'mother occupation': 'motheroccupation', 'motheroccupation': 'motheroccupation',
      'guardian name': 'guardianname', 'guardianname': 'guardianname',
      'guardian mobile': 'guardianmobile', 'guardianmobile': 'guardianmobile', 'guardian phone': 'guardianmobile',
      'guardian occupation': 'guardianoccupation', 'guardianoccupation': 'guardianoccupation',
      'concession': 'concession', 'concession category': 'concession',
      'payment in charge': 'payincharge', 'pay in charge': 'payincharge', 'payincharge': 'payincharge', 'pay name': 'payincharge',
      'payment mobile': 'payinchargemob', 'pay mobile': 'payinchargemob', 'payinchargemob': 'payinchargemob',
      'admission type': 'admname', 'admtype': 'admname', 'admname': 'admname',
      'quota': 'quoname', 'quota name': 'quoname', 'quoname': 'quoname',
      'batch': 'batch', 'batch no': 'batch', 'batch number': 'batch',
      'medium': 'medium', 'stumedium': 'medium',
      // ID columns (whitespace already collapsed by the normaliser).
      'course id': 'course_id', 'courseid': 'course_id', 'cour id': 'course_id',
      'class id': 'class_id', 'classid': 'class_id', 'cla id': 'class_id',
      'admission type id': 'admission_type_id', 'admtype id': 'admission_type_id', 'adm type id': 'admission_type_id',
      'concession id': 'concession_id', 'concession category id': 'concession_id', 'con id': 'concession_id',
      'quota id': 'quota_id', 'quo id': 'quota_id',
      'admitted course id': 'admitted_course_id',
    };
    return map[h] ?? '';
  }

  /// Parse a date string in common formats
  static DateTime? _parseDate(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    final t = s.trim();
    // yyyy-MM-dd (ISO format)
    try { return DateTime.parse(t); } catch (_) {}
    final parts = t.split(RegExp(r'[/\-.]'));
    if (parts.length == 3) {
      final a = int.tryParse(parts[0]);
      final b = int.tryParse(parts[1]);
      final c = int.tryParse(parts[2]);
      if (a != null && b != null && c != null) {
        // Try MM-DD-YYYY or MM-DD-YY (US format)
        if (a >= 1 && a <= 12 && b >= 1 && b <= 31) {
          final year = c < 100 ? (c > 50 ? c + 1900 : c + 2000) : c;
          return DateTime(year, a, b);
        }
        // Try DD-MM-YYYY or DD-MM-YY (Indian format)
        if (b >= 1 && b <= 12 && a >= 1 && a <= 31) {
          final year = c < 100 ? (c > 50 ? c + 1900 : c + 2000) : c;
          return DateTime(year, b, a);
        }
        // Try YYYY-MM-DD where first part is year
        if (a > 1900 && b >= 1 && b <= 12 && c >= 1 && c <= 31) {
          return DateTime(a, b, c);
        }
      }
    }
    return null;
  }

  /// Normalize gender input to M/F/O
  static String _normalizeGender(String? g) {
    if (g == null) return 'M';
    final v = g.trim().toUpperCase();
    if (v == 'M' || v == 'MALE') return 'M';
    if (v == 'F' || v == 'FEMALE') return 'F';
    return 'O';
  }

  // â”€â”€â”€ Import Logic â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _resetImport() {
    setState(() {
      _showImport = false;
      _importStep = 0;
      _importFileName = null;
      _importHeaders = [];
      _importRows = [];
      _importMappings = [];
      _importedCount = 0;
      _skippedCount = 0;
      _totalCount = 0;
      _importErrors = [];
      _importErrorMsg = null;
      _rowErrors = {};
      _cellErrors = {};
    });
  }

  Future<void> _pickImportFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'xls'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    final ext = (file.extension ?? '').toLowerCase();
    try {
      List<String> headers;
      List<List<dynamic>> rows;

      if (ext == 'csv') {
        final csvString = utf8.decode(file.bytes!);
        final parsed = const CsvToListConverter().convert(csvString);
        if (parsed.isEmpty) throw Exception('The file is empty. Add student rows and choose the file again.');
        headers = parsed.first.map((e) => e.toString().trim()).toList();
        rows = parsed.skip(1).where((r) => r.any((c) => c.toString().trim().isNotEmpty)).toList();
      } else {
        final excel = xl.Excel.decodeBytes(file.bytes!);
        final sheetName = excel.tables.keys.first;
        final sheet = excel.tables[sheetName]!;
        if (sheet.rows.isEmpty) throw Exception('The file is empty. Add student rows and choose the file again.');
        headers = sheet.rows.first.map((c) => c?.value?.toString().trim() ?? '').toList();
        rows = sheet.rows.skip(1)
            .where((r) => r.any((c) => c?.value != null && c!.value.toString().trim().isNotEmpty))
            .map((r) => r.map((c) => c?.value ?? '').toList())
            .toList();
      }

      final mappings = headers.map((h) {
        final m = _autoMapHeader(h);
        return m.isEmpty ? null : m;
      }).toList();

      setState(() {
        _importFileName = file.name;
        _importHeaders = headers;
        _importRows = rows;
        _importValidated = false;
        _importMappings = mappings;
        _importStep = 1;
        _importErrorMsg = null;
      });
      await _loadImportMasters();
    } catch (e) {
      setState(() => _importErrorMsg = friendlyError(e));
    }
  }

  /// Fetch class + course masters so _validateImportRow can flag rows whose
  /// class/course doesn't exist or whose mapping disagrees with the master.
  Future<void> _loadImportMasters() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    String norm(String s) => s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    try {
      final results = await Future.wait([
        SupabaseService.fromSchema('class')
            .select('cla_id, claname, cour_id')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        SupabaseService.fromSchema('course')
            .select('cour_id, courname')
            .eq('ins_id', insId),
      ]);
      final classRows = results[0] as List;
      final courseRows = results[1] as List;
      final courNameById = <int, String>{
        for (final c in courseRows)
          if (c['cour_id'] is int && (c['courname']?.toString() ?? '').isNotEmpty)
            c['cour_id'] as int: c['courname'].toString().trim(),
      };
      final classNames = <String>{};
      final classToCourse = <String, String?>{};
      for (final r in classRows) {
        final name = (r['claname']?.toString() ?? '').trim();
        if (name.isEmpty) continue;
        final k = norm(name);
        classNames.add(k);
        final cid = r['cour_id'];
        if (cid is int && courNameById.containsKey(cid)) {
          classToCourse[k] = norm(courNameById[cid]!);
        }
      }
      final courseNames = courNameById.values.map(norm).toSet();
      if (mounted) {
        setState(() {
          _importClassNames = classNames;
          _importCourseNames = courseNames;
          _importClassToCourse = classToCourse;
        });
      }
    } catch (e) {
      debugPrint('Load import masters failed: $e');
    }
  }

  /// Export the currently-loaded rows back to Excel with an extra "Error"
  /// column populated for each failed row, so the user can fix the issues
  /// offline and re-import the corrected file.
  Future<void> _exportImportRowsWithErrors() async {
    final excel = xl.Excel.createExcel();
    final sheet = excel['Students'];
    excel.delete('Sheet1');

    final origHeaders = List<String>.from(_importHeaders);
    final headers = [...origHeaders, 'Error'];
    final headerStyle = xl.CellStyle(
      backgroundColorHex: xl.ExcelColor.fromHexString('#FF2D3748'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFFFF'),
      bold: true,
    );
    final errorCellStyle = xl.CellStyle(
      backgroundColorHex: xl.ExcelColor.fromHexString('#FFFCE4E4'),
    );
    for (int i = 0; i < headers.length; i++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = xl.TextCellValue(headers[i]);
      cell.cellStyle = headerStyle;
      sheet.setColumnWidth(i, i == headers.length - 1 ? 40.0 : 18.0);
    }
    sheet.setRowHeight(0, 32);

    for (int r = 0; r < _importRows.length; r++) {
      final row = _importRows[r];
      final cellErrs = _cellErrors[r] ?? const <String, String>{};
      for (int c = 0; c < origHeaders.length; c++) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
        final raw = c < row.length ? row[c].toString() : '';
        cell.value = xl.TextCellValue(raw);
        final mappedKey = c < _importMappings.length ? _importMappings[c] : null;
        if (mappedKey != null && cellErrs.containsKey(mappedKey)) {
          cell.cellStyle = errorCellStyle;
        }
      }
      // Error column
      final errorCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: origHeaders.length, rowIndex: r + 1));
      errorCell.value = xl.TextCellValue(_rowErrors[r] ?? '');
      if (cellErrs.isNotEmpty) errorCell.cellStyle = errorCellStyle;
    }

    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save File with Errors',
        fileName: 'student_import_errors.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (savePath == null) return;
      final bytes = excel.encode();
      if (bytes == null) return;
      await File(savePath).writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error report exported'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export the file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _exportStudentTemplate() async {
    final excel = xl.Excel.createExcel();
    final sheet = excel['Students'];
    excel.delete('Sheet1');

    // Headers follow the import grid exactly (same order + labels + the new
    // Medium / ID columns), so the template always matches what the grid shows.
    final headers = _gridKeys.map((k) => _importGridLabels[k] ?? k).toList();

    final headerStyle = xl.CellStyle(
      backgroundColorHex: xl.ExcelColor.fromHexString('#FF2D3748'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFFFF'),
      bold: true,
    );

    for (int i = 0; i < headers.length; i++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = xl.TextCellValue(schoolTerm(headers[i]));
      cell.cellStyle = headerStyle;
      sheet.setColumnWidth(i, 18.0);
    }
    sheet.setRowHeight(0, 32);

    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Template',
        fileName: 'student_import_template.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (savePath == null) return;

      final bytes = excel.encode();
      if (bytes == null) return;
      await File(savePath).writeAsBytes(bytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Template exported successfully'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export the template. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _exportSampleData() async {
    final excel = xl.Excel.createExcel();
    final sheet = excel['Students'];
    excel.delete('Sheet1');

    // Headers + row values keyed to the import grid, so the sample always
    // matches the grid's order + new columns (Medium / IDs left blank).
    final headers = _gridKeys.map((k) => _importGridLabels[k] ?? k).toList();
    final sampleMaps = <Map<String, String>>[
      {
        'stuadmno': 'CS001', 'stuname': 'RAHUL KUMAR', 'stugender': 'Male', 'studob': '2004-06-15',
        'stuadmdate': '2025-06-01', 'courname': isSchool ? 'I' : 'BSC-CS', 'stuclass': isSchool ? 'I A' : 'I Year', 'stumobile': '9876543210',
        'stuemail': 'rahul@email.com', 'concession': 'GENERAL', 'stuaddress': 'No.5 Main Street',
        'stucity': 'Chennai', 'stustate': 'Tamil Nadu', 'stucountry': 'India', 'stupin': '600001',
        'stubloodgrp': 'B+', 'aadharno': '234567890123', 'community': 'OC', 'caste': 'Iyer',
        'religion': 'Hindu', 'nationality': 'Indian', 'transportmode': 'Y', 'hostel': 'N', 'division': 'PRIMARY',
        'fathername': 'KUMAR S', 'fathermobile': '9876543210', 'fatheroccupation': 'Business',
        'mothername': 'LAKSHMI K', 'mothermobile': '9876543211', 'motheroccupation': 'Teacher',
        'paremail': 'kumar@email.com', 'payincharge': 'KUMAR S', 'payinchargemob': '9876543210',
        'admname': 'GEN', 'quoname': 'GQ', 'batch': '2025-2026', 'admittyear': '2025-2026', 'medium': 'English',
      },
      {
        'stuadmno': 'CS002', 'stuname': 'PRIYA S', 'stugender': 'Female', 'studob': '2004-03-22',
        'stuadmdate': '2025-06-01', 'courname': isSchool ? 'I' : 'BSC-CS', 'stuclass': isSchool ? 'I A' : 'I Year', 'stumobile': '9876543220',
        'concession': 'GENERAL', 'stuaddress': 'No.10 Anna Nagar', 'stucity': 'Chennai',
        'stustate': 'Tamil Nadu', 'stucountry': 'India', 'stupin': '600040', 'stubloodgrp': 'O+',
        'aadharno': '345678901234', 'community': 'BC', 'caste': 'Naidu', 'religion': 'Hindu',
        'nationality': 'Indian', 'transportmode': 'N', 'hostel': 'Y', 'fathername': 'SENTHIL S',
        'fathermobile': '9876543220', 'fatheroccupation': 'Engineer', 'mothername': 'MEENA S',
        'mothermobile': '9876543221', 'motheroccupation': 'Homemaker', 'paremail': 'senthil@email.com',
        'payincharge': 'SENTHIL S', 'payinchargemob': '9876543220', 'admname': 'GEN', 'quoname': 'GQ',
        'batch': '2025-2026', 'admittyear': '2025-2026', 'medium': 'Tamil',
      },
    ];
    final sampleRows = sampleMaps.map((m) => _gridKeys.map((k) => m[k] ?? '').toList()).toList();

    final headerStyle = xl.CellStyle(
      backgroundColorHex: xl.ExcelColor.fromHexString('#FF2D3748'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFFFF'),
      bold: true,
    );

    for (int i = 0; i < headers.length; i++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = xl.TextCellValue(schoolTerm(headers[i]));
      cell.cellStyle = headerStyle;
      sheet.setColumnWidth(i, 18);
    }
    for (int r = 0; r < sampleRows.length; r++) {
      for (int c = 0; c < sampleRows[r].length; c++) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
        cell.value = xl.TextCellValue(sampleRows[r][c]);
      }
    }

    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Sample Data',
        fileName: 'student_import_sample.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (savePath == null) return;
      final bytes = excel.encode();
      if (bytes == null) return;
      await File(savePath).writeAsBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sample data exported successfully'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export the sample data. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  String _importMappedCell(List<dynamic> row, String fieldKey) {
    final idx = _importMappings.indexOf(fieldKey);
    if (idx < 0 || idx >= row.length) return '';
    return row[idx].toString().trim();
  }

  String? _importCellByKey(List<dynamic> row, String fieldKey) {
    final idx = _importMappings.indexOf(fieldKey);
    if (idx < 0 || idx >= row.length) return null;
    final v = row[idx].toString().trim();
    return v.isEmpty ? null : v;
  }

  /// Returns null if the value is null, empty, or whitespace-only
  static String? _nullIfEmpty(String? v) {
    if (v == null) return null;
    final trimmed = v.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // Hostel is char(1) on students - normalize free text to 'Y'/'N' (null when
  // blank, since the column is nullable).
  static String? _normalizeYesNo(String? v) {
    final t = _nullIfEmpty(v)?.toUpperCase();
    if (t == null) return null;
    if (t == 'Y' || t == 'YES' || t == 'TRUE' || t == '1') return 'Y';
    if (t == 'N' || t == 'NO' || t == 'FALSE' || t == '0') return 'N';
    return null;
  }

  static String? _truncate(String? v, int maxLen) {
    if (v == null) return null;
    return v.length <= maxLen ? v : v.substring(0, maxLen);
  }

  /// Transport Mode: the export encodes N = own transport, Y = institution
  /// transport. Existing free-text values (Bus, Own, …) pass through unchanged.
  static String? _normalizeTransportMode(String? v) {
    final raw = _nullIfEmpty(v);
    if (raw == null) return null;
    switch (raw.toUpperCase()) {
      case 'N':
      case 'NO':
      case 'OWN':
        return 'OWN';
      case 'Y':
      case 'YES':
      case 'INSTITUTION':
      case 'INSTITUTIONAL':
        return 'INSTITUTION';
    }
    return _truncate(raw, 20);
  }

  /// Validates email format; returns null if invalid
  static String? _validEmail(String? v) {
    final e = _nullIfEmpty(v);
    if (e == null) return null;
    // Basic email check - must contain @ and .
    final regex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return regex.hasMatch(e) ? e : null;
  }

  /// Payment-in-charge auto-fill for import: pick the first parent
  /// (father -> mother -> guardian) that has BOTH a name and a mobile, and
  /// return [name, mobile]. Returns [null, null] when no parent qualifies.
  List<String?> _deriveImportPayer(List<dynamic> row) {
    String? cell(String k) => _nullIfEmpty(_importCellByKey(row, k));
    final fn = cell('fathername'), fm = cell('fathermobile');
    if (fn != null && fm != null) return [fn, fm];
    final mn = cell('mothername'), mm = cell('mothermobile');
    if (mn != null && mm != null) return [mn, mm];
    final gn = cell('guardianname'), gm = cell('guardianmobile');
    if (gn != null && gm != null) return [gn, gm];
    return [null, null];
  }

  /// Per-field validation. Returns a map of fieldKey â†’ reason for every cell
  /// that's invalid. Empty map means the row passes.
  /// Digits-only form of a mobile number (strips spaces, ':', '+', '-', etc.).
  /// Returns null when the result is empty.
  static String? _digitsOnly(String? v) {
    if (v == null) return null;
    final d = v.replaceAll(RegExp(r'[^0-9]'), '');
    return d.isEmpty ? null : d;
  }

  Map<String, String> _validateImportRow(int rowIdx) {
    final row = _importRows[rowIdx];
    final errors = <String, String>{};
    for (final reqKey in _importRequiredFields) {
      final colIdx = _importMappings.indexOf(reqKey);
      if (colIdx < 0 || colIdx >= row.length || row[colIdx].toString().trim().isEmpty) {
        errors[reqKey] = 'Required';
      }
    }
    // Pay In Charge / Mobile: satisfied either by an explicit value or by a
    // parent that has BOTH a name and a mobile (auto-filled at import time).
    final payer = _deriveImportPayer(row);
    final payName = _nullIfEmpty(_importCellByKey(row, 'payincharge')) ?? payer[0];
    final payMob = _nullIfEmpty(_importCellByKey(row, 'payinchargemob')) ?? payer[1];
    if (payName == null) errors['payincharge'] = 'Payment In Charge is missing. Enter it, or enter a parent\'s name and mobile number.';
    if (payMob == null) errors['payinchargemob'] = 'Payment Mobile is missing. Enter it, or enter a parent\'s name and mobile number.';
    // DOB is NOT NULL on students - a non-empty but unparseable value would
    // insert null and fail server-side, so flag the bad format here.
    final dobRaw = (_importCellByKey(row, 'studob') ?? '').trim();
    if (dobRaw.isNotEmpty && _parseDate(dobRaw) == null) {
      errors['studob'] = 'Invalid date (use YYYY-MM-DD)';
    }
    // Mobile numbers must be EXACTLY 10 digits (spaces / punctuation ignored,
    // so "9043531846" and ":9043531846" both count as 10). Only checked when a
    // value is present — required-ness is handled above.
    for (final mk in const ['stumobile', 'fathermobile', 'mothermobile', 'guardianmobile']) {
      final raw = (_importCellByKey(row, mk) ?? '').trim();
      if (raw.isEmpty) continue;
      if (raw.replaceAll(RegExp(r'[^0-9]'), '').length != 10) {
        errors[mk] = schoolTerm('${_importGridLabels[mk] ?? _importFields[mk] ?? mk} must be 10 digits');
      }
    }
    if (payMob != null && payMob.replaceAll(RegExp(r'[^0-9]'), '').length != 10) {
      errors['payinchargemob'] = 'Payment Mobile must be 10 digits';
    }
    // Class + course must exist in the master and (if both supplied) agree
    // with the class-course mapping. Skip if masters haven't loaded yet -
    // server enforces too.
    String norm(String s) => s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    final classRaw = (_importCellByKey(row, 'stuclass') ?? '').trim();
    final courseRaw = (_importCellByKey(row, 'courname') ?? '').trim();
    if (classRaw.isNotEmpty && _importClassNames.isNotEmpty) {
      final k = norm(classRaw);
      if (!_importClassNames.contains(k)) {
        errors['stuclass'] = '${schoolTerm('Class')} "$classRaw" not found in Master Data';
      } else if (courseRaw.isNotEmpty && _importCourseNames.isNotEmpty) {
        final ck = norm(courseRaw);
        if (!_importCourseNames.contains(ck)) {
          errors['courname'] = '${schoolTerm('Course')} "$courseRaw" not found in Master Data';
        } else {
          final expected = _importClassToCourse[k];
          if (expected != null && expected != ck) {
            errors['courname'] = '${schoolTerm('Class')} "$classRaw" belongs to ${schoolTerm('course')} "$expected", not the ${schoolTerm('course')} in this row';
          }
        }
      }
    }
    return errors;
  }

  /// Compose a row-level tooltip from the per-field errors.
  String _composeRowError(Map<String, String> fieldErrors) {
    final missing = <String>[];
    final detail = <String>[];
    fieldErrors.forEach((k, v) {
      if (v == 'Required') {
        missing.add(schoolTerm(_importGridLabels[k] ?? _importFields[k] ?? k));
      } else {
        detail.add(v);
      }
    });
    final parts = <String>[];
    if (missing.isNotEmpty) parts.add('Missing: ${missing.join(', ')}');
    parts.addAll(detail);
    return parts.join(' • ');
  }

  static String _friendlyError(String msg) {
    final m = msg.toLowerCase();
    if (m.contains('duplicate key') || m.contains('unique constraint')) {
      if (m.contains('stuadmno') || m.contains('admission')) return schoolTerm('Roll number already exists');
      if (m.contains('stuemail') || m.contains('email')) return 'Email already exists';
      if (m.contains('payinchargemob')) return 'Payment mobile already exists';
      return 'Duplicate record found';
    }
    if (m.contains('not-null') || m.contains('null value')) {
      final match = RegExp(r'column "(\w+)"').firstMatch(msg);
      final col = match?.group(1) ?? '';
      final labels = {'stuadmno': 'Roll No.', 'stuname': 'Name', 'stugender': 'Gender', 'studob': 'Date of Birth', 'stumobile': 'Mobile', 'stuclass': 'Class', 'payincharge': 'Payment In Charge', 'payinchargemob': 'Payment Mobile'};
      return schoolTerm('${labels[col] ?? col} is required');
    }
    if (m.contains('foreign key') || m.contains('fkey')) return schoolTerm('Invalid class, academic year or concession. Check these values in Master Data.');
    if (m.contains('check constraint')) {
      if (m.contains('gender')) return 'Gender must be M, F, or T';
      if (m.contains('email')) return 'Invalid email format';
      if (m.contains('activestatus')) return 'Invalid status value';
      return 'Invalid value format';
    }
    if (m.contains('value too long')) return 'Value too long for the field';
    if (m.contains('invalid input syntax')) return 'Invalid data format';
    if (m.contains('permission denied')) return 'Permission denied';
    return msg.length > 80 ? '${msg.substring(0, 80)}...' : msg;
  }

  void _validateImportData() {
    final cellErrors = <int, Map<String, String>>{};
    final rowErrors = <int, String>{};
    for (int i = 0; i < _importRows.length; i++) {
      final fields = _validateImportRow(i);
      if (fields.isNotEmpty) {
        cellErrors[i] = fields;
        rowErrors[i] = _composeRowError(fields);
      }
    }
    setState(() {
      _cellErrors = cellErrors;
      _rowErrors = rowErrors;
      _importValidated = rowErrors.isEmpty;
    });
    if (rowErrors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All rows are valid. Click Import to add the students.'), backgroundColor: AppColors.success),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${rowErrors.length} row(s) have errors (highlighted in red). Fix them in the file, or click Export with Errors.'), backgroundColor: AppColors.error),
      );
    }
  }

  Future<void> _startStudentImport() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;

    // Students can be imported independently of the fee master data (fee groups
    // / types / concessions / class fee demand) — no pre-import gate.
    final inscode = auth.inscode ?? '';
    final yrId = int.tryParse(_selectedYrId ?? '1') ?? 1;
    final yrLabel = _selectedYrLabel ?? '';

    setState(() {
      _importStep = 2;
      _importedCount = 0;
      _skippedCount = 0;
      _totalCount = _importRows.length;
      _importErrors = [];
    });

    // Pre-fetch class + course masters so each staging row gets the matching
    // cla_id and cour_id resolved from the canonical master tables.
    final classMasterRaw = await SupabaseService.fromSchema('class')
        .select('cla_id, claname')
        .eq('ins_id', insId)
        .eq('activestatus', 1);
    final courseMasterRaw = await SupabaseService.fromSchema('course')
        .select('cour_id, courname')
        .eq('ins_id', insId);
    String _normKey(String s) => s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    final claIdByName = <String, int>{};
    final claNameById = <int, String>{};
    for (final c in (classMasterRaw as List)) {
      final id = c['cla_id'] as int?;
      final name = (c['claname'] ?? '').toString().trim();
      if (id == null || name.isEmpty) continue;
      claIdByName.putIfAbsent(_normKey(name), () => id);
      claNameById[id] = name;
    }
    final courIdByName = <String, int>{};
    final courNameById = <int, String>{};
    for (final c in (courseMasterRaw as List)) {
      final id = c['cour_id'] as int?;
      final name = (c['courname'] ?? '').toString().trim();
      if (id == null || name.isEmpty) continue;
      courIdByName.putIfAbsent(_normKey(name), () => id);
      courNameById[id] = name;
    }

    // Admission type / concession / quota masters — used to resolve the import's
    // ID columns (Admission Type Id / Concession Id / Quota Id) to canonical
    // names. An ID (when present) wins over the corresponding name column.
    // A school has no admissiontype / quota tables -- skip those reads there.
    final admMasterRaw = isSchool ? <Map<String, dynamic>>[] : await SupabaseService.fromSchema('admissiontype').select('adm_id, admname').eq('ins_id', insId).eq('activestatus', 1);
    final conMasterRaw = await SupabaseService.fromSchema('concessioncategory').select('con_id, condesc').eq('ins_id', insId).eq('activestatus', 1);
    final quoMasterRaw = isSchool ? <Map<String, dynamic>>[] : await SupabaseService.fromSchema('quota').select('quo_id, quoname').eq('ins_id', insId).eq('activestatus', 1);
    final admNameById = <int, String>{ for (final r in (admMasterRaw as List)) if (r['adm_id'] != null) (r['adm_id'] as int): (r['admname'] ?? '').toString().trim() };
    final conNameById = <int, String>{ for (final r in (conMasterRaw as List)) if (r['con_id'] != null) (r['con_id'] as int): (r['condesc'] ?? '').toString().trim() };
    final quoNameById = <int, String>{ for (final r in (quoMasterRaw as List)) if (r['quo_id'] != null) (r['quo_id'] as int): (r['quoname'] ?? '').toString().trim() };
    // Reverse maps (name -> id) so we can also store adm_id / quo_id when only
    // the name is given (cla_id is resolved above; con_id is resolved server-side).
    final admIdByName = <String, int>{ for (final r in (admMasterRaw as List)) if (r['adm_id'] != null && (r['admname']?.toString() ?? '').isNotEmpty) _normKey(r['admname'].toString()): (r['adm_id'] as int) };
    final quoIdByName = <String, int>{ for (final r in (quoMasterRaw as List)) if (r['quo_id'] != null && (r['quoname']?.toString() ?? '').isNotEmpty) _normKey(r['quoname'].toString()): (r['quo_id'] as int) };

    // 1. Validate and build staging rows
    final stagingRows = <Map<String, dynamic>>[];
    for (int i = 0; i < _importRows.length; i++) {
      final fields = _validateImportRow(i);
      if (fields.isNotEmpty) {
        _skippedCount++;
        _importErrors.add('Row ${i + 2}: ${_composeRowError(fields)}');
        continue;
      }
      final row = _importRows[i];
      final dob = _parseDate(_importCellByKey(row, 'studob'));
      final admDate = _parseDate(_importCellByKey(row, 'stuadmdate'));
      // Resolve class/course names against the master. Excel may carry the
      // class as either a numeric id (e.g. "53") OR the name (e.g. "B.E ECE -II").
      // Always write the canonical claname/courname from the master back into
      // stuclass / courname so downstream JOINs and dashboards work.
      // Prefer the dedicated Class Id column; else the stuclass cell (id or name).
      final classIdCell = int.tryParse((_importCellByKey(row, 'class_id') ?? '').trim());
      final classRaw = (_importCellByKey(row, 'stuclass') ?? '').trim();
      int? claId;
      String claNameCanon = classRaw;
      if (classIdCell != null && claNameById.containsKey(classIdCell)) {
        claId = classIdCell;
        claNameCanon = claNameById[claId]!;
      } else {
        final classAsInt = int.tryParse(classRaw);
        if (classAsInt != null && claNameById.containsKey(classAsInt)) {
          claId = classAsInt;
          claNameCanon = claNameById[claId]!;
        } else {
          final byName = claIdByName[_normKey(classRaw)];
          if (byName != null) {
            claId = byName;
            claNameCanon = claNameById[claId] ?? classRaw;
          }
        }
      }

      // Prefer the Course Id column (fall back to Admitted Course Id), else name.
      final courseIdCell = int.tryParse((_importCellByKey(row, 'course_id') ?? _importCellByKey(row, 'admitted_course_id') ?? '').trim());
      final courseRaw = (_importCellByKey(row, 'courname') ?? '').trim();
      int? courId;
      String? courNameCanon = _nullIfEmpty(courseRaw);
      if (courseIdCell != null && courNameById.containsKey(courseIdCell)) {
        courId = courseIdCell;
        courNameCanon = courNameById[courId];
      } else {
        final courseAsInt = int.tryParse(courseRaw);
        if (courseAsInt != null && courNameById.containsKey(courseAsInt)) {
          courId = courseAsInt;
          courNameCanon = courNameById[courId];
        } else {
          final byName = courIdByName[_normKey(courseRaw)];
          if (byName != null) {
            courId = byName;
            courNameCanon = courNameById[courId];
          }
        }
      }
      // Admitted course (distinct from current course). Prefer the Admitted
      // Course Id column; fall back to the Course Id column, then to the
      // resolved current course id so it is never left null.
      final admitCourseIdCell = int.tryParse((_importCellByKey(row, 'admitted_course_id') ?? _importCellByKey(row, 'course_id') ?? '').trim());
      int? admitCourId;
      if (admitCourseIdCell != null && courNameById.containsKey(admitCourseIdCell)) {
        admitCourId = admitCourseIdCell;
      }
      admitCourId ??= courId;

      // Admission type / quota / concession resolved by id (id wins over name).
      final admIdCell = int.tryParse((_importCellByKey(row, 'admission_type_id') ?? '').trim());
      final admNameResolved = (admIdCell != null && admNameById.containsKey(admIdCell)) ? admNameById[admIdCell] : _nullIfEmpty(_importCellByKey(row, 'admname'));
      final quoIdCell = int.tryParse((_importCellByKey(row, 'quota_id') ?? '').trim());
      final quoNameResolved = (quoIdCell != null && quoNameById.containsKey(quoIdCell)) ? quoNameById[quoIdCell] : _nullIfEmpty(_importCellByKey(row, 'quoname'));
      final conIdCell = int.tryParse((_importCellByKey(row, 'concession_id') ?? '').trim());
      final conNameResolved = (conIdCell != null && conNameById.containsKey(conIdCell)) ? conNameById[conIdCell] : _nullIfEmpty(_importCellByKey(row, 'concession'));
      // Store adm_id / quo_id (id column wins; else look up from the resolved name).
      final admId = (admIdCell != null && admNameById.containsKey(admIdCell)) ? admIdCell : (admNameResolved != null ? admIdByName[_normKey(admNameResolved)] : null);
      final quoId = (quoIdCell != null && quoNameById.containsKey(quoIdCell)) ? quoIdCell : (quoNameResolved != null ? quoIdByName[_normKey(quoNameResolved)] : null);
      // Auto-fill Pay In Charge from a parent (name + mobile) when left blank.
      final payer = _deriveImportPayer(row);
      final payName = _nullIfEmpty(_importCellByKey(row, 'payincharge')) ?? payer[0];
      final payMob = _nullIfEmpty(_importCellByKey(row, 'payinchargemob')) ?? payer[1];
      stagingRows.add({
        'ins_id': insId,
        'inscode': inscode,
        'yr_id': yrId,
        'yrlabel': yrLabel,
        'stuadmno': _importCellByKey(row, 'stuadmno'),
        'stuname': _importCellByKey(row, 'stuname'),
        'stugender': _normalizeGender(_importCellByKey(row, 'stugender')),
        'studob': dob?.toIso8601String().split('T').first,
        'stuadmdate': (admDate ?? DateTime.now()).toIso8601String().split('T').first,
        'stuclass': claNameCanon,
        'cla_id': claId,
        'courname': courNameCanon,
        'cour_id': courId,
        'admit_cour_id': admitCourId,
        'stumobile': _digitsOnly(_importCellByKey(row, 'stumobile')),
        'stuemail': _validEmail(_importCellByKey(row, 'stuemail')),
        'concession': conNameResolved,
        'stuaddress': _nullIfEmpty(_importCellByKey(row, 'stuaddress')),
        'stucity': _nullIfEmpty(_importCellByKey(row, 'stucity')),
        'stustate': _nullIfEmpty(_importCellByKey(row, 'stustate')),
        'stucountry': _nullIfEmpty(_importCellByKey(row, 'stucountry')),
        // PIN column is varchar(6). Excel often emits it as "600123.0" or with
        // stray spaces; strip non-digits and cap at 6 so it can't overflow.
        'stupin': _truncate(_nullIfEmpty((_importCellByKey(row, 'stupin') ?? '').replaceAll(RegExp(r'[^0-9]'), '')), 6),
        'stubloodgrp': _nullIfEmpty(_importCellByKey(row, 'stubloodgrp')),
        'aadharno': _nullIfEmpty(_importCellByKey(row, 'aadharno')),
        'community': _nullIfEmpty(_importCellByKey(row, 'community')),
        'caste': _nullIfEmpty(_importCellByKey(row, 'caste')),
        'religion': _nullIfEmpty(_importCellByKey(row, 'religion')),
        'nationality': _nullIfEmpty(_importCellByKey(row, 'nationality')),
        'transportmode': _normalizeTransportMode(_importCellByKey(row, 'transportmode')),
        'hostel': _normalizeYesNo(_importCellByKey(row, 'hostel')),
        'division': _truncate(_nullIfEmpty(_importCellByKey(row, 'division')), 50),
        'fathername': _nullIfEmpty(_importCellByKey(row, 'fathername')),
        'fathermobile': _digitsOnly(_importCellByKey(row, 'fathermobile')),
        'fatheroccupation': _nullIfEmpty(_importCellByKey(row, 'fatheroccupation')),
        'mothername': _nullIfEmpty(_importCellByKey(row, 'mothername')),
        'mothermobile': _digitsOnly(_importCellByKey(row, 'mothermobile')),
        'motheroccupation': _nullIfEmpty(_importCellByKey(row, 'motheroccupation')),
        'guardianname': _nullIfEmpty(_importCellByKey(row, 'guardianname')),
        'guardianmobile': _digitsOnly(_importCellByKey(row, 'guardianmobile')),
        'guardianoccupation': _nullIfEmpty(_importCellByKey(row, 'guardianoccupation')),
        'paremail': _validEmail(_importCellByKey(row, 'paremail')),
        'payincharge': payName ?? '-',
        'payinchargemob': _digitsOnly(payMob),
        // student_import on a school has no admission type / quota / batch.
        if (!isSchool) 'admname': admNameResolved,
        if (!isSchool) 'adm_id': admId,
        if (!isSchool) 'quoname': quoNameResolved,
        if (!isSchool) 'quo_id': quoId,
        if (!isSchool) 'batch': _truncate(_nullIfEmpty(_importCellByKey(row, 'batch')), 9),
        'admittyear': _truncate(_nullIfEmpty(_importCellByKey(row, 'admittyear')), 9),
        'medium': _truncate(_nullIfEmpty(_importCellByKey(row, 'medium')), 30),
        'status': 'PENDING',
      });
    }

    if (stagingRows.isEmpty) {
      setState(() => _importStep = 3);
      return;
    }

    setState(() {});

    try {
      // 2. Bulk insert into staging table (batches of 200)
      for (int i = 0; i < stagingRows.length; i += 200) {
        final batch = stagingRows.sublist(i, (i + 200).clamp(0, stagingRows.length));
        await SupabaseService.fromSchema('student_import').insert(batch);
        setState(() {
          _importedCount = i + batch.length;
        });
      }

      // 3. Call DB function to move data to original tables
      setState(() {
        _importedCount = 0;
      });
      final result = await SupabaseService.client.rpc('process_student_import', params: {'p_ins_id': insId});
      SupabaseService.invalidateStudentsCache(insId); // imported rows → drop stale cache

      if (result is List && result.isNotEmpty) {
        final r = result.first;
        _importedCount = (r['imported'] as num?)?.toInt() ?? 0;
        _skippedCount += (r['skipped'] as num?)?.toInt() ?? 0;
      }

      // 4. Fetch errors from staging table (best-effort — a blocked read must
      // not turn a SUCCESSFUL import into a scary generic error).
      try {
        final errors = await SupabaseService.fromSchema('student_import')
            .select('imp_id, stuadmno, error_msg, status')
            .eq('ins_id', insId)
            .inFilter('status', ['ERROR', 'NO_PARENT']);
        for (final e in errors) {
          final status = e['status'];
          final admNo = e['stuadmno'] ?? '';
          if (status == 'NO_PARENT') {
            _importErrors.add('${schoolTerm('Roll No.')} $admNo: Payment In Charge name or mobile is missing, so the student was not added.');
          } else {
            _importErrors.add('${schoolTerm('Roll No.')} $admNo: ${_friendlyError(e['error_msg']?.toString() ?? 'Unknown error')}');
          }
        }
      } catch (e) {
        debugPrint('Fetch student_import errors failed: $e');
      }

      // 5. Clean up processed staging rows via a SECURITY DEFINER RPC — the
      // direct client DELETE is revoked under the write lockdown, so it runs
      // server-side. Best-effort: silently no-ops if the RPC isn't deployed yet.
      try {
        await SupabaseService.client.rpc('cleanup_student_import', params: {'p_ins_id': insId});
      } catch (e) {
        debugPrint('cleanup_student_import failed: $e');
      }
    } catch (e) {
      // Only a genuinely fatal error (e.g. process_student_import itself failed)
      // reaches here; those leave _importedCount at 0. Show the raw cause so it
      // isn't masked by the generic "Something went wrong".
      _importErrors.add('Import failed. ${friendlyError(e)}');
    }

    setState(() => _importStep = 3);
    _loadDropdowns();
  }

  // â”€â”€â”€ Import UI â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildStudentImportSection() {
    if (_importStep == 2) return _buildImportProgressStep();
    if (_importStep == 3) return _buildImportDoneStep();

    return Container(
      padding: EdgeInsets.all(16.w),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title bar
          Row(
            children: [
              InkWell(
                onTap: _resetImport,
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                child: Builder(builder: (context) {
                  final compact = AppUI.compact(context);
                  final hPad = compact ? 14.0 : 18.0;
                  const radius = AppUI.controlRadius;
                  final textSize = compact ? 13.0 : 14.0;
                  final innerGap = AppBtn.gap(context);
                  return Container(
                    height: AppBtn.height(context),
                    padding: EdgeInsets.symmetric(horizontal: hPad),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(radius),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon.linear('Chevron Left', size: AppBtn.iconSize(context), color: Colors.white),
                        SizedBox(width: innerGap),
                        Text('Back', style: TextStyle(fontSize: textSize, fontWeight: FontWeight.w700, color: Colors.white)),
                      ],
                    ),
                  );
                }),
              ),
              SizedBox(width: 12.w),
              AppIcon('document-upload', size: 20, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('Import Students', style: AppUI.cardTitle),
              const Spacer(),
              if (_importFileName != null)
                Text(_importFileName!, style: AppUI.muted),
              SizedBox(width: 12.w),
              ElevatedButton.icon(
                onPressed: _pickImportFile,
                icon: AppIcon('document-upload', size: 16),
                label: const Text(AppText.chooseFile),
              ),
              SizedBox(width: 8.w),
              Builder(builder: (_) {
                // After Validate, if there are cell-level errors the button
                // exports the loaded rows with an annotated "Error" column so
                // the user can fix issues offline and re-import. Otherwise it
                // still downloads the blank template.
                final hasErrors = _importRows.isNotEmpty && _cellErrors.isNotEmpty;
                return ElevatedButton.icon(
                  onPressed: hasErrors ? _exportImportRowsWithErrors : _exportStudentTemplate,
                  icon: AppIcon(hasErrors ? 'document-download' : 'grid-1', size: 16),
                  label: Text(hasErrors ? 'Export with Errors' : AppText.downloadTemplate),
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.success),
                );
              }),
              SizedBox(width: 8.w),
              ElevatedButton.icon(
                onPressed: _exportSampleData,
                icon: AppIcon('document-download', size: 16),
                label: const Text(AppText.downloadSample),
              ),
            ],
          ),
          if (_importErrorMsg != null) ...[
            SizedBox(height: 8.h),
            Text(_importErrorMsg!, style: TextStyle(color: AppColors.error, fontSize: 13.sp)),
          ],
          SizedBox(height: 12.h),

          // Data grid
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: AppColors.cardBorder),
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
              ),
              clipBehavior: Clip.hardEdge,
              child: LayoutBuilder(builder: (ctx, constraints) {
                final viewportW = constraints.maxWidth;
                final sNoW = 50.w;
                final gridKeys = _gridKeys;
                final dividers = (gridKeys.length + 1) * 1.0;
                final dataColsRaw = gridKeys.fold<double>(0, (sum, k) => sum + _gridColWidth(k));
                final totalRaw = sNoW + dataColsRaw + dividers;
                // If natural width fits the viewport, scale data columns up to fill it
                // (keeps S.No fixed). Otherwise keep widths and let the user scroll.
                final scale = totalRaw < viewportW ? (viewportW - sNoW - dividers) / dataColsRaw : 1.0;
                double colW(String key) => _gridColWidth(key) * scale;
                final tableW = totalRaw < viewportW ? viewportW : totalRaw;
                final needsScroll = tableW > viewportW;
                return Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _importScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: needsScroll ? null : const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: needsScroll ? tableW : viewportW,
                          child: Column(
                            children: [
                              // Header row
                              Container(
                                decoration: AppUI.tableHeadBar,
                                child: Row(
                                  children: [
                                    _gridHeaderCell('S.No', width: sNoW, center: true),
                                    _gridHeaderDivider(),
                                    for (final key in gridKeys) ...[
                                      _gridHeaderCell(schoolTerm(_importGridLabels[key] ?? key), width: colW(key)),
                                      _gridHeaderDivider(),
                                    ],
                                  ],
                                ),
                              ),
                              // Data rows
                              Expanded(
                                child: _importRows.isEmpty
                                    ? AppUI.empty(
                                        icon: 'element-4',
                                        title: 'No data loaded',
                                        why: 'Click Choose File to load a CSV or Excel file.',
                                      )
                                    : ListView.builder(
                                        itemCount: _importRows.length,
                                        itemBuilder: (context, index) {
                                          final row = _importRows[index];
                                          final isEven = index % 2 == 0;
                                          final cellErrs = _cellErrors[index] ?? const <String, String>{};
                                          final hasError = cellErrs.isNotEmpty;
                                          return Container(
                                            color: isEven ? Colors.white : AppColors.surface,
                                            padding: EdgeInsets.symmetric(vertical: 6.h),
                                            child: Row(
                                              children: [
                                                _gridDataCell('${index + 1}', width: sNoW, center: true),
                                                for (final key in gridKeys)
                                                  cellErrs.containsKey(key)
                                                      ? Tooltip(
                                                          message: cellErrs[key]!,
                                                          child: Container(
                                                            color: AppColors.errorBg,
                                                            child: _gridDataCell(_importMappedCell(row, key), width: colW(key)),
                                                          ),
                                                        )
                                                      : _gridDataCell(_importMappedCell(row, key), width: colW(key)),
                                                if (hasError)
                                                  Padding(
                                                    padding: EdgeInsets.only(right: 8.w),
                                                    child: Tooltip(
                                                      message: _rowErrors[index] ?? '',
                                                      child: AppIcon.linear('info-circle', color: AppColors.error, size: 16),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (needsScroll)
                      ClassicHScrollbar(
                        controller: _importScrollController,
                        contentWidth: tableW,
                        viewportWidth: viewportW,
                      ),
                  ],
                );
              }),
            ),
          ),

          SizedBox(height: 12.h),

          // Bottom bar
          Row(
            children: [
              Text(
                '${_importRows.length} rows',
                style: AppUI.cell,
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _importRows.isEmpty || _importValidated ? null : _validateImportData,
                icon: AppIcon(_importValidated ? 'tick-circle' : 'tick-circle', size: 16),
                label: Text(_importValidated ? 'Validated' : 'Validate'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _importRows.isNotEmpty && !_importValidated ? AppColors.warning : (_importValidated ? AppColors.success : AppColors.textLight),
                ),
              ),
              SizedBox(width: 8.w),
              ElevatedButton.icon(
                onPressed: _importValidated ? _startStudentImport : null,
                icon: AppIcon('save-2', size: 16),
                label: const Text(AppText.import),
              ),
              SizedBox(width: 8.w),
              OutlinedButton(
                onPressed: _resetImport,
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImportProgressStep() {
    final progress = _totalCount > 0 ? (_importedCount + _skippedCount) / _totalCount : 0.0;
    return Center(
      child: Container(
        width: 400.w,
        padding: EdgeInsets.all(32.w),
        decoration: AppUI.card(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            SizedBox(height: 20.h),
            Text('Importing... ${_importedCount + _skippedCount} / $_totalCount', style: AppUI.label),
            SizedBox(height: 12.h),
            LinearProgressIndicator(value: progress, backgroundColor: AppColors.divider, valueColor: const AlwaysStoppedAnimation(AppColors.primary)),
            SizedBox(height: 8.h),
            Text('$_importedCount imported, $_skippedCount skipped', style: AppUI.muted),
          ],
        ),
      ),
    );
  }

  Widget _buildImportDoneStep() {
    return Center(
      child: Container(
        width: 500.w,
        padding: EdgeInsets.all(32.w),
        decoration: AppUI.card(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon('tick-circle', size: 64.sp, color: AppColors.success),
            SizedBox(height: 16.h),
            Text('Import Complete', style: AppUI.cardTitle),
            SizedBox(height: 12.h),
            Text('$_importedCount imported successfully, $_skippedCount skipped', style: AppUI.body),
            if (_importErrors.isNotEmpty) ...[
              SizedBox(height: 16.h),
              Container(
                height: 150.h,
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  color: AppColors.errorBg,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                ),
                child: ListView(
                  children: _importErrors.map((e) => Padding(
                    padding: EdgeInsets.only(bottom: 4.h),
                    child: Text(e, style: TextStyle(fontSize: 13.sp, color: AppColors.error)),
                  )).toList(),
                ),
              ),
            ],
            SizedBox(height: 20.h),
            ElevatedButton(
              onPressed: _resetImport,
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  /// Column width = the fixed width below, or the header's own width when the
  /// label is longer (school wording such as "ADMITTED STANDARD ID" is longer
  /// than the college label the fixed width was sized for), so a header never
  /// runs into the next column.
  double _gridColWidth(String key) {
    final label = schoolTerm(_importGridLabels[key] ?? key).toUpperCase();
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: AppUI.tableHead),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final headerW = tp.width + 20.w + 8; // cell padding (10.w each side) + slack
    final base = _gridColBaseWidth(key);
    return headerW > base ? headerW : base;
  }

  double _gridColBaseWidth(String key) {
    // Widths sized to fit header text on a single line at 13.sp / w700
    // (e.g., "GUARDIAN MOBILE" needs ~150px; "CONCESSION *" needs ~140px).
    switch (key) {
      case 'stuadmno': return 110;          // ROLL NO *
      case 'stuname': return 170;           // NAME *
      case 'stugender': return 110;         // GENDER *
      case 'studob': return 100;            // DOB *
      case 'stuadmdate': return 120;        // ADM DATE
      case 'stuclass': return 100;          // CLASS *
      case 'courname': return 110;          // COURSE
      case 'stumobile': return 120;         // MOBILE
      case 'stuemail': return 170;          // EMAIL
      case 'concession': return 150;        // CONCESSION *
      case 'stuaddress': return 170;        // ADDRESS
      case 'stucity': return 100;           // CITY
      case 'stustate': return 100;          // STATE
      case 'stucountry': return 110;        // COUNTRY
      case 'stupin': return 110;            // PIN CODE
      case 'stubloodgrp': return 130;       // BLOOD GROUP
      case 'aadharno': return 140;          // AADHAR NO
      case 'community': return 130;         // COMMUNITY
      case 'division': return 120;          // DIVISION
      case 'caste': return 110;             // CASTE
      case 'religion': return 120;          // RELIGION
      case 'nationality': return 130;       // NATIONALITY
      case 'transportmode': return 150;     // TRANSPORT MODE
      case 'hostel': return 120;            // HOSTEL (Y/N)
      case 'fathername': case 'mothername': return 150;
      case 'guardianname': return 160;      // GUARDIAN NAME
      case 'fathermobile': case 'mothermobile': return 150;
      case 'guardianmobile': return 170;    // GUARDIAN MOBILE
      case 'fatheroccupation': case 'motheroccupation': case 'guardianoccupation': return 150;
      case 'paremail': return 170;          // PARENT EMAIL
      case 'payincharge': return 160;       // PAY IN CHARGE *
      case 'payinchargemob': return 140;    // PAY MOBILE *
      case 'admname': return 160;           // ADMISSION TYPE
      case 'quoname': return 110;           // QUOTA
      case 'batch': return 110;             // BATCH
      case 'admittyear': return 140;        // ADMITTED YEAR
      case 'medium': return 120;            // MEDIUM
      case 'admitted_course_id': return 150;
      case 'course_id': return 120;
      case 'class_id': return 110;
      case 'admission_type_id': return 160;
      case 'concession_id': return 140;
      case 'quota_id': return 110;
      default: return 120;
    }
  }

  Widget _gridHeaderCell(String text, {double? width, int flex = 1, bool center = false}) {
    final child = Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 12.h),
      alignment: center ? Alignment.center : Alignment.centerLeft,
      child: Text(
        text.toUpperCase(),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: AppUI.tableHead,
      ),
    );
    return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
  }

  Widget _gridHeaderDivider() {
    return Container(width: 1, height: 36.h, color: AppColors.divider);
  }

  Widget _gridDataCell(String text, {double? width, int flex = 1, bool center = false}) {
    final child = Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 10.h),
      alignment: center ? Alignment.center : Alignment.centerLeft,
      decoration: BoxDecoration(
        border: const Border(right: BorderSide(color: AppColors.divider)),
      ),
      child: Text(text, style: AppUI.cell, overflow: TextOverflow.ellipsis),
    );
    return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
  }

  // â”€â”€â”€ Helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Card panel with a labelled header
  Widget _panel({required String title, required String icon, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppUI.cardHeader(icon: icon, title: title),
          SizedBox(height: 12.h),
          const Divider(color: AppColors.divider),
          SizedBox(height: 12.h),
          child,
        ],
      ),
    );
  }

  /// Two fields side by side
  Widget _row2(Widget left, Widget right) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        SizedBox(width: 14.w),
        Expanded(child: right),
      ],
    );
  }

  /// Three fields side by side
  Widget _row3(Widget a, Widget b, Widget c) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: a),
        SizedBox(width: 14.w),
        Expanded(child: b),
        SizedBox(width: 14.w),
        Expanded(child: c),
      ],
    );
  }

  /// Four fields side by side
  Widget _row4(Widget a, Widget b, Widget c, Widget d) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: a),
        SizedBox(width: 14.w),
        Expanded(child: b),
        SizedBox(width: 14.w),
        Expanded(child: c),
        SizedBox(width: 14.w),
        Expanded(child: d),
      ],
    );
  }

  /// Field with label that expands to fill available width
  Widget _fieldFull({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label.endsWith(' *')
            ? AppUI.fieldLabel(label.substring(0, label.length - 2), required: true)
            : AppUI.fieldLabel(label),
        child,
      ],
    );
  }

  // [filled] = the field has a value (accent edge); empty fields stay grey.
  InputDecoration _dec(String hint, {bool filled = false}) {
    return AppUI.field(context, hint, filled: filled);
  }
}

// _ExcelImportDialog removed - import is now inline grid in _StudentsScreenState
