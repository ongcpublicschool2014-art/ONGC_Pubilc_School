import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// One field placed on a PDF format (TC or fee receipt). Positions are in PDF
/// points (1/72 inch) from the page's top-left; [y] is the top of the text.
/// [rowH] > 0 makes it a list block (the receipt's fee lines): its value is
/// one line per row, "particular<TAB>amount", printed [rowH] apart with the
/// amount right-aligned in the last [amtW] points of the width.
class TcPdfField {
  String key;
  int page;
  double x, y, w, size;
  String align; // left | center | right
  bool bold;
  double rowH, amtW;
  /// The format's own wording for this field ("2. Name of the Pupil (IN
  /// BLOCK LETTERS)"), when known -- set by automatic placement, shown on
  /// TC Details. Empty for a field placed by hand.
  String label;

  TcPdfField({
    required this.key,
    this.page = 0,
    required this.x,
    required this.y,
    this.w = 200,
    this.size = 11,
    this.align = 'left',
    this.bold = false,
    this.rowH = 0,
    this.amtW = 0,
    this.label = '',
  });

  bool get isList => rowH > 0;

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
      rowH: d(j['rowh'], 0),
      amtW: d(j['amtw'], 0),
      label: '${j['label'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key, 'page': page, 'x': _r(x), 'y': _r(y), 'w': _r(w), 'size': _r(size), 'align': align, 'bold': bold,
        if (rowH > 0) 'rowh': _r(rowH),
        if (rowH > 0) 'amtw': _r(amtW),
        if (label.isNotEmpty) 'label': label,
      };

  static double _r(double v) => (v * 10).roundToDouble() / 10;
}

/// Paper sizes a TC can be printed on (PDF points). 'FORMAT' = the uploaded
/// PDF's own page size.
const Map<String, (String, double, double)> kTcPapers = {
  'FORMAT': ('Same as the uploaded format', 0, 0),
  'A4': ('A4 (210 x 297 mm)', 595.28, 841.89),
  'A5': ('A5 (148 x 210 mm)', 419.53, 595.28),
  'LEGAL': ('Legal (8.5 x 14 in)', 612, 1008),
  'FOOLSCAP': ('Foolscap / FS (8.5 x 13 in)', 612, 936),
  'LETTER': ('Letter (8.5 x 11 in)', 612, 792),
};

/// Where each field prints on a PDF TC format. [background] off = print the
/// values only, for TC books that already have the form printed on them.
/// [offX]/[offY]: printer adjustment in mm (+ moves the print right / down),
/// for a printer that feeds the TC book a little off. [paper]: a [kTcPapers] key.
class TcPdfLayout {
  bool background;
  double offX, offY;
  String paper;
  final List<TcPdfField> fields;

  TcPdfLayout({this.background = true, this.offX = 0, this.offY = 0, this.paper = 'FORMAT', List<TcPdfField>? fields})
      : fields = fields ?? [];

  factory TcPdfLayout.fromJson(Object? raw) {
    final j = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    double d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
    final paper = '${j['paper'] ?? 'FORMAT'}';
    return TcPdfLayout(
      background: j['background'] != false,
      offX: d(j['offx']),
      offY: d(j['offy']),
      paper: kTcPapers.containsKey(paper) ? paper : 'FORMAT',
      fields: [
        for (final f in (j['fields'] as List? ?? const []))
          if (f is Map) TcPdfField.fromJson(Map<String, dynamic>.from(f)),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'background': background,
        'offx': TcPdfField._r(offX),
        'offy': TcPdfField._r(offY),
        'paper': paper,
        'fields': [for (final f in fields) f.toJson()],
      };

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
  static Future<Uint8List> fill(Uint8List pdf, TcPdfLayout layout, List<Map<String, String>> rows) async =>
      (await build(pdf, layout, rows)).$1;

  static const double _mm = 72 / 25.4;

  /// As [fill], also giving the paper size to print on. [guides]: the
  /// alignment test -- a mm ruler on the top and left edges and a box round
  /// each field, to hold against a TC book page.
  static Future<(Uint8List, PdfPageFormat)> build(Uint8List pdf, TcPdfLayout layout, List<Map<String, String>> rows,
      {bool guides = false}) async {
    final (doc, fmt) = await buildDoc(pdf, layout, rows, guides: guides);
    return (await doc.save(), fmt);
  }

  /// As [build], as a document. [pages]: the format already rendered (at 200
  /// dpi when the background prints), to skip rendering it again.
  static Future<(pw.Document, PdfPageFormat)> buildDoc(Uint8List pdf, TcPdfLayout layout, List<Map<String, String>> rows,
      {bool guides = false, List<TcPdfPage>? pages}) async {
    // background printed at 200 dpi; without it only the page sizes are needed
    pages ??= await TcPdf.pages(pdf, dpi: layout.background ? 200 : 20);
    final paper = kTcPapers[layout.paper];
    PdfPageFormat formatOf(TcPdfPage p) {
      if (paper != null && paper.$2 != 0) return PdfPageFormat(paper.$2, paper.$3);
      // the format's own size, measured from a coarse render: snap to the
      // standard paper it is (A4 etc.) so the printer is not asked for an odd size
      for (final k in kTcPapers.values) {
        if (k.$2 == 0) continue;
        if ((p.wPt - k.$2).abs() < 4 && (p.hPt - k.$3).abs() < 4) return PdfPageFormat(k.$2, k.$3);
        if ((p.wPt - k.$3).abs() < 4 && (p.hPt - k.$2).abs() < 4) return PdfPageFormat(k.$3, k.$2);
      }
      return PdfPageFormat(p.wPt, p.hPt);
    }
    final dx = layout.offX * _mm, dy = layout.offY * _mm;
    const ink = PdfColor.fromInt(0xFF2F7FB5);
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
        final fmt = formatOf(p);
        doc.addPage(pw.Page(
          pageFormat: fmt,
          margin: pw.EdgeInsets.zero,
          build: (ctx) => pw.Stack(children: [
            if (layout.background)
              pw.Positioned(left: dx, top: dy, child: pw.Image(images[i], width: p.wPt, height: p.hPt, fit: pw.BoxFit.fill)),
            if (guides) ..._ruler(fmt, ink, reg),
            for (final f in layout.fields.where((f) => f.page == i && f.isList))
              ..._list(f, row[f.key] ?? '', dx, dy, guides ? ink : null, reg, bold, fallback),
            for (final f in layout.fields.where((f) => f.page == i && !f.isList))
              pw.Positioned(
                left: f.x + dx,
                top: f.y + dy,
                child: pw.Container(
                  width: f.w,
                  decoration: guides ? pw.BoxDecoration(border: pw.Border.all(color: ink, width: 0.4)) : null,
                  child: pw.Text(
                    row[f.key] ?? '',
                    textAlign: _align(f.align),
                    style: pw.TextStyle(
                      font: f.bold ? (bold ?? reg) : reg,
                      fontBold: bold,
                      fontWeight: f.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                      fontSize: _fitSize(ctx, f, row[f.key] ?? '', f.bold ? (bold ?? reg) : reg),
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
    return (doc, formatOf(pages.first));
  }

  /// Smallest share of the chosen size a long value may shrink to. Past it
  /// the value wraps at that size rather than becoming unreadable.
  static const double _minShrink = 0.6;

  /// Font size for [text] in field [f]: the chosen size when it fits the
  /// field's width on one line, otherwise smaller so it does (a long name
  /// stays on its line instead of running into the next row of the form),
  /// but not below [_minShrink] of the chosen size. A value with its own line
  /// breaks keeps the chosen size and wraps as typed.
  static double _fitSize(pw.Context ctx, TcPdfField f, String text, pw.Font? font) {
    final t = text.trim();
    if (t.isEmpty || t.contains('\n') || f.w <= 0) return f.size;
    try {
      final width = (font ?? pw.Font.helvetica()).getFont(ctx).stringMetrics(t).advanceWidth * f.size;
      if (width <= f.w) return f.size;
      final fit = f.size * f.w / width * 0.98; // a hair under, for rounding
      return fit < f.size * _minShrink ? f.size * _minShrink : fit;
    } catch (_) {
      return f.size;
    }
  }

  /// A list block: one row per line of [value] ("particular<TAB>amount").
  static List<pw.Widget> _list(TcPdfField f, String value, double dx, double dy, PdfColor? guide,
      pw.Font? reg, pw.Font? bold, List<pw.Font> fallback) {
    final lines = value.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final style = pw.TextStyle(
      font: f.bold ? (bold ?? reg) : reg,
      fontBold: bold,
      fontWeight: f.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      fontSize: f.size,
      fontFallback: fallback,
    );
    final amtW = f.amtW.clamp(0.0, f.w);
    return [
      if (guide != null)
        pw.Positioned(
          left: f.x + dx,
          top: f.y + dy,
          child: pw.Container(
            width: f.w,
            height: f.rowH * (lines.isEmpty ? 1 : lines.length),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: guide, width: 0.4)),
          ),
        ),
      for (var r = 0; r < lines.length; r++)
        pw.Positioned(
          left: f.x + dx,
          top: f.y + dy + r * f.rowH,
          child: pw.SizedBox(
            width: f.w,
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Expanded(child: pw.Text(lines[r].split('\t').first, style: style, maxLines: 1)),
              if (amtW > 0)
                pw.SizedBox(
                  width: amtW,
                  child: pw.Text(lines[r].contains('\t') ? lines[r].split('\t').last : '',
                      style: style, textAlign: pw.TextAlign.right, maxLines: 1),
                ),
            ]),
          ),
        ),
    ];
  }

  /// mm marks along the top and left edges of the page, numbered every cm.
  static List<pw.Widget> _ruler(PdfPageFormat f, PdfColor ink, pw.Font? font) {
    final out = <pw.Widget>[];
    pw.Widget tick(double l, double t, double w, double h) =>
        pw.Positioned(left: l, top: t, child: pw.Container(width: w, height: h, color: ink));
    pw.Widget num(double l, double t, int n) => pw.Positioned(
        left: l, top: t, child: pw.Text('$n', style: pw.TextStyle(font: font, fontSize: 5, color: ink)));
    for (var m = 0; m * _mm <= f.width; m++) {
      final len = m % 10 == 0 ? 6.0 : (m % 5 == 0 ? 4.0 : 2.0);
      out.add(tick(m * _mm, 0, 0.3, len * _mm / 2));
      if (m % 10 == 0 && m > 0) out.add(num(m * _mm + 1, 3.2 * _mm / 2 + 1, m ~/ 10));
    }
    for (var m = 0; m * _mm <= f.height; m++) {
      final len = m % 10 == 0 ? 6.0 : (m % 5 == 0 ? 4.0 : 2.0);
      out.add(tick(0, m * _mm, len * _mm / 2, 0.3));
      if (m % 10 == 0 && m > 0) out.add(num(3.2 * _mm / 2 + 1, m * _mm + 1, m ~/ 10));
    }
    out.add(pw.Positioned(
      left: 14 * _mm,
      top: 4 * _mm,
      child: pw.Text('ALIGNMENT TEST -- edge marks are mm, numbers are cm. Boxes show where each field prints.',
          style: pw.TextStyle(font: font, fontSize: 6, color: ink)),
    ));
    return out;
  }
}
