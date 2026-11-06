#requires -Version 5.1
<#
.SYNOPSIS
    QQ 点歌翻唱套件 —— 卸载 / 回滚

.DESCRIPTION
    1. 停掉 song-rvc 和点歌监听
    2. 删掉拷进服务目录的脚本（不删 state 里的日志和缓存）
    3. 用最近的 .bak-* 还原四处补丁（SurfCore ×3 + Coopanion ×1）

.EXAMPLE
    .\uninstall.ps1 -DryRun
    .\uninstall.ps1
    .\uninstall.ps1 -KeepPatches      # 只停服务、删脚本，保留补丁
#>
[CmdletBinding()]
param(
    [string]$SurfcorePath,
    [string]$CoopanionPath,
    [string]$StateDir,
    [switch]$KeepPatches,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

function Say([string]$m, [string]$lvl = 'info') {
    switch ($lvl) {
        'ok'   { Write-Host "  [OK]   $m" -ForegroundColor Green }
        'skip' { Write-Host "  [SKIP] $m" -ForegroundColor DarkGray }
        'warn' { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
        'todo' { Write-Host "  [TODO] $m" -ForegroundColor Cyan }
        default { Write-Host "  $m" }
    }
}
function Step([string]$t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

function Probe-Surfcore {
    if ($SurfcorePath -and (Test-Path (Join-Path $SurfcorePath 'src\bridge.js'))) { return $SurfcorePath }
    foreach ($c in @('D:\surfcore', 'C:\surfcore')) { if (Test-Path (Join-Path $c 'src\bridge.js')) { return $c } }
    return $null
}
function Probe-Coopanion {
    if ($CoopanionPath -and (Test-Path (Join-Path $CoopanionPath 'Coopanion.exe'))) { return $CoopanionPath }
    foreach ($c in @('D:\Coopanion', 'C:\Program Files\Coopanion')) { if (Test-Path (Join-Path $c 'Coopanion.exe')) { return $c } }
    return $null
}

# 用同一目录下最新的 .bak-* 还原
function Restore-Latest([string]$file) {
    if (-not (Test-Path $file)) { Say "文件不存在，跳过：$file" 'skip'; return }
    $dir = Split-Path -Parent $file
    $leaf = Split-Path -Leaf $file
    $bak = Get-ChildItem $dir -Filter "$leaf.bak-*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $bak) { Say "没有备份可还原：$leaf" 'skip'; return }
    if ($DryRun) { Say "将用 $($bak.Name) 还原 $leaf" 'todo'; return }
    Copy-Item $bak.FullName $file -Force
    Say "已还原 $leaf（来自 $($bak.Name)）" 'ok'
}

Write-Host "QQ 点歌翻唱套件 · 卸载" -ForegroundColor White
if ($DryRun) { Write-Host "（DryRun：不会做任何改动）" -ForegroundColor Yellow }

$sc = Probe-Surfcore
$coop = Probe-Coopanion
if (-not $StateDir) {
    if ($sc) { $StateDir = Join-Path $sc 'state' } elseif ($env:SC_STATE_DIR) { $StateDir = $env:SC_STATE_DIR } else { $StateDir = 'D:\surfcore\state' }
}

Step '1. 停服务'
if ($DryRun) {
    Say "将执行：music-plugin.ps1 stop" 'todo'
} elseif (Test-Path (Join-Path $StateDir 'music-plugin.ps1')) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $StateDir 'music-plugin.ps1') stop
} else {
    # 兜底：直接杀
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'song-rvc\.py|song-cmd-poll\.py' } |
        ForEach-Object { if (-not $DryRun) { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Say "已按命令行杀掉两个 python" 'ok'
}

# 守护也停掉
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'song-guard' } |
    ForEach-Object { if (-not $DryRun) { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
Say "守护进程已停（如有）" 'ok'

Step '2. 删服务脚本'
$files = @('song-rvc.py', 'song-cmd-poll.py', 'song-guard.ps1', 'song-rvc-guard.bat',
    'music-plugin.ps1', '音乐插件-启动.bat', '音乐插件-停止.bat')
foreach ($f in $files) {
    $p = Join-Path $StateDir $f
    if (Test-Path $p) {
        if ($DryRun) { Say "将删除 $f" 'todo' } else { Remove-Item $p -Force; Say "已删除 $f" 'ok' }
    }
}
Say "（日志 song-*.log / 缓存 song-cache 保留，要清自己删）" 'skip'

if ($KeepPatches) {
    Step '3. 补丁（-KeepPatches，跳过）'
} else {
    Step '3. 还原补丁'
    if ($sc) {
        Restore-Latest (Join-Path $sc 'src\command-spam.js')
        Restore-Latest (Join-Path $sc 'src\bridge.js')
        Restore-Latest (Join-Path $sc 'config.json')
        Say "SurfCore 改完要重启桥接（restart.bat）" 'warn'
    } else { Say '没找到 SurfCore' 'skip' }
    if ($coop) {
        $worker = Join-Path $coop 'data\extensions\node_modules\@wocwang\cortico-world-rvc-for-coopanion\src\python\worker.py'
        Restore-Latest $worker
        if (-not $DryRun) {
            try {
                Invoke-WebRequest 'http://127.0.0.1:17788/api/worlds/restart' -Method POST -Body '{"id":"rvc"}' `
                    -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing | Out-Null
                Say "RVC world 已重启" 'ok'
            } catch { Say "重启 RVC 失败（Coopanion 没开？）" 'warn' }
        }
    } else { Say '没找到 Coopanion' 'skip' }
}

Step '汇总'
if ($DryRun) { Write-Host "  DryRun 结束。" -ForegroundColor Yellow }
else { Write-Host "  卸载完成。" -ForegroundColor Green }
