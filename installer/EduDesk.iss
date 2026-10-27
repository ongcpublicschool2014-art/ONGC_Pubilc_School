; Inno Setup script for EduDesk
; Builds: EduDesk-Setup-1.0.0.exe
;
; Prerequisites:
;   1. Install Inno Setup 6 from https://jrsoftware.org/isdl.php
;   2. Run a Release build first:  flutter build windows --release
;   3. Compile this script:        iscc EduDesk.iss
;      (or right-click → "Compile" in the Inno Setup IDE)

#define MyAppName       "EduDesk"
#define MyAppVersion    "1.0.0"
#define MyAppPublisher  "Krishnaswamy Institutions"
#define MyAppExeName    "school_admin.exe"
#define MyAppId         "{{A8F2D3E1-9B4C-4A7D-B5E8-1F2C3D4E5F6A}"

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
OutputDir=.\dist
OutputBaseFilename=EduDesk-Setup-{#MyAppVersion}
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

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userappdata}\Microsoft\Internet Explorer\Quick Launch\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: quicklaunchicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}"
