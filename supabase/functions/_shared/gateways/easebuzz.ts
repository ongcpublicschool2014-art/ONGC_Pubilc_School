// Easebuzz -- Initiate Payment (hosted page) + Transaction retrieve.
//
// VERIFY IN THE EASEBUZZ SANDBOX BEFORE GOING LIVE: Easebuzz's official docs
// could not be read when this was written (2026-11-03), so the URLs and hash
// sequences below follow Easebuzz's published integration kits:
//   initiate POST {pay}/payment/initiateLink (form)       -> { status: 1, data: <access key> }
//            payment page: {pay}/pay/<access key>
//            hash = sha512(key|txnid|amount|productinfo|firstname|email|udf1..udf10|salt)
//   status   POST {dash}/transaction/v1/retrieve (form: txnid, key, amount, email, phone, hash)
//            hash = sha512(key|txnid|amount|email|phone|salt)
//            -> { status: true, msg: { status: "success" | "failure" | ..., easepayid, amount } }

import { sha512Hex } from "./crypto.ts";
import { Adapter, Creds, GatewayError, need } from "./types.ts";

function urls(c: Creds) {
  return c.mode === "LIVE"
    ? { pay: "https://pay.easebuzz.in", dash: "https://dashboard.easebuzz.in" }
    : { pay: "https://testpay.easebuzz.in", dash: "https://testdashboard.easebuzz.in" };
}

// The retrieve call needs the same amount / email / phone the order was made
// with, so they are fixed from the order id + amount the server already holds.
function contact(orderId: string) {
  return { email: `fees+${orderId.toLowerCase()}@school.invalid`, phone: "9999999999" };
}

export const easebuzz: Adapter = {
  async create(c, input) {
    const key = need(c.config, "merchant_key", "Easebuzz Merchant Key");
    const salt = need(c.secret, "salt", "Easebuzz Salt");
    const amount = input.amount.toFixed(2);
    const firstname = (input.customer.name || "Student").replace(/[^A-Za-z ]/g, "").trim().slice(0, 40) || "Student";
    const productinfo = "School Fees";
    const { email, phone } = contact(input.orderId);
    const hash = await sha512Hex(
      [key, input.orderId, amount, productinfo, firstname, email, "", "", "", "", "", "", "", "", "", "", salt].join("|"),
    );
    const form = new URLSearchParams({
      key, txnid: input.orderId, amount, productinfo, firstname, phone, email,
      surl: input.returnUrl, furl: input.returnUrl, hash,
    });
    // Easebuzz split: {"label": amount} per fee group (labels set up by Easebuzz).
    if (input.splits?.length) {
      form.set("split_payments", JSON.stringify(Object.fromEntries(input.splits.map((s) => [s.account, Number(s.amount.toFixed(2))]))));
    }
    const r = await fetch(`${urls(c).pay}/payment/initiateLink`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const d = await r.json().catch(() => ({}));
    if (Number(d?.status) !== 1 || !d?.data) throw new GatewayError(`Easebuzz refused the order: ${d?.error_desc ?? d?.data ?? r.status}`);
    return { checkout: { kind: "redirect", url: `${urls(c).pay}/pay/${d.data}`, order_id: input.orderId } };
  },

  async status(c, o) {
    return await easebuzzStatus(c, o.orderId, o.amount);
  },

  async webhookOrderId(raw) {
    const p = new URLSearchParams(raw);
    let id = p.get("txnid");
    if (!id) {
      try {
        id = JSON.parse(raw)?.txnid ?? null;
      } catch { /* ignore */ }
    }
    return id;
  },

  async test(c) {
    const key = need(c.config, "merchant_key", "Easebuzz Merchant Key");
    const salt = need(c.secret, "salt", "Easebuzz Salt");
    const txnid = `TEST${Date.now()}`;
    const { email, phone } = contact(txnid);
    const amount = "1.00";
    const hash = await sha512Hex([key, txnid, amount, email, phone, salt].join("|"));
    const r = await fetch(`${urls(c).dash}/transaction/v1/retrieve`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ txnid, key, amount, email, phone, hash }).toString(),
    });
    const d = await r.json().catch(() => ({}));
    const msg = typeof d?.msg === "string" ? d.msg : JSON.stringify(d?.msg ?? d);
    if (/hash|key|auth/i.test(msg) && !/not found|no transaction/i.test(msg)) return { ok: false, message: `Easebuzz: ${msg}` };
    return { ok: true, message: `Easebuzz answered (${msg}). Confirm with a sandbox payment.` };
  },
};

/// Easebuzz's retrieve call signs the amount, so the status check needs it.
export async function easebuzzStatus(c: Creds, orderId: string, amountRupees: number) {
  const key = need(c.config, "merchant_key", "Easebuzz Merchant Key");
  const salt = need(c.secret, "salt", "Easebuzz Salt");
  const amount = amountRupees.toFixed(2);
  const { email, phone } = contact(orderId);
  const hash = await sha512Hex([key, orderId, amount, email, phone, salt].join("|"));
  const r = await fetch(`${urls(c).dash}/transaction/v1/retrieve`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ txnid: orderId, key, amount, email, phone, hash }).toString(),
  });
  const d = await r.json().catch(() => ({}));
  const m = Array.isArray(d?.msg) ? d.msg[0] : d?.msg;
  const s = String(m?.status ?? "").toLowerCase();
  if (d?.status && s === "success") {
    return { state: "captured" as const, reference: String(m.easepayid ?? orderId), amount: Number(m.amount), raw: d };
  }
  if (["failure", "usercancelled", "dropped", "bounced"].includes(s)) return { state: "failed" as const, raw: d };
  return { state: "pending" as const, raw: d };
}
