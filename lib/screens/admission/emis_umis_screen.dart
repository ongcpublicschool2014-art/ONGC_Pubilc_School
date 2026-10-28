import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/school_terms.dart';
import '../../utils/class_sort.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/form_section_panel.dart';
import '../../widgets/validation_dialog.dart';

/// Bulk entry of the government EMIS / UMIS numbers, class by class.
///
/// These arrive as a spreadsheet from the school or the university, hundreds of
/// rows at a time, so the screen is built around Export → fill in Excel →
/// Import → Save rather than typing. It mirrors New Roll Number, minus the
/// effect date and the change log: unlike a register number, an EMIS/UMIS
/// number isn't referenced by fee demands or receipts, so correcting one is a
/// plain update with nothing to cascade.
///
/// Each number is unique: one student per EMIS number and one per UMIS number,
/// among the institution's active students. That is checked three times:
///   * the grid marks a number another student already has, as it is typed;
///   * Import checks the sheet before anything lands in the grid, lists every
///     problem by row, and Export with Errors hands the sheet back marked up;
///   * Save checks again against the database, so a number someone else saved
///     since this screen loaded is still caught.
class EmisUmisScreen extends StatefulWidget {
  const EmisUmisScreen({super.key});

  @override
  State<EmisUmisScreen> createState() => _EmisUmisScreenState();
}

class _EmisUmisScreenState extends State<EmisUmisScreen> {
  int get _insId => context.read<AuthProvider>().insId ?? 1;

  bool _loading = true;
  bool _saving = false;
  bool _busyIo = false;

  List<Map<String, dynamic>> _students = [];
  List<Map<String, dynamic>> _classes = [];
  List<Map<String, dynamic>> _courses = [];

  String? _course;
  String? _class;

  /// Per-student inputs, keyed by stuadmno. Created on demand by the row
  /// builder — allocating one per student up front would mean thousands under
  /// "All classes" for no gain.
  final Map<String, TextEditingController> _emis = {};
  final Map<String, TextEditingController> _umis = {};

  /// Grid order within a class: 'regno' (default) or 'name'.
  String _order = 'regno';

  final _search = TextEditingController();

  /// Column labels, indexed like the checks below: 0 = EMIS, 1 = UMIS.
  static const _label = ['EMIS', 'UMIS'];

  /// Number columns in use: a school has no UMIS, so only EMIS (col 0).
  static int get _nCols => isSchool ? 1 : 2;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _emis.values) {
      c.dispose();
    }
    for (final c in _umis.values) {
      c.dispose();
    }
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final insId = _insId;
      // All three at once. They do not depend on each other, and awaiting them
      // one after another made opening this screen cost the SUM of the round
      // trips -- the students scan alone pages 1000 rows at a time.
      //
      // fetchAll: PostgREST caps a response at 1000 rows and truncates
      // silently, which would drop whole classes from the list.
      final res = await Future.wait<dynamic>([
        SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('students')
            .select(isSchool
                ? 'stu_id, stuadmno, stuname, stuclass, emisno'
                : 'stu_id, stuadmno, stuname, stuclass, emisno, umisno')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .eq('preadmission', 0)),  // next year's intake: advance screens only
        SupabaseService.fromSchema('class')
            .select('cla_id, claname, cour_id')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        SupabaseService.fromSchema('course')
            .select('cour_id, courname')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
      ]);
      final students = List<Map<String, dynamic>>.from(res[0] as List);
      final classes = res[1];
      final courses = res[2];
      if (!mounted) return;
      setState(() {
        _students = students.map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) => (a['stuadmno'] ?? '')
              .toString()
              .compareTo((b['stuadmno'] ?? '').toString()));
        _classes = (classes as List).map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) => classCompare(
              (a['claname'] ?? '').toString(), (b['claname'] ?? '').toString()));
        _courses = (courses as List).map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) => (a['courname'] ?? '')
              .toString()
              .compareTo((b['courname'] ?? '').toString()));
        _seedControllers();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load the students. ${friendlyError(e)}', AppColors.error);
    }
  }

  /// Prefill from what's already stored, so the grid shows current values and
  /// Save only sends what actually changed.
  void _seedControllers() {
    for (final s in _students) {
      final k = (s['stuadmno'] ?? '').toString();
      if (k.isEmpty) continue;
      _emis.putIfAbsent(k, () => TextEditingController()).text =
          (s['emisno'] ?? '').toString();
      if (!isSchool) {
        _umis.putIfAbsent(k, () => TextEditingController()).text =
            (s['umisno'] ?? '').toString();
      }
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  List<Map<String, dynamic>> get _classOptions {
    if (_course == null) return _classes;
    final id = _courses.firstWhere((c) => c['courname'] == _course,
        orElse: () => const {})['cour_id'];
    if (id == null) return _classes;
    return _classes.where((cl) => cl['cour_id'] == id).toList();
  }

  /// Natural order for a register number: "9" sorts before "18", and "017"
  /// lands next to "17" instead of at the top. A plain string compare put a
  /// bare "9" after "18", which is what the grid used to show. Numbers come
  /// before anything non-numeric; equal values fall back to the raw text so
  /// "17" and "017" keep a stable order.
  static int _cmpRegNo(Object? x, Object? y) {
    final a = (x ?? '').toString().trim();
    final b = (y ?? '').toString().trim();
    final na = num.tryParse(a);
    final nb = num.tryParse(b);
    if (na != null && nb != null) {
      final c = na.compareTo(nb);
      return c != 0 ? c : a.compareTo(b);
    }
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  static int _cmpName(Object? x, Object? y) => (x ?? '')
      .toString()
      .trim()
      .toLowerCase()
      .compareTo((y ?? '').toString().trim().toLowerCase());

  /// The chosen order, applied WITHIN a class. Class stays the primary key
  /// when several are listed, so "All classes" still reads class by class --
  /// the order option sorts inside each one rather than shuffling them
  /// together.
  int _cmpChosen(Map<String, dynamic> a, Map<String, dynamic> b) =>
      _order == 'name'
          ? _cmpName(a['stuname'], b['stuname'])
          : _cmpRegNo(a['stuadmno'], b['stuadmno']);

  /// Students in scope. A null [_class] means every class of the selected
  /// course, ordered by class so the grid still reads class by class.
  List<Map<String, dynamic>> get _rows {
    if (_class != null) {
      return _students.where((s) => (s['stuclass'] ?? '') == _class).toList()
        ..sort(_cmpChosen);
    }
    final allowed = _classOptions.map((e) => e['claname'].toString()).toSet();
    final rows = _course == null
        ? List<Map<String, dynamic>>.from(_students)
        : _students
            .where((s) => allowed.contains((s['stuclass'] ?? '').toString()))
            .toList();
    rows.sort((a, b) {
      final c = (a['stuclass'] ?? '')
          .toString()
          .compareTo((b['stuclass'] ?? '').toString());
      return c != 0 ? c : _cmpChosen(a, b);
    });
    return rows;
  }

  List<Map<String, dynamic>> get _visibleRows {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows
        .where((s) => '${s['stuadmno']} ${s['stuname']}'.toLowerCase().contains(q))
        .toList();
  }

  /// Rows whose EMIS or UMIS differs from what's stored — the Save set.
  List<Map<String, dynamic>> get _changed {
    final out = <Map<String, dynamic>>[];
    for (final s in _rows) {
      if (_onScreen(s, 0) != _stored(s, 0) || (!isSchool && _onScreen(s, 1) != _stored(s, 1))) {
        out.add(s);
      }
    }
    return out;
  }

  // ─────────────────────────────────────────────── number helpers

  /// The stored EMIS (col 0) or UMIS (col 1) number of [s].
  static String _stored(Map<String, dynamic> s, int col) =>
      ((col == 0 ? s['emisno'] : s['umisno']) ?? '').toString().trim();

  /// What the grid shows for [s]: the typed value, else the stored one.
  String _onScreen(Map<String, dynamic> s, int col) {
    final k = (s['stuadmno'] ?? '').toString();
    final c = (col == 0 ? _emis : _umis)[k];
    return (c?.text ?? _stored(s, col)).trim();
  }

  /// number -> the active students the grid shows holding it, per column.
  List<Map<String, List<Map<String, dynamic>>>> _holders() {
    final out = [
      <String, List<Map<String, dynamic>>>{},
      <String, List<Map<String, dynamic>>>{},
    ];
    for (final s in _students) {
      for (var col = 0; col < _nCols; col++) {
        final v = _onScreen(s, col);
        if (v.isNotEmpty) (out[col][v] ??= []).add(s);
      }
    }
    return out;
  }

  static String _who(Map<String, dynamic> s) {
    final n = (s['stuname'] ?? '').toString().trim();
    return schoolTerm('Register No. ${s['stuadmno']}${n.isEmpty ? '' : ' · $n'}');
  }

  static String _list(List<String> items) => items.length <= 3
      ? items.join(', ')
      : '${items.take(3).join(', ')} and ${items.length - 3} more';

  /// Letters and digits only, upper case: for names and classes, where spacing,
  /// dots and case differ between the sheet and the record.
  static String _alnum(Object? v) =>
      (v?.toString() ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Reg No as typed or as Excel stores it: a numeric cell comes back as
  /// "2601.0", and leading zeros are often lost.
  static String _regKey(Object? v) {
    var t = (v?.toString() ?? '').trim();
    t = t.replaceFirst(RegExp(r'\.0+$'), '');
    return t.toUpperCase().replaceFirst(RegExp(r'^0+'), '');
  }

  /// A number cell as typed, or as Excel hands back a numeric one ("1223123123.0").
  static String _cleanNumber(String v) => v.trim().replaceFirst(RegExp(r'\.0+$'), '');

  static final _digits = RegExp(r'^\d{1,30}$');

  // ─────────────────────────────────────────────── export / import

  Future<void> _export() async {
    final rows = _rows;
    if (rows.isEmpty) {
      _snack('Nothing to export for this filter.', AppColors.warning);
      return;
    }
    setState(() => _busyIo = true);
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel[isSchool ? 'EMIS' : 'EMIS UMIS'];
      excel.delete('Sheet1');

      final headers = ['Reg No', 'Student Name', 'Class', 'EMIS No', if (!isSchool) 'UMIS No'];
      for (var c = 0; c < headers.length; c++) {
        sheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
            .value = xl.TextCellValue(schoolTerm(headers[c]));
      }
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final k = (r['stuadmno'] ?? '').toString();
        final row = i + 1;
        // Everything is written as TEXT: these are digit strings, and Excel
        // would turn them into numbers, drop a leading zero and render a long
        // one in scientific notation — both of which come back wrong.
        void put(int c, String v) => sheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row))
            .value = xl.TextCellValue(v);
        put(0, k);
        put(1, (r['stuname'] ?? '').toString());
        put(2, (r['stuclass'] ?? '').toString());
        put(3, _emis[k]?.text.trim() ?? (r['emisno'] ?? '').toString());
        if (!isSchool) put(4, _umis[k]?.text.trim() ?? (r['umisno'] ?? '').toString());
      }
      sheet.setColumnWidth(0, 18);
      sheet.setColumnWidth(1, 30);
      sheet.setColumnWidth(2, 18);
      sheet.setColumnWidth(3, 22);
      if (!isSchool) sheet.setColumnWidth(4, 22);

      final bytes = excel.encode();
      if (bytes == null) return;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: schoolTerm('Export students for EMIS / UMIS'),
        fileName: '${isSchool ? 'EMIS' : 'EMIS_UMIS'}_${_class ?? _course ?? 'All'}.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      await File(path).writeAsBytes(bytes);
      if (mounted) {
        _snack('Exported ${rows.length} students to $path', AppColors.success);
      }
    } catch (e) {
      if (mounted) _snack('Could not export the sheet. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busyIo = false);
    }
  }

  /// Import: read → check → show what the check found → fill the grid with the
  /// valid rows only if the admin chooses to. Nothing is saved here; Save does
  /// that, and checks again.
  Future<void> _import() async {
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (picked == null || picked.files.single.path == null) return;
    final file = picked.files.single;
    setState(() => _busyIo = true);
    _ImportCheck? check;
    try {
      final bytes = await File(file.path!).readAsBytes();
      final excel = xl.Excel.decodeBytes(bytes);
      if (excel.tables.isEmpty) throw Exception('The file has no sheets');
      final raw = excel.tables[excel.tables.keys.first]!
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
      // Export with Errors file line up exactly with the admin's sheet.
      final rows = [
        for (final r in raw.skip(1))
          List<String>.generate(width, (j) => j < r.length ? r[j] : ''),
      ];
      check = _checkSheet(file.name, header, rows);
    } catch (e) {
      _snack('Could not import the sheet. ${friendlyError(e)} Check that it is an .xlsx file exported from this screen.', AppColors.error);
    } finally {
      if (mounted) setState(() => _busyIo = false);
    }
    if (check == null || !mounted) return;
    if (await _showImportValidation(check) && mounted) _applyImport(check);
  }

  _ImportCheck _checkSheet(
      String fileName, List<String> header, List<List<String>> rows) {
    // ---- columns, found by header name so extra columns or another order
    // still import.
    var regCol = -1, nameCol = -1, classCol = -1;
    final numCol = [-1, -1];
    for (var c = 0; c < header.length; c++) {
      final key = _alnum(collegeTerm(header[c]));
      if (key.isEmpty) continue;
      if (regCol < 0 &&
          const {'REGNO', 'REGISTERNO', 'OLDREGNO', 'ADMNO', 'ADMISSIONNO', 'STUADMNO', 'ROLLNO'}
              .contains(key)) {
        regCol = c;
      } else if (nameCol < 0 && const {'STUDENTNAME', 'NAME', 'STUNAME'}.contains(key)) {
        nameCol = c;
      } else if (classCol < 0 && const {'CLASS', 'STUCLASS'}.contains(key)) {
        classCol = c;
      } else if (numCol[0] < 0 &&
          (const {'EMISNO', 'EMIS', 'EMISNUMBER'}.contains(key) ||
              // the school heading Export writes: "EMIS No / APAAR ID"
              (isSchool && const {'EMISNOAPAARID', 'EMISAPAARID'}.contains(key)))) {
        numCol[0] = c;
      } else if (!isSchool && numCol[1] < 0 && const {'UMISNO', 'UMIS', 'UMISNUMBER'}.contains(key)) {
        numCol[1] = c;
      }
    }
    final blocking = [
      if (regCol < 0) schoolTerm('The sheet has no "Reg No" column. Use Export to get a sheet with the right columns.'),
      if (nameCol < 0) 'There is no "Student Name" column.',
      if (numCol[0] < 0 && (isSchool || numCol[1] < 0))
        isSchool ? schoolTerm('There is no "EMIS No" column.') : 'There is no "EMIS No" or "UMIS No" column.',
    ];
    if (blocking.isNotEmpty) {
      return _ImportCheck(
          fileName: fileName, header: header, rows: rows, blocking: blocking,
          entries: const [], rowsChecked: 0, fills: 0);
    }

    final byReg = <String, Map<String, dynamic>>{};
    for (final s in _students) {
      final k = _regKey(s['stuadmno']);
      if (k.isNotEmpty) byReg.putIfAbsent(k, () => s);
    }
    final inScope = {for (final s in _rows) (s['stuadmno'] ?? '').toString()};
    final firstRowOf = <String, int>{};
    final entries = <_SheetRow>[];
    var rowsChecked = 0;

    // ---- each row on its own
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.every((v) => v.trim().isEmpty)) continue; // an empty line
      rowsChecked++;
      String at(int c) => (c >= 0 && c < row.length) ? row[c].trim() : '';
      final e = _SheetRow(i, i + 2, at(regCol), at(nameCol));

      if (e.reg.isEmpty) {
        e.flag(regCol, schoolTerm('Register No. blank'), schoolTerm('Register No. is blank'));
      } else {
        final stu = byReg[_regKey(e.reg)];
        if (stu == null) {
          e.flag(regCol, schoolTerm('Register No. not found'), schoolTerm('Register No. ${e.reg} does not belong to an active student'));
        } else {
          e.student = stu;
          final dup = firstRowOf[e.key];
          if (dup != null) {
            e.flag(regCol, schoolTerm('Register No. repeated'), schoolTerm('Register No. ${e.reg} is already in row $dup'));
          } else {
            firstRowOf[e.key] = e.row;
          }
          // The name must be this student's -- catches a Reg No typed on the
          // wrong row. Spacing, dots and case are ignored.
          final stuName = (stu['stuname'] ?? '').toString().trim();
          if (e.name.isNotEmpty && _alnum(e.name) != _alnum(stuName)) {
            e.flag(nameCol, 'Name mismatch',
                schoolTerm('Name "${e.name}" does not match Register No. ${e.reg} (on record: ${stuName.isEmpty ? 'no name' : stuName})'));
            if (regCol >= 0) e.bad.add(regCol);
          }
          final stuClass = (stu['stuclass'] ?? '').toString().trim();
          final fileClass = at(classCol);
          if (fileClass.isNotEmpty && _alnum(fileClass) != _alnum(stuClass)) {
            e.flag(classCol, schoolTerm('Class mismatch'), schoolTerm('Sheet says $fileClass, but the student is in $stuClass'));
          } else if (!inScope.contains(e.key)) {
            // The grid only holds the chosen course / class, and Save only
            // sends what the grid holds.
            e.flag(regCol, 'Outside filter',
                schoolTerm('The student is in $stuClass, outside the course / class chosen on screen'));
          }
        }
      }
      if (e.name.isEmpty) e.flag(nameCol, 'Name blank', 'Name is blank');

      for (var col = 0; col < _nCols; col++) {
        final raw = at(numCol[col]);
        if (raw.isEmpty) continue; // blank leaves the number as it is
        final v = _cleanNumber(raw);
        if (col == 0 && _digits.hasMatch(v) && emisInvalid(v)) {
          e.flag(numCol[col], 'Invalid ${_label[col]}', '$kEmisRuleMsg -- "$raw" has ${v.length}');
        } else if (_digits.hasMatch(v)) {
          e.values[col] = v;
        } else {
          e.flag(numCol[col], 'Invalid ${_label[col]}',
              '${schoolTerm('${_label[col]} No')} "$raw" must be digits only, up to 30 (format the column as Text in Excel)');
        }
      }
      entries.add(e);
    }

    // ---- unique numbers, judged on the grid as it would be after the fill:
    // the valid rows' numbers, everyone else's as the grid shows them. Rows
    // that fail drop out and the check runs again, because a row that no
    // longer fills leaves its student holding a number another row may want.
    var again = true;
    while (again) {
      again = false;
      final live = entries.where((e) => e.ok).toList();
      for (var col = 0; col < _nCols; col++) {
        final incoming = <String, _SheetRow>{}; // stuadmno -> row filling it
        for (final e in live) {
          if (e.values[col] != null) incoming[e.key] = e;
        }
        final holders = <String, List<Map<String, dynamic>>>{};
        for (final s in _students) {
          final k = (s['stuadmno'] ?? '').toString();
          final v = incoming[k]?.values[col] ?? _onScreen(s, col);
          if (v.isNotEmpty) (holders[v] ??= []).add(s);
        }
        for (final e in incoming.values) {
          final v = e.values[col]!;
          final others = (holders[v] ?? const <Map<String, dynamic>>[])
              .where((s) => (s['stuadmno'] ?? '').toString() != e.key)
              .toList();
          if (others.isEmpty) continue;
          final where = [
            for (final s in others)
              incoming[(s['stuadmno'] ?? '').toString()] != null
                  ? 'row ${incoming[(s['stuadmno'] ?? '').toString()]!.row}'
                  : _who(s),
          ];
          e.flag(numCol[col], 'Duplicate ${_label[col]}',
              '${schoolTerm('${_label[col]} No')} $v is also on ${_list(where)}');
          again = true;
        }
      }
    }

    var fills = 0;
    for (final e in entries.where((e) => e.ok)) {
      for (var col = 0; col < _nCols; col++) {
        final v = e.values[col];
        if (v != null && v != _onScreen(e.student!, col)) fills++;
      }
    }

    return _ImportCheck(
        fileName: fileName, header: header, rows: rows, blocking: const [],
        entries: entries, rowsChecked: rowsChecked, fills: fills);
  }

  Future<bool> _showImportValidation(_ImportCheck c) {
    final ready = c.ready.length;
    final err = c.errorRows;
    final canFill = c.blocking.isEmpty && c.fills > 0;
    String s(int n) => n == 1 ? '' : 's';

    final String headline;
    if (c.blocking.isNotEmpty) {
      headline = 'This sheet can\'t be imported yet.';
    } else if (err > 0) {
      headline = canFill
          ? '$err row${err == 1 ? ' has' : 's have'} problems and will be skipped. Fix them with Export with '
              'Errors, or fill in the ${c.fills} number${s(c.fills)} from the $ready valid row${s(ready)} now '
              'and import the corrected rows later.'
          : '$err row${err == 1 ? ' has' : 's have'} problems. Fix them with Export with Errors and import '
              'the sheet again.';
    } else if (c.rowsChecked == 0) {
      headline = 'The sheet has no student rows.';
    } else if (canFill) {
      headline = 'All $ready row${ready == 1 ? ' is' : 's are'} valid. ${c.fills} number${s(c.fills)} will be '
          'filled in on screen — review, then Save.';
    } else {
      headline = 'All rows are valid, and every number already matches the screen.';
    }

    final messages = <int, List<String>>{};
    final badCells = <int, Set<int>>{};
    for (final e in c.entries.where((e) => !e.ok)) {
      messages[e.index] = [for (final x in e.issues) x.message];
      badCells[e.index] = e.bad;
    }

    return showValidationDialog(
      context,
      subtitle: c.fileName,
      rowLabel: 'Row',
      stats: c.blocking.isNotEmpty
          ? const []
          : [
              ('Rows in sheet', c.rowsChecked, AppColors.textSecondary),
              ('Rows ready', ready, AppColors.success),
              ('Rows with errors', err, err > 0 ? AppColors.error : AppColors.textLight),
              ('Numbers to fill', c.fills, AppColors.accent),
            ],
      headline: headline,
      blocking: c.blocking,
      blockingHint: 'Use Export on this screen to get a sheet with the right columns.',
      issues: c.issues,
      onExport: () => _exportWithErrors(
          fileName: c.fileName, header: c.header, rows: c.rows,
          badCells: badCells, messages: messages),
      actionLabel: canFill
          ? (err > 0 ? 'Fill $ready valid, skip $err row${s(err)}' : 'Fill ${c.fills} number${s(c.fills)}')
          : null,
      actionIcon: Icons.edit_note_rounded,
    );
  }

  void _applyImport(_ImportCheck c) {
    var fills = 0;
    for (final e in c.ready) {
      for (var col = 0; col < _nCols; col++) {
        final v = e.values[col];
        if (v == null) continue;
        final ctl = (col == 0 ? _emis : _umis).putIfAbsent(e.key, () => TextEditingController());
        if (ctl.text.trim() != v) {
          ctl.text = v;
          fills++;
        }
      }
    }
    setState(() {});
    _snack('$fills number${fills == 1 ? '' : 's'} filled in. Review, then Save.', AppColors.success);
  }

  /// The sheet handed back marked up: bad cells red and an Error column saying
  /// why. Fix it in Excel and import it again.
  Future<void> _exportWithErrors({
    required String fileName,
    required List<String> header,
    required List<List<String>> rows,
    required Map<int, Set<int>> badCells,
    required Map<int, List<String>> messages,
  }) async {
    try {
      final saved = await exportSheetWithErrors(
          fileName: fileName,
          sheetName: isSchool ? 'EMIS' : 'EMIS UMIS',
          header: header,
          rows: rows,
          badCells: badCells,
          messages: messages);
      if (saved) {
        _snack('Saved with ${messages.length} row(s) marked. Fix the red cells and import it again.',
            AppColors.success);
      }
    } catch (e) {
      _snack('Could not export the error sheet. ${friendlyError(e)}', AppColors.error);
    }
  }

  // ─────────────────────────────────────────────────────── save

  Future<void> _save() async {
    final changed = _changed;
    if (changed.isEmpty) {
      _snack(schoolTerm('Nothing to save — no EMIS / UMIS number changed.'), AppColors.warning);
      return;
    }
    setState(() => _saving = true);
    _SaveCheck? check;
    try {
      check = await _checkSave(changed);
    } catch (e) {
      _snack('Could not check for duplicate numbers. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (check == null || !mounted) return;

    var toSave = changed;
    if (check.errorRows > 0) {
      if (!await _showSaveValidation(check) || !mounted) return;
      toSave = [for (final e in check.ready) e.student];
    }
    await _write(toSave);
  }

  /// Each changed number must not be held by another active student. The
  /// others are read fresh from the database: someone may have saved a number
  /// since this screen loaded.
  Future<_SaveCheck> _checkSave(List<Map<String, dynamic>> changed) async {
    final fresh = List<Map<String, dynamic>>.from(await SupabaseService.fetchAll(
        () => SupabaseService.fromSchema('students')
            .select(isSchool
                ? 'stu_id, stuadmno, stuname, emisno'
                : 'stu_id, stuadmno, stuname, emisno, umisno')
            .eq('ins_id', _insId)
            .eq('activestatus', 1)
            .eq('preadmission', 0)));  // next year's intake: advance screens only
    final scope = _rows;
    final gridNo = <String, int>{
      for (var i = 0; i < scope.length; i++) (scope[i]['stuadmno'] ?? '').toString(): i + 1,
    };
    final entries = [
      for (final s in changed)
        _SaveRow(
          s,
          gridNo[(s['stuadmno'] ?? '').toString()] ?? 0,
          [_onScreen(s, 0), _onScreen(s, 1)],
          [_onScreen(s, 0) != _stored(s, 0), !isSchool && _onScreen(s, 1) != _stored(s, 1)],
        ),
    ];

    // A changed school EMIS No. must be exactly 12 digits.
    for (final e in entries) {
      if (e.changedCol[0] && emisInvalid(e.values[0])) {
        e.flag(0, 'Invalid ${_label[0]}', '$kEmisRuleMsg -- ${e.values[0]} has ${e.values[0].length}');
      }
    }

    // As in Import: students that fail keep their stored number, so check
    // again until nothing new fails.
    var again = true;
    while (again) {
      again = false;
      final live = {for (final e in entries.where((e) => e.ok)) e.stuId: e};
      for (var col = 0; col < _nCols; col++) {
        final holders = <String, List<Object>>{}; // number -> _SaveRow | fresh row
        for (final f in fresh) {
          final e = live[(f['stu_id'] as num).toInt()];
          final v = e != null ? e.values[col] : _stored(f, col);
          if (v.isNotEmpty) (holders[v] ??= []).add(e ?? f);
        }
        for (final e in live.values) {
          if (!e.changedCol[col] || e.values[col].isEmpty) continue;
          final v = e.values[col];
          final where = <String>[];
          for (final h in holders[v] ?? const <Object>[]) {
            if (h is _SaveRow) {
              if (h.stuId != e.stuId) where.add('${_who(h.student)} (not saved yet)');
            } else if (h is Map<String, dynamic> && (h['stu_id'] as num?)?.toInt() != e.stuId) {
              where.add(_who(h));
            }
          }
          if (where.isEmpty) continue;
          e.flag(col, 'Duplicate ${_label[col]}', '${schoolTerm('${_label[col]} No')} $v is also on ${_list(where)}');
          again = true;
        }
      }
    }
    return _SaveCheck(entries);
  }

  Future<bool> _showSaveValidation(_SaveCheck c) {
    final ready = c.ready.length;
    final err = c.errorRows;
    String s(int n) => n == 1 ? '' : 's';

    // The grid as it stands, for Export with Errors.
    final scope = _rows;
    final messages = <int, List<String>>{};
    final badCells = <int, Set<int>>{};
    for (final e in c.entries.where((e) => !e.ok && e.gridNo > 0)) {
      messages[e.gridNo - 1] = [for (final x in e.issues) x.message];
      badCells[e.gridNo - 1] = {for (final col in e.badCols) col + 3};
    }

    return showValidationDialog(
      context,
      subtitle: schoolTerm('Save · ${_class ?? _course ?? 'All classes'}'),
      rowLabel: '#',
      stats: [
        ('Students changed', c.entries.length, AppColors.textSecondary),
        ('Ready to save', ready, AppColors.success),
        ('With errors', err, AppColors.error),
      ],
      headline: ready > 0
          ? '$err student${err == 1 ? ' has' : 's have'} a number another student already has, and will be '
              'skipped. Fix the numbers on screen, or save the $ready valid student${s(ready)} now.'
          : 'Every changed student has a number another student already has. Fix the numbers on screen, '
              'then Save again.',
      issues: c.issues,
      onExport: () => _exportWithErrors(
        fileName: '${isSchool ? 'EMIS' : 'EMIS_UMIS'}_${_class ?? _course ?? 'All'}.xlsx',
        header: [for (final h in ['Reg No', 'Student Name', 'Class', 'EMIS No', if (!isSchool) 'UMIS No']) schoolTerm(h)],
        rows: [
          for (final r in scope)
            [
              (r['stuadmno'] ?? '').toString(),
              (r['stuname'] ?? '').toString(),
              (r['stuclass'] ?? '').toString(),
              _onScreen(r, 0),
              if (!isSchool) _onScreen(r, 1),
            ],
        ],
        badCells: badCells,
        messages: messages,
      ),
      actionLabel: ready > 0 ? 'Save $ready valid, skip $err' : null,
      actionIcon: Icons.save,
    );
  }

  Future<void> _write(List<Map<String, dynamic>> rows) async {
    setState(() => _saving = true);
    var done = 0;
    final failures = <String>[];
    try {
      final insId = _insId;
      for (final s in rows) {
        final k = (s['stuadmno'] ?? '').toString();
        final e = _emis[k]?.text.trim() ?? '';
        final u = _umis[k]?.text.trim() ?? '';
        final patch = <String, dynamic>{
          'emisno': e.isEmpty ? null : e,
          if (!isSchool) 'umisno': u.isEmpty ? null : u,
        };
        try {
          // updateStudent, not a direct update: it goes through the
          // session-gated save_student RPC when a token is held, and it
          // invalidates the cached student list the Students screen reads.
          await SupabaseService.updateStudent(
              (s['stu_id'] as num).toInt(), patch);
          // Also stamp the admission row. It is upstream of students —
          // save_admission pushes an allocated admission's columns down — so
          // leaving it blank here would let a later admission edit wipe the
          // number back out. Deliberately a narrow direct update rather than
          // the save_admission RPC: that RPC re-pushes the WHOLE admission row
          // onto students, which would revert any field edited on the student
          // since allocation.
          try {
            await SupabaseService.client
                .from('admission')
                .update(patch)
                .eq('ins_id', insId)
                .eq('admno', k);
          } catch (_) {
            // No admission row (student came in through import) — the students
            // row is the one that matters, so this is not a failure.
          }
          // Reflect it locally so the row stops counting as changed.
          s['emisno'] = patch['emisno'];
          if (!isSchool) s['umisno'] = patch['umisno'];
          done++;
        } catch (e) {
          failures.add('$k: ${friendlyError(e)}');
        }
      }
      if (!mounted) return;
      setState(() {});
      final left = _changed.length;
      if (failures.isEmpty) {
        _snack(
            left > 0
                ? '$done student(s) updated. $left still to fix.'
                : '$done student(s) updated.',
            left > 0 ? AppColors.warning : AppColors.success);
      } else {
        _snack('$done ${done == 1 ? 'student' : 'students'} updated. ${failures.length} could not be updated: ${failures.first}',
            AppColors.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ─────────────────────────────────────────────────────── ui

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final rows = _rows;
    final visible = _visibleRows;
    final changed = _changed.length;
    final holders = _holders();
    var clashing = 0;
    for (final s in rows) {
      for (var col = 0; col < _nCols; col++) {
        final v = _onScreen(s, col);
        if (v.isNotEmpty && (holders[col][v]?.length ?? 0) > 1) {
          clashing++;
          break;
        }
      }
    }

    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Title in its own card, matching New Roll Number: the page then reads
        // as three stacked panels rather than a bare heading over two cards.
        Container(
          padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, 12.w, 16.h),
          decoration: AppUI.card(),
          child: AppUI.cardHeader(
            icon: 'note-1',
            title: schoolTerm('EMIS / UMIS'),
            subtitle: isSchool ? schoolTerm('Assign EMIS No for students') : 'Assign EMIS and UMIS numbers for students',
            trailing: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _load,
                icon: Icon(Icons.refresh,
                    size: 20.sp, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        SizedBox(height: AppUI.gap),

        // filters + actions
        Container(
          padding: EdgeInsets.all(AppUI.cardPad),
          decoration: AppUI.card(),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
                flex: 4,
                child: FormFieldLabel(
                    label: schoolTerm('Course'), icon: 'teacher', child: _courseDrop())),
            SizedBox(width: 12.w),
            Expanded(
                flex: 4,
                child: FormFieldLabel(
                    label: schoolTerm('Class'), icon: 'book', child: _classDrop())),
            SizedBox(width: 12.w),
            Expanded(
                flex: 3,
                child: FormFieldLabel(
                    label: 'Sort By', icon: 'sort', child: _orderDrop())),
            SizedBox(width: 12.w),
            Expanded(
              flex: 4,
              child: FormFieldLabel(
                label: AppText.search,
                icon: 'hashtag',
                child: TextField(
                controller: _search,
                style: AppUI.fieldText(context),
                decoration: AppUI.field(context, schoolTerm('Search by register no. or name')).copyWith(
                  prefixIcon: Icon(Icons.search, size: 17.sp, color: AppColors.textSecondary),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: AppText.clear,
                          icon: Icon(Icons.close, size: 15.sp, color: AppColors.textSecondary),
                          onPressed: () => setState(_search.clear),
                        ),
                ),
                onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            SizedBox(width: 14.w),
            OutlinedButton.icon(
              onPressed: _busyIo || _saving ? null : _export,
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('Export'),
            ),
            SizedBox(width: 8.w),
            Tooltip(
              message: 'Select a filled sheet. It is checked first, and nothing changes on screen until you choose to fill it in.',
              child: OutlinedButton.icon(
                onPressed: _busyIo || _saving ? null : _import,
                icon: _busyIo
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_outlined, size: 16),
                label: const Text('Import'),
              ),
            ),
            SizedBox(width: 8.w),
            ElevatedButton.icon(
              onPressed: (_saving || _busyIo || changed == 0) ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save, size: 16),
              label: Text(changed > 0 ? 'Save ($changed)' : 'Save'),
            ),
          ]),
        ),
        // Counts sit under the toolbar, so a new chip never squeezes the fields
        // or pushes the buttons off the edge.
        if (rows.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: 10.h),
            child: Row(children: [
              _chip(
                  visible.length == rows.length
                      ? '${rows.length} student${rows.length == 1 ? '' : 's'}'
                      : '${visible.length} of ${rows.length}',
                  AppColors.success, icon: 'profile-2user'),
              SizedBox(width: 8.w),
              _chip('$changed to update',
                  changed > 0 ? AppColors.warning : AppColors.textLight,
                  icon: 'clock'),
              if (clashing > 0) ...[
                SizedBox(width: 8.w),
                Tooltip(
                  message: isSchool
                      ? schoolTerm('Students whose EMIS No another student also has. '
                          'The numbers are marked red.')
                      : 'Students whose EMIS or UMIS number another student also has. '
                          'The numbers are marked red.',
                  child: _chip('$clashing duplicate${clashing == 1 ? '' : 's'}', AppColors.error),
                ),
              ],
            ]),
          ),
        SizedBox(height: AppUI.gap),

        // The table (with its headers) is always on screen; the message for
        // "no students" sits inside the body -- as on New Register Number.
        Expanded(child: _table(visible, holders)),

        // ── Note
        Container(
          width: double.infinity,
          margin: EdgeInsets.only(top: 10.h),
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
          decoration: BoxDecoration(
            color: AppColors.warningBg,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.warning.withValues(alpha: 0.25)),
          ),
          child: Row(children: [
            Icon(Icons.info_outline, size: 15.sp, color: AppColors.warning),
            SizedBox(width: 7.w),
            Expanded(
                child: Text(
              isSchool
                  ? schoolTerm('Each EMIS No. belongs to one student -- a number another student already has is marked red '
                      'and is not saved. Use Export to fill the numbers in Excel and Import to bring them back; Save stores them.')
                  : 'Each EMIS and UMIS number belongs to one student -- a number another student already has is marked red '
                      'and is not saved. Use Export to fill the numbers in Excel and Import to bring them back; Save stores them.',
              style: AppUI.muted.copyWith(color: AppColors.textSecondary, height: 1.35),
            )),
          ]),
        ),
      ]),
    );
  }

  Widget _table(List<Map<String, dynamic>> visible, List<Map<String, List<Map<String, dynamic>>>> holders) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(),
      child: Column(children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
          decoration: const BoxDecoration(
            color: AppColors.tableHeadBg,
            border: Border(bottom: BorderSide(color: AppColors.divider)),
          ),
          child: Row(children: [
            SizedBox(width: 40.w, child: Text('#', style: _hStyle())),
            _hc(schoolTerm('Register No.'), 3, 'hashtag'),
            _hc('Student Name', 5, 'profile-2user'),
            // Class only earns a column when the list spans more than one.
            if (_class == null) _hc(schoolTerm('Class'), 3, 'book'),
            _hc(schoolTerm('EMIS No.'), 3, 'note-1'),
            if (!isSchool) _hc('UMIS No.', 3, 'note-1'),
          ]),
        ),
        Expanded(
          child: visible.isEmpty
              ? _search.text.trim().isNotEmpty
                  ? AppUI.empty(title: 'No matches', why: 'No student here matches "${_search.text.trim()}".', icon: 'search-normal')
                  : AppUI.empty(
                      title: 'No students',
                      why: _class == null
                          ? schoolTerm('There are no active students for this course.')
                          : schoolTerm('This class has no active students.'),
                      icon: 'people')
              : ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                  itemBuilder: (_, i) => _row(visible[i], i, holders),
                ),
        ),
      ]),
    );
  }

  TextStyle _hStyle() => AppUI.tableHead;

  /// A column heading with the glyph that names it, as on New Register Number.
  Widget _hc(String t, int flex, String icon) => Expanded(
        flex: flex,
        child: Row(children: [
          AppIcon.linear(icon, size: 13, color: AppColors.textSecondary),
          SizedBox(width: 5.w),
          Flexible(child: Text(t.toUpperCase(), overflow: TextOverflow.ellipsis, style: _hStyle())),
        ]),
      );

  Widget _row(Map<String, dynamic> s, int i,
      List<Map<String, List<Map<String, dynamic>>>> holders) {
    final k = (s['stuadmno'] ?? '').toString();
    final emis = _emis.putIfAbsent(k, () => TextEditingController());
    final umis = isSchool ? null : _umis.putIfAbsent(k, () => TextEditingController());
    // Other students the grid shows with the same number.
    List<Map<String, dynamic>> clash(int col, TextEditingController c) {
      final v = c.text.trim();
      if (v.isEmpty) return const [];
      return (holders[col][v] ?? const <Map<String, dynamic>>[])
          .where((o) => !identical(o, s))
          .toList();
    }

    final entered = _onScreen(s, 0) != _stored(s, 0) || (!isSchool && _onScreen(s, 1) != _stored(s, 1));
    return Container(
      color: entered ? AppColors.accent.withValues(alpha: 0.045) : Colors.transparent,
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 5.h),
      child: Row(children: [
        SizedBox(width: 40.w, child: Text('${i + 1}', style: AppUI.cell.copyWith(color: AppColors.textLight))),
        Expanded(flex: 3, child: Align(alignment: Alignment.centerLeft, child: AppUI.admTag(k))),
        Expanded(flex: 5, child: Text((s['stuname'] ?? '').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
        if (_class == null)
          Expanded(
              flex: 3,
              child: Text((s['stuclass'] ?? '').toString(),
                  overflow: TextOverflow.ellipsis, style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
        Expanded(flex: 3, child: _numField(emis, schoolTerm('Enter EMIS no.'), clash(0, emis), invalid: emisInvalid(emis.text), maxLen: emisMaxLength)),
        if (umis != null) Expanded(flex: 3, child: _numField(umis, 'Enter UMIS no.', clash(1, umis))),
      ]),
    );
  }

  Widget _numField(TextEditingController c, String hint, List<Map<String, dynamic>> clash, {bool invalid = false, int maxLen = 30}) {
    final bad = clash.isNotEmpty || invalid;
    final has = c.text.trim().isNotEmpty;
    final red = OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        borderSide: const BorderSide(color: AppColors.error, width: 1.4));
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4.w),
      child: TextField(
        controller: c,
        style: AppUI.fieldText(context, filled: has).copyWith(color: bad ? AppColors.error : null),
        decoration: AppUI.field(context, hint, filled: has && !bad, dense: true).copyWith(
          enabledBorder: bad ? red : null,
          focusedBorder: bad ? red : null,
          fillColor: bad ? AppColors.errorBg : null,
          suffixIcon: bad
              ? Tooltip(
                  message: clash.isEmpty ? kEmisRuleMsg : 'Also on ${_list(clash.map(_who).toList())}',
                  child: Icon(Icons.error_outline_rounded, size: 17.sp, color: AppColors.error),
                )
              : null,
          suffixIconConstraints: BoxConstraints(minWidth: 30.w, minHeight: 18.h),
        ),
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(maxLen),
        ],
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _chip(String text, Color color, {String? icon}) {
    // The kit chip's look (tint + coloured label), keeping the glyph.
    final (fg, bg) = color == AppColors.success
        ? (AppColors.success, AppColors.successBg)
        : color == AppColors.warning
            ? (AppColors.warning, AppColors.warningBg)
            : color == AppColors.error
                ? (AppColors.error, AppColors.errorBg)
                : (AppColors.textSecondary, AppColors.tableHeadBg);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          AppIcon.linear(icon, size: 13, color: fg),
          SizedBox(width: 6.w),
        ],
        Text(text, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: fg)),
      ]),
    );
  }

  Widget _courseDrop() => DropdownButtonFormField<String>(
        key: ValueKey('emcourse-${_course ?? ''}'),
        initialValue: _course,
        isExpanded: true,
        style: AppUI.fieldText(context, filled: _course != null),
        decoration: AppUI.field(context, schoolTerm('All courses')),
        items: [
          DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All courses'))),
          ..._courses.map((c) => DropdownMenuItem(
              value: c['courname'].toString(),
              child: Text(c['courname'].toString(), overflow: TextOverflow.ellipsis))),
        ],
        onChanged: (v) => setState(() {
          _course = v;
          _class = null;
        }),
      );

  Widget _orderDrop() => DropdownButtonFormField<String>(
        initialValue: _order,
        isExpanded: true,
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, schoolTerm('Register No.')),
        items: [
          DropdownMenuItem(value: 'regno', child: Text(schoolTerm('Register No.'))),
          const DropdownMenuItem(value: 'name', child: Text('Name')),
        ],
        onChanged: (v) => setState(() => _order = v ?? 'regno'),
      );

  Widget _classDrop() => DropdownButtonFormField<String>(
        key: ValueKey('emclass-${_class ?? ''}-${_course ?? ''}'),
        initialValue: _class,
        isExpanded: true,
        style: AppUI.fieldText(context, filled: _class != null),
        decoration: AppUI.field(context, schoolTerm('All classes')),
        items: [
          DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All classes'))),
          ..._classOptions.map((c) => DropdownMenuItem(
              value: c['claname'].toString(),
              child: Text(c['claname'].toString(), overflow: TextOverflow.ellipsis))),
        ],
        onChanged: (v) => setState(() => _class = v),
      );
}

/// One sheet row as Import read it.
class _SheetRow {
  _SheetRow(this.index, this.row, this.reg, this.name);

  /// Index into the sheet's data rows.
  final int index;

  /// Excel row number.
  final int row;
  final String reg;
  final String name;
  Map<String, dynamic>? student;

  /// EMIS, UMIS -- null where the cell is blank, which leaves the number as it is.
  final List<String?> values = [null, null];
  final List<RowIssue> issues = [];

  /// Sheet columns to shade red in Export with Errors.
  final Set<int> bad = {};

  bool get ok => issues.isEmpty;
  String get key => (student?['stuadmno'] ?? '').toString();

  void flag(int col, String category, String message) {
    issues.add(RowIssue(row, reg, name, category, message));
    if (col >= 0) bad.add(col);
  }
}

class _ImportCheck {
  _ImportCheck({
    required this.fileName,
    required this.header,
    required this.rows,
    required this.blocking,
    required this.entries,
    required this.rowsChecked,
    required this.fills,
  });

  final String fileName;
  final List<String> header;

  /// Data rows as read; rows[i] is Excel row i + 2.
  final List<List<String>> rows;

  /// Problems that stop the whole sheet (missing required columns).
  final List<String> blocking;
  final List<_SheetRow> entries;
  final int rowsChecked;

  /// Numbers the valid rows would change in the grid.
  final int fills;

  List<_SheetRow> get ready => entries.where((e) => e.ok).toList();
  int get errorRows => entries.where((e) => !e.ok).length;
  List<RowIssue> get issues => [for (final e in entries) ...e.issues];
}

/// One changed student as Save checks it.
class _SaveRow {
  _SaveRow(this.student, this.gridNo, this.values, this.changedCol);

  final Map<String, dynamic> student;

  /// The grid's # for this student (1-based).
  final int gridNo;

  /// EMIS, UMIS as they stand on screen.
  final List<String> values;

  /// Whether EMIS / UMIS differ from what is stored -- only a changed number
  /// is judged, so an old duplicate doesn't block an unrelated edit.
  final List<bool> changedCol;
  final List<RowIssue> issues = [];

  /// 0 = EMIS, 1 = UMIS.
  final Set<int> badCols = {};

  int get stuId => (student['stu_id'] as num).toInt();
  bool get ok => issues.isEmpty;

  void flag(int col, String category, String message) {
    issues.add(RowIssue(gridNo, (student['stuadmno'] ?? '').toString(),
        (student['stuname'] ?? '').toString(), category, message));
    badCols.add(col);
  }
}

class _SaveCheck {
  _SaveCheck(this.entries);

  final List<_SaveRow> entries;

  List<_SaveRow> get ready => entries.where((e) => e.ok).toList();
  int get errorRows => entries.where((e) => !e.ok).length;
  List<RowIssue> get issues => [for (final e in entries) ...e.issues];
}
