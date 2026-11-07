# 点歌服务守护 —— 守 song-rvc(:9883)、点歌监听，以及 Coopanion 那边的 RVC 引擎(:9881)。
#
# 旧 song-rvc-guard.bat 的判定是坏的：
#   tasklist /FI "IMAGENAME eq python.exe" /FO CSV | findstr "song-rvc"
# CSV 输出里只有进程名 python.exe，没有命令行，findstr 永远匹配不到 "song-rvc"。
# 结果是它每 30 秒就认定"没在跑"，再 start 一个 song-rvc.py；第二个实例绑 9883 失败当场崩，
# 表现就是点歌时好时坏、日志里莫名其妙出现 10061/10054。
# 这里改成按命令行匹配，只有一个实例才放行。

$STATE = 'D:\surfcore\state'

function Get-Match([string]$pattern) {
    @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern })
}

function Start-Hidden([string]$script, [string]$outLog, [string]$errLog) {
    # 不要用 cmd /c start /B：进程会挂在守护那个隐藏窗口的控制台上，
    # 控制台一销毁（守护被关、会话结束）子进程就跟着没了 —— 表现就是「song-rvc 没开」。
    # 这里让 cmd 常驻当父进程（重定向要 shell），窗口隐藏，日志 append。
    $args2 = '/c python "' + (Join-Path $STATE $script) + '" >> "' + (Join-Path $STATE $outLog) + '" 2>> "' + (Join-Path $STATE $errLog) + '"'
    Start-Process -FilePath 'cmd.exe' -ArgumentList $args2 -WorkingDirectory $STATE -WindowStyle Hidden | Out-Null
}

# RVC 引擎（Coopanion 的 world）崩了：worker 一退出，9881 就 ready=false，所有点歌 409。
# 发现不在就调 Coopanion 的 world 重启接口。重新加载模型约 90 秒，期间一直 ready=false，
# 所以留 3 分钟冷却，不能反复打。
$script:lastRvcRestart = [datetime]::MinValue

function Test-RvcReady {
    try {
        $h = (Invoke-WebRequest 'http://127.0.0.1:9881/health' -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json
        return [bool]$h.ready
    } catch { return $false }
}

function Restart-RvcEngine {
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:17788/api/worlds/restart' -Method POST `
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
