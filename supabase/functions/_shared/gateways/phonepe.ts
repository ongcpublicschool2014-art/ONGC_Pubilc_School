// PhonePe Payment Gateway, v2 Standard Checkout.
// Docs: developer.phonepe.com/payment-gateway/website-integration/standard-checkout
//   token  POST {auth}/v1/oauth/token (form: client_id, client_version, client_secret, grant_type)
//   pay    POST {pg}/checkout/v2/pay      -> redirectUrl
//   status GET  {pg}/checkout/v2/order/{merchantOrderId}/status -> state COMPLETED/FAILED/PENDING
// Header: Authorization: O-Bearer <access_token>. Amounts in paise.

import { sha256Hex, safeEqual } from "./crypto.ts";
import { Adapter, Creds, GatewayError, need } from "./types.ts";

function urls(c: Creds) {
  return c.mode === "LIVE"
    ? { token: "https://api.phonepe.com/apis/identity-manager/v1/oauth/token", pg: "https://api.phonepe.com/apis/pg" }
    : { token: "https://api-preprod.phonepe.com/apis/pg-sandbox/v1/oauth/token", pg: "https://api-preprod.phonepe.com/apis/pg-sandbox" };
}

// Tokens are reused until shortly before they expire (per warm function instance).
const tokens = new Map<string, { token: string; until: number }>();

async function token(c: Creds): Promise<string> {
  const k = `${c.pg_id}:${c.mode}`;
  const t = tokens.get(k);
  if (t && t.until > Date.now() / 1000 + 60) return t.token;
  const form = new URLSearchParams({
    client_id: need(c.config, "client_id", "PhonePe Client ID"),
    client_version: need(c.config, "client_version", "PhonePe Client Version"),
    client_secret: need(c.secret, "client_secret", "PhonePe Client Secret"),
    grant_type: "client_credentials",
  });
  const r = await fetch(urls(c).token, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: form.toString(),
  });
  const d = await r.json();
  if (!d?.access_token) throw new GatewayError(`PhonePe sign-in failed: ${d?.message ?? d?.code ?? r.status}`);
  tokens.set(k, { token: d.access_token, until: Number(d.expires_at ?? 0) });
  return d.access_token;
}

export const phonepe: Adapter = {
  async create(c, input) {
    if (input.splits?.length) {
      throw new GatewayError("PhonePe does not split settlements. Give each fee group its own PhonePe account instead.");
    }
    const r = await fetch(`${urls(c).pg}/checkout/v2/pay`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `O-Bearer ${await token(c)}` },
      body: JSON.stringify({
        merchantOrderId: input.orderId,
        amount: Math.round(input.amount * 100),
        expireAfter: 1200,
        paymentFlow: { type: "PG_CHECKOUT", message: "School fee payment", merchantUrls: { redirectUrl: input.returnUrl } },
      }),
    });
    const d = await r.json();
    if (!d?.redirectUrl) throw new GatewayError(`PhonePe refused the order: ${d?.message ?? d?.code ?? r.status}`);
    return { gwOrderId: d.orderId, checkout: { kind: "redirect", url: d.redirectUrl, order_id: input.orderId } };
  },

  async status(c, o) {
    const r = await fetch(`${urls(c).pg}/checkout/v2/order/${encodeURIComponent(o.orderId)}/status?details=false`, {
      headers: { "Content-Type": "application/json", Authorization: `O-Bearer ${await token(c)}` },
    });
    const d = await r.json();
    if (d?.code === "INVALID_MERCHANT_ORDER_ID") return { state: "pending", raw: d };
    const paid = (d?.paymentDetails ?? []).find((p: Record<string, unknown>) => p.state === "COMPLETED");
    if (d?.state === "COMPLETED") {
      return { state: "captured", reference: paid?.transactionId ?? d?.orderId, amount: Number(d?.amount) / 100, raw: d };
    }
    if (d?.state === "FAILED") return { state: "failed", raw: d };
    return { state: "pending", raw: d };
  },

  async webhookOrderId(raw, headers, c) {
    // SHA mode: Authorization = SHA256(username:password), when configured.
    const u = (c.secret?.webhook_username ?? "").trim(), p = (c.secret?.webhook_password ?? "").trim();
    if (u && p) {
      const got = (headers.get("authorization") ?? "").replace(/^SHA256\s+/i, "").trim().toLowerCase();
      if (!safeEqual(await sha256Hex(`${u}:${p}`), got)) return null;
    }
    try {
      return JSON.parse(raw)?.payload?.merchantOrderId ?? null;
    } catch {
      return null;
    }
  },

  async test(c) {
    try {
      await token(c);
      return { ok: true, message: "PhonePe accepted the Client ID and Secret." };
    } catch (e) {
      return { ok: false, message: (e as Error).message };
    }
  },
};
