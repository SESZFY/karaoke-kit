param(
    [Parameter(Mandatory = $true)][string]$Repo,    # 你的仓库，例如 yourname/karaoke-kit
    [Parameter(Mandatory = $true)][string]$Token,   # GitHub Personal Access Token（scope: repo）
    [string]$Branch = "main",
    [switch]$CreateIfMissing
)

$ErrorActionPreference = 'Stop'
# 这台机器上唯一能正常 init 的 git（PortableGit 那份在这台机器上创建 .git 会 Permission denied）
$git = if (Test-Path "D:\Coopanion\resources\app\mingit\cmd\git.exe") {
    "D:\Coopanion\resources\app\mingit\cmd\git.exe"
} else { "git" }

Set-Location $PSScriptRoot

if ($CreateIfMissing) {
    $name = ($Repo -split '/')[1]
    $body = @{ name = $name; private = $false; description = "QQ 点歌翻唱套件（song-rvc + 点歌监听 + SurfCore 过滤 + Coopanion 补丁）" } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod "https://api.github.com/user/repos" -Method POST -Body $body `
            -Headers @{ Authorization = "Bearer $Token"; "User-Agent" = "karaoke-kit"; Accept = "application/vnd.github+json" } `
            -ContentType "application/json"
        Write-Host "已创建仓库：$($r.full_name)" -ForegroundColor Green
    } catch {
        Write-Host "创建仓库跳过（可能已存在）：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

& $git remote remove origin 2>$null
& $git remote add origin "https://$Token@github.com/$Repo.git"
& $git push -u origin "HEAD:$Branch"

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "推送成功：https://github.com/$Repo" -ForegroundColor Green
    Write-Host "（token 已经写进 .git/config 的 remote 里，需要的话执行 git remote set-url origin https://github.com/$Repo.git 去掉）" -ForegroundColor Yellow
} else {
    Write-Host "推送失败，检查：仓库名对不对 / token 有没有 repo 权限 / 网络" -ForegroundColor Red
}
