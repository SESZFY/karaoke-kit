<#
  音乐插件（点歌 → 搜音源 → RVC 换音色 → 发 QQ）的统一开关。

  用法（命令行）：
      .\music-plugin.ps1 status      看状态
      .\music-plugin.ps1 start       起服务（song-rvc + 点歌监听）
      .\music-plugin.ps1 stop        停掉（只停这两个，不动 Coopanion / SnowLuma）
      .\music-plugin.ps1 restart     重起

  也可以直接双击桌面上的「音乐插件-状态.bat」。
#>
param([string]$Action = 'status')

$ErrorActionPreference = 'Continue'
$STATE = if ($env:SC_STATE_DIR) { $env:SC_STATE_DIR } else { 'D:\surfcore\state' }
$PY = 'python'

function Test-Port([int]$p) {
  [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue)
}

function Get-Listener {
  Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'song-cmd-poll\.py' }
}

function Show-Status {
  $songOk = Test-Port 9883
  $rvcOk = Test-Port 9881
  $qqOk = Test-Port 3000
  $ls = @(Get-Listener)
  $rvcModel = ''
  if ($rvcOk) {
    try { $rvcModel = (Invoke-WebRequest 'http://127.0.0.1:9881/health' -TimeoutSec 4 -UseBasicParsing).Content | ConvertFrom-Json | ForEach-Object { "ready=$($_.ready) $($_.model)" } } catch {}
  }
  Write-Host ""
  Write-Host "  音乐插件状态" -ForegroundColor Cyan
  Write-Host "  ─────────────────────────────────────────"
  Write-Host ("  song-rvc  :9883   " + $(if($songOk){'运行中'}else{'未启动'}) + "   " + $(if($songOk){try{(Invoke-WebRequest 'http://127.0.0.1:9883/health' -TimeoutSec 4 -UseBasicParsing).StatusCode}catch{'?'}}else{''}))
  Write-Host ("  点歌监听  (轮询)  " + $(if($ls.Count -gt 0){"运行中 PID=$($ls[0].ProcessId)"}else{'未启动'}))
  Write-Host ("  RVC       :9881   " + $(if($rvcOk){"运行中  $rvcModel"}else{'未启动（点歌会失败）'}))
  Write-Host ("  QQ 通道   :3000   " + $(if($qqOk){'运行中'}else{'未启动（SnowLuma 没开）'}))
  Write-Host "  ─────────────────────────────────────────"
  if ($songOk -and $ls.Count -gt 0) { Write-Host "  可以用了：QQ 里发 【唱】歌名" -ForegroundColor Green }
  else { Write-Host "  还没齐，执行 start" -ForegroundColor Yellow }
  Write-Host ""
}

function Start-All {
  # Coopanion 的 RVC 是前置（点歌要用它的模型）
  if (-not (Test-Port 9881)) {
    Write-Host "  ! RVC(9881) 没在跑：先打开 Coopanion，等「RVC唱歌-大肥鱼」页显示引擎就绪" -ForegroundColor Yellow
  }
  if (-not (Test-Port 9883)) {
    # 用 cmd start 起，脱离当前进程树：Start-Process 带重定向时父进程会等 EOF，
    # 脚本一被中断子进程也一起没（本机踩过好几次）。
    & cmd.exe /c "start `"songrvc`" /B python `"$STATE\song-rvc.py`" >> `"$STATE\song-rvc.log`" 2>> `"$STATE\song-rvc.err.log`""
    for ($i = 0; $i -lt 12; $i++) { Start-Sleep -Seconds 1; if (Test-Port 9883) { break } }
    if (Test-Port 9883) { Write-Host "  ✓ song-rvc :9883 已启动" } else { Write-Host "  ✗ song-rvc 启动失败，看 $STATE\song-rvc.err.log" -ForegroundColor Red }
  } else { Write-Host "  · song-rvc 已在运行" }

  if (@(Get-Listener).Count -eq 0) {
    & cmd.exe /c "start `"songpoll`" /B python `"$STATE\song-cmd-poll.py`" >> `"$STATE\song-poll.log`" 2>> `"$STATE\song-poll.err.log`""
    Start-Sleep -Seconds 3
    if (@(Get-Listener).Count -gt 0) { Write-Host "  ✓ 点歌监听已启动" } else { Write-Host "  ✗ 监听没起来，看 $STATE\song-poll.err.log" -ForegroundColor Red }
  } else { Write-Host "  · 点歌监听已在运行" }
}

function Stop-All {
  $stopped = 0
  $old = (Get-NetTCPConnection -State Listen -LocalPort 9883 -ErrorAction SilentlyContinue).OwningProcess
  if ($old) {
    $p = Get-Process -Id $old -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'python') { Stop-Process -Id $old -Force; $stopped++; Write-Host "  ✓ 已停 song-rvc" }
  }
  foreach ($p in @(Get-Listener)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $stopped++; Write-Host "  ✓ 已停点歌监听" }
  if ($stopped -eq 0) { Write-Host "  · 本来就没在跑" }
}

switch ($Action.ToLower()) {
  'start'   { Start-All; Show-Status }
  'stop'    { Stop-All; Show-Status }
  'restart' { Stop-All; Start-Sleep -Seconds 2; Start-All; Show-Status }
  'status'  { Show-Status }
  default   { Write-Host "用法: music-plugin.ps1 [status|start|stop|restart]"; Show-Status }
}
