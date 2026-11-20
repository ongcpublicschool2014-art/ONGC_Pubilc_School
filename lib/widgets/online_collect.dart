import 'package:flutter/material.dart';
import '../services/online_payment_service.dart';
import '../utils/payment_gateways.dart';
import 'gateway_checkout_dialog.dart';

/// Collects a counter collection (Misc / Advance / Advance Fee) online,
/// through the school's gateway (Setup > Payment Gateways).
///
/// [header] and [lines] are exactly what the screen's own save takes. The
/// SERVER saves the collection once the gateway confirms the money -- also when
/// this window was closed or the PC restarted -- so the caller must NOT save it
/// again. Returns the server's answer; for C the receipt number is in
/// `receiptNumbers`. Every other outcome is explained to the cashier here.
Future<OnlinePayResult?> collectOnline(
  BuildContext context, {
  required String kind, // MISC | ADVANCE | ADVFEE
  int? stuId,
  required Map<String, dynamic> header,
  List<Map<String, dynamic>>? lines,
  String payerName = '',
  String merchantName = '',
}) async {
  void say(String title, String text) {
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }

  OnlineOrder order;
  try {
    order = await OnlinePaymentService.startOther(
        kind: kind, stuId: stuId, request: {'header': header, 'lines': lines});
  } catch (e) {
    final msg = e is OnlinePaymentException ? e.message : '$e';
    // Another online payment for this student is open: offer to ask now.
    if (e is OnlinePaymentException && e.code == 'P0002' && e.orderId != null && context.mounted) {
      final check = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Online Payment Not Settled'),
          content: Text('$msg\n\nAsk the gateway now whether it was paid?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Close')),
            ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Check Now')),
          ],
        ),
      );
      if (check == true) {
        try {
          final r = await OnlinePaymentService.status(e.orderId!);
          say('Online Payment', switch (r.status) {
            'C' => 'It was paid: receipt ${r.receiptNumbers}.',
            'F' when r.moneyMayBeMoving => 'The gateway is still processing it. Try again in a few minutes.',
            'F' => 'The gateway says it was not paid. You can collect now.',
            'X' => 'It was paid but needs the office (Setup > Payment Gateways). Do not collect again.',
            _ => 'Not confirmed yet. Try again in a few minutes.',
          });
        } catch (e2) {
          say('Online Payment', e2 is OnlinePaymentException ? e2.message : '$e2');
        }
      }
      return null;
    }
    say('Cannot Start Online Payment', msg);
    return null;
  }
  if (!context.mounted) return null;

  final gatewayName = pgProvider(order.provider)?.name ?? order.provider;
  final r = await showGatewayCheckout(context,
      order: order, gatewayName: gatewayName, payerName: payerName, merchantName: merchantName);
  if (!context.mounted) return r;
  switch (r?.status) {
    case 'C':
      break; // the caller shows its own receipt dialog
    case 'X':
      say('Paid, Receipt Pending',
          '$gatewayName took this payment, but it could not be saved (${r!.note.isEmpty ? 'unknown reason' : r.note}). '
          'Do not collect it again: it is listed under Setup > Payment Gateways for the office. Reference: ${order.orderId}.');
    case 'F' when r!.moneyMayBeMoving:
      say('Still Processing',
          '$gatewayName is still processing this payment. Do not collect it again yet: if it completes, the '
          'collection is saved automatically. Reference: ${order.orderId}.');
    case 'F':
      say('Not Paid', 'Not paid so far: $gatewayName has not received this payment, and nothing was saved. '
          'If the payer approved it on their phone, wait a few minutes before collecting another way. '
          'Reference: ${order.orderId}.');
    case 'T':
      say('Test Payment', 'The gateway is in Test mode: the payment went through but nothing was saved.');
    case 'H':
      say('Closed', 'This payment was closed by the office.');
    case null:
      break; // the window could not open; already told
    default:
      say('Not Confirmed Yet',
          'The bank has not confirmed this payment yet. Do not collect it again: if the money went through, '
          'the collection is saved automatically within a few minutes. Reference: ${order.orderId}.');
  }
  return r;
}
