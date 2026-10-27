import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';

/// Fee Demand Import — a wide sheet in and out: one row per student, one
/// column per fee type.
///
///   reg no | name | class | sem | <fee type> ... | duedate
///
/// EXPORT writes the ticked students of the chosen class, pre-filled with Reg
/// No, Name, Class and Sem, with a column for each ticked fee type (the fee
/// types Class Fee Demand defines for that class and semester start ticked).
///
/// IMPORT validates first and writes nothing: every problem is listed by row,
/// and "Export with Errors" hands the sheet back with the bad cells shaded red
/// and an error column. Reg No, Name (which must be that student's), Sem, due
/// date and every fee amount are required -- 0 means no fee. A row with any
/// problem is skipped as a whole; the admin then chooses to send the valid rows
/// or fix the sheet first.
///
/// SENDING stages each non-blank amount as one REGULAR demand in tempfeedemand
/// (isapproved = false), so nothing is billed until Fee Demand Approval.
/// Re-importing a corrected sheet UPDATES instead of duplicating:
///   * the existing Regular demand's demno is reused, so approval updates it;
///   * its concession is carried over (approval writes it back onto the demand);
///   * older still-pending Regular staged rows for the same demand are replaced.
/// Arrear demands are never matched, reused or replaced.
class FeeDemandImportScreen extends StatefulWidget {
  const FeeDemandImportScreen({super.key});

  @override
  State<FeeDemandImportScreen> createState() => _FeeDemandImportScreenState();
}

class _FeeDemandImportScreenState extends State<FeeDemandImportScreen> {
  bool _loading = true;
  String? _loadError;

  List<Map<String, dynamic>> _courses = [];
  List<Map<String, dynamic>> _classes = [];
  List<Map<String, dynamic>> _semesters = [];
  List<Map<String, dynamic>> _feeTypes = [];

  // Export selection.
  String? _course;
  /// Classes to export, ticked in the Class picker. One sheet covers all of
  /// them: each student row carries its own class, and the fee columns are the
  /// union of what Class Fee Demand defines for these classes at the chosen
  /// semester -- so a student whose class has no such fee is priced 0.
  final Set<String> _pickedClasses = {};
  String? _semName;
  bool _exporting = false;

  // Pick lists for the ticked classes.
  bool _loadingLists = false;
  String? _listsKey; // the class set the lists below belong to
  List<Map<String, dynamic>> _classStudents = [];
  List<Map<String, dynamic>> _classTemplate = []; // classfeedemand: cfclass, cfterm, cffeetype
  final Set<String> _pickedStudents = {}; // stuadmno
  final Set<int> _pickedFees = {}; // fee_id
  final _stuSearch = TextEditingController();
  final _feeSearch = TextEditingController();
  final _classSearch = TextEditingController();
  final _feeKey = GlobalKey();
  final _classKey = GlobalKey();

  /// Stable identity for a set of classes, so a reply that arrives after the
  /// ticks changed again can be discarded.
  static String _keyOf(Iterable<String> classes) =>
      (classes.toList()..sort()).join('\u0000');

  /// What the Class field and the messages call the selection.
  String get _classLabel => _pickedClasses.length == 1
      ? _pickedClasses.first
      : schoolTerm('${_pickedClasses.length} classes');

  // Import progress / last result.
  String? _fileName;
  bool _importing = false;
  bool _done = false;
  int _lines = 0; // demands that passed validation
  int _staged = 0; // demands actually sent
  int _skipped = 0; // rows skipped for problems + demands that failed to send
  final List<String> _errors = [];

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  @override
  void initState() {
    super.initState();
    // After the first frame: _loadMasters calls setState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMasters());
  }

  @override
  void dispose() {
    _stuSearch.dispose();
    _feeSearch.dispose();
    _classSearch.dispose();
    super.dispose();
  }

  // ─── Masters ──────────────────────────────────────────────────────────────

  Future<void> _loadMasters() async {
    final auth = context.read<AuthProvider>();
    if (auth.schema != null && auth.schema!.isNotEmpty) {
      SupabaseService.setSchema(auth.schema);
    }
    final insId = _insId;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('course')
            .select('cour_id, courname, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1)),
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('class')
            .select('cla_id, claname, cour_id, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1)),
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('semester')
            .select('sem_id, semname, semshort, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1)),
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('feetype')
            .select('fee_id, feedesc, feeshort, payseq')
            .eq('activestatus', 1)),
      ]);
      int ord(Map<String, dynamic> m, String k, [int missing = 9999]) =>
          (m[k] as num?)?.toInt() ?? missing;
      int byOrd(Map<String, dynamic> a, Map<String, dynamic> b, String name) {
        final c = ord(a, 'ordid').compareTo(ord(b, 'ordid'));
        return c != 0 ? c : _upper(a[name]).compareTo(_upper(b[name]));
      }

      final courses = List<Map<String, dynamic>>.from(r[0] as List)
        ..sort((a, b) => byOrd(a, b, 'courname'));
      final classes = List<Map<String, dynamic>>.from(r[1] as List)
        ..sort((a, b) => byOrd(a, b, 'claname'));
      final sems = List<Map<String, dynamic>>.from(r[2] as List)
        ..sort((a, b) {
          final c = ord(a, 'ordid').compareTo(ord(b, 'ordid'));
          return c != 0 ? c : ord(a, 'sem_id').compareTo(ord(b, 'sem_id'));
        });
      // Fee Master priority order, then name.
      final fees = List<Map<String, dynamic>>.from(r[3] as List)
        ..sort((a, b) {
          final c = ord(a, 'payseq', 1000).compareTo(ord(b, 'payseq', 1000));
          return c != 0 ? c : _upper(a['feedesc']).compareTo(_upper(b['feedesc']));
        });
      if (!mounted) return;
      setState(() {
        _courses = courses;
        _classes = classes;
        _semesters = sems;
        _feeTypes = fees;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = friendlyError(e);
      });
    }
  }

  Future<void> _refresh() async {
    await _loadMasters();
    if (mounted && _pickedClasses.isNotEmpty) _loadExportLists();
  }

  // ─── Text helpers ─────────────────────────────────────────────────────────

  /// Upper case, trimmed, inner whitespace collapsed. Keeps punctuation, which
  /// matters: "STUDENTS ADVANCE" and "STUDENTS ADVANCE." are different fee types.
  static String _upper(Object? v) =>
      (v?.toString() ?? '').trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Letters and digits only -- a loose fallback for hand-typed headers.
  static String _alnum(Object? v) =>
      (v?.toString() ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Reg No as typed or as Excel stores it: a numeric cell comes back as
  /// "2627100.0", and leading zeros are often lost.
  static String _regKey(Object? v) {
    var t = (v?.toString() ?? '').trim();
    t = t.replaceFirst(RegExp(r'\.0+$'), '');
    return t.toUpperCase().replaceFirst(RegExp(r'^0+'), '');
  }

  static double? _amount(String s) {
    final t = s.replaceAll(',', '').replaceAll('₹', '').trim();
    if (t.isEmpty) return 0;
    return double.tryParse(t);
  }

  static String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime? _ymd(int y, int m, int d) {
    if (y < 1900 || m < 1 || m > 12 || d < 1 || d > 31) return null;
    final dt = DateTime(y, m, d);
    return (dt.month == m && dt.day == d) ? dt : null; // rejects 31-02
  }

  /// Due date: an ISO date (how a date cell reads back), an Excel serial number
  /// (a date cell read as a number), or DD-MM-YYYY. Never guesses MM-DD --
  /// these sheets are written day first.
  static DateTime? _parseDate(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(t);
    if (iso != null) {
      return _ymd(int.parse(iso.group(1)!), int.parse(iso.group(2)!),
          int.parse(iso.group(3)!));
    }
    final serial = double.tryParse(t);
    if (serial != null) {
      return (serial > 20000 && serial < 80000)
          ? DateTime(1899, 12, 30).add(Duration(days: serial.floor()))
          : null;
    }
    final p = t.split(RegExp(r'[/\-.]'));
    if (p.length == 3) {
      final d = int.tryParse(p[0].trim());
      final m = int.tryParse(p[1].trim());
      final y = int.tryParse(p[2].trim());
      if (d != null && m != null && y != null) {
        return _ymd(y < 100 ? 2000 + y : y, m, d);
      }
    }
    return null;
  }

  /// Fee types a column header could mean: exact name first (what Export
  /// writes), then punctuation-blind, then the short name.
  List<Map<String, dynamic>> _feeTypeCandidates(String header) {
    final u = _upper(header);
    final exact = _feeTypes.where((f) => _upper(f['feedesc']) == u).toList();
    if (exact.isNotEmpty) return exact;
    final a = _alnum(header);
    final loose = _feeTypes.where((f) => _alnum(f['feedesc']) == a).toList();
    if (loose.isNotEmpty) return loose;
    return _feeTypes.where((f) => _upper(f['feeshort']) == u).toList();
  }

  Map<String, dynamic>? _resolveSemester(String raw) {
    if (raw.trim().isEmpty) return null;
    final u = _upper(raw);
    for (final s in _semesters) {
      if (_upper(s['semname']) == u) return s;
    }
    for (final s in _semesters) {
      if (_upper(s['semshort']) == u) return s;
    }
    final a = _alnum(raw);
    final m = _semesters
        .where((s) => _alnum(s['semname']) == a || _alnum(s['semshort']) == a)
        .toList();
    return m.length == 1 ? m.first : null;
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  // ─── Pick lists ───────────────────────────────────────────────────────────

  /// Students and class-fee rows for every ticked class. Every student starts
  /// ticked -- the usual export is the whole class -- and the fee ticks follow
  /// the semester.
  ///
  /// Students are ordered by class, then reg no, so a sheet covering several
  /// classes stays grouped the way the admin reads it.
  Future<void> _loadExportLists() async {
    final classes = _pickedClasses.toList();
    final key = _keyOf(classes);
    _stuSearch.clear();
    _feeSearch.clear();
    if (classes.isEmpty) {
      setState(_clearExportLists);
      return;
    }
    setState(() {
      _loadingLists = true;
      _listsKey = key;
      _classStudents = [];
      _classTemplate = [];
      _pickedStudents.clear();
      _pickedFees.clear();
    });
    try {
      final insId = _insId;
      final res = await Future.wait<dynamic>([
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
            .select('stuadmno, stuname, stuclass')
            .eq('ins_id', insId)
            .inFilter('stuclass', classes)
            .eq('activestatus', 1)
            .eq('preadmission', 0)),  // next year's intake: advance screens only
        // classfeedemand is per-schema and has no ins_id column. cfclass comes
        // back too: the fee columns are the union across the ticked classes, so
        // a fee only some of them define still has to be identifiable.
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('classfeedemand')
            .select('cfclass, cffeetype, cfterm')
            .inFilter('cfclass', classes)
            .eq('activestatus', 1)),
      ]);
      // The ticks may have changed again while this was loading.
      if (!mounted || _listsKey != key) return;
      final students = List<Map<String, dynamic>>.from(res[0] as List)
        ..sort((a, b) {
          final c = _upper(a['stuclass']).compareTo(_upper(b['stuclass']));
          if (c != 0) return c;
          return (a['stuadmno']?.toString() ?? '')
              .compareTo(b['stuadmno']?.toString() ?? '');
        });
      setState(() {
        _classStudents = students;
        _classTemplate = List<Map<String, dynamic>>.from(res[1] as List);
        // A semester carried over from the previous selection may not exist in
        // this one's template. Clear it rather than leave the dropdown holding a
        // value that is no longer among its items.
        final terms = {for (final t in _classTemplate) _upper(t['cfterm'])};
        if (_semName != null && !terms.contains(_upper(_semName))) _semName = null;
        _pickedStudents.addAll(students.map((s) => s['stuadmno'].toString()));
        _applyFeeDefaults();
        _loadingLists = false;
      });
    } catch (e) {
      if (!mounted || _listsKey != key) return;
      setState(() => _loadingLists = false);
      _snack('Could not load $_classLabel. ${friendlyError(e)}', AppColors.error);
    }
  }

  void _clearExportLists() {
    _listsKey = null;
    _classStudents = [];
    _classTemplate = [];
    _pickedStudents.clear();
    _pickedFees.clear();
  }

  /// Semesters EVERY ticked class defines in Class Fee Demand, kept in the
  /// Semester master's own order. The sheet is built from that template, so a
  /// term with no class-fee rows has nothing to export or price.
  ///
  /// Shared, not pooled: the sheet writes ONE semester into every row, so a
  /// term only some of the ticked classes define would export the rest of the
  /// students against a template that does not exist for them. Ticking a
  /// YEARLY class together with a semester-wise one therefore offers nothing --
  /// which is the honest answer, since they cannot share a sheet.
  ///
  /// A ticked class with no class-fee rows at all contributes an empty set and
  /// empties the result, for the same reason.
  List<Map<String, dynamic>> get _classTerms {
    if (_pickedClasses.isEmpty) return const [];
    final byClass = <String, Set<String>>{};
    for (final t in _classTemplate) {
      final c = _upper(t['cfclass']);
      final term = _upper(t['cfterm']);
      if (c.isEmpty || term.isEmpty) continue;
      (byClass[c] ??= <String>{}).add(term);
    }
    Set<String>? shared;
    for (final c in _pickedClasses) {
      final terms = byClass[_upper(c)] ?? const <String>{};
      shared = shared == null ? {...terms} : (shared..retainAll(terms));
    }
    final keep = shared ?? const <String>{};
    return _semesters.where((s) => keep.contains(_upper(s['semname']))).toList();
  }

  /// Fee types Class Fee Demand defines for the chosen class + semester.
  Set<String> get _templateFeeNames {
    final sem = _semName;
    if (sem == null) return const {};
    final k = _upper(sem);
    return {
      for (final t in _classTemplate)
        if (_upper(t['cfterm']) == k && _upper(t['cffeetype']).isNotEmpty)
          _upper(t['cffeetype']),
    };
  }

  /// Tick exactly the class fees for this semester; the admin adjusts from there.
  void _applyFeeDefaults() {
    final names = _templateFeeNames;
    _pickedFees
      ..clear()
      ..addAll(_feeTypes
          .where((f) => names.contains(_upper(f['feedesc'])))
          .map((f) => (f['fee_id'] as num).toInt()));
  }

  // ─── Export ───────────────────────────────────────────────────────────────

  Future<void> _export() async {
    final sem = _semName;
    if (_pickedClasses.isEmpty || sem == null) {
      _snack(schoolTerm('Choose a class and a semester to export.'), AppColors.warning);
      return;
    }
    // One class keeps the old file name; several are named by count, since
    // stringing every class into a file name gets unreadable fast.
    final cls = _pickedClasses.length == 1
        ? _pickedClasses.first
        : '${_pickedClasses.length} classes';
    final students = _classStudents
        .where((s) => _pickedStudents.contains(s['stuadmno'].toString()))
        .toList();
    // Fee Master priority order, whatever order they were ticked in.
    final cols = _feeTypes
        .where((f) => _pickedFees.contains((f['fee_id'] as num).toInt()))
        .toList();
    if (students.isEmpty || cols.isEmpty) {
      _snack('Tick at least one student and one fee type.', AppColors.warning);
      return;
    }
    setState(() => _exporting = true);
    try {
      String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Fee Demand Import Sheet',
        fileName: 'Fee_Demand_Import_${safe(cls)}_${safe(sem)}.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;

      final book = xl.Excel.createExcel();
      final sheet = book['Fee Demand Import'];
      book.delete('Sheet1');
      final fixedHdr = xl.CellStyle(
        bold: true,
        fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      // Fee columns in a different colour: those are the cells to fill in.
      final feeHdr = xl.CellStyle(
        bold: true,
        fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#1E40AF'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final headers = <String>[
        'reg no',
        'name',
        'class',
        'sem',
        ...cols.map((f) => f['feedesc'].toString().trim()),
        'duedate',
      ];
      for (var c = 0; c < headers.length; c++) {
        final isFee = c >= 4 && c < headers.length - 1;
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
          ..value = xl.TextCellValue(isFee ? headers[c] : schoolTerm(headers[c]))
          ..cellStyle = isFee ? feeHdr : fixedHdr;
        sheet.setColumnWidth(c, c == 1 ? 28 : (isFee ? 16 : 14));
      }
      for (var r = 0; r < students.length; r++) {
        final s = students[r];
        // Text cells, so a Reg No keeps its leading zeros.
        final vals = [s['stuadmno'], s['stuname'], s['stuclass'], sem];
        for (var c = 0; c < vals.length; c++) {
          sheet
              .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1))
              .value = xl.TextCellValue(vals[c]?.toString() ?? '');
        }
      }
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack(
          'Exported ${students.length} students from $_classLabel '
          'with ${cols.length} fee columns.',
          AppColors.success);
    } catch (e) {
      _snack('Export failed. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ─── Import: read -> validate -> choose -> send ───────────────────────────

  Future<void> _pickAndImport() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;

    setState(() => _importing = true);
    _SheetCheck? check;
    try {
      final bytes =
          f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) throw Exception('The file could not be read');
      final book = xl.Excel.decodeBytes(bytes);
      if (book.tables.isEmpty) throw Exception('The file has no sheets');
      final raw = book.tables[book.tables.keys.first]!
          .rows
          .map((r) => [for (final c in r) c?.value?.toString().trim() ?? ''])
          .toList();
      if (raw.isEmpty) throw Exception('The sheet is empty');
      var width = raw.first.length;
      while (width > 0 && raw.first[width - 1].isEmpty) {
        width--;
      }
      final header = raw.first.sublist(0, width);
      // Every data row is kept -- blank ones too -- so row numbers and the
      // Export with Errors file line up exactly with the sheet the admin has.
      final rows = [
        for (final r in raw.skip(1))
          List<String>.generate(width, (j) => j < r.length ? r[j] : ''),
      ];
      check = await _checkSheet(f.name, header, rows);
    } catch (e) {
      _snack('Could not read the sheet. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
    if (check == null || !mounted) return;
    final send = await _showValidation(check);
    if (send && mounted) await _sendForApproval(check);
  }

  /// Reads the database and checks every row. Writes nothing.
  Future<_SheetCheck> _checkSheet(
      String fileName, List<String> header, List<List<String>> rows) async {
    final auth = context.read<AuthProvider>();
    final insId = _insId;

    // ---- columns ---------------------------------------------------------
    var regCol = -1, nameCol = -1, classCol = -1, semCol = -1, dueCol = -1;
    final feeCols = <int, Map<String, dynamic>>{};
    final warnings = <String>[];
    for (var c = 0; c < header.length; c++) {
      final raw = header[c].trim();
      if (raw.isEmpty) continue;
      final key = _alnum(raw);
      if (regCol < 0 &&
          const {'REGNO', 'REGISTERNO', 'REGNUMBER', 'ROLLNO', 'ADMNO', 'STUADMNO', 'ADMISSIONNO', 'ADMISSIONNUMBER'}
              .contains(key)) {
        regCol = c;
        continue;
      }
      if (nameCol < 0 && const {'NAME', 'STUNAME', 'STUDENTNAME'}.contains(key)) {
        nameCol = c;
        continue;
      }
      if (classCol < 0 && const {'CLASS', 'STUCLASS'}.contains(_alnum(collegeTerm(raw)))) {
        classCol = c;
        continue;
      }
      if (semCol < 0 && const {'SEM', 'SEMESTER', 'TERM'}.contains(key)) {
        semCol = c;
        continue;
      }
      if (dueCol < 0 && const {'DUEDATE', 'DUE'}.contains(key)) {
        dueCol = c;
        continue;
      }
      final cands = _feeTypeCandidates(raw);
      if (cands.isEmpty) {
        warnings.add('Column "$raw" is not a fee type in Fee Master, so it is ignored.');
        continue;
      }
      if (cands.length > 1) {
        warnings.add('Column "$raw" matches more than one fee type in Fee Master, so it is ignored.');
        continue;
      }
      if (feeCols.values.any((v) => v['fee_id'] == cands.first['fee_id'])) {
        warnings.add('Column "$raw" repeats a fee type already in the sheet, so it is ignored.');
        continue;
      }
      feeCols[c] = cands.first;
    }
    final blocking = [
      if (regCol < 0) schoolTerm('There is no "reg no" column.'),
      if (nameCol < 0) 'There is no "name" column.',
      if (semCol < 0) 'There is no "sem" column.',
      if (dueCol < 0) 'There is no "duedate" column.',
      if (feeCols.isEmpty) 'No column is a fee type from Fee Master.',
    ];
    if (blocking.isNotEmpty) {
      return _SheetCheck(
        fileName: fileName,
        header: header,
        rows: rows,
        blocking: blocking,
        warnings: warnings,
        issues: const [],
        badCells: const {},
        staged: const {},
        rowsChecked: 0,
        errorRows: 0,
      );
    }

    // ---- what the checks need ---------------------------------------------
    final data = await Future.wait<dynamic>([
      SupabaseService.fetchAll(() => SupabaseService.fromSchema('students')
          .select('stu_id, stuadmno, stuname, stuclass, courname, yr_id, yrlabel')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .eq('preadmission', 0)),  // next year's intake: advance screens only
      SupabaseService.fetchAll(() => SupabaseService.fromSchema('classfeedemand')
          .select('cf_id, cfclass, cfterm, cffeetype')
          .eq('activestatus', 1)),
      SupabaseService.fetchAll(() => SupabaseService.fromSchema('feedemand')
          .select('stu_id, demfeeterm, demfeetype, demseqtype, demno, paidamount, conamount, con_id')
          .eq('ins_id', insId)
          .eq('activestatus', 1)),
    ]);
    final students = <String, Map<String, dynamic>>{};
    for (final s in List<Map<String, dynamic>>.from(data[0] as List)) {
      final k = _regKey(s['stuadmno']);
      if (k.isNotEmpty) students.putIfAbsent(k, () => s);
    }
    final classIds = <String, int>{
      for (final c in _classes)
        if (c['cla_id'] != null) _upper(c['claname']): (c['cla_id'] as num).toInt(),
    };
    final cfIds = <String, int>{
      for (final c in List<Map<String, dynamic>>.from(data[1] as List))
        if (c['cf_id'] != null)
          '${_upper(c['cfclass'])}|${_upper(c['cfterm'])}|${_upper(c['cffeetype'])}':
              (c['cf_id'] as num).toInt(),
    };
    // Regular demands only: an Arrear demand is a different debt.
    final existing = <String, Map<String, dynamic>>{};
    for (final d in List<Map<String, dynamic>>.from(data[2] as List)) {
      if (_upper(d['demseqtype']) == 'ARREAR' || d['stu_id'] == null) continue;
      existing.putIfAbsent(
          '${d['stu_id']}|${_upper(d['demfeeterm'])}|${_upper(d['demfeetype'])}', () => d);
    }

    // ---- rows ----------------------------------------------------------------
    final issues = <_RowIssue>[];
    final badCells = <int, Set<int>>{};
    final staged = <String, Map<String, dynamic>>{};
    final firstRow = <String, int>{}; // demand key -> Excel row that has it
    var rowsChecked = 0;
    var errorRows = 0;

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final excelRow = i + 2;
      String at(int c) => (c >= 0 && c < row.length) ? row[c].trim() : '';
      if (row.every((v) => v.trim().isEmpty)) continue; // an empty line
      rowsChecked++;

      final reg = at(regCol);
      final name = at(nameCol);
      final rowIssues = <_RowIssue>[];
      final bad = <int>{};
      void flag(int col, String category, String message) {
        rowIssues.add(_RowIssue(excelRow, reg, name, category, message));
        if (col >= 0) bad.add(col);
      }

      // Every fee column is compulsory: 0 means no fee, blank is a mistake.
      // Read here, reported after the student checks so a row's messages
      // follow the sheet's column order.
      final amounts = <int, double>{};
      final amountIssues = <void Function()>[];
      for (final e in feeCols.entries) {
        final text = at(e.key);
        final feeType = e.value['feedesc'].toString().trim();
        final amt = _amount(text);
        if (text.isEmpty) {
          amountIssues.add(() =>
              flag(e.key, 'Amount blank', '$feeType amount is blank (enter 0 if there is no fee)'));
        } else if (amt == null || amt < 0) {
          amountIssues.add(() => flag(e.key, 'Invalid amount', '$feeType "$text" is not a valid amount'));
        } else {
          amounts[e.key] = amt;
        }
      }

      final rowStaged = <String, Map<String, dynamic>>{};
      if (reg.isEmpty) {
        flag(regCol, schoolTerm('Reg No blank'), schoolTerm('Reg No is blank'));
      } else {
        final stu = students[_regKey(reg)];
        if (stu == null) {
          flag(regCol, schoolTerm('Reg No not found'), '${schoolTerm('Reg No')} $reg is not an active student');
        } else {
          // The name must be this student's -- catches a Reg No typed on the
          // wrong row. Spacing, dots and case are ignored.
          final stuName = stu['stuname']?.toString().trim() ?? '';
          if (name.isNotEmpty && _alnum(name) != _alnum(stuName)) {
            flag(nameCol, 'Name mismatch',
                'Name "$name" does not belong to ${schoolTerm('Reg No')} $reg (on record: ${stuName.isEmpty ? 'no name' : stuName})');
            if (regCol >= 0) bad.add(regCol);
          }
          final stuClass = stu['stuclass']?.toString().trim() ?? '';
          final fileClass = at(classCol);
          if (classCol >= 0 && fileClass.isNotEmpty && _alnum(fileClass) != _alnum(stuClass)) {
            flag(classCol, schoolTerm('Class mismatch'), 'Sheet says $fileClass, but the student is in $stuClass');
          }
          final semRaw = at(semCol);
          final sem = _resolveSemester(semRaw);
          if (sem == null) {
            semRaw.isEmpty
                ? flag(semCol, schoolTerm('Semester blank'), schoolTerm('Semester is blank'))
                : flag(semCol, schoolTerm('Unknown semester'), schoolTerm('Semester "$semRaw" is not in the Semester master'));
          }
          final dueRaw = at(dueCol);
          final due = _parseDate(dueRaw);
          if (due == null) {
            dueRaw.isEmpty
                ? flag(dueCol, 'Due date blank', 'Due date is blank')
                : flag(dueCol, 'Invalid due date', 'Due date "$dueRaw" is not DD-MM-YYYY');
          }

          final stuId = (stu['stu_id'] as num).toInt();
          for (final e in feeCols.entries) {
            final amt = amounts[e.key];
            if (amt == null || amt == 0 || sem == null || due == null) continue;
            final feeType = e.value['feedesc'].toString().trim();
            final term = sem['semname'].toString().trim();
            final key = '$stuId|${_upper(term)}|${_upper(feeType)}';
            final dup = firstRow[key];
            if (dup != null) {
              flag(e.key, 'Duplicate fee', '$feeType for $term is already in row $dup');
              continue;
            }
            final ex = existing[key];
            final paid = (ex?['paidamount'] as num?)?.toDouble() ?? 0;
            final con = (ex?['conamount'] as num?)?.toDouble() ?? 0;
            if (ex != null && amt + 0.005 < paid + con) {
              flag(e.key, 'Below paid',
                  '$feeType ${_fmt(amt)} is below already paid ${_fmt(paid)} + concession ${_fmt(con)}');
              continue;
            }
            final demno = ex?['demno']?.toString().trim() ?? '';
            rowStaged[key] = <String, dynamic>{
              'ins_id': insId,
              'inscode': auth.inscode ?? '',
              // Reusing the demno is what makes approval UPDATE the demand.
              if (demno.isNotEmpty) 'demno': demno,
              'demseqtype': 'REGULAR',
              'stu_id': stuId,
              'stuadmno': stu['stuadmno'],
              'stuclass': stuClass,
              'courname': stu['courname'],
              'yr_id': stu['yr_id'],
              'demfeeyear': stu['yrlabel'] ?? '',
              'demfeeterm': term,
              'demfeetype': feeType,
              'feeamount': amt,
              // Carried over: approval writes these back onto the demand.
              'con_id': ex?['con_id'],
              'conamount': con,
              'balancedue': amt - con < 0 ? 0 : amt - con,
              'duedate': _iso(due),
              'cla_id': classIds[_upper(stuClass)],
              'sem_id': sem['sem_id'],
              'fee_id': e.value['fee_id'],
              'cf_id': cfIds['${_upper(stuClass)}|${_upper(term)}|${_upper(feeType)}'],
              'collectible': true,
              'activestatus': 1,
              'createdby': auth.userName,
              'isapproved': false,
            }..removeWhere((k, v) => v == null);
          }
        }
      }
      if (name.isEmpty) flag(nameCol, 'Name blank', 'Name is blank');
      for (final report in amountIssues) {
        report();
      }

      if (rowIssues.isEmpty) {
        for (final k in rowStaged.keys) {
          firstRow[k] = excelRow;
        }
        staged.addAll(rowStaged);
      } else {
        // A row with any problem is skipped whole, so a corrected row is never
        // half in the system.
        issues.addAll(rowIssues);
        badCells[i] = bad;
        errorRows++;
      }
    }

    return _SheetCheck(
      fileName: fileName,
      header: header,
      rows: rows,
      blocking: const [],
      warnings: warnings,
      issues: issues,
      badCells: badCells,
      staged: staged,
      rowsChecked: rowsChecked,
      errorRows: errorRows,
    );
  }

  /// The sheet handed back: every original row, bad cells shaded red, and an
  /// "error" column saying why. Fix it in Excel and import it again.
  Future<void> _exportWithErrors(_SheetCheck c) async {
    try {
      final base = c.fileName.replaceAll(RegExp(r'\.xlsx$', caseSensitive: false), '');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Sheet with Errors',
        fileName: '${base}_errors.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;

      final book = xl.Excel.createExcel();
      final sheet = book['Fee Demand Import'];
      book.delete('Sheet1');
      final hdr = xl.CellStyle(
        bold: true,
        fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final errHdr = xl.CellStyle(
        bold: true,
        fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#B91C1C'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      final badCell = xl.CellStyle(
        bold: true,
        backgroundColorHex: xl.ExcelColor.fromHexString('#FCE4E4'),
        fontColorHex: xl.ExcelColor.fromHexString('#B91C1C'),
      );
      final errText = xl.CellStyle(fontColorHex: xl.ExcelColor.fromHexString('#B91C1C'));

      final errCol = c.header.length;
      for (var j = 0; j <= errCol; j++) {
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: j, rowIndex: 0))
          ..value = xl.TextCellValue(j == errCol ? 'error' : c.header[j])
          ..cellStyle = j == errCol ? errHdr : hdr;
        sheet.setColumnWidth(j, j == errCol ? 60 : (j == 1 ? 28 : 15));
      }
      final msgsByRow = <int, List<String>>{};
      for (final x in c.issues) {
        msgsByRow.putIfAbsent(x.row, () => []).add(x.message);
      }
      for (var i = 0; i < c.rows.length; i++) {
        final r = c.rows[i];
        final bad = c.badCells[i] ?? const <int>{};
        for (var j = 0; j < c.header.length; j++) {
          final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: j, rowIndex: i + 1));
          cell.value = xl.TextCellValue(j < r.length ? r[j] : '');
          if (bad.contains(j)) cell.cellStyle = badCell;
        }
        final msgs = msgsByRow[i + 2];
        if (msgs != null) {
          sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: errCol, rowIndex: i + 1))
            ..value = xl.TextCellValue(msgs.join('; '))
            ..cellStyle = errText;
        }
      }
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack('Saved with ${c.errorRows} row(s) marked. Fix the red cells and import it again.',
          AppColors.success);
    } catch (e) {
      _snack('Export failed. ${friendlyError(e)}', AppColors.error);
    }
  }

  /// Stages what validation approved: clear collisions, then insert.
  Future<void> _sendForApproval(_SheetCheck c) async {
    final insId = _insId;
    final staged = c.staged;
    setState(() {
      _fileName = c.fileName;
      _importing = true;
      _done = false;
      _lines = staged.length;
      _staged = 0;
      _skipped = c.errorRows;
      _errors
        ..clear()
        ..addAll(c.issues.map((x) =>
            'Row ${x.row}${x.regNo.isEmpty ? '' : ' · ${schoolTerm('Reg No')} ${x.regNo}'}: ${x.message}.'));
    });
    try {
      // Approved staging rows (activestatus 9) still hold the demnos reused here.
      try {
        await SupabaseService.fromSchema('tempfeedemand')
            .delete()
            .eq('ins_id', insId)
            .eq('activestatus', 9);
      } catch (e) {
        debugPrint('tempfeedemand cleanup failed: $e');
      }

      // Older still-pending Regular rows for the same demands: replaced, so the
      // approval list holds one row per demand and the latest sheet wins.
      final keys = staged.keys.toSet();
      final stuIds = staged.values.map((r) => r['stu_id'] as int).toSet().toList();
      final stale = <int>[];
      for (var s = 0; s < stuIds.length; s += 200) {
        final part = stuIds.sublist(s, (s + 200).clamp(0, stuIds.length));
        final pending = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('tempfeedemand')
            .select('temp_id, stu_id, demfeeterm, demfeetype, demseqtype')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('isapproved', false)
            .inFilter('stu_id', part));
        for (final p in pending) {
          if (_upper(p['demseqtype']) == 'ARREAR') continue;
          final k = '${p['stu_id']}|${_upper(p['demfeeterm'])}|${_upper(p['demfeetype'])}';
          if (keys.contains(k) && p['temp_id'] != null) {
            stale.add((p['temp_id'] as num).toInt());
          }
        }
      }
      for (var s = 0; s < stale.length; s += 200) {
        await SupabaseService.fromSchema('tempfeedemand')
            .delete()
            .inFilter('temp_id', stale.sublist(s, (s + 200).clamp(0, stale.length)));
      }

      final list = staged.values.toList();
      const size = 100;
      for (var s = 0; s < list.length; s += size) {
        final chunk = list.sublist(s, (s + size).clamp(0, list.length));
        try {
          await SupabaseService.fromSchema('tempfeedemand').insert(chunk);
          _staged += chunk.length;
        } catch (_) {
          // One bad row fails the batch; retry singly so the rest land.
          for (final r in chunk) {
            try {
              await SupabaseService.fromSchema('tempfeedemand').insert(r);
              _staged++;
            } catch (e) {
              _skipped++;
              _errors.add('${schoolTerm('Reg No')} ${r['stuadmno']} · ${r['demfeetype']} (${r['demfeeterm']}): '
                  '${friendlyError(e)}');
            }
          }
        }
        if (mounted) setState(() {});
      }
    } catch (e) {
      _errors.insert(0, 'Stopped: ${friendlyError(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _done = true;
        });
        _showImportResult();
      }
    }
  }

  // ─── Validation window ────────────────────────────────────────────────────

  /// Shows what validation found. Returns true when the admin chooses to send.
  Future<bool> _showValidation(_SheetCheck c) async {
    final ready = c.staged.length;
    final readyRows = c.rowsChecked - c.errorRows;
    final byCategory = <String, int>{};
    for (final x in c.issues) {
      byCategory[x.category] = (byCategory[x.category] ?? 0) + 1;
    }
    final hasBlocking = c.blocking.isNotEmpty;
    final hasIssues = c.issues.isNotEmpty;
    final canSend = !hasBlocking && ready > 0;
    // The Excel-like preview needs a bounded height, so the dialog grows
    // tall whenever there are rows to show.
    final showGrid = !hasBlocking && c.rows.isNotEmpty;

    final Color tone;
    final IconData icon;
    final String headline;
    if (hasBlocking) {
      tone = AppColors.error;
      icon = Icons.error_outline_rounded;
      headline = 'This sheet can\'t be imported yet.';
    } else if (hasIssues) {
      tone = AppColors.warning;
      icon = Icons.warning_amber_rounded;
      headline = '${c.errorRows} row${c.errorRows == 1 ? ' has' : 's have'} problems and will be skipped. '
          'Fix them with Export with Errors, or send the $ready valid demand${ready == 1 ? '' : 's'} now '
          'and import the corrected rows later.';
    } else if (ready > 0) {
      tone = AppColors.success;
      icon = Icons.check_circle_outline_rounded;
      headline = 'All $readyRows row${readyRows == 1 ? ' is' : 's are'} valid. '
          '$ready demand${ready == 1 ? ' is' : 's are'} ready to send for approval.';
    } else {
      tone = AppColors.textSecondary;
      icon = Icons.info_outline_rounded;
      headline = c.rowsChecked == 0
          ? 'The sheet has no student rows.'
          : 'Every amount is 0, so there is nothing to send.';
    }

    var exporting = false;
    var open = true;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        final body = Column(
          mainAxisSize: (showGrid || hasIssues) ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Row(children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                ),
                child: Icon(icon, color: tone, size: 20),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Validation', style: AppUI.cardTitle),
                  Text(c.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppUI.muted),
                ]),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(ctx, false),
                icon: const Icon(Icons.close, size: 20),
              ),
            ]),
            SizedBox(height: 14.h),

            // Counts
            if (!hasBlocking)
              Wrap(spacing: 8.w, runSpacing: 8.h, children: [
                _stat('Rows in sheet', '${c.rowsChecked}', AppColors.textSecondary),
                _stat('Rows ready', '$readyRows', AppColors.success),
                _stat('Rows with errors', '${c.errorRows}',
                    hasIssues ? AppColors.error : AppColors.textLight),
                _stat('Demands ready', '$ready', AppColors.primary),
              ]),
            if (!hasBlocking) SizedBox(height: 12.h),

            // Headline banner
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: tone.withValues(alpha: 0.30)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, size: 17.sp, color: tone),
                SizedBox(width: 8.w),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(headline, style: AppUI.body.copyWith(height: 1.35)),
                    for (final b in c.blocking)
                      Padding(
                        padding: EdgeInsets.only(top: 4.h),
                        child: Text('• $b',
                            style: AppUI.body.copyWith(color: AppColors.error, fontWeight: FontWeight.w600)),
                      ),
                    if (hasBlocking)
                      Padding(
                        padding: EdgeInsets.only(top: 6.h),
                        child: Text('Use Export on this screen to get a sheet with the right columns.',
                            style: AppUI.muted),
                      ),
                  ]),
                ),
              ]),
            ),

            // Ignored columns
            for (final w in c.warnings)
              Padding(
                padding: EdgeInsets.only(top: 8.h),
                child: Row(children: [
                  Icon(Icons.visibility_off_outlined, size: 14.sp, color: AppColors.warning),
                  SizedBox(width: 6.w),
                  Expanded(child: Text(w, style: AppUI.muted)),
                ]),
              ),

            // Sheet contents -- the imported rows, shown like the Excel file
            // so the data can be looked over before anything is sent.
            if (showGrid) ...[
              SizedBox(height: 14.h),
              Row(children: [
                Icon(Icons.table_chart_outlined, size: 15.sp, color: AppColors.textSecondary),
                SizedBox(width: 6.w),
                Text('Sheet contents · ${c.rows.length} row${c.rows.length == 1 ? '' : 's'}',
                    style: AppUI.label.copyWith(color: AppColors.textSecondary)),
                if (hasIssues) ...[
                  SizedBox(width: 8.w),
                  Container(
                    width: 11.w, height: 11.w,
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.15),
                      border: Border.all(color: AppColors.error.withValues(alpha: 0.5)),
                      borderRadius: BorderRadius.circular(2.r),
                    ),
                  ),
                  SizedBox(width: 5.w),
                  Text('cells with a problem', style: AppUI.muted.copyWith(color: AppColors.error)),
                ],
              ]),
              SizedBox(height: 6.h),
              Expanded(flex: hasIssues ? 3 : 1, child: _PreviewGrid(c)),
            ],

            // Problem summary + the list
            if (hasIssues) ...[
              SizedBox(height: 12.h),
              Wrap(spacing: 6.w, runSpacing: 6.h, children: [
                for (final e in byCategory.entries) _chip('${e.key} · ${e.value}', AppColors.error),
              ]),
              SizedBox(height: 8.h),
              Expanded(flex: 2, child: _issueTable(c.issues)),
            ],

            SizedBox(height: 16.h),
            // Actions
            Row(children: [
              if (hasIssues)
                OutlinedButton.icon(
                  onPressed: exporting
                      ? null
                      : () async {
                          setDlg(() => exporting = true);
                          await _exportWithErrors(c);
                          if (open) setDlg(() => exporting = false);
                        },
                  icon: exporting
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.file_download_outlined, size: 17),
                  label: const Text('Export with Errors'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error.withValues(alpha: 0.45)),
                  ),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(canSend ? 'Cancel' : 'Close'),
              ),
              if (canSend) ...[
                SizedBox(width: 8.w),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: Text(hasIssues
                      ? 'Send $ready valid, skip ${c.errorRows} row${c.errorRows == 1 ? '' : 's'}'
                      : 'Send $ready for approval'),
                ),
              ],
            ]),
          ],
        );

        return Dialog(
          child: SizedBox(
            width: 920.w,
            height: (showGrid || hasIssues) ? 680.h : null,
            child: Padding(padding: EdgeInsets.all(AppUI.cardPad), child: body),
          ),
        );
      }),
    );
    open = false;
    return result ?? false;
  }

  Widget _stat(String label, String value, Color c) => Container(
        padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: c.withValues(alpha: 0.22)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(value, style: TextStyle(fontSize: 17.sp, fontWeight: FontWeight.w800, color: c, height: 1.1)),
          Text(label.toUpperCase(), style: AppUI.caps),
        ]),
      );

  Widget _issueTable(List<_RowIssue> issues) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(),
      child: Column(children: [
        Container(
          decoration: AppUI.tableHeadBar,
          padding: EdgeInsets.symmetric(horizontal: 12.w),
          child: Row(children: [
            SizedBox(width: 60.w, child: _headText('Row')),
            Expanded(flex: 2, child: _headText(schoolTerm('Reg No'))),
            Expanded(flex: 3, child: _headText('Name')),
            Expanded(flex: 7, child: _headText('Problem')),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: issues.length,
            itemBuilder: (_, i) {
              final x = issues[i];
              return Container(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 7.h),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: AppColors.divider)),
                ),
                child: Row(children: [
                  SizedBox(
                    width: 60.w,
                    child: Text('${x.row}',
                        style: AppUI.cell.copyWith(fontWeight: FontWeight.w700, color: AppColors.error)),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(x.regNo.isEmpty ? '—' : x.regNo,
                        overflow: TextOverflow.ellipsis,
                        style: AppUI.cell.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(x.name,
                        overflow: TextOverflow.ellipsis,
                        style: AppUI.cell.copyWith(color: AppColors.textSecondary)),
                  ),
                  Expanded(
                    flex: 7,
                    child: Row(children: [
                      AppUI.chip(x.category, AppStatus.danger),
                      SizedBox(width: 8.w),
                      Expanded(
                        child: Text(x.message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppUI.cell),
                      ),
                    ]),
                  ),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }

  // ─── Screen ───────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _visibleStudents {
    final q = _stuSearch.text.trim().toUpperCase();
    if (q.isEmpty) return _classStudents;
    return _classStudents
        .where((s) =>
            s['stuadmno'].toString().toUpperCase().contains(q) ||
            (s['stuname']?.toString().toUpperCase().contains(q) ?? false))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return AppUI.empty(
        title: 'Could not load masters.',
        why: _loadError,
        action: OutlinedButton(onPressed: _loadMasters, child: const Text('Retry')),
      );
    }
    final visible = _visibleStudents;
    final busy = _exporting || _importing;
    final courseId = _course == null
        ? null
        : _courses.firstWhere((c) => c['courname'] == _course,
            orElse: () => const <String, dynamic>{})['cour_id'];
    // Master ordid order within each group, TC batches last
    // (utils/class_sort.dart).
    final classOptions = classGroupPartition(
        _classes
            .where((c) => courseId == null || c['cour_id'] == courseId)
            .map((c) => c['claname'].toString()),
        (s) => s);
    // Only the semesters Class Fee Demand has fees for in the loaded classes.
    final semOptions = _classTerms.map((s) => s['semname'].toString()).toList();
    final canExport = !busy &&
        !_loadingLists &&
        _pickedClasses.isNotEmpty &&
        _semName != null &&
        _pickedStudents.isNotEmpty &&
        _pickedFees.isNotEmpty;

    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title
          Row(children: [
            Expanded(
              child: AppUI.cardHeader(
                icon: 'document-upload',
                title: 'Fee Demand Import',
                subtitle: schoolTerm('export a class, fill in the fee amounts, import and validate for approval'),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: busy ? null : _refresh,
              icon: Icon(Icons.refresh, size: 20.sp, color: AppColors.textSecondary),
            ),
          ]),
          SizedBox(height: 14.h),

          // ── Toolbar: every field shares one height and one label line, and
          // the fields share the width, so nothing wraps or truncates on 1366.
          Container(
            padding: EdgeInsets.all(AppUI.cardPad),
            decoration: AppUI.card(),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              _field(schoolTerm('Course'), flex: 4, DropdownButtonFormField<String>(
                key: ValueKey('fdicourse-${_course ?? ''}'),
                initialValue: _course,
                isExpanded: true,
                isDense: true,
                icon: _arrow(),
                style: _fieldText(),
                decoration: _dec(schoolTerm('All courses')),
                items: [
                  DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All courses'))),
                  ..._courses.map((e) => DropdownMenuItem(
                      value: e['courname'].toString(),
                      child: Text(e['courname'].toString(), overflow: TextOverflow.ellipsis))),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                          _course = v;
                          // The ticked classes may not belong to the new course.
                          _pickedClasses.clear();
                          _clearExportLists();
                        }),
              )),
              SizedBox(width: 10.w),
              _field(schoolTerm('Class'), flex: 4, _classesField(busy, classOptions)),
              SizedBox(width: 10.w),
              _field(schoolTerm('Semester'), flex: 3, DropdownButtonFormField<String>(
                key: ValueKey('fdisem-${_semName ?? ''}-$_listsKey'),
                // Guarded: a value that is not among the items asserts.
                initialValue: semOptions.contains(_semName) ? _semName : null,
                isExpanded: true,
                isDense: true,
                icon: _arrow(),
                style: _fieldText(),
                decoration: _dec(_pickedClasses.isEmpty
                    ? schoolTerm('Choose class first')
                    : semOptions.isEmpty
                        ? (_pickedClasses.length > 1
                            ? schoolTerm('No shared semester')
                            : schoolTerm('No class fees'))
                        : 'Choose'),
                items: semOptions
                    .map((n) => DropdownMenuItem(
                        value: n, child: Text(n, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: busy || semOptions.isEmpty
                    ? null
                    : (v) => setState(() {
                          _semName = v;
                          _applyFeeDefaults();
                        }),
              )),
              SizedBox(width: 10.w),
              _field(schoolTerm('Reg No'), flex: 4, TextField(
                controller: _stuSearch,
                enabled: _classStudents.isNotEmpty,
                style: _fieldText(),
                decoration: _dec(schoolTerm('Search reg no / name')).copyWith(
                  prefixIcon: Icon(Icons.search, size: 17.sp, color: AppColors.textSecondary),
                  suffixIcon: _stuSearch.text.isEmpty
                      ? null
                      : InkWell(
                          onTap: () => setState(_stuSearch.clear),
                          child: Icon(Icons.close, size: 15.sp, color: AppColors.textSecondary),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              )),
              SizedBox(width: 10.w),
              _field('Fee Types', flex: 4, _feeTypesField(busy)),
              SizedBox(width: 14.w),
              OutlinedButton.icon(
                onPressed: canExport ? _export : null,
                icon: _exporting
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_outlined, size: 16),
                label: const Text('Export'),
              ),
              SizedBox(width: 8.w),
              Tooltip(
                message: 'Pick a filled sheet. It is checked first -- nothing is saved until you choose to send.',
                child: ElevatedButton.icon(
                  onPressed: busy ? null : _pickAndImport,
                  icon: _importing
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.upload_outlined, size: 16),
                  label: Text(_importing ? 'Checking…' : 'Import'),
                ),
              ),
            ]),
          ),

          // Thin progress bar while the class list loads or an import runs.
          SizedBox(
            height: 3.h,
            child: (_loadingLists || _importing)
                ? const LinearProgressIndicator(minHeight: 2)
                : null,
          ),
          SizedBox(height: 9.h),

          // ── Status row: counts on the left, last import on the right.
          SizedBox(
            height: 30.h,
            child: Row(children: [
              if (_pickedClasses.isEmpty)
                Text(schoolTerm('Choose one or more classes to list their students.'),
                    style: AppUI.muted)
              else if (_classStudents.isNotEmpty) ...[
                _chip(
                    visible.length == _classStudents.length
                        ? '${_classStudents.length} student${_classStudents.length == 1 ? '' : 's'}'
                        : '${visible.length} of ${_classStudents.length} shown',
                    AppColors.textSecondary),
                SizedBox(width: 8.w),
                _chip('${_pickedStudents.length} selected',
                    _pickedStudents.isNotEmpty ? AppColors.accent : AppColors.textLight),
                SizedBox(width: 8.w),
                _chip('${_pickedFees.length} fee type${_pickedFees.length == 1 ? '' : 's'}',
                    _pickedFees.isNotEmpty ? AppColors.accent : AppColors.textLight),
                if (_semName == null) ...[
                  SizedBox(width: 10.w),
                  Expanded(
                    child: Text(
                        // An empty list with several classes ticked is not the
                        // same as "pick one" -- say which classes disagree, or
                        // it reads as a broken dropdown.
                        semOptions.isNotEmpty
                            ? schoolTerm('Choose a semester to tick its class fees.')
                            : _pickedClasses.length > 1
                                ? schoolTerm('These $_classLabel share no semester in Class Fee Demand, so they cannot go in one sheet. '
                                    'A sheet carries ONE semester for every row -- untick until the classes agree.')
                                : schoolTerm('Class Fee Demand defines no fees for this class.'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppUI.muted.copyWith(color: AppColors.warning)),
                  ),
                ],
              ],
              const Spacer(),
              if (_done)
                Tooltip(
                  message: 'Show the last import result',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20.r),
                    onTap: _showImportResult,
                    child: _chip(
                        'Last import: $_staged sent${_skipped > 0 ? ', $_skipped skipped' : ''}',
                        _errors.isEmpty ? AppColors.success : AppColors.warning),
                  ),
                ),
            ]),
          ),
          SizedBox(height: 8.h),

          Expanded(child: _table(visible)),

          // ── Note
          Container(
            width: double.infinity,
            margin: EdgeInsets.only(top: 10.h),
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
            decoration: BoxDecoration(
              color: AppColors.warningBg,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.30)),
            ),
            child: Row(children: [
              Icon(Icons.info_outline, size: 15.sp, color: AppColors.warning),
              SizedBox(width: 7.w),
              Expanded(
                child: Text(schoolTerm(
                  'Only ticked students and fee types go into the sheet. Import checks the sheet first and saves '
                  'nothing until you choose to send: fix problems with Export with Errors, or send the valid rows. '
                  'Reg No, Name, due date (DD-MM-YYYY) and every fee amount are required; enter 0 where there is no fee. '
                  'Demands are Regular and wait in Fee '
                  'Demand Approval; importing a corrected sheet again updates them instead of duplicating.'),
                  style: AppUI.muted.copyWith(color: AppColors.textSecondary, height: 1.35),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  /// A labelled toolbar field taking [flex] shares of the toolbar width.
  Widget _field(String label, Widget control, {int flex = 4}) => Expanded(
        flex: flex,
        child: _labeled(label, control),
      );

  /// The Class field: a checkbox picker rather than a dropdown, so one sheet
  /// can cover several classes. Reads as the class name while exactly one is
  /// ticked, which is how it is used most of the time.
  Widget _classesField(bool busy, List<String> options) {
    final n = _pickedClasses.length;
    return InkWell(
      key: _classKey,
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      onTap: busy ? null : () => _openClassPicker(options),
      child: InputDecorator(
        decoration: _dec('').copyWith(enabled: !busy, suffixIcon: _arrow()),
        child: Text(
          n == 0 ? schoolTerm('Choose class') : _classLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: n == 0
              ? AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)
              : AppUI.fieldText(context, filled: true),
        ),
      ),
    );
  }

  Widget _feeTypesField(bool busy) {
    final enabled = _pickedClasses.isNotEmpty && !_loadingLists && !busy;
    final n = _pickedFees.length;
    return InkWell(
      key: _feeKey,
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      onTap: enabled ? _openFeePicker : null,
      child: InputDecorator(
        decoration: _dec('').copyWith(
          enabled: enabled,
          suffixIcon: _arrow(),
        ),
        child: Text(
          n == 0 ? 'Choose fee types' : '$n fee type${n == 1 ? '' : 's'} selected',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: n == 0
              ? AppUI.fieldText(context).copyWith(fontWeight: FontWeight.w500, color: AppColors.textLight)
              : AppUI.fieldText(context, filled: true),
        ),
      ),
    );
  }

  Widget _table(List<Map<String, dynamic>> rows) {
    final total = _classStudents.length;
    final allOn = rows.isNotEmpty &&
        rows.every((s) => _pickedStudents.contains(s['stuadmno'].toString()));
    final anyOn = rows.any((s) => _pickedStudents.contains(s['stuadmno'].toString()));

    final Widget body;
    if (_pickedClasses.isEmpty) {
      body = _empty('document-upload', schoolTerm('Choose a class'),
          schoolTerm('Tick one or more classes and a semester to list their students, then tick the students and fee types to put in the sheet.'));
    } else if (_loadingLists) {
      body = const Center(child: CircularProgressIndicator());
    } else if (total == 0) {
      body = _empty('people', 'No students', schoolTerm('This class has no active students.'));
    } else if (rows.isEmpty) {
      body = _empty('search-normal', 'No matches',
          'No student here matches "${_stuSearch.text.trim()}".');
    } else {
      body = ListView.builder(
        itemCount: rows.length,
        itemBuilder: (_, i) {
          final s = rows[i];
          final id = s['stuadmno'].toString();
          final on = _pickedStudents.contains(id);
          void toggle() => setState(() => on ? _pickedStudents.remove(id) : _pickedStudents.add(id));
          return InkWell(
            onTap: toggle,
            child: Container(
              decoration: BoxDecoration(
                color: on ? AppColors.primaryLight : Colors.white,
                border: const Border(bottom: BorderSide(color: AppColors.divider)),
              ),
              padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 1.h),
              child: Row(children: [
                SizedBox(
                  width: 40.w,
                  child: Checkbox(
                    value: on,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (_) => toggle(),
                  ),
                ),
                SizedBox(
                  width: 50.w,
                  child: Text('${i + 1}',
                      style: AppUI.cell.copyWith(color: AppColors.textLight)),
                ),
                Expanded(flex: 3, child: Text(id,
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.cell.copyWith(fontWeight: FontWeight.w600))),
                Expanded(flex: 6, child: Text(s['stuname']?.toString() ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.cell)),
                Expanded(flex: 3, child: Text(s['stuclass']?.toString() ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
              ]),
            ),
          );
        },
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(),
      child: Column(children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 3.h),
          decoration: const BoxDecoration(
            color: AppColors.tableHeadBg,
            border: Border(bottom: BorderSide(color: AppColors.divider)),
          ),
          child: Row(children: [
            SizedBox(
              width: 40.w,
              child: Tooltip(
                message: allOn ? 'Untick all shown' : 'Tick all shown',
                child: Checkbox(
                  tristate: true,
                  value: allOn ? true : (anyOn ? null : false),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  // Acts on the rows the search is showing.
                  onChanged: rows.isEmpty
                      ? null
                      : (_) => setState(() {
                            final ids = rows.map((s) => s['stuadmno'].toString());
                            if (allOn) {
                              _pickedStudents.removeAll(ids);
                            } else {
                              _pickedStudents.addAll(ids);
                            }
                          }),
                ),
              ),
            ),
            SizedBox(width: 50.w, child: _headText('#')),
            Expanded(flex: 3, child: _headText(schoolTerm('Reg No'))),
            Expanded(flex: 6, child: _headText('Student Name')),
            Expanded(flex: 3, child: _headText(schoolTerm('Class'))),
          ]),
        ),
        Expanded(child: body),
      ]),
    );
  }

  Widget _headText(String t) => Padding(
        padding: EdgeInsets.symmetric(vertical: 9.h),
        child: Text(t.toUpperCase(), style: AppUI.tableHead),
      );

  /// Class picker, anchored under the Class field. Several classes can be
  /// ticked: the export then covers all of them in one sheet.
  ///
  /// The students and the class-fee template are reloaded ONCE, when the picker
  /// closes and only if the selection actually changed -- not on every tick,
  /// which would fire a pair of queries per click.
  Future<void> _openClassPicker(List<String> options) async {
    final box = _classKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screen = MediaQuery.of(context).size;
    final w = size.width < 300 ? 300.0 : size.width;
    const maxH = 470.0;
    final left = pos.dx.clamp(8.0, (screen.width - w - 8).clamp(8.0, screen.width));
    final top = (pos.dy + size.height + 4).clamp(8.0, (screen.height - 120).clamp(8.0, screen.height));
    _classSearch.clear();
    final before = _keyOf(_pickedClasses);

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.04),
      builder: (ctx) => Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.pop(ctx),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: w,
          child: StatefulBuilder(builder: (ctx, setLocal) {
            void update(VoidCallback fn) {
              setState(fn);
              setLocal(() {});
            }

            final q = _classSearch.text.trim().toUpperCase();
            final shown =
                options.where((c) => q.isEmpty || _upper(c).contains(q)).toList();

            return Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: Colors.white,
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: maxH),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      color: AppColors.tableHeadBg,
                      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                      child: Row(children: [
                        Expanded(
                          child: Text(schoolTerm('Classes · ${_pickedClasses.length} selected'),
                              style: AppUI.label),
                        ),
                        TextButton(
                            onPressed: () => update(() => _pickedClasses.addAll(shown)),
                            child: const Text('Select all')),
                        TextButton(
                            onPressed: () => update(() => _pickedClasses.removeAll(shown)),
                            child: const Text('Clear')),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      child: TextField(
                        controller: _classSearch,
                        autofocus: true,
                        onChanged: (_) => setLocal(() {}),
                        style: AppUI.fieldText(context),
                        decoration: _dec(schoolTerm('Search class')).copyWith(
                          prefixIcon: const Icon(Icons.search, size: 17, color: AppColors.textSecondary),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Flexible(
                      child: shown.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                  options.isEmpty
                                      ? schoolTerm('No class in ${_course ?? 'this institution'}.')
                                      : schoolTerm('No class matches the search.'),
                                  style: AppUI.muted),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              itemCount: shown.length,
                              itemBuilder: (_, i) {
                                final c = shown[i];
                                return CheckboxListTile(
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  controlAffinity: ListTileControlAffinity.leading,
                                  value: _pickedClasses.contains(c),
                                  onChanged: (v) => update(() {
                                    if (v == true) {
                                      _pickedClasses.add(c);
                                    } else {
                                      _pickedClasses.remove(c);
                                    }
                                  }),
                                  title: Text(c,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppUI.body),
                                );
                              },
                            ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Done'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ]),
    );
    if (!mounted) return;
    if (_keyOf(_pickedClasses) != before) {
      _loadExportLists();
    } else {
      setState(() {});
    }
  }

  /// Fee type picker, anchored under the Fee Types field. Ticks apply as you
  /// click; Select all / Clear act on what the search is showing. Class fees for
  /// the semester are listed first and tagged.
  Future<void> _openFeePicker() async {
    final box = _feeKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screen = MediaQuery.of(context).size;
    const w = 360.0;
    const maxH = 470.0;
    final left = (pos.dx + size.width - w).clamp(8.0, (screen.width - w - 8).clamp(8.0, screen.width));
    final top = (pos.dy + size.height + 4).clamp(8.0, (screen.height - 120).clamp(8.0, screen.height));
    _feeSearch.clear();

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.04),
      builder: (ctx) => Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.pop(ctx),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: w,
          child: StatefulBuilder(builder: (ctx, setLocal) {
            void update(VoidCallback fn) {
              setState(fn);
              setLocal(() {});
            }

            final q = _feeSearch.text.trim().toUpperCase();
            // ONLY the fee types Class Fee Demand defines for the chosen class
            // and semester. A fee outside that template has no class-fee row
            // behind it to price or approve against, so it must not reach the
            // sheet. Fee Master order is preserved (_feeTypes is already sorted
            // by payseq, then name).
            final tpl = _templateFeeNames;
            final classFees =
                _feeTypes.where((f) => tpl.contains(_upper(f['feedesc']))).toList();
            final shown = classFees
                .where((f) =>
                    q.isEmpty ||
                    _upper(f['feedesc']).contains(q) ||
                    _upper(f['feeshort']).contains(q))
                .toList();
            final ids = shown.map((f) => (f['fee_id'] as num).toInt()).toList();

            return Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: Colors.white,
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: maxH),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      color: AppColors.tableHeadBg,
                      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                      child: Row(children: [
                        Expanded(
                          child: Text(schoolTerm('Class Fees · ${_pickedFees.length} selected'),
                              style: AppUI.label),
                        ),
                        TextButton(
                            onPressed: () => update(() => _pickedFees.addAll(ids)),
                            child: const Text('Select all')),
                        TextButton(
                            onPressed: () => update(() => _pickedFees.removeAll(ids)),
                            child: const Text('Clear')),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      child: TextField(
                        controller: _feeSearch,
                        autofocus: true,
                        onChanged: (_) => setLocal(() {}),
                        style: AppUI.fieldText(context),
                        decoration: _dec('Search fee type').copyWith(
                          prefixIcon: const Icon(Icons.search, size: 17, color: AppColors.textSecondary),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Flexible(
                      child: shown.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                  _semName == null
                                      ? schoolTerm('Choose a semester to see its class fees.')
                                      : classFees.isEmpty
                                          ? schoolTerm('Class Fee Demand has no fees for $_classLabel · $_semName.')
                                          : schoolTerm('No class fee matches the search.'),
                                  style: AppUI.muted),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              itemCount: shown.length,
                              itemBuilder: (_, i) {
                                final f = shown[i];
                                final id = (f['fee_id'] as num).toInt();
                                return CheckboxListTile(
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  controlAffinity: ListTileControlAffinity.leading,
                                  value: _pickedFees.contains(id),
                                  onChanged: (v) => update(() {
                                    if (v == true) {
                                      _pickedFees.add(id);
                                    } else {
                                      _pickedFees.remove(id);
                                    }
                                  }),
                                  title: Text(f['feedesc'].toString().trim(),
                                      overflow: TextOverflow.ellipsis,
                                      style: AppUI.body),
                                );
                              },
                            ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Done'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ]),
    );
    if (mounted) setState(() {});
  }

  /// Result of the last send: counts plus every row-level message. Opened when
  /// sending finishes, and again from the status chip.
  Future<void> _showImportResult() async {
    if (!mounted) return;
    final ok = _errors.isEmpty;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 640.w,
          child: Padding(
            padding: EdgeInsets.all(AppUI.cardPad),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: (_staged > 0 ? AppColors.success : AppColors.warning).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                    ),
                    child: Icon(_staged > 0 ? Icons.check_circle_outline_rounded : Icons.info_outline_rounded,
                        color: _staged > 0 ? AppColors.success : AppColors.warning, size: 20),
                  ),
                  SizedBox(width: 12.w),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Import result', style: AppUI.cardTitle),
                      if (_fileName != null)
                        Text(_fileName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppUI.muted),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ]),
                SizedBox(height: 14.h),
                Wrap(spacing: 8.w, runSpacing: 8.h, children: [
                  _stat('Demands ready', '$_lines', AppColors.primary),
                  _stat('Sent for approval', '$_staged', AppColors.success),
                  _stat('Skipped', '$_skipped', _skipped > 0 ? AppColors.error : AppColors.textLight),
                ]),
                SizedBox(height: 12.h),
                Text(
                  _staged > 0
                      ? '$_staged demand${_staged == 1 ? ' is' : 's are'} waiting in Fee Demand Approval.'
                      : 'Nothing was sent for approval.',
                  style: AppUI.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _staged > 0 ? AppColors.success : AppColors.textSecondary),
                ),
                if (!ok) ...[
                  SizedBox(height: 12.h),
                  Text('${_errors.length} skipped item${_errors.length == 1 ? '' : 's'}',
                      style: AppUI.label),
                  SizedBox(height: 6.h),
                  Container(
                    width: double.infinity,
                    constraints: BoxConstraints(maxHeight: 300.h),
                    padding: EdgeInsets.all(10.w),
                    decoration: BoxDecoration(
                      color: AppColors.errorBg,
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                      border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _errors.length,
                      itemBuilder: (_, i) => Padding(
                        padding: EdgeInsets.symmetric(vertical: 3.h),
                        child: Text(_errors[i], style: AppUI.cell),
                      ),
                    ),
                  ),
                ],
                SizedBox(height: 16.h),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Status pill from the kit; the tone picks the matching AppStatus.
  Widget _chip(String text, Color c) => AppUI.chip(
        text,
        c == AppColors.success
            ? AppStatus.success
            : c == AppColors.warning
                ? AppStatus.warning
                : c == AppColors.error
                    ? AppStatus.danger
                    : (c == AppColors.accent || c == AppColors.primary)
                        ? AppStatus.info
                        : AppStatus.neutral,
      );

  Widget _empty(String icon, String title, String hint) => AppUI.empty(
        icon: icon,
        title: title,
        why: hint,
      );

  Widget _labeled(String label, Widget field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 6.h),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label),
          ),
          field,
        ],
      );

  Icon _arrow() => Icon(Icons.keyboard_arrow_down_rounded, size: 20.sp, color: AppColors.textSecondary);

  TextStyle _fieldText() => AppUI.fieldText(context);

  /// One decoration for every toolbar field. The icon constraints matter: left
  /// at their 48px default, a search or arrow icon makes that field taller than
  /// its neighbours, which is what knocked the labels out of line.
  InputDecoration _dec(String hint) => AppUI.field(context, hint).copyWith(
        hintMaxLines: 1,
        prefixIconConstraints: BoxConstraints(minWidth: 34.w, minHeight: 18.h),
        suffixIconConstraints: BoxConstraints(minWidth: 30.w, minHeight: 18.h),
      );
}

/// One problem found while validating a sheet row.
class _RowIssue {
  /// Excel row number, as the admin sees it in the sheet.
  final int row;
  final String regNo;
  final String name;

  /// Short label, used for the summary chips ("Due date blank · 36").
  final String category;
  final String message;

  const _RowIssue(this.row, this.regNo, this.name, this.category, this.message);
}

/// Everything learned from validating one sheet.
class _SheetCheck {
  final String fileName;
  final List<String> header;

  /// Data rows as read; rows[i] is Excel row i + 2.
  final List<List<String>> rows;

  /// Problems that stop the whole sheet (missing required columns).
  final List<String> blocking;

  /// Columns ignored because they are not a single known fee type.
  final List<String> warnings;
  final List<_RowIssue> issues;

  /// rows index -> column indexes to shade red in Export with Errors.
  final Map<int, Set<int>> badCells;

  /// Demands from the rows with no problems -- exactly what sending stages.
  final Map<String, Map<String, dynamic>> staged;
  final int rowsChecked;
  final int errorRows;

  const _SheetCheck({
    required this.fileName,
    required this.header,
    required this.rows,
    required this.blocking,
    required this.warnings,
    required this.issues,
    required this.badCells,
    required this.staged,
    required this.rowsChecked,
    required this.errorRows,
  });
}


/// The imported sheet shown like Excel: a sticky header row then every data
/// row, scrollable both ways with working scrollbars, and cells that failed
/// validation tinted red. Read-only -- fixes are made in Excel and re-imported.
///
/// Its own [ScrollController]s are what make the scrollbars draggable: a
/// Scrollbar with thumbVisibility must share a controller with its scroll view.
/// Header and body sit in ONE horizontal scroll view (so they move together),
/// and only the body scrolls vertically (so the header stays put).
class _PreviewGrid extends StatefulWidget {
  const _PreviewGrid(this.check);

  final _SheetCheck check;

  @override
  State<_PreviewGrid> createState() => _PreviewGridState();
}

class _PreviewGridState extends State<_PreviewGrid> {
  final _h = ScrollController();
  final _v = ScrollController();

  @override
  void dispose() {
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  static String _key(String v) =>
      v.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// A due date cell, shown the way the sheet is meant to be written: DD-MM-YYYY.
  ///
  /// Excel hands a real date cell back as a full ISO timestamp
  /// (2026-09-20T00:00:00.000) or as a serial number, and printing that raw made
  /// the preview look like the sheet was wrong when it was fine. The value is
  /// only reformatted for DISPLAY -- what gets imported is still parsed from the
  /// original cell by _parseDate, which accepts all three forms.
  static String _showCell(String header, String v) {
    final k = _key(header);
    if (k != 'DUEDATE' && k != 'DATE') return v;
    final d = _FeeDemandImportScreenState._parseDate(v);
    if (d == null) return v; // unparseable: show it as typed, flagged as bad
    return '${d.day.toString().padLeft(2, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.check;
    final numW = 48.w;
    double colW(int j) {
      final k = _key(c.header[j]);
      if (const {'NAME', 'STUDENTNAME', 'STUNAME'}.contains(k)) return 190.w;
      if (const {'REGNO', 'ADMNO', 'ROLLNO', 'STUADMNO', 'ADMISSIONNO'}.contains(k)) return 110.w;
      return 128.w;
    }

    var totalW = numW;
    for (var j = 0; j < c.header.length; j++) {
      totalW += colW(j);
    }

    Widget cell(String text, double w, {bool head = false, bool bad = false}) => Container(
          width: w,
          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: head ? 8.h : 6.h),
          decoration: BoxDecoration(
            color: head
                ? AppColors.tableHeadBg
                : (bad ? AppColors.errorBg : null),
            border: const Border(
              right: BorderSide(color: AppColors.divider),
              bottom: BorderSide(color: AppColors.divider),
            ),
          ),
          child: Text(
            head ? text : (text.isEmpty ? '\u2014' : text),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: head
                ? AppUI.tableHead
                : AppUI.cell.copyWith(
                    fontSize: 13.sp,
                    fontWeight: bad ? FontWeight.w700 : FontWeight.w500,
                    color: bad
                        ? AppColors.error
                        : (text.isEmpty ? AppColors.textLight : AppColors.textPrimary),
                  ),
          ),
        );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(radius: AppUI.controlRadius),
      child: Scrollbar(
        controller: _h,
        thumbVisibility: true,
        notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(
          controller: _h,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: totalW,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  cell('#', numW, head: true),
                  for (var j = 0; j < c.header.length; j++) cell(c.header[j], colW(j), head: true),
                ]),
                Expanded(
                  child: Scrollbar(
                    controller: _v,
                    thumbVisibility: true,
                    notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
                    child: ListView.builder(
                      controller: _v,
                      itemCount: c.rows.length,
                      itemBuilder: (_, i) {
                        final row = c.rows[i];
                        final bad = c.badCells[i] ?? const <int>{};
                        return Container(
                          color: bad.isNotEmpty
                              ? AppColors.errorBg.withValues(alpha: 0.5)
                              : Colors.white,
                          child: Row(children: [
                            cell('${i + 2}', numW),
                            for (var j = 0; j < c.header.length; j++)
                              cell(_showCell(c.header[j], j < row.length ? row[j] : ''),
                                  colW(j), bad: bad.contains(j)),
                          ]),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
