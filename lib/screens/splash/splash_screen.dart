import 'package:flutter/material.dart';
import 'package:animate_do/animate_do.dart';
import 'package:provider/provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/app_routes.dart';
import '../../utils/auth_provider.dart';
import '../../services/device_service.dart';
import '../../services/supabase_service.dart';
import '../../services/update_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _progressController;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..forward();

    _navigateToNextScreen();
  }

  Future<void> _navigateToNextScreen() async {
    await Future.delayed(const Duration(seconds: 4));
    if (!mounted) return;

    // No auto-login: closing the app ends the session, so every launch goes to
    // the login screen and asks for the password. This also clears any password
    // an older build had saved for auto-login.
    final auth = context.read<AuthProvider>();
    await auth.forgetSavedPassword();
    if (!mounted) return;

    // First-run gate: on a brand-new database there is no super-admin
    // account. Until one is created, route to the Super Admin
    // Registration screen. Once it exists, this is skipped forever.
    final saExists = await SupabaseService.client
        .rpc('super_admin_exists')
        .then((v) => v == true)
        .catchError((_) => true); // on error, don't block — fall through
    if (!mounted) return;
    if (!saExists) {
      Navigator.pushReplacementNamed(context, AppRoutes.superAdminRegistration);
      return;
    }

    // Device gate: any Windows PC must be activated once before login.
    // This is a one-time check against the local activation flag — once
    // a PC is activated it is never re-verified against the server.
    final activated = await DeviceService.isActivated();
    if (!mounted) return;
    if (!activated) {
      Navigator.pushReplacementNamed(context, AppRoutes.deviceActivation);
    } else {
      Navigator.pushReplacementNamed(context, AppRoutes.welcome);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Matches the sign-in screen: the school painting under a light wash,
    // the logo on a white tile with a marigold ring, the brand in Fraunces.
    return Scaffold(
      backgroundColor: AppColors.loginBg,
      body: Stack(fit: StackFit.expand, children: [
        Image.asset(
          'assets/images/login_bg.jpg',
          fit: BoxFit.cover,
          alignment: const Alignment(0, 0.3),
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
        ColoredBox(color: AppColors.loginBg.withValues(alpha: 0.78)),
        Column(
          children: [
            const Spacer(flex: 3),
            FadeInDown(
              duration: const Duration(milliseconds: 800),
              child: AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) => Container(
                  width: 168,
                  height: 168,
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(36),
                    border: Border.all(color: AppColors.gold, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryDark.withValues(alpha: 0.18 + _pulseController.value * 0.12),
                        blurRadius: 40,
                        spreadRadius: -6,
                        offset: const Offset(0, 18),
                      ),
                    ],
                  ),
                  child: child,
                ),
                child: Image.asset(
                  'assets/images/app_logo_mark.png',
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.school_rounded, size: 60, color: AppColors.primary),
                ),
              ),
            ),
            const SizedBox(height: 32),
            FadeInUp(
              delay: const Duration(milliseconds: 400),
              duration: const Duration(milliseconds: 800),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: 'FIT ',
                    style: AppFonts.heading(size: 56, weight: FontWeight.w700, color: AppColors.primaryDark, height: 1),
                  ),
                  TextSpan(
                    text: 'School',
                    style: AppFonts.heading(size: 56, weight: FontWeight.w700, color: AppColors.goldDark, height: 1),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            FadeInUp(
              delay: const Duration(milliseconds: 600),
              duration: const Duration(milliseconds: 800),
              child: Text(
                'SCHOOL ERP',
                style: AppFonts.body(size: 15, weight: FontWeight.w800, color: AppColors.ink2, letterSpacing: 4),
              ),
            ),
            const Spacer(flex: 2),
            FadeInUp(
              delay: const Duration(milliseconds: 800),
              duration: const Duration(milliseconds: 600),
              child: Column(
                children: [
                  SizedBox(
                    width: 240,
                    child: AnimatedBuilder(
                      animation: _progressController,
                      builder: (context, child) => ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _progressController.value,
                          backgroundColor: AppColors.primarySoft,
                          valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                          minHeight: 4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Initializing…', style: AppFonts.body(size: 14, weight: FontWeight.w600, color: AppColors.ink2)),
                ],
              ),
            ),
            const Spacer(),
            FadeIn(
              delay: const Duration(milliseconds: 1000),
              child: FutureBuilder<String>(
                future: UpdateService.currentVersion(),
                builder: (context, snap) => Text(
                  snap.hasData && snap.data!.isNotEmpty ? 'Version ${snap.data}' : '',
                  style: AppFonts.body(size: 13, color: AppColors.ink3),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ]),
    );
  }
}
