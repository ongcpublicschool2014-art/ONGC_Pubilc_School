import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/supabase_service.dart';
import '../models/institution_user_model.dart';
import 'friendly_error.dart';

const _kEmail = 'saved_email';
const _kPassword = 'saved_password';
const _kInsId = 'saved_ins_id';
const _kIsSuperAdmin = 'saved_is_super_admin';
const _kRememberMe = 'login_remember_me';
const _kSchema = 'saved_schema';
const _kYearLabel = 'saved_year_label';

// Password is kept in the OS secure store (Keychain / Keystore / DPAPI /
// libsecret). Other non-sensitive fields stay in SharedPreferences.
const _secureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

class AuthProvider extends ChangeNotifier {
  bool _isAuthenticated = false;
  bool _isLoading = false;
  bool _subscriptionActive = false;
  bool _isSuperAdmin = false;
  String? _schema;
  String? _userEmail;
  String? _userName;
  String? _userRole;
  String? _errorMessage;
  int? _insId;
  String? _inscode;
  String? _insName;
  String? _insLogo;
  String? _insAddress;
  String? _yearLabel;
  InstitutionUserModel? _currentUser;
  String? _sessionToken; // server-issued session token (security foundation)

  bool get isAuthenticated => _isAuthenticated;
  bool get isLoading => _isLoading;
  bool get subscriptionActive => _subscriptionActive;
  bool get isSuperAdmin => _isSuperAdmin;
  String? get schema => _schema;
  String? get userEmail => _userEmail;
  String? get userName => _userName;
  String? get userRole => _userRole;
  String? get errorMessage => _errorMessage;
  int? get insId => _insId;
  String? get inscode => _inscode;
  String? get insName => _insName;
  String? get insLogo => _insLogo;
  String? get insAddress => _insAddress;
  String? get yearLabel => _yearLabel;
  InstitutionUserModel? get currentUser => _currentUser;
  String? get sessionToken => _sessionToken;

  Future<bool> login(String email, String password, {int? insId, bool isSuperAdmin = false, String? yearLabel}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final user = await SupabaseService.loginUser(
        email: email,
        password: password,
        insId: insId,
        isSuperAdmin: isSuperAdmin,
        selectedYearLabel: yearLabel,
      );

      if (user != null) {
        // Populate identification fields up front (before the subscription
        // gate) so the Subscription Expired screen can prefill the renewal
        // request with insName / inscode / email instead of "(unknown)".
        _userEmail = user.usemail;
        _userName = user.usename;
        _insId = user.insId;
        _inscode = user.inscode;
        if (user.insId != null) {
          try {
            final insInfo = await SupabaseService.getInstitutionInfo(user.insId!);
            _insName = insInfo.name;
            _insLogo = insInfo.logo;
            _insAddress = insInfo.address;
          } catch (_) {/* non-fatal — keep going */}
        }

        // Subscription gating removed: activation codes are only consumed
        // at institution creation. After that, users may log into any year
        // they have a row for — including past years whose iyrenddate has
        // elapsed — so they can keep viewing historical data without a
        // renewal flow. The product-license gate in splash handles app-
        // wide expiry separately.
        _subscriptionActive = !isSuperAdmin && user.insId != null;

        _isAuthenticated = true;
        _isSuperAdmin = isSuperAdmin;
        _currentUser = user;
        _userRole = isSuperAdmin ? 'Super Admin' : user.desname;

        // The server-side session was minted by loginUser right after the
        // password check (the server refuses the app's requests without one),
        // so it is already on SupabaseService.sessionToken.
        _sessionToken = SupabaseService.sessionToken;

        _isLoading = false;
        notifyListeners();

        // Set schema for institution-scoped queries. The institution info
        // (insName/insLogo/insAddress) was already fetched up front before
        // the subscription gate, so we don't re-fetch here.
        if (user.insId != null) {
          // Fetch schema name from institution table
          final insRow = await SupabaseService.client
              .from('institution')
              .select('inshortname')
              .eq('ins_id', user.insId!)
              .maybeSingle();
          if (insRow != null && insRow['inshortname'] != null) {
            // Build schema name: shortname + year (e.g. kcet20262027)
            final selectedYear = yearLabel ?? await _fetchYearLabel(user.insId!);
            final shortName = (insRow['inshortname'] as String).toLowerCase();
            _schema = '$shortName${selectedYear.replaceAll('-', '')}';
            SupabaseService.setSchema(_schema);
            _yearLabel = selectedYear;
            // server-side RPCs follow the year picked at login
            await SupabaseService.setSessionYear(selectedYear);
            await SupabaseService.masterTablesReady;
            // Schema exposure used to run here on every login — moved to the
            // registration flow only, so we don't hit the RPC thousands of
            // times/day for schemas that are already exposed. If a schema
            // isn't exposed PostgREST will surface a clear PGRST106 error.
          }
          notifyListeners();
        }

        return true;
      } else {
        _errorMessage = SupabaseService.lastLoginError ?? 'Invalid email or password. Please try again.';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = friendlyError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> register(
      String name, String email, String password, String role) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // For now, registration is handled by the admin creating users in Supabase
      _errorMessage =
          'Registration is managed by the institution admin. Please contact your administrator.';
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = friendlyError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> resetPassword(String email) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    // Password reset would need to be handled via Supabase or admin
    _isLoading = false;
    notifyListeners();
  }

  /// Closing the app ends the session: the password is required again on the
  /// next launch. This wipes any password left on disk by an older build that
  /// did auto-login — both the secure-storage copy and the legacy plaintext one
  /// in SharedPreferences — so upgrading actually removes it rather than
  /// leaving it sitting there unused.
  ///
  /// The email is deliberately kept, only to pre-fill the login field.
  Future<void> forgetSavedPassword() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPassword);
    try {
      await _secureStorage.delete(key: _kPassword);
    } catch (_) {
      // Secure storage can be unavailable on a locked profile; the plaintext
      // copy is gone either way, which is the part that matters.
    }
  }

  /// The last email that signed in on this machine, for pre-filling the login
  /// form. Never a password.
  Future<String?> savedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kEmail);
    return (v == null || v.isEmpty) ? null : v;
  }

  /// What the sign-in card pre-fills when "Remember Me" was ticked: the last
  /// email, institution and access type. Never a password.
  Future<({String? email, int? insId, bool superAdmin})> savedLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString(_kEmail);
    return (
      email: (email == null || email.isEmpty) ? null : email,
      insId: prefs.getInt(_kInsId),
      superAdmin: prefs.getBool(_kIsSuperAdmin) ?? false,
    );
  }

  /// The sign-in card's "Remember Me" tick (on by default).
  Future<bool> rememberMe() async =>
      (await SharedPreferences.getInstance()).getBool(_kRememberMe) ?? true;

  Future<void> setRememberMe(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_kRememberMe, value);

  /// Save credentials for auto-login on next launch
  Future<void> saveCredentials(String email, String password, {int? insId, bool isSuperAdmin = false, String? yearLabel}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEmail, email);
    // The password is NOT stored. Every launch asks for it again.
    await prefs.setBool(_kIsSuperAdmin, isSuperAdmin);
    if (insId != null) {
      await prefs.setInt(_kInsId, insId);
    }
    if (_schema != null) {
      await prefs.setString(_kSchema, _schema!);
    }
    if (yearLabel != null && yearLabel.isNotEmpty) {
      await prefs.setString(_kYearLabel, yearLabel);
    }
  }

  /// Clear saved credentials (call on logout)
  Future<void> clearCredentials() async {
    // Revoke the server-side session so the token can't be reused after logout.
    if (_sessionToken != null) {
      try { await SupabaseService.revokeSession(_sessionToken!); } catch (_) {}
      _sessionToken = null;
    }
    SupabaseService.sessionToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kEmail);
    await prefs.remove(_kPassword); // remove any legacy plaintext copy too
    await prefs.remove(_kInsId);
    await prefs.remove(_kSchema);
    await prefs.remove(_kYearLabel);
    await _secureStorage.delete(key: _kPassword);
  }

  /// The dashboard's year switch: screens that re-apply [schema] on open
  /// (Misc / Advance Collection, reports ...) and the server session must all
  /// follow the year now on screen, not the one picked at login.
  Future<void> switchYear(String schema, String yearLabel) async {
    _schema = schema;
    _yearLabel = yearLabel;
    SupabaseService.setSchema(schema);
    await SupabaseService.masterTablesReady;
    await SupabaseService.setSessionYear(yearLabel);
    notifyListeners();
  }

  Future<void> logout() async {
    await clearCredentials();
    _isAuthenticated = false;
    _subscriptionActive = false;
    _isSuperAdmin = false;
    _schema = null;
    SupabaseService.setSchema(null);
    _currentUser = null;
    _userEmail = null;
    _userName = null;
    _userRole = null;
    _insId = null;
    _inscode = null;
    _insName = null;
    _insLogo = null;
    _insAddress = null;
    _yearLabel = null;
    _errorMessage = null;
    notifyListeners();
  }

  Future<String> _fetchYearLabel(int insId) async {
    try {
      final result = await SupabaseService.client
          .from('institutionyear')
          .select('yrlabel')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('yrlabel', ascending: false)
          .limit(1)
          .maybeSingle();
      if (result != null && result['yrlabel'] != null) {
        return result['yrlabel'] as String;
      }
    } catch (e) {
      debugPrint('Fetch year label error: $e');
    }
    // Fallback: try year table
    try {
      final result = await SupabaseService.client
          .from('year')
          .select('yrlabel')
          .eq('ins_id', insId)
          .eq('activestatus', 1)
          .order('yr_id', ascending: false)
          .limit(1)
          .maybeSingle();
      if (result != null && result['yrlabel'] != null) {
        return result['yrlabel'] as String;
      }
    } catch (_) {}
    return '${DateTime.now().year}-${DateTime.now().year + 1}';
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

}
