import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// HT-Demucs 的 STFT/ISTFT 前后端 (难点一/模型契约)。
///
/// 真实 htdemucs 整图含复数 STFT/ISTFT, CoreML 不支持复数张量, 故模型只跑实值"分离核心",
/// STFT/ISTFT 必须在 Swift 用 Accelerate 完成。本类复刻 demucs `_spec/_ispec/_magnitude`,
/// 其数值正确性已由 `reference/demucs_stft.py` 对真实 torch 模型逐点校验 (误差 ~1e-8)。
///
/// ⚠️ 该文件为算法移植, 需在 macOS/真机用单元测试 (输入与 reference 同种子) 二次校验后再上线。
public final class DemucsSTFT {
    public static let nFFT = 4096
    public static let hop = 1024
    public static let pad = 1536          // hop/2*3
    public static let segment = 343980    // model.valid_length(44100)
    public static let freqBins = 2048     // 丢弃 Nyquist 后
    public static let frames = 336
    public static let channels = 2

    private let log2n: vDSP_Length
    private let win: [Float]
    private let norm: Float
    #if canImport(Accelerate)
    private let fftSetup: FFTSetup
    #endif

    public init() {
        log2n = vDSP_Length(log2(Float(Self.nFFT)))
        norm = sqrtf(Float(Self.nFFT))
        // 周期 Hann (与 torch.hann_window(periodic=True) 一致)
        var w = [Float](repeating: 0, count: Self.nFFT)
        for i in 0..<Self.nFFT { w[i] = 0.5 - 0.5 * cosf(2 * .pi * Float(i) / Float(Self.nFFT)) }
        win = w
        #if canImport(Accelerate)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        vDSP_destroy_fftsetup(fftSetup)
        #endif
    }

    // MARK: - 反射填充 (numpy mode='reflect')
    private func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
        var out = [Float](); out.reserveCapacity(x.count + left + right)
        for i in 0..<left { out.append(x[left - i]) }          // 反射, 不含边界点
        out.append(contentsOf: x)
        let n = x.count
        for i in 0..<right { out.append(x[n - 2 - i]) }
        return out
    }

    // MARK: - 前向: 波形 [C][L] -> spectrogram 通道打包 [C*2][F][T] (展平, C 序)
    /// 返回长度 = 4*2048*336, 布局 [c0_real, c0_imag, c1_real, c1_imag] 每个 [2048][336] (行优先)。
    public func spectrogram(mix: [[Float]]) -> [Float] {
        let length = mix[0].count
        let le = Int(ceil(Double(length) / Double(Self.hop)))
        let outChans = Self.channels * 2
        var out = [Float](repeating: 0, count: outChans * Self.freqBins * Self.frames)

        for c in 0..<Self.channels {
            // demucs._spec 外层反射填充
            let padded = reflectPad(mix[c], left: Self.pad, right: Self.pad + le * Self.hop - length)
            // torch.stft(center=True) 内部再反射填充 nFFT/2
            let centered = reflectPad(padded, left: Self.nFFT / 2, right: Self.nFFT / 2)
            let totalFrames = 1 + (centered.count - Self.nFFT) / Self.hop
            // 逐帧 rfft, 取 z[:-1] (丢 Nyquist) 与 z[:, 2:2+le] (去边界帧)
            for t in 0..<Self.frames {
                let srcFrame = t + 2          // 对应 z[..., 2:2+le]
                guard srcFrame < totalFrames else { break }
                let (re, im) = rfft(Array(centered[srcFrame * Self.hop ..< srcFrame * Self.hop + Self.nFFT]))
                // re/im 长度 nFFT/2+1=2049, 丢最后一个 bin -> 2048
                for f in 0..<Self.freqBins {
                    let baseR = (c * 2) * Self.freqBins * Self.frames + f * Self.frames + t
                    let baseI = (c * 2 + 1) * Self.freqBins * Self.frames + f * Self.frames + t
                    out[baseR] = re[f]
                    out[baseI] = im[f]
                }
            }
        }
        return out
    }

    // MARK: - 重建: spectrogram_stems(单源 [C*2][F][T]) + waveform_stems(单源 [C][L]) -> [C][L]
    public func reconstructStem(specChannels: [[Float]],   // 4 个 [F*T] (c0r,c0i,c1r,c1i)
                                waveChannels: [[Float]],   // 2 个 [segment]
                                length: Int) -> [[Float]] {
        var result = [[Float]]()
        for c in 0..<Self.channels {
            // 还原复数 [F][T]
            let reCh = specChannels[c * 2]
            let imCh = specChannels[c * 2 + 1]
            let wave = ispecChannel(re: reCh, im: imCh, length: length)
            // 加上时域分支
            var stem = wave
            let w = waveChannels[c]
            let n = min(stem.count, w.count, length)
            for i in 0..<n { stem[i] += w[i] }
            result.append(Array(stem.prefix(length)))
        }
        return result
    }

    /// demucs._ispec 单通道: 复数 [F=2048][T=336] -> 波形 [length]
    private func ispecChannel(re: [Float], im: [Float], length: Int) -> [Float] {
        // 补回零频 bin (2048->2049) + 两端补 2 帧 (336->340)
        let F = Self.freqBins + 1
        let T = Self.frames + 4
        var reF = [Float](repeating: 0, count: F * T)
        var imF = [Float](repeating: 0, count: F * T)
        for f in 0..<Self.freqBins {
            for t in 0..<Self.frames {
                reF[f * T + (t + 2)] = re[f * Self.frames + t]
                imF[f * T + (t + 2)] = im[f * Self.frames + t]
            }
        }
        // istft
        let le = Self.hop * Int(ceil(Double(length) / Double(Self.hop))) + 2 * Self.pad
        let full = istft(reF: reF, imF: imF, F: F, T: T, outLength: le)
        // 去掉 demucs 外层 pad
        let start = Self.pad
        return Array(full[start ..< min(start + length, full.count)])
    }

    // MARK: - rfft / irfft (vDSP)
    /// 实序列 (长度 nFFT) -> (real[0..2048], imag[0..2048]), 归一化除以 sqrt(nFFT), 匹配 numpy rfft/norm。
    private func rfft(_ frame: [Float]) -> (re: [Float], im: [Float]) {
        #if canImport(Accelerate)
        let n = Self.nFFT
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(frame, 1, win, 1, &windowed, 1, vDSP_Length(n))
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var re = [Float](repeating: 0, count: n / 2 + 1)
        var im = [Float](repeating: 0, count: n / 2 + 1)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP 打包: realp[0]=DC, imagp[0]=Nyquist; bins 1..n/2-1 在 realp/imagp。
                // vDSP 前向有 2x 缩放, 需 *0.5 还原标准 DFT。虚部符号与 numpy 相反 -> 取负。
                let scale: Float = 0.5
                re[0] = rp[0] * scale; im[0] = 0
                re[n / 2] = ip[0] * scale; im[n / 2] = 0       // Nyquist (随后会被丢弃)
                for k in 1..<(n / 2) {
                    re[k] = rp[k] * scale
                    im[k] = -ip[k] * scale
                }
            }
        }
        // 归一化 (normalized=True)
        let inv = 1.0 / norm
        vDSP_vsmul(re, 1, [inv], &re, 1, vDSP_Length(re.count))
        vDSP_vsmul(im, 1, [inv], &im, 1, vDSP_Length(im.count))
        return (re, im)
        #else
        return ([Float](repeating: 0, count: Self.nFFT / 2 + 1),
                [Float](repeating: 0, count: Self.nFFT / 2 + 1))
        #endif
    }

    /// 归一化 Hann ISTFT (overlap-add + 窗能量归一)。F=2049, T 帧。
    private func istft(reF: [Float], imF: [Float], F: Int, T: Int, outLength: Int) -> [Float] {
        #if canImport(Accelerate)
        let n = Self.nFFT
        let total = n + (T - 1) * Self.hop
        var out = [Float](repeating: 0, count: total)
        var wsum = [Float](repeating: 0, count: total)
        for t in 0..<T {
            // 还原 vDSP 打包 (逆缩放/符号) 后做 irfft
            var realp = [Float](repeating: 0, count: n / 2)
            var imagp = [Float](repeating: 0, count: n / 2)
            realp[0] = reF[0 * T + t] * norm * 2          // DC; 逆 *0.5 与归一
            imagp[0] = reF[(F - 1) * T + t] * norm * 2    // Nyquist 放回 imagp[0]
            for k in 1..<(n / 2) {
                realp[k] = reF[k * T + t] * norm * 2
                imagp[k] = -imF[k * T + t] * norm * 2     // 逆符号
            }
            var frame = [Float](repeating: 0, count: n)
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    frame.withUnsafeMutableBytes {
                        vDSP_ztoc(&split, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(n / 2))
                    }
                }
            }
            // vDSP 逆变换有 1/n 之外的缩放, 统一乘 1/n
            var inv = 1.0 / Float(n)
            vDSP_vsmul(frame, 1, &inv, &frame, 1, vDSP_Length(n))
            for i in 0..<n {
                let v = frame[i] * win[i]
                out[t * Self.hop + i] += v
                wsum[t * Self.hop + i] += win[i] * win[i]
            }
        }
        for i in 0..<total where wsum[i] > 1e-8 { out[i] /= wsum[i] }
        // 去 center pad
        let start = n / 2
        return Array(out[start ..< min(start + outLength, out.count)])
        #else
        return [Float](repeating: 0, count: outLength)
        #endif
    }
}
