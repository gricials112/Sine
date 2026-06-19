#!/usr/bin/env python3
"""
导出真实 HT-Demucs (Meta htdemucs 4.0.1) 分离核心到 CoreML, **目标 iOS 16**。
=============================================================================

来源: 改编自 reiscook/pocket-voice-cleanup-demucs-htdemucs-coreml 的官方导出脚本,
关键差异: minimum_deployment_target 由 iOS26 改为 **iOS16**。
这样 coremltools 会把融合的 scaled_dot_product_attention 拆解为 iOS16 可用的原语
(matmul/softmax/...), 使模型可在 iOS 16 设备加载运行 (满足"必须支持 iOS16")。

权重: Meta 官方 htdemucs 基础检查点 955717e8-8726e21a.th (sha8=8726e21a),
      经 HuggingFace 镜像下载到 torch hub 缓存 (官方 fbaipublicfiles 域被本环境拦截)。

为何是"分离核心"导出: HTDemucs 整图含复数 STFT/ISTFT, CoreML 不支持复数张量,
故在 cac=True 边界切分 —— STFT/ISTFT 由 Swift 用 Accelerate 完成, CoreML 跑学习到的实值核心。

I/O 契约 (与 Swift DemucsSeparator 一致):
  IN  mix          [1, 2, 343980]          44.1kHz 立体声波形 (7.8s 段)
  IN  spectrogram  [1, 4, 2048, 336]       STFT 的 实/虚 作为通道
  OUT spectrogram_stems [1, 4, 4, 2048, 336]
  OUT waveform_stems    [1, 4, 2, 343980]
  source order: drums, bass, other, vocals
"""
from __future__ import annotations
import argparse
from pathlib import Path

import coremltools as ct
import torch
from demucs.pretrained import get_model

MODEL_ID = "htdemucs"


class HTDemucsSeparatorCore(torch.nn.Module):
    """实值 HTDemucs 分离核心 (STFT 在外部完成)。"""

    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, mix: torch.Tensor, spectrogram: torch.Tensor):
        model = self.model
        x = spectrogram
        xt = mix
        batch, _, freqs, frames = x.shape
        length = mix.shape[-1]

        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)
        mean_t = xt.mean(dim=(1, 2), keepdim=True)
        std_t = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - mean_t) / (1e-5 + std_t)

        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(model.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(model.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = model.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and model.freq_emb is not None:
                fp = torch.arange(x.shape[-2], device=x.device)
                emb = model.freq_emb(fp).t()[None, :, :, None].expand_as(x)
                x = x + model.freq_emb_scale * emb
            saved.append(x)

        if model.crosstransformer:
            if model.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = model.channel_upsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = model.channel_upsampler_t(xt)
            x, xt = model.crosstransformer(x, xt)
            if model.bottom_channels:
                b, c, f, t = x.shape
                x = x.reshape(b, c, f * t)
                x = model.channel_downsampler(x)
                x = x.reshape(b, -1, f, t)
                xt = model.channel_downsampler_t(xt)

        for idx, decode in enumerate(model.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = model.depth - len(model.tdecoder)
            if idx >= offset:
                tdec = model.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip_t = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip_t, length_t)

        sources = len(model.sources)
        x = x.view(batch, sources, -1, freqs, frames)
        x = x * std[:, None] + mean[:, None]
        xt = xt.view(batch, sources, -1, length)
        xt = xt * std_t[:, None] + mean_t[:, None]
        return x, xt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="models/SineSeparator.mlpackage")
    args = ap.parse_args()

    bag = get_model(MODEL_ID)
    model = bag.models[0].eval()
    segment_samples = model.valid_length(44100)            # 343980
    hop = model.hop_length                                  # 1024
    segment_frames = int((segment_samples + hop - 1) // hop)  # 336
    print(f"segment_samples={segment_samples} segment_frames={segment_frames} sources={model.sources}")

    core = HTDemucsSeparatorCore(model).eval()
    mix = torch.zeros(1, 2, segment_samples)
    spec = torch.zeros(1, 4, 2048, segment_frames)

    # 自洽校验: 包装核心 + 外部 STFT/ISTFT 能否重建原模型输出
    with torch.no_grad():
        probe = torch.randn_like(mix) * 0.01
        z = model._spec(probe)
        mag = model._magnitude(z)
        spec_out, wave_out = core(probe, mag)
        recon = model._ispec(model._mask(z, spec_out), segment_samples) + wave_out
        ref = model(probe)
        err = (recon - ref).abs().max().item()
        print(f"[validate] wrapper_max_abs_error={err:.8f} (应 ~0)")

    traced = torch.jit.trace(core, (mix, spec), strict=False, check_trace=False)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=mix.shape),
                ct.TensorType(name="spectrogram", shape=spec.shape)],
        outputs=[ct.TensorType(name="spectrogram_stems"),
                 ct.TensorType(name="waveform_stems")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS16,      # ← 关键: 支持 iOS16
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.author = "Sine (HT-Demucs 4.0.1, Meta)"
    mlmodel.short_description = "HT-Demucs separator core (iOS16). mix+spectrogram -> stems. STFT/ISTFT in Swift."
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    import shutil
    if Path(args.out).exists():
        shutil.rmtree(args.out)
    mlmodel.save(args.out)
    print("saved:", args.out)


if __name__ == "__main__":
    main()
