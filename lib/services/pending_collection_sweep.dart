import 'dart:async';

import 'package:flutter/foundation.dart';

import 'paytm_service.dart';
import 'supabase_service.dart';

/// Recovers a misc or advance Paytm collection the counter never finished.
///
/// WHY THIS EXISTS. A fee payment that Paytm captures late is recovered by
/// `_sweepOrphanedPayments` on the Fee Collection screen: the 'I' payment row
/// carries `payitems`, so the app can replay it without help. Misc and advance
/// had no such row at all until `pending_collection` — and even then, the only
/// thing that completed a late capture was the Paytm webhook.
///
/// A webhook is the wrong thing to depend on for money. It has to be deployed,
/// Paytm has to be configured to call it, and there is one callback URL for one
/// Paytm account — so a TEST machine paying through live Paytm can never be
/// recovered by it. The case that prompted this is ordinary: a cashier opens a
/// UPI collect, cancels the window, and the payer approves it on their phone
/// two minutes later. Paytm takes the money; nothing was watching.
///
/// So the app recovers it itself, exactly as it does for fee payments: ask
/// Paytm about every intent old enough to have a final answer, and raise the
/// receipt for the ones it captured.
///
/// WHAT IT WILL NOT DO. It never fails a collection on silence. Only an
/// explicit Paytm failure closes an intent; "pending", "no record", and a
/// verify call that threw are all UNDECIDED and leave the row alone for the
/// next sweep. That rule is the one the 01-10-2026 release was built on — the
/// orphan sweep used to write off anything it could not confirm within 15
/// minutes, which is how Rs 91,500 of real receipts were lost.
class PendingCollectionSweep {
  /// Sweeping only when a screen opens leaves a counter looking at a payment
  /// that Paytm settled ten minutes ago. This keeps one timer for the whole
  /// app so an intent resolves itself wherever the user happens to be.
  ///
  /// Five minutes, not one: each tick asks Paytm about every open intent, and
  /// an intent is not eligible until it is 2 minutes old anyway. When there
  /// are none -- the normal case -- a tick costs a single cheap query.
  ///
  /// NOT a substitute for the webhook or for pg_cron: this only runs while the
  /// app is open. It closes the gap between "somebody opened the right screen"
  /// and "somebody has the app open at all".
  static Timer? _auto;

  static void startAuto({required int insId, String? sessionToken}) {
    _auto?.cancel();

    // Sweep once NOW, not in five minutes. Timer.periodic does not fire until
    // its first interval has elapsed, so an accountant opening the app in the
    // morning -- precisely when yesterday's unresolved payments should be
    // picked up -- would have waited. Unawaited on purpose: login must not
    // block on a gateway round trip.
    unawaited(run(insId: insId, sessionToken: sessionToken)
        .then((r) {
          if (r.didSomething) {
            debugPrint('login sweep: ${r.receipted} receipted, ${r.closed} closed');
          }
        })
        .catchError((Object e) {
          debugPrint('login sweep: $e');
          return const SweepResult(0, 0, 0);
        }));

    _auto = Timer.periodic(const Duration(minutes: 5), (_) async {
      try {
        final r = await run(insId: insId, sessionToken: sessionToken);
        if (r.didSomething) {
          debugPrint('auto sweep: ${r.receipted} receipted, ${r.closed} closed');
        }
      } catch (e) {
        debugPrint('auto sweep: $e');
      }
    });
  }

  static void stopAuto() {
    _auto?.cancel();
    _auto = null;
  }

  /// What one pass did, for logging and for the caller to surface if it wants.
  static Future<SweepResult> run({required int insId, String? sessionToken}) async {
    var receipted = 0, failed = 0, undecided = 0;

    List<dynamic> open;
    try {
      open = await SupabaseService.client
              .rpc('open_pending_collections', params: {'p_ins_id': insId})
          as List<dynamic>;
    } catch (e) {
      // The migration may not be deployed yet. Not an error worth showing.
      debugPrint('PendingCollectionSweep: cannot list intents: $e');
      return const SweepResult(0, 0, 0);
    }

    for (final row in open) {
      final orderId = row['order_id']?.toString();
      if (orderId == null || orderId.isEmpty) continue;
      final kind = row['kind']?.toString() ?? 'M';
      final banId = (row['ban_id'] as num?)?.toInt();

      // ASK THE MERCHANT THE ORDER WAS SIGNED WITH. Orders are signed per fee
      // group, so a hostel collection lives under the hostel merchant; asking
      // the institution default returns "no such order" and a captured payment
      // would look like a failure.
      PaytmStatus status;
      try {
        final routing =
            await SupabaseService.resolvePaytmRouting(insId: insId, banId: banId);
        status = await PaytmService.verifyPayment(orderId,
            mid: routing.ok ? routing.mid : null);
      } catch (e) {
        debugPrint('PendingCollectionSweep: $orderId lookup failed: $e');
        undecided++;
        continue; // undecided -- try again next time
      }

      if (status.isCaptured) {
        if (await _raiseReceipt(orderId, kind, status.paymentId,
            sessionToken: sessionToken)) {
          receipted++;
        } else {
          undecided++;
        }
      } else if (status.isFailed) {
        // Only an explicit gateway failure closes it. 'X' rather than 'F':
        // the money was never taken, so this is an abandoned attempt, not a
        // failed collection the books need to know about.
        try {
          await SupabaseService.client.rpc('settle_pending_collection',
              params: {'p_order_id': orderId, 'p_status': 'X'});
          failed++;
        } catch (e) {
          debugPrint('PendingCollectionSweep: $orderId close failed: $e');
        }
      } else {
        undecided++;
      }
    }

    if (receipted > 0 || failed > 0) {
      debugPrint('PendingCollectionSweep: $receipted receipted, $failed closed, '
          '$undecided left undecided');
    }
    return SweepResult(receipted, failed, undecided);
  }

  /// Claim, then raise the receipt through the ordinary save path.
  ///
  /// The claim is what stops two receipts for one payment: the counter may be
  /// finishing this very collection, and the webhook may be doing the same.
  /// Exactly one caller wins; a loser must do nothing at all.
  static Future<bool> _raiseReceipt(String orderId, String kind, String? txnId,
      {String? sessionToken}) async {
    List<dynamic> claim;
    try {
      claim = await SupabaseService.client.rpc('claim_pending_collection',
          params: {'p_order_id': orderId, 'p_by': 'SWEEP'}) as List<dynamic>;
    } catch (e) {
      debugPrint('PendingCollectionSweep: $orderId claim failed: $e');
      return false;
    }
    if (claim.isEmpty) return false; // somebody else has it -- correct outcome

    final c = claim.first as Map<String, dynamic>;
    final insId = (c['ins_id'] as num).toInt();
    final header = Map<String, dynamic>.from(c['header'] as Map);
    final lines = c['lines'];

    // Carry Paytm's own transaction id onto the receipt so it can be matched
    // against a settlement report like every other receipt.
    if (txnId != null && txnId.isNotEmpty) header['paytm_txnid'] = txnId;

    try {
      String? receiptNo;
      if (kind == 'M') {
        final res = await SupabaseService.client.rpc('save_misc_collection',
            params: {
              'p_ins_id': insId,
              'p_header': header,
              'p_lines': lines ?? <dynamic>[],
            });
        receiptNo = (res is Map ? res['mcno'] : null)?.toString();
      } else {
        // save_advance_collection wants a session; the sweep runs inside a
        // signed-in admin app, so it has one. (The webhook, which does not,
        // goes through _save_advance_collection instead.)
        if (sessionToken == null || sessionToken.isEmpty) {
          await _release(orderId);
          debugPrint('PendingCollectionSweep: $orderId needs a session');
          return false;
        }
        // An ADVANCE FEE payment (school, Advance Fee Collection) is raised
        // through collect_student_advance, so the student's advance lines
        // are marked paid as well -- not as a plain admission advance.
        final res = await SupabaseService.client.rpc(
            header['stuadv'] == true ? 'collect_student_advance' : 'save_advance_collection',
            params: {
              'p_token': sessionToken,
              'p_header': header,
              'p_lines': lines,
            });
        receiptNo = (res is Map ? res['advno'] : null)?.toString();
      }

      await SupabaseService.client.rpc('settle_pending_collection', params: {
        'p_order_id': orderId,
        'p_status': 'C',
        'p_receipt_no': receiptNo,
      });
      // Date it the day the MONEY WAS TAKEN, not the day we found it. The
      // save RPCs stamp now() on purpose -- right for a collection happening
      // now, wrong for one recovered a day later, which would otherwise land
      // on the wrong Daily Collection and never tie against Paytm. The date
      // comes from the intent's server-stamped created_at, never a client.
      try {
        await SupabaseService.client.rpc('backdate_recovered_collection',
            params: {'p_order_id': orderId});
      } catch (e) {
        debugPrint('PendingCollectionSweep: $orderId backdate failed: $e');
      }

      debugPrint('PendingCollectionSweep: $orderId receipted as $receiptNo');
      return true;
    } catch (e) {
      // Put it back so the next sweep, the webhook or a person can try again.
      // Leaving it claimed would strand real money behind a lock nobody holds.
      await _release(orderId);
      debugPrint('PendingCollectionSweep: $orderId could not be receipted: $e');
      return false;
    }
  }

  static Future<void> _release(String orderId) async {
    try {
      await SupabaseService.client.rpc('settle_pending_collection',
          params: {'p_order_id': orderId, 'p_status': 'I'});
    } catch (e) {
      debugPrint('PendingCollectionSweep: $orderId release failed: $e');
    }
  }
}

class SweepResult {
  const SweepResult(this.receipted, this.closed, this.undecided);
  final int receipted;
  final int closed;
  final int undecided;
  bool get didSomething => receipted > 0 || closed > 0;
}
