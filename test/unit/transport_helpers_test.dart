import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/transport/transport_master_panel.dart';
import 'package:school_admin/widgets/app_ui.dart';

void main() {
  group('trNumberText', () {
    test('drops a meaningless decimal', () {
      expect(trNumberText(5000.0), '5000');
      expect(trNumberText(5000), '5000');
    });
    test('keeps a real decimal', () => expect(trNumberText(12.5), '12.5'));
    test('blank for null', () => expect(trNumberText(null), ''));
  });

  group('trFileName', () {
    const base = 'https://x.supabase.co/storage/v1/object/public/InstitutionLogos/transport';
    test('shows the original name after the upload stamp', () {
      expect(trFileName('$base/vehicle-docs/1731300000000000_RC_Book.pdf'), 'RC_Book.pdf');
    });
    test('decodes an encoded name', () => expect(trFileName('$base/staff-docs/1731300000000000_Licence%20Front.jpg'), 'Licence Front.jpg'));
    test('a photo keeps its stamp name', () => expect(trFileName('$base/staff/1731300000000000.jpg'), '1731300000000000.jpg'));
  });

  group('trExpiryStatus', () {
    final today = DateTime(2026, 11, 6);
    test('no date', () => expect(trExpiryStatus(null, today: today).$2, AppStatus.neutral));
    test('yesterday is expired', () => expect(trExpiryStatus('2026-11-05', today: today).$2, AppStatus.danger));
    test('today still counts as valid with 0 days left', () {
      final s = trExpiryStatus('2026-11-06', today: today);
      expect(s.$1, '0 Days Left');
      expect(s.$2, AppStatus.warning);
    });
    test('the last warning day warns', () => expect(trExpiryStatus('2026-12-06', today: today).$2, AppStatus.warning));
    test('after the warning period is valid', () => expect(trExpiryStatus('2026-12-07', today: today).$2, AppStatus.success));
    test('honours the school\'s warning days', () => expect(trExpiryStatus('2026-12-07', warnDays: 60, today: today).$2, AppStatus.warning));
  });

  group('times and run days', () {
    test('a server time becomes HH:MM', () {
      expect(trTimeValue('07:05:00'), '07:05');
      expect(trTimeValue('7:05'), '07:05');
      expect(trTimeValue(null), isNull);
      expect(trTimeValue('soon'), isNull);
    });
    test('a time reads on the 12-hour clock', () {
      expect(trTimeText('07:05:00'), '7:05 AM');
      expect(trTimeText('12:30'), '12:30 PM');
      expect(trTimeText('00:15'), '12:15 AM');
      expect(trTimeText('15:45'), '3:45 PM');
      expect(trTimeText(null), '');
    });
    test('minutes after midnight and back', () {
      expect(trMinutes('07:05:00'), 425);
      expect(trHhmm(425), '07:05');
      expect(trHhmm(0), '00:00');
    });
    test('run days are sorted, each once, Monday to Sunday only', () {
      expect(trDayList([3, 1, 1, 9, 0, '2']), [1, 2, 3]);
      expect(trDayList(null), isEmpty);
    });
    test('run days read as a range or a list', () {
      expect(trDaysText([1, 2, 3, 4, 5, 6]), 'Mon–Sat');
      expect(trDaysText([1, 2, 3, 4, 5]), 'Mon–Fri');
      expect(trDaysText([1, 3, 5]), 'Mon, Wed, Fri');
      expect(trDaysText([6, 7]), 'Sat, Sun');
      expect(trDaysText([1, 2, 3, 4, 5, 6, 7]), 'Every day');
      expect(trDaysText(const []), '-');
    });
  });

  group('TrFormBody.collect', () {
    Future<GlobalKey<TrFormBodyState>> pump(WidgetTester t, List<TrField> fields, Map<String, dynamic> initial) async {
      final key = GlobalKey<TrFormBodyState>();
      await t.binding.setSurfaceSize(const Size(1400, 900));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: TrFormBody(key: key, fields: fields, initial: initial))),
        ),
      ));
      await t.pump();
      return key;
    }

    testWidgets('a missing required field stops the save', (t) async {
      final k = await pump(t, const [TrField('route_code', 'Route Code', required: true)], const {});
      expect(k.currentState!.collect(), isNull);
      await t.pump();
      expect(find.text('Enter the route code.'), findsOneWidget);
    });

    testWidgets('amounts stay as typed, so they are never rounded', (t) async {
      final k = await pump(t, const [TrField('amount', 'Amount', kind: TrKind.decimal)], const {'amount': 1234.5});
      expect(k.currentState!.collect(), {'amount': '1234.5'});
    });

    testWidgets('a bad mobile number is refused', (t) async {
      final k = await pump(t, const [TrField('mobile', 'Mobile', kind: TrKind.mobile)], const {'mobile': '123'});
      expect(k.currentState!.collect(), isNull);
    });

    testWidgets('blank optional text is saved as empty', (t) async {
      final k = await pump(t, const [TrField('landmark', 'Landmark')], const {});
      expect(k.currentState!.collect(), {'landmark': null});
    });

    testWidgets('a hidden field is cleared and its required rule skipped', (t) async {
      final k = await pump(t, [
        const TrField('ownership_type', 'Ownership', kind: TrKind.choice, options: [('OWNED', 'Owned'), ('HIRED', 'Hired')]),
        TrField('vendor_id', 'Vendor', kind: TrKind.choice, required: true, options: const [(5, 'Sri Travels')], visibleWhen: (v) => v['ownership_type'] != 'OWNED'),
      ], const {'ownership_type': 'OWNED', 'vendor_id': 5});
      expect(k.currentState!.collect(), {'ownership_type': 'OWNED', 'vendor_id': null});
    });

    testWidgets('a visible required choice must be chosen', (t) async {
      final k = await pump(t, [
        TrField('vendor_id', 'Vendor', kind: TrKind.choice, required: true, options: const [(5, 'Sri Travels')], visibleWhen: (v) => v['ownership_type'] != 'OWNED'),
      ], const {'ownership_type': 'HIRED'});
      expect(k.currentState!.collect(), isNull);
    });

    testWidgets('every kind of field draws, with and without a hint', (t) async {
      final k = await pump(t, const [
        TrField('a', 'Text', hint: 'e.g. R5', section: 'First'),
        TrField('b', 'Upper', kind: TrKind.upper, hint: 'e.g. BUS-07'),
        TrField('c', 'Whole', kind: TrKind.integer),
        TrField('d', 'Decimal', kind: TrKind.decimal, hint: 'e.g. 13.0827', section: 'Second'),
        TrField('e', 'Mobile', kind: TrKind.mobile),
        TrField('f', 'Date', kind: TrKind.date),
        TrField('g', 'Toggle', kind: TrKind.toggle),
        TrField('h', 'Choice', kind: TrKind.choice, options: [('X', 'Ex')]),
        TrField('i', 'Choice With Hint', kind: TrKind.choice, hint: 'Pick one', options: [('X', 'Ex')]),
        TrField('j', 'Notes', kind: TrKind.multiline, full: true),
      ], const {'h': 'X', 'f': '2027-01-02', 'g': true});
      expect(t.takeException(), isNull);
      expect(find.text('FIRST'), findsOneWidget);
      expect(find.text('02-01-2027'), findsOneWidget);
      expect(k.currentState!.collect()!['g'], true);
    });

    testWidgets('a date keeps only its YYYY-MM-DD part', (t) async {
      final k = await pump(t, const [TrField('expiry_date', 'Expiry', kind: TrKind.date)], const {'expiry_date': '2027-03-31T00:00:00'});
      expect(k.currentState!.collect(), {'expiry_date': '2027-03-31'});
    });

    testWidgets('a time keeps HH:MM, and run days stay a sorted list', (t) async {
      final k = await pump(t, const [
        TrField('planned_start', 'Start Time', kind: TrKind.time, required: true),
        TrField('run_days', 'Run Days', kind: TrKind.days, required: true),
      ], const {
        'planned_start': '07:05:00',
        'run_days': [3, 1, 2],
      });
      expect(t.takeException(), isNull);
      expect(find.text('7:05 AM'), findsOneWidget);
      expect(k.currentState!.collect(), {
        'planned_start': '07:05',
        'run_days': [1, 2, 3],
      });
    });

    testWidgets('a required time, or run days, must be set', (t) async {
      final k = await pump(t, const [TrField('planned_start', 'Start Time', kind: TrKind.time, required: true)], const {});
      expect(k.currentState!.collect(), isNull);
      await t.pump();
      expect(find.text('Select the start time.'), findsOneWidget);
      final d = await pump(t, const [TrField('run_days', 'Run Days', kind: TrKind.days, required: true)], const {'run_days': []});
      expect(d.currentState!.collect(), isNull);
    });

    testWidgets('tapping a day switches it, and onChanged hears it', (t) async {
      final key = GlobalKey<TrFormBodyState>();
      Map<String, dynamic>? seen;
      await t.binding.setSurfaceSize(const Size(1400, 900));
      await t.pumpWidget(ScreenUtilInit(
        designSize: const Size(1750, 984),
        builder: (_, __) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TrFormBody(
                key: key,
                fields: const [TrField('run_days', 'Run Days', kind: TrKind.days)],
                initial: const {
                  'run_days': [1],
                },
                onChanged: (v) => seen = v,
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('Wed'));
      await t.pump();
      await t.tap(find.text('Mon'));
      await t.pump();
      expect(seen?['run_days'], [3]);
      expect(key.currentState!.collect(), {
        'run_days': [3],
      });
    });

    // The Fuel tab's Fuel: shown from the chosen vehicle, never saved.
    final fuelOf = {1: 'Diesel', 2: 'Electric'};
    List<TrField> fuelFields() => [
          const TrField('vehicle_id', 'Vehicle', kind: TrKind.choice, options: [(1, 'BUS-01'), (2, 'VAN-02')]),
          TrField('vehicle_fuel', 'Fuel', kind: TrKind.display, hint: 'Choose the vehicle', displayFor: (v) => fuelOf[v['vehicle_id']] ?? ''),
        ];

    testWidgets('a display field shows its value, follows the choice, and is never saved', (t) async {
      final k = await pump(t, fuelFields(), const {'vehicle_id': 1});
      expect(t.takeException(), isNull);
      expect(find.text('Diesel'), findsOneWidget);
      expect(k.currentState!.collect(), {'vehicle_id': 1});
      await t.tap(find.text('BUS-01'));
      await t.pumpAndSettle();
      await t.tap(find.text('VAN-02').last);
      await t.pumpAndSettle();
      expect(find.text('Electric'), findsOneWidget);
      expect(find.text('Diesel'), findsNothing);
      expect(k.currentState!.collect(), {'vehicle_id': 2});
    });

    testWidgets('a display field with nothing to show shows its hint', (t) async {
      final k = await pump(t, fuelFields(), const {});
      expect(find.text('Choose the vehicle'), findsOneWidget);
      expect(k.currentState!.collect(), {'vehicle_id': null});
    });
  });
}
