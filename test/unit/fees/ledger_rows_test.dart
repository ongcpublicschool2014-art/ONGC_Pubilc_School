import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/ledger_logic.dart';

Map<String, dynamic> _demand({
  String demno = 'D1',
  String term = 'I SEMESTER',
  String feetype = 'SCHOOL FEES',
  String duedate = '2026-04-01',
  num feeamount = 1000,
  num paidamount = 0,
  num fineamount = 0,
  num? balancedue,
  num? reconbalancedue,
  Map<String, dynamic>? payment,
}) =>
    {
      'demno': demno,
      'demfeeterm': term,
      'demfeetype': feetype,
      'duedate': duedate,
      'feeamount': feeamount,
      'paidamount': paidamount,
      'fineamount': fineamount,
      'balancedue': balancedue ?? (feeamount - paidamount),
      'reconbalancedue': reconbalancedue,
      'payment': payment,
    };

void main() {
  group('buildLedgerRows', () {
    test('unpaid demand emits only debit row', () {
      final rows = buildLedgerRows([_demand()]);
      expect(rows, hasLength(1));
      expect(rows.first.type, 'demand');
      expect(rows.first.debit, 1000);
      expect(rows.first.credit, 0);
    });

    test('paid + reconciled emits demand and payment rows', () {
      final rows = buildLedgerRows([
        _demand(
          paidamount: 1000,
          balancedue: 0,
          reconbalancedue: 0,
          payment: {
            'paydate': '2026-04-15',
            'paynumber': 'SF25/00001',
            'paymethod': 'cash',
          },
        ),
      ]);
      expect(rows, hasLength(2));
      expect(rows.where((r) => r.type == 'demand'), hasLength(1));
      expect(rows.where((r) => r.type == 'payment'), hasLength(1));
      final payment = rows.firstWhere((r) => r.type == 'payment');
      expect(payment.credit, 1000);
      expect(payment.feetype, 'Payment (cash)');
    });

    test('paid but not reconciled (reconbalancedue > 0) hides payment row', () {
      final rows = buildLedgerRows([
        _demand(
          paidamount: 1000,
          balancedue: 0, // legacy field shows zero
          reconbalancedue: 1000, // recon still pending
          payment: {'paydate': '2026-04-15', 'paynumber': 'SF25/00002', 'paymethod': 'razorpay'},
        ),
      ]);
      expect(rows.where((r) => r.type == 'payment'), isEmpty);
      expect(rows, hasLength(1)); // only the demand row
    });

    test('partial payment marks Partial Payment label', () {
      final rows = buildLedgerRows([
        _demand(
          feeamount: 1000,
          paidamount: 500,
          balancedue: 500,
          reconbalancedue: 0, // reconciled in full somehow — partial label by balancedue
          payment: {'paydate': '2026-04-15', 'paynumber': 'SF25/00003', 'paymethod': 'cash'},
        ),
      ]);
      final payment = rows.firstWhere((r) => r.type == 'payment');
      expect(payment.feetype, contains('Partial Payment'));
    });

    test('demands sorted by date, payments sorted by date', () {
      final rows = buildLedgerRows([
        _demand(demno: 'A', duedate: '2026-04-15'),
        _demand(demno: 'B', duedate: '2026-04-01'),
        _demand(
          demno: 'C',
          duedate: '2026-04-10',
          paidamount: 1000,
          balancedue: 0,
          reconbalancedue: 0,
          payment: {'paydate': '2026-04-20', 'paynumber': 'P1', 'paymethod': 'cash'},
        ),
      ]);
      // First three are demands; sorted by due date ascending.
      final demandTypes = rows.where((r) => r.type == 'demand').toList();
      expect(demandTypes.map((r) => r.docno), ['B', 'C', 'A']);
      // Payment comes after all demands.
      expect(rows.last.type, 'payment');
    });

    test('falls back to balancedue when reconbalancedue absent', () {
      final rows = buildLedgerRows([
        _demand(
          paidamount: 1000,
          balancedue: 0,
          reconbalancedue: null, // no recon column
          payment: {'paydate': '2026-04-15', 'paynumber': 'X', 'paymethod': 'cash'},
        ),
      ]);
      expect(rows.where((r) => r.type == 'payment'), hasLength(1));
    });

    test('handles missing payment map gracefully', () {
      final rows = buildLedgerRows([
        _demand(paidamount: 1000, balancedue: 0, reconbalancedue: 0, payment: null),
      ]);
      expect(rows.where((r) => r.type == 'payment'), isEmpty);
    });
  });

  group('computeLedgerTotals', () {
    test('all unreconciled — paid is 0', () {
      final t = computeLedgerTotals([
        _demand(feeamount: 1000, paidamount: 1000, reconbalancedue: 1000),
        _demand(feeamount: 500, paidamount: 500, reconbalancedue: 500),
      ]);
      expect(t.demand, 1500);
      expect(t.paid, 0);
      expect(t.pending, 1500);
    });

    // paidamount is FEE only; the fine is collected on top of it.
    test('all reconciled — paid is paidamount, fine on top', () {
      final t = computeLedgerTotals([
        _demand(feeamount: 1000, paidamount: 1000, fineamount: 100, reconbalancedue: 0),
      ]);
      expect(t.demand, 1000);
      expect(t.paid, 1000);
      expect(t.fine, 100);
      expect(t.pending, 0);
    });

    test('mixed — sums match cards', () {
      final t = computeLedgerTotals([
        _demand(feeamount: 1000, paidamount: 1000, reconbalancedue: 0),
        _demand(feeamount: 500, paidamount: 0, reconbalancedue: 500),
      ]);
      expect(t.demand, 1500);
      expect(t.paid, 1000);
      expect(t.pending, 500);
    });
  });
}
