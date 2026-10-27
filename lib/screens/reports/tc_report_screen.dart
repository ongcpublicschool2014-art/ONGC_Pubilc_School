import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../services/supabase_service.dart';
import '../../utils/app_theme.dart';
import '../../utils/app_text.dart';
import '../../utils/auth_provider.dart';
import '../../utils/class_sort.dart';
import '../../utils/friendly_error.dart';
import '../../utils/report_pdf_export.dart';
import '../../utils/school_terms.dart';
import '../../widgets/app_ui.dart';

/// TRANSFER CERTIFICATE PROVIDED DETAILS REPORT — every TC issued in a date
/// range: TC No, TC Date, Reg No, Student Name, Class and Join Date.
///
/// Six fixed columns, so no field picker: unlike the Admission Register this
/// report has always been the same six, and a chooser would be a control that
/// only ever has one setting.
///
/// Read from tc_entry, which is the record of what was ISSUED. A student's
/// current row in students/admission says whether they have left; tc_entry says
/// which certificate said so, when, and what class they were in at the time —
/// and that is what a register of certificates has to show, even after the
/// student's class or name is later corrected.
class TcReportScreen extends StatefulWidget {
  const TcReportScreen({super.key});

  @override
  State<TcReportScreen> createState() => _TcReportScreenState();
}

String _s(Object? v) => (v ?? '').toString().trim();

/// 'yyyy-MM-dd...' -> 'dd-MM-yyyy'.
String _d(Object? v) {
  final s = _s(v);
  if (s.length < 10) return '';
  return '${s.substring(8, 10)}-${s.substring(5, 7)}-${s.substring(0, 4)}';
}

class _TcReportScreenState extends State<TcReportScreen> {
  int get _insId => context.read<AuthProvider>().insId ?? 1;

  bool _loading = true;
  bool _running = false;   // exporting
  bool _counting = false;  // reloading after a filter change
  String? _loadError;

  /// What the screen shows and what Export writes -- the same rows.
  List<Map<String, dynamic>> _rows = [];

  List<Map<String, dynamic>> _courseRows = [];
  List<Map<String, dynamic>> _classRows = [];

  String _insName = '';
  String _insAddress = '';
  String _insCity = '';

  /// The active academic year. The report is always this year's certificates,
  /// so there is nothing to pick: tc_entry stamps the year on the row.
  String _yearLabel = '';
  int? _yearId;

  String? _course;
  String? _class;

  /// The sample report reads class by class, so that is the default.
  String _orderKey = 'class';

  @override
  void initState() {
    super.initState();
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
            .select('cour_id, courname, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        SupabaseService.fromSchema('class')
            .select('claname, cour_id, ordid')
            .eq('ins_id', insId)
            .eq('activestatus', 1),
        SupabaseService.getInstitutionInfo(insId),
        SupabaseService.client
            .from('institutionyear')
            .select('iyr_id, yrlabel')
            .eq('ins_id', insId)
            .eq('activestatus', 1)
            .order('iyr_id', ascending: false)
            .limit(1),
      ]);
      if (!mounted) return;
      final info = res[2] as ({String? name, String? logo, String? address, String? mobile, String? email});
      final years = res[3] as List;
      setState(() {
        _courseRows = List<Map<String, dynamic>>.from(res[0] as List)
          ..sort((a, b) => _s(a['courname']).compareTo(_s(b['courname'])));
        _classRows = List<Map<String, dynamic>>.from(res[1] as List);
        _insName = info.name ?? '';
        // Address comes back as one string; the printed report has always put
        // the city on its own line, so the last comma-separated part goes there.
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
        if (years.isNotEmpty) {
          _yearLabel = _s(years.first['yrlabel']);
          _yearId = (years.first['iyr_id'] as num?)?.toInt();
        }
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

  List<String> get _courseNames =>
      _courseRows.map((e) => _s(e['courname'])).where((s) => s.isNotEmpty).toList();

  /// Classes of the chosen course, TC batches last (utils/class_sort.dart).
  List<String> get _classNames {
    final courId = _course == null
        ? null
        : _courseRows.firstWhere((c) => _s(c['courname']) == _course,
            orElse: () => const <String, dynamic>{})['cour_id'];
    return classGroupPartition(
        _classRows
            .where((c) => courId == null || c['cour_id'] == courId)
            .map((e) => _s(e['claname']))
            .where((s) => s.isNotEmpty),
        (s) => s);
  }

  void _snack(String m, Color c) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: c));
  }

  /// Reload and show. A failed load leaves the last good list on screen and
  /// says what went wrong, rather than blanking it.
  Future<void> _refresh() async {
    if (_yearId == null && _yearLabel.isEmpty) return;
    setState(() => _counting = true);
    try {
      final rows = await _load();
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (e) {
      if (mounted) _snack('Could not load the TC report. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _counting = false);
    }
  }

  Future<void> _run({required bool pdf}) async {
    if (_rows.isEmpty) {
      _snack('No transfer certificates to export.', AppColors.warning);
      return;
    }
    setState(() => _running = true);
    if (pdf) {
      await _exportPdf();
    } else {
      await _export2();
    }
  }

  Future<void> _exportPdf() async {
    try {
      String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final scope = _s(_class).isNotEmpty
          ? safe(_class!)
          : _s(_course).isNotEmpty
              ? safe(_course!)
              : 'All';
      final ok = await saveReportPdf(
        context,
        fileName: 'TC_Report_${scope}_${safe(_yearLabel)}',
        insName: _insName,
        insAddress: _insAddress,
        insCity: _insCity,
        title: 'TRANSFER CERTIFICATES ISSUED',
        subtitle: 'Academic Year: $_yearLabel',
        headers: ['TC No.', 'TC Date', schoolTerm('Register No.'), 'Student Name', schoolTerm('Class'), AppText.dateOfAdmission],
        rows: [
          for (final r in _rows)
            [
              _s(r['tcno']),
              _d(r['tcdate']),
              _s(r['stuadmno']),
              _s(r['stuname']),
              _s(r['stuclass']),
              _d(r['joindate']),
            ],
        ],
        landscape: false,
        footNote: 'Total: ${_rows.length} transfer certificate(s)',
      );
      if (ok) _snack('TC report saved as PDF (${_rows.length} certificates).', AppColors.success);
    } catch (e) {
      _snack('Could not create the TC report PDF. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Every certificate issued in the active year, filtered and sorted.
  Future<List<Map<String, dynamic>>> _load() async {
      final insId = _insId;
      // fetchAll: a year of certificates can pass the 1000-row cap, and a
      // truncated register of TCs would look complete.
      final rows = List<Map<String, dynamic>>.from(
          await SupabaseService.fetchAll(() => SupabaseService
              .fromSchema('tc_entry')
              .select('tc_id, tcno, tcdate, stuadmno, stuname, stuclass, joindate')
              .eq('ins_id', insId)
              .eq('activestatus', 1)
              // Either stamp identifies the year: a row written by an older
              // build may carry the label without the id, or the other way
              // round, and missing certificates would be invisible.
              .or([
                if (_yearId != null) 'yr_id.eq.$_yearId',
                if (_yearLabel.isNotEmpty) 'yrlabel.eq.$_yearLabel',
              ].join(','))));

      // Only rows that actually carry a number. tc_entry is append-only, so
      // re-activating a student appends a row with no tcno -- that is a
      // cancellation, not a certificate, and it does not belong in a register
      // of certificates issued.
      var out = rows.where((r) => _s(r['tcno']).isNotEmpty).toList();

      // Course narrows by the classes that belong to it: tc_entry records the
      // class, not the course.
      if (_s(_class).isNotEmpty) {
        out = out.where((r) => _s(r['stuclass']) == _class).toList();
      } else if (_s(_course).isNotEmpty) {
        final allowed = _classNames.map((c) => c.toUpperCase()).toSet();
        out = out.where((r) => allowed.contains(_s(r['stuclass']).toUpperCase())).toList();
      }



      String keyOf(Map<String, dynamic> r) {
        switch (_orderKey) {
          case 'tcno':
            return _s(r['tcno']);
          case 'admno':
            return _s(r['stuadmno']);
          case 'stuname':
            return _s(r['stuname']);
          default:
            return _s(r['stuclass']);
        }
      }

      // Ties break on reg no so the same range prints the same way every time.
      out.sort((a, b) {
        final c = keyOf(a).toUpperCase().compareTo(keyOf(b).toUpperCase());
        return c != 0 ? c : _s(a['stuadmno']).compareTo(_s(b['stuadmno']));
      });

      return out;
  }

  Future<void> _export2() async {
    try {
      await _export(_rows);
    } catch (e) {
      _snack('Could not create the Excel file. ${friendlyError(e)}', AppColors.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _export(List<Map<String, dynamic>> rows) async {
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final scope = _s(_class).isNotEmpty
        ? safe(_class!)
        : _s(_course).isNotEmpty
            ? safe(_course!)
            : 'All';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save TC Report',
      fileName: 'TC_Report_${scope}_${safe(_yearLabel)}.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (path == null) return;

    final book = xl.Excel.createExcel();
    final sheet = book['TC Report'];
    book.delete('Sheet1');

    final bold = xl.CellStyle(bold: true, fontSize: 11);
    final hdr = xl.CellStyle(
      bold: true,
      fontSize: 10,
      backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
      fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
    );

    void put(int col, int row, String text, [xl.CellStyle? style]) {
      final c = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));
      c.value = xl.TextCellValue(text);
      if (style != null) c.cellStyle = style;
    }

    put(2, 0, _insName.toUpperCase(), bold);
    if (_insAddress.isNotEmpty) put(2, 1, _insAddress.toUpperCase(), bold);
    if (_insCity.isNotEmpty) put(2, 2, _insCity.toUpperCase(), bold);
    put(2, 3, 'TRANSFER CERTIFICATES ISSUED', bold);
    put(2, 4, 'Academic Year: $_yearLabel', bold);

    final headers = ['TC No.', 'TC Date', schoolTerm('Register No.'), 'Student Name', schoolTerm('Class'), AppText.dateOfAdmission];
    const headerRow = 6;
    for (var c = 0; c < headers.length; c++) {
      put(c, headerRow, headers[c], hdr);
      sheet.setColumnWidth(c, c == 3 ? 30 : 16);
    }

    var r = headerRow + 2;
    for (final row in rows) {
      put(0, r, _s(row['tcno']));
      put(1, r, _d(row['tcdate']));
      put(2, r, _s(row['stuadmno']));
      put(3, r, _s(row['stuname']));
      put(4, r, _s(row['stuclass']));
      put(5, r, _d(row['joindate']));
      r++;
    }
    put(0, r + 1, 'Total: ${rows.length} transfer certificate(s)', bold);

    final bytes = book.encode();
    if (bytes == null) throw Exception('Could not build the Excel file');
    await File(path).writeAsBytes(bytes);
    _snack('TC report saved as Excel (${rows.length} certificates).', AppColors.success);
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return AppUI.empty(
        title: schoolTerm('Could not load courses and classes'),
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
                icon: 'document-text',
                title: 'TC Report',
                subtitle: 'Transfer certificates issued in the current academic year',
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
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: _labeled('Academic Year', InputDecorator(
                    decoration: _dec('').copyWith(enabled: false),
                    child: Text(_yearLabel.isEmpty ? 'No active academic year' : _yearLabel,
                        style: _yearLabel.isEmpty
                            ? AppUI.fieldText(context).copyWith(color: AppColors.error)
                            : AppUI.fieldText(context, filled: true)),
                  )),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: _labeled('Sort By', DropdownButtonFormField<String>(
                    initialValue: _orderKey,
                    isExpanded: true,
                    isDense: true,
                    decoration: _dec(''),
                    style: AppUI.fieldText(context),
                    items: [
                      DropdownMenuItem(value: 'class', child: Text(schoolTerm('Class'))),
                      const DropdownMenuItem(value: 'tcno', child: Text('TC No.')),
                      DropdownMenuItem(value: 'admno', child: Text(schoolTerm('Register No.'))),
                      const DropdownMenuItem(value: 'stuname', child: Text('Student Name')),
                    ],
                    onChanged: (v) {
                      setState(() => _orderKey = v ?? 'class');
                      _refresh();
                    },
                  )),
                ),
              ]),
              SizedBox(height: 10.h),
              Row(children: [
                Expanded(
                  child: _labeled(schoolTerm('Course'), DropdownButtonFormField<String?>(
                    key: ValueKey('tccourse-${_course ?? ''}'),
                    initialValue: _courseNames.contains(_course) ? _course : null,
                    isExpanded: true,
                    isDense: true,
                    decoration: _dec(schoolTerm('All Courses')),
                    style: AppUI.fieldText(context),
                    items: [
                      DropdownMenuItem<String?>(value: null, child: Text(schoolTerm('All Courses'))),
                      ..._courseNames.map((e) => DropdownMenuItem<String?>(
                          value: e, child: Text(e, overflow: TextOverflow.ellipsis))),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _course = v;
                        _class = null;
                      });
                      _refresh();
                    },
                  )),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: _labeled(schoolTerm('Class'), DropdownButtonFormField<String?>(
                    key: ValueKey('tcclass-${_class ?? ''}-${_course ?? ''}'),
                    initialValue: _classNames.contains(_class) ? _class : null,
                    isExpanded: true,
                    isDense: true,
                    decoration: _dec(schoolTerm('All Classes')),
                    style: AppUI.fieldText(context),
                    items: [
                      DropdownMenuItem<String?>(value: null, child: Text(schoolTerm('All Classes'))),
                      ..._classNames.map((e) => DropdownMenuItem<String?>(
                          value: e, child: Text(e, overflow: TextOverflow.ellipsis))),
                    ],
                    onChanged: (v) {
                      setState(() => _class = v);
                      _refresh();
                    },
                  )),
                ),
                SizedBox(width: 12.w),
                const Expanded(child: SizedBox.shrink()),
              ]),
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
                  schoolTerm('Every transfer certificate issued in the current academic year, '
                  'with the class and date of admission as they stood when the certificate was issued.'),
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
    Widget cell(String s, {int flex = 0, double? width, bool bold = false}) {
      final child = Text(bold ? s.toUpperCase() : s,
          overflow: TextOverflow.ellipsis,
          style: bold ? AppUI.tableHead : AppUI.cell);
      return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
    }

    List<Widget> row(String tcno, String tcdate, String reg, String name, String cls, String join,
            {bool bold = false}) =>
        [
          cell(tcno, width: 110.w, bold: bold),
          cell(tcdate, width: 100.w, bold: bold),
          cell(reg, width: 140.w, bold: bold),
          cell(name, flex: 3, bold: bold),
          cell(cls, flex: 2, bold: bold),
          cell(join, width: 140.w, bold: bold),
        ];

    return Container(
      decoration: AppUI.card(),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          decoration: AppUI.tableHeadBar,
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
          child: Row(
              children: row('TC No.', 'TC Date', schoolTerm('Register No.'), 'Student Name', schoolTerm('Class'), AppText.dateOfAdmission,
                  bold: true)),
        ),
        const Divider(height: 1),
        Expanded(
          child: _counting
              ? const Center(child: CircularProgressIndicator())
              : _rows.isEmpty
                  ? AppUI.empty(
                      title: 'No transfer certificates found',
                      why: schoolTerm('None were issued in $_yearLabel for these filters. Try another course or class above.'),
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
                              children: row(
                                  _s(r['tcno']),
                                  _d(r['tcdate']),
                                  _s(r['stuadmno']),
                                  _s(r['stuname']),
                                  _s(r['stuclass']),
                                  _d(r['joindate']))),
                        );
                      },
                    ),
        ),
        const Divider(height: 1),
        Container(
          color: AppColors.tableHeadBg,
          padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
          child: Text('${_rows.length} transfer certificate(s)', style: AppUI.label),
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

  Widget _labeled(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppUI.fieldLabel(label),
          child,
        ],
      );
}
