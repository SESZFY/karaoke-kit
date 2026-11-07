#requires -Version 5.1
<#
.SYNOPSIS
    点歌翻唱全套 —— 一键安装器（自动下载原版软件，再注入修改）
.DESCRIPTION
    包内不含原版软件本体。安装时从官方 GitHub Releases 下载，再注入改动：
      Coopanion  -> RVC 扩展 + 洛天依音色 + UVR5 模型 + 显存回收补丁
      SnowLuma   -> 原样安装（QQ 网关）
      SurfCore   -> 原版源码 + 方括号命令过滤补丁
      DDSP-SVC   -> 翻唱引擎全套（含模型）
.EXAMPLE
    .\install.ps1 -OwnerQQ 123456789
    .\install.ps1 -OwnerQQ 123456789 -Start
    .\install.ps1 -DryRun
    .\install.ps1 -Offline -CoopanionZip "D:\dl\Coopanion.zip"
#>
[CmdletBinding()]
param(
    [string]$CoopanionPath = "D:\Coopanion",
    [string]$SnowLumaPath  = "D:\大肥鱼的实验室\SnowLuma",
    [string]$SurfcorePath  = "D:\surfcore",
    [string]$DdspPath      = "",
    [string]$OwnerQQ       = "",
    [string]$CoopanionZip  = "",
    [string]$SnowLumaZip   = "",
    [string]$SurfcoreZip   = "",
    [switch]$SkipVendor,
    [switch]$Offline,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tmp   = Join-Path $env:TEMP "karaoke-install-$stamp"
$script:Fails = @(); $script:Warns = @()

$SRC = @{
    Coopanion = @{ Url = 'https://github.com/Pal-AI-Lab/Coopanion/releases/download/v0.2.18/Coopanion-0.2.18-win-x64-portable.zip'; Name = 'Coopanion 便携版' }
    SnowLuma  = @{ Url = 'https://github.com/SnowLuma/SnowLuma/releases/download/v2.4.2/SnowLuma-v2.4.2-win-x64.zip'; Name = 'SnowLuma win-x64' }
    Surfcore  = @{ Url = 'https://github.com/mieksido/surfcore/archive/refs/heads/main.zip'; Name = 'SurfCore main' }
}

function Say([string]$m, [string]$lvl = 'info') {
    switch ($lvl) {
        'ok'   { Write-Host "  [OK]   $m" -ForegroundColor Green }
        'skip' { Write-Host "  [SKIP] $m" -ForegroundColor DarkGray }
        'warn' { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:Warns += $m }
        'err'  { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:Fails += $m }
        'todo' { Write-Host "  [TODO] $m" -ForegroundColor Cyan }
        default { Write-Host "  $m" }
    }
}
function Step([string]$t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Backup([string]$f) {
    if (-not (Test-Path $f)) { return }
    if ($DryRun) { Say "将备份 $(Split-Path -Leaf $f)" 'todo'; return }
    Copy-Item $f "$f.bak-$stamp" -Force -ErrorAction SilentlyContinue
}

function Get-Remote([string]$url, [string]$out, [string]$label) {
    if ($DryRun) { Say "将下载 $label" 'todo'; return $false }
    if ($Offline) { Say "$label 需要联网（-Offline 已禁止）" 'err'; return $false }
    New-Item -ItemType Directory -Path (Split-Path $out -Parent) -Force | Out-Null
    Say "下载 $label ..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $aria = Get-Command aria2c -ErrorAction SilentlyContinue
        if ($aria) {
            & $aria.Source -x 16 -s 16 -k 1M --file-allocation=none --console-log-level=warn --summary-interval=0 -d (Split-Path $out -Parent) -o (Split-Path $out -Leaf) $url 2>$null | Out-Null
        } else {
            Invoke-WebRequest $url -OutFile $out -TimeoutSec 1800 -UseBasicParsing
        }
        if (-not (Test-Path $out) -or (Get-Item $out).Length -lt 1MB) { throw '文件没下来或过小' }
        $sw.Stop()
        Say "$label 完成 $([math]::Round((Get-Item $out).Length/1MB,1)) MB / $([math]::Round($sw.Elapsed.TotalSeconds,0))s" 'ok'
        return $true
    } catch { Say "$label 下载失败：$($_.Exception.Message)" 'err'; return $false }
}

function Expand-Zip([string]$zip, [string]$dest, [string]$label) {
    if ($DryRun) { Say "将解压 $label" 'todo'; return }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    try {
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        $inner = Get-ChildItem $dest -Directory | Select-Object -First 1
        if ($inner -and (Get-ChildItem $dest -File).Count -eq 0) {
            Get-ChildItem $inner.FullName | Move-Item -Destination $dest -Force
            Remove-Item $inner.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Say "$label 解压完成" 'ok'
    } catch { Say "$label 解压失败：$($_.Exception.Message)" 'err' }
}

function Flatten([string]$root, [string]$exeName) {
    if (Test-Path (Join-Path $root $exeName)) { return }
    $sub = Get-ChildItem $root -Recurse -Filter $exeName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sub) { return }
    $dir = Split-Path $sub.FullName -Parent
    if ($dir -eq $root) { return }
    Get-ChildItem $dir | Move-Item -Destination $root -Force
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $DdspPath) { $DdspPath = Join-Path (Join-Path $SurfcorePath 'state') 'ddsp-svc' }

Write-Host "点歌翻唱全套 · 一键安装（自动下载原版）" -ForegroundColor White
Write-Host "会从 GitHub 下载约 440 MB 原版软件，再注入修改" -ForegroundColor DarkGray
if ($DryRun)  { Write-Host "（DryRun：不下载、不修改）" -ForegroundColor Yellow }
if ($Offline) { Write-Host "（Offline：只用本地 zip）" -ForegroundColor Yellow }

Step '0. 依赖检查'
foreach ($c in @('python','ffmpeg','yt-dlp','node')) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { Say "$c 就绪" 'ok' } else { Say "$c 不在 PATH" 'warn' }
}

Step '1. 目标路径'
Say "Coopanion : $CoopanionPath"
Say "SnowLuma  : $SnowLumaPath"
Say "SurfCore  : $SurfcorePath"
Say "DDSP      : $DdspPath"

if (-not $SkipVendor) {
    Step '2. Coopanion'
    $need = $Force -or -not (Test-Path (Join-Path $CoopanionPath 'Coopanion.exe'))
    if ($need) {
        $zip = $CoopanionZip
        if (-not $zip) { $zip = Join-Path $tmp 'Coopanion.zip'; [void](Get-Remote $SRC.Coopanion.Url $zip $SRC.Coopanion.Name) }
        if ($zip -and (Test-Path $zip) -and -not $DryRun) {
            if (Test-Path $CoopanionPath) { Move-Item $CoopanionPath "$CoopanionPath.old-$stamp" -Force -ErrorAction SilentlyContinue }
            Expand-Zip $zip $CoopanionPath 'Coopanion'
            Flatten $CoopanionPath 'Coopanion.exe'
        }
    } else { Say '已安装（-Force 可重装）' 'skip' }

    Step '3. 注入 RVC 扩展与音色'
    $rvcDst   = Join-Path $CoopanionPath 'data\extensions\node_modules\@wocwang\cortico-world-rvc-for-coopanion'
    $rvcPatch = Join-Path $here 'patch\coopanion\rvc-extension'
    if ((Test-Path $rvcPatch) -and -not $DryRun) {
        New-Item -ItemType Directory -Path $rvcDst -Force | Out-Null
        robocopy $rvcPatch $rvcDst /E /NJH /NJS /NDL /NP | Out-Null
        Say 'RVC 扩展已注入（Demucs 分离 / 显存回收 / 人声门限）' 'ok'
    } elseif ($DryRun) { Say '将注入 RVC 扩展' 'todo' }

    $modelPatch = Join-Path $here 'patch\coopanion\rvc-data'
    $modelDst   = Join-Path $CoopanionPath 'data\home\companion\data\rvc'
    if ((Test-Path $modelPatch) -and -not $DryRun) {
        robocopy $modelPatch $modelDst /E /NJH /NJS /NDL /NP /XF *.bak | Out-Null
        Say '音色模型 + UVR5 + rmvpe 已注入' 'ok'
    } elseif ($DryRun) { Say '将注入音色与模型' 'todo' }

    Step '4. SnowLuma'
    $need = $Force -or ((-not (Test-Path (Join-Path $SnowLumaPath 'launcher.bat'))) -and (-not (Test-Path (Join-Path $SnowLumaPath 'SnowLuma.exe'))))
    if ($need) {
        $zip = $SnowLumaZip
        if (-not $zip) { $zip = Join-Path $tmp 'SnowLuma.zip'; [void](Get-Remote $SRC.SnowLuma.Url $zip $SRC.SnowLuma.Name) }
        if ($zip -and (Test-Path $zip) -and -not $DryRun) {
            if (Test-Path $SnowLumaPath) { Move-Item $SnowLumaPath "$SnowLumaPath.old-$stamp" -Force -ErrorAction SilentlyContinue }
            Expand-Zip $zip $SnowLumaPath 'SnowLuma'
        }
    } else { Say '已安装（-Force 可重装）' 'skip' }

    Step '5. SurfCore'
    $need = $Force -or -not (Test-Path (Join-Path $SurfcorePath 'src\bridge.js'))
    if ($need) {
        $zip = $SurfcoreZip
        if (-not $zip) { $zip = Join-Path $tmp 'surfcore.zip'; [void](Get-Remote $SRC.Surfcore.Url $zip $SRC.Surfcore.Name) }
        if ($zip -and (Test-Path $zip) -and -not $DryRun) {
            if (Test-Path $SurfcorePath) { Move-Item $SurfcorePath "$SurfcorePath.old-$stamp" -Force -ErrorAction SilentlyContinue }
            Expand-Zip $zip $SurfcorePath 'SurfCore'
        }
    } else { Say '已安装（-Force 可重装）' 'skip' }

    Step '6. 注入方括号命令过滤'
    $sfPatch = Join-Path $here 'patch\surfcore'
    if (-not $DryRun) {
        foreach ($pair in @(
            @{src='command-spam.js'; dst="$SurfcorePath\src\command-spam.js"},
            @{src='bridge.js';       dst="$SurfcorePath\src\bridge.js"}
        )) {
            $s = Join-Path $sfPatch $pair.src
            if (Test-Path $s) { Backup $pair.dst; Copy-Item $s $pair.dst -Force; Say "$($pair.src) 已覆盖（含方括号过滤）" 'ok' }
        }
        $cfg = "$SurfcorePath\config.json"
        if (-not (Test-Path $cfg) -and (Test-Path (Join-Path $sfPatch 'config.template.json'))) {
            Copy-Item (Join-Path $sfPatch 'config.template.json') $cfg -Force
            Say 'config.json 已生成模板（需填机器人账号）' 'warn'
        } elseif (Test-Path $cfg) { Say 'config.json 已存在，保留不动' 'skip' }
    } else { Say '将注入方括号过滤补丁' 'todo' }
} else { Step '2-6. 原版软件（-SkipVendor，跳过）' }

Step '7. 点歌脚本'
$stateDir = Join-Path $SurfcorePath 'state'
if (-not $DryRun) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    robocopy (Join-Path $here 'patch\runtime') $stateDir /E /NJH /NJS /NDL /NP | Out-Null
    Say "点歌脚本 -> $stateDir" 'ok'
} else { Say "将复制点歌脚本 -> $stateDir" 'todo' }

Step '8. DDSP-SVC（约 800 MB）'
if (-not $DryRun) {
    New-Item -ItemType Directory -Path $DdspPath -Force | Out-Null
    robocopy (Join-Path $here 'ddsp') $DdspPath /E /NJH /NJS /NDL /NP /XD .git __pycache__ cache tmp | Out-Null
    Say 'DDSP-SVC 就位（ContentVec / NSF-HiFiGAN / RMVPE / 音色模型）' 'ok'
} else { Say "将复制 DDSP -> $DdspPath" 'todo' }

Step '9. 配置'
if ($OwnerQQ) {
    if (-not $DryRun) { [Environment]::SetEnvironmentVariable('SC_OWNER', $OwnerQQ, 'User'); Say "SC_OWNER=$OwnerQQ" 'ok' }
    else { Say "将设置 SC_OWNER=$OwnerQQ" 'todo' }
} else { Say '没给 -OwnerQQ，稍后：setx SC_OWNER "你的QQ号"' 'warn' }
if (-not $DryRun) {
    [Environment]::SetEnvironmentVariable('SONG_DDSP_DIR', $DdspPath, 'User')
    [Environment]::SetEnvironmentVariable('SONG_ENGINE', 'ddsp', 'User')
    Say 'SONG_DDSP_DIR / SONG_ENGINE 已写入' 'ok'
}

Step '10. 清理'
if ((Test-Path $tmp) -and -not $DryRun) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; Say '临时文件已清理' 'ok' }

Step '11. 启动'
if ($Start -and -not $DryRun) {
    $mp = Join-Path $stateDir 'music-plugin.ps1'
    if (Test-Path $mp) { & powershell -NoProfile -ExecutionPolicy Bypass -File $mp start }
} else { Say '加 -Start 可装完直接起服务' 'skip' }

Step '汇总'
if ($DryRun) { Write-Host "  DryRun 结束" -ForegroundColor Yellow }
elseif ($script:Fails.Count -eq 0) {
    Write-Host "  安装完成" -ForegroundColor Green
    Write-Host ""
    Write-Host "  还要手动做三步：" -ForegroundColor Cyan
    Write-Host "   1. 打开 $CoopanionPath\Coopanion.exe，等 RVC 变声页就绪"
    Write-Host "   2. 打开 $SnowLumaPath，扫码登录 QQ"
    Write-Host "   3. 在 $SurfcorePath 跑 npm install，然后双击 start.bat"
    Write-Host ""
    Write-Host "  自检：.\verify.ps1 -StateDir `"$stateDir`"" -ForegroundColor Gray
} else {
    Write-Host "  有 $($script:Fails.Count) 项失败：" -ForegroundColor Red
    $script:Fails | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
}
if ($script:Warns.Count) {
    Write-Host "  提醒：" -ForegroundColor Yellow
    $script:Warns | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
}
if ($script:Fails.Count -gt 0) { exit 1 } else { exit 0 }