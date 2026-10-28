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

/// PENDING FEE REPORT AS ON <date> -- the old product's Fee Pending Report,
/// with its two layouts (the two sheets of the old workbook):
///
///   Term-wise      Sno | Section | Admission No. | Student Name |
///                  <current-year pending per term> | Total |
///                  <arrear pending per year> | Net Total | Remarks
///   Fee-type-wise  the same, with one column per term x fee type (term on
///                  the top header row, the fee type's short name below)
///
/// Students grouped by section ('Total' after each) and standard ('Standard
/// Total' after each), 'Grand Total' at the end; TC-issued students are left
/// out unless asked for ("Note : without TC Issued Students"). Pending = what
/// the student still owes, a collection still awaiting reconciliation counted
/// as unpaid (the rule of the Pending Payment report). Arrear columns: one per
/// arrear year with "With Arrear Detail", else a single Arrear column.
/// Server side: public.rpt_pending_fee (school_rpt_pending_fee.sql).
class PendingFeeReportScreen extends StatefulWidget {
  const PendingFeeReportScreen({super.key});

  @override
  State<PendingFeeReportScreen> createState() => _PendingFeeReportScreenState();
}

/// One student's pending, pivoted.
class _Stu {
  final Map<String, dynamic> s;
  final Map<String, double> term = {}; // current-year pending per term
  final Map<String, double> termFt = {}; // per term + fee type ([_key])
  final Map<String, double> arrear = {}; // arrear pending per year
  double con = 0;
  _Stu(this.s);

  double get total => term.values.fold(0.0, (a, b) => a + b);
  double get arrearTotal => arrear.values.fold(0.0, (a, b) => a + b);
  double get net => total + arrearTotal;
  bool get tc => s['tc'] == true;
  String get admNo => '${s['stuadmno'] ?? ''}';
  String get name => '${s['stuname'] ?? ''}';
  String get section => '${s['claname'] ?? ''}';
  String get standard => '${s['courname'] ?? ''}';

  /// 'CONCESSION' for a student in a concession category other than GENERAL,
  /// or with a concession on a demand -- the old report's Remarks.
  String get remark {
    final c = '${s['category'] ?? ''}'.trim().toUpperCase();
    return (c.isNotEmpty && c != 'GENERAL') || con.abs() >= 0.005 ? 'CONCESSION' : '';
  }
}

String _key(String term, String ft) => '$term\u0001$ft';

/// An amount column: [top] is the upper header row (the term, in the
/// fee-type-wise layout, or 'Arrear'), [head] the lower one.
class _Col {
  final String top, head;
  final double Function(_Stu) v;
  final bool strong; // Total / Net Total
  const _Col(this.top, this.head, this.v, {this.strong = false});
  String get single => top.isEmpty ? head : '$top $head';
}

enum _Kind { student, section, standard, grand }

/// A printed line: a student, or a subtotal over [members].
class _Line {
  final _Kind kind;
  final _Stu? stu;
  final int sno;
  final String label; // section / standard name of a subtotal
  final List<_Stu> members;
  const _Line(this.kind, {this.stu, this.sno = 0, this.label = '', this.members = const []});
  double sum(_Col c) => stu != null ? c.v(stu!) : members.fold(0.0, (t, s) => t + c.v(s));
}

class _PendingFeeReportScreenState extends State<PendingFeeReportScreen> {
  static const _tcModes = [
    ('WITHOUT', 'Without TC Students'),
    ('TC', 'TC Issued Students'),
    ('ALL', 'All Students'),
  ];

  // filters
  final Set<int> _claIds = {};
  final Set<String> _fees = {};
  String _tc = 'WITHOUT';
  bool _feeLayout = false; // false = term-wise, true = fee-type-wise
  bool _withArrear = true;

  // masters
  List<Map<String, dynamic>> _courses = [], _classes = [];
  List<(String, String)> _feeTypes = []; // (fee type, short name), in order
  String _insName = '', _insAddress = '', _insCity = '';

  // result
  bool _loading = true, _running = false, _exporting = false;
  String? _error;
  List<_Stu> _rows = [];
  List<_Line> _lines = [];
  List<String> _terms = []; // terms with pending, in term order
  List<(String, String)> _pairs = []; // (term, fee type) with pending
  List<String> _years = []; // arrear years with pending
  DateTime _asOf = DateTime.now();
  String _ranTc = 'WITHOUT';

  int get _insId => context.read<AuthProvider>().insId ?? 1;
  static int? _id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  static bool _zero(double v) => v.abs() < 0.005;

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
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id, ordid').eq('ins_id', _insId).eq('activestatus', 1),
        SupabaseService.getInstitutionInfo(_insId),
      ]);
      if (!mounted) return;
      final info = r[2] as ({String? name, String? logo, String? address, String? mobile, String? email});
      final parts = (info.address ?? '').replaceAll('\n', ', ').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      setState(() {
        _courses = List<Map<String, dynamic>>.from(r[0] as List)..sort((a, b) => (_id(a['ordid']) ?? 999).compareTo(_id(b['ordid']) ?? 999));
        _classes = List<Map<String, dynamic>>.from(r[1] as List)
          ..sort((a, b) {
            final o = (_id(a['ordid']) ?? 999).compareTo(_id(b['ordid']) ?? 999);
            return o != 0 ? o : classCompare('${a['claname']}', '${b['claname']}');
          });
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

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final res = await SupabaseService.client.rpc('rpt_pending_fee', params: {
        'p_token': SupabaseService.sessionToken,
        'p_cla_ids': _claIds.isEmpty ? null : _claIds.toList(),
        'p_fee_types': _fees.isEmpty ? null : _fees.toList(),
        'p_tc': _tc,
      });
      final j = Map<String, dynamic>.from(res as Map);
      final byId = <int, _Stu>{};
      for (final x in (j['students'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(x as Map);
        byId[_id(m['stu_id'])!] = _Stu(m);
      }
      final termOrder = [for (final t in (j['terms'] as List? ?? const [])) '${(t as Map)['term']}'];
      final feeTypes = [for (final f in (j['feetypes'] as List? ?? const [])) ('${(f as Map)['ft']}', '${f['short'] ?? f['ft']}')];
      final ftOrder = [for (final f in feeTypes) f.$1];
      final terms = <String>{}, years = <String>{};
      final pairs = <String, (String, String)>{};
      for (final x in (j['lines'] as List? ?? const [])) {
        final l = x as Map;
        final s = byId[_id(l['stu_id'])];
        if (s == null) continue;
        final amt = _num(l['amt']);
        s.con += _num(l['con']);
        if (_zero(amt)) continue;
        final term = '${l['term']}', ft = '${l['ft']}';
        if ('${l['seq']}' == 'ARREAR') {
          final y = '${l['year']}';
          years.add(y);
          s.arrear[y] = (s.arrear[y] ?? 0) + amt;
        } else {
          terms.add(term);
          pairs[_key(term, ft)] = (term, ft);
          s.term[term] = (s.term[term] ?? 0) + amt;
          s.termFt[_key(term, ft)] = (s.termFt[_key(term, ft)] ?? 0) + amt;
        }
      }
      int idx(List<String> order, String v) {
        final i = order.indexOf(v);
        return i < 0 ? order.length : i;
      }

      int byTerm(String a, String b) {
        final c = idx(termOrder, a).compareTo(idx(termOrder, b));
        return c != 0 ? c : a.compareTo(b);
      }

      if (!mounted) return;
      setState(() {
        _feeTypes = feeTypes;
        _fees.removeWhere((f) => !ftOrder.contains(f));
        _rows = byId.values.toList();
        _lines = _group(_rows);
        _terms = terms.toList()..sort(byTerm);
        _pairs = pairs.values.toList()
          ..sort((a, b) {
            final c = byTerm(a.$1, b.$1);
            if (c != 0) return c;
            final f = idx(ftOrder, a.$2).compareTo(idx(ftOrder, b.$2));
            return f != 0 ? f : a.$2.compareTo(b.$2);
          });
        _years = years.toList()..sort();
        _asOf = DateTime.tryParse('${j['asof'] ?? ''}') ?? DateTime.now();
        _ranTc = _tc;
        _error = null;
      });
    } catch (e) {
      if (mounted) _snack(AppText.couldNot('load the report', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Sorted by standard, section and admission number, with a section
  /// subtotal after each section, a standard subtotal after each standard and
  /// the grand total last (the old report's Total / ClsGrp Tot / G.Total).
  static List<_Line> _group(List<_Stu> rows) {
    int adm(String a, String b) {
      final x = int.tryParse(a), y = int.tryParse(b);
      if (x != null && y != null) return x.compareTo(y);
      return a.compareTo(b);
    }

    final sorted = [...rows]
      ..sort((a, b) {
        var c = (_id(a.s['cour_ord']) ?? 999).compareTo(_id(b.s['cour_ord']) ?? 999);
        if (c != 0) return c;
        c = a.standard.compareTo(b.standard);
        if (c != 0) return c;
        c = (_id(a.s['cla_ord']) ?? 999).compareTo(_id(b.s['cla_ord']) ?? 999);
        if (c != 0) return c;
        c = classCompare(a.section, b.section);
        return c != 0 ? c : adm(a.admNo, b.admNo);
      });
    final out = <_Line>[];
    var sec = <_Stu>[], std = <_Stu>[];
    var sno = 0;
    for (var i = 0; i < sorted.length; i++) {
      final s = sorted[i];
      out.add(_Line(_Kind.student, stu: s, sno: ++sno));
      sec.add(s);
      std.add(s);
      final next = i + 1 < sorted.length ? sorted[i + 1] : null;
      final newStd = next == null || next.standard != s.standard || next.s['cour_id'] != s.s['cour_id'];
      if (newStd || next.section != s.section) {
        out.add(_Line(_Kind.section, label: s.section, members: sec));
        sec = [];
      }
      if (newStd) {
        out.add(_Line(_Kind.standard, label: s.standard, members: std));
        std = [];
      }
    }
    if (sorted.isNotEmpty) out.add(_Line(_Kind.grand, members: sorted));
    return out;
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  // ── columns ──────────────────────────────────────────────────────────────
  String _short(String ft) => _feeTypes.firstWhere((f) => f.$1 == ft, orElse: () => (ft, ft)).$2;

  List<_Col> _columns(bool feeLayout) => [
        if (feeLayout)
          for (final p in _pairs) _Col(p.$1, _short(p.$2), (s) => s.termFt[_key(p.$1, p.$2)] ?? 0)
        else
          for (final t in _terms) _Col('', t, (s) => s.term[t] ?? 0),
        _Col('', 'Total', (s) => s.total, strong: true),
        if (_withArrear)
          for (final y in _years) _Col('Arrear', y, (s) => s.arrear[y] ?? 0)
        else if (_years.isNotEmpty)
          _Col('', 'Arrear', (s) => s.arrearTotal),
        _Col('', 'Net Total', (s) => s.net, strong: true),
      ];

  // ── wording ──────────────────────────────────────────────────────────────
  String get _title => 'PENDING FEE REPORT AS ON ${formatDmy(_asOf)}';
  String get _feeLine => 'FEE TYPE : ${_fees.isEmpty ? 'ALL FEE TYPES' : ([for (final f in _feeTypes) if (_fees.contains(f.$1)) f.$1]).join(', ')}';
  String get _sectionLine {
    if (_claIds.isEmpty) return '';
    final names = [for (final c in _classes) if (_claIds.contains(_id(c['cla_id']))) '${c['claname']}'];
    return '${schoolTerm('CLASS')} : ${names.join(', ')}';
  }

  String get _note => switch (_ranTc) {
        'TC' => 'Note : TC Issued Students only',
        'ALL' => 'Note : including TC Issued Students',
        _ => 'Note : without TC Issued Students',
      };

  String get _secHead => schoolTerm('Class');
  String _subLabel(_Line l) => switch (l.kind) {
        _Kind.section => 'Total',
        _Kind.standard => schoolTerm('Course Total'),
        _Kind.grand => 'Grand Total',
        _Kind.student => '',
      };

  String get _fileStem {
    final d = formatDmy(_asOf);
    return 'Pending_Fee_Report_$d';
  }

  // ── export ───────────────────────────────────────────────────────────────
  Future<void> _exportExcel() async {
    if (_rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Pending Fee Report',
        fileName: '$_fileStem.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (path == null) return;
      final book = xl.Excel.createExcel();
      _writeSheet(book['Term'], false);
      _writeSheet(book['Feetypewise'], true);
      book.delete('Sheet1');
      book.setDefaultSheet('Term');
      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not build the Excel file');
      final file = path.toLowerCase().endsWith('.xlsx') ? path : '$path.xlsx';
      await File(file).writeAsBytes(bytes);
      _snack('Pending fee report saved -- ${_rows.length} students.', AppColors.success);
    } catch (e) {
      _snack(AppText.couldNot('build the Excel file', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  static String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  /// One sheet of the old workbook: title block, header row(s), the lines
  /// with their subtotals, and the note.
  void _writeSheet(xl.Sheet sheet, bool feeLayout) {
    final cols = _columns(feeLayout);
    final lastCol = 4 + cols.length; // Sno, Section, Adm No, Name, amounts, Remarks
    final center = xl.CellStyle(bold: true, fontSize: 11, horizontalAlign: xl.HorizontalAlign.Center);
    final hdr = xl.CellStyle(
      bold: true,
      fontSize: 10,
      horizontalAlign: xl.HorizontalAlign.Center,
      textWrapping: xl.TextWrapping.WrapText,
      backgroundColorHex: xl.ExcelColor.fromHexString(_hex(AppColors.tableHeadBg)),
    );
    final bold = xl.CellStyle(bold: true, fontSize: 10);
    // amounts as plain numbers (General), as the old workbook
    final num = xl.CellStyle(fontSize: 10);
    final numBold = xl.CellStyle(bold: true, fontSize: 10);

    xl.Data at(int c, int r) => sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r));
    void text(int c, int r, String v, [xl.CellStyle? st]) {
      final cell = at(c, r);
      cell.value = xl.TextCellValue(v);
      if (st != null) cell.cellStyle = st;
    }

    void amount(int c, int r, double v, {bool showZero = false, bool strong = false}) {
      if (_zero(v) && !showZero) return;
      final cell = at(c, r);
      cell.value = xl.DoubleCellValue(double.parse(v.toStringAsFixed(2)));
      cell.cellStyle = strong ? numBold : num;
    }

    void title(int r, String v) {
      sheet.merge(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r), xl.CellIndex.indexByColumnRow(columnIndex: lastCol, rowIndex: r));
      text(0, r, v, center);
    }

    title(0, _insName.toUpperCase());
    if (_insAddress.isNotEmpty) title(1, _insAddress.toUpperCase());
    if (_insCity.isNotEmpty) title(2, _insCity.toUpperCase());
    title(3, _title);
    title(4, _feeLine);
    if (_sectionLine.isNotEmpty) title(5, _sectionLine);

    // header: one row (term-wise) or two (fee-type-wise: term over fee type)
    const h = 7;
    final two = feeLayout;
    final fixed = ['Sno', _secHead, AppText.admissionNo, 'Student Name'];
    for (var c = 0; c < fixed.length; c++) {
      text(c, h, fixed[c], hdr);
      if (two) text(c, h + 1, '', hdr);
    }
    for (var i = 0; i < cols.length; i++) {
      if (two) {
        text(4 + i, h, cols[i].top.isEmpty ? cols[i].head : cols[i].top, hdr);
        text(4 + i, h + 1, cols[i].top.isEmpty ? '' : cols[i].head, hdr);
      } else {
        text(4 + i, h, cols[i].single, hdr);
      }
    }
    text(lastCol, h, 'Remarks', hdr);
    if (two) text(lastCol, h + 1, '', hdr);
    sheet.setColumnWidth(0, 14);
    sheet.setColumnWidth(1, 12);
    sheet.setColumnWidth(2, 14);
    sheet.setColumnWidth(3, 30);
    for (var i = 0; i < cols.length; i++) {
      sheet.setColumnWidth(4 + i, 13);
    }
    sheet.setColumnWidth(lastCol, 14);

    var r = h + (two ? 2 : 1);
    for (final l in _lines) {
      final s = l.stu;
      if (s != null) {
        text(0, r, '${l.sno}');
        text(1, r, s.section);
        text(2, r, s.admNo);
        text(3, r, s.name);
        for (var i = 0; i < cols.length; i++) {
          amount(4 + i, r, cols[i].v(s));
        }
        if (s.remark.isNotEmpty) text(lastCol, r, s.remark);
      } else {
        // old: 'Total' in the Class column, 'ClsGrp Tot' / 'G.Total' in Sno
        if (l.kind == _Kind.section) {
          text(1, r, _subLabel(l), bold);
        } else {
          text(0, r, _subLabel(l), bold);
        }
        for (var i = 0; i < cols.length; i++) {
          amount(4 + i, r, l.sum(cols[i]), showZero: true, strong: true);
        }
      }
      r++;
    }
    text(0, r + 2, _note, bold);
  }

  Future<void> _exportPdf() async {
    if (_rows.isEmpty) return _snack('Nothing to export yet.', AppColors.warning);
    setState(() => _exporting = true);
    try {
      final cols = _columns(_feeLayout);
      String fmt(double v, bool zero) => _zero(v) && !zero ? '' : formatIndianNumber(v);
      final ok = await saveReportPdf(
        context,
        fileName: '${_fileStem}_${_feeLayout ? 'Feetypewise' : 'Term'}',
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: _title,
        subtitle: [_feeLine, if (_sectionLine.isNotEmpty) _sectionLine].join('     '),
        headers: [AppText.serialNo, _secHead, AppText.admissionNo, 'Student Name', ...cols.map((c) => c.single), 'Remarks'],
        rows: [
          for (final l in _lines)
            if (l.stu != null)
              ['${l.sno}', l.stu!.section, l.stu!.admNo, l.stu!.name, ...cols.map((c) => fmt(c.v(l.stu!), false)), l.stu!.remark]
            else
              [
                l.kind == _Kind.section ? '' : _subLabel(l),
                l.kind == _Kind.section ? _subLabel(l) : '',
                '',
                l.kind == _Kind.grand ? '' : l.label,
                ...cols.map((c) => fmt(l.sum(c), true)),
                '',
              ],
        ],
        rightAlign: {for (var i = 0; i < cols.length; i++) 4 + i},
        landscape: true,
        footNote: _note,
      );
      if (ok) _snack('Pending fee report PDF saved.', AppColors.success);
    } catch (e) {
      _snack(AppText.couldNot('build the PDF', friendlyError(e)), AppColors.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ── filters ──────────────────────────────────────────────────────────────
  /// A field-looking button that opens a tick list.
  Widget _pickerField(String hint, String label, bool filled, String icon, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        onTap: _running ? null : onTap,
        child: InputDecorator(
          decoration: AppUI.field(context, hint, filled: filled, leadingIcon: icon, suffix: Icon(Icons.arrow_drop_down, color: AppColors.ink3, size: 22.sp)),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.fieldText(context, filled: filled)),
        ),
      );

  /// Tick many: [groups] of (heading, items); a heading ticks its whole group.
  Future<Set<T>?> _pickMany<T>(String title, List<(String, List<(T, String)>)> groups, Set<T> current) {
    final draft = Set<T>.from(current);
    final all = [for (final g in groups) for (final i in g.$2) i.$1];
    return showDialog<Set<T>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Row(children: [
            Expanded(child: Text(title, style: AppUI.cardTitle)),
            TextButton(onPressed: () => setLocal(() => draft.addAll(all)), child: const Text('Select All')),
            TextButton(onPressed: () => setLocal(draft.clear), child: const Text(AppText.clear)),
          ]),
          content: SizedBox(
            width: 420.w,
            height: 420.h,
            child: all.isEmpty
                ? AppUI.empty(title: 'Nothing to choose from', why: 'There is nothing to choose for this filter yet.')
                : ListView(children: [
                    for (final g in groups) ...[
                      if (g.$1.isNotEmpty)
                        CheckboxListTile(
                          tristate: true,
                          value: g.$2.every((i) => draft.contains(i.$1)) ? true : (g.$2.any((i) => draft.contains(i.$1)) ? null : false),
                          onChanged: (_) => setLocal(() {
                            final on = g.$2.every((i) => draft.contains(i.$1));
                            for (final i in g.$2) {
                              on ? draft.remove(i.$1) : draft.add(i.$1);
                            }
                          }),
                          dense: true,
                          activeColor: AppColors.primary,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(g.$1, style: AppUI.label),
                        ),
                      for (final i in g.$2)
                        CheckboxListTile(
                          value: draft.contains(i.$1),
                          onChanged: (v) => setLocal(() => v == true ? draft.add(i.$1) : draft.remove(i.$1)),
                          dense: true,
                          activeColor: AppColors.primary,
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.only(left: g.$1.isEmpty ? 16 : 40, right: 16),
                          title: Text(i.$2, style: AppUI.body),
                        ),
                    ],
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
  }

  Future<void> _pickSections() async {
    final groups = [
      for (final c in _courses)
        (
          '${c['courname']}',
          [for (final k in _classes) if (_id(k['cour_id']) == _id(c['cour_id'])) (_id(k['cla_id'])!, '${k['claname']}')],
        ),
    ].where((g) => g.$2.isNotEmpty).toList();
    final picked = await _pickMany<int>(schoolTerm('Select Courses / Classes'), groups, _claIds);
    if (picked == null || !mounted) return;
    setState(() => _claIds
      ..clear()
      ..addAll(picked));
    _run();
  }

  Future<void> _pickFees() async {
    final picked = await _pickMany<String>('Select Fee Types', [('', [for (final f in _feeTypes) (f.$1, f.$1)])], _fees);
    if (picked == null || !mounted) return;
    setState(() => _fees
      ..clear()
      ..addAll(picked.length == _feeTypes.length ? const <String>{} : picked));
    _run();
  }

  String get _sectionLabel {
    if (_claIds.isEmpty) return schoolTerm('All Courses / Classes');
    if (_claIds.length == 1) {
      return '${_classes.firstWhere((c) => _id(c['cla_id']) == _claIds.first, orElse: () => const {})['claname'] ?? ''}';
    }
    return schoolTerm('${_claIds.length} classes selected');
  }

  String get _feeLabel => _fees.isEmpty ? 'All Fee Types' : (_fees.length == 1 ? _fees.first : '${_fees.length} fee types selected');

  /// One half of a two-way switch (layout).
  Widget _seg(String label, bool on, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: 14.w),
          decoration: BoxDecoration(
            color: on ? AppColors.primaryLight : AppColors.card,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: on ? AppColors.primary : AppColors.border),
          ),
          child: Text(label, style: AppUI.label.copyWith(color: on ? AppColors.primary : AppColors.textSecondary)),
        ),
      );

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _courses.isEmpty) {
      return AppUI.empty(
        title: 'Could not open the report',
        why: _error,
        icon: 'info-circle',
        action: OutlinedButton.icon(onPressed: _loadMasters, icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
      );
    }
    final cols = _columns(_feeLayout);
    double sum(double Function(_Stu) f) => _rows.fold(0.0, (t, s) => t + f(s));
    final sections = {for (final s in _rows) s.s['cla_id']}.length;

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppUI.cardHeader(
          icon: 'wallet-money',
          title: 'Pending Fee Report',
          subtitle: 'What each student still owes, term-wise or fee-type-wise, as on ${formatDmy(_asOf)}',
          trailing: [
            OutlinedButton.icon(
              style: AppUI.secondary(context),
              onPressed: _exporting || _rows.isEmpty ? null : _exportExcel,
              icon: const Icon(Icons.table_chart_outlined, size: 16),
              label: const Text(AppText.exportExcel),
            ),
            OutlinedButton.icon(
              style: AppUI.secondary(context),
              onPressed: _exporting || _rows.isEmpty ? null : _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: const Text(AppText.exportPdf),
            ),
          ],
        ),
        SizedBox(height: 16.h),
        // filters
        Row(children: [
          Expanded(flex: 4, child: _pickerField(schoolTerm('Course / Class'), _sectionLabel, _claIds.isNotEmpty, 'book-1', _pickSections)),
          SizedBox(width: 10.w),
          Expanded(flex: 4, child: _pickerField('Fee Type', _feeLabel, _fees.isNotEmpty, 'receipt-discount', _pickFees)),
          SizedBox(width: 10.w),
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              key: ValueKey('tc-$_tc'),
              initialValue: _tc,
              isExpanded: true,
              dropdownColor: AppColors.card,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              style: AppUI.fieldText(context, filled: _tc != 'WITHOUT'),
              decoration: AppUI.field(context, 'Students', filled: _tc != 'WITHOUT', leadingIcon: 'people'),
              items: [for (final m in _tcModes) DropdownMenuItem(value: m.$1, child: Text(m.$2, overflow: TextOverflow.ellipsis))],
              onChanged: _running
                  ? null
                  : (v) {
                      setState(() => _tc = v ?? 'WITHOUT');
                      _run();
                    },
            ),
          ),
          SizedBox(width: 10.w),
          OutlinedButton.icon(
            style: AppUI.secondary(context),
            onPressed: _running ? null : _run,
            icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
          ),
        ]),
        SizedBox(height: 10.h),
        Row(children: [
          Text('Layout', style: AppUI.label),
          SizedBox(width: 10.w),
          _seg('Term-wise', !_feeLayout, () => setState(() => _feeLayout = false)),
          SizedBox(width: 6.w),
          _seg('Fee-type-wise', _feeLayout, () => setState(() => _feeLayout = true)),
          SizedBox(width: 24.w),
          InkWell(
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            onTap: () => setState(() => _withArrear = !_withArrear),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: _withArrear, activeColor: AppColors.primary, onChanged: (v) => setState(() => _withArrear = v ?? false)),
              Text('With Arrear Detail', style: AppUI.label),
            ]),
          ),
          const Spacer(),
        ]),
        SizedBox(height: 16.h),
        // KPI tiles
        Row(children: [
          Expanded(child: AppUI.kpi(icon: 'people', label: 'Students', value: '${_rows.length}', sub: schoolTerm('in $sections ${sections == 1 ? 'class' : 'classes'}'))),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'receipt-2', label: 'Current Year Pending', value: '₹${formatIndianNumber(sum((s) => s.total))}', tint: AppColors.demand)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'calendar-1', label: 'Arrear Pending', value: '₹${formatIndianNumber(sum((s) => s.arrearTotal))}', sub: _years.isEmpty ? 'No arrears' : _years.join(', '), tint: AppColors.goldDark)),
          SizedBox(width: 12.w),
          Expanded(child: AppUI.kpi(icon: 'wallet-money', label: 'Net Pending', value: '₹${formatIndianNumber(sum((s) => s.net))}', tint: AppColors.warning)),
        ]),
        SizedBox(height: 16.h),
        Expanded(child: _table(cols)),
        SizedBox(height: 10.h),
        Text(
          _rows.isEmpty ? '' : '${AppUI.showing(1, _rows.length, _rows.length)} students · ${_fees.isEmpty ? 'All fee types' : _feeLabel} · $_note',
          style: AppUI.muted,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ]),
    );
  }

  Widget _table(List<_Col> cols) {
    if (_running && _rows.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_rows.isEmpty) {
      return AppUI.empty(
        title: 'Nothing pending',
        why: schoolTerm('No student owes anything for these filters. Select other classes, fee types or students.'),
        icon: 'wallet-money',
      );
    }
    const wSno = 70.0, wSec = 100.0, wAdm = 120.0, wName = 220.0, wAmt = 112.0, wRem = 120.0;
    final total = wSno + wSec + wAdm + wName + wAmt * cols.length + wRem + 32;
    final two = _feeLayout || cols.any((c) => c.top.isNotEmpty);

    Widget cell(String t, double width, {bool right = false, TextStyle? style}) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Text(t, textAlign: right ? TextAlign.right : TextAlign.left, maxLines: 1, overflow: TextOverflow.ellipsis, style: style ?? AppUI.cell),
          ),
        );
    Widget head(String top, String text, double width, {bool right = false}) => SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.w),
            child: Column(crossAxisAlignment: right ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (two) Text(top.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.tableHead.copyWith(color: AppColors.goldDark)),
              Text(text.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: right ? TextAlign.right : TextAlign.left, style: AppUI.tableHead),
            ]),
          ),
        );
    String fmt(double v, bool zero) => _zero(v) && !zero ? '' : formatIndianNumber(v);
    final strongMoney = AppUI.money.copyWith(fontWeight: FontWeight.w800);

    Widget lineRow(_Line l) {
      final s = l.stu;
      if (s != null) {
        return Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 8.h),
          child: Row(children: [
            cell('${l.sno}', wSno, style: AppUI.muted),
            cell(s.section, wSec),
            SizedBox(width: wAdm, child: Padding(padding: EdgeInsets.symmetric(horizontal: 8.w), child: Align(alignment: Alignment.centerLeft, child: AppUI.admTag(s.admNo, size: 11.5)))),
            cell(s.tc ? '${s.name}  (TC)' : s.name, wName, style: s.tc ? AppUI.cell.copyWith(color: AppColors.textLight) : null),
            for (final c in cols)
              cell(fmt(c.v(s), false), wAmt, right: true, style: c.strong ? (c.head == 'Net Total' ? strongMoney.copyWith(color: AppColors.warning) : strongMoney) : AppUI.money),
            SizedBox(width: wRem, child: Padding(padding: EdgeInsets.symmetric(horizontal: 8.w), child: s.remark.isEmpty ? const SizedBox.shrink() : Align(alignment: Alignment.centerLeft, child: AppUI.chip(s.remark, AppStatus.info)))),
          ]),
        );
      }
      final bg = l.kind == _Kind.section ? AppColors.sunken : AppColors.primarySoft;
      final labelText = '${_subLabel(l)} · ${l.label}';
      return Container(
        decoration: BoxDecoration(color: bg, border: const Border(bottom: BorderSide(color: AppColors.border))),
        padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 9.h),
        child: Row(children: [
          cell(labelText, wSno + wSec + wAdm + wName, style: AppUI.label.copyWith(color: l.kind == _Kind.standard ? AppColors.primary : AppColors.textPrimary)),
          for (final c in cols) cell(fmt(l.sum(c), true), wAmt, right: true, style: strongMoney),
          const SizedBox(width: wRem),
        ]),
      );
    }

    final grand = _lines.isNotEmpty && _lines.last.kind == _Kind.grand ? _lines.last : null;
    final body = grand == null ? _lines : _lines.sublist(0, _lines.length - 1);

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
                          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 10.h),
                          child: Row(children: [
                            head('', AppText.serialNo, wSno),
                            head('', _secHead, wSec),
                            head('', AppText.admissionNo, wAdm),
                            head('', 'Student Name', wName),
                            for (final c in cols) head(c.top, c.head, wAmt, right: true),
                            head('', 'Remarks', wRem),
                          ]),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: _vCtrl,
                            itemCount: body.length,
                            itemBuilder: (_, i) => lineRow(body[i]),
                          ),
                        ),
                        if (grand != null)
                          Container(
                            decoration: const BoxDecoration(color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
                            padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 12.h),
                            child: Row(children: [
                              cell(_subLabel(grand), wSno + wSec + wAdm + wName, style: AppUI.label),
                              for (final c in cols) cell(fmt(grand.sum(c), true), wAmt, right: true, style: strongMoney),
                              const SizedBox(width: wRem),
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
