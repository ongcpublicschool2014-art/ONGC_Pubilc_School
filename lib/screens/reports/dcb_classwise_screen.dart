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
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../utils/save_path.dart';

/// DCB -- CLASSWISE STATEMENT: demand, collection and balance per standard,
/// in the old product's two layouts (PsFees, DCB_ClassSummary):
///
///   Annual  "ANNUAL DCB - CLASSWISE STATEMENT <year>" -- the whole year:
///           strength | Budget Demand | Total Demand Generated | Concession |
///           Net Demand | Collection W/O TC | Excess Collection from Paid &
///           left | Previous Arrears Collected | Total Collection | Previous
///           Advance | Excess Adv. from Paid and left | Arrears Carried Over
///   Period  "DCB - CLASSWISE STATEMENT ..." with PERIOD : From TO To -- the
///           terms falling in the period, adding Addl. Demand, Advance
///           Collections for next Terms, Previous Advance for next Terms and
///           Advance Carried Over.
///
/// One row per standard, then 'Misc / Arr' (arrears of earlier years and
/// miscellaneous receipts), 'Refund', 'Year End TC' and 'Total', as the old
/// sheets. Every figure comes from public.rpt_dcb_classwise
/// (school_rpt_dcb_classwise.sql), which documents each column.
class DcbClasswiseScreen extends StatefulWidget {
  const DcbClasswiseScreen({super.key});

  @override
  State<DcbClasswiseScreen> createState() => _DcbClasswiseScreenState();
}

/// A column: [key] into a line's values, [head] the old sheet's heading.
class _Col {
  const _Col(this.key, this.head, {this.count = false});
  final String key;
  final String head;
  final bool count; // a head count, not an amount

  /// The heading as shown on screen and in the PDF (the old sheet has a
  /// stray double space in two of them; the Excel keeps it).
  String get label => head.replaceAll('  ', ' ');
}

enum _Kind { standard, extra, total }

/// A printed line. A key missing from [v] is a blank cell, as the old sheet
/// leaves the cells of its Misc / Refund lines empty.
class _Line {
  const _Line(this.kind, this.label, this.v);
  final _Kind kind;
  final String label;
  final Map<String, num> v;
}

class _DcbClasswiseScreenState extends State<DcbClasswiseScreen> {
  // The old sheets' columns, in order (headings verbatim).
  static const _annualCols = [
    _Col('prom', 'Prom. Strg', count: true),
    _Col('newadm', 'New Admn', count: true),
    _Col('tc', 'TC', count: true),
    _Col('curr', 'Curr Strg.', count: true),
    _Col('budget', 'Budget Demand'),
    _Col('gen', 'Total Demand Generated'),
    _Col('con', 'Concession'),
    _Col('net', 'Net Demand'),
    _Col('coll', 'Collection for Curr.Year W/O TC'),
    _Col('excess', 'Excess Collection from Paid & left'),
    _Col('prevarr', 'Previous Arrears Collected'),
    _Col('total', 'Total Collection'),
    _Col('prevadv', 'Previous Advance  Collection for Curr. Year'),
    _Col('excessadv', 'Excess Adv. from Paid and left'),
    _Col('arrears', 'Arrears Carried Over'),
  ];
  static const _periodCols = [
    _Col('prom', 'Prom. Strg', count: true),
    _Col('newadm', 'New Admn', count: true),
    _Col('tc', 'TC', count: true),
    _Col('curr', 'Curr Strg.', count: true),
    _Col('budget', 'Budget Demand'),
    _Col('gen', 'Total Demand Generated'),
    _Col('addl', 'Addl. Demand'),
    _Col('con', 'Concession'),
    _Col('net', 'Net Demand'),
    _Col('coll', 'Collection for Curr.Term W/O TC'),
    _Col('advnext', 'Advance Collections for next Terms'),
    _Col('excess', 'Excess Collection from Paid & left'),
    _Col('prevarr', 'Previous Arrears Collected'),
    _Col('total', 'Total Collection'),
    _Col('prevadv', 'Previous Advance  Collection for Curr. Term'),
    _Col('excessadv', 'Excess Adv. from Paid and left'),
    _Col('prevadvnext', 'Previous Advance for next Terms'),
    _Col('arrears', 'Arrears Carried Over'),
    _Col('advcarry', 'Advance Carried Over'),
  ];

  // filters
  bool _annual = true;
  late DateTime _from;
  late DateTime _to;
  late DateTime _yearFrom;
  late DateTime _yearTo;
  final Set<String> _fees = {};

  // masters
  List<(String, String)> _feeTypes = []; // (fee type, short name), in order
  String _insName = '', _insAddress = '', _insCity = '', _yearLabel = '';

  // result (of the last run; the layout follows the run, not the switch)
  bool _loading = true, _running = false, _exporting = false;
  String? _error;
  List<_Line> _lines = [];
  bool _ranAnnual = true;
  DateTime? _ranFrom, _ranTo;
  Set<String> _ranFees = {};
  double _pendingRecon = 0;
  int _awaitCount = 0;
  double _awaitAmount = 0;

  final ScrollController _hCtrl = ScrollController();

  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  static bool _zero(num v) => v.abs() < 0.005;

  @override
  void initState() {
    super.initState();
    // The academic year signed into, 1 April to 31 March, as the old sheet.
    final label = context.read<AuthProvider>().yearLabel ?? '';
    final start = int.tryParse(label.length >= 4 ? label.substring(0, 4) : '');
    final now = DateTime.now();
    final y = start ?? (now.month >= 4 ? now.year : now.year - 1);
    _yearLabel = label.isNotEmpty ? label : '$y-${y + 1}';
    _yearFrom = _from = DateTime(y, 4, 1);
    _yearTo = _to = DateTime(y + 1, 3, 31);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMasters());
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMasters() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final insId = context.read<AuthProvider>().insId ?? 1;
      final info = await SupabaseService.getInstitutionInfo(insId);
      if (!mounted) return;
      final parts =
          (info.address ?? '').replaceAll('\n', ', ').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      setState(() {
        _insName = info.name ?? '';
        if (parts.length > 1) _insCity = parts.removeLast();
        _insAddress = parts.join(', ');
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

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _slash(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<void> _run() async {
    final from = _annual ? _yearFrom : _from;
    final to = _annual ? _yearTo : _to;
    if (to.isBefore(from)) {
      _snack('The To date is before the From date. Select a To date on or after the From date.', AppColors.warning);
      return;
    }
    setState(() => _running = true);
    try {
      final res = await SupabaseService.client.rpc('rpt_dcb_classwise', params: {
        'p_token': SupabaseService.sessionToken,
        'p_from': _ymd(from),
        'p_to': _ymd(to),
        'p_annual': _annual,
        'p_fee_types': _fees.isEmpty ? null : _fees.toList(),
      });
      final j = Map<String, dynamic>.from(res as Map);
      final feeTypes = [
        for (final f in (j['feetypes'] as List? ?? const [])) ('${(f as Map)['ft']}', '${f['short'] ?? f['ft']}')
      ];
      final lines = _build(j, _annual);
      if (!mounted) return;
      setState(() {
        _feeTypes = feeTypes;
        _fees.removeWhere((f) => !feeTypes.any((t) => t.$1 == f));
        _lines = lines;
        _ranAnnual = _annual;
        _ranFrom = from;
        _ranTo = to;
        _ranFees = {..._fees};
        _pendingRecon = _num(j['pending_recon']);
        final aw = j['awaiting_approval'] is Map ? j['awaiting_approval'] as Map : const {};
        _awaitCount = _num(aw['count']).toInt();
        _awaitAmount = _num(aw['amount']);
        _error = null;
      });
    } catch (e) {
      if (mounted) _snack(AppText.couldNot('load the DCB statement', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// The standards, the old sheet's three extra lines and the Total.
  static List<_Line> _build(Map<String, dynamic> j, bool annual) {
    final lines = <_Line>[];
    for (final x in (j['rows'] as List? ?? const [])) {
      final r = x as Map;
      double f(String k) => _num(r[k]);
      final prom = f('prom').toInt(), adm = f('newadm').toInt(), tc = f('tc').toInt();
      final gen = f('gen'), addl = f('addl'), con = f('con');
      final coll = f('coll'), advnext = f('advnext'), excess = f('excess'), prevarr = f('prevarr');
      final prevadvnext = f('prevadvnext');
      lines.add(_Line(_Kind.standard, '${r['name'] ?? '-'}', {
        'prom': prom,
        'newadm': adm,
        'tc': tc,
        'curr': prom + adm - tc,
        'budget': f('budget'),
        // the annual sheet has no Addl. Demand column: all of it is generated
        'gen': annual ? gen + addl : gen,
        if (!annual) 'addl': addl,
        'con': con,
        'net': gen + addl - con,
        'coll': coll,
        if (!annual) 'advnext': advnext,
        'excess': excess,
        'prevarr': prevarr,
        'total': coll + excess + prevarr + (annual ? 0 : advnext),
        'prevadv': f('prevadv'),
        'excessadv': f('excessadv'),
        if (!annual) 'prevadvnext': prevadvnext,
        'arrears': f('arrears'),
        if (!annual) 'advcarry': advnext + prevadvnext,
      }));
    }

    final m = j['misc'] is Map ? j['misc'] as Map : const {};
    final misc = _num(m['misc']), arrcoll = _num(m['arrcoll']), madv = _num(m['prevadv']);
    lines.add(_Line(_Kind.extra, 'Misc / Arr', {
      'con': _num(m['con']),
      'coll': misc,
      'prevarr': arrcoll,
      'total': misc + arrcoll,
      if (!_zero(madv)) 'prevadv': madv,
      'arrears': _num(m['arrears']),
    }));

    // Refunds are money paid back: a negative collection.
    final rf = j['refund'] is Map ? j['refund'] as Map : const {};
    final onroll = _num(rf['onroll']), left = _num(rf['left']);
    lines.add(_Line(_Kind.extra, 'Refund', {
      'coll': -onroll,
      'excess': -left,
      'total': -(onroll + left),
    }));

    final ye = j['yearend_tc'] is Map ? j['yearend_tc'] as Map : const {};
    lines.add(_Line(_Kind.extra, 'Year End TC', {'excessadv': _num(ye['excessadv'])}));

    final keys = (annual ? _annualCols : _periodCols).map((c) => c.key);
    lines.add(_Line(_Kind.total, 'Total', {
      for (final k in keys) k: lines.fold<num>(0, (t, l) => t + (l.v[k] ?? 0)),
    }));
    return lines;
  }

  // ── wording ──────────────────────────────────────────────────────────────
  List<_Col> get _cols => _ranAnnual ? _annualCols : _periodCols;

  /// The whole default year: the old sheet calls that "FOR ALL TERM".
  bool get _wholeYear => _ranFrom == _yearFrom && _ranTo == _yearTo;

  String get _title => _ranAnnual
      ? 'ANNUAL DCB - CLASSWISE STATEMENT  $_yearLabel'
      : 'DCB - CLASSWISE STATEMENT${_wholeYear ? ' FOR ALL TERM' : ''}  $_yearLabel';

  String get _periodLine =>
      _ranFrom == null || _ranTo == null ? '' : 'PERIOD : ${_slash(_ranFrom!)} TO ${_slash(_ranTo!)}';

  String get _dateLine => 'DATE : ${_slash(DateTime.now())}';

  String get _feeLine {
    final names = _ranFees.isEmpty
        ? [for (final f in _feeTypes) f.$1]
        : [for (final f in _feeTypes) if (_ranFees.contains(f.$1)) f.$1];
    return 'FOR THE FEE TYPE : ${names.join(',')}';
  }

  String get _stdHead => schoolTerm('Course');

  String get _note {
    final parts = <String>[
      'Collections awaiting bank reconciliation are not counted'
          '${_zero(_pendingRecon) ? '' : ' (₹${formatIndianNumber(_pendingRecon)} in this period)'}.',
      if (_awaitCount > 0)
        '$_awaitCount staged ${_awaitCount == 1 ? 'demand' : 'demands'} of ₹${formatIndianNumber(_awaitAmount)} '
            'not approved yet: in the Budget, not yet in Total Demand Generated.',
    ];
    return parts.join(' ');
  }

  String get _fileStem {
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return _ranAnnual
        ? 'Annual_DCB_${safe(_yearLabel)}'
        : 'DCB_Class_Group_${safe(formatDmy(_ranFrom))}_${safe(formatDmy(_ranTo))}';
  }

  String _cell(_Line l, _Col c) {
    final v = l.v[c.key];
    if (v == null) return '';
    return c.count ? '${v.toInt()}' : formatIndianNumber(v);
  }

  // ── export ───────────────────────────────────────────────────────────────
  Future<void> _exportExcel() async {
    if (_lines.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final path = await pickSavePath(
        dialogTitle: 'Save DCB Statement',
        fileName: '$_fileStem.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      final book = xl.Excel.createExcel();
      final sheetName = _ranAnnual ? 'Annual DCB' : 'DCB Class Group';
      _writeSheet(book[sheetName]);
      book.delete('Sheet1');
      book.setDefaultSheet(sheetName);
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      final file = path.toLowerCase().endsWith('.xlsx') ? path : '$path.xlsx';
      await File(file).writeAsBytes(bytes);
      _snack('DCB statement saved.', AppColors.success);
    } catch (e) {
      _snack(AppText.couldNot('build the Excel file', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// The old sheet's layout: name, address and city in C1..C3, the title in
  /// C4, the period in C5 and the date in J5, the fee types in C7, the
  /// headings on row 8 and the lines from row 9.
  void _writeSheet(xl.Sheet sheet) {
    final cols = _cols;
    final bold = xl.CellStyle(bold: true, fontSize: 11);
    final hdr = xl.CellStyle(
      bold: true,
      fontSize: 10,
      textWrapping: xl.TextWrapping.WrapText,
      verticalAlign: xl.VerticalAlign.Center,
      backgroundColorHex: XlTheme.headerBg,
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
    );
    final numBold = xl.CellStyle(bold: true, fontSize: 10);

    xl.Data at(int c, int r) => sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
    void text(int c, int r, String v, [xl.CellStyle? st]) {
      final cell = at(c, r);
      cell.value = xl.TextCellValue(v);
      if (st != null) cell.cellStyle = st;
    }

    text(2, 0, _insName.toUpperCase(), bold);
    if (_insAddress.isNotEmpty) text(2, 1, _insAddress.toUpperCase(), bold);
    if (_insCity.isNotEmpty) text(2, 2, _insCity.toUpperCase(), bold);
    text(2, 3, _title, bold);
    if (!_ranAnnual) text(2, 4, _periodLine, bold);
    text(9, 4, _dateLine, bold);
    text(2, 6, _feeLine, bold);

    const h = 7;
    text(0, h, _stdHead, hdr);
    sheet.setColumnWidth(0, 14);
    for (var i = 0; i < cols.length; i++) {
      text(1 + i, h, cols[i].head, hdr);
      sheet.setColumnWidth(1 + i, cols[i].count ? 10 : 15);
    }

    var r = h + 1;
    for (final l in _lines) {
      final strong = l.kind == _Kind.total;
      text(0, r, l.label, strong ? bold : null);
      for (var i = 0; i < cols.length; i++) {
        final v = l.v[cols[i].key];
        if (v == null) continue;
        final cell = at(1 + i, r);
        final whole = (v - v.roundToDouble()).abs() < 0.005;
        cell.value = whole ? xl.IntCellValue(v.round()) : xl.DoubleCellValue(double.parse(v.toStringAsFixed(2)));
        if (strong) cell.cellStyle = numBold;
      }
      r++;
    }
    text(0, r + 1, 'Note : $_note');
  }

  Future<void> _exportPdf() async {
    if (_lines.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final cols = _cols;
      final ok = await saveReportPdf(
        context,
        fileName: _fileStem,
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: _title,
        subtitle: [if (!_ranAnnual) _periodLine, _feeLine].join('     '),
        headers: [_stdHead, ...cols.map((c) => c.label)],
        rows: [
          for (final l in _lines) [l.label, ...cols.map((c) => _cell(l, c))],
        ],
        rightAlign: {for (var i = 0; i < cols.length; i++) 1 + i},
        landscape: true,
        footNote: 'Note : $_note',
      );
      if (ok) _snack('DCB statement PDF saved.', AppColors.success);
    } catch (e) {
      _snack(AppText.couldNot('build the PDF', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── filters ──────────────────────────────────────────────────────────────
  Future<void> _pickFees() async {
    final draft = Set<String>.from(_fees);
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Row(children: [
            Expanded(child: Text('Select Fee Types', style: AppUI.cardTitle)),
            TextButton(
                onPressed: () => setLocal(() => draft.addAll(_feeTypes.map((f) => f.$1))),
                child: const Text('Select All')),
            TextButton(onPressed: () => setLocal(draft.clear), child: const Text(AppText.clear)),
          ]),
          content: SizedBox(
            width: 420.w,
            height: 420.h,
            child: _feeTypes.isEmpty
                ? AppUI.empty(title: 'Nothing to choose from', why: 'No fee types are set up yet.')
                : ListView(children: [
                    for (final f in _feeTypes)
                      CheckboxListTile(
                        value: draft.contains(f.$1),
                        onChanged: (v) => setLocal(() => v == true ? draft.add(f.$1) : draft.remove(f.$1)),
                        dense: true,
                        activeColor: AppColors.primary,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(f.$1, style: AppUI.body),
                      ),
                  ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text(AppText.cancel)),
            ElevatedButton(
              style: AppUI.primary(ctx),
              onPressed: () => Navigator.of(ctx).pop(draft),
              child: Text('Apply${draft.isEmpty ? '' : ' (${draft.length})'}'),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _fees
      ..clear()
      ..addAll(picked.length == _feeTypes.length ? const <String>{} : picked));
    _run();
  }

  String get _feeLabel =>
      _fees.isEmpty ? 'All Fee Types' : (_fees.length == 1 ? _fees.first : '${_fees.length} fee types selected');

  /// One half of the Annual / Period switch.
  Widget _seg(String label, bool on, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        onTap: _running ? null : onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: 16.w),
          decoration: BoxDecoration(
            color: on ? AppColors.primaryLight : AppColors.card,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: on ? AppColors.primary : AppColors.border),
          ),
          child: Text(label, style: AppUI.label.copyWith(color: on ? AppColors.primary : AppColors.textSecondary)),
        ),
      );

  Widget _dateField(String label, DateTime value, ValueChanged<DateTime>? onPick) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppUI.fieldLabel(label),
          InkWell(
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            onTap: onPick == null || _running
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
              decoration: AppUI.field(context, '').copyWith(
                suffixIcon: Icon(Icons.calendar_today_outlined, size: 15.sp, color: AppColors.textSecondary),
              ),
              child: Text(formatDmy(value),
                  style: AppUI.fieldText(context).copyWith(color: onPick == null ? AppColors.textLight : null)),
            ),
          ),
        ],
      );

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _lines.isEmpty) {
      return AppUI.empty(
        title: 'Could not open the report',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton.icon(
            onPressed: _loadMasters, icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
      );
    }
    final total = _lines.isNotEmpty && _lines.last.kind == _Kind.total ? _lines.last : null;
    num t(String k) => total?.v[k] ?? 0;

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'chart-2',
          title: 'DCB Statement',
          subtitle: schoolTerm('Demand, collection and balance per course, annual or for a period'),
          trailing: [
            OutlinedButton.icon(
              style: AppUI.secondary(context),
              onPressed: _exporting || _running || _lines.isEmpty ? null : _exportExcel,
              icon: const Icon(Icons.table_chart_outlined, size: 16),
              label: const Text(AppText.exportExcel),
            ),
            OutlinedButton.icon(
              style: AppUI.secondary(context),
              onPressed: _exporting || _running || _lines.isEmpty ? null : _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: const Text(AppText.exportPdf),
            ),
          ],
        ),
        SizedBox(height: 16.h),
        // filters
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            AppUI.fieldLabel('Statement'),
            Row(children: [
              _seg('Annual', _annual, () {
                if (_annual) return;
                setState(() => _annual = true);
                _run();
              }),
              SizedBox(width: 6.w),
              _seg('Period', !_annual, () {
                if (!_annual) return;
                setState(() => _annual = false);
                _run();
              }),
            ]),
          ]),
          SizedBox(width: 12.w),
          Expanded(
            flex: 2,
            child: _dateField(
                'From Date',
                _annual ? _yearFrom : _from,
                _annual
                    ? null
                    : (d) {
                        setState(() => _from = d);
                        _run();
                      }),
          ),
          SizedBox(width: 12.w),
          Expanded(
            flex: 2,
            child: _dateField(
                'To Date',
                _annual ? _yearTo : _to,
                _annual
                    ? null
                    : (d) {
                        setState(() => _to = d);
                        _run();
                      }),
          ),
          SizedBox(width: 12.w),
          Expanded(
            flex: 3,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              AppUI.fieldLabel('Fee Type'),
              InkWell(
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                onTap: _running ? null : _pickFees,
                child: InputDecorator(
                  decoration: AppUI.field(context, AppText.select('fee types'),
                      filled: _fees.isNotEmpty,
                      leadingIcon: 'receipt-discount',
                      suffix: Icon(Icons.arrow_drop_down, color: AppColors.ink3, size: 22.sp)),
                  child: Text(_feeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppUI.fieldText(context, filled: _fees.isNotEmpty)),
                ),
              ),
            ]),
          ),
          SizedBox(width: 12.w),
          SizedBox(
            height: AppUI.controlHeight(context),
            child: OutlinedButton.icon(
              style: AppUI.secondary(context),
              onPressed: _running ? null : _run,
              icon: _running
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
          ),
        ]),
        SizedBox(height: 16.h),
        Row(children: [
          Expanded(
              child: AppUI.kpi(
                  icon: 'people',
                  label: 'Current Strength',
                  value: '${t('curr').toInt()}',
                  sub: '${t('newadm').toInt()} new · ${t('tc').toInt()} TC')),
          SizedBox(width: 12.w),
          Expanded(
              child: AppUI.kpi(
                  icon: 'receipt-2',
                  label: 'Net Demand',
                  value: '₹${formatIndianNumber(t('net'))}',
                  tint: AppColors.demand)),
          SizedBox(width: 12.w),
          Expanded(
              child: AppUI.kpi(
                  icon: 'money-recive',
                  label: 'Total Collection',
                  value: '₹${formatIndianNumber(t('total'))}',
                  sub: 'Previous advance ₹${formatIndianNumber(t('prevadv'))}',
                  tint: AppColors.success)),
          SizedBox(width: 12.w),
          Expanded(
              child: AppUI.kpi(
                  icon: 'wallet-money',
                  label: 'Arrears Carried Over',
                  value: '₹${formatIndianNumber(t('arrears'))}',
                  tint: AppColors.warning)),
        ]),
        SizedBox(height: 12.h),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
          decoration: BoxDecoration(
            color: AppColors.infoBg,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.info.withValues(alpha: 0.25)),
          ),
          child: Row(children: [
            Icon(Icons.info_outline, size: 15.sp, color: AppColors.info),
            SizedBox(width: 8.w),
            Expanded(
              child: Text(
                schoolTerm('Students who took a TC are left out of the demand and the balance; what they paid shows '
                    'under Paid & left. Net Demand = Demand − Concession. Arrears Carried Over = Net Demand − '
                    'Collection − Previous Advance, plus any refund (a refund reopens the demand). '
                    '${_annual ? 'Annual takes the whole year.' : 'Period takes the terms falling between From and To; earlier terms count as arrears, later ones as advance.'}'),
                style: AppUI.muted.copyWith(color: AppColors.textSecondary, height: 1.35),
              ),
            ),
          ]),
        ),
        SizedBox(height: 12.h),
        Expanded(child: _table()),
        SizedBox(height: 8.h),
        Text(_lines.isEmpty ? '' : _note, style: AppUI.muted, maxLines: 2, overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  Widget _table() {
    if (_running && _lines.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_lines.isEmpty) {
      return AppUI.empty(
        title: 'Nothing to show yet',
        why: 'Select the statement and the dates above, then Refresh.',
        icon: 'chart-2',
      );
    }
    final cols = _cols;
    const wLabel = 130.0, wCount = 84.0, wAmt = 124.0;
    final width = wLabel + cols.fold<double>(0, (t, c) => t + (c.count ? wCount : wAmt)) + 32;
    final strongMoney = AppUI.money.copyWith(fontWeight: FontWeight.w800);

    Widget cell(String s, double w, {bool right = true, TextStyle? style}) => SizedBox(
          width: w,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 6.w),
            child: Text(s,
                textAlign: right ? TextAlign.right : TextAlign.left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style ?? AppUI.money),
          ),
        );

    Widget line(_Line l) {
      final std = l.kind == _Kind.standard;
      final tot = l.kind == _Kind.total;
      return Container(
        decoration: BoxDecoration(
          color: tot ? AppColors.tableHeadBg : (std ? AppColors.card : AppColors.sunken),
          border: Border(bottom: BorderSide(color: tot ? AppColors.border : AppColors.divider)),
        ),
        padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: tot ? 12.h : 9.h),
        child: Row(children: [
          cell(l.label, wLabel, right: false, style: std ? AppUI.cell : AppUI.label),
          for (final c in cols)
            cell(_cell(l, c), c.count ? wCount : wAmt,
                style: tot
                    ? strongMoney
                    : (c.key == 'arrears' && std
                        ? AppUI.money.copyWith(color: AppColors.warning)
                        : AppUI.money)),
        ]),
      );
    }

    final body = _lines.where((l) => l.kind != _Kind.total).toList();
    final total = _lines.lastWhere((l) => l.kind == _Kind.total, orElse: () => _lines.last);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
      child: Column(children: [
        Expanded(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: LayoutBuilder(builder: (context, box) {
              final w = width < box.maxWidth ? box.maxWidth : width;
              return SingleChildScrollView(
                controller: _hCtrl,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: w,
                  child: Column(children: [
                    Container(
                      decoration: AppUI.tableHeadBar,
                      padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 10.h),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        SizedBox(
                          width: wLabel,
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6.w),
                            child: Text(_stdHead.toUpperCase(), style: AppUI.tableHead),
                          ),
                        ),
                        for (final c in cols)
                          SizedBox(
                            width: c.count ? wCount : wAmt,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 6.w),
                              child: Text(c.label.toUpperCase(),
                                  textAlign: TextAlign.right, maxLines: 3, style: AppUI.tableHead),
                            ),
                          ),
                      ]),
                    ),
                    Expanded(
                      child: Stack(children: [
                        ListView.builder(itemCount: body.length, itemBuilder: (_, i) => line(body[i])),
                        if (_running)
                          const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 2)),
                      ]),
                    ),
                    line(total),
                  ]),
                ),
              );
            }),
          ),
        ),
        ClassicHScrollbar(controller: _hCtrl),
      ]),
    );
  }
}
