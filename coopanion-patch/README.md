# Coopanion 补丁：RVC worker 显存回收

文件：`worker.py`
路径：`Coopanion\data\extensions\node_modules\@wocwang\cortico-world-rvc-for-coopanion\src\python\worker.py`

直接用本目录的 `worker.py` 覆盖，然后在 Coopanion 里重启 RVC world：

```powershell
Invoke-WebRequest 'http://127.0.0.1:17788/api/worlds/restart' -Method POST `
  -Body '{"id":"rvc"}' -ContentType 'application/json'
```

---

## 为什么要打

8G 显存的机器上，RVC worker 跑完长音频不把显存还给驱动：

```
处理前   1205 MB   （模型加载后的基线）
跑完一首 5268 MB   ← 缓存攥着不放
```

下一首长音频分片推理时分配失败，worker 直接退出：

```
[rvc] 切片 8/10：20.3 秒 | [rvc] 切片 9/10：20.3 秒 | [rvc] 切片 10/10：5.6 秒
RVC worker 退出（4294967295）
→ 之后所有请求 409 模型未就绪
```

整首歌白跑，而且插件不会自己恢复，得手动重启 world。

---

## 改了什么

### 1. 新增释放函数（在 `main()` 内，`def cover` 之前）

```python
    def _release_vram() -> None:
        """任务收工把未使用的显存还给驱动。

        torch 的缓存分配器默认攥着显存不放（实测这个 worker 能攒到 5GB+），
        8G 卡上再跑长音频就 OOM、worker 直接退出，整首歌白跑。
        empty_cache() 只释放没人引用的缓存块，安全，不影响后续推理。
        """
        try:
            import torch
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
                torch.cuda.ipc_collect()
        except Exception:
            pass
```

### 2. 在 `cover()` 的 emit 之后调用一次

```python
            "peakScale": round(scale, 3),
        })
        _release_vram()
```

### 3. 在 `main()` 的指令循环里，`cover()` 返回后**再**调一次

这一处才是关键——函数返回后局部张量才真正释放，这时 `empty_cache()` 才有效：

```python
        if op == "cover":
            cover(req)
            # 函数已经返回、局部张量都释放了，这时 empty_cache 才真能还给驱动
            _release_vram()
            continue
```

---

## 实测效果

| 时机 | worker 显存 |
|---|---|
| 处理前（基线） | 1205 MB |
| 一首 186s 整首之后 | 4343 MB（打补丁前是 5268 MB） |
| 重启 world 后 | 回到 1205 MB |

补丁能压住一部分，但 WDDM 下 torch 仍不会把显存全还给驱动，所以**还要靠两个兜底**：

- `song-guard.ps1` 检测到 `9881/health` 的 `ready=false` 就自动调 `POST /api/worlds/restart`
- `song-rvc.py` 的 `SONG_RVC_BLOCK=80`（分块跑，每块 80 秒，别一口气塞整首）

---

## 注意

这是第三方扩展的源码文件，插件更新时会被覆盖，升级后需要重新打一遍。
