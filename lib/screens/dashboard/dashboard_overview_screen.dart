import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/dashboard_tiles.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../models/payment_model.dart';
import '../../widgets/app_ui.dart';
import '../../widgets/empty_state.dart';
import '../fees/pending_approval_screen.dart';
import '../../utils/school_terms.dart';
import '../../utils/app_text.dart';

/// Dashboard overview — the institution's fee pulse at a glance. Redesigned as a
/// multi-panel overview: KPI row, a collection-over-time area chart, a
/// students-by-class donut, recent payments, quick actions and a today summary.
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
  int _txToday = 0, _admToday = 0;
  List<_Bar> _monthly = [];
  List<PaymentModel> _recent = [];
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
    // Upper bound for "today". DateTime rolls the month/year over for us.
    final tomorrowYmd = _ymd(DateTime(now.year, now.month, now.day + 1));

    // WAVE 1 — cheap, fast queries. Render the dashboard as soon as these land
    // so the KPIs and recent payments show immediately instead of waiting on
    // the heavy year-wide aggregates below.
    try {
      final core = await Future.wait<dynamic>([
        SupabaseService.getFeeTotals(_insId),
        SupabaseService.getStudentCount(_insId),
        _recentIncludingMisc(limit: 6),
        _countOnDay('payment', 'paydate', todayYmd, tomorrowYmd),
        _countOnDay('students', 'stuadmdate', todayYmd, tomorrowYmd),
        // Misc receipts are transactions too -- counting only `payment` made
        // the Transactions figure disagree with the Transactions screen, which
        // lists both.
        _countOnDay('misc_collection', 'mcdate', todayYmd, tomorrowYmd),
      ]);
      final totals = core[0] as Map<String, double>;
      if (!mounted) return;
      setState(() {
        _demand = totals['totalDemand'] ?? 0;
        _collected = totals['totalPaid'] ?? 0;
        _pending = totals['totalPending'] ?? 0;
        _fine = totals['totalFine'] ?? 0;
        _students = core[1] as int;
        _recent = core[2] as List<PaymentModel>;
        _txToday = (core[3] as int) + (core[5] as int);
        _admToday = core[4] as int;
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

  /// The latest receipts across BOTH tables.
  ///
  /// getRecentPayments reads `payment` only, so a day of misc collections could
  /// leave the card showing older fee receipts while the newest money was misc.
  /// Each side is over-fetched a little, merged, then trimmed -- the newest
  /// [limit] overall, not the newest of each.
  Future<List<PaymentModel>> _recentIncludingMisc({int limit = 6}) async {
    final fee = await SupabaseService.getRecentPayments(_insId, limit: limit);
    try {
      final misc = await SupabaseService.fromSchema('misc_collection')
          .select('mc_id, mcno, mcdate, stu_id, stuname, paymode, totalamount, createdat')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          // By RECEIPT DATE, like the fee side. mc_id is insertion order, so
          // an imported or back-dated misc receipt outranked money taken the
          // same morning.
          .order('mcdate', ascending: false, nullsFirst: false)
          .order('mc_id', ascending: false)
          .limit(limit * 3);
      final rows = List<Map<String, dynamic>>.from(misc as List);
      final merged = <PaymentModel>[
        ...fee,
        for (final m in rows)
          PaymentModel(
            // Negative, like the Transactions screen does, so a misc mc_id can
            // never be mistaken for a pay_id by anything downstream.
            payId: -((m['mc_id'] as num?)?.toInt() ?? 0),
            paynumber: m['mcno']?.toString(),
            insId: _insId,
            stuId: (m['stu_id'] as num?)?.toInt(),
            transtotalamount: (m['totalamount'] as num?)?.toDouble() ?? 0,
            paydate: DateTime.tryParse(m['mcdate']?.toString() ?? ''),
            paystatus: 'C',
            paymethod: m['paymode']?.toString(),
            payreference: 'MISC',
            stuname: m['stuname']?.toString(),
            createdat: DateTime.tryParse(m['createdat']?.toString() ?? '') ??
                DateTime.tryParse(m['mcdate']?.toString() ?? '') ??
                DateTime.now(),
          ),
      ]..sort((a, b) =>
          (b.paydate ?? b.createdat).compareTo(a.paydate ?? a.createdat));
      return merged.take(limit).toList();
    } catch (e) {
      // Older database or a transient failure: fall back to fee receipts only
      // rather than emptying the card.
      debugPrint('recent misc unavailable: $e');
      return fee;
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
          .eq('paystatus', 'C').eq('recon_status', 'R')
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

  /// Small count of rows created on/after [ymd] (today) — used for the Today
  /// summary. Bounded to a single day so it stays light.
  /// Rows dated ON [ymd] -- at or after it, and strictly before [nextYmd].
  ///
  /// The upper bound is the point: a lower bound alone also counts rows dated in
  /// the FUTURE. Students are admitted with a later joining date all the time,
  /// so "New Admissions" was reporting every future-dated admission as today's
  /// (48 of them, spread over October to December, on a day with none).
  ///
  /// Works for a date column and a timestamp one alike: any time on [ymd] is
  /// still < [nextYmd] at midnight.
  Future<int> _countOnDay(
      String table, String dateCol, String ymd, String nextYmd) async {
    try {
      final rows = await SupabaseService.fromSchema(table)
          .select('ins_id')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .gte(dateCol, ymd)
          .lt(dateCol, nextYmd)
          .limit(2000);
      return (rows as List).length;
    } catch (_) {
      return 0;
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

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(4.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_showHero) ...[_hero(), SizedBox(height: AppUI.gap)],
            _kpiRow(),
            SizedBox(height: AppUI.gap),
            // Collection overview area chart (wide) + payment-methods pie.
            // Either chart can be withheld on its own. With one gone the other
            // takes the full width rather than leaving a hole where it was.
            if (_may('${kDashboardTilePrefix}chart_overview') ||
                _may('${kDashboardTilePrefix}chart_mode'))
              LayoutBuilder(builder: (context, c) {
                final showChart = _may('${kDashboardTilePrefix}chart_overview');
                final showPie = _may('${kDashboardTilePrefix}chart_mode');
                final chart = _panel(
                  icon: 'chart-1',
                  title: 'Collection Overview',
                  subtitle: 'Last 12 months',
                  child: _heavyLoading ? _chartLoading() : _barChart(),
                );
                final pie = _panel(
                  icon: 'grid-1',
                  title: 'Collection by Mode',
                  subtitle: 'This year, reconciled payments',
                  child: _heavyLoading ? _chartLoading() : _methodPie(),
                );
                if (!showPie) return chart;
                if (!showChart) return pie;
                if (c.maxWidth <= 1000) {
                  return Column(children: [chart, SizedBox(height: AppUI.gap), pie]);
                }
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 3, child: chart),
                  SizedBox(width: AppUI.gap),
                  Expanded(flex: 2, child: pie),
                ]);
              }),
            if (_may('${kDashboardTilePrefix}chart_overview') ||
                _may('${kDashboardTilePrefix}chart_mode'))
              SizedBox(height: AppUI.gap),
            // Row: recent payments (wide) + quick actions.
            if (_may('${kDashboardTilePrefix}recent') ||
                _may('${kDashboardTilePrefix}quickactions'))
              LayoutBuilder(builder: (context, c) {
                final showRecent = _may('${kDashboardTilePrefix}recent');
                final showActions = _may('${kDashboardTilePrefix}quickactions');
                final recent = _panel(
                  icon: 'receipt-2',
                  title: 'Recent Payments',
                  subtitle: 'Latest ${_recent.length}',
                  trailing: _viewAll('Transactions'),
                  child: _recentTable(),
                );
                final actions = _panel(icon: 'grid-1', title: 'Quick Actions', child: _quickActions());
                if (!showActions) return recent;
                if (!showRecent) return actions;
                if (c.maxWidth <= 1000) {
                  return Column(children: [recent, SizedBox(height: AppUI.gap), actions]);
                }
                return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 3, child: recent),
                  SizedBox(width: AppUI.gap),
                  Expanded(flex: 2, child: actions),
                ]);
              }),
            if (_may('${kDashboardTilePrefix}recent') ||
                _may('${kDashboardTilePrefix}quickactions'))
              SizedBox(height: AppUI.gap),
            if (_may('${kDashboardTilePrefix}todaysummary')) _todayRow(),
          ],
        ),
      ),
    );
  }

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

  // ── Hero: the one number that matters ─────────────────────────────────────
  /// Total fees due, split into collected / waived / outstanding. Shown when
  /// the role may see the demand figure; the KPI row then leaves those four
  /// out so nothing appears twice.
  bool get _showHero => _may('dash:demand');

  Widget _hero() {
    final parts = <(String, double, Color, String, VoidCallback?)>[
      if (_may('dash:collected'))
        ('Collected', _collected, AppColors.primary, 'money-recive',
            () => _showRegArrBreakdown('paid', 'Total Collected', AppColors.success, 'money-recive')),
      if (_may('dash:concession')) ('Waived (concession)', _concession, AppColors.info, 'discount-shape', null),
      if (_may('dash:outstanding'))
        ('Outstanding', _pending, AppColors.goldMuted, 'wallet-money',
            () => _showRegArrBreakdown('outstanding', 'Outstanding', AppColors.today, 'wallet-money')),
    ];
    final total = _demand <= 0 ? 1.0 : _demand;
    Widget legend((String, double, Color, String, VoidCallback?) p) {
      final waiting = p.$1.startsWith('Waived') && _heavyLoading;
      final body = Row(children: [
        AppUI.iconTile(p.$4, color: p.$3 == AppColors.goldMuted ? AppColors.goldDark : p.$3, size: 18),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            // 'Waived (concession)' stays the tuple value (checked above);
            // the legend shows the glossary word.
            Text((p.$1.startsWith('Waived') ? 'Concession' : p.$1).toUpperCase(), style: AppUI.caps, maxLines: 1, overflow: TextOverflow.ellipsis),
            SizedBox(height: 3.h),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(waiting ? '…' : _inrFull(p.$2),
                  maxLines: 1, style: AppFonts.heading(size: 21.sp)),
            ),
            SizedBox(height: 2.h),
            Text(waiting ? 'loading' : '${_pct(p.$2).toStringAsFixed(1)}% of fees due${p.$5 != null ? ' · click for details' : ''}',
                style: AppUI.muted, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]);
      return p.$5 == null
          ? body
          : InkWell(onTap: p.$5, borderRadius: BorderRadius.circular(AppUI.controlRadius), child: Padding(padding: EdgeInsets.all(4.w), child: body));
    }

    return Container(
      padding: EdgeInsets.all(AppUI.cardPad + 4.w),
      decoration: AppUI.card(),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 900;
        final headline = InkWell(
          onTap: () => _showRegArrBreakdown('demand', 'Total Fees Due', AppColors.demand, 'receipt-2'),
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          child: Padding(
            padding: EdgeInsets.all(4.w),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                AppUI.iconTile('receipt-2', color: AppColors.demand, size: 18),
                SizedBox(width: 10.w),
                Text('TOTAL FEES DUE', style: AppUI.caps),
              ]),
              SizedBox(height: 10.h),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(_inrFull(_demand),
                    maxLines: 1, style: AppFonts.heading(size: 42.sp, height: 1.1)),
              ),
              SizedBox(height: 4.h),
              Text('Regular + arrear · click for the split', style: AppUI.muted),
            ]),
          ),
        );
        // one bar, three shares (each part labelled below -- never colour alone)
        final bar = ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              for (final p in parts)
                if (p.$2 > 0) Expanded(flex: ((p.$2 / total) * 1000).round().clamp(1, 1000), child: Container(color: p.$3)),
              Expanded(
                flex: (1000 - parts.fold<double>(0, (a, p) => a + (p.$2 / total) * 1000)).round().clamp(0, 1000),
                child: Container(color: AppColors.track),
              ),
            ]),
          ),
        );
        final legends = [for (final p in parts) Expanded(child: legend(p))];
        final split = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          if (parts.isNotEmpty) bar,
          if (parts.isNotEmpty) SizedBox(height: 16.h),
          Row(children: [
            for (var i = 0; i < legends.length; i++) ...[if (i > 0) SizedBox(width: 12.w), legends[i]],
          ]),
        ]);
        if (!wide || parts.isEmpty) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            headline,
            if (parts.isNotEmpty) ...[SizedBox(height: 18.h), split],
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: c.maxWidth * 0.32, child: headline),
          Container(width: 1, height: 96.h, color: AppColors.divider, margin: EdgeInsets.symmetric(horizontal: 20.w)),
          Expanded(child: split),
        ]);
      }),
    );
  }

  // ── KPI cards (light, reference-style) ─────────────────────────────────────
  Widget _kpiRow() {
    // Wave-2 values show a placeholder until their heavier queries resolve.
    String hv(double v) => _heavyLoading ? '…' : _inrFull(v);
    final cards = [
      if (_may('dash:students'))
        _Kpi(
          'Total Students',
          // The regular body when the split is known; the plain active count
          // when it is not, rather than a misleading 0.
          _byClassType.isEmpty ? _students.toString() : _regularStudents.toString(),
          _byClassType.isEmpty
              ? 'Active students'
              : 'Promotional ${_byClassType['PROMOTIONAL'] ?? 0} · '
                  'Terminal ${_byClassType['TERMINAL'] ?? 0} · click for details',
          AppColors.primary,
          'people',
          onTap: _byClassType.isEmpty ? null : _showClassTypeBreakdown),
      if (!_showHero && _may('dash:demand')) _Kpi('Total Fees Due', _inrFull(_demand), 'Regular + arrear · click for the split', AppColors.demand, 'receipt-2',
          onTap: () => _showRegArrBreakdown('demand', 'Total Fees Due', AppColors.demand, 'receipt-2')),
      if (!_showHero && _may('dash:collected')) _Kpi('Total Collected', _inrFull(_collected), '${_pct(_collected).toStringAsFixed(1)}% collected · click for the split', AppColors.success, 'money-recive',
          onTap: () => _showRegArrBreakdown('paid', 'Total Collected', AppColors.success, 'money-recive')),
      if (_may('dash:misc')) _Kpi('Miscellaneous Collection', hv(_misc), 'Miscellaneous fees', AppColors.accent, 'receipt-2'),
      if (_may('dash:advance')) _Kpi('Advance Collection', hv(_advance), 'Held, not yet adjusted', AppColors.success, 'empty-wallet-add'),
      if (_may('dash:fine')) _Kpi('Fine Collected', _inrFull(_fine), 'Late-fee collected', AppColors.error, 'receipt-edit'),
      if (!_showHero && _may('dash:concession')) _Kpi('Concession', hv(_concession), 'Total waived', AppColors.info, 'discount-shape'),
      if (_may('dash:today')) _Kpi("Today's Collection", hv(_collectedToday + _miscToday + _advanceToday + _fineToday), _heavyLoading ? 'Reconciled today' : 'Fee + miscellaneous + advance + fine · click for the split', AppColors.today, 'calendar-1',
          onTap: _heavyLoading ? null : _showTodayBreakdown),
      if (_may('dash:pendingapproval')) _Kpi('Pending Approval', hv(_pendingApproval), 'Awaiting reconciliation · click to view', AppColors.warning, 'money-remove',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PendingApprovalScreen()))),
      if (!_showHero && _may('dash:outstanding')) _Kpi('Outstanding', _inrFull(_pending), '${_pct(_pending).toStringAsFixed(1)}% pending · click for the split', AppColors.today, 'wallet-money',
          onTap: () => _showRegArrBreakdown('outstanding', 'Outstanding', AppColors.today, 'wallet-money')),
    ];
    if (cards.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, c) {
      final gap = AppUI.gap;
      // Size cards by a minimum width so full values never clip, then cap the
      // per-row count so the cards divide evenly (9 cards → up to 5 per row for
      // a balanced 5+4, 8 → 4+4).
      final minW = 240.w;
      final cap = cards.length > 8 ? 5 : 4;
      int perRow = ((c.maxWidth + gap) / (minW + gap)).floor();
      perRow = perRow.clamp(1, cap);
      final cardW = (c.maxWidth - gap * (perRow - 1)) / perRow;
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final k in cards) SizedBox(width: cardW, child: _kpiCard(k)),
      ]);
    });
  }

  /// The full split, including the one the card has no room for.
  ///
  /// COMPLETED is the interesting number and the reason this is worth a tap:
  /// those students are in TC classes — they have left — yet they still count
  /// as active. On the restore of live that is 1,851 of them.
  void _showClassTypeBreakdown() {
    const order = ['PROMOTIONAL', 'TERMINAL', 'COMPLETED'];
    const label = {
      'PROMOTIONAL': 'Promotional',
      'TERMINAL': 'Terminal (final year)',
      'COMPLETED': 'Completed (TC class)',
    };
    const tint = {
      'PROMOTIONAL': AppColors.success,
      'TERMINAL': AppColors.warning,
      'COMPLETED': AppColors.error,
    };
    final known = order.fold<int>(0, (a, k) => a + (_byClassType[k] ?? 0));
    final other = _students - known;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(schoolTerm('Students by Class Type'), style: AppUI.cardTitle),
        content: SizedBox(
          width: 340.w,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final k in order)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 7.h),
                child: Row(children: [
                  Container(
                      width: 9.w,
                      height: 9.w,
                      decoration: BoxDecoration(
                          color: tint[k], shape: BoxShape.circle)),
                  SizedBox(width: 10.w),
                  Expanded(
                      child: Text(schoolTerm(label[k]!), style: AppUI.body)),
                  Text('${_byClassType[k] ?? 0}',
                      style: TextStyle(
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w800,
                          color: tint[k])),
                ]),
              ),
            if (other > 0) ...[
              const Divider(height: 18),
              Row(children: [
                Expanded(
                    child: Text(schoolTerm('Class not in the master'),
                        style: AppUI.muted)),
                Text('$other',
                    style: TextStyle(
                        fontSize: 13.sp,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary)),
              ]),
            ],
            const Divider(height: 18),
            // The card's own figure, and what it leaves out. Showing the
            // total active underneath is the point: it is nearly double, and
            // the difference is students who have left.
            Row(children: [
              Expanded(
                  child: Text('Regular students (on the card)',
                      style: TextStyle(
                          fontSize: 13.sp, fontWeight: FontWeight.w800))),
              Text('$_regularStudents',
                  style: TextStyle(
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary)),
            ]),
            SizedBox(height: 8.h),
            Row(children: [
              Expanded(
                  child: Text(schoolTerm('Total active, including TC classes'),
                      style: AppUI.muted)),
              Text('$_students',
                  style: TextStyle(
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
            ]),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _kpiCard(_Kpi k) {
    if (k.label == "Today's Collection") return _receiptCard(k);
    final action = k.label == 'Pending Approval';
    // Same anatomy as AppUI.kpi (icon tile, CAPS label, Playfair value, muted
    // sub) plus a tap chevron and a value that shrinks rather than clips.
    // Pending Approval is the gold "action needed" card.
    final card = Container(
      padding: EdgeInsets.all(16.w),
      decoration: action
          ? BoxDecoration(
              color: AppColors.goldTint,
              borderRadius: BorderRadius.circular(AppUI.cardRadius),
              border: Border.all(color: AppColors.goldLine),
            )
          : AppUI.card(),
      child: Row(children: [
        AppUI.iconTile(k.icon, color: k.color),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                child: Text(k.label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.caps),
              ),
              if (action) ...[AppUI.chip('Action', AppStatus.warning), SizedBox(width: 6.w)],
              if (k.onTap != null)
                Icon(Icons.chevron_right, size: 16.sp, color: AppColors.textLight),
            ]),
            SizedBox(height: 4.h),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(k.value, maxLines: 1, style: AppFonts.heading(size: 26.sp, height: 1.15)),
            ),
            SizedBox(height: 2.h),
            Text(k.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.muted),
          ]),
        ),
      ]),
    );
    if (k.onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: k.onTap, borderRadius: BorderRadius.circular(AppUI.cardRadius), child: card),
    );
  }

  /// Today's Collection as the Royal receipt: a solid maroon card with a
  /// dashed tear line, mono figures and a scalloped bottom edge.
  Widget _receiptCard(_Kpi k) {
    final card = ClipPath(
      clipper: const _ScallopClipper(),
      child: Container(
        padding: EdgeInsets.fromLTRB(16.w, 14.h, 16.w, 20.h),
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [AppColors.primary, AppColors.primaryDark]),
          borderRadius: BorderRadius.circular(AppUI.cardRadius),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: Text("TODAY'S COLLECTION · ${formatDmy(DateTime.now())}",
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: AppUI.caps.copyWith(color: AppColors.onPrimaryAccent)),
            ),
            if (k.onTap != null) Icon(Icons.chevron_right, size: 16.sp, color: AppColors.onPrimaryMuted),
          ]),
          SizedBox(height: 6.h),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(k.value, maxLines: 1, style: AppFonts.heading(size: 28.sp, color: AppColors.onPrimary, height: 1.1)),
          ),
          SizedBox(height: 8.h),
          // dashed tear line
          SizedBox(height: 1, width: double.infinity, child: CustomPaint(painter: _DashedHLine(AppColors.onPrimaryMuted.withValues(alpha: 0.6)))),
          SizedBox(height: 8.h),
          Text(k.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppFonts.mono(size: 11.5.sp, color: AppColors.onPrimaryMuted)),
        ]),
      ),
    );
    if (k.onTap == null) return card;
    return Material(color: Colors.transparent, child: InkWell(onTap: k.onTap, borderRadius: BorderRadius.circular(AppUI.cardRadius), child: card));
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
                  Text("Today's Collection", style: AppUI.cardTitle),
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
          style: bold ? AppUI.money.copyWith(fontSize: 16.sp, fontWeight: FontWeight.w800, color: color) : AppUI.money),
    ]);
  }

  /// Splits demand / paid / outstanding into Regular vs Arrear from feedemand
  /// (demseqtype = 'ARREAR' → arrear). Fetched lazily, only when a card is
  /// tapped, so the dashboard's initial load isn't slowed. Totals tally with
  /// getFeeTotals (paid is fee-only: paidamount − fine, like the KPI card).
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
            .select('dem_id, transtotalamount')
            .inFilter('pay_id', payIds));
        for (final r in List<Map<String, dynamic>>.from(pdRows)) {
          final dem = r['dem_id'];
          if (dem is int) (pendingByDem[dem] ??= []).add((r['transtotalamount'] as num?)?.toDouble() ?? 0);
        }
      }
    } catch (_) {}

    double dR = 0, dA = 0, paidR = 0, paidA = 0, pendR = 0, pendA = 0;
    final rows = await SupabaseService.fetchAll(() => SupabaseService
        .fromSchema('feedemand')
        .select('dem_id, demseqtype, feeamount, paidamount, reconbalancedue, fineamount')
        .eq('ins_id', _insId)
        .eq('activestatus', 1));
    for (final r in List<Map<String, dynamic>>.from(rows)) {
      final arr = (r['demseqtype']?.toString() ?? '').trim().toUpperCase() == 'ARREAR';
      final fee = (r['feeamount'] as num?)?.toDouble() ?? 0;
      final paid = (r['paidamount'] as num?)?.toDouble() ?? 0;
      final recBal = (r['reconbalancedue'] as num?)?.toDouble() ?? 0;
      final fine = (r['fineamount'] as num?)?.toDouble() ?? 0;
      // Subtract this demand's un-reconciled allocations (pending_fee+pending_fine).
      double pending = 0;
      final dem = r['dem_id'];
      if (dem is int && pendingByDem.containsKey(dem)) {
        for (final amt in pendingByDem[dem]!) {
          pending += (amt - fine).clamp(0, double.infinity); // pending_fee
          pending += amt < fine ? amt : fine; // pending_fine
        }
      }
      final reconciledPaid = paid - pending;
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
                  Expanded(child: Text(title, style: AppUI.cardTitle)),
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
                  // Collection drill-down only: the Regular/Arrear figures are
                  // SUM(paidamount), which carries the fine portion. Showing it
                  // on its own line, and netting it off the total, keeps this
                  // dialog agreeing with the Total Collected card -- which now
                  // reports fee collection only.
                  if (metric == 'paid') ...[
                    Divider(height: 20.h, color: AppColors.divider),
                    _breakdownRow('receipt-edit', AppColors.error, 'Less: Fine', _fine),
                  ],
                  Divider(height: 20.h, color: AppColors.divider),
                  _breakdownRow(icon, color, metric == 'paid' ? 'Collection (Excluding Fine)' : 'Total',
                      metric == 'paid' ? total - _fine : total,
                      bold: true),
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

  // ── Panel shell ────────────────────────────────────────────────────────────
  BoxDecoration _cardDecoration() => AppUI.card();

  Widget _panel({required String icon, required String title, String? subtitle, Widget? trailing, required Widget child}) {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: _cardDecoration(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppUI.cardHeader(icon: icon, title: title, subtitle: subtitle, trailing: [if (trailing != null) trailing]),
        SizedBox(height: 16.h),
        child,
      ]),
    );
  }

  /// "View all →" link that jumps to another sidebar screen, shown only when
  /// the user's role can actually open [menu].
  Widget? _viewAll(String menu) {
    final allowed = widget.allowedMenus;
    if (allowed != null && !allowed.contains(menu)) return null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onNavigate?.call(menu),
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8.w, vertical: 4.h),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('View All', style: AppUI.label.copyWith(color: AppColors.primary)),
            SizedBox(width: 4.w),
            Icon(Icons.arrow_forward, size: 14.sp, color: AppColors.primary),
          ]),
        ),
      ),
    );
  }

  // ── Collection overview: monthly bar chart ─────────────────────────────────
  Widget _barChart() {
    final maxV = _monthly.fold<double>(0, (m, b) => math.max(m, b.value));
    if (maxV <= 0) return _emptyMini('No collection recorded yet', 'Reconciled receipts from the last 12 months will appear here.');
    return SizedBox(
      height: 230.h,
      child: LayoutBuilder(builder: (context, c) {
        return CustomPaint(
          size: Size(c.maxWidth, 230.h),
          painter: _BarPainter(
            _monthly.map((b) => b.value).toList(),
            _monthly.map((b) => b.value > 0 ? _compactInr(b.value) : '').toList(),
            maxV,
            AppColors.primary,
          ),
          child: Padding(
            padding: EdgeInsets.only(top: 200.h),
            child: Row(children: [
              for (final b in _monthly)
                Expanded(child: Text(b.label.split(' ').first,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 9.5.sp, color: AppColors.textLight, fontWeight: FontWeight.w600))),
            ]),
          ),
        );
      }),
    );
  }

  /// Placeholder shown in the chart / pie panels while wave-2 aggregates load.
  Widget _chartLoading() => SizedBox(height: 230.h, child: const AppLoading(label: 'Loading…'));

  // ── Recent payments table ──────────────────────────────────────────────────
  Widget _recentTable() {
    if (_recent.isEmpty) return _emptyMini('No payments yet', 'Receipts appear here once fees are collected.');
    Widget head(String t, {int flex = 2, TextAlign align = TextAlign.left}) => AppUI.th(t, flex: flex, align: align);
    return Column(children: [
      Container(
        padding: EdgeInsets.symmetric(vertical: 10.h, horizontal: 8.w),
        decoration: AppUI.tableHeadBar.copyWith(borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          head('RECEIPT NO.', flex: 3),
          head('AMOUNT', flex: 2, align: TextAlign.right),
          head('DATE', flex: 2, align: TextAlign.right),
          head('MODE', flex: 2, align: TextAlign.center),
        ]),
      ),
      for (var i = 0; i < _recent.length; i++) _recentRow(_recent[i], i.isEven),
    ]);
  }

  Widget _recentRow(PaymentModel p, bool zebra) {
    final amt = p.transtotalamount;
    final date = p.paydate ?? p.createdat;
    final dStr = formatDmy(date);
    final mode = (p.paymethod ?? '-');
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
      padding: EdgeInsets.symmetric(vertical: 10.h, horizontal: 8.w),
      child: Row(children: [
        Expanded(flex: 3, child: Text(p.paynumber ?? '${p.payId}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: AppUI.cell.copyWith(fontWeight: FontWeight.w700, color: AppColors.primary))),
        Expanded(flex: 2, child: Text(_inr(amt), textAlign: TextAlign.right, style: AppUI.money)),
        Expanded(flex: 2, child: Text(dStr, textAlign: TextAlign.right,
            style: AppUI.cell.copyWith(color: AppColors.textSecondary))),
        Expanded(flex: 2, child: Align(alignment: Alignment.center, child: _modePill(mode))),
      ]),
    );
  }

  Widget _modePill(String mode) {
    final m = mode.toLowerCase();
    final status = m.contains('online') || m.contains('upi')
        ? AppStatus.success
        : m.contains('card')
            ? AppStatus.info
            : m.contains('cash')
                ? AppStatus.warning
                : AppStatus.neutral;
    return AppUI.chip(mode.isEmpty ? '-' : mode, status);
  }

  // ── Quick actions grid ─────────────────────────────────────────────────────
  Widget _quickActions() {
    final allowed = widget.allowedMenus;
    final actions = <_QuickAction>[
      _QuickAction('New Admission', 'user-add', AppColors.primary, 'Admission'),
      _QuickAction('Collect Fee', 'money-recive', AppColors.success, 'Fee Collection'),
      _QuickAction('Fee Demand', 'receipt-edit', AppColors.demand, 'Fee Demand'),
      _QuickAction('Miscellaneous Collection', 'receipt-2', AppColors.today, 'Misc Collection'),
      _QuickAction('Fee Refund', 'money-remove', AppColors.error, 'Fee Refund'),
      _QuickAction('Daily Collection', 'chart-1', AppColors.info, 'Daily Collection'),
    ].where((a) => allowed == null || allowed.contains(a.menu)).toList();
    if (actions.isEmpty) {
      return const EmptyState(icon: 'grid-1', title: 'No quick actions', subtitle: 'Your role has no shortcut screens.');
    }
    return LayoutBuilder(builder: (context, c) {
      const cols = 3;
      final gap = 10.w;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final a in actions) SizedBox(width: w, child: _quickTile(a)),
      ]);
    });
  }

  Widget _quickTile(_QuickAction a) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onNavigate?.call(a.menu),
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        child: Container(
          padding: EdgeInsets.symmetric(vertical: 14.h),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppUI.controlRadius),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Column(children: [
            AppUI.iconTile(a.icon, color: a.color, size: 18),
            SizedBox(height: 8.h),
            // Shrinks a long label (Miscellaneous Collection) instead of
            // cutting it off; tiles keep one height.
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 6.w),
              child: FittedBox(fit: BoxFit.scaleDown, child: Text(a.label, maxLines: 1, style: AppUI.label)),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Today's summary (full width) ───────────────────────────────────────────
  Widget _todayRow() {
    return _panel(
      icon: 'calendar-1',
      title: "Today's Summary",
      subtitle: formatDmy(DateTime.now()),
      child: Row(children: [
        // Fee + Misc, matching the Today Collection KPI above. Fine stays out
        // of it deliberately -- a penalty is not fee collection.
        Expanded(child: _miniStat('money-recive', AppColors.success, _inrFull(_collectedToday + _miscToday + _advanceToday), 'Collected Today')),
        _vDivider(),
        Expanded(child: _miniStat('receipt-2', AppColors.primary, '$_txToday', 'Transactions')),
        _vDivider(),
        Expanded(child: _miniStat('user-add', AppColors.today, '$_admToday', 'New Admissions')),
        _vDivider(),
        Expanded(child: _miniStat('clock', AppColors.warning, _inrFull(_pendingApproval), 'Pending Approval')),
      ]),
    );
  }

  // ── Collection-by-mode donut ───────────────────────────────────────────────
  Widget _methodPie() {
    if (_byMethod.isEmpty) {
      return SizedBox(
        height: 200.h,
        child: const EmptyState(icon: 'grid-1', title: 'No collection yet', subtitle: 'Reconciled payments will appear here.'),
      );
    }
    final total = _byMethod.fold<double>(0, (s, e) => s + e.value);
    final slices = [for (final e in _byMethod) _Slice(e.key, e.value, _methodColor(e.key))];
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.h),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(
          width: 150.w,
          height: 150.w,
          child: Stack(alignment: Alignment.center, children: [
            CustomPaint(size: Size(150.w, 150.w), painter: _DonutPainter(slices, total)),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Text('TOTAL', style: AppUI.caps),
              SizedBox(height: 2.h),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(_inr(total),
                    style: AppFonts.heading(size: 18.sp)),
              ),
            ]),
          ]),
        ),
        SizedBox(width: 18.w),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final s in slices)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 5.h),
                  child: Row(children: [
                    Container(width: 11.w, height: 11.w,
                        decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(3.r))),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: AppUI.body),
                    ),
                    Text('${(total <= 0 ? 0 : s.value / total * 100).toStringAsFixed(0)}%',
                        textAlign: TextAlign.right,
                        style: AppUI.money.copyWith(color: AppColors.textSecondary)),
                  ]),
                ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _miniStat(String icon, Color color, String value, String label) {
    return Column(children: [
      AppUI.iconTile(icon, color: color, size: 18),
      SizedBox(height: 8.h),
      Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: AppFonts.heading(size: 21.sp)),
      SizedBox(height: 2.h),
      Text(label.toUpperCase(), textAlign: TextAlign.center, style: AppUI.caps),
    ]);
  }

  Widget _vDivider() => Container(width: 1, height: 46.h, color: AppColors.divider, margin: EdgeInsets.symmetric(horizontal: 8.w));

  Widget _emptyMini(String msg, String why) => SizedBox(
        height: 230.h,
        child: AppUI.empty(title: msg, why: why, icon: 'receipt-2'),
      );
}

// ── palette + helper types ───────────────────────────────────────────────────

class _Bar {
  final String label;
  final double value;
  _Bar(this.label, this.value);
}

class _Kpi {
  final String label, value, sub, icon;
  final Color color;
  final VoidCallback? onTap;
  _Kpi(this.label, this.value, this.sub, this.color, this.icon, {this.onTap});
}

class _QuickAction {
  final String label, icon, menu;
  final Color color;
  _QuickAction(this.label, this.icon, this.color, this.menu);
}

/// Compact rupee formatting (₹1.55Cr / ₹61.6L / ₹25K) for tight spots like
/// the bar-chart value labels.
String _compactInr(double v) {
  if (v >= 1e7) return '₹${(v / 1e7).toStringAsFixed(2)}Cr';
  if (v >= 1e5) return '₹${(v / 1e5).toStringAsFixed(2)}L';
  if (v >= 1e3) return '₹${(v / 1e3).toStringAsFixed(1)}K';
  return '₹${v.toStringAsFixed(0)}';
}

/// Vertical bar chart of monthly collection (one rounded bar per month), with
/// the collection amount printed above each non-zero bar.
class _BarPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  final double maxV;
  final Color color;
  _BarPainter(this.values, this.labels, this.maxV, this.color);

  /// Royal: past months muted maroon, the current (last) month gold.
  Color barColor(int i) => i == values.length - 1 ? AppColors.gold : AppColors.primaryMuted;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || maxV <= 0) return;
    final h = size.height - 26; // leave room for month labels
    const topPad = 16.0; // headroom so value labels above the tallest bar fit

    // gridlines
    final grid = Paint()..color = AppColors.divider..strokeWidth = 1;
    for (var g = 0; g <= 3; g++) {
      final y = topPad + (h - topPad) * g / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final n = values.length;
    final slot = size.width / n;
    final barW = slot * 0.5;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      final bh = (v / maxV).clamp(0.0, 1.0) * (h - topPad);
      final left = i * slot + (slot - barW) / 2;
      final top = h - bh;
      // faint track behind each bar
      final track = RRect.fromRectAndRadius(Rect.fromLTWH(left, topPad, barW, h - topPad), const Radius.circular(5));
      canvas.drawRRect(track, Paint()..color = AppColors.track);
      if (bh <= 0) continue;
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, top, barW, bh),
        topLeft: const Radius.circular(5),
        topRight: const Radius.circular(5),
      );
      canvas.drawRRect(rect, Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
          barColor(i), barColor(i).withValues(alpha: 0.85),
        ]).createShader(Rect.fromLTWH(left, top, barW, bh)));

      // value label above the bar
      final label = i < labels.length ? labels[i] : '';
      if (label.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(text: label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: slot);
      final tx = left + barW / 2 - tp.width / 2;
      final ty = (top - tp.height - 3).clamp(0.0, h);
      tp.paint(canvas, Offset(tx, ty));
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.values != values || old.maxV != maxV || old.labels != labels;
}

/// One wedge of the collection donut.
class _Slice {
  final String label;
  final double value;
  final Color color;
  _Slice(this.label, this.value, this.color);
}

/// Donut chart for collection split by payment mode.
class _DonutPainter extends CustomPainter {
  final List<_Slice> slices;
  final double total;
  _DonutPainter(this.slices, this.total);

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final rect = Rect.fromLTWH(6, 6, size.width - 12, size.height - 12);
    final stroke = size.width * 0.20;
    var start = -1.5708; // -90° so the first slice starts at 12 o'clock
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
  bool shouldRepaint(_DonutPainter old) => old.slices != slices || old.total != total;
}

/// Scalloped (torn receipt) bottom edge for the Today's Collection card.
class _ScallopClipper extends CustomClipper<Path> {
  const _ScallopClipper();

  @override
  Path getClip(Size size) {
    const r = 5.0;
    final path = Path()..lineTo(0, size.height - r);
    var x = 0.0;
    while (x < size.width) {
      path.arcToPoint(Offset((x + 2 * r).clamp(0, size.width), size.height - r), radius: const Radius.circular(r), clockwise: false);
      x += 2 * r;
    }
    path
      ..lineTo(size.width, 0)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(_ScallopClipper oldClipper) => false;
}

/// A dashed horizontal rule.
class _DashedHLine extends CustomPainter {
  final Color color;
  const _DashedHLine(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, 0), Offset((x + 4).clamp(0, size.width), 0), paint);
    }
  }

  @override
  bool shouldRepaint(_DashedHLine old) => old.color != color;
}
