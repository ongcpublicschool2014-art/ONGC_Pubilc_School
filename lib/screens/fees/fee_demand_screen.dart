import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:excel/excel.dart' as xl;
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../services/supabase_service.dart';
import '../../utils/formatters.dart';

class FeeDemandScreen extends StatefulWidget {
  const FeeDemandScreen({super.key});

  @override
  State<FeeDemandScreen> createState() => _FeeDemandScreenState();
}

class _FeeDemandScreenState extends State<FeeDemandScreen> {
  // Form controllers
  final _formKey = GlobalKey<FormState>();
  final _admNoController = TextEditingController();
  final _feeAmountController = TextEditingController();
  final _conAmountController = TextEditingController();
  DateTime? _dueDate;

  String? _selectedClass;
  String? _selectedFeeType;
  String? _selectedFeeYear;
  final _feeTermController = TextEditingController();
  String? _selectedConcession;
  List<String> _classes = [];
  List<String> _feeTypes = [];
  List<Map<String, dynamic>> _years = [];
  List<Map<String, dynamic>> _concessions = [];
  List<String> _concessionList = [];

  // Students master cached at file-pick time so _validateRow can flag rows
  // whose Roll No doesn't exist, or whose Class/Course disagrees with the
  // student's stored class/course (so a demand can't be filed against the
  // wrong roll number by mistake).
  Map<String, Map<String, String>> _importStudentByAdmno = {};

  bool _isLoading = false;
  bool _isSaving = false;

  // Import state
  bool _showImport = false;
  String? _fileName;
  List<String> _headers = [];
  List<List<dynamic>> _rows = [];
  Map<int, String> _rowErrors = {};
  // rowIdx → set of field keys whose value failed validation. Field keys
  // match _importFieldLabels (e.g. 'stuadmno', 'stuclass', 'demfeetype').
  Map<int, Set<String>> _cellErrors = {};
  List<String?> _mappings = [];
  int _importStep = 0; // 0=pick, 1=map, 2=importing, 3=done
  int _imported = 0;
  int _skipped = 0;
  int _total = 0;
  List<String> _importErrors = [];
  String? _errorMsg;

  // Fee demand list
  List<Map<String, dynamic>> _classSummary = [];
  bool _loadingDemands = false;
  String? _drilldownClass;
  List<Map<String, dynamic>> _drilldownDemands = [];
  bool _loadingDrilldown = false;
  String? _drilldownStudent; // selected student adm no for 3rd level
  String? _drilldownStudentName; // selected student name for 3rd level

  // Search
  final _searchController = TextEditingController();
  String _searchQuery = '';

  static const _importFieldKeys = [
    'demno',
    'stuadmno',
    'stuclass',
    'courname',
    'demfeetype',
    'yr_id',
    'demfeeterm',
    'con_id',
    'feeamount',
    'conamount',
    'duedate',
  ];

  static const Map<String, String> _importFieldLabels = {
    'demno': 'Demand No',
    'stuadmno': 'Roll No',
    'stuclass': 'Class',
    'courname': 'Course',
    'demfeetype': 'Fee Type',
    'yr_id': 'Fee Year',
    'demfeeterm': 'Semester',
    'con_id': 'Concession',
    'feeamount': 'Fee Amount',
    'conamount': 'Concession Amount',
    'duedate': 'Due Date',
  };

  static const _requiredFields = {'stuadmno', 'stuclass', 'demfeetype', 'yr_id', 'demfeeterm', 'feeamount', 'duedate'};

  @override
  void initState() {
    super.initState();
    _loadDropdowns();
    _loadFeeDemands();
  }

  @override
  void dispose() {
    _admNoController.dispose();
    _feeAmountController.dispose();
    _conAmountController.dispose();

    _feeTermController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadDropdowns() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        SupabaseService.getClasses(insId),
        SupabaseService.getYears(insId),
        SupabaseService.getConcessions(insId),
        SupabaseService.getFeeTypes(insId),
      ]);

      if (!mounted) return;
      final classes = results[0] as List<String>;
      const classOrder = ['PKG', 'LKG', 'UKG', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII'];
      classes.sort((a, b) {
        final aIdx = classOrder.indexOf(a);
        final bIdx = classOrder.indexOf(b);
        return (aIdx == -1 ? 999 : aIdx).compareTo(bIdx == -1 ? 999 : bIdx);
      });
      setState(() {
        _classes = classes;
        _years = results[1] as List<Map<String, dynamic>>;
        _concessions = results[2] as List<Map<String, dynamic>>;
        _concessionList = _concessions
            .map((c) => c['condesc']?.toString())
            .where((s) => s != null && s.isNotEmpty)
            .cast<String>()
            .toList();
        _feeTypes = results[3] as List<String>;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading dropdowns: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadFeeDemands() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() => _loadingDemands = true);
    try {
      final results = await Future.wait<dynamic>([
        SupabaseService.getFeeDemandSummary(insId),
        SupabaseService.getCourseClassOrdering(insId),
      ]);
      final summary = results[0] as List<Map<String, dynamic>>;
      final ord = results[1] as ({Map<String, int> courseOrd, Map<String, int> classOrd});
      if (mounted) {
        // Sort by course.ordid then class.ordid (master-data order).
        // Rows with no matching master row fall to the end, then break ties by name.
        const tail = 1 << 30;
        int courseKey(String name) => ord.courseOrd[name.trim()] ?? tail;
        int classKey(String name) => ord.classOrd[name.trim()] ?? tail;
        summary.sort((a, b) {
          final aCourse = a['courname']?.toString() ?? '';
          final bCourse = b['courname']?.toString() ?? '';
          final c = courseKey(aCourse).compareTo(courseKey(bCourse));
          if (c != 0) return c;
          final nameCmp = aCourse.compareTo(bCourse);
          if (nameCmp != 0) return nameCmp;
          final aClass = a['stuclass']?.toString() ?? '';
          final bClass = b['stuclass']?.toString() ?? '';
          final ck = classKey(aClass).compareTo(classKey(bClass));
          if (ck != 0) return ck;
          return aClass.compareTo(bClass);
        });
        setState(() {
          _classSummary = summary;
          _loadingDemands = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading fee demands: $e');
      if (mounted) setState(() => _loadingDemands = false);
    }
  }

  String? _drilldownCourse;

  Future<void> _loadDrilldown(String className, {String? courseName}) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() {
      _drilldownClass = className;
      _drilldownCourse = courseName;
      _loadingDrilldown = true;
      _drilldownDemands = [];
    });
    try {
      final demands = await SupabaseService.getFeeDemandsByClass(insId, className);
      // Filter by course if specified
      final filtered = courseName != null
          ? demands.where((d) => (d['courname']?.toString() ?? d['stuname_course'] ?? '') == courseName || courseName == 'Other').toList()
          : demands;
      if (mounted) {
        setState(() {
          _drilldownDemands = filtered;
          _loadingDrilldown = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading drilldown: $e');
      if (mounted) setState(() => _loadingDrilldown = false);
    }
  }

  Future<void> _saveDemand() async {
    if (!_formKey.currentState!.validate()) return;

    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final inscode = auth.inscode;
    if (insId == null) return;

    final masterData = await SupabaseService.checkMasterData(insId);
    if (!masterData.hasFeeTypes || !masterData.hasClassFeeDemand) {
      if (mounted) {
        final missing = <String>[];
        if (!masterData.hasFeeTypes) missing.add('Fee Types');
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

    setState(() => _isSaving = true);
    try {
      // Look up the year label for the selected yr_id
      String? yearLabel;
      if (_selectedFeeYear != null) {
        final yearEntry = _years.firstWhere(
          (y) => y['yr_id'].toString() == _selectedFeeYear,
          orElse: () => <String, dynamic>{},
        );
        yearLabel = yearEntry['yrlabel']?.toString();
      }

      final feeAmount = double.tryParse(_feeAmountController.text.trim()) ?? 0;
      final conAmount = double.tryParse(_conAmountController.text.trim()) ?? 0;

      // Lookup stu_id from admission number
      final admNo = _admNoController.text.trim();
      int? stuId;
      if (admNo.isNotEmpty) {
        final stuResult = await SupabaseService.fromSchema('students')
            .select('stu_id')
            .eq('ins_id', insId)
            .eq('stuadmno', admNo)
            .eq('activestatus', 1)
            .maybeSingle();
        stuId = stuResult?['stu_id'] as int?;
      }

      final data = {
        'ins_id': insId,
        'inscode': inscode ?? '',
        'stuadmno': admNo,
        'stu_id': stuId,
        'stuclass': _selectedClass,
        'demfeetype': _selectedFeeType,
        'yr_id': _selectedFeeYear != null ? int.tryParse(_selectedFeeYear!) : null,
        'demfeeyear': yearLabel,
        'demfeeterm': _feeTermController.text.trim(),
        'con_id': _selectedConcession != null ? int.tryParse(_selectedConcession!) : null,
        'feeamount': feeAmount,
        'conamount': conAmount,
        'balancedue': feeAmount,
        'duedate': _dueDate?.toIso8601String().split('T').first,
        'activestatus': 1,
        'createdat': DateTime.now().toIso8601String(),
        'createdby': auth.userName,
        'isapproved': false,
      };

      await SupabaseService.fromSchema('tempfeedemand').insert(data);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fee demand saved successfully'), backgroundColor: AppColors.success),
        );
        _resetForm();
        _loadFeeDemands();
      }
    } catch (e) {
      debugPrint('Error saving fee demand: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _lookupStudentClass(String admNo) async {
    if (admNo.isEmpty) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId;
    if (insId == null) return;
    try {
      final result = await SupabaseService.fromSchema('students')
          .select('stuclass')
          .eq('ins_id', insId)
          .eq('stuadmno', admNo)
          .eq('activestatus', 1)
          .maybeSingle();
      if (mounted && result != null) {
        setState(() => _selectedClass = result['stuclass']?.toString());
      }
    } catch (_) {}
  }

  void _resetForm() {
    _formKey.currentState?.reset();
    _admNoController.clear();
    _feeAmountController.clear();
    _conAmountController.clear();

    setState(() {
      _selectedClass = null;
      _selectedFeeType = null;
      _selectedFeeYear = null;
      _feeTermController.clear();
      _selectedConcession = null;
      _dueDate = null;
    });
  }

  Future<void> _pickDueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  // ─── Import Logic ───────────────────────────────────────────────────────

  static String? _autoMapHeader(String header) {
    final h = header.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    const aliases = {
      'demno': 'demno', 'demandno': 'demno', 'demandnumber': 'demno', 'docno': 'demno',
      'admissionno': 'stuadmno', 'admno': 'stuadmno', 'stuadmno': 'stuadmno', 'admissionnumber': 'stuadmno', 'rollno': 'stuadmno', 'roll': 'stuadmno', 'rollnumber': 'stuadmno',
      'class': 'stuclass', 'stuclass': 'stuclass',
      'course': 'courname', 'courname': 'courname', 'coursename': 'courname',
      'feetype': 'demfeetype', 'demfeetype': 'demfeetype', 'type': 'demfeetype',
      'feeyear': 'yr_id', 'yrid': 'yr_id', 'year': 'yr_id',
      'feeterm': 'demfeeterm', 'demfeeterm': 'demfeeterm', 'term': 'demfeeterm', 'semester': 'demfeeterm', 'sem': 'demfeeterm',
      'concession': 'con_id', 'conid': 'con_id', 'concessioncategory': 'con_id', 'con': 'con_id',
      'feeamount': 'feeamount', 'amount': 'feeamount', 'fee': 'feeamount', 'feeamt': 'feeamount', 'fee amount': 'feeamount', 'fee amt': 'feeamount',
      'concessionamount': 'conamount', 'conamount': 'conamount', 'conamt': 'conamount', 'con amt': 'conamount', 'con. amt': 'conamount', 'concession amount': 'conamount',
      'duedate': 'duedate', 'due': 'duedate',
    };
    return aliases[h];
  }

  Future<void> _pickFile() async {
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

      final mappings = headers.map((h) => _autoMapHeader(h)).toList();

      setState(() {
        _fileName = file.name;
        _headers = headers;
        _rows = rows;
        _mappings = mappings;
        _importStep = 1;
        _errorMsg = null;
        _rowErrors = {};
        _cellErrors = {};
      });
      await _loadStudentMaster();
    } catch (e) {
      setState(() => _errorMsg = friendlyError(e));
    }
  }

  /// Load the students master keyed by roll number so _validateRow can flag
  /// imported rows whose Roll No doesn't exist, or whose Class/Course
  /// disagrees with what the student is registered under.
  Future<void> _loadStudentMaster() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    String norm(String s) => s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    try {
      final rows = await SupabaseService.fromSchema('students')
          .select('stuadmno, stuclass, courname')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      final map = <String, Map<String, String>>{};
      for (final s in (rows as List)) {
        final adm = (s['stuadmno']?.toString() ?? '').trim();
        if (adm.isEmpty) continue;
        map[norm(adm)] = {
          'stuclass': (s['stuclass']?.toString() ?? '').trim(),
          'courname': (s['courname']?.toString() ?? '').trim(),
        };
      }
      if (mounted) setState(() => _importStudentByAdmno = map);
    } catch (e) {
      debugPrint('Load student master failed: $e');
    }
  }

  /// Per-field validation. Returns fieldKey → reason for every cell that
  /// failed (empty map ⇒ row passes).
  Map<String, String> _validateRowFields(int rowIdx) {
    final row = _rows[rowIdx];
    final errors = <String, String>{};
    for (final reqKey in _requiredFields) {
      final colIdx = _mappings.indexOf(reqKey);
      if (colIdx < 0 || colIdx >= row.length || row[colIdx].toString().trim().isEmpty) {
        errors[reqKey] = 'Required';
      }
    }
    final ft = _cellByKey(row, 'demfeetype');
    if (ft != null && _feeTypes.isNotEmpty) {
      final ftLower = ft.toLowerCase();
      if (!_feeTypes.any((f) => f.toLowerCase() == ftLower)) {
        errors['demfeetype'] = 'Fee Type "$ft" not found — import it first';
      }
    }
    String norm(String s) => s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    final admRaw = _cellByKey(row, 'stuadmno');
    if (admRaw != null && _importStudentByAdmno.isNotEmpty) {
      final student = _importStudentByAdmno[norm(admRaw)];
      if (student == null) {
        errors['stuadmno'] = 'Roll No "$admRaw" not found in students master';
      } else {
        final clsRaw = _cellByKey(row, 'stuclass');
        if (clsRaw != null && (student['stuclass'] ?? '').isNotEmpty
            && norm(clsRaw) != norm(student['stuclass']!)) {
          errors['stuclass'] = 'Class "$clsRaw" doesn\'t match student (registered as "${student['stuclass']}")';
        }
        final courRaw = _cellByKey(row, 'courname');
        if (courRaw != null && (student['courname'] ?? '').isNotEmpty
            && norm(courRaw) != norm(student['courname']!)) {
          errors['courname'] = 'Course "$courRaw" doesn\'t match student (registered as "${student['courname']}")';
        }
      }
    }
    return errors;
  }

  /// Back-compat single-string helper, used by the staging-build save path.
  String? _validateRow(int rowIdx) {
    final fields = _validateRowFields(rowIdx);
    if (fields.isEmpty) return null;
    return _composeRowError(fields);
  }

  String _composeRowError(Map<String, String> fields) {
    final missing = <String>[];
    final detail = <String>[];
    fields.forEach((k, v) {
      if (v == 'Required') {
        missing.add(_importFieldLabels[k] ?? k);
      } else {
        detail.add(v);
      }
    });
    final parts = <String>[];
    if (missing.isNotEmpty) parts.add('Missing: ${missing.join(', ')}');
    parts.addAll(detail);
    return parts.join(' • ');
  }

  String? _cellByKey(List<dynamic> row, String fieldKey) {
    final idx = _mappings.indexOf(fieldKey);
    if (idx < 0 || idx >= row.length) return null;
    final v = row[idx].toString().trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _startImport() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId ?? 1;
    final now = DateTime.now().toIso8601String();

    final masterData = await SupabaseService.checkMasterData(insId);
    if (!masterData.hasFeeTypes || !masterData.hasClassFeeDemand) {
      if (mounted) {
        final missing = <String>[];
        if (!masterData.hasFeeTypes) missing.add('Fee Types');
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

    setState(() {
      _importStep = 2;
      _imported = 0;
      _skipped = 0;
      _total = _rows.length;
      _importErrors = [];
    });

    // 1. Pre-fetch all student admno -> stu_id mappings.
    // Index under multiple normalisations because Excel often loses
    // leading zeros and adds whitespace to admission numbers.
    final stuList = await SupabaseService.fromSchema('students')
        .select('stu_id, stuadmno')
        .eq('ins_id', insId)
        .eq('activestatus', 1);
    final stuMap = <String, int>{};
    for (final s in stuList) {
      final raw = s['stuadmno']?.toString().trim() ?? '';
      final id  = s['stu_id'] as int?;
      if (raw.isEmpty || id == null) continue;
      // Original, lowercase, leading-zero stripped, leading-zero stripped+lower.
      stuMap.putIfAbsent(raw, () => id);
      stuMap.putIfAbsent(raw.toLowerCase(), () => id);
      final stripped = raw.replaceFirst(RegExp(r'^0+'), '');
      if (stripped.isNotEmpty) {
        stuMap.putIfAbsent(stripped, () => id);
        stuMap.putIfAbsent(stripped.toLowerCase(), () => id);
      }
    }

    // 2. Pre-fetch concession name -> con_id mappings
    final conMap = <String, int>{};
    for (final c in _concessions) {
      final desc = c['condesc']?.toString().toUpperCase() ?? '';
      final id = c['con_id'] as int?;
      if (desc.isNotEmpty && id != null) conMap[desc] = id;
    }

    // 3. Build all rows in memory
    final batch = <Map<String, dynamic>>[];
    for (int i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      final err = _validateRow(i);
      if (err != null) {
        _skipped++;
        _importErrors.add('Row ${i + 2}: $err');
        continue;
      }

      try {
        final feeAmount = double.tryParse(_cellByKey(row, 'feeamount') ?? '0') ?? 0;
        final conAmount = double.tryParse(_cellByKey(row, 'conamount') ?? '0') ?? 0;

        final yrRaw = _cellByKey(row, 'yr_id');
        int? yrId;
        String? yrLabel;

        final yrInt = int.tryParse(yrRaw ?? '');
        if (yrInt != null) {
          final byId = _years.firstWhere(
            (y) => y['yr_id'] == yrInt,
            orElse: () => <String, dynamic>{},
          );
          if (byId.isNotEmpty) {
            yrId = yrInt;
            yrLabel = byId['yrlabel']?.toString();
          }
        }
        if (yrId == null && yrRaw != null) {
          final byLabel = _years.firstWhere(
            (y) => y['yrlabel']?.toString() == yrRaw,
            orElse: () => <String, dynamic>{},
          );
          if (byLabel.isNotEmpty) {
            yrId = byLabel['yr_id'] as int?;
            yrLabel = byLabel['yrlabel']?.toString();
          }
        }
        if (yrId == null && yrRaw != null) {
          final byPartial = _years.firstWhere(
            (y) => y['yrlabel']?.toString().startsWith(yrRaw) == true,
            orElse: () => <String, dynamic>{},
          );
          if (byPartial.isNotEmpty) {
            yrId = byPartial['yr_id'] as int?;
            yrLabel = byPartial['yrlabel']?.toString();
          }
        }
        // Final fallback: if there's exactly one year configured, use it.
        // This handles Excel files where yr_id is missing or has values like
        // '2025', 'Year 1', etc. that don't match anything in the year table.
        if (yrId == null && _years.isNotEmpty) {
          yrId = _years.first['yr_id'] as int?;
          yrLabel = _years.first['yrlabel']?.toString();
        }

        final admNoRaw = _cellByKey(row, 'stuadmno')?.trim() ?? '';
        // Try direct, lowercase, and leading-zero-stripped variants
        // before giving up — same normalisations applied to the map.
        int? stuId = stuMap[admNoRaw];
        if (stuId == null && admNoRaw.isNotEmpty) {
          stuId = stuMap[admNoRaw.toLowerCase()];
          stuId ??= stuMap[admNoRaw.replaceFirst(RegExp(r'^0+'), '')];
          stuId ??= stuMap[admNoRaw.replaceFirst(RegExp(r'^0+'), '').toLowerCase()];
        }
        if (stuId == null) {
          _skipped++;
          _importErrors.add('Row ${i + 2}: Roll No "$admNoRaw" not found in active students');
          continue;
        }

        final conName = _cellByKey(row, 'con_id');
        int? conId;
        if (conName != null && conName.isNotEmpty) {
          conId = int.tryParse(conName) ?? conMap[conName.toUpperCase()];
        }

        final data = {
          'ins_id': insId,
          'inscode': auth.inscode ?? '',
          'demno': _cellByKey(row, 'demno'),
          'stuadmno': admNoRaw,
          'stu_id': stuId,
          'stuclass': _cellByKey(row, 'stuclass'),
          'courname': _cellByKey(row, 'courname'),
          'demfeetype': _cellByKey(row, 'demfeetype'),
          'yr_id': yrId,
          'demfeeyear': yrLabel ?? yrRaw ?? '',
          'demfeeterm': _cellByKey(row, 'demfeeterm'),
          'con_id': conId,
          'feeamount': feeAmount,
          'conamount': conAmount,
          'balancedue': feeAmount,
          'duedate': _cellByKey(row, 'duedate'),
          'activestatus': 1,
          'createdat': now,
          'createdby': auth.userName,
          'isapproved': false,
        };
        data.removeWhere((k, v) => v == null);
        batch.add(data);
      } catch (e) {
        _skipped++;
        _importErrors.add('Row ${i + 2}: ${_friendlyError(e.toString())}');
      }
    }

    setState(() {});

    // 4. Bulk insert in small batches (Supabase REST has payload limits and
    // long requests time out, so 100/batch is the sweet spot for big imports).
    const int batchSize = 100;
    for (int i = 0; i < batch.length; i += batchSize) {
      final chunk = batch.sublist(i, (i + batchSize).clamp(0, batch.length));
      try {
        await SupabaseService.fromSchema('tempfeedemand').insert(chunk);
        _imported += chunk.length;
      } catch (e) {
        debugPrint('Batch insert failed at $i: $e');
        // Halve the batch on first failure, then per-row as last resort
        try {
          final mid = chunk.length ~/ 2;
          await SupabaseService.fromSchema('tempfeedemand').insert(chunk.sublist(0, mid));
          await SupabaseService.fromSchema('tempfeedemand').insert(chunk.sublist(mid));
          _imported += chunk.length;
        } catch (_) {
          for (final row in chunk) {
            try {
              await SupabaseService.fromSchema('tempfeedemand').insert(row);
              _imported++;
            } catch (e2) {
              _skipped++;
              _importErrors.add('Adm ${row['stuadmno']}: ${_friendlyError(e2.toString())}');
            }
          }
        }
      }
      if (mounted) setState(() {});
    }

    setState(() => _importStep = 3);
    _loadFeeDemands();
  }

  void _resetImport() {
    setState(() {
      _showImport = false;
      _importStep = 0;
      _fileName = null;
      _headers = [];
      _rows = [];
      _mappings = [];
      _imported = 0;
      _skipped = 0;
      _total = 0;
      _importErrors = [];
      _errorMsg = null;
      _rowErrors = {};
    });
  }

  static String _friendlyError(String msg) {
    final m = msg.toLowerCase();
    if (m.contains('duplicate key') || m.contains('unique constraint')) return 'Duplicate record found';
    if (m.contains('not-null') || m.contains('null value')) {
      final match = RegExp(r'column "(\w+)"').firstMatch(msg);
      return '${match?.group(1) ?? 'Field'} is required';
    }
    if (m.contains('foreign key') || m.contains('fkey')) return 'Invalid reference - check linked values';
    if (m.contains('check constraint')) return 'Invalid value format';
    if (m.contains('value too long')) return 'Value too long for the field';
    if (m.contains('invalid input syntax')) return 'Invalid data format';
    if (m.contains('permission denied')) return 'Permission denied';
    return msg.length > 80 ? '${msg.substring(0, 80)}...' : msg;
  }

  // ─── UI ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          // Card header with title, buttons, breadcrumb, and search.
          // Hidden entirely while import is active — the import panel has
          // its own Back button to return.
          if (!_showImport) Container(
            padding: EdgeInsets.fromLTRB(16.w, 10.h, 16.w, 0),
            child: Row(
              children: [
                if (_drilldownClass == null && _drilldownStudent == null) ...[
                  AppIcon('receipt-edit', color: AppColors.accent, size: 18),
                  SizedBox(width: 10.w),
                  Text('Fee Demand', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ],
                if (!_showImport) ...[
                  if (_drilldownClass != null || _drilldownStudent != null) ...[
                    // Back button — solid accent pill
                    InkWell(
                      onTap: () => setState(() {
                        if (_drilldownStudent != null) {
                          _drilldownStudent = null;
                          _drilldownStudentName = null;
                        } else {
                          _drilldownClass = null;
                          _drilldownDemands = [];
                        }
                        _searchQuery = '';
                        _searchController.clear();
                      }),
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
                    // Breadcrumb path (plain text, not button-like)
                    Text('Fee Demand', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                    SizedBox(width: 6.w),
                    AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                    SizedBox(width: 6.w),
                    if (_drilldownStudent != null) ...[
                      Text('${_drilldownCourse != null ? '$_drilldownCourse > ' : ''}$_drilldownClass', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                      SizedBox(width: 6.w),
                      AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                      SizedBox(width: 6.w),
                      Text(
                        '${_drilldownStudentName ?? ''} (${_drilldownStudent})',
                        style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                      ),
                    ] else
                      Text(
                        'Class $_drilldownClass',
                        style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                      ),
                  ] else ...[
                    SizedBox(width: 16.w),
                    Text(
                      '${_classSummary.fold<int>(0, (sum, c) => sum + ((c['student_count'] as num?)?.toInt() ?? 0))} students',
                      style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
                    ),
                  ],
                ],
                const Spacer(),
                if (!_showImport) ...[
                  AppSearchField(
                    controller: _searchController,
                    hintText: 'Search by class...',
                    onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
                    width: 260.w,
                    suffixIcon: _searchQuery.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: IconButton(
                              icon: const AppIcon('close-circle', size: 14),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                              splashRadius: 12,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          )
                        : null,
                  ),
                  SizedBox(width: 16.w),
                ],
                Builder(builder: (context) {
                  // Hide the Import CSV/Excel button for institution Admin role.
                  // Admins manage / approve demands; imports are an accountant
                  // / super-admin action.
                  final role = context.read<AuthProvider>().currentUser?.urname ?? '';
                  if (role.toLowerCase() == 'admin') return const SizedBox.shrink();
                  final compact = MediaQuery.of(context).size.width <= 1366;
                  final btnHeight = compact ? 30.0 : 40.0;
                  final iconSize = compact ? 12.0 : 16.0;
                  final hPad = compact ? 10.0 : 18.0;
                  final radius = compact ? 6.0 : 10.0;
                  final textSize = compact ? 11.0 : 13.0;
                  return SizedBox(
                    height: btnHeight,
                    child: ElevatedButton.icon(
                      onPressed: () => setState(() {
                        _showImport = !_showImport;
                        if (!_showImport) _resetImport();
                      }),
                      icon: AppIcon(_showImport ? 'close-circle' : 'document-upload', size: iconSize, color: Colors.white),
                      label: Text(_showImport ? 'Close Import' : 'Import CSV/Excel'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _showImport ? AppColors.error : AppColors.accent,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: EdgeInsets.symmetric(horizontal: hPad),
                        textStyle: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
                      ),
                    ),
                  );
                }),
                if (!_showImport) ...[
                  SizedBox(width: 8.w),
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
                        onPressed: _loadFeeDemands,
                        icon: AppIcon('refresh', size: iconSize, color: Colors.white),
                        label: const Text('Refresh'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: EdgeInsets.symmetric(horizontal: hPad),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
                          textStyle: TextStyle(fontSize: textSize, fontWeight: FontWeight.w600),
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),

          // Content
          Expanded(
            child: _showImport ? _buildImportSection() : _buildMainContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return _buildDemandsList();
  }

  Widget _buildForm() {
    return Container(
      padding: EdgeInsets.all(20.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: AppColors.border),
      ),
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        AppIcon('receipt-2', size: 18, color: AppColors.accent),
                        SizedBox(width: 8.w),
                        Text('Add Fee Demand', style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    SizedBox(height: 20.h),

                    // Admission No
                    _buildLabel('Roll No *'),
                    TextFormField(
                      controller: _admNoController,
                      decoration: _inputDecoration('Enter admission number'),
                      style: TextStyle(fontSize: 13.sp),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                      onChanged: (v) => _lookupStudentClass(v.trim()),
                    ),
                    SizedBox(height: 16.h),

                    // Class
                    _buildLabel('Class'),
                    Builder(builder: (_) {
                      final seen = <String>{};
                      final items = <DropdownMenuItem<String>>[];
                      for (final c in _classes) {
                        if (c.isEmpty || !seen.add(c)) continue;
                        items.add(DropdownMenuItem(value: c, child: Text(c)));
                      }
                      final value = seen.contains(_selectedClass) ? _selectedClass : null;
                      return DropdownButtonFormField<String>(
                        value: value,
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 6,
                        decoration: _inputDecoration('Select class'),
                        items: items,
                        onChanged: (v) => setState(() => _selectedClass = v),
                        style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                      );
                    }),
                    SizedBox(height: 16.h),

                    // Fee Type
                    _buildLabel('Fee Type *'),
                    Builder(builder: (_) {
                      final seen = <String>{};
                      final items = <DropdownMenuItem<String>>[];
                      for (final f in _feeTypes) {
                        if (f.isEmpty || !seen.add(f)) continue;
                        items.add(DropdownMenuItem(value: f, child: Text(f)));
                      }
                      final value = seen.contains(_selectedFeeType) ? _selectedFeeType : null;
                      return DropdownButtonFormField<String>(
                        value: value,
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 6,
                        decoration: _inputDecoration('Select fee type'),
                        items: items,
                        onChanged: (v) => setState(() => _selectedFeeType = v),
                        validator: (v) => v == null ? 'Required' : null,
                        style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                      );
                    }),
                    SizedBox(height: 16.h),

                    // Fee Year & Fee Term (side by side)
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Fee Year'),
                              Builder(builder: (_) {
                                final seen = <String>{};
                                final items = <DropdownMenuItem<String>>[];
                                for (final y in _years) {
                                  final v = y['yr_id']?.toString();
                                  if (v == null || v.isEmpty || !seen.add(v)) continue;
                                  items.add(DropdownMenuItem(value: v, child: Text(y['yrlabel']?.toString() ?? '-')));
                                }
                                final value = seen.contains(_selectedFeeYear) ? _selectedFeeYear : null;
                                return DropdownButtonFormField<String>(
                                  value: value,
                                  dropdownColor: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  elevation: 6,
                                  decoration: _inputDecoration('Select year'),
                                  items: items,
                                  onChanged: (v) => setState(() => _selectedFeeYear = v),
                                  style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                                );
                              }),
                            ],
                          ),
                        ),
                        SizedBox(width: 12.w),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Semester'),
                              TextFormField(
                                controller: _feeTermController,
                                decoration: _inputDecoration('Enter term'),
                                style: TextStyle(fontSize: 13.sp),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16.h),

                    // Concession
                    _buildLabel('Concession'),
                    Builder(builder: (_) {
                      final seen = <String>{};
                      final items = <DropdownMenuItem<String>>[];
                      for (final c in _concessions) {
                        final v = c['con_id']?.toString();
                        if (v == null || !seen.add(v)) continue;
                        items.add(DropdownMenuItem(value: v, child: Text(c['condesc']?.toString() ?? '-')));
                      }
                      final value = seen.contains(_selectedConcession) ? _selectedConcession : null;
                      return DropdownButtonFormField<String>(
                        value: value,
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 6,
                        decoration: _inputDecoration('Select concession'),
                        items: items,
                        onChanged: (v) => setState(() => _selectedConcession = v),
                        style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary),
                      );
                    }),
                    SizedBox(height: 16.h),

                    // Fee Amount & Concession Amount (side by side)
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Fee Amount *'),
                              TextFormField(
                                controller: _feeAmountController,
                                decoration: _inputDecoration('Enter amount'),
                                keyboardType: TextInputType.number,
                                style: TextStyle(fontSize: 13.sp),
                                validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 12.w),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Concession Amount'),
                              TextFormField(
                                controller: _conAmountController,
                                decoration: _inputDecoration('Enter amount'),
                                keyboardType: TextInputType.number,
                                style: TextStyle(fontSize: 13.sp),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16.h),

                    // Due Date
                    _buildLabel('Due Date'),
                    InkWell(
                      onTap: _pickDueDate,
                      borderRadius: BorderRadius.circular(10.r),
                      child: InputDecorator(
                        decoration: _inputDecoration('').copyWith(
                          suffixIcon: AppIcon('calendar-1', size: 18, color: AppColors.textSecondary),
                        ),
                        child: Text(
                          _dueDate != null
                              ? '${_dueDate!.day.toString().padLeft(2, '0')}/${_dueDate!.month.toString().padLeft(2, '0')}/${_dueDate!.year}'
                              : 'Select date',
                          style: TextStyle(fontSize: 13.sp, color: _dueDate != null ? AppColors.textPrimary : Colors.grey.shade400),
                        ),
                      ),
                    ),
                    SizedBox(height: 24.h),

                    // Buttons
                    Builder(builder: (_) {
                      const btnHeight = 48.0;
                      final btnPadding = EdgeInsets.symmetric(horizontal: 28.w);
                      return Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: btnHeight,
                              child: OutlinedButton.icon(
                                onPressed: _resetForm,
                                icon: const AppIcon('refresh', size: 16, color: AppColors.textPrimary),
                                label: const Text('Clear', style: TextStyle(fontWeight: FontWeight.w600)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.textPrimary,
                                  side: const BorderSide(color: AppColors.border),
                                  padding: btnPadding,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 12.w),
                          Expanded(
                            flex: 2,
                            child: SizedBox(
                              height: btnHeight,
                              child: ElevatedButton.icon(
                                onPressed: _isSaving ? null : _saveDemand,
                                icon: _isSaving
                                    ? SizedBox(width: 18.w, height: 18.h, child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : AppIcon('save-2', size: 18),
                                label: Text(_isSaving ? 'Saving...' : 'Save Fee Demand', style: const TextStyle(fontWeight: FontWeight.w600)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: Colors.white,
                                  padding: btnPadding,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: 6.h),
      child: Text(
        text,
        style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 13.sp, color: Colors.grey.shade400),
      contentPadding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10.r),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10.r),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10.r),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      filled: true,
      fillColor: AppColors.surface,
    );
  }

  Widget _buildDemandsList() {
    return _loadingDemands
        ? const Center(child: CircularProgressIndicator())
        : _drilldownStudent != null
            ? _buildStudentFeeDetails()
            : _drilldownClass != null
                ? _buildDrilldownView()
                : _buildClassCards();
  }

  List<Map<String, dynamic>> get _filteredClassSummary {
    if (_searchQuery.isEmpty) return _classSummary;
    return _classSummary.where((c) {
      final cls = c['stuclass']?.toString().toLowerCase() ?? '';
      final course = c['courname']?.toString().toLowerCase() ?? '';
      return cls.contains(_searchQuery) || course.contains(_searchQuery);
    }).toList();
  }

  List<Map<String, dynamic>> get _filteredDrilldownDemands {
    final source = _drilldownDemands;
    if (_searchQuery.isEmpty) return source;
    return source.where((d) {
      final admNo = d['stuadmno']?.toString().toLowerCase() ?? '';
      final feeType = d['demfeetype']?.toString().toLowerCase() ?? '';
      final term = d['demfeeterm']?.toString().toLowerCase() ?? '';
      return admNo.contains(_searchQuery) || feeType.contains(_searchQuery) || term.contains(_searchQuery);
    }).toList();
  }

  /// Aggregate drilldown demands by student for the intermediate student-wise view
  List<Map<String, dynamic>> get _studentSummary {
    final Map<String, Map<String, dynamic>> grouped = {};
    for (final d in _drilldownDemands) {
      final admNo = d['stuadmno']?.toString() ?? '-';
      if (!grouped.containsKey(admNo)) {
        grouped[admNo] = {
          'stuadmno': admNo,
          'stuname': d['stuname'] ?? d['studentname'] ?? '',
          'courname': d['courname']?.toString(),
          'total_demand': 0.0,
          'total_concession': 0.0,
          'total_paid': 0.0,
          'total_pending': 0.0,
          'total_fine': 0.0,
          'demand_count': 0,
          'paid_count': 0,
          'unpaid_count': 0,
        };
      }
      final g = grouped[admNo]!;
      final amt = (d['feeamount'] as num?)?.toDouble() ?? 0;
      final con = (d['conamount'] as num?)?.toDouble() ?? 0;
      final pa = (d['paidamount'] as num?)?.toDouble() ?? 0;
      final fa = (d['fineamount'] as num?)?.toDouble() ?? 0;
      // Use reconbalancedue (post-recon outstanding); fall back to balancedue.
      // Paid = paidamount - fineamount when reconciled, else 0.
      final bal = (d['reconbalancedue'] as num?)?.toDouble()
          ?? (d['balancedue'] as num?)?.toDouble() ?? amt;
      final isFullyReconciled = bal <= 0;
      final paid = isFullyReconciled ? (pa - fa) : 0.0;
      g['total_demand'] = (g['total_demand'] as double) + amt;
      g['total_concession'] = (g['total_concession'] as double) + con;
      g['total_paid'] = (g['total_paid'] as double) + paid;
      g['total_fine'] = (g['total_fine'] as double) + (isFullyReconciled ? fa : 0);
      g['total_pending'] = (g['total_pending'] as double) + bal;
      g['demand_count'] = (g['demand_count'] as int) + 1;
      if (isFullyReconciled) {
        g['paid_count'] = (g['paid_count'] as int) + 1;
      } else {
        g['unpaid_count'] = (g['unpaid_count'] as int) + 1;
      }
    }
    final list = grouped.values.toList();
    if (_searchQuery.isNotEmpty) {
      return list.where((s) {
        final admNo = s['stuadmno']?.toString().toLowerCase() ?? '';
        final name = s['stuname']?.toString().toLowerCase() ?? '';
        return admNo.contains(_searchQuery) || name.contains(_searchQuery);
      }).toList();
    }
    return list;
  }

  /// Fee demands for the selected student
  List<Map<String, dynamic>> get _filteredStudentDemands {
    if (_drilldownStudent == null) return [];
    final source = _drilldownDemands.where((d) => d['stuadmno']?.toString() == _drilldownStudent).toList();
    if (_searchQuery.isEmpty) return source;
    return source.where((d) {
      final feeType = d['demfeetype']?.toString().toLowerCase() ?? '';
      final term = d['demfeeterm']?.toString().toLowerCase() ?? '';
      return feeType.contains(_searchQuery) || term.contains(_searchQuery);
    }).toList();
  }

  Widget _buildClassCards() {
    final summaries = _filteredClassSummary;
    if (summaries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon('message-text', size: 48.sp, color: AppColors.textSecondary.withValues(alpha: 0.4)),
            SizedBox(height: 8.h),
            const Text('No fee demands found', style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            // Table header + rows, sharing a reserved scrollbar lane
            Expanded(
              child: AppVerticalScrollbar(
                header: Container(
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
              color: AppColors.tableHeadBg,
              child: Row(
                children: [
                  Expanded(child: Text('COURSE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                  Expanded(child: Text('CLASS', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                  Expanded(child: Text('STUDENTS', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.center)),
                  Expanded(child: Text('TOTAL DEMAND', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.right)),
                  Expanded(child: Text('COLLECTED', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.right)),
                  Expanded(child: Text('FINE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.right)),
                  Expanded(child: Text('PENDING', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.right)),
                  SizedBox(width: 32.w),
                ],
              ),
            ),
                builder: (context, controller) => ListView.separated(
                controller: controller,
                padding: EdgeInsets.zero,
                itemCount: summaries.length,
                separatorBuilder: (_, __) => const SizedBox.shrink(),
                itemBuilder: (context, i) {
                  final s = summaries[i];
                  final className = s['stuclass']?.toString() ?? '-';
                  final studentCount = (s['student_count'] as num?)?.toInt() ?? 0;
                  final totalDemand = (s['total_demand'] as num?)?.toDouble() ?? 0;
                  final totalPaid = (s['total_paid'] as num?)?.toDouble() ?? 0;
                  final totalFine = (s['total_fine'] as num?)?.toDouble() ?? 0;
                  final totalPending = (s['total_pending'] as num?)?.toDouble() ?? 0;

                  return InkWell(
                    onTap: () => _loadDrilldown(className, courseName: s['courname']?.toString()),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                      color: i.isEven ? Colors.white : AppColors.surface,
                      child: Row(
                        children: [
                          Expanded(child: Text(s['courname']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                          Expanded(child: Text(className, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                          Expanded(child: Text('$studentCount', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary), textAlign: TextAlign.center)),
                          Expanded(child: Text('${_formatAmount(totalDemand)}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary), textAlign: TextAlign.right)),
                          Expanded(child: Text('${_formatAmount(totalPaid)}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.success), textAlign: TextAlign.right)),
                          Expanded(child: Text(totalFine > 0 ? '${_formatAmount(totalFine)}' : '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: totalFine > 0 ? Colors.orange : AppColors.textSecondary), textAlign: TextAlign.right)),
                          Expanded(child: Text('${_formatAmount(totalPending)}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.warning), textAlign: TextAlign.right)),
                          SizedBox(width: 32.w, child: AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                  );
                },
              ),
              ),
            ),
            // Total footer row
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
              decoration: BoxDecoration(
                color: AppColors.tableHeadBg,
                border: const Border(top: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                children: [
                  Expanded(child: Text('TOTAL', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                  const Expanded(child: SizedBox.shrink()),
                  Expanded(child: Text('${summaries.fold<int>(0, (sum, s) => sum + ((s['student_count'] as num?)?.toInt() ?? 0))}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary), textAlign: TextAlign.center)),
                  Expanded(child: Text('${_formatAmount(summaries.fold<double>(0, (sum, s) => sum + ((s['total_demand'] as num?)?.toDouble() ?? 0)))}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary), textAlign: TextAlign.right)),
                  Expanded(child: Text('${_formatAmount(summaries.fold<double>(0, (sum, s) => sum + ((s['total_paid'] as num?)?.toDouble() ?? 0)))}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.success), textAlign: TextAlign.right)),
                  Expanded(child: Text('${_formatAmount(summaries.fold<double>(0, (sum, s) => sum + ((s['total_fine'] as num?)?.toDouble() ?? 0)))}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: Colors.orange), textAlign: TextAlign.right)),
                  Expanded(child: Text('${_formatAmount(summaries.fold<double>(0, (sum, s) => sum + ((s['total_pending'] as num?)?.toDouble() ?? 0)))}', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w700, color: AppColors.warning), textAlign: TextAlign.right)),
                  SizedBox(width: 32.w),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDueDate(String dateStr) {
    if (dateStr == '-' || dateStr.isEmpty) return '-';
    try {
      final dt = DateTime.parse(dateStr);
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${dt.day.toString().padLeft(2, '0')}-${months[dt.month - 1]}-${dt.year}';
    } catch (_) {
      return dateStr;
    }
  }

  String _formatAmount(double amount) => formatIndianNumber(amount);

  /// Level 2: Student-wise summary for selected class
  Widget _buildDrilldownView() {
    if (_loadingDrilldown) {
      return const Center(child: CircularProgressIndicator());
    }

    final students = _studentSummary;
    if (students.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon('message-text', size: 48.sp, color: AppColors.textSecondary.withValues(alpha: 0.4)),
            SizedBox(height: 8.h),
            Text(
              _searchQuery.isNotEmpty ? 'No matching students' : 'No students found',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: AppColors.border),
        ),
        child: AppVerticalScrollbar(
                header: Container(
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                color: AppColors.tableHeadBg,
                child: Row(
                  children: [
                    Expanded(flex: 1, child: Text('ROLL NO', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                    Expanded(flex: 2, child: Text('NAME', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                    Expanded(flex: 1, child: Text('COURSE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3))),
                    Expanded(flex: 1, child: Text('DEMAND', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('PAID', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('FINE', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('PENDING', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('STATUS', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3), textAlign: TextAlign.center)),
                    SizedBox(width: 28.w),
                  ],
                ),
              ),
                builder: (context, controller) => ListView.separated(
                  controller: controller,
                  padding: EdgeInsets.zero,
                  itemCount: students.length,
                  separatorBuilder: (_, __) => const SizedBox.shrink(),
                  itemBuilder: (context, i) {
                    final s = students[i];
                    final admNo = s['stuadmno']?.toString() ?? '-';
                    final name = s['stuname']?.toString() ?? '';
                    final totalDemand = (s['total_demand'] as double?) ?? 0;
                    final totalPaid = (s['total_paid'] as double?) ?? 0;
                    final totalFine = (s['total_fine'] as double?) ?? 0;
                    final totalPending = (s['total_pending'] as double?) ?? 0;
                    final unpaidCount = (s['unpaid_count'] as int?) ?? 0;
                    final allPaid = unpaidCount == 0;

                    return InkWell(
                      onTap: () => setState(() {
                        _drilldownStudent = admNo;
                        _drilldownStudentName = name;
                        _searchQuery = '';
                        _searchController.clear();
                      }),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 6.h),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 1,
                              child: Text(admNo, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                name.isNotEmpty ? name : '-',
                                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text(s['courname']?.toString() ?? '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text('${_formatAmount(totalDemand)}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary), textAlign: TextAlign.right),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text('${_formatAmount(totalPaid)}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.success), textAlign: TextAlign.right),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text(totalFine > 0 ? '${_formatAmount(totalFine)}' : '-', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: totalFine > 0 ? Colors.orange : AppColors.textSecondary), textAlign: TextAlign.right),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text('${_formatAmount(totalPending)}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: totalPending > 0 ? AppColors.warning : AppColors.success), textAlign: TextAlign.right),
                            ),
                            Expanded(
                              flex: 1,
                              child: Center(
                                child: Container(
                                  padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 3.h),
                                  decoration: BoxDecoration(
                                    color: allPaid ? AppColors.success.withValues(alpha: 0.1) : AppColors.warning.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(6.r),
                                  ),
                                  child: Text(
                                    allPaid ? 'Paid' : 'Unpaid',
                                    style: TextStyle(fontSize: 10.sp, fontWeight: FontWeight.w600, color: allPaid ? AppColors.success : AppColors.warning),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: 28.w, child: AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
        ),
      );
  }

  /// Level 3: Individual fee details for selected student
  static const _termOrder = [
    'I TERM', 'II TERM', 'III TERM',
    'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER',
    'NOVEMBER', 'DECEMBER', 'JANUARY', 'FEBRUARY', 'MARCH',
    'APRIL', 'MAY',
  ];

  int _termIndex(String term) {
    final idx = _termOrder.indexOf(term.toUpperCase());
    return idx >= 0 ? idx : _termOrder.length;
  }

  Widget _buildStudentFeeDetails() {
    final demands = List<Map<String, dynamic>>.from(_filteredStudentDemands)
      ..sort((a, b) {
        final ta = a['demfeeterm']?.toString() ?? '';
        final tb = b['demfeeterm']?.toString() ?? '';
        final ftA = a['demfeetype']?.toString() ?? '';
        final ftB = b['demfeetype']?.toString() ?? '';
        final cmp = ftA.compareTo(ftB);
        if (cmp != 0) return cmp;
        return _termIndex(ta).compareTo(_termIndex(tb));
      });
    if (demands.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon('message-text', size: 48.sp, color: AppColors.textSecondary.withValues(alpha: 0.4)),
            SizedBox(height: 8.h),
            Text(
              _searchQuery.isNotEmpty ? 'No matching records' : 'No fee demands found',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    double totalAmt = 0, totalPaid = 0, totalFine = 0, totalBal = 0;
    for (final d in demands) {
      totalAmt += (d['feeamount'] as num?)?.toDouble() ?? 0;
      final pa = (d['paidamount'] as num?)?.toDouble() ?? 0;
      final fa = (d['fineamount'] as num?)?.toDouble() ?? 0;
      final status = d['paidstatus']?.toString() ?? 'U';
      final isPaid = pa > 0 || status == 'P' || status == 'Paid';
      totalPaid += pa - (isPaid ? fa : 0);
      totalFine += isPaid ? fa : 0;
      totalBal += (d['balancedue'] as num?)?.toDouble() ?? 0;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Builder(builder: (context) {
          const flexes = <int>[1, 2, 3, 2, 2, 2, 2, 2, 2];
          const headers = <String>[
            'S No.', 'SEMESTER', 'FEE TYPE', 'AMOUNT', 'PAID',
            'FINE', 'BALANCE', 'DUE DATE', 'STATUS',
          ];
          final hStyle = TextStyle(
              fontSize: 12.sp,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
              letterSpacing: 0.3);
          final cStyle = TextStyle(
              fontSize: 13.sp,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary);
          final tStyle = TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14.sp,
              color: AppColors.textPrimary);
          // AMOUNT/PAID/FINE/BALANCE are right-aligned.
          bool rightAlign(int i) => i >= 3 && i <= 6;
          Widget cell(int i, Widget child) => Expanded(
                flex: flexes[i],
                child: Align(
                  alignment: rightAlign(i)
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: child,
                ),
              );
          return Column(
            children: [
              // Sticky header.
              Container(
                color: AppColors.tableHeadBg,
                padding:
                    EdgeInsets.symmetric(horizontal: 20, vertical: 12.h),
                child: Row(children: [
                  for (int i = 0; i < headers.length; i++)
                    cell(i, Text(headers[i], style: hStyle)),
                ]),
              ),
              Container(height: 1, color: AppColors.border),
              // Scrolling body.
              Expanded(
                child: AppVerticalScrollbar(
                  builder: (context, sc) => ListView.separated(
                  controller: sc,
                  itemCount: demands.length,
                  separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: AppColors.border.withValues(alpha: 0.5)),
                  itemBuilder: (_, i) {
                    final d = demands[i];
                    final term = d['demfeeterm']?.toString() ?? '-';
                    final feeType = d['demfeetype']?.toString() ?? '-';
                    final amt = (d['feeamount'] as num?)?.toDouble() ?? 0;
                    final pa = (d['paidamount'] as num?)?.toDouble() ?? 0;
                    final fa = (d['fineamount'] as num?)?.toDouble() ?? 0;
                    final status = d['paidstatus']?.toString() ?? 'U';
                    final isPaid =
                        pa > 0 || status == 'P' || status == 'Paid';
                    final paid = pa - (isPaid ? fa : 0);
                    final fineDisplay = isPaid ? fa : 0.0;
                    final bal = (d['balancedue'] as num?)?.toDouble() ?? 0;
                    final dueDate = d['duedate']?.toString() ?? '-';
                    final formattedDueDate = _formatDueDate(dueDate);
                    return Container(
                      color: i.isEven ? Colors.white : AppColors.surface,
                      padding: EdgeInsets.symmetric(
                          horizontal: 20, vertical: 6.h),
                      child: Row(children: [
                        cell(0, Text('${i + 1}', style: cStyle)),
                        cell(1, Text(term, style: cStyle)),
                        cell(2, Text(feeType, style: cStyle)),
                        cell(3,
                            Text('${_formatAmount(amt)}', style: cStyle)),
                        cell(
                            4,
                            Text('${_formatAmount(paid)}',
                                style: cStyle)),
                        cell(
                            5,
                            Text(
                                fineDisplay > 0
                                    ? '${_formatAmount(fineDisplay)}'
                                    : '-',
                                style: fineDisplay > 0
                                    ? TextStyle(
                                        fontSize: 13.sp,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.orange)
                                    : cStyle)),
                        cell(
                            6,
                            Text('${_formatAmount(bal)}',
                                style: cStyle)),
                        cell(7, Text(formattedDueDate, style: cStyle)),
                        cell(
                            8,
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isPaid
                                    ? AppColors.success
                                        .withValues(alpha: 0.1)
                                    : AppColors.warning
                                        .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8.r),
                              ),
                              child: Text(isPaid ? 'Paid' : 'Pending',
                                  style: TextStyle(
                                      fontSize: 12.sp,
                                      fontWeight: FontWeight.w700,
                                      color: isPaid
                                          ? AppColors.success
                                          : AppColors.warning)),
                            )),
                      ]),
                    );
                  },
                ),
                ),
              ),
              // Total — pinned footer.
              Container(height: 1, color: AppColors.border),
              Container(
                color: AppColors.tableHeadBg,
                padding:
                    EdgeInsets.symmetric(horizontal: 20, vertical: 12.h),
                child: Row(children: [
                  cell(0, const SizedBox()),
                  cell(1, const SizedBox()),
                  cell(2, Text('Total', style: tStyle)),
                  cell(3, Text('${_formatAmount(totalAmt)}',
                      style: tStyle)),
                  cell(
                      4,
                      Text('${_formatAmount(totalPaid)}',
                          style: tStyle.copyWith(
                              color: AppColors.success))),
                  cell(
                      5,
                      Text('${_formatAmount(totalFine)}',
                          style: tStyle.copyWith(
                              color: AppColors.warning))),
                  cell(6, Text('${_formatAmount(totalBal)}',
                      style: tStyle)),
                  cell(7, const SizedBox()),
                  cell(8, const SizedBox()),
                ]),
              ),
            ],
          );
        }),
      ),
    );
  }

  // ─── Import UI ──────────────────────────────────────────────────────────

  Widget _buildImportSection() {
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
                onTap: () => setState(() {
                  _showImport = false;
                  _resetImport();
                }),
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
              Text('Import Fee Demands', style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_fileName != null)
                Text(_fileName!, style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
              SizedBox(width: 12.w),
              ElevatedButton.icon(
                onPressed: _pickFile,
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
                final hasErrors = _rows.isNotEmpty && _cellErrors.isNotEmpty;
                return ElevatedButton.icon(
                  onPressed: hasErrors ? _exportRowsWithErrors : _exportTemplate,
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
          if (_errorMsg != null) ...[
            SizedBox(height: 8.h),
            Text(_errorMsg!, style: TextStyle(color: AppColors.error, fontSize: 13.sp)),
          ],
          SizedBox(height: 12.h),

          // Data grid
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(8.r),
              ),
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
                        _gridHeaderCell('S.No', width: 60, center: true),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Demand No', flex: 2),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Roll No *', flex: 3),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Course', flex: 2),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Class *', flex: 2),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Fee Type *', flex: 3),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Year *', flex: 2),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Semester *', flex: 2),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Concession', flex: 2),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Fee Amt *', flex: 2, center: true),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Con. Amt', flex: 2, center: true),
                        _gridHeaderDivider(),
                        _gridHeaderCell('Due Date *', flex: 3, center: true),
                      ],
                    ),
                  ),
                  // Data rows
                  Expanded(
                    child: _rows.isEmpty
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
                            itemCount: _rows.length,
                            itemBuilder: (context, index) {
                              final row = _rows[index];
                              final isEven = index % 2 == 0;
                              final cellErrs = _cellErrors[index] ?? const <String>{};
                              final rowTooltip = _rowErrors[index] ?? '';
                              Widget cell(String key, int flex, {bool center = false}) {
                                final w = _gridDataCell(_mappedCell(row, key), flex: flex, center: center);
                                if (!cellErrs.contains(key)) return w;
                                return Expanded(
                                  flex: flex,
                                  child: Tooltip(
                                    message: rowTooltip,
                                    child: Container(
                                      color: const Color(0xFFFCE4E4),
                                      alignment: center ? Alignment.center : Alignment.centerLeft,
                                      padding: EdgeInsets.symmetric(horizontal: 8.w),
                                      child: Text(
                                        _mappedCell(row, key),
                                        style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return Container(
                                padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
                                color: isEven ? Colors.white : AppColors.surface,
                                child: Row(
                                  children: [
                                    _gridDataCell('${index + 1}', width: 60, center: true),
                                    cell('demno', 2),
                                    cell('stuadmno', 3),
                                    cell('courname', 2),
                                    cell('stuclass', 2),
                                    cell('demfeetype', 3),
                                    cell('yr_id', 2),
                                    cell('demfeeterm', 2),
                                    cell('con_id', 2),
                                    cell('feeamount', 2, center: true),
                                    cell('conamount', 2, center: true),
                                    cell('duedate', 3, center: true),
                                    if (cellErrs.isNotEmpty)
                                      Padding(
                                        padding: EdgeInsets.only(left: 8.w),
                                        child: Tooltip(
                                          message: rowTooltip,
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

          SizedBox(height: 12.h),

          // Bottom bar with row count and action buttons
          Row(
            children: [
              Text(
                '${_rows.length} rows',
                style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _rows.isEmpty ? null : () => _validateImportData(),
                icon: AppIcon.linear('tick-circle', size: 16),
                label: const Text('Validate'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                  textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w500),
                ),
              ),
              SizedBox(width: 8.w),
              ElevatedButton.icon(
                onPressed: _rows.isNotEmpty && _mappings.contains('stuadmno') && _mappings.contains('feeamount') ? _startImport : null,
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

  String _mappedCell(List<dynamic> row, String fieldKey) {
    final idx = _mappings.indexOf(fieldKey);
    if (idx < 0 || idx >= row.length) return '';
    return row[idx].toString().trim();
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
    return Container(width: 1, height: 36, color: AppColors.border);
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

  /// Export the currently-loaded rows back to Excel with offending cells
  /// shaded red and an extra "Error" column describing each row's issue.
  Future<void> _exportRowsWithErrors() async {
    final excel = xl.Excel.createExcel();
    final sheet = excel['Fee Demands'];
    excel.delete('Sheet1');

    final origHeaders = List<String>.from(_headers);
    final allHeaders = [...origHeaders, 'Error'];
    final headerStyle = xl.CellStyle(
      backgroundColorHex: xl.ExcelColor.fromHexString('#FF2D3748'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFFFF'),
      bold: true,
    );
    final errStyle = xl.CellStyle(
      backgroundColorHex: xl.ExcelColor.fromHexString('#FFFCE4E4'),
    );
    for (int i = 0; i < allHeaders.length; i++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = xl.TextCellValue(allHeaders[i]);
      cell.cellStyle = headerStyle;
      sheet.setColumnWidth(i, i == allHeaders.length - 1 ? 40 : 18);
    }
    sheet.setRowHeight(0, 32);

    for (int r = 0; r < _rows.length; r++) {
      final row = _rows[r];
      final cellErrs = _cellErrors[r] ?? const <String>{};
      // Map each error field key back to the source column index so the
      // matching cell gets the red shade.
      final errCols = <int>{};
      for (final fk in cellErrs) {
        final idx = _mappings.indexOf(fk);
        if (idx >= 0) errCols.add(idx);
      }
      for (int c = 0; c < origHeaders.length; c++) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
        cell.value = xl.TextCellValue(c < row.length ? row[c].toString() : '');
        if (errCols.contains(c)) cell.cellStyle = errStyle;
      }
      final errorCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: origHeaders.length, rowIndex: r + 1));
      errorCell.value = xl.TextCellValue(_rowErrors[r] ?? '');
      if (cellErrs.isNotEmpty) errorCell.cellStyle = errStyle;
    }

    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save File with Errors',
        fileName: 'fee_demand_errors.xlsx',
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

  Future<void> _exportTemplate() async {
    final excel = xl.Excel.createExcel();
    final sheet = excel['Fee Demands'];
    // Remove default Sheet1
    excel.delete('Sheet1');

    // Asterisk marks columns the importer requires (matches _requiredFields:
    // stuadmno, stuclass, demfeetype, yr_id, demfeeterm, feeamount, duedate).
    final headers = [
      'Demand No',
      'Roll No *',
      'Course',
      'Class *',
      'Fee Type *',
      'Fee Year *',
      'Semester *',
      'Concession',
      'Fee Amount *',
      'Concession Amount',
      'Due Date *',
    ];

    final headerStyle = xl.CellStyle(
      backgroundColorHex: xl.ExcelColor.fromHexString('#FF2D3748'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFFFF'),
      bold: true,
    );

    const columnWidths = [16.0, 18.0, 12.0, 18.0, 14.0, 12.0, 16.0, 16.0, 16.0, 20.0, 16.0];

    for (int i = 0; i < headers.length; i++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = xl.TextCellValue(headers[i]);
      cell.cellStyle = headerStyle;
      sheet.setColumnWidth(i, columnWidths[i]);
    }
    sheet.setRowHeight(0, 32);

    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Template',
        fileName: 'fee_demand_template.xlsx',
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
    final sheet = excel['Fee Demands'];
    excel.delete('Sheet1');

    final headers = ['Demand No', 'Roll No *', 'Course', 'Class *', 'Fee Type *', 'Fee Year *', 'Semester *', 'Concession', 'Fee Amount *', 'Concession Amount', 'Due Date *'];
    final sampleRows = [
      ['', 'CS001', 'BSC-CS', 'I Year', 'SCHOOL FEES', '2026-2027', 'I TERM', 'GENERAL', '10080', '0', '2026-05-31'],
      ['', 'CS001', 'BSC-CS', 'I Year', 'TUITION FEES', '2026-2027', 'JUNE', 'GENERAL', '700', '0', '2026-06-30'],
      ['', 'BBA001', 'BBA', 'II Year', 'SCHOOL FEES', '2026-2027', 'I TERM', 'GENERAL', '10080', '2000', '2026-05-31'],
      ['', 'MCA001', 'MCA', 'I Year', 'SCHOOL FEES', '2026-2027', 'I TERM', 'GENERAL', '6500', '0', '2026-05-31'],
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
        fileName: 'fee_demand_sample.xlsx',
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

  void _validateImportData() {
    final rowErrors = <int, String>{};
    final cellErrors = <int, Set<String>>{};
    for (int i = 0; i < _rows.length; i++) {
      final fields = _validateRowFields(i);
      if (fields.isEmpty) continue;
      rowErrors[i] = _composeRowError(fields);
      cellErrors[i] = fields.keys.toSet();
    }
    setState(() {
      _rowErrors = rowErrors;
      _cellErrors = cellErrors;
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

  Widget _buildImportProgressStep() {
    final progress = _total > 0 ? (_imported + _skipped) / _total : 0.0;
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
            Text('Importing... ${_imported + _skipped} / $_total', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600)),
            SizedBox(height: 12.h),
            LinearProgressIndicator(value: progress, backgroundColor: AppColors.border, valueColor: const AlwaysStoppedAnimation(AppColors.accent)),
            SizedBox(height: 8.h),
            Text('$_imported imported, $_skipped skipped', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
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
            Text('Import Complete', style: TextStyle(fontSize: 18.sp, fontWeight: FontWeight.w700)),
            SizedBox(height: 12.h),
            Text('$_imported imported successfully, $_skipped skipped', style: TextStyle(fontSize: 13.sp)),
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
}
