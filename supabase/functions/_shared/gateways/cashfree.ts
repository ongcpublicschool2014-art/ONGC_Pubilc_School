// Cashfree Payment Gateway (PG), API version 2023-08-01.
// Docs: cashfree.com/docs/api-reference/payments
//   create POST {base}/orders           -> payment_session_id (opened with Cashfree's JS checkout)
//   order  GET  {base}/orders/{id}      -> order_status PAID / ACTIVE / EXPIRED / TERMINATED
//   pays   GET  {base}/orders/{id}/payments -> cf_payment_id, payment_status SUCCESS ...
// Webhook: x-webhook-signature = Base64(HMAC-SHA256(timestamp + rawBody, secret key)).

import { hmacSha256B64, safeEqual } from "./crypto.ts";
import { Adapter, Creds, GatewayError, need } from "./types.ts";

const base = (c: Creds) => (c.mode === "LIVE" ? "https://api.cashfree.com/pg" : "https://sandbox.cashfree.com/pg");

function headers(c: Creds) {
  return {
    "Content-Type": "application/json",
    "x-api-version": "2023-08-01",
    "x-client-id": need(c.config, "app_id", "Cashfree App ID"),
    "x-client-secret": need(c.secret, "secret_key", "Cashfree Secret Key"),
  };
}

export const cashfree: Adapter = {
  async create(c, input) {
    const phone = (input.customer.mobile || "").replace(/\D/g, "").slice(-10) || "9999999999";
    const r = await fetch(`${base(c)}/orders`, {
      method: "POST",
      headers: headers(c),
      body: JSON.stringify({
        order_id: input.orderId,
        order_amount: Number(input.amount.toFixed(2)),
        order_currency: "INR",
        customer_details: {
          customer_id: input.customer.id.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 50) || "STUDENT",
          customer_phone: phone,
          customer_name: input.customer.name.slice(0, 100),
          ...(input.customer.email ? { customer_email: input.customer.email } : {}),
        },
        order_meta: { return_url: input.returnUrl, notify_url: input.notifyUrl },
        // Expires after 30 minutes, so an abandoned order is reported EXPIRED
        // (closed) instead of staying open for weeks.
        order_expiry_time: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
        // Cashfree Easy Split: each fee group's share to its vendor.
        ...(input.splits?.length
          ? { order_splits: input.splits.map((s) => ({ vendor_id: s.account, amount: Number(s.amount.toFixed(2)) })) }
          : {}),
      }),
    });
    const d = await r.json();
    if (!d?.payment_session_id) throw new GatewayError(`Cashfree refused the order: ${d?.message ?? r.status}`);
    return {
      gwOrderId: d.cf_order_id ? String(d.cf_order_id) : undefined,
      checkout: {
        kind: "cashfree",
        payment_session_id: d.payment_session_id,
        order_id: input.orderId,
        env: c.mode === "LIVE" ? "production" : "sandbox",
      },
    };
  },

  async status(c, o) {
    const orderId = o.orderId;
    const r = await fetch(`${base(c)}/orders/${encodeURIComponent(orderId)}`, { headers: headers(c) });
    const d = await r.json();
    if (r.status === 404) return { state: "pending", raw: d };
    if (!r.ok) throw new GatewayError(`Cashfree status failed: ${d?.message ?? r.status}`);
    if (d?.order_status === "PAID") {
      const pr = await fetch(`${base(c)}/orders/${encodeURIComponent(orderId)}/payments`, { headers: headers(c) });
      const pays: Array<Record<string, unknown>> = (await pr.json().catch(() => [])) ?? [];
      const ok = Array.isArray(pays) ? pays.find((p) => p.payment_status === "SUCCESS") : undefined;
      return {
        state: "captured",
        reference: ok ? String(ok.cf_payment_id) : String(d.cf_order_id ?? orderId),
        amount: Number(ok?.payment_amount ?? d.order_amount),
        raw: d,
      };
    }
    if (d?.order_status === "EXPIRED" || d?.order_status === "TERMINATED") return { state: "failed", raw: d };
    return { state: "pending", raw: d };
  },

  async webhookOrderId(raw, hdrs, c) {
    const sig = hdrs.get("x-webhook-signature") ?? "";
    const ts = hdrs.get("x-webhook-timestamp") ?? "";
    const key = (c.secret?.secret_key ?? "").trim();
    if (sig && ts && key) {
      if (!safeEqual(await hmacSha256B64(key, ts + raw), sig)) return null;
    }
    try {
      return JSON.parse(raw)?.data?.order?.order_id ?? null;
    } catch {
      return null;
    }
  },

  async test(c) {
    const r = await fetch(`${base(c)}/orders/TEST${Date.now()}`, { headers: headers(c) });
    if (r.status === 401 || r.status === 403) {
      const d = await r.json().catch(() => ({}));
      return { ok: false, message: `Cashfree: ${d?.message ?? "authentication failed"}` };
    }
    return { ok: true, message: "Cashfree accepted the App ID and Secret Key." };
  },
};
