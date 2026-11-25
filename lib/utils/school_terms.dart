import '../services/supabase_service.dart';

/// School wording and scope.
///
/// The app is built on the college model: a COURSE (B.E-CSE) holds CLASSES
/// (B.E-CSE-I ...). On the school database the same tables mean a STANDARD
/// (LKG, I, II ...) holding SECTIONS (I A, I B ...) -- see
/// school_standard_section_bridge.sql -- and admission type, quota and batch
/// do not exist at all.
///
/// Everything here is a no-op on the college database, so a single build
/// serves both.
bool get isSchool => SupabaseService.isSchoolLayout;

// ── gender wording ───────────────────────────────────────────────────────────
// Stored as a code (M / F / T or O). Shown as Boy / Girl on the school database
// (user, 2026-10-30: "male to boy female to girl"), Male / Female on a college.
// The TC certificate keeps Male / Female (tc_fields.dart): it is an official
// document.

/// "Boy" (school) / "Male" (college).
String get kBoyLabel => isSchool ? 'Boy' : 'Male';

/// "Girl" (school) / "Female" (college).
String get kGirlLabel => isSchool ? 'Girl' : 'Female';

/// Gender as shown for a stored code (or an old word): M -> Boy, F -> Girl,
/// T / O -> Other; anything else is shown as it is ('' stays '').
String genderLabel(Object? code) {
  final g = '${code ?? ''}'.trim();
  switch (g.toUpperCase()) {
    case 'M':
    case 'MALE':
    case 'BOY':
      return kBoyLabel;
    case 'F':
    case 'FEMALE':
    case 'GIRL':
      return kGirlLabel;
    case 'T':
    case 'O':
    case 'OTHER':
      return 'Other';
    default:
      return g;
  }
}

/// [genderLabel] by another name, for code that has its own `genderLabel`
/// (a model getter or a local variable) hiding this one.
String genderLabelOf(Object? code) => genderLabel(code);

/// The stored code for a shown gender (either wording): Boy/Male -> M,
/// Girl/Female -> F, Other -> [other]; null when blank or unknown.
String? genderCode(String? label, {String other = 'T'}) {
  switch ((label ?? '').trim().toUpperCase()) {
    case 'M':
    case 'MALE':
    case 'BOY':
      return 'M';
    case 'F':
    case 'FEMALE':
    case 'GIRL':
      return 'F';
    case 'T':
    case 'O':
    case 'OTHER':
      return other;
    default:
      return null;
  }
}

const Map<String, String> _schoolWords = {
  'Course': 'Standard', 'Courses': 'Standards',
  'COURSE': 'STANDARD', 'COURSES': 'STANDARDS',
  'course': 'standard', 'courses': 'standards',
  'Class': 'Section', 'Classes': 'Sections',
  'CLASS': 'SECTION', 'CLASSES': 'SECTIONS',
  'class': 'section', 'classes': 'sections',
  'Semester': 'Term', 'Semesters': 'Terms',
  'SEMESTER': 'TERM', 'SEMESTERS': 'TERMS',
  'semester': 'term', 'semesters': 'terms',
};

final RegExp _wordRe = RegExp(r'\b(Courses|Course|COURSES|COURSE|courses|course|Classes|Class|CLASSES|CLASS|classes|class|Semesters|Semester|SEMESTERS|SEMESTER|semesters|semester)\b');

/// Display text in the institution's own terms: on a school, Course ->
/// Standard, Class -> Section and Semester -> Term (whole words, case kept).
/// Import matchers already accept "Term" for a semester column, so there is
/// deliberately no Term -> Semester mapping in [collegeTerm]. Use it ONLY on text
/// a person reads -- never on keys, column names, or headers that are matched
/// against an imported file.
String schoolTerm(String text) {
  if (!isSchool) return text;
  String keepCase(String s, String out) =>
      s == s.toUpperCase() ? out.toUpperCase() : (s == s.toLowerCase() ? out.toLowerCase() : out);
  // EMIS is the school's student id, entered together with the APAAR ID; a
  // school has no UMIS (university) number.
  var t = text.replaceAllMapped(_emisUmisRe, (m) => keepCase(m.group(0)!, 'EMIS / APAAR ID'));
  t = t.replaceAllMapped(_emisNoRe, (m) => keepCase(m.group(0)!, 'EMIS No. / APAAR ID'));
  t = t.replaceAllMapped(_seqRe, (m) {
    final s = m.group(0)!;
    return keepCase(s, s.toLowerCase().endsWith('s') ? 'Admission No. Sequences' : 'Admission No. Sequence');
  });
  t = t.replaceAllMapped(_numberRe, (m) {
    final s = m.group(0)!;
    final low = s.toLowerCase();
    // Always the full "Admission No." ("... Numbers" -> plural). The dot is
    // left off when the text already follows with ':' or '.'.
    if (low.endsWith('numbers')) return keepCase(s, 'Admission Numbers');
    final next = m.end < m.input.length ? m.input[m.end] : '';
    return keepCase(s, next == ':' || next == '.' ? 'Admission No' : 'Admission No.');
  });
  // the long menu / tab name does not fit the sidebar or a card header
  t = t.replaceAll(RegExp(r'Advance Fee Receipt No\.?'), 'Advance Receipt No.');
  t = t.replaceAll('Advance Fee Definition', 'Advance Fee Demand');
  // A school imports only OPTIONAL fees there (user, 2026-11-17).
  t = t.replaceAll('Fee Demand Import', 'Optional Fee Import');
  return t.replaceAllMapped(_wordRe, (m) => _schoolWords[m.group(0)!] ?? m.group(0)!);
}

/// The college's register / roll number is a school's ADMISSION number:
/// Reg No, Reg. No, RegNo, Roll No, Register No/Number, Registration No,
/// Roll Number ... -> Admission No.; Roll/Register Numbers -> Admission
/// Numbers.
final RegExp _numberRe = RegExp(
    r'\b(?:Registration|Register|Reg\.?|Roll)\s?(?:No\.?|Numbers?)(?![A-Za-z])',
    caseSensitive: false);

/// "EMIS / UMIS" (menu, screen) and "EMIS No" (field). The look-aheads keep an
/// already converted label from growing a second "/ APAAR ID".
final RegExp _emisUmisRe = RegExp(r'\bEMIS\s*/\s*UMIS\b', caseSensitive: false);
final RegExp _emisNoRe = RegExp(r'\bEMIS\s?No\.?(?!\s*/\s*APAAR)', caseSensitive: false);

/// The register-number sequence is the admission-number sequence.
final RegExp _seqRe = RegExp(r'\bRegister\s+Sequences?\b', caseSensitive: false);

const Map<String, String> _collegeWords = {
  'Standard': 'Course', 'Standards': 'Courses',
  'STANDARD': 'COURSE', 'STANDARDS': 'COURSES',
  'standard': 'course', 'standards': 'courses',
  'Section': 'Class', 'Sections': 'Classes',
  'SECTION': 'CLASS', 'SECTIONS': 'CLASSES',
  'section': 'class', 'sections': 'classes',
};

final RegExp _schoolWordRe = RegExp(r'(?<![A-Za-z])(Standards|Standard|STANDARDS|STANDARD|standards|standard|Sections|Section|SECTIONS|SECTION|sections|section)(?![A-Za-z])');

/// The reverse of [schoolTerm], for reading a file back: on a school, a
/// column headed "Standard" / "Section *" / "Section Id" is matched as if it
/// said "Course" / "Class *" / "Class Id", so templates downloaded in school
/// wording -- and the old Course/Class ones -- both import. No-op on college.
/// Unlike [schoolTerm], words glued by "_" ("section_id") are mapped too.
String collegeTerm(String header) {
  if (!isSchool) return header;
  return header.replaceAllMapped(_schoolWordRe, (m) => _collegeWords[m.group(0)!] ?? m.group(0)!);
}

/// School EMIS No. / APAAR ID: exactly 12 digits. (The college's EMIS / UMIS
/// keep their own, looser rule.)
const int kSchoolEmisLength = 12;
final RegExp _emisRe = RegExp(r'^\d{12}$');

/// Longest number the EMIS field accepts.
int get emisMaxLength => isSchool ? kSchoolEmisLength : 30;

/// True for a filled school EMIS No. that is not exactly 12 digits (blank is
/// allowed -- the field is optional).
bool emisInvalid(String v) {
  final t = v.trim();
  return isSchool && t.isNotEmpty && !_emisRe.hasMatch(t);
}

const String kEmisRuleMsg = 'EMIS No. / APAAR ID must be exactly 12 digits';

/// Sidebar sub-items that do not exist for a school (keys, not display text).
const Set<String> kSchoolHiddenSubItems = {'Admission Type', 'Quota'};

/// Sidebar menu items a school does not use (Advance Fee Collection takes
/// the place of Advance Collection there; Advance Reconciliation Report
/// replaces the Advance Register).
const Set<String> kSchoolHiddenNavItems = {
  'Advance Collection',
  // replaced on a school by the old-format reports
  'Advance Register', // -> Advance Reconciliation Report
  'Pending Payment', 'Pending Details', // -> Pending Fee Report
  // Fee Demand Import was hidden here on 2026-11-13 and is back in Fees for a
  // school too (user, 2026-11-17).
};

/// Sidebar sub-items that only a school has.
const Set<String> kCollegeHiddenSubItems = {'Arrear Receipt No', 'Misc Receipt No', 'Concession Approval', 'Class Matching', 'Advance Fee Definition', 'Advance Fee Collection', 'Advance Fee Receipt No', 'Year End Process', 'Consolidated Summary', 'Receiptwise Report', 'Division Summary', 'Fee Matrix', 'Pending Fee Report', 'Advance Reconciliation Report', 'TC Certificate', 'TC Approval', 'TC Print', 'TC Format', 'Receipt Format', 'Allot Section', 'Transport Setup', 'Routes & Stops', 'Vehicles', 'Transport Staff', 'Trip Schedules', 'Duty Roster', 'Student Enrollment', 'Vehicle Allotment', 'Stage Fees', 'Staff', 'Attendance Entry', 'Leave & Out-pass', 'Attendance Report', 'Attendance Setup'};
