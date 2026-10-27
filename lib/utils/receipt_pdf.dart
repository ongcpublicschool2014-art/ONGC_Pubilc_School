import 'dart:math' as math;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../widgets/receipt_widget.dart';
import 'school_terms.dart';

/// ISO A5 page format — 148 × 210 mm. Exported so every `Printing.layoutPdf`
/// call site passes it as `format:`; otherwise the print dialog defaults to
/// the printer's loaded paper (usually A4) and the printer's right-edge
/// unprintable margin clips the amount column.
const PdfPageFormat a5PageFormat =
    PdfPageFormat(148 * PdfPageFormat.mm, 210 * PdfPageFormat.mm);

/// Width of the printed receipt column. EVERYTHING — header banner included —
/// is centred inside this, so no element can reach further towards the paper
/// edge than any other. A5 is 419.5pt wide, so this leaves ~19mm of clearance
/// on each side: enough that a printer feeding the sheet a few mm off-centre
/// still prints the whole receipt.
const double kReceiptWidth = 310;

/// Builds the A5 fee-receipt PDF — a 1:1 match of [ReceiptWidget] and the
/// Figma "Receipt" design. Shared by every call site (Daily Collection,
/// Student Fee Collection, Failed Transactions) so receipts stay identical.
/// [pageFormat] is the format the print dialog reports for the selected paper
/// (passed straight through from `Printing.layoutPdf`'s onLayout callback).
/// Building at that size is what makes the receipt land centred and unclipped:
/// the plugin's Windows backend renders the PDF page 1:1 onto the physical
/// sheet with no scale-to-fit, so a page built for a different paper size just
/// prints anchored in a corner. Defaults to A5 for previews and downloads.
Future<pw.Document> buildReceiptPdf(ReceiptData data,
    {PdfPageFormat? pageFormat}) async {
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
  final bannerAsset = isSchool ? null : receiptHeaderImage(data.schoolName);

  // School: the fee group's uploaded header image (Utilities -> Receipt
  // Letterhead), printed full width in place of the text header.
  pw.ImageProvider? uploaded;
  final uploadedUrl = (data.headerBanner ?? '').trim();
  if (isSchool && uploadedUrl.startsWith('http')) {
    try {
      uploaded = await networkImage(uploadedUrl);
    } catch (_) {/* fall back to logo + text */}
  }
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

  /// One right-aligned label|amount line of the TOTAL block. Shared so the
  /// plain TOTAL and the three-line advance-adjusted version cannot drift
  /// apart in padding, height or rule position.
  pw.Widget amountLine(String label, double amount, bool isBold) => pw.Container(
        height: 32,
        decoration: const pw.BoxDecoration(border: pw.Border(top: divider)),
        child: pw.Row(
          children: [
            pw.Expanded(
              child: pw.Container(
                height: 32,
                alignment: pw.Alignment.centerRight,
                padding: const pw.EdgeInsets.symmetric(horizontal: 12),
                child: pw.Text(label, style: st(9, isBold ? bold : med)),
              ),
            ),
            pw.Container(width: 1, height: 32, color: black),
            pw.Container(
              width: amountColWidth,
              height: 32,
              alignment: pw.Alignment.centerRight,
              padding: const pw.EdgeInsets.symmetric(horizontal: 12),
              child: pw.Text(formatReceiptAmount(amount),
                  style: st(9, isBold ? bold : med)),
            ),
          ],
        ),
      );

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

  final fmt = pageFormat ?? a5PageFormat;
  // Symmetric margins => the content column sits centred on the sheet. Never
  // go inside the printer's own unprintable border (fmt carries it), and never
  // below our own ~15mm/13mm safe inset, whichever is larger.
  final safeH = math.max(42.0, math.max(fmt.marginLeft, fmt.marginRight));
  final safeV = math.max(36.0, math.max(fmt.marginTop, fmt.marginBottom));
  // Narrow the column if the sheet is smaller than the A5 design width.
  final colW = math.min(kReceiptWidth, fmt.width - safeH * 2);

  final pdf = pw.Document();
  pdf.addPage(
    pw.Page(
      pageFormat: fmt,
      margin: pw.EdgeInsets.symmetric(horizontal: safeH, vertical: safeV),
      theme: pw.ThemeData.withFont(base: reg, bold: bold),
      build: (ctx) {
        final body = pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            // Header — centered college banner, or logo + text fallback.
            if (uploaded != null)
              pw.SizedBox(
                height: 82,
                child: pw.Center(child: pw.Image(uploaded, fit: pw.BoxFit.contain)),
              )
            else if (banner != null)
              // Two-grid header: 20% crest | 5% gap | 75% banner. Height matches
              // the text-header fallback (82) so the fixed-height table below
              // still fits exactly inside the A5 sheet.
              pw.SizedBox(
                height: 82,
                child: pw.Row(
                  children: [
                    pw.Expanded(
                      flex: 4,
                      child: pw.Center(
                        child: crest != null
                            ? pw.Image(crest, height: 74)
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
            pw.Expanded(
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.SizedBox(
                    width: colW,
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
                            kv(schoolTerm('Reg. No'), data.admissionNo),
                            kv(isSchool ? 'Section' : 'Branch', data.className),
                            kv('Mode', data.paymentMethod.isEmpty ? '-' : data.paymentMethod),
                          ]),
                        ),
                        pw.Container(width: 1, color: black),
                        pw.Expanded(
                          child: infoCell([
                            kv('Receipt No', data.receiptNo),
                            kv('Date', data.date),
                            kv(isSchool ? 'Term' : 'Sem', receiptSemesterLabel(data)),
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
                  // Particulars — expands to fill the remaining page height so
                  // the receipt fits exactly inside the A5 sheet.
                  pw.Expanded(
                    child: pw.Container(
                    decoration: const pw.BoxDecoration(
                        border: pw.Border(top: divider)),
                    child: pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                      children: [
                        pw.Expanded(
                          child: pw.Container(
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
                        pw.Container(width: 1, color: black),
                        pw.Container(
                          width: amountColWidth,
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
                  ),
                  // TOTAL block -- mirrors receipt_widget._totalRows so the
                  // printed copy and the on-screen preview cannot disagree.
                  // `total` is the whole settlement; an advance that settled
                  // part of it is SUBTRACTED to reach what changed hands.
                  amountLine('TOTAL', data.total, true),
                  if (data.hasAdvanceAdjustment) ...[
                    amountLine(
                        'LESS: ADVANCE ADJUSTED'
                        '${data.advanceNo.isEmpty ? '' : ' ${data.advanceNo}'}',
                        data.advanceAdjusted,
                        false),
                    amountLine(
                        'TOTAL PAID', data.total - data.advanceAdjusted, true),
                  ],
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
                ],
              ),
            ),
          ],
        );
        // The banner header used to span the full content width while the table
        // below was narrower, which made the header the closest thing to the
        // paper edge — and the first thing a mis-fed sheet clipped. Pinning both
        // to kReceiptWidth keeps the whole receipt inside one safe column.
        final page = pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [pw.SizedBox(width: colW, child: body)],
        );
        if (!data.cancelled) return page;
        // Voided receipt — overlay a diagonal "CANCELLED" watermark so a
        // reprint can never be mistaken for a live receipt.
        return pw.Stack(
          alignment: pw.Alignment.center,
          children: [
            page,
            pw.Center(
              child: pw.Transform.rotate(
                angle: 0.6,
                child: pw.Text(
                  'CANCELLED',
                  style: pw.TextStyle(
                    font: bold,
                    fontSize: 60,
                    color: PdfColor.fromInt(0x33D32F2F),
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
