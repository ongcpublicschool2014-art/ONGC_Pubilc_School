import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart'
    if (dart.library.html) '../screens/fees/webview_windows_stub.dart';
import '../config/paytm_config.dart';
import '../services/paytm_service.dart';

/// Opens the Paytm JS Checkout in a WebView dialog and resolves once the
/// transaction reaches a terminal state. Returns:
///   'C'  -> captured (success)
///   'F'  -> failed
///   null -> cancelled by the user / WebView could not open
///
/// The dialog polls [PaytmService.verifyPayment] (the server-side Transaction
/// Status API) — it never trusts the browser callback alone. This mirrors the
/// Razorpay checkout dialog's polling design.
Future<String?> showPaytmCheckout(
  BuildContext context, {
  required PaytmOrder order,
  required double amount,
  String studentName = '',
  String studentMobile = '',
  String studentEmail = '',
  String merchantName = '',
  Duration pollInterval = const Duration(seconds: 3),
  Duration pollMaxDuration = const Duration(minutes: 10),
}) async {
  final completer = Completer<String?>();
  final webviewController = WebviewController();
  Timer? pollTimer;
  File? tempFile;

  Future<void> cleanup() async {
    pollTimer?.cancel();
    try {
      await tempFile?.delete();
    } catch (_) {}
  }

  try {
    await webviewController.initialize();
    await webviewController.setBackgroundColor(Colors.white);

    // Capture JS diagnostics the checkout HTML posts (window.chrome.webview)
    // so a stuck/blank checkout shows its real cause in the run log.
    try {
      webviewController.webMessage.listen((msg) {
        debugPrint('PAYTM WEBVIEW: $msg');
      });
    } catch (_) {}

    // Defence-in-depth host allowlist (the primary control is the local HTML
    // we generate). Log unexpected navigations; the Paytm SDK may redirect
    // through bank/UPI hosts, so we only warn rather than block.
    final allowed = PaytmConfig.allowedHosts;
    try {
      webviewController.url.listen((current) {
        if (current.isEmpty) return;
        final uri = Uri.tryParse(current);
        if (uri == null) return;
        if (uri.scheme == 'file' || uri.scheme == 'about' || uri.scheme == 'data') {
          return;
        }
        if (!allowed.contains(uri.host)) {
          debugPrint('Paytm webview navigated to: ${uri.host}');
        }
      });
    } catch (_) {}

    final html = PaytmService.buildCheckoutHtml(
      order: order,
      studentName: studentName,
      studentMobile: studentMobile,
      studentEmail: studentEmail,
      merchantName: merchantName,
    );
    tempFile =
        File('${Directory.systemTemp.path}/kcet_paytm_checkout_${order.orderId}.html');
    await tempFile.writeAsString(html);
    await webviewController.loadUrl(Uri.file(tempFile.path).toString());
  } catch (e) {
    await cleanup();
    try {
      webviewController.dispose();
    } catch (_) {}
    final msg = e.toString().toLowerCase();
    final isWebView2Missing =
        msg.contains('webview2') || msg.contains('not found');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isWebView2Missing
              ? 'Microsoft Edge WebView2 runtime is missing on this PC. '
                  'Install it from https://developer.microsoft.com/microsoft-edge/webview2/ then retry.'
              : 'Could not open the Paytm payment window. Please retry.'),
          backgroundColor: Colors.red,
        ),
      );
    }
    return null;
  }

  // Poll the server-side status API until a terminal state or timeout.
  final pollStarted = DateTime.now();
  pollTimer = Timer.periodic(pollInterval, (timer) async {
    if (DateTime.now().difference(pollStarted) > pollMaxDuration) {
      timer.cancel();
      try {
        final s = await PaytmService.verifyPayment(order.orderId, mid: order.mid);
        if (!completer.isCompleted) {
          completer.complete(s.isCaptured ? 'C' : 'F');
        }
      } catch (_) {
        if (!completer.isCompleted) completer.complete('F');
      }
      return;
    }
    try {
      final s = await PaytmService.verifyPayment(order.orderId, mid: order.mid);
      if (s.isCaptured) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete('C');
      } else if (s.isFailed) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete('F');
      }
    } catch (_) {
      // transient — keep polling
    }
  });

  BuildContext? dialogCtx;
  if (context.mounted) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: SizedBox(
            width: 500,
            height: 620,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: const BoxDecoration(
                    color: Color(0xFF00B4AB),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.account_balance_wallet,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Paytm Payment  -  ₹${amount.toStringAsFixed(2)}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 15),
                        ),
                      ),
                      InkWell(
                        onTap: () async {
                          // Last-chance authoritative check before treating as
                          // cancelled — the txn may have just succeeded.
                          pollTimer?.cancel();
                          try {
                            final s = await PaytmService.verifyPayment(order.orderId, mid: order.mid);
                            if (s.isCaptured) {
                              if (ctx.mounted) Navigator.pop(ctx);
                              if (!completer.isCompleted) completer.complete('C');
                              return;
                            }
                          } catch (_) {}
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (!completer.isCompleted) completer.complete(null);
                        },
                        child: const Icon(Icons.close, color: Colors.white, size: 20),
                      ),
                    ],
                  ),
                ),
                Expanded(child: Webview(webviewController)),
              ],
            ),
          ),
        );
      },
    );
  }

  final result = await completer.future;

  if (dialogCtx != null && dialogCtx!.mounted) {
    final nav = Navigator.maybeOf(dialogCtx!);
    if (nav != null && nav.canPop()) nav.pop();
  }

  // Let the exit animation finish before disposing the WebView.
  await Future.delayed(const Duration(milliseconds: 300));
  try {
    webviewController.dispose();
  } catch (_) {}
  await cleanup();

  return result;
}
