import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/class_sort.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/report_pdf_export.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/classic_h_scrollbar.dart';

/// CONSOLIDATED SUMMARY STATEMENT OF DEMAND - CONCESSION - COLLECTION -
/// BALANCE FOR THE YEAR -- the old product's "Consolidated Summary"
/// (sp_arrivefeereceivable), one row per student:
///
///   Sno | Adm No | Student Name | Class | <one DEMAND column per fee type> |
///   Concession | Collection | Pre Yr Adv Collection | Refund |
///   TC Demand | TC Collection | TC Refund | Misc. Collection |
///   Advance Refund | Net Balance | Mobile No | Category
///
/// Collection type, as the old screen: fee related to the CURRENT year (the
/// year's regular demands), to NEXT year (advance demands) or MISC
/// collection. A TC student shows what they paid as TC demand / collection,
/// with no balance -- they owe nothing more. Server side:
/// public.consolidated_summary (school_consolidated_summary.sql).
class ConsolidatedSummaryScreen extends StatefulWidget {
  const ConsolidatedSummaryScreen({super.key});

  @override
  State<ConsolidatedSummaryScreen> createState() => _ConsolidatedSummaryScreenState();
}

class _Stu {
  final Map<String, dynamic> s;
  final Map<String, double> fee = {}; // fee type -> demand (or misc amount)
  double concession = 0, coll = 0, preadv = 0, refund = 0, bal = 0, misc = 0, advRefund = 0;
  _Stu(this.s);
  bool get tc => s['tc'] == true;
  double get tcDemand => tc ? coll + preadv : 0;
  double get tcRefund => tc ? refund : 0;
}

class _ConsolidatedSummaryScreenState extends State<ConsolidatedSummaryScreen> {
  static const _modes = [
    ('CURRENT', 'Fee related to current year'),
    ('NEXT', 'Fee related to next year'),
    ('MISC', 'Miscellaneous collection'),
  ];

  String _mode = 'CURRENT';
  int? _cour, _cla;
  String? _term, _feeType;
  List<Map<String, dynamic>> _courses = [], _classes = [];
  List<String> _terms = [], _feeTypes = [];
  String _insName = '', _insAddress = '', _insCity = '', _year = '';

  bool _loading = true, _running = false, _exporting = false;
  String? _error;
  List<_Stu> _rows = [];
  List<String> _cols = []; // fee type columns, in order
  String _nextYear = '';

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  static String _m(double v) => v.abs() < 0.005 ? '' : formatIndianNumber(v);

  // the table's two visible scrollbars (sideways for the many columns, and
  // up/down pinned to the visible right edge)
  final ScrollController _hCtrl = ScrollController();
  final ScrollController _vCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadMasters();
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    _vCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMasters() async {
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('semester').select('semname').eq('ins_id', _insId).eq('activestatus', 1).order('sem_id'),
        SupabaseService.fromSchema('feetype').select('feedesc').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.getInstitutionInfo(_insId),
      ]);
      if (!mounted) return;
      final info = r[4] as ({String? name, String? logo, String? address, String? mobile, String? email});
      final parts = (info.address ?? '').replaceAll('\n', ', ').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      setState(() {
        _courses = List<Map<String, dynamic>>.from(r[0] as List)..sort((a, b) => (_id(a['ordid']) ?? 999).compareTo(_id(b['ordid']) ?? 999));
        _classes = List<Map<String, dynamic>>.from(r[1] as List)..sort((a, b) => classCompare('${a['claname']}', '${b['claname']}'));
        _terms = [for (final t in r[2] as List) '${t['semname']}'].toSet().toList();
        _feeTypes = ([for (final f in r[3] as List) '${f['feedesc']}'].toSet().toList())..sort();
        _insName = info.name ?? '';
        if (parts.length > 1) _insCity = parts.removeLast();
        _insAddress = parts.join(', ');
        _year = context.read<AuthProvider>().yearLabel ?? '';
        _loading = false;
      });
      _run();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  List<int>? get _claIds {
    if (_cla != null) return [_cla!];
    if (_cour != null) return [for (final c in _classes) if (_id(c['cour_id']) == _cour) _id(c['cla_id'])!];
    return null;
  }

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final res = await SupabaseService.client.rpc('consolidated_summary', params: {
        'p_token': SupabaseService.sessionToken,
        'p_mode': _mode,
        'p_cla_ids': _claIds,
        'p_terms': _term == null ? null : [_term],
        'p_fee_types': _feeType == null ? null : [_feeType],
      });
      final j = Map<String, dynamic>.from(res as Map);
      final byId = <int, _Stu>{};
      for (final x in (j['students'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(x as Map);
        byId[_id(m['stu_id'])!] = _Stu(m);
      }
      final cols = <String>{};
      for (final x in (j['lines'] as List? ?? const [])) {
        final l = x as Map;
        final s = byId[_id(l['stu_id'])];
        if (s == null) continue;
        final ft = '${l['ft']}';
        cols.add(ft);
        s.fee[ft] = (s.fee[ft] ?? 0) + _num(l['demand']);
        s.concession += _num(l['concession']);
        s.coll += _num(l['coll']);
        s.preadv += _num(l['preadv']);
        s.refund += _num(l['refund']);
        s.bal += _num(l['bal']);
      }
      for (final x in (j['misc'] as List? ?? const [])) {
        final l = x as Map;
        final s = byId[_id(l['stu_id'])];
        if (s == null) continue;
        s.misc += _num(l['amt']);
        if (_mode == 'MISC') {
          final ft = '${l['ft']}';
          cols.add(ft);
          s.fee[ft] = (s.fee[ft] ?? 0) + _num(l['amt']);
        }
      }
      for (final x in (j['advrefund'] as List? ?? const [])) {
        final s = byId[_id((x as Map)['stu_id'])];
        if (s != null) s.advRefund += _num(x['amt']);
      }
      final rows = byId.values.toList()
        ..sort((a, b) {
          final c = classCompare('${a.s['stuclass'] ?? ''}', '${b.s['stuclass'] ?? ''}');
          return c != 0 ? c : '${a.s['stuadmno']}'.compareTo('${b.s['stuadmno']}');
        });
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _cols = cols.toList()..sort((a, b) => _feeTypes.indexOf(a).compareTo(_feeTypes.indexOf(b)));
        _nextYear = '${j['year'] ?? ''}';
        _error = null;
      });
    } catch (e) {
      if (mounted) _snack('Could not load the report. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  // ── columns per collection type ──────────────────────────────────────────
  /// (header, value of a student, is-amount)
  List<(String, String Function(_Stu), bool)> get _columns {
    final fee = [
      for (final f in _cols) (f.toUpperCase(), (_Stu s) => s.tc && _mode == 'CURRENT' ? '' : _m(s.fee[f] ?? 0), true),
    ];
    final head = <(String, String Function(_Stu), bool)>[
      ('ADMISSION NO', (s) => '${s.s['stuadmno'] ?? ''}', false),
      ('STUDENT NAME', (s) => '${s.s['stuname'] ?? ''}${s.tc ? '  (TC)' : ''}', false),
      (schoolTerm('CLASS'), (s) => '${s.s['stuclass'] ?? ''}', false),
    ];
    final tail = <(String, String Function(_Stu), bool)>[
      ('MOBILE NO', (s) => '${s.s['mobile'] ?? ''}', false),
      ('CATEGORY', (s) => '${s.s['category'] ?? ''}', false),
    ];
    switch (_mode) {
      case 'NEXT':
        return [
          ...head,
          ...fee,
          ('COLLECTION', (s) => _m(s.coll), true),
          ('NET BALANCE', (s) => _m(s.bal), true),
          ...tail,
        ];
      case 'MISC':
        return [
          ...head,
          ...fee,
          ('TOTAL', (s) => _m(s.misc), true),
          ...tail,
        ];
      default:
        return [
          ...head,
          ...fee,
          ('CONCESSION', (s) => s.tc ? '' : _m(s.concession), true),
          ('COLLECTION', (s) => s.tc ? '' : _m(s.coll), true),
          ('PREVIOUS YEAR ADVANCE COLLECTION', (s) => s.tc ? '' : _m(s.preadv), true),
          ('REFUND', (s) => s.tc ? '' : _m(s.refund), true),
          ('TC DEMAND', (s) => _m(s.tcDemand), true),
          ('TC COLLECTION', (s) => _m(s.tcDemand), true),
          ('TC REFUND', (s) => _m(s.tcRefund), true),
          ('MISCELLANEOUS COLLECTION', (s) => _m(s.misc), true),
          ('ADVANCE REFUND', (s) => _m(s.advRefund), true),
          ('NET BALANCE', (s) => s.tc ? '' : _m(s.bal), true),
          ...tail,
        ];
    }
  }

  /// Grand total of an amount column (by re-reading each row's value).
  String _total(String Function(_Stu) f) {
    var t = 0.0;
    for (final s in _rows) {
      t += double.tryParse(f(s).replaceAll(',', '')) ?? 0;
    }
    return _m(t);
  }

  String get _title => switch (_mode) {
        'NEXT' => 'CONSOLIDATED SUMMARY STATEMENT OF ADVANCE DEMAND - COLLECTION - BALANCE${_nextYear.isEmpty ? '' : ' FOR $_nextYear'}',
        'MISC' => 'CONSOLIDATED SUMMARY STATEMENT FOR MISCELLANEOUS COLLECTION',
        _ => 'CONSOLIDATED SUMMARY STATEMENT OF DEMAND - CONCESSION - COLLECTION - BALANCE FOR THE YEAR $_year',
      };

  String get _scope {
    final parts = <String>[
      if (_cla != null) '${_classes.firstWhere((c) => _id(c['cla_id']) == _cla, orElse: () => const {})['claname'] ?? ''}'
      else if (_cour != null) '${_courses.firstWhere((c) => _id(c['cour_id']) == _cour, orElse: () => const {})['courname'] ?? ''}',
      if (_term != null) _term!,
      if (_feeType != null) _feeType!,
    ];
    return parts.isEmpty ? 'All' : parts.join(' · ');
  }

  // ── export ───────────────────────────────────────────────────────────────
  Future<void> _exportPdf() async {
    if (_rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final cols = _columns;
      String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final ok = await saveReportPdf(
        context,
        fileName: 'Consolidated_Summary_${_mode}_${safe(_scope)}',
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: _title,
        subtitle: 'Scope : $_scope',
        headers: ['S. NO.', ...cols.map((c) => c.$1)],
        rows: [
          for (var i = 0; i < _rows.length; i++) ['${i + 1}', ...cols.map((c) => c.$2(_rows[i]))],
          ['', 'TOTAL', ...cols.skip(1).map((c) => c.$3 ? _total(c.$2) : '')],
        ],
        rightAlign: {for (var i = 0; i < cols.length; i++) if (cols[i].$3) i + 1},
        landscape: true,
        footNote: 'Students : ${_rows.length}',
      );
      if (ok) _snack('Consolidated summary PDF saved.', AppColors.success);
    } catch (e) {
      _snack('Could not build the PDF. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportExcel() async {
    if (_rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Consolidated Summary',
        fileName: 'Consolidated_Summary_${_mode}_${safe(_scope)}.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      final cols = _columns;
      final book = xl.Excel.createExcel();
      final sheet = book['Consolidated Summary'];
      book.delete('Sheet1');
      final bold = xl.CellStyle(bold: true, fontSize: 11);
      final hdr = xl.CellStyle(bold: true, fontSize: 10, backgroundColorHex: xl.ExcelColor.fromHexString('#F2F4F7'));
      void put(int c, int r, String v, [xl.CellStyle? st, bool number = false]) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        final n = number ? double.tryParse(v.replaceAll(',', '')) : null;
        cell.value = n != null ? xl.DoubleCellValue(n) : xl.TextCellValue(v);
        if (st != null) cell.cellStyle = st;
      }

      put(1, 0, _insName.toUpperCase(), bold);
      if (_insAddress.isNotEmpty) put(1, 1, _insAddress.toUpperCase());
      if (_insCity.isNotEmpty) put(1, 2, _insCity.toUpperCase());
      put(1, 3, _title, bold);
      put(1, 4, 'Scope : $_scope');
      const h = 6;
      put(0, h, 'S. NO.', hdr);
      for (var c = 0; c < cols.length; c++) {
        put(c + 1, h, cols[c].$1, hdr);
        sheet.setColumnWidth(c + 1, c == 1 ? 30 : 16);
      }
      var r = h + 1;
      for (var i = 0; i < _rows.length; i++, r++) {
        put(0, r, '${i + 1}');
        for (var c = 0; c < cols.length; c++) {
          put(c + 1, r, cols[c].$2(_rows[i]), null, cols[c].$3);
        }
      }
      put(1, r, 'TOTAL', bold);
      for (var c = 1; c < cols.length; c++) {
        if (cols[c].$3) put(c + 1, r, _total(cols[c].$2), bold, true);
      }
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack('Consolidated summary saved -- ${_rows.length} students.', AppColors.success);
    } catch (e) {
      _snack('Could not build the Excel file. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  Widget _drop<T>(String hint, T? value, List<(T, String)> items, ValueChanged<T?> onChanged, {String? icon, bool allowAll = true, String allLabel = 'All'}) {
    return DropdownButtonFormField<T?>(
      key: ValueKey('$hint-$value-${items.length}'),
      initialValue: value,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      style: AppUI.fieldText(context, filled: value != null),
      decoration: AppUI.field(context, hint, filled: value != null, leadingIcon: icon),
      items: [
        if (allowAll) DropdownMenuItem<T?>(value: null, child: Text(allLabel, overflow: TextOverflow.ellipsis)),
        for (final e in items) DropdownMenuItem<T?>(value: e.$1, child: Text(e.$2, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: _running ? null : onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open the report',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton.icon(onPressed: _loadMasters, icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
      );
    }
    final cols = _columns;
    final sections = [for (final c in _classes) if (_cour == null || _id(c['cour_id']) == _cour) (_id(c['cla_id'])!, '${c['claname']}')];
    double sum(double Function(_Stu) f) => _rows.fold(0.0, (t, s) => t + f(s));

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'chart-2',
          title: 'Consolidated Summary',
          subtitle: 'Demand, concession, collection and balance for each student',
          trailing: [
            OutlinedButton.icon(
              onPressed: _exporting || _rows.isEmpty ? null : _exportExcel,
              icon: const Icon(Icons.table_chart_outlined, size: 16),
              label: const Text(AppText.exportExcel),
            ),
            OutlinedButton.icon(
              onPressed: _exporting || _rows.isEmpty ? null : _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: const Text(AppText.exportPdf),
            ),
          ],
        ),
        SizedBox(height: 16.h),
        // filters
        Row(children: [
          Expanded(
            flex: 5,
            child: _drop<String>('Collection Type', _mode, [for (final m in _modes) (m.$1, m.$2)], (v) {
              setState(() => _mode = v ?? 'CURRENT');
              _run();
            }, icon: 'layer', allowAll: false),
          ),
          SizedBox(width: 10.w),
          Expanded(
            flex: 3,
            child: _drop<int>(schoolTerm('Course'), _cour, [for (final c in _courses) (_id(c['cour_id'])!, '${c['courname']}')], (v) {
              setState(() {
                _cour = v;
                _cla = null;
              });
              _run();
            }, icon: 'teacher', allLabel: schoolTerm('All Courses')),
          ),
          SizedBox(width: 10.w),
          Expanded(
            flex: 3,
            child: _drop<int>(schoolTerm('Class'), _cla, sections, (v) {
              setState(() => _cla = v);
              _run();
            }, icon: 'book-1', allLabel: schoolTerm('All Classes')),
          ),
          SizedBox(width: 10.w),
          Expanded(
            flex: 3,
            child: _drop<String>(schoolTerm('Semester'), _term, [for (final t in _terms) (t, t)], (v) {
              setState(() => _term = v);
              _run();
            }, icon: 'calendar-1', allLabel: schoolTerm('All Semesters')),
          ),
          SizedBox(width: 10.w),
          Expanded(
            flex: 3,
            child: _drop<String>('Fee Type', _feeType, [for (final f in _feeTypes) (f, f)], (v) {
              setState(() => _feeType = v);
              _run();
            }, icon: 'receipt-discount', allLabel: 'All Fee Types'),
          ),
          SizedBox(width: 10.w),
          OutlinedButton.icon(
            onPressed: _running ? null : _run,
            icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
          ),
        ]),
        SizedBox(height: 16.h),
        // KPI tiles
        Row(children: [
          Expanded(child: AppUI.kpi(icon: 'people', label: 'Students', value: '${_rows.length}', sub: '${_rows.where((s) => s.tc).length} with TC')),
          SizedBox(width: 12.w),
          if (_mode == 'MISC')
            Expanded(child: AppUI.kpi(icon: 'receipt-2', label: 'Miscellaneous Collection', value: '₹${formatIndianNumber(sum((s) => s.misc))}', tint: AppColors.success))
          else ...[
            Expanded(child: AppUI.kpi(icon: 'receipt-2', label: 'Demand', value: '₹${formatIndianNumber(sum((s) => s.tc ? 0 : s.fee.values.fold(0.0, (a, b) => a + b)))}', tint: AppColors.demand)),
            SizedBox(width: 12.w),
            Expanded(child: AppUI.kpi(icon: 'money-recive', label: 'Collected', value: '₹${formatIndianNumber(sum((s) => s.coll + s.preadv - s.refund))}', tint: AppColors.success)),
            SizedBox(width: 12.w),
            Expanded(child: AppUI.kpi(icon: 'wallet-money', label: 'Net Balance', value: '₹${formatIndianNumber(sum((s) => s.tc ? 0 : s.bal))}', tint: AppColors.warning)),
          ],
        ]),
        SizedBox(height: 16.h),
        Expanded(child: _table(cols)),
        SizedBox(height: 10.h),
        Text(
          _rows.isEmpty
              ? ''
              : '${AppUI.showing(1, _rows.length, _rows.length)} students · $_scope'
                  '${_mode == 'CURRENT' ? ' · current-year demands only (arrears are not part of this statement)' : ''}',
          style: AppUI.muted,
        ),
      ]),
    );
  }

  Widget _table(List<(String, String Function(_Stu), bool)> cols) {
    if (_running && _rows.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_rows.isEmpty) {
      return AppUI.empty(
        title: 'Nothing to show',
        why: _mode == 'NEXT'
            ? 'No advance demands for these filters -- save an Advance Fee Demand first.'
            : _mode == 'MISC'
                ? 'No miscellaneous collection for these filters.'
                : schoolTerm('No fee demands for these filters. Select another class, semester or fee type.'),
        icon: 'chart-2',
      );
    }
    // widths: sno, adm no, name, class, then amounts / text tail
    double w(int i, String head) {
      if (head == 'STUDENT NAME') return 220;
      if (head == 'ADMISSION NO' || head == 'MOBILE NO') return 110;
      if (head == schoolTerm('CLASS') || head == 'CATEGORY') return 100;
      return head.length > 14 ? 130 : 110;
    }

    final widths = [56.0, for (var i = 0; i < cols.length; i++) w(i, cols[i].$1)];
    final total = widths.fold(0.0, (a, b) => a + b) + 32;
    Widget cell(String t, double width, {bool right = false, TextStyle? style}) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Text(t, textAlign: right ? TextAlign.right : TextAlign.left, overflow: TextOverflow.ellipsis, style: style ?? AppUI.cell),
          ),
        );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
      child: Column(children: [
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: ScrollConfiguration(
                // the bars are drawn below and at the right instead
                behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: LayoutBuilder(builder: (context, c) {
        final width = total < c.maxWidth ? c.maxWidth : total;
        return SingleChildScrollView(
          controller: _hCtrl,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(children: [
              // sticky header
              Container(
                color: AppColors.tableHeadBg,
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 12.h),
                child: Row(children: [
                  cell('S. NO.', widths[0], style: AppUI.tableHead),
                  for (var i = 0; i < cols.length; i++) cell(cols[i].$1, widths[i + 1], right: cols[i].$3, style: AppUI.tableHead),
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  controller: _vCtrl,
                  itemCount: _rows.length,
                  itemBuilder: (_, r) {
                    final s = _rows[r];
                    return Container(
                      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
                      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 10.h),
                      child: Row(children: [
                        cell('${r + 1}', widths[0], style: AppUI.muted),
                        for (var i = 0; i < cols.length; i++)
                          cell(cols[i].$2(s), widths[i + 1],
                              right: cols[i].$3,
                              style: cols[i].$1 == 'NET BALANCE'
                                  ? AppUI.money.copyWith(color: AppColors.warning)
                                  : (s.tc && i == 1 ? AppUI.cell.copyWith(color: AppColors.textLight) : (cols[i].$3 ? AppUI.money : AppUI.cell))),
                      ]),
                    );
                  },
                ),
              ),
              // grand total
              Container(
                decoration: const BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 12.h),
                child: Row(children: [
                  cell('', widths[0]),
                  for (var i = 0; i < cols.length; i++)
                    cell(i == 0 ? 'TOTAL' : (cols[i].$3 ? _total(cols[i].$2) : ''), widths[i + 1],
                        right: cols[i].$3, style: AppUI.money.copyWith(fontWeight: FontWeight.w800)),
                ]),
              ),
            ]),
          ),
        );
                }),
              ),
            ),
            AppScrollbarBar(controller: _vCtrl),
          ]),
        ),
        ClassicHScrollbar(controller: _hCtrl),
      ]),
    );
  }
}
