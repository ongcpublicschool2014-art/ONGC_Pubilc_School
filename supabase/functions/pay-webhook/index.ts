// pay-webhook -- server-to-server callbacks from every gateway.
//
// URL: .../functions/v1/pay-webhook?pg=<pg_id>  (shown in Setup > Payment Gateways)
// The callback is only a nudge: we find our order in it (checking the
// gateway's signature where the gateway signs it), then ask the gateway for
// the verdict with the school's own key and act on that -- exactly the
// college paytm-webhook's approach. Idempotent; a 500 makes the gateway retry.
// Deploy with --no-verify-jwt.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { adapterFor, json, loadCreds, loadOrder, serviceDb, settle } from "../_shared/gateways/index.ts";

/// Our order id (S<ins>P<pay>T<ms>) anywhere in a callback body.
function findOrderId(raw: string): string | null {
  const m = raw.match(/S\d+P\d+T\d+/);
  return m ? m[0] : null;
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const q = new URL(req.url).searchParams;
    const pgId = Number(q.get("pg"));
    const banId = Number(q.get("ban")) || null; // a bank's own merchant (&ban=<ban_id>)
    if (!pgId) return json({ error: "missing ?pg=" }, 400);
    const raw = await req.text();
    const db = serviceDb();
    // Find OUR order first. The callback is only a nudge: settle() asks the
    // gateway with the order's own merchant keys, so a callback whose
    // signature cannot be checked here (URL without &ban=, gateway re-added
    // under a new id) still leads to the right status check, and a forged one
    // achieves nothing but that check.
    let orderId: string | null = null;
    try {
      const creds = await loadCreds(db, pgId, banId);
      orderId = await adapterFor(creds.provider).webhookOrderId(raw, req.headers, creds);
    } catch (_) {
      // gateway deleted / keys gone: fall back to reading the id
    }
    orderId = orderId ?? findOrderId(raw);
    if (!orderId) return json({ ok: true, action: "ignored (no order id)" });
    const o = await loadOrder(db, orderId);
    if (!o) return json({ ok: true, action: "not our order", order_id: orderId });
    const r = await settle(db, o);
    return json({ ok: true, order_id: orderId, ...r });
  } catch (e) {
    console.error("pay-webhook:", (e as Error).message);
    return json({ error: (e as Error).message }, 500);
  }
});
