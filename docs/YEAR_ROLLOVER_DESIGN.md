# Year-End Rollover — Design

**Date:** 2026-08-21
**Scope:** Creating the next academic-year schema and carrying forward students, masters,
fee configuration and outstanding balances. Covers `public.rollover_academic_year`,
`public.create_institution_schema`, and the admin-app flow that drives them.
**Status:** Design only — nothing in this document has been implemented.
**Companion:** `YEAR_CARRYOVER_PROCESS.md` — the target end-to-end process specification.
This document is the as-is audit (*what is wrong today*); that one is the spec
(*what the process should be*).
**Method:** read-only review of `complete_setup.sql`, `live_schema.sql`,
`rollover_academic_year.sql` (all in `C:\pg_backups`) and the Flutter admin app.

---

## TL;DR

A rollover function **already exists and is deployed**:
`public.rollover_academic_year(p_ins_id, p_old_year_label, p_new_year_label, p_start_date, p_end_date)`
— `complete_setup.sql:2189`, confirmed live in `live_schema.sql:3284`. The standalone draft
`C:\pg_backups\rollover_academic_year.sql` is byte-identical to the deployed body.

Two problems:

1. **Nothing calls it.** `dashboard_screen.dart:327` calls `create_institution_schema` only, so
   "New Year" produces an **empty** schema. The carry-forward path is dead code.
2. **It has drifted behind the schema.** It was written against an older table layout and now
   silently drops ~20 columns across 6 tables, and omits 4 tables entirely. Several of the drops
   are silent data corruption, not just missing data.

This is therefore a **repair-and-extend** job, not a greenfield build.

---

## Defect summary

| # | Severity | Defect | Table |
|---|----------|--------|-------|
| 1 | 🔴 Critical | `classfeedemand.collectible` not copied; column defaults `false` → every fee template becomes non-collectible in the new year | classfeedemand |
| 2 | 🔴 Critical | Granted to `anon`, `SECURITY DEFINER`, no `SET search_path` | function |
| 3 | 🟠 High | Promotion map joins `class` by name only, ignoring `cour_id` — duplicate class names across courses abort the whole rollover | promotion |
| 3b | 🟠 High | `adm_id` / `quo_id` / `cla_id` not carried on students — admission type and quota survive only as name strings | students |
| 4 | 🟠 High | `feedemand.arrearclass` never set on opening balances → arrear receipts print the wrong class | feedemand |
| 5 | 🟠 High | `feegroup_accountant` not copied → accountants lose all fee-group access on day one | feegroup_accountant |
| 6 | 🟠 High | No year-close mechanism → the same due is collectible in both the old and new schema | — |
| 7 | 🟡 Medium | `semester`, `community`, `division` not copied | masters |
| 8 | 🟡 Medium | `bank.ins_id` and `bank.paytm_mid` not copied | bank |
| 9 | 🟡 Medium | Opening balance ignores `collectible`, drops `fineamount`, ignores `reconbalancedue` | feedemand |
| 10 | 🟡 Medium | 9 further student columns dropped (demographics / medium / admit course) | students |
| 10b | 🟡 Medium | Unmatched class name or dangling `succeedingclass` silently un-promotes the student, still reported as carried | promotion |
| 10c | 🟡 Medium | Students at `activestatus` 2 / 9 appear in neither the carried nor the graduated count | promotion |
| 11 | 🟡 Medium | No detained-student concept and no per-student override | promotion |
| 12 | 🟢 Low | `feetype.type`, `sequence.seqend`, `sequence.division`, `classfeedemand` NOB/BGB/DHB flags not copied | misc |

---

## 1. Current state

### 1.1 What the deployed function does

Sections are numbered in `rollover_academic_year.sql`:

| Step | Line | Behaviour |
|------|------|-----------|
| 1 | `:81` | Calls `create_institution_schema` to build the empty new schema + `year` / `institutionyear` rows |
| 2 | `:87` | Copies masters **as-is with PKs preserved**, then `setval`s each sequence: bank, course, class, concessioncategory, admissiontype, quota, paymentgateway, finerule, classfeedemand, feegroup, feetype, sequence |
| 3 | `:195` | Builds a temp `_promote` map: class promoted via `class.succeedingclass` |
| 4 | `:220` | Inserts students with `stu_id` preserved, `stuclass` promoted, year re-stamped |
| 5 | `:244` | Inserts parents — only those linked to a carried student |
| 6 | `:270` | Inserts parentdetail with the promoted class |
| 7 | `:286` | One consolidated **Opening Balance** feedemand row per student per feetype |

Design decisions already baked in and worth keeping:

- **IDs are preserved** across the year boundary. This is deliberate and load-bearing —
  `feedemand.fee_id`, `sequence.fg_id`, `feegroup_accountant.fg_id` and `class.succeedingclass`
  self-references all depend on stable ids.
- **Receipt sequences reset** — `seqcurno` is copied as `seqstart`, so numbering restarts yearly.
- **Transactional.** DDL is inside the transaction, so a failure rolls back the entire new schema.
  There is no half-created state to clean up.
- **The old year stays intact and switchable.**
- **Not copied** (correctly): payment, paymentdetails, real feedemand, tempfeedemand,
  shoppingcart(+details), notice, notification, student_import, userlogin.

### 1.2 How students carry over, exactly

Two passes. **Pass 1** (`:195`) builds a temp table `_promote (stu_id, new_class)` — the decision of
who carries and to what class. **Pass 2** (`:220`) is a single `INSERT ... SELECT` from the old
schema's `students`, `JOIN _promote`. Nothing else governs membership: not in `_promote`, not in the
new year.

**Eligibility.** One filter: `s.activestatus = 1`. Suspended (`2`) and terminated / TC (`9`) students
are dropped — see §2.3b for why they also vanish from the summary.

**Class resolution.** Matched by string, not by id (§2.3), giving four outcomes:

| Situation | Result |
|---|---|
| Class matched, has `succeedingclass` | Promoted to `nc.claname` |
| Class matched, `succeedingclass IS NULL` | **Excluded** — treated as graduating |
| Class name not found in master | Carried, **same class**, silently (§2.3a) |
| `succeedingclass` points at a deleted / inactive row | Carried, **same class**, silently (§2.3a) |

**Field disposition on the copied row:**

| Disposition | Fields |
|---|---|
| **Preserved** | `stu_id`, `stuadmno`, `stuadmdate`, name / gender / DOB, contact, address, photo, `cour_id`, `courname`, `con_id` / `stucondesc`, `stuser_id`, `stupassword`, `batch`, `admname`, `quoname`, `admittyear` |
| **Re-stamped** | `yr_id`, `yrlabel` → new year; `stuclass` → promoted class |
| **Reset** | `stuotpstatus` → 0, `approveddate` → `now()`, `createdon` → `now()`, `activestatus` → 1 |
| **Dropped** | 18 columns, 12 of them material — see §2.3c |

`stu_id` preservation is the load-bearing choice: the student keeps the same identity across years,
so cross-year lookup by `stu_id` or `stuadmno` works. `setval` then advances `students_stu_id_seq`
past the max so new admissions don't collide.

Passwords survive intact — `hash_student_password` (`complete_setup.sql:2971`) skips values already
prefixed `$2a$` / `$2b$`, so the copied bcrypt hash is not re-hashed. Same for `parents`.

**What follows the student.** `parents` and `parentdetail` are both driven off the same `_promote`
map — a parent carries only if they have a `parentdetail` row pointing at a carried student.
`par_id` and `pd_id` are preserved, `parotpstatus` resets to 0, `parentdetail.stuclass` gets the
promoted class. Fee history does **not** follow; only the consolidated Opening Balance row per
feetype crosses over.

`succeedingclass` is alive and maintained — `drop_succeedingclass.sql` exists in `C:\pg_backups`
but was **never applied** (`complete_setup.sql:2786` still creates the column), and
`master_data_screen.dart:683` auto-chains it by `ordid`.

### 1.3 What raises next year's demands

Auto-generation of fee demands on student insert is **deliberately disabled**
(`complete_setup.sql:2813-2818` drops `trg_gen_feedemand_on_student` and documents why).
So carried students land with an opening balance and **no current-year demands**. Year-start is
therefore a two-step operation: rollover, then `public.generate_feedemand_from_template(p_ins_id)`
(`complete_setup.sql:3909`) → `tempfeedemand` → Fee Demand Approval → `feedemand`.

---

## 2. Defects in detail

### 2.1 🔴 `classfeedemand.collectible` silently flips to false

`complete_setup.sql:2805` declares `collectible boolean DEFAULT false NOT NULL`. The copy at
`rollover_academic_year.sql:160` enumerates only
`(cf_id, cfclass, cfterm, cffeetype, cfamount, cfdduedate, admissiontype)`.

Every template row therefore lands with `collectible = false`. `fn_gen_feedemand_on_student`
propagates it via `COALESCE(cf.collectible, true)`, so demands generated from those templates are
also non-collectible. **The new year opens unable to collect fees.**

Also missing from the same copy: `activestatus`, `cla_id`, `sem_id`, `fee_id`, and the
`cfnob` / `cfbgb` / `cfdhb` New-Old / Boy-Girl / DayScholar-Hosteller flags added by
`add_cf_flags.sql`.

`cla_id` / `sem_id` / `fee_id` self-heal — the `set_classfee_ids` trigger re-resolves them from the
name columns on insert. `collectible`, `activestatus` and the three flags do **not**.

### 2.2 🔴 Security posture

```
GRANT EXECUTE ON FUNCTION public.rollover_academic_year(...) TO anon, authenticated;
```
(`complete_setup.sql:2469`)

The function is `SECURITY DEFINER` with **no `SET search_path`**. Two consequences:

- Any holder of the anon key can create schemas and bulk-copy an institution's data. This is
  finding #1 of `SECURITY_REVIEW.md` in a new form and contradicts the Option B session-gated
  RPC remediation already in progress.
- The unpinned `search_path` on a definer function that also does `CREATE TEMP TABLE _promote`
  is a resolution-hijack surface. Peer functions such as `read_lock_schema`
  (`complete_setup.sql:881`) already pin it.

**Fix shape:** take `p_token`, derive `ins_id` server-side via `session_context`, verify an admin
role, and pin `SET search_path` — matching the existing `*_secure` wrappers.

### 2.3 🟠 Promotion map aborts on duplicate class names

The promotion map (`rollover_academic_year.sql:195`) resolves the next class by **string-matching**
the student's class against the class master:

```sql
LEFT JOIN class c ON UPPER(TRIM(c.claname)) = UPPER(TRIM(s.stuclass))
                 AND c.ins_id = s.ins_id AND c.activestatus = 1
LEFT JOIN class nc ON nc.cla_id = c.succeedingclass
```

The join **does not include `cour_id`**, and there is no unique constraint on `(ins_id, claname)` —
`class` (`complete_setup.sql:2786`) carries `cour_id` and the comment on the next line calls it
"optional / informational".

So an institution running "I YEAR" under both B.E-CSE and B.E-ECE produces **two** `_promote` rows
for one student. `_promote` declares `stu_id` as PRIMARY KEY, so this is a unique violation and the
**entire rollover aborts**.

It fails safe — one transaction, full rollback, no corruption — but any multi-course institution
with reused class names cannot run the rollover at all. **Fix:** disambiguate the join on course
(`c.cour_id = s.cour_id`, with a fallback for NULL `cour_id`), or add a unique constraint on
`(ins_id, claname, cour_id)` and match on it.

### 2.3a 🟡 Silent un-promotion

Two branches of the promotion map fall back to *"leave the student where they are, say nothing"*:

- `CASE WHEN c.cla_id IS NULL THEN s.stuclass` — class name not found in the master
- `COALESCE(nc.claname, s.stuclass)` — `succeedingclass` points at a deleted or inactive row

A renamed class, a trailing-space typo, or a class row deactivated mid-year therefore silently
un-promotes an entire batch, **and the summary still counts them as carried**. There is no warning
and no way to distinguish them afterwards. The preview (§4) must surface these as a distinct
"could not resolve promotion" bucket rather than letting them pass as normal carries.

### 2.3b 🟡 Inactive students vanish from the summary

The returned JSON computes `students_graduated = active_students - students_carried`, where
`active_students` counts only `activestatus = 1`. Students at `activestatus` 2 (suspended) or 9
(terminated / TC) are therefore counted in **neither** bucket — they disappear with no line item.
The summary should report them explicitly.

### 2.3c 🟠 Student columns dropped — including admission type and quota

`students` (`complete_setup.sql:2742`) has 54 columns; the copy at `rollover_academic_year.sql:220`
lists 36. Of the 18 absent, 6 are correctly omitted (`stumobotp` is a transient OTP, and the
suspend/terminate fields are meaningless because only `activestatus = 1` students carry). The
remaining **12 are material losses**:

```
admit_cour_id, aadharno, community, caste, religion, nationality,
transportmode, hostel, medium, cla_id, adm_id, quo_id
```

`adm_id` and `quo_id` are the admission-type and quota foreign keys. Today only the human-readable
`admname` / `quoname` strings survive, so anything joining on the id breaks and any later rename of
a quota silently orphans the historical rows.

**`cla_id` is worse than merely missing.** The function promotes `stuclass` (the string) but has no
logic to recompute `cla_id`. Simply adding `cla_id` to the copy list would carry the **old** class's
id against the **new** class's name — an inconsistency worse than NULL. The promotion map must
resolve and emit the new `cla_id` alongside the new `claname`.

### 2.4 🟠 Opening balances lose their originating class

Fee collection deliberately attributes an arrear to the class it **arose in**, not the student's
current class — see `fee_collection_screen.dart:3405`, `student_fee_collection_screen.dart:3090`
and `failed_transactions_screen.dart:243`, all of which read `feedemand.arrearclass`. The column is
also surfaced as "Arrear Class" in `fee_demand_screen.dart:126`.

The opening-balance insert (`rollover_academic_year.sql:286`) stamps `stuclass = p.new_class` and
**never sets `arrearclass`**. Arrear receipts in the new year will therefore print the promoted
class instead of the class the due came from.

**Fix:** set `arrearclass` to the old year's `stuclass` (or preserve the old row's `arrearclass`
when it is already an arrear being carried a second time).

### 2.5 🟠 `feegroup_accountant` is not copied

`complete_setup.sql:2772` — this is the fee-group→accountant access mapping. It is not in the copy
list at all, so every accountant loses access to every fee group the moment the new year opens, and
the mapping must be rebuilt by hand annually.

### 2.6 🟠 No year-close — the same due is collectible twice

After rollover the old schema remains fully writable and switchable. A clerk can collect an
outstanding due **in the old year** and the same amount again as an **Opening Balance in the new
year**. Nothing prevents or detects this.

There is no existing mechanism to lean on:

- `institutionyear.iyearsubstatus` (`complete_setup.sql:210`) is subscription/licence state,
  not a year lock.
- `read_lock_schema` (`complete_setup.sql:881`) applies RLS tenant-scoping; it is not a freeze.

**A genuine "year closed" flag is required**, enforced server-side in the payment RPCs, not just
hidden in the UI.

### 2.7 🟡 Master tables not copied

| Table | Line | Consequence of omission |
|-------|------|------------------------|
| `semester` | `:2801` | `set_classfee_ids` cannot resolve `sem_id`; term-based demands lose their semester link |
| `community` | `:2796` | Student community master empty |
| `division` | `:2797` | Division master empty |
| `feegroup_accountant` | `:2772` | See 2.5 |

### 2.8 🟡 `bank` copy is incomplete

`bank` (`complete_setup.sql:2830`) has `ins_id` and `paytm_mid`; the copy at
`rollover_academic_year.sql:90` lists neither. Banks arrive unscoped to the institution, and Paytm
merchant routing breaks for the new year.

### 2.9 🟡 Opening-balance arithmetic is under-specified

The step-7 aggregation filters `activestatus = 1 AND paidstatus = 'U' AND balancedue > 0` and
groups by `demfeetype`. Four unresolved policy questions:

- **`collectible` is not filtered.** Optional fees the student never opted into are carried as
  arrears.
- **`fineamount` is forced to 0.** Accrued overdue fines from `finerule` are written off. Deliberate?
- **`reconbalancedue` is ignored.** Cheque and online payments still pending reconciliation
  (`payment.recon_status = 'P'`) are treated as realized. `feedemand` carries both `balancedue` and
  `reconbalancedue` precisely because they can differ.
- **Term detail is collapsed.** All terms merge into one row per feetype with
  `demfeeterm = 'Opening Balance'`. Reasonable, but it means the new year cannot report which term
  the arrear came from — and `'Opening Balance'` is unlikely to exist in the `semester` master, so
  `sem_id` will be NULL.

Grouping per feetype (rather than per feegroup) is correct and should be kept — it preserves
feetype → feegroup → bank routing so arrears are collected into the right bank account.

Note the `set_dem_id` trigger fills `dem_id`, `demno` and `demseqtype`, so the missing NOT NULL
columns in the insert do not fail — but each opening-balance row **consumes a DEMNO from the
freshly reset sequence**. Since step 2 resets sequences before step 7 runs, the new year's first
manual demand starts after the opening-balance block. Confirm that is intended.

### 2.10 🟡 No detained-student concept

Promotion is unconditional: everyone with a `succeedingclass` moves up. There is no way to express
"repeat the same class", and no per-student override at all. Combined with the two implicit exit
rules (§1.2), the operator has **no control** over who carries forward beyond editing
`activestatus` by hand before running the rollover.

---

## 3. Entity-by-entity handling

### Students — carry, detain, exit

Auto-promotion via `succeedingclass` is the right default but needs an explicit **decision set**
computed *before* the copy, with one of three dispositions per student:

- **Promote** → next class per `succeedingclass`, `cla_id` recomputed
- **Detain** → same class, same `cla_id`
- **Exit** → not carried, with a reason (graduated / TC / dropped / transferred)

The UI pattern already exists twice in the codebase and should be reused rather than reinvented:

- `class_allocation_screen.dart` — grid of students, per-row class dropdown, bulk save. This is
  structurally identical to a promotion review screen.
- `interim_promotion_screen.dart` — already models mid-year class transfer and logs it to the
  `interim_promotion` table (`complete_setup.sql:2842`).

Pre-fill the grid from `succeedingclass`, let the clerk override, then pass the decision set to the
rollover instead of letting SQL infer it.

### Fee group / fee type

Copy-as-is with IDs preserved is correct — keep it. Required changes: add `feetype.type`, and copy
`feegroup_accountant`. Year re-stamping (`yr_id`, `yrlabel`) already works.

### Admission — special case, not per-year

`public.admission` (`complete_setup.sql:99`) lives in the **public** schema, is keyed
`UNIQUE (ins_id, admno)`, and has **nullable** `yr_id` / `yrlabel` (the live table dropped them;
they are retained nullable only because `allocate_admission_to_student` still reads them).

Consequences:

- There is nothing to copy — admissions are already visible from every year.
- **Admission numbers do not restart** per year, because uniqueness is per institution. This is
  inconsistent with the receipt-sequence reset in step 2 and should be an explicit, documented
  decision rather than an accident. Note `institution_settings.admission_number_mode`
  (`AUTO` | `MANUAL`) interacts with this.
- **Open policy question:** what happens to rows still `admstatus = 'PENDING'` when the year rolls?
  Options: (a) leave them pending and allocate into new-year classes, (b) bulk-cancel at year end,
  (c) stamp them with the new `yrlabel`. This must be decided — today the behaviour is
  unspecified and they simply linger.

### Quota

`quota` and `admissiontype` are smallint-PK masters already copied as-is at
`rollover_academic_year.sql:127` and `:133`. The only fix needed is on the **student** side —
carrying `quo_id` / `adm_id` so the ids remain meaningful rather than relying on name-string
matching (§2.3c).

### Balance

Beyond the arithmetic questions in §2.9, the structural requirement is the **year-close flag**
(§2.6). Without it, opening balances create a double-collection window rather than closing one.

---

## 4. Missing structural pieces

**No dry run.** Nothing reports *"412 carried, 68 graduating, 14 detained, ₹8.4L opening balance"*
before committing. For an irreversible bulk operation on a live institution this is the single
highest-value addition.

**No re-run path.** The function aborts if the new schema already exists. The whole thing is one
transaction, so that is *safe* — but it means the only recovery from a wrong rollover is a manual
`DROP SCHEMA`. Consider an explicit, admin-gated "discard and redo" that requires the new schema to
have zero payments.

**PostgREST exposure.** On the Supabase free tier `expose_schema` must be run manually, so the new
schema exists but is invisible to the API until that SQL runs. The rollover must either handle it
or the flow must surface the requirement — otherwise "the year was created but the app shows
nothing" is the reported symptom.

**Demand generation is a separate step.** See §1.3.

---

## 5. Target flow

1. **Preview** — session-gated, read-only RPC returning the promotion table plus counts and money
   totals. Writes nothing.
2. **Review** — promotion screen (pattern from `class_allocation_screen.dart`) where the clerk sets
   Promote / Detain / Exit per student, with a reason on exits.
3. **Commit** — rollover accepts the decision set as a parameter and runs in one transaction:
   create schema → copy masters with **complete** column lists → students with promoted `stuclass`
   *and* recomputed `cla_id`, carrying `adm_id` / `quo_id` / demographics → parents + parentdetail →
   opening balances with `arrearclass` set, filtered on `collectible`, under a stated fine and
   reconciliation policy.
4. **Close old year** — set the year-closed flag; block collection in the old schema server-side.
5. **Open new year** — expose the schema, `generate_feedemand_from_template`, approve demands.

---

## 6. Work order

1. **Blockers** — §2.3 aborts the rollover outright for any multi-course institution with reused
   class names. Nothing else can be tested until this is fixed.
2. **Correctness bugs** — §2.1, §2.3a, §2.3c, §2.4, §2.5, §2.7, §2.8. These are silent and they
   corrupt data. §2.1 alone makes the new year uncollectable.
3. **Security gate** — §2.2. Cheap, and it aligns with the in-flight hardening work.
4. **Preview + promotion override screen** — §2.3a, §2.3b, §2.10, §4.
5. **Year-close flag** — §2.6. Must not slip past the first real rollover, or double collections
   will need reconciling by hand.
6. **Policy decisions to confirm with the institution** — pending admissions at year end,
   fine write-off, reconciliation treatment, admission-number continuity.

### Guard against the next drift

The function hardcodes column lists for ~15 tables, which is exactly why it drifted this far. Add a
guard that **fails loudly** when a table's live column set does not match what the copy enumerates
(compare against `information_schema.columns` at run time). Without it, the next migration silently
breaks next year's rollover the same way this one broke.

---

## Appendix — table disposition matrix

Per-year schema tables from `create_institution_schema` (`complete_setup.sql:2720`).

| Table | Today | Should be |
|-------|-------|-----------|
| `year` | created by `create_institution_schema` | unchanged |
| `students` | copied, 12 columns dropped, class promoted | copy **all** columns; `cla_id` recomputed; disposition-driven |
| `parents` | copied for carried students | unchanged |
| `parentdetail` | copied, class updated | also update `cla_id` if added |
| `feedemand` | opening balance only | + `arrearclass`, `collectible` filter, fine/recon policy |
| `tempfeedemand` | not copied | unchanged (correct) |
| `feegroup` | copied, year re-stamped | unchanged |
| `feetype` | copied, year re-stamped | + `type` |
| `feegroup_accountant` | **not copied** | copy |
| `concessioncategory` | copied | unchanged |
| `course` | copied | unchanged |
| `class` | copied with `succeedingclass` | unchanged |
| `admissiontype` | copied | unchanged |
| `quota` | copied | unchanged |
| `community` | **not copied** | copy |
| `division` | **not copied** | copy |
| `semester` | **not copied** | copy |
| `classfeedemand` | copied, 8 columns dropped | copy **all** — esp. `collectible` |
| `finerule` | copied | unchanged |
| `payment` | not copied | unchanged (correct) |
| `bank` | copied, `ins_id` + `paytm_mid` dropped | copy both |
| `paymentdetails` | not copied | unchanged (correct) |
| `paymentgateway` | copied | unchanged |
| `interim_promotion` | not copied | unchanged (correct — year-specific log) |
| `fee_refund` / `fee_refunddetails` | not copied | confirm: pending adjustments may need carrying |
| `sequence` | copied, `seqcurno` reset | + `seqend`, `division` |
| `shoppingcart` / `shoppingcartdetails` | not copied | unchanged (correct) |
| `notice` / `notification` | not copied | unchanged (correct) |
| `userlogin` | not copied | unchanged (correct) |
| `student_import` | not copied | unchanged (correct) |

Public tables — no copy, but note the behaviour:

| Table | Note |
|-------|------|
| `public.admission` | cross-year by design; `admno` unique per institution, does **not** restart. Pending-row policy undecided |
| `public.institutionyear` | new row created by `create_institution_schema`; `iyearsubstatus` is subscription state, not a year lock |
| `public.institution_settings` | per-institution, not per-year — no action |
