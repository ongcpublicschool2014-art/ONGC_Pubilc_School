/// The dashboard's own access catalogue.
///
/// Menu Access grants a role whole SCREENS, keyed by AppNavItem.label. The
/// dashboard needed something finer: the landing page puts the institution's
/// money on screen — what is owed, what came in today, what is still
/// outstanding — and not every role that needs the dashboard should see all of
/// it. So each card and each panel is grantable on its own.
///
/// Grants live in the SAME table as the menu ones (public.rolemenuaccess), one
/// row per allowed key. That is why every key here is prefixed: a menu label
/// and a tile key share one column, and [kDashboardTilePrefix] is what keeps a
/// tile called "Quick Actions" from ever being mistaken for a menu of the same
/// name.
///
/// NEVER rename a key. Like AppNavItem.label it is the stored permission, so a
/// rename silently revokes that tile for every role already configured. The
/// LABEL beside it is display-only and safe to reword.
library;

const String kDashboardTilePrefix = 'dash:';

/// Written whenever an Admin saves, so "configured to show nothing" can be
/// told apart from "never configured".
///
/// Without it the two are identical — both are simply an absence of rows — and
/// a role with every tile unticked would read as unconfigured and be shown the
/// whole dashboard, which is the opposite of what was asked for.
const String kDashboardConfiguredMarker = '${kDashboardTilePrefix}__configured__';

class DashboardTile {
  /// Stored in rolemenuaccess.menulabel. Fixed forever.
  final String key;

  /// What Roles & Access shows. Display-only.
  final String label;
  final String icon;

  const DashboardTile(this.key, this.label, this.icon);
}

/// The KPI cards across the top, in the order they appear.
const List<DashboardTile> kDashboardCards = [
  DashboardTile('${kDashboardTilePrefix}students', 'Total Students', 'people'),
  DashboardTile('${kDashboardTilePrefix}demand', 'Total Fees Due', 'receipt-2'),
  DashboardTile('${kDashboardTilePrefix}collected', 'Total Collected', 'money-recive'),
  DashboardTile('${kDashboardTilePrefix}misc', 'Misc Collection', 'receipt-2'),
  DashboardTile('${kDashboardTilePrefix}advance', 'Advance Collection', 'empty-wallet-add'),
  DashboardTile('${kDashboardTilePrefix}fine', 'Fine Collected', 'receipt-edit'),
  DashboardTile('${kDashboardTilePrefix}concession', 'Concession', 'discount-shape'),
  DashboardTile('${kDashboardTilePrefix}today', 'Today Collection', 'calendar-1'),
  DashboardTile('${kDashboardTilePrefix}pendingapproval', 'Pending Approval', 'money-remove'),
  DashboardTile('${kDashboardTilePrefix}outstanding', 'Outstanding', 'wallet-money'),
];

/// The charts and panels below the cards.
const List<DashboardTile> kDashboardPanels = [
  DashboardTile('${kDashboardTilePrefix}chart_overview', 'Collection Overview (chart)', 'chart-1'),
  DashboardTile('${kDashboardTilePrefix}chart_mode', 'Collection by Mode (chart)', 'grid-1'),
  DashboardTile('${kDashboardTilePrefix}recent', 'Recent Payments', 'receipt-2'),
  DashboardTile('${kDashboardTilePrefix}quickactions', 'Quick Actions', 'grid-1'),
  DashboardTile('${kDashboardTilePrefix}todaysummary', "Today's Summary", 'calendar-1'),
];

List<DashboardTile> get kAllDashboardTiles => [...kDashboardCards, ...kDashboardPanels];

/// The sections Roles & Access renders, in order.
const Map<String, List<DashboardTile>> kDashboardTileSections = {
  'DASHBOARD · CARDS': kDashboardCards,
  'DASHBOARD · CHARTS & PANELS': kDashboardPanels,
};

/// Is [key] granted by [allowed] (the role's rows from rolemenuaccess)?
///
/// Additive, exactly like Menu Access: a role nobody has configured keeps the
/// whole dashboard, so shipping this changes nothing for anyone until an Admin
/// saves. Once saved, the marker is present and the ticks decide.
bool dashboardTileAllowed(Set<String>? allowed, String key) {
  if (allowed == null) return true; // not loaded yet — don't blank the page
  if (!allowed.contains(kDashboardConfiguredMarker)) return true;
  return allowed.contains(key);
}

/// True when this role has had its dashboard configured at all.
bool dashboardConfigured(Set<String>? allowed) =>
    allowed != null && allowed.contains(kDashboardConfiguredMarker);
