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
import { generateSignature } from "../_shared/paytm_checksum.ts";
import { resolveMerchant } from "../_shared/paytm_merchant.ts";

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
