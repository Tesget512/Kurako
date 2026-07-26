[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $env:USERPROFILE 'source\KURAKO'),
    # When supplied, sync before building. Example: \\WINDOWS-PC\KURAKO-Git\KURAKO.git
    [string]$Repository,
    [string]$Branch = 'master',
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw '未找到 Flutter。请先安装 Flutter stable，并确保 flutter doctor 的 Windows toolchain 为绿色。'
}
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    throw '未找到 rustup。请先安装 Rust 的 stable-x86_64-pc-windows-msvc 工具链。'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Repository) {
    & (Join-Path $scriptDir 'Sync-KurakoWorkspace.ps1') -Repository $Repository -Workspace $Workspace -Branch $Branch
}

if (-not (Test-Path -LiteralPath (Join-Path $Workspace 'pubspec.yaml'))) {
    throw "不是 KURAKO 工作目录：$Workspace"
}

Push-Location $Workspace
try {
    # Embedded into the Dart AOT bundle and shown in Settings, so each
    # distributable can be distinguished even while the semantic version stays
    # at 1.0.0 during active development.
    $buildTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败。' }
    & flutter build windows --release "--dart-define=KURAKO_BUILD_TIME=$buildTime"
    if ($LASTEXITCODE -ne 0) { throw 'Windows Release 构建失败。' }

    $bundle = Join-Path $Workspace 'build\windows\x64\runner\Release\kurako.exe'
    if (-not (Test-Path -LiteralPath $bundle)) { throw "找不到 Release 程序：$bundle" }
    Write-Host "Windows Release 已生成：$bundle"

    if (-not $SkipInstaller) {
        $iscc = @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $iscc) { throw '未找到 Inno Setup 6 的 ISCC.exe。安装后重试，或使用 -SkipInstaller 仅生成便携版。' }
        & $iscc (Join-Path $Workspace 'installer.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Inno Setup 打包失败。' }
        Write-Host "安装包已生成：$(Join-Path $Workspace 'dist\Kurako-Setup-1.0.0.exe')"
    }
} finally {
    Pop-Location
}
