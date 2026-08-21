# Security Review — Admin App + Mobile App

**Date:** 2026-08-12
**Scope:** Admin Flutter app (this repo) + the shared Supabase backend (edge functions,
RPCs, RLS, grants). The mobile app is a separate repo but uses the **same backend**, so
every backend finding below applies to it equally.
**Method:** read-only review. No code or DB changed.

---

## Severity summary

| # | Severity | Finding | Affects |
|---|----------|---------|---------|
| 1 | 🔴 Critical | Public anon key has `GRANT ALL` on all tenant tables → full read/write/delete of every institution's data, bypassing the app | Both |
| 2 | 🔴 Critical | Fee payments can be forged — `complete_payment_grouped` trusts client `p_status`; direct `UPDATE feedemand` also possible | Both |
| 3 | 🟠 High | `public.admission` (cross-tenant PII) has an `"Allow all"` RLS policy | Both |
| 4 | 🟡 Medium | Paytm edge functions have no user auth beyond the anon JWT | Both |
| 5 | 🟡 Medium | `SECURITY DEFINER` RPCs trust client-supplied `p_ins_id` (no caller/institution check) | Both |
| 6 | 🟡 Medium (mobile) | Anon key is decompilable from the APK; no certificate pinning | Mobile |

---

## 1. 🔴 Anon key has full CRUD on all tenant data

**Root cause.** The app authenticates with a **custom** `institutionusers` login that does **not**
create a Supabase Auth session. All data access therefore runs as the **anon** role, and anon
has been granted everything:

- `recreate_institution_functions.sql:315` — `GRANT ALL ON ALL TABLES IN SCHEMA <schema> TO anon, authenticated` (per institution-year schema)
- `recreate_institution_functions.sql:1278` — `GRANT ALL ON ALL TABLES IN SCHEMA public TO anon`
- Institution schemas are exposed via PostgREST (`expose_all_schemas`)
- RLS is enabled on only 4 minor tables (notice, notification, tempfeedemand, institutionusers);
  `payment`, `feedemand`, `students`, `feetype`, `feegroup`, … have **no RLS**, so `GRANT ALL` fully governs.

**Impact.** Anyone who obtains the anon key — embedded in the desktop app **and** the mobile APK,
and visible in network traffic — can call the Supabase REST API directly and read/modify/delete
**any** institution's students, PII (Aadhaar, DOB, mobile, parents), fees, and payments, with no
login. The login screen is a UI gate only; there is no server-side authorization.

## 2. 🔴 Fee payments can be forged

- `recreate_institution_functions.sql:983` — `complete_payment_grouped(... p_status char DEFAULT 'C')`
  is `SECURITY DEFINER`, granted to anon, and **trusts the client-supplied `p_status`**. It does not
  verify with the payment gateway that money actually settled.
- Because of finding #1, a caller can also just `UPDATE <schema>.feedemand SET balancedue=0` directly.

**Impact.** A student (or anyone with the anon key) can mark fee demands **PAID without paying**.
The app verifies status via `get-paytm-payment` before completing, but that check is **client-side
only** — a direct API call skips it.

## 3. 🟠 Shared admission table is world-read/write

- `admission_public_module.sql:96-98` — `public.admission` RLS = `"Allow all" USING(true) WITH CHECK(true)`.
  This is the cross-tenant applicant-PII staging table. Any anon caller can read/alter every
  institution's admissions.

## 4. 🟡 Paytm edge functions have no user auth

- `create-paytm-order` / `get-paytm-payment` perform no `getUser`/authorization check; the anon key
  satisfies the default `verify_jwt`. Lower severity: creating an order pulls money *from* the payer
  (abuse = order spam / MID probing); `get-paytm-payment` is order-status info disclosure. **No secret
  is exposed** — merchant keys stay in edge env (good).

## 5. 🟡 RPCs trust client-supplied `p_ins_id`

- `complete_payment_grouped`, `process_master_import`, `allocate_admission_to_student`, etc. accept
  `p_ins_id` from the client with no check that the caller belongs to that institution → cross-tenant
  writes. Moot while everything is already open (finding #1), but must be fixed during remediation.

## 6. 📱 Mobile-specific

Same root cause, wider exposure: the anon key is decompilable from the APK; there is no certificate
pinning; the key grants full DB access. The mobile app introduces no new bug class — it makes the
existing one easier to exploit.

---

## ✅ Done right (positives)

- **Passwords:** bcrypt, verified **server-side** via RPC (`p_plain_password`); `usepassword` SELECT
  is **revoked from anon** (`supabase_service.dart:997`). Hashes are not exposed.
- **Paytm merchant keys** live only in edge env (`PAYTM_MERCHANTS`), never in the client.
- **No `service_role` key** in the client. The Razorpay/Paytm keys present in the client are
  *publishable* (non-secret) keys — acceptable to ship.
- Online payment completion **does** verify the gateway status before finalizing (client-side) —
  good practice; needs to move server-side (finding #2).

---

## Remediation (staged — architectural)

The core issue is that the anon key is treated as a trusted credential with full DB privileges.

**Option A — Proper (Supabase Auth + RLS).** Adopt Supabase Auth (per-user JWT), `REVOKE ALL` from
anon on data tables, and write RLS policies scoped by institution + role using JWT claims.

**Option B — Pragmatic (keeps the custom login).** `REVOKE` direct table CRUD from anon; route all
writes through `SECURITY DEFINER` RPCs that require a session token issued at login and resolve
institution/role **server-side** (ignore client `p_ins_id`).

**Quick wins (a migration; needs per-screen testing because some screens write tables directly):**
1. `REVOKE INSERT, UPDATE, DELETE` from anon on `payment`, `feedemand`, `students`, `public.admission`
   — stops direct data tampering immediately; writes must then go through RPCs.
2. Make `complete_payment_grouped` verify the gateway transaction server-side before accepting
   `p_status='C'` for online payments.
3. Replace the `"Allow all"` admission policy with a real one.

⚠️ The quick wins will break any screen that writes those tables directly (not via an RPC). Map every
direct-write call site first, then apply and test per screen.

---

## Blast-radius map (2026-08-12) — why the "quick wins" are not quick

Direct writes to the sensitive tables (found in the client), i.e. what a `REVOKE` breaks:

| Table | Screens / flows writing it directly |
|---|---|
| `payment` | Fee Collection (Razorpay, Paytm, fine, status→F), Bank Reconciliation, Fee Refund |
| `feedemand` | Fee Concession, Student Fee Definition, Bank Reconciliation, Fee Master, Fee Refund, Section Transfer, Fee Collection (fine) |
| `students`/`parents`/`parentdetail` | Add/Edit Student, Student photo (`students_screen`), parent edit, `supabase_service` add/edit |
| `public.admission` | Fast Admission (`fast_admission_screen:178` `.from('admission').insert`), Admission form |

≈10–12 distinct write paths hit these tables directly (not through RPCs).

**Reassessment:**
- **REVOKE writes from anon** breaks all of the above. Each path first needs a `SECURITY DEFINER` RPC
  to write through — so it is a mini-project per path, not one migration.
- **RLS policies are ineffective** in the current model: every request runs as the **anon** role (the
  custom login issues no per-user JWT), so a policy cannot distinguish users/institutions. RLS does
  nothing until a real identity layer exists.

**Therefore there is no genuine quick fix.** Both real options require the identity layer first
(Option A: Supabase Auth + RLS; Option B: session-token-gated RPC layer), each a multi-week effort
touching every write path. Recommend treating this as a planned security workstream, not a patch.
