import 'dart:convert';

import 'package:archive/archive.dart';

/// The school's own TC format: a Word (.docx) template with placeholders in
/// braces -- {Student Name}, {DOB in Words}, {TC No} ... -- filled per
/// student. A .docx is a zip; the text lives in word/document.xml (and the
/// header/footer parts) split into runs, so a placeholder Word has broken
/// across runs ("{Student" + " Name}") is still found and replaced.
class TcDocx {
  TcDocx._();

  static final RegExp _ph = RegExp(r'\{([^{}\r\n]{1,60})\}');
  static final RegExp _para = RegExp(r'<w:p[ >][\s\S]*?</w:p>|<w:p/>');
  static final RegExp _wt = RegExp(r'<w:t(?:\s[^>]*)?>([\s\S]*?)</w:t>|<w:t(?:\s[^>]*)?/>');

  static bool _isTextPart(String name) =>
      name == 'word/document.xml' || RegExp(r'^word/(header|footer)\d*\.xml$').hasMatch(name);

  static String _unesc(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  static String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  /// Every placeholder name in the template, in order of first appearance.
  static List<String> placeholders(List<int> docx) {
    final out = <String>[];
    final zip = ZipDecoder().decodeBytes(docx);
    for (final f in zip.files) {
      if (!f.isFile || !_isTextPart(f.name)) continue;
      final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
      for (final p in _para.allMatches(xml)) {
        final text = _wt.allMatches(p.group(0)!).map((m) => _unesc(m.group(1) ?? '')).join();
        for (final m in _ph.allMatches(text)) {
          final k = m.group(1)!.trim();
          if (k.isNotEmpty && !out.contains(k)) out.add(k);
        }
      }
    }
    return out;
  }

  /// The format's items in reading order: (its own wording, its fields), for
  /// TC Details to show the certificate the way it prints. In a table row,
  /// each cell with {placeholders} is an item worded by the text cells before
  /// it ("2." + "Name of the Pupil (IN BLOCK LETTERS)"); a paragraph outside
  /// a table is worded by its text before the first placeholder.
  static List<(String, List<String>)> items(List<int> docx) {
    final zip = ZipDecoder().decodeBytes(docx);
    final f = zip.files.where((f) => f.name == 'word/document.xml').firstOrNull;
    if (f == null) return const [];
    final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
    String text(String p) => _wt.allMatches(p).map((m) => _unesc(m.group(1) ?? '')).join();
    List<String> keys(String t) => [for (final m in _ph.allMatches(t)) m.group(1)!.trim()];
    String tidy(String s) => s.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'[\s:]+$'), '').trim();
    final out = <(String, List<String>)>[];

    void paragraph(String p) {
      final t = text(p);
      final k = keys(t);
      if (k.isEmpty) return;
      out.add((tidy(t.substring(0, t.indexOf('{'))), k));
    }

    final tables = RegExp(r'<w:tbl>[\s\S]*?</w:tbl>');
    final rowRe = RegExp(r'<w:tr[ >][\s\S]*?</w:tr>');
    final cellRe = RegExp(r'<w:tc[ >][\s\S]*?</w:tc>');
    var pos = 0;
    for (final t in tables.allMatches(xml)) {
      for (final p in _para.allMatches(xml.substring(pos, t.start))) {
        paragraph(p.group(0)!);
      }
      for (final r in rowRe.allMatches(t.group(0)!)) {
        final words = <String>[];
        for (final c in cellRe.allMatches(r.group(0)!)) {
          final ct = [for (final p in _para.allMatches(c.group(0)!)) text(p.group(0)!)].join('\n');
          final k = keys(ct);
          if (k.isEmpty) {
            if (ct.trim().isNotEmpty) words.add(ct.trim());
          } else {
            out.add((tidy(words.join(' ')), k));
            words.clear();
          }
        }
      }
      pos = t.end;
    }
    for (final p in _para.allMatches(xml.substring(pos))) {
      paragraph(p.group(0)!);
    }
    return out;
  }

  /// Replace the placeholders of one paragraph's runs with [values] (unknown
  /// names become empty). The text of a placeholder split across runs goes
  /// into the run it starts in; the runs it spilled into lose those chars.
  static String _fillPara(String para, Map<String, String> values) {
    final nodes = _wt.allMatches(para).toList();
    if (nodes.isEmpty) return para;
    final texts = nodes.map((m) => _unesc(m.group(1) ?? '')).toList();
    final joined = texts.join();
    if (!_ph.hasMatch(joined)) return para;
    // owner[i] = which run char i of the joined text came from
    final owner = <int>[];
    for (var n = 0; n < texts.length; n++) {
      for (var i = 0; i < texts[n].length; i++) {
        owner.add(n);
      }
    }
    final outText = List<StringBuffer>.generate(texts.length, (_) => StringBuffer());
    var pos = 0;
    for (final m in _ph.allMatches(joined)) {
      for (var i = pos; i < m.start; i++) {
        outText[owner[i]].write(joined[i]);
      }
      outText[owner[m.start]].write(values[m.group(1)!.trim()] ?? '');
      pos = m.end;
    }
    for (var i = pos; i < joined.length; i++) {
      outText[owner[i]].write(joined[i]);
    }
    // rebuild the paragraph, run text by run text
    final sb = StringBuffer();
    var last = 0;
    for (var n = 0; n < nodes.length; n++) {
      final m = nodes[n];
      sb.write(para.substring(last, m.start));
      sb.write('<w:t xml:space="preserve">${_esc(outText[n].toString())}</w:t>');
      last = m.end;
    }
    sb.write(para.substring(last));
    return sb.toString();
  }

  static String _fillXml(String xml, Map<String, String> values) =>
      xml.replaceAllMapped(_para, (m) => _fillPara(m.group(0)!, values));

  /// Fill the template for each student in [rows] (one value map each) into
  /// ONE document, a page break between students. Headers / footers take the
  /// first student's values (keep only school-level placeholders there).
  static List<int> fill(List<int> docx, List<Map<String, String>> rows) {
    if (rows.isEmpty) throw ArgumentError('Nothing to print');
    final zip = ZipDecoder().decodeBytes(docx);
    final out = Archive();
    for (final f in zip.files) {
      if (!f.isFile) continue;
      List<int> bytes = f.content as List<int>;
      if (f.name == 'word/document.xml') {
        final xml = utf8.decode(bytes, allowMalformed: true);
        final b0 = xml.indexOf('<w:body>');
        final b1 = xml.lastIndexOf('</w:body>');
        if (b0 < 0 || b1 < 0) {
          bytes = utf8.encode(_fillXml(xml, rows.first));
        } else {
          final body = xml.substring(b0 + 8, b1);
          // the section properties close the body; keep them once, at the end
          final s0 = body.lastIndexOf('<w:sectPr');
          final content = s0 >= 0 ? body.substring(0, s0) : body;
          final sect = s0 >= 0 ? body.substring(s0) : '';
          const pageBreak = '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';
          final filled = [for (final r in rows) _fillXml(content, r)].join(pageBreak);
          bytes = utf8.encode('${xml.substring(0, b0 + 8)}$filled$sect${xml.substring(b1)}');
        }
      } else if (_isTextPart(f.name)) {
        bytes = utf8.encode(_fillXml(utf8.decode(bytes, allowMalformed: true), rows.first));
      }
      out.addFile(ArchiveFile(f.name, bytes.length, bytes));
    }
    return ZipEncoder().encode(out)!;
  }

  // ── sample templates ─────────────────────────────────────────────────
  static String _p(String text,
          {bool bold = false, String align = '', int size = 22, int after = 80, bool underline = false, String font = ''}) =>
      '<w:p><w:pPr>${align.isEmpty ? '' : '<w:jc w:val="$align"/>'}<w:spacing w:before="0" w:after="$after" w:line="240" w:lineRule="auto"/></w:pPr>'
      '<w:r><w:rPr>${font.isEmpty ? '' : '<w:rFonts w:ascii="$font" w:hAnsi="$font" w:cs="$font"/>'}'
      '${bold ? '<w:b/>' : ''}${underline ? '<w:u w:val="single"/>' : ''}<w:sz w:val="$size"/></w:rPr>'
      '<w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>';

  /// A table: [rows] of cells (a cell's '\n' = a new paragraph, a leading '*'
  /// = bold); [widths] in twentieths of a point.
  static String _table(List<List<String>> rows, List<int> widths,
      {bool borders = false, int size = 20, int after = 40, String font = ''}) {
    final edge = borders ? 'w:val="single" w:sz="4" w:space="0" w:color="000000"' : 'w:val="nil"';
    final b = StringBuffer('<w:tbl><w:tblPr><w:tblW w:w="${widths.fold<int>(0, (a, w) => a + w)}" w:type="dxa"/>'
        '<w:tblBorders><w:top $edge/><w:left $edge/><w:bottom $edge/><w:right $edge/><w:insideH $edge/><w:insideV $edge/></w:tblBorders>'
        '<w:tblLayout w:type="fixed"/><w:tblCellMar><w:left w:w="60" w:type="dxa"/><w:right w:w="60" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblGrid>');
    for (final w in widths) {
      b.write('<w:gridCol w:w="$w"/>');
    }
    b.write('</w:tblGrid>');
    for (final r in rows) {
      b.write('<w:tr><w:trPr><w:cantSplit/></w:trPr>');
      for (var i = 0; i < widths.length; i++) {
        var cell = i < r.length ? r[i] : '';
        // A leading '#' = Tamil text: Arial has no Tamil letters.
        final tamil = cell.startsWith('#');
        if (tamil) cell = cell.substring(1);
        final bold = cell.startsWith('*');
        b.write('<w:tc><w:tcPr><w:tcW w:w="${widths[i]}" w:type="dxa"/></w:tcPr>');
        for (final line in (bold ? cell.substring(1) : cell).split('\n')) {
          b.write(_p(line, bold: bold, size: size, after: after, font: tamil ? 'Nirmala UI' : font));
        }
        b.write('</w:tc>');
      }
      b.write('</w:tr>');
    }
    return (b..write('</w:tbl>')).toString();
  }

  static List<int> _pack(String body) {
    final doc = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="700" w:right="1000" w:bottom="700" w:left="1000" w:header="500" w:footer="500" w:gutter="0"/></w:sectPr>'
        '</w:body></w:document>';
    const types = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>';
    const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>';
    final a = Archive();
    void add(String name, String text) {
      final b = utf8.encode(text);
      a.addFile(ArchiveFile(name, b.length, b));
    }

    add('[Content_Types].xml', types);
    add('_rels/.rels', rels);
    add('word/document.xml', doc);
    return ZipEncoder().encode(a)!;
  }

  /// A starting template (CBSE-style transfer certificate) using the standard
  /// placeholders -- download, adjust in Word, upload back.
  static List<int> sample(List<(String, String)> lines, {String title = 'TRANSFER CERTIFICATE'}) {
    final body = StringBuffer()
      ..write(_p('{School Name}', bold: true, align: 'center', size: 32))
      ..write(_p('{School Address}', align: 'center'))
      ..write(_p(title, bold: true, align: 'center', size: 28))
      ..write(_p('{Copy}', bold: true, align: 'center', size: 20))
      ..write(_p('TC No: {TC No}                                                    Admission No: {Admission No}'));
    var i = 1;
    for (final l in lines) {
      body.write(_p('${i++}. ${l.$1}  :  {${l.$2}}'));
    }
    body
      ..write(_p(''))
      ..write(_p('Date: {Print Date}                                    Signature of the Principal', bold: true));
    return _pack(body.toString());
  }

  /// The Tamil Nadu / Puducherry state-board TC, laid out like the old
  /// product's built-in print (PsTc): numbered items, the course-of-study
  /// table, the headmaster's signature and the parent's declaration.
  /// [studyCols]: (placeholder part, heading) of the course-of-study table,
  /// whose rows use {Study n <part>}.
  static List<int> sampleStateBoard({required int studyRows, required List<(String, String)> studyCols}) {
    String v(String ph) => ':  $ph';
    // one row per sub-item, so each value sits level with its label
    final items = <List<String>>[
      ['1.', '(a) Name of the School', v('{School Name}')],
      ['', '(b) Name of the Educational District', v('{Educational District}')],
      ['', '(c) Name of the Revenue District', v('{Revenue District}')],
      ['2.', 'Name of the Pupil (in block letters)', v('{Student Name (Block Letters)}')],
      ['3.', 'Name of the Father or Mother of the Pupil', v('{Father or Mother Name}')],
      ['4.', 'Nationality and Religion', v('{Nationality and Religion}')],
      ['5.', 'Community and whether he/she belongs to (a) Adi Dravidar (Scheduled Caste) or Scheduled Tribe (b) Backward Class '
            '(c) Most Backward Class (d) Converted to Christianity from Scheduled Caste (e) Denotified Communities (f) Other Communities',
        '${v('{Community Category} - {Community}')}\n   {Community Certificate Note}'],
      ['6.', 'Sex', v('{Gender}')],
      ['7.', 'Date of Birth as entered in the Admission Register (in figures and words)', v('{DOB in Figures and Words}')],
      ['8.', 'Personal marks of identification', '${v('(a) {Identification Mark 1}')}\n   (b) {Identification Mark 2}'],
      ['9.', 'Date of Admission and Standard in which admitted (the year to be entered in words)',
        '${v('{Date of Admission} ({Date of Admission in Words})')}\n   Standard {Admission Standard in Words}'],
      ['10.', '(a) Standard in which the pupil was studying at the time of leaving (in words)', v('{Standard in Words}')],
      ['', '(b) The course offered, i.e., General Education or Vocational Education', v('{Course Offered}')],
      ['', '(c) In the case of General Education, the subjects offered under Part III Group A and Medium of Instruction',
        v('{Part III Group A Subjects} / {Medium}')],
      ['', '(d) In the case of Vocational Education, the vocational subject under Part III Group B and the related subject offered under Part III Group A',
        v('{Part III Group B Subjects}')],
      ['', '(e) Language offered under Part I', v('{Part I Language}')],
      ['11.', 'Whether qualified for promotion to higher standard', v('{Qualified for Promotion}')],
      ['12.', 'Whether the pupil was in receipt of any scholarship (nature of the scholarship to be specified)', v('{Scholarship}')],
      ['13.', 'Whether the pupil has undergone medical inspection during the last academic year (first or repeat to be specified)', v('{Medical Inspection}')],
      ['14.', 'Date on which the pupil actually left the school', v('{Leaving Date}')],
      ['15.', "The pupil's conduct and character", v('{General Conduct}')],
      ['16.', 'Date on which application for Transfer Certificate was made on behalf of the pupil by the parent or guardian', v('{Date of Application}')],
      ['17.', 'Date of the Transfer Certificate', v('{TC Date}')],
    ];
    final study = <List<String>>[
      [for (final c in studyCols) '*${c.$2}'],
      for (var n = 1; n <= studyRows; n++) [for (final c in studyCols) '{Study $n ${c.$1}}'],
    ];
    final body = StringBuffer()
      ..write(_p('{School Name}', bold: true, align: 'center', size: 30, after: 0))
      ..write(_p('{School Address}', align: 'center', size: 20))
      ..write(_p('TRANSFER CERTIFICATE', bold: true, align: 'center', size: 28, after: 0))
      ..write(_p('{Copy}', bold: true, align: 'center', size: 18))
      ..write(_table([
        ['Serial No : {TC No}', 'Admission No : {Admission No}', 'EMIS No : {EMIS No}'],
        ['Mark Certificate S.No : {Mark Certificate S.No}', 'Register No : {Register No}', 'TMR Code No & Date : {TMR Code No & Date}'],
      ], const [3700, 2500, 3700], size: 17, after: 20))
      ..write(_p('', after: 40))
      ..write(_table(items, const [520, 5300, 4080], size: 18, after: 30))
      ..write(_p('18.  Course of study', size: 18, after: 30))
      ..write(_table(study, const [2900, 2000, 1600, 1600, 1800], borders: true, size: 17, after: 10))
      ..write(_p('', after: 120))
      ..write(_table([
        ['Date : {Print Date}', '*Signature of the Headmaster with date and school seal'],
      ], const [4950, 4950]))
      ..write(_p('', after: 120))
      ..write(_p('DECLARATION BY THE PARENT OR GUARDIAN', bold: true, align: 'center', size: 18, after: 40))
      ..write(_p('I hereby declare that the particulars recorded against items 2 to 7 are correct and that no change will be demanded by me in future.', size: 18))
      ..write(_p('', after: 120))
      ..write(_p('Signature of the Parent / Guardian', bold: true, align: 'right', size: 18));
    return _pack(body.toString());
  }
}

/// The client schools' own TC layouts (C:/pg_backups/TC samples), as Word
/// formats. [blank] leaves out every {placeholder} (values become ":"), for
/// uploading with "Place Fields": Word turns it into the PDF and the fields
/// are placed next to their labels.
class TcClientFormats {
  TcClientFormats._();

  static const _font = 'Arial';
  static String _p(String t, {bool bold = false, String align = '', int size = 20, int after = 40, bool underline = false}) =>
      TcDocx._p(t, bold: bold, align: align, size: size, after: after, underline: underline, font: _font);
  static String _t(List<List<String>> rows, List<int> widths, {bool borders = false, int size = 19, int after = 24}) =>
      TcDocx._table(rows, widths, borders: borders, size: size, after: after, font: _font);

  /// Immaculate Heart of Mary GHSS, Puducherry -- state-board TC.
  /// [higherSecondary]: the XII format (items 11 a-e, fees paid, 20 items).
  static List<int> immaculate({required bool higherSecondary, bool blank = false}) {
    String v(String ph) => blank ? ':' : ':  $ph';
    final items = <List<String>>[
      ['1.', '(a) Name of the School', v('{School Name}')],
      ['', '(b) Name of the Educational District / Revenue District', v('{Educational District}')],
      ['2.', 'Name of the Pupil (IN BLOCK LETTERS)', v('{Student Name (Block Letters)}')],
      ['', '#மாணவியின் பெயர் (தமிழில்)', '#${v('{Student Name (Tamil)}')}'],
      ['3.', 'Name of the Father', v('{Father Name}')],
      ['4.', 'Name of the Mother', v('{Mother Name}')],
      ['5.', 'Nationality, Religion & Caste', v('{Nationality, Religion and Caste}')],
      ['6.', 'Community', v('{Community}')],
      ['7.', 'Gender', v('{Gender}')],
      ['8.', 'Date of Birth as entered in the Admission Register (in figures and words)', v('{DOB}  {DOB in Words}')],
      ['9.', 'Personal Marks of Identification',
        blank ? ':  a)\n:  b)' : ':  a) {Identification Mark 1}\n:  b) {Identification Mark 2}'],
      ['10.', 'Date of Admission and Standard in which admitted (the year to be entered in words)',
        blank ? ':' : ':  {Date of Admission} ({Admission Year in Words})\n    {Admission Class}-STD'],
      ['11.', 'Standard in which the Pupil was studying at the time of Leaving (in words)', v('{Standard Ordinal} STANDARD')],
      if (higherSecondary) ...[
        ['', 'a) The Course i.e, General Education or Vocational Education', v('{Course Offered}')],
        ['', 'b) In the case of General Education the Subjects offered under Part III, Group -A and Medium of Instruction',
          v('{Part III Group A Subjects}')],
        ['', "c) In the case of Vocational Education, the Vocational subject under Part III, Group – 'B' and the related "
            "subject offered under Part - III Group 'A'", v('{Part III Group B Subjects}')],
        ['', 'd) Language offered under Part-I', v('{Part I Language}')],
        ['', 'e) Medium of Study', v('{Medium}')],
      ],
    ];
    var n = 12;
    String no() => '${n++}.';
    items.addAll([
      [no(), higherSecondary
          ? 'Whether qualified for promotion to Higher Standard? under Higher Secondary Education rules'
          : 'Whether qualified for promotion to Higher Standard?', v('{Qualified for Promotion}')],
      if (higherSecondary) [no(), 'Whether the pupil has paid all the fees due to the school', v('{All Fees Paid}')],
      [no(), higherSecondary
          ? 'Whether the Pupil was in receipt of any Scholarship (Nature of Scholarship to be specified) or any Educational concession'
          : 'Whether the Pupil was in receipt of any Scholarship? (Nature of Scholarship to be specified)', v('{Scholarship}')],
      [no(), 'Whether the Pupil has undergone medical inspection during the academic year?', v('{Medical Inspection}')],
      [no(), 'Date on which the pupil actually left the school', v('{Leaving Date}')],
      [no(), "The Pupil's Conduct and Character", v('{General Conduct}')],
      [no(), 'Date on which application for Transfer Certificate was made on behalf of the Pupil by the Parent or Guardian',
        v('{Date of Application}')],
      [no(), 'Date of the Transfer Certificate', v('{TC Date}')],
    ]);
    final studyNo = no();
    const cols = [('School', 'Name of the School'), ('Years', 'Academic year(s)'), ('Standard', 'Standard(s) Studied'),
      ('Language', 'First Language'), ('Medium', 'Medium of Instruction')];
    final study = <List<String>>[
      [for (final c in cols) '*${c.$2}'],
      for (var r = 1; r <= 2; r++) [for (final c in cols) blank ? '' : '{Study $r ${c.$1}}'],
    ];
    String hv(String ph) => blank ? ':' : ':  $ph';
    final body = StringBuffer()
      ..write(_p("IMMACULATE HEART OF MARY GIRLS' HR. SEC. SCHOOL", bold: true, align: 'center', size: 30, after: 0))
      ..write(_p('(Recognised by Director of School Education)', align: 'center', size: 20, after: 0))
      ..write(_p('Puducherry - 1', align: 'center', size: 20, after: 0))
      ..write(_p('_' * 86, align: 'center', size: 20, after: 40))
      ..write(_p('TRANSFER CERTIFICATE', bold: true, align: 'center', size: 26, after: 60, underline: true))
      ..write(_t([
        ['*Serial No.', hv('{TC No}'), '*Admission No.', hv('{Admission No}')],
        ['*Student PEN', hv('{Student PEN}'), '*Aadhar No', hv('{Aadhar No}')],
        ['*APAAR ID', hv('{EMIS No}'), '*Cert. Sl.No', hv('{Cert Sl No}')],
      ], const [1500, 3450, 1600, 3350], size: 19, after: 10))
      ..write(_p('_' * 86, align: 'center', size: 20, after: 60))
      ..write(_t(items, const [450, 5000, 4450], size: higherSecondary ? 18 : 19, after: higherSecondary ? 14 : 24))
      ..write(_p('$studyNo Previous Year(s) and Course of studies', size: 19, after: 40))
      ..write(_t(study, const [3300, 1700, 1500, 1600, 1800], borders: true, size: 18, after: 10))
      ..write(_p('', after: higherSecondary ? 400 : 600))
      ..write(_p('Signature of the Principal', bold: true, align: 'right', size: 19, after: higherSecondary ? 160 : 300))
      ..write(_p('DECLARATION BY THE PARENT OR GUARDIAN', bold: true, align: 'center', size: 19, after: 40, underline: true))
      ..write(_p('        I hereby declare that the particulars recorded against items 2 to 7 are correct and that no change '
          'will be demanded by me in future.', size: 19, after: higherSecondary ? 200 : 300))
      ..write(_p('Signature of the Parent / Guardian', bold: true, align: 'right', size: 19));
    return TcDocx._pack(body.toString());
  }

  /// VES -- CBSE-style TC, 25 items. The top of the page is left empty for
  /// the school's pre-printed letterhead.
  static List<int> ves({bool blank = false}) {
    String v(String ph) => blank ? ':' : ':  $ph';
    var n = 1;
    List<String> it(String label, String value) => ['${n++}.', label, value];
    final items = <List<String>>[
      it('Name of the Student (in BLOCK LETTERS)', v('{Student Name (Block Letters)}')),
      it("Mother's Name", v('{Mother Name}')),
      it("Father's / Guardian Name", v('{Father Name}')),
      it('Date of Birth (in Christian Era) according to Admission & Withdrawal in figures and in words', v('{DOB}  {DOB in Words}')),
      it('Proof for Date of Birth submitted at the time of admission', v('{Proof of DOB}')),
      it('Nationality / Religion', v('{Nationality and Religion}')),
      it('Whether the candidate belongs to Schedule Caste or Schedule Tribe or OBC', v('{Community Category}')),
      it('Date of first admission in the School with class', v('{Date of Admission}  {Admission Class}')),
      it('Class in which the Pupil last studied (In figures)',
        blank ? ':                    (Class In words) :' : ':  {Standard}          (Class In words) :  {Standard Ordinal} STD'),
      it('School / Board Annual Examination last taken with result', v('{Last Exam Result}')),
      it('Whether failed, if so once / twice in the same class', v('{Whether Failed}')),
      it('Subject studied', v('{Subjects Studied}')),
      it('Whether qualified for promotion to the higher class. If so, to which class (In figures)',
        blank ? ':\n:                    (In words) :' : ':  {Qualified for Promotion}\n:  {Promoted Class}          (In words) :  {Promoted Class in Words}'),
      it('No. of working days present / Total no. of working days', blank ? ':' : ':  {Days Present} / {Total Working Days}'),
      it('Month upto which the pupil has paid school dues', v('{Fees Paid Up To}')),
      it('Any fee concession availed of; If so, the nature of such Concession', v('{Fee Concession}')),
      it('Whether NCC Cadet / Boy Scout / Girl Guide (details may be given)', v('{NCC / Scout / Guide}')),
      it('Whether school is under Govt./Minority/ Independent Category', v('{School Category}')),
      it('Games played or extra-curricular activities in which the Pupil usually took part (Mention achievement level therein)',
        v('{Extra Curricular Activities}')),
      it('General conduct', v('{General Conduct}')),
      it('Date of application for certificate', v('{Date of Application}')),
      it("Date on which pupil's name was struck off the rolls of the school", v('{Date Struck Off}')),
      it('Date of issue of certificate', v('{TC Date}')),
      it('Reason for leaving the school', v('{Reason for Leaving}')),
      it('Any other remarks', v('{Remarks}')),
    ];
    String hv(String ph) => blank ? ':' : ':  $ph';
    final body = StringBuffer();
    for (var i = 0; i < 6; i++) {
      body.write(_p('', size: 22, after: 120)); // room for the pre-printed letterhead
    }
    body
      ..write(_t([
        ['*T.C. No.', hv('{TC No}'), '*EMIS No', hv('{EMIS No}'), '*Admission No', hv('{Admission No}')],
      ], const [1100, 2200, 1100, 2300, 1400, 1800], size: 21, after: 10))
      ..write(_p('', after: 80))
      ..write(_t(items, const [450, 4750, 4700], after: 50))
      ..write(_p('', after: 200))
      ..write(_p('        I hereby declare that the above information including Name of the Candidate, Father\'s Name, '
          'Mother\'s Name and date of Birth furnished above is correct as per school records', size: 19, after: 700))
      ..write(_t([
        [blank ? 'Date :' : 'Date :  {Print Date}', 'Signature of the Principal'],
      ], const [4950, 4950], size: 19));
    return TcDocx._pack(body.toString());
  }
}

/// Numbers and dates in words, for {DOB in Words} / {Standard in Words}.
class InWords {
  InWords._();
  static const _ones = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven',
    'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
  static const _tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
  static const _ordinals = ['', 'First', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'Seventh', 'Eighth', 'Ninth',
    'Tenth', 'Eleventh', 'Twelfth', 'Thirteenth', 'Fourteenth', 'Fifteenth', 'Sixteenth', 'Seventeenth', 'Eighteenth',
    'Nineteenth', 'Twentieth', 'Twenty First', 'Twenty Second', 'Twenty Third', 'Twenty Fourth', 'Twenty Fifth',
    'Twenty Sixth', 'Twenty Seventh', 'Twenty Eighth', 'Twenty Ninth', 'Thirtieth', 'Thirty First'];
  static const _months = ['', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September',
    'October', 'November', 'December'];

  static String number(int n) {
    if (n == 0) return 'Zero';
    String below1000(int x) {
      final parts = <String>[];
      if (x >= 100) {
        parts.add('${_ones[x ~/ 100]} Hundred');
        x %= 100;
      }
      if (x >= 20) {
        parts.add(_tens[x ~/ 10] + (x % 10 > 0 ? ' ${_ones[x % 10]}' : ''));
      } else if (x > 0) {
        parts.add(_ones[x]);
      }
      return parts.join(' ');
    }

    final parts = <String>[];
    if (n >= 1000) {
      parts.add('${below1000(n ~/ 1000)} Thousand');
      n %= 1000;
    }
    if (n > 0) parts.add(below1000(n));
    return parts.join(' ');
  }

  /// 15-05-2021 -> "Fifteenth May Two Thousand Twenty One"
  static String date(DateTime d) => '${_ordinals[d.day]} ${_months[d.month]} ${number(d.year)}';

  static const _roman = {'I': 1, 'II': 2, 'III': 3, 'IV': 4, 'V': 5, 'VI': 6, 'VII': 7, 'VIII': 8, 'IX': 9, 'X': 10, 'XI': 11, 'XII': 12};

  /// "II" -> "Two", "LKG" -> "LKG" (standards that are not numerals stay).
  /// "Twelfth" for XII / 12 -- as the TCs write it ("TWELFTH STANDARD",
  /// "TENTH STD"). LKG / UKG / anything else is returned as it is.
  static String standardOrdinal(String std) {
    final s = std.trim().toUpperCase();
    final n = _roman[s] ?? int.tryParse(s);
    return n != null && n > 0 && n < _ordinals.length ? _ordinals[n] : std.trim();
  }

  static String standard(String std) {
    final s = std.trim().toUpperCase();
    final r = _roman[s];
    if (r != null) return number(r);
    final n = int.tryParse(s);
    return n != null ? number(n) : std.trim();
  }
}
