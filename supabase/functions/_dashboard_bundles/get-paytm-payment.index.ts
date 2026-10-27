// ===========================================================================
// SELF-CONTAINED BUILD -- paste this whole file into the Supabase dashboard.
//
// WHY THIS FILE EXISTS: the real source is supabase/functions/get-paytm-payment/index.ts,
// which imports the two shared Paytm modules from the sibling _shared folder.
// The CLI bundles those automatically; the dashboard editor only has the one
// file you paste, so it fails with "Module not found ... paytm_checksum.ts".
// Both modules are inlined below, unchanged.
//
// THIS IS A BUILD ARTEFACT -- DO NOT EDIT IT. Change the real source and
// regenerate, or the dashboard copy and the repo will silently diverge.
// ===========================================================================

// get-paytm-payment
//
// Server-side Paytm "Transaction Status" call. Mirrors get-razorpay-payment so
// the Flutter polling loop can reuse the same {status, payment_id} shape:
//   status: 'captured' | 'failed' | 'pending'
//   payment_id: Paytm txnId (the gateway reference we store as payreference)
//
// This is the authoritative source of truth — never trust the browser
// callback alone. Required env vars: PAYTM_MID, PAYTM_MERCHANT_KEY, PAYTM_HOST.
//
// Ref: https://www.paytmpayments.com/docs/api/v3/transaction-status-api

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// --- inlined from _shared/paytm_checksum.ts --------------------------------
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

// --- inlined from _shared/paytm_merchant.ts --------------------------------
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

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // mid (optional): the merchant the order was created under. Must match so
    // the status query is signed with the right key.
    const { order_id, mid: requestedMid } = await req.json();

    if (!order_id) {
      return new Response(JSON.stringify({ error: "Missing order_id" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { mid, key, host } = resolveMerchant(requestedMid);

    const body = { mid, orderId: String(order_id) };
    const signature = await generateSignature(JSON.stringify(body), key);
    const payload = { body, head: { signature } };

    const paytmResp = await fetch(`${host}/v3/order/status`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await paytmResp.json();

    const resultStatus = data?.body?.resultInfo?.resultStatus;
    const txnId = data?.body?.txnId ?? null;

    // Map Paytm result status onto the Razorpay-style vocabulary the client
    // polling loop already understands.
    let status: "captured" | "failed" | "pending";
    if (resultStatus === "TXN_SUCCESS") {
      status = "captured";
    } else if (resultStatus === "TXN_FAILURE") {
      status = "failed";
    } else {
      status = "pending"; // PENDING / NO_RECORD_FOUND / not yet attempted
    }

    return new Response(
      JSON.stringify({
        status,
        payment_id: txnId,
        result_status: resultStatus ?? null,
        result_info: data?.body?.resultInfo ?? null,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
