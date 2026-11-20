import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/student_import_rules.dart';

/// Student Import: one parent with name + mobile, and Payment In Charge +
/// Payment Mobile, are mandatory on every row.
void main() {
  Map<String, String> check(Map<String, String> row) =>
      importParentPayErrors((k) => (row[k] ?? '').trim().isEmpty ? null : row[k]!.trim());

  const pay = {'payincharge': 'B.ASHOKKUMAR', 'payinchargemob': '9094936278'};

  test('father name + mobile and payment in charge: passes', () {
    expect(check({'fathername': 'B.ASHOKKUMAR', 'fathermobile': '9094936278', ...pay}), isEmpty);
  });

  test('mother only (name + mobile) with payment in charge: passes', () {
    expect(check({'mothername': 'A.SANGEETHA', 'mothermobile': '9876543210', ...pay}), isEmpty);
  });

  test('guardian only (name + mobile) with payment in charge: passes', () {
    expect(check({'guardianname': 'R.KUMAR', 'guardianmobile': '9876543210', ...pay}), isEmpty);
  });

  test('father name but no mobile (old import data): fails on Father Mobile', () {
    final e = check({'fathername': 'B.ASHOKKUMAR', 'mothername': 'A.SANGEETHA', ...pay});
    expect(e.keys, containsAll(['fathermobile', 'mothermobile']));
    expect(e.containsKey('fathername'), isFalse);
    expect(e.containsKey('payincharge'), isFalse);
  });

  test('no parent at all: marks Father Name and Father Mobile', () {
    final e = check({...pay});
    expect(e.keys.toSet(), {'fathername', 'fathermobile'});
  });

  test('parent complete but Payment In Charge missing: fails on both pay cells', () {
    final e = check({'fathername': 'B.ASHOKKUMAR', 'fathermobile': '9094936278'});
    expect(e.keys.toSet(), {'payincharge', 'payinchargemob'});
  });

  test('Payment Mobile missing only', () {
    final e = check({'fathername': 'B.ASHOKKUMAR', 'fathermobile': '9094936278', 'payincharge': 'B.ASHOKKUMAR'});
    expect(e.keys.toSet(), {'payinchargemob'});
  });

  test('blank / spaces count as empty', () {
    final e = check({'fathername': '  ', 'fathermobile': '9094936278', 'payincharge': ' ', 'payinchargemob': '9094936278'});
    expect(e.keys.toSet(), {'fathername', 'payincharge'});
  });

  test('empty row: parent and payment errors together', () {
    expect(check({}).keys.toSet(), {'fathername', 'fathermobile', 'payincharge', 'payinchargemob'});
  });
}
