import 'package:flutter/foundation.dart';
import '../config/paytm_config.dart';
import 'supabase_service.dart';

/// Result of a Paytm "Initiate Transaction" call.
class PaytmOrder {
  final String orderId;
  final String txnToken;
  final String amount; // rupees, 2 decimals (e.g. "1500.00")
  final String mid; // the merchant the order was created under

  const PaytmOrder({
    required this.orderId,
    required this.txnToken,
    required this.amount,
    required this.mid,
  });
}

/// Status of a Paytm transaction, normalised to the same vocabulary the
/// existing Razorpay polling loop uses.
class PaytmStatus {
  /// 'captured' | 'failed' | 'pending'
  final String status;

  /// Paytm txnId — stored as `payreference` on success.
  final String? paymentId;

  const PaytmStatus({required this.status, this.paymentId});

  bool get isCaptured => status == 'captured';
  bool get isFailed => status == 'failed';
}

/// Client-side helper for the Paytm JS Checkout flow.
///
/// All signing happens server-side in the `create-paytm-order` and
/// `get-paytm-payment` edge functions — this service only orchestrates the
/// calls and builds the checkout HTML the WebView renders. It deliberately
/// mirrors the shape of the Razorpay flow in student_fee_collection_screen.dart.
class PaytmService {
  PaytmService._();

  /// Initiate a transaction. The payment row (status 'I') must already exist;
  /// pass its [payId]. Returns the order id + txnToken for the checkout page.
  /// [mid] is the merchant resolved for this payment via
  /// SupabaseService.getPaytmMidForFeeGroups (the fee group's bank.paytm_mid).
  ///
  /// Routing depends on PaytmConfig.splitSettlement:
  ///   * false (single-account): [mid] is used directly as the order MID; when
  ///     null the edge function falls back to the default MID.
  ///   * true  (per-unit split): the order is created under the parent/default
  ///     MID and [mid] becomes the CHILD MID that funds settle to, sent as
  ///     `split_mid` so the edge function attaches splitSettlementInfo. A null
  ///     [mid] means no split (funds stay with the parent) — a safe fallback.
  static Future<PaytmOrder> createOrder({
    required int payId,
    required double amount,
    String? custId,
    String? orderId,
    String? mid,
  }) async {
    // In split mode the resolved unit MID is the settlement target, not the
    // order MID (we only hold the parent's API key, so the order must be
    // created under the parent/default merchant).
    final String? orderMid = PaytmConfig.splitSettlement ? null : mid;
    final String? splitMid = PaytmConfig.splitSettlement ? mid : null;
    final resp = await SupabaseService.client.functions.invoke(
      'create-paytm-order',
      body: {
        'amount': amount,
        'pay_id': payId,
        if (custId != null) 'cust_id': custId,
        if (orderId != null) 'order_id': orderId,
        if (orderMid != null) 'mid': orderMid,
        if (splitMid != null) 'split_mid': splitMid,
      },
    );

    final data = resp.data is Map<String, dynamic>
        ? resp.data as Map<String, dynamic>
        : <String, dynamic>{};

    final token = data['txn_token']?.toString();
    final order = data['order_id']?.toString();
    if (token == null || token.isEmpty || order == null || order.isEmpty) {
      throw Exception(
        'Paytm order initiation failed: ${data['error'] ?? data['result_info'] ?? data}',
      );
    }

    return PaytmOrder(
      orderId: order,
      txnToken: token,
      amount: data['amount']?.toString() ?? amount.toStringAsFixed(2),
      // Trust the MID the server actually created the order under (the parent
      // in split mode); fall back to the order MID / default, never the child.
      mid: data['mid']?.toString() ?? orderMid ?? PaytmConfig.mid,
    );
  }

  /// Authoritative status check via the Transaction Status API. [mid] must be
  /// the merchant the order was created under (PaytmOrder.mid).
  static Future<PaytmStatus> verifyPayment(String orderId, {String? mid}) async {
    final resp = await SupabaseService.client.functions.invoke(
      'get-paytm-payment',
      body: {
        'order_id': orderId,
        if (mid != null) 'mid': mid,
      },
    );
    final data = resp.data is Map<String, dynamic>
        ? resp.data as Map<String, dynamic>
        : <String, dynamic>{};
    final status = data['status']?.toString() ?? 'pending';
    final paymentId = data['payment_id']?.toString();
    return PaytmStatus(
      status: status,
      paymentId: (paymentId != null && paymentId.isNotEmpty) ? paymentId : null,
    );
  }

  /// Build the local checkout HTML loaded into the WebView. The merchant JS
  /// Checkout SDK is fetched from Paytm; we only hand it the txnToken/orderId.
  static String buildCheckoutHtml({
    required PaytmOrder order,
    String studentName = '',
    String studentMobile = '',
    String studentEmail = '',
    String merchantName = 'KCET',
  }) {
    final mid = order.mid;
    final sdkUrl = PaytmConfig.checkoutJsUrlFor(mid);
    final safeName = studentName.replaceAll("'", "\\'");
    // Merchant display name is injected into a double-quoted JSON string inside
    // the checkout JS, so escape backslashes/quotes and flatten newlines.
    // Falls back to 'KCET' when the institution name is unavailable.
    final rawMerchant = merchantName.trim().isEmpty ? 'KCET' : merchantName.trim();
    final safeMerchant = rawMerchant
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll(RegExp(r'[\r\n]+'), ' ');

    return '''
<!DOCTYPE html>
<html>
<head>
  <title>$rawMerchant - Fee Payment</title>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: Arial, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
    .container { text-align: center; padding: 40px; }
    .info { color: #666; margin-top: 10px; }
  </style>
  <!-- Define the handler BEFORE the SDK <script> so it exists when onload fires. -->
  <script type="application/javascript">
    // Forward JS errors/diagnostics to Flutter (webMessageReceived) so a stuck
    // checkout can be diagnosed from the run log.
    function post(m) { try { window.chrome.webview.postMessage(String(m)); } catch (e) {} }
    window.onerror = function(msg, src, line) { post('JSERR: ' + msg + ' @ ' + (src || '') + ':' + (line || '')); };
    function showStatus(msg) {
      var el = document.getElementById('status');
      if (el) el.innerHTML = '<p class="info">' + msg + '</p>';
    }
    function onScriptLoad() {
      post('onScriptLoad; hasCheckoutJS=' + !!(window.Paytm && window.Paytm.CheckoutJS));
      var config = {
        "root": "",
        "flow": "DEFAULT",
        "merchant": { "mid": "$mid", "name": "$safeMerchant", "redirect": false },
        "data": {
          "orderId": "${order.orderId}",
          "token": "${order.txnToken}",
          "tokenType": "TXN_TOKEN",
          "amount": "${order.amount}",
          "userDetail": {
            "name": "$safeName",
            "mobile": "$studentMobile",
            "email": "$studentEmail"
          }
        },
        "handler": {
          "notifyMerchant": function(eventName, data) {
            console.log("notifyMerchant", eventName, data);
          },
          // Required when merchant.redirect = false. The Flutter side polls
          // get-paytm-payment for the authoritative result and closes the
          // dialog, so here we just surface progress and close the checkout UI.
          "transactionStatus": function(paymentStatus) {
            console.log("transactionStatus", paymentStatus);
            showStatus('Payment submitted. Verifying with the bank...');
            try { window.Paytm.CheckoutJS.close(); } catch (e) {}
          }
        }
      };
      if (window.Paytm && window.Paytm.CheckoutJS) {
        // The merchant .js loads the real CheckoutJS library asynchronously —
        // onLoad fires only once it's fully ready, so init/invoke won't run
        // too early (the cause of a stuck "Opening..." screen).
        window.Paytm.CheckoutJS.onLoad(function checkoutReady() {
          post('onLoad fired; calling init');
          window.Paytm.CheckoutJS.init(config)
            .then(function onSuccess() { post('init OK; invoking'); window.Paytm.CheckoutJS.invoke(); post('invoke called'); })
            .catch(function onError(error) {
              post('INIT_ERR: ' + (error && error.message ? error.message : JSON.stringify(error)));
              showStatus('Unable to open Paytm checkout: ' + error);
              console.error("CheckoutJS init error", error);
            });
        });
      } else {
        post('SDK not loaded (window.Paytm.CheckoutJS missing)');
        showStatus('Paytm SDK did not load. Please close and retry.');
      }
    }
  </script>
  <script type="application/javascript" crossorigin="anonymous" src="$sdkUrl" onload="onScriptLoad();"></script>
</head>
<body>
  <div class="container" id="status">
    <p class="info">Opening Paytm Checkout...</p>
  </div>
</body>
</html>
''';
  }

  /// Convenience: is the gateway configured enough to attempt a payment?
  static bool get isConfigured {
    final ok = PaytmConfig.mid.isNotEmpty;
    if (!ok) debugPrint('PaytmService: MID is empty — check PaytmConfig.');
    return ok;
  }
}
