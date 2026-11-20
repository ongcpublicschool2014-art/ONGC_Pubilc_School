import 'dart:math' as math;
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
import '../../utils/excel_theme.dart';
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/report_pdf_export.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../utils/save_path.dart';

/// DATEWISE ABSTRACT REPORT -- the old product's (PsFees) day-by-day abstract
/// of the receipts taken between two dates: one row per (date, receipt
/// prefix) with the first and last receipt number of that prefix that day.
///
///   Detailed: S. No. | Date | Prefix | Start No. | End No. |
///             <collection kind> > <fee type short name> > Cash / Bank / UPI |
///             Total
///   Summary:  Date | Fee Prefix | Start No. | End No. | Regular Fee |
///             Advance Fee | Arrear Fee | Miscellaneous Fee | Total
///
/// with a GRAND TOTAL at the end. A fine goes with the kind it was charged on
/// (under its own FINE fee column in the detailed layout). On screen and in
/// the PDF the detailed layout shows only the fee type / mode columns that
/// have money; the Excel sheet keeps the old layout, each fee type spanning
/// Cash, Bank and UPI.
///
/// Receipts counted, and how their money is split, are those of the
/// Receiptwise Report, so the grand totals agree. Server side:
/// public.rpt_datewise_abstract (school_rpt_datewise_abstract.sql).
class DatewiseAbstractScreen extends StatefulWidget {
  const DatewiseAbstractScreen({super.key});

  @override
  State<DatewiseAbstractScreen> createState() => _DatewiseAbstractScreenState();
}

double _n(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

/// One (date, prefix) row.
class _Row {
  final DateTime? date;
  final String prefix;
  final int? start, end;
  final int receipts, cancelled, pending;
  final double reg, adv, arr, misc;
  /// Refunds paid back that day (negative).
  final double ref;

  /// 'KIND|FEE|MODE' -> amount.
  final Map<String, double> cells;

  _Row(Map<String, dynamic> m)
      : date = DateTime.tryParse('${m['date'] ?? ''}'),
        prefix = '${m['prefix'] ?? ''}'.trim(),
        start = m['start'] == null ? null : _n(m['start']).round(),
        end = m['end'] == null ? null : _n(m['end']).round(),
        receipts = _n(m['receipts']).round(),
        cancelled = _n(m['cancelled']).round(),
        pending = _n(m['pending']).round(),
        reg = _n(m['reg']),
        adv = _n(m['adv']),
        arr = _n(m['arr']),
        misc = _n(m['misc']),
        ref = _n(m['ref']),
        cells = {
          for (final c in (m['cells'] as List? ?? const []))
            if (c is Map) '${c['k']}|${c['f']}|${c['m']}': _n(c['a']),
        };

  double get total => reg + adv + arr + misc + ref;
  double cell(String kind, String fee, String mode) => cells['$kind|$fee|$mode'] ?? 0;
  String get prefixLabel => prefix.isEmpty ? 'No Prefix' : prefix;
}

/// An amount column: a summary kind (key 'reg' ...), a detailed
/// (kind, fee, mode) cell, or the row total.
class _Col {
  final String head;
  final double Function(_Row r) value;
  // detailed only: the header levels above the mode
  final String kind, fee, mode;
  const _Col(this.head, this.value, {this.kind = '', this.fee = '', this.mode = ''});
}

class _DatewiseAbstractScreenState extends State<DatewiseAbstractScreen> {
  /// Collection kinds as the old detailed sheet lays them out: REGULAR first,
  /// ARREAR last.
  static const _kinds = [
    ('REG', 'REGULAR'),
    ('ADV', 'ADVANCE'),
    ('MISC', 'MISCELLANEOUS'),
    ('ARR', 'ARREAR'),
    ('REF', 'REFUND'),
  ];
  static const _modes = [('CASH', 'CASH'), ('BANK', 'BANK'), ('UPI', 'UPI')];

  late DateTime _from, _to;
  bool _summary = false, _withPending = false;

  String _insName = '', _insAddress = '', _insCity = '';
  bool _loading = true, _running = false, _exporting = false;
  String? _error;
  List<_Row> _rows = [];
  List<String> _fees = []; // fee type labels in order

  final ScrollController _hCtrl = ScrollController();
  final ScrollController _vCtrl = ScrollController();

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  static String _m(double v) => v.abs() < 0.005 ? '' : formatIndianNumber(v);
  static String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    _from = DateTime(now.year, now.month, 1);
    _loadInfo();
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    _vCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadInfo() async {
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
      final res = await SupabaseService.client.rpc('rpt_datewise_abstract', params: {
        'p_token': SupabaseService.sessionToken,
        'p_from': _iso(_from),
        'p_to': _iso(_to),
        'p_with_pending': _withPending,
      });
      final j = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      setState(() {
        _rows = [for (final x in (j['rows'] as List? ?? const [])) _Row(Map<String, dynamic>.from(x as Map))];
        _fees = [
          for (final f in (j['fees'] as List? ?? const []))
            if (f is Map) '${f['label'] ?? ''}',
        ];
      });
    } catch (e) {
      if (mounted) _snack(AppText.couldNot('load the datewise abstract report', friendlyError(e)), AppColors.error);
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

  // ── columns ──────────────────────────────────────────────────────────────
  double _sum(Iterable<_Row> rs, double Function(_Row r) f) => rs.fold(0.0, (t, r) => t + f(r));

  List<_Col> get _summaryCols => [
        _Col('REGULAR FEE', (r) => r.reg),
        _Col('ADVANCE FEE', (r) => r.adv),
        _Col('ARREAR FEE', (r) => r.arr),
        _Col('MISCELLANEOUS FEE', (r) => r.misc),
        if (_rows.any((r) => r.ref.abs() >= 0.005)) _Col('REFUND', (r) => r.ref),
      ];

  /// The detailed (kind, fee, mode) columns. [allModes]: every fee type with
  /// money in a kind spans Cash, Bank and UPI (the old sheet); otherwise only
  /// the columns that have money.
  List<_Col> _detailCols({bool allModes = false}) {
    final out = <_Col>[];
    for (final (k, kh) in _kinds) {
      for (final f in _fees) {
        final has = {
          for (final (md, _) in _modes)
            if (_sum(_rows, (r) => r.cell(k, f, md).abs()) >= 0.005) md,
        };
        if (has.isEmpty) continue;
        for (final (md, mh) in _modes) {
          if (allModes || has.contains(md)) out.add(_Col(mh, (r) => r.cell(k, f, md), kind: kh, fee: f, mode: mh));
        }
      }
    }
    return out;
  }

  List<_Col> _cols({bool allModes = false}) => _summary ? _summaryCols : _detailCols(allModes: allModes);

  // ── titles ───────────────────────────────────────────────────────────────
  String get _title => 'DATEWISE ABSTRACT REPORT FROM : ${formatDmy(_from)} TO : ${formatDmy(_to)}';
  String get _prefixLine => 'PREFIX : ${({for (final r in _rows) r.prefixLabel}.toList()..sort()).map((p) => "'$p'").join(',')}';
  List<String> get _notes => [
        'With Advance Fees',
        if (!_summary) 'With Arrear Fees',
        'With Misc. Fees',
        if (_withPending) 'With Receipts Not Yet Reconciled',
        if (_rows.any((r) => r.ref.abs() >= 0.005)) 'Less Refunds',
      ];
  String get _fileStem =>
      'Datewise_Abstract${_summary ? '_Summary' : ''}_${formatDmy(_from)}${_from == _to ? '' : '_to_${formatDmy(_to)}'}';
  String get _layoutName => _summary ? 'Datewise abstract summary' : 'Datewise abstract report';

  // ── export ───────────────────────────────────────────────────────────────
  Future<void> _exportPdf() async {
    final rows = _rows;
    if (rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final cols = _cols();
      final lead = [
        if (!_summary) AppText.serialNo.toUpperCase(),
        'DATE',
        _summary ? 'FEE PREFIX' : 'PREFIX',
        'START NO.',
        'END NO.',
      ];
      final ok = await saveReportPdf(
        context,
        fileName: _fileStem,
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: _summary ? '$_title (SUMMARY)' : _title,
        subtitle: _prefixLine,
        headers: [
          ...lead,
          for (final c in cols) _summary ? c.head : '${c.kind}\n${c.fee}\n${c.mode}',
          'TOTAL',
        ],
        rows: [
          for (var i = 0; i < rows.length; i++)
            [
              if (!_summary) '${i + 1}',
              formatDmy(rows[i].date),
              rows[i].prefixLabel,
              '${rows[i].start ?? ''}',
              '${rows[i].end ?? ''}',
              for (final c in cols) _m(c.value(rows[i])),
              _m(rows[i].total),
            ],
          [
            'GRAND TOTAL',
            for (var i = 1; i < lead.length; i++) '',
            for (final c in cols) formatIndianNumber(_sum(rows, c.value)),
            formatIndianNumber(_sum(rows, (r) => r.total)),
          ],
        ],
        rightAlign: {
          for (var i = lead.length - 2; i < lead.length + cols.length + 1; i++) i,
        },
        landscape: true,
        footNote: _notes.join('   ·   '),
      );
      if (ok) _snack('$_layoutName PDF saved.', AppColors.success);
    } catch (e) {
      _snack(AppText.couldNot('build the PDF', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportExcel() async {
    final rows = _rows;
    if (rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final path = await pickSavePath(
        dialogTitle: 'Save ${_summary ? 'Datewise Abstract Summary' : 'Datewise Abstract Report'}',
        fileName: '$_fileStem.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      final book = xl.Excel.createExcel();
      final sheet = book[_summary ? 'Datewise Abstract Summary' : 'Datewise Abstract'];
      book.delete('Sheet1');
      final bold = xl.CellStyle(bold: true, fontSize: 11);
      final hdr = xl.CellStyle(bold: true, fontSize: 10, backgroundColorHex: XlTheme.headerBg, fontColorHex: XlTheme.headerFg);
      final tot = xl.CellStyle(bold: true, fontSize: 10, backgroundColorHex: XlTheme.totalBg);
      void text(int c, int r, String v, [xl.CellStyle? st]) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        cell.value = xl.TextCellValue(v);
        if (st != null) cell.cellStyle = st;
      }

      void number(int c, int r, num? v, [xl.CellStyle? st, bool blankNil = true]) {
        if (v == null || (blankNil && v.abs() < 0.005)) {
          if (st != null) text(c, r, '', st);
          return;
        }
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        cell.value = v is int || v == v.roundToDouble() ? xl.IntCellValue(v.round()) : xl.DoubleCellValue(v.toDouble());
        if (st != null) cell.cellStyle = st;
      }

      // title block, as the old sheet: name / address / city in B1..B3, the
      // title in B4
      text(1, 0, _insName.toUpperCase(), bold);
      if (_insAddress.isNotEmpty) text(1, 1, _insAddress.toUpperCase());
      if (_insCity.isNotEmpty) text(1, 2, _insCity.toUpperCase());
      text(1, 3, _title, bold);

      var r = 0;
      if (_summary) {
        // A7: Date | Fee Prefix | Start No. | End No. | Reg | Adv | Arr | Misc | Total
        final cols = _summaryCols;
        const h = 6;
        final heads = ['DATE', 'FEE PREFIX', 'START NO.', 'END NO.', ...cols.map((c) => c.head), 'TOTAL'];
        for (var c = 0; c < heads.length; c++) {
          text(c, h, heads[c], hdr);
          sheet.setColumnWidth(c, c < 4 ? 13 : 16);
        }
        r = h + 1;
        for (final row in rows) {
          text(0, r, formatDmy(row.date));
          text(1, r, row.prefixLabel);
          number(2, r, row.start, null, false);
          number(3, r, row.end, null, false);
          for (var c = 0; c < cols.length; c++) {
            number(4 + c, r, cols[c].value(row));
          }
          number(4 + cols.length, r, row.total);
          r++;
        }
        text(0, r, 'GRAND TOTAL', tot);
        for (var c = 1; c < 4; c++) {
          text(c, r, '', tot);
        }
        for (var c = 0; c < cols.length; c++) {
          number(4 + c, r, _sum(rows, cols[c].value), tot, false);
        }
        number(4 + cols.length, r, _sum(rows, (x) => x.total), tot, false);
        r++;
      } else {
        // "Collection Mode : CASH BANK UPI" in R2 / X2 / AA2 / AD2, the
        // prefixes in B5, then three header rows from row 7: kind, fee type,
        // mode -- every fee type spans Cash, Bank and UPI
        text(17, 1, 'Collection Mode :', bold);
        text(23, 1, 'CASH', bold);
        text(26, 1, 'BANK', bold);
        text(29, 1, 'UPI', bold);
        text(1, 4, _prefixLine, bold);
        final cols = _detailCols(allModes: true);
        const h = 6;
        const lead = 5; // S. No. | Date | Prefix | Start No. | End No.
        final leadHeads = [AppText.serialNo.toUpperCase(), 'DATE', 'PREFIX', 'START NO.', 'END NO.'];
        for (var c = 0; c < lead; c++) {
          text(c, h, leadHeads[c], hdr);
          text(c, h + 1, '', hdr);
          text(c, h + 2, '', hdr);
        }
        for (var c = 0; c < cols.length; c++) {
          final first = c == 0 || cols[c - 1].kind != cols[c].kind || cols[c - 1].fee != cols[c].fee;
          text(lead + c, h, first ? cols[c].kind : '', hdr);
          text(lead + c, h + 1, first ? cols[c].fee : '', hdr);
          text(lead + c, h + 2, cols[c].mode, hdr);
          sheet.setColumnWidth(lead + c, 12);
        }
        text(lead + cols.length, h, 'TOTAL', hdr);
        text(lead + cols.length, h + 1, '', hdr);
        text(lead + cols.length, h + 2, '', hdr);
        sheet.setColumnWidth(0, 7);
        sheet.setColumnWidth(1, 12);
        sheet.setColumnWidth(2, 11);
        sheet.setColumnWidth(3, 10);
        sheet.setColumnWidth(4, 10);
        sheet.setColumnWidth(lead + cols.length, 14);
        r = h + 3;
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i];
          text(0, r, '${i + 1}');
          text(1, r, formatDmy(row.date));
          text(2, r, row.prefixLabel);
          number(3, r, row.start, null, false);
          number(4, r, row.end, null, false);
          for (var c = 0; c < cols.length; c++) {
            number(lead + c, r, cols[c].value(row));
          }
          number(lead + cols.length, r, row.total);
          r++;
        }
        text(0, r, 'GRAND TOTAL', tot);
        for (var c = 1; c < lead; c++) {
          text(c, r, '', tot);
        }
        for (var c = 0; c < cols.length; c++) {
          number(lead + c, r, _sum(rows, cols[c].value), tot);
        }
        number(lead + cols.length, r, _sum(rows, (x) => x.total), tot, false);
        r++;
      }
      for (final n in _notes) {
        text(0, r++, n);
      }
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack('$_layoutName saved -- ${rows.length} rows.', AppColors.success);
    } catch (e) {
      _snack(AppText.couldNot('build the Excel file', friendlyError(e)), AppColors.error);
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
        action: OutlinedButton.icon(onPressed: _loadInfo, icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
      );
    }
    final rows = _rows;
    final receipts = rows.fold(0, (t, r) => t + r.receipts);
    final cancelled = rows.fold(0, (t, r) => t + r.cancelled);
    final pending = rows.fold(0, (t, r) => t + r.pending);
    final adv = _sum(rows, (r) => r.adv), misc = _sum(rows, (r) => r.misc);

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'calendar-1',
          title: 'Datewise Abstract Report',
          subtitle: 'Each day\'s receipts by receipt prefix, with the first and last receipt number',
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
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            flex: 2,
            child: _dateField('From Date', _from, (d) {
              setState(() {
                _from = d;
                if (_to.isBefore(d)) _to = d;
              });
              _run();
            }),
          ),
          SizedBox(width: 10.w),
          Expanded(
            flex: 2,
            child: _dateField('To Date', _to, (d) {
              setState(() {
                _to = d;
                if (_from.isAfter(d)) _from = d;
              });
              _run();
            }),
          ),
          SizedBox(width: 10.w),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Detailed'), icon: Icon(Icons.view_column_outlined, size: 16)),
              ButtonSegment(value: true, label: Text('Summary'), icon: Icon(Icons.view_list_outlined, size: 16)),
            ],
            selected: {_summary},
            onSelectionChanged: (v) => setState(() => _summary = v.first),
          ),
          SizedBox(width: 10.w),
          OutlinedButton.icon(
            onPressed: _running ? null : _run,
            icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
          ),
          const Spacer(flex: 3),
        ]),
        SizedBox(height: 8.h),
        Row(children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            onTap: _running
                ? null
                : () {
                    setState(() => _withPending = !_withPending);
                    _run();
                  },
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(
                value: _withPending,
                activeColor: AppColors.primary,
                visualDensity: VisualDensity.compact,
                onChanged: _running
                    ? null
                    : (v) {
                        setState(() => _withPending = v ?? false);
                        _run();
                      },
              ),
              Text('Include Receipts Not Yet Reconciled', style: AppUI.body),
            ]),
          ),
        ]),
        SizedBox(height: 12.h),
        Row(children: [
          Expanded(
            child: AppUI.kpi(
              icon: 'receipt-2',
              label: 'Receipts',
              value: '$receipts',
              sub: [
                '${rows.length} date / prefix rows',
                if (cancelled > 0) '$cancelled cancelled',
                if (pending > 0) '$pending not yet reconciled',
              ].join(' · '),
            ),
          ),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'money-recive', label: 'Regular', value: '₹${formatIndianNumber(_sum(rows, (r) => r.reg))}', tint: AppColors.info)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'calendar-1', label: 'Arrear', value: '₹${formatIndianNumber(_sum(rows, (r) => r.arr))}', tint: AppColors.warning)),
          SizedBox(width: 12.w),
          Expanded(
            child: AppUI.kpi(
              icon: 'wallet-money',
              label: 'Total Collected',
              value: '₹${formatIndianNumber(_sum(rows, (r) => r.total))}',
              sub: adv <= 0 && misc <= 0
                  ? null
                  : [
                      if (adv > 0) 'Advance ₹${formatIndianNumber(adv)}',
                      if (misc > 0) 'Miscellaneous ₹${formatIndianNumber(misc)}',
                    ].join(' · '),
              tint: AppColors.success,
            ),
          ),
        ]),
        SizedBox(height: 16.h),
        Expanded(child: _table(rows)),
        SizedBox(height: 10.h),
        Text(
          rows.isEmpty ? '' : '${AppUI.showing(1, rows.length, rows.length)} date / prefix rows · ${_prefixLine.toLowerCase().replaceFirst('prefix : ', 'prefixes ')}',
          style: AppUI.muted,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ]),
    );
  }

  Widget _table(List<_Row> rows) {
    if (_running && rows.isEmpty) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty) {
      return AppUI.empty(
        title: 'Nothing to show',
        why: 'No receipts were taken between ${formatDmy(_from)} and ${formatDmy(_to)}.',
        icon: 'receipt-2',
      );
    }
    final cols = _cols();
    // Widths from the content: the date and the grand total (the widest
    // amount) must fit, so neither is cut to "...".
    final totalStyle = AppUI.money.copyWith(fontWeight: FontWeight.w800);
    double measure(String t, TextStyle st) {
      final tp = TextPainter(
        text: TextSpan(text: t, style: DefaultTextStyle.of(context).style.merge(st)),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final w = tp.width + 2 * 8.w + 6;
      tp.dispose();
      return w;
    }

    final grandAll = rows.fold(0.0, (t, r) => t + r.reg + r.adv + r.arr + r.misc);
    final moneyW = measure(formatIndianNumber(grandAll), totalStyle);
    final amountW = math.max(116.0, moneyW), totalW = math.max(130.0, moneyW);
    final lead = [
      if (!_summary) (AppText.serialNo.toUpperCase(), 60.0),
      ('DATE', math.max(104.0, measure('00-00-0000', AppUI.cell))),
      (_summary ? 'FEE PREFIX' : 'PREFIX', 110.0),
      ('START NO.', 90.0),
      ('END NO.', 90.0),
    ];
    final leadW = lead.fold(0.0, (t, l) => t + l.$2);
    final colW = _summary ? math.max(150.0, moneyW) : amountW;
    final total = leadW + cols.length * colW + totalW + 32;

    Widget cell(String t, double width, {bool right = false, TextStyle? style, bool center = false}) => SizedBox(
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

    // header: one row (summary) or kind / fee type / mode (detailed), the
    // spanning cells as wide as the columns under them
    Widget spanRow(String Function(_Col c) key) {
      final out = <Widget>[cell('', leadW)];
      var i = 0;
      while (i < cols.length) {
        var j = i;
        while (j < cols.length && key(cols[j]) == key(cols[i])) {
          j++;
        }
        out.add(Container(
          width: (j - i) * colW,
          decoration: const BoxDecoration(border: Border(left: BorderSide(color: AppColors.border))),
          child: cell(key(cols[i]).split('|').last, (j - i) * colW - 1, style: AppUI.tableHead, center: true),
        ));
        i = j;
      }
      out.add(cell('', totalW));
      return Row(children: out);
    }

    final header = Container(
      color: AppColors.tableHeadBg,
      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 10.h),
      child: Column(children: [
        if (!_summary) ...[
          spanRow((c) => c.kind),
          SizedBox(height: 6.h),
          spanRow((c) => '${c.kind}|${c.fee}'),
          SizedBox(height: 6.h),
        ],
        Row(children: [
          for (final l in lead) cell(l.$1, l.$2, style: AppUI.tableHead, right: l.$1.endsWith('NO.')),
          for (final c in cols) cell(c.head, colW, right: true, style: AppUI.tableHead),
          cell('TOTAL', totalW, right: true, style: AppUI.tableHead),
        ]),
      ]),
    );

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
                        header,
                        Expanded(
                          child: ListView.builder(
                            controller: _vCtrl,
                            itemCount: rows.length,
                            itemBuilder: (_, i) {
                              final r = rows[i];
                              // a new date starts under a slightly heavier rule
                              final newDay = i + 1 < rows.length && rows[i + 1].date != r.date;
                              return Container(
                                decoration: BoxDecoration(
                                  border: Border(bottom: BorderSide(color: newDay ? AppColors.border : AppColors.divider)),
                                ),
                                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 8.h),
                                child: Row(children: [
                                  if (!_summary) cell('${i + 1}', lead[0].$2, style: AppUI.muted),
                                  cell(i > 0 && rows[i - 1].date == r.date ? '' : formatDmy(r.date), lead[_summary ? 0 : 1].$2),
                                  cell(r.prefixLabel, lead[_summary ? 1 : 2].$2, style: AppUI.mono),
                                  cell('${r.start ?? ''}', lead[_summary ? 2 : 3].$2, right: true, style: AppUI.mono),
                                  cell('${r.end ?? ''}', lead[_summary ? 3 : 4].$2, right: true, style: AppUI.mono),
                                  for (final c in cols) cell(_m(c.value(r)), colW, right: true, style: AppUI.money),
                                  cell(_m(r.total), totalW, right: true, style: totalStyle),
                                ]),
                              );
                            },
                          ),
                        ),
                        Container(
                          decoration: const BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
                          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 12.h),
                          child: Row(children: [
                            cell('GRAND TOTAL', leadW, style: totalStyle),
                            for (final c in cols) cell(formatIndianNumber(_sum(rows, c.value)), colW, right: true, style: totalStyle),
                            cell(formatIndianNumber(_sum(rows, (r) => r.total)), totalW, right: true, style: totalStyle),
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
