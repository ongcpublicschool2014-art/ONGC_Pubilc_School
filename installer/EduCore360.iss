; Inno Setup script for EduCore360
; Output: dist\EduCore360-Setup-<version>.exe
;
; Prerequisites:
;   1. Install Inno Setup 6 from https://jrsoftware.org/isdl.php
;   2. Run a Release build first:  flutter build windows --release
;   3. Compile this script:        iscc EduCore360.iss
;      (or open in the Inno Setup IDE and press F9)

#define MyAppName       "EduCore360"
#define MyAppVersion    "1.0.0"
#define MyAppPublisher  "TBS Technologies Private Limited"
#define MyAppExeName    "school_admin.exe"
; UUID for this product line — bumping it makes Windows treat upgrades as
; fresh installs (don't change unless you intentionally want that).
#define MyAppId         "{{B0F1A2C3-D4E5-4F67-8A9B-EDU-CORE-360}"

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
OutputBaseFilename=ONGC-Setup-{#MyAppVersion}
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
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

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
