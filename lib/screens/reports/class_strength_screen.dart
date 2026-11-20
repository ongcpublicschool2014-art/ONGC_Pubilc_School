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
import '../../utils/excel_theme.dart';
import '../../utils/friendly_error.dart';
import '../../utils/report_pdf_export.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';
import '../../utils/save_path.dart';

/// CLASS STRENGTH (with TC) — per standard and section, for a period:
///
///   Opening Strength  students admitted before From who had not left before it
///   New Admission     students admitted between From and To
///   TC Issued         students whose TC is dated between From and To
///   Total             Opening + New − TC: the strength at the end of the period
///
/// One line per section, a Total line per standard, and a G.Total at the end
/// -- the old system's "Strength with Tc" sheet. Counts this year's students
/// (the year schema), in the section they are in now.
class ClassStrengthScreen extends StatefulWidget {
  const ClassStrengthScreen({super.key});

  @override
  State<ClassStrengthScreen> createState() => _ClassStrengthScreenState();
}

String _s(Object? v) => (v ?? '').toString().trim();
int _n(Object? v) => v is num ? v.toInt() : (int.tryParse(_s(v)) ?? 0);

/// 'yyyy-MM-dd...' as a date (no time); null when blank.
DateTime? _date(Object? v) {
  final s = _s(v);
  if (s.length < 10) return null;
  return DateTime.tryParse(s.substring(0, 10));
}

/// One section's line.
class _Sec {
  _Sec(this.group, this.section);
  final String group;
  final String section;
  int opening = 0;
  int admitted = 0;
  int tc = 0;
  int get total => opening + admitted - tc;
  bool get isEmpty => opening == 0 && admitted == 0 && tc == 0;
}

/// A standard: its sections and their sum.
class _Group {
  _Group(this.name);
  final String name;
  final List<_Sec> sections = [];
  int get opening => sections.fold(0, (a, s) => a + s.opening);
  int get admitted => sections.fold(0, (a, s) => a + s.admitted);
  int get tc => sections.fold(0, (a, s) => a + s.tc);
  int get total => opening + admitted - tc;
}

class _ClassStrengthScreenState extends State<ClassStrengthScreen> {
  int get _insId => context.read<AuthProvider>().insId ?? 1;

  bool _loading = true;
  bool _running = false; // exporting
  bool _counting = false; // recounting after a date change
  String? _loadError;

  /// What the screen shows and what Export writes.
  List<_Group> _groups = [];

  List<Map<String, dynamic>> _courses = [];
  List<Map<String, dynamic>> _classes = [];
  String _insName = '';
  String _insAddress = '';

  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    // The academic year signed into: 1 April to 31 March, as the old sheet.
    final label = context.read<AuthProvider>().yearLabel ?? '';
    final start = int.tryParse(label.length >= 4 ? label.substring(0, 4) : '');
    final now = DateTime.now();
    final y = start ?? (now.month >= 4 ? now.year : now.year - 1);
    _from = DateTime(y, 4, 1);
    _to = DateTime(y + 1, 3, 31);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMasters());
  }

  Future<void> _loadMasters() async {
    final auth = context.read<AuthProvider>();
    if (auth.schema != null && auth.schema!.isNotEmpty) {
      SupabaseService.setSchema(auth.schema);
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final insId = _insId;
      final res = await Future.wait<dynamic>([
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', insId),
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id, ordid').eq('ins_id', insId),
        SupabaseService.getInstitutionInfo(insId),
      ]);
      if (!mounted) return;
      final info = res[2] as ({String? name, String? logo, String? address, String? mobile, String? email});
      setState(() {
        _courses = List<Map<String, dynamic>>.from(res[0] as List);
        _classes = List<Map<String, dynamic>>.from(res[1] as List);
        _insName = info.name ?? '';
        _insAddress = (info.address ?? '')
            .replaceAll('\n', ', ')
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .join(', ');
        _loading = false;
      });
      _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = friendlyError(e);
      });
    }
  }

  String _dmy(DateTime d, [String sep = '-']) =>
      '${d.day.toString().padLeft(2, '0')}$sep${d.month.toString().padLeft(2, '0')}$sep${d.year}';

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  Future<void> _refresh() async {
    if (_to.isBefore(_from)) {
      _snack('The To date is before the From date. Select a To date on or after the From date.', AppColors.warning);
      return;
    }
    setState(() => _counting = true);
    try {
      final groups = await _count();
      if (!mounted) return;
      setState(() => _groups = groups);
    } catch (e) {
      if (mounted) _snack('Could not count the class strength. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _counting = false);
    }
  }

  Future<List<_Group>> _count() async {
    final insId = _insId;
    final students = await SupabaseService.fetchAll(() => SupabaseService
        .fromSchema('students')
        .select('stuadmno, stuadmdate, cla_id, stuclass, courname, activestatus, preadmission')
        .eq('ins_id', insId));

    // TC date per reg no: the latest TC row decides (a re-activation appends a
    // row with status 1 and no TC no., which cancels the earlier TC).
    final tcDate = <String, DateTime?>{};
    try {
      final tcRows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('tc_entry')
          .select('stuadmno, tcno, tcdate, tc_id, status')
          .eq('ins_id', insId)
          .eq('activestatus', 1));
      final latest = <String, Map<String, dynamic>>{};
      for (final t in tcRows) {
        final k = _s(t['stuadmno']).toUpperCase();
        if (k.isEmpty) continue;
        final prev = latest[k];
        if (prev == null || _n(t['tc_id']) > _n(prev['tc_id'])) latest[k] = t;
      }
      latest.forEach((k, t) {
        if (_s(t['tcno']).isNotEmpty && _n(t['status']) != 1) tcDate[k] = _date(t['tcdate']);
      });
    } catch (_) {
      // No tc_entry on this schema: nobody has a TC, which is the honest count.
    }

    // Masters: course and class order (ordid), class -> its standard.
    final courseById = {for (final c in _courses) _n(c['cour_id']): c};
    final classById = {for (final c in _classes) _n(c['cla_id']): c};
    final classByName = {for (final c in _classes) _s(c['claname']).toUpperCase(): c};

    final secs = <String, _Sec>{}; // key: GROUP|SECTION
    _Sec secFor(String group, String section) =>
        secs.putIfAbsent('${group.toUpperCase()}|${section.toUpperCase()}', () => _Sec(group, section));

    final from = DateTime(_from.year, _from.month, _from.day);
    final to = DateTime(_to.year, _to.month, _to.day);
    for (final st in students) {
      if (_n(st['preadmission']) == 1) continue; // next year's intake
      final adm = _date(st['stuadmdate']);
      final key = _s(st['stuadmno']).toUpperCase();
      final hasTc = tcDate.containsKey(key);
      final tc = tcDate[key];
      // Not on the rolls and no TC: removed, not a strength figure.
      if (!hasTc && _n(st['activestatus']) != 1) continue;
      if (adm != null && adm.isAfter(to)) continue; // joined after the period
      if (hasTc && tc != null && tc.isBefore(from)) continue; // left before it

      final cls = classById[_n(st['cla_id'])] ?? classByName[_s(st['stuclass']).toUpperCase()];
      final section = cls != null ? _s(cls['claname']) : _s(st['stuclass']);
      final course = cls != null ? courseById[_n(cls['cour_id'])] : null;
      final group = course != null ? _s(course['courname']) : _s(st['courname']);
      final sec = secFor(group.isEmpty ? '-' : group, section.isEmpty ? '-' : section);

      if (adm == null || adm.isBefore(from)) {
        sec.opening++;
      } else {
        sec.admitted++;
      }
      if (hasTc && tc != null && !tc.isAfter(to)) sec.tc++;
    }

    // Standards in the course master's order, sections in the class master's.
    int courseOrd(String name) {
      for (final c in _courses) {
        if (_s(c['courname']).toUpperCase() == name.toUpperCase()) return _n(c['ordid']);
      }
      return 1 << 20;
    }

    final classOrd = <String, int>{
      for (final c in _classes) _s(c['claname']).toUpperCase(): _n(c['ordid']),
    };
    final byGroup = <String, _Group>{};
    for (final s in secs.values.where((s) => !s.isEmpty)) {
      byGroup.putIfAbsent(s.group.toUpperCase(), () => _Group(s.group)).sections.add(s);
    }
    final groups = byGroup.values.toList()
      ..sort((a, b) {
        final c = courseOrd(a.name).compareTo(courseOrd(b.name));
        return c != 0 ? c : classCompare(a.name, b.name);
      });
    final cmp = classOrdidComparator(classOrd);
    for (final g in groups) {
      g.sections.sort((a, b) => cmp(a.section, b.section));
    }
    return groups;
  }

  // ── Export ────────────────────────────────────────────────────────────────

  String get _periodLine => 'PERIOD : ${_dmy(_from, '/')} TO ${_dmy(_to, '/')}';
  static const _title = 'CLASS STRENGTH REPORT';
  String get _fileBase {
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return 'Class_Strength_${safe(_dmy(_from))}_${safe(_dmy(_to))}';
  }

  List<String> get _headers =>
      [schoolTerm('Class Group'), schoolTerm('Class'), 'Opening Strength', 'New Admission', 'TC Issued', 'Total'];

  /// Every printed line, in order: sections, a Total per standard, G.Total.
  /// kind: 's' section, 't' standard total, 'g' grand total.
  List<(String kind, List<String> cells)> get _lines {
    final out = <(String, List<String>)>[];
    var o = 0, a = 0, t = 0;
    for (final g in _groups) {
      for (var i = 0; i < g.sections.length; i++) {
        final s = g.sections[i];
        out.add(('s', [i == 0 ? g.name : '', s.section, '${s.opening}', '${s.admitted}', '${s.tc}', '${s.total}']));
      }
      out.add(('t', ['Total', '', '${g.opening}', '${g.admitted}', '${g.tc}', '${g.total}']));
      o += g.opening;
      a += g.admitted;
      t += g.tc;
    }
    out.add(('g', ['G.Total', '', '$o', '$a', '$t', '${o + a - t}']));
    return out;
  }

  Future<void> _run({required bool pdf}) async {
    if (_groups.isEmpty) {
      _snack('Nothing to export yet.', AppColors.warning);
      return;
    }
    setState(() => _running = true);
    try {
      if (pdf) {
        final ok = await saveReportPdf(
          context,
          fileName: _fileBase,
          insName: _insName,
          insAddress: _insAddress,
          insCity: '',
          title: _title,
          subtitle: _periodLine,
          headers: _headers,
          rows: [for (final l in _lines) l.$2],
          rightAlign: const {2, 3, 4, 5},
          landscape: false,
        );
        if (ok) _snack('Class strength PDF saved.', AppColors.success);
      } else {
        await _export();
      }
    } catch (e) {
      _snack('Could not build the class strength report. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// The old sheet's layout: name / address / title merged across A:F on rows
  /// 2-4, the period on row 6, the header on row 8, then the lines.
  Future<void> _export() async {
    final path = await pickSavePath(
      dialogTitle: 'Save Class Strength Report',
      fileName: '$_fileBase.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (path == null) return;

    final book = xl.Excel.createExcel();
    final sheet = book['Class Strength'];
    book.delete('Sheet1');

    final centre = xl.CellStyle(bold: true, fontSize: 11, horizontalAlign: xl.HorizontalAlign.Center);
    final bold = xl.CellStyle(bold: true, fontSize: 11);
    final hdr = xl.CellStyle(
      bold: true,
      fontSize: 10,
      backgroundColorHex: XlTheme.headerBg,
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
    );
    xl.CellIndex at(int c, int r) => xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r);

    void text(int c, int r, String v, [xl.CellStyle? style]) {
      final cell = sheet.cell(at(c, r));
      cell.value = xl.TextCellValue(v);
      if (style != null) cell.cellStyle = style;
    }

    void heading(int r, String v) {
      text(0, r, v, centre);
      sheet.merge(at(0, r), at(5, r));
    }

    heading(1, _insName.toUpperCase());
    if (_insAddress.isNotEmpty) heading(2, _insAddress.toUpperCase());
    heading(3, _title);
    text(0, 5, _periodLine, bold);

    const headerRow = 7;
    final widths = [14.0, 12.0, 18.0, 15.0, 11.0, 10.0];
    for (var c = 0; c < _headers.length; c++) {
      text(c, headerRow, _headers[c], hdr);
      sheet.setColumnWidth(c, widths[c]);
    }

    var r = headerRow + 1;
    for (final (kind, cells) in _lines) {
      final style = kind == 's' ? null : bold;
      text(0, r, cells[0], style);
      text(1, r, cells[1], style);
      for (var c = 2; c < 6; c++) {
        final cell = sheet.cell(at(c, r));
        cell.value = xl.IntCellValue(int.parse(cells[c]));
        if (style != null) cell.cellStyle = style;
      }
      r++;
    }

    final bytes = book.encode();
    if (bytes == null) throw Exception('Could not build the Excel file');
    await File(path).writeAsBytes(bytes);
    _snack('Class strength report saved.', AppColors.success);
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return AppUI.empty(
        title: 'Could not load the master data.',
        why: _loadError,
        action: OutlinedButton.icon(
            onPressed: _loadMasters, icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
      );
    }

    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: AppUI.cardHeader(
                icon: 'people',
                title: 'Class Strength',
                subtitle: schoolTerm('Opening strength, new admissions and TCs per section'),
              ),
            ),
            _exportBtn(onPressed: () => _run(pdf: false), icon: Icons.table_chart_rounded, label: AppText.exportExcel),
            SizedBox(width: AppBtn.gap(context)),
            _exportBtn(onPressed: () => _run(pdf: true), icon: Icons.picture_as_pdf_rounded, label: AppText.exportPdf),
          ]),
          SizedBox(height: 14.h),
          Container(
            padding: EdgeInsets.all(AppUI.cardPad),
            decoration: AppUI.card(),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: _dateField('From Date', _from, (d) {
                  setState(() => _from = d);
                  _refresh();
                }),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: _dateField('To Date', _to, (d) {
                  setState(() => _to = d);
                  _refresh();
                }),
              ),
              SizedBox(width: 12.w),
              const Expanded(child: SizedBox()),
            ]),
          ),
          SizedBox(height: AppUI.gap),
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
                  schoolTerm('Opening = admitted before From. New Admission = admitted between From and To. '
                      'TC Issued = TC dated between From and To. Total = Opening + New Admission − TC Issued. '
                      'Students are counted in the section they are in now.'),
                  style: AppUI.muted.copyWith(color: AppColors.textSecondary, height: 1.35),
                ),
              ),
            ]),
          ),
          SizedBox(height: 12.h),
          Expanded(child: _table()),
        ],
      ),
    );
  }

  Widget _table() {
    Widget cell(String s, {int flex = 0, double? width, bool bold = false, bool right = false, bool head = false}) {
      final child = Text(head ? s.toUpperCase() : s,
          textAlign: right ? TextAlign.right : TextAlign.left,
          overflow: TextOverflow.ellipsis,
          style: head ? AppUI.tableHead : (bold ? AppUI.money : AppUI.cell));
      return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
    }

    List<Widget> row(List<String> v, {bool bold = false, bool head = false}) => [
          cell(v[0], flex: 3, bold: bold, head: head),
          cell(v[1], flex: 3, bold: bold, head: head),
          cell(v[2], flex: 2, bold: bold, right: true, head: head),
          cell(v[3], flex: 2, bold: bold, right: true, head: head),
          cell(v[4], flex: 2, bold: bold, right: true, head: head),
          cell(v[5], flex: 2, bold: bold, right: true, head: head),
        ];

    final lines = _groups.isEmpty ? <(String, List<String>)>[] : _lines;
    final body = lines.where((l) => l.$1 != 'g').toList();
    final grand = lines.isEmpty ? null : lines.last;

    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          decoration: AppUI.tableHeadBar,
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
          child: Row(children: row(_headers, head: true)),
        ),
        const Divider(height: 1),
        Expanded(
          child: _counting
              ? const Center(child: CircularProgressIndicator())
              : body.isEmpty
                  ? AppUI.empty(
                      title: 'No students between ${_dmy(_from)} and ${_dmy(_to)}.',
                      why: 'Widen the From Date and To Date above.',
                    )
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: body.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (_, i) {
                        final (kind, cells) = body[i];
                        final total = kind == 't';
                        return Container(
                          color: total ? AppColors.primaryTint : Colors.white,
                          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
                          child: Row(children: row(cells, bold: total)),
                        );
                      },
                    ),
        ),
        if (grand != null && !_counting) ...[
          const Divider(height: 1),
          Container(
            color: AppColors.tableHeadBg,
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
            child: Row(children: row(grand.$2, bold: true)),
          ),
        ],
      ]),
    );
  }

  Widget _exportBtn({required VoidCallback onPressed, required IconData icon, required String label}) {
    return SizedBox(
      height: AppBtn.height(context),
      child: ElevatedButton.icon(
        onPressed: _running || _counting ? null : onPressed,
        icon: _running
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(icon, size: AppBtn.iconSize(context)),
        label: Text(label),
      ),
    );
  }

  Widget _dateField(String label, DateTime value, ValueChanged<DateTime> onPick) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppUI.fieldLabel(label),
          InkWell(
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            onTap: () async {
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
              child: Text(_dmy(value), style: AppUI.fieldText(context)),
            ),
          ),
        ],
      );
}
