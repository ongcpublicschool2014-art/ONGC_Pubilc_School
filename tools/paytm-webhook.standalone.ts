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

// ===================================================================
// BUNDLED FOR THE DASHBOARD EDITOR -- generated, do not edit here.
//
// The deployed source of truth is three files:
//     supabase/functions/paytm-webhook/index.ts
//     supabase/functions/_shared/paytm_checksum.ts
//     supabase/functions/_shared/paytm_merchant.ts
//
// They are inlined below because the dashboard editor cannot resolve the
// ../_shared/ imports. Deploying with the CLI uses the three files and does
// not need this bundle at all:
//
//     supabase functions deploy paytm-webhook \
//       --project-ref <ref> --no-verify-jwt
//
// --no-verify-jwt IS REQUIRED. Paytm authenticates with its own CHECKSUMHASH,
// not a Supabase JWT; with JWT verification on, every callback is rejected
// before this code runs.
//
// If you change the behaviour, change the three files and regenerate -- an
// edit made only in the dashboard is lost on the next CLI deploy.
// ===================================================================

// ---- inlined from _shared/paytm_checksum.ts -----------------------
// Paytm checksum (signature) helper for Deno edge functions.
//
// Port of the official PaytmChecksum library's generate/verify routines.
// Algorithm:
//   1. salt = 4 random alphanumeric chars
//   2. hash = SHA256(params + "|" + salt)  (hex)
//   3. finalString = hash + salt
//   4. checksum = base64( AES-128-CBC encrypt(finalString) ) with the
//      merchant key as the AES key and the fixed IV below.
//
// Verify decrypts the checksum, splits off the trailing 4-char salt, and
// re-hashes to confirm. The merchant key must be 16 chars (AES-128).
//
// Ref: https://www.paytmpayments.com/docs/checksum

const IV = "@@@@&&&&####$$$$"; // fixed 16-byte IV used by PaytmChecksum
const SALT_CHARS =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function toBase64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function fromBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function randomSalt(length = 4): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  let s = "";
  for (const b of bytes) s += SALT_CHARS[b % SALT_CHARS.length];
  return s;
}

async function importKey(key: string): Promise<CryptoKey> {
  // AES-128-CBC requires a 16-byte key. Paytm merchant keys are 16 chars.
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(key),
    { name: "AES-CBC" },
    false,
    ["encrypt", "decrypt"],
  );
}

/// Generate a Paytm signature over `params` (usually JSON.stringify(body)).
async function generateSignature(
  params: string,
  key: string,
): Promise<string> {
  const salt = randomSalt(4);
  const hash = await sha256Hex(params + "|" + salt);
  const finalString = hash + salt;
  const cryptoKey = await importKey(key);
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-CBC", iv: encoder.encode(IV) },
    cryptoKey,
    encoder.encode(finalString),
  );
  return toBase64(new Uint8Array(encrypted));
}

/// Verify a Paytm signature (e.g. on webhook/callback payloads).
async function verifySignature(
  params: string,
  key: string,
  checksum: string,
): Promise<boolean> {
  try {
    const cryptoKey = await importKey(key);
    const decrypted = await crypto.subtle.decrypt(
      { name: "AES-CBC", iv: encoder.encode(IV) },
      cryptoKey,
      fromBase64(checksum),
    );
    const decryptedStr = decoder.decode(decrypted);
    const salt = decryptedStr.slice(-4);
    const hash = decryptedStr.slice(0, -4);
    const expected = await sha256Hex(params + "|" + salt);
    return hash === expected;
  } catch (_) {
    return false;
  }
}

// ---- inlined from _shared/paytm_merchant.ts -----------------------
// Resolve a Paytm merchant (MID + secret key) for a request.
//
// Secrets live server-side only. Two env layouts are supported:
//   * PAYTM_MID + PAYTM_MERCHANT_KEY        — the single default merchant.
//   * PAYTM_MERCHANTS (JSON)                — multi-merchant routing, a map of
//       { "<mid>": "<merchantKey>", ... }   so each IOBPAY entity (KCET,
//       Hostel, Arts&Science, Polytechnic) settles to its own bank account.
//
// Resolution given an optional requested `mid` (from the fee group's bank):
//   - mid in PAYTM_MERCHANTS            -> that mid + its key
//   - mid === PAYTM_MID                 -> default key
//   - mid given, PAYTM_SUBMERCHANT_MODE -> that (sub) mid + the PARENT key
//                                          (aggregator: sub MIDs share one key)
//   - no mid                            -> default merchant
//   - mid given but unknown            -> throws (don't silently mis-route money)

interface PaytmMerchant {
  mid: string;
  key: string;
  website: string;
  host: string;
}

function resolveMerchant(requestedMid?: string | null): PaytmMerchant {
  const website = Deno.env.get("PAYTM_WEBSITE") ?? "WEBSTAGING";
  const host = Deno.env.get("PAYTM_HOST") ??
    "https://securestage.paytmpayments.com";

  const defaultMid = Deno.env.get("PAYTM_MID") ?? "";
  const defaultKey = Deno.env.get("PAYTM_MERCHANT_KEY") ?? "";

  // Aggregator / sub-merchant mode: sub MIDs are linked under the parent and
  // have NO own key, so a transaction runs under the requested sub MID but is
  // signed with the PARENT (default) key. Gated by env so an unknown MID is
  // never silently signed unless this is deliberately enabled.
  const subMerchantMode = Deno.env.get("PAYTM_SUBMERCHANT_MODE") === "true";

  let merchants: Record<string, string> = {};
  const raw = Deno.env.get("PAYTM_MERCHANTS");
  if (raw) {
    try {
      merchants = JSON.parse(raw) as Record<string, string>;
    } catch (_) {
      throw new Error("PAYTM_MERCHANTS is not valid JSON");
    }
  }

  const mid = (requestedMid && String(requestedMid).trim()) || "";

  if (mid) {
    if (merchants[mid]) return { mid, key: merchants[mid], website, host };
    if (mid === defaultMid && defaultKey) {
      return { mid, key: defaultKey, website, host };
    }
    // Sub MID linked under the parent — sign with the parent key.
    if (subMerchantMode && defaultKey) {
      return { mid, key: defaultKey, website, host };
    }
    throw new Error(`No merchant key configured for MID ${mid}`);
  }

  if (!defaultMid || !defaultKey) {
    throw new Error("Payment gateway not configured");
  }
  return { mid: defaultMid, key: defaultKey, website, host };
}

// ---- paytm-webhook/index.ts ---------------------------------------

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
      // Paytm has money for an order we have no record of (the 2026-09-29
      // Rs 30,000 case). Nothing can be raised automatically -- there is no
      // record of which fees it was for -- so make it loud instead of silent.
      console.error(
        "UNMATCHED PAYTM PAYMENT order=" + orderId + " txn=" + txnId +
          " amount=" + txnAmount,
      );
      // Loud in the log is not loud enough -- nobody reads it. Record it so
      // fee_health_check() reports it every day until a person deals with it.
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
      return json({
        ok: true,
        order_id: orderId,
        action: "no payment row - needs a human",
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
