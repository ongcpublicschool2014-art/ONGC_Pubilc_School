import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/class_sort.dart';
import '../../utils/friendly_error.dart';
import '../../utils/report_pdf_export.dart';
import '../../utils/school_terms.dart';
import '../../services/supabase_service.dart';
import '../../services/admission_service.dart';
import '../../models/admission_model.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_search_field.dart';

/// Class (school: Section) Allocation -- places admissions saved without a
/// class and moves them into the year's students/parents/parentdetail tables.
///
/// Rows are admissions. Picking a section ticks the row; Save Allocation
/// allocates every ticked row. Auto Fill spreads the unplaced pending rows
/// evenly over their standard's sections; Bulk Allocate puts the ticked rows
/// into one chosen section. Allocated rows are shown read-only (Filters).
class ClassAllocationScreen extends StatefulWidget {
  const ClassAllocationScreen({super.key});

  @override
  State<ClassAllocationScreen> createState() => _ClassAllocationScreenState();
}

enum _Status { pending, allocated, all }

class _ClassAllocationScreenState extends State<ClassAllocationScreen> {
  List<AdmissionModel> _admissions = []; // non-cancelled, current institution
  List<Map<String, dynamic>> _courseList = []; // {cour_id, courname, ordid}
  List<Map<String, dynamic>> _classList = []; // {claname, cour_id}
  Map<String, int> _strength = {}; // section -> students on the rolls

  String? _selectedCourse; // null = all standards
  String _orderBy = 'Admission No';
  _Status _status = _Status.pending;
  String? _gender; // null = all, else M / F / T
  final _search = TextEditingController();

  final Map<int, String?> _rowClass = {}; // adm_id -> chosen section
  final Set<int> _ticked = {}; // adm_id ticked for allocation
  bool _loading = true;
  bool _saving = false;
  bool _exporting = false;

  String _insName = '', _insAddress = '', _insCity = '';

  static const _orderOptions = ['Admission No', 'Student Name', 'Gender + Student Name'];
  // How an order option reads (the option itself is compared in _sorted).
  static const _orderLabels = {'Admission No': 'Register No.'};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() => _loading = true);
    final insId = _insId;
    try {
      final results = await Future.wait<dynamic>([
        AdmissionService.getAdmissions(insId),
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('students').select('stuclass').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.getInstitutionInfo(insId),
      ]);
      if (!mounted) return;
      final info = results[4] as ({String? name, String? logo, String? address, String? mobile, String? email});
      final strength = <String, int>{};
      for (final s in results[3] as List) {
        final c = s['stuclass']?.toString().trim() ?? '';
        if (c.isNotEmpty) strength[c] = (strength[c] ?? 0) + 1;
      }
      setState(() {
        _admissions = (results[0] as List<AdmissionModel>).where((a) => a.isPending || a.isAllocated).toList();
        _courseList = List<Map<String, dynamic>>.from(results[1] as List)
          ..sort((a, b) {
            final oa = (a['ordid'] as num?)?.toInt() ?? 9999;
            final ob = (b['ordid'] as num?)?.toInt() ?? 9999;
            return oa != ob ? oa.compareTo(ob) : '${a['courname']}'.compareTo('${b['courname']}');
          });
        _classList = List<Map<String, dynamic>>.from(results[2] as List);
        _strength = strength;
        _insName = info.name ?? '';
        final parts = (info.address ?? '').replaceAll('\n', ', ').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        _insCity = parts.length > 1 ? parts.removeLast() : '';
        _insAddress = parts.join(', ');
        // Pre-fill (and tick) the section chosen at admission; still editable.
        for (final a in _admissions.where((a) => a.isPending)) {
          final c = a.stuclass?.trim() ?? '';
          if (c.isNotEmpty && !_rowClass.containsKey(a.admId) && _classNamesFor(a.courname).contains(c)) {
            _rowClass[a.admId] = c;
            _ticked.add(a.admId);
          }
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Could not load the admissions. ${friendlyError(e)}', AppColors.error);
      }
    }
  }

  // ── options ───────────────────────────────────────────────────────
  List<String> get _courseNames => _courseList
      .map((e) => e['courname']?.toString().trim() ?? '')
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();

  List<String> _classNamesFor(String? courname) {
    final cm = _courseList.firstWhere(
      (c) => (c['courname']?.toString().trim() ?? '') == (courname?.trim() ?? ''),
      orElse: () => const {},
    );
    final courId = cm['cour_id'];
    if (courId == null) return const [];
    return _classList
        .where((cl) => cl['cour_id'] == courId)
        .map((e) => e['claname']?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort(classCompare);
  }

  /// Sections of the selected standard, or of every standard.
  List<String> get _sectionsInScope => _selectedCourse != null
      ? _classNamesFor(_selectedCourse)
      : [for (final c in _courseNames) ..._classNamesFor(c)];

  String _sectionOf(AdmissionModel a) =>
      a.isAllocated ? (a.allocatedclass ?? a.stuclass ?? '') : (_rowClass[a.admId] ?? '');

  /// Admissions of the selected standard (all standards when none).
  List<AdmissionModel> get _inStandard => _selectedCourse == null
      ? _admissions
      : _admissions.where((a) => (a.courname?.trim() ?? '') == _selectedCourse).toList();

  /// What the grid shows: standard + status + gender + search, sorted.
  List<AdmissionModel> get _rows {
    final q = _search.text.trim().toLowerCase();
    final list = _inStandard.where((a) {
      if (_status == _Status.pending && !a.isPending) return false;
      if (_status == _Status.allocated && !a.isAllocated) return false;
      if (_gender != null && a.stugender != _gender) return false;
      if (q.isEmpty) return true;
      return a.admno.toLowerCase().contains(q) ||
          a.stuname.toLowerCase().contains(q) ||
          _sectionOf(a).toLowerCase().contains(q);
    }).toList();
    final courseRank = {for (var i = 0; i < _courseNames.length; i++) _courseNames[i]: i};
    list.sort((a, b) {
      if (_selectedCourse == null) {
        final c = (courseRank[a.courname?.trim()] ?? 9999).compareTo(courseRank[b.courname?.trim()] ?? 9999);
        if (c != 0) return c;
      }
      switch (_orderBy) {
        case 'Student Name':
          return a.stuname.toLowerCase().compareTo(b.stuname.toLowerCase());
        case 'Gender + Student Name':
          final s = a.stugender.compareTo(b.stugender);
          return s != 0 ? s : a.stuname.toLowerCase().compareTo(b.stuname.toLowerCase());
        default:
          return a.admno.compareTo(b.admno);
      }
    });
    return list;
  }

  int get _pendingTotal => _admissions.where((a) => a.isPending).length;
  int get _tickedCount => _admissions.where((a) => a.isPending && _ticked.contains(a.admId)).length;

  // ── actions ───────────────────────────────────────────────────────
  void _setSection(AdmissionModel a, String? v) => setState(() {
        _rowClass[a.admId] = v;
        if (v != null && v.isNotEmpty) _ticked.add(a.admId);
      });

  /// Spread the visible pending rows that have no section yet evenly over
  /// their standard's sections, smallest section (rolls + this fill) first.
  Future<void> _autoFill() async {
    final targets = _rows.where((a) => a.isPending && (_rowClass[a.admId] ?? '').isEmpty).toList();
    if (targets.isEmpty) {
      _snack(schoolTerm('Every pending student shown already has a class.'), AppColors.warning);
      return;
    }
    final ok = await _confirm(
      'Auto Fill',
      schoolTerm('Spread ${targets.length} student(s) without a class evenly across '
          '${_selectedCourse == null ? 'their course\'s' : '$_selectedCourse\'s'} classes, '
          'filling the smallest class first. Classes already chosen are kept.'),
      'Auto Fill',
    );
    if (!ok) return;
    final load = <String, int>{};
    for (final a in _admissions.where((a) => a.isPending)) {
      final c = _rowClass[a.admId] ?? '';
      if (c.isNotEmpty) load[c] = (load[c] ?? 0) + 1;
    }
    var skipped = 0;
    setState(() {
      for (final a in targets) {
        final opts = _classNamesFor(a.courname);
        if (opts.isEmpty) {
          skipped++;
          continue;
        }
        int size(String c) => (_strength[c] ?? 0) + (load[c] ?? 0);
        final pick = opts.reduce((x, y) => size(y) < size(x) ? y : x);
        load[pick] = (load[pick] ?? 0) + 1;
        _rowClass[a.admId] = pick;
        _ticked.add(a.admId);
      }
    });
    if (skipped > 0) _snack(schoolTerm('$skipped student(s) skipped: their course has no classes.'), AppColors.warning);
  }

  /// Put every ticked pending row into one chosen section.
  Future<void> _bulkAllocate() async {
    final rows = _rows.where((a) => a.isPending && _ticked.contains(a.admId)).toList();
    if (rows.isEmpty) {
      _snack('Tick the students to allocate first.', AppColors.warning);
      return;
    }
    final courses = rows.map((a) => a.courname?.trim() ?? '').toSet();
    if (courses.length > 1) {
      _snack(schoolTerm('The ticked students are in different courses. Select one course first.'), AppColors.warning);
      return;
    }
    final options = _classNamesFor(courses.first);
    if (options.isEmpty) {
      _snack(schoolTerm('No classes available for ${courses.first}.'), AppColors.warning);
      return;
    }
    String? picked = options.length == 1 ? options.first : null;
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(schoolTerm('Bulk Allocate')),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(schoolTerm('Allocate the ${rows.length} ticked ${rows.length == 1 ? 'student' : 'students'} of ${courses.first} to one class.'),
                    style: AppUI.muted),
                SizedBox(height: 14.h),
                DropdownButtonFormField<String>(
                  initialValue: picked,
                  isExpanded: true,
                  style: AppUI.fieldText(ctx, filled: picked != null),
                  decoration: AppUI.field(ctx, '', label: schoolTerm('Class')),
                  items: [
                    for (final e in options)
                      DropdownMenuItem(value: e, child: Text('$e  (${_strength[e] ?? 0} on rolls)', style: AppUI.fieldText(ctx))),
                  ],
                  onChanged: (v) => setLocal(() => picked = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (picked != null) Navigator.pop(ctx, picked);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    setState(() {
      for (final a in rows) {
        _rowClass[a.admId] = chosen;
      }
    });
  }

  Future<void> _save([List<AdmissionModel>? only]) async {
    final ticked = only ?? _admissions.where((a) => a.isPending && _ticked.contains(a.admId)).toList();
    if (ticked.isEmpty) {
      _snack(schoolTerm('Select a class for at least one student first.'), AppColors.warning);
      return;
    }
    final missing = ticked.where((a) => (_rowClass[a.admId] ?? '').isEmpty).toList();
    if (missing.isNotEmpty) {
      _snack(schoolTerm('Select a class for: ${missing.take(5).map((a) => a.admno).join(', ')}'
          '${missing.length > 5 ? ' and ${missing.length - 5} more' : ''}.'), AppColors.error);
      return;
    }
    final by = context.read<AuthProvider>().userName;
    setState(() => _saving = true);
    var done = 0;
    final failures = <String>[];
    for (final a in ticked) {
      try {
        await AdmissionService.allocateClass(
          admId: a.admId,
          className: _rowClass[a.admId]!,
          stuadmno: a.admno,
          allocatedBy: by,
        );
        done++;
        _ticked.remove(a.admId);
        _rowClass.remove(a.admId);
      } catch (e) {
        failures.add('${a.admno} ${a.stuname}: ${friendlyError(e)}');
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    await _load();
    if (!mounted) return;
    if (failures.isEmpty) {
      _snack('$done ${done == 1 ? 'student' : 'students'} allocated and added to Students.', AppColors.success);
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$done Allocated, ${failures.length} Not Allocated'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final f in failures)
                    Padding(
                      padding: EdgeInsets.only(bottom: 4.h),
                      child: Text('• $f', style: TextStyle(fontSize: 12.sp, color: AppColors.error)),
                    ),
                ],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
    }
  }

  void _showSections() {
    final secs = _sectionsInScope;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(schoolTerm(_selectedCourse == null ? 'Classes' : 'Classes of $_selectedCourse')),
        content: SizedBox(
          width: 380,
          child: secs.isEmpty
              ? Text(schoolTerm('No classes set up.'), style: AppUI.muted)
              : SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final s in secs)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 6.h),
                        child: Row(children: [
                          const AppIcon.linear('layer', size: 16, color: AppColors.demand),
                          SizedBox(width: 10.w),
                          Expanded(child: Text(s, style: AppUI.label)),
                          Text('${_strength[s] ?? 0} on rolls', style: AppUI.muted),
                          if (_admissions.any((a) => a.isPending && _rowClass[a.admId] == s)) ...[
                            SizedBox(width: 8.w),
                            Text('+${_admissions.where((a) => a.isPending && _rowClass[a.admId] == s).length} picked',
                                style: AppUI.label.copyWith(color: AppColors.warning)),
                          ],
                        ]),
                      ),
                  ]),
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  // ── export ────────────────────────────────────────────────────────
  static const _exportHeaders = [AppText.serialNo, 'Register No.', 'Student Name', 'Gender', 'Course', 'Class', 'Status'];

  List<List<String>> get _exportRows {
    final rows = _rows;
    return [
      for (var i = 0; i < rows.length; i++)
        [
          '${i + 1}',
          rows[i].admno,
          rows[i].stuname,
          rows[i].genderLabel,
          rows[i].courname ?? '',
          _sectionOf(rows[i]),
          rows[i].isAllocated ? 'Allocated' : 'Pending',
        ],
    ];
  }

  String get _fileStem => schoolTerm('Class_Allocation${_selectedCourse == null ? '' : '_${_selectedCourse!.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}'}');

  Future<void> _exportExcel() async {
    final rows = _exportRows;
    if (rows.isEmpty) {
      _snack('Nothing to export.', AppColors.warning);
      return;
    }
    final path = await FilePicker.platform.saveFile(
      dialogTitle: schoolTerm('Save Class Allocation'),
      fileName: '$_fileStem.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (path == null) return;
    setState(() => _exporting = true);
    try {
      final book = xl.Excel.createExcel();
      final sheetName = schoolTerm('Class Allocation');
      final sheet = book[sheetName];
      book.delete('Sheet1');
      final bold = xl.CellStyle(bold: true, fontSize: 11);
      final hdr = xl.CellStyle(
        bold: true,
        fontSize: 10,
        backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
        fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
      );
      void put(int col, int row, String text, [xl.CellStyle? style]) {
        final c = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
        c.value = xl.TextCellValue(text);
        if (style != null) c.cellStyle = style;
      }

      var r = 0;
      put(0, r++, _insName.toUpperCase(), bold);
      if (_insAddress.isNotEmpty) put(0, r++, _insAddress.toUpperCase(), bold);
      if (_insCity.isNotEmpty) put(0, r++, _insCity.toUpperCase(), bold);
      put(0, r++, schoolTerm('Class Allocation${_selectedCourse == null ? '' : ' - $_selectedCourse'}'), bold);
      r++;
      for (var c = 0; c < _exportHeaders.length; c++) {
        put(c, r, schoolTerm(_exportHeaders[c]), hdr);
      }
      r++;
      for (final row in rows) {
        for (var c = 0; c < row.length; c++) {
          put(c, r, row[c]);
        }
        r++;
      }
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack('Excel file saved to $path', AppColors.success);
    } catch (e) {
      _snack('Could not export the Excel file. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportPdf() async {
    final rows = _exportRows;
    if (rows.isEmpty) {
      _snack('Nothing to export.', AppColors.warning);
      return;
    }
    setState(() => _exporting = true);
    try {
      await saveReportPdf(
        context,
        fileName: _fileStem,
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: schoolTerm('Class Allocation'),
        subtitle: schoolTerm('${_selectedCourse == null ? 'All Courses' : 'Course : $_selectedCourse'}'
            '   Status : ${_status == _Status.pending ? 'Pending' : _status == _Status.allocated ? 'Allocated' : 'All'}'),
        headers: [for (final h in _exportHeaders) schoolTerm(h)],
        rows: rows,
        landscape: false,
      );
    } catch (e) {
      _snack('Could not export the PDF. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── helpers ───────────────────────────────────────────────────────
  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 400, child: Text(body, style: AppUI.body.copyWith(color: AppColors.textSecondary))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return r ?? false;
  }

  bool get _compact => MediaQuery.of(context).size.width <= 1366;

  // ── build ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppUI.card(),
      padding: EdgeInsets.fromLTRB(AppUI.cardPad, 16.h, AppUI.cardPad, 16.h),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(),
          SizedBox(height: 16.h),
          _statCards(),
          SizedBox(height: 16.h),
          _toolbar(),
          SizedBox(height: 10.h),
          Expanded(child: _table()),
          SizedBox(height: 8.h),
          _actionBar(),
        ],
      ),
    );
  }

  Widget _topBar() {
    final crumb = AppUI.muted;
    return Row(children: [
      AppUI.iconTile('book-1'),
      SizedBox(width: 12.w),
      Text(schoolTerm('Class Allocation'), style: AppUI.cardTitle),
      SizedBox(width: 14.w),
      Flexible(
        child: Text.rich(
          TextSpan(style: crumb, children: [
            const TextSpan(text: 'Admission  ›  '),
            TextSpan(text: '${schoolTerm('Class Allocation')}  ›  '),
            TextSpan(text: _status == _Status.allocated ? 'Allocated' : _status == _Status.all ? 'All' : 'Pending Allocation'),
          ]),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const Spacer(),
      SizedBox(width: 170.w, child: _courseDropdown()),
      SizedBox(width: AppBtn.gap(context)),
      SizedBox(width: 190.w, child: _orderDropdown()),
      SizedBox(width: AppBtn.gap(context)),
      ElevatedButton.icon(
        onPressed: _loading || _saving ? null : _autoFill,
        icon: Icon(Icons.auto_fix_high, size: AppBtn.iconSize(context)),
        label: const Text('Auto Fill'),
      ),
      SizedBox(width: AppBtn.gap(context)),
      AppUI.chip('$_pendingTotal Pending', AppStatus.warning),
    ]);
  }

  Widget _statCards() {
    final scope = _inStandard;
    final allocated = scope.where((a) => a.isAllocated).length;
    final pending = scope.where((a) => a.isPending).length;
    return Row(children: [
      Expanded(child: _stat('profile-2user', 'Total Students', '${scope.length}', AppColors.primary, AppColors.primaryLight)),
      SizedBox(width: AppUI.gap),
      Expanded(child: _stat('tick-circle', 'Allocated', '$allocated', AppColors.success, AppColors.successBg)),
      SizedBox(width: AppUI.gap),
      Expanded(child: _stat('clock', 'Pending', '$pending', AppColors.warning, AppColors.warningBg)),
      SizedBox(width: AppUI.gap),
      Expanded(
        child: _stat('layer', schoolTerm('Classes'), '${_sectionsInScope.length}', AppColors.demand, AppColors.surface,
            trailing: TextButton(
              onPressed: _showSections,
              child: Text(schoolTerm('View Classes')),
            )),
      ),
    ]);
  }

  Widget _stat(String icon, String label, String value, Color color, Color bg, {Widget? trailing}) {
    // [bg] is kept for callers; the tile itself is the kit's white KPI card.
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: _compact ? 10.h : 14.h),
      decoration: AppUI.card(),
      child: Row(children: [
        AppUI.iconTile(icon, color: color),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label.toUpperCase(), style: AppUI.caps, maxLines: 1, overflow: TextOverflow.ellipsis),
            SizedBox(height: 4.h),
            Text(value, style: TextStyle(fontSize: 20.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          ]),
        ),
        if (trailing != null) trailing,
      ]),
    );
  }

  Widget _toolbar() {
    final filtered = _status != _Status.pending || _gender != null;
    return Row(children: [
      Expanded(
        flex: 5,
        child: AppSearchField(
          controller: _search,
          hintText: schoolTerm('Search by register no., name or class'),
          onChanged: (_) => setState(() {}),
        ),
      ),
      const Spacer(flex: 3),
      PopupMenuButton<String>(
        tooltip: 'Filters',
        onSelected: (v) => setState(() {
          switch (v) {
            case 'sp': _status = _Status.pending;
            case 'sa': _status = _Status.allocated;
            case 'sx': _status = _Status.all;
            case 'g': _gender = null;
            case 'gM': _gender = 'M';
            case 'gF': _gender = 'F';
            case 'gT': _gender = 'T';
          }
        }),
        itemBuilder: (_) => [
          PopupMenuItem(enabled: false, height: 28, child: Text('STATUS', style: AppUI.caps)),
          _check('sp', 'Pending', _status == _Status.pending),
          _check('sa', 'Allocated', _status == _Status.allocated),
          _check('sx', 'All', _status == _Status.all),
          const PopupMenuDivider(),
          PopupMenuItem(enabled: false, height: 28, child: Text('GENDER', style: AppUI.caps)),
          _check('g', 'All', _gender == null),
          _check('gM', 'Male', _gender == 'M'),
          _check('gF', 'Female', _gender == 'F'),
          _check('gT', 'Other', _gender == 'T'),
        ],
        child: Container(
          height: AppUI.controlHeight(context),
          padding: EdgeInsets.symmetric(horizontal: 14.w),
          decoration: BoxDecoration(
            color: filtered ? AppColors.primaryLight : Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: filtered ? AppColors.primary : AppColors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AppIcon('filter', size: AppBtn.iconSize(context), color: filtered ? AppColors.primary : AppColors.textPrimary),
            SizedBox(width: 6.w),
            Text('Filters', style: AppUI.label.copyWith(color: filtered ? AppColors.primary : AppColors.textPrimary)),
          ]),
        ),
      ),
      SizedBox(width: AppBtn.gap(context)),
      _solidBtn(AppText.exportExcel, Icons.table_chart_rounded, AppColors.primary, _exporting ? null : _exportExcel),
      SizedBox(width: AppBtn.gap(context)),
      _solidBtn(AppText.exportPdf, Icons.picture_as_pdf_rounded, AppColors.primary, _exporting ? null : _exportPdf),
      SizedBox(width: AppBtn.gap(context)),
      OutlinedButton.icon(
        onPressed: _saving ? null : _bulkAllocate,
        icon: AppIcon('people', size: AppBtn.iconSize(context) + 2, color: AppColors.primary),
        label: const Text('Bulk Allocate'),
      ),
    ]);
  }

  PopupMenuItem<String> _check(String value, String label, bool on) => PopupMenuItem(
        value: value,
        height: 34,
        child: Row(children: [
          Icon(on ? Icons.radio_button_checked : Icons.radio_button_off, size: 16, color: on ? AppColors.primary : AppColors.textLight),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
        ]),
      );

  /// Export buttons: the kit's secondary (outlined) button, so the toolbar has
  /// one primary action. [color] is kept for callers.
  Widget _solidBtn(String label, IconData icon, Color color, VoidCallback? onPressed) => OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: AppBtn.iconSize(context)),
        label: Text(label),
      );

  // Column widths: checkbox, S.No, Adm No, Name (flex), Gender, Standard, Section, Status, Action.
  Widget _cols(List<Widget> c) => Row(children: [
        SizedBox(width: 44.w, child: c[0]),
        SizedBox(width: 60.w, child: c[1]),
        SizedBox(width: 130.w, child: c[2]),
        Expanded(child: c[3]),
        SizedBox(width: 100.w, child: c[4]),
        SizedBox(width: 130.w, child: c[5]),
        SizedBox(width: 230.w, child: c[6]),
        SizedBox(width: 130.w, child: c[7]),
        SizedBox(width: 60.w, child: Center(child: c[8])),
      ]);

  Widget _table() {
    final rows = _rows;
    final pendingRows = rows.where((a) => a.isPending).toList();
    final allTicked = pendingRows.isNotEmpty && pendingRows.every((a) => _ticked.contains(a.admId));
    final someTicked = pendingRows.any((a) => _ticked.contains(a.admId));
    final h = AppUI.tableHead;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(children: [
        Container(
          decoration: AppUI.tableHeadBar,
          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h),
          child: _cols([
            Checkbox(
              value: allTicked ? true : (someTicked ? null : false),
              tristate: true,
              onChanged: pendingRows.isEmpty
                  ? null
                  : (_) => setState(() {
                        if (allTicked) {
                          _ticked.removeAll(pendingRows.map((a) => a.admId));
                        } else {
                          _ticked.addAll(pendingRows.map((a) => a.admId));
                        }
                      }),
            ),
            Text('S.NO', style: h),
            Text(isSchool ? 'ADMISSION NO.' : 'REGISTER NO.', style: h),
            Text('STUDENT NAME', style: h),
            Text('GENDER', style: h),
            Text(schoolTerm('COURSE'), style: h),
            Text(schoolTerm('CLASS'), style: h),
            Text('STATUS', style: h),
            Text('ACTION', style: h),
          ]),
        ),
        Expanded(child: _body(rows)),
      ]),
    );
  }

  Widget _body(List<AdmissionModel> rows) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty) {
      final msg = _search.text.trim().isNotEmpty
          ? 'No students match "${_search.text.trim()}"'
          : _status == _Status.pending
              ? schoolTerm('No students waiting for a class${_selectedCourse == null ? '' : ' in $_selectedCourse'}')
              : 'No students to show';
      return AppUI.empty(
        title: msg,
        why: _search.text.trim().isNotEmpty
            ? 'Try a different name or number.'
            : _status == _Status.pending
                ? 'New admissions saved without a class appear here.'
                : 'Change the filters to see more.',
        icon: 'task-square',
      );
    }
    return FocusTraversalGroup(
      child: ListView.builder(
        itemCount: rows.length,
        itemBuilder: (_, i) => _row(rows[i], i),
      ),
    );
  }

  Widget _row(AdmissionModel a, int index) {
    final cell = AppUI.cell;
    final pending = a.isPending;
    final options = _classNamesFor(a.courname);
    final chosen = _rowClass[a.admId];
    return Container(
      decoration: BoxDecoration(
        color: _ticked.contains(a.admId) && pending ? AppColors.primaryLight.withValues(alpha: 0.35) : Colors.white,
        border: const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 6.h),
      child: _cols([
        Checkbox(
          value: pending && _ticked.contains(a.admId),
          onChanged: pending
              ? (v) => setState(() => v == true ? _ticked.add(a.admId) : _ticked.remove(a.admId))
              : null,
        ),
        Text('${index + 1}', style: cell),
        Text(a.admno, style: cell, overflow: TextOverflow.ellipsis),
        Text(a.stuname, style: cell, overflow: TextOverflow.ellipsis),
        Text(a.genderLabel, style: cell),
        Text(a.courname ?? '—', style: cell, overflow: TextOverflow.ellipsis),
        Padding(
          padding: EdgeInsets.only(right: 16.w),
          child: pending
              ? DropdownButtonFormField<String>(
                  key: ValueKey('cls-${a.admId}-$chosen'),
                  initialValue: options.contains(chosen) ? chosen : null,
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.textSecondary),
                  style: AppUI.fieldText(context, filled: options.contains(chosen)),
                  decoration: _cellDec(filled: options.contains(chosen)),
                  hint: Text(schoolTerm('Select class'), style: AppUI.fieldText(context).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500)),
                  items: [
                    for (final e in options)
                      DropdownMenuItem(value: e, child: Text(e, style: AppUI.fieldText(context))),
                  ],
                  onChanged: (v) => _setSection(a, v),
                )
              : Text(_sectionOf(a), style: cell.copyWith(fontWeight: FontWeight.w600)),
        ),
        Align(alignment: Alignment.centerLeft, child: _statusChip(pending)),
        PopupMenuButton<String>(
          tooltip: 'Actions',
          icon: const Icon(Icons.more_vert, color: AppColors.textSecondary),
          onSelected: (v) {
            if (v == 'save') {
              _save([a]);
            } else if (v == 'clear') {
              setState(() {
                _rowClass.remove(a.admId);
                _ticked.remove(a.admId);
              });
            }
          },
          itemBuilder: (_) => pending
              ? [
                  PopupMenuItem(value: 'save', enabled: (chosen ?? '').isNotEmpty && !_saving, child: const Text('Allocate Now')),
                  PopupMenuItem(value: 'clear', enabled: (chosen ?? '').isNotEmpty, child: Text(schoolTerm('Clear Class'))),
                ]
              : [
                  PopupMenuItem(
                    enabled: false,
                    child: Text(
                      'Allocated to ${_sectionOf(a)}'
                      '${a.allocatedby == null ? '' : ' by ${a.allocatedby}'}'
                      '${a.allocateddate == null ? '' : ' on ${a.allocateddate!.day.toString().padLeft(2, '0')}-${a.allocateddate!.month.toString().padLeft(2, '0')}-${a.allocateddate!.year}'}',
                      style: AppUI.muted,
                    ),
                  ),
                ],
        ),
      ]),
    );
  }

  Widget _statusChip(bool pending) =>
      AppUI.chip(pending ? 'Pending' : 'Allocated', pending ? AppStatus.warning : AppStatus.success);

  Widget _actionBar() {
    final count = _tickedCount;
    return Row(children: [
      Text(count > 0 ? '$count selected for allocation' : schoolTerm('Select a class or tick students to allocate'),
          style: AppUI.body.copyWith(color: AppColors.textSecondary)),
      const Spacer(),
      ElevatedButton.icon(
        onPressed: _saving || count == 0 ? null : () => _save(),
        icon: _saving
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(Icons.save_rounded, size: AppBtn.iconSize(context) + 2),
        label: Text(_saving ? 'Allocating…' : 'Save Allocation'),
      ),
    ]);
  }

  // ── decorations ───────────────────────────────────────────────────
  InputDecoration _dec({bool filled = false}) => AppUI.field(context, '', filled: filled);

  InputDecoration _cellDec({bool filled = false}) => AppUI.field(context, '', filled: filled, dense: true);

  Widget _courseDropdown() {
    final names = _courseNames;
    final allLabel = schoolTerm('All Courses');
    return DropdownButtonFormField<String>(
      key: ValueKey('course-$_selectedCourse-${names.length}'),
      initialValue: _selectedCourse ?? '',
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.textSecondary),
      style: AppUI.fieldText(context, filled: true),
      decoration: _dec(filled: true),
      items: [
        DropdownMenuItem(value: '', child: Text(allLabel, style: AppUI.fieldText(context))),
        for (final e in names)
          DropdownMenuItem(value: e, child: Text(e, style: AppUI.fieldText(context), overflow: TextOverflow.ellipsis)),
      ],
      selectedItemBuilder: (_) => [
        for (final e in ['', ...names])
          Align(
            alignment: Alignment.centerLeft,
            child: Text(e.isEmpty ? allLabel : e,
                overflow: TextOverflow.ellipsis,
                style: AppUI.fieldText(context, filled: true)),
          ),
      ],
      onChanged: (v) => setState(() => _selectedCourse = (v == null || v.isEmpty) ? null : v),
    );
  }

  Widget _orderDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _orderBy,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.textSecondary),
      style: AppUI.fieldText(context, filled: true),
      decoration: _dec(filled: true),
      items: [
        for (final e in _orderOptions)
          DropdownMenuItem(value: e, child: Text(schoolTerm(_orderLabels[e] ?? e), style: AppUI.fieldText(context))),
      ],
      selectedItemBuilder: (_) => [
        for (final e in _orderOptions)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(schoolTerm(_orderLabels[e] ?? e),
                overflow: TextOverflow.ellipsis,
                style: AppUI.fieldText(context, filled: true)),
          ),
      ],
      onChanged: (v) => setState(() => _orderBy = v ?? 'Admission No'),
    );
  }
}
