import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/save_path.dart';

void main() {
  const x = ['xlsx'];
  test('keeps a correct name', () {
    expect(withExtension(r'C:\a\student_import_template.xlsx', x), r'C:\a\student_import_template.xlsx');
    expect(withExtension(r'C:\a\My Template.XLSX', x), r'C:\a\My Template.XLSX');
  });
  test('adds the extension when it was removed', () {
    expect(withExtension(r'C:\a\students', x), r'C:\a\students.xlsx');
    expect(withExtension(r'C:\a\students 2026', x), r'C:\a\students 2026.xlsx');
  });
  test('the dot deleted', () {
    expect(withExtension(r'C:\a\student_import_templatexlsx', x), r'C:\a\student_import_template.xlsx');
  });
  test('trailing dot', () {
    expect(withExtension(r'C:\a\students.', x), r'C:\a\students.xlsx');
  });
  test('pdf and csv', () {
    expect(withExtension(r'C:\a\receipt', ['pdf']), r'C:\a\receipt.pdf');
    expect(withExtension(r'C:\a\list.csv', ['csv']), r'C:\a\list.csv');
  });
  test('no allowed list: from the suggested name', () {
    expect(withExtension(r'C:\a\report', null, 'report.xlsx'), r'C:\a\report.xlsx');
  });
}
