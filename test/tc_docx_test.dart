import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/tc_docx.dart';

String _docXml(List<int> docx) {
  final zip = ZipDecoder().decodeBytes(docx);
  final f = zip.files.firstWhere((f) => f.name == 'word/document.xml');
  return utf8.decode(f.content as List<int>);
}

List<int> _docxWith(String bodyXml) {
  final doc = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="x"><w:body>$bodyXml<w:sectPr/></w:body></w:document>';
  final a = Archive();
  final b = utf8.encode(doc);
  a.addFile(ArchiveFile('word/document.xml', b.length, b));
  return ZipEncoder().encode(a)!;
}

void main() {
  test('sample template lists its placeholders', () {
    final docx = TcDocx.sample([('Name of the Pupil', 'Student Name'), ('Date of Birth in words', 'DOB in Words')]);
    final ph = TcDocx.placeholders(docx);
    expect(ph, containsAll(['School Name', 'Copy', 'TC No', 'Admission No', 'Student Name', 'DOB in Words', 'Print Date']));
  });

  test('fills two students into one document with a page break', () {
    final docx = TcDocx.sample([('Name of the Pupil', 'Student Name')]);
    final out = TcDocx.fill(docx, [
      {'Student Name': 'GURU & CO', 'TC No': 'TC26/0001'},
      {'Student Name': 'PRIYA', 'TC No': 'TC26/0002'},
    ]);
    final xml = _docXml(out);
    expect(xml, contains('GURU &amp; CO'));
    expect(xml, contains('PRIYA'));
    expect(xml, contains('TC26/0002'));
    expect(xml, contains('w:type="page"'));
    expect(xml, isNot(contains('{Student Name}')));
    expect('<w:sectPr'.allMatches(xml).length, 1);
  });

  test('a placeholder Word split across runs is still replaced', () {
    final docx = _docxWith('<w:p><w:r><w:t>Name: {Stud</w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>ent Na</w:t></w:r><w:r><w:t>me} ok</w:t></w:r></w:p>');
    expect(TcDocx.placeholders(docx), ['Student Name']);
    final xml = _docXml(TcDocx.fill(docx, [{'Student Name': 'ANU'}]));
    expect(xml, contains('Name: ANU'));
    expect(xml, contains(' ok'));
    expect(xml, isNot(contains('{')));
  });

  test('in words', () {
    expect(InWords.date(DateTime(2021, 5, 15)), 'Fifteenth May Two Thousand Twenty One');
    expect(InWords.standard('XII'), 'Twelve');
    expect(InWords.standard('LKG'), 'LKG');
    expect(InWords.number(1999), 'One Thousand Nine Hundred Ninety Nine');
  });
}
