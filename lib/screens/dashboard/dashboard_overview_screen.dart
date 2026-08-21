import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/auth_provider.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_icon.dart';

/// Dashboard overview — the fee pulse of the institution at a glance:
///   * four KPI cards (Total Demand / Collected / Overdue / Pending) with ring
///     gauges showing each as a share of the total demand,
///   * a daily Collection Trend for the last 7 days,
///   * a month-wise collection breakdown for the last 12 months.
///
/// All figures are institution-scoped and count only reconciled ('R') payments
/// toward collection, matching the Fee Collection screen's definition.
class DashboardOverviewScreen extends StatefulWidget {
  const DashboardOverviewScreen({super.key});

  @override
  State<DashboardOverviewScreen> createState() => _DashboardOverviewScreenState();
}

class _DashboardOverviewScreenState extends State<DashboardOverviewScreen> {
  bool _loading = true;
  String? _error;

  double _demand = 0, _collected = 0, _pending = 0, _overdue = 0;
  List<_Bar> _daily = [];
  List<_Bar> _monthly = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  int get _insId => context.read<AuthProvider>().insId ?? 1;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final yearStart = DateTime(now.year - 1, now.month, 1);
      final results = await Future.wait<dynamic>([
        SupabaseService.getFeeTotals(_insId),
        _fetchTrendByDay(yearStart, now),
        _fetchOverdue(now),
      ]);

      final totals = results[0] as Map<String, double>;
      final byDay = results[1] as Map<String, double>;
      final overdue = results[2] as double;

      // Roll the per-day totals up into per-month totals for the 12-month trend.
      final byMonth = <String, double>{};
      byDay.forEach((dayKey, amt) {
        final monKey = dayKey.length >= 7 ? dayKey.substring(0, 7) : dayKey; // 'YYYY-MM'
        byMonth[monKey] = (byMonth[monKey] ?? 0) + amt;
      });

      // Last 7 calendar days (including empty days so the trend reads honestly).
      final daily = <_Bar>[];
      for (var i = 6; i >= 0; i--) {
        final d = now.subtract(Duration(days: i));
        daily.add(_Bar('${d.day}/${d.month}', byDay[_ymd(d)] ?? 0));
      }

      // Last 12 months, most recent first.
      const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final monthly = <_Bar>[];
      for (var i = 0; i < 12; i++) {
        final d = DateTime(now.year, now.month - i, 1);
        final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        monthly.add(_Bar('${monthNames[d.month - 1]} ${d.year % 100}', byMonth[key] ?? 0));
      }

      if (!mounted) return;
      setState(() {
        _demand = totals['totalDemand'] ?? 0;
        _collected = totals['totalPaid'] ?? 0;
        _pending = totals['totalPending'] ?? 0;
        _overdue = overdue;
        _daily = daily;
        _monthly = monthly;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Reconciled collection grouped by day for [from]..[to]. Prefers the
  /// server-side aggregate RPC (a few hundred rows) and falls back to pulling
  /// every payment and bucketing in Dart if the RPC isn't deployed.
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
      // Fallback: old payments-based bucketing (RPC missing / errored).
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

  /// Outstanding balance that is already past its due date. Prefers the
  /// server-side SUM RPC; falls back to paging feedemand and summing in Dart.
  Future<double> _fetchOverdue(DateTime now) async {
    try {
      final r = await SupabaseService.client.rpc('get_overdue_total', params: {'p_ins_id': _insId});
      if (r != null) return (r as num).toDouble();
    } catch (_) {
      // fall through to the legacy fetchAll below
    }
    try {
      // Paged: institution-wide, so well past PostgREST's 1000-row cap.
      final rows = await SupabaseService.fetchAll(() => SupabaseService
          .fromSchema('feedemand')
          .select('balancedue, duedate')
          .eq('ins_id', _insId)
          .eq('activestatus', 1)
          .gt('balancedue', 0)
          .lt('duedate', _ymd(now)));
      double sum = 0;
      for (final r in (rows as List)) {
        sum += (r['balancedue'] as num?)?.toDouble() ?? 0;
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Compact Indian-currency label: ₹1.25 Cr / ₹94.8 L / ₹7.5K / ₹500.
  String _inr(double v) {
    if (v >= 1e7) return '₹${(v / 1e7).toStringAsFixed(2)} Cr';
    if (v >= 1e5) return '₹${(v / 1e5).toStringAsFixed(2)} L';
    if (v >= 1e3) return '₹${(v / 1e3).toStringAsFixed(1)}K';
    return '₹${v.toStringAsFixed(0)}';
  }

  double _pct(double part) => _demand <= 0 ? 0 : (part / _demand * 100).clamp(0, 100);

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Could not load dashboard', style: TextStyle(fontSize: 14.sp, color: AppColors.error, fontWeight: FontWeight.w600)),
          SizedBox(height: 8.h),
          OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 16), label: const Text('Retry')),
        ]),
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
            _kpiRow(),
            SizedBox(height: 16.h),
            LayoutBuilder(builder: (context, c) {
              final twoCol = c.maxWidth > 1000;
              final trend = _chartCard(
                title: 'Collection Trend',
                subtitle: 'last 7 days',
                icon: 'chart-1',
                child: _dailyChart(),
              );
              final month = _chartCard(
                title: 'Monthwise Collection',
                subtitle: 'last 12 months',
                icon: 'calendar-1',
                child: _monthlyChart(),
              );
              if (!twoCol) {
                return Column(children: [trend, SizedBox(height: 16.h), month]);
              }
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: trend),
                    SizedBox(width: 16.w),
                    Expanded(flex: 2, child: month),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  // ── KPI cards ─────────────────────────────────────────────────────────────
  Widget _kpiRow() {
    final cards = [
      _KpiData('Total Demand', _demand, 100, AppColors.primary, 'wallet-money'),
      _KpiData('Fee Collected', _collected, _pct(_collected), AppColors.success, 'money-recive'),
      _KpiData('Overdue Amount', _overdue, _pct(_overdue), AppColors.warning, 'money-time'),
      _KpiData('Overall Pending', _pending, _pct(_pending), AppColors.error, 'money-remove'),
    ];
    return LayoutBuilder(builder: (context, c) {
      // 4-up on wide, 2-up otherwise.
      final perRow = c.maxWidth > 900 ? 4 : 2;
      final gap = 16.w;
      final cardW = (c.maxWidth - gap * (perRow - 1)) / perRow;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final k in cards) SizedBox(width: cardW, child: _kpiCard(k))],
      );
    });
  }

  Widget _kpiCard(_KpiData k) {
    final darker = Color.lerp(k.color, Colors.black, 0.20)!;
    const onTile = Colors.white;
    return Container(
      padding: EdgeInsets.all(18.w),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [k.color, darker],
        ),
        borderRadius: BorderRadius.circular(14.r),
        boxShadow: [
          BoxShadow(color: k.color.withValues(alpha: 0.30), offset: const Offset(0, 8), blurRadius: 20, spreadRadius: -6),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: EdgeInsets.all(7.w),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(8.r)),
                    child: AppIcon(k.icon, size: 16, color: onTile),
                  ),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text(k.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.92))),
                  ),
                ]),
                SizedBox(height: 14.h),
                Text(_inr(k.value),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 22.sp, fontWeight: FontWeight.w800, color: onTile)),
              ],
            ),
          ),
          SizedBox(width: 10.w),
          SizedBox(
            width: 58.w,
            height: 58.w,
            child: CustomPaint(
              painter: _RingPainter(percent: k.percent, color: onTile, track: Colors.white.withValues(alpha: 0.28)),
              child: Center(
                child: Text('${k.percent.round()}%',
                    style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w800, color: onTile)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── chart card shell ──────────────────────────────────────────────────────
  Widget _chartCard({required String title, required String subtitle, required String icon, required Widget child}) {
    return Container(
      padding: EdgeInsets.all(18.w),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: AppColors.border),
        boxShadow: const [
          BoxShadow(color: Color.fromRGBO(16, 24, 40, 0.04), offset: Offset(0, 1), blurRadius: 2),
          BoxShadow(color: Color.fromRGBO(16, 24, 40, 0.05), offset: Offset(0, 8), blurRadius: 20, spreadRadius: -6),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            AppIcon(icon, size: 18, color: AppColors.primary),
            SizedBox(width: 8.w),
            Text(title, style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            SizedBox(width: 8.w),
            Text(subtitle, style: TextStyle(fontSize: 11.sp, color: AppColors.textLight)),
          ]),
          SizedBox(height: 18.h),
          child,
        ],
      ),
    );
  }

  // ── daily vertical bars ───────────────────────────────────────────────────
  Widget _dailyChart() {
    final maxV = _daily.fold<double>(0, (m, b) => math.max(m, b.value));
    if (maxV <= 0) return _emptyChart('No collection in the last 7 days');
    return SizedBox(
      height: 220.h,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < _daily.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 5.w),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(_daily[i].value > 0 ? _inr(_daily[i].value) : '',
                        maxLines: 1, overflow: TextOverflow.visible,
                        style: TextStyle(fontSize: 9.5.sp, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                    SizedBox(height: 4.h),
                    Container(
                      height: (160.h) * (_daily[i].value / maxV).clamp(0.02, 1.0),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [_barColor(i), _barColorDark(i)],
                        ),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(6.r)),
                      ),
                    ),
                    SizedBox(height: 6.h),
                    Text(_daily[i].label, style: TextStyle(fontSize: 10.sp, color: AppColors.textLight)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── monthly horizontal bars ───────────────────────────────────────────────
  Widget _monthlyChart() {
    final maxV = _monthly.fold<double>(0, (m, b) => math.max(m, b.value));
    if (maxV <= 0) return _emptyChart('No collection recorded yet');
    return Column(
      children: [
        for (var i = 0; i < _monthly.length; i++)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 4.h),
            child: Row(
              children: [
                SizedBox(width: 52.w, child: Text(_monthly[i].label, style: TextStyle(fontSize: 11.sp, color: AppColors.textSecondary))),
                Expanded(
                  child: Stack(
                    children: [
                      Container(height: 18.h, decoration: BoxDecoration(color: AppColors.secondaryLight, borderRadius: BorderRadius.circular(5.r))),
                      FractionallySizedBox(
                        widthFactor: (_monthly[i].value / maxV).clamp(_monthly[i].value > 0 ? 0.02 : 0.0, 1.0),
                        child: Container(
                          height: 18.h,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [_barColor(i), _barColorDark(i)]),
                            borderRadius: BorderRadius.circular(5.r),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 10.w),
                SizedBox(
                  width: 64.w,
                  child: Text(_monthly[i].value > 0 ? _inr(_monthly[i].value) : '—',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _emptyChart(String msg) => SizedBox(
        height: 120.h,
        child: Center(child: Text(msg, style: TextStyle(fontSize: 13.sp, color: AppColors.textLight))),
      );
}

/// Cohesive categorical palette for chart bars — distinct hues that still sit
/// in the app's cool, blue-anchored family. Cycled per bar so each reads apart.
const List<Color> kBarPalette = [
  Color(0xFF2563EB), // royal blue
  Color(0xFF14B8A6), // teal
  Color(0xFF8B5CF6), // violet
  Color(0xFFF59E0B), // amber
  Color(0xFF22C55E), // emerald
  Color(0xFF0EA5E9), // sky
  Color(0xFFEC4899), // pink
  Color(0xFF6366F1), // indigo
];

Color _barColor(int i) => kBarPalette[i % kBarPalette.length];
Color _barColorDark(int i) => Color.lerp(_barColor(i), Colors.black, 0.18)!;

class _Bar {
  final String label;
  final double value;
  _Bar(this.label, this.value);
}

class _KpiData {
  final String label;
  final double value;
  final double percent;
  final Color color;
  final String icon;
  _KpiData(this.label, this.value, this.percent, this.color, this.icon);
}

/// A thick rounded ring showing [percent] of a full circle.
class _RingPainter extends CustomPainter {
  final double percent;
  final Color color;
  final Color track;
  _RingPainter({required this.percent, required this.color, required this.track});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.14;
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.width - stroke) / 2;

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(center, radius, trackPaint);

    final sweep = 2 * math.pi * (percent.clamp(0, 100) / 100);
    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, sweep, false, arcPaint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.percent != percent || old.color != color;
}
