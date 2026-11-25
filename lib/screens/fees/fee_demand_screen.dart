import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/focusable_tap.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import 'package:excel/excel.dart' as xl;
import '../../utils/excel_theme.dart';
import '../../utils/import_errors_export.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../utils/app_text.dart';
import '../../services/supabase_service.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_dropdown_field.dart';
import '../../utils/save_path.dart';

class FeeDemandScreen extends StatefulWidget {
  const FeeDemandScreen({super.key});

  @override
  State<FeeDemandScreen> createState() => _FeeDemandScreenState();
}

class _FeeDemandScreenState extends State<FeeDemandScreen> {
  // Form controllers
  final _formKey = GlobalKey<FormState>();
  final _admNoController = TextEditingController();
  // Debounces the roll-no → class lookup so it doesn't hit the DB per keystroke.
  Timer? _lookupDebounce;
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
  // Save is enabled only after a successful Validate; reset whenever the data
  // changes (new file / cleared) so the user must re-validate.
  bool _isValidated = false;

  // Import state
  bool _showImport = false;
  String? _fileName;
  List<String> _headers = [];
  List<List<dynamic>> _rows = [];
  Map<int, String> _rowErrors = {};
  // rowIdx â†’ set of field keys whose value failed validation. Field keys
  // match _importFieldLabels (e.g. 'stuadmno', 'stuclass', 'demfeetype').
  Map<int, Set<String>> _cellErrors = {};
  List<String?> _mappings = [];
  int _importStep = 0; // 0=pick, 1=map, 2=importing, 3=done
  int _imported = 0;
  /// Rows that will UPDATE a demand the student already has, rather than raise
  /// a new one. Reported on the summary so a re-import's effect is visible
  /// before anyone goes looking for duplicates.
  int _willUpdate = 0;
  int _skipped = 0;
  int _total = 0;
  List<String> _importErrors = [];
  String? _errorMsg;

  // Fee demand list
  List<Map<String, dynamic>> _classSummary = [];
  bool _loadingDemands = false;
  String? _drilldownClass;
  List<Map<String, dynamic>> _drilldownDemands = [];
  // All active students of the drilled-down class — so students who have NO
  // feedemand row still appear in the student-wise list (with a "No Demand" tag).
  List<Map<String, dynamic>> _drilldownAllStudents = [];
  bool _loadingDrilldown = false;
  String? _drilldownStudent; // selected student adm no for 3rd level
  String? _drilldownStudentName; // selected student name for 3rd level

  // Main class-list Course/Class filters + pagination
  String? _courseFilter; // null = All Courses
  String? _classFilter;  // null = All Classes
  /// 'Regular' or 'Arrear' demands -- one or the other, Regular by default
  /// (user, 2026-11-14: "defaulty show regular not need regular+arrear").
  String _typeFilter = 'Regular';
  bool _typeMatches(Map<String, dynamic> d) {
    final arrear = (d['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
    return arrear == (_typeFilter == 'Arrear');
  }
  int _fdPage = 0;
  int _fdPerPage = 20;

  // Search
  final _searchController = TextEditingController();
  String _searchQuery = '';

  // Horizontal scroll for the wide import preview grid (17 columns).
  final _importHScroll = ScrollController();

  static const _importFieldKeys = [
    'demno',
    'demseqtype',
    'stuadmno',
    'stuclass',
    'demfeeterm',
    'demfeetype',
    'yr_id',
    'feeamount',
    'con_id',
    'conamount',
    'duedate',
    'cla_id',
    'sem_id',
    'fee_id',
    'cf_id',
    'arrearclass',
  ];

  static const Map<String, String> _importFieldLabels = {
    'demno': 'Demand No',
    'demseqtype': 'Type',
    'stuadmno': 'Roll No',
    'stuclass': 'Class',
    'demfeeterm': 'Semester',
    'demfeetype': 'Fee Type',
    'yr_id': 'Fee Year',
    'feeamount': 'Due Amount',
    'con_id': 'Con. Category',
    'conamount': 'Concession Amount',
    'duedate': 'Due Date',
    'cla_id': 'Class Id',
    'sem_id': 'Semester id',
    'fee_id': 'Fee Id',
    'cf_id': 'Class Fee Id',
    'arrearclass': 'Arrear Class',
  };

  static const _requiredFields = {'stuadmno', 'stuclass', 'demfeetype', 'yr_id', 'demfeeterm', 'feeamount', 'duedate'};

  // Fixed column widths for the import preview grid. The grid scrolls
  // horizontally (17 columns don't fit an Expanded/flex layout — long headers
  // like "Arrear Class" overflowed the container), so header + data cells share
  // these exact widths and _gridTotalW is their sum (+ slack for the error icon).
  static const double _wSno = 60, _wDemno = 120, _wType = 90, _wRoll = 150,
      _wClass = 120, _wSem = 110, _wFeeType = 150, _wYear = 105, _wDueAmt = 125,
      _wConCat = 190, _wConAmt = 170, _wDueDate = 120, _wClaId = 105,
      _wSemId = 115, _wFeeId = 75, _wCfId = 145, _wArrear = 145;
  // Sum of the 17 column widths above (2095) + slack for the data-row error icon.
  static const double _gridTotalW = 2155;

  @override
  void initState() {
    super.initState();
    _loadDropdowns();
    _loadFeeDemands();
  }

  @override
  void dispose() {
    _lookupDebounce?.cancel();
    _admNoController.dispose();
    _feeAmountController.dispose();
    _conAmountController.dispose();

    _feeTermController.dispose();
    _searchController.dispose();
    _importHScroll.dispose();
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
      // Shared ordering (utils/class_sort.dart): course, then year, with TC
      // batches last. The bare-grade list this replaced ranked every college
      // class the same, so they fell back to database insertion order.
      classes.sort(classCompare);
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
        SupabaseService.getFeeDemandSummary(insId, seqType: _typeFilter.toUpperCase()),
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
        // Arrear: only the sections that have arrears -- the Standard and
        // Section lists, student count and totals follow (user, 2026-11-14).
        if (_typeFilter == 'Arrear') {
          summary.removeWhere((c) => ((c['total_demand'] as num?)?.toDouble() ?? 0) <= 0);
        }
        setState(() {
          _classSummary = summary;
          // a Standard / Section no longer listed stops filtering
          if (_courseFilter != null && !summary.any((c) => c['courname']?.toString() == _courseFilter)) _courseFilter = null;
          if (_classFilter != null && !summary.any((c) => c['stuclass']?.toString() == _classFilter)) _classFilter = null;
          _loadingDemands = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading fee demands: $e');
      if (mounted) setState(() => _loadingDemands = false);
    }
  }

  String? _drilldownCourse;

  /// A demand line's paid / pending / fine as the section row above counts
  /// them (get_fee_demand_line_figures, attached when the section loads):
  /// a part-paid line shows what was paid, the fine is the one collected on
  /// its receipts. Without them (an older database), the line's own figures.
  ({double paid, double pending, double fine}) _lineFigures(Map<String, dynamic> d) {
    final f = d['_figures'];
    if (f is Map) {
      return (paid: (f['paid'] as num).toDouble(), pending: (f['pending'] as num).toDouble(), fine: (f['fine'] as num).toDouble());
    }
    final amt = (d['feeamount'] as num?)?.toDouble() ?? 0;
    final pa = (d['paidamount'] as num?)?.toDouble() ?? 0;
    return (paid: pa < amt ? pa : amt, pending: (d['balancedue'] as num?)?.toDouble() ?? amt, fine: 0.0);
  }

  Future<void> _loadDrilldown(String className, {String? courseName}) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    setState(() {
      _drilldownClass = className;
      _drilldownCourse = courseName;
      _loadingDrilldown = true;
      _drilldownDemands = [];
      _drilldownAllStudents = [];
    });
    try {
      // Also load every active student of the class so students with NO demand
      // still show up in the student-wise list.
      final results = await Future.wait<dynamic>([
        SupabaseService.getFeeDemandsByClass(insId, className),
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
            .select('stuadmno, stuname, courname')
            .eq('ins_id', insId)
            .eq('stuclass', className)
            .eq('activestatus', 1)
            .eq('preadmission', 0)),  // next year's intake: advance screens only
        SupabaseService.getFeeDemandLineFigures(insId, className),
      ]);
      final demands = List<Map<String, dynamic>>.from(results[0] as List);
      var students = List<Map<String, dynamic>>.from(results[1] as List);
      // each line's paid / pending / fine as the section row above counts them
      final figures = results[2] as Map<int, Map<String, double>>;
      for (final d in demands) {
        final f = figures[(d['dem_id'] as num?)?.toInt()];
        if (f != null) d['_figures'] = f;
      }
      // Filter by course if specified
      final filtered = (courseName != null
          ? demands.where((d) => (d['courname']?.toString() ?? d['stuname_course'] ?? '') == courseName || courseName == 'Other').toList()
          : demands).where(_typeMatches).toList();
      if (courseName != null && courseName != 'Other') {
        students = students
            .where((s) => (s['courname']?.toString() ?? '') == courseName)
            .toList();
      }
      if (mounted) {
        setState(() {
          _drilldownDemands = filtered;
          _drilldownAllStudents = students;
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
            content: Text(schoolTerm('Please import master data first: ${missing.join(', ')}')),
            backgroundColor: AppColors.error,
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
      if (feeAmount <= 0 || conAmount < 0 || conAmount > feeAmount) {
        throw const _DemandInputError('The concession cannot be more than the fee amount.');
      }

      // The term must be one of the Term master's names (a typo here becomes a
      // separate fee that is billed twice). Its sem_id rides along.
      final termTyped = _feeTermController.text.trim();
      final terms = List<Map<String, dynamic>>.from(await SupabaseService
          .fromSchema('semester').select('sem_id, semname').eq('ins_id', insId).eq('activestatus', 1));
      final term = terms.where((t) =>
          (t['semname'] ?? '').toString().trim().toUpperCase() == termTyped.toUpperCase()).firstOrNull;
      if (term == null) {
        throw _DemandInputError(schoolTerm(
            'Term "$termTyped" is not in the Semester master. Use one of: '
            '${terms.map((t) => t['semname']).join(', ')}'));
      }

      // Lookup stu_id from admission number
      final admNo = _admNoController.text.trim();
      int? stuId;
      if (admNo.isNotEmpty) {
        final stuResult = await SupabaseService.fromSchema('students')
            .select('stu_id')
            .eq('ins_id', insId)
            .eq('stuadmno', admNo)
            .eq('activestatus', 1)
            .eq('preadmission', 0)  // next year's intake: advance screens only
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
        'demfeeterm': term['semname'].toString().trim(),
        'sem_id': term['sem_id'],
        'con_id': _selectedConcession != null ? int.tryParse(_selectedConcession!) : null,
        'feeamount': feeAmount,
        'conamount': conAmount,
        'balancedue': feeAmount - conAmount,
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
          SnackBar(content: Text(e is _DemandInputError ? e.message : friendlyError(e)), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Debounces the roll-no lookup (~350ms) so a DB round-trip fires only after
  /// the user pauses typing, not on every character.
  void _onAdmNoChanged(String admNo) {
    _lookupDebounce?.cancel();
    if (admNo.isEmpty) return;
    _lookupDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _lookupStudentClass(admNo);
    });
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
          .eq('preadmission', 0)  // next year's intake: advance screens only
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

  // â”€â”€â”€ Import Logic â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  static String? _autoMapHeader(String header) {
    final h = collegeTerm(header).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    const aliases = {
      'demno': 'demno', 'demandno': 'demno', 'demandnumber': 'demno', 'docno': 'demno',
      // "Type" = demand sequence type (ARREAR / DEMAND / REGULAR), NOT the fee type.
      'type': 'demseqtype', 'demseqtype': 'demseqtype', 'demandtype': 'demseqtype', 'seqtype': 'demseqtype',
      'admissionno': 'stuadmno', 'admno': 'stuadmno', 'stuadmno': 'stuadmno', 'admissionnumber': 'stuadmno', 'rollno': 'stuadmno', 'roll': 'stuadmno', 'rollnumber': 'stuadmno',
      'class': 'stuclass', 'stuclass': 'stuclass',
      // "Arrear Class" = the original class the arrear was raised under (differs from current Class).
      'arrearclass': 'arrearclass',
      'course': 'courname', 'courname': 'courname', 'coursename': 'courname',
      'feetype': 'demfeetype', 'demfeetype': 'demfeetype',
      'feeyear': 'yr_id', 'yrid': 'yr_id', 'year': 'yr_id', 'arrearyear': 'yr_id',
      'feeterm': 'demfeeterm', 'demfeeterm': 'demfeeterm', 'term': 'demfeeterm', 'semester': 'demfeeterm', 'sem': 'demfeeterm',
      'concession': 'con_id', 'conid': 'con_id', 'concessioncategory': 'con_id', 'con': 'con_id',
      'feeamount': 'feeamount', 'amount': 'feeamount', 'fee': 'feeamount', 'feeamt': 'feeamount', 'fee amount': 'feeamount', 'fee amt': 'feeamount', 'dueamount': 'feeamount', 'dueamt': 'feeamount',
      'concessionamount': 'conamount', 'conamount': 'conamount', 'conamt': 'conamount', 'con amt': 'conamount', 'con. amt': 'conamount', 'concession amount': 'conamount',
      'concategory': 'con_id', 'concessioncat': 'con_id',
      'balanceamount': 'balancedue', 'balance': 'balancedue', 'balancedue': 'balancedue', 'balamount': 'balancedue', 'baldue': 'balancedue', 'balanceamt': 'balancedue',
      'duedate': 'duedate', 'due': 'duedate',
      'classid': 'cla_id', 'claid': 'cla_id',
      'semesterid': 'sem_id', 'semid': 'sem_id', 'termid': 'sem_id', 'feetermid': 'sem_id',
      'feeid': 'fee_id',
      'classfeeid': 'cf_id', 'cfid': 'cf_id', 'cffeeid': 'cf_id',
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
        _isValidated = false; // new file must be re-validated before Save
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
      // Paged: the full student roster passes 1000 as the college grows,
      // and a silent truncation here would mis-map imported rows.
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('students')
          .select('stuadmno, stuclass, courname')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0));  // next year's intake: advance screens only
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

  /// Per-field validation. Returns fieldKey â†’ reason for every cell that
  /// failed (empty map â‡’ row passes).
  Map<String, String> _validateRowFields(int rowIdx) {
    final row = _rows[rowIdx];
    final errors = <String, String>{};
    for (final reqKey in _requiredFields) {
      final colIdx = _mappings.indexOf(reqKey);
      if (colIdx < 0 || colIdx >= row.length || row[colIdx].toString().trim().isEmpty) {
        errors[reqKey] = 'Required';
      }
    }
    // Due date must parse to a real calendar date (accepts DD-MM-YYYY etc.).
    final dueRaw = _cellByKey(row, 'duedate');
    if (dueRaw != null && _parseDate(dueRaw) == null) {
      errors['duedate'] = 'Due date "$dueRaw" is not a valid date. Use YYYY-MM-DD or DD-MM-YYYY';
    }
    final ft = _cellByKey(row, 'demfeetype');
    if (ft != null && _feeTypes.isNotEmpty) {
      final ftLower = ft.toLowerCase();
      if (!_feeTypes.any((f) => f.toLowerCase() == ftLower)) {
        errors['demfeetype'] = 'Fee type "$ft" is not in Fee Master. Add it there, then validate again';
      }
    }
    String norm(String s) => s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    final admRaw = _cellByKey(row, 'stuadmno');
    if (admRaw != null && _importStudentByAdmno.isNotEmpty) {
      final student = _importStudentByAdmno[norm(admRaw)];
      if (student == null) {
        errors['stuadmno'] = '${schoolTerm('Roll No.')} "$admRaw" does not match any student. Check the number and validate again';
      } else {
        final clsRaw = _cellByKey(row, 'stuclass');
        if (clsRaw != null && (student['stuclass'] ?? '').isNotEmpty
            && norm(clsRaw) != norm(student['stuclass']!)) {
          errors['stuclass'] = schoolTerm('Class "$clsRaw" does not match this student\'s class "${student['stuclass']}". Correct it and validate again');
        }
        final courRaw = _cellByKey(row, 'courname');
        if (courRaw != null && (student['courname'] ?? '').isNotEmpty
            && norm(courRaw) != norm(student['courname']!)) {
          errors['courname'] = schoolTerm('Course "$courRaw" does not match this student\'s course "${student['courname']}". Correct it and validate again');
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
        missing.add(schoolTerm(_importFieldLabels[k] ?? k));
      } else {
        detail.add(v);
      }
    });
    final parts = <String>[];
    if (missing.isNotEmpty) parts.add('Required values are blank: ${missing.join(', ')}');
    parts.addAll(detail);
    return parts.join(' • ');
  }

  String? _cellByKey(List<dynamic> row, String fieldKey) {
    final idx = _mappings.indexOf(fieldKey);
    if (idx < 0 || idx >= row.length) return null;
    final v = row[idx].toString().trim();
    return v.isEmpty ? null : v;
  }

  /// Parse a date string in common formats (ISO, DD-MM-YYYY, MM-DD-YYYY).
  /// Excel due dates are often typed as "30-07-2026" (DD-MM-YYYY), which
  /// Postgres rejects when sent raw to a `date` column, so normalise here.
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
            content: Text(schoolTerm('Please import master data first: ${missing.join(', ')}')),
            backgroundColor: AppColors.error,
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
      _willUpdate = 0;
      _total = _rows.length;
      _importErrors = [];
    });

    // Clear already-processed staging rows (activestatus=9) so re-importing the
    // same Demand No isn't blocked by the tempfeedemand.demno unique constraint.
    // Those demands already live in feedemand; approving the new staging rows
    // updates them in place (fn_approve_tempfeedemand dedup) instead of adding.
    try {
      await SupabaseService.fromSchema('tempfeedemand')
          .delete()
          .eq('ins_id', insId)
          .eq('activestatus', 9);
    } catch (e) {
      debugPrint('tempfeedemand cleanup failed: $e');
    }

    // 1. Pre-fetch all student admno -> stu_id mappings.
    // Index under multiple normalisations because Excel often loses
    // leading zeros and adds whitespace to admission numbers.
    // Paged: see above — a truncated roster silently drops import matches.
    final stuList = await SupabaseService.fetchAll(() => SupabaseService
        .fromSchema('students')
        .select('stu_id, stuadmno, courname')
        .eq('ins_id', insId)
        .eq('activestatus', 1)
        .eq('preadmission', 0));  // next year's intake: advance screens only
    final stuMap = <String, int>{};
    final stuCourse = <int, String>{}; // stu_id -> course name (for the demand)
    for (final s in stuList) {
      final raw = s['stuadmno']?.toString().trim() ?? '';
      final id  = s['stu_id'] as int?;
      if (raw.isEmpty || id == null) continue;
      final cn = s['courname']?.toString().trim() ?? '';
      if (cn.isNotEmpty) stuCourse[id] = cn;
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

    // 2b. Pre-fetch valid classfeedemand cf_ids so an imported demand's Class Fee
    // Id can be validated against the class-fee templates (an unmatched id errors).
    final cfIds = <int>{};
    try {
      final cfRows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('classfeedemand')
          .select('cf_id'));
      for (final c in cfRows) {
        final id = c['cf_id'] as int?;
        if (id != null) cfIds.add(id);
      }
    } catch (_) {/* classfeedemand may be empty — skip the cf_id check */}

    // 2c. Pre-fetch cla_id -> course name (class.cour_id -> course.courname), so
    // an imported demand's course is derived from its Class Id.
    final claCourse = <int, String>{};
    try {
      final classRows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('class').select('cla_id, cour_id').eq('ins_id', insId));
      final courseRows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('course').select('cour_id, courname').eq('ins_id', insId));
      final courseById = <int, String>{
        for (final c in courseRows)
          if (c['cour_id'] is int) (c['cour_id'] as int): (c['courname']?.toString().trim() ?? ''),
      };
      for (final cl in classRows) {
        final claId = cl['cla_id'] as int?;
        final courId = cl['cour_id'] as int?;
        final cn = courId == null ? null : courseById[courId];
        if (claId != null && cn != null && cn.isNotEmpty) claCourse[claId] = cn;
      }
    } catch (_) {/* class/course masters may be missing */}

    // 2d. Pre-fetch valid Fee Type ids. A row whose Fee Id isn't one of these is
    // REJECTED (not imported) — the file's ids must match this institution's
    // masters. A blank Fee Id is allowed (resolved from the name on insert).
    final feeIds = <int>{};
    try {
      final ftRows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('feetype').select('fee_id').eq('activestatus', 1));
      for (final f in ftRows) {
        final id = f['fee_id'] as int?;
        if (id != null) feeIds.add(id);
      }
    } catch (_) {/* feetype missing — skip the check */}

    // 2d(ii). Pre-fetch valid Semester ids — a row whose Semester Id isn't one
    // of this institution's semesters is REJECTED (a blank Semester Id is fine).
    final semIds = <int>{};
    try {
      final smRows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('semester').select('sem_id').eq('ins_id', insId).eq('activestatus', 1));
      for (final s in smRows) {
        final id = s['sem_id'] as int?;
        if (id != null) semIds.add(id);
      }
    } catch (_) {/* semester master missing — skip the check */}

    // 2e. The demands this student ALREADY has, keyed by
    // stu_id|feetype|term|yr_id. Two things need it:
    //
    //   * the re-import guard below -- a demand cannot be reduced below what
    //     has already been collected against it;
    //   * UPDATE-INSTEAD-OF-DUPLICATE. fn_approve_tempfeedemand matches an
    //     existing demand by DEMNO, so a staged row carrying a demand number
    //     the database has never seen is always inserted. A sheet of rejected
    //     rows carries NEWLY ALLOCATED numbers (or, once Excel has been near
    //     it, none at all), so every row that was already billed came back as a
    //     SECOND demand and doubled the student's balance. Stamping the
    //     EXISTING demno onto the staged row makes that same trigger update the
    //     demand in place, with no change to the database.
    //
    // A LIST, not one value: the same student can legitimately hold two
    // demands for one fee type and term -- two instalments, a top-up raised
    // separately, or an old class's bill left behind by a transfer. Those must
    // never be silently merged, so a row that matches more than one and does
    // not say which it means is reported instead of guessed at.
    final existingDemands = <String, List<({String demno, double paid})>>{};
    // ...and the same demands keyed by their NUMBER, because a row that
    // carries one has already answered the question. A sheet exported from the
    // system names the exact demand on every line; looking that up by student
    // and fee type instead, and then refusing because the student happens to
    // hold two, throws away the answer the row was handed.
    final demandByNo = <String, ({int stuId, String feeType, double paid})>{};
    try {
      final fdRows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('feedemand')
          .select('stu_id, demfeetype, demfeeterm, yr_id, paidamount, demno')
          .eq('ins_id', insId)
          .eq('activestatus', 1));
      for (final f in fdRows) {
        final sid = f['stu_id'] as int?;
        if (sid == null) continue;
        final paid = (f['paidamount'] as num?)?.toDouble() ?? 0;
        final dn = f['demno']?.toString().trim() ?? '';
        final k = '$sid|${f['demfeetype'] ?? ''}|${f['demfeeterm'] ?? ''}|${f['yr_id'] ?? ''}';
        (existingDemands[k] ??= []).add((demno: dn, paid: paid));
        if (dn.isNotEmpty) {
          demandByNo.putIfAbsent(dn, () => (
            stuId: sid,
            feeType: f['demfeetype']?.toString() ?? '',
            paid: paid,
          ));
        }
      }
    } catch (_) {/* no existing demands */}

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
        // Balance column removed from the import: balance is always the full due
        // amount on a first import; re-import recomputes it from payments made.
        final balAmount = feeAmount;
        final cfId = int.tryParse(_cellByKey(row, 'cf_id') ?? '');
        final claId = int.tryParse(_cellByKey(row, 'cla_id') ?? '');
        // Reject a row whose Fee Id doesn't exist in this College's Fee Types
        // (blank is fine — it's resolved from the fee-type name on insert).
        final feeId = int.tryParse(_cellByKey(row, 'fee_id') ?? '');
        if (feeId != null && feeIds.isNotEmpty && !feeIds.contains(feeId)) {
          _skipped++;
          _importErrors.add('${schoolTerm('Roll No.')} ${_cellByKey(row, 'stuadmno') ?? ''}: Fee ID $feeId is not in Fee Master. Correct it in the file and import again.');
          continue;
        }
        // Reject a row whose Class Fee Id doesn't match a class-fee template, so
        // an unmatched id errors instead of importing an unlinked demand.
        if (cfId != null && cfIds.isNotEmpty && !cfIds.contains(cfId)) {
          _skipped++;
          _importErrors.add(schoolTerm('Roll No. ${_cellByKey(row, 'stuadmno') ?? ''}: Class Fee ID $cfId is not in Class Fee Demand. Correct it in the file and import again.'));
          continue;
        }
        // Reject a row whose Semester Id doesn't exist in this institution.
        final semId = int.tryParse(_cellByKey(row, 'sem_id') ?? '');
        if (semId != null && semIds.isNotEmpty && !semIds.contains(semId)) {
          _skipped++;
          _importErrors.add(schoolTerm('Roll No. ${_cellByKey(row, 'stuadmno') ?? ''}: Semester ID $semId is not in the Semester master. Correct it in the file and import again.'));
          continue;
        }

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
        // If the provided Fee/Arrear Year isn't in the year master, LEAVE yr_id
        // NULL (stored as null) and keep the raw label in demfeeyear — never
        // silently assign the wrong year. yr_id is nullable in feedemand /
        // tempfeedemand (add_feedemand_yrid_nullable.sql). The exact/partial
        // matches above still resolve close variants like "2025" -> "2025-2026".

        final admNoRaw = _cellByKey(row, 'stuadmno')?.trim() ?? '';
        // Try direct, lowercase, and leading-zero-stripped variants
        // before giving up - same normalisations applied to the map.
        int? stuId = stuMap[admNoRaw];
        if (stuId == null && admNoRaw.isNotEmpty) {
          stuId = stuMap[admNoRaw.toLowerCase()];
          stuId ??= stuMap[admNoRaw.replaceFirst(RegExp(r'^0+'), '')];
          stuId ??= stuMap[admNoRaw.replaceFirst(RegExp(r'^0+'), '').toLowerCase()];
        }
        if (stuId == null) {
          _skipped++;
          _importErrors.add('Row ${i + 2}: ${schoolTerm('Roll No.')} "$admNoRaw" does not match any active student.');
          continue;
        }

        // Does this student already have this demand?
        final demType = _cellByKey(row, 'demfeetype') ?? '';
        final demTerm = _cellByKey(row, 'demfeeterm') ?? '';

        String? existingDemno;
        double existingPaid = 0;

        // 1. THE ROW NAMES ITS DEMAND. A sheet exported from the system puts
        //    the demand number on every line, and that settles it -- even for
        //    a student holding two demands for the same fee, which is exactly
        //    when the number matters most.
        //
        //    The owner is checked first. fn_approve_tempfeedemand matches on
        //    demno + fee type and does NOT check the student, and demand
        //    numbers have been reissued, so a number from an old sheet can
        //    belong to somebody else entirely. Updating that would rewrite a
        //    different student's bill.
        final sheetDemno = _cellByKey(row, 'demno')?.trim() ?? '';
        final named = sheetDemno.isEmpty ? null : demandByNo[sheetDemno];
        if (named != null) {
          if (named.stuId != stuId) {
            _skipped++;
            _importErrors.add('${schoolTerm('Roll No.')} $admNoRaw: Demand No. "$sheetDemno" belongs '
                'to another student. Remove it from the row, or enter this '
                "student's own demand number.");
            continue;
          }
          existingDemno = sheetDemno;
          existingPaid = named.paid;
        } else {
          // 2. No usable number, so fall back to the student's demands for
          //    this fee type / term / year.
          final already =
              existingDemands['$stuId|$demType|$demTerm|${yrId ?? ''}'] ??
                  const [];
          // More than one and nothing says which: merging two instalments
          // would delete a bill, adding a third would double it.
          if (already.length > 1) {
            _skipped++;
            _importErrors.add('${schoolTerm('Roll No.')} $admNoRaw: $demType / $demTerm already has '
                '${already.length} demands (${already.map((e) => e.demno).join(", ")}). '
                'Enter the Demand No. of the one you mean in the row, or fix them '
                'in Student Fee Definition, then import again.');
            continue;
          }
          if (already.length == 1 && already.first.demno.isNotEmpty) {
            existingDemno = already.first.demno;
          }
          existingPaid = already.isEmpty ? 0.0 : already.first.paid;
        }

        // Re-import guard: Due Amount must cover what's already paid on this
        // demand + its concession (else the balance would go negative / a demand
        // would be reduced below collections). First imports have paid = 0.
        if (feeAmount + 0.005 < existingPaid + conAmount) {
          _skipped++;
          _importErrors.add('${schoolTerm('Roll No.')} $admNoRaw: due amount ${feeAmount.toStringAsFixed(0)} is less than the amount already paid (${existingPaid.toStringAsFixed(0)}) plus concession (${conAmount.toStringAsFixed(0)}). Enter at least ${(existingPaid + conAmount).toStringAsFixed(0)}.');
          continue;
        }

        // existingDemno is now set either from the number the row carried or
        // from the student's single matching demand, and is what makes the
        // approval trigger update in place. A number the sheet carried that
        // the database has never issued is dropped on purpose -- on a rejects
        // sheet it was only ever a proposal.
        if (existingDemno != null) _willUpdate++;

        final conName = _cellByKey(row, 'con_id');
        int? conId;
        if (conName != null && conName.isNotEmpty) {
          conId = int.tryParse(conName) ?? conMap[conName.toUpperCase()];
        }

        // Normalise the due date to ISO (yyyy-MM-dd). Excel commonly stores it
        // as "30-07-2026" (DD-MM-YYYY), which Postgres rejects raw.
        final dueRaw = _cellByKey(row, 'duedate');
        final dueParsed = _parseDate(dueRaw);
        if (dueRaw != null && dueParsed == null) {
          _skipped++;
          _importErrors.add('Row ${i + 2}: due date "$dueRaw" is not a valid date. Use YYYY-MM-DD or DD-MM-YYYY.');
          continue;
        }

        final data = {
          'ins_id': insId,
          'inscode': auth.inscode ?? '',
          'demno': existingDemno ?? _cellByKey(row, 'demno'),
          // ARREAR / DEMAND. Null (regular import) -> feedemand trigger defaults to 'DEMAND'.
          'demseqtype': _cellByKey(row, 'demseqtype'),
          'stuadmno': admNoRaw,
          'stu_id': stuId,
          'stuclass': _cellByKey(row, 'stuclass'),
          'courname': (claId != null ? claCourse[claId] : null) ?? stuCourse[stuId] ?? _cellByKey(row, 'courname'),
          'demfeetype': _cellByKey(row, 'demfeetype'),
          'yr_id': yrId,
          'demfeeyear': yrLabel ?? yrRaw ?? '',
          'demfeeterm': _cellByKey(row, 'demfeeterm'),
          'con_id': conId,
          'feeamount': feeAmount,
          'conamount': conAmount,
          'balancedue': balAmount,
          'duedate': dueParsed?.toIso8601String().split('T').first,
          'cla_id': claId,
          'sem_id': semId,
          'fee_id': int.tryParse(_cellByKey(row, 'fee_id') ?? ''),
          'cf_id': cfId,
          // Original class for an arrear demand (differs from current stuclass).
          'arrearclass': _cellByKey(row, 'arrearclass'),
          // Once cf_id / fee_id / sem_id validate, the demand is a real amount
          // owed and is always collectible — independent of the template's flag.
          'collectible': true,
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
              _importErrors.add('${schoolTerm('Roll No.')} ${row['stuadmno']}: ${_friendlyError(e2.toString())}');
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
      _isValidated = false;
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
    if (m.contains('duplicate key') || m.contains('unique constraint')) return 'This fee demand already exists.';
    if (m.contains('not-null') || m.contains('null value')) {
      // Name the column as the sheet labels it, not the database column.
      final col = RegExp(r'column "(\w+)"').firstMatch(msg)?.group(1);
      return col == null ? 'A required value is blank.' : '${schoolTerm(_importFieldLabels[col] ?? col)} is required.';
    }
    if (m.contains('foreign key') || m.contains('fkey')) return 'A linked value (student, class or fee type) does not exist. Check those columns and import again.';
    if (m.contains('check constraint')) return 'A value is not in the expected format. Check amounts and dates.';
    if (m.contains('value too long')) return 'A value is too long for its column. Shorten it and import again.';
    if (m.contains('invalid input syntax')) return 'A value is not in the expected format. Check amounts and dates.';
    if (m.contains('permission denied')) return 'You do not have permission to import fee demands. Ask an administrator.';
    return msg.length > 80 ? '${msg.substring(0, 80)}...' : msg;
  }

  // â”€â”€â”€ UI â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppUI.card(),
      child: Column(
        children: [
          // Card header with title, buttons, breadcrumb, and search.
          // Hidden entirely while import is active - the import panel has
          // its own Back button to return.
          if (!_showImport) Container(
            padding: EdgeInsets.fromLTRB(16.w, 10.h, 16.w, 0),
            child: Row(
              children: [
                if (_drilldownClass == null && _drilldownStudent == null) ...[
                  AppUI.iconTile('receipt-edit', size: 18),
                  SizedBox(width: 12.w),
                  Text('Fee Demand', style: AppUI.cardTitle),
                ],
                if (!_showImport) ...[
                  if (_drilldownClass != null || _drilldownStudent != null) ...[
                    // Back button - solid accent pill
                    InkWell(
                      onTap: () => setState(() {
                        if (_drilldownStudent != null) {
                          _drilldownStudent = null;
                          _drilldownStudentName = null;
                        } else {
                          _drilldownClass = null;
                          _drilldownDemands = [];
                          _drilldownAllStudents = [];
                        }
                        _searchQuery = '';
                        _searchController.clear();
                      }),
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                      child: Container(
                        height: AppUI.controlHeight(context),
                        padding: EdgeInsets.symmetric(horizontal: 14.w),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(AppUI.controlRadius),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
                            SizedBox(width: 6.w),
                            Text('Back', style: AppUI.label.copyWith(color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(width: 12.w),
                    Container(width: 1, height: 18, color: AppColors.cardBorder),
                    SizedBox(width: 12.w),
                    // Breadcrumb path (plain text, not button-like)
                    Text('Fee Demand', style: AppUI.muted),
                    SizedBox(width: 6.w),
                    AppIcon.linear('Chevron Right', size: 14, color: AppColors.textLight),
                    SizedBox(width: 6.w),
                    if (_drilldownStudent != null) ...[
                      Text('${_drilldownCourse != null ? '$_drilldownCourse > ' : ''}$_drilldownClass', style: AppUI.muted),
                      SizedBox(width: 6.w),
                      AppIcon.linear('Chevron Right', size: 14, color: AppColors.textLight),
                      SizedBox(width: 6.w),
                      Text(
                        '${_drilldownStudentName ?? ''} (${_drilldownStudent})',
                        style: AppUI.label,
                      ),
                    ] else
                      Text(
                        schoolTerm('Class $_drilldownClass'),
                        style: AppUI.label,
                      ),
                  ] else ...[
                    SizedBox(width: 12.w),
                    AppUI.chip(
                      '${_classSummary.fold<int>(0, (sum, c) => sum + ((c['student_count'] as num?)?.toInt() ?? 0))} students',
                      AppStatus.info,
                    ),
                  ],
                ],
                const Spacer(),
                // Search / Import / Refresh only on the main list — not in the
                // class or student drill-down.
                if (!_showImport && _drilldownClass == null && _drilldownStudent == null) ...[
                  AppSearchField(
                    controller: _searchController,
                    hintText: schoolTerm('Search by class...'),
                    onChanged: (v) => setState(() { _searchQuery = v.trim().toLowerCase(); _fdPage = 0; }),
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
                if (_drilldownClass == null && _drilldownStudent == null)
                  Builder(builder: (context) {
                  // Fee Demand import is available to Admin as well as accountant
                  // / super-admin (Admin can both manage/approve AND import demands).
                  return ElevatedButton.icon(
                    onPressed: () => setState(() {
                      _showImport = !_showImport;
                      if (!_showImport) _resetImport();
                    }),
                    icon: AppIcon(_showImport ? 'close-circle' : 'document-upload', size: AppBtn.iconSize(context), color: Colors.white),
                    label: Text(_showImport ? 'Close Import' : AppText.import),
                    style: _showImport ? AppUI.danger(context) : null,
                  );
                }),
                if (!_showImport && _drilldownClass == null && _drilldownStudent == null) ...[
                  SizedBox(width: 8.w),
                  Builder(builder: (context) {
                    return OutlinedButton.icon(
                      onPressed: _loadFeeDemands,
                      icon: AppIcon('refresh', size: AppBtn.iconSize(context), color: AppColors.primary),
                      label: const Text('Refresh'),
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
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: FocusTraversalGroup(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const CardTitleBlock(icon: 'receipt-2', title: 'Add Fee Demand', subtitle: 'create a new fee demand for a student'),
                    SizedBox(height: 20.h),

                    // Reg No
                    _buildLabel(schoolTerm('Roll No *')),
                    TextFormField(
                      controller: _admNoController,
                      decoration: _inputDecoration('Enter admission number', filled: _admNoController.text.trim().isNotEmpty),
                      style: TextStyle(fontSize: 13.sp, color: _admNoController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: _admNoController.text.trim().isNotEmpty ? FontWeight.w600 : null),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                      onChanged: (v) { setState(() {}); _onAdmNoChanged(v.trim()); },
                    ),
                    SizedBox(height: 16.h),

                    // Class
                    _buildLabel(schoolTerm('Class')),
                    Builder(builder: (_) {
                      final seen = <String>{};
                      final items = <DropdownMenuItem<String>>[];
                      for (final c in _classes) {
                        if (c.isEmpty || !seen.add(c)) continue;
                        items.add(DropdownMenuItem(value: c, child: Text(c)));
                      }
                      final value = seen.contains(_selectedClass) ? _selectedClass : null;
                      return AppDropdownField<String>(
                        value: value,
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 6,
                        icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                        decoration: _inputDecoration(schoolTerm('Select class'), filled: value != null),
                        items: items,
                        selectedItemBuilder: (context) => items.map((m) => Align(alignment: Alignment.centerLeft, child: Text((m.child as Text).data ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
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
                      return AppDropdownField<String>(
                        value: value,
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 6,
                        icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                        decoration: _inputDecoration('Select fee type', filled: value != null),
                        items: items,
                        selectedItemBuilder: (context) => items.map((m) => Align(alignment: Alignment.centerLeft, child: Text((m.child as Text).data ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
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
                                return AppDropdownField<String>(
                                  value: value,
                                  dropdownColor: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  elevation: 6,
                                  icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                                  decoration: _inputDecoration('Select year', filled: value != null),
                                  items: items,
                                  selectedItemBuilder: (context) => items.map((m) => Align(alignment: Alignment.centerLeft, child: Text((m.child as Text).data ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
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
                              _buildLabel(schoolTerm('Semester')),
                              TextFormField(
                                controller: _feeTermController,
                                decoration: _inputDecoration('Enter term', filled: _feeTermController.text.trim().isNotEmpty),
                                style: TextStyle(fontSize: 13.sp, color: _feeTermController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: _feeTermController.text.trim().isNotEmpty ? FontWeight.w600 : null),
                                onChanged: (_) => setState(() {}),
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
                      return AppDropdownField<String>(
                        value: value,
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        elevation: 6,
                        icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
                        decoration: _inputDecoration('Select concession', filled: value != null),
                        items: items,
                        selectedItemBuilder: (context) => items.map((m) => Align(alignment: Alignment.centerLeft, child: Text((m.child as Text).data ?? '', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.accent)))).toList(),
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
                                decoration: _inputDecoration('Enter amount', filled: _feeAmountController.text.trim().isNotEmpty),
                                keyboardType: TextInputType.number,
                                style: TextStyle(fontSize: 13.sp, color: _feeAmountController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: _feeAmountController.text.trim().isNotEmpty ? FontWeight.w600 : null),
                                validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                                onChanged: (_) => setState(() {}),
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
                                decoration: _inputDecoration('Enter amount', filled: _conAmountController.text.trim().isNotEmpty),
                                keyboardType: TextInputType.number,
                                style: TextStyle(fontSize: 13.sp, color: _conAmountController.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: _conAmountController.text.trim().isNotEmpty ? FontWeight.w600 : null),
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16.h),

                    // Due Date
                    _buildLabel('Due Date'),
                    FocusableTap(
                      onTap: _pickDueDate,
                      borderRadius: BorderRadius.circular(10.r),
                      child: InputDecorator(
                        decoration: _inputDecoration('', filled: _dueDate != null).copyWith(
                          suffixIcon: AppIcon('calendar-1', size: 18, color: AppColors.textSecondary),
                        ),
                        child: Text(
                          _dueDate != null
                              ? '${_dueDate!.day.toString().padLeft(2, '0')}/${_dueDate!.month.toString().padLeft(2, '0')}/${_dueDate!.year}'
                              : 'Select date',
                          style: _dueDate != null
                              ? AppUI.fieldText(context, filled: true)
                              : AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                    SizedBox(height: 24.h),

                    // Buttons
                    Builder(builder: (_) {
                      return Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _resetForm,
                              icon: const AppIcon('refresh', size: 16, color: AppColors.primary),
                              label: const Text('Clear'),
                            ),
                          ),
                          SizedBox(width: 12.w),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton.icon(
                              onPressed: _isSaving ? null : _saveDemand,
                              icon: _isSaving
                                  ? SizedBox(width: 18.w, height: 18.h, child: const CircularProgressIndicator(strokeWidth: 2, color: AppColors.textLight))
                                  : AppIcon('save-2', size: 18),
                              label: Text(_isSaving ? 'Saving...' : 'Save Fee Demand'),
                            ),
                          ),
                        ],
                      );
                    }),
                  ],
                )),
              ),
            ),
    );
  }

  Widget _buildLabel(String text) {
    // Callers pass "Roll No *" style labels; the kit draws the red star.
    final req = text.trimRight().endsWith('*');
    return AppUI.fieldLabel(
      req ? text.trimRight().substring(0, text.trimRight().length - 1).trimRight() : text,
      required: req,
    );
  }

  InputDecoration _inputDecoration(String hint, {bool filled = false}) {
    return AppUI.field(context, hint, filled: filled);
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
    return _classSummary.where((c) {
      if (_courseFilter != null && (c['courname']?.toString() != _courseFilter)) return false;
      if (_classFilter != null && (c['stuclass']?.toString() != _classFilter)) return false;
      if (_searchQuery.isNotEmpty) {
        final cls = c['stuclass']?.toString().toLowerCase() ?? '';
        final course = c['courname']?.toString().toLowerCase() ?? '';
        if (!cls.contains(_searchQuery) && !course.contains(_searchQuery)) return false;
      }
      return true;
    }).toList();
  }

  List<String> get _fdCourseOptions =>
      (_classSummary.map((c) => c['courname']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList()..sort());

  List<String> get _fdClassOptions {
    Iterable<Map<String, dynamic>> src = _classSummary;
    if (_courseFilter != null) src = src.where((c) => c['courname']?.toString() == _courseFilter);
    return (src.map((c) => c['stuclass']?.toString().trim() ?? '').where((s) => s.isNotEmpty).toSet().toList()..sort());
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
          'arr_years': <String>{},
        };
      }
      final g = grouped[admNo]!;
      // Arrear: the year the dues are from, with the section the student was
      // in then (user, 2026-11-14: "for arrear show arrear year").
      final yr = d['demfeeyear']?.toString().trim() ?? '';
      if (yr.isNotEmpty && (d['demseqtype']?.toString().trim().toUpperCase() ?? '') == 'ARREAR') {
        final was = d['arrearclass']?.toString().trim() ?? '';
        (g['arr_years'] as Set<String>).add(was.isEmpty ? yr : '$yr ($was)');
      }
      final amt = (d['feeamount'] as num?)?.toDouble() ?? 0;
      final con = (d['conamount'] as num?)?.toDouble() ?? 0;
      // paid / pending / fine as the section row counts them: a part-paid
      // line shows what was paid, and the fine is the one on its receipts
      final x = _lineFigures(d);
      g['total_demand'] = (g['total_demand'] as double) + amt;
      g['total_concession'] = (g['total_concession'] as double) + con;
      g['total_paid'] = (g['total_paid'] as double) + x.paid;
      g['total_fine'] = (g['total_fine'] as double) + x.fine;
      g['total_pending'] = (g['total_pending'] as double) + x.pending;
      g['demand_count'] = (g['demand_count'] as int) + 1;
      if (x.pending <= 0) {
        g['paid_count'] = (g['paid_count'] as int) + 1;
      } else {
        g['unpaid_count'] = (g['unpaid_count'] as int) + 1;
      }
    }
    // Add students of this class who have NO feedemand row at all, so they still
    // appear in the list (with a "No Demand" status and all-zero amounts).
    // (Arrear view: only the students who have arrears.)
    for (final s in _typeFilter == 'Arrear' ? const <Map<String, dynamic>>[] : _drilldownAllStudents) {
      final admNo = s['stuadmno']?.toString() ?? '';
      if (admNo.isEmpty || grouped.containsKey(admNo)) continue;
      grouped[admNo] = {
        'stuadmno': admNo,
        'stuname': s['stuname']?.toString() ?? '',
        'courname': s['courname']?.toString(),
        'total_demand': 0.0,
        'total_concession': 0.0,
        'total_paid': 0.0,
        'total_pending': 0.0,
        'total_fine': 0.0,
        'demand_count': 0,
        'paid_count': 0,
        'unpaid_count': 0,
        'no_demand': true,
      };
    }
    // Order the student list alphabetically by name.
    final list = grouped.values.toList()
      ..sort((a, b) => (a['stuname']?.toString() ?? '')
          .toLowerCase()
          .compareTo((b['stuname']?.toString() ?? '').toLowerCase()));
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
    final all = _filteredClassSummary;
    if (all.isEmpty) {
      return Padding(
        padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
        child: Column(children: [
          _fdFilterRow(),
          SizedBox(height: 40.h),
          AppUI.empty(icon: 'receipt-edit', title: 'No fee demands found', why: schoolTerm('Generate demands from the class fee template, or import them.')),
        ]),
      );
    }
    final pageCount = (all.length / _fdPerPage).ceil();
    if (_fdPage >= pageCount) _fdPage = pageCount - 1;
    if (_fdPage < 0) _fdPage = 0;
    final start = _fdPage * _fdPerPage;
    final summaries = all.sublist(start, (start + _fdPerPage).clamp(0, all.length));

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 12.h),
      child: Column(children: [
        _fdFilterRow(),
        SizedBox(height: 12.h),
        Expanded(child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.cardBorder),
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
                  Expanded(child: Text(schoolTerm('COURSE'), style: AppUI.tableHead)),
                  Expanded(child: Text(schoolTerm('CLASS'), style: AppUI.tableHead)),
                  Expanded(child: Text('STUDENTS', style: AppUI.tableHead, textAlign: TextAlign.center)),
                  Expanded(child: Text('TOTAL DEMAND', style: AppUI.tableHead, textAlign: TextAlign.right)),
                  Expanded(child: Text('CONCESSION', style: AppUI.tableHead, textAlign: TextAlign.right)),
                  Expanded(child: Text('COLLECTED', style: AppUI.tableHead, textAlign: TextAlign.right)),
                  Expanded(child: Text('FINE', style: AppUI.tableHead, textAlign: TextAlign.right)),
                  Expanded(child: Text('PENDING', style: AppUI.tableHead, textAlign: TextAlign.right)),
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
                  final totalConcession = (s['total_concession'] as num?)?.toDouble() ?? 0;
                  final totalPaid = (s['total_paid'] as num?)?.toDouble() ?? 0;
                  final totalFine = (s['total_fine'] as num?)?.toDouble() ?? 0;
                  final totalPending = (s['total_pending'] as num?)?.toDouble() ?? 0;
                  // No demand raised for this section yet: its own colour, so
                  // the gaps stand out (user, 2026-11-14).
                  final none = totalDemand <= 0;

                  return InkWell(
                    // Nothing raised: nothing to open (user, 2026-11-14).
                    onTap: none ? null : () => _loadDrilldown(className, courseName: s['courname']?.toString()),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                      decoration: BoxDecoration(
                        color: none ? AppColors.errorTint : Colors.white,
                        border: const Border(bottom: BorderSide(color: AppColors.divider)),
                      ),
                      child: Row(
                        children: [
                          Expanded(child: Text(s['courname']?.toString() ?? '-', style: none ? AppUI.cell.copyWith(color: AppColors.errorInk) : AppUI.cell)),
                          Expanded(child: Text(className, style: AppUI.cell.copyWith(fontWeight: FontWeight.w700, color: none ? AppColors.errorInk : null))),
                          Expanded(child: Text('$studentCount', style: AppUI.cell, textAlign: TextAlign.center)),
                          Expanded(
                              child: none
                                  ? Text('No demand', style: AppUI.cell.copyWith(color: AppColors.error, fontWeight: FontWeight.w700), textAlign: TextAlign.right)
                                  : Text('${_formatAmount(totalDemand)}', style: AppUI.money, textAlign: TextAlign.right)),
                          Expanded(child: Text(totalConcession > 0 ? '${_formatAmount(totalConcession)}' : '-', style: AppUI.money, textAlign: TextAlign.right)),
                          Expanded(child: Text('${_formatAmount(totalPaid)}', style: AppUI.money.copyWith(color: AppColors.success), textAlign: TextAlign.right)),
                          Expanded(child: Text(totalFine > 0 ? '${_formatAmount(totalFine)}' : '-', style: AppUI.money.copyWith(color: totalFine > 0 ? AppColors.warning : AppColors.textLight), textAlign: TextAlign.right)),
                          Expanded(child: Text('${_formatAmount(totalPending)}', style: AppUI.money.copyWith(color: AppColors.warning), textAlign: TextAlign.right)),
                          SizedBox(width: 32.w, child: none ? null : AppIcon.linear('Chevron Right', size: 16, color: AppColors.textLight)),
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
              decoration: const BoxDecoration(
                color: AppColors.tableHeadBg,
                border: Border(top: BorderSide(color: AppColors.cardBorder)),
              ),
              child: Row(
                children: [
                  Expanded(child: Text('TOTAL', style: AppUI.tableHead.copyWith(color: AppColors.textPrimary))),
                  const Expanded(child: SizedBox.shrink()),
                  Expanded(child: Text('${all.fold<int>(0, (sum, s) => sum + ((s['student_count'] as num?)?.toInt() ?? 0))}', style: AppUI.money, textAlign: TextAlign.center)),
                  Expanded(child: Text('${_formatAmount(all.fold<double>(0, (sum, s) => sum + ((s['total_demand'] as num?)?.toDouble() ?? 0)))}', style: AppUI.money.copyWith(fontWeight: FontWeight.w800), textAlign: TextAlign.right)),
                  Expanded(child: Text('${_formatAmount(all.fold<double>(0, (sum, s) => sum + ((s['total_concession'] as num?)?.toDouble() ?? 0)))}', style: AppUI.money.copyWith(fontWeight: FontWeight.w800), textAlign: TextAlign.right)),
                  Expanded(child: Text('${_formatAmount(all.fold<double>(0, (sum, s) => sum + ((s['total_paid'] as num?)?.toDouble() ?? 0)))}', style: AppUI.money.copyWith(fontWeight: FontWeight.w800, color: AppColors.success), textAlign: TextAlign.right)),
                  Expanded(child: Text('${_formatAmount(all.fold<double>(0, (sum, s) => sum + ((s['total_fine'] as num?)?.toDouble() ?? 0)))}', style: AppUI.money.copyWith(fontWeight: FontWeight.w800, color: AppColors.warning), textAlign: TextAlign.right)),
                  Expanded(child: Text('${_formatAmount(all.fold<double>(0, (sum, s) => sum + ((s['total_pending'] as num?)?.toDouble() ?? 0)))}', style: AppUI.money.copyWith(fontWeight: FontWeight.w800, color: AppColors.warning), textAlign: TextAlign.right)),
                  SizedBox(width: 32.w),
                ],
              ),
            ),
          ],
        ),
      )),
      SizedBox(height: 10.h),
      _fdPaginationBar(all.length, pageCount),
    ]),
    );
  }

  // Course / Class filter row (main class list only).
  Widget _fdFilterRow() {
    return Row(children: [
      _fdDropdown(schoolTerm('Course'), _courseFilter, schoolTerm('All Courses'), _fdCourseOptions, (v) => setState(() { _courseFilter = v; _classFilter = null; _fdPage = 0; })),
      SizedBox(width: 14.w),
      _fdDropdown(schoolTerm('Class'), _classFilter, schoolTerm('All Classes'), _fdClassOptions, (v) => setState(() { _classFilter = v; _fdPage = 0; })),
      SizedBox(width: 14.w),
      // Regular / Arrear: the totals are re-read for that kind of demand.
      _fdDropdown('Demand Type', _typeFilter, 'Regular', const ['Regular', 'Arrear'], (v) {
        if (v == null || v == _typeFilter) return;
        setState(() { _typeFilter = v; _fdPage = 0; });
        _loadFeeDemands();
      }, allowAll: false),
      const Spacer(),
    ]);
  }

  /// [allowAll] false: no "All ..." entry -- one of [options] is always chosen.
  Widget _fdDropdown(String label, String? value, String hint, List<String> options, ValueChanged<String?> onChanged, {bool allowAll = true}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      AppUI.fieldLabel(label),
      SizedBox(
        width: 220.w,
        child: AppDropdownField<String>(
          initialValue: options.contains(value) ? value : null,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          style: AppUI.fieldText(context, filled: options.contains(value)),
          decoration: AppUI.field(context, hint, filled: options.contains(value)),
          items: [
            if (allowAll) DropdownMenuItem<String>(value: null, child: Text(hint, overflow: TextOverflow.ellipsis)),
            ...options.map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis))),
          ],
          onChanged: onChanged,
        ),
      ),
    ]);
  }

  Widget _fdPaginationBar(int total, int pageCount) {
    final from = total == 0 ? 0 : _fdPage * _fdPerPage + 1;
    final to = ((_fdPage + 1) * _fdPerPage).clamp(0, total);
    Widget navBtn(IconData ic, VoidCallback? onTap) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(width: 32, height: 32, alignment: Alignment.center, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)), child: Icon(ic, size: 18, color: onTap == null ? AppColors.textLight : AppColors.textPrimary)),
        );
    // Windowed page numbers around the current page (max 5).
    final startPage = (_fdPage - 2).clamp(0, (pageCount - 5).clamp(0, pageCount)).toInt();
    final endPage = (startPage + 5).clamp(0, pageCount).toInt();
    return Row(children: [
      Text(AppUI.showing(from, to, total), style: AppUI.muted),
      const Spacer(),
      navBtn(Icons.chevron_left, _fdPage > 0 ? () => setState(() => _fdPage--) : null),
      SizedBox(width: 6.w),
      for (int p = startPage; p < endPage; p++) ...[
        InkWell(
          onTap: () => setState(() => _fdPage = p),
          borderRadius: BorderRadius.circular(8),
          child: Container(width: 32, height: 32, alignment: Alignment.center, decoration: BoxDecoration(color: p == _fdPage ? AppColors.primary : Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: p == _fdPage ? AppColors.primary : AppColors.border)), child: Text('${p + 1}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w700, color: p == _fdPage ? Colors.white : AppColors.textPrimary))),
        ),
        SizedBox(width: 6.w),
      ],
      navBtn(Icons.chevron_right, _fdPage < pageCount - 1 ? () => setState(() => _fdPage++) : null),
      SizedBox(width: 14.w),
      SizedBox(
        // Fixed (not .w-scaled) so "20 / page" stays on one line in a small window.
        width: 132,
        child: AppDropdownField<int>(
          initialValue: _fdPerPage,
          isExpanded: true,
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          style: AppUI.fieldText(context),
          decoration: AppUI.field(context, ''),
          items: const [10, 20, 50, 100].map((n) => DropdownMenuItem(value: n, child: AppFitText('$n / page'))).toList(),
          onChanged: (v) => setState(() { _fdPerPage = v ?? 20; _fdPage = 0; }),
        ),
      ),
    ]);
  }

  String _formatDueDate(String dateStr) {
    if (dateStr == '-' || dateStr.isEmpty) return '-';
    try {
      return formatDmy(DateTime.parse(dateStr));
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
      return AppUI.empty(
        icon: 'message-text',
        title: _searchQuery.isNotEmpty ? 'No matching students' : 'No students found',
        why: _searchQuery.isNotEmpty
            ? schoolTerm('Nothing in this class matches the search. Clear it to see every student.')
            : schoolTerm('This class has no students with fee demands yet. Use Back to pick another class.'),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: AppVerticalScrollbar(
                header: Container(
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                color: AppColors.tableHeadBg,
                child: Row(
                  children: [
                    Expanded(flex: 1, child: Text(schoolTerm('ROLL NO.'), style: AppUI.tableHead)),
                    Expanded(flex: 2, child: Text('NAME', style: AppUI.tableHead)),
                    Expanded(flex: 1, child: Text(schoolTerm('COURSE'), style: AppUI.tableHead)),
                    if (_typeFilter == 'Arrear') Expanded(flex: 2, child: Text('ARREAR YEAR', style: AppUI.tableHead)),
                    Expanded(flex: 1, child: Text('DEMAND', style: AppUI.tableHead, textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('CONCESSION', style: AppUI.tableHead, textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('PAID', style: AppUI.tableHead, textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('FINE', style: AppUI.tableHead, textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('PENDING', style: AppUI.tableHead, textAlign: TextAlign.right)),
                    Expanded(flex: 1, child: Text('STATUS', style: AppUI.tableHead, textAlign: TextAlign.center)),
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
                    final totalConcession = (s['total_concession'] as double?) ?? 0;
                    final totalPaid = (s['total_paid'] as double?) ?? 0;
                    final totalFine = (s['total_fine'] as double?) ?? 0;
                    final totalPending = (s['total_pending'] as double?) ?? 0;
                    final unpaidCount = (s['unpaid_count'] as int?) ?? 0;
                    final noDemand = s['no_demand'] == true;
                    final allPaid = unpaidCount == 0;
                    final statusLabel =
                        noDemand ? 'No Demand' : (allPaid ? 'Paid' : 'Pending');
                    final statusKind = noDemand
                        ? AppStatus.neutral
                        : (allPaid ? AppStatus.success : AppStatus.warning);

                    return InkWell(
                      onTap: () => setState(() {
                        _drilldownStudent = admNo;
                        _drilldownStudentName = name;
                        _searchQuery = '';
                        _searchController.clear();
                      }),
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                        decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: AppColors.divider)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 1,
                              child: Text(admNo, style: AppUI.cell.copyWith(fontWeight: FontWeight.w600, color: AppColors.primary)),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                name.isNotEmpty ? name : '-',
                                style: AppUI.cell.copyWith(fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text(s['courname']?.toString() ?? '-', style: AppUI.cell),
                            ),
                            if (_typeFilter == 'Arrear')
                              Expanded(
                                flex: 2,
                                child: Text(
                                  () {
                                    // one year per line, in full -- not cut off
                                    final t = (((s['arr_years'] as Set<String>?) ?? const <String>{}).toList()..sort()).join('\n');
                                    return t.isEmpty ? '-' : t;
                                  }(),
                                  style: AppUI.cell.copyWith(fontWeight: FontWeight.w600, color: AppColors.warning),
                                ),
                              ),
                            Expanded(
                              flex: 1,
                              child: Text('${_formatAmount(totalDemand)}', style: AppUI.money, textAlign: TextAlign.right),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text(totalConcession > 0 ? '${_formatAmount(totalConcession)}' : '-', style: AppUI.money, textAlign: TextAlign.right),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text('${_formatAmount(totalPaid)}', style: AppUI.money.copyWith(color: AppColors.success), textAlign: TextAlign.right),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text(totalFine > 0 ? '${_formatAmount(totalFine)}' : '-', style: AppUI.money.copyWith(color: totalFine > 0 ? AppColors.warning : AppColors.textLight), textAlign: TextAlign.right),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text('${_formatAmount(totalPending)}', style: AppUI.money.copyWith(color: totalPending > 0 ? AppColors.warning : AppColors.success), textAlign: TextAlign.right),
                            ),
                            Expanded(
                              flex: 1,
                              child: Center(
                                child: AppUI.chip(statusLabel, statusKind),
                              ),
                            ),
                            SizedBox(width: 28.w, child: AppIcon.linear('Chevron Right', size: 16, color: AppColors.textLight)),
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
      return AppUI.empty(
        icon: 'message-text',
        title: _searchQuery.isNotEmpty ? 'No matching records' : 'No fee demands found',
        why: _searchQuery.isNotEmpty
            ? 'Nothing matches the search. Clear it to see every demand.'
            : 'This student has no fee demands yet. Use Back to pick another student.',
      );
    }

    double totalAmt = 0, totalConcession = 0, totalPaid = 0, totalFine = 0, totalBal = 0;
    for (final d in demands) {
      totalAmt += (d['feeamount'] as num?)?.toDouble() ?? 0;
      totalConcession += (d['conamount'] as num?)?.toDouble() ?? 0;
      final x = _lineFigures(d);
      totalPaid += x.paid;
      totalFine += x.fine;
      totalBal += x.pending;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16.w, 8.h, 16.w, 16.h),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: LayoutBuilder(builder: (context, constraints) {
          // Right-sized base widths so the whole table (through STATUS) fits
          // the viewport without the DUE DATE column being clipped at the
          // screen edge. Order: S No, SEMESTER, FEE TYPE, AMOUNT, CONCESSION,
          // PAID, FINE, BALANCE, DUE DATE, STATUS.
          const baseWidths = <double>[60, 120, 170, 120, 130, 120, 100, 120, 140, 110];
          // The narrowest each column may get before the table scrolls.
          const minWidths = <double>[52, 96, 130, 108, 112, 108, 90, 108, 112, 100];
          // Horizontal padding outside the columns: 20 on the left; on the
          // right 28 plus the 16px scrollbar lane beside the body rows, so
          // the last column never sits against the border or the scrollbar.
          const rowPadL = 20.0, rowPadR = 28.0, barLane = 16.0;
          const hPad = rowPadL + rowPadR + barLane;
          final naturalWidth = baseWidths.reduce((a, b) => a + b) + hPad;
          final minWidth = minWidths.reduce((a, b) => a + b) + hPad;
          // Wider than the natural table: scale every column up so the table
          // fills the space. Narrower: shrink the columns toward their
          // minimums so every column still shows; only below that does the
          // row scroll horizontally.
          final avail = constraints.maxWidth;
          final List<double> widths;
          if (!avail.isFinite || avail <= minWidth) {
            widths = List<double>.from(minWidths);
          } else if (avail < naturalWidth) {
            final t = (avail - minWidth) / (naturalWidth - minWidth);
            widths = [for (int i = 0; i < baseWidths.length; i++) minWidths[i] + (baseWidths[i] - minWidths[i]) * t];
          } else {
            final scale = (avail - hPad) / (naturalWidth - hPad);
            widths = [for (final w in baseWidths) w * scale];
          }
          final tableWidth = widths.reduce((a, b) => a + b) + hPad;
          const headers = <String>[
            'S. NO.', 'SEMESTER', 'FEE TYPE', 'AMOUNT', 'CONCESSION', 'PAID',
            'FINE', 'BALANCE', 'DUE DATE', 'STATUS',
          ];
          final hStyle = AppUI.tableHead;
          final cStyle = AppUI.cell;
          final mStyle = AppUI.money;
          final tStyle = AppUI.money.copyWith(fontWeight: FontWeight.w800);
          // AMOUNT/CONCESSION/PAID/FINE/BALANCE are right-aligned.
          bool rightAlign(int i) => i >= 3 && i <= 7;
          Widget cell(int i, Widget child) => SizedBox(
                width: widths[i],
                child: Padding(
                  // Gutter between every column so adjacent values (e.g. a
                  // right-aligned BALANCE and a left-aligned DUE DATE) keep
                  // clear breathing room.
                  padding: EdgeInsets.symmetric(horizontal: 10.w),
                  child: Align(
                    alignment: rightAlign(i)
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: child,
                  ),
                ),
              );

          bool isArrear(Map<String, dynamic> d) =>
              (d['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
          final regulars = demands.where((d) => !isArrear(d)).toList();
          final arrears = demands.where(isArrear).toList();
          // Display items: a section banner (String) then its demand rows, so
          // the type is always shown — even a single fee gets REGULAR/ARREAR.
          // Serial numbers restart at 1 within each section.
          final rowItems = <Object>[];
          final serials = <int>[];
          void addGroup(String label, List<Map<String, dynamic>> list) {
            rowItems.add(label);
            serials.add(0);
            for (int k = 0; k < list.length; k++) {
              rowItems.add(list[k]);
              serials.add(k + 1);
            }
          }
          if (regulars.isNotEmpty || arrears.isEmpty) addGroup('REGULAR FEES', regulars);
          // Arrears separated by year, oldest first, each with the section
          // the student was in that year (user, 2026-11-14: "sepearte by year").
          final byYear = <String, List<Map<String, dynamic>>>{};
          for (final d in arrears) {
            final yr = d['demfeeyear']?.toString().trim() ?? '';
            (byYear[yr] ??= []).add(d);
          }
          for (final yr in byYear.keys.toList()..sort()) {
            final lines = byYear[yr]!;
            final was = lines
                .map((d) => d['arrearclass']?.toString().trim() ?? '')
                .where((x) => x.isNotEmpty)
                .toSet()
                .join(', ');
            addGroup(
                yr.isEmpty ? 'ARREAR FEES' : 'ARREAR FEES  ·  $yr${was.isEmpty ? '' : '  ($was)'}',
                lines);
          }
          Widget bannerRow(String title) => Container(
                width: tableWidth,
                color: AppColors.primaryLight,
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8.h),
                alignment: Alignment.centerLeft,
                child: Text(title,
                    style: AppUI.caps.copyWith(color: AppColors.primary)),
              );

          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              child: Column(
            children: [
              // Sticky header.
              Container(
                color: AppColors.tableHeadBg,
                padding: EdgeInsets.fromLTRB(
                    rowPadL, 12.h, rowPadR + barLane, 12.h),
                child: Row(children: [
                  for (int i = 0; i < headers.length; i++)
                    cell(i, Text(schoolTerm(headers[i]), style: hStyle)),
                ]),
              ),
              Container(height: 1, color: AppColors.divider),
              // Scrolling body.
              Expanded(
                child: AppVerticalScrollbar(
                  builder: (context, sc) => ListView.separated(
                  controller: sc,
                  itemCount: rowItems.length,
                  separatorBuilder: (_, __) => const Divider(
                      height: 1,
                      color: AppColors.divider),
                  itemBuilder: (_, i) {
                    final item = rowItems[i];
                    if (item is String) return bannerRow(item);
                    final d = item as Map<String, dynamic>;
                    final serial = serials[i];
                    final term = d['demfeeterm']?.toString() ?? '-';
                    final feeType = d['demfeetype']?.toString() ?? '-';
                    final amt = (d['feeamount'] as num?)?.toDouble() ?? 0;
                    final con = (d['conamount'] as num?)?.toDouble() ?? 0;
                    final x = _lineFigures(d);
                    final paid = x.paid;
                    final fineDisplay = x.fine;
                    final bal = x.pending;
                    final dueDate = d['duedate']?.toString() ?? '-';
                    final formattedDueDate = _formatDueDate(dueDate);
                    return Container(
                      color: Colors.white,
                      padding: EdgeInsets.fromLTRB(
                          rowPadL, 11.h, rowPadR, 11.h),
                      child: Row(children: [
                        cell(0, Text('$serial', style: cStyle)),
                        cell(1, Text(term, style: cStyle)),
                        cell(2, Text(feeType, style: cStyle)),
                        cell(3,
                            Text('${_formatAmount(amt)}', style: mStyle)),
                        cell(
                            4,
                            Text(con > 0 ? '${_formatAmount(con)}' : '-',
                                style: mStyle)),
                        cell(
                            5,
                            Text('${_formatAmount(paid)}',
                                style: mStyle)),
                        cell(
                            6,
                            Text(
                                fineDisplay > 0
                                    ? '${_formatAmount(fineDisplay)}'
                                    : '-',
                                style: fineDisplay > 0
                                    ? mStyle.copyWith(color: AppColors.warning)
                                    : mStyle)),
                        cell(
                            7,
                            Text('${_formatAmount(bal)}',
                                style: mStyle)),
                        cell(8, Text(formattedDueDate, style: cStyle)),
                        cell(
                            9,
                            bal <= 0
                                ? AppUI.chip('Paid', AppStatus.success)
                                : paid > 0
                                    ? AppUI.chip('Partial', AppStatus.info)
                                    : AppUI.chip('Pending', AppStatus.warning)),
                      ]),
                    );
                  },
                ),
                ),
              ),
              // Total - pinned footer.
              Container(height: 1, color: AppColors.cardBorder),
              Container(
                color: AppColors.tableHeadBg,
                padding: EdgeInsets.fromLTRB(
                    rowPadL, 12.h, rowPadR + barLane, 12.h),
                child: Row(children: [
                  cell(0, const SizedBox()),
                  cell(1, const SizedBox()),
                  cell(2, Text('Total', style: tStyle)),
                  cell(3, Text('${_formatAmount(totalAmt)}',
                      style: tStyle)),
                  cell(4, Text('${_formatAmount(totalConcession)}',
                      style: tStyle)),
                  cell(
                      5,
                      Text('${_formatAmount(totalPaid)}',
                          style: tStyle.copyWith(
                              color: AppColors.success))),
                  cell(
                      6,
                      Text('${_formatAmount(totalFine)}',
                          style: tStyle.copyWith(
                              color: AppColors.warning))),
                  cell(7, Text('${_formatAmount(totalBal)}',
                      style: tStyle)),
                  cell(8, const SizedBox()),
                  cell(9, const SizedBox()),
                ]),
              ),
            ],
              ),
            ),
          );
        }),
      ),
    );
  }

  // â”€â”€â”€ Import UI â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _buildImportSection() {
    if (_importStep == 2) return _buildImportProgressStep();
    if (_importStep == 3) return _buildImportDoneStep();

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
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
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                child: Builder(builder: (context) {
                  final compact = AppUI.compact(context);
                  final hPad = compact ? 12.0 : 14.0;
                  final innerGap = compact ? 4.0 : 6.0;
                  return Container(
                    height: AppBtn.height(context),
                    padding: EdgeInsets.symmetric(horizontal: hPad),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon.linear('Chevron Left', size: AppBtn.iconSize(context), color: Colors.white),
                        SizedBox(width: innerGap),
                        Text('Back', style: AppUI.label.copyWith(color: Colors.white)),
                      ],
                    ),
                  );
                }),
              ),
              SizedBox(width: 12.w),
              AppUI.iconTile('document-upload', size: 18),
              SizedBox(width: 12.w),
              Text('Import Fee Demands', style: AppUI.cardTitle),
              const Spacer(),
              if (_fileName != null)
                Text(_fileName!, style: AppUI.muted),
              SizedBox(width: 12.w),
              ElevatedButton.icon(
                onPressed: _pickFile,
                icon: AppIcon('document-upload', size: 16),
                label: const Text(AppText.chooseFile),
              ),
              SizedBox(width: 8.w),
              Builder(builder: (_) {
                final hasErrors = _rows.isNotEmpty && _cellErrors.isNotEmpty;
                return OutlinedButton.icon(
                  onPressed: hasErrors ? _exportRowsWithErrors : _exportTemplate,
                  icon: AppIcon(hasErrors ? 'document-download' : 'grid-1', size: 16),
                  label: Text(hasErrors ? 'Export with Errors' : AppText.downloadTemplate),
                );
              }),
              SizedBox(width: 8.w),
              OutlinedButton.icon(
                onPressed: _exportSampleData,
                icon: AppIcon('document-download', size: 16),
                label: const Text(AppText.downloadSample),
              ),
            ],
          ),
          if (_errorMsg != null) ...[
            SizedBox(height: 8.h),
            Text(_errorMsg!, style: AppUI.body.copyWith(fontSize: 13.sp, color: AppColors.error)),
          ],
          SizedBox(height: 12.h),

          // Data grid
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.cardBorder),
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
              ),
              clipBehavior: Clip.hardEdge,
              child: Scrollbar(
                controller: _importHScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                controller: _importHScroll,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: _gridTotalW,
                  child: Column(
                children: [
                  // Header row
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.tableHeadBg,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(AppUI.controlRadius - 1),
                        topRight: Radius.circular(AppUI.controlRadius - 1),
                      ),
                    ),
                    child: Row(
                      children: [
                        _gridHeaderCell(AppText.serialNo, width: _wSno, center: true),
                        _gridHeaderCell('Demand No.', width: _wDemno),
                        _gridHeaderCell('Type', width: _wType),
                        _gridHeaderCell(schoolTerm('Roll No. *'), width: _wRoll),
                        _gridHeaderCell(schoolTerm('Class *'), width: _wClass),
                        _gridHeaderCell(schoolTerm('Semester *'), width: _wSem),
                        _gridHeaderCell('Fee Type *', width: _wFeeType),
                        _gridHeaderCell('Fee Year *', width: _wYear),
                        _gridHeaderCell('Due Amount *', width: _wDueAmt, center: true),
                        _gridHeaderCell('Concession Category', width: _wConCat),
                        _gridHeaderCell('Concession Amount', width: _wConAmt, center: true),
                        _gridHeaderCell('Due Date *', width: _wDueDate, center: true),
                        _gridHeaderCell(schoolTerm('Class ID'), width: _wClaId, center: true),
                        _gridHeaderCell(schoolTerm('Semester ID'), width: _wSemId, center: true),
                        _gridHeaderCell('Fee ID', width: _wFeeId, center: true),
                        _gridHeaderCell(schoolTerm('Class Fee ID'), width: _wCfId, center: true),
                        _gridHeaderCell(schoolTerm('Arrear Class'), width: _wArrear),
                      ],
                    ),
                  ),
                  // Data rows
                  Expanded(
                    child: _rows.isEmpty
                        ? AppUI.empty(
                            icon: 'element-4',
                            title: 'No data loaded',
                            why: 'Click Choose File to load a CSV or Excel file.',
                          )
                        : ListView.builder(
                            itemCount: _rows.length,
                            itemBuilder: (context, index) {
                              final row = _rows[index];
                              final isEven = index % 2 == 0;
                              final cellErrs = _cellErrors[index] ?? const <String>{};
                              final rowTooltip = _rowErrors[index] ?? '';
                              Widget cell(String key, double w, {bool center = false}) {
                                final cellW = _gridDataCell(_mappedCell(row, key), width: w, center: center);
                                if (!cellErrs.contains(key)) return cellW;
                                return SizedBox(
                                  width: w,
                                  child: Tooltip(
                                    message: rowTooltip,
                                    child: Container(
                                      color: AppColors.errorBg,
                                      alignment: center ? Alignment.center : Alignment.centerLeft,
                                      padding: EdgeInsets.symmetric(horizontal: 8.w),
                                      child: Text(
                                        _mappedCell(row, key),
                                        style: AppUI.cell.copyWith(fontWeight: FontWeight.w600, color: AppColors.error),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return Container(
                                padding: EdgeInsets.symmetric(vertical: 12.h),
                                decoration: BoxDecoration(
                                  color: isEven ? Colors.white : AppColors.surface,
                                  border: const Border(bottom: BorderSide(color: AppColors.divider)),
                                ),
                                child: Row(
                                  children: [
                                    _gridDataCell('${index + 1}', width: _wSno, center: true),
                                    cell('demno', _wDemno),
                                    cell('demseqtype', _wType),
                                    cell('stuadmno', _wRoll),
                                    cell('stuclass', _wClass),
                                    cell('demfeeterm', _wSem),
                                    cell('demfeetype', _wFeeType),
                                    cell('yr_id', _wYear),
                                    cell('feeamount', _wDueAmt, center: true),
                                    cell('con_id', _wConCat),
                                    cell('conamount', _wConAmt, center: true),
                                    cell('duedate', _wDueDate, center: true),
                                    cell('cla_id', _wClaId, center: true),
                                    cell('sem_id', _wSemId, center: true),
                                    cell('fee_id', _wFeeId, center: true),
                                    cell('cf_id', _wCfId, center: true),
                                    cell('arrearclass', _wArrear),
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
              ),
            ),
          ),

          SizedBox(height: 12.h),

          // Bottom bar with row count and action buttons
          Row(
            children: [
              Text(
                '${_rows.length} rows',
                style: AppUI.muted,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _rows.isEmpty ? null : () => _validateImportData(),
                icon: AppIcon.linear('tick-circle', size: 16),
                label: const Text('Validate'),
              ),
              SizedBox(width: 8.w),
              ElevatedButton.icon(
                // Enabled only after a successful Validate (no row errors).
                onPressed: _isValidated && _rows.isNotEmpty && _mappings.contains('stuadmno') && _mappings.contains('feeamount') ? _startImport : null,
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

  String _mappedCell(List<dynamic> row, String fieldKey) {
    final idx = _mappings.indexOf(fieldKey);
    if (idx < 0 || idx >= row.length) return '';
    final raw = row[idx].toString().trim();
    // Group amount columns; leave non-numeric (error) values exactly as typed.
    if (fieldKey == 'feeamount' || fieldKey == 'conamount') {
      final n = num.tryParse(raw);
      if (n != null) return formatIndianNumber(n);
    }
    return raw;
  }

  Widget _gridHeaderCell(String text, {double? width, int flex = 1, bool center = false}) {
    final child = Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 12.h),
      alignment: center ? Alignment.center : Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: AppColors.divider)),
      ),
      child: Text(
        text.toUpperCase(),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: AppUI.tableHead,
      ),
    );
    return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
  }

  Widget _gridDataCell(String text, {double? width, int flex = 1, bool center = false}) {
    final child = Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 10.h),
      alignment: center ? Alignment.center : Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: AppColors.divider)),
      ),
      child: Text(text, style: AppUI.cell, overflow: TextOverflow.ellipsis),
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
      backgroundColorHex: XlTheme.headerBg,
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
      final savePath = await pickSavePath(
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

    // BUILT FROM THE FIELD LIST, not typed out again.
    //
    // This template used to carry its own hand-written array of 14 headings
    // while the preview grid, the Sample Data sheet and the importer all work
    // from the 16 in _importFieldKeys. It was missing "Type" and "Arrear
    // Class", so a sheet filled in from the downloaded template could not
    // describe an arrear at all, and its columns no longer lined up with the
    // grid the user was looking at. Deriving all three from one list is the
    // only way they stay in step.
    //
    // The asterisk is likewise derived: it marks exactly the columns in
    // _requiredFields, so adding a required field cannot leave the template
    // claiming it is optional.
    final headers = [
      for (final k in _importFieldKeys)
        '${_importFieldLabels[k] ?? k}${_requiredFields.contains(k) ? ' *' : ''}',
    ];

    final headerStyle = xl.CellStyle(
      backgroundColorHex: XlTheme.headerBg,
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFFFF'),
      bold: true,
    );

    // Per field, so a reordered or added column cannot shift every width after
    // it the way a positional list did.
    const widthByKey = <String, double>{
      'demno': 16, 'demseqtype': 12, 'stuadmno': 18, 'stuclass': 20,
      'demfeeterm': 14, 'demfeetype': 22, 'yr_id': 14, 'feeamount': 14,
      'con_id': 16, 'conamount': 18, 'duedate': 14, 'cla_id': 10,
      'sem_id': 12, 'fee_id': 10, 'cf_id': 13, 'arrearclass': 18,
    };
    final columnWidths = [
      for (final k in _importFieldKeys) widthByKey[k] ?? 14.0,
    ];

    for (int i = 0; i < headers.length; i++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      cell.value = xl.TextCellValue(schoolTerm(headers[i]));
      cell.cellStyle = headerStyle;
      sheet.setColumnWidth(i, columnWidths[i]);
    }
    sheet.setRowHeight(0, 32);

    try {
      final savePath = await pickSavePath(
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

    // Supports BOTH formats. Regular rows: leave "Type"/"Arrear Class" blank
    // (Type defaults to DEMAND). Arrear rows: Type = ARREAR + the original
    // class in "Arrear Class" (differs from the student's current "Class").
    final headers = ['Demand No', 'Type', 'Roll No *', 'Class *', 'Semester *', 'Fee Type *', 'Fee Year *', 'Due Amount *', 'Con. Category', 'Concession Amount', 'Due Date *', 'Class Id', 'Semester id', 'Fee Id', 'Class Fee Id', 'Arrear Class'];
    final sampleRows = [
      ['', 'DEMAND', 'CS001',  'I Year',  'I TERM', 'SCHOOL FEES',  '2026-2027', '10080', 'GENERAL', '0',    '2026-05-31', '', '', '', '', ''],
      ['', 'DEMAND', 'CS001',  'I Year',  'JUNE',   'TUITION FEES', '2026-2027', '700',   'GENERAL', '0',    '2026-06-30', '', '', '', '', ''],
      ['', 'DEMAND', 'BBA001', 'II Year', 'I TERM', 'SCHOOL FEES',  '2026-2027', '10080', 'GENERAL', '2000', '2026-05-31', '', '', '', '', ''],
      ['', 'ARREAR', 'MCA001', 'II Year', 'I TERM', 'TUITION FEES', '2022-2023', '6500',  'GENERAL', '0',    '2026-05-31', '', '', '', '', 'I Year'],
    ];

    final headerStyle = xl.CellStyle(
      backgroundColorHex: XlTheme.headerBg,
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
      final savePath = await pickSavePath(
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
      // Save unlocks only when validation passes with zero row errors.
      _isValidated = rowErrors.isEmpty && _rows.isNotEmpty;
    });
    if (rowErrors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All rows are valid'), backgroundColor: AppColors.success),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${rowErrors.length} row(s) have errors. Fix the cells highlighted in red and validate again.'), backgroundColor: AppColors.error),
      );
    }
  }

  Widget _buildImportProgressStep() {
    final progress = _total > 0 ? (_imported + _skipped) / _total : 0.0;
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
            Text('Importing... ${_imported + _skipped} / $_total', style: AppUI.body.copyWith(fontWeight: FontWeight.w700)),
            SizedBox(height: 12.h),
            LinearProgressIndicator(value: progress, backgroundColor: AppColors.divider, valueColor: const AlwaysStoppedAnimation(AppColors.primary)),
            SizedBox(height: 8.h),
            Text('$_imported imported, $_skipped skipped', style: AppUI.muted),
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
            Text('$_imported imported successfully, $_skipped skipped',
                textAlign: TextAlign.center,
                style: AppUI.body),
            // Say how many of those were UPDATES. Without it a re-import reads
            // as "218 imported" whether it raised 218 new demands or refreshed
            // 218 existing ones, and the difference is the whole ledger.
            if (_willUpdate > 0) ...[
              SizedBox(height: 4.h),
              Text(
                  '$_willUpdate existing demand(s) updated'
                  ' · ${_imported - _willUpdate} new demand(s) added',
                  textAlign: TextAlign.center,
                  style: AppUI.muted),
            ],
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
                    child: Text(e, style: AppUI.body.copyWith(fontSize: 13.sp, color: AppColors.error)),
                  )).toList(),
                ),
              ),
            ],
            SizedBox(height: 20.h),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (_importErrors.isNotEmpty) ...[
                OutlinedButton.icon(
                  onPressed: () => exportImportErrors('Fee Demand', _importErrors),
                  icon: AppIcon('document-download', size: 16, color: AppColors.primary),
                  label: const Text('Export Errors'),
                ),
                SizedBox(width: 10.w),
              ],
              ElevatedButton(
                onPressed: _resetImport,
                child: const Text(AppText.close),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// A fee demand the screen refuses before sending (shown as typed).
class _DemandInputError implements Exception {
  final String message;
  const _DemandInputError(this.message);
}
