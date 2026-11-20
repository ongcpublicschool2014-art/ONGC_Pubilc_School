import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';

import 'excel_theme.dart';
import 'school_terms.dart';
import 'save_path.dart';

/// Export Errors for an import's result: every problem the import met while
/// saving, one per row of a sheet, so the admin can fix them and import again.
/// A message is "<record>: <problem>" (e.g. "Row 12: Fee type missing",
/// "Register No. ADM00012 - TUTION FEE (TERM 1): ..."), so the sheet has a Row /
/// Record column and an Error column. Returns the saved path, or null if
/// cancelled.
Future<String?> exportImportErrors(String name, List<String> errors) async {
  final path = await pickSavePath(
    dialogTitle: 'Save Import Errors',
    fileName: '${schoolTerm(name).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}_errors.xlsx',
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (path == null) return null;
  final book = xl.Excel.createExcel();
  final sheet = book[schoolTerm(name)];
  final head = xl.CellStyle(bold: true, backgroundColorHex: XlTheme.headerBg, fontColorHex: XlTheme.headerFg);
  final err = xl.CellStyle(fontColorHex: xl.ExcelColor.fromHexString('#B91C1C'));
  const cols = ['Row / Record', 'Error'];
  for (var i = 0; i < cols.length; i++) {
    final c = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    c.value = xl.TextCellValue(cols[i]);
    c.cellStyle = head;
  }
  sheet.setColumnWidth(0, 40);
  sheet.setColumnWidth(1, 80);
  for (var r = 0; r < errors.length; r++) {
    final e = schoolTerm(errors[r]);
    final colon = e.indexOf(':');
    // only a short lead-in is a record name; a long sentence is all error
    final named = colon > 0 && colon <= 80;
    sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r + 1)).value =
        xl.TextCellValue(named ? e.substring(0, colon).trim() : '');
    final c = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r + 1));
    c.value = xl.TextCellValue(named ? e.substring(colon + 1).trim() : e);
    c.cellStyle = err;
  }
  book.delete('Sheet1');
  final bytes = book.encode();
  if (bytes != null) File(path.toLowerCase().endsWith('.xlsx') ? path : '$path.xlsx').writeAsBytesSync(bytes);
  return path;
}
