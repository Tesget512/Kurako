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
$restorePubspecLock = $false
try {
    if (Test-Path -LiteralPath (Join-Path $Workspace '.git')) {
        $lockChanges = & git -C $Workspace status --porcelain -- pubspec.lock
        if ($LASTEXITCODE -eq 0 -and -not $lockChanges) {
            $restorePubspecLock = $true
        }
    }

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

    $releaseDir = Split-Path -Parent $bundle
    $docsDir = Join-Path $releaseDir 'docs'
    New-Item -ItemType Directory -Force -Path $docsDir | Out-Null
    Copy-Item (Join-Path $Workspace 'installer\windows-info.zh-CN.txt') (Join-Path $docsDir '安装说明.txt') -Force
    Copy-Item (Join-Path $Workspace 'installer\windows-info.en.txt') (Join-Path $docsDir 'Installation.txt') -Force
    Copy-Item (Join-Path $Workspace 'THIRD_PARTY_NOTICES.txt') $docsDir -Force
    Copy-Item (Join-Path $Workspace 'assets\fonts\OFL.txt') (Join-Path $docsDir 'LXGW-WenKai-OFL-1.1.txt') -Force
    $license = Join-Path $Workspace 'LICENSE'
    if (Test-Path -LiteralPath $license) {
        Copy-Item $license $docsDir -Force
    }

    $outDir = Join-Path $Workspace 'dist\out'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $portableZip = Join-Path $outDir 'Kurako-Windows-x64-release.zip'
    Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $portableZip -Force
    Write-Host "Windows 便携版已生成：$portableZip"

    if (-not $SkipInstaller) {
        $iscc = @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $iscc) { throw '未找到 Inno Setup 6 的 ISCC.exe。安装后重试，或使用 -SkipInstaller 仅生成便携版。' }
        & $iscc (Join-Path $Workspace 'installer.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Inno Setup 打包失败。' }
        Write-Host "安装包已生成：$(Join-Path $outDir 'Kurako-Setup-1.0.0.exe')"
    }
} finally {
    if ($restorePubspecLock) {
        & git -C $Workspace restore --source=HEAD --worktree -- pubspec.lock
        if ($LASTEXITCODE -ne 0) {
            Write-Warning '无法自动恢复 pubspec.lock；下次同步前请检查该文件。'
        }
    }
    Pop-Location
}
