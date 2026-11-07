#requires -Version 5.1
<#
.SYNOPSIS
    点歌翻唱全套 —— 卸载（默认只删脚本，保留软件和音色）
.EXAMPLE
    .\uninstall.ps1                       # 停服务 + 删点歌脚本和 DDSP
    .\uninstall.ps1 -RemoveVendor         # 连 Coopanion / SnowLuma / SurfCore 一起删
    .\uninstall.ps1 -KeepDdsp             # 保留 DDSP（800MB，重装省事）
    .\uninstall.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$CoopanionPath = "D:\Coopanion",
    [string]$SnowLumaPath  = "D:\大肥鱼的实验室\SnowLuma",
    [string]$SurfcorePath  = "D:\surfcore",
    [string]$StateDir      = "",
    [string]$DdspPath      = "",
    [switch]$RemoveVendor,
    [switch]$KeepDdsp,
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'
if (-not $StateDir) { $StateDir = Join-Path $SurfcorePath 'state' }
if (-not $DdspPath) { $DdspPath = Join-Path $StateDir 'ddsp-svc' }

function Say([string]$m, [string]$lvl='info') {
    switch ($lvl) {
        'ok'   { Write-Host "  [OK]   $m" -ForegroundColor Green }
        'skip' { Write-Host "  [SKIP] $m" -ForegroundColor DarkGray }
        'warn' { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
        default{ Write-Host "  $m" }
    }
}
Write-Host "点歌翻唱全套 · 卸载" -ForegroundColor White
if ($DryRun) { Write-Host "（DryRun：不删任何东西）" -ForegroundColor Yellow }

Write-Host ""
Write-Host "== 1. 停止服务" -ForegroundColor Cyan
$mp = Join-Path $StateDir 'music-plugin.ps1'
if (Test-Path $mp -and -not $DryRun) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $mp stop 2>$null
    Say "已调用 music-plugin.ps1 stop"
} else { Say '跳过（或 DryRun）' 'skip' }
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
    Where-Object { $_.CommandLine -match 'song-cmd-poll|song-rvc\.py' } |
    ForEach-Object {
        if ($DryRun) { Say "将结束 PID $($_.ProcessId)" }
        else { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Say "结束 PID $($_.ProcessId)" }
    }

Write-Host ""
Write-Host "== 2. 删点歌脚本" -ForegroundColor Cyan
foreach ($f in @('song-rvc.py','song-cmd-poll.py','song-guard.ps1','song-control.ps1',
                 'music-plugin.ps1','song-rvc-guard.bat','音乐插件-启动.bat','音乐插件-停止.bat',
                 'song-cmd-seen.json')) {
    $p = Join-Path $StateDir $f
    if (Test-Path $p) {
        if ($DryRun) { Say "将删除 $f" }
        else { Remove-Item $p -Force -ErrorAction SilentlyContinue; Say "删除 $f" 'ok' }
    }
}

if (-not $KeepDdsp) {
    Write-Host ""
    Write-Host "== 3. 删 DDSP-SVC（含模型 800MB）" -ForegroundColor Cyan
    if (Test-Path $DdspPath) {
        if ($DryRun) { Say "将删除 $DdspPath" }
        else { Remove-Item $DdspPath -Recurse -Force -ErrorAction SilentlyContinue; Say "删除 $DdspPath" 'ok' }
    } else { Say '不存在' 'skip' }
} else { Write-Host ""; Write-Host "== 3. DDSP（-KeepDdsp，保留）" -ForegroundColor Cyan; Say '保留' 'skip' }

if ($RemoveVendor) {
    Write-Host ""
    Write-Host "== 4. 删原版软件（危险！）" -ForegroundColor Red
    foreach ($p in @($CoopanionPath, $SnowLumaPath, $SurfcorePath)) {
        if (Test-Path $p) {
            if ($DryRun) { Say "将删除 $p" }
            else {
                Say "删除 $p（3 秒后，Ctrl+C 可取消）" 'warn'
                Start-Sleep -Seconds 3
                Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
                Say "已删除 $p" 'ok'
            }
        }
    }
} else {
    Write-Host ""
    Write-Host "== 4. 原版软件（保留）" -ForegroundColor Cyan
    Say '加 -RemoveVendor 才会删' 'skip'
}

Write-Host ""
Write-Host "== 5. 还原备份" -ForegroundColor Cyan
$baks = Get-ChildItem -Path $SurfcorePath, $CoopanionPath -Filter '*.bak-*' -Recurse -File -ErrorAction SilentlyContinue
if ($baks) {
    foreach ($b in $baks) {
        $orig = $b.FullName -replace '\.bak-\d{8}-\d{6}$', ''
        if ($DryRun) { Say "将还原 $($b.Name) → $(Split-Path -Leaf $orig)" }
        else { Copy-Item $b.FullName $orig -Force -ErrorAction SilentlyContinue; Say "还原 $(Split-Path -Leaf $orig)" 'ok' }
    }
} else { Say '没有备份文件' 'skip' }

Write-Host ""
Write-Host "== 6. 清环境变量" -ForegroundColor Cyan
foreach ($v in @('SONG_ENGINE','SONG_DDSP_DIR','SC_OWNER','DDSP_STEP','DDSP_HIGHPASS','DDSP_GAIN','DDSP_INST_GAIN')) {
    if ($DryRun) { Say "将清除 $v" }
    else { [Environment]::SetEnvironmentVariable($v, $null, 'User'); Say "清除 $v" 'ok' }
}

Write-Host ""
Write-Host "卸载完成。" -ForegroundColor Green
Write-Host "（音色模型、聊天记录、点歌缓存都保留着，重装可以直接用）" -ForegroundColor DarkGray
