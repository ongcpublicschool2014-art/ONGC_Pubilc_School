# EduDesk Installer

This folder contains the Inno Setup script that packages the Flutter Windows
Release build into a single-file Windows installer (`EduDesk-Setup-X.Y.Z.exe`).

## One-time setup

1. Download **Inno Setup 6** (free): https://jrsoftware.org/isdl.php
2. Install the "unicode" edition (default).
3. Confirm `iscc.exe` is available — usually at
   `C:\Program Files (x86)\Inno Setup 6\iscc.exe`.

## Build the installer

From this folder, in a terminal:

```bash
# 1. Build the Flutter release first (only needed when the app code changes)
cd ..
flutter build windows --release

# 2. Compile the installer
cd installer
"C:\Program Files (x86)\Inno Setup 6\iscc.exe" EduDesk.iss
```

Or just double-click `EduDesk.iss` to open it in the Inno Setup IDE, then hit
**Build → Compile** (F9).

The output goes to `installer\dist\EduDesk-Setup-1.0.0.exe`.

## What the installer does

- Installs to `C:\Program Files\EduDesk` (admin-elevated)
- Creates a Start Menu entry
- Optionally creates a Desktop shortcut (user ticks a checkbox)
- Offers to launch the app after installation
- Registers a clean uninstaller under *Settings → Apps*

## Updating the version

Edit the top of `EduDesk.iss`:

```
#define MyAppVersion    "1.0.1"
```

Then rebuild and recompile.

## FIT School (school app) — its own product

FIT School is built from this repo with `EduCore360.iss` and is **separate from
the college app (EduCore360)** since 2026-11-06:

| | FIT School | College (EduCore360) |
|---|---|---|
| Installer AppId | `{875025D7-2E5A-4654-ADE0-25ABB7446C4A}` | `{B0F1A2C3-D4E5-4F67-8A9B-EDU-CORE-360}` |
| Install folder | `C:\Program Files\FIT School` | its own |
| Data folder (activation, sign-in, settings) | `%APPDATA%\com.edudesk\FIT School` | `...\EduCore 360` |
| Optional config.json | next to the exe, else `%APPDATA%\FITSchool\config.json` | `%APPDATA%\EduCore360\config.json` |
| Live server (compiled in) | `xjdvrrcmvyjocxynmhql` | college project |
| Update manifest | `app-updates/latest-windows.json` on the project the app is connected to (each school's own) | `app-updates/latest.json` on the college project |

Releasing a FIT School update never reaches the college app, and the other
way round.

### Publishing a FIT School update

1. Raise `version:` in `pubspec.yaml` and `MyAppVersion` in `EduCore360.iss`
   (the same number, e.g. `0.0.2`).
2. `flutter build windows --release`, then compile `EduCore360.iss` →
   `dist\FITSchool-Setup-0.0.2.exe`.
3. **Per school.** One source, one Supabase project per school: each app
   checks the project it is connected to (compiled default or config.json).
   For every school that should get the update, in THAT school's project →
   Storage → bucket `app-updates` (public; create it once per project):
   upload `FITSchool-Setup-0.0.2.exe`, then upload `latest-windows.json`
   (template in this folder) with that version and the exe's URL **on the
   same project**. That school's apps offer the update on their next start.
   The update is offered only when the URL is an `.exe` on that same project
   and the file is really there; a school you did not upload to stays on its
   version (so does the test project).

`maintenance.json` in the same bucket (`{"maintenance": true, "message": "..."}`)
puts that school's FIT School and parent app into maintenance (only that
school); set it to `false` or delete it to end.

### Moving a PC to the separate install (one time)

The earlier FIT School setups shared the college AppId, so on a PC that had
both, one install could have overwritten the other. On such a PC: uninstall
"FIT School" / "EduCore360" from Settings → Apps, install the new
FIT School setup, reinstall the college setup if it was there, and activate
FIT School once (it now keeps its own activation).
