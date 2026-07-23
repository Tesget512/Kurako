; Inno Setup script for KURAKO
;
; Build the app first:  flutter build windows --release
; Then compile this script with Inno Setup 6 (ISCC.exe installer.iss), or open
; it in the Inno Setup IDE and hit Build. Output: dist/KURAKO-Setup.exe
;
; The app stores its library + settings in Documents\KURAKO, NOT in the
; install directory — so updating (reinstalling over the top) never touches user
; data, and uninstalling leaves the library intact.

#define AppName "KURAKO"
#define AppNameEn "KURAKO"
#define AppVersion "1.0.0"
#define AppPublisher "com.alts"
#define AppExeName "kurako.exe"
; Path to the flutter release bundle, relative to this script (project root).
#define ReleaseDir "build\windows\x64\runner\Release"

[Setup]
AppId={{17E6CBB0-5F44-446A-B193-51100DE2F0EB}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppNameEn}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename={#AppNameEn}-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Name shown in Add/Remove Programs.
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}

[Languages]
Name: "cn"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Package the entire release bundle (exe + DLLs + data/ + flutter_assets).
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
