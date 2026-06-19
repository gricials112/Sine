# Sine 模型 (真实 HT-Demucs, 4 轨)

`SineSeparator.mlpackage` 是 **Meta 官方 HT-Demucs 4.0.1** (`htdemucs` 基础检查点 `955717e8`)
的 CoreML 导出, **4 轨**分离: `drums / bass / other / vocals` (鼓 / 贝斯 / 其他 / 人声)。

- 经 **Git LFS** 提交 (`weight.bin` ≈ 102MB, FP16)。clone 后需 `git lfs pull` 拉取权重。
- 目标 **iOS 16** (specificationVersion 7, opset CoreML6) —— 导出时 `minimum_deployment_target=iOS16`
  使融合的 `scaled_dot_product_attention` 被拆解为 iOS16 可用原语。
- Xcode 会把 `.mlpackage` 自动编译为 `.mlmodelc` 进 App bundle (见 `project.yml`)。

## 为什么是"分离核心" + Swift STFT
HT-Demucs 整图含复数 STFT/ISTFT, CoreML 不支持复数张量, 故在 `cac=True` 边界切分:
- **Swift (Accelerate)** 做 STFT/ISTFT (`Sine/Core/Separation/DemucsSTFT.swift`)。
- **CoreML** 跑实值分离核心。
其数值契约 (n_fft=4096, hop=1024, 反射 pad 1536, 归一化 Hann, 7.8s/343980 样本段) 见
`manifest.json`, 并由 `reference/demucs_stft.py` 对真实 torch 模型**逐点校验** (误差 ~1e-8)。

## I/O 契约
| | 名称 | 形状 |
|---|---|---|
| 输入 | `mix` | [1, 2, 343980] |
| 输入 | `spectrogram` | [1, 4, 2048, 336] |
| 输出 | `spectrogram_stems` | [1, **4**, 4, 2048, 336] |
| 输出 | `waveform_stems` | [1, **4**, 2, 343980] |

源顺序 (dim1): `drums(0), bass(1), other(2), vocals(3)`。

## 复现导出 (需 macOS 或 Linux, 见版本约束)
```bash
pip install -r models/requirements.txt   # numpy<2, torch==2.4.1, coremltools==8.2, demucs==4.0.1
# 把官方 htdemucs 检查点放到 torch hub 缓存 (官方域被墙时用 HF 镜像):
#   ~/.cache/torch/hub/checkpoints/955717e8-8726e21a.th
python models/export_htdemucs_ios16.py --out models/SineSeparator.mlpackage
```
> 版本要点: **numpy 必须 < 2** (numpy 2.x 下 coremltools 的 `aten::Int` 转换会因
> `int(ndarray)` 报错); coremltools 8.2 + torch 2.4.1 验证可用。
> Linux 仅能*导出*, 不能预测/验证 (无 CoreML 运行时); 真机推理需在 iOS 上跑。
