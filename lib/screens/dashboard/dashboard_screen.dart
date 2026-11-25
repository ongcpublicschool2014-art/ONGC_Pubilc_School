
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/app_menu.dart';
import '../../utils/module_control.dart';
import '../../utils/school_terms.dart';
import '../../utils/app_routes.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../models/student_model.dart';
import '../students/students_screen.dart';
import 'dashboard_overview_screen.dart';

import '../admin/master_import_screen.dart';
import '../fees/student_fee_collection_screen.dart';
import '../transactions/failed_transactions_screen.dart';
import '../admin/admin_creation_screen.dart';
import '../admin/roles_access_screen.dart';
import '../admin/bank_details_screen.dart';
import '../notices/notices_screen.dart';
import '../notifications/notification_screen.dart';
import '../fees/fee_demand_screen.dart';
import '../fees/fee_demand_approval_screen.dart';
import '../fees/fee_demand_import_screen.dart';
import '../admin/master_data_screen.dart';
import '../admin/utilities_screen.dart';
import '../admin/payment_gateways_screen.dart';
import '../fees/bank_reconciliation_screen.dart';
import '../fees/reports_screen.dart';
import '../reports/admission_register_screen.dart';
import '../reports/tc_report_screen.dart';
import '../reports/consolidated_summary_screen.dart';
import '../reports/receiptwise_report_screen.dart';
import '../reports/receiptwise_abstract_screen.dart';
import '../reports/datewise_abstract_screen.dart';
import '../reports/dcb_classwise_screen.dart';
import '../transport/transport_setup_screen.dart';
import '../transport/routes_stops_screen.dart';
import '../transport/vehicles_screen.dart';
import '../transport/transport_staff_screen.dart';
import '../admin/staff_screen.dart';
import '../attendance/attendance_entry_screen.dart';
import '../attendance/attendance_report_screen.dart';
import '../attendance/attendance_setup_screen.dart';
import '../attendance/leave_outpass_screen.dart';
import '../transport/trip_schedules_screen.dart';
import '../transport/duty_roster_screen.dart';
import '../transport/daily_trips_screen.dart';
import '../transport/student_enrollment_screen.dart';
import '../transport/vehicle_allotment_screen.dart';
import '../transport/stage_fees_screen.dart';
import '../reports/division_summary_screen.dart';
import '../reports/fee_matrix_screen.dart';
import '../reports/pending_fee_report_screen.dart';
import '../reports/advance_reconciliation_report_screen.dart';
import '../tc/tc_certificate_screen.dart';
import '../tc/tc_format_screen.dart';
import '../admin/receipt_format_screen.dart';
import '../tc/tc_list_screens.dart';
import '../fees/fee_master_screen.dart';
import '../fees/fee_concession_screen.dart';
import '../fees/concession_approval_screen.dart';
import '../fees/fee_refund_screen.dart';
import '../fees/fee_cancel_screen.dart';
import '../fees/misc_collection_screen.dart';
import '../fees/advance_collection_screen.dart';
import '../fees/advance_fee_collection_screen.dart';
import '../fees/advance_adjustment_screen.dart';
import '../fees/advance_reconcile_screen.dart';
import '../admin/year_end_screen.dart';
import '../admin/sequence_master_screen.dart';
import '../admission/admission_screen.dart';
import '../admission/fast_admission_screen.dart';
import '../admission/section_allocation_tabs.dart';
import '../admission/interim_promotion_screen.dart';
import '../admission/transfer_certificate_screen.dart';
import '../admission/new_rollno_screen.dart';
import '../admission/emis_umis_screen.dart';
import '../admission/admission_master_screen.dart';



import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/student_avatar.dart';
import '../../widgets/update_dialog.dart';
import '../../utils/friendly_error.dart';
import '../../services/pending_collection_sweep.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _selectedNavIndex = 0;
  int _selectedSubIndex = 0;
  int? _expandedNavIndex;
  bool _sidebarCollapsed = false;
  // Which sidebar sections are expanded (accordion). Empty = all collapsed,
  // so the menu opens showing just Dashboard + the group headers.
  final Set<String> _expandedSections = {};

  /// Sidebar groups inside a section (AppNavItem.group), keyed 'SECTION/Group':
  /// opened by the user, or closed by the user while holding the open page
  /// (that group starts open).
  final Set<String> _openGroups = {};
  final Set<String> _closedGroups = {};

  // Section header icon + display label for the collapsible menu groups.
  // MAIN MENU has no header — its items (Dashboard) render standalone at top.
  // Section icons/labels come from kSectionMeta in lib/utils/app_menu.dart.

  // Notification unread count
  int _unreadNotifCount = 0;
  String _academicYear = '';
  List<Map<String, dynamic>> _availableYears = [];

  // Sidebar nav scrolling — shows a bottom down-arrow cue when more menu
  // items exist below the fold.
  final ScrollController _navScrollCtrl = ScrollController();
  bool _navMoreBelow = false;
  bool _navMoreAbove = false;
  // The open screen's menu tile, scrolled into view when it changes.
  final GlobalKey _activeTileKey = GlobalKey();
  final GlobalKey _activeSubKey = GlobalKey();
  (int, int)? _revealedNav;

  // Bumped by the header Refresh button. It's the key of the content subtree,
  // so incrementing it re-mounts the current screen from scratch — re-running
  // its initState and therefore reloading its data.
  int _refreshTick = 0;
  bool _refreshing = false;

  // Global search
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final LayerLink _searchLayerLink = LayerLink();
  OverlayEntry? _searchOverlay;
  List<StudentModel> _allStudents = [];
  List<StudentModel> _searchResults = [];


  late List<AppNavItem> _navItems;

  /// Menus this user's role is allowed to open, loaded from rolemenuaccess.
  /// null = never configured for this role -> fall back to the built-in
  /// defaults below, so existing installs behave exactly as before.
  Set<String>? _allowedMenus;

  /// Menus the vendor switched off for this institution (Module Control,
  /// public.modules / activitytype). Hidden for every role, Admin included.
  Set<String> _disabledMenus = {};

  /// Load the Roles & Access grants for the logged-in user's role.
  Future<void> _loadMenuAccess() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    final urId = auth.currentUser?.urId;
    if (insId == null || urId == null) return;
    final off = await loadDisabledMenus(insId);
    if (!mounted) return;
    if (off.length != _disabledMenus.length || !off.containsAll(_disabledMenus)) {
      setState(() => _disabledMenus = off);
    }
    final access = await SupabaseService.getRoleMenuAccess(insId);
    if (!mounted) return;
    final allowed = access[urId];
    if (allowed == null || allowed.isEmpty) return; // unconfigured -> defaults
    setState(() => _allowedMenus = allowed);
  }

  /// Full refresh from the header button: reload the shell's own state (year,
  /// unread notifications, role access) and re-mount the current screen so its
  /// data re-fetches. Bumping [_refreshTick] changes the content subtree's key,
  /// which disposes the old screen and builds a fresh one (re-running initState).
  Future<void> _refreshApp() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await Future.wait([
        _loadUnreadNotifCount(),
        _loadAcademicYear(),
        _loadMenuAccess(),
      ]);
    } catch (_) {
      // Shell reloads are best-effort; the screen re-mount below still happens.
    }
    if (!mounted) return;
    setState(() {
      _refreshTick++;
      _refreshing = false;
    });
  }

  /// Role-filtered menus, minus the school-only ones on a college.
  List<AppNavItem> _getNavItems(BuildContext context) => _getRoleNavItems(context)
      .where((i) => !(isSchool ? kSchoolHiddenNavItems : kCollegeHiddenSubItems).contains(i.label))
      .where((i) => !_disabledMenus.contains(i.label))
      .toList();

  List<AppNavItem> _getRoleNavItems(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final isAdmin = auth.currentUser?.urname == 'Admin';
    final isAccountant = auth.currentUser?.urname == 'Accountant';

    // A role has been configured in Roles & Access — that list wins over the
    // defaults. For Admin the never-revocable menus are forced back in, so an
    // Admin can slim their own sidebar but never lock every Admin out.
    final allowed = _allowedMenus;
    if (allowed != null) {
      final effective = isAdmin ? {...allowed, ...kAlwaysAllowedForAdmin} : allowed;
      // Dashboard obeys the grant like every other menu — no force-include.
      // Roles configured before Dashboard became assignable are backfilled by
      // migrations/rolemenuaccess_dashboard.sql so none of them lose it.
      return kAppNavItems.where((item) => effective.contains(item.label)).toList();
    }

    // Never configured — Admin sees everything except accountant-only screens.
    if (isAdmin) return kAppNavItems.where((item) => !item.accountantOnly).toList();

    // Never configured — built-in defaults.
    return kAppNavItems.where((item) {
      if (item.adminOnly) return false;
      if (item.accountantOnly && !isAccountant) return false;
      if (item.hideForAccountant && isAccountant) return false;
      return true;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadUnreadNotifCount();
    _loadAcademicYear();
    _loadMenuAccess();
    // One-shot update check after login (silent if up to date / offline).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybePromptUpdate(context);
      // Keep resolving unfinished Paytm collections for as long as the app is
      // open, instead of only when somebody opens the right screen. Started
      // from the dashboard because it outlives every other screen.
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      final insId = auth.insId;
      if (insId != null) {
        PendingCollectionSweep.startAuto(
            insId: insId, sessionToken: auth.sessionToken);
      }
    });
    _navScrollCtrl.addListener(_updateNavMoreBelow);
    _searchFocusNode.addListener(() {
      if (!_searchFocusNode.hasFocus) {
        // Delay removal so overlay tap events can fire first
        Future.delayed(const Duration(milliseconds: 200), () {
          _removeSearchOverlay();
        });
      }
    });
  }

  // Toggles the sidebar up/down arrow cues based on scroll position.
  void _updateNavMoreBelow() {
    if (!_navScrollCtrl.hasClients) return;
    final pos = _navScrollCtrl.position;
    final below = pos.maxScrollExtent > 0 && pos.pixels < pos.maxScrollExtent - 4;
    final above = pos.pixels > 4;
    if ((below != _navMoreBelow || above != _navMoreAbove) && mounted) {
      setState(() {
        _navMoreBelow = below;
        _navMoreAbove = above;
      });
    }
  }

  Future<void> _loadAcademicYear() async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;
    try {
      // Load from institutionyear (public) - all years for this institution
      final result = await SupabaseService.client
          .from('institutionyear')
          .select('yrlabel, iyrstadate, iyrenddate, activestatus')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('yrlabel', ascending: false);
      final years = List<Map<String, dynamic>>.from(result);
      if (years.isNotEmpty && mounted) {
        // Detect current year from active schema
        String currentYear = years.first['yrlabel']?.toString() ?? '';
        final schema = SupabaseService.currentSchema ?? '';
        for (final y in years) {
          final label = y['yrlabel']?.toString() ?? '';
          if (schema.endsWith(label.replaceAll('-', ''))) {
            currentYear = label;
            break;
          }
        }
        setState(() {
          _availableYears = years;
          _academicYear = currentYear;
        });
      }
    } catch (_) {}
  }

  Future<void> _switchYear(String yearLabel) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    // Get institution short name
    final insRow = await SupabaseService.client
        .from('institution')
        .select('inshortname')
        .eq('ins_id', insId)
        .maybeSingle();
    if (insRow == null || insRow['inshortname'] == null) return;

    final shortName = (insRow['inshortname'] as String).toLowerCase();
    final newSchema = '$shortName${yearLabel.replaceAll('-', '')}';

    // New schema everywhere: the client, the screens that re-apply
    // auth.schema on open, and the server session (so RPCs follow it).
    await auth.switchYear(newSchema, yearLabel);
    if (!mounted) return;
    setState(() => _academicYear = yearLabel);

    // Reload all data
    _loadStudentsForSearch();
    _loadUnreadNotifCount();
    // Back to the first menu in the sidebar (Dashboard for most roles, but it
    // can now be hidden) to refresh.
    setState(() => _selectedNavIndex = 0);
  }

  void _showCreateYearDialog() {
    // Auto-calculate next year from current
    final currentParts = _academicYear.split('-');
    final nextStart = currentParts.length == 2 ? int.tryParse(currentParts[1]) ?? (DateTime.now().year + 1) : DateTime.now().year + 1;
    final nextEnd = nextStart + 1;
    final nextLabel = '$nextStart-$nextEnd';

    final startDateCtrl = TextEditingController(text: '$nextStart-06-01');
    final endDateCtrl = TextEditingController(text: '$nextEnd-05-31');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Create New Academic Year', style: AppUI.cardTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New Year: $nextLabel', style: AppUI.label.copyWith(color: AppColors.primary)),
            SizedBox(height: 16.h),
            TextField(
              controller: startDateCtrl,
              decoration: AppUI.field(context, '', label: 'Start Date (YYYY-MM-DD)'),
            ),
            SizedBox(height: 12.h),
            TextField(
              controller: endDateCtrl,
              decoration: AppUI.field(context, '', label: 'End Date (YYYY-MM-DD)'),
            ),
            SizedBox(height: 8.h),
            Text('This will create a new empty schema with all tables.', style: AppUI.muted),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _createNewYear(nextLabel, startDateCtrl.text.trim(), endDateCtrl.text.trim());
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _createNewYear(String yearLabel, String startDate, String endDate) async {
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) return;

    try {
      // Get institution short name
      final insRow = await SupabaseService.client
          .from('institution')
          .select('inshortname')
          .eq('ins_id', insId)
          .maybeSingle();
      if (insRow == null || insRow['inshortname'] == null) return;

      final shortName = (insRow['inshortname'] as String).toLowerCase();
      final schemaName = '$shortName${yearLabel.replaceAll('-', '')}';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Creating schema $schemaName...'), backgroundColor: AppColors.accent),
        );
      }

      await SupabaseService.client.rpc('create_institution_schema', params: {
        'p_schema_name': schemaName,
        'p_ins_id': insId,
        'p_year_label': yearLabel,
        'p_start_date': startDate,
        'p_end_date': endDate,
      });

      // Reload years and switch
      await _loadAcademicYear();
      await _switchYear(yearLabel);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Academic year $yearLabel created successfully!'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e)), backgroundColor: AppColors.error),
        );
      }
    }
  }

  bool _studentsLoaded = false;
  Future<void> _loadStudentsForSearch() async {
    if (_studentsLoaded) return;
    _studentsLoaded = true;
    final auth = context.read<AuthProvider>();
    final insId = auth.insId;
    if (insId == null) { _studentsLoaded = false; return; }
    _allStudents = await SupabaseService.getStudents(insId);
  }

  Future<void> _loadUnreadNotifCount() async {
    try {
      final auth = context.read<AuthProvider>();
      final insId = auth.insId;
      if (insId == null) return;
      // Match the Notifications screen filter — staff-only (stu_id IS NULL).
      // Without this the sidebar badge counted student notifications too,
      // showing 73 while the screen actually displays a much smaller list.
      final rows = await SupabaseService.fromSchema('notification')
          .select('notititle, notibody, notitype, isread')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .isFilter('stu_id', null);
      // Group by title+body+type. If ANY row in a group is read, the whole
      // group is treated as read — matches the dedupe behavior on the
      // notifications screen and keeps the badge in sync after the user
      // opens a notification.
      final allKeys = <String>{};
      final readKeys = <String>{};
      for (final n in (rows as List)) {
        final key = '${n['notititle']}|${n['notibody']}|${n['notitype']}';
        allKeys.add(key);
        if (n['isread'] == true || n['isread'] == 1) {
          readKeys.add(key);
        }
      }
      final unread = allKeys.length - readKeys.length;
      if (mounted) setState(() => _unreadNotifCount = unread);
    } catch (_) {}
  }

  void _onSearchChanged(String query) async {
    if (query.trim().isEmpty) {
      _removeSearchOverlay();
      _searchResults = [];
      return;
    }
    // Lazy load students on first search
    if (!_studentsLoaded) await _loadStudentsForSearch();
    final q = query.toLowerCase();
    _searchResults = _allStudents.where((s) =>
      s.stuname.toLowerCase().contains(q) ||
      s.stuadmno.toLowerCase().contains(q)
    ).take(10).toList();
    _showSearchOverlay();
  }

  void _showSearchOverlay() {
    _removeSearchOverlay();
    if (_searchResults.isEmpty) return;
    _searchOverlay = OverlayEntry(builder: (context) => _buildSearchOverlay());
    Overlay.of(context).insert(_searchOverlay!);
  }

  void _removeSearchOverlay() {
    _searchOverlay?.remove();
    _searchOverlay = null;
  }

  StudentModel? _navigateToStudent;

  void _onStudentSelected(StudentModel student) {
    _removeSearchOverlay();
    _searchController.clear();
    _searchFocusNode.unfocus();
    // Found by label, not a fixed index: the sidebar is built from the role's
    // grants, so Students is not always second (and may be absent entirely).
    final idx = _navItems.indexWhere((i) => i.label == 'Students');
    if (idx < 0) return;
    setState(() {
      _navigateToStudent = student;
      _selectedNavIndex = idx;
    });
  }


  Widget _buildSearchOverlay() {
    return Positioned(
      width: 350.w,
      child: CompositedTransformFollower(
        link: _searchLayerLink,
        showWhenUnlinked: false,
        offset: Offset(0, 48.h),
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: BoxConstraints(maxHeight: 400.h),
            decoration: AppUI.card(radius: 12),
            child: ListView.builder(
              padding: EdgeInsets.symmetric(vertical: 4.h),
              shrinkWrap: true,
              itemCount: _searchResults.length,
              itemBuilder: (context, index) {
                final s = _searchResults[index];
                return InkWell(
                  onTap: () => _onStudentSelected(s),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
                    child: Row(
                      children: [
                        StudentAvatar(
                          photoUrl: (s.stuphoto?.startsWith('http') ?? false) ? s.stuphoto : null,
                          name: s.stuname,
                          size: 36,
                          enlargeOnTap: false, // tapping the row opens the student
                        ),
                        SizedBox(width: 12.w),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.stuname, style: AppUI.label),
                              Text(schoolTerm('${s.stuadmno}  •  Class ${s.stuclass}'), style: AppUI.muted),
                            ],
                          ),
                        ),
                        Text(s.stumobile, style: AppUI.muted),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _navScrollCtrl.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _removeSearchOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _navItems = _getNavItems(context);
    _revealActiveNav();
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 800;
    final isTablet = size.width > 500 && size.width <= 800;
    // Tablet width (and narrow windows): the sidebar collapses to icons on
    // its own; menus with sub-items open them in a pop-out (see _openFlyout).
    final autoCollapse = size.width <= 1100;

    // Clamp selected index if nav items changed (e.g. role-based filtering)
    if (_selectedNavIndex >= _navItems.length) {
      _selectedNavIndex = 0;
    }

    return Scaffold(
      backgroundColor: AppColors.surface,
      drawer: (!isDesktop && !isTablet)
          ? Drawer(child: ExcludeFocus(child: _buildSidebar(context, false)))
          : null,
      body: Row(
        children: [
          // Sidebar
          if (isDesktop || isTablet)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: (_sidebarCollapsed || autoCollapse) ? 78 : (isDesktop ? (size.width < 1400 ? 230 : 270) : 78),
              // Keep the sidebar out of keyboard Tab traversal so tabbing
              // through a form's fields doesn't jump into the nav menu between
              // rows. Items remain mouse-clickable.
              child: ExcludeFocus(
                // Icons only until the opening animation is wide enough for
                // the labels (they overflowed for the first frames).
                child: LayoutBuilder(
                  builder: (context, box) => _buildSidebar(context,
                      _sidebarCollapsed || isTablet || autoCollapse || box.maxWidth < 200),
                ),
              ),
            ),

          // Main content
          Expanded(
            child: Column(
              children: [
                // Top bar — kept out of Tab traversal (collapse/menu, bell,
                // account are mouse-operated) so tabbing stays inside the form.
                ExcludeFocus(child: _buildTopBar(context, isDesktop)),

                // Content area. Wrapped in a FocusTraversalGroup so a page's
                // form fields tab as one contiguous unit (reading order),
                // independent of any surrounding chrome (sidebar / top bar).
                Expanded(
                  child: FocusTraversalGroup(
                    // Keyed on _refreshTick so the header Refresh button can
                    // re-mount the whole content subtree (fresh initState +
                    // data reload) just by incrementing the tick.
                    child: KeyedSubtree(
                      key: ValueKey('content-$_refreshTick'),
                      child: _isFullHeightScreen()
                          ? Padding(
                              // The dashboard's own spacing (redesign spec): 30 top /
                              // 46 right / 30 bottom / 36 left on a full-size window.
                              padding: MediaQuery.of(context).size.width <= 1366
                                  ? const EdgeInsets.all(20)
                                  : _navItems[_selectedNavIndex].label == 'Dashboard'
                                      ? const EdgeInsets.fromLTRB(28, 18, 28, 18)
                                      : const EdgeInsets.all(32),
                              child: _buildDashboardContent(context, isDesktop),
                            )
                          : SingleChildScrollView(
                              padding: EdgeInsets.all(MediaQuery.of(context).size.width <= 1366 ? 20 : 32),
                              child: _buildDashboardContent(context, isDesktop),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context, bool collapsed) {
    // After layout, refresh the "more below" cue (handles the initial render
    // where the list is scrollable but hasn't been scrolled yet).
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateNavMoreBelow());
    // Group visible nav items by section, preserving insertion order.
    final orderedSections = <String>[];
    final groupedIndices = <String, List<int>>{};
    for (var i = 0; i < _navItems.length; i++) {
      final section = _navItems[i].section;
      if (!groupedIndices.containsKey(section)) {
        orderedSections.add(section);
        groupedIndices[section] = [];
      }
      groupedIndices[section]!.add(i);
    }

    final hPad = collapsed
        // Fixed (non-.w) inside the fixed 78px rail — scaled units overflow it.
        ? 10.0
        : (MediaQuery.of(context).size.width < 1100 ? 10.w : 14.w);

    return Container(
      decoration: BoxDecoration(
        // Light teal menu (user, 2026-10-31).
        color: AppColors.menuBg,
        border: const Border(right: BorderSide(color: AppColors.menuBorder, width: 1)),
      ),
      child: Stack(children: [
        // School picture at the foot of the menu, fading up into the green
        // (user's design, 2026-10-31). Behind the items, never takes clicks.
        if (!collapsed)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (r) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black],
                  stops: [0.0, 0.3],
                ).createShader(r),
                // A faint watermark behind the menu items.
                child: Image.asset(
                  'assets/images/sidebar_school.jpg',
                  fit: BoxFit.fitWidth,
                  opacity: const AlwaysStoppedAnimation(0.16),
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        Column(
        children: [
          // Logo area
          Container(
            padding: EdgeInsets.symmetric(
              // Collapsed sidebar is a fixed 78px, so use fixed (non-.w) sizes
              // here — scaled units overflow the fixed width on some screens.
              horizontal: collapsed ? 12 : (MediaQuery.of(context).size.width < 1100 ? 14.w : 24.w),
              vertical: 20.h,
            ),
            child: Row(
              children: [
                // Cream plate with a marigold ring behind the logo (the mark is
                // dark on a transparent PNG and would sink into the dark teal).
                ClipRRect(
                  borderRadius: BorderRadius.circular(collapsed ? 10 : 12),
                  child: Container(
                    width: collapsed ? 46 : 56.w,
                    height: collapsed ? 46 : 56.h,
                    decoration: BoxDecoration(
                      color: AppColors.onPrimary,
                      borderRadius: BorderRadius.circular(collapsed ? 10 : 12),
                      border: Border.all(color: AppColors.gold, width: 2),
                    ),
                    padding: EdgeInsets.all(collapsed ? 3 : 4),
                    child: Image.asset(
                      'assets/images/app_logo_mark.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => AppIcon('teacher',
                        color: AppColors.primary,
                        size: 16,
                      ),
                    ),
                  ),
                ),
                if (!collapsed) ...[
                  SizedBox(width: 10.w),
                  Flexible(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(text: 'FIT ', style: AppFonts.heading(size: 20.sp, color: AppColors.menuBrandFit)),
                          TextSpan(text: 'School', style: AppFonts.heading(size: 20.sp, color: AppColors.menuBrandSchool)),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(isSchool ? 'SCHOOL ERP' : 'COLLEGE ERP',
                          style: TextStyle(fontSize: 9.5.sp, fontWeight: FontWeight.w800, letterSpacing: 2.2, color: AppColors.menuMuted)),
                    ]),
                  ),
                ],
              ],
            ),
          ),

          // Nav items grouped by section. The default desktop scrollbar is
          // suppressed so the sidebar reads as a flat menu — items still
          // scroll via mouse wheel / trackpad, just without a visible bar.
          Expanded(
            child: Stack(
              children: [
                // While the menu scrolls, the "more above / below" pills get
                // their own 30px at the top and bottom instead of covering a
                // menu item (the active one could be hidden under them).
                Padding(
                  padding: EdgeInsets.symmetric(vertical: (_navMoreAbove || _navMoreBelow) ? 30 : 0),
                  // items fade out at a scrolled edge instead of showing a
                  // half-cut label under the "more" bar
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (r) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _navMoreAbove ? Colors.transparent : Colors.black,
                        Colors.black,
                        Colors.black,
                        _navMoreBelow ? Colors.transparent : Colors.black,
                      ],
                      stops: [0, r.height <= 0 ? 0 : (22 / r.height).clamp(0.0, 0.5), r.height <= 0 ? 1 : (1 - 22 / r.height).clamp(0.5, 1.0), 1],
                    ).createShader(r),
                    child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: ListView(
                controller: _navScrollCtrl,
                padding: EdgeInsets.zero,
                children: [
                  // The items sit on the menu colour, so the school picture
                  // shows only in the free space below them and never behind
                  // a label (an open Reports group reached down over it).
                  ColoredBox(
                    // see-through: the picture is a watermark behind the items
                    color: Colors.transparent,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: hPad),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (var s = 0; s < orderedSections.length; s++) ...[
                    if (collapsed) ...[
                      // Icon-only sidebar: keep the flat grouped layout.
                      SizedBox(height: s == 0 ? 4.h : 18.h),
                      for (final idx in groupedIndices[orderedSections[s]]!)
                        _buildNavTile(context, idx, collapsed),
                    ] else if (orderedSections[s] == 'MAIN MENU' ||
                        groupedIndices[orderedSections[s]]!.length < 2) ...[
                      // Standalone items — no group header. Applies to MAIN MENU
                      // (Dashboard) and to any section holding a single item:
                      // wrapping one item in a collapsible group of the same
                      // name just makes the user expand "Reports" to reach
                      // "Reports".
                      SizedBox(height: 4.h),
                      for (final idx in groupedIndices[orderedSections[s]]!)
                        _buildNavTile(context, idx, collapsed),
                      SizedBox(height: 4.h),
                    ] else ...[
                      // Collapsible group: header toggles its items. Items render
                      // as indented, smaller sub-tiles so they read as children.
                      _buildSectionHeader(context, orderedSections[s]),
                      if (_expandedSections.contains(orderedSections[s]))
                        ..._sectionTiles(context, orderedSections[s], groupedIndices[orderedSections[s]]!),
                    ],
                  ],
                  SizedBox(height: 16.h),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
                  ),
                ),
                // Full-width amber bar at the TOP when there are items above.
                if (_navMoreAbove)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: GestureDetector(
                      onTap: () {
                        _navScrollCtrl.animateTo(
                          (_navScrollCtrl.offset - 180).clamp(0.0, _navScrollCtrl.position.maxScrollExtent),
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                      },
                      child: Container(
                        height: 26,
                        margin: EdgeInsets.symmetric(horizontal: 20.w),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [AppColors.gold, AppColors.goldDark],
                          ),
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.gold.withValues(alpha: 0.40),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.keyboard_arrow_up, size: 18, color: AppColors.onGold),
                      ),
                    ),
                  ),
                // Full-width amber bar at the BOTTOM when more items are below.
                if (_navMoreBelow)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: () {
                        final pos = _navScrollCtrl.position;
                        _navScrollCtrl.animateTo(
                          (_navScrollCtrl.offset + 180).clamp(0.0, pos.maxScrollExtent),
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                      },
                      child: Container(
                        height: 26,
                        margin: EdgeInsets.symmetric(horizontal: 20.w),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [AppColors.gold, AppColors.goldDark],
                          ),
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.gold.withValues(alpha: 0.40),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.keyboard_arrow_down, size: 18, color: AppColors.onGold),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      ]),
    );
  }

  /// Collapsible section header (Admin / Admission / Students / Fees / General).
  /// Tapping toggles the group's items. Highlights when it holds the active
  /// page but is collapsed, so the user still sees where they are.
  Widget _buildSectionHeader(BuildContext context, String section) {
    final meta = kSectionMeta[section];
    final icon = meta != null ? meta[0] : 'category';
    final label = meta != null ? meta[1] : section;
    final expanded = _expandedSections.contains(section);
    final containsSelected = _navItems[_selectedNavIndex].section == section;
    // The group holding the open page stays highlighted, open or closed.
    final highlight = containsSelected;
    return Padding(
      padding: EdgeInsets.only(bottom: 7.h),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() {
            if (expanded) {
              _expandedSections.remove(section);
            } else {
              // Single-open accordion: opening a group collapses the others.
              _expandedSections
                ..clear()
                ..add(section);
            }
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 10.h),
            decoration: BoxDecoration(
              // The group holding the active page (while closed) is the
              // cream active item with a gold edge; an open group a faint tint.
              color: highlight
                  ? AppColors.menuActiveBg
                  : (expanded ? AppColors.menuOpenBg : Colors.transparent),
              border: highlight ? const Border(left: BorderSide(color: AppColors.menuActiveEdge, width: 3)) : null,
              borderRadius: BorderRadius.circular(10),
              boxShadow: highlight ? _activeShadow : null,
            ),
            child: Row(
              children: [
                AppIcon.linear(icon, size: 20.sp, color: highlight ? AppColors.menuActiveText : AppColors.menuText),
                SizedBox(width: 12.w),
                // One line: a long group name ("Transfer Certificate") shrinks a
                // little rather than wrapping and growing into its neighbours.
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w700,
                        color: highlight ? AppColors.menuActiveText : AppColors.menuText,
                      ),
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: expanded ? -0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  // Same caret the form dropdowns use (Icons.arrow_drop_down),
                  // so "this opens" reads the same everywhere in the app.
                  child: Icon(
                    Icons.arrow_drop_down,
                    size: 24,
                    color: highlight ? AppColors.menuActiveText : AppColors.menuMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// An open section's items. Those sharing an [AppNavItem.group] sit under
  /// a small collapsible heading (Reports > Collection > Daily Collection), at
  /// the place of the group's first item; a group of one is just its item.
  List<Widget> _sectionTiles(BuildContext context, String section, List<int> idxs) {
    final out = <Widget>[];
    final done = <String>{};
    for (final i in idxs) {
      final g = _navItems[i].group;
      if (g == null) {
        out.add(_buildNavTile(context, i, false, inSection: true));
        continue;
      }
      if (!done.add(g)) continue;
      final members = [for (final j in idxs) if (_navItems[j].group == g) j];
      if (members.length == 1) {
        out.add(_buildNavTile(context, members.first, false, inSection: true));
        continue;
      }
      final key = '$section/$g';
      final holdsPage = members.contains(_selectedNavIndex);
      final open = holdsPage ? !_closedGroups.contains(key) : _openGroups.contains(key);
      out.add(_buildGroupHeader(key, g, members.length, open: open, holdsPage: holdsPage));
      if (open) {
        out.add(Padding(
          padding: EdgeInsets.only(left: 14.w),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final j in members) _buildNavTile(context, j, false, inSection: true),
          ]),
        ));
      }
    }
    return out;
  }

  /// The heading of a group inside a section: its icon, name, how many items
  /// it holds and a caret. Tinted while closed over the open page.
  Widget _buildGroupHeader(String key, String title, int count, {required bool open, required bool holdsPage}) {
    final fg = holdsPage && !open ? AppColors.menuSubActive : AppColors.menuText;
    return Padding(
      padding: EdgeInsets.only(bottom: 3.h, left: 2.w),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _navRail(false),
          SizedBox(width: 2.w),
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('nav-group-$key'),
                canRequestFocus: false,
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() {
                  if (open) {
                    _openGroups.remove(key);
                    _closedGroups.add(key);
                  } else {
                    _closedGroups.remove(key);
                    _openGroups.add(key);
                  }
                }),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 7.w, vertical: 6.h),
                  decoration: BoxDecoration(
                    color: holdsPage && !open ? AppColors.menuSubActiveBg : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    SizedBox(
                      width: 25.w,
                      height: 25.w,
                      child: Center(
                        child: AppIcon(kNavGroupIcons[title] ?? 'folder-2', style: AppIconStyle.linear, color: fg,
                            size: (MediaQuery.of(context).size.width <= 1366 ? 18.sp : 20.sp) - 3),
                      ),
                    ),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(title, maxLines: 1, style: TextStyle(fontSize: 12.5.sp, fontWeight: FontWeight.w800, color: fg)),
                      ),
                    ),
                    Text('$count', style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w700, color: AppColors.menuMuted)),
                    SizedBox(width: 2.w),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(Icons.keyboard_arrow_down, size: 18.sp, color: fg.withValues(alpha: 0.9)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// Soft lift under the active (cream) menu item.
  static final List<BoxShadow> _activeShadow = [
    BoxShadow(color: AppColors.primary.withValues(alpha: 0.14), blurRadius: 10, offset: const Offset(0, 3)),
  ];

  /// Timeline rail for a sub-menu item — a continuous vertical line with a blue
  /// dot, so an expanded section's children read as a connected list (mockup).
  Widget _navRail(bool selected) {
    final w = 16.w;
    return SizedBox(
      width: w,
      child: Stack(children: [
        // dashed tree line linking the sub-items
        Positioned(top: 0, bottom: 0, left: w / 2 - 0.5, width: 1, child: const CustomPaint(painter: _DashedVLine(AppColors.menuTreeLine))),
        Positioned.fill(child: Center(child: Container(
          width: selected ? 8.w : 5.w, height: selected ? 8.w : 5.w,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? AppColors.gold : AppColors.menuTreeLine,
          ),
        ))),
      ]),
    );
  }

  /// After the open screen changes, scroll the sidebar (only if needed) so
  /// its menu item is in view rather than hidden below the "more" bar.
  void _revealActiveNav() {
    final now = (_selectedNavIndex, _selectedSubIndex);
    if (_revealedNav == now) return;
    _revealedNav = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _activeSubKey.currentContext ?? _activeTileKey.currentContext;
      if (ctx == null || !_navScrollCtrl.hasClients) return;
      final item = ctx.findRenderObject() as RenderBox?;
      final view = Scrollable.maybeOf(ctx)?.context.findRenderObject() as RenderBox?;
      if (item == null || view == null || !item.attached || !view.attached) return;
      // Leave it alone when it is already clear of the faded edges (28px);
      // otherwise bring it to the middle of the menu.
      final top = item.localToGlobal(Offset.zero, ancestor: view).dy;
      if (top >= 28 && top + item.size.height <= view.size.height - 28) return;
      Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  Widget _buildNavTile(BuildContext context, int index, bool collapsed, {bool inSection = false}) {
    final item = _navItems[index];
    final isSelected = _selectedNavIndex == index;
    final hasSubItems = item.visibleSubItems.isNotEmpty;
    final isExpanded = !collapsed && hasSubItems && _expandedNavIndex == index;
    final badge = item.label == 'Notifications' && _unreadNotifCount > 0
        ? _unreadNotifCount.toString()
        : null;
    // A tile shown under an expanded section header is a child: indent it,
    // shrink it, and dim it so it reads as a sub-menu, not a top-level menu.
    final sub = inSection && !collapsed;

    // An active top-level item is a teal pill with a marigold edge; an
    // active sub-item is teal text on a soft teal tint.
    final selectedBg = sub ? AppColors.menuSubActiveBg : AppColors.menuActiveBg;
    final selectedFg = sub ? AppColors.menuSubActive : AppColors.menuActiveText;
    final unselectedFg = sub ? AppColors.menuSubText : AppColors.menuText;

    final iconSize = (MediaQuery.of(context).size.width <= 1366 ? 18.sp : 20.sp) - (sub ? 3 : 0);

    final content = Builder(builder: (tileCtx) => Material(
            color: Colors.transparent,
            child: InkWell(
              // Mouse-only: never take keyboard focus, so Tab in a form never
              // lands on a nav item.
              canRequestFocus: false,
              onTap: () {
                // Icon-only sidebar: a menu with sub-items opens them in a
                // pop-out beside the icon instead of an accordion.
                if (collapsed && hasSubItems) {
                  _openFlyout(tileCtx, index, item);
                  return;
                }
                setState(() {
                  if (_selectedNavIndex != index) _selectedSubIndex = 0;
                  _selectedNavIndex = index;
                  if (hasSubItems && !collapsed) {
                    _expandedNavIndex = isExpanded ? null : index;
                  } else {
                    _expandedNavIndex = null;
                  }
                });
                _loadUnreadNotifCount();
              },
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: EdgeInsets.symmetric(
                  // Fixed inside the 78px rail (see hPad note) so it never overflows.
                  horizontal: collapsed ? 8.0 : (sub ? 7.w : 10.w),
                  vertical: sub ? 6.h : 7.h,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? selectedBg : Colors.transparent,
                  border: isSelected && !sub ? const Border(left: BorderSide(color: AppColors.menuActiveEdge, width: 3)) : null,
                  borderRadius: BorderRadius.circular(sub ? 8 : 10),
                  boxShadow: isSelected && !sub ? _activeShadow : null,
                ),
                child: Row(
                  children: [
                    // Rounded icon chip (mockup style). Sub-items get a smaller,
                    // borderless chip so they read as children.
                    Container(
                      // Fixed size when collapsed so the icon chip + padding
                      // always fit the fixed 78px rail (avoids a RenderFlex overflow).
                      width: collapsed ? 36.0 : (sub ? 25.w : 30.w),
                      height: collapsed ? 36.0 : (sub ? 25.w : 30.w),
                      alignment: Alignment.center,
                      // Plain icons, no chip
                      child: AppIcon(
                        item.unselectedIcon ?? item.icon,
                        style: AppIconStyle.linear,
                        color: isSelected ? selectedFg : unselectedFg,
                        size: iconSize,
                      ),
                    ),
                    if (!collapsed) ...[
                      // Labels start where the group headers' do (14 + 20 + 12).
                      SizedBox(width: sub ? 8.w : 6.w),
                      // A long name shrinks a little to fit rather than end in "...".
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            item.sideNavTitle,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: sub ? 12.5.sp : 14.sp,
                              color: isSelected ? selectedFg : unselectedFg,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 2.h),
                          decoration: BoxDecoration(
                            color: AppColors.gold,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(badge,
                              style: TextStyle(fontSize: 11.sp, color: AppColors.onGold, fontWeight: FontWeight.w800)),
                        ),
                        SizedBox(width: 6.w),
                      ],
                      // Trailing affordance: expandable → rotating chevron;
                      // navigable → a right chevron.
                      if (hasSubItems)
                        AnimatedRotation(
                          turns: isExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: Icon(Icons.keyboard_arrow_down, size: 20.sp, color: (isSelected ? selectedFg : unselectedFg).withValues(alpha: 0.9)),
                        )
                      else if (!sub)
                        Icon(Icons.chevron_right, size: 18.sp, color: (isSelected ? selectedFg : unselectedFg).withValues(alpha: isSelected ? 0.95 : 0.5)),
                    ],
                  ],
                ),
              ),
            ),
          ));
    final tile = Padding(
      padding: EdgeInsets.only(bottom: sub ? 3.h : 7.h, left: sub ? 2.w : 0),
      child: sub
          // A section child can itself have sub-items (Setup > Fee Master >
          // Fee Group). The submenu sits OUTSIDE the IntrinsicHeight — that
          // only needs to size the tile row against its nav rail, and giving it
          // a growing child to measure is what breaks IntrinsicHeight layouts.
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _navRail(isSelected),
                  SizedBox(width: 2.w),
                  Expanded(child: KeyedSubtree(key: isSelected ? _activeTileKey : null, child: content)),
                ]),
              ),
              if (isExpanded) _buildSubMenu(context, index, item),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              KeyedSubtree(key: isSelected ? _activeTileKey : null, child: content),
              if (isExpanded) _buildSubMenu(context, index, item),
            ]),
    );
    // Collapsed sidebar hides labels, so surface each item's name on hover.
    return collapsed
        ? Tooltip(
            message: item.navTitle,
            waitDuration: const Duration(milliseconds: 300),
            // Push clear of the fixed 78px sidebar so the pill sits to the
            // right of the icon rather than overlapping the rail.
            margin: const EdgeInsets.only(left: 84),
            verticalOffset: 14,
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(8.r),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            textStyle: TextStyle(
              color: AppColors.textOnPrimary,
              fontSize: 13.sp,
              fontWeight: FontWeight.w600,
            ),
            child: tile,
          )
        : tile;
  }

  /// Collapsed (icon-only) sidebar: the sub-items of [item] in a pop-out to
  /// the right of its icon. Picking one opens it, as the accordion does.
  Future<void> _openFlyout(BuildContext tileCtx, int index, AppNavItem item) async {
    final box = tileCtx.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(tileCtx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final at = box.localToGlobal(Offset(box.size.width + 14, 0), ancestor: overlay);
    final picked = await showMenu<int>(
      context: tileCtx,
      position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx, 0),
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
      items: [
        PopupMenuItem<int>(
          enabled: false,
          height: 34,
          child: Text(item.navTitle.toUpperCase(), style: AppUI.caps),
        ),
        for (var s = 0; s < item.visibleSubItems.length; s++)
          PopupMenuItem<int>(
            value: s,
            height: 42,
            child: Builder(builder: (_) {
              final sub = item.visibleSubItems[s];
              final on = _selectedNavIndex == index && _selectedSubIndex == s;
              return Row(children: [
                AppIcon(sub.icon,
                    size: 17,
                    style: on ? AppIconStyle.bold : AppIconStyle.linear,
                    color: on ? AppColors.primary : AppColors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(sub.navTitle,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                          color: on ? AppColors.primary : AppColors.textPrimary)),
                ),
              ]);
            }),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedNavIndex = index;
      _selectedSubIndex = picked;
      _expandedNavIndex = null;
    });
    _loadUnreadNotifCount();
  }

  Widget _buildSubMenu(BuildContext context, int parentIndex, AppNavItem item) {
    // The selected item is teal text on a soft teal tint.
    const selectedFg = AppColors.menuSubActive;
    const unselectedFg = AppColors.menuSubText;
    final isParentSelected = _selectedNavIndex == parentIndex;

    return Padding(
      padding: EdgeInsets.only(top: 6.h, left: 22.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var s = 0; s < item.visibleSubItems.length; s++) ...[
            Builder(builder: (context) {
              final sub = item.visibleSubItems[s];
              final selected = isParentSelected && _selectedSubIndex == s;
              return Material(
                key: selected ? _activeSubKey : null,
                color: Colors.transparent,
                child: InkWell(
                  canRequestFocus: false,
                  onTap: () {
                    setState(() {
                      _selectedNavIndex = parentIndex;
                      _selectedSubIndex = s;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 9.h),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.menuSubActiveBg : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        AppIcon(
                          sub.icon,
                          size: 15.sp,
                          color: selected ? selectedFg : unselectedFg,
                          style: selected ? AppIconStyle.bold : AppIconStyle.linear,
                        ),
                        SizedBox(width: 10.w),
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              sub.navTitle,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 12.5.sp,
                                color: selected ? selectedFg : unselectedFg,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
            if (s < item.visibleSubItems.length - 1) SizedBox(height: 2.h),
          ],
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, bool isDesktop) {
    final auth = context.watch<AuthProvider>();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? (MediaQuery.of(context).size.width < 1100 ? 12 : MediaQuery.of(context).size.width < 1400 ? 16 : 24) : 16,
        vertical: 18,
      ),
      decoration: const BoxDecoration(
        color: AppColors.topbar,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          if (!isDesktop && MediaQuery.of(context).size.width <= 500)
            IconButton(
              onPressed: () => Scaffold.of(context).openDrawer(),
              icon: const AppIcon('menu'),
            ),
          if (isDesktop)
            _softIconButton(
              icon: _sidebarCollapsed ? 'menu-open' : 'menu-close',
              onTap: () => setState(() => _sidebarCollapsed = !_sidebarCollapsed),
            ),
          SizedBox(width: 14.w),
          // Page title + academic year chip
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _navItems[_selectedNavIndex].navTitle,
                style: AppFonts.heading(size: 26.sp, height: 1.1),
              ),
              if (_academicYear.isNotEmpty) ...[
                SizedBox(height: 5.h),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                  decoration: BoxDecoration(
                    color: AppColors.goldSoft,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.goldLine),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon('calendar-1', size: 14, color: AppColors.goldInk),
                      SizedBox(width: 6.w),
                      Text(
                        'AY $_academicYear',
                        style: TextStyle(fontSize: 12.sp, color: AppColors.goldInk, fontWeight: FontWeight.w800, letterSpacing: 0.2),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),

          // Center: institution identity
          if (isDesktop)
            Expanded(
              child: Center(
                child: (auth.insLogo != null || auth.insName != null)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (auth.insLogo != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10.r),
                            child: Image.network(
                              auth.insLogo!,
                              width: 56.w,
                              height: 56.h,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => AppIcon('teacher', size: 44.sp, color: AppColors.accent),
                            ),
                          )
                        else
                          AppIcon('teacher', size: 48.sp, color: AppColors.accent),
                        SizedBox(width: 14.w),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (auth.insName != null)
                              Text(
                                auth.insName!,
                                textAlign: TextAlign.center,
                                style: AppFonts.heading(size: 20.sp, height: 1.1),
                              ),
                            if (auth.insAddress != null) ...[
                              SizedBox(height: 2.h),
                              Text(
                                auth.insAddress!,
                                textAlign: TextAlign.center,
                                style: AppUI.muted,
                              ),
                            ],
                          ],
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
              ),
            ),

          SizedBox(width: 12.w),

          // Refresh: reloads the current screen's data + the shell state.
          Tooltip(
            message: 'Refresh',
            child: _softIconButton(
              icon: 'refresh',
              spinning: _refreshing,
              onTap: _refreshing ? null : _refreshApp,
            ),
          ),
          SizedBox(width: 14.w),

          // Notification bell (primary-colored)
          Stack(
            clipBehavior: Clip.none,
            children: [
              _softIconButton(
                icon: 'notification',
                iconLinear: true,
                filled: true,
                onTap: () {
                  setState(() => _selectedNavIndex = _navItems.indexWhere((i) => i.label == 'Notifications'));
                  _loadUnreadNotifCount();
                },
              ),
              if (_unreadNotifCount > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: AppColors.error,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(width: 14.w),
          // Profile pill card (clickable — opens popup)
          PopupMenuButton<String>(
            tooltip: 'Profile options',
            position: PopupMenuPosition.under,
            offset: Offset(0, 8.h),
            menuPadding: EdgeInsets.symmetric(vertical: 6.h),
            padding: EdgeInsets.zero,
            onSelected: (value) async {
              if (value == 'signout') {
                await auth.logout();
                if (context.mounted) {
                  Navigator.pushReplacementNamed(context, AppRoutes.welcome);
                }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'signout',
                child: Row(
                  children: [
                    AppIcon('logout', size: 18),
                    SizedBox(width: 8.w),
                    const Text('Sign Out'),
                  ],
                ),
              ),
            ],
            child: Container(
              padding: EdgeInsets.only(left: 4.w, right: 12.w, top: 4.h, bottom: 4.h),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(builder: (context) {
                    final compact = MediaQuery.of(context).size.width <= 1366;
                    return CircleAvatar(
                      radius: compact ? 18 : 26,
                      backgroundColor: AppColors.primary,
                      child: Text(
                        (auth.userName ?? 'U')[0].toUpperCase(),
                        style: AppFonts.heading(size: compact ? 16.sp : 20.sp, color: AppColors.onPrimary),
                      ),
                    );
                  }),
                  SizedBox(width: 12.w),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: isDesktop ? 220 : 140,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          auth.userName ?? 'User',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16.sp, color: AppColors.textPrimary, fontWeight: FontWeight.w700, height: 1.15, letterSpacing: -0.2),
                        ),
                        SizedBox(height: 2.h),
                        Text(
                          auth.userEmail ?? (auth.userRole ?? 'Staff'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppUI.muted.copyWith(height: 1.15),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: 8.w),
                  AppIcon.linear('Chevron Down', size: 16, color: AppColors.textSecondary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Soft-shadow icon button used in the top bar (mail, notifications, etc.)
  // When [filled] is true, the button uses the primary colour as background
  // with white iconography (used for the notification bell).
  Widget _softIconButton({
    required String icon,
    bool iconLinear = false,
    bool filled = false,
    bool spinning = false,
    required VoidCallback? onTap,
  }) {
    final bg = filled ? AppColors.primary : AppColors.card;
    final fg = filled ? AppColors.onPrimary : AppColors.ink2;
    final compact = MediaQuery.of(context).size.width <= 1366;
    final size = compact ? 36.0 : 44.0;
    final iconSize = compact ? 22.0 : 28.0;
    const radius = AppUI.controlRadius;
    Widget iconWidget = iconLinear
        ? AppIcon.linear(icon, size: iconSize, color: fg)
        : AppIcon(icon, size: iconSize, color: fg);
    // Continuous spin while a refresh is in flight.
    if (spinning) {
      iconWidget = _SpinningIcon(child: iconWidget);
    }
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(radius),
      elevation: 0,
      child: InkWell(
        // Top-bar buttons are mouse-only — keep them out of keyboard focus.
        canRequestFocus: false,
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(radius),
          ),
          alignment: Alignment.center,
          child: iconWidget,
        ),
      ),
    );
  }

  /// Screens that manage their own scroll and need full bounded height
  bool _isFullHeightScreen() {
    final label = _navItems[_selectedNavIndex].label;
    return label == 'Dashboard' || label == 'Students' || label == 'Fee Demand' || label == 'Fee Demand Import' || label == 'Fee Collection' || label == 'Student Ledger' || label == 'Fee Demand Approval' || label == 'Transactions' || label == 'Users' || label == 'Notices' || label == 'Notifications' || label == 'Master Data' || label == 'Bank Reconciliation' || label == 'Bank Accounts' || label == 'Reports' || label == 'Daily Collection' || label == 'Pending Payment' || label == 'Pending Details' || label == 'Consolidated Status' || label == 'Consolidated Summary' || label == 'Receiptwise Report' || label == 'Receiptwise Abstract' || label == 'Datewise Abstract' || label == 'DCB Statement' || label == 'Division Summary' || label == 'Fee Matrix' || label == 'Pending Fee Report' || label == 'Advance Reconciliation Report' || label == 'TC Certificate' || label == 'TC Approval' || label == 'TC Print' || label == 'TC Format' || label == 'DCB Register' || label == 'Advance Register' || label == 'Admission Register' || label == 'TC Report' || label == 'Transport Setup' || label == 'Routes & Stops' || label == 'Vehicles' || label == 'Transport Staff' || label == 'Staff' || label == 'Attendance Entry' || label == 'Leave & Out-pass' || label == 'Attendance Report' || label == 'Attendance Setup' || label == 'Trip Schedules' || label == 'Duty Roster' || label == 'Student Enrollment' || label == 'Vehicle Allotment' || label == 'Stage Fees' || label == 'Admission' || label == 'Fast Admission' || label == 'Class Allocation' || label == 'Allot Section' || label == 'Course Transfer' || label == 'Transfer Certificate' || label == 'New Roll Number' || label == 'EMIS / UMIS' || label == 'Admission Master' || label == 'Fee Master' || label == 'Fee Concession' || label == 'Concession Approval' || label == 'Fee Refund' || label == 'Fee Cancel Receipt' || label == 'Misc Collection' || label == 'Advance Collection' || label == 'Advance Fee Collection' || label == 'Advance Adjustment' || label == 'Year End Process' || label == 'Payment Gateways' || label == 'Fee Collection Import' || label == 'Roles & Access' || label == 'Daily Trips' || label == kSequenceMenu;
  }

  /// Which tab a sidebar sub-item opens, resolved by LABEL.
  ///
  /// This used to be positional -- sub-item N opened tab N -- which held only
  /// while every tab had a sub-item, in the same order. Sequence Master took
  /// five tabs out of Fee Master's sub-list while leaving the tabs themselves
  /// in place, so position no longer lines up and "Class Fee Demand" would
  /// have opened "Demand No". Matching on the label means the sub-item list
  /// and the tab list are free to differ in order and length.
  int _subTab(List<String> tabLabels) {
    final items = _navItems[_selectedNavIndex].visibleSubItems;
    if (_selectedSubIndex >= 0 && _selectedSubIndex < items.length) {
      final i = tabLabels.indexOf(items[_selectedSubIndex].label);
      if (i >= 0) return i;
    }
    return 0;
  }

  /// The label of the selected sub-item, or '' when there is none.
  String get _subLabel {
    final items = _navItems[_selectedNavIndex].visibleSubItems;
    return (_selectedSubIndex >= 0 && _selectedSubIndex < items.length)
        ? items[_selectedSubIndex].label
        : '';
  }

  Widget _buildDashboardContent(BuildContext context, bool isDesktop) {
    final selectedMenu = _navItems[_selectedNavIndex].label;
    if (selectedMenu == 'Students') {
      final student = _navigateToStudent;
      _navigateToStudent = null;
      return StudentsScreen(key: student != null ? ValueKey(student.stuId) : null, initialStudent: student);
    }
    if (selectedMenu == 'Fee Demand') {
      return const FeeDemandScreen();
    }
    if (selectedMenu == 'Fee Demand Import') {
      return const FeeDemandImportScreen();
    }
    if (selectedMenu == 'Fee Collection') {
      return StudentFeeCollectionScreen(
        onNavigateToTransactions: () {
          final idx = _navItems.indexWhere((i) => i.label == 'Transactions');
          if (idx >= 0) setState(() => _selectedNavIndex = idx);
        },
      );
    }
    if (selectedMenu == 'Misc Collection') {
      return const MiscCollectionScreen();
    }
    if (selectedMenu == 'Advance Collection') {
      return const AdvanceCollectionScreen();
    }
    if (selectedMenu == 'Advance Fee Collection') {
      return const AdvanceFeeCollectionScreen();
    }
    if (selectedMenu == 'Advance Adjustment') {
      // School: last year's advance fees reconciled against this year's demands.
      return isSchool ? const AdvanceReconcileScreen() : const AdvanceAdjustmentScreen();
    }
    if (selectedMenu == 'Fee Collection Import') {
      // Reuses the master-import card layout; opens directly at the (hidden) Fee
      // Collection tab so it looks exactly like the other import screens.
      return const MasterImportScreen(initialTabIndex: 10, showInternalTabs: false);
    }
    // Reports are now individual sidebar submenus, each opening the Reports
    // screen at its tab with the in-screen tab bar hidden.
    const reportTabs = {
      'Daily Collection': 0,
      'Student Ledger': 1,
      'Pending Payment': 2,
      'Pending Details': 3,
      'Consolidated Status': 4,
      'DCB Register': 5,
      'Advance Register': 6,
    };
    if (reportTabs.containsKey(selectedMenu)) {
      return ReportsScreen(initialTab: reportTabs[selectedMenu]!, showTabBar: false);
    }
    // Its own screen rather than a Reports tab: the register is admission
    // data with its own filters and field chooser, and reports_screen.dart is
    // already the largest file in the app.
    if (selectedMenu == 'Admission Register') {
      return const AdmissionRegisterScreen();
    }
    if (selectedMenu == 'TC Report') {
      return const TcReportScreen();
    }
    if (selectedMenu == 'Receiptwise Report') return const ReceiptwiseReportScreen();
    if (selectedMenu == 'Receiptwise Abstract') return const ReceiptwiseAbstractScreen();
    if (selectedMenu == 'Datewise Abstract') return const DatewiseAbstractScreen();
    if (selectedMenu == 'DCB Statement') return const DcbClasswiseScreen();
    if (selectedMenu == 'Transport Setup') return const TransportSetupScreen();
    if (selectedMenu == 'Routes & Stops') return const RoutesStopsScreen();
    if (selectedMenu == 'Vehicles') return const VehiclesScreen();
    if (selectedMenu == 'Transport Staff') return const TransportStaffScreen();
    if (selectedMenu == 'Staff') return const StaffScreen();
    if (selectedMenu == 'Attendance Entry') return const AttendanceEntryScreen();
    if (selectedMenu == 'Leave & Out-pass') return const LeaveOutpassScreen();
    if (selectedMenu == 'Attendance Report') return const AttendanceReportScreen();
    if (selectedMenu == 'Attendance Setup') return const AttendanceSetupScreen();
    if (selectedMenu == 'Trip Schedules') return const TripSchedulesScreen();
    if (selectedMenu == 'Duty Roster') return const DutyRosterScreen();
    if (selectedMenu == 'Daily Trips') return const DailyTripsScreen();
    if (selectedMenu == 'Student Enrollment') return const StudentEnrollmentScreen();
    if (selectedMenu == 'Vehicle Allotment') return const VehicleAllotmentScreen();
    if (selectedMenu == 'Stage Fees') return const StageFeesScreen();
    if (selectedMenu == 'Division Summary') return const DivisionSummaryScreen();
    if (selectedMenu == 'Fee Matrix') return const FeeMatrixScreen();
    if (selectedMenu == 'Pending Fee Report') return const PendingFeeReportScreen();
    if (selectedMenu == 'Advance Reconciliation Report') return const AdvanceReconciliationReportScreen();
    if (selectedMenu == 'Consolidated Summary') {
      return const ConsolidatedSummaryScreen();
    }
    if (selectedMenu == 'TC Certificate') return const TcCertificateScreen();
    if (selectedMenu == 'TC Approval') return const TcApprovalScreen();
    if (selectedMenu == 'TC Print') return const TcPrintScreen();
    if (selectedMenu == 'TC Format') return const TcFormatScreen();
    if (selectedMenu == 'Transactions') {
      return const FailedTransactionsScreen();
    }
    if (selectedMenu == 'Fee Demand Approval') {
      return const FeeDemandApprovalScreen();
    }
    if (selectedMenu == 'Users') {
      return const AdminCreationScreen();
    }
    if (selectedMenu == 'Roles & Access') {
      return const RolesAccessScreen();
    }
    if (selectedMenu == 'Notices') {
      return const NoticesScreen();
    }
    if (selectedMenu == 'Notifications') {
      return NotificationScreen(onReadChanged: _loadUnreadNotifCount);
    }
    // Master Data / Admission Master / Fee Master keep their tabs as sidebar
    // SUB-ITEMS, so the sidebar is the tab selector and the in-screen pill bar
    // is hidden. _selectedSubIndex is the chosen tab.
    if (selectedMenu == 'Bank Accounts') {
      return const BankDetailsScreen();
    }
    if (selectedMenu == 'Bank Reconciliation') {
      return const BankReconciliationScreen();
    }
    if (selectedMenu == 'Reports') {
      return const ReportsScreen();
    }
    if (selectedMenu == 'Admission') {
      return const AdmissionScreen();
    }
    if (selectedMenu == 'Fast Admission') {
      return const FastAdmissionScreen();
    }
    if (selectedMenu == 'Class Allocation') {
      return const SectionAllocationTabs();
    }
    if (selectedMenu == 'Course Transfer') {
      return const InterimPromotionScreen();
    }
    if (selectedMenu == 'Transfer Certificate') {
      return const TransferCertificateScreen();
    }
    if (selectedMenu == 'New Roll Number') {
      return const NewRollNoScreen();
    }
    if (selectedMenu == 'EMIS / UMIS') {
      return const EmisUmisScreen();
    }
    if (selectedMenu == 'Master Data') {
      // Division and Medium are listed under Master Data but are Admission
      // Master tabs.
      final ai = (_subLabel == 'Division' || _subLabel == 'Medium')
          ? AdmissionMasterScreen.tabLabels.indexOf(_subLabel)
          : -1;
      if (ai >= 0) {
        return AdmissionMasterScreen(
            key: ValueKey('admmaster-$ai'), initialTab: ai, showTabBar: false);
      }
      final t = _subTab(MasterDataScreen.tabLabels);
      return MasterDataScreen(
          key: ValueKey('masterdata-$t'), initialTab: t, showTabBar: false);
    }
    if (selectedMenu == 'Admission Master') {
      final t = _subTab(AdmissionMasterScreen.tabLabels);
      return AdmissionMasterScreen(
          key: ValueKey('admmaster-$t'), initialTab: t, showTabBar: false);
    }
    if (selectedMenu == 'Fee Master') {
      // Receipt Format sits under Fee Master but is a screen of its own
      if (_subLabel == 'Receipt Format') return const ReceiptFormatScreen();
      final t = _subTab(FeeMasterScreen.tabLabels);
      return FeeMasterScreen(
          key: ValueKey('feemaster-$t'), initialTab: t, showTabBar: false);
    }
    // Sequence Master shows tabs that belong to two OTHER screens, so it picks
    // the screen from the label rather than opening one of its own.
    if (selectedMenu == kSequenceMenu) {
      // One screen; the series is picked from its Sequence Type dropdown.
      return const SequenceMasterScreen();
    }
    if (selectedMenu == 'Fee Concession') {
      return const FeeConcessionScreen();
    }
    if (selectedMenu == 'Concession Approval') {
      return const ConcessionApprovalScreen();
    }
    if (selectedMenu == 'Fee Refund') {
      return const FeeRefundScreen();
    }
    if (selectedMenu == 'Fee Cancel Receipt') {
      return const FeeCancelScreen();
    }
    if (selectedMenu == 'Payment Gateways') {
      return const PaymentGatewaysScreen();
    }
    if (selectedMenu == 'Utilities') {
      return const UtilitiesScreen();
    }
    if (selectedMenu == 'Year End Process') {
      return const YearEndScreen();
    }
    // Dashboard landing page: the institution overview (KPIs, collection chart,
    // students-by-class, recent payments, quick actions, today summary).
    return DashboardOverviewScreen(
      allowedMenus: _navItems.map((i) => i.label).toSet(),
      // The RAW grant set, not the nav labels above: it carries the dash:
      // tile keys too, and the overview needs those to know which cards and
      // panels this role may see.
      allowedTiles: _allowedMenus,
      onNavigate: (label) {
        final idx = _navItems.indexWhere((i) => i.label == label);
        if (idx < 0) return;
        setState(() {
          _selectedNavIndex = idx;
          _expandedSections
            ..clear()
            ..add(_navItems[idx].section);
        });
      },
    );
  }

}

// NOTE: the nav catalog (AppNavItem / kAppNavItems / kSectionMeta) now lives in
// lib/utils/app_menu.dart so the Roles & Access screen renders the same list
// the sidebar does. Don't reintroduce a local copy here — it would drift.

/// Spins its [child] continuously — used on the header Refresh icon while a
/// refresh is in flight.
class _SpinningIcon extends StatefulWidget {
  final Widget child;
  const _SpinningIcon({required this.child});

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(turns: _ctrl, child: widget.child);
}

class _DashedLinePainter extends CustomPainter {
  final Color color;
  const _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const dashHeight = 3.0;
    const dashGap = 3.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    double y = 0;
    while (y < size.height) {
      canvas.drawLine(Offset(0, y), Offset(0, y + dashHeight), paint);
      y += dashHeight + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) => oldDelegate.color != color;
}

/// The dashed tree line in the sidebar that links a group's sub-items.
class _DashedVLine extends CustomPainter {
  final Color color;
  const _DashedVLine(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var y = 0.0; y < size.height; y += 6) {
      canvas.drawLine(Offset(size.width / 2, y), Offset(size.width / 2, (y + 3).clamp(0, size.height)), paint);
    }
  }

  @override
  bool shouldRepaint(_DashedVLine old) => old.color != color;
}
