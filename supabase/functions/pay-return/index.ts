// pay-return -- where a gateway sends the payer back after its payment page
// (PhonePe, Cashfree, Easebuzz redirect here; GET or POST).
//
// Asks the gateway for the verdict (the redirect itself proves nothing) and
// shows a plain page. The apps watch for this URL to close their window.
// Deploy with --no-verify-jwt (the browser carries no Supabase token).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { loadOrder, serviceDb, settle } from "../_shared/gateways/index.ts";

const page = (title: string, text: string, ok: boolean) =>
  new Response(
    `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>body{font-family:system-ui,sans-serif;background:#f5f1e8;color:#14302c;display:flex;
min-height:100vh;align-items:center;justify-content:center;margin:0}.c{background:#fff;padding:32px 40px;border-radius:14px;
max-width:420px;text-align:center;box-shadow:0 12px 28px -22px #0006}h1{font-size:22px;color:${ok ? "#0f6b63" : "#c8453a"}}
p{color:#4a5d59}</style></head><body><div class="c"><h1>${title}</h1><p>${text}</p><p>You can close this window.</p></div></body></html>`,
    { headers: { "Content-Type": "text/html; charset=utf-8" } },
  );

serve(async (req) => {
  const url = new URL(req.url);
  let orderId = url.searchParams.get("order") ?? "";
  if (!orderId && req.method === "POST") {
    const raw = await req.text();
    orderId = new URLSearchParams(raw).get("txnid") ?? "";
  }
  if (!orderId) return page("Payment", "No payment was named.", false);
  try {
    const db = serviceDb();
    const o = await loadOrder(db, orderId);
    if (!o) return page("Payment", "This payment could not be found.", false);
    const r = await settle(db, o) as Record<string, unknown>;
    if (r.status === "C") return page("Payment received", "Thank you. The receipt has been raised.", true);
    if (r.status === "F") return page("Payment not completed", "No money was taken. You can try again.", false);
    if (r.status === "X") return page("Payment received", "The school office will issue the receipt.", true);
    return page("Payment in progress", "The bank has not confirmed it yet. The receipt follows automatically.", true);
  } catch (_) {
    return page("Payment in progress", "We could not confirm it right now. The receipt follows automatically.", true);
  }
});
