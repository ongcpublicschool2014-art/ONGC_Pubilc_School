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
import '../../utils/friendly_error.dart';
import '../../utils/report_pdf_export.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';

/// ADMISSION ABSTRACT — how many students each course has admitted, split by
/// sex, as at a date. One row per course, then a grand total.
///
/// The counting companion to the Admission Register: the register lists the
/// students, this counts them. Both are kept.
class AdmissionAbstractScreen extends StatefulWidget {
  const AdmissionAbstractScreen({super.key});

  @override
  State<AdmissionAbstractScreen> createState() => _AdmissionAbstractScreenState();
}

String _s(Object? v) => (v ?? '').toString().trim();

/// One printed line.
class _Row {
  _Row(this.course);
  final String course;
  int male = 0;
  int female = 0;
  int other = 0;
  int get total => male + female + other;
}

class _AdmissionAbstractScreenState extends State<AdmissionAbstractScreen> {
  int get _insId => context.read<AuthProvider>().insId ?? 1;

  bool _loading = true;
  bool _running = false;   // exporting
  bool _counting = false;  // recounting after a filter change
  String? _loadError;

  /// What the screen shows and what Export writes -- the same rows, so the
  /// sheet can never disagree with the figures that were read off the screen.
  List<_Row> _rows = [];

  List<Map<String, dynamic>> _courseRows = [];
  String _insName = '';
  String _insAddress = '';
  String _insCity = '';
  String _yearLabel = '';

  /// The same range the Register uses, so the two tabs agree.
  late DateTime _from;
  late DateTime _to;

  /// 'NEW' counts admissions taken between From and To; 'ACTIVE' counts who is
  /// on the rolls now, whenever they were admitted. Same split as the Register
  /// tab, because the two tabs answer the same question at different detail.
  String _mode = 'NEW';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, 5, 6);
    if (now.isBefore(_from)) _from = DateTime(now.year - 1, 5, 6);
    _to = DateTime(_from.year + 1, 5, 5);
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
        SupabaseService.fromSchema('course')
            .select('courname, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        SupabaseService.getInstitutionInfo(insId),
        SupabaseService.client
            .from('institutionyear')
            .select('yrlabel, iyr_id')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('iyr_id', ascending: false)
            .limit(1),
      ]);
      if (!mounted) return;
      final info = res[1] as ({String? name, String? logo, String? address, String? mobile, String? email});
      final years = res[2] as List;
      setState(() {
        // Course order is the master's own (ordid), which is the order the
        // printed abstract has always used -- not alphabetical.
        _courseRows = List<Map<String, dynamic>>.from(res[0] as List)
          ..sort((a, b) {
            final oa = (a['ordid'] as num?)?.toInt() ?? 9999;
            final ob = (b['ordid'] as num?)?.toInt() ?? 9999;
            return oa != ob ? oa.compareTo(ob) : _s(a['courname']).compareTo(_s(b['courname']));
          });
        _insName = info.name ?? '';
        final parts = (info.address ?? '')
            .replaceAll('\n', ', ')
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.length > 1) {
          _insCity = parts.removeLast();
          _insAddress = parts.join(', ');
        } else {
          _insAddress = parts.join(', ');
          _insCity = '';
        }
        _yearLabel = years.isNotEmpty ? _s(years.first['yrlabel']) : '';
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

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _dmy(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  /// Recount and show. Never throws into the UI: a failed count leaves the
  /// last good figures on screen and says what went wrong.
  Future<void> _refresh() async {
    setState(() => _counting = true);
    try {
      final rows = await _count();
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (e) {
      if (mounted) _snack('Could not count the admissions. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _counting = false);
    }
  }

  Future<void> _run({required bool pdf}) async {
    if (_rows.isEmpty) {
      _snack('Nothing to export yet.', AppColors.warning);
      return;
    }
    setState(() => _running = true);
    if (pdf) {
      await _runExportPdf();
    } else {
      await _runExport();
    }
  }

  Future<void> _runExportPdf() async {
    try {
      final anyOther = _rows.any((r) => r.other > 0);
      var m = 0, f = 0, o = 0;
      for (final r in _rows) {
        m += r.male;
        f += r.female;
        o += r.other;
      }
      String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final ok = await saveReportPdf(
        context,
        fileName: 'Admission_Abstract_${safe(_dmy(_from))}_${safe(_dmy(_to))}',
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: 'ADMISSION ABSTRACT',
        subtitle: '${_mode == 'NEW' ? 'From : ${_dmy(_from)}  To : ${_dmy(_to)}' : 'Students on the rolls'}'
            '${_yearLabel.isEmpty ? '' : '   Academic Year : $_yearLabel'}',
        headers: [
          AppText.serialNo,
          schoolTerm('Course'),
          'Male',
          'Female',
          if (anyOther) 'Other',
          'Total',
        ],
        rows: [
          for (var i = 0; i < _rows.length; i++)
            [
              '${i + 1}',
              _rows[i].course,
              '${_rows[i].male}',
              '${_rows[i].female}',
              if (anyOther) '${_rows[i].other}',
              '${_rows[i].total}',
            ],
          // The total belongs in the table, not in a note: on a two-page
          // abstract a note under the grid lands on the last page alone.
          ['', 'TOTAL', '$m', '$f', if (anyOther) '$o', '${m + f + o}'],
        ],
        rightAlign: {for (var i = 2; i < (anyOther ? 6 : 5); i++) i},
        landscape: false,
      );
      if (ok) _snack('Admission abstract PDF saved.', AppColors.success);
    } catch (e) {
      _snack('Could not build the abstract PDF. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// One half of the New admissions / Active students switch. Changing it
  /// re-counts immediately -- the abstract is a single number per course and
  /// there is nothing to press.
  Widget _modeSeg(String label, String value) {
    final on = _mode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      onTap: () {
        if (_mode == value) return;
        setState(() => _mode = value);
        _refresh();
      },
      child: Container(
        constraints: BoxConstraints(minHeight: AppUI.controlHeight(context)),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: 12.w),
        decoration: BoxDecoration(
          color: on ? AppColors.primaryLight : Colors.white,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: on ? AppColors.primary : AppColors.border),
        ),
        child: Text(label,
            style: AppUI.label.copyWith(color: on ? AppColors.primary : AppColors.textSecondary)),
      ),
    );
  }

  /// The counting itself: every admission on or before the As-on date, folded
  /// into one line per course.
  Future<List<_Row>> _count() async {
      final insId = _insId;
      // fetchAll: a whole year of admissions is well past the 1000-row cap, and
      // a truncated count is a wrong count that looks right.
      var q = SupabaseService.client
          .from('admission')
          .select('courname, stugender, admno')
          .eq('ins_id', insId)
          .eq('activestatus', 1);
      // The date window belongs to the admissions count only -- "who is here"
      // is not a period.
      if (_mode == 'NEW') {
        q = q.gte('admdate', _ymd(_from)).lte('admdate', _ymd(_to));
      }
      var rows = List<Map<String, dynamic>>.from(
          await SupabaseService.fetchAll(() => q));

      // ACTIVE: keep the admissions whose student is still on this year's
      // rolls, counted from the year schema rather than from admission.
      if (_mode == 'ACTIVE') {
        final onRoll = <String>{};
        final stu = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('students')
            .select('stuadmno')
            .eq('ins_id', insId)
            .eq('activestatus', 1));
        for (final r in stu) {
          final k = _s(r['stuadmno']);
          if (k.isNotEmpty) onRoll.add(k);
        }
        rows = rows.where((r) => onRoll.contains(_s(r['admno']))).toList();
      }

      // Start from the course master so the abstract lists courses in the
      // master's order, then fold in any course name that appears only on the
      // admissions -- an imported record whose course was never set up still
      // has to be counted somewhere rather than vanish from the totals.
      final byCourse = <String, _Row>{};
      for (final c in _courseRows) {
        final name = _s(c['courname']);
        if (name.isNotEmpty) byCourse[name.toUpperCase()] = _Row(name);
      }
      for (final r in rows) {
        final name = _s(r['courname']);
        final key = name.isEmpty ? '(NO COURSE)' : name.toUpperCase();
        final row = byCourse.putIfAbsent(key, () => _Row(name.isEmpty ? schoolTerm('(no course)') : name));
        switch (_s(r['stugender']).toUpperCase()) {
          case 'M':
            row.male++;
          case 'F':
            row.female++;
          default:
            // Anything else -- 'T', or a record with no sex recorded. Counted,
            // and shown in its own column when it happens, so Male + Female
            // always adds up to Total on the sheet.
            row.other++;
        }
      }

      // Courses with nobody admitted in the range are left out: a page of
      // zeroes buries the courses that actually ran.
      return byCourse.values.where((r) => r.total > 0).toList();
    }

  Future<void> _runExport() async {
    try {
      await _export(_rows);
    } catch (e) {
      _snack('Could not build the abstract. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _export(List<_Row> rows) async {
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Admission Abstract',
      fileName: 'Admission_Abstract_${safe(_dmy(_from))}_${safe(_dmy(_to))}.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (path == null) return;

    final book = xl.Excel.createExcel();
    final sheet = book['Admission Abstract'];
    book.delete('Sheet1');

    final bold = xl.CellStyle(bold: true, fontSize: 11);
    final hdr = xl.CellStyle(
      bold: true,
      fontSize: 10,
      backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
    );
    final totalStyle = xl.CellStyle(bold: true, fontSize: 10);

    void put(int col, int row, String text, [xl.CellStyle? style]) {
      final c = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
      c.value = xl.TextCellValue(text);
      if (style != null) c.cellStyle = style;
    }

    put(0, 0, _insName.toUpperCase(), bold);
    if (_insAddress.isNotEmpty) put(0, 1, _insAddress.toUpperCase(), bold);
    if (_insCity.isNotEmpty) put(0, 2, _insCity.toUpperCase(), bold);
    put(0, 3,
        '${_mode == 'NEW' ? 'ADMISSION ABSTRACT FROM : ${_dmy(_from)}  TO : ${_dmy(_to)}' : 'ADMISSION ABSTRACT — STUDENTS ON THE ROLLS'}'
        '${_yearLabel.isEmpty ? '' : '   Academic Year : $_yearLabel'}',
        bold);

    // The Other column earns its place only when something is in it, so a
    // normal abstract is the same four columns it has always been.
    final anyOther = rows.any((r) => r.other > 0);
    final headers = <String>[
      AppText.serialNo,
      schoolTerm('Course'),
      'Male',
      'Female',
      if (anyOther) 'Other',
      'Total',
    ];
    const headerRow = 5;
    for (var c = 0; c < headers.length; c++) {
      put(c, headerRow, headers[c], hdr);
      sheet.setColumnWidth(c, c == 1 ? 34 : (c == 0 ? 8 : 12));
    }

    var r = headerRow + 1;
    var m = 0, f = 0, o = 0;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      m += row.male;
      f += row.female;
      o += row.other;
      var c = 0;
      put(c++, r, '${i + 1}');
      put(c++, r, row.course);
      put(c++, r, '${row.male}');
      put(c++, r, '${row.female}');
      if (anyOther) put(c++, r, '${row.other}');
      put(c, r, '${row.total}');
      r++;
    }

    var c = 0;
    put(c++, r, '', totalStyle);
    put(c++, r, 'TOTAL', totalStyle);
    put(c++, r, '$m', totalStyle);
    put(c++, r, '$f', totalStyle);
    if (anyOther) put(c++, r, '$o', totalStyle);
    put(c, r, '${m + f + o}', totalStyle);

    final bytes = book.encode();
    if (bytes == null) throw Exception('Could not build the Excel file');
    await File(path).writeAsBytes(bytes);
    _snack(schoolTerm('Admission abstract saved — ${rows.length} courses, ${m + f + o} students.'),
        AppColors.success);
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
            onPressed: _loadMasters,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry')),
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
                icon: 'chart-2',
                title: 'Admission Abstract',
                subtitle: schoolTerm('Students admitted per course, split by sex'),
              ),
            ),
            _exportBtn(
              onPressed: () => _run(pdf: false),
              icon: Icons.table_chart_rounded,
              label: AppText.exportExcel,
            ),
            SizedBox(width: AppBtn.gap(context)),
            _exportBtn(
              onPressed: () => _run(pdf: true),
              icon: Icons.picture_as_pdf_rounded,
              label: AppText.exportPdf,
            ),
          ]),
          SizedBox(height: 14.h),
          Container(
            padding: EdgeInsets.all(AppUI.cardPad),
            decoration: AppUI.card(),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: IgnorePointer(
                  ignoring: _mode != 'NEW',
                  child: Opacity(
                    opacity: _mode == 'NEW' ? 1 : 0.45,
                    child: _dateField('From Date', _from, (d) {
                      setState(() => _from = d);
                      _refresh();
                    }),
                  ),
                ),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: IgnorePointer(
                  ignoring: _mode != 'NEW',
                  child: Opacity(
                    opacity: _mode == 'NEW' ? 1 : 0.45,
                    child: _dateField('To Date', _to, (d) {
                      setState(() => _to = d);
                      _refresh();
                    }),
                  ),
                ),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Row(children: [
                  _modeSeg('New Admissions', 'NEW'),
                  SizedBox(width: 8.w),
                  _modeSeg('Active Students', 'ACTIVE'),
                ]),
              ),
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
                  schoolTerm('${_mode == 'NEW' ? 'Counts every admission dated between From and To' : 'Counts everyone on the rolls this year, whenever they were admitted'}'
                  '${_yearLabel.isEmpty ? '' : ', academic year $_yearLabel'}. '
                  'Courses follow the master’s own order, and a course found only on an '
                  'admission record is still counted.'),
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

  /// The abstract on screen. The Other column appears only when something is
  /// in it, so Male + Female always adds up to Total on a normal sheet.
  Widget _table() {
    final anyOther = _rows.any((r) => r.other > 0);
    var m = 0, f = 0, o = 0;
    for (final r in _rows) {
      m += r.male;
      f += r.female;
      o += r.other;
    }

    Widget cell(String s, {int flex = 0, double? width, bool bold = false, bool right = false, bool head = false}) {
      final child = Text(head ? s.toUpperCase() : s,
          textAlign: right ? TextAlign.right : TextAlign.left,
          overflow: TextOverflow.ellipsis,
          style: head ? AppUI.tableHead : (bold ? AppUI.money : AppUI.cell));
      return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
    }

    List<Widget> row(String no, String course, String male, String female, String other, String total,
        {bool bold = false, bool head = false}) =>
        [
          cell(no, width: 44.w, bold: bold, head: head),
          cell(course, flex: 4, bold: bold, head: head),
          cell(male, width: 80.w, bold: bold, right: true, head: head),
          cell(female, width: 80.w, bold: bold, right: true, head: head),
          if (anyOther) cell(other, width: 80.w, bold: bold, right: true, head: head),
          cell(total, width: 90.w, bold: bold, right: true, head: head),
        ];

    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          decoration: AppUI.tableHeadBar,
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
          child: Row(children: row(AppText.serialNo, schoolTerm('Course'), 'Male', 'Female', 'Other', 'Total', head: true)),
        ),
        const Divider(height: 1),
        Expanded(
          child: _counting
              ? const Center(child: CircularProgressIndicator())
              : _rows.isEmpty
                  ? AppUI.empty(
                      title: 'No admissions between ${_dmy(_from)} and ${_dmy(_to)}.',
                      why: 'Widen the From Date and To Date above, or switch to Active Students.',
                    )
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: _rows.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (_, i) {
                        final r = _rows[i];
                        return Container(
                          color: i.isOdd ? AppColors.surface : Colors.white,
                          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 9.h),
                          child: Row(
                              children: row('${i + 1}', r.course, '${r.male}', '${r.female}',
                                  '${r.other}', '${r.total}')),
                        );
                      },
                    ),
        ),
        const Divider(height: 1),
        Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
          child: Row(children: row('', 'TOTAL', '$m', '$f', '$o', '${m + f + o}', bold: true)),
        ),
      ]),
    );
  }


  /// The app's export button: the themed solid button, sized through AppBtn
  /// so it matches every other button. Disabled while an export is running.
  Widget _exportBtn({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
  }) {
    return SizedBox(
      height: AppBtn.height(context),
      child: ElevatedButton.icon(
        onPressed: _running ? null : onPressed,
        icon: _running
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(icon, size: AppBtn.iconSize(context)),
        label: Text(label),
      ),
    );
  }

  InputDecoration _dec(String hint) => AppUI.field(context, hint);

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
              decoration: _dec('').copyWith(
                suffixIcon: Icon(Icons.calendar_today_outlined, size: 15.sp, color: AppColors.textSecondary),
              ),
              child: Text(_dmy(value), style: AppUI.fieldText(context)),
            ),
          ),
        ],
      );
}
