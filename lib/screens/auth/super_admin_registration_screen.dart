import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/supabase_service.dart';
import '../../utils/app_routes.dart';
import '../../utils/app_theme.dart';
import '../../widgets/app_ui.dart';

/// Clean message out of a FunctionException (or any other failure).
String _friendlyError(Object e) {
  if (e is FunctionException) {
    final d = e.details;
    if (d is Map && d['error'] != null) return d['error'].toString();
    return 'Server error (${e.status}). Please try again.';
  }
  return 'Could not reach the server. Check your connection and try again.';
}

/// First-run super-admin setup. Shown by the splash only when
/// super_admin_exists() returns false (brand-new database). Creates the
/// one office master account after verifying the mobile number with an
/// SMS OTP, then sends the user on to device activation.
class SuperAdminRegistrationScreen extends StatefulWidget {
  const SuperAdminRegistrationScreen({super.key});

  @override
  State<SuperAdminRegistrationScreen> createState() =>
      _SuperAdminRegistrationScreenState();
}

class _SuperAdminRegistrationScreenState
    extends State<SuperAdminRegistrationScreen> {
  final _trustNameController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;

  bool _sendingOtp = false;
  bool _otpSent = false;
  String? _maskedPhone;

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _trustNameController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');

  Future<void> _sendOtp() async {
    final mobile = _digits(_phoneController.text);
    if (mobile.length < 10) {
      setState(() => _error = 'Enter a valid 10-digit mobile number');
      return;
    }
    setState(() {
      _sendingOtp = true;
      _error = null;
    });
    try {
      final resp = await SupabaseService.client.functions.invoke(
        'send-superadmin-otp',
        body: {'mobile': mobile},
      );
      if (!mounted) return;
      if (resp.status >= 400) {
        final data = resp.data;
        setState(() {
          _sendingOtp = false;
          _error = data is Map
              ? (data['error']?.toString() ?? 'Could not send the OTP. Try again in a moment.')
              : 'Could not send the OTP. Try again in a moment.';
        });
        return;
      }
      final data = resp.data;
      setState(() {
        _sendingOtp = false;
        _otpSent = true;
        _maskedPhone = data is Map ? data['masked']?.toString() : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingOtp = false;
        _error = _friendlyError(e);
      });
    }
  }

  Future<void> _register() async {
    final trustName = _trustNameController.text.trim();
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final pwd = _passwordController.text;
    final confirm = _confirmController.text;
    final otp = int.tryParse(_otpController.text.trim());

    if (trustName.isEmpty) {
      setState(() => _error = 'Trust name is required');
      return;
    }
    if (name.isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email');
      return;
    }
    if (!_otpSent) {
      setState(() => _error = 'Send the OTP to your mobile first');
      return;
    }
    if (otp == null || otp < 100000 || otp > 999999) {
      setState(() => _error = 'Enter the 6-digit OTP sent to your mobile');
      return;
    }
    if (pwd.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters');
      return;
    }
    if (pwd != confirm) {
      setState(() => _error = 'Passwords do not match');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await SupabaseService.client.rpc('register_super_admin', params: {
        'p_name': name,
        'p_email': email,
        'p_password': pwd,
        'p_phone': _phoneController.text.trim(),
        'p_trust_name': trustName,
        'p_otp': otp,
      });
      final map = Map<String, dynamic>.from(result as Map);
      if (map['ok'] == true) {
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, AppRoutes.deviceActivation);
      } else {
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _error = 'Could not create the super admin account. Try again.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst(RegExp(r'^.*?:\s*'), '');
      setState(() {
        _submitting = false;
        _error = msg;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage(
                'assets/images/vimal-s-J69ERsG93hI-unsplash.jpg'),
            fit: BoxFit.cover,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Container(
              width: 480.w,
              padding: EdgeInsets.all(36.w),
              margin: EdgeInsets.symmetric(horizontal: 24.w, vertical: 24.h),
              decoration: AppUI.card(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.admin_panel_settings_rounded,
                      size: 52.sp, color: AppColors.primary),
                  SizedBox(height: 14.h),
                  Text(
                    'Set Up Super Admin',
                    textAlign: TextAlign.center,
                    style: AppUI.pageTitle,
                  ),
                  SizedBox(height: 6.h),
                  Text(
                    'This is a one-time setup. Create the office master account that manages all institutions.',
                    textAlign: TextAlign.center,
                    style: AppUI.muted,
                  ),
                  SizedBox(height: 24.h),
                  _field(_trustNameController, 'Trust Name *',
                      Icons.account_balance_outlined,
                      hint: 'Enter trust name'),
                  SizedBox(height: 12.h),
                  _field(_nameController, 'Username *', Icons.person_outline,
                      hint: 'Enter username'),
                  SizedBox(height: 12.h),
                  _field(_emailController, 'Email *', Icons.mail_outline,
                      keyboard: TextInputType.emailAddress,
                      hint: 'name@example.com'),
                  SizedBox(height: 12.h),
                  // Mobile + Send OTP
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          onChanged: (_) => setState(() {}),
                          style: _valueStyle(
                              _phoneController.text.trim().isNotEmpty),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(10),
                          ],
                          decoration: _inputDec('Mobile Number *',
                              prefixIcon: const Icon(Icons.phone_outlined),
                              hint: '10-digit mobile number',
                              filled: _phoneController.text.trim().isNotEmpty),
                        ),
                      ),
                      SizedBox(width: 8.w),
                      SizedBox(
                        height: AppUI.controlHeight(context),
                        child: ElevatedButton(
                          onPressed: _sendingOtp ? null : _sendOtp,
                          child: _sendingOtp
                              ? SizedBox(
                                  height: 16.h,
                                  width: 16.h,
                                  child: const CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.white)))
                              : Text(_otpSent ? 'Resend' : 'Send OTP'),
                        ),
                      ),
                    ],
                  ),
                  if (_otpSent) ...[
                    SizedBox(height: 6.h),
                    Text(
                      'OTP sent to ${_maskedPhone ?? 'your mobile'}.',
                      style: AppUI.muted.copyWith(color: AppColors.success),
                    ),
                    SizedBox(height: 10.h),
                    TextField(
                      controller: _otpController,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      style: AppUI.fieldText(context).copyWith(letterSpacing: 4),
                      decoration: _inputDec('OTP *',
                          prefixIcon: const Icon(Icons.sms_outlined),
                          hint: 'Enter the 6-digit OTP',
                          filled: _otpController.text.trim().isNotEmpty),
                    ),
                  ],
                  SizedBox(height: 12.h),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscure,
                    onChanged: (_) => setState(() {}),
                    style: _valueStyle(_passwordController.text.isNotEmpty),
                    decoration: _inputDec('Password *',
                        prefixIcon: const Icon(Icons.lock_outline),
                        hint: 'Enter password',
                        filled: _passwordController.text.isNotEmpty,
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        )),
                  ),
                  SizedBox(height: 12.h),
                  TextField(
                    controller: _confirmController,
                    obscureText: _obscure,
                    onChanged: (_) => setState(() {}),
                    style: _valueStyle(_confirmController.text.isNotEmpty),
                    decoration: _inputDec('Confirm Password *',
                        prefixIcon: const Icon(Icons.lock_outline),
                        hint: 'Re-enter password',
                        filled: _confirmController.text.isNotEmpty),
                    onSubmitted: (_) => _register(),
                  ),
                  if (_error != null) ...[
                    SizedBox(height: 12.h),
                    Container(
                      padding: EdgeInsets.all(10.w),
                      decoration: BoxDecoration(
                        color: AppColors.errorBg,
                        borderRadius: BorderRadius.circular(AppUI.controlRadius),
                        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 16.sp, color: AppColors.error),
                          SizedBox(width: 8.w),
                          Expanded(
                            child: Text(_error!,
                                style: AppUI.body.copyWith(
                                    color: AppColors.error,
                                    fontSize: 13.sp)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  SizedBox(height: 20.h),
                  ElevatedButton(
                    onPressed: _submitting ? null : _register,
                    style: AppUI.primary(context),
                    child: _submitting
                        ? SizedBox(
                            height: 20.h,
                            width: 20.h,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text('Create Super Admin'),
                  ),
                  SizedBox(height: 10.h),
                  Center(child: AppUI.requiredNote()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon,
      {TextInputType? keyboard, String? hint}) {
    final filled = c.text.trim().isNotEmpty;
    return TextField(
      controller: c,
      keyboardType: keyboard,
      onChanged: (_) => setState(() {}),
      style: _valueStyle(filled),
      decoration: _inputDec(label, prefixIcon: Icon(icon), hint: hint, filled: filled),
    );
  }

  /// Text style for a field's value (the kit field text).
  TextStyle _valueStyle(bool filled) => AppUI.fieldText(context);

  /// The kit field with a floating label, placeholder and the caller's
  /// prefix/suffix icons.
  InputDecoration _inputDec(String label,
      {Widget? prefixIcon, Widget? suffixIcon, String? hint, bool filled = false}) {
    return AppUI.field(context, hint ?? '', label: label, filled: filled).copyWith(
      prefixIcon: prefixIcon == null
          ? null
          : Padding(padding: const EdgeInsets.only(left: 12, right: 8), child: prefixIcon),
      suffixIcon: suffixIcon,
    );
  }
}
