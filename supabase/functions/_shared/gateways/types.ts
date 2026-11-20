// Common shapes for every payment gateway adapter.
//
// A school chooses its gateway and enters its credentials in Setup > Payment
// Gateways (public.payment_gateway + Supabase Vault). The Edge Functions load
// them with public.pg_credentials(pg_id) and hand them to the adapter for that
// provider -- nothing here is hard-coded per school.

export type Mode = "TEST" | "LIVE";

export interface Creds {
  pg_id: number;
  ins_id: number;
  provider: string;
  mode: Mode;
  config: Record<string, string>; // public settings (MID, key id ...)
  secret: Record<string, string>; // secret settings (key, salt ...)
}

/// What the app needs to open the gateway's payment page.
export type Checkout =
  | { kind: "paytm"; mid: string; txn_token: string; order_id: string; amount: string; host: string }
  | { kind: "razorpay"; key_id: string; gw_order_id: string; order_id: string; amount_paise: number; currency: "INR" }
  | { kind: "cashfree"; payment_session_id: string; order_id: string; env: "sandbox" | "production" }
  | { kind: "redirect"; url: string; order_id: string };

export interface CreateInput {
  orderId: string;
  amount: number; // rupees
  customer: { id: string; name: string; mobile: string; email: string };
  returnUrl: string; // where the gateway sends the payer back (pay-return)
  notifyUrl: string; // server-to-server callback (pay-webhook?pg=<id>)
  channel: "COUNTER" | "APP";
  /// Fee-group settlement: pay these parts into these sub-accounts (Razorpay
  /// linked account, Cashfree vendor, Paytm child MID, Easebuzz split label).
  /// The rest stays with the main account. Empty = no split.
  splits?: Split[];
}

export interface Split {
  fg_id: number;
  account: string;
  amount: number; // rupees
}

export interface CreateResult {
  checkout: Checkout;
  gwOrderId?: string; // the gateway's own order id, when it differs from ours
}

/// An order as the server holds it (public.online_order).
export interface OrderRef {
  orderId: string;
  gwOrderId?: string | null;
  amount: number; // rupees asked for
}

/// The gateway's verdict on an order. Only 'captured' and 'failed' are final.
export interface StatusResult {
  /// not_found: the gateway has no payment at all for this order (nobody
  /// paid, or the order never reached it). Only closed after an hour.
  state: "captured" | "failed" | "pending" | "not_found";
  reference?: string; // the gateway's transaction id
  amount?: number; // rupees actually taken
  raw?: unknown;
}

export interface Adapter {
  create(c: Creds, input: CreateInput): Promise<CreateResult>;
  status(c: Creds, o: OrderRef): Promise<StatusResult>;
  /// Pull our order id out of a callback. The callback is only a nudge: the
  /// verdict always comes from status(), so a forged callback achieves
  /// nothing but a status check.
  webhookOrderId(raw: string, headers: Headers, c: Creds): Promise<string | null>;
  /// Do the saved credentials work? (Setup > Payment Gateways > Test.)
  test(c: Creds): Promise<{ ok: boolean; message: string }>;
}

export class GatewayError extends Error {}

export function need(obj: Record<string, string>, key: string, label: string): string {
  const v = (obj?.[key] ?? "").toString().trim();
  if (!v) throw new GatewayError(`${label} is not set for this gateway. Enter it in Setup > Payment Gateways.`);
  return v;
}
