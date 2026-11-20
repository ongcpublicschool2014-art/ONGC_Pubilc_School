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
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../utils/save_path.dart';

/// RECEIPT WISE ABSTRACT -- the old product's "Receiptwise Abstract": every
/// receipt taken between two dates, its money spread over one column per fee
/// type (the fee type's short name):
///
///   S. No. | Receipt No. | Type | Class | Student Name | <fee type> ... |
///   [Fine] | Total
///
/// Type is REG (regular fee), ADV (advance), ARR (arrear) or MISC
/// (miscellaneous), written on the first receipt of each type, as the old
/// sheet. A fee receipt that paid both regular and arrear demands shows once
/// under REG and once under ARR, each with its own part. A Total row closes
/// each type when more than one is shown, and the list ends with the Total.
/// As the old report, a fee type with nothing collected in the range has no
/// column.
///
/// Receipts and amounts are the Receiptwise Report's, so the two agree: the
/// fine is kept in its own column, cancelled receipts are not listed and
/// receipts still waiting on the bank are left out unless asked for.
///
/// Server side: public.rpt_receiptwise_abstract
/// (school_rpt_receiptwise_abstract.sql).
class ReceiptwiseAbstractScreen extends StatefulWidget {
  const ReceiptwiseAbstractScreen({super.key});

  @override
  State<ReceiptwiseAbstractScreen> createState() => _ReceiptwiseAbstractScreenState();
}

/// One receipt (one type's part of it).
class _Rec {
  final Map<String, dynamic> m;
  _Rec(this.m);

  static double _n(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  String s(String k) => '${m[k] ?? ''}'.trim();

  String get kind => s('kind');
  bool get pending => s('status') == 'PENDING';
  double get fine => _n(m['fine']);
  double get total => _n(m['total']);
  Map<String, dynamic> get amounts => (m['amounts'] as Map?)?.cast<String, dynamic>() ?? const {};
  double amt(String key) => _n(amounts[key]);

  /// The receipt number without its running number: 'CF26/' of 'CF26/00002'.
  String get prefix => s('recno').replaceFirst(RegExp(r'\d+$'), '');
  int get serial => int.tryParse(RegExp(r'\d+$').firstMatch(s('recno'))?.group(0) ?? '') ?? 0;
}

/// A line of the listing: a receipt, or a Total (of a type, or the grand one).
class _Line {
  final _Rec? rec;
  final int sno;
  final bool first; // the first receipt of its type: the Type is written
  final String? totalOf; // a type's Total; '' = the grand Total
  final List<_Rec> recs;
  const _Line.rec(_Rec this.rec, this.sno, this.first)
      : totalOf = null,
        recs = const [];
  const _Line.total(String this.totalOf, this.recs)
      : rec = null,
        sno = 0,
        first = false;
  bool get isTotal => rec == null;
  bool get isGrand => totalOf == '';
}

/// An amount column: a fee type's short name (key), FINE or TOTAL.
class _Col {
  final String key;
  final String head;
  final String tip;
  const _Col(this.key, this.head, this.tip);
  static const fine = 'FINE*', total = 'TOTAL*';
  double of(_Rec r) => key == fine ? r.fine : (key == total ? r.total : r.amt(key));
}

class _ReceiptwiseAbstractScreenState extends State<ReceiptwiseAbstractScreen> {
  /// Types in the old order: key, picker label.
  static const _typeNames = [
    ('REG', 'Regular'),
    ('ADV', 'Advance'),
    ('ARR', 'Arrear'),
    ('MISC', 'Miscellaneous'),
    // money paid back, negative, on the day it was paid back
    ('REF', 'Refund'),
  ];

  late DateTime _from, _to;
  bool _withPending = false;
  Set<String> _types = {for (final t in _typeNames) t.$1};
  Set<String> _prefixOff = {}; // the UNticked prefixes, so a new one shows ticked

  String _insName = '', _insAddress = '', _insCity = '';
  bool _loading = true, _running = false, _exporting = false;
  String? _error;
  List<_Rec> _all = [];
  List<(String, String)> _feeTypes = []; // (short name, full name), master order

  final ScrollController _hCtrl = ScrollController();
  final ScrollController _vCtrl = ScrollController();

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  String get _year => (context.read<AuthProvider>().yearLabel ?? '').trim();
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
      final res = await SupabaseService.client.rpc('rpt_receiptwise_abstract', params: {
        'p_token': SupabaseService.sessionToken,
        'p_from': _iso(_from),
        'p_to': _iso(_to),
      });
      final j = Map<String, dynamic>.from(res as Map);
      final rows = [for (final x in (j['rows'] as List? ?? const [])) _Rec(Map<String, dynamic>.from(x as Map))];
      final types = [
        for (final t in (j['feetypes'] as List? ?? const []))
          if (t is Map && '${t['key'] ?? ''}'.trim().isNotEmpty) ('${t['key']}'.trim(), '${t['name'] ?? ''}'.trim()),
      ];
      if (!mounted) return;
      setState(() {
        _all = rows;
        _feeTypes = types;
      });
    } catch (e) {
      if (mounted) _snack(AppText.couldNot('load the receipt wise abstract', friendlyError(e)), AppColors.error);
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
  /// 'CF26' of 'CF26/', as the old sheet's "Prefix : 'BF26',...".
  static String _prefixLabel(String p) {
    final t = p.replaceFirst(RegExp(r'[^A-Za-z0-9]+$'), '');
    return t.isEmpty ? 'No Prefix' : t;
  }

  List<String> get _prefixList => {for (final r in _all) if (_withPending || !r.pending) r.prefix}.toList()..sort();

  void _clearFilters() => setState(() {
        _types = {for (final t in _typeNames) t.$1};
        _prefixOff = {};
      });

  bool get _filtered => _types.length < _typeNames.length || _prefixOff.isNotEmpty;

  /// The receipts shown, in the old order: by type (REG, ADV, ARR, MISC),
  /// then by receipt number.
  List<_Rec> get _rows {
    int typeOrd(_Rec r) {
      final i = _typeNames.indexWhere((t) => t.$1 == r.kind);
      return i < 0 ? _typeNames.length : i;
    }

    final out = [
      for (final r in _all)
        if ((_withPending || !r.pending) && _types.contains(r.kind) && !_prefixOff.contains(r.prefix)) r,
    ];
    out.sort((a, b) {
      var c = typeOrd(a).compareTo(typeOrd(b));
      if (c == 0) c = a.prefix.compareTo(b.prefix);
      if (c == 0) c = a.serial.compareTo(b.serial);
      if (c == 0) c = a.s('recno').compareTo(b.s('recno'));
      if (c == 0) c = a.s('date').compareTo(b.s('date'));
      return c;
    });
    return out;
  }

  /// Receipts; a Total after each type when more than one type is listed;
  /// the grand Total last.
  List<_Line> _lines(List<_Rec> rows) {
    final out = <_Line>[];
    final multi = {for (final r in rows) r.kind}.length > 1;
    var sno = 0, i = 0;
    while (i < rows.length) {
      final kind = rows[i].kind;
      final group = <_Rec>[];
      while (i < rows.length && rows[i].kind == kind) {
        out.add(_Line.rec(rows[i], ++sno, group.isEmpty));
        group.add(rows[i]);
        i++;
      }
      if (multi) out.add(_Line.total(kind, group));
    }
    if (rows.isNotEmpty) out.add(_Line.total('', rows));
    return out;
  }

  double _sum(Iterable<_Rec> rs, _Col c) => rs.fold(0.0, (t, r) => t + c.of(r));

  /// One column per fee type with money in [rows] (master order, then any
  /// other head, OTHERS last), FINE when there is any, then TOTAL.
  List<_Col> _columns(List<_Rec> rows) {
    final used = <String, double>{};
    for (final r in rows) {
      r.amounts.forEach((k, _) => used[k] = (used[k] ?? 0) + r.amt(k));
    }
    final names = {for (final t in _feeTypes) t.$1: t.$2};
    final keys = [
      for (final t in _feeTypes)
        if ((used[t.$1] ?? 0).abs() >= 0.005) t.$1,
      ...(used.keys.where((k) => !names.containsKey(k) && k != 'OTHERS' && used[k]!.abs() >= 0.005).toList()..sort()),
      if ((used['OTHERS'] ?? 0).abs() >= 0.005) 'OTHERS',
    ];
    final fine = rows.fold(0.0, (t, r) => t + r.fine);
    return [
      for (final k in keys) _Col(k, k == 'OTHERS' ? 'OTHERS' : k, names[k] ?? (k == 'OTHERS' ? 'Not tied to a fee type' : k)),
      if (fine.abs() >= 0.005) const _Col(_Col.fine, 'FINE', 'Fine'),
      const _Col(_Col.total, 'Total', 'Total'),
    ];
  }

  /// Fixed columns before the amounts.
  List<String> get _heads => [AppText.serialNo, 'Receipt No.', 'Type', schoolTerm('Class'), 'Student Name'];
  static const _fixedWidths = [64.0, 130.0, 70.0, 100.0, 220.0];

  List<String> _fixedText(_Line l) {
    if (l.isGrand) return ['Total', '', '', '', 'Total'];
    if (l.isTotal) return ['', '', l.totalOf!, '', '${l.totalOf} Total'];
    final r = l.rec!;
    return ['${l.sno}', r.s('recno'), l.first ? r.kind : '', r.s('class'), r.s('name')];
  }

  String get _title =>
      'RECEIPT WISE ABSTRACT${_year.isEmpty ? '' : ' $_year'} FROM : ${formatDmy(_from)} TO : ${formatDmy(_to)}';

  /// "Prefix : 'CF26','AF26'" -- the prefixes in the listing.
  String _prefixLine(List<_Rec> rows) =>
      "Prefix : ${({for (final r in rows) _prefixLabel(r.prefix)}.toList()..sort()).map((p) => "'$p'").join(',')}";

  /// "Type may be 'REG','ADV','ARR','MISC'" -- the types ticked.
  String get _typeLine => "Type may be ${[for (final t in _typeNames) if (_types.contains(t.$1)) "'${t.$1}'"].join(',')}";

  String get _fileStem {
    final f = formatDmy(_from), t = formatDmy(_to);
    return 'Receipt_Wise_Abstract_$f${_from == _to ? '' : '_to_$t'}';
  }

  // ── export ───────────────────────────────────────────────────────────────
  Future<void> _exportPdf() async {
    final rows = _rows;
    if (rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final cols = _columns(rows);
      final ok = await saveReportPdf(
        context,
        fileName: _fileStem,
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: _title,
        subtitle: '${_prefixLine(rows)}\n$_typeLine${_withPending ? ' · Includes receipts not yet reconciled' : ''}',
        headers: [..._heads, ...cols.map((c) => c.head)],
        rows: [
          for (final l in _lines(rows))
            [
              ..._fixedText(l),
              for (final c in cols) l.isTotal ? formatIndianNumber(_sum(l.recs, c)) : _m(c.of(l.rec!)),
            ],
        ],
        rightAlign: {for (var i = 0; i < cols.length; i++) _heads.length + i},
        landscape: true,
        footNote: 'Receipts : ${rows.length}',
      );
      if (ok) _snack('Receipt wise abstract PDF saved.', AppColors.success);
    } catch (e) {
      _snack(AppText.couldNot('build the PDF', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// The old sheet: name / address / city in B1-B3, the type legend in G2,
  /// the title in B4, the prefixes in B5, headers in row 6, a row per
  /// receipt (nil amounts left blank) and the Total last.
  Future<void> _exportExcel() async {
    final rows = _rows;
    if (rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final path = await pickSavePath(
        dialogTitle: 'Save Receipt Wise Abstract',
        fileName: '$_fileStem.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      final cols = _columns(rows);
      final book = xl.Excel.createExcel();
      final sheet = book['Receipt Wise Abstract'];
      book.delete('Sheet1');
      final bold = xl.CellStyle(bold: true, fontSize: 11);
      final hdr = xl.CellStyle(bold: true, fontSize: 10, backgroundColorHex: XlTheme.headerBg, fontColorHex: XlTheme.headerFg);
      final tot = xl.CellStyle(bold: true, backgroundColorHex: XlTheme.totalBg);
      void put(int c, int r, String v, [xl.CellStyle? st]) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        cell.value = xl.TextCellValue(v);
        if (st != null) cell.cellStyle = st;
      }

      void putNum(int c, int r, double v, [xl.CellStyle? st]) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        cell.value = xl.DoubleCellValue(v);
        if (st != null) cell.cellStyle = st;
      }

      put(1, 0, _insName.toUpperCase(), bold);
      if (_insAddress.isNotEmpty) put(1, 1, _insAddress.toUpperCase());
      put(6, 1, _typeLine);
      if (_insCity.isNotEmpty) put(1, 2, _insCity.toUpperCase());
      put(1, 3, _title, bold);
      put(1, 4, _prefixLine(rows) + (_withPending ? '   (Includes receipts not yet reconciled)' : ''));
      const h = 5;
      final heads = [..._heads, ...cols.map((c) => c.head)];
      for (var c = 0; c < heads.length; c++) {
        put(c, h, heads[c], hdr);
        sheet.setColumnWidth(c, c < _fixedWidths.length ? _fixedWidths[c] / 7.5 : 13);
      }
      var r = h + 1;
      for (final l in _lines(rows)) {
        final fixed = _fixedText(l);
        final st = l.isTotal ? tot : null;
        for (var c = 0; c < fixed.length; c++) {
          if (fixed[c].isNotEmpty || l.isTotal) put(c, r, fixed[c], st);
        }
        for (var c = 0; c < cols.length; c++) {
          final v = l.isTotal ? _sum(l.recs, cols[c]) : cols[c].of(l.rec!);
          if (v.abs() >= 0.005 || l.isTotal) putNum(_heads.length + c, r, v, st);
        }
        r++;
      }
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack('Receipt wise abstract saved -- ${rows.length} receipts.', AppColors.success);
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

  /// A field-looking button that opens a tick list.
  Widget _picker(String label, String icon, String value, bool filled, VoidCallback onTap) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppUI.fieldLabel(label),
          InkWell(
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            onTap: onTap,
            child: InputDecorator(
              decoration: AppUI.field(
                context,
                '',
                filled: filled,
                leadingIcon: icon,
                suffix: const Icon(Icons.arrow_drop_down, color: AppColors.ink3, size: 22),
              ),
              child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: filled)),
            ),
          ),
        ],
      );

  /// Tick many of [items] (key, label); null = cancelled. Apply needs at least
  /// one tick.
  Future<Set<String>?> _pickMany(String title, List<(String, String)> items, Set<String> current) {
    final draft = Set<String>.from(current);
    return showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          scrollable: true,
          title: Row(children: [
            Expanded(child: Text(title, style: AppUI.cardTitle)),
            TextButton(onPressed: () => setLocal(() => draft.addAll(items.map((i) => i.$1))), child: const Text('Select All')),
            TextButton(onPressed: () => setLocal(draft.clear), child: const Text('Unselect All')),
          ]),
          content: SizedBox(
            width: 380.w,
            child: items.isEmpty
                ? Text('There is nothing to choose in this date range.', style: AppUI.muted)
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    for (final i in items)
                      CheckboxListTile(
                        value: draft.contains(i.$1),
                        onChanged: (v) => setLocal(() => v == true ? draft.add(i.$1) : draft.remove(i.$1)),
                        dense: true,
                        activeColor: AppColors.primary,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(i.$2, style: AppUI.body),
                      ),
                  ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text(AppText.cancel)),
            ElevatedButton(
              style: AppUI.primary(ctx),
              onPressed: draft.isEmpty ? null : () => Navigator.of(ctx).pop(draft),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filters() {
    final prefixes = _prefixList;
    final onPrefixes = prefixes.where((p) => !_prefixOff.contains(p)).toSet();
    String typeText() => _types.length == _typeNames.length
        ? 'All Types'
        : [for (final t in _typeNames) if (_types.contains(t.$1)) t.$2].join(', ');
    String prefixText() {
      if (_prefixOff.isEmpty) return 'All';
      if (onPrefixes.length <= 2) return (onPrefixes.map(_prefixLabel).toList()..sort()).join(', ');
      return '${onPrefixes.length} selected';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
        Expanded(
          flex: 3,
          child: _picker('Type', 'category', typeText(), _types.length < _typeNames.length, () async {
            final picked = await _pickMany('Type', [for (final t in _typeNames) (t.$1, '${t.$2} (${t.$1})')], _types);
            if (picked != null && mounted) setState(() => _types = picked);
          }),
        ),
        SizedBox(width: 10.w),
        Expanded(
          flex: 2,
          child: _picker('Receipt Prefix', 'hashtag', prefixText(), _prefixOff.isNotEmpty, () async {
            final picked = await _pickMany('Receipt Prefix', [for (final p in prefixes) (p, _prefixLabel(p))], onPrefixes);
            if (picked != null && mounted) setState(() => _prefixOff = prefixes.where((p) => !picked.contains(p)).toSet());
          }),
        ),
        SizedBox(width: 10.w),
        OutlinedButton.icon(
          onPressed: _filtered ? _clearFilters : null,
          icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
          label: const Text(AppText.clearFilters),
        ),
        SizedBox(width: 10.w),
        OutlinedButton.icon(
          onPressed: _running ? null : _run,
          icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 16),
          label: const Text('Refresh'),
        ),
      ]),
      SizedBox(height: 8.h),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        _toggle('Include Receipts Not Yet Reconciled', _withPending, (v) => setState(() => _withPending = v)),
      ]),
    ]);
  }

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
    double kindSum(String k) => rows.where((r) => r.kind == k).fold(0.0, (t, r) => t + r.total);
    final grand = rows.fold(0.0, (t, r) => t + r.total);
    final fine = rows.fold(0.0, (t, r) => t + r.fine);
    final pending = rows.where((r) => r.pending).length;
    final other = [
      if (kindSum('ADV') > 0) 'Advance ₹${formatIndianNumber(kindSum('ADV'))}',
      if (kindSum('MISC') > 0) 'Miscellaneous ₹${formatIndianNumber(kindSum('MISC'))}',
      if (fine > 0) 'Fine ₹${formatIndianNumber(fine)}',
      if (kindSum('REF') < 0) 'after refunds ₹${formatIndianNumber(-kindSum('REF'))}',
    ];

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'receipt-2',
          title: 'Receipt Wise Abstract',
          subtitle: 'Every receipt taken between two dates, split by fee type',
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
        _filters(),
        SizedBox(height: 12.h),
        Row(children: [
          Expanded(
            child: AppUI.kpi(
              icon: 'receipt-2',
              label: 'Receipts',
              value: '${rows.length}',
              sub: pending > 0 ? '$pending not yet reconciled' : null,
            ),
          ),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'money-recive', label: 'Regular', value: '₹${formatIndianNumber(kindSum('REG'))}', tint: AppColors.info)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'calendar-1', label: 'Arrear', value: '₹${formatIndianNumber(kindSum('ARR'))}', tint: AppColors.warning)),
          SizedBox(width: 12.w),
          Expanded(
            child: AppUI.kpi(
              icon: 'wallet-money',
              label: 'Total Collected',
              value: '₹${formatIndianNumber(grand)}',
              sub: other.isEmpty ? null : other.join(' · '),
              tint: AppColors.success,
            ),
          ),
        ]),
        SizedBox(height: 16.h),
        Expanded(child: _table(rows)),
        SizedBox(height: 10.h),
        Text(
          rows.isEmpty ? '' : '${AppUI.showing(1, rows.length, rows.length)} receipts${_filtered ? ' · filtered' : ''}',
          style: AppUI.muted,
        ),
      ]),
    );
  }

  Widget _table(List<_Rec> rows) {
    if (_running && rows.isEmpty) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty && _all.isNotEmpty && _filtered) {
      return AppUI.empty(
        title: 'Nothing to show',
        why: 'No receipts between ${formatDmy(_from)} and ${formatDmy(_to)} match the filters.',
        icon: 'filter',
        action: OutlinedButton.icon(
          onPressed: _clearFilters,
          icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
          label: const Text(AppText.clearFilters),
        ),
      );
    }
    if (rows.isEmpty) {
      return AppUI.empty(
        title: 'Nothing to show',
        why: 'No receipts were taken between ${formatDmy(_from)} and ${formatDmy(_to)}'
            '${_all.isNotEmpty && !_withPending ? ' that are reconciled with the bank' : ''}.',
        icon: 'receipt-2',
      );
    }
    final cols = _columns(rows);
    final lines = _lines(rows);
    final widths = [..._fixedWidths, for (final c in cols) c.key == _Col.total ? 130.0 : 110.0];
    final full = widths.fold(0.0, (a, b) => a + b) + 32;
    final totalStyle = AppUI.money.copyWith(fontWeight: FontWeight.w800);
    Widget cell(String t, double width, {bool right = false, TextStyle? style}) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Text(t, textAlign: right ? TextAlign.right : TextAlign.left, overflow: TextOverflow.ellipsis, style: style ?? AppUI.cell),
          ),
        );

    Widget lineRow(_Line l) {
      final fixed = _fixedText(l);
      final r = l.rec;
      return Row(children: [
        for (var i = 0; i < fixed.length; i++)
          if (i == 2 && !l.isTotal && fixed[i].isNotEmpty)
            SizedBox(
              width: widths[i],
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8.w),
                child: Align(alignment: Alignment.centerLeft, child: AppUI.chip(fixed[i], AppStatus.info)),
              ),
            )
          else
            cell(
              fixed[i],
              widths[i],
              style: l.isTotal ? totalStyle : (i == 0 ? AppUI.muted : (i == 1 ? AppUI.mono : null)),
            ),
        for (var c = 0; c < cols.length; c++)
          cell(
            l.isTotal ? formatIndianNumber(_sum(l.recs, cols[c])) : _m(cols[c].of(r!)),
            widths[_heads.length + c],
            right: true,
            style: l.isTotal ? totalStyle : AppUI.money,
          ),
      ]);
    }

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
                  final width = full < c.maxWidth ? c.maxWidth : full;
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
                            for (var i = 0; i < _heads.length; i++) cell(_heads[i], widths[i], style: AppUI.tableHead),
                            for (var i = 0; i < cols.length; i++)
                              Tooltip(
                                message: cols[i].tip,
                                child: cell(cols[i].head, widths[_heads.length + i], right: true, style: AppUI.tableHead),
                              ),
                          ]),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: _vCtrl,
                            itemCount: lines.length - 1, // the grand Total is pinned below
                            itemBuilder: (_, i) {
                              final l = lines[i];
                              return Container(
                                decoration: l.isTotal
                                    ? const BoxDecoration(color: AppColors.surface, border: Border(bottom: BorderSide(color: AppColors.border)))
                                    : const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
                                padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: l.isTotal ? 10.h : 8.h),
                                child: lineRow(l),
                              );
                            },
                          ),
                        ),
                        Container(
                          decoration: const BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
                          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 12.h),
                          child: lineRow(lines.last),
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
