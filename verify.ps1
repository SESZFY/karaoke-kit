#requires -Version 5.1
<#
.SYNOPSIS
    点歌翻唱全套 —— 安装后自检（只读，不改任何东西）
.EXAMPLE
    .\verify.ps1
    .\verify.ps1 -StateDir "E:\surfcore\state"
#>
[CmdletBinding()]
param(
    [string]$CoopanionPath = "D:\Coopanion",
    [string]$SnowLumaPath  = "D:\大肥鱼的实验室\SnowLuma",
    [string]$SurfcorePath  = "D:\surfcore",
    [string]$StateDir      = "",
    [string]$DdspPath      = ""
)
$ErrorActionPreference = 'Continue'
if (-not $StateDir) { $StateDir = Join-Path $SurfcorePath 'state' }
if (-not $DdspPath) { $DdspPath = Join-Path $StateDir 'ddsp-svc' }

$pass = 0; $warn = 0; $fail = 0
function Ok([string]$m)   { Write-Host "  [PASS] $m" -ForegroundColor Green;  $script:pass++ }
function Wn([string]$m)   { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:warn++ }
function No([string]$m)   { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:fail++ }
function Head([string]$t) { Write-Host ""; Write-Host "-- $t" -ForegroundColor Cyan }

Write-Host "点歌翻唱全套 · 自检  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White

Head '1. 程序本体'
foreach ($p in @(
    @{n='Coopanion 主程序'; p="$CoopanionPath\Coopanion.exe"},
    @{n='RVC 扩展';         p="$CoopanionPath\data\extensions\node_modules\@wocwang\cortico-world-rvc-for-coopanion\src\python\worker.py"},
    @{n='RVC 音色模型';     p="$CoopanionPath\data\home\companion\data\rvc\voices\luotianyi.pth"},
    @{n='UVR5 分离模型';    p="$CoopanionPath\data\home\companion\data\rvc\uvr5\UVR-MDX-NET-Inst_HQ_3.onnx"},
    @{n='SnowLuma 主程序';  p="$SnowLumaPath"},
    @{n='SurfCore 源码';    p="$SurfcorePath\src\bridge.js"},
    @{n='SurfCore 配置';    p="$SurfcorePath\config.json"},
    @{n='SurfCore 依赖';    p="$SurfcorePath\node_modules"}
)) {
    if (Test-Path $p.p) { Ok $p.n } else { No "$($p.n) 缺失：$($p.p)" }
}

Head '2. 修改是否到位'
$wk = "$CoopanionPath\data\extensions\node_modules\@wocwang\cortico-world-rvc-for-coopanion\src\python\worker.py"
if (Test-Path $wk) {
    $w = Get-Content $wk -Raw -Encoding UTF8
    if ($w -match '_release_vram') { Ok 'RVC worker：显存回收已注入' } else { Wn 'RVC worker：没找到 _release_vram（可能是原版）' }
    if ($w -match 'def _vocal_gate') { Ok 'RVC worker：人声门限已注入' } else { Wn 'RVC worker：没找到 _vocal_gate' }
    if ($w -match 'class DemucsSeparator') { Ok 'RVC worker：Demucs 分离器已注入' } else { Wn 'RVC worker：没找到 DemucsSeparator' }
}
$cs = "$SurfcorePath\src\command-spam.js"
if (Test-Path $cs) {
    if ((Get-Content $cs -Raw -Encoding UTF8) -match 'isBracketCommandText') { Ok 'SurfCore：方括号命令过滤已注入' }
    else { Wn 'SurfCore：没找到 isBracketCommandText' }
}
$bj = "$SurfcorePath\src\bridge.js"
if (Test-Path $bj) {
    if ((Get-Content $bj -Raw -Encoding UTF8) -match 'isBracketCommandText') { Ok 'SurfCore：bridge 已接入过滤' }
    else { Wn 'SurfCore：bridge 里没接入 isBracketCommandText' }
}

Head '3. 点歌脚本'
foreach ($f in @('song-rvc.py','song-cmd-poll.py','song-guard.ps1','music-plugin.ps1','song-control.ps1')) {
    if (Test-Path (Join-Path $StateDir $f)) { Ok $f } else { No "$f 缺失" }
}
if (Test-Path (Join-Path $StateDir 'song-rvc.py')) {
    $s = Get-Content (Join-Path $StateDir 'song-rvc.py') -Raw -Encoding UTF8
    if ($s -match 'SONG_ENGINE') { Ok 'song-rvc：引擎开关已就位' } else { Wn 'song-rvc：没有 SONG_ENGINE' }
    if ($s -match 'def ddsp_convert') { Ok 'song-rvc：DDSP 调用已就位' } else { Wn 'song-rvc：没有 ddsp_convert' }
}

Head '4. DDSP-SVC'
foreach ($p in @(
    @{n='流水线脚本';   p="$DdspPath\ddsp_sing.py"},
    @{n='Reflow 入口';  p="$DdspPath\run_reflow.py"},
    @{n='音色模型';     p="$DdspPath\exp\reflow-luotyxx\model_350000-luo.pt"},
    @{n='ContentVec';   p="$DdspPath\pretrain\contentvec\checkpoint_best_legacy_500.pt"},
    @{n='NSF-HiFiGAN';  p="$DdspPath\pretrain\nsf_hifigan\model"},
    @{n='RMVPE';        p="$DdspPath\pretrain\rmvpe\model.pt"}
)) { if (Test-Path $p.p) { Ok $p.n } else { No "$($p.n) 缺失：$($p.p)" } }

Head '5. 外部依赖'
foreach ($c in @('python','ffmpeg','yt-dlp','node')) {
    $g = Get-Command $c -ErrorAction SilentlyContinue
    if ($g) { Ok "$c → $($g.Source)" } else { No "$c 不在 PATH" }
}
$rvcPy = "D:\Coopanion\data\home\companion\data\rvc\venv\Scripts\python.exe"
if (Test-Path $rvcPy) {
    $t = & $rvcPy -c "import torch,sys;print(torch.__version__, torch.cuda.is_available())" 2>&1
    if ("$t" -match 'True') { Ok "RVC venv torch：$t" } else { Wn "RVC venv torch：$t（CUDA 不可用）" }
    $d = & $rvcPy -c "import demucs;print(demucs.__version__)" 2>&1
    if ("$d" -notmatch 'Error|No module') { Ok "demucs：$d" } else { No "demucs 未安装（pip install demucs）" }
} else { No "RVC venv 不存在：$rvcPy" }

Head '6. 服务状态'
foreach ($p in @(9883,9881,3000)) {
    $c = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue
    if ($c) { Ok "端口 $p 监听中" } else { Wn "端口 $p 未监听" }
}
try {
    $h = Invoke-RestMethod 'http://127.0.0.1:9883/health' -TimeoutSec 5
    if ($h.ok) { Ok "song-rvc 健康：$($h.rvc.model) queue=$($h.rvc.queue)" } else { Wn 'song-rvc 返回不健康' }
} catch { Wn 'song-rvc 无响应（服务没起？）' }

Head '7. 环境变量'
foreach ($v in @('SONG_ENGINE','SONG_DDSP_DIR','SC_OWNER')) {
    $val = [Environment]::GetEnvironmentVariable($v, 'User')
    if ($val) { Ok "$v = $val" } else { Wn "$v 未设置" }
}

Write-Host ""
Write-Host "───────────────" -ForegroundColor DarkGray
Write-Host ("结果：{0} 通过, {1} 提醒, {2} 失败" -f $pass, $warn, $fail) -ForegroundColor White
if ($fail -eq 0 -and $warn -eq 0) { Write-Host "OVERALL: PASS" -ForegroundColor Green }
elseif ($fail -eq 0) { Write-Host "OVERALL: PASS (有提醒)" -ForegroundColor Yellow }
else { Write-Host "OVERALL: FAIL" -ForegroundColor Red }
if ($fail -gt 0) { exit 1 } else { exit 0 }
