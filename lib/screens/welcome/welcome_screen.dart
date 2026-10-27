import 'package:flutter/material.dart';
import 'package:animate_do/animate_do.dart';
import 'package:provider/provider.dart';
import '../../services/supabase_service.dart';
import '../../utils/app_routes.dart';
import '../../utils/auth_provider.dart';
import '../../utils/app_theme.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_ui.dart';

class _PinkPalette {
  static const Color frame = Color(0xFF001530);
  static const Color primary = Color(0xFF002147);
  static const Color accent = Color(0xFFD2913C);

  static const LinearGradient buttonGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE5A85C), Color(0xFFB5752A)],
  );

  static const LinearGradient avatarGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE8B06B), Color(0xFFA76920)],
  );

  // Three-stop diagonal: lifted primary blue → core navy → near-black so
  // the panel reads as a gradient rather than a flat colour.
  static const LinearGradient panelGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF1E3A6B),
      Color(0xFF002147),
      Color(0xFF000A1A),
    ],
    stops: [0.0, 0.55, 1.0],
  );
}

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

  bool _isSuperAdmin = false;
  bool _appliedMobileDefault = false;

  List<Map<String, dynamic>> _institutions = [];
  int? _selectedInsId;
  bool _loadingInstitutions = true;

  List<Map<String, dynamic>> _availableYears = [];
  String? _selectedYear;
  bool _loadingYears = false;

  // Hero-panel preview when an institution is picked (Institute Login).
  ({String? name, String? logo, String? address, String? mobile, String? email})?
      _selectedInsInfo;
  bool _loadingInsInfo = false;


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
    _loadInstitutions();
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
    _emailController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
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
          _fpError = data is Map
              ? (data['error']?.toString() ?? 'Server error (${resp.status})')
              : 'Server error (${resp.status})';
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
  }

  Future<void> _loadYears(int insId) async {
    setState(() => _loadingYears = true);
    try {
      final result = await SupabaseService.client
          .from('institutionyear')
          .select('yrlabel, iyrstadate, iyrenddate')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('iyr_id', ascending: false);
      final rawYears = List<Map<String, dynamic>>.from(result);
      final seen = <String>{};
      final years = <Map<String, dynamic>>[];
      for (final y in rawYears) {
        final label = y['yrlabel']?.toString() ?? '';
        if (label.isEmpty || seen.contains(label)) continue;
        seen.add(label);
        years.add(y);
      }
      if (mounted) {
        setState(() {
          _availableYears = years;
          _selectedYear =
              years.isNotEmpty ? years.first['yrlabel']?.toString() : null;
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
      _selectedInsInfo = null;
    });
    context.read<AuthProvider>().clearError();
  }

  Future<void> _loadInstitutionInfo(int insId) async {
    setState(() => _loadingInsInfo = true);
    try {
      final info = await SupabaseService.getInstitutionInfo(insId);
      if (mounted) {
        setState(() {
          _selectedInsInfo = info;
          _loadingInsInfo = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingInsInfo = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 900;

    return Scaffold(
      backgroundColor: AppColors.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Static bg image behind the centred auth card.
          Positioned.fill(
            child: Image.asset(
              'assets/images/vimal-s-J69ERsG93hI-unsplash.jpg',
              fit: BoxFit.cover,
              alignment: Alignment.center,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(isDesktop ? 40 : 16),
                child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isDesktop ? 1080 : 520),
              child: FadeIn(
                duration: const Duration(milliseconds: 500),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 32,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: IntrinsicHeight(
                      child: isDesktop
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(flex: 5, child: _buildHeroPanel()),
                                Expanded(flex: 6, child: _buildFormPanel()),
                              ],
                            )
                          : Column(
                              children: [
                                _buildHeroPanel(compact: true),
                                _buildFormPanel(),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
          ),
        ],
      ),
    );
  }

  // ─── Hero panel (left) ──────────────────────────────────────────────────────

  Widget _buildHeroPanel({bool compact = false}) {
    return Container(
      padding: EdgeInsets.all(compact ? 24 : 36),
      decoration: const BoxDecoration(gradient: _PinkPalette.panelGradient),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo + brand
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 44,
                  height: 44,
                  color: Colors.white,
                  padding: const EdgeInsets.all(6),
                  child: Image.asset(
                    'assets/images/educore360_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.school_rounded,
                        color: _PinkPalette.primary,
                        size: 24),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'EduCore360',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
          if (!compact) ...[
            const SizedBox(height: 56),
            // Show the picked institution's preview once it's loaded;
            // otherwise fall back to the generic tagline.
            if (_selectedInsInfo != null && !_isSuperAdmin)
              FadeIn(child: _institutionPreview(_selectedInsInfo!))
            else ...[
              FadeInLeft(
                child: const Text(
                  'Run your\ninstitution with\nclarity.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FadeInLeft(
                delay: const Duration(milliseconds: 100),
                child: Text(
                  'A unified administration platform for fees,\nstudents, staff and reporting.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _institutionPreview(
      ({String? name, String? logo, String? address, String? mobile, String? email}) info) {
    final logo = info.logo;
    final hasLogo = logo != null && logo.isNotEmpty;
    final initial = (info.name?.isNotEmpty == true)
        ? info.name![0].toUpperCase()
        : 'I';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Logo + name
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 72,
                height: 72,
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: hasLogo
                    ? Image.network(
                        logo,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => _logoFallback(initial),
                      )
                    : _logoFallback(initial),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                info.name ?? 'Institution',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                  letterSpacing: -0.3,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        // Generic explanation copy
        Text(
          'Sign in to access your administration tools — student\nrecords, fee collection, staff schedules, and detailed\nreports, all from one secure dashboard.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.75),
            fontSize: 14,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 36),
        // Decorative illustration filling the empty navy space below.
        // Fixed height instead of Expanded — the surrounding IntrinsicHeight
        // (used to keep both panels equal) can't size an Expanded child.
        // When an institution is picked, fill that space with a faded
        // version of its own logo instead of the generic teacher icon.
        SizedBox(
          height: 320,
          child: hasLogo
              ? _institutionLogoDecoration(logo)
              : _heroDecoration(),
        ),
      ],
    );
  }

  /// Hero illustration when an institution is selected: the institution's
  /// own logo, large and faded to 25% opacity, sitting in the empty navy
  /// space below the welcome copy.
  Widget _institutionLogoDecoration(String logoUrl) {
    return Center(
      child: Opacity(
        opacity: 0.25,
        child: SizedBox(
          width: 240,
          height: 240,
          child: Image.network(
            logoUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  /// Single-glyph hero illustration (one vector image): a large `teacher`
  /// icon centered inside a soft amber halo. Uses only Column/Center so
  /// IntrinsicHeight can measure it cleanly.
  Widget _heroDecoration() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  _PinkPalette.accent.withValues(alpha: 0.22),
                  _PinkPalette.accent.withValues(alpha: 0.0),
                ],
              ),
            ),
            alignment: Alignment.center,
            child: Opacity(
              opacity: 0.55,
              child: const AppIcon('teacher', size: 140, color: _PinkPalette.accent),
            ),
          ),
        ),
      ],
    );
  }

  Widget _logoFallback(String initial) => Container(
        decoration: const BoxDecoration(
          shape: BoxShape.rectangle,
          gradient: _PinkPalette.avatarGradient,
        ),
        alignment: Alignment.center,
        child: Text(
          initial,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w800,
          ),
        ),
      );

  // ─── Form panel (right) ─────────────────────────────────────────────────────

  Widget _buildFormPanel() {
    final isMobile = MediaQuery.of(context).size.width <= 900;
    return Container(
      color: Colors.white,
      padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 24 : 40, vertical: isMobile ? 28 : 36),
      child: _showForgotPassword
          ? _buildForgotPasswordPanel()
          : _buildSignInForm(isMobile: isMobile),
    );
  }

  Widget _buildSignInForm({required bool isMobile}) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
            Text('Sign in', style: AppUI.pageTitle),
            const SizedBox(height: 6),
            Text(
              'Welcome back. Choose your access type to continue.',
              style: AppUI.muted.copyWith(height: 1.5),
            ),
            const SizedBox(height: 24),

            _fieldLabel('Login as'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildPillTab(
                    'Institute Login',
                    !_isSuperAdmin,
                    () => _switchTab(false),
                    disabled: isMobile,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildPillTab(
                    'Super Admin',
                    _isSuperAdmin,
                    () => _switchTab(true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Error
            Consumer<AuthProvider>(
              builder: (context, auth, _) {
                if (auth.errorMessage == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.errorBg,
                      borderRadius: BorderRadius.circular(AppUI.controlRadius),
                      border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: AppColors.error, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            auth.errorMessage!,
                            style: AppUI.label.copyWith(color: AppColors.error, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

            // Institute-only fields
            if (!_isSuperAdmin) ...[
              _fieldLabel('Institution'),
              const SizedBox(height: 6),
              _loadingInstitutions
                  ? const LinearProgressIndicator(
                      color: AppColors.primary,
                      backgroundColor: AppColors.primaryLight,
                    )
                  : _buildFilledDropdown<int>(
                      value: _selectedInsId,
                      hint: 'Select Institution',
                      icon: Icons.school_outlined,
                      items: _institutions
                          .map((ins) => DropdownMenuItem<int>(
                                value: ins['ins_id'] as int,
                                child: Text(
                                  ins['insname'] ?? '',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ))
                          .toList(),
                      onChanged: (value) {
                        setState(() {
                          _selectedInsId = value;
                          _selectedYear = null;
                          _availableYears = [];
                          _selectedInsInfo = null;
                        });
                        if (value != null) {
                          _loadYears(value);
                          _loadInstitutionInfo(value);
                        }
                      },
                      validator: (value) =>
                          value == null ? 'Please select an institution' : null,
                    ),
              const SizedBox(height: 16),
              if (_availableYears.isNotEmpty) ...[
                _fieldLabel('Academic Year'),
                const SizedBox(height: 6),
                _loadingYears
                    ? const LinearProgressIndicator(
                        color: AppColors.primary,
                        backgroundColor: AppColors.primaryLight,
                      )
                    : _buildFilledDropdown<String>(
                        value: _selectedYear,
                        hint: 'Academic Year',
                        icon: Icons.calendar_today_outlined,
                        items: _availableYears.map((y) {
                          final label = y['yrlabel']?.toString() ?? '';
                          return DropdownMenuItem<String>(
                            value: label,
                            child: Text(label, overflow: TextOverflow.ellipsis),
                          );
                        }).toList(),
                        onChanged: (value) =>
                            setState(() => _selectedYear = value),
                      ),
                const SizedBox(height: 16),
              ],
            ],

            _fieldLabel(_isSuperAdmin ? 'Username' : 'Email'),
            const SizedBox(height: 6),
            _buildFilledField(
              controller: _emailController,
              hint: _isSuperAdmin ? 'Enter username' : 'you@institution.edu',
              icon: _isSuperAdmin
                  ? Icons.person_outline_rounded
                  : Icons.email_outlined,
              keyboardType: _isSuperAdmin
                  ? TextInputType.text
                  : TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return _isSuperAdmin
                      ? 'Please enter your username'
                      : 'Please enter your email';
                }
                if (!_isSuperAdmin && !value.contains('@')) {
                  return 'Please enter a valid email';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            _fieldLabel('Password'),
            const SizedBox(height: 6),
            _buildFilledField(
              controller: _passwordController,
              hint: 'Enter your password',
              icon: Icons.lock_outline_rounded,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _handleLogin(),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                  color: AppColors.textLight,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter your password';
                }
                if (value.length < 6) {
                  return 'Password must be at least 6 characters';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),

            // Forgot password link, right-aligned — opens the inline panel
            // instead of pushing a new route.
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _openForgotPassword,
                child: const Text('Forgot Password?'),
              ),
            ),

            const SizedBox(height: 12),

            Consumer<AuthProvider>(
              builder: (context, auth, _) {
                return SizedBox(
                  height: AppUI.controlHeight(context),
                  child: ElevatedButton(
                    onPressed: auth.isLoading ? null : _handleLogin,
                    child: auth.isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : const Text('LOGIN'),
                  ),
                );
              },
            ),
          ],
        ),
      );
  }

  // ─── Forgot password panel (inline replacement of the right panel) ─────────

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
            label: const Text('Back to sign in'),
          ),
        ),
        const SizedBox(height: 8),
        Text('Forgot Password?', style: AppUI.pageTitle),
        const SizedBox(height: 6),
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
          Container(
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
                  child: Text(
                    _fpError!,
                    style: AppUI.label.copyWith(color: AppColors.error, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Step 0: email
        if (_fpStep == 0) ...[
          _fieldLabel('Email Address'),
          const SizedBox(height: 6),
          _buildFilledField(
            controller: _emailController,
            hint: 'you@institution.edu',
            icon: Icons.email_outlined,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _fpRequestOtp(),
          ),
          const SizedBox(height: 24),
          _fpPrimaryButton(
            label: 'Send OTP',
            icon: const AppIcon('send', size: 16, color: Colors.white),
            onPressed: _fpRequestOtp,
          ),
        ],

        // Step 1: OTP
        if (_fpStep == 1) ...[
          _fieldLabel('OTP'),
          const SizedBox(height: 6),
          _buildFilledField(
            controller: _otpController,
            hint: '6-digit OTP',
            icon: Icons.shield_outlined,
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
            icon: const AppIcon('shield-tick', size: 16, color: Colors.white),
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
            icon: Icons.lock_outline_rounded,
            obscureText: _fpObscure,
            suffixIcon: IconButton(
              icon: Icon(
                _fpObscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                size: 18,
                color: AppColors.textLight,
              ),
              onPressed: () => setState(() => _fpObscure = !_fpObscure),
            ),
          ),
          const SizedBox(height: 16),
          _fieldLabel('Confirm Password'),
          const SizedBox(height: 6),
          _buildFilledField(
            controller: _confirmPasswordController,
            hint: 'Re-enter new password',
            icon: Icons.lock_outline_rounded,
            obscureText: _fpObscure,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _fpResetPassword(),
          ),
          const SizedBox(height: 24),
          _fpPrimaryButton(
            label: 'Reset Password',
            icon: const AppIcon('lock', size: 16, color: Colors.white),
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
      height: AppUI.controlHeight(context),
      child: ElevatedButton.icon(
        onPressed: _fpLoading ? null : onPressed,
        icon: _fpLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
              )
            : icon,
        label: Text(label),
      ),
    );
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  Widget _fieldLabel(String label) => Text(label, style: AppUI.label);

  Widget _buildPillTab(
    String label,
    bool active,
    VoidCallback onTap, {
    bool disabled = false,
  }) {
    final tab = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: AppUI.controlHeight(context),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: active ? AppColors.primaryLight : Colors.white,
        borderRadius: BorderRadius.circular(AppUI.controlRadius),
        border: Border.all(
          color: active ? AppColors.primary : AppColors.border,
          width: active ? 1.5 : 1,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? AppColors.primary : Colors.transparent,
              border: Border.all(
                color: active ? AppColors.primary : AppColors.border,
                width: 1.5,
              ),
            ),
            child: active
                ? const Icon(Icons.check, size: 10, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppUI.label.copyWith(
                color: active ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );

    if (disabled) {
      return Opacity(opacity: 0.4, child: IgnorePointer(child: tab));
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: tab),
    );
  }

  Widget _buildFilledField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffixIcon,
    String? Function(String?)? validator,
    TextInputAction? textInputAction,
    void Function(String)? onFieldSubmitted,
  }) {
    final filled = controller.text.trim().isNotEmpty;
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      onChanged: (_) => setState(() {}),
      style: AppUI.fieldText(context),
      decoration: _filledDec(hint, icon, suffixIcon, filled: filled),
      validator: validator,
    );
  }

  Widget _buildFilledDropdown<T>({
    required T? value,
    required String hint,
    required IconData icon,
    required List<DropdownMenuItem<T>> items,
    required void Function(T?) onChanged,
    String? Function(T?)? validator,
  }) {
    final filled = value != null;
    return DropdownButtonFormField<T>(
      value: value,
      isExpanded: true,
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 6,
      // Open-menu items render in textPrimary; the closed/selected value is
      // recolored amber + semibold via selectedItemBuilder below.
      style: AppUI.fieldText(context),
      icon: const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
      decoration: _filledDec(hint, icon, null, filled: filled),
      items: items,
      selectedItemBuilder: (context) => items
          .map((item) => DefaultTextStyle(
                style: AppUI.fieldText(context),
                child: Align(
                    alignment: Alignment.centerLeft, child: item.child),
              ))
          .toList(),
      onChanged: onChanged,
      validator: validator,
    );
  }

  // The app-wide field (AppUI.field) with this screen's Material leading icon.
  // The [filled] param is retained but no longer affects the border.
  InputDecoration _filledDec(String hint, IconData icon, Widget? suffixIcon,
      {bool filled = false}) {
    return AppUI.field(context, hint, suffix: suffixIcon).copyWith(
      prefixIcon: Padding(
        padding: const EdgeInsets.only(left: 12, right: 8),
        child: Icon(icon, size: 18, color: AppColors.textLight),
      ),
      prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
    );
  }
}

