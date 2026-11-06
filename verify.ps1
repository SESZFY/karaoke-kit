#requires -Version 5.1
<#
.SYNOPSIS
    QQ 点歌翻唱套件 —— 自检

.EXAMPLE
    .\verify.ps1
    .\verify.ps1 -SurfcorePath "D:\surfcore" -CoopanionPath "D:\Coopanion"
#>
[CmdletBinding()]
param(
    [string]$SurfcorePath,
    [string]$CoopanionPath,
    [string]$StateDir,
    [int]$SongPort = 9883,
    [int]$RvcPort = 9881,
    [int]$OneBotPort = 3000,
    [int]$CoopanionWebui = 17788
)

$ErrorActionPreference = 'Continue'
$script:Pass = 0; $script:Fail = 0; $script:Warn = 0

function Check([string]$name, [scriptblock]$test, [string]$fix = '') {
    try {
        $r = & $test
        if ($r -eq $true) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:Pass++ }
        elseif ($r -eq 'skip') { Write-Host "  [SKIP] $name" -ForegroundColor DarkGray }
        else { throw "返回 $r" }
    } catch {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        if ($fix) { Write-Host "         → $fix" -ForegroundColor Yellow }
        $script:Fail++
    }
}

function Warn([string]$name) { Write-Host "  [WARN] $name" -ForegroundColor Yellow; $script:Warn++ }

function Probe-Surfcore {
    if ($SurfcorePath) { return $SurfcorePath }
    foreach ($c in @('D:\surfcore', 'C:\surfcore')) { if (Test-Path (Join-Path $c 'src\bridge.js')) { return $c } }
    return $null
}
function Probe-Coopanion {
    if ($CoopanionPath) { return $CoopanionPath }
    foreach ($c in @('D:\Coopanion', 'C:\Program Files\Coopanion')) { if (Test-Path (Join-Path $c 'Coopanion.exe')) { return $c } }
    return $null
}
function PortOpen([int]$p) {
    [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue)
}
function HttpJson([string]$url, [int]$timeout = 5) {
    (Invoke-WebRequest $url -TimeoutSec $timeout -UseBasicParsing).Content | ConvertFrom-Json
}

Write-Host "QQ 点歌翻唱套件 · 自检" -ForegroundColor White
Write-Host ""

$sc = Probe-Surfcore
$coop = Probe-Coopanion
if (-not $StateDir) {
    if ($sc) { $StateDir = Join-Path $sc 'state' } elseif ($env:SC_STATE_DIR) { $StateDir = $env:SC_STATE_DIR } else { $StateDir = 'D:\surfcore\state' }
}

Write-Host "-- 服务" -ForegroundColor Cyan
Check "song-rvc.py 进程在跑" {
    [bool](Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'song-rvc\.py' })
} "powershell -File `"$StateDir\music-plugin.ps1`" start"

Check "点歌监听进程在跑" {
    [bool](Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'song-cmd-poll\.py' })
} "powershell -File `"$StateDir\music-plugin.ps1`" start"

Check "守护进程在跑" {
    [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'song-guard' })
} "双击 $StateDir\song-rvc-guard.bat"

Check "端口 $SongPort 在听" { PortOpen $SongPort } "起 song-rvc.py"
Check "端口 $RvcPort 在听（Coopanion RVC）" { PortOpen $RvcPort } "打开 Coopanion，等 RVC 页就绪"
Check "OneBot 端口 $OneBotPort 可达" { PortOpen $OneBotPort } "打开 SnowLuma"

Write-Host ""
Write-Host "-- 接口" -ForegroundColor Cyan
Check "9883 /health ok" {
    $h = HttpJson "http://127.0.0.1:$SongPort/health"
    if ($h.ok -and $h.rvc.ok) { $true } else { throw "ok=$($h.ok) rvc.ok=$($h.rvc.ok)" }
} "看 $StateDir\song-rvc.err.log"

Check "9881 RVC ready=true" {
    $h = HttpJson "http://127.0.0.1:$RvcPort/health"
    if ($h.ready) { $true } else { throw "ready=false（worker 崩了）" }
} "POST http://127.0.0.1:$CoopanionWebui/api/worlds/restart  body {`"id`":`"rvc`"}"

Write-Host ""
Write-Host "-- 补丁" -ForegroundColor Cyan
if ($sc) {
    Check "SurfCore: command-spam.js 含 isBracketCommandText" {
        (Get-Content (Join-Path $sc 'src\command-spam.js') -Raw -Encoding utf8) -match 'isBracketCommandText'
    } "跑 install.ps1 -Auto"

    Check "SurfCore: bridge.js 含过滤块" {
        (Get-Content (Join-Path $sc 'src\bridge.js') -Raw -Encoding utf8) -match 'ignoreBracketCommands'
    } "跑 install.ps1 -Auto"

    Check "SurfCore: config.json ignoreBracketCommands=true" {
        $cfg = (Get-Content (Join-Path $sc 'config.json') -Raw -Encoding utf8) | ConvertFrom-Json
        $cfg.socialV2.ignoreBracketCommands -eq $true
    } "跑 install.ps1 -Auto"
} else { Write-Host "  [SKIP] 没找到 SurfCore，跳过补丁检查" -ForegroundColor DarkGray }

if ($coop) {
    $worker = Join-Path $coop 'data\extensions\node_modules\@wocwang\cortico-world-rvc-for-coopanion\src\python\worker.py'
    Check "Coopanion: worker.py 含 _release_vram" {
        (Test-Path $worker) -and ((Get-Content $worker -Raw -Encoding utf8) -match '_release_vram')
    } "跑 install.ps1 -Auto"
} else { Write-Host "  [SKIP] 没找到 Coopanion，跳过补丁检查" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "-- 资源" -ForegroundColor Cyan
try {
    $free = [int]((nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null) -replace '\D', '')
    if ($free -gt 0) {
        if ($free -lt 1500) { Warn "显存只剩 ${free}MB —— 长音频可能把 RVC worker 顶崩（先重启 world 或降 SONG_RVC_BLOCK）" }
        else { Write-Host "  [PASS] 显存空闲 ${free}MB" -ForegroundColor Green; $script:Pass++ }
    } else { Write-Host "  [SKIP] nvidia-smi 没返回" -ForegroundColor DarkGray }
} catch { Write-Host "  [SKIP] nvidia-smi 不可用" -ForegroundColor DarkGray }

if (-not $env:SC_OWNER) { Warn "SC_OWNER 未设置（私聊点歌需要）：setx SC_OWNER `"你的QQ号`"" }

Write-Host ""
if ($script:Fail -eq 0) {
    Write-Host "OVERALL: PASS   （$($script:Pass) 项通过，$($script:Warn) 项提醒）" -ForegroundColor Green
    exit 0
} else {
    Write-Host "OVERALL: FAIL   （$($script:Fail) 项失败，$($script:Pass) 项通过）" -ForegroundColor Red
    exit 1
}
