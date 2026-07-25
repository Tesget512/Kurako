[CmdletBinding()]
param(
    # The bare repository stores Git objects only; do not use it as the build folder.
    [string]$BareRepository = 'D:\KURAKO-Git\KURAKO.git',
    # Optional SMB share name for the directory that contains the bare repository.
    [string]$ShareName = 'KURAKO-Git',
    [switch]$CreateShare
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw '未找到 Git。请先安装 Git for Windows，并重新打开 PowerShell。'
}

if (Test-Path -LiteralPath $BareRepository) {
    if (-not (Test-Path -LiteralPath (Join-Path $BareRepository 'HEAD'))) {
        throw "目标已存在但不是裸 Git 仓库：$BareRepository"
    }
    Write-Host "复用已有裸仓库：$BareRepository"
} else {
    $parent = Split-Path -Parent $BareRepository
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    & git init --bare $BareRepository
    if ($LASTEXITCODE -ne 0) { throw '创建裸 Git 仓库失败。' }
    & git -C $BareRepository config receive.denyNonFastForwards true
    Write-Host "已创建裸仓库：$BareRepository"
}

if ($CreateShare) {
    $parent = Split-Path -Parent $BareRepository
    $existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        # Creating SMB shares requires an elevated PowerShell window. Grant the
        # current Windows account access; add other accounts in Computer
        # Management if they also need to push from another machine.
        New-SmbShare -Name $ShareName -Path $parent -FullAccess "$env:USERDOMAIN\$env:USERNAME" | Out-Null
        Write-Host "已创建 SMB 共享：\\$env:COMPUTERNAME\$ShareName"
    } elseif ($existing.Path -ne $parent) {
        throw "共享名 $ShareName 已指向 $($existing.Path)，不是 $parent。"
    } else {
        Write-Host "复用已有 SMB 共享：\\$env:COMPUTERNAME\$ShareName"
    }
}

Write-Host ''
Write-Host 'Mac 端 Git 远端路径：'
Write-Host "  \\$env:COMPUTERNAME\$ShareName\$(Split-Path -Leaf $BareRepository)"
Write-Host '将上述 UNC 路径提供给 Mac，即可直接 push。'
