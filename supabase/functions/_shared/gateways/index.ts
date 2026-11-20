// The gateway registry + the one place a gateway's verdict is turned into a
// receipt. Used by pay-create, pay-status, pay-return, pay-webhook, pay-sweep
// and pg-test.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cashfree } from "./cashfree.ts";
import { easebuzz } from "./easebuzz.ts";
import { paytm } from "./paytm.ts";
import { phonepe } from "./phonepe.ts";
import { razorpay } from "./razorpay.ts";
import { Adapter, Creds, GatewayError, StatusResult } from "./types.ts";

export const adapters: Record<string, Adapter> = {
  PAYTM: paytm,
  RAZORPAY: razorpay,
  PHONEPE: phonepe,
  CASHFREE: cashfree,
  EASEBUZZ: easebuzz,
};

export function adapterFor(provider: string): Adapter {
  const a = adapters[(provider ?? "").toUpperCase()];
  if (!a) throw new GatewayError(`Payment gateway ${provider} is not supported.`);
  return a;
}

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

export function serviceDb(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
}

export const functionsUrl = () => `${Deno.env.get("SUPABASE_URL")}/functions/v1`;

/// [banId]: the keys of that bank's own merchant (e.g. the hostel's MID)
/// instead of the gateway's main merchant. Sent only when set, so the call
/// also works against a database without that option yet.
export async function loadCreds(db: SupabaseClient, pgId: number, banId?: number | null, mid?: string | null): Promise<Creds> {
  const args: Record<string, unknown> = { p_pg_id: pgId };
  if (banId) args.p_ban_id = banId;
  if (mid) args.p_mid = mid; // the merchant the order was opened with
  const { data, error } = await db.rpc("pg_credentials", args);
  if (error || !data) throw new GatewayError(`Payment gateway ${pgId} could not be loaded: ${error?.message ?? "not found"}`);
  return data as Creds;
}

export interface OnlineOrder {
  order_id: string;
  ins_id: number;
  pay_id: number;
  stu_id: number;
  pg_id: number;
  provider: string;
  amount: number;
  status: "I" | "C" | "F" | "X" | "H" | "T";
  gw_order_id: string | null;
  ban_id?: number | null; // under this bank's own merchant
  mid?: string | null; // the merchant id it was opened with
  mode?: string | null; // TEST / LIVE when it started
  prev_status?: string | null; // what it was when the office closed it
  createdat?: string;
  receipts: unknown;
  note: string | null;
}

export async function loadOrder(db: SupabaseClient, orderId: string): Promise<OnlineOrder | null> {
  const { data, error } = await db.rpc("online_order_get", { p_order_id: orderId });
  if (error) throw new GatewayError(`Order lookup failed: ${error.message}`);
  return (data as OnlineOrder) ?? null;
}

/// Ask the gateway about an order and act on its answer. Only the gateway's
/// own word moves money: captured -> receipt, failed -> failed, anything else
/// is left open. Safe to call any number of times.
///
/// The result carries `gateway`: what the gateway itself said
/// (captured / failed / pending / not_found), so callers can tell "nobody has
/// paid" from "money is still moving".
export async function settle(db: SupabaseClient, o: OnlineOrder): Promise<Record<string, unknown>> {
  if (o.status === "C") return { status: "C", receipts: o.receipts };
  if (o.status === "X") return { status: "X", note: o.note };
  if (o.status === "T") return { status: "T", note: o.note };
  // Office-closed is final -- except one closed while still unconfirmed
  // ("not paid"): the gateway is still asked for 3 days, and a payment that
  // arrives anyway goes back to the office (online_pay_captured makes it X).
  const reopenable = o.status === "H" && o.prev_status === "I" &&
    (!o.createdat || Date.now() - new Date(o.createdat).getTime() < 3 * 24 * 3600 * 1000);
  if (o.status === "H" && !reopenable) return { status: "H", note: o.note };

  const creds = await loadCreds(db, o.pg_id, o.ban_id, o.mid);
  // The gateway was switched between Test and Live while this was open: the
  // saved keys belong to the other system and cannot answer for it.
  if (o.mode && creds.mode !== o.mode) {
    if (o.status === "H") return { status: "H", note: o.note };
    if (o.mode === "TEST") {
      const { data } = await db.rpc("online_pay_failed", { p_order_id: o.order_id, p_reference: "NOT STARTED" });
      return { ...(data as Record<string, unknown> ?? { status: "F" }), gateway: "not_found" };
    }
    const { data } = await db.rpc("online_pay_attention", {
      p_order_id: o.order_id,
      p_note: "The gateway was switched to Test while this LIVE payment was open. Check it in the live dashboard, then receipt it by hand or mark it handled.",
    });
    return { ...(data as Record<string, unknown> ?? { status: "X" }), gateway: "pending" };
  }

  const verdict: StatusResult = await adapterFor(o.provider).status(creds, {
    orderId: o.order_id,
    gwOrderId: o.gw_order_id,
    amount: Number(o.amount),
  });
  const say = (r: Record<string, unknown>) => ({ ...r, gateway: verdict.state });
  if (verdict.state === "captured") {
    const { data, error } = await db.rpc("online_pay_captured", {
      p_order_id: o.order_id,
      p_reference: verdict.reference ?? o.order_id,
      p_amount: verdict.amount ?? null,
    });
    if (error) throw new GatewayError(`Recording failed: ${error.message}`);
    return say(data as Record<string, unknown>);
  }
  if (o.status === "H") return say({ status: "H", note: o.note });
  // The gateway has nothing for it. Within the first hour the payer may still
  // be on the payment page; after that nobody can pay it any more.
  if (verdict.state === "not_found") {
    const age = o.createdat ? Date.now() - new Date(o.createdat).getTime() : 0;
    if (o.status === "I" && age > 60 * 60 * 1000) {
      const { data, error } = await db.rpc("online_pay_failed", { p_order_id: o.order_id, p_reference: "NO RECORD" });
      if (error) throw new GatewayError(`Recording failed: ${error.message}`);
      return say(data as Record<string, unknown>);
    }
    return say({ status: o.status === "F" ? "F" : "I" });
  }
  if (verdict.state === "failed") {
    const { data, error } = await db.rpc("online_pay_failed", {
      p_order_id: o.order_id,
      p_reference: "FAILED:" + (verdict.reference ?? ""),
    });
    if (error) throw new GatewayError(`Recording failed: ${error.message}`);
    return say(data as Record<string, unknown>);
  }
  // Still open at the gateway (money may be moving). A failed / cancelled
  // order being asked again stays failed until the gateway says it was paid.
  return say({ status: o.status === "F" ? "F" : "I" });
}
