import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:file_picker/file_picker.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/pill_tab.dart';
import 'package:excel/excel.dart' as xl;
import '../../utils/app_theme.dart';
import '../../services/supabase_service.dart';
import 'package:provider/provider.dart';
import '../../utils/auth_provider.dart';
import '../../utils/friendly_error.dart';

void _showImportResultDialog(BuildContext context, {required int imported, required int skipped, List<String> errors = const [], VoidCallback? onDone}) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Center(
      child: Container(
        width: 420.w,
        padding: EdgeInsets.all(32.w),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(errors.isEmpty ? 'tick-circle' : 'warning-2', size: 64.sp, color: errors.isEmpty ? AppColors.success : AppColors.error),
            SizedBox(height: 16.h),
            Text(errors.isEmpty ? 'Import Complete' : 'Import Completed with Errors', style: TextStyle(fontSize: 18.sp, fontWeight: FontWeight.w700)),
            SizedBox(height: 12.h),
            Text('$imported imported successfully, $skipped skipped', style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
            if (errors.isNotEmpty) ...[
              SizedBox(height: 16.h),
              Container(
                height: 150.h,
                padding: EdgeInsets.all(12.w),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8.r),
                ),
                child: ListView(
                  children: errors.map((e) => Padding(
                    padding: EdgeInsets.only(bottom: 4.h),
                    child: Text(e, style: TextStyle(fontSize: 13.sp, color: AppColors.error)),
                  )).toList(),
                ),
              ),
            ],
            SizedBox(height: 20.h),
            ElevatedButton(
              onPressed: () { Navigator.pop(ctx); onDone?.call(); },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
              ),
              child: Text('Done', style: TextStyle(fontWeight: FontWeight.w600)),
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
    _tabCtrl = TabController(length: 8, vsync: this, initialIndex: widget.initialTabIndex.clamp(0, 7));
  }

  @override
  void didUpdateWidget(covariant MasterImportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTabIndex != oldWidget.initialTabIndex) {
      final i = widget.initialTabIndex.clamp(0, 7);
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
        // Tabs (pill style, same as Reports) — hidden when driven by sidebar sub-menu
        if (widget.showInternalTabs)
          ListenableBuilder(
            listenable: _tabCtrl,
            builder: (context, _) {
              final selected = _tabCtrl.index;
              final tabLabels = ['Admission Type', 'Quota', 'Course', 'Class', 'Fee Group', 'Fee Type', 'Concession', 'Class Fee Demand'];
              final tabIcons = ['teacher', 'book-1', 'category-2', 'receipt-1', 'receipt-discount', 'note-2', 'user-tick', 'ticket'];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < tabLabels.length; i++) ...[
                        PillTab(
                          icon: tabIcons[i],
                          label: tabLabels[i],
                          selected: selected == i,
                          onTap: () => _tabCtrl.animateTo(i),
                        ),
                        if (i < tabLabels.length - 1) SizedBox(width: PillTab.gap(context)),
                      ],
                    ],
                  ),
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
              children: const [
                _AdmissionTypeTab(),
                _QuotaTab(),
                _CourseTab(),
                _ClassTab(),
                _FeeGroupTab(),
                _FeeTypeTab(),
                _ConcessionTab(),
                _ClassFeeDemandTab(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════
// STAGING TABLE IMPORT HELPER
// ═══════════════════════════════════════════════

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

String _friendlyError(String msg) {
  final m = msg.toLowerCase();
  if (m.contains('duplicate key') || m.contains('unique constraint')) return 'Duplicate record found';
  if (m.contains('not-null') || m.contains('null value')) {
    final match = RegExp(r'column "(\w+)"').firstMatch(msg);
    return '${match?.group(1) ?? 'Field'} is required';
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

// ═══════════════════════════════════════════════
// GENERIC HELPERS
// ═══════════════════════════════════════════════

List<List<dynamic>> _parseExcel(String path) {
  final bytes = File(path).readAsBytesSync();
  final excel = xl.Excel.decodeBytes(bytes);
  final sheet = excel.tables[excel.tables.keys.first]!;
  return sheet.rows.map((r) => r.map((c) => c?.value?.toString().trim() ?? '').toList()).toList();
}

Future<void> _exportSampleData(String sheetName, List<String> headers, List<List<String>> sampleRows) async {
  final savePath = await FilePicker.platform.saveFile(
    dialogTitle: 'Save Sample Data',
    fileName: '${sheetName.toLowerCase().replaceAll(' ', '_')}_sample.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (savePath == null) return;
  final workbook = xl.Excel.createExcel();
  final sheet = workbook[sheetName];
  final headerStyle = xl.CellStyle(
    bold: true,
    backgroundColorHex: xl.ExcelColor.fromHexString('#1B2A4A'),
    fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
  );
  for (int i = 0; i < headers.length; i++) {
    final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    cell.value = xl.TextCellValue(headers[i]);
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
    fileName: '${sheetName.toLowerCase().replaceAll(' ', '_')}_errors.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (savePath == null) return;
  final workbook = xl.Excel.createExcel();
  final sheet = workbook[sheetName];
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
    cell.value = xl.TextCellValue(allHeaders[i]);
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
    errorCell.value = xl.TextCellValue(rowErrors[r] ?? '');
    if (errs.isNotEmpty) errorCell.cellStyle = errorCellStyle;
  }
  workbook.delete('Sheet1');
  final bytes = workbook.encode();
  if (bytes != null) File(savePath).writeAsBytesSync(bytes);
}

Future<void> _exportTemplate(String sheetName, List<String> headers) async {
  final savePath = await FilePicker.platform.saveFile(
    dialogTitle: 'Save Template',
    fileName: '${sheetName.toLowerCase().replaceAll(' ', '_')}_template.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (savePath == null) return;
  final workbook = xl.Excel.createExcel();
  final sheet = workbook[sheetName];
  final headerStyle = xl.CellStyle(
    bold: true,
    backgroundColorHex: xl.ExcelColor.fromHexString('#1B2A4A'),
    fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
  );
  for (int i = 0; i < headers.length; i++) {
    final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    cell.value = xl.TextCellValue(headers[i]);
    cell.cellStyle = headerStyle;
    sheet.setColumnWidth(i, 18);
  }
  workbook.delete('Sheet1');
  final bytes = workbook.encode();
  if (bytes != null) File(savePath).writeAsBytesSync(bytes);
}

/// Convert per-row error messages into per-cell column indices by parsing
/// the canonical patterns the tabs emit:
///   - "Missing: A, B"  → highlight headers matching A and B (case-insensitive)
///   - "Fee Group "X" not found ..."  → highlight the "Fee Group" header
///   - "Class ID "X" not found ..."   → highlight the "Class ID" header
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
    final missing = RegExp(r'Missing:\s*([^•]+)').firstMatch(msg);
    if (missing != null) {
      for (final raw in missing.group(1)!.split(',')) {
        final idx = headerIndexFor(raw.trim());
        if (idx != null) cells.add(idx);
      }
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
    child: Text(text.toUpperCase(), style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.3.w)),
  );
  return width != null ? SizedBox(width: width, child: child) : Expanded(flex: flex, child: child);
}

Widget _gridHeaderDivider() {
  return Container(width: 1, height: 44.h, color: AppColors.border);
}

Widget _gridDataCell(String text, {double? width, int flex = 1, bool center = false, bool right = false}) {
  final child = Container(
    padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
    alignment: right ? Alignment.centerRight : center ? Alignment.center : Alignment.centerLeft,
    decoration: BoxDecoration(
      border: Border(right: BorderSide(color: AppColors.border.withValues(alpha: 0.3))),
    ),
    child: Text(text, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis),
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
  // rowIdx → set of column indices that failed validation. When non-empty,
  // the Format to Excel button switches to "Export with Errors" so the user
  // can fix issues offline and re-import.
  Map<int, Set<int>> cellErrors = const {},
  Set<int> rightAlignCols = const {},
}) {
  final bool showExisting = rows.isEmpty && existingRows.isNotEmpty;
  final displayHeaders = showExisting ? existingHeaders : headers;
  final displayRows = showExisting ? existingRows : rows;
  final bool hasCellErrors = !showExisting && cellErrors.isNotEmpty;
  return Container(
    padding: EdgeInsets.all(16.w),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10.r),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title bar
        Row(
          children: [
            AppIcon('document-upload', size: 20, color: AppColors.accent),
            SizedBox(width: 8.w),
            Text(title, style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w700)),
            const Spacer(),
            if (fileName != null)
              Text(fileName, style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
            SizedBox(width: 12.w),
            ElevatedButton.icon(
              onPressed: onBrowse,
              icon: AppIcon('document-upload', size: 16),
              label: const Text('Import'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
              ),
            ),
            SizedBox(width: 8.w),
            ElevatedButton.icon(
              onPressed: hasCellErrors
                  ? () => _exportRowsWithErrors(
                        sheetName: title,
                        headers: headers,
                        rows: rows,
                        cellErrors: cellErrors,
                        rowErrors: rowErrors,
                      )
                  : onTemplate,
              icon: AppIcon(hasCellErrors ? 'document-download' : 'grid-1', size: 16),
              label: Text(hasCellErrors ? 'Export with Errors' : 'Format to Excel'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF217346),
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
              ),
            ),
            if (onSampleDownload != null) ...[
              SizedBox(width: 8.w),
              ElevatedButton.icon(
                onPressed: onSampleDownload,
                icon: AppIcon('document-download', size: 16),
                label: const Text('Sample Data'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE65100),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                  textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
        if (showResult) ...[
          SizedBox(height: 8.h),
          Container(
            padding: EdgeInsets.all(10.w),
            decoration: BoxDecoration(
              color: errors.isEmpty ? const Color(0xFFE6F4EA) : const Color(0xFFFCE4E4),
              borderRadius: BorderRadius.circular(8.r),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppIcon(errors.isEmpty ? 'tick-circle' : 'warning-2', color: errors.isEmpty ? AppColors.success : AppColors.error, size: 18),
                    SizedBox(width: 8.w),
                    Text('$imported imported, $skipped skipped', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.sp)),
                    const Spacer(),
                    IconButton(icon: AppIcon.linear('close-circle', size: 16), onPressed: onDismissResult, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
                  ],
                ),
                if (errors.isNotEmpty) ...[
                  SizedBox(height: 4.h),
                  ...errors.take(5).map((e) => Padding(
                    padding: EdgeInsets.only(top: 2.h),
                    child: Text(e, style: TextStyle(fontSize: 13.sp, color: Colors.red)),
                  )),
                  if (errors.length > 5) Text('... and ${errors.length - 5} more errors', style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
                ],
              ],
            ),
          ),
        ],
        SizedBox(height: 8.h),

        // Data grid
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(8.r),
            ),
            child: Column(
              children: [
                // Header row
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.tableHeadBg,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(7.r),
                      topRight: Radius.circular(7.r),
                    ),
                  ),
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
                        Text('Existing Records (${existingRows.length})', style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
                      ],
                    ),
                  ),
                // Data rows
                Expanded(
                  child: isLoadingExisting && rows.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : displayRows.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AppIcon('element-4', size: 48.sp, color: AppColors.textPrimary.withValues(alpha: 0.3)),
                                  SizedBox(height: 8.h),
                                  Text('No data loaded', style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
                                  SizedBox(height: 4.h),
                                  Text('Click Browse to load a CSV or Excel file', style: TextStyle(fontSize: 13.sp, color: AppColors.textPrimary)),
                                ],
                              ),
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
                                    color: i.isEven ? Colors.white : AppColors.surface,
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
                                              message: rowErrors[i] ?? '',
                                              child: Container(
                                                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 10.h),
                                                alignment: rightAlignCols.contains(j) ? Alignment.centerRight : Alignment.centerLeft,
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFFCE4E4),
                                                  border: Border(right: BorderSide(color: AppColors.border.withValues(alpha: 0.3))),
                                                ),
                                                child: Text(text, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis),
                                              ),
                                            ),
                                          );
                                        }),
                                        if (hasRowError)
                                          Padding(
                                            padding: EdgeInsets.only(right: 8.w),
                                            child: Tooltip(
                                              message: rowErrors[i] ?? '',
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
            Text('${displayRows.length} rows${showExisting ? ' (existing)' : ''}', style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: rows.isNotEmpty && !saving ? onValidate : null,
              icon: AppIcon.linear('tick-circle', size: 16),
              label: const Text('Validate'),
              style: OutlinedButton.styleFrom(
                foregroundColor: rows.isNotEmpty && !saving ? AppColors.accent : AppColors.textPrimary,
                padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                textStyle: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600),
              ),
            ),
            SizedBox(width: 8.w),
            ElevatedButton.icon(
              onPressed: saving ? null : (isValidated ? onSave : null),
              icon: saving
                  ? SizedBox(width: 14.w, height: 14.h, child: const CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : AppIcon('save-2', size: 16),
              label: Text(saving ? 'Saving...' : 'Save'),
              style: ElevatedButton.styleFrom(
                backgroundColor: isValidated ? AppColors.accent : Colors.grey.shade300,
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 28.w, vertical: 20.h),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                textStyle: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600),
              ),
            ),
            SizedBox(width: 8.w),
            OutlinedButton(
              onPressed: onClose,
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
                textStyle: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600),
              ),
              child: const Text('Close'),
            ),
          ],
        ),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════
// 1. FEE GROUP TAB
// ═══════════════════════════════════════════════
// COURSE TAB
// ═══════════════════════════════════════════════

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
      // Sort client-side by ordid (NULLS last), then courname — mirrors the
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
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: Colors.orange),
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
      if (idRaw.isEmpty || int.tryParse(idRaw) == null) { rowErrs[i] = 'Invalid Course ID'; continue; }
      if (name.isEmpty) rowErrs[i] = 'Missing: Course Name';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors'), backgroundColor: Colors.red));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed! Click Save to import.'), backgroundColor: Colors.green));
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
    for (final row in _rows) {
      if (row.length < 2 || row[1].toString().trim().isEmpty) { _skipped++; continue; }
      try {
        final courId = int.tryParse(row[0].toString().trim());
        if (courId == null) { _skipped++; _errors.add('Row with name ${row[1]}: invalid Course ID'); continue; }
        await SupabaseService.fromSchema('course').upsert({
          'cour_id': courId,
          'courname': row[1].toString().trim(),
          'ordid': row.length > 2 ? int.tryParse(row[2].toString().trim()) : null,
          'ins_id': insId,
          'activestatus': 1,
        }, onConflict: 'cour_id');
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

// ═══════════════════════════════════════════════
// CLASS TAB
// ═══════════════════════════════════════════════

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
  static const _headers = ['Class ID *', 'Class Name *', 'Active Status', 'Course ID', 'Succeeding Class', 'Order'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;
  // Existing course IDs for this institution — _validate uses these to flag
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
      // Sort by course.ordid → class.ordid (NULLs to the end). Existing
      // rows read in master-defined order — same as the Students sidebar.
      final enriched = rows.map((r) {
        final courIdKey = '${r['cour_id'] ?? ''}';
        return {
          'cells': [
            courseMap[courIdKey] ?? '',
            r['claname']?.toString() ?? '',
            classMap['${r['succeedingclass'] ?? ''}'] ?? '',
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
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: Colors.orange),
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
      final succRaw = _rows[i].length > 4   ? _rows[i][4]?.toString().trim() ?? '' : '';
      if (idRaw.isEmpty || int.tryParse(idRaw) == null) { rowErrs[i] = 'Invalid Class ID'; continue; }
      if (name.isEmpty) missing.add('Class Name');
      if (courRaw.isNotEmpty && int.tryParse(courRaw) == null) missing.add('Course ID must be integer');
      if (succRaw.isNotEmpty && int.tryParse(succRaw) == null) missing.add('Succeeding Class must be integer');
      if (actRaw.isNotEmpty && int.tryParse(actRaw) == null) missing.add('Active Status must be 0 or 1');
      if (missing.isNotEmpty) { rowErrs[i] = 'Missing: ${missing.join(', ')}'; continue; }
      // Course ID must match an existing course for this institution before
      // a Class can be imported (FK on class.cour_id).
      if (courRaw.isNotEmpty && _courIds.isNotEmpty) {
        final cid = int.tryParse(courRaw);
        if (cid != null && !_courIds.contains(cid)) {
          rowErrs[i] = 'Course ID "$courRaw" not found — import the course first';
        }
      }
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors'), backgroundColor: Colors.red));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed! Click Save to import.'), backgroundColor: Colors.green));
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
    for (final row in _rows) {
      if (row.isEmpty || row[1].toString().trim().isEmpty) { _skipped++; continue; }
      try {
        final claId = int.tryParse(row[0].toString().trim());
        if (claId == null) { _skipped++; _errors.add('Row: invalid Class ID'); continue; }
        final actRaw  = row.length > 2 ? row[2].toString().trim() : '';
        final courRaw = row.length > 3 ? row[3].toString().trim() : '';
        final succRaw = row.length > 4 ? row[4].toString().trim() : '';
        final ordRaw  = row.length > 5 ? row[5].toString().trim() : '';
        await SupabaseService.fromSchema('class').upsert({
          'cla_id': claId,
          'claname': row[1].toString().trim(),
          'cour_id': courRaw.isEmpty ? null : int.tryParse(courRaw),
          'succeedingclass': succRaw.isEmpty ? null : int.tryParse(succRaw),
          'ordid': ordRaw.isEmpty ? null : int.tryParse(ordRaw),
          'ins_id': insId,
          'activestatus': actRaw.isEmpty ? 1 : (int.tryParse(actRaw) ?? 1),
        }, onConflict: 'cla_id');
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
      onSampleDownload: () => _exportSampleData('Class', _headers, [
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
      existingHeaders: const ['Course', 'Class Name', 'Succeeding Class'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

// ═══════════════════════════════════════════════

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
  static const _headers = ['Fee Group ID *', 'Group Name *', 'Year *'];
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
        _existingRows = groups.map((g) => [g['fgdesc'] ?? '', g['yrlabel'] ?? '']).toList();
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
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: Colors.orange),
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
        if (val.isEmpty) missing.add(labels[j]);
      }
      if (missing.isNotEmpty) rowErrs[i] = 'Missing: ${missing.join(', ')}';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors — highlighted in red'), backgroundColor: Colors.red));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed! Click Save to import.'), backgroundColor: Colors.green));
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
      final result = await _stagingImport(insId: insId, impType: 'FEEGROUP', rows: _rows, colCount: 3);
      _imported = result['imported'] ?? 0;
      _skipped = result['skipped'] ?? 0;
      if (_skipped > 0) _errors = await _getImportErrors(insId, 'FEEGROUP');
    } catch (e) {
      _errors = ['Import failed: ${_friendlyError(e.toString())}'];
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
        ['1', 'SCHOOL FEES', '2025-2026'],
        ['2', 'VAN FEES', '2025-2026'],
        ['3', 'HOSTEL FEES', '2025-2026'],
        ['4', 'EXAM FEES', '2025-2026'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Group Name', 'Year'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

// ═══════════════════════════════════════════════
// 2. FEE TYPE TAB
// Columns: Fee Name *, Short Name *, Fee Group *, Optional, Category
// ═══════════════════════════════════════════════

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
  static const _headers = ['Fee ID *', 'Fee Name *', 'Short Name *', 'Fee Group *', 'Year *', 'Fine Applicable *'];
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;
  // Lowercased fee-group names for the current institution — used by _validate
  // to flag rows whose Fee Group doesn't exist (otherwise the server import
  // silently skips them).
  Set<String> _fgNames = {};

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
            t['yrlabel'] ?? '',
            fineLabels['${t['feefineapplicable'] ?? 0}'] ?? 'No',
          ];
        }).toList();
        _fgNames = fgNameSet;
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
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: Colors.orange),
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
        if (val.isEmpty) missing.add(labels[j]);
      }
      if (missing.isNotEmpty) {
        rowErrs[i] = 'Missing: ${missing.join(', ')}';
        continue;
      }
      // Fee Group must already exist for this institution. Otherwise the
      // server-side join in process_master_import drops the row silently.
      final fg = (_rows[i].length > 3 ? _rows[i][3]?.toString().trim() ?? '' : '').toLowerCase();
      if (fg.isNotEmpty && _fgNames.isNotEmpty && !_fgNames.contains(fg)) {
        rowErrs[i] = 'Fee Group "${_rows[i][3]}" not found — import it first';
      }
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors — highlighted in red'), backgroundColor: Colors.red));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed! Click Save to import.'), backgroundColor: Colors.green));
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
      final mappedRows = _rows.map((row) {
        final mapped = List<dynamic>.from(row);
        while (mapped.length < 6) {
          mapped.add('');
        }
        // Fine Applicable is col 6 (index 5) after Fee ID, Name, Short, Group, Year.
        final fine = mapped[5].toString().trim().toLowerCase();
        mapped[5] = fineMap[fine] ?? mapped[5];
        return mapped;
      }).toList();
      final result = await _stagingImport(insId: insId, impType: 'FEETYPE', rows: mappedRows, colCount: 6);
      _imported = result['imported'] ?? 0;
      _skipped = result['skipped'] ?? 0;
      if (_skipped > 0) _errors = await _getImportErrors(insId, 'FEETYPE');
    } catch (e) {
      _errors = ['Import failed: ${_friendlyError(e.toString())}'];
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
        ['1', 'SCHOOL FEES', 'SCH', 'SCHOOL FEES', '2025-2026', 'Yes'],
        ['2', 'VAN FEES', 'VAN', 'VAN FEES', '2025-2026', 'No'],
        ['3', 'TUITION FEES', 'TUI', 'SCHOOL FEES', '2025-2026', 'Yes'],
        ['4', 'BOOK FEES', 'BK', 'SCHOOL FEES', '2025-2026', 'No'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Fee Name', 'Short Name', 'Fee Group', 'Year', 'Fine Applicable'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
    );
  }
}

// ═══════════════════════════════════════════════
// 3. CONCESSION TAB
// Columns: Concession Name *, Order
// ═══════════════════════════════════════════════

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
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: Colors.orange),
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
        if (val.isEmpty) missing.add(labels[j]);
      }
      if (missing.isNotEmpty) rowErrs[i] = 'Missing: ${missing.join(', ')}';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors — highlighted in red'), backgroundColor: Colors.red));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed! Click Save to import.'), backgroundColor: Colors.green));
    }
  }

  void _close() { setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; }); }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    try {
      final result = await _stagingImport(insId: insId, impType: 'CONCESSION', rows: _rows, colCount: 2);
      _imported = result['imported'] ?? 0;
      _skipped = result['skipped'] ?? 0;
      if (_skipped > 0) _errors = await _getImportErrors(insId, 'CONCESSION');
    } catch (e) {
      _errors = ['Import failed: ${_friendlyError(e.toString())}'];
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

// ═══════════════════════════════════════════════
// 4. CLASS FEE DEMAND TAB
// Columns: Class *, Term, Fee Type *, Amount, Due Date, Admission Type
// ═══════════════════════════════════════════════

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
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _headers = ['Class *', 'Semester *', 'Fee Type *', 'Amount *', 'Due Date *', 'Admission Type *'];
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
      final results = await Future.wait([
        SupabaseService.fromSchema('classfeedemand').select('*'),
        SupabaseService.fromSchema('admissiontype').select('adm_id, admname').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('class').select('claname, cour_id').eq('ins_id', insId).eq('activestatus', 1),
        SupabaseService.fromSchema('course').select('cour_id, courname').eq('ins_id', insId),
      ]);
      final rows = results[0] as List;
      final admRows = results[1] as List;
      final classRows = results[2] as List;
      final courseRows = results[3] as List;
      final admMap = { for (final a in admRows) a['adm_id'].toString(): (a['admname'] ?? '').toString() };
      final courseById = <String, String>{
        for (final c in courseRows) c['cour_id'].toString(): (c['courname'] ?? '').toString(),
      };
      String norm(String s) => s.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
      // Class name → course name lookup, derived from class.cour_id.
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
        _existingRows = sorted.map((r) => [
          classToCourse[norm(r['cfclass']?.toString() ?? '')] ?? '',
          r['cfclass'] ?? '',
          r['cfterm'] ?? '',
          r['cffeetype'] ?? '',
          r['cfamount'] ?? '',
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
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: Colors.orange),
        );
      }
      return;
    }
    // Backwards-compat: strip a legacy leading CF ID column if the header (or
    // any data row) suggests one is present. Header check handles user-typed
    // sheets; numeric-data check handles re-uploads of the previous template.
    final headerCells = parsed.first;
    final headerHasCfId = headerCells.isNotEmpty &&
        headerCells.first.toString().trim().toLowerCase().contains('cf') &&
        headerCells.first.toString().trim().toLowerCase().contains('id');
    var dataRows = parsed.sublist(1);
    final firstRowLooksLegacy = dataRows.isNotEmpty &&
        dataRows.first.length >= 7 &&
        int.tryParse(dataRows.first[0].toString().trim()) != null;
    if (headerHasCfId || firstRowLooksLegacy) {
      dataRows = dataRows.map((r) => r.length > 1 ? r.sublist(1) : r).toList();
    }
    setState(() { _fileName = result.files.single.name; _rows = dataRows; _isValidated = false; });
  }

  void _validate() {
    final rowErrs = <int, String>{};
    final labels = ['Class', 'Semester', 'Fee Type', 'Amount', 'Due Date', 'Admission Type'];
    for (int i = 0; i < _rows.length; i++) {
      final missing = <String>[];
      for (int j = 0; j < labels.length; j++) {
        final val = _rows[i].length > j ? _rows[i][j]?.toString().trim() ?? '' : '';
        if (val.isEmpty) missing.add(labels[j]);
      }
      if (missing.isNotEmpty) rowErrs[i] = 'Missing: ${missing.join(', ')}';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors — highlighted in red'), backgroundColor: Colors.red));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed! Click Save to import.'), backgroundColor: Colors.green));
    }
  }

  void _close() { setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; }); }

  Future<void> _save() async {
    if (_rows.isEmpty) return;
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final insId = auth.insId ?? 0;
    try {
      final mappedRows = _rows.asMap().entries.map((entry) {
        final i = entry.key;
        var row = entry.value;
        // Backwards-compat: legacy template included a leading CF ID. If the
        // row has 7 cells and the first is numeric, drop it.
        if (row.length >= 7 && int.tryParse(row[0].toString().trim()) != null) {
          row = row.sublist(1);
        }
        final mapped = List<dynamic>.from(row);
        while (mapped.length < 6) mapped.add('');
        // Admission Type passes through as a name (e.g. "MANAGEMENT QUOTA");
        // the SQL staging-promote looks up admissiontype.adm_id by admname.
        // Prepend a placeholder col1 (row number) — real cf_id is assigned
        // server-side by the set_cf_id trigger.
        return [(i + 1).toString(), ...mapped];
      }).toList();
      final result = await _stagingImport(insId: insId, impType: 'CLASSFEEDEMAND', rows: mappedRows, colCount: 7);
      _imported = result['imported'] ?? 0;
      _skipped = result['skipped'] ?? 0;
      if (_skipped > 0) _errors = await _getImportErrors(insId, 'CLASSFEEDEMAND');
    } catch (e) {
      _errors = ['Import failed: ${_friendlyError(e.toString())}'];
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
      title: 'Import Class Fee Demand',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Class Fee Demand', _headers),
      onSampleDownload: () => _exportSampleData('Class Fee Demand', _headers, [
        ['I',   'I TERM', 'SCHOOL FEES',  '10080', '2025-05-31', 'MANAGEMENT QUOTA'],
        ['I',   'JUNE',   'TUITION FEES', '700',   '2025-06-30', 'MANAGEMENT QUOTA'],
        ['XII', 'I TERM', 'SCHOOL FEES',  '15410', '2025-05-31', 'GOVERNMENT QUOTA'],
        ['XII', 'JUNE',   'VAN FEES',     '810',   '2025-06-30', 'GOVERNMENT QUOTA'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Course', 'Class', 'Semester', 'Fee Type', 'Amount', 'Due Date', 'Admission Type'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
      rightAlignCols: const {4}, // AMOUNT
    );
  }
}

// ═══════════════════════════════════════════════
// ADMISSION TYPE / QUOTA — simple lookup tables
// (ids are user-supplied; no auto-trigger)
// ═══════════════════════════════════════════════

Future<Map<String, int>> _directLookupImport({
  required int insId,
  required String table,
  required String idCol,
  required String nameCol,
  required List<List<dynamic>> rows,
  required bool hasInsId,
  required List<String> errorsOut,
}) async {
  int imported = 0;
  int skipped = 0;
  for (int i = 0; i < rows.length; i++) {
    try {
      final row = rows[i];
      final idRaw = row.isNotEmpty ? row[0].toString().trim() : '';
      final name = row.length > 1 ? row[1].toString().trim() : '';
      final id = int.tryParse(idRaw);
      if (id == null || name.isEmpty) {
        skipped++;
        errorsOut.add('Row ${i + 2}: invalid id or name');
        continue;
      }
      final record = <String, dynamic>{
        idCol: id,
        nameCol: name,
        'activestatus': 1,
      };
      if (hasInsId) record['ins_id'] = insId;
      await SupabaseService.fromSchema(table).upsert(record, onConflict: idCol);
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
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: Colors.orange),
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
      if (idRaw.isEmpty || int.tryParse(idRaw) == null) { errs[i] = 'Invalid Adm ID'; continue; }
      if (name.isEmpty) { errs[i] = 'Missing Admission Name'; }
    }
    setState(() { _rowErrors = errs; _isValidated = errs.isEmpty; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(errs.isEmpty ? 'Validation passed' : '${errs.length} row(s) have errors'),
      backgroundColor: errs.isEmpty ? Colors.green : Colors.red,
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
      rows: _rows, hasInsId: true, errorsOut: errs,
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
      existingHeaders: const ['Admission Name'],
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
          SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (parsed.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File has no data rows. Add at least one row below the header.'), backgroundColor: Colors.orange),
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
      if (idRaw.isEmpty || int.tryParse(idRaw) == null) { errs[i] = 'Invalid Quo ID'; continue; }
      if (name.isEmpty) { errs[i] = 'Missing Quota Name'; }
    }
    setState(() { _rowErrors = errs; _isValidated = errs.isEmpty; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(errs.isEmpty ? 'Validation passed' : '${errs.length} row(s) have errors'),
      backgroundColor: errs.isEmpty ? Colors.green : Colors.red,
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
      rows: _rows, hasInsId: true, errorsOut: errs,
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
      title: 'Import Quota',
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

