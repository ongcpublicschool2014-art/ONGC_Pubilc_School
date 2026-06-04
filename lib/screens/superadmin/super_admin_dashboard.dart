import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../models/fee_model.dart';
import '../../models/payment_model.dart';
import '../../utils/app_theme.dart';
import '../../utils/app_routes.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../auth/register_screen.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../utils/friendly_error.dart';
class SuperAdminDashboard extends StatefulWidget {
  const SuperAdminDashboard({super.key});

  @override
  State<SuperAdminDashboard> createState() => _SuperAdminDashboardState();
}

class _SuperAdminDashboardState extends State<SuperAdminDashboard> {
  int _selectedNavIndex = 0;
  bool _sidebarCollapsed = false;

  // Deterministic accent colour per institution code so each KCxx badge
  // in the Institutions Overview gets its own visually distinct highlight
  // without depending on a server-supplied palette.
  static const List<Color> _insCodePalette = [
    Color(0xFFE65100), // deep orange
    Color(0xFF1565C0), // strong blue
    Color(0xFF2E7D32), // forest green
    Color(0xFF6A1B9A), // purple
    Color(0xFFC62828), // crimson
    Color(0xFF00838F), // teal
    Color(0xFFEF6C00), // amber
  ];
  Color _colorForInsCode(String code) {
    if (code.isEmpty) return _insCodePalette[0];
    final h = code.codeUnits.fold<int>(0, (a, b) => a + b);
    return _insCodePalette[h % _insCodePalette.length];
  }

  static const List<_SANavItem> _navItems = [
    _SANavItem('element-3', 'Dashboard', section: 'MAIN MENU'),
    _SANavItem('building', 'Register Institution', section: 'INSTITUTIONS'),
    _SANavItem('buildings-2', 'Manage Institutions', unselectedIcon: 'buildings-2', section: 'INSTITUTIONS'),
    _SANavItem('setting-2', 'Settings', section: 'GENERAL'),
  ];

  List<Map<String, dynamic>> _institutions = [];
  bool _loadingInstitutions = true;
  bool _loadingFinanceData = true;
  bool _syncingLogos = false;

  Future<void> _syncInstitutionLogos() async {
    setState(() => _syncingLogos = true);
    final filled = await SupabaseService.backfillInstitutionLogos();
    if (!mounted) return;
    setState(() => _syncingLogos = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(filled == 0
            ? 'All institution logos already in sync.'
            : 'Synced $filled institution logo${filled == 1 ? '' : 's'}.'),
        backgroundColor: filled == 0 ? AppColors.textSecondary : AppColors.success,
      ),
    );
    if (filled > 0) _refreshDashboard();
  }
  List<_InstitutionFinanceSummary> _institutionSummaries = [];
  List<_SuperAdminTransactionRow> _recentTransactions = [];

  // Horizontal scroll controllers for the two summary tables, used to drive
  // ClassicHScrollbar (matches the modern table-bar look elsewhere).
  final ScrollController _institutionTableScrollCtrl = ScrollController();
  final ScrollController _recentTransactionsScrollCtrl = ScrollController();

  // Year filter — null means "latest per institution" (legacy behaviour).
  // Populated lazily from public.get_super_admin_year_labels() on first
  // load so we don't hold up dashboard rendering on slow networks.
  List<String> _availableYears = [];
  String? _selectedYear;
  String _trustName = '';
  String? _trustLogo;
  DateTime? _lastUpdated;

  // Body-area drilldown state — stays inside the dashboard layout (header
  // and sidebar remain visible) instead of pushing a new route.
  String? _aggregateDrilldownMode;
  _InstitutionFinanceSummary? _courseWiseSummary;
  String? _courseWiseMode;
  bool _courseWiseTodayOnly = false;

  final Set<int> _expandedInsIds = <int>{};

  @override
  void initState() {
    super.initState();
    _loadAvailableYears();
    _loadInstitutions();
    _loadTrustSettings();
  }

  @override
  void dispose() {
    _institutionTableScrollCtrl.dispose();
    _recentTransactionsScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTrustSettings() async {
    try {
      final row = await SupabaseService.client
          .from('trust')
          .select('trust_name, trust_logo')
          .eq('trust_id', 1)
          .maybeSingle();
      if (!mounted || row == null) return;
      setState(() {
        _trustName = (row['trust_name'] as String?) ?? '';
        _trustLogo = row['trust_logo'] as String?;
      });
    } catch (e) {
      debugPrint('trust settings load failed: $e');
    }
  }

  /// Pull the distinct yrlabels across all institutions and remember them
  /// for the dropdown. Default the selection to the year covering today
  /// (or the newest available, since the helper returns DESC). Failure is
  /// non-fatal — without years the dropdown hides itself and the dashboard
  /// keeps the existing latest-year totals.
  Future<void> _loadAvailableYears() async {
    try {
      final res = await SupabaseService.client.rpc('get_super_admin_year_labels');
      final list = res is List ? res.cast<String>() : <String>[];
      if (!mounted || list.isEmpty) return;

      // Pick a sensible default — the year label whose left half matches
      // today's calendar year (e.g. today=2026 → '2026-2027'), falling
      // back to the newest entry (list is already DESC-sorted).
      final today = DateTime.now();
      String? current;
      for (final y in list) {
        final left = y.split('-').first;
        if (left == today.year.toString()) {
          current = y;
          break;
        }
      }
      current ??= list.first;

      final shouldReload = _selectedYear != current;
      setState(() {
        _availableYears = list;
        _selectedYear = current;
      });
      if (shouldReload) _loadInstitutions();
    } catch (e) {
      debugPrint('get_super_admin_year_labels failed: $e');
    }
  }

  /// Year-filter dropdown shown in the dashboard header. Includes an
  /// "All years" sentinel (null value) which falls back to each
  /// institution's latest year — the legacy behaviour. Selecting a
  /// specific year re-runs the dashboard RPC with p_yrlabel set.
  Widget _buildYearFilter() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w),
      height: 36,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedYear,
          isDense: true,
          icon: const AppIcon('arrow-down-1', size: 14, color: AppColors.textSecondary),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
          items: [
            for (final y in _availableYears)
              DropdownMenuItem<String>(
                value: y,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIcon('calendar', size: 14, color: AppColors.accent),
                    SizedBox(width: 6.w),
                    Text(y),
                  ],
                ),
              ),
          ],
          onChanged: (v) {
            if (v == null || v == _selectedYear) return;
            setState(() {
              _selectedYear = v;
              _loadingFinanceData = true;
            });
            _loadInstitutions();
          },
        ),
      ),
    );
  }

  void _refreshDashboard() {
    setState(() {
      _loadingInstitutions = true;
      _loadingFinanceData = true;
    });
    _loadInstitutions();
  }

  String _formatUpdated(DateTime t) {
    final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final ampm = t.hour < 12 ? 'AM' : 'PM';
    final mm = t.minute.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    final mo = t.month.toString().padLeft(2, '0');
    return '$dd/$mo ${h12.toString().padLeft(2, '0')}:$mm $ampm';
  }

  /// Full date + time for the header pill. Falls back to the current
  /// moment until the first refresh stamps [_lastUpdated].
  String _formatHeaderDateTime(DateTime? t) {
    final d = t ?? DateTime.now();
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    final mm = d.minute.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final mo = d.month.toString().padLeft(2, '0');
    return '$dd/$mo/${d.year}  ${h12.toString().padLeft(2, '0')}:$mm $ampm';
  }

  Future<void> _loadTodayCollections(
      List<_InstitutionFinanceSummary> summaries) async {
    // Try the v2 RPC first — single round-trip aggregation for everything.
    // Pass _selectedYear so v2 picks the right per-institution schema; null
    // falls back to each institution's latest year (legacy behaviour).
    try {
      final v2 = await SupabaseService.client.rpc(
        'get_super_admin_dashboard_v2',
        params: {'p_yrlabel': _selectedYear},
      );
      if (v2 is List) {
        final byId = <int, Map<String, dynamic>>{};
        for (final r in v2) {
          if (r is Map && r['ins_id'] is int) {
            byId[r['ins_id'] as int] = Map<String, dynamic>.from(r);
          }
        }
        for (final s in summaries) {
          final r = byId[s.insId];
          if (r == null) continue;
          s.totalPending = (r['total_pending'] as num?)?.toDouble() ?? s.totalPending;
          s.totalCollected = (r['total_collected'] as num?)?.toDouble() ?? s.totalCollected;
          s.pendingApproval = (r['pending_approval'] as num?)?.toDouble() ?? 0;
        }
        if (mounted) setState(() {});
        await _loadTodayOnly(summaries);
        return;
      }
    } catch (e) {
      debugPrint('v2 dashboard RPC failed, falling back: $e');
    }

    final now = DateTime.now();
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    await Future.wait(summaries.map((s) async {
      try {
        final insRow = await SupabaseService.client
            .from('institution')
            .select('inshortname')
            .eq('ins_id', s.insId)
            .maybeSingle();
        final shortName = (insRow?['inshortname'] as String?)?.toLowerCase();
        if (shortName == null) return;

        final yearRows = await SupabaseService.client
            .from('institutionyear')
            .select('yrlabel, iyrstadate, iyrenddate')
            .eq('ins_id', s.insId)
            .eq('activestatus', 1)
            .order('iyr_id', ascending: false);
        final years = List<Map<String, dynamic>>.from(yearRows as List);
        if (years.isEmpty) return;

        String? yearLabel;
        for (final y in years) {
          final start = DateTime.tryParse(y['iyrstadate']?.toString() ?? '');
          final end = DateTime.tryParse(y['iyrenddate']?.toString() ?? '');
          if (start != null &&
              end != null &&
              !now.isBefore(start) &&
              !now.isAfter(end)) {
            yearLabel = y['yrlabel']?.toString();
            break;
          }
        }
        yearLabel ??= years.first['yrlabel']?.toString();
        if (yearLabel == null) return;

        final schema = '$shortName${yearLabel.replaceAll('-', '')}';
        final rows = await SupabaseService.client
            .schema(schema)
            .from('payment')
            .select('transtotalamount')
            .eq('paydate', todayStr)
            .eq('activestatus', 1);
        final total = (rows as List).fold<double>(
            0,
            (sum, r) =>
                sum + ((r['transtotalamount'] as num?)?.toDouble() ?? 0));
        s.todayCollected = total;

        // Pending Approval = sum of paymentdetails (per-fee allocation)
        // for payments awaiting reconciliation, excluding any FINE rows.
        final pendingPays = await SupabaseService.client
            .schema(schema)
            .from('payment')
            .select('pay_id')
            .eq('paystatus', 'C')
            .eq('recon_status', 'P')
            .eq('activestatus', 1);
        final pendingPayIds = (pendingPays as List)
            .map((r) => r['pay_id'])
            .whereType<int>()
            .toList();
        double pendingApproval = 0;
        for (int i = 0; i < pendingPayIds.length; i += 200) {
          final chunk = pendingPayIds.sublist(
              i, (i + 200).clamp(0, pendingPayIds.length));
          final pd = await SupabaseService.client
              .schema(schema)
              .from('paymentdetails')
              .select('dem_id, transtotalamount')
              .inFilter('pay_id', chunk);
          final demIds = (pd as List)
              .map((r) => r['dem_id'])
              .whereType<int>()
              .toSet()
              .toList();
          final demFineMap = <int, double>{};
          for (int j = 0; j < demIds.length; j += 200) {
            final dchunk =
                demIds.sublist(j, (j + 200).clamp(0, demIds.length));
            final fd = await SupabaseService.client
                .schema(schema)
                .from('feedemand')
                .select('dem_id, fineamount')
                .inFilter('dem_id', dchunk);
            for (final r in (fd as List)) {
              demFineMap[r['dem_id'] as int] =
                  (r['fineamount'] as num?)?.toDouble() ?? 0;
            }
          }
          for (final r in pd) {
            final did = r['dem_id'] as int?;
            final amt = (r['transtotalamount'] as num?)?.toDouble() ?? 0;
            final fine = did != null ? (demFineMap[did] ?? 0) : 0;
            pendingApproval += (amt - fine).clamp(0, double.infinity).toDouble();
          }
        }
        s.pendingApproval = pendingApproval;
        // Total Collection and Total Pending are already set from
        // get_super_admin_dashboard RPC (SUM(paidamount) / SUM(balancedue)).
        // Don't override with (feeamount - reconbalancedue) — that formula
        // drifts from the institution dashboard's figures.
      } catch (e) {
        debugPrint('today collection error for ${s.insName}: $e');
      }
    }));
    if (mounted) setState(() {});
  }

  Future<void> _loadTodayOnly(
      List<_InstitutionFinanceSummary> summaries) async {
    final now = DateTime.now();
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final tomorrow = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    final tomorrowStr =
        '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
    await Future.wait(summaries.map((s) async {
      try {
        final insRow = await SupabaseService.client
            .from('institution')
            .select('inshortname')
            .eq('ins_id', s.insId)
            .maybeSingle();
        final shortName = (insRow?['inshortname'] as String?)?.toLowerCase();
        if (shortName == null) return;
        final yearRows = await SupabaseService.client
            .from('institutionyear')
            .select('yrlabel, iyrstadate, iyrenddate')
            .eq('ins_id', s.insId)
            .eq('activestatus', 1)
            .order('iyr_id', ascending: false);
        final years = List<Map<String, dynamic>>.from(yearRows as List);
        if (years.isEmpty) return;
        String? yearLabel;
        for (final y in years) {
          final start = DateTime.tryParse(y['iyrstadate']?.toString() ?? '');
          final end = DateTime.tryParse(y['iyrenddate']?.toString() ?? '');
          if (start != null &&
              end != null &&
              !now.isBefore(start) &&
              !now.isAfter(end)) {
            yearLabel = y['yrlabel']?.toString();
            break;
          }
        }
        yearLabel ??= years.first['yrlabel']?.toString();
        if (yearLabel == null) return;
        final schema = '$shortName${yearLabel.replaceAll('-', '')}';
        final rows = await SupabaseService.client
            .schema(schema)
            .from('payment')
            .select('transtotalamount')
            .eq('paystatus', 'C')
            .gte('paydate', todayStr)
            .lt('paydate', tomorrowStr)
            .eq('activestatus', 1);
        s.todayCollected = (rows as List).fold<double>(
            0,
            (sum, r) =>
                sum + ((r['transtotalamount'] as num?)?.toDouble() ?? 0));
      } catch (e) {
        debugPrint('today-only fetch error for ${s.insName}: $e');
      }
    }));
    if (mounted) setState(() {});
  }

  Future<void> _loadInstitutions() async {
    try {
      // Single RPC call for all institution data with finance summary.
      // Pass _selectedYear so the per-institution schema lookup matches the
      // chosen academic year. Null = each institution's latest year.
      debugPrint('[SuperAdmin] Calling get_super_admin_dashboard RPC for year=$_selectedYear...');
      final rpcResult = await SupabaseService.client.rpc(
        'get_super_admin_dashboard',
        params: {'p_yrlabel': _selectedYear},
      );
      debugPrint(
          '[SuperAdmin] RPC raw result type=${rpcResult.runtimeType} value=$rpcResult');
      // Supabase returns json RPC results sometimes as List, sometimes as a
      // JSON-encoded String — handle both safely.
      List rawList;
      if (rpcResult == null) {
        rawList = const [];
      } else if (rpcResult is List) {
        rawList = rpcResult;
      } else if (rpcResult is String) {
        final decoded = rpcResult.isEmpty ? null : jsonDecode(rpcResult);
        rawList = decoded is List ? decoded : const [];
      } else {
        rawList = const [];
      }
      final dashboardData =
          rawList.map((e) => Map<String, dynamic>.from(e as Map)).toList();

      final institutions = <Map<String, dynamic>>[];
      final summaries = <_InstitutionFinanceSummary>[];

      for (final row in dashboardData) {
        institutions.add(row);
        summaries.add(
          _InstitutionFinanceSummary(
            insId: row['ins_id'] as int? ?? 0,
            insName: row['insname']?.toString() ?? 'Institution',
            insCode: row['inscode']?.toString() ?? '',
            insLogo: row['inslogo']?.toString(),
            totalDemand: (row['total_demand'] as num?)?.toDouble() ?? 0,
            totalCollected: (row['total_collected'] as num?)?.toDouble() ?? 0,
            totalPending: (row['total_pending'] as num?)?.toDouble() ?? 0,
            transactionCount: (row['transaction_count'] as num?)?.toInt() ?? 0,
            activeStatus: row['activestatus'] == 1,
          ),
        );
      }

      if (mounted) {
        setState(() {
          _institutions = institutions;
          _institutionSummaries = summaries;
          _loadingInstitutions = false;
          _loadingFinanceData = false;
          _lastUpdated = DateTime.now();
        });
      }

      _loadTodayCollections(summaries);
    } catch (e, st) {
      debugPrint('[SuperAdmin] RPC FAILED: $e');
      debugPrint('[SuperAdmin] Stack: $st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Dashboard load failed. ${friendlyError(e)}',
                style: const TextStyle(fontSize: 12)),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10),
          ),
        );
      }
      // Fallback: load institutions without finance data
      try {
        final result = await SupabaseService.client
            .from('institution')
            .select(
                'ins_id, insname, inscode, inshortname, inslogo, insmail, insmobno, inscity, insstate, activestatus')
            .order('ins_id');
        final insList = List<Map<String, dynamic>>.from(result);
        final fallbackSummaries = insList
            .map((row) => _InstitutionFinanceSummary(
                  insId: row['ins_id'] as int? ?? 0,
                  insName: row['insname']?.toString() ?? 'Institution',
                  insCode: row['inscode']?.toString() ?? '',
                  insLogo: row['inslogo']?.toString(),
                  totalDemand: 0,
                  totalCollected: 0,
                  totalPending: 0,
                  transactionCount: 0,
                  activeStatus: row['activestatus'] == 1,
                ))
            .toList();
        if (mounted) {
          setState(() {
            _institutions = insList;
            _institutionSummaries = fallbackSummaries;
            _loadingInstitutions = false;
            _loadingFinanceData = false;
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _loadingInstitutions = false;
            _loadingFinanceData = false;
          });
        }
      }
    }
  }

  Future<String> _fetchLatestYearLabel(int insId) async {
    try {
      final result = await SupabaseService.client
          .from('institutionyear')
          .select('yrlabel')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('iyr_id', ascending: false)
          .limit(1)
          .maybeSingle();

      final yrLabel = result?['yrlabel']?.toString();
      if (yrLabel != null && yrLabel.isNotEmpty) {
        return yrLabel;
      }
    } catch (e) {
      debugPrint('Error fetching latest year for institution $insId: $e');
    }

    final year = DateTime.now().year;
    return '$year-${year + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 800;

    return Scaffold(
      backgroundColor: AppColors.surface,
      body: Row(
        children: [
          if (isDesktop)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: _sidebarCollapsed ? 78 : 240,
              // Lay the sidebar out at its target width and clip — otherwise
              // the content overflows while the width tween is mid-flight.
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: _sidebarCollapsed ? 78 : 240,
                  maxWidth: _sidebarCollapsed ? 78 : 240,
                  child: _buildSidebar(context, _sidebarCollapsed),
                ),
              ),
            ),
          Expanded(
            child: Column(
              children: [
                _buildTopBar(context, isDesktop),
                Expanded(child: _buildContent(context)),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: isDesktop ? null : _buildMobileBottomNav(),
    );
  }

  Widget _buildMobileBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: List.generate(_navItems.length, (i) {
              final item = _navItems[i];
              final selected = _selectedNavIndex == i;
              return Expanded(
                child: InkWell(
                  onTap: () {
                    final prev = _selectedNavIndex;
                    setState(() {
                      _selectedNavIndex = i;
                      _aggregateDrilldownMode = null;
                      _courseWiseSummary = null;
                      _courseWiseMode = null;
                    });
                    if (i == 0 && prev != 0) _refreshDashboard();
                  },
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AppIcon(
                        selected ? item.icon : (item.unselectedIcon ?? item.icon),
                        style: selected ? AppIconStyle.bold : AppIconStyle.linear,
                        color: selected ? AppColors.accent : AppColors.textSecondary,
                        size: 22,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _bottomNavLabel(item.label),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                          color: selected ? AppColors.accent : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  String _bottomNavLabel(String label) {
    switch (label) {
      case 'Register Institution':
        return 'Register';
      case 'Manage Institutions':
        return 'Institutions';
      default:
        return label;
    }
  }

  Widget _buildSidebar(BuildContext context, bool collapsed) {
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

    final hPad = collapsed ? 12.0 : 14.0;

    return Container(
      color: AppColors.surfaceSidebar,
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 10 : 20,
              vertical: 20,
            ),
            child: Row(
              children: [
                // Larger transparent tile so the E-mark detail is readable
                // — the previous 36×36 with tinted backdrop dimmed the
                // navy mark against the navy backdrop.
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Image.asset(
                    'assets/images/educore360_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const AppIcon(
                      'teacher',
                      color: AppColors.primary,
                      size: 18,
                    ),
                  ),
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 10),
                  const Text(
                    'EduCore 360',
                    style: TextStyle(
                      fontSize: 17,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Builder(
                    builder: (ctx) {
                      final scaffold = Scaffold.maybeOf(ctx);
                      if (scaffold == null || !scaffold.isEndDrawerOpen) {
                        return const SizedBox.shrink();
                      }
                      return IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const AppIcon('Close_SM', size: 22),
                        tooltip: 'Close',
                        splashRadius: 20,
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: AppVerticalScrollbar(
              builder: (context, controller) => ListView(
                controller: controller,
                padding: EdgeInsets.symmetric(horizontal: hPad),
                children: [
                  for (var s = 0; s < orderedSections.length; s++) ...[
                    if (!collapsed)
                      Padding(
                        padding: EdgeInsets.only(
                          top: s == 0 ? 4 : 18,
                          bottom: 8,
                          left: 10,
                        ),
                        child: Text(
                          orderedSections[s],
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: AppColors.accent,
                          ),
                        ),
                      )
                    else
                      SizedBox(height: s == 0 ? 4 : 18),
                    for (final idx in groupedIndices[orderedSections[s]]!)
                      _buildNavTile(context, idx, collapsed),
                  ],
                  const SizedBox(height: 16),
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

    const selectedBg = AppColors.primary;
    const selectedFg = AppColors.textOnPrimary;
    const unselectedFg = AppColors.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            final prevIndex = _selectedNavIndex;
            setState(() {
              _selectedNavIndex = index;
              // Clear any active drilldown so the chosen menu's page
              // actually renders instead of the previous drilldown view.
              _aggregateDrilldownMode = null;
              _courseWiseSummary = null;
              _courseWiseMode = null;
            });
            if (index == 0 && prevIndex != 0) {
              _refreshDashboard();
            }
            // Close drawer on mobile after selection
            final scaffold = Scaffold.maybeOf(context);
            if (scaffold != null && scaffold.isEndDrawerOpen) {
              scaffold.closeEndDrawer();
            }
          },
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 4 : 14,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: isSelected ? selectedBg : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                AppIcon(
                  isSelected ? item.icon : (item.unselectedIcon ?? item.icon),
                  style: isSelected ? AppIconStyle.bold : AppIconStyle.linear,
                  color: isSelected ? selectedFg : unselectedFg,
                  size: 20,
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.label,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 14,
                        color: isSelected ? selectedFg : unselectedFg,
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, bool isDesktop) {
    final auth = context.watch<AuthProvider>();
    final isMobile = MediaQuery.of(context).size.width <= 800;
    final inDrilldown = _aggregateDrilldownMode != null || _courseWiseSummary != null;

    // Mobile drilldown: minimal header — just an icon-only back button.
    if (isMobile && inDrilldown) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: () => setState(() {
                _aggregateDrilldownMode = null;
                _courseWiseSummary = null;
                _courseWiseMode = null;
              }),
              icon: AppIcon.linear('Chevron Left', size: 22, color: Colors.white),
              tooltip: 'Back',
              style: IconButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.all(8),
              ),
            ),
          ],
        ),
      );
    }

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
          if (isDesktop)
            _softIconButton(
              icon: _sidebarCollapsed ? 'menu-open' : 'menu-close',
              onTap: () => setState(() => _sidebarCollapsed = !_sidebarCollapsed),
            ),
          if (isMobile)
            // Profile pill on the LEFT (mobile only): avatar + name + email
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: AppColors.accent.withValues(alpha: 0.18),
                    child: Text(
                      (auth.userName ?? 'S')[0].toUpperCase(),
                      style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          auth.userName ?? 'Super Admin',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, color: AppColors.textPrimary, fontWeight: FontWeight.w700, height: 1.15),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          auth.userEmail ?? 'Super Admin',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w500, height: 1.15),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else ...[
            SizedBox(width: 14.w),
            // Menu name + date/time + refresh, left-aligned beside the collapse icon
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _navItems[_selectedNavIndex].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.2,
                      height: 1.1),
                ),
                SizedBox(height: 6.h),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Current date & time — refreshed on demand
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon('clock', size: 14, color: AppColors.accent),
                          const SizedBox(width: 6),
                          Text(
                            _formatHeaderDateTime(_lastUpdated),
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.accent),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 8.w),
                    // Refresh — updates the date & time to the current moment
                    InkWell(
                      onTap:
                          _loadingInstitutions ? null : _refreshDashboard,
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.accent,
                        ),
                        child: _loadingInstitutions
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : AppIcon('refresh',
                                size: 14, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (_trustName.isNotEmpty)
              Expanded(
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if ((_trustLogo ?? '').isNotEmpty) ...[
                        ClipOval(
                          child: Image.network(
                            _trustLogo!,
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                        SizedBox(width: 8.w),
                      ],
                      Flexible(
                        child: Text(
                          _trustName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: AppColors.accent,
                              letterSpacing: 0.2,
                              height: 1.15),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              const Spacer(),
          ],
          // Year filter — only on the Dashboard tab, and only when there's
          // a real choice to make. With a single distinct yrlabel across
          // every institution, the dropdown is decorative noise.
          if (_selectedNavIndex == 0 && _availableYears.length > 1) ...[
            SizedBox(width: 12.w),
            _buildYearFilter(),
          ],
          SizedBox(width: 12.w),
          if (isMobile)
            IconButton(
              onPressed: () async {
                await auth.logout();
                if (context.mounted) {
                  Navigator.pushReplacementNamed(context, AppRoutes.welcome);
                }
              },
              icon: const AppIcon('logout', size: 22, color: AppColors.textSecondary),
              tooltip: 'Sign out',
            )
          else
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
              padding: isMobile
                  ? const EdgeInsets.all(2)
                  : EdgeInsets.only(left: 4.w, right: 12.w, top: 4.h, bottom: 4.h),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: isMobile ? 18 : 26,
                    backgroundColor: AppColors.accent.withValues(alpha: 0.18),
                    child: Text(
                      (auth.userName ?? 'S')[0].toUpperCase(),
                      style: TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                        fontSize: isMobile ? 14 : 20,
                      ),
                    ),
                  ),
                  if (!isMobile) ...[
                    SizedBox(width: 12.w),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: isDesktop ? 220 : 140),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            auth.userName ?? 'Super Admin',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 16, color: AppColors.textPrimary, fontWeight: FontWeight.w700, height: 1.15, letterSpacing: -0.2),
                          ),
                          SizedBox(height: 2.h),
                          Text(
                            auth.userEmail ?? 'Super Admin',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w500, height: 1.15),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 8.w),
                    AppIcon.linear('Chevron Down', size: 16, color: AppColors.textSecondary),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _softIconButton({
    required String icon,
    bool iconLinear = false,
    bool filled = false,
    required VoidCallback onTap,
  }) {
    final bg = filled ? AppColors.primary : Colors.white;
    final fg = filled ? Colors.white : AppColors.textSecondary;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: iconLinear
              ? AppIcon.linear(icon, size: 28, color: fg)
              : AppIcon(icon, size: 28, color: fg),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_courseWiseSummary != null && _courseWiseMode != null) {
      return _CourseWiseCollectionPage(
        summary: _courseWiseSummary!,
        mode: _courseWiseMode!,
        todayOnly: _courseWiseTodayOnly,
        onBack: () => setState(() {
          _courseWiseSummary = null;
          _courseWiseMode = null;
          _courseWiseTodayOnly = false;
        }),
      );
    }
    if (_aggregateDrilldownMode != null) {
      return _AggregateDrilldownPage(
        summaries: _institutionSummaries,
        mode: _aggregateDrilldownMode!,
        onBack: () => setState(() => _aggregateDrilldownMode = null),
      );
    }
    switch (_selectedNavIndex) {
      case 1:
        return RegisterScreen(onRegistered: _refreshDashboard);
      case 2:
        return _buildManageInstitutions(context);
      case 3:
        return const _SuperAdminSettings();
      default:
        return _buildDashboardHome(context);
    }
  }

  Widget _buildDashboardHome(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width <= 800;
    if (isMobile) {
      return _buildMobileDashboardHome(context);
    }
    return Padding(
      padding: EdgeInsets.all(16.w),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loadingFinanceData)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_institutionSummaries.isEmpty)
            Expanded(
                child: Center(
                    child: Text('No institutions found',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w600))))
          else ...[
            _buildSummaryRow(),
            SizedBox(height: 16.h),
            Expanded(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(16.w, 16.h, 16.w, 12.h),
                      child: Row(
                        children: [
                          AppIcon('buildings-2', size: 18, color: AppColors.accent),
                          SizedBox(width: 8.w),
                          Text('Institutions Overview',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                          const Spacer(),
                          Text('${_institutionSummaries.length} institutes',
                              style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(16.w, 0, 16.w, 16.h),
                        child: ListView.separated(
                          padding: EdgeInsets.zero,
                          itemCount: _institutionSummaries.length,
                          separatorBuilder: (_, __) => SizedBox(height: 12.h),
                          itemBuilder: (context, index) {
                            final s = _institutionSummaries[index];
                            return _buildInstitutionCard(context, s);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMobileDashboardHome(BuildContext context) {
    if (_loadingFinanceData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_institutionSummaries.isEmpty) {
      return const Center(
        child: Text('No institutions found',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14, fontWeight: FontWeight.w600)),
      );
    }

    final activeCount = _institutionSummaries.where((s) => s.activeStatus).length;
    final totalDemand = _institutionSummaries.fold<double>(0, (sum, s) => sum + s.totalDemand);
    final totalCollection = _institutionSummaries.fold<double>(0, (sum, s) => sum + s.totalCollected);
    final totalTodayCollection = _institutionSummaries.fold<double>(0, (sum, s) => sum + s.todayCollected);
    final totalPending = _institutionSummaries.fold<double>(0, (sum, s) => sum + s.totalPending);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Page name (shown in body since header has profile + hamburger)
        Row(
          children: [
            Text(_navItems[_selectedNavIndex].label,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary, letterSpacing: -0.3)),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon('security-user', size: 12, color: AppColors.accent),
                  const SizedBox(width: 4),
                  const Text('Super Admin',
                      style: TextStyle(fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text("Here's a snapshot of all institutions",
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
        const SizedBox(height: 24),

        // Hero balance card — Total Demand
        Center(
          child: Column(
            children: [
              const Text('Total Demand',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(_formatAmount(totalDemand),
                  style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: AppColors.textPrimary, letterSpacing: -0.5)),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Action buttons
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () => setState(() => _selectedNavIndex = 1),
                  icon: AppIcon('add', size: 16, color: Colors.white),
                  label: const Text('Register'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () => setState(() => _selectedNavIndex = 2),
                  icon: AppIcon('buildings-2', size: 16, color: Colors.white),
                  label: const Text('Manage'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.textPrimary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),

        // Quick Stats — horizontal scroll cards
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Quick Stats',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            Text('$activeCount active',
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 110,
          // ScrollConfiguration enables mouse-drag and trackpad scrolling on
          // Windows desktop — the default Material behavior only listens for
          // touch, so the carousel was effectively static under a mouse.
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: const {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
                PointerDeviceKind.stylus,
              },
              scrollbars: false,
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              children: [
                _miniStatCard('tick-circle', 'Collection', _formatAmount(totalCollection), AppColors.success,
                    onTap: () => _showAggregateDrilldown(context, 'collection')),
                const SizedBox(width: 12),
                _miniStatCard('calendar', 'Today Collection', _formatAmount(totalTodayCollection), AppColors.success,
                    onTap: () => _showAggregateDrilldown(context, 'today_collection')),
                const SizedBox(width: 12),
                _miniStatCard('timer', 'Total Pending', _formatAmount(totalPending), AppColors.error,
                    onTap: () => _showAggregateDrilldown(context, 'pending')),
                const SizedBox(width: 12),
                _miniStatCard('buildings-2', 'Institutes', '$activeCount of ${_institutionSummaries.length}', AppColors.accent,
                    onTap: () => _showAggregateDrilldown(context, 'active')),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),

        // Institutions list (compact)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Institutions',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            InkWell(
              onTap: () => setState(() => _selectedNavIndex = 2),
              child: const Text('View all',
                  style: TextStyle(fontSize: 13, color: AppColors.accent, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ..._institutionSummaries.take(4).map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _mobileInstitutionRow(s),
            )),
      ],
    );
  }

  Widget _miniStatCard(String icon, String label, String value, Color color, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 160,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: AppIcon(icon, color: color, size: 16),
                ),
                const Spacer(),
                if (onTap != null)
                  AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileInstitutionRow(_InstitutionFinanceSummary s) {
    final expanded = _expandedInsIds.contains(s.insId);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              if (expanded) {
                _expandedInsIds.remove(s.insId);
              } else {
                _expandedInsIds.add(s.insId);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                    backgroundImage: (s.insLogo != null && s.insLogo!.isNotEmpty)
                        ? NetworkImage(s.insLogo!)
                        : null,
                    child: (s.insLogo == null || s.insLogo!.isEmpty)
                        ? Text(
                            s.insCode.isNotEmpty
                                ? s.insCode.toUpperCase()
                                : (s.insName.isNotEmpty ? s.insName[0] : 'I'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.w800))
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(s.insName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        const SizedBox(height: 2),
                        Text('Code: ${s.insCode}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_formatAmount(s.totalCollected),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                      Text(s.activeStatus ? 'Active' : 'Inactive',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: s.activeStatus ? AppColors.success : AppColors.textSecondary)),
                    ],
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 180),
                    turns: expanded ? 0.5 : 0,
                    child: AppIcon.linear('Chevron Down', size: 18, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      children: [
                        Container(height: 1, color: AppColors.border),
                        const SizedBox(height: 12),
                        _institutionMetricsGrid(s),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _institutionMetricsGrid(_InstitutionFinanceSummary s) {
    return LayoutBuilder(builder: (context, c) {
      final cardWidth = (c.maxWidth - 10) / 2;
      Widget cell({
        required String icon,
        required Color color,
        required String value,
        required String label,
        VoidCallback? onTap,
      }) {
        return SizedBox(
          width: cardWidth,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: AppIcon(icon, color: color, size: 14),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                        const SizedBox(height: 2),
                        Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 4),
                    AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                  ],
                ],
              ),
            ),
          ),
        );
      }

      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          cell(
            icon: 'wallet-1',
            color: AppColors.accent,
            value: _formatAmount(s.totalDemand),
            label: 'Total Demand',
            onTap: () => _showCourseWiseDemand(context, s),
          ),
          cell(
            icon: 'tick-circle',
            color: AppColors.accent,
            value: _formatAmount(s.totalCollected),
            label: 'Total Collection',
            onTap: () => _showCourseWiseCollection(context, s),
          ),
          cell(
            icon: 'calendar',
            color: AppColors.accent,
            value: _formatAmount(s.todayCollected),
            label: 'Today Collection',
            onTap: () => _showCourseWiseTodayCollection(context, s),
          ),
          cell(
            icon: 'timer',
            color: AppColors.accent,
            value: _formatAmount(s.totalPending),
            label: 'Total Pending',
            onTap: () => _showCourseWisePending(context, s),
          ),
        ],
      );
    });
  }

  Widget _buildSummaryRow() {
    final totalDemand =
        _institutionSummaries.fold<double>(0, (sum, s) => sum + s.totalDemand);
    final totalCollection = _institutionSummaries.fold<double>(
        0, (sum, s) => sum + s.totalCollected);
    final totalTodayCollection = _institutionSummaries.fold<double>(
        0, (sum, s) => sum + s.todayCollected);
    final totalPending = _institutionSummaries.fold<double>(
        0, (sum, s) => sum + s.totalPending);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      const gap = 12.0;
      final cols = w < 600 ? 2 : 4;
      final cardWidth = (w - gap * (cols - 1)) / cols;
      final cards = <Widget>[
        SizedBox(width: cardWidth, child: _buildSummaryCard('wallet-1', AppColors.accent, _formatAmount(totalDemand), 'Total Demand',
            onTap: () => _showAggregateDrilldown(context, 'demand'))),
        SizedBox(width: cardWidth, child: _buildSummaryCard('tick-circle', AppColors.accent, _formatAmount(totalCollection), 'Total Collection',
            onTap: () => _showAggregateDrilldown(context, 'collection'))),
        SizedBox(width: cardWidth, child: _buildSummaryCard('calendar', AppColors.accent, _formatAmount(totalTodayCollection), 'Today Collection',
            onTap: () => _showAggregateDrilldown(context, 'today_collection'))),
        SizedBox(width: cardWidth, child: _buildSummaryCard('timer', AppColors.accent, _formatAmount(totalPending), 'Total Pending',
            onTap: () => _showAggregateDrilldown(context, 'pending'))),
      ];
      return Wrap(spacing: gap, runSpacing: gap, children: cards);
    });
  }

  Widget _buildSummaryCard(String icon, Color iconColor, String value, String label, {VoidCallback? onTap}) {
    // Raw pixel sizes — don't scale with screenutil so cards stay readable
    // on narrow phone screens where .sp values would shrink below 5px.
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: AppIcon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary, letterSpacing: -0.2)),
                const SizedBox(height: 4),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          if (onTap != null)
            AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary),
        ],
      ),
    );
    return onTap != null
        ? InkWell(
            borderRadius: BorderRadius.circular(12.r),
            onTap: onTap,
            child: card,
          )
        : card;
  }

  void _showAggregateDrilldown(BuildContext context, String mode) {
    setState(() => _aggregateDrilldownMode = mode);
  }

  String _formatAmount(double amount) {
    if (amount == amount.roundToDouble()) {
      return '₹${amount.toInt().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{2})+(\d)(?!\d))'), (m) => '${m[1]},')}';
    }
    final parts = amount.toStringAsFixed(2).split('.');
    final intPart = parts[0].replaceAllMapped(
        RegExp(r'(\d)(?=(\d{2})+(\d)(?!\d))'), (m) => '${m[1]},');
    return '₹$intPart.${parts[1]}';
  }

  Widget _buildInstitutionCard(
      BuildContext context, _InstitutionFinanceSummary s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Builder(builder: (_) {
                final codeColor = _colorForInsCode(s.insCode);
                return Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: codeColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: codeColor.withValues(alpha: 0.55), width: 1.2),
                  ),
                  child: Center(
                    child: Text(
                      s.insCode.isNotEmpty
                          ? s.insCode.toUpperCase()
                          : (s.insName.isNotEmpty ? s.insName[0] : 'I'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: codeColor,
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(s.insName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: s.activeStatus
                      ? AppColors.success.withValues(alpha: 0.1)
                      : AppColors.textSecondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  s.activeStatus ? 'Active' : 'Inactive',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: s.activeStatus
                          ? AppColors.success
                          : AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            // Adaptive layout: stack vertically on mobile, 2-col on tablet,
            // single row on desktop.
            const gap = 12.0;
            final demand = _buildFinanceTile('Total Demand', s.totalDemand, AppColors.accent,
                icon: 'wallet-1', onTap: () => _showCourseWiseDemand(context, s));
            final collection = _buildFinanceTile('Total Collection', s.totalCollected, AppColors.success,
                icon: 'tick-circle', onTap: () => _showCourseWiseCollection(context, s));
            final approval = _buildFinanceTile('Today Collection', s.todayCollected, AppColors.success,
                icon: 'calendar', onTap: () => _showCourseWiseTodayCollection(context, s));
            final pending = _buildFinanceTile('Total Pending', s.totalPending, AppColors.error,
                icon: 'timer', onTap: () => _showCourseWisePending(context, s));

            if (w < 600) {
              // Mobile: stack vertically
              return Column(
                children: [
                  demand,
                  SizedBox(height: gap),
                  collection,
                  SizedBox(height: gap),
                  approval,
                  SizedBox(height: gap),
                  pending,
                ],
              );
            } else if (w < 1000) {
              // Tablet: 2-column grid for finance tiles
              final tileWidth = (w - gap) / 2;
              return Column(
                children: [
                  Row(children: [
                    SizedBox(width: tileWidth, child: demand),
                    SizedBox(width: gap),
                    SizedBox(width: tileWidth, child: collection),
                  ]),
                  SizedBox(height: gap),
                  Row(children: [
                    SizedBox(width: tileWidth, child: approval),
                    SizedBox(width: gap),
                    SizedBox(width: tileWidth, child: pending),
                  ]),
                ],
              );
            }
            // Desktop: single row, original layout
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: demand),
                  SizedBox(width: gap),
                  Expanded(child: collection),
                  SizedBox(width: gap),
                  Expanded(child: approval),
                  SizedBox(width: gap),
                  Expanded(child: pending),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildCollectionPendingTile(_InstitutionFinanceSummary s, Color collectionColor, Color pendingColor) {
    final pending = (s.totalPending - s.pendingApproval).clamp(0, double.infinity).toDouble();
    Widget half(String label, String value, Color color, VoidCallback onTap) {
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 14.h),
            child: Column(
              children: [
                Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.black)),
                SizedBox(height: 6.h),
                Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
              ],
            ),
          ),
        ),
      );
    }
    return Expanded(
      flex: 2,
      child: Container(
        decoration: BoxDecoration(
          color: collectionColor.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10.r),
          border: Border.all(color: collectionColor.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            half('Total Collection', _formatAmount(s.totalCollected), collectionColor, () => _showCourseWiseCollection(context, s)),
            Container(width: 1, height: 38.h, color: AppColors.border),
            half('Total Pending', _formatAmount(pending), pendingColor, () => _showCourseWisePending(context, s)),
          ],
        ),
      ),
    );
  }

  Widget _buildFinanceTile(String label, double amount, Color color,
      {String icon = 'wallet-1', VoidCallback? onTap}) {
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: AppIcon(icon, color: AppColors.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_formatAmount(amount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary, letterSpacing: -0.2)),
                const SizedBox(height: 4),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          if (onTap != null)
            AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary),
        ],
      ),
    );
    return onTap != null
        ? InkWell(
            borderRadius: BorderRadius.circular(10.r),
            onTap: onTap,
            child: tile)
        : tile;
  }

  void _showCourseWiseCollection(
      BuildContext context, _InstitutionFinanceSummary s) {
    setState(() {
      _courseWiseSummary = s;
      _courseWiseMode = 'collection';
      _courseWiseTodayOnly = false;
    });
  }

  void _showCourseWiseTodayCollection(
      BuildContext context, _InstitutionFinanceSummary s) {
    setState(() {
      _courseWiseSummary = s;
      _courseWiseMode = 'collection';
      _courseWiseTodayOnly = true;
    });
  }

  void _showCourseWisePending(
      BuildContext context, _InstitutionFinanceSummary s) {
    setState(() {
      _courseWiseSummary = s;
      _courseWiseMode = 'pending';
    });
  }

  void _showCourseWiseDemand(
      BuildContext context, _InstitutionFinanceSummary s) {
    setState(() {
      _courseWiseSummary = s;
      _courseWiseMode = 'demand';
    });
  }

  Widget _buildStatCard(BuildContext context, String title, String value,
      String icon, Color color) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.all(20.w),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14.r),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 48.w,
              height: 48.h,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12.r),
              ),
              child: AppIcon(icon, color: color, size: 18),
            ),
            SizedBox(width: 16.w),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.black)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstitutionFinanceSection(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'All Colleges Fee Overview',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(20.r),
                ),
                child: Text(
                  'View Only',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.black,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
          SizedBox(height: 16.h),
          if (_loadingFinanceData)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_institutionSummaries.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12.h),
              child: Text(
                'No fee collection data available yet.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.black),
              ),
            )
          else
            Column(mainAxisSize: MainAxisSize.min, children: [
            ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                controller: _institutionTableScrollCtrl,
                scrollDirection: Axis.horizontal,
                child: DataTable(
                headingRowColor: WidgetStateProperty.all(
                    AppColors.primary.withValues(alpha: 0.08)),
                columns: const [
                  DataColumn(label: Text('COLLEGE')),
                  DataColumn(label: Text('CODE')),
                  DataColumn(label: Text('FEE COLLECTION')),
                  DataColumn(label: Text('PENDING FEES')),
                  DataColumn(label: Text('TRANSACTIONS')),
                  DataColumn(label: Text('STATUS')),
                ],
                rows: _institutionSummaries.map((item) {
                  return DataRow(
                    cells: [
                      DataCell(Text(item.insName)),
                      DataCell(Text(item.insCode)),
                      DataCell(Text(_formatCurrency(item.totalCollected))),
                      DataCell(Text(_formatCurrency(item.totalPending))),
                      DataCell(Text('${item.transactionCount}')),
                      DataCell(
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 10.w, vertical: 4.h),
                          decoration: BoxDecoration(
                            color: item.activeStatus
                                ? AppColors.success.withValues(alpha: 0.1)
                                : AppColors.error.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20.r),
                          ),
                          child: Text(
                            item.activeStatus ? 'Active' : 'Inactive',
                            style: TextStyle(
                              color: item.activeStatus
                                  ? AppColors.success
                                  : AppColors.error,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            )),
            ClassicHScrollbar(controller: _institutionTableScrollCtrl),
            ]),
        ],
      ),
    );
  }

  Widget _buildRecentTransactionsSection(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent Transactions Across Colleges',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 16.h),
          if (_loadingFinanceData)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_recentTransactions.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12.h),
              child: Text(
                'No transactions found.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.black),
              ),
            )
          else
            Column(mainAxisSize: MainAxisSize.min, children: [
            ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                controller: _recentTransactionsScrollCtrl,
                scrollDirection: Axis.horizontal,
                child: DataTable(
                headingRowColor: WidgetStateProperty.all(
                    AppColors.primary.withValues(alpha: 0.08)),
                columns: const [
                  DataColumn(label: Text('COLLEGE')),
                  DataColumn(label: Text('PAY NO')),
                  DataColumn(label: Text('AMOUNT')),
                  DataColumn(label: Text('METHOD')),
                  DataColumn(label: Text('REFERENCE')),
                  DataColumn(label: Text('DATE')),
                  DataColumn(label: Text('STATUS')),
                ],
                rows: _recentTransactions.map((row) {
                  final payment = row.payment;
                  final date = payment.paydate ?? payment.createdat;
                  final isPaid = payment.paystatus == 'C';
                  final statusColor =
                      isPaid ? AppColors.success : AppColors.error;
                  final statusText = isPaid ? 'Paid' : payment.statusText;

                  return DataRow(
                    cells: [
                      DataCell(Text(row.institutionName)),
                      DataCell(Text(payment.paynumber ?? '—')),
                      DataCell(Text(_formatCurrency(payment.transtotalamount))),
                      DataCell(Text(payment.paymethod ?? '-')),
                      DataCell(
                        SizedBox(
                          width: 160.w,
                          child: Text(
                            payment.payreference ?? '-',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      DataCell(Text(_formatDate(date))),
                      DataCell(
                        Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 10.w, vertical: 4.h),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20.r),
                          ),
                          child: Text(
                            statusText,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            )),
            ClassicHScrollbar(controller: _recentTransactionsScrollCtrl),
            ]),
        ],
      ),
    );
  }

  String _formatCurrency(double value) {
    final fixed = value.toStringAsFixed(2);
    final parts = fixed.split('.');
    final whole = parts[0].replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (match) => ',',
    );
    return 'Rs. $whole.${parts[1]}';
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  Widget _buildManageInstitutions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              // Wrap so the button group flows below the title on narrow
              // viewports instead of overflowing horizontally.
              child: Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon('buildings-2', size: 18, color: AppColors.accent),
                      const SizedBox(width: 8),
                      const Text('All Institutions',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      const SizedBox(width: 10),
                      Text('${_institutions.length} institutes',
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      SizedBox(
                        height: 40,
                        child: OutlinedButton.icon(
                          onPressed: _syncingLogos ? null : _syncInstitutionLogos,
                          icon: _syncingLogos
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                              : AppIcon('refresh', size: 16, color: AppColors.accent),
                          label: const Text('Sync Logos'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accent,
                            side: const BorderSide(color: AppColors.accent),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: 40,
                        child: ElevatedButton.icon(
                          onPressed: () => setState(() => _selectedNavIndex = 1),
                          icon: AppIcon('add', size: 16, color: Colors.white),
                          label: const Text('Register New'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: AppVerticalScrollbar(
                builder: (context, controller) => _loadingInstitutions
                  ? const Center(child: CircularProgressIndicator())
                  : _institutions.isEmpty
                      ? Center(child: Text('No institutions found',
                          style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600)))
                      : ListView.separated(
                          controller: controller,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          itemCount: _institutions.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final ins = _institutions[index];
                            return Container(
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Builder(builder: (_) {
                                      final logo = ins['inslogo']?.toString() ?? '';
                                      final fallback = Text(
                                        (ins['insname'] as String? ?? 'I')[0].toUpperCase(),
                                        style: const TextStyle(
                                            color: AppColors.primary,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 18),
                                      );
                                      return Container(
                                        width: 72,
                                        height: 64,
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: AppColors.primary.withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        alignment: Alignment.center,
                                        child: logo.isEmpty
                                            ? fallback
                                            : Image.network(
                                                logo,
                                                fit: BoxFit.contain,
                                                errorBuilder: (_, __, ___) => fallback,
                                              ),
                                      );
                                    }),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            ins['insname'] ?? '',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 14,
                                                color: AppColors.textPrimary,
                                                height: 1.2),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Code: ${ins['inscode'] ?? ''}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: AppColors.textSecondary,
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: ins['activestatus'] == 1
                                            ? AppColors.success.withValues(alpha: 0.12)
                                            : AppColors.error.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        ins['activestatus'] == 1 ? 'Active' : 'Inactive',
                                        style: TextStyle(
                                          color: ins['activestatus'] == 1
                                              ? AppColors.success
                                              : AppColors.error,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SANavItem {
  final String icon;
  final String? unselectedIcon;
  final String label;
  final String section;
  const _SANavItem(this.icon, this.label, {this.unselectedIcon, this.section = 'MAIN MENU'});
}

class _InstitutionFinanceSummary {
  final int insId;
  final String insName;
  final String insCode;
  final String? insLogo;
  final double totalDemand;
  double totalCollected;
  double totalPending;
  final int transactionCount;
  final bool activeStatus;
  double todayCollected;
  double pendingApproval;

  _InstitutionFinanceSummary({
    required this.insId,
    required this.insName,
    required this.insCode,
    this.insLogo,
    this.todayCollected = 0,
    this.pendingApproval = 0,
    required this.totalDemand,
    required this.totalCollected,
    required this.totalPending,
    required this.transactionCount,
    required this.activeStatus,
  });
}

class _SuperAdminTransactionRow {
  final String institutionName;
  final String institutionCode;
  final PaymentModel payment;

  const _SuperAdminTransactionRow({
    required this.institutionName,
    required this.institutionCode,
    required this.payment,
  });
}

class _InstitutionDetailPage extends StatefulWidget {
  final _InstitutionFinanceSummary summary;
  const _InstitutionDetailPage({required this.summary});

  @override
  State<_InstitutionDetailPage> createState() => _InstitutionDetailPageState();
}

class _InstitutionDetailPageState extends State<_InstitutionDetailPage> {
  bool _loading = true;
  // Each entry: { class, collection, pending }
  List<Map<String, dynamic>> _classWiseData = [];

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    final s = widget.summary;
    try {
      // Single RPC call for course-wise breakdown
      final rpcResult = await SupabaseService.client
          .rpc('get_institution_course_summary', params: {
        'p_ins_id': s.insId,
      });
      final courseData = rpcResult != null
          ? List<Map<String, dynamic>>.from(rpcResult as List)
          : <Map<String, dynamic>>[];

      final classWise = courseData
          .map((row) => {
                'class': '${row['course'] ?? 'Other'} - ${row['class'] ?? ''}',
                'collection': (row['collection'] as num?)?.toDouble() ?? 0.0,
                'pending': (row['pending'] as num?)?.toDouble() ?? 0.0,
                'students': (row['students'] as num?)?.toInt() ?? 0,
              })
          .toList();

      if (mounted) {
        setState(() {
          _classWiseData = classWise;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading institution details: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(double amount) {
    if (amount == amount.roundToDouble()) {
      return '₹${amount.toInt().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{2})+(\d)(?!\d))'), (m) => '${m[1]},')}';
    }
    final parts = amount.toStringAsFixed(2).split('.');
    final intPart = parts[0].replaceAllMapped(
        RegExp(r'(\d)(?=(\d{2})+(\d)(?!\d))'), (m) => '${m[1]},');
    return '₹$intPart.${parts[1]}';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    const collectionColor = Color(0xFF43A047);
    const pendingColor = Color(0xFFEF5350);

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(s.insName),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: EdgeInsets.all(20.w),
              child: Column(
                children: [
                  // Summary row
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: EdgeInsets.symmetric(vertical: 16.h),
                          decoration: BoxDecoration(
                            color: collectionColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12.r),
                            border: Border.all(
                                color: collectionColor.withValues(alpha: 0.2)),
                          ),
                          child: Column(
                            children: [
                              Text('Total Collection',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: collectionColor)),
                              SizedBox(height: 6.h),
                              Text(
                                  _fmt(_classWiseData.fold<double>(
                                      0,
                                      (sum, r) =>
                                          sum +
                                          ((r['collection'] as double?) ?? 0))),
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      color: collectionColor)),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(width: 12.w),
                      Expanded(
                        child: Container(
                          padding: EdgeInsets.symmetric(vertical: 16.h),
                          decoration: BoxDecoration(
                            color: pendingColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12.r),
                            border: Border.all(
                                color: pendingColor.withValues(alpha: 0.2)),
                          ),
                          child: Column(
                            children: [
                              Text('Total Pending',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: pendingColor)),
                              SizedBox(height: 6.h),
                              Text(
                                  _fmt(_classWiseData.fold<double>(
                                      0,
                                      (sum, r) =>
                                          sum +
                                          ((r['pending'] as double?) ?? 0))),
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      color: pendingColor)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16.h),
                  // Table header + rows, sharing a reserved scrollbar lane
                  Expanded(
                    child: AppVerticalScrollbar(
                      header: Container(
                    padding:
                        EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.08),
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(12.r)),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                            flex: 3,
                            child: Padding(
                                padding: EdgeInsets.fromLTRB(16.w, 0, 24.w, 0),
                                child: Text('Standard - Class',
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700)))),
                        Expanded(
                            child: Text('Students',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.accent),
                                textAlign: TextAlign.right)),
                        Expanded(
                            child: Text('Collection',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: collectionColor),
                                textAlign: TextAlign.right)),
                        Expanded(
                            child: Text('Pending',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: pendingColor),
                                textAlign: TextAlign.right)),
                      ],
                    ),
                  ),
                      builder: (context, controller) => Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(12.r)),
                        border: Border(
                          left: BorderSide(color: AppColors.border),
                          right: BorderSide(color: AppColors.border),
                          bottom: BorderSide(color: AppColors.border),
                        ),
                      ),
                      child: _classWiseData.isEmpty
                          ? Center(
                              child: Text('No data',
                                  style: TextStyle(
                                      color: Colors.black,
                                      fontSize: 13)))
                          : ListView.separated(
                              controller: controller,
                              itemCount: _classWiseData.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, color: AppColors.border),
                              itemBuilder: (context, index) {
                                final row = _classWiseData[index];
                                final cls = row['class'] as String;
                                final collection =
                                    (row['collection'] as double?) ?? 0;
                                final pending =
                                    (row['pending'] as double?) ?? 0;
                                return Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 16.w, vertical: 12.h),
                                  child: Row(
                                    children: [
                                      Expanded(
                                          flex: 3,
                                          child: Text(cls,
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight:
                                                      FontWeight.w600))),
                                      Expanded(
                                          child: Text('${row['students'] ?? 0}',
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: AppColors.accent),
                                              textAlign: TextAlign.right)),
                                      Expanded(
                                          child: Text(_fmt(collection),
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w700,
                                                  color: collectionColor),
                                              textAlign: TextAlign.right)),
                                      Expanded(
                                          child: Text(_fmt(pending),
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w700,
                                                  color: pendingColor),
                                              textAlign: TextAlign.right)),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                      ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _CourseWiseCollectionPage extends StatefulWidget {
  final _InstitutionFinanceSummary summary;
  final String mode; // 'collection' or 'pending'
  final bool todayOnly;
  final VoidCallback? onBack;
  const _CourseWiseCollectionPage(
      {required this.summary, this.mode = 'collection', this.todayOnly = false, this.onBack});

  @override
  State<_CourseWiseCollectionPage> createState() =>
      _CourseWiseCollectionPageState();
}

class _CourseWiseCollectionPageState extends State<_CourseWiseCollectionPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  DateTime? _filterFrom;
  DateTime? _filterTo;
  String? _schema;
  String? _activePreset;

  @override
  void initState() {
    super.initState();
    if (widget.todayOnly && widget.mode == 'collection') {
      final now = DateTime.now();
      _filterFrom = DateTime(now.year, now.month, now.day);
      _filterTo = DateTime(now.year, now.month, now.day);
      _activePreset = 'today';
    }
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (widget.mode == 'approval') {
        await _loadApprovalFromPayments();
      } else if (widget.mode == 'collection' &&
          (_filterFrom != null || _filterTo != null)) {
        await _loadCollectionFromPayments();
      } else {
        final rpc = await SupabaseService.client.rpc(
            'get_institution_course_summary',
            params: {'p_ins_id': widget.summary.insId});
        if (rpc != null) {
          final all = List<Map<String, dynamic>>.from(rpc as List).map((r) {
            // RPC now returns `demand` directly (sum of feeamount). Fall back
            // to `collection + pending` only for backward compatibility with
            // older RPC versions that don't expose `demand`.
            final demand = (r['demand'] as num?)?.toDouble();
            if (demand != null) return Map<String, dynamic>.from(r);
            final collection = (r['collection'] as num?)?.toDouble() ?? 0;
            final pending = (r['pending'] as num?)?.toDouble() ?? 0;
            return {...r, 'demand': collection + pending};
          }).toList();
          _rows = all
              .where((r) => ((r[widget.mode] as num?)?.toDouble() ?? 0) > 0)
              .toList();

          // RPC now returns unpaid_students / paid_students directly
          // (FILTER WHERE balancedue > 0 / paidamount > 0). Parallel query is
          // no longer needed and was producing wrong counts when
          // students.stuclass diverged from feedemand.stuclass.
          if (widget.mode == 'approval') {
            await _computeStudentCounts();
          }
        }
      }
    } catch (e) {
      debugPrint('course-wise ${widget.mode} error: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<String?> _resolveSchema() async {
    if (_schema != null) return _schema;
    final now = DateTime.now();
    final insRow = await SupabaseService.client
        .from('institution')
        .select('inshortname')
        .eq('ins_id', widget.summary.insId)
        .maybeSingle();
    final shortName = (insRow?['inshortname'] as String?)?.toLowerCase();
    if (shortName == null) return null;
    final yearRows = await SupabaseService.client
        .from('institutionyear')
        .select('yrlabel, iyrstadate, iyrenddate')
        .eq('ins_id', widget.summary.insId)
        .eq('activestatus', 1)
        .order('iyr_id', ascending: false);
    final years = List<Map<String, dynamic>>.from(yearRows as List);
    if (years.isEmpty) return null;
    String? yearLabel;
    for (final y in years) {
      final start = DateTime.tryParse(y['iyrstadate']?.toString() ?? '');
      final end = DateTime.tryParse(y['iyrenddate']?.toString() ?? '');
      if (start != null &&
          end != null &&
          !now.isBefore(start) &&
          !now.isAfter(end)) {
        yearLabel = y['yrlabel']?.toString();
        break;
      }
    }
    yearLabel ??= years.first['yrlabel']?.toString();
    if (yearLabel == null) return null;
    _schema = '$shortName${yearLabel.replaceAll('-', '')}';
    return _schema;
  }

  String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _loadCollectionFromPayments() async {
    final schema = await _resolveSchema();
    if (schema == null) {
      _rows = [];
      return;
    }
    var q = SupabaseService.client
        .schema(schema)
        .from('payment')
        .select('stu_id, transtotalamount, paydate')
        .eq('paystatus', 'C')
        .eq('activestatus', 1);
    if (_filterFrom != null) q = q.gte('paydate', _dateStr(_filterFrom!));
    if (_filterTo != null) {
      q = q.lt('paydate', _dateStr(_filterTo!.add(const Duration(days: 1))));
    }
    final payments = await q;
    final paymentList = List<Map<String, dynamic>>.from(payments as List);
    final stuIds = paymentList
        .map((p) => p['stu_id'])
        .where((id) => id != null)
        .toSet()
        .toList();
    if (stuIds.isEmpty) {
      _rows = [];
      return;
    }
    final students = await SupabaseService.client
        .schema(schema)
        .from('students')
        .select('stu_id, stuclass, clagrpname')
        .inFilter('stu_id', stuIds);
    final stuMap = <int, Map<String, dynamic>>{};
    for (final s in (students as List)) {
      final id = s['stu_id'];
      if (id is int) stuMap[id] = Map<String, dynamic>.from(s as Map);
    }

    final groups = <String, Map<String, dynamic>>{};
    for (final p in paymentList) {
      final stuId = p['stu_id'];
      final s = stuMap[stuId is int ? stuId : int.tryParse('$stuId')];
      final course = (s?['clagrpname'] ?? 'Other').toString();
      final cls = (s?['stuclass'] ?? '').toString();
      final key = '$course|$cls';
      final amt = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
      final g = groups.putIfAbsent(
          key,
          () => {
                'course': course,
                'class': cls,
                'collection': 0.0,
                '_stu_ids': <dynamic>{},
              });
      g['collection'] = (g['collection'] as double) + amt;
      (g['_stu_ids'] as Set).add(stuId);
    }

    final result = groups.values.map((g) {
      final paid = (g['_stu_ids'] as Set).length;
      g.remove('_stu_ids');
      g['paid_students'] = paid;
      return g;
    }).toList()
      ..sort(
          (a, b) => (a['course'] as String).compareTo(b['course'] as String));
    _rows = result
        .where((r) => ((r['collection'] as num?)?.toDouble() ?? 0) > 0)
        .toList();
  }

  Future<void> _loadApprovalFromPayments() async {
    final schema = await _resolveSchema();
    if (schema == null) {
      _rows = [];
      return;
    }
    final payments = await SupabaseService.client
        .schema(schema)
        .from('payment')
        .select('pay_id, stu_id, transtotalamount')
        .eq('paystatus', 'C')
        .eq('recon_status', 'P')
        .eq('activestatus', 1);
    final paymentList = List<Map<String, dynamic>>.from(payments as List);
    if (paymentList.isEmpty) {
      _rows = [];
      return;
    }
    final payIds = paymentList
        .map((p) => p['pay_id'])
        .whereType<int>()
        .toList();
    final demFineByPay = <int, double>{};
    for (int i = 0; i < payIds.length; i += 200) {
      final chunk = payIds.sublist(i, (i + 200).clamp(0, payIds.length));
      final pd = await SupabaseService.client
          .schema(schema)
          .from('paymentdetails')
          .select('pay_id, dem_id')
          .inFilter('pay_id', chunk);
      final demIds = (pd as List)
          .map((r) => r['dem_id'])
          .whereType<int>()
          .toSet()
          .toList();
      final demFine = <int, double>{};
      for (int j = 0; j < demIds.length; j += 200) {
        final dchunk = demIds.sublist(j, (j + 200).clamp(0, demIds.length));
        final fd = await SupabaseService.client
            .schema(schema)
            .from('feedemand')
            .select('dem_id, fineamount')
            .inFilter('dem_id', dchunk);
        for (final r in (fd as List)) {
          demFine[r['dem_id'] as int] =
              (demFine[r['dem_id'] as int] ?? 0) +
                  ((r['fineamount'] as num?)?.toDouble() ?? 0);
        }
      }
      for (final r in pd) {
        final pid = r['pay_id'] as int?;
        final did = r['dem_id'] as int?;
        if (pid == null) continue;
        demFineByPay[pid] =
            (demFineByPay[pid] ?? 0) + (did != null ? (demFine[did] ?? 0) : 0);
      }
    }

    final stuIds = paymentList
        .map((p) => p['stu_id'])
        .where((id) => id != null)
        .toSet()
        .toList();
    final students = await SupabaseService.client
        .schema(schema)
        .from('students')
        .select('stu_id, stuclass, clagrpname')
        .inFilter('stu_id', stuIds);
    final stuMap = <int, Map<String, dynamic>>{};
    for (final s in (students as List)) {
      final id = s['stu_id'];
      if (id is int) stuMap[id] = Map<String, dynamic>.from(s as Map);
    }

    final groups = <String, Map<String, dynamic>>{};
    for (final p in paymentList) {
      final stuId = p['stu_id'];
      final s = stuMap[stuId is int ? stuId : int.tryParse('$stuId')];
      final course = (s?['clagrpname'] ?? 'Other').toString();
      final cls = (s?['stuclass'] ?? '').toString();
      final key = '$course|$cls';
      final amt = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
      final pid = p['pay_id'] as int?;
      final fine = pid != null ? (demFineByPay[pid] ?? 0) : 0;
      final net = (amt - fine).clamp(0, double.infinity).toDouble();
      final g = groups.putIfAbsent(
          key,
          () => {
                'course': course,
                'class': cls,
                'approval': 0.0,
                '_stu_ids': <dynamic>{},
              });
      g['approval'] = (g['approval'] as double) + net;
      (g['_stu_ids'] as Set).add(stuId);
    }

    final result = groups.values.map((g) {
      final count = (g['_stu_ids'] as Set).length;
      g.remove('_stu_ids');
      g['approval_students'] = count;
      return g;
    }).toList()
      ..sort(
          (a, b) => (a['course'] as String).compareTo(b['course'] as String));
    _rows = result
        .where((r) => ((r['approval'] as num?)?.toDouble() ?? 0) > 0)
        .toList();
  }

  Future<void> _computeStudentCounts() async {
    try {
      final now = DateTime.now();
      final insRow = await SupabaseService.client
          .from('institution')
          .select('inshortname')
          .eq('ins_id', widget.summary.insId)
          .maybeSingle();
      final shortName = (insRow?['inshortname'] as String?)?.toLowerCase();
      if (shortName == null) return;

      final yearRows = await SupabaseService.client
          .from('institutionyear')
          .select('yrlabel, iyrstadate, iyrenddate')
          .eq('ins_id', widget.summary.insId)
          .eq('activestatus', 1)
          .order('iyr_id', ascending: false);
      final years = List<Map<String, dynamic>>.from(yearRows as List);
      if (years.isEmpty) return;

      String? yearLabel;
      for (final y in years) {
        final start = DateTime.tryParse(y['iyrstadate']?.toString() ?? '');
        final end = DateTime.tryParse(y['iyrenddate']?.toString() ?? '');
        if (start != null &&
            end != null &&
            !now.isBefore(start) &&
            !now.isAfter(end)) {
          yearLabel = y['yrlabel']?.toString();
          break;
        }
      }
      yearLabel ??= years.first['yrlabel']?.toString();
      if (yearLabel == null) return;

      final schema = '$shortName${yearLabel.replaceAll('-', '')}';
      final isPending = widget.mode == 'pending';
      final fieldKey = isPending ? 'unpaid_students' : 'paid_students';

      final stuIds = <dynamic>{};
      const pageSize = 1000;
      int offset = 0;
      while (true) {
        final List page = isPending
            ? await SupabaseService.client
                .schema(schema)
                .from('feedemand')
                .select('stu_id')
                .gt('balancedue', 0)
                .eq('activestatus', 1)
                .range(offset, offset + pageSize - 1)
            : await SupabaseService.client
                .schema(schema)
                .from('payment')
                .select('stu_id')
                .eq('paystatus', 'C')
                .eq('activestatus', 1)
                .range(offset, offset + pageSize - 1);
        for (final r in page) {
          if (r['stu_id'] != null) stuIds.add(r['stu_id']);
        }
        if (page.length < pageSize) break;
        offset += pageSize;
      }
      final stuIdsList = stuIds.toList();
      if (stuIds.isEmpty) {
        for (final r in _rows) {
          r[fieldKey] = 0;
        }
        return;
      }

      final counts = <String, int>{};
      for (int i = 0; i < stuIdsList.length; i += 200) {
        final chunk = stuIdsList.sublist(i, (i + 200).clamp(0, stuIdsList.length));
        final students = await SupabaseService.client
            .schema(schema)
            .from('students')
            .select('stu_id, stuclass, clagrpname')
            .inFilter('stu_id', chunk);
        for (final s in (students as List)) {
          final key = '${s['clagrpname'] ?? 'Other'}|${s['stuclass'] ?? ''}';
          counts[key] = (counts[key] ?? 0) + 1;
        }
      }
      for (final r in _rows) {
        final key = '${r['course'] ?? 'Other'}|${r['class'] ?? ''}';
        r[fieldKey] = counts[key] ?? 0;
      }
    } catch (e) {
      debugPrint('student counts (${widget.mode}) error: $e');
    }
  }

  Future<void> _openDateFilter() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        DateTime? from = _filterFrom;
        DateTime? to = _filterTo;
        return StatefulBuilder(builder: (ctx, setStateDialog) {
          Widget presetChip(String label, VoidCallback onTap) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(label,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  ),
                ),
              );

          Widget datePickerBox({required String hint, required DateTime? value, required ValueChanged<DateTime> onChanged}) {
            return InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: value ?? DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                );
                if (picked != null) onChanged(picked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon('calendar-1', size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Text(
                      value != null
                          ? '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}'
                          : hint,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: value != null ? AppColors.textPrimary : AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            );
          }

          Widget sectionLabel(String text) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary, letterSpacing: 0.3)),
              );

          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            title: Row(
              children: [
                Text('Filters', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const AppIcon.linear('close-circle', size: 20, color: AppColors.textSecondary),
                  splashRadius: 18,
                  tooltip: 'Close',
                ),
              ],
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  sectionLabel('QUICK RANGE'),
                  Row(children: [
                    presetChip('Today', () {
                      final now = DateTime.now();
                      setStateDialog(() {
                        from = DateTime(now.year, now.month, now.day);
                        to = DateTime(now.year, now.month, now.day);
                      });
                    }),
                    presetChip('7 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() {
                        from = now.subtract(const Duration(days: 7));
                        to = DateTime(now.year, now.month, now.day);
                      });
                    }),
                    presetChip('30 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() {
                        from = now.subtract(const Duration(days: 30));
                        to = DateTime(now.year, now.month, now.day);
                      });
                    }),
                    presetChip('All', () {
                      setStateDialog(() { from = null; to = null; });
                    }),
                  ]),
                  const SizedBox(height: 16),
                  sectionLabel('CUSTOM RANGE'),
                  Row(children: [
                    Expanded(child: datePickerBox(hint: 'From', value: from, onChanged: (d) => setStateDialog(() => from = d))),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('—')),
                    Expanded(child: datePickerBox(hint: 'To', value: to, onChanged: (d) => setStateDialog(() => to = d))),
                  ]),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setStateDialog(() { from = null; to = null; }),
                child: Text('Clear', style: TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () {
                  setState(() {
                    _filterFrom = from;
                    _filterTo = to;
                    _activePreset = null;
                  });
                  Navigator.pop(ctx);
                  _load();
                },
                child: const Text('Apply'),
              ),
            ],
          );
        });
      },
    );
  }

  String _fmt(double amount) {
    if (amount == amount.roundToDouble()) {
      return '₹${amount.toInt().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{2})+(\d)(?!\d))'), (m) => '${m[1]},')}';
    }
    final parts = amount.toStringAsFixed(2).split('.');
    final intPart = parts[0].replaceAllMapped(
        RegExp(r'(\d)(?=(\d{2})+(\d)(?!\d))'), (m) => '${m[1]},');
    return '₹$intPart.${parts[1]}';
  }

  int _studentsOf(Map<String, dynamic> r) {
    if (widget.mode == 'pending') {
      return (r['unpaid_students'] as num?)?.toInt() ?? 0;
    } else if (widget.mode == 'collection') {
      return (r['paid_students'] as num?)?.toInt() ?? 0;
    } else if (widget.mode == 'approval') {
      return (r['approval_students'] as num?)?.toInt() ?? 0;
    }
    return (r['students'] as num?)?.toInt() ?? 0;
  }

  /// Renders the course breakdown as a grouped register — each course is a
  /// section with an accent header, its per-class rows, and a S.Total row,
  /// matching the Date-wise Paid Collection Register style.
  Widget _buildCourseBreakdownTable(double rowPadH) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final r in _rows) {
      final course = '${r['course'] ?? 'Other'}';
      grouped.putIfAbsent(course, () => []).add(r);
    }

    // Single cell — flex + alignment shared by every row type.
    Widget cell(String text, int flex,
            {TextAlign? align, FontWeight? weight, Color? color}) =>
        Expanded(
          flex: flex,
          child: Text(text,
              textAlign: align,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: weight ?? FontWeight.w600,
                  color: color ?? AppColors.textSecondary)),
        );

    final rows = <Widget>[];
    grouped.forEach((course, classRows) {
      // Per-class rows. Course name shows in the STANDARD column on the first
      // row of each group (grouped-table style); blank on subsequent rows so
      // the eye groups them visually without a separate banner.
      for (var i = 0; i < classRows.length; i++) {
        final r = classRows[i];
        final amount = (r[widget.mode] as num?)?.toDouble() ?? 0;
        rows.add(Container(
          color: i.isEven ? Colors.white : AppColors.surface,
          padding: EdgeInsets.symmetric(horizontal: rowPadH, vertical: 8),
          child: Row(
            children: [
              cell(i == 0 ? course : '', 3,
                  weight: FontWeight.w700, color: AppColors.accent),
              cell('${r['class'] ?? ''}', 2),
              cell('${_studentsOf(r)}', 2, align: TextAlign.right),
              cell(_fmt(amount), 4,
                  align: TextAlign.right,
                  weight: FontWeight.w700,
                  color: AppColors.textPrimary),
            ],
          ),
        ));
      }

      // S.Total — per-course subtotal.
      final secStudents =
          classRows.fold<int>(0, (s, r) => s + _studentsOf(r));
      final secAmount = classRows.fold<double>(
          0, (s, r) => s + ((r[widget.mode] as num?)?.toDouble() ?? 0));
      rows.add(Container(
        color: AppColors.tableHeadBg,
        padding: EdgeInsets.symmetric(horizontal: rowPadH, vertical: 7),
        child: Row(
          children: [
            cell('S.Total', 3,
                weight: FontWeight.w700, color: AppColors.textPrimary),
            cell('', 2),
            cell('$secStudents', 2,
                align: TextAlign.right,
                weight: FontWeight.w700,
                color: AppColors.textPrimary),
            cell(_fmt(secAmount), 4,
                align: TextAlign.right,
                weight: FontWeight.w700,
                color: AppColors.textPrimary),
          ],
        ),
      ));
    });

    return ListView(children: rows);
  }

  @override
  Widget build(BuildContext context) {
    final String valueLabel;
    final String totalLabel;
    final String titleIcon;
    switch (widget.mode) {
      case 'pending':
        valueLabel = 'Pending';
        totalLabel = 'Total Pending';
        titleIcon = 'timer';
        break;
      case 'demand':
        valueLabel = 'Demand';
        totalLabel = 'Total Demand';
        titleIcon = 'wallet-1';
        break;
      case 'approval':
        valueLabel = 'Approval';
        totalLabel = 'Pending Approval';
        titleIcon = 'timer';
        break;
      default:
        valueLabel = 'Collection';
        totalLabel = (widget.todayOnly || _filterFrom != null || _filterTo != null)
            ? (widget.todayOnly ? 'Today Collection' : 'Filtered Collection')
            : 'Total Collection';
        titleIcon = 'tick-circle';
    }
    final double total;
    if (widget.mode == 'collection') {
      if (widget.todayOnly || _filterFrom != null || _filterTo != null) {
        total = _rows.fold<double>(
            0, (sum, r) => sum + ((r['collection'] as num?)?.toDouble() ?? 0));
      } else {
        total = widget.summary.totalCollected;
      }
    } else if (widget.mode == 'pending') {
      total = _rows.fold<double>(
          0, (sum, r) => sum + ((r['pending'] as num?)?.toDouble() ?? 0));
    } else if (widget.mode == 'approval') {
      total = _rows.fold<double>(
          0, (sum, r) => sum + ((r['approval'] as num?)?.toDouble() ?? 0));
    } else {
      total = widget.summary.totalDemand;
    }

    final isMobile = MediaQuery.of(context).size.width <= 800;
    final studentsHeader = isMobile
        ? (widget.mode == 'pending'
            ? 'UNPAID'
            : widget.mode == 'collection'
                ? 'PAID'
                : widget.mode == 'approval'
                    ? 'PEND.'
                    : 'STU')
        : (widget.mode == 'pending'
            ? 'UNPAID STUDENTS'
            : widget.mode == 'collection'
                ? 'PAID STUDENTS'
                : widget.mode == 'approval'
                    ? 'PENDING STUDENTS'
                    : 'STUDENTS');
    final rowPadH = isMobile ? 12.0 : 16.0;

    return Scaffold(
      backgroundColor: AppColors.surface,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(builder: (context, c) {
                    final isMobile = c.maxWidth < 700;
                    final backButton = InkWell(
                      onTap: widget.onBack ?? () => Navigator.of(context).pop(),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
                            const SizedBox(width: 6),
                            const Text('Back',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
                          ],
                        ),
                      ),
                    );
                    final totalPill = Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('$totalLabel: ',
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                          Text(_fmt(total),
                              style: const TextStyle(fontSize: 13, color: AppColors.accent, fontWeight: FontWeight.w800)),
                        ],
                      ),
                    );
                    final dateBtn = SizedBox(
                      height: 40,
                      child: OutlinedButton.icon(
                        onPressed: _openDateFilter,
                        icon: AppIcon('calendar-1', size: 16, color: AppColors.textPrimary),
                        label: const Text('Date',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.border),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    );
                    final refreshBtn = SizedBox(
                      height: 40,
                      child: ElevatedButton.icon(
                        onPressed: _load,
                        icon: AppIcon('refresh', size: 16, color: Colors.white),
                        label: const Text('Refresh'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    );
                    final breadcrumbText = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(widget.summary.insName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                        ),
                        const SizedBox(width: 6),
                        AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                        const SizedBox(width: 6),
                        Text('Standard-wise $valueLabel',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      ],
                    );

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: isMobile
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(widget.summary.insName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                                    ),
                                    const SizedBox(width: 6),
                                    AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text('Standard-wise $valueLabel',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    totalPill,
                                    if (widget.mode == 'collection' && !widget.todayOnly) dateBtn,
                                    if (widget.mode == 'collection') refreshBtn,
                                  ],
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                backButton,
                                const SizedBox(width: 12),
                                Container(width: 1, height: 18, color: AppColors.border),
                                const SizedBox(width: 12),
                                breadcrumbText,
                                const Spacer(),
                                totalPill,
                                if (widget.mode == 'collection') ...[
                                  const SizedBox(width: 12),
                                  if (!widget.todayOnly) ...[
                                    dateBtn,
                                    const SizedBox(width: 8),
                                  ],
                                  refreshBtn,
                                ],
                              ],
                            ),
                    );
                  }),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            child: Row(
                              children: [
                                AppIcon(titleIcon,
                                    size: 18, color: AppColors.accent),
                                const SizedBox(width: 8),
                                const Text('Standard-wise Breakdown',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary)),
                                const Spacer(),
                                Text('${_rows.length} ${_rows.length == 1 ? "standard" : "standards"}',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textSecondary,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              child: Container(
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Column(
                                  children: [
                                    Container(
                                      color: AppColors.tableHeadBg,
                                      padding: EdgeInsets.symmetric(
                                          horizontal: rowPadH, vertical: 12),
                                      child: Row(
                                        children: [
                                          Expanded(
                                              flex: 3,
                                              child: Text('STANDARD',
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w700,
                                                      color: AppColors.textPrimary,
                                                      letterSpacing: 0.4))),
                                          Expanded(
                                              flex: 2,
                                              child: Text('SECTION',
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w700,
                                                      color: AppColors.textPrimary,
                                                      letterSpacing: 0.4))),
                                          Expanded(
                                              flex: 2,
                                              child: Text(
                                                  studentsHeader,
                                                  textAlign: TextAlign.right,
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w700,
                                                      color: AppColors.textPrimary,
                                                      letterSpacing: 0.4))),
                                          Expanded(
                                              flex: 4,
                                              child: Text(
                                                  valueLabel.toUpperCase(),
                                                  textAlign: TextAlign.right,
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w700,
                                                      color: AppColors.textPrimary,
                                                      letterSpacing: 0.4))),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: _rows.isEmpty
                                          ? Center(
                                              child: Text('No data',
                                                  style: TextStyle(
                                                      fontSize: 13,
                                                      color: AppColors.textSecondary,
                                                      fontWeight: FontWeight.w600)))
                                          : _buildCourseBreakdownTable(rowPadH),
                                    ),
                                    if (_rows.isNotEmpty)
                                      Builder(builder: (_) {
                                        final totalStudents = _rows.fold<int>(
                                            0, (sum, r) => sum + _studentsOf(r));
                                        final double totalAmount;
                                        if (widget.mode == 'collection') {
                                          if (widget.todayOnly || _filterFrom != null || _filterTo != null) {
                                            totalAmount = _rows.fold<double>(
                                                0, (sum, r) => sum + ((r['collection'] as num?)?.toDouble() ?? 0));
                                          } else {
                                            totalAmount = widget.summary.totalCollected;
                                          }
                                        } else if (widget.mode == 'demand') {
                                          totalAmount = widget.summary.totalDemand;
                                        } else {
                                          totalAmount = _rows.fold<double>(
                                              0, (sum, r) => sum + ((r[widget.mode] as num?)?.toDouble() ?? 0));
                                        }
                                        return Container(
                                          decoration: const BoxDecoration(
                                            color: AppColors.tableHeadBg,
                                            border: Border(top: BorderSide(color: AppColors.border)),
                                          ),
                                          padding: EdgeInsets.symmetric(horizontal: rowPadH, vertical: 14),
                                          child: Row(
                                            children: [
                                              const Expanded(
                                                  flex: 3,
                                                  child: Text('GRAND TOTAL',
                                                      style: TextStyle(
                                                          fontSize: 13,
                                                          fontWeight: FontWeight.w800,
                                                          color: AppColors.textPrimary,
                                                          letterSpacing: 0.4))),
                                              const Expanded(flex: 2, child: SizedBox()),
                                              Expanded(
                                                  flex: 2,
                                                  child: Text('$totalStudents',
                                                      textAlign: TextAlign.right,
                                                      style: const TextStyle(
                                                          fontSize: 13,
                                                          fontWeight: FontWeight.w800,
                                                          color: AppColors.textPrimary))),
                                              Expanded(
                                                  flex: 4,
                                                  child: Text(_fmt(totalAmount),
                                                      textAlign: TextAlign.right,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                          fontSize: 13,
                                                          fontWeight: FontWeight.w800,
                                                          color: AppColors.textPrimary))),
                                            ],
                                          ),
                                        );
                                      }),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Super Admin Settings — reset username and password.
class _SuperAdminSettings extends StatefulWidget {
  const _SuperAdminSettings();
  @override
  State<_SuperAdminSettings> createState() => _SuperAdminSettingsState();
}

class _SuperAdminSettingsState extends State<_SuperAdminSettings> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _dobCtrl = TextEditingController();
  DateTime? _dob;
  final _currentPwdCtrl = TextEditingController();
  final _newPwdCtrl = TextEditingController();
  final _confirmPwdCtrl = TextEditingController();
  final _trustNameCtrl = TextEditingController();
  String? _trustLogoUrl;
  File? _trustLogoFile;
  String? _trustLogoFileName;
  bool _savingTrust = false;
  bool _saving = false;
  bool _showCurrent = false;
  bool _showNew = false;
  bool _showConfirm = false;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _usernameCtrl.text = auth.currentUser?.usename ?? '';
    _emailCtrl.text = auth.currentUser?.usemail ?? '';
    _loadProfile();
    _loadTrust();
  }

  Future<void> _loadTrust() async {
    try {
      final row = await SupabaseService.client
          .from('trust')
          .select('trust_name, trust_logo')
          .eq('trust_id', 1)
          .maybeSingle();
      if (!mounted || row == null) return;
      setState(() {
        _trustNameCtrl.text = (row['trust_name'] as String?) ?? '';
        _trustLogoUrl = row['trust_logo'] as String?;
      });
    } catch (_) {}
  }

  Future<void> _pickTrustLogo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg'],
    );
    if (result == null || result.files.single.path == null) return;
    final file = result.files.single;
    final ext = file.extension?.toLowerCase() ?? '';
    if (!['png', 'jpg', 'jpeg'].contains(ext)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Only PNG, JPG, JPEG formats are allowed'),
              backgroundColor: Colors.red),
        );
      }
      return;
    }
    setState(() {
      _trustLogoFile = File(file.path!);
      _trustLogoFileName = file.name;
    });
  }

  Future<void> _saveTrust() async {
    setState(() => _savingTrust = true);
    try {
      // Upload the picked logo first (if any) and capture its public URL.
      if (_trustLogoFile != null) {
        final ext = _trustLogoFile!.path.split('.').last.toLowerCase();
        final path = 'trust/logo.$ext';
        await SupabaseService.client.storage
            .from('InstitutionLogos')
            .upload(
              path,
              _trustLogoFile!,
              fileOptions: const FileOptions(upsert: true),
            );
        var url = SupabaseService.client.storage
            .from('InstitutionLogos')
            .getPublicUrl(path);
        // Bust the CDN cache so the new image shows immediately.
        url = '$url?v=${DateTime.now().millisecondsSinceEpoch}';
        _trustLogoUrl = url;
        _trustLogoFile = null;
        _trustLogoFileName = null;
      }
      await SupabaseService.client
          .from('trust')
          .update({
            'trust_name': _trustNameCtrl.text.trim(),
            'trust_logo': _trustLogoUrl,
            'updatedat': DateTime.now().toIso8601String(),
          })
          .eq('trust_id', 1);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trust settings saved'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _savingTrust = false);
    }
  }

  Future<void> _loadProfile() async {
    final auth = context.read<AuthProvider>();
    final useId = auth.currentUser?.useId;
    if (useId == null) return;
    try {
      final row = await SupabaseService.client
          .from('institutionusers')
          .select('usephone, usedob')
          .eq('use_id', useId)
          .maybeSingle();
      if (!mounted || row == null) return;
      setState(() {
        _phoneCtrl.text = row['usephone']?.toString() ?? '';
        final dobStr = row['usedob']?.toString();
        if (dobStr != null && dobStr.isNotEmpty) {
          _dob = DateTime.tryParse(dobStr);
          if (_dob != null) {
            _dobCtrl.text = '${_dob!.day.toString().padLeft(2, '0')}/'
                '${_dob!.month.toString().padLeft(2, '0')}/${_dob!.year}';
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _pickDob() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1940),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _dob = picked;
        _dobCtrl.text =
            '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
      });
    }
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _dobCtrl.dispose();
    _currentPwdCtrl.dispose();
    _newPwdCtrl.dispose();
    _confirmPwdCtrl.dispose();
    _trustNameCtrl.dispose();
    super.dispose();
  }

  Widget _buildTrustCard(bool isMobile) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(isMobile ? 16 : 20, 20, isMobile ? 16 : 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: AppIcon('buildings-2', color: AppColors.accent, size: 18),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Trust Settings',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      SizedBox(height: 2),
                      Text('Name shown at the top of the super-admin dashboard',
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('Trust Name'),
                      TextFormField(
                        controller: _trustNameCtrl,
                        readOnly: true,
                        canRequestFocus: false,
                        decoration: _inputDec('e.g. Krishnaswamy Educational Trust'),
                        style: _fieldStyle(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('Trust Logo (optional)'),
                      Row(
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppColors.border),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: _trustLogoFile != null
                                ? Image.file(_trustLogoFile!, fit: BoxFit.cover)
                                : ((_trustLogoUrl ?? '').isNotEmpty
                                    ? Image.network(
                                        _trustLogoUrl!,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Center(
                                          child: AppIcon('image', color: AppColors.textSecondary, size: 22),
                                        ),
                                      )
                                    : Center(
                                        child: AppIcon('image', color: AppColors.textSecondary, size: 22),
                                      )),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _trustLogoFileName ?? (((_trustLogoUrl ?? '').isNotEmpty) ? 'Current logo' : 'No logo selected'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: _pickTrustLogo,
                                      icon: AppIcon('document-upload', size: 14, color: AppColors.accent),
                                      label: Text(_trustLogoFile == null && (_trustLogoUrl ?? '').isEmpty ? 'Choose file' : 'Change'),
                                      style: OutlinedButton.styleFrom(
                                        side: const BorderSide(color: AppColors.border),
                                        foregroundColor: AppColors.textPrimary,
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    if (_trustLogoFile != null || (_trustLogoUrl ?? '').isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      TextButton(
                                        onPressed: () => setState(() {
                                          _trustLogoFile = null;
                                          _trustLogoFileName = null;
                                          _trustLogoUrl = null;
                                        }),
                                        child: const Text('Remove', style: TextStyle(fontSize: 12, color: Colors.redAccent, fontWeight: FontWeight.w600)),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            Center(
              child: SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _savingTrust ? null : _saveTrust,
                  icon: _savingTrust
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : AppIcon('save-2', size: 18, color: Colors.white),
                  label: Text(_savingTrust ? 'Saving…' : 'Save Trust',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    final useId = auth.currentUser?.useId;
    // Super admin verifies by USERNAME, not email (see verify_user_login RPC).
    final loginId = auth.currentUser?.usename;
    if (useId == null || loginId == null || loginId.isEmpty) return;

    setState(() => _saving = true);
    try {
      // Verify current password via the same login RPC.
      final verify = await SupabaseService.client.rpc('verify_user_login', params: {
        'p_email': loginId,
        'p_plain_password': _currentPwdCtrl.text,
        'p_is_super_admin': true,
      });
      final list = verify is List ? verify : const [];
      final ok = list.isNotEmpty && (list.first as Map)['is_valid'] == true;
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Current password is incorrect'), backgroundColor: Colors.red),
          );
        }
        setState(() => _saving = false);
        return;
      }

      final updates = <String, dynamic>{
        'usename': _usernameCtrl.text.trim(),
        'usemail': _emailCtrl.text.trim(),
        if (_phoneCtrl.text.trim().isNotEmpty) 'usephone': _phoneCtrl.text.trim(),
        if (_dob != null) 'usedob': _dob!.toIso8601String().split('T').first,
      };
      if (_newPwdCtrl.text.isNotEmpty) {
        // DB trigger hashes plaintext on UPDATE.
        updates['usepassword'] = _newPwdCtrl.text;
      }
      await SupabaseService.client
          .from('institutionusers')
          .update(updates)
          .eq('use_id', useId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings updated successfully'), backgroundColor: Colors.green),
        );
        _currentPwdCtrl.clear();
        _newPwdCtrl.clear();
        _confirmPwdCtrl.clear();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed. ${friendlyError(e)}'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
      );

  TextStyle _fieldStyle() => TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.textPrimary);

  String? _validateEmail(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Email required';
    if (!RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$').hasMatch(t)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  InputDecoration _inputDec(String hint, {Widget? suffix}) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.55), fontSize: 13, fontWeight: FontWeight.w500),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.accent, width: 1.5)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.error)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
        filled: true,
        fillColor: Colors.white,
        // No hover tint — read-only fields shouldn't look interactive.
        hoverColor: Colors.transparent,
        isDense: false,
        constraints: const BoxConstraints(minHeight: 48, maxHeight: 48),
        suffixIcon: suffix,
        suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 16, maxHeight: 16),
      );

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width <= 800;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _buildTrustCard(isMobile),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Form(
              key: _formKey,
              child: Padding(
                padding: EdgeInsets.fromLTRB(isMobile ? 16 : 20, 20, isMobile ? 16 : 20, 20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: AppIcon('setting-2', color: AppColors.accent, size: 18),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Account Settings',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        SizedBox(height: 2),
                        Text('Manage your account credentials',
                            style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (isMobile) ...[
                _label('Username'),
                TextFormField(
                  controller: _usernameCtrl,
                  readOnly: true,
                  canRequestFocus: false,
                  decoration: _inputDec('Enter username'),
                  style: _fieldStyle(),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Username required' : null,
                ),
                const SizedBox(height: 14),
                _label('Email'),
                TextFormField(
                  controller: _emailCtrl,
                  readOnly: true,
                  canRequestFocus: false,
                  decoration: _inputDec('Enter email'),
                  style: _fieldStyle(),
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  validator: _validateEmail,
                ),
              ] else
                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _label('Username'),
                    TextFormField(
                      controller: _usernameCtrl,
                      readOnly: true,
                      canRequestFocus: false,
                      decoration: _inputDec('Enter username'),
                      style: _fieldStyle(),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Username required' : null,
                    ),
                  ])),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _label('Email'),
                    TextFormField(
                      controller: _emailCtrl,
                      readOnly: true,
                      canRequestFocus: false,
                      decoration: _inputDec('Enter email'),
                      style: _fieldStyle(),
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      validator: _validateEmail,
                    ),
                  ])),
                ]),
              const SizedBox(height: 14),
              _label('Mobile No'),
              TextFormField(
                controller: _phoneCtrl,
                readOnly: true,
                canRequestFocus: false,
                decoration: _inputDec('Enter 10-digit mobile number'),
                style: _fieldStyle(),
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ],
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return null; // optional
                  if (!RegExp(r'^[6-9]\d{9}$').hasMatch(t)) {
                    return 'Enter a valid 10-digit mobile number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: AppIcon('lock', color: AppColors.accent, size: 18),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Change Password',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        SizedBox(height: 2),
                        Text('Leave new password blank to keep current',
                            style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: _label('Current Password *'),
              ),
              TextFormField(
                controller: _currentPwdCtrl,
                obscureText: !_showCurrent,
                decoration: _inputDec(
                  'Enter current password',
                  suffix: IconButton(
                    icon: AppIcon(_showCurrent ? 'eye-slash' : 'eye', size: 12, color: AppColors.textSecondary),
                    onPressed: () => setState(() => _showCurrent = !_showCurrent),
                  ),
                ),
                style: _fieldStyle(),
                validator: (v) => (v == null || v.isEmpty) ? 'Required to confirm changes' : null,
              ),
              const SizedBox(height: 14),
              if (isMobile) ...[
                _label('New Password'),
                TextFormField(
                  controller: _newPwdCtrl,
                  obscureText: !_showNew,
                  decoration: _inputDec(
                    'Leave blank to keep current',
                    suffix: IconButton(
                      icon: AppIcon(_showNew ? 'eye-slash' : 'eye', size: 12, color: AppColors.textSecondary),
                      onPressed: () => setState(() => _showNew = !_showNew),
                    ),
                  ),
                  style: _fieldStyle(),
                  validator: (v) {
                    if (v != null && v.isNotEmpty && v.length < 6) return 'Min 6 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                _label('Confirm New Password'),
                TextFormField(
                  controller: _confirmPwdCtrl,
                  obscureText: !_showConfirm,
                  decoration: _inputDec(
                    'Re-enter new password',
                    suffix: IconButton(
                      icon: AppIcon(_showConfirm ? 'eye-slash' : 'eye', size: 12, color: AppColors.textSecondary),
                      onPressed: () => setState(() => _showConfirm = !_showConfirm),
                    ),
                  ),
                  style: _fieldStyle(),
                  validator: (v) {
                    if (_newPwdCtrl.text.isEmpty) return null;
                    if (v != _newPwdCtrl.text) return 'Passwords do not match';
                    return null;
                  },
                ),
              ] else
                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _label('New Password'),
                    TextFormField(
                      controller: _newPwdCtrl,
                      obscureText: !_showNew,
                      decoration: _inputDec(
                        'Leave blank to keep current',
                        suffix: IconButton(
                          icon: AppIcon(_showNew ? 'eye-slash' : 'eye', size: 12, color: AppColors.textSecondary),
                          onPressed: () => setState(() => _showNew = !_showNew),
                        ),
                      ),
                      style: _fieldStyle(),
                      validator: (v) {
                        if (v != null && v.isNotEmpty && v.length < 6) return 'Min 6 characters';
                        return null;
                      },
                    ),
                  ])),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _label('Confirm New Password'),
                    TextFormField(
                      controller: _confirmPwdCtrl,
                      obscureText: !_showConfirm,
                      decoration: _inputDec(
                        'Re-enter new password',
                        suffix: IconButton(
                          icon: AppIcon(_showConfirm ? 'eye-slash' : 'eye', size: 12, color: AppColors.textSecondary),
                          onPressed: () => setState(() => _showConfirm = !_showConfirm),
                        ),
                      ),
                      style: _fieldStyle(),
                      validator: (v) {
                        if (_newPwdCtrl.text.isEmpty) return null;
                        if (v != _newPwdCtrl.text) return 'Passwords do not match';
                        return null;
                      },
                    ),
                  ])),
                ]),
              const SizedBox(height: 28),
              Center(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : AppIcon('save-2', size: 18, color: Colors.white),
                    label: Text(_saving ? 'Saving...' : 'Save Changes',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ),
            ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
  }
}

class _AggregateDrilldownPage extends StatelessWidget {
  final List<_InstitutionFinanceSummary> summaries;
  final String mode; // active | demand | collection | approval | pending
  final VoidCallback? onBack;
  const _AggregateDrilldownPage({required this.summaries, required this.mode, this.onBack});

  String get _title {
    switch (mode) {
      case 'active':
        return 'Active Institutes';
      case 'demand':
        return 'Total Demand';
      case 'collection':
        return 'Total Collection';
      case 'today_collection':
        return 'Today Collection';
      case 'approval':
        return 'Pending Approval';
      case 'pending':
        return 'Total Pending';
      default:
        return 'Drilldown';
    }
  }

  String get _columnLabel {
    switch (mode) {
      case 'active':
        return 'STATUS';
      case 'demand':
        return 'DEMAND';
      case 'collection':
        return 'COLLECTION';
      case 'today_collection':
        return 'TODAY COLLECTION';
      case 'approval':
        return 'PENDING APPROVAL';
      case 'pending':
        return 'PENDING';
      default:
        return 'VALUE';
    }
  }

  String _formatAmount(double amount) {
    if (amount == amount.roundToDouble()) {
      return '₹${amount.toInt().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{2})+(\d)(?!\d))'), (m) => '${m[1]},')}';
    }
    final parts = amount.toStringAsFixed(2).split('.');
    final intPart = parts[0].replaceAllMapped(
        RegExp(r'(\d)(?=(\d{2})+(\d)(?!\d))'), (m) => '${m[1]},');
    return '₹$intPart.${parts[1]}';
  }

  double _value(_InstitutionFinanceSummary s) {
    switch (mode) {
      case 'demand':
        return s.totalDemand;
      case 'today_collection':
        return s.todayCollected;
      case 'collection':
        return s.totalCollected;
      case 'approval':
        return s.pendingApproval;
      case 'pending':
        return s.totalPending;
      default:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = mode == 'active'
        ? summaries.where((s) => s.activeStatus).toList()
        : summaries.where((s) => _value(s) > 0).toList();
    if (mode != 'active') {
      filtered.sort((a, b) => _value(b).compareTo(_value(a)));
    }
    final aggregate = mode == 'active'
        ? filtered.length.toString()
        : _formatAmount(filtered.fold<double>(0, (sum, s) => sum + _value(s)));

    final isMobile = MediaQuery.of(context).size.width <= 800;
    final mobileColLabel = mode == 'approval' ? 'APPROVAL' : _columnLabel;
    final columnLabel = isMobile ? mobileColLabel : _columnLabel;
    final rowPadH = isMobile ? 12.0 : 16.0;

    final backButton = InkWell(
      onTap: onBack ?? () => Navigator.of(context).pop(),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
            const SizedBox(width: 6),
            const Text('Back',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
          ],
        ),
      ),
    );
    final totalPill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Total: ',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
          Text(aggregate,
              style: const TextStyle(fontSize: 13, color: AppColors.accent, fontWeight: FontWeight.w800)),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: AppColors.surface,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: isMobile
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text('Dashboard',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                            const SizedBox(width: 6),
                            AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(_title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        totalPill,
                      ],
                    )
                  : Row(
                      children: [
                        backButton,
                        const SizedBox(width: 12),
                        Container(width: 1, height: 18, color: AppColors.border),
                        const SizedBox(width: 12),
                        const Text('Dashboard',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textSecondary)),
                        const SizedBox(width: 6),
                        AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                        const SizedBox(width: 6),
                        Text(_title,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        const Spacer(),
                        totalPill,
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Row(
                        children: [
                          AppIcon('buildings-2', size: 18, color: AppColors.accent),
                          const SizedBox(width: 8),
                          const Text('Institution Breakdown',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                          const Spacer(),
                          Text('${filtered.length} institutes',
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Column(
                          children: [
                            Container(
                              color: AppColors.tableHeadBg,
                              padding: EdgeInsets.symmetric(horizontal: rowPadH, vertical: 12),
                              child: Row(
                                children: [
                                  const SizedBox(width: 28, child: Text('#', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.4))),
                                  const Expanded(flex: 5, child: Text('INSTITUTION', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.4))),
                                  Expanded(flex: 2, child: Text('CODE', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.4))),
                                  Expanded(flex: 4, child: Text(columnLabel, textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary, letterSpacing: 0.4))),
                                ],
                              ),
                            ),
                            Expanded(
                              child: filtered.isEmpty
                                  ? const Center(
                                      child: Text('No data',
                                          style: TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                                    )
                                  : ListView.builder(
                                      itemCount: filtered.length,
                                      itemBuilder: (_, i) {
                                        final s = filtered[i];
                                        final zebra = i.isOdd ? AppColors.surface : Colors.white;
                                        return Container(
                                          color: zebra,
                                          padding: EdgeInsets.symmetric(horizontal: rowPadH, vertical: 14),
                                          child: Row(
                                            children: [
                                              SizedBox(width: 28, child: Text('${i + 1}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                              Expanded(flex: 5, child: Text(s.insName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                              Expanded(flex: 2, child: Text(s.insCode, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                                              Expanded(
                                                flex: 4,
                                                child: mode == 'active'
                                                    ? Align(
                                                        alignment: Alignment.centerRight,
                                                        child: Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                          decoration: BoxDecoration(
                                                            color: s.activeStatus
                                                                ? AppColors.success.withValues(alpha: 0.1)
                                                                : AppColors.textSecondary.withValues(alpha: 0.1),
                                                            borderRadius: BorderRadius.circular(999),
                                                          ),
                                                          child: Text(
                                                            s.activeStatus ? 'Active' : 'Inactive',
                                                            style: TextStyle(
                                                                fontSize: 11,
                                                                fontWeight: FontWeight.w700,
                                                                color: s.activeStatus ? AppColors.success : AppColors.textSecondary),
                                                          ),
                                                        ),
                                                      )
                                                    : Text(_formatAmount(_value(s)),
                                                        textAlign: TextAlign.right,
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
