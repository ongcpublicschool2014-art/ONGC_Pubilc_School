// Paytm -- the same calls as the proven college functions (create-paytm-order,
// get-paytm-payment), with the school's own MID / key / website from Setup
// instead of the PAYTM_* server secrets. Signing reuses ../paytm_checksum.ts.

import { generateSignature } from "../paytm_checksum.ts";
import { Adapter, Creds, GatewayError, need } from "./types.ts";

// Paytm runs two sets of servers: paytmpayments.com (newer accounts, and the
// college's) and paytm.in (many older accounts). An order sent to the wrong
// one is refused with "System Error". Setup > Payment Gateways can name the
// host; blank = paytmpayments.com.
const host = (c: Creds) => {
  const h = (c.config.host ?? "").trim().replace(/\/+$/, "");
  if (h) return /^https?:\/\//i.test(h) ? h : `https://${h}`;
  return c.mode === "LIVE" ? "https://secure.paytmpayments.com" : "https://securestage.paytmpayments.com";
};

async function orderStatus(c: Creds, orderId: string) {
  const mid = need(c.config, "mid", "Paytm Merchant ID");
  const key = need(c.secret, "merchant_key", "Paytm Merchant Key");
  const body = { mid, orderId };
  const signature = await generateSignature(JSON.stringify(body), key);
  const r = await fetch(`${host(c)}/v3/order/status`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ body, head: { signature } }),
  });
  return await r.json();
}

export const paytm: Adapter = {
  async create(c, input) {
    const mid = need(c.config, "mid", "Paytm Merchant ID");
    const key = need(c.secret, "merchant_key", "Paytm Merchant Key");
    const website = c.config.website?.trim() || (c.mode === "LIVE" ? "DEFAULT" : "WEBSTAGING");
    const h = host(c);
    // The mobile All-in-One SDK watches for this exact callback URL; the
    // desktop JS Checkout never redirects. Same as the college function.
    const app = input.channel === "APP";
    const body = {
      requestType: "Payment",
      mid,
      websiteName: website,
      orderId: input.orderId,
      // Never empty: a merchant with no default callback set up at Paytm has
      // its orders refused ("System Error") when this is blank. The counter's
      // JS Checkout (redirect: false) does not navigate to it; pay-return
      // only asks Paytm for the verdict if anything is ever posted there.
      callbackUrl: app
        ? `${h}/theia/paytmCallback?ORDER_ID=${input.orderId}`
        : (input.returnUrl ||
          `${Deno.env.get("SUPABASE_URL") ?? ""}/functions/v1/pay-return?order=${encodeURIComponent(input.orderId)}`),
      txnAmount: { value: input.amount.toFixed(2), currency: "INR" },
      userInfo: { custId: input.customer.id },
      ...(app ? { channelId: "WAP" } : {}),
      // Paytm split settlement: each fee group's share to its child MID.
      // (Split settlement must be enabled on the merchant by Paytm.)
      ...(input.splits?.length
        ? {
          // Same shape as the college's create-paytm-order.
          splitSettlementInfo: {
            splitType: "AT_TXN",
            splitMethod: "AMOUNT",
            splitInfo: input.splits.map((s) => ({
              mid: s.account,
              amount: { value: s.amount.toFixed(2), currency: "INR" },
              splitReferenceId: `${input.orderId}-${s.fg_id}`,
            })),
          },
        }
        : {}),
    };
    const signature = await generateSignature(JSON.stringify(body), key);
    const r = await fetch(`${h}/theia/api/v1/initiateTransaction?mid=${mid}&orderId=${input.orderId}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ body, head: { signature } }),
    });
    const data = await r.json();
    const token = data?.body?.txnToken;
    if (!token) {
      // Code and status too: Paytm support asks for them, and "System Error"
      // alone covers many different causes.
      const ri = data?.body?.resultInfo ?? {};
      console.error("paytm initiateTransaction refused:", JSON.stringify(ri), "host:", h, "mid:", mid);
      throw new GatewayError(
        `Paytm refused the order: ${ri.resultMsg ?? "no txnToken"}` +
          (ri.resultCode ? ` (code ${ri.resultCode}${ri.resultStatus ? `, ${ri.resultStatus}` : ""})` : ""),
      );
    }
    return {
      checkout: { kind: "paytm", mid, txn_token: token, order_id: input.orderId, amount: input.amount.toFixed(2), host: h },
    };
  },

  async status(c, o) {
    const data = await orderStatus(c, o.orderId);
    const s = data?.body?.resultInfo?.resultStatus;
    const amount = Number(data?.body?.txnAmount ?? NaN);
    if (s === "TXN_SUCCESS") {
      return { state: "captured", reference: data?.body?.txnId ?? undefined, amount: isNaN(amount) ? undefined : amount, raw: data };
    }
    // "Invalid Order Id" (334): Paytm has no transaction for it at all. Not a
    // decline -- never treated as one while the payer may still be paying.
    const ri = data?.body?.resultInfo ?? {};
    if (String(ri.resultCode ?? "") === "334" || /invalid order|no record/i.test(String(ri.resultMsg ?? ""))) {
      return { state: "not_found", raw: data };
    }
    if (s === "TXN_FAILURE") return { state: "failed", reference: data?.body?.txnId ?? undefined, raw: data };
    return { state: "pending", raw: data }; // PENDING
  },

  async webhookOrderId(raw) {
    // Form (browser callback) or JSON (dashboard webhook, fields under body).
    try {
      const j = JSON.parse(raw);
      return j?.ORDERID ?? j?.orderId ?? j?.body?.orderId ?? j?.body?.ORDERID ?? null;
    } catch {
      const p = new URLSearchParams(raw);
      return p.get("ORDERID") ?? p.get("orderId");
    }
  },

  async test(c) {
    const data = await orderStatus(c, `TEST${Date.now()}`);
    const info = data?.body?.resultInfo ?? {};
    const msg = `${info.resultMsg ?? "no answer"}`;
    // An unknown order means Paytm accepted our MID and signature.
    if (/checksum|invalid mid|merchant/i.test(msg) && !/order/i.test(msg)) return { ok: false, message: `Paytm: ${msg}` };
    // That alone passed for accounts that still could not take a payment
    // ("System Error" on every order). So also open a Rs 1 order exactly as a
    // payment would: it is never shown to anyone, never paid, and expires.
    try {
      await this.create(c, {
        orderId: `TEST${Date.now()}`,
        amount: 1,
        customer: { id: "SETUPTEST", name: "Setup Test", mobile: "", email: "" },
        returnUrl: "",
        notifyUrl: "",
        channel: "COUNTER",
      });
    } catch (e) {
      return {
        ok: false,
        message: `Paytm knows this Merchant ID, but ${(e as Error).message}. Re-paste the Merchant Key (copy it, do not ` +
          `type it), check the Website Name, and ask Paytm whether the MID is activated for ${c.mode === "LIVE" ? "Live" : "Test"} payments.`,
      };
    }
    return { ok: true, message: "Paytm accepted the Merchant ID and key, and can create payment orders." };
  },
};
