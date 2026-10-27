import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// One field placed on a PDF TC format. Positions are in PDF points
/// (1/72 inch) from the page's top-left; [y] is the top of the text.
class TcPdfField {
  String key;
  int page;
  double x, y, w, size;
  String align; // left | center | right
  bool bold;

  TcPdfField({
    required this.key,
    this.page = 0,
    required this.x,
    required this.y,
    this.w = 200,
    this.size = 11,
    this.align = 'left',
    this.bold = false,
  });

  factory TcPdfField.fromJson(Map<String, dynamic> j) {
    double d(Object? v, double def) => v is num ? v.toDouble() : double.tryParse('$v') ?? def;
    return TcPdfField(
      key: '${j['key'] ?? ''}',
      page: (j['page'] as num?)?.toInt() ?? 0,
      x: d(j['x'], 40),
      y: d(j['y'], 40),
      w: d(j['w'], 200),
      size: d(j['size'], 11),
      align: '${j['align'] ?? 'left'}',
      bold: j['bold'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key, 'page': page, 'x': _r(x), 'y': _r(y), 'w': _r(w), 'size': _r(size), 'align': align, 'bold': bold,
      };

  static double _r(double v) => (v * 10).roundToDouble() / 10;
}

/// Where each field prints on a PDF TC format. [background] off = print the
/// values only, for TC books that already have the form printed on them.
class TcPdfLayout {
  bool background;
  final List<TcPdfField> fields;

  TcPdfLayout({this.background = true, List<TcPdfField>? fields}) : fields = fields ?? [];

  factory TcPdfLayout.fromJson(Object? raw) {
    final j = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return TcPdfLayout(
      background: j['background'] != false,
      fields: [
        for (final f in (j['fields'] as List? ?? const []))
          if (f is Map) TcPdfField.fromJson(Map<String, dynamic>.from(f)),
      ],
    );
  }

  Map<String, dynamic> toJson() => {'background': background, 'fields': [for (final f in fields) f.toJson()]};

  /// The field names used, for the TC Certificate screen's extra fields.
  List<String> get keys => {for (final f in fields) f.key}.toList();
}

/// A rendered page of the uploaded PDF.
class TcPdfPage {
  final Uint8List png;
  final double wPt, hPt;
  const TcPdfPage(this.png, this.wPt, this.hPt);
}

class TcPdf {
  TcPdf._();

  /// Renders every page of [pdf] (throws if it is not a readable PDF).
  static Future<List<TcPdfPage>> pages(Uint8List pdf, {double dpi = 110}) async {
    final out = <TcPdfPage>[];
    await for (final r in Printing.raster(pdf, dpi: dpi)) {
      out.add(TcPdfPage(await r.toPng(), r.width * 72 / dpi, r.height * 72 / dpi));
    }
    if (out.isEmpty) throw StateError('The PDF has no pages.');
    return out;
  }

  static pw.TextAlign _align(String a) =>
      a == 'center' ? pw.TextAlign.center : (a == 'right' ? pw.TextAlign.right : pw.TextAlign.left);

  /// One PDF: every page of the format for each row in [rows], with the
  /// values written at the layout's positions.
  static Future<Uint8List> fill(Uint8List pdf, TcPdfLayout layout, List<Map<String, String>> rows) async {
    // background printed at 200 dpi; without it only the page sizes are needed
    final pages = await TcPdf.pages(pdf, dpi: layout.background ? 200 : 20);
    pw.Font? reg, bold;
    final fallback = <pw.Font>[];
    try {
      reg = await PdfGoogleFonts.notoSansRegular();
      bold = await PdfGoogleFonts.notoSansBold();
      fallback.add(await PdfGoogleFonts.notoSansTamilRegular());
    } catch (_) {
      // offline: the built-in font (Latin only)
    }
    final images = [for (final p in pages) pw.MemoryImage(p.png)];
    final doc = pw.Document(title: 'Transfer Certificate');
    for (final row in rows) {
      for (var i = 0; i < pages.length; i++) {
        final p = pages[i];
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat(p.wPt, p.hPt),
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Stack(children: [
            if (layout.background)
              pw.Positioned(left: 0, top: 0, child: pw.Image(images[i], width: p.wPt, height: p.hPt, fit: pw.BoxFit.fill)),
            for (final f in layout.fields.where((f) => f.page == i))
              pw.Positioned(
                left: f.x,
                top: f.y,
                child: pw.SizedBox(
                  width: f.w,
                  child: pw.Text(
                    row[f.key] ?? '',
                    textAlign: _align(f.align),
                    style: pw.TextStyle(
                      font: f.bold ? (bold ?? reg) : reg,
                      fontBold: bold,
                      fontWeight: f.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                      fontSize: f.size,
                      fontFallback: fallback,
                      lineSpacing: 1,
                    ),
                  ),
                ),
              ),
          ]),
        ));
      }
    }
    return doc.save();
  }
}
