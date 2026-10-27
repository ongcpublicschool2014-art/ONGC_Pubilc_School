// Turn a CSV into a fee-demand workbook in the import template's layout.
//
// WHY DART. The import screen reads .xlsx with the `excel` package, and that
// package cannot decode a workbook written by Python's openpyxl -- it throws a
// null check at parse.dart:540, with or without styling. Anything meant to be
// imported has to be written by this same library.
//
// Usage:
//   dart run tools/csv_to_demand_xlsx.dart <in.csv> <out.xlsx> [sheet name]
//
// The CSV's first line is the header and is written as-is, so the column set
// comes from whoever produced the CSV rather than being fixed here.
import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';

/// Widths by heading, so a reordered or added column cannot shift the rest.
const _widths = <String, double>{
  'Demand No': 16, 'Type': 12, 'Roll No *': 18, 'Class *': 20,
  'Semester *': 14, 'Fee Type *': 22, 'Fee Year *': 14, 'Due Amount *': 14,
  'Con. Category': 16, 'Concession Amount': 18, 'Due Date *': 14,
  'Class Id': 10, 'Semester id': 12, 'Fee Id': 10, 'Class Fee Id': 13,
  'Arrear Class': 18,
};

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: csv_to_demand_xlsx.dart <in.csv> <out.xlsx> [sheet]');
    exit(2);
  }
  final sheetName = args.length > 2 ? args[2] : 'Fee Demands';

  final rows = const CsvToListConverter(shouldParseNumbers: false)
      .convert(utf8.decode(File(args[0]).readAsBytesSync()));
  if (rows.isEmpty) {
    stderr.writeln('empty csv');
    exit(1);
  }
  final headers = rows.first.map((e) => e.toString()).toList();
  final body = rows.skip(1).where((r) => r.any((c) => '$c'.trim().isNotEmpty));

  final excel = Excel.createExcel();
  final sheet = excel[sheetName];
  // createExcel() seeds a Sheet1 that would otherwise be the first tab, and
  // the importer reads tables.keys.first.
  if (sheetName != 'Sheet1') excel.delete('Sheet1');

  final headerStyle = CellStyle(
    backgroundColorHex: ExcelColor.fromHexString('#FF2D3748'),
    fontColorHex: ExcelColor.fromHexString('#FFFFFFFF'),
    bold: true,
  );
  for (var i = 0; i < headers.length; i++) {
    final cell =
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    cell.value = TextCellValue(headers[i]);
    cell.cellStyle = headerStyle;
    sheet.setColumnWidth(i, _widths[headers[i]] ?? 14);
  }
  sheet.setRowHeight(0, 32);

  var r = 1;
  for (final row in body) {
    for (var i = 0; i < headers.length; i++) {
      // Everything as text: a roll number written as a number comes back from
      // Excel as 4.21326E+11, and the real digits are gone.
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: r))
          .value = TextCellValue(i < row.length ? '${row[i]}' : '');
    }
    r++;
  }

  final bytes = excel.encode();
  if (bytes == null) {
    stderr.writeln('encode() returned null');
    exit(1);
  }
  File(args[1]).writeAsBytesSync(bytes);
  print('wrote ${r - 1} data rows x ${headers.length} columns to ${args[1]}');

  // Read it back exactly as the import screen does, so a broken file is
  // caught here and not at the counter.
  final check = Excel.decodeBytes(File(args[1]).readAsBytesSync());
  final cs = check.tables[check.tables.keys.first]!;
  final gotHeaders =
      cs.rows.first.map((c) => c?.value?.toString().trim() ?? '').toList();
  final gotRows = cs.rows
      .skip(1)
      .where((x) =>
          x.any((c) => c?.value != null && c!.value.toString().trim().isNotEmpty))
      .toList();
  print('re-read ok: sheet "${check.tables.keys.first}", '
      '${gotRows.length} rows, headers $gotHeaders');
  print('  first row: ${gotRows.first.map((c) => c?.value).toList()}');
}
