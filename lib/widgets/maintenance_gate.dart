import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/app_theme.dart';
import '../services/maintenance_service.dart';

/// Wraps the whole app and, when the hosted maintenance flag is on, covers
/// everything with an opaque "Under Maintenance" screen so no user can read or
/// write while the live database is being worked on.
///
/// It checks on launch, on a periodic poll (so users already inside the app are
/// gated within ~[_pollInterval] of the flag being flipped), and whenever the
/// window is resumed. The check is fail-open (see [MaintenanceService]).
class MaintenanceGate extends StatefulWidget {
  final Widget child;
  const MaintenanceGate({super.key, required this.child});

  @override
  State<MaintenanceGate> createState() => _MaintenanceGateState();
}

class _MaintenanceGateState extends State<MaintenanceGate>
    with WidgetsBindingObserver {
  static const Duration _pollInterval = Duration(seconds: 90);

  MaintenanceStatus _status = MaintenanceStatus.off;
  bool _checking = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
    _timer = Timer.periodic(_pollInterval, (_) => _check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final s = await MaintenanceService.check();
      if (!mounted) return;
      if (!s.sameAs(_status)) {
        setState(() => _status = s);
      }
    } finally {
      _checking = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_status.active)
          Positioned.fill(
            child: _MaintenanceScreen(
              status: _status,
              onRetry: _check,
            ),
          ),
      ],
    );
  }
}

class _MaintenanceScreen extends StatefulWidget {
  final MaintenanceStatus status;
  final Future<void> Function() onRetry;
  const _MaintenanceScreen({required this.status, required this.onRetry});

  @override
  State<_MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<_MaintenanceScreen>
    with SingleTickerProviderStateMixin {
  // Slow continuous rotation of the gear — reads as "work in progress".
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 8))
        ..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return maintenanceScreenBody(context, widget.status, _spin);
  }
}

// ── Shared maintenance visual (identical across desktop / mobile / web) ──────

const Color _mAccent = AppColors.gold; // marigold accents
const Color _mAccentStrong = AppColors.goldMuted;

/// Builds the maintenance card. Kept as a top-level function so the exact same
/// layout can be pasted into each app (they can't share a Dart library).
Widget maintenanceScreenBody(
    BuildContext context, MaintenanceStatus status, Animation<double> spin) {
  final title =
      status.title.trim().isEmpty ? 'Server Maintenance' : status.title.trim();
  final message = status.message.trim().isEmpty
      ? 'We are currently performing scheduled maintenance to improve system '
          'performance and reliability.\nThe system will be back online shortly.\n'
          'Thank you for your patience and understanding.'
      : status.message.trim();
  final time = status.time.trim();
  final duration = status.duration.trim();
  final notice = status.notice.trim();
  final hasInfo = time.isNotEmpty || duration.isNotEmpty;
  final hasNotice = notice.isNotEmpty;

  return Material(
    color: AppColors.sideBg, // opaque base — hides the app behind it
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.35),
          radius: 1.1,
          colors: [AppColors.primary, AppColors.primaryDark],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Container(
              padding: const EdgeInsets.fromLTRB(40, 44, 40, 40),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.035),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 48,
                    offset: const Offset(0, 24),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _maintenanceIllustration(spin),
                  const SizedBox(height: 26),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _titleDivider(),
                  const SizedBox(height: 20),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: 15,
                      height: 1.6,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (hasInfo) ...[
                    const SizedBox(height: 26),
                    _hLine(),
                    const SizedBox(height: 18),
                    if (time.isNotEmpty)
                      _infoRow(Icons.calendar_month_rounded,
                          'Maintenance Time', time),
                    if (time.isNotEmpty && duration.isNotEmpty)
                      const SizedBox(height: 6),
                    if (duration.isNotEmpty)
                      _infoRow(Icons.access_time_rounded, 'Expected Duration',
                          duration),
                  ],
                  if (hasNotice) ...[
                    SizedBox(height: hasInfo ? 20 : 26),
                    _hLine(),
                    const SizedBox(height: 18),
                    _noticeBanner(notice),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Server + gear illustration with a soft glow and a few decorative sparkles.
Widget _maintenanceIllustration(Animation<double> spin) {
  Widget dot(double s) => Container(
        width: s,
        height: s,
        decoration: const BoxDecoration(
            shape: BoxShape.circle, color: _mAccent),
      );
  return SizedBox(
    width: 168,
    height: 150,
    child: Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // Soft radial glow behind the server.
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [AppColors.gold.withValues(alpha: 0.33), AppColors.primaryDark.withValues(alpha: 0)],
            ),
          ),
        ),
        Icon(Icons.dns_rounded,
            size: 66, color: Colors.white.withValues(alpha: 0.88)),
        // Gear overlapping the bottom-right, slowly rotating.
        Positioned(
          right: 36,
          bottom: 24,
          child: RotationTransition(
            turns: spin,
            child: const Icon(Icons.settings,
                size: 34, color: AppColors.onPrimaryMuted),
          ),
        ),
        // Decorative sparkles.
        Positioned(left: 34, top: 60, child: dot(6)),
        const Positioned(
            left: 54, top: 40, child: Icon(Icons.add, size: 12, color: _mAccent)),
        const Positioned(
            right: 40, top: 44, child: Icon(Icons.add, size: 13, color: _mAccent)),
        Positioned(right: 38, top: 84, child: dot(6)),
        Positioned(left: 46, bottom: 40, child: dot(4)),
      ],
    ),
  );
}

/// Small centred divider under the title (line · dot · line).
Widget _titleDivider() {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
          width: 30,
          height: 2,
          decoration: BoxDecoration(
              color: _mAccentStrong.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 8),
      Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
              shape: BoxShape.circle, color: _mAccentStrong)),
      const SizedBox(width: 8),
      Container(
          width: 30,
          height: 2,
          decoration: BoxDecoration(
              color: _mAccentStrong.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(2))),
    ],
  );
}

Widget _hLine() =>
    Container(height: 1, color: Colors.white.withValues(alpha: 0.10));

/// One "icon | label | value" info row.
Widget _infoRow(IconData icon, String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, color: _mAccent, size: 22),
        const SizedBox(width: 14),
        SizedBox(
          width: 150,
          child: Text(label,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.60),
                  fontSize: 14,
                  fontWeight: FontWeight.w500)),
        ),
        Container(
            width: 1, height: 34, color: Colors.white.withValues(alpha: 0.14)),
        const SizedBox(width: 16),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.4)),
        ),
      ],
    ),
  );
}

/// Bottom info banner.
Widget _noticeBanner(String notice) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Icon(Icons.info_outline_rounded, color: _mAccent, size: 24),
        const SizedBox(width: 14),
        Expanded(
          child: Text(notice,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 13.5,
                  height: 1.45,
                  fontWeight: FontWeight.w500)),
        ),
      ],
    ),
  );
}
