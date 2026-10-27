import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/formatters.dart';

void main() {
  group('formatDate', () {
    test('ISO date string', () {
      expect(formatDate('2026-04-01'), '01-04-2026');
    });

    test('ISO with timestamp', () {
      expect(formatDate('2026-04-01T10:30:00Z'), '01-04-2026');
    });

    test('null returns dash', () {
      expect(formatDate(null), '-');
    });

    test('empty returns dash', () {
      expect(formatDate(''), '-');
    });

    test('unparseable returns raw', () {
      expect(formatDate('not a date'), 'not a date');
    });

    test('zero-pads day and month for parseable input', () {
      // DateTime.parse already requires zero-padded ISO dates, so an
      // unpadded value falls through to the raw-string branch. The format
      // step itself zero-pads single-digit values that came from a parsed
      // DateTime — verify via a full ISO datetime with month=1, day=5.
      expect(formatDate('2026-01-05T00:00:00Z'), '05-01-2026');
    });
  });
}
