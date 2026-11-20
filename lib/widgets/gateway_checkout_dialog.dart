import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart'
    if (dart.library.html) '../screens/fees/webview_windows_stub.dart';
import '../services/online_payment_service.dart';
import '../utils/app_theme.dart';
import '../utils/formatters.dart';
import 'app_ui.dart';

/// Opens the school's payment gateway (whichever one Setup > Payment Gateways
/// chose) for [order] and waits for the server's verdict.
///
/// Returns the server's answer: C paid and receipted, F not paid, X paid but
/// not receipted, I not decided yet (the window was closed while the bank was
/// still working; the server receipts it later on its own). Returns null only
/// when the window could not open at all.
///
/// The verdict always comes from pay-status, which asks the gateway with the
/// school's key; nothing the page itself reports is trusted.
Future<OnlinePayResult?> showGatewayCheckout(
  BuildContext context, {
  required OnlineOrder order,
  required String gatewayName,
  String payerName = '',
  String payerMobile = '',
  String payerEmail = '',
  String merchantName = '',
  Duration pollInterval = const Duration(seconds: 4),
  Duration pollMaxDuration = const Duration(minutes: 15),
}) async {
  final completer = Completer<OnlinePayResult?>();
  final controller = WebviewController();
  Timer? pollTimer;
  HttpServer? pageServer;
  var polling = false;

  /// True once the payer has done something at the gateway (left our page for
  /// a bank page, or the gateway reported a payment event). Closing after that
  /// is no longer free: the bank may still debit.
  var paymentStarted = false;
  final failureMsg = ValueNotifier<String?>(null);

  void finish(OnlinePayResult? r) {
    pollTimer?.cancel();
    if (!completer.isCompleted) completer.complete(r);
  }

  Future<OnlinePayResult?> ask({bool cancel = false}) async {
    try {
      return await OnlinePaymentService.status(order.orderId, cancel: cancel);
    } catch (e) {
      debugPrint('pay-status ${order.orderId}: $e');
      return null;
    }
  }

  /// One poll. Final answers end the window, except a failure after the payer
  /// tried: that is shown, so a decline never looks like the app closing.
  Future<void> poll() async {
    if (polling || completer.isCompleted) return;
    polling = true;
    try {
      final r = await ask();
      if (r == null || !r.isFinal) return;
      if (r.status == 'F' && paymentStarted) {
        pollTimer?.cancel();
        failureMsg.value = 'The payment did not go through.';
        return;
      }
      finish(r);
    } finally {
      polling = false;
    }
  }

  Future<void> cleanup() async {
    pollTimer?.cancel();
    try {
      await pageServer?.close(force: true);
    } catch (_) {}
    pageServer = null;
  }

  try {
    await controller.initialize();
    await controller.setBackgroundColor(Colors.white);

    try {
      controller.webMessage.listen((msg) {
        final text = msg.toString();
        debugPrint('GATEWAY WEBVIEW: $text');
        // The page reports gateway events; any of these means the payer has
        // acted, so check right away rather than waiting for the next poll.
        if (text.startsWith('paid') || text.startsWith('txnStatus')) {
          paymentStarted = true;
          poll();
        } else if (text.startsWith('failed')) {
          // A declined attempt; the gateway's window lets the payer try again.
          poll();
        } else if (text.startsWith('dismissed')) {
          // The payer closed the gateway's own window before paying.
          _closeRequested?.call();
        }
      });
    } catch (_) {}

    try {
      controller.url.listen((current) {
        final uri = Uri.tryParse(current);
        if (uri == null || current.isEmpty) return;
        if (uri.scheme == 'about' || uri.scheme == 'data' ||
            uri.host == '127.0.0.1' || uri.host == 'localhost') {
          return;
        }
        final kind = order.checkout['kind'];
        // A redirect gateway's own first page is not the payer acting yet.
        if (kind == 'redirect' && current == order.checkout['url']) return;
        paymentStarted = true;
        // Back on our return page: the gateway is done, ask now.
        if (uri.path.endsWith('/pay-return')) poll();
      });
    } catch (_) {}

    final kind = '${order.checkout['kind']}';
    if (kind == 'redirect') {
      await controller.loadUrl('${order.checkout['url']}');
    } else {
      final html = _checkoutHtml(order,
          payerName: payerName, payerMobile: payerMobile, payerEmail: payerEmail, merchantName: merchantName);
      // Served from a loopback server, not file://: the gateways' scripts need
      // a real origin (see paytm_checkout_dialog.dart).
      pageServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      pageServer!.listen((req) async {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..headers.set('Cache-Control', 'no-store');
        req.response.write(html);
        await req.response.close();
      }, onError: (Object e) => debugPrint('checkout server error: $e'), cancelOnError: false);
      await controller.loadUrl('http://127.0.0.1:${pageServer!.port}/checkout.html');
    }
  } catch (e) {
    await cleanup();
    try {
      controller.dispose();
    } catch (_) {}
    final m = e.toString().toLowerCase();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(m.contains('webview2') || m.contains('not found')
            ? 'Microsoft Edge WebView2 runtime is missing on this PC. Install it from '
                'https://developer.microsoft.com/microsoft-edge/webview2/ then retry.'
            : 'Could not open the payment window. Please retry.'),
        backgroundColor: AppColors.error,
      ));
    }
    // Nobody could pay: close the order so a retry is not blocked.
    await ask(cancel: true);
    return null;
  }

  final started = DateTime.now();
  pollTimer = Timer.periodic(pollInterval, (t) {
    if (DateTime.now().difference(started) > pollMaxDuration) {
      // Out of time but not decided: leave it open for the server.
      ask().then((r) => finish(r ?? const OnlinePayResult('I')));
      return;
    }
    poll();
  });

  BuildContext? dialogCtx;

  /// The close button (or the gateway's own close). Asks once more; a payment
  /// the payer has acted on can only be left deliberately.
  Future<void> onClose() async {
    final ctx = dialogCtx;
    final r = await ask();
    if (r != null && r.isFinal) {
      finish(r);
      return;
    }
    if (paymentStarted) {
      if (ctx == null || !ctx.mounted) return;
      final leave = await showDialog<bool>(
        context: ctx,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          title: const Text('Payment Still in Progress'),
          content: const Text(
            'The bank has not confirmed this payment yet.\n\n'
            'If you close now and the amount is debited, the receipt is raised '
            'automatically within a few minutes. Do not collect it again.\n\n'
            'Please wait until it completes if you can.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep Waiting')),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              style: TextButton.styleFrom(foregroundColor: AppColors.error),
              child: const Text('Close Anyway'),
            ),
          ],
        ),
      );
      if (leave != true) return;
      finish(r ?? const OnlinePayResult('I'));
      return;
    }
    // Nothing was paid: close the order so the next attempt is not blocked.
    finish(await ask(cancel: true) ?? const OnlinePayResult('I'));
  }

  _closeRequested = onClose;

  if (context.mounted) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
          child: SizedBox(
            width: 520,
            height: 660,
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(AppUI.cardRadius)),
                ),
                child: Row(children: [
                  const Icon(Icons.account_balance_wallet, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$gatewayName Payment  -  ₹${formatIndianNumber(order.amount)}',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                        if (order.mode == 'TEST')
                          const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Text('TEST MODE - no real money is taken',
                                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 11.5)),
                          ),
                      ],
                    ),
                  ),
                  InkWell(onTap: onClose, child: const Icon(Icons.close, color: Colors.white, size: 20)),
                ]),
              ),
              Expanded(
                child: ValueListenableBuilder<String?>(
                  valueListenable: failureMsg,
                  builder: (_, msg, child) {
                    if (msg == null) return child!;
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.error_outline, color: AppColors.error, size: 48),
                        const SizedBox(height: 16),
                        Text('Payment Not Completed', style: AppUI.cardTitle),
                        const SizedBox(height: 10),
                        Text(msg, textAlign: TextAlign.center, style: AppUI.body),
                        const SizedBox(height: 10),
                        Text(
                          'No receipt has been raised. If the amount was debited, the bank '
                          'refunds it, or the receipt is raised automatically once it settles.',
                          textAlign: TextAlign.center,
                          style: AppUI.muted,
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton(
                          onPressed: () => finish(const OnlinePayResult('F')),
                          child: const Text('Close'),
                        ),
                      ]),
                    );
                  },
                  child: Webview(controller),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }

  final result = await completer.future;
  _closeRequested = null;
  if (dialogCtx != null && dialogCtx!.mounted) {
    final nav = Navigator.maybeOf(dialogCtx!);
    if (nav != null && nav.canPop()) nav.pop();
  }
  await Future.delayed(const Duration(milliseconds: 300));
  try {
    controller.dispose();
  } catch (_) {}
  await cleanup();
  failureMsg.dispose();
  return result;
}

/// Set while a checkout window is open, so the page's "dismissed" message can
/// run the same close path as the close button.
Future<void> Function()? _closeRequested;

String _js(String s) => jsonEncode(s);

/// The local page that opens the gateway's own checkout script. Values go in
/// through jsonEncode, so nothing from a name or a setting can break the page.
String _checkoutHtml(
  OnlineOrder order, {
  String payerName = '',
  String payerMobile = '',
  String payerEmail = '',
  String merchantName = '',
}) {
  final c = order.checkout;
  final merchant = merchantName.trim().isEmpty ? 'School Fees' : merchantName.trim();
  String script;
  String sdk;
  switch ('${c['kind']}') {
    case 'paytm':
      sdk = '${c['host']}/merchantpgpui/checkoutjs/merchants/${c['mid']}.js';
      script = '''
function onSdk() {
  if (!(window.Paytm && window.Paytm.CheckoutJS)) { show('The Paytm page did not load. Close and retry.'); return; }
  var config = {
    root: "", flow: "DEFAULT",
    merchant: { mid: ${_js('${c['mid']}')}, name: ${_js(merchant)}, redirect: false },
    data: { orderId: ${_js('${c['order_id']}')}, token: ${_js('${c['txn_token']}')}, tokenType: "TXN_TOKEN",
            amount: ${_js('${c['amount']}')},
            userDetail: { name: ${_js(payerName)}, mobile: ${_js(payerMobile)}, email: ${_js(payerEmail)} } },
    handler: {
      notifyMerchant: function(ev, d) { post('notify: ' + ev); },
      transactionStatus: function(s) {
        post('txnStatus: ' + JSON.stringify(s));
        show('Payment submitted. Checking with the bank...');
        try { window.Paytm.CheckoutJS.close(); } catch (e) {}
      }
    }
  };
  window.Paytm.CheckoutJS.onLoad(function() {
    window.Paytm.CheckoutJS.init(config).then(function() { window.Paytm.CheckoutJS.invoke(); })
      .catch(function(e) { post('INIT_ERR: ' + (e && e.message ? e.message : JSON.stringify(e))); show('Could not open Paytm: ' + e); });
  });
}''';
      break;
    case 'razorpay':
      sdk = 'https://checkout.razorpay.com/v1/checkout.js';
      script = '''
function onSdk() {
  if (!window.Razorpay) { show('The Razorpay page did not load. Close and retry.'); return; }
  var rzp = new Razorpay({
    key: ${_js('${c['key_id']}')}, order_id: ${_js('${c['gw_order_id']}')},
    amount: ${(c['amount_paise'] as num?)?.toInt() ?? 0}, currency: "INR",
    name: ${_js(merchant)}, description: ${_js('Fee payment ${c['order_id']}')},
    prefill: { name: ${_js(payerName)}, contact: ${_js(payerMobile)}, email: ${_js(payerEmail)} },
    handler: function(r) { post('paid ' + (r && r.razorpay_payment_id || '')); show('Payment received. Raising the receipt...'); },
    modal: { ondismiss: function() { post('dismissed'); show('Checking...'); } }
  });
  rzp.on('payment.failed', function(r) { post('failed ' + (r && r.error ? r.error.description : '')); });
  rzp.open();
}''';
      break;
    case 'cashfree':
      sdk = 'https://sdk.cashfree.com/js/v3/cashfree.js';
      script = '''
function onSdk() {
  if (!window.Cashfree) { show('The Cashfree page did not load. Close and retry.'); return; }
  var cf = Cashfree({ mode: ${_js('${c['env']}')} });
  cf.checkout({ paymentSessionId: ${_js('${c['payment_session_id']}')}, redirectTarget: "_self" });
}''';
      break;
    default:
      sdk = '';
      script = 'function onSdk() { show("This gateway is not supported here."); }';
  }

  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Fee Payment</title>
  <style>
    body { font-family: Arial, sans-serif; display: flex; justify-content: center; align-items: center;
           height: 100vh; margin: 0; background: #f5f5f5; color: #555; }
  </style>
  <script>
    function post(m) { try { window.chrome.webview.postMessage(String(m)); } catch (e) {} }
    window.onerror = function(msg, src, line) { post('JSERR: ' + msg + ' @ ' + (src || '') + ':' + (line || '')); };
    function show(m) { var el = document.getElementById('status'); if (el) el.textContent = m; }
    $script
  </script>
  <script src="$sdk" onload="onSdk()" onerror="show('Could not reach the payment gateway. Check the internet and retry.')"></script>
</head>
<body><p id="status">Opening the payment page...</p></body>
</html>
''';
}
