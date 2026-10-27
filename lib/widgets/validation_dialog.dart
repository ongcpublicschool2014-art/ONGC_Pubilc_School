import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../utils/app_theme.dart';
import '../utils/school_terms.dart';
import 'app_ui.dart';

/// One problem found while checking a sheet row or an on-screen row.
class RowIssue {
  /// Row number as the admin sees it: the Excel row, or the grid's #.
  final int row;
  final String regNo;
  final String name;

  /// Short label, used for the summary chips ("Duplicate EMIS · 3").
  final String category;
  final String message;

  const RowIssue(this.row, this.regNo, this.name, this.category, this.message);
}

/// The Validation window the import screens share: counts, a headline, the
/// problems grouped by kind and listed by row, Export with Errors, and one
/// action. Returns true when the admin takes [actionLabel].
///
/// [stats] are (label, value, colour). [blocking] problems stop the whole sheet
/// and are listed in the headline banner. With no [actionLabel] only Close is
/// offered.
Future<bool> showValidationDialog(
  BuildContext context, {
  required String subtitle,
  required String rowLabel,
  required List<(String, int, Color)> stats,
  required String headline,
  List<String> blocking = const [],
  String? blockingHint,
  List<RowIssue> issues = const [],
  Future<void> Function()? onExport,
  String? actionLabel,
  IconData actionIcon = Icons.check_rounded,
}) async {
  final hasBlocking = blocking.isNotEmpty;
  final hasIssues = issues.isNotEmpty;
  final Color tone;
  final IconData icon;
  if (hasBlocking) {
    tone = AppColors.error;
    icon = Icons.error_outline_rounded;
  } else if (hasIssues) {
    tone = AppColors.warning;
    icon = Icons.warning_amber_rounded;
  } else if (actionLabel != null) {
    tone = AppColors.success;
    icon = Icons.check_circle_outline_rounded;
  } else {
    tone = AppColors.textSecondary;
    icon = Icons.info_outline_rounded;
  }
  final byCategory = <String, int>{};
  for (final x in issues) {
    byCategory[x.category] = (byCategory[x.category] ?? 0) + 1;
  }

  var exporting = false;
  var open = true;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
      final body = Column(
        mainAxisSize: hasIssues ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Row(children: [
            Container(
              padding: EdgeInsets.all(8.w),
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10.r),
              ),
              child: Icon(icon, color: tone, size: 22.sp),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Validation Results', style: AppUI.cardTitle),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.muted),
              ]),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(ctx, false),
              icon: const Icon(Icons.close, size: 20),
            ),
          ]),
          SizedBox(height: 14.h),

          // Counts
          if (stats.isNotEmpty) ...[
            Wrap(spacing: 8.w, runSpacing: 8.h, children: [
              for (final st in stats) _stat(st.$1, '${st.$2}', st.$3),
            ]),
            SizedBox(height: 12.h),
          ],

          // Headline banner
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              border: Border.all(color: tone.withValues(alpha: 0.30)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, size: 17.sp, color: tone),
              SizedBox(width: 8.w),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(headline,
                      style: AppUI.body.copyWith(height: 1.35)),
                  for (final b in blocking)
                    Padding(
                      padding: EdgeInsets.only(top: 4.h),
                      child: Text('• $b',
                          style: AppUI.body.copyWith(color: AppColors.error, fontWeight: FontWeight.w600)),
                    ),
                  if (hasBlocking && blockingHint != null)
                    Padding(
                      padding: EdgeInsets.only(top: 6.h),
                      child: Text(blockingHint,
                          style: AppUI.muted),
                    ),
                ]),
              ),
            ]),
          ),

          // Problem summary + the list
          if (hasIssues) ...[
            SizedBox(height: 14.h),
            Wrap(spacing: 6.w, runSpacing: 6.h, children: [
              for (final e in byCategory.entries) _chip('${e.key} · ${e.value}'),
            ]),
            SizedBox(height: 10.h),
            Expanded(child: _issueTable(issues, rowLabel)),
          ],

          SizedBox(height: 16.h),
          // Actions
          Row(children: [
            if (hasIssues && onExport != null)
              OutlinedButton.icon(
                onPressed: exporting
                    ? null
                    : () async {
                        setDlg(() => exporting = true);
                        await onExport();
                        if (open) setDlg(() => exporting = false);
                      },
                icon: exporting
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.file_download_outlined, size: 17),
                label: const Text('Export with Errors'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: BorderSide(color: AppColors.error.withValues(alpha: 0.45)),
                ),
              ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(actionLabel != null ? 'Cancel' : 'Close'),
            ),
            if (actionLabel != null) ...[
              SizedBox(width: 8.w),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: Icon(actionIcon, size: 16),
                label: Text(actionLabel),
              ),
            ],
          ]),
        ],
      );

      return Dialog(
        child: SizedBox(
          width: 920.w,
          height: hasIssues ? 680.h : null,
          child: Padding(padding: EdgeInsets.all(20.w), child: body),
        ),
      );
    }),
  );
  open = false;
  return result ?? false;
}

/// Writes [rows] back out with the bad cells shaded red and an "Error" column
/// saying why, so the sheet can be fixed in Excel and imported again.
///
/// [badCells] and [messages] are keyed by index into [rows]; [badCells] values
/// are column indexes into [header]. Every cell is written as text, so long
/// numbers and leading zeros survive the round trip. Returns false when the
/// admin cancels the save dialog; throws when the file can't be written.
Future<bool> exportSheetWithErrors({
  required String fileName,
  required String sheetName,
  required List<String> header,
  required List<List<String>> rows,
  required Map<int, Set<int>> badCells,
  required Map<int, List<String>> messages,
}) async {
  final base = fileName.replaceAll(RegExp(r'\.xlsx$', caseSensitive: false), '');
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Save Sheet with Errors',
    fileName: '${base}_errors.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (path == null) return false;

  final book = xl.Excel.createExcel();
  final sheet = book[sheetName];
  book.delete('Sheet1');
  final hdr = xl.CellStyle(
    bold: true,
    fontSize: 10,
    backgroundColorHex: xl.ExcelColor.fromHexString('#2D3748'),
    fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
  );
  final errHdr = xl.CellStyle(
    bold: true,
    fontSize: 10,
    backgroundColorHex: xl.ExcelColor.fromHexString('#B91C1C'),
    fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
  );
  final badCell = xl.CellStyle(
    bold: true,
    backgroundColorHex: xl.ExcelColor.fromHexString('#FCE4E4'),
    fontColorHex: xl.ExcelColor.fromHexString('#B91C1C'),
  );
  final errText = xl.CellStyle(fontColorHex: xl.ExcelColor.fromHexString('#B91C1C'));

  final errCol = header.length;
  for (var j = 0; j <= errCol; j++) {
    final key = j < errCol ? header[j].toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '') : '';
    final isName = const {'STUDENTNAME', 'NAME', 'STUNAME'}.contains(key);
    sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: j, rowIndex: 0))
      ..value = xl.TextCellValue(j == errCol ? 'Error' : header[j])
      ..cellStyle = j == errCol ? errHdr : hdr;
    sheet.setColumnWidth(j, j == errCol ? 70 : (isName ? 30 : 20));
  }
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final bad = badCells[i] ?? const <int>{};
    for (var j = 0; j < header.length; j++) {
      final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: j, rowIndex: i + 1));
      cell.value = xl.TextCellValue(j < r.length ? r[j] : '');
      if (bad.contains(j)) cell.cellStyle = badCell;
    }
    final msgs = messages[i];
    if (msgs != null) {
      sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: errCol, rowIndex: i + 1))
        ..value = xl.TextCellValue(msgs.join('; '))
        ..cellStyle = errText;
    }
  }
  final bytes = book.encode();
  if (bytes == null) throw Exception('Could not build the Excel file');
  await File(path).writeAsBytes(bytes);
  return true;
}

Widget _stat(String label, String value, Color c) => Container(
      padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10.r),
        border: Border.all(color: c.withValues(alpha: 0.22)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(value, style: TextStyle(fontSize: 17.sp, fontWeight: FontWeight.w800, color: c, height: 1.1)),
        Text(label, style: AppUI.muted),
      ]),
    );

// Problem-kind pills are always errors: the kit's danger chip.
Widget _chip(String text) => AppUI.chip(text, AppStatus.danger);

Widget _issueTable(List<RowIssue> issues, String rowLabel) {
  TextStyle head() => AppUI.tableHead;
  return Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      border: Border.all(color: AppColors.cardBorder),
    ),
    child: Column(children: [
      Container(
        color: AppColors.tableHeadBg,
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
        child: Row(children: [
          SizedBox(width: 60.w, child: Text(rowLabel.toUpperCase(), style: head())),
          Expanded(flex: 2, child: Text(schoolTerm('REGISTER NO.'), style: head())),
          Expanded(flex: 3, child: Text('NAME', style: head())),
          Expanded(flex: 7, child: Text('PROBLEM', style: head())),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: issues.length,
          itemBuilder: (_, i) {
            final x = issues[i];
            return Container(
              padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 7.h),
              decoration: BoxDecoration(
                color: Colors.white,
                border: const Border(bottom: BorderSide(color: AppColors.divider)),
              ),
              child: Row(children: [
                SizedBox(
                  width: 60.w,
                  child: Text('${x.row}',
                      style: AppUI.money.copyWith(color: AppColors.error)),
                ),
                Expanded(
                  flex: 2,
                  child: Text(x.regNo.isEmpty ? '—' : x.regNo,
                      overflow: TextOverflow.ellipsis,
                      style: AppUI.cell.copyWith(fontWeight: FontWeight.w600)),
                ),
                Expanded(
                  flex: 3,
                  child: Text(x.name,
                      overflow: TextOverflow.ellipsis,
                      style: AppUI.cell.copyWith(color: AppColors.textSecondary)),
                ),
                Expanded(
                  flex: 7,
                  child: Row(children: [
                    AppUI.chip(x.category, AppStatus.danger),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text(x.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppUI.cell),
                    ),
                  ]),
                ),
              ]),
            );
          },
        ),
      ),
    ]),
  );
}
