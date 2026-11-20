import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';
import 'package:provider/provider.dart';
import '../../services/supabase_service.dart';
import '../../utils/app_routes.dart';
import '../../utils/auth_provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';

import '../../services/update_service.dart';
import '../../widgets/app_dropdown_field.dart';
import '../superadmin/module_control_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _rememberMe = true;
  String _version = '';

  bool _isSuperAdmin = false;
  bool _appliedMobileDefault = false;

  List<Map<String, dynamic>> _institutions = [];
  int? _selectedInsId;
  bool _loadingInstitutions = true;

  List<Map<String, dynamic>> _availableYears = [];
  String? _selectedYear;
  bool _loadingYears = false;


  // ── Forgot-password flow (rendered inline in the right panel instead
  // of pushing a separate route) ────────────────────────────────────────
  bool _showForgotPassword = false;
  int _fpStep = 0; // 0 = email, 1 = otp, 2 = new password
  bool _fpLoading = false;
  String? _fpError;
  String? _fpMaskedPhone;
  bool _fpObscure = true;
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_vendorKey);
    _loadInstitutions();
    UpdateService.currentVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_appliedMobileDefault) {
      _appliedMobileDefault = true;
      final width = MediaQuery.of(context).size.width;
      if (width <= 900) {
        // Mobile: only Super Admin login is available, so default the form there.
        _isSuperAdmin = true;
      }
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_vendorKey);
    _emailController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  /// Ctrl+Shift+M: the software vendor's Module Control (behind the vendor
  /// password). Not shown anywhere on screen -- it is not for the client.
  bool _vendorKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyM) return false;
    final k = HardwareKeyboard.instance;
    if (!k.isControlPressed || !k.isShiftPressed) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ModuleControlScreen()));
    return true;
  }

  // ── Forgot-password handlers (mirror forgot_password_screen.dart but
  //    keep the user on the welcome screen) ───────────────────────────
  void _openForgotPassword() {
    setState(() {
      _showForgotPassword = true;
      _fpStep = 0;
      _fpError = null;
      _fpMaskedPhone = null;
      _otpController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
    });
  }

  void _closeForgotPassword() {
    setState(() {
      _showForgotPassword = false;
      _fpStep = 0;
      _fpError = null;
      _fpMaskedPhone = null;
      _otpController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
    });
  }

  Future<void> _fpRequestOtp() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _fpError = 'Enter a valid email address');
      return;
    }
    setState(() {
      _fpLoading = true;
      _fpError = null;
    });
    try {
      final resp = await SupabaseService.client.functions.invoke(
        'send-password-reset-otp',
        body: {'email': email},
      );
      final data = resp.data;
      if (resp.status >= 400) {
        setState(() {
          _fpLoading = false;
          _fpError = data is Map ? (data['error']?.toString() ?? 'Server error (${resp.status})') : 'Server error (${resp.status})';
        });
        return;
      }
      if (data is Map && data['error'] != null) {
        setState(() {
          _fpLoading = false;
          _fpError = data['error'].toString();
        });
        return;
      }
      setState(() {
        _fpLoading = false;
        _fpStep = 1;
        _fpMaskedPhone = (data is Map ? data['masked'] : null)?.toString();
      });
    } catch (e) {
      setState(() {
        _fpLoading = false;
        _fpError = friendlyError(e);
      });
    }
  }

  Future<void> _fpVerifyOtp() async {
    final otp = int.tryParse(_otpController.text.trim());
    if (otp == null || otp < 100000 || otp > 999999) {
      setState(() => _fpError = 'Enter the 6-digit OTP from SMS');
      return;
    }
    setState(() {
      _fpLoading = true;
      _fpError = null;
    });
    try {
      final ok = await SupabaseService.client.rpc('verify_password_reset_otp', params: {
        'p_email': _emailController.text.trim(),
        'p_otp': otp,
      });
      if (ok == true) {
        setState(() {
          _fpLoading = false;
          _fpStep = 2;
        });
      } else {
        setState(() {
          _fpLoading = false;
          _fpError = 'Invalid or expired OTP. Try again or request a new one.';
        });
      }
    } catch (_) {
      setState(() {
        _fpLoading = false;
        _fpError = 'Verification failed. Try again.';
      });
    }
  }

  Future<void> _fpResetPassword() async {
    final pwd = _newPasswordController.text;
    final confirm = _confirmPasswordController.text;
    if (pwd.length < 6) {
      setState(() => _fpError = 'Password must be at least 6 characters');
      return;
    }
    if (pwd != confirm) {
      setState(() => _fpError = 'Passwords do not match');
      return;
    }
    setState(() {
      _fpLoading = true;
      _fpError = null;
    });
    try {
      final ok = await SupabaseService.client.rpc('complete_password_reset', params: {
        'p_email': _emailController.text.trim(),
        'p_new_password': pwd,
      });
      if (ok == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password reset successful. Please sign in with your new password.'),
            backgroundColor: AppColors.success,
          ),
        );
        _passwordController.clear();
        _closeForgotPassword();
      } else {
        setState(() {
          _fpLoading = false;
          _fpError = 'Reset failed. Restart the process and try again.';
        });
      }
    } catch (_) {
      setState(() {
        _fpLoading = false;
        _fpError = 'Could not save the new password. Try again.';
      });
    }
  }

  Future<void> _loadInstitutions() async {
    final institutions = await SupabaseService.getInstitutionNames();
    if (!mounted) return;
    setState(() {
      _institutions = institutions;
      _loadingInstitutions = false;
    });
    _restoreRemembered();
  }

  Future<void> _loadYears(int insId) async {
    setState(() => _loadingYears = true);
    try {
      final result = await SupabaseService.client
          .from('institutionyear')
          .select('yrlabel, iyrstadate, iyrenddate')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('yrlabel', ascending: false);
      final rawYears = List<Map<String, dynamic>>.from(result);
      final seen = <String>{};
      final years = <Map<String, dynamic>>[];
      for (final y in rawYears) {
        final label = y['yrlabel']?.toString() ?? '';
        if (label.isEmpty || seen.contains(label)) continue;
        seen.add(label);
        years.add(y);
      }
      // Default to the year whose dates cover today (else the newest), as the
      // login screen does -- a past year added later must never become the
      // default and have fees posted into it.
      final today = DateTime.now();
      String? current;
      for (final y in years) {
        final start = DateTime.tryParse(y['iyrstadate']?.toString() ?? '');
        final end = DateTime.tryParse(y['iyrenddate']?.toString() ?? '');
        if (start == null || end == null) continue;
        if (!today.isBefore(start) && !today.isAfter(DateTime(end.year, end.month, end.day, 23, 59, 59))) {
          current = y['yrlabel']?.toString();
          break;
        }
      }
      if (mounted) {
        setState(() {
          _availableYears = years;
          _selectedYear = current ?? (years.isNotEmpty ? years.first['yrlabel']?.toString() : null);
          _loadingYears = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingYears = false);
    }
  }

  void _switchTab(bool superAdmin) {
    if (_isSuperAdmin == superAdmin) return;
    setState(() {
      _isSuperAdmin = superAdmin;
      _emailController.clear();
      _passwordController.clear();
      _selectedInsId = null;
      _availableYears = [];
      _selectedYear = null;
    });
    context.read<AuthProvider>().clearError();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_isSuperAdmin && _selectedInsId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an institution')),
      );
      return;
    }

    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.login(
      _emailController.text.trim(),
      _passwordController.text,
      insId: _isSuperAdmin ? null : _selectedInsId,
      isSuperAdmin: _isSuperAdmin,
      yearLabel: _selectedYear,
    );

    if (success && mounted) {
      await authProvider.setRememberMe(_rememberMe);
      await authProvider.saveCredentials(
        _emailController.text.trim(),
        _passwordController.text,
        insId: _isSuperAdmin ? null : _selectedInsId,
        isSuperAdmin: _isSuperAdmin,
        yearLabel: _selectedYear,
      );
      if (mounted) {
        Navigator.pushReplacementNamed(
          context,
          _isSuperAdmin ? AppRoutes.superAdminDashboard : AppRoutes.dashboard,
        );
      }
      return;
    }
  }

  // ─── Remember Me ────────────────────────────────────────────────────────────

  /// Pre-fill the last email / institution / access type when the user ticked
  /// "Remember Me" last time. Runs once the institution list is in.
  Future<void> _restoreRemembered() async {
    final auth = context.read<AuthProvider>();
    final remember = await auth.rememberMe();
    if (!mounted) return;
    setState(() => _rememberMe = remember);
    if (!remember) return;
    final saved = await auth.savedLogin();
    if (!mounted || saved.email == null || _emailController.text.isNotEmpty) return;
    final isMobile = MediaQuery.of(context).size.width <= 900;
    if (isMobile && !saved.superAdmin) return; // mobile signs in as Super Admin only
    final insKnown = _institutions.any((i) => i['ins_id'] == saved.insId);
    setState(() {
      _isSuperAdmin = saved.superAdmin;
      _emailController.text = saved.email!;
      if (!saved.superAdmin && insKnown) _selectedInsId = saved.insId;
    });
    if (!saved.superAdmin && insKnown) {
      _loadYears(saved.insId!);
    }
  }

  // ─── Small formatters ───────────────────────────────────────────────────────

  static String _initials(String name) {
    final words = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(w[0])).toList();
    if (words.isEmpty) return '•';
    if (words.length == 1) return words.first.substring(0, 1).toUpperCase();
    return (words[0][0] + words[1][0]).toUpperCase();
  }

  // ─── Page ───────────────────────────────────────────────────────────────────
  // Sign-in (2026-10-31, user's mock-up): the school painting across the
  // window, the headline and feature chips on the left, and a white card on
  // the right holding the whole form in one step.

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width <= 900;
    final wide = size.width >= 1100;
    final cardAreaW = wide ? (size.width * 0.36).clamp(540.0, 720.0).toDouble() : size.width;
    final cardW = math.min(630.0, cardAreaW - 56);
    final card = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
        child: FadeIn(duration: const Duration(milliseconds: 400), child: _card(width: cardW, isMobile: isMobile)),
      ),
    );
    return Scaffold(
      backgroundColor: AppColors.loginBg,
      body: Stack(fit: StackFit.expand, children: [
        _backdrop(size),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _leftColumn()),
            SizedBox(width: cardAreaW, child: card),
          ])
        else
          SafeArea(child: card),
      ]),
    );
  }

  /// The school painting across the whole window, under a light wash that
  /// is strongest on the left (behind the headline) and softens the bright
  /// colours everywhere, as in the mock-up.
  Widget _backdrop(Size size) {
    return IgnorePointer(
      child: Stack(fit: StackFit.expand, children: [
        Image.asset(
          'assets/images/login_bg.jpg',
          fit: BoxFit.cover,
          alignment: const Alignment(0, 0.3),
          errorBuilder: (_, __, ___) => const ColoredBox(color: AppColors.loginBg),
        ),
        // overall softening
        ColoredBox(color: AppColors.loginBg.withValues(alpha: 0.28)),
        // the wash behind the headline, fading out towards the school
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.loginBg.withValues(alpha: 0.93),
                AppColors.loginBg.withValues(alpha: 0.82),
                AppColors.loginBg.withValues(alpha: 0.12),
                AppColors.loginBg.withValues(alpha: 0.0),
              ],
              stops: const [0, 0.3, 0.48, 1],
            ),
          ),
        ),
      ]),
    );
  }

  /// Brand, headline, feature chips and the status line.
  Widget _leftColumn() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(80, 72, 32, 52),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _brand(),
        Expanded(
          child: Align(
            alignment: const Alignment(-1, 0.1),
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _headline()),
          ),
        ),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.bottomLeft, child: _statusLine()),
      ]),
    );
  }

  // ─── Brand, headline, status ────────────────────────────────────────────────

  Widget _brand({double logo = 74, double title = 36}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: logo,
          height: logo,
          padding: EdgeInsets.all(logo * 0.1),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(logo * 0.24),
            border: Border.all(color: AppColors.gold, width: 2.5),
            boxShadow: [
              BoxShadow(
                  color: AppColors.primaryDark.withValues(alpha: 0.5),
                  blurRadius: 22,
                  spreadRadius: -12,
                  offset: const Offset(0, 10)),
            ],
          ),
          child: _appLogo(),
        ),
        SizedBox(width: logo * 0.24),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _brandName(title),
            SizedBox(height: title * 0.22),
            Text('SCHOOL ERP',
                style: AppFonts.body(
                    size: title * 0.42, weight: FontWeight.w800, color: AppColors.loginInk2, letterSpacing: title * 0.42 * 0.24)),
          ],
        ),
      ],
    );
  }

  Widget _brandName(double size) => Text.rich(
        TextSpan(children: [
          TextSpan(text: 'FIT ', style: AppFonts.heading(size: size, weight: FontWeight.w700, color: AppColors.primaryDark, height: 1)),
          TextSpan(text: 'School', style: AppFonts.heading(size: size, weight: FontWeight.w700, color: AppColors.loginBrand, height: 1)),
        ]),
      );

  Widget _appLogo() => Image.asset(
        'assets/images/app_logo_mark.png',
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const AppIcon('teacher', size: 22, color: AppColors.primary),
      );

  Widget _headline() {
    return FadeInLeft(
      duration: const Duration(milliseconds: 600),
      child: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 28, height: 2, color: AppColors.gold),
              const SizedBox(width: 12),
              Text('WELCOME TO',
                  style: AppFonts.body(size: 13, weight: FontWeight.w800, color: AppColors.loginBrandInk, letterSpacing: 2.6)),
            ]),
            const SizedBox(height: 26),
            Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: 'Run your\ninstitution with\n',
                  style: AppFonts.heading(
                      size: 66, weight: FontWeight.w700, color: AppColors.primaryDark, height: 1.08, letterSpacing: -1.2),
                ),
                TextSpan(
                  text: 'clarity.',
                  style: AppFonts.heading(
                          size: 66, weight: FontWeight.w700, color: AppColors.loginBrand, height: 1.08, letterSpacing: -1.2)
                      .copyWith(fontStyle: FontStyle.italic),
                ),
              ]),
            ),
            const SizedBox(height: 26),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                'A unified administration platform for fees, students, staff and reporting.',
                style: AppFonts.body(size: 20, color: AppColors.loginInk2).copyWith(height: 1.55),
              ),
            ),
            const SizedBox(height: 30),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Wrap(spacing: 14, runSpacing: 14, children: [
                _chip('teacher', 'Admissions'),
                _chip('receipt-item', 'Fees & Receipts'),
                _chip('profile-2user', 'Students & Staff'),
                _chip('chart', 'Reports'),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String icon, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.loginLine),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AppIcon.linear(icon, size: 20, color: AppColors.primaryDark),
          const SizedBox(width: 12),
          Text(label, style: AppFonts.body(size: 15.5, weight: FontWeight.w600, color: AppColors.loginInk)),
        ]),
      );

  /// Copyright + version, and the live server status (tap to retry when down).
  Widget _statusLine({bool stacked = false}) {
    final style = AppFonts.body(size: 15, color: AppColors.loginInk2);
    final String status;
    final Color dot;
    if (_loadingInstitutions) {
      status = 'Connecting to server…';
      dot = AppColors.gold;
    } else if (_institutions.isNotEmpty) {
      status = 'Connected to server';
      dot = AppColors.loginOk;
    } else {
      status = 'Server not reachable · Retry';
      dot = AppColors.error;
    }
    final canRetry = !_loadingInstitutions && _institutions.isEmpty;
    final statusChip = MouseRegion(
      cursor: canRetry ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: canRetry
            ? () {
                setState(() => _loadingInstitutions = true);
                _loadInstitutions();
              }
            : null,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dot,
              boxShadow: [BoxShadow(color: dot.withValues(alpha: 0.15), spreadRadius: 4)],
            ),
          ),
          const SizedBox(width: 10),
          Text(status, style: style.copyWith(color: AppColors.loginInk)),
        ]),
      ),
    );
    final copy = Row(mainAxisSize: MainAxisSize.min, children: [
      Text('© ${DateTime.now().year} ', style: style.copyWith(color: AppColors.loginInk)),
      Text('FIT School', style: style.copyWith(color: AppColors.loginInk, fontWeight: FontWeight.w700)),
      if (_version.isNotEmpty) ...[
        const SizedBox(width: 8),
        Container(width: 1, height: 14, color: AppColors.loginLine),
        const SizedBox(width: 8),
        Text('Version $_version', style: style),
      ],
    ]);
    if (stacked) return Column(mainAxisSize: MainAxisSize.min, children: [statusChip, const SizedBox(height: 6), copy]);
    return Row(mainAxisSize: MainAxisSize.min, children: [copy, const SizedBox(width: 26), statusChip]);
  }

  // ─── The card ───────────────────────────────────────────────────────────────

  Widget _card({required double width, required bool isMobile}) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
              color: AppColors.primaryDark.withValues(alpha: 0.35),
              blurRadius: 60,
              spreadRadius: -28,
              offset: const Offset(0, 30)),
          BoxShadow(color: AppColors.primaryDark.withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(isMobile ? 24 : 42, 26, isMobile ? 24 : 42, 0),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              alignment: Alignment.topCenter,
              child: _formColumn(isMobile: isMobile),
            ),
          ),
          _cardFoot(),
        ]),
      ),
    );
  }

  /// Mint wave along the card's foot with the cap on its books.
  Widget _cardFoot() => SizedBox(
        height: 70,
        child: Stack(children: [
          const Positioned.fill(child: CustomPaint(painter: _WavePainter(AppColors.loginMint, AppColors.loginWave))),
          Positioned(
            right: 6,
            bottom: 0,
            width: 108,
            child: Image.asset(
              'assets/images/login_cap.png',
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        ]),
      );

  Widget _heading(String title, String sub) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              textAlign: TextAlign.center,
              style: AppFonts.heading(size: 30, weight: FontWeight.w700, color: AppColors.primaryDark, height: 1.1)),
          const SizedBox(height: 4),
          Text(sub, textAlign: TextAlign.center, style: AppFonts.body(size: 14, color: AppColors.loginInk)),
        ],
      );

  Widget _formColumn({required bool isMobile}) {
    final head = [
      Center(child: _brand(logo: 52, title: 26)),
      const SizedBox(height: 14),
    ];
    if (_showForgotPassword) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        ...head,
        _heading('Reset Password', 'Account recovery'),
        const SizedBox(height: 14),
        _buildForgotPasswordPanel(),
        const SizedBox(height: 8),
      ]);
    }
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...head,
          _heading('Sign In', _isSuperAdmin ? 'Super Admin access to every institution' : 'Access your school account'),
          const SizedBox(height: 16),
          _tabs(isMobile),
          const SizedBox(height: 14),
          Consumer<AuthProvider>(
            builder: (context, auth, _) {
              if (auth.errorMessage == null) return const SizedBox.shrink();
              return Padding(padding: const EdgeInsets.only(bottom: 14), child: _errorBox(auth.errorMessage!));
            },
          ),
          if (!_isSuperAdmin) ...[
            _fieldLabel('Institution'),
            const SizedBox(height: 6),
            _loadingInstitutions
                ? const LinearProgressIndicator(color: AppColors.primary, backgroundColor: AppColors.primaryLight)
                : _institutionDropdown(),
            const SizedBox(height: 10),
            _fieldLabel('Academic Year'),
            const SizedBox(height: 6),
            _loadingYears
                ? const LinearProgressIndicator(color: AppColors.primary, backgroundColor: AppColors.primaryLight)
                : _yearDropdown(),
            const SizedBox(height: 10),
          ],
          ..._loginFields(),
        ],
      ),
    );
  }

  /// Email, password, Remember Me / Forgot Password, Sign In.
  List<Widget> _loginFields() => [
        _fieldLabel(_isSuperAdmin ? 'Username' : 'Email Address'),
        const SizedBox(height: 6),
        _buildFilledField(
          controller: _emailController,
          hint: _isSuperAdmin ? 'Enter username' : 'you@institution.edu',
          icon: _isSuperAdmin ? 'user' : 'sms',
          keyboardType: _isSuperAdmin ? TextInputType.text : TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          validator: (value) {
            if (value == null || value.isEmpty) {
              return _isSuperAdmin ? 'Please enter your username' : 'Please enter your email';
            }
            if (!_isSuperAdmin && !value.contains('@')) return 'Please enter a valid email';
            return null;
          },
        ),
        const SizedBox(height: 10),
        _fieldLabel('Password'),
        const SizedBox(height: 6),
        _buildFilledField(
          controller: _passwordController,
          hint: 'Enter your password',
          icon: 'lock',
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _handleLogin(),
          suffixIcon: _eyeToggle(_obscurePassword, () => setState(() => _obscurePassword = !_obscurePassword)),
          validator: (value) {
            if (value == null || value.isEmpty) return 'Please enter your password';
            if (value.length < 6) return 'Password must be at least 6 characters';
            return null;
          },
        ),
        const SizedBox(height: 6),
        Row(children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _rememberMe = !_rememberMe),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: _rememberMe,
                    activeColor: AppColors.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    onChanged: (v) => setState(() => _rememberMe = v ?? true),
                  ),
                ),
                const SizedBox(width: 8),
                Text('Remember Me', style: AppFonts.body(size: 15, color: AppColors.loginInk)),
              ]),
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: _openForgotPassword,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              textStyle: AppFonts.body(size: 15, weight: FontWeight.w700),
            ),
            child: const Text('Forgot Password?'),
          ),
        ]),
        const SizedBox(height: 10),
        Consumer<AuthProvider>(
          builder: (context, auth, _) => _primaryButton('Sign In', _handleLogin, loading: auth.isLoading),
        ),
        const SizedBox(height: 4),
      ];

  Widget _tabs(bool isMobile) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: AppColors.loginMint, borderRadius: BorderRadius.circular(13)),
        child: Row(children: [
          Expanded(child: _segment('Institution', 'building', !_isSuperAdmin, () => _switchTab(false), disabled: isMobile)),
          Expanded(child: _segment('Super Admin', 'shield-tick', _isSuperAdmin, () => _switchTab(true))),
        ]),
      );

  /// Teal button, full width.
  Widget _primaryButton(String label, VoidCallback onTap, {bool loading = false}) => Container(
        height: 46,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.loginBtnTop, AppColors.loginBtnBottom],
          ),
          boxShadow: [
            BoxShadow(
                color: AppColors.primaryDark.withValues(alpha: 0.9),
                blurRadius: 26,
                spreadRadius: -14,
                offset: const Offset(0, 14)),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(13),
            onTap: loading ? null : onTap,
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                    )
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(label, style: AppFonts.body(size: 16.5, weight: FontWeight.w700, color: Colors.white)),
                      const SizedBox(width: 10),
                      const Icon(Icons.arrow_forward_rounded, size: 19, color: Colors.white),
                    ]),
            ),
          ),
        ),
      );

  Widget _errorBox(String message) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.errorBg,
          borderRadius: BorderRadius.circular(AppUI.controlRadius),
          border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: AppUI.label.copyWith(color: AppColors.error, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

  Widget _eyeToggle(bool obscured, VoidCallback onPressed) => IconButton(
        tooltip: obscured ? 'Show password' : 'Hide password',
        icon: AppIcon.linear(obscured ? 'eye-slash' : 'eye', size: 18, color: AppColors.ink3),
        onPressed: onPressed,
      );

  /// Academic years of the picked institution; defaults to the one covering
  /// today (see _loadYears).
  Widget _yearDropdown() {
    return AppDropdownField<String>(
      value: _selectedYear,
      isExpanded: true,
      dropdownColor: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      style: _fieldStyle,
      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.loginInk2),
      decoration: _filledDec(_selectedInsId == null ? 'Select an institution first' : 'Select academic year', 'calendar', null),
      items: [
        for (final y in _availableYears)
          DropdownMenuItem<String>(
            value: y['yrlabel']?.toString() ?? '',
            child: Text(y['yrlabel']?.toString() ?? '', overflow: TextOverflow.ellipsis),
          ),
      ],
      // null = disabled (no institution yet, or it has no active year)
      onChanged: _availableYears.isEmpty ? null : (v) => setState(() => _selectedYear = v),
      validator: (v) => (_availableYears.isNotEmpty && v == null) ? 'Please select an academic year' : null,
    );
  }

  /// Institution list: crest initials, name, and the institution code.
  Widget _institutionDropdown() {
    Widget row(Map<String, dynamic> ins, {required bool selected, bool crest = true}) {
      final name = ins['insname']?.toString() ?? '';
      final code = ins['inscode']?.toString() ?? '';
      return Row(
        children: [
          if (crest) ...[
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primarySoft,
              border: Border.all(color: AppColors.primaryLine),
            ),
            child: Text(_initials(name), style: AppFonts.heading(size: 11, color: AppColors.primaryText)),
          ),
          const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _fieldStyle.copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w600),
            ),
          ),
          if (code.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(code, style: AppFonts.mono(size: 11.5, weight: FontWeight.w500, color: AppColors.ink3)),
          ],
        ],
      );
    }

    return AppDropdownField<int>(
      value: _selectedInsId,
      isExpanded: true,
      dropdownColor: AppColors.card,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      itemHeight: null,
      style: _fieldStyle,
      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.loginInk2),
      // Same box as the other fields: building icon, same height.
      decoration: _filledDec('Select institution', 'building', null),
      items: [
        for (final ins in _institutions) DropdownMenuItem<int>(value: ins['ins_id'] as int, child: row(ins, selected: false)),
      ],
      selectedItemBuilder: (_) => [for (final ins in _institutions) row(ins, selected: true, crest: false)],
      onChanged: (value) {
        setState(() {
          _selectedInsId = value;
          _selectedYear = null;
          _availableYears = [];
        });
        if (value != null) {
          _loadYears(value);
        }
      },
      validator: (value) => value == null ? 'Please select an institution' : null,
    );
  }

  Widget _segment(String label, String icon, bool active, VoidCallback onTap, {bool disabled = false}) {
    final color = active ? Colors.white : AppColors.loginInk2;
    final seg = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? AppColors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        boxShadow: active
            ? [BoxShadow(color: AppColors.primaryDark.withValues(alpha: 0.7), blurRadius: 16, spreadRadius: -8, offset: const Offset(0, 8))]
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon.linear(icon, size: 17, color: color),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.body(size: 15.5, weight: active ? FontWeight.w700 : FontWeight.w600, color: color),
            ),
          ),
        ],
      ),
    );
    if (disabled) return Opacity(opacity: 0.4, child: IgnorePointer(child: seg));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: seg),
    );
  }

  // ─── Forgot password panel (inline, inside the card) ───────────────────────

  Widget _buildForgotPasswordPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Back-to-sign-in pill
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _closeForgotPassword,
            icon: const Icon(Icons.chevron_left_rounded, size: 18, color: AppColors.primary),
            label: const Text('Back to Sign In'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _fpStep == 0
              ? 'Enter your registered email. We\'ll send a 6-digit OTP to the mobile number on file.'
              : _fpStep == 1
                  ? (_fpMaskedPhone != null && _fpMaskedPhone!.isNotEmpty
                      ? 'OTP sent to $_fpMaskedPhone. Enter the 6-digit code below.'
                      : 'Enter the 6-digit OTP sent to your registered mobile.')
                  : 'Set a new password for your account.',
          style: AppUI.muted.copyWith(height: 1.5),
        ),
        const SizedBox(height: 24),

        if (_fpError != null) ...[
          _errorBox(_fpError!),
          const SizedBox(height: 16),
        ],

        // Step 0: email
        if (_fpStep == 0) ...[
          _fieldLabel('Email Address'),
          const SizedBox(height: 6),
          _buildFilledField(
            controller: _emailController,
            hint: 'you@institution.edu',
            icon: 'sms',
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _fpRequestOtp(),
          ),
          const SizedBox(height: 24),
          _fpPrimaryButton(
            label: 'Send OTP',
            icon: const AppIcon('send', size: 16, color: AppColors.onPrimary),
            onPressed: _fpRequestOtp,
          ),
        ],

        // Step 1: OTP
        if (_fpStep == 1) ...[
          _fieldLabel('OTP'),
          const SizedBox(height: 6),
          _buildFilledField(
            controller: _otpController,
            hint: 'Enter the 6-digit OTP',
            icon: 'shield-tick',
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _fpVerifyOtp(),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _fpLoading ? null : _fpRequestOtp,
              child: const Text('Resend OTP'),
            ),
          ),
          const SizedBox(height: 16),
          _fpPrimaryButton(
            label: 'Verify OTP',
            icon: const AppIcon('shield-tick', size: 16, color: AppColors.onPrimary),
            onPressed: _fpVerifyOtp,
          ),
        ],

        // Step 2: new password
        if (_fpStep == 2) ...[
          _fieldLabel('New Password'),
          const SizedBox(height: 6),
          _buildFilledField(
            controller: _newPasswordController,
            hint: 'At least 6 characters',
            icon: 'lock',
            obscureText: _fpObscure,
            suffixIcon: _eyeToggle(_fpObscure, () => setState(() => _fpObscure = !_fpObscure)),
          ),
          const SizedBox(height: 16),
          _fieldLabel('Confirm Password'),
          const SizedBox(height: 6),
          _buildFilledField(
            controller: _confirmPasswordController,
            hint: 'Re-enter new password',
            icon: 'lock',
            obscureText: _fpObscure,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _fpResetPassword(),
          ),
          const SizedBox(height: 24),
          _fpPrimaryButton(
            label: 'Reset Password',
            icon: const AppIcon('lock', size: 16, color: AppColors.onPrimary),
            onPressed: _fpResetPassword,
          ),
        ],
      ],
    );
  }

  Widget _fpPrimaryButton({
    required String label,
    required Widget icon,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 48,
      child: ElevatedButton.icon(
        onPressed: _fpLoading ? null : onPressed,
        icon: _fpLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(color: AppColors.onPrimary, strokeWidth: 2.5),
              )
            : icon,
        label: Text(label),
      ),
    );
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  TextStyle get _fieldStyle => AppFonts.body(size: 15, weight: FontWeight.w500, color: AppColors.loginInk);

  Widget _fieldLabel(String label) =>
      Text(label, style: AppFonts.body(size: 14.5, weight: FontWeight.w700, color: AppColors.loginInk));

  Widget _buildFilledField({
    required TextEditingController controller,
    required String hint,
    required String icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffixIcon,
    String? Function(String?)? validator,
    TextInputAction? textInputAction,
    void Function(String)? onFieldSubmitted,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      onChanged: (_) => setState(() {}),
      style: _fieldStyle,
      decoration: _filledDec(hint, icon, suffixIcon),
      validator: validator,
    );
  }

  /// 50px white field, 1.5px mint-grey border, teal when focused.
  InputDecoration _filledDec(String hint, String? icon, Widget? suffixIcon) {
    OutlineInputBorder b(Color c) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c, width: 1.5));
    return InputDecoration(
      hintText: hint,
      hintStyle: AppFonts.body(size: 15.5, color: AppColors.ink3),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      prefixIcon: icon == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 16, right: 12),
              child: AppIcon.linear(icon, size: 18, color: AppColors.loginInk2),
            ),
      prefixIconConstraints: const BoxConstraints(minWidth: 46, minHeight: 20),
      suffixIcon: suffixIcon,
      border: b(AppColors.loginLine),
      enabledBorder: b(AppColors.loginLine),
      disabledBorder: b(AppColors.loginLine),
      focusedBorder: b(AppColors.primary),
      errorBorder: b(AppColors.error),
      focusedErrorBorder: b(AppColors.error),
    );
  }
}

/// The mint wave along the foot of the sign-in card.
class _WavePainter extends CustomPainter {
  const _WavePainter(this.light, this.deep);
  final Color light, deep;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final back = Path()
      ..moveTo(0, h * 0.30)
      ..cubicTo(w * 0.25, h * 0.05, w * 0.45, h * 0.75, w * 0.70, h * 0.45)
      ..cubicTo(w * 0.85, h * 0.28, w * 0.95, h * 0.30, w, h * 0.22)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(back, Paint()..color = light);
    final front = Path()
      ..moveTo(0, h * 0.62)
      ..cubicTo(w * 0.30, h * 0.40, w * 0.50, h * 0.95, w * 0.78, h * 0.62)
      ..cubicTo(w * 0.88, h * 0.50, w * 0.95, h * 0.48, w, h * 0.46)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(front, Paint()..color = deep);
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.light != light || old.deep != deep;
}
