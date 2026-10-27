import 'tc_docx.dart';

/// The fields of a TC certificate -- each one is a placeholder name the
/// school's Word format can use, e.g. {Student Name}. AUTO fields fill from
/// the student / admission / TC entry when a certificate is first opened (and
/// stay editable); the rest are typed in. Whatever the template has that is
/// not listed here shows up as an extra field to type.
class TcField {
  final String key;
  final String group;
  final String Function(TcSource s)? auto;
  final String hint;
  const TcField(this.key, this.group, {this.auto, this.hint = ''});
}

/// Everything a certificate is filled from.
class TcSource {
  final Map<String, dynamic> student, admission, tc;
  final String schoolName, schoolAddress, yearLabel;
  TcSource({required this.student, required this.admission, required this.tc,
      required this.schoolName, required this.schoolAddress, required this.yearLabel});

  String a(String k) => '${admission[k] ?? student[k] ?? ''}'.trim();
  String st(String k) => '${student[k] ?? admission[k] ?? ''}'.trim();
}

String tcDate(dynamic v) {
  final d = DateTime.tryParse('${v ?? ''}');
  return d == null ? '' : '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
}

/// Academic year a date falls in (June start), e.g. 2019-2020.
String _yearOf(dynamic v) {
  final d = DateTime.tryParse('${v ?? ''}');
  if (d == null) return '';
  final y = d.month >= 6 ? d.year : d.year - 1;
  return '$y-${y + 1}';
}

String _join(List<String> parts, String sep) => parts.where((p) => p.trim().isNotEmpty).join(sep);

String _gender(String g) => switch (g.toUpperCase()) { 'M' || 'MALE' => 'Male', 'F' || 'FEMALE' => 'Female', 'T' => 'Transgender', _ => g };

/// Placeholders filled at print time, never stored.
const kTcPrintTimeKeys = {'Copy', 'Print Date'};

final List<TcField> kTcFields = [
  // school
  TcField('School Name', 'School', auto: (s) => s.schoolName),
  TcField('School Address', 'School', auto: (s) => s.schoolAddress),
  TcField('Academic Year', 'School', auto: (s) => s.yearLabel),
  TcField('Educational District', 'School', hint: 'Carried over from the last certificate'),
  TcField('Revenue District', 'School', hint: 'Carried over from the last certificate'),
  // the TC
  TcField('TC No', 'Transfer Certificate', auto: (s) => '${s.tc['tcno'] ?? ''}'),
  TcField('TC Date', 'Transfer Certificate', auto: (s) => tcDate(s.tc['tcdate'])),
  TcField('Leaving Date', 'Transfer Certificate', auto: (s) => tcDate(s.tc['effectfrom'] ?? s.tc['tcdate'])),
  TcField('Leaving Status', 'Transfer Certificate', auto: (s) => '${s.tc['statustype'] ?? ''}'),
  TcField('Date of Application', 'Transfer Certificate', hint: 'dd-mm-yyyy'),
  TcField('Date Struck Off', 'Transfer Certificate', auto: (s) => tcDate(s.tc['effectfrom'] ?? s.tc['tcdate'])),
  TcField('Reason for Leaving', 'Transfer Certificate', auto: (s) => '${s.tc['remarks'] ?? ''}'.trim().isNotEmpty ? '${s.tc['remarks']}' : '${s.tc['statustype'] ?? ''}'),
  TcField('Book No', 'Transfer Certificate'),
  // student
  TcField('Student Name', 'Student', auto: (s) => s.st('stuname')),
  TcField('Student Name (Block Letters)', 'Student', auto: (s) => s.st('stuname').toUpperCase()),
  TcField('Student Name (Tamil)', 'Student'),
  TcField('Admission No', 'Student', auto: (s) => s.st('stuadmno').isNotEmpty ? s.st('stuadmno') : s.a('admno')),
  TcField('Gender', 'Student', auto: (s) => _gender(s.st('stugender'))),
  TcField('DOB', 'Student', auto: (s) => tcDate(s.student['studob'] ?? s.admission['studob'])),
  TcField('DOB in Words', 'Student', auto: (s) {
    final d = DateTime.tryParse('${s.student['studob'] ?? s.admission['studob'] ?? ''}');
    return d == null ? '' : InWords.date(d);
  }),
  TcField('DOB in Figures and Words', 'Student', auto: (s) {
    final d = DateTime.tryParse('${s.student['studob'] ?? s.admission['studob'] ?? ''}');
    return d == null ? '' : '${tcDate(d.toIso8601String())} (${InWords.date(d)})';
  }),
  TcField('DOB as per Birth Certificate', 'Student', auto: (s) => tcDate(s.student['studob'] ?? s.admission['studob'])),
  TcField('Nationality', 'Student', auto: (s) => s.a('nationality')),
  TcField('Religion', 'Student', auto: (s) => s.a('religion')),
  TcField('Nationality and Religion', 'Student', auto: (s) => _join([s.a('nationality'), s.a('religion')], ' - ')),
  TcField('Community', 'Student', auto: (s) => s.a('community')),
  TcField('Caste', 'Student', auto: (s) => s.a('caste')),
  TcField('Community Category', 'Student', hint: 'SC / ST / BC / MBC / DNC / OC'),
  TcField('Community Certificate Note', 'Student', auto: (_) => 'Refer the Community Certificate issued by Revenue Authorities'),
  TcField('Aadhar No', 'Student', auto: (s) => s.a('aadharno')),
  TcField('EMIS No', 'Student', auto: (s) => s.a('emisno')),
  TcField('Identification Mark 1', 'Student'),
  TcField('Identification Mark 2', 'Student'),
  // parents
  TcField('Father Name', 'Parents', auto: (s) => s.a('fathername')),
  TcField('Mother Name', 'Parents', auto: (s) => s.a('mothername')),
  TcField('Guardian Name', 'Parents', auto: (s) => s.a('guardianname')),
  TcField('Father or Mother Name', 'Parents', auto: (s) => s.a('fathername').isNotEmpty ? s.a('fathername') : s.a('mothername')),
  TcField('Father Name (Tamil)', 'Parents'),
  // admission & studies
  TcField('Date of Admission', 'Admission & studies', auto: (s) => tcDate(s.admission['admdate'] ?? s.student['stuadmdate'])),
  TcField('Date of Admission in Words', 'Admission & studies', auto: (s) {
    final d = DateTime.tryParse('${s.admission['admdate'] ?? s.student['stuadmdate'] ?? ''}');
    return d == null ? '' : InWords.date(d);
  }),
  TcField('Admission Class', 'Admission & studies', auto: (s) => '${s.admission['courname'] ?? ''}'),
  TcField('Admission Standard in Words', 'Admission & studies', auto: (s) => InWords.standard('${s.admission['courname'] ?? ''}')),
  TcField('Division', 'Admission & studies', auto: (s) => s.a('division')),
  TcField('Standard', 'Admission & studies', auto: (s) => '${s.student['courname'] ?? ''}'),
  TcField('Standard in Words', 'Admission & studies', auto: (s) => InWords.standard('${s.student['courname'] ?? ''}')),
  TcField('Class', 'Admission & studies', auto: (s) => '${s.student['stuclass'] ?? ''}'),
  TcField('Medium', 'Admission & studies', auto: (s) => s.a('medium')),
  TcField('First Language', 'Admission & studies'),
  TcField('Subjects Studied', 'Admission & studies'),
  TcField('Last Exam Result', 'Admission & studies'),
  TcField('Qualified for Promotion', 'Admission & studies', auto: (_) => 'Yes'),
  TcField('Promoted Class', 'Admission & studies'),
  // course (state board / higher secondary)
  TcField('Course Offered', kTcCourseGroup, auto: (_) => 'General Education', hint: 'General Education / Vocational Education'),
  TcField('Part I Language', kTcCourseGroup),
  TcField('Part III Group A Subjects', kTcCourseGroup),
  TcField('Part III Group B Subjects', kTcCourseGroup, hint: 'Vocational education only'),
  TcField('Mark Certificate S.No', kTcCourseGroup),
  TcField('Register No', kTcCourseGroup),
  TcField('TMR Code No & Date', kTcCourseGroup),
  // course of study: row 1 = this school, row 2 = the previous school
  for (var n = 1; n <= kTcStudyRows; n++)
    for (final c in kTcStudyCols)
      TcField('Study $n ${c.$1}', kTcStudyGroup, auto: switch ((n, c.$1)) {
        (1, 'School') => (s) => s.schoolName,
        (1, 'Years') => (s) {
            final from = _yearOf(s.admission['admdate'] ?? s.student['stuadmdate']);
            return from.isEmpty || from == s.yearLabel ? s.yearLabel : '$from to ${s.yearLabel}';
          },
        (1, 'Standard') => (s) {
            final a = '${s.admission['courname'] ?? ''}', b = '${s.student['courname'] ?? ''}';
            return a.isEmpty || a == b ? b : '$a to $b';
          },
        (1, 'Medium') => (s) => s.a('medium'),
        (2, 'School') => (s) => s.a('prevschool'),
        (2, 'Standard') => (s) => s.a('prevclass'),
        _ => null,
      }),
  // attendance & fees
  TcField('Total Working Days', 'Attendance & fees'),
  TcField('Days Present', 'Attendance & fees'),
  TcField('Fees Paid Up To', 'Attendance & fees'),
  TcField('Fee Concession', 'Attendance & fees'),
  TcField('Scholarship', 'Attendance & fees'),
  TcField('Medical Inspection', 'Attendance & fees'),
  // conduct & other
  TcField('General Conduct', 'Conduct & other', auto: (_) => 'Good'),
  TcField('NCC / Scout / Guide', 'Conduct & other'),
  TcField('Extra Curricular Activities', 'Conduct & other'),
  TcField('Remarks', 'Conduct & other'),
];

final Set<String> kTcFieldKeys = {for (final f in kTcFields) f.key};

const kTcCourseGroup = 'Course (state board / Hr. Sec.)';

/// The "course of study" table of the state-board TC: up to [kTcStudyRows]
/// schools, placeholders {Study 1 School}, {Study 1 Years} ...
const kTcStudyGroup = 'Course of study';
const kTcStudyRows = 5;
const List<(String, String)> kTcStudyCols = [
  ('School', 'Name of the school'),
  ('Years', 'Academic year(s)'),
  ('Standard', 'Standard(s) studied'),
  ('Language', 'First language'),
  ('Medium', 'Medium of instruction'),
];

/// School-level typed fields: a new certificate starts with the value from
/// the last saved one.
const kTcCarryKeys = {'Educational District', 'Revenue District'};

/// Lines of the downloadable sample format (label, placeholder) -- CBSE order.
const List<(String, String)> kTcSampleLines = [
  ('Name of the Pupil', 'Student Name'),
  ("Mother's Name", 'Mother Name'),
  ("Father's / Guardian's Name", 'Father Name'),
  ('Date of Birth (in figures)', 'DOB'),
  ('Date of Birth (in words)', 'DOB in Words'),
  ('Nationality', 'Nationality'),
  ('Religion / Community', 'Community'),
  ('Date of first admission in the school with class', 'Date of Admission'),
  ('Class in which the pupil last studied', 'Standard'),
  ('School / Board examination last taken with result', 'Last Exam Result'),
  ('Subjects studied', 'Subjects Studied'),
  ('Whether qualified for promotion to the higher class', 'Qualified for Promotion'),
  ('If so, to which class', 'Promoted Class'),
  ('Month up to which the school dues paid', 'Fees Paid Up To'),
  ('Any fee concession availed of', 'Fee Concession'),
  ('Total number of working days', 'Total Working Days'),
  ('Total number of working days present', 'Days Present'),
  ('NCC Cadet / Boy Scout / Girl Guide', 'NCC / Scout / Guide'),
  ('Games played or extra-curricular activities', 'Extra Curricular Activities'),
  ('General conduct', 'General Conduct'),
  ('Date of application for certificate', 'Date of Application'),
  ('Date of issue of certificate', 'TC Date'),
  ('Reason for leaving the school', 'Reason for Leaving'),
  ('Any other remarks', 'Remarks'),
];
