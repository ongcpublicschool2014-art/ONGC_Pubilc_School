# Paytm workflow — configuration-driven, nothing about a merchant in the code

**Who this is for:** a developer or integrator wiring Paytm up for an
institution. Not an office document.

**What it covers:** how a payment actually flows, where every merchant value
is meant to live, how to bring up a new institution without touching Dart, and
— honestly — what is still hardcoded today and how to remove it.

Companion docs: `paytm_integration.md` (the original JS-Checkout write-up) and
`PAYTM_INTEGRATION_GUIDE.md`.

---

## 1. The rule

**One Paytm order settles to exactly one merchant.** Everything below follows
from that. The merchant has to be decided *before* the order is created,
because the merchant the order is signed with is what decides which bank
account the money lands in — and no amount of correcting the receipt
afterwards moves the money.

**The merchant key never reaches the client.** All signing happens in Supabase
edge functions. The desktop app knows a merchant *id* (public), never a key.

---

## 2. Where each value lives

| Value | Lives in | Read by |
|---|---|---|
| Merchant **key** (secret) | Edge function env: `PAYTM_MERCHANT_KEY`, or `PAYTM_MERCHANTS` | `_shared/paytm_merchant.ts` only |
| Merchant **id** per bank account | `<schema>.bank.paytm_mid` | `resolvePaytmRouting` |
| Merchant **id** per institution (fallback) | `public.paytm_configuration (institution_id, merchant_id, is_active)` | `getPaytmMidForInstitution` |
| Which account a fee group banks into | `<schema>.feegroup.ban_id` → `bank` | `resolveRoutingBanId`, and the save RPCs |
| Receipt series per fee group | `<schema>.sequence` where `fg_id` is set | `save_misc_collection`, `save_advance_collection` |
| Gateway host / website | Edge env: `PAYTM_HOST`, `PAYTM_WEBSITE` | `resolveMerchant` |
| Staging vs production (client) | `%APPDATA%\EduCore360\config.json` → `"paytmStaging"` | `SupabaseConfig.load()` → `PaytmConfig.isProduction` |

> **No `config.json` means LIVE.** Its absence is not "unconfigured", it is
> production. A TEST database with `paytmStaging: false` takes **real money**.

---

## 3. How the merchant is resolved

Two resolutions happen, and they must agree.

### Client side — *which* merchant (`SupabaseService`)

```
resolveRoutingBanId(insId, feeTypes / advType)   ->  ban_id   (via feegroup)
resolvePaytmRouting(insId, banId)                ->  mid
```

`resolvePaytmRouting` in order:

1. `bank.paytm_mid` for that `ban_id` → `source: 'bank:<id>'`
2. `public.paytm_configuration.merchant_id` for the institution → `source: 'institution'`
3. **Refuses.** It returns an error, not the parent merchant. A silent fall
   back to the college merchant is how hostel money ends up in the college
   account with nothing on the receipt to show it.

An unreadable *bank row* falls through to step 2 — that is a read failure, not
a routing decision. A missing *merchant* stops the collection.

### Server side — *which key* (`_shared/paytm_merchant.ts`)

Given the mid the client asked for:

| Condition | Key used |
|---|---|
| mid is in `PAYTM_MERCHANTS` | that merchant's own key |
| mid equals `PAYTM_MID` | `PAYTM_MERCHANT_KEY` |
| mid given and `PAYTM_SUBMERCHANT_MODE=true` | the **parent** key (sub-merchant signing) |
| no mid | `PAYTM_MID` + `PAYTM_MERCHANT_KEY` |

`PAYTM_MERCHANTS` is a JSON object, `{"<mid>": "<key>", ...}`. It is the only
thing that needs editing to add a genuinely separate merchant.

---

## 4. The collection workflow

Same shape for all three collection types. Differences are called out.

```
1  narrow to ONE fee group        one order = one merchant
2  resolveRoutingBanId()          fee types (or advType) -> ban_id
3  resolvePaytmRouting()          ban_id -> mid, or REFUSE
4  record the intent  <-- BEFORE the gateway, always
5  create-paytm-order             edge fn signs with that mid's key -> txnToken
6  checkout WebView               checkoutJsUrlFor(mid), allowedHosts gate
7  get-paytm-payment              /v3/order/status, asked of THAT mid
8  decide: captured / failed / undecided
9  recovery sweeps catch anything step 8 could not decide
```

### Step 4 — the intent, and why it is first

| Flow | Intent record |
|---|---|
| Fee collection | a `payment` row with `paystatus = 'I'`; `payorderid` stamped after step 5 |
| Misc | `record_pending_collection(kind 'M', …, p_ban_id)` |
| Advance | `record_pending_collection(kind 'A', …, p_ban_id)` |

If this machine dies between step 5 and step 8, the intent is the only thing
that lets a captured payment become a receipt later. `p_ban_id` is on it
because **the sweep must re-ask the merchant the order was signed with** — ask
the wrong one and Paytm answers "no such order", which reads as a failure.

### Step 8 — three outcomes, not two

| Paytm says | Action |
|---|---|
| `TXN_SUCCESS` | complete, raise the receipt |
| `TXN_FAILURE` | mark failed — **only an explicit failure may do this** |
| `PENDING` / no record / call threw | **undecided** — leave the row `'I'` and let the sweep decide later |

An unresolved row is recoverable; a wrongly failed one is not. Observed codes
on this merchant: `810 ORDER IS CLOSE` (abandoned), `227` (declined / wrong
UPI PIN), `196` (over bank limit), `402` (processing — genuinely in flight),
`334 Invalid Order Id` (never created).

### Step 9 — recovery, which does not depend on the webhook

| Mechanism | Scope | Cadence |
|---|---|---|
| `_sweepOrphanedPayments` | `payment` rows `'I'` **and `'F'`**, 15 min – 7 days old, `paynumber IS NULL` | on Fee Collection open |
| `PendingCollectionSweep` | `open_pending_collections` — intents older than 2 min | every 5 min, from login |
| `paytm-webhook` | callback, but **re-asks** `/v3/order/status` rather than trusting the callback | on Paytm's call |

`'F'` is swept too: a payment captured near midnight after the old 15-minute
sweep had already written it off is how ₹2,000 and ₹1,600 went missing on
30-09-2026. Re-asking costs nothing and can only turn a wrongly-failed payment
back into a receipt — rows that already have a `paynumber` are excluded.

Recovered receipts are back-dated to when the money was actually taken, by
`backdate_recovered_payment` / `backdate_recovered_collection`. Both move the
date **backwards only**.

### Receipt numbering

The number comes from the **fee group's own** sequence (`sequence.fg_id`), not
a shared one. A group with no sequence is **refused**, not numbered out of
another group's run — see `MISC_RECEIPT_SEQUENCE_BY_FEEGROUP.sql`.

---

## 5. Bringing up a new institution — no code change

1. **Bank Accounts** — create the account, set its `paytm_mid`.
2. **Fee Group** — point each group at its bank account (`ban_id`).
3. **Sequence Master** — a receipt series per fee group. *Without this,
   collections against that group are refused.*
4. **Edge function env** — add `"<mid>": "<key>"` to `PAYTM_MERCHANTS`
   (or set `PAYTM_SUBMERCHANT_MODE=true` if Paytm issued a sub-mid under your
   parent key). Set `PAYTM_HOST` and `PAYTM_WEBSITE` for the environment.
5. **`public.paytm_configuration`** — one row per institution as the fallback
   for anything not routed by bank.
6. **Webhook URL** — register the `paytm-webhook` function URL with Paytm.

Verify before taking money:

```sql
-- every group: an account, a merchant, and a series
SELECT fg.fg_id, fg.fgdesc, fg.ban_id,
       CASE WHEN COALESCE(b.paytm_mid,'') = '' THEN 'NO MERCHANT' ELSE 'ok' END AS merchant,
       CASE WHEN s.seq_id IS NULL THEN 'NO SEQUENCE' ELSE s.seqprefix END      AS series
  FROM kcet20262027.feegroup fg
  LEFT JOIN kcet20262027.bank b ON b.ban_id = fg.ban_id
  LEFT JOIN kcet20262027.sequence s ON s.fg_id = fg.fg_id AND s.activestatus = 1
 WHERE fg.activestatus = 1
 ORDER BY fg.fg_id;
```

`tools/feegroup_receipts.sql` query 4 answers the same question with usage
figures attached.

---

## 6. What is still hardcoded (and should not be)

Everything above is configuration-driven **except** these, all in
`lib/config/paytm_config.dart`:

| Member | Line | Problem |
|---|---|---|
| `stagingMid` | 69 | an institution's merchant id compiled into the binary |
| `productionMid` | 83 | same |
| `stagingWebsiteName` / `productionWebsiteName` | 95 / 100 | per-merchant, should come from the edge env like the server's `PAYTM_WEBSITE` |
| `host` / `allowedHosts` / `checkoutJsUrl` | 112–126 | gateway-wide, defensible as constants |
| `splitSettlement` | 38 | `const false`; a flag that cannot be flipped without a build |

**These are reachable, not dead.** `PaytmConfig.mid` is the last-resort
fallback at `paytm_service.dart:115` and the readiness check at `:287`. So an
institution with no `bank.paytm_mid` and no `paytm_configuration` row can
still create an order — against **whichever merchant was compiled in**.

To remove them:

1. Make `PaytmConfig.mid` return empty rather than a baked-in id, so the
   readiness check fails loudly instead of routing to someone else's merchant.
2. Delete the `?? PaytmConfig.mid` fallback at `paytm_service.dart:115`. The
   order already carries its mid; a null there is a bug worth surfacing.
3. Move `websiteName` server-side — `create-paytm-order` already reads
   `PAYTM_WEBSITE` via `resolveMerchant`, so the client copy is redundant.
4. Make `splitSettlement` a row in institution settings if it is ever needed.

Until (1) and (2) are done, **"no merchant configured" silently becomes "the
merchant in the build"**, which is the one failure this whole design exists to
prevent.

### Hygiene

`paytm_config.dart` carries credential-looking strings in its **comments**,
including what reads as a plaintext merchant key. Merchant *ids* are not
secret; a key in a committed comment is. Worth auditing and purging from
history separately.

---

## 7. Troubleshooting

| Symptom | Look at |
|---|---|
| "No Paytm merchant is set up for this institution" | `bank.paytm_mid`, then `public.paytm_configuration` |
| Checkout header names the wrong entity | `merchantName` passed to `showPaytmCheckout` — it is composed per screen from the resolved fee group |
| Receipt numbered from the wrong series | `sequence.fg_id` for that group; `MISC_RECEIPT_SEQUENCE_BY_FEEGROUP.sql` |
| Sweep reports "no such order" | the order was signed with a different mid — check `ban_id` on the intent |
| `token session expired` immediately | staging token against the production host or vice versa; `PaytmConfig.isProduction` vs `PAYTM_HOST` |
| Captured money with no receipt | `_sweepOrphanedPayments` log, then `webhook_record_refusal` rows |

Status checks are read-only and safe to run against a live merchant:

```
POST {SUPABASE_URL}/functions/v1/get-paytm-payment
{ "order_id": "<payorderid>", "mid": "<the mid it was signed with>" }
```
