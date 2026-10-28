/// The app's sidebar menu catalog — the single source of truth for what
/// screens exist, how they're grouped, and their default role visibility.
///
/// Lives here (rather than inside DashboardScreen) so the Roles & Access
/// screen can list the same menus the sidebar renders. Keeping one list
/// prevents the permission tick-list from drifting out of sync with the menu.
library;

import 'school_terms.dart';

/// Routing + permission key for Setup -> Sequence Master.
///
/// A NEW permission key: a role that already has explicit menu permissions
/// will not see this menu until it is granted in Roles & Access, even if that
/// role has Fee Master. The sequences it holds moved OUT of Fee Master and
/// Admission Master, so granting it is what restores them.
const String kSequenceMenu = 'Sequence Master';

class AppNavSubItem {
  final String icon;
  /// Routing / tab key (screens find their tab by it) -- never reworded.
  final String label;
  /// Optional display-only text for the sidebar.
  final String? title;
  const AppNavSubItem(this.icon, this.label, {this.title});
  String get navTitle => schoolTerm(title ?? label);
}

class AppNavItem {
  final String icon;
  final String? unselectedIcon;
  final String label;
  /// Optional display-only override for the sidebar/title. `label` stays the
  /// stable routing + Roles&Access permission key (stored per-role in the DB),
  /// so renaming what the user sees never revokes a menu from a configured role.
  final String? title;
  final String section;

  /// Default visibility, used only until an Admin configures Roles & Access.
  /// Once a role has explicit menu permissions, these flags are bypassed.
  final bool adminOnly;
  final bool accountantOnly;
  final bool hideForAccountant;
  final List<AppNavSubItem> subItems;

  const AppNavItem(
    this.icon,
    this.label, {
    this.title,
    this.section = 'MAIN',
    this.adminOnly = false,
    this.accountantOnly = false,
    this.hideForAccountant = false,
    this.unselectedIcon,
    this.subItems = const [],
  });

  /// What the sidebar/top bar shows. Falls back to [label] when no override.
  /// In school wording on the school database (Course -> Standard ...).
  String get navTitle => schoolTerm(title ?? label);

  /// Sub-items to show: on a school, the ones that do not exist there
  /// (Admission Type, Quota) are left out. [subItems] keeps every key.
  List<AppNavSubItem> get visibleSubItems => isSchool
      ? subItems.where((s) => !kSchoolHiddenSubItems.contains(s.label)).toList()
      : subItems.where((s) => !kCollegeHiddenSubItems.contains(s.label)).toList();
}

/// Icon + display label for each collapsible section header in the sidebar.
/// Key = section name used on AppNavItem.section.
const Map<String, List<String>> kSectionMeta = {
  'ADMISSION': ['profile-add', 'Admission'],
  'STUDENTS': ['people', 'Students'],
  'TC': ['document-text', 'TC'],
  'FEES': ['wallet-money', 'Fees'],
  'BANKING': ['bank', 'Banking'],
  'REPORTS': ['chart-1', 'Reports'],
  'SETUP': ['setting-2', 'Setup'],
  'GENERAL': ['notification', 'General'],
};

/// Every menu item in the app, in sidebar order.
const List<AppNavItem> kAppNavItems = [
  AppNavItem('element-3', 'Dashboard', section: 'MAIN MENU'),

  // ADMISSION — enrolling and placing students.
  AppNavItem('profile-add', 'Admission', title: 'Admission Entry', section: 'ADMISSION', adminOnly: true),
  // Places admissions saved without a class (Fast Admission) and moves them
  // into students. School: "Section Allocation" via navTitle.
  AppNavItem('task-square', 'Class Allocation', section: 'ADMISSION', adminOnly: true),
  AppNavItem('flash', 'Fast Admission', section: 'ADMISSION', adminOnly: true),
  AppNavItem('ranking', 'Course Transfer', title: 'Student Transfer', section: 'ADMISSION', adminOnly: true),
  AppNavItem('tag', 'New Roll Number', title: 'New Register Number', section: 'ADMISSION', adminOnly: true),
  AppNavItem('note-1', 'EMIS / UMIS', section: 'ADMISSION', adminOnly: true),

  // STUDENTS
  AppNavItem('people', 'Students', title: 'Student Details', section: 'STUDENTS', adminOnly: true),

  // TC -- its own module, as the old product (PsTc.dll): issue the TC,
  // fill the certificate, approve it, print it on the school's own Word
  // format. 'Transfer Certificate' keeps its label (role grants are by label).
  AppNavItem('document-text', 'Transfer Certificate', title: 'Transfer Certificate Entry', section: 'TC', adminOnly: true),
  AppNavItem('edit-2', 'TC Certificate', title: 'TC Details', section: 'TC', adminOnly: true),
  AppNavItem('tick-square', 'TC Approval', section: 'TC', adminOnly: true),
  AppNavItem('printer', 'TC Print', section: 'TC', adminOnly: true),
  AppNavItem('document-upload', 'TC Format', section: 'TC', adminOnly: true),

  // FEES — ordered to follow the money lifecycle:
  // raise demand → approve → concede → collect → refund → statement.
  AppNavItem('receipt-edit', 'Fee Demand', section: 'FEES'),
  // Wide Excel (student x fee type) in and out; stages into the same
  // approval flow as Fee Demand. Label is the permission key -- never rename.
  AppNavItem('document-upload', 'Fee Demand Import', section: 'FEES'),
  AppNavItem('tick-square', 'Fee Demand Approval', section: 'FEES', adminOnly: true),
  AppNavItem('discount-shape', 'Fee Concession', section: 'FEES', accountantOnly: true),
  AppNavItem('indianrupeesign.circle.fill', 'Fee Collection', section: 'FEES', accountantOnly: true, unselectedIcon: 'indianrupeesign.circle'),
  AppNavItem('receipt-2', 'Misc Collection', title: 'Miscellaneous Collection', section: 'FEES', accountantOnly: true),
  // Money taken before any fee is due. Spent on Fee Collection, which
  // highlights a student who still has an unused advance.
  AppNavItem('empty-wallet-add', 'Advance Collection', section: 'FEES', accountantOnly: true),
  // School only: next year's fees (stuadvdemand) from the Advance Fee
  // Definition, collected as admission-advance receipts.
  AppNavItem('wallet-add', 'Advance Fee Collection', section: 'FEES', accountantOnly: true),
  // Bulk-applies ADMISSION advances against one fee type. A student advance is
  // applied at the counter instead — it settles a balance, not a fee.
  AppNavItem('empty-wallet-change', 'Advance Adjustment', section: 'FEES', accountantOnly: true),
  AppNavItem('document-upload', 'Fee Collection Import', section: 'FEES', accountantOnly: true),
  AppNavItem('money-recive', 'Fee Refund', section: 'FEES', accountantOnly: true),
  AppNavItem('receipt-discount', 'Fee Cancel Receipt', title: 'Cancel Fee Receipt', section: 'FEES', accountantOnly: true),

  // REPORTS — each report is its own submenu (opens the Reports screen at that
  // tab with the in-screen tab bar hidden). NOTE: no 'Collection Summary' entry
  // — the Dashboard menu opens that screen (fee_collection_screen.dart).
  AppNavItem('calendar-1', 'Daily Collection', section: 'REPORTS'),
  AppNavItem('book-1', 'Student Ledger', section: 'REPORTS'),
  AppNavItem('clock', 'Pending Payment', section: 'REPORTS'),
  AppNavItem('receipt-item', 'Pending Details', section: 'REPORTS'),
  AppNavItem('chart-2', 'Consolidated Status', section: 'REPORTS'),
  // School: the old product's Consolidated Summary Statement (per student).
  AppNavItem('document-text', 'Consolidated Summary', section: 'REPORTS'),
  // School: the old product's report formats (receipt-wise, division
  // summary, fee matrix, pending fee, advance reconciliation).
  AppNavItem('receipt-item', 'Receiptwise Report', section: 'REPORTS'),
  AppNavItem('category-2', 'Division Summary', section: 'REPORTS'),
  AppNavItem('grid-1', 'Fee Matrix', section: 'REPORTS'),
  AppNavItem('clock', 'Pending Fee Report', section: 'REPORTS'),
  AppNavItem('wallet-check', 'Advance Reconciliation Report', section: 'REPORTS'),
  AppNavItem('grid-1', 'DCB Register', section: 'REPORTS'),
  AppNavItem('wallet-money', 'Advance Register', section: 'REPORTS'),
  AppNavItem('book-1', 'Admission Register', section: 'REPORTS'),
  AppNavItem('document-text', 'TC Report', section: 'REPORTS'),

  // BANKING — money that has left the counter.
  AppNavItem('receipt-2', 'Transactions', section: 'BANKING'),
  AppNavItem('bank', 'Bank Reconciliation', section: 'BANKING', adminOnly: true),

  // SETUP — configure-once masters. Sits above GENERAL so the two
  // notification items stay at the very bottom of the sidebar.
  // The three master screens carry their tabs as sub-items: picking one opens
  // that tab directly, and the in-screen tab bar is hidden. Sub-items are NOT
  // separate permission keys — the parent's Roles & Access entry still governs.
  AppNavItem('document-upload', 'Master Data', section: 'SETUP', adminOnly: true,
      subItems: [
        AppNavSubItem('teacher', 'Course'),
        AppNavSubItem('book-1', 'Class'),
      ]),
  AppNavItem('category-2', 'Admission Master', section: 'SETUP', adminOnly: true,
      subItems: [
        AppNavSubItem('user-tick', 'Admission Type'),
        AppNavSubItem('ticket', 'Quota'),
        AppNavSubItem('people', 'Community'),
        AppNavSubItem('discount-shape', 'Concession'),
        AppNavSubItem('diagram', 'Division'),
      ]),
  AppNavItem('receipt-discount', 'Fee Master', section: 'SETUP', accountantOnly: true,
      subItems: [
        AppNavSubItem('receipt-discount', 'Fee Group'),
        AppNavSubItem('tag', 'Fee Type'),
        AppNavSubItem('calendar-1', 'Semester'),
        // School only (<year schema>.classmatch): section -> next section.
        AppNavSubItem('arrow-swap-horizontal', 'Class Matching'),
        AppNavSubItem('sort', 'Class Fee Demand'),
        // School only (<year schema>.advfeedemand): next year's fees, defined
        // but never raised on students.
        AppNavSubItem('empty-wallet-add', 'Advance Fee Definition'),
        AppNavSubItem('warning-2', 'Fine Rules'),
      ]),
  // Every number series the institution issues, gathered from Admission Master
  // and Fee Master. The tabs still live on those screens -- this is a view over
  // them, not a second copy.
  AppNavItem('hashtag', kSequenceMenu, section: 'SETUP', adminOnly: true,
      subItems: [
        AppNavSubItem('tag', 'Reg No', title: 'Register No.'),
        AppNavSubItem('document-text', 'TC Sequence', title: 'TC No.'),
        AppNavSubItem('category', 'Demand No', title: 'Demand No.'),
        AppNavSubItem('discount-shape', 'Concession No', title: 'Concession No.'),
        AppNavSubItem('money-recive', 'Refund No', title: 'Refund No.'),
        // No ADVNO series any more: a student or mess advance is numbered from
        // the RECEIPT sequence of the fee group it is banked under, like every
        // other receipt. See save_advance_collection.
        AppNavSubItem('receipt-1', 'Receipt Sequence', title: 'Receipt No.'),
        // School only: Advance Fee Collection's own receipt series (ADVFEENO).
        AppNavSubItem('receipt-2', 'Advance Fee Receipt No', title: 'Advance Receipt No.'),
      ]),
  AppNavItem('bank', 'Bank Accounts', section: 'SETUP', adminOnly: true),
  // Roles first, then Users — you define a role before assigning it to a user.
  AppNavItem('lock-1', 'Roles & Access', section: 'SETUP', adminOnly: true),
  AppNavItem('security-user', 'Users', section: 'SETUP', adminOnly: true),
  // Institution-wide behaviour toggles (admission numbering, arrear-first collection).
  AppNavItem('setting-2', 'Utilities', section: 'SETUP', adminOnly: true),
  // School only: close the year into the next one (promotion, fees, arrears,
  // receipt series, advances) -- the old product's Year End Processing.
  AppNavItem('calendar-tick', 'Year End Process', section: 'SETUP', adminOnly: true),


  // GENERAL
  AppNavItem('notification', 'Notices', section: 'GENERAL'),
  AppNavItem('notification-bing', 'Notifications', section: 'GENERAL'),
];

/// Menus an Admin can never lose — granting/revoking these would let an Admin
/// lock themselves (or every Admin) out of the app. Dashboard is NOT one of
/// them: it is a landing page, not a way back in, so it can be hidden from any
/// role. Users + Roles & Access are what an Admin needs to undo a change.
const Set<String> kAlwaysAllowedForAdmin = {'Users', 'Roles & Access'};

/// Menus that can be assigned to a role in the Roles & Access screen — all of
/// them, Dashboard included.
List<AppNavItem> get kAssignableNavItems => kAppNavItems;
