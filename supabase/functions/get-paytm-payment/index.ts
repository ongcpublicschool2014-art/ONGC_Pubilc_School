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
