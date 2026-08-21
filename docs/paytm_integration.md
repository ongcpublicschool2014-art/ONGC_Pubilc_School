# Paytm Payment Gateway (JS Checkout) integration

Onboarded via Indian Overseas Bank's **IOBPAY** program — the actual gateway is
**Paytm**. Credentials source: `Desktop/iob.txt`. The values currently wired in
are **STAGING/TEST** only.

This mirrors the existing Razorpay flow: the secret never touches the Flutter
client; all signing (checksum) happens in Supabase edge functions.

## Components

| Layer | File | Role |
|-------|------|------|
| Client config (non-secret) | `lib/config/paytm_config.dart` | MID, hosts, JS Checkout SDK URL |
| Client service | `lib/services/paytm_service.dart` | createOrder / verifyPayment / buildCheckoutHtml |
| Client UI | `lib/widgets/paytm_checkout_dialog.dart` | WebView checkout + status polling → `'C'`/`'F'`/`null` |
| Server (secret) | `supabase/functions/create-paytm-order/` | Initiate Transaction API + checksum |
| Server (secret) | `supabase/functions/get-paytm-payment/` | Transaction Status API |
| Server shared | `supabase/functions/_shared/paytm_checksum.ts` | AES-128-CBC + SHA256 signature |

## One-time setup

### 1. Set edge-function secrets (NEVER commit these)

```bash
supabase secrets set \
  PAYTM_MID=rJWzOr10770674724816 \
  PAYTM_MERCHANT_KEY=5G_bfQt2WBgneX7_ \
  PAYTM_WEBSITE=WEBSTAGING \
  PAYTM_HOST=https://securestage.paytmpayments.com
# optional: PAYTM_CALLBACK_URL=<your webhook URL>
```

`PAYTM_MID`/`PAYTM_MERCHANT_KEY` is the **default** merchant. It is used whenever
a payment doesn't resolve a specific MID.

> The thread contained **two** staging credential sets. The values above are
> the latest mail (Antony T, 22 Jun). The earlier set was
> MID `FLwTdx52530851901961`, key `_hAx6CdlKyHub%_j`. Confirm with TBS/Paytm
> which is active before testing.

### 2. Deploy the functions

```bash
supabase functions deploy create-paytm-order
supabase functions deploy get-paytm-payment
```

### 3. Client config

`lib/config/paytm_config.dart` already holds the staging MID. Keep
`isProduction = false` until go-live.

## Wiring into fee collection

The pieces are decoupled so the working Razorpay path is untouched. To trigger
a Paytm payment from a screen (e.g. after inserting the `payment` row with
`paystatus='I'`):

```dart
import '../../services/paytm_service.dart';
import '../../widgets/paytm_checkout_dialog.dart';

// payId: the inserted payment row id; totalNet: rupees.
final order = await PaytmService.createOrder(
  payId: payId,
  amount: totalNet,
  custId: 'STU-$stuId',
);

final result = await showPaytmCheckout(
  context,
  order: order,
  amount: totalNet,
  studentName: studentName,
  studentMobile: studentMobile,
  studentEmail: studentEmail,
); // 'C' | 'F' | null

final status = result == 'C' ? 'C' : 'F';
final payRef = await PaytmService.verifyPayment(order.orderId)
    .then((s) => s.paymentId ?? '');

await SupabaseService.client.rpc('complete_payment_grouped', params: {
  'p_pay_id': payId,
  'p_pay_method': 'online',
  'p_pay_reference': status == 'C' ? payRef : (result == 'F' ? 'FAILED:$payRef' : 'CANCELLED'),
  'p_items': items,
  'p_ins_id': insId,
  'p_status': status,
});
```

This reuses the same `complete_payment_grouped` RPC and `payment` row lifecycle
(`I` → `C`/`F`) as the Razorpay flow.

## Go-live checklist (from the onboarding mail)

1. Complete request + response of **3 successful transactions** across 3
   paymodes (UPI, Credit Card, Debit Card).
2. Capture a Paytm checkout cashier-page screenshot.
3. Share both with Paytm to receive **production** credentials.
4. Set production `PAYTM_MID` / `PAYTM_MERCHANT_KEY` / `PAYTM_WEBSITE` /
   `PAYTM_HOST=https://securegw.paytmpayments.com` as edge secrets.
5. Set `PaytmConfig.isProduction = true` and `productionMid`.

## Multi-MID routing (settling to the right bank account)

A Paytm MID settles to **one** bank account fixed at onboarding — the
transaction never carries a destination account. So to make different fee
groups settle to different accounts (KCET vs Hostel vs Arts&Science vs
Polytechnic), route each to its own MID. The routing reuses the existing
fee-group → bank mapping:

```
feegroup.ban_id  ->  bank.paytm_mid  ->  Paytm MID  ->  its settlement account
```

**How it's wired**
- `bank.paytm_mid` column (migration `add_paytm_mid_to_bank.sql`) — set per bank
  account in the **Bank Accounts** admin screen ("Paytm MID" field). Blank =
  use the default MID.
- `SupabaseService.getPaytmMidForFeeGroups(fgIds)` resolves the MID for the fee
  groups being paid (predominant bank wins for multi-group payments).
- `PaytmService.createOrder(..., mid: resolvedMid)` passes it through; the MID
  the order ran under is carried on `PaytmOrder.mid` and reused for status
  verification.
- Edge functions resolve the **secret key** for that MID via
  `_shared/paytm_merchant.ts`.

**Configuring multiple merchant keys** — set `PAYTM_MERCHANTS` as a JSON map of
MID → key (in addition to / instead of the single default):

```bash
supabase secrets set PAYTM_MERCHANTS='{
  "rJWzOr10770674724816":"5G_bfQt2WBgneX7_",
  "<kcetMid>":"<kcetKey>",
  "<hostelMid>":"<hostelKey>"
}'
```

Resolution: a requested MID found in `PAYTM_MERCHANTS` uses that key; a MID equal
to `PAYTM_MID` uses `PAYTM_MERCHANT_KEY`; no MID falls back to the default; an
unknown MID is rejected (so money is never mis-routed). All merchants currently
share `PAYTM_WEBSITE`/`PAYTM_HOST`.

> You currently hold only ONE staging MID. The plumbing above works with one MID
> today (everything falls back to the default) and scales to four once Paytm/IOB
> issue per-entity MIDs — just fill `bank.paytm_mid` and `PAYTM_MERCHANTS`.

## Notes

- **Always** confirm status via `get-paytm-payment` (server-side Transaction
  Status API). The browser callback is advisory only.
- Paytm merchant keys are 16 chars (AES-128). If a future key differs in length
  the checksum import will fail — keep keys at 16 chars.
