#!/usr/bin/env python3
"""
song-rvc —— 「唱某首歌」：搜音源 → 下载 → RVC 换成本机音色 → 返回音频。

和 singer 的「自动编旋律」不同，这个走的是**原曲原调**：它找到那首歌的真实录音，
把人声分离出来、换成桌宠的音色，所以旋律节奏都是原唱的。

接口（默认 127.0.0.1:9883）：
    GET  /health
    POST /sing-song   {"query":"雨爱 杨丞琳", "voice":"daifeiyu", "maxSeconds":60,
                       "separator":true, "base64":false}
                      → audio/wav（或 {"audioBase64":...}）

搜源走 yt-dlp 的 bilisearch；下载只取音频流；换音色调本机 RVC 插件（:9881）。

环境变量：
    SONG_RVC_PORT       默认 9883
    SONG_RVC_RVC        默认 http://127.0.0.1:9881
    SONG_RVC_CACHE      默认 <本文件目录>/song-cache
    SONG_RVC_YTDLP      默认 yt-dlp
    SONG_RVC_FFMPEG     默认 ffmpeg
"""
from __future__ import annotations

import concurrent.futures
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("SONG_RVC_PORT", "9883"))
RVC = os.environ.get("SONG_RVC_RVC", "http://127.0.0.1:9881").rstrip("/")
HERE = Path(__file__).resolve().parent
CACHE = Path(os.environ.get("SONG_RVC_CACHE") or (HERE / "song-cache"))
YTDLP = os.environ.get("SONG_RVC_YTDLP", "yt-dlp")
FFMPEG = os.environ.get("SONG_RVC_FFMPEG", "ffmpeg")
# 整首翻唱混音时的人声增益(dB)。UVR5 分出来的伴奏保留了原曲母带响度，而 RVC 出来的是干声，
# 按 RMS 对齐后叠上去人声会发闷发小。默认 +5dB；还嫌小就 SONG_RVC_VOCAL_GAIN=7 再跑。
VOCAL_GAIN = float(os.environ.get("SONG_RVC_VOCAL_GAIN", "3.5"))
# 音域适配：# protect 越高越能保住清辅音/气声，减少高音区的破音和齿音拉丝
PROTECT = float(os.environ.get("SONG_RVC_PROTECT", "0.5"))
# 响度包络混合：1.0 = 完全用转换后的包络（高音容易突然冲出来），0.25 更贴原唱动态
RMS_MIX = float(os.environ.get("SONG_RVC_RMS_MIX", "0.25"))
# 索引率 0..1：越高越贴音色，但高音区检索容易串味、发刺。点歌默认压到 0.2
INDEX_RATE = float(os.environ.get("SONG_RVC_INDEX_RATE", "0.1"))
# 变调（半音）：+12 = 升八度，-12 = 降八度。0 为原调。
# 升八度相当于让模型用更低的发声位置去唱，极高音会轻松很多；八度是和谐音程，
# 所以人声升八度和原调伴奏叠在一起还能听（不像升 5 个半音那么怪）。
PITCH = int(os.environ.get("SONG_RVC_PITCH", "0"))

# ── 演唱引擎 ────────────────────────────────────────────
# ddsp = DDSP-SVC ReFlow（音质好、快），rvc = 老的 RVC /cover 链路（可随时切回）
ENGINE = os.environ.get("SONG_ENGINE", "ddsp").strip().lower()
DDSP_DIR = os.environ.get("SONG_DDSP_DIR", r"D:\surfcore\state\ddsp-svc")
DDSP_PY = os.environ.get("SONG_DDSP_PY", r"D:\Coopanion\data\home\companion\data\rvc\venv\Scripts\python.exe")
DDSP_STEP = int(os.environ.get("DDSP_STEP", "40"))
DDSP_HIGHPASS = float(os.environ.get("DDSP_HIGHPASS", "380"))
# 高音柔化：deesser 压齿音 + 7kHz 以上轻降，专治高音"尖/刺/炸"
HIGH_SOFTEN = os.environ.get("SONG_RVC_SOFTEN", "1") == "1"
DEESS_I = float(os.environ.get("SONG_RVC_DEESS", "0.65"))
HIGH_SHELF_DB = float(os.environ.get("SONG_RVC_HIGHSHELF_DB", "-2"))
# 磁盘策略：默认不留原音源和成品（一首歌的原 wav 就 40~50MB，攒几十首就是几个 G）。
# SONG_RVC_KEEP=1 才保留（重复点同一首能跳过下载，但会一直占地）。
KEEP_CACHE = os.environ.get("SONG_RVC_KEEP", "1") == "1"
# 缓存总上限（MB），超了按最久没碰过的顺序删。0 = 不限。
CACHE_MAX_MB = float(os.environ.get("SONG_RVC_CACHE_MAX_MB", "400"))
# 整首翻唱的分块长度（秒）。0 = 不分块，一次整首交给 /cover（1:22 之前就是这个模式，
# 最快：140 秒左右出整首）。分块是为了避开 8G 显存被顶爆；显存够的时候没必要分。
# 崩了由守护（song-guard.ps1）自动重启 RVC 引擎。
BLOCK_SECONDS = float(os.environ.get("SONG_RVC_BLOCK", "0"))
FFPROBE = os.environ.get("SONG_RVC_FFPROBE", "ffprobe")

# 音源质量打分用：这些词出现加分（原版/官方/完整），出现减分（翻唱/伴奏/教学/纯音乐）
GOOD_WORDS = ("原唱", "官方", "MV", "完整版", "高音质", "Hi-Res", "无损", "4K")
BAD_WORDS = ("翻唱", "伴奏", "纯音乐", "钢琴", "吉他", "教学", "教程", "DJ", "remix",
             "鬼畜", "搞笑", "空耳", "串烧", "合集", "reaction", "解说", "光遇", "简谱")

LOCK = threading.Lock()


def log(msg: str) -> None:
    sys.stderr.write(f"[song-rvc] {msg}\n")
    sys.stderr.flush()


def prune_cache() -> None:
    """缓存超过 CACHE_MAX_MB 就按最久未修改的顺序删，直到降回上限以下。"""
    if CACHE_MAX_MB <= 0 or not CACHE.exists():
        return
    try:
        files = [p for p in CACHE.rglob("*") if p.is_file()]
    except OSError:
        return
    total = 0
    for p in files:
        try:
            total += p.stat().st_size
        except OSError:
            pass
    limit = CACHE_MAX_MB * 1024 * 1024
    if total <= limit:
        return
    before = total
    for p in sorted(files, key=lambda x: x.stat().st_mtime if x.exists() else 0):
        if total <= limit:
            break
        try:
            size = p.stat().st_size
            p.unlink()
            total -= size
        except OSError:
            pass
    log(f"缓存清理：{before/1024/1024:.0f} MB → {total/1024/1024:.0f} MB（上限 {CACHE_MAX_MB:.0f} MB）")


def run(cmd: list[str], timeout: int = 600) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


def clean_query(q: str) -> str:
    """把「《稻香》 周杰伦 原唱 完整版」洗成「稻香 周杰伦」，B 站搜索才搜得到。"""
    s = str(q or "").strip()
    s = re.sub(r"[《》＜＞<>「」『』\"'“”‘’]", " ", s)
    s = re.sub(r"(原唱|原版|完整版|官方版?|高清|无损|高音质|MV|mv|4K|4k|Hi-?Res|hi-?res|"
               r"伴奏|翻唱|纯音乐|KTV|ktv|歌词版?|动态谱|简谱)", " ", s)
    s = re.sub(r"\s{2,}", " ", s).strip()
    return s or str(q or "").strip()


# 直接给链接/番号时跳过搜索：BV 号、bilibili.com/video/BVxxx、b23.tv 短链
BV_RE = re.compile(r"(BV[0-9A-Za-z]{10})", re.I)
B23_RE = re.compile(r"https?://b23\.tv/[A-Za-z0-9]+", re.I)


def parse_bvid(text: str) -> str:
    """从用户输入里抠出 BV 号；没有就返回空串。"""
    m = BV_RE.search(str(text or ""))
    if m:
        return m.group(1)
    m = B23_RE.search(str(text or ""))
    if m:
        # 短链先跟一次重定向拿到真实地址，再抠 BV 号
        try:
            req = urllib.request.Request(m.group(0), method="HEAD",
                                         headers={"User-Agent": _BILI_UA})
            with urllib.request.urlopen(req, timeout=12) as r:
                real = r.geturl()
            m2 = BV_RE.search(real)
            if m2:
                return m2.group(1)
        except Exception as e:
            log(f"短链解析失败：{str(e)[:80]}")
    return ""


def probe_video(vid: str) -> dict:
    """已知 BV 号：只取标题和时长，不进搜索。"""
    title, dur = vid, 0.0
    try:
        p = run([YTDLP, "--no-warnings", "--skip-download", "--print",
                 "%(title)s\t%(duration)s", f"https://www.bilibili.com/video/{vid}"], 120)
        for line in (p.stdout or "").splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                title = parts[0] or vid
                try:
                    dur = float(parts[1])
                except ValueError:
                    dur = 0.0
                break
    except Exception as e:
        log(f"取视频信息失败 {vid}：{str(e)[:80]}")
    return {"id": vid, "title": title, "duration": dur, "score": 999.0}


_SEARCH_THROTTLE = 6.0
_SEARCH_CACHE_TTL = 86400
_search_state = {"last": 0.0}
_search_cache: dict = {}


def search(query: str, limit: int = 10) -> list[dict]:
    """B 站搜索：全局节流 + 412 退避 + 结果缓存。

    这个接口对频率极敏感：一秒内连发几个请求，后面全部回 412 Precondition Failed。
    所以两次搜索之间强制间隔 6 秒，同一个词 24 小时内只搜一次，失败等 4/8 秒再试。
    """
    hit = _search_cache.get(query)
    if hit and time.time() - hit[0] < _SEARCH_CACHE_TTL:
        return hit[1]
    wait = _SEARCH_THROTTLE - (time.time() - _search_state["last"])
    if wait > 0:
        log(f"搜索节流，等 {wait:.1f}s（B 站会 412）")
        time.sleep(wait)
    try:
        cleaned = clean_query(query)
        words = [w for w in cleaned.split() if w]
        variants = []
        for v in (cleaned,
                  " ".join(reversed(words)) if len(words) > 1 else "",
                  words[0] if words else "",
                  str(query or "").strip()):
            if v and v not in variants:
                variants.append(v)
        for q in variants:
            for attempt, backoff in enumerate((4.0, 8.0, 12.0), start=1):
                out = _search_api(q, limit) or _search_once(q, limit)
                if out:
                    _search_cache[query] = (time.time(), out)
                    log(f"搜索命中 «{q}» {len(out)} 条")
                    return out
                if attempt < 3:
                    log(f"«{q}» 没结果（可能 412），{backoff:.0f}s 后重试")
                    time.sleep(backoff)
        return []
    finally:
        _search_state["last"] = time.time()

_BILI_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
_bili_cookie: dict = {}


def _ensure_buvid3() -> str:
    """B 站搜索接口要有 buvid3 才不 412；访问首页拿一个。"""
    if _bili_cookie.get("buvid3"):
        return _bili_cookie["buvid3"]
    try:
        req = urllib.request.Request("https://www.bilibili.com/", headers={"User-Agent": _BILI_UA})
        with urllib.request.urlopen(req, timeout=15) as r:
            for line in (r.headers.get_all("Set-Cookie") or []):
                if line.startswith("buvid3="):
                    _bili_cookie["buvid3"] = line.split(";")[0].split("=", 1)[1]
                    break
    except Exception as e:
        log(f"拿 buvid3 失败：{e}")
    return _bili_cookie.get("buvid3", "")


def _parse_dur(s) -> float:
    """'4:30' 或 270 或 '1:02:03' → 秒。"""
    if isinstance(s, (int, float)):
        return float(s)
    parts = [p for p in str(s).split(":") if p.strip()]
    try:
        sec = 0.0
        for p in parts:
            sec = sec * 60 + float(p)
        return sec
    except ValueError:
        return 0.0


def _search_api(query: str, limit: int = 10) -> list[dict]:
    """B 站官方搜索接口（带 buvid3），比 yt-dlp 的爬虫稳，412 少得多。"""
    from urllib.parse import quote
    cookie = _ensure_buvid3()
    url = ("https://api.bilibili.com/x/web-interface/search/type"
           f"?search_type=video&keyword={quote(query)}&page=1&page_size={limit}")
    headers = {
        "User-Agent": _BILI_UA,
        "Referer": f"https://search.bilibili.com/all?keyword={quote(query)}",
        "Accept": "application/json, text/plain, */*",
    }
    if cookie:
        headers["Cookie"] = f"buvid3={cookie}"
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=25) as r:
            payload = json.loads(r.read() or b"{}")
    except Exception as e:
        log(f"官方搜索接口失败 «{query}»：{str(e)[:80]}")
        return []
    if payload.get("code") != 0:
        log(f"官方搜索返回 code={payload.get('code')} «{query}»")
        return []
    items = ((payload.get("data") or {}).get("result") or [])
    out = []
    for it in items:
        vid = it.get("bvid") or ""
        if not vid:
            continue
        title = re.sub(r"<[^>]+>", "", str(it.get("title") or ""))
        d = _parse_dur(it.get("duration"))
        if not (60 <= d <= 600):
            continue
        score = 0.0
        for w in GOOD_WORDS:
            if w.lower() in title.lower():
                score += 3
        for w in BAD_WORDS:
            if w.lower() in title.lower():
                score -= 8
        score -= abs(d - 240) / 120.0
        out.append({"id": vid, "title": title, "duration": d, "score": round(score, 2)})
    out.sort(key=lambda x: -x["score"])
    return out

def _search_once(query: str, limit: int = 10) -> list[dict]:
    """B 站搜索，返回 [{id,title,duration,score}]，按 score 降序。"""
    p = run([YTDLP, f"bilisearch{limit}:{query}", "--print",
             "%(id)s\t%(title)s\t%(duration)s", "--skip-download", "--no-warnings"], 180)
    out = []
    for line in (p.stdout or "").splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        vid, title, dur = parts
        try:
            d = float(dur)
        except ValueError:
            continue
        if not (60 <= d <= 600):          # 1~10 分钟才算一首歌
            continue
        score = 0.0
        t = title or ""
        for w in GOOD_WORDS:
            if w.lower() in t.lower():
                score += 3
        for w in BAD_WORDS:
            if w.lower() in t.lower():
                score -= 8
        # 时长离 4 分钟越近越好（大部分流行歌）
        score -= abs(d - 240) / 120.0
        out.append({"id": vid, "title": t, "duration": d, "score": round(score, 2)})
    out.sort(key=lambda x: -x["score"])
    return out


def download(video_id: str, dest_dir: Path) -> Path:
    """只下音频流，转成 44.1k 立体声 wav。已有同 id 的 wav 直接复用（音源本身不会变）。"""
    dest_dir.mkdir(parents=True, exist_ok=True)
    wav = dest_dir / f"{video_id}.wav"
    if wav.exists() and wav.stat().st_size > 100_000:
        log(f"音源已缓存，跳过下载：{video_id}")
        return wav
    raw = dest_dir / f"{video_id}.m4a"
    p = run([YTDLP, "-f", "bestaudio/best", "--no-playlist", "--no-warnings",
             "-o", str(raw), f"https://www.bilibili.com/video/{video_id}"], 900)
    if not raw.exists() or raw.stat().st_size < 10000:
        raise RuntimeError(f"下载失败：{(p.stderr or '')[-400:]}")
    q = run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", str(raw),
             "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le", str(wav)], 600)
    try:
        raw.unlink()          # 下载下来的 m4a 转完就没用了，别留在盘上
    except OSError:
        pass
    if not wav.exists():
        raise RuntimeError(f"转码失败：{(q.stderr or '')[-400:]}")
    return wav


def clip(src: Path, dst: Path, start: float, seconds: float) -> Path:
    """截一段（QQ 语音条有长度限制，默认只取副歌位置）。"""
    run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error",
         "-ss", str(start), "-t", str(seconds), "-i", str(src),
         "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le", str(dst)], 300)
    return dst


DEFAULT_VOICE = os.environ.get("SONG_RVC_VOICE", "luotianyi")


def rvc_convert(src: Path, voice: str, separator: bool, key_shift: int = 0) -> bytes:
    """调本机 RVC 插件换音色，返回 wav 字节。"""
    boundary = "----songrvc" + uuid.uuid4().hex
    body = bytearray()

    def field(name: str, value: str) -> None:
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(value.encode("utf-8") + b"\r\n")

    body.extend(f"--{boundary}\r\n".encode())
    body.extend(f'Content-Disposition: form-data; name="file"; filename="{src.name}"\r\n'.encode())
    body.extend(b"Content-Type: audio/wav\r\n\r\n")
    body.extend(src.read_bytes() + b"\r\n")
    if voice:
        field("voice", voice)
    if separator:
        # 整首翻唱走 /cover，混音阶段能调人声电平（-12..12 dB，插件侧字段名 vocalGain）
        field("vocalGain", f"{VOCAL_GAIN:g}")
    # 音域适配：保护清辅音 + 响度包络贴近原唱（高音不炸、低音不虚）
    if key_shift:
        field("keyShift", str(key_shift))
    field("pitch", str(PITCH))
    field("indexRate", f"{INDEX_RATE:g}")
    field("protect", f"{PROTECT:g}")
    field("rmsMix", f"{RMS_MIX:g}")
    field("format", "wav")
    body.extend(f"--{boundary}--\r\n".encode())

    url = RVC + ("/cover" if separator else "/convert")   # separator=True 时走整首翻唱（带伴奏）
    req = urllib.request.Request(url, data=bytes(body), method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(req, timeout=3600) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        raise RuntimeError(f"RVC 返回 {e.code}：{detail}")
    except Exception as e:
        raise RuntimeError(f"RVC 不可用：{e}")


def estimate_key_shift(src: Path, max_sec: float = 90.0) -> int:
    """看原曲音域是否超出音色模型的舒适区，决定整首升/降八度。

    女声模型（luotianyi）的舒适基频大约 150~800 Hz：
      · 95% 分位的 f0 超过 900 Hz —— 极高音上不去、容易刺 -> 整首降八度（-12）
      · 5% 分位低于 90 Hz —— 极低音下不来、发虚 -> 整首升八度（+12）

    只动八度、不动半音：八度是和谐音程；worker 那边会把**伴奏一起移调**，
    所以整首歌是真的换了 key，不是人声跑调。
    """
    if os.environ.get("SONG_RVC_AUTO_KEY", "1") != "1":
        return 0
    try:
        import librosa
        import numpy as np
    except Exception as e:
        log(f"音域检测跳过（缺 librosa）：{e}")
        return 0
    try:
        y, sr = librosa.load(str(src), sr=22050, mono=True, duration=max_sec)
        # 先高通 120 Hz：混音里的贝斯/底鼓会被 pyin 误判成 70 Hz 的"极低音"，
        # 一上来就把整首升八度（实测《左手指月》就被这样带偏过）。
        try:
            import scipy.signal as _ss
            _sos = _ss.butter(4, 120.0, "highpass", fs=sr, output="sos")
            y = _ss.sosfilt(_sos, y).astype("float32")
        except Exception:
            pass
        f0, _, _ = librosa.pyin(y, fmin=110.0, fmax=1200.0, sr=sr,
                                frame_length=2048, hop_length=256)
        vals = f0[~np.isnan(f0)]
        if vals.size < 200:
            log("音域检测：有效音高太少，保持原调")
            return 0
        lo = float(np.percentile(vals, 5))
        hi = float(np.percentile(vals, 95))
        log(f"音域检测：f0 5%={lo:.0f}Hz  95%={hi:.0f}Hz")
        if hi > float(os.environ.get("SONG_RVC_KEY_HI", "800")):
            log("极高音超出模型舒适区 -> 整首降八度（伴奏同步）")
            return -12
        if lo < float(os.environ.get("SONG_RVC_KEY_LO", "110")):
            log("极低音超出模型舒适区 -> 整首升八度（伴奏同步）")
            return 12
        return 0
    except Exception as e:
        log(f"音域检测失败：{e}")
        return 0

def soften_highs(data: bytes) -> bytes:
    """高音柔化：消齿音 + 7 kHz 以上轻降。

    RVC 在高音区最容易把齿音（s/sh/ts）和气声放大成"尖"，甚至发炸。
    deesser 是专门压这个的滤镜；highshelf 再补一点衰减，整体听感就不刺了。
    失败就原样返回，绝不让它拖垮出歌。
    """
    if not HIGH_SOFTEN or len(data) < 5000:
        return data
    try:
        af = (f"deesser=i={DEESS_I:g}:m=0.6:f=0.55,"
              f"highshelf=f=7000:g={HIGH_SHELF_DB:g}")
        p = subprocess.run(
            [FFMPEG, "-y", "-hide_banner", "-loglevel", "error",
             "-i", "pipe:0", "-af", af,
             "-f", "wav", "-c:a", "pcm_s16le", "pipe:1"],
            input=data, capture_output=True, timeout=600)
        if p.returncode == 0 and len(p.stdout) > 5000:
            return p.stdout
        log(f"高音柔化失败，用原音：{(p.stderr or b'')[:120]!r}")
    except Exception as e:
        log(f"高音柔化异常：{e}")
    return data

def ddsp_convert(src: Path, key_shift: int = 0) -> bytes:
    """走 DDSP-SVC 流水线：Demucs 分离 -> 380Hz 高通 -> 音高掩码 -> ReFlow -> 混音母带。

    跑在 Coopanion 的 RVC venv 里（那份有 torch cu128 / demucs / ddsp 依赖）。
    整首一次处理，不碎成片段，所以不会有分片接缝。
    """
    tmp = Path(tempfile.mkdtemp(prefix="ddspcall-"))
    try:
        out = tmp / "out.wav"
        script = Path(DDSP_DIR) / "ddsp_sing.py"
        if not script.exists():
            raise RuntimeError(f"找不到 DDSP 流水线脚本：{script}")
        cmd = [
            DDSP_PY, str(script),
            "--input", str(src),
            "--output", str(out),
            "--workdir", str(tmp / "work"),
            "--step", str(DDSP_STEP),
            "--highpass", f"{DDSP_HIGHPASS:g}",
            "--key", str(key_shift),
        ]
        t0 = time.time()
        p = subprocess.run(cmd, cwd=DDSP_DIR, capture_output=True, text=True, timeout=3600)
        if p.returncode != 0 or not out.exists():
            raise RuntimeError(f"DDSP 流水线失败：{(p.stderr or '')[-500:]}")
        log(f"DDSP 出歌完成 {time.time()-t0:.1f}s  {out.stat().st_size/1024/1024:.1f}MB")
        return out.read_bytes()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

def duration_of(path: Path) -> float:
    """读时长（秒）。源文件是 PCM wav，直接读头；读不到再退回 ffprobe；都没有就返回 0。"""
    try:
        with wave.open(str(path), "rb") as w:
            return w.getnframes() / float(w.getframerate() or 1)
    except Exception:
        pass
    try:
        p = run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=nw=1:nk=1", str(path)], 60)
        return float((p.stdout or "").strip() or 0)
    except Exception:
        return 0.0


def rvc_convert_blocks(src: Path, voice: str, separator: bool, key_shift: int = 0) -> bytes:
    """长音频分块跑 RVC 再把各块拼回一条。

    一次性整首交给 /cover 时，插件会把音频切成十几片在 GPU 上连着跑，8G 显存
    （还要给 ComfyUI 留地方）到最后几片就顶崩 —— worker 退出、模型未就绪，
    整首歌白跑。这里按 BLOCK_SECONDS 切块、逐块调用，每块收工就释放显存。
    """
    total = duration_of(src)
    if not BLOCK_SECONDS or BLOCK_SECONDS <= 0 or total <= BLOCK_SECONDS * 1.15:
        return rvc_convert(src, voice, separator, key_shift)
    tmp = Path(tempfile.mkdtemp(prefix="rvcblk-"))
    try:
        chunks: list[bytes] = []
        t = 0.0
        while t < total - 0.2:
            seg = tmp / f"b{len(chunks):02d}.wav"
            clip(src, seg, t, BLOCK_SECONDS)
            if seg.exists() and seg.stat().st_size > 1000:
                log(f"分块 {len(chunks) + 1}：{t:.0f}s 起 {min(BLOCK_SECONDS, total - t):.0f}s / 共 {total:.0f}s")
                chunks.append(rvc_convert(seg, voice, separator, key_shift))
            t += BLOCK_SECONDS
        if not chunks:
            return rvc_convert(src, voice, separator, key_shift)
        if len(chunks) == 1:
            return chunks[0]
        first = wave.open(io.BytesIO(chunks[0]), "rb")
        nch, sw, fr = first.getnchannels(), first.getsampwidth(), first.getframerate()
        first.close()
        out = io.BytesIO()
        with wave.open(out, "wb") as w:
            w.setnchannels(nch)
            w.setsampwidth(sw)
            w.setframerate(fr)
            for blob in chunks:
                with wave.open(io.BytesIO(blob), "rb") as r:
                    w.writeframes(r.readframes(r.getnframes()))
        log(f"分块拼接完成：{len(chunks)} 块 → {len(out.getvalue()) / 1024 / 1024:.1f}MB")
        return out.getvalue()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# 同一首歌的并发请求合并：后来的等第一个的结果，**不再回「忙」**。
# 不同歌之间串行（RVC / UVR5 都是重推理，同时跑会抢显存）。
_inflight: dict = {}
_inflight_lock = threading.Lock()
_serial = threading.Semaphore(1)


def _sing_key(query, voice, max_seconds, separator, start) -> str:
    return hashlib.sha1(json.dumps([query, voice, max_seconds, separator, start],
                                   sort_keys=True).encode()).hexdigest()[:16]


def sing_song(query: str, voice: str = "", max_seconds: float = 60.0,
              separator: bool = True, start: float | None = None) -> tuple[bytes, dict]:
    """同 key 复用同一份结果；不同 key 排队等（最多 30 分钟）。"""
    key = _sing_key(query, voice, max_seconds, separator, start)
    with _inflight_lock:
        fut = _inflight.get(key)
        owner = fut is None
        if owner:
            fut = concurrent.futures.Future()
            _inflight[key] = fut
    if not owner:
        log(f"同一首已在合成，等它的结果：{query}")
        try:
            return fut.result(timeout=1800)
        except concurrent.futures.TimeoutError:
            raise RuntimeError("等前一个同曲请求超时（30 分钟）")
    try:
        with _serial:
            out = _sing_song_impl(query, voice, max_seconds, separator, start)
        fut.set_result(out)
        return out
    except BaseException as e:
        fut.set_exception(e)
        raise
    finally:
        with _inflight_lock:
            _inflight.pop(key, None)


def _sing_song_impl(query: str, voice: str = "", max_seconds: float = 60.0,
                    separator: bool = True, start: float | None = None) -> tuple[bytes, dict]:
    key = hashlib.sha1(json.dumps([query, voice, max_seconds, separator, start],
                                  sort_keys=True).encode()).hexdigest()[:16]
    out_wav = CACHE / f"{key}.wav"
    meta_file = CACHE / f"{key}.json"
    # 故意**不复用上一次的成品**：同一首点两次也要真跑一遍 RVC，
    # 否则听感上就是「又把旧文件发了一遍」。音源与截取段仍缓存（那两步是确定性的）。

    t0 = time.time()
    bvid = parse_bvid(query)
    if bvid:
        # 用户直接给了链接/番号：不搜，就唱这一首
        log(f"直连音源：{bvid}（跳过搜索）")
        best = probe_video(bvid)
        if not best["duration"]:
            best["duration"] = 0.0
        hits = [best]
    else:
        hits = search(query)
    if not hits:
        raise LookupError(f"搜不到「{query}」的音源")
    best = hits[0]
    log(f"选中 {best['id']} 《{best['title']}》 {best['duration']:.0f}s score={best['score']}")

    src = download(best["id"], CACHE / "src")
    work = src
    if max_seconds and best["duration"] > max_seconds + 5:
        # 跳过前奏，从 1/4 处取，通常正好是主歌末/副歌
        st = start if start is not None else max(8.0, best["duration"] * 0.25)
        work = clip(src, CACHE / f"{key}.seg.wav", st, max_seconds)
        log(f"截取 {st:.0f}s 起 {max_seconds:.0f}s")

    if ENGINE == "ddsp":
        # DDSP 链路自己会做分离/高通/混音/母带，不再走 RVC 那套
        log("引擎：DDSP-SVC（Demucs 分离 + Reflow 转换）")
        audio = ddsp_convert(work, 0)
    else:
        key_shift = estimate_key_shift(src)
        if key_shift:
            log(f"整首移调 {key_shift:+d} 半音（人声和伴奏一起）")
        audio = rvc_convert_blocks(work, (voice or "").strip() or DEFAULT_VOICE, separator, key_shift)
        audio = soften_highs(audio)
    if len(audio) < 5000:
        raise RuntimeError(f"RVC 回了空音频：{audio[:200]!r}")
    CACHE.mkdir(parents=True, exist_ok=True)
    meta = {
        "query": query, "videoId": best["id"], "title": best["title"],
        "duration": round(best["duration"], 1), "voice": voice or "(默认)",
        "seconds": max_seconds, "ms": int((time.time() - t0) * 1000),
        "candidates": hits[:5],
    }
    meta_file.write_text(json.dumps(meta, ensure_ascii=False, indent=2), "utf-8")
    # 音频已经读进内存交给调用方了，成品和截取段一律不落盘；
    # 原音源只有 KEEP_CACHE=1（默认）才留着，下次点同一首能跳过下载。
    try:
        w = Path(work)
        if w.exists() and w.is_file() and w.name != Path(src).name:
            w.unlink()
    except OSError:
        pass
    if not KEEP_CACHE:
        try:
            s = Path(src)
            if s.exists() and s.is_file():
                s.unlink()
        except OSError:
            pass
    prune_cache()
    return audio, {**meta, "cached": False}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log("%s - %s" % (self.address_string(), fmt % args))

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _json(self, code: int, obj: dict):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def do_GET(self):
        if self.path.split("?")[0] in ("/health", "/v1/health"):
            try:
                with urllib.request.urlopen(RVC + "/health", timeout=5) as r:
                    rvc = json.loads(r.read() or b"{}")
                rvc_ok = True
            except Exception as e:
                rvc, rvc_ok = {"error": str(e)[:120]}, False
            self._json(200, {"ok": rvc_ok, "rvc": rvc, "cache": str(CACHE)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        if path not in ("/sing-song", "/song"):
            self._json(404, {"error": "not found"})
            return
        n = int(self.headers.get("content-length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception as e:
            self._json(400, {"error": f"bad json: {e}"})
            return
        query = str(req.get("query") or req.get("title") or req.get("q") or "").strip()
        if not query:
            self._json(400, {"error": "缺少 query（歌名）"})
            return
        raw_max = req.get("maxSeconds")
        try:
            max_seconds = float(raw_max) if raw_max is not None else 60.0
        except (TypeError, ValueError):
            max_seconds = 60.0
        if max_seconds < 0:
            max_seconds = 0.0   # 0 / 负数 = 整首，不截取
        try:
            audio, meta = sing_song(
                query,
                voice=str(req.get("voice") or ""),
                max_seconds=max_seconds,
                separator=bool(req.get("separator", True)),
                start=(float(req["start"]) if req.get("start") is not None else None),
            )
            if req.get("base64"):
                import base64
                self._json(200, {**meta, "ok": True, "audioBase64": base64.b64encode(audio).decode()})
            else:
                self._send(200, audio, "audio/wav")
        except LookupError as e:
            self._json(404, {"error": str(e)})
        except Exception as e:
            self._json(502, {"error": str(e)[:600]})



def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    prune_cache()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    log(f"监听 http://127.0.0.1:{PORT}  → RVC {RVC}  缓存 {CACHE}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
