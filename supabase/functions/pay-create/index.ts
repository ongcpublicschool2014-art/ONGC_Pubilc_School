// pay-create -- start an online fee payment, for any gateway.
//
// POST { token, stu_id, items: [{dem_id, amount, fine?}], channel: "COUNTER" | "APP" }
// -> { order_id, pay_id, amount, provider, checkout }
//
// The SERVER decides the amount and the gateway (online_pay_start checks the
// session, that every fee is this student's and owes that much, and picks
// the school's gateway for those fee groups). The gateway order is created
// with the school's own credentials from Setup > Payment Gateways.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { adapterFor, cors, functionsUrl, json, loadCreds, serviceDb } from "../_shared/gateways/index.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = serviceDb();
  let orderId: string | null = null;
  try {
    const { token, stu_id, items, channel, kind, request } = await req.json();
    // kind: FEE (fee demands, default) or a counter collection -- MISC,
    // ADVANCE, ADVFEE -- whose {header, lines} the server saves on capture.
    const other = kind && String(kind).toUpperCase() !== "FEE";
    if (!token || (!other && (!stu_id || !Array.isArray(items))) || (other && !request)) {
      return json({ error: "token and stu_id + items (fees) or kind + request (collections) are required" }, 400);
    }

    const { data: start, error } = other
      ? await db.rpc("online_pay_start_other", {
        p_token: token, p_kind: kind, p_stu_id: stu_id ?? null, p_request: request, p_channel: channel ?? "COUNTER",
      })
      : await db.rpc("online_pay_start", {
        p_token: token, p_stu_id: stu_id, p_items: items, p_channel: channel ?? "COUNTER",
      });
    if (error) return json({ error: error.message, code: error.code }, 400);
    orderId = start.order_id;

    const banId: number | null = start.ban_id ?? null; // a bank's own merchant, if these fees go there
    const creds = await loadCreds(db, start.pg_id, banId);
    const result = await adapterFor(start.provider).create(creds, {
      orderId: start.order_id,
      amount: Number(start.amount),
      customer: {
        id: `STU${start.student.stu_id}`,
        name: start.student.name ?? "Student",
        mobile: start.student.mobile ?? "",
        email: start.student.email ?? "",
      },
      returnUrl: `${functionsUrl()}/pay-return?order=${encodeURIComponent(start.order_id)}`,
      notifyUrl: `${functionsUrl()}/pay-webhook?pg=${start.pg_id}${banId ? `&ban=${banId}` : ""}`,
      channel: channel === "APP" ? "APP" : "COUNTER",
      splits: Array.isArray(start.splits) ? start.splits : [],
    });
    if (result.gwOrderId) {
      // Without the gateway's own order id the payment could never be checked
      // (Razorpay), so do not send the payer to it.
      const { error: gwErr } = await db.rpc("online_order_set_gw", { p_order_id: start.order_id, p_gw_order_id: result.gwOrderId });
      if (gwErr) throw new Error(`Could not record the gateway order: ${gwErr.message}`);
    }
    return json({
      order_id: start.order_id,
      pay_id: start.pay_id,
      amount: Number(start.amount),
      provider: start.provider,
      mode: start.mode,
      checkout: result.checkout,
    });
  } catch (e) {
    // The gateway refused before anyone could pay: close the attempt so the
    // student is not blocked by the "payment in progress" guard.
    // (A supabase-js query is thenable but has no .catch(): calling it threw
    // here, turned every gateway refusal into a bare 500 and left the order
    // open. try/catch instead.)
    console.error("pay-create:", (e as Error).message);
    if (orderId) {
      try {
        await db.rpc("online_pay_failed", { p_order_id: orderId, p_reference: "NOT STARTED" });
      } catch (e2) {
        console.error("pay-create: could not close", orderId, (e2 as Error).message);
      }
    }
    return json({ error: (e as Error).message }, 502);
  }
});
