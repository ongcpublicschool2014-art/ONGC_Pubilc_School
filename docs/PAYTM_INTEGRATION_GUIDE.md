# Adding Paytm to another app

How to put the Paytm gateway into a new app, using EduCore360's implementation as
the reference. Written for a developer who has the other app's codebase open and
a Supabase project behind it.

Everything here is already working in this repo. Where a file is named, copy it
rather than rewriting it — most of the awkward parts exist because of a specific
failure, and the comments in those files say which.

---

## 1. The shape of it

**The merchant key never leaves the server.** Not in the app, not in a `.env`
shipped with a build, not in a config file on a counter PC. Anyone holding it can
sign transactions as you. So every call that needs it runs in an edge function,
and the app only ever receives a transaction token that is useless on its own.

Three functions do all the work:

| Function | Called by | Does |
|---|---|---|
| `create-paytm-order` | the app | Signs an order, returns a txn token |
| `get-paytm-payment` | the app | Asks Paytm the real status of an order |
| `paytm-webhook` | Paytm | Raises the receipt server-side when the app never came back |

Two shared modules sit beside them:

- `_shared/paytm_checksum.ts` — generate/verify, a port of Paytm's own routine
  (SHA-256 + AES-128-CBC with a fixed IV). Copy it as-is; it is easy to get
  subtly wrong and the failure mode is "Paytm rejects everything".
- `_shared/paytm_merchant.ts` — resolves which merchant a request belongs to.
  Needed even for one merchant, because it is also where "unknown MID" becomes a
  thrown error instead of a silent mis-route.

Copy all five files from `supabase/functions/` into the other project.

---

## 2. Secrets

Set on the other app's Supabase project, under Edge Functions → Secrets. Never in
the repo.

| Secret | Required | Notes |
|---|---|---|
| `PAYTM_MID` | yes | The merchant id |
| `PAYTM_MERCHANT_KEY` | yes | 16 characters. AES-128 needs exactly that |
| `PAYTM_HOST` | yes | `https://securegw-stage.paytm.in` while testing, the production host when live |
| `PAYTM_WEBSITE` | yes | `WEBSTAGING` for staging, `DEFAULT` for production |
| `PAYTM_MERCHANTS` | no | JSON map `{"<mid>":"<key>"}` when several entities settle to their own accounts |
| `PAYTM_SUBMERCHANT_MODE` | no | `true` only for aggregator sub-MIDs that share the parent key |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.

Deploy:

```bash
supabase functions deploy create-paytm-order --project-ref <ref>
supabase functions deploy get-paytm-payment  --project-ref <ref>
supabase functions deploy paytm-webhook --no-verify-jwt --project-ref <ref>
```

`--no-verify-jwt` is **required on the webhook only**. Paytm sends no Supabase
JWT, so with verification on, every callback is rejected at the gateway before
your code runs — and nothing in the dashboard looks wrong. The function simply
never fires, and you discover it when a payment goes missing.

Then point Paytm at it: the merchant-level webhook / S2S callback setting on the
Paytm dashboard, not a callback URL in the order body. A dashboard webhook is
independent of the order, so it covers web, desktop and mobile at once. On mobile
it is the only option that works at all, because the All-in-One SDK watches for
Paytm's own callback URL and will not accept yours.

---

## 3. What the database has to provide

The gateway code assumes four things exist. Build them before wiring the client.

**A row written before the gateway is contacted.** Status `I`, carrying the
amount and what the payment is for. This is the single most important part. If
money is taken and the app never comes back, this row is the only record of what
the payment was for — without it a late capture cannot be turned into anything.

**A place to store the order id on that row.** The webhook matches a callback to
a row by exact order id. Write it back as soon as `create-paytm-order` returns.

**A completion function that is idempotent.** Called twice, it completes once: it
re-reads the row and does nothing if the payment is already complete. Paytm
retries on any non-2xx, and the app and the webhook can both arrive at the same
moment.

**A refusals table.** When Paytm confirms money and the database will not accept
it — amount mismatch, no matching row, the charge already settled another way —
the refusal is correct but must not be silent. Each row is money received with no
receipt against it. In this repo that is `public.webhook_refusal`, surfaced by a
health check.

If several parties can complete the same payment (counter, a sweep, the webhook),
add an atomic claim so exactly one wins. See `claim_pending_collection` and
`pending_collection` here for the pattern.

### Order ids

```
PAY-<row_id>t<millis>     fee payment
MISC<ins>T<millis>        other collection
ADV<ins>T<millis>         advance
```

The timestamp suffix makes every attempt unique, so a retry never collides with
an order Paytm still has open. Keep a prefix per kind: it tells you which table
holds the record, which is the first thing you need when a payment is missing.
Match on the stored id exactly; never parse the id to find a row.

---

## 4. The client

### Mobile (Flutter, Android)

```yaml
dependencies:
  paytm_allinonesdk:
    path: third_party/paytm_allinonesdk
```

The published package is **vendored and patched** in this repo. Copy
`third_party/paytm_allinonesdk/` across rather than depending on the pub version
— the patches cover Flutter v2 embedding and the IOBPAY host, and without them it
does not build or does not reach the right gateway.

### Desktop and web

No SDK. Paytm's JS checkout runs in a WebView:
`webview_windows` on Windows, `webview_flutter` elsewhere. See
`lib/widgets/paytm_checkout_dialog.dart` for a working implementation, including
reading back the JS diagnostics the checkout page posts.

### The flow in code

```
1. write the intent row (status I)
2. call create-paytm-order  -> { orderId, txnToken, amount, mid }
3. store orderId on the row
4. launch the SDK or the WebView
5. ignore whatever it returns
6. call get-paytm-payment    -> captured | failed | pending
7. captured -> complete (idempotent)
   failed   -> mark F
   pending  -> leave it alone
```

Step 5 is not a joke. The checkout can resolve without a verdict, the phone can
lose signal, the user can close the page. Treat the SDK result as a hint that it
is time to ask the server, never as the outcome.

Poll step 6 fast at first — most UPI and card transactions settle in one to three
seconds — then back off.

---

## 5. Rules that came from real losses

Each of these fixed money that had actually gone missing. They look like extra
work until they don't.

**Never trust the callback body.** A callback is a nudge saying "look at this
order". The verdict always comes from a fresh signed status call. Then a forged
or replayed POST achieves nothing, a browser-mediated callback is as safe as a
server-to-server one, and no shared secret has to be distributed.

**Never write off an undecided payment.** `PENDING` and `NO_RECORD_FOUND` both
mean "no answer yet", not "failed". Only an explicit failure marks a row failed.

**Never delete an in-flight row.** The obvious cleanup — clear this user's old
`I` rows when they start a new payment — deletes a row Paytm still has open.
When the first checkout is then completed, the money arrives against a row that
no longer exists, invisible to every recovery path, findable only by reconciling
the settlement report by hand. Clear only rows with **no order id**: those
provably never reached the gateway.

**Verify the amount before completing.** If Paytm's figure differs from what the
attempt asked for, raise nothing and record a refusal. Answer 200, because a
retry cannot help and Paytm would retry forever.

**Mark server-raised receipts.** Stamp a prefix on the reference for anything the
webhook completed (`PAYTM-WH:` here). The apps write the bare transaction id, so
without a marker the two are indistinguishable later and you cannot tell how much
the webhook has saved — or whether it is working at all.

**Ask the merchant that created the order.** With more than one MID, asking the
wrong one returns "no such order", which reads as "not paid". A resolver that
marks payments failed on that basis will mark real payments failed. Store the
merchant (or the bank that implies it) on the row.

**An abandoned checkout never resolves.** If the user opens the Paytm page and
closes it without choosing a method, the order sits as Pending with a blank
payment source forever. No callback, and the status API answers `PENDING`
indefinitely. So any "wait for a verdict" logic needs a time bound, or you lock
the user out permanently. Fifteen minutes works.

---

## 6. Before going live

- [ ] Staging host and `WEBSTAGING` while testing; switch both together
- [ ] Webhook deployed with `--no-verify-jwt`, and Paytm's dashboard pointed at it
- [ ] Kill the app mid-payment and confirm the webhook still raises the receipt
- [ ] Call the completion twice with the same order and confirm one receipt
- [ ] Pay an amount that does not match and confirm a refusal, not a receipt
- [ ] Abandon a checkout and confirm nothing is marked failed and nothing locks
- [ ] Reconcile a day: Paytm's capture count and total against your receipts,
      scoped to one merchant. They should agree exactly

Settlement is a separate thing from capture, and the two will never tie. Paytm
pays out on T+1, batched, so a day's settlement figure has no relationship to
that day's collection. Reconcile captures against receipts; reconcile settlement
against the bank.
