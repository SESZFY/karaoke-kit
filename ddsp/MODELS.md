# DDSP-SVC 模型清单

`ddsp/` 目录下只有代码，模型文件因为体积（合计约 800 MB，单个最大 361 MB）超过 GitHub 的 100 MB 单文件限制，需要单独获取。

## 目录结构

装完后 `ddsp-svc/` 应该长这样：

```
ddsp-svc/
├── ddsp_sing.py                              本仓库提供
├── run_reflow.py                             本仓库提供
├── main_reflow.py                            上游自带
├── ddsp/ reflow/ encoder/ ...                上游自带（含 vocoder-patch.md 的四处补丁）
├── pretrain/
│   ├── contentvec/checkpoint_best_legacy_500.pt   361 MB   ← 需要下载
│   ├── nsf_hifigan/model                           54 MB   ← 需要下载
│   └── rmvpe/model.pt                             173 MB   ← 需要下载
└── exp/reflow-luotyxx/
    ├── config.yaml                              你的模型配置
    └── model_350000-luo.pt                      210 MB   ← 你的音色模型
```

## 三个必需模型

### 1. ContentVec（361 MB）

```bash
# 用 aria2c 多线程（单线程从 hf-mirror 只有 131 KB/s，16 线程能到 7 MB/s）
aria2c -x 16 -s 16 -k 1M \
  -d ddsp-svc/pretrain/contentvec \
  -o checkpoint_best_legacy_500.pt \
  "https://hf-mirror.com/innnky/contentvec/resolve/main/checkpoint_best_legacy_500.pt"
```

**注意**：必须下 `pytorch_model.bin` 或等价的 **transformers 格式**，不能下 fairseq 格式的 `checkpoint_best_legacy_500.pt`（那个会报 `No module named 'fairseq'`）。

两个源都可以：

```bash
# 源 A（180 MB，精简版，推荐）
https://hf-mirror.com/innnky/contentvec/resolve/main/pytorch_model.bin

# 源 B（361 MB，完整版）
https://hf-mirror.com/lengyue233/content-vec-best/resolve/main/pytorch_model.bin
```

下完重命名为 `checkpoint_best_legacy_500.pt`（配置里引用的就是这个名字）。

### 2. NSF-HiFiGAN（54 MB）

```bash
curl -L -o nsf.zip \
  "https://github.com/openvpi/vocoders/releases/download/pc-nsf-hifigan-44.1k-hop512-128bin-2025.02/pc_nsf_hifigan_44.1k_hop512_128bin_2025.02.zip"

# 解压后 zip 里是 pc_nsf_hifigan_44.1k_hop512_128bin_2025.02/{model.ckpt, config.json}
# 把这两个文件挪到 pretrain/nsf_hifigan/ 下，并重命名 model.ckpt → model
```

### 3. RMVPE（173 MB）

**方式 A：复用 Coopanion 的（推荐，省一次下载）**

```powershell
# Coopanion 装好之后就有这个文件
copy "D:\Coopanion\data\home\companion\data\rvc\assets\rmvpe\rmvpe.pt" `
     "ddsp-svc\pretrain\rmvpe\rmvpe.pt"

# DDSP 期望的格式是 {'model': state_dict}，Coopanion 那份是裸 state_dict，需要包一层
python -c "import torch; ck=torch.load(r'ddsp-svc/pretrain/rmvpe/rmvpe.pt', map_location='cpu', weights_only=False); torch.save({'model': ck, 'step': 0}, r'ddsp-svc/pretrain/rmvpe/model.pt')"
```

**方式 B：官方下载**

```bash
curl -L -o rmvpe.zip "https://github.com/yxlllc/RMVPE/releases/download/230917/rmvpe.zip"
unzip rmvpe.zip -d ddsp-svc/pretrain/
# 官方包解压出来是 pretrain/model.pt（368 MB）
```

## 你自己的音色模型

`exp/reflow-luotyxx/model_350000-luo.pt`（210 MB）是训练好的 ReFlow 音色模型，配合 `config.yaml` 使用。这个仓库不带它——每个人的音色都不一样。

自己训练的话见上游 [DDSP-SVC](https://github.com/yxlllc/DDSP-SVC) 的 README，`train_reflow.py` 大约需要 10 分钟音频素材。

## 验证装好了

```bash
cd ddsp-svc
python run_reflow.py --help
```

能打印帮助就说明依赖齐了（`torchcrepe` 已改可选，`pyworld` 必须装）。

真正跑一次：

```bash
python ddsp_sing.py \
  --input 任意歌曲.wav \
  --output out.wav \
  --workdir C:\Temp\test \
  --step 40 --highpass 380
```

## 常见报错

| 报错 | 原因 | 解法 |
|---|---|---|
| `No module named 'slicer'` | RVC venv 把 `sys.path[0]` 指到了 DLLs | 用本仓库的 `run_reflow.py` 启动，它会手动插 sys.path |
| `No module named 'torchcrepe'` | 顶层 import 挡住了 | 参考 `vocoder-patch.md` 第 4 节改成 try/except |
| `WeightsUnpicklingError` | PyTorch 2.6+ 默认 `weights_only=True` | 全仓库 `torch.load` 加 `weights_only=False` |
| `No module named 'fairseq'` | ContentVec 下成了 fairseq 格式 | 换 `pytorch_model.bin`（transformers 格式） |
| `KeyError: 'model'` | RMVPE checkpoint 结构不对 | 包一层 `{'model': state_dict}` |