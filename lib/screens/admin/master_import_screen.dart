import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:file_picker/file_picker.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/pill_tab.dart';
import 'package:excel/excel.dart' as xl;
import '../../utils/app_text.dart';
import '../../utils/app_theme.dart';
import '../../services/supabase_service.dart';
import 'package:provider/provider.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';
import '../../utils/formatters.dart';
import '../../utils/school_terms.dart';

void _showImportResultDialog(BuildContext context, {required int imported, required int skipped, List<String> errors = const [], VoidCallback? onDone}) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Center(
      child: Container(
        width: 420.w,
        padding: EdgeInsets.all(32.w),
        decoration: AppUI.card(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(errors.isEmpty ? 'tick-circle' : 'warning-2', size: 64.sp, color: errors.isEmpty ? AppColors.success : AppColors.error),
            SizedBox(height: 16.h),
            Text(errors.isEmpty ? 'Import Complete' : 'Import Completed with Errors', style: AppUI.cardTitle),
            SizedBox(height: 12.h),
            Text('$imported imported successfully, $skipped skipped', style: AppUI.body),
            if (errors.isNotEmpty) ...[
              SizedBox(height: 16.h),
              Container(
                height: 150.h,
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  color: AppColors.errorBg,
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                ),
                child: ListView(
                  children: errors.map((e) => Padding(
                    padding: EdgeInsets.only(bottom: 4.h),
                    child: Text(e, style: AppUI.body.copyWith(color: AppColors.error)),
                  )).toList(),
                ),
              ),
            ],
            SizedBox(height: 20.h),
            ElevatedButton(
              onPressed: () { Navigator.pop(ctx); onDone?.call(); },
              child: const Text(AppText.close),
            ),
          ],
        ),
      ),
    ),
  );
}

class MasterImportScreen extends StatefulWidget {
  final int initialTabIndex;
  final bool showInternalTabs;
  const MasterImportScreen({super.key, this.initialTabIndex = 0, this.showInternalTabs = true});
  @override
  State<MasterImportScreen> createState() => _MasterImportScreenState();
}

class _MasterImportScreenState extends State<MasterImportScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    // 10 tabs: 9 master-data tabs shown in the pill bar + a hidden Fee Collection
    // import tab (index 9), reached only via the "Fee Collection Import" menu.
    _tabCtrl = TabController(length: 11, vsync: this, initialIndex: _startIndex(widget.initialTabIndex));
  }

  /// A school has no Admission Type / Quota (tabs 0 and 1): when the pill bar
  /// is shown, start on the first tab it actually offers. Indexes are kept as
  /// they are -- callers open this importer at fixed tab indexes.
  int _startIndex(int requested) {
    final i = requested.clamp(0, 10);
    return (isSchool && widget.showInternalTabs && i < 2) ? 2 : i;
  }

  @override
  void didUpdateWidget(covariant MasterImportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTabIndex != oldWidget.initialTabIndex) {
      final i = _startIndex(widget.initialTabIndex);
      if (_tabCtrl.index != i) _tabCtrl.animateTo(i);
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tabs (pill style, same as Reports) - hidden when driven by sidebar sub-menu
        if (widget.showInternalTabs)
          ListenableBuilder(
            listenable: _tabCtrl,
            builder: (context, _) {
              final selected = _tabCtrl.index;
              final tabLabels = ['Admission Type', 'Quota', 'Course', 'Class', 'Fee Group', 'Fee Type', 'Concession', 'Class Fee Demand', 'Semester', 'Community'];
              final tabIcons = ['teacher', 'book-1', 'category-2', 'receipt-1', 'receipt-discount', 'note-2', 'user-tick', 'ticket', 'calendar-1', 'people'];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: // Wrap, not a horizontal scroll view: the row can run past the
              // window on a laptop screen, and a horizontal
              // SingleChildScrollView has no scrollbar and ignores the mouse
              // wheel on desktop, leaving the last tabs unreachable.
              Wrap(
                spacing: PillTab.gap(context),
                runSpacing: 8,
                children: [
                  for (var i = 0; i < tabLabels.length; i++)
                    // Admission Type / Quota (0, 1) do not exist on a school.
                    if (!(isSchool && i < 2))
                    PillTab(
                      icon: tabIcons[i],
                      label: schoolTerm(tabLabels[i]),
                      selected: selected == i,
                      onTap: () => _tabCtrl.animateTo(i),
                    ),
                ],
              ),
              );
            },
          ),
        // Content (white card)
        Expanded(
          child: Container(
            decoration: AppCard.decoration(),
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.only(top: widget.showInternalTabs ? 8 : 0),
            child: TabBarView(
              controller: _tabCtrl,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // Kept in place on a school (as empty) so every tab index stays put.
                if (isSchool) const SizedBox.shrink() else const _AdmissionTypeTab(),
                if (isSchool) const SizedBox.shrink() else const _QuotaTab(),
                const _CourseTab(),
                const _ClassTab(),
                const _FeeGroupTab(),
                const _FeeTypeTab(),
                const _ConcessionTab(),
                const _ClassFeeDemandTab(),
                const _SemesterTab(),
                const _CommunityTab(),
                const _FeeCollectionImportTab(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// STAGING TABLE IMPORT HELPER
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

Future<Map<String, int>> _stagingImport({
  required int insId,
  required String impType,
  required List<List<dynamic>> rows,
  required int colCount,
}) async {
  // 1. Clear old pending rows
  await SupabaseService.client.from('master_import').delete().eq('ins_id', insId).eq('imp_type', impType).eq('status', 'PENDING');

  // 2. Bulk insert into staging table in batches of 500
  for (int i = 0; i < rows.length; i += 500) {
    final batch = rows.sublist(i, (i + 500).clamp(0, rows.length));
    final records = batch.map((row) {
      final map = <String, dynamic>{
        'imp_type': impType,
        'ins_id': insId,
      };
      for (int c = 0; c < colCount; c++) {
        final val = c < row.length ? row[c].toString().trim() : '';
        map['col${c + 1}'] = val.isEmpty ? null : val;
      }
      return map;
    }).toList();
    await SupabaseService.client.from('master_import').insert(records);
  }

  // 3. Call processing function
  final result = await SupabaseService.client.rpc('process_master_import', params: {'p_ins_id': insId});
  final list = result is List ? result : [result];
  final r = list.isNotEmpty ? list.first : {};
  return {
    'total': r['total'] ?? 0,
    'imported': r['imported'] ?? 0,
    'skipped': r['skipped'] ?? 0,
  };
}

Future<List<String>> _getImportErrors(int insId, String impType) async {
  final errors = await SupabaseService.client
      .from('master_import')
      .select('imp_id, error_msg')
      .eq('ins_id', insId)
      .eq('imp_type', impType)
      .eq('status', 'ERROR')
      .order('imp_id')
      .limit(20);
  return (errors as List).map((e) => 'Row ${e['imp_id']}: ${_friendlyError(e['error_msg']?.toString() ?? 'Unknown error')}').toList();
}

/// Readable names for the database columns the staging import can report
/// as empty (display only).
const Map<String, String> _importColumnLabels = {
  'fg_id': 'Fee Group',
  'fgdesc': 'Group Name',
  'fee_id': 'Fee ID',
  'feedesc': 'Fee Name',
  'feeshort': 'Short Name',
  'feefineapplicable': 'Fine Applicable',
  'con_id': 'Concession ID',
  'condesc': 'Concession Name',
  'yr_id': 'Academic Year',
  'yrlabel': 'Academic Year',
};

String _friendlyError(String msg) {
  final m = msg.toLowerCase();
  if (m.contains('duplicate key') || m.contains('unique constraint')) return 'Duplicate record found';
  if (m.contains('not-null') || m.contains('null value')) {
    final match = RegExp(r'column "(\w+)"').firstMatch(msg);
    final field = _importColumnLabels[match?.group(1)];
    return field == null ? 'A required field is empty' : '$field is required';
  }
  if (m.contains('foreign key') || m.contains('fkey')) return 'Invalid reference - check linked values';
  if (m.contains('check constraint')) return 'Invalid value format';
  if (m.contains('value too long')) return 'Value too long for the field';
  if (m.contains('invalid input syntax')) {
    // Preserve the type and the offending value so users can see WHICH cell.
    final typeMatch = RegExp(r'invalid input syntax for type (\w+):\s*"([^"]*)"').firstMatch(msg);
    if (typeMatch != null) {
      return 'Invalid ${typeMatch.group(1)}: "${typeMatch.group(2)}"';
    }
    return 'Invalid data format';
  }
  if (m.contains('permission denied')) return 'Permission denied';
  return msg.length > 120 ? '${msg.substring(0, 120)}...' : msg;
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// GENERIC HELPERS
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

List<List<dynamic>> _parseExcel(String path) {
  final bytes = File(path).readAsBytesSync();

  // CSV as well as .xlsx. Every picker on this screen offers 'csv' alongside
  // 'xlsx' and 'xls', but this used to hand the bytes straight to
  // Excel.decodeBytes whatever they were, so choosing a .csv always came back
  // as "Could not read file. Something went wrong" -- the one message that
  // says nothing about what is wrong. A CSV is also the only format a script
  // can reliably produce for this screen, since the Dart excel package cannot
  // read a workbook written by most other tools.
  if (path.toLowerCase().endsWith('.csv')) {
    var text = utf8.decode(bytes, allowMalformed: true);
    // Strip a BOM: Excel writes one when saving as "CSV UTF-8", and it would
    // otherwise ride along on the first header and stop it matching.
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
    return const CsvToListConverter(shouldParseNumbers: false, eol: '\n')
        .convert(text.replaceAll('\r\n', '\n'))
        .map((r) => r.map((c) => c?.toString().trim() ?? '').toList())
        .toList();
  }

  final excel = xl.Excel.decodeBytes(bytes);
  final sheet = excel.tables[excel.tables.keys.first]!;
  return sheet.rows.map((r) => r.map((c) => c?.value?.toString().trim() ?? '').toList()).toList();
}

Future<void> _exportSampleData(String sheetName, List<String> headers, List<List<String>> sampleRows) async {
  final savePath = await FilePicker.platform.saveFile(
    dialogTitle: 'Save Sample Data',
    fileName: '${schoolTerm(sheetName).toLowerCase().replaceAll(' ', '_')}_sample.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (savePath == null) return;
  final workbook = xl.Excel.createExcel();
  final sheet = workbook[schoolTerm(sheetName)];
  final headerStyle = xl.CellStyle(
    bold: true,
    backgroundColorHex: xl.ExcelColor.fromHexString('#1B2A4A'),
    fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
  );
  for (int i = 0; i < headers.length; i++) {
    final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    cell.value = xl.TextCellValue(schoolTerm(headers[i]));
    cell.cellStyle = headerStyle;
    sheet.setColumnWidth(i, 20);
  }
  for (int r = 0; r < sampleRows.length; r++) {
    for (int c = 0; c < sampleRows[r].length; c++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
      cell.value = xl.TextCellValue(sampleRows[r][c]);
    }
  }
  workbook.delete('Sheet1');
  final bytes = workbook.encode();
  if (bytes != null) File(savePath).writeAsBytesSync(bytes);
}

/// Re-export the loaded import rows with an extra "Error" column populated
/// for failed rows, plus red shading on the offending cells. Use this when
/// validation surfaces problems so the user can fix them in Excel and
/// re-import the corrected file.
Future<void> _exportRowsWithErrors({
  required String sheetName,
  required List<String> headers,
  required List<List<dynamic>> rows,
  required Map<int, Set<int>> cellErrors,
  required Map<int, String> rowErrors,
}) async {
  final savePath = await FilePicker.platform.saveFile(
    dialogTitle: 'Save File with Errors',
    fileName: '${schoolTerm(sheetName).toLowerCase().replaceAll(' ', '_')}_errors.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (savePath == null) return;
  final workbook = xl.Excel.createExcel();
  final sheet = workbook[schoolTerm(sheetName)];
  final headerStyle = xl.CellStyle(
    bold: true,
    backgroundColorHex: xl.ExcelColor.fromHexString('#1B2A4A'),
    fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
  );
  final errorCellStyle = xl.CellStyle(
    backgroundColorHex: xl.ExcelColor.fromHexString('#FCE4E4'),
  );
  final allHeaders = [...headers, 'Error'];
  for (int i = 0; i < allHeaders.length; i++) {
    final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    cell.value = xl.TextCellValue(schoolTerm(allHeaders[i]));
    cell.cellStyle = headerStyle;
    sheet.setColumnWidth(i, i == allHeaders.length - 1 ? 40 : 20);
  }
  for (int r = 0; r < rows.length; r++) {
    final row = rows[r];
    final errs = cellErrors[r] ?? const <int>{};
    for (int c = 0; c < headers.length; c++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
      cell.value = xl.TextCellValue(c < row.length ? row[c].toString() : '');
      if (errs.contains(c)) cell.cellStyle = errorCellStyle;
    }
    final errorCell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: headers.length, rowIndex: r + 1));
    errorCell.value = xl.TextCellValue(schoolTerm(rowErrors[r] ?? ''));
    if (errs.isNotEmpty) errorCell.cellStyle = errorCellStyle;
  }
  workbook.delete('Sheet1');
  final bytes = workbook.encode();
  if (bytes != null) File(savePath).writeAsBytesSync(bytes);
}

Future<void> _exportTemplate(String sheetName, List<String> headers) async {
  final savePath = await FilePicker.platform.saveFile(
    dialogTitle: 'Save Template',
    fileName: '${schoolTerm(sheetName).toLowerCase().replaceAll(' ', '_')}_template.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (savePath == null) return;
  final workbook = xl.Excel.createExcel();
  final sheet = workbook[schoolTerm(sheetName)];
  final headerStyle = xl.CellStyle(
    bold: true,
    backgroundColorHex: xl.ExcelColor.fromHexString('#1B2A4A'),
    fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
  );
  for (int i = 0; i < headers.length; i++) {
    final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    cell.value = xl.TextCellValue(schoolTerm(headers[i]));
    cell.cellStyle = headerStyle;
    sheet.setColumnWidth(i, 18);
  }
  workbook.delete('Sheet1');
  final bytes = workbook.encode();
  if (bytes != null) File(savePath).writeAsBytesSync(bytes);
}

/// Convert per-row error messages into per-cell column indices by parsing
/// the canonical patterns the tabs emit:
///   - "Missing: A, B"  â†’ highlight headers matching A and B (case-insensitive)
///   - "Fee Group "X" not found ..."  â†’ highlight the "Fee Group" header
///   - "Class ID "X" not found ..."   â†’ highlight the "Class ID" header
///   - Otherwise no specific cell is flagged (icon only).
Map<int, Set<int>> _deriveCellErrors(Map<int, String> rowErrs, List<String> headers) {
  String hnorm(String s) => s.replaceAll('*', '').trim().toLowerCase();
  final headerNorm = headers.map(hnorm).toList();
  int? headerIndexFor(String token) {
    final t = token.toLowerCase();
    for (int i = 0; i < headerNorm.length; i++) {
      if (headerNorm[i] == t) return i;
    }
    for (int i = 0; i < headerNorm.length; i++) {
      if (headerNorm[i].contains(t) || t.contains(headerNorm[i])) return i;
    }
    return null;
  }
  final out = <int, Set<int>>{};
  for (final entry in rowErrs.entries) {
    final msg = entry.value;
    final cells = <int>{};
    final missing = RegExp(r'Missing:\s*([^*]+)').firstMatch(msg);
    if (missing != null) {
      for (final raw in missing.group(1)!.split(',')) {
        final idx = headerIndexFor(raw.trim());
        if (idx != null) cells.add(idx);
      }
    }
    // "Course ID must be a whole number" -> highlight the "Course ID" header.
    for (final m in RegExp(r'(?:^|\.\s+)([A-Za-z ]+?) must be').allMatches(msg)) {
      final idx = headerIndexFor(m.group(1)!.trim());
      if (idx != null) cells.add(idx);
    }
    for (final m in RegExp(r'^([A-Za-z ]+?)\s*"').allMatches(msg)) {
      final idx = headerIndexFor(m.group(1)!.trim());
      if (idx != null) cells.add(idx);
    }
    if (cells.isNotEmpty) out[entry.key] = cells;
  }
  return out;
}

Widget _gridHeaderCell(String text, {double? width, int flex = 1, bool center = false, bool right = false}) {
  final child = Container(
    padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 12.h),
    alignment: right ? Alignment.centerRight : center ? Alignment.center : Alignment.centerLeft,
    child: Text(schoolTerm(text).toUpperCase(), style: AppUI.tableHead),
  );
  return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
}

Widget _gridHeaderDivider() {
  return Container(width: 1, height: 36.h, color: AppColors.divider);
}

Widget _gridDataCell(String text, {double? width, int flex = 1, bool center = false, bool right = false}) {
  final child = Container(
    padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 10.h),
    alignment: right ? Alignment.centerRight : center ? Alignment.center : Alignment.centerLeft,
    decoration: BoxDecoration(
      border: Border(right: BorderSide(color: AppColors.divider)),
    ),
    child: Text(text, style: AppUI.cell, overflow: TextOverflow.ellipsis),
  );
  return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
}

Widget _buildImportCard({
  required String title,
  required List<String> headers,
  required List<List<dynamic>> rows,
  required VoidCallback onBrowse,
  required VoidCallback? onSave,
  required VoidCallback onTemplate,
  required bool saving,
  String savingLabel = 'Saving...',
  String? fileName,
  int imported = 0,
  int skipped = 0,
  List<String> errors = const [],
  bool showResult = false,
  VoidCallback? onDismissResult,
  VoidCallback? onValidate,
  VoidCallback? onClose,
  bool isValidated = false,
  List<List<dynamic>> existingRows = const [],
  List<String> existingHeaders = const [],
  bool isLoadingExisting = false,
  VoidCallback? onSampleDownload,
  Map<int, String> rowErrors = const {},
  // rowIdx â†’ set of column indices that failed validation. When non-empty,
  // the Format to Excel button switches to "Export with Errors" so the user
  // can fix issues offline and re-import.
  Map<int, Set<int>> cellErrors = const {},
  Set<int> rightAlignCols = const {},
}) {
  final bool showExisting = rows.isEmpty && existingRows.isNotEmpty;
  // Existing-records headers are display only, so they read in school terms;
  // the import grid keeps the file's own header names.
  final displayHeaders = showExisting ? existingHeaders.map(schoolTerm).toList() : headers;
  final displayRows = showExisting ? existingRows : rows;
  final bool hasCellErrors = !showExisting && cellErrors.isNotEmpty;
  // Sits inside the screen's white AppCard, so no second border here.
  return Container(
    padding: EdgeInsets.all(AppUI.cardPad),
    color: Colors.white,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title bar
        Row(
          children: [
            AppUI.iconTile('document-upload'),
            SizedBox(width: 12.w),
            Text(schoolTerm(title), style: AppUI.cardTitle),
            const Spacer(),
            if (fileName != null)
              Text(fileName, style: AppUI.muted),
            SizedBox(width: 12.w),
            ElevatedButton.icon(
              onPressed: onBrowse,
              icon: AppIcon('document-upload', size: 16, color: Colors.white),
              label: const Text('Import'),
            ),
            SizedBox(width: 8.w),
            OutlinedButton.icon(
              onPressed: hasCellErrors
                  ? () => _exportRowsWithErrors(
                        sheetName: title,
                        headers: headers,
                        rows: rows,
                        cellErrors: cellErrors,
                        rowErrors: rowErrors,
                      )
                  : onTemplate,
              icon: AppIcon(hasCellErrors ? 'document-download' : 'grid-1', size: 16, color: AppColors.primary),
              label: Text(hasCellErrors ? 'Export with Errors' : AppText.downloadTemplate),
            ),
            if (onSampleDownload != null) ...[
              SizedBox(width: 8.w),
              OutlinedButton.icon(
                onPressed: onSampleDownload,
                icon: AppIcon('document-download', size: 16, color: AppColors.primary),
                label: const Text(AppText.downloadSample),
              ),
            ],
          ],
        ),
        if (showResult) ...[
          SizedBox(height: 8.h),
          Container(
            padding: EdgeInsets.all(10.w),
            decoration: BoxDecoration(
              color: errors.isEmpty ? AppColors.successBg : AppColors.errorBg,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppIcon(errors.isEmpty ? 'tick-circle' : 'warning-2', color: errors.isEmpty ? AppColors.success : AppColors.error, size: 18),
                    SizedBox(width: 8.w),
                    Text('$imported imported, $skipped skipped', style: AppUI.label),
                    const Spacer(),
                    IconButton(icon: AppIcon.linear('close-circle', size: 16), onPressed: onDismissResult, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
                  ],
                ),
                if (errors.isNotEmpty) ...[
                  SizedBox(height: 4.h),
                  ...errors.take(5).map((e) => Padding(
                    padding: EdgeInsets.only(top: 2.h),
                    child: Text(e, style: AppUI.body.copyWith(color: AppColors.error)),
                  )),
                  if (errors.length > 5) Text('... and ${errors.length - 5} more errors', style: AppUI.muted),
                ],
              ],
            ),
          ),
        ],
        SizedBox(height: 8.h),

        // Data grid
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.cardBorder),
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
            ),
            child: Column(
              children: [
                // Header row
                Container(
                  decoration: AppUI.tableHeadBar,
                  child: Row(
                    children: [
                      _gridHeaderCell('S.No', width: 60.w, center: true),
                      ...displayHeaders.asMap().entries.expand((e) => [
                        _gridHeaderDivider(),
                        _gridHeaderCell(e.value, right: rightAlignCols.contains(e.key)),
                      ]),
                    ],
                  ),
                ),
                // Existing records label
                if (showExisting)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
                    color: AppColors.accent.withValues(alpha: 0.06),
                    child: Row(
                      children: [
                        AppIcon.linear('box-1', size: 14, color: AppColors.accent),
                        SizedBox(width: 6.w),
                        Text('Existing Records (${existingRows.length})', style: AppUI.label.copyWith(color: AppColors.primary)),
                      ],
                    ),
                  ),
                // Data rows
                Expanded(
                  child: isLoadingExisting && rows.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : displayRows.isEmpty
                          ? AppUI.empty(
                              title: 'No data loaded',
                              why: 'Click Import to load a CSV or Excel file.',
                              icon: 'element-4',
                            )
                          : AppVerticalScrollbar(
                              builder: (context, controller) => ListView.builder(
                                controller: controller,
                                itemCount: displayRows.length,
                                itemBuilder: (_, i) {
                                  final cellErrs = !showExisting ? (cellErrors[i] ?? const <int>{}) : const <int>{};
                                  final hasRowError = !showExisting && rowErrors.containsKey(i);
                                  return Container(
                                    padding: EdgeInsets.zero,
                                    decoration: BoxDecoration(
                                      color: i.isEven ? Colors.white : AppColors.surface,
                                      border: const Border(bottom: BorderSide(color: AppColors.divider)),
                                    ),
                                    child: Row(
                                      children: [
                                        _gridDataCell('${i + 1}', width: 60.w, center: true),
                                        ...List.generate(displayHeaders.length, (j) {
                                          final text = j < displayRows[i].length ? displayRows[i][j].toString() : '';
                                          if (!cellErrs.contains(j)) {
                                            return _gridDataCell(text, right: rightAlignCols.contains(j));
                                          }
                                          // Cell-level highlight: rebuild the cell inline with a red
                                          // background, since _gridDataCell already wraps the inner
                                          // container with Expanded.
                                          return Expanded(
                                            flex: 1,
                                            child: Tooltip(
                                              message: schoolTerm(rowErrors[i] ?? ''),
                                              child: Container(
                                                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 10.h),
                                                alignment: rightAlignCols.contains(j) ? Alignment.centerRight : Alignment.centerLeft,
                                                decoration: const BoxDecoration(
                                                  color: AppColors.errorBg,
                                                  border: Border(right: BorderSide(color: AppColors.divider)),
                                                ),
                                                child: Text(text, style: AppUI.cell.copyWith(color: AppColors.error), overflow: TextOverflow.ellipsis),
                                              ),
                                            ),
                                          );
                                        }),
                                        if (hasRowError)
                                          Padding(
                                            padding: EdgeInsets.only(right: 8.w),
                                            child: Tooltip(
                                              message: schoolTerm(rowErrors[i] ?? ''),
                                              child: AppIcon.linear('info-circle', color: AppColors.error, size: 16),
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: 12.h),

        // Bottom bar
        Row(
          children: [
            Text('${displayRows.length} rows${showExisting ? ' (existing)' : ''}', style: AppUI.muted),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: rows.isNotEmpty && !saving ? onValidate : null,
              icon: AppIcon.linear('tick-circle', size: 16),
              label: const Text('Validate'),
            ),
            SizedBox(width: 8.w),
            ElevatedButton.icon(
              onPressed: saving ? null : (isValidated ? onSave : null),
              icon: saving
                  ? SizedBox(width: 14.w, height: 14.h, child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : AppIcon('save-2', size: 16),
              label: Text(saving ? savingLabel : 'Save'),
            ),
            SizedBox(width: 8.w),
            OutlinedButton(
              onPressed: onClose,
              child: const Text('Close'),
            ),
          ],
        ),
      ],
    ),
  );
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// 1. FEE GROUP TAB
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// COURSE TAB
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class _CourseTab extends StatefulWidget {
  const _CourseTab();
  @override
  State<_CourseTab> createState() => _CourseTabState();
}

class _CourseTabState extends State<_CourseTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _headers = ['Course ID *', 'Course Name *', 'Order'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final rows = await SupabaseService.fromSchema('course').select('*').eq('ins_id', insId);
      // Sort client-side by ordid (NULLS last), then courname - mirrors the
      // master-defined order used by the Students sidebar and drilldowns.
      final sorted = List<Map<String, dynamic>>.from(rows.cast<Map<String, dynamic>>())
        ..sort((a, b) {
          final oa = (a['ordid'] is num) ? (a['ordid'] as num).toInt() : 1 << 30;
          final ob = (b['ordid'] is num) ? (b['ordid'] as num).toInt() : 1 << 30;
          if (oa != ob) return oa.compareTo(ob);
          return (a['courname'] ?? '').toString().toLowerCase()
              .compareTo((b['courname'] ?? '').toString().toLowerCase());
        });
      if (mounted) setState(() {
        _existingRows = sorted.map((r) => [r['courname'] ?? '']).toList();
        _isLoadingExisting = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    setState(() { _fileName = result.files.single.name; _rows = parsed.sublist(1); _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final rowErrs = <int, String>{};
    for (int i = 0; i < _rows.length; i++) {
      final idRaw = _rows[i].isNotEmpty ? _rows[i][0]?.toString().trim() ?? '' : '';
      final name = _rows[i].length > 1 ? _rows[i][1]?.toString().trim() ?? '' : '';
      // Blank ID is generated on save; a value that is not a number is an error.
      if (idRaw.isNotEmpty && int.tryParse(idRaw) == null) { rowErrs[i] = 'Course ID must be a number'; continue; }
      if (name.isEmpty) rowErrs[i] = 'Missing: Course Name';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors. Fix the rows marked in red and validate again.'), backgroundColor: AppColors.error));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed. Click Save to import.'), backgroundColor: AppColors.success));
    }
  }

  void _close() {
    setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; });
  }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    // Blank ID / Order cells are generated: next ID after the highest in the
    // table or the file, next Order after the highest for this institution.
    var nextId = 0, nextOrd = 0;
    try {
      final ids = await SupabaseService.fromSchema('course').select('cour_id').order('cour_id', ascending: false).limit(1);
      if ((ids as List).isNotEmpty) nextId = (ids.first['cour_id'] as num?)?.toInt() ?? 0;
      final ords = await SupabaseService.fromSchema('course').select('ordid').eq('ins_id', insId).order('ordid', ascending: false).limit(1);
      if ((ords as List).isNotEmpty) nextOrd = (ords.first['ordid'] as num?)?.toInt() ?? 0;
    } catch (_) {}
    for (final row in _rows) {
      final id = int.tryParse(row.isNotEmpty ? row[0].toString().trim() : '');
      final ord = row.length > 2 ? int.tryParse(row[2].toString().trim()) : null;
      if (id != null && id > nextId) nextId = id;
      if (ord != null && ord > nextOrd) nextOrd = ord;
    }
    for (final row in _rows) {
      if (row.length < 2 || row[1].toString().trim().isEmpty) { _skipped++; continue; }
      try {
        final courId = int.tryParse(row[0].toString().trim()) ?? ++nextId;
        final ordid = (row.length > 2 ? int.tryParse(row[2].toString().trim()) : null) ?? ++nextOrd;
        await SupabaseService.importSchemaRows('course', [{
          'cour_id': courId,
          'courname': row[1].toString().trim(),
          'ordid': ordid,
          'ins_id': insId,
          'activestatus': 1,
        }], conflictCol: 'cour_id');
        _imported++;
      } catch (e) {
        _skipped++;
        _errors.add('${row[1]}: ${_friendlyError(e.toString())}');
      }
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Courses',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Course', _headers),
      onSampleDownload: () => _exportSampleData('Course', _headers, [
        ['Pre-KG', '1'],
        ['LKG', '2'],
        ['UKG', '3'],
        ['I', '4'],
        ['II', '5'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Course Name'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// CLASS TAB
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class _ClassTab extends StatefulWidget {
  const _ClassTab();
  @override
  State<_ClassTab> createState() => _ClassTabState();
}

class _ClassTabState extends State<_ClassTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _collegeHeaders = ['Class ID *', 'Class Name *', 'Active Status', 'Course ID', 'Succeeding Class', 'Order'];
  // School: a section has no succeeding section, so the column is not there
  // at all and Order moves up one place.
  static const _schoolHeaders = ['Class ID *', 'Class Name *', 'Active Status', 'Course ID', 'Order'];
  List<String> get _headers => isSchool ? _schoolHeaders : _collegeHeaders;
  int get _iOrd => isSchool ? 4 : 5;
  // Standard (course) name by id -- a school section is saved as "LKG A".
  Map<String, String> _courNames = {};

  /// School: "A" under LKG is saved as "LKG A", the same as Master Data,
  /// so sections of different standards never share a name. A name that
  /// already starts with its standard is kept as it is.
  String _sectionName(String name, String courRaw) {
    if (!isSchool) return name;
    final std = (_courNames[courRaw] ?? '').trim();
    if (std.isEmpty || name.toUpperCase().startsWith('${std.toUpperCase()} ') ||
        name.toUpperCase() == std.toUpperCase()) {
      return name;
    }
    return '$std ${name.toUpperCase()}';
  }
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;
  // Existing course IDs for this institution - _validate uses these to flag
  // rows whose Course ID isn't backed by a real course (otherwise the FK
  // insert fails silently and rows are skipped).
  Set<int> _courIds = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final results = await Future.wait([
        SupabaseService.fromSchema('class').select('*').eq('ins_id', insId).order('cla_id', ascending: true),
        SupabaseService.fromSchema('course').select('cour_id, courname, ordid').eq('ins_id', insId),
      ]);
      final rows = results[0] as List;
      final courseRows = results[1] as List;
      // Course name + ordid by cour_id; class name by cla_id (for succeeding class lookup).
      final courseMap = { for (final c in courseRows) c['cour_id'].toString(): (c['courname'] ?? '').toString() };
      final courseOrd = <String, int>{
        for (final c in courseRows)
          if (c['ordid'] != null)
            c['cour_id'].toString(): (c['ordid'] as num).toInt(),
      };
      final classMap = { for (final r in rows) r['cla_id'].toString(): (r['claname'] ?? '').toString() };
      final courIdSet = courseRows
          .map((c) => c['cour_id'] is int ? c['cour_id'] as int : int.tryParse('${c['cour_id'] ?? ''}'))
          .whereType<int>()
          .toSet();
      // Sort by course.ordid â†’ class.ordid (NULLs to the end). Existing
      // rows read in master-defined order - same as the Students sidebar.
      final enriched = rows.map((r) {
        final courIdKey = '${r['cour_id'] ?? ''}';
        return {
          'cells': [
            courseMap[courIdKey] ?? '',
            r['claname']?.toString() ?? '',
            if (!isSchool) classMap['${r['succeedingclass'] ?? ''}'] ?? '',
          ],
          'courseOrd': courseOrd[courIdKey] ?? 1 << 30,
          'classOrd': (r['ordid'] is num) ? (r['ordid'] as num).toInt() : 1 << 30,
        };
      }).toList()
        ..sort((a, b) {
          final co = (a['courseOrd'] as int).compareTo(b['courseOrd'] as int);
          if (co != 0) return co;
          final cl = (a['classOrd'] as int).compareTo(b['classOrd'] as int);
          if (cl != 0) return cl;
          // cells now: [course, claname, succeeding]. Class name (idx 1) is
          // the final tiebreaker.
          final acells = a['cells'] as List;
          final bcells = b['cells'] as List;
          return (acells[1] as String).toLowerCase().compareTo((bcells[1] as String).toLowerCase());
        });
      final sorted = enriched.map((e) => e['cells'] as List).toList();
      if (mounted) {
        setState(() {
          _existingRows = sorted;
          _courIds = courIdSet;
          _courNames = courseMap;
          _isLoadingExisting = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    setState(() { _fileName = result.files.single.name; _rows = parsed.sublist(1); _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final rowErrs = <int, String>{};
    for (int i = 0; i < _rows.length; i++) {
      final missing = <String>[];
      final idRaw   = _rows[i].isNotEmpty   ? _rows[i][0]?.toString().trim() ?? '' : '';
      final name    = _rows[i].length > 1   ? _rows[i][1]?.toString().trim() ?? '' : '';
      final actRaw  = _rows[i].length > 2   ? _rows[i][2]?.toString().trim() ?? '' : '';
      final courRaw = _rows[i].length > 3   ? _rows[i][3]?.toString().trim() ?? '' : '';
      final succRaw = (!isSchool && _rows[i].length > 4) ? _rows[i][4]?.toString().trim() ?? '' : '';
      // Blank ID is generated on save; a value that is not a number is an error.
      if (idRaw.isNotEmpty && int.tryParse(idRaw) == null) { rowErrs[i] = 'Class ID must be a number'; continue; }
      final invalid = <String>[];
      if (name.isEmpty) missing.add('Class Name');
      if (courRaw.isNotEmpty && int.tryParse(courRaw) == null) invalid.add('Course ID must be a whole number');
      if (succRaw.isNotEmpty && int.tryParse(succRaw) == null) invalid.add('Succeeding Class must be a whole number');
      if (actRaw.isNotEmpty && int.tryParse(actRaw) == null) invalid.add('Active Status must be 0 or 1');
      if (missing.isNotEmpty || invalid.isNotEmpty) {
        rowErrs[i] = [if (missing.isNotEmpty) 'Missing: ${missing.join(', ')}', ...invalid].join('. ');
        continue;
      }
      // Course ID must match an existing course for this institution before
      // a Class can be imported (FK on class.cour_id).
      if (courRaw.isNotEmpty && _courIds.isNotEmpty) {
        final cid = int.tryParse(courRaw);
        if (cid != null && !_courIds.contains(cid)) {
          rowErrs[i] = 'Course ID "$courRaw" not found. Import the course first.';
        }
      }
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors. Fix the rows marked in red and validate again.'), backgroundColor: AppColors.error));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed. Click Save to import.'), backgroundColor: AppColors.success));
    }
  }

  void _close() {
    setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; });
  }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    // Blank ID is the next after the highest in the table or the file; blank
    // Order is the next within the row's course.
    var nextId = 0;
    final nextOrd = <String, int>{};
    try {
      final ids = await SupabaseService.fromSchema('class').select('cla_id').order('cla_id', ascending: false).limit(1);
      if ((ids as List).isNotEmpty) nextId = (ids.first['cla_id'] as num?)?.toInt() ?? 0;
      final ords = await SupabaseService.fromSchema('class').select('cour_id, ordid').eq('ins_id', insId);
      for (final r in (ords as List)) {
        final k = '${r['cour_id'] ?? ''}';
        final o = (r['ordid'] as num?)?.toInt() ?? 0;
        if (o > (nextOrd[k] ?? 0)) nextOrd[k] = o;
      }
    } catch (_) {}
    for (final row in _rows) {
      final id = int.tryParse(row.isNotEmpty ? row[0].toString().trim() : '');
      if (id != null && id > nextId) nextId = id;
      final k = row.length > 3 ? row[3].toString().trim() : '';
      final o = row.length > _iOrd ? int.tryParse(row[_iOrd].toString().trim()) : null;
      if (o != null && o > (nextOrd[k] ?? 0)) nextOrd[k] = o;
    }
    for (final row in _rows) {
      if (row.isEmpty || row[1].toString().trim().isEmpty) { _skipped++; continue; }
      try {
        final claId = int.tryParse(row[0].toString().trim()) ?? ++nextId;
        final actRaw  = row.length > 2 ? row[2].toString().trim() : '';
        final courRaw = row.length > 3 ? row[3].toString().trim() : '';
        final succRaw = (!isSchool && row.length > 4) ? row[4].toString().trim() : '';
        final ordRaw  = row.length > _iOrd ? row[_iOrd].toString().trim() : '';
        final ordid = int.tryParse(ordRaw) ?? (nextOrd[courRaw] = (nextOrd[courRaw] ?? 0) + 1);
        await SupabaseService.importSchemaRows('class', [{
          'cla_id': claId,
          'claname': _sectionName(row[1].toString().trim(), courRaw),
          'cour_id': courRaw.isEmpty ? null : int.tryParse(courRaw),
          // School: a section has no succeeding section.
          if (!isSchool) 'succeedingclass': succRaw.isEmpty ? null : int.tryParse(succRaw),
          'ordid': ordid,
          'ins_id': insId,
          'activestatus': actRaw.isEmpty ? 1 : (int.tryParse(actRaw) ?? 1),
        }], conflictCol: 'cla_id');
        _imported++;
      } catch (e) {
        _skipped++;
        _errors.add('${row[1]}: ${_friendlyError(e.toString())}');
      }
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Classes',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Class', _headers),
      onSampleDownload: () => _exportSampleData('Class', _headers, isSchool
          ? [
              ['', 'A', '1', '1', ''],
              ['', 'B', '1', '1', ''],
              ['', 'A', '1', '2', ''],
            ]
          : [
        ['1', 'I Year',   '1', '1', '2', '1'],
        ['2', 'II Year',  '1', '1', '3', '2'],
        ['3', 'III Year', '1', '1', '',  '3'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: isSchool ? const ['Course', 'Class Name'] : const ['Course', 'Class Name', 'Succeeding Class'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class _FeeGroupTab extends StatefulWidget {
  const _FeeGroupTab();
  @override
  State<_FeeGroupTab> createState() => _FeeGroupTabState();
}

class _FeeGroupTabState extends State<_FeeGroupTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  // Year is NOT imported - it's auto-set to the institution's active year by
  // process_master_import.
  static const _headers = ['Fee Group ID *', 'Group Name *'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final groups = await SupabaseService.getFeeGroups(insId);
      if (mounted) setState(() {
        _existingRows = groups.map((g) => [g['fgdesc'] ?? '']).toList();
        _isLoadingExisting = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    setState(() { _fileName = result.files.single.name; _rows = parsed.sublist(1); _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final rowErrs = <int, String>{};
    final labels = _headers.map((h) => h.replaceAll(' *', '').replaceAll('*', '')).toList();
    for (int i = 0; i < _rows.length; i++) {
      final missing = <String>[];
      for (int j = 0; j < labels.length; j++) {
        final val = _rows[i].length > j ? _rows[i][j]?.toString().trim() ?? '' : '';
        if (val.isEmpty && j != 0) missing.add(labels[j]);  // blank ID is generated on save
      }
      if (missing.isNotEmpty) rowErrs[i] = 'Missing: ${missing.join(', ')}';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors. Fix the rows marked in red and validate again.'), backgroundColor: AppColors.error));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed. Click Save to import.'), backgroundColor: AppColors.success));
    }
  }

  void _close() {
    setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; });
  }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    try {
      final rows = await _fillBlankIds('feegroup', 'fg_id', _rows);
      final result = await _stagingImport(insId: insId, impType: 'FEEGROUP', rows: rows, colCount: 2);
      _imported = result['imported'] ?? 0;
      _skipped = result['skipped'] ?? 0;
      if (_skipped > 0) _errors = await _getImportErrors(insId, 'FEEGROUP');
    } catch (e) {
      _errors = ['Could not import the file. ${_friendlyError(e.toString())}'];
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) {
      _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Fee Groups',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Fee Group', _headers),
      onSampleDownload: () => _exportSampleData('Fee Group', _headers, [
        ['1', 'SCHOOL FEES'],
        ['2', 'VAN FEES'],
        ['3', 'HOSTEL FEES'],
        ['4', 'EXAM FEES'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Group Name'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// 2. FEE TYPE TAB
// Columns: Fee Name *, Short Name *, Fee Group *, Optional, Category
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class _FeeTypeTab extends StatefulWidget {
  const _FeeTypeTab();
  @override
  State<_FeeTypeTab> createState() => _FeeTypeTabState();
}

class _FeeTypeTabState extends State<_FeeTypeTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  // Year is NOT imported - it's auto-set to the institution's active year by
  // process_master_import.
  static const _headers = ['Fee ID *', 'Fee Name *', 'Short Name *', 'Fee Group *', 'Fine Applicable *', 'FeeType Order', 'Type'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;
  // Lowercased fee-group names for the current institution - used by _validate
  // to flag rows whose Fee Group doesn't exist (otherwise the server import
  // silently skips them).
  Set<String> _fgNames = {};
  Set<int> _fgIdSet = {}; // valid fee group IDs — the import also accepts fg_id in the Fee Group column

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final feeGroups = await SupabaseService.getFeeGroups(insId);
      if (feeGroups.isEmpty) {
        if (mounted) setState(() { _fgNames = {}; _isLoadingExisting = false; });
        return;
      }
      final fgIds = feeGroups.map((fg) => fg['fg_id'] as int).toList();
      final fgNameMap = { for (final fg in feeGroups) fg['fg_id'] as int: fg['fgdesc']?.toString() ?? '' };
      final fgNameSet = feeGroups
          .map((fg) => (fg['fgdesc']?.toString() ?? '').trim().toLowerCase())
          .where((s) => s.isNotEmpty)
          .toSet();
      final types = await SupabaseService.fromSchema('feetype').select('*').inFilter('fg_id', fgIds).eq('activestatus', 1).order('fee_id', ascending: true);
      if (mounted) setState(() {
        const fineLabels = {'1': 'Yes', '0': 'No'};
        _existingRows = (types as List).map((t) {
          return [
            t['feedesc'] ?? '',
            t['feeshort'] ?? '',
            fgNameMap[t['fg_id']] ?? '',
            fineLabels['${t['feefineapplicable'] ?? 0}'] ?? 'No',
            t['type'] ?? '',
          ];
        }).toList();
        _fgNames = fgNameSet;
        _fgIdSet = fgIds.toSet();
        _isLoadingExisting = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    setState(() { _fileName = result.files.single.name; _rows = parsed.sublist(1); _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final rowErrs = <int, String>{};
    final labels = _headers.map((h) => h.replaceAll(' *', '').replaceAll('*', '')).toList();
    for (int i = 0; i < _rows.length; i++) {
      final missing = <String>[];
      for (int j = 0; j < labels.length; j++) {
        if (!_headers[j].contains('*')) continue; // optional column (FeeType Order, Type)
        final val = _rows[i].length > j ? _rows[i][j]?.toString().trim() ?? '' : '';
        if (val.isEmpty && j != 0) missing.add(labels[j]);  // blank ID is generated on save
      }
      if (missing.isNotEmpty) {
        rowErrs[i] = 'Missing: ${missing.join(', ')}';
        continue;
      }
      // Fee Group must already exist for this institution. The column accepts
      // either the fee group ID (e.g. 1) or the group name — matching the
      // server-side resolution in process_master_import.
      final fgRaw = _rows[i].length > 3 ? _rows[i][3]?.toString().trim() ?? '' : '';
      final asId = int.tryParse(fgRaw);
      final validById = asId != null && _fgIdSet.contains(asId);
      final validByName = _fgNames.contains(fgRaw.toLowerCase());
      final haveMaster = _fgIdSet.isNotEmpty || _fgNames.isNotEmpty;
      if (fgRaw.isNotEmpty && haveMaster && !validById && !validByName) {
        rowErrs[i] = 'Fee Group "$fgRaw" not found. Import the fee group first.';
      }
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors. Fix the rows marked in red and validate again.'), backgroundColor: AppColors.error));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed. Click Save to import.'), backgroundColor: AppColors.success));
    }
  }

  void _close() { setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; }); }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    try {
      const fineMap = {'yes': '1', 'y': '1', 'true': '1', '1': '1', 'no': '0', 'n': '0', 'false': '0', '0': '0', '': '0'};
      final filled = await _fillBlankIds('feetype', 'fee_id', _rows);
      final mappedRows = filled.map((row) {
        final mapped = List<dynamic>.from(row);
        while (mapped.length < 7) {
          mapped.add('');
        }
        // Fine Applicable is col 5 (index 4) after Fee ID, Name, Short, Group.
        // col 6 = FeeType Order (positional alignment only), col 7 = Type.
        final fine = mapped[4].toString().trim().toLowerCase();
        mapped[4] = fineMap[fine] ?? mapped[4];
        return mapped;
      }).toList();
      final result = await _stagingImport(insId: insId, impType: 'FEETYPE', rows: mappedRows, colCount: 7);
      _imported = result['imported'] ?? 0;
      _skipped = result['skipped'] ?? 0;
      if (_skipped > 0) _errors = await _getImportErrors(insId, 'FEETYPE');
    } catch (e) {
      _errors = ['Could not import the file. ${_friendlyError(e.toString())}'];
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) {
      _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Fee Types',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Fee Type', _headers),
      onSampleDownload: () => _exportSampleData('Fee Type', _headers, [
        ['1', 'SCHOOL FEES', 'SCH', 'SCHOOL FEES', 'Yes', '0', isSchool ? 'REG' : 'COL'],
        ['2', 'VAN FEES', 'VAN', 'VAN FEES', 'No', '0', isSchool ? 'OPT' : 'COL'],
        ['3', 'TUITION FEES', 'TUI', 'SCHOOL FEES', 'Yes', '0', isSchool ? 'REG' : 'COL'],
        ['4', 'BOOK FEES', 'BK', 'SCHOOL FEES', 'No', '0', isSchool ? 'OPT' : 'COL'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Fee Name', 'Short Name', 'Fee Group', 'Fine Applicable', 'Type'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// 3. CONCESSION TAB
// Columns: Concession Name *, Order
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class _ConcessionTab extends StatefulWidget {
  const _ConcessionTab();
  @override
  State<_ConcessionTab> createState() => _ConcessionTabState();
}

class _ConcessionTabState extends State<_ConcessionTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _headers = ['Concession ID *', 'Concession Name *'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final concessions = await SupabaseService.getConcessions(insId);
      if (mounted) setState(() {
        _existingRows = concessions.map((c) => [c['condesc'] ?? '']).toList();
        _isLoadingExisting = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    setState(() { _fileName = result.files.single.name; _rows = parsed.sublist(1); _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final rowErrs = <int, String>{};
    final labels = _headers.map((h) => h.replaceAll(' *', '').replaceAll('*', '')).toList();
    for (int i = 0; i < _rows.length; i++) {
      final missing = <String>[];
      for (int j = 0; j < labels.length; j++) {
        final val = _rows[i].length > j ? _rows[i][j]?.toString().trim() ?? '' : '';
        if (val.isEmpty && j != 0) missing.add(labels[j]);  // blank ID is generated on save
      }
      if (missing.isNotEmpty) rowErrs[i] = 'Missing: ${missing.join(', ')}';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors. Fix the rows marked in red and validate again.'), backgroundColor: AppColors.error));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed. Click Save to import.'), backgroundColor: AppColors.success));
    }
  }

  void _close() { setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; }); }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    try {
      final rows = await _fillBlankIds('concessioncategory', 'con_id', _rows);
      final result = await _stagingImport(insId: insId, impType: 'CONCESSION', rows: rows, colCount: 2);
      _imported = result['imported'] ?? 0;
      _skipped = result['skipped'] ?? 0;
      if (_skipped > 0) _errors = await _getImportErrors(insId, 'CONCESSION');
    } catch (e) {
      _errors = ['Could not import the file. ${_friendlyError(e.toString())}'];
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) {
      _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Concessions',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Concession', _headers),
      onSampleDownload: () => _exportSampleData('Concession', _headers, [
        ['1', 'SC/ST'],
        ['2', 'Staff Children'],
        ['3', 'Merit Scholarship'],
        ['4', 'Sibling Discount'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Concession Name'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// 4. CLASS FEE DEMAND TAB
// Columns: Class *, Term, Fee Type *, Amount, Due Date, Admission Type
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class _ClassFeeDemandTab extends StatefulWidget {
  const _ClassFeeDemandTab();
  @override
  State<_ClassFeeDemandTab> createState() => _ClassFeeDemandTabState();
}

class _ClassFeeDemandTabState extends State<_ClassFeeDemandTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  // Live label for the Save button during the multi-step save (import +
  // per-class demand generation) so the user sees progress, not a frozen
  // "Saving...".
  String _genStatus = 'Saving...';
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _collegeHeaders = ['Class *', 'Semester *', 'Feetype *', 'AdmissionType *', 'Class Fee Amount *', 'Due Date *', 'App. To All', 'Class Id', 'Semester Id', 'Fee Id', 'Admission Type Id', 'Class Fee Id'];
  /// School format: no admission type; a line can instead be limited to
  /// New/Old students, Boys/Girls and Dayscholars/Hostlers (blank = both).
  static const _schoolHeaders = ['Section *', 'Term *', 'Fee Type *', 'Amount *', 'New/Old', 'Boy/Girl', 'Dayscholar/Hostler', 'Due Date *', 'Term Id', 'Fee Id', 'Section Id'];
  static List<String> get _headers => isSchool ? _schoolHeaders : _collegeHeaders;

  /// School flag cells -> 1 / 2 / 3 (3 = both; blank is both). null = not
  /// a recognised value.
  static int? _flag(String raw, Set<String> one, Set<String> two) {
    final v = raw.trim().toUpperCase().replaceAll(RegExp(r'[\s.]+'), '');
    if (v.isEmpty || const {'BOTH', 'ALL', 'B', '3'}.contains(v)) return 3;
    if (one.contains(v)) return 1;
    if (two.contains(v)) return 2;
    return null;
  }
  static int? _nob(String v) => _flag(v, const {'NEW', 'N', '1'}, const {'OLD', 'O', '2'});
  static int? _bgb(String v) => _flag(v, const {'BOY', 'BOYS', 'M', 'MALE', '1'}, const {'GIRL', 'GIRLS', 'F', 'FEMALE', 'G', '2'});
  static int? _dhb(String v) => _flag(v, const {'DAYSCHOLAR', 'DAYSCHOLARS', 'DAY', 'D', 'DS', '1'},
      const {'HOSTLER', 'HOSTLERS', 'HOSTELLER', 'HOSTELLERS', 'HOSTEL', 'H', '2'});
  static const _nobLabel = {1: 'New', 2: 'Old', 3: 'Both'};
  static const _bgbLabel = {1: 'Boy', 2: 'Girl', 3: 'Both'};
  static const _dhbLabel = {1: AppText.dayScholar, 2: AppText.hosteller, 3: 'Both'};
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;
  Map<String, int> _admIdByName = {}; // admission type name (upper) -> adm_id

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final results = await Future.wait([
        // classfeedemand is class x term x feetype x admission type — it runs
        // past 1000 rows on a real college, so page it.
        SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('classfeedemand').select('*').eq('activestatus', 1)),
        // A school has no admission-type table.
        if (isSchool)
          Future.value(const <Map<String, dynamic>>[])
        else
          SupabaseService.fromSchema('admissiontype').select('adm_id, admname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('course').select('cour_id, courname').eq('ins_id', insId),
      ]);
      final rows = results[0] as List;
      final admRows = results[1] as List;
      final classRows = results[2] as List;
      final courseRows = results[3] as List;
      final admMap = { for (final a in admRows) a['adm_id'].toString(): (a['admname'] ?? '').toString() };
      _admIdByName = {
        for (final a in admRows)
          if (a['adm_id'] != null && (a['admname']?.toString().trim() ?? '').isNotEmpty)
            a['admname'].toString().trim().toUpperCase(): (a['adm_id'] as num).toInt(),
      };
      final courseById = <String, String>{
        for (final c in courseRows) c['cour_id'].toString(): (c['courname'] ?? '').toString(),
      };
      String norm(String s) => s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
      // Class name â†’ course name lookup, derived from class.cour_id.
      final classToCourse = <String, String>{};
      for (final cl in classRows) {
        final name = (cl['claname']?.toString() ?? '').trim();
        if (name.isEmpty) continue;
        final cid = cl['cour_id']?.toString() ?? '';
        classToCourse[norm(name)] = courseById[cid] ?? '';
      }
      if (mounted) setState(() {
        final sorted = List<Map<String, dynamic>>.from(rows.cast<Map<String, dynamic>>());
        sorted.sort((a, b) {
          final ca = (a['cfclass']?.toString() ?? '').toLowerCase();
          final cb = (b['cfclass']?.toString() ?? '').toLowerCase();
          if (ca != cb) return ca.compareTo(cb);
          return (a['cfterm']?.toString() ?? '').compareTo(b['cfterm']?.toString() ?? '');
        });
        // Amounts come back as raw doubles (e.g. 1750.0); show them as xxxx.xx.
        String fmtAmount(dynamic v) {
          if (v == null || v.toString().trim().isEmpty) return '';
          final d = v is num ? v.toDouble() : double.tryParse(v.toString());
          return d == null ? v.toString() : formatIndianNumber(d);
        }
        int? n(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
        _existingRows = isSchool
            ? sorted.map((r) => <dynamic>[
                  classToCourse[norm(r['cfclass']?.toString() ?? '')] ?? '',
                  r['cfclass'] ?? '',
                  r['cfterm'] ?? '',
                  r['cffeetype'] ?? '',
                  fmtAmount(r['cfamount']),
                  _nobLabel[n(r['cfnob']) ?? 3] ?? '',
                  _bgbLabel[n(r['cfbgb']) ?? 3] ?? '',
                  _dhbLabel[n(r['cfdhb']) ?? 3] ?? '',
                  r['cfdduedate'] ?? '',
                ]).toList()
            : sorted.map((r) => [
          classToCourse[norm(r['cfclass']?.toString() ?? '')] ?? '',
          r['cfclass'] ?? '',
          r['cfterm'] ?? '',
          r['cffeetype'] ?? '',
          fmtAmount(r['cfamount']),
          r['cfdduedate'] ?? '',
          admMap['${r['admissiontype'] ?? ''}'] ?? '${r['admissiontype'] ?? ''}',
        ]).toList();
        _isLoadingExisting = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    // Align each row to the canonical column order by matching the file's
    // HEADER NAMES (not position), so an extra leading S.NO column, reordered
    // columns, or a legacy leading CF ID column can't shift a value onto the
    // wrong field. (Positional reads previously dropped Class Fee Id whenever
    // the layout differed, so cf_id silently auto-generated.)
    final dataRows = _alignRows(parsed);
    setState(() { _fileName = result.files.single.name; _rows = dataRows; _isValidated = false; });
  }

  static String _normHeader(String s) =>
      collegeTerm(s).trim().toLowerCase().replaceAll('*', '').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Reorder each data row into the canonical [_headers] order by matching the
  /// file's header names. Immune to a leading S.NO column, reordered columns, or
  /// a legacy leading CF ID column. Falls back to the old positional handling
  /// (with the leading-column strip) only if the header can't be matched.
  List<List<dynamic>> _alignRows(List<List<dynamic>> parsed) {
    if (isSchool) return _alignSchoolRows(parsed);
    final header = parsed.first.map((c) => _normHeader(c.toString())).toList();
    const fields = <List<String>>[
      ['class'],
      ['semester', 'term'],
      ['feetype', 'fee type'],
      ['admissiontype', 'admission type'],
      ['class fee amount'],
      ['due date'],
      ['app. to all', 'app to all', 'apptoall'],
      ['class id', 'classid'],
      ['semester id', 'sem id', 'semid'],
      ['fee id', 'feeid'],
      ['admission type id', 'adm type id', 'adm id'],
      ['class fee id', 'classfeeid', 'cf id', 'cfid'],
    ];
    final idx = [
      for (final aliases in fields) header.indexWhere((h) => aliases.contains(h)),
    ];
    // Reorder by name only when the 6 required columns all resolved.
    if (idx.take(6).every((i) => i >= 0)) {
      return parsed.sublist(1).map((r) => List<dynamic>.generate(
            fields.length,
            (f) => idx[f] >= 0 && idx[f] < r.length ? r[idx[f]] : '',
          )).toList();
    }
    // Legacy fallback: positional read with a leading-column strip.
    var dataRows = parsed.sublist(1);
    final h0 = parsed.first.isNotEmpty ? parsed.first.first.toString().trim().toLowerCase() : '';
    final headerHasCfId = h0.contains('cf') && h0.contains('id');
    final firstRowLooksLegacy = dataRows.isNotEmpty &&
        dataRows.first.length >= 7 &&
        int.tryParse(dataRows.first[0].toString().trim()) != null;
    if (headerHasCfId || firstRowLooksLegacy) {
      dataRows = dataRows.map((r) => r.length > 1 ? r.sublist(1) : r).toList();
    }
    return dataRows;
  }

  /// School columns by header name (Section/Term are read through collegeTerm,
  /// so they arrive as class/semester; "Day Scholar / Hosteller" etc. match).
  /// A file without the required headers is read in the template's order.
  List<List<dynamic>> _alignSchoolRows(List<List<dynamic>> parsed) {
    String norm(String h) => _normHeader(h)
        .replaceAll(RegExp(r'\s*/\s*'), '/')
        .replaceAll('day scholar', 'dayscholar')
        .replaceAll('hosteller', 'hostler');
    final header = parsed.first.map((c) => norm(c.toString())).toList();
    const fields = <List<String>>[
      ['class', 'class name'],
      ['semester', 'term'],
      ['feetype', 'fee type'],
      ['amount', 'class fee amount', 'fee amount'],
      ['new/old', 'newold', 'new or old'],
      ['boy/girl', 'boygirl', 'gender'],
      ['dayscholar/hostler', 'dayscholarhostler', 'hostel'],
      ['due date', 'duedate'],
      ['semester id', 'term id', 'sem id', 'semid'],
      ['fee id', 'feeid'],
      ['class id', 'classid'],
    ];
    final idx = [for (final aliases in fields) header.indexWhere((h) => aliases.contains(h))];
    if (![0, 1, 2, 3, 7].every((i) => idx[i] >= 0)) return parsed.sublist(1);
    return parsed.sublist(1).map((r) => List<dynamic>.generate(
          fields.length,
          (f) => idx[f] >= 0 && idx[f] < r.length ? r[idx[f]] : '',
        )).toList();
  }

  void _validate() {
    if (isSchool) {
      _validateSchool();
      return;
    }
    final rowErrs = <int, String>{};
    final labels = ['Class', 'Semester', 'Feetype', 'AdmissionType', 'Class Fee Amount', 'Due Date'];
    for (int i = 0; i < _rows.length; i++) {
      final missing = <String>[];
      for (int j = 0; j < labels.length; j++) {
        if (isSchool && j == 3) continue; // no admission type on a school
        final val = _rows[i].length > j ? _rows[i][j]?.toString().trim() ?? '' : '';
        if (val.isEmpty) missing.add(labels[j]);
      }
      if (missing.isNotEmpty) rowErrs[i] = 'Missing: ${missing.join(', ')}';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors. Fix the rows marked in red and validate again.'), backgroundColor: AppColors.error));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed. Click Save to import.'), backgroundColor: AppColors.success));
    }
  }

  void _close() { setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; }); }

  /// Name key for matching a file value to the master: case, spaces and dots
  /// ignored, so "i a", "IA" and "I A" all find section "I A".
  static String _key(String v) => v.toUpperCase().replaceAll(RegExp(r'[\s.]+'), '');

  bool _validating = false;

  /// School validation. Besides the format rules, every row is checked
  /// against the DATABASE: the Section, Term and Fee Type must exist (a
  /// Standard name such as "I" is not a section), any ids typed in the file
  /// must belong to those names, and a line already defined -- in the file or
  /// in the database -- is refused. Passing rows get the master's exact names
  /// and their Term Id / Fee Id / Section Id filled in.
  Future<void> _validateSchool() async {
    if (_validating) return;
    final insId = Provider.of<AuthProvider>(context, listen: false).insId;
    if (insId == null) return;
    setState(() => _validating = true);
    List<Map<String, dynamic>> classes, courses, terms, fees, saved;
    try {
      final r = await Future.wait([
        SupabaseService.fromSchema('class').select('cla_id, claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('course').select('cour_id, courname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('semester').select('sem_id, semname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('feetype').select('fee_id, feedesc').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fetchAll(() => SupabaseService.fromSchema('classfeedemand')
            .select('cfclass, cfterm, cffeetype, cfnob, cfbgb, cfdhb').eq('activestatus', 1)),
      ]);
      List<Map<String, dynamic>> m(dynamic x) => List<Map<String, dynamic>>.from((x as List).cast<Map<String, dynamic>>());
      classes = m(r[0]);
      courses = m(r[1]);
      terms = m(r[2]);
      fees = m(r[3]);
      saved = m(r[4]);
    } catch (e) {
      if (mounted) {
        setState(() => _validating = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not load the master data needed for validation. ${friendlyError(e)}'), backgroundColor: AppColors.error));
      }
      return;
    }
    int? id(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    final classByKey = {for (final c in classes) _key('${c['claname']}'): c};
    final termByKey = {for (final t in terms) _key('${t['semname']}'): t};
    final feeByKey = {for (final f in fees) _key('${f['feedesc']}'): f};
    final courseByKey = {for (final c in courses) _key('${c['courname']}'): c};
    String lineKey(String cls, String term, String fee, int nob, int bgb, int dhb) =>
        '${_key(cls)}|${_key(term)}|${_key(fee)}|$nob|$bgb|$dhb';
    final savedKeys = {
      for (final r in saved)
        lineKey('${r['cfclass'] ?? ''}', '${r['cfterm'] ?? ''}', '${r['cffeetype'] ?? ''}',
            id(r['cfnob']) ?? 3, id(r['cfbgb']) ?? 3, id(r['cfdhb']) ?? 3),
    };
    final termNames = terms.map((t) => '${t['semname']}').join(', ');
    final seenInFile = <String, int>{};

    final rowErrs = <int, String>{};
    final cellErrs = <int, Set<int>>{};
    const required = {0: 'Section', 1: 'Term', 2: 'Fee Type', 3: 'Amount', 7: 'Due Date'};
    for (int i = 0; i < _rows.length; i++) {
      // Work on a growable copy so ids / exact names can be written back.
      final row = List<dynamic>.from(_rows[i]);
      while (row.length < _schoolHeaders.length) {
        row.add('');
      }
      _rows[i] = row;
      String cell(int j) => row[j]?.toString().trim() ?? '';
      final problems = <String>[];
      final bad = <int>{};

      // ---- against the database -----------------------------------------
      final cls = classByKey[_key(cell(0))];
      if (cell(0).isNotEmpty && cls == null) {
        final std = courseByKey[_key(cell(0))];
        if (std != null) {
          final secs = classes.where((c) => id(c['cour_id']) == id(std['cour_id'])).map((c) => '${c['claname']}').toList();
          problems.add('"${cell(0)}" is a Standard, not a Section${secs.isEmpty ? '' : ' -- use ${secs.join(', ')}'}');
        } else {
          problems.add('Section "${cell(0)}" not found');
        }
        bad.add(0);
      }
      final term = termByKey[_key(cell(1))];
      if (cell(1).isNotEmpty && term == null) {
        problems.add('Term "${cell(1)}" not found${termNames.isEmpty ? '' : ' (terms: $termNames)'}');
        bad.add(1);
      }
      final fee = feeByKey[_key(cell(2))];
      if (cell(2).isNotEmpty && fee == null) {
        problems.add('Fee Type "${cell(2)}" not found');
        bad.add(2);
      }
      // Ids typed in the file must belong to the names beside them.
      void checkId(int col, String label, Map<String, dynamic>? rec, String idCol) {
        final typed = cell(col);
        if (typed.isEmpty || rec == null) return;
        if (int.tryParse(typed) != id(rec[idCol])) {
          problems.add('$label $typed does not match the name (expected ${id(rec[idCol])})');
          bad.add(col);
        }
      }
      checkId(8, 'Term ID', term, 'sem_id');
      checkId(9, 'Fee ID', fee, 'fee_id');
      checkId(10, 'Section ID', cls, 'cla_id');
      final missing = [for (final e in required.entries) if (cell(e.key).isEmpty) e.value];
      for (final e in required.entries) {
        if (cell(e.key).isEmpty) bad.add(e.key);
      }
      if (missing.isNotEmpty) problems.add('Missing: ${missing.join(', ')}');
      if (cell(3).isNotEmpty && double.tryParse(cell(3).replaceAll(',', '')) == null) {
        problems.add('Amount must be a number');
        bad.add(3);
      }
      if (cell(7).isNotEmpty && _dueDateIso(cell(7)) == null) {
        problems.add('Due Date must be DD-MM-YYYY');
        bad.add(7);
      }
      if (_nob(cell(4)) == null) { problems.add('New/Old must be New, Old or blank'); bad.add(4); }
      if (_bgb(cell(5)) == null) { problems.add('Boy/Girl must be Boy, Girl or blank'); bad.add(5); }
      if (_dhb(cell(6)) == null) { problems.add('Day Scholar/Hosteller must be Day Scholar, Hosteller or blank'); bad.add(6); }

      // ---- duplicates: in this file, or already saved ----------------------
      if (cls != null && term != null && fee != null && !bad.contains(4) && !bad.contains(5) && !bad.contains(6)) {
        final k = lineKey('${cls['claname']}', '${term['semname']}', '${fee['feedesc']}',
            _nob(cell(4)) ?? 3, _bgb(cell(5)) ?? 3, _dhb(cell(6)) ?? 3);
        if (seenInFile.containsKey(k)) {
          problems.add('Duplicate of row ${seenInFile[k]! + 1}');
          bad.addAll(const [0, 1, 2]);
        } else {
          seenInFile[k] = i;
          if (savedKeys.contains(k)) {
            problems.add('Already defined for this section, term and fee type');
            bad.addAll(const [0, 1, 2]);
          }
        }
      }

      if (problems.isNotEmpty) {
        rowErrs[i] = problems.join('; ');
        cellErrs[i] = bad;
      } else {
        // Exact master names (so cfclass / cfterm / cffeetype match the
        // masters character for character) and their ids.
        row[0] = cls!['claname'];
        row[1] = term!['semname'];
        row[2] = fee!['feedesc'];
        row[8] = '${id(term['sem_id']) ?? ''}';
        row[9] = '${id(fee['fee_id']) ?? ''}';
        row[10] = '${id(cls['cla_id']) ?? ''}';
      }
    }
    if (!mounted) return;
    setState(() { _validating = false; _rowErrors = rowErrs; _cellErrors = cellErrs; _isValidated = rowErrs.isEmpty; });
    ScaffoldMessenger.of(context).showSnackBar(rowErrs.isNotEmpty
        ? SnackBar(content: Text('${rowErrs.length} row(s) have errors. Fix the rows marked in red and validate again.'), backgroundColor: AppColors.error)
        : const SnackBar(content: Text('Validation passed. Click Save to import.'), backgroundColor: AppColors.success));
  }

  // Normalise a due date to ISO yyyy-MM-dd so Postgres never mis-parses it
  // (files often use DD-MM-YYYY, which Postgres reads as month=31 and rejects).
  // Returns null for empty/unparseable so a bad date doesn't fail the batch.
  static String? _dueDateIso(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final parts = t.split(RegExp(r'[/\-.]'));
    if (parts.length == 3) {
      final p0 = int.tryParse(parts[0]), p1 = int.tryParse(parts[1]), p2 = int.tryParse(parts[2]);
      if (p0 != null && p1 != null && p2 != null) {
        int y, m, d;
        if (parts[0].length == 4) { y = p0; m = p1; d = p2; }            // YYYY-MM-DD
        else { d = p0; m = p1; y = p2 < 100 ? p2 + 2000 : p2; }          // DD-MM-YYYY
        if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
          return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
        }
      }
    }
    final dt = DateTime.tryParse(t);
    return dt == null ? null : '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; _genStatus = 'Saving...'; });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    int generated = 0;
    try {
      // File column order (matches the export template):
      //   0 Class, 1 Semester, 2 Feetype, 3 AdmissionType, 4 Class Fee Amount,
      //   5 Due Date, 6 App. To All (collectible), 7 Class Id, 8 Semester Id,
      //   9 Fee Id, 10 Admission Type Id, 11 Class Fee Id.
      // Class/Semester/Fee Type stored as names; admissiontype from the Admission
      // Type Id (or resolved from the name); App. To All -> collectible; due date
      // normalised to ISO so DD-MM-YYYY isn't mis-read. cf_id uses the file's
      // Class Fee Id (col 11) when given, else the set_cf_id trigger assigns it.
      const truthy = {'Y', 'YES', 'TRUE', '1', 'ALL'};
      final records = <Map<String, dynamic>>[];
      for (final row in isSchool ? const <List<dynamic>>[] : _rows) {
        String cell(int j) => j < row.length ? row[j].toString().trim() : '';
        final className = cell(0);
        final feetype = cell(2);
        if (className.isEmpty || feetype.isEmpty) { _skipped++; continue; }
        int? admId = int.tryParse(cell(10)); // Admission Type Id wins
        if (admId == null && cell(3).isNotEmpty) admId = _admIdByName[cell(3).toUpperCase()];
        final cfId = int.tryParse(cell(11)); // Class Fee Id from the file (col 11)
        records.add({
          // Always send cf_id (value or null). import_schema_rows picks the columns
          // to insert from the FIRST row's keys, so omitting cf_id on row 0 would
          // drop it for the WHOLE batch. A value is kept as-is (so a later Fee
          // Demand import can reference it); null lets the set_cf_id trigger assign
          // the next sequence number.
          'cf_id': cfId,
          'cfclass': className,
          'cfterm': cell(1).isEmpty ? null : cell(1),
          'cffeetype': feetype,
          'cfamount': double.tryParse(cell(4).replaceAll(',', '')),
          'cfdduedate': _dueDateIso(cell(5)),
          if (!isSchool) 'admissiontype': admId,
          'collectible': truthy.contains(cell(6).toUpperCase()),
          'cla_id': int.tryParse(cell(7)),
          'sem_id': int.tryParse(cell(8)),
          'fee_id': int.tryParse(cell(9)),
          'activestatus': 1,
        });
      }
      // School: 0 Section, 1 Term, 2 Fee Type, 3 Amount, 4 New/Old, 5 Boy/Girl,
      // 6 Dayscholar/Hostler, 7 Due Date, 8 Term Id, 9 Fee Id, 10 Section Id.
      // Every line is raised on its matching students (collectible); cf_id is
      // always assigned by the set_cf_id trigger.
      if (isSchool) {
        for (final row in _rows) {
          String cell(int j) => j < row.length ? row[j].toString().trim() : '';
          if (cell(0).isEmpty || cell(2).isEmpty) { _skipped++; continue; }
          records.add({
            'cf_id': null,
            'cfclass': cell(0),
            'cfterm': cell(1),
            'cffeetype': cell(2),
            'cfamount': double.tryParse(cell(3).replaceAll(',', '')),
            'cfnob': _nob(cell(4)) ?? 3,
            'cfbgb': _bgb(cell(5)) ?? 3,
            'cfdhb': _dhb(cell(6)) ?? 3,
            'cfdduedate': _dueDateIso(cell(7)),
            'collectible': true,
            'sem_id': int.tryParse(cell(8)),
            'fee_id': int.tryParse(cell(9)),
            'cla_id': int.tryParse(cell(10)),
            'activestatus': 1,
          });
        }
      }
      for (int i = 0; i < records.length; i += 500) {
        final batch = records.sublist(i, (i + 500).clamp(0, records.length));
        try {
          await SupabaseService.importSchemaRows('classfeedemand',
              List<Map<String, dynamic>>.from(batch));
          _imported += batch.length;
        } catch (_) {
          for (final rec in batch) {
            try {
              await SupabaseService.importSchemaRows('classfeedemand',
                  [Map<String, dynamic>.from(rec as Map)]);
              _imported++;
            } catch (e) {
              _skipped++;
              _errors.add('${rec['cfclass']} / ${rec['cffeetype']}: ${_friendlyError(e.toString())}');
            }
          }
        }
      }
      // Generate the student demands from the (updated) template. Do this PER
      // CLASS: one whole-institution call stages tens of thousands of rows
      // (each assigning a demno via a trigger) in a single transaction and
      // times out. Per-class batches each finish quickly and never time out.
      try {
        // fetchAll: a plain select stops at PostgREST's 1000-row cap, which
        // would silently drop classes from this set — and a class missing here
        // never gets its demands generated at all.
        final classRows = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('classfeedemand')
            .select('cfclass')
            .eq('activestatus', 1));
        final classes = <String>{
          for (final r in (classRows as List))
            (r['cfclass'] ?? '').toString().trim(),
        }..removeWhere((c) => c.isEmpty);
        final total = classes.length;
        var done = 0;
        for (final cls in classes) {
          done++;
          if (mounted) setState(() => _genStatus = 'Generating $done/$total…');
          try {
            final g = await SupabaseService.client.rpc(
                'generate_feedemand_for_class',
                params: {'p_ins_id': insId, 'p_class': cls});
            generated += (g is num) ? g.toInt() : (int.tryParse(g?.toString() ?? '') ?? 0);
          } catch (e) {
            _errors.add('Demand generation failed for "$cls": ${_friendlyError(e.toString())}');
          }
        }
      } catch (e) {
        _errors.add('Fee demand lines imported, but student fee demands could not be generated: ${_friendlyError(e.toString())}');
      }
    } catch (e) {
      _errors.add('Could not import the file. ${_friendlyError(e.toString())}');
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) {
      _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: () {
        _loadExisting();
        if (generated > 0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Generated $generated fee demand(s). Review and approve them in Fee Demand Approval.'),
            backgroundColor: AppColors.success,
            duration: const Duration(seconds: 5),
          ));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Class Fee Demand',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Class Fee Demand', _headers),
      onSampleDownload: () => _exportSampleData('Class Fee Demand', _headers, isSchool ? [
        ['I A',   'TERM 1', 'TUITION FEE',   '12000', '',    '',     '',        '30-06-2026', '', '', ''],
        ['I A',   'TERM 1', 'ADMISSION FEE', '5000',  'New', '',     '',        '30-06-2026', '', '', ''],
        ['I A',   'TERM 1', 'HOSTEL FEE',    '15000', '',    '',     'Hostler', '30-06-2026', '', '', ''],
        ['LKG A', 'TERM 1', 'UNIFORM FEE',   '1800',  'New', 'Girl', '',        '30-06-2026', '', '', ''],
      ] : [
        ['I',   'I TERM', 'SCHOOL FEES',  isSchool ? '' : 'MANAGEMENT QUOTA', '10080', '31-05-2025', 'Y', '', '', '', '', ''],
        ['I',   'JUNE',   'TUITION FEES', isSchool ? '' : 'MANAGEMENT QUOTA', '700',   '30-06-2025', 'N', '', '', '', '', ''],
        ['XII', 'I TERM', 'SCHOOL FEES',  isSchool ? '' : 'GOVERNMENT QUOTA', '15410', '31-05-2025', 'Y', '', '', '', '', ''],
        ['XII', 'JUNE',   'VAN FEES',     isSchool ? '' : 'GOVERNMENT QUOTA', '810',   '30-06-2025', 'N', '', '', '', '', ''],
      ]),
      saving: _saving, savingLabel: _genStatus, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: isSchool
          ? const ['Course', 'Class', 'Semester', 'Fee Type', 'Amount', 'New/Old', 'Boy/Girl', 'Day Scholar/Hosteller', 'Due Date']
          : const ['Course', 'Class', 'Semester', 'Fee Type', 'Amount', 'Due Date', 'Admission Type'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
      // AMOUNT: col 4 in the saved list; col 3 in a school file.
      rightAlignCols: isSchool && _rows.isNotEmpty ? const {3} : const {4},
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// ADMISSION TYPE / QUOTA - simple lookup tables
// (ids are user-supplied; no auto-trigger)
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

/// Fill a blank first-column ID with the next number after the highest in
/// [table].[idCol] or in the file itself, so an import never has to carry
/// IDs. Rows with no name (column 2) are left untouched and skipped later.
Future<List<List<dynamic>>> _fillBlankIds(String table, String idCol, List<List<dynamic>> rows) async {
  var next = 0;
  try {
    final r = await SupabaseService.fromSchema(table).select(idCol).order(idCol, ascending: false).limit(1);
    if ((r as List).isNotEmpty) next = (r.first[idCol] as num?)?.toInt() ?? 0;
  } catch (_) {}
  for (final row in rows) {
    final v = int.tryParse(row.isNotEmpty ? row[0].toString().trim() : '');
    if (v != null && v > next) next = v;
  }
  return rows.map((row) {
    final m = List<dynamic>.from(row);
    if (m.isEmpty) m.add('');
    final hasName = m.length > 1 && m[1].toString().trim().isNotEmpty;
    if (m[0].toString().trim().isEmpty && hasName) m[0] = '${++next}';
    return m;
  }).toList();
}

Future<Map<String, int>> _directLookupImport({
  required int insId,
  required String table,
  required String idCol,
  required String nameCol,
  required List<List<dynamic>> rows,
  required bool hasInsId,
  required List<String> errorsOut,
  String? createdBy,
}) async {
  int imported = 0;
  int skipped = 0;
  rows = await _fillBlankIds(table, idCol, rows);
  for (int i = 0; i < rows.length; i++) {
    try {
      final row = rows[i];
      final idRaw = row.isNotEmpty ? row[0].toString().trim() : '';
      final name = row.length > 1 ? row[1].toString().trim() : '';
      final id = int.tryParse(idRaw);
      if (id == null || name.isEmpty) {
        skipped++;
        errorsOut.add('Row ${i + 2}: ID or name is missing or invalid');
        continue;
      }
      final record = <String, dynamic>{
        idCol: id,
        nameCol: name,
        'activestatus': 1,
      };
      if (hasInsId) record['ins_id'] = insId;
      if (createdBy != null && createdBy.trim().isNotEmpty) record['createdby'] = createdBy.trim();
      await SupabaseService.importSchemaRows(table, [record], conflictCol: idCol);
      imported++;
    } catch (e) {
      skipped++;
      errorsOut.add('Row ${i + 2}: ${_friendlyError(e.toString())}');
    }
  }
  return {'imported': imported, 'skipped': skipped};
}

class _AdmissionTypeTab extends StatefulWidget {
  const _AdmissionTypeTab();
  @override
  State<_AdmissionTypeTab> createState() => _AdmissionTypeTabState();
}

class _AdmissionTypeTabState extends State<_AdmissionTypeTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _headers = ['Adm ID *', 'Admission Name *'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() { super.initState(); _loadExisting(); }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final rows = await SupabaseService.fromSchema('admissiontype').select('adm_id, admname').eq('activestatus', 1).order('adm_id', ascending: true);
      if (mounted) setState(() {
        _existingRows = (rows as List).map((r) => [r['admname']?.toString() ?? '']).toList();
        _isLoadingExisting = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    setState(() { _fileName = result.files.single.name; _rows = parsed.sublist(1); _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final errs = <int, String>{};
    for (int i = 0; i < _rows.length; i++) {
      final idRaw = _rows[i].isNotEmpty ? _rows[i][0]?.toString().trim() ?? '' : '';
      final name = _rows[i].length > 1 ? _rows[i][1]?.toString().trim() ?? '' : '';
      // Blank ID is generated on save; a value that is not a number is an error.
      if (idRaw.isNotEmpty && int.tryParse(idRaw) == null) { errs[i] = 'Admission Type ID must be a number'; continue; }
      if (name.isEmpty) { errs[i] = 'Missing: Admission Type Name'; }
    }
    setState(() { _rowErrors = errs; _isValidated = errs.isEmpty; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(errs.isEmpty ? 'Validation passed. Click Save to import.' : '${errs.length} row(s) have errors. Fix the rows marked in red and validate again.'),
      backgroundColor: errs.isEmpty ? AppColors.success : AppColors.error,
    ));
  }

  void _close() { setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; }); }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    final errs = <String>[];
    final result = await _directLookupImport(
      insId: insId, table: 'admissiontype', idCol: 'adm_id', nameCol: 'admname',
      rows: _rows, hasInsId: true, errorsOut: errs, createdBy: auth.userName,
    );
    _imported = result['imported'] ?? 0;
    _skipped = result['skipped'] ?? 0;
    _errors = errs;
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) {
      _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Admission Types',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Admission Type', _headers),
      onSampleDownload: () => _exportSampleData('Admission Type', _headers, [
        ['1', 'GOVERNMENT QUOTA'],
        ['2', 'MANAGEMENT QUOTA'],
        ['3', 'NRI QUOTA'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Admission Type Name'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

class _CommunityTab extends StatefulWidget {
  const _CommunityTab();
  @override
  State<_CommunityTab> createState() => _CommunityTabState();
}

class _CommunityTabState extends State<_CommunityTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _headers = ['Com ID *', 'Community Name *'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() { super.initState(); _loadExisting(); }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final rows = await SupabaseService.fromSchema('community').select('com_id, comname').eq('activestatus', 1).order('com_id', ascending: true);
      if (mounted) setState(() {
        _existingRows = (rows as List).map((r) => [r['comname']?.toString() ?? '']).toList();
        _isLoadingExisting = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    setState(() { _fileName = result.files.single.name; _rows = parsed.sublist(1); _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final errs = <int, String>{};
    for (int i = 0; i < _rows.length; i++) {
      final idRaw = _rows[i].isNotEmpty ? _rows[i][0]?.toString().trim() ?? '' : '';
      final name = _rows[i].length > 1 ? _rows[i][1]?.toString().trim() ?? '' : '';
      // Blank ID is generated on save; a value that is not a number is an error.
      if (idRaw.isNotEmpty && int.tryParse(idRaw) == null) { errs[i] = 'Community ID must be a number'; continue; }
      if (name.isEmpty) { errs[i] = 'Missing: Community Name'; }
    }
    setState(() { _rowErrors = errs; _isValidated = errs.isEmpty; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(errs.isEmpty ? 'Validation passed. Click Save to import.' : '${errs.length} row(s) have errors. Fix the rows marked in red and validate again.'),
      backgroundColor: errs.isEmpty ? AppColors.success : AppColors.error,
    ));
  }

  void _close() { setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; }); }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    final errs = <String>[];
    final result = await _directLookupImport(
      insId: insId, table: 'community', idCol: 'com_id', nameCol: 'comname',
      rows: _rows, hasInsId: true, errorsOut: errs, createdBy: auth.userName,
    );
    _imported = result['imported'] ?? 0;
    _skipped = result['skipped'] ?? 0;
    _errors = errs;
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) {
      _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Communities',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Community', _headers),
      onSampleDownload: () => _exportSampleData('Community', _headers, [
        ['1', 'BC'],
        ['2', 'MBC'],
        ['3', 'SC'],
        ['4', 'ST'],
        ['5', 'OC'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Community Name'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

class _QuotaTab extends StatefulWidget {
  const _QuotaTab();
  @override
  State<_QuotaTab> createState() => _QuotaTabState();
}

class _QuotaTabState extends State<_QuotaTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _headers = ['Quo ID *', 'Quota Name *'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() { super.initState(); _loadExisting(); }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final rows = await SupabaseService.fromSchema('quota').select('quo_id, quoname').eq('ins_id', insId).eq('activestatus', 1).order('quo_id', ascending: true);
      if (mounted) setState(() {
        _existingRows = (rows as List).map((r) => [r['quoname']?.toString() ?? '']).toList();
        _isLoadingExisting = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    setState(() { _fileName = result.files.single.name; _rows = parsed.sublist(1); _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final errs = <int, String>{};
    for (int i = 0; i < _rows.length; i++) {
      final idRaw = _rows[i].isNotEmpty ? _rows[i][0]?.toString().trim() ?? '' : '';
      final name = _rows[i].length > 1 ? _rows[i][1]?.toString().trim() ?? '' : '';
      // Blank ID is generated on save; a value that is not a number is an error.
      if (idRaw.isNotEmpty && int.tryParse(idRaw) == null) { errs[i] = 'Quota ID must be a number'; continue; }
      if (name.isEmpty) { errs[i] = 'Missing: Quota Name'; }
    }
    setState(() { _rowErrors = errs; _isValidated = errs.isEmpty; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(errs.isEmpty ? 'Validation passed. Click Save to import.' : '${errs.length} row(s) have errors. Fix the rows marked in red and validate again.'),
      backgroundColor: errs.isEmpty ? AppColors.success : AppColors.error,
    ));
  }

  void _close() { setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; }); }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    final errs = <String>[];
    final result = await _directLookupImport(
      insId: insId, table: 'quota', idCol: 'quo_id', nameCol: 'quoname',
      rows: _rows, hasInsId: true, errorsOut: errs, createdBy: auth.userName,
    );
    _imported = result['imported'] ?? 0;
    _skipped = result['skipped'] ?? 0;
    _errors = errs;
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) {
      _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Quotas',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Quota', _headers),
      onSampleDownload: () => _exportSampleData('Quota', _headers, [
        ['1', 'GENERAL'],
        ['2', 'OBC'],
        ['3', 'SC'],
        ['4', 'ST'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Quota Name'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// SEMESTER TAB
// ═══════════════════════════════════════════════════════════════════

class _SemesterTab extends StatefulWidget {
  const _SemesterTab();
  @override
  State<_SemesterTab> createState() => _SemesterTabState();
}

class _SemesterTabState extends State<_SemesterTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _headers = ['Semester ID *', 'Semester Name *', 'Semester Short', 'Semester Type', 'Semester Order'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  // Semester Type free-text → the stored code: S(emester) / M(onthly) / Y(early).
  static String _semType(String raw) {
    final t = raw.trim().toUpperCase();
    // School: a semester is a TERM, flagged T (S or T in the file both mean it).
    final def = isSchool ? 'T' : 'S';
    if (t.isEmpty) return def;
    if (t.startsWith('M')) return 'M';
    if (t.startsWith('Y') || t.startsWith('A')) return 'Y';
    return def;
  }

  Future<void> _loadExisting() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId;
    if (insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final rows = await SupabaseService.fromSchema('semester').select('*').eq('ins_id', insId).eq('activestatus', 1);
      final sorted = List<Map<String, dynamic>>.from(rows.cast<Map<String, dynamic>>())
        ..sort((a, b) {
          final oa = (a['ordid'] is num) ? (a['ordid'] as num).toInt() : (a['sem_id'] is num ? (a['sem_id'] as num).toInt() : 1 << 30);
          final ob = (b['ordid'] is num) ? (b['ordid'] as num).toInt() : (b['sem_id'] is num ? (b['sem_id'] as num).toInt() : 1 << 30);
          return oa.compareTo(ob);
        });
      if (mounted) setState(() {
        _existingRows = sorted.map((r) => [
          r['semname'] ?? '',
          r['semshort'] ?? '',
          r['semtype'] ?? '',
        ]).toList();
        _isLoadingExisting = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoadingExisting = false);
    }
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning),
        );
      }
      return;
    }
    setState(() { _fileName = result.files.single.name; _rows = parsed.sublist(1); _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final rowErrs = <int, String>{};
    for (int i = 0; i < _rows.length; i++) {
      final idRaw = _rows[i].isNotEmpty ? _rows[i][0]?.toString().trim() ?? '' : '';
      final name = _rows[i].length > 1 ? _rows[i][1]?.toString().trim() ?? '' : '';
      // Blank ID is generated on save; a value that is not a number is an error.
      if (idRaw.isNotEmpty && int.tryParse(idRaw) == null) { rowErrs[i] = 'Invalid Semester ID'; continue; }
      if (name.isEmpty) rowErrs[i] = 'Missing: Semester Name';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors. Fix the rows marked in red and validate again.'), backgroundColor: AppColors.error));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed. Click Save to import.'), backgroundColor: AppColors.success));
    }
  }

  void _close() {
    setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; });
  }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    final filled = await _fillBlankIds('semester', 'sem_id', _rows);
    for (final row in filled) {
      if (row.length < 2 || row[1].toString().trim().isEmpty) { _skipped++; continue; }
      try {
        final semId = int.tryParse(row[0].toString().trim());
        if (semId == null) { _skipped++; _errors.add(schoolTerm('Row with name ${row[1]}: invalid Semester ID')); continue; }
        final short = row.length > 2 ? row[2].toString().trim() : '';
        final type = row.length > 3 ? _semType(row[3].toString()) : (isSchool ? 'T' : 'S');
        final order = row.length > 4 ? int.tryParse(row[4].toString().trim()) : null;
        await SupabaseService.importSchemaRows('semester', [{
          'sem_id': semId,
          'semname': row[1].toString().trim(),
          'semshort': short.isEmpty ? null : short,
          'semtype': type,
          'ordid': order,
          'ins_id': insId,
          'activestatus': 1,
        }], conflictCol: 'sem_id');
        _imported++;
      } catch (e) {
        _skipped++;
        _errors.add('${row[1]}: ${_friendlyError(e.toString())}');
      }
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Semesters',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Semester', _headers),
      onSampleDownload: () => _exportSampleData('Semester', _headers, [
        ['1', 'I TERM',  'IT',   'S', '1'],
        ['2', 'II TERM', 'IIT',  'S', '2'],
        ['3', 'JUNE',    'JUN',  'M', '3'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Semester', 'Short Name', 'Type'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}


// ═══════════════════════════════════════════════════════════════════
// FEE COLLECTION (PAYMENT) IMPORT TAB
// ═══════════════════════════════════════════════════════════════════
// Uses the shared _buildImportCard look. Not shown in the internal pill bar
// (master-data only) — reached via the "Fee Collection Import" menu, which opens
// MasterImportScreen at this tab with showInternalTabs:false. Records each
// receipt via the import_payment RPC and decrements the paid demands' balances.

class _FeeCollectionImportTab extends StatefulWidget {
  const _FeeCollectionImportTab();
  @override
  State<_FeeCollectionImportTab> createState() => _FeeCollectionImportTabState();
}

class _FeeCollectionImportTabState extends State<_FeeCollectionImportTab> with AutomaticKeepAliveClientMixin {
  List<List<dynamic>> _rows = [];
  String? _fileName;
  bool _saving = false;
  bool _isValidated = false;
  int _imported = 0, _skipped = 0;
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};

  // Import mode: 'fee' = fee-collection (Demand No → import_payment) |
  // 'misc' = miscellaneous collection (Fee Type → misc_collection).
  String _mode = 'fee';

  // Template column order (positional). Roll No / Demand No / Paid Amount required.
  static const _feeHeaders = ['Receipt No', 'Pay Date', 'Roll No *', 'Demand No *', 'Paid Amount *', 'Pay Method', 'Reference', 'Type', 'Year'];
  static const _feeOrder = ['receiptno', 'paydate', 'stuadmno', 'demno', 'amount', 'method', 'reference', 'type', 'year'];
  // Misc format: Receipt No, Pay Date, Student type (S/O), Roll No, Name, Class,
  // Address, City, Fee Type, Paid Amount, Payment Mode, Reference No.
  static const _miscHeaders = ['Receipt No', 'Pay Date', 'Student type', 'Roll No', 'Name', 'Class', 'Address', 'City', 'Fee Type *', 'Paid Amount *', 'Payment Mode', 'Reference No'];
  static const _miscOrder = ['receiptno', 'paydate', 'seltype', 'stuadmno', 'stuname', 'stuclass', 'address', 'city', 'feetype', 'amount', 'method', 'reference'];

  List<String> get _headers => _mode == 'misc' ? _miscHeaders : _feeHeaders;
  List<String> get _order => _mode == 'misc' ? _miscOrder : _feeOrder;

  static String _cell(List r, int j) => j < r.length ? (r[j]?.toString().trim() ?? '') : '';

  @override
  bool get wantKeepAlive => true;

  static String? _mapHeader(String h) {
    final k = h.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    const m = {
      'receiptno': 'receiptno', 'receipt': 'receiptno', 'paynumber': 'receiptno', 'receiptnumber': 'receiptno', 'billno': 'receiptno', 'rcptno': 'receiptno',
      'paydate': 'paydate', 'date': 'paydate', 'paymentdate': 'paydate', 'collectiondate': 'paydate', 'receiptdate': 'paydate',
      'rollno': 'stuadmno', 'roll': 'stuadmno', 'admno': 'stuadmno', 'admissionno': 'stuadmno', 'admissionnumber': 'stuadmno', 'stuadmno': 'stuadmno', 'registerno': 'stuadmno', 'regno': 'stuadmno',
      'demandno': 'demno', 'demno': 'demno', 'demand': 'demno', 'docno': 'demno',
      'paidamount': 'amount', 'amount': 'amount', 'paid': 'amount', 'collectedamount': 'amount', 'payamount': 'amount', 'amountpaid': 'amount',
      'paymethod': 'method', 'method': 'method', 'mode': 'method', 'paymode': 'method', 'paymentmode': 'method', 'paymentmethod': 'method',
      'reference': 'reference', 'ref': 'reference', 'payreference': 'reference', 'transactionid': 'reference', 'txnno': 'reference', 'chequeno': 'reference', 'referenceno': 'reference',
      'type': 'type', 'demseqtype': 'type', 'seqtype': 'type', 'demandtype': 'type',
      'year': 'year', 'yr': 'year', 'academicyear': 'year', 'feeyear': 'year', 'demandyear': 'year', 'demfeeyear': 'year',
      // Misc-collection columns
      'studenttype': 'seltype', 'stutype': 'seltype', 'selection': 'seltype', 'seltype': 'seltype',
      'name': 'stuname', 'studentname': 'stuname', 'stuname': 'stuname',
      'class': 'stuclass', 'stuclass': 'stuclass', 'classname': 'stuclass', 'className': 'stuclass',
      'address': 'address', 'stuaddress': 'address',
      'city': 'city', 'stucity': 'city',
      'feetype': 'feetype', 'feename': 'feetype', 'miscfee': 'feetype', 'particulars': 'feetype',
    };
    return m[k];
  }

  static String? _iso(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final parts = t.split(RegExp(r'[/\-.]'));
    if (parts.length >= 3) {
      final p0 = int.tryParse(parts[0]), p1 = int.tryParse(parts[1]), p2 = int.tryParse(parts[2].split(' ').first);
      if (p0 != null && p1 != null && p2 != null) {
        int y, m, d;
        if (parts[0].length == 4) { y = p0; m = p1; d = p2; } else { d = p0; m = p1; y = p2 < 100 ? p2 + 2000 : p2; }
        if (m >= 1 && m <= 12 && d >= 1 && d <= 31) return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
      }
    }
    final dt = DateTime.tryParse(t);
    return dt == null ? null : dt.toIso8601String().split('T').first;
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'xls', 'csv']);
    if (result == null) return;
    List<List<dynamic>> parsed;
    try {
      parsed = _parseExcel(result.files.single.path!);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: AppColors.error));
      return;
    }
    if (parsed.length < 2) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: AppColors.warning));
      return;
    }
    final headerCells = parsed.first.map((e) => e.toString()).toList();
    final keyIdx = <String, int>{};
    for (int i = 0; i < headerCells.length; i++) {
      final k = _mapHeader(headerCells[i]);
      if (k != null) keyIdx.putIfAbsent(k, () => i);
    }
    final rows = parsed.sublist(1).map((r) {
      return _order.map((k) {
        final idx = keyIdx[k];
        return (idx != null && idx < r.length) ? (r[idx]?.toString().trim() ?? '') : '';
      }).toList();
    }).where((r) => r.any((c) => c.toString().trim().isNotEmpty)).toList();
    setState(() { _fileName = result.files.single.name; _rows = rows; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
  }

  void _validate() {
    final rowErrs = <int, String>{};
    if (_mode == 'misc') {
      // Fee Type (8) + Paid Amount (9) required; Roll No (3) required only when
      // Student type isn't 'O' (Others = walk-in, no student record).
      for (int i = 0; i < _rows.length; i++) {
        final missing = <String>[];
        if (_cell(_rows[i], 8).isEmpty) missing.add('Fee Type');
        if (_cell(_rows[i], 9).isEmpty) missing.add('Paid Amount');
        if (_cell(_rows[i], 2).toUpperCase() != 'O' && _cell(_rows[i], 3).isEmpty) missing.add('Roll No');
        if (missing.isNotEmpty) rowErrs[i] = 'Missing: ${missing.join(', ')}';
      }
    } else {
      const req = {2: 'Roll No', 3: 'Demand No', 4: 'Paid Amount'};
      for (int i = 0; i < _rows.length; i++) {
        final missing = <String>[];
        req.forEach((j, label) {
          if (_cell(_rows[i], j).isEmpty) missing.add(label);
        });
        if (missing.isNotEmpty) rowErrs[i] = 'Missing: ${missing.join(', ')}';
      }
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(rowErrs.isEmpty ? 'Validation passed. Click Save to import.' : '${rowErrs.length} row(s) have errors. Fix the rows marked in red and validate again.'),
      backgroundColor: rowErrs.isEmpty ? AppColors.success : AppColors.error));
  }

  void _close() => setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; });

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    if (_mode == 'misc') return _saveMisc();
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    try {
      final years = await SupabaseService.getYears(insId);
      final yr = years.isNotEmpty ? years.first : null;
      final yrId = yr?['yr_id'] ?? 0;
      final yrLabel = yr?['yrlabel']?.toString() ?? '';

      final stuList = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('students').select('stu_id, stuadmno').eq('ins_id', insId).eq('activestatus', 1));
      final stuMap = <String, int>{};
      for (final s in stuList) {
        final a = s['stuadmno']?.toString().trim() ?? '';
        final id = s['stu_id'] as int?;
        if (a.isNotEmpty && id != null) { stuMap.putIfAbsent(a, () => id); stuMap.putIfAbsent(a.toLowerCase(), () => id); }
      }
      final demList = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('feedemand').select('dem_id, demno, demseqtype, demfeeyear').eq('activestatus', 1));
      // Match a demand by Demand No + Type (REGULAR/ARREAR): the same demno can
      // exist as both a regular and an arrear demand. Progressive keys — most
      // specific (demno|type|year) first, then (demno|type), then demno alone.
      final demByNoTypeYear = <String, int>{};
      final demByNoType = <String, int>{};
      final demByNo = <String, int>{};
      for (final d in demList) {
        final dn = d['demno']?.toString().trim() ?? '';
        final id = (d['dem_id'] as num?)?.toInt();
        if (dn.isEmpty || id == null) continue;
        final t = (d['demseqtype']?.toString().trim().toUpperCase() == 'ARREAR') ? 'ARREAR' : 'REGULAR';
        final y = d['demfeeyear']?.toString().trim() ?? '';
        demByNoTypeYear.putIfAbsent('$dn|$t|$y', () => id);
        demByNoType.putIfAbsent('$dn|$t', () => id);
        demByNo.putIfAbsent(dn, () => id);
      }

      String cell(List r, int j) => j < r.length ? (r[j]?.toString().trim() ?? '') : '';
      final groups = <String, List<List<dynamic>>>{};
      var auto = 0;
      for (final r in _rows) {
        final rc = cell(r, 0);
        groups.putIfAbsent(rc.isNotEmpty ? rc : '__auto_${auto++}', () => []).add(r);
      }

      for (final entry in groups.entries) {
        final rcpt = entry.key.startsWith('__auto_') ? '' : entry.key;
        final rows = entry.value;
        final label = rcpt.isEmpty ? '(no receipt no)' : rcpt;
        final admno = cell(rows.first, 2);
        final stuId = stuMap[admno] ?? stuMap[admno.toLowerCase()];
        if (stuId == null) { _skipped++; _errors.add('Receipt $label: ${schoolTerm('Roll Number')} "$admno" not found'); continue; }
        final items = <Map<String, dynamic>>[];
        for (final r in rows) {
          final dn = cell(r, 3);
          final amt = double.tryParse(cell(r, 4).replaceAll(',', '')) ?? 0;
          final typeCell = cell(r, 7).toUpperCase();
          final rowType = typeCell == 'ARREAR' ? 'ARREAR' : (typeCell == 'REGULAR' ? 'REGULAR' : '');
          final rowYear = cell(r, 8);
          int? demId;
          if (rowType.isNotEmpty) {
            demId = demByNoTypeYear['$dn|$rowType|$rowYear'] ?? demByNoType['$dn|$rowType'];
          }
          demId ??= demByNo[dn];
          if (demId == null) {
            _errors.add('Receipt $label: Demand No "$dn"${typeCell.isEmpty ? '' : ' ($typeCell)'} not found');
            continue;
          }
          items.add({'dem_id': demId, 'amount': amt});
        }
        if (items.isEmpty) { _skipped++; continue; }
        final method = cell(rows.first, 5);
        final reference = cell(rows.first, 6);
        try {
          await SupabaseService.client.rpc('import_payment', params: {
            'p_ins_id': insId, 'p_inscode': auth.inscode ?? '', 'p_stu_id': stuId,
            'p_yr_id': yrId, 'p_yrlabel': yrLabel,
            'p_paynumber': rcpt.isEmpty ? null : rcpt,
            'p_paydate': _iso(cell(rows.first, 1)),
            'p_method': method.isEmpty ? 'cash' : method,
            'p_reference': reference.isEmpty ? null : reference,
            'p_created_by': auth.userName, 'p_items': items,
          });
          _imported++;
        } catch (e) {
          _skipped++;
          _errors.add('Receipt $label: ${_friendlyError(e.toString())}');
        }
      }
    } catch (e) {
      _errors = ['Could not import the file. ${_friendlyError(e.toString())}'];
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: () {});
  }

  /// Misc-collection import — group rows by Receipt No, insert a misc_collection
  /// header (preserving the file's receipt no as mcno) + one detail per fee-type
  /// row. Student type 'O' (Others) needs no student record.
  Future<void> _saveMisc() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    try {
      final years = await SupabaseService.getYears(insId);
      final yr = years.isNotEmpty ? years.first : null;
      final yrId = yr?['yr_id'];
      final yrLabel = yr?['yrlabel']?.toString() ?? '';
      final today = DateTime.now().toIso8601String().split('T').first;

      final stuList = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('students').select('stu_id, stuadmno, courname').eq('ins_id', insId).eq('activestatus', 1));
      final stuMap = <String, int>{};
      final stuCourse = <String, String>{};
      for (final s in stuList) {
        final a = s['stuadmno']?.toString().trim() ?? '';
        final id = s['stu_id'] as int?;
        if (a.isNotEmpty && id != null) {
          stuMap.putIfAbsent(a, () => id); stuMap.putIfAbsent(a.toLowerCase(), () => id);
          final c = s['courname']?.toString().trim() ?? '';
          if (c.isNotEmpty) { stuCourse[a] = c; stuCourse[a.toLowerCase()] = c; }
        }
      }
      // Fee-type master → resolve fee_id from the Fee Type name on each row.
      final feeList = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('feetype').select('fee_id, feedesc').eq('ins_id', insId).eq('activestatus', 1));
      final feeIdByName = <String, int>{};
      for (final f in feeList) {
        final name = f['feedesc']?.toString().trim().toUpperCase() ?? '';
        final id = f['fee_id'] as int?;
        if (name.isNotEmpty && id != null) feeIdByName.putIfAbsent(name, () => id);
      }
      // Class → Course map, so the course is resolved from the file's Class column.
      final courseList = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('course').select('cour_id, courname').eq('ins_id', insId).eq('activestatus', 1));
      final courNameById = <int, String>{};
      for (final c in courseList) {
        final id = c['cour_id'] as int?;
        final n = c['courname']?.toString().trim() ?? '';
        if (id != null && n.isNotEmpty) courNameById[id] = n;
      }
      final classList = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('class').select('claname, cour_id').eq('ins_id', insId).eq('activestatus', 1));
      final courByClass = <String, String>{};
      for (final cl in classList) {
        final cn = cl['claname']?.toString().trim().toUpperCase() ?? '';
        final cid = cl['cour_id'] as int?;
        if (cn.isNotEmpty && cid != null && courNameById[cid] != null) courByClass.putIfAbsent(cn, () => courNameById[cid]!);
      }

      // Existing receipt numbers — skip re-importing a misc receipt already saved
      // (prevents duplicates on a re-run). Matched on mcno, case-insensitive.
      final existingRows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('misc_collection').select('mcno').eq('ins_id', insId).eq('activestatus', 1));
      final existingMcno = <String>{};
      for (final m in existingRows) {
        final v = m['mcno']?.toString().trim() ?? '';
        if (v.isNotEmpty) existingMcno.add(v.toLowerCase());
      }

      final groups = <String, List<List<dynamic>>>{};
      var auto = 0;
      for (final r in _rows) {
        final rc = _cell(r, 0);
        groups.putIfAbsent(rc.isNotEmpty ? rc : '__auto_${auto++}', () => []).add(r);
      }

      for (final entry in groups.entries) {
        final rcpt = entry.key.startsWith('__auto_') ? '' : entry.key;
        final rows = entry.value;
        final first = rows.first;
        final label = rcpt.isEmpty ? '(no receipt no)' : rcpt;
        // Duplicate guard: a receipt already saved in the DB is skipped.
        if (rcpt.isNotEmpty && existingMcno.contains(rcpt.toLowerCase())) {
          _skipped++;
          _errors.add('Receipt $label: already imported (duplicate)');
          continue;
        }
        final sel = _cell(first, 2).toUpperCase() == 'O' ? 'O' : 'S';
        final admno = _cell(first, 3);
        final stuId = sel == 'S' ? (stuMap[admno] ?? stuMap[admno.toLowerCase()]) : null;
        if (sel == 'S' && stuId == null) { _skipped++; _errors.add('Receipt $label: ${schoolTerm('Roll Number')} "$admno" not found'); continue; }

        final lines = <Map<String, dynamic>>[];
        double total = 0;
        for (final r in rows) {
          final ft = _cell(r, 8);
          if (ft.isEmpty) continue;
          final amt = double.tryParse(_cell(r, 9).replaceAll(',', '')) ?? 0;
          lines.add({'feetype': ft, 'amount': amt, 'fee_id': feeIdByName[ft.toUpperCase()]});
          total += amt;
        }
        if (lines.isEmpty) { _skipped++; continue; }
        // Course resolves from the file's Class column first, then the student.
        final className = _cell(first, 5).trim();
        final courname = courByClass[className.toUpperCase()] ?? stuCourse[admno] ?? stuCourse[admno.toLowerCase()];

        try {
          final hdr = await SupabaseService.fromSchema('misc_collection').insert({
            'ins_id': insId, 'inscode': auth.inscode, 'yr_id': yrId, 'yrlabel': yrLabel,
            'mcno': rcpt.isEmpty ? 'MISC${DateTime.now().millisecondsSinceEpoch}' : rcpt,
            'mcdate': _iso(_cell(first, 1)) ?? today,
            'selection': sel,
            'stu_id': stuId,
            'regno': admno.isEmpty ? null : admno,
            'stuname': _cell(first, 4),
            'stuclass': _cell(first, 5),
            'courname': courname,
            'address': _cell(first, 6).isEmpty ? null : _cell(first, 6),
            'city': _cell(first, 7).isEmpty ? null : _cell(first, 7),
            'paymode': _cell(first, 10).isEmpty ? 'Cash' : _cell(first, 10),
            'transrefno': _cell(first, 11).isEmpty ? null : _cell(first, 11),
            'totalamount': total,
            'collectedby': auth.userName,
            'activestatus': 1,
          }).select('mc_id').single();
          final mcId = hdr['mc_id'];
          await SupabaseService.fromSchema('misc_collection_detail').insert(
              lines.map((l) => {'mc_id': mcId, 'ins_id': insId, 'fee_id': l['fee_id'], 'feetype': l['feetype'], 'amount': l['amount'], 'activestatus': 1}).toList());
          _imported++;
        } catch (e) {
          _skipped++;
          _errors.add('Receipt $label: ${_friendlyError(e.toString())}');
        }
      }
    } catch (e) {
      _errors = ['Could not import the file. ${_friendlyError(e.toString())}'];
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: () {});
  }

  void _setMode(String m) {
    if (m == _mode) return;
    setState(() { _mode = m; _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; });
  }

  Widget _modeToggle() {
    Widget seg(String label, String value, IconData icon) {
      final sel = _mode == value;
      return Expanded(child: InkWell(
        onTap: () => _setMode(value),
        borderRadius: BorderRadius.circular(8.r),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(vertical: 9.h),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? AppColors.primaryLight : Colors.transparent,
            borderRadius: BorderRadius.circular(8.r),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: sel ? AppColors.primary : AppColors.textSecondary),
            SizedBox(width: 7.w),
            Text(label, style: AppUI.label.copyWith(color: sel ? AppColors.primary : AppColors.textSecondary)),
          ]),
        ),
      ));
    }
    return Container(
      margin: EdgeInsets.only(bottom: 10.h),
      padding: EdgeInsets.all(4.w),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.border)),
      child: Row(children: [
        seg('Fee Collection', 'fee', Icons.receipt_long_outlined),
        SizedBox(width: 4.w),
        seg('Miscellaneous Collection', 'misc', Icons.list_alt_outlined),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isMisc = _mode == 'misc';
    return Column(children: [
      _modeToggle(),
      Expanded(child: _buildImportCard(
        title: isMisc ? 'Import Miscellaneous Collections' : 'Import Fee Collections',
        headers: _headers,
        rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
        onBrowse: _browse,
        onSave: _rows.isNotEmpty && _isValidated ? _save : null,
        onTemplate: () => _exportTemplate(isMisc ? 'Misc Collection' : 'Fee Collection', _headers),
        onSampleDownload: () => _exportSampleData(isMisc ? 'Misc Collection' : 'Fee Collection', _headers, isMisc
            ? [
                ['FC26/00005', '01-07-2026', 'S', '421325243029', 'MOHAMMED FAWAAZ L', 'B.TECH - AI&DS-II', '', '', 'BONAFIDE CERTIFICATE', '50', 'Cash', ''],
                ['FC26/00006', '01-07-2026', 'O', '', 'HEMAVATHI B', 'I AI DS', '', '', 'APPLICATION', '500', 'Cash', ''],
                ['FC26/00037', '02-07-2026', 'S', '421324622001', 'ABI S', 'MCA TC 26', '', '', 'LIBRARY FINE', '150', 'Cash', ''],
              ]
            : [
                ['R0001', '05-06-2026', '20252617', 'DM00001', '5000', 'cash', ''],
                ['R0001', '05-06-2026', '20252617', 'DM00002', '2000', 'cash', ''],
                ['R0002', '06-06-2026', '20252619', 'DM00003', '7000', 'upi', 'UPI-88213'],
              ]),
        saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
        onDismissResult: () {},
        onValidate: _rows.isNotEmpty ? _validate : null,
        onClose: _close,
        isValidated: _isValidated,
        // Import shows ONLY the data being imported — no existing rows.
        existingRows: const [],
        existingHeaders: const ['Receipt No', 'Pay Date', 'Amount', 'Method'],
        isLoadingExisting: false,
        rowErrors: _rowErrors,
        cellErrors: _cellErrors,
        rightAlignCols: isMisc ? const {9} : const {4},
      )),
    ]);
  }
}
