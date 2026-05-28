import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../widgets/receipt_widget.dart';

/// ISO A5 page format — 148 × 210 mm. Exported so every `Printing.layoutPdf`
/// call site passes it as `format:`; otherwise the print dialog defaults to
/// the printer's loaded paper (usually A4) and the printer's right-edge
/// unprintable margin clips the amount column.
const PdfPageFormat a5PageFormat =
    PdfPageFormat(148 * PdfPageFormat.mm, 210 * PdfPageFormat.mm);

/// Builds the A5 fee-receipt PDF — a 1:1 match of [ReceiptWidget] and the
/// Figma "Receipt" design. Shared by every call site (Daily Collection,
/// Student Fee Collection, Failed Transactions) so receipts stay identical.
Future<pw.Document> buildReceiptPdf(ReceiptData data) async {
  final reg = await PdfGoogleFonts.interRegular();
  final med = await PdfGoogleFonts.interMedium();
  final semi = await PdfGoogleFonts.interSemiBold();
  final bold = await PdfGoogleFonts.interBold();

  pw.ImageProvider? logo;
  if ((data.schoolLogoUrl ?? '').isNotEmpty) {
    try {
      logo = await networkImage(data.schoolLogoUrl!);
    } catch (_) {/* fall back to a logo-less header */}
  }

  // College header banner (kcet/kmptc/kcsam), chosen by institution name.
  pw.ImageProvider? banner;
  pw.ImageProvider? crest;
  final bannerAsset = receiptHeaderImage(data.schoolName);
  if (bannerAsset != null) {
    try {
      banner = await imageFromAssetBundle(bannerAsset);
      crest = await imageFromAssetBundle('assets/images/KMPTC Logo.jpg');
    } catch (_) {/* fall back to logo + text */}
  }

  const black = PdfColors.black;
  const divider = pw.BorderSide(color: black, width: 1);
  const amountColWidth = 120.0;

  pw.TextStyle st(double size, pw.Font f) =>
      pw.TextStyle(font: f, fontSize: size, color: black);

  pw.Widget kv(String label, String value) => pw.RichText(
        text: pw.TextSpan(children: [
          pw.TextSpan(text: '$label : ', style: st(9, semi)),
          pw.TextSpan(
              text: value.trim().isEmpty ? '-' : value, style: st(9, reg)),
        ]),
      );

  pw.Widget infoCell(List<pw.Widget> lines) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) pw.SizedBox(height: 8),
              lines[i],
            ],
          ],
        ),
      );

  final particulars = flattenParticulars(data);

  final pdf = pw.Document();
  pdf.addPage(
    pw.Page(
      pageFormat: a5PageFormat,
      margin: const pw.EdgeInsets.all(24),
      theme: pw.ThemeData.withFont(base: reg, bold: bold),
      build: (ctx) {
        return pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            // Header — centered college banner, or logo + text fallback.
            if (banner != null)
              // Two-grid header: 20% crest | 5% gap | 75% banner.
              pw.SizedBox(
                height: 100,
                child: pw.Row(
                  children: [
                    pw.Expanded(
                      flex: 4,
                      child: pw.Center(
                        child: crest != null
                            ? pw.Image(crest, height: 88)
                            : pw.SizedBox(),
                      ),
                    ),
                    pw.Expanded(flex: 1, child: pw.SizedBox()),
                    pw.Expanded(
                      flex: 15,
                      child: pw.Center(
                        child: pw.Image(banner, fit: pw.BoxFit.contain),
                      ),
                    ),
                  ],
                ),
              )
            else
              pw.SizedBox(
              height: 82,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  if (logo != null) ...[
                    pw.SizedBox(
                        width: 70,
                        height: 70,
                        child: pw.Image(logo, fit: pw.BoxFit.contain)),
                    pw.SizedBox(width: 14),
                  ],
                  pw.Flexible(
                    child: pw.Column(
                      mainAxisSize: pw.MainAxisSize.min,
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(data.schoolName, style: st(9, bold)),
                        pw.SizedBox(height: 3),
                        pw.Text(data.schoolAddress,
                            maxLines: 2, style: st(9, med)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Center(child: pw.Text('RECEIPT', style: st(9, bold))),
            pw.SizedBox(height: 8),
            // Bordered receipt table — content-sized (no Expanded), so the
            // PDF layout engine renders every row reliably. Centered at a
            // fixed 350pt so the table sits inside the 371pt content area
            // with a small inset on each side.
            pw.Center(
              child: pw.SizedBox(
                width: 350,
                child: pw.Container(
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: black, width: 1),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  // Info row — student details | receipt details.
                  pw.Container(
                    height: 90,
                    child: pw.Row(
                      children: [
                        pw.Expanded(
                          child: infoCell([
                            kv('Name', data.studentName),
                            kv('Reg. No', data.admissionNo),
                            kv('Branch', data.className),
                            kv('Mode', data.paymentMethod.isEmpty ? '-' : data.paymentMethod),
                          ]),
                        ),
                        pw.Container(width: 1, color: black),
                        pw.Expanded(
                          child: infoCell([
                            kv('Receipt No', data.receiptNo),
                            kv('Date', data.date),
                            kv('Sem', 'FEE (UP TO DATE)'),
                            kv('Txn ID', (data.paymentReference ?? '').trim().isEmpty ? '-' : data.paymentReference!.trim()),
                          ]),
                        ),
                      ],
                    ),
                  ),
                  // Column headings.
                  pw.Container(
                    height: 30,
                    decoration: const pw.BoxDecoration(
                        border: pw.Border(top: divider)),
                    child: pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.Container(
                            height: 30,
                            alignment: pw.Alignment.center,
                            child: pw.Text('PARTICULARS',
                                style: st(9, bold)),
                          ),
                        ),
                        pw.Container(width: 1, height: 30, color: black),
                        pw.Container(
                          width: amountColWidth,
                          height: 30,
                          alignment: pw.Alignment.centerRight,
                          padding:
                              const pw.EdgeInsets.symmetric(horizontal: 12),
                          child: pw.Text('AMOUNTS (Rs)',
                              style: st(9, bold)),
                        ),
                      ],
                    ),
                  ),
                  // Particulars.
                  pw.Container(
                    height: 150,
                    decoration: const pw.BoxDecoration(
                        border: pw.Border(top: divider)),
                    child: pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.Container(
                            height: 150,
                            padding: const pw.EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            child: pw.Column(
                              crossAxisAlignment:
                                  pw.CrossAxisAlignment.start,
                              children: [
                                for (var i = 0;
                                    i < particulars.length;
                                    i++) ...[
                                  if (i > 0) pw.SizedBox(height: 6),
                                  pw.Text(
                                      '${i + 1}. ${particulars[i].type}',
                                      style: st(9, reg)),
                                ],
                              ],
                            ),
                          ),
                        ),
                        pw.Container(width: 1, height: 240, color: black),
                        pw.Container(
                          width: amountColWidth,
                          height: 150,
                          padding: const pw.EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.end,
                            children: [
                              for (var i = 0;
                                  i < particulars.length;
                                  i++) ...[
                                if (i > 0) pw.SizedBox(height: 6),
                                pw.Text(
                                    formatReceiptAmount(
                                        particulars[i].amount),
                                    style: st(9, reg)),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Total row.
                  pw.Container(
                    height: 32,
                    decoration: const pw.BoxDecoration(
                        border: pw.Border(top: divider)),
                    child: pw.Row(
                      children: [
                        pw.Expanded(
                          child: pw.Container(
                            height: 32,
                            alignment: pw.Alignment.centerRight,
                            padding: const pw.EdgeInsets.symmetric(
                                horizontal: 12),
                            child: pw.Text('TOTAL', style: st(9, bold)),
                          ),
                        ),
                        pw.Container(width: 1, height: 32, color: black),
                        pw.Container(
                          width: amountColWidth,
                          height: 32,
                          alignment: pw.Alignment.centerRight,
                          padding:
                              const pw.EdgeInsets.symmetric(horizontal: 12),
                          child: pw.Text(formatReceiptAmount(data.total),
                              style: st(9, bold)),
                        ),
                      ],
                    ),
                  ),
                  // Footer — amount in words + cashier signature line.
                  pw.Container(
                    height: 78,
                    decoration: const pw.BoxDecoration(
                        border: pw.Border(top: divider)),
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(amountInWords(data.total),
                            style: st(9, med)),
                        // Receipt is not a settled-cash equivalent until the
                        // institution reconciles the bank/UPI/cheque entry.
                        if (data.reconStatus != 'R') ...[
                          pw.SizedBox(height: 4),
                          pw.Text('* Subject to Realization',
                              style: pw.TextStyle(font: med, fontSize: 9, color: PdfColor.fromInt(0xFFB85C00))),
                        ],
                        pw.Spacer(),
                        pw.Container(
                          width: double.infinity,
                          padding: const pw.EdgeInsets.only(right: 34),
                          child: pw.Text('Cashier',
                              textAlign: pw.TextAlign.right,
                              style: st(9, bold)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
              ),
            ),
          ],
        );
      },
    ),
  );
  return pdf;
}
