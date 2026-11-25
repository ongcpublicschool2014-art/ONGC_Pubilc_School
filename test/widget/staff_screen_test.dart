import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/admin/staff_screen.dart';

/// Staff Details (redesign 2026-11-23): the experience length shown while
/// typing must be the one the server stores (_staff_exp_length), and the
/// profile page has to lay out at the school PCs' sizes.
void main() {
  group('experience length = the server\'s _staff_exp_length', () {
    // values read from public._staff_exp_length on the test database
    const cases = {
      ('2020-06-01', '2021-05-31'): '1 Year',
      ('2019-01-15', '2020-03-14'): '1 Year 2 Months',
      ('2008-06-01', '2012-05-15'): '3 Years 11 Months',
      ('2005-06-01', '2008-05-31'): '3 Years',
      ('2019-01-31', '2019-02-28'): '1 Month',
      ('2020-01-31', '2020-03-01'): '1 Month',
      ('2016-02-29', '2017-02-27'): '11 Months',
      ('2010-06-15', '2011-06-13'): '11 Months',
      ('2020-06-01', '2020-06-10'): '',
    };
    cases.forEach((k, want) {
      test('${k.$1} to ${k.$2} -> "$want"', () {
        final m = staffMonths(k.$1, k.$2);
        expect(m, isNotNull);
        expect(staffSpanText(m!), want);
      });
    });

    test('a missing date or a To before From gives nothing', () {
      expect(staffMonths(null, '2020-01-01'), isNull);
      expect(staffMonths('2020-01-01', ''), isNull);
      expect(staffMonths('2021-01-01', '2020-01-01'), isNull);
    });
  });

  test('avatar initials', () {
    expect(staffInitials('Lakshmi Narayanan R'), 'LN');
    expect(staffInitials('meena'), 'M');
    expect(staffInitials('  '), '?');
  });

  // Admission Entry's rules, and the students' / parents' app password
  // (the server checks the same in staff_save).
  test('mobile, phone and e-mail rules', () {
    expect(staffMobileProblem('9840011001'), isNull);
    for (final bad in ['984001100534444', '5840011001', '9999999999', '98400110']) {
      expect(staffMobileProblem(bad), isNotNull, reason: bad);
    }
    expect(staffPhoneProblem('0436822233'), isNull, reason: '10 digits');
    expect(staffPhoneProblem('04368222333'), isNotNull, reason: '11 digits');
    expect(staffPhoneProblem('0436'), isNotNull);
    expect(staffEmailProblem('meena.t@example.com'), isNull);
    expect(staffEmailProblem('meena.t@example'), isNotNull);
  });

  test('password rules = the mobile app Set Password', () {
    expect(staffPasswordProblem('Staff@2026'), isNull);
    expect(staffPasswordProblem('Abcdefg1'), isNull);
    for (final bad in ['Abc1', 'abcdefg1', 'ABCDEFG1', 'Abcdefgh']) {
      expect(staffPasswordProblem(bad), isNotNull, reason: bad);
    }
  });

  test('suggestions: the school\'s own spelling first, defaults after, A-Z', () {
    expect(staffSuggestions(['HINDU', 'Christian', ' '], ['Hindu', 'Muslim']), ['Christian', 'HINDU', 'Muslim']);
  });

  Future<void> open(WidgetTester t, Size size, Map<String, dynamic>? staff) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScreenUtilInit(
      designSize: const Size(1750, 984),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: size.width - 240 - 280,
            height: size.height - 130,
            child: StaffProfile(
              staff: staff,
              lookups: const StaffLookups(year: '2026-2027', communities: [(1, 'BC')], designations: [(1, 'Principal'), (2, 'Teacher')]),
              onBack: () {},
              onSaved: (_) {},
            ),
          ),
        ),
      ),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  const lakshmi = {
    'staf_id': 3, 'emp_code': 'EMP001', 'stafname': 'Lakshmi Narayanan R', 'shortname': 'Lakshmi', 'gender': 'F',
    'dob': '1975-03-10', 'joindate': '2015-06-01', 'mobileno': '9840011001', 'emailid': 'lakshmi@school.in',
    'designation': 'Principal', 'transportreq': 'BUS', 'is_active': true, 'in_year': true, 'staftermin': false,
    'community_id': 1, 'has_password': false,
  };

  for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
    testWidgets('a new staff member\'s page lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      await open(t, size, null);
      expect(t.takeException(), isNull);
      expect(find.text('New Staff Member'), findsWidgets);
      expect(find.text('Personal Details'), findsOneWidget);
      expect(find.text('Experience'), findsOneWidget);
      // an experience row is added on the page itself
      await t.ensureVisible(find.byKey(const ValueKey('staff-exp-add')));
      await t.tap(find.byKey(const ValueKey('staff-exp-add')));
      await t.pump();
      expect(t.takeException(), isNull);
      // one line per school at 1920 (column heads), two lines at 1366 (field labels)
      expect(find.text(size.width >= 1900 ? 'SCHOOL NAME' : 'School Name'), findsOneWidget);
      // every date box on the page -- the experience From / To included --
      // shows a whole date (the hint is as wide as one), not "01..."
      final dates = find.text('DD-MM-YYYY');
      expect(dates, findsAtLeastNWidgets(5), reason: 'birth, joining, confirmation, From, To');
      for (final el in dates.evaluate()) {
        final p = el.renderObject! as RenderParagraph;
        expect(p.didExceedMaxLines, isFalse, reason: 'a date box at ${size.width.toInt()} is cut off');
      }
    });

    testWidgets('a staff member\'s page lays out at ${size.width.toInt()}x${size.height.toInt()}', (t) async {
      await open(t, size, lakshmi);
      expect(t.takeException(), isNull);
      expect(find.text('Lakshmi Narayanan R'), findsWidgets);
      expect(find.text('LN'), findsOneWidget);
      expect(find.text('Principal  ·  Employee Code EMP001'), findsOneWidget);
      expect(find.text('School Bus'), findsOneWidget, reason: 'transport OWN / BUS shown by name');
      expect(find.text('Delete'), findsNothing, reason: 'staff are never deleted: Relieved instead');
    });
  }

  // Designation comes from the school's Staff Designation list, with a last
  // item that adds one (user, 2026-11-23).
  testWidgets('Designation offers the Staff Designation list and Add New Designation', (t) async {
    await open(t, const Size(1920, 1080), lakshmi);
    final field = find.byKey(const ValueKey('tr-designation-Principal'));
    expect(field, findsOneWidget, reason: 'Principal is chosen');
    await t.ensureVisible(field);
    await t.tap(field);
    await t.pumpAndSettle();
    expect(find.text('Teacher'), findsWidgets);
    expect(find.text('Add New Designation'), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('Mobile No. takes digits only, at most 10', (t) async {
    await open(t, const Size(1920, 1080), lakshmi);
    final mobile = find.widgetWithText(TextField, '9840011001');
    await t.ensureVisible(mobile);
    // a full field keeps its number; an empty one takes the first 10 digits
    await t.enterText(mobile, '98400-1100534444');
    await t.pump();
    expect(find.widgetWithText(TextField, '9840011001'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, '9840011001'), '');
    await t.pump();
    final empty = find.widgetWithText(TextField, '10-digit mobile number');
    await t.enterText(empty, '98400-1100534444');
    await t.pump();
    expect(find.widgetWithText(TextField, '9840011005'), findsOneWidget);
  });

  testWidgets('Religion lists the values to pick, narrowing as it is typed', (t) async {
    await open(t, const Size(1920, 1080), {...lakshmi, 'religion': null});
    final religion = find.widgetWithText(TextField, 'Type or select a religion');
    await t.ensureVisible(religion);
    await t.tap(religion);
    await t.pumpAndSettle();
    expect(find.text('Christian'), findsOneWidget);
    expect(find.text('Hindu'), findsOneWidget);
    await t.enterText(religion, 'mus');
    await t.pumpAndSettle();
    expect(find.text('Muslim'), findsOneWidget);
    expect(find.text('Hindu'), findsNothing);
    await t.tap(find.text('Muslim'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Muslim'), findsOneWidget);
  });

  testWidgets('a weak password stops the save, with the rule', (t) async {
    await open(t, const Size(1920, 1080), lakshmi);
    final pwd = find.widgetWithText(TextField, '8+ characters, with upper- and lower-case letters and a number');
    await t.ensureVisible(pwd);
    await t.enterText(pwd, 'abc12345');
    await t.tap(find.byKey(const ValueKey('staff-save')));
    await t.pump();
    expect(find.text('The password needs at least 8 characters, with an uppercase letter, a lowercase letter and a number.'), findsOneWidget);
  });

  testWidgets('a designation saved before the list stays shown', (t) async {
    await open(t, const Size(1920, 1080), {...lakshmi, 'designation': 'Librarian'});
    expect(find.byKey(const ValueKey('tr-designation-Librarian')), findsOneWidget);
    expect(find.text('Librarian'), findsWidgets);
  });
}
