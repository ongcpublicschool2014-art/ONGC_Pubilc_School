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

/// The number series on Sequence Master's "Sequence Type" dropdown. `label`
/// is the Admission Master / Fee Master tab key (never reword); `title` is
/// what the dropdown shows.
const List<AppNavSubItem> kSequenceTypes = [
  AppNavSubItem('tag', 'Reg No', title: 'Register No.'),
  AppNavSubItem('document-text', 'TC Sequence', title: 'TC No.'),
  AppNavSubItem('category', 'Demand No', title: 'Demand No.'),
  AppNavSubItem('discount-shape', 'Concession No', title: 'Concession No.'),
  AppNavSubItem('money-recive', 'Refund No', title: 'Refund No.'),
  // Numbers every cancelled / bounced receipt (CANCNO; user, 2026-11-14).
  AppNavSubItem('close-circle', 'Cancel No', title: 'Cancel No.'),
  // No ADVNO series any more: a student or mess advance is numbered from
  // the RECEIPT sequence of the fee group it is banked under, like every
  // other receipt. See save_advance_collection.
  AppNavSubItem('receipt-1', 'Receipt Sequence', title: 'Receipt No.'),
  // School only: arrear fees are receipted from their own series (ARRFEENO).
  AppNavSubItem('receipt-minus', 'Arrear Receipt No', title: 'Arrear Receipt No.'),
  // School only: Miscellaneous Collection's own series (MISCFEENO).
  AppNavSubItem('receipt-text', 'Misc Receipt No', title: 'Miscellaneous Receipt No.'),
  // School only: Advance Fee Collection's own receipt series (ADVFEENO).
  AppNavSubItem('receipt-2', 'Advance Fee Receipt No', title: 'Advance Receipt No.'),
];

/// [kSequenceTypes] this database uses (Advance Receipt No. is school only).
List<AppNavSubItem> get visibleSequenceTypes => kSequenceTypes
    .where((s) => !(isSchool ? kSchoolHiddenSubItems : kCollegeHiddenSubItems).contains(s.label))
    .toList();

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
  /// Optional shorter name for the sidebar only, where [title] is too long
  /// for the menu width; the top bar still shows [title].
  final String? sideTitle;
  final String section;

  /// Display only: items of a section sharing a group sit under a small
  /// collapsible heading in the sidebar (Reports > Collection > Daily
  /// Collection). The label stays the permission key; see [kNavGroupIcons].
  final String? group;

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
    this.sideTitle,
    this.section = 'MAIN',
    this.group,
    this.adminOnly = false,
    this.accountantOnly = false,
    this.hideForAccountant = false,
    this.unselectedIcon,
    this.subItems = const [],
  });

  /// What the sidebar/top bar shows. Falls back to [label] when no override.
  /// In school wording on the school database (Course -> Standard ...).
  String get navTitle => schoolTerm(title ?? label);

  /// What the sidebar shows: [sideTitle] when set, else [navTitle].
  String get sideNavTitle => sideTitle == null ? navTitle : schoolTerm(sideTitle!);

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
  'STAFF': ['profile-2user', 'Staff'],
  'ATTENDANCE': ['calendar-tick', 'Attendance'],
  'FEES': ['wallet-money', 'Fees'],
  'TRANSPORT': ['bus', 'Transport'],
  'TC': ['document-text', 'Transfer Certificate'],
  'REPORTS': ['chart-1', 'Reports'],
  'BANKING': ['bank', 'Banking'],
  'SETUP': ['setting-2', 'Setup'],
  'GENERAL': ['notification', 'General'],
};

/// Icon of each sidebar group ([AppNavItem.group]).
const Map<String, String> kNavGroupIcons = {
  'Collection': 'wallet-money',
  'Student-wise': 'people',
  'Pending & DCB': 'clock',
  'Advance': 'empty-wallet',
  'Admission & TC': 'document-text',
};

/// Every menu item in the app, in sidebar order.
const List<AppNavItem> kAppNavItems = [
  AppNavItem('element-3', 'Dashboard', section: 'MAIN MENU'),

  // ADMISSION — enrolling and placing students.
  AppNavItem('profile-add', 'Admission', title: 'Admission Entry', section: 'ADMISSION', adminOnly: true),
  // Places admissions saved without a class (Fast Admission) and moves them
  // into students. School: "Section Allocation" via navTitle.
  AppNavItem('task-square', 'Class Allocation', section: 'ADMISSION', adminOnly: true),
  // School only: a pre-admission placed in its standard gets its section here,
  // once the principal approves (school_preadmission_standard.sql).
  AppNavItem('flash', 'Fast Admission', section: 'ADMISSION', adminOnly: true),
  AppNavItem('ranking', 'Course Transfer', title: 'Student Transfer', section: 'ADMISSION', adminOnly: true),
  AppNavItem('tag', 'New Roll Number', title: 'New Register Number', section: 'ADMISSION', adminOnly: true),
  AppNavItem('note-1', 'EMIS / UMIS', section: 'ADMISSION', adminOnly: true),

  // STUDENTS
  AppNavItem('people', 'Students', title: 'Student Details', section: 'STUDENTS', adminOnly: true),

  // STAFF (school only) -- its own section below Student Details, out of Setup
  // (user, 2026-11-23). The staff, their experience, and the year's employee
  // code and designation (school_staff_master.sql). 'Staff' is the permission
  // key the server checks (_staff_ctx) -- never rename it.
  AppNavItem('profile-2user', 'Staff', title: 'Staff Details', section: 'STAFF', adminOnly: true),

  // ATTENDANCE (school only, 2026-11-24) -- C:/pg_backups/attendance:
  // school_attendance.sql (tables) and school_attendance_api.sql (att_*
  // functions). The labels are the menu names the server checks (_att_ctx)
  // -- never rename them.
  AppNavItem('calendar-tick', 'Attendance Entry', section: 'ATTENDANCE', adminOnly: true),
  AppNavItem('calendar-remove', 'Leave & Out-pass', section: 'ATTENDANCE', adminOnly: true),
  AppNavItem('chart-1', 'Attendance Report', section: 'ATTENDANCE', adminOnly: true),
  AppNavItem('setting-2', 'Attendance Setup', section: 'ATTENDANCE', adminOnly: true),

  // FEES — ordered to follow the money lifecycle:
  // raise demand → approve → concede → collect → refund → statement.
  AppNavItem('receipt-edit', 'Fee Demand', section: 'FEES'),
  // Wide Excel (student x fee type) in and out; stages into the same
  // approval flow as Fee Demand. Label is the permission key -- never rename.
  AppNavItem('document-upload', 'Fee Demand Import', section: 'FEES'),
  AppNavItem('indianrupeesign.circle.fill', 'Fee Collection', section: 'FEES', accountantOnly: true, unselectedIcon: 'indianrupeesign.circle'),
  AppNavItem('receipt-2', 'Misc Collection', title: 'Miscellaneous Collection', section: 'FEES', accountantOnly: true),
  // Money taken before any fee is due. Spent on Fee Collection, which
  // highlights a student who still has an unused advance.
  AppNavItem('empty-wallet-add', 'Advance Collection', section: 'FEES', accountantOnly: true),
  // School only: next year's fees (stuadvdemand) from the Advance Fee
  // Definition, collected as admission-advance receipts.
  AppNavItem('wallet-add', 'Advance Fee Collection', section: 'FEES', accountantOnly: true),
  // Below Advance Fee Collection (user, 2026-11-14).
  AppNavItem('discount-shape', 'Fee Concession', section: 'FEES', accountantOnly: true),
  // School: concessions entered by a role that may not approve them wait here
  // (school_concession_approval.sql). Given to a role in Roles & Access.
  AppNavItem('tick-square', 'Concession Approval', section: 'FEES', adminOnly: true),
  // Bulk-applies ADMISSION advances against one fee type. A student advance is
  // applied at the counter instead — it settles a balance, not a fee.
  // Shown as "Advance Reconcile" (user, 2026-11-14); the label stays the key.
  AppNavItem('empty-wallet-change', 'Advance Adjustment', title: 'Advance Reconcile', section: 'FEES', accountantOnly: true),
  AppNavItem('money-recive', 'Fee Refund', section: 'FEES', accountantOnly: true),
  AppNavItem('receipt-discount', 'Fee Cancel Receipt', title: 'Cancel Fee Receipt', section: 'FEES', accountantOnly: true),
  // Just above the import (user, 2026-11-14).
  AppNavItem('tick-square', 'Fee Demand Approval', section: 'FEES', adminOnly: true),
  // Last in Fees (user, 2026-11-14: "move feecollection import to last").
  AppNavItem('document-upload', 'Fee Collection Import', section: 'FEES', accountantOnly: true),

  // TRANSPORT (school only). The server checks these same menu names:
  // see transport._entity in migrations/desktop/transport_02_phase1_api.sql.
  AppNavItem('setting-2', 'Transport Setup', section: 'TRANSPORT', adminOnly: true),
  AppNavItem('routing', 'Routes & Stops', section: 'TRANSPORT', adminOnly: true),
  AppNavItem('bus', 'Vehicles', section: 'TRANSPORT', adminOnly: true),
  AppNavItem('driver', 'Transport Staff', section: 'TRANSPORT', adminOnly: true),
  // Route + vehicle + times -> each day's trips (transport_core.fn_generate_trips).
  AppNavItem('timer-1', 'Trip Schedules', section: 'TRANSPORT', adminOnly: true),
  // Who drives and attends each schedule; each day's trip takes its crew from it.
  AppNavItem('user-tick', 'Duty Roster', section: 'TRANSPORT', adminOnly: true),
  // Which students travel on each route, and their pickup and drop stops.
  AppNavItem('people', 'Student Enrollment', section: 'TRANSPORT', adminOnly: true),
  // Which vehicle each enrolled student travels in, within its seats.
  AppNavItem('element-4', 'Vehicle Allotment', section: 'TRANSPORT', adminOnly: true),
  // What each stage of a route costs, term by term (transport fee types only).
  AppNavItem('moneys', 'Stage Fees', section: 'TRANSPORT', adminOnly: true),

  // Sidebar order (user, 2026-11-13, "daily work first"): Dashboard,
  // Admission, Student Details, Fees, Transfer Certificate, Reports,
  // Banking, Setup, General. Sections show in the order they first appear here.
  // TC -- its own module, as the old product (PsTc.dll): issue the TC,
  // fill the certificate, approve it, print it on the school's own Word
  // format. 'Transfer Certificate' keeps its label (role grants are by label).
  AppNavItem('document-text', 'Transfer Certificate', title: 'Transfer Certificate Entry', sideTitle: 'TC Entry', section: 'TC', adminOnly: true),
  AppNavItem('edit-2', 'TC Certificate', title: 'TC Details', section: 'TC', adminOnly: true),
  AppNavItem('tick-square', 'TC Approval', section: 'TC', adminOnly: true),
  AppNavItem('printer', 'TC Print', section: 'TC', adminOnly: true),
  AppNavItem('document-upload', 'TC Format', section: 'TC', adminOnly: true),

  // REPORTS — each report is its own submenu (opens the Reports screen at that
  // tab with the in-screen tab bar hidden). NOTE: no 'Collection Summary' entry
  // — the Dashboard menu opens that screen (fee_collection_screen.dart).
  // Grouped in the sidebar (user, 2026-11-23: "in reports under grouped by
  // submenu"): [AppNavItem.group] is display only -- each report keeps its
  // own label, the Roles & Access / Module Control key.
  // Collection
  AppNavItem('calendar-1', 'Daily Collection', section: 'REPORTS', group: 'Collection'),
  // School: the old product's report formats (receipt-wise, division
  // summary, fee matrix, pending fee, advance reconciliation).
  AppNavItem('receipt-item', 'Receiptwise Report', section: 'REPORTS', group: 'Collection'),
  AppNavItem('receipt-text', 'Receiptwise Abstract', section: 'REPORTS', group: 'Collection'),
  AppNavItem('calendar-2', 'Datewise Abstract', section: 'REPORTS', group: 'Collection'),
  AppNavItem('category-2', 'Division Summary', section: 'REPORTS', group: 'Collection'),
  // Student-wise
  AppNavItem('book-1', 'Student Ledger', section: 'REPORTS', group: 'Student-wise'),
  AppNavItem('chart-2', 'Consolidated Status', section: 'REPORTS', group: 'Student-wise'),
  // School: the old product's Consolidated Summary Statement (per student).
  AppNavItem('document-text', 'Consolidated Summary', section: 'REPORTS', group: 'Student-wise'),
  // Pending & DCB
  AppNavItem('clock', 'Pending Payment', section: 'REPORTS', group: 'Pending & DCB'),
  AppNavItem('receipt-item', 'Pending Details', section: 'REPORTS', group: 'Pending & DCB'),
  AppNavItem('clock', 'Pending Fee Report', section: 'REPORTS', group: 'Pending & DCB'),
  AppNavItem('grid-1', 'Fee Matrix', section: 'REPORTS', group: 'Pending & DCB'),
  AppNavItem('grid-1', 'DCB Register', section: 'REPORTS', group: 'Pending & DCB'),
  AppNavItem('chart-21', 'DCB Statement', section: 'REPORTS', group: 'Pending & DCB'),
  // Advance
  AppNavItem('wallet-check', 'Advance Reconciliation Report', sideTitle: 'Advance Reconciliation', section: 'REPORTS', group: 'Advance'),
  AppNavItem('wallet-money', 'Advance Register', section: 'REPORTS', group: 'Advance'),
  // Admission & TC
  AppNavItem('book-1', 'Admission Register', section: 'REPORTS', group: 'Admission & TC'),
  AppNavItem('document-text', 'TC Report', section: 'REPORTS', group: 'Admission & TC'),

  // BANKING — money that has left the counter.
  AppNavItem('receipt-2', 'Transactions', section: 'BANKING'),
  AppNavItem('bank', 'Bank Reconciliation', section: 'BANKING', adminOnly: true),

  // SETUP — configure-once masters. Sits above GENERAL so the two
  // notification items stay at the very bottom of the sidebar.
  // The master screens carry their tabs as sub-items: picking one opens
  // that tab directly, and the in-screen tab bar is hidden. Sub-items are NOT
  // separate permission keys — the parent's Roles & Access entry still governs.
  // Division and Medium sit under Master Data (user, 2026-11-10 / 2026-11-24)
  // but are tabs of AdmissionMasterScreen.
  AppNavItem('document-upload', 'Master Data', section: 'SETUP', adminOnly: true,
      subItems: [
        AppNavSubItem('diagram', 'Division'),
        AppNavSubItem('language-square', 'Medium'),
        AppNavSubItem('teacher', 'Course'),
        AppNavSubItem('book-1', 'Class'),
      ]),
  AppNavItem('category-2', 'Admission Master', section: 'SETUP', adminOnly: true,
      subItems: [
        AppNavSubItem('user-tick', 'Admission Type'),
        AppNavSubItem('ticket', 'Quota'),
        AppNavSubItem('people', 'Community'),
        AppNavSubItem('discount-shape', 'Concession'),
      ]),
  // The gateway account (merchant ID, keys) before Fee Master: a fee group's
  // bank account carries its Merchant / Settlement ID under this gateway
  // (user, 2026-11-14: "bring payment gateway above the fee master").
  AppNavItem('card', 'Payment Gateways', section: 'SETUP', adminOnly: true),
  AppNavItem('receipt-discount', 'Fee Master', section: 'SETUP', accountantOnly: true,
      subItems: [
        AppNavSubItem('receipt-discount', 'Fee Group'),
        AppNavSubItem('tag', 'Fee Type'),
        AppNavSubItem('calendar-1', 'Semester'),
        // School only (<year schema>.classmatch): section -> next section.
        // Shown as "Section Mapping" (user, 2026-11-14); the label stays the key.
        AppNavSubItem('arrow-swap-horizontal', 'Class Matching', title: 'Class Mapping'),
        AppNavSubItem('sort', 'Class Fee Demand'),
        // School only (<year schema>.advfeedemand): next year's fees, defined
        // but never raised on students.
        AppNavSubItem('empty-wallet-add', 'Advance Fee Definition'),
        AppNavSubItem('warning-2', 'Fine Rules'),
        // School only: the school's own fee receipt (a PDF with the values
        // placed on it). Its own screen, not a Fee Master tab.
        AppNavSubItem('receipt-edit', 'Receipt Format'),
      ]),
  // Every number series the institution issues, gathered from Admission Master
  // and Fee Master. One menu item: the series is picked from a dropdown on the
  // screen (kSequenceTypes, SequenceMasterScreen) -- user, 2026-11-13.
  AppNavItem('hashtag', kSequenceMenu, section: 'SETUP', adminOnly: true),
  // Bank accounts are added / edited from Fee Master -> Fee Group.
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

/// Menus that can be assigned to a role in the Roles & Access screen: every
/// menu this database shows (Dashboard included) -- the ones a school or a
/// college never shows are left out, as in the sidebar.
List<AppNavItem> get kAssignableNavItems => kAppNavItems
    .where((i) => !(isSchool ? kSchoolHiddenNavItems : kCollegeHiddenSubItems).contains(i.label))
    .toList();
