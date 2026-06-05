import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:animate_do/animate_do.dart';
import '../../utils/app_routes.dart';
import '../../widgets/app_icon.dart';

class _TealPalette {
  static const Color deep = Color(0xFF002147);
  static const Color amber = Color(0xFFD2913C);
  static const Color amberPale = Color(0xFFF0D2A5);

  // Diagonal three-stop gradient (matches the welcome panel) so the bg
  // reads as a gradient rather than a flat navy.
  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF1E3A6B),
      Color(0xFF002147),
      Color(0xFF000A1A),
    ],
    stops: [0.0, 0.55, 1.0],
  );

  static const LinearGradient buttonGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE5A85C), Color(0xFFB5752A)],
  );
}

class _ModuleCard {
  final String label;
  final String icon;
  final Color tint;
  final List<String> previewLabels;
  const _ModuleCard({
    required this.label,
    required this.icon,
    required this.tint,
    required this.previewLabels,
  });
}

class _OnboardingPage {
  final String pill;
  final String title;
  final String subtitle;
  final List<_ModuleCard> modules;
  const _OnboardingPage({
    required this.pill,
    required this.title,
    required this.subtitle,
    required this.modules,
  });
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Continuous left→right wave animation that breathes life into the bg.
  late final AnimationController _waveController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  )..repeat();

  // Three thematic onboarding pages, each with five project modules.
  static const List<_OnboardingPage> _pages = [
    _OnboardingPage(
      pill: 'Welcome to EduCore360',
      title: 'Building blocks for institution\nadministration.',
      subtitle:
          'Manage students, fees, staff, and reporting from one secure\ndashboard. Designed for principals, accountants, and admin teams.',
      modules: [
        _ModuleCard(
          label: 'Students',
          icon: 'profile-2user',
          tint: Color(0xFF6FB3FF),
          previewLabels: ['Roll', 'Section', 'Year'],
        ),
        _ModuleCard(
          label: 'Fee Collection',
          icon: 'wallet-1',
          tint: Color(0xFFE5A85C),
          previewLabels: ['Term I', 'Term II', 'Paid'],
        ),
        _ModuleCard(
          label: 'Reports',
          icon: 'chart-2',
          tint: Color(0xFF8BD4B5),
          previewLabels: ['Daily', 'Pending', 'Ledger'],
        ),
        _ModuleCard(
          label: 'Notices',
          icon: 'notification',
          tint: Color(0xFFEC7D8E),
          previewLabels: ['Exam', 'Holiday', 'Fee'],
        ),
        _ModuleCard(
          label: 'Staff',
          icon: 'teacher',
          tint: Color(0xFFB89BE8),
          previewLabels: ['Roles', 'Duty', 'Leave'],
        ),
      ],
    ),
    _OnboardingPage(
      pill: 'Run your finances',
      title: 'Every rupee, tracked.\nNo demand left behind.',
      subtitle:
          'Raise demands, collect at the counter, reconcile with bank statements,\nand see who still owes what — across courses and academic years.',
      modules: [
        _ModuleCard(
          label: 'Fee Demand',
          icon: 'wallet-1',
          tint: Color(0xFFE5A85C),
          previewLabels: ['Standard', 'Term', 'Due'],
        ),
        _ModuleCard(
          label: 'Counter',
          icon: 'tick-circle',
          tint: Color(0xFF8BD4B5),
          previewLabels: ['Cash', 'UPI', 'Receipt'],
        ),
        _ModuleCard(
          label: 'Bank Recon',
          icon: 'bank',
          tint: Color(0xFF6FB3FF),
          previewLabels: ['Match', 'Auto', 'Diff'],
        ),
        _ModuleCard(
          label: 'Approvals',
          icon: 'timer',
          tint: Color(0xFFB89BE8),
          previewLabels: ['Pending', 'Today', 'Verify'],
        ),
        _ModuleCard(
          label: 'Pending',
          icon: 'clock',
          tint: Color(0xFFEC7D8E),
          previewLabels: ['Standard', 'Section', 'Total'],
        ),
      ],
    ),
    _OnboardingPage(
      pill: 'Decide with data',
      title: 'Reports that answer the\nquestions principals ask.',
      subtitle:
          'Daily collection, course-wise demand, ledgers and consolidated\nstatus — exported as Excel or PDF in two clicks.',
      modules: [
        _ModuleCard(
          label: 'Daily',
          icon: 'calendar-1',
          tint: Color(0xFF8BD4B5),
          previewLabels: ['Today', 'Mode', 'Total'],
        ),
        _ModuleCard(
          label: 'Ledger',
          icon: 'book-1',
          tint: Color(0xFF6FB3FF),
          previewLabels: ['Roll', 'Term', 'Bal'],
        ),
        _ModuleCard(
          label: 'Pending',
          icon: 'clock',
          tint: Color(0xFFEC7D8E),
          previewLabels: ['Section', 'Days', 'Owed'],
        ),
        _ModuleCard(
          label: 'Consolidated',
          icon: 'chart-2',
          tint: Color(0xFFE5A85C),
          previewLabels: ['Standard', 'Net', 'Paid'],
        ),
        _ModuleCard(
          label: 'Settings',
          icon: 'setting-2',
          tint: Color(0xFFB89BE8),
          previewLabels: ['Roles', 'Fines', 'Year'],
        ),
      ],
    ),
  ];

  @override
  void dispose() {
    _waveController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _finish();
    }
  }

  void _finish() {
    Navigator.pushReplacementNamed(context, AppRoutes.welcome);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 900;

    return Scaffold(
      backgroundColor: _TealPalette.deep,
      body: Container(
        decoration: const BoxDecoration(
          gradient: _TealPalette.backgroundGradient,
        ),
        child: Stack(
          children: [
            // Soft glows in opposite corners.
            Positioned(
              top: -120,
              right: -120,
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _TealPalette.amber.withValues(alpha: 0.07),
                ),
              ),
            ),
            Positioned(
              bottom: -100,
              left: -100,
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _TealPalette.amberPale.withValues(alpha: 0.05),
                ),
              ),
            ),

            // Ripple-grid: dots arranged on a 40 px lattice, brightened by
            // two slow ripple sources drifting across the screen. The ring
            // of bright dots propagating outward from each source feels
            // calm and distinctive — sonar through a quiet pond.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _waveController,
                  builder: (_, __) => CustomPaint(
                    painter: _RippleGridPainter(_waveController.value),
                  ),
                ),
              ),
            ),

            SafeArea(
              child: Column(
                children: [
                  _topBar(isDesktop),
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: _pages.length,
                      onPageChanged: (i) => setState(() => _currentPage = i),
                      itemBuilder: (context, index) =>
                          _pageBody(_pages[index], isDesktop),
                    ),
                  ),
                  _bottomBar(isDesktop),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(bool isDesktop) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 64 : 24,
        vertical: 22,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 36,
                  height: 36,
                  color: Colors.white,
                  padding: const EdgeInsets.all(4),
                  child: Image.asset(
                    'assets/images/educore360_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.school_rounded,
                      color: _TealPalette.amber,
                      size: 20,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'EduCore360',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _finish,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 5, 5, 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Skip Tour',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFFE5A85C),
                            Color(0xFFB5752A),
                          ],
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                _TealPalette.amber.withValues(alpha: 0.50),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.keyboard_double_arrow_right_rounded,
                        color: Colors.white,
                        size: 18,
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

  Widget _pageBody(_OnboardingPage page, bool isDesktop) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: isDesktop ? 64 : 20,
          vertical: 12,
        ),
        child: Column(
          children: [
            FadeInDown(
              key: ValueKey('pill-${page.pill}'),
              duration: const Duration(milliseconds: 450),
              child: _heroPill(page.pill),
            ),
            const SizedBox(height: 24),
            FadeInUp(
              key: ValueKey('title-${page.pill}'),
              duration: const Duration(milliseconds: 450),
              child: Text(
                page.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                  letterSpacing: -0.6,
                ),
              ),
            ),
            const SizedBox(height: 14),
            FadeInUp(
              key: ValueKey('sub-${page.pill}'),
              delay: const Duration(milliseconds: 80),
              duration: const Duration(milliseconds: 450),
              child: Text(
                page.subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 14.5,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 36),
            FadeInUp(
              key: ValueKey('grid-${page.pill}'),
              delay: const Duration(milliseconds: 160),
              duration: const Duration(milliseconds: 500),
              child: _moduleGrid(page.modules, isDesktop),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: _TealPalette.amber,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _moduleGrid(List<_ModuleCard> modules, bool isDesktop) {
    if (isDesktop) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < modules.length; i++) ...[
            _moduleCard(modules[i], i),
            if (i != modules.length - 1) const SizedBox(width: 14),
          ],
        ],
      );
    }
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < modules.length; i++)
          SizedBox(
            width: 150,
            child: _moduleCard(modules[i], i, mobile: true),
          ),
      ],
    );
  }

  Widget _moduleCard(_ModuleCard m, int index, {bool mobile = false}) {
    final width = mobile ? 158.0 : 192.0;
    final height = mobile ? 226.0 : 256.0;
    final isOdd = index.isOdd;
    return Transform.translate(
      offset: Offset(0, (isOdd ? 12 : -12).toDouble()),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: m.tint.withValues(alpha: 0.30),
            width: 1,
          ),
          // Subtle glow: soft halo + gentle drop.
          boxShadow: [
            BoxShadow(
              color: m.tint.withValues(alpha: 0.18),
              blurRadius: 10,
              spreadRadius: 0,
              offset: const Offset(0, 0),
            ),
            BoxShadow(
              color: m.tint.withValues(alpha: 0.08),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 22,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: Stack(
            children: [
              // Subtle tint wash in the top-right (very low opacity on white).
              Positioned(
                top: -60,
                right: -60,
                child: Container(
                  width: 170,
                  height: 170,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        m.tint.withValues(alpha: 0.16),
                        m.tint.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: -50,
                left: -50,
                child: Container(
                  width: 130,
                  height: 130,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        m.tint.withValues(alpha: 0.10),
                        m.tint.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                m.tint,
                                Color.lerp(m.tint, Colors.black, 0.18) ??
                                    m.tint,
                              ],
                            ),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: m.tint.withValues(alpha: 0.55),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child:
                              AppIcon(m.icon, size: 24, color: Colors.white),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: m.tint.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: m.tint.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Text(
                            '0${index + 1}',
                            style: TextStyle(
                              color: m.tint,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      m.label,
                      style: const TextStyle(
                        color: _TealPalette.deep,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Module preview',
                      style: TextStyle(
                        color: _TealPalette.deep.withValues(alpha: 0.50),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const Spacer(),
                    // Tint hairline separator.
                    Container(
                      height: 1,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            m.tint.withValues(alpha: 0.0),
                            m.tint.withValues(alpha: 0.35),
                            m.tint.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final lbl in m.previewLabels)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 5),
                            decoration: BoxDecoration(
                              color: m.tint.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: m.tint.withValues(alpha: 0.40),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              lbl,
                              style: const TextStyle(
                                color: _TealPalette.deep,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.1,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(bool isDesktop) {
    final isLast = _currentPage == _pages.length - 1;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 64 : 24,
        vertical: 22,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: List.generate(_pages.length, (i) {
              final active = _currentPage == i;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                margin: const EdgeInsets.only(right: 8),
                height: 6,
                width: active ? 28 : 6,
                decoration: BoxDecoration(
                  color: active
                      ? _TealPalette.amber
                      : Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _next,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                padding: EdgeInsets.symmetric(
                  horizontal: isLast ? 32 : 24,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  gradient: _TealPalette.buttonGradient,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: _TealPalette.amber.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isLast ? 'Get Started' : 'Next',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.white,
                      size: 20,
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

/// One ripple source drifting across the screen.
class _RippleSource {
  final double startX; // 0..1
  final double startY;
  final double vx;
  final double vy;
  const _RippleSource(this.startX, this.startY, this.vx, this.vy);
}

/// A grid of dots brightened by travelling ripple waves.
///
/// • A 40-px dot lattice is the bg structure.
/// • Two ripple sources drift slowly across the screen; each source emits
///   a wave whose phase depends on distance and time.
/// • Each dot's alpha = base + amplitude × sin((distance − speed·t)/λ ·
///   2π), with a 1/(1+d/k) falloff so the ripples fade with distance.
/// The result reads as concentric rings of bright dots emanating from
/// each travelling source — calm, distinctive, organic.
class _RippleGridPainter extends CustomPainter {
  final double t; // 0..1, repeats forever
  _RippleGridPainter(this.t);

  static const Color _amber = Color(0xFFD2913C);

  static const double _step = 40;
  static const double _wavelength = 200;
  static const double _waveSpeedPx = 320; // ripple front travels per cycle

  static const List<_RippleSource> _sources = [
    _RippleSource(0.25, 0.30, 0.45, 0.18),
    _RippleSource(0.75, 0.70, -0.32, -0.42),
    _RippleSource(0.55, 0.10, -0.28, 0.50),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Resolve current ripple source positions (wrapped).
    final sources = <Offset>[];
    for (final s in _sources) {
      final nx = (((s.startX + s.vx * t) % 1.2) - 0.1) * size.width;
      final ny = (((s.startY + s.vy * t) % 1.2) - 0.1) * size.height;
      sources.add(Offset(nx, ny));
    }

    final reusablePaint = Paint();
    for (double y = _step / 2; y < size.height; y += _step) {
      for (double x = _step / 2; x < size.width; x += _step) {
        final pos = Offset(x, y);

        // Sum the ripple contributions from every source.
        double waveSum = 0;
        for (final src in sources) {
          final d = (pos - src).distance;
          final phase = ((d - t * _waveSpeedPx) / _wavelength) * 2 * math.pi;
          final falloff = 1 / (1 + d / 240);
          waveSum += math.sin(phase) * falloff;
        }
        // waveSum sits roughly in [-3, 3]; map to [0, 1] for alpha curve.
        final norm = (waveSum / 3 * 0.5 + 0.5).clamp(0.0, 1.0);
        final alpha = 0.06 + 0.40 * norm;

        // Larger dots where the ripple is strongest, so peaks read as
        // bright pulses rather than just colour shifts.
        final radius = 1.0 + 1.2 * norm;
        reusablePaint.color = _amber.withValues(alpha: alpha);
        canvas.drawCircle(pos, radius, reusablePaint);
      }
    }
  }

  @override
  bool shouldRepaint(_RippleGridPainter old) => old.t != t;
}
