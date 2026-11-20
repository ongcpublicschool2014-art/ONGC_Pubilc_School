import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../utils/app_theme.dart';
import '../services/supabase_service.dart';
import 'app_icon.dart';
import 'app_ui.dart';

/// Day-wise and month-wise collection charts.
///
/// Self-loading: pulls the last 12 months of payments once and derives both
/// series from them, counting only reconciled ('R') payments so the figures
/// match the Fee Collection cards.
///
/// Used on the Dashboard in place of the old date-wise summary table.
class CollectionCharts extends StatefulWidget {
  final int insId;

  /// Days shown in the daily trend.
  final int days;

  /// Months shown in the month-wise breakdown.
  final int months;

  const CollectionCharts({
    super.key,
    required this.insId,
    this.days = 7,
    this.months = 12,
  });

  @override
  State<CollectionCharts> createState() => _CollectionChartsState();
}

class _CollectionChartsState extends State<CollectionCharts> {
  bool _loading = true;
  String? _error;
  List<_Bar> _daily = [];
  List<_Bar> _monthly = [];
  List<_Slice> _methods = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CollectionCharts old) {
    super.didUpdateWidget(old);
    if (old.insId != widget.insId) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final from = DateTime(now.year, now.month - (widget.months - 1), 1);
      final payments = await SupabaseService.getPaymentsByDateRange(
        widget.insId,
        fromDate: from,
        toDate: now,
      );

      final byDay = <String, double>{};
      final byMonth = <String, double>{};
      // Collection split by payment method. Unlike the trend/monthwise charts
      // (reconciled only), this counts ALL collected payments and tracks how
      // much of each method is still pending reconciliation — cash auto-
      // reconciles, so UPI/cheque/DD are what typically sit unreconciled.
      final byMethod = <String, double>{};
      final byMethodPending = <String, double>{};
      for (final p in payments) {
        final d = DateTime.tryParse(p['paydate']?.toString() ?? '');
        if (d == null) continue;
        final amt = (p['transtotalamount'] as num?)?.toDouble() ?? 0;
        final reconciled = (p['recon_status']?.toString() ?? 'P') == 'R';

        final method = _normMethod(p['paymethod']?.toString());
        byMethod[method] = (byMethod[method] ?? 0) + amt;
        if (!reconciled) byMethodPending[method] = (byMethodPending[method] ?? 0) + amt;

        // Only reconciled money counts toward the time-series charts.
        if (!reconciled) continue;
        byDay[_ymd(d)] = (byDay[_ymd(d)] ?? 0) + amt;
        final monKey = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        byMonth[monKey] = (byMonth[monKey] ?? 0) + amt;
      }

      // Method slices, largest first, coloured by reconciliation behaviour.
      final methods = byMethod.entries
          .map((e) => _Slice(e.key, e.value, byMethodPending[e.key] ?? 0))
          .where((s) => s.value > 0)
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      // Last N calendar days, including empty ones so the trend reads honestly.
      final daily = <_Bar>[];
      for (var i = widget.days - 1; i >= 0; i--) {
        final d = now.subtract(Duration(days: i));
        daily.add(_Bar('${d.day}/${d.month}', byDay[_ymd(d)] ?? 0));
      }

      // Last N months, most recent first.
      const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      final monthly = <_Bar>[];
      for (var i = 0; i < widget.months; i++) {
        final d = DateTime(now.year, now.month - i, 1);
        final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
        monthly.add(_Bar('${monthNames[d.month - 1]} ${d.year % 100}', byMonth[key] ?? 0));
      }

      if (!mounted) return;
      setState(() {
        _daily = daily;
        _monthly = monthly;
        _methods = methods;
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

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Collapse the many raw paymethod strings (upi / UPI / gpay / razorpay / dd…)
  /// into the handful of buckets the donut shows.
  String _normMethod(String? raw) {
    final m = (raw ?? '').trim().toLowerCase();
    if (m.isEmpty) return 'Other';
    if (m.contains('cash')) return 'Cash';
    if (m.contains('upi') || m.contains('gpay') || m.contains('phonepe') || m.contains('paytm') ||
        m.contains('razor') || m.contains('online') || m.contains('net')) return 'Online';
    if (m.contains('cheque') || m.contains('chq')) return 'Cheque';
    if (m.contains('dd') || m.contains('demand draft')) return 'DD';
    if (m.contains('card')) return 'Card';
    return 'Other';
  }

  /// Fixed hue per method so the slice, its legend dot, and any repeat render
  /// stay consistent. Cash = green (auto-reconciled); the rest lean toward the
  /// "needs reconciling" hues.
  Color _methodColor(String method) {
    switch (method) {
      case 'Cash':
        return AppColors.chart[0];
      case 'Online':
        return AppColors.chart[1];
      case 'Cheque':
        return AppColors.chart[3];
      case 'DD':
        return AppColors.chart[2];
      case 'Card':
        return AppColors.chart[4];
      default:
        return AppColors.ink3;
    }
  }

  /// Compact Indian-currency label: ₹1.25 Cr / ₹94.8 L / ₹7.5K / ₹500.
  String _inr(double v) {
    if (v >= 1e7) return '₹${(v / 1e7).toStringAsFixed(2)} Cr';
    if (v >= 1e5) return '₹${(v / 1e5).toStringAsFixed(2)} L';
    if (v >= 1e3) return '₹${(v / 1e3).toStringAsFixed(1)}K';
    return '₹${v.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(height: 260.h, child: const Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return SizedBox(
        height: 240.h,
        child: AppUI.empty(
          title: 'Could not load charts',
          why: 'The collection figures did not load. Check the connection and retry.',
          icon: 'info-circle',
          action: OutlinedButton(onPressed: _load, child: const Text('Retry')),
        ),
      );
    }

    return LayoutBuilder(builder: (context, c) {
      final trend = _chartCard(
        title: 'Collection Trend',
        subtitle: 'Last ${widget.days} days',
        icon: 'chart-1',
        action: IconButton(
          onPressed: _load,
          tooltip: 'Refresh',
          splashRadius: 18,
          icon: const AppIcon('refresh', size: 16, color: AppColors.textSecondary),
        ),
        child: _dailyChart(),
      );
      final month = _chartCard(
        title: 'Monthly Collection',
        subtitle: 'Last ${widget.months} months',
        icon: 'calendar-1',
        child: _monthlyChart(),
      );
      final methods = _chartCard(
        title: 'Collection by Mode',
        subtitle: 'Last ${widget.months} months',
        icon: 'wallet-money',
        child: _methodsChart(),
      );
      if (c.maxWidth <= 1000) {
        return Column(children: [
          trend,
          SizedBox(height: AppUI.gap),
          month,
          SizedBox(height: AppUI.gap),
          methods,
        ]);
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 3, child: trend),
            SizedBox(width: AppUI.gap),
            Expanded(flex: 2, child: month),
            SizedBox(width: AppUI.gap),
            Expanded(flex: 2, child: methods),
          ],
        ),
      );
    });
  }

  Widget _chartCard({
    required String title,
    required String subtitle,
    required String icon,
    required Widget child,
    Widget? action,
  }) {
    return Container(
      padding: EdgeInsets.all(AppUI.cardPad),
      decoration: AppUI.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppUI.cardHeader(icon: icon, title: title, subtitle: subtitle, trailing: [if (action != null) action]),
          SizedBox(height: 18.h),
          child,
        ],
      ),
    );
  }

  // ── daily vertical bars ───────────────────────────────────────────────────
  Widget _dailyChart() {
    final maxV = _daily.fold<double>(0, (m, b) => math.max(m, b.value));
    if (maxV <= 0) return _emptyChart('No collection in the last ${widget.days} days');
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
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        style: TextStyle(fontSize: 9.5.sp, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                    SizedBox(height: 4.h),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: (_daily[i].value / maxV).clamp(0.02, 1.0)),
                      duration: Duration(milliseconds: 500 + i * 60),
                      curve: Curves.easeOutCubic,
                      builder: (_, t, __) => Container(
                        height: 160.h * t,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [_barColor(i), _barColorDark(i)],
                          ),
                          borderRadius: BorderRadius.vertical(top: Radius.circular(6.r)),
                        ),
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
                      TweenAnimationBuilder<double>(
                        tween: Tween(
                          begin: 0,
                          end: (_monthly[i].value / maxV).clamp(_monthly[i].value > 0 ? 0.02 : 0.0, 1.0),
                        ),
                        duration: Duration(milliseconds: 500 + i * 40),
                        curve: Curves.easeOutCubic,
                        builder: (_, t, __) => FractionallySizedBox(
                          widthFactor: t,
                          child: Container(
                            height: 18.h,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: [_barColor(i), _barColorDark(i)]),
                              borderRadius: BorderRadius.circular(5.r),
                            ),
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

  // ── payment-method donut + legend ─────────────────────────────────────────
  Widget _methodsChart() {
    final total = _methods.fold<double>(0, (s, m) => s + m.value);
    if (total <= 0) return _emptyChart('No collection recorded yet');
    final pending = _methods.fold<double>(0, (s, m) => s + m.pending);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Donut with the total collected in the hole.
        Center(
          child: SizedBox(
            width: 150.w,
            height: 150.w,
            child: Stack(
              alignment: Alignment.center,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (_, t, __) => CustomPaint(
                    size: Size(150.w, 150.w),
                    painter: _DonutPainter(
                      slices: [for (final m in _methods) (m.value, _methodColor(m.label))],
                      sweepFraction: t,
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_inr(total),
                        style: TextStyle(fontSize: 16.sp, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                    Text('collected', style: TextStyle(fontSize: 10.sp, color: AppColors.textLight)),
                  ],
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: 14.h),
        // Legend: one row per method with its share, plus a pending note.
        for (final m in _methods) _methodLegendRow(m, total),
        if (pending > 0) ...[
          SizedBox(height: 8.h),
          Row(children: [
            Icon(Icons.info_outline, size: 13.sp, color: AppColors.warning),
            SizedBox(width: 6.w),
            Expanded(
              child: Text('${_inr(pending)} awaiting reconciliation',
                  style: TextStyle(fontSize: 10.5.sp, color: AppColors.warning, fontWeight: FontWeight.w600)),
            ),
          ]),
        ],
      ],
    );
  }

  Widget _methodLegendRow(_Slice m, double total) {
    final pct = total <= 0 ? 0.0 : (m.value / total * 100);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 3.h),
      child: Row(children: [
        Container(width: 10.w, height: 10.w, decoration: BoxDecoration(color: _methodColor(m.label), borderRadius: BorderRadius.circular(3.r))),
        SizedBox(width: 8.w),
        Expanded(
          child: Row(children: [
            Text(m.label, style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            SizedBox(width: 6.w),
            if (m.pending > 0)
              Text('• ${_inr(m.pending)} pending',
                  style: TextStyle(fontSize: 10.sp, color: AppColors.warning, fontWeight: FontWeight.w600)),
          ]),
        ),
        Text('${pct.toStringAsFixed(0)}%', style: TextStyle(fontSize: 11.sp, color: AppColors.textLight, fontWeight: FontWeight.w600)),
        SizedBox(width: 8.w),
        SizedBox(
          width: 60.w,
          child: Text(_inr(m.value), textAlign: TextAlign.right, style: TextStyle(fontSize: 11.5.sp, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        ),
      ]),
    );
  }

  Widget _emptyChart(String msg) => SizedBox(
        height: 220.h,
        child: AppUI.empty(
          title: msg,
          why: 'Reconciled receipts will chart here once fees are collected.',
          icon: 'chart-1',
        ),
      );
}

/// Draws a donut from [slices] (value, colour). [sweepFraction] animates the
/// arc from 0→1. A rounded gap separates adjacent slices.
class _DonutPainter extends CustomPainter {
  final List<(double, Color)> slices;
  final double sweepFraction;
  _DonutPainter({required this.slices, required this.sweepFraction});

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<double>(0, (s, e) => s + e.$1);
    if (total <= 0) return;
    final stroke = size.width * 0.16;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (size.width - stroke) / 2,
    );
    // Track ring.
    canvas.drawArc(rect, 0, 2 * math.pi, false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = stroke..color = AppColors.divider);

    const gap = 0.04; // radians between slices
    var start = -math.pi / 2;
    for (final (value, color) in slices) {
      final full = (value / total) * (2 * math.pi);
      final sweep = (full - gap).clamp(0.0, 2 * math.pi) * sweepFraction;
      if (sweep <= 0) {
        start += full;
        continue;
      }
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke
          ..color = color,
      );
      start += full;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.sweepFraction != sweepFraction || old.slices != slices;
}

/// Cohesive categorical palette for chart bars — distinct hues that still sit
/// in the app's cool, blue-anchored family. Cycled per bar so each reads apart.
const List<Color> _barPalette = AppColors.chart; // Peacock series order

Color _barColor(int i) => _barPalette[i % _barPalette.length];
Color _barColorDark(int i) => Color.lerp(_barColor(i), Colors.black, 0.18)!;

class _Bar {
  final String label;
  final double value;
  _Bar(this.label, this.value);
}

/// One payment-method slice: total collected + how much is still unreconciled.
class _Slice {
  final String label;
  final double value;
  final double pending;
  _Slice(this.label, this.value, this.pending);
}
