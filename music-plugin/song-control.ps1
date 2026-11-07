#requires -Version 5.1
<#
.SYNOPSIS
    点歌系统控制台（给桌面 bat 调用的后端）
.EXAMPLE
    song-control.ps1 status
    song-control.ps1 start
    song-control.ps1 stop
    song-control.ps1 restart
    song-control.ps1 logs
#>
param(
    [ValidateSet('status', 'start', 'stop', 'restart', 'logs')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'SilentlyContinue'
$STATE = if ($env:SC_STATE_DIR) { $env:SC_STATE_DIR } else { 'D:\surfcore\state' }
$SONG_PORT = 9883
$RVC_PORT = 9881
$ONEBOT_PORT = 3000
$WEBUI = 'http://127.0.0.1:17788'
$PY = 'python'

function Get-PyProc([string]$pattern) {
    @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern })
}
function Get-GuardProc {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'song-guard' })
}
function Test-Port([int]$p) {
    [bool](Get-NetTCPConnection -State Listen -LocalPort $p)
}
function Try-Json([string]$url) {
    try { (Invoke-WebRequest $url -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json } catch { $null }
}
function Line([string]$t = '') { Write-Host $t }

function Show-Status {
    $poll = @(Get-PyProc 'song-cmd-poll\.py')
    $rvc = @(Get-PyProc 'song-rvc\.py')
    $guard = @(Get-GuardProc)
    $songOk = Test-Port $SONG_PORT
    $rvcOk = Test-Port $RVC_PORT
    $qqOk = Test-Port $ONEBOT_PORT
    $h983 = Try-Json "http://127.0.0.1:$SONG_PORT/health"
    $h981 = Try-Json "http://127.0.0.1:$RVC_PORT/health"

    Write-Host ("=" * 52) -ForegroundColor DarkCyan
    Write-Host "  点歌系统" -NoNewline -ForegroundColor White
    Write-Host ("  " + (Get-Date -Format 'HH:mm:ss') + "  ") -NoNewline -ForegroundColor DarkGray
    Write-Host ""
    Write-Host ("=" * 52) -ForegroundColor DarkCyan

    function Row([string]$label, [bool]$on, [string]$detail, [string]$okColor = 'Green') {
        Write-Host "  " -NoNewline
        if ($on) { Write-Host "●" -ForegroundColor $okColor -NoNewline }
        else { Write-Host "○" -ForegroundColor Red -NoNewline }
        Write-Host ("  {0,-10}" -f $label) -NoNewline
        Write-Host $detail -ForegroundColor $(if ($on) { 'White' } else { 'DarkGray' })
    }

    Row '点歌监听' ($poll.Count -gt 0) $(if ($poll.Count -gt 0) { "PID $($poll[0].ProcessId)" } else { '未运行' })
    Row 'song-rvc' ($rvc.Count -gt 0) $(if ($rvc.Count -gt 0) { "PID $($rvc[0].ProcessId)   :$SONG_PORT" } else { "未运行（:$SONG_PORT 无监听）" })
    Row 'RVC 引擎' ([bool]($h981 -and $h981.ready)) $(if ($h981 -and $h981.ready) { "$($h981.model)  queue=$($h981.queue)" } elseif ($rvcOk) { '启动中…' } else { "不可用（:$RVC_PORT 无监听）" })
    Row 'QQ 通道' $qqOk $(if ($qqOk) { "OneBot :$ONEBOT_PORT" } else { "不通（SnowLuma 没开？）" })
    Row '守护' ($guard.Count -gt 0) $(if ($guard.Count -gt 0) { "PID $($guard[0].ProcessId)" } else { '未运行（崩了不会自动拉）' })

    Write-Host ("-" * 52) -ForegroundColor DarkCyan

    # 显存
    try {
        $free = [int]((nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null) -replace '\D', '')
        if ($free -gt 0) {
            $color = if ($free -lt 1500) { 'Yellow' } else { 'Gray' }
            Write-Host "  显存空闲 ${free} MB" -ForegroundColor $color
        }
    } catch {}

    # 最近一次点歌结果
    $log = Join-Path $STATE 'song-poll.err.log'
    if (Test-Path $log) {
        $last = Get-Content $log -Tail 30 -Encoding Default |
            Where-Object { $_ -match '全部已发|部分失败|已发 \d+KB|失败：' } |
            Select-Object -Last 1
        if ($last) { $line = ($last -replace '^\[song-poll\]\s*', ''); if ($line.Length -gt 78) { $line = $line.Substring(0, 78) + '…' }; Write-Host ("  最近：" + $line) -ForegroundColor DarkGray }
    }
    if ($h983 -and $h983.ok) {
        Write-Host "  接口正常" -ForegroundColor DarkGray
    }
    Write-Host ("=" * 52) -ForegroundColor DarkCyan
}

function Start-All {
    Remove-Item "$STATE\song-rvc.lock" -Force -ErrorAction SilentlyContinue

    # 守护先起来（它自己会拉起两个 python）
    if (@(Get-GuardProc).Count -eq 0) {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$STATE\song-guard.ps1" `
            -WindowStyle Hidden
        Write-Host "  守护已启动" -ForegroundColor Green
    } else {
        Write-Host "  守护已在运行" -ForegroundColor DarkGray
    }

    # 等 song-rvc 起来（最多 30 秒）
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Port $SONG_PORT) { $ok = $true; break }
    }
    if ($ok) { Write-Host "  song-rvc :$SONG_PORT 已就绪" -ForegroundColor Green }
    else {
        # 兜底：直接拉
        cmd.exe /c "start `"songrvc`" /B $PY `"$STATE\song-rvc.py`" >> `"$STATE\song-rvc.log`" 2>> `"$STATE\song-rvc.err.log`""
        Start-Sleep -Seconds 6
        if (Test-Port $SONG_PORT) { Write-Host "  song-rvc 已手动拉起" -ForegroundColor Green }
        else { Write-Host "  song-rvc 起不来，看 song-rvc.err.log" -ForegroundColor Red }
    }

    # 点歌监听
    if (@(Get-PyProc 'song-cmd-poll\.py').Count -eq 0) {
        cmd.exe /c "start `"songpoll`" /B $PY `"$STATE\song-cmd-poll.py`" >> `"$STATE\song-poll.log`" 2>> `"$STATE\song-poll.err.log`""
        Start-Sleep -Seconds 5
    }
    if (@(Get-PyProc 'song-cmd-poll\.py').Count -gt 0) { Write-Host "  点歌监听已启动" -ForegroundColor Green }
    else { Write-Host "  点歌监听起不来，看 song-poll.err.log" -ForegroundColor Red }

    Write-Host ""
    Show-Status
}

function Stop-All {
    $n = 0
    foreach ($p in @(Get-PyProc 'song-cmd-poll\.py')) { Stop-Process -Id $p.ProcessId -Force; $n++ }
    foreach ($p in @(Get-PyProc 'song-rvc\.py')) { Stop-Process -Id $p.ProcessId -Force; $n++ }
    foreach ($p in @(Get-GuardProc)) { Stop-Process -Id $p.ProcessId -Force; $n++ }
    if ($n -gt 0) { Write-Host "  已停止 $n 个进程（Coopanion 和 SnowLuma 不动）" -ForegroundColor Green }
    else { Write-Host "  本来就没在跑" -ForegroundColor DarkGray }
    Write-Host ""
    Show-Status
}

function Show-Logs {
    Write-Host "  实时日志（点歌 + RVC），Ctrl+C 退出" -ForegroundColor Cyan
    Write-Host ("-" * 52) -ForegroundColor DarkCyan
    $a = Join-Path $STATE 'song-poll.err.log'
    $b = Join-Path $STATE 'song-rvc.err.log'
    Get-Content $a -Tail 15 -Encoding Default -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host $_ -ForegroundColor Gray }
    Get-Content $a, $b -Wait -Tail 0 -Encoding Default -ErrorAction SilentlyContinue |
        ForEach-Object {
            $c = if ($_ -match '已发|全部已发') { 'Green' } elseif ($_ -match '失败|错误|Error') { 'Red' } else { 'Gray' }
            Write-Host $_ -ForegroundColor $c
        }
}

switch ($Action) {
    'status'  { Show-Status }
    'start'   { Start-All }
    'stop'    { Stop-All }
    'restart' { Stop-All; Start-Sleep -Seconds 2; Start-All }
    'logs'    { Show-Logs }
}
