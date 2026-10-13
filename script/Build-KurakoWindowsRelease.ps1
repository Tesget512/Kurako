[CmdletBinding()]
param(
    [string]$Workspace,
    # When supplied, sync before building. Example: \\WINDOWS-PC\KURAKO-Git\KURAKO.git
    [string]$Repository,
    [string]$Branch = 'master',
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'

function Repair-CorruptMediaKitMpvArchive {
    param([string]$WorkspacePath)

    $cmakePath = Join-Path $WorkspacePath 'windows\flutter\ephemeral\.plugin_symlinks\media_kit_libs_windows_video\windows\CMakeLists.txt'
    if (-not (Test-Path -LiteralPath $cmakePath)) { return $false }

    $cmakeContent = Get-Content -LiteralPath $cmakePath -Raw
    $archiveMatch = [regex]::Match($cmakeContent, 'set\(LIBMPV\s+"([^"]+)"\)')
    $md5Match = [regex]::Match($cmakeContent, 'set\(LIBMPV_MD5\s+"([0-9a-fA-F]+)"\)')
    $urlMatch = [regex]::Match($cmakeContent, 'set\(LIBMPV_URL\s+"([^"]+)"\)')
    if (-not $archiveMatch.Success -or -not $md5Match.Success -or -not $urlMatch.Success) { return $false }

    $archivePath = Join-Path $WorkspacePath (Join-Path 'build\windows\x64' $archiveMatch.Groups[1].Value)
    if (-not (Test-Path -LiteralPath $archivePath)) { return $false }

    $actualMd5 = (Get-FileHash -LiteralPath $archivePath -Algorithm MD5).Hash.ToLowerInvariant()
    $expectedMd5 = $md5Match.Groups[1].Value.ToLowerInvariant()
    if ($actualMd5 -eq $expectedMd5) { return $false }

    Remove-Item -LiteralPath $archivePath -Force
    Write-Host "已删除校验失败的 media_kit mpv 下载缓存：$archivePath"

    $temporaryArchive = "$archivePath.download"
    if (Test-Path -LiteralPath $temporaryArchive) {
        Remove-Item -LiteralPath $temporaryArchive -Force
    }

    # The plugin already tried the official GitHub URL. This fallback is used
    # only after that download fails, and the upstream MD5 is verified below.
    $fallbackUrl = "https://gh-proxy.com/$($urlMatch.Groups[1].Value)"
    Write-Host '正在通过备用链路重新获取 media_kit mpv 依赖。'
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe --location --fail --silent --show-error --retry 2 --connect-timeout 15 --max-time 180 --output $temporaryArchive $fallbackUrl
        $downloadExitCode = $LASTEXITCODE
    } else {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $fallbackUrl -OutFile $temporaryArchive
            $downloadExitCode = 0
        } catch {
            Write-Warning "media_kit mpv 备用下载失败：$($_.Exception.Message)"
            $downloadExitCode = 1
        }
    }

    if ($downloadExitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryArchive)) {
        if (Test-Path -LiteralPath $temporaryArchive) {
            Remove-Item -LiteralPath $temporaryArchive -Force
        }
        return $false
    }

    $downloadedMd5 = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm MD5).Hash.ToLowerInvariant()
    if ($downloadedMd5 -ne $expectedMd5) {
        Remove-Item -LiteralPath $temporaryArchive -Force
        Write-Warning '备用链路返回的 media_kit mpv 文件校验失败，已拒绝使用。'
        return $false
    }

    Move-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force
    Write-Host 'media_kit mpv 依赖已重新下载并通过上游校验。'
    return $true
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw '未找到 Flutter。请先安装 Flutter stable，并确保 flutter doctor 的 Windows toolchain 为绿色。'
}
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    throw '未找到 rustup。请先安装 Rust 的 stable-x86_64-pc-windows-msvc 工具链。'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Workspace) {
    $Workspace = Split-Path -Parent $scriptDir
}
if ($Repository) {
    & (Join-Path $scriptDir 'Sync-KurakoWorkspace.ps1') -Repository $Repository -Workspace $Workspace -Branch $Branch
}

if (-not (Test-Path -LiteralPath (Join-Path $Workspace 'pubspec.yaml'))) {
    throw "不是 KURAKO 工作目录：$Workspace"
}

Push-Location $Workspace
$restorePubspecLock = $false
$buildMarker = $null
$currentCommit = $null
try {
    if (Test-Path -LiteralPath (Join-Path $Workspace '.git')) {
        Write-Host ''
        Write-Host '=== 检查 Git 工作区与更新 ==='
        Write-Host 'Mac 推送会直接更新此工作区；以下显示自上次成功构建以来的变化。'
        & git -C $Workspace status --short --branch
        if ($LASTEXITCODE -ne 0) { throw '无法读取 Git 工作区状态。' }

        $workspaceChanges = @(& git -C $Workspace status --porcelain)
        if ($LASTEXITCODE -ne 0) { throw '无法检查 Git 工作区改动。' }
        if ($workspaceChanges.Count -gt 0) {
            $workspaceChanges | ForEach-Object { Write-Host "  $_" }
            throw '工作区有未提交改动，已停止 Release 构建。'
        }

        $currentCommit = (& git -C $Workspace rev-parse HEAD).Trim()
        $gitDir = (& git -C $Workspace rev-parse --absolute-git-dir).Trim()
        if ($LASTEXITCODE -ne 0) { throw '无法读取当前 Git 提交。' }
        $buildMarker = Join-Path $gitDir 'kurako-last-build'
        $previousCommit = ''
        if (Test-Path -LiteralPath $buildMarker) {
            $previousCommit = (Get-Content -LiteralPath $buildMarker -Raw).Trim()
        }

        if ($previousCommit -and $previousCommit -eq $currentCommit) {
            Write-Host '当前提交与上次成功构建一致，没有新的 Git 变化。'
        } elseif ($previousCommit) {
            & git -C $Workspace merge-base --is-ancestor $previousCommit $currentCommit
            if ($LASTEXITCODE -eq 0) {
                Write-Host "新增提交：$previousCommit..$currentCommit"
                & git -C $Workspace log --oneline --no-decorate "$previousCommit..$currentCommit"
                Write-Host '变更文件：'
                & git -C $Workspace diff --name-status $previousCommit $currentCommit
            } else {
                Write-Host '上次构建记录不属于当前历史，显示当前提交：'
                & git -C $Workspace log -1 --oneline --no-decorate
                Write-Host '当前提交包含的文件（不是未提交改动）：'
                & git -C $Workspace show --name-status --format= $currentCommit
            }
        } else {
            Write-Host '首次使用新版构建入口，当前提交：'
            & git -C $Workspace log -1 --oneline --no-decorate
            Write-Host '当前提交包含的文件（不是未提交改动）：'
            & git -C $Workspace show --name-status --format= $currentCommit
        }

        $lockChanges = & git -C $Workspace status --porcelain -- pubspec.lock
        if ($LASTEXITCODE -eq 0 -and -not $lockChanges) {
            $restorePubspecLock = $true
        }
    }

    $versionLine = (Select-String -LiteralPath (Join-Path $Workspace 'pubspec.yaml') -Pattern '^version:\s*([^+\s]+)').Line
    $versionMatch = [regex]::Match($versionLine, '^version:\s*([^+\s]+)')
    if (-not $versionMatch.Success) {
        throw '无法从 pubspec.yaml 读取版本号。'
    }
    $appVersion = $versionMatch.Groups[1].Value

    # Embedded into the Dart AOT bundle and shown in Settings so each
    # distributable can be distinguished even when the semantic version stays unchanged.
    $buildTime = $env:KURAKO_BUILD_TIME
    if (-not $buildTime) {
        $buildTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'
    }
    $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    Write-Host ''
    Write-Host '=== 获取 Flutter 依赖 ==='
    Write-Host "PUB_HOSTED_URL=$env:PUB_HOSTED_URL"
    Write-Host "FLUTTER_STORAGE_BASE_URL=$env:FLUTTER_STORAGE_BASE_URL"

    $windowsBuildCache = Join-Path $Workspace 'build\windows'
    $flutterWrapperSource = Join-Path $Workspace 'windows\flutter\ephemeral\cpp_client_wrapper\core_implementations.cc'
    if ((Test-Path -LiteralPath $windowsBuildCache) -and -not (Test-Path -LiteralPath $flutterWrapperSource)) {
        Write-Host '检测到 Windows 构建缓存存在，但 Flutter C++ wrapper 缺失；正在执行一次 flutter clean。'
        & flutter clean
        if ($LASTEXITCODE -ne 0) { throw '清理失效的 Windows 构建缓存失败。' }
    }

    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败。' }

    [void](Repair-CorruptMediaKitMpvArchive -WorkspacePath $Workspace)
    & flutter build windows --release --no-pub "--dart-define=KURAKO_BUILD_TIME=$buildTime"
    $buildExitCode = $LASTEXITCODE
    if ($buildExitCode -ne 0 -and (Repair-CorruptMediaKitMpvArchive -WorkspacePath $Workspace)) {
        Write-Host 'media_kit mpv 下载缓存已损坏，正在自动重新下载并重试一次。'
        & flutter build windows --release --no-pub "--dart-define=KURAKO_BUILD_TIME=$buildTime"
        $buildExitCode = $LASTEXITCODE
    }
    if ($buildExitCode -ne 0) { throw 'Windows Release 构建失败。' }

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
        $installerBuildDir = Join-Path $Workspace 'build\installer'
        New-Item -ItemType Directory -Force -Path $installerBuildDir | Out-Null
        $licenseText = [System.IO.File]::ReadAllText(
            (Join-Path $Workspace 'LICENSE'),
            [System.Text.Encoding]::UTF8
        )
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        foreach ($installerInfo in @(
            @('installer\windows-info.zh-CN.txt', 'windows-info-license.zh-CN.txt'),
            @('installer\windows-info.en.txt', 'windows-info-license.en.txt')
        )) {
            $infoText = [System.IO.File]::ReadAllText(
                (Join-Path $Workspace $installerInfo[0]),
                [System.Text.Encoding]::UTF8
            )
            $combinedText = $infoText.TrimEnd() + "`r`n`r`n===== GNU GENERAL PUBLIC LICENSE VERSION 3 =====`r`n`r`n" + $licenseText
            [System.IO.File]::WriteAllText((Join-Path $installerBuildDir $installerInfo[1]), $combinedText, $utf8Bom)
        }

        $iscc = @(
            "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
            "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $iscc) { throw '未找到 Inno Setup 6 的 ISCC.exe。安装后重试，或使用 -SkipInstaller 仅生成便携版。' }
        & $iscc "/DAppVersion=$appVersion" (Join-Path $Workspace 'installer.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Inno Setup 打包失败。' }
        Write-Host "安装包已生成：$(Join-Path $outDir "Kurako-Setup-$appVersion.exe")"
    }

    if ($buildMarker -and $currentCommit) {
        Set-Content -LiteralPath $buildMarker -Value $currentCommit -Encoding Ascii -NoNewline
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
