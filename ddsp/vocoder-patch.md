# DDSP-SVC vocoder.py 补丁（八度修正 + f0 中值平滑）

在你 clone 下来的 ddsp-svc 里改 `ddsp/vocoder.py`：

## 1. 加两个函数（放在 `class F0_Extractor:` 之前）

```python
def _fix_isolated_octave(f0):
    """修正孤立的八度跳变：跳出去一帧两帧又跳回来。"""
    import numpy as np
    if f0 is None or len(f0) < 3:
        return f0
    f = np.array(f0, dtype=np.float64, copy=True)
    for i in range(1, len(f) - 1):
        a, b, c = f[i - 1], f[i], f[i + 1]
        if a <= 0 or b <= 0 or c <= 0:
            continue
        r0 = 12 * np.log2(b / a)
        r1 = 12 * np.log2(c / b)
        k = round(r0 / 12.0)
        if k == 0:
            continue
        if abs(r0 - k * 12) < 1.5 and abs(r1 + k * 12) < 1.5:
            f[i] = b / (2.0 ** k)
    return f


def _smooth_f0(f0, kernel=5):
    """中值滤波去单帧尖峰，保留转音趋势。"""
    import numpy as np
    from scipy.signal import medfilt
    if f0 is None or len(f0) < kernel:
        return f0
    f = np.array(f0, dtype=np.float64, copy=True)
    ok = f > 0
    if ok.sum() < kernel:
        return f
    idx = np.where(ok)[0]
    seg = f[idx]
    if len(seg) >= kernel:
        f[idx] = medfilt(seg, kernel_size=kernel)
    return f
```

## 2. 在 rmvpe 提取之后套上

```python
# 原：
f0 = self.rmvpe.infer_from_audio(audio, self.sample_rate, device=device, thred=0.03, use_viterbi=False)

# 改成：
f0 = self.rmvpe.infer_from_audio(audio, self.sample_rate, device=device, thred=0.015, use_viterbi=True)
f0 = _fix_isolated_octave(f0)
f0 = _smooth_f0(f0, 5)
```

**参数含义**
- `thred=0.015`（默认 0.03）：置信阈值放低，换声点不再判"无音高"
- `use_viterbi=True`（默认 False）：全局最优路径，减少断帧和八度跳变
- `_fix_isolated_octave`：修"跳出去又回来"的孤立错误
- `_smooth_f0(kernel=5)`：5 帧≈40ms 中值滤波，去尖峰保趋势

## 3. 另外三处兼容补丁（PyTorch 2.6+ 必需）

全仓库的 `torch.load(...)` 加 `weights_only=False`，否则会报 `WeightsUnpicklingError`。
`vocoder.py` 里有 4 处、`inference.py` 1 处、`utils.py` 2 处、`models.py` 1 处。

## 4. torchcrepe 改成可选导入

`ddsp/vocoder.py` 顶部：

```python
try:
    import torchcrepe
except ImportError:
    torchcrepe = None
```

（用 rmvpe 时不需要 torchcrepe，但顶层 import 会挡住启动）