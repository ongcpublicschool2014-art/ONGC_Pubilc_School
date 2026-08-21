import 'package:http/http.dart' as http;
import '../services/supabase_service.dart';

/// HTTP client that attaches the current app session token as an `x-app-token`
/// header on EVERY Supabase request (REST + RPC + Functions).
///
/// The server's `db-pre-request` hook (`public.app_pre_request`) reads this
/// header, validates it against `app_session`, and sets a request-local
/// `app.ins_id` GUC that RLS policies filter on — enforcing per-tenant reads
/// without the app having to route every read through an RPC. When there is no
/// token (logged out), no header is sent and RLS-protected tables return no rows.
///
/// The token is read live from [SupabaseService.sessionToken], which
/// AuthProvider keeps current across login/logout — so a single client instance
/// injected at init stays correct for the whole session.
class AppTokenHttpClient extends http.BaseClient {
  final http.Client _inner;
  AppTokenHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final token = SupabaseService.sessionToken;
    if (token != null && token.isNotEmpty) {
      request.headers['x-app-token'] = token;
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
