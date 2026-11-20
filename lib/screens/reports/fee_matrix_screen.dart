import 'dart:io';

import 'package:excel/excel.dart' as xl;
import '../../utils/excel_theme.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/report_pdf_export.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../utils/save_path.dart';

/// FEE MATRIX FOR <year> -- the old product's "Fee Matrix": every line of
/// the Section Fee Demand as a matrix, grouped by term:
///
///   TERM / STANDARD | REGULAR / OPTIONAL | NEW / OLD | BOYS / GIRLS |
///   <AMOUNT per standard or section> | TOTAL
///
/// with a TOTAL row per term and a GRAND TOTAL. A standard whose fees are
/// defined for the whole standard is one column; a section-level standard has
/// one column per section. TOTAL is what the fee raises across the school:
/// amount x the students it applies to (an optional fee: the students who
/// opted in). Server side: public.rpt_fee_matrix (school_rpt_fee_matrix.sql).
class FeeMatrixScreen extends StatefulWidget {
  const FeeMatrixScreen({super.key});

  @override
  State<FeeMatrixScreen> createState() => _FeeMatrixScreenState();
}

class _Col {
  final String key, label, level;
  final List<String> sections;
  final int students;
  const _Col(this.key, this.label, this.level, this.sections, this.students);
}

class _Cell {
  final double amt, total;
  final int n;
  final bool differs;
  const _Cell(this.amt, this.n, this.total, this.differs);
}

class _Line {
  final String term, feeType, type;
  final int nob, bgb, dhb, students;
  final Map<String, _Cell> cells;
  final double total;
  const _Line(this.term, this.feeType, this.type, this.nob, this.bgb, this.dhb, this.cells, this.total, this.students);
  bool get optional => type == 'OPT';
}

enum _Kind { term, line, termTotal, grandTotal }

/// One printed row: a term heading, a fee line, a term's TOTAL or the GRAND TOTAL.
class _VRow {
  final _Kind kind;
  final String label;
  final _Line? line;
  final Map<String, double> sums; // column key -> sum of amounts
  final double total;
  const _VRow(this.kind, this.label, {this.line, this.sums = const {}, this.total = 0});
}

class _FeeMatrixScreenState extends State<FeeMatrixScreen> {
  String _insName = '', _insAddress = '', _insCity = '', _year = '';
  bool _loading = true, _running = false, _exporting = false, _hideEmpty = false;
  String? _error;
  List<_Col> _allCols = [];
  List<_Line> _lines = [];

  // body scrolls both ways; the header follows the body sideways
  final ScrollController _hCtrl = ScrollController();
  final ScrollController _hHead = ScrollController();
  final ScrollController _vCtrl = ScrollController();

  static const double _rowH = 40, _headH = 52, _stuH = 34;
  static const double _wFee = 250, _wType = 104, _wNob = 84, _wBgb = 92, _wDhb = 120, _wAmt = 104, _wTotal = 136;

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  static int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  static String _m(double v) => v.abs() < 0.005 ? '' : formatIndianNumber(v);

  static String _typeText(String t) => t == 'OPT' ? 'OPTIONAL' : 'REGULAR';
  static String _nobText(int v) => switch (v) { 1 => 'NEW', 2 => 'OLD', _ => 'BOTH' };
  static String _bgbText(int v) => switch (v) { 1 => 'BOYS', 2 => 'GIRLS', _ => 'BOTH' };
  static String _dhbText(int v) => switch (v) { 1 => 'DAY SCHOLAR', 2 => 'HOSTELLER', _ => 'BOTH' };

  @override
  void initState() {
    super.initState();
    _hCtrl.addListener(() {
      if (_hHead.hasClients && _hHead.offset != _hCtrl.offset) {
        _hHead.jumpTo(_hCtrl.offset.clamp(0.0, _hHead.position.maxScrollExtent));
      }
    });
    _load();
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    _hHead.dispose();
    _vCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.client.rpc('rpt_fee_matrix', params: {'p_token': SupabaseService.sessionToken}),
        SupabaseService.getInstitutionInfo(_insId),
      ]);
      if (!mounted) return;
      final j = Map<String, dynamic>.from(r[0] as Map);
      final info = r[1] as ({String? name, String? logo, String? address, String? mobile, String? email});
      final parts = (info.address ?? '').replaceAll('\n', ', ').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      final cols = [
        for (final x in (j['columns'] as List? ?? const []))
          _Col('${x['key']}', '${x['label'] ?? ''}', '${x['level'] ?? ''}',
              [for (final s in (x['sections'] as List? ?? const [])) '$s'], _int(x['students'])),
      ];
      final lines = <_Line>[];
      for (final x in (j['rows'] as List? ?? const [])) {
        final m = x as Map;
        final cells = <String, _Cell>{};
        (m['cells'] as Map? ?? const {}).forEach((k, v) {
          final c = v as Map;
          cells['$k'] = _Cell(_num(c['amt']), _int(c['n']), _num(c['total']), c['differs'] == true);
        });
        lines.add(_Line('${m['term'] ?? ''}', '${m['fee_type'] ?? ''}', '${m['type'] ?? 'REG'}', _int(m['nob']), _int(m['bgb']),
            _int(m['dhb']), cells, _num(m['total']), _int(m['students'])));
      }
      setState(() {
        _allCols = cols;
        _lines = lines;
        _year = '${j['year'] ?? ''}'.isNotEmpty ? '${j['year']}' : (context.read<AuthProvider>().yearLabel ?? '');
        _insName = info.name ?? '';
        if (parts.length > 1) _insCity = parts.removeLast();
        _insAddress = parts.join(', ');
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (_loading) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      } else {
        _snack('Could not load the fee matrix. ${friendlyError(e)}', AppColors.error);
      }
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

  // ── derived ──────────────────────────────────────────────────────────────
  List<_Col> get _cols => _hideEmpty ? [for (final c in _allCols) if (_lines.any((l) => l.cells.containsKey(c.key))) c] : _allCols;

  bool get _showDhb => _lines.any((l) => l.dhb != 3);
  bool get _anyDiffers => _lines.any((l) => l.cells.values.any((c) => c.differs));
  int get _students => _allCols.fold(0, (a, c) => a + c.students);
  double _sumType(String t) => _lines.where((l) => l.type == t).fold(0.0, (a, l) => a + l.total);
  double get _grand => _lines.fold(0.0, (a, l) => a + l.total);

  /// Term heading, its fee lines, its TOTAL; GRAND TOTAL at the end. The
  /// server sends the lines already in term order.
  List<_VRow> get _vrows {
    final out = <_VRow>[];
    final grand = <String, double>{};
    var grandTotal = 0.0;
    var i = 0;
    while (i < _lines.length) {
      final term = _lines[i].term;
      out.add(_VRow(_Kind.term, term.toUpperCase()));
      final sums = <String, double>{};
      var total = 0.0;
      while (i < _lines.length && _lines[i].term.toUpperCase() == term.toUpperCase()) {
        final l = _lines[i++];
        out.add(_VRow(_Kind.line, l.feeType.toUpperCase(), line: l));
        l.cells.forEach((k, c) => sums[k] = (sums[k] ?? 0) + c.amt);
        total += l.total;
      }
      out.add(_VRow(_Kind.termTotal, 'TOTAL', sums: sums, total: total));
      sums.forEach((k, v) => grand[k] = (grand[k] ?? 0) + v);
      grandTotal += total;
    }
    if (_lines.isNotEmpty) out.add(_VRow(_Kind.grandTotal, 'GRAND TOTAL', sums: grand, total: grandTotal));
    return out;
  }

  /// The fixed (left) text of a row: fee type, regular / optional, new / old,
  /// boys / girls (and day scholar / hosteller when any line uses it).
  List<String> _fixed(_VRow r) {
    final l = r.line;
    return [
      r.label,
      l == null ? '' : _typeText(l.type),
      l == null ? '' : _nobText(l.nob),
      l == null ? '' : _bgbText(l.bgb),
      if (_showDhb) l == null ? '' : _dhbText(l.dhb),
    ];
  }

  List<String> get _fixedHeads => [
        'TERM / STANDARD',
        'REGULAR / OPTIONAL',
        'NEW / OLD',
        'BOYS / GIRLS',
        if (_showDhb) 'DAY SCHOLAR / HOSTELLER',
      ];

  List<double> get _fixedWidths => [_wFee, _wType, _wNob, _wBgb, if (_showDhb) _wDhb];

  /// Amount shown in a column of a row ('' = none); '*' marks a standard whose
  /// sections do not all carry the same amount.
  String _amt(_VRow r, _Col c, {bool mark = true}) {
    switch (r.kind) {
      case _Kind.term:
        return '';
      case _Kind.line:
        final cell = r.line!.cells[c.key];
        if (cell == null) return '';
        return '${_m(cell.amt)}${mark && cell.differs ? ' *' : ''}';
      default:
        return _m(r.sums[c.key] ?? 0);
    }
  }

  String _rowTotal(_VRow r) => r.kind == _Kind.term ? '' : _m(r.kind == _Kind.line ? r.line!.total : r.total);

  // ── export ───────────────────────────────────────────────────────────────
  String get _title => 'FEE MATRIX FOR  $_year';
  static const _note = 'TOTAL = amount x students it applies to (optional fees: students who opted in). '
      'Active students only; TC students are left out.';
  static const _diffNote = '* Not the same in every section of the standard -- the first section\'s amount is shown.';

  Future<void> _exportExcel() async {
    if (_lines.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final path = await pickSavePath(
        dialogTitle: 'Save Fee Matrix',
        fileName: 'Fee_Matrix_${_year.replaceAll(RegExp(r'[^0-9A-Za-z]+'), '_')}.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      final cols = _cols;
      final book = xl.Excel.createExcel();
      final sheet = book['Fee Matrix'];
      book.delete('Sheet1');
      final bold = xl.CellStyle(bold: true, fontSize: 11);
      final hdr = xl.CellStyle(bold: true, fontSize: 10, backgroundColorHex: XlTheme.headerBg, fontColorHex: XlTheme.headerFg, textWrapping: xl.TextWrapping.WrapText);
      void put(int c, int r, String v, [xl.CellStyle? st, bool number = false]) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        final n = number ? double.tryParse(v.replaceAll(',', '').replaceAll('*', '').trim()) : null;
        cell.value = n != null ? xl.DoubleCellValue(n) : xl.TextCellValue(v);
        if (st != null) cell.cellStyle = st;
      }

      // old layout: A-D the line, E day scholar / hosteller (blank when no
      // line uses it), F.. one column per standard / section, then TOTAL
      put(1, 0, _insName.toUpperCase(), bold);
      if (_insAddress.isNotEmpty) put(1, 1, _insAddress.toUpperCase());
      if (_insCity.isNotEmpty) put(1, 2, _insCity.toUpperCase());
      put(1, 3, _title, bold);
      const h = 5, first = 5;
      final totalCol = first + cols.length;
      final heads = ['TERM / STANDARD', 'REGULAR / OPTIONAL', 'NEW / OLD', 'BOYS / GIRLS', _showDhb ? 'DAY SCHOLAR / HOSTELLER' : ''];
      for (var c = 0; c < heads.length; c++) {
        put(c, h, heads[c], hdr);
      }
      for (var c = 0; c < cols.length; c++) {
        put(first + c, h, cols[c].label.toUpperCase(), hdr);
        sheet.setColumnWidth(first + c, 11);
      }
      put(totalCol, h, 'TOTAL', hdr);
      sheet.setColumnWidth(0, 34);
      sheet.setColumnWidth(1, 13);
      sheet.setColumnWidth(2, 9);
      sheet.setColumnWidth(3, 9);
      sheet.setColumnWidth(4, _showDhb ? 13 : 3);
      sheet.setColumnWidth(totalCol, 15);
      // students per column
      var r = h + 1;
      put(0, r, 'STUDENTS', bold);
      for (var c = 0; c < cols.length; c++) {
        put(first + c, r, '${cols[c].students}', null, true);
      }
      put(totalCol, r, '${cols.fold(0, (a, c) => a + c.students)}', bold, true);
      r++;
      for (final v in _vrows) {
        final strong = v.kind != _Kind.line;
        final fx = _fixed(v);
        for (var c = 0; c < fx.length && c < 5; c++) {
          if (fx[c].isNotEmpty) put(c, r, fx[c], strong ? bold : null);
        }
        for (var c = 0; c < cols.length; c++) {
          final a = _amt(v, cols[c]);
          if (a.isEmpty) continue;
          // a flagged amount keeps its '*' as text
          put(first + c, r, a, strong ? bold : null, !a.endsWith('*'));
        }
        final t = _rowTotal(v);
        if (t.isNotEmpty) put(totalCol, r, t, bold, true);
        r++;
      }
      r++;
      put(0, r++, _note);
      if (_anyDiffers) put(0, r++, _diffNote);
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack('Fee matrix saved.', AppColors.success);
    } catch (e) {
      _snack('Could not build the Excel file. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportPdf() async {
    if (_lines.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final cols = _cols;
      final fixedHeads = _fixedHeads;
      final nFixed = fixedHeads.length;
      final ok = await saveReportPdf(
        context,
        fileName: 'Fee_Matrix_${_year.replaceAll(RegExp(r'[^0-9A-Za-z]+'), '_')}',
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: _title,
        subtitle: 'Students : $_students',
        headers: [...fixedHeads, ...cols.map((c) => c.label.toUpperCase()), 'TOTAL'],
        rows: [
          ['STUDENTS', for (var i = 1; i < nFixed; i++) '', ...cols.map((c) => '${c.students}'), '${cols.fold(0, (a, c) => a + c.students)}'],
          for (final v in _vrows) [..._fixed(v), ...cols.map((c) => _amt(v, c)), _rowTotal(v)],
        ],
        rightAlign: {for (var i = nFixed; i <= nFixed + cols.length; i++) i},
        landscape: true,
        footNote: _anyDiffers ? '$_note\n$_diffNote' : _note,
      );
      if (ok) _snack('Fee matrix PDF saved.', AppColors.success);
    } catch (e) {
      _snack('Could not build the PDF. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return AppUI.empty(
        title: 'Could not open the report',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton.icon(
          onPressed: () {
            setState(() {
              _loading = true;
              _error = null;
            });
            _load();
          },
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Retry'),
        ),
      );
    }
    final regular = _lines.where((l) => !l.optional).length;
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'grid-1',
          title: 'Fee Matrix',
          subtitle: 'Each fee of the Section Fee Demand by Standard and Section, term by term${_year.isEmpty ? '' : ' · $_year'}',
          trailing: [
            OutlinedButton.icon(
              onPressed: _running ? null : _load,
              icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
            OutlinedButton.icon(
              onPressed: _exporting || _lines.isEmpty ? null : _exportExcel,
              icon: const Icon(Icons.table_chart_outlined, size: 16),
              label: const Text(AppText.exportExcel),
            ),
            OutlinedButton.icon(
              onPressed: _exporting || _lines.isEmpty ? null : _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: const Text(AppText.exportPdf),
            ),
          ],
        ),
        SizedBox(height: 16.h),
        Row(children: [
          Expanded(child: AppUI.kpi(icon: 'people', label: 'Students', value: '$_students', sub: 'Active, without TC students')),
          SizedBox(width: 12.w),
          Expanded(
            child: AppUI.kpi(icon: 'receipt-2', label: 'Regular Fees', value: '₹${formatIndianNumber(_sumType('REG'))}', sub: '$regular fee line${regular == 1 ? '' : 's'}', tint: AppColors.demand),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: AppUI.kpi(
                icon: 'receipt-discount',
                label: 'Optional Fees',
                value: '₹${formatIndianNumber(_sumType('OPT'))}',
                sub: '${_lines.length - regular} fee line${_lines.length - regular == 1 ? '' : 's'} · opted-in students',
                tint: AppColors.teal),
          ),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'wallet-money', label: 'Grand Total', value: '₹${formatIndianNumber(_grand)}', tint: AppColors.warning)),
        ]),
        SizedBox(height: 12.h),
        Row(children: [
          Checkbox(
            value: _hideEmpty,
            activeColor: AppColors.primary,
            visualDensity: VisualDensity.compact,
            onChanged: (v) => setState(() => _hideEmpty = v ?? false),
          ),
          Text('Hide Standards and Sections With No Fees', style: AppUI.body),
        ]),
        SizedBox(height: 8.h),
        Expanded(child: _table()),
        SizedBox(height: 10.h),
        Text(_anyDiffers ? '$_note\n$_diffNote' : _note, style: AppUI.muted),
      ]),
    );
  }

  Widget _cell(String t, double width, {bool right = false, TextStyle? style, String? tip}) {
    final text = Padding(
      padding: EdgeInsets.symmetric(horizontal: 8.w),
      child: Text(t, textAlign: right ? TextAlign.right : TextAlign.left, maxLines: 2, overflow: TextOverflow.ellipsis, style: style ?? AppUI.cell),
    );
    return SizedBox(
      width: width,
      child: tip == null || t.isEmpty ? text : Tooltip(message: tip, waitDuration: const Duration(milliseconds: 400), child: text),
    );
  }

  BoxDecoration _rowDeco(_Kind k) => BoxDecoration(
        color: switch (k) {
          _Kind.term => AppColors.sunken,
          _Kind.termTotal => AppColors.goldTint,
          _Kind.grandTotal => AppColors.primaryTint,
          _Kind.line => AppColors.card,
        },
        border: Border(bottom: BorderSide(color: k == _Kind.line ? AppColors.line2 : AppColors.line)),
      );

  TextStyle _textStyle(_Kind k) => switch (k) {
        _Kind.term => AppUI.label.copyWith(color: AppColors.primaryText, letterSpacing: 0.6),
        _Kind.line => AppUI.cell,
        _ => AppUI.label,
      };

  TextStyle _moneyStyle(_Kind k) => k == _Kind.line ? AppUI.money : AppUI.money.copyWith(fontWeight: FontWeight.w800);

  Widget _table() {
    if (_running && _lines.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_lines.isEmpty) {
      return AppUI.empty(
        title: 'Nothing to show',
        why: 'No fee lines yet -- define the Section Fee Demand for this year first.',
        icon: 'grid-1',
      );
    }
    final cols = _cols;
    final rows = _vrows;
    final fw = _fixedWidths;
    final fixedW = fw.fold(0.0, (a, b) => a + b);
    final scrollW = cols.length * _wAmt + _wTotal;
    final heads = _fixedHeads;

    // fixed (left) part of one row
    Widget fixedRow(_VRow r) => Container(
          height: _rowH,
          decoration: _rowDeco(r.kind),
          child: Row(children: [
            for (var i = 0; i < fw.length; i++)
              _cell(_fixed(r)[i], fw[i],
                  style: i == 0 ? _textStyle(r.kind) : (r.line != null && r.line!.optional && i == 1 ? AppUI.cell.copyWith(color: AppColors.teal) : AppUI.cell)),
          ]),
        );

    // scrolling (right) part of one row
    Widget amountRow(_VRow r) => Container(
          height: _rowH,
          decoration: _rowDeco(r.kind),
          child: Row(children: [
            for (final c in cols)
              () {
                final cell = r.line?.cells[c.key];
                final tip = cell == null
                    ? null
                    : '${cell.differs ? 'Not the same in every section of ${c.label} -- the first section\'s amount is shown.\n' : ''}'
                        '${cell.n} students · ₹${formatIndianNumber(cell.total)}';
                return _cell(_amt(r, c), _wAmt,
                    right: true, tip: tip, style: cell != null && cell.differs ? AppUI.money.copyWith(color: AppColors.warning) : _moneyStyle(r.kind));
              }(),
            _cell(_rowTotal(r), _wTotal, right: true, style: AppUI.money.copyWith(fontWeight: FontWeight.w800)),
          ]),
        );

    const headDeco = BoxDecoration(color: AppColors.tableHeader, border: Border(bottom: BorderSide(color: AppColors.line)));
    const stuDeco = BoxDecoration(color: AppColors.sunken, border: Border(bottom: BorderSide(color: AppColors.lineStrong)));
    final totalStudents = cols.fold(0, (a, c) => a + c.students);

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
                child: Column(children: [
                  // header + students row: fixed part, then the amounts following the body sideways
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(
                      width: fixedW,
                      child: Column(children: [
                        Container(
                          height: _headH,
                          decoration: headDeco,
                          child: Row(children: [for (var i = 0; i < fw.length; i++) _cell(heads[i], fw[i], style: AppUI.tableHead)]),
                        ),
                        Container(
                          height: _stuH,
                          decoration: stuDeco,
                          child: Row(children: [_cell('STUDENTS', fixedW, style: AppUI.tableHead)]),
                        ),
                      ]),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _hHead,
                        scrollDirection: Axis.horizontal,
                        physics: const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: scrollW,
                          child: Column(children: [
                            Container(
                              height: _headH,
                              decoration: headDeco,
                              child: Row(children: [
                                for (final c in cols)
                                  _cell(c.label.toUpperCase(), _wAmt,
                                      right: true,
                                      style: AppUI.tableHead,
                                      tip: c.level == 'STANDARD' ? _sectionsTip(c.sections) : null),
                                _cell('TOTAL', _wTotal, right: true, style: AppUI.tableHead),
                              ]),
                            ),
                            Container(
                              height: _stuH,
                              decoration: stuDeco,
                              child: Row(children: [
                                for (final c in cols) _cell('${c.students}', _wAmt, right: true, style: AppUI.mono.copyWith(color: AppColors.ink2)),
                                _cell('$totalStudents', _wTotal, right: true, style: AppUI.mono.copyWith(fontWeight: FontWeight.w800)),
                              ]),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ]),
                  // body: one vertical scroll; the amounts also scroll sideways
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _vCtrl,
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(
                          width: fixedW,
                          child: Column(children: [for (final r in rows) fixedRow(r)]),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _hCtrl,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: scrollW,
                              child: Column(children: [for (final r in rows) amountRow(r)]),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
            AppScrollbarBar(controller: _vCtrl),
          ]),
        ),
        ClassicHScrollbar(controller: _hCtrl),
      ]),
    );
  }

  /// Tooltip of a standard-level column: the sections it covers.
  static String _sectionsTip(List<String> sections) => 'Sections: ${sections.join(', ')}';
}
