import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
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
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/form_section_panel.dart';
import '../../widgets/validation_dialog.dart';

/// New Roll Number (Admission → New Roll Number).
/// Pick a class, type each student's new register number, Save. The
/// save_rollno_change RPC replaces stuadmno on the student and cascades the new
/// number to every table keyed by it (fee demands, receipts, concessions,
/// refunds, TC, parent link) plus public.admission.admno — atomically — and logs
/// the change. A student cannot be renumbered twice on the same effect date.
class NewRollNoScreen extends StatefulWidget {
  const NewRollNoScreen({super.key});

  @override
  State<NewRollNoScreen> createState() => _NewRollNoScreenState();
}

class _NewRollNoScreenState extends State<NewRollNoScreen> {
  int get _insId => context.read<AuthProvider>().insId ?? 1;

  bool _loading = true;
  bool _saving = false;
  List<Map<String, dynamic>> _students = [];
  List<Map<String, dynamic>> _classes = [];
  List<Map<String, dynamic>> _courses = [];

  String? _course;
  String? _class;
  DateTime _effectDate = DateTime.now();

  /// New reg-no input per student (keyed by the CURRENT stuadmno).
  final Map<String, TextEditingController> _newNo = {};

  /// Every roll number already in use → the student holding it. Used to reject
  /// a duplicate as it is typed, before the RPC ever sees it.
  final Map<String, String> _existingNos = {};

  /// Narrows the listed class by admission no / name. Filtering is display-only —
  /// entered numbers live in _newNo and are still saved when hidden.
  /// Grid order within a class: 'regno' (default) or 'name'.
  String _order = 'regno';

  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _newNo.values) {
      c.dispose();
    }
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final insId = _insId;
      // All five at once. None depends on another, and awaiting them in turn
      // made opening this screen cost the SUM of the round trips -- with two
      // full students scans paging 1000 rows at a time, that was most of the
      // wait.
      //
      // fetchAll, not a plain select: PostgREST caps a response at 1000 rows and
      // silently truncates, which would drop whole classes from the list.
      //
      // takenStu / takenAdm are every number the UNIQUE indexes would reject --
      // mirrors save_rollno_change: students of ANY status (a TC'd student still
      // holds their number) plus admissions not yet allocated. Truncation here
      // would let a duplicate through the client check, so those paginate too.
      final res = await Future.wait<dynamic>([
        SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('students')
            .select('stu_id, stuadmno, stuname, stuclass, cla_id')
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
        SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('students')
            .select('stuadmno, stuname')
            .eq('ins_id', insId)),
        SupabaseService.fetchAll(() => SupabaseService.client
            .from('admission')
            .select('admno, stuname')
            .eq('ins_id', insId)),
      ]);
      final students = List<Map<String, dynamic>>.from(res[0] as List);
      final classes = res[1];
      final courses = res[2];
      final takenStu = List<Map<String, dynamic>>.from(res[3] as List);
      final takenAdm = List<Map<String, dynamic>>.from(res[4] as List);
      if (!mounted) return;
      setState(() {
        _students = students.map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) => (a['stuadmno'] ?? '').toString().compareTo((b['stuadmno'] ?? '').toString()));
        _classes = (classes as List).map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) => classCompare(
              (a['claname'] ?? '').toString(), (b['claname'] ?? '').toString()));
        _courses = (courses as List).map((e) => Map<String, dynamic>.from(e)).toList()
          ..sort((a, b) => (a['courname'] ?? '').toString().compareTo((b['courname'] ?? '').toString()));
        _existingNos.clear();
        for (final e in takenAdm) {
          if (e['admno'] == null) continue;
          _existingNos[e['admno'].toString()] = (e['stuname'] ?? '').toString();
        }
        // students win the label where both hold the number (same person)
        for (final e in takenStu) {
          if (e['stuadmno'] == null) continue;
          _existingNos[e['stuadmno'].toString()] = (e['stuname'] ?? '').toString();
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not load the students. ${friendlyError(e)}', AppColors.error);
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  List<Map<String, dynamic>> get _classOptions {
    if (_course == null) return _classes;
    final cour = _courses.firstWhere((c) => c['courname'].toString() == _course, orElse: () => const {});
    final id = cour['cour_id'];
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

  /// Students to renumber. A null [_class] means "All classes" — every student
  /// of the selected course (or of the whole institution when no course is
  /// picked), ordered by class so the grid still reads class by class.
  List<Map<String, dynamic>> get _rows {
    if (_class != null) {
      return _students.where((s) => (s['stuclass'] ?? '') == _class).toList()
        ..sort(_cmpChosen);
    }
    final allowed = _classOptions.map((e) => e['claname'].toString()).toSet();
    final rows = _course == null
        ? List<Map<String, dynamic>>.from(_students)
        : _students.where((s) => allowed.contains((s['stuclass'] ?? '').toString())).toList();
    rows.sort((a, b) {
      final c = (a['stuclass'] ?? '')
          .toString()
          .compareTo((b['stuclass'] ?? '').toString());
      return c != 0 ? c : _cmpChosen(a, b);
    });
    return rows;
  }

  /// What the table shows — _rows narrowed by the search box.
  List<Map<String, dynamic>> get _visibleRows {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows
        .where((s) => '${s['stuadmno']} ${s['stuname']}'.toLowerCase().contains(q))
        .toList();
  }

  void _selectClass(String? c) {
    setState(() {
      _class = c;
      _search.clear(); // a filter carried over from the last class hides everything
      for (final ctl in _newNo.values) {
        ctl.dispose();
      }
      // Controllers are created on demand by the row builder (putIfAbsent) —
      // eagerly allocating one per student would mean thousands under
      // "All classes" for no gain.
      _newNo.clear();
    });
  }

  bool _busyIo = false;

  /// Export the filtered students to a sheet with a blank New Reg No column.
  /// Typing 1,080 numbers into the grid isn't realistic, so the sheet is the
  /// working copy: fill the last column, then import it back.
  Future<void> _exportForNumbering() async {
    final rows = _rows;
    if (rows.isEmpty) {
      _snack('Nothing to export for this filter.', AppColors.warning);
      return;
    }
    setState(() => _busyIo = true);
    try {
      final excel = xl.Excel.createExcel();
      final sheet = excel[schoolTerm('New Roll Numbers')];
      excel.delete('Sheet1');

      const headers = ['Old Reg No', 'Student Name', 'Class', 'New Reg No'];
      for (var c = 0; c < headers.length; c++) {
        sheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
            .value = xl.TextCellValue(schoolTerm(headers[c]));
      }
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final row = i + 1;
        // Old Reg No is TEXT on purpose: these are digit strings and Excel
        // would otherwise turn them into numbers and drop any leading zero,
        // which then fails to match on import.
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row)).value =
            xl.TextCellValue(r['stuadmno']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row)).value =
            xl.TextCellValue(r['stuname']?.toString() ?? '');
        sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row)).value =
            xl.TextCellValue(r['stuclass']?.toString() ?? '');
        // New Reg No deliberately left blank — that's the column to fill in.
      }
      sheet.setColumnWidth(0, 20);
      sheet.setColumnWidth(1, 30);
      sheet.setColumnWidth(2, 18);
      sheet.setColumnWidth(3, 20);

      final bytes = excel.encode();
      if (bytes == null) return;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: schoolTerm('Export students for new roll numbers'),
        fileName: 'New_Roll_Numbers_${_class ?? _course ?? 'All'}.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      await File(path).writeAsBytes(bytes);
      if (mounted) _snack('Exported ${rows.length} students to $path', AppColors.success);
    } catch (e) {
      if (mounted) _snack('Could not export the sheet. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _busyIo = false);
    }
  }

  /// Longest register number every table the change cascades into can hold:
  /// parentdetail.stuadmno is varchar(20) (the others are 25), and one value
  /// that doesn't fit fails the whole save.
  static const _maxRegNoLength = 20;

  /// A cell as typed, or as Excel hands back a numeric one ("2627100.0").
  /// Leading zeros are kept: "09" and "9" are different register numbers.
  static String _cell(String v) =>
      v.trim().replaceFirstMapped(RegExp(r'^(\d+)\.0+$'), (m) => m[1]!);

  /// A long digit string Excel has turned into scientific notation ("2.62731E+11").
  static final _scientific = RegExp(r'^\d+(\.\d+)?[eE][+-]?\d+$');

  /// Letters and digits only, upper case: for names and classes, where spacing,
  /// dots and case differ between the sheet and the record.
  static String _alnum(Object? v) =>
      (v?.toString() ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static String _list(List<String> items) => items.length <= 3
      ? items.join(', ')
      : '${items.take(3).join(', ')} and ${items.length - 3} more';

  /// What is wrong with a new number on its own, before comparing it with
  /// anyone else's; null when nothing is.
  static String? _formatProblem(String v) {
    if (_scientific.hasMatch(v)) {
      return schoolTerm('New Reg No "$v" was turned into a number by Excel (format the column as Text and type it again)');
    }
    if (v.length > _maxRegNoLength) {
      return schoolTerm('New Reg No "$v" is longer than $_maxRegNoLength characters');
    }
    return null;
  }

  /// The new number typed on screen for [s] (blank when none).
  String _typedNew(Map<String, dynamic> s) =>
      _newNo[(s['stuadmno'] ?? '').toString()]?.text.trim() ?? '';

  /// Import: read → check → show what the check found → fill the grid with the
  /// valid rows only if the admin chooses to. Nothing is written to the
  /// database here; Save does that, and checks again.
  Future<void> _importNumbering() async {
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (picked == null || picked.files.single.path == null) return;
    final file = picked.files.single;
    setState(() => _busyIo = true);
    _RollImportCheck? check;
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

  _RollImportCheck _checkSheet(
      String fileName, List<String> header, List<List<String>> rows) {
    // ---- columns, found by header name so extra columns or another order
    // still import. New Reg No is matched first so it is never taken for the
    // old number.
    var oldCol = -1, nameCol = -1, classCol = -1, newCol = -1;
    for (var c = 0; c < header.length; c++) {
      final key = _alnum(collegeTerm(header[c]));
      if (key.isEmpty) continue;
      if (newCol < 0 &&
          const {'NEWREGNO', 'NEWREG', 'NEWROLLNO', 'NEWREGISTERNO', 'NEWADMNO', 'NEWADMISSIONNO'}.contains(key)) {
        newCol = c;
      } else if (oldCol < 0 &&
          const {'OLDREGNO', 'OLDREG', 'OLDROLLNO', 'REGNO', 'ADMNO', 'ADMISSIONNO', 'OLDADMNO', 'OLDADMISSIONNO'}.contains(key)) {
        oldCol = c;
      } else if (nameCol < 0 && const {'STUDENTNAME', 'NAME', 'STUNAME'}.contains(key)) {
        nameCol = c;
      } else if (classCol < 0 && const {'CLASS', 'STUCLASS'}.contains(key)) {
        classCol = c;
      }
    }
    final blocking = [
      if (oldCol < 0) schoolTerm('The sheet has no "Old Reg No" column. Use Export to get a sheet with the right columns.'),
      if (nameCol < 0) 'There is no "Student Name" column.',
      if (newCol < 0) schoolTerm('The sheet has no "New Reg No" column. Use Export to get a sheet with the right columns.'),
    ];
    if (blocking.isNotEmpty) {
      return _RollImportCheck(
          fileName: fileName, header: header, rows: rows, blocking: blocking,
          entries: const [], rowsChecked: 0, fills: 0);
    }

    final byOld = <String, Map<String, dynamic>>{
      for (final s in _students) (s['stuadmno'] ?? '').toString().trim(): s,
    };
    final inScope = {for (final s in _rows) (s['stuadmno'] ?? '').toString()};
    final firstRowOf = <String, int>{};
    final entries = <_RollRow>[];
    var rowsChecked = 0;

    // ---- each row on its own
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.every((v) => v.trim().isEmpty)) continue; // an empty line
      rowsChecked++;
      String at(int c) => (c >= 0 && c < row.length) ? _cell(row[c]) : '';
      final e = _RollRow(i, i + 2, at(oldCol), at(nameCol));

      if (e.oldNo.isEmpty) {
        e.flag(oldCol, schoolTerm('Old Register No. blank'), schoolTerm('Old Register No. is blank'));
      } else {
        final stu = byOld[e.oldNo];
        if (stu == null) {
          e.flag(oldCol, schoolTerm('Old Register No. not found'), schoolTerm('Old Register No. ${e.oldNo} does not belong to an active student'));
        } else {
          e.student = stu;
          final dup = firstRowOf[e.oldNo];
          if (dup != null) {
            e.flag(oldCol, schoolTerm('Old Register No. repeated'), schoolTerm('Old Register No. ${e.oldNo} is already in row $dup'));
          } else {
            firstRowOf[e.oldNo] = e.row;
          }
          // The name must be this student's -- catches a number typed on the
          // wrong row. Spacing, dots and case are ignored.
          final stuName = (stu['stuname'] ?? '').toString().trim();
          if (e.name.isNotEmpty && _alnum(e.name) != _alnum(stuName)) {
            e.flag(nameCol, 'Name mismatch',
                schoolTerm('Name "${e.name}" does not match Old Register No. ${e.oldNo} (on record: ${stuName.isEmpty ? 'no name' : stuName})'));
            if (oldCol >= 0) e.bad.add(oldCol);
          }
          final stuClass = (stu['stuclass'] ?? '').toString().trim();
          final fileClass = at(classCol);
          if (fileClass.isNotEmpty && _alnum(fileClass) != _alnum(stuClass)) {
            e.flag(classCol, schoolTerm('Class mismatch'), schoolTerm('Sheet says $fileClass, but the student is in $stuClass'));
          } else if (!inScope.contains(e.oldNo)) {
            // The grid only holds the chosen course / class, and Save only
            // sends what the grid holds.
            e.flag(oldCol, 'Outside filter',
                schoolTerm('The student is in $stuClass, outside the course / class chosen on screen'));
          }
        }
      }
      if (e.name.isEmpty) e.flag(nameCol, 'Name blank', 'Name is blank');

      // Blank, or the same as the old number, means no change for this row.
      final v = at(newCol);
      if (v.isNotEmpty && v != e.oldNo) {
        final problem = _formatProblem(v);
        if (problem != null) {
          e.flag(newCol, schoolTerm('Invalid New Register No.'), problem);
        } else {
          e.newNo = v;
          // Taken by anyone: a student of any status, or an admission record.
          // That includes a number another row gives up in this same save --
          // save_rollno_change applies rows one at a time and would refuse it.
          final holder = _existingNos[v];
          if (holder != null) {
            e.flag(newCol, schoolTerm('Register No. in use'),
                schoolTerm('New Register No. $v is already used${holder.isEmpty ? '' : ' by $holder'}'));
          }
        }
      }
      entries.add(e);
    }

    // ---- one student per new number, judged on the grid as it would be after
    // the fill: the valid rows' numbers, everyone else's as typed on screen.
    // Rows that fail drop out and the check runs again.
    var again = true;
    while (again) {
      again = false;
      final incoming = <String, _RollRow>{
        for (final e in entries)
          if (e.ok && e.newNo != null) e.oldNo: e,
      };
      final takers = <String, List<Map<String, dynamic>>>{};
      for (final s in _rows) {
        final k = (s['stuadmno'] ?? '').toString();
        final v = incoming[k]?.newNo ?? _typedNew(s);
        if (v.isEmpty || v == k) continue;
        (takers[v] ??= []).add(s);
      }
      for (final e in incoming.values) {
        final others = (takers[e.newNo!] ?? const <Map<String, dynamic>>[])
            .where((s) => (s['stuadmno'] ?? '').toString() != e.oldNo)
            .toList();
        if (others.isEmpty) continue;
        final where = [
          for (final s in others)
            incoming[(s['stuadmno'] ?? '').toString()] != null
                ? 'row ${incoming[(s['stuadmno'] ?? '').toString()]!.row}'
                : schoolTerm('Old Reg No ${s['stuadmno']} · ${s['stuname'] ?? ''} (typed on screen)'),
        ];
        e.flag(newCol, schoolTerm('New Register No. repeated'),
            schoolTerm('New Register No. ${e.newNo} is also given to ${_list(where)}'));
        again = true;
      }
    }

    var fills = 0;
    for (final e in entries) {
      if (e.ok && e.newNo != null && _typedNew(e.student!) != e.newNo) fills++;
    }
    return _RollImportCheck(
        fileName: fileName, header: header, rows: rows, blocking: const [],
        entries: entries, rowsChecked: rowsChecked, fills: fills);
  }

  Future<bool> _showImportValidation(_RollImportCheck c) {
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
              'Errors, or fill in the ${c.fills} new number${s(c.fills)} from the valid rows now and import '
              'the corrected rows later.'
          : '$err row${err == 1 ? ' has' : 's have'} problems. Fix them with Export with Errors and import '
              'the sheet again.';
    } else if (c.rowsChecked == 0) {
      headline = 'The sheet has no student rows.';
    } else if (canFill) {
      headline = 'All $ready row${ready == 1 ? ' is' : 's are'} valid. ${c.fills} new number${s(c.fills)} will '
          'be filled in on screen — review, then Save.';
    } else {
      headline = 'All rows are valid, but there is no new number to fill in.';
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
          ? (err > 0
              ? 'Fill ${c.fills} valid, skip $err row${s(err)}'
              : 'Fill ${c.fills} number${s(c.fills)}')
          : null,
      actionIcon: Icons.edit_note_rounded,
    );
  }

  void _applyImport(_RollImportCheck c) {
    var fills = 0;
    for (final e in c.ready) {
      final v = e.newNo;
      if (v == null) continue;
      final ctl = _newNo.putIfAbsent(e.oldNo, () => TextEditingController());
      if (ctl.text.trim() != v) {
        ctl.text = v;
        fills++;
      }
    }
    setState(() {});
    _snack('$fills new number${fills == 1 ? '' : 's'} filled in. Review, then Save.', AppColors.success);
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
          sheetName: schoolTerm('New Roll Numbers'),
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

  /// Every number save_rollno_change would refuse → who holds it: students of
  /// ANY status (a TC'd student keeps their number) plus admission records.
  Future<Map<String, String>> _fetchTaken() async {
    final insId = _insId;
    final takenStu = await SupabaseService.fetchAll(() => SupabaseService
        .fromSchema('students')
        .select('stuadmno, stuname')
        .eq('ins_id', insId));
    final takenAdm = await SupabaseService.fetchAll(() => SupabaseService.client
        .from('admission')
        .select('admno, stuname')
        .eq('ins_id', insId));
    final out = <String, String>{};
    for (final e in takenAdm) {
      if (e['admno'] == null) continue;
      out[e['admno'].toString()] = (e['stuname'] ?? '').toString();
    }
    // students win the label where both hold the number (same person)
    for (final e in takenStu) {
      if (e['stuadmno'] == null) continue;
      out[e['stuadmno'].toString()] = (e['stuname'] ?? '').toString();
    }
    return out;
  }

  Future<void> _save() async {
    final rows = _rows;
    final pending = <Map<String, dynamic>>[
      for (final s in rows)
        if (_typedNew(s).isNotEmpty && _typedNew(s) != (s['stuadmno'] ?? '').toString()) s,
    ];
    if (pending.isEmpty) {
      _snack(schoolTerm('Enter at least one new register number.'), AppColors.warning);
      return;
    }

    setState(() => _saving = true);
    List<_RollSaveRow>? checked;
    try {
      checked = await _checkSave(rows, pending);
    } catch (e) {
      _snack('Could not check the new numbers. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (checked == null || !mounted) return;

    var ready = checked;
    if (checked.any((e) => !e.ok)) {
      if (!await _showSaveValidation(checked, rows) || !mounted) return;
      ready = [for (final e in checked) if (e.ok) e];
    }
    final entries = [
      for (final e in ready) {'oldrollno': e.oldNo, 'newrollno': e.newNo},
    ];
    // Skipped rows keep what was typed, so they can be fixed after the save.
    final keep = <String, String>{
      for (final e in checked) if (!e.ok) e.oldNo: e.newNo,
    };

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(schoolTerm('Update Register Numbers')),
        content: Text(
            'Renumber ${entries.length} ${entries.length == 1 ? 'student' : 'students'} effective from ${_fmt(_effectDate)}?\n\n'
            'The new number replaces the old one everywhere — fee demands, receipts, '
            'concessions, refunds and the admission record all move with it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final n = await SupabaseService.saveRollNoChange(
        effectDate: _effectDate,
        rows: entries,
        createdBy: context.read<AuthProvider>().userName,
      );
      await _load();
      _selectClass(_class);
      if (keep.isNotEmpty && mounted) {
        setState(() {
          keep.forEach((k, v) => _newNo.putIfAbsent(k, () => TextEditingController()).text = v);
        });
      }
      _snack(
          keep.isEmpty
              ? schoolTerm('$n register ${n == 1 ? 'number' : 'numbers'} updated.')
              : schoolTerm('$n register ${n == 1 ? 'number' : 'numbers'} updated. ${keep.length} still need fixing.'),
          keep.isEmpty ? AppColors.success : AppColors.warning);
    } catch (e) {
      _snack('Could not update the numbers. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Each new number must be free and entered for one student only. What is
  /// taken is read fresh from the database -- someone may have renumbered a
  /// student or added an admission since this screen loaded -- and the grid's
  /// own duplicate marks are refreshed with it.
  Future<List<_RollSaveRow>> _checkSave(
      List<Map<String, dynamic>> rows, List<Map<String, dynamic>> pending) async {
    final taken = await _fetchTaken();
    if (mounted) {
      setState(() {
        _existingNos
          ..clear()
          ..addAll(taken);
      });
    }
    final gridNo = <String, int>{
      for (var i = 0; i < rows.length; i++) (rows[i]['stuadmno'] ?? '').toString(): i + 1,
    };
    final entries = [
      for (final s in pending)
        _RollSaveRow(s, gridNo[(s['stuadmno'] ?? '').toString()] ?? 0, _typedNew(s)),
    ];
    final byNew = <String, List<_RollSaveRow>>{};
    for (final e in entries) {
      (byNew[e.newNo] ??= []).add(e);
    }
    for (final e in entries) {
      final problem = _formatProblem(e.newNo);
      if (problem != null) {
        e.flag(schoolTerm('Invalid New Register No.'), problem);
        continue;
      }
      final holder = taken[e.newNo];
      if (holder != null) {
        e.flag(schoolTerm('Register No. in use'),
            schoolTerm('New Register No. ${e.newNo} is already used${holder.isEmpty ? '' : ' by $holder'}'));
      }
      final others = byNew[e.newNo]!.where((o) => !identical(o, e)).toList();
      if (others.isNotEmpty) {
        e.flag(schoolTerm('New Register No. repeated'),
            schoolTerm('New Register No. ${e.newNo} is also entered for ${_list([for (final o in others) 'Old Register No. ${o.oldNo} · ${o.name}'])}'));
      }
    }
    return entries;
  }

  Future<bool> _showSaveValidation(List<_RollSaveRow> checked, List<Map<String, dynamic>> rows) {
    final ready = checked.where((e) => e.ok).length;
    final err = checked.length - ready;
    String s(int n) => n == 1 ? '' : 's';

    final messages = <int, List<String>>{};
    final badCells = <int, Set<int>>{};
    for (final e in checked.where((e) => !e.ok && e.gridNo > 0)) {
      messages[e.gridNo - 1] = [for (final x in e.issues) x.message];
      badCells[e.gridNo - 1] = {3}; // the New Reg No column
    }

    return showValidationDialog(
      context,
      subtitle: schoolTerm('Save · ${_class ?? _course ?? 'All classes'} · effective ${_fmt(_effectDate)}'),
      rowLabel: '#',
      stats: [
        ('Students to renumber', checked.length, AppColors.textSecondary),
        ('Ready to save', ready, AppColors.success),
        ('With errors', err, AppColors.error),
      ],
      headline: ready > 0
          ? '$err student${err == 1 ? ' has' : 's have'} a new number that can\'t be used, and will be '
              'skipped. Fix them on screen, or save the $ready valid student${s(ready)} now.'
          : 'None of the new numbers can be used yet. Fix them on screen, then Save again.',
      issues: [for (final e in checked) ...e.issues],
      onExport: () => _exportWithErrors(
        fileName: 'New_Roll_Numbers_${_class ?? _course ?? 'All'}.xlsx',
        header: [for (final h in const ['Old Reg No', 'Student Name', 'Class', 'New Reg No']) schoolTerm(h)],
        rows: [
          for (final r in rows)
            [
              (r['stuadmno'] ?? '').toString(),
              (r['stuname'] ?? '').toString(),
              (r['stuclass'] ?? '').toString(),
              _typedNew(r),
            ],
        ],
        badCells: badCells,
        messages: messages,
      ),
      actionLabel: ready > 0 ? 'Save $ready valid, skip $err' : null,
      actionIcon: Icons.save,
    );
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  /// Per-row uniqueness errors, keyed by the row's CURRENT roll number.
  /// A new number is rejected when it already belongs to another student, or
  /// when it has been typed on more than one row here.
  Map<String, String> _computeErrors(List<Map<String, dynamic>> rows) {
    final errs = <String, String>{};
    final typedCount = <String, int>{};
    for (final s in rows) {
      final oldNo = s['stuadmno'].toString();
      final v = _newNo[oldNo]?.text.trim() ?? '';
      if (v.isEmpty || v == oldNo) continue;
      typedCount[v] = (typedCount[v] ?? 0) + 1;
    }
    for (final s in rows) {
      final oldNo = s['stuadmno'].toString();
      final v = _newNo[oldNo]?.text.trim() ?? '';
      if (v.isEmpty || v == oldNo) continue;
      // v != oldNo here, so any hit belongs to a DIFFERENT student.
      final owner = _existingNos[v];
      if (owner != null) {
        errs[oldNo] = 'In use by ${owner.isEmpty ? 'another student' : owner}';
      } else if ((typedCount[v] ?? 0) > 1) {
        errs[oldNo] = 'Entered on more than one row';
      }
    }
    return errs;
  }

  /// How many rows carry a new number that actually differs from the old one.
  int get _filledCount {
    var n = 0;
    for (final s in _rows) {
      final oldNo = s['stuadmno'].toString();
      final v = _newNo[oldNo]?.text.trim() ?? '';
      if (v.isNotEmpty && v != oldNo) n++;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final rows = _rows;
    final visible = _visibleRows;
    final filled = _filledCount;
    // Errors cover the WHOLE class, not just what the search shows, so a
    // duplicate scrolled out of view still blocks Save.
    final errors = _computeErrors(rows);
    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title, in its own card so the page reads as three stacked
          // panels (title / filters / table) rather than a bare heading.
          Container(
            padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, 12.w, 16.h),
            decoration: AppUI.card(),
            child: AppUI.cardHeader(
              icon: 'tag',
              title: schoolTerm('New Register Number'),
              subtitle: schoolTerm('Assign new register numbers class by class'),
              trailing: [
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _saving ? null : _load,
                  icon: Icon(Icons.refresh, size: 20.sp, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          SizedBox(height: AppUI.gap),

          // ── Toolbar card
          Container(
            padding: EdgeInsets.all(AppUI.cardPad),
            decoration: AppUI.card(),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(flex: 3, child: _labeled('Effective Date', InkWell(
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _effectDate,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) setState(() => _effectDate = d);
                },
                child: InputDecorator(
                  decoration: _dec('Select effective date').copyWith(
                    suffixIcon: Icon(Icons.calendar_today_outlined, size: 15.sp, color: AppColors.textSecondary),
                  ),
                  child: Text(_fmt(_effectDate), style: AppUI.fieldText(context)),
                ),
              ), icon: 'calendar')),
              SizedBox(width: 12.w),
              Expanded(flex: 4, child: _labeled(schoolTerm('Course'), DropdownButtonFormField<String>(
                key: ValueKey('rncourse-${_course ?? ''}'),
                initialValue: _course,
                isExpanded: true,
                style: AppUI.fieldText(context, filled: _course != null),
                decoration: _dec(schoolTerm('All courses')),
                items: [
                  DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All courses'))),
                  ..._courses.map((e) => DropdownMenuItem(
                      value: e['courname'].toString(),
                      child: Text(e['courname'].toString(), overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (v) { _course = v; _selectClass(null); },
              ), icon: 'teacher')),
              SizedBox(width: 12.w),
              Expanded(flex: 4, child: _labeled(schoolTerm('Class'), DropdownButtonFormField<String>(
                key: ValueKey('rnclass-${_class ?? ''}-${_course ?? ''}'),
                initialValue: _class,
                isExpanded: true,
                style: AppUI.fieldText(context, filled: _class != null),
                decoration: _dec(schoolTerm('All classes')),
                items: [
                  DropdownMenuItem<String>(value: null, child: Text(schoolTerm('All classes'))),
                  ..._classOptions.map((e) => DropdownMenuItem(
                      value: e['claname'].toString(),
                      child: Text(e['claname'].toString(), overflow: TextOverflow.ellipsis))),
                ],
                onChanged: _selectClass,
              ), icon: 'book')),
              SizedBox(width: 12.w),
              Expanded(flex: 3, child: _labeled('Sort By', DropdownButtonFormField<String>(
                key: ValueKey('rnord-$_order'),
                initialValue: _order,
                isExpanded: true,
                style: AppUI.fieldText(context),
                decoration: _dec(schoolTerm('Register No.')),
                items: [
                  DropdownMenuItem(value: 'regno', child: Text(schoolTerm('Register No.'))),
                  const DropdownMenuItem(value: 'name', child: Text('Name')),
                ],
                onChanged: (v) => setState(() => _order = v ?? 'regno'),
              ), icon: 'sort')),
              Expanded(flex: 4, child: _labeled(AppText.search, TextField(
                controller: _search,
                decoration: _dec(schoolTerm('Search by register no. or name')).copyWith(
                  prefixIcon: Icon(Icons.search, size: 17.sp, color: AppColors.textSecondary),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: Icon(Icons.close, size: 15.sp, color: AppColors.textSecondary),
                          onPressed: () => setState(_search.clear),
                        ),
                ),
                style: AppUI.fieldText(context),
                onChanged: (_) => setState(() {}),
              ), icon: 'hashtag')),
              SizedBox(width: 14.w),
              // Export the filtered list, fill the New Reg No column in Excel,
              // import it back. Import only fills the grid — Save still commits.
              OutlinedButton.icon(
                onPressed: _busyIo || _saving ? null : _exportForNumbering,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Export'),
              ),
              SizedBox(width: 8.w),
              OutlinedButton.icon(
                onPressed: _busyIo || _saving ? null : _importNumbering,
                icon: _busyIo
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_outlined, size: 16),
                label: const Text('Import'),
              ),
              SizedBox(width: 8.w),
              ElevatedButton.icon(
                onPressed: (_saving || _busyIo || filled == 0) ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save, size: 16),
                label: Text(filled > 0 ? 'Save ($filled)' : 'Save'),
              ),
            ]),
          ),
          // ── Counts sit under the toolbar, so a new chip never squeezes the
          // fields or pushes the buttons off the edge.
          if (rows.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 10.h),
              child: Row(children: [
                // Green for "how many are here", amber for "how many are
                // waiting on you" -- the same reading as the rest of the app,
                // where success is settled and warning is outstanding.
                _chip(
                    visible.length == rows.length
                        ? '${rows.length} student${rows.length == 1 ? '' : 's'}'
                        : '${visible.length} of ${rows.length}',
                    AppColors.success, icon: 'profile-2user'),
                SizedBox(width: 8.w),
                _chip('$filled to update',
                    filled > 0 ? AppColors.warning : AppColors.textLight,
                    icon: 'clock'),
                if (errors.isNotEmpty) ...[
                  SizedBox(width: 8.w),
                  _chip('${errors.length} duplicate${errors.length == 1 ? '' : 's'}', AppColors.error),
                ],
              ]),
            ),
          SizedBox(height: AppUI.gap),

          // The table (with its headers) is always on screen; the message for
          // "no class picked" / "no students" sits inside the body.
          Expanded(child: _table(visible, errors)),

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
              Expanded(child: Text(schoolTerm(
                'The new number replaces the old one everywhere — fee demands, receipts, concessions, '
                'refunds and the admission record move with it. A register number cannot be updated twice '
                'on the same effective date. Blank rows are skipped.'),
                style: AppUI.muted.copyWith(color: AppColors.textSecondary, height: 1.35),
              )),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color c, {String? icon}) {
    final (fg, bg) = c == AppColors.success
        ? (AppColors.success, AppColors.successBg)
        : c == AppColors.warning
            ? (AppColors.warning, AppColors.warningBg)
            : c == AppColors.error
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

  Widget _empty(String icon, String title, String hint) =>
      AppUI.empty(title: title, why: hint, icon: icon);

  Widget _table(List<Map<String, dynamic>> rows, Map<String, String> errors) {
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
            SizedBox(width: 40.w, child: Text('#', style: AppUI.tableHead)),
            _hc(schoolTerm('Old Register No.'), 3, icon: 'hashtag'),
            _hc('Student Name', 5, icon: 'profile-2user'),
            // Class only earns a column when the list spans more than one.
            if (_class == null) _hc(schoolTerm('Class'), 3, icon: 'book'),
            _hc(schoolTerm('New Register No.'), 3, icon: 'tag'),
          ]),
        ),
        Expanded(
          child: rows.isEmpty
              ? _search.text.trim().isNotEmpty
                  ? _empty('search-normal', 'No matches',
                      'No student here matches "${_search.text.trim()}".')
                  : _empty('people', 'No students',
                      _class == null
                          ? 'There are no active students to renumber.'
                          : schoolTerm('This class has no active students.'))
              : ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
            itemBuilder: (_, i) {
              final s = rows[i];
              final oldNo = s['stuadmno'].toString();
              final ctl = _newNo.putIfAbsent(oldNo, () => TextEditingController());
              final entered = ctl.text.trim().isNotEmpty && ctl.text.trim() != oldNo;
              final err = errors[oldNo];
              final tint = err != null ? AppColors.error : AppColors.accent;
              return Container(
                color: entered ? tint.withValues(alpha: 0.045) : Colors.transparent,
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 5.h),
                child: Row(children: [
                  SizedBox(width: 40.w, child: Text('${i + 1}',
                      style: AppUI.cell.copyWith(color: AppColors.textLight))),
                  Expanded(flex: 3, child: Text(oldNo,
                      overflow: TextOverflow.ellipsis,
                      style: AppUI.cell.copyWith(fontWeight: FontWeight.w600))),
                  Expanded(flex: 5, child: Text(s['stuname']?.toString() ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: AppUI.cell)),
                  if (_class == null)
                    Expanded(flex: 3, child: Text(s['stuclass']?.toString() ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
                  Expanded(flex: 3, child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4.w),
                    child: TextField(
                      controller: ctl,
                      inputFormatters: [LengthLimitingTextInputFormatter(_maxRegNoLength)],
                      style: AppUI.fieldText(context, filled: entered).copyWith(color: entered ? tint : null),
                      onChanged: (_) => setState(() {}),
                      // errorText swaps in the kit's red error edge.
                      decoration: AppUI.field(context, schoolTerm('Enter new register no.'),
                              filled: entered && err == null, dense: true)
                          .copyWith(
                        errorText: err,
                        errorStyle: TextStyle(fontSize: 10.5.sp, color: AppColors.error),
                      ),
                    ),
                  )),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }

  /// A column heading. The optional glyph names the column at a glance, the
  /// same way the filter labels above the table do.
  Widget _hc(String t, int flex, {String? icon}) => Expanded(
        flex: flex,
        child: Row(children: [
          if (icon != null) ...[
            AppIcon.linear(icon, size: 13, color: AppColors.textSecondary),
            SizedBox(width: 5.w),
          ],
          Flexible(
            child: Text(t.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: AppUI.tableHead),
          ),
        ]),
      );

  /// A filter's label above its input. [icon] names the field at a glance --
  /// the same small accent glyph the rest of the admission forms use, via the
  /// shared [FormFieldLabel] rather than a private copy of it.
  Widget _labeled(String label, Widget field, {String? icon}) =>
      FormFieldLabel(label: label, icon: icon, child: field);

  InputDecoration _dec(String hint) => AppUI.field(context, hint);
}

/// One sheet row as Import read it.
class _RollRow {
  _RollRow(this.index, this.row, this.oldNo, this.name);

  /// Index into the sheet's data rows.
  final int index;

  /// Excel row number.
  final int row;
  final String oldNo;
  final String name;
  Map<String, dynamic>? student;

  /// The new number, when the row gives one that differs from the old.
  String? newNo;
  final List<RowIssue> issues = [];

  /// Sheet columns to shade red in Export with Errors.
  final Set<int> bad = {};

  bool get ok => issues.isEmpty;

  void flag(int col, String category, String message) {
    issues.add(RowIssue(row, oldNo, name, category, message));
    if (col >= 0) bad.add(col);
  }
}

class _RollImportCheck {
  _RollImportCheck({
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
  final List<_RollRow> entries;
  final int rowsChecked;

  /// New numbers the valid rows would change in the grid.
  final int fills;

  List<_RollRow> get ready => entries.where((e) => e.ok).toList();
  int get errorRows => entries.where((e) => !e.ok).length;
  List<RowIssue> get issues => [for (final e in entries) ...e.issues];
}

/// One student Save is about to renumber.
class _RollSaveRow {
  _RollSaveRow(this.student, this.gridNo, this.newNo);

  final Map<String, dynamic> student;

  /// The grid's # for this student (1-based).
  final int gridNo;
  final String newNo;
  final List<RowIssue> issues = [];

  String get oldNo => (student['stuadmno'] ?? '').toString();
  String get name => (student['stuname'] ?? '').toString();
  bool get ok => issues.isEmpty;

  void flag(String category, String message) =>
      issues.add(RowIssue(gridNo, oldNo, name, category, message));
}
