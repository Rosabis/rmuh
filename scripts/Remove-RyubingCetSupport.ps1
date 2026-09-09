<#
.SYNOPSIS
    从 Ryubing (Ryujinx) 源码中移除 CET (Control-flow Enforcement Technology / 影子栈) 支持。

.DESCRIPTION
    背景：
      .NET 9 起 apphost / singlefilehost 默认带 /CETCOMPAT 标记，
      在部分 Windows（尤其是 ntdll 未带 CET 修复补丁的版本）上会触发
      coreclr 断言  !AreShadowStacksEnabled() || UseSpecialUserModeApc()
      并以 0xc0000602 (STATUS_FAIL_FAST_EXCEPTION) 直接 fail-fast 退出。
      https://github.com/dotnet/runtime/issues/110920

    官方退出方式（按应用粒度）：在项目文件里写 <CETCompat>false</CETCompat>。
      https://learn.microsoft.com/dotnet/core/compatibility/interop/9.0/cet-support

    本脚本做两件事：
      1) 把所有 <CETCompat> 置为 false，缺失则在 Directory.Build.props / Ryujinx.csproj 中注入；
      2) 扫描源码里是否出现"运行时 CET 检测"相关 API，仅报告不误改代码。

.PARAMETER RepoRoot
    Ryubing 源码根目录。

.EXAMPLE
    ./scripts/Remove-RyubingCetSupport.ps1 -RepoRoot ryubing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Write-Host "== Ryubing 源码根目录: $RepoRoot ==" -ForegroundColor Cyan

$patchedFiles = [System.Collections.Generic.List[string]]::new()
$scanHits     = [System.Collections.Generic.List[string]]::new()

# ---------------------------------------------------------------------------
# 1. 关闭 MSBuild 的 CETCompat 开关
# ---------------------------------------------------------------------------
function Disable-CetCompat {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "跳过（文件不存在）: $Path"
        return
    }

    $text = [System.IO.File]::ReadAllText($Path)
    $rel  = $Path.Substring($RepoRoot.Length).TrimStart('\', '/')

    # 已有 <CETCompat>...</CETCompat> -> 直接改成 false
    $pattern = '(?s)<CETCompat\s*>.*?</CETCompat>'
    if ([regex]::IsMatch($text, $pattern)) {
        $new = [regex]::Replace($text, $pattern, '<CETCompat>false</CETCompat>')
        if ($new -ne $text) {
            [System.IO.File]::WriteAllText($Path, $new)
            Write-Host "  [改写] $rel : <CETCompat> -> false"
            $patchedFiles.Add($rel)
        }
        return
    }

    # 没有则注入到第一个 <PropertyGroup>
    $m = [regex]::Match($text, '<PropertyGroup\s*>')
    if ($m.Success) {
        $insertAt = $m.Index + $m.Length
        $new = $text.Substring(0, $insertAt) +
               [Environment]::NewLine + '    <CETCompat>false</CETCompat>' +
               $text.Substring($insertAt)
    }
    else {
        # 兜底：在 </Project> 前塞一个 PropertyGroup
        $m2 = [regex]::Match($text, '(?i)</Project\s*>')
        if (-not $m2.Success) {
            Write-Warning "跳过（找不到 PropertyGroup / </Project>）: $rel"
            return
        }
        $new = $text.Substring(0, $m2.Index) +
               '  <PropertyGroup>' + [Environment]::NewLine +
               '    <CETCompat>false</CETCompat>' + [Environment]::NewLine +
               '  </PropertyGroup>' + [Environment]::NewLine +
               $text.Substring($m2.Index)
    }

    [System.IO.File]::WriteAllText($Path, $new)
    Write-Host "  [注入] $rel : <CETCompat>false</CETCompat>"
    $patchedFiles.Add($rel)
}

Write-Host "`n[1/2] 关闭 MSBuild CETCompat..." -ForegroundColor Yellow

# 根目录 Directory.Build.props 对所有项目生效
Disable-CetCompat (Join-Path $RepoRoot 'Directory.Build.props')
# 主入口项目（真正产出 apphost / singlefilehost 的地方）
Disable-CetCompat (Join-Path $RepoRoot 'src/Ryujinx/Ryujinx.csproj')

# 其他任何显式写了 CETCompat 的项目文件一并修正
Get-ChildItem -LiteralPath $RepoRoot -Recurse -Include '*.csproj', '*.props', '*.targets' -File -ErrorAction SilentlyContinue |
    ForEach-Object {
        $t = [System.IO.File]::ReadAllText($_.FullName)
        if ([regex]::IsMatch($t, '(?s)<CETCompat\s*>\s*(?!false)')) {
            Disable-CetCompat $_.FullName
        }
    }

# ---------------------------------------------------------------------------
# 2. 扫描源码中是否存在"运行时 CET 检测"代码（只报告，不自动改业务代码）
# ---------------------------------------------------------------------------
Write-Host "`n[2/2] 扫描源码中的 CET / 影子栈检测代码..." -ForegroundColor Yellow

$detectionPatterns = @(
    'CETCompat',
    'CET_COMPAT',
    'IMAGE_DLLCHARACTERISTICS',
    'ShadowStack',
    'Shstk',
    'GetProcessMitigationPolicy',
    'SetProcessMitigationPolicy',
    'AreShadowStacksEnabled'
)
$rx = [regex]::new(($detectionPatterns | ForEach-Object { [regex]::Escape($_) }) -join '|')

Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src') -Recurse -Include '*.cs' -File -ErrorAction SilentlyContinue |
    ForEach-Object {
        $lineNo = 0
        foreach ($line in [System.IO.File]::ReadLines($_.FullName)) {
            $lineNo++
            if ($rx.IsMatch($line)) {
                $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
                $scanHits.Add("${rel}:${lineNo}: $($line.Trim())")
            }
        }
    }

if ($scanHits.Count -eq 0) {
    Write-Host "  未发现运行时 CET 检测代码（当前版本 CET 标记完全来自 .NET SDK 的 apphost）。" -ForegroundColor Green
}
else {
    Write-Host "  发现 $($scanHits.Count) 处 CET 相关引用（需人工确认，本脚本不自动改动业务代码）：" -ForegroundColor Magenta
    $scanHits | ForEach-Object { Write-Host "    $_" }
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
Write-Host "`n== 完成 ==" -ForegroundColor Cyan
Write-Host "  已处理文件: $($patchedFiles.Count)"
$patchedFiles | ForEach-Object { Write-Host "   - $_" }

if ($env:GITHUB_STEP_SUMMARY) {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('## CET 移除结果')
    [void]$lines.Add('')
    [void]$lines.Add('已关闭 CETCompat（.NET apphost 不再标记 /CETCOMPAT）：')
    [void]$lines.Add('')
    foreach ($f in $patchedFiles) { [void]$lines.Add("- $f") }
    [void]$lines.Add('')
    if ($scanHits.Count -eq 0) {
        [void]$lines.Add('源码扫描：未发现运行时 CET 检测代码。')
    }
    else {
        [void]$lines.Add("源码扫描：发现 $($scanHits.Count) 处 CET 相关引用")
        [void]$lines.Add('')
        foreach ($h in $scanHits) { [void]$lines.Add("    $h") }
    }
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n")
}

if ($patchedFiles.Count -eq 0) {
    Write-Warning "没有文件被修改，请确认 RepoRoot 是否正确。"
    exit 1
}
