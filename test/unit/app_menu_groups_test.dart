import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/utils/app_menu.dart';

/// Reports are grouped in the sidebar (user, 2026-11-23). The group is display
/// only: every report keeps its own label (the Roles & Access key).
void main() {
  final reports = kAppNavItems.where((i) => i.section == 'REPORTS').toList();

  test('every report is in a group that has an icon', () {
    for (final r in reports) {
      expect(r.group, isNotNull, reason: r.label);
      expect(kNavGroupIcons.containsKey(r.group), isTrue, reason: '${r.label} -> ${r.group}');
    }
  });

  test('groups in sidebar order, each one together', () {
    final order = <String>[];
    for (final r in reports) {
      if (order.isEmpty || order.last != r.group) {
        expect(order.contains(r.group), isFalse, reason: '${r.group} is split: ${r.label}');
        order.add(r.group!);
      }
    }
    expect(order, ['Collection', 'Student-wise', 'Pending & DCB', 'Advance', 'Admission & TC']);
  });

  test('no report lost or renamed by the grouping', () {
    expect(reports.map((r) => r.label).toSet(), {
      'Daily Collection', 'Receiptwise Report', 'Receiptwise Abstract', 'Datewise Abstract', 'Division Summary',
      'Student Ledger', 'Consolidated Status', 'Consolidated Summary',
      'Pending Payment', 'Pending Details', 'Pending Fee Report', 'Fee Matrix', 'DCB Register', 'DCB Statement',
      'Advance Reconciliation Report', 'Advance Register',
      'Admission Register', 'TC Report',
    });
  });
}
