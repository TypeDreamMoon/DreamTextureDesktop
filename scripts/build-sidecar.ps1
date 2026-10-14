#!/usr/bin/env pwsh
<#
.SYNOPSIS
  构建桌面版的 sidecar：本仓库的界面 + backend/ 子模块的 Go 后端，编成一个 exe。

.DESCRIPTION
  1. 构建 web/（pnpm install --frozen-lockfile；pnpm build，含 vue-tsc 类型检查）→ web/dist
  2. 把 web/dist 拷进 backend/internal/web/dist（先清空），那是后端 go:embed 的目标
  3. go build backend/cmd/dreamtexture
     → src-tauri/binaries/dreamtexture-<rust 目标三元组>.exe（Tauri externalBin 的命名约定）
  4. 无论成败，把 backend/internal/web/dist 还原成子模块提交的状态——
     子模块在这里只是"借来编译"，不该因为一次构建就变脏

  后端自己提交的 internal/web/dist 是 tools/sync-web-ui.ps1 同步过去的一份界面构建，
  用来让后端仓库独立 go build；这里编进 sidecar 的则是本仓库当前源码重建的那份，
  两者可能不同，安装包里以这里的为准。

  需要 pwsh 7、pnpm、Go、Rust（只取 rustc -vV 的 host 三元组）。

.PARAMETER Version
  写进后端的版本号（-ldflags -X main.version=）。默认取 src-tauri/tauri.conf.json 的 version。

.PARAMETER SkipWebBuild
  不重建前端，直接用现成的 web/dist（调后端时省时间）。
#>
[CmdletBinding()]
param(
  [string]$Version,
  [switch]$SkipWebBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$web = Join-Path $root 'web'
$backend = Join-Path $root 'backend'
$embedRel = 'internal/web/dist'
$embedDir = Join-Path $backend 'internal/web/dist'
$binDir = Join-Path $root 'src-tauri/binaries'

function Invoke-Native {
  # 原生命令不会因为非零退出码而抛异常，统一在这里检查。
  param([Parameter(Mandatory)][string]$What, [Parameter(Mandatory)][scriptblock]$Run)
  & $Run
  if ($LASTEXITCODE -ne 0) { throw "$What 失败（退出码 $LASTEXITCODE）" }
}

# --- 前置检查 ---------------------------------------------------------------

if (-not (Test-Path (Join-Path $backend 'cmd/dreamtexture'))) {
  throw "backend/ 子模块还没检出。先运行：git submodule update --init"
}

# 还原步骤会 checkout + clean 这个目录；里面有未提交改动的话会被一并抹掉，先拦住。
$dirty = git -C $backend status --porcelain -- $embedRel
if ($LASTEXITCODE -ne 0) { throw '读取 backend/ 的 git 状态失败' }
if ($dirty) {
  throw "backend/$embedRel 有未提交的改动，构建结束时的还原会把它们抹掉。先处理掉：`n$dirty"
}

if (-not $Version) {
  $Version = (Get-Content (Join-Path $root 'src-tauri/tauri.conf.json') -Raw | ConvertFrom-Json).version
}

$triple = (rustc -vV | Where-Object { $_ -like 'host: *' }) -replace '^host:\s*', ''
if (-not $triple) { throw '从 rustc -vV 里读不到 host 目标三元组' }

Write-Host "版本 $Version，目标 $triple"

# --- 构建 -------------------------------------------------------------------

try {
  if ($SkipWebBuild) {
    if (-not (Test-Path (Join-Path $web 'dist/index.html'))) {
      throw '用了 -SkipWebBuild，但 web/dist 不存在'
    }
    Write-Host '== 跳过前端构建，使用现成的 web/dist'
  }
  else {
    Write-Host '== 构建前端'
    Invoke-Native 'pnpm install (web)' { pnpm -C $web install --frozen-lockfile }
    Invoke-Native 'pnpm build (web)' { pnpm -C $web build }
  }

  Write-Host '== 把界面放进后端的 embed 目录'
  if (Test-Path $embedDir) {
    Get-ChildItem -LiteralPath $embedDir -Force | Remove-Item -Recurse -Force
  }
  else {
    New-Item -ItemType Directory -Path $embedDir | Out-Null
  }
  Copy-Item -Path (Join-Path $web 'dist/*') -Destination $embedDir -Recurse -Force

  Write-Host '== 编译后端'
  New-Item -ItemType Directory -Path $binDir -Force | Out-Null
  $out = Join-Path $binDir "dreamtexture-$triple.exe"
  Push-Location $backend
  try {
    # 后端用 modernc 的纯 Go SQLite，不需要 cgo；关掉它让产物不依赖本机有没有 gcc。
    $env:CGO_ENABLED = '0'
    Invoke-Native 'go build' {
      go build -trimpath -ldflags "-s -w -X main.version=$Version" -o $out ./cmd/dreamtexture
    }
  }
  finally {
    Pop-Location
    Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
  }

  $size = '{0:N1} MB' -f ((Get-Item $out).Length / 1MB)
  Write-Host "== 完成：$out（$size）"
}
finally {
  # 无论成败都还原，让子模块保持干净。
  Write-Host '== 还原 backend/internal/web/dist'
  git -C $backend checkout -- $embedRel
  git -C $backend clean -fdq -- $embedRel
}
