// pg-test -- Setup > Payment Gateways > Test Connection.
// POST { token, pg_id } -> { ok, message }. Admin only (pg_list checks it).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { adapterFor, cors, json, loadCreds, serviceDb } from "../_shared/gateways/index.ts";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { token, pg_id, ban_id } = await req.json();
    const db = serviceDb();
    const { data: list, error } = await db.rpc("pg_list", { p_token: token });
    if (error) return json({ ok: false, message: error.message }, 401);
    const mine = (list?.gateways ?? []).some((g: { pg_id: number }) => g.pg_id === Number(pg_id));
    if (!mine) return json({ ok: false, message: "Gateway not found." }, 404);
    const creds = await loadCreds(db, Number(pg_id), ban_id ? Number(ban_id) : null);
    return json(await adapterFor(creds.provider).test(creds));
  } catch (e) {
    return json({ ok: false, message: (e as Error).message });
  }
});
