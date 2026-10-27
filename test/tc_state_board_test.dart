import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/services/tc_service.dart';
import 'package:school_admin/utils/tc_docx.dart';
import 'package:school_admin/utils/tc_fields.dart';

String _docXml(List<int> docx) =>
    utf8.decode(ZipDecoder().decodeBytes(docx).files.firstWhere((f) => f.name == 'word/document.xml').content as List<int>);

void main() {
  final sample = TcDocx.sampleStateBoard(studyRows: kTcStudyRows, studyCols: kTcStudyCols);

  test('every placeholder in the state-board sample is a known field', () {
    final ph = TcDocx.placeholders(sample);
    final known = {...kTcFieldKeys, ...kTcPrintTimeKeys};
    expect(ph.where((k) => !known.contains(k)), isEmpty);
    expect(ph, containsAll(['Educational District', 'Community Certificate Note', 'Study 1 School', 'Study 5 Medium', 'TMR Code No & Date']));
    final out = Platform.environment['TC_SAMPLE_OUT'];
    if (out != null) File(out).writeAsBytesSync(sample);
  });

  test('the state-board sample fills, table cells included', () {
    final item = {
      'student': {'stuname': 'Arun Kumar', 'studob': '2015-06-05', 'courname': 'V', 'stuadmdate': '2019-06-10'},
      'admission': {'admdate': '2019-06-10', 'courname': 'LKG', 'fathername': 'Suresh', 'nationality': 'Indian', 'religion': 'Hindu',
        'prevschool': 'St. Mary Nursery', 'prevclass': 'Pre-KG', 'medium': 'English'},
      'tc': {'tcno': 'TC26/0001', 'tcdate': '2026-10-27'},
    };
    final v = TcService.autoValues(item, schoolName: 'ONGC PUBLIC SCHOOL', schoolAddress: 'Puducherry', yearLabel: '2026-2027');
    expect(v['Student Name (Block Letters)'], 'ARUN KUMAR');
    expect(v['Nationality and Religion'], 'Indian - Hindu');
    expect(v['Father or Mother Name'], 'Suresh');
    expect(v['DOB in Figures and Words'], '05-06-2015 (Fifth June Two Thousand Fifteen)');
    expect(v['Study 1 Years'], '2019-2020 to 2026-2027');
    expect(v['Study 1 Standard'], 'LKG to V');
    expect(v['Study 2 School'], 'St. Mary Nursery');
    expect(v['Admission Standard in Words'], 'LKG');

    final filled = TcDocx.fill(sample, [{...v, 'Copy': 'ORIGINAL', 'Print Date': '27-10-2026', 'Community Category': 'BC', 'Community': 'Vanniyar'}]);
    final out = Platform.environment['TC_FILLED_OUT'];
    if (out != null) File(out).writeAsBytesSync(filled);
    final xml = _docXml(filled);
    expect(xml, contains('ARUN KUMAR'));
    expect(xml, contains('2019-2020 to 2026-2027'));
    expect(xml, contains('St. Mary Nursery'));
    expect(xml, isNot(contains('{')));
  });
}
