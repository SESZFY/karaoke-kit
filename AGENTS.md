# AGENTS.md — 交给 AI 代理（DSH / Claude / Codex）的操作手册

这个仓库是一套 **QQ 点歌翻唱** 的本地工具集合。你在读这份文件，说明你要**自动安装、修改或排障**。
按下面顺序做，不要跳步。

---

## 0. 一句话说明

QQ 群里发 `【唱】歌名`，机器人用 Coopanion 的 RVC 引擎把整首歌换成指定音色，按 60 秒切段当语音发回去。
配套还有两块补丁：SurfCore 的方括号命令过滤（AI 不接话）、Coopanion RVC worker 的显存回收。

---

## 1. 先探测环境（不要假设路径）

| 需要什么 | 怎么找 |
|---|---|
| **Coopanion 安装目录** | 找 `Coopanion.exe`（常见 `D:\Coopanion`、`C:\Program Files\Coopanion`）；标记：同级有 `resources\app` |
| **RVC 扩展目录** | `<Coopanion>\data\extensions\node_modules\@wocwang\cortico-world-rvc-for-coopanion` |
| **音色目录** | `<Coopanion>\data\home\companion\data\rvc\voices`（`名字.pth` + `名字.index`） |
| **SurfCore 目录** | 含 `src\bridge.js` 和 `src\command-spam.js` 的目录（常见 `D:\surfcore`） |
| **SurfCore 配置** | `<SurfCore>\config.json`（`socialV2` 段在这） |
| **OneBot 配置** | `<SnowLuma>\config\onebot_*.json`（读 `accessToken`；SnowLuma 目录常见 `D:\大肥鱼的实验室\SnowLuma`） |
| **服务目录** | `<SurfCore>\state` 或 `$env:SC_STATE_DIR`（放 song-rvc.py / song-cmd-poll.py） |

用 `install.ps1 -Auto -DryRun` 可以先让脚本自己探测并**只报告不修改**。

---

## 2. 安装（一条命令）

```powershell
.\install.ps1 -Auto
```

`-Auto` 会依次做：

1. 探测上面所有路径（探测不到就问用户，不要自己编路径）
2. 检查依赖：`python`、`ffmpeg`、`ffprobe`、`yt-dlp`
3. 把 `core/`、`guard/`、`music-plugin/` 拷到服务目录
4. 打 4 处补丁（**幂等**：已打过会跳过，都会先备份 `.bak-<时间戳>`）：
   - `src/command-spam.js` ← 本仓库 `surfcore-patch/command-spam.js`
   - `src/bridge.js` ← 插 import + 插过滤块
   - `config.json` ← `socialV2.ignoreBracketCommands = true`
   - RVC `src/python/worker.py` ← 本仓库 `coopanion-patch/worker.py`
5. 拉起 song-rvc(:9883) + 点歌监听
6. 调 `verify.ps1` 自检

可选参数：

| 参数 | 作用 |
|---|---|
| `-DryRun` | 只打印将做什么，不改任何文件 |
| `-Target <dir>` | 服务目录 |
| `-CoopanionPath <dir>` / `-SurfcorePath <dir>` | 手动指定路径 |
| `-SkipSurfcore` / `-SkipCoopanion` | 跳过某块补丁 |
| `-Start` | 装完直接起服务 |

---

## 3. 验证

```powershell
.\verify.ps1
```

逐项输出 `PASS / FAIL`：

```
[PASS] song-rvc.py 进程在跑
[PASS] 点歌监听进程在跑
[PASS] 9883 /health 返回 ok
[PASS] 9881 Coopanion RVC ready=true
[PASS] OneBot 3000 可达
[PASS] SurfCore: command-spam.js 含 isBracketCommandText
[PASS] SurfCore: bridge.js 含过滤块
[PASS] SurfCore: config.json ignoreBracketCommands=true
[PASS] Coopanion: worker.py 含 _release_vram
[WARN] 显存剩余 < 1.5GB（长音频可能崩）
```

最后一行 `OVERALL: PASS/FAIL`。**FAIL 必须修完再交付。**

---

## 4. 回滚

```powershell
.\uninstall.ps1
```

停服务、删拷贝的脚本、用最近的 `.bak-*` 还原四处补丁（SurfCore 的三处 + Coopanion 的一处）。

---

## 5. 修改这个项目时遵守的规矩

1. **只动本仓库列出的文件**，第三方目录（Coopanion / SnowLuma / SurfCore）里**只允许**改这 4 个：
   `<SurfCore>\src\command-spam.js`、`<SurfCore>\src\bridge.js`、`<SurfCore>\config.json`、`<RVC扩展>\src\python\worker.py`
2. **每次改第三方文件前先备份**：`<file>.bak-<yyyyMMdd-HHmmss>`
3. **改动要幂等**：重复执行不能插入两遍（用标记串检测，例如 `ignoreBracketCommands`、`_release_vram`）
4. **不要提交密钥**：`config.json` 里有 QQ 号和 OneBot accessToken，任何改动只加键、不要整份复制到本仓库
5. **不要改音色模型**（`.pth` / `.index`）
6. **不要自动 `git push`**，除非用户明确要求

---

## 6. 排障速查

| 症状 | 原因 | 处置 |
|---|---|---|
| `【唱】` 完全没反应 | 点歌监听没跑 / OneBot 不通 | `music-plugin.ps1 start`；`verify.ps1` |
| 回了「没唱出来：RVC 返回 409」 | Coopanion RVC worker 崩了 | `POST http://127.0.0.1:17788/api/worlds/restart`，body `{"id":"rvc"}` |
| 日志 `RVC worker 退出（4294967295）` | 8G 显存 + 长音频分片 OOM | 打 `coopanion-patch/worker.py`；`SONG_RVC_BLOCK=80`；显存 <1.5G 时先重启 world |
| 搜索总失败 `412` | B 站搜索频率限制 | 已内置 6 秒节流 + 24h 缓存，别去掉 |
| 语音只发了一条 / 长度不对 | `SC_SEGMENT` 太大 | 设 60（QQ 语音条上限） |
| 人声被伴奏压住 | RVC 混音默认 0dB | `SONG_RVC_VOCAL_GAIN=5`（-12~12） |
| `restart.bat` 报 `'src' is not recognized` | UTF-8 中文注释被 cmd 按 GBK 解析 | 用本仓库的英文注释版 |
| `song-rvc-guard.bat` 每 30 秒重复拉起 | 老版用 `tasklist /FO CSV` 判定，永远匹配不到 | 用本仓库的 `song-guard.ps1` |

---

## 7. 运行时配置（环境变量）

见 `README.md` 的表格。最常改的三个：

```
SC_OWNER            必填，你的 QQ 号
SC_SECONDS          0 = 整首；数字 = 只唱那么多秒
SONG_RVC_VOCAL_GAIN 人声增益 dB（默认 5）
SONG_RVC_BLOCK      0 = 一次性整首（快、吃显存）；80 = 分块（稳、慢一倍）
```

---

## 8. 交付前自查

- [ ] `verify.ps1` 全 PASS（WARN 可接受，但要报告给用户）
- [ ] 群里发一条 `【唱】稻香`，能在 3 分钟内收到语音
- [ ] 发 `【唱】https://www.bilibili.com/video/BVxxxx` 能直连（不搜）
- [ ] SurfCore 里 AI 不会对方括号命令接话
- [ ] 没有把 token / accessToken 写进任何提交
