[CmdletBinding()]
param(
    # Example: \\WINDOWS-PC\KURAKO-Git\KURAKO.git
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [string]$Workspace = (Join-Path $env:USERPROFILE 'source\KURAKO'),
    [string]$Branch = 'master'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw '未找到 Git。请先安装 Git for Windows，并重新打开 PowerShell。'
}

if (-not (Test-Path -LiteralPath (Join-Path $Workspace '.git'))) {
    $parent = Split-Path -Parent $Workspace
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    & git clone --branch $Branch $Repository $Workspace
    if ($LASTEXITCODE -ne 0) { throw '首次克隆失败。请确认 SMB 共享可访问、路径正确且 Windows 账户拥有读写权限。' }
    Write-Host "已克隆到：$Workspace"
    return
}

$changes = & git -C $Workspace status --porcelain
if ($LASTEXITCODE -ne 0) { throw "无法读取工作目录：$Workspace" }
if ($changes) {
    throw "工作目录有未提交改动，已停止同步以避免覆盖：$Workspace"
}

& git -C $Workspace fetch origin
if ($LASTEXITCODE -ne 0) { throw '获取远端更新失败。' }
& git -C $Workspace checkout $Branch
if ($LASTEXITCODE -ne 0) { throw "无法切换到分支：$Branch" }
& git -C $Workspace pull --ff-only origin $Branch
if ($LASTEXITCODE -ne 0) { throw '无法快进更新；请先检查本地分支状态。' }

Write-Host "已同步：$Workspace"
