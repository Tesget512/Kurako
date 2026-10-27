; Inno Setup script for Kurako
;
; Build the app first:  flutter build windows --release
; Then compile this script with Inno Setup 6 (ISCC.exe installer.iss), or open
; it in the Inno Setup IDE and hit Build. Output: dist/Kurako-Setup.exe
;
; The app stores its library + settings in Documents\Kurako, NOT in the
; install directory — so updating (reinstalling over the top) never touches user
; data, and uninstalling leaves the library intact.

#define AppName "Kurako"
#define AppNameEn "Kurako"
#ifndef AppVersion
#define AppVersion "1.2.0"
#endif
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
DefaultDirName={autopf}\Kurako
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
VersionInfoVersion=1.2.0.6
VersionInfoTextVersion={#AppVersion}

[Languages]
Name: "cn"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"; InfoBeforeFile: "build\installer\windows-info-license.zh-CN.txt"
Name: "english"; MessagesFile: "compiler:Default.isl"; InfoBeforeFile: "build\installer\windows-info-license.en.txt"

[Messages]
cn.WelcomeLabel1=欢迎安装 [name]
cn.WelcomeLabel2=Kurako 是一款由 Flutter 与 Rust 构建的本地番剧库和视频播放器。%n%n安装向导将说明功能、数据位置与开源许可，并允许选择安装目录和快捷方式。
cn.InfoBeforeLabel=安装说明与 GPL-3.0 许可证
cn.ReadyLabel2a=准备好继续安装后，请点击“下一步”。
english.WelcomeLabel1=Welcome to [name] Setup
english.WelcomeLabel2=Kurako is a local anime library and video player built with Flutter and Rust.%n%nThis wizard explains its features, data locations, and open-source license, and lets you choose the installation folder and shortcuts.
english.InfoBeforeLabel=Installation Notes and GPL-3.0 License
english.ReadyLabel2a=When you are ready to continue, click Next.

[CustomMessages]
cn.ShortcutTasks=快捷方式：
cn.CreateStartMenuIcon=创建开始菜单快捷方式
english.ShortcutTasks=Shortcuts:
english.CreateStartMenuIcon=Create a Start Menu shortcut
cn.ExistingInstallTitle=已检测到 Kurako
cn.ExistingInstallDescription=选择安装方式
cn.ExistingInstallSubCaption=当前已安装 Kurako %1。两种方式都会保留媒体库、账号设置与下载内容。
cn.UpdateInstall=更新或重新安装 Kurako
cn.RepairInstall=修复当前安装（重新写入程序文件）
english.ExistingInstallTitle=Kurako is already installed
english.ExistingInstallDescription=Choose an installation mode
english.ExistingInstallSubCaption=Kurako %1 is installed. Both options preserve the media library, account settings, and downloads.
english.UpdateInstall=Update or reinstall Kurako
english.RepairInstall=Repair the current installation (rewrite program files)

[Tasks]
Name: "startmenuicon"; Description: "{cm:CreateStartMenuIcon}"; GroupDescription: "{cm:ShortcutTasks}"; Flags: unchecked
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:ShortcutTasks}"; Flags: unchecked

[Files]
; Package the entire release bundle (exe + DLLs + data/ + flutter_assets).
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "installer\windows-info.zh-CN.txt"; DestDir: "{app}\docs"; DestName: "安装说明.txt"; Flags: ignoreversion
Source: "installer\windows-info.en.txt"; DestDir: "{app}\docs"; DestName: "Installation.txt"; Flags: ignoreversion
Source: "THIRD_PARTY_NOTICES.txt"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "assets\fonts\OFL.txt"; DestDir: "{app}\docs"; DestName: "LXGW-WenKai-OFL-1.1.txt"; Flags: ignoreversion
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

[Code]
const
  KurakoUninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{17E6CBB0-5F44-446A-B193-51100DE2F0EB}_is1';

var
  ExistingInstallPage: TInputOptionWizardPage;
  ExistingInstallDir: String;
  ExistingInstallVersion: String;
  WizardRaised: Boolean;

const
  HWND_TOPMOST = -1;
  HWND_NOTOPMOST = -2;
  SWP_NOSIZE = $0001;
  SWP_NOMOVE = $0002;
  SWP_SHOWWINDOW = $0040;

function SetWindowPos(hWnd: HWND; hWndInsertAfter: HWND; X, Y, cx, cy: Integer;
  uFlags: UINT): BOOL; external 'SetWindowPos@user32.dll stdcall';
function SetForegroundWindow(hWnd: HWND): BOOL;
  external 'SetForegroundWindow@user32.dll stdcall';

{ After the UAC elevation prompt the elevated wizard often opens behind the
  window that launched it. Raise it once: a brief topmost toggle changes the
  Z-order even when Windows refuses the foreground request. }
procedure RaiseWizardOnce;
begin
  if WizardRaised or WizardSilent then
    Exit;
  WizardRaised := True;
  SetWindowPos(WizardForm.Handle, HWND_TOPMOST, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_SHOWWINDOW);
  SetWindowPos(WizardForm.Handle, HWND_NOTOPMOST, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_SHOWWINDOW);
  SetForegroundWindow(WizardForm.Handle);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  RaiseWizardOnce;
end;

function FindExistingInstall(): Boolean;
begin
  Result := RegQueryStringValue(HKLM, KurakoUninstallKey, 'DisplayVersion', ExistingInstallVersion);
  if Result then
    RegQueryStringValue(HKLM, KurakoUninstallKey, 'InstallLocation', ExistingInstallDir)
  else
  begin
    Result := RegQueryStringValue(HKCU, KurakoUninstallKey, 'DisplayVersion', ExistingInstallVersion);
    if Result then
      RegQueryStringValue(HKCU, KurakoUninstallKey, 'InstallLocation', ExistingInstallDir);
  end;
end;

procedure InitializeWizard;
begin
  if FindExistingInstall() then
  begin
    if ExistingInstallDir <> '' then
      WizardForm.DirEdit.Text := ExistingInstallDir;
    ExistingInstallPage := CreateInputOptionPage(
      wpWelcome,
      ExpandConstant('{cm:ExistingInstallTitle}'),
      ExpandConstant('{cm:ExistingInstallDescription}'),
      FmtMessage(ExpandConstant('{cm:ExistingInstallSubCaption}'), [ExistingInstallVersion]),
      True,
      False);
    ExistingInstallPage.Add(ExpandConstant('{cm:UpdateInstall}'));
    ExistingInstallPage.Add(ExpandConstant('{cm:RepairInstall}'));
    ExistingInstallPage.SelectedValueIndex := 0;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  if (ExistingInstallPage <> nil) and
     (CurPageID = ExistingInstallPage.ID) and
     (ExistingInstallPage.SelectedValueIndex = 1) and
     (ExistingInstallDir <> '') then
    WizardForm.DirEdit.Text := ExistingInstallDir;
  Result := True;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (ExistingInstallPage <> nil) and
    (ExistingInstallPage.SelectedValueIndex = 1) and
    (PageID = wpSelectDir);
end;
