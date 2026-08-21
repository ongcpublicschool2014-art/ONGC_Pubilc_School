# Paytm Integration — Mobile App Handoff

This describes how the **desktop app** (Flutter Windows) does Paytm payments, so the
**mobile app** can replicate it against the **same Supabase backend**. The server
side is already built and live — **do not change it**. The mobile app only replaces
the *checkout UI*.

---

## 0. Principles (do not violate)

1. **The merchant secret key NEVER lives in the app.** All Paytm request signing
   (checksum) happens in Supabase **edge functions**. The mobile app only calls
   those functions and gets back an `orderId` + `txnToken`.
2. **Per-unit settlement:** each institution collects under its **own Paytm MID**,
   so money settles to that unit's own bank account. The MID is resolved from the
   DB by `ins_id`; the matching key is held only in the edge secret `PAYTM_MERCHANTS`.
3. **Server is the source of truth for status.** Never trust the SDK/UI callback
   alone — always confirm with the `get-paytm-payment` edge function.

---

## 1. What the mobile app REUSES unchanged

| Piece | Where | Reuse |
|---|---|---|
| `create-paytm-order` edge function | Supabase | Call it to start a payment |
| `get-paytm-payment` edge function | Supabase | Call it to verify status |
| `public.paytm_configuration` table | Supabase DB | Read MID per institution |
| Payment row + completion RPC | `<schema>.payment` / `complete_payment_grouped` | Same as desktop |

**No edge-function or DB changes are needed for mobile.**

---

## 2. Recommended mobile checkout: Paytm All-in-One SDK (native)

Desktop uses the **JS Checkout in a WebView**. On mobile, use the **Paytm All-in-One
SDK** — it opens UPI apps / cards / net-banking natively and is the supported mobile
flow. For Flutter mobile, the plugin is **`paytm_allinonesdk`** (Android + iOS).

The SDK needs exactly what `create-paytm-order` already returns: `mid`, `orderId`,
`txnToken`, `amount`. You do **not** compute any checksum on the device.

### Flutter example
```dart
import 'package:paytm_allinonesdk/paytm_allinonesdk.dart';

// 1) You already called create-paytm-order and got: order (orderId, txnToken, mid, amount)
final response = await AllInOneSdk.startTransaction(
  order.mid,               // the institution's MID (per-unit)
  order.orderId,
  order.amount,            // "1.00"
  order.txnToken,
  // callbackUrl for the new host:
  'https://secure.paytmpayments.com/theia/paytmCallback?ORDER_ID=${order.orderId}',
  false,                   // isStaging = false  => PRODUCTION
  true,                    // restrictAppInvoke (optional)
);
// response is a Map; but treat it as advisory only — VERIFY server-side next.
```

> **Do not decide success from `response` alone.** After the SDK returns (success,
> failure, or cancel), call `get-paytm-payment` and use *that* as the outcome.

### Alternative (fast path): reuse the WebView JS Checkout
If you don't want the native SDK yet, you can embed the **same JS Checkout HTML** the
desktop builds (`PaytmService.buildCheckoutHtml`) in a Flutter `webview_flutter`
widget. It works on mobile too. The native SDK gives a better UPI experience, but the
WebView is a valid interim.

---

## 3. Edge function contracts

Base URL: `https://ohbjbiwrjykdugbrimxe.supabase.co/functions/v1`
Auth headers on every call:
```
Authorization: Bearer <SUPABASE_ANON_KEY>
apikey: <SUPABASE_ANON_KEY>
Content-Type: application/json
```
(`SUPABASE_ANON_KEY` is the public anon key — safe in the app, same one the desktop uses.)

### 3a. `POST /create-paytm-order`  — start a payment
Request:
```json
{
  "amount": 1.00,          // rupees
  "pay_id": 12345,         // your payment row id (status 'I')
  "cust_id": "STU-987",    // optional
  "mid": "Krishn36335928406501"   // the institution's MID (per-unit). Omit -> default parent MID
}
```
Success response:
```json
{
  "order_id": "PAY-12345",
  "txn_token": "<long token>",
  "mid": "Krishn36335928406501",
  "amount": "1.00",
  "result_info": { "resultStatus": "S", "resultCode": "0000", "resultMsg": "Success" }
}
```
Error response (HTTP 4xx/5xx): `{ "error": "...", "result_info": {...}, "raw": {...} }`

### 3b. `POST /get-paytm-payment`  — verify status (source of truth)
Request:
```json
{ "order_id": "PAY-12345", "mid": "Krishn36335928406501" }   // mid MUST match the order's mid
```
Response:
```json
{ "status": "captured", "payment_id": "<paytm txnId>", "result_status": "TXN_SUCCESS" }
```
`status` is one of: **`captured`** (success), **`failed`**, **`pending`**.

---

## 4. Resolve the institution's MID (per-unit settlement)

Before creating the order, look up the paying institution's MID from the DB:

```
GET /rest/v1/paytm_configuration?select=merchant_id&institution_id=eq.<insId>&is_active=eq.true
Headers: apikey + Authorization = <SUPABASE_ANON_KEY>
```
Take `merchant_id` from the single row → that's the `mid` you pass to
`create-paytm-order`. If there's no row, omit `mid` (falls back to the default parent
MID). Current mapping:

| ins_id | Institution | MID |
|---|---|---|
| 1 | College (KCET) | `Krishn36335928406501` |
| 2 | Polytechnic | `Krishn15569334364496` |
| 3 | Arts & Science | `Krishn02645517368198` |
| 4 | Hostel | `Krishn33556941260773` |

(Add more rows as institutions are added — same table.)

---

## 5. Full payment sequence (mobile)

```
1. User picks demands to pay for a student → compute net amount.
2. Resolve MID:   GET paytm_configuration by ins_id  -> mid
3. Create payment row (status 'I') in <schema>.payment  -> pay_id
      (REST insert with Content-Profile: <schema>; store payitems JSON, recon_status 'P')
4. Create order:  POST create-paytm-order {amount, pay_id, cust_id, mid}
                  -> {order_id, txn_token, mid, amount}
5. Save order_id: PATCH payment.payorderid = order_id  (optional; edge fn also does it)
6. Launch checkout: Paytm All-in-One SDK (mid, order_id, amount, txn_token, callbackUrl, isStaging=false)
7. When the SDK returns (any result): POST get-paytm-payment {order_id, mid}
      status == 'captured'  -> success
      status == 'failed'    -> failed
      status == 'pending'   -> poll get-paytm-payment a few times (2–3s apart)
8. On success: complete the payment the SAME way desktop does
      (mark demands paid + create receipt; desktop uses the complete_payment_grouped RPC).
      On failure: mark the payment row 'F'.
```

Idempotency / recovery: if the app dies after step 6, you can always re-run step 7
with the stored `order_id` — Paytm's status API is authoritative and repeatable.

---

## 6. Config values (non-secret — safe to ship)

| Name | Value |
|---|---|
| Supabase URL | `https://ohbjbiwrjykdugbrimxe.supabase.co` |
| Supabase anon key | (same public anon key the desktop app uses) |
| Paytm host (production) | `https://secure.paytmpayments.com` |
| Paytm websiteName | `DEFAULT` |
| Staging host (if ever needed) | `https://securestage.paytmpayments.com`, website `WEBSTAGING` |

**Secrets that must stay server-side (never in the app):** the four merchant keys
(in the edge secret `PAYTM_MERCHANTS`) and the parent `PAYTM_MERCHANT_KEY`.

---

## 7. Testing

- Validate a credential without spending money: the repo has `paytm_check.js` —
  `node paytm_check.js <MID> <KEY> DEFAULT` → expect `resultCode 0000`.
- End-to-end: pay **₹1** for a real student under each institution, then confirm in
  the Paytm dashboard that it settled to that unit's account.
- Server-side pre-flight (no app): `POST create-paytm-order {amount:1, pay_id:999999,
  mid:"<MID>"}` should return a `txn_token`.

---

## 8. Gotchas (learned the hard way)

1. **Host:** production is `secure.paytmpayments.com`, NOT `securegw.*` (securegw
   returns 404). Staging is `securestage.paytmpayments.com`.
2. **Per-MID key:** each unit MID is signed with its OWN key (server-side, from
   `PAYTM_MERCHANTS`). Do not sign a unit MID with the parent key — Paytm returns
   `2005 Checksum invalid`.
3. **UPI is enabled per-MID.** If UPI/QR doesn't appear for a unit, Paytm must enable
   those instruments on that specific MID (not just the parent).
4. **Amount format:** always 2 decimals as a string to Paytm (`"1.00"`).
5. **Status:** trust `get-paytm-payment`, not the SDK/UI callback.
