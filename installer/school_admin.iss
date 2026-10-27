; Inno Setup script for School Admin — bundles the Flutter Windows release
; folder into a single installer .exe (school_admin_setup.exe).
; Compile with: "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\school_admin.iss

#define MyAppName "KCET"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "TBS Tech"
#define MyAppExeName "school_admin.exe"

[Setup]
; Unique application id — keep this stable across versions so upgrades replace
; the previous install instead of creating a duplicate.
AppId={{8F3A2C71-5B4D-4E9A-9C2F-1A7B6D3E0F45}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=output
OutputBaseFilename=kcet_setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
; Bundle the entire Flutter release output (exe + DLLs + data\).
; NEVER package a config.json. A leftover one in the build folder points the
; installed app at whatever project it names -- a TEST config shipped to
; customers would send live fee collection, and its Paytm routing, at the
; wrong database. config.example.json is the deliberate opt-in instead.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "config.json"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
