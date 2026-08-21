# Releasing a new EduCore360 version (with auto-update)

Installed apps check for updates on launch. On the dashboard they call
`maybePromptUpdate()` → `UpdateService.checkForUpdate()`, which fetches
`latest.json` from the **public `app-updates` Supabase Storage bucket** and
compares its `version` to the running app's `pubspec.yaml` version
(via `package_info_plus`). If newer, the user sees an **Update available** prompt
that downloads the new installer and runs it (the app closes, Inno installs, the
app reopens).

Because the check is name/version driven, releasing is just: **build a new
installer → upload it + a new `latest.json`.**

## One-time setup
1. Run `migrations/add_app_updates_bucket.sql` in Supabase (creates the public
   `app-updates` bucket).
2. Ship the current build to users once (the normal installer) so they're on a
   version that contains the updater. From then on, updates are automatic.

## Every release
1. **Bump the version** in `pubspec.yaml`:
   ```yaml
   version: 1.1.0+2      # major.minor.patch (+build). The updater compares the
                         # major.minor.patch part only.
   ```
2. **Build + package** (from the project root):
   ```powershell
   flutter build windows --release
   iscc installer\EduCore360.iss        # -> dist\EduCore360-Setup-<ver>.exe
   ```
   (Name the output `EduCore360-Setup-1.1.0.exe` — bump the version in the
   `.iss` `AppVersion` / `OutputBaseFilename` so the filename carries the version.)
3. **Upload to the `app-updates` bucket** (Supabase dashboard → Storage →
   `app-updates`, or the CLI):
   - the installer, e.g. `EduCore360-Setup-1.1.0.exe`
   - an updated **`latest.json`** (see below)
4. Done. Every running app shows the prompt on its next launch.

## `latest.json` (upload this to the bucket root)
```json
{
  "version": "1.1.0",
  "url": "https://ohbjbiwrjykdugbrimxe.supabase.co/storage/v1/object/public/app-updates/EduCore360-Setup-1.1.0.exe",
  "notes": "What changed in this release (shown in the prompt).",
  "mandatory": false
}
```
- **`version`** — must match the new `pubspec.yaml` major.minor.patch.
- **`url`** — public URL of the installer you just uploaded.
- **`notes`** — free text shown in the update dialog.
- **`mandatory`** — `true` blocks the app until the user updates (use only for
  money/schema-breaking releases); `false` shows a dismissible "Later" button.

## Notes & safety
- The check **never blocks the app**: offline / bad manifest / bad JSON all fall
  through silently (the app just runs the current version).
- The updater only *downloads and launches* the installer — it does not bypass
  it, so Windows still shows the normal Inno install (closes/reopens the app).
- `mandatory:true` is the only thing that forces the update; keep it `false`
  for routine releases so a cashier is never blocked mid-day.
- Rolling back = upload a `latest.json` pointing at the older installer with a
  lower `version` won't re-trigger (it only updates *forward*); to force users
  back, ship a higher version number of the older build.
