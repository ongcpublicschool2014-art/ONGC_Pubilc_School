import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
import '../../utils/formatters.dart';
import '../auth/register_screen.dart';

import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/card_title_block.dart';
import '../../widgets/app_vertical_scrollbar.dart';
import '../../widgets/classic_h_scrollbar.dart';
import '../../utils/friendly_error.dart';
import '../../utils/school_terms.dart';
import '../../utils/app_text.dart';
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
  // Manage Institutions screen: dedicated full-column list + table state.
  List<Map<String, dynamic>> _manageList = [];
  bool _manageLoaded = false;
  bool _manageLoading = false;
  String _manageFilter = 'all'; // all | active | inactive
  String _manageSearch = '';
  Map<String, dynamic>? _editInstitution; // set when editing via the Register wizard
  int _managePage = 0;
  final int _managePerPage = 10;
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

  // Trust-wide chart data (from get_super_admin_charts): reconciled collection
  // by normalised method and by month, aggregated across all institutions.
  Map<String, double> _superByMethod = {};
  Map<String, double> _superByMonth = {}; // 'YYYY-MM' -> amount

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
      padding: EdgeInsets.symmetric(horizontal: 12.w),
      height: AppUI.controlHeight(context),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedYear,
          isDense: true,
          icon: Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          style: AppUI.fieldText(context),
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
    return '$dd-$mo ${h12.toString().padLeft(2, '0')}:$mm $ampm';
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
    return '$dd-$mo-${d.year}  ${h12.toString().padLeft(2, '0')}:$mm $ampm';
  }

  /// Resolve each institution's CURRENT-year schema (the year whose date range
  /// contains today, else the latest active year) in just TWO batched queries
  /// for ALL institutions — instead of two lookups PER institution. Returns
  /// insId -> schema name.
  Future<Map<int, String>> _resolveCurrentSchemas(
      List<_InstitutionFinanceSummary> summaries) async {
    final result = <int, String>{};
    final ids = summaries.map((s) => s.insId).toList();
    if (ids.isEmpty) return result;
    final now = DateTime.now();
    try {
      final insRows = await SupabaseService.client
          .from('institution')
          .select('ins_id, inshortname')
          .inFilter('ins_id', ids);
      final shortById = <int, String>{};
      for (final r in (insRows as List)) {
        final id = (r['ins_id'] as num?)?.toInt();
        final sn = (r['inshortname'] as String?)?.toLowerCase();
        if (id != null && sn != null) shortById[id] = sn;
      }
      final yearRows = await SupabaseService.client
          .from('institutionyear')
          .select('ins_id, yrlabel, iyrstadate, iyrenddate')
          .inFilter('ins_id', ids)
          .eq('activestatus', 1)
          .order('iyr_id', ascending: false);
      final yearsById = <int, List<Map<String, dynamic>>>{};
      for (final r in List<Map<String, dynamic>>.from(yearRows as List)) {
        final id = (r['ins_id'] as num?)?.toInt();
        if (id == null) continue;
        yearsById.putIfAbsent(id, () => []).add(r);
      }
      for (final s in summaries) {
        final sn = shortById[s.insId];
        final years = yearsById[s.insId];
        if (sn == null || years == null || years.isEmpty) continue;
        String? yearLabel;
        for (final y in years) {
          final start = DateTime.tryParse(y['iyrstadate']?.toString() ?? '');
          final end = DateTime.tryParse(y['iyrenddate']?.toString() ?? '');
          if (start != null && end != null &&
              !now.isBefore(start) && !now.isAfter(end)) {
            yearLabel = y['yrlabel']?.toString();
            break;
          }
        }
        yearLabel ??= years.first['yrlabel']?.toString();
        if (yearLabel == null) continue;
        result[s.insId] = '$sn${yearLabel.replaceAll('-', '')}';
      }
    } catch (e) {
      debugPrint('schema resolve error: $e');
    }
    return result;
  }

  /// Trust-wide reconciled collection by method + by month (across all
  /// institution schemas). Degrades gracefully if the RPC isn't deployed.
  Future<void> _loadCharts() async {
    try {
      final res = await SupabaseService.client
          .rpc('get_super_admin_charts', params: {'p_yrlabel': _selectedYear});
      if (res is! Map) return;
      final method = <String, double>{};
      final rawMethod = res['by_method'];
      if (rawMethod is Map) {
        rawMethod.forEach((k, v) {
          final norm = _normPayMode(k.toString());
          method[norm] = (method[norm] ?? 0) + ((v as num?)?.toDouble() ?? 0);
        });
      }
      final month = <String, double>{};
      final rawMonth = res['by_month'];
      if (rawMonth is Map) {
        rawMonth.forEach((k, v) => month[k.toString()] = (v as num?)?.toDouble() ?? 0);
      }
      // Fold miscellaneous collections into the by-mode + monthly charts, so the
      // graph summary matches the admin dashboard (which includes misc).
      await _addMiscToCharts(method, month);
      if (mounted) setState(() {
        _superByMethod = method;
        _superByMonth = month;
      });
    } catch (e) {
      debugPrint('[SuperAdmin] charts RPC failed: $e');
    }
  }

  /// Add each institution's misc collections to the by-mode + monthly maps.
  Future<void> _addMiscToCharts(Map<String, double> method, Map<String, double> month) async {
    if (_institutionSummaries.isEmpty) return;
    try {
      final schemas = await _resolveCurrentSchemas(_institutionSummaries);
      await Future.wait(_institutionSummaries.map((s) async {
        final schema = schemas[s.insId];
        if (schema == null) return;
        try {
          // All-time, so this passes 1000 rows on any established institution.
          // Truncating would silently under-report the collection totals.
          final rows = await SupabaseService.fetchAll(() => SupabaseService
              .client
              .schema(schema)
              .from('misc_collection')
              .select('paymode, mcdate, totalamount')
              .eq('activestatus', 1));
          for (final r in (rows as List)) {
            final amt = (r['totalamount'] as num?)?.toDouble() ?? 0;
            if (amt <= 0) continue;
            final mode = _normPayMode(r['paymode']?.toString() ?? 'Cash');
            method[mode] = (method[mode] ?? 0) + amt;
            final d = r['mcdate']?.toString() ?? '';
            if (d.length >= 7) {
              final ym = d.substring(0, 7);
              month[ym] = (month[ym] ?? 0) + amt;
            }
          }
        } catch (_) {}
      }));
    } catch (e) {
      debugPrint('[SuperAdmin] misc charts merge failed: $e');
    }
  }

  String _normPayMode(String raw) {
    final m = raw.trim().toLowerCase();
    if (m.isEmpty) return 'Other';
    if (m.contains('cash')) return 'Cash';
    if (m.contains('upi') || m.contains('online') || m.contains('net') || m.contains('razor') || m.contains('paytm')) return 'Online';
    if (m.contains('card')) return 'Card';
    if (m.contains('dd') || m.contains('cheque') || m.contains('draft')) return 'DD/Cheque';
    return raw.trim();
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
        bool haveToday = false;
        for (final s in summaries) {
          final r = byId[s.insId];
          if (r == null) continue;
          // total_collected / total_pending are already correct from
          // get_super_admin_dashboard (SUM paidamount / SUM reconbalancedue,
          // matching the institution-admin cards). v2's versions drift to 0 (it
          // counts only recon_status='R' payments), so DON'T override them here —
          // take only pending_approval, which v2 uniquely provides.
          s.pendingApproval = (r['pending_approval'] as num?)?.toDouble() ?? 0;
          // today_collected is computed server-side (v2 is SECURITY DEFINER) so
          // it works for the superadmin, which runs as anon and CANNOT read the
          // tenant payment table directly. Older v2 (no column) → fall back.
          if (r['today_collected'] != null) {
            s.todayCollected = (r['today_collected'] as num?)?.toDouble() ?? 0;
            haveToday = true;
          }
        }
        if (mounted) setState(() {});
        if (!haveToday) await _loadTodayOnly(summaries);
        await _loadTodayMisc(summaries);
        return;
      }
    } catch (e) {
      debugPrint('v2 dashboard RPC failed, falling back: $e');
    }

    final now = DateTime.now();
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    // paydate is a TIMESTAMP, so match the whole day with a [today, tomorrow)
    // range — `.eq(paydate, dateStr)` only matched rows stamped at midnight and
    // so returned 0 for real (timestamped) collections.
    final tomorrow = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final tomorrowStr =
        '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
    // Resolve every institution's schema up front in 2 batched queries instead
    // of 2 lookups per institution inside the loop below.
    final schemas = await _resolveCurrentSchemas(summaries);
    await Future.wait(summaries.map((s) async {
      final schema = schemas[s.insId];
      if (schema == null) return;
      try {
        final rows = await SupabaseService.client
            .schema(schema)
            .from('payment')
            .select('transtotalamount')
            .eq('paystatus', 'C')
            .eq('recon_status', 'R')
            .gte('paydate', todayStr)
            .lt('paydate', tomorrowStr)
            .eq('activestatus', 1);
        s.todayCollected = (rows as List).fold<double>(
            0,
            (sum, r) =>
                sum + ((r['transtotalamount'] as num?)?.toDouble() ?? 0));

        // Pending Approval = sum of paymentdetails (per-fee allocation)
        // for payments awaiting reconciliation, excluding any FINE rows.
        // Paged: institution-wide, so past PostgREST's 1000-row cap.
        final pendingPays = await SupabaseService.fetchAll(() => SupabaseService
            .client
            .schema(schema)
            .from('payment')
            .select('pay_id')
            .eq('paystatus', 'C')
            .eq('recon_status', 'P')
            .eq('activestatus', 1));
        final pendingPayIds = (pendingPays as List)
            .map((r) => r['pay_id'])
            .whereType<int>()
            .toList();
        double pendingApproval = 0;
        for (int i = 0; i < pendingPayIds.length; i += 200) {
          final chunk = pendingPayIds.sublist(
              i, (i + 200).clamp(0, pendingPayIds.length));
          // Paged: a chunk of receipts has many lines each.
          final pd = await SupabaseService.fetchAll(() => SupabaseService.client
              .schema(schema)
              .from('paymentdetails')
              .select('dem_id, transtotalamount')
              .inFilter('pay_id', chunk));
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
    await _loadTodayMisc(summaries);
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
    // Two batched lookups resolve all schemas; then one payment query per
    // institution (was 3 sequential round-trips per institution before).
    final schemas = await _resolveCurrentSchemas(summaries);
    await Future.wait(summaries.map((s) async {
      final schema = schemas[s.insId];
      if (schema == null) return;
      try {
        final rows = await SupabaseService.client
            .schema(schema)
            .from('payment')
            .select('transtotalamount')
            .eq('paystatus', 'C')
            .eq('recon_status', 'R')
            .gte('paydate', todayStr)
            .lt('paydate', tomorrowStr)
            .eq('activestatus', 1);
        s.todayCollected = (rows as List).fold<double>(
            0, (sum, r) => sum + ((r['transtotalamount'] as num?)?.toDouble() ?? 0));
      } catch (e) {
        debugPrint('today-only fetch error for ${s.insName}: $e');
      }
    }));
    if (mounted) setState(() {});
  }

  /// Today's miscellaneous collection per institution (misc_collection.mcdate =
  /// today). Superadmin runs as anon; misc_collection is readable per-schema.
  Future<void> _loadTodayMisc(List<_InstitutionFinanceSummary> summaries) async {
    final now = DateTime.now();
    final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final schemas = await _resolveCurrentSchemas(summaries);
    await Future.wait(summaries.map((s) async {
      final schema = schemas[s.insId];
      if (schema == null) return;
      try {
        final rows = await SupabaseService.client
            .schema(schema)
            .from('misc_collection')
            .select('totalamount')
            .eq('activestatus', 1)
            .eq('mcdate', todayStr);
        s.todayMisc = (rows as List).fold<double>(
            0, (sum, r) => sum + ((r['totalamount'] as num?)?.toDouble() ?? 0));
      } catch (e) {
        debugPrint('today misc error for ${s.insName}: $e');
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
            totalConcession: (row['total_concession'] as num?)?.toDouble() ?? 0,
            totalMisc: (row['total_misc'] as num?)?.toDouble() ?? 0,
            totalFine: (row['total_fine'] as num?)?.toDouble() ?? 0,
            transactionCount: (row['transaction_count'] as num?)?.toInt() ?? 0,
            studentCount: (row['student_count'] as num?)?.toInt() ?? 0,
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
      _loadCharts();
    } catch (e, st) {
      debugPrint('[SuperAdmin] RPC FAILED: $e');
      debugPrint('[SuperAdmin] Stack: $st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not load the dashboard. ${friendlyError(e)}',
                style: const TextStyle(fontSize: 12)),
            backgroundColor: AppColors.error,
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
              width: _sidebarCollapsed ? 78 : (size.width < 1100 ? 200 : size.width < 1400 ? 230 : 270),
              // Lay the sidebar out at its target width and clip — otherwise
              // the content overflows while the width tween is mid-flight.
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: _sidebarCollapsed ? 78 : (size.width < 1100 ? 200 : size.width < 1400 ? 230 : 270),
                  maxWidth: _sidebarCollapsed ? 78 : (size.width < 1100 ? 200 : size.width < 1400 ? 230 : 270),
                  // Keep the sidebar out of keyboard Tab traversal so tabbing
                  // through a form doesn't jump into the nav menu between rows.
                  child: ExcludeFocus(child: _buildSidebar(context, _sidebarCollapsed)),
                ),
              ),
            ),
          Expanded(
            child: Column(
              children: [
                // Top bar kept out of Tab traversal (mouse-operated chrome).
                ExcludeFocus(child: _buildTopBar(context, isDesktop)),
                // FocusTraversalGroup keeps a page's form fields tabbing as one
                // contiguous unit, independent of the surrounding chrome.
                Expanded(child: FocusTraversalGroup(child: _buildContent(context))),
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

    final hPad = collapsed
        ? 12.w
        : (MediaQuery.of(context).size.width < 1100 ? 10.w : 14.w);

    return Container(
      decoration: const BoxDecoration(
        // Dark navy sidebar — light foreground on it.
        color: AppColors.sidebarBg,
        border: Border(right: BorderSide(color: AppColors.sidebarBorder, width: 1)),
      ),
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 12 : (MediaQuery.of(context).size.width < 1100 ? 14.w : 24.w),
              vertical: 20.h,
            ),
            child: Row(
              children: [
                // White plate behind the logo (same treatment as Login /
                // Welcome). The mark is dark navy on a transparent PNG, so
                // without this it sinks into the navy sidebar.
                ClipRRect(
                  borderRadius: BorderRadius.circular(collapsed ? 10 : 12),
                  child: Container(
                    width: collapsed ? 46 : 56.w,
                    height: collapsed ? 46 : 56.h,
                    color: Colors.white,
                    padding: EdgeInsets.all(collapsed ? 4 : 5),
                    child: Image.asset(
                      'assets/images/educore360_logo.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const AppIcon(
                        'teacher',
                        color: AppColors.primary,
                        size: 16,
                      ),
                    ),
                  ),
                ),
                if (!collapsed) ...[
                  SizedBox(width: 10.w),
                  // Expanded, not Flexible + Spacer: a Spacer is an Expanded
                  // that claims every spare pixel, so the loosely-fitted text
                  // beside it was squeezed down to "EduCo...". Expanded here
                  // gives the name the remaining width and drops the Spacer,
                  // which the close button below doesn't need.
                  Expanded(
                    child: Text(
                      'EduCore360',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16.sp,
                        color: AppColors.sidebarText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
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
                          top: s == 0 ? 4.h : 18.h,
                          bottom: 8.h,
                          left: 10.w,
                        ),
                        child: Text(
                          orderedSections[s],
                          style: AppUI.caps.copyWith(
                            color: AppColors.sidebarText.withValues(alpha: 0.6),
                          ),
                        ),
                      )
                    else
                      SizedBox(height: s == 0 ? 4.h : 18.h),
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
    // Navy sidebar — light foreground reads cleanest on it.
    const unselectedFg = AppColors.sidebarText;

    return Padding(
      padding: EdgeInsets.only(bottom: 10.h),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // Mouse-only: never take keyboard focus so Tab in a form never
          // lands on a nav item.
          canRequestFocus: false,
          onTap: () {
            final prevIndex = _selectedNavIndex;
            setState(() {
              _selectedNavIndex = index;
              // Register Institution from the nav = a fresh registration.
              if (index == 1) _editInstitution = null;
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
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
            decoration: BoxDecoration(
              // Active tile = solid accent pill on the navy sidebar.
              color: isSelected ? selectedBg : null,
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
            ),
            child: Row(
              mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Container(
                  width: 34.w, height: 34.w, alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: isSelected ? 0.22 : 0.07),
                    borderRadius: BorderRadius.circular(9.r),
                    border: Border.all(color: Colors.white.withValues(alpha: isSelected ? 0.28 : 0.10)),
                  ),
                  child: AppIcon(
                    isSelected ? item.icon : (item.unselectedIcon ?? item.icon),
                    style: isSelected ? AppIconStyle.bold : AppIconStyle.linear,
                    color: isSelected ? selectedFg : unselectedFg,
                    size: 20.sp,
                  ),
                ),
                if (!collapsed) ...[
                  SizedBox(width: 12.w),
                  Expanded(
                    child: Text(
                      item.label,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 13.5.sp,
                        color: isSelected ? selectedFg : unselectedFg,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18.sp, color: (isSelected ? selectedFg : unselectedFg).withValues(alpha: isSelected ? 0.95 : 0.5)),
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
        // Matches the admin dashboard header height (dashboard_screen.dart).
        vertical: 18,
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
                  style: AppUI.cardTitle.copyWith(height: 1.1),
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
              tooltip: 'Sign Out',
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
                    const Text('Sign Out'),
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
      borderRadius: BorderRadius.circular(AppUI.controlRadius),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
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
        return RegisterScreen(
          key: ValueKey('register_${_editInstitution?['ins_id'] ?? 'new'}'),
          editInstitution: _editInstitution,
          onRegistered: () {
            _refreshDashboard();
            setState(() { _manageLoaded = false; _editInstitution = null; });
          },
        );
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
                child: AppUI.empty(
                    icon: 'buildings-2',
                    title: 'No institutions found',
                    why: 'No institution has been registered yet. Use Register Institution in the menu to add one.'))
          else
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(bottom: 8.h),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _buildSummaryRow(),
                  SizedBox(height: AppUI.gap),
                  // Row 1: Institution Overview (left) + Collection Overview (right).
                  LayoutBuilder(builder: (context, c) {
                    if (c.maxWidth <= 1050) {
                      return Column(children: [_scInstitutionOverview(), SizedBox(height: AppUI.gap), _scCollectionOverview()]);
                    }
                    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 3, child: _scInstitutionOverview()),
                      SizedBox(width: AppUI.gap),
                      Expanded(flex: 2, child: _scCollectionOverview()),
                    ]);
                  }),
                  SizedBox(height: AppUI.gap),
                  // Row 2: Quick Actions (full width — Collection by Mode removed;
                  // the Collection Overview donut already shows the by-mode split).
                  _scQuickActions(),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  // ── Redesigned dashboard sections ──────────────────────────────────────────
  Widget _scPanel({required String icon, required String title, String? subtitle, Widget? trailing, required Widget child}) {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CardTitleBlock(icon: icon, title: title, subtitle: subtitle),
          const Spacer(),
          if (trailing != null) trailing,
        ]),
        SizedBox(height: 14.h),
        child,
      ]),
    );
  }

  Color _methodColor(String m) {
    switch (m) {
      case 'Cash':
        return AppColors.success;
      case 'Online':
        return AppColors.primary;
      case 'Card':
        return AppColors.demand;
      case 'DD/Cheque':
        return AppColors.warning;
      default:
        return AppColors.textLight;
    }
  }

  Widget _scStatChip(String icon, Color color, String value, String label) => Container(
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 12.h),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: color.withValues(alpha: 0.18))),
        child: Row(children: [
          AppUI.iconTile(icon, color: color, size: 16),
          SizedBox(width: 10.w),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.caps),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          ])),
        ]),
      );

  Widget _scStatusPill(bool active) =>
      AppUI.chip(active ? 'Active' : 'Inactive', active ? AppStatus.success : AppStatus.danger);

  Widget _scInstitutionOverview() {
    final active = _institutionSummaries.where((s) => s.activeStatus).length;
    final inactive = _institutionSummaries.length - active;
    final students = _institutionSummaries.fold<int>(0, (s, e) => s + e.studentCount);
    final top = [..._institutionSummaries]..sort((a, b) => b.totalCollected.compareTo(a.totalCollected));
    final topN = top.take(5).toList();
    Widget h(String t, {int flex = 2, TextAlign a = TextAlign.left}) => AppUI.th(t, flex: flex, align: a);
    return _scPanel(
      icon: 'buildings-2', title: 'Institution Overview', subtitle: 'Across every institution',
      trailing: TextButton(onPressed: _openAllInstitutions, child: const Text('View all')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: _scStatChip('tick-circle', AppColors.success, '$active', 'Active')),
          SizedBox(width: 10.w),
          Expanded(child: _scStatChip('close-circle', AppColors.error, '$inactive', 'Inactive')),
          SizedBox(width: 10.w),
          Expanded(child: _scStatChip('people', AppColors.primary, '$students', 'Students')),
        ]),
        SizedBox(height: 16.h),
        Text('Top Institutions by Collection', style: AppUI.label),
        SizedBox(height: 8.h),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
          decoration: AppUI.tableHeadBar.copyWith(borderRadius: BorderRadius.circular(8)),
          child: Row(children: [h('INSTITUTION', flex: 4), h('COLLECTION', flex: 2, a: TextAlign.right), h('PENDING', flex: 2, a: TextAlign.right), h('STATUS', flex: 2, a: TextAlign.right)]),
        ),
        for (final s in topN)
          Container(
            padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
            child: Row(children: [
              Expanded(flex: 4, child: Text(s.insName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
              Expanded(flex: 2, child: Text(_formatAmount(s.totalCollected), textAlign: TextAlign.right, style: AppUI.money.copyWith(color: AppColors.success))),
              Expanded(flex: 2, child: Text(_formatAmount(s.totalPending), textAlign: TextAlign.right, style: AppUI.money)),
              Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: _scStatusPill(s.activeStatus))),
            ]),
          ),
      ]),
    );
  }

  Widget _scDonutWithLegend() {
    final entries = _superByMethod.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) {
      return SizedBox(height: 120.h, child: Center(child: Text('No reconciled collection yet', textAlign: TextAlign.center, style: AppUI.muted)));
    }
    final total = entries.fold<double>(0, (s, e) => s + e.value);
    final slices = [for (final e in entries) _ScSlice(e.key, e.value, _methodColor(e.key))];
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(
        width: 128.w, height: 128.w,
        child: Stack(alignment: Alignment.center, children: [
          CustomPaint(size: Size(128.w, 128.w), painter: _ScDonut(slices, total)),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text('TOTAL', style: AppUI.caps),
            FittedBox(fit: BoxFit.scaleDown, child: Text(_formatAmount(total), style: TextStyle(fontSize: 14.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary))),
          ]),
        ]),
      ),
      SizedBox(width: 16.w),
      Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final s in slices)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 4.h),
            child: Row(children: [
              Container(width: 11.w, height: 11.w, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(3.r))),
              SizedBox(width: 8.w),
              Expanded(child: Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.body)),
              Text('${(total <= 0 ? 0 : s.value / total * 100).toStringAsFixed(0)}%', textAlign: TextAlign.right, style: AppUI.label.copyWith(color: AppColors.textSecondary)),
            ]),
          ),
      ])),
    ]);
  }

  Widget _scMonthlyBars() {
    const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final now = DateTime.now();
    final values = <double>[];
    final labels = <String>[];
    for (var i = 11; i >= 0; i--) {
      final d = DateTime(now.year, now.month - i, 1);
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      values.add(_superByMonth[key] ?? 0);
      labels.add(monthNames[d.month - 1]);
    }
    final maxV = values.fold<double>(0, (m, v) => math.max(m, v));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Monthly Collection Trend', style: AppUI.label),
      SizedBox(height: 10.h),
      maxV <= 0
          ? SizedBox(height: 100.h, child: Center(child: Text('No monthly collection yet', textAlign: TextAlign.center, style: AppUI.muted)))
          : SizedBox(height: 150.h, child: LayoutBuilder(builder: (context, c) => CustomPaint(size: Size(c.maxWidth, 150.h), painter: _ScBars(values, labels, maxV)))),
    ]);
  }

  Widget _scCollectionOverview() => _scPanel(
        icon: 'chart-1', title: 'Collection Overview', subtitle: 'This year, reconciled payments',
        child: Column(children: [_scDonutWithLegend(), SizedBox(height: 16.h), _scMonthlyBars()]),
      );

  Widget _scCollectionByMode() {
    final total = _superByMethod.values.fold<double>(0, (s, v) => s + v);
    final online = _superByMethod['Online'] ?? 0;
    final onlinePct = total <= 0 ? 0 : (online / total * 100);
    return _scPanel(
      icon: 'grid-1', title: 'Collection by Mode', subtitle: 'This year, reconciled payments',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _scDonutWithLegend(),
        if (total > 0) ...[
          SizedBox(height: 14.h),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
            decoration: BoxDecoration(color: AppColors.successBg, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.success.withValues(alpha: 0.18))),
            child: Row(children: [
              AppUI.iconTile('chart-1', color: AppColors.success, size: 16),
              SizedBox(width: 10.w),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Online collections are ${onlinePct.toStringAsFixed(0)}% of total', style: AppUI.label),
                Text(onlinePct >= 40 ? 'Great digital adoption — keep it up.' : 'Keep promoting digital payments.', style: AppUI.muted),
              ])),
            ]),
          ),
        ],
      ]),
    );
  }

  /// Opens the full detailed institution list on its own page (from the
  /// Institution Overview "View all").
  void _openAllInstitutions() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.border)),
        title: Row(children: [
          AppUI.iconTile('buildings-2', size: 18),
          SizedBox(width: 12.w),
          Text('All Institutions', style: AppUI.cardTitle),
        ]),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16.w),
        child: _scAllInstitutions(context),
      ),
    )));
  }

  Widget _scQuickActions() {
    final actions = <(String, String, int)>[
      ('user-add', 'Register Institution', 1),
      ('buildings-2', 'Manage Institutions', 2),
      ('setting-2', 'Settings', 3),
    ];
    return _scPanel(
      icon: 'grid-1', title: 'Quick Actions',
      child: LayoutBuilder(builder: (context, c) {
        final perRow = c.maxWidth > 800 ? 3 : 1;
        const gap = 12.0;
        final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final a in actions)
            SizedBox(
              width: w,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => setState(() => _selectedNavIndex = a.$3),
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  child: Container(
                    padding: EdgeInsets.symmetric(vertical: 14.h, horizontal: 14.w),
                    decoration: BoxDecoration(color: AppColors.primaryLight.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.cardBorder)),
                    child: Row(children: [
                      AppUI.iconTile(a.$1, size: 18),
                      SizedBox(width: 12.w),
                      Expanded(child: Text(a.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label)),
                    ]),
                  ),
                ),
              ),
            ),
        ]);
      }),
    );
  }

  Widget _scAllInstitutions(BuildContext context) => _scPanel(
        icon: 'buildings-2', title: 'All Institutions', subtitle: 'Detailed finance',
        trailing: Text('${_institutionSummaries.length} institutions', style: AppUI.muted),
        child: ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: _institutionSummaries.length,
          separatorBuilder: (_, __) => SizedBox(height: 12.h),
          itemBuilder: (context, i) => _buildInstitutionCard(context, _institutionSummaries[i]),
        ),
      );

  Widget _buildMobileDashboardHome(BuildContext context) {
    if (_loadingFinanceData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_institutionSummaries.isEmpty) {
      return AppUI.empty(
        icon: 'buildings-2',
        title: 'No institutions found',
        why: 'No institution has been registered yet. Use Register Institution to add one.',
      );
    }

    final activeCount = _institutionSummaries.where((s) => s.activeStatus).length;
    final totalDemand = _institutionSummaries.fold<double>(0, (sum, s) => sum + s.totalDemand);
    final totalCollection = _institutionSummaries.fold<double>(0, (sum, s) => sum + s.totalCollected);
    final totalTodayCollection = _institutionSummaries.fold<double>(0, (sum, s) => sum + s.todayCollected + s.todayMisc);
    final totalPending = _institutionSummaries.fold<double>(0, (sum, s) => sum + s.totalPending);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Page name (shown in body since header has profile + hamburger)
        Row(
          children: [
            Text(_navItems[_selectedNavIndex].label,
                style: AppUI.pageTitle.copyWith(fontSize: 22)),
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
                      style: TextStyle(fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text("Here's a snapshot of all institutions", style: AppUI.muted),
        const SizedBox(height: 24),

        // Hero balance card — Total Demand
        Center(
          child: Column(
            children: [
              Text('TOTAL DEMAND', style: AppUI.caps),
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
              child: ElevatedButton.icon(
                onPressed: () => setState(() => _selectedNavIndex = 1),
                icon: AppIcon('add', size: 16, color: Colors.white),
                label: const Text('Register'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _selectedNavIndex = 2),
                icon: AppIcon('buildings-2', size: 16, color: AppColors.primary),
                label: const Text('Manage'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),

        // Quick Stats — horizontal scroll cards
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Quick Stats', style: AppUI.cardTitle),
            Text('$activeCount active', style: AppUI.muted),
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
                _miniStatCard('calendar', "Today's Collection", _formatAmount(totalTodayCollection), AppColors.success,
                    onTap: () => _showAggregateDrilldown(context, 'today_collection')),
                const SizedBox(width: 12),
                _miniStatCard('timer', 'Total Pending', _formatAmount(totalPending), AppColors.error,
                    onTap: () => _showAggregateDrilldown(context, 'pending')),
                const SizedBox(width: 12),
                _miniStatCard('buildings-2', 'Institutions', '$activeCount of ${_institutionSummaries.length}', AppColors.accent,
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
            Text('Institutions', style: AppUI.cardTitle),
            InkWell(
              onTap: () => setState(() => _selectedNavIndex = 2),
              child: Text('View all', style: AppUI.label.copyWith(color: AppColors.primary)),
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
      borderRadius: BorderRadius.circular(AppUI.cardRadius),
      child: Container(
        width: 160,
        padding: const EdgeInsets.all(14),
        decoration: AppUI.card(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppUI.iconTile(icon, color: color, size: 14),
                const Spacer(),
                if (onTap != null)
                  AppIcon.linear('Chevron Right', size: 16, color: AppColors.textSecondary),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.caps),
                const SizedBox(height: 2),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
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
      decoration: AppUI.card(),
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
                            style: AppUI.label.copyWith(fontSize: 14)),
                        const SizedBox(height: 2),
                        Text('Code: ${s.insCode}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppUI.muted),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_formatAmount(s.totalCollected), textAlign: TextAlign.right, style: AppUI.money),
                      const SizedBox(height: 4),
                      AppUI.chip(s.activeStatus ? 'Active' : 'Inactive',
                          s.activeStatus ? AppStatus.success : AppStatus.neutral),
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
                        Container(height: 1, color: AppColors.divider),
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
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                // Light tinted cell, matching the trust-level summary cards.
                color: color.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(AppUI.controlRadius),
                border: Border.all(color: color.withValues(alpha: 0.22)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      // Solid white chip so the icon separates from the tint.
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: color.withValues(alpha: 0.22)),
                    ),
                    child: AppIcon(icon, color: color, size: 14),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppUI.caps.copyWith(fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
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
          // Four distinct hues, matching the app-wide language:
          // violet = demand, green = collected, teal = today, amber = pending.
          cell(
            icon: 'wallet-1',
            color: AppColors.demand,
            value: _formatAmount(s.totalDemand),
            label: 'Total Demand',
            onTap: () => _showCourseWiseDemand(context, s),
          ),
          cell(
            icon: 'tick-circle',
            color: AppColors.success,
            value: _formatAmount(s.totalCollected),
            label: 'Total Collection',
            onTap: () => _showCourseWiseCollection(context, s),
          ),
          cell(
            icon: 'calendar',
            color: AppColors.today,
            value: _formatAmount(s.todayCollected),
            label: "Today's Collection",
            onTap: () => _showCourseWiseTodayCollection(context, s),
          ),
          cell(
            icon: 'timer',
            color: AppColors.warning,
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
        0, (sum, s) => sum + s.todayCollected + s.todayMisc);
    final totalPending = _institutionSummaries.fold<double>(
        0, (sum, s) => sum + s.totalPending);
    final totalMisc = _institutionSummaries.fold<double>(0, (sum, s) => sum + s.totalMisc);
    final totalStudents = _institutionSummaries.fold<int>(0, (sum, s) => sum + s.studentCount);
    final activeCount = _institutionSummaries.where((s) => s.activeStatus).length;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      const gap = 12.0;
      // 7 KPI cards across on wide screens (matches the reference), stepping
      // down to 4 then 2 as width shrinks.
      final cols = w < 600 ? 2 : (w < 1150 ? 4 : 7);
      final cardWidth = (w - gap * (cols - 1)) / cols;
      final collectedPct = totalDemand <= 0 ? 0.0 : (totalCollection / totalDemand * 100).clamp(0, 100);
      final pendingPct = totalDemand <= 0 ? 0.0 : (totalPending / totalDemand * 100).clamp(0, 100);
      final cards = <Widget>[
        // Non-interactive KPI cards (no drill-down), with real subtitles.
        SizedBox(width: cardWidth, child: _buildSummaryCard('wallet-1', AppColors.demand, _formatAmount(totalDemand), 'Total Demand', subtitle: 'For the trust')),
        SizedBox(width: cardWidth, child: _buildSummaryCard('tick-circle', AppColors.success, _formatAmount(totalCollection), 'Total Collection', subtitle: '${collectedPct.toStringAsFixed(1)}% collected', subtitleColor: AppColors.success)),
        SizedBox(width: cardWidth, child: _buildSummaryCard('receipt-2', AppColors.accent, _formatAmount(totalMisc), 'Miscellaneous Collection', subtitle: 'Miscellaneous fees')),
        SizedBox(width: cardWidth, child: _buildSummaryCard('calendar', AppColors.today, _formatAmount(totalTodayCollection), "Today's Collection", subtitle: 'Reconciled today')),
        SizedBox(width: cardWidth, child: _buildSummaryCard('timer', AppColors.warning, _formatAmount(totalPending), 'Total Pending', subtitle: '${pendingPct.toStringAsFixed(1)}% pending', subtitleColor: AppColors.error)),
        SizedBox(width: cardWidth, child: _buildSummaryCard('buildings-2', AppColors.primary, '$activeCount of ${_institutionSummaries.length}', 'Institutions', subtitle: 'Active Institutions')),
        SizedBox(width: cardWidth, child: _buildSummaryCard('people', AppColors.today, '$totalStudents', 'Total Students', subtitle: 'Across institutions')),
      ];
      return Wrap(spacing: gap, runSpacing: gap, children: cards);
    });
  }

  Widget _buildSummaryCard(String icon, Color iconColor, String value, String label, {String? subtitle, Color? subtitleColor}) {
    // AppUI.kpi layout (icon tile, CAPS label, 20/800 value, muted sub),
    // composed locally so long amounts scale down instead of ellipsizing.
    return Container(
      padding: EdgeInsets.all(16.w),
      decoration: AppUI.card(),
      child: Row(children: [
        AppUI.iconTile(icon, color: iconColor),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.caps),
            SizedBox(height: 4.h),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, maxLines: 1, style: TextStyle(fontSize: 20.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            ),
            if (subtitle != null) ...[
              SizedBox(height: 2.h),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: subtitleColor == null ? AppUI.muted : AppUI.muted.copyWith(color: subtitleColor, fontWeight: FontWeight.w700)),
            ],
          ]),
        ),
      ]),
    );
  }

  void _showAggregateDrilldown(BuildContext context, String mode) {
    setState(() => _aggregateDrilldownMode = mode);
  }

  String _formatAmount(double amount) {
    return formatIndianNumber(amount);
  }

  Widget _buildInstitutionCard(
      BuildContext context, _InstitutionFinanceSummary s) {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
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
                        style: AppUI.cardTitle),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AppUI.chip(s.activeStatus ? 'Active' : 'Inactive',
                  s.activeStatus ? AppStatus.success : AppStatus.neutral),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            // Adaptive layout: stack vertically on mobile, 2-col on tablet,
            // single row on desktop.
            const gap = 12.0;
            // The same 8 finance figures the institution admin sees on its own
            // dashboard, in the same order, so the breakdown matches exactly.
            final feesDue = _buildFinanceTile('Total Fees Due', s.totalDemand, AppColors.demand,
                icon: 'receipt-2', onTap: () => _showRegArrDialog(context, s.insId, 'demand', 'Total Fees Due', AppColors.demand, 'receipt-2', s.totalDemand));
            final collected = _buildFinanceTile('Total Collected', s.totalCollected, AppColors.success,
                icon: 'tick-circle', onTap: () => _showRegArrDialog(context, s.insId, 'paid', 'Total Collected', AppColors.success, 'money-recive', s.totalCollected));
            final misc = _buildFinanceTile('Miscellaneous Collection', s.totalMisc, AppColors.accent, icon: 'receipt-2');
            final fine = _buildFinanceTile('Fine Collected', s.totalFine, AppColors.error, icon: 'receipt-edit');
            final concession = _buildFinanceTile('Concession', s.totalConcession, AppColors.info, icon: 'discount-shape');
            final today = _buildFinanceTile("Today's Collection", s.todayCollected + s.todayMisc, AppColors.today,
                icon: 'calendar', onTap: () => _showTodayBreakdown(context, s));
            final pendingApproval = _buildFinanceTile('Pending Approval', s.pendingApproval, AppColors.warning,
                icon: 'money-remove', onTap: () => _showPendingApprovalDialog(context, s));
            final outstanding = _buildFinanceTile('Outstanding', s.totalPending, AppColors.today,
                icon: 'wallet-money', onTap: () => _showRegArrDialog(context, s.insId, 'pending', 'Outstanding', AppColors.today, 'wallet-money', s.totalPending));
            final tiles = [feesDue, collected, misc, fine, concession, today, pendingApproval, outstanding];

            if (w < 600) {
              // Mobile: stack vertically.
              return Column(children: [
                for (var i = 0; i < tiles.length; i++) ...[if (i > 0) SizedBox(height: gap), tiles[i]],
              ]);
            }
            // Rows of N Expanded tiles.
            Widget rowOf(List<Widget> row) => IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (var i = 0; i < row.length; i++) ...[if (i > 0) SizedBox(width: gap), Expanded(child: row[i])],
                  ]),
                );
            if (w < 1000) {
              // Tablet: 2 per row → 4 rows.
              return Column(children: [
                rowOf([feesDue, collected]), SizedBox(height: gap),
                rowOf([misc, fine]), SizedBox(height: gap),
                rowOf([concession, today]), SizedBox(height: gap),
                rowOf([pendingApproval, outstanding]),
              ]);
            }
            // Desktop: 4 per row → 2 rows (matches the admin KPI grid).
            return Column(children: [
              rowOf([feesDue, collected, misc, fine]),
              SizedBox(height: gap),
              rowOf([concession, today, pendingApproval, outstanding]),
            ]);
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
                Text(label, style: AppUI.body),
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
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: collectionColor.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            half('Total Collection', _formatAmount(s.totalCollected), collectionColor, () => _showCourseWiseCollection(context, s)),
            Container(width: 1, height: 38.h, color: AppColors.divider),
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
        // Light tinted tile in the metric's own colour, matching the trust-level
        // summary cards above. (This previously hardcoded AppColors.accent for
        // the icon and ignored `color`, so every tile rendered the same blue.)
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          AppUI.iconTile(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppUI.caps),
                const SizedBox(height: 4),
                Text(_formatAmount(amount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 20.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
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
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
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

  Widget _saBreakdownRow(String icon, Color color, String label, double amount, {bool bold = false}) {
    return Row(children: [
      AppUI.iconTile(icon, color: color, size: 16),
      SizedBox(width: 12.w),
      Expanded(child: Text(label, style: bold ? AppUI.label.copyWith(fontSize: 14.sp, fontWeight: FontWeight.w800) : AppUI.body)),
      Text(_formatAmount(amount), textAlign: TextAlign.right, style: bold ? AppUI.money.copyWith(fontSize: 15.sp, fontWeight: FontWeight.w800, color: color) : AppUI.money),
    ]);
  }

  /// Regular vs Arrear split for one institution — same dialog the institution
  /// admin sees (via get_fee_totals_by_seqtype). [metric] = demand|paid|pending.
  /// [cardTotal] is the authoritative figure shown on the card (from
  /// get_super_admin_dashboard, which matches the admin) — used for the Total
  /// row so it always agrees with the card even if the split RPC drifts.
  void _showRegArrDialog(BuildContext context, int insId, String metric, String title, Color color, String icon, double cardTotal) {
    // Create the RPC future ONCE here — not inside the FutureBuilder — so a
    // dialog rebuild never re-fires the query.
    final splitFuture = SupabaseService.client.rpc('get_fee_totals_by_seqtype', params: {'p_ins_id': insId});
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
        insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 420.w),
          child: Padding(
            padding: EdgeInsets.all(22.w),
            child: FutureBuilder<dynamic>(
              future: splitFuture,
              builder: (c, snap) {
                final head = Row(children: [
                  AppUI.iconTile(icon, color: color),
                  SizedBox(width: 12.w),
                  Expanded(child: Text(title, style: AppUI.cardTitle)),
                ]);
                if (snap.connectionState != ConnectionState.done) {
                  return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [head, SizedBox(height: 20.h), SizedBox(height: 100.h, child: const Center(child: CircularProgressIndicator()))]);
                }
                final raw = snap.data;
                final m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
                double val(String type) => ((m[type] as Map?)?[metric] as num?)?.toDouble() ?? 0;
                final reg = val('regular'), arr = val('arrear');
                // Total row uses the authoritative card figure (matches admin).
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  head,
                  SizedBox(height: 18.h),
                  _saBreakdownRow('receipt-2', color, 'Regular', reg),
                  Divider(height: 20.h, color: AppColors.divider),
                  _saBreakdownRow('receipt-edit', color, 'Arrear', arr),
                  Divider(height: 20.h, color: AppColors.divider),
                  _saBreakdownRow(icon, color, 'Total', cardTotal, bold: true),
                  SizedBox(height: 18.h),
                  Align(alignment: Alignment.centerRight, child: OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _fetchInstitutionPending(int insId) async {
    try {
      final all = await SupabaseService.getPaymentsByDateRange(insId, fromDate: DateTime(2015, 1, 1), toDate: DateTime.now());
      return List<Map<String, dynamic>>.from(all)
          .where((p) => (p['recon_status']?.toString() ?? '') == 'P')
          .toList()
        ..sort((a, b) => (b['paydate']?.toString() ?? '').compareTo(a['paydate']?.toString() ?? ''));
    } catch (_) {
      return [];
    }
  }

  /// Today Collection split into Fee Collection + Misc — same as the admin's.
  void _showTodayBreakdown(BuildContext context, _InstitutionFinanceSummary s) {
    final fee = s.todayCollected;
    final misc = s.todayMisc;
    final total = fee + misc;
    Widget line(String icon, String label, double v, Color color) => Padding(
          padding: EdgeInsets.symmetric(vertical: 8.h),
          child: Row(children: [
            AppUI.iconTile(icon, color: color, size: 16),
            SizedBox(width: 12.w),
            Expanded(child: Text(label, style: AppUI.body)),
            Text(_formatAmount(v), textAlign: TextAlign.right, style: AppUI.money.copyWith(color: color)),
          ]),
        );
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
        insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 440.w),
          child: Padding(
            padding: EdgeInsets.all(20.w),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                AppUI.iconTile('calendar', color: AppColors.today),
                SizedBox(width: 12.w),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text("Today's Collection", maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cardTitle),
                  Text(s.insName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
                ])),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close, size: 18), color: AppColors.textSecondary),
              ]),
              SizedBox(height: 12.h),
              line('tick-circle', 'Fee Collection', fee, AppColors.success),
              Divider(height: 1, color: AppColors.divider),
              line('receipt-2', 'Miscellaneous Collection', misc, AppColors.accent),
              SizedBox(height: 12.h),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 12.h),
                decoration: BoxDecoration(color: AppColors.today.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: AppColors.today.withValues(alpha: 0.22))),
                child: Row(children: [
                  Expanded(child: Text('Total Today', style: AppUI.label)),
                  Text(_formatAmount(total), textAlign: TextAlign.right, style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w800, color: AppColors.today)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Pending-approval student list for one institution — same as the admin's.
  void _showPendingApprovalDialog(BuildContext context, _InstitutionFinanceSummary s) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
        insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560.w, maxHeight: 560.h),
          child: Padding(
            padding: EdgeInsets.all(20.w),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _fetchInstitutionPending(s.insId),
              builder: (c, snap) {
                final head = Row(children: [
                  AppUI.iconTile('money-remove', color: AppColors.warning),
                  SizedBox(width: 12.w),
                  Expanded(child: Text('Pending Approval', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cardTitle)),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close, size: 18), color: AppColors.textSecondary),
                ]);
                if (!snap.hasData) {
                  return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [head, SizedBox(height: 20.h), SizedBox(height: 140.h, child: const Center(child: CircularProgressIndicator()))]);
                }
                final list = snap.data!;
                final total = list.fold<double>(0, (a, p) => a + ((p['transtotalamount'] as num?)?.toDouble() ?? 0));
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  head,
                  SizedBox(height: 4.h),
                  Text('${list.length} payment${list.length == 1 ? '' : 's'} • ${_formatAmount(total)} awaiting reconciliation', style: AppUI.muted),
                  SizedBox(height: 14.h),
                  if (list.isEmpty)
                    SizedBox(height: 160.h, child: AppUI.empty(icon: 'tick-circle', title: 'Nothing pending', why: 'Every payment for this institution has been reconciled.'))
                  else
                    Flexible(child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: list.length,
                      separatorBuilder: (_, __) => Divider(height: 14.h, color: AppColors.divider),
                      itemBuilder: (_, i) {
                        final p = list[i];
                        final name = (p['stuname']?.toString() ?? '').trim();
                        final admno = p['stuadmno']?.toString() ?? '';
                        final cls = p['stuclass']?.toString() ?? '';
                        final receipt = p['paynumber']?.toString() ?? '';
                        final amount = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
                        final rawDate = p['paydate']?.toString() ?? '';
                        final date = rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;
                        return Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(name.isEmpty ? '—' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.label),
                            SizedBox(height: 2.h),
                            Text([if (admno.isNotEmpty) admno, if (cls.isNotEmpty) cls, if (receipt.isNotEmpty) receipt].join(' • '), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
                          ])),
                          SizedBox(width: 10.w),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(_formatAmount(amount), textAlign: TextAlign.right, style: AppUI.money.copyWith(color: AppColors.warning)),
                            SizedBox(height: 2.h),
                            Text(date, style: AppUI.muted.copyWith(fontSize: 12.sp)),
                          ]),
                        ]);
                      },
                    )),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(BuildContext context, String title, String value,
      String icon, Color color) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.all(16.w),
        decoration: AppUI.card(),
        child: Row(
          children: [
            AppUI.iconTile(icon, color: color),
            SizedBox(width: 12.w),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title.toUpperCase(), style: AppUI.caps),
                SizedBox(height: 4.h),
                Text(value,
                    style: TextStyle(fontSize: 20.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
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
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'All Institutions Fee Overview',
                style: AppUI.cardTitle,
              ),
              const Spacer(),
              AppUI.chip('View Only', AppStatus.neutral),
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
            AppUI.empty(
              icon: 'chart-1',
              title: 'No fee collection data available yet.',
              why: 'No institution has recorded a fee collection yet.',
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
                    AppColors.tableHeadBg),
                columns: const [
                  DataColumn(label: Text('INSTITUTION')),
                  DataColumn(label: Text('CODE')),
                  DataColumn(label: Text('FEE COLLECTION'), numeric: true),
                  DataColumn(label: Text('PENDING FEES'), numeric: true),
                  DataColumn(label: Text('TRANSACTIONS'), numeric: true),
                  DataColumn(label: Text('STATUS')),
                ],
                rows: _institutionSummaries.map((item) {
                  return DataRow(
                    cells: [
                      DataCell(Text(item.insName)),
                      DataCell(Text(item.insCode)),
                      DataCell(Text(_formatCurrency(item.totalCollected), style: AppUI.money)),
                      DataCell(Text(_formatCurrency(item.totalPending), style: AppUI.money)),
                      DataCell(Text('${item.transactionCount}')),
                      DataCell(
                        AppUI.chip(item.activeStatus ? 'Active' : 'Inactive',
                            item.activeStatus ? AppStatus.success : AppStatus.danger),
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
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent Transactions Across Institutions',
            style: AppUI.cardTitle,
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
            AppUI.empty(
              icon: 'receipt-2',
              title: 'No transactions found.',
              why: 'No payment has been recorded across the institutions yet.',
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
                    AppColors.tableHeadBg),
                columns: const [
                  DataColumn(label: Text('INSTITUTION')),
                  DataColumn(label: Text('RECEIPT NO.')),
                  DataColumn(label: Text('AMOUNT'), numeric: true),
                  DataColumn(label: Text('MODE')),
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
                      DataCell(Text(_formatCurrency(payment.transtotalamount), style: AppUI.money)),
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
                        AppUI.chip(statusText,
                            statusColor == AppColors.success ? AppStatus.success : AppStatus.danger),
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
    return formatIndianNumber(value);
  }

  String _formatDate(DateTime date) => formatDmy(date);

  Future<void> _loadManageList() async {
    if (_manageLoading) return;
    setState(() => _manageLoading = true);
    try {
      final res = await SupabaseService.client
          .from('institution')
          .select('ins_id, insname, inscode, inslogo, inscity, insstate, insstadate, activestatus')
          .order('ins_id');
      if (mounted) setState(() { _manageList = List<Map<String, dynamic>>.from(res); _manageLoaded = true; _manageLoading = false; });
    } catch (e) {
      debugPrint('manage institutions load error: $e');
      if (mounted) setState(() { _manageLoaded = true; _manageLoading = false; });
    }
  }

  /// public.institution allows activestatus 1, 2 or 9 — NOT 0, unlike most
  /// tables in the schema. 0 is what this toggle used to send, so switching an
  /// institution off failed on institution_activestatus_check and the row
  /// silently rolled back to Active.
  ///
  /// 2 is the inactive/suspended value here; 9 means deleted elsewhere in the
  /// system and would be wrong for a reversible switch. Everything that reads
  /// this column tests `== 1`, so any non-1 value reads as inactive.
  static const int _insActive = 1;
  static const int _insInactive = 2;

  Future<void> _setInstitutionActive(int insId, bool active) async {
    final idx = _manageList.indexWhere((i) => i['ins_id'] == insId);
    final prev = idx >= 0 ? _manageList[idx]['activestatus'] : null;
    final next = active ? _insActive : _insInactive;
    if (idx >= 0) setState(() => _manageList[idx]['activestatus'] = next);
    try {
      // institution has RLS (SELECT-only for anon) → write via SECURITY DEFINER RPC.
      await SupabaseService.client.rpc('admin_update_institution', params: {
        'p_ins_id': insId,
        'p_patch': {'activestatus': next, 'updatedby': 'SUPERADMIN'},
      });
    } catch (e) {
      if (idx >= 0 && mounted) setState(() => _manageList[idx]['activestatus'] = prev);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update the status. ${friendlyError(e)}'), backgroundColor: AppColors.error));
    }
  }

  String _fmtInsDate(dynamic v) {
    final s = v?.toString() ?? '';
    if (s.length < 10) return s;
    try {
      final d = DateTime.parse(s.substring(0, 10));
      return formatDmy(d);
    } catch (_) {
      return s;
    }
  }

  Widget _buildManageInstitutions(BuildContext context) {
    if (!_manageLoaded && !_manageLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadManageList());
    }
    final all = _manageList;
    final activeCount = all.where((i) => i['activestatus'] == 1).length;
    final inactiveCount = all.length - activeCount;
    final q = _manageSearch.trim().toLowerCase();
    final filtered = all.where((i) {
      if (_manageFilter == 'active' && i['activestatus'] != 1) return false;
      if (_manageFilter == 'inactive' && i['activestatus'] == 1) return false;
      if (q.isNotEmpty) {
        final hay = '${i['insname'] ?? ''} ${i['inscode'] ?? ''}'.toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
    final total = filtered.length;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: AppUI.card(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _manageHeader(all.length),
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), child: _manageTabsAndSearch(all.length, activeCount, inactiveCount)),
          Expanded(child: _loadingInstitutions || _manageLoading
              ? const Center(child: CircularProgressIndicator())
              : total == 0
                  ? AppUI.empty(
                      icon: 'buildings-2',
                      title: 'No institutions found',
                      why: all.isEmpty
                          ? 'No institution has been registered yet. Use Register Institution to add one.'
                          : 'No institution matches this filter or search. Clear the search or pick All.')
                  : _manageTable(filtered)),
        ]),
      ),
    );
  }

  Widget _manageHeader(int count) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.spaceBetween, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            AppUI.iconTile('buildings-2'),
            const SizedBox(width: 12),
            Text('Institutions', style: AppUI.cardTitle),
            const SizedBox(width: 10),
            AppUI.chip('$count Total', AppStatus.info),
          ]),
          Wrap(spacing: 10, runSpacing: 8, children: [
            OutlinedButton(
              onPressed: _manageLoading ? null : () { setState(() => _manageLoaded = false); _loadManageList(); },
              // Icon-only: square at the theme control height.
              style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size(AppUI.controlHeight(context), AppUI.controlHeight(context))),
              child: const AppIcon('refresh', size: 17, color: AppColors.primary),
            ),
            ElevatedButton.icon(
              onPressed: () => setState(() { _editInstitution = null; _selectedNavIndex = 1; }),
              icon: const AppIcon('add', size: 16, color: Colors.white),
              label: const Text('Register Institution'),
            ),
          ]),
        ]),
      );

  Widget _manageTabsAndSearch(int allCount, int activeCount, int inactiveCount) {
    Widget tab(String label, int cnt, String value, Color cntColor) {
      final sel = _manageFilter == value;
      return Padding(padding: const EdgeInsets.only(right: 8), child: InkWell(
        onTap: () => setState(() { _manageFilter = value; _managePage = 0; }),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(color: sel ? AppColors.primary : Colors.white, borderRadius: BorderRadius.circular(AppUI.controlRadius), border: Border.all(color: sel ? AppColors.primary : AppColors.border)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: sel ? Colors.white : AppColors.textPrimary)),
            const SizedBox(width: 8),
            Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1), decoration: BoxDecoration(color: sel ? Colors.white.withValues(alpha: 0.25) : cntColor.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)), child: Text('$cnt', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: sel ? Colors.white : cntColor))),
          ]),
        ),
      ));
    }
    return Row(children: [
      tab('All', allCount, 'all', AppColors.primary),
      tab('Active', activeCount, 'active', AppColors.success),
      tab('Inactive', inactiveCount, 'inactive', AppColors.error),
      const Spacer(),
      SizedBox(width: 320, child: TextField(
        onChanged: (v) => setState(() { _manageSearch = v; _managePage = 0; }),
        style: AppUI.fieldText(context),
        decoration: AppUI.field(context, 'Search by institution name or code').copyWith(
          prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.textLight),
        ),
      )),
    ]);
  }

  Widget _manageTable(List<Map<String, dynamic>> rows) {
    TextStyle h() => AppUI.tableHead;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(color: AppColors.tableHeadBg, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(children: [
        Expanded(flex: 4, child: Text('INSTITUTION', style: h())),
        Expanded(flex: 2, child: Text('CODE', style: h())),
        SizedBox(width: 110, child: Text('STATUS', style: h())),
        Expanded(flex: 2, child: Text('REGISTERED ON', style: h())),
        SizedBox(width: 200, child: Text('ACTION', textAlign: TextAlign.center, style: h())),
      ])),
      Expanded(child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.divider),
        itemBuilder: (context, i) => _manageRow(rows[i]),
      )),
    ]);
  }

  /// ins_id currently uploading a logo, so only that row shows a spinner.
  int? _logoUploadingIns;

  /// Replace an institution's logo. Registration is the only other place a
  /// logo can be set, and backfillInstitutionLogos deliberately skips rows that
  /// already have one — so without this a logo could be set once and never
  /// changed.
  Future<void> _changeInstitutionLogo(Map<String, dynamic> ins) async {
    final insId = ins['ins_id'] as int?;
    final inscode = ins['inscode']?.toString().trim();
    if (insId == null || inscode == null || inscode.isEmpty) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg'],
    );
    if (result == null || result.files.single.path == null) return;
    final picked = result.files.single;
    final ext = picked.extension?.toLowerCase() ?? '';
    if (!['png', 'jpg', 'jpeg'].contains(ext)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Only PNG, JPG, JPEG formats are allowed'),
            backgroundColor: AppColors.error));
      }
      return;
    }

    setState(() => _logoUploadingIns = insId);
    try {
      // Same path shape registration uses, so the bucket keeps one file per
      // institution instead of accumulating a copy per upload.
      final path = 'logos/$inscode.$ext';
      await SupabaseService.client.storage.from('InstitutionLogos').upload(
            path,
            File(picked.path!),
            fileOptions: const FileOptions(upsert: true),
          );
      var url = SupabaseService.client.storage
          .from('InstitutionLogos')
          .getPublicUrl(path);
      // The path never changes, so without a cache-buster the CDN keeps
      // serving the previous image and the new logo appears not to save.
      url = '$url?v=${DateTime.now().millisecondsSinceEpoch}';
      await SupabaseService.client
          .from('institution')
          .update({'inslogo': url}).eq('ins_id', insId);
      if (!mounted) return;
      setState(() {
        final i = _manageList.indexWhere((e) => e['ins_id'] == insId);
        if (i >= 0) _manageList[i]['inslogo'] = url;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Logo updated'), backgroundColor: AppColors.success));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Logo upload failed. ${friendlyError(e)}'),
            backgroundColor: AppColors.error));
      }
    } finally {
      if (mounted) setState(() => _logoUploadingIns = null);
    }
  }

  Widget _manageRow(Map<String, dynamic> ins) {
    final active = ins['activestatus'] == 1;
    final insId = ins['ins_id'] as int? ?? 0;
    final loc = [ins['inscity'], ins['insstate']].where((e) => (e?.toString().trim().isNotEmpty ?? false)).join(', ');
    final logo = ins['inslogo']?.toString() ?? '';
    final fallback = Text((ins['insname'] as String? ?? 'I')[0].toUpperCase(), style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 18));
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(children: [
      // INSTITUTION
      Expanded(flex: 4, child: Row(children: [
        Container(width: 44, height: 44, clipBehavior: Clip.antiAlias, alignment: Alignment.center, decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)), child: logo.isEmpty ? fallback : Image.network(logo, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(ins['insname']?.toString() ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppUI.cell.copyWith(fontWeight: FontWeight.w700, height: 1.2)),
          if (loc.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(children: [const Icon(Icons.location_on_outlined, size: 13, color: AppColors.textLight), const SizedBox(width: 3), Flexible(child: Text(loc, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted.copyWith(fontSize: 12)))]),
          ],
        ])),
      ])),
      // CODE
      Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(ins['inscode']?.toString() ?? '', style: AppUI.cell.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text('Institution Code', style: AppUI.muted.copyWith(fontSize: 12)),
      ])),
      // STATUS
      SizedBox(width: 110, child: Align(alignment: Alignment.centerLeft, child: AppUI.chip(active ? 'Active' : 'Inactive', active ? AppStatus.success : AppStatus.danger))),
      // REGISTERED ON
      Expanded(flex: 2, child: Row(children: [const Icon(Icons.calendar_today_outlined, size: 14, color: AppColors.textLight), const SizedBox(width: 6), Flexible(child: Text(_fmtInsDate(ins['insstadate']), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell.copyWith(color: AppColors.textSecondary)))])),
      // ACTION
      SizedBox(width: 280, child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        OutlinedButton.icon(
          onPressed: _logoUploadingIns == insId ? null : () => _changeInstitutionLogo(ins),
          icon: _logoUploadingIns == insId
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.image_outlined, size: 15),
          label: const Text('Logo'),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: () => setState(() { _editInstitution = ins; _selectedNavIndex = 1; }),
          icon: const Icon(Icons.edit_outlined, size: 15),
          label: const Text('Edit'),
        ),
        const SizedBox(width: 10),
        Switch(value: active, activeThumbColor: Colors.white, activeTrackColor: AppColors.primary, onChanged: (v) => _setInstitutionActive(insId, v)),
      ])),
    ]));
  }

  Widget _managePagination(int total, int pageCount, int start) {
    final from = total == 0 ? 0 : start + 1;
    final to = (start + _managePerPage).clamp(0, total);
    Widget navBtn(IconData ic, VoidCallback? onTap) => InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8), child: Container(width: 32, height: 32, alignment: Alignment.center, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)), child: Icon(ic, size: 18, color: onTap == null ? AppColors.textLight : AppColors.textPrimary)));
    final startPage = (_managePage - 2).clamp(0, (pageCount - 5).clamp(0, pageCount)).toInt();
    final endPage = (startPage + 5).clamp(0, pageCount).toInt();
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: Row(children: [
      Text(AppUI.showing(from, to, total), style: AppUI.muted),
      const Spacer(),
      navBtn(Icons.chevron_left, _managePage > 0 ? () => setState(() => _managePage--) : null),
      const SizedBox(width: 6),
      for (int p = startPage; p < endPage; p++) ...[
        InkWell(onTap: () => setState(() => _managePage = p), borderRadius: BorderRadius.circular(8), child: Container(width: 32, height: 32, alignment: Alignment.center, decoration: BoxDecoration(color: p == _managePage ? AppColors.primary : Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: p == _managePage ? AppColors.primary : AppColors.border)), child: Text('${p + 1}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: p == _managePage ? Colors.white : AppColors.textPrimary)))),
        const SizedBox(width: 6),
      ],
      navBtn(Icons.chevron_right, _managePage < pageCount - 1 ? () => setState(() => _managePage++) : null),
      const SizedBox(width: 14),
      Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9), border: Border.all(color: AppColors.border)), child: Text('$_managePerPage per page', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary))),
    ]));
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
  final double totalConcession;
  final double totalMisc;
  final double totalFine;
  final int transactionCount;
  final int studentCount;
  final bool activeStatus;
  double todayCollected;
  double todayMisc; // today's miscellaneous collection (separate from fee)
  double pendingApproval;

  _InstitutionFinanceSummary({
    required this.insId,
    required this.insName,
    required this.insCode,
    this.insLogo,
    this.todayCollected = 0,
    this.todayMisc = 0,
    this.pendingApproval = 0,
    this.totalConcession = 0,
    this.totalMisc = 0,
    this.totalFine = 0,
    this.studentCount = 0,
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
    return formatIndianNumber(amount);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    const collectionColor = AppColors.success;
    const pendingColor = AppColors.error;

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: Text(s.insName, style: AppUI.cardTitle),
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
                            color: AppColors.successBg,
                            borderRadius: BorderRadius.circular(AppUI.cardRadius),
                            border: Border.all(
                                color: collectionColor.withValues(alpha: 0.2)),
                          ),
                          child: Column(
                            children: [
                              Text('TOTAL COLLECTION',
                                  style: AppUI.caps.copyWith(color: collectionColor)),
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
                            color: AppColors.errorBg,
                            borderRadius: BorderRadius.circular(AppUI.cardRadius),
                            border: Border.all(
                                color: pendingColor.withValues(alpha: 0.2)),
                          ),
                          child: Column(
                            children: [
                              Text('TOTAL PENDING',
                                  style: AppUI.caps.copyWith(color: pendingColor)),
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
                      color: AppColors.tableHeadBg,
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(AppUI.cardRadius)),
                      border: Border.all(color: AppColors.cardBorder),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                            flex: 3,
                            child: Padding(
                                padding: EdgeInsets.fromLTRB(16.w, 0, 24.w, 0),
                                child: Text(schoolTerm('Course - Class').toUpperCase(),
                                    style: AppUI.tableHead))),
                        AppUI.th('Students', align: TextAlign.right),
                        AppUI.th('Collection', align: TextAlign.right),
                        AppUI.th('Pending', align: TextAlign.right),
                      ],
                    ),
                  ),
                      builder: (context, controller) => Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(AppUI.cardRadius)),
                        border: const Border(
                          left: BorderSide(color: AppColors.cardBorder),
                          right: BorderSide(color: AppColors.cardBorder),
                          bottom: BorderSide(color: AppColors.cardBorder),
                        ),
                      ),
                      child: _classWiseData.isEmpty
                          ? AppUI.empty(
                              title: 'No data',
                              why: 'This institution has no fee demand or collection recorded yet.')
                          : ListView.separated(
                              controller: controller,
                              itemCount: _classWiseData.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, color: AppColors.divider),
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
                                              style: AppUI.cell)),
                                      Expanded(
                                          child: Text('${row['students'] ?? 0}',
                                              style: AppUI.cell,
                                              textAlign: TextAlign.right)),
                                      Expanded(
                                          child: Text(_fmt(collection),
                                              style: AppUI.money.copyWith(color: collectionColor),
                                              textAlign: TextAlign.right)),
                                      Expanded(
                                          child: Text(_fmt(pending),
                                              style: AppUI.money.copyWith(color: pendingColor),
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
    // Server-side grouping via SECURITY DEFINER RPC — the superadmin runs as
    // anon and CANNOT read the tenant payment/students tables directly (that's
    // why the direct-query version returned "No data").
    try {
      final rpc = await SupabaseService.client.rpc(
        'get_superadmin_collection_by_course',
        params: {
          'p_ins_id': widget.summary.insId,
          'p_from': _filterFrom != null ? _dateStr(_filterFrom!) : null,
          'p_to': _filterTo != null ? _dateStr(_filterTo!) : null,
        },
      );
      final rows = List<Map<String, dynamic>>.from((rpc as List?) ?? const []);
      _rows = rows
          .map((r) => {
                'course': (r['course'] ?? 'Other').toString(),
                'class': (r['stuclass'] ?? '').toString(),
                'paid_students': (r['paid_students'] as num?)?.toInt() ?? 0,
                'collection': (r['collection'] as num?)?.toDouble() ?? 0,
              })
          .where((r) => (r['collection'] as double) > 0)
          .toList();
    } catch (e) {
      debugPrint('collection-by-course RPC error: $e');
      _rows = [];
    }
  }

  Future<void> _loadApprovalFromPayments() async {
    // Server-side grouping via SECURITY DEFINER RPC — anon can't read the tenant
    // payment/paymentdetails/feedemand tables (this used to N+1 over them in Dart
    // and returned "No data" for the superadmin).
    try {
      final rpc = await SupabaseService.client.rpc(
        'get_superadmin_approval_by_course',
        params: {'p_ins_id': widget.summary.insId},
      );
      final rows = List<Map<String, dynamic>>.from((rpc as List?) ?? const []);
      _rows = rows
          .map((r) => {
                'course': (r['course'] ?? 'Other').toString(),
                'class': (r['stuclass'] ?? '').toString(),
                'approval_students': (r['approval_students'] as num?)?.toInt() ?? 0,
                'approval': (r['approval'] as num?)?.toDouble() ?? 0,
              })
          .where((r) => (r['approval'] as double) > 0)
          .toList();
    } catch (e) {
      debugPrint('approval-by-course RPC error: $e');
      _rows = [];
    }
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
            .select('stu_id, stuclass, courname')
            .inFilter('stu_id', chunk);
        for (final s in (students as List)) {
          final key = '${s['courname'] ?? 'Other'}|${s['stuclass'] ?? ''}';
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
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(label, style: AppUI.label),
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
              borderRadius: BorderRadius.circular(AppUI.controlRadius),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: value != null ? AppColors.primary.withValues(alpha: 0.55) : AppColors.border),
                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
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
                      style: value != null
                          ? AppUI.fieldText(ctx)
                          : AppUI.fieldText(ctx).copyWith(color: AppColors.textLight, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            );
          }

          Widget sectionLabel(String text) => AppUI.sectionLabel(text);

          return AlertDialog(
            backgroundColor: Colors.white,
            titlePadding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            title: Row(
              children: [
                Text('Filters', style: AppUI.cardTitle),
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
                    presetChip('Last 7 Days', () {
                      final now = DateTime.now();
                      setStateDialog(() {
                        from = now.subtract(const Duration(days: 7));
                        to = DateTime(now.year, now.month, now.day);
                      });
                    }),
                    presetChip('Last 30 Days', () {
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
                child: const Text('Clear'),
              ),
              ElevatedButton(
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
    return formatIndianNumber(amount);
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
              style: AppUI.cell.copyWith(
                  fontWeight: weight ?? FontWeight.w500,
                  color: color ?? AppColors.textPrimary)),
        );

    final rows = <Widget>[];
    grouped.forEach((course, classRows) {
      // Per-class rows. Course name shows in the COURSE column on the first
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
                  weight: FontWeight.w700, color: AppColors.primary),
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
            cell('Subtotal', 3,
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
            ? (widget.todayOnly ? "Today's Collection" : 'Filtered Collection')
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
                    ? 'PENDING'
                    : 'STUDENTS')
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
                    final backButton = ElevatedButton.icon(
                      onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
                      icon: AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
                      label: const Text('Back'),
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
                          Text('$totalLabel: ', style: AppUI.muted),
                          Text(_fmt(total),
                              style: AppUI.money.copyWith(color: AppColors.primary, fontWeight: FontWeight.w800)),
                        ],
                      ),
                    );
                    final dateBtn = OutlinedButton.icon(
                      onPressed: _openDateFilter,
                      icon: AppIcon('calendar-1', size: 16, color: AppColors.primary),
                      label: const Text('Date'),
                    );
                    final refreshBtn = ElevatedButton.icon(
                      onPressed: _load,
                      icon: AppIcon('refresh', size: 16, color: Colors.white),
                      label: const Text('Refresh'),
                    );
                    final breadcrumbText = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(widget.summary.insName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppUI.muted),
                        ),
                        const SizedBox(width: 6),
                        AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                        const SizedBox(width: 6),
                        Text(schoolTerm('Course-wise $valueLabel'),
                            style: AppUI.label),
                      ],
                    );

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: AppUI.card(),
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
                                          style: AppUI.muted),
                                    ),
                                    const SizedBox(width: 6),
                                    AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(schoolTerm('Course-wise $valueLabel'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppUI.label),
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
                                Container(width: 1, height: 18, color: AppColors.divider),
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
                  SizedBox(height: AppUI.gap),
                  Expanded(
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: AppUI.card(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            child: Row(
                              children: [
                                AppUI.iconTile(titleIcon, size: 18),
                                const SizedBox(width: 12),
                                Text(schoolTerm('Course-wise Breakdown'),
                                    style: AppUI.cardTitle),
                                const Spacer(),
                                Text(schoolTerm('${_rows.length} ${_rows.length == 1 ? "course" : "courses"}'),
                                    style: AppUI.muted),
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
                                  borderRadius: BorderRadius.circular(AppUI.controlRadius),
                                  border: Border.all(color: AppColors.cardBorder),
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
                                              child: Text(schoolTerm('COURSE'),
                                                  style: AppUI.tableHead)),
                                          Expanded(
                                              flex: 2,
                                              child: Text(schoolTerm('CLASS'),
                                                  style: AppUI.tableHead)),
                                          Expanded(
                                              flex: 2,
                                              child: Text(
                                                  studentsHeader,
                                                  textAlign: TextAlign.right,
                                                  style: AppUI.tableHead)),
                                          Expanded(
                                              flex: 4,
                                              child: Text(
                                                  valueLabel.toUpperCase(),
                                                  textAlign: TextAlign.right,
                                                  style: AppUI.tableHead)),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: _rows.isEmpty
                                          ? AppUI.empty(
                                              title: 'No data',
                                              why: 'Nothing recorded for this institution in the selected range.')
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
                                            border: Border(top: BorderSide(color: AppColors.divider)),
                                          ),
                                          padding: EdgeInsets.symmetric(horizontal: rowPadH, vertical: 14),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                  flex: 3,
                                                  child: Text('GRAND TOTAL',
                                                      style: AppUI.label.copyWith(
                                                          fontWeight: FontWeight.w800,
                                                          letterSpacing: 0.4))),
                                              const Expanded(flex: 2, child: SizedBox()),
                                              Expanded(
                                                  flex: 2,
                                                  child: Text('$totalStudents',
                                                      textAlign: TextAlign.right,
                                                      style: AppUI.money.copyWith(fontWeight: FontWeight.w800))),
                                              Expanded(
                                                  flex: 4,
                                                  child: Text(_fmt(totalAmount),
                                                      textAlign: TextAlign.right,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: AppUI.money.copyWith(fontWeight: FontWeight.w800))),
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
              backgroundColor: AppColors.error),
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
          const SnackBar(content: Text('Trust settings saved'), backgroundColor: AppColors.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the trust settings. ${friendlyError(e)}'), backgroundColor: AppColors.error),
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
      margin: EdgeInsets.only(bottom: AppUI.gap),
      clipBehavior: Clip.antiAlias,
      decoration: AppUI.card(),
      child: Padding(
        padding: EdgeInsets.fromLTRB(isMobile ? 16 : 20, 20, isMobile ? 16 : 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppUI.cardHeader(
              icon: 'buildings-2',
              title: 'Trust Settings',
              subtitle: 'Name shown at the top of the super-admin dashboard',
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
                              borderRadius: BorderRadius.circular(AppUI.controlRadius),
                              border: Border.all(color: AppColors.cardBorder),
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
                                  style: AppUI.label,
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: _pickTrustLogo,
                                      icon: AppIcon('document-upload', size: 14, color: AppColors.primary),
                                      label: Text(_trustLogoFile == null && (_trustLogoUrl ?? '').isEmpty ? 'Choose file' : 'Change'),
                                    ),
                                    if (_trustLogoFile != null || (_trustLogoUrl ?? '').isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      TextButton(
                                        onPressed: () => setState(() {
                                          _trustLogoFile = null;
                                          _trustLogoFileName = null;
                                          _trustLogoUrl = null;
                                        }),
                                        style: TextButton.styleFrom(foregroundColor: AppColors.error),
                                        child: const Text('Remove'),
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
              child: ElevatedButton.icon(
                onPressed: _savingTrust ? null : _saveTrust,
                icon: _savingTrust
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : AppIcon('save-2', size: 18, color: Colors.white),
                label: Text(_savingTrust ? 'Saving…' : 'Save'),
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
            const SnackBar(content: Text('Current password is incorrect'), backgroundColor: AppColors.error),
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
      // Session-gated via server-side password re-verification (the super admin
      // has no session token). Lets anon UPDATE on institutionusers be revoked.
      await SupabaseService.client.rpc('update_super_admin_self', params: {
        'p_username': loginId,
        'p_current_password': _currentPwdCtrl.text,
        'p_updates': updates,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account settings saved'), backgroundColor: AppColors.success),
        );
        _currentPwdCtrl.clear();
        _newPwdCtrl.clear();
        _confirmPwdCtrl.clear();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save your account settings. ${friendlyError(e)}'), backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _label(String text, {bool required = false}) => AppUI.fieldLabel(text, required: required);

  TextStyle _fieldStyle() => AppUI.fieldText(context);

  String? _validateEmail(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return 'Enter an email address';
    if (!RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$').hasMatch(t)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  // [filled] = the field has a value (accent edge); the shared kit field.
  InputDecoration _inputDec(String hint, {Widget? suffix, bool filled = false}) =>
      AppUI.field(context, hint, filled: filled, suffix: suffix).copyWith(
        // No hover tint — read-only fields shouldn't look interactive.
        hoverColor: Colors.transparent,
        suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 32),
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
            decoration: AppUI.card(),
            child: Form(
              key: _formKey,
              child: Padding(
                padding: EdgeInsets.fromLTRB(isMobile ? 16 : 20, 20, isMobile ? 16 : 20, 20),
                child: FocusTraversalGroup(
                  child: Column(
                  children: [
                    AppUI.cardHeader(
                      icon: 'setting-2',
                      title: 'Account Settings',
                      subtitle: 'Manage your account credentials',
                    ),
              const SizedBox(height: 24),
              if (isMobile) ...[
                _label('Username', required: true),
                TextFormField(
                  controller: _usernameCtrl,
                  readOnly: true,
                  canRequestFocus: false,
                  decoration: _inputDec('Enter username', filled: _usernameCtrl.text.trim().isNotEmpty),
                  style: _fieldStyle().copyWith(color: _usernameCtrl.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a username' : null,
                ),
                const SizedBox(height: 14),
                _label('Email', required: true),
                TextFormField(
                  controller: _emailCtrl,
                  readOnly: true,
                  canRequestFocus: false,
                  decoration: _inputDec('Enter email', filled: _emailCtrl.text.trim().isNotEmpty),
                  style: _fieldStyle().copyWith(color: _emailCtrl.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  validator: _validateEmail,
                ),
              ] else
                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _label('Username', required: true),
                    TextFormField(
                      controller: _usernameCtrl,
                      readOnly: true,
                      canRequestFocus: false,
                      decoration: _inputDec('Enter username', filled: _usernameCtrl.text.trim().isNotEmpty),
                      style: _fieldStyle().copyWith(color: _usernameCtrl.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a username' : null,
                    ),
                  ])),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _label('Email', required: true),
                    TextFormField(
                      controller: _emailCtrl,
                      readOnly: true,
                      canRequestFocus: false,
                      decoration: _inputDec('Enter email', filled: _emailCtrl.text.trim().isNotEmpty),
                      style: _fieldStyle().copyWith(color: _emailCtrl.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      validator: _validateEmail,
                    ),
                  ])),
                ]),
              const SizedBox(height: 14),
              _label('Mobile Number'),
              TextFormField(
                controller: _phoneCtrl,
                readOnly: true,
                canRequestFocus: false,
                decoration: _inputDec('Enter 10-digit mobile number', filled: _phoneCtrl.text.trim().isNotEmpty),
                style: _fieldStyle().copyWith(color: _phoneCtrl.text.trim().isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                onChanged: (_) => setState(() {}),
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
              AppUI.cardHeader(
                icon: 'lock',
                title: 'Change Password',
                subtitle: 'Leave new password blank to keep current',
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: _label('Current Password', required: true),
              ),
              TextFormField(
                controller: _currentPwdCtrl,
                obscureText: !_showCurrent,
                onChanged: (_) => setState(() {}),
                decoration: _inputDec(
                  'Enter current password',
                  filled: _currentPwdCtrl.text.isNotEmpty,
                  suffix: IconButton(
                    icon: AppIcon(_showCurrent ? 'eye-slash' : 'eye', size: 16, color: AppColors.textSecondary),
                    onPressed: () => setState(() => _showCurrent = !_showCurrent),
                  ),
                ),
                style: _fieldStyle().copyWith(color: _currentPwdCtrl.text.isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                validator: (v) => (v == null || v.isEmpty) ? 'Enter your current password to save changes' : null,
              ),
              const SizedBox(height: 14),
              if (isMobile) ...[
                _label('New Password'),
                TextFormField(
                  controller: _newPwdCtrl,
                  obscureText: !_showNew,
                  onChanged: (_) => setState(() {}),
                  decoration: _inputDec(
                    'Leave blank to keep current',
                    filled: _newPwdCtrl.text.isNotEmpty,
                    suffix: IconButton(
                      icon: AppIcon(_showNew ? 'eye-slash' : 'eye', size: 16, color: AppColors.textSecondary),
                      onPressed: () => setState(() => _showNew = !_showNew),
                    ),
                  ),
                  style: _fieldStyle().copyWith(color: _newPwdCtrl.text.isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                  validator: (v) {
                    if (v != null && v.isNotEmpty && v.length < 6) return 'Use at least 6 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                _label('Confirm New Password'),
                TextFormField(
                  controller: _confirmPwdCtrl,
                  obscureText: !_showConfirm,
                  onChanged: (_) => setState(() {}),
                  decoration: _inputDec(
                    'Re-enter new password',
                    filled: _confirmPwdCtrl.text.isNotEmpty,
                    suffix: IconButton(
                      icon: AppIcon(_showConfirm ? 'eye-slash' : 'eye', size: 16, color: AppColors.textSecondary),
                      onPressed: () => setState(() => _showConfirm = !_showConfirm),
                    ),
                  ),
                  style: _fieldStyle().copyWith(color: _confirmPwdCtrl.text.isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
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
                      onChanged: (_) => setState(() {}),
                      decoration: _inputDec(
                        'Leave blank to keep current',
                        filled: _newPwdCtrl.text.isNotEmpty,
                        suffix: IconButton(
                          icon: AppIcon(_showNew ? 'eye-slash' : 'eye', size: 16, color: AppColors.textSecondary),
                          onPressed: () => setState(() => _showNew = !_showNew),
                        ),
                      ),
                      style: _fieldStyle().copyWith(color: _newPwdCtrl.text.isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
                      validator: (v) {
                        if (v != null && v.isNotEmpty && v.length < 6) return 'Use at least 6 characters';
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
                      onChanged: (_) => setState(() {}),
                      decoration: _inputDec(
                        'Re-enter new password',
                        filled: _confirmPwdCtrl.text.isNotEmpty,
                        suffix: IconButton(
                          icon: AppIcon(_showConfirm ? 'eye-slash' : 'eye', size: 16, color: AppColors.textSecondary),
                          onPressed: () => setState(() => _showConfirm = !_showConfirm),
                        ),
                      ),
                      style: _fieldStyle().copyWith(color: _confirmPwdCtrl.text.isNotEmpty ? AppColors.accent : null, fontWeight: FontWeight.w600),
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
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : AppIcon('save-2', size: 18, color: Colors.white),
                  label: Text(_saving ? 'Saving…' : 'Save'),
                ),
              ),
              const SizedBox(height: 10),
              Center(child: AppUI.requiredNote()),
            ],
                  ),
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
        return "Today's Collection";
      case 'approval':
        return 'Pending Approval';
      case 'pending':
        return 'Total Pending';
      default:
        return 'Details';
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
        return "TODAY'S COLLECTION";
      case 'approval':
        return 'PENDING APPROVAL';
      case 'pending':
        return 'PENDING';
      default:
        return 'VALUE';
    }
  }

  String _formatAmount(double amount) {
    return formatIndianNumber(amount);
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
      // Order institutions by ins_id (KC01, KC02, KC03 ...) rather than by
      // the metric value.
      filtered.sort((a, b) => a.insId.compareTo(b.insId));
    }
    final aggregate = mode == 'active'
        ? filtered.length.toString()
        : _formatAmount(filtered.fold<double>(0, (sum, s) => sum + _value(s)));

    final isMobile = MediaQuery.of(context).size.width <= 800;
    final mobileColLabel = mode == 'approval' ? 'APPROVAL' : _columnLabel;
    final columnLabel = isMobile ? mobileColLabel : _columnLabel;
    final rowPadH = isMobile ? 12.0 : 16.0;

    final backButton = ElevatedButton.icon(
      onPressed: onBack ?? () => Navigator.of(context).pop(),
      icon: AppIcon.linear('Chevron Left', size: 14, color: Colors.white),
      label: const Text('Back'),
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
          Text('Total: ', style: AppUI.muted),
          Text(aggregate,
              style: AppUI.money.copyWith(color: AppColors.primary, fontWeight: FontWeight.w800)),
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
              decoration: AppUI.card(),
              child: isMobile
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('Dashboard', style: AppUI.muted),
                            const SizedBox(width: 6),
                            AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(_title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppUI.label),
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
                        Container(width: 1, height: 18, color: AppColors.divider),
                        const SizedBox(width: 12),
                        Text('Dashboard', style: AppUI.muted),
                        const SizedBox(width: 6),
                        AppIcon.linear('Chevron Right', size: 14, color: AppColors.textSecondary),
                        const SizedBox(width: 6),
                        Text(_title, style: AppUI.label),
                        const Spacer(),
                        totalPill,
                      ],
                    ),
            ),
            SizedBox(height: AppUI.gap),
            Expanded(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: AppUI.card(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: Row(
                        children: [
                          const CardTitleBlock(icon: 'buildings-2', title: 'Institution Breakdown', subtitle: 'fee performance per institution'),
                          const Spacer(),
                          Text('${filtered.length} institutions', style: AppUI.muted),
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
                          borderRadius: BorderRadius.circular(AppUI.controlRadius),
                          border: Border.all(color: AppColors.cardBorder),
                        ),
                        child: Column(
                          children: [
                            Container(
                              color: AppColors.tableHeadBg,
                              padding: EdgeInsets.symmetric(horizontal: rowPadH, vertical: 12),
                              child: Row(
                                children: [
                                  SizedBox(width: 28, child: Text('#', style: AppUI.tableHead)),
                                  AppUI.th('INSTITUTION', flex: 5),
                                  AppUI.th('CODE', flex: 2),
                                  AppUI.th(columnLabel, flex: 4, align: TextAlign.right),
                                ],
                              ),
                            ),
                            Expanded(
                              child: filtered.isEmpty
                                  ? AppUI.empty(
                                      icon: 'buildings-2',
                                      title: 'No data',
                                      why: 'No institution has a figure for this metric yet.',
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
                                              SizedBox(width: 28, child: Text('${i + 1}', style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
                                              Expanded(flex: 5, child: Text(s.insName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
                                              Expanded(flex: 2, child: Text(s.insCode, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.cell)),
                                              Expanded(
                                                flex: 4,
                                                child: mode == 'active'
                                                    ? Align(
                                                        alignment: Alignment.centerRight,
                                                        child: AppUI.chip(s.activeStatus ? 'Active' : 'Inactive',
                                                            s.activeStatus ? AppStatus.success : AppStatus.neutral),
                                                      )
                                                    : Text(_formatAmount(_value(s)),
                                                        textAlign: TextAlign.right,
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: AppUI.money),
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

// ── SuperAdmin dashboard chart painters ──────────────────────────────────────
class _ScSlice {
  final String label;
  final double value;
  final Color color;
  _ScSlice(this.label, this.value, this.color);
}

class _ScDonut extends CustomPainter {
  final List<_ScSlice> slices;
  final double total;
  _ScDonut(this.slices, this.total);

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final rect = Rect.fromLTWH(6, 6, size.width - 12, size.height - 12);
    final stroke = size.width * 0.20;
    var start = -1.5708;
    const gap = 0.03;
    for (final s in slices) {
      final sweep = (s.value / total) * 6.28319;
      final paint = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.butt;
      final drawSweep = (sweep - gap).clamp(0.0, 6.28319);
      canvas.drawArc(rect.deflate(stroke / 2), start + gap / 2, drawSweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_ScDonut old) => old.slices != slices || old.total != total;
}

class _ScBars extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final double maxV;
  _ScBars(this.values, this.labels, this.maxV);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || maxV <= 0) return;
    final h = size.height - 22;
    final grid = Paint()
      ..color = AppColors.divider
      ..strokeWidth = 1;
    for (var g = 0; g <= 3; g++) {
      final y = h * g / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final n = values.length;
    final slot = size.width / n;
    final barW = slot * 0.5;
    for (var i = 0; i < n; i++) {
      final bh = (values[i] / maxV).clamp(0.0, 1.0) * (h - 6);
      final left = i * slot + (slot - barW) / 2;
      final top = h - bh;
      if (bh > 0) {
        final rrect = RRect.fromRectAndCorners(
          Rect.fromLTWH(left, top, barW, bh),
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        );
        canvas.drawRRect(
            rrect,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.primary, AppColors.primary.withValues(alpha: 0.55)],
              ).createShader(Rect.fromLTWH(left, top, barW, bh)));
      }
      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: const TextStyle(fontSize: 10, color: AppColors.textLight, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(left + barW / 2 - tp.width / 2, h + 6));
    }
  }

  @override
  bool shouldRepaint(_ScBars old) => old.values != values || old.maxV != maxV;
}
