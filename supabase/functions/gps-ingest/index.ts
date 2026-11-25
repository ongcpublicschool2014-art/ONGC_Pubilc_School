// gps-ingest -- positions from the buses' GPS trackers (2026-11-20).
//
// A tracker platform (or a Traccar server, for trackers that speak a TCP
// protocol such as GT06) sends each position here over HTTPS:
//   https://<project>.supabase.co/functions/v1/gps-ingest?key=<GPS_INGEST_KEY>&id=<IMEI>&lat=..&lon=..&timestamp=..&speed=..
// or POSTs JSON (formats in ../_shared/gps_formats.ts). The device must be in
// Transport > Vehicles > GPS Devices (by IMEI) and on a vehicle in GPS
// Mapping. Positions go to public.tr_gps_ingest (service role only), which
// keeps them and moves the vehicle on the parents' School Bus map.
//
// Setup: secret GPS_INGEST_KEY (a long random text), and deploy WITHOUT JWT
// checks (trackers cannot send a Supabase token):
//   supabase secrets set GPS_INGEST_KEY=<key> --project-ref <ref>
//   supabase functions deploy gps-ingest --no-verify-jwt --project-ref <ref>

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { parseRequest, sameKey } from "../_shared/gps_formats.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-gps-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function reply(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "GET" && req.method !== "POST") return reply(405, { error: "GET or POST only" });

  const expected = Deno.env.get("GPS_INGEST_KEY") ?? "";
  if (expected.length < 16) return reply(503, { error: "GPS intake is not set up (GPS_INGEST_KEY)" });

  const body = req.method === "POST" ? await req.text() : "";
  if (body.length > 1_000_000) return reply(413, { error: "too large" });
  const { key, positions } = parseRequest(new URL(req.url), req.headers, body);
  if (!key || !sameKey(key, expected)) return reply(401, { error: "wrong or missing key" });
  if (positions.length === 0) return reply(400, { error: "no position found (need id/imei, lat, lon)" });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await db.rpc("tr_gps_ingest", { p_positions: positions.slice(0, 500) });
  if (error) {
    console.error("tr_gps_ingest failed", error.message);
    return reply(500, { error: "could not store the positions" });
  }
  // 200 even when some were skipped: a tracker platform would only resend
  // them, and the reasons are in the answer.
  return reply(200, data);
});
