#!/usr/bin/env python3
"""
song-cmd-poll —— 轮询版「QQ 里发【唱】歌名就回语音」。不依赖 WebSocket。

为什么轮询：SnowLuma 的正向 WS（3001）已被 SurfCore 的桥接占着，第二个客户端
能连上但收不到事件；HTTP（3000）这边随便查都通，所以用「定时拉最近消息 + 比 message_id」。

每 3 秒：
    ① 拉所有群的最近消息 + 主人的私聊最近消息
    ② 只挑「没见过 且 以【唱】开头 且 不是 bot 自己发的」
    ③ 调 song-rvc 搜音源 + RVC，把 wav 当 record 发回原会话
"""
from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

CONF = Path(r"D:\大肥鱼的实验室\SnowLuma\config")
HTTP = os.environ.get("SC_HTTP", "http://127.0.0.1:3000").rstrip("/")
SONG = os.environ.get("SC_SONG", "http://127.0.0.1:9883").rstrip("/")
SECONDS = float(os.environ.get("SC_SECONDS", "0"))      # 0 = 整首（分段发全曲）；填数字则只唱那么多秒
SEGMENT = float(os.environ.get("SC_SEGMENT", "60"))     # QQ 语音条单条上限，按这个长度切段
SEG_GAP = float(os.environ.get("SC_SEG_GAP", "2.0"))    # 段与段之间歇几秒，避免连发被风控
FFMPEG = os.environ.get("SC_FFMPEG", "ffmpeg")
VOICE = os.environ.get("SC_VOICE", "luotianyi")
INTERVAL = float(os.environ.get("SC_INTERVAL", "3"))
SEEN_FILE = Path(__file__).resolve().parent / "song-cmd-seen.json"
OWNER = os.environ.get("SC_OWNER", "3147159492")

CMD_RE = re.compile(r"^\s*(?:【\s*唱\s*】|\[\s*唱\s*\]|\[\s*sing\s*\])\s*", re.IGNORECASE)


def log(m: str) -> None:
    sys.stderr.write(f"[song-poll] {time.strftime('%H:%M:%S')} {m}\n")
    sys.stderr.flush()


def pick_token() -> str:
    cands = []
    for f in sorted(CONF.glob("onebot_*.json")):
        try:
            j = json.loads(f.read_text("utf-8"))
        except Exception:
            continue
        h = ((j.get("networks") or {}).get("httpServers") or [{}])[0]
        t = str(h.get("accessToken") or "")
        if t:
            cands.append((t, f.name))
    for t, name in cands:
        r = api("get_login_info", {}, t, 8)
        if r.get("status") == "ok":
            log(f"token 来自 {name}（uin={r.get('data', {}).get('user_id')}）")
            return t
    if cands:
        return cands[0][0]
    raise SystemExit("找不到可用的 onebot HTTP token")


def api(action: str, payload: dict, token: str, timeout: int = 60) -> dict:
    data = json.dumps(payload, ensure_ascii=False).encode()
    req = urllib.request.Request(f"{HTTP}/{action}", data=data, method="POST",
                                 headers={"content-type": "application/json",
                                          "authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return {"status": "failed", "retcode": e.code}
    except Exception as e:
        return {"status": "failed", "retcode": -1, "body": str(e)[:120]}


def load_seen() -> set[int]:
    try:
        return set(json.loads(SEEN_FILE.read_text("utf-8")))
    except Exception:
        return set()


def save_seen(seen: set[int]) -> None:
    try:
        SEEN_FILE.write_text(json.dumps(sorted(seen)[-800:]), "utf-8")
    except Exception:
        pass


def ensure_song_rvc() -> bool:
    """9883 挂了就拉起来。点歌前调一次，最多等 6 秒。"""
    def alive() -> bool:
        try:
            urllib.request.urlopen("http://127.0.0.1:9883/health", timeout=2)
            return True
        except Exception:
            return False
    if alive():
        return True
    log("song-rvc 没在跑，自动拉起")
    try:
        flags = 0x08000000 if os.name == "nt" else 0   # CREATE_NO_WINDOW
        subprocess.Popen(["cmd", "/c", "start", "songrvc", "/B", "python",
                          r"D:\surfcore\state\song-rvc.py"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=flags)
    except Exception as e:
        log(f"拉起失败：{e}")
        return False
    for _ in range(12):
        time.sleep(0.5)
        if alive():
            log("song-rvc 已就绪")
            return True
    return False

def sing(query: str, max_seconds: float | None = None):
    secs = SECONDS if max_seconds is None else max_seconds
    body = json.dumps({"query": query, "maxSeconds": secs, "voice": VOICE}, ensure_ascii=False).encode()
    req = urllib.request.Request(f"{SONG}/sing-song", data=body, method="POST",
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=3600) as r:
            return r.read(), {}
    except urllib.error.HTTPError as e:
        return None, {"error": e.read()[:300].decode("utf-8", "replace")}
    except Exception as e:
        return None, {"error": str(e)[:200]}


def split_wav(data: bytes, seconds: float) -> list[bytes]:
    """把整首 wav 按 seconds 切段；切不动就原样当一整条发。"""
    if not seconds or seconds <= 5:
        return [data]
    tmp = Path(tempfile.mkdtemp(prefix="songseg-"))
    try:
        src = tmp / "full.wav"
        src.write_bytes(data)
        out = tmp / "seg"
        out.mkdir()
        r = subprocess.run(
            [FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", str(src),
             "-f", "segment", "-segment_time", f"{seconds:g}", "-c:a", "pcm_s16le",
             str(out / "p%03d.wav")],
            capture_output=True, text=True, timeout=900)
        files = sorted(out.glob("p*.wav"))
        if r.returncode != 0 or not files:
            log(f"切段失败，整条发：{(r.stderr or '')[-200:]}")
            return [data]
        return [p.read_bytes() for p in files]
    except Exception as e:
        log(f"切段异常，整条发：{e}")
        return [data]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def handle(ev: dict, token: str) -> None:
    text = re.sub(r"\[CQ:[^\]]+\]", "", str(ev.get("raw_message") or "")).strip()
    m = CMD_RE.match(text)
    if not m:
        return
    song = text[m.end():].strip().strip("《》<>「」\"' ")
    is_group = ev.get("message_type") == "group"
    target = {"group_id": ev["group_id"]} if is_group else {"user_id": ev["user_id"]}
    send_action = "send_group_msg" if is_group else "send_private_msg"
    if not song:
        api(send_action, target | {"message": [{"type": "text", "data": {"text": "【唱】后面要写歌名，比如 【唱】雨爱"}}]}, token, 30)
        return
    who = (ev.get("sender") or {}).get("nickname", "?")
    log(f"点歌：{who} → «{song}»")
    ensure_song_rvc()
    # 整首是分块跑 RVC（一首三四分钟很正常），先回一句，否则群里等着的几分钟看着像没反应
    api(send_action, target | {"message": [{"type": "text", "data": {"text": f"「{song}」收到，整首翻唱中，好了直接分批发出来～"}}]}, token, 30)
    t0 = time.time()
    audio, meta = sing(song)
    if not audio:
        # 整首翻唱失败（时长太长 / 显存 / UVR5）时退回 60 秒片段，至少给出一段
        log(f"整首失败，退回 60s 片段：{meta.get('error', '')[:120]}")
        audio, meta = sing(song, 60)
    if not audio:
        api(send_action, target | {"message": [{"type": "text", "data": {"text": f"「{song}」没唱出来：{meta.get('error','')[:80]}"}}]}, token, 30)
        log(f"失败：{meta.get('error','')[:120]}")
        return
    segs = split_wav(audio, SEGMENT)
    log(f"«{song}» 整首 {len(audio)/1024/1024:.1f}MB → {len(segs)} 段")
    if len(segs) > 1:
        api(send_action, target | {"message": [{"type": "text", "data": {"text": f"「{song}」整首唱完，分 {len(segs)} 段发（每段 {SEGMENT:.0f} 秒）"}}]}, token, 30)
    sent = 0
    for i, seg in enumerate(segs, 1):
        b64 = base64.b64encode(seg).decode()
        r = api(send_action, target | {"message": [{"type": "record", "data": {"file": f"base64://{b64}"}}]}, token, 300)
        ok = r.get("status") == "ok"
        sent += 1 if ok else 0
        log(f"  第 {i}/{len(segs)} 段 {len(seg)/1024:.0f}KB {'已发' if ok else '失败'}")
        if i < len(segs):
            time.sleep(SEG_GAP)
    log(f"«{song}» {'全部已发' if sent == len(segs) else f'部分失败 {sent}/{len(segs)}'} "
        f"{len(audio)/1024:.0f}KB {time.time()-t0:.1f}s")


def main() -> None:
    token = pick_token()
    seen = load_seen()
    log(f"HTTP {HTTP} / song-rvc {SONG} / {'整首' if not SECONDS else f'每首 {SECONDS:.0f}s'} / 每段 {SEGMENT:.0f}s / 轮询 {INTERVAL:.0f}s")
    groups = []
    r = api("get_group_list", {}, token, 20)
    if r.get("status") == "ok":
        groups = [g["group_id"] for g in r.get("data") or []]
    log(f"监听 {len(groups)} 个群 + 主人私聊 {OWNER}")
    while True:
        try:
            for gid in groups:
                h = api("get_group_msg_history", {"group_id": gid, "count": 3}, token, 20)
                if h.get("status") != "ok":
                    continue
                for msg in (h.get("data") or {}).get("messages") or []:
                    mid = msg.get("message_id")
                    if mid in seen:
                        continue
                    if os.environ.get("SC_ALLOW_SELF") != "1" and str((msg.get("sender") or {}).get("user_id")) == str(ev_self_id(token)):
                        continue
                    seen.add(mid)
                    msg["message_type"] = "group"
                    msg["group_id"] = gid
                    handle(msg, token)
            h = api("get_friend_msg_history", {"user_id": int(OWNER), "count": 3}, token, 20)
            if h.get("status") == "ok":
                for msg in (h.get("data") or {}).get("messages") or []:
                    mid = msg.get("message_id")
                    if mid in seen:
                        continue
                    if os.environ.get("SC_ALLOW_SELF") != "1" and str((msg.get("sender") or {}).get("user_id")) == str(ev_self_id(token)):
                        continue
                    seen.add(mid)
                    msg["message_type"] = "private"
                    msg["user_id"] = int(OWNER)
                    handle(msg, token)
            save_seen(seen)
        except Exception as e:
            log(f"轮询出错：{type(e).__name__}: {e}")
        time.sleep(INTERVAL)


_SELF: dict = {}


def ev_self_id(token: str) -> int:
    if "id" not in _SELF:
        r = api("get_login_info", {}, token, 8)
        _SELF["id"] = (r.get("data") or {}).get("user_id") or 0
    return _SELF["id"]


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
