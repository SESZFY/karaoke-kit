# 大肥鱼点歌翻唱全套 · 一键安装器

QQ 群里发 `【唱】歌名`，机器人下载音源 → 分离伴奏 → 洛天依翻唱 → 分 60 秒一段发回来。
引擎是 **DDSP-SVC ReFlow**，3 分钟的歌约 **2 分钟**出结果。

---

## 这个包不含原版软件

包内只有**补丁 + 模型 + 引擎**（约 1.9 GB）。原版软件在安装时从官方 GitHub Releases 自动下载：

| 软件 | 下载源 | 大小 |
|---|---|---|
| Coopanion | `Pal-AI-Lab/Coopanion` v0.2.18 便携版 | 220 MB |
| SnowLuma | `SnowLuma/SnowLuma` v2.4.2 win-x64 | 220 MB |
| SurfCore | `mieksido/surfcore` main 分支 | 2 MB |

联网即可。不想联网就用 `-Offline` + 本地 zip。

---

## 包内有什么

```
patch/coopanion/rvc-extension/    RVC 扩展（已改：Demucs 分离 / 显存回收 / 人声门限）
patch/coopanion/rvc-data/         洛天依音色 + rmvpe + UVR5 模型   1.17 GB
patch/surfcore/                   command-spam.js / bridge.js / config 模板（方括号过滤）
patch/runtime/                    点歌脚本八件套（song-rvc.py 带 DDSP 引擎）
ddsp/                             DDSP-SVC 全套 + ContentVec + NSF-HiFiGAN + RMVPE + 音色   797 MB
install.ps1 / verify.ps1 / uninstall.ps1 / README.md
```

---

## 前置要求

| 依赖 | 说明 |
|---|---|
| Windows 10/11 | |
| NVIDIA 显卡 | 8 GB 显存起 |
| Python 3.10+ | 需在 PATH，装 `yt-dlp` |
| ffmpeg | 需在 PATH |
| Node.js 18+ | SurfCore 需要 |
| 磁盘 | 约 8 GB 空闲 |

```powershell
python -m pip install -U yt-dlp
winget install Gyan.FFmpeg
winget install OpenJS.NodeJS.LTS
```

---

## 安装

**方式一：双击 exe**

```
点歌翻唱全套-安装器.exe
```

会提示确认，然后自动下载原版 + 注入补丁 + 复制引擎。

**方式二：命令行（可控）**

```powershell
.\install.ps1 -DryRun                        # 只看会做什么
.\install.ps1 -OwnerQQ 123456789             # 正式装
.\install.ps1 -OwnerQQ 123456789 -Start      # 装完直接起服务
.\install.ps1 -Force                         # 已装也重装（原版会重新下载）
.\install.ps1 -SkipVendor                    # 只装补丁和引擎，不动原版
.\install.ps1 -Offline -CoopanionZip "D:\dl\Coopanion.zip"   # 离线装
```

**装完手动三步**（脚本代劳不了）：

1. 打开 `D:\Coopanion\Coopanion.exe`，等「RVC 变声」页显示引擎就绪
2. 打开 SnowLuma，扫码登录 QQ
3. 在 SurfCore 目录 `npm install`，然后双击 `start.bat`

**自检**：

```powershell
.\verify.ps1
```

---

## 使用

群里发（**必须带方括号**）：

```
【唱】稻香
【唱】BV1CX4y187Gu
【唱】https://www.bilibili.com/video/BV1CX4y187Gu
```

`【唱】` / `[唱]` / `[sing]` 三种；**`唱《稻香》` 不认**（防聊天误触发）。

只有主人（`-OwnerQQ`）能用。

---

## 调参

```powershell
setx SONG_ENGINE ddsp        # ddsp（默认）/ rvc（切回老链路）
setx DDSP_STEP 40            # 采样步数：20 快 / 40 平衡 / 60 好
setx DDSP_HIGHPASS 380       # 人声高通，削低八度误判
setx DDSP_GAIN 2.0           # 人声音量
setx DDSP_INST_GAIN 0.65     # 伴奏音量
```

改完重启 song-rvc。

---

## 卸载

```powershell
.\uninstall.ps1               # 停服务 + 删脚本和 DDSP
.\uninstall.ps1 -KeepDdsp     # 保留 DDSP（重装省 800 MB）
.\uninstall.ps1 -RemoveVendor # 连原版软件一起删
```

音色、聊天记录、点歌缓存都保留。

---

## 已知限制

| 问题 | 原因 |
|---|---|
| 清唱段气声被填成实音 | DDSP-SVC 训练数据倾向实音（模型固有，可切 RVC 规避） |
| 极高音偶尔低八度 | rmvpe 在混合信号上判断不稳（380 Hz 高通已规避大部分） |
| 分离偶尔把主唱高音分到伴奏 | 三套分离引擎一致的边界判断，会让那句听感"变薄" |

---

**版权**：Coopanion / SnowLuma / SurfCore 为第三方软件，遵循各自许可；音色模型仅供个人学习，不要商用或传播。
