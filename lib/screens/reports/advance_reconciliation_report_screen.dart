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

/// ADVANCE FEE RECONCILIATION REPORT -- the old product's "ADVANCE FEE
/// RECONCILATION REPORT" (PsFees, over Advfeerecon):
///
///   Sno | Class | Admn No. | Student Name | Term | Adv. Amt | Rec. Amt | Non Rec. Amt
///
/// with a subtotal per section and a grand total, and its fee-type version
///   Fee Type | Adv. Amt | Rec. Amt | Non Rec. Amt.
///
/// Two kinds of advance:
///   * Previous year's advances (default, as the old report) -- collected last
///     year, carried forward and reconciled into this year's demands on
///     Fees -> Advance Reconcile. Rec. Amt = reconciled so far.
///   * This year's advances for next year -- Rec. Amt = what Advance
///     Adjustment already settled this year; Non Rec. Amt is what Carry
///     Forward will take into next year.
/// Server side: public.rpt_advance_reconciliation
/// (school_rpt_advance_reconciliation.sql).
class AdvanceReconciliationReportScreen extends StatefulWidget {
  const AdvanceReconciliationReportScreen({super.key});

  @override
  State<AdvanceReconciliationReportScreen> createState() => _AdvanceReconciliationReportScreenState();
}

/// One line from the server: a student x term x fee type.
class _Line {
  final int stuId, claId, courOrd, termOrd, feeOrd;
  final String admNo, name, section, term, feeType;
  final double adv, rec, non;
  _Line(Map m)
      : stuId = _id(m['stu_id']) ?? 0,
        claId = _id(m['cla_id']) ?? 0,
        courOrd = _id(m['cour_ord']) ?? 999,
        termOrd = _id(m['term_ord']) ?? 999,
        feeOrd = _id(m['fee_ord']) ?? 999,
        admNo = '${m['stuadmno'] ?? ''}',
        name = '${m['stuname'] ?? ''}',
        section = '${m['claname'] ?? ''}',
        term = '${m['term'] ?? ''}',
        feeType = '${m['feetype'] ?? ''}',
        adv = _num(m['adv']),
        rec = _num(m['rec']),
        non = _num(m['nonrec']);

  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
}

enum _Kind { data, subtotal, grand }

/// A printed row: a student-term (or fee type), a section subtotal or the
/// grand total.
class _Row {
  final _Kind kind;
  final int? sno;
  final String section, admNo, name, term, feeType;
  double adv = 0, rec = 0, non = 0;
  _Row(this.kind, {this.sno, this.section = '', this.admNo = '', this.name = '', this.term = '', this.feeType = ''});
  void add(double a, double r, double n) {
    adv += a;
    rec += r;
    non += n;
  }
}

class _AdvanceReconciliationReportScreenState extends State<AdvanceReconciliationReportScreen> {
  static const _title = 'ADVANCE FEE RECONCILIATION REPORT';

  String _mode = 'PREV'; // PREV = last year's advances, NEXT = this year's for next year
  bool _feeWise = false, _onlyPending = false;
  int? _cour, _cla;
  List<Map<String, dynamic>> _courses = [], _classes = [];
  String _insName = '', _insAddress = '', _insCity = '';

  bool _loading = true, _running = false, _exporting = false, _prevFound = true;
  String? _error;
  List<_Line> _lines = [];
  String _curYear = '', _prevYear = '', _nextYear = '';
  int _pendingCarry = 0;
  double _pendingCarryAmt = 0;

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static String _m(double v) => formatIndianNumber(v.abs() < 0.005 ? 0 : v);

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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Future.wait<dynamic>([
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.getInstitutionInfo(_insId),
      ]);
      if (!mounted) return;
      final info = r[2] as ({String? name, String? logo, String? address, String? mobile, String? email});
      final parts = (info.address ?? '').replaceAll('\n', ', ').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      setState(() {
        _courses = List<Map<String, dynamic>>.from(r[0] as List)..sort((a, b) => (_id(a['ordid']) ?? 999).compareTo(_id(b['ordid']) ?? 999));
        _classes = List<Map<String, dynamic>>.from(r[1] as List)..sort((a, b) => classCompare('${a['claname']}', '${b['claname']}'));
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

  List<int>? get _claIds {
    if (_cla != null) return [_cla!];
    if (_cour != null) return [for (final c in _classes) if (_id(c['cour_id']) == _cour) _id(c['cla_id'])!];
    return null;
  }

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final res = await SupabaseService.client.rpc('rpt_advance_reconciliation', params: {
        'p_token': SupabaseService.sessionToken,
        'p_cla_ids': _claIds,
        'p_mode': _mode,
      });
      final j = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      setState(() {
        _lines = [for (final x in (j['rows'] as List? ?? const [])) _Line(x as Map)];
        _curYear = '${j['cur_year'] ?? ''}';
        _prevYear = '${j['prev_year'] ?? ''}';
        _nextYear = '${j['next_year'] ?? ''}';
        _prevFound = j['prev_found'] != false;
        _pendingCarry = _id(j['pending_carry']) ?? 0;
        _pendingCarryAmt = _Line._num(j['pending_carry_amount']);
      });
    } catch (e) {
      if (mounted) _snack(AppText.couldNot('load the report', friendlyError(e)), AppColors.error);
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

  // ── rows ─────────────────────────────────────────────────────────────────
  static String _termLabel(String t) => t.isEmpty ? '-' : t;
  static String _feeLabel(String f) => f.isEmpty ? 'General Advance' : f;

  /// The report rows in print order: per section its students (or fee types)
  /// and a section subtotal; the grand total last. In the fee-type layout
  /// with more than one section, an all-sections fee-type summary comes
  /// before the grand total.
  List<_Row> get _rows {
    // sections in standard order, then section name
    final bySection = <int, List<_Line>>{};
    for (final l in _lines) {
      bySection.putIfAbsent(l.claId, () => []).add(l);
    }
    final sections = bySection.keys.toList()
      ..sort((a, b) {
        final la = bySection[a]!.first, lb = bySection[b]!.first;
        final c = la.courOrd.compareTo(lb.courOrd);
        return c != 0 ? c : classCompare(la.section, lb.section);
      });

    final out = <_Row>[];
    final grand = _Row(_Kind.grand, section: 'GRAND TOTAL');
    final overall = <String, _Row>{};
    final overallOrd = <String, int>{};
    var sno = 0;
    for (final cla in sections) {
      final ls = bySection[cla]!;
      final name = ls.first.section;
      final groups = <String, _Row>{};
      final order = <String, List<Object>>{};
      for (final l in ls) {
        final key = _feeWise ? l.feeType : '${l.stuId}|${l.term}';
        groups.putIfAbsent(key, () => _feeWise
            ? _Row(_Kind.data, section: name, feeType: _feeLabel(l.feeType))
            : _Row(_Kind.data, section: name, admNo: l.admNo, name: l.name, term: _termLabel(l.term)));
        groups[key]!.add(l.adv, l.rec, l.non);
        order[key] = _feeWise ? [l.feeOrd, _feeLabel(l.feeType)] : [l.admNo, l.termOrd, l.term];
      }
      final keys = groups.keys.where((k) => !_onlyPending || groups[k]!.non > 0.005).toList()
        ..sort((a, b) {
          final x = order[a]!, y = order[b]!;
          for (var i = 0; i < x.length; i++) {
            final c = (x[i] as Comparable).compareTo(y[i]);
            if (c != 0) return c;
          }
          return 0;
        });
      if (keys.isEmpty) continue;
      final sub = _Row(_Kind.subtotal, section: '$name TOTAL');
      for (final k in keys) {
        final g = groups[k]!;
        sno++;
        final row = _feeWise
            ? _Row(_Kind.data, sno: sno, section: g.section, feeType: g.feeType)
            : _Row(_Kind.data, sno: sno, section: g.section, admNo: g.admNo, name: g.name, term: g.term);
        row.add(g.adv, g.rec, g.non);
        out.add(row);
        sub.add(g.adv, g.rec, g.non);
        grand.add(g.adv, g.rec, g.non);
        if (_feeWise) {
          overall.putIfAbsent(g.feeType, () => _Row(_Kind.data, section: schoolTerm('ALL CLASSES'), feeType: g.feeType)).add(g.adv, g.rec, g.non);
          overallOrd[g.feeType] = (order[k]!.first as int);
        }
      }
      out.add(sub);
    }
    if (out.isEmpty) return out;
    if (_feeWise && sections.length > 1 && overall.isNotEmpty) {
      final fts = overall.keys.toList()
        ..sort((a, b) {
          final c = overallOrd[a]!.compareTo(overallOrd[b]!);
          return c != 0 ? c : a.compareTo(b);
        });
      for (final f in fts) {
        sno++;
        final o = overall[f]!;
        out.add(_Row(_Kind.data, sno: sno, section: o.section, feeType: o.feeType)..add(o.adv, o.rec, o.non));
      }
    }
    out.add(grand);
    return out;
  }

  // ── columns ──────────────────────────────────────────────────────────────
  /// (header, value of a row, is-amount, width)
  List<(String, String Function(_Row), bool, double)> get _columns => [
        (AppText.serialNo.toUpperCase(), (r) => r.sno == null ? '' : '${r.sno}', false, 64),
        (schoolTerm('CLASS'), (r) => r.section, false, 140),
        if (!_feeWise) ...[
          (AppText.admissionNo.toUpperCase(), (r) => r.admNo, false, 130),
          ('STUDENT NAME', (r) => r.name, false, 230),
          (schoolTerm('SEMESTER'), (r) => r.term, false, 100),
        ] else
          ('FEE TYPE', (r) => r.feeType, false, 230),
        ('ADV. AMT', (r) => _m(r.adv), true, 120),
        ('REC. AMT', (r) => _m(r.rec), true, 120),
        ('NON REC. AMT', (r) => _m(r.non), true, 130),
      ];

  String get _scope {
    if (_cla != null) return '${_classes.firstWhere((c) => _id(c['cla_id']) == _cla, orElse: () => const {})['claname'] ?? ''}';
    if (_cour != null) return '${_courses.firstWhere((c) => _id(c['cour_id']) == _cour, orElse: () => const {})['courname'] ?? ''}';
    return '';
  }

  /// "ADVANCE FEE RECONCILIATION REPORT FOR <section>" -- as the old titles.
  String get _fullTitle {
    final s = _scope;
    if (s.isEmpty) return _title;
    return _cla != null ? '$_title FOR $s' : '$_title FOR ${schoolTerm('COURSE')} : $s';
  }

  String get _what => _mode == 'PREV'
      ? 'Advances collected in $_prevYear, reconciled in $_curYear'
      : 'Advances collected in $_curYear for $_nextYear';

  String get _subtitle => [
        _what,
        _feeWise ? 'Fee Type Wise' : 'Student Wise',
        if (_onlyPending) 'Only Not Reconciled',
      ].join(' · ');

  String? get _note {
    if (_mode == 'PREV' && _pendingCarry > 0) {
      return 'Note : $_pendingCarry advance receipt${_pendingCarry == 1 ? '' : 's'} of $_prevYear '
          '(₹${formatIndianNumber(_pendingCarryAmt)}) not carried forward yet -- run Carry Forward on Advance Reconcile.';
    }
    if (_mode == 'NEXT') return 'Note : Non Rec. Amt is carried into $_nextYear by Carry Forward.';
    return null;
  }

  String get _fileName {
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final s = _scope;
    return 'Advance_Reconciliation_${_mode == 'PREV' ? _prevYear : _curYear}${_feeWise ? '_FeeType' : ''}${s.isEmpty ? '' : '_${safe(s)}'}';
  }

  // ── export ───────────────────────────────────────────────────────────────
  Future<void> _exportPdf() async {
    final rows = _rows;
    if (rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final cols = _columns;
      final ok = await saveReportPdf(
        context,
        fileName: _fileName,
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: _fullTitle,
        subtitle: _subtitle,
        headers: [for (final c in cols) c.$1],
        rows: [for (final r in rows) [for (final c in cols) c.$2(r)]],
        rightAlign: {for (var i = 0; i < cols.length; i++) if (cols[i].$3) i},
        landscape: false,
        footNote: _note,
      );
      if (ok) _snack('Advance reconciliation PDF saved.', AppColors.success);
    } catch (e) {
      _snack(AppText.couldNot('build the PDF', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// The old sheet: institution name / address / city on rows 1-3, the title
  /// on row 6, the column headers on row 9 starting at column B.
  Future<void> _exportExcel() async {
    final rows = _rows;
    if (rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Advance Reconciliation Report',
        fileName: '$_fileName.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      final cols = _columns;
      final book = xl.Excel.createExcel();
      final sheet = book['Advance Reconciliation'];
      book.delete('Sheet1');
      final bold = xl.CellStyle(bold: true, fontSize: 11);
      final center = xl.CellStyle(bold: true, fontSize: 11, horizontalAlign: xl.HorizontalAlign.Center);
      final hdr = xl.CellStyle(bold: true, fontSize: 11, backgroundColorHex: xl.ExcelColor.fromHexString('#F2F4F7'));
      void put(int c, int r, String v, [xl.CellStyle? st, bool number = false]) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
        final n = number ? double.tryParse(v.replaceAll(',', '')) : null;
        cell.value = n != null ? xl.DoubleCellValue(n) : xl.TextCellValue(v);
        if (st != null) cell.cellStyle = st;
      }

      const c0 = 1; // column B, as the old sheet
      final mid = c0 + cols.length ~/ 2;
      put(mid, 0, _insName.toUpperCase(), center);
      if (_insAddress.isNotEmpty) put(mid, 1, _insAddress.toUpperCase(), center);
      if (_insCity.isNotEmpty) put(mid, 2, _insCity.toUpperCase(), center);
      put(c0 + 1, 5, _fullTitle, bold);
      put(c0 + 1, 6, _subtitle.toUpperCase());
      const h = 8;
      for (var c = 0; c < cols.length; c++) {
        put(c0 + c, h, cols[c].$1, hdr);
        sheet.setColumnWidth(c0 + c, cols[c].$4 / 7);
      }
      var r = h + 1;
      for (final row in rows) {
        final st = row.kind == _Kind.data ? null : bold;
        for (var c = 0; c < cols.length; c++) {
          put(c0 + c, r, cols[c].$2(row), st, cols[c].$3);
        }
        r++;
      }
      final note = _note;
      if (note != null) put(c0, r + 1, note);
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      await File(path).writeAsBytes(bytes);
      _snack('Advance reconciliation report saved.', AppColors.success);
    } catch (e) {
      _snack(AppText.couldNot('build the Excel file', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  Widget _drop<T>(String hint, T? value, List<(T, String)> items, ValueChanged<T?> onChanged, {String? icon, String allLabel = 'All'}) {
    return DropdownButtonFormField<T?>(
      key: ValueKey('$hint-$value-${items.length}'),
      initialValue: value,
      isExpanded: true,
      dropdownColor: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      style: AppUI.fieldText(context, filled: value != null),
      decoration: AppUI.field(context, hint, filled: value != null, leadingIcon: icon),
      items: [
        DropdownMenuItem<T?>(value: null, child: Text(allLabel, overflow: TextOverflow.ellipsis)),
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
    final rows = _rows;
    final grand = rows.isEmpty ? null : rows.last;
    final students = {for (final l in _lines) if (!_onlyPending || l.non > 0.005) l.stuId}.length;
    final sections = [for (final c in _classes) if (_cour == null || _id(c['cour_id']) == _cour) (_id(c['cla_id'])!, '${c['claname']}')];
    final note = _note;

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'wallet-check',
          title: 'Advance Fee Reconciliation',
          subtitle: 'Advance collected, reconciled into fee demands, and not reconciled yet',
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
        Row(children: [
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
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'PREV', label: Text('Previous Year Advances')),
              ButtonSegment(value: 'NEXT', label: Text('Advances for Next Year')),
            ],
            selected: {_mode},
            showSelectedIcon: false,
            onSelectionChanged: _running
                ? null
                : (v) {
                    setState(() => _mode = v.first);
                    _run();
                  },
          ),
          SizedBox(width: 10.w),
          OutlinedButton.icon(
            onPressed: _running ? null : _run,
            icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
          ),
        ]),
        SizedBox(height: 12.h),
        Row(children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Student Wise'), icon: Icon(Icons.person_outline, size: 16)),
              ButtonSegment(value: true, label: Text('Fee Type Wise'), icon: Icon(Icons.receipt_long_outlined, size: 16)),
            ],
            selected: {_feeWise},
            onSelectionChanged: (v) => setState(() => _feeWise = v.first),
          ),
          SizedBox(width: 20.w),
          Switch(
            value: _onlyPending,
            activeThumbColor: AppColors.onPrimary,
            activeTrackColor: AppColors.primary,
            onChanged: (v) => setState(() => _onlyPending = v),
          ),
          SizedBox(width: 6.w),
          Text('Only Not Reconciled', style: AppUI.label),
          const Spacer(),
          Flexible(child: Text(_what, style: AppUI.muted, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
        SizedBox(height: 16.h),
        // KPI tiles
        Row(children: [
          Expanded(child: AppUI.kpi(icon: 'people', label: 'Students', value: '$students', sub: _scope.isEmpty ? schoolTerm('All Classes') : _scope)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'wallet-money', label: 'Advance Amount', value: '₹${_m(grand?.adv ?? 0)}', tint: AppColors.demand)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'tick-circle', label: 'Reconciled', value: '₹${_m(grand?.rec ?? 0)}', tint: AppColors.success)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'timer-1', label: 'Not Reconciled', value: '₹${_m(grand?.non ?? 0)}', tint: AppColors.warning)),
        ]),
        SizedBox(height: 16.h),
        Expanded(child: _table(rows)),
        SizedBox(height: 10.h),
        if (note != null) ...[
          Text(note.replaceFirst('Note : ', ''),
              style: AppUI.muted.copyWith(color: _mode == 'PREV' ? AppColors.warning : AppColors.ink3), maxLines: 2, overflow: TextOverflow.ellipsis),
          SizedBox(height: 4.h),
        ],
        Text(
          rows.isEmpty ? '' : '$students students · ${rows.where((r) => r.kind == _Kind.data).length} rows · $_subtitle',
          style: AppUI.muted,
        ),
      ]),
    );
  }

  Widget _table(List<_Row> rows) {
    if (_running && _lines.isEmpty) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty) {
      return AppUI.empty(
        title: 'Nothing to show',
        why: _mode == 'PREV' && !_prevFound
            ? 'There is no $_prevYear academic year to bring advances from.'
            : _mode == 'PREV'
                ? (_pendingCarry > 0
                    ? 'No carried advances for these filters. Run Carry Forward on Advance Reconcile to bring $_prevYear advances in.'
                    : schoolTerm('No $_prevYear advances for this class.'))
                : _onlyPending
                    ? 'Every advance for these filters is reconciled.'
                    : schoolTerm('No advance collected this year for this class.'),
        icon: 'wallet-check',
      );
    }
    final cols = _columns;
    final body = rows.last.kind == _Kind.grand ? rows.sublist(0, rows.length - 1) : rows;
    final grand = rows.last.kind == _Kind.grand ? rows.last : null;
    final total = cols.fold(0.0, (a, c) => a + c.$4) + 32;
    Widget cell(String t, double width, {bool right = false, TextStyle? style}) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Text(t, textAlign: right ? TextAlign.right : TextAlign.left, overflow: TextOverflow.ellipsis, style: style ?? AppUI.cell),
          ),
        );
    final strong = AppUI.money.copyWith(fontWeight: FontWeight.w800);

    Widget rowWidget(_Row r) {
      final sub = r.kind != _Kind.data;
      return Container(
        decoration: BoxDecoration(
          color: sub ? AppColors.sunken : null,
          border: const Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 10.h),
        child: Row(children: [
          for (final c in cols)
            if (!sub && c.$1 == AppText.admissionNo.toUpperCase())
              SizedBox(
                width: c.$4,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8.w),
                  child: Align(alignment: Alignment.centerLeft, child: AppUI.admTag(r.admNo)),
                ),
              )
            else
              cell(
                c.$2(r),
                c.$4,
                right: c.$3,
                style: sub
                    ? (c.$3 ? strong : AppUI.label)
                    : c.$1 == 'NON REC. AMT' && r.non > 0.005
                        ? AppUI.money.copyWith(color: AppColors.warning)
                        : c.$1 == AppText.serialNo.toUpperCase()
                            ? AppUI.muted
                            : (c.$3 ? AppUI.money : AppUI.cell),
              ),
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
                        Container(
                          color: AppColors.tableHeadBg,
                          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 12.h),
                          child: Row(children: [
                            for (final c in cols) cell(c.$1, c.$4, right: c.$3, style: AppUI.tableHead),
                          ]),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: _vCtrl,
                            itemCount: body.length,
                            itemBuilder: (_, i) => rowWidget(body[i]),
                          ),
                        ),
                        if (grand != null)
                          Container(
                            decoration: const BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
                            padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 12.h),
                            child: Row(children: [
                              for (final c in cols) cell(c.$2(grand), c.$4, right: c.$3, style: c.$3 ? strong : AppUI.label),
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
