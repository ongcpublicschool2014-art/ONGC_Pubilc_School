import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/medium_options.dart';

/// A student's Medium comes from Setup -> Master Data -> Medium, English by
/// default (user, 2026-11-24).
void main() {
  test('a new student gets English, in the list\'s own spelling', () {
    expect(defaultMedium(['TAMIL', 'English']), 'English');
    expect(defaultMedium(['Tamil', 'English Medium']), 'English Medium');
    expect(defaultMedium(['TAMIL']), kDefaultMedium, reason: 'English even when the list has none');
    expect(defaultMedium([]), 'ENGLISH');
  });

  test('a saved medium is shown in the list\'s spelling, or kept as it is', () {
    expect(matchMedium(['English', 'Tamil'], 'ENGLISH '), 'English');
    expect(matchMedium(['Tamil'], 'ENGLISH'), 'ENGLISH');
    expect(matchMedium(['Tamil'], '  '), isNull);
    expect(matchMedium(['Tamil'], null), isNull);
  });

  test('an older record keeps its medium in the dropdown', () {
    expect(mediumItems([], 'ENGLISH'), ['ENGLISH'], reason: 'an empty list must not clear it');
    expect(mediumItems(['Tamil'], 'ENGLISH'), ['Tamil', 'ENGLISH']);
    expect(mediumItems(['English', 'Tamil'], 'English'), ['English', 'Tamil'], reason: 'not twice');
    expect(mediumItems(['Tamil'], null), ['Tamil']);
  });

  test('medium rows: trimmed, blanks and repeats left out, order kept', () {
    expect(
      mediumNames([
        {'medname': ' ENGLISH '},
        {'medname': 'Tamil'},
        {'medname': ''},
        {'medname': null},
        {'medname': 'english'},
      ]),
      ['ENGLISH', 'Tamil'],
    );
  });
}
