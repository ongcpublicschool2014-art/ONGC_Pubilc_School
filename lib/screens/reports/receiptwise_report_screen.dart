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
import '../../utils/formatters.dart';
import '../../utils/friendly_error.dart';
import '../../utils/report_pdf_export.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/classic_h_scrollbar.dart';

/// RECEIPTWISE REPORT -- the old product's "Daily Fee Collection"
/// (PsFees: Receiptwise Report), one row per receipt taken in the date range:
///
///   S. No. | Date | Receipt No. | Admission No. | Student Name | Section |
///   [Drawee Bank | Cheque / Ref. No. | Deposited In]  (With Bank Detail)
///   [Arrear Year]                                       (Arrear Year)
///   Payment Mode | Regular | Advance | Arrear | Miscellaneous | Fine |
///   Total | Remarks
///
/// with a TOTAL row under every date and a GRAND TOTAL at the end. As the old
/// report, an amount column whose total is nil is left out; Total always
/// shows. Cancelled receipts are listed at nil with the remark 'Cancelled'
/// (they leave a hole in the receipt series an auditor asks about); receipts
/// still waiting on the bank can be included on request.
///
/// Server side: public.rpt_receiptwise (school_rpt_receiptwise.sql).
class ReceiptwiseReportScreen extends StatefulWidget {
  const ReceiptwiseReportScreen({super.key});

  @override
  State<ReceiptwiseReportScreen> createState() => _ReceiptwiseReportScreenState();
}

/// One receipt.
class _Rec {
  final Map<String, dynamic> m;
  _Rec(this.m);

  static double _n(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  String s(String k) => '${m[k] ?? ''}'.trim();

  DateTime? get date => DateTime.tryParse(s('date'));
  String get status => s('status');
  bool get cancelled => status == 'CANCELLED';
  bool get pending => status == 'PENDING';
  double amt(String k) => _n(m[k]);
  double get total => amt('regular') + amt('advance') + amt('arrear') + amt('misc') + amt('fine');

  /// 'cash' as stored by some collection paths reads 'Cash'.
  String get mode {
    final v = s('mode');
    if (v.isEmpty || v != v.toLowerCase()) return v;
    return v.split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
  }
}

/// A line of the listing: a receipt (with its serial number) or a date's TOTAL.
class _Line {
  final _Rec? rec;
  final int sno;
  final DateTime? day;
  final List<_Rec> dayRecs;
  const _Line.rec(_Rec this.rec, this.sno)
      : day = null,
        dayRecs = const [];
  const _Line.total(this.day, this.dayRecs)
      : rec = null,
        sno = 0;
  bool get isTotal => rec == null;
}

/// A column: header, width, is-amount, value of a receipt, amount key.
class _Col {
  final String head;
  final double width;
  final String? amountKey; // regular / advance / arrear / misc / fine / total
  final String Function(_Rec r) text;
  const _Col(this.head, this.width, this.text, {this.amountKey});
  bool get isAmount => amountKey != null;
}

class _ReceiptwiseReportScreenState extends State<ReceiptwiseReportScreen> {
  static const _amountCols = [
    ('regular', 'REGULAR'),
    ('advance', 'ADVANCE'),
    ('arrear', 'ARREAR'),
    ('misc', 'MISCELLANEOUS'),
    ('fine', 'FINE'),
  ];

  late DateTime _from, _to;
  String? _user; // null = all users
  bool _bank = false, _arrYear = false, _showCancelled = true, _withPending = false;

  String _insName = '', _insAddress = '', _insCity = '';
  bool _loading = true, _running = false, _exporting = false;
  String? _error;
  List<_Rec> _all = [];
  List<String> _users = [];

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
    _from = DateTime(now.year, now.month, now.day);
    _to = _from;
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
      final res = await SupabaseService.client.rpc('rpt_receiptwise', params: {
        'p_token': SupabaseService.sessionToken,
        'p_from': _iso(_from),
        'p_to': _iso(_to),
        'p_user': _user,
      });
      final j = Map<String, dynamic>.from(res as Map);
      final rows = [for (final x in (j['rows'] as List? ?? const [])) _Rec(Map<String, dynamic>.from(x as Map))];
      if (!mounted) return;
      setState(() {
        _all = rows;
        _users = [for (final u in (j['users'] as List? ?? const [])) '$u'];
      });
    } catch (e) {
      if (mounted) _snack(AppText.couldNot('load the receiptwise report', friendlyError(e)), AppColors.error);
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

  // ── what is shown ────────────────────────────────────────────────────────
  List<_Rec> get _rows => [
        for (final r in _all)
          if ((_showCancelled || !r.cancelled) && (_withPending || !r.pending)) r,
      ];

  /// Receipts and, after each date, that date's TOTAL line.
  List<_Line> _lines(List<_Rec> rows) {
    final out = <_Line>[];
    var sno = 0;
    var i = 0;
    while (i < rows.length) {
      final day = rows[i].s('date');
      final group = <_Rec>[];
      while (i < rows.length && rows[i].s('date') == day) {
        group.add(rows[i]);
        out.add(_Line.rec(rows[i], ++sno));
        i++;
      }
      out.add(_Line.total(group.first.date, group));
    }
    return out;
  }

  double _sum(Iterable<_Rec> rs, String key) =>
      rs.fold(0.0, (t, r) => t + (key == 'total' ? r.total : r.amt(key)));

  List<_Col> _columns(List<_Rec> rows) => [
        _Col('DATE', 100, (r) => formatDmy(r.date)),
        _Col('RECEIPT NO.', 130, (r) => r.s('recno')),
        _Col('ADMISSION NO.', 130, (r) => r.s('admno')),
        _Col('STUDENT NAME', 220, (r) => r.s('name')),
        _Col(schoolTerm('CLASS'), 100, (r) => r.s('class')),
        if (_bank) ...[
          _Col('DRAWEE BANK', 170, (r) => r.s('drawee')),
          _Col('CHEQUE / REF. NO.', 140, (r) => r.s('refno')),
          _Col('DEPOSITED IN', 170, (r) => r.s('deposited')),
        ],
        if (_arrYear) _Col('ARREAR YEAR', 110, (r) => r.s('arryear')),
        _Col(AppText.paymentMode.toUpperCase(), 120, (r) => r.mode),
        // as the old report: an amount column with nothing in it is left out
        for (final (k, h) in _amountCols)
          if (_sum(rows, k).abs() >= 0.005) _Col(h, 120, (r) => _m(r.amt(k)), amountKey: k),
        _Col('TOTAL', 130, (r) => _m(r.total), amountKey: 'total'),
        _Col('REMARKS', 150, (r) => r.s('remarks')),
      ];

  String get _collectedBy => 'FEE COLLECTED BY : ${_user == null ? 'ALL USERS' : _user!.toUpperCase()}';
  String get _title => 'RECEIPTWISE REPORT FROM ${formatDmy(_from)} TO ${formatDmy(_to)}';
  String get _fileStem {
    String f(DateTime d) => formatDmy(d);
    final who = _user == null ? '' : '_${_user!.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}';
    return 'Receiptwise_Report_${f(_from)}${_from == _to ? '' : '_to_${f(_to)}'}$who';
  }

  // ── export ───────────────────────────────────────────────────────────────
  Future<void> _exportPdf() async {
    final rows = _rows;
    if (rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final cols = _columns(rows);
      String tot(Iterable<_Rec> rs, _Col c) => c.isAmount ? formatIndianNumber(_sum(rs, c.amountKey!)) : '';
      final ok = await saveReportPdf(
        context,
        fileName: _fileStem,
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: _title,
        subtitle: _collectedBy,
        headers: [AppText.serialNo.toUpperCase(), ...cols.map((c) => c.head)],
        rows: [
          for (final l in _lines(rows))
            l.isTotal
                ? ['', 'TOTAL', ...cols.skip(1).map((c) => tot(l.dayRecs, c))]
                : ['${l.sno}', ...cols.map((c) => c.text(l.rec!))],
          ['GRAND TOTAL', '', ...cols.skip(1).map((c) => tot(rows, c))],
        ],
        rightAlign: {for (var i = 0; i < cols.length; i++) if (cols[i].isAmount) i + 1},
        landscape: true,
        footNote: 'Receipts : ${rows.length}',
      );
      if (ok) _snack('Receiptwise report PDF saved.', AppColors.success);
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
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Receiptwise Report',
        fileName: '$_fileStem.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      final cols = _columns(rows);
      final book = xl.Excel.createExcel();
      final sheet = book['Receiptwise Report'];
      book.delete('Sheet1');
      final bold = xl.CellStyle(bold: true, fontSize: 11);
      final hdr = xl.CellStyle(bold: true, fontSize: 10, backgroundColorHex: xl.ExcelColor.fromHexString('#F2F4F7'));
      void put(int c, int r, String v, [xl.CellStyle? st, bool number = false]) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        final n = number ? double.tryParse(v.replaceAll(',', '')) : null;
        cell.value = n != null ? xl.DoubleCellValue(n) : xl.TextCellValue(v);
        if (st != null) cell.cellStyle = st;
      }

      // title block, as the old report: name / address / city / title, then
      // who collected and, above the optional columns, what switched them on
      put(1, 0, _insName.toUpperCase(), bold);
      if (_insAddress.isNotEmpty) put(1, 1, _insAddress.toUpperCase());
      if (_insCity.isNotEmpty) put(1, 2, _insCity.toUpperCase());
      put(1, 3, _title, bold);
      put(1, 6, _collectedBy, bold);
      for (var c = 0; c < cols.length; c++) {
        if (cols[c].head == 'DRAWEE BANK') put(c + 1, 7, 'With Bank Detail');
        if (cols[c].head == 'ARREAR YEAR') put(c + 1, 7, 'Arrear Year');
      }
      const h = 8;
      put(0, h, AppText.serialNo.toUpperCase(), hdr);
      sheet.setColumnWidth(0, 8);
      for (var c = 0; c < cols.length; c++) {
        put(c + 1, h, cols[c].head, hdr);
        sheet.setColumnWidth(c + 1, cols[c].width / 7.5);
      }
      var r = h + 1;
      void totals(String label, int labelCol, Iterable<_Rec> rs) {
        put(labelCol, r, label, bold);
        for (var c = 0; c < cols.length; c++) {
          if (cols[c].isAmount) put(c + 1, r, '${_sum(rs, cols[c].amountKey!)}', bold, true);
        }
        r++;
      }

      for (final l in _lines(rows)) {
        if (l.isTotal) {
          totals('TOTAL', 1, l.dayRecs);
          continue;
        }
        put(0, r, '${l.sno}');
        for (var c = 0; c < cols.length; c++) {
          final col = cols[c];
          // amounts go in as numbers; a nil amount stays blank, as the old sheet
          final v = col.isAmount
              ? (col.amountKey == 'total' ? l.rec!.total : l.rec!.amt(col.amountKey!))
              : null;
          if (v != null) {
            if (v.abs() >= 0.005) put(c + 1, r, '$v', null, true);
          } else {
            put(c + 1, r, col.text(l.rec!));
          }
        }
        r++;
      }
      totals('GRAND TOTAL', 0, rows);
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack('Receiptwise report saved -- ${rows.length} receipts.', AppColors.success);
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

  Widget _userField() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppUI.fieldLabel('Fee Collected By'),
          DropdownButtonFormField<String?>(
            key: ValueKey('user-$_user-${_users.length}'),
            initialValue: _user,
            isExpanded: true,
            dropdownColor: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            style: AppUI.fieldText(context, filled: _user != null),
            decoration: AppUI.field(context, 'All users', filled: _user != null, leadingIcon: 'user'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All Users', overflow: TextOverflow.ellipsis)),
              for (final u in {..._users, if (_user != null) _user!}) DropdownMenuItem<String?>(value: u, child: Text(u, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: _running
                ? null
                : (v) {
                    setState(() => _user = v);
                    _run();
                  },
          ),
        ],
      );

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) => InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: EdgeInsets.only(right: 14.w),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(
              value: value,
              activeColor: AppColors.primary,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => onChanged(v ?? false),
            ),
            Text(label, style: AppUI.body),
          ]),
        ),
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
    final cols = _columns(rows);
    final cancelled = rows.where((r) => r.cancelled).length;
    final pending = rows.where((r) => r.pending).length;
    final other = [
      if (_sum(rows, 'advance') > 0) 'Advance ₹${formatIndianNumber(_sum(rows, 'advance'))}',
      if (_sum(rows, 'misc') > 0) 'Miscellaneous ₹${formatIndianNumber(_sum(rows, 'misc'))}',
      if (_sum(rows, 'fine') > 0) 'Fine ₹${formatIndianNumber(_sum(rows, 'fine'))}',
    ];

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'receipt-2',
          title: 'Receiptwise Report',
          subtitle: 'Every receipt taken between two dates, with a total for each day',
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
          Expanded(flex: 3, child: _userField()),
          SizedBox(width: 10.w),
          OutlinedButton.icon(
            onPressed: _running ? null : _run,
            icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
          ),
        ]),
        SizedBox(height: 8.h),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          _toggle('With Bank Detail', _bank, (v) => setState(() => _bank = v)),
          _toggle('Arrear Year', _arrYear, (v) => setState(() => _arrYear = v)),
          _toggle('Show Cancelled Receipts', _showCancelled, (v) => setState(() => _showCancelled = v)),
          _toggle('Include Receipts Not Yet Reconciled', _withPending, (v) => setState(() => _withPending = v)),
        ]),
        SizedBox(height: 12.h),
        // KPI tiles
        Row(children: [
          Expanded(
            child: AppUI.kpi(
              icon: 'receipt-2',
              label: 'Receipts',
              value: '${rows.length}',
              sub: [
                if (cancelled > 0) '$cancelled cancelled',
                if (pending > 0) '$pending not yet reconciled',
              ].join(' · '),
            ),
          ),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'money-recive', label: 'Regular', value: '₹${formatIndianNumber(_sum(rows, 'regular'))}', tint: AppColors.info)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'calendar-1', label: 'Arrear', value: '₹${formatIndianNumber(_sum(rows, 'arrear'))}', tint: AppColors.warning)),
          SizedBox(width: 12.w),
          Expanded(
            child: AppUI.kpi(
              icon: 'wallet-money',
              label: 'Total Collected',
              value: '₹${formatIndianNumber(_sum(rows, 'total'))}',
              sub: other.isEmpty ? null : other.join(' · '),
              tint: AppColors.success,
            ),
          ),
        ]),
        SizedBox(height: 16.h),
        Expanded(child: _table(rows, cols)),
        SizedBox(height: 10.h),
        Text(
          rows.isEmpty ? '' : '${AppUI.showing(1, rows.length, rows.length)} receipts · ${_collectedBy.toLowerCase().replaceFirst('fee collected by : ', 'collected by ')}',
          style: AppUI.muted,
        ),
      ]),
    );
  }

  Widget _table(List<_Rec> rows, List<_Col> cols) {
    if (_running && rows.isEmpty) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty) {
      return AppUI.empty(
        title: 'Nothing to show',
        why: _user == null
            ? 'No receipts were taken between ${formatDmy(_from)} and ${formatDmy(_to)}.'
            : 'No receipts were taken by $_user between ${formatDmy(_from)} and ${formatDmy(_to)}.',
        icon: 'receipt-2',
      );
    }
    final lines = _lines(rows);
    final widths = [64.0, for (final c in cols) c.width];
    final total = widths.fold(0.0, (a, b) => a + b) + 32;
    final totalStyle = AppUI.money.copyWith(fontWeight: FontWeight.w800);
    Widget cell(String t, double width, {bool right = false, TextStyle? style}) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Text(t, textAlign: right ? TextAlign.right : TextAlign.left, overflow: TextOverflow.ellipsis, style: style ?? AppUI.cell),
          ),
        );
    Widget rowCell(_Rec r, _Col c, double width) {
      if (c.head == 'ADMISSION NO.' && r.s('admno').isNotEmpty) {
        return SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Align(alignment: Alignment.centerLeft, child: AppUI.admTag(r.s('admno'), size: 12)),
          ),
        );
      }
      if (c.head == 'REMARKS' && (r.cancelled || r.pending)) {
        return SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AppUI.chip(r.s('remarks'), r.cancelled ? AppStatus.danger : AppStatus.warning),
            ),
          ),
        );
      }
      final dim = r.cancelled ? AppUI.cell.copyWith(color: AppColors.textLight) : null;
      return cell(c.text(r), width, right: c.isAmount, style: c.isAmount ? AppUI.money : dim);
    }

    Widget totalsRow(String label, Iterable<_Rec> rs, {bool grand = false}) => Row(children: [
          cell(grand ? label : '', widths[0], style: totalStyle),
          for (var i = 0; i < cols.length; i++)
            cell(
              i == 0 && !grand ? label : (cols[i].isAmount ? formatIndianNumber(_sum(rs, cols[i].amountKey!)) : ''),
              widths[i + 1],
              right: cols[i].isAmount,
              style: totalStyle,
            ),
        ]);

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
                            cell(AppText.serialNo.toUpperCase(), widths[0], style: AppUI.tableHead),
                            for (var i = 0; i < cols.length; i++) cell(cols[i].head, widths[i + 1], right: cols[i].isAmount, style: AppUI.tableHead),
                          ]),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: _vCtrl,
                            itemCount: lines.length,
                            itemBuilder: (_, i) {
                              final l = lines[i];
                              if (l.isTotal) {
                                return Container(
                                  decoration: const BoxDecoration(
                                    color: AppColors.surface,
                                    border: Border(bottom: BorderSide(color: AppColors.border)),
                                  ),
                                  padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 10.h),
                                  child: totalsRow('TOTAL', l.dayRecs),
                                );
                              }
                              final r = l.rec!;
                              return Container(
                                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
                                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 8.h),
                                child: Row(children: [
                                  cell('${l.sno}', widths[0], style: AppUI.muted),
                                  for (var k = 0; k < cols.length; k++) rowCell(r, cols[k], widths[k + 1]),
                                ]),
                              );
                            },
                          ),
                        ),
                        // grand total
                        Container(
                          decoration: const BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
                          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 12.h),
                          child: totalsRow('GRAND TOTAL', rows, grand: true),
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
