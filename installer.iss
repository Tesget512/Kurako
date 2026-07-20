; Inno Setup script for AnimeBDPlayer (动画仓库)
;
; Build the app first:  flutter build windows --release
; Then compile this script with Inno Setup 6 (ISCC.exe installer.iss), or open
; it in the Inno Setup IDE and hit Build. Output: dist/AnimeBDPlayer-Setup.exe
;
; The app stores its library + settings in Documents\AnimeBDPlayer, NOT in the
; install directory — so updating (reinstalling over the top) never touches user
; data, and uninstalling leaves the library intact.

#define AppName "动画仓库"
#define AppNameEn "AnimeBDPlayer"
#define AppVersion "1.0.0"
#define AppPublisher "com.animebd"
#define AppExeName "anime_bd_player.exe"
; Path to the flutter release bundle, relative to this script (project root).
#define ReleaseDir "build\windows\x64\runner\Release"

[Setup]
AppId={{9F4B2C7A-8E1D-4A3F-9B6E-ANIMEBDPLAYER}}
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
; Show the Chinese + English name in Add/Remove Programs.
UninstallDisplayName={#AppName} ({#AppNameEn})
UninstallDisplayIcon={app}\{#AppExeName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
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
