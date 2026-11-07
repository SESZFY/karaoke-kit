#!/usr/bin/env python3
"""DDSP-SVC 点歌流水线：混音 wav 进 → 洛天依翻唱 wav 出。

被 song-rvc.py 用 subprocess 调用（跑在 Coopanion 的 RVC venv 里，那份有
torch cu128 / demucs / ddsp 依赖）。

流程：
    1. Demucs htdemucs 分离（GPU，4-stem，人声独立输出）
    2. 生成音高掩码（原唱没稳定音高的段压到 -34dB，避免 DDSP 硬唱）
    3. main_reflow.py 转换人声（ReFlow 40 步 + rmvpe + fmax 1100）
    4. 输出能量跟随输入（补掉模型在换声点的能量塌陷）
    5. 人声压缩 → 与伴奏混音 → deesser + 高频柔化 + 限幅

用法：
    python ddsp_sing.py --input mix.wav --output final.wav [--key 0] [--step 40]
                        [--model exp/reflow-luotyxx/model_350000-luo.pt]
                        [--workdir C:\\Temp\\ddsp-job]
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
os.environ.setdefault("HF_HUB_OFFLINE", "1")      # 模型已缓存，别联网查更新
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

import numpy as np                                    # noqa: E402
import soundfile as sf                                # noqa: E402


def log(msg: str) -> None:
    sys.stderr.write(f"[ddsp] {time.strftime('%H:%M:%S')} {msg}\n")
    sys.stderr.flush()


# ── 1. Demucs 分离 ─────────────────────────────────────
def separate(src: Path, outdir: Path) -> tuple[Path, Path]:
    import torch
    from demucs.pretrained import get_model
    from demucs.apply import apply_model

    t0 = time.time()
    a, sr = sf.read(str(src), always_2d=True)
    if a.shape[1] == 1:
        a = np.repeat(a, 2, axis=1)
    wav = a.T.astype(np.float32)

    model = get_model("htdemucs")
    model.eval()
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    model.to(dev)

    w = torch.from_numpy(wav)
    ref = w.mean(0)
    mean, std = float(ref.mean()), float(ref.std()) + 1e-8
    with torch.no_grad():
        out = apply_model(model, ((w - mean) / std)[None], device=dev,
                          shifts=1, split=True, overlap=0.25, progress=False)[0]
    out = out * std + mean

    vocals = out[3].cpu().numpy().T
    inst = (out[0] + out[1] + out[2]).cpu().numpy().T
    vp, ip = outdir / "vocals.wav", outdir / "inst.wav"
    sf.write(str(vp), vocals, sr)
    sf.write(str(ip), inst, sr)
    log(f"分离完成 {time.time()-t0:.1f}s  时长 {len(vocals)/sr:.1f}s")
    return vp, ip


# ── 2. 音高掩码 ────────────────────────────────────────
def gate_vocals(vocal_path: Path, out_path: Path, highpass_hz: float = 0.0) -> Path:
    import librosa

    t0 = time.time()
    y, sr22 = librosa.load(str(vocal_path), sr=22050, mono=True)
    _, vflag, vprob = librosa.pyin(y, fmin=65, fmax=2000, sr=sr22,
                                   frame_length=2048, hop_length=256)
    conf = np.nan_to_num(vprob, nan=0.0).astype(np.float32)
    g = conf ** 1.5
    win = 86                                        # ~1.0s（更长 = 更顺）
    k = np.hanning(win).astype(np.float32)
    k /= k.sum()
    g = np.convolve(g, k, mode="same").astype(np.float32)
    g = np.clip(g * 2.2, 0.35, 1.0)

    a, sr = sf.read(str(vocal_path), always_2d=True)
    ratio = sr / sr22 * 256
    idx = np.clip((np.arange(int(len(g) * ratio)) / ratio).astype(np.int32), 0, len(g) - 1)
    mask = g[idx]
    n = min(len(a), len(mask))
    a[:n] *= mask[:n, None]
    if highpass_hz and highpass_hz > 0:
        from scipy.signal import butter, sosfilt
        sos = butter(6, highpass_hz / (sr / 2), btype="highpass", output="sos")
        a = sosfilt(sos, a, axis=0).astype(np.float32)
        log(f"高通 {highpass_hz:.0f}Hz 已应用（削掉低八度误判）")
    sf.write(str(out_path), a.astype(np.float32), sr)
    log(f"音高掩码 {time.time()-t0:.1f}s  压低占比 {(mask<0.1).mean()*100:.1f}%")
    return out_path


# ── 3. DDSP 转换 ───────────────────────────────────────
def reflow(vocal_path: Path, out_path: Path, model: str, key: int, step: int, fmax: int) -> Path:
    t0 = time.time()
    cmd = [
        sys.executable, str(HERE / "run_reflow.py"),
        "-m", model, "-d", "cuda",
        "-i", str(vocal_path), "-o", str(out_path),
        "-pe", "rmvpe", "-step", str(step), "-k", str(key),
        "-fmax", str(fmax), "-th", "-60",
    ]
    p = subprocess.run(cmd, cwd=str(HERE), capture_output=True, text=True, timeout=3600)
    if p.returncode != 0 or not out_path.exists():
        raise RuntimeError(f"DDSP 转换失败：{(p.stderr or '')[-400:]}")
    log(f"DDSP 转换 {time.time()-t0:.1f}s")
    return out_path


# ── 4+5. 能量跟随 + 压缩 + 混音 + 母带 ─────────────────
def mixdown(vocal_in: Path, vocal_ddsp: Path, inst_path: Path, out_path: Path,
            vocal_gain: float = 2.7, inst_gain: float = 0.62) -> Path:
    from scipy.ndimage import uniform_filter1d

    voc, sr = sf.read(str(vocal_ddsp), always_2d=True)
    inst, _ = sf.read(str(inst_path), always_2d=True)
    inp, _ = sf.read(str(vocal_in), always_2d=True)
    if voc.shape[1] == 1:
        voc = np.repeat(voc, 2, axis=1)
    n = min(len(voc), len(inst), len(inp))
    voc, inst, inp = voc[:n], inst[:n], inp[:n]

    # 能量跟随：输出向输入的能量包络靠拢，补掉换声点的塌陷
    hop = int(sr * 0.05)
    nn = max(1, n // hop)

    def env(x):
        m = x.mean(axis=1)
        r = np.sqrt(np.mean(m[:nn * hop].reshape(nn, hop) ** 2, axis=1))
        return 20 * np.log10(np.maximum(r, 1e-9))

    # 默认「静态对齐」：只把整体电平匹配到原唱，不逐帧追。
    # 逐帧跟随会让每个字的气口都抽一下，实测帧间跳变 2.21dB（原唱 2.36），
    # 听感就是"词句不连贯"。静态对齐后降到 1.76dB，比原唱还顺。
    if os.environ.get("DDSP_FOLLOW", "0") == "1":
        d = np.clip((env(inp) - env(voc)) * 0.6, -20, 20)
        _sm = float(os.environ.get("DDSP_FOLLOW_SMOOTH", "0.6"))
        d = uniform_filter1d(d, size=max(1, int(_sm * sr / hop)), mode="nearest")
    else:
        _ri = float(np.sqrt(np.mean(inp ** 2)))
        _rv = float(np.sqrt(np.mean(voc ** 2)))
        _g0 = float(np.clip(20 * np.log10(max(_ri, 1e-9) / max(_rv, 1e-9)), -20, 20))
        d = np.full(nn, _g0, dtype=np.float32)
        log(f"静态电平对齐 {_g0:+.1f} dB")
    g = np.repeat(10 ** (d / 20.0), hop)[:n]
    if len(g) < n:
        g = np.pad(g, (0, n - len(g)), mode="edge")
    voc = voc * g[:, None]

    # 分别 EQ：人声提清晰度，伴奏在 1-4kHz 让路（不这么做，光提音量只会更刺）
    try:
        from scipy.signal import butter, sosfilt, iirpeak, lfilter
        nyq = sr / 2.0
        # 人声：80Hz 高通去闷
        voc = sosfilt(butter(2, 80/nyq, btype="highpass", output="sos"), voc, axis=0).astype(np.float32)
        # 人声：2.5kHz +2.5dB 提咬字
        _b, _a = iirpeak(2500/nyq, 1.0)
        voc = (voc + lfilter(_b, _a, voc, axis=0) * (10 ** (4.0/20) - 1)).astype(np.float32)
        # 1.2kHz 补一点"字头"的实体感（咬字清晰度）
        _b3, _a3 = iirpeak(1200/nyq, 1.2)
        voc = (voc + lfilter(_b3, _a3, voc, axis=0) * (10 ** (1.5/20) - 1)).astype(np.float32)
        # 伴奏：2kHz -2.5dB 给中频让路
        _b2, _a2 = iirpeak(2000/nyq, 1.2)
        inst = (inst - lfilter(_b2, _a2, inst, axis=0) * (1 - 10 ** (-2.5/20))).astype(np.float32)
        log("EQ 已应用（人声 +2.5dB@2.5k / 伴奏 -2.5dB@2k）")
    except Exception as _e:
        log(f"EQ 跳过：{_e}")

    # 音区平衡：洛天依模型在低音区（<220Hz）和高音区（>600Hz）都偏弱，
    # 中音区最饱满。按帧判断当前音高，在两端各补一点，让整首的高低音一样"实"。
    if os.environ.get("DDSP_TONE_BALANCE", "1") == "1":
        try:
            import librosa
            _y, _sr2 = librosa.load(str(vocal_ddsp), sr=11025, mono=True, duration=150)  # 只分析前 150 秒，够判音区
            _f0, _vf, _ = librosa.pyin(_y, fmin=65, fmax=1600, sr=_sr2,
                                       frame_length=2048, hop_length=128)
            _g = np.ones(len(_f0), dtype=np.float32)
            _ok = ~np.isnan(_f0) & _vf
            _g[_ok & (_f0 < 220)] = 10 ** (float(os.environ.get("DDSP_LOW_BOOST", "2.0")) / 20)
            _g[_ok & (_f0 > 600)] = 10 ** (float(os.environ.get("DDSP_HIGH_BOOST", "2.0")) / 20)
            # 200ms 平滑，避免音区切换处出现台阶
            _g = uniform_filter1d(_g, size=max(3, int(0.2 * _sr2 / 128)), mode="nearest")
            _ratio = sr / _sr2 * 128
            _idx = np.clip((np.arange(n) / _ratio).astype(np.int32), 0, len(_g) - 1)
            voc = voc * _g[_idx][:, None]
            log(f"音区平衡：低音+{os.environ.get('DDSP_LOW_BOOST','2.0')}dB 高音+{os.environ.get('DDSP_HIGH_BOOST','2.0')}dB")
        except Exception as _e:
            log(f"音区平衡跳过：{_e}")
    # 包络平滑：DDSP 生成的人声帧间跳动天生比原唱多 0.54dB，
    # 这里把 20ms 帧能量的起伏削掉一半（50% 混合，保留咬字的自然强弱）
    if os.environ.get("DDSP_SMOOTH", "1") == "1":
        _h = max(1, int(sr * 0.02))
        _nn = n // _h
        if _nn > 10:
            _e = np.sqrt(np.mean(voc[:_nn*_h].reshape(_nn, _h, -1) ** 2, axis=(1, 2)))
            _es = uniform_filter1d(_e, size=max(3, int(0.3 * sr / _h)), mode="nearest")
            _r = np.clip(_es / np.maximum(_e, 1e-9), 0.4, 2.5)
            _r = 1.0 + (_r - 1.0) * 0.5
            _g = np.repeat(_r, _h)[:n]
            if len(_g) < n: _g = np.pad(_g, (0, n - len(_g)), mode="edge")
            voc = voc * _g[:, None]
            log(f"包络平滑 50%")

    mix = inst * inst_gain + voc * vocal_gain
    peak = float(np.abs(mix).max())
    if peak > 0.97:
        x = mix / peak
        mix = np.tanh(x * 1.3) / np.tanh(1.3) * 0.97
    sf.write(str(out_path), mix.astype(np.float32), sr)
    log(f"混音 rms={float(np.sqrt(np.mean(mix**2))):.4f} peak={float(np.abs(mix).max()):.3f}")
    return out_path


def master(src: Path, dst: Path) -> Path:
    ff = os.environ.get("SONG_RVC_FFMPEG", "ffmpeg")
    # 两级压缩把动态从 ~30dB 收到接近商业成品，再限幅；响度对不上原曲时听感会"伴奏抢戏"
    # 之前 deesser(0.45) + highshelf(-1.5dB) 把 4-8kHz 砍掉 65%，听感"听不清"
    # 现在：压缩 makeup 降到 2+3（不撞限幅）、deesser 0.15、去掉 highshelf
    af = ("acompressor=threshold=-24dB:ratio=2:attack=15:release=200:makeup=2,"
          "acompressor=threshold=-18dB:ratio=3:attack=8:release=120:makeup=3,"
          "deesser=i=0.15:m=0.6:f=0.55,"
          "alimiter=limit=0.95:attack=5:release=80")
    p = subprocess.run([ff, "-y", "-hide_banner", "-loglevel", "error",
                        "-i", str(src), "-af", af, "-c:a", "pcm_s16le", str(dst)],
                       capture_output=True, text=True, timeout=600)
    if p.returncode != 0 or not dst.exists():
        log(f"母带处理失败，用未处理版本：{(p.stderr or '')[-200:]}")
        shutil.copy(src, dst)
    return dst


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--model", default=str(HERE / "exp" / "reflow-luotyxx" / "model_350000-luo.pt"))
    ap.add_argument("--key", type=int, default=0)
    ap.add_argument("--step", type=int, default=int(os.environ.get("DDSP_STEP", "40")))
    ap.add_argument("--fmax", type=int, default=int(os.environ.get("DDSP_FMAX", "1600")))
    ap.add_argument("--gain", type=float, default=float(os.environ.get("DDSP_GAIN", "2.7")))
    ap.add_argument("--highpass", type=float, default=float(os.environ.get("DDSP_HIGHPASS", "0")))
    ap.add_argument("--inst-gain", type=float, default=float(os.environ.get("DDSP_INST_GAIN", "0.62")))
    ap.add_argument("--workdir", default="")
    args = ap.parse_args()

    src = Path(args.input)
    dst = Path(args.output)
    if not src.exists():
        raise SystemExit(f"输入不存在：{src}")

    work = Path(args.workdir) if args.workdir else Path(tempfile.mkdtemp(prefix="ddsp-job-"))
    work.mkdir(parents=True, exist_ok=True)
    t_all = time.time()
    try:
        vocals, inst = separate(src, work)
        gated = gate_vocals(vocals, work / "vocals_gated.wav", args.highpass)
        ddsp_out = reflow(gated, work / "vocals_ddsp.wav", args.model, args.key, args.step, args.fmax)
        # 用「未掩码」的原始人声做能量基准：gated 已被压低，拿它当基准补不回原唱电平
        mixed = mixdown(vocals, ddsp_out, inst, work / "mix.wav", args.gain, args.inst_gain)
        master(mixed, dst)
        log(f"全流程 {time.time()-t_all:.1f}s → {dst}")
    finally:
        if not args.workdir:
            shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
