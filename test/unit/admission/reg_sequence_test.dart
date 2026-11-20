import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/reg_sequence.dart';

void main() {
  Map<String, dynamic> s(int id, String name, String? division) =>
      {'seq_id': id, 'seqname': name, 'division': division};

  final general = s(2, 'ADM', null);
  final kg = s(20, 'KINDER GARDEN', 'KINDER GARDEN');
  final primary = s(21, 'PRIMARY', 'PRIMARY');
  final all = [general, kg, primary];

  group('regSeqDivisionWise', () {
    test('false when no sequence has a division', () {
      expect(regSeqDivisionWise([general, s(3, 'OLD', '  ')]), isFalse);
    });
    test('true when one sequence has a division', () => expect(regSeqDivisionWise(all), isTrue));
  });

  group('regSeqFor', () {
    test('takes the division\'s own sequence', () {
      final c = regSeqFor(all, 'PRIMARY');
      expect(c.seq, primary);
      expect(c.notice, isNull);
      expect(c.blocked, isFalse);
    });
    test('ignores case and spaces', () => expect(regSeqFor(all, ' kinder garden ').seq, kg));
    test('never takes another division\'s sequence', () {
      final c = regSeqFor([kg, primary], 'SECONDARY');
      expect(c.seq, isNull);
      expect(c.blocked, isTrue);
      expect(c.notice, contains('SECONDARY has no admission number sequence'));
    });
    test('a standard with no division takes the general sequence, with no notice', () {
      final c = regSeqFor(all, null);
      expect(c.seq, general);
      expect(c.notice, isNull);
    });
    test('a division with no sequence falls back to the general one and says so', () {
      final c = regSeqFor(all, 'SECONDARY');
      expect(c.seq, general);
      expect(c.blocked, isFalse);
      expect(c.notice, contains('so ADM is used'));
    });
    test('no division and no general sequence is blocked', () {
      final c = regSeqFor([kg, primary], null);
      expect(c.blocked, isTrue);
      expect(c.notice, contains('no general admission number sequence'));
    });
  });
}
