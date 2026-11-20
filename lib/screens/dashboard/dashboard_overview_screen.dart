import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/dashboard_tiles.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import '../fees/pending_approval_screen.dart';
import '../../utils/app_text.dart';

/// Dashboard overview — the institution's fee pulse at a glance, in four rows
/// ("Classic, polished", 2026-10-31): Total fees due; the number cards; Today's
/// collection, Pending approval and Quick actions; then Collection Overview
/// beside Collection by Mode, filling the rest of the window.
///
/// [onNavigate] lets the Quick Actions tiles jump to another sidebar menu by
/// label (the parent dashboard resolves the label to its nav index).
///
/// [allowedMenus] is the set of sidebar menu labels this user can actually open
/// (after role/permission filtering). Quick Actions are limited to these so a
/// user is never offered a shortcut to a screen they can't access. When null,
/// every action is shown.
class DashboardOverviewScreen extends StatefulWidget {
  final void Function(String label)? onNavigate;
  final Set<String>? allowedMenus;

  /// The role's raw rolemenuaccess grants, which carry the dash: tile keys
  /// alongside the menu labels. null while it loads, or for a role nobody has
  /// configured -- both mean "show everything", so the page never blanks on a
  /// missing lookup.
  final Set<String>? allowedTiles;

  const DashboardOverviewScreen(
      {super.key, this.onNavigate, this.allowedMenus, this.allowedTiles});

  @override
  State<DashboardOverviewScreen> createState() => _DashboardOverviewScreenState();
}

class _DashboardOverviewScreenState extends State<DashboardOverviewScreen> {
  // Dashboard titles and figures use the sans figure font (AppFonts.figure).
  TextStyle get _titleStyle => AppFonts.figure(size: 18.sp, weight: FontWeight.w700, height: 1.2);
  TextStyle get _money => AppFonts.figure(size: 13.5.sp, weight: FontWeight.w600);

  /// Is this card / panel granted to the role? See utils/dashboard_tiles.dart.
  bool _may(String key) => dashboardTileAllowed(widget.allowedTiles, key);

  bool _loading = true;
  bool _heavyLoading = true; // wave-2 aggregates (chart, pie, concession, pending)
  String? _error;

  int _students = 0;

  /// Active students per class type, keyed PROMOTIONAL / TERMINAL / COMPLETED.
  ///
  /// Empty when the database has no classtype column yet — the card then shows
  /// what it always showed rather than a row of zeros, which would read as
  /// "nobody is in a terminal class" instead of "not known here".
  Map<String, int> _byClassType = const {};

  /// Students actually studying: PROMOTIONAL + TERMINAL.
  ///
  /// COMPLETED is deliberately out. Those students are in TC classes -- they
  /// have left -- and on this data they are 1,851 of the 3,614 'active'
  /// students, so counting them made the headline overstate the student body
  /// by more than half.
  int get _regularStudents =>
      (_byClassType['PROMOTIONAL'] ?? 0) + (_byClassType['TERMINAL'] ?? 0);
  double _demand = 0, _collected = 0, _pending = 0, _fine = 0, _concession = 0;
  double _collectedToday = 0, _pendingApproval = 0, _misc = 0, _miscToday = 0;
  double _advance = 0, _advanceToday = 0;
  /// Fine collected TODAY, kept out of _collectedToday for the same reason the
  /// all-time fine is kept out of _collected: a penalty is not fee collection.
  double _fineToday = 0;
  List<_Bar> _monthly = [];
  List<MapEntry<String, double>> _byMethod = [];
  // Cached so tapping Fees Due / Collected / Outstanding reuses one fetch.
  Future<Map<String, (double, double)>>? _regArrFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _heavyLoading = true;
      _error = null;
      _regArrFuture = null; // invalidate cached drill-down split on refresh
    });
    final now = DateTime.now();
    final yearStart = DateTime(now.year - 1, now.month, 1);
    final todayYmd = _ymd(DateTime(now.year, now.month, now.day));

    // WAVE 1 — cheap, fast queries. Render the dashboard as soon as these land
    // so the KPIs and recent payments show immediately instead of waiting on
    // the heavy year-wide aggregates below.
    try {
      final core = await Future.wait<dynamic>([
        SupabaseService.getFeeTotals(_insId),
        SupabaseService.getStudentCount(_insId),
      ]);
      final totals = core[0] as Map<String, double>;
      if (!mounted) return;
      setState(() {
        _demand = totals['totalDemand'] ?? 0;
        _collected = totals['totalPaid'] ?? 0;
        _pending = totals['totalPending'] ?? 0;
        _fine = totals['totalFine'] ?? 0;
        _students = core[1] as int;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
      return;
    }

    // WAVE 2 — heavier aggregates (12-month trend, concession, pending-approval
    // sum, by-method breakdown). These fill in the chart, pie and their KPI
    // cards without blocking the initial paint.
    try {
      final heavy = await Future.wait<dynamic>([
        _fetchTrendByDay(yearStart, now),
        _fetchConcession(),
        _fetchPendingApproval(),
        _fetchByMethod(yearStart, now),
        _fetchMiscRows(yearStart),
        _fetchAdvanceRows(yearStart),
        _fetchAdvanceAdjustmentsByDay(yearStart, now),
        // No date floor: the card is money held on students' behalf, and an
        // advance taken 13 months ago is still held. With the 12-month window
        // the card fell every month as old advances aged out of it, while the
        // money itself had not moved.
        _fetchAdvanceRows(DateTime(2000)),
      ]);
      final byDayRaw = heavy[0] as Map<String, double>;
      final concession = heavy[1] as double;
      final pendingApproval = heavy[2] as double;
      final rawByMethod = Map<String, double>.from(heavy[3] as Map<String, double>);
      final miscRows = heavy[4] as List<Map<String, dynamic>>;
      final advanceRows = heavy[5] as List<Map<String, dynamic>>;
      final adjByDay = heavy[6] as Map<String, double>;
      // WHAT IS STILL HELD, not what was ever taken. balanceamount is a
      // stored generated column -- transtotalamount - adjustedamount -
      // refund_amount -- so the figure needs no arithmetic here and cannot
      // drift from the Advance Register, which reads the same column.
      //
      // Summing transtotalamount made the card a running total of every
      // advance ever collected: it only ever rose, including for advances
      // already adjusted against a fee receipt or refunded in full. The
      // college's actual liability -- money taken that it still owes the
      // student a service for -- was never on the dashboard.
      final advanceHeld = (heavy[7] as List<Map<String, dynamic>>).fold<double>(
          0, (a, r) => a + ((r['balanceamount'] as num?)?.toDouble() ?? 0));

      // Net the adjustment receipts out of the daily fee totals before anything
      // is derived from them — see _fetchAdvanceAdjustmentsByDay.
      final byDay = <String, double>{};
      byDayRaw.forEach((day, amt) {
        final net = amt - (adjByDay[day] ?? 0);
        byDay[day] = net > 0 ? net : 0;
      });

      // Fold misc collection into the year/today totals, the monthly bars and
      // the by-mode pie. _fetchMiscRows returns approved rows only, so an
      // unreconciled misc receipt sits in Pending Approval instead -- the same
      // treatment a UPI fee payment gets.
      double miscYear = 0, miscToday = 0;
      final miscByMonth = <String, double>{};
      for (final r in miscRows) {
        final amt = (r['totalamount'] as num?)?.toDouble() ?? 0;
        final raw = r['mcdate']?.toString() ?? '';
        final day = raw.length >= 10 ? raw.substring(0, 10) : raw;
        miscYear += amt;
        if (day == todayYmd) miscToday += amt;
        final monKey = day.length >= 7 ? day.substring(0, 7) : day;
        miscByMonth[monKey] = (miscByMonth[monKey] ?? 0) + amt;
        rawByMethod[_normMethod(r['paymode']?.toString() ?? '')] =
            (rawByMethod[_normMethod(r['paymode']?.toString() ?? '')] ?? 0) + amt;
      }
      // Fold advance collection in the same way as misc.
      double advToday = 0;
      final advByMonth = <String, double>{};
      for (final r in advanceRows) {
        final amt = (r['transtotalamount'] as num?)?.toDouble() ?? 0;
        final raw = r['advdate']?.toString() ?? '';
        final day = raw.length >= 10 ? raw.substring(0, 10) : raw;
        if (day == todayYmd) advToday += amt;
        final monKey = day.length >= 7 ? day.substring(0, 7) : day;
        advByMonth[monKey] = (advByMonth[monKey] ?? 0) + amt;
        final m = _normMethod(r['paymethod']?.toString() ?? '');
        rawByMethod[m] = (rawByMethod[m] ?? 0) + amt;
      }
      // The pie must not show the adjustments either — they are already in it
      // via the trend RPC, under whatever _normMethod makes of the string.
      rawByMethod.remove(_normMethod('Advance Adjustment'));

      final byMethod = rawByMethod.entries.where((e) => e.value > 0).toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      final byMonth = <String, double>{};
      byDay.forEach((dayKey, amt) {
        final monKey = dayKey.length >= 7 ? dayKey.substring(0, 7) : dayKey;
        byMonth[monKey] = (byMonth[monKey] ?? 0) + amt;
      });
      miscByMonth.forEach((k, v) => byMonth[k] = (byMonth[k] ?? 0) + v);
      advByMonth.forEach((k, v) => byMonth[k] = (byMonth[k] ?? 0) + v);
      const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final monthly = <_Bar>[];
      for (var i = 11; i >= 0; i--) {
        final d = DateTime(now.year, now.month - i, 1);
        final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        monthly.add(_Bar('${monthNames[d.month - 1]} ${d.year % 100}', byMonth[key] ?? 0));
      }

      // Today's fine, from the same reconciled source the Daily Collection
      // report uses, so the two agree. Its own try/catch -- a dashboard must
      // still render if this one figure cannot be had.
      double fineToday = 0;
      try {
        final schema = SupabaseService.currentSchema;
        if (schema != null && schema.isNotEmpty) {
          final agg = await SupabaseService.client.rpc(
            'get_daily_collection_report_json',
            params: {
              'p_schema': schema,
              'p_ins_id': _insId,
              'p_from': todayYmd,
              'p_to': todayYmd,
            },
          );
          if (agg is List) {
            for (final r in agg) {
              fineToday += ((r as Map)['fine'] as num?)?.toDouble() ?? 0;
            }
          }
        }
      } catch (e) {
        debugPrint("today's fine lookup failed: \$e");
      }

      final byClassType = await _loadByClassType();

      if (!mounted) return;
      setState(() {
        _byClassType = byClassType;
        _fineToday = fineToday;
        _collectedToday = (byDay[todayYmd] ?? 0) - fineToday;
        _concession = concession;
        _pendingApproval = pendingApproval;
        _monthly = monthly;
        _byMethod = byMethod;
        _misc = miscYear;
        _miscToday = miscToday;
        // The card counts every active advance. The 12-month rows still feed
        // the chart (advByMonth) and the by-mode pie (rawByMethod) above.
        _advance = advanceHeld;
        _advanceToday = advToday;
        _heavyLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _heavyLoading = false); // leave the core dashboard usable
    }
  }

  Future<Map<String, double>> _fetchTrendByDay(DateTime from, DateTime to) async {
    final byDay = <String, double>{};
    try {
      final rows = await SupabaseService.client.rpc(
        'get_reconciled_collection_by_day',
        params: {'p_ins_id': _insId, 'p_from': _ymd(from), 'p_to': _ymd(to)},
      );
      for (final r in (rows as List)) {
        final day = r['day']?.toString();
        if (day == null) continue;
        final key = day.length >= 10 ? day.substring(0, 10) : day;
        byDay[key] = (byDay[key] ?? 0) + ((r['total'] as num?)?.toDouble() ?? 0);
      }
      return byDay;
    } catch (_) {
      byDay.clear();
      try {
        final payments = await SupabaseService.getPaymentsByDateRange(_insId, fromDate: from, toDate: to);
        for (final p in List<Map<String, dynamic>>.from(payments)) {
          if ((p['recon_status']?.toString() ?? 'P') != 'R') continue;
          final d = DateTime.tryParse(p['paydate']?.toString() ?? '');
          if (d == null) continue;
          byDay[_ymd(d)] = (byDay[_ymd(d)] ?? 0) + ((p['transtotalamount'] as num?)?.toDouble() ?? 0);
        }
      } catch (_) {}
      return byDay;
    }
  }

  /// Miscellaneous fee-collection rows (this year) — amount, date and mode.
  /// Aggregated in _load into the Misc card, the Today split, the monthly bars
  /// and the Collection-by-Mode pie.
  Future<List<Map<String, dynamic>>> _fetchMiscRows(DateTime from) async {
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('misc_collection')
          .select('totalamount, mcdate, paymode, recon_status')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .gte('mcdate', _ymd(from)));
      // Only bank-approved money counts as collected, matching fee payments
      // (Today Collection has always been recon_status='R' only). A row from a
      // database without the column reads null and counts, which is how misc
      // behaved before reconciliation applied to it.
      return [
        for (final r in List<Map<String, dynamic>>.from(rows))
          if ((r['recon_status']?.toString() ?? 'R') != 'P') r
      ];
    } catch (_) {
      // Older deployment: no recon_status column, so the select above 400s.
      // Retry without it rather than showing zero misc collection.
      try {
        final rows = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('misc_collection')
            .select('totalamount, mcdate, paymode')
            .eq('ins_id', _insId)
            .eq('activestatus', 1)
            .gte('mcdate', _ymd(from)));
        return List<Map<String, dynamic>>.from(rows);
      } catch (_) {
        return [];
      }
    }
  }

  /// Advance collections since [from]. Money over the counter on the day it is
  /// taken, so it counts exactly as a misc receipt does — and like misc, only
  /// bank-approved rows count; an unreconciled cheque advance sits in Pending
  /// Approval instead.
  Future<List<Map<String, dynamic>>> _fetchAdvanceRows(DateTime from) async {
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('advance_collection')
          .select('transtotalamount, balanceamount, advdate, paymethod, recon_status')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .eq('paystatus', 'C')
          .gte('advdate', _ymd(from)));
      return [
        for (final r in List<Map<String, dynamic>>.from(rows))
          if ((r['recon_status']?.toString() ?? 'R') != 'P') r
      ];
    } catch (_) {
      // The table may not exist on this database yet.
      return [];
    }
  }

  /// Per-day total settled out of an ADVANCE.
  ///
  /// Read from advadjustment, not from payment. An advance can reach a receipt
  /// two ways — attached to a cash receipt (the total then covers both) or on
  /// its own — and advadjustment records both identically, so one query nets
  /// off either. Keying on paymethod would miss the attached case entirely.
  ///
  /// It has to be netted off because the money was ALREADY counted as
  /// collection on the day the advance was taken; the trend RPC sums every
  /// reconciled payment row and would report that rupee twice.
  ///
  /// Only rows with a pay_id. An ADMISSION advance reduces the fee instead of
  /// paying it and writes no payment row at all, so there is nothing of it in
  /// the trend to net off -- subtracting it would take the day's collection
  /// below what was actually collected.
  Future<Map<String, double>> _fetchAdvanceAdjustmentsByDay(
      DateTime from, DateTime to) async {
    final byDay = <String, double>{};
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('advadjustment')
          .select('adjustdate, adjustamount')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .not('pay_id', 'is', null)
          .gte('adjustdate', _ymd(from)));
      for (final r in List<Map<String, dynamic>>.from(rows)) {
        final raw = r['adjustdate']?.toString() ?? '';
        final day = raw.length >= 10 ? raw.substring(0, 10) : raw;
        if (day.isEmpty) continue;
        byDay[day] = (byDay[day] ?? 0) + ((r['adjustamount'] as num?)?.toDouble() ?? 0);
      }
    } catch (_) {/* table not there yet — nothing to net off */}
    return byDay;
  }

  /// Total concession granted across all demands — summed from the same
  /// class-wise summary the Fee Demand page uses, so the figures tally.
  Future<double> _fetchConcession() async {
    try {
      final rows = await SupabaseService.getFeeDemandSummary(_insId);
      double sum = 0;
      for (final r in rows) {
        sum += (r['total_concession'] as num?)?.toDouble() ?? 0;
      }
      return sum;
    } catch (_) {}
    return 0;
  }

  /// Amount awaiting approval = COMPLETED payments not yet reconciled
  /// (paystatus='C' AND recon_status='P'), all-time. The paystatus='C' filter
  /// matches the Pending Approval drill-down and get_fee_totals — without it,
  /// initiated/failed rows inflate the card above the actual pending list.
  Future<double> _fetchPendingApproval() async {
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('payment')
          .select('transtotalamount')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .eq('paystatus', 'C')
          .eq('recon_status', 'P'));
      double sum = 0;
      for (final r in (rows as List)) {
        sum += (r['transtotalamount'] as num?)?.toDouble() ?? 0;
      }

      // Misc receipts wait for the same approval. Without them this card
      // disagrees with the Pending Approval list it opens, and with Bank
      // Reconciliation -- the card is a link to that list, so it has to match.
      try {
        final misc = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('misc_collection')
            .select('totalamount')
            .eq('ins_id', _insId)
            .eq('activestatus', 1)
            .eq('recon_status', 'P'));
        for (final r in (misc as List)) {
          sum += (r['totalamount'] as num?)?.toDouble() ?? 0;
        }
      } catch (_) {
        // No recon_status column yet: nothing misc is pending, by definition.
      }

      // And advances. A cheque or UPI advance waits for the bank exactly as a
      // fee or misc receipt does, and it is listed in both Bank Reconciliation
      // and the Pending Approval screen -- leaving it out of the card meant the
      // card reported less than the list it opens.
      try {
        final adv = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('advance_collection')
            .select('transtotalamount')
            .eq('ins_id', _insId)
            .eq('activestatus', 1)
            .eq('paystatus', 'C')
            .eq('recon_status', 'P'));
        for (final r in (adv as List)) {
          sum += (r['transtotalamount'] as num?)?.toDouble() ?? 0;
        }
      } catch (_) {
        // Advance module not deployed on this database.
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  /// Reconciled collection grouped by normalised payment method, for the
  /// collection pie. Methods are folded into Cash / Online / Card / DD / Other.
  /// Queries the payment table directly (2 columns, reconciled only) rather than
  /// the student-joined date-range RPC — far less data to transfer.
  Future<Map<String, double>> _fetchByMethod(DateTime from, DateTime to) async {
    final byMethod = <String, double>{};
    try {
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('payment')
          .select('paymethod, transtotalamount')
          .eq('ins_id', _insId).eq('activestatus', 1)
          // 'R' = later refunded: the money was received (the refund is its own line)
          .inFilter('paystatus', ['C', 'R']).eq('recon_status', 'R')
          .gte('paydate', _ymd(from)));
      for (final p in List<Map<String, dynamic>>.from(rows)) {
        final m = _normMethod(p['paymethod']?.toString() ?? '');
        byMethod[m] = (byMethod[m] ?? 0) + ((p['transtotalamount'] as num?)?.toDouble() ?? 0);
      }
    } catch (_) {}
    return byMethod;
  }

  String _normMethod(String raw) {
    final m = raw.trim().toLowerCase();
    if (m.contains('cash')) return 'Cash';
    if (m.contains('upi') || m.contains('online') || m.contains('net')) return 'Online';
    if (m.contains('card')) return 'Card';
    if (m.contains('dd') || m.contains('cheque') || m.contains('draft')) return 'DD/Cheque';
    return raw.trim().isEmpty ? 'Other' : raw.trim();
  }

  Color _methodColor(String m) {
    switch (m) {
      case 'Cash':
        return AppColors.chart[0];
      case 'Online':
        return AppColors.chart[1];
      case 'DD/Cheque':
        return AppColors.chart[3];
      case 'Card':
        return AppColors.chart[4];
      default:
        return AppColors.chart[2];
    }
  }

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _inr(double v) {
    if (v >= 1e7) return '₹${(v / 1e7).toStringAsFixed(2)} Cr';
    if (v >= 1e5) return '₹${(v / 1e5).toStringAsFixed(2)} L';
    if (v >= 1e3) return '₹${(v / 1e3).toStringAsFixed(1)}K';
    return '₹${v.toStringAsFixed(0)}';
  }

  /// Full rupee value with Indian digit grouping (e.g. ₹6,18,00,000) — no
  /// K/L/Cr abbreviation. Used for the KPI cards.
  String _inrFull(double v) {
    final neg = v < 0;
    final s = v.abs().round().toString();
    String grouped;
    if (s.length <= 3) {
      grouped = s;
    } else {
      final last3 = s.substring(s.length - 3);
      final rest = s.substring(0, s.length - 3);
      final withCommas = rest.replaceAllMapped(RegExp(r'\B(?=(\d{2})+(?!\d))'), (_) => ',');
      grouped = '$withCommas,$last3';
    }
    return '${neg ? '-' : ''}₹$grouped';
  }

  double _pct(double part) => _demand <= 0 ? 0 : (part / _demand * 100).clamp(0, 100);

  // ── Layout ("Classic, polished", 2026-10-31) ─────────────────────────────
  // Spec: DBA/redesign/DASHBOARD_CLASSIC_POLISHED_HANDOFF.md. Sizes there are
  // pixels on a 1920-wide window; _p scales them to the window actually open.
  double _k = 1;
  double _p(double v) => v * _k;
  double get _gap => _p(14); // tighter than the spec (22): user, 2026-11-03

  TextStyle get _labelStyle =>
      AppFonts.body(size: _p(12), weight: FontWeight.w800, color: AppColors.ink2, letterSpacing: 0.07 * _p(12));
  TextStyle get _valueStyle =>
      AppFonts.body(size: _p(30), weight: FontWeight.w800, color: AppColors.ink, letterSpacing: -0.01 * _p(30))
          .copyWith(height: 1.15);
  TextStyle get _bigStyle =>
      AppFonts.body(size: _p(48), weight: FontWeight.w800, color: AppColors.ink, letterSpacing: -0.02 * _p(48))
          .copyWith(height: 1.05);
  TextStyle get _subStyle => AppFonts.body(size: _p(14), weight: FontWeight.w500, color: AppColors.ink2);

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading(label: 'Loading dashboard…');
    if (_error != null) {
      return EmptyState(
        icon: 'info-circle',
        title: 'Could not load the dashboard',
        subtitle: 'Check your internet connection, then select Retry.',
        action: OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
      );
    }

    final width = MediaQuery.of(context).size.width;
    _k = (width / 1920).clamp(0.74, 1.2).toDouble();
    final wide = width >= 1500;

    final showChart = _may('${kDashboardTilePrefix}chart_overview');
    final showPie = _may('${kDashboardTilePrefix}chart_mode');

    // Rows 1-3: Total fees due, the number cards, then Today's collection /
    // Pending approval / Quick actions.
    final rows = <Widget>[];
    var minH = 0.0;
    void add(Widget w, double h) {
      rows.add(w);
      minH += _p(h);
    }

    add(_welcome(), 34);
    if (_showHero) add(_feesDueCard(), 186);
    final perRow = width < 1100 ? 2 : 4;
    final cards = _numberCards();
    for (var i = 0; i < cards.length; i += perRow) {
      add(_equalRow([for (final n in cards.skip(i).take(perRow)) (_numCard(n), 1)], fillTo: perRow), 124);
    }
    final today = _may('dash:today') ? _todayTicket() : null;
    final pending = _may('dash:pendingapproval') ? _pendingCard() : null;
    final actions = _may('${kDashboardTilePrefix}quickactions') ? _quickActionsCard() : null;
    if (wide) {
      // On the same 4-column grid as the number cards: Quick actions spans
      // columns 3-4, so every edge lines up with the row above.
      final items = [if (today != null) (today, 1), if (pending != null) (pending, 1), if (actions != null) (actions, 2)];
      if (items.isNotEmpty) add(_gridRow(items), 150);
    } else {
      final items = [if (today != null) (today, 1), if (pending != null) (pending, 1)];
      if (items.isNotEmpty) add(_equalRow(items), 150);
      if (actions != null) add(actions, 150);
    }

    return LayoutBuilder(builder: (context, c) {
      // Row 4 fills what is left of the window when there is room for it;
      // otherwise the page scrolls and the charts get a fixed height.
      final fill = wide && c.maxHeight.isFinite && c.maxHeight >= minH + _gap * rows.length + _p(260);
      final row4 = _row4(wide: wide, showChart: showChart, showPie: showPie);
      final children = <Widget>[
        for (var i = 0; i < rows.length; i++) ...[if (i > 0) SizedBox(height: _gap), rows[i]],
        if (row4 != null) ...[
          if (rows.isNotEmpty) SizedBox(height: _gap),
          if (fill) Expanded(child: row4) else if (wide) SizedBox(height: _p(390), child: row4) else row4,
        ],
      ];
      if (fill) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
      return RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          // a lane for the scrollbar, so it does not sit over the cards
          padding: const EdgeInsets.only(right: 14, bottom: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      );
    });
  }

  // ── Shared pieces ──────────────────────────────────────────────────────────
  BoxDecoration _dCard({Color? color, Color? border}) => BoxDecoration(
        color: color ?? AppColors.card,
        borderRadius: BorderRadius.circular(_p(16)),
        border: Border.all(color: border ?? AppColors.line),
        boxShadow: [
          const BoxShadow(color: AppColors.dashShadowNear, blurRadius: 2, offset: Offset(0, 1)),
          BoxShadow(
              color: AppColors.ink.withValues(alpha: 0.35),
              blurRadius: 28,
              spreadRadius: -22,
              offset: const Offset(0, 12)),
        ],
      );

  /// 42x42 icon tile: the colour at 13% over the card, outline icon in it.
  Widget _tile(String icon, Color c, {double size = 42, double radius = 12, double iconSize = 21}) => Container(
        width: _p(size),
        height: _p(size),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Color.alphaBlend(c.withValues(alpha: 0.13), AppColors.card),
          borderRadius: BorderRadius.circular(_p(radius)),
        ),
        // marigold is too light for a line icon: its tile keeps marigold,
        // the icon takes the darker marigold
        child: AppIcon.linear(icon, size: _p(iconSize), color: c == AppColors.gold ? AppColors.goldDark : c),
      );

  Widget _arrow(Color c) => Positioned(
        right: _p(18),
        top: _p(20),
        child: Icon(Icons.chevron_right, size: _p(20), color: c),
      );

  Widget _tap(Widget child, VoidCallback? onTap) => onTap == null
      ? child
      : MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: child),
        );

  /// "Good morning, ADMIN" -- the signed-in user, by the time of day.
  Widget _welcome() {
    final auth = context.read<AuthProvider>();
    final user = auth.currentUser;
    final name = (user?.usename.trim().isNotEmpty == true ? user!.usename : (auth.userName ?? '')).trim();
    final h = DateTime.now().hour;
    final greet = h < 12 ? 'Good morning' : (h < 17 ? 'Good afternoon' : 'Good evening');
    final role = '${user?.urname ?? ''}'.trim();
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text('$greet, ', style: AppFonts.body(size: _p(22), weight: FontWeight.w600, color: AppColors.ink2)),
      Flexible(
        child: Text(name.isEmpty ? 'Welcome' : name,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.heading(size: _p(26), weight: FontWeight.w700, color: AppColors.primaryDark)),
      ),
      if (role.isNotEmpty) ...[
        SizedBox(width: _p(12)),
        Padding(padding: EdgeInsets.only(bottom: _p(4)), child: AppUI.chip(role, AppStatus.info)),
      ],
    ]);
  }

  /// Cards on the dashboard's 4-column grid (the number cards' columns), each
  /// spanning `$2` columns: a 2-column card is two columns plus the gap
  /// between them, so its edges meet the cards above and below.
  Widget _gridRow(List<(Widget, int)> items, {bool stretchHeight = false}) {
    return LayoutBuilder(builder: (context, c) {
      final col = (c.maxWidth - 3 * _gap) / 4;
      final row = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(width: _gap),
          if (i == items.length - 1)
            Expanded(child: items[i].$1)
          else
            SizedBox(width: col * items[i].$2 + _gap * (items[i].$2 - 1), child: items[i].$1),
        ],
      ]);
      return stretchHeight ? row : IntrinsicHeight(child: row);
    });
  }

  /// Cards side by side at one height (the tallest), [fillTo] keeping a short
  /// last row's cards the same width as the rows above.
  Widget _equalRow(List<(Widget, int)> items, {int? fillTo}) {
    final n = fillTo ?? items.length;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < n; i++) ...[
          if (i > 0) SizedBox(width: _gap),
          Expanded(flex: i < items.length ? items[i].$2 : 1, child: i < items.length ? items[i].$1 : const SizedBox()),
        ],
      ]),
    );
  }

  // ── Row 1: Total fees due ──────────────────────────────────────────────────
  bool get _showHero => _may('dash:demand');

  Widget _feesDueCard() {
    String pc(double v) => '${v.toStringAsFixed(1)}%';
    final showCol = _may('dash:collected'), showOut = _may('dash:outstanding');
    final left = _tap(
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          _tile('receipt-text', AppColors.tileViolet),
          SizedBox(width: _p(13)),
          Flexible(child: Text('TOTAL FEES DUE', maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle)),
        ]),
        SizedBox(height: _p(16)),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(_inrFull(_demand), maxLines: 1, style: _bigStyle),
        ),
        SizedBox(height: _p(8)),
        Text('Regular + arrear · click for the split', maxLines: 1, overflow: TextOverflow.ellipsis, style: _subStyle),
      ]),
      () => _showRegArrBreakdown('demand', 'Total Fees Due', AppColors.demand, 'receipt-2'),
    );

    final stats = <Widget>[
      if (showCol)
        _stat('dollar-circle', AppColors.primary, 'COLLECTED', _inrFull(_collected),
            '${pc(_pct(_collected))} of fees due · click for details',
            () => _showRegArrBreakdown('paid', 'Total Collected', AppColors.success, 'money-recive')),
      if (_may('dash:concession'))
        _stat('percentage-square', AppColors.tileViolet, 'CONCESSION', _heavyLoading ? '…' : _inrFull(_concession),
            _heavyLoading ? 'Loading…' : '${pc(_pct(_concession))} of fees due', null),
      if (showOut)
        _stat('clock', AppColors.orange, 'OUTSTANDING', _inrFull(_pending),
            '${pc(_pct(_pending))} of fees due · click for details',
            () => _showRegArrBreakdown('outstanding', 'Outstanding', AppColors.today, 'wallet-money')),
    ];

    final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (showCol || showOut) ...[
        Row(children: [
          if (showCol)
            Text('${pc(_pct(_collected))} collected',
                style: AppFonts.body(size: _p(12.5), weight: FontWeight.w700, color: AppColors.primary)),
          const Spacer(),
          if (showOut)
            Text('${pc(_pct(_pending))} outstanding',
                style: AppFonts.body(size: _p(12.5), weight: FontWeight.w700, color: AppColors.ink2)),
        ]),
        SizedBox(height: _p(8)),
      ],
      ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: _p(12),
          color: Color.alphaBlend(AppColors.gold.withValues(alpha: 0.32), AppColors.card),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: showCol ? _pct(_collected) / 100 : 0,
            heightFactor: 1,
            child: Container(color: AppColors.primary),
          ),
        ),
      ),
      if (stats.isNotEmpty) ...[
        SizedBox(height: _p(22)),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < stats.length; i++) ...[if (i > 0) SizedBox(width: _p(20)), Expanded(child: stats[i])],
        ]),
      ],
    ]);

    return Container(
      constraints: BoxConstraints(minHeight: _p(186)),
      padding: EdgeInsets.symmetric(horizontal: _p(32), vertical: _p(28)),
      decoration: _dCard(),
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < _p(1050)) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            left,
            SizedBox(height: _p(22)),
            right,
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: _p(440), child: left),
          SizedBox(width: _p(34)),
          Container(width: 1, height: _p(126), color: AppColors.line),
          SizedBox(width: _p(34)),
          Expanded(child: right),
        ]);
      }),
    );
  }

  Widget _stat(String icon, Color c, String label, String value, String sub, VoidCallback? onTap) => _tap(
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _tile(icon, c),
          SizedBox(width: _p(12)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle),
              SizedBox(height: _p(3)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value,
                    maxLines: 1,
                    style: AppFonts.body(
                        size: _p(23), weight: FontWeight.w800, color: AppColors.ink, letterSpacing: -0.01 * _p(23))),
              ),
              SizedBox(height: _p(2)),
              Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppFonts.body(size: _p(13), color: AppColors.ink2)),
            ]),
          ),
        ]),
        onTap,
      );

  // ── Row 2: number cards ────────────────────────────────────────────────────
  List<_Num> _numberCards() {
    String hv(double v) => _heavyLoading ? '…' : _inrFull(v);
    final allowed = widget.allowedMenus;
    final canOpenStudents = allowed == null || allowed.contains('Students');
    return [
      if (_may('dash:students'))
        _Num('people', AppColors.primary, 'TOTAL STUDENTS',
            // The regular body when the split is known; the plain active count
            // when it is not, rather than a misleading 0.
            _byClassType.isEmpty ? _students.toString() : _regularStudents.toString(),
            'Active students',
            canOpenStudents ? () => widget.onNavigate?.call('Students') : null),
      // A role that may not see Total fees due gets these as plain cards.
      if (!_showHero && _may('dash:collected'))
        _Num('dollar-circle', AppColors.primary, 'TOTAL COLLECTED', _inrFull(_collected),
            '${_pct(_collected).toStringAsFixed(1)}% collected · click for the split',
            () => _showRegArrBreakdown('paid', 'Total Collected', AppColors.success, 'money-recive')),
      if (!_showHero && _may('dash:concession'))
        _Num('percentage-square', AppColors.tileViolet, 'CONCESSION', hv(_concession), 'Total waived', null),
      if (!_showHero && _may('dash:outstanding'))
        _Num('clock', AppColors.orange, 'OUTSTANDING', _inrFull(_pending),
            '${_pct(_pending).toStringAsFixed(1)}% pending · click for the split',
            () => _showRegArrBreakdown('outstanding', 'Outstanding', AppColors.today, 'wallet-money')),
      if (_may('dash:misc'))
        _Num('coin', AppColors.tileViolet, 'MISCELLANEOUS COLLECTION', hv(_misc), 'Miscellaneous fees', null),
      if (_may('dash:advance'))
        _Num('strongbox', AppColors.tileBlue, 'ADVANCE COLLECTION', hv(_advance), 'Held, not yet adjusted', null),
      if (_may('dash:fine'))
        _Num('warning-2', AppColors.tileRed, 'FINE COLLECTED', _inrFull(_fine), 'Late-fee collected', null),
    ];
  }

  Widget _numCard(_Num n) => _tap(
        Container(
          constraints: BoxConstraints(minHeight: _p(124)),
          decoration: _dCard(),
          child: Stack(fit: StackFit.passthrough, children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: _p(22), vertical: _p(20)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _tile(n.icon, n.color),
                SizedBox(width: _p(15)),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Padding(
                      padding: EdgeInsets.only(right: n.onTap != null ? _p(16) : 0),
                      child: Text(n.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle),
                    ),
                    SizedBox(height: _p(5)),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(n.value, maxLines: 1, style: _valueStyle),
                    ),
                    SizedBox(height: _p(4)),
                    Text(n.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: _subStyle),
                  ]),
                ),
              ]),
            ),
            if (n.onTap != null) _arrow(AppColors.ink3),
          ]),
        ),
        n.onTap,
      );

  // ── Row 3a: Today's collection (teal ticket) ───────────────────────────────
  Widget _todayTicket() {
    final total = _collectedToday + _miscToday + _advanceToday + _fineToday;
    final onTap = _heavyLoading ? null : _showTodayBreakdown;
    final card = Container(
      constraints: BoxConstraints(minHeight: _p(150)),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_p(16)),
        boxShadow: [
          BoxShadow(
              color: AppColors.primaryDark.withValues(alpha: 0.8),
              blurRadius: 30,
              spreadRadius: -18,
              offset: const Offset(0, 18)),
        ],
      ),
      child: ClipPath(
        clipper: _TicketClipper(radius: _p(16), notch: _p(5.5), pitch: _p(14)),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [AppColors.primary, AppColors.primaryDark]),
          ),
          child: Stack(fit: StackFit.passthrough, children: [
            // decorative ring, clipped by the ticket
            Positioned(
              right: -_p(46),
              top: -_p(60),
              child: Container(
                width: _p(170),
                height: _p(170),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: _p(24)),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(_p(22), _p(20), _p(22), _p(20)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: EdgeInsets.only(right: _p(16)),
                  child: Text("TODAY'S COLLECTION · ${formatDmy(DateTime.now())}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _labelStyle.copyWith(color: AppColors.onPrimaryWarm)),
                ),
                SizedBox(height: _p(6)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(_heavyLoading ? '…' : _inrFull(total),
                      maxLines: 1,
                      style: AppFonts.body(
                              size: _p(36), weight: FontWeight.w800, color: Colors.white, letterSpacing: -0.01 * _p(36))
                          .copyWith(height: 1.1)),
                ),
                SizedBox(height: _p(10)),
                SizedBox(
                  height: 1.5,
                  width: double.infinity,
                  child: CustomPaint(painter: _DashedHLine(Colors.white.withValues(alpha: 0.35), 1.5)),
                ),
                SizedBox(height: _p(10)),
                Text(
                  _heavyLoading ? 'Reconciled today' : 'Fee + miscellaneous + advance + fine · click for the split',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(size: _p(13.5), color: Colors.white.withValues(alpha: 0.8)),
                ),
              ]),
            ),
            if (onTap != null) _arrow(AppColors.onPrimaryWarm),
          ]),
        ),
      ),
    );
    return _tap(card, onTap);
  }

  // ── Row 3b: Pending approval ───────────────────────────────────────────────
  Widget _pendingCard() {
    final card = Container(
      constraints: BoxConstraints(minHeight: _p(150)),
      decoration: _dCard(
        color: Color.alphaBlend(AppColors.orange.withValues(alpha: 0.06), AppColors.card),
        border: Color.alphaBlend(AppColors.orange.withValues(alpha: 0.34), AppColors.card),
      ),
      child: Stack(fit: StackFit.passthrough, children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: _p(22), vertical: _p(20)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _tile('clipboard-tick', AppColors.orange),
            SizedBox(width: _p(15)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: EdgeInsets.only(right: _p(16)),
                  child: Text('PENDING APPROVAL', maxLines: 1, overflow: TextOverflow.ellipsis, style: _labelStyle),
                ),
                SizedBox(height: _p(5)),
                Row(children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(_heavyLoading ? '…' : _inrFull(_pendingApproval), maxLines: 1, style: _valueStyle),
                    ),
                  ),
                  SizedBox(width: _p(10)),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: _p(8), vertical: _p(3)),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(_p(6)),
                      border: Border.all(color: AppColors.orangeInk, width: 1.5),
                    ),
                    child: Text('ACTION',
                        style: AppFonts.body(
                            size: _p(11), weight: FontWeight.w800, color: AppColors.orangeInk, letterSpacing: 0.1 * _p(11))),
                  ),
                ]),
                SizedBox(height: _p(4)),
                Text('Awaiting reconciliation · click to view',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: _subStyle),
              ]),
            ),
          ]),
        ),
        _arrow(AppColors.orangeInk),
      ]),
    );
    return _tap(card, () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PendingApprovalScreen())));
  }

  // ── Row 3c: Quick actions ──────────────────────────────────────────────────
  Widget _quickActionsCard() {
    final allowed = widget.allowedMenus;
    final acts = <_QuickAction>[
      _QuickAction('Collect fee', 'receipt-text', AppColors.primary, 'Fee Collection'),
      _QuickAction('New admission', 'user-add', AppColors.tileBlue, 'Admission'),
      _QuickAction('Issue TC', 'document-text', AppColors.tileViolet, 'Transfer Certificate'),
      _QuickAction('Day book', 'book', AppColors.orange, 'Daily Collection'),
    ].where((a) => allowed == null || allowed.contains(a.menu)).toList();
    return Container(
      constraints: BoxConstraints(minHeight: _p(150)),
      padding: EdgeInsets.symmetric(horizontal: _p(20), vertical: _p(16)),
      decoration: _dCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          AppIcon.linear('flash', size: _p(18), color: AppColors.goldDark),
          SizedBox(width: _p(8)),
          Text('Quick actions', style: AppFonts.body(size: _p(16), weight: FontWeight.w800, color: AppColors.ink)),
        ]),
        SizedBox(height: _p(10)),
        if (acts.isEmpty)
          Text('Your role has no shortcut screens.', style: _subStyle)
        else
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < 4; i++) ...[
              if (i > 0) SizedBox(width: _p(12)),
              Expanded(
                child: i < acts.length
                    ? _QuickButton(
                        label: acts[i].label,
                        icon: acts[i].icon,
                        color: acts[i].color,
                        k: _k,
                        onTap: () => widget.onNavigate?.call(acts[i].menu),
                      )
                    : const SizedBox(),
              ),
            ],
          ]),
      ]),
    );
  }

  // ── Row 4: charts ──────────────────────────────────────────────────────────
  Widget? _row4({required bool wide, required bool showChart, required bool showPie}) {
    if (!showChart && !showPie) return null;
    if (wide) {
      // Chart under columns 1-2, payment modes under 3-4 (below Quick actions).
      if (showChart && showPie) return _gridRow([(_chartPanel(), 2), (_modePanel(fill: true), 2)], stretchHeight: true);
      return showChart ? _chartPanel() : _modePanel(fill: true);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (showChart) SizedBox(height: _p(390), child: _chartPanel()),
      if (showChart && showPie) SizedBox(height: _gap),
      if (showPie) _modePanel(fill: false),
    ]);
  }

  Widget _panelHeader(String icon, String title, String sub) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _tile(icon, AppColors.primary),
        SizedBox(width: _p(14)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: _p(19), weight: FontWeight.w700, color: AppColors.ink)),
            SizedBox(height: _p(7)),
            Container(
              width: _p(28),
              height: 3,
              decoration: BoxDecoration(color: AppColors.orange, borderRadius: BorderRadius.circular(2)),
            ),
            SizedBox(height: _p(7)),
            Text(sub, style: AppFonts.body(size: _p(13.5), color: AppColors.ink2)),
          ]),
        ),
      ]);

  /// Always given a bounded height (the row, or a fixed box when stacked).
  Widget _chartPanel() => Container(
        padding: EdgeInsets.fromLTRB(_p(24), _p(22), _p(24), _p(18)),
        decoration: _dCard(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _panelHeader('chart', 'Collection Overview', 'Last 12 months'),
          SizedBox(height: _p(14)),
          Expanded(child: _heavyLoading ? const AppLoading(label: 'Loading…') : _barChart()),
        ]),
      );

  Widget _barChart() {
    final maxV = _monthly.fold<double>(0, (m, b) => math.max(m, b.value));
    if (maxV <= 0) {
      // Shrinks to the space the row leaves it rather than overflowing.
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: _p(420),
          child: AppUI.empty(
            title: 'No collection recorded yet',
            why: 'Reconciled receipts from the last 12 months will appear here.',
            icon: 'receipt-2',
          ),
        ),
      );
    }
    final step = _niceStep(maxV / 3);
    return CustomPaint(
      painter: _BarPainter(
        values: [for (final b in _monthly) b.value],
        months: [for (final b in _monthly) b.label.split(' ').first],
        top: step * 3,
        step: step,
        k: _k,
      ),
      child: const SizedBox.expand(),
    );
  }

  /// [fill]: the panel has a bounded height (beside the chart) and centres
  /// the donut in it; stacked under the chart it takes its own height.
  Widget _modePanel({required bool fill}) {
    final body = _heavyLoading ? SizedBox(height: _p(190), child: const AppLoading(label: 'Loading…')) : _methodPie();
    return Container(
      padding: EdgeInsets.fromLTRB(_p(24), _p(22), _p(24), _p(18)),
      decoration: _dCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          _panelHeader('chart-2', 'Collection by Mode', 'This year, reconciled payments'),
          if (fill)
            Expanded(child: Center(child: body))
          else
            Padding(padding: EdgeInsets.symmetric(vertical: _p(20)), child: body),
        ],
      ),
    );
  }

  /// Cash teal, Online marigold (the spec); other modes keep the chart palette.
  Color _modeColor(String m) => switch (m) {
        'Cash' => AppColors.primary,
        'Online' => AppColors.gold,
        _ => _methodColor(m),
      };

  Widget _methodPie() {
    if (_byMethod.isEmpty) {
      // Shrinks to the space the panel leaves it rather than overflowing.
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: _p(380),
          child: AppUI.empty(
            title: 'No collection yet',
            why: 'Reconciled payments will appear here.',
            icon: 'grid-1',
          ),
        ),
      );
    }
    final total = _byMethod.fold<double>(0, (s, e) => s + e.value);
    final slices = [for (final e in _byMethod) _Slice(e.key, e.value, _modeColor(e.key))];
    final d = _p(190);
    return Row(children: [
      SizedBox(
        width: d,
        height: d,
        child: Stack(alignment: Alignment.center, children: [
          CustomPaint(size: Size(d, d), painter: _DonutPainter(slices, total, stroke: _p(24))),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: _p(30)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('TOTAL',
                  style: AppFonts.body(
                      size: _p(11), weight: FontWeight.w800, color: AppColors.ink3, letterSpacing: 0.07 * _p(11))),
              SizedBox(height: _p(2)),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(_inr(total),
                    maxLines: 1, style: AppFonts.body(size: _p(25), weight: FontWeight.w800, color: AppColors.ink)),
              ),
            ]),
          ),
        ]),
      ),
      SizedBox(width: _p(34)),
      // More than three modes (a college: Cash, Online, DD/Cheque, Card,
      // UPI...) use one-line rows; the list scrolls if it still does not fit.
      Expanded(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < slices.length; i++) ...[
              if (i > 0) SizedBox(height: _p(slices.length > 3 ? 8 : 12)),
              slices.length > 3 ? _legendRowCompact(slices[i], total) : _legendRow(slices[i], total),
            ],
          ]),
        ),
      ),
    ]);
  }

  Widget _legendRowCompact(_Slice s, double total) => Container(
        padding: EdgeInsets.symmetric(horizontal: _p(12), vertical: _p(7)),
        decoration: BoxDecoration(
          color: Color.alphaBlend(s.color.withValues(alpha: 0.07), AppColors.card),
          borderRadius: BorderRadius.circular(_p(10)),
          border: Border.all(color: Color.alphaBlend(s.color.withValues(alpha: 0.18), AppColors.line)),
        ),
        child: Row(children: [
          Container(
            width: _p(10),
            height: _p(10),
            decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(_p(3))),
          ),
          SizedBox(width: _p(8)),
          Expanded(
            child: Text(s.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: _p(13), weight: FontWeight.w600, color: AppColors.ink)),
          ),
          SizedBox(width: _p(6)),
          Text(_inrFull(s.value), style: AppFonts.body(size: _p(12), color: AppColors.ink2)),
          SizedBox(width: _p(10)),
          Text('${(total <= 0 ? 0 : s.value / total * 100).toStringAsFixed(0)}%',
              style: AppFonts.body(size: _p(13), weight: FontWeight.w800, color: AppColors.ink)),
        ]),
      );

  Widget _legendRow(_Slice s, double total) => Container(
        padding: EdgeInsets.symmetric(horizontal: _p(14), vertical: _p(11)),
        decoration: BoxDecoration(
          color: Color.alphaBlend(s.color.withValues(alpha: 0.07), AppColors.card),
          borderRadius: BorderRadius.circular(_p(12)),
          border: Border.all(color: Color.alphaBlend(s.color.withValues(alpha: 0.18), AppColors.line)),
        ),
        child: Row(children: [
          Container(
            width: _p(12),
            height: _p(12),
            decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(_p(4))),
          ),
          SizedBox(width: _p(10)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(s.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(size: _p(15), weight: FontWeight.w600, color: AppColors.ink)),
              Text(_inrFull(s.value), style: AppFonts.body(size: _p(12), color: AppColors.ink2)),
            ]),
          ),
          Text('${(total <= 0 ? 0 : s.value / total * 100).toStringAsFixed(0)}%',
              style: AppFonts.body(size: _p(15), weight: FontWeight.w800, color: AppColors.ink)),
        ]),
      );

  /// How many active students sit in a PROMOTIONAL, TERMINAL or COMPLETED
  /// class.
  ///
  /// Two steps on purpose. Counting per class would be one query per class —
  /// a hundred of them — and fetching the students to group them locally hits
  /// the PostgREST 1000-row cap, which on this data would silently lose more
  /// than half of them. So: read the ~100 class rows, then ONE count per type
  /// with the class names as an IN filter.
  ///
  /// Matched on stuclass, not cla_id: a student imported before the masters
  /// existed carries only the name, and leaving those out would understate
  /// every bucket.
  Future<Map<String, int>> _loadByClassType() async {
    try {
      final classes = await SupabaseService.fromSchema('class')
          .select('claname, classtype')
          .eq('ins_id', _insId)
          .eq('activestatus', 1);

      final names = <String, List<String>>{};
      for (final c in (classes as List)) {
        final type = (c['classtype'] ?? '').toString().trim();
        final name = (c['claname'] ?? '').toString().trim();
        if (type.isEmpty || name.isEmpty) continue;
        names.putIfAbsent(type, () => <String>[]).add(name);
      }
      if (names.isEmpty) return const {};

      final out = <String, int>{};
      for (final e in names.entries) {
        out[e.key] = await SupabaseService.fromSchema('students')
            .count()
            .eq('ins_id', _insId)
            .eq('activestatus', 1)
            .eq('preadmission', 0)
            .inFilter('stuclass', e.value);
      }
      return out;
    } catch (e) {
      // No classtype column on this database yet. Not an error worth showing:
      // the card falls back to its plain subtitle.
      debugPrint('class-type split unavailable: $e');
      return const {};
    }
  }

  /// Drill-down for the Today Collection card: split today's total into fee,
  /// miscellaneous and advance collection, plus the fine.
  void _showTodayBreakdown() {
    final total = _collectedToday + _miscToday + _advanceToday + _fineToday;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 420.w),
          child: Padding(
            padding: EdgeInsets.all(22.w),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                AppUI.iconTile('calendar-1', color: AppColors.today),
                SizedBox(width: 12.w),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text("Today's Collection", style: _titleStyle),
                  Text(formatDmy(DateTime.now()), style: AppUI.muted),
                ])),
              ]),
              SizedBox(height: 18.h),
              _breakdownRow('money-recive', AppColors.success, 'Fee Collection', _collectedToday),
              Divider(height: 20.h, color: AppColors.divider),
              _breakdownRow('receipt-2', AppColors.accent, 'Miscellaneous Collection', _miscToday),
              _breakdownRow('empty-wallet-add', AppColors.success, 'Advance Collection', _advanceToday),
              Divider(height: 20.h, color: AppColors.divider),
              // Fine is listed apart from Fee Collection, not folded into it.
              _breakdownRow('receipt-edit', AppColors.error, 'Fine', _fineToday),
              Divider(height: 20.h, color: AppColors.divider),
              _breakdownRow('calendar-1', AppColors.today, 'Total', total, bold: true),
              SizedBox(height: 20.h),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _breakdownRow(String icon, Color color, String label, double amount, {bool bold = false}) {
    return Row(children: [
      AppUI.iconTile(icon, color: color, size: 16),
      SizedBox(width: 10.w),
      Expanded(child: Text(label, style: bold ? AppUI.label.copyWith(fontWeight: FontWeight.w800) : AppUI.body)),
      Text(_inrFull(amount),
          textAlign: TextAlign.right,
          style: bold ? _money.copyWith(fontSize: 16.sp, fontWeight: FontWeight.w800, color: color) : _money),
    ]);
  }

  /// Splits demand / paid / outstanding into Regular vs Arrear from feedemand
  /// (demseqtype = 'ARREAR' → arrear). Fetched lazily, only when a card is
  /// tapped, so the dashboard's initial load isn't slowed. Totals tally with
  /// getFeeTotals (paid is the fee part only; fines are on the receipt lines).
  Future<Map<String, (double, double)>> _fetchRegArrSplit() async {
    // Fast path: server-side aggregation (get_fee_totals_by_seqtype migration).
    // Falls through to the client-side computation if the RPC isn't deployed.
    try {
      final r = await SupabaseService.client.rpc('get_fee_totals_by_seqtype', params: {'p_ins_id': _insId});
      if (r != null) {
        final m = Map<String, dynamic>.from(r as Map);
        double val(String type, String field) => ((m[type] as Map?)?[field] as num?)?.toDouble() ?? 0;
        return {
          'demand': (val('regular', 'demand'), val('arrear', 'demand')),
          'paid': (val('regular', 'paid'), val('arrear', 'paid')),
          'outstanding': (val('regular', 'pending'), val('arrear', 'pending')),
        };
      }
    } catch (_) {
      // RPC not deployed yet — compute client-side below.
    }

    // Pending-approval allocations per demand (from un-reconciled payments) so
    // Paid/Outstanding exclude un-realised amounts, exactly like get_fee_totals.
    final pendingByDem = <int, List<double>>{};
    try {
      final payRows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('payment')
          .select('pay_id')
          .eq('ins_id', _insId).eq('activestatus', 1)
          .eq('paystatus', 'C').eq('recon_status', 'P'));
      final payIds = List<Map<String, dynamic>>.from(payRows).map((r) => r['pay_id']).whereType<int>().toList();
      if (payIds.isNotEmpty) {
        final pdRows = await SupabaseService.fetchAll(() => SupabaseService
            .fromSchema('paymentdetails')
            .select('dem_id, transtotalamount, fineamount')
            .inFilter('pay_id', payIds));
        for (final r in List<Map<String, dynamic>>.from(pdRows)) {
          final dem = r['dem_id'];
          final amt = ((r['transtotalamount'] as num?)?.toDouble() ?? 0) - ((r['fineamount'] as num?)?.toDouble() ?? 0);
          if (dem is int) (pendingByDem[dem] ??= []).add(amt < 0 ? 0 : amt);
        }
      }
    } catch (_) {}

    double dR = 0, dA = 0, paidR = 0, paidA = 0, pendR = 0, pendA = 0;
    final rows = await SupabaseService.fetchAll(() => SupabaseService
        .fromSchema('feedemand')
        .select('dem_id, demseqtype, feeamount, paidamount, reconbalancedue')
        .eq('ins_id', _insId)
        .eq('activestatus', 1));
    for (final r in List<Map<String, dynamic>>.from(rows)) {
      final arr = (r['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
      final fee = (r['feeamount'] as num?)?.toDouble() ?? 0;
      final paid = (r['paidamount'] as num?)?.toDouble() ?? 0;
      final recBal = (r['reconbalancedue'] as num?)?.toDouble() ?? 0;
      // Fee part only, less this demand's un-reconciled fee allocations --
      // the same rule as get_fee_totals_by_seqtype.
      double pending = 0;
      final dem = r['dem_id'];
      if (dem is int && pendingByDem.containsKey(dem)) {
        for (final amt in pendingByDem[dem]!) {
          pending += amt;
        }
      }
      final reconciledPaid = (paid < fee ? paid : fee) - pending;
      if (arr) { dA += fee; paidA += reconciledPaid; pendA += recBal; }
      else { dR += fee; paidR += reconciledPaid; pendR += recBal; }
    }
    return {
      'demand': (dR, dA),
      'paid': (paidR < 0 ? 0.0 : paidR, paidA < 0 ? 0.0 : paidA),
      'outstanding': (pendR, pendA),
    };
  }

  /// Regular vs Arrear drill-down for the Fees Due / Collected / Outstanding
  /// cards. [metric] is 'demand' | 'paid' | 'outstanding'.
  void _showRegArrBreakdown(String metric, String title, Color color, String icon) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 420.w),
          child: Padding(
            padding: EdgeInsets.all(22.w),
            child: FutureBuilder<Map<String, (double, double)>>(
              future: _regArrFuture ??= _fetchRegArrSplit(),
              builder: (c, snap) {
                final head = Row(children: [
                  AppUI.iconTile(icon, color: color),
                  SizedBox(width: 12.w),
                  Expanded(child: Text(title, style: _titleStyle)),
                ]);
                if (!snap.hasData) {
                  return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    head,
                    SizedBox(height: 20.h),
                    SizedBox(height: 120.h, child: const AppLoading(label: 'Loading split…')),
                  ]);
                }
                final (reg, arr) = snap.data![metric]!;
                final total = reg + arr;
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  head,
                  SizedBox(height: 18.h),
                  _breakdownRow('receipt-2', color, 'Regular', reg),
                  Divider(height: 20.h, color: AppColors.divider),
                  _breakdownRow('receipt-edit', color, 'Arrear', arr),
                  // Regular / Arrear paid are fee only (the fine is already left
                  // out), so they add up to the Collected card as they are.
                  Divider(height: 20.h, color: AppColors.divider),
                  _breakdownRow(icon, color, metric == 'paid' ? 'Collection (Excluding Fine)' : 'Total', total, bold: true),
                  if (metric == 'paid' && _fine > 0) ...[
                    SizedBox(height: 8.h),
                    Text('Fine of ${_inrFull(_fine)} is shown on its own card, not in this total.', style: AppUI.muted),
                  ],
                  SizedBox(height: 20.h),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }

}

// ── palette + helper types ───────────────────────────────────────────────────

class _Bar {
  final String label;
  final double value;
  _Bar(this.label, this.value);
}

/// One number card in row 2.
class _Num {
  final String icon, label, value, sub;
  final Color color;
  final VoidCallback? onTap;
  _Num(this.icon, this.color, this.label, this.value, this.sub, this.onTap);
}

class _QuickAction {
  final String label, icon, menu;
  final Color color;
  _QuickAction(this.label, this.icon, this.color, this.menu);
}

/// A quick-action button: paper, line border; teal tint on hover.
class _QuickButton extends StatefulWidget {
  const _QuickButton({required this.label, required this.icon, required this.color, required this.k, required this.onTap});
  final String label, icon;
  final Color color;
  final double k;
  final VoidCallback onTap;

  @override
  State<_QuickButton> createState() => _QuickButtonState();
}

class _QuickButtonState extends State<_QuickButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final k = widget.k;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.symmetric(horizontal: 12 * k, vertical: 10 * k),
          decoration: BoxDecoration(
            color: _hover ? AppColors.primaryTint : AppColors.paper,
            borderRadius: BorderRadius.circular(12 * k),
            border: Border.all(color: _hover ? AppColors.primaryLine : AppColors.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 36 * k,
              height: 36 * k,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Color.alphaBlend(widget.color.withValues(alpha: 0.13), AppColors.card),
                borderRadius: BorderRadius.circular(10 * k),
              ),
              child: AppIcon.linear(widget.icon, size: 18 * k, color: widget.color == AppColors.gold ? AppColors.goldDark : widget.color),
            ),
            SizedBox(height: 8 * k),
            Text(widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: 14 * k, weight: FontWeight.w700, color: AppColors.ink)),
          ]),
        ),
      ),
    );
  }
}

/// Compact rupee formatting (₹1.55Cr / ₹61.6L / ₹25K) for tight spots like
/// the chart's value chip.
String _compactInr(double v) {
  if (v >= 1e7) return '₹${(v / 1e7).toStringAsFixed(2)}Cr';
  if (v >= 1e5) return '₹${(v / 1e5).toStringAsFixed(2)}L';
  if (v >= 1e3) return '₹${(v / 1e3).toStringAsFixed(1)}K';
  return '₹${v.toStringAsFixed(0)}';
}

/// Axis labels: ₹1.5L, ₹1L, ₹50K, 0.
String _axisInr(double v) {
  String trim(double x) => x.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
  if (v <= 0) return '0';
  if (v >= 1e7) return '₹${trim(v / 1e7)}Cr';
  if (v >= 1e5) return '₹${trim(v / 1e5)}L';
  if (v >= 1e3) return '₹${trim(v / 1e3)}K';
  return '₹${v.toStringAsFixed(0)}';
}

/// A round gridline step at least [raw]: 1, 2, 2.5 or 5 x a power of ten.
double _niceStep(double raw) {
  if (raw <= 0) return 1;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (m * mag >= raw) return m * mag;
  }
  return 10 * mag;
}

/// Collection Overview: a y-axis, dashed gridlines, one bar per month on a
/// full-height track, marigold-to-orange bars, a value chip over the current
/// (last) month and its label in orange ink.
class _BarPainter extends CustomPainter {
  final List<double> values;
  final List<String> months;
  final double top, step, k;
  _BarPainter({required this.values, required this.months, required this.top, required this.step, required this.k});

  TextPainter _text(String s, TextStyle st) =>
      TextPainter(text: TextSpan(text: s, style: st), textDirection: TextDirection.ltr)..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || top <= 0) return;
    final axisW = 50 * k;
    final labelH = 26 * k;
    final chipH = 28 * k;
    final plotTop = chipH;
    final plotBottom = size.height - labelH;
    final plotH = plotBottom - plotTop;
    if (plotH <= 0) return;
    final left = axisW;
    final plotW = size.width - left;

    // gridlines + y labels
    final axisStyle = AppFonts.body(size: 11.5 * k, weight: FontWeight.w600, color: AppColors.ink3);
    final line = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = plotBottom - plotH * i / 3;
      if (i == 0) {
        canvas.drawLine(Offset(left, y), Offset(size.width, y), line);
      } else {
        for (var x = left; x < size.width; x += 7) {
          canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, size.width), y), line);
        }
      }
      final tp = _text(_axisInr(step * i), axisStyle);
      tp.paint(canvas, Offset(axisW - 10 * k - tp.width, y - tp.height / 2));
    }

    final n = values.length;
    final gap = 22 * k;
    final barW = math.max(4.0, (plotW - gap * (n - 1)) / n);
    final radii = (Radius.circular(8 * k), Radius.circular(3 * k));
    for (var i = 0; i < n; i++) {
      final x = left + i * (barW + gap);
      final current = i == n - 1;
      // full-height track
      canvas.drawRRect(
        RRect.fromRectAndCorners(Rect.fromLTWH(x, plotTop, barW, plotH),
            topLeft: radii.$1, topRight: radii.$1, bottomLeft: radii.$2, bottomRight: radii.$2),
        Paint()..color = AppColors.chartTrack,
      );
      final v = values[i];
      final bh = (v / top).clamp(0.0, 1.0) * plotH;
      if (bh > 0) {
        final r = Rect.fromLTWH(x, plotBottom - bh, barW, bh);
        canvas.drawRRect(
          RRect.fromRectAndCorners(r, topLeft: radii.$1, topRight: radii.$1, bottomLeft: radii.$2, bottomRight: radii.$2),
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.gold, AppColors.orange],
            ).createShader(r),
        );
      }
      // value chip over the current month
      if (current && v > 0) {
        final tp = _text(_compactInr(v), AppFonts.body(size: 11.5 * k, weight: FontWeight.w800, color: Colors.white));
        final w = tp.width + 14 * k, h = tp.height + 6 * k;
        final cx = (x + barW / 2 - w / 2).clamp(0.0, size.width - w);
        final cy = math.max(0.0, plotBottom - bh - h - 6 * k);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(cx, cy, w, h), Radius.circular(6 * k)),
            Paint()..color = AppColors.ink);
        tp.paint(canvas, Offset(cx + 7 * k, cy + 3 * k));
      }
      // month label
      if (i < months.length) {
        final tp = _text(
          months[i],
          AppFonts.body(
            size: 11.5 * k,
            weight: current ? FontWeight.w800 : FontWeight.w500,
            color: current ? AppColors.orangeInk : AppColors.ink3,
          ),
        );
        tp.paint(canvas, Offset(x + barW / 2 - tp.width / 2, plotBottom + 8 * k));
      }
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.values != values || old.top != top || old.k != k || old.months != months;
}

/// One wedge of the collection donut.
class _Slice {
  final String label;
  final double value;
  final Color color;
  _Slice(this.label, this.value, this.color);
}

/// Donut on a light track, wedges a few pixels apart.
class _DonutPainter extends CustomPainter {
  final List<_Slice> slices;
  final double total, stroke;
  _DonutPainter(this.slices, this.total, {required this.stroke});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(rect, 0, 2 * math.pi, false, Paint()
      ..color = AppColors.chartTrack
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke);
    if (total <= 0) return;
    final gap = slices.length > 1 ? 3 / (rect.width / 2) : 0.0; // ~3px
    var start = -math.pi / 2; // 12 o'clock
    for (final s in slices) {
      final sweep = s.value / total * 2 * math.pi;
      canvas.drawArc(rect, start + gap / 2, math.max(0.0, sweep - gap), false, Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.slices != slices || old.total != total || old.stroke != stroke;
}

/// The Today's collection ticket: rounded card with half-circle notches cut
/// along the bottom edge, like a torn receipt.
class _TicketClipper extends CustomClipper<Path> {
  const _TicketClipper({required this.radius, required this.notch, required this.pitch});
  final double radius, notch, pitch;

  @override
  Path getClip(Size size) {
    final body = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    final holes = Path();
    for (var x = pitch / 2; x < size.width; x += pitch) {
      holes.addOval(Rect.fromCircle(center: Offset(x, size.height), radius: notch));
    }
    return Path.combine(PathOperation.difference, body, holes);
  }

  @override
  bool shouldReclip(_TicketClipper old) => old.radius != radius || old.notch != notch || old.pitch != pitch;
}

/// A dashed horizontal rule.
class _DashedHLine extends CustomPainter {
  final Color color;
  final double width;
  const _DashedHLine(this.color, [this.width = 1]);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width;
    final y = size.height / 2;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, size.width), y), paint);
    }
  }

  @override
  bool shouldRepaint(_DashedHLine old) => old.color != color || old.width != width;
}
