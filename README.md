# QQ 大肥鱼点歌翻唱套件（Karaoke Kit）

在 QQ 群里发 `【唱】歌名`，机器人把整首歌用 **RVC 换声** 成指定音色（默认洛天依），
按 60 秒切段当语音发回来。整首 186 秒的歌大约 80~200 秒出结果。

配套还包含两块周边：

- **SurfCore 方括号命令过滤**：`【唱】…` 这类命令消息不再唤醒桥接的 AI（AI 不会每次点歌都接话）
- **Coopanion RVC 显存回收补丁**：长音频分片推理后把显存还给驱动，避免 8G 卡把 worker 顶崩

---

## 架构

```
QQ 群 / 私聊
   │  发【唱】xxx
   ▼
SnowLuma (OneBot HTTP :3000)  ──►  song-cmd-poll.py  (:9883 无，只是轮询进程)
                                      │  每 3 秒拉最近消息，挑【唱】开头且没见过的
                                      ▼
                                  song-rvc.py (:9883)
                                      │  ① 解析：BV 号/链接直连，否则 B 站搜索
                                      │  ② yt-dlp 下音源 → 44.1k 立体声 wav
                                      │  ③ 送 Coopanion RVC 插件 (:9881) /cover
                                      │     内部：UVR5 分离人声 → RVC 变声 → 加回伴奏
                                      ▼
                                  wav 字节（整首）
                                      │
                                      ▼
                                  song-cmd-poll 用 ffmpeg 切 60 秒/段
                                      │  record 消息逐条发回原会话
                                      ▼
                                  QQ 里收到 N 条语音
```

守护进程 `song-guard.ps1` 每 30 秒检查一次：

- `song-rvc.py` 不在 → 拉起
- `song-cmd-poll.py` 不在 → 拉起
- Coopanion 的 RVC 引擎 `ready=false`（worker 崩了）→ 调 `POST /api/worlds/restart {"id":"rvc"}` 重启（3 分钟冷却）

---

## 目录

| 路径 | 作用 |
|---|---|
| `core/song-rvc.py` | 搜源 / 下载 / RVC 换声 / 返回 wav（HTTP 服务，:9883） |
| `core/song-cmd-poll.py` | 轮询 QQ 消息，处理【唱】命令，切段发送 |
| `guard/song-guard.ps1` | 守护 + RVC 引擎自愈 |
| `guard/song-rvc-guard.bat` | 双击启动守护 |
| `music-plugin/music-plugin.ps1` | 启停/状态：`status` `start` `stop` `restart` |
| `music-plugin/*.bat` | 双击版启停 |
| `surfcore-patch/command-spam.js` | 【】命令识别（替换 SurfCore 的 `src/command-spam.js`） |
| `surfcore-patch/bridge-insert.md` | `src/bridge.js` 里要插入的 8 行 |
| `surfcore-patch/config-snippet.json` | `config.json` 的 socialV2 开关 |
| `surfcore-patch/restart.bat` | 修好的重启脚本（原版 UTF-8 中文注释会被 cmd 按 GBK 拆碎） |
| `coopanion-patch/worker.py` | 打了 empty_cache 的 RVC worker（覆盖同名文件） |

---

## 依赖

| 组件 | 说明 |
|---|---|
| **SnowLuma** | QQ 机器人网关，开 OneBot HTTP（默认 :3000），配置在 `config\onebot_*.json` |
| **Coopanion** | 提供 RVC 变声引擎（HTTP :9881）和 world 管理（webui :17788） |
| **Python 3.10+** | 跑两个 py |
| **ffmpeg / ffprobe** | 在 PATH 里（转码、切段） |
| **yt-dlp** | 在 PATH 里（下 B 站音频） |
| **RVC 音色模型** | 放 `Coopanion\data\home\companion\data\rvc\voices\`，`名字.pth` + `名字.index` |
| **UVR5 分离模型** | Coopanion RVC 插件页「一键安装」（约 64 MB） |

---

## 安装

```powershell
# 1. 拷文件（默认装到 D:\surfcore\state，可用 -Target 改）
.\install.ps1 -Target "D:\surfcore\state"

# 2. 设你的 QQ 号（点歌监听要用它来监听私聊）
setx SC_OWNER "你的QQ号"

# 3. 起服务
cd <Target>
powershell -ExecutionPolicy Bypass -File music-plugin.ps1 start
```

SurfCore 那两块手动改（它是别人项目的源码，不方便自动替换）：

1. `surfcore-patch/command-spam.js` → 覆盖 `你的surfcore\src\command-spam.js`
2. `surfcore-patch/bridge-insert.md` 里那 8 行 → 插到 `src/bridge.js` 的指定位置
3. `config.json` 的 `socialV2` 加一行 `"ignoreBracketCommands": true`
4. 重启桥接（用 `surfcore-patch/restart.bat`）

Coopanion 那块：`coopanion-patch/worker.py` 覆盖
`Coopanion\data\extensions\node_modules\@wocwang\cortico-world-rvc-for-coopanion\src\python\worker.py`，
然后在 Coopanion 里重启 RVC world（或调 `POST /api/worlds/restart {"id":"rvc"}`）。

---

## 环境变量

### song-cmd-poll.py

| 变量 | 默认 | 说明 |
|---|---|---|
| `SC_OWNER` | **必填** | 你的 QQ 号，监听私聊点歌 |
| `SC_ONEBOT_CONF` | `D:\大肥鱼的实验室\SnowLuma\config` | OneBot 配置目录（读 accessToken） |
| `SC_HTTP` | `http://127.0.0.1:3000` | OneBot HTTP 地址 |
| `SC_SONG` | `http://127.0.0.1:9883` | song-rvc 地址 |
| `SC_SECONDS` | `0` | 每首取多少秒，**0 = 整首** |
| `SC_SEGMENT` | `60` | 每段多少秒（QQ 语音条上限） |
| `SC_SEG_GAP` | `2.0` | 段间停顿秒数 |
| `SC_VOICE` | `luotianyi` | 音色名（对 `voices\` 目录里的 pth 名） |
| `SC_INTERVAL` | `3` | 轮询间隔秒 |

### song-rvc.py

| 变量 | 默认 | 说明 |
|---|---|---|
| `SONG_RVC_PORT` | `9883` | 监听端口 |
| `SONG_RVC_RVC` | `http://127.0.0.1:9881` | Coopanion RVC 地址 |
| `SONG_RVC_VOICE` | `luotianyi` | 默认音色 |
| `SONG_RVC_VOCAL_GAIN` | `5` | 人声增益 dB（-12~12），嫌伴奏盖过人声就调大 |
| `SONG_RVC_BLOCK` | `0` | 分块秒数；**0 = 一次性整首（快，但吃显存）**，显存紧就设 80 |
| `SONG_RVC_KEEP` | `1` | 1 = 保留下载的音源（同曲重播跳过下载）；0 = 用完即删 |
| `SONG_RVC_CACHE_MAX_MB` | `400` | 缓存上限，超了按最久没碰的删 |
| `SONG_RVC_YTDLP` | `yt-dlp` | yt-dlp 命令 |
| `SONG_RVC_FFMPEG` | `ffmpeg` | ffmpeg 命令 |

---

## 点歌写法

| 写法 | 效果 |
|---|---|
| `【唱】稻香` | B 站搜「稻香」，按标题/时长打分挑一条 |
| `【唱】BV1AyVz6XEYA` | 直连这个视频，跳过搜索 |
| `【唱】https://www.bilibili.com/video/BV1AyVz6XEYA` | 同上 |
| `【唱】https://b23.tv/xxxxx` | 跟一次重定向拿到 BV 号 |
| `[唱] xxx` / `[sing] xxx` | 半角写法同样认 |

搜索打分规则：标题含 `原唱/官方/MV/完整版/高音质/Hi-Res/无损/4K` +3；
含 `翻唱/伴奏/纯音乐/钢琴/吉他/教学/DJ/remix/鬼畜/搞笑/空耳/串烧/合集/reaction/解说/光遇/简谱` −8；
时长越接近 4 分钟加分；只收 60~600 秒的视频。

---

## 实测速度

| 音频长度 | 处理耗时 | 分段 |
|---|---|---|
| 60 秒 | 20~115 秒 | 1 段 |
| 124 秒整首 | 65~140 秒 | 3 段 |
| 186 秒整首 | 83~200 秒 | 3~4 段 |

RVC 单实例在这张 8G 卡上的实时率约 0.4~1.1×，随显存压力波动。
一首 3 分钟的歌要"稳定 1 分钟出"做不到；要快就把 `SC_SECONDS` 调小（只唱副歌）。

---

## 已知坑

1. **显存**：8G 卡同时跑 ComfyUI + RVC 时，worker 会攥着 4~5G 不放，长音频分片到后面就 OOM 退出（日志 `RVC worker 退出（4294967295）`）。对策：`coopanion-patch/worker.py` 的 empty_cache + 守护自愈 + `SONG_RVC_BLOCK=80`。
2. **B 站 412**：搜索接口对频率极敏感，两次搜索至少隔 6 秒，同词 24 小时缓存。
3. **`song-rvc-guard.bat` 老版本的判定是坏的**（`tasklist /FO CSV` 里没有命令行，`findstr song-rvc` 永远匹配不到），会每 30 秒重复拉起、抢 9883 端口。本套件里的 `song-guard.ps1` 已改成按命令行匹配。
4. **`restart.bat` 的编码**：UTF-8 保存的中文注释会被 cmd 按 GBK 解析，整行被拆成命令执行（报 `'src' is not recognized`）。本套件里是纯英文注释版。
5. **QQ 语音条单条上限 60 秒**，所以整首必须切段发；段间留 2 秒，否则容易被风控。

---

## 许可

自用脚本集合，随取随改。Coopanion / SnowLuma / SurfCore 是各自作者的作品，这里只放补丁和对接代码。
