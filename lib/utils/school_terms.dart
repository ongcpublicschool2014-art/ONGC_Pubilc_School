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
  t = t.replaceAllMapped(_emisNoRe, (m) => keepCase(m.group(0)!, 'EMIS No / APAAR ID'));
  t = t.replaceAllMapped(_seqRe, (m) {
    final s = m.group(0)!;
    return keepCase(s, s.toLowerCase().endsWith('s') ? 'Admission No Sequences' : 'Admission No Sequence');
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
  t = t.replaceAll('Advance Fee Receipt No', 'Advance Receipt No');
  t = t.replaceAll('Advance Fee Definition', 'Advance Fee Demand');
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

/// Sidebar sub-items that do not exist for a school (keys, not display text).
const Set<String> kSchoolHiddenSubItems = {'Admission Type', 'Quota'};

/// Sidebar menu items a school does not use (Advance Fee Collection takes
/// the place of Advance Collection there).
const Set<String> kSchoolHiddenNavItems = {'Advance Collection'};

/// Sidebar sub-items that only a school has.
const Set<String> kCollegeHiddenSubItems = {'Class Matching', 'Advance Fee Definition', 'Advance Fee Collection', 'Advance Fee Receipt No', 'Year End Process', 'Consolidated Summary', 'TC Certificate', 'TC Approval', 'TC Print', 'TC Format'};
