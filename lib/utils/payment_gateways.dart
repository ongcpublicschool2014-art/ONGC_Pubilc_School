import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';

/// One setting a payment gateway needs. [secret] fields are saved encrypted
/// (Supabase Vault) and never shown again; the others are plain settings.
class PgField {
  final String key, label, hint;
  final bool secret, required;
  const PgField(this.key, this.label, {this.hint = '', this.secret = false, this.required = true});
}

/// A supported gateway: what the school must enter for it. Adding a gateway
/// here adds it to Setup > Payment Gateways; its server adapter lives in
/// supabase/functions/_shared/gateways/.
class PgProvider {
  final String code, name, help;
  final List<PgField> fields;
  const PgProvider(this.code, this.name, this.fields, {this.help = ''});

  List<PgField> get publicFields => fields.where((f) => !f.secret).toList();
  List<PgField> get secretFields => fields.where((f) => f.secret).toList();
}

const List<PgProvider> kPgProviders = [
  PgProvider('PAYTM', 'Paytm', [
    PgField('mid', 'Merchant ID (MID)', hint: 'From the Paytm dashboard, API Keys'),
    PgField('website', 'Website Name', hint: 'WEBSTAGING for Test, DEFAULT for Live'),
    PgField('host', 'Gateway Host', required: false,
        hint: 'Blank = secure.paytmpayments.com. Older accounts: securegw.paytm.in (Live) / securegw-stage.paytm.in (Test)'),
    PgField('merchant_key', 'Merchant Key', secret: true),
  ], help: 'Paytm dashboard > Developer Settings > API Keys.'),
  PgProvider('RAZORPAY', 'Razorpay', [
    PgField('key_id', 'Key ID', hint: 'rzp_test_... or rzp_live_...'),
    PgField('key_secret', 'Key Secret', secret: true),
    PgField('webhook_secret', 'Webhook Secret', secret: true, required: false, hint: 'Set when you add the webhook in Razorpay'),
  ], help: 'Razorpay dashboard > Account & Settings > API Keys.'),
  PgProvider('PHONEPE', 'PhonePe', [
    PgField('client_id', 'Client ID'),
    PgField('client_version', 'Client Version', hint: 'Usually 1'),
    PgField('merchant_id', 'Merchant ID', required: false),
    PgField('client_secret', 'Client Secret', secret: true),
    PgField('webhook_username', 'Webhook Username', secret: true, required: false),
    PgField('webhook_password', 'Webhook Password', secret: true, required: false),
  ], help: 'PhonePe Business dashboard > Developer Settings (Payment Gateway, Standard Checkout).'),
  PgProvider('CASHFREE', 'Cashfree', [
    PgField('app_id', 'App ID (Client ID)'),
    PgField('secret_key', 'Secret Key (Client Secret)', secret: true),
  ], help: 'Cashfree merchant dashboard > Developers > API Keys (Payment Gateway).'),
  PgProvider('EASEBUZZ', 'Easebuzz', [
    PgField('merchant_key', 'Merchant Key'),
    PgField('salt', 'Salt', secret: true),
  ], help: 'Easebuzz dashboard > Settings > API Keys.'),
];

/// What a bank's settlement account is called at this gateway, or null when
/// the gateway cannot split a payment (PhonePe).
String? pgSplitLabel(String provider) => switch (provider.toUpperCase()) {
      'RAZORPAY' => 'Linked Account ID (acc_...)',
      'CASHFREE' => 'Vendor ID',
      'PAYTM' => 'Child MID',
      'EASEBUZZ' => 'Split Label',
      _ => null,
    };

PgProvider? pgProvider(String code) => kPgProviders.where((p) => p.code == code.toUpperCase()).firstOrNull;

/// The last four characters of a merchant id, for showing on screen.
String pgMaskId(String id) => id.length > 4 ? '••${id.substring(id.length - 4)}' : id;

/// [id] is the gateway's own main merchant: paying to it is not a split.
bool pgIsMainMerchantId(Map<String, dynamic> gateway, String id) {
  final cfg = (gateway['config'] as Map?) ?? const {};
  final t = id.trim();
  return t.isNotEmpty && (t == '${cfg['mid'] ?? ''}'.trim() || t == '${cfg['merchant_id'] ?? ''}'.trim());
}

/// What is wrong with a sub-account id at this gateway, or null when it is
/// usable. The same rules online_pay_start applies, but said when the bank is
/// saved instead of when a parent is trying to pay.
String? pgMerchantIdError(Map<String, dynamic> gateway, String id) {
  final provider = '${gateway['provider'] ?? ''}'.toUpperCase();
  final name = pgProvider(provider)?.name ?? provider;
  if (provider == 'PHONEPE') return 'PhonePe cannot split a payment between accounts, so this bank cannot have a Merchant ID.';
  if (provider == 'RAZORPAY' && !RegExp(r'^acc_[A-Za-z0-9]+$').hasMatch(id.trim())) {
    return 'A Razorpay Linked Account ID starts with acc_ (for example acc_Abc123).';
  }
  if (pgIsMainMerchantId(gateway, id)) return 'This is the main $name account. Choose "Main $name account" instead.';
  return null;
}

enum OnlineRouteKind { cashOnly, noGateway, main, subAccount, ownMerchant, problem }

/// Where a fee group's online money really goes.
class OnlineRoute {
  final OnlineRouteKind kind;
  final String text; // short, for a chip
  final String detail; // one sentence
  const OnlineRoute(this.kind, this.text, this.detail);

  /// Online payments for this fee group will work.
  bool get ready =>
      kind == OnlineRouteKind.main || kind == OnlineRouteKind.subAccount || kind == OnlineRouteKind.ownMerchant;
}

/// The same decision online_pay_start makes for a fee group's bank.
OnlineRoute onlineRouteFor({
  required Map<String, dynamic>? gateway,
  required Map<String, dynamic>? bank,
  Map<int, Map<String, dynamic>> bankMerchants = const {},
}) {
  if (bank == null) {
    return const OnlineRoute(OnlineRouteKind.cashOnly, 'Cash only', 'No bank account, so only Cash can be collected for this group.');
  }
  if (gateway == null) {
    return const OnlineRoute(OnlineRouteKind.noGateway, 'Online not set up',
        'Set up the gateway in Setup → Payment Gateways to take online payments.');
  }
  final provider = '${gateway['provider'] ?? ''}'.toUpperCase();
  final name = pgProvider(provider)?.name ?? provider;
  final id = '${bank['paytm_mid'] ?? ''}'.trim();
  final own = bankMerchants[(bank['ban_id'] as num?)?.toInt() ?? -1];
  if (own != null && '${own['provider'] ?? ''}'.toUpperCase() == provider && own['has_secret'] == true) {
    return OnlineRoute(OnlineRouteKind.ownMerchant, 'Separate $name merchant ${pgMaskId(id)}',
        'Online payments go to this separate $name merchant, as their own payment: fees of other merchants cannot be paid together with them.');
  }
  if (id.isEmpty || pgIsMainMerchantId(gateway, id)) {
    return OnlineRoute(OnlineRouteKind.main, 'Main $name account',
        'Online payments go to the main $name account. Other payment modes are recorded against this bank.');
  }
  final err = pgMerchantIdError(gateway, id);
  if (err != null) return OnlineRoute(OnlineRouteKind.problem, 'Merchant ID needs fixing', err);
  return OnlineRoute(OnlineRouteKind.subAccount, '$name sub-account ${pgMaskId(id)}',
      "Online payments are split to this bank's ${pgSplitLabel(provider) ?? 'sub-account'}.");
}

/// Setup > Payment Gateways (C:/pg_backups/school_payment_gateways.sql).
class PaymentGatewayService {
  PaymentGatewayService._();
  static String? get _token => SupabaseService.sessionToken;

  /// {gateways: [...], routes: [{fg_id, pg_id}]}. Secrets are never returned.
  static Future<Map<String, dynamic>> list() async =>
      Map<String, dynamic>.from(await SupabaseService.client.rpc('pg_list', params: {'p_token': _token}) as Map);

  /// [secret] null keeps the saved secret; otherwise replaces it.
  static Future<int> save({
    int? pgId,
    required String provider,
    required String name,
    required String mode,
    required Map<String, String> config,
    Map<String, String>? secret,
    bool isDefault = false,
  }) async {
    final r = await SupabaseService.client.rpc('pg_save', params: {
      'p_token': _token,
      'p_pg_id': pgId,
      'p_provider': provider,
      'p_name': name,
      'p_mode': mode,
      'p_config': config,
      'p_secret': secret,
      'p_is_default': isDefault,
    });
    return (r as num).toInt();
  }

  /// Banks that are their own merchant at the gateway: {ban_id: {provider, config, has_secret}}.
  static Future<Map<int, Map<String, dynamic>>> bankMerchants() async {
    final r = await SupabaseService.client.rpc('pg_bank_merchants', params: {'p_token': _token});
    return {
      for (final x in (r as List? ?? const []))
        ((x as Map)['ban_id'] as num).toInt(): Map<String, dynamic>.from(x),
    };
  }

  /// The bank's own keys ([secret] null keeps the saved ones).
  static Future<void> saveBankMerchant(int banId, Map<String, String> config, Map<String, String>? secret) =>
      SupabaseService.client.rpc('pg_bank_merchant_save',
          params: {'p_token': _token, 'p_ban_id': banId, 'p_config': config, 'p_secret': secret});

  static Future<void> deleteBankMerchant(int banId) =>
      SupabaseService.client.rpc('pg_bank_merchant_delete', params: {'p_token': _token, 'p_ban_id': banId});

  static Future<void> delete(int pgId) =>
      SupabaseService.client.rpc('pg_delete', params: {'p_token': _token, 'p_pg_id': pgId});

  static Future<void> setRoute(int fgId, int? pgId) =>
      SupabaseService.client.rpc('pg_set_route', params: {'p_token': _token, 'p_fg_id': fgId, 'p_pg_id': pgId});

  /// Keeps the result of Test Connection on the gateway, for the setup status.
  static Future<void> noteTest(int pgId, bool ok, String note) => SupabaseService.client
      .rpc('pg_note_test', params: {'p_token': _token, 'p_pg_id': pgId, 'p_ok': ok, 'p_note': note});

  /// Asks the gateway to accept the saved credentials (server function
  /// pg-test). Returns the gateway's answer.
  /// [banId]: test that bank's own merchant account instead of the main one.
  static Future<({bool ok, String message})> test(int pgId, {int? banId}) async {
    try {
      final r = await SupabaseService.client.functions
          .invoke('pg-test', body: {'pg_id': pgId, 'token': _token, if (banId != null) 'ban_id': banId});
      final m = r.data is Map ? Map<String, dynamic>.from(r.data as Map) : const <String, dynamic>{};
      return (ok: m['ok'] == true, message: '${m['message'] ?? 'No answer from the gateway.'}');
    } on FunctionException catch (e) {
      final d = e.details;
      if (d is Map && d['message'] != null && d['ok'] == false) return (ok: false, message: '${d['message']}');
      if (e.status == 404) {
        return (ok: false, message: 'The test could not run: the payment server functions are not deployed on this server.');
      }
      if (e.status >= 500) {
        return (ok: false, message: 'The payment server is busy or briefly unavailable (${e.status}). Try again in a minute.');
      }
      return (ok: false, message: 'The test could not run (${e.status}).');
    } catch (e) {
      return (ok: false, message: 'The test could not run: no connection to the payment server. Check the internet.');
    }
  }
}
