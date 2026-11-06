#requires -Version 5.1
<#
.SYNOPSIS
    QQ 点歌翻唱套件 —— 全自动安装（幂等，可反复执行）

.DESCRIPTION
    探测 Coopanion / SurfCore / SnowLuma 路径，拷贝服务脚本，打 4 处补丁，拉起服务，再自检。
    每处补丁都会先备份 <file>.bak-<时间戳>，已打过的一律跳过。

.EXAMPLE
    .\install.ps1 -Auto -DryRun      # 只报告将做什么，不改任何文件
    .\install.ps1 -Auto              # 正式安装
    .\install.ps1 -Auto -Start       # 装完直接起服务
    .\install.ps1 -Auto -CoopanionPath "D:\Coopanion" -SurfcorePath "D:\surfcore"
#>
[CmdletBinding()]
param(
    [switch]$Auto,                      # 无交互模式（探测不到就报错，不提问）
    [switch]$DryRun,                    # 只打印，不落盘
    [string]$Target,                    # 服务目录（默认 <Surfcore>\state）
    [string]$CoopanionPath,
    [string]$SurfcorePath,
    [string]$SnowLumaPath,
    [switch]$SkipSurfcore,
    [switch]$SkipCoopanion,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Fails = @()
$script:Warns = @()

function Say([string]$msg, [string]$level = 'info') {
    switch ($level) {
        'ok'   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
        'skip' { Write-Host "  [SKIP] $msg" -ForegroundColor DarkGray }
        'warn' { Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:Warns += $msg }
        'err'  { Write-Host "  [FAIL] $msg" -ForegroundColor Red;    $script:Fails += $msg }
        'todo' { Write-Host "  [TODO] $msg" -ForegroundColor Cyan }
        default { Write-Host "  $msg" }
    }
}

function Step([string]$t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

function Backup-File([string]$path) {
    if ($DryRun) { Say "将备份 $path -> .bak-$stamp" 'todo'; return }
    $bak = "$path.bak-$stamp"
    Copy-Item $path $bak -Force
    Say "已备份 -> $(Split-Path -Leaf $bak)"
}

# ── 探测 ────────────────────────────────────────────────
function Find-Coopanion {
    if ($CoopanionPath) {
        if (Test-Path (Join-Path $CoopanionPath 'Coopanion.exe')) { return $CoopanionPath }
        throw "指定的 CoopanionPath 里没有 Coopanion.exe：$CoopanionPath"
    }
    $cands = @(
        'D:\Coopanion', 'C:\Coopanion',
        'C:\Program Files\Coopanion', 'C:\Program Files (x86)\Coopanion',
        "$env:LOCALAPPDATA\Programs\Coopanion"
    )
    foreach ($c in $cands) {
        if (Test-Path (Join-Path $c 'Coopanion.exe')) { return $c }
    }
    foreach ($root in @('D:\', 'C:\')) {
        $hit = Get-ChildItem $root -Filter 'Coopanion.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return (Split-Path -Parent $hit.FullName) }
    }
    return $null
}

function Find-Surfcore {
    if ($SurfcorePath) {
        if (Test-Path (Join-Path $SurfcorePath 'src\bridge.js')) { return $SurfcorePath }
        throw "指定的 SurfcorePath 里没有 src\bridge.js：$SurfcorePath"
    }
    foreach ($c in @('D:\surfcore', 'C:\surfcore', "$env:USERPROFILE\surfcore")) {
        if (Test-Path (Join-Path $c 'src\bridge.js')) { return $c }
    }
    return $null
}

function Find-SnowLuma {
    if ($SnowLumaPath) { return $SnowLumaPath }
    $cands = @(
        'D:\大肥鱼的实验室\SnowLuma',
        'D:\SnowLuma', 'C:\SnowLuma',
        "$env:USERPROFILE\SnowLuma"
    )
    foreach ($c in $cands) {
        if (Test-Path (Join-Path $c 'config')) { return $c }
    }
    return $null
}

# ── 补丁 1：command-spam.js ─────────────────────────────
function Patch-CommandSpam([string]$surfcore) {
    $dst = Join-Path $surfcore 'src\command-spam.js'
    if (-not (Test-Path $dst)) { Say "找不到 $dst" 'err'; return }
    if ((Get-Content $dst -Raw -Encoding utf8) -match 'isBracketCommandText') {
        Say "command-spam.js 已含 isBracketCommandText" 'skip'; return
    }
    if ($DryRun) { Say "将覆盖 $dst（先备份）" 'todo'; return }
    Backup-File $dst
    Copy-Item (Join-Path $here 'surfcore-patch\command-spam.js') $dst -Force
    Say "command-spam.js 已替换" 'ok'
}

# ── 补丁 2：bridge.js（import + 插块）───────────────────
function Patch-Bridge([string]$surfcore) {
    $f = Join-Path $surfcore 'src\bridge.js'
    if (-not (Test-Path $f)) { Say "找不到 $f" 'err'; return }
    $raw = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
    if ($raw -match 'ignoreBracketCommands') { Say "bridge.js 已含过滤块" 'skip'; return }

    $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $oldImport = "import { isSpamCommandText } from './command-spam.js';"
    if (-not $raw.Contains($oldImport)) { Say "bridge.js 里找不到 command-spam 的 import 行" 'err'; return }

    $anchor = 'isSpamCommandText(plainContent)) {'
    $i = $raw.IndexOf($anchor)
    if ($i -lt 0) { Say "bridge.js 里找不到 # 短指令过滤块（anchor 未命中）" 'err'; return }
    $closePat = $nl + '    }' + $nl
    $j = $raw.IndexOf($closePat, $i)
    if ($j -lt 0) { Say "bridge.js 里定位不到过滤块结尾" 'err'; return }

    $block = @(
        ''
        '    // 方括号命令（【唱】歌名 / [sing] xxx / 【查询】xxx）：这是给外部插件的指令，桥接不参与。'
        '    // 主人发的也拦——不然点一首歌 AI 就接一次话。被 @ / 引用 / 直呼时仍按消息处理。'
        '    if (cfg.socialV2?.ignoreBracketCommands !== false'
        '        && !quoteTargetIsSelf && !isDirectAddress(plainContent, event, kind)'
        '        && isBracketCommandText(plainContent)) {'
        '      if (logThrottled(`ignore-bracket:${key}`, 10 * 60_000, `[bracket-cmd] 忽略 ${key} 的方括号命令：${plainContent.slice(0, 40)}`)) {'
        '        appendActivity(`${key} [忽略命令] ${displayName}：${plainContent.slice(0, 80)}（方括号命令不唤醒桥接）`);'
        '      }'
        '      return;'
        '    }'
    ) -join $nl

    if ($DryRun) {
        Say "将替换 import 行" 'todo'
        $lineNo = ($raw.Substring(0, $j) -split [regex]::Escape($nl)).Count
        Say "将在第 ~$lineNo 行后插入 12 行过滤块" 'todo'
        return
    }

    Backup-File $f
    $new = $raw.Replace($oldImport, "import { isSpamCommandText, isBracketCommandText } from './command-spam.js';")
    $insertAt = $j + $closePat.Length
    $new = $new.Insert($insertAt, $block)
    [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding($false)))
    Say "bridge.js 已插入过滤块（import + 12 行）" 'ok'
}

# ── 补丁 3：config.json ─────────────────────────────────
function Patch-Config([string]$surfcore) {
    $f = Join-Path $surfcore 'config.json'
    if (-not (Test-Path $f)) { Say "找不到 $f" 'err'; return }
    $raw = Get-Content $f -Raw -Encoding utf8
    $cfg = $raw | ConvertFrom-Json
    if ($cfg.socialV2 -and ($cfg.socialV2.PSObject.Properties.Name -contains 'ignoreBracketCommands')) {
        Say "config.json 已有 ignoreBracketCommands=$($cfg.socialV2.ignoreBracketCommands)" 'skip'; return
    }
    if ($DryRun) { Say "将在 socialV2 里加 ignoreBracketCommands=true" 'todo'; return }
    Backup-File $f
    $pat = '("ignoreSpamCommands"\s*:\s*(?:true|false)\s*,)'
    if ($raw -notmatch $pat) { Say "config.json 里找不到 ignoreSpamCommands，需手动加一行" 'err'; return }
    $new = $raw -replace $pat, ('$1' + "`r`n    " + '"ignoreBracketCommands": true,')
    [IO.File]::WriteAllText($f, $new, (New-Object Text.UTF8Encoding($false)))
    try { $null = (Get-Content $f -Raw -Encoding utf8 | ConvertFrom-Json); Say "config.json 已加开关（JSON 校验通过）" 'ok' }
    catch { Say "config.json 改完 JSON 不合法，已回滚备份" 'err'; Copy-Item "$f.bak-$stamp" $f -Force }
}

# ── 补丁 4：Coopanion RVC worker.py ─────────────────────
function Patch-Worker([string]$coopanion) {
    $rvc = Join-Path $coopanion 'data\extensions\node_modules\@wocwang\cortico-world-rvc-for-coopanion'
    $f = Join-Path $rvc 'src\python\worker.py'
    if (-not (Test-Path $f)) { Say "找不到 RVC worker：$f（Coopanion 没装 RVC 扩展？）" 'warn'; return }
    if ((Get-Content $f -Raw -Encoding utf8) -match '_release_vram') { Say "worker.py 已含 _release_vram" 'skip'; return }
    if ($DryRun) { Say "将覆盖 $f（先备份），然后需重启 RVC world" 'todo'; return }
    Backup-File $f
    Copy-Item (Join-Path $here 'coopanion-patch\worker.py') $f -Force
    Say "worker.py 已替换（需重启 RVC world 生效）" 'ok'
}

# ── 拷贝服务脚本 ────────────────────────────────────────
function Copy-Services([string]$target) {
    if ($DryRun) { Say "将把 core/ guard/ music-plugin/ 拷到 $target" 'todo'; return }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item (Join-Path $here 'core\song-rvc.py')         $target -Force
    Copy-Item (Join-Path $here 'core\song-cmd-poll.py')    $target -Force
    Copy-Item (Join-Path $here 'guard\song-guard.ps1')     $target -Force
    Copy-Item (Join-Path $here 'guard\song-rvc-guard.bat') $target -Force
    Copy-Item (Join-Path $here 'music-plugin\*')            $target -Force
    Say "服务脚本已拷到 $target" 'ok'
}

# ── 重启 RVC world ─────────────────────────────────────
function Restart-Rvc([string]$webui = 'http://127.0.0.1:17788') {
    if ($DryRun) { Say "将调 $webui/api/worlds/restart 重启 RVC" 'todo'; return }
    try {
        $r = Invoke-WebRequest "$webui/api/worlds/restart" -Method POST -Body '{"id":"rvc"}' `
            -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing
        Say "RVC world 已重启：$($r.Content)" 'ok'
    } catch { Say "重启 RVC 失败（Coopanion 没开？）：$($_.Exception.Message)" 'warn' }
}

# ══════════════════════════════════════════════════════
Write-Host "QQ 点歌翻唱套件 · 安装程序" -ForegroundColor White
if ($DryRun) { Write-Host "（DryRun：不会修改任何文件）" -ForegroundColor Yellow }

Step '1. 探测环境'
$coop = $null; $sc = $null; $sl = $null
if (-not $SkipCoopanion) {
    $coop = Find-Coopanion
    if ($coop) { Say "Coopanion: $coop" 'ok' } else { Say 'Coopanion 未找到（用 -CoopanionPath 指定）' 'err' }
}
if (-not $SkipSurfcore) {
    $sc = Find-Surfcore
    if ($sc) { Say "SurfCore: $sc" 'ok' } else { Say 'SurfCore 未找到（用 -SurfcorePath 指定）' 'err' }
    $sl = Find-SnowLuma
    if ($sl) { Say "SnowLuma: $sl" 'ok' } else { Say 'SnowLuma 未找到（不影响安装，只影响点歌监听读 token）' 'warn' }
}
if (-not $Target) {
    if ($sc) { $Target = Join-Path $sc 'state' }
    elseif ($env:SC_STATE_DIR) { $Target = $env:SC_STATE_DIR }
    else { $Target = 'D:\surfcore\state' }
}
Say "服务目录: $Target" 'ok'

Step '2. 依赖检查'
$missing = @()
foreach ($cmd in @('python', 'ffmpeg', 'ffprobe', 'yt-dlp')) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) { Say "$cmd 在 PATH" 'ok' }
    elseif ($cmd -eq 'ffprobe') { Say 'ffprobe 不在 PATH（song-rvc 用 wave 读时长兜底，不影响点歌）' 'warn' }
    else { $missing += $cmd; Say "$cmd 不在 PATH" 'err' }
}
if ($missing -contains 'yt-dlp') { Say '装 yt-dlp：python -m pip install -U yt-dlp' 'warn' }

Step '3. 拷贝服务脚本'
Copy-Services $Target

if (-not $SkipSurfcore -and $sc) {
    Step '4. SurfCore 补丁'
    Patch-CommandSpam $sc
    Patch-Bridge $sc
    Patch-Config $sc
} else { Step '4. SurfCore 补丁（跳过）' }

if (-not $SkipCoopanion -and $coop) {
    Step '5. Coopanion 补丁'
    Patch-Worker $coop
    if (-not $DryRun) { Restart-Rvc }
} else { Step '5. Coopanion 补丁（跳过）' }

Step '6. 环境变量'
if ($env:SC_OWNER) { Say "SC_OWNER=$env:SC_OWNER" 'ok' }
else { Say 'SC_OWNER 未设置（点歌监听需要它；setx SC_OWNER "你的QQ号"）' 'warn' }

if ($Start -and -not $DryRun) {
    Step '7. 启动服务'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Target 'music-plugin.ps1') start
}

Step '汇总'
if ($DryRun) {
    Write-Host "  DryRun 结束，未做任何修改。" -ForegroundColor Yellow
} elseif ($script:Fails.Count -eq 0) {
    Write-Host "  安装完成。" -ForegroundColor Green
    Write-Host "  下一步：.\verify.ps1 自检；或在 QQ 里发 【唱】稻香" -ForegroundColor Gray
} else {
    Write-Host "  有 $($script:Fails.Count) 项失败：" -ForegroundColor Red
    $script:Fails | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
}
if ($script:Warns.Count) {
    Write-Host "  提醒：" -ForegroundColor Yellow
    $script:Warns | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
}
if ($script:Fails.Count -gt 0) { exit 1 } else { exit 0 }
