; Inno Setup script for EduCore360
; Output: dist\EduCore360-Setup-<version>.exe
;
; Prerequisites:
;   1. Install Inno Setup 6 from https://jrsoftware.org/isdl.php
;   2. Run a Release build first:  flutter build windows --release
;   3. Compile this script:        iscc EduCore360.iss
;      (or open in the Inno Setup IDE and press F9)

; FIT School is its own product, separate from the college app (EduCore360):
; its own AppId (Windows keeps the two installs, uninstalls and upgrades
; apart), install folder, data folder ("FIT School", Runner.rc ProductName)
; and update manifest (app-updates/latest-windows.json on the school's
; Supabase project). Until 2026-11-06 it reused the college AppId and data
; folder, so a setup of either app upgraded the other's install and the two
; shared one config.json and activation.
#define MyAppName       "FIT School"
#define MyFilePrefix    "FITSchool"
#define MyAppVersion    "0.0.0"
#define MyAppPublisher  "TBS Technologies Private Limited"
#define MyAppExeName    "school_admin.exe"
; UUID for FIT School. Never reuse the college app's
; {B0F1A2C3-D4E5-4F67-8A9B-EDU-CORE-360}, and keep this one from now on:
; changing it makes Windows treat the next setup as a different app.
#define MyAppId         "{{875025D7-2E5A-4654-ADE0-25ABB7446C4A}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
OutputDir=.\dist
OutputBaseFilename={#MyFilePrefix}-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\windows\runner\resources\app_icon.ico
DisableProgramGroupPage=yes
DisableDirPage=no
ShowLanguageDialog=no
MinVersion=10.0.17763
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"
Name: "quicklaunchicon"; Description: "Create a &Quick Launch shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
; Copy the entire Release folder
; NEVER package a config.json. A leftover one in the build folder points the
; installed app at whatever project it names -- a TEST config shipped to
; customers would send live fee collection, and its Paytm routing, at the
; wrong database. config.example.json is the deliberate opt-in instead.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "config.json"
; Bundle the config.json template (rename to config.json to point at another
; Supabase project). Never overwrites a real config.json — different filename.
Source: "config.example.json"; DestDir: "{app}"; Flags: ignoreversion
; No config.json is shipped: the school's live project is the app's
; compiled-in default (lib/config/supabase_config.dart). No [InstallDelete] of
; EduCore360 shortcuts either -- on a PC with both apps those are the college
; app's.

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userappdata}\Microsoft\Internet Explorer\Quick Launch\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: quicklaunchicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Program folder
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}"
; Per-user state — flutter_secure_storage.dat + shared_preferences.json.
; The path comes from the Windows runner's CompanyName + ProductName
; (see windows/runner/Runner.rc). Wiping this folder forces the next
; install to ask for a fresh device activation code.
Type: filesandordirs; Name: "{userappdata}\com.edudesk\EduCore 360"
Type: dirifempty;    Name: "{userappdata}\com.edudesk"

[UninstallRun]
; Remove the Windows Credential Manager entry that holds the AES key
; for flutter_secure_storage.dat. Harmless if it doesn't exist.
Filename: "cmdkey.exe"; Parameters: "/delete:key_school_admin_VGhpcyBpcyB0aGUgcHJlZml4IGZv_"; Flags: runhidden; RunOnceId: "DelSecureStorageCred"
