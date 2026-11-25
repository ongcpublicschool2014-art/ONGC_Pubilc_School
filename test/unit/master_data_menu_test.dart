import 'package:flutter_test/flutter_test.dart';
import 'package:school_admin/screens/admin/master_data_screen.dart';
import 'package:school_admin/screens/admission/admission_master_screen.dart';
import 'package:school_admin/utils/app_menu.dart';

/// Setup -> Master Data: Division and Medium (user, 2026-11-24: "add medium")
/// are Admission Master tabs, Course / Class are Master Data tabs. The
/// dashboard opens a sub-item by its label, so each one must be a real tab.
void main() {
  final masterData = kAppNavItems.firstWhere((i) => i.label == 'Master Data');
  final subs = masterData.subItems.map((s) => s.label).toList();

  test('Medium is listed under Master Data, after Division', () {
    expect(subs, ['Division', 'Medium', 'Course', 'Class']);
  });

  test('every Master Data sub-item opens a tab', () {
    for (final s in subs) {
      final tab = AdmissionMasterScreen.tabLabels.contains(s) || MasterDataScreen.tabLabels.contains(s);
      expect(tab, isTrue, reason: s);
    }
    expect(AdmissionMasterScreen.tabLabels.indexOf('Medium'), AdmissionMasterScreen.tabLabels.indexOf('Division') + 1);
  });
}
