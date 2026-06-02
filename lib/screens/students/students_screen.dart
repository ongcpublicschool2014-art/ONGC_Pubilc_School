import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:excel/excel.dart' as xl;
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions, PostgrestException;
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../models/student_model.dart';
import '../../utils/friendly_error.dart';

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
  String? _photoUrl;
  String? _insName;
  String? _insLogo;

  // Parent Info
  String _selectedParentTab = 'Father';
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
  List<StudentModel> _students = [];
  Map<String, int> _classCounts = {};
  // Master-table ordering: claname -> ordid, clagrpname -> ordid.
  // Used by _buildClassList to honour the institution's preferred sort.
  Map<String, int> _classOrdMap = {};
  Map<String, int> _courseOrdMap = {};
  Map<String, List<StudentModel>> _cachedClassStudents = {};
  bool _loadingClassStudents = false;
  StudentModel? _selectedStudent;
  String? _selectedClassFilter; // null = show class list, non-null = show students of that class
  String? _selectedCourseFilter; // tracks which course the selected class belongs to
  // Single-open accordion state for the course list — opening one course
  // auto-collapses any previously open course.
  String? _expandedCourse;
  final Map<String, ExpansibleController> _courseExpansionCtrls = {};
  final _searchController = TextEditingController();
  final _globalSearchController = TextEditingController();
  List<StudentModel> _globalSearchResults = [];
  bool _isGlobalSearching = false;
  // Import state
  bool _showImport = false;
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
  // reject rows whose class/course doesn't exist or whose class→course
  // mapping disagrees with the master.
  Set<String> _importClassNames = {};         // normalized claname
  Set<String> _importCourseNames = {};        // normalized clagrpname
  Map<String, String?> _importClassToCourse = {}; // normalized claname → normalized course name (from class.cgrp_id)

  static const _importGridKeys = [
    'stuadmno', 'stuname', 'stugender', 'studob', 'stuadmdate', 'clagrpname', 'stuclass',
    'stumobile', 'stuemail', 'concession',
    'stuaddress', 'stucity', 'stustate', 'stucountry',
    'stupin', 'stubloodgrp',
    'fathername', 'fathermobile', 'fatheroccupation',
    'mothername', 'mothermobile', 'motheroccupation',
    'guardianname', 'guardianmobile', 'guardianoccupation',
    'payincharge', 'payinchargemob',
    'admittyear',
  ];

  static const Map<String, String> _importGridLabels = {
    'stuadmno': 'Roll No *',
    'stuname': 'Name *',
    'stugender': 'Gender *',
    'studob': 'DOB *',
    'stuadmdate': 'Adm Date',
    'stuclass': 'Class *',
    'clagrpname': 'Standard',
    'stumobile': 'Mobile',
    'stuemail': 'Email',
    'concession': 'Concession *',
    'admittyear': 'Admitted Year',
    'stuaddress': 'Address',
    'stucity': 'City',
    'stustate': 'State',
    'stucountry': 'Country',
    'stupin': 'Pin Code',
    'stubloodgrp': 'Blood Group',
    'fathername': 'Father Name',
    'fathermobile': 'Father Mobile',
    'fatheroccupation': 'Father Occ.',
    'mothername': 'Mother Name',
    'mothermobile': 'Mother Mobile',
    'motheroccupation': 'Mother Occ.',
    'guardianname': 'Guardian Name',
    'guardianmobile': 'Guardian Mobile',
    'guardianoccupation': 'Guardian Occ.',
    'payincharge': 'Pay In Charge *',
    'payinchargemob': 'Pay Mobile *',
  };

  final ScrollController _importScrollController = ScrollController();

  static const _importRequiredFields = {'stuadmno', 'stuname', 'stugender', 'stuclass', 'payincharge', 'payinchargemob'};

  static final TextStyle _inputStyle = TextStyle(fontWeight: FontWeight.w500, fontSize: 13.sp, color: const Color(0xFF555555));

  final List<String> _bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
  final List<String> _genders = ['Male', 'Female', 'Other'];
  static const List<String> _classOrder = [
    'PKG', 'LKG', 'UKG', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII',
  ];

  static const List<Color> _classColors = [
    Color(0xFF6366F1), // PKG - Indigo
    Color(0xFF8B5CF6), // LKG - Violet
    Color(0xFFA855F7), // UKG - Purple
    Color(0xFFEC4899), // I - Pink
    Color(0xFFF43F5E), // II - Rose
    Color(0xFFEF4444), // III - Red
    Color(0xFFF97316), // IV - Orange
    Color(0xFFF59E0B), // V - Amber
    Color(0xFF22C55E), // VI - Green
    Color(0xFF6C8EEF), // VII - Teal
    Color(0xFF06B6D4), // VIII - Cyan
    Color(0xFF6C8EEF), // IX - Blue
    Color(0xFF2563EB), // X - Blue dark
    Color(0xFF7C3AED), // XI - Violet dark
    Color(0xFF9333EA), // XII - Purple dark
  ];

  Color _getClassColor(String className) {
    final index = _classOrder.indexOf(className);
    if (index >= 0 && index < _classColors.length) return _classColors[index];
    return AppColors.accent;
  }

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

    // Stage 1: parallel — includes class counts so list shows immediately with correct counts
    final results = await Future.wait<dynamic>([
      SupabaseService.getYears(insId),
      SupabaseService.getConcessions(insId),
      SupabaseService.getClasses(insId),
      SupabaseService.getInstitutionInfo(insId),
      SupabaseService.getStudentCountsByClass(insId),
      // class + course masters with ordid for the sidebar ordering.
      SupabaseService.fromSchema('class').select('claname, ordid').eq('ins_id', insId).eq('activestatus', 1),
      SupabaseService.fromSchema('clagrp').select('clagrpname, ordid').eq('ins_id', insId).eq('activestatus', 1),
    ]);

    if (!mounted) return;
    final years = results[0] as List<Map<String, dynamic>>;
    final concessions = results[1] as List<Map<String, dynamic>>;
    final rawClasses = (results[2] as List<String>).toSet().toList();
    final insInfo = results[3] as ({String? name, String? logo, String? address, String? mobile, String? email});
    final classCounts = results[4] as Map<String, int>;
    final classMaster = results[5] as List<dynamic>;
    final courseMaster = results[6] as List<dynamic>;
    final classOrdMap = <String, int>{
      for (final r in classMaster)
        if (r['claname'] != null && r['ordid'] != null)
          r['claname'].toString().trim(): (r['ordid'] as num).toInt(),
    };
    final courseOrdMap = <String, int>{
      for (final r in courseMaster)
        if (r['clagrpname'] != null && r['ordid'] != null)
          r['clagrpname'].toString().trim(): (r['ordid'] as num).toInt(),
    };
    // Dedupe rawClasses while preserving first-seen order — the class table
    // sometimes has multiple rows with the same claname (different cgrp_id),
    // which would otherwise crash DropdownButton with duplicate values.
    final seen = <String>{};
    final dedupedRaw = <String>[];
    for (final c in rawClasses) {
      if (c.isNotEmpty && seen.add(c)) dedupedRaw.add(c);
    }
    final ordered = _classOrder.where((c) => dedupedRaw.contains(c)).toList();
    final extra = dedupedRaw.where((c) => !_classOrder.contains(c)).toList();

    final allClasses = [...ordered, ...extra];
    setState(() {
      _years = years;
      _concessions = concessions;
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
      // Don't auto-select — show all students by default
    });

    // Stage 2: background — load all students for search/export
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
    // Map DB variants like "B+VE", "B-VE", "O+VE" → canonical dropdown values
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
    setState(() {
      _selectedGender = null;
      _selectedBloodGroup = null;
      _selectedClass = null;
      _selectedConId = null;
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

    // Fetch parent data
    final parent = await SupabaseService.getStudentParent(s.stuId);
    if (!mounted) return;

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
      _selectedGender = s.gender;
      _selectedBloodGroup = _normalizeBloodGroup(s.stubloodgrp);
      _selectedClass = s.stuclass.trim();
      _selectedConId = s.conId?.toString();
      _admDate = s.stuadmdate;
      _dob = s.studob;
      _photoUrl = s.stuphoto;
      _isFormEnabled = false; // view mode — buttons disabled
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
    setState(() {
      _selectedGender = null;
      _selectedBloodGroup = null;
      _selectedClass = null;
      _selectedConId = null;
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

  Future<void> _saveNewStudent() async {
    if (_admNoController.text.trim().isEmpty ||
        _nameController.text.trim().isEmpty ||
        _selectedClass == null ||
        _mobileController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all required fields (Roll No, Name, Class, Mobile)'), backgroundColor: AppColors.error),
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
          SnackBar(content: Text('Error saving student. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
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
  // (student-photos-kcet, student-photos-kcsam, …) so quotas / deletion
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
          SnackBar(content: Text('Photo upload failed. ${friendlyError(e)}'), backgroundColor: Colors.red),
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
    // file inside and uploads them — much faster than Ctrl+A in the file
    // picker when a school has hundreds of photos.
    final folderPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder of photos named by Roll No (e.g. 6522.jpg)',
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
          SnackBar(content: Text('Could not read folder. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (imageFiles.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No image files found in that folder'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.inscode ?? 'ins';
    if (insId == null) return;

    // Build a Roll No → stu_id lookup from the already-loaded students list.
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
        await SupabaseService.fromSchema('students')
            .update({'stuphoto': url})
            .eq('stu_id', stuId)
            .eq('ins_id', insId);
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
      final refreshed = await SupabaseService.getStudents(insId);
      if (mounted) setState(() => _students = refreshed);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Photo import complete'),
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
                    Text('Unmatched (${unmatched.length}) — no student with this Roll No:',
                        style: TextStyle(color: AppColors.warning, fontWeight: FontWeight.w700, fontSize: 13.sp)),
                    for (final n in unmatched.take(20))
                      Padding(padding: EdgeInsets.only(left: 8.w, top: 2.h), child: Text('• $n', style: TextStyle(fontSize: 12.sp))),
                    if (unmatched.length > 20)
                      Padding(padding: EdgeInsets.only(left: 8.w, top: 2.h), child: Text('… and ${unmatched.length - 20} more', style: TextStyle(fontSize: 12.sp, fontStyle: FontStyle.italic))),
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
    // Sort by course ordid → class ordid → name so the main list mirrors the
    // sidebar grouping (which is also driven by the same master ordids).
    int courseOrd(StudentModel s) =>
        _courseOrdMap[(s.clagrpname ?? '').trim()] ?? 1 << 30;
    int classOrd(StudentModel s) =>
        _classOrdMap[s.stuclass.trim()] ?? 1 << 30;
    filtered.sort((a, b) {
      final ca = courseOrd(a);
      final cb = courseOrd(b);
      if (ca != cb) return ca.compareTo(cb);
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

  // ─── Left Panel Builders ─────────────────────────────────────────────────────

  // Group classes by course with correct counts
  Map<String, Map<String, int>> _getCoursewiseClassCounts() {
    final courseMap = <String, Map<String, int>>{};
    for (final s in _students) {
      final course = s.clagrpname ?? 'Other';
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
          children: (classCounts.keys.toList()
                ..sort((a, b) {
                  // Sort classes within a course by master-table ordid;
                  // unknown classes fall to the end alphabetically.
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
            return Material(
              color: Colors.transparent,
              child: InkWell(
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
                  padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 11.h),
                  decoration: BoxDecoration(
                    color: isSelected ? classColor.withValues(alpha: 0.08) : null,
                    border: const Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 34.w, height: 34.h,
                        decoration: BoxDecoration(
                          color: classColor.withValues(alpha: isSelected ? 0.2 : 0.1),
                          borderRadius: BorderRadius.circular(9.r),
                        ),
                        child: Center(child: AppIcon('book-1', size: 16, color: classColor)),
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
      allStudents = allStudents.where((s) => (s.clagrpname ?? 'Other') == _selectedCourseFilter).toList();
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
              Text('Class $className', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: classColor)),
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
              ? Center(child: Text('No students found', style: TextStyle(color: AppColors.textSecondary, fontSize: 13.sp)))
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
    final compact = MediaQuery.of(context).size.width <= 1366;
    final btnHeight = compact ? 30.0 : 40.0;
    final iconSize = compact ? 12.0 : 16.0;
    final hPad = compact ? 10.0 : 18.0;
    final radius = compact ? 6.0 : 10.0;
    final textSize = compact ? 11.0 : 13.0;
    final gap = compact ? 6.0 : 10.0;

    Widget importPhotos = SizedBox(
      height: btnHeight,
      child: ElevatedButton.icon(
        onPressed: _isImportingPhotos ? null : _bulkImportPhotos,
        icon: _isImportingPhotos
            ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(Icons.photo_library, size: iconSize),
        label: Text(_isImportingPhotos
            ? 'Uploading ${_photoUploadDone}/$_photoUploadTotal…'
            : 'Import Photos'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(horizontal: hPad),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          textStyle: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600),
          elevation: 0,
        ),
      ),
    );

    Widget importCsv = SizedBox(
      height: btnHeight,
      child: ElevatedButton.icon(
        onPressed: () => setState(() {
          _showImport = !_showImport;
          if (!_showImport) _resetImport();
        }),
        icon: AppIcon(_showImport ? 'close-circle' : 'document-upload', size: iconSize),
        label: Text(_showImport ? 'Close Import' : 'Import CSV/Excel'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _showImport ? AppColors.error : AppColors.accent,
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(horizontal: hPad),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          textStyle: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600),
          elevation: 0,
        ),
      ),
    );

    return [
      SizedBox(width: gap),
      importPhotos,
      SizedBox(width: gap),
      importCsv,
    ];
  }

  Widget _buildAllStudentsTable() {
    final q = _searchController.text.toLowerCase();
    final allStudents = q.isEmpty
        ? _students
        : _students.where((s) => s.stuname.toLowerCase().contains(q) || s.stuadmno.toLowerCase().contains(q) || (s.clagrpname ?? '').toLowerCase().contains(q)).toList();
    final totalStudents = allStudents.length;

    final cellStyle = TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary);

    return Column(
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(16.w, 10.h, 16.w, 0),
          child: Row(
            children: [
              AppIcon('people', size: 18, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('All Students', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700)),
              SizedBox(width: 8.w),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10.r)),
                child: Text('$totalStudents students', style: TextStyle(fontSize: 12.sp, color: AppColors.primary, fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              AppSearchField(
                controller: _searchController,
                hintText: 'Search...',
                onChanged: (_) => setState(() {}),
                width: 240.w,
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
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(color: AppColors.border),
              ),
              child: AppVerticalScrollbar(
                header: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    color: AppColors.tableHeadBg,
                    child: Row(
                      children: [
                        Expanded(flex: 1, child: Text('S NO.', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('ROLL NO', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 3, child: Text('STUDENT NAME', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('STANDARD', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('CLASS', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 2, child: Text('MOBILE NO', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                        Expanded(flex: 1, child: Text('ACTION', textAlign: TextAlign.right, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                      ],
                    ),
                  ),
                  Container(height: 1, color: AppColors.border),
                  ],
                ),
                builder: (context, controller) => ListView.separated(
                      controller: controller,
                      itemCount: allStudents.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border),
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
                                Expanded(flex: 2, child: Text(s.clagrpname ?? '-', style: cellStyle)),
                                Expanded(flex: 2, child: Text(s.stuclass, style: cellStyle)),
                                Expanded(flex: 2, child: Text(s.stumobile.isEmpty ? '-' : s.stumobile, style: cellStyle)),
                                Expanded(flex: 1, child: Align(alignment: Alignment.centerRight, child: AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary))),
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
      allStudents = allStudents.where((s) => (s.clagrpname ?? 'Other') == _selectedCourseFilter).toList();
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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Ledger-style class header: icon + class name (colored) + count
          // pill + search field. No back/breadcrumb/export — class switching
          // happens via the sidebar.
          Container(
            padding: EdgeInsets.fromLTRB(12.w, 10.h, 16.w, 10.h),
            decoration: BoxDecoration(
              color: classColor.withValues(alpha: 0.06),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(12.r),
                topRight: Radius.circular(12.r),
              ),
              border: const Border(bottom: BorderSide(color: AppColors.border)),
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
                padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                color: AppColors.tableHeadBg,
                child: Row(
                  children: [
                    Expanded(flex: 1, child: Text('S NO.', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                    Expanded(flex: 2, child: Text('ROLL NO', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                    Expanded(flex: 3, child: Text('STUDENT NAME', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                    Expanded(flex: 2, child: Text('STANDARD', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                    Expanded(flex: 1, child: Text('GENDER', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                    Expanded(flex: 2, child: Text('MOBILE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                    Expanded(flex: 1, child: Text('ACTION', textAlign: TextAlign.right, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                  ],
                ),
              ),
              builder: (context, controller) => filteredStudents.isEmpty
                ? Center(child: Text('No students found', style: TextStyle(color: AppColors.textSecondary, fontSize: 13.sp)))
                : ListView.separated(
                    controller: controller,
                    padding: EdgeInsets.zero,
                    itemCount: filteredStudents.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border.withValues(alpha: 0.4)),
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
                              Expanded(flex: 1, child: Text('${index + 1}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                              Expanded(flex: 2, child: Text(s.stuadmno, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent))),
                              Expanded(flex: 3, child: Text(s.stuname, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis)),
                              Expanded(flex: 2, child: Text(s.clagrpname ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                              Expanded(flex: 1, child: Text(s.stugender, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                              Expanded(flex: 2, child: Text(s.stumobile, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                              Expanded(flex: 1, child: Align(alignment: Alignment.centerRight, child: AppIcon.linear('Chevron Right', size: 16, color: AppColors.accent))),
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

  // ─── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [

        // Global search results
        if (_globalSearchController.text.isNotEmpty) ...[
          Container(
            constraints: BoxConstraints(maxHeight: 300.h),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10.r),
              border: Border.all(color: AppColors.border),
            ),
            child: _isGlobalSearching
                ? const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
                : _globalSearchResults.isEmpty
                    ? Padding(
                        padding: EdgeInsets.all(16.w),
                        child: Center(child: Text('No students found', style: TextStyle(color: AppColors.textSecondary, fontSize: 13.sp))),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _globalSearchResults.length,
                        separatorBuilder: (_, __) => Divider(height: 1, color: AppColors.border),
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
                            subtitle: Text('Adm No: ${s.stuadmno} | Mobile: ${s.stumobile} | Class: ${s.stuclass}', style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary)),
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
                // LEFT — Student List
                SizedBox(
                  width: 260.w,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12.r),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  // Header
                  Container(
                    padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 10.h),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            AppIcon('people', color: AppColors.accent, size: 20),
                            SizedBox(width: 8.w),
                            Expanded(
                              child: Text('Students', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                            ),
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10.r),
                              ),
                              child: Text('${_students.isNotEmpty ? _students.length : _classCounts.values.fold(0, (s, c) => s + c)}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.accent)),
                            ),
                          ],
                        ),
                        SizedBox(height: 0.h),
                      ],
                    ),
                  ),
                  Divider(height: 1.h, color: AppColors.border),
                  // Class list (always visible)
                  Expanded(
                    child: _buildClassList(),
                  ),
                ],
              ),
            ),
          ),

          SizedBox(width: 16.w),

          // RIGHT — Student Details or Class Table
          Expanded(
            child: _selectedStudent == null
                ? Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12.r),
                      border: Border.all(color: AppColors.border),
                    ),
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
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10.r),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            children: [
                              InkWell(
                                onTap: () => setState(() { _selectedStudent = null; }),
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
                                padding: EdgeInsets.all(20.w),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12.r),
                                  border: Border.all(color: AppColors.border),
                                ),
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
                                              Row(children: [
                                                AppIcon('user', color: AppColors.accent, size: 20),
                                                SizedBox(width: 8.w),
                                                Text('Student Information',
                                                    style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                                              ]),
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
                                    const Divider(color: AppColors.border),
                                    SizedBox(height: 4.h),
                                    IgnorePointer(
                                      ignoring: !_isFormEnabled,
                                      child: _buildStudentFields(),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: 16.h),
                              _panel(title: 'Parent / Guardian Information', icon: 'people', child: _buildParentFields()),
                              SizedBox(height: 16.h),
                              _panel(title: 'Payment In Charge', icon: 'indianrupeesign.circle.fill', child: _buildPaymentFields()),
                              if (_selectedStudent == null) ...[
                                SizedBox(height: 16.h),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextButton.icon(
                                        onPressed: _isSaving ? null : _clearForm,
                                        icon: AppIcon('close-circle', size: 16),
                                        label: Text('Cancel', style: TextStyle(fontWeight: FontWeight.w500)),
                                        style: TextButton.styleFrom(
                                          foregroundColor: AppColors.textSecondary,
                                          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: 12.w),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: _isSaving ? null : _saveNewStudent,
                                        icon: _isSaving
                                            ? SizedBox(width: 18.w, height: 18.h, child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                            : AppIcon('save-2', size: 18),
                                        label: Text(_isSaving ? 'Saving...' : 'Save', style: const TextStyle(fontWeight: FontWeight.w600)),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: AppColors.accent,
                                          foregroundColor: Colors.white,
                                          padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                                        ),
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

  // ─── Left panel: Student fields ───────────────────────────────────────────────

  Widget _buildStudentFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row3(
          _fieldFull(label: 'Academic Year *', child: DropdownButtonFormField<String>(
            initialValue: _selectedYrId,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            decoration: _dec('Select year'),
            style: _inputStyle,
            items: _years.map((y) => DropdownMenuItem(value: y['yr_id'].toString(), child: Text(y['yrlabel']))).toList(),
            onChanged: (v) => setState(() {
              _selectedYrId = v;
              _selectedYrLabel = v != null
                  ? _years.firstWhere((y) => y['yr_id'].toString() == v)['yrlabel']
                  : null;
            }),
            validator: (v) => v == null ? 'Required' : null,
          )),
          _fieldFull(label: 'Roll Number *', child: TextFormField(
            controller: _admNoController,
            decoration: _dec('Enter roll no'),
            style: _inputStyle,
            validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
          )),
          _fieldFull(label: 'Student Name *', child: TextFormField(
            controller: _nameController,
            decoration: _dec('Enter full name'),
            style: _inputStyle,
            validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
          )),
        ),
        SizedBox(height: 14.h),

        _row3(
          _fieldFull(
            label: 'Admission Date *',
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
                decoration: _dec('Select admission date').copyWith(
                  suffixIcon: Padding(
                    padding: EdgeInsets.only(right: 10.w),
                    child: AppIcon('calendar-1', size: 14, color: AppColors.textSecondary),
                  ),
                ),
                child: Text(
                  _admDate != null
                      ? '${_admDate!.day.toString().padLeft(2, '0')}/${_admDate!.month.toString().padLeft(2, '0')}/${_admDate!.year}'
                      : 'Select admission date',
                  style: TextStyle(
                    color: _admDate != null ? AppColors.textPrimary : AppColors.textSecondary.withValues(alpha: 0.6),
                    fontSize: 13.sp,
                    fontWeight: _admDate != null ? FontWeight.w700 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
          _fieldFull(label: 'Gender *', child: DropdownButtonFormField<String>(
            initialValue: _selectedGender,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            decoration: _dec('Select gender'),
            style: _inputStyle,
            items: _genders.map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
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
              decoration: _dec('Select DOB'),
              child: Text(
                _dob != null
                    ? '${_dob!.day.toString().padLeft(2, '0')}/${_dob!.month.toString().padLeft(2, '0')}/${_dob!.year}'
                    : 'DD/MM/YYYY',
                style: TextStyle(
                  color: _dob != null ? AppColors.textPrimary : AppColors.textSecondary.withValues(alpha: 0.6),
                  fontSize: 13.sp,
                  fontWeight: _dob != null ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ),
          )),
        ),
        SizedBox(height: 14.h),

        _row3(
          _fieldFull(label: 'Mobile Number', child: TextFormField(
            controller: _mobileController,
            decoration: _dec('Enter mobile'),
            style: _inputStyle,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          )),
          _fieldFull(label: 'Email', child: TextFormField(
            controller: _emailController,
            decoration: _dec('Enter email'),
            style: _inputStyle,
            keyboardType: TextInputType.emailAddress,
          )),
          _fieldFull(label: 'Standard', child: TextFormField(
            initialValue: _selectedStudent?.clagrpname ?? '',
            decoration: _dec('Standard'),
            style: _inputStyle,
            enabled: false,
          )),
        ),
        SizedBox(height: 14.h),

        _row3(
          _fieldFull(label: 'Class *', child: Builder(builder: (_) {
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
              decoration: _dec('Select class'),
              style: _inputStyle,
              items: classOptions.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
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
            decoration: _dec('Select'),
            style: _inputStyle,
            items: _bloodGroups.map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
            onChanged: (v) => setState(() => _selectedBloodGroup = v),
          )),
          _fieldFull(label: 'Concession', child: Builder(builder: (_) {
            // Dedupe by con_id — duplicate master rows would otherwise crash
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
              decoration: _dec('Select concession'),
              style: _inputStyle,
              items: items,
              onChanged: (v) => setState(() => _selectedConId = v),
            );
          })),
        ),
        SizedBox(height: 14.h),

        _fieldFull(label: 'Address *', child: TextFormField(
          controller: _addressController,
          decoration: _dec('Enter address'),
          style: _inputStyle,
          maxLines: 2,
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
        )),
        SizedBox(height: 14.h),

        _row4(
          _fieldFull(label: 'City', child: TextFormField(controller: _cityController, decoration: _dec('Enter city'), style: _inputStyle)),
          _fieldFull(label: 'State', child: TextFormField(controller: _stateController, decoration: _dec('Enter state'), style: _inputStyle)),
          _fieldFull(label: 'Country', child: TextFormField(controller: _countryController, decoration: _dec('Enter country'), style: _inputStyle)),
          _fieldFull(label: 'Pin Code *', child: TextFormField(
            controller: _pinController,
            decoration: _dec('Enter pin'),
            style: _inputStyle,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
          )),
        ),
      ],
    );
  }

  // ─── Right panel: Parent fields ───────────────────────────────────────────────

  Widget _buildParentFields() {
    final controllers = _selectedParentTab == 'Father'
        ? (_fatherNameController, _fatherMobileController, _fatherOccController)
        : _selectedParentTab == 'Mother'
            ? (_motherNameController, _motherMobileController, _motherOccController)
            : (_guardianNameController, _guardianMobileController, _guardianOccController);
    final prefix = _selectedParentTab;

    return Column(
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
              selectedColor: AppColors.accent,
              labelStyle: TextStyle(color: selected ? Colors.white : AppColors.textPrimary, fontWeight: FontWeight.w600),
              backgroundColor: AppColors.border.withValues(alpha: 0.3),
            );
          }).toList(),
        ),
        SizedBox(height: 16.h),

        IgnorePointer(
          ignoring: !_isFormEnabled,
          child: _row3(
            _fieldFull(label: '$prefix Name', child: TextFormField(
              controller: controllers.$1,
              decoration: _dec('Enter $prefix name'),
              style: _inputStyle,
            )),
            _fieldFull(label: '$prefix Mobile', child: TextFormField(
              controller: controllers.$2,
              decoration: _dec('Enter mobile'),
              style: _inputStyle,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            )),
            _fieldFull(label: '$prefix Occupation', child: TextFormField(
              controller: controllers.$3,
              decoration: _dec('Enter occupation'),
              style: _inputStyle,
            )),
          ),
        ),
      ],
    );
  }

  // ─── Right panel: Payment fields ──────────────────────────────────────────────

  Widget _buildPaymentFields() {
    return IgnorePointer(
      ignoring: !_isFormEnabled,
      child: _row2(
      _fieldFull(label: 'Name *', child: TextFormField(
        controller: _payNameController,
        decoration: _dec('Enter name'),
        style: _inputStyle,
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
      )),
      _fieldFull(label: 'Mobile Number *', child: TextFormField(
        controller: _payMobileController,
        decoration: _dec('Enter mobile'),
        style: _inputStyle,
        keyboardType: TextInputType.phone,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
      )),
    ));
  }

  // ─── Excel Import ─────────────────────────────────────────────────────────────

  /// Known student fields for column mapping
  static const _importFields = <String, String>{
    '': '-- Skip --',
    'stuadmno': 'Roll No',
    'stuname': 'Name',
    'stugender': 'Gender',
    'studob': 'DOB',
    'stumobile': 'Mobile',
    'stuclass': 'Class',
    'clagrpname': 'Standard',
    'stuemail': 'Email',
    'stuaddress': 'Address',
    'stucity': 'City',
    'stustate': 'State',
    'stucountry': 'Country',
    'stupin': 'PIN',
    'stubloodgrp': 'Blood Group',
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
    'payincharge': 'Payment In Charge',
    'payinchargemob': 'Payment Mobile',
  };

  /// Auto-map header text to field key (case-insensitive)
  static String _autoMapHeader(String header) {
    // Strip the trailing "*" used to flag mandatory columns in our templates
    // ("Roll No *" → "roll no") so re-uploaded templates still auto-map.
    final h = header.replaceAll('*', '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    const map = {
      'adm no': 'stuadmno', 'admission number': 'stuadmno', 'admno': 'stuadmno', 'admission no': 'stuadmno', 'roll no': 'stuadmno', 'rollno': 'stuadmno', 'roll number': 'stuadmno',
      'name': 'stuname', 'student name': 'stuname', 'stuname': 'stuname',
      'gender': 'stugender', 'sex': 'stugender',
      'dob': 'studob', 'date of birth': 'studob', 'birth date': 'studob',
      'mobile': 'stumobile', 'phone': 'stumobile', 'mobile no': 'stumobile', 'phone no': 'stumobile',
      'class': 'stuclass', 'grade': 'stuclass',
      'standard': 'clagrpname', 'standard name': 'clagrpname',
      'course': 'clagrpname', 'course name': 'clagrpname', 'clagrpname': 'clagrpname',
      'email': 'stuemail', 'e-mail': 'stuemail',
      'address': 'stuaddress',
      'city': 'stucity', 'town': 'stucity',
      'state': 'stustate',
      'country': 'stucountry',
      'pin': 'stupin', 'pincode': 'stupin', 'pin code': 'stupin', 'zip': 'stupin', 'zip code': 'stupin',
      'blood group': 'stubloodgrp', 'bloodgroup': 'stubloodgrp',
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

  // ─── Import Logic ───────────────────────────────────────────────────────

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
        if (parsed.isEmpty) throw Exception('CSV file is empty');
        headers = parsed.first.map((e) => e.toString().trim()).toList();
        rows = parsed.skip(1).where((r) => r.any((c) => c.toString().trim().isNotEmpty)).toList();
      } else {
        final excel = xl.Excel.decodeBytes(file.bytes!);
        final sheetName = excel.tables.keys.first;
        final sheet = excel.tables[sheetName]!;
        if (sheet.rows.isEmpty) throw Exception('Excel file is empty');
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
            .select('cla_id, claname, cgrp_id')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        SupabaseService.fromSchema('clagrp')
            .select('cgrp_id, clagrpname')
            .eq('ins_id', insId),
      ]);
      final classRows = results[0] as List;
      final courseRows = results[1] as List;
      final courNameById = <int, String>{
        for (final c in courseRows)
          if (c['cgrp_id'] is int && (c['clagrpname']?.toString() ?? '').isNotEmpty)
            c['cgrp_id'] as int: c['clagrpname'].toString().trim(),
      };
      final classNames = <String>{};
      final classToCourse = <String, String?>{};
      for (final r in classRows) {
        final name = (r['claname']?.toString() ?? '').trim();
        if (name.isEmpty) continue;
        final k = norm(name);
        classNames.add(k);
        final cid = r['cgrp_id'];
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
          SnackBar(content: Text('Export failed. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _exportStudentTemplate() async {
    final excel = xl.Excel.createExcel();
    final sheet = excel['Students'];
    excel.delete('Sheet1');

    // Asterisk marks the columns the importer requires
    // (_importRequiredFields = stuadmno, stuname, stugender, stuclass,
    // payincharge, payinchargemob).
    final headers = [
      'Roll No *', 'Name *', 'Gender *', 'DOB', 'Admission Date', 'Standard', 'Class *', 'Mobile', 'Email', 'Concession',
      'Address', 'City', 'State', 'Country', 'PIN', 'Blood Group',
      'Father Name', 'Father Mobile', 'Father Occupation',
      'Mother Name', 'Mother Mobile', 'Mother Occupation',
      'Guardian Name', 'Guardian Mobile', 'Guardian Occupation',
      'Payment In Charge *', 'Payment Mobile *',
      'Admitted Year',
    ];

    final headerStyle = xl.CellStyle(
      backgroundColorHex: xl.ExcelColor.fromHexString('#FF2D3748'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFFFF'),
      bold: true,
    );

    for (int i = 0; i < headers.length; i++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = xl.TextCellValue(headers[i]);
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
          SnackBar(content: Text('Export failed. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _exportSampleData() async {
    final excel = xl.Excel.createExcel();
    final sheet = excel['Students'];
    excel.delete('Sheet1');

    final headers = [
      'Roll No *', 'Name *', 'Gender *', 'DOB', 'Admission Date', 'Standard', 'Class *', 'Mobile', 'Email', 'Concession',
      'Address', 'City', 'State', 'Country', 'PIN', 'Blood Group',
      'Father Name', 'Father Mobile', 'Father Occupation',
      'Mother Name', 'Mother Mobile', 'Mother Occupation',
      'Guardian Name', 'Guardian Mobile', 'Guardian Occupation',
      'Payment In Charge *', 'Payment Mobile *',
      'Admitted Year',
    ];
    final sampleRows = [
      ['CS001', 'RAHUL KUMAR', 'Male', '2004-06-15', '2025-06-01', 'BSC-CS', 'I Year', '9876543210', 'rahul@email.com', 'GENERAL', 'No.5 Main Street', 'Chennai', 'Tamil Nadu', 'India', '600001', 'B+', 'KUMAR S', '9876543210', 'Business', 'LAKSHMI K', '9876543211', 'Teacher', '', '', '', 'KUMAR S', '9876543210', '25-26'],
      ['CS002', 'PRIYA S', 'Female', '2004-03-22', '2025-06-01', 'BSC-CS', 'I Year', '9876543220', '', 'GENERAL', 'No.10 Anna Nagar', 'Chennai', 'Tamil Nadu', 'India', '600040', 'O+', 'SENTHIL S', '9876543220', 'Engineer', 'MEENA S', '9876543221', 'Homemaker', '', '', '', 'SENTHIL S', '9876543220', '25-26'],
      ['BBA001', 'ARUN M', 'Male', '2003-11-08', '2025-06-01', 'BBA', 'II Year', '9876543230', 'arun@email.com', 'GENERAL', 'No.15 Park Road', 'Madurai', 'Tamil Nadu', 'India', '625001', 'A+', 'MURUGAN A', '9876543230', 'Doctor', 'SELVI M', '9876543231', 'Nurse', '', '', '', 'MURUGAN A', '9876543230', '25-26'],
      ['MCA001', 'DIVYA R', 'Female', '2002-08-30', '2025-06-01', 'MCA', 'I Year', '9876543240', '', 'GENERAL', 'No.20 Lake View', 'Coimbatore', 'Tamil Nadu', 'India', '641001', 'AB+', 'RAJAN D', '9876543240', 'Farmer', 'KALA R', '9876543241', 'Homemaker', '', '', '', 'RAJAN D', '9876543240', '25-26'],
    ];

    final headerStyle = xl.CellStyle(
      backgroundColorHex: xl.ExcelColor.fromHexString('#FF2D3748'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFFFF'),
      bold: true,
    );

    for (int i = 0; i < headers.length; i++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = xl.TextCellValue(headers[i]);
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
          SnackBar(content: Text('Export failed. ${friendlyError(e)}'), backgroundColor: AppColors.error),
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

  static String? _truncate(String? v, int maxLen) {
    if (v == null) return null;
    return v.length <= maxLen ? v : v.substring(0, maxLen);
  }

  /// Validates email format; returns null if invalid
  static String? _validEmail(String? v) {
    final e = _nullIfEmpty(v);
    if (e == null) return null;
    // Basic email check — must contain @ and .
    final regex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return regex.hasMatch(e) ? e : null;
  }

  /// Per-field validation. Returns a map of fieldKey → reason for every cell
  /// that's invalid. Empty map means the row passes.
  Map<String, String> _validateImportRow(int rowIdx) {
    final row = _importRows[rowIdx];
    final errors = <String, String>{};
    for (final reqKey in _importRequiredFields) {
      final colIdx = _importMappings.indexOf(reqKey);
      if (colIdx < 0 || colIdx >= row.length || row[colIdx].toString().trim().isEmpty) {
        errors[reqKey] = 'Required';
      }
    }
    // Class + course must exist in the master and (if both supplied) agree
    // with the class-course mapping. Skip if masters haven't loaded yet —
    // server enforces too.
    String norm(String s) => s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    final classRaw = (_importCellByKey(row, 'stuclass') ?? '').trim();
    final courseRaw = (_importCellByKey(row, 'clagrpname') ?? '').trim();
    if (classRaw.isNotEmpty && _importClassNames.isNotEmpty) {
      final k = norm(classRaw);
      if (!_importClassNames.contains(k)) {
        errors['stuclass'] = 'Class "$classRaw" not found in master';
      } else if (courseRaw.isNotEmpty && _importCourseNames.isNotEmpty) {
        final ck = norm(courseRaw);
        if (!_importCourseNames.contains(ck)) {
          errors['clagrpname'] = 'Standard "$courseRaw" not found in master';
        } else {
          final expected = _importClassToCourse[k];
          if (expected != null && expected != ck) {
            errors['clagrpname'] = 'Class "$classRaw" belongs to "$expected"';
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
        missing.add(_importGridLabels[k] ?? _importFields[k] ?? k);
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
      if (m.contains('stuadmno') || m.contains('admission')) return 'Roll number already exists';
      if (m.contains('stuemail') || m.contains('email')) return 'Email already exists';
      if (m.contains('payinchargemob')) return 'Payment mobile already exists';
      return 'Duplicate record found';
    }
    if (m.contains('not-null') || m.contains('null value')) {
      final match = RegExp(r'column "(\w+)"').firstMatch(msg);
      final col = match?.group(1) ?? '';
      final labels = {'stuadmno': 'Roll No', 'stuname': 'Name', 'stugender': 'Gender', 'studob': 'Date of Birth', 'stumobile': 'Mobile', 'stuclass': 'Class', 'payincharge': 'Pay In Charge', 'payinchargemob': 'Payment Mobile'};
      return '${labels[col] ?? col} is required';
    }
    if (m.contains('foreign key') || m.contains('fkey')) return 'Invalid reference - check class, year, or concession values';
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
        const SnackBar(content: Text('All rows are valid'), backgroundColor: AppColors.success),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${rowErrors.length} row(s) have errors — highlighted in red'), backgroundColor: AppColors.error),
      );
    }
  }

  Future<void> _startStudentImport() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;

    // Check master data exists before allowing import
    final masterData = await SupabaseService.checkMasterData(insId);
    if (!masterData.hasFeeGroups || !masterData.hasFeeTypes || !masterData.hasConcessions || !masterData.hasClassFeeDemand) {
      if (mounted) {
        final missing = <String>[];
        if (!masterData.hasFeeGroups) missing.add('Fee Groups');
        if (!masterData.hasFeeTypes) missing.add('Fee Types');
        if (!masterData.hasConcessions) missing.add('Concessions');
        if (!masterData.hasClassFeeDemand) missing.add('Class Fee Demand');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Please import master data first: ${missing.join(', ')}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }

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
    // cla_id and cgrp_id resolved from the canonical master tables.
    final classMasterRaw = await SupabaseService.fromSchema('class')
        .select('cla_id, claname')
        .eq('ins_id', insId)
        .eq('activestatus', 1);
    final courseMasterRaw = await SupabaseService.fromSchema('clagrp')
        .select('cgrp_id, clagrpname')
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
    final cgrpIdByName = <String, int>{};
    final courNameById = <int, String>{};
    for (final c in (courseMasterRaw as List)) {
      final id = c['cgrp_id'] as int?;
      final name = (c['clagrpname'] ?? '').toString().trim();
      if (id == null || name.isEmpty) continue;
      cgrpIdByName.putIfAbsent(_normKey(name), () => id);
      courNameById[id] = name;
    }

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
      // Always write the canonical claname/clagrpname from the master back into
      // stuclass / clagrpname so downstream JOINs and dashboards work.
      final classRaw = (_importCellByKey(row, 'stuclass') ?? '').trim();
      int? claId;
      String claNameCanon = classRaw;
      final classAsInt = int.tryParse(classRaw);
      if (classAsInt != null && claNameById.containsKey(classAsInt)) {
        // Excel had a valid cla_id → resolve to canonical name
        claId = classAsInt;
        claNameCanon = claNameById[claId]!;
      } else {
        // Excel had a name (or a number that isn't in the master) → name lookup
        final byName = claIdByName[_normKey(classRaw)];
        if (byName != null) {
          claId = byName;
          claNameCanon = claNameById[claId] ?? classRaw;
        }
      }

      final courseRaw = (_importCellByKey(row, 'clagrpname') ?? '').trim();
      int? cgrpId;
      String? courNameCanon = _nullIfEmpty(courseRaw);
      final courseAsInt = int.tryParse(courseRaw);
      if (courseAsInt != null && courNameById.containsKey(courseAsInt)) {
        cgrpId = courseAsInt;
        courNameCanon = courNameById[cgrpId];
      } else {
        final byName = cgrpIdByName[_normKey(courseRaw)];
        if (byName != null) {
          cgrpId = byName;
          courNameCanon = courNameById[cgrpId];
        }
      }
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
        'clagrpname': courNameCanon,
        'cgrp_id': cgrpId,
        'stumobile': _importCellByKey(row, 'stumobile'),
        'stuemail': _validEmail(_importCellByKey(row, 'stuemail')),
        'concession': _nullIfEmpty(_importCellByKey(row, 'concession')),
        'stuaddress': _nullIfEmpty(_importCellByKey(row, 'stuaddress')),
        'stucity': _nullIfEmpty(_importCellByKey(row, 'stucity')),
        'stustate': _nullIfEmpty(_importCellByKey(row, 'stustate')),
        'stucountry': _nullIfEmpty(_importCellByKey(row, 'stucountry')),
        'stupin': _nullIfEmpty(_importCellByKey(row, 'stupin')),
        'stubloodgrp': _nullIfEmpty(_importCellByKey(row, 'stubloodgrp')),
        'fathername': _nullIfEmpty(_importCellByKey(row, 'fathername')),
        'fathermobile': _nullIfEmpty(_importCellByKey(row, 'fathermobile')),
        'fatheroccupation': _nullIfEmpty(_importCellByKey(row, 'fatheroccupation')),
        'mothername': _nullIfEmpty(_importCellByKey(row, 'mothername')),
        'mothermobile': _nullIfEmpty(_importCellByKey(row, 'mothermobile')),
        'motheroccupation': _nullIfEmpty(_importCellByKey(row, 'motheroccupation')),
        'guardianname': _nullIfEmpty(_importCellByKey(row, 'guardianname')),
        'guardianmobile': _nullIfEmpty(_importCellByKey(row, 'guardianmobile')),
        'guardianoccupation': _nullIfEmpty(_importCellByKey(row, 'guardianoccupation')),
        'payincharge': _nullIfEmpty(_importCellByKey(row, 'payincharge')) ?? '-',
        'payinchargemob': _nullIfEmpty(_importCellByKey(row, 'payinchargemob')),
        'admittyear': _truncate(_nullIfEmpty(_importCellByKey(row, 'admittyear')), 9),
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

      if (result is List && result.isNotEmpty) {
        final r = result.first;
        _importedCount = (r['imported'] as num?)?.toInt() ?? 0;
        _skippedCount += (r['skipped'] as num?)?.toInt() ?? 0;
      }

      // 4. Fetch errors from staging table
      final errors = await SupabaseService.fromSchema('student_import')
          .select('imp_id, stuadmno, error_msg, status')
          .eq('ins_id', insId)
          .inFilter('status', ['ERROR', 'NO_PARENT']);
      for (final e in errors) {
        final status = e['status'];
        final admNo = e['stuadmno'] ?? '';
        if (status == 'NO_PARENT') {
          _importErrors.add('Roll $admNo: Payment In Charge or Mobile is missing - student not created');
        } else {
          _importErrors.add('Roll $admNo: ${_friendlyError(e['error_msg']?.toString() ?? 'Unknown error')}');
        }
      }

      // 5. Clean up processed staging rows
      await SupabaseService.fromSchema('student_import')
          .delete()
          .eq('ins_id', insId)
          .inFilter('status', ['DONE', 'ERROR', 'NO_PARENT']);

    } catch (e) {
      _importErrors.add(friendlyError(e));
    }

    setState(() => _importStep = 3);
    _loadDropdowns();
  }

  // ─── Import UI ──────────────────────────────────────────────────────────

  Widget _buildStudentImportSection() {
    if (_importStep == 2) return _buildImportProgressStep();
    if (_importStep == 3) return _buildImportDoneStep();

    return Container(
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title bar
          Row(
            children: [
              InkWell(
                onTap: _resetImport,
                borderRadius: BorderRadius.circular(MediaQuery.of(context).size.width <= 1366 ? 6 : 10),
                child: Builder(builder: (context) {
                  final compact = MediaQuery.of(context).size.width <= 1366;
                  final hPad = compact ? 10.0 : 14.0;
                  final radius = compact ? 6.0 : 10.0;
                  final textSize = compact ? 11.0 : 13.0;
                  final innerGap = compact ? 4.0 : 6.0;
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
                        Text('Back', style: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600, color: Colors.white)),
                      ],
                    ),
                  );
                }),
              ),
              SizedBox(width: 12.w),
              AppIcon('document-upload', size: 20, color: AppColors.accent),
              SizedBox(width: 8.w),
              Text('Import Students', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_importFileName != null)
                Text(_importFileName!, style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
              SizedBox(width: 12.w),
              ElevatedButton.icon(
                onPressed: _pickImportFile,
                icon: AppIcon('document-upload', size: 16),
                label: const Text('Import'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                  textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                ),
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
                  label: Text(hasErrors ? 'Export with Errors' : 'Format to Excel'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF217346),
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                    textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                  ),
                );
              }),
              SizedBox(width: 8.w),
              ElevatedButton.icon(
                onPressed: _exportSampleData,
                icon: AppIcon('document-download', size: 16),
                label: const Text('Sample Data'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE65100),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                  textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                ),
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
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(8.r),
              ),
              clipBehavior: Clip.hardEdge,
              child: LayoutBuilder(builder: (ctx, constraints) {
                final viewportW = constraints.maxWidth;
                final sNoW = 50.w;
                final dividers = (_importGridKeys.length + 1) * 1.0;
                final dataColsRaw = _importGridKeys.fold<double>(0, (sum, k) => sum + _gridColWidth(k));
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
                                decoration: BoxDecoration(
                                  color: AppColors.tableHeadBg,
                                  borderRadius: BorderRadius.only(
                                    topLeft: Radius.circular(7.r),
                                    topRight: Radius.circular(7.r),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    _gridHeaderCell('S.No', width: sNoW, center: true),
                                    _gridHeaderDivider(),
                                    for (final key in _importGridKeys) ...[
                                      _gridHeaderCell(_importGridLabels[key] ?? key, width: colW(key)),
                                      _gridHeaderDivider(),
                                    ],
                                  ],
                                ),
                              ),
                              // Data rows
                              Expanded(
                                child: _importRows.isEmpty
                                    ? Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            AppIcon('element-4', size: 48.sp, color: AppColors.textSecondary.withValues(alpha: 0.3)),
                                            SizedBox(height: 8.h),
                                            Text('No data loaded', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                                            SizedBox(height: 4.h),
                                            Text('Click Browse to load a CSV or Excel file', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                                          ],
                                        ),
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
                                                for (final key in _importGridKeys)
                                                  cellErrs.containsKey(key)
                                                      ? Tooltip(
                                                          message: cellErrs[key]!,
                                                          child: Container(
                                                            color: const Color(0xFFFCE4E4),
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
                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _importRows.isEmpty || _importValidated ? null : _validateImportData,
                icon: AppIcon(_importValidated ? 'tick-circle' : 'tick-circle', size: 16),
                label: Text(_importValidated ? 'Validated' : 'Validate'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _importRows.isNotEmpty && !_importValidated ? Colors.orange : (_importValidated ? AppColors.success : Colors.grey),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.r)),
                  textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(width: 8.w),
              ElevatedButton.icon(
                onPressed: _importValidated ? _startStudentImport : null,
                icon: AppIcon('save-2', size: 16),
                label: const Text('Save'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                  textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(width: 8.w),
              OutlinedButton(
                onPressed: _resetImport,
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                  textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                ),
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
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            SizedBox(height: 20.h),
            Text('Importing... ${_importedCount + _skippedCount} / $_totalCount', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
            SizedBox(height: 12.h),
            LinearProgressIndicator(value: progress, backgroundColor: AppColors.border, valueColor: const AlwaysStoppedAnimation(AppColors.accent)),
            SizedBox(height: 8.h),
            Text('$_importedCount imported, $_skippedCount skipped', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
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
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon('tick-circle', size: 64.sp, color: AppColors.success),
            SizedBox(height: 16.h),
            Text('Import Complete', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            SizedBox(height: 12.h),
            Text('$_importedCount imported successfully, $_skippedCount skipped', style: TextStyle(fontSize: 13.sp)),
            if (_importErrors.isNotEmpty) ...[
              SizedBox(height: 16.h),
              Container(
                height: 150.h,
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8.r),
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
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  double _gridColWidth(String key) {
    // Widths sized to fit header text on a single line at 13.sp / w700
    // (e.g., "GUARDIAN MOBILE" needs ~150px; "CONCESSION *" needs ~140px).
    switch (key) {
      case 'stuadmno': return 110;          // ROLL NO *
      case 'stuname': return 170;           // NAME *
      case 'stugender': return 110;         // GENDER *
      case 'studob': return 100;            // DOB *
      case 'stuadmdate': return 120;        // ADM DATE
      case 'stuclass': return 100;          // CLASS *
      case 'clagrpname': return 110;          // STANDARD
      case 'stumobile': return 120;         // MOBILE
      case 'stuemail': return 170;          // EMAIL
      case 'concession': return 150;        // CONCESSION *
      case 'stuaddress': return 170;        // ADDRESS
      case 'stucity': return 100;           // CITY
      case 'stustate': return 100;          // STATE
      case 'stucountry': return 110;        // COUNTRY
      case 'stupin': return 110;            // PIN CODE
      case 'stubloodgrp': return 130;       // BLOOD GROUP
      case 'fathername': case 'mothername': return 150;
      case 'guardianname': return 160;      // GUARDIAN NAME
      case 'fathermobile': case 'mothermobile': return 150;
      case 'guardianmobile': return 170;    // GUARDIAN MOBILE
      case 'fatheroccupation': case 'motheroccupation': case 'guardianoccupation': return 150;
      case 'payincharge': return 160;       // PAY IN CHARGE *
      case 'payinchargemob': return 140;    // PAY MOBILE *
      case 'admittyear': return 140;        // ADMITTED YEAR
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
        style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3.w),
      ),
    );
    return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
  }

  Widget _gridHeaderDivider() {
    return Container(width: 1, height: 44.h, color: AppColors.border);
  }

  Widget _gridDataCell(String text, {double? width, int flex = 1, bool center = false}) {
    final child = Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
      alignment: center ? Alignment.center : Alignment.centerLeft,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: AppColors.border.withValues(alpha: 0.3))),
      ),
      child: Text(text, style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
    );
    return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────────

  /// Card panel with a labelled header
  Widget _panel({required String title, required String icon, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            AppIcon(icon, color: AppColors.accent, size: 20),
            SizedBox(width: 8.w),
            Text(title, style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ]),
          SizedBox(height: 4.h),
          const Divider(color: AppColors.border),
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
        Text(label, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: Colors.black)),
        SizedBox(height: 6.h),
        child,
      ],
    );
  }

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.6), fontSize: 13.sp),
    contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.border)),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.border)),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r), borderSide: const BorderSide(color: AppColors.accent)),
    filled: true,
    fillColor: Colors.white,
  );
}

// _ExcelImportDialog removed — import is now inline grid in _StudentsScreenState
