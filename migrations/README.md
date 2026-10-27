# migrations/

SQL that has to be run by hand in the Supabase SQL editor. Nothing here runs
automatically, and nothing in the apps connects with credentials that could run
it — every file is applied to TEST first, then to LIVE by the user.

## Where a new file goes

Both apps share ONE database, so a clean two-way split is not possible: a
function like `process_grouped_payment` is called by the desktop app AND
reached by the parent app through its payment flow. The folders say **who asked
for the change**, which is what you need when a release goes wrong and you want
to know which app's queue to look at.

| Folder | For |
|---|---|
| `desktop/` | Changes a desktop-admin feature needs, and the parent app never touches: fee master, admission, reports, utilities, roles/menu access, bank reconciliation, year rollover. |
| `mobile/` | Changes the parent app needs: anything read or written by the parent's own screens and nothing else. |
| `shared/` | Anything both apps depend on. **Routing, receipt sequences, payment/advance/misc RPCs, and every anon-grant change live here** — the parent app pays through the same functions the desktop app posts through. If you are unsure, it is `shared/`. |

A change that starts in one app but touches a shared RPC is `shared/`. Splitting
it into two files so each app "owns" its half is how you get a LIVE database
that is half-migrated.

## Naming

    <SCOPE>_<WHAT_IT_DOES>.sql

`SCOPE` is `LIVE_` only when the script is written for the live database
specifically (a data fix keyed to live's rows) or `TEST_` for a TEST-only
rehearsal. Everything else carries no prefix and is meant for both, TEST first.

## Rules that have not changed

- **TEST before LIVE, always.** Never run an unrehearsed script on live.
- Anything that rewrites existing rows ships **dry-run by default**, printing
  what it would change; the user flips a flag to commit. `SYNC_CLASS_COURSE_NAMES.sql`
  is the reference for this.
- After a script is applied, fold its DDL into `C:\pg_backups\complete_setup.sql`
  **in the same session**, so a fresh database built from that file matches live.
- Never seed business data through a migration.

## Before today (2026-09-28)

Everything sitting loose in `migrations/` predates this split. It is left where
it is on purpose: the pending-LIVE queue refers to those files by path, and
moving them mid-queue is how a step gets skipped. New files go in the folders.
