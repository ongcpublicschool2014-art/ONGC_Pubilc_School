import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// One way to print a tabular report, shared by the Admission Register, the
/// Admission Abstract and the TC Report.
///
/// Written once rather than three times: the three differ only in their
/// columns, so three copies would have drifted the moment one of them needed a
/// wider page or a different heading block.
///
/// The heading (institution, address, city, title, date line) repeats on every
/// page. MultiPage renders its `build` children once, so a two-page report put
/// the college name on page 1 and opened page 2 on a bare grid -- the heading
/// belongs in the header callback instead.
Future<bool> saveReportPdf(
  BuildContext context, {
  required String fileName,
  required String insName,
  required String insAddress,
  required String insCity,
  required String title,
  required String subtitle,
  required List<String> headers,
  required List<List<String>> rows,

  /// Columns to right-align — the numeric ones. Indexes into [headers].
  Set<int> rightAlign = const {},

  /// Landscape once a report is wider than about eight columns; portrait reads
  /// better below that.
  bool? landscape,

  /// Printed under the table, e.g. 'Note : Without Tc Students'.
  String? footNote,
}) async {
  final wide = landscape ?? headers.length > 8;
  final format = wide ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;

  // Below about 6pt the type stops being readable, so a very wide report
  // shrinks only so far and then lets the columns wrap.
  final fontSize = headers.length <= 8
      ? 8.0
      : headers.length <= 14
          ? 7.0
          : headers.length <= 22
              ? 6.0
              : 5.5;

  // The other reports print one address line; the callers here keep the city
  // apart so the Excel sheet can stack them, so rejoin it for the PDF.
  final fullAddress =
      [insAddress, insCity].where((s) => s.trim().isNotEmpty).join(', ');
  final now = DateTime.now();
  final runDate = '${now.day.toString().padLeft(2, '0')}/'
      '${now.month.toString().padLeft(2, '0')}/${now.year}';

  final pdf = pw.Document();
  pdf.addPage(pw.MultiPage(
    pageFormat: format,
    margin: const pw.EdgeInsets.fromLTRB(18, 16, 18, 18),
    // The heading the other report PDFs use (Daily Collection, DCB Register):
    // left-aligned, institution name bold 13 with the address under it in
    // regular 9, then the report title on the left of a row with the run date
    // on the right. It was centred and all-bold here, which read as a second
    // house style rather than the one the office already knows.
    header: (ctx) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (insName.isNotEmpty)
          pw.Text(insName, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        if (fullAddress.isNotEmpty)
          pw.Text(fullAddress, style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 4),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(title, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            pw.Text('Date: $runDate', style: const pw.TextStyle(fontSize: 10)),
          ],
        ),
        if (subtitle.isNotEmpty) ...[
          pw.SizedBox(height: 2),
          pw.Text(subtitle, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        ],
        pw.SizedBox(height: 6),
      ],
    ),
    // Page numbers matter here: these reports are filed on paper, and a
    // register whose pages cannot be put back in order is worth less.
    footer: (ctx) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
    ),
    build: (ctx) => [
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: rows,
        headerStyle: pw.TextStyle(
            fontSize: fontSize, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
        // Headings centred over their columns, whichever way the data below
        // them sits: a right-aligned Total and a left-aligned Course both read
        // better under a centred label than under one pushed to an edge.
        headerAlignment: pw.Alignment.center,
        cellStyle: pw.TextStyle(fontSize: fontSize),
        cellAlignments: {for (final i in rightAlign) i: pw.Alignment.centerRight},
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.3),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
      ),
      if (footNote != null && footNote.isNotEmpty) ...[
        pw.SizedBox(height: 8),
        pw.Text(footNote, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
      ],
    ],
  ));

  final bytes = await pdf.save();
  final result = await FilePicker.platform.saveFile(
    dialogTitle: 'Save PDF',
    fileName: '$fileName.pdf',
    type: FileType.custom,
    allowedExtensions: ['pdf'],
  );
  if (result == null) return false;
  final path = result.toLowerCase().endsWith('.pdf') ? result : '$result.pdf';
  await File(path).writeAsBytes(bytes);
  return true;
}
