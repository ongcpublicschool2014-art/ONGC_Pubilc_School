// pay-status -- the app asks how its payment went.
//
// POST { token, order_id, cancel? } -> { status: "I"|"C"|"F"|"X", receipts?, note? }
//   I = still open, C = paid and receipted, F = failed, X = paid at the
//   gateway but could not be receipted (needs the office).
// The answer comes from the GATEWAY (never from the app), and a "paid" answer
// raises the receipt here, on the server.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { cors, json, loadOrder, serviceDb, settle } from "../_shared/gateways/index.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { token, order_id, cancel } = await req.json();
    if (!token || !order_id) return json({ error: "token and order_id are required" }, 400);
    const db = serviceDb();
    const { data: mine, error } = await db.rpc("online_order_check_session", { p_token: token, p_order_id: order_id });
    if (error) return json({ error: error.message }, 401);
    if (mine !== true) return json({ error: "Order not found" }, 404);
    const o = await loadOrder(db, order_id);
    if (!o) return json({ error: "Order not found" }, 404);
    const r = await settle(db, o);
    // cancel: the payer backed out before paying. Only when the gateway has NO
    // payment at all for it -- "pending" means money may be moving (UPI collect,
    // QR, net banking) and the order is left open for the sweep / webhook.
    if (cancel === true && r.status === "I" && r.gateway === "not_found") {
      const { data, error: e2 } = await db.rpc("online_pay_failed", { p_order_id: order_id, p_reference: "CANCELLED" });
      if (e2) return json({ error: e2.message }, 500);
      return json({ order_id, ...(data as Record<string, unknown>) });
    }
    return json({ order_id, ...r });
  } catch (e) {
    return json({ error: (e as Error).message }, 502);
  }
});
