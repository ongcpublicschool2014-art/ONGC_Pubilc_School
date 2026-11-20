import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/tc_docx.dart';
import 'package:school_admin/utils/tc_fields.dart';

/// The client schools' TC formats (Immaculate X / XII, VES): every
/// {placeholder} must be a field the app fills or asks for, and the blank
/// versions must have none left.
void main() {
  final known = {...kTcFieldKeys, ...kTcPrintTimeKeys};
  final formats = {
    'Immaculate X': TcClientFormats.immaculate(higherSecondary: false),
    'Immaculate XII': TcClientFormats.immaculate(higherSecondary: true),
    'VES': TcClientFormats.ves(),
  };

  for (final e in formats.entries) {
    test('${e.key}: every placeholder is a known field', () {
      final ph = TcDocx.placeholders(e.value);
      expect(ph, isNotEmpty);
      expect(ph.where((k) => !known.contains(k)).toList(), isEmpty);
    });

    test('${e.key}: fills with values', () {
      final filled = TcDocx.fill(e.value, [
        {for (final k in TcDocx.placeholders(e.value)) k: 'V-$k'},
      ]);
      expect(TcDocx.placeholders(filled), isEmpty);
    });
  }

  test('blank versions have no placeholders', () {
    for (final b in [
      TcClientFormats.immaculate(higherSecondary: false, blank: true),
      TcClientFormats.immaculate(higherSecondary: true, blank: true),
      TcClientFormats.ves(blank: true),
    ]) {
      expect(TcDocx.placeholders(b), isEmpty);
    }
  });
}
