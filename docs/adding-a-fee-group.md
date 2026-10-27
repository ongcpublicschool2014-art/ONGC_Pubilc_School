# Adding a second fee group (e.g. HOSTEL FEES)

Written for whoever administers EduCore360 — the steps, in order, with what
goes wrong if one is skipped.

As of 2026-10-01 live has **one** fee group (COLLEGE FEES), so none of this is
needed yet. It becomes needed the day a second group is created.

## The trap

Creating the fee group and its bank, and stopping there, is worse than not
starting. Online collections for the new group will settle into the **COLLEGE**
account, silently, with nothing in the app or on Paytm to show it happened —
because routing is off by default and the order is created under the
institution's single merchant.

So either do all of it, or none of it. Half of it looks like it works.

## The order

| # | Step | Where | Skip it and… |
|---|------|-------|--------------|
| 1 | Create the fee group | Fee Master | — |
| 2 | Create its bank, with that account's own `paytm_mid` | Setup → Bank Details | online cannot route |
| 3 | Map the group to the bank | Fee Master | routing resolves nothing |
| 4 | Create the group's receipt sequence (e.g. `HF26/`) | Setup → Sequence Master | receipts get `PAY<id>` fallback numbers instead of a series |
| 5 | Add that merchant's **key** to the `PAYTM_MERCHANTS` edge secret | Supabase → Edge Functions → Secrets | the server **rejects** the payment — loud and safe |
| 6 | Run `migrations/shared/LIVE_BANK_ROUTING_BUNDLE.sql` | live SQL editor | cash / misc / advance record the wrong account |
| 7 | Run `migrations/shared/SET_FEE_GROUP_SETTLEMENT.sql` | live SQL editor | **money settles to the college account, silently** |
| 8 | Take one small real payment into the new group and check Paytm | — | — |

Steps 5 and 7 are the ones that bite. **5 fails loudly**; the payment is
refused and nothing is mis-settled. **7 fails silently**, which is why it is
last: everything else should already be correct before routing is switched on.

## Checking readiness before step 7

`SET_FEE_GROUP_SETTLEMENT.sql` prints a readiness table — for each fee group it
shows `bank / merchant / sequence` and says `ready` or
`NOT READY - online payments here will not route`. It verifies steps 1–4 and 6.
**Step 5, the merchant key, it cannot see** — that lives in an edge secret.

## Turning it off

Step 7 is a single row in `institution_settings`, so it reverses in seconds:

```sql
INSERT INTO public.institution_settings
       (ins_id, setting_key, setting_value, updatedat, updatedby)
VALUES (1, 'fee_group_settlement', 'false', now(), 'ADMIN')
ON CONFLICT (ins_id, setting_key)
DO UPDATE SET setting_value = EXCLUDED.setting_value, updatedat = now();
```

Every counter picks that up within 60 seconds. This is deliberate: the first
time real money routes to a newly onboarded merchant is exactly when an instant
undo is wanted, and a rebuild-and-release is not one.

A test machine can opt in instead with `"feeGroupSettlement": true` in its
`%APPDATA%\EduCore360\config.json`, which is how the routing is trialled against
TEST before the setting is ever turned on for live.

## What it costs once it is on

**A student owing dues in two groups can no longer pay them in one online
transaction.** One Paytm order settles to exactly one merchant, so the counter
takes two payments and the screen says so:

> An online payment settles into ONE account, and these dues belong to different
> ones (COLLEGE FEES and HOSTEL FEES). Collect them one group at a time.

Cash, cheque and DD still take both groups together — they are banked by the
receipt, not by the gateway.

This limitation is inherent, not a bug. Fee-group routing was built, reverted
once for exactly this reason, and now sits behind a switch so it is turned on
knowingly.

## What it does not do

Existing receipts are not reclassified. Routing applies only to **new**
collections; payments already recorded with no account keep it. Re-stating
which account past money went into is a decision about the books, not a
migration — ask for it separately if it is wanted.
