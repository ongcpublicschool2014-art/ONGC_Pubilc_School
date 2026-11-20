/// Pure logic for the Student Ledger view. Extracted from
/// `lib/screens/fees/student_ledger_screen.dart` for unit testing.
///
/// Each demand row from the database may produce one or two ledger rows:
///   * A debit row representing the demand itself (always emitted).
///   * A credit row representing the payment (only when the row is paid AND
///     the payment has been reconciled — `reconbalancedue <= 0`).
///
/// Rows are sorted demands-first then payments, both by date ascending so
/// the running balance reads naturally from top to bottom.

class LedgerRow {
  final String date;
  final String docno;
  final String term;
  final String feetype;
  final String reference;
  final double debit;
  final double credit;
  final double fine;
  final String type; // 'demand' or 'payment'

  const LedgerRow({
    required this.date,
    required this.docno,
    required this.term,
    required this.feetype,
    required this.reference,
    required this.debit,
    required this.credit,
    required this.fine,
    required this.type,
  });

  Map<String, dynamic> toMap() => {
        'date': date,
        'docno': docno,
        'term': term,
        'feetype': feetype,
        'reference': reference,
        'debit': debit,
        'credit': credit,
        'fine': fine,
        'type': type,
      };
}

/// Build ordered ledger rows from a list of demand maps.
///
/// Each `demand` map is expected to contain (all optional, sensibly defaulted):
///   * `duedate` (String) — demand due date (used as both demand row date
///     and payment row date when the payment record lacks one).
///   * `demno` / `dem_id` — printed in DOC.NO column for demand rows.
///   * `demfeeterm` (String) — semester / month label.
///   * `demfeetype` (String) — fee type label.
///   * `feeamount` (num) — debit amount.
///   * `paidamount` (num) — FEE collected (the fine is not in it).
///   * `fineamount` (num) — fine collected on top of the fee.
///   * `balancedue` (num) — pre-reconciliation outstanding.
///   * `reconbalancedue` (num) — post-reconciliation outstanding. When
///     present and `<= 0`, the row is treated as fully reconciled and a
///     payment row is emitted; otherwise it's hidden (matches the cards).
///   * `payment` (Map) — joined payment row with `paydate`, `paynumber`, `paymethod`.
List<LedgerRow> buildLedgerRows(List<Map<String, dynamic>> demands) {
  final rows = <LedgerRow>[];

  for (final d in demands) {
    final raw = d['duedate']?.toString() ?? '';
    final dueDate = raw.length >= 10 ? raw.substring(0, 10) : raw;
    final paidAmount = (d['paidamount'] as num?)?.toDouble() ?? 0;
    final hasPaid = paidAmount > 0;
    final payment = d['payment'];
    final amt = (d['feeamount'] as num?)?.toDouble() ?? 0;

    rows.add(LedgerRow(
      date: dueDate,
      docno: d['demno']?.toString() ?? d['dem_id']?.toString() ?? '-',
      term: d['demfeeterm']?.toString() ?? '-',
      feetype: d['demfeetype']?.toString() ?? '-',
      reference: '-',
      debit: amt,
      credit: 0,
      fine: 0,
      type: 'demand',
    ));

    final reconBal = (d['reconbalancedue'] as num?)?.toDouble()
        ?? (d['balancedue'] as num?)?.toDouble() ?? amt;
    final isReconciled = reconBal <= 0;

    if (hasPaid && payment is Map && isReconciled) {
      final payDateRaw = payment['paydate']?.toString() ?? raw;
      final payDate = payDateRaw.length >= 10 ? payDateRaw.substring(0, 10) : payDateRaw;
      final payNumber = payment['paynumber']?.toString() ?? '-';
      final payMethod = payment['paymethod']?.toString() ?? '-';
      final balance = (d['balancedue'] as num?)?.toDouble() ?? 0;
      final fine = (d['fineamount'] as num?)?.toDouble() ?? 0;
      final isPartial = balance > 0;
      rows.add(LedgerRow(
        date: payDate,
        docno: payNumber,
        term: d['demfeeterm']?.toString() ?? '-',
        feetype: isPartial ? 'Partial Payment ($payMethod)' : 'Payment ($payMethod)',
        reference: d['demno']?.toString() ?? d['dem_id']?.toString() ?? '-',
        debit: balance,
        // paidamount is fee only (school_fine_model.sql, 2026-11-05).
        credit: paidAmount,
        fine: fine,
        type: 'payment',
      ));
    }
  }

  // Demands first (sorted by date), then payments (sorted by date)
  rows.sort((a, b) {
    final typeA = a.type == 'demand' ? 0 : 1;
    final typeB = b.type == 'demand' ? 0 : 1;
    if (typeA != typeB) return typeA.compareTo(typeB);
    return a.date.compareTo(b.date);
  });

  return rows;
}

/// Aggregate totals matching the Demand / Paid / Pending cards in the
/// Student Ledger header. Paid is the reconciled portion (paidamount -- fee
/// only -- when reconbalancedue ≤ 0); Pending is reconbalancedue (or balancedue fallback).
class LedgerTotals {
  final double demand;
  final double paid;
  final double fine;
  final double pending;

  const LedgerTotals({
    required this.demand,
    required this.paid,
    required this.fine,
    required this.pending,
  });
}

LedgerTotals computeLedgerTotals(List<Map<String, dynamic>> demands) {
  double demand = 0, paid = 0, fine = 0, pending = 0;
  for (final d in demands) {
    final amt = (d['feeamount'] as num?)?.toDouble() ?? 0;
    final reconBal = (d['reconbalancedue'] as num?)?.toDouble()
        ?? (d['balancedue'] as num?)?.toDouble() ?? amt;
    final pa = (d['paidamount'] as num?)?.toDouble() ?? 0;
    final fa = (d['fineamount'] as num?)?.toDouble() ?? 0;
    final isReconciled = reconBal <= 0;
    demand += amt;
    paid += isReconciled ? pa : 0;
    fine += isReconciled ? fa : 0;
    pending += reconBal;
  }
  return LedgerTotals(demand: demand, paid: paid, fine: fine, pending: pending);
}
