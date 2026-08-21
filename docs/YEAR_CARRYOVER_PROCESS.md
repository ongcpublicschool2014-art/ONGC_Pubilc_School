# Academic Year Carry-Over — Process Specification

**Date:** 2026-08-21
**Status:** Specification. Not implemented.
**Companion:** `YEAR_ROLLOVER_DESIGN.md` — the as-is audit of the deployed
`public.rollover_academic_year` and its defects. That document says *what is wrong today*;
this one says *what the process should be*.

---

## Five principles

Everything below follows from these. Where a later decision looks arbitrary, it is being
forced by one of these.

1. **A closed year is immutable.** Once a year ends, no row in its schema changes meaning.
   Promotion never rewrites `stuclass` in the year the student actually sat in that class.
2. **Decide from the old year, write to the new year.** The promotion decision is *computed*
   by reading the old schema and *applied* only to the new schema.
3. **One reviewed decision set, one transaction.** A human approves an explicit list; the
   commit executes exactly that list and nothing inferred at run time.
4. **Money must tie out.** Old-year closing balance for carried students equals new-year
   opening balance, to the rupee. Any difference is a named, approved exception.
5. **Nothing is silent.** Every student who does not carry, and every student whose promotion
   could not be resolved, appears explicitly in a report. Absence is never the answer.

---

## Process overview

| Phase | Writes? | Reversible? | Output |
|-------|---------|-------------|--------|
| 0 — Gates | No | — | Pass / list of blocking problems |
| 1 — Preview | No | — | Disposition table + money projection |
| 2 — Review & freeze | Decision set only | Yes, until frozen | Approved, frozen decision set |
| 3 — Commit | New schema | All-or-nothing | New year populated + audit log |
| 4 — Close old year | Old year flag | Yes (reopen) | Old year read-only for collection |
| 5 — Open new year | New year | Normal operations | Demands raised, year active |

---

## Phase 0 — Gates

These are **blocking preconditions**, not warnings. Each failure names a specific screen where
it is fixed. Running the rollover with any of these unresolved produces damage that is
expensive to undo.

### Structural

| Gate | Why |
|------|-----|
| New year schema does not already exist | Prevents clobbering a prior attempt |
| Old year schema exists and is the active year | Prevents rolling over from a stale year |
| Licence/subscription valid for the new year | `institutionyear.iyearsubstatus` — a year you cannot open is not worth creating |

### Class master is promotion-ready

| Gate | Why |
|------|-----|
| No duplicate `(ins_id, claname, cour_id)` among active classes | Duplicate class names abort the rollover outright — see `YEAR_ROLLOVER_DESIGN.md` §2.3 |
| Every active class has `succeedingclass` set **or** is explicitly flagged terminal | Today "no successor" and "terminal class" are the same state, so a forgotten link silently graduates a whole batch |
| Every `succeedingclass` points at a live, active class row | A dangling pointer silently un-promotes |
| No cycles in the promotion ladder | A → B → A loops forever conceptually and produces nonsense |

The second gate needs a **schema change**: `class` currently cannot distinguish "terminal" from
"nobody filled this in". Add an explicit `is_terminal` flag, or the gate cannot be enforced.

### Student data is resolvable

| Gate | Why |
|------|-----|
| Every active student's `stuclass` matches exactly one active class row | Unmatched students are silently kept in place today |
| Every active student has a `cour_id` where the class master is course-scoped | Needed to disambiguate the class join |

### Financial quiet-state

| Gate | Why |
|------|-----|
| `tempfeedemand` approval queue empty (`isapproved = false`) | `tempfeedemand` is not carried; unapproved demands are silently destroyed |
| No payments in `paystatus = 'I'` (initiated) | An in-flight gateway payment would settle into a superseded year |
| Reconciliation queue empty (`payment.recon_status = 'P'`) | Otherwise the opening balance is computed from money that may still bounce — see Financial perspective |
| Credit / advance balances resolved | `feedemand.balancedue` has `CHECK (balancedue >= 0)`, so overpayments cannot be represented as negative dues and would be lost |

Making the reconciliation queue a **gate** rather than a policy question is deliberate: it turns
a hard modelling problem (how do you carry a balance that might reverse?) into an operational
one (clear the queue first). That is the cheaper trade.

---

## Phase 1 — Preview

A **read-only, session-gated RPC**. Writes nothing. Returns everything a human needs to approve
or reject the rollover.

### Student disposition table

One row per active student:

```
stu_id, stuadmno, stuname, courname, current_class, proposed_class,
disposition, reason, outstanding_due
```

`disposition` ∈ `PROMOTE` | `DETAIN` | `GRADUATE` | `EXIT` | `UNRESOLVED`

`UNRESOLVED` is the important addition. Today an unmatched class or dangling `succeedingclass`
falls through to "keep the same class" and is reported as a normal carry. It must instead
surface as its own bucket and block the commit until cleared.

### Counts

Every active student lands in exactly one bucket, and the buckets sum to the total:

```
promote + detain + graduate + exit + unresolved = active_students
```

Inactive students (`activestatus` 2 / 9) are reported **separately and explicitly** — today they
appear in neither the carried nor the graduated count and vanish without trace.

### Money projection

- Closing balance by fee group, by class, by fee type
- Count of students with dues, and total
- **Projected opening balance** — what would be written, itemised the same way
- **Exiting students with outstanding dues** — see below

### The exit-with-dues problem

A student who graduates or takes a TC while still owing money is a real business event, and the
current design makes the debt **disappear**: they are not carried, so no opening balance is
created, and the old year is closed. The money is simply gone from the system.

The preview must list these students separately, and Phase 2 must force one of three explicit
choices per student:

| Choice | Effect |
|--------|--------|
| **Hold** | Student is not exited; carries into the new year despite being in a terminal class, so the due remains collectible |
| **Write off** | Due is closed with an approval reason and an audit row; reported as a write-off, not as a collection |
| **Carry to alumni register** | Due survives outside the year schemas so it stays visible and collectible |

The third requires a place to put it — a public-schema alumni-dues table, since per-year schemas
are the wrong home for a debt that outlives the year. This is a design decision, not a detail.

---

## Phase 2 — Review and freeze

A grid, pre-filled from Phase 1. The pattern already exists in `class_allocation_screen.dart`
(per-row class dropdown, bulk save) and should be reused rather than reinvented.

### Per-student controls

| Control | Notes |
|---------|-------|
| Disposition | Promote / Detain / Graduate / Exit |
| Target class | Defaults to the ladder successor; editable |
| Target course | For students changing stream at promotion — must update `cour_id` **and** `admit_cour_id` semantics consistently |
| Exit reason | Mandatory on Exit: Graduated / TC / Dropped / Transferred / Deceased |
| Dues action | Mandatory when exiting with a balance (see above) |

### Bulk actions

Promote-all-by-class, detain-selected, exit-selected. Year-end promotion touches hundreds of
students; per-row editing alone is unusable.

### Freeze

On approval the decision set is **persisted and frozen**, with a hash. Phase 3 executes exactly
the frozen set and re-verifies the hash. Two reasons:

- The commit must not re-derive anything at run time. What was reviewed is what runs.
- The decision set is client-supplied, so it must be **server-validated**: every target class
  must exist and be active, every `stu_id` must be an active student in the old schema, and no
  `stu_id` may appear twice.

---

## Phase 3 — Commit

Single transaction, session-gated, admin role required, `SET search_path` pinned, and a
`statement_timeout` raised for large institutions (`generate_feedemand_from_template` already
uses `'180s'` as precedent).

### Ordering

Dependency order matters — later steps resolve ids against earlier ones via triggers.

1. **Create schema** — `create_institution_schema`, which also creates the `year` and
   `institutionyear` rows and applies `read_lock_schema` so the schema is born RLS-locked.
2. **Masters, in dependency order:**
   `course` → `class` → `semester` → `community` → `division` → `concessioncategory` →
   `admissiontype` → `quota` → `bank` → `paymentgateway` → `finerule` → `feegroup` →
   `feetype` → `feegroup_accountant` → `classfeedemand` → `sequence`
3. **`setval` every sequence** past the copied maximum.
4. **Students**, from the frozen decision set — all columns, `cla_id` recomputed from the
   *target* class, `adm_id` / `quo_id` / demographics carried.
5. **Parents** — only those with a `parentdetail` row pointing at a carried student.
6. **Parentdetail** — target class and `cla_id`.
7. **Opening balances** — see Financial perspective.
8. **Audit log** — promotion register, exit register, write-off register.
9. **Return a summary** that ties out (Principle 4).

Copy every column. The single biggest cause of the current defects is hardcoded column lists
that drifted — `classfeedemand.collectible` defaults to `false`, is not in the copy list, and
therefore silently makes the entire new year uncollectable.

### Drift guard

Before copying each table, compare its live column set against what the copy enumerates and
**raise** on mismatch. Without this, the next migration breaks next year's rollover exactly the
way the last several migrations broke this one — silently, and only discovered a year later.

---

## Phase 4 — Close the old year

Currently **impossible** — there is no year-close concept. `institutionyear.iyearsubstatus` is
subscription state; `read_lock_schema` is RLS tenant-scoping. Neither is a lock.

Without it, the same due is collectible twice: once in the old schema and once as an opening
balance in the new one. Nothing detects the double collection.

Requirements:

- A year-closed flag, set as part of the same operation (not an optional follow-up)
- **Server-side** enforcement in the payment RPCs — rejecting collection against a closed year,
  not merely hiding the button
- The old year stays fully **readable** and reportable, permanently
- A deliberate, audited reopen path for corrections

---

## Phase 5 — Open the new year

1. **Expose the schema to PostgREST.** On the Supabase free tier `expose_schema` runs manually
   and is outside the transaction. If the commit succeeds and this step does not, the year exists
   but the app sees nothing — the classic reported symptom. Needs a retryable repair action.
2. **Switch the active year.**
3. **Generate demands** — `generate_feedemand_from_template(p_ins_id)` → `tempfeedemand` →
   Fee Demand Approval → `feedemand`. Auto-generation on student insert is deliberately disabled,
   so this is a required explicit step.
4. **Run the tie-out report** — old-year closing versus new-year opening.

**Ordering constraint:** demand generation matches `cf.cfclass = students.stuclass`. Classes must
be final before demands are generated. This is why promotion belongs in Phase 3, not as a
post-carry step inside the new year.

---

## Perspectives

### Academic

- **Detention** has no representation today. Promotion is unconditional for anyone with a
  successor. Detain = carry at the same class, same `cla_id`.
- **Terminal vs unset** must become distinguishable on `class` (Phase 0).
- **Course change at promotion** — a student moving stream needs `cour_id` updated alongside the
  class, and the relationship to `admit_cour_id` (the course they were *admitted* to) decided:
  `admit_cour_id` is a historical fact and should never change; `cour_id` is current and should.
- **`batch` and `admittyear` are cohort identity** — immutable, carried unchanged forever. They
  are what makes "the 2024 batch" meaningful after four promotions.
- **Register numbers** (`sequence`, `actname = 'REGNO'`) are typically permanent per student,
  unlike receipt numbers which reset yearly. The current code resets *every* sequence
  indiscriminately. Confirm which sequences are year-scoped and which are institution-scoped.
- **Section allocation** for the new year is a separate step after promotion —
  `section_transfer_screen.dart` already handles it.

### Financial

**Opening balance composition.** Per carried student, per fee type:

- Base it on **realized** money, not pending money — hence the reconciliation gate in Phase 0.
- **Filter on `collectible`.** Optional fees the student never opted into must not become arrears.
- **Fines are separable.** `fineamount` is a penalty, not principal. Carrying it merged into the
  principal makes it impossible to waive a fine later without touching the fee. Carry it as a
  distinct arrear line, not folded in — and never as a silent write-off, which is what happens
  today.
- **Do not re-apply concession.** The opening balance is a *net* figure; the concession was
  already applied when the original demand was raised. Carry `con_id` for provenance with
  `conamount = 0`. Re-applying would discount the same student twice.
- **Group per fee type, not per fee group.** This preserves fee type → fee group → `ban_id`
  routing so arrears land in the correct bank account. The current code gets this right; keep it.
- **Set `arrearclass`** to the class the due arose in. Fee collection deliberately attributes
  arrears to the originating class (`fee_collection_screen.dart:3405`,
  `student_fee_collection_screen.dart:3090`), and today it is never populated.

**Credit balances.** `balancedue` has `CHECK (balancedue >= 0)`, so an overpayment cannot be
carried as a negative due. Either refund before close, or model credits explicitly. Currently
they would be lost. This is why it is a Phase 0 gate.

**Numbering.** Opening-balance rows consume DEMNO from the freshly reset sequence, so the new
year's first real demand does not start at 1. Give opening balances their own `demseqtype` and
sequence, or reserve a block, so year-one numbering stays clean.

**Tie-out report.** Automatic, immediately post-commit:

```
sum(old year closing balance, carried students)
  = sum(new year opening balance)
  + sum(approved write-offs)
  + sum(alumni-register transfers)
```

Any residual is a bug, and the report is the only thing that will catch it.

### Student lifecycle

| Exit type | Record required | Dues handling |
|-----------|-----------------|---------------|
| Graduated | Alumni lookup by `stu_id` / `stuadmno` | Must be cleared, written off, or moved to alumni register |
| TC issued | TC number, date, reason | Normally cleared at TC issue |
| Dropped / absconding | Reason, last-attended date | Usually written off with approval |
| Transferred out | Destination institution | Cleared |
| Deceased | Date | Written off |
| **Detained** | Not an exit — carries at same class | Carries normally |

**Readmission.** A student who exits and returns later should reuse the same `stu_id` and
`stuadmno`, because `stu_id` is preserved across years and `admno` is unique per institution.
That requires a cross-year lookup at admission time — searching closed schemas, not just the
active one. Without it, returning students get duplicate identities and their fee history splits.

### Parent and portal

- `par_id` and `pd_id` are preserved, so parent identity survives.
- **`parotpstatus` is reset to 0 today**, forcing every parent to re-verify by OTP at year start.
  That is a real support burden every single year, and it is currently an accident rather than a
  decision. Either keep verification (`parotpstatus` carried as-is) or make annual
  re-verification an explicit, documented security policy.
- A parent with one child carried and one graduated: the parent row carries, but the graduated
  child's history lives only in the old schema. The portal must resolve children across years,
  not just the active one.
- Parent sessions resolve the schema by year, so the switch must be atomic with Phase 5 or
  parents briefly see an empty year.

### Security

- Session-gated (`p_token`), `ins_id` derived **server-side**, admin role verified. The function
  is currently granted to `anon` with no role check — anyone holding the anon key can create
  schemas and bulk-copy tenant data.
- `SET search_path` pinned. The function is `SECURITY DEFINER` and creates a temp table with an
  unpinned path; `read_lock_schema` already sets the precedent for pinning.
- The frozen decision set is client-supplied and must be fully re-validated server-side.
- New schema born read-locked — `create_institution_schema` already calls `read_lock_schema`.
  Verify this still holds for rollover-created schemas.

### Audit

Nothing currently records what happened. The only evidence a promotion occurred is a diff
between two schemas. Required, and printable:

- **Promotion register** — student, from class, to class, disposition, decided by, decided when
- **Exit register** — student, exit type, reason, outstanding due at exit, dues action taken
- **Write-off register** — separately, because write-offs are a financial control point and must
  be reviewable independently of promotions
- **Run record** — who executed the rollover, when, the decision-set hash, the returned summary

`interim_promotion` already models in-year transfers and is the natural template, but year-end
promotion should be its own log — the two are different events and mixing them makes both
reports wrong.

### Failure and recovery

- **Atomicity is already correct.** DDL inside the transaction means a failure drops the whole
  new schema. Keep this.
- Verify the `public.institutionyear` row inserted by `create_institution_schema` also rolls back.
- `expose_schema` is outside the transaction — must be idempotent and separately retryable.
- **Post-commit verification**, run automatically: row counts per table, tie-out, `UNRESOLVED`
  count is zero, every carried student's `cla_id` matches their `stuclass`.
- **Discard-and-redo**: an explicit, admin-gated action that drops the new schema, permitted only
  while it contains zero payments. Today the only recovery is a manual `DROP SCHEMA`.

### Reporting

- Cross-year student search by `stu_id` / `stuadmno`, spanning closed schemas
- Closing-versus-opening tie-out (above)
- Promotion and exit registers (above)
- Year-over-year comparison: strength by class, collection by fee group

---

## Open decisions

These need the institution's answer. Each changes what gets built, so none can be defaulted
silently.

| # | Decision | Options |
|---|----------|---------|
| 1 | Students exiting with outstanding dues | Hold / write off / alumni register |
| 2 | Accrued fines at year end | Carry as separate arrear line / merge into principal / waive |
| 3 | Credit and advance balances | Refund before close / model as carried credit |
| 4 | Pending `public.admission` rows at year end | Leave pending / bulk cancel / re-stamp to new year |
| 5 | Register number continuity | Permanent per student / reset yearly (receipt numbers reset — confirm REGNO does not) |
| 6 | Admission number continuity | Currently does **not** reset (`admno` unique per institution) — confirm intended |
| 7 | Parent OTP re-verification | Annual re-verify / carry verified state |
| 8 | Reconciliation queue | Hard gate (recommended) / carry `reconbalancedue` and handle bounces cross-year |

---

## What has to change structurally

Beyond fixing the existing function, four things do not exist today and must be built:

1. **`class.is_terminal`** — to distinguish "end of ladder" from "nobody filled this in".
2. **Year-closed flag + server-side enforcement** — to stop double collection.
3. **A promotion decision-set table** — persisted, frozen, hashed, auditable.
4. **An alumni-dues home** in the public schema — if decision #1 goes that way, a debt that
   outlives the year cannot live in a year schema.

---

## Sequencing summary

```
Phase 0  gates            ── fail fast, name the fix
Phase 1  preview          ── read-only, full disposition + money
Phase 2  review & freeze  ── human decides, set is frozen + hashed
Phase 3  commit           ── one transaction, exactly the frozen set
Phase 4  close old year   ── flag + server-side enforcement
Phase 5  open new year    ── expose, switch, generate demands, tie out
```

Phases 3 and 4 must be a single operation. Separating them opens the double-collection window
that Principle 1 and Principle 4 exist to prevent.
