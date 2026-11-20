// pay-sweep -- every few minutes (Supabase cron), ask the gateways about
// online payments still open after 15 minutes, so a payment whose app was
// closed is still receipted (or closed as failed) without anyone opening a
// screen. Only asks the gateways -- calling it can never mark anything paid
// that was not. Deploy with --no-verify-jwt.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { json, serviceDb, settle, OnlineOrder } from "../_shared/gateways/index.ts";

serve(async () => {
  const db = serviceDb();
  const { data, error } = await db.rpc("online_orders_open", { p_minutes: 15 });
  if (error) return json({ error: error.message }, 500);
  const out: Array<Record<string, unknown>> = [];
  for (const o of (data ?? []) as OnlineOrder[]) {
    try {
      out.push({ order_id: o.order_id, ...(await settle(db, o)) });
    } catch (e) {
      out.push({ order_id: o.order_id, error: (e as Error).message });
    }
  }
  return json({ checked: out.length, results: out });
});
