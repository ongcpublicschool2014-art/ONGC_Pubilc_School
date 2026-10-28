import 'package:flutter/material.dart';
import 'package:animate_do/animate_do.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../utils/app_theme.dart';
import '../../utils/app_routes.dart';
import '../../utils/auth_provider.dart';
import '../../services/device_service.dart';
import '../../services/supabase_service.dart';

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
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF7A1F2B),
              Color(0xFF571520),
              Color(0xFF3D0F17),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 3),
              FadeInDown(
                duration: const Duration(milliseconds: 800),
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    return Container(
                      width: 200.w,
                      height: 200.h,
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(32.r),
                        border: Border.all(
                          color: AppColors.accent.withValues(
                            alpha: 0.3 + (_pulseController.value * 0.2),
                          ),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accent.withValues(
                              alpha: 0.1 + (_pulseController.value * 0.1),
                            ),
                            blurRadius: 40,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                      padding: EdgeInsets.all(20.w),
                      child: Image.asset(
                        'assets/images/educore360_logo.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.school_rounded,
                          size: 60.sp,
                          color: AppColors.accent,
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: 32.h),
              FadeInUp(
                delay: const Duration(milliseconds: 400),
                duration: const Duration(milliseconds: 800),
                child: Text(
                  'EduCore360',
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.w,
                      ),
                ),
              ),
              SizedBox(height: 8.h),
              FadeInUp(
                delay: const Duration(milliseconds: 600),
                duration: const Duration(milliseconds: 800),
                child: Text(
                  'Institution Administration Platform',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppColors.textLight.withValues(alpha: 0.8),
                        letterSpacing: 1.w,
                      ),
                ),
              ),
              const Spacer(flex: 2),
              FadeInUp(
                delay: const Duration(milliseconds: 800),
                duration: const Duration(milliseconds: 600),
                child: Column(
                  children: [
                    SizedBox(
                      width: 200.w,
                      child: AnimatedBuilder(
                        animation: _progressController,
                        builder: (context, child) {
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(4.r),
                            child: LinearProgressIndicator(
                              value: _progressController.value,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.1),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                AppColors.accent.withValues(alpha: 0.8),
                              ),
                              minHeight: 3.h,
                            ),
                          );
                        },
                      ),
                    ),
                    SizedBox(height: 16.h),
                    Text(
                      'Initializing...',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textLight.withValues(alpha: 0.5),
                          ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              FadeIn(
                delay: const Duration(milliseconds: 1000),
                child: Text(
                  'v1.0.0',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.textLight.withValues(alpha: 0.3),
                      ),
                ),
              ),
              SizedBox(height: 32.h),
            ],
          ),
        ),
      ),
    );
  }
}
