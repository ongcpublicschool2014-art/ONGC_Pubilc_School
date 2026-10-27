// paytm-webhook
//
// Receives Paytm's transaction callback and RAISES THE RECEIPT SERVER-SIDE.
//
// WHY THIS EXISTS
// Until now the only thing that could turn a captured payment into a receipt
// was the client: the parent's phone or the counter PC. get-paytm-payment
// reports the gateway's answer and writes nothing. So if the app was closed,
// lost signal, or the checkout dialog resolved without a verdict, Paytm had
// the money and nothing on our side ever acted on it. On 2026-09-29 that cost
// three receipts and Rs 95,000.
//
// This closes that: Paytm tells the SERVER, and the server completes the
// payment whether or not the client ever comes back.
//
// THE BODY IS NOT TRUSTED.
// A callback is treated purely as a nudge saying "look at this order". The
// verdict always comes from a fresh /v3/order/status call signed with the
// merchant key. That means:
//   * a forged or replayed POST can achieve nothing except making us ask
//     Paytm about an order, and we then do whatever is actually true;
//   * a browser-mediated callback (which the customer could tamper with) is
//     as safe as a server-to-server one;
//   * no shared secret has to be distributed for this endpoint to be safe.
// The checksum is still verified when present, as defence in depth, but a
// missing one does not stop us asking Paytm.
//
// IDEMPOTENT. Called twice, it completes once: the SQL side re-reads the
// payment row and does nothing if a receipt already exists. Paytm retries on
// a non-2xx, so anything unexpected returns 500 to get another attempt, while
// anything correctly handled returns 200.
//
// Deploy:  supabase functions deploy paytm-webhook --no-verify-jwt
//   (--no-verify-jwt is required: Paytm does not send a Supabase JWT.)
//
// THEN POINT PAYTM AT IT VIA THE DASHBOARD's merchant-level webhook / S2S
// callback setting -- NOT via PAYTM_CALLBACK_URL.
//
// PAYTM_CALLBACK_URL goes into the order body that create-paytm-order sends,
// and that body is deliberately byte-for-byte unchanged from the flow in
// production today. It would also have no effect on mobile, which hard-sets
// its callbackUrl to Paytm's own /theia/paytmCallback because the All-in-One
// SDK watches for that exact URL. A dashboard webhook is independent of the
// order body, so it covers web, desktop and mobile without altering a single
// byte of what is already working.
//
// Needs WEBHOOK_PAYMENT_RPCS.sql deployed for the three RPCs it calls.
//
// Env: PAYTM_MID, PAYTM_MERCHANT_KEY, PAYTM_HOST (as the other Paytm
//      functions), SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { generateSignature, verifySignature } from "../_shared/paytm_checksum.ts";
import { resolveMerchant } from "../_shared/paytm_merchant.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

/// Paytm posts form-encoded from the browser callback and JSON from the
/// dashboard webhook. Accept both rather than guessing which is configured.
async function readParams(req: Request): Promise<Record<string, string>> {
  const ctype = (req.headers.get("content-type") ?? "").toLowerCase();
  if (ctype.includes("application/json")) {
    const j = await req.json().catch(() => ({}));
    const flat: Record<string, string> = {};
    for (const [k, v] of Object.entries(j ?? {})) {
      if (v !== null && typeof v !== "object") flat[k] = String(v);
    }
    // The dashboard webhook nests the real fields under `body`.
    const nested = (j as Record<string, unknown>)?.body;
    if (nested && typeof nested === "object") {
      for (const [k, v] of Object.entries(nested as Record<string, unknown>)) {
        if (v !== null && typeof v !== "object") flat[k] = String(v);
      }
    }
    return flat;
  }
  const form = await req.formData().catch(() => null);
  const out: Record<string, string> = {};
  if (form) for (const [k, v] of form.entries()) out[k] = String(v);
  return out;
}

/// Paytm's own checksum rule: every field except the checksum itself, sorted
/// by key, joined with a pipe. Only used for the optional extra check.
function checksumPayload(p: Record<string, string>): string {
  return Object.keys(p)
    .filter((k) => k !== "CHECKSUMHASH" && k !== "signature")
    .sort()
    .map((k) => p[k])
    .join("|");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const params = await readParams(req);
    const orderId = params.ORDERID ?? params.orderId ?? params.order_id ?? "";
    if (!orderId) return json({ error: "no order id in callback" }, 400);

    const requestedMid = params.MID ?? params.mid ?? null;
    const { mid, key, host } = resolveMerchant(requestedMid);

    // Defence in depth only -- never a reason to skip asking Paytm.
    const sent = params.CHECKSUMHASH ?? params.signature ?? "";
    let checksumOk: boolean | null = null;
    if (sent) {
      checksumOk = await verifySignature(checksumPayload(params), key, sent)
        .catch(() => false);
    }

    // ---- THE AUTHORITATIVE ANSWER --------------------------------------
    const statusBody = { mid, orderId: String(orderId) };
    const signature = await generateSignature(JSON.stringify(statusBody), key);
    const resp = await fetch(host + "/v3/order/status", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ body: statusBody, head: { signature } }),
    });
    const data = await resp.json();
    const resultStatus = data?.body?.resultInfo?.resultStatus;
    const txnId = data?.body?.txnId ?? null;
    const txnAmount = Number(data?.body?.txnAmount ?? 0);

    // Anything not decided yet is left alone. The row stays 'I' and a later
    // callback or the sweep resolves it -- we never write off an undecided
    // payment, which is the mistake that started all of this.
    if (resultStatus !== "TXN_SUCCESS" && resultStatus !== "TXN_FAILURE") {
      return json({ ok: true, order_id: orderId, action: "left pending", resultStatus });
    }

    const db = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    // EVERY order id is now followed through, not just PAY-.
    //
    // This used to return early for anything not starting with "PAY-", on the
    // reasoning that "a misc receipt stores Paytm's TXN id, not the order id,
    // so it cannot be found from a callback at all". That was true: misc and
    // advance wrote nothing to the database until the payment succeeded, so a
    // callback about MISC1T.../ADV1T... had nothing to match.
    //
    // They now record an intent BEFORE contacting the gateway, so those orders
    // can be completed -- webhook_complete_payment falls through to
    // webhook_complete_collection when no payment row matches. Returning early
    // here would discard exactly the callbacks that intent exists to serve, and
    // an order that matches nothing at all is recorded as a refusal rather than
    // being dropped.

    const { data: found, error: selErr } = await db.rpc("webhook_find_payment", {
      p_order_id: orderId,
    });
    if (selErr) throw new Error("lookup failed: " + selErr.message);

    const row = Array.isArray(found) ? found[0] : found;
    if (!row) {
      // A MISC or ADVANCE order has NO PAYMENT ROW BY DESIGN -- its record is
      // the pending_collection intent, and webhook_find_payment only searches
      // <schema>.payment. So this branch is reached by every misc/advance
      // callback, including the ones that worked perfectly.
      //
      // Until this was added the function returned here, which had two costs:
      //
      //   * every successful misc Paytm payment raised a refusal reading
      //     "no record in the database". Four on 05-10-2026 (Rs 5,250, 3,000,
      //     4,950, 50) -- all four already receipted as FC26/03395, 03414,
      //     03475, 03476. A list that means "money received with no receipt"
      //     is worth nothing once it also fires when nothing went wrong.
      //
      //   * worse, the WEBHOOK COULD NEVER RECOVER A MISC OR ADVANCE at all.
      //     The comment above promises a fall-through to
      //     webhook_complete_collection; the early return made it unreachable,
      //     so of the three claimants the design names -- counter, app sweep,
      //     webhook -- only two existed for these, and the sweep needs the
      //     admin app open.
      //
      // webhook_complete_collection answers all three cases itself: it claims
      // and raises the receipt, or says "already being handled" when the
      // counter beat it, or "no pending collection" when the order really is
      // unknown. Only that last case is worth waking anyone for.
      if (resultStatus === "TXN_SUCCESS") {
        try {
          const { data: coll } = await db.rpc("webhook_complete_collection", {
            p_order_id: orderId,
            p_reference: txnId ?? "",
          });
          if (coll && coll.ok === true) {
            return json({
              ok: true,
              order_id: orderId,
              action: coll.receipt
                ? "collection receipted"
                : (coll.reason ?? "collection handled"),
              receipt: coll.receipt ?? null,
              kind: coll.kind ?? null,
              txn_id: txnId,
              amount: txnAmount,
            });
          }
          // ok:false means no intent exists -- fall through and record it.
        } catch (e) {
          // Older database without the collection functions: fall through to
          // the unmatched handling rather than 500, which would make Paytm
          // retry a callback nothing can do more with.
          console.error("webhook_complete_collection unavailable: " + e);
        }
      }

      // Paytm has money for an order we have no record of (the 2026-09-29
      // Rs 30,000 case). Nothing can be raised automatically -- there is no
      // record of which fees it was for -- so make it loud instead of silent.
      console.error(
        "UNMATCHED PAYTM PAYMENT order=" + orderId + " txn=" + txnId +
          " amount=" + txnAmount,
      );
      // RECORD IT ONLY IF PAYTM ACTUALLY TOOK THE MONEY.
      //
      // This branch is reached for a final status of EITHER kind, so a FAILED
      // payment we cannot match used to be recorded as "Paytm captured money
      // ..." -- which is simply untrue. On 05-10-2026 that put three failures
      // on the list (Rs 48,225, Rs 30,000, Rs 450) alongside one genuine
      // Rs 450 capture. A warning that means "money received with no receipt"
      // is worth nothing once it also means "a payment failed".
      //
      // An unmatched FAILURE needs no action: nobody paid.
      if (resultStatus === "TXN_SUCCESS") {
        try {
          await db.rpc("webhook_record_refusal", {
            p_order_id: orderId,
            p_reason: "Paytm captured money for an order with no record in the " +
              "database - cannot tell which fees it was for",
            p_ins_id: null,
            p_pay_id: null,
            p_amount: txnAmount,
          });
        } catch (e) {
        // The recording functions arrive with their own migration. Until
        // then this must stay a NO-OP, not a 500: a thrown error here
        // would make Paytm retry a callback that was handled correctly.
          console.error('webhook_record_refusal unavailable: ' + e);
        }
      }
      return json({
        ok: true,
        order_id: orderId,
        action: resultStatus === "TXN_SUCCESS"
          ? "no payment row - needs a human"
          : "no payment row, and Paytm says it failed - no action",
        txn_id: txnId,
        amount: txnAmount,
      });
    }

    if (row.paystatus === "C") {
      return json({
        ok: true,
        order_id: orderId,
        action: "already receipted",
        paynumber: row.paynumber,
      });
    }

    if (resultStatus === "TXN_FAILURE") {
      await db.rpc("webhook_fail_payment", {
        p_order_id: orderId,
        p_reference: "FAILED:" + (txnId ?? ""),
      });
      return json({ ok: true, order_id: orderId, action: "marked failed" });
    }

    // TXN_SUCCESS -- the amount Paytm actually took must match what we asked
    // for, or we would raise a receipt for the wrong figure.
    if (txnAmount > 0 && Math.abs(txnAmount - Number(row.transtotalamount)) > 0.009) {
      console.error(
        "AMOUNT MISMATCH order=" + orderId + " paytm=" + txnAmount +
          " app=" + row.transtotalamount,
      );
      // Record it. This branch answers 200 on purpose -- a retry cannot help
      // and Paytm would keep retrying forever -- so without a row the only
      // trace is this log line, and Paytm is holding money the college has no
      // receipt for. fee_health_check() reads webhook_refusal.
      try {
  await db.rpc("webhook_record_refusal", {
          p_order_id: orderId,
          p_reason: "amount mismatch - Paytm took " + txnAmount +
            ", the attempt asked for " + row.transtotalamount,
          p_ins_id: row.ins_id ?? null,
          p_pay_id: row.pay_id ?? null,
          p_amount: txnAmount,
        });
      } catch (e) {
        // The recording functions arrive with their own migration. Until
        // then this must stay a NO-OP, not a 500: a thrown error here
        // would make Paytm retry a callback that was handled correctly.
        console.error('webhook_record_refusal unavailable: ' + e);
      }
      return json({
        ok: true,
        order_id: orderId,
        action: "amount mismatch - needs a human",
        paytm_amount: txnAmount,
        app_amount: row.transtotalamount,
      });
    }

    // Stamped "PAYTM-WH:" so a receipt the SERVER raised is identifiable
    // forever. The apps write the bare Paytm txn id, so without a marker the
    // two are indistinguishable afterwards and there is no way to audit how
    // much money this function has actually saved.
    const { data: res, error: compErr } = await db.rpc("webhook_complete_payment", {
      p_order_id: orderId,
      p_reference: "PAYTM-WH:" + (txnId ? String(txnId) : orderId),
    });
    if (compErr) throw new Error("complete failed: " + compErr.message);

    return json({
      ok: true,
      order_id: orderId,
      action: "receipt raised",
      checksum_verified: checksumOk,
      result: res,
    });
  } catch (err) {
    // 500 so Paytm retries -- better a second attempt than a lost receipt.
    console.error("paytm-webhook error:", (err as Error).message);
    return json({ error: (err as Error).message }, 500);
  }
});
