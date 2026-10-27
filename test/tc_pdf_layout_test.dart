import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/tc_pdf.dart';

void main() {
  test('PDF layout survives a save/load round trip', () {
    final l = TcPdfLayout(background: false, fields: [
      TcPdfField(key: 'Student Name', x: 120.04, y: 200, w: 250, size: 12, bold: true),
      TcPdfField(key: 'TC No', page: 1, x: 10, y: 20, align: 'right'),
      TcPdfField(key: 'Student Name', x: 300, y: 600),
    ]);
    final back = TcPdfLayout.fromJson(l.toJson());
    expect(back.background, isFalse);
    expect(back.fields.length, 3);
    expect(back.fields.first.x, 120.0);
    expect(back.fields.first.bold, isTrue);
    expect(back.fields[1].page, 1);
    expect(back.fields[1].align, 'right');
    expect(back.keys, ['Student Name', 'TC No']);
  });

  test('missing or empty layout gives an empty layout that prints the background', () {
    final l = TcPdfLayout.fromJson(null);
    expect(l.background, isTrue);
    expect(l.fields, isEmpty);
  });
}
