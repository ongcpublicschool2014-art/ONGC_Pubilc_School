import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/supabase_service.dart';
import '../../utils/app_routes.dart';
import '../../utils/app_theme.dart';

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
              ? (data['error']?.toString() ?? 'Could not send OTP (${resp.status})')
              : 'Could not send OTP (${resp.status})';
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
          _error = 'Registration failed';
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
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16.r),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.admin_panel_settings_rounded,
                      size: 52.sp, color: AppColors.primary),
                  SizedBox(height: 14.h),
                  Text(
                    'Set up Super Admin',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                  ),
                  SizedBox(height: 6.h),
                  Text(
                    'This is a one-time setup. Create the office master account that manages all institutions.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12.sp),
                  ),
                  SizedBox(height: 24.h),
                  _field(_trustNameController, 'Trust Name *',
                      Icons.account_balance_outlined),
                  SizedBox(height: 12.h),
                  _field(_nameController, 'Username *', Icons.person_outline),
                  SizedBox(height: 12.h),
                  _field(_emailController, 'Email *', Icons.mail_outline,
                      keyboard: TextInputType.emailAddress),
                  SizedBox(height: 12.h),
                  // Mobile + Send OTP
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(10),
                          ],
                          decoration: InputDecoration(
                            labelText: 'Mobile *',
                            prefixIcon: const Icon(Icons.phone_outlined),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8.r)),
                            isDense: true,
                          ),
                        ),
                      ),
                      SizedBox(width: 8.w),
                      SizedBox(
                        height: 48.h,
                        child: ElevatedButton(
                          onPressed: _sendingOtp ? null : _sendOtp,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8.r)),
                          ),
                          child: _sendingOtp
                              ? SizedBox(
                                  height: 16.h,
                                  width: 16.h,
                                  child: const CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.white)))
                              : Text(_otpSent ? 'Resend' : 'Send OTP',
                                  style: TextStyle(
                                      fontSize: 12.sp,
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                  if (_otpSent) ...[
                    SizedBox(height: 6.h),
                    Text(
                      'OTP sent to ${_maskedPhone ?? 'your mobile'}.',
                      style: TextStyle(
                          color: AppColors.success, fontSize: 11.sp),
                    ),
                    SizedBox(height: 10.h),
                    TextField(
                      controller: _otpController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      style: TextStyle(fontSize: 16.sp, letterSpacing: 4),
                      decoration: InputDecoration(
                        labelText: 'Enter 6-digit OTP *',
                        prefixIcon: const Icon(Icons.sms_outlined),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8.r)),
                        isDense: true,
                      ),
                    ),
                  ],
                  SizedBox(height: 12.h),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Password *',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8.r)),
                      isDense: true,
                    ),
                  ),
                  SizedBox(height: 12.h),
                  TextField(
                    controller: _confirmController,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Confirm Password *',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8.r)),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _register(),
                  ),
                  if (_error != null) ...[
                    SizedBox(height: 12.h),
                    Container(
                      padding: EdgeInsets.all(10.w),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8.r),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 16.sp, color: Colors.red.shade700),
                          SizedBox(width: 8.w),
                          Expanded(
                            child: Text(_error!,
                                style: TextStyle(
                                    color: Colors.red.shade700,
                                    fontSize: 12.sp)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  SizedBox(height: 20.h),
                  ElevatedButton(
                    onPressed: _submitting ? null : _register,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: 14.h),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8.r)),
                    ),
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
                        : Text('Create Super Admin',
                            style: TextStyle(
                                fontSize: 15.sp,
                                fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon,
      {TextInputType? keyboard}) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8.r)),
        isDense: true,
      ),
    );
  }
}
