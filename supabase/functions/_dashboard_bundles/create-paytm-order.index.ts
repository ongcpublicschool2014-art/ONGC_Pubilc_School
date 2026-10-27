// ===========================================================================
// SELF-CONTAINED BUILD -- paste this whole file into the Supabase dashboard.
//
// WHY THIS FILE EXISTS: the real source is supabase/functions/create-paytm-order/index.ts,
// which imports the two shared Paytm modules from the sibling _shared folder.
// The CLI bundles those automatically; the dashboard editor only has the one
// file you paste, so it fails with "Module not found ... paytm_checksum.ts".
// Both modules are inlined below, unchanged.
//
// THIS IS A BUILD ARTEFACT -- DO NOT EDIT IT. Change the real source and
// regenerate, or the dashboard copy and the repo will silently diverge.
// ===========================================================================

// create-paytm-order
//
// Server-side Paytm "Initiate Transaction" call. Mirrors create-razorpay-order:
// the merchant key (secret) stays here, never in the Flutter client. Returns a
// txnToken the JS Checkout SDK needs to render the payment page.
//
// Required env vars (set via `supabase secrets set` — take these from the Paytm
// dashboard's "Test API Details", NOT from onboarding mails):
//   PAYTM_MID            staging: Krishn06051431858637   (from dashboard, non-secret)
//   PAYTM_MERCHANT_KEY   the dashboard "Merchant Key"    (SECRET — never commit)
//   PAYTM_WEBSITE        staging: DEFAULT
//   PAYTM_HOST           staging: https://securestage.paytmpayments.com
//   PAYTM_CALLBACK_URL   optional server-side callback/webhook URL
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  (already present)
//
// Ref: https://www.paytmpayments.com/docs/jscheckout-initiate-payment

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
    // amount: rupees (e.g. 1500.00). pay_id: our payment row id.
    // mid (optional): route to a specific merchant (fee group's bank.paytm_mid).
    // channel_id (optional): "WEB" (default, web/desktop JS Checkout) or "WAP"
    //   (mobile native All-in-One SDK -> UPI Intent). Omitted for web/desktop so
    //   the order body stays byte-for-byte identical to the proven WEB flow.
    const { amount, pay_id, cust_id, order_id, mid: requestedMid, split_mid: splitMid,
      channel_id: channelIdRaw } = await req.json();
    const channelId = (channelIdRaw && String(channelIdRaw).trim()) || "";

    // pay_id is compared against null/undefined, NOT tested for truthiness:
    // `!pay_id` also rejects 0, and a Misc receipt has no payment row to quote.
    // That is what made every Misc Paytm payment fail with "missing fields".
    if (!amount || pay_id === undefined || pay_id === null) {
      return new Response(
        JSON.stringify({ error: "Missing required fields (amount, pay_id)" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { mid, key, website, host } = resolveMerchant(requestedMid);

    // Unique, stable order id. Reuse a caller-supplied one on retry so the
    // same attempt isn't double-charged.
    const orderId = (order_id && String(order_id)) || `PAY-${pay_id}`;

    // The mobile All-in-One SDK detects payment completion by watching for this
    // EXACT callback URL; it MUST equal the callbackUrl the app passes to the SDK
    // (${host}/theia/paytmCallback?ORDER_ID=<orderId>) or Paytm's page loads and
    // 404s. For mobile (channel_id=WAP) hard-set the matching URL; web/desktop
    // (JS Checkout, redirect:false) never redirect, so keep the env/empty value
    // — byte-for-byte unchanged from today's proven flow.
    const callbackUrl = channelId
      ? `${host}/theia/paytmCallback?ORDER_ID=${orderId}`
      : (Deno.env.get("PAYTM_CALLBACK_URL") ?? "");

    // Split Settlement (per-unit banking): settle 100% of this transaction to
    // the paying unit's child MID. Only attached when the client sends a
    // split_mid (PaytmConfig.splitSettlement = true). Requires Paytm to have
    // enabled Split Settlement on the parent MID and onboarded the child MID
    // with its bank account, else initiateTransaction rejects the request.
    const splitTarget = splitMid && String(splitMid).trim();
    const splitSettlement = splitTarget
      ? {
        splitSettlementInfo: {
          splitType: "AT_TXN",
          splitMethod: "AMOUNT",
          splitInfo: [
            {
              mid: String(splitMid).trim(),
              amount: { value: Number(amount).toFixed(2), currency: "INR" },
              splitReferenceId: String(pay_id),
            },
          ],
        },
      }
      : {};

    const body = {
      requestType: "Payment",
      mid,
      websiteName: website,
      orderId,
      callbackUrl,
      txnAmount: { value: Number(amount).toFixed(2), currency: "INR" },
      userInfo: { custId: cust_id ? String(cust_id) : `CUST-${pay_id}` },
      ...(channelId ? { channelId } : {}),   // WAP for mobile; omitted for WEB
      ...splitSettlement,
    };

    const signature = await generateSignature(JSON.stringify(body), key);
    const payload = { body, head: { signature } };

    const url =
      `${host}/theia/api/v1/initiateTransaction?mid=${mid}&orderId=${orderId}`;
    const paytmResp = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await paytmResp.json();

    const txnToken = data?.body?.txnToken;
    const resultInfo = data?.body?.resultInfo;

    if (!txnToken) {
      return new Response(
        JSON.stringify({
          error: "Paytm did not return a txnToken",
          result_info: resultInfo ?? null,
          raw: data,
        }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // Persist the order id on the payment row. Skipped when there is no
    // payment row (Misc/Advance pass a negative sentinel id).
    //
    // THIS USED TO BE `supabase.from("payment")`, WHICH NEVER WORKED.
    // Unqualified, that resolves to public.payment -- a table that does not
    // exist, because payment lives in <institution schema>. The update
    // matched nothing and the error was swallowed as "non-fatal: the client
    // also updates payorderid". The DESKTOP client does; the MOBILE app does
    // not, so a mobile payment's order id was never written anywhere.
    //
    // Everything downstream keys on payorderid: webhook_find_payment matches
    // only on it, _sweepOrphanedPayments needs it to ask Paytm, and
    // create_pending_payment deletes rows that lack it. So an unstamped
    // mobile payment could be captured by Paytm and then have its own row
    // deleted by the next retry -- which is how KANNAN D's Rs 5,125 of
    // 11-10-2026 went missing.
    //
    // stamp_payorderid() is SECURITY DEFINER and finds the right tenant
    // schema, which this function cannot do on its own.
    if (pay_id !== undefined && pay_id !== null && Number(pay_id) > 0) {
      const supabase = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      );
      const { data: stamped, error: stampErr } = await supabase.rpc(
        "stamp_payorderid",
        { p_pay_id: Number(pay_id), p_order_id: orderId },
      );
      // NOT swallowed any more. An order exists at Paytm now, but nothing has
      // been charged -- the checkout has not opened. Refusing here costs the
      // payer one retry; letting it through costs a payment nobody can trace
      // back to a student. The abandoned order simply expires.
      if (stampErr || stamped !== true) {
        return new Response(
          JSON.stringify({
            error:
              "Could not record the payment order against the payment row. " +
              "The payment was NOT started -- please try again.",
            detail: stampErr?.message ?? "stamp_payorderid returned false",
            order_id: orderId,
            pay_id,
          }),
          {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          },
        );
      }
    }

    return new Response(
      JSON.stringify({
        order_id: orderId,
        txn_token: txnToken,
        mid,
        amount: Number(amount).toFixed(2),
        result_info: resultInfo ?? null,
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
