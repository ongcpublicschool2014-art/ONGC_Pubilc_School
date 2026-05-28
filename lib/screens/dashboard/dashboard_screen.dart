import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/app_routes.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../models/student_model.dart';
import '../students/students_screen.dart';
import '../fees/fee_collection_screen.dart';
import '../fees/student_fee_collection_screen.dart';
import '../fees/student_ledger_screen.dart';
import '../transactions/failed_transactions_screen.dart';
import '../admin/admin_creation_screen.dart';
import '../admin/bank_details_screen.dart';
import '../notices/notices_screen.dart';
import '../notifications/notification_screen.dart';
import '../fees/fee_demand_screen.dart';
import '../fees/fee_demand_approval_screen.dart';
import '../admin/master_import_screen.dart';
import '../admin/settings_screen.dart';
import '../fees/bank_reconciliation_screen.dart';
import '../fees/reports_screen.dart';



import '../../widgets/app_icon.dart';
import '../../utils/friendly_error.dart';
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

  // Notification unread count
  int _unreadNotifCount = 0;
  String _academicYear = '';
  List<Map<String, dynamic>> _availableYears = [];

  // Global search
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final LayerLink _searchLayerLink = LayerLink();
  OverlayEntry? _searchOverlay;
  List<StudentModel> _allStudents = [];
  List<StudentModel> _searchResults = [];


  static const List<_NavItem> _allNavItems = [
    _NavItem('element-3', 'Dashboard', section: 'MAIN MENU'),
    _NavItem('document-upload', 'Master Data', section: 'ADMIN', adminOnly: true, subItems: [
      _NavSubItem('user-tick', 'Admission Type'),
      _NavSubItem('ticket', 'Quota'),
      _NavSubItem('teacher', 'Course'),
      _NavSubItem('book-1', 'Class'),
      _NavSubItem('category-2', 'Fee Group'),
      _NavSubItem('receipt-1', 'Fee Type'),
      _NavSubItem('receipt-discount', 'Concession'),
      _NavSubItem('note-2', 'Class Fee Demand'),
    ]),
    _NavItem('setting-2', 'Sequence Creation', section: 'ADMIN', adminOnly: true),
    _NavItem('bank', 'Bank Accounts', section: 'ADMIN', adminOnly: true),
    _NavItem('security-user', 'User Creation', section: 'ADMIN', adminOnly: true),
    _NavItem('people', 'Student', section: 'STUDENTS', adminOnly: true),
    _NavItem('book-1', 'Student Ledger', section: 'STUDENTS'),
    _NavItem('receipt-edit', 'Fee Demand', section: 'FEES'),
    _NavItem('tick-square', 'Fee Demand Approval', section: 'FEES', adminOnly: true),
    _NavItem('bank', 'Bank Reconciliation', section: 'FEES', adminOnly: true),
    _NavItem('indianrupeesign.circle.fill', 'Fee Collection', section: 'FEES', accountantOnly: true, unselectedIcon: 'indianrupeesign.circle'),
    _NavItem('receipt-2', 'Transactions', section: 'FEES'),
    _NavItem('notification', 'Notices', section: 'GENERAL'),
    _NavItem('notification-bing', 'Notifications', section: 'GENERAL'),
    _NavItem('chart-1', 'Reports', section: 'GENERAL', unselectedIcon: 'chart'),
  ];

  late List<_NavItem> _navItems;

  List<_NavItem> _getNavItems(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final isAdmin = auth.currentUser?.urname == 'Admin';
    final isAccountant = auth.currentUser?.urname == 'Accountant';
    if (isAdmin) return _allNavItems.where((item) => !item.accountantOnly).toList();
    return _allNavItems.where((item) {
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
    _searchFocusNode.addListener(() {
      if (!_searchFocusNode.hasFocus) {
        // Delay removal so overlay tap events can fire first
        Future.delayed(const Duration(milliseconds: 200), () {
          _removeSearchOverlay();
        });
      }
    });
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
          .order('iyr_id', ascending: false);
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

    // Set new schema
    SupabaseService.setSchema(newSchema);
    setState(() => _academicYear = yearLabel);

    // Reload all data
    _loadStudentsForSearch();
    _loadUnreadNotifCount();
    // Reset to dashboard tab to refresh
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.r)),
        title: Text('Create New Academic Year', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16.sp)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New Year: $nextLabel', style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w600, color: AppColors.accent)),
            SizedBox(height: 16.h),
            TextField(
              controller: startDateCtrl,
              decoration: InputDecoration(
                labelText: 'Start Date (YYYY-MM-DD)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
                isDense: true,
              ),
            ),
            SizedBox(height: 12.h),
            TextField(
              controller: endDateCtrl,
              decoration: InputDecoration(
                labelText: 'End Date (YYYY-MM-DD)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
                isDense: true,
              ),
            ),
            SizedBox(height: 8.h),
            Text('This will create a new empty schema with all tables.', style: TextStyle(fontSize: 12.sp, color: AppColors.textSecondary)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _createNewYear(nextLabel, startDateCtrl.text.trim(), endDateCtrl.text.trim());
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
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
    setState(() {
      _navigateToStudent = student;
      _selectedNavIndex = 1; // Students tab
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
          borderRadius: BorderRadius.circular(12.r),
          child: Container(
            constraints: BoxConstraints(maxHeight: 400.h),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12.r),
              border: Border.all(color: AppColors.border),
            ),
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
                        CircleAvatar(
                          radius: 18.r,
                          backgroundColor: AppColors.accent.withValues(alpha: 0.1),
                          child: s.stuphoto != null && s.stuphoto!.startsWith('http')
                              ? ClipOval(child: Image.network(s.stuphoto!, width: 36.w, height: 36.h, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Text(s.stuname[0].toUpperCase(), style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 14.sp))))
                              : Text(s.stuname[0].toUpperCase(), style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 14.sp)),
                        ),
                        SizedBox(width: 12.w),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.stuname, style: TextStyle(fontSize: 13.sp, fontWeight: FontWeight.w600)),
                              Text('${s.stuadmno}  •  Class ${s.stuclass}', style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                        Text(s.stumobile, style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary)),
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
    _searchController.dispose();
    _searchFocusNode.dispose();
    _removeSearchOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _navItems = _getNavItems(context);
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 800;
    final isTablet = size.width > 500 && size.width <= 800;

    // Clamp selected index if nav items changed (e.g. role-based filtering)
    if (_selectedNavIndex >= _navItems.length) {
      _selectedNavIndex = 0;
    }

    return Scaffold(
      backgroundColor: AppColors.surface,
      drawer: (!isDesktop && !isTablet)
          ? Drawer(child: _buildSidebar(context, false))
          : null,
      body: Row(
        children: [
          // Sidebar
          if (isDesktop || isTablet)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: _sidebarCollapsed ? 78 : (isDesktop ? (size.width < 1100 ? 170 : size.width < 1400 ? 200 : 240) : 78),
              child: _buildSidebar(
                  context, _sidebarCollapsed || isTablet),
            ),

          // Main content
          Expanded(
            child: Column(
              children: [
                // Top bar
                _buildTopBar(context, isDesktop),

                // Content area
                Expanded(
                  child: _isFullHeightScreen()
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: _buildDashboardContent(context, isDesktop),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: _buildDashboardContent(context, isDesktop),
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
        ? 12.w
        : (MediaQuery.of(context).size.width < 1100 ? 10.w : 14.w);

    return Container(
      color: AppColors.surfaceSidebar,
      child: Column(
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
                SizedBox(
                  width: collapsed ? 46 : 56.w,
                  height: collapsed ? 46 : 56.h,
                  child: Image.asset(
                    'assets/images/educore360_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => AppIcon('teacher',
                      color: AppColors.primary,
                      size: 16,
                    ),
                  ),
                ),
                if (!collapsed) ...[
                  SizedBox(width: 10.w),
                  Flexible(
                    child: Text(
                      'EduCore360',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.sp,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Nav items grouped by section. The default desktop scrollbar is
          // suppressed so the sidebar reads as a flat menu — items still
          // scroll via mouse wheel / trackpad, just without a visible bar.
          Expanded(
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: ListView(
                padding: EdgeInsets.symmetric(horizontal: hPad),
                children: [
                  for (var s = 0; s < orderedSections.length; s++) ...[
                    if (!collapsed)
                      Padding(
                        padding: EdgeInsets.only(
                          top: s == 0 ? 4.h : 18.h,
                          bottom: 8.h,
                          left: 10.w,
                        ),
                        child: Text(
                          orderedSections[s],
                          style: TextStyle(
                            fontSize: 11.sp,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: AppColors.accent,
                          ),
                        ),
                      )
                    else
                      SizedBox(height: s == 0 ? 4.h : 18.h),
                    for (final idx in groupedIndices[orderedSections[s]]!)
                      _buildNavTile(context, idx, collapsed),
                  ],
                  SizedBox(height: 16.h),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavTile(BuildContext context, int index, bool collapsed) {
    final item = _navItems[index];
    final isSelected = _selectedNavIndex == index;
    final hasSubItems = item.subItems.isNotEmpty;
    final isExpanded = !collapsed && hasSubItems && _expandedNavIndex == index;
    final badge = item.label == 'Notifications' && _unreadNotifCount > 0
        ? _unreadNotifCount.toString()
        : null;

    const selectedBg = AppColors.primary;
    const selectedFg = AppColors.textOnPrimary;
    const unselectedFg = AppColors.textSecondary;

    final iconSize =
        MediaQuery.of(context).size.width <= 1366 ? 18.sp : 20.sp;

    final tile = Padding(
      padding: EdgeInsets.only(bottom: 4.h),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                setState(() {
                  _selectedNavIndex = index;
                  if (hasSubItems && !collapsed) {
                    _expandedNavIndex = isExpanded ? null : index;
                  } else {
                    _expandedNavIndex = null;
                  }
                });
                _loadUnreadNotifCount();
              },
              borderRadius: BorderRadius.circular(12.r),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: EdgeInsets.symmetric(
                  horizontal: collapsed ? 12.w : 14.w,
                  vertical: 11.h,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? selectedBg : Colors.transparent,
                  borderRadius: BorderRadius.circular(12.r),
                ),
                child: Row(
                  children: [
                    AppIcon(
                      isSelected ? item.icon : (item.unselectedIcon ?? item.icon),
                      style: isSelected
                          ? AppIconStyle.bold
                          : AppIconStyle.linear,
                      color: isSelected ? selectedFg : unselectedFg,
                      size: iconSize,
                    ),
                    if (!collapsed) ...[
                      SizedBox(width: 12.w),
                      Expanded(
                        child: Text(
                          item.label,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13.sp,
                            color: isSelected ? selectedFg : unselectedFg,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (badge != null)
                        Text(
                          badge,
                          style: TextStyle(
                            fontSize: 12.sp,
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.7)
                                : unselectedFg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (hasSubItems)
                        Container(
                          width: 20.w,
                          height: 20.w,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.18)
                                : unselectedFg.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(5.r),
                            border: Border.all(
                              color: isSelected
                                  ? Colors.white.withValues(alpha: 0.30)
                                  : unselectedFg.withValues(alpha: 0.30),
                              width: 1,
                            ),
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            transitionBuilder: (child, anim) =>
                                ScaleTransition(scale: anim, child: child),
                            child: AppIcon(
                              isExpanded ? 'Remove_Minus' : 'Add_Plus',
                              key: ValueKey(isExpanded),
                              style: AppIconStyle.bold,
                              size: 15.sp,
                              color: isSelected ? selectedFg : unselectedFg,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (isExpanded) _buildSubMenu(context, index, item),
        ],
      ),
    );
    // Collapsed sidebar hides labels, so surface each item's name on hover.
    return collapsed
        ? Tooltip(
            message: item.label,
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

  Widget _buildSubMenu(BuildContext context, int parentIndex, _NavItem item) {
    const selectedFg = AppColors.primary;
    const unselectedFg = AppColors.textSecondary;
    final isParentSelected = _selectedNavIndex == parentIndex;

    return Padding(
      padding: EdgeInsets.only(top: 6.h, left: 22.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var s = 0; s < item.subItems.length; s++) ...[
            Builder(builder: (context) {
              final sub = item.subItems[s];
              final selected = isParentSelected && _selectedSubIndex == s;
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _selectedNavIndex = parentIndex;
                      _selectedSubIndex = s;
                    });
                  },
                  borderRadius: BorderRadius.circular(8.r),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.primary.withValues(alpha: 0.06) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8.r),
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        children: [
                          // Left accent rail on selected
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 3.w,
                            margin: EdgeInsets.symmetric(vertical: 6.h),
                            decoration: BoxDecoration(
                              color: selected ? selectedFg : Colors.transparent,
                              borderRadius: BorderRadius.circular(2.r),
                            ),
                          ),
                          SizedBox(width: 10.w),
                          AppIcon(
                            sub.icon,
                            size: 15.sp,
                            color: selected ? selectedFg : unselectedFg,
                            style: selected ? AppIconStyle.bold : AppIconStyle.linear,
                          ),
                          SizedBox(width: 10.w),
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 8.h),
                              child: Text(
                                sub.label,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 12.5.sp,
                                  color: selected ? selectedFg : unselectedFg,
                                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 8.w),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            if (s < item.subItems.length - 1) SizedBox(height: 2.h),
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
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.border)),
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
                _navItems[_selectedNavIndex].label,
                style: TextStyle(fontSize: 18.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: -0.2, height: 1.1),
              ),
              if (_academicYear.isNotEmpty) ...[
                SizedBox(height: 5.h),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon('calendar-1', size: 14, color: AppColors.accent),
                      SizedBox(width: 6.w),
                      Text(
                        'AY $_academicYear',
                        style: TextStyle(fontSize: 12.sp, color: AppColors.accent, fontWeight: FontWeight.w700, letterSpacing: 0.2),
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (auth.insName != null)
                              Text(
                                auth.insName!,
                                style: TextStyle(fontSize: 20.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary, letterSpacing: -0.3, height: 1.1),
                              ),
                            if (auth.insAddress != null) ...[
                              SizedBox(height: 2.h),
                              Text(
                                auth.insAddress!,
                                style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                                overflow: TextOverflow.ellipsis,
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
            color: Colors.white,
            elevation: 10,
            surfaceTintColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12.r),
              side: const BorderSide(color: AppColors.border),
            ),
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
                    const Text('Sign out'),
                  ],
                ),
              ),
            ],
            child: Container(
              padding: EdgeInsets.only(left: 4.w, right: 12.w, top: 4.h, bottom: 4.h),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(builder: (context) {
                    final compact = MediaQuery.of(context).size.width <= 1366;
                    return CircleAvatar(
                      radius: compact ? 18 : 26,
                      backgroundColor: AppColors.accent.withValues(alpha: 0.18),
                      child: Text(
                        (auth.userName ?? 'U')[0].toUpperCase(),
                        style: TextStyle(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w800,
                          fontSize: compact ? 16.sp : 20.sp,
                        ),
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
                          style: TextStyle(fontSize: 13.sp, color: AppColors.textSecondary, fontWeight: FontWeight.w500, height: 1.15),
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
    required VoidCallback onTap,
  }) {
    final bg = filled ? AppColors.primary : Colors.white;
    final fg = filled ? Colors.white : AppColors.textSecondary;
    final compact = MediaQuery.of(context).size.width <= 1366;
    final size = compact ? 36.0 : 44.0;
    final iconSize = compact ? 22.0 : 28.0;
    final radius = compact ? 10.0 : 12.0;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(radius),
      elevation: 0,
      child: InkWell(
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
          child: iconLinear
              ? AppIcon.linear(icon, size: iconSize, color: fg)
              : AppIcon(icon, size: iconSize, color: fg),
        ),
      ),
    );
  }

  /// Screens that manage their own scroll and need full bounded height
  bool _isFullHeightScreen() {
    final label = _navItems[_selectedNavIndex].label;
    return label == 'Dashboard' || label == 'Student' || label == 'Fee Demand' || label == 'Fee Collection' || label == 'Student Ledger' || label == 'Fee Demand Approval' || label == 'Transactions' || label == 'User Creation' || label == 'Notices' || label == 'Notifications' || label == 'Master Data' || label == 'Sequence Creation' || label == 'Bank Reconciliation' || label == 'Bank Accounts' || label == 'Reports';
  }

  Widget _buildDashboardContent(BuildContext context, bool isDesktop) {
    final selectedMenu = _navItems[_selectedNavIndex].label;
    if (selectedMenu == 'Student') {
      final student = _navigateToStudent;
      _navigateToStudent = null;
      return StudentsScreen(key: student != null ? ValueKey(student.stuId) : null, initialStudent: student);
    }
    if (selectedMenu == 'Fee Demand') {
      return const FeeDemandScreen();
    }
    if (selectedMenu == 'Fee Collection') {
      return StudentFeeCollectionScreen(
        onNavigateToTransactions: () {
          final idx = _navItems.indexWhere((i) => i.label == 'Transactions');
          if (idx >= 0) setState(() => _selectedNavIndex = idx);
        },
      );
    }
    if (selectedMenu == 'Student Ledger') {
      return const StudentLedgerScreen();
    }
    if (selectedMenu == 'Transactions') {
      return const FailedTransactionsScreen();
    }
    if (selectedMenu == 'Fee Demand Approval') {
      return const FeeDemandApprovalScreen();
    }
    if (selectedMenu == 'User Creation') {
      return const AdminCreationScreen();
    }
    if (selectedMenu == 'Notices') {
      return const NoticesScreen();
    }
    if (selectedMenu == 'Notifications') {
      return NotificationScreen(onReadChanged: _loadUnreadNotifCount);
    }
    if (selectedMenu == 'Master Data') {
      return MasterImportScreen(
        initialTabIndex: _selectedSubIndex,
        showInternalTabs: false,
      );
    }
    if (selectedMenu == 'Sequence Creation') {
      return const SettingsScreen();
    }
    if (selectedMenu == 'Bank Accounts') {
      return const BankDetailsScreen();
    }
    if (selectedMenu == 'Bank Reconciliation') {
      return const BankReconciliationScreen();
    }
    if (selectedMenu == 'Reports') {
      return const ReportsScreen();
    }
    // Dashboard shows Fee Collection screen
    return const FeeCollectionScreen();
  }

}

class _NavItem {
  final String icon;
  final String? unselectedIcon;
  final String label;
  final String section;
  final bool adminOnly;
  final bool accountantOnly;
  final bool hideForAccountant;
  final List<_NavSubItem> subItems;
  const _NavItem(this.icon, this.label, {this.section = 'MAIN', this.adminOnly = false, this.accountantOnly = false, this.hideForAccountant = false, this.unselectedIcon, this.subItems = const []});
}

class _NavSubItem {
  final String icon;
  final String label;
  const _NavSubItem(this.icon, this.label);
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

