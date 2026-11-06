# 点歌服务守护 —— 守 song-rvc(:9883)、点歌监听，以及 Coopanion 那边的 RVC 引擎(:9881)。
#
# 旧 song-rvc-guard.bat 的判定是坏的：
#   tasklist /FI "IMAGENAME eq python.exe" /FO CSV | findstr "song-rvc"
# CSV 输出里只有进程名 python.exe，没有命令行，findstr 永远匹配不到 "song-rvc"。
# 结果是它每 30 秒就认定"没在跑"，再 start 一个 song-rvc.py；第二个实例绑 9883 失败当场崩，
# 表现就是点歌时好时坏、日志里莫名其妙出现 10061/10054。
# 这里改成按命令行匹配，只有一个实例才放行。

# 服务目录（song-rvc.py / song-cmd-poll.py 所在处）。可用 SC_STATE_DIR 覆盖。
$STATE = if ($env:SC_STATE_DIR) { $env:SC_STATE_DIR } else { 'D:\surfcore\state' }
# Coopanion 的 RVC 引擎端口 / webui 端口（自愈用）
$RVC_PORT = if ($env:SC_RVC_PORT) { $env:SC_RVC_PORT } else { '9881' }
$COOPANION_WEBUI = if ($env:SC_COOPANION_WEBUI) { $env:SC_COOPANION_WEBUI } else { 'http://127.0.0.1:17788' }

function Get-Match([string]$pattern) {
    @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern })
}

function Start-Hidden([string]$script, [string]$outLog, [string]$errLog) {
    cmd.exe /c "start `"$script`" /B python `"$STATE\$script`" >> `"$STATE\$outLog`" 2>> `"$STATE\$errLog`""
}

# RVC 引擎（Coopanion 的 world）崩了：worker 一退出，9881 就 ready=false，所有点歌 409。
# 发现不在就调 Coopanion 的 world 重启接口。重新加载模型约 90 秒，期间一直 ready=false，
# 所以留 3 分钟冷却，不能反复打。
$script:lastRvcRestart = [datetime]::MinValue

function Test-RvcReady {
    try {
        $h = (Invoke-WebRequest "http://127.0.0.1:$RVC_PORT/health" -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json
        return [bool]$h.ready
    } catch { return $false }
}

function Restart-RvcEngine {
    try {
        $r = Invoke-WebRequest "$COOPANION_WEBUI/api/worlds/restart" -Method POST `
            -Body '{"id":"rvc"}' -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing
        Write-Host "$(Get-Date -Format HH:mm:ss) RVC 引擎不在，已请求重启：$($r.Content)"
        $script:lastRvcRestart = Get-Date
    } catch {
        Write-Host "$(Get-Date -Format HH:mm:ss) RVC 重启请求失败：$($_.Exception.Message)"
    }
}

# 冷启动先等 RVC(9881) 就绪，避免 song-rvc 起来就报 RVC 不可用
$waited = 0
while ($waited -lt 60) {
    if (Test-RvcReady) { break }
    Start-Sleep -Seconds 3; $waited += 3
}

while ($true) {
    $now = Get-Date -Format 'HH:mm:ss'

    if ((Get-Match 'song-rvc\.py').Count -eq 0) {
        Write-Host "$now song-rvc 不在，拉起"
        Start-Hidden 'song-rvc.py' 'song-rvc.log' 'song-rvc.err.log'
    }
    if ((Get-Match 'song-cmd-poll\.py').Count -eq 0) {
        Write-Host "$now 点歌监听不在，拉起"
        Start-Hidden 'song-cmd-poll.py' 'song-poll.log' 'song-poll.err.log'
    }

    if (-not (Test-RvcReady) -and ((Get-Date) - $script:lastRvcRestart).TotalSeconds -gt 180) {
        Restart-RvcEngine
    }

    Start-Sleep -Seconds 30
}
