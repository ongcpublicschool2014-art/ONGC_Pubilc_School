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
import '../../utils/formatters.dart';

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
    // 10 tabs: 9 master-data tabs shown in the pill bar + a hidden Fee Collection
    // import tab (index 9), reached only via the "Fee Collection Import" menu.
    _tabCtrl = TabController(length: 11, vsync: this, initialIndex: widget.initialTabIndex.clamp(0, 10));
  }

  @override
  void didUpdateWidget(covariant MasterImportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTabIndex != oldWidget.initialTabIndex) {
      final i = widget.initialTabIndex.clamp(0, 10);
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
                _SemesterTab(),
                _CommunityTab(),
                _FeeCollectionImportTab(),
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

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// GENERIC HELPERS
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
  return Container(width: 1, height: 36.h, color: AppColors.border);
}

Widget _gridDataCell(String text, {double? width, int flex = 1, bool center = false, bool right = false}) {
  final child = Container(
    padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 10.h),
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
  // rowIdx â†’ set of column indices that failed validation. When non-empty,
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
        await SupabaseService.importSchemaRows('course', [{
          'cour_id': courId,
          'courname': row[1].toString().trim(),
          'ordid': row.length > 2 ? int.tryParse(row[2].toString().trim()) : null,
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
  static const _headers = ['Class ID *', 'Class Name *', 'Active Status', 'Course ID', 'Succeeding Class', 'Order'];
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
          rowErrs[i] = 'Course ID "$courRaw" not found - import the course first';
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
        await SupabaseService.importSchemaRows('class', [{
          'cla_id': claId,
          'claname': row[1].toString().trim(),
          'cour_id': courRaw.isEmpty ? null : int.tryParse(courRaw),
          'succeedingclass': succRaw.isEmpty ? null : int.tryParse(succRaw),
          'ordid': ordRaw.isEmpty ? null : int.tryParse(ordRaw),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors - highlighted in red'), backgroundColor: Colors.red));
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
      final result = await _stagingImport(insId: insId, impType: 'FEEGROUP', rows: _rows, colCount: 2);
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
        if (!_headers[j].contains('*')) continue; // optional column (FeeType Order, Type)
        final val = _rows[i].length > j ? _rows[i][j]?.toString().trim() ?? '' : '';
        if (val.isEmpty) missing.add(labels[j]);
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
        rowErrs[i] = 'Fee Group "$fgRaw" not found - import it first';
      }
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors - highlighted in red'), backgroundColor: Colors.red));
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
        ['1', 'SCHOOL FEES', 'SCH', 'SCHOOL FEES', 'Yes', '0', 'COL'],
        ['2', 'VAN FEES', 'VAN', 'VAN FEES', 'No', '0', 'COL'],
        ['3', 'TUITION FEES', 'TUI', 'SCHOOL FEES', 'Yes', '0', 'COL'],
        ['4', 'BOOK FEES', 'BK', 'SCHOOL FEES', 'No', '0', 'COL'],
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors - highlighted in red'), backgroundColor: Colors.red));
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
  List<String> _errors = [];
  Map<int, String> _rowErrors = {};
  Map<int, Set<int>> _cellErrors = {};
  static const _headers = ['Class *', 'Semester *', 'Feetype *', 'AdmissionType *', 'Class Fee Amount *', 'Due Date *', 'App. To All', 'Class Id', 'Semester Id', 'Fee Id', 'Admission Type Id', 'Class Fee Id'];
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
        SupabaseService.fromSchema('classfeedemand').select('*').eq('activestatus', 1),
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
        _existingRows = sorted.map((r) => [
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
    final labels = ['Class', 'Semester', 'Feetype', 'AdmissionType', 'Class Fee Amount', 'Due Date'];
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors - highlighted in red'), backgroundColor: Colors.red));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed! Click Save to import.'), backgroundColor: Colors.green));
    }
  }

  void _close() { setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; }); }

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
    setState(() { _saving = true; _errors = []; _imported = 0; _skipped = 0; });
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
      // normalised to ISO so DD-MM-YYYY isn't mis-read. cf_id is trigger-assigned.
      const truthy = {'Y', 'YES', 'TRUE', '1', 'ALL'};
      final records = <Map<String, dynamic>>[];
      for (final row in _rows) {
        String cell(int j) => j < row.length ? row[j].toString().trim() : '';
        final className = cell(0);
        final feetype = cell(2);
        if (className.isEmpty || feetype.isEmpty) { _skipped++; continue; }
        int? admId = int.tryParse(cell(10)); // Admission Type Id wins
        if (admId == null && cell(3).isNotEmpty) admId = _admIdByName[cell(3).toUpperCase()];
        records.add({
          'cfclass': className,
          'cfterm': cell(1).isEmpty ? null : cell(1),
          'cffeetype': feetype,
          'cfamount': double.tryParse(cell(4).replaceAll(',', '')),
          'cfdduedate': _dueDateIso(cell(5)),
          'admissiontype': admId,
          'collectible': truthy.contains(cell(6).toUpperCase()),
          'cla_id': int.tryParse(cell(7)),
          'sem_id': int.tryParse(cell(8)),
          'fee_id': int.tryParse(cell(9)),
          'activestatus': 1,
        });
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
      // Generate the actual student demands from the (updated) template — one
      // server-side set-based INSERT into tempfeedemand (pending approval).
      try {
        final gen = await SupabaseService.client.rpc('generate_feedemand_from_template', params: {'p_ins_id': insId});
        generated = (gen is num) ? gen.toInt() : (int.tryParse(gen?.toString() ?? '') ?? 0);
      } catch (e) {
        _errors.add('Templates imported, but demand generation failed: ${_friendlyError(e.toString())}');
      }
    } catch (e) {
      _errors.add('Import failed: ${_friendlyError(e.toString())}');
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) {
      _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: () {
        _loadExisting();
        if (generated > 0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Generated $generated fee demand(s) — review & approve in Fee Demand Approval.'),
            backgroundColor: Colors.green,
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
      onSampleDownload: () => _exportSampleData('Class Fee Demand', _headers, [
        ['I',   'I TERM', 'SCHOOL FEES',  'MANAGEMENT QUOTA', '10080', '2025-05-31', 'Y', '', '', '', '', ''],
        ['I',   'JUNE',   'TUITION FEES', 'MANAGEMENT QUOTA', '700',   '2025-06-30', 'N', '', '', '', '', ''],
        ['XII', 'I TERM', 'SCHOOL FEES',  'GOVERNMENT QUOTA', '15410', '2025-05-31', 'Y', '', '', '', '', ''],
        ['XII', 'JUNE',   'VAN FEES',     'GOVERNMENT QUOTA', '810',   '2025-06-30', 'N', '', '', '', '', ''],
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

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// ADMISSION TYPE / QUOTA - simple lookup tables
// (ids are user-supplied; no auto-trigger)
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
      existingHeaders: const ['Admission Name'],
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
      if (idRaw.isEmpty || int.tryParse(idRaw) == null) { errs[i] = 'Invalid Com ID'; continue; }
      if (name.isEmpty) { errs[i] = 'Missing Community Name'; }
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
    if (t.isEmpty) return 'S';
    if (t.startsWith('M')) return 'M';
    if (t.startsWith('Y') || t.startsWith('A')) return 'Y';
    return 'S';
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
      if (idRaw.isEmpty || int.tryParse(idRaw) == null) { rowErrs[i] = 'Invalid Semester ID'; continue; }
      if (name.isEmpty) rowErrs[i] = 'Missing: Semester Name';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (rowErrs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${rowErrs.length} row(s) have errors'), backgroundColor: Colors.red));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Validation passed! Click Save to import.'), backgroundColor: Colors.green));
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
    for (final row in _rows) {
      if (row.length < 2 || row[1].toString().trim().isEmpty) { _skipped++; continue; }
      try {
        final semId = int.tryParse(row[0].toString().trim());
        if (semId == null) { _skipped++; _errors.add('Row with name ${row[1]}: invalid Semester ID'); continue; }
        final short = row.length > 2 ? row[2].toString().trim() : '';
        final type = row.length > 3 ? _semType(row[3].toString()) : 'S';
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
      title: 'Import Semester',
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
      existingHeaders: const ['Semester', 'Short', 'Type'],
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
  List<List<dynamic>> _existingRows = [];
  bool _isLoadingExisting = false;

  // Template column order (positional). Roll No / Demand No / Paid Amount required.
  // Type (REGULAR/ARREAR) + Year appended at the end so existing positions 0-6
  // stay stable; they disambiguate which demand a Demand No refers to.
  static const _headers = ['Receipt No', 'Pay Date', 'Roll No *', 'Demand No *', 'Paid Amount *', 'Pay Method', 'Reference', 'Type', 'Year'];
  static const _order = ['receiptno', 'paydate', 'stuadmno', 'demno', 'amount', 'method', 'reference', 'type', 'year'];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  static String? _mapHeader(String h) {
    final k = h.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    const m = {
      'receiptno': 'receiptno', 'receipt': 'receiptno', 'paynumber': 'receiptno', 'receiptnumber': 'receiptno', 'billno': 'receiptno', 'rcptno': 'receiptno',
      'paydate': 'paydate', 'date': 'paydate', 'paymentdate': 'paydate', 'collectiondate': 'paydate', 'receiptdate': 'paydate',
      'rollno': 'stuadmno', 'roll': 'stuadmno', 'admno': 'stuadmno', 'admissionno': 'stuadmno', 'stuadmno': 'stuadmno', 'registerno': 'stuadmno', 'regno': 'stuadmno',
      'demandno': 'demno', 'demno': 'demno', 'demand': 'demno', 'docno': 'demno',
      'paidamount': 'amount', 'amount': 'amount', 'paid': 'amount', 'collectedamount': 'amount', 'payamount': 'amount', 'amountpaid': 'amount',
      'paymethod': 'method', 'method': 'method', 'mode': 'method', 'paymode': 'method', 'paymentmode': 'method', 'paymentmethod': 'method',
      'reference': 'reference', 'ref': 'reference', 'payreference': 'reference', 'transactionid': 'reference', 'txnno': 'reference', 'chequeno': 'reference', 'referenceno': 'reference',
      'type': 'type', 'demseqtype': 'type', 'seqtype': 'type', 'demandtype': 'type',
      'year': 'year', 'yr': 'year', 'academicyear': 'year', 'feeyear': 'year', 'demandyear': 'year', 'demfeeyear': 'year',
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

  Future<void> _loadExisting() async {
    final insId = Provider.of<AuthProvider>(context, listen: false).insId;
    if (insId == null) return;
    setState(() => _isLoadingExisting = true);
    try {
      final rows = await SupabaseService.fromSchema('payment')
          .select('paynumber, paydate, transtotalamount, paymethod')
          .eq('ins_id', insId).eq('activestatus', 1)
          .order('pay_id', ascending: false).limit(200);
      if (mounted) setState(() {
        _existingRows = (rows as List).map((r) => [
          r['paynumber'] ?? '',
          (r['paydate']?.toString() ?? '').split('T').first,
          r['transtotalamount']?.toString() ?? '',
          r['paymethod'] ?? '',
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read file. ${friendlyError(e)}'), backgroundColor: Colors.red));
      return;
    }
    if (parsed.length < 2) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File has no data rows.'), backgroundColor: Colors.orange));
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
    const req = {2: 'Roll No', 3: 'Demand No', 4: 'Paid Amount'};
    for (int i = 0; i < _rows.length; i++) {
      final missing = <String>[];
      req.forEach((j, label) {
        final v = _rows[i].length > j ? _rows[i][j]?.toString().trim() ?? '' : '';
        if (v.isEmpty) missing.add(label);
      });
      if (missing.isNotEmpty) rowErrs[i] = 'Missing: ${missing.join(', ')}';
    }
    setState(() { _rowErrors = rowErrs; _cellErrors = _deriveCellErrors(rowErrs, _headers); _isValidated = rowErrs.isEmpty; });
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(rowErrs.isEmpty ? 'Validation passed! Click Save to import.' : '${rowErrs.length} row(s) have errors'),
      backgroundColor: rowErrs.isEmpty ? Colors.green : Colors.red));
  }

  void _close() => setState(() { _rows = []; _fileName = null; _isValidated = false; _errors = []; _rowErrors = {}; _cellErrors = {}; });

  Future<void> _save() async {
    if (_rows.isEmpty) return;
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
        if (stuId == null) { _skipped++; _errors.add('Receipt $label: Roll No "$admno" not found'); continue; }
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
      _errors = ['Import failed: ${_friendlyError(e.toString())}'];
    }
    setState(() { _saving = false; _rows = []; _fileName = null; _isValidated = false; _rowErrors = {}; _cellErrors = {}; });
    if (mounted) _showImportResultDialog(context, imported: _imported, skipped: _skipped, errors: _errors, onDone: _loadExisting);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _buildImportCard(
      title: 'Import Fee Collections',
      headers: _headers,
      rows: _rows.map((r) => List.generate(_headers.length, (j) => j < r.length ? r[j] : '')).toList(),
      onBrowse: _browse,
      onSave: _rows.isNotEmpty && _isValidated ? _save : null,
      onTemplate: () => _exportTemplate('Fee Collection', _headers),
      onSampleDownload: () => _exportSampleData('Fee Collection', _headers, [
        ['R0001', '2026-06-05', '20252617', 'DM00001', '5000', 'cash', ''],
        ['R0001', '2026-06-05', '20252617', 'DM00002', '2000', 'cash', ''],
        ['R0002', '2026-06-06', '20252619', 'DM00003', '7000', 'upi', 'UPI-88213'],
      ]),
      saving: _saving, fileName: _fileName, imported: _imported, skipped: _skipped, errors: _errors, showResult: false,
      onDismissResult: () {},
      onValidate: _rows.isNotEmpty ? _validate : null,
      onClose: _close,
      isValidated: _isValidated,
      existingRows: _existingRows,
      existingHeaders: const ['Receipt No', 'Pay Date', 'Amount', 'Method'],
      isLoadingExisting: _isLoadingExisting,
      rowErrors: _rowErrors,
      cellErrors: _cellErrors,
      rightAlignCols: const {4},
    );
  }
}
