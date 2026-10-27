// Apply Class Fee Id / Due Amount corrections to a fee-demand workbook,
// IN PLACE, using the same `excel` package the import screen reads with.
//
// WHY DART AND NOT PYTHON. An openpyxl-written .xlsx cannot be read back by
// this package -- Excel.decodeBytes throws a null check at parse.dart:540,
// with or without styling. Writing the file with the same library that will
// later read it is the only way to correct the workbook and keep it
// importable. Excel opens it fine too.
//
// Usage:
//   dart run tools/apply_demand_corrections.dart <workbook.xlsx> <corrections.json>
//
// corrections.json:
//   { "cfIdCol": 14, "amountCol": 7,        // 1-based column numbers
//     "cfId":   {"<1-based sheet row>": <int>},
//     "amount": {"<1-based sheet row>": <num>},
//     "blank":  [<rows deliberately left as they are>] }
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: apply_demand_corrections.dart <xlsx> <corrections.json>');
    exit(2);
  }
  final book = File(args[0]);
  if (!book.existsSync()) {
    stderr.writeln('not found: ${args[0]}');
    exit(2);
  }
  final spec = jsonDecode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  final cfCol = (spec['cfIdCol'] as num).toInt() - 1;
  final amtCol = (spec['amountCol'] as num).toInt() - 1;
  final cfId = (spec['cfId'] as Map).cast<String, dynamic>();
  final amount = (spec['amount'] as Map).cast<String, dynamic>();

  final excel = Excel.decodeBytes(book.readAsBytesSync());
  final name = excel.tables.keys.first;
  final sheet = excel.tables[name]!;
  print('sheet "$name": ${sheet.maxRows} rows x ${sheet.maxColumns} columns');

  var wroteCf = 0, wroteAmt = 0;
  void put(int rowIndex, int col, String value) {
    sheet
        .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: rowIndex))
        .value = TextCellValue(value);
  }

  cfId.forEach((rowStr, v) {
    // JSON keys are 1-based sheet rows; the package indexes from 0.
    final r = int.parse(rowStr) - 1;
    final before = sheet.rows[r][cfCol]?.value?.toString() ?? '';
    put(r, cfCol, '${(v as num).toInt()}');
    wroteCf++;
    if (wroteCf <= 3) print('  row ${r + 1} Class Fee Id $before -> $v');
  });

  amount.forEach((rowStr, v) {
    final r = int.parse(rowStr) - 1;
    final before = sheet.rows[r][amtCol]?.value?.toString() ?? '';
    put(r, amtCol, '${(v as num).toInt()}');
    wroteAmt++;
    print('  row ${r + 1} Due Amount $before -> $v');
  });

  final out = excel.encode();
  if (out == null) {
    stderr.writeln('encode() returned null - nothing written');
    exit(1);
  }
  book.writeAsBytesSync(out);
  print('wrote $wroteCf Class Fee Id and $wroteAmt Due Amount changes to ${book.path}');

  // Read it straight back the way the import screen does.
  final check = Excel.decodeBytes(book.readAsBytesSync());
  final cs = check.tables[check.tables.keys.first]!;
  final headers =
      cs.rows.first.map((c) => c?.value?.toString().trim() ?? '').toList();
  final body = cs.rows
      .skip(1)
      .where((r) =>
          r.any((c) => c?.value != null && c!.value.toString().trim().isNotEmpty))
      .toList();
  print('re-read ok: ${body.length} data rows, headers: $headers');
  print('  first row: ${body.first.map((c) => c?.value).toList()}');
}
