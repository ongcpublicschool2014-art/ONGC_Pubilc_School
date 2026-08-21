/// The app's sidebar menu catalog — the single source of truth for what
/// screens exist, how they're grouped, and their default role visibility.
///
/// Lives here (rather than inside DashboardScreen) so the Roles & Access
/// screen can list the same menus the sidebar renders. Keeping one list
/// prevents the permission tick-list from drifting out of sync with the menu.
library;

class AppNavSubItem {
  final String icon;
  final String label;
  const AppNavSubItem(this.icon, this.label);
}

class AppNavItem {
  final String icon;
  final String? unselectedIcon;
  final String label;
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
    this.section = 'MAIN',
    this.adminOnly = false,
    this.accountantOnly = false,
    this.hideForAccountant = false,
    this.unselectedIcon,
    this.subItems = const [],
  });
}

/// Icon + display label for each collapsible section header in the sidebar.
/// Key = section name used on AppNavItem.section.
const Map<String, List<String>> kSectionMeta = {
  'ADMISSION': ['profile-add', 'Admission'],
  'STUDENTS': ['people', 'Students'],
  'FEES': ['wallet-money', 'Fees'],
  'BANKING': ['bank', 'Banking'],
  'REPORTS': ['chart-1', 'Reports'],
  'GENERAL': ['notification', 'General'],
  'SETUP': ['setting-2', 'Setup'],
};

/// Every menu item in the app, in sidebar order.
const List<AppNavItem> kAppNavItems = [
  AppNavItem('element-3', 'Dashboard', section: 'MAIN MENU'),

  // ADMISSION — enrolling and placing students.
  AppNavItem('profile-add', 'Admission', section: 'ADMISSION', adminOnly: true),
  AppNavItem('flash', 'Fast Admission', section: 'ADMISSION', adminOnly: true),
  AppNavItem('task-square', 'Class Allocation', section: 'ADMISSION', adminOnly: true),

  // STUDENTS
  AppNavItem('people', 'Students', section: 'STUDENTS', adminOnly: true),

  // FEES — ordered to follow the money lifecycle:
  // raise demand → approve → concede → collect → refund → statement.
  AppNavItem('receipt-edit', 'Fee Demand', section: 'FEES'),
  AppNavItem('tick-square', 'Fee Demand Approval', section: 'FEES', adminOnly: true),
  AppNavItem('discount-shape', 'Fee Concession', section: 'FEES', accountantOnly: true),
  AppNavItem('indianrupeesign.circle.fill', 'Fee Collection', section: 'FEES', accountantOnly: true, unselectedIcon: 'indianrupeesign.circle'),
  AppNavItem('document-upload', 'Fee Collection Import', section: 'FEES', accountantOnly: true),
  AppNavItem('money-recive', 'Fee Refund', section: 'FEES', accountantOnly: true),

  // BANKING — money that has left the counter.
  AppNavItem('receipt-2', 'Transactions', section: 'BANKING'),
  AppNavItem('bank', 'Bank Reconciliation', section: 'BANKING', adminOnly: true),

  // REPORTS
  // NOTE: no 'Collection Summary' entry — the Dashboard menu opens that screen
  // (fee_collection_screen.dart), so a separate item would be a duplicate.
  AppNavItem('chart-1', 'Reports', section: 'REPORTS', unselectedIcon: 'chart'),

  // GENERAL
  AppNavItem('notification', 'Notices', section: 'GENERAL'),
  AppNavItem('notification-bing', 'Notifications', section: 'GENERAL'),

  // SETUP — configure-once masters, kept last so daily work stays on top.
  AppNavItem('document-upload', 'Master Data', section: 'SETUP', adminOnly: true),
  AppNavItem('category-2', 'Admission Master', section: 'SETUP', adminOnly: true),
  AppNavItem('receipt-discount', 'Fee Master', section: 'SETUP', accountantOnly: true),
  AppNavItem('bank', 'Bank Accounts', section: 'SETUP', adminOnly: true),
  // Roles first, then Users — you define a role before assigning it to a user.
  AppNavItem('lock-1', 'Roles & Access', section: 'SETUP', adminOnly: true),
  AppNavItem('security-user', 'Users', section: 'SETUP', adminOnly: true),
  // Institution-wide behaviour toggles (admission numbering, arrear-first collection).
  AppNavItem('setting-2', 'Utilities', section: 'SETUP', adminOnly: true),
];

/// Menus an Admin can never lose — granting/revoking these would let an Admin
/// lock themselves (or every Admin) out of the app.
const Set<String> kAlwaysAllowedForAdmin = {'Dashboard', 'Users', 'Roles & Access'};

/// Menus that can be assigned to a role in the Roles & Access screen.
/// Dashboard is excluded — everyone gets it.
List<AppNavItem> get kAssignableNavItems =>
    kAppNavItems.where((i) => i.label != 'Dashboard').toList();
