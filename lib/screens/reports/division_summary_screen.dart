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

/// FEE COLLECTION - DIVISION SUMMARY ON <date> -- the old product's
/// "FeeCollection - Division Summary" (PsFees, Division Summary.xlsx):
///
///   FEE TYPE | <division> CASH  BANK | <division> CASH  BANK | ... | TOTAL
///   Regular   fee types collected (fee receipts + each misc item), TOTAL
///   Arrear    fee types collected on arrear demands, TOTAL
///   Advance   advance receipts by fee type, TOTAL (switchable)
///   GRAND TOTAL
///
/// A division is the student's standard's division (Master Data -> Standard);
/// a standard with none counts under 'No Division'. Only divisions with money
/// in the range are shown. Server side: public.rpt_division_summary
/// (school_rpt_division_summary.sql) -- the Daily Collection receipt rules,
/// cancelled receipts out, bank receipts only once reconciled, and the part of
/// a receipt settled from an advance left out (it was counted when the
/// advance was taken).
class DivisionSummaryScreen extends StatefulWidget {
  const DivisionSummaryScreen({super.key});

  @override
  State<DivisionSummaryScreen> createState() => _DivisionSummaryScreenState();
}

/// One amount line of the RPC.
class _Line {
  final String section, ft, div;
  final double cash, bank;
  const _Line(this.section, this.ft, this.div, this.cash, this.bank);
}

enum _Kind { section, fee, total, grand }

/// One printed row: a section label, a fee type, a section TOTAL or the
/// GRAND TOTAL. [cells] holds (cash, bank) per shown division; a null entry
/// is a division with nothing on this fee type (printed blank, as the old).
class _Row {
  final _Kind kind;
  final String label;
  final List<(double, double)?> cells;
  const _Row(this.kind, this.label, this.cells);
  double get total => cells.fold(0.0, (t, c) => t + (c == null ? 0 : c.$1 + c.$2));
}

class _DivisionSummaryScreenState extends State<DivisionSummaryScreen> {
  static const _sections = [('REGULAR', 'Regular'), ('ARREAR', 'Arrear'), ('ADVANCE', 'Advance'), ('REFUND', 'Refund')];

  late DateTime _from, _to;
  bool _withAdvance = true;
  String _insName = '', _insAddress = '', _insCity = '';

  bool _loading = true, _running = false, _exporting = false;
  String? _error;
  List<String> _allDivs = []; // in the RPC's order
  List<_Line> _lines = [];
  int _pendingCount = 0;
  double _pendingAmount = 0;
  Map<String, int> _receipts = {};

  final ScrollController _hCtrl = ScrollController();
  final ScrollController _vCtrl = ScrollController();

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  static String _m(double v) => formatIndianNumber(v.abs() < 0.005 ? 0 : v);
  static String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = _to = DateTime(now.year, now.month, now.day);
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
      final info = await SupabaseService.getInstitutionInfo(_insId);
      if (!mounted) return;
      final parts = (info.address ?? '').replaceAll('\n', ', ').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      setState(() {
        _insName = info.name ?? '';
        if (parts.length > 1) _insCity = parts.removeLast();
        _insAddress = parts.join(', ');
        _loading = false;
        _error = null;
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

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final res = await SupabaseService.client.rpc('rpt_division_summary', params: {
        'p_token': SupabaseService.sessionToken,
        'p_from': _ymd(_from),
        'p_to': _ymd(_to),
      });
      final j = Map<String, dynamic>.from(res as Map);
      final pending = Map<String, dynamic>.from((j['pending'] as Map?) ?? const {});
      final rec = Map<String, dynamic>.from((j['receipts'] as Map?) ?? const {});
      if (!mounted) return;
      setState(() {
        _allDivs = [for (final d in (j['divisions'] as List? ?? const [])) '${(d as Map)['name']}'];
        _lines = [
          for (final x in (j['lines'] as List? ?? const []))
            _Line('${(x as Map)['section']}', '${x['ft']}', '${x['div']}', _num(x['cash']), _num(x['bank'])),
        ];
        _pendingCount = _num(pending['count']).toInt();
        _pendingAmount = _num(pending['amount']);
        _receipts = {for (final e in rec.entries) e.key: _num(e.value).toInt()};
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

  // ── the statement ────────────────────────────────────────────────────────
  List<_Line> get _shownLines => [for (final l in _lines) if (_withAdvance || l.section != 'ADVANCE') l];

  /// Divisions with any money among the shown lines, in the RPC's order.
  List<String> get _divs {
    final has = <String>{for (final l in _shownLines) if (l.cash.abs() > 0.005 || l.bank.abs() > 0.005) l.div};
    return [for (final d in _allDivs) if (has.contains(d)) d];
  }

  /// The printed rows, old layout: per section a label row, one row per fee
  /// type (alphabetical, as the old report), a TOTAL row; then GRAND TOTAL.
  List<_Row> _build(List<String> divs) {
    final rows = <_Row>[];
    final grand = List<(double, double)>.filled(divs.length, (0, 0));
    for (final s in _sections) {
      final lines = [for (final l in _shownLines) if (l.section == s.$1) l];
      if (lines.isEmpty) continue;
      final fts = <String, String>{}; // upper -> shown name
      for (final l in lines) {
        fts.putIfAbsent(l.ft.toUpperCase(), () => l.ft);
      }
      final keys = fts.keys.toList()..sort();
      rows.add(_Row(_Kind.section, s.$2, const []));
      final sub = List<(double, double)>.filled(divs.length, (0, 0));
      for (final k in keys) {
        final cells = List<(double, double)?>.filled(divs.length, null);
        for (final l in lines) {
          if (l.ft.toUpperCase() != k) continue;
          final i = divs.indexOf(l.div);
          if (i < 0) continue;
          final c = cells[i] ?? (0.0, 0.0);
          cells[i] = (c.$1 + l.cash, c.$2 + l.bank);
        }
        if (cells.every((c) => c == null)) continue;
        for (var i = 0; i < divs.length; i++) {
          final c = cells[i];
          if (c == null) continue;
          sub[i] = (sub[i].$1 + c.$1, sub[i].$2 + c.$2);
          grand[i] = (grand[i].$1 + c.$1, grand[i].$2 + c.$2);
        }
        rows.add(_Row(_Kind.fee, fts[k]!, cells));
      }
      rows.add(_Row(_Kind.total, 'TOTAL', sub));
    }
    if (rows.isNotEmpty) rows.add(_Row(_Kind.grand, 'GRAND TOTAL', grand));
    return rows;
  }

  bool get _oneDay => _from.year == _to.year && _from.month == _to.month && _from.day == _to.day;

  /// The old title: "FeeCollection - Division Summary On 11/06/2026".
  String get _title => _oneDay
      ? 'Fee Collection - Division Summary On ${formatDmy(_from)}'
      : 'Fee Collection - Division Summary From ${formatDmy(_from)} To ${formatDmy(_to)}';

  String get _fileStem => _oneDay
      ? 'Division_Summary_${formatDmy(_from)}'
      : 'Division_Summary_${formatDmy(_from)}_to_${formatDmy(_to)}';

  String? get _note {
    final parts = <String>[
      if (!_withAdvance) 'Advance receipts not included',
      if (_pendingCount > 0)
        '₹${_m(_pendingAmount)} in $_pendingCount bank receipt${_pendingCount == 1 ? '' : 's'} awaiting reconciliation not included',
    ];
    return parts.isEmpty ? null : 'Note : ${parts.join('; ')}';
  }

  // ── export ───────────────────────────────────────────────────────────────
  String _cellText((double, double)? c, bool cash, _Kind k) {
    if (k == _Kind.section) return '';
    if (c == null) return k == _Kind.fee ? '' : '0';
    return _m(cash ? c.$1 : c.$2);
  }

  Future<void> _exportPdf() async {
    final divs = _divs;
    final rows = _build(divs);
    if (rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final ok = await saveReportPdf(
        context,
        fileName: _fileStem,
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: _title,
        subtitle: '',
        headers: ['FEE TYPE', for (final d in divs) ...['${d.toUpperCase()}\nCASH', '${d.toUpperCase()}\nBANK'], 'TOTAL'],
        rows: [
          for (final r in rows)
            [
              r.kind == _Kind.section ? r.label.toUpperCase() : r.label,
              for (var i = 0; i < divs.length; i++) ...[
                _cellText(r.kind == _Kind.section ? null : r.cells[i], true, r.kind),
                _cellText(r.kind == _Kind.section ? null : r.cells[i], false, r.kind),
              ],
              r.kind == _Kind.section ? '' : _m(r.total),
            ],
        ],
        rightAlign: {for (var i = 1; i <= divs.length * 2 + 1; i++) i},
        landscape: divs.length > 2,
        footNote: _note,
      );
      if (ok) _snack('Division summary PDF saved.', AppColors.success);
    } catch (e) {
      _snack('Could not build the PDF. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportExcel() async {
    final divs = _divs;
    final rows = _build(divs);
    if (rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final path = await pickSavePath(
        dialogTitle: 'Save Division Summary',
        fileName: '$_fileStem.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      final book = xl.Excel.createExcel();
      final sheet = book['Division Summary'];
      book.delete('Sheet1');
      final lastCol = divs.length * 2 + 1; // FEE TYPE, CASH/BANK per division, TOTAL
      final center = xl.CellStyle(bold: true, fontSize: 11, horizontalAlign: xl.HorizontalAlign.Center);
      final plainCenter = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Center);
      final hdr = xl.CellStyle(
        bold: true,
        fontSize: 10,
        horizontalAlign: xl.HorizontalAlign.Center,
        verticalAlign: xl.VerticalAlign.Center,
        backgroundColorHex: XlTheme.headerBg, fontColorHex: XlTheme.headerFg,
      );
      final bold = xl.CellStyle(bold: true, fontSize: 10);
      final boldNum = xl.CellStyle(bold: true, fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      final plainNum = xl.CellStyle(fontSize: 10, horizontalAlign: xl.HorizontalAlign.Right);
      xl.CellIndex at(int c, int r) => xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r);
      void text(int c, int r, String v, [xl.CellStyle? st]) {
        final cell = sheet.cell(at(c, r));
        cell.value = xl.TextCellValue(v);
        if (st != null) cell.cellStyle = st;
      }

      void amount(int c, int r, double v, xl.CellStyle st) {
        final cell = sheet.cell(at(c, r));
        cell.value = xl.DoubleCellValue(double.parse(v.toStringAsFixed(2)));
        cell.cellStyle = st;
      }

      // title block, centred over the table (old: rows 1-4)
      void titleRow(int r, String v, xl.CellStyle st) {
        text(0, r, v, st);
        if (lastCol > 0) sheet.merge(at(0, r), at(lastCol, r), customValue: xl.TextCellValue(v));
      }

      titleRow(0, _insName.toUpperCase(), center);
      if (_insAddress.isNotEmpty) titleRow(1, _insAddress.toUpperCase(), plainCenter);
      if (_insCity.isNotEmpty) titleRow(2, _insCity.toUpperCase(), plainCenter);
      titleRow(3, _title, center);

      // two header rows: division over CASH | BANK; FEE TYPE and TOTAL span both
      const h = 6;
      text(0, h, 'FEE TYPE', hdr);
      text(0, h + 1, '', hdr);
      sheet.merge(at(0, h), at(0, h + 1), customValue: xl.TextCellValue('FEE TYPE'));
      for (var i = 0; i < divs.length; i++) {
        final c = 1 + i * 2;
        text(c, h, divs[i].toUpperCase(), hdr);
        text(c + 1, h, '', hdr);
        sheet.merge(at(c, h), at(c + 1, h), customValue: xl.TextCellValue(divs[i].toUpperCase()));
        text(c, h + 1, 'CASH', hdr);
        text(c + 1, h + 1, 'BANK', hdr);
        sheet.setColumnWidth(c, 14);
        sheet.setColumnWidth(c + 1, 14);
      }
      text(lastCol, h, 'TOTAL', hdr);
      text(lastCol, h + 1, '', hdr);
      sheet.merge(at(lastCol, h), at(lastCol, h + 1), customValue: xl.TextCellValue('TOTAL'));
      sheet.setColumnWidth(0, 32);
      sheet.setColumnWidth(lastCol, 16);

      var r = h + 2;
      for (final row in rows) {
        final isTotal = row.kind == _Kind.total || row.kind == _Kind.grand;
        text(0, r, row.label, row.kind == _Kind.fee ? null : bold);
        if (row.kind != _Kind.section) {
          for (var i = 0; i < divs.length; i++) {
            final c = row.cells[i];
            // the old sheet: a division with nothing on a fee type is blank,
            // a TOTAL row always prints its 0s
            if (c == null && !isTotal) continue;
            amount(1 + i * 2, r, c?.$1 ?? 0, isTotal ? boldNum : plainNum);
            amount(2 + i * 2, r, c?.$2 ?? 0, isTotal ? boldNum : plainNum);
          }
          amount(lastCol, r, row.total, isTotal ? boldNum : plainNum);
        }
        r++;
      }
      final note = _note;
      if (note != null) text(0, r + 1, note);

      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack('Division summary saved.', AppColors.success);
    } catch (e) {
      _snack('Could not build the Excel file. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  Widget _dateField(String label, DateTime value, ValueChanged<DateTime> onPick) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppUI.fieldLabel(label),
          InkWell(
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            onTap: _running
                ? null
                : () async {
                    final p = await showDatePicker(
                      context: context,
                      initialDate: value,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(DateTime.now().year + 5),
                    );
                    if (p != null) onPick(p);
                  },
            child: InputDecorator(
              decoration: AppUI.field(context, '', filled: true, leadingIcon: 'calendar-1'),
              child: Text(formatDmy(value), style: AppUI.fieldText(context, filled: true)),
            ),
          ),
        ],
      );

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
    final divs = _divs;
    final rows = _build(divs);
    final grand = rows.isEmpty ? null : rows.last;
    double cash = 0, bank = 0;
    for (final c in grand?.cells ?? const <(double, double)?>[]) {
      cash += c?.$1 ?? 0;
      bank += c?.$2 ?? 0;
    }
    final receipts = (_receipts['fee'] ?? 0) + (_receipts['misc'] ?? 0) + (_withAdvance ? (_receipts['advance'] ?? 0) : 0);
    final note = _note;

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'chart-2',
          title: 'Division Summary',
          subtitle: 'Fee collection by fee type and division, cash and bank',
          trailing: [
            OutlinedButton.icon(
              onPressed: _exporting || rows.isEmpty ? null : _exportExcel,
              icon: const Icon(Icons.table_chart_outlined, size: 16),
              label: const Text(AppText.exportExcel),
            ),
            OutlinedButton.icon(
              onPressed: _exporting || rows.isEmpty ? null : _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: const Text(AppText.exportPdf),
            ),
          ],
        ),
        SizedBox(height: 16.h),
        // filters
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          SizedBox(
            width: 190.w,
            child: _dateField('From', _from, (d) {
              setState(() {
                _from = d;
                if (_to.isBefore(d)) _to = d;
              });
              _run();
            }),
          ),
          SizedBox(width: 10.w),
          SizedBox(
            width: 190.w,
            child: _dateField('To', _to, (d) {
              setState(() {
                _to = d;
                if (_from.isAfter(d)) _from = d;
              });
              _run();
            }),
          ),
          SizedBox(width: 20.w),
          Padding(
            padding: EdgeInsets.only(bottom: 4.h),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(
                value: _withAdvance,
                activeThumbColor: AppColors.onPrimary,
                activeTrackColor: AppColors.primary,
                onChanged: (v) => setState(() => _withAdvance = v),
              ),
              SizedBox(width: 6.w),
              Text('Include Advance Receipts', style: AppUI.label),
            ]),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _running ? null : _run,
            icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
          ),
        ]),
        SizedBox(height: 16.h),
        // KPI tiles
        Row(children: [
          Expanded(child: AppUI.kpi(icon: 'money-recive', label: 'Cash', value: '₹${_m(cash)}', tint: AppColors.success)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'bank', label: 'Bank', value: '₹${_m(bank)}', tint: AppColors.demand)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'wallet-money', label: 'Grand Total', value: '₹${_m(cash + bank)}')),
          SizedBox(width: 12.w),
          Expanded(
            child: AppUI.kpi(
              icon: 'receipt-2',
              label: 'Receipts',
              value: '$receipts',
              sub: '${divs.length} division${divs.length == 1 ? '' : 's'}',
              tint: AppColors.warning,
            ),
          ),
        ]),
        SizedBox(height: 16.h),
        Expanded(child: _table(divs, rows)),
        SizedBox(height: 10.h),
        Text(
          rows.isEmpty ? '' : '$_title${note == null ? '' : ' · ${note.replaceFirst('Note : ', '')}'}',
          style: AppUI.muted,
        ),
      ]),
    );
  }

  Widget _table(List<String> divs, List<_Row> rows) {
    if (_running && rows.isEmpty) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty) {
      return AppUI.empty(
        title: 'Nothing to show',
        why: _oneDay ? 'No fee collected on ${formatDmy(_from)}.' : 'No fee collected from ${formatDmy(_from)} to ${formatDmy(_to)}.',
        icon: 'chart-2',
      );
    }
    const feeW = 240.0, amtW = 120.0, totW = 130.0;
    final total = feeW + divs.length * amtW * 2 + totW + 32;

    Widget cell(String t, double width, {bool right = false, bool center = false, TextStyle? style}) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Text(
              t,
              textAlign: center ? TextAlign.center : (right ? TextAlign.right : TextAlign.left),
              overflow: TextOverflow.ellipsis,
              style: style ?? AppUI.cell,
            ),
          ),
        );

    Widget rowOf(_Row r) {
      final strong = r.kind == _Kind.total || r.kind == _Kind.grand;
      final money = strong ? AppUI.money.copyWith(fontWeight: FontWeight.w800) : AppUI.money;
      if (r.kind == _Kind.section) {
        return Container(
          color: AppColors.sunken,
          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 8.h),
          child: Row(children: [cell(r.label.toUpperCase(), feeW, style: AppUI.caps.copyWith(color: AppColors.primary))]),
        );
      }
      return Container(
        decoration: BoxDecoration(
          color: r.kind == _Kind.grand ? AppColors.primarySoft : (r.kind == _Kind.total ? AppColors.surface : null),
          border: const Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 10.h),
        child: Row(children: [
          cell(r.label, feeW, style: strong ? AppUI.label : AppUI.cell),
          for (var i = 0; i < divs.length; i++) ...[
            cell(r.cells[i] == null && !strong ? '' : _m(r.cells[i]?.$1 ?? 0), amtW, right: true, style: money),
            cell(r.cells[i] == null && !strong ? '' : _m(r.cells[i]?.$2 ?? 0), amtW, right: true, style: money),
          ],
          cell(_m(r.total), totW, right: true, style: money.copyWith(fontWeight: FontWeight.w800)),
        ]),
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
      child: Column(children: [
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: LayoutBuilder(builder: (context, c) {
                  final width = total < c.maxWidth ? c.maxWidth : total;
                  return SingleChildScrollView(
                    controller: _hCtrl,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: width,
                      child: Column(children: [
                        // two header rows: the division over its CASH | BANK
                        Container(
                          color: AppColors.tableHeadBg,
                          padding: EdgeInsets.fromLTRB(8.w, 10.h, 8.w, 8.h),
                          child: Column(children: [
                            Row(children: [
                              cell('FEE TYPE', feeW, style: AppUI.tableHead),
                              for (final d in divs)
                                SizedBox(
                                  width: amtW * 2,
                                  child: Container(
                                    padding: EdgeInsets.only(bottom: 4.h),
                                    margin: EdgeInsets.symmetric(horizontal: 8.w),
                                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.cardBorder))),
                                    child: Text(d.toUpperCase(), textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: AppUI.tableHead),
                                  ),
                                ),
                              cell('TOTAL', totW, right: true, style: AppUI.tableHead),
                            ]),
                            SizedBox(height: 6.h),
                            Row(children: [
                              cell('', feeW),
                              for (var i = 0; i < divs.length; i++) ...[
                                cell('CASH', amtW, right: true, style: AppUI.tableHead),
                                cell('BANK', amtW, right: true, style: AppUI.tableHead),
                              ],
                              cell('', totW),
                            ]),
                          ]),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: _vCtrl,
                            itemCount: rows.length,
                            itemBuilder: (_, i) => rowOf(rows[i]),
                          ),
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
