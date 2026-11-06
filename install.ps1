param(
    [string]$Target = "D:\surfcore\state",
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== QQ 点歌翻唱套件 安装 ===" -ForegroundColor Cyan
Write-Host "目标目录: $Target"

# 1. 依赖检查
$missing = @()
foreach ($cmd in @('python', 'ffmpeg', 'ffprobe', 'yt-dlp')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
}
if ($missing.Count -gt 0) {
    Write-Host "! 这些命令不在 PATH 里：$($missing -join ', ')" -ForegroundColor Yellow
    Write-Host "  python 必须有；ffmpeg/ffprobe 必需；yt-dlp 必需（pip install yt-dlp）" -ForegroundColor Yellow
} else {
    Write-Host "OK 依赖齐全（python / ffmpeg / ffprobe / yt-dlp）" -ForegroundColor Green
}

# 2. 拷贝
New-Item -ItemType Directory -Path $Target -Force | Out-Null
Copy-Item "$here\core\song-rvc.py"       $Target -Force
Copy-Item "$here\core\song-cmd-poll.py"  $Target -Force
Copy-Item "$here\guard\song-guard.ps1"   $Target -Force
Copy-Item "$here\guard\song-rvc-guard.bat" $Target -Force
Copy-Item "$here\music-plugin\*"         $Target -Force
Write-Host "OK 文件已拷到 $Target" -ForegroundColor Green

# 3. 环境变量提示
if (-not $env:SC_OWNER) {
    Write-Host "! 还没设 SC_OWNER（你的 QQ 号，用来监听私聊点歌）" -ForegroundColor Yellow
    Write-Host "  执行：setx SC_OWNER `"你的QQ号`"" -ForegroundColor Yellow
    Write-Host "  设置后需要重开终端/重启监听才生效" -ForegroundColor Yellow
}

# 4. SurfCore / Coopanion 补丁提醒
Write-Host ""
Write-Host "还需要手动打两处补丁（详见 README.md）：" -ForegroundColor Cyan
Write-Host "  · SurfCore: command-spam.js 覆盖 + bridge.js 插 8 行 + config.json 加 ignoreBracketCommands"
Write-Host "  · Coopanion: worker.py 覆盖后重启 RVC world"

# 5. 启动
if ($Start) {
    Write-Host ""
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$Target\music-plugin.ps1" start
}

Write-Host ""
Write-Host "完成。启停用：powershell -ExecutionPolicy Bypass -File `"$Target\music-plugin.ps1`" [status|start|stop|restart]" -ForegroundColor Green
