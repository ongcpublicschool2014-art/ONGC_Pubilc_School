import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

/// The gateway a payment will go through (Setup > Payment Gateways).
class OnlineGateway {
  final int pgId;
  final String provider, name, mode;
  const OnlineGateway(this.pgId, this.provider, this.name, this.mode);
  bool get isTest => mode == 'TEST';
}

/// A started online payment: our order id and what the app needs to open the
/// gateway's page. [checkout]['kind'] is paytm / razorpay / cashfree / redirect.
class OnlineOrder {
  final String orderId, provider, mode;
  final int payId;
  final double amount;
  final Map<String, dynamic> checkout;
  const OnlineOrder({
    required this.orderId,
    required this.payId,
    required this.amount,
    required this.provider,
    required this.mode,
    required this.checkout,
  });
}

/// The server's answer on an order. Only C, F and X are final:
/// C = paid and receipted, F = not paid, X = paid at the gateway but not
/// receipted (the office must look at it), I = not decided yet.
class OnlinePayResult {
  final String status;
  final List<Map<String, dynamic>> receipts;
  final String note;
  /// What the gateway itself said: captured / failed / pending / not_found.
  /// "pending" = money may still be moving; "not_found" = nobody has paid.
  final String gateway;
  const OnlinePayResult(this.status, {this.receipts = const [], this.note = '', this.gateway = ''});
  /// C paid, F not paid, X paid-no-receipt, T test payment, H closed by office.
  bool get isFinal => status == 'C' || status == 'F' || status == 'X' || status == 'T' || status == 'H';
  bool get moneyMayBeMoving => gateway == 'pending';

  String get receiptNumbers => receipts
      .map((r) => r['paynumber']?.toString() ?? '')
      .where((s) => s.isNotEmpty)
      .join(', ');

  int? get firstPayId {
    for (final r in receipts) {
      final v = r['pay_id'];
      final id = v is int ? v : int.tryParse('${v ?? ''}');
      if (id != null) return id;
    }
    return null;
  }
}

/// Online fee payments for any gateway, through the server functions
/// pay-create and pay-status (supabase/functions/). The server decides the
/// amount and the gateway and raises the receipt; the app only opens the
/// gateway's page and asks how it went.
class OnlinePaymentService {
  OnlinePaymentService._();
  static String? get _token => SupabaseService.sessionToken;

  /// The gateway these fee groups pay into, or null when the school has none
  /// set up. [fgIds] null asks for the school's default gateway.
  ///
  /// Fails CLOSED: only "not set up" returns null. Any other error (network,
  /// session) is thrown, so a school that has a gateway is never sent down
  /// an older payment path just because the lookup failed.
  static Future<OnlineGateway?> gatewayFor([List<int>? fgIds]) async {
    try {
      final r = await SupabaseService.client.rpc('pg_for_payment',
          params: {'p_token': _token, 'p_fg_ids': fgIds});
      if (r is! Map) return null;
      return OnlineGateway((r['pg_id'] as num).toInt(), '${r['provider']}',
          '${r['name'] ?? r['provider']}', '${r['mode'] ?? 'LIVE'}');
    } on PostgrestException catch (e) {
      if (e.message.toLowerCase().contains('not set up')) return null;
      rethrow;
    }
  }

  /// Why [gatewayFor] would refuse these fee groups, in the server's words.
  static Future<String?> gatewayProblem(List<int> fgIds) async {
    try {
      await SupabaseService.client.rpc('pg_for_payment',
          params: {'p_token': _token, 'p_fg_ids': fgIds});
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// [items]: [{dem_id, amount (incl. fine), fine}].
  static Future<OnlineOrder> start({
    required int stuId,
    required List<Map<String, dynamic>> items,
    String channel = 'COUNTER',
  }) async {
    final r = await _invoke('pay-create',
        {'token': _token, 'stu_id': stuId, 'items': items, 'channel': channel});
    return OnlineOrder(
      orderId: '${r['order_id']}',
      payId: (r['pay_id'] as num).toInt(),
      amount: (r['amount'] as num).toDouble(),
      provider: '${r['provider']}',
      mode: '${r['mode'] ?? ''}',
      checkout: Map<String, dynamic>.from(r['checkout'] as Map),
    );
  }

  /// A counter collection (MISC / ADVANCE / ADVFEE): [request] = {header,
  /// lines} as the screen's save takes them. The server saves it on capture.
  static Future<OnlineOrder> startOther({
    required String kind,
    int? stuId,
    required Map<String, dynamic> request,
    String channel = 'COUNTER',
  }) async {
    final r = await _invoke('pay-create', {
      'token': _token,
      'kind': kind,
      'stu_id': stuId,
      'request': request,
      'channel': channel,
    });
    return OnlineOrder(
      orderId: '${r['order_id']}',
      payId: (r['pay_id'] as num?)?.toInt() ?? 0,
      amount: (r['amount'] as num).toDouble(),
      provider: '${r['provider']}',
      mode: '${r['mode'] ?? ''}',
      checkout: Map<String, dynamic>.from(r['checkout'] as Map),
    );
  }

  /// Asks the server, which asks the gateway. Never trusts the browser.
  /// [cancel]: the payer backed out. The server still asks the gateway first
  /// and closes the order only if nothing was paid.
  static Future<OnlinePayResult> status(String orderId, {bool cancel = false}) async {
    final r = await _invoke('pay-status',
        {'token': _token, 'order_id': orderId, if (cancel) 'cancel': true});
    final raw = r['receipts'];
    final list = raw is List ? raw : (raw is Map ? [raw] : const []);
    return OnlinePayResult(
      '${r['status'] ?? 'I'}',
      receipts: [for (final x in list) if (x is Map) Map<String, dynamic>.from(x)],
      note: '${r['note'] ?? r['reason'] ?? ''}',
      gateway: '${r['gateway'] ?? ''}',
    );
  }

  /// Cash / cheque guard: the fees among [demIds] held by an online payment
  /// that is not settled. [{dem_id, order_id, status}].
  static Future<List<Map<String, dynamic>>> feesHeld(int stuId, List<int> demIds) async {
    final r = await SupabaseService.client.rpc('online_fees_held',
        params: {'p_token': _token, 'p_stu_id': stuId, 'p_dem_ids': demIds});
    return [for (final x in (r as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
  }

  /// Online payments the gateway took but that have no receipt (office).
  static Future<List<Map<String, dynamic>>> attention() async {
    final r = await SupabaseService.client.rpc('online_orders_attention', params: {'p_token': _token});
    return [for (final x in (r as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
  }

  /// Try the receipt again (after the office fixed what stopped it).
  static Future<OnlinePayResult> retry(String orderId) async {
    await SupabaseService.client.rpc('online_order_retry', params: {'p_token': _token, 'p_order_id': orderId});
    return status(orderId);
  }

  /// Dealt with by hand (refunded / receipted at the counter); [note] says how.
  static Future<void> markHandled(String orderId, String note) =>
      SupabaseService.client.rpc('online_order_handled',
          params: {'p_token': _token, 'p_order_id': orderId, 'p_note': note});

  static Future<Map<String, dynamic>> _invoke(String fn, Map<String, dynamic> body) async {
    try {
      final r = await SupabaseService.client.functions.invoke(fn, body: body);
      if (r.data is Map) {
        final m = Map<String, dynamic>.from(r.data as Map);
        if (m['error'] != null) throw OnlinePaymentException('${m['error']}', code: '${m['code'] ?? ''}');
        return m;
      }
      throw const OnlinePaymentException('No answer from the payment server.');
    } on FunctionException catch (e) {
      final d = e.details;
      if (d is Map && d['error'] != null) throw OnlinePaymentException('${d['error']}', code: '${d['code'] ?? ''}');
      // The platform's own errors (busy, crashed) come as {code, message}.
      final why = d is Map && d['message'] != null ? ': ${d['message']}' : '';
      throw OnlinePaymentException(e.status >= 500
          ? 'The payment server could not complete this (${e.status}$why). Nothing was collected. Please try again.'
          : 'Payment server error (${e.status}$why). Please try again.');
    }
  }
}

class OnlinePaymentException implements Exception {
  final String message;
  /// The server's error code: P0002 = a payment for this student / fee is
  /// still being confirmed, P0003 = paid online but the receipt is pending.
  final String code;
  const OnlinePaymentException(this.message, {this.code = ''});

  /// The order the message names, e.g. S1P12T1793768012686.
  String? get orderId => RegExp(r'S\d+P\d+T\d+').firstMatch(message)?.group(0);
  @override
  String toString() => message;
}
