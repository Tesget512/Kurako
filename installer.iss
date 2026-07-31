; Inno Setup script for Kurako
;
; Build the app first:  flutter build windows --release
; Then compile this script with Inno Setup 6 (ISCC.exe installer.iss), or open
; it in the Inno Setup IDE and hit Build. Output: dist/Kurako-Setup.exe
;
; The app stores its library + settings in Documents\KURAKO, NOT in the
; install directory — so updating (reinstalling over the top) never touches user
; data, and uninstalling leaves the library intact.

#define AppName "Kurako"
#define AppNameEn "Kurako"
#define AppVersion "1.0.0"
#define AppPublisher "Tesget512"
#define AppExeName "kurako.exe"
; Path to the flutter release bundle, relative to this script (project root).
#define ReleaseDir "build\windows\x64\runner\Release"

[Setup]
AppId={{17E6CBB0-5F44-446A-B193-51100DE2F0EB}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppComments=支持本地文件夹、SMB 与 WebDAV 的跨平台番剧库与视频播放器
AppCopyright=Copyright (C) 2026 Tesget512 and Kurako contributors
DefaultDirName={autopf}\{#AppNameEn}
DefaultGroupName={#AppName}
DisableDirPage=no
DisableProgramGroupPage=yes
OutputDir=dist\out
OutputBaseFilename={#AppNameEn}-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Name shown in Add/Remove Programs.
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
SetupIconFile=windows\runner\resources\app_icon.ico
VersionInfoDescription=Kurako Windows 安装程序
VersionInfoCompany={#AppPublisher}
VersionInfoProductName={#AppName}
VersionInfoCopyright=Copyright (C) 2026 Tesget512 and Kurako contributors

[Languages]
Name: "cn"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"; LicenseFile: "LICENSE"; InfoBeforeFile: "installer\windows-info.zh-CN.txt"; InfoAfterFile: "installer\ACKNOWLEDGEMENTS.zh-CN.txt"
Name: "english"; MessagesFile: "compiler:Default.isl"; LicenseFile: "LICENSE"; InfoBeforeFile: "installer\windows-info.en.txt"; InfoAfterFile: "installer\ACKNOWLEDGEMENTS.en.txt"

[Messages]
cn.WelcomeLabel1=欢迎安装 [name]
cn.WelcomeLabel2=Kurako 是一款由 Flutter 与 Rust 构建的本地番剧库和视频播放器。%n%n安装向导将说明功能、数据位置与开源许可，并允许选择安装目录和快捷方式。
english.WelcomeLabel1=Welcome to [name] Setup
english.WelcomeLabel2=Kurako is a local anime library and video player built with Flutter and Rust.%n%nThis wizard explains its features, data locations, and open-source license, and lets you choose the installation folder and shortcuts.

[CustomMessages]
cn.ShortcutTasks=快捷方式：
cn.CreateStartMenuIcon=创建开始菜单快捷方式
english.ShortcutTasks=Shortcuts:
english.CreateStartMenuIcon=Create a Start Menu shortcut

[Tasks]
Name: "startmenuicon"; Description: "{cm:CreateStartMenuIcon}"; GroupDescription: "{cm:ShortcutTasks}"; Flags: unchecked
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:ShortcutTasks}"; Flags: unchecked

[Files]
; Package the entire release bundle (exe + DLLs + data/ + flutter_assets).
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "installer\windows-info.zh-CN.txt"; DestDir: "{app}\docs"; DestName: "安装说明.txt"; Flags: ignoreversion
Source: "installer\windows-info.en.txt"; DestDir: "{app}\docs"; DestName: "Installation.txt"; Flags: ignoreversion
Source: "THIRD_PARTY_NOTICES.txt"; DestDir: "{app}\docs"; Flags: ignoreversion
#if FileExists("LICENSE")
Source: "LICENSE"; DestDir: "{app}\docs"; Flags: ignoreversion
#endif

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: startmenuicon
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"; Tasks: startmenuicon
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\kurako"; ValueType: string; ValueName: ""; ValueData: "URL:Kurako OAuth Callback"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\kurako"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\kurako\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\docs\安装说明.txt"; Description: "查看安装说明"; Flags: postinstall shellexec skipifsilent unchecked; Languages: cn
Filename: "{app}\docs\Installation.txt"; Description: "View installation notes"; Flags: postinstall shellexec skipifsilent unchecked; Languages: english
