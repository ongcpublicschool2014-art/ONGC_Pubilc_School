import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart'
    if (dart.library.html) '../screens/fees/webview_windows_stub.dart';
import '../config/paytm_config.dart';
import '../services/paytm_service.dart';
import '../utils/app_theme.dart';
import 'app_ui.dart';

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
  /// Which account this payment is settling into, e.g.
  /// 'HOSTEL FEES · merchant …260773'.
  ///
  /// The name Paytm shows in its own header is [merchantName] -- the
  /// INSTITUTION's name -- and it reads the same whichever merchant the order
  /// was signed with. A cashier collecting a hostel fee therefore saw the
  /// college's name and had no way to tell whether the money was routed
  /// correctly. This line is the one place that says so.
  String settlingTo = '',
  Duration pollInterval = const Duration(seconds: 3),
  Duration pollMaxDuration = const Duration(minutes: 10),
}) async {
  final completer = Completer<String?>();
  // A reason left over from an earlier attempt must never be shown against
  // this one.
  PaytmService.lastGatewayMessage = '';
  final webviewController = WebviewController();
  Timer? pollTimer;
  // The checkout page is SERVED, not opened from disk.
  //
  // It used to be written to %TEMP% and loaded as file://. That worked until
  // the WebView2 runtime went from 154 to 155 on 14-10-2026, and then every
  // checkout hung on "Opening Paytm Checkout..." -- the log showed
  // "onLoad fired; calling init" and then nothing, forever: init()'s promise
  // neither resolved nor rejected.
  //
  // A file:// page has NO origin -- Chromium reports it as the string "null".
  // Paytm's CheckoutJS opens an iframe to the gateway and completes a
  // postMessage handshake with it before init() resolves, and a null origin
  // cannot complete that handshake. Nothing errors; it simply waits.
  //
  // A loopback server gives the page a real origin (http://127.0.0.1:<port>),
  // which is all the handshake needs. Bound to the loopback interface on an
  // OS-assigned port, serving exactly one document, and closed with the
  // dialog -- nothing is reachable from outside this machine, and no file is
  // left in %TEMP% afterwards either.
  HttpServer? pageServer;
  /// True once the checkout has left our local HTML for a real gateway or bank
  /// page — i.e. the cashier has actually submitted the payment. Until then the
  /// window is just a form nobody has used, and closing it costs nothing.
  /// Afterwards the bank may debit regardless of what this window does, which
  /// is what makes closing it dangerous.
  var paymentStarted = false;
  /// Set when the gateway reports the attempt failed AFTER the cashier
  /// submitted it. The window then shows the reason and waits to be dismissed
  /// instead of disappearing on its own: a window that vanishes mid-payment
  /// looks identical to a crash, and leaves nobody sure whether money moved.
  final failureMsg = ValueNotifier<String?>(null);

  Future<void> cleanup() async {
    pollTimer?.cancel();
    // force: true so a checkout the cashier closed mid-redirect cannot hold
    // the port open behind them.
    try {
      await pageServer?.close(force: true);
    } catch (_) {}
    pageServer = null;
  }

  try {
    await webviewController.initialize();
    await webviewController.setBackgroundColor(Colors.white);

    // Capture JS diagnostics the checkout HTML posts (window.chrome.webview)
    // so a stuck/blank checkout shows its real cause in the run log.
    try {
      webviewController.webMessage.listen((msg) {
        debugPrint('PAYTM WEBVIEW: $msg');
        // The transactionStatus callback carries Paytm's own RESPMSG -- the
        // only statement of WHY a payment failed. The Transaction Status API
        // the poll below uses returns the status alone, so without this a
        // decline and a closed window are indistinguishable to the cashier.
        final text = msg.toString();
        final at = text.indexOf('txnStatus: ');
        if (at < 0) return;
        try {
          final body = jsonDecode(text.substring(at + 'txnStatus: '.length));
          if (body is Map) {
            final respMsg = body['RESPMSG']?.toString().trim() ?? '';
            if (respMsg.isNotEmpty) PaytmService.lastGatewayMessage = respMsg;
          }
        } catch (_) {
          // Malformed callback payload: the run log still has it verbatim.
        }
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
        // Our OWN page does not count as leaving it. 127.0.0.1 is where the
        // checkout document is now served from -- before it was file://, and
        // a listener that only knew about file:// would mark the payment as
        // started the instant the dialog opened, which turns every cancelled
        // checkout into "the payment may have gone through".
        if (uri.scheme == 'file' ||
            uri.scheme == 'about' ||
            uri.scheme == 'data' ||
            uri.host == '127.0.0.1' ||
            uri.host == 'localhost') {
          return;
        }
        // Left the local checkout page for the gateway or a bank/UPI/ACS page:
        // the payment is now in the bank's hands, not ours.
        paymentStarted = true;
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
    // Port 0 = let the OS pick a free one, so two checkouts opened in quick
    // succession cannot collide on a fixed port.
    pageServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final pageUrl = 'http://127.0.0.1:${pageServer!.port}/checkout.html';
    debugPrint('Paytm checkout served at $pageUrl');

    // Every path returns the same document. The server exists for its ORIGIN,
    // not to be a file server, and serving one thing means a stray request --
    // /favicon.ico is the usual one -- cannot 404 into the WebView console.
    pageServer!.listen(
      (req) async {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          // The page carries a live txnToken. No-store keeps it out of
          // WebView2's HTTP cache on disk.
          ..headers.set('Cache-Control', 'no-store');
        req.response.write(html);
        await req.response.close();
      },
      onError: (Object e) => debugPrint('Paytm checkout server error: $e'),
      cancelOnError: false,
    );

    await webviewController.loadUrl(pageUrl);
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
          backgroundColor: AppColors.error,
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
          // Pending is NOT failure. Returning 'F' here wrote off payments the
          // bank was still settling; null means "undecided", and the caller
          // leaves the row 'I' for the sweep to resolve.
          completer.complete(s.isCaptured ? 'C' : (s.isFailed ? 'F' : null));
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
        // Only close on our own if the cashier never submitted anything --
        // then there is nothing to explain. Once an attempt has been made,
        // hold the window open and SAY why, so a decline is not mistaken for
        // the app closing itself.
        if (paymentStarted) {
          failureMsg.value = s.message.trim().isNotEmpty
              ? s.message.trim()
              : (PaytmService.lastGatewayMessage.trim().isNotEmpty
                  ? PaytmService.lastGatewayMessage.trim()
                  : 'The payment did not go through.');
        } else if (!completer.isCompleted) {
          completer.complete('F');
        }
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppUI.cardRadius)),
          child: SizedBox(
            width: 500,
            height: 620,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(AppUI.cardRadius)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.account_balance_wallet,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Paytm Payment  -  ₹${amount.toStringAsFixed(2)}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15),
                            ),
                            // Paytm's own header shows the INSTITUTION name
                            // whichever merchant signed the order, so this is
                            // the only place the account is visible.
                            if (settlingTo.trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  'Settling to  ${settlingTo.trim()}',
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w500,
                                      fontSize: 11.5),
                                ),
                              ),
                          ],
                        ),
                      ),
                      InkWell(
                        onTap: () async {
                          // Last-chance authoritative check before treating as
                          // cancelled — the txn may have just succeeded.
                          //
                          // The poll is deliberately NOT cancelled yet: if the
                          // cashier decides to keep waiting, the transaction has
                          // to stay under observation.
                          PaytmStatus? s;
                          try {
                            s = await PaytmService.verifyPayment(order.orderId, mid: order.mid);
                          } catch (_) {}

                          if (s != null && s.isCaptured) {
                            pollTimer?.cancel();
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (!completer.isCompleted) completer.complete('C');
                            return;
                          }

                          // Closing a payment the cashier has already submitted
                          // is how money ends up debited with no receipt behind
                          // it: the bank settles later, this window is gone, and
                          // nothing is left to raise the receipt. Several such
                          // payments have had to be entered by hand. A status
                          // that is not yet 'failed' may still succeed, so make
                          // closing a deliberate act rather than one stray click.
                          // A known failure closes with 'F' rather than as a
                          // cancellation: the difference matters to the row the
                          // collection screen writes.
                          if (s != null && s.isFailed) {
                            pollTimer?.cancel();
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (!completer.isCompleted) completer.complete('F');
                            return;
                          }

                          final inFlight =
                              paymentStarted && (s == null || !s.isFailed);
                          if (inFlight) {
                            if (!ctx.mounted) return;
                            final closeAnyway = await showDialog<bool>(
                              context: ctx,
                              barrierDismissible: false,
                              builder: (c) => AlertDialog(
                                title: const Text('Payment still in progress'),
                                content: const Text(
                                  'This payment has been submitted to the bank and has '
                                  'not finished yet.\n\n'
                                  'If you close now and the bank debits the amount, the '
                                  'student will be charged with NO receipt, and it will '
                                  'have to be entered by hand later.\n\n'
                                  'Please wait until it completes.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text('Keep waiting'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    style: TextButton.styleFrom(
                                        foregroundColor: AppColors.error),
                                    child: const Text('Close anyway'),
                                  ),
                                ],
                              ),
                            );
                            // Keep waiting: the poll is still running and will
                            // resolve the payment on its own.
                            if (closeAnyway != true) return;
                          }

                          pollTimer?.cancel();
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (!completer.isCompleted) completer.complete(null);
                        },
                        child: const Icon(Icons.close, color: Colors.white, size: 20),
                      ),
                    ],
                  ),
                ),
                // A failed attempt replaces the checkout with a plain statement
                // of what the gateway said. The cashier closes it deliberately,
                // so there is never a moment where the window simply vanished.
                Expanded(
                  child: ValueListenableBuilder<String?>(
                    valueListenable: failureMsg,
                    builder: (_, msg, child) {
                      if (msg == null) return child!;
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline,
                                color: AppColors.error, size: 48),
                            const SizedBox(height: 16),
                            Text('Payment not completed',
                                style: AppUI.cardTitle),
                            const SizedBox(height: 10),
                            Text(msg,
                                textAlign: TextAlign.center,
                                style: AppUI.body),
                            const SizedBox(height: 10),
                            Text(
                              'No receipt has been raised. If the amount was debited, '
                              'it will be refunded by the bank, or the receipt can be '
                              'entered once it settles.',
                              textAlign: TextAlign.center,
                              style: AppUI.muted,
                            ),
                            const SizedBox(height: 20),
                            ElevatedButton(
                              onPressed: () {
                                pollTimer?.cancel();
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (!completer.isCompleted) {
                                  completer.complete('F');
                                }
                              },
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    },
                    child: Webview(webviewController),
                  ),
                ),
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
  failureMsg.dispose();

  return result;
}
