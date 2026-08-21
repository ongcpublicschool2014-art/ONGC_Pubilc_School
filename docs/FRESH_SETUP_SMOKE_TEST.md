# Fresh-Setup Smoke Test

Run this on a **scratch Supabase project** (not production) to prove `C:\pg_backups\complete_setup.sql`
produces a working schema before you wipe and rebuild the real DB.

**Rule:** if any ❌ step fails, STOP — fix the script (or tell me the error) before touching production.

---

## Phase 0 — Prep
- [ ] Create a throwaway Supabase project (or an empty DB you can drop).
- [ ] Have the admin app point at it (temporarily swap the URL/anon key in `lib/config/supabase_config.dart`, or use a second build). **Remember to switch back.**
- [ ] `pg_dump` the REAL production DB first (into `C:\pg_backups\`) — your rollback.

## Phase 1 — Run the script
- [ ] Paste **all** of `complete_setup.sql` into the SQL editor and run.
- [ ] **PASS = "Success. No rows returned" with NO red error.** (An error here is the whole point of testing — note the line/message.)
- [ ] Verify the core public objects exist:
```sql
SELECT tablename FROM pg_tables WHERE schemaname='public'
  AND tablename IN ('institution','institutionyear','admission','institution_settings','license_keys');
-- expect all 5
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND proname IN
 ('create_institution_schema','process_student_import','cleanup_student_import',
  'allocate_admission_to_student','get_super_admin_dashboard','get_fee_demands');
-- expect all 6
```

## Phase 2 — Create an institution + academic year (generates the per-year schema)
- [ ] In the app (super-admin): **Register Institution** → create one (e.g. shortname `test`), then create an academic **year** (e.g. 2026-2027). This calls `create_institution_schema` and builds the schema.
- [ ] Verify the schema + key tables were generated:
```sql
SELECT nspname FROM pg_namespace WHERE nspname LIKE 'test%';        -- expect e.g. test20262027
SELECT table_name FROM information_schema.tables
WHERE table_schema='test20262027'
  AND table_name IN ('students','parents','parentdetail','feedemand','tempfeedemand','payment','classfeedemand','sequence');
-- expect all 8
```
- [ ] Confirm the auto-demand trigger is **absent** (student import must not create demands):
```sql
SELECT tgname FROM pg_trigger WHERE tgname='trg_gen_feedemand_on_student';  -- expect 0 rows
```

## Phase 3 — Students
- [ ] Import a **small** student file (10–20 rows, include 1–2 with a blank/shared email and a few with the same parent mobile).
- [ ] **PASS = all imported, 0 skipped.**
- [ ] Verify students + parents + parentdetail + admission mirror all landed and link cleanly:
```sql
SELECT
 (SELECT count(*) FROM test20262027.students     WHERE activestatus=1) AS students,
 (SELECT count(*) FROM test20262027.parentdetail WHERE activestatus=1) AS parentdetail,
 (SELECT count(*) FROM public.admission WHERE ins_id=(SELECT ins_id FROM public.institution WHERE inshortname='test') AND admsource='IMPORT') AS admission_mirror;
-- students == parentdetail == admission_mirror (all equal the import count)
-- Every demand-less student should still be joinable by stu_id:
SELECT count(*) AS orphan_admission
FROM public.admission a
LEFT JOIN test20262027.students s ON s.stuadmno=a.admno
WHERE a.admsource='IMPORT' AND s.stu_id IS NULL;   -- expect 0
```

## Phase 4 — Fee demands (regular + arrear)
- [ ] Import a **small** fee-demand file with **both** a REGULAR row and an ARREAR row (Type column) for the same student, then **approve** it (Fee Demand Approval).
- [ ] **PASS = no "duplicate key" error; both rows land in `feedemand`.**
- [ ] Verify arrear fields + recon balance are set, and re-approving does NOT duplicate:
```sql
SELECT demseqtype, arrearclass, yr_id, balancedue, reconbalancedue, paidstatus
FROM test20262027.feedemand ORDER BY dem_id;
-- ARREAR row: demseqtype='ARREAR', arrearclass set, yr_id may be NULL, reconbalancedue = balancedue
-- Re-import + re-approve the SAME file → count must NOT increase (demno dedup):
SELECT count(*) FROM test20262027.feedemand;
```

## Phase 5 — Fee collection
- [ ] Collect a payment for one student (a **regular** demand). Save/complete it.
- [ ] **PASS = receipt generated; balance drops.**
```sql
SELECT paystatus, transtotalamount FROM test20262027.payment ORDER BY pay_id DESC LIMIT 1;  -- 'C'
SELECT dem_id, feeamount, paidamount, balancedue, reconbalancedue, paidstatus
FROM test20262027.feedemand WHERE paidstatus IN ('P','U') ORDER BY dem_id;
-- paid demand: balancedue reduced, paidamount up, paidstatus 'P' if cleared
```
- [ ] (Arrear-first) With an unpaid arrear on the student, the collection screen opens on **Arrear** and Regular is locked (if the `institution_settings` arrear-first toggle is ON).

## Phase 6 — Dashboards & reports
- [ ] **Institution dashboard**: Total Demand / Collection / Pending are non-zero and tally (Demand = Collection + Pending).
- [ ] **Super-admin dashboard**: the test institution shows the same Demand/Collection/Pending (not ₹0).
```sql
SELECT elem->>'total_demand', elem->>'total_collected', elem->>'total_pending'
FROM json_array_elements(get_super_admin_dashboard(NULL)) elem;  -- non-zero, tallies
```
- [ ] **Reports → Daily Collection** loads without error and shows the payment.

## Phase 7 — Parent mobile app (optional but recommended)
- [ ] Log in as the test student's parent → **Pending Fees** shows fees; the **Arrear Fees** section appears with the original class; regular fees locked until arrear cleared. (No ₹0/blank — confirms the `yr_id`-null parse fix.)

---

## Go / No-Go
- ✅ **GO to production** only if **every** Phase 1–6 step passed (Phase 7 optional).
- ❌ Any failure → capture the exact SQL error or app message and fix the script first.

## After a successful production rebuild — do imports in THIS order (prevents the stu_id orphaning we hit):
1. `complete_setup.sql`
2. Institutions + years (super-admin) → generates schemas
3. **Students — import once, never clear + re-import**
4. Fee demands (REGULAR/ARREAR) → approve
5. Set `Setup → Utilities` (needs `institution_settings`, which the script creates)
6. **Seed Paytm MID routing** — run `migrations/seed_paytm_configuration.sql`. The
   rebuild recreates `paytm_configuration` empty; without these rows every unit's
   online payments fall back to the DEFAULT MID and settle into the parent account
   instead of each unit's own bank. Confirm with:
   `SELECT institution_id, merchant_id, is_active FROM public.paytm_configuration ORDER BY 1;`
   (expect ins 1→Krishn36335928406501, 2→…496, 3→…198, 4→…773, all active).
   NOTE: the Paytm secret KEYS live in the edge function's `PAYTM_MERCHANTS` env
   (not the DB), so they survive a DB wipe — only these routing rows are lost.
