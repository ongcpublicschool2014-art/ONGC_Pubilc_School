// Razorpay -- Orders API + Checkout. Docs: https://razorpay.com/docs/api/orders/
// The same API host serves test and live; the key (rzp_test_ / rzp_live_)
// decides. Payments must be auto-captured (Razorpay dashboard setting) --
// an 'authorized' payment is treated as still pending.

import { hmacSha256Hex, safeEqual } from "./crypto.ts";
import { Adapter, Creds, GatewayError, need } from "./types.ts";

const API = "https://api.razorpay.com/v1";

function auth(c: Creds) {
  const id = need(c.config, "key_id", "Razorpay Key ID");
  const secret = need(c.secret, "key_secret", "Razorpay Key Secret");
  return "Basic " + btoa(`${id}:${secret}`);
}

export const razorpay: Adapter = {
  async create(c, input) {
    const amountPaise = Math.round(input.amount * 100);
    const r = await fetch(`${API}/orders`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: auth(c) },
      body: JSON.stringify({
        amount: amountPaise,
        currency: "INR",
        receipt: input.orderId,
        notes: { order_id: input.orderId },
        // Razorpay Route: each fee group's share goes to its linked account
        // once the payment is captured.
        ...(input.splits?.length
          ? {
            transfers: input.splits.map((s) => ({
              account: s.account,
              amount: Math.round(s.amount * 100),
              currency: "INR",
              notes: { order_id: input.orderId, fee_group: String(s.fg_id) },
              on_hold: false,
            })),
          }
          : {}),
      }),
    });
    const data = await r.json();
    if (!r.ok || !data?.id) throw new GatewayError(`Razorpay refused the order: ${data?.error?.description ?? r.status}`);
    return {
      gwOrderId: data.id,
      checkout: {
        kind: "razorpay",
        key_id: need(c.config, "key_id", "Razorpay Key ID"),
        gw_order_id: data.id,
        order_id: input.orderId,
        amount_paise: amountPaise,
        currency: "INR",
      },
    };
  },

  async status(c, o) {
    if (!o.gwOrderId) return { state: "not_found" }; // the order never reached Razorpay
    const r = await fetch(`${API}/orders/${o.gwOrderId}/payments`, { headers: { Authorization: auth(c) } });
    const data = await r.json();
    if (!r.ok) throw new GatewayError(`Razorpay status failed: ${data?.error?.description ?? r.status}`);
    const items: Array<Record<string, unknown>> = data?.items ?? [];
    const cap = items.find((p) => p.status === "captured");
    if (cap) return { state: "captured", reference: String(cap.id), amount: Number(cap.amount) / 100, raw: data };
    // A Razorpay order stays open for retries, so failed attempts are not a
    // final failure; the order simply stays pending until it is paid. No
    // attempt at all = nobody paid yet (closed after an hour by settle()).
    if (items.length === 0) return { state: "not_found", raw: data };
    return { state: "pending", raw: data };
  },

  async webhookOrderId(raw, headers, c) {
    const sig = headers.get("x-razorpay-signature") ?? "";
    const whs = (c.secret?.webhook_secret ?? "").trim();
    if (whs && sig) {
      const want = await hmacSha256Hex(whs, raw);
      if (!safeEqual(want, sig)) return null; // forged: ignore
    }
    try {
      const j = JSON.parse(raw);
      const p = j?.payload?.payment?.entity ?? j?.payload?.order?.entity ?? {};
      return p?.notes?.order_id ?? p?.receipt ?? null;
    } catch {
      return null;
    }
  },

  async test(c) {
    const r = await fetch(`${API}/orders?count=1`, { headers: { Authorization: auth(c) } });
    if (r.ok) return { ok: true, message: "Razorpay accepted the Key ID and Secret." };
    const d = await r.json().catch(() => ({}));
    if (r.status === 401) {
      return {
        ok: false,
        message: "Razorpay did not accept this Key ID and Key Secret together. Copy both from the same key " +
          "(Razorpay dashboard > Account & Settings > API Keys, in the same Test/Live mode); " +
          "if the key was regenerated, the old secret no longer works.",
      };
    }
    return { ok: false, message: `Razorpay: ${d?.error?.description ?? r.status}` };
  },
};
