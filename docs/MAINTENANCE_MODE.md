# Maintenance Mode — gating all apps during live DB work

When you need to change the **live** database (run a migration, alter a schema,
rebuild demands, etc.), put every client into maintenance mode first so nobody
reads or writes mid-change. One flag file gates **all three apps** — desktop
(admin), mobile (parent), and the public website.

## How it works

- The flag is a **public file in Supabase Storage**, bucket `app-updates`, named
  **`maintenance.json`** — the same bucket as the auto-update `latest.json`.
- It is deliberately **not** in the database: altering/migrating DB tables never
  touches Storage, so the apps can still read the flag *while* you work on the DB.
- Every app checks it **on launch, every 90 seconds, and on resume**. When
  `maintenance` is `true` it shows a full-screen "Under Maintenance" screen and
  blocks the whole UI. Flip it back and the apps clear the screen automatically
  (within ~90s, no restart needed).
- **Fail-open:** if the file is missing (404), unreachable, or malformed, the
  apps behave normally. So the file only matters when you deliberately turn it on.

Code: `MaintenanceService` + `MaintenanceGate` in each repo
(desktop `lib/services` + `lib/widgets`, mobile `lib/core/services` +
`lib/presentation/widgets`, website `lib/`). All read the same URL:

```
https://ohbjbiwrjykdugbrimxe.supabase.co/storage/v1/object/public/app-updates/maintenance.json
```

## To START maintenance

Upload `maintenance.json` to the `app-updates` bucket (overwrite the existing
one). Only `maintenance` is required; the rest tailor the screen and are all
optional (an omitted field is simply not shown):

```json
{
  "maintenance": true,
  "title": "Server Maintenance",
  "message": "We are currently performing scheduled maintenance to improve system performance and reliability. The system will be back online shortly. Thank you for your patience and understanding.",
  "time": "22 Aug 2026\n06:00 PM – 07:00 PM (IST)",
  "duration": "1 hour",
  "notice": "During this time, the application may be unavailable or experience intermittent downtime."
}
```

Field notes:
- `title` — heading; defaults to **"Server Maintenance"** if omitted.
- `message` — the body paragraph; a sensible default is shown if omitted.
- `time` — value beside the **Maintenance Time** row (calendar icon). Use `\n`
  for a second line (e.g. date on line 1, time range on line 2).
- `duration` — value beside the **Expected Duration** row (clock icon).
- `notice` — text of the highlighted info banner at the bottom.
- The `time`/`duration` rows and the `notice` banner only appear when their
  field is present, so a bare `{"maintenance": true, "message": "..."}` still
  works and just shows the title + message.
- **Newlines must be written as `\n`** (JSON has no literal line breaks) — a raw
  line break makes the file invalid JSON, which fail-opens (no screen shows).

Within ~90s every open app shows the maintenance screen; new launches show it
immediately. Wait ~2 minutes for any in-flight fee collection to finish before
you start the DB change.

## To END maintenance

Re-upload `maintenance.json` with `"maintenance": false` (the default file in
`installer/dist/maintenance.json`), **or** delete the file from the bucket.
Apps resume within ~90s.

## Full runbook for a live DB change

1. Set `maintenance: true` (upload the file). Confirm the apps show the screen.
2. Wait ~2 min for active users to drain.
3. Back up: `pg_dump` / refresh `C:\pg_backups\complete_setup.sql` (see
   `db_setup_and_dump` memory).
4. Run the migration in Supabase; verify.
5. Set `maintenance: false` (or delete the file). Apps resume.

> Note: the flag blocks the **UI** of the apps. It does not, by itself, revoke
> database access — a determined direct API call could still reach the DB. For a
> hard cutoff during a risky migration you can additionally pause the Supabase
> project or revoke `anon` grants (see `security_hardening` memory), but for
> routine maintenance the flag + a short drain window is the practical choice.
