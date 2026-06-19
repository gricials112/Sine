"""
Demucs STFT/ISTFT 契约的 numpy 参考实现 + 对真实模型的数值校验。
=================================================================

目的: Swift 端 (DemucsSTFT.swift) 需要在 Accelerate 上复刻 Demucs 的 _spec/_ispec,
把波形 <-> 频谱 (实/虚作通道), 并做掩码重建。本文件用 numpy 复刻这套变换, 并与
真实 htdemucs 模型的 torch 实现逐点比对, 作为 Swift 移植的"事实基线"。

运行: python reference/demucs_stft.py   (需 torch + demucs + 已缓存检查点)
"""
import math
import numpy as np

N_FFT = 4096
HOP = 1024
PAD = HOP // 2 * 3        # 1536
SEGMENT = 343980
FREQ_BINS = 2048          # 丢弃最高 bin 后
SEGMENT_FRAMES = 336


def hann(n):
    # torch.hann_window(n, periodic=True)
    return 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)


def _reflect_pad(x, left, right):
    return np.pad(x, [(0, 0)] * (x.ndim - 1) + [(left, right)], mode="reflect")


def np_spec(x):
    """复刻 demucs._spec: 输入 [C, L] -> 复数 [C, 2048, 336]。"""
    C, length = x.shape
    le = int(math.ceil(length / HOP))
    x = _reflect_pad(x, PAD, PAD + le * HOP - length)
    win = hann(N_FFT)
    # torch.stft(center=True, normalized=True): 内部再 reflect pad n_fft//2 两侧
    xc = _reflect_pad(x, N_FFT // 2, N_FFT // 2)
    norm = math.sqrt(N_FFT)
    frames = 1 + (xc.shape[-1] - N_FFT) // HOP
    z = np.zeros((C, N_FFT // 2 + 1, frames), dtype=np.complex128)
    for c in range(C):
        for t in range(frames):
            seg = xc[c, t * HOP: t * HOP + N_FFT] * win
            z[c, :, t] = np.fft.rfft(seg) / norm
    z = z[:, :-1, :]          # 丢最高频 bin -> 2048
    z = z[:, :, 2:2 + le]     # 去边界帧
    return z


def np_magnitude(z):
    """复刻 cac=True 的 _magnitude: 复数 [C,F,T] -> [C*2, F, T] (实/虚作通道)。"""
    C, F, T = z.shape
    m = np.stack([z.real, z.imag], axis=2)   # [C, F, 2, T]? 需匹配 torch view_as_real 顺序
    # torch: view_as_real(z) -> [...,2] 末维; permute 到通道 [C,2,F,T] -> reshape [C*2,F,T]
    m = np.stack([z.real, z.imag], axis=1)   # [C, 2, F, T]
    return m.reshape(C * 2, F, T)


def np_from_magnitude(m, C=2):
    """[C*2,F,T] -> 复数 [C,F,T] (逆 view_as_complex)。"""
    CC, F, T = m.shape
    m = m.reshape(C, 2, F, T)
    return m[:, 0] + 1j * m[:, 1]


def np_ispec(z, length):
    """复刻 demucs._ispec: 复数 [C,2048,T] -> 波形 [C, length]。"""
    C = z.shape[0]
    z = np.pad(z, [(0, 0), (0, 1), (0, 0)])      # 补回零频 bin -> 2049
    z = np.pad(z, [(0, 0), (0, 0), (2, 2)])      # 两端补 2 帧
    le = HOP * int(math.ceil(length / HOP)) + 2 * PAD
    x = np_istft(z, le)
    return x[:, PAD: PAD + length]


def np_istft(z, length):
    """归一化 Hann ISTFT (匹配 torch.istft center=True normalized=True)。"""
    C, F, T = z.shape
    win = hann(N_FFT)
    norm = math.sqrt(N_FFT)
    total = N_FFT + (T - 1) * HOP
    out = np.zeros((C, total))
    wsum = np.zeros(total)
    for c in range(C):
        for t in range(T):
            frame = np.fft.irfft(z[c, :, t] * norm, n=N_FFT) * win
            out[c, t * HOP: t * HOP + N_FFT] += frame
            if c == 0:
                wsum[t * HOP: t * HOP + N_FFT] += win ** 2
    wsum[wsum < 1e-8] = 1.0
    out = out / wsum
    out = out[:, N_FFT // 2: N_FFT // 2 + length]   # 去 center pad
    return out


def main():
    import torch
    from demucs.pretrained import get_model
    model = get_model("htdemucs").models[0].eval()

    rng = np.random.default_rng(0)
    mix = (rng.standard_normal((2, SEGMENT)) * 0.05).astype(np.float64)
    mt = torch.tensor(mix[None], dtype=torch.float32)

    # 1) STFT 比对
    z_torch = model._spec(mt)[0].detach().numpy()         # [2,2048,336] complex
    z_np = np_spec(mix)
    print(f"[STFT]  shape torch={z_torch.shape} np={z_np.shape}  max_abs_err={np.abs(z_torch - z_np).max():.2e}")

    # 2) magnitude 打包比对
    mag_torch = model._magnitude(model._spec(mt))[0].detach().numpy()  # [4,2048,336]
    mag_np = np_magnitude(z_np)
    print(f"[PACK]  shape={mag_np.shape}  max_abs_err={np.abs(mag_torch - mag_np).max():.2e}")

    # 3) ISTFT 往返比对 (用 torch 的 z 走 numpy ispec, 与 model._ispec 比)
    isp_torch = model._ispec(model._spec(mt), SEGMENT)[0].detach().numpy()
    isp_np = np_ispec(z_torch, SEGMENT)
    print(f"[ISTFT] shape={isp_np.shape}  max_abs_err={np.abs(isp_torch - isp_np).max():.2e}")


if __name__ == "__main__":
    main()
